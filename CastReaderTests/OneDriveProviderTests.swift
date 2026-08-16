import XCTest
@testable import CastReader

final class OneDriveProviderTests: XCTestCase {
#if canImport(MSAL)
    func testMalformedMSALClientIDFailsClosed() {
        XCTAssertThrowsError(
            try OneDriveProvider(
                clientID: "not-a-guid",
                authority: "https://login.microsoftonline.com/common",
                redirectURI: "msauth.com.same.castreader://auth",
                presenter: { nil }
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudStorageError,
                .invalidConfiguration(code: "onedrive_client_id")
            )
        }
    }

    func testMalformedMSALAuthorityFailsClosed() {
        XCTAssertThrowsError(
            try OneDriveProvider(
                clientID: "00000000-0000-0000-0000-000000000001",
                authority: "http://login.microsoftonline.com/common",
                redirectURI: "msauth.com.same.castreader://auth",
                presenter: { nil }
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudStorageError,
                .invalidConfiguration(code: "onedrive_authority")
            )
        }
    }

    func testMalformedMSALRedirectURIFailsClosed() {
        XCTAssertThrowsError(
            try OneDriveProvider(
                clientID: "00000000-0000-0000-0000-000000000001",
                authority: "https://login.microsoftonline.com/common",
                redirectURI: "not a redirect URI",
                presenter: { nil }
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudStorageError,
                .invalidConfiguration(code: "onedrive_redirect_uri")
            )
        }
    }
#endif

    func testGraph403OnlyMapsExplicitDownloadRestrictionInDownloadContext() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/id/content")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        ))
        let restricted = Data(
            #"{"error":{"code":"accessDenied","innerError":{"code":"downloadNotAllowed"}}}"#.utf8
        )

        XCTAssertEqual(
            OneDriveGraphErrorMapper.map(
                response: response,
                data: restricted,
                isDownload: true
            ),
            .downloadNotAllowed
        )
        XCTAssertEqual(
            OneDriveGraphErrorMapper.map(
                response: response,
                data: restricted,
                isDownload: false
            ),
            .provider(code: "onedrive_access_denied", retryable: false)
        )
    }

    func testGraph403ConditionalAccessAndGenericAccessDeniedAreNotDownloadErrors() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/id/content")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        ))
        let conditionalAccess = Data(
            #"{"error":{"code":"accessDenied","innerError":{"code":"conditionalAccessPolicyEnforced"}}}"#.utf8
        )
        let generic = Data(#"{"error":{"code":"accessDenied"}}"#.utf8)

        XCTAssertEqual(
            OneDriveGraphErrorMapper.map(
                response: response,
                data: conditionalAccess,
                isDownload: true
            ),
            .provider(code: "onedrive_admin_policy", retryable: false)
        )
        XCTAssertEqual(
            OneDriveGraphErrorMapper.map(
                response: response,
                data: generic,
                isDownload: true
            ),
            .provider(code: "onedrive_access_denied", retryable: false)
        )
    }

    func testGraphNestedCodesPreserveAuthNotFoundAndRateLimitSemantics() throws {
        let url = URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/id")!
        let forbidden = try XCTUnwrap(HTTPURLResponse(
            url: url, statusCode: 403, httpVersion: nil, headerFields: nil
        ))
        let throttled = try XCTUnwrap(HTTPURLResponse(
            url: url,
            statusCode: 403,
            httpVersion: nil,
            headerFields: ["Retry-After": "23"]
        ))

        XCTAssertEqual(
            OneDriveGraphErrorMapper.map(
                response: forbidden,
                data: Data(#"{"error":{"code":"invalidAuthenticationToken"}}"#.utf8),
                isDownload: false
            ),
            .needsReauthorization
        )
        XCTAssertEqual(
            OneDriveGraphErrorMapper.map(
                response: forbidden,
                data: Data(#"{"error":{"code":"accessDenied","innerError":{"code":"itemNotFound"}}}"#.utf8),
                isDownload: false
            ),
            .itemUnavailable
        )
        XCTAssertEqual(
            OneDriveGraphErrorMapper.map(
                response: throttled,
                data: Data(#"{"error":{"code":"activityLimitReached"}}"#.utf8),
                isDownload: false
            ),
            .rateLimited(23)
        )
    }

    func testGraphCodecCanonicalizesRemoteItemsAndUsesCTagRevision() throws {
        let data = Data(#"""
        {
          "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=opaque",
          "value": [
            {
              "id": "shortcut-id",
              "name": "Shared Book.pdf",
              "remoteItem": {
                "id": "remote-file-id",
                "name": "Original.pdf",
                "size": 2048,
                "lastModifiedDateTime": "2026-08-10T08:00:01.123Z",
                "eTag": "etag-old",
                "cTag": "ctag-content",
                "file": { "mimeType": "application/pdf" },
                "parentReference": { "driveId": "remote-drive-id" }
              }
            },
            {
              "id": "folder-id",
              "name": "Books",
              "folder": {},
              "parentReference": { "driveId": "main-drive-id" }
            },
            {
              "id": "package-id",
              "name": "Notebook.one",
              "package": { "type": "oneNote" },
              "parentReference": { "driveId": "main-drive-id" }
            }
          ]
        }
        """#.utf8)

        let page = try OneDriveGraphCodec.decodePage(data)

        XCTAssertEqual(page.nextLink, "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=opaque")
        XCTAssertEqual(page.entries.count, 3)
        XCTAssertEqual(page.entries[0].id, "remote-file-id")
        XCTAssertEqual(page.entries[0].driveID, "remote-drive-id")
        XCTAssertEqual(page.entries[0].name, "Shared Book.pdf")
        XCTAssertEqual(page.entries[0].revision, "ctag-content")
        XCTAssertEqual(page.entries[0].mimeType, "application/pdf")
        XCTAssertEqual(page.entries[0].size, 2048)
        XCTAssertTrue(page.entries[1].isFolder)
        XCTAssertTrue(page.entries[2].isPackage)
    }

    func testGraphNextLinkRejectsTokenExfiltrationHost() throws {
        XCTAssertNoThrow(try OneDriveGraphCodec.validatedNextLink(
            "https://graph.microsoft.com/v1.0/me/drive/root/children?$skiptoken=x"
        ))
        XCTAssertThrowsError(try OneDriveGraphCodec.validatedNextLink(
            "https://attacker.example/collect?token=please"
        )) { error in
            XCTAssertEqual(
                error as? OneDriveAdapterError,
                .invalidResponse("onedrive_untrusted_next_link")
            )
        }
    }

    func testSelectedDriveGraphRoutesStayInsideThatDrive() {
        let children = OneDriveGraphCodec.childrenURL(
            driveID: "drive-2",
            itemID: "root"
        )
        let search = OneDriveGraphCodec.searchURL(
            query: "reader's notes",
            driveID: "drive-2"
        )

        XCTAssertEqual(children.path, "/v1.0/drives/drive-2/root/children")
        XCTAssertTrue(search.path.contains("/v1.0/drives/drive-2/root/search"))
        XCTAssertTrue(search.absoluteString.contains("reader''s%20notes")
            || search.absoluteString.contains("reader%27%27s%20notes"))
        XCTAssertEqual(OneDriveGraphCodec.defaultDriveURL().path, "/v1.0/me/drive")
        XCTAssertEqual(OneDriveGraphCodec.drivesURL().path, "/v1.0/me/drives")
    }

    func testGraphDrivePageMarksOnlyDefaultDriveAndPreservesNextLink() throws {
        let defaultDrive = try OneDriveGraphCodec.decodeDefaultDrive(Data(#"""
        {
          "id": "drive-default",
          "name": "Ada's OneDrive"
        }
        """#.utf8))
        let page = try OneDriveGraphCodec.decodeDrivePage(Data(#"""
        {
          "@odata.nextLink": "https://graph.microsoft.com/v1.0/me/drives?$skiptoken=next",
          "value": [
            { "id": "drive-default", "name": "Ada's OneDrive" },
            { "id": "drive-archive", "name": "Archive" }
          ]
        }
        """#.utf8), defaultDriveID: defaultDrive.id)

        XCTAssertEqual(defaultDrive.isDefault, true)
        XCTAssertEqual(page.drives.map(\.id), ["drive-default", "drive-archive"])
        XCTAssertEqual(page.drives.map(\.isDefault), [true, false])
        XCTAssertEqual(
            page.nextLink,
            "https://graph.microsoft.com/v1.0/me/drives?$skiptoken=next"
        )
    }

    func testPreauthenticatedDownloadRequestNeverContainsBearerHeader() throws {
        let request = try OneDriveGraphCodec.preauthenticatedDownloadRequest(
            url: URL(string: "https://public.dm.files.1drv.com/content?authkey=opaque")!
        )

        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.scheme, "https")
    }

    func testListMapsFoldersSupportedFilesPackagesAndOpaquePagination() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        await adapter.enqueueList(OneDrivePageRecord(
            entries: [
                OneDriveItemRecord(
                    id: "folder", driveID: "drive", name: "Books", size: nil,
                    modifiedAt: nil, eTag: nil, cTag: nil, mimeType: nil,
                    isFolder: true, isPackage: false
                ),
                OneDriveItemRecord(
                    id: "docx", driveID: "drive", name: "Draft.docx", size: 11,
                    modifiedAt: nil, eTag: "e", cTag: "c", mimeType: nil,
                    isFolder: false, isPackage: false
                ),
                OneDriveItemRecord(
                    id: "epub", driveID: "drive", name: "Book", size: 22,
                    modifiedAt: nil, eTag: "e2", cTag: nil,
                    mimeType: "application/epub+zip",
                    isFolder: false, isPackage: false
                ),
                OneDriveItemRecord(
                    id: "html", driveID: "drive", name: "Web Clip", size: 30,
                    modifiedAt: nil, eTag: "e3", cTag: "c3",
                    mimeType: "text/html",
                    isFolder: false, isPackage: false
                ),
                OneDriveItemRecord(
                    id: "package", driveID: "drive", name: "Notes.one", size: nil,
                    modifiedAt: nil, eTag: nil, cTag: nil, mimeType: nil,
                    isFolder: false, isPackage: true
                ),
                OneDriveItemRecord(
                    id: "binary", driveID: "drive", name: "Archive.bin", size: 44,
                    modifiedAt: nil, eTag: "e4", cTag: "c4",
                    mimeType: "application/octet-stream",
                    isFolder: false, isPackage: false
                ),
            ],
            nextLink: "https://graph.microsoft.com/v1.0/next?page=2"
        ))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()

        let page = try await provider.list(folder: nil, cursor: nil)

        XCTAssertEqual(page.folders.map(\.id), ["folder"])
        XCTAssertEqual(
            page.items.map(\.kind),
            [.file, .file, .file, .unsupported, .unsupported]
        )
        XCTAssertEqual(page.items[0].revision, "c")
        XCTAssertEqual(page.items[1].mimeType, "application/epub+zip")
        XCTAssertEqual(page.items[2].mimeType, "text/html")
        XCTAssertEqual(page.nextCursor?.rawValue, "https://graph.microsoft.com/v1.0/next?page=2")
        XCTAssertEqual(page.items[0].accountKey, account.stableAccountKey)

        await adapter.enqueueList(OneDrivePageRecord(entries: [], nextLink: nil))
        _ = try await provider.list(folder: nil, cursor: page.nextCursor)
        let calls = await adapter.listCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[1].nextLink, page.nextCursor?.rawValue)
    }

    func testListDrivesMapsOnlyAdapterUserDrivesAndMarksDefault() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        await adapter.setDrives([
            OneDriveDriveRecord(id: "default-drive", name: "Ada's OneDrive", isDefault: true),
            OneDriveDriveRecord(id: "archive-drive", name: "Archive", isDefault: false),
            OneDriveDriveRecord(id: "archive-drive", name: "Duplicate", isDefault: false),
        ])
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()

        let drives = try await provider.listDrives()

        XCTAssertEqual(drives.map(\.id), ["default-drive", "archive-drive"])
        XCTAssertEqual(drives.map(\.name), ["Ada's OneDrive", "Archive"])
        XCTAssertEqual(drives.map(\.isDefault), [true, false])
        XCTAssertTrue(drives.allSatisfy { $0.provider == .oneDrive })
        XCTAssertTrue(drives.allSatisfy { $0.accountKey == account.stableAccountKey })
        let listDrivesCallCount = await adapter.listDrivesCallCount
        XCTAssertEqual(listDrivesCallCount, 1)
    }

    func testSearchScopesInitialAndPaginatedRequestsToSelectedDrive() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        await adapter.enqueueSearch(OneDrivePageRecord(
            entries: [OneDriveItemRecord(
                id: "book",
                driveID: "archive-drive",
                name: "Book.pdf",
                size: 10,
                modifiedAt: nil,
                eTag: "etag",
                cTag: "ctag",
                mimeType: "application/pdf",
                isFolder: false,
                isPackage: false
            )],
            nextLink: "https://graph.microsoft.com/v1.0/drives/archive-drive/root/search(q='book')?$skiptoken=next"
        ))
        await adapter.enqueueSearch(OneDrivePageRecord(entries: [], nextLink: nil))
        let provider = makeProvider(adapter: adapter)
        _ = try await provider.ensureConnected()

        let first = try await provider.search("book", driveID: "archive-drive", cursor: nil)
        _ = try await provider.search(
            "book",
            driveID: "archive-drive",
            cursor: first.nextCursor
        )

        XCTAssertEqual(first.items.first?.driveID, "archive-drive")
        let calls = await adapter.searchCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.map(\.driveID), ["archive-drive", "archive-drive"])
        XCTAssertNil(calls[0].nextLink)
        XCTAssertEqual(calls[1].nextLink, first.nextCursor?.rawValue)
    }

    func testExplicitAccountSelectionIsTwoPhaseAndUsesSelectAccountPrompt() async throws {
        let first = Self.account
        let second = OneDriveAccountRecord(
            rawAccountID: "home-account-2",
            cacheAccountIdentifier: "cache-account-2",
            displayName: "Grace Reader",
            email: "grace@example.com"
        )
        let adapter = OneDriveMockAdapter(account: first)
        let suite = "OneDriveProviderTests.commit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(
            first.cacheAccountIdentifier,
            forKey: "cloud.onedrive.activeMSALAccountIdentifier"
        )
        let provider = OneDriveProvider(adapter: adapter, defaults: defaults)
        let activeA = try await provider.ensureConnected()
        await adapter.setAuthorizedAccount(second)

        let selected = try await provider.stageAnotherAccount()
        let stateBeforeCommit = await provider.connectionState()
        let sdkAccountBeforeCommit = await adapter.activeAccountIdentifier

        XCTAssertEqual(selected.displayName, "Grace Reader")
        let selectAccountValues = await adapter.authorizeSelectAccountValues
        XCTAssertEqual(selectAccountValues, [true])
        XCTAssertEqual(stateBeforeCommit, .connected(activeA))
        XCTAssertEqual(sdkAccountBeforeCommit, first.cacheAccountIdentifier)
        XCTAssertEqual(
            defaults.string(forKey: "cloud.onedrive.pendingCandidateMSALAccountIdentifier"),
            second.cacheAccountIdentifier
        )

        let committed = try await provider.commitCandidate()
        let sdkAccountAfterCommit = await adapter.activeAccountIdentifier
        let signedOut = await adapter.signedOutIdentifiers
        XCTAssertEqual(committed.displayName, "Grace Reader")
        XCTAssertEqual(sdkAccountAfterCommit, second.cacheAccountIdentifier)
        XCTAssertEqual(signedOut, [first.cacheAccountIdentifier])
        XCTAssertEqual(
            defaults.string(forKey: "cloud.onedrive.activeMSALAccountIdentifier"),
            second.cacheAccountIdentifier
        )
        XCTAssertNil(defaults.string(
            forKey: "cloud.onedrive.pendingCandidateMSALAccountIdentifier"
        ))
        XCTAssertNil(defaults.string(
            forKey: "cloud.onedrive.pendingRetiredMSALAccountIdentifier"
        ))
    }

    func testDiscardCandidateSignsOutCandidateLocallyAndRestoresOldAccount() async throws {
        let second = OneDriveAccountRecord(
            rawAccountID: "home-account-2",
            cacheAccountIdentifier: "cache-account-2",
            displayName: "Grace Reader",
            email: "grace@example.com"
        )
        let adapter = OneDriveMockAdapter(account: Self.account)
        let provider = makeProvider(adapter: adapter)
        _ = try await provider.ensureConnected()
        await adapter.setAuthorizedAccount(second)
        _ = try await provider.stageAnotherAccount()

        await provider.discardCandidate()

        let staged = await provider.stagedCandidate()
        let signedOut = await adapter.signedOutIdentifiers
        let activeIdentifier = await adapter.activeAccountIdentifier
        XCTAssertNil(staged)
        XCTAssertEqual(signedOut, [second.cacheAccountIdentifier])
        XCTAssertEqual(activeIdentifier, Self.account.cacheAccountIdentifier)
    }

    func testProviderRebuildSignsOutUnconfirmedCandidateAndKeepsOldAccount() async throws {
        let second = OneDriveAccountRecord(
            rawAccountID: "home-account-2",
            cacheAccountIdentifier: "cache-account-2",
            displayName: "Grace Reader",
            email: "grace@example.com"
        )
        let adapter = OneDriveMockAdapter(account: Self.account)
        let suite = "OneDriveProviderTests.restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let beforeCrash = OneDriveProvider(adapter: adapter, defaults: defaults)
        let activeA = try await beforeCrash.ensureConnected()
        await adapter.setAuthorizedAccount(second)
        _ = try await beforeCrash.stageAnotherAccount()
        XCTAssertEqual(
            defaults.string(forKey: "cloud.onedrive.pendingCandidateMSALAccountIdentifier"),
            second.cacheAccountIdentifier
        )

        let afterRestart = OneDriveProvider(adapter: adapter, defaults: defaults)
        let restored = try await afterRestart.ensureConnected()
        let activeIdentifier = await adapter.activeAccountIdentifier
        let signedOut = await adapter.signedOutIdentifiers

        XCTAssertEqual(restored, activeA)
        XCTAssertEqual(activeIdentifier, Self.account.cacheAccountIdentifier)
        XCTAssertEqual(signedOut, [second.cacheAccountIdentifier])
        XCTAssertNil(defaults.string(
            forKey: "cloud.onedrive.pendingCandidateMSALAccountIdentifier"
        ))
    }

    func testColdDisconnectUsesPersistedIdentifierToRemoveMSALAccount() async {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let suite = "OneDriveProviderTests.coldDisconnect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(
            Self.account.cacheAccountIdentifier,
            forKey: "cloud.onedrive.activeMSALAccountIdentifier"
        )
        let provider = OneDriveProvider(adapter: adapter, defaults: defaults)

        let result = await provider.disconnect()
        let signedOut = await adapter.signedOutIdentifiers

        XCTAssertTrue(result.localAssociationRemoved)
        XCTAssertEqual(result.remoteRevocationStatus, .unsupported)
        XCTAssertEqual(signedOut, [Self.account.cacheAccountIdentifier])
        XCTAssertNil(defaults.string(forKey: "cloud.onedrive.activeMSALAccountIdentifier"))
        XCTAssertNil(defaults.string(
            forKey: "cloud.onedrive.pendingRetiredMSALAccountIdentifier"
        ))
    }

    func testDisconnectRetainsFailedCandidateCleanupAndRetriesAfterColdStart() async throws {
        let second = OneDriveAccountRecord(
            rawAccountID: "home-account-2",
            cacheAccountIdentifier: "cache-account-2",
            displayName: "Grace Reader",
            email: "grace@example.com"
        )
        let adapter = OneDriveMockAdapter(account: Self.account)
        let suite = "OneDriveProviderTests.disconnectCleanupRetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let provider = OneDriveProvider(adapter: adapter, defaults: defaults)
        _ = try await provider.ensureConnected()
        await adapter.setAuthorizedAccount(second)
        _ = try await provider.stageAnotherAccount()
        await adapter.failNextSignOut(accountIdentifier: second.cacheAccountIdentifier)

        let result = await provider.disconnect()

        XCTAssertFalse(result.localAssociationRemoved)
        XCTAssertNil(defaults.string(forKey: "cloud.onedrive.activeMSALAccountIdentifier"))
        XCTAssertEqual(
            defaults.stringArray(
                forKey: "cloud.onedrive.pendingCleanupMSALAccountIdentifiers"
            ),
            [second.cacheAccountIdentifier]
        )
        XCTAssertEqual(
            defaults.string(forKey: "cloud.onedrive.pendingCandidateMSALAccountIdentifier"),
            second.cacheAccountIdentifier
        )

        let afterRestart = OneDriveProvider(adapter: adapter, defaults: defaults)
        do {
            _ = try await afterRestart.restorePersistedAccount()
            XCTFail("A completed disconnect must not restore an account")
        } catch {
            XCTAssertEqual(error as? CloudStorageError, .needsReauthorization)
        }

        let attempts = await adapter.signOutAttemptIdentifiers
        XCTAssertEqual(
            attempts.filter { $0 == second.cacheAccountIdentifier }.count,
            2
        )
        XCTAssertEqual(
            attempts.filter { $0 == Self.account.cacheAccountIdentifier }.count,
            1
        )
        XCTAssertNil(defaults.stringArray(
            forKey: "cloud.onedrive.pendingCleanupMSALAccountIdentifiers"
        ))
        XCTAssertNil(defaults.string(
            forKey: "cloud.onedrive.pendingCandidateMSALAccountIdentifier"
        ))
    }

    func testCancelledAccountSwitchRejectsLateMSALSuccessAndRemovesCandidate() async throws {
        let second = OneDriveAccountRecord(
            rawAccountID: "home-account-2",
            cacheAccountIdentifier: "cache-account-2",
            displayName: "Grace Reader",
            email: "grace@example.com"
        )
        let adapter = OneDriveMockAdapter(account: Self.account)
        let provider = makeProvider(adapter: adapter)
        let activeA = try await provider.ensureConnected()
        await adapter.suspendNextAuthorization()

        let switchTask = Task { try await provider.stageAnotherAccount() }
        await adapter.waitUntilAuthorizationStarts()
        switchTask.cancel()
        await adapter.completeSuspendedAuthorization(with: second)

        do {
            _ = try await switchTask.value
            XCTFail("Expected cancelled switch")
        } catch {
            XCTAssertEqual(error as? CloudStorageError, .userCancelled)
        }
        let state = await provider.connectionState()
        let activeIdentifier = await adapter.activeAccountIdentifier
        let signedOut = await adapter.signedOutIdentifiers
        let stagedCandidate = await provider.stagedCandidate()
        XCTAssertEqual(state, .connected(activeA))
        XCTAssertEqual(activeIdentifier, Self.account.cacheAccountIdentifier)
        XCTAssertEqual(signedOut, [second.cacheAccountIdentifier])
        XCTAssertNil(stagedCandidate)
    }

    func testDownloadUsesDriveIdentityAndReturnsDeviceLocalReceipt() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onedrive-book.epub")
        let metadata = OneDriveItemRecord(
            id: "remote-item",
            driveID: "shared-drive",
            name: "Novel.epub",
            size: 9001,
            modifiedAt: nil,
            eTag: "etag",
            cTag: "ctag",
            mimeType: "application/epub+zip",
            isFolder: false,
            isPackage: false
        )
        await adapter.enqueueMetadata(metadata)
        await adapter.enqueueMetadata(metadata)
        await adapter.setTransfer(OneDriveTransferRecord(
            localURL: destination,
            byteCount: 9001
        ))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .oneDrive,
            accountKey: account.stableAccountKey,
            driveID: "shared-drive",
            id: "remote-item",
            name: "Novel.epub",
            mimeType: "application/epub+zip",
            revision: "ctag",
            kind: .file
        )

        let receipt = try await provider.download(item, to: destination)

        XCTAssertEqual(receipt.localURL, destination)
        XCTAssertEqual(receipt.effectiveFormat, .epub)
        XCTAssertEqual(receipt.effectiveMIMEType, "application/epub+zip")
        XCTAssertEqual(receipt.finalRevision, "ctag")
        XCTAssertEqual(receipt.byteCount, 9001)
        let call = await adapter.downloadCall
        XCTAssertEqual(call?.itemID, "remote-item")
        XCTAssertEqual(call?.driveID, "shared-drive")
        XCTAssertEqual(call?.destination, destination)
    }

    func testDownloadRetriesRenameAndRevisionRaceAndUsesFinalMetadata() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("onedrive-version-race.docx")
        let beforeChange = OneDriveItemRecord(
            id: "remote-item",
            driveID: "shared-drive",
            name: "Draft.pdf",
            size: 100,
            modifiedAt: nil,
            eTag: "etag-1",
            cTag: "ctag-1",
            mimeType: "application/pdf",
            isFolder: false,
            isPackage: false
        )
        let afterChange = OneDriveItemRecord(
            id: "remote-item",
            driveID: "shared-drive",
            name: "Final.docx",
            size: 200,
            modifiedAt: nil,
            eTag: "etag-2",
            cTag: "ctag-2",
            mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            isFolder: false,
            isPackage: false
        )
        await adapter.enqueueMetadata(beforeChange)
        await adapter.enqueueMetadata(afterChange)
        await adapter.enqueueMetadata(afterChange)
        await adapter.enqueueMetadata(afterChange)
        await adapter.enqueueTransfer(OneDriveTransferRecord(
            localURL: destination,
            byteCount: 100
        ))
        await adapter.enqueueTransfer(OneDriveTransferRecord(
            localURL: destination,
            byteCount: 200
        ))

        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let staleItem = CloudItem(
            provider: .oneDrive,
            accountKey: account.stableAccountKey,
            driveID: "shared-drive",
            id: "remote-item",
            name: "Draft.pdf",
            mimeType: "application/pdf",
            revision: "ctag-1",
            kind: .file
        )

        let receipt = try await provider.download(staleItem, to: destination)
        let downloadCalls = await adapter.downloadCalls
        let metadataCalls = await adapter.metadataCalls

        XCTAssertEqual(downloadCalls.count, 2)
        XCTAssertEqual(metadataCalls.count, 4)
        XCTAssertEqual(receipt.effectiveFilename, "Final.docx")
        XCTAssertEqual(
            receipt.effectiveMIMEType,
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        )
        XCTAssertEqual(receipt.effectiveFormat, .docx)
        XCTAssertEqual(receipt.finalRevision, "ctag-2")
        XCTAssertEqual(receipt.byteCount, 200)
    }

    func testExtensionlessHTMLUsesTextLimitAndKeepsHTMLParserHint() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("onedrive-extensionless-html-\(UUID().uuidString)")
        let metadata = OneDriveItemRecord(
            id: "html-item",
            driveID: "drive",
            name: "Web Clip",
            size: 30,
            modifiedAt: nil,
            eTag: "etag-html",
            cTag: "ctag-html",
            mimeType: "text/html",
            isFolder: false,
            isPackage: false
        )
        await adapter.enqueueMetadata(metadata)
        await adapter.enqueueMetadata(metadata)
        await adapter.setTransfer(OneDriveTransferRecord(
            localURL: destination,
            byteCount: 30
        ))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .oneDrive,
            accountKey: account.stableAccountKey,
            driveID: "drive",
            id: "html-item",
            name: "Web Clip",
            mimeType: "text/html",
            size: 30,
            revision: "ctag-html",
            kind: .file
        )

        let receipt = try await provider.download(item, to: destination)

        XCTAssertEqual(receipt.effectiveFilename, "Web Clip.html")
        XCTAssertEqual(receipt.effectiveMIMEType, "text/html")
        XCTAssertEqual(receipt.effectiveFormat, .text)
        let calls = await adapter.downloadCalls
        XCTAssertEqual(calls.first?.maximumBytes, SupportedDocumentFormat.text.maximumInputBytes)
    }

    func testDownloadRejectsOversizedFinalTransferAndDeletesTemporaryFile() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("onedrive-oversized-\(UUID().uuidString).pdf")
        try Data("partial".utf8).write(to: destination)
        let metadata = OneDriveItemRecord(
            id: "remote-item",
            driveID: "drive",
            name: "Book.pdf",
            size: nil,
            modifiedAt: nil,
            eTag: "etag",
            cTag: "ctag",
            mimeType: "application/pdf",
            isFolder: false,
            isPackage: false
        )
        await adapter.enqueueMetadata(metadata)
        await adapter.setTransfer(OneDriveTransferRecord(
            localURL: destination,
            byteCount: DocumentResourceLimits.maximumInputBytes + 1
        ))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .oneDrive,
            accountKey: account.stableAccountKey,
            driveID: "drive",
            id: "remote-item",
            name: "Book.pdf",
            kind: .file
        )

        do {
            _ = try await provider.download(item, to: destination)
            XCTFail("Expected final transfer size rejection")
        } catch {
            XCTAssertEqual(
                error as? DocumentImportError,
                .resourceLimitExceeded(.inputFileTooLarge)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloadRejectsOversizedFreshMetadataBeforeTransfer() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("onedrive-metadata-oversized-\(UUID().uuidString).pdf")
        try Data("placeholder".utf8).write(to: destination)
        await adapter.enqueueMetadata(OneDriveItemRecord(
            id: "remote-item",
            driveID: "drive",
            name: "Book.pdf",
            size: DocumentResourceLimits.maximumInputBytes + 1,
            modifiedAt: nil,
            eTag: "etag",
            cTag: "ctag",
            mimeType: "application/pdf",
            isFolder: false,
            isPackage: false
        ))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .oneDrive,
            accountKey: account.stableAccountKey,
            driveID: "drive",
            id: "remote-item",
            name: "Book.pdf",
            kind: .file
        )

        do {
            _ = try await provider.download(item, to: destination)
            XCTFail("Expected fresh metadata size rejection")
        } catch {
            XCTAssertEqual(
                error as? DocumentImportError,
                .resourceLimitExceeded(.inputFileTooLarge)
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let downloadCalls = await adapter.downloadCalls
        XCTAssertTrue(downloadCalls.isEmpty)
    }

    func testFreshPDFMetadataControlsCapacityWhenHistoryStillSaysDOCX() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let capacity = OneDriveCapacityPreflightRecorder()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("onedrive-fresh-pdf-\(UUID().uuidString).pdf")
        let pdfBytes: Int64 = 100 * 1_024 * 1_024
        let metadata = OneDriveItemRecord(
            id: "remote-renamed",
            driveID: "drive",
            name: "Current.pdf",
            size: pdfBytes,
            modifiedAt: nil,
            eTag: "etag-current",
            cTag: "ctag-current",
            mimeType: SupportedDocumentFormat.pdf.preferredMIMEType,
            isFolder: false,
            isPackage: false
        )
        await adapter.enqueueMetadata(metadata)
        await adapter.enqueueMetadata(metadata)
        await adapter.setTransfer(OneDriveTransferRecord(
            localURL: destination,
            byteCount: pdfBytes
        ))
        let provider = makeProvider(
            adapter: adapter,
            capacityPreflight: { expectedBytes, destination in
                try capacity.run(expectedBytes, destination)
            }
        )
        let account = try await provider.ensureConnected()
        let staleDOCX = CloudItem(
            provider: .oneDrive,
            accountKey: account.stableAccountKey,
            driveID: "drive",
            id: "remote-renamed",
            name: "Former.docx",
            mimeType: SupportedDocumentFormat.docx.preferredMIMEType,
            size: SupportedDocumentFormat.docx.maximumInputBytes + 1,
            revision: "ctag-old",
            kind: .file
        )

        let receipt = try await provider.download(staleDOCX, to: destination)

        XCTAssertEqual(receipt.effectiveFormat, .pdf)
        let calls = await adapter.downloadCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(
            capacity.snapshot(),
            [.init(expectedBytes: pdfBytes, destination: destination)]
        )
    }

    func testFreshMetadataDiskPreflightFailureStopsOneDriveTransfer() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let capacity = OneDriveCapacityPreflightRecorder(
            failure: .resourceLimitExceeded(.insufficientDeviceStorage)
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("onedrive-low-storage-\(UUID().uuidString).pdf")
        try Data("placeholder".utf8).write(to: destination)
        await adapter.enqueueMetadata(OneDriveItemRecord(
            id: "remote-low-storage",
            driveID: "drive",
            name: "Current.pdf",
            size: 23_456,
            modifiedAt: nil,
            eTag: "etag-current",
            cTag: "ctag-current",
            mimeType: SupportedDocumentFormat.pdf.preferredMIMEType,
            isFolder: false,
            isPackage: false
        ))
        let provider = makeProvider(
            adapter: adapter,
            capacityPreflight: { expectedBytes, destination in
                try capacity.run(expectedBytes, destination)
            }
        )
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .oneDrive,
            accountKey: account.stableAccountKey,
            driveID: "drive",
            id: "remote-low-storage",
            name: "Old.docx",
            size: 1,
            kind: .file
        )

        do {
            _ = try await provider.download(item, to: destination)
            XCTFail("Expected low-storage rejection")
        } catch {
            XCTAssertEqual(
                error as? DocumentImportError,
                .resourceLimitExceeded(.insufficientDeviceStorage)
            )
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        let calls = await adapter.downloadCalls
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(
            capacity.snapshot(),
            [.init(expectedBytes: 23_456, destination: destination)]
        )
    }

    func testDisconnectPerformsMSALLocalSignoutWithoutClaimingRemoteRevocation() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let provider = makeProvider(adapter: adapter)
        _ = try await provider.ensureConnected()

        let result = await provider.disconnect()

        XCTAssertTrue(result.localAssociationRemoved)
        XCTAssertEqual(result.remoteRevocationStatus, .unsupported)
        let signedOut = await adapter.signedOutIdentifiers
        let state = await provider.connectionState()
        XCTAssertEqual(signedOut, [Self.account.cacheAccountIdentifier])
        XCTAssertEqual(state, .disconnected)
    }

    func testAccountBoundaryUsesOnlyMSALLocalSignout() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let provider = makeProvider(adapter: adapter)
        _ = try await provider.ensureConnected()

        await provider.clearLocalAuthorizationForAccountBoundary()

        let signedOut = await adapter.signedOutIdentifiers
        let state = await provider.connectionState()
        XCTAssertEqual(signedOut, [Self.account.cacheAccountIdentifier])
        XCTAssertEqual(state, .disconnected)
    }

    func testDownloadRejectsNonFileDestinationBeforeAdapterCall() async throws {
        let adapter = OneDriveMockAdapter(account: Self.account)
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .oneDrive,
            accountKey: account.stableAccountKey,
            driveID: "drive",
            id: "pdf",
            name: "paper.pdf",
            kind: .file
        )

        do {
            _ = try await provider.download(
                item,
                to: URL(string: "https://example.com/paper.pdf")!
            )
            XCTFail("Expected non-file destination rejection")
        } catch {
            XCTAssertEqual(error as? CloudStorageError, .downloadNotAllowed)
        }
        let downloadCall = await adapter.downloadCall
        XCTAssertNil(downloadCall)
    }

    private func makeProvider(
        adapter: OneDriveMockAdapter,
        capacityPreflight: @escaping CloudDownloadCapacityPreflight =
            CloudDownloadCapacityPolicy.live
    ) -> OneDriveProvider {
        let suite = "OneDriveProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return OneDriveProvider(
            adapter: adapter,
            defaults: defaults,
            capacityPreflight: capacityPreflight
        )
    }

    private static let account = OneDriveAccountRecord(
        rawAccountID: "home-account-1",
        cacheAccountIdentifier: "cache-account-1",
        displayName: "Ada Reader",
        email: "ada@example.com"
    )
}

private final class OneDriveCapacityPreflightRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let expectedBytes: Int64
        let destination: URL
    }

    private let lock = NSLock()
    private var calls: [Call] = []
    private let failure: DocumentImportError?

    init(failure: DocumentImportError? = nil) {
        self.failure = failure
    }

    func run(_ expectedBytes: Int64, _ destination: URL) throws {
        lock.lock()
        calls.append(Call(expectedBytes: expectedBytes, destination: destination))
        lock.unlock()
        if let failure { throw failure }
    }

    func snapshot() -> [Call] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

private actor OneDriveMockAdapter: OneDriveProviderAdapter {
    struct ListCall: Equatable {
        let folderID: String?
        let driveID: String?
        let nextLink: String?
    }

    struct DownloadCall: Equatable {
        let itemID: String
        let driveID: String?
        let destination: URL
        let maximumBytes: Int64
    }

    struct MetadataCall: Equatable {
        let itemID: String
        let driveID: String?
    }

    struct SearchCall: Equatable {
        let query: String
        let driveID: String?
        let nextLink: String?
    }

    private var account: OneDriveAccountRecord
    private var authorizedAccount: OneDriveAccountRecord
    private var knownAccounts: [String: OneDriveAccountRecord]
    private var drives: [OneDriveDriveRecord] = []
    private var listResults: [OneDrivePageRecord] = []
    private var searchResults: [OneDrivePageRecord] = []
    private var metadataResults: [OneDriveItemRecord] = []
    private var transferResults: [OneDriveTransferRecord] = []
    private var transfer = OneDriveTransferRecord(
        localURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("onedrive.pdf"),
        byteCount: 0
    )
    private var shouldSuspendNextAuthorization = false
    private var authorizationStarted = false
    private var authorizationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationContinuation: CheckedContinuation<OneDriveAccountRecord, Never>?
    private var signOutFailuresRemaining: [String: Int] = [:]

    private(set) var authorizeSelectAccountValues: [Bool] = []
    private(set) var listDrivesCallCount = 0
    private(set) var listCalls: [ListCall] = []
    private(set) var searchCalls: [SearchCall] = []
    private(set) var metadataCalls: [MetadataCall] = []
    private(set) var downloadCalls: [DownloadCall] = []
    private(set) var downloadCall: DownloadCall?
    private(set) var signedOutIdentifiers: [String] = []
    private(set) var signOutAttemptIdentifiers: [String] = []
    private(set) var activeAccountIdentifier: String?

    init(account: OneDriveAccountRecord) {
        self.account = account
        authorizedAccount = account
        knownAccounts = [account.cacheAccountIdentifier: account]
    }

    func setAuthorizedAccount(_ account: OneDriveAccountRecord) {
        authorizedAccount = account
        knownAccounts[account.cacheAccountIdentifier] = account
    }

    func failNextSignOut(accountIdentifier: String) {
        signOutFailuresRemaining[accountIdentifier, default: 0] += 1
    }

    func setDrives(_ drives: [OneDriveDriveRecord]) {
        self.drives = drives
    }

    func enqueueSearch(_ result: OneDrivePageRecord) {
        searchResults.append(result)
    }

    func enqueueList(_ result: OneDrivePageRecord) {
        listResults.append(result)
    }

    func enqueueMetadata(_ result: OneDriveItemRecord) {
        metadataResults.append(result)
    }

    func setTransfer(_ transfer: OneDriveTransferRecord) {
        self.transfer = transfer
    }

    func enqueueTransfer(_ transfer: OneDriveTransferRecord) {
        transferResults.append(transfer)
    }

    func suspendNextAuthorization() {
        shouldSuspendNextAuthorization = true
        authorizationStarted = false
    }

    func waitUntilAuthorizationStarts() async {
        if authorizationStarted { return }
        await withCheckedContinuation { authorizationStartWaiters.append($0) }
    }

    func completeSuspendedAuthorization(with account: OneDriveAccountRecord) {
        knownAccounts[account.cacheAccountIdentifier] = account
        authorizationContinuation?.resume(returning: account)
        authorizationContinuation = nil
    }

    func restoreAccount(accountIdentifier: String?) async throws -> OneDriveAccountRecord? {
        if let accountIdentifier {
            guard let restored = knownAccounts[accountIdentifier] else { return nil }
            account = restored
            activeAccountIdentifier = restored.cacheAccountIdentifier
            return restored
        }
        activeAccountIdentifier = account.cacheAccountIdentifier
        return account
    }

    func authorize(selectAccount: Bool) async throws -> OneDriveAccountRecord {
        authorizeSelectAccountValues.append(selectAccount)
        if shouldSuspendNextAuthorization {
            shouldSuspendNextAuthorization = false
            authorizationStarted = true
            let waiters = authorizationStartWaiters
            authorizationStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            let selected = await withCheckedContinuation {
                authorizationContinuation = $0
            }
            account = selected
            activeAccountIdentifier = selected.cacheAccountIdentifier
            return selected
        }
        account = authorizedAccount
        activeAccountIdentifier = authorizedAccount.cacheAccountIdentifier
        return authorizedAccount
    }

    func metadata(itemID: String, driveID: String?) async throws -> OneDriveItemRecord {
        metadataCalls.append(MetadataCall(itemID: itemID, driveID: driveID))
        guard !metadataResults.isEmpty else {
            throw OneDriveAdapterError.invalidResponse("metadata_fixture_missing")
        }
        return metadataResults.removeFirst()
    }

    func listDrives() async throws -> [OneDriveDriveRecord] {
        listDrivesCallCount += 1
        return drives
    }

    func list(
        folderID: String?,
        driveID: String?,
        nextLink: String?
    ) async throws -> OneDrivePageRecord {
        listCalls.append(ListCall(folderID: folderID, driveID: driveID, nextLink: nextLink))
        guard !listResults.isEmpty else { return OneDrivePageRecord(entries: [], nextLink: nil) }
        return listResults.removeFirst()
    }

    func search(
        query: String,
        driveID: String?,
        nextLink: String?
    ) async throws -> OneDrivePageRecord {
        searchCalls.append(SearchCall(query: query, driveID: driveID, nextLink: nextLink))
        guard !searchResults.isEmpty else {
            return OneDrivePageRecord(entries: [], nextLink: nil)
        }
        return searchResults.removeFirst()
    }

    func download(
        itemID: String,
        driveID: String?,
        destination: URL,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> OneDriveTransferRecord {
        let call = DownloadCall(
            itemID: itemID,
            driveID: driveID,
            destination: destination,
            maximumBytes: maximumBytes
        )
        downloadCall = call
        downloadCalls.append(call)
        let result = transferResults.isEmpty ? transfer : transferResults.removeFirst()
        guard result.byteCount <= maximumBytes else {
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }
        progress(CloudDownloadProgress(
            completedBytes: result.byteCount,
            totalBytes: result.byteCount
        ))
        return result
    }

    func signOut(accountIdentifier: String) async throws {
        signOutAttemptIdentifiers.append(accountIdentifier)
        if signOutFailuresRemaining[accountIdentifier, default: 0] > 0 {
            signOutFailuresRemaining[accountIdentifier, default: 0] -= 1
            throw OneDriveAdapterError.network("onedrive_test_signout")
        }
        guard knownAccounts[accountIdentifier] != nil else { return }
        signedOutIdentifiers.append(accountIdentifier)
        knownAccounts[accountIdentifier] = nil
        if activeAccountIdentifier == accountIdentifier { activeAccountIdentifier = nil }
    }
}
