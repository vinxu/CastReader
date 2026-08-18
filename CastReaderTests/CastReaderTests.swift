//
//  CastReaderTests.swift
//  CastReaderTests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest
import UIKit
import WebKit
import AuthenticationServices
@testable import CastReader

class CastReaderTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
    }

    // MARK: - App Intents / Widget system integration

    func testSystemActionParsesPublicDeepLinks() throws {
        XCTAssertEqual(
            SystemAction.from(url: try XCTUnwrap(URL(
                string: "castreader://import"
            ))),
            .openImport
        )
        XCTAssertEqual(
            SystemAction.from(url: try XCTUnwrap(URL(
                string: "castreader://continue?item=history-42&mode=explain"
            ))),
            .continueReading(itemID: "history-42", mode: .explain)
        )
        XCTAssertEqual(
            SystemAction.from(url: try XCTUnwrap(URL(
                string: "castreader://read?input=https%3A%2F%2Fexample.com%2Farticle&mode=explain"
            ))),
            .read(input: "https://example.com/article", mode: .explain)
        )
        XCTAssertNil(SystemAction.from(url: try XCTUnwrap(URL(
            string: "castreader://read?mode=read"
        ))))
        XCTAssertNil(SystemAction.from(url: try XCTUnwrap(URL(
            string: "https://castreader.com/read?input=hello"
        ))))
    }

    func testSystemActionStoreIsLastWriteWinsAndOneShot() throws {
        let suite = "SystemActionStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SystemActionStore(defaults: defaults)

        XCTAssertTrue(store.enqueue(.openImport))
        XCTAssertTrue(store.enqueue(.continueReading(itemID: "newest", mode: .read)))
        XCTAssertEqual(
            store.takePending(),
            .continueReading(itemID: "newest", mode: .read)
        )
        XCTAssertNil(store.takePending(), "pending command must execute at most once")
    }

    func testContinueSnapshotStoreNormalizesHomeEligibleItems() throws {
        let suite = "ContinueSnapshotStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ContinueSnapshotStore(defaults: defaults)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshots = (0..<10).map { index in
            ContinueSnapshot(
                id: "item-\(index)",
                title: "Item \(index)",
                sourceKind: index == 0 ? "kindle" : "text",
                updatedAt: now.addingTimeInterval(Double(index))
            )
        }
        snapshots.append(ContinueSnapshot(
            id: "item-5",
            title: "Older duplicate",
            sourceKind: "text",
            updatedAt: now.addingTimeInterval(-100)
        ))

        store.replace(with: snapshots)
        let result = store.snapshots()

        XCTAssertEqual(result.count, 8)
        XCTAssertFalse(result.contains { $0.sourceKind == "kindle" })
        XCTAssertEqual(result.first?.id, "item-9")
        XCTAssertEqual(result.first(where: { $0.id == "item-5" })?.title, "Item 5")
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
    }

    func testSystemContinueSelectionNeverSubstitutesForStaleExplicitID() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let records = [
            HistoryRecord(
                id: "latest",
                title: "Latest",
                sourceKindRaw: ReadingSourceKind.text.rawValue,
                sourceURL: nil,
                language: "en",
                createdAt: now,
                lastOpenedAt: now,
                coverPath: nil
            ),
            HistoryRecord(
                id: "older",
                title: "Older",
                sourceKindRaw: ReadingSourceKind.web.rawValue,
                sourceURL: "https://example.com",
                language: "en",
                createdAt: now.addingTimeInterval(-100),
                lastOpenedAt: now.addingTimeInterval(-100),
                coverPath: nil
            ),
            HistoryRecord(
                id: "kindle",
                title: "Connected library",
                sourceKindRaw: ReadingSourceKind.kindle.rawValue,
                sourceURL: nil,
                language: "en",
                createdAt: now,
                lastOpenedAt: now,
                coverPath: nil
            )
        ]

        XCTAssertEqual(SystemContinueContract.record(in: records, itemID: nil)?.id, "latest")
        XCTAssertEqual(SystemContinueContract.record(in: records, itemID: "older")?.id, "older")
        XCTAssertNil(SystemContinueContract.record(in: records, itemID: "missing"))
        XCTAssertNil(SystemContinueContract.record(in: records, itemID: "kindle"))
    }

    func testHistoryRecordPersistsReadingPositionAcrossEncodeDecode() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var record = HistoryRecord(
            id: "resume-doc",
            title: "Imported PDF",
            sourceKindRaw: ReadingSourceKind.pdf.rawValue,
            sourceURL: nil,
            language: "zh",
            createdAt: now,
            lastOpenedAt: now,
            coverPath: nil
        )
        record.lastParagraphIndex = 12

        let decoded = try JSONDecoder().decode(
            HistoryRecord.self,
            from: JSONEncoder().encode(record)
        )
        XCTAssertEqual(decoded.lastParagraphIndex, 12)

        // Old-index records without the field and corrupt negatives stay nil.
        var legacy = record
        legacy.lastParagraphIndex = nil
        let decodedLegacy = try JSONDecoder().decode(
            HistoryRecord.self,
            from: JSONEncoder().encode(legacy)
        )
        XCTAssertNil(decodedLegacy.lastParagraphIndex)

        // Live-bridge and time-based sources never persist a paragraph resume.
        for kind in [ReadingSourceKind.kindle, .weread, .googleBooks, .youtube, .web] {
            XCTAssertFalse(
                HistoryStore.resumableSourceKinds.contains(kind),
                "\(kind) must keep its own resume mechanism"
            )
        }
        for kind in [ReadingSourceKind.text, .epub, .pdf, .docx, .photo] {
            XCTAssertTrue(HistoryStore.resumableSourceKinds.contains(kind))
        }
    }

    func testPausedCloudFeatureHidesRemoteHistoryFromAppAndSystemContinue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cloudRecord = HistoryRecord(
            id: "cloud-pdf",
            title: "Remote PDF",
            sourceKindRaw: ReadingSourceKind.pdf.rawValue,
            sourceURL: nil,
            language: "en",
            createdAt: now,
            lastOpenedAt: now,
            coverPath: nil,
            persistencePolicy: .remoteReference
        )

        XCTAssertFalse(
            HistoryVisibilityContract.includes(
                cloudRecord,
                cloudStorageEnabled: false
            )
        )
        XCTAssertTrue(
            HistoryVisibilityContract.includes(
                cloudRecord,
                cloudStorageEnabled: true
            )
        )
        XCTAssertNil(
            SystemContinueContract.record(
                in: [cloudRecord],
                itemID: cloudRecord.id,
                cloudStorageEnabled: false
            )
        )
        XCTAssertEqual(
            SystemContinueContract.record(
                in: [cloudRecord],
                itemID: cloudRecord.id,
                cloudStorageEnabled: true
            )?.id,
            cloudRecord.id
        )
    }

    func testDeferredAutoplayGateConsumesEachRequestExactlyOnce() {
        var gate = DeferredAutoplayGate()

        XCTAssertFalse(gate.request(isReady: false))
        XCTAssertTrue(gate.isPending)
        XCTAssertTrue(gate.contentBecameReady(isReady: true))
        XCTAssertFalse(gate.contentBecameReady(isReady: true))
        XCTAssertFalse(gate.isPending)

        XCTAssertTrue(gate.request(isReady: true), "a later Continue tap remains actionable")
        XCTAssertFalse(gate.contentBecameReady(isReady: true))
    }

    func testExplainShortcutAlwaysBuildsExplainAction() {
        XCTAssertEqual(
            ExplainWithCastReaderIntent(input: "A difficult paragraph").systemAction,
            .read(input: "A difficult paragraph", mode: .explain)
        )
    }

    // MARK: - 绑定书库首次引导

    @MainActor
    func testBoundLibraryOnboardingIsOneTimeAndVersionedLocally() throws {
        let suite = "BoundLibraryOnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstLaunch = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        XCTAssertTrue(firstLaunch.isChooserPresented)
        XCTAssertFalse(firstLaunch.hasSeenChooser)
        XCTAssertFalse(firstLaunch.isActivated)

        firstLaunch.postpone()
        XCTAssertFalse(firstLaunch.isChooserPresented)
        XCTAssertTrue(firstLaunch.shouldShowReminder)

        let nextLaunch = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        XCTAssertFalse(nextLaunch.isChooserPresented, "稍后再说后不应每次冷启动强弹")
        XCTAssertTrue(nextLaunch.shouldShowReminder, "未激活时首页仍保留轻量完成入口")
    }

    @MainActor
    func testBoundLibraryActivationAccumulatesAcrossReaderPagesAndMatchesSource() throws {
        let suite = "BoundLibraryActivationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        store.select(.kindle)

        for _ in 0..<6 {
            store.recordPlayback(source: .kindle, seconds: 2)
        }
        XCTAssertEqual(store.activationPlaybackSeconds, 12, accuracy: 0.001)
        XCTAssertFalse(store.isActivated, "第一张短页不应单独完成激活")

        for _ in 0..<5 {
            store.recordPlayback(source: .weread, seconds: 2)
        }
        XCTAssertEqual(store.activationPlaybackSeconds, 12, accuracy: 0.001, "不同书库不能混算")

        for _ in 0..<9 {
            store.recordPlayback(source: .kindle, seconds: 2)
        }
        XCTAssertTrue(store.isActivated, "跨 Kindle 页累计到 30 秒必须完成")
        XCTAssertEqual(store.activationPlaybackSeconds, 30, accuracy: 0.001)

        let relaunched = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        XCTAssertTrue(relaunched.isActivated)
        XCTAssertFalse(relaunched.isChooserPresented)
        XCTAssertFalse(relaunched.shouldShowReminder)
    }

    @MainActor
    func testBoundLibraryOnboardingRejectsSeekSizedPlaybackJump() throws {
        let suite = "BoundLibrarySeekTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        store.select(.weread)
        store.recordPlayback(source: .weread, seconds: 20)
        XCTAssertEqual(store.activationPlaybackSeconds, 0, "seek/异常时间跳变不能制造激活")
    }

    @MainActor
    func testBoundLibraryOnboardingV3ResumesTheExactDeferredStep() throws {
        let suite = "BoundLibraryV3ResumeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstLaunch = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        XCTAssertEqual(firstLaunch.phase, .sample)
        XCTAssertFalse(firstLaunch.hasCompletedSample)

        firstLaunch.completeSample()
        XCTAssertEqual(firstLaunch.phase, .storefront)
        XCTAssertTrue(firstLaunch.hasCompletedSample)

        firstLaunch.postpone()
        XCTAssertEqual(firstLaunch.phase, .postponed)
        XCTAssertFalse(firstLaunch.isChooserPresented)

        let relaunched = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        XCTAssertEqual(relaunched.phase, .postponed)
        XCTAssertFalse(relaunched.isChooserPresented)
        relaunched.presentChooser()
        XCTAssertEqual(relaunched.phase, .storefront, "恢复时不应让用户重听已完成的示例")
    }

    @MainActor
    func testBoundLibraryOnboardingV3PersistsRecommendedBookUntilRealPlayback() throws {
        let suite = "BoundLibraryV3BookTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        store.completeSample()
        store.confirmKindleStorefront()
        store.beginKindleScan()
        store.prepareFirstListen(bookID: "book-ready")
        XCTAssertEqual(store.phase, .firstListen)
        XCTAssertEqual(store.recommendedBookID, "book-ready")

        store.startFirstListen(bookID: "book-ready")
        XCTAssertFalse(store.isChooserPresented)
        XCTAssertFalse(store.isActivated, "点书只负责开播，不能代替真实 30 秒激活")

        let relaunched = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        XCTAssertEqual(relaunched.phase, .firstListen)
        XCTAssertEqual(relaunched.recommendedBookID, "book-ready")
        XCTAssertTrue(relaunched.isChooserPresented)

        for _ in 0..<15 {
            relaunched.recordPlayback(source: .kindle, seconds: 2)
        }
        XCTAssertTrue(relaunched.isActivated)
        XCTAssertEqual(relaunched.phase, .activated)
        XCTAssertNil(relaunched.recommendedBookID)
    }

    @MainActor
    func testBoundLibraryOnboardingV1DismissalMigratesWithoutForcingV3() throws {
        let suite = "BoundLibraryV1MigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "boundLibraryOnboarding.v1.hasSeenChooser")
        defaults.set("kindle", forKey: "boundLibraryOnboarding.v1.selectedSource")

        let migrated = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        XCTAssertEqual(migrated.phase, .postponed)
        XCTAssertFalse(migrated.isChooserPresented)
        XCTAssertTrue(migrated.shouldResumeDeferredLibraryFlow)
    }

    @MainActor
    func testChinaAccountDoesNotInheritLegacyActivatedKindleOnboarding() throws {
        let suite = "BoundLibraryChinaScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("kindle", forKey: "boundLibraryOnboarding.v1.selectedSource")
        defaults.set(true, forKey: "boundLibraryOnboarding.v1.hasSeenChooser")
        defaults.set(true, forKey: "boundLibraryOnboarding.v1.isActivated")
        defaults.set("activated", forKey: "boundLibraryOnboarding.v3.phase")
        defaults.set(true, forKey: "boundLibraryOnboarding.v3.hasCompletedSample")

        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        XCTAssertTrue(store.isActivated, "测试前置必须还原真机上的旧 Kindle 状态")

        store.activateAccountScope(
            storageID: String(repeating: "c", count: 64),
            region: .cn,
            migrateLegacyState: true
        )

        XCTAssertFalse(store.isActivated, "中国账号不能继承设备级 Kindle 激活状态")
        XCTAssertNil(store.selectedSource)
        XCTAssertEqual(store.phase, .sample)
        XCTAssertTrue(store.isChooserPresented, "中国账号首次登录后必须展示书架引导")
    }

    @MainActor
    func testRestoredGlobalAccountCopiesLegacyOnboardingOnlyOnce() throws {
        let suite = "BoundLibraryGlobalMigrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = String(repeating: "a", count: 64)

        defaults.set("kindle", forKey: "boundLibraryOnboarding.v1.selectedSource")
        defaults.set(true, forKey: "boundLibraryOnboarding.v1.hasSeenChooser")
        defaults.set(true, forKey: "boundLibraryOnboarding.v1.isActivated")
        defaults.set("activated", forKey: "boundLibraryOnboarding.v3.phase")

        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        store.activateAccountScope(
            storageID: account,
            region: .global,
            migrateLegacyState: true
        )
        XCTAssertTrue(store.isActivated, "升级时已登录的全球老账号不能被强制重走引导")

        store.reset()
        XCTAssertFalse(store.isActivated)
        XCTAssertTrue(store.isChooserPresented)
        store.deactivateAccountScope()
        store.activateAccountScope(
            storageID: account,
            region: .global,
            migrateLegacyState: true
        )

        XCTAssertFalse(store.isActivated, "显式重置后旧设备状态不能再次灌回账号 scope")
        XCTAssertEqual(store.phase, .sample)
        XCTAssertTrue(store.isChooserPresented)
    }

    @MainActor
    func testNewGlobalLoginNeverImportsLegacyStateOnLaterRestore() throws {
        let suite = "BoundLibraryNewGlobalAccountTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = String(repeating: "b", count: 64)

        defaults.set("kindle", forKey: "boundLibraryOnboarding.v1.selectedSource")
        defaults.set(true, forKey: "boundLibraryOnboarding.v1.hasSeenChooser")
        defaults.set(true, forKey: "boundLibraryOnboarding.v1.isActivated")
        defaults.set("activated", forKey: "boundLibraryOnboarding.v3.phase")

        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        store.activateAccountScope(
            storageID: account,
            region: .global,
            migrateLegacyState: false
        )
        XCTAssertFalse(store.isActivated, "新登录账号不能继承另一个旧账号的设备状态")
        store.postpone()

        store.deactivateAccountScope()
        store.activateAccountScope(
            storageID: account,
            region: .global,
            migrateLegacyState: true
        )

        XCTAssertFalse(store.isActivated, "新账号冷启动恢复时也不能补迁移旧设备状态")
        XCTAssertEqual(store.phase, .postponed)
        XCTAssertFalse(store.isChooserPresented)
    }

    @MainActor
    func testBoundLibraryOnboardingReloadsAcrossAccountAndRegionBoundaries() throws {
        let suite = "BoundLibraryBoundaryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let accountA = String(repeating: "1", count: 64)
        let accountB = String(repeating: "2", count: 64)

        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        store.activateAccountScope(storageID: accountA, region: .cn)
        store.select(.weread)
        XCTAssertEqual(store.selectedSource, .weread)
        XCTAssertEqual(store.phase, .postponed)

        store.activateAccountScope(storageID: accountB, region: .cn)
        XCTAssertNil(store.selectedSource, "账号 B 不能看到账号 A 的书架引导进度")
        XCTAssertEqual(store.phase, .sample)
        XCTAssertTrue(store.isChooserPresented)

        store.activateAccountScope(storageID: accountA, region: .cn)
        XCTAssertEqual(store.selectedSource, .weread, "切回账号 A 必须恢复自己的进度")
        XCTAssertEqual(store.phase, .postponed)
        XCTAssertFalse(store.isChooserPresented)

        store.activateAccountScope(storageID: accountA, region: .global)
        XCTAssertNil(store.selectedSource, "同一账号的全球与中国产品引导必须隔离")
        XCTAssertEqual(store.phase, .sample)
        XCTAssertTrue(store.isChooserPresented)

        store.deactivateAccountScope()
        XCTAssertFalse(store.isChooserPresented, "退出登录时不能把引导盖在登录页上")
        store.activateAccountScope(storageID: accountA, region: .cn)
        XCTAssertEqual(store.selectedSource, .weread, "登出不能删除账号自己的引导进度")
    }

    @MainActor
    func testResetLaunchArgumentClearsRestoredAccountScopeWithoutLegacyRefill() throws {
        let suite = "BoundLibraryScopedResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = String(repeating: "d", count: 64)
        let scopedPrefix = ".region.global.account.\(account)"

        defaults.set("kindle", forKey: "boundLibraryOnboarding.v1.selectedSource")
        defaults.set(true, forKey: "boundLibraryOnboarding.v1.isActivated")
        defaults.set("kindle", forKey: "boundLibraryOnboarding.v1.selectedSource\(scopedPrefix)")
        defaults.set(true, forKey: "boundLibraryOnboarding.v1.isActivated\(scopedPrefix)")
        defaults.set("activated", forKey: "boundLibraryOnboarding.v3.phase\(scopedPrefix)")

        let store = BoundLibraryOnboardingStore(
            defaults: defaults,
            arguments: ["-CastReaderResetLibraryOnboarding"]
        )
        store.activateAccountScope(
            storageID: account,
            region: .global,
            migrateLegacyState: true
        )

        XCTAssertFalse(store.isActivated)
        XCTAssertNil(store.selectedSource)
        XCTAssertEqual(store.phase, .sample)
        XCTAssertTrue(store.isChooserPresented)

        store.deactivateAccountScope()
        store.activateAccountScope(
            storageID: account,
            region: .global,
            migrateLegacyState: true
        )
        XCTAssertFalse(store.isActivated, "reset 后不能从 legacy 状态重新灌回")
        XCTAssertEqual(store.phase, .sample)
    }

    @MainActor
    func testActivatedUserCanReplayOnboardingWithoutLosingActivation() throws {
        let suite = "BoundLibraryReplayTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        store.markActivatedIfNeeded(source: .kindle, playbackSeconds: 30)
        XCTAssertTrue(store.isActivated)

        store.presentChooser()
        XCTAssertTrue(store.isChooserPresented)
        XCTAssertEqual(store.phase, .sample)
        store.completeSample()
        XCTAssertEqual(store.phase, .storefront)
        store.confirmKindleStorefront()
        XCTAssertEqual(store.phase, .login)
        XCTAssertTrue(store.isActivated, "重新体验引导不应清空已获得的激活")
    }

    @MainActor
    func testKindleConfirmationResetsPlaybackFromAnotherProvider() throws {
        let suite = "BoundLibrarySourceSwitchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = BoundLibraryOnboardingStore(defaults: defaults, arguments: [])
        store.select(.weread)
        for _ in 0..<5 { store.recordPlayback(source: .weread, seconds: 2) }
        XCTAssertEqual(store.activationPlaybackSeconds, 10, accuracy: 0.001)

        store.presentChooser()
        store.confirmKindleStorefront()
        XCTAssertEqual(store.selectedSource, .kindle)
        XCTAssertEqual(store.activationPlaybackSeconds, 0, accuracy: 0.001)
    }

    func testKindleOnboardingRecommendationPrefersListeningAnchorThenRecentBook() {
        var anchored = kindleBook(
            id: "B000000001",
            asin: "B000000001",
            title: "Anchored",
            url: "https://read.amazon.com/?asin=B000000001"
        )
        anchored.storefrontID = "us"
        anchored.lastOpenedAt = Date(timeIntervalSince1970: 10)

        var recent = kindleBook(
            id: "B000000002",
            asin: "B000000002",
            title: "Recent",
            url: "https://read.amazon.com/?asin=B000000002"
        )
        recent.storefrontID = "us"
        recent.lastOpenedAt = Date(timeIntervalSince1970: 20)

        var wrongStore = kindleBook(
            id: "B000000003",
            asin: "B000000003",
            title: "Wrong storefront",
            url: "https://leer.amazon.es/?asin=B000000003"
        )
        wrongStore.storefrontID = "es"
        wrongStore.lastOpenedAt = Date(timeIntervalSince1970: 30)

        let recommendation = KindleOnboardingBookRecommendation.choose(
            from: [wrongStore, recent, anchored],
            expectedStorefrontID: "us",
            hasListeningAnchor: { $0 == anchored.id }
        )
        XCTAssertEqual(recommendation?.id, anchored.id)

        let withoutAnchor = KindleOnboardingBookRecommendation.choose(
            from: [wrongStore, anchored, recent],
            expectedStorefrontID: "us"
        )
        XCTAssertEqual(withoutAnchor?.id, recent.id)
    }

    // MARK: - 场景化「划重点·批注」content_type 全链路自检（PRD P0）

    private func encodedJSON<T: Encodable>(_ v: T) throws -> String {
        let data = try JSONEncoder().encode(v)
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// §7.2：场景进入时 extract-plan 请求体须含 content_type，且 nil 时字段省略（§2.1 向后兼容、零回归）。
    func testExtractPlanEncodesContentType() throws {
        let withCT = ExtractPlanRequest(
            source_url: "castreader://doc/x", title: "T", lang: nil, depth: "deep",
            text: "t", fullText: "t", paragraphs: [], prev_summary: nil, content_type: "paper")
        let json = try encodedJSON(withCT)
        XCTAssertTrue(json.contains("\"content_type\":\"paper\""), "content_type 应被编码: \(json)")

        let general = ExtractPlanRequest(
            source_url: "castreader://doc/x", title: "T", lang: nil, depth: "standard",
            text: "t", fullText: "t", paragraphs: [], prev_summary: nil, content_type: nil)
        XCTAssertFalse(try encodedJSON(general).contains("content_type"), "nil content_type 应省略字段（零回归）")
    }

    /// 快道 fast-block0 同样带 content_type。
    func testFastBlock0EncodesContentType() throws {
        let req = FastBlock0Request(
            title: "T", openingParas: [FastBlock0OpeningPara(text: "a")],
            lang: nil, depth: "deep", prev_summary: nil, content_type: "contract")
        XCTAssertTrue(try encodedJSON(req).contains("\"content_type\":\"contract\""))
    }

    /// content_type 与 depth 正交：场景**不**覆盖用户深度。设深度=速览，进「论文」场景，requestDepth 仍=速览。
    @MainActor
    func testScenarioDoesNotOverrideDepth() {
        let prev = AppSettings.shared.explainDepth
        defer { AppSettings.shared.explainDepth = prev }

        let doc = ReadingDocument(title: "T", sourceKind: .text,
                                  paragraphs: [ReadingParagraph(id: 0, text: "hello world", type: .paragraph)])
        let vm = ExplainViewModel(document: doc)

        AppSettings.shared.explainDepth = QuickreadDepth.overview.rawValue
        vm.scenario = ExplainContentType.paper.rawValue   // 论文（旧逻辑会强制 deep）
        XCTAssertEqual(vm.requestDepth, "overview", "场景不应覆盖用户深度")

        AppSettings.shared.explainDepth = QuickreadDepth.deep.rawValue
        XCTAssertEqual(vm.requestDepth, "deep", "深度始终跟随用户设置")

        XCTAssertEqual(ExplainContentType.allCases.count, 6)
    }

    /// content_type 的 rawValue 必须是后端约定的 6 个 id（§4 契约）。
    func testContentTypeRawValues() {
        XCTAssertEqual(Set(ExplainContentType.allCases.map(\.rawValue)),
                       ["paper", "book", "report", "contract", "study", "manual"])
    }

    /// 场景只改变导入来源排序，不限制来源能力；尤其说明书 / Git 文档必须支持 Web 链接。
    func testScenarioImportSourcesAreRecommendationsOnly() {
        let allSources = Set(ImportSource.allCases)
        for ct in ExplainContentType.allCases {
            XCTAssertEqual(Set(ImportSource.sources(for: ct)), allSources, "\(ct.rawValue) 不应缺导入来源")
        }

        XCTAssertEqual(ImportSource.sources(for: .manual).first, .url, "说明书 / 文档场景应优先支持 Web 链接")
        XCTAssertEqual(ImportSource.general.first, .url, "底部 + 快速导入应优先支持 Web 链接")
    }

    /// 场景注入 ExplainViewModel：scenario 被正确设置（驱动 content_type，不动深度）。
    @MainActor
    func testScenarioInjection() {
        let doc = ReadingDocument(title: "T", sourceKind: .text,
                                  paragraphs: [ReadingParagraph(id: 0, text: "hello world", type: .paragraph)])
        let vm = ExplainViewModel(document: doc)
        vm.scenario = ExplainContentType.paper.rawValue
        XCTAssertEqual(vm.scenario, "paper")
    }

    // MARK: - P1 分层标注：weight → 笔触粗细

    func testWeightMultiplier() {
        XCTAssertEqual(HandwrittenMark.weightMultiplier("primary"), 1.6)
        XCTAssertEqual(HandwrittenMark.weightMultiplier("tertiary"), 0.65)
        XCTAssertEqual(HandwrittenMark.weightMultiplier("secondary"), 1.0)
        XCTAssertEqual(HandwrittenMark.weightMultiplier(nil), 1.0)   // 后端没给 → 零回归
    }

    /// mark 事件解码出 weight/role（后端 P1 字段；缺省时为 nil）。
    func testQuickreadEventDecodesWeightRole() throws {
        let json = #"{"action":"wave","text":"风险","weight":"primary","role":"caution"}"#.data(using: .utf8)!
        let ev = try JSONDecoder().decode(QuickreadEvent.self, from: json)
        XCTAssertEqual(ev.action, "wave")
        XCTAssertEqual(ev.weight, "primary")
        XCTAssertEqual(ev.role, "caution")

        let bare = #"{"action":"underline","text":"x"}"#.data(using: .utf8)!
        let ev2 = try JSONDecoder().decode(QuickreadEvent.self, from: bare)
        XCTAssertNil(ev2.weight)
    }

    /// fast-block0 同样要接住场景化标注的样式与分层字段；否则首块会把 wave/star 等新 mark 丢薄。
    func testFastBlock0MarkDecodesScenarioFields() throws {
        let json = #"{"style":"star","text":"a key sentence","n":2,"weight":"primary","role":"key","note":"why it matters"}"#.data(using: .utf8)!
        let mark = try JSONDecoder().decode(FastBlock0Mark.self, from: json)
        XCTAssertEqual(mark.style, "star")
        XCTAssertEqual(mark.text, "a key sentence")
        XCTAssertEqual(mark.n, 2)
        XCTAssertEqual(mark.weight, "primary")
        XCTAssertEqual(mark.role, "key")
        XCTAssertEqual(mark.note, "why it matters")
    }

    // MARK: - 封面 + 标题：网页元数据解析

    func testLinkMetadataParsesOGTitleAndImage() {
        let html = """
        <html><head>
        <title>Fallback Title</title>
        <meta property="og:title" content="Real Article Title &amp; More">
        <meta property="og:image" content="https://cdn.example.com/cover.jpg">
        </head><body></body></html>
        """
        let r = LinkMetadata.parse(html: html, baseURL: URL(string: "https://example.com/post")!)
        XCTAssertEqual(r.title, "Real Article Title & More")   // og 优先 + 实体解码
        XCTAssertEqual(r.imageURL, "https://cdn.example.com/cover.jpg")
    }

    func testLinkMetadataResolvesRelativeImageAndFallsBackToTitleTag() {
        let html = """
        <head><title>Only Title Tag</title>
        <meta name="twitter:image" content="/img/cover.png"></head>
        """
        let r = LinkMetadata.parse(html: html, baseURL: URL(string: "https://blog.example.com/a/b")!)
        XCTAssertEqual(r.title, "Only Title Tag")                          // 无 og:title → 回退 <title>
        XCTAssertEqual(r.imageURL, "https://blog.example.com/img/cover.png") // 相对路径解析为绝对
    }

    func testLinkMetadataNoMetaReturnsNilImage() {
        let r = LinkMetadata.parse(html: "<html><head></head><body>hi</body></html>",
                                   baseURL: URL(string: "https://x.com")!)
        XCTAssertNil(r.imageURL)
    }

    // MARK: - Kindle 书架扫描防误判

    private func kindleBook(
        id: String,
        asin: String? = nil,
        title: String,
        url: String
    ) -> KindleBook {
        KindleBook(
            id: id,
            asin: asin,
            title: title,
            author: "",
            coverURL: nil,
            readerURL: url,
            progressLabel: "",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastReadPageKey: nil,
            lastReadURL: nil
        )
    }

    func testKindleBookValidatorRejectsAmazonMarketingLinks() {
        let fakeBooks = [
            kindleBook(id: "download", title: "在应用商店中下载", url: "https://read.amazon.com/kindle-library"),
            kindleBook(id: "learn-more", title: "了解更多有关 Kindle APP 的信息", url: "https://read.amazon.com/landing"),
            kindleBook(id: "any-device", title: "在任何设备上阅读 read.amazon.com", url: "https://read.amazon.com/kindle-library"),
            kindleBook(id: "app", title: "Download the Kindle App", url: "https://read.amazon.com/download")
        ]

        for book in fakeBooks {
            XCTAssertFalse(book.isLikelyLibraryBook, "不应把 Kindle 引导/营销链接当成书：\(book.title)")
        }
    }

    func testKindleBookValidatorAcceptsReaderBooks() {
        XCTAssertTrue(
            kindleBook(
                id: "B012345678",
                asin: "B012345678",
                title: "A Real Kindle Book",
                url: "https://read.amazon.com/?asin=B012345678"
            ).isLikelyLibraryBook
        )

        XCTAssertTrue(
            kindleBook(
                id: "reader",
                title: "Another Real Kindle Book",
                url: "https://read.amazon.com/reader/B012345678"
            ).isLikelyLibraryBook
        )
    }

    // MARK: - 文件标题推导（PDF/DOCX 不再只用文件名）

    func testPDFTitlePrefersMeaningfulMetadata() {
        // 有意义的元数据标题 → 直接用
        XCTAssertEqual(DocumentBuilder.derivePDFTitle(meta: "Attention Is All You Need",
                                                      firstText: "arXiv:1706.03762 Provided proper...", fallback: "1706.03762"),
                       "Attention Is All You Need")
        // 垃圾元数据（Office 导出）→ 回退首段文本（截断）
        XCTAssertEqual(DocumentBuilder.derivePDFTitle(meta: "Microsoft Word - doc1.docx",
                                                      firstText: "季度财务报告与风险提示", fallback: "doc1"),
                       "季度财务报告与风险提示")
        // 无元数据、首段太短 → 文件名兜底
        XCTAssertEqual(DocumentBuilder.derivePDFTitle(meta: nil, firstText: "x", fallback: "report"), "report")
    }

    func testIsMeaningfulTitle() {
        XCTAssertTrue(DocumentBuilder.isMeaningfulTitle("Deep Residual Learning"))
        XCTAssertFalse(DocumentBuilder.isMeaningfulTitle("untitled"))
        XCTAssertFalse(DocumentBuilder.isMeaningfulTitle("Microsoft Word - Document1"))
        XCTAssertFalse(DocumentBuilder.isMeaningfulTitle(" "))
    }

    // MARK: - Kindle Audiobook sentence resume anchor

    private func anchorParagraph(id: Int, _ text: String) -> ReadingParagraph {
        let words = text.split(whereSeparator: { $0.isWhitespace }).enumerated().map {
            OCRWord(id: $0.offset, text: String($0.element), bboxNorm: .zero)
        }
        return ReadingParagraph(id: id, text: text, words: words, pageIndex: 0)
    }

    private func listeningAnchor(
        paragraphs: [ReadingParagraph],
        targetParagraph: Int,
        targetWord: Int,
        pageKey: String = "page-real-1",
        schemaVersion: Int = KindleListeningAnchor.currentSchemaVersion,
        readerVersion: Int = KindleListeningAnchor.currentReaderImplementationVersion
    ) -> KindleListeningAnchor {
        let paragraph = paragraphs.first(where: { $0.id == targetParagraph })!
        let charOffset = KindleListeningAnchorResolver.charOffset(in: paragraph, wordIndex: targetWord)
        let phrase = KindleListeningAnchorResolver.anchorPhrase(in: paragraph.text, charOffset: charOffset)
        return KindleListeningAnchor(
            bookId: "book-1",
            pageKey: pageKey,
            pageTextHash: KindleListeningAnchorResolver.pageTextHash(paragraphs: paragraphs),
            paragraphIndex: targetParagraph,
            wordIndex: targetWord,
            charOffset: charOffset,
            anchorPhrase: phrase.phrase,
            anchorWordOffset: phrase.anchorWordOffset,
            voice: "af_heart",
            speed: 1.5,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            schemaVersion: schemaVersion,
            readerImplementationVersion: readerVersion
        )
    }

    func testKindleListeningAnchorExactSamePageMatch() {
        let paragraphs = [
            anchorParagraph(id: 0, "An opening paragraph establishes the scene for this page."),
            anchorParagraph(id: 1, "The narrator now reaches the exact sentence that should continue after reopening the book.")
        ]
        let anchor = listeningAnchor(paragraphs: paragraphs, targetParagraph: 1, targetWord: 6)
        let result = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "page-real-1",
            paragraphs: paragraphs
        )
        XCTAssertEqual(result.match, .exact)
        XCTAssertEqual(result.paragraphIndex, 1)
        XCTAssertEqual(result.wordIndex, 6)
    }

    func testKindleListeningAnchorRelocatesAfterSmallTextChange() {
        let original = [
            anchorParagraph(id: 0, "An opening paragraph establishes the scene for this page."),
            anchorParagraph(id: 1, "The narrator now reaches the exact sentence that should continue after reopening the book.")
        ]
        let anchor = listeningAnchor(paragraphs: original, targetParagraph: 1, targetWord: 6)
        let changed = [
            anchorParagraph(id: 0, "A newly recognized heading appears before the original OCR text."),
            anchorParagraph(id: 1, original[0].text),
            anchorParagraph(id: 2, original[1].text)
        ]
        let result = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "page-real-1",
            paragraphs: changed
        )
        XCTAssertEqual(result.match, .relocated)
        XCTAssertEqual(result.paragraphIndex, 2)
        XCTAssertEqual(result.reason, "anchor-fuzzy")
    }

    func testKindleListeningAnchorInvalidPageAndHashFallBackSafely() {
        let original = [
            anchorParagraph(id: 0, "Original words locate a unique sentence in the captured Kindle page."),
            anchorParagraph(id: 1, "Another readable paragraph follows it for the rest of the page.")
        ]
        let anchor = listeningAnchor(paragraphs: original, targetParagraph: 1, targetWord: 3)
        let pageMismatch = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "different-real-page",
            paragraphs: original
        )
        XCTAssertEqual(pageMismatch.match, .fallback)
        XCTAssertEqual(pageMismatch.paragraphIndex, 0)
        XCTAssertEqual(pageMismatch.reason, "page-key-mismatch")

        let unrelated = [anchorParagraph(id: 0, "Completely unrelated replacement content without the saved token window.")]
        let hashMismatch = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "page-real-1",
            paragraphs: unrelated
        )
        XCTAssertEqual(hashMismatch.match, .fallback)
        XCTAssertEqual(hashMismatch.paragraphIndex, 0)
    }

    func testKindleListeningAnchorOldSchemaFallsBack() {
        let paragraphs = [anchorParagraph(id: 0, "A valid page still rejects an anchor written by an obsolete schema.")]
        let anchor = listeningAnchor(
            paragraphs: paragraphs,
            targetParagraph: 0,
            targetWord: 4,
            schemaVersion: 0
        )
        let result = KindleListeningAnchorResolver.resolve(
            anchor,
            bookId: "book-1",
            pageKey: "page-real-1",
            paragraphs: paragraphs
        )
        XCTAssertEqual(result.match, .fallback)
        XCTAssertEqual(result.reason, "schema-mismatch")
    }

    func testKindleContinueListeningAutoplayGateConsumesOncePerBook() {
        let gate = KindleAutoplayRequestGate()
        XCTAssertEqual(gate.request(for: "book-a"), 1)
        XCTAssertEqual(gate.consume(for: "book-a"), 1)
        XCTAssertNil(gate.consume(for: "book-a"), "同一请求的重复 WebKit ready 回调不得再次 autoplay")

        XCTAssertEqual(gate.request(for: "book-b"), 1)
        XCTAssertEqual(gate.request(for: "book-b"), 2)
        XCTAssertEqual(gate.consume(for: "book-b"), 2, "连续点击应合并为最新一次 ensurePlaying 请求")
        XCTAssertNil(gate.consume(for: "book-b"))
    }

    func testKindleSyncDialogEventParsesLocationsWithoutBodyText() throws {
        let event = try XCTUnwrap(KindleSyncDialogEvent(payload: [
            "type": "kindle-sync-dialog",
            "visible": true,
            "localLocation": 1097,
            "cloudLocation": "1088"
        ]))
        XCTAssertTrue(event.isVisible)
        XCTAssertEqual(event.localLocation, 1097)
        XCTAssertEqual(event.cloudLocation, 1088)
        XCTAssertNil(event.choice)
    }

    func testKindleSyncDialogChoiceIsSeparateFromPageTruth() throws {
        let event = try XCTUnwrap(KindleSyncDialogEvent(payload: [
            "type": "kindle-sync-dialog-choice",
            "visible": true,
            "choice": "no",
            "localLocation": 1097,
            "cloudLocation": 1088
        ]))
        XCTAssertEqual(event.choice, .no)
        XCTAssertEqual(event.localLocation, 1097)
        XCTAssertEqual(event.cloudLocation, 1088)
    }

    @MainActor
    func testKindleSyncDialogBootstrapDetectsDialogAndChoice() async throws {
        let collector = KindleTestMessageCollector()
        let controller = WKUserContentController()
        controller.add(collector, name: "castReaderKindle")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        let window = UIWindow(frame: webView.frame)
        window.isHidden = false
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.loadHTMLString(
            """
            <!doctype html><html><body>
            <div role="dialog" aria-modal="true" style="position:fixed;left:30px;top:120px;width:330px;height:240px">
              <h2>Most Recent Page Read</h2>
              <p>You're on location 1097. The most recent location is 1088. Go to location 1088?</p>
              <button id="no">No</button><button id="yes">Yes</button>
            </div>
            <button id="kr-chevron-right" aria-label="Next page" style="opacity:0;pointer-events:none">Next</button>
            <script>
              window.hiddenChevronClickCount = 0;
              window.hiddenKeyboardTurnCount = 0;
              document.getElementById('kr-chevron-right').addEventListener('click', function() {
                window.hiddenChevronClickCount += 1;
              });
              window.addEventListener('keydown', function(event) {
                if (event.key === 'ArrowRight') window.hiddenKeyboardTurnCount += 1;
              });
            </script>
            </body></html>
            """,
            baseURL: URL(string: "https://read.amazon.com")
        )
        for _ in 0..<30 {
            if let loaded = try? await webView.evaluateJavaScript("!!document.querySelector('[role=dialog]')") as? Bool,
               loaded { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        _ = try await webView.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap)

        for _ in 0..<30 where !collector.messages.contains(where: { ($0["type"] as? String) == "kindle-sync-dialog" }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let shownPayload = try XCTUnwrap(collector.messages.first(where: { ($0["type"] as? String) == "kindle-sync-dialog" }))
        let shown = try XCTUnwrap(KindleSyncDialogEvent(payload: shownPayload))
        XCTAssertEqual(shown.localLocation, 1097)
        XCTAssertEqual(shown.cloudLocation, 1088)

        _ = try await webView.evaluateJavaScript("document.getElementById('no').click()")
        for _ in 0..<20 where !collector.messages.contains(where: { ($0["type"] as? String) == "kindle-sync-dialog-choice" }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let choicePayload = try XCTUnwrap(collector.messages.first(where: { ($0["type"] as? String) == "kindle-sync-dialog-choice" }))
        XCTAssertEqual(KindleSyncDialogEvent(payload: choicePayload)?.choice, .no)

        _ = try await webView.evaluateJavaScript(
            """
            (function() {
              var leaf = document.createElement('span');
              document.getElementById('kr-chevron-right').appendChild(leaf);
              window.leftActionCount = 0;
              window.rightActionCount = 0;
              var root = { memoizedProps:{}, pendingProps:{
                leftAction:function(){ window.leftActionCount += 1; },
                rightAction:function(){ window.rightActionCount += 1; },
                pageProgressionDirection:'ltr'
              }, return:null, type:{name:'KindlePagination'} };
              var fiber = root;
              for (var i = 0; i < 24; i++) fiber = { memoizedProps:{ onClick:function(){} }, pendingProps:{}, return:fiber };
              leaf.__reactFiber$test = fiber;
            })()
            """
        )
        let rawTurn = try await webView.evaluateJavaScript("window.__crKindleSemanticPageTurn('next')")
        let turnJSON = try XCTUnwrap(rawTurn as? String)
        let turnData = try XCTUnwrap(turnJSON.data(using: .utf8))
        let turn = try XCTUnwrap(JSONSerialization.jsonObject(with: turnData) as? [String: Any])
        XCTAssertEqual(turn["strategy"] as? String, "react-paired-action")
        XCTAssertEqual(turn["propsSource"] as? String, "pendingProps")
        XCTAssertEqual(turn["fiberDepth"] as? Int, 24)
        XCTAssertEqual(turn["dispatchCount"] as? Int, 1)
        let rightActionCount = try await webView.evaluateJavaScript("window.rightActionCount") as? Int
        let leftActionCount = try await webView.evaluateJavaScript("window.leftActionCount") as? Int
        let hiddenChevronClickCount = try await webView.evaluateJavaScript("window.hiddenChevronClickCount") as? Int
        let hiddenKeyboardTurnCount = try await webView.evaluateJavaScript("window.hiddenKeyboardTurnCount") as? Int
        XCTAssertEqual(rightActionCount, 1)
        XCTAssertEqual(leftActionCount, 0)
        XCTAssertEqual(hiddenChevronClickCount, 0)
        XCTAssertEqual(hiddenKeyboardTurnCount, 0)

        let rtlFallbackRaw = try await webView.evaluateJavaScript(
            """
            (function() {
              var leaf = document.querySelector('#kr-chevron-right span');
              leaf.__reactFiber$test = { memoizedProps:{
                leftAction:function(){ window.leftActionCount += 1; },
                rightAction:function(){ window.rightActionCount += 1; }
              }, pendingProps:{}, return:null, type:{name:'KindlePagination'} };
              return window.__crKindleSemanticPageTurn('next', 'rtl');
            })()
            """
        )
        let rtlFallbackData = try XCTUnwrap((rtlFallbackRaw as? String)?.data(using: .utf8))
        let rtlFallback = try XCTUnwrap(JSONSerialization.jsonObject(with: rtlFallbackData) as? [String: Any])
        XCTAssertEqual(rtlFallback["semanticAction"] as? String, "leftAction")
        XCTAssertEqual(rtlFallback["progressionSource"] as? String, "language-fallback")
        let rtlLeftActionCount = try await webView.evaluateJavaScript("window.leftActionCount") as? Int
        XCTAssertEqual(rtlLeftActionCount, 1)

        let compatibilityRaw = try await webView.evaluateJavaScript(
            "[window.__crKindleDirectPage('right'), window.__crKindleForceAdjacentPage('left')]"
        )
        let compatibility = try XCTUnwrap(compatibilityRaw as? [String])
        XCTAssertEqual(compatibility.count, 2)
        for raw in compatibility {
            let data = try XCTUnwrap(raw.data(using: .utf8))
            let result = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(result["strategy"] as? String, "react-paired-action")
            XCTAssertEqual(result["dispatchCount"] as? Int, 1)
        }
        let compatibilityRightCount = try await webView.evaluateJavaScript("window.rightActionCount") as? Int
        let compatibilityLeftCount = try await webView.evaluateJavaScript("window.leftActionCount") as? Int
        XCTAssertEqual(compatibilityRightCount, 2)
        XCTAssertEqual(compatibilityLeftCount, 2)

        let singleHandlerRaw = try await webView.evaluateJavaScript(
            """
            (function() {
              var leaf = document.querySelector('#kr-chevron-right span');
              leaf.__reactFiber$test = { memoizedProps:{ onClick:function(){} }, pendingProps:{}, return:null };
              return window.__crKindleSemanticPageTurn('next');
            })()
            """
        )
        let singleHandlerData = try XCTUnwrap((singleHandlerRaw as? String)?.data(using: .utf8))
        let singleHandler = try XCTUnwrap(JSONSerialization.jsonObject(with: singleHandlerData) as? [String: Any])
        XCTAssertEqual(singleHandler["ok"] as? Bool, false, "单个 click handler 不能冒充 paired pagination actions")
    }

    @MainActor
    func testKindleEarlyBlobCaptureRunsBeforePageScriptsAndSurvivesRevoke() async throws {
        let controller = WKUserContentController()
        if #available(iOS 14.0, *) {
            controller.addUserScript(WKUserScript(
                source: KindleWebScripts.earlyPageBlobCaptureBootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
        } else {
            controller.addUserScript(WKUserScript(
                source: KindleWebScripts.earlyPageBlobCaptureBootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 800),
            configuration: configuration
        )
        let window = UIWindow(frame: webView.frame)
        window.isHidden = false
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.loadHTMLString(
            """
            <!doctype html><html><body>
            <script>
              window.fixtureBlobURL = URL.createObjectURL(
                new Blob([new Uint8Array([137,80,78,71,13,10,26,10,1,2,3,4])], {type:'image/png'})
              );
              URL.revokeObjectURL(window.fixtureBlobURL);
            </script>
            </body></html>
            """,
            baseURL: URL(string: "https://read.amazon.com")
        )

        var captured: [String: Any]?
        for _ in 0..<80 {
            if let raw = try? await webView.evaluateJavaScript(
                """
                JSON.stringify({
                  ready: window.__crKindleEarlyBlobCaptureReady === true,
                  count: Number(window.__crKindleProbe && window.__crKindleProbe.earlyCapturedBlobCount || 0),
                  key: String(window.__crKindleProbe && window.__crKindleProbe.urlToKey.get(window.fixtureBlobURL) || ''),
                  live: String((function() {
                    var p = window.__crKindleProbe;
                    var key = p && p.urlToKey.get(window.fixtureBlobURL);
                    return key && p.keyToLiveUrl.get(key) || '';
                  })()),
                  held: Number(window.__crKindleProbe && window.__crKindleProbe.heldPageKeys.length || 0),
                  heldKey: String(window.__crKindleProbe && window.__crKindleProbe.heldPageKeys[0] || '')
                })
                """
            ) as? String,
               let data = raw.data(using: .utf8),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                captured = result
                if (result["count"] as? Int ?? 0) > 0 { break }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let result = try XCTUnwrap(captured)
        XCTAssertEqual(result["ready"] as? Bool, true)
        XCTAssertEqual(result["count"] as? Int, 1, "页面内联脚本创建 blob 前必须已安装 hook")
        XCTAssertEqual((result["key"] as? String)?.count, 16)
        XCTAssertTrue((result["live"] as? String)?.hasPrefix("blob:") == true)
        XCTAssertEqual(result["held"] as? Int, 1)
        XCTAssertEqual(
            result["heldKey"] as? String,
            "content-\(result["key"] as? String ?? "")",
            "候选顺序必须与 stableImageKey 使用同一个 content-* 命名空间"
        )

        _ = try await webView.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap)
        let preserved = try await webView.evaluateJavaScript(
            """
            (function() {
              var p = window.__crKindleProbe;
              var key = p && p.urlToKey.get(window.fixtureBlobURL);
              return !!(key && p.keyToLiveUrl.get(key) && p.heldPageKeys.indexOf('content-' + key) >= 0);
            })()
            """
        ) as? Bool
        XCTAssertEqual(preserved, true, "延迟安装完整脚本时不得丢失早期捕获的页面")
    }

    @MainActor
    func testKindlePreloadCapturesBroadHeldWindowWithoutTrustingOneNeighbor() async throws {
        let controller = WKUserContentController()
        if #available(iOS 14.0, *) {
            controller.addUserScript(WKUserScript(
                source: KindleWebScripts.earlyPageBlobCaptureBootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
        } else {
            controller.addUserScript(WKUserScript(
                source: KindleWebScripts.earlyPageBlobCaptureBootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 800),
            configuration: configuration
        )
        let window = UIWindow(frame: webView.frame)
        window.isHidden = false
        window.addSubview(webView)
        defer { webView.removeFromSuperview() }

        webView.loadHTMLString(
            """
            <!doctype html><html><head><style>
              html,body { margin:0; width:390px; min-height:1600px; }
              img { display:block; width:300px; height:500px; }
              #next { margin-top:700px; }
            </style></head><body>
              <img id="current"><img id="next">
              <script>
                function pageBlob(label, color) {
                  var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="600" height="1000">' +
                    '<rect width="600" height="1000" fill="' + color + '"/>' +
                    '<text x="40" y="100" font-size="52">' + label + '</text></svg>';
                  return new Blob([svg], {type:'image/svg+xml'});
                }
                async function createMapped(label, color) {
                  var url = URL.createObjectURL(pageBlob(label, color));
                  for (var i = 0; i < 100; i++) {
                    if (window.__crKindleProbe.urlToKey.get(url)) return url;
                    await new Promise(function(resolve) { setTimeout(resolve, 5); });
                  }
                  return url;
                }
                (async function() {
                  window.fixtureCurrentURL = await createMapped('CURRENT', '#fff');
                  window.fixtureStaleURL = await createMapped('STALE', '#fcc');
                  window.fixtureNextURL = await createMapped('NEXT', '#cfc');
                  document.getElementById('current').src = window.fixtureCurrentURL;
                  document.getElementById('next').src = window.fixtureNextURL;
                  await Promise.all(Array.from(document.images).map(function(img) {
                    return img.decode ? img.decode().catch(function(){}) : Promise.resolve();
                  }));
                  window.fixtureReady = true;
                })();
              </script>
            </body></html>
            """,
            baseURL: URL(string: "https://read.amazon.com")
        )

        var fixture: [String: Any]?
        for _ in 0..<120 {
            if let raw = try? await webView.evaluateJavaScript(
                """
                JSON.stringify({
                  ready: window.fixtureReady === true,
                  current: String(window.__crKindleProbe && window.__crKindleProbe.urlToKey.get(window.fixtureCurrentURL) || ''),
                  stale: String(window.__crKindleProbe && window.__crKindleProbe.urlToKey.get(window.fixtureStaleURL) || ''),
                  next: String(window.__crKindleProbe && window.__crKindleProbe.urlToKey.get(window.fixtureNextURL) || ''),
                  held: (window.__crKindleProbe && window.__crKindleProbe.heldPageKeys || []).slice()
                })
                """
            ) as? String,
               let data = raw.data(using: .utf8),
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                fixture = result
                if result["ready"] as? Bool == true { break }
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }

        let state = try XCTUnwrap(fixture)
        XCTAssertEqual(state["ready"] as? Bool, true)
        let currentKey = try XCTUnwrap(state["current"] as? String)
        let staleKey = try XCTUnwrap(state["stale"] as? String)
        let nextKey = try XCTUnwrap(state["next"] as? String)
        XCTAssertEqual(
            state["held"] as? [String],
            ["content-\(currentKey)", "content-\(staleKey)", "content-\(nextKey)"],
            "测试前提：Blob 历史顺序故意把无关页放在实际相邻页之前"
        )

        _ = try await webView.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap)
        let candidateScript =
            """
            window.__crKindleCandidateSnapshotsAfterKey(
              'content-\(currentKey)', 2, 640, 0.86
            )
            """
        _ = try await webView.evaluateJavaScript(candidateScript)
        try await Task.sleep(nanoseconds: 240_000_000)
        let evaluated = try await webView.evaluateJavaScript(candidateScript) as? String
        let raw = try XCTUnwrap(evaluated)
        let data = try XCTUnwrap(raw.data(using: .utf8))
        let result = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let pages = result["pages"] as? [[String: Any]] ?? []
        XCTAssertEqual(pages.count, 2)
        let capturedKeys = Set(pages.compactMap { $0["key"] as? String })
        XCTAssertEqual(
            capturedKeys,
            Set(["content-\(staleKey)", "content-\(nextKey)"]),
            "预加载必须缓存整个候选窗口，不能把任一 Blob/DOM 相邻关系当成真实翻页顺序"
        )
        XCTAssertEqual(pages.first?["source"] as? String, "held-adjacent-speculation")
    }

    func testKindleNineLanguageAndPageEvidenceContracts() throws {
        let expected = [
            "en-US":"en", "zh-CN":"zh", "ja-JP":"ja", "es-ES":"es",
            "fr-FR":"fr", "de-DE":"de", "deu":"de", "ger":"de",
            "pt-BR":"pt", "it-IT":"it", "hi-IN":"hi", "pt-PT":"pt", "por":"pt"
        ]
        for (input, language) in expected {
            XCTAssertEqual(KindleLanguageContract.profile(language: input)?.language, language)
        }
        XCTAssertEqual(KindleLanguageContract.profile(language: "pt-PT")?.visionLocale, "pt-BR")
        XCTAssertEqual(KindleLanguageContract.profile(language: "zh")?.visionLocale, "zh-Hans")
        XCTAssertEqual(KindleLanguageContract.profile(language: "zh")?.tesseractModel, "chi_sim")
        XCTAssertEqual(KindleLanguageContract.profile(language: "hi")?.tesseractModel, "hin")
        XCTAssertEqual(KindleLanguageContract.profile(language: "de")?.tesseractModel, "deu")
        XCTAssertEqual(
            ["en", "zh", "ja", "es", "fr", "de", "pt", "it", "hi"].compactMap {
                KindleLanguageContract.profile(language: $0)?.tesseractModel
            },
            ["eng", "chi_sim", "jpn", "spa", "fra", "deu", "por", "ita", "hin"]
        )
        XCTAssertEqual(KindleLanguageContract.profile(language: "ja")?.readingDirection, .rtl)
        XCTAssertFalse(
            try XCTUnwrap(KindleLanguageContract.profile(language: "ja", writingMode: .vertical)).isSupported,
            "日语竖排必须在生产 OCR/TTS 前阻止"
        )
        XCTAssertEqual(KindleLanguageContract.profile(language: "ja", writingMode: .vertical)?.tesseractModel, "jpn_vert")
        XCTAssertEqual(
            KindleOCRRoutingContract.route(for: try XCTUnwrap(KindleLanguageContract.profile(language: "zh"))),
            KindleOCRRoute(primary: .vision, fallback: .tesseract)
        )
        XCTAssertEqual(
            KindleOCRRoutingContract.route(for: try XCTUnwrap(KindleLanguageContract.profile(language: "hi"))),
            KindleOCRRoute(primary: .tesseract, fallback: nil)
        )
        XCTAssertEqual(
            KindleOCRRoutingContract.route(
                for: try XCTUnwrap(KindleLanguageContract.profile(language: "ja", writingMode: .vertical))
            ),
            KindleOCRRoute(primary: .tesseract, fallback: nil)
        )
        XCTAssertEqual(
            KindleOCRTextContract.tokens(in: "研究哲学、文学", language: "zh"),
            ["研", "究", "哲", "学", "、", "文", "学"]
        )
        XCTAssertEqual(
            KindleOCRTextContract.tokens(in: "Kindle reader", language: "en"),
            ["Kindle", "reader"]
        )
        XCTAssertEqual(
            KindleOCRTextContract.tokens(in: "हिन्दी भाषा", language: "hi"),
            ["हिन्दी", "भाषा"],
            "天城文组合附标必须保留在完整词内"
        )
        XCTAssertEqual(KindleLanguageContract.alignmentText("人 間"), KindleLanguageContract.alignmentText("人間"))
        XCTAssertEqual(KindleLanguageContract.alignmentText("café"), KindleLanguageContract.alignmentText("cafe\u{301}"))
        XCTAssertEqual(KindleLanguageContract.alignmentText("हिन्दी"), KindleLanguageContract.alignmentText("हि न्दी"))
        XCTAssertTrue(KindleLanguageContract.endsWithHardTerminal("समाप्त॥”"))
        XCTAssertTrue(KindleLanguageContract.startsWithListMarker("1) पहला बिंदु"))
        XCTAssertTrue(KindleLanguageContract.startsWithListMarker("२) दूसरा बिंदु"))
        XCTAssertTrue(KindleLanguageContract.startsWithListMarker("• गोदान का परिचय"))
        XCTAssertTrue(KindleLanguageContract.endsWithHeadingDelimiter("मुख्य पात्र："))
        XCTAssertFalse(KindleLanguageContract.startsWithListMarker("सामान्य अनुच्छेद"))
        XCTAssertEqual(KindleLanguageContract.join(["人", "間"], language: "ja"), "人間")
        XCTAssertTrue(KindleLanguageContract.shouldPreferRawParagraphs(language: "hi", raw: 4, visualLines: 5, rebuilt: 1))
        XCTAssertFalse(KindleLanguageContract.isVerified(language: "ja", source: nil), "旧缓存语言没有证据来源，必须重新确认")
        XCTAssertTrue(KindleLanguageContract.isVerified(language: "ja", source: "renderer-metadata"))
        XCTAssertTrue(KindlePlaybackLifecycleContract.shouldKeepPlayback(
            surfaceAttached: true,
            explicitlyClosed: false
        ))
        XCTAssertFalse(KindlePlaybackLifecycleContract.shouldKeepPlayback(
            surfaceAttached: false,
            explicitlyClosed: false
        ))
        XCTAssertTrue(KindlePlaybackLifecycleContract.requiresImmediateVisualSync(
            readerPresented: true,
            applicationActive: true
        ))
        XCTAssertFalse(KindlePlaybackLifecycleContract.requiresImmediateVisualSync(
            readerPresented: false,
            applicationActive: true
        ))
        XCTAssertFalse(KindlePlaybackLifecycleContract.requiresImmediateVisualSync(
            readerPresented: true,
            applicationActive: false
        ))
        XCTAssertTrue(KindleContinuousPageHandoffContract.shouldArm(
            isReadMode: true,
            isLastReadableParagraph: true,
            currentTTSComplete: true,
            hasPreparedPage: true,
            hasPreparedAudio: true,
            audioIsPlaying: true
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.shouldArm(
            isReadMode: true,
            isLastReadableParagraph: true,
            currentTTSComplete: true,
            hasPreparedPage: true,
            hasPreparedAudio: false,
            audioIsPlaying: true
        ))
        XCTAssertTrue(KindleContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: "current-tail",
            predecessorSegmentID: "current-tail",
            remainingAudioSeconds: 2.6,
            playbackRate: 2.0
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: "earlier-segment",
            predecessorSegmentID: "current-tail",
            remainingAudioSeconds: 0.2,
            playbackRate: 1.0
        ))
        XCTAssertTrue(KindleContinuousPageHandoffContract.shouldReleaseAudioGate(
            hasConfirmedVisibleSurface: true,
            textFingerprintMatches: true,
            firstHighlightHandshakeFinished: true
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.shouldReleaseAudioGate(
            hasConfirmedVisibleSurface: true,
            textFingerprintMatches: false,
            firstHighlightHandshakeFinished: true
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.shouldReleaseAudioGate(
            hasConfirmedVisibleSurface: true,
            textFingerprintMatches: true,
            firstHighlightHandshakeFinished: false
        ))
        XCTAssertEqual(
            KindleVisualHighlightQueueContract.completion(
                activeSequence: 8,
                completedSequence: 8,
                taskCancelled: false,
                hasPending: true
            ),
            .drainPending,
            "A refocus sequence bump must not strand the active paint slot or freeze later words"
        )
        XCTAssertEqual(
            KindleVisualHighlightQueueContract.completion(
                activeSequence: 9,
                completedSequence: 8,
                taskCancelled: false,
                hasPending: true
            ),
            .stale,
            "An older completion must not clear a newer task's ownership"
        )
        XCTAssertEqual(
            KindleVisualHighlightQueueContract.completion(
                activeSequence: 8,
                completedSequence: 8,
                taskCancelled: true,
                hasPending: true
            ),
            .clearOnly
        )
        XCTAssertFalse(KindleContinuousPageHandoffContract.shouldReleaseVisualHold(
            audioBoundaryReached: false,
            hasConfirmedVisibleSurface: true
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.shouldReleaseVisualHold(
            audioBoundaryReached: true,
            hasConfirmedVisibleSurface: false
        ))
        XCTAssertTrue(KindleContinuousPageHandoffContract.shouldReleaseVisualHold(
            audioBoundaryReached: true,
            hasConfirmedVisibleSurface: true
        ))
        XCTAssertEqual(
            KindleWritingModeContract.infer(from: [CGSize(width: 0.8, height: 0.1), CGSize(width: 0.7, height: 0.12)]),
            .horizontal
        )
        XCTAssertEqual(
            KindleWritingModeContract.infer(from: [CGSize(width: 0.08, height: 0.8), CGSize(width: 0.1, height: 0.7)]),
            .vertical
        )

        let englishFragment = LanguageDetector.Evidence(language: "en", confidence: 0.91, readableCharacterCount: 15)
        let japanesePage = LanguageDetector.Evidence(language: "ja", confidence: 0.96, readableCharacterCount: 180)
        let japaneseTitle = LanguageDetector.evidence(for: "人間失格 日本語版")
        let bad = KindleOCRConsensus.score(page: englishFragment, requestedLanguage: "en", title: japaneseTitle)
        let good = KindleOCRConsensus.score(page: japanesePage, requestedLanguage: "ja", title: japaneseTitle)
        XCTAssertEqual(good.language, "ja")
        XCTAssertGreaterThan(good.value, bad.value * 3, "完整日语 OCR 必须压过少量英文模型噪声")

        XCTAssertTrue(KindleColumnLayoutContract.isDualColumn(aspect: 1.01, pixelsReadable: true, centerGutter: true))
        XCTAssertTrue(KindleColumnLayoutContract.isDualColumn(aspect: 1.12, pixelsReadable: true, centerGutter: true))
        XCTAssertFalse(KindleColumnLayoutContract.isDualColumn(aspect: 1.70, pixelsReadable: true, centerGutter: false))
        XCTAssertTrue(KindleColumnLayoutContract.isDualColumn(aspect: 1.70, pixelsReadable: false, centerGutter: false))
        XCTAssertNil(KindleColumnLayoutContract.cacheSignature(contentKey: "same", pixelFingerprint: nil, pixelSize: CGSize(width: 100, height: 100)))
        XCTAssertEqual(KindleLivePageOCRContract.isolatedPageStrategy, .kindleSingleFlow)
        XCTAssertEqual(
            KindleLivePageOCRContract.wholeImageStrategy(rendererDetectedDualPage: false),
            .kindleSingleFlow
        )
        XCTAssertEqual(
            KindleLivePageOCRContract.wholeImageStrategy(rendererDetectedDualPage: true),
            .kindleLayout
        )
        XCTAssertNotEqual(
            KindleColumnLayoutContract.cacheSignature(contentKey: "same", pixelFingerprint: "a", pixelSize: CGSize(width: 100, height: 100)),
            KindleColumnLayoutContract.cacheSignature(contentKey: "same", pixelFingerprint: "b", pixelSize: CGSize(width: 100, height: 100))
        )

        XCTAssertTrue(KindleTurnContract.confirms(progress: .unchanged, beforeFingerprint: "a", afterFingerprint: "b", semanticActionDispatched: true, stableVisualSamples: 2))
        XCTAssertFalse(KindleTurnContract.confirms(progress: .unchanged, beforeFingerprint: "a", afterFingerprint: "b", semanticActionDispatched: true, stableVisualSamples: 1))
        XCTAssertFalse(KindleTurnContract.confirms(progress: .forward, beforeFingerprint: "a", afterFingerprint: "a", semanticActionDispatched: true, stableVisualSamples: 2))
        XCTAssertFalse(KindleTurnContract.confirms(progress: .backward, beforeFingerprint: "a", afterFingerprint: "b", semanticActionDispatched: true, stableVisualSamples: 2))
        XCTAssertEqual(KindleTurnContract.progress(beforeLocation: 2, afterLocation: 2, beforeRenderer: 10, afterRenderer: 11), .forward)
        XCTAssertEqual(KindleTurnContract.progressNumber("स्थान १२३"), 123)
        XCTAssertTrue(KindleWebScripts.pageCaptureBootstrap.contains("crKindleOcrMaxWidth = 2048"))
        XCTAssertTrue(KindleWebScripts.pageCaptureBootstrap.contains("toDataURL('image/png')"))
        XCTAssertFalse(KindleWebScripts.pageCaptureBootstrap.contains("toDataURL('image/jpeg', quality)"))
    }

    func testKindleReadPageCompletionHasSingleSessionOwner() {
        let pageA = KindleReadPageSession(generation: 41, documentID: "doc-a")
        let pageB = KindleReadPageSession(generation: 42, documentID: "doc-b")

        XCTAssertEqual(
            KindleReadPageCompletionContract.decision(
                isReadMode: true,
                ownerMatches: true,
                activeSession: pageA,
                eventSession: pageA,
                consumedGeneration: nil,
                currentPageKey: "page-a"
            ),
            .accept
        )
        XCTAssertEqual(
            KindleReadPageCompletionContract.decision(
                isReadMode: true,
                ownerMatches: true,
                activeSession: pageA,
                eventSession: pageA,
                consumedGeneration: pageA.generation,
                currentPageKey: "page-a"
            ),
            .duplicate,
            "同一页的第二个完成信号不得再次触发翻页"
        )
        XCTAssertEqual(
            KindleReadPageCompletionContract.decision(
                isReadMode: true,
                ownerMatches: false,
                activeSession: pageB,
                eventSession: pageA,
                consumedGeneration: nil,
                currentPageKey: "page-b"
            ),
            .staleOwner,
            "上一页迟到的 VM 回调不得消费新页"
        )
        XCTAssertEqual(
            KindleReadPageCompletionContract.decision(
                isReadMode: true,
                ownerMatches: true,
                activeSession: pageB,
                eventSession: pageA,
                consumedGeneration: nil,
                currentPageKey: "page-b"
            ),
            .staleSession,
            "即使页内段落 ID 都从零开始，会话代际不同也必须拒绝"
        )
    }

    func testKindleContinuousHandoffRequiresFreshTargetDocumentOwner() {
        XCTAssertTrue(KindleContinuousPageHandoffContract.canAdoptPreparedAudio(
            previousOwnerDocumentID: "doc-a",
            activeOwnerDocumentID: "doc-b",
            targetDocumentID: "doc-b"
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.canAdoptPreparedAudio(
            previousOwnerDocumentID: "doc-a",
            activeOwnerDocumentID: "doc-a",
            targetDocumentID: "doc-b"
        ))
        XCTAssertFalse(KindleContinuousPageHandoffContract.canAdoptPreparedAudio(
            previousOwnerDocumentID: "doc-a",
            activeOwnerDocumentID: "doc-c",
            targetDocumentID: "doc-b"
        ))
    }

    func testKindleContinuousFallbackCommitsWhenAudioAlreadyReachedBoundary() {
        XCTAssertTrue(
            KindleContinuousPageHandoffContract.shouldCommitConfirmedFallbackAtBoundary(
                hasConfirmedVisibleSurface: true,
                textFingerprintMatches: false,
                isQueuedSegmentGated: true
            ),
            "真实页确认晚于音频边界时必须立即接管并生成真实页音频"
        )
        XCTAssertFalse(
            KindleContinuousPageHandoffContract.shouldCommitConfirmedFallbackAtBoundary(
                hasConfirmedVisibleSurface: true,
                textFingerprintMatches: false,
                isQueuedSegmentGated: false
            ),
            "旧页仍在播放时不能提前截断，继续等待自然音频边界"
        )
        XCTAssertFalse(
            KindleContinuousPageHandoffContract.shouldCommitConfirmedFallbackAtBoundary(
                hasConfirmedVisibleSurface: true,
                textFingerprintMatches: true,
                isQueuedSegmentGated: true
            ),
            "预加载命中时继续使用正常的无缝队列恢复路径"
        )
    }

    func testKindleContinuousVisualTurnNeverRetriesSemanticActionAfterMismatch() {
        let old = "page-10"
        let speculative = "held-surface-a"

        XCTAssertTrue(KindleContinuousVisualTurnContract.shouldDispatchSemanticAction(
            expectedKey: speculative,
            visibleKey: old,
            semanticActionAttempted: false,
            confirmedTargetKey: nil
        ))

        let actual = "page-11"
        XCTAssertFalse(KindleContinuousVisualTurnContract.shouldDispatchSemanticAction(
            expectedKey: speculative,
            visibleKey: actual,
            semanticActionAttempted: true,
            confirmedTargetKey: actual
        ), "预加载 key 与真实下一页不一致时不得重发翻页动作")
        XCTAssertEqual(
            KindleContinuousVisualTurnContract.stagingTargetKey(
                oldKey: old,
                expectedKey: speculative,
                visibleKey: actual,
                semanticActionAttempted: true,
                confirmedTargetKey: actual
            ),
            actual,
            "翻页成功后应改为接管真实可见页，而不是为了命中猜测缓存继续翻页"
        )

        XCTAssertFalse(KindleContinuousVisualTurnContract.shouldDispatchSemanticAction(
            expectedKey: speculative,
            visibleKey: actual,
            semanticActionAttempted: true,
            confirmedTargetKey: nil
        ), "即使动作确认超时，已尝试过的非幂等动作也不能重发")
        XCTAssertEqual(
            KindleContinuousVisualTurnContract.stagingTargetKey(
                oldKey: old,
                expectedKey: speculative,
                visibleKey: actual,
                semanticActionAttempted: true,
                confirmedTargetKey: nil
            ),
            actual
        )
    }

    @MainActor
    func testKindleChineseVisionOCRUsesGraphemeGeometry() async throws {
        let size = CGSize(width: 1400, height: 560)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            context.cgContext.setFillColor(UIColor.white.cgColor)
            context.cgContext.fill(CGRect(origin: .zero, size: size))
            let style = NSMutableParagraphStyle()
            style.lineSpacing = 18
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont(name: "Songti SC", size: 54) ?? UIFont.systemFont(ofSize: 54),
                .foregroundColor: UIColor.black,
                .paragraphStyle: style
            ]
            let text = "王国维字静安，号观堂，浙江海宁人，是我国近代享有国际盛誉的著名学者。\n他中过秀才，早年学习英、日文，研究哲学、文学。"
            text.draw(in: CGRect(x: 60, y: 60, width: 1280, height: 440), withAttributes: attributes)
        }
        let profile = try XCTUnwrap(KindleLanguageContract.profile(language: "zh"))
        let document = try await OCRService.shared.recognizeKindle(
            image: image,
            profile: profile,
            title: "中文 OCR 契约",
            paragraphStrategy: .kindleLayout
        )
        XCTAssertTrue(document.fullText.contains("研究哲学、文学"))
        let words = document.paragraphs.flatMap(\.words)
        XCTAssertTrue(words.contains(where: { $0.text == "研" }))
        XCTAssertTrue(words.contains(where: { $0.text == "究" }))
        XCTAssertTrue(words.allSatisfy { !$0.bboxNorm.isNull && $0.bboxNorm.width > 0 && $0.bboxNorm.height > 0 })
    }

    @MainActor
    func testKindleRendererMetadataLanguageAuthority() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        webView.loadHTMLString("<!doctype html><html><body>reader</body></html>", baseURL: URL(string: "https://read.amazon.com"))
        for _ in 0..<40 {
            let body = try? await webView.evaluateJavaScript("document.body && document.body.textContent") as? String
            if body?.contains("reader") == true { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        _ = try await webView.evaluateJavaScript(KindleWebScripts.metadataBootstrap)
        let raw = try await webView.evaluateJavaScript(
            "JSON.stringify(window.__crKindleExtractMetadataProfile({renderer:{book:{book_locale:'jpn'},layout:{orientation:'vertical'},pagination:{page_turn_direction:'rtl'}}}))"
        )
        let data = try XCTUnwrap((raw as? String)?.data(using: .utf8))
        let profile = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(profile["language"] as? String, "ja")
        XCTAssertEqual(profile["writingMode"] as? String, "horizontal", "generic orientation 不能冒充日语竖排")
        XCTAssertEqual(profile["pageProgressionDirection"] as? String, "rtl")
        XCTAssertEqual(profile["source"] as? String, "renderer-metadata")
    }

    @MainActor
    func testKindleRendererTokenGeometryBuildsVerticalJapaneseColumns() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        webView.loadHTMLString("<!doctype html><html><body>reader</body></html>", baseURL: URL(string: "https://read.amazon.com"))
        for _ in 0..<40 {
            let body = try? await webView.evaluateJavaScript("document.body && document.body.textContent") as? String
            if body?.contains("reader") == true { break }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        _ = try await webView.evaluateJavaScript(KindleWebScripts.metadataBootstrap)
        let raw = try await webView.evaluateJavaScript(
            """
            (function() {
              var page = {pageIndex:4, children:[
                {startPositionId:100,endPositionId:109,x:300,y:20,width:20,height:300,words:[
                  {startPositionId:100,endPositionId:104,x:300,y:20,width:20,height:130},
                  {startPositionId:105,endPositionId:109,x:300,y:170,width:20,height:150}
                ]},
                {startPositionId:110,endPositionId:119,x:250,y:20,width:20,height:300,words:[
                  {startPositionId:110,endPositionId:114,x:250,y:20,width:20,height:130},
                  {startPositionId:115,endPositionId:119,x:250,y:170,width:20,height:150}
                ]}
              ]};
              return JSON.stringify(window.__crKindleExtractRendererFiles([
                {name:'metadata.json',value:{book_locale:'jpn',writingMode:'horizontal'}},
                {name:'tokens_1_1.json',value:[page]}
              ], 'https://read.amazon.com/renderer/render?startingPosition=100', null));
            })()
            """
        )
        let data = try XCTUnwrap((raw as? String)?.data(using: .utf8))
        let profile = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(profile["language"] as? String, "ja")
        XCTAssertEqual(profile["writingMode"] as? String, "vertical")
        XCTAssertEqual(profile["writingModeSource"] as? String, "token-geometry")
        let hints = try XCTUnwrap(profile["verticalColumnHints"] as? [[String: Any]])
        XCTAssertEqual(hints.count, 2)
        XCTAssertEqual(hints.first?["startPositionId"] as? Int, 100)
    }

    func testKindleParagraphVisualFragmentsStaySeparatedAcrossGutter() {
        let paragraph = ReadingParagraph(
            id: 0,
            text: "one continued paragraph",
            words: [],
            bboxNorm: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
            visualFragments: [
                OCRVisualFragment(column: .left, bboxNorm: CGRect(x: 0.1, y: 0.1, width: 0.35, height: 0.1), wordIDs: [0]),
                OCRVisualFragment(column: .right, bboxNorm: CGRect(x: 0.55, y: 0.8, width: 0.35, height: 0.1), wordIDs: [1])
            ]
        )
        XCTAssertEqual(paragraph.visualFragments.count, 2)
        XCTAssertLessThan(paragraph.visualFragments[0].bboxNorm.maxX, paragraph.visualFragments[1].bboxNorm.minX)
    }

    func testTimestampQualityIsLanguageNeutralAndFallsBackPerSegment() {
        func timestamps(_ words: [String]) -> [TTSTimestamp] {
            words.enumerated().map {
                TTSTimestamp(word: $0.element, startTime: Double($0.offset), endTime: Double($0.offset + 1))
            }
        }
        XCTAssertTrue(TTSTimestampQuality.hasReliableWordGranularity(
            text: "El rápido zorro español",
            timestamps: timestamps(["El", "rápido", "zorro", "español"]),
            duration: 4
        ))
        XCTAssertTrue(TTSTimestampQuality.hasReliableWordGranularity(
            text: "La lettura segue ogni parola",
            timestamps: timestamps(["La", "lettura", "segue", "ogni", "parola"]),
            duration: 5
        ), "Italian word timing must not be blocked by a language allowlist")
        XCTAssertTrue(TTSTimestampQuality.hasReliableWordGranularity(
            text: "Deutsche Stimmen markieren jedes gesprochene Wort",
            timestamps: timestamps(["Deutsche", "Stimmen", "markieren", "jedes", "gesprochene", "Wort"]),
            duration: 6
        ), "German word timing must be accepted when the actual segment passes the quality gate")
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "Deutsche Stimmen fallen nur für dieses Segment zurück.",
            timestamps: [TTSTimestamp(
                word: "Deutsche Stimmen fallen nur für dieses Segment zurück.",
                startTime: 0,
                endTime: 4
            )],
            duration: 4
        ), "A sentence-level German response must not masquerade as one word")
        XCTAssertTrue(TTSTimestampQuality.hasReliableWordGranularity(
            text: "中文逐词高亮测试",
            timestamps: timestamps(["中文", "逐词", "高亮", "测试"]),
            duration: 4
        ), "Any future valid compact-script word timing should be accepted")
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "中文整句时间戳不能伪装成一个单词。",
            timestamps: [TTSTimestamp(word: "中文整句时间戳不能伪装成一个单词。", startTime: 0, endTime: 3)],
            duration: 3
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "日本語の文全体を一語として扱わない。",
            timestamps: [TTSTimestamp(word: "日本語の文全体を一語として扱わない。", startTime: 0, endTime: 3)],
            duration: 3
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "El rápido zorro español",
            timestamps: timestamps(["El", "rápido"]),
            duration: 2
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "Esta respuesta contiene muchas palabras diferentes",
            timestamps: timestamps(["Esta respuesta contiene"]),
            duration: 1
        ))
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "time must move forward",
            timestamps: [
                TTSTimestamp(word: "time", startTime: 0, endTime: 1),
                TTSTimestamp(word: "must", startTime: 0.7, endTime: 0.9),
                TTSTimestamp(word: "move", startTime: 1.1, endTime: 2),
                TTSTimestamp(word: "forward", startTime: 2, endTime: 3)
            ],
            duration: 3
        ), "timestamp ends must be monotonic")
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "timestamps stay inside audio",
            timestamps: timestamps(["timestamps", "stay", "inside", "audio"]),
            duration: 2
        ), "timestamps outside the actual audio duration must fall back")
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "one two three four five six seven eight nine ten",
            timestamps: timestamps(["one", "two", "three", "four", "five", "six", "seven", "eight"]),
            duration: 10
        ), "High overall coverage must not hide missing spoken words at the tail")
        XCTAssertTrue(TTSTimestampQuality.hasReliableWordGranularity(
            text: "one two three four five six seven eight nine ten",
            timestamps: timestamps(["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]),
            duration: 10
        ), "The same segment remains word-reliable when its spoken tail is covered")
        XCTAssertFalse(TTSTimestampQuality.hasReliableWordGranularity(
            text: "Please highlight every spoken word in order",
            timestamps: timestamps(["highlight", "every", "spoken", "word", "in", "order"]),
            duration: 8
        ), "High overall coverage must not hide missing spoken words at the start")
        let chineseWords = "一二三四五六七八九十".map(String.init)
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: chineseWords,
                segmentTexts: ["一二三四五"],
                segPos: 0
            ),
            0..<5
        )
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: chineseWords,
                segmentTexts: ["一二三四五", "六七八九十"],
                segPos: 0
            ),
            0..<5,
            "后续流式 segment 到达时，当前 segment 的高亮范围不得重新分配"
        )
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: chineseWords,
                segmentTexts: ["一二三四五", "六七八九十"],
                segPos: 1
            ),
            5..<10
        )
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: ["你", "好", "你", "好"],
                segmentTexts: ["你好", "你好"],
                segPos: 1
            ),
            2..<4,
            "重复文本必须沿 OCR 游标单调向前"
        )
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: ["Le", "lecteur", "Kindle", "avance"],
                segmentTexts: ["Le lecteur", "Kindle avance"],
                segPos: 1
            ),
            2..<4
        )
        let japaneseWords = [
            "明", "智", "君", "は", "枕", "を", "ぎゅっと", "抱きしめ", "、",
            "目", "を", "つぶった", "が", "、", "どうしても", "涙", "が", "にじんでくる", "。"
        ]
        XCTAssertEqual(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: japaneseWords,
                segmentTexts: ["明智君は枕をぎゅっと抱きしめ、目をつぶったが、どうしても涙がにじんでくる。"],
                segPos: 0
            ),
            0..<japaneseWords.count,
            "日语句子必须忽略 OCR 分词与标点差异并覆盖完整视觉句子"
        )
        XCTAssertNil(
            ReadAloudViewModel.alignedPhotoWordRange(
                words: japaneseWords,
                segmentTexts: ["OCRに存在しない文章です。"],
                segPos: 0
            ),
            "匹配失败不能退回句首并错误高亮第一个字"
        )
    }

    func testSpeechTextSanitizerConvertsMusicMarkersIntoSentenceBoundaries() {
        let lyrics = "♪ Inside we both know what's been going ♪ ♪ We know the game and we're gonna play it ♪"
        let sanitized = SpeechTextSanitizer.sanitizedForTTS(lyrics)

        XCTAssertEqual(
            sanitized,
            "Inside we both know what's been going. We know the game and we're gonna play it."
        )
        XCTAssertFalse(sanitized.contains("♪"))
        let musicOnly = "♩ ♪ ♫ ♬ 🎵 🎶"
        XCTAssertEqual(SpeechTextSanitizer.sanitizedForTTS(musicOnly), "")
        XCTAssertFalse(SpeechTextSanitizer.containsSpeakableContent(musicOnly))
    }

    func testJapaneseNaturalSentenceRequestsMatchAndroidAndExtension() {
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "良くフリーエネルギーと言えば、多いと思います。物質に永久はありません。",
                language: "ja-JP"
            ),
            [
                "良くフリーエネルギーと言えば、多いと思います。",
                "物質に永久はありません。"
            ]
        )
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "一文目です！「本当ですか？」三文目です。",
                language: "ja"
            ),
            ["一文目です！", "「本当ですか？」", "三文目です。"]
        )
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "これは同じ文が画面の幅で\n折り返されただけです。",
                language: "ja"
            ),
            ["これは同じ文が画面の幅で折り返されただけです。"]
        )
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "First sentence. Second sentence.",
                language: "en"
            ).count,
            1
        )
        XCTAssertEqual(
            TTSSentenceSegmenter.requestUnits(
                "Primera frase. Segunda frase.",
                language: "es-ES"
            ).count,
            1
        )
    }

    func testKindleListeningHashAndAnchorTokenContract() {
        let a = [anchorParagraph(id: 0, "Hello,  WORLD!  Kindle 123")]
        let b = [anchorParagraph(id: 0, "hello world kindle 123")]
        XCTAssertEqual(
            KindleListeningAnchorResolver.pageTextHash(paragraphs: a),
            KindleListeningAnchorResolver.pageTextHash(paragraphs: b)
        )

        let paragraph = anchorParagraph(id: 0, "zero one two three four five six seven eight nine ten eleven twelve")
        let offset = KindleListeningAnchorResolver.charOffset(in: paragraph, wordIndex: 6)
        let phrase = KindleListeningAnchorResolver.anchorPhrase(in: paragraph.text, charOffset: offset)
        XCTAssertLessThanOrEqual(phrase.phrase.split(separator: " ").count, 11)
        XCTAssertEqual(phrase.anchorWordOffset, 5)
    }

    func testKindleListeningAnchorUsesSharedPageTextHashFieldAndMigratesLegacyKey() throws {
        let paragraphs = [anchorParagraph(id: 0, "A stable sentence used for cross-platform resume metadata.")]
        let anchor = listeningAnchor(paragraphs: paragraphs, targetParagraph: 0, targetWord: 3)
        let encoded = try JSONEncoder().encode(anchor)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["pageTextHash"] as? String, anchor.pageTextHash)
        XCTAssertNil(json["textHash"])

        json["textHash"] = json.removeValue(forKey: "pageTextHash")
        let legacyData = try JSONSerialization.data(withJSONObject: json)
        let migrated = try JSONDecoder().decode(KindleListeningAnchor.self, from: legacyData)
        XCTAssertEqual(migrated.pageTextHash, anchor.pageTextHash)
    }
}

final class LocalizationCatalogTests: XCTestCase {
    private let appLocales = ["en", "zh-Hans", "ja", "es", "fr", "de", "pt-BR", "it", "hi"]
    private let translatedLocales = ["en", "zh-Hans", "ja", "es", "fr", "de", "pt-BR", "it", "hi"]

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func catalog(named name: String) throws -> [String: Any] {
        try catalog(relativePath: "CastReader/\(name).xcstrings")
    }

    private func catalog(relativePath: String) throws -> [String: Any] {
        let url = repositoryRoot.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("Source catalog checks run on the host build machine")
        }
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func formatSignature(_ value: String) throws -> [String] {
        let pattern = #"%(?:\d+\$)?[-+0 #']*(?:\d+|\*)?(?:\.\d+)?(?:hh|ll|h|l|z|t|j)?([@diuoxXfFeEgGaAcCsSp])"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let scalarRange = Range(match.range(at: 1), in: value) else { return nil }
            let scalar = String(value[scalarRange])
            if "diuoxXc".contains(scalar) { return "integer" }
            if "fFeEgGaA".contains(scalar) { return "float" }
            if scalar == "@" { return "object" }
            return scalar
        }.sorted()
    }

    private func templateTokens(_ value: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: #"\$\{([^}]+)\}"#)
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.matches(in: value, range: range).compactMap { match in
            guard let tokenRange = Range(match.range(at: 1), in: value) else { return nil }
            return String(value[tokenRange])
        }.sorted()
    }

    func testAppLanguagePickerContainsSystemAndAllNineLanguages() {
        XCTAssertEqual(
            AppLanguage.allCases.map(\.rawValue),
            ["system", "en", "zh-Hans", "ja", "es", "fr", "de", "pt-BR", "it", "hi"]
        )
    }

    func testAppLanguageOverrideChangesRuntimeLocalizedStrings() {
        let manager = AppLanguageManager.shared
        let previousLanguage = manager.selectedLanguage
        defer { manager.select(previousLanguage) }

        manager.select(.english)
        XCTAssertEqual(AppLocalized("首页"), "Home")
        XCTAssertEqual(AppLocalized("跟随系统"), "Follow System")

        manager.select(.japanese)
        XCTAssertEqual(AppLocalized("首页"), "ホーム")
        XCTAssertEqual(AppLocalized("跟随系统"), "システム設定に従う")

        manager.select(.simplifiedChinese)
        XCTAssertEqual(AppLocalized("首页"), "首页")
        XCTAssertEqual(AppLocalized("论文 / 学术"), "论文 / 学术")
        XCTAssertEqual(AppLocalized("书籍 / 长篇"), "书籍 / 长篇")
        XCTAssertEqual(AppLocalized("报告 / 研报"), "报告 / 研报")
        XCTAssertEqual(AppLocalized("合同 / 条款"), "合同 / 条款")
        XCTAssertEqual(AppLocalized("教材 / 学习"), "教材 / 学习")
        XCTAssertEqual(AppLocalized("说明书 / 文档"), "说明书 / 文档")
    }

    func testHomeProCardPurchaseContractRoutesWithoutAnIntermediatePaywall() {
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: true,
                hasYearlyProduct: true,
                hasSyncableAccount: true,
                isLoadingProducts: false,
                isPurchaseInFlight: false
            ),
            .none
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: true,
                hasSyncableAccount: true,
                isLoadingProducts: true,
                isPurchaseInFlight: false
            ),
            .none
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: false,
                hasSyncableAccount: true,
                isLoadingProducts: false,
                isPurchaseInFlight: false
            ),
            .showPlans
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: true,
                hasSyncableAccount: false,
                isLoadingProducts: false,
                isPurchaseInFlight: false
            ),
            .requireLogin
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: true,
                hasSyncableAccount: true,
                isLoadingProducts: false,
                isPurchaseInFlight: false
            ),
            .purchaseYearly
        )
        XCTAssertEqual(
            HomeProPurchaseContract.primaryAction(
                isPro: false,
                hasYearlyProduct: true,
                hasSyncableAccount: true,
                isLoadingProducts: false,
                isPurchaseInFlight: true
            ),
            .none
        )
    }

    func testShareInboxExtractsThePageURLFromSharedCaptionText() {
        let text = "Worth reading today — https://example.com/articles/focus?source=share"
        XCTAssertEqual(
            ShareInboxLinkExtractor.firstWebURL(in: text)?.absoluteString,
            "https://example.com/articles/focus?source=share"
        )
        XCTAssertNil(ShareInboxLinkExtractor.firstWebURL(in: "A useful note with no page link"))
        XCTAssertNil(ShareInboxLinkExtractor.firstWebURL(in: "Contact reader@example.com"))
    }

    func testShareInboxBadgeCountsOnlyItemsCreatedAfterLastSeenDate() {
        let seenAt = Date(timeIntervalSince1970: 2_000)
        func record(id: UUID = UUID(), createdAt: Date) -> ShareInboxRecord {
            ShareInboxRecord(
                id: id,
                createdAt: createdAt,
                kind: .url,
                mode: .read,
                title: "Shared article",
                payloadFilename: nil,
                sourceURL: "https://example.com",
                previewImageFilename: nil,
                linkMetadataFetchedAt: nil
            )
        }
        let records = [
            record(createdAt: Date(timeIntervalSince1970: 1_000)),
            record(createdAt: seenAt),
            record(createdAt: Date(timeIntervalSince1970: 3_000))
        ]

        XCTAssertEqual(ShareInboxStore.unreadCount(in: records, lastSeenAt: nil), 3)
        XCTAssertEqual(ShareInboxStore.unreadCount(in: records, lastSeenAt: seenAt), 1)
    }

    func testDynamicWebExtractionRejectsTitleOnlyPayloadButAcceptsArticleBody() throws {
        func paragraph(_ index: Int, _ text: String) throws -> WebRenderedParagraph {
            try XCTUnwrap(WebRenderedParagraph([
                "paragraphIndex": index,
                "text": text,
                "type": "paragraph"
            ]))
        }

        let weak = [try paragraph(0, "人民日报文章标题")]
        XCTAssertTrue(WebExtractionReadiness.isWeak(weak))

        let body = [
            try paragraph(0, String(repeating: "正文第一段内容。", count: 12)),
            try paragraph(1, String(repeating: "正文第二段内容。", count: 12)),
            try paragraph(2, String(repeating: "正文第三段内容。", count: 12))
        ]
        XCTAssertFalse(WebExtractionReadiness.isWeak(body))
    }

    func testShareInboxRecordRemainsBackwardCompatibleBeforeLinkPreviewFields() throws {
        let id = UUID()
        let legacyJSON = """
        {
          "id": "\(id.uuidString)",
          "createdAt": 0,
          "kind": "url",
          "mode": "read",
          "title": "example.com",
          "sourceURL": "https://example.com"
        }
        """
        let record = try JSONDecoder().decode(ShareInboxRecord.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(record.id, id)
        XCTAssertNil(record.fallbackTitle)
        XCTAssertNil(record.previewImageFilename)
        XCTAssertNil(record.linkMetadataFetchedAt)
    }

    func testHomeProCardWeeklyPriceUsesAnnualPriceDividedByFiftyTwo() throws {
        var weekly = HomeProPricing.weeklyPrice(from: try XCTUnwrap(Decimal(string: "34.99")))
        var rounded = Decimal()
        NSDecimalRound(&rounded, &weekly, 2, .plain)
        XCTAssertEqual(rounded, Decimal(string: "0.67"))
    }

    func testHomeProCardCopyFollowsAllNineRuntimeLanguages() {
        let manager = AppLanguageManager.shared
        let previousLanguage = manager.selectedLanguage
        defer { manager.select(previousLanguage) }

        for language in AppLanguage.allCases where language != .system {
            manager.select(language)
            let headline = AppLocalized("让每本 Kindle 都开口说话")
            let benefits = AppLocalized("Kindle 连续朗读 · 100+ 专业音色 · 9 种语言")
            let cta = String(format: AppLocalized("以 %@/年成为 Pro"), "PRICE")
            XCTAssertFalse(headline.isEmpty, "Missing headline for \(language.rawValue)")
            XCTAssertFalse(benefits.isEmpty, "Missing benefits for \(language.rawValue)")
            XCTAssertTrue(cta.contains("PRICE"), "Missing price placeholder for \(language.rawValue): \(cta)")
        }
    }

    func testKindlePlaybackAccessGateCoversReadAndExplainQuota() {
        XCTAssertFalse(
            KindlePlaybackAccessGate.canStart(
                mode: .read,
                isPro: false,
                listenRemaining: 0,
                explainRemaining: 3
            )
        )
        XCTAssertTrue(
            KindlePlaybackAccessGate.canStart(
                mode: .read,
                isPro: false,
                listenRemaining: 1,
                explainRemaining: 0
            )
        )
        XCTAssertFalse(
            KindlePlaybackAccessGate.canStart(
                mode: .explain,
                isPro: false,
                listenRemaining: 1200,
                explainRemaining: 0
            )
        )
        XCTAssertTrue(
            KindlePlaybackAccessGate.canStart(
                mode: .explain,
                isPro: true,
                listenRemaining: 0,
                explainRemaining: 0
            )
        )
    }

    func testBlockedKindleModeSwitchPreservesCurrentPlaybackAndRequestsTargetPaywall() {
        let blocked = KindleModeSwitchAccessContract.resolve(
            requestedMode: .explain,
            hasAccess: false
        )

        XCTAssertFalse(blocked.shouldStopCurrentPlayback)
        XCTAssertFalse(blocked.shouldApplyRequestedMode)
        XCTAssertEqual(blocked.paywallMode, .explain)
        XCTAssertEqual(
            KindlePaywallPresentationContract.analyticsTrigger(
                requestedMode: blocked.paywallMode,
                currentMode: .read
            ),
            "explain_quota",
            "被拦截时当前模式仍是朗读，但付费墙必须归因到目标解读模式"
        )

        let allowed = KindleModeSwitchAccessContract.resolve(
            requestedMode: .explain,
            hasAccess: true
        )
        XCTAssertTrue(allowed.shouldStopCurrentPlayback)
        XCTAssertTrue(allowed.shouldApplyRequestedMode)
        XCTAssertNil(allowed.paywallMode)
    }

    func testQuickReadStructuredSSE402MapsToQuotaError() {
        let numericPayload = Data(#"{"code":402,"message":"quota exhausted"}"#.utf8)
        guard case .httpError(402) = QuickReadSSEErrorMapper.map(payload: numericPayload) else {
            return XCTFail("numeric SSE 402 must map to the paywall error path")
        }

        let nestedStringPayload = Data(#"{"error":{"status":"402","message":"quota exhausted"}}"#.utf8)
        guard case .httpError(402) = QuickReadSSEErrorMapper.map(payload: nestedStringPayload) else {
            return XCTFail("nested string SSE 402 must map to the paywall error path")
        }
    }

    func testQuickReadOrdinarySSEErrorRemainsAServiceError() {
        let payload = Data(#"{"code":503,"message":"temporarily unavailable"}"#.utf8)
        guard case .serverError(let message) = QuickReadSSEErrorMapper.map(payload: payload) else {
            return XCTFail("non-quota SSE errors must not open the paywall")
        }
        XCTAssertEqual(message, "temporarily unavailable")
    }

    func testNineLanguageCatalogIsCompleteAndFormatSafe() throws {
        let root = try catalog(named: "Localizable")
        XCTAssertEqual(root["sourceLanguage"] as? String, "zh-Hans")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let protectedTokens = ["CastReader", "Apple", "Google", "Safari", "StoreKit", "WebView", "Xcode", "Amazon", "EPUB", "PDF", "DOCX", "TXT", "URL", "SLA", "API", "HTTP"]

        for (key, rawEntry) in strings where !key.isEmpty {
            let entry = try XCTUnwrap(rawEntry as? [String: Any], "Invalid entry: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any], "No localizations: \(key)")
            let expectedSignature = try formatSignature(key)

            for locale in translatedLocales {
                let rawLocalization = try XCTUnwrap(localizations[locale], "Missing \(locale): \(key)")
                let localization = try XCTUnwrap(rawLocalization as? [String: Any])
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(locale): \(key)")
                XCTAssertEqual(unit["state"] as? String, "translated", "Untranslated \(locale): \(key)")
                XCTAssertEqual(try formatSignature(value), expectedSignature, "Format mismatch \(locale): \(key) => \(value)")

                for token in protectedTokens where key.contains(token) {
                    XCTAssertTrue(value.contains(token), "Protected token \(token) changed in \(locale): \(key) => \(value)")
                }
            }
        }
    }

    /// `AppLocalized` is an explicit runtime lookup, so Xcode's normal string
    /// extraction does not guarantee that every literal key exists in the
    /// catalog. Keep static literals covered while deliberately ignoring
    /// interpolated/dynamic keys and the intentionally empty catalog key.
    func testEveryStaticAppLocalizedLiteralExistsInCatalog() throws {
        let root = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let sourceRoot = repositoryRoot.appendingPathComponent("CastReader")
        guard let enumerator = FileManager.default.enumerator(
            at: sourceRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        ) else {
            throw XCTSkip("Source coverage checks run on the host build machine")
        }

        let regex = try NSRegularExpression(
            pattern: #"AppLocalized\s*\(\s*"([^"\\]*)""#
        )
        var missing: [String: Set<String>] = [:]

        for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
            let source = try String(contentsOf: fileURL, encoding: .utf8)
            let sourceRange = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, range: sourceRange) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                let key = String(source[keyRange])
                guard !key.isEmpty, strings[key] == nil else { continue }
                let relativePath = fileURL.path.replacingOccurrences(
                    of: repositoryRoot.path + "/",
                    with: ""
                )
                missing[key, default: []].insert(relativePath)
            }
        }

        let report = missing
            .sorted { $0.key < $1.key }
            .map { key, files in "\(key) [\(files.sorted().joined(separator: ", "))]" }
            .joined(separator: "\n")
        XCTAssertTrue(
            missing.isEmpty,
            "Static AppLocalized literals missing from Localizable.xcstrings:\n\(report)"
        )
    }

    func testInfoPlistCatalogCoversAllAppLocales() throws {
        let root = try catalog(named: "InfoPlist")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        XCTAssertEqual(Set(strings.keys), [
            "CFBundleName", "NSCameraUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryUsageDescription"
        ])

        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for locale in appLocales {
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any], "Missing \(locale): \(key)")
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(locale): \(key)")
                XCTAssertEqual(unit["state"] as? String, "translated", "Untranslated \(locale): \(key)")
            }
        }
    }

    func testAuxiliaryCatalogsCoverAllNineLanguagesAndPreserveTemplates() throws {
        let paths = [
            "CastReader/AppShortcuts.xcstrings",
            "CastReader Share Extension/Localizable.xcstrings",
            "CastReader Widget/Localizable.xcstrings"
        ]

        for path in paths {
            let root = try catalog(relativePath: path)
            let sourceLanguage = try XCTUnwrap(root["sourceLanguage"] as? String)
            let strings = try XCTUnwrap(root["strings"] as? [String: Any])
            for (key, rawEntry) in strings where !key.isEmpty {
                let entry = try XCTUnwrap(rawEntry as? [String: Any], "Invalid entry: \(path): \(key)")
                let localizations = try XCTUnwrap(
                    entry["localizations"] as? [String: Any],
                    "No localizations: \(path): \(key)"
                )
                XCTAssertEqual(
                    Set(localizations.keys),
                    Set(appLocales),
                    "Wrong locale coverage: \(path): \(key)"
                )
                let sourceLocalization = try XCTUnwrap(localizations[sourceLanguage] as? [String: Any])
                let sourceUnit = try XCTUnwrap(sourceLocalization["stringUnit"] as? [String: Any])
                let sourceValue = try XCTUnwrap(sourceUnit["value"] as? String)
                let sourceFormat = try formatSignature(sourceValue)
                let sourceTemplates = try templateTokens(sourceValue)

                for locale in appLocales {
                    let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
                    let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                    let value = try XCTUnwrap(unit["value"] as? String)
                    XCTAssertFalse(
                        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        "Empty \(locale): \(path): \(key)"
                    )
                    XCTAssertEqual(
                        unit["state"] as? String,
                        "translated",
                        "Untranslated \(locale): \(path): \(key)"
                    )
                    XCTAssertEqual(
                        try formatSignature(value),
                        sourceFormat,
                        "Format mismatch \(locale): \(path): \(key)"
                    )
                    XCTAssertEqual(
                        try templateTokens(value),
                        sourceTemplates,
                        "Template mismatch \(locale): \(path): \(key)"
                    )
                }
            }
        }
    }

    func testShareExtensionGermanCopyDoesNotFallBackToEnglish() throws {
        let root = try catalog(relativePath: "CastReader Share Extension/Localizable.xcstrings")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        for (key, rawEntry) in strings {
            let entry = try XCTUnwrap(rawEntry as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            let english = try XCTUnwrap(localizations["en"] as? [String: Any])
            let german = try XCTUnwrap(localizations["de"] as? [String: Any])
            let englishUnit = try XCTUnwrap(english["stringUnit"] as? [String: Any])
            let germanUnit = try XCTUnwrap(german["stringUnit"] as? [String: Any])
            XCTAssertNotEqual(
                germanUnit["value"] as? String,
                englishUnit["value"] as? String,
                "German Share Extension copy falls back to English: \(key)"
            )
        }
    }

    func testCoreNavigationTerminologyIsNativeAndStable() throws {
        let root = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let expected: [String: [String: String]] = [
            "首页": ["en": "Home", "zh-Hans": "首页", "ja": "ホーム", "es": "Inicio", "fr": "Accueil", "de": "Start", "pt-BR": "Início", "it": "Home", "hi": "होम"],
            "文库": ["en": "Library", "zh-Hans": "文库", "ja": "ライブラリ", "es": "Biblioteca", "fr": "Bibliothèque", "de": "Bibliothek", "pt-BR": "Biblioteca", "it": "Libreria", "hi": "लाइब्रेरी"],
            "设置": ["en": "Settings", "zh-Hans": "设置", "ja": "設定", "es": "Ajustes", "fr": "Réglages", "de": "Einstellungen", "pt-BR": "Ajustes", "it": "Impostazioni", "hi": "सेटिंग्स"],
            "朗读": ["en": "Read Aloud", "zh-Hans": "朗读", "ja": "読み上げ", "es": "Leer en voz alta", "fr": "Lire à voix haute", "de": "Vorlesen", "pt-BR": "Ler em voz alta", "it": "Leggi ad alta voce", "hi": "ज़ोर से पढ़ें"],
            "解读": ["en": "Explain", "zh-Hans": "解读", "ja": "解説", "es": "Explicar", "fr": "Expliquer", "de": "Erklären", "pt-BR": "Explicar", "it": "Spiega", "hi": "व्याख्या"],
            "Kindle": ["en": "Kindle", "zh-Hans": "Kindle", "ja": "Kindle", "es": "Kindle", "fr": "Kindle", "de": "Kindle", "pt-BR": "Kindle", "it": "Kindle", "hi": "Kindle"]
        ]

        for (key, locales) in expected {
            let entry = try XCTUnwrap(strings[key] as? [String: Any])
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            for (locale, expectedValue) in locales {
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                XCTAssertEqual(unit["value"] as? String, expectedValue, "Unexpected \(locale) term for \(key)")
            }
        }
    }

    /// 试用文案是审核红线：任何一种语言缺翻译，该语言用户就会看到中文源串或空承诺。
    func testFreeTrialCopyIsCompleteInAllNineLanguages() throws {
        let root = try catalog(named: "Localizable")
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let trialKeys = [
            "%d 天免费试用",
            "开始 %d 天免费试用",
            "试用结束后收费",
            "免费试用 %1$d 天，之后按 %2$@%3$@自动续订。可随时在 App Store 设置中取消。",
            "免费试用 %1$d 天，之后按 %2$@/年自动续订，可随时取消",
            "/月", "/年", "/周", "/天"
        ]

        for key in trialKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], "缺少试用文案 key: \(key)")
            let localizations = try XCTUnwrap(entry["localizations"] as? [String: Any])
            XCTAssertEqual(
                Set(localizations.keys), Set(translatedLocales),
                "试用文案 \(key) 未覆盖九种语言"
            )
            let sourceSignature = try formatSignature(key)
            for locale in translatedLocales {
                let localization = try XCTUnwrap(localizations[locale] as? [String: Any])
                let unit = try XCTUnwrap(localization["stringUnit"] as? [String: Any])
                let value = try XCTUnwrap(unit["value"] as? String)
                XCTAssertFalse(
                    value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "\(locale) 的 \(key) 为空"
                )
                XCTAssertEqual(
                    try formatSignature(value), sourceSignature,
                    "\(locale) 的 \(key) 占位符与源串不一致，会在运行时崩或错位"
                )
            }
        }
    }

    func testProjectDeclaresAllNineKnownRegions() throws {
        let projectURL = repositoryRoot.appendingPathComponent("CastReader.xcodeproj/project.pbxproj")
        guard FileManager.default.fileExists(atPath: projectURL.path) else {
            throw XCTSkip("Project source checks run on the host build machine")
        }
        let project = try String(
            contentsOf: projectURL,
            encoding: .utf8
        )
        for locale in appLocales {
            XCTAssertTrue(project.contains(locale), "Project does not declare \(locale)")
        }
    }

    // MARK: - Player control deck / Kindle surface stability

    func testKindleReaderSurfaceFreezesWhilePlayerVoiceOverlayIsPresented() {
        let stable = CGSize(width: 430, height: 690)
        let transient = CGSize(width: 453, height: 690)

        XCTAssertEqual(
            KindleReaderSurfaceContract.renderSize(
                measured: transient,
                stable: stable,
                isPlayerOverlayPresented: true
            ),
            stable,
            "Voice UI must not resize the Kindle WebView"
        )
        XCTAssertEqual(
            KindleReaderSurfaceContract.renderSize(
                measured: transient,
                stable: stable,
                isPlayerOverlayPresented: false
            ),
            transient,
            "Real reader layout changes still need to propagate"
        )
    }

    func testKindleVisualCandidateDriftCannotRestartPlaybackWithoutSemanticNavigation() {
        XCTAssertFalse(
            KindleExternalNavigationContract.shouldBeginResume(
                semanticSequenceAdvanced: false,
                hasActivePlayback: true,
                isReaderStable: true,
                isInternalTurnInFlight: false
            ),
            "OCR/preload candidate changes are not user page turns"
        )
        XCTAssertTrue(
            KindleExternalNavigationContract.shouldBeginResume(
                semanticSequenceAdvanced: true,
                hasActivePlayback: true,
                isReaderStable: true,
                isInternalTurnInFlight: false
            )
        )
        XCTAssertFalse(
            KindleExternalNavigationContract.shouldBeginResume(
                semanticSequenceAdvanced: true,
                hasActivePlayback: true,
                isReaderStable: true,
                isInternalTurnInFlight: true
            ),
            "An internal turn already in flight owns the transition"
        )
    }

    func testCachedAsyncImageRejectsStaleVoiceAvatarCompletion() {
        XCTAssertTrue(
            CachedAsyncImageLoadContract.shouldCommit(
                activeRequest: "https://cdn.example/voice-b.png",
                completedRequest: "https://cdn.example/voice-b.png",
                isCancelled: false
            )
        )
        XCTAssertFalse(
            CachedAsyncImageLoadContract.shouldCommit(
                activeRequest: "https://cdn.example/voice-b.png",
                completedRequest: "https://cdn.example/voice-a.png",
                isCancelled: false
            )
        )
        XCTAssertFalse(
            CachedAsyncImageLoadContract.shouldCommit(
                activeRequest: "https://cdn.example/voice-b.png",
                completedRequest: "https://cdn.example/voice-b.png",
                isCancelled: true
            )
        )
    }

    @MainActor
    func testPlaybackVoicePanelUsesOneNormalizedRootRequest() {
        let center = PlaybackVoicePanelCenter.shared
        center.dismiss()
        center.present(language: "ja-JP")
        XCTAssertTrue(center.isPresented)
        XCTAssertEqual(center.request?.language, "ja")
        center.dismiss()
        XCTAssertFalse(center.isPresented)
    }

    @MainActor
    func testExplainVoiceUsesTargetLanguageInsteadOfSourceLanguage() {
        let settings = AppSettings.shared
        let previous = settings.explainLanguage
        defer { settings.explainLanguage = previous }
        settings.explainLanguage = "es"

        let document = ReadingDocument(
            title: "Japanese source",
            sourceKind: .text,
            language: "ja",
            paragraphs: [ReadingParagraph(id: 0, text: "十分な長さの日本語本文です。", type: .paragraph)]
        )
        let vm = ExplainViewModel(document: document)
        XCTAssertEqual(vm.playbackLanguage, "es")
    }

    // MARK: - Unified nine-language import contract

    func testReadingSentenceContractCoversAllNineLanguages() {
        let samples: [String: String] = [
            "en": "First sentence. Second sentence!",
            "zh": "第一句话。第二句话！",
            "ja": "最初の文です。次の文です！",
            "es": "Primera frase. Segunda frase!",
            "fr": "Première phrase. Deuxième phrase !",
            "de": "Erster Satz. Zweiter Satz!",
            "pt": "Primeira frase. Segunda frase!",
            "it": "Prima frase. Seconda frase!",
            "hi": "यह पहला वाक्य है। यह दूसरा वाक्य है॥"
        ]
        XCTAssertEqual(Set(samples.keys), Set(SupportedTTSLanguage.allCases.map(\.rawValue)))
        for (language, text) in samples {
            XCTAssertEqual(
                ReadingSentenceContract.segments(text).count,
                2,
                "\(language) must preserve both sentence units"
            )
        }
    }

    func testReadingSentenceContractKeepsGermanAbbreviationsTogether() {
        XCTAssertEqual(
            ReadingSentenceContract.segments("Dr. Müller liest z. B. zwei Kapitel. Danach macht er Pause."),
            ["Dr. Müller liest z. B. zwei Kapitel.", "Danach macht er Pause."]
        )
    }

    func testReadingSentenceContractPreservesJapaneseAndChineseVisualWraps() {
        XCTAssertEqual(
            ReadingSentenceContract.normalizeWhitespace("日\n本\n語です。", language: "ja"),
            "日本語です。"
        )
        XCTAssertEqual(
            ReadingSentenceContract.normalizeWhitespace("中\n文内容。", language: "zh"),
            "中文内容。"
        )
        XCTAssertEqual(
            ReadingSentenceContract.normalizeWhitespace("hello\nworld.", language: "en"),
            "hello world."
        )
    }

    func testImportedOCRHindiSelectionRequiresStrongIndependentEvidence() {
        let weakVision = LanguageDetector.Evidence(language: "en", confidence: 0.31, readableCharacterCount: 9)
        let hindi = LanguageDetector.Evidence(language: "hi", confidence: 0.98, readableCharacterCount: 48)
        XCTAssertTrue(ImportedOCRLanguageSelection.shouldRunHindiProbe(vision: weakVision))
        XCTAssertTrue(ImportedOCRLanguageSelection.shouldPreferHindi(
            vision: weakVision,
            hindi: hindi,
            hindiMeanConfidence: 82
        ))

        let strongEnglish = LanguageDetector.Evidence(language: "en", confidence: 0.97, readableCharacterCount: 180)
        XCTAssertFalse(ImportedOCRLanguageSelection.shouldRunHindiProbe(vision: strongEnglish))
        XCTAssertFalse(ImportedOCRLanguageSelection.shouldPreferHindi(
            vision: strongEnglish,
            hindi: LanguageDetector.Evidence(language: "hi", confidence: 0.7, readableCharacterCount: 10),
            hindiMeanConfidence: 42
        ))
    }

    func testPDFRenderingModeSeparatesTextLayerFromOCRReflow() {
        let native = ReadingDocument(
            title: "Native PDF",
            sourceKind: .pdf,
            paragraphs: [ReadingParagraph(
                id: 0,
                text: "Searchable text.",
                pdfPageIndex: 0,
                pdfRange: NSRange(location: 0, length: 16)
            )]
        )
        XCTAssertTrue(native.usesNativePDFRendering)
        XCTAssertFalse(native.usesNativeTextRendering)

        let scanned = ReadingDocument(
            title: "Scanned PDF",
            sourceKind: .pdf,
            language: "hi",
            paragraphs: [ReadingParagraph(id: 0, text: "यह स्कैन किया गया पाठ है।", pdfPageIndex: 0)]
        )
        XCTAssertFalse(scanned.usesNativePDFRendering)
        XCTAssertTrue(scanned.usesNativeTextRendering)
    }

    // MARK: - 微信读书 live Canvas 合同

    func testWeReadAvailabilityIsGlobalWithoutLocaleRestrictions() {
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .simplifiedChinese,
            systemLanguageCode: "en",
            timeZoneIdentifier: "America/Los_Angeles"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .system,
            systemLanguageCode: "zh-Hans",
            timeZoneIdentifier: "Europe/Paris"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .english,
            systemLanguageCode: "en",
            timeZoneIdentifier: "Asia/Shanghai"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .japanese,
            systemLanguageCode: "ja",
            timeZoneIdentifier: "Asia/Tokyo"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .french,
            systemLanguageCode: "fr",
            timeZoneIdentifier: "Europe/Paris"
        ))
        XCTAssertTrue(WeReadAvailability.isAvailable(
            appLanguage: .hindi,
            systemLanguageCode: "hi",
            timeZoneIdentifier: "Asia/Kolkata"
        ))
    }

    func testDedicatedBookRailsDoNotDuplicateInHomeContinue() {
        XCTAssertFalse(HomeContinueContract.includes(.kindle))
        XCTAssertFalse(HomeContinueContract.includes(.weread))
        XCTAssertTrue(HomeContinueContract.includes(.web))
        XCTAssertTrue(HomeContinueContract.includes(.pdf))
    }

    func testWeReadBookAndSingleTurnContracts() {
        let readerURL = "https://weread.qq.com/web/reader/abcdef"
        XCTAssertEqual(WeReadBookValidator.usableReaderURL(readerURL), readerURL)
        XCTAssertNil(WeReadBookValidator.usableReaderURL("https://weread.qq.com/web/shelf"))
        XCTAssertNil(WeReadBookValidator.usableReaderURL("https://example.com/web/reader/a"))
        XCTAssertEqual(
            WeReadBookValidator.stableID(bookID: "abcdef", readerURL: readerURL, title: "Book"),
            "weread:abcdef"
        )

        let before = WeReadPageFingerprint.make(first: "第一页", last: "结尾", progress: "10%", route: readerURL)
        let after = WeReadPageFingerprint.make(first: "第二页", last: "新结尾", progress: "11%", route: readerURL)
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(WeReadPageTurnContract.canCommit(previous: before, next: after, actionID: "one-semantic-click"))
        XCTAssertFalse(WeReadPageTurnContract.canCommit(previous: before, next: before, actionID: "one-semantic-click"))
        XCTAssertFalse(WeReadPageTurnContract.canCommit(previous: before, next: after, actionID: ""))
        XCTAssertEqual(WeReadPageTurnContract.semanticNextLabels(), ["下一页"])
        XCTAssertEqual(WeReadPageTurnContract.manualRestartDelayNanoseconds, 600_000_000)

        let evidenceBefore = WeReadPageEvidence(
            contentFingerprint: before,
            layoutFingerprint: "layout-a",
            columnFingerprint: "0:0|1:900",
            canvasEpoch: 4
        )
        XCTAssertFalse(WeReadPageTurnContract.canCommit(
            previous: evidenceBefore,
            next: evidenceBefore,
            actionID: "one-semantic-click"
        ))
        XCTAssertTrue(WeReadPageTurnContract.canCommit(
            previous: evidenceBefore,
            next: WeReadPageEvidence(
                contentFingerprint: before,
                layoutFingerprint: "layout-a",
                columnFingerprint: "0:1800|1:2700",
                canvasEpoch: 5
            ),
            actionID: "one-semantic-click"
        ))
        XCTAssertFalse(WeReadPageTurnContract.canCommit(
            previous: evidenceBefore,
            next: WeReadPageEvidence(
                contentFingerprint: before,
                layoutFingerprint: "layout-b",
                columnFingerprint: "0:0|1:900",
                canvasEpoch: 5
            ),
            actionID: ""
        ))

        XCTAssertTrue(WeReadContinuousPageHandoffContract.shouldArm(
            sourceFingerprint: before,
            currentFingerprint: before,
            hasPreparedAudio: true,
            isLastReadableParagraph: true,
            currentTTSComplete: true,
            audioIsPlaying: true
        ))
        XCTAssertFalse(WeReadContinuousPageHandoffContract.shouldArm(
            sourceFingerprint: before,
            currentFingerprint: after,
            hasPreparedAudio: true,
            isLastReadableParagraph: true,
            currentTTSComplete: true,
            audioIsPlaying: true
        ))
        XCTAssertTrue(WeReadContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: "tail",
            predecessorSegmentID: "tail",
            remainingAudioSeconds: 0.9,
            playbackRate: 1.5
        ))
        XCTAssertFalse(WeReadContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: "other",
            predecessorSegmentID: "tail",
            remainingAudioSeconds: 0,
            playbackRate: 1
        ))
        XCTAssertTrue(WeReadContinuousPageHandoffContract.canReleasePreparedAudio(
            sourceFingerprint: before,
            previousFingerprint: before,
            predictedContentFingerprint: after,
            visibleContentFingerprint: after,
            preparedText: "下一页正文",
            visiblePreparedText: "下一页正文",
            preparedVoiceID: "zf_xiaobei",
            selectedVoiceID: "zf_xiaobei"
        ))
        XCTAssertFalse(WeReadContinuousPageHandoffContract.canReleasePreparedAudio(
            sourceFingerprint: before,
            previousFingerprint: before,
            predictedContentFingerprint: after,
            visibleContentFingerprint: "unexpected-page",
            preparedText: "这是预测的下一页内容，连续文字必须能够对应。",
            visiblePreparedText: "这是完全不同的一页，不能释放错误的预加载音频。",
            preparedVoiceID: "zf_xiaobei",
            selectedVoiceID: "zf_xiaobei"
        ))
        XCTAssertFalse(WeReadContinuousPageHandoffContract.canReleasePreparedAudio(
            sourceFingerprint: before,
            previousFingerprint: before,
            predictedContentFingerprint: after,
            visibleContentFingerprint: after,
            preparedText: "少了一句的预取正文",
            visiblePreparedText: "真实首句。少了一句的预取正文",
            preparedVoiceID: "zf_xiaobei",
            selectedVoiceID: "zf_xiaobei"
        ))

        let mapped = WeReadCrossPageSpeechContract.boundarySegment(
            segmentTexts: ["第一句。", "这句话从本页开始并跨到下一页才结束。"],
            boundaryUTF16Offset: ("第一句。这句话从本页开始" as NSString).length
        )
        XCTAssertEqual(mapped?.sequence, 1)
        XCTAssertEqual(
            mapped?.fraction ?? -1,
            Double(("这句话从本页开始" as NSString).length) /
                Double(("这句话从本页开始并跨到下一页才结束。" as NSString).length),
            accuracy: 0.0001
        )
        let cue = WeReadBoundaryAudioCue(
            segmentID: "boundary-sentence",
            segmentSequence: 1,
            boundaryTime: 2.4,
            segmentDuration: 4.8
        )
        XCTAssertTrue(WeReadCrossPageSpeechContract.shouldRequestTurn(
            currentSegmentID: "boundary-sentence",
            cue: cue,
            currentTime: 1.9,
            playbackRate: 1,
            leadSeconds: 0.6
        ))
        XCTAssertFalse(WeReadCrossPageSpeechContract.shouldRequestTurn(
            currentSegmentID: "another-sentence",
            cue: cue,
            currentTime: 2.4,
            playbackRate: 1,
            leadSeconds: 0.6
        ))
        XCTAssertTrue(WeReadCrossPageSpeechContract.shouldApplyConsumedCursor(
            pendingSemanticTurn: true,
            continuationSuppressed: false
        ))
        XCTAssertFalse(WeReadCrossPageSpeechContract.shouldApplyConsumedCursor(
            pendingSemanticTurn: true,
            continuationSuppressed: true
        ), "a manual turn or mode switch must not inherit the automatic cursor")
        XCTAssertFalse(WeReadCrossPageSpeechContract.shouldApplyConsumedCursor(
            pendingSemanticTurn: false,
            continuationSuppressed: false
        ))
        XCTAssertFalse(
            WeReadCrossPageSpeechContract
                .shouldClearContinuationSuppressionWhenReturningToRead(
                    pendingSemanticTurn: true
                ),
            "read → explain → read must not revive an in-flight turn's cursor"
        )
        XCTAssertTrue(
            WeReadCrossPageSpeechContract
                .shouldClearContinuationSuppressionWhenReturningToRead(
                    pendingSemanticTurn: false
                )
        )

        // The source-DOM cursor, not speculative audio readiness, is the
        // authority for exactly-once speech across a visual page boundary.
        // The first four UTF-16 code units on the confirmed page were already
        // spoken by the old page's complete natural-sentence audio item.
        let partiallyConsumed = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 7,
                    sourceUTF16Start: 20,
                    sourceUTF16End: 29,
                    text: "已经读过的新页内容。"
                ),
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 1,
                    sourceParagraphIndex: 8,
                    sourceUTF16Start: 0,
                    sourceUTF16End: 5,
                    text: "下一段。"
                ),
            ],
            through: WeReadConsumedTextCursor(sourceParagraphIndex: 7, sourceUTF16End: 24)
        )
        XCTAssertEqual(partiallyConsumed.texts, ["的新页内容。", "下一段。"])
        XCTAssertEqual(partiallyConsumed.carryParagraphIndex, 0)
        XCTAssertEqual(partiallyConsumed.carryUTF16Length, 4)

        // Preserve visual paragraph indices even when the carry sentence has
        // consumed the entire first slice. The next TTS request must begin at
        // paragraph 1 rather than rebuilding the page from paragraph 0.
        let fullyConsumed = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 7,
                    sourceUTF16Start: 24,
                    sourceUTF16End: 28,
                    text: "已读完。"
                ),
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 1,
                    sourceParagraphIndex: 8,
                    sourceUTF16Start: 0,
                    sourceUTF16End: 5,
                    text: "真正新句。"
                ),
            ],
            through: WeReadConsumedTextCursor(sourceParagraphIndex: 7, sourceUTF16End: 28)
        )
        XCTAssertEqual(fullyConsumed.texts, ["", "真正新句。"])
        XCTAssertEqual(fullyConsumed.carryParagraphIndex, 0)
        XCTAssertEqual(fullyConsumed.carryUTF16Length, 4)

        // Source paragraph indices are only local to one transient WeRead DOM
        // layout. Reusing the same integer from a different layout must not
        // clip real text from the newly visible page.
        let wrongLayout = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 0,
                    sourceLayoutFingerprint: "layout-b",
                    sourceParagraphIndex: 7,
                    sourceUTF16Start: 20,
                    sourceUTF16End: 29,
                    text: "不能被跳过的新句。"
                ),
            ],
            through: WeReadConsumedTextCursor(
                sourceLayoutFingerprint: "layout-a",
                sourceParagraphIndex: 7,
                sourceUTF16End: 24
            ),
            requireSourceLayoutIdentity: true
        )
        XCTAssertEqual(wrongLayout.texts, ["不能被跳过的新句。"])
        XCTAssertNil(wrongLayout.carryParagraphIndex)

        let missingIdentity = WeReadCrossPageSpeechContract.consumeAlreadySpokenPrefix(
            in: [
                WeReadSourceTextSlice(
                    visibleParagraphIndex: 0,
                    sourceParagraphIndex: 7,
                    sourceUTF16Start: 20,
                    sourceUTF16End: 29,
                    text: "来源不确定时保留全文。"
                ),
            ],
            through: WeReadConsumedTextCursor(
                sourceParagraphIndex: 7,
                sourceUTF16End: 24
            ),
            requireSourceLayoutIdentity: true
        )
        XCTAssertEqual(missingIdentity.texts, ["来源不确定时保留全文。"])
        XCTAssertNil(missingIdentity.carryParagraphIndex)
    }

    func testWeReadExplainOwnsItsPageLifecycle() {
        // QuickRead annotations and status updates can repaint the Canvas, but
        // they are not navigation and must not restart the explanation.
        for reason in ["canvas", "resize", "mutation", "foreground"] {
            XCTAssertFalse(WeReadExplainPageEventContract.shouldHandleVisualChange(
                isReadMode: false,
                reason: reason,
                hasPendingSemanticTurn: false,
                hasPendingManualTurn: false,
                refreshActive: false
            ))
        }

        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: false,
            reason: "manual-intent",
            hasPendingSemanticTurn: false,
            hasPendingManualTurn: false,
            refreshActive: false
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: false,
            reason: "canvas",
            hasPendingSemanticTurn: true,
            hasPendingManualTurn: false,
            refreshActive: false
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: false,
            reason: "canvas",
            hasPendingSemanticTurn: false,
            hasPendingManualTurn: true,
            refreshActive: false
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: false,
            reason: "theme",
            hasPendingSemanticTurn: false,
            hasPendingManualTurn: false,
            refreshActive: true
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldHandleVisualChange(
            isReadMode: true,
            reason: "canvas",
            hasPendingSemanticTurn: false,
            hasPendingManualTurn: false,
            refreshActive: false
        ))

        XCTAssertFalse(WeReadExplainPageEventContract.shouldResumeExplanation(isAutomaticTurn: false))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldResumeExplanation(isAutomaticTurn: true))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldResumeExplanation(
            isAutomaticTurn: false,
            resumeAlreadyArmed: true
        ))
        XCTAssertTrue(WeReadExplainPageEventContract.shouldResumeExplanation(
            isAutomaticTurn: false,
            wasLiveExplaining: true
        ))
    }

    func testWeReadExplainPrefetchRequiresExactVisiblePageAndCurrentSettings() {
        let baseline = (
            source: "page-a",
            predicted: "page-b-content",
            voice: "zf_xiaoxiao",
            depth: "standard"
        )
        XCTAssertTrue(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: baseline.predicted,
            predictedText: ["预测页面正文"],
            visibleText: ["预测页面正文"],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: baseline.voice,
            preparedDepth: baseline.depth,
            selectedDepth: baseline.depth
        ))
        let predictedPage = "下一页从这一句开始。" + String(repeating: "微信读书分页正文连续内容。", count: 12)
        let visiblePage = predictedPage + String(repeating: "真实页面尾部多出的正文。", count: 3)
        let boundaryMatch = WeReadSpeculativeTextContract.evaluate(
            predicted: [predictedPage],
            visible: [visiblePage]
        )
        XCTAssertTrue(boundaryMatch.isCompatible)
        XCTAssertEqual(boundaryMatch.predictedCoverage, 1, accuracy: 0.0001)
        XCTAssertGreaterThan(boundaryMatch.visibleCoverage, 0.70)
        XCTAssertTrue(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: "different-boundary-fingerprint",
            predictedText: [predictedPage],
            visibleText: [visiblePage],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: baseline.voice,
            preparedDepth: baseline.depth,
            selectedDepth: baseline.depth
        ))
        XCTAssertFalse(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: "a-different-page",
            predictedText: ["预测页面包含一段足够长的连续正文，用于验证下一页。"],
            visibleText: ["错误页面包含完全不同的内容，不允许命中推测缓存。"],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: baseline.voice,
            preparedDepth: baseline.depth,
            selectedDepth: baseline.depth
        ))
        XCTAssertFalse(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: baseline.predicted,
            predictedText: ["预测页面正文"],
            visibleText: ["预测页面正文"],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: "zf_xiaoyi",
            preparedDepth: baseline.depth,
            selectedDepth: baseline.depth
        ))
        XCTAssertFalse(WeReadExplainPagePrefetchContract.canConsume(
            sourceFingerprint: baseline.source,
            previousFingerprint: baseline.source,
            predictedContentFingerprint: baseline.predicted,
            visibleContentFingerprint: baseline.predicted,
            predictedText: ["预测页面正文"],
            visibleText: ["预测页面正文"],
            payloadTextFingerprint: baseline.predicted,
            preparedVoiceID: baseline.voice,
            selectedVoiceID: baseline.voice,
            preparedDepth: baseline.depth,
            selectedDepth: "deep"
        ))
    }

    func testWeReadViewportCropIsPredictedBeforeLoadAndCalibratedFromVisibleText() {
        let phone = CGSize(width: 390, height: 700)
        let predicted = WeReadViewportCrop.predicted(for: phone)
        XCTAssertEqual(predicted.widthScale, 1.19, accuracy: 0.001)
        XCTAssertEqual(predicted.offsetX, -37.05, accuracy: 0.01)
        let initialFrame = predicted.webViewFrame(for: phone)
        XCTAssertEqual(initialFrame.origin.x, predicted.offsetX, accuracy: 0.001)
        XCTAssertEqual(initialFrame.origin.y, 0, accuracy: 0.001)
        XCTAssertEqual(initialFrame.width, phone.width * 1.19, accuracy: 0.001)
        XCTAssertEqual(initialFrame.height, phone.height, accuracy: 0.001)
        XCTAssertEqual(WeReadViewportCrop.compactReaderBreakpoint, 700)
        XCTAssertEqual(WeReadViewportCrop.compactPageHorizontalPadding, 50)
        XCTAssertEqual(WeReadViewportCrop.compactOpeningWidthScale, 1.19)

        let calibrated = WeReadViewportCrop.calibrated(
            for: phone,
            layoutWidthScale: predicted.widthScale,
            contentLeftRatio: 0.16,
            contentRightRatio: 0.84
        )
        XCTAssertNotNil(calibrated)
        // Runtime text bounds are diagnostics only and must never resize or
        // translate WKWebView after the opening navigation.
        XCTAssertEqual(calibrated?.widthScale ?? 0, predicted.widthScale, accuracy: 0.001)
        XCTAssertEqual(calibrated?.offsetX ?? 1, predicted.offsetX, accuracy: 0.01)

        XCTAssertNil(WeReadViewportCrop.calibrated(
            for: phone,
            layoutWidthScale: predicted.widthScale,
            contentLeftRatio: 0.49,
            contentRightRatio: 0.51
        ))
        XCTAssertEqual(WeReadInitialPlaybackContract.stabilityDelayNanoseconds, 1_800_000_000)
    }

    func testWeReadPlaybackResumeFindsCurrentSentenceAcrossViewportReflow() {
        let anchor = WeReadPlaybackResumeAnchor(
            segmentText: "所谓的“社会话题性”，在她的作品里并不是目的。",
            sourceParagraphText: "但金爱烂的可贵之处在于，所谓的社会话题性，在她的作品里并不是目的，而是场景中的一个因素。",
            segmentProgress: 0.43,
            wasPlaying: true
        )
        let paragraphs = [
            ReadingParagraph(id: 0, text: "上一段已经结束。", type: .paragraph),
            ReadingParagraph(id: 1, text: "所谓的社会话题性，在她的作品里并不是目的。", type: .paragraph),
            ReadingParagraph(id: 2, text: "而是场景中的一个因素。", type: .paragraph),
        ]
        XCTAssertEqual(WeReadPlaybackResumeContract.paragraphIndex(in: paragraphs, anchor: anchor), 1)
        XCTAssertTrue(WeReadPlaybackResumeContract.segmentMatches(
            "所谓的社会话题性，在她的作品里并不是目的。",
            anchor: anchor
        ))
        XCTAssertFalse(WeReadPlaybackResumeContract.segmentMatches("完全不同的一句话。", anchor: anchor))
    }

    func testWeReadBackgroundLifecycleNeverReloadsForTransientForegroundProbeFailure() {
        XCTAssertFalse(WeReadBackgroundLifecycleContract.shouldReload(
            probeSucceeded: false,
            webContentProcessTerminationObserved: false
        ))
        XCTAssertFalse(WeReadBackgroundLifecycleContract.shouldReload(
            probeSucceeded: true,
            webContentProcessTerminationObserved: false
        ))
        XCTAssertTrue(WeReadBackgroundLifecycleContract.shouldReload(
            probeSucceeded: false,
            webContentProcessTerminationObserved: true
        ))
        XCTAssertFalse(WeReadBackgroundLifecycleContract.shouldScheduleRefreshFallback(
            applicationIsActive: false
        ))
        XCTAssertTrue(WeReadBackgroundLifecycleContract.shouldScheduleRefreshFallback(
            applicationIsActive: true
        ))
        XCTAssertEqual(WeReadBackgroundLifecycleContract.foregroundProbeDelays.count, 3)
        XCTAssertEqual(WeReadBackgroundLifecycleContract.foregroundProbeTimeout, 0.8)
    }

    func testWeReadRejectsGenericCoverAltAsBookTitle() {
        let generic = WeReadBook(
            id: "weread:bad",
            title: "书籍封面",
            author: "",
            coverURL: nil,
            readerURL: "https://weread.qq.com/web/reader/abcdef",
            progressLabel: "",
            bookID: "abcdef",
            lastOpenedAt: nil,
            lastSyncedAt: Date(),
            lastPageFingerprint: nil,
            lastReaderURL: nil
        )
        XCTAssertFalse(WeReadBookValidator.isLikelyLibraryBook(generic))
        XCTAssertTrue(WeReadWebScripts.libraryScan.contains("bookData.author"))
        XCTAssertTrue(WeReadWebScripts.libraryScan.contains(":scope > .title"))
    }

    func testWeReadShelfPageContractRejectsHomeRecommendationsAndLooseShelfPaths() {
        XCTAssertTrue(WeReadShelfPageContract.isExactShelfURL("https://weread.qq.com/web/shelf"))
        XCTAssertTrue(WeReadShelfPageContract.isExactShelfURL("https://weread.qq.com/web/shelf/?wr_theme=dark"))
        XCTAssertFalse(WeReadShelfPageContract.isExactShelfURL("http://weread.qq.com/web/shelf"))
        XCTAssertFalse(WeReadShelfPageContract.isExactShelfURL("https://evilweread.qq.com/web/shelf"))
        XCTAssertFalse(WeReadShelfPageContract.isExactShelfURL("https://weread.qq.com/web/shelf/archive"))
        XCTAssertFalse(WeReadShelfPageContract.isExactShelfURL("https://weread.qq.com/?next=/web/shelf"))
        XCTAssertFalse(WeReadShelfPageContract.isExactShelfURL("https://weread.qq.com:8443/web/shelf"))
        XCTAssertFalse(WeReadShelfPageContract.isExactShelfURL("https://reader@weread.qq.com/web/shelf"))

        let homeRecommendation: [String: Any] = [
            "url": "https://weread.qq.com/",
            "isShelfPage": false,
            "authenticated": true,
            "authRequired": false,
            "rawBookCount": 1,
            "books": [[
                "bookId": "recommendation-only",
                "title": "首页推荐",
                "readerURL": "https://weread.qq.com/web/reader/recommendation-only",
            ]],
        ]
        let result = WeReadScanResult(homeRecommendation)
        XCTAssertFalse(result.isShelfPage)
        XCTAssertTrue(result.books.isEmpty)
        XCTAssertEqual(result.rawBookCount, 1)
    }

    func testWeReadShelfSnapshotContractExcludedRowsDoNotVetoCompletion() {
        func shelfScan(
            pendingRows: Int = 0,
            excludedRows: Int = 0,
            loading: Bool = false,
            loadError: Bool = false,
            documentReady: Bool = true,
            reachedShelfEnd: Bool = true,
            hasAddTile: Bool = true,
            parsedBookCount: Int? = nil,
            bookCount: Int = 4
        ) -> WeReadScanResult {
            let books: [[String: Any]] = (0..<bookCount).map { index in
                [
                    "bookId": "book\(index)",
                    "title": "书 \(index)",
                    "readerURL": "https://weread.qq.com/web/reader/book\(index)",
                ]
            }
            return WeReadScanResult([
                "url": "https://weread.qq.com/web/shelf",
                "isShelfPage": true,
                "documentReady": documentReady,
                "reachedShelfEnd": reachedShelfEnd,
                "hasAddTile": hasAddTile,
                "loading": loading,
                "loadError": loadError,
                "rawBookCount": bookCount + pendingRows + excludedRows,
                "pendingRowCount": pendingRows,
                "excludedRowCount": excludedRows,
                "parsedBookCount": parsedBookCount ?? bookCount,
                "authenticated": true,
                "authRequired": false,
                "books": books,
            ])
        }

        // A shelf containing audio/video/banner tiles (excluded rows) must
        // still complete — this was the permanent veto behind the field
        // reports of "暂时没能同步微信读书书架，请重试".
        XCTAssertTrue(WeReadShelfSnapshotContract.isStableEndPass(
            shelfScan(excludedRows: 2), accumulatedUnchanged: true
        ))
        // Reader rows that have not hydrated yet keep blocking completion.
        XCTAssertFalse(WeReadShelfSnapshotContract.isStableEndPass(
            shelfScan(pendingRows: 1), accumulatedUnchanged: true
        ))
        // A native-side parse drop still blocks (page accepted more rows than
        // native parsed).
        XCTAssertFalse(WeReadShelfSnapshotContract.isStableEndPass(
            shelfScan(parsedBookCount: 5), accumulatedUnchanged: true
        ))
        XCTAssertFalse(WeReadShelfSnapshotContract.isStableEndPass(
            shelfScan(loadError: true), accumulatedUnchanged: true
        ))
        XCTAssertFalse(WeReadShelfSnapshotContract.isStableEndPass(
            shelfScan(), accumulatedUnchanged: false
        ))

        // Without the add tile the physical end still completes after extra
        // stable passes instead of stranding the user on markup drift.
        XCTAssertEqual(
            WeReadShelfSnapshotContract.requiredStablePasses(accumulatedIsEmpty: false, hasAddTile: true), 4
        )
        XCTAssertEqual(
            WeReadShelfSnapshotContract.requiredStablePasses(accumulatedIsEmpty: false, hasAddTile: false), 8
        )
        XCTAssertEqual(
            WeReadShelfSnapshotContract.requiredStablePasses(accumulatedIsEmpty: true, hasAddTile: true), 10
        )

        XCTAssertEqual(
            WeReadShelfSnapshotContract.failureReason(lastScan: shelfScan(loadError: true)), "load_error"
        )
        XCTAssertEqual(
            WeReadShelfSnapshotContract.failureReason(lastScan: shelfScan(pendingRows: 3)), "rows_pending"
        )
        XCTAssertEqual(
            WeReadShelfSnapshotContract.failureReason(lastScan: nil), "scan_unavailable"
        )
        XCTAssertTrue(WeReadShelfSnapshotContract.isNetworkShapedFailure("load_error"))
        XCTAssertFalse(WeReadShelfSnapshotContract.isNetworkShapedFailure("parse_mismatch"))
    }

    func testWeReadBookEntryRecoveryRetriesCanonicalBeforeShelfScan() {
        let canonical = "https://weread.qq.com/web/reader/book123"
        let resume = "https://weread.qq.com/web/reader/book123?chapter=9"

        XCTAssertEqual(
            WeReadBookEntryRecoveryContract.localFallbackURL(
                failedURL: resume,
                canonicalURL: canonical,
                resumeURL: resume
            ),
            canonical
        )
        XCTAssertNil(WeReadBookEntryRecoveryContract.localFallbackURL(
            failedURL: canonical,
            canonicalURL: canonical,
            resumeURL: resume
        ))
        XCTAssertFalse(WeReadBookEntryRecoveryContract.shouldDiscardResumeURL(
            oldCanonicalURL: canonical,
            newCanonicalURL: canonical,
            resumeURL: resume
        ))
        XCTAssertTrue(WeReadBookEntryRecoveryContract.shouldDiscardResumeURL(
            oldCanonicalURL: canonical,
            newCanonicalURL: "https://weread.qq.com/web/reader/book123-new",
            resumeURL: resume
        ))
    }

    func testWeReadBridgePreservesNoPrivateAPIBoundary() {
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("preRenderContainer"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("renderTargetContainer"))
        XCTAssertTrue(WeReadWebScripts.canvasIntercept.contains("CanvasRenderingContext2D.prototype.clearRect"))
        XCTAssertTrue(WeReadWebScripts.canvasIntercept.contains("effectiveArea>=area*.45"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("han/sample.length>=.45"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains(".readerFooter_button:last-child"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("label=next?'下一页':'上一页'"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("clean(candidate.textContent)===label"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("userPage(direction)"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("contentFingerprint"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("resolveSegmentRange"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("computeSourceSpan"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("manualTurnIntent"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("wereadLayoutStable"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("resumeAfterForeground"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("relayout(a)"))
        XCTAssertTrue(WeReadWebScripts.readerBridge.contains("document.addEventListener('pointerdown',manualTurnIntent,true)"))
        XCTAssertFalse(WeReadWebScripts.readerBridge.contains("${columns}|${progress}"))
        XCTAssertFalse(WeReadWebScripts.readerBridge.contains("chapterInfos"))
        XCTAssertFalse(WeReadWebScripts.readerBridge.contains("decodeChapterResponse"))
    }

    func testWeReadTOCBridgeUsesStableChapterIdentityAndOneNavigationAction() {
        XCTAssertTrue(WeReadWebScripts.tocBridge.contains("chapterInfos"))
        XCTAssertTrue(WeReadWebScripts.tocBridge.contains("chapterUid"))
        XCTAssertTrue(WeReadWebScripts.tocBridge.contains("chapterIdx"))
        XCTAssertTrue(WeReadWebScripts.tocBridge.contains("readerCatalog_list"))
        XCTAssertTrue(WeReadWebScripts.tocBridge.contains("wereadTOCCatalogRequest"))
        XCTAssertTrue(WeReadWebScripts.tocBridge.contains("installNativeCatalog"))
        XCTAssertTrue(WeReadWebScripts.tocBridge.contains("native-cookie-session"))

        // Navigation is one semantic click carrying real coordinates, dispatched
        // at WeRead's own catalog handler. `location.assign` is deliberately not
        // used: routing around the site's handler reloads the reader document,
        // and `HTMLElement.click()` produces a zero-coordinate event that current
        // WeRead Vue 2 ignores outright — that was the repeated no-op navigation.
        XCTAssertTrue(WeReadWebScripts.tocBridge.contains("dispatchEvent(new MouseEvent"))
        XCTAssertTrue(WeReadWebScripts.tocBridge.contains("clientX"))
        XCTAssertFalse(WeReadWebScripts.tocBridge.contains("location.assign"))
        // Still exactly one mechanism — no keyboard or route fallback cascade.
        XCTAssertFalse(WeReadWebScripts.tocBridge.contains("KeyboardEvent"))
        XCTAssertFalse(WeReadWebScripts.tocBridge.contains("HTMLElement.prototype.click"))
    }

    @MainActor
    func testWeReadTOCNormalizesDuplicatesAndMarksCurrentChapter() {
        let raw = [
            WeReadTOCEntry(index: 4, chapterIndex: 12, chapterUID: "b", title: "第二章"),
            WeReadTOCEntry(index: 1, chapterIndex: 3, chapterUID: "a", title: "第一章"),
            WeReadTOCEntry(index: 2, chapterIndex: 3, chapterUID: "a", title: "重复"),
            WeReadTOCEntry(index: 3, chapterIndex: 9, chapterUID: "", title: "   "),
        ]
        let normalized = WeReadTOCController.normalized(raw)
        XCTAssertEqual(normalized.map(\.chapterUID), ["a", "b"])
        XCTAssertEqual(normalized.map(\.index), [0, 1])

        let active = WeReadTOCController.markingCurrent(
            normalized,
            chapterUID: "b",
            chapterIndex: 3
        )
        XCTAssertFalse(active[0].active)
        XCTAssertTrue(active[1].active, "UID is authoritative when both identities are present")

        let indexFallback = WeReadTOCController.markingCurrent(
            normalized,
            chapterUID: "not-yet-available",
            chapterIndex: 3
        )
        XCTAssertTrue(indexFallback[0].active, "Chapter index must keep the current marker while UID state catches up")
        XCTAssertFalse(indexFallback[1].active)
    }

    @MainActor
    func testWeReadTOCRejectsPresentationOnlyRowsWithoutDowngradingIdentity() {
        let controller = WeReadTOCController(bookID: "toc-authority-\(UUID().uuidString)")
        controller.receive(
            [
                WeReadTOCEntry(
                    index: 0,
                    chapterIndex: 8,
                    chapterUID: "server-uid-8",
                    title: "旧标题"
                )
            ],
            currentChapterUID: nil,
            currentChapterIndex: nil
        )
        controller.receive(
            [
                WeReadTOCEntry(
                    index: 0,
                    chapterIndex: 8,
                    chapterUID: "",
                    title: "页面上的新标题"
                )
            ],
            currentChapterUID: nil,
            currentChapterIndex: 8
        )

        XCTAssertEqual(controller.entries.first?.chapterUID, "server-uid-8")
        XCTAssertEqual(controller.entries.first?.title, "旧标题")
        XCTAssertFalse(controller.entries.first?.active == true)
        XCTAssertNil(controller.errorText)
    }

    @MainActor
    func testWeReadTOCRefusesToNavigateWithoutAuthoritativeChapterUID() {
        let controller = WeReadTOCController(bookID: "toc-selection-\(UUID().uuidString)")
        var selected: WeReadTOCEntry?
        controller.onSelect = { selected = $0 }
        let presentationOnly = WeReadTOCEntry(
            index: 0,
            chapterIndex: 8,
            chapterUID: "",
            title: "页面目录文字"
        )

        controller.receive(
            [presentationOnly],
            currentChapterUID: nil,
            currentChapterIndex: nil
        )
        controller.select(presentationOnly)

        XCTAssertTrue(controller.entries.isEmpty)
        XCTAssertNil(selected)
        XCTAssertFalse(controller.isJumping)
        XCTAssertNotNil(controller.errorText)
    }

    func testWeReadUIStringsCoverAllNineRuntimeLanguages() {
        let keys = [
            "已同步的微信读书书架",
            "绑定微信读书",
            "登录后同步书架与阅读进度",
            "截图二维码，用微信扫码登录",
            "截图后打开微信扫一扫，从相册识别二维码。登录后会自动进入书架，供你同步到 CastReader。",
            "正在扫描微信读书书架…（%d）",
            "检测到 %d 本书",
            "同步后即可在 CastReader 中朗读和解读。",
            "请先登录微信读书，再点同步。",
            "微信读书书籍链接已失效，请重新登录并同步书架。",
            "微信读书登录已失效，请重新登录后继续。",
            "书架中没有找到这本书，请重新同步微信读书书架。",
            "目录",
            "正在加载目录…",
            "正在更新目录…",
            "正在跳转章节…",
            "暂未找到这本书的目录。",
            "跳转失败，请重试。"
        ]
        for language in AppLanguage.allCases where language != .system {
            guard let localization = language.bundleLocalization,
                  let path = Bundle.main.path(forResource: localization, ofType: "lproj"),
                  let bundle = Bundle(path: path) else {
                return XCTFail("Missing runtime bundle for \(language.rawValue)")
            }
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: nil, table: nil)
                XCTAssertFalse(value.isEmpty, "Empty WeRead translation for \(language.rawValue): \(key)")
                if language != .simplifiedChinese {
                    XCTAssertNotEqual(value, key, "Missing WeRead translation for \(language.rawValue): \(key)")
                }
            }
        }
    }
}

final class ReaderPlaybackBarLayoutContractTests: XCTestCase {
    func testCommercialAndWeReadPlayersUsePageControls() {
        XCTAssertTrue(
            ReaderPlaybackNavigationContract.usesPageTurns(for: .googleBooks)
        )
        XCTAssertTrue(
            ReaderPlaybackNavigationContract.usesPageTurns(for: .kobo)
        )
        XCTAssertTrue(
            ReaderPlaybackNavigationContract.usesPageTurns(for: .weread)
        )

        for source in [
            ReadingSourceKind.web,
            .docx,
            .pdf,
            .photo,
            .epub,
            .text,
            .kindle,
        ] {
            XCTAssertFalse(
                ReaderPlaybackNavigationContract.usesPageTurns(for: source),
                "\(source) must retain its own playback/navigation controls"
            )
        }
    }

    func testGenericReaderUsesTheSameCompactPortraitGeometryAsKindle() {
        XCTAssertEqual(ReaderPlaybackBarLayoutContract.portraitHeight, 72)
        XCTAssertEqual(ReaderPlaybackBarLayoutContract.consoleHeight, 64)
        XCTAssertEqual(
            ReaderPlaybackBarLayoutContract.reservedPortraitHeight(for: .read),
            72
        )
        XCTAssertEqual(
            ReaderPlaybackBarLayoutContract.reservedPortraitHeight(for: .explain),
            72
        )
    }

    func testExplainCaptionDoesNotConsumeReaderViewportHeight() {
        XCTAssertFalse(ReaderPlaybackBarLayoutContract.explainCaptionConsumesReservedHeight)
        XCTAssertLessThan(ReaderPlaybackBarLayoutContract.explainCaptionOffset, 0)
        XCTAssertEqual(
            ReaderPlaybackBarLayoutContract.portraitHeight
                - ReaderPlaybackBarLayoutContract.consoleHeight,
            8,
            "The caption must overflow above the console instead of adding a subtitle row"
        )
    }

    func testPartialLandscapeCapsulesDoNotCropAFullWidthWebBand() {
        XCTAssertEqual(
            ReaderPlaybackBarLayoutContract.bottomContentOcclusion(
                controlsCoverFullWidth: false
            ),
            0,
            "Visible Kobo text outside the compact capsules must remain in the TTS snapshot"
        )
        XCTAssertEqual(
            ReaderPlaybackBarLayoutContract.bottomContentOcclusion(
                controlsCoverFullWidth: true
            ),
            ReaderPlaybackBarLayoutContract.landscapeControlHeight
        )
    }

    func testReadControlShowsWaitingAndErrorsInsteadOfFakePausedState() {
        XCTAssertEqual(
            ReadPlaybackPresentationContract.resolve(
                isPlaying: false,
                isWaitingForPlayableAudio: true,
                status: .loading
            ),
            .waiting
        )
        XCTAssertEqual(
            ReadPlaybackPresentationContract.resolve(
                isPlaying: false,
                isWaitingForPlayableAudio: false,
                status: .error("network")
            ),
            .retry
        )
        XCTAssertEqual(
            ReadPlaybackPresentationContract.resolve(
                isPlaying: false,
                isWaitingForPlayableAudio: false,
                status: .ready
            ),
            .paused
        )
        XCTAssertEqual(
            ReadPlaybackPresentationContract.resolve(
                isPlaying: true,
                isWaitingForPlayableAudio: true,
                status: .streaming
            ),
            .playing
        )
    }

    func testShortSegmentWaitingKeepsPreviousStablePresentation() {
        XCTAssertFalse(
            ReaderPlaybackWaitingDebounceContract.hasExceededDelay(
                elapsedMilliseconds: 299
            )
        )
        XCTAssertEqual(
            ReaderPlaybackWaitingDebounceContract.resolve(
                rawWaiting: true,
                waitingHasExceededDelay: false,
                previousStablePresentation: ReadPlaybackPresentationState.playing,
                currentStablePresentation: ReadPlaybackPresentationState.paused,
                waitingPresentation: ReadPlaybackPresentationState.waiting
            ),
            .playing,
            "a normal sub-300ms segment handoff must keep the pause icon and listening status"
        )
    }

    func testSustainedWaitingUsesStableOrangeLoadingControl() {
        XCTAssertTrue(
            ReaderPlaybackWaitingDebounceContract.hasExceededDelay(
                elapsedMilliseconds: 300
            )
        )
        XCTAssertEqual(
            ReaderPlaybackWaitingDebounceContract.resolve(
                rawWaiting: true,
                waitingHasExceededDelay: true,
                previousStablePresentation: ReadPlaybackPresentationState.playing,
                currentStablePresentation: ReadPlaybackPresentationState.paused,
                waitingPresentation: ReadPlaybackPresentationState.waiting
            ),
            .waiting
        )
        XCTAssertTrue(
            ReaderPrimaryPlaybackButtonVisualContract.keepsPrimaryCircleWhileLoading
        )
        XCTAssertEqual(
            ReaderPrimaryPlaybackButtonVisualContract.portraitSize,
            52
        )
        XCTAssertEqual(
            ReaderPrimaryPlaybackButtonVisualContract.landscapeSize,
            44
        )
    }

    func testWaitingEndImmediatelyReturnsToCurrentRealState() {
        XCTAssertEqual(
            ReaderPlaybackWaitingDebounceContract.resolve(
                rawWaiting: false,
                waitingHasExceededDelay: true,
                previousStablePresentation: ReaderExplainPlaybackPresentationState.playing,
                currentStablePresentation: ReaderExplainPlaybackPresentationState.paused,
                waitingPresentation: ReaderExplainPlaybackPresentationState.waiting
            ),
            .paused
        )
    }

    func testActiveOrPreparingPlaybackContinuesAcrossModeSwitch() {
        XCTAssertTrue(
            ReaderModeSwitchPlaybackContract.shouldContinueFromRead(
                audioIsPlaying: true,
                viewModelIsPlaying: false,
                status: .ready
            )
        )
        XCTAssertTrue(
            ReaderModeSwitchPlaybackContract.shouldContinueFromRead(
                audioIsPlaying: false,
                viewModelIsPlaying: false,
                status: .loading
            )
        )
        XCTAssertFalse(
            ReaderModeSwitchPlaybackContract.shouldContinueFromRead(
                audioIsPlaying: false,
                viewModelIsPlaying: false,
                status: .ready
            ),
            "an explicitly paused Read session must remain paused"
        )
        XCTAssertFalse(
            ReaderModeSwitchPlaybackContract.shouldContinueFromRead(
                audioIsPlaying: false,
                viewModelIsPlaying: false,
                status: .streaming
            ),
            "a paused Read session stays streaming after its first response and must remain paused"
        )

        XCTAssertTrue(
            ReaderModeSwitchPlaybackContract.shouldContinueFromExplain(
                audioIsPlaying: false,
                viewModelIsPlaying: false,
                status: .planning,
                isPreparingNext: false
            )
        )
        XCTAssertTrue(
            ReaderModeSwitchPlaybackContract.shouldContinueFromExplain(
                audioIsPlaying: false,
                viewModelIsPlaying: false,
                status: .streaming(block: 0, total: 2),
                isPreparingNext: true
            )
        )
        XCTAssertFalse(
            ReaderModeSwitchPlaybackContract.shouldContinueFromExplain(
                audioIsPlaying: false,
                viewModelIsPlaying: false,
                status: .streaming(block: 0, total: 2),
                isPreparingNext: false
            ),
            "an explicitly paused Explain session must remain paused"
        )
    }
}

final class AudioPlaybackOwnershipTests: XCTestCase {
    func testReadRecoveryReloadsOnlyCompleteCachedParagraph() {
        XCTAssertEqual(
            ReadAloudOwnershipRecoveryPlan.resolve(
                isReady: true,
                cachedSegmentCount: 2
            ),
            .reloadCachedParagraph
        )
        XCTAssertEqual(
            ReadAloudOwnershipRecoveryPlan.resolve(
                isReady: false,
                cachedSegmentCount: 2
            ),
            .regenerateParagraph,
            "a partial streaming paragraph must be regenerated instead of replaying a truncated cache"
        )
        XCTAssertEqual(
            ReadAloudOwnershipRecoveryPlan.resolve(
                isReady: true,
                cachedSegmentCount: 0
            ),
            .regenerateParagraph
        )
    }

    func testExplainRecoveryPrefersPreparedThenReplayThenSafeRestart() {
        XCTAssertEqual(
            ExplainOwnershipRecoveryPlan.resolve(
                currentBlockIndex: 2,
                hasCurrentPreparedBlock: true,
                replayBlockCount: 3,
                statusIsActive: true
            ),
            .preparedBlock(index: 2)
        )
        XCTAssertEqual(
            ExplainOwnershipRecoveryPlan.resolve(
                currentBlockIndex: 7,
                hasCurrentPreparedBlock: false,
                replayBlockCount: 3,
                statusIsActive: true
            ),
            .replayBlock(index: 2)
        )
        XCTAssertEqual(
            ExplainOwnershipRecoveryPlan.resolve(
                currentBlockIndex: -1,
                hasCurrentPreparedBlock: false,
                replayBlockCount: 0,
                statusIsActive: true
            ),
            .restartPlanning(reusingStartedSession: true)
        )
        XCTAssertEqual(
            ExplainOwnershipRecoveryPlan.resolve(
                currentBlockIndex: -1,
                hasCurrentPreparedBlock: false,
                replayBlockCount: 0,
                statusIsActive: false
            ),
            .restartPlanning(reusingStartedSession: false)
        )
    }

    func testModeSwitchFencesOldQueueFromOwnerAndRemotePlayback() {
        var state = AudioPlaybackOwnershipState()
        let read = state.claim(.readAloud)
        XCTAssertTrue(state.attachQueue(to: read))
        XCTAssertTrue(state.permitsPlayback(requestedBy: read))
        XCTAssertFalse(
            state.permitsPlayback(requestedBy: nil),
            "an un-tokenized in-app caller must not inherit the active owner"
        )
        XCTAssertTrue(state.permitsRemotePlayback)

        let explain = state.claim(.explain)
        XCTAssertFalse(state.permitsPlayback(requestedBy: read))
        XCTAssertFalse(state.permitsCallback(from: read))
        XCTAssertFalse(
            state.permitsRemotePlayback,
            "remote commands must not revive the retained Read queue after Explain becomes active"
        )
        XCTAssertFalse(state.attachQueue(to: read))

        XCTAssertTrue(state.attachQueue(to: explain))
        XCTAssertTrue(state.permitsPlayback(requestedBy: explain))
        XCTAssertTrue(state.permitsCallback(from: explain))
        XCTAssertTrue(state.permitsRemotePlayback)
    }

    func testSameOwnerClaimCreatesNewSessionAndRejectsLateCallbacks() {
        var state = AudioPlaybackOwnershipState()
        let first = state.claim(.readAloud)
        XCTAssertTrue(state.attachQueue(to: first))

        let replacement = state.claim(.readAloud)
        XCTAssertNotEqual(first, replacement)
        XCTAssertFalse(state.permitsQueueMutation(first))
        XCTAssertFalse(state.permitsPlayback(requestedBy: first))
        XCTAssertFalse(state.permitsRemotePlayback)

        XCTAssertTrue(state.attachQueue(to: replacement))
        XCTAssertTrue(state.permitsPlayback(requestedBy: replacement))
        XCTAssertFalse(
            state.permitsCallback(from: first),
            "an old AVPlayerItem callback must stay fenced after the replacement queue is attached"
        )
        XCTAssertTrue(state.permitsCallback(from: replacement))
    }

    func testContinuousHandoffTransfersQueueToFreshSessionWithoutUnownedGap() throws {
        var state = AudioPlaybackOwnershipState()
        let oldPage = state.claim(.readAloud)
        XCTAssertTrue(state.attachQueue(to: oldPage))

        let nextPage = try XCTUnwrap(state.transferActiveQueue(to: .readAloud))
        XCTAssertNotEqual(oldPage, nextPage)
        XCTAssertEqual(state.activeSession, nextPage)
        XCTAssertEqual(state.queueSession, nextPage)
        XCTAssertFalse(state.permitsPlayback(requestedBy: oldPage))
        XCTAssertFalse(state.permitsCallback(from: oldPage))
        XCTAssertTrue(state.permitsPlayback(requestedBy: nextPage))
        XCTAssertTrue(state.permitsCallback(from: nextPage))
    }

    func testReleasedSessionCannotBeRestartedByRemoteCommand() {
        var state = AudioPlaybackOwnershipState()
        let explain = state.claim(.explain)
        XCTAssertTrue(state.attachQueue(to: explain))

        state.release(explain)

        XCTAssertFalse(state.permitsPlayback(requestedBy: explain))
        XCTAssertFalse(state.permitsRemotePlayback)
    }
}

final class TTSEndpointSecurityTests: XCTestCase {
    func testNewTTSContractContainsOnlyTheTwoHTTPSGatewaysAndNoCrossRouteFallback() {
        XCTAssertEqual(TTSEndpoint.globalBase, "https://api.castreader.ai")
        XCTAssertEqual(TTSEndpoint.chinaMainlandBase, "https://api.castreader.cn")
        XCTAssertNil(TTSEndpoint.fallbackBase(isMainlandChina: true))
        XCTAssertNil(TTSEndpoint.fallbackBase(isMainlandChina: false))
    }
}

final class QuickReadEndpointSecurityTests: XCTestCase {
    func testNewQuickReadContractPinsGlobalAndDedicatedChinaIngresses() {
        XCTAssertEqual(QuickReadEndpoint.defaultBase, "https://api.castreader.ai")
        XCTAssertEqual(QuickReadEndpoint.chinaBase, "https://quickread.castreader.cn")
        XCTAssertFalse(QuickReadEndpoint.defaultBase.contains("qr.castreader.ai"))
        XCTAssertFalse(QuickReadEndpoint.chinaBase.contains(".ai"))
    }
}

final class QuickReadFastLaneHandoffTests: XCTestCase {
    private func paragraphs() -> [ReadingParagraph] {
        (0..<7).map { index in
            ReadingParagraph(
                id: index,
                text: "paragraph-\(index)-" + String(repeating: "x", count: index + 1),
                type: index == 0 ? .heading(1) : .paragraph
            )
        }
    }

    func testOpeningAndQualityInputArePhysicalPrefixAndDisjointSuffix() throws {
        let source = paragraphs()
        let opening = Array(source.prefix(2))
        let handoff = try XCTUnwrap(QuickReadFastLaneHandoff(
            readableParagraphs: source,
            selectedOpening: opening,
            fastNarration: "fast narration"
        ))

        XCTAssertEqual(handoff.opening + handoff.qualityInput, source)
        XCTAssertTrue(
            Set(handoff.opening.map(\.id)).isDisjoint(with: Set(handoff.qualityInput.map(\.id)))
        )
        XCTAssertEqual(handoff.reindexedQualityInput.map(\.id), Array(0..<5))
        XCTAssertEqual(handoff.reindexedQualityInput.map(\.text), Array(source.dropFirst(2)).map(\.text))
        XCTAssertNotEqual(handoff.openingDigest.fingerprint, handoff.qualityDigest.fingerprint)
        XCTAssertEqual(
            handoff.qualityDigest,
            QuickReadFastLaneHandoff.scopeDigest(handoff.reindexedQualityInput),
            "reindexing for transport must not change the logged quality-scope fingerprint"
        )

        XCTAssertNil(QuickReadFastLaneHandoff(
            readableParagraphs: source,
            selectedOpening: Array(source[1...2]),
            fastNarration: "fast narration"
        ), "a non-prefix opening must fall back instead of sending overlapping scopes")
    }

    func testFastNarrationIsTheQualityPlanPreviousSummary() throws {
        let source = paragraphs()
        let narration = "The already-played opening explanation."
        let handoff = try XCTUnwrap(QuickReadFastLaneHandoff(
            readableParagraphs: source,
            selectedOpening: Array(source.prefix(2)),
            fastNarration: narration
        ))

        XCTAssertEqual(handoff.previousSummary, narration)
        XCTAssertEqual(
            QuickReadFastLaneHandoff.continuitySummary(
                explicitPreviousSummary: handoff.previousSummary,
                fastNarration: "stale fallback"
            ),
            narration
        )
        XCTAssertEqual(
            QuickReadFastLaneHandoff.continuitySummary(
                explicitPreviousSummary: nil,
                fastNarration: narration
            ),
            narration
        )
    }

    func testFastLanePlaybackAndQualityBlockIndexesRoundTrip() {
        let indexBase = 1
        XCTAssertNil(QuickReadFastLaneHandoff.qualityBlockIndex(
            forPlaybackBlockIndex: 0,
            indexBase: indexBase
        ))

        for qualityIndex in 0..<4 {
            let playbackIndex = QuickReadFastLaneHandoff.playbackBlockIndex(
                forQualityBlockIndex: qualityIndex,
                indexBase: indexBase
            )
            XCTAssertEqual(playbackIndex, qualityIndex + 1)
            XCTAssertEqual(
                playbackIndex.flatMap {
                    QuickReadFastLaneHandoff.qualityBlockIndex(
                        forPlaybackBlockIndex: $0,
                        indexBase: indexBase
                    )
                },
                qualityIndex
            )
        }

        XCTAssertEqual(QuickReadFastLaneHandoff.qualityBlockIndex(
            forPlaybackBlockIndex: 0,
            indexBase: 0
        ), 0, "the original single-lane path keeps block zero unchanged")
    }
}

@MainActor
final class StudyBoostTests: XCTestCase {
    private func campaignCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(
        _ month: Int,
        _ day: Int,
        year: Int = 2026,
        hour: Int = 12,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone,
                year: year,
                month: month,
                day: day,
                hour: hour
            )
        )!
    }

    func testStudyDeepLinkMatchesOnlyStudyRoute() {
        XCTAssertTrue(StudyBoostDeepLink.matches(URL(string: "castreader://study")!))
        XCTAssertTrue(StudyBoostDeepLink.matches(URL(string: "CASTREADER://STUDY/?source=app-store")!))
        XCTAssertFalse(StudyBoostDeepLink.matches(URL(string: "https://castreader.com/study")!))
        XCTAssertFalse(StudyBoostDeepLink.matches(URL(string: "castreader://pro")!))
        XCTAssertFalse(StudyBoostDeepLink.matches(URL(string: "castreader://study/other")!))
    }

    func testStudyCampaignUsesInclusiveSeptember15Boundary() {
        let calendar = campaignCalendar()
        XCTAssertEqual(
            StudyBoostCampaign.phase(
                at: date(8, 17, hour: 23, calendar: calendar),
                completedDays: 0,
                calendar: calendar
            ),
            .upcoming
        )
        XCTAssertEqual(
            StudyBoostCampaign.phase(
                at: date(8, 18, hour: 0, calendar: calendar),
                completedDays: 0,
                calendar: calendar
            ),
            .active
        )
        XCTAssertEqual(
            StudyBoostCampaign.phase(
                at: date(9, 15, hour: 23, calendar: calendar),
                completedDays: 0,
                calendar: calendar
            ),
            .active
        )
        XCTAssertEqual(
            StudyBoostCampaign.phase(
                at: date(9, 16, hour: 0, calendar: calendar),
                completedDays: 0,
                calendar: calendar
            ),
            .ended
        )
    }

    func testStudyDaysAreUniqueWindowedAndPersistent() throws {
        let suite = "StudyBoostTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = campaignCalendar()
        let store = StudyBoostStore(
            defaults: defaults,
            calendar: calendar,
            now: { self.date(8, 18, calendar: calendar) }
        )

        XCTAssertFalse(store.recordStudySession(at: date(8, 17, calendar: calendar)))
        XCTAssertTrue(store.recordStudySession(at: date(8, 18, calendar: calendar)))
        XCTAssertFalse(store.recordStudySession(at: date(8, 18, hour: 22, calendar: calendar)))
        XCTAssertTrue(store.recordStudySession(at: date(8, 19, calendar: calendar)))
        XCTAssertFalse(store.recordStudySession(at: date(9, 16, hour: 0, calendar: calendar)))
        XCTAssertEqual(store.completedDays, 2)

        let restored = StudyBoostStore(
            defaults: defaults,
            calendar: calendar,
            now: { self.date(8, 19, calendar: calendar) }
        )
        XCTAssertEqual(restored.completedDays, 2)
        XCTAssertTrue(restored.isTodayComplete)
    }

    func testSevenUniqueStudyDaysCompleteChallenge() throws {
        let suite = "StudyBoostGoalTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = campaignCalendar()
        let store = StudyBoostStore(
            defaults: defaults,
            calendar: calendar,
            now: { self.date(8, 24, calendar: calendar) }
        )

        for day in 18...24 {
            XCTAssertTrue(store.recordStudySession(at: date(8, day, calendar: calendar)))
        }
        XCTAssertEqual(store.completedDays, StudyBoostCampaign.goalDays)
        XCTAssertEqual(store.progress, 1, accuracy: 0.001)
        XCTAssertEqual(store.phase, .completed)
    }

    func testStudyBoostCopyCoversExactlyNineProductLanguages() {
        let productLanguages = AppLanguage.allCases.filter { $0 != .system }.map(\.rawValue).sorted()
        XCTAssertEqual(StudyBoostCopy.supportedLanguages.map(\.rawValue).sorted(), productLanguages)
        XCTAssertEqual(productLanguages.count, 9)

        for language in StudyBoostCopy.supportedLanguages {
            let copy = StudyBoostCopy.localized(for: language, locale: language.locale)
            let strings = Mirror(reflecting: copy).children.compactMap { $0.value as? String }
            XCTAssertEqual(strings.count, 21, "\(language.rawValue) 文案字段数量异常")
            XCTAssertTrue(
                strings.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
                "\(language.rawValue) 存在空白活动文案"
            )
        }
    }

}

final class AppleAccountLinkTests: XCTestCase {

    @MainActor
    func testAppleCredentialStateFailsClosedWhenAuthorizationIsGone() {
        XCTAssertFalse(
            AuthService.appleCredentialRequiresLocalSignOut(.authorized)
        )
        XCTAssertTrue(
            AuthService.appleCredentialRequiresLocalSignOut(.revoked)
        )
        XCTAssertTrue(
            AuthService.appleCredentialRequiresLocalSignOut(.notFound)
        )
        XCTAssertTrue(
            AuthService.appleCredentialRequiresLocalSignOut(.transferred)
        )
    }

    @MainActor
    func testRemovingAppleArchiveDeletesUserAcrossRouteFields() {
        let userID = "apple-delete-test-\(UUID().uuidString)"
        defer { AuthService.removeArchivedAppleProfile(for: userID) }

        AuthService.archiveAppleProfile(
            id: userID,
            name: "Delete Me",
            email: "delete@example.com",
            backendUserId: "backend-delete-test"
        )
        XCTAssertEqual(AuthService.archivedAppleProfile(for: userID).name, "Delete Me")

        AuthService.removeArchivedAppleProfile(for: userID)

        let removed = AuthService.archivedAppleProfile(for: userID)
        XCTAssertNil(removed.name)
        XCTAssertNil(removed.email)
        XCTAssertNil(removed.backendUserId)
    }

    /// `needsAppleRelink` 是付费用户被当成免费用户时唯一的自救提示，误报会骚扰
    /// 正常用户，漏报会让人永远卡住——两个方向都要钉住。
    @MainActor
    func testNeedsAppleRelink_onlyForAppleAccountsMissingBackendId() {
        let auth = AuthService.shared
        let restore = auth.account
        defer {
            if let restore { auth.applyAccount(restore) } else { auth.signOut() }
        }

        auth.signOut()
        XCTAssertFalse(auth.needsAppleRelink, "未登录不该提示重新关联")

        auth.applyAccount(UserAccount(
            id: "google-sub", email: "a@b.com", name: nil, pictureURL: nil,
            provider: "google", backendUserId: nil
        ))
        XCTAssertFalse(auth.needsAppleRelink, "Google 账号有 Keychain 重试路径，不该走 Apple 提示")

        auth.applyAccount(UserAccount(
            id: "apple-sub", email: nil, name: nil, pictureURL: nil,
            provider: "apple", backendUserId: "backend-123"
        ))
        XCTAssertFalse(auth.needsAppleRelink, "已关联的 Apple 账号不该提示")

        auth.applyAccount(UserAccount(
            id: "apple-sub", email: nil, name: nil, pictureURL: nil,
            provider: "apple", backendUserId: nil
        ))
        XCTAssertTrue(auth.needsAppleRelink, "Apple 账号缺后端 id 必须提示，否则用户无从自救")

        auth.applyAccount(UserAccount(
            id: "apple-sub", email: nil, name: nil, pictureURL: nil,
            provider: "apple", backendUserId: ""
        ))
        XCTAssertTrue(auth.needsAppleRelink, "空串等同于未关联")
        XCTAssertNil(auth.proUserId?.isEmpty == false ? auth.proUserId : nil,
                     "未关联时 proUserId 不该被当作有效值传给 /api/pro/status")
    }
}

@MainActor
private final class KindleTestMessageCollector: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let payload = message.body as? [String: Any] {
            messages.append(payload)
        }
    }
}

@MainActor
final class EmailOTPNetworkPolicyTests: XCTestCase {

    func testDedicatedSessionIsBoundedAndDoesNotStoreCookies() {
        let configuration = AuthService.emailOTPSessionConfiguration

        XCTAssertEqual(configuration.timeoutIntervalForRequest, 20, accuracy: 0.001)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 20, accuracy: 0.001)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
    }

    func testOTPRequestIsCookieFreeJSONPost() throws {
        let url = try XCTUnwrap(URL(string: "https://castreader.com/api/auth/email-otp/send-verification-otp"))
        let request = AuthService.makeEmailOTPRequest(
            url: url,
            body: ["email": "reader@example.com", "type": "sign-in"]
        )

        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["email"], "reader@example.com")
        XCTAssertEqual(json["type"], "sign-in")
    }

    func testSendAndVerifyMapClientErrorsByOperation() {
        let csrfPayload = Data(#"{"code":"MISSING_OR_NULL_ORIGIN"}"#.utf8)
        XCTAssertEqual(
            kind(of: AuthService.mapEmailOTPFailure(
                statusCode: 403,
                data: csrfPayload,
                operation: .send
            )),
            .failed,
            "发码阶段的 CSRF 403 不能误报成验证码错误"
        )

        for statusCode in [400, 401, 403] {
            XCTAssertEqual(
                kind(of: AuthService.mapEmailOTPFailure(
                    statusCode: statusCode,
                    data: Data(),
                    operation: .send
                )),
                .failed,
                "发码阶段 HTTP \(statusCode) 不能映射为 invalidOTP"
            )
            XCTAssertEqual(
                kind(of: AuthService.mapEmailOTPFailure(
                    statusCode: statusCode,
                    data: Data(),
                    operation: .verify
                )),
                .invalidOTP,
                "验码阶段 HTTP \(statusCode) 应提示验证码无效"
            )
        }

        let invalidEmail = Data(#"{"code":"INVALID_EMAIL"}"#.utf8)
        XCTAssertEqual(
            kind(of: AuthService.mapEmailOTPFailure(
                statusCode: 400,
                data: invalidEmail,
                operation: .send
            )),
            .invalidEmail
        )
    }

    func testEndpointAndGatewayFailuresKeepActionableMeaning() {
        for operation in [AuthService.EmailOTPOperation.send, .verify] {
            XCTAssertEqual(
                kind(of: AuthService.mapEmailOTPFailure(
                    statusCode: 404,
                    data: Data(),
                    operation: operation
                )),
                .unavailable
            )
            XCTAssertEqual(
                kind(of: AuthService.mapEmailOTPFailure(
                    statusCode: 504,
                    data: Data(),
                    operation: operation
                )),
                .timeout
            )
            XCTAssertEqual(
                kind(of: AuthService.mapEmailOTPFailure(
                    statusCode: 503,
                    data: Data(),
                    operation: operation
                )),
                .failed
            )
        }
    }

    func testTransportFailuresDistinguishTimeoutAndNetwork() {
        XCTAssertEqual(
            kind(of: AuthService.mapEmailOTPTransportError(URLError(.timedOut))),
            .timeout
        )

        let networkCodes: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .cannotConnectToHost,
            .cannotFindHost,
            .dnsLookupFailed,
            .internationalRoamingOff,
            .dataNotAllowed,
        ]
        for code in networkCodes {
            XCTAssertEqual(
                kind(of: AuthService.mapEmailOTPTransportError(URLError(code))),
                .network,
                "\(code) 应保留为可操作的网络错误"
            )
        }

        XCTAssertEqual(
            kind(of: AuthService.mapEmailOTPTransportError(URLError(.cancelled))),
            .failed
        )
        XCTAssertEqual(
            kind(of: AuthService.mapEmailOTPTransportError(NSError(
                domain: "EmailOTPNetworkPolicyTests",
                code: 1
            ))),
            .failed
        )
    }

    private enum ErrorKind: Equatable {
        case unavailable
        case invalidEmail
        case invalidOTP
        case timeout
        case network
        case failed
        case other
    }

    private func kind(of error: AuthError) -> ErrorKind {
        switch error {
        case .emailOTPUnavailable: return .unavailable
        case .invalidEmail: return .invalidEmail
        case .invalidOTP: return .invalidOTP
        case .emailOTPTimeout: return .timeout
        case .emailOTPNetwork: return .network
        case .emailOTPFailed: return .failed
        default: return .other
        }
    }
}
