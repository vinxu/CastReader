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
        defaults.set(try JSONEncoder().encode(stale), forKey: "systemIntegration.continueSnapshots.v1")

        XCTAssertEqual(ContinueSnapshotStore(defaults: defaults).snapshots().map(\.id), ["ok"])
    }

    func testReplacingWithAnEmptyListClearsTheSurfaces() {
        let store = ContinueSnapshotStore(defaults: defaults)
        store.replace(with: [snapshot("a")])
        store.replace(with: [])

        XCTAssertTrue(store.snapshots().isEmpty)
    }
}
