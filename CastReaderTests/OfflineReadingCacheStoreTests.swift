import CryptoKit
import Foundation
import XCTest
@testable import CastReader

private final class OfflineReadingCacheTestClock: OfflineReadingCacheClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval = 1) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private final class OfflineReadingCacheFaultScript: @unchecked Sendable {
    private let lock = NSLock()
    private let target: OfflineReadingCacheFaultPoint
    private let failure: OfflineReadingCacheInjectedFailure
    private var remainingFailures: Int

    init(
        target: OfflineReadingCacheFaultPoint,
        failure: OfflineReadingCacheInjectedFailure = .io,
        failureCount: Int = 1
    ) {
        self.target = target
        self.failure = failure
        remainingFailures = failureCount
    }

    func handle(_ point: OfflineReadingCacheFaultPoint) throws {
        lock.lock()
        let shouldFail = point == target && remainingFailures > 0
        if shouldFail { remainingFailures -= 1 }
        lock.unlock()
        if shouldFail { throw failure }
    }
}

private final class OfflineReadingCacheCommitBarrier: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var shouldBlock = true

    func handle(_ point: OfflineReadingCacheFaultPoint) {
        guard point == .beforeManifestWrite(.publish) else { return }
        lock.lock()
        let blockThisCommit = shouldBlock
        shouldBlock = false
        lock.unlock()
        guard blockThisCommit else { return }
        entered.signal()
        release.wait()
    }
}

final class OfflineReadingCacheStoreTests: XCTestCase {
    func testAccountPathUsesOpaqueStorageIDAndCacheRootExcludesBackup() throws {
        let fixture = try makeFixture()
        let storageID = String(repeating: "a", count: 64)
        let accountRoot = try XCTUnwrap(
            OfflineReadingCacheProvider.accountCacheDirectory(
                applicationSupportRoot: fixture.root,
                storageID: storageID
            )
        )
        XCTAssertEqual(
            accountRoot.path,
            fixture.root
                .appendingPathComponent("AccountData")
                .appendingPathComponent(storageID)
                .appendingPathComponent("OfflineReadingCache")
                .path
        )
        XCTAssertNil(
            OfflineReadingCacheProvider.accountCacheDirectory(
                applicationSupportRoot: fixture.root,
                storageID: "../../another-account"
            )
        )

        _ = try OfflineReadingCacheStore(rootDirectory: accountRoot)
        let values = try accountRoot.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testCompleteMultiPagePackageRoundTripsAfterStoreRecreation() async throws {
        let fixture = try makeFixture()
        let clock = OfflineReadingCacheTestClock()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let book = makeBook(id: "B00-ROUNDTRIP")
        let document = makeDocument(id: "doc-roundtrip")
        let audio = makeAudio(document: document)

        let saved = try await store.saveKindlePackage(
            book: book,
            document: document,
            pageKeys: ["position:1", "position:2"],
            voiceID: "af_heart",
            segmentsByParagraph: audio
        )
        XCTAssertEqual(saved.pageCount, 2)
        XCTAssertEqual(saved.audioSegmentCount, 2)
        let containsSaved = await store.containsKindlePackage(book: book)
        XCTAssertTrue(containsSaved)

        let reopened = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let reloadedPackage = await reopened.loadKindlePackage(book: book)
        let package = try XCTUnwrap(reloadedPackage)
        XCTAssertEqual(package.document, document)
        XCTAssertEqual(package.pageKeys, ["position:1", "position:2"])
        XCTAssertEqual(package.segmentsByParagraph.keys.sorted(), [1, 3])
        assertSegment(package.segmentsByParagraph[1]?.first, equals: audio[1]?.first)
        assertSegment(package.segmentsByParagraph[3]?.first, equals: audio[3]?.first)
    }

    func testOnDevicePackageRoundTripsWithoutEmbeddedAudio() async throws {
        let fixture = try makeFixture()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let book = makeBook(id: "B00-LOCAL-JIT")
        let document = makeDocument(id: "local-jit")

        let summary = try await store.saveKindlePackage(
            book: book,
            document: document,
            pageKeys: ["page-a", "page-b"],
            voiceID: "on-device:auto",
            segmentsByParagraph: [:],
            audioMode: .onDevice
        )

        XCTAssertEqual(summary.audioMode, .onDevice)
        XCTAssertEqual(summary.audioSegmentCount, 0)
        let loaded = await store.loadKindlePackage(book: book)
        let package = try XCTUnwrap(loaded)
        XCTAssertEqual(package.document, document)
        XCTAssertEqual(package.audioMode, .onDevice)
        XCTAssertTrue(package.segmentsByParagraph.isEmpty)
    }

    func testOnDevicePackageRejectsAccidentallyEmbeddedAudio() async throws {
        let fixture = try makeFixture()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let book = makeBook(id: "B00-LOCAL-NO-AUDIO")
        let document = makeDocument(id: "local-no-audio")

        do {
            _ = try await store.saveKindlePackage(
                book: book,
                document: document,
                pageKeys: ["page-a", "page-b"],
                voiceID: "on-device:auto",
                segmentsByParagraph: makeAudio(document: document),
                audioMode: .onDevice
            )
            XCTFail("On-device packages must keep generated audio out of the durable book")
        } catch {
            XCTAssertEqual(
                error as? OfflineReadingCacheError,
                .invalidDocument("on-device packages cannot embed audio")
            )
        }
    }

    func testIncompletePageOrAudioCoverageIsRejectedWithoutReplacingGoodPackage() async throws {
        let fixture = try makeFixture()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let book = makeBook(id: "B00-ATOMIC")
        let original = makeDocument(id: "original")
        let originalAudio = makeAudio(document: original)
        try await store.saveKindlePackage(
            book: book,
            document: original,
            pageKeys: ["page-a", "page-b"],
            voiceID: "voice-a",
            segmentsByParagraph: originalAudio
        )

        do {
            try await store.saveKindlePackage(
                book: book,
                document: makeDocument(id: "replacement"),
                pageKeys: ["only-one-key"],
                voiceID: "voice-b",
                segmentsByParagraph: originalAudio
            )
            XCTFail("Expected page completeness validation to fail")
        } catch {
            XCTAssertEqual(error as? OfflineReadingCacheError, .invalidPageKeys)
        }

        var incompleteAudio = originalAudio
        incompleteAudio.removeValue(forKey: 3)
        do {
            try await store.saveKindlePackage(
                book: book,
                document: original,
                pageKeys: ["page-a", "page-b"],
                voiceID: "voice-b",
                segmentsByParagraph: incompleteAudio
            )
            XCTFail("Expected audio completeness validation to fail")
        } catch {
            XCTAssertEqual(
                error as? OfflineReadingCacheError,
                .incompleteAudio(paragraphIndex: nil)
            )
        }

        let loadedOriginal = await store.loadKindlePackage(book: book)
        let restored = try XCTUnwrap(loadedOriginal)
        XCTAssertEqual(restored.document.id, "original")
        XCTAssertEqual(restored.summary.voiceID, "voice-a")
    }

    func testResourceCorruptionInvalidatesAndPurgesPackage() async throws {
        let fixture = try makeFixture()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let book = makeBook(id: "B00-CORRUPT")
        let document = makeDocument(id: "corrupt")
        try await store.saveKindlePackage(
            book: book,
            document: document,
            pageKeys: ["page-a", "page-b"],
            voiceID: "voice",
            segmentsByParagraph: makeAudio(document: document)
        )

        let key = try XCTUnwrap(OfflineReadingCacheStore.cacheKey(forKindleBook: book))
        let resources = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(key)
            .appendingPathComponent("resources")
        let resourceName = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(atPath: resources.path).first
        )
        try Data("tampered".utf8).write(
            to: resources.appendingPathComponent(resourceName),
            options: .atomic
        )

        // Shelf queries deliberately trust only the manifest fast path. The
        // strict package hash scan happens at load time, just before playback.
        let summaryBeforeLoad = await store.summary(forKindleBook: book)
        let containsBeforeLoad = await store.containsKindlePackage(book: book)
        XCTAssertNotNil(summaryBeforeLoad)
        XCTAssertTrue(containsBeforeLoad)

        let corruptedLoad = await store.loadKindlePackage(book: book)
        let containsCorrupted = await store.containsKindlePackage(book: book)
        XCTAssertNil(corruptedLoad)
        XCTAssertFalse(containsCorrupted)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.cacheRoot
                    .appendingPathComponent("entries")
                    .appendingPathComponent(key)
                    .path
            )
        )
    }

    func testAccessTouchWriteFailureDoesNotDeleteHealthyPackage() async throws {
        let fixture = try makeFixture()
        let clock = OfflineReadingCacheTestClock()
        let book = makeBook(id: "B00-TOUCH-FAILURE")
        let initialStore = try OfflineReadingCacheStore(
            rootDirectory: fixture.cacheRoot,
            clock: clock
        )
        try await saveFixture(book: book, store: initialStore)
        let key = try XCTUnwrap(OfflineReadingCacheStore.cacheKey(forKindleBook: book))

        clock.advance()
        let faults = OfflineReadingCacheFaultScript(
            target: .beforeManifestWrite(.accessTouch)
        )
        let failingTouchStore = try OfflineReadingCacheStore(
            rootDirectory: fixture.cacheRoot,
            clock: clock,
            faultHandler: { try faults.handle($0) }
        )
        let loadedDespiteTouchFailure = await failingTouchStore.loadKindlePackage(book: book)
        XCTAssertNotNil(loadedDespiteTouchFailure)
        let stillContained = await failingTouchStore.containsKindlePackage(book: book)
        XCTAssertTrue(stillContained)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.cacheRoot
                    .appendingPathComponent("entries")
                    .appendingPathComponent(key)
                    .path
            )
        )

        let reopened = try OfflineReadingCacheStore(
            rootDirectory: fixture.cacheRoot,
            clock: clock
        )
        let loadedAfterReopen = await reopened.loadKindlePackage(book: book)
        XCTAssertNotNil(loadedAfterReopen)
    }

    func testPublishCrashBeforeManifestCommitRestoresPreviousPackage() async throws {
        let crashPoints: [OfflineReadingCacheFaultPoint] = [
            .afterPreviousMoved,
            .afterCandidateInstalled,
        ]
        for (index, crashPoint) in crashPoints.enumerated() {
            let fixture = try makeFixture()
            let book = makeBook(id: "B00-ROLLBACK-\(index)")
            let originalDocument = makeDocument(id: "original-\(index)")
            let initialStore = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
            try await initialStore.saveKindlePackage(
                book: book,
                document: originalDocument,
                pageKeys: ["page-a", "page-b"],
                voiceID: "original-voice",
                segmentsByParagraph: makeAudio(document: originalDocument)
            )

            let faults = OfflineReadingCacheFaultScript(
                target: crashPoint,
                failure: .simulatedCrash
            )
            let crashingStore = try OfflineReadingCacheStore(
                rootDirectory: fixture.cacheRoot,
                faultHandler: { try faults.handle($0) }
            )
            let replacement = makeDocument(id: "replacement-\(index)")
            do {
                try await crashingStore.saveKindlePackage(
                    book: book,
                    document: replacement,
                    pageKeys: ["page-a", "page-b"],
                    voiceID: "replacement-voice",
                    segmentsByParagraph: makeAudio(document: replacement)
                )
                XCTFail("Expected simulated publish crash at \(crashPoint)")
            } catch {
                // Reopening below is the crash boundary under test.
            }

            let recoveredStore = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
            let recoveredPackage = await recoveredStore.loadKindlePackage(book: book)
            let recovered = try XCTUnwrap(recoveredPackage)
            XCTAssertEqual(recovered.document.id, originalDocument.id)
            XCTAssertEqual(recovered.summary.voiceID, "original-voice")
            try assertStagingIsEmpty(fixture)
        }
    }

    func testPublishCrashAfterManifestCommitKeepsReplacementPackage() async throws {
        let fixture = try makeFixture()
        let book = makeBook(id: "B00-ROLLFORWARD")
        let originalDocument = makeDocument(id: "original")
        let initialStore = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        try await initialStore.saveKindlePackage(
            book: book,
            document: originalDocument,
            pageKeys: ["page-a", "page-b"],
            voiceID: "original-voice",
            segmentsByParagraph: makeAudio(document: originalDocument)
        )

        let faults = OfflineReadingCacheFaultScript(
            target: .afterManifestCommitted,
            failure: .simulatedCrash
        )
        let crashingStore = try OfflineReadingCacheStore(
            rootDirectory: fixture.cacheRoot,
            faultHandler: { try faults.handle($0) }
        )
        let replacement = makeDocument(id: "replacement")
        do {
            try await crashingStore.saveKindlePackage(
                book: book,
                document: replacement,
                pageKeys: ["page-a", "page-b"],
                voiceID: "replacement-voice",
                segmentsByParagraph: makeAudio(document: replacement)
            )
            XCTFail("Expected simulated crash after manifest commit")
        } catch {
            // Reopening below must finish the committed transaction.
        }

        let recoveredStore = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let recoveredPackage = await recoveredStore.loadKindlePackage(book: book)
        let recovered = try XCTUnwrap(recoveredPackage)
        XCTAssertEqual(recovered.document.id, replacement.id)
        XCTAssertEqual(recovered.summary.voiceID, "replacement-voice")
        try assertStagingIsEmpty(fixture)
    }

    func testInitializationPurgesUnjournaledStagingAndEntryOrphans() throws {
        let fixture = try makeFixture()
        let stagingOrphan = fixture.cacheRoot
            .appendingPathComponent(".staging", isDirectory: true)
            .appendingPathComponent(String(repeating: "a", count: 64), isDirectory: true)
        let entryOrphan = fixture.cacheRoot
            .appendingPathComponent("entries", isDirectory: true)
            .appendingPathComponent(String(repeating: "b", count: 64), isDirectory: true)
        try FileManager.default.createDirectory(
            at: stagingOrphan,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: entryOrphan,
            withIntermediateDirectories: true
        )
        try Data("private staged page".utf8).write(
            to: stagingOrphan.appendingPathComponent("payload")
        )
        try Data("private orphan page".utf8).write(
            to: entryOrphan.appendingPathComponent("payload")
        )

        _ = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingOrphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryOrphan.path))
        try assertStagingIsEmpty(fixture)
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(
                atPath: fixture.cacheRoot.appendingPathComponent("entries").path
            ).isEmpty
        )
    }

    func testRemoveFailuresKeepOperationRetryable() async throws {
        let fixture = try makeFixture()
        let book = makeBook(id: "B00-REMOVE-RETRY")
        let key = try XCTUnwrap(OfflineReadingCacheStore.cacheKey(forKindleBook: book))
        let byteRemovalFaults = OfflineReadingCacheFaultScript(
            target: .beforeEntryRemoval(key)
        )
        let byteRemovalStore = try OfflineReadingCacheStore(
            rootDirectory: fixture.cacheRoot,
            faultHandler: { try byteRemovalFaults.handle($0) }
        )
        try await saveFixture(book: book, store: byteRemovalStore)

        do {
            try await byteRemovalStore.removeKindlePackage(book: book)
            XCTFail("Expected byte removal to fail")
        } catch {
            // The manifest and bytes must remain available for a retry.
        }
        let containedAfterByteFailure = await byteRemovalStore.containsKindlePackage(book: book)
        XCTAssertTrue(containedAfterByteFailure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: entryPath(fixture, key: key).path))
        try await byteRemovalStore.removeKindlePackage(book: book)
        let containedAfterRetry = await byteRemovalStore.containsKindlePackage(book: book)
        XCTAssertFalse(containedAfterRetry)

        let secondBook = makeBook(id: "B00-MANIFEST-RETRY")
        let secondKey = try XCTUnwrap(
            OfflineReadingCacheStore.cacheKey(forKindleBook: secondBook)
        )
        let manifestFaults = OfflineReadingCacheFaultScript(
            target: .beforeManifestWrite(.remove)
        )
        let manifestStore = try OfflineReadingCacheStore(
            rootDirectory: fixture.cacheRoot,
            faultHandler: { try manifestFaults.handle($0) }
        )
        try await saveFixture(book: secondBook, store: manifestStore)
        do {
            try await manifestStore.removeKindlePackage(book: secondBook)
            XCTFail("Expected manifest removal to fail")
        } catch {
            // Bytes are gone, but the retained manifest record makes retry safe.
        }
        let containedAfterManifestFailure = await manifestStore.containsKindlePackage(
            book: secondBook
        )
        XCTAssertTrue(containedAfterManifestFailure)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: entryPath(fixture, key: secondKey).path)
        )
        try await manifestStore.removeKindlePackage(book: secondBook)
        let containedAfterManifestRetry = await manifestStore.containsKindlePackage(
            book: secondBook
        )
        XCTAssertFalse(containedAfterManifestRetry)
    }

    func testEmptyOrBlankTimestampWordsAreRejected() async throws {
        let fixture = try makeFixture()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let document = makeDocument(id: "timestamp-validation")
        let book = makeBook(id: "B00-TIMESTAMPS")
        let originalAudio = makeAudio(document: document)
        let originalSegment = try XCTUnwrap(originalAudio[1]?.first)

        var missingTimestamps = originalAudio
        missingTimestamps[1] = [copySegment(originalSegment, timestamps: [])]
        do {
            try await store.saveKindlePackage(
                book: book,
                document: document,
                pageKeys: ["page-a", "page-b"],
                voiceID: "voice",
                segmentsByParagraph: missingTimestamps
            )
            XCTFail("Expected empty timestamps to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OfflineReadingCacheError,
                .incompleteAudio(paragraphIndex: 1)
            )
        }

        var blankWordTimestamps = originalAudio
        blankWordTimestamps[1] = [
            copySegment(
                originalSegment,
                timestamps: [TTSTimestamp(word: "   ", startTime: 0, endTime: 0.8)]
            ),
        ]
        do {
            try await store.saveKindlePackage(
                book: book,
                document: document,
                pageKeys: ["page-a", "page-b"],
                voiceID: "voice",
                segmentsByParagraph: blankWordTimestamps
            )
            XCTFail("Expected blank timestamp words to be rejected")
        } catch {
            XCTAssertEqual(
                error as? OfflineReadingCacheError,
                .incompleteAudio(paragraphIndex: 1)
            )
        }
    }

    func testAlreadyCancelledSaveCannotRepublishAfterRemoval() async throws {
        let fixture = try makeFixture()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let book = makeBook(id: "B00-CANCELLED-QUEUED-SAVE")
        try await saveFixture(book: book, store: store)
        try await store.removeAllKindlePackages()

        let document = makeDocument(id: "must-not-return")
        let cancelledSave = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.saveKindlePackage(
                book: book,
                document: document,
                pageKeys: ["page-a", "page-b"],
                voiceID: "voice",
                segmentsByParagraph: makeAudio(document: document)
            )
        }
        do {
            _ = try await cancelledSave.value
            XCTFail("Expected the queued save to observe cancellation")
        } catch is CancellationError {
            // Expected: the store rejects it before writing staged bytes.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let containsCancelledSave = await store.containsKindlePackage(book: book)
        XCTAssertFalse(containsCancelledSave)
        try assertStagingIsEmpty(fixture)
    }

    func testCancellationAfterStagingRollsBackWithoutPublishing() async throws {
        let fixture = try makeFixture()
        let book = makeBook(id: "B00-CANCEL-BEFORE-PUBLISH")
        let originalDocument = makeDocument(id: "original-before-cancel")
        let initialStore = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        try await initialStore.saveKindlePackage(
            book: book,
            document: originalDocument,
            pageKeys: ["page-a", "page-b"],
            voiceID: "original-voice",
            segmentsByParagraph: makeAudio(document: originalDocument)
        )

        let cancellingStore = try OfflineReadingCacheStore(
            rootDirectory: fixture.cacheRoot,
            faultHandler: { point in
                if point == .beforePublish {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        )
        let replacement = makeDocument(id: "cancelled-replacement")
        let cancelledSave = Task {
            try await cancellingStore.saveKindlePackage(
                book: book,
                document: replacement,
                pageKeys: ["page-a", "page-b"],
                voiceID: "replacement-voice",
                segmentsByParagraph: makeAudio(document: replacement)
            )
        }
        do {
            _ = try await cancelledSave.value
            XCTFail("Expected cancellation immediately before publish")
        } catch is CancellationError {
            // Expected: staged bytes are deleted by save's defer.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }

        let loadedOriginal = await cancellingStore.loadKindlePackage(book: book)
        XCTAssertEqual(loadedOriginal?.document.id, originalDocument.id)
        XCTAssertEqual(loadedOriginal?.summary.voiceID, "original-voice")
        try assertStagingIsEmpty(fixture)
    }

    func testRevokedPublishLeaseDoesNotPublishOrReplacePreviousPackage() async throws {
        let fixture = try makeFixture()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let existingBook = makeBook(id: "B00-LEASE-EXISTING")
        let original = makeDocument(id: "lease-original")
        try await store.saveKindlePackage(
            book: existingBook,
            document: original,
            pageKeys: ["page-a", "page-b"],
            voiceID: "original-voice",
            segmentsByParagraph: makeAudio(document: original)
        )

        let revokedLease = OfflineReadingCachePublishLease()
        revokedLease.revoke()
        let replacement = makeDocument(id: "lease-replacement")
        do {
            try await store.saveKindlePackage(
                book: existingBook,
                document: replacement,
                pageKeys: ["page-a", "page-b"],
                voiceID: "replacement-voice",
                segmentsByParagraph: makeAudio(document: replacement),
                publishLease: revokedLease
            )
            XCTFail("Expected a revoked lease to reject replacement")
        } catch is CancellationError {
            // Expected: journal recovery restores the previous package.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let retainedPackage = await store.loadKindlePackage(book: existingBook)
        XCTAssertEqual(retainedPackage?.document.id, original.id)
        XCTAssertEqual(retainedPackage?.summary.voiceID, "original-voice")

        let newBook = makeBook(id: "B00-LEASE-NEW")
        let newDocument = makeDocument(id: "lease-new")
        do {
            try await store.saveKindlePackage(
                book: newBook,
                document: newDocument,
                pageKeys: ["page-a", "page-b"],
                voiceID: "new-voice",
                segmentsByParagraph: makeAudio(document: newDocument),
                publishLease: revokedLease
            )
            XCTFail("Expected a revoked lease to reject a first publication")
        } catch is CancellationError {
            // Expected: no prior package means the candidate is discarded.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let containsNewBook = await store.containsKindlePackage(book: newBook)
        XCTAssertFalse(containsNewBook)
        try assertStagingIsEmpty(fixture)
    }

    func testPublishLeaseLinearizesCommitBeforeConcurrentRevoke() async throws {
        let fixture = try makeFixture()
        let barrier = OfflineReadingCacheCommitBarrier()
        let store = try OfflineReadingCacheStore(
            rootDirectory: fixture.cacheRoot,
            faultHandler: { barrier.handle($0) }
        )
        let lease = OfflineReadingCachePublishLease()
        let book = makeBook(id: "B00-LEASE-COMMIT-WINS")
        let document = makeDocument(id: "commit-wins")
        let saveTask = Task {
            try await store.saveKindlePackage(
                book: book,
                document: document,
                pageKeys: ["page-a", "page-b"],
                voiceID: "commit-voice",
                segmentsByParagraph: makeAudio(document: document),
                publishLease: lease
            )
        }

        XCTAssertEqual(
            barrier.entered.wait(timeout: .now() + 2),
            .success,
            "The manifest commit never entered the lease critical section"
        )
        let revokeStarted = DispatchSemaphore(value: 0)
        let revokeFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            revokeStarted.signal()
            lease.revoke()
            revokeFinished.signal()
        }
        XCTAssertEqual(revokeStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            revokeFinished.wait(timeout: .now() + 0.1),
            .timedOut,
            "Revoke must wait while the winning manifest commit holds the lease"
        )

        barrier.release.signal()
        let summary = try await saveTask.value
        XCTAssertEqual(summary.voiceID, "commit-voice")
        XCTAssertEqual(revokeFinished.wait(timeout: .now() + 2), .success)
        let committedPackage = await store.loadKindlePackage(book: book)
        XCTAssertEqual(committedPackage?.document.id, document.id)

        // Once the winning commit releases the lock, the pending revoke is
        // durable for every later publication using this lease.
        let laterReplacement = makeDocument(id: "after-revoke")
        do {
            try await store.saveKindlePackage(
                book: book,
                document: laterReplacement,
                pageKeys: ["page-a", "page-b"],
                voiceID: "later-voice",
                segmentsByParagraph: makeAudio(document: laterReplacement),
                publishLease: lease
            )
            XCTFail("Expected the completed revoke to reject later commits")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        let packageAfterRejectedReplacement = await store.loadKindlePackage(book: book)
        XCTAssertEqual(packageAfterRejectedReplacement?.document.id, document.id)
        XCTAssertEqual(packageAfterRejectedReplacement?.summary.voiceID, "commit-voice")
        try assertStagingIsEmpty(fixture)
    }

    func testCountLimitUsesLoadAccessForLRUEviction() async throws {
        let fixture = try makeFixture()
        let clock = OfflineReadingCacheTestClock()
        let store = try OfflineReadingCacheStore(
            rootDirectory: fixture.cacheRoot,
            limits: OfflineReadingCacheLimits(maxBookCount: 2, maxBytes: 20_000_000),
            clock: clock
        )
        let first = makeBook(id: "B00-FIRST")
        let second = makeBook(id: "B00-SECOND")
        let third = makeBook(id: "B00-THIRD")
        try await saveFixture(book: first, store: store)
        clock.advance()
        try await saveFixture(book: second, store: store)
        clock.advance()
        let touchedFirst = await store.loadKindlePackage(book: first)
        XCTAssertNotNil(touchedFirst)
        clock.advance()
        try await saveFixture(book: third, store: store)

        let containsFirst = await store.containsKindlePackage(book: first)
        let containsSecond = await store.containsKindlePackage(book: second)
        let containsThird = await store.containsKindlePackage(book: third)
        XCTAssertTrue(containsFirst)
        XCTAssertFalse(containsSecond)
        XCTAssertTrue(containsThird)
    }

    func testFilesystemNamesAreOpaqueAndManifestContainsNoRawIdentity() async throws {
        let fixture = try makeFixture()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let rawBookID = "raw-book-id-B00-SECRET"
        let rawAccountID = "reader@example.com"
        let book = makeBook(id: rawBookID, title: "Private Book Title")
        try await saveFixture(book: book, store: store)

        let manifestData = try Data(
            contentsOf: fixture.cacheRoot.appendingPathComponent("manifest.json")
        )
        let manifestText = String(decoding: manifestData, as: UTF8.self)
        XCTAssertFalse(manifestText.contains(rawAccountID))
        XCTAssertFalse(manifestText.contains(rawBookID))
        XCTAssertFalse(manifestText.contains("Private Book Title"))

        let entryNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.cacheRoot.appendingPathComponent("entries").path
        )
        XCTAssertEqual(entryNames.count, 1)
        XCTAssertTrue(isDigest(entryNames[0]))
        let entryURL = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(entryNames[0])
        let packageNames = try FileManager.default.contentsOfDirectory(atPath: entryURL.path)
        let metadataNames = packageNames.filter { $0 != "resources" }
        XCTAssertEqual(metadataNames.count, 1)
        XCTAssertTrue(metadataNames.allSatisfy(isDigest))
        let resourceNames = try FileManager.default.contentsOfDirectory(
            atPath: entryURL.appendingPathComponent("resources").path
        )
        XCTAssertFalse(resourceNames.isEmpty)
        XCTAssertTrue(resourceNames.allSatisfy(isDigest))
    }

    func testRemoveOneAndRemoveAllKindlePackages() async throws {
        let fixture = try makeFixture()
        let store = try OfflineReadingCacheStore(rootDirectory: fixture.cacheRoot)
        let first = makeBook(id: "B00-REMOVE-ONE")
        let second = makeBook(id: "B00-REMOVE-ALL")
        try await saveFixture(book: first, store: store)
        try await saveFixture(book: second, store: store)

        try await store.removeKindlePackage(book: first)
        let containsFirst = await store.containsKindlePackage(book: first)
        let containsSecondBeforeAll = await store.containsKindlePackage(book: second)
        XCTAssertFalse(containsFirst)
        XCTAssertTrue(containsSecondBeforeAll)

        try await store.removeAllKindlePackages()
        let containsSecondAfterAll = await store.containsKindlePackage(book: second)
        XCTAssertFalse(containsSecondAfterAll)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let root: URL
        let cacheRoot: URL
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return Fixture(
            root: root,
            cacheRoot: root.appendingPathComponent("OfflineReadingCache", isDirectory: true)
        )
    }

    private func makeBook(
        id: String,
        title: String = "Test Kindle Book"
    ) -> KindleBook {
        KindleBook(
            id: id,
            asin: id,
            title: title,
            author: "Author",
            coverURL: nil,
            readerURL: "https://read.amazon.com/?asin=\(id)",
            progressLabel: "1%",
            storefrontID: "read.amazon.com",
            language: "en",
            languageSource: "renderer-metadata",
            lastOpenedAt: nil,
            lastSyncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastReadPageKey: nil,
            lastReadURL: nil
        )
    }

    private func makeDocument(id: String) -> ReadingDocument {
        let firstImage = ReadingParagraph(
            id: 0,
            text: "",
            type: .image,
            pageIndex: 0,
            imageData: Data(repeating: 0x11, count: 256)
        )
        let firstText = ReadingParagraph(
            id: 1,
            text: "First page text.",
            words: [
                OCRWord(
                    id: 0,
                    text: "First",
                    bboxNorm: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.08)
                ),
            ],
            bboxNorm: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.08),
            pageIndex: 0
        )
        let secondImage = ReadingParagraph(
            id: 2,
            text: "",
            type: .image,
            pageIndex: 1,
            imageData: Data(repeating: 0x22, count: 384)
        )
        let secondText = ReadingParagraph(
            id: 3,
            text: "Second page text.",
            words: [
                OCRWord(
                    id: 1,
                    text: "Second",
                    bboxNorm: CGRect(x: 0.1, y: 0.6, width: 0.25, height: 0.08)
                ),
            ],
            bboxNorm: CGRect(x: 0.1, y: 0.6, width: 0.5, height: 0.08),
            pageIndex: 1
        )
        return ReadingDocument(
            id: id,
            title: "Offline fixture",
            sourceKind: .kindle,
            language: "en",
            paragraphs: [firstImage, firstText, secondImage, secondText],
            sourceURL: "https://read.amazon.com/",
            coverURL: "https://images.example/cover.jpg",
            contentSessionKey: "session-\(id)",
            layoutColumnCount: 1,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func makeAudio(document: ReadingDocument) -> [Int: [AudioSegment]] {
        Dictionary(uniqueKeysWithValues: document.readableParagraphs.map { paragraph in
            (
                paragraph.id,
                [
                    AudioSegment(
                        paragraphIndex: paragraph.id,
                        segmentIndex: 0,
                        audioData: Data(repeating: UInt8(paragraph.id + 1), count: 128),
                        timestamps: [
                            TTSTimestamp(word: paragraph.text, startTime: 0, endTime: 0.8),
                        ],
                        duration: 1,
                        text: paragraph.text,
                        unprocessedText: paragraph.text,
                        speaker: "narrator"
                    ),
                ]
            )
        })
    }

    private func saveFixture(
        book: KindleBook,
        store: OfflineReadingCacheStore
    ) async throws {
        let document = makeDocument(id: "doc-\(book.id)")
        try await store.saveKindlePackage(
            book: book,
            document: document,
            pageKeys: ["page-a", "page-b"],
            voiceID: "voice",
            segmentsByParagraph: makeAudio(document: document)
        )
    }

    private func copySegment(
        _ segment: AudioSegment,
        timestamps: [TTSTimestamp]
    ) -> AudioSegment {
        AudioSegment(
            paragraphIndex: segment.paragraphIndex,
            segmentIndex: segment.segmentIndex,
            audioData: segment.audioData,
            timestamps: timestamps,
            duration: segment.duration,
            text: segment.text,
            isWavFormat: segment.isWavFormat,
            unprocessedText: segment.unprocessedText,
            speaker: segment.speaker
        )
    }

    private func entryPath(_ fixture: Fixture, key: String) -> URL {
        fixture.cacheRoot
            .appendingPathComponent("entries", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    private func assertStagingIsEmpty(
        _ fixture: Fixture,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: fixture.cacheRoot.appendingPathComponent(".staging").path
        )
        XCTAssertTrue(names.isEmpty, "Unexpected staging items: \(names)", file: file, line: line)
    }

    private func assertSegment(_ actual: AudioSegment?, equals expected: AudioSegment?) {
        XCTAssertEqual(actual?.id, expected?.id)
        XCTAssertEqual(actual?.paragraphIndex, expected?.paragraphIndex)
        XCTAssertEqual(actual?.segmentIndex, expected?.segmentIndex)
        XCTAssertEqual(actual?.audioData, expected?.audioData)
        XCTAssertEqual(actual?.duration, expected?.duration)
        XCTAssertEqual(actual?.text, expected?.text)
        XCTAssertEqual(actual?.unprocessedText, expected?.unprocessedText)
        XCTAssertEqual(actual?.speaker, expected?.speaker)
        XCTAssertEqual(actual?.timestamps.first?.word, expected?.timestamps.first?.word)
        XCTAssertEqual(actual?.timestamps.first?.startTime, expected?.timestamps.first?.startTime)
        XCTAssertEqual(actual?.timestamps.first?.endTime, expected?.timestamps.first?.endTime)
    }

    private func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
