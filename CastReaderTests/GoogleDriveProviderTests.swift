//
//  GoogleDriveProviderTests.swift
//  CastReaderTests
//
//  Contract tests for Google Drive's atomic mobile Picker OAuth flow. All
//  browser, network, credential, clock and random dependencies are in-memory.
//

import Foundation
import UIKit
import XCTest
@testable import CastReader

final class GoogleDriveProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTextDocumentMIMEsAndExtensionsAreImportableWithoutEnablingOtherFiles() {
        XCTAssertEqual(
            GoogleDriveProvider.supportedFormat(
                mimeType: "text/plain",
                filename: "notes"
            ),
            .text
        )
        XCTAssertEqual(
            GoogleDriveProvider.supportedFormat(
                mimeType: "text/markdown",
                filename: "README"
            ),
            .text
        )
        XCTAssertEqual(
            GoogleDriveProvider.supportedFormat(
                mimeType: "application/rtf",
                filename: "Formatted"
            ),
            .text
        )
        XCTAssertEqual(
            GoogleDriveProvider.supportedFormat(
                mimeType: "text/html",
                filename: "Article"
            ),
            .text
        )
        XCTAssertEqual(
            GoogleDriveProvider.supportedFormat(
                mimeType: "application/json",
                filename: "Export"
            ),
            .text
        )
        XCTAssertEqual(
            GoogleDriveProvider.supportedFormat(
                mimeType: "application/octet-stream",
                filename: "notes.md"
            ),
            .text
        )
        XCTAssertNil(GoogleDriveProvider.supportedFormat(
            mimeType: "application/vnd.google-apps.spreadsheet",
            filename: "Budget"
        ))
        XCTAssertNil(GoogleDriveProvider.supportedFormat(
            mimeType: "application/zip",
            filename: "Archive.zip"
        ))
        XCTAssertEqual(
            GoogleDriveProvider.normalizedDownloadFilename(
                "README",
                format: .text,
                mimeType: "text/markdown"
            ),
            "README.md"
        )
        XCTAssertEqual(
            GoogleDriveProvider.normalizedDownloadFilename(
                "Formatted",
                format: .text,
                mimeType: "application/rtf"
            ),
            "Formatted.rtf"
        )
        XCTAssertEqual(
            GoogleDriveProvider.normalizedDownloadFilename(
                "Article",
                format: .text,
                mimeType: "text/html"
            ),
            "Article.html"
        )
    }

    @MainActor
    func testTXTAndRTFDownloadThroughGoogleAndImportIntoReadableDocument() async throws {
        let fixtures: [(
            id: String,
            name: String,
            mimeType: String,
            payload: Data,
            expectedText: String
        )] = [
            (
                "text-plain-1",
                "Cloud Notes.txt",
                "text/plain",
                Data("Plain cloud text is readable.".utf8),
                "Plain cloud text is readable."
            ),
            (
                "text-rtf-1",
                "Formatted Cloud Note.rtf",
                "application/rtf",
                Data(#"{\rtf1\ansi Formatted cloud text is readable.}"#.utf8),
                "Formatted cloud text is readable."
            ),
        ]

        for (index, fixture) in fixtures.enumerated() {
            let account = testAccount()
            let store = GoogleDriveTestCredentialStore(
                credential: browserCredential(account: account)
            )
            let metadata =
                """
                {
                  "id":"\(fixture.id)",
                  "name":"\(fixture.name)",
                  "mimeType":"\(fixture.mimeType)",
                  "size":"\(fixture.payload.count)",
                  "modifiedTime":"2026-08-10T08:00:00.000Z",
                  "version":"1",
                  "capabilities":{"canDownload":true}
                }
                """
            let transport = GoogleDriveTestTransport(
                dataHandler: { request in
                    XCTAssertEqual(
                        request.url?.path,
                        "/drive/v3/files/\(fixture.id)"
                    )
                    return .json(metadata)
                },
                downloadHandler: { request in
                    XCTAssertEqual(
                        request.url?.path,
                        "/drive/v3/files/\(fixture.id)"
                    )
                    XCTAssertEqual(request.url?.queryDictionary["alt"], "media")
                    return .bytes(
                        fixture.payload,
                        contentType: fixture.mimeType
                    )
                }
            )
            let provider = makeProvider(
                transport: transport,
                store: store,
                web: GoogleDriveImmediateWebAuthenticator.unused
            )
            let item = CloudItem(
                provider: .googleDrive,
                accountKey: account.stableAccountKey,
                id: fixture.id,
                name: fixture.name,
                mimeType: fixture.mimeType,
                size: Int64(fixture.payload.count),
                revision: "1|2026-08-10T08:00:00.000Z",
                kind: .file
            )
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("GoogleTextE2E-\(UUID().uuidString)")
                .appendingPathExtension(
                    URL(fileURLWithPath: fixture.name).pathExtension
                )
            defer { try? FileManager.default.removeItem(at: destination) }

            let receipt = try await provider.download(
                item,
                exportFormat: nil,
                to: destination,
                progress: { _ in }
            )
            let origin = CloudDocumentOrigin(
                provider: .googleDrive,
                accountKey: account.stableAccountKey,
                remoteItemID: fixture.id,
                revision: item.revision,
                originalName: fixture.name,
                mimeType: fixture.mimeType
            )
            let result = try await DocumentImportPipeline().importDocument(
                DocumentImportRequest(
                    receipt: receipt,
                    origin: origin,
                    session: ImportSession(
                        epoch: UInt64(index + 1),
                        provider: .googleDrive,
                        scenario: nil,
                        mode: .read
                    )
                )
            )

            XCTAssertEqual(receipt.effectiveFormat, .text)
            XCTAssertEqual(result.format, .text)
            XCTAssertEqual(result.document.sourceKind, .text)
            XCTAssertEqual(result.document.origin, origin)
            XCTAssertTrue(result.document.fullText.contains(fixture.expectedText))
            XCTAssertEqual(try Data(contentsOf: destination), fixture.payload)
            XCTAssertFalse(result.document.readableParagraphs.isEmpty)
            XCTAssertTrue(transport.recordedRequests().allSatisfy {
                $0.url?.host == "drive.example"
            })
        }
    }

    func testAppOAuthFallbackRequiresExactRouteAndState() throws {
        let valid = try XCTUnwrap(URL(
            string: "com.example.drive:/oauth2redirect?state=current&code=c"
        ))
        let stale = try XCTUnwrap(URL(
            string: "com.example.drive:/oauth2redirect?state=old&code=c"
        ))
        let wrongRoute = try XCTUnwrap(URL(
            string: "com.example.drive:/other?state=current&code=c"
        ))

        XCTAssertTrue(GoogleDriveSystemWebAuthenticator.matches(
            valid,
            callbackScheme: "com.example.drive",
            redirectURI: "com.example.drive:/oauth2redirect",
            expectedState: "current"
        ))
        XCTAssertFalse(GoogleDriveSystemWebAuthenticator.matches(
            stale,
            callbackScheme: "com.example.drive",
            redirectURI: "com.example.drive:/oauth2redirect",
            expectedState: "current"
        ))
        XCTAssertFalse(GoogleDriveSystemWebAuthenticator.matches(
            wrongRoute,
            callbackScheme: "com.example.drive",
            redirectURI: "com.example.drive:/oauth2redirect",
            expectedState: "current"
        ))
    }

    func testForbiddenReasonsOnlyMapExplicitFileRestrictionsToDownloadNotAllowed() {
        XCTAssertEqual(
            GoogleDriveProvider.googleForbiddenError(
                data: Self.googleError(reason: "download_restricted_for_revision")
            ),
            .downloadNotAllowed
        )
        XCTAssertEqual(
            GoogleDriveProvider.googleForbiddenError(
                data: Self.googleError(reason: "insufficientFilePermissions")
            ),
            .provider(code: "google_insufficient_file_permissions", retryable: false)
        )
        XCTAssertEqual(
            GoogleDriveProvider.googleForbiddenError(
                data: Self.googleError(reason: "domainPolicy")
            ),
            .provider(code: "google_domain_policy", retryable: false)
        )
        XCTAssertEqual(
            GoogleDriveProvider.googleForbiddenError(
                data: Self.googleError(reason: "exportSizeLimitExceeded")
            ),
            .provider(code: "google_export_size_limit", retryable: false)
        )
    }

    func testUnknownGoogle403IsNotMisreportedAsFileDownloadRestriction() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: URL(string: "https://www.googleapis.com/drive/v3/files/id")!,
            statusCode: 403,
            httpVersion: nil,
            headerFields: nil
        ))

        XCTAssertThrowsError(
            try GoogleDriveProvider.validateAPIResponse(
                response,
                data: Self.googleError(reason: "forbidden")
            )
        ) { error in
            XCTAssertEqual(
                error as? CloudStorageError,
                .provider(code: "google_api_forbidden", retryable: false)
            )
        }
    }

    @MainActor
    func testEnsureConnectedUsesReadonlyOAuthWithoutPickerParameters() async throws {
        let store = GoogleDriveTestCredentialStore()
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            let state = try XCTUnwrap(authorizationURL.queryDictionary["state"])
            return try Self.oauthCallbackURL(
                state: state,
                code: "browse-code"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json(
                    """
                    {"access_token":"browse-access","refresh_token":"browse-refresh","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                return .json(
                    """
                    {"user":{"displayName":"Reader","emailAddress":"reader@example.com","permissionId":"permission-42"}}
                    """
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        let account = try await provider.ensureConnected()

        XCTAssertEqual(account.displayName, "Reader")
        XCTAssertEqual(
            provider.selectionCapability,
            .persistentConnectionAndNativeBrowser
        )
        let query = try XCTUnwrap(web.authorizationURL?.queryDictionary)
        XCTAssertEqual(
            query["scope"],
            GoogleDriveProvider.Configuration.driveReadonlyScope
        )
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "consent")
        XCTAssertNil(query["trigger_onepick"])
        XCTAssertNil(query["allow_multiple"])
        XCTAssertNil(query["mimetypes"])
        let loaded = await store.load()
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(
            saved.authorizedScopes,
            [GoogleDriveProvider.Configuration.driveReadonlyScope]
        )
    }

    @MainActor
    func testSecondConnectReplacesStaleOAuthInsteadOfReturningAuthorizationInProgress()
        async throws
    {
        let store = GoogleDriveTestCredentialStore()
        let web = GoogleDriveReplacingWebAuthenticator()
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json(
                    """
                    {"access_token":"replacement-access","refresh_token":"replacement-refresh","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                return .json(
                    """
                    {"user":{"displayName":"Reader","emailAddress":"reader@example.com","permissionId":"permission-42"}}
                    """
                )
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        let stale = Task { try await provider.ensureConnected() }
        while web.authenticationCount == 0 { await Task.yield() }

        let replacement = try await provider.ensureConnected()

        XCTAssertEqual(replacement.displayName, "Reader")
        XCTAssertEqual(web.authenticationCount, 2)
        XCTAssertEqual(web.cancellationCount, 1)
        do {
            _ = try await stale.value
            XCTFail("Expected the stale authorization to be cancelled")
        } catch let error as CloudStorageError {
            XCTAssertEqual(error, .userCancelled)
        }
    }

    @MainActor
    func testEnsureConnectedReusesPersistedReadonlyGrantWithoutOAuth() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: browserCredential(account: account)
        )
        let provider = makeProvider(
            transport: GoogleDriveTestTransport(dataHandler: { request in
                XCTFail("A valid persisted connection must not use the network: \(request)")
                return .json("{}", status: 500)
            }),
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )

        let first = try await provider.ensureConnected()
        let second = try await provider.ensureConnected()

        XCTAssertEqual(first, account)
        XCTAssertEqual(second, account)
    }

    @MainActor
    func testLegacyDriveFileCredentialRequiresReadonlyReauthorization() async throws {
        let account = testAccount()
        let legacy = credential(account: account, accessToken: "legacy-access")
        let store = GoogleDriveTestCredentialStore(credential: legacy)
        let provider = makeProvider(
            transport: GoogleDriveTestTransport(dataHandler: { request in
                XCTFail("Connection-state migration must be local: \(request)")
                return .json("{}", status: 500)
            }),
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )

        let state = await provider.connectionState()

        XCTAssertEqual(state, .needsReauthorization(account))
    }

    @MainActor
    func testReadonlyOAuthDoesNotReuseLegacyPickerRefreshToken() async throws {
        let account = testAccount()
        let legacy = credential(account: account, accessToken: "legacy-access")
        let store = GoogleDriveTestCredentialStore(credential: legacy)
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            try Self.oauthCallbackURL(
                state: XCTUnwrap(authorizationURL.queryDictionary["state"]),
                code: "readonly-code"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json("{\"access_token\":\"readonly-access\",\"expires_in\":3600}")
            case "/drive/v3/about":
                return .json("{\"user\":{\"permissionId\":\"permission-42\"}}")
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        await XCTAssertThrowsCloudError(
            try await provider.ensureConnected(),
            expected: .invalidResponse(code: "google_missing_refresh_token")
        )

        let retained = await store.load()
        XCTAssertEqual(retained, legacy)
    }

    @MainActor
    func testRootListShowsSharedEntryAndMapsAllFilesWithPagination() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: browserCredential(account: account)
        )
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            XCTAssertEqual(request.url?.path, "/drive/v3/files")
            XCTAssertEqual(
                request.url?.queryDictionary["q"],
                "'root' in parents and trashed = false"
            )
            XCTAssertEqual(request.url?.queryDictionary["corpora"], "user")
            XCTAssertEqual(request.url?.queryDictionary["pageSize"], "100")
            XCTAssertEqual(
                request.url?.queryDictionary["supportsAllDrives"],
                "true"
            )
            return .json(
                """
                {
                  "nextPageToken":"next-root",
                  "files":[
                    {"id":"folder-1","name":"Books","mimeType":"application/vnd.google-apps.folder","driveId":"shared-1"},
                    {"id":"pdf-1","name":"Guide.pdf","mimeType":"application/pdf","size":"120","version":"2","modifiedTime":"2026-08-10T08:00:00.000Z","capabilities":{"canDownload":true}},
                    {"id":"doc-1","name":"Notes","mimeType":"application/vnd.google-apps.document","capabilities":{"canDownload":true}},
                    {"id":"sheet-1","name":"Budget","mimeType":"application/vnd.google-apps.spreadsheet","capabilities":{"canDownload":true}},
                    {"id":"slides-1","name":"Pitch","mimeType":"application/vnd.google-apps.presentation","capabilities":{"canDownload":true}},
                    {"id":"drawing-1","name":"Diagram","mimeType":"application/vnd.google-apps.drawing","capabilities":{"canDownload":true}},
                    {"id":"form-1","name":"Survey","mimeType":"application/vnd.google-apps.form","capabilities":{"canDownload":true}},
                    {"id":"blocked-sheet","name":"Locked Budget","mimeType":"application/vnd.google-apps.spreadsheet","capabilities":{"canDownload":false}},
                    {"id":"txt-1","name":"Transcript.txt","mimeType":"text/plain","size":"80","capabilities":{"canDownload":true}},
                    {"id":"md-1","name":"README.md","mimeType":"text/markdown","size":"90","capabilities":{"canDownload":true}},
                    {"id":"rtf-1","name":"Formatted.rtf","mimeType":"application/rtf","size":"100","capabilities":{"canDownload":true}},
                    {"id":"blocked-text","name":"Blocked.txt","mimeType":"text/plain","size":"50","capabilities":{"canDownload":false}},
                    {"id":"zip-1","name":"Archive.zip","mimeType":"application/zip","size":"42","capabilities":{"canDownload":true}}
                  ]
                }
                """
            )
        })
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )

        let page = try await provider.list(folder: nil, cursor: nil)

        XCTAssertEqual(page.folders.map(\.id), [
            GoogleDriveProvider.sharedWithMeFolderID,
            "folder-1",
        ])
        XCTAssertEqual(page.items.map(\.name), [
            "Guide.pdf", "Notes", "Budget", "Pitch", "Diagram", "Survey",
            "Locked Budget", "Transcript.txt", "README.md", "Formatted.rtf",
            "Blocked.txt", "Archive.zip",
        ])
        XCTAssertEqual(page.items.map(\.kind), [
            .file, .exportableDocument, .exportableDocument,
            .exportableDocument, .exportableDocument, .unsupported,
            .exportableDocument, .file, .file, .file, .file, .unsupported,
        ])
        XCTAssertEqual(page.items[1].exportOptions, [.docx])
        XCTAssertEqual(page.items[2].exportOptions, [.pdf])
        XCTAssertEqual(page.items[3].exportOptions, [.pdf])
        XCTAssertEqual(page.items[4].exportOptions, [.pdf])
        XCTAssertEqual(page.items[6].exportOptions, [.pdf])
        XCTAssertEqual(page.nextCursor, CloudCursor(rawValue: "next-root"))
    }

    @MainActor
    func testSharedDriveListAndSearchUseDriveCorpusAndEscapedQuery() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: browserCredential(account: account)
        )
        let requestCounter = GoogleDriveTestCounter()
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            let call = await requestCounter.next()
            if call == 1 {
                XCTAssertEqual(request.url?.path, "/drive/v3/files")
                XCTAssertEqual(request.url?.queryDictionary["corpora"], "drive")
                XCTAssertEqual(request.url?.queryDictionary["driveId"], "drive-7")
                XCTAssertEqual(
                    request.url?.queryDictionary["q"],
                    "'drive-7' in parents and trashed = false"
                )
            } else {
                XCTAssertEqual(request.url?.queryDictionary["corpora"], "drive")
                XCTAssertEqual(request.url?.queryDictionary["driveId"], "drive-7")
                XCTAssertEqual(
                    request.url?.queryDictionary["q"],
                    "name contains 'Reader\\'s \\\\ Notes' and trashed = false"
                )
                XCTAssertEqual(request.url?.queryDictionary["pageToken"], "search-2")
            }
            return .json("{\"files\":[]}")
        })
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )
        let root = CloudFolder(
            provider: .googleDrive,
            accountKey: account.stableAccountKey,
            driveID: "drive-7",
            id: "root",
            name: "Team"
        )

        _ = try await provider.list(folder: root, cursor: nil)
        _ = try await provider.search(
            "Reader's \\ Notes",
            driveID: "drive-7",
            cursor: CloudCursor(rawValue: "search-2")
        )
    }

    @MainActor
    func testListDrivesReturnsMyDriveAndAllSharedDrivePages() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: browserCredential(account: account)
        )
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            XCTAssertEqual(request.url?.path, "/drive/v3/drives")
            if request.url?.queryDictionary["pageToken"] == nil {
                return .json(
                    """
                    {"nextPageToken":"drives-2","drives":[{"id":"drive-a","name":"Team A"}]}
                    """
                )
            }
            XCTAssertEqual(request.url?.queryDictionary["pageToken"], "drives-2")
            return .json(
                """
                {"drives":[{"id":"drive-b","name":"Team B"}]}
                """
            )
        })
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )

        let drives = try await provider.listDrives()

        XCTAssertEqual(drives.map(\.id), ["root", "drive-a", "drive-b"])
        XCTAssertTrue(drives[0].isDefault)
        XCTAssertEqual(drives.map(\.accountKey), Array(repeating: account.stableAccountKey, count: 3))
    }

    @MainActor
    func testAuthorizeAndPickUsesExactDriveFilePKCEContractAndPersistsSelection()
        async throws
    {
        let store = GoogleDriveTestCredentialStore()
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            let query = try XCTUnwrap(
                URLComponents(
                    url: authorizationURL,
                    resolvingAgainstBaseURL: false
                )?.queryDictionary
            )
            return try Self.callbackURL(
                state: XCTUnwrap(query["state"]),
                code: "authorization-code",
                fileID: "file-123"
            )
        }
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                switch (request.url?.host, request.url?.path) {
                case ("oauth.example", "/token"):
                    return .json(
                        """
                        {
                          "access_token": "access-1",
                          "refresh_token": "refresh-1",
                          "expires_in": 3600
                        }
                        """
                    )
                case ("drive.example", "/drive/v3/about"):
                    return .json(
                        """
                        {
                          "user": {
                            "displayName": "Reader",
                            "emailAddress": "reader@example.com",
                            "permissionId": "permission-42"
                          }
                        }
                        """
                    )
                case ("drive.example", "/drive/v3/files/file-123"):
                    return .json(Self.pdfMetadata(id: "file-123"))
                default:
                    XCTFail("Unexpected request: \(request)")
                    return .json("{}", status: 500)
                }
            }
        )
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: web
        )

        let selection = try await provider.authorizeAndPick()

        XCTAssertEqual(selection.account.provider, CloudProviderID.googleDrive)
        XCTAssertEqual(selection.account.displayName, "Reader")
        XCTAssertEqual(selection.account.maskedEmail, "r***@example.com")
        XCTAssertEqual(selection.item.id, "file-123")
        XCTAssertEqual(selection.item.driveID, "shared-drive-1")
        XCTAssertEqual(selection.item.resourceKey, "resource-key-1")
        XCTAssertEqual(selection.item.revision, "7|2026-08-10T08:00:00.000Z")
        XCTAssertEqual(selection.item.kind, CloudItemKind.file)
        XCTAssertEqual(selection.item.exportOptions, [CloudExportFormat]())

        let authorizationURL = try XCTUnwrap(web.authorizationURL)
        let query = try XCTUnwrap(
            URLComponents(
                url: authorizationURL,
                resolvingAgainstBaseURL: false
            )?.queryDictionary
        )
        XCTAssertEqual(query["client_id"], "drive-client.apps.googleusercontent.com")
        XCTAssertEqual(query["redirect_uri"], "com.example.drive:/oauth2redirect")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["scope"], GoogleDriveProvider.Configuration.driveFileScope)
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "consent")
        XCTAssertEqual(query["trigger_onepick"], "true")
        XCTAssertEqual(query["allow_multiple"], "false")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertFalse(try XCTUnwrap(query["code_challenge"]).isEmpty)
        XCTAssertFalse(try XCTUnwrap(query["state"]).isEmpty)
        XCTAssertEqual(
            Set(try XCTUnwrap(query["mimetypes"]).split(separator: ",").map(String.init)),
            [
                "application/pdf",
                "application/epub+zip",
                "application/vnd.google-apps.document",
                "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                "text/plain",
                "text/markdown",
                "application/rtf",
            ]
        )

        let requests: [URLRequest] = transport.recordedRequests()
        let tokenRequest: URLRequest = try XCTUnwrap(
            requests.first(where: { $0.url?.path == "/token" })
        )
        let form = tokenRequest.formDictionary
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], "authorization-code")
        XCTAssertEqual(form["redirect_uri"], "com.example.drive:/oauth2redirect")
        let verifier: String = try XCTUnwrap(form["code_verifier"])
        XCTAssertFalse(verifier.isEmpty)
        XCTAssertNil(form["client_secret"])

        let metadataRequest: URLRequest = try XCTUnwrap(
            requests.first(where: { $0.url?.path == "/drive/v3/files/file-123" })
        )
        XCTAssertEqual(metadataRequest.url?.queryDictionary["supportsAllDrives"], "true")
        XCTAssertTrue(
            metadataRequest.url?.queryDictionary["fields"]?.contains("resourceKey") == true
        )
        XCTAssertEqual(
            metadataRequest.value(forHTTPHeaderField: "Authorization"),
            "Bearer access-1"
        )

        let saved = await store.load()
        XCTAssertEqual(saved?.refreshToken, "refresh-1")
        XCTAssertEqual(saved?.rawPermissionID, "permission-42")
        let connectionState = await provider.connectionState()
        XCTAssertEqual(
            connectionState,
            CloudConnectionState.needsReauthorization(selection.account)
        )
    }

    @MainActor
    func testDifferentGoogleAccountStaysStagedUntilExplicitCommit() async throws {
        let originalAccount = testAccount()
        let originalCredential = credential(account: originalAccount, accessToken: "access-a")
        let store = GoogleDriveTestCredentialStore(credential: originalCredential)
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            let query = try XCTUnwrap(
                URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                    .queryDictionary
            )
            return try Self.callbackURL(
                state: XCTUnwrap(query["state"]),
                code: "authorization-b",
                fileID: "file-b"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json(
                    """
                    {"access_token":"access-b","refresh_token":"refresh-b","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                return .json(
                    """
                    {"user":{"displayName":"Other Reader","emailAddress":"other@example.com","permissionId":"permission-99"}}
                    """
                )
            case "/drive/v3/files/file-b":
                return .json(Self.pdfMetadata(id: "file-b"))
            case "/revoke":
                XCTAssertEqual(request.formDictionary["token"], "refresh-token")
                return .json("{}")
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        let staged = try await provider.authorizeAndPickPreservingExistingAccount(
            forceAccountSelection: true
        )

        XCTAssertTrue(staged.requiresAccountSwitchConfirmation)
        XCTAssertNotEqual(staged.account.stableAccountKey, originalAccount.stableAccountKey)
        let credentialBeforeCommit = await store.load()
        XCTAssertEqual(credentialBeforeCommit?.account, originalAccount)
        XCTAssertEqual(
            web.authorizationURL?.queryDictionary["prompt"],
            "select_account consent"
        )

        let committed = try await provider.commitStagedAccount()
        XCTAssertEqual(committed.account, staged.account)
        XCTAssertEqual(committed.item, staged.item)
        let credentialAfterCommit = await store.load()
        XCTAssertEqual(credentialAfterCommit?.account, staged.account)
        let revokeRequests = transport.recordedRequests().filter {
            $0.url?.path == "/revoke"
        }
        XCTAssertEqual(revokeRequests.count, 1)
        XCTAssertEqual(revokeRequests.first?.formDictionary["token"], "refresh-token")
    }

    @MainActor
    func testHistoryExpectedOwnerStillRequiresConfirmationWhenReplacingCurrentAccount()
        async throws
    {
        let expectedAccount = testAccount()
        let currentAccount = CloudAccount(
            provider: .googleDrive,
            stableAccountKey: CloudStableIdentifier.accountKey(
                provider: .googleDrive,
                rawAccountID: "permission-99"
            ),
            displayName: "Current B"
        )
        let currentCredential = GoogleDriveCredential(
            accessToken: "access-b",
            refreshToken: "refresh-b",
            expiresAt: now.addingTimeInterval(3_600),
            account: currentAccount,
            rawPermissionID: "permission-99"
        )
        let store = GoogleDriveTestCredentialStore(credential: currentCredential)
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            try Self.callbackURL(
                state: XCTUnwrap(authorizationURL.queryDictionary["state"]),
                code: "authorization-a",
                fileID: "file-a"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json(
                    """
                    {"access_token":"access-a","refresh_token":"refresh-a","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                return .json(
                    """
                    {"user":{"displayName":"Reader A","emailAddress":"a@example.com","permissionId":"permission-42"}}
                    """
                )
            case "/drive/v3/files/file-a":
                return .json(Self.pdfMetadata(id: "file-a"))
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        let selection = try await provider.authorizeAndPickPreservingExistingAccount(
            forceAccountSelection: true,
            expectedAccountKey: expectedAccount.stableAccountKey
        )

        XCTAssertEqual(selection.account.stableAccountKey, expectedAccount.stableAccountKey)
        XCTAssertTrue(selection.requiresAccountSwitchConfirmation)
        let durableBeforeConfirmation = await store.load()
        XCTAssertEqual(durableBeforeConfirmation?.account, currentAccount)
    }

    @MainActor
    func testHistoryExpectedOwnerRejectsPickerSelectionFromCurrentWrongAccount()
        async throws
    {
        let expectedAccount = testAccount()
        let currentAccount = CloudAccount(
            provider: .googleDrive,
            stableAccountKey: CloudStableIdentifier.accountKey(
                provider: .googleDrive,
                rawAccountID: "permission-99"
            )
        )
        let store = GoogleDriveTestCredentialStore(credential: GoogleDriveCredential(
            accessToken: "access-b",
            refreshToken: "refresh-b",
            expiresAt: now.addingTimeInterval(3_600),
            account: currentAccount,
            rawPermissionID: "permission-99"
        ))
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            try Self.callbackURL(
                state: XCTUnwrap(authorizationURL.queryDictionary["state"]),
                code: "authorization-b",
                fileID: "file-b"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json(
                    """
                    {"access_token":"access-b2","refresh_token":"refresh-b2","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                return .json(
                    """
                    {"user":{"permissionId":"permission-99"}}
                    """
                )
            case "/drive/v3/files/file-b":
                return .json(Self.pdfMetadata(id: "file-b"))
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        await XCTAssertThrowsCloudError(
            try await provider.authorizeAndPickPreservingExistingAccount(
                forceAccountSelection: true,
                expectedAccountKey: expectedAccount.stableAccountKey
            ),
            expected: .accountMismatch
        )

        let stagedCandidate = await provider.stagedCandidateAccount()
        XCTAssertNil(stagedCandidate)
        let durable = await store.load()
        XCTAssertEqual(durable?.account, currentAccount)
        XCTAssertEqual(durable?.refreshToken, "refresh-b")
        XCTAssertTrue(
            transport.recordedRequests().allSatisfy { $0.url?.path != "/revoke" }
        )
    }

    @MainActor
    func testDiscardStagedGoogleAccountRevokesCandidateAndKeepsPriorAccount()
        async throws
    {
        let originalAccount = testAccount()
        let originalCredential = credential(account: originalAccount, accessToken: "access-a")
        let store = GoogleDriveTestCredentialStore(credential: originalCredential)
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            let query = try XCTUnwrap(
                URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                    .queryDictionary
            )
            return try Self.callbackURL(
                state: XCTUnwrap(query["state"]),
                code: "authorization-b",
                fileID: "file-b"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json(
                    """
                    {"access_token":"access-b","refresh_token":"refresh-b","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                return .json(
                    """
                    {"user":{"displayName":"Other Reader","emailAddress":"other@example.com","permissionId":"permission-99"}}
                    """
                )
            case "/drive/v3/files/file-b":
                return .json(Self.pdfMetadata(id: "file-b"))
            case "/revoke":
                let active = await store.load()
                XCTAssertEqual(active?.account, originalAccount)
                XCTAssertEqual(request.formDictionary["token"], "refresh-b")
                return .json("{}", status: 503)
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        let staged = try await provider.authorizeAndPickPreservingExistingAccount(
            forceAccountSelection: true
        )
        XCTAssertTrue(staged.requiresAccountSwitchConfirmation)

        await provider.discardStagedAccount()

        let activeAfterDiscard = await store.load()
        XCTAssertEqual(activeAfterDiscard?.account, originalAccount)
        let revokeRequests = transport.recordedRequests().filter {
            $0.url?.path == "/revoke"
        }
        XCTAssertEqual(revokeRequests.count, 1)
        XCTAssertEqual(revokeRequests.first?.formDictionary["token"], "refresh-b")
        await XCTAssertThrowsCloudError(
            try await provider.commitStagedAccount(),
            expected: .invalidResponse(code: "google_candidate_missing")
        )
    }

    @MainActor
    func testCommitStagedGoogleAccountKeepsNewAccountWhenPriorRevocationFails()
        async throws
    {
        let originalAccount = testAccount()
        let originalCredential = credential(account: originalAccount, accessToken: "access-a")
        let store = GoogleDriveTestCredentialStore(credential: originalCredential)
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            let query = try XCTUnwrap(
                URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
                    .queryDictionary
            )
            return try Self.callbackURL(
                state: XCTUnwrap(query["state"]),
                code: "authorization-b",
                fileID: "file-b"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json(
                    """
                    {"access_token":"access-b","refresh_token":"refresh-b","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                return .json(
                    """
                    {"user":{"displayName":"Other Reader","emailAddress":"other@example.com","permissionId":"permission-99"}}
                    """
                )
            case "/drive/v3/files/file-b":
                return .json(Self.pdfMetadata(id: "file-b"))
            case "/revoke":
                let active = await store.load()
                XCTAssertEqual(active?.rawPermissionID, "permission-99")
                XCTAssertEqual(request.formDictionary["token"], "refresh-token")
                throw URLError(.notConnectedToInternet)
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        let staged = try await provider.authorizeAndPickPreservingExistingAccount(
            forceAccountSelection: true
        )
        let committed = try await provider.commitStagedAccount()

        XCTAssertEqual(committed.account, staged.account)
        let activeAfterCommit = await store.load()
        let stateAfterCommit = await provider.connectionState()
        XCTAssertEqual(activeAfterCommit?.account, staged.account)
        XCTAssertEqual(
            stateAfterCommit,
            CloudConnectionState.needsReauthorization(staged.account)
        )
        let revokeRequests = transport.recordedRequests().filter {
            $0.url?.path == "/revoke"
        }
        XCTAssertEqual(revokeRequests.count, 1)
        XCTAssertEqual(revokeRequests.first?.formDictionary["token"], "refresh-token")
    }

    @MainActor
    func testCallbackWithWrongStateStopsBeforeTokenExchange() async throws {
        let store = GoogleDriveTestCredentialStore()
        let web = GoogleDriveImmediateWebAuthenticator { _ in
            try Self.callbackURL(
                state: "forged-state",
                code: "authorization-code",
                fileID: "file-123"
            )
        }
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                XCTFail("No network request expected after state mismatch: \(request)")
                return .json("{}", status: 500)
            }
        )
        let provider = makeProvider(transport: transport, store: store, web: web)

        await XCTAssertThrowsCloudError(
            try await provider.authorizeAndPick(),
            expected: .invalidResponse(code: "google_state_mismatch")
        )
        XCTAssertTrue(transport.recordedRequests().isEmpty)
        let saved = await store.load()
        XCTAssertNil(saved)
    }

    @MainActor
    func testCancelledFirstAuthorizationAfterTokenExchangeRevokesTransientGrant()
        async throws
    {
        let store = GoogleDriveTestCredentialStore()
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            try Self.callbackURL(
                state: XCTUnwrap(authorizationURL.queryDictionary["state"]),
                code: "authorization-code",
                fileID: "file-123"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json(
                    """
                    {"access_token":"transient-access","refresh_token":"transient-refresh","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                throw CancellationError()
            case "/revoke":
                XCTAssertEqual(
                    request.formDictionary["token"],
                    "transient-refresh"
                )
                return .json("{}")
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        await XCTAssertThrowsCloudError(
            try await provider.authorizeAndPickPreservingExistingAccount(),
            expected: .userCancelled
        )

        XCTAssertEqual(
            transport.recordedRequests().filter { $0.url?.path == "/revoke" }.count,
            1
        )
        let saved = await store.load()
        XCTAssertNil(saved)
    }

    @MainActor
    func testAmbiguousCancelledAuthorizationNeverRevokesExistingGoogleAccount()
        async throws
    {
        let original = credential(account: testAccount(), accessToken: "active-access")
        let store = GoogleDriveTestCredentialStore(credential: original)
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            try Self.callbackURL(
                state: XCTUnwrap(authorizationURL.queryDictionary["state"]),
                code: "authorization-code",
                fileID: "file-123"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/token":
                return .json(
                    """
                    {"access_token":"ambiguous-access","refresh_token":"ambiguous-refresh","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                throw CancellationError()
            default:
                XCTFail("Existing authorization must not be revoked: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(transport: transport, store: store, web: web)

        await XCTAssertThrowsCloudError(
            try await provider.authorizeAndPickPreservingExistingAccount(
                forceAccountSelection: true
            ),
            expected: .userCancelled
        )

        XCTAssertTrue(
            transport.recordedRequests().allSatisfy { $0.url?.path != "/revoke" }
        )
        let saved = await store.load()
        XCTAssertEqual(saved, original)
    }

    @MainActor
    func testCallbackMustMatchConfiguredSchemeHostAndPath() async throws {
        for forgedRoute in [
            "forged.example.drive:/oauth2redirect",
            "com.example.drive:/different-path",
        ] {
            let store = GoogleDriveTestCredentialStore()
            let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
                let state = try XCTUnwrap(authorizationURL.queryDictionary["state"])
                var components = try XCTUnwrap(URLComponents(string: forgedRoute))
                components.queryItems = [
                    URLQueryItem(name: "state", value: state),
                    URLQueryItem(name: "code", value: "authorization-code"),
                    URLQueryItem(name: "picked_file_ids", value: "file-123"),
                ]
                return try XCTUnwrap(components.url)
            }
            let transport = GoogleDriveTestTransport(
                dataHandler: { request in
                    XCTFail("Forged callback must stop before network: \(request)")
                    return .json("{}", status: 500)
                }
            )
            let provider = makeProvider(transport: transport, store: store, web: web)

            await XCTAssertThrowsCloudError(
                try await provider.authorizeAndPick(),
                expected: .invalidResponse(code: "google_callback_route_mismatch")
            )
            XCTAssertTrue(transport.recordedRequests().isEmpty)
            let saved = await store.load()
            XCTAssertNil(saved)
        }
    }

    @MainActor
    func testGoogleDocsDownloadUsesDOCXExportAndResourceKey() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: credential(account: account, accessToken: "access-doc")
        )
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                guard request.url?.path == "/drive/v3/files/doc-1" else {
                    XCTFail("Unexpected data request: \(request)")
                    return .json("{}", status: 500)
                }
                return .json(Self.googleDocMetadata(id: "doc-1"))
            },
            downloadHandler: { request in
                XCTAssertEqual(request.url?.path, "/drive/v3/files/doc-1/export")
                XCTAssertEqual(
                    request.url?.queryDictionary["mimeType"],
                    GoogleDriveProvider.Configuration.docxMIMEType
                )
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "X-Goog-Drive-Resource-Keys"),
                    "doc-1/doc-resource-key"
                )
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer access-doc"
                )
                return .bytes(Data("docx-container".utf8), contentType: "application/octet-stream")
            }
        )
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )
        let item = CloudItem(
            provider: .googleDrive,
            accountKey: account.stableAccountKey,
            id: "doc-1",
            name: "Notes",
            mimeType: GoogleDriveProvider.Configuration.googleDocumentMIMEType,
            modifiedAt: now,
            revision: "8|2026-08-10T08:05:00.000Z",
            resourceKey: "doc-resource-key",
            kind: .exportableDocument,
            exportOptions: [.docx]
        )
        let destination = temporaryFile("Notes.docx")
        defer { try? FileManager.default.removeItem(at: destination.deletingLastPathComponent()) }

        let receipt = try await provider.download(
            item,
            exportFormat: .docx,
            to: destination
        )

        XCTAssertEqual(receipt.effectiveFilename, "Notes.docx")
        XCTAssertEqual(receipt.effectiveFormat, .docx)
        XCTAssertEqual(receipt.exportFormat, .docx)
        XCTAssertEqual(receipt.effectiveMIMEType, GoogleDriveProvider.Configuration.docxMIMEType)
        XCTAssertEqual(receipt.finalRevision, "9|2026-08-10T08:06:00.000Z")
        XCTAssertEqual(try Data(contentsOf: destination), Data("docx-container".utf8))
    }

    @MainActor
    func testSheetsSlidesAndDrawingsExportToPDF() async throws {
        let account = testAccount()
        let nativeFiles: [(id: String, name: String, mimeType: String)] = [
            (
                "sheet-1",
                "Budget",
                GoogleDriveProvider.Configuration.googleSpreadsheetMIMEType
            ),
            (
                "slides-1",
                "Pitch",
                GoogleDriveProvider.Configuration.googlePresentationMIMEType
            ),
            (
                "drawing-1",
                "Diagram",
                GoogleDriveProvider.Configuration.googleDrawingMIMEType
            ),
        ]

        for nativeFile in nativeFiles {
            let readablePDF = makeReadablePDFData(
                text: "Readable Google Workspace PDF \(nativeFile.id)"
            )
            let store = GoogleDriveTestCredentialStore(
                credential: credential(
                    account: account,
                    accessToken: "access-\(nativeFile.id)"
                )
            )
            let transport = GoogleDriveTestTransport(
                dataHandler: { request in
                    XCTAssertEqual(
                        request.url?.path,
                        "/drive/v3/files/\(nativeFile.id)"
                    )
                    return .json(
                        """
                        {
                          "id": "\(nativeFile.id)",
                          "name": "\(nativeFile.name)",
                          "mimeType": "\(nativeFile.mimeType)",
                          "modifiedTime": "2026-08-10T08:06:00.000Z",
                          "version": "9",
                          "resourceKey": "\(nativeFile.id)-resource-key",
                          "capabilities": {"canDownload": true}
                        }
                        """
                    )
                },
                downloadHandler: { request in
                    XCTAssertEqual(
                        request.url?.path,
                        "/drive/v3/files/\(nativeFile.id)/export"
                    )
                    XCTAssertEqual(
                        request.url?.queryDictionary["mimeType"],
                        GoogleDriveProvider.Configuration.pdfMIMEType
                    )
                    XCTAssertEqual(
                        request.value(
                            forHTTPHeaderField: "X-Goog-Drive-Resource-Keys"
                        ),
                        "\(nativeFile.id)/\(nativeFile.id)-resource-key"
                    )
                    return .bytes(
                        readablePDF,
                        contentType: GoogleDriveProvider.Configuration.pdfMIMEType
                    )
                }
            )
            let provider = makeProvider(
                transport: transport,
                store: store,
                web: GoogleDriveImmediateWebAuthenticator.unused
            )
            let item = CloudItem(
                provider: .googleDrive,
                accountKey: account.stableAccountKey,
                id: nativeFile.id,
                name: nativeFile.name,
                mimeType: nativeFile.mimeType,
                modifiedAt: now,
                revision: "8|2026-08-10T08:05:00.000Z",
                resourceKey: "\(nativeFile.id)-resource-key",
                kind: .exportableDocument,
                exportOptions: [.pdf]
            )
            let destination = temporaryFile("\(nativeFile.name).pdf")
            defer {
                try? FileManager.default.removeItem(
                    at: destination.deletingLastPathComponent()
                )
            }

            let receipt = try await provider.download(
                item,
                exportFormat: .pdf,
                to: destination
            )

            XCTAssertEqual(receipt.effectiveFilename, "\(nativeFile.name).pdf")
            XCTAssertEqual(receipt.effectiveFormat, .pdf)
            XCTAssertEqual(receipt.exportFormat, .pdf)
            XCTAssertEqual(
                receipt.effectiveMIMEType,
                GoogleDriveProvider.Configuration.pdfMIMEType
            )
            XCTAssertEqual(receipt.finalRevision, "9|2026-08-10T08:06:00.000Z")
            XCTAssertEqual(try Data(contentsOf: destination), readablePDF)
            XCTAssertEqual(
                transport.recordedRequests().map { $0.url?.path },
                [
                    "/drive/v3/files/\(nativeFile.id)",
                    "/drive/v3/files/\(nativeFile.id)/export",
                    "/drive/v3/files/\(nativeFile.id)",
                ]
            )

            let result = try await DocumentImportPipeline().importDocument(
                DocumentImportRequest(
                    receipt: receipt,
                    origin: CloudDocumentOrigin(
                        provider: .googleDrive,
                        accountKey: account.stableAccountKey,
                        remoteItemID: nativeFile.id,
                        revision: receipt.finalRevision,
                        originalName: nativeFile.name,
                        mimeType: nativeFile.mimeType
                    ),
                    session: ImportSession(
                        epoch: 1,
                        provider: .googleDrive,
                        scenario: nil,
                        mode: .read
                    )
                )
            )
            XCTAssertEqual(result.format, .pdf)
            XCTAssertTrue(
                result.document.fullText.contains(
                    "Readable Google Workspace PDF \(nativeFile.id)"
                )
            )
        }
    }

    @MainActor
    func testWorkspaceExportDefersCapabilityHintToContentEndpoint() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: credential(account: account, accessToken: "access-blocked")
        )
        let readablePDF = makeReadablePDFData(
            text: "Capability hint must not block an allowed export"
        )
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                XCTAssertEqual(request.url?.path, "/drive/v3/files/sheet-blocked")
                return .json(
                    """
                    {
                      "id": "sheet-blocked",
                      "name": "Locked Budget",
                      "mimeType": "application/vnd.google-apps.spreadsheet",
                      "version": "3",
                      "capabilities": {"canDownload": false}
                    }
                    """
                )
            },
            downloadHandler: { request in
                XCTAssertEqual(
                    request.url?.path,
                    "/drive/v3/files/sheet-blocked/export"
                )
                XCTAssertEqual(
                    request.url?.queryDictionary["mimeType"],
                    GoogleDriveProvider.Configuration.pdfMIMEType
                )
                return .bytes(
                    readablePDF,
                    contentType: GoogleDriveProvider.Configuration.pdfMIMEType
                )
            }
        )
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )
        let staleItem = CloudItem(
            provider: .googleDrive,
            accountKey: account.stableAccountKey,
            id: "sheet-blocked",
            name: "Locked Budget",
            mimeType: GoogleDriveProvider.Configuration.googleSpreadsheetMIMEType,
            kind: .exportableDocument,
            exportOptions: [.pdf]
        )
        let destination = temporaryFile("Locked Budget.pdf")
        defer {
            try? FileManager.default.removeItem(
                at: destination.deletingLastPathComponent()
            )
        }

        let receipt = try await provider.download(
            staleItem,
            exportFormat: .pdf,
            to: destination
        )

        XCTAssertEqual(receipt.effectiveFormat, .pdf)
        XCTAssertEqual(try Data(contentsOf: destination), readablePDF)
        XCTAssertEqual(
            transport.recordedRequests().map { $0.url?.path },
            [
                "/drive/v3/files/sheet-blocked",
                "/drive/v3/files/sheet-blocked/export",
                "/drive/v3/files/sheet-blocked",
            ]
        )
    }

    @MainActor
    func testBlobDownloadRefreshesOnceForConcurrentCallersAndUsesSharedDriveFlags()
        async throws
    {
        let account = testAccount()
        let expired = credential(
            account: account,
            accessToken: "expired-access",
            expiresAt: now.addingTimeInterval(-10)
        )
        let store = GoogleDriveTestCredentialStore(credential: expired)
        let refreshCounter = GoogleDriveTestCounter()
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                if request.url?.path == "/token" {
                    await refreshCounter.increment()
                    try await Task.sleep(nanoseconds: 80_000_000)
                    XCTAssertEqual(request.formDictionary["grant_type"], "refresh_token")
                    XCTAssertEqual(request.formDictionary["refresh_token"], "refresh-token")
                    return .json(
                        """
                        {"access_token":"fresh-access","expires_in":3600}
                        """
                    )
                }
                guard let fileID = request.url?.path.split(separator: "/").last else {
                    return .json("{}", status: 500)
                }
                return .json(Self.pdfMetadata(id: String(fileID), version: "11"))
            },
            downloadHandler: { request in
                XCTAssertEqual(request.url?.queryDictionary["alt"], "media")
                XCTAssertEqual(request.url?.queryDictionary["supportsAllDrives"], "true")
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "Authorization"),
                    "Bearer fresh-access"
                )
                let id = request.url?.path.split(separator: "/").last ?? "missing"
                XCTAssertEqual(
                    request.value(forHTTPHeaderField: "X-Goog-Drive-Resource-Keys"),
                    "\(id)/resource-key-1"
                )
                return .bytes(Data("pdf-\(id)".utf8), contentType: "application/pdf")
            }
        )
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )
        let first = pdfItem(id: "file-a", account: account)
        let second = pdfItem(id: "file-b", account: account)
        let firstURL = temporaryFile("a.pdf")
        let secondURL = temporaryFile("b.pdf")
        defer {
            try? FileManager.default.removeItem(at: firstURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: secondURL.deletingLastPathComponent())
        }

        async let firstReceipt: CloudDownloadReceipt = provider.download(first, to: firstURL)
        async let secondReceipt: CloudDownloadReceipt = provider.download(second, to: secondURL)
        let receipts = try await [firstReceipt, secondReceipt]

        XCTAssertEqual(receipts.map(\.effectiveFormat), [.pdf, .pdf])
        let refreshCount = await refreshCounter.currentValue()
        let refreshedCredential = await store.load()
        XCTAssertEqual(refreshCount, 1)
        XCTAssertEqual(refreshedCredential?.accessToken, "fresh-access")
    }

    @MainActor
    func testDownloadRetriesWhenRevisionChangesAndRecordsOnlyMatchingBytes() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: credential(account: account, accessToken: "access-current")
        )
        let metadataCounter = GoogleDriveTestCounter()
        let downloadCounter = GoogleDriveTestCounter()
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                XCTAssertEqual(request.url?.path, "/drive/v3/files/file-changing")
                let call = await metadataCounter.next()
                if call == 1 {
                    return .json(
                        Self.pdfMetadata(
                            id: "file-changing",
                            version: "7",
                            name: "Before.pdf",
                            modifiedTime: "2026-08-10T08:00:00.000Z"
                        )
                    )
                }
                return .json(
                    Self.pdfMetadata(
                        id: "file-changing",
                        version: "8",
                        name: "After.pdf",
                        modifiedTime: "2026-08-10T08:01:00.000Z"
                    )
                )
            },
            downloadHandler: { _ in
                let call = await downloadCounter.next()
                return .bytes(
                    Data((call == 1 ? "old-revision" : "new-revision").utf8),
                    contentType: "application/pdf"
                )
            }
        )
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )
        let destination = temporaryFile("download.pdf")
        defer {
            try? FileManager.default.removeItem(
                at: destination.deletingLastPathComponent()
            )
        }

        let receipt = try await provider.download(
            pdfItem(id: "file-changing", account: account),
            to: destination
        )

        let metadataCalls = await metadataCounter.currentValue()
        let downloadCalls = await downloadCounter.currentValue()
        XCTAssertEqual(metadataCalls, 3)
        XCTAssertEqual(downloadCalls, 2)
        XCTAssertEqual(receipt.effectiveFilename, "After.pdf")
        XCTAssertEqual(receipt.finalRevision, "8|2026-08-10T08:01:00.000Z")
        XCTAssertEqual(try Data(contentsOf: destination), Data("new-revision".utf8))
    }

    @MainActor
    func testFreshPDFMetadataControlsCapacityWhenHistoryStillSaysDOCX() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: credential(account: account, accessToken: "access-current")
        )
        let capacity = GoogleDriveCapacityPreflightRecorder()
        let pdfBytes: Int64 = 100 * 1_024 * 1_024
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                XCTAssertEqual(request.url?.path, "/drive/v3/files/file-renamed")
                return .json(Self.pdfMetadata(
                    id: "file-renamed",
                    name: "Current.pdf",
                    size: String(pdfBytes)
                ))
            },
            downloadHandler: { _ in
                .bytes(Data("current-pdf".utf8), contentType: "application/pdf")
            }
        )
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused,
            capacityPreflight: { expectedBytes, destination in
                try capacity.run(expectedBytes, destination)
            }
        )
        let staleDOCX = CloudItem(
            provider: .googleDrive,
            accountKey: account.stableAccountKey,
            id: "file-renamed",
            name: "Former.docx",
            mimeType: SupportedDocumentFormat.docx.preferredMIMEType,
            size: SupportedDocumentFormat.docx.maximumInputBytes + 1,
            revision: "old-revision",
            kind: .file
        )
        let destination = temporaryFile("Current.pdf")
        defer {
            try? FileManager.default.removeItem(
                at: destination.deletingLastPathComponent()
            )
        }

        let receipt = try await provider.download(staleDOCX, to: destination)

        XCTAssertEqual(receipt.effectiveFormat, .pdf)
        XCTAssertEqual(
            capacity.snapshot(),
            [.init(expectedBytes: pdfBytes, destination: destination)]
        )
    }

    @MainActor
    func testFreshMetadataDiskPreflightFailureStopsGoogleTransfer() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: credential(account: account, accessToken: "access-current")
        )
        let capacity = GoogleDriveCapacityPreflightRecorder(
            failure: .resourceLimitExceeded(.insufficientDeviceStorage)
        )
        let downloadCounter = GoogleDriveTestCounter()
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                XCTAssertEqual(request.url?.path, "/drive/v3/files/file-low-storage")
                return .json(Self.pdfMetadata(
                    id: "file-low-storage",
                    name: "Current.pdf",
                    size: "34567"
                ))
            },
            downloadHandler: { _ in
                await downloadCounter.increment()
                return .bytes(Data(), contentType: "application/pdf")
            }
        )
        let provider = makeProvider(
            transport: transport,
            store: store,
            web: GoogleDriveImmediateWebAuthenticator.unused,
            capacityPreflight: { expectedBytes, destination in
                try capacity.run(expectedBytes, destination)
            }
        )
        let destination = temporaryFile("Current.pdf")
        defer {
            try? FileManager.default.removeItem(
                at: destination.deletingLastPathComponent()
            )
        }

        do {
            _ = try await provider.download(
                pdfItem(id: "file-low-storage", account: account),
                to: destination
            )
            XCTFail("Expected low-storage rejection")
        } catch {
            XCTAssertEqual(
                error as? DocumentImportError,
                .resourceLimitExceeded(.insufficientDeviceStorage)
            )
        }

        let downloadCalls = await downloadCounter.currentValue()
        XCTAssertEqual(downloadCalls, 0)
        XCTAssertEqual(
            capacity.snapshot(),
            [.init(expectedBytes: 34_567, destination: destination)]
        )
    }

    @MainActor
    func testDisconnectDeletesLocalCredentialEvenWhenRemoteRevokeFails() async throws {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: credential(account: account, accessToken: "access-before-disconnect")
        )
        let revocationStore = GoogleDriveTestRevocationStore()
        let revokeCounter = GoogleDriveTestCounter()
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                XCTAssertEqual(request.url?.path, "/revoke")
                XCTAssertEqual(request.formDictionary["token"], "refresh-token")
                let attempt = await revokeCounter.next()
                return .json("{}", status: attempt == 1 ? 503 : 200)
            }
        )
        let provider = makeProvider(
            transport: transport,
            store: store,
            revocationStore: revocationStore,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )

        let result = await provider.disconnect()

        XCTAssertTrue(result.localAssociationRemoved)
        XCTAssertEqual(result.remoteRevocationStatus, CloudRemoteRevocationStatus.unconfirmed)
        XCTAssertTrue(result.retryable)
        XCTAssertEqual(result.diagnosticCode, "google_revoke_http_503")
        let saved = await store.load()
        let connectionState = await provider.connectionState()
        XCTAssertNil(saved)
        XCTAssertEqual(connectionState, CloudConnectionState.disconnected)

        // A fresh provider instance proves the revocation-only token survives
        // process reconstruction without restoring file access.
        let rebuilt = makeProvider(
            transport: transport,
            store: store,
            revocationStore: revocationStore,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )
        let retried = await rebuilt.retryPendingRevocations()
        XCTAssertEqual(retried.remoteRevocationStatus, .confirmed)
        XCTAssertFalse(retried.retryable)
        let revokeAttempts = await revokeCounter.currentValue()
        let remainingRevocations = await revocationStore.loadRecords()
        XCTAssertEqual(revokeAttempts, 2)
        XCTAssertTrue(remainingRevocations.isEmpty)
    }

    @MainActor
    func testAccountBoundaryClearsLocalCredentialWithoutRemoteRevocation()
        async throws
    {
        let account = testAccount()
        let store = GoogleDriveTestCredentialStore(
            credential: credential(account: account, accessToken: "local-only")
        )
        let revocationStore = GoogleDriveTestRevocationStore()
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            XCTFail("Account isolation must not make a remote request: \(request)")
            return .json("{}")
        })
        let provider = makeProvider(
            transport: transport,
            store: store,
            revocationStore: revocationStore,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )

        await provider.clearLocalAuthorizationForAccountBoundary()

        let savedCredential = await store.load()
        let state = await provider.connectionState()
        let pendingRevocations = await revocationStore.loadRecords()
        XCTAssertNil(savedCredential)
        XCTAssertEqual(state, .disconnected)
        XCTAssertTrue(pendingRevocations.isEmpty)
    }

    @MainActor
    func testPendingAccountARevocationSurvivesAccountBAuthorizationWithoutDisconnectingB()
        async throws
    {
        let accountA = testAccount()
        let credentialA = GoogleDriveCredential(
            accessToken: "access-a",
            refreshToken: "refresh-a",
            expiresAt: now.addingTimeInterval(3_600),
            account: accountA,
            rawPermissionID: "permission-42"
        )
        let store = GoogleDriveTestCredentialStore(credential: credentialA)
        let revocationStore = GoogleDriveTestRevocationStore()
        let revokeCounter = GoogleDriveTestCounter()
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            try Self.callbackURL(
                state: XCTUnwrap(authorizationURL.queryDictionary["state"]),
                code: "authorization-b",
                fileID: "file-b"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/revoke":
                XCTAssertEqual(request.formDictionary["token"], "refresh-a")
                let attempt = await revokeCounter.next()
                return .json("{}", status: attempt == 1 ? 503 : 200)
            case "/token":
                return .json(
                    """
                    {"access_token":"access-b","refresh_token":"refresh-b","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                return .json(
                    """
                    {"user":{"displayName":"Reader B","emailAddress":"b@example.com","permissionId":"permission-99"}}
                    """
                )
            case "/drive/v3/files/file-b":
                return .json(Self.pdfMetadata(id: "file-b"))
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(
            transport: transport,
            store: store,
            revocationStore: revocationStore,
            web: web
        )

        let disconnected = await provider.disconnect()
        XCTAssertEqual(disconnected.remoteRevocationStatus, .unconfirmed)

        let selection = try await provider.authorizeAndPick()
        XCTAssertNotEqual(
            selection.account.stableAccountKey,
            accountA.stableAccountKey
        )
        let stateWithPendingA = await provider.connectionState()
        XCTAssertEqual(stateWithPendingA, .needsReauthorization(selection.account))

        let pendingAfterB = await revocationStore.loadRecords()
        XCTAssertEqual(pendingAfterB.count, 1)
        XCTAssertEqual(pendingAfterB.first?.stableAccountKey, accountA.stableAccountKey)
        XCTAssertEqual(pendingAfterB.first?.token, "refresh-a")

        let retried = await provider.retryPendingRevocations()
        let pendingAfterRetry = await revocationStore.loadRecords()
        let revokeAttempts = await revokeCounter.currentValue()
        let stateAfterRetry = await provider.connectionState()
        let savedAfterRetry = await store.load()
        XCTAssertEqual(retried.remoteRevocationStatus, .confirmed)
        XCTAssertTrue(pendingAfterRetry.isEmpty)
        XCTAssertEqual(revokeAttempts, 2)
        XCTAssertEqual(stateAfterRetry, .needsReauthorization(selection.account))
        XCTAssertEqual(savedAfterRetry?.refreshToken, "refresh-b")
    }

    @MainActor
    func testSameAccountReauthorizationSupersedesOnlyItsPendingRevocation()
        async throws
    {
        let accountA = testAccount()
        let credentialA = GoogleDriveCredential(
            accessToken: "access-a-old",
            refreshToken: "refresh-a-old",
            expiresAt: now.addingTimeInterval(3_600),
            account: accountA,
            rawPermissionID: "permission-42"
        )
        let store = GoogleDriveTestCredentialStore(credential: credentialA)
        let revocationStore = GoogleDriveTestRevocationStore()
        let revokeCounter = GoogleDriveTestCounter()
        let web = GoogleDriveImmediateWebAuthenticator { authorizationURL in
            try Self.callbackURL(
                state: XCTUnwrap(authorizationURL.queryDictionary["state"]),
                code: "authorization-a-new",
                fileID: "file-a"
            )
        }
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            switch request.url?.path {
            case "/revoke":
                XCTAssertEqual(request.formDictionary["token"], "refresh-a-old")
                await revokeCounter.increment()
                return .json("{}", status: 503)
            case "/token":
                return .json(
                    """
                    {"access_token":"access-a-old","refresh_token":"refresh-a-old","expires_in":3600}
                    """
                )
            case "/drive/v3/about":
                return .json(
                    """
                    {"user":{"displayName":"Reader","emailAddress":"reader@example.com","permissionId":"permission-42"}}
                    """
                )
            case "/drive/v3/files/file-a":
                return .json(Self.pdfMetadata(id: "file-a"))
            default:
                XCTFail("Unexpected request: \(request)")
                return .json("{}", status: 500)
            }
        })
        let provider = makeProvider(
            transport: transport,
            store: store,
            revocationStore: revocationStore,
            web: web
        )

        let disconnected = await provider.disconnect()
        let pendingAfterDisconnect = await revocationStore.loadRecords()
        XCTAssertEqual(disconnected.remoteRevocationStatus, .unconfirmed)
        XCTAssertEqual(pendingAfterDisconnect.count, 1)

        let selection = try await provider.authorizeAndPick()
        let pendingAfterAuthorization = await revocationStore.loadRecords()
        let revokeAttemptsAfterAuthorization = await revokeCounter.currentValue()
        let stateAfterAuthorization = await provider.connectionState()
        let savedAfterAuthorization = await store.load()

        XCTAssertEqual(selection.account.stableAccountKey, accountA.stableAccountKey)
        XCTAssertTrue(pendingAfterAuthorization.isEmpty)
        XCTAssertEqual(revokeAttemptsAfterAuthorization, 1)
        XCTAssertEqual(
            stateAfterAuthorization,
            .needsReauthorization(selection.account)
        )
        XCTAssertEqual(savedAfterAuthorization?.refreshToken, "refresh-a-old")
        XCTAssertNotEqual(
            savedAfterAuthorization?.localGenerationID,
            credentialA.localGenerationID
        )

        // Retrying after the replacement must not send the old token to Google;
        // doing so can invalidate the newly issued grant for the same account.
        let retry = await provider.retryPendingRevocations()
        let finalRevokeAttempts = await revokeCounter.currentValue()
        XCTAssertEqual(retry.remoteRevocationStatus, .confirmed)
        XCTAssertEqual(finalRevokeAttempts, 1)
    }

    @MainActor
    func testColdStartDisconnectMarkerAppliesOnlyToExactCredentialGeneration()
        async throws
    {
        let accountA = testAccount()
        let credentialA = GoogleDriveCredential(
            accessToken: "access-a",
            refreshToken: "refresh-a",
            expiresAt: now.addingTimeInterval(3_600),
            account: accountA,
            rawPermissionID: "permission-42"
        )
        let record = GoogleDrivePendingRevocation(
            stableAccountKey: accountA.stableAccountKey,
            token: "refresh-a",
            disconnectedCredentialFingerprint:
                GoogleDriveProvider.revocationCredentialFingerprint(credentialA)
        )
        let store = GoogleDriveTestCredentialStore(credential: credentialA)
        let revocationStore = GoogleDriveTestRevocationStore(records: [record])
        let transport = GoogleDriveTestTransport(dataHandler: { request in
            XCTFail("Connection recovery must not use the network: \(request)")
            return .json("{}", status: 500)
        })
        let rebuilt = makeProvider(
            transport: transport,
            store: store,
            revocationStore: revocationStore,
            web: GoogleDriveImmediateWebAuthenticator.unused
        )

        let recoveredState = await rebuilt.connectionState()
        let recoveredCredential = await store.load()
        let remainingRecords = await revocationStore.loadRecords()
        XCTAssertEqual(recoveredState, .disconnected)
        XCTAssertNil(recoveredCredential)
        XCTAssertEqual(remainingRecords.first, record)
    }

    @MainActor
    func testDisconnectEpochPreventsStalePickerCallbackFromSavingCredentials() async throws {
        let store = GoogleDriveTestCredentialStore()
        let web = GoogleDriveSuspendingWebAuthenticator()
        let transport = GoogleDriveTestTransport(
            dataHandler: { request in
                XCTFail("Stale callback must stop before network: \(request)")
                return .json("{}", status: 500)
            }
        )
        let provider = makeProvider(transport: transport, store: store, web: web)
        let authorization = Task<(account: CloudAccount, item: CloudItem), Error> {
            try await provider.authorizeAndPick()
        }

        while web.authorizationURL == nil {
            await Task.yield()
        }
        _ = await provider.disconnect()
        let state = try XCTUnwrap(web.authorizationURL?.queryDictionary["state"])
        web.resume(
            with: try Self.callbackURL(
                state: state,
                code: "late-code",
                fileID: "late-file"
            )
        )

        do {
            _ = try await authorization.value
            XCTFail("Expected stale session")
        } catch let error as CloudStorageError {
            XCTAssertEqual(error, CloudStorageError.staleSession)
        }
        let saved = await store.load()
        XCTAssertNil(saved)
    }

    // MARK: Fixtures

    @MainActor
    private func makeProvider(
        transport: GoogleDriveTestTransport,
        store: GoogleDriveTestCredentialStore,
        revocationStore: any GoogleDriveRevocationStoring = GoogleDriveTestRevocationStore(),
        web: any GoogleDriveWebAuthenticating,
        capacityPreflight: @escaping CloudDownloadCapacityPreflight =
            CloudDownloadCapacityPolicy.live
    ) -> GoogleDriveProvider {
        let fixedNow = now
        return GoogleDriveProvider(
            configuration: GoogleDriveProvider.Configuration(
                clientID: "drive-client.apps.googleusercontent.com",
                redirectURI: "com.example.drive:/oauth2redirect",
                callbackScheme: "com.example.drive",
                authorizationEndpoint: URL(string: "https://oauth.example/auth")!,
                tokenEndpoint: URL(string: "https://oauth.example/token")!,
                revokeEndpoint: URL(string: "https://oauth.example/revoke")!,
                driveAPIBaseURL: URL(string: "https://drive.example/drive/v3")!
            ),
            transport: transport,
            credentialStore: store,
            revocationStore: revocationStore,
            webAuthenticator: web,
            now: { fixedNow },
            randomData: { count in
                Data((0..<count).map { UInt8($0 & 0xff) })
            },
            sleep: { _ in },
            capacityPreflight: capacityPreflight
        )
    }

    private func testAccount() -> CloudAccount {
        CloudAccount(
            provider: .googleDrive,
            stableAccountKey: CloudStableIdentifier.accountKey(
                provider: .googleDrive,
                rawAccountID: "permission-42"
            ),
            displayName: "Reader",
            maskedEmail: "r***@example.com"
        )
    }

    private func makeReadablePDFData(text: String) -> Data {
        let renderer = UIGraphicsPDFRenderer(
            // Keep the whole assertion string on the page. The previous
            // 320-point fixture clipped the Slides/Drawings suffix before
            // PDFKit extracted it, which made a healthy import look broken.
            bounds: CGRect(x: 0, y: 0, width: 640, height: 480)
        )
        return renderer.pdfData { context in
            context.beginPage()
            (text as NSString).draw(
                at: CGPoint(x: 24, y: 24),
                withAttributes: [.font: UIFont.systemFont(ofSize: 16)]
            )
        }
    }

    private func credential(
        account: CloudAccount,
        accessToken: String,
        expiresAt: Date? = nil
    ) -> GoogleDriveCredential {
        GoogleDriveCredential(
            accessToken: accessToken,
            refreshToken: "refresh-token",
            expiresAt: expiresAt ?? now.addingTimeInterval(3600),
            account: account,
            rawPermissionID: "permission-42"
        )
    }

    private func browserCredential(account: CloudAccount) -> GoogleDriveCredential {
        GoogleDriveCredential(
            accessToken: "browser-access",
            refreshToken: "browser-refresh",
            expiresAt: now.addingTimeInterval(3_600),
            account: account,
            rawPermissionID: "permission-42",
            authorizedScopes: [GoogleDriveProvider.Configuration.driveReadonlyScope]
        )
    }

    private func pdfItem(id: String, account: CloudAccount) -> CloudItem {
        CloudItem(
            provider: .googleDrive,
            accountKey: account.stableAccountKey,
            driveID: "shared-drive-1",
            id: id,
            name: "\(id).pdf",
            mimeType: "application/pdf",
            size: 100,
            modifiedAt: now,
            revision: "7|2026-08-10T08:00:00.000Z",
            resourceKey: "resource-key-1",
            kind: .file
        )
    }

    private func temporaryFile(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleDriveProviderTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(name)
    }

    private static func callbackURL(
        state: String,
        code: String,
        fileID: String
    ) throws -> URL {
        var components = URLComponents(string: "com.example.drive:/oauth2redirect")!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "picked_file_ids", value: fileID),
            URLQueryItem(
                name: "scope",
                value: GoogleDriveProvider.Configuration.driveFileScope
            ),
        ]
        return try XCTUnwrap(components.url)
    }

    private static func oauthCallbackURL(
        state: String,
        code: String
    ) throws -> URL {
        var components = URLComponents(string: "com.example.drive:/oauth2redirect")!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(
                name: "scope",
                value: GoogleDriveProvider.Configuration.driveReadonlyScope
            ),
        ]
        return try XCTUnwrap(components.url)
    }

    private static func pdfMetadata(
        id: String,
        version: String = "7",
        name: String? = nil,
        modifiedTime: String = "2026-08-10T08:00:00.000Z",
        size: String = "128"
    ) -> String {
        """
        {
          "id": "\(id)",
          "name": "\(name ?? "\(id).pdf")",
          "mimeType": "application/pdf",
          "size": "\(size)",
          "modifiedTime": "\(modifiedTime)",
          "version": "\(version)",
          "driveId": "shared-drive-1",
          "resourceKey": "resource-key-1",
          "capabilities": {"canDownload": true}
        }
        """
    }

    private static func googleDocMetadata(id: String) -> String {
        """
        {
          "id": "\(id)",
          "name": "Notes",
          "mimeType": "application/vnd.google-apps.document",
          "modifiedTime": "2026-08-10T08:06:00.000Z",
          "version": "9",
          "resourceKey": "doc-resource-key",
          "capabilities": {"canDownload": true}
        }
        """
    }

    private static func googleError(reason: String) -> Data {
        Data(
            """
            {"error":{"errors":[{"reason":"\(reason)"}]}}
            """.utf8
        )
    }
}

private final class GoogleDriveCapacityPreflightRecorder: @unchecked Sendable {
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

// MARK: - Test doubles

private actor GoogleDriveTestCredentialStore: GoogleDriveCredentialStoring {
    private var credential: GoogleDriveCredential?

    init(credential: GoogleDriveCredential? = nil) {
        self.credential = credential
    }

    func load() -> GoogleDriveCredential? { credential }
    func save(_ credential: GoogleDriveCredential) { self.credential = credential }
    func delete() { credential = nil }
    func replace(
        expected: GoogleDriveCredential?,
        with replacement: GoogleDriveCredential?
    ) -> Bool {
        guard credential == expected else { return false }
        credential = replacement
        return true
    }
}

private actor GoogleDriveTestRevocationStore: GoogleDriveRevocationStoring {
    private var records = Set<GoogleDrivePendingRevocation>()

    init(records: Set<GoogleDrivePendingRevocation> = []) {
        self.records = records
    }

    func loadRecords() -> Set<GoogleDrivePendingRevocation> { records }
    func saveRecords(_ records: Set<GoogleDrivePendingRevocation>) {
        self.records = records
    }
}

@MainActor
private final class GoogleDriveImmediateWebAuthenticator:
    GoogleDriveWebAuthenticating,
    @unchecked Sendable
{
    static var unused: GoogleDriveImmediateWebAuthenticator {
        GoogleDriveImmediateWebAuthenticator { _ in
            throw CloudStorageError.provider(
                code: "unexpected_google_web_auth",
                retryable: false
            )
        }
    }

    private let callback: (URL) throws -> URL
    private(set) var authorizationURL: URL?

    init(callback: @escaping (URL) throws -> URL) {
        self.callback = callback
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        authorizationURL = url
        return try callback(url)
    }

    func cancel() {}
}

@MainActor
private final class GoogleDriveSuspendingWebAuthenticator:
    GoogleDriveWebAuthenticating,
    @unchecked Sendable
{
    private(set) var authorizationURL: URL?
    private var continuation: CheckedContinuation<URL, Error>?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        authorizationURL = url
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func cancel() {
        // Deliberately leave the callback pending so the provider's epoch check
        // is exercised when a late system callback arrives.
    }

    func resume(with url: URL) {
        continuation?.resume(returning: url)
        continuation = nil
    }
}

@MainActor
private final class GoogleDriveReplacingWebAuthenticator:
    GoogleDriveWebAuthenticating,
    @unchecked Sendable
{
    private(set) var authenticationCount = 0
    private(set) var cancellationCount = 0
    private var continuation: CheckedContinuation<URL, Error>?

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        authenticationCount += 1
        if authenticationCount == 1 {
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
            }
        }

        guard let state = url.queryDictionary["state"] else {
            throw CloudStorageError.invalidResponse(code: "missing_test_state")
        }
        var components = URLComponents(string: "com.example.drive:/oauth2redirect")!
        components.queryItems = [
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code", value: "replacement-code"),
            URLQueryItem(
                name: "scope",
                value: GoogleDriveProvider.Configuration.driveReadonlyScope
            ),
        ]
        guard let callback = components.url else {
            throw CloudStorageError.invalidResponse(code: "invalid_test_callback")
        }
        return callback
    }

    func cancel() {
        cancellationCount += 1
        continuation?.resume(throwing: CloudStorageError.userCancelled)
        continuation = nil
    }
}

private final class GoogleDriveTestTransport: GoogleDriveHTTPTransport, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) async throws -> GoogleDriveTestReply

    private let dataHandler: Handler
    private let downloadHandler: Handler
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    init(
        dataHandler: @escaping Handler,
        downloadHandler: @escaping Handler = { _ in
            .bytes(Data(), contentType: "application/octet-stream")
        }
    ) {
        self.dataHandler = dataHandler
        self.downloadHandler = downloadHandler
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        record(request)
        let reply = try await dataHandler(request)
        return (reply.data, reply.response(for: request))
    }

    func download(
        for request: URLRequest,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> (URL, URLResponse) {
        record(request)
        let reply = try await downloadHandler(request)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("GoogleDriveTransport-\(UUID().uuidString)")
        try reply.data.write(to: url, options: .atomic)
        progress(
            CloudDownloadProgress(
                completedBytes: Int64(reply.data.count),
                totalBytes: Int64(reply.data.count)
            )
        )
        return (url, reply.response(for: request))
    }

    func recordedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    private func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }
}

private struct GoogleDriveTestReply: Sendable {
    let status: Int
    let headers: [String: String]
    let data: Data

    static func json(_ json: String, status: Int = 200) -> GoogleDriveTestReply {
        GoogleDriveTestReply(
            status: status,
            headers: ["Content-Type": "application/json"],
            data: Data(json.utf8)
        )
    }

    static func bytes(
        _ data: Data,
        contentType: String,
        status: Int = 200
    ) -> GoogleDriveTestReply {
        GoogleDriveTestReply(
            status: status,
            headers: ["Content-Type": contentType],
            data: data
        )
    }

    func response(for request: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }
}

private actor GoogleDriveTestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
    func next() -> Int {
        value += 1
        return value
    }
    func currentValue() -> Int { value }
}

private extension URLComponents {
    var queryDictionary: [String: String] {
        Dictionary(
            uniqueKeysWithValues: (queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
    }
}

private extension URL {
    var queryDictionary: [String: String] {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.queryDictionary ?? [:]
    }
}

private extension URLRequest {
    var formDictionary: [String: String] {
        guard let httpBody,
              let raw = String(data: httpBody, encoding: .utf8) else {
            return [:]
        }
        return raw.split(separator: "&").reduce(into: [:]) { result, pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = parts.first else { return }
            let value = parts.count > 1 ? String(parts[1]) : ""
            result[String(key).removingPercentEncoding ?? String(key)] =
                value.removingPercentEncoding ?? value
        }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsCloudError<T>(
        _ expression: @autoclosure () async throws -> T,
        expected: CloudStorageError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as CloudStorageError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}
