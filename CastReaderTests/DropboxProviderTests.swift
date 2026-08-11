import XCTest
@testable import CastReader
#if canImport(SwiftyDropbox)
@preconcurrency import SwiftyDropbox
#endif

final class DropboxProviderTests: XCTestCase {
    #if canImport(SwiftyDropbox)
    func testTypedSDKRouteErrorsPreserveDownloadSemantics() {
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapDownloadRouteError(.unsupportedFile),
            .unsupportedItem
        )
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapDownloadRouteError(.path(.restrictedContent)),
            .downloadNotAllowed
        )
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapDownloadRouteError(.path(.notFound)),
            .itemUnavailable
        )
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapExportRouteError(.nonExportable),
            .unsupportedItem
        )
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapExportRouteError(.invalidExportFormat),
            .unsupportedExportFormat
        )
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapExportRouteError(.retryError),
            .provider(code: "dropbox_export_not_ready", retryable: true)
        )
    }

    func testTypedSDKAuthRateLimitAndNetworkErrorsDoNotUseStringMatching() {
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapAuthError(.expiredAccessToken),
            .needsReauthorization
        )
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapAuthError(.routeAccessDenied),
            .provider(code: "dropbox_auth_policy", retryable: false)
        )
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapRateLimitError(
                Auth.RateLimitError(reason: .tooManyRequests, retryAfter: 17)
            ),
            .rateLimited(17)
        )
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapClientError(
                .urlSessionError(URLError(.notConnectedToInternet))
            ),
            .network("dropbox_url_-1009")
        )
        let invalidRoot: CallError<Files.DownloadError> = .httpError(
            422,
            #"{"error":{".tag":"invalid_root"}}"#,
            nil
        )
        XCTAssertEqual(
            SwiftyDropboxAdapter.mapCallError(
                invalidRoot,
                route: SwiftyDropboxAdapter.mapDownloadRouteError
            ),
            .invalidRoot
        )
    }

    func testLateOAuthTokenCleanupNeverDeletesOwnedOrPendingToken() {
        XCTAssertEqual(
            DropboxOAuthOrphanTokenPolicy.cleanup(
                tokenUID: "accepted-a",
                acceptedTokenUIDs: ["accepted-a"],
                lastKnownActiveTokenUID: nil,
                hasPendingAuthorization: false
            ),
            .preserve
        )
        XCTAssertEqual(
            DropboxOAuthOrphanTokenPolicy.cleanup(
                tokenUID: "active-a",
                acceptedTokenUIDs: [],
                lastKnownActiveTokenUID: "active-a",
                hasPendingAuthorization: true
            ),
            .preserve
        )
        XCTAssertEqual(
            DropboxOAuthOrphanTokenPolicy.cleanup(
                tokenUID: "possible-new-b",
                acceptedTokenUIDs: [],
                lastKnownActiveTokenUID: "active-a",
                hasPendingAuthorization: true
            ),
            .deferUntilPendingAuthorizationFinishes
        )
        XCTAssertEqual(
            DropboxOAuthOrphanTokenPolicy.cleanup(
                tokenUID: "orphan-b",
                acceptedTokenUIDs: [],
                lastKnownActiveTokenUID: "active-a",
                hasPendingAuthorization: false
            ),
            .clearNow
        )
    }
    #endif

    func testListMapsSupportedExportableAndUnsupportedEntries() async throws {
        let account = Self.account(root: "root-1")
        let adapter = DropboxMockAdapter(account: account)
        await adapter.enqueueList(.success(DropboxPageRecord(
            entries: [
                .folder(id: "id:folder", name: "Books"),
                .file(DropboxFileRecord(
                    id: "id:pdf", name: "paper.pdf", size: 42,
                    modifiedAt: Date(timeIntervalSince1970: 100), revision: "rev-1",
                    isDownloadable: true, exportFormats: []
                )),
                .file(DropboxFileRecord(
                    id: "id:paper", name: "Dropbox Paper",
                    size: nil, modifiedAt: nil, revision: "rev-2",
                    isDownloadable: false, exportFormats: ["html", "pdf", "docx", "PDF"]
                )),
                .file(DropboxFileRecord(
                    id: "id:text", name: "notes.txt", size: 2,
                    modifiedAt: nil, revision: "rev-3",
                    isDownloadable: true, exportFormats: []
                )),
            ],
            cursor: "cursor-1",
            hasMore: true
        )))

        let provider = makeProvider(adapter: adapter)
        let connected = try await provider.ensureConnected()
        let page = try await provider.list(folder: nil, cursor: nil)

        XCTAssertEqual(connected.provider, .dropbox)
        XCTAssertEqual(page.folders.map(\.id), ["id:folder"])
        XCTAssertEqual(page.items.map(\.kind), [.file, .exportableDocument, .file])
        XCTAssertEqual(page.items[0].mimeType, SupportedDocumentFormat.pdf.preferredMIMEType)
        XCTAssertEqual(page.items[1].exportOptions, [.pdf, .docx])
        XCTAssertEqual(page.nextCursor?.rawValue, "cursor-1")
    }

    func testPaginationPassesOpaqueCursor() async throws {
        let adapter = DropboxMockAdapter(account: Self.account(root: "root-1"))
        await adapter.enqueueList(.success(DropboxPageRecord(
            entries: [], cursor: "opaque-cursor", hasMore: true
        )))
        await adapter.enqueueList(.success(DropboxPageRecord(
            entries: [], cursor: nil, hasMore: false
        )))
        let provider = makeProvider(adapter: adapter)

        _ = try await provider.list(folder: nil, cursor: nil)
        _ = try await provider.list(
            folder: nil,
            cursor: CloudCursor(rawValue: "opaque-cursor")
        )

        let calls = await adapter.listCalls
        XCTAssertEqual(calls.map(\.cursor), [nil, "opaque-cursor"])
        XCTAssertEqual(calls.map(\.root), ["root-1", "root-1"])
    }

    func testInvalidRootRefreshesAccountAndRestartsPageWithoutOldCursor() async throws {
        let old = Self.account(root: "old-root")
        let refreshed = Self.account(root: "new-root")
        let adapter = DropboxMockAdapter(account: old, refreshedAccount: refreshed)
        await adapter.enqueueList(.failure(.invalidRoot))
        await adapter.enqueueList(.success(DropboxPageRecord(
            entries: [.folder(id: "id:new", name: "New root")],
            cursor: nil,
            hasMore: false
        )))
        let provider = makeProvider(adapter: adapter)

        _ = try await provider.ensureConnected()
        let page = try await provider.list(
            folder: nil,
            cursor: CloudCursor(rawValue: "old-root-cursor")
        )

        XCTAssertEqual(page.folders.map(\.id), ["id:new"])
        let calls = await adapter.listCalls
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls[0].cursor, "old-root-cursor")
        XCTAssertEqual(calls[0].root, "old-root")
        XCTAssertNil(calls[1].cursor)
        XCTAssertEqual(calls[1].root, "new-root")
    }

    func testExportDownloadsDirectlyToDestinationAndBuildsReceipt() async throws {
        let account = Self.account(root: "root-1")
        let adapter = DropboxMockAdapter(account: account)
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dropbox-export.docx")
        await adapter.setTransfer(DropboxTransferRecord(
            localURL: destination,
            filename: "Notes.docx",
            byteCount: 1234,
            revision: "download-rev"
        ))
        await adapter.setMetadata(DropboxFileRecord(
            id: "id:paper",
            name: "Notes",
            size: nil,
            modifiedAt: nil,
            revision: "old-rev",
            isDownloadable: false,
            exportFormats: ["pdf", "docx"]
        ))
        let provider = makeProvider(adapter: adapter)
        let connected = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .dropbox,
            accountKey: connected.stableAccountKey,
            id: "id:paper",
            name: "Notes",
            revision: "old-rev",
            kind: .exportableDocument,
            exportOptions: [.pdf, .docx]
        )

        let receipt = try await provider.download(
            item,
            exportFormat: .docx,
            to: destination,
            progress: { _ in }
        )

        XCTAssertEqual(receipt.localURL, destination)
        XCTAssertEqual(receipt.effectiveFilename, "Notes.docx")
        XCTAssertEqual(receipt.effectiveFormat, .docx)
        XCTAssertEqual(receipt.exportFormat, .docx)
        XCTAssertEqual(receipt.finalRevision, "download-rev")
        XCTAssertEqual(receipt.byteCount, 1234)
        let call = await adapter.downloadCall
        XCTAssertEqual(call?.id, "id:paper")
        XCTAssertEqual(call?.root, "root-1")
        XCTAssertEqual(call?.exportFormat, "docx")
        XCTAssertEqual(call?.destination, destination)
    }

    func testDirectDownloadUsesFinalResponseFormatWhenSameIDChangesPDFToDOCX() async throws {
        let adapter = DropboxMockAdapter(account: Self.account(root: "root-1"))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-version-race-\(UUID().uuidString).docx")
        await adapter.setTransfer(DropboxTransferRecord(
            localURL: destination,
            filename: "Final Draft.docx",
            mimeType: SupportedDocumentFormat.docx.preferredMIMEType,
            byteCount: 222,
            revision: "rev-docx"
        ))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let staleItem = CloudItem(
            provider: .dropbox,
            accountKey: account.stableAccountKey,
            id: "id:same-file",
            name: "Old Draft.pdf",
            mimeType: SupportedDocumentFormat.pdf.preferredMIMEType,
            revision: "rev-pdf",
            kind: .file
        )

        let receipt = try await provider.download(staleItem, to: destination)

        XCTAssertEqual(receipt.effectiveFilename, "Final Draft.docx")
        XCTAssertEqual(receipt.effectiveFormat, .docx)
        XCTAssertEqual(
            receipt.effectiveMIMEType,
            SupportedDocumentFormat.docx.preferredMIMEType
        )
        XCTAssertEqual(receipt.finalRevision, "rev-docx")
        XCTAssertEqual(receipt.byteCount, 222)
    }

    func testTextDownloadUsesTextLimitAndMIMEAwareParserExtension() async throws {
        let adapter = DropboxMockAdapter(account: Self.account(root: "root-1"))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-html-\(UUID().uuidString).txt")
        await adapter.setTransfer(DropboxTransferRecord(
            localURL: destination,
            filename: "Web Clip.txt",
            mimeType: "text/html",
            byteCount: 30,
            revision: "rev-html"
        ))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .dropbox,
            accountKey: account.stableAccountKey,
            id: "id:html",
            name: "Web Clip.txt",
            mimeType: "text/plain",
            size: 30,
            revision: "rev-html",
            kind: .file
        )

        let receipt = try await provider.download(item, to: destination)

        XCTAssertEqual(receipt.effectiveFilename, "Web Clip.html")
        XCTAssertEqual(receipt.effectiveMIMEType, "text/html")
        XCTAssertEqual(receipt.effectiveFormat, .text)
        let call = await adapter.downloadCall
        XCTAssertEqual(call?.maximumBytes, SupportedDocumentFormat.text.maximumInputBytes)
    }

    func testFreshPDFMetadataUsesPDFLimitWhenHistoryStillSaysDOCX() async throws {
        let adapter = DropboxMockAdapter(account: Self.account(root: "root-1"))
        let capacity = DropboxCapacityPreflightRecorder()
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-fresh-pdf-\(UUID().uuidString).pdf")
        let pdfBytes: Int64 = 100 * 1_024 * 1_024
        await adapter.setMetadata(DropboxFileRecord(
            id: "id:renamed",
            name: "Current.pdf",
            size: pdfBytes,
            modifiedAt: nil,
            revision: "rev-pdf",
            isDownloadable: true,
            exportFormats: []
        ))
        await adapter.setTransfer(DropboxTransferRecord(
            localURL: destination,
            filename: "Current.pdf",
            mimeType: SupportedDocumentFormat.pdf.preferredMIMEType,
            byteCount: pdfBytes,
            revision: "rev-pdf"
        ))
        let provider = makeProvider(
            adapter: adapter,
            capacityPreflight: { expectedBytes, destination in
                try capacity.run(expectedBytes, destination)
            }
        )
        let account = try await provider.ensureConnected()
        let staleDOCX = CloudItem(
            provider: .dropbox,
            accountKey: account.stableAccountKey,
            id: "id:renamed",
            name: "Former.docx",
            mimeType: SupportedDocumentFormat.docx.preferredMIMEType,
            // This old DOCX snapshot is over the DOCX cap. The same stable ID
            // is now a valid PDF, so stale metadata must not reject it.
            size: SupportedDocumentFormat.docx.maximumInputBytes + 1,
            revision: "rev-docx",
            kind: .file
        )

        let receipt = try await provider.download(staleDOCX, to: destination)

        XCTAssertEqual(receipt.effectiveFormat, .pdf)
        XCTAssertEqual(receipt.byteCount, pdfBytes)
        let call = await adapter.downloadCall
        XCTAssertEqual(call?.maximumBytes, SupportedDocumentFormat.pdf.maximumInputBytes)
        XCTAssertEqual(
            capacity.snapshot(),
            [.init(expectedBytes: pdfBytes, destination: destination)]
        )
    }

    func testFreshMetadataDiskPreflightFailureStopsDropboxTransfer() async throws {
        let adapter = DropboxMockAdapter(account: Self.account(root: "root-1"))
        let capacity = DropboxCapacityPreflightRecorder(
            failure: .resourceLimitExceeded(.insufficientDeviceStorage)
        )
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-low-storage-\(UUID().uuidString).pdf")
        try Data("placeholder".utf8).write(to: destination)
        await adapter.setMetadata(DropboxFileRecord(
            id: "id:low-storage",
            name: "Current.pdf",
            size: 12_345,
            modifiedAt: nil,
            revision: "rev-current",
            isDownloadable: true,
            exportFormats: []
        ))
        let provider = makeProvider(
            adapter: adapter,
            capacityPreflight: { expectedBytes, destination in
                try capacity.run(expectedBytes, destination)
            }
        )
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .dropbox,
            accountKey: account.stableAccountKey,
            id: "id:low-storage",
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
        let call = await adapter.downloadCall
        XCTAssertNil(call)
        XCTAssertEqual(
            capacity.snapshot(),
            [.init(expectedBytes: 12_345, destination: destination)]
        )
    }

    func testDownloadRejectsConflictingFinalFilenameAndMIMEAndDeletesBytes() async throws {
        let adapter = DropboxMockAdapter(account: Self.account(root: "root-1"))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-mismatch-\(UUID().uuidString).pdf")
        try Data("partial".utf8).write(to: destination)
        await adapter.setTransfer(DropboxTransferRecord(
            localURL: destination,
            filename: "Book.pdf",
            mimeType: SupportedDocumentFormat.docx.preferredMIMEType,
            byteCount: 7,
            revision: "rev"
        ))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .dropbox,
            accountKey: account.stableAccountKey,
            id: "id:book",
            name: "Book.pdf",
            kind: .file
        )

        do {
            _ = try await provider.download(item, to: destination)
            XCTFail("Expected final filename/MIME mismatch")
        } catch {
            XCTAssertEqual(
                error as? CloudStorageError,
                .invalidResponse(code: "dropbox_transfer_format_mismatch")
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testDownloadRejectsOversizedFinalTransferAndDeletesTemporaryFile() async throws {
        let adapter = DropboxMockAdapter(account: Self.account(root: "root-1"))
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("dropbox-oversized-\(UUID().uuidString).pdf")
        try Data("partial".utf8).write(to: destination)
        await adapter.setTransfer(DropboxTransferRecord(
            localURL: destination,
            filename: "Book.pdf",
            mimeType: SupportedDocumentFormat.pdf.preferredMIMEType,
            byteCount: DocumentResourceLimits.maximumInputBytes + 1,
            revision: "rev"
        ))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .dropbox,
            accountKey: account.stableAccountKey,
            id: "id:book",
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

    func testDisconnectClearsExactLocalTokenWhenRemoteRevokeFails() async throws {
        let account = Self.account(root: "root-1")
        let adapter = DropboxMockAdapter(account: account)
        await adapter.setRevokeError(.network("offline"))
        let provider = makeProvider(adapter: adapter)
        _ = try await provider.ensureConnected()

        let result = await provider.disconnect()

        XCTAssertTrue(result.localAssociationRemoved)
        XCTAssertEqual(result.remoteRevocationStatus, .unconfirmed)
        XCTAssertTrue(result.retryable)
        let cleared = await adapter.clearedTokenUIDs
        let activated = await adapter.activatedTokenUIDs
        let state = await provider.connectionState()
        XCTAssertEqual(cleared, [account.tokenUID])
        XCTAssertEqual(activated, [account.tokenUID])
        XCTAssertEqual(state, .disconnected)
    }

    func testDownloadRejectsNonFileDestinationBeforeAdapterCall() async throws {
        let adapter = DropboxMockAdapter(account: Self.account(root: "root-1"))
        let provider = makeProvider(adapter: adapter)
        let account = try await provider.ensureConnected()
        let item = CloudItem(
            provider: .dropbox,
            accountKey: account.stableAccountKey,
            id: "id:pdf",
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

    func testAccountSwitchIsTwoPhaseAndOldAccountRemainsActiveUntilCommit() async throws {
        let first = Self.account(root: "root-a")
        let second = DropboxAccountRecord(
            rawAccountID: "dbid:account-b",
            tokenUID: "token-uid-b",
            displayName: "Grace Reader",
            email: "grace@example.com",
            rootNamespaceID: "root-b"
        )
        let adapter = DropboxMockAdapter(account: first)
        let suite = "DropboxProviderTests.commit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let provider = DropboxProvider(adapter: adapter, defaults: defaults)
        let activeA = try await provider.ensureConnected()
        await adapter.setAuthorizedAccount(second)

        let candidateB = try await provider.stageAnotherAccount()
        let stateBeforeCommit = await provider.connectionState()
        let sdkTokenBeforeCommit = await adapter.activeTokenUID

        XCTAssertEqual(candidateB.displayName, "Grace Reader")
        XCTAssertEqual(stateBeforeCommit, .connected(activeA))
        XCTAssertEqual(sdkTokenBeforeCommit, first.tokenUID)
        XCTAssertEqual(
            defaults.string(forKey: "cloud.dropbox.pendingCandidateTokenUID"),
            second.tokenUID
        )

        let activeB = try await provider.commitCandidate()
        let sdkTokenAfterCommit = await adapter.activeTokenUID
        let cleared = await adapter.clearedTokenUIDs
        let revoked = await adapter.revokedTokenUIDs
        XCTAssertEqual(activeB.displayName, "Grace Reader")
        XCTAssertEqual(sdkTokenAfterCommit, second.tokenUID)
        XCTAssertEqual(cleared, [first.tokenUID])
        XCTAssertEqual(revoked, [first.tokenUID])
        XCTAssertEqual(
            defaults.string(forKey: "cloud.dropbox.activeTokenUID"),
            second.tokenUID
        )
        XCTAssertNil(defaults.string(forKey: "cloud.dropbox.pendingCandidateTokenUID"))
        XCTAssertNil(defaults.string(forKey: "cloud.dropbox.pendingRetiredTokenUID"))
    }

    func testAccountSwitchKeepsRetiredMarkerAfterRevokeFailureAndRetriesOnRestart() async throws {
        let first = Self.account(root: "root-a")
        let second = DropboxAccountRecord(
            rawAccountID: "dbid:account-b",
            tokenUID: "token-uid-b",
            displayName: "Grace Reader",
            email: "grace@example.com",
            rootNamespaceID: "root-b"
        )
        let adapter = DropboxMockAdapter(account: first)
        await adapter.setRevokeError(.network("offline"))
        let suite = "DropboxProviderTests.revokeRetry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let provider = DropboxProvider(adapter: adapter, defaults: defaults)
        _ = try await provider.ensureConnected()
        await adapter.setAuthorizedAccount(second)
        _ = try await provider.stageAnotherAccount()

        let activeB = try await provider.commitCandidate()

        XCTAssertEqual(activeB.displayName, "Grace Reader")
        XCTAssertEqual(
            defaults.string(forKey: "cloud.dropbox.pendingRetiredTokenUID"),
            first.tokenUID
        )
        let initiallyCleared = await adapter.clearedTokenUIDs
        XCTAssertEqual(initiallyCleared, [])
        await adapter.setRevokeError(nil)

        let rebuilt = DropboxProvider(adapter: adapter, defaults: defaults)
        let restoredB = try await rebuilt.ensureConnected()
        let revoked = await adapter.revokedTokenUIDs
        let cleared = await adapter.clearedTokenUIDs
        let activeTokenUID = await adapter.activeTokenUID

        XCTAssertEqual(restoredB.displayName, "Grace Reader")
        XCTAssertEqual(revoked, [first.tokenUID, first.tokenUID])
        XCTAssertEqual(cleared, [first.tokenUID])
        XCTAssertNil(defaults.string(forKey: "cloud.dropbox.pendingRetiredTokenUID"))
        XCTAssertEqual(activeTokenUID, second.tokenUID)
    }

    func testDiscardCandidateClearsOnlyCandidateAndRestoresOldAccount() async throws {
        let first = Self.account(root: "root-a")
        let second = DropboxAccountRecord(
            rawAccountID: "dbid:account-b",
            tokenUID: "token-uid-b",
            displayName: "Grace Reader",
            email: "grace@example.com",
            rootNamespaceID: "root-b"
        )
        let adapter = DropboxMockAdapter(account: first)
        let provider = makeProvider(adapter: adapter)
        _ = try await provider.ensureConnected()
        await adapter.setAuthorizedAccount(second)
        _ = try await provider.stageAnotherAccount()

        await provider.discardCandidate()

        let staged = await provider.stagedCandidate()
        let activeToken = await adapter.activeTokenUID
        let cleared = await adapter.clearedTokenUIDs
        XCTAssertNil(staged)
        XCTAssertEqual(activeToken, first.tokenUID)
        XCTAssertEqual(cleared, [second.tokenUID])
    }

    func testProviderRebuildClearsUnconfirmedCandidateAndKeepsOldAccount() async throws {
        let first = Self.account(root: "root-a")
        let second = DropboxAccountRecord(
            rawAccountID: "dbid:account-b",
            tokenUID: "token-uid-b",
            displayName: "Grace Reader",
            email: "grace@example.com",
            rootNamespaceID: "root-b"
        )
        let adapter = DropboxMockAdapter(account: first)
        let suite = "DropboxProviderTests.restart.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let beforeCrash = DropboxProvider(adapter: adapter, defaults: defaults)
        let activeA = try await beforeCrash.ensureConnected()
        await adapter.setAuthorizedAccount(second)
        _ = try await beforeCrash.stageAnotherAccount()
        XCTAssertEqual(
            defaults.string(forKey: "cloud.dropbox.pendingCandidateTokenUID"),
            second.tokenUID
        )

        let afterRestart = DropboxProvider(adapter: adapter, defaults: defaults)
        let restored = try await afterRestart.ensureConnected()
        let activeTokenUID = await adapter.activeTokenUID
        let clearedTokenUIDs = await adapter.clearedTokenUIDs

        XCTAssertEqual(restored, activeA)
        XCTAssertEqual(activeTokenUID, first.tokenUID)
        XCTAssertEqual(clearedTokenUIDs, [second.tokenUID])
        XCTAssertNil(defaults.string(forKey: "cloud.dropbox.pendingCandidateTokenUID"))
    }

    func testColdDisconnectUsesPersistedActiveUIDToRevokeAndClearSDKToken() async {
        let account = Self.account(root: "root-a")
        let adapter = DropboxMockAdapter(account: account)
        let suite = "DropboxProviderTests.coldDisconnect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(account.tokenUID, forKey: "cloud.dropbox.activeTokenUID")
        let provider = DropboxProvider(adapter: adapter, defaults: defaults)

        let result = await provider.disconnect()
        let revokedTokenUIDs = await adapter.revokedTokenUIDs
        let clearedTokenUIDs = await adapter.clearedTokenUIDs

        XCTAssertTrue(result.localAssociationRemoved)
        XCTAssertEqual(result.remoteRevocationStatus, .confirmed)
        XCTAssertEqual(revokedTokenUIDs, [account.tokenUID])
        XCTAssertEqual(clearedTokenUIDs, [account.tokenUID])
        XCTAssertNil(defaults.string(forKey: "cloud.dropbox.activeTokenUID"))
        XCTAssertNil(defaults.string(forKey: "cloud.dropbox.pendingRetiredTokenUID"))
    }

    func testCancelledAccountSwitchRejectsLateOAuthSuccessAndClearsCandidate() async throws {
        let first = Self.account(root: "root-a")
        let second = DropboxAccountRecord(
            rawAccountID: "dbid:account-b",
            tokenUID: "token-uid-b",
            displayName: "Grace Reader",
            email: "grace@example.com",
            rootNamespaceID: "root-b"
        )
        let adapter = DropboxMockAdapter(account: first)
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
        let activeTokenUID = await adapter.activeTokenUID
        let clearedTokenUIDs = await adapter.clearedTokenUIDs
        let stagedCandidate = await provider.stagedCandidate()
        XCTAssertEqual(state, .connected(activeA))
        XCTAssertEqual(activeTokenUID, first.tokenUID)
        XCTAssertEqual(clearedTokenUIDs, [second.tokenUID])
        XCTAssertNil(stagedCandidate)
    }

    private func makeProvider(
        adapter: DropboxMockAdapter,
        capacityPreflight: @escaping CloudDownloadCapacityPreflight =
            CloudDownloadCapacityPolicy.live
    ) -> DropboxProvider {
        let suite = "DropboxProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return DropboxProvider(
            adapter: adapter,
            defaults: defaults,
            capacityPreflight: capacityPreflight
        )
    }

    private static func account(root: String) -> DropboxAccountRecord {
        DropboxAccountRecord(
            rawAccountID: "dbid:account",
            tokenUID: "token-uid-account",
            displayName: "Ada Reader",
            email: "ada@example.com",
            rootNamespaceID: root
        )
    }
}

private final class DropboxCapacityPreflightRecorder: @unchecked Sendable {
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

private actor DropboxMockAdapter: DropboxProviderAdapter {
    struct ListCall: Equatable {
        let path: String
        let cursor: String?
        let root: String
    }

    struct DownloadCall: Equatable {
        let id: String
        let root: String
        let exportFormat: String?
        let destination: URL
        let maximumBytes: Int64
    }

    private var account: DropboxAccountRecord
    private var authorizedAccount: DropboxAccountRecord
    private var refreshedAccount: DropboxAccountRecord
    private var listResults: [Result<DropboxPageRecord, DropboxAdapterError>] = []
    private var transfer = DropboxTransferRecord(
        localURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("download.pdf"),
        filename: "download.pdf",
        byteCount: 0,
        revision: nil
    )
    private var metadataRecord: DropboxFileRecord?
    private var revokeError: DropboxAdapterError?
    private var shouldSuspendNextAuthorization = false
    private var authorizationStarted = false
    private var authorizationStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var authorizationContinuation: CheckedContinuation<DropboxAccountRecord, Never>?

    private(set) var listCalls: [ListCall] = []
    private(set) var downloadCall: DownloadCall?
    private(set) var activatedTokenUIDs: [String] = []
    private(set) var clearedTokenUIDs: [String] = []
    private(set) var revokedTokenUIDs: [String] = []
    private(set) var activeTokenUID: String?

    init(account: DropboxAccountRecord, refreshedAccount: DropboxAccountRecord? = nil) {
        self.account = account
        authorizedAccount = account
        self.refreshedAccount = refreshedAccount ?? account
    }

    func setAuthorizedAccount(_ account: DropboxAccountRecord) {
        authorizedAccount = account
    }

    func enqueueList(_ result: Result<DropboxPageRecord, DropboxAdapterError>) {
        listResults.append(result)
    }

    func setTransfer(_ transfer: DropboxTransferRecord) {
        self.transfer = transfer
    }

    func setMetadata(_ metadata: DropboxFileRecord) {
        metadataRecord = metadata
    }

    func setRevokeError(_ error: DropboxAdapterError?) {
        revokeError = error
    }

    func suspendNextAuthorization() {
        shouldSuspendNextAuthorization = true
        authorizationStarted = false
    }

    func waitUntilAuthorizationStarts() async {
        if authorizationStarted { return }
        await withCheckedContinuation { authorizationStartWaiters.append($0) }
    }

    func completeSuspendedAuthorization(with account: DropboxAccountRecord) {
        authorizationContinuation?.resume(returning: account)
        authorizationContinuation = nil
    }

    func restoreAccount(tokenUID: String?) async throws -> DropboxAccountRecord? {
        let restored: DropboxAccountRecord
        if tokenUID == authorizedAccount.tokenUID {
            restored = authorizedAccount
        } else {
            restored = account
        }
        activeTokenUID = restored.tokenUID
        return restored
    }

    func authorize() async throws -> DropboxAccountRecord {
        if shouldSuspendNextAuthorization {
            shouldSuspendNextAuthorization = false
            authorizationStarted = true
            let waiters = authorizationStartWaiters
            authorizationStartWaiters.removeAll()
            waiters.forEach { $0.resume() }
            let selected = await withCheckedContinuation {
                authorizationContinuation = $0
            }
            activeTokenUID = selected.tokenUID
            return selected
        }
        activeTokenUID = authorizedAccount.tokenUID
        return authorizedAccount
    }
    func refreshCurrentAccount() async throws -> DropboxAccountRecord { refreshedAccount }

    func activate(tokenUID: String) async throws {
        activatedTokenUIDs.append(tokenUID)
        activeTokenUID = tokenUID
    }

    func metadata(id: String, rootNamespaceID: String) async throws -> DropboxFileRecord {
        if let metadataRecord { return metadataRecord }
        return DropboxFileRecord(
            id: id,
            name: transfer.filename,
            size: transfer.byteCount,
            modifiedAt: nil,
            revision: transfer.revision,
            isDownloadable: true,
            exportFormats: []
        )
    }

    func list(
        path: String,
        cursor: String?,
        rootNamespaceID: String
    ) async throws -> DropboxPageRecord {
        listCalls.append(ListCall(path: path, cursor: cursor, root: rootNamespaceID))
        guard !listResults.isEmpty else {
            return DropboxPageRecord(entries: [], cursor: nil, hasMore: false)
        }
        return try listResults.removeFirst().get()
    }

    func search(
        query: String,
        cursor: String?,
        rootNamespaceID: String
    ) async throws -> DropboxPageRecord {
        DropboxPageRecord(entries: [], cursor: nil, hasMore: false)
    }

    func download(
        id: String,
        rootNamespaceID: String,
        exportFormat: String?,
        destination: URL,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> DropboxTransferRecord {
        downloadCall = DownloadCall(
            id: id,
            root: rootNamespaceID,
            exportFormat: exportFormat,
            destination: destination,
            maximumBytes: maximumBytes
        )
        guard transfer.byteCount <= maximumBytes else {
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }
        progress(CloudDownloadProgress(completedBytes: transfer.byteCount, totalBytes: transfer.byteCount))
        return transfer
    }

    func revoke(tokenUID: String) async throws {
        revokedTokenUIDs.append(tokenUID)
        if let revokeError { throw revokeError }
    }

    func clearLocalToken(tokenUID: String) async {
        clearedTokenUIDs.append(tokenUID)
        if activeTokenUID == tokenUID { activeTokenUID = nil }
    }
}
