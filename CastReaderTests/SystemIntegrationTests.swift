//
//  SystemIntegrationTests.swift
//  CastReaderTests
//
//  Contracts for the system entry points (Siri / Shortcuts / widgets).
//
//  This module is contract-heavy and crosses a process boundary: extensions
//  deposit one command into the App Group and the app claims it. The rules that
//  keep that safe — a single last-write-wins slot, an atomic claim, and the
//  Home Continue source filter — are invisible at the call site, so they are
//  pinned here.
//

import XCTest
import UIKit
@testable import CastReader

final class SystemIntegrationTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "test.systemIntegration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - castreader:// URL contract

    func testURLContractAcceptsTheThreeSupportedHosts() {
        XCTAssertEqual(SystemAction.from(url: URL(string: "castreader://import")!), .openImport)
        XCTAssertEqual(
            SystemAction.from(url: URL(string: "castreader://continue?item=abc&mode=explain")!),
            .continueReading(itemID: "abc", mode: .explain)
        )
        XCTAssertEqual(
            SystemAction.from(url: URL(string: "castreader://read?input=hello")!),
            .read(input: "hello", mode: .read)
        )
    }

    func testURLContractDefaultsToReadModeAndAcceptsIDAlias() {
        XCTAssertEqual(
            SystemAction.from(url: URL(string: "castreader://continue?id=xyz")!),
            .continueReading(itemID: "xyz", mode: .read),
            "`id` is an accepted alias for `item`, and a missing mode means read"
        )
        XCTAssertEqual(
            SystemAction.from(url: URL(string: "castreader://read?input=hi&mode=nonsense")!),
            .read(input: "hi", mode: .read),
            "An unparsable mode falls back to read rather than dropping the action"
        )
    }

    func testURLContractRejectsForeignAndIncompleteURLs() {
        XCTAssertNil(SystemAction.from(url: URL(string: "https://castreader.ai/read?input=hi")!))
        XCTAssertNil(SystemAction.from(url: URL(string: "castreader://unknown-host")!))
        XCTAssertNil(
            SystemAction.from(url: URL(string: "castreader://read")!),
            "A read action with no input must be rejected, not opened as empty"
        )
        XCTAssertNil(
            SystemAction.from(url: URL(string: "castreader://read?input=%20%20")!),
            "Whitespace-only input is empty input"
        )
    }

    func testURLContractIgnoresCase() {
        XCTAssertEqual(
            SystemAction.from(url: URL(string: "CASTREADER://Continue?ITEM=abc")!),
            .continueReading(itemID: "abc", mode: .read)
        )
    }

    // MARK: - Pending action slot

    func testPendingSlotIsLastWriteWins() {
        let store = SystemActionStore(defaults: defaults)
        store.enqueue(.openImport)
        store.enqueue(.read(input: "second", mode: .explain))

        XCTAssertEqual(
            store.takePending(), .read(input: "second", mode: .explain),
            "One slot only — a newer command replaces an unclaimed older one"
        )
    }

    /// Scene-active can fire more than once; the action must execute exactly once.
    func testClaimingThePendingSlotIsAtomic() {
        let store = SystemActionStore(defaults: defaults)
        store.enqueue(.openImport)

        XCTAssertEqual(store.takePending(), .openImport)
        XCTAssertNil(store.takePending(), "A claimed action must never be replayed")
    }

    func testCorruptPayloadIsClearedRatherThanRetried() {
        defaults.set(Data("not json".utf8), forKey: "systemIntegration.pendingAction.v1")
        let store = SystemActionStore(defaults: defaults)

        XCTAssertNil(store.takePending())
        XCTAssertNil(
            defaults.data(forKey: "systemIntegration.pendingAction.v1"),
            "Undecodable data must be dropped, otherwise it is re-read forever"
        )
    }

    // MARK: - Launch attribution

    func testOriginPeekIsNonDestructive() {
        let store = SystemActionStore(defaults: defaults)
        store.enqueue(.continueReading(itemID: nil, mode: .read), origin: .widget)

        XCTAssertEqual(store.peekPendingOrigin(), .widget)
        XCTAssertEqual(store.peekPendingOrigin(), .widget, "Peeking twice must still find it")
        XCTAssertEqual(
            store.takePending(), .continueReading(itemID: nil, mode: .read),
            "Peeking must not consume the action the app still has to route"
        )
    }

    func testOriginIsClearedWithTheAction() {
        let store = SystemActionStore(defaults: defaults)
        store.enqueue(.openImport, origin: .deepLink)
        _ = store.takePending()

        XCTAssertNil(
            store.peekPendingOrigin(),
            "A stale origin would misattribute the next ordinary launch"
        )
    }

    func testNoPendingActionMeansNoOrigin() {
        XCTAssertNil(SystemActionStore(defaults: defaults).peekPendingOrigin())
    }

    /// `SystemActionOrigin` ships in the extension-safe module and cannot import
    /// ProductAnalytics, so nothing but this test stops the two vocabularies
    /// from drifting apart and silently emitting an invalid launchType.
    func testOriginLaunchTypesAreValidAnalyticsValues() {
        for origin in [SystemActionOrigin.appIntent, .widget, .deepLink] {
            XCTAssertNotNil(
                AnalyticsLaunchType(rawValue: origin.launchType),
                "\(origin) emits launchType '\(origin.launchType)', which analytics rejects"
            )
        }
    }

    func testAppSessionStartRejectsAnUnknownLaunchType() {
        XCTAssertThrowsError(
            try AnalyticsSchema.validate(.appSessionStart, properties: .init(launchType: "carrier_pigeon"))
        )
        XCTAssertNoThrow(
            try AnalyticsSchema.validate(.appSessionStart, properties: .init(launchType: "intent"))
        )
    }

    // MARK: - Continue snapshots

    private func snapshot(
        _ id: String,
        sourceKind: String = "text",
        minutesAgo: Int = 0
    ) -> ContinueSnapshot {
        ContinueSnapshot(
            id: id,
            title: "Item \(id)",
            sourceKind: sourceKind,
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000 - Double(minutesAgo) * 60)
        )
    }

    /// Home gives Kindle and WeRead their own rails, so Continue must not repeat
    /// them — the same contract has to hold on the Siri and widget surfaces.
    func testConnectedLibrarySourcesNeverReachTheSystemSurfaces() {
        let store = ContinueSnapshotStore(defaults: defaults)
        store.replace(with: [
            snapshot("a", sourceKind: "text"),
            snapshot("b", sourceKind: "kindle"),
            snapshot("c", sourceKind: "weread"),
            snapshot("d", sourceKind: "google_books"),
            snapshot("e", sourceKind: "kobo"),
            snapshot("f", sourceKind: "oreilly"),
            snapshot("g", sourceKind: "pdf")
        ])

        XCTAssertEqual(store.snapshots().map(\.id).sorted(), ["a", "g"])
    }

    func testSnapshotsAreDeduplicatedKeepingTheNewest() {
        let store = ContinueSnapshotStore(defaults: defaults)
        store.replace(with: [
            snapshot("dup", minutesAgo: 60),
            snapshot("dup", minutesAgo: 1),
            snapshot("dup", minutesAgo: 30)
        ])

        let snapshots = store.snapshots()
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.updatedAt, snapshot("dup", minutesAgo: 1).updatedAt)
    }

    func testSnapshotsAreNewestFirstAndCappedAtEight() {
        let store = ContinueSnapshotStore(defaults: defaults)
        store.replace(with: (0..<12).map { snapshot("item-\($0)", minutesAgo: $0) })

        let snapshots = store.snapshots()
        XCTAssertEqual(snapshots.count, 8, "Widgets and Siri suggestions take a bounded list")
        XCTAssertEqual(snapshots.map(\.id), (0..<8).map { "item-\($0)" })
    }

    func testBlankIdentifiersAreDropped() {
        let store = ContinueSnapshotStore(defaults: defaults)
        store.replace(with: [snapshot("  "), snapshot("real")])

        XCTAssertEqual(store.snapshots().map(\.id), ["real"])
    }

    /// An older build could have written an entry that today's contract excludes.
    func testStoredValuesAreFilteredAgainWhenRead() throws {
        let stale = [snapshot("legacy", sourceKind: "kindle"), snapshot("ok")]
        defaults.set(try JSONEncoder().encode(stale), forKey: "systemIntegration.continueSnapshots.v2")

        XCTAssertEqual(ContinueSnapshotStore(defaults: defaults).snapshots().map(\.id), ["ok"])
    }

    func testReplacingWithAnEmptyListClearsTheSurfaces() {
        let store = ContinueSnapshotStore(defaults: defaults)
        store.replace(with: [snapshot("a")])
        store.replace(with: [])

        XCTAssertTrue(store.snapshots().isEmpty)
    }
}

@MainActor
final class HistoryStoreAccountScopeTests: XCTestCase {
    func testAccountScopesStartInactivePreserveLegacyAndRemainIndependent() async throws {
        let container = makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }

        let legacyDirectory = container.appendingPathComponent("History", isDirectory: true)
        try FileManager.default.createDirectory(
            at: legacyDirectory,
            withIntermediateDirectories: true
        )
        let now = Date(timeIntervalSinceReferenceDate: 779_000_000)
        let legacy = HistoryRecord(
            id: "legacy-document",
            title: "Legacy",
            sourceKindRaw: ReadingSourceKind.text.rawValue,
            sourceURL: nil,
            language: "en",
            createdAt: now,
            lastOpenedAt: now,
            coverPath: nil
        )
        let legacyIndexURL = legacyDirectory.appendingPathComponent("index.json")
        let legacyPayloadURL = legacyDirectory.appendingPathComponent("legacy-document.payload")
        let legacyIndexData = try JSONEncoder().encode([legacy])
        try legacyIndexData.write(to: legacyIndexURL, options: .atomic)
        try Data("legacy bytes".utf8).write(to: legacyPayloadURL, options: .atomic)

        // Existing dependency/test injection remains immediately active.
        XCTAssertEqual(HistoryStore(directory: legacyDirectory).records.map(\.id), [legacy.id])

        let accountDataRoot = container.appendingPathComponent("AccountData", isDirectory: true)
        let store = HistoryStore(accountDataRoot: accountDataRoot)
        XCTAssertTrue(store.records.isEmpty)
        store.record(textDocument(id: "inactive", title: "Inactive", text: "ignored"))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountDataRoot.path))
        XCTAssertEqual(try Data(contentsOf: legacyIndexURL), legacyIndexData)
        XCTAssertEqual(try Data(contentsOf: legacyPayloadURL), Data("legacy bytes".utf8))

#if DEBUG
        XCTAssertTrue(store.activateLegacyTestingScope())
        XCTAssertEqual(store.records.map(\.id), [legacy.id])
        store.deactivateAccountScope()
        XCTAssertTrue(store.records.isEmpty)
#endif

        XCTAssertTrue(store.activateAccountScope(storageID: "opaque-account-a"))
        store.record(textDocument(
            id: "same-document-id",
            title: "Account A",
            text: "account a bytes"
        ))
        XCTAssertEqual(store.records.map(\.title), ["Account A"])

        let accountADirectory = try XCTUnwrap(HistoryStore.accountHistoryDirectory(
            accountDataRoot: accountDataRoot,
            storageID: "opaque-account-a"
        ))
        XCTAssertEqual(
            try Data(contentsOf: accountADirectory.appendingPathComponent("same-document-id.payload")),
            Data("account a bytes".utf8)
        )

        XCTAssertTrue(store.activateAccountScope(storageID: "opaque-account-b"))
        XCTAssertTrue(store.records.isEmpty)
        store.record(textDocument(
            id: "same-document-id",
            title: "Account B",
            text: "account b bytes"
        ))
        XCTAssertEqual(store.records.map(\.title), ["Account B"])

        let accountBDirectory = try XCTUnwrap(HistoryStore.accountHistoryDirectory(
            accountDataRoot: accountDataRoot,
            storageID: "opaque-account-b"
        ))
        XCTAssertEqual(
            try Data(contentsOf: accountBDirectory.appendingPathComponent("same-document-id.payload")),
            Data("account b bytes".utf8)
        )

        XCTAssertTrue(store.activateAccountScope(storageID: "opaque-account-a"))
        let accountARecord = try XCTUnwrap(store.records.first)
        XCTAssertEqual(accountARecord.title, "Account A")
        let reopenedAccountA = try await store.reopen(accountARecord)
        XCTAssertEqual(reopenedAccountA?.fullText, "account a bytes")

        store.deactivateAccountScope()
        XCTAssertTrue(store.records.isEmpty)
        store.clearAll()
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: accountADirectory.appendingPathComponent("index.json").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: accountBDirectory.appendingPathComponent("index.json").path
        ))
        XCTAssertEqual(try Data(contentsOf: legacyIndexURL), legacyIndexData)
        XCTAssertEqual(try Data(contentsOf: legacyPayloadURL), Data("legacy bytes".utf8))
    }

    func testInvalidStorageIDDeactivatesWithoutEscapingRoot() {
        let container = makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let accountDataRoot = container.appendingPathComponent("AccountData", isDirectory: true)
        let store = HistoryStore(accountDataRoot: accountDataRoot)

        XCTAssertTrue(store.activateAccountScope(storageID: "valid-scope"))
        store.record(textDocument(id: "valid", title: "Valid", text: "valid"))
        XCTAssertFalse(store.records.isEmpty)

        XCTAssertFalse(store.activateAccountScope(storageID: "../escaped"))
        XCTAssertTrue(store.records.isEmpty)
        XCTAssertNil(HistoryStore.accountHistoryDirectory(
            accountDataRoot: accountDataRoot,
            storageID: "../escaped"
        ))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: container.appendingPathComponent("escaped", isDirectory: true).path
        ))
    }

    func testPendingCoverFromPreviousScopeCannotWriteIntoCurrentAccount() async throws {
        let container = makeDirectory()
        defer { try? FileManager.default.removeItem(at: container) }
        let accountDataRoot = container.appendingPathComponent("AccountData", isDirectory: true)
        let accountBDirectory = try XCTUnwrap(HistoryStore.accountHistoryDirectory(
            accountDataRoot: accountDataRoot,
            storageID: "account-b"
        ))
        try FileManager.default.createDirectory(
            at: accountBDirectory,
            withIntermediateDirectories: true
        )
        let now = Date(timeIntervalSinceReferenceDate: 780_000_000)
        let accountBRecord = HistoryRecord(
            id: "shared-id",
            title: "Account B",
            sourceKindRaw: ReadingSourceKind.text.rawValue,
            sourceURL: nil,
            language: "en",
            createdAt: now,
            lastOpenedAt: now,
            // Prevent account B from starting its own cover task while keeping
            // this record eligible for an accidental old-scope write.
            coverPath: ""
        )
        try JSONEncoder().encode([accountBRecord]).write(
            to: accountBDirectory.appendingPathComponent("index.json"),
            options: .atomic
        )

        let gate = SuspendedHistoryCoverLoader()
        let store = HistoryStore(
            accountDataRoot: accountDataRoot,
            performsCoverWork: true,
            coverDataLoader: { _ in await gate.load() }
        )
        XCTAssertTrue(store.activateAccountScope(storageID: "account-a"))
        store.record(ReadingDocument(
            id: "shared-id",
            title: "Account A",
            sourceKind: .text,
            language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "Account A")],
            coverURL: "https://example.invalid/account-a-cover.png"
        ))
        await gate.waitUntilStarted()

        XCTAssertTrue(store.activateAccountScope(storageID: "account-b"))
        XCTAssertEqual(store.records.first, accountBRecord)

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
        await gate.resume(with: image.pngData())
        await gate.waitUntilFinished()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(store.records.first, accountBRecord)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: accountBDirectory.appendingPathComponent("shared-id.cover.jpg").path
        ))
    }

    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreAccountScopeTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func textDocument(id: String, title: String, text: String) -> ReadingDocument {
        ReadingDocument(
            id: id,
            title: title,
            sourceKind: .text,
            language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: text)]
        )
    }
}

private actor SuspendedHistoryCoverLoader {
    private var continuation: CheckedContinuation<Data?, Never>?
    private var didStart = false
    private var didFinish = false

    func load() async -> Data? {
        didStart = true
        let data = await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        didFinish = true
        return data
    }

    func waitUntilStarted() async {
        while !didStart { await Task.yield() }
    }

    func resume(with data: Data?) {
        continuation?.resume(returning: data)
        continuation = nil
    }

    func waitUntilFinished() async {
        while !didFinish { await Task.yield() }
    }
}
