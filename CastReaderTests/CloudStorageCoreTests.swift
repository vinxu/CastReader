//
//  CloudStorageCoreTests.swift
//  CastReaderTests
//

import UIKit
import Security
import XCTest
import ZIPFoundation
@testable import CastReader

final class CloudStorageCoreTests: XCTestCase {
    func testDriveOAuthSchemeIsOwnedByAuthenticationSessionNotAppDeepLinks() throws {
        let urlTypes = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes")
                as? [[String: Any]]
        )
        let registeredSchemes = urlTypes.flatMap {
            $0["CFBundleURLSchemes"] as? [String] ?? []
        }

        XCTAssertTrue(registeredSchemes.contains("castreader"))
        XCTAssertFalse(
            registeredSchemes.contains(Constants.CloudStorage.GoogleDrive.redirectScheme)
        )
    }

    func testCloudDownloadDestinationPolicyAllowsMissingLeafInCreatedTemporaryParent()
        throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudDestinationPolicyTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let destination = directory.appendingPathComponent("document.docx")

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(CloudDownloadDestinationPolicy.allows(destination))
    }

    func testCloudDownloadDestinationPolicyRejectsSymlinkedParentEscape() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudDestinationPolicyTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let outsideDirectory = try XCTUnwrap(
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        )
            .appendingPathComponent("CloudDestinationPolicyTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: temporaryDirectory)
            try? FileManager.default.removeItem(at: outsideDirectory)
        }
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: outsideDirectory,
            withIntermediateDirectories: true
        )
        let linkedParent = temporaryDirectory.appendingPathComponent(
            "redirected",
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: linkedParent,
            withDestinationURL: outsideDirectory
        )

        XCTAssertFalse(CloudDownloadDestinationPolicy.allows(
            linkedParent.appendingPathComponent("document.pdf")
        ))
    }

    func testGoogleDriveCallbackMatcherAcceptsOnlyConfiguredScheme() throws {
        let callback = try XCTUnwrap(URL(
            string: "com.googleusercontent.apps.client:/oauth2redirect?state=s&code=c"
        ))

        XCTAssertTrue(GoogleDriveSystemWebAuthenticator.matches(
            callback,
            callbackScheme: "com.googleusercontent.apps.client"
        ))
        XCTAssertTrue(GoogleDriveSystemWebAuthenticator.matches(
            callback,
            callbackScheme: "COM.GOOGLEUSERCONTENT.APPS.CLIENT"
        ))
        XCTAssertFalse(GoogleDriveSystemWebAuthenticator.matches(
            callback,
            callbackScheme: "com.example.other"
        ))
        XCTAssertFalse(GoogleDriveSystemWebAuthenticator.matches(
            callback,
            callbackScheme: ""
        ))
    }

    @MainActor
    func testOAuthCallbackDeduplicatorForwardsIdenticalCallbackOnlyOnce() throws {
        let deduplicator = CloudOAuthCallbackDeduplicator(retentionInterval: 10)
        let callback = try XCTUnwrap(URL(
            string: "db-test://oauth?state=state-a&code=code-a"
        ))
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(deduplicator.shouldForward(callback, now: now))
        XCTAssertFalse(deduplicator.shouldForward(
            callback,
            now: now.addingTimeInterval(1)
        ))
    }

    @MainActor
    func testOAuthCallbackDeduplicatorDoesNotConflateDifferentStateOrCode() throws {
        let deduplicator = CloudOAuthCallbackDeduplicator(retentionInterval: 10)
        let now = Date(timeIntervalSince1970: 1_000)
        let first = try XCTUnwrap(URL(
            string: "db-test://oauth?state=state-a&code=code-a"
        ))
        let differentState = try XCTUnwrap(URL(
            string: "db-test://oauth?state=state-b&code=code-a"
        ))
        let differentCode = try XCTUnwrap(URL(
            string: "db-test://oauth?state=state-a&code=code-b"
        ))

        XCTAssertTrue(deduplicator.shouldForward(first, now: now))
        XCTAssertTrue(deduplicator.shouldForward(differentState, now: now))
        XCTAssertTrue(deduplicator.shouldForward(differentCode, now: now))
    }

    @MainActor
    func testOAuthCallbackDeduplicatorExpiresOldCallbackOwnership() throws {
        let deduplicator = CloudOAuthCallbackDeduplicator(retentionInterval: 10)
        let callback = try XCTUnwrap(URL(
            string: "db-test://oauth?state=state-a&code=code-a"
        ))
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(deduplicator.shouldForward(callback, now: now))
        XCTAssertTrue(deduplicator.shouldForward(
            callback,
            now: now.addingTimeInterval(10)
        ))
    }

    func testCloudFailurePresentationExplainsOrganizationPolicyWithoutRetry() {
        for code in ["google_domain_policy", "onedrive_admin_policy"] {
            let presentation = CloudFlowFailurePresentation.make(
                error: CloudStorageError.provider(code: code, retryable: false),
                hasRetrySelection: true
            )

            XCTAssertEqual(
                presentation.message,
                CloudLocalized("组织策略禁止 CastReader 访问此云盘，请联系组织管理员")
            )
            XCTAssertEqual(presentation.recovery, .close)
            XCTAssertFalse(presentation.showsRetry)
        }
    }

    func testCloudFailurePresentationExplainsGoogleExportLimitWithoutRetry() {
        let presentation = CloudFlowFailurePresentation.make(
            error: CloudStorageError.provider(
                code: "google_export_size_limit",
                retryable: false
            ),
            hasRetrySelection: true
        )

        XCTAssertEqual(
            presentation.message,
            CloudLocalized("此 Google 文档超过 Google Drive 的导出大小限制，无法导入")
        )
        XCTAssertEqual(presentation.recovery, .close)
        XCTAssertFalse(presentation.showsRetry)
    }

    func testCloudFailurePresentationDoesNotCallPendingOAuthAProviderRejection() {
        let presentation = CloudFlowFailurePresentation.make(
            error: CloudStorageError.provider(
                code: "google_authorization_in_progress",
                retryable: false
            ),
            hasRetrySelection: false
        )

        XCTAssertEqual(
            presentation.message,
            CloudLocalized("云盘暂时无法完成此操作，请重试")
        )
        XCTAssertEqual(presentation.recovery, .reconnect)
        XCTAssertTrue(presentation.showsRetry)
    }

    func testCloudFailurePresentationExplainsDisabledDriveAPIAsConfiguration() {
        let presentation = CloudFlowFailurePresentation.make(
            error: CloudStorageError.provider(
                code: "google_access_not_configured",
                retryable: false
            ),
            hasRetrySelection: false
        )

        XCTAssertEqual(
            presentation.message,
            CloudLocalized("该云盘尚未完成开发者配置，请稍后再试")
        )
        XCTAssertEqual(presentation.recovery, .close)
        XCTAssertFalse(presentation.showsRetry)
    }

    func testCloudFailurePresentationHidesRetryForPermanentProviderFailure() {
        let presentation = CloudFlowFailurePresentation.make(
            error: CloudStorageError.provider(
                code: "provider_permanent_test",
                retryable: false
            ),
            hasRetrySelection: true
        )

        XCTAssertEqual(
            presentation.message,
            CloudLocalized("云盘拒绝了此操作，请联系云盘管理员或稍后查看服务状态")
        )
        XCTAssertEqual(presentation.recovery, .close)
        XCTAssertFalse(presentation.showsRetry)
    }

    func testUnsupportedDocumentUsesGenericFormatCopyWithoutAFixedAllowlist() {
        let presentation = CloudFlowFailurePresentation.make(
            error: CloudStorageError.unsupportedItem,
            hasRetrySelection: false
        )

        XCTAssertEqual(
            presentation.message,
            CloudLocalized("此文件暂时无法朗读或解读")
        )
        XCTAssertEqual(presentation.recovery, .close)
    }

    @MainActor
    func testUnsupportedRowRemainsClickableAndPublishesAlertItem() {
        let model = CloudStorageFlowViewModel(
            provider: .googleDrive,
            scenario: nil,
            mode: .read,
            analyticsContext: nil
        )
        let item = CloudItem(
            provider: .googleDrive,
            accountKey: "account",
            id: "unsupported-archive",
            name: "Archive.zip",
            kind: .unsupported
        )

        model.choose(item)

        XCTAssertEqual(model.unsupportedItem, item)
        model.dismissUnsupportedItem()
        XCTAssertNil(model.unsupportedItem)
    }

    func testTextMIMEFallbackAndParserAwareFilenameNormalization() {
        let readableMIMEs = [
            "text/plain", "text/markdown", "text/html", "text/csv",
            "application/json", "application/xml", "application/rtf",
            "application/yaml",
        ]
        for mimeType in readableMIMEs {
            XCTAssertEqual(
                SupportedDocumentFormat.resolve(
                    filename: "Extensionless",
                    mimeType: mimeType
                ),
                .text,
                mimeType
            )
        }
        XCTAssertEqual(
            SupportedDocumentFormat.normalizedFilename(
                "Article",
                format: .text,
                mimeType: "text/html"
            ),
            "Article.html"
        )
        XCTAssertEqual(
            SupportedDocumentFormat.normalizedFilename(
                "Article.txt",
                format: .text,
                mimeType: "application/rtf"
            ),
            "Article.rtf"
        )
        XCTAssertNil(
            SupportedDocumentFormat.resolve(
                filename: "Archive.bin",
                mimeType: "application/octet-stream"
            )
        )
    }

    func testCloudFailurePresentationRetriesExactSelectionOnlyForTransientFailure() {
        let transientErrors: [CloudStorageError] = [
            .network(code: "offline"),
            .rateLimited(retryAfterSeconds: 5),
            .provider(code: "provider_503", retryable: true)
        ]

        for error in transientErrors {
            let withSelection = CloudFlowFailurePresentation.make(
                error: error,
                hasRetrySelection: true
            )
            XCTAssertEqual(withSelection.recovery, .retrySelection)
            XCTAssertTrue(withSelection.showsRetry)

            let withoutSelection = CloudFlowFailurePresentation.make(
                error: error,
                hasRetrySelection: false
            )
            XCTAssertEqual(withoutSelection.recovery, .reconnect)
            XCTAssertTrue(withoutSelection.showsRetry)
        }
    }

    func testCloudFailurePresentationDoesNotRedownloadResourceLimitFailures() {
        for reason in [
            DocumentResourceLimitReason.inputFileTooLarge,
            .archiveExpandedSizeTooLarge,
            .insufficientDeviceStorage
        ] {
            let presentation = CloudFlowFailurePresentation.make(
                error: DocumentImportError.resourceLimitExceeded(reason),
                hasRetrySelection: true
            )

            XCTAssertEqual(presentation.recovery, .close)
            XCTAssertFalse(presentation.showsRetry)
        }

        let storage = CloudFlowFailurePresentation.make(
            error: DocumentImportError.resourceLimitExceeded(.insufficientDeviceStorage),
            hasRetrySelection: true
        )
        XCTAssertEqual(
            storage.message,
            CloudLocalized("设备可用空间不足，请在系统设置中管理存储空间后再试")
        )
    }

    func testCloudFailurePresentationRetriesIncompleteDownloadOnlyWhenSelectionIsRetained() {
        let retained = CloudFlowFailurePresentation.make(
            error: DocumentImportError.byteCountMismatch(expected: 20, actual: 10),
            hasRetrySelection: true
        )
        XCTAssertEqual(retained.recovery, .retrySelection)
        XCTAssertTrue(retained.showsRetry)

        let lost = CloudFlowFailurePresentation.make(
            error: DocumentImportError.byteCountMismatch(expected: 20, actual: 10),
            hasRetrySelection: false
        )
        XCTAssertEqual(lost.recovery, .close)
        XCTAssertFalse(lost.showsRetry)
    }

    func testCloudHistoryFailureDoesNotOfferRetryForPermanentProviderFailure() throws {
        let now = Date()
        let record = HistoryRecord(
            id: "cloud-failure-history",
            title: "Remote document",
            sourceKindRaw: ReadingSourceKind.text.rawValue,
            sourceURL: nil,
            language: "en",
            createdAt: now,
            lastOpenedAt: now,
            coverPath: nil
        )

        let presentation = try XCTUnwrap(CloudHistoryFailurePresentation.make(
            record: record,
            error: CloudStorageError.provider(
                code: "onedrive_admin_policy",
                retryable: false
            )
        ))

        XCTAssertEqual(
            presentation.message,
            CloudLocalized("组织策略禁止 CastReader 访问此云盘，请联系组织管理员")
        )
        XCTAssertEqual(presentation.recovery, .dismiss)
    }

    func testTemporaryJanitorRemovesOnlyNamedCloudRoots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-janitor-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imports = root.appendingPathComponent("CastReaderCloudImports", isDirectory: true)
        let history = root.appendingPathComponent("CastReaderCloudHistoryReopen", isDirectory: true)
        let unrelated = root.appendingPathComponent("keep-me", isDirectory: true)
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)

        CloudTemporaryFileJanitor.removeAbandonedImports(temporaryRoot: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: imports.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: history.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testCloudTemporaryFilesAreExcludedFromBackup() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cloud-security-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try CloudTemporaryFileSecurity.prepareDirectory(directory)
        let file = directory.appendingPathComponent("document.pdf")
        try Data("temporary".utf8).write(to: file)
        try CloudTemporaryFileSecurity.secureFile(at: file)

        XCTAssertEqual(
            try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )
        XCTAssertEqual(
            try file.resourceValues(forKeys: [.isExcludedFromBackupKey])
                .isExcludedFromBackup,
            true
        )
    }

    func testCloudDownloadCapacityLeavesSafetyReserve() throws {
        XCTAssertNoThrow(try CloudTemporaryFileSecurity.requireCapacity(
            expectedBytes: 10 * 1_024 * 1_024,
            availableBytes: 80 * 1_024 * 1_024
        ))
        XCTAssertThrowsError(try CloudTemporaryFileSecurity.requireCapacity(
            expectedBytes: 20 * 1_024 * 1_024,
            availableBytes: 80 * 1_024 * 1_024
        )) { error in
            XCTAssertEqual(
                error as? DocumentImportError,
                .resourceLimitExceeded(.insufficientDeviceStorage)
            )
        }
    }

    func testStableIdentifiersSeparateAccountRevisionAndFormat() {
        let accountA = CloudStableIdentifier.accountKey(
            provider: .googleDrive,
            rawAccountID: "account-a"
        )
        let accountAAgain = CloudStableIdentifier.accountKey(
            provider: .googleDrive,
            rawAccountID: "account-a"
        )
        let accountB = CloudStableIdentifier.accountKey(
            provider: .googleDrive,
            rawAccountID: "account-b"
        )
        XCTAssertEqual(accountA, accountAAgain)
        XCTAssertNotEqual(accountA, accountB)
        XCTAssertEqual(accountA.count, 64)

        let documentID = CloudStableIdentifier.documentID(
            provider: .googleDrive,
            accountKey: accountA,
            driveID: "drive",
            remoteItemID: "item"
        )
        XCTAssertNotEqual(
            CloudStableIdentifier.contentSessionKey(
                documentID: documentID,
                revision: "1",
                format: .pdf
            ),
            CloudStableIdentifier.contentSessionKey(
                documentID: documentID,
                revision: "2",
                format: .pdf
            )
        )
        XCTAssertNotEqual(
            CloudStableIdentifier.contentSessionKey(
                documentID: documentID,
                revision: "1",
                format: .pdf
            ),
            CloudStableIdentifier.contentSessionKey(
                documentID: documentID,
                revision: "1",
                format: .docx
            )
        )
    }

    func testConnectionStorePersistsActiveAndUsesCandidateCommit() async throws {
        let suite = "CloudConnectionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "connections"
        let original = CloudAccount(
            provider: .dropbox,
            stableAccountKey: "old-account",
            displayName: "Old"
        )
        let candidate = CloudAccount(
            provider: .dropbox,
            stableAccountKey: "new-account",
            displayName: "New"
        )

        let store = CloudConnectionStore(defaults: defaults, storageKey: key)
        let firstEpoch = await store.setActive(original)
        await store.stageCandidate(candidate)
        let activeBeforeCommit = await store.activeAccount(for: .dropbox)
        XCTAssertEqual(activeBeforeCommit, original)

        let committed = await store.commitCandidate(for: .dropbox)
        XCTAssertEqual(committed, candidate)
        let secondEpoch = await store.connectionEpoch(for: .dropbox)
        XCTAssertGreaterThan(secondEpoch, firstEpoch)

        let reloaded = CloudConnectionStore(defaults: defaults, storageKey: key)
        let persisted = await reloaded.activeAccount(for: .dropbox)
        XCTAssertEqual(persisted, candidate)
        let removed = await reloaded.removeActive(for: .dropbox)
        XCTAssertEqual(removed, candidate)
        let afterRemoval = await reloaded.activeAccount(for: .dropbox)
        XCTAssertNil(afterRemoval)
    }

    func testCredentialOwnershipIsProviderScopedPersistentAndFailsClosed()
        throws
    {
        let suite = "CloudCredentialOwnershipTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let keyPrefix = "credential-owner"
        let scopeA = String(repeating: "a", count: 64)
        let scopeB = String(repeating: "b", count: 64)

        var store = CloudCredentialOwnershipStore(
            defaults: defaults,
            keyPrefix: keyPrefix
        )
        store.setOwnerStorageID(scopeA, for: .googleDrive)
        store.setOwnerStorageID(scopeB, for: .dropbox)
        XCTAssertEqual(store.ownerStorageID(for: .googleDrive), scopeA)
        XCTAssertEqual(store.ownerStorageID(for: .dropbox), scopeB)
        XCTAssertNil(store.ownerStorageID(for: .oneDrive))

        store = CloudCredentialOwnershipStore(
            defaults: defaults,
            keyPrefix: keyPrefix
        )
        XCTAssertEqual(store.ownerStorageID(for: .googleDrive), scopeA)
        store.removeOwner(for: .googleDrive)
        XCTAssertNil(store.ownerStorageID(for: .googleDrive))

        defaults.set("raw-user@example.com", forKey: "\(keyPrefix).onedrive")
        XCTAssertNil(
            store.ownerStorageID(for: .oneDrive),
            "Raw or malformed identities must never become credential owners"
        )
    }

    func testConnectionStoreRecoversProviderCommitAcrossProcessDeath() async throws {
        let suite = "CloudConnectionStoreCrashRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "connections"
        let accountA = CloudAccount(
            provider: .oneDrive,
            stableAccountKey: "account-a",
            displayName: "A"
        )
        let accountB = CloudAccount(
            provider: .oneDrive,
            stableAccountKey: "account-b",
            displayName: "B"
        )

        let beforeCrash = CloudConnectionStore(defaults: defaults, storageKey: key)
        _ = await beforeCrash.setActive(accountA)
        await beforeCrash.stageCandidate(accountB)

        // Provider commit completed, but Center.setActive(B) never ran.
        let relaunched = CloudConnectionStore(defaults: defaults, storageKey: key)
        let recoveryEpoch = await relaunched.connectionEpoch(for: .oneDrive)
        let recovered = await relaunched.reconcileObservedActiveAccount(
            accountB,
            preserveLiveCandidate: false,
            expectedEpoch: recoveryEpoch
        )
        XCTAssertEqual(recovered, accountB)
        let recoveredActive = await relaunched.activeAccount(for: .oneDrive)
        let recoveredCandidate = await relaunched.candidateAccount(for: .oneDrive)
        XCTAssertEqual(recoveredActive, accountB)
        XCTAssertNil(recoveredCandidate)
    }

    func testConnectionStoreDiscardsUnconfirmedCandidateAfterColdStart() async throws {
        let suite = "CloudConnectionStoreColdCandidate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "connections"
        let accountA = CloudAccount(provider: .dropbox, stableAccountKey: "account-a")
        let accountB = CloudAccount(provider: .dropbox, stableAccountKey: "account-b")

        let store = CloudConnectionStore(defaults: defaults, storageKey: key)
        _ = await store.setActive(accountA)
        await store.stageCandidate(accountB)

        let reconciliationEpoch = await store.connectionEpoch(for: .dropbox)
        let observed = await store.reconcileObservedActiveAccount(
            accountA,
            preserveLiveCandidate: false,
            expectedEpoch: reconciliationEpoch
        )
        XCTAssertEqual(observed, accountA)
        let remainingCandidate = await store.candidateAccount(for: .dropbox)
        XCTAssertNil(remainingCandidate)
    }

    func testConnectionStorePreservesCandidateWhileConfirmationIsLive() async throws {
        let suite = "CloudConnectionStoreLiveCandidate.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudConnectionStore(defaults: defaults, storageKey: "connections")
        let accountA = CloudAccount(provider: .googleDrive, stableAccountKey: "account-a")
        let accountB = CloudAccount(provider: .googleDrive, stableAccountKey: "account-b")
        _ = await store.setActive(accountA)
        await store.stageCandidate(accountB)

        let reconciliationEpoch = await store.connectionEpoch(for: .googleDrive)
        _ = await store.reconcileObservedActiveAccount(
            accountA,
            preserveLiveCandidate: true,
            expectedEpoch: reconciliationEpoch
        )
        let preservedCandidate = await store.candidateAccount(for: .googleDrive)
        XCTAssertEqual(preservedCandidate, accountB)
    }

    func testStaleReconciliationCannotResurrectDisconnectedAccount() async throws {
        let suite = "CloudConnectionStoreDisconnectCAS.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudConnectionStore(defaults: defaults, storageKey: "connections")
        let account = CloudAccount(provider: .dropbox, stableAccountKey: "account-a")
        _ = await store.setActive(account)
        let restoreEpoch = await store.connectionEpoch(for: .dropbox)

        _ = await store.removeActive(for: .dropbox)
        let staleResult = await store.reconcileObservedActiveAccount(
            account,
            preserveLiveCandidate: false,
            expectedEpoch: restoreEpoch
        )

        XCTAssertNil(staleResult)
        let activeAfterLateRestore = await store.activeAccount(for: .dropbox)
        XCTAssertNil(activeAfterLateRestore)
    }

    func testFormatSpecificInputCapsProtectDOCXRenderingPath() {
        XCTAssertEqual(SupportedDocumentFormat.pdf.maximumInputBytes, 200 * 1_024 * 1_024)
        XCTAssertEqual(SupportedDocumentFormat.docx.maximumInputBytes, 40 * 1_024 * 1_024)
        XCTAssertEqual(SupportedDocumentFormat.epub.maximumInputBytes, 120 * 1_024 * 1_024)

        let docx = CloudItem(
            provider: .dropbox,
            accountKey: "account",
            id: "docx",
            name: "Large.docx",
            kind: .file
        )
        XCTAssertEqual(
            DocumentResourceLimits.maximumInputBytes(for: docx, exportFormat: nil),
            SupportedDocumentFormat.docx.maximumInputBytes
        )
    }

    func testImportCoordinatorReplacementCancelsAndRejectsOldResult() async throws {
        let coordinator = CloudImportCoordinator()
        let first = await coordinator.begin(scenario: nil, mode: .read)
        let operation = Task {
            try await coordinator.run(for: first) {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "late"
            }
        }

        await Task.yield()
        let second = await coordinator.begin(scenario: .study, mode: .explain)
        do {
            _ = try await operation.value
            XCTFail("replaced session must not commit its late result")
        } catch let error as CloudImportCoordinationError {
            XCTAssertEqual(error, .staleSession)
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let firstIsCurrent = await coordinator.isCurrent(first)
        let secondIsCurrent = await coordinator.isCurrent(second)
        XCTAssertFalse(firstIsCurrent)
        XCTAssertTrue(secondIsCurrent)
        let didCancel = await coordinator.cancel(second)
        let current = await coordinator.currentSession()
        XCTAssertTrue(didCancel)
        XCTAssertNil(current)
    }

    func testValidatorRejectsSpoofedAndMismatchedFiles() throws {
        XCTAssertThrowsError(try DocumentFormatValidator.validate(
            data: Data("<html>sign in</html>".utf8),
            filename: "report.pdf",
            mimeType: "text/html",
            expectedFormat: .pdf
        )) { error in
            XCTAssertEqual(
                error as? DocumentImportError,
                .mimeTypeMismatch(expected: .pdf, actual: "text/html")
            )
        }

        let pdf = makePDFData()
        XCTAssertThrowsError(try DocumentFormatValidator.validate(
            data: pdf,
            filename: "report.epub",
            mimeType: "application/epub+zip",
            expectedFormat: .pdf
        )) { error in
            XCTAssertEqual(
                error as? DocumentImportError,
                .extensionMismatch(expected: .pdf, actual: "epub")
            )
        }
    }

    func testValidatorAcceptsValidPDFDOCXAndEPUBContainers() throws {
        let pdf = makePDFData()
        XCTAssertEqual(
            try DocumentFormatValidator.validate(
                data: pdf,
                filename: "sample.pdf",
                mimeType: "application/pdf"
            ).format,
            .pdf
        )

        let docx = try makeDOCXData()
        XCTAssertEqual(
            try DocumentFormatValidator.validate(
                data: docx,
                filename: "sample.docx",
                mimeType: SupportedDocumentFormat.docx.preferredMIMEType
            ).format,
            .docx
        )

        let epub = try makeMinimalEPUBData()
        XCTAssertEqual(
            try DocumentFormatValidator.validate(
                data: epub,
                filename: "sample.epub",
                mimeType: "application/epub+zip"
            ).format,
            .epub
        )
    }

    func testCloudDOCXPipelineUsesStableIdentityAndRemoteReference() async throws {
        let data = try makeDOCXData()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudStorageCoreTests-\(UUID().uuidString).docx")
        try data.write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let accountKey = CloudStableIdentifier.accountKey(
            provider: .dropbox,
            rawAccountID: "account"
        )
        let origin = CloudDocumentOrigin(
            provider: .dropbox,
            accountKey: accountKey,
            maskedAccountHint: "a***@example.com",
            remoteItemID: "id:document",
            revision: "old-revision",
            originalName: "Old name.docx",
            mimeType: "application/octet-stream",
            modifiedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let receipt = CloudDownloadReceipt(
            localURL: fileURL,
            effectiveFilename: "Cloud.docx",
            effectiveMIMEType: SupportedDocumentFormat.docx.preferredMIMEType,
            effectiveFormat: .docx,
            finalRevision: "final-revision",
            byteCount: Int64(data.count)
        )
        let session = ImportSession(
            epoch: 9,
            scenario: .study,
            mode: .explain
        )

        let result = try await DocumentImportPipeline().importDocument(
            DocumentImportRequest(receipt: receipt, origin: origin, session: session)
        )
        XCTAssertEqual(result.document.id, origin.stableDocumentID)
        XCTAssertEqual(result.document.title, "Cloud")
        XCTAssertEqual(result.document.sourceKind, .docx)
        XCTAssertEqual(result.document.fileData, data)
        XCTAssertEqual(result.persistencePolicy, .remoteReference)
        XCTAssertEqual(result.finalRevision, "final-revision")
        XCTAssertEqual(result.origin?.revision, "final-revision")
        XCTAssertEqual(result.origin?.originalName, "Cloud.docx")
        XCTAssertEqual(
            result.origin?.mimeType,
            SupportedDocumentFormat.docx.preferredMIMEType
        )
        XCTAssertEqual(result.origin?.maskedAccountHint, "a***@example.com")
        XCTAssertEqual(result.origin?.modifiedAt, origin.modifiedAt)
        XCTAssertEqual(
            result.contentSessionKey,
            CloudStableIdentifier.contentSessionKey(
                documentID: origin.stableDocumentID,
                revision: "final-revision",
                format: .docx
            )
        )
    }

    func testExportedOriginKeepsProviderMIMEWhileUpdatingNameAndRevision() {
        let origin = CloudDocumentOrigin(
            provider: .googleDrive,
            accountKey: "account",
            maskedAccountHint: "g***@example.com",
            remoteItemID: "google-doc",
            revision: "1",
            originalName: "Draft",
            mimeType: "application/vnd.google-apps.document"
        )

        let updated = origin.replacingDownloadedMetadata(
            revision: "2",
            effectiveFilename: "Renamed.docx",
            effectiveMIMEType: SupportedDocumentFormat.docx.preferredMIMEType,
            isExport: true
        )

        XCTAssertEqual(updated.originalName, "Renamed.docx")
        XCTAssertEqual(updated.revision, "2")
        XCTAssertEqual(updated.mimeType, "application/vnd.google-apps.document")
        XCTAssertEqual(updated.maskedAccountHint, "g***@example.com")
    }

    @MainActor
    func testQuickReadDoesNotExposeCloudStableIdentityOrFilename() {
        let origin = CloudDocumentOrigin(
            provider: .oneDrive,
            accountKey: "derived-account-key",
            driveID: "drive-id",
            remoteItemID: "remote-item-id",
            originalName: "Confidential Plan.pdf",
            mimeType: SupportedDocumentFormat.pdf.preferredMIMEType
        )
        let cloudDocument = ReadingDocument(
            id: origin.stableDocumentID,
            title: "Confidential Plan",
            sourceKind: .pdf,
            paragraphs: [ReadingParagraph(id: 0, text: "Allowed document text")],
            origin: origin,
            effectiveFormat: .pdf
        )

        XCTAssertEqual(
            ExplainViewModel.quickReadSourceURL(for: cloudDocument),
            "castreader://cloud-document"
        )
        XCTAssertEqual(
            ExplainViewModel.quickReadTitle(for: cloudDocument),
            "Cloud document"
        )
        XCTAssertFalse(
            ExplainViewModel.quickReadSourceURL(for: cloudDocument)
                .contains(origin.stableDocumentID)
        )
        XCTAssertFalse(
            ExplainViewModel.quickReadTitle(for: cloudDocument)
                .contains("Confidential")
        )

        let localDocument = ReadingDocument(
            id: "local-id",
            title: "Local title",
            sourceKind: .text,
            paragraphs: [ReadingParagraph(id: 0, text: "Local text")]
        )
        XCTAssertEqual(
            ExplainViewModel.quickReadSourceURL(for: localDocument),
            "castreader://doc/local-id"
        )
        XCTAssertEqual(ExplainViewModel.quickReadTitle(for: localDocument), "Local title")
    }

    func testGoogleDriveQuickReadUsesLimitedUseGlobalService() {
        let googleOrigin = CloudDocumentOrigin(
            provider: .googleDrive,
            accountKey: "google-account",
            remoteItemID: "drive-file",
            originalName: "Document.txt",
            mimeType: SupportedDocumentFormat.text.preferredMIMEType
        )
        let googleDocument = ReadingDocument(
            title: "Document",
            sourceKind: .text,
            paragraphs: [ReadingParagraph(id: 0, text: "Workspace-derived text")],
            origin: googleOrigin
        )
        let localDocument = ReadingDocument(
            title: "Local",
            sourceKind: .text,
            paragraphs: [ReadingParagraph(id: 0, text: "Local text")]
        )

        XCTAssertTrue(
            QuickReadService.forDocument(googleDocument)
                === QuickReadService.googleLimitedUse
        )
        XCTAssertTrue(
            QuickReadService.forDocument(localDocument)
                === QuickReadService.shared
        )
    }

    private func makePDFData() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 480))
        return renderer.pdfData { context in
            context.beginPage()
            ("Cloud import validation" as NSString).draw(
                at: CGPoint(x: 24, y: 24),
                withAttributes: [.font: UIFont.systemFont(ofSize: 16)]
            )
        }
    }

    private func makeDOCXData() throws -> Data {
        try makeZIP(entries: [
            "[Content_Types].xml": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
                  <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
                </Types>
                """.utf8),
            "word/document.xml": Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
                  <w:body><w:p><w:r><w:t>Cloud title</w:t></w:r></w:p></w:body>
                </w:document>
                """.utf8)
        ])
    }

    private func makeMinimalEPUBData() throws -> Data {
        try makeZIP(entries: [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("""
                <?xml version="1.0"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
                </container>
                """.utf8)
        ])
    }

    private func makeZIP(entries: [String: Data]) throws -> Data {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CloudStorageCoreTests-\(UUID().uuidString)", isDirectory: true)
        let zipURL = root.appendingPathExtension("zip")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: zipURL)
        }

        for (path, data) in entries {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url)
        }
        let archive = try Archive(url: zipURL, accessMode: .create)
        for path in entries.keys.sorted() {
            try archive.addEntry(with: path, relativeTo: root)
        }
        return try Data(contentsOf: zipURL)
    }
}

final class KeychainStoreTests: XCTestCase {
    private let service = "ai.castreader.auth"
    private let privateGroup = "TEAM123.com.same.castreader"
    private let legacyMSALGroup = "TEAM123.com.microsoft.adalcache"

    func testAccessGroupConfigurationUsesApplicationIdentifierAndRejectsPlaceholders() throws {
        let configuration = try XCTUnwrap(
            KeychainAccessGroupConfiguration(
                privateAccessGroup: privateGroup,
                bundleIdentifier: "com.same.castreader"
            )
        )
        XCTAssertEqual(configuration.privateAccessGroup, privateGroup)
        XCTAssertEqual(configuration.legacyAccessGroups, [legacyMSALGroup])
        XCTAssertNil(
            KeychainAccessGroupConfiguration(
                privateAccessGroup: "$(AppIdentifierPrefix)com.same.castreader",
                bundleIdentifier: "com.same.castreader"
            )
        )
        XCTAssertNil(
            KeychainAccessGroupConfiguration(
                privateAccessGroup: "TEAM123.com.someone.else",
                bundleIdentifier: "com.same.castreader"
            )
        )
    }

    func testSetWritesOnlyPrivateGroupAndRemovesLegacyCastReaderCopy() throws {
        let client = FakeKeychainItemClient()
        client.seed(
            "old",
            service: service,
            account: "token",
            group: legacyMSALGroup
        )
        let repository = makeRepository(client: client)

        XCTAssertTrue(
            repository.set(
                "new",
                for: "token",
                accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
            )
        )

        XCTAssertEqual(client.value(service: service, account: "token", group: privateGroup), "new")
        XCTAssertNil(client.value(service: service, account: "token", group: legacyMSALGroup))
        XCTAssertEqual(client.writes.map(\.accessGroup), [privateGroup])
        XCTAssertTrue(client.deletes.contains { $0.accessGroup == legacyMSALGroup })
    }

    func testGetReadsExistingAppIdentifierItemAndCleansLegacyDuplicate() {
        let client = FakeKeychainItemClient()
        client.seed("private", service: service, account: "token", group: privateGroup)
        client.seed("stale", service: service, account: "token", group: legacyMSALGroup)
        let repository = makeRepository(client: client)

        XCTAssertEqual(repository.get("token"), "private")
        XCTAssertEqual(client.reads.map(\.accessGroup), [privateGroup])
        XCTAssertNil(client.value(service: service, account: "token", group: legacyMSALGroup))
    }

    func testGetMigratesLegacyADALItemAndPreservesAccessibility() {
        let client = FakeKeychainItemClient()
        let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        client.seed(
            "legacy-secret",
            service: service,
            account: "token",
            group: legacyMSALGroup,
            accessibility: accessibility
        )
        let repository = makeRepository(client: client)

        XCTAssertEqual(repository.get("token"), "legacy-secret")
        XCTAssertEqual(
            client.item(service: service, account: "token", group: privateGroup),
            KeychainStoredItem(data: Data("legacy-secret".utf8), accessibility: accessibility)
        )
        XCTAssertNil(client.item(service: service, account: "token", group: legacyMSALGroup))
        XCTAssertEqual(client.reads.map(\.accessGroup), [privateGroup, legacyMSALGroup])
        XCTAssertEqual(client.writes.map(\.accessGroup), [privateGroup])
    }

    func testFailedMigrationKeepsLegacyItemReadable() {
        let client = FakeKeychainItemClient()
        client.seed("legacy-secret", service: service, account: "token", group: legacyMSALGroup)
        client.writeStatus = errSecMissingEntitlement
        let repository = makeRepository(client: client)

        XCTAssertEqual(repository.get("token"), "legacy-secret")
        XCTAssertNil(client.item(service: service, account: "token", group: privateGroup))
        XCTAssertEqual(
            client.value(service: service, account: "token", group: legacyMSALGroup),
            "legacy-secret"
        )
    }

    func testDeleteTargetsPrivateAndLegacyGroups() {
        let client = FakeKeychainItemClient()
        client.seed("private", service: service, account: "token", group: privateGroup)
        client.seed("legacy", service: service, account: "token", group: legacyMSALGroup)
        let repository = makeRepository(client: client)

        repository.delete("token")

        XCTAssertNil(client.item(service: service, account: "token", group: privateGroup))
        XCTAssertNil(client.item(service: service, account: "token", group: legacyMSALGroup))
        XCTAssertEqual(Set(client.deletes.map(\.accessGroup)), Set([privateGroup, legacyMSALGroup]))
    }

    func testSignedHostStoresCastReaderSecretOnlyInPrivateGroup() throws {
        let configuration = try XCTUnwrap(KeychainAccessGroupConfiguration.current())
        let account = "keychain-access-group-test-\(UUID().uuidString)"
        defer { KeychainStore.delete(account) }

        XCTAssertTrue(
            KeychainStore.set(
                "private-secret",
                for: account,
                accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            )
        )
        XCTAssertEqual(KeychainStore.get(account), "private-secret")
        XCTAssertEqual(
            copyStatus(account: account, group: configuration.privateAccessGroup),
            errSecSuccess
        )
        for legacyGroup in configuration.legacyAccessGroups {
            XCTAssertEqual(copyStatus(account: account, group: legacyGroup), errSecItemNotFound)
        }
    }

    func testSignedHostMigratesLegacyADALSecretIntoPrivateGroup() throws {
        let configuration = try XCTUnwrap(KeychainAccessGroupConfiguration.current())
        let legacyGroup = try XCTUnwrap(configuration.legacyAccessGroups.first)
        let account = "keychain-legacy-migration-test-\(UUID().uuidString)"
        let accessibility = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        defer { KeychainStore.delete(account) }

        let legacyItem: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: legacyGroup,
            kSecValueData as String: Data("legacy-secret".utf8),
            kSecAttrAccessible as String: accessibility
        ]
        XCTAssertEqual(SecItemAdd(legacyItem as CFDictionary, nil), errSecSuccess)

        XCTAssertEqual(KeychainStore.get(account), "legacy-secret")
        XCTAssertEqual(copyStatus(account: account, group: legacyGroup), errSecItemNotFound)
        let migrated = try XCTUnwrap(copyItem(account: account, group: configuration.privateAccessGroup))
        XCTAssertEqual(String(data: migrated.data, encoding: .utf8), "legacy-secret")
        XCTAssertEqual(migrated.accessibility, accessibility)
    }

    private func makeRepository(client: FakeKeychainItemClient) -> KeychainRepository {
        KeychainRepository(
            service: service,
            configuration: KeychainAccessGroupConfiguration(
                privateAccessGroup: privateGroup,
                bundleIdentifier: "com.same.castreader"
            )!,
            client: client
        )
    }

    private func copyStatus(account: String, group: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result)
    }

    private func copyItem(account: String, group: String) -> KeychainStoredItem? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group,
            kSecReturnData as String: true,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let attributes = result as? [String: Any],
              let data = attributes[kSecValueData as String] as? Data,
              let accessibility = attributes[kSecAttrAccessible as String] as? String else {
            return nil
        }
        return KeychainStoredItem(data: data, accessibility: accessibility)
    }
}

private final class FakeKeychainItemClient: KeychainItemClient {
    struct Location: Hashable {
        let service: String
        let account: String
        let accessGroup: String
    }

    struct Write {
        let location: Location
        let item: KeychainStoredItem

        var accessGroup: String { location.accessGroup }
    }

    private var items: [Location: KeychainStoredItem] = [:]
    var reads: [Location] = []
    var writes: [Write] = []
    var deletes: [Location] = []
    var writeStatus: OSStatus = errSecSuccess

    func seed(
        _ value: String,
        service: String,
        account: String,
        group: String,
        accessibility: String = kSecAttrAccessibleAfterFirstUnlock as String
    ) {
        items[Location(service: service, account: account, accessGroup: group)] =
            KeychainStoredItem(data: Data(value.utf8), accessibility: accessibility)
    }

    func item(service: String, account: String, group: String) -> KeychainStoredItem? {
        items[Location(service: service, account: account, accessGroup: group)]
    }

    func value(service: String, account: String, group: String) -> String? {
        item(service: service, account: account, group: group)
            .flatMap { String(data: $0.data, encoding: .utf8) }
    }

    func read(service: String, account: String, accessGroup: String) -> KeychainStoredItem? {
        let location = Location(service: service, account: account, accessGroup: accessGroup)
        reads.append(location)
        return items[location]
    }

    func write(
        data: Data,
        service: String,
        account: String,
        accessGroup: String,
        accessibility: String
    ) -> OSStatus {
        let location = Location(service: service, account: account, accessGroup: accessGroup)
        let item = KeychainStoredItem(data: data, accessibility: accessibility)
        writes.append(Write(location: location, item: item))
        guard writeStatus == errSecSuccess else { return writeStatus }
        items[location] = item
        return errSecSuccess
    }

    func delete(service: String, account: String, accessGroup: String) -> OSStatus {
        let location = Location(service: service, account: account, accessGroup: accessGroup)
        deletes.append(location)
        return items.removeValue(forKey: location) == nil ? errSecItemNotFound : errSecSuccess
    }
}
