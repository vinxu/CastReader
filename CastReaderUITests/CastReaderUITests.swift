//
//  CastReaderUITests.swift
//  CastReaderUITests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest
import UIKit
import Vision

/// Opt-in UI evidence for the installed extension. Pixel attachments still need
/// review; a passing button-state test alone does not prove highlight visibility.
final class SafariLiveReadingUITests: XCTestCase {
    func testInstalledSafariReadingControls() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_SAFARI_LIVE_UI"] == "1")
        continueAfterFailure = false
        let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")
        safari.activate()
        // A manually opened, site-specific simulator permission prompt may be
        // pending. Grant only the current public test website for this day.
        let wikipediaPermission = safari.alerts.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "CastReader", "en.wikipedia.org")).firstMatch
        if wikipediaPermission.exists {
            wikipediaPermission.buttons["Allow for One Day"].tap()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            safari.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.45)).tap()
        }
        XCTAssertTrue(safari.webViews.firstMatch.waitForExistence(timeout: 20))
        // A tab can retain an old content script after reinstalling the app.
        let reload = safari.buttons["ReloadButton"]
        if reload.exists { reload.tap() }
        func evidence(_ name: String) {
            let picture = XCTAttachment(screenshot: safari.screenshot())
            picture.name = name
            picture.lifetime = .keepAlways
            add(picture)
            let diagnostic = safari.textViews["CastReader QA status"]
            if diagnostic.exists, let value = diagnostic.value as? String {
                let status = XCTAttachment(string: value)
                status.name = name + "-diagnostic"
                status.lifetime = .keepAlways
                add(status)
            }
        }
        func button(_ labels: [String]) -> XCUIElement {
            safari.buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
        }
        func settle(_ seconds: TimeInterval) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        evidence("safari-before-reading")
        let tree = XCTAttachment(string: safari.debugDescription)
        tree.name = "safari-controls-before-reading"
        tree.lifetime = .keepAlways
        add(tree)
        let pause = button(["Pause", "暂停"])
        if !pause.exists {
            let start = button(["Read this page", "朗读当前页", "Resume", "继续", "恢复"])
            XCTAssertTrue(start.waitForExistence(timeout: 45), "Enable the installed CastReader extension on the open test page")
            start.tap()
        }
        XCTAssertTrue(pause.waitForExistence(timeout: 45))
        for index in 0..<8 {
            settle(3)
            evidence("safari-playing-\(index)")
        }
        // Start this pause check during sustained playback. On a short heading
        // the same primary button can become "cancel loading" before the tap.
        let pauseDeadline = Date().addingTimeInterval(90)
        var playingSince: Date?
        while Date() < pauseDeadline {
            if pause.exists {
                if playingSince == nil { playingSince = Date() }
                if Date().timeIntervalSince(playingSince!) >= 8 { break }
            } else {
                playingSince = nil
            }
            settle(0.2)
        }
        XCTAssertNotNil(playingSince)
        XCTAssertTrue(pause.exists)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(playingSince!), 8)
        pause.tap()
        let resume = button(["Resume", "继续", "恢复"])
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        evidence("safari-paused-start")
        settle(3)
        evidence("safari-paused-end")
        let speed = safari.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", ["Speed", "速度"])).firstMatch
        XCTAssertTrue(speed.exists)
        speed.tap()
        let slowerRate = safari.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "0.75x")).firstMatch
        XCTAssertTrue(slowerRate.waitForExistence(timeout: 5))
        slowerRate.tap()
        evidence("safari-rate-changed")
        let chooseVoice = button(["Choose voice", "选择音色"])
        XCTAssertTrue(chooseVoice.exists)
        chooseVoice.tap()
        let voiceTree = XCTAttachment(string: safari.debugDescription)
        voiceTree.name = "safari-voice-options"
        voiceTree.lifetime = .keepAlways
        add(voiceTree)
        let bella = safari.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS[c] %@", "Bella", "preview")).firstMatch
        XCTAssertTrue(bella.waitForExistence(timeout: 10))
        let voiceToSelect = bella.label.contains("Current voice")
            ? safari.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND NOT label CONTAINS[c] %@", "Heart", "preview")).firstMatch
            : bella
        XCTAssertTrue(voiceToSelect.exists)
        voiceToSelect.tap()
        evidence("safari-voice-changed")
        XCTAssertTrue(resume.waitForExistence(timeout: 30))
        resume.tap()
        // Changing voice can require a fresh cloud generation, just like start.
        XCTAssertTrue(pause.waitForExistence(timeout: 45))
        for index in 0..<8 {
            settle(3)
            evidence("safari-resumed-\(index)")
        }
        let stop = button(["Stop", "停止", "Stop reading", "停止朗读"])
        XCTAssertTrue(stop.exists)
        stop.tap()
        settle(2)
        evidence("safari-stopped")
        XCTAssertFalse(pause.exists)
    }
}

class CastReaderUITests: XCTestCase {

    func testGrowthReadyStartsListeningBeforeTrialPaywall() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderGrowthOfferFixture", "-CastReaderDisableDebugPro",
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en"]
        app.launch()
        let primary = app.buttons["growthTrialOfferPrimary"]
        XCTAssertTrue(primary.waitForExistence(timeout: 15))
        XCTAssertEqual(primary.label, "Start reading")
        XCTAssertFalse(app.buttons["paywallPurchaseButton"].exists)
        primary.tap()
        XCTAssertEqual(app.staticTexts["growthFixtureStarts"].label, "starts=1")
        XCTAssertFalse(primary.exists)
        XCTAssertFalse(app.buttons["paywallPurchaseButton"].exists)
        app.buttons["growthFixture30Seconds"].tap()
        XCTAssertTrue(primary.waitForExistence(timeout: 5))
        XCTAssertNotEqual(primary.label, "Start reading")
        primary.tap()
        XCTAssertTrue(app.buttons["paywallPurchaseButton"].waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "growth-30s-real-paywall-synthetic-milestone"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    /// Explicitly opt in only after the account owner authorizes syncing the
    /// already signed-in Kobo session. This test never enters credentials or
    /// clears the shared WebKit profile, and ordinary CI skips it.
    func testKoboAuthorizedLiveShelfSync() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["CASTREADER_KOBO_LIVE_SYNC"] == "1",
            "Live Kobo sync requires CASTREADER_KOBO_LIVE_SYNC=1 after user authorization"
        )
        guard let rawCount = environment["CASTREADER_KOBO_LIVE_EXPECTED_BOOKS"],
              let expectedCount = Int(rawCount), expectedCount > 0 else {
            XCTFail("Set CASTREADER_KOBO_LIVE_EXPECTED_BOOKS to the verified positive book count")
            return
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-CastReaderKoboHomeValidation",
            "-CastReaderSkipLibraryOnboarding",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-interfaceLanguage", "en",
        ]
        app.launch()
        openKoboConnectionFromHome(app)

        let sync = app.buttons["koboSyncButton"]
        let syncReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"),
            object: sync
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [syncReady], timeout: 60), .completed,
            "The already authorized Kobo shelf must reach a tappable native sync action"
        )
        XCTAssertTrue(
            app.staticTexts["Found \(expectedCount) books, ready to sync."].exists,
            "The complete shelf must match the independently verified account book count"
        )
        keepScreenshot(of: app, named: "Kobo-authorized-live-\(expectedCount)-ready")

        sync.tap()
        XCTAssertTrue(
            app.staticTexts["Synced \(expectedCount) books."].waitForExistence(timeout: 15),
            "The authorized live shelf must commit with the same verified count"
        )
        keepScreenshot(of: app, named: "Kobo-authorized-live-\(expectedCount)-synced")
        returnFromKoboConnectionToHome(app)
        let homeBooks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.kobo."))
        XCTAssertTrue(homeBooks.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(homeBooks.count, expectedCount)
        keepScreenshot(of: app, named: "Kobo-live-home-after-sync")
        let bookIDs = homeBooks.allElementsBoundByIndex.map(\.identifier)
        for (index, identifier) in bookIDs.enumerated() {
            let book = app.buttons[identifier]
            scrollTo(book, in: app)
            XCTAssertTrue(book.isHittable)
            book.tap()
            let reader = app.webViews["koboReaderWebView"]
            XCTAssertTrue(reader.waitForExistence(timeout: 30), "Home book must enter the actual reader")
            XCTAssertTrue(app.buttons["readerMinimizeButton"].exists)
            // Actual parsed-content readiness is checked below after the
            // official reader loads; a native title alone is not evidence.
            let expectedUUID = String(identifier.dropFirst("homeShelfBook.kobo.".count))
            XCTAssertTrue(waitForKoboReadablePage(reader, bookUUID: expectedUUID, timeout: 90), "Official Kobo reader must provide real parsed text")
            keepScreenshot(of: app, named: "Kobo-live-book-\(index + 1)-readable")
            let before = reader.value as? String
            let next = app.buttons["readerNextPageButton"]
            XCTAssertTrue(next.isHittable)
            next.tap()
            XCTAssertTrue(waitForKoboReadablePage(reader, bookUUID: expectedUUID, excluding: before, timeout: 30), "Next page must produce different real text")
            keepScreenshot(of: app, named: "Kobo-live-book-\(index + 1)-next-page")
            app.buttons["readerMinimizeButton"].tap()
        }
        app.terminate()
        app.launch()
        XCTAssertTrue(homeBooks.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(homeBooks.count, expectedCount, "A fresh process must reload the shelf on Home")
        keepScreenshot(of: app, named: "Kobo-live-home-persisted-after-relaunch")
    }

    private func koboHomeLaunchArguments() -> [String] {
        ["-CastReaderKoboHomeValidation", "-CastReaderSkipLibraryOnboarding",
         "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en"]
    }

    private func scrollTo(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 where !element.isHittable { app.swipeUp() }
    }

    private func openKoboConnectionFromHome(_ app: XCUIApplication) {
        let sources = app.buttons["homeShelfSourcesButton"]
        XCTAssertTrue(sources.waitForExistence(timeout: 15))
        sources.tap()
        let connect = app.buttons["shelfSourcePrimaryAction.kobo"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        scrollTo(connect, in: app)
        connect.tap()
        XCTAssertTrue(app.webViews["koboBindingWebView"].waitForExistence(timeout: 15))
    }

    private func returnFromKoboConnectionToHome(_ app: XCUIApplication) {
        app.buttons["Done"].tap()
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        close.tap()
        XCTAssertTrue(app.buttons["homeShelfSourcesButton"].waitForExistence(timeout: 10))
    }

    private func waitForKoboReadablePage(_ reader: XCUIElement, bookUUID: String, excluding previous: String? = nil, timeout: TimeInterval) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let value = reader.value as? String else { return false }
            let fields = value.split(separator: ":").map(String.init)
            guard fields.count == 4, fields[0] == "ready", fields[1] == bookUUID,
                  let count = Int(fields[2]), count > 0 else { return false }
            return previous?.split(separator: ":").last.map(String.init) != fields[3]
        }, object: reader)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    func testKoboHundredBooksBindSyncAndPersistOnHome() throws {
        let app = XCUIApplication()
        app.launchArguments = koboHomeLaunchArguments() + [
            "-CastReaderKoboHundredShelfFixture", "-CastReaderResetKoboHundredFixture",
        ]
        app.launch()
        openKoboConnectionFromHome(app)
        let sync = app.buttons["koboSyncButton"]
        XCTAssertTrue(sync.waitForExistence(timeout: 50))
        XCTAssertTrue(app.staticTexts["Found 100 books, ready to sync."].exists)
        keepScreenshot(of: app, named: "Kobo-100-four-pages-ready")
        sync.tap()
        XCTAssertTrue(app.staticTexts["Synced 100 books."].waitForExistence(timeout: 15))
        returnFromKoboConnectionToHome(app)
        let rail = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.kobo."))
        XCTAssertTrue(rail.firstMatch.waitForExistence(timeout: 10))
        let viewAll = app.descendants(matching: .any)["homeShelfViewAll.kobo"].firstMatch
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "Kobo-100-home-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
        scrollTo(viewAll, in: app)
        XCTAssertTrue(viewAll.isHittable)
        keepScreenshot(of: app, named: "Kobo-100-home-rail")
        viewAll.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        for number in [1, 25, 26, 50, 51, 75, 76, 100] {
            search.tap()
            if let old = search.value as? String, old.contains("合成测试书") {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
            }
            search.typeText(String(format: "合成测试书 %03d", number))
            let uuid = String(format: "b1000000-0000-4000-8000-%012d", number)
            XCTAssertTrue(app.buttons["koboLibraryBook.\(uuid)"].waitForExistence(timeout: 5),
                          "Every page boundary, including book 100, must be available in the saved library")
        }
        keepScreenshot(of: app, named: "Kobo-100-last-book-in-library")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-CastReaderResetKoboHundredFixture" }
        app.launch()
        XCTAssertTrue(rail.firstMatch.waitForExistence(timeout: 15))
        app.buttons["homeShelfSourcesButton"].tap()
        XCTAssertTrue(app.buttons["shelfSourcePrimaryAction.kobo"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Synced 100 books."].waitForExistence(timeout: 10),
                      "After restart the actual source UI must report the full persisted count")
        keepScreenshot(of: app, named: "Kobo-100-count-persisted-after-relaunch")
    }

    /// A local form exercises the real binding UI without credentials or an
    /// identity-provider request. In particular, delayed shelf probes must not
    /// put the native sign-in card back over an already visible login form.
    func testKoboLoginFixtureKeepsFormUsableWithoutNativeOverlay() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CastReaderKoboLoginFixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-interfaceLanguage", "en",
        ]
        app.launch()

        let web = app.webViews["koboBindingWebView"]
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        let email = web.textFields["Email"]
        let password = web.secureTextFields["Password"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        XCTAssertTrue(password.exists)
        XCTAssertTrue(app.buttons["koboReloadButton"].exists)

        let card = app.descendants(matching: .any)["koboBindingCard"].firstMatch
        XCTAssertTrue(waitForDisappearance(card, timeout: 5))
        let cardReappears = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"), object: card
        )
        cardReappears.isInverted = true
        XCTAssertEqual(
            XCTWaiter.wait(for: [cardReappears], timeout: 2), .completed,
            "The original bug reclassified the login page during its first four probes"
        )
        XCTAssertFalse(app.buttons["koboSignInButton"].exists)

        email.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        email.typeText("fixture@example.invalid")
        XCTAssertEqual(email.value as? String, "fixture@example.invalid")
        XCTAssertFalse(card.exists, "The keyboard must never bring back a native overlay")
        keepScreenshot(of: app, named: "Kobo-login-email-keyboard-unobstructed")

        for _ in 0..<3 where !password.isHittable { web.swipeUp() }
        XCTAssertTrue(password.isHittable, "The webpage password field must remain reachable")
        password.tap()
        password.typeText("local-fixture-only")
        XCTAssertFalse(card.exists)
        XCTAssertFalse(app.buttons["koboSignInButton"].exists)

        let submit = web.buttons["Continue"]
        for _ in 0..<3 where !submit.isHittable { web.swipeUp() }
        XCTAssertTrue(submit.isHittable, "The webpage action must be tappable with the keyboard open")
        keepScreenshot(of: app, named: "Kobo-login-password-action-unobstructed")
        submit.tap()
        XCTAssertTrue(
            web.staticTexts["Form submitted locally"].waitForExistence(timeout: 5),
            "The local form must actually submit, without a network request"
        )
        keepScreenshot(of: app, named: "Kobo-login-local-form-submitted")
    }

    /// A blank document must resolve to visible recovery controls instead of
    /// leaving a hidden error or a permanent loading state over the WebView.
    func testKoboBlankFixtureShowsVisibleRetryWithoutCoveringWebView() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CastReaderKoboBlankFixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-interfaceLanguage", "en",
        ]
        app.launch()

        let web = app.webViews["koboBindingWebView"]
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        let error = app.staticTexts["koboBindingError"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(error.isHittable, "The retry explanation must be visible")
        let reload = app.buttons["koboReloadButton"]
        XCTAssertTrue(reload.isHittable)
        XCTAssertTrue(reload.isEnabled)

        let card = app.descendants(matching: .any)["koboBindingCard"].firstMatch
        XCTAssertTrue(card.exists)
        XCTAssertLessThanOrEqual(
            web.frame.maxY, card.frame.minY + 1,
            "The compact status must occupy space below the webpage, not cover it"
        )
        keepScreenshot(of: app, named: "Kobo-blank-visible-retry-below-webpage")
    }

    /// Kobo can open an empty popup first and fill it with its official form.
    /// The native sign-in action must retain that WebKit window and provide a
    /// local close path without treating cancellation as login success.
    func testKoboPopupFixtureKeepsBlankWindowLoginAndCloseUsable() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CastReaderKoboPopupFixture",
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-interfaceLanguage", "en",
        ]
        app.launch()

        let main = app.webViews["koboBindingWebView"]
        XCTAssertTrue(main.waitForExistence(timeout: 15))
        let signIn = app.buttons["koboSignInButton"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.isHittable)
        signIn.tap()

        let popup = app.webViews["koboLoginPopupWebView"]
        XCTAssertTrue(popup.waitForExistence(timeout: 10))
        let password = popup.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Kobo-popup-before-input")
        // Exercise a real touch at the rendered control: WebKit's about:blank
        // popup can report no AX hit point even with a visible input frame.
        password.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        password.typeText("local-popup-only")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse((password.value as? String ?? "").isEmpty,
                       "The popup must accept real keyboard input")
        XCTAssertFalse(
            app.descendants(matching: .any)["koboBindingCard"].firstMatch.exists,
            "Native shelf status must not cover an authentication popup"
        )
        let closePopup = app.buttons["koboClosePopupButton"]
        XCTAssertTrue(closePopup.isHittable)
        keepScreenshot(of: app, named: "Kobo-popup-local-login-unobstructed")

        closePopup.tap()
        XCTAssertTrue(waitForDisappearance(popup, timeout: 5))
        XCTAssertTrue(main.exists)
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.isHittable)
        XCTAssertFalse(app.buttons["koboClosePopupButton"].exists)
        keepScreenshot(of: app, named: "Kobo-popup-cancel-returns-to-sign-in")
    }

    /// Runs the real connection view and commit path against an isolated,
    /// delayed four-page shelf. No Kobo account or remote book data is used.
    func testKoboFourPageShelfFixtureCollectsAndCommits77Books() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-CastReaderKoboShelfFixture",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        app.launch()
        let sync = app.buttons["koboSyncButton"]
        XCTAssertTrue(sync.waitForExistence(timeout: 45))
        let ready = app.staticTexts.matching(NSPredicate(
            format: "label == %@ OR label == %@", "找到 77 本书，可以同步。", "Found 77 books, ready to sync."
        )).firstMatch
        XCTAssertTrue(ready.exists, "Only the union of all four pages may enable sync")
        keepScreenshot(of: app, named: "Kobo-4-pages-77-ready")
        sync.tap()
        let synced = app.staticTexts.matching(NSPredicate(
            format: "label == %@ OR label == %@", "已同步 77 本书。", "Synced 77 books."
        )).firstMatch
        XCTAssertTrue(synced.waitForExistence(timeout: 10), "The verified 77-book shelf must commit")
        XCTAssertFalse(sync.exists)
        keepScreenshot(of: app, named: "Kobo-4-pages-77-synced")
    }

    /// 声音克隆发布后必须显示「已创建」入口；未登录测试态仍由账号闸门保护。
    func testVoiceBrowserShowsCreatedTabAndKeepsAccountGate() throws {
        let app = launchZh()
        app.tabBars.buttons["音色"].tap()
        XCTAssertTrue(app.buttons["探索"].waitForExistence(timeout: 5))
        let created = app.buttons["已创建"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        created.tap()
        XCTAssertTrue(app.staticTexts["登录后创建声音"].waitForExistence(timeout: 5))
    }

    func testHomeVoiceFeatureCarouselRoutesToExploreAndRecord() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-interfaceLanguage", "system",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderRegion", "global",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let discover = app.buttons["homeVoiceDiscoverBanner"]
        let record = app.buttons["homeVoiceRecordBanner"]
        let invite = app.buttons["homeVoiceInviteBanner"]
        XCTAssertTrue(discover.waitForExistence(timeout: 5))
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        let showsCapabilityGatedInvite = invite.waitForExistence(timeout: 1)

        // The banners intentionally live at the end of Home, immediately before
        // the optional Pro card. Scroll to the end before inspecting their frames.
        for _ in 0..<10 {
            app.swipeUp()
        }
        XCTAssertTrue(discover.isHittable)
        XCTAssertTrue(record.isHittable)

        XCTAssertEqual(discover.frame.width, record.frame.width, accuracy: 0.5)
        XCTAssertEqual(discover.frame.height, record.frame.height, accuracy: 0.5)
        XCTAssertEqual(discover.frame.minY, record.frame.minY, accuracy: 0.5)
        if showsCapabilityGatedInvite {
            XCTAssertEqual(discover.frame.width, invite.frame.width, accuracy: 0.5)
            XCTAssertEqual(discover.frame.minY, invite.frame.minY, accuracy: 0.5)
        }

        let windowFrame = app.windows.firstMatch.frame
        let leftInset = discover.frame.minX - windowFrame.minX
        XCTAssertEqual(leftInset, 20, accuracy: 2)
        XCTAssertEqual(record.frame.minX - discover.frame.maxX, 12, accuracy: 1)
        if showsCapabilityGatedInvite {
            XCTAssertEqual(invite.frame.minX - record.frame.maxX, 12, accuracy: 1)
            XCTAssertLessThan(invite.frame.minX, windowFrame.maxX)
            XCTAssertGreaterThan(invite.frame.maxX, windowFrame.maxX)
        }

        let proCard = app.otherElements["homeProCard"]
        if proCard.exists {
            XCTAssertLessThan(record.frame.maxY, proCard.frame.minY)
        }

        discover.tap()
        XCTAssertTrue(app.buttons["探索"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["性别"].waitForExistence(timeout: 5))

        app.tabBars.buttons["首页"].tap()
        XCTAssertTrue(record.waitForExistence(timeout: 5))
        record.tap()
        XCTAssertTrue(app.buttons["已创建"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["登录 CastReader"].waitForExistence(timeout: 5))
    }

    func testVoiceCreationMethodChooserRendersAvailableMethods() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderRegion", "global",
            "-CastReaderOpenVoiceCreationMethods",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        app.tabBars.buttons["音色"].tap()
        let created = app.buttons["已创建"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        created.tap()

        XCTAssertTrue(app.otherElements["voiceCreationMethodSheet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voiceCreationMethodRecordButton"].exists)
        XCTAssertTrue(app.buttons["voiceCreationMethodUploadButton"].exists)
        XCTAssertTrue(app.buttons["voiceCreationMethodUploadButton"].isEnabled)
        XCTAssertFalse(app.staticTexts["voiceCreationMethodUploadComingSoon"].exists)
    }

    /// Debug-only presentation hook exercises the original recording flow
    /// without bypassing the account boundary.
    func testVoiceCloneDoubaoStyleRecordingShell() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderOpenVoiceCloneCreation",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        app.tabBars.buttons["音色"].tap()
        let created = app.buttons["已创建"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        created.tap()

        XCTAssertTrue(app.staticTexts["克隆我的声音"].waitForExistence(timeout: 5))
        let confirm = app.buttons["voiceCloneIntroConfirmButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(confirm.label.contains("确认录制"))
        XCTAssertTrue(app.staticTexts["录制自己的声音"].exists)
        XCTAssertTrue(app.staticTexts["找一处安静的地方"].exists)
        XCTAssertTrue(app.staticTexts["自由朗读或自然说话"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "可以朗读示例，也可以用录音语言自然说一段自己的内容，无需逐字一致。"
            ].exists
        )
        XCTAssertTrue(
            app.staticTexts[
                "所有用户均可创建和试听声音；Pro 可用于朗读和解读，每个会员周期 120 分钟。"
            ].exists
        )

        XCTAssertTrue(
            app.staticTexts[
                "继续即表示你确认录制的是本人声音，并同意仅在 App 内用于生成语音。"
            ].exists
        )
        XCTAssertFalse(app.switches.firstMatch.exists)
        let confirmEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: confirm
        )
        XCTAssertEqual(XCTWaiter().wait(for: [confirmEnabled], timeout: 3), .completed)
        confirm.tap()
        allowMicrophonePermissionIfPresent()

        XCTAssertTrue(app.staticTexts["请开始说话"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voiceCloneRecordingLanguagePicker"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "你可以朗读下面的示例，也可以自然说一段自己的内容，无需逐字一致。"
            ].exists
        )
        XCTAssertTrue(app.staticTexts["示例文本（可选）"].exists)
        XCTAssertTrue(
            app.staticTexts["我最喜欢的事情就是学习啦，我每天都会看书，学各种知识，希望变得更聪明！"]
                .exists
        )
        XCTAssertTrue(app.descendants(matching: .any)["voiceCloneHoldButton"].exists)
    }

    /// Runtime language overrides must reach the complete clone flow rather
    /// than only translating the surrounding Voice tab. This catches the
    /// previous regression where every locale still received the Chinese
    /// recording script and instructions.
    func testVoiceCloneRecordingShellFollowsEnglishAppLanguage() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-interfaceLanguage", "en",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderOpenVoiceCloneCreation",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        app.tabBars.buttons["Voice"].tap()
        let created = app.buttons["Created"]
        XCTAssertTrue(created.waitForExistence(timeout: 5))
        created.tap()

        XCTAssertTrue(app.staticTexts["Clone My Voice"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["克隆我的声音"].exists)
        XCTAssertTrue(app.staticTexts["Record your voice"].exists)
        XCTAssertTrue(app.staticTexts["Find a quiet place"].exists)
        XCTAssertTrue(app.staticTexts["Read Freely or Speak Naturally"].exists)
        let record = app.buttons["voiceCloneIntroConfirmButton"]
        XCTAssertTrue(record.waitForExistence(timeout: 3))
        XCTAssertTrue(record.label.contains("Continue to Record"))
        record.tap()
        allowMicrophonePermissionIfPresent()

        XCTAssertTrue(app.staticTexts["Start Speaking"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["voiceCloneRecordingLanguagePicker"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "You can read the sample below or speak naturally in your own words. It does not need to match exactly."
            ].exists
        )
        XCTAssertTrue(app.staticTexts["Sample Text (Optional)"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "My favorite thing is learning. I read every day, discover new ideas, and hope to understand the world a little better."
            ].exists
        )
        XCTAssertFalse(app.staticTexts["请开始说话"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["voiceCloneHoldButton"].exists)
    }

    func testUnknownReadingLanguageShowsFailureAndUsableLanguagePicker() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        let text = "Di sebuah lingkungan permukiman, warga membuka ruang baca bersama di bangunan yang sudah lama tidak digunakan."
        app.launchArguments = [
            "-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
            "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate",
            "-CastReaderUnknownLanguageFixture",
            "-CastReaderCaptureTextB64", Data(text.utf8).base64EncodedString()
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()
        let play = app.buttons["readPlayPauseButton"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30))
        let notice = app.staticTexts["readerPlaybackFailureNotice"]
        if !notice.waitForExistence(timeout: 2) { play.tap() }
        XCTAssertTrue(notice.waitForExistence(timeout: 15))
        XCTAssertTrue(notice.label.contains("language"))
        let voice = app.buttons["playbackVoiceButton"].firstMatch
        XCTAssertTrue(voice.waitForExistence(timeout: 5))
        XCTAssertTrue(voice.isHittable)
        XCTAssertEqual(voice.label, "Reading Language")
        voice.tap()
        let search = app.searchFields["Search Languages"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Indonesian")
        let indonesian = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Indonesian")).firstMatch
        XCTAssertTrue(indonesian.waitForExistence(timeout: 5))
        XCTAssertTrue(indonesian.isHittable)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "unknown-language-recovery-picker"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The Italian reader's exact path, end to end: a page narrated in English,
    /// the voice panel opened, the reading language corrected to Italian, and the
    /// same panel then asked for "Nicola".
    ///
    /// Before the fix the reader's language control was inert text and every list
    /// in the panel — including its own search box — was filtered by the page
    /// language, so this path dead-ended at "no matching voices".
    ///
    /// Opt-in: it needs the live voice catalog (the offline fallback ships one
    /// Italian voice, and Nicola is not it) and real read-aloud.
    ///
    /// Real read-aloud spends free listen quota, which is per install. Repeated runs
    /// on one simulator eventually exhaust it and the voice control never appears;
    /// `xcrun simctl uninstall <device> com.same.castreader` first.
    func testReaderVoicePanelCorrectsAMisdetectedReadingLanguage() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CASTREADER_RUN_LIVE_VOICE_TESTS"] == "1",
            "Set CASTREADER_RUN_LIVE_VOICE_TESTS=1 to run against the live voice catalog."
        )
        XCUIDevice.shared.orientation = .portrait
        let englishPage = """
        That dream was but a moment in a man's life, whose proper business it seemed \
        was to get food and kill his fellows and beget after the manner of all that \
        belongs to the fellowship of the beasts. About him, hidden from him by the \
        thinnest of veils, were the untouched sources of Power, whose magnitude we \
        scarcely do more than suspect even to-day.
        """
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-interfaceLanguage", "en",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderCaptureTextB64", Data(englishPage.utf8).base64EncodedString(),
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let play = app.buttons["readPlayPauseButton"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 30), "The seeded page must open in the reader")
        play.tap()

        // The voice control only appears once a paragraph has entered playback.
        let voiceButton = app.buttons["playbackVoiceButton"].firstMatch
        XCTAssertTrue(
            voiceButton.waitForExistence(timeout: 40),
            "Read-aloud must reach the voice control before the panel can be opened"
        )
        let englishVoice = voiceButton.value as? String ?? ""
        XCTAssertFalse(englishVoice.isEmpty)

        voiceButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["playbackVoicePanel"].waitForExistence(timeout: 10)
        )

        // The control is a Button again, not the disabled label it used to be.
        let languageControl = app.buttons["Reading Language"].firstMatch
        XCTAssertTrue(
            languageControl.waitForExistence(timeout: 5),
            "The reader's language control must be reachable and named Reading Language"
        )
        XCTAssertEqual(
            languageControl.value as? String,
            "English (United States)",
            "The panel opens on the language the content is currently narrated in"
        )
        languageControl.tap()

        // The picker is a half-height sheet whose rows are laid out lazily, so
        // reach Italian through its own search rather than by scrolling.
        let languageSearch = app.searchFields["Search Languages"]
        XCTAssertTrue(languageSearch.waitForExistence(timeout: 10))
        languageSearch.tap()
        languageSearch.typeText("Italian")
        let italian = app.buttons
            .matching(NSPredicate(format: "label BEGINSWITH %@", "Italian"))
            .firstMatch
        XCTAssertTrue(italian.waitForExistence(timeout: 10))
        italian.tap()

        // (a) The content itself is now narrated in Italian. The reader's own voice
        // control stays behind the panel and its value follows the reading language,
        // so a changed voice means the correction reached playback, not just the list.
        let switched = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value != %@", englishVoice),
            object: voiceButton
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [switched], timeout: 20),
            .completed,
            "Correcting the reading language must re-narrate with that language's voice"
        )
        XCTAssertEqual(
            voiceButton.value as? String,
            "Sara",
            "Italian with no stored preference resolves to the catalog default voice"
        )

        // (b) Nicola is now reachable from the search box that used to return nothing.
        let search = app.searchFields["Search Voices"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        search.tap()
        search.typeText("Nicola")
        XCTAssertTrue(
            app.staticTexts["Nicola"].waitForExistence(timeout: 15),
            "Searching Nicola after correcting the language must find the Italian voice"
        )
    }

    /// Explain keeps its language pinned. It is chosen by the user in Settings, and
    /// a cross-language voice is rejected downstream, so an openable control there
    /// would only offer voices that do nothing when tapped — a worse dead end than
    /// the one being fixed. Needs no network: only the control's shape is asserted.
    func testExplainVoicePanelKeepsItsLanguagePinned() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-interfaceLanguage", "system",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderCaptureTextB64",
            Data("A short English page for the explain panel.".utf8).base64EncodedString(),
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        XCTAssertTrue(
            app.buttons["readPlayPauseButton"].firstMatch.waitForExistence(timeout: 30),
            "The seeded page must open in the reader"
        )
        let modePicker = app.segmentedControls["readerModePicker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 5))
        let explain = modePicker.buttons["Explain"]
        XCTAssertTrue(explain.waitForExistence(timeout: 5))
        explain.tap()

        let voiceButton = app.buttons["playbackVoiceButton"].firstMatch
        XCTAssertTrue(voiceButton.waitForExistence(timeout: 15))
        voiceButton.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["playbackVoicePanel"].waitForExistence(timeout: 10)
        )

        XCTAssertTrue(
            app.staticTexts["Reading Language"].waitForExistence(timeout: 5),
            "The pinned control still states which language is being spoken"
        )
        XCTAssertFalse(
            app.buttons["Reading Language"].exists,
            "Explain's language must stay pinned rather than become correctable"
        )
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // UI tests must launch the application that they test.
        _ = launchZh()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    func testStudyBoostCTAOpensFixedStudyImportFlow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-interfaceLanguage", "system",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderOpenStudyBoost",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        XCTAssertTrue(
            app.descendants(matching: .any)["studyBoostView"].waitForExistence(timeout: 6)
        )
        let start = app.buttons["studyBoostStartButton"]
        XCTAssertTrue(start.exists)
        start.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["importOptions.study"].waitForExistence(timeout: 6),
            "Study Boost CTA must open the fixed Study scenario import panel"
        )
        XCTAssertTrue(app.buttons["Upload File"].exists)
        XCTAssertTrue(app.buttons["Take Photo"].exists)
    }

    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    // MARK: - 场景化首页 + 导航 P0 交互自检

    /// 强制中文 locale 启动（模拟器默认英文时也按中文断言）。
    private func launchZh() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments += [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-interfaceLanguage", "system",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()
        return app
    }

    /// A simulator can retain the one-time universal-link confirmation across
    /// app reinstalls. It is SpringBoard-owned and unrelated to onboarding, so
    /// clear it before asserting the app surface.
    private func dismissSelfOpenSystemAlertIfPresent() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // StoreKit can ask an unsigned simulator to sign in even though these
        // tests never purchase. Dismiss that unrelated system sheet so it
        // cannot cover the feature under test or strand the next test run.
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 2) else { return }
        for label in ["Not Now", "以后再说", "暂不", "Cancel", "取消"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
        for label in ["Open", "打开"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
    }

    /// A fresh install asks for microphone access when the clone recorder is
    /// prepared. Handle that one-time SpringBoard alert explicitly so this UI
    /// contract remains deterministic on both clean and reused simulators.
    private func allowMicrophonePermissionIfPresent(timeout: TimeInterval = 2) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: timeout) else { return }
        let title = alert.label.lowercased()
        guard title.contains("microphone") || title.contains("麦克风") else { return }
        for label in ["Allow", "允许", "OK", "好"] {
            let button = alert.buttons[label]
            if button.exists {
                button.tap()
                return
            }
        }
        if alert.buttons.count > 1 {
            alert.buttons.element(boundBy: alert.buttons.count - 1).tap()
        }
    }

    private func dismissClipboardPromptIfPresent(in app: XCUIApplication) {
        let dismiss = app.buttons["忽略"]
        if dismiss.waitForExistence(timeout: 2) {
            dismiss.tap()
        }
    }

    private func waitForVisibleYouTubeParagraph(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let query = app.descendants(matching: .any).matching(
            NSPredicate(
                format: "identifier BEGINSWITH %@",
                "youtubeTranscriptParagraph_"
            )
        )
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for element in query.allElementsBoundByIndex
                where element.exists && element.isHittable {
                let renderedText = [
                    element.label,
                    element.value as? String ?? "",
                ].joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !renderedText.isEmpty { return element }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }

    /// Opt-in because it reaches the real public YouTube page. It validates
    /// the short-lived extraction WebView, native transcript handoff and the
    /// second-open cache path without making ordinary CI depend on the network.
    ///
    /// Drive the sample through the app's discovery surface. Recent simulator
    /// runtimes force-relaunch an already controlled app after
    /// `XCUIApplication.open(_:)`; that replacement debug launch drops the URL.
    /// Deep-link parsing and routing remain covered by deterministic tests.
    func testYouTubePublicTranscriptLiveExtractionAndCacheReopen() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CASTREADER_RUN_LIVE_YOUTUBE_TESTS"] == "1",
            "Set CASTREADER_RUN_LIVE_YOUTUBE_TESTS=1 for the live acceptance probe."
        )
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
        ]

        app.launch()
        dismissSelfOpenSystemAlertIfPresent()
        app.activate()
        openYouTubePublicSample(in: app)

        guard let visibleParagraph = waitForVisibleYouTubeParagraph(
            in: app,
            timeout: 50
        ) else {
            XCTFail("Public sample did not reach a visible native transcript paragraph")
            return
        }
        XCTAssertTrue(visibleParagraph.isHittable)
        let renderedParagraphText = [
            visibleParagraph.label,
            visibleParagraph.value as? String ?? "",
        ].joined(separator: " ")
        XCTAssertNil(
            renderedParagraphText.range(
                of: #"^\d{1,2}:\d{2}\d+\s+(?:second|minute)"#,
                options: [.regularExpression, .caseInsensitive]
            ),
            "YouTube accessibility timing text leaked into the rendered caption"
        )
        XCTAssertFalse(
            app.webViews.firstMatch.exists,
            "The extraction WebView must be destroyed before showing the transcript"
        )
        let playPause = app.buttons["readPlayPauseButton"]
        XCTAssertTrue(
            playPause.waitForExistence(timeout: 5),
            "The native reader controls did not appear after extraction"
        )
        let audiblePlayback = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value ==[c] 'playing'"),
            object: playPause
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [audiblePlayback], timeout: 20),
            .completed,
            "The public sample never reached real CastReader TTS playback"
        )
        let cacheBadge = app.descendants(matching: .any)[
            "youtubeOfflineCacheBadge"
        ]
        XCTAssertTrue(cacheBadge.waitForExistence(timeout: 5))
        let completeArtwork = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == 'artwork complete'"),
            object: cacheBadge
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [completeArtwork], timeout: 20),
            .completed,
            "The public sample did not persist every required artwork resource"
        )
        let firstScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        firstScreenshot.name = "YouTube live transcript, TTS and artwork"
        firstScreenshot.lifetime = .keepAlways
        add(firstScreenshot)

        app.terminate()
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()
        app.activate()
        let cacheStartedAt = Date()
        openYouTubePublicSample(in: app)
        guard let reopenedParagraph = waitForVisibleYouTubeParagraph(
            in: app,
            timeout: 5
        ) else {
            XCTFail("Cached transcript did not reopen to a visible native paragraph")
            return
        }
        XCTAssertTrue(reopenedParagraph.isHittable)
        XCTAssertLessThan(
            Date().timeIntervalSince(cacheStartedAt),
            5,
            "Cached transcript reopen exceeded the acceptance window"
        )
        let reopenedCacheBadge = app.descendants(matching: .any)[
            "youtubeOfflineCacheBadge"
        ]
        XCTAssertTrue(reopenedCacheBadge.waitForExistence(timeout: 5))
        XCTAssertEqual(
            reopenedCacheBadge.value as? String,
            "artwork complete",
            "Cached reopen lost persisted storyboard coverage"
        )
        let cachedScreenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        cachedScreenshot.name = "YouTube cached transcript reopen"
        cachedScreenshot.lifetime = .keepAlways
        add(cachedScreenshot)
    }

    /// Regression probe for a real page that YouTube currently places behind
    /// bot verification. Success is acceptable if YouTube later permits the
    /// transcript again; an explicit temporary access limitation is also
    /// truthful. Neither the old false timeout nor a false sign-in claim may
    /// return.
    func testYouTubeReportedURLNeverMisreportsVerificationAsTimeout() throws {
        #if !CASTREADER_LIVE_YOUTUBE_CLASSIFICATION
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment[
                "CASTREADER_RUN_LIVE_YOUTUBE_CLASSIFICATION_TESTS"
            ] == "1",
            "Set CASTREADER_RUN_LIVE_YOUTUBE_CLASSIFICATION_TESTS=1 for this probe."
        )
        #endif
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-interfaceLanguage", "zh-Hans",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()
        app.activate()
        dismissClipboardPromptIfPresent(in: app)

        let entry = app.buttons["youtubeHomeEntryCard"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        let field = app.textFields["youtubeURLField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(
            "https://m.youtube.com/watch?v=wpb-DrbhEiY&pp=iggCQAE%3D&ra=m"
        )
        let listen = app.buttons["youtubePasteListenButton"]
        XCTAssertTrue(listen.waitForExistence(timeout: 5))
        listen.tap()

        let accessLimited = app.staticTexts[
            "YouTube 暂时限制了字幕访问，视频本身可能仍可正常观看；请稍后重试或在 YouTube 中打开"
        ]
        let misleadingSignIn = app.staticTexts["该视频需要登录 YouTube 查看，无法解析"]
        let falseTimeout = app.staticTexts["解析超时，请重试"]
        var paragraph: XCUIElement?
        let deadline = Date().addingTimeInterval(50)
        repeat {
            paragraph = waitForVisibleYouTubeParagraph(in: app, timeout: 0.05)
            if paragraph != nil || accessLimited.exists
                || misleadingSignIn.exists || falseTimeout.exists { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline

        XCTAssertFalse(falseTimeout.exists, "bot verification regressed to a false timeout")
        XCTAssertFalse(
            misleadingSignIn.exists,
            "bot verification regressed to a false YouTube sign-in requirement"
        )
        XCTAssertTrue(
            paragraph != nil || accessLimited.exists,
            "the exact URL reached neither a transcript nor the truthful access-limited state"
        )
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "YouTube reported URL terminal state"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func openYouTubePublicSample(in app: XCUIApplication) {
        let entry = app.buttons["youtubeHomeEntryCard"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()

        if let liveURL = ProcessInfo.processInfo.environment[
            "CASTREADER_YOUTUBE_LIVE_URL"
        ], !liveURL.isEmpty {
            let field = app.textFields["youtubeURLField"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(liveURL)
            let listen = app.buttons["youtubePasteListenButton"]
            XCTAssertTrue(listen.waitForExistence(timeout: 5))
            listen.tap()
            return
        }

        let sample = app.buttons["youtubeSampleButton"]
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
    }

    /// 28 个目标语言包都必须能独立启动，并显示各自的首页标签。
    func testLaunchesInAllTwentyEightSupportedLanguages() {
        let configurations: [(language: String, locale: String, home: String)] = [
            ("en", "en_US", "Home"),
            ("zh-Hans", "zh_CN", "首页"),
            ("ja", "ja_JP", "ホーム"),
            ("es", "es_ES", "Inicio"),
            ("fr", "fr_FR", "Accueil"),
            ("de", "de_DE", "Start"),
            ("pt-BR", "pt_BR", "Início"),
            ("it", "it_IT", "Home"),
            ("hi", "hi_IN", "होम"),
            ("nl", "nl_NL", "Start"), ("ko", "ko_KR", "홈"),
            ("ar", "ar_SA", "الرئيسية"), ("ru", "ru_RU", "Главная"),
            ("pl", "pl_PL", "Strona główna"), ("sv", "sv_SE", "Hem"),
            ("da", "da_DK", "Hjem"), ("nb", "nb_NO", "Hjem"),
            ("fi", "fi_FI", "Koti"), ("cs", "cs_CZ", "Domů"),
            ("el", "el_GR", "Αρχική"), ("hu", "hu_HU", "Kezdőlap"),
            ("fil", "fil_PH", "Home"), ("he", "he_IL", "בית"),
            ("id", "id_ID", "Beranda"), ("ms", "ms_MY", "Laman Utama"),
            ("ro", "ro_RO", "Acasă"), ("tr", "tr_TR", "Ana Sayfa"),
            ("vi", "vi_VN", "Trang chủ")
        ]

        for configuration in configurations {
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(\(configuration.language))",
                "-AppleLocale", configuration.locale,
                "-interfaceLanguage", "system",
                "-CastReaderSkipLibraryOnboarding",
                "-CastReaderSkipSignInGate",
            ]
            app.launch()
            dismissSelfOpenSystemAlertIfPresent()
            XCTAssertTrue(
                mainNavigationItem(in: app, title: configuration.home, symbol: "house.fill").waitForExistence(timeout: 5),
                "Missing localized Home tab for \(configuration.language)"
            )
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "28-language-home-\(configuration.language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            app.terminate()
        }
    }

    /// 新增书架来源流程必须在九种语言与明暗两种外观下都能进入，
    /// 并完整呈现五个平台。使用稳定的 accessibility id，不依赖翻译文本。
    func testShelfSourcesInAllLanguagesAndAppearances() {
        let configurations: [(language: String, locale: String)] = [
            ("en", "en_US"),
            ("zh-Hans", "zh_CN"),
            ("ja", "ja_JP"),
            ("es", "es_ES"),
            ("fr", "fr_FR"),
            ("de", "de_DE"),
            ("pt-BR", "pt_BR"),
            ("it", "it_IT"),
            ("hi", "hi_IN"),
        ]

        for appearance in ["Light", "Dark"] {
            for configuration in configurations {
                let app = XCUIApplication()
                app.launchArguments = [
                    "-AppleLanguages", "(\(configuration.language))",
                    "-AppleLocale", configuration.locale,
                    "-interfaceLanguage", "system",
                    "-AppleInterfaceStyle", appearance,
                    "-CastReaderSkipLibraryOnboarding",
                    "-CastReaderSkipSignInGate",
                ]
                app.launch()

                let sources = app.buttons["homeShelfSourcesButton"]
                XCTAssertTrue(
                    sources.waitForExistence(timeout: 5),
                    "Missing shelf-source entry for \(configuration.language), \(appearance)"
                )
                sources.tap()
                XCTAssertTrue(
                    app.descendants(matching: .any)["shelfSourcesScreen"]
                        .waitForExistence(timeout: 5),
                    "Shelf-source screen failed for \(configuration.language), \(appearance)"
                )
                for source in ["kindle", "weread", "google_books", "kobo", "oreilly"] {
                    XCTAssertTrue(
                        app.buttons["shelfSourcePrimaryAction.\(source)"]
                            .waitForExistence(timeout: 2),
                        "Missing \(source) for \(configuration.language), \(appearance)"
                    )
                }
                app.terminate()
            }
        }
    }

    /// 首启流程必须跟随系统外观，不能为维持旧稿效果而强制浅色。
    func testFirstLaunchFollowsSystemAppearance() {
        let expectedAppearance = UITraitCollection.current.userInterfaceStyle == .dark
            ? "dark"
            : "light"
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-CastReaderResetLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            // 固定为全球版：否则开发机时区在中国大陆时，首启会被路由到
            // 微信读书引导，这些 Kindle 断言会全部落空。
            "-CastReaderRegion", "global",
            "-CastReaderForceLibraryOnboardingRebind",
            "-boundLibraryOnboarding.v1.isActivated", "NO",
            "-boundLibraryOnboarding.v1.hasSeenChooser", "NO",
            "-boundLibraryOnboarding.v3.phase", "sample",
            "-boundLibraryOnboarding.v3.resumePhase", "sample",
            "-boundLibraryOnboarding.v3.hasCompletedSample", "NO",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let onboarding = app.descendants(matching: .any)["boundLibraryOnboarding"]
        XCTAssertTrue(
            onboarding.waitForExistence(timeout: 6),
            "First-launch onboarding did not appear in \(expectedAppearance) mode"
        )
        XCTAssertEqual(
            onboarding.value as? String,
            expectedAppearance,
            "First-launch onboarding must inherit the system appearance"
        )
    }

    func testFirstLaunchShowsBoundLibraryOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderResetLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            // 固定为全球版：否则开发机时区在中国大陆时，首启会被路由到
            // 微信读书引导，这些 Kindle 断言会全部落空。
            "-CastReaderRegion", "global",
            "-CastReaderForceLibraryOnboardingRebind",
            // UserDefaults can survive a preceding UI-test process on the
            // shared simulator. Pin the argument domain to the value step so
            // this test verifies a real first launch instead of a restored
            // login/scan phase.
            "-boundLibraryOnboarding.v1.isActivated", "NO",
            "-boundLibraryOnboarding.v1.hasSeenChooser", "NO",
            "-boundLibraryOnboarding.v3.phase", "sample",
            "-boundLibraryOnboarding.v3.resumePhase", "sample",
            "-boundLibraryOnboarding.v3.hasCompletedSample", "NO",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let connect = app.buttons["kindleOnboarding.sample.start"]
        XCTAssertTrue(
            connect.waitForExistence(timeout: 6),
            "首启必须稳定落在价值页，不能恢复到上一次 UI 测试的登录或扫描阶段"
        )
        let sampleTitle = app.staticTexts["kindleOnboarding.sample.title"]
        XCTAssertTrue(
            sampleTitle.waitForExistence(timeout: 2),
            "首启价值页必须直接说明 Kindle 书可变成有声书"
        )
        XCTAssertEqual(sampleTitle.label, "把你的 Kindle 书变成有声书")
        XCTAssertLessThan(
            sampleTitle.frame.height,
            connect.frame.height,
            "首启标题必须缩放为单行，不能挤压中部插画与底部操作"
        )
        XCTAssertFalse(
            app.staticTexts["0 · 价值页"].exists,
            "首屏顶部不应出现内部步骤名或价值页标签"
        )
        let noKindle = app.buttons["kindleOnboarding.sample.skip"]
        XCTAssertTrue(connect.exists, "价值页缺少连接 Kindle 主 CTA")
        XCTAssertTrue(noKindle.exists, "价值页缺少没有 Kindle 的次 CTA")
        XCTAssertGreaterThan(
            noKindle.frame.maxY,
            app.frame.height * 0.82,
            "价值页按钮组必须贴近页面底部"
        )

        connect.tap()

        let storefront = app.buttons["kindleOnboarding.storefront.continue"]
        let firstListen = app.buttons["kindleOnboarding.firstListen.start"]
        XCTAssertTrue(
            waitForEither(
                storefront,
                firstListen,
                timeout: 6
            ),
            "连接 Kindle 后必须进入选站；已绑定用户可以直接进入首听"
        )

        if firstListen.exists {
            XCTAssertTrue(
                app.buttons["kindleOnboarding.firstListen.start"].exists,
                "已绑定用户直接进入首听时必须保留一键开始入口"
            )
            let connectionStatus = app.descendants(matching: .any)[
                "kindleOnboarding.firstListen.connectionStatus"
            ]
            XCTAssertTrue(
                connectionStatus.waitForExistence(timeout: 2),
                "首听页必须明确显示 Kindle 已连接"
            )
            XCTAssertEqual(connectionStatus.value as? String, "success")
            XCTAssertFalse(
                app.buttons["kindleOnboarding.firstListen.changeBook"].exists,
                "书籍候选已直接平铺，不应再出现旧的换书入口"
            )
            return
        }

        let storefrontTitle = app.staticTexts["你在哪个亚马逊买书？"]
        XCTAssertTrue(
            storefrontTitle.exists,
            "选站页标题必须把唯一决策说清楚"
        )
        XCTAssertLessThan(
            storefrontTitle.frame.height,
            56,
            "常规中文标题应根据可用宽度缩放为单行，而不是被固定窄宽提前换行"
        )
        XCTAssertTrue(app.buttons["kindleOnboarding.storefront.continue"].exists)
        let postpone = app.buttons["kindleOnboarding.storefront.postpone"]
        XCTAssertTrue(postpone.exists)
        XCTAssertGreaterThan(
            postpone.frame.maxY,
            app.frame.height * 0.82,
            "选站页按钮组必须贴近页面底部"
        )

        let expectedStorefrontIDs = [
            "us", "uk", "ca", "au", "jp", "de", "fr",
            "it", "es", "in", "br", "mx", "nl",
        ]
        for storefrontID in expectedStorefrontIDs {
            XCTAssertTrue(
                app.buttons[
                    "kindleOnboarding.storefront.option.\(storefrontID)"
                ].exists,
                "选站页必须完整提供可用 Kindle 站点：\(storefrontID)"
            )
        }
        XCTAssertFalse(
            app.buttons["kindleOnboarding.storefront.option.cn"].exists,
            "已关闭的 Amazon.cn 仅用于历史链接识别，不能作为登录目的地"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Kindle onboarding storefront"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }


    /// 轮询等待某个元素的 accessibilityValue 变成期望值。
    /// SwiftUI 重绘后 value 的更新会晚一两帧，直接断言会偶发失败。
    private func expect(
        _ element: XCUIElement,
        toHaveValue expected: String,
        _ message: String,
        timeout: TimeInterval = 5
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (element.value as? String) == expected { return }
            usleep(200_000)
        }
        XCTFail("\(message)（实际：\(String(describing: element.value))）")
    }

    /// 产品发行区域与账号域必须原子绑定。切换只写给下次启动，当前进程保持
    /// 原账号域，避免一次会话中途混用登录、支付与本地数据命名空间。
    func testInternalRegionSwitcherIsReachableAndSwitchesRegion() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderResetServiceRouteState",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        // 齿轮只在「音色」Tab 的工具栏上。
        app.tabBars.buttons["音色"].tap()
        XCTAssertTrue(app.buttons["settingsGearButton"].waitForExistence(timeout: 6))
        app.buttons["settingsGearButton"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 6))

        let chinaOption = app.buttons["中国大陆（CHN）"]
        for _ in 0..<12 where !chinaOption.exists {
            app.swipeUp()
        }
        XCTAssertTrue(
            chinaOption.waitForExistence(timeout: 4),
            "设置里必须能找到内部区域开关的「中国大陆」选项"
        )

        chinaOption.tap()

        // 切换后当前生效区域要立刻反映出来。
        let effective = app.descendants(matching: .any)["settingsRegionEffective"]
        // Form rows are virtualized. Selecting the last inline picker option
        // can leave the status row just below the rendered viewport.
        for _ in 0..<6 where !effective.exists {
            app.swipeUp()
        }
        // On compact devices the inline picker can virtualize the status row
        // above the viewport after several fast upward swipes. Search back
        // toward the picker before declaring the internal control missing.
        for _ in 0..<8 where !effective.exists {
            app.swipeDown()
        }
        XCTAssertTrue(effective.waitForExistence(timeout: 4))
        expect(effective, toHaveValue: "cn", "切到 CHN 后当前生效区域应为 cn")

        let currentRoute = app.descendants(matching: .any)["settingsServiceRouteEffective"]
        let nextRoute = app.descendants(matching: .any)["settingsServiceRouteNextLaunch"]
        for _ in 0..<8 where !currentRoute.exists || !nextRoute.exists {
            app.swipeUp()
        }
        XCTAssertTrue(currentRoute.exists)
        XCTAssertTrue(nextRoute.exists)
        expect(currentRoute, toHaveValue: "global", "当前进程必须保持原账号域")
        expect(nextRoute, toHaveValue: "cn", "选择中国产品区必须同步中国账号域")

        // 必须能切回来——否则测试机会被锁死在中国区。
        let globalOption = app.buttons["全球（Global）"]
        for _ in 0..<6 where !globalOption.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(globalOption.isHittable, "必须保留切回全球的入口")
        globalOption.tap()
        for _ in 0..<6 where !effective.exists {
            app.swipeUp()
        }
        for _ in 0..<8 where !effective.exists {
            app.swipeDown()
        }
        expect(effective, toHaveValue: "global", "切回后当前生效区域应为 global")
        for _ in 0..<6 where !nextRoute.exists {
            app.swipeUp()
        }
        expect(nextRoute, toHaveValue: "global", "切回全球产品区必须同步全球账号域")
    }

    /// 产品区域与服务线路只放在设置页，登录页不重复暴露内部测试控件。
    func testRootLoginDoesNotExposeDistributionSettings() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderResetServiceRouteState",
            "-CastReaderRegion", "global",
            "-auth_account_v1", "RESET",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        XCTAssertFalse(app.buttons["login.phone"].exists, "global 产品体验不应显示手机号入口")
        XCTAssertFalse(app.descendants(matching: .any)["loginRegionOverride"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["loginServiceRouteOverride"].exists)
        XCTAssertTrue(app.buttons["login.apple"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["login.email"].exists)
    }

    /// Guideline 4: Apple must be a full, visible alternative to the other
    /// primary provider, including the review device's landscape layout.
    func testAppleLoginHasEquivalentProminence() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for (region, language, locale) in [
            ("global", "en", "en_US"),
            ("global", "de", "de_DE"),
            ("cn", "zh-Hans", "zh_CN"),
        ] {
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(\(language))", "-AppleLocale", locale,
                "-CastReaderRegion", region, "-CastReaderServiceRoute", region,
                "-CastReaderDisableDebugPro",
                "-auth_account_v1", "RESET", "-auth_account_v1.cn", "RESET",
            ]
            XCUIDevice.shared.orientation = .portrait
            app.launch()
            dismissSelfOpenSystemAlertIfPresent()
            let apple = app.buttons["login.apple"]
            let other = app.buttons[region == "cn" ? "login.phone" : "login.google"]
            XCTAssertTrue(apple.waitForExistence(timeout: 6))
            XCTAssertTrue(other.exists)

            let orientations: [UIDeviceOrientation] = UIDevice.current.userInterfaceIdiom == .pad
                ? [.portrait, .landscapeLeft] : [.portrait]
            for orientation in orientations {
                XCUIDevice.shared.orientation = orientation
                // UIKit's native button and the SwiftUI row can publish their
                // accessibility frames at different points during rotation.
                let settled = XCTNSPredicateExpectation(
                    predicate: NSPredicate { _, _ in
                        let window = app.windows.firstMatch.frame
                        let orientationMatches = orientation == .portrait
                            ? window.height > window.width : window.width > window.height
                        return orientationMatches && apple.frame.width > 200
                    },
                    object: nil
                )
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
                XCTAssertTrue(apple.isHittable, "Apple login must be visible without scrolling")
                XCTAssertTrue(other.isHittable)
                XCTAssertGreaterThan(apple.frame.width, 200)
                XCTAssertEqual(apple.frame.width, other.frame.width, accuracy: 1)
                XCTAssertEqual(apple.frame.height, other.frame.height, accuracy: 1)
                XCTAssertGreaterThanOrEqual(apple.frame.height, 50)
                XCTAssertLessThan(apple.frame.maxY, other.frame.minY)
                XCTAssertTrue(apple.label.localizedCaseInsensitiveContains("Apple"))
                let window = app.windows.firstMatch.frame
                XCTAssertTrue(window.contains(apple.frame))
                XCTAssertTrue(window.contains(other.frame))
                let picture = XCTAttachment(screenshot: app.screenshot())
                picture.name = "login-parity-\(region)-\(language)-\(orientation.rawValue)"
                picture.lifetime = .keepAlways
                add(picture)
            }

            if region == "cn" {
                // The native button must still route through the consent gate.
                // Decline so this layout test never starts account authorization.
                apple.tap()
                let consent = app.alerts["服务条款与隐私政策"]
                XCTAssertTrue(consent.waitForExistence(timeout: 3))
                consent.buttons["不同意"].tap()
                XCTAssertTrue(apple.isHittable)
            }
            app.terminate()
        }
    }

    /// 中国区首启走微信读书强绑定：四屏，没有站点确认屏，
    /// 也不应出现任何 Kindle / Google 图书 / Kobo / O'Reilly 的痕迹。
    func testFirstLaunchInChinaShowsWeReadOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderResetLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderRegion", "cn",
            "-boundLibraryOnboarding.v1.isActivated", "NO",
            "-boundLibraryOnboarding.v1.hasSeenChooser", "NO",
            "-boundLibraryOnboarding.v3.phase", "sample",
            "-boundLibraryOnboarding.v3.resumePhase", "sample",
            "-boundLibraryOnboarding.v3.hasCompletedSample", "NO",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let connect = app.buttons["wereadOnboarding.sample.start"]
        XCTAssertTrue(
            connect.waitForExistence(timeout: 6),
            "中国区首启必须落在微信读书价值页"
        )

        let sampleTitle = app.staticTexts["wereadOnboarding.sample.title"]
        XCTAssertTrue(sampleTitle.waitForExistence(timeout: 2))
        XCTAssertEqual(sampleTitle.label, "把你的微信读书变成有声书")

        XCTAssertTrue(
            app.buttons["wereadOnboarding.sample.skip"].exists,
            "价值页必须保留「我没有微信读书」的退路"
        )
        XCTAssertFalse(
            app.buttons["kindleOnboarding.sample.start"].exists,
            "中国区不得出现 Kindle 引导入口"
        )

        connect.tap()

        // 微信读书是单站点：价值页之后直接进登录，不经过站点确认屏。
        // 用「稍后」按钮判定：按钮一定会被曝光为可查询元素，容器上的
        // accessibilityIdentifier 在 SwiftUI 里未必稳定可见。
        let loginPostpone = app.buttons["wereadOnboarding.login.postpone"]
        if !loginPostpone.waitForExistence(timeout: 10) {
            XCTFail(
                "中国区必须从价值页直接进入微信登录，不应出现站点选择。当前元素树：\n"
                    + app.debugDescription
            )
        }
        XCTAssertFalse(
            app.buttons["kindleOnboarding.storefront.continue"].exists,
            "微信读书没有站点确认屏"
        )
        XCTAssertTrue(
            app.staticTexts["wereadOnboarding.login.qrGuidance"].exists,
            "登录页必须给出长按识别二维码的操作指引"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "WeRead onboarding login"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Regression for upgrades/switches where this device already completed
    /// the old global Kindle activation. The real CN login boundary must load
    /// a fresh account-scoped WeRead flow instead of inheriting that state.
    func testChinaPhoneFirstLoginIgnoresLegacyActivatedKindleOnboarding() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderRegion", "cn",
            "-CastReaderServiceRoute", "cn",
            "-CastReaderPhoneAuthLocalFallback",
            "-CastReaderDisableDebugPro",
            "-auth_account_v1.cn", "RESET",
            "-boundLibraryOnboarding.v1.selectedSource", "kindle",
            "-boundLibraryOnboarding.v1.hasSeenChooser", "YES",
            "-boundLibraryOnboarding.v1.isActivated", "YES",
            "-boundLibraryOnboarding.v1.activationPlaybackSeconds", "30",
            "-boundLibraryOnboarding.v3.phase", "activated",
            "-boundLibraryOnboarding.v3.resumePhase", "firstListen",
            "-boundLibraryOnboarding.v3.hasCompletedSample", "YES",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        openAcceptedPhoneSignIn(app)
        let phoneField = app.textFields["phoneSignIn.phoneField"]
        let codeField = app.textFields["phoneSignIn.codeField"]
        let resend = app.buttons["phoneSignIn.resend"]
        let primary = app.buttons["phoneSignIn.primary"]
        XCTAssertTrue(phoneField.waitForExistence(timeout: 6))

        // A unique local fallback identity keeps repeated UI-test runs
        // independent without deleting any real/simulator account data.
        let randomPrefix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        let suffix = (UInt32(randomPrefix, radix: 16) ?? 0) % 100_000_000
        let phone = String(format: "138%08u", suffix)
        phoneField.tap()
        phoneField.typeText(phone)
        XCTAssertTrue(resend.isEnabled)
        resend.tap()
        codeField.tap()
        codeField.typeText("888888")
        XCTAssertTrue(primary.isEnabled)
        primary.tap()

        let weReadStart = app.buttons["wereadOnboarding.sample.start"]
        XCTAssertTrue(
            weReadStart.waitForExistence(timeout: 20),
            "中国区新账号登录后必须显示微信读书绑定引导，不能继承旧 Kindle 激活状态"
        )
        XCTAssertEqual(
            app.staticTexts["wereadOnboarding.sample.title"].label,
            "把你的微信读书变成有声书"
        )
        XCTAssertFalse(app.buttons["kindleOnboarding.sample.start"].exists)
    }

    /// 中国区手机号登录：后端未接通时用预设码也要能走完并真正登录成功。
    func testChinaPhoneSignInCompletesWithPresetCode() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderRegion", "cn",
            "-CastReaderServiceRoute", "cn",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderPhoneAuthLocalFallback",
            "-CastReaderDisableDebugPro",
            "-auth_account_v1.cn", "RESET",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let phoneEntry = app.buttons["login.phone"]
        XCTAssertTrue(phoneEntry.waitForExistence(timeout: 6), "中国区必须提供手机号登录入口")
        XCTAssertFalse(
            app.buttons["使用 Google 继续"].exists,
            "中国区不得展示不可用的 Google 登录入口"
        )
        XCTAssertTrue(app.buttons["login.apple"].exists, "中国区必须保留完整 Apple 登录按钮")
        XCTAssertFalse(app.buttons["login.email"].exists, "中国区不应展示尚未接通的邮箱登录")

        signInWithPresetPhoneCode(app)

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "CN phone sign-in completed"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// A resend failure must not remove or lock the verification form. This
    /// mirrors the production case where Tencent already delivered the SMS but
    /// the client saw a timeout/limit error and still needs to submit that code.
    func testChinaPhoneSignInAcceptsExistingCodeAfterSendFailure() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderRegion", "cn",
            "-CastReaderServiceRoute", "cn",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderPhoneAuthLocalFallback",
            "-CastReaderPhoneAuthForceSendFailure",
            "-CastReaderDisableDebugPro",
            "-auth_account_v1.cn", "RESET",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        openAcceptedPhoneSignIn(app)

        let phoneField = app.textFields["phoneSignIn.phoneField"]
        let codeField = app.textFields["phoneSignIn.codeField"]
        let send = app.buttons["phoneSignIn.resend"]
        let login = app.buttons["phoneSignIn.primary"]

        XCTAssertTrue(phoneField.waitForExistence(timeout: 6))
        XCTAssertTrue(codeField.exists, "验证码输入框必须从页面初始状态就存在")
        XCTAssertEqual(send.label, "获取验证码")
        XCTAssertEqual(login.label, "登录")
        XCTAssertFalse(login.isEnabled)

        phoneField.tap()
        phoneField.typeText("13800138000")
        XCTAssertTrue(send.isEnabled)
        XCTAssertFalse(login.isEnabled, "只有手机号、没有 6 位验证码时不得提交")

        send.tap()
        let error = app.staticTexts["phoneSignIn.error"]
        XCTAssertTrue(error.waitForExistence(timeout: 6), "发码失败应给出错误提示")
        XCTAssertTrue(codeField.exists, "发码失败后验证码输入框不能消失")

        codeField.tap()
        codeField.typeText("888888")
        XCTAssertTrue(login.isEnabled, "已有合法验证码时，发码失败不能锁死登录")
        login.tap()

        XCTAssertTrue(
            app.buttons["settingsGearButton"].waitForExistence(timeout: 20),
            "已有验证码必须能继续完成登录"
        )
    }

    /// 手机号是中国产品能力，不由网络线路决定。即便服务仍走 global，
    /// 中国产品登录页也必须隐藏 Google 与邮箱，只保留手机号和 Apple。
    func testChinaProductOnGlobalRouteKeepsSupportedLoginChannels() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderRegion", "cn",
            "-CastReaderServiceRoute", "global",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderPhoneAuthLocalFallback",
            "-CastReaderDisableDebugPro",
            "-auth_account_v1", "RESET",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        XCTAssertTrue(
            app.buttons["login.phone"].waitForExistence(timeout: 6),
            "中国产品在 global 网关也必须提供手机号入口"
        )
        XCTAssertFalse(
            app.buttons["使用 Google 继续"].exists,
            "中国区不能因为服务暂走 global 就重新显示 Google"
        )
        XCTAssertTrue(
            app.buttons["login.apple"].exists,
            "中国区必须保留 Apple 登录"
        )
        XCTAssertFalse(app.buttons["login.email"].exists, "中国区不应因服务暂走 global 就显示邮箱登录")

        signInWithPresetPhoneCode(app)
    }

    /// 中国区手机号账号必须能进入付费流程。
    ///
    /// 回归点：购买门禁原本要求账号有邮箱，而手机号账号没有邮箱——
    /// 那会让中国区所有用户的付费按钮点不动。
    func testChinaPhoneAccountCanReachPurchase() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderRegion", "cn",
            "-CastReaderServiceRoute", "cn",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderPhoneAuthLocalFallback",
            "-CastReaderDisableDebugPro",
            "-auth_account_v1.cn", "RESET",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        signInWithPresetPhoneCode(app)

        // 登录后进入升级页，付费按钮必须可用（不再被邮箱门禁挡住）。
        let upgrade = app.buttons["settingsProLink"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 10), "手机号账号必须能看到升级入口")
        upgrade.tap()

        let purchase = app.buttons["paywallPurchaseButton"]
        XCTAssertTrue(purchase.waitForExistence(timeout: 15), "StoreKit 商品必须加载并展示购买按钮")
        XCTAssertTrue(
            purchase.isEnabled,
            "手机号账号必须能点付费按钮——邮箱门禁会挡住整个中国区"
        )

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "CN paywall with phone account"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// 用预设验证码完成中国区手机号登录，停在设置页。
    private func signInWithPresetPhoneCode(_ app: XCUIApplication) {
        openAcceptedPhoneSignIn(app)

        let phoneField = app.textFields["phoneSignIn.phoneField"]
        let codeField = app.textFields["phoneSignIn.codeField"]
        let resend = app.buttons["phoneSignIn.resend"]
        let primary = app.buttons["phoneSignIn.primary"]
        XCTAssertTrue(phoneField.waitForExistence(timeout: 6))
        XCTAssertTrue(codeField.exists, "验证码框必须不依赖发码成功才显示")
        XCTAssertEqual(resend.label, "获取验证码")
        XCTAssertEqual(primary.label, "登录")
        XCTAssertFalse(primary.isEnabled)

        phoneField.tap()
        phoneField.typeText("13800138000")

        XCTAssertTrue(resend.isEnabled, "合法手机号应允许获取验证码")
        XCTAssertFalse(primary.isEnabled, "登录按钮必须等待完整验证码")
        resend.tap()

        XCTAssertTrue(codeField.exists)
        codeField.tap()
        codeField.typeText("888888")
        XCTAssertTrue(primary.isEnabled)
        primary.tap()

        // Home and Voice intentionally share this accessibility identifier, and
        // SwiftUI may retain both tab hierarchies. Select Voice explicitly so the
        // query resolves to a stable, visible toolbar target after login.
        let voiceTab = app.tabBars.buttons["音色"]
        XCTAssertTrue(voiceTab.waitForExistence(timeout: 20), "手机号登录后必须进入主界面")
        voiceTab.tap()

        let settings = app.buttons["settingsGearButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 6), "音色页必须提供设置入口")
        settings.tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 6))
        XCTAssertTrue(
            app.buttons["退出登录"].waitForExistence(timeout: 20),
            "预设验证码必须能完成登录"
        )
    }

    /// Enter the phone sheet through the real China consent continuation.
    private func openAcceptedPhoneSignIn(_ app: XCUIApplication) {
        let phoneEntry = app.buttons["login.phone"]
        XCTAssertTrue(phoneEntry.waitForExistence(timeout: 6))

        let consent = app.buttons["login.chinaConsent"]
        XCTAssertTrue(consent.exists, "中国区登录页必须展示协议勾选框")
        expect(consent, toHaveValue: "unchecked", "协议必须默认不勾选")

        phoneEntry.tap()
        XCTAssertTrue(
            app.alerts["服务条款与隐私政策"].waitForExistence(timeout: 4),
            "未勾选协议点击登录方式必须弹出确认框"
        )
        app.alerts["服务条款与隐私政策"].buttons["同意"].tap()
    }

    func testOnboardingCanBeDeferredWithoutAContentDecision() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-interfaceLanguage", "system",
            "-CastReaderResetLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-boundLibraryOnboarding.v1.isActivated", "NO",
            "-boundLibraryOnboarding.v1.hasSeenChooser", "NO",
            "-boundLibraryOnboarding.v3.phase", "sample",
            "-boundLibraryOnboarding.v3.resumePhase", "sample",
            "-boundLibraryOnboarding.v3.hasCompletedSample", "NO",
            // 固定为全球版：否则开发机时区在中国大陆时，首启会被路由到
            // 微信读书引导，这些 Kindle 断言会全部落空。
            "-CastReaderRegion", "global",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let skip = app.buttons["kindleOnboarding.sample.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 5))
        skip.tap()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 6))
    }

    func testOnboardingKindleStartsExistingBindingFlow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-interfaceLanguage", "system",
            "-CastReaderResetLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            // 固定为全球版：否则开发机时区在中国大陆时，首启会被路由到
            // 微信读书引导，这些 Kindle 断言会全部落空。
            "-CastReaderRegion", "global",
            "-CastReaderForceLibraryOnboardingRebind",
            "-boundLibraryOnboarding.v1.isActivated", "NO",
            "-boundLibraryOnboarding.v1.hasSeenChooser", "NO",
            "-boundLibraryOnboarding.v3.phase", "sample",
            "-boundLibraryOnboarding.v3.resumePhase", "sample",
            "-boundLibraryOnboarding.v3.hasCompletedSample", "NO",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let start = app.buttons["kindleOnboarding.sample.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()
        let connect = app.buttons["kindleOnboarding.storefront.continue"]
        XCTAssertTrue(connect.waitForExistence(timeout: 6))
        connect.tap()
        XCTAssertTrue(
            app.webViews.firstMatch.waitForExistence(timeout: 8),
            "连接站点后必须进入 Amazon 官方 Web 登录页"
        )
        let postpone = app.buttons["kindleOnboarding.login.postpone"]
        XCTAssertTrue(postpone.waitForExistence(timeout: 4))
        XCTAssertGreaterThan(
            postpone.frame.maxY,
            app.frame.height * 0.82,
            "登录页稍后入口必须贴近页面底部"
        )
    }

    func testOnboardingWeReadStartsExistingBindingFlow() {
        let app = launchZh()
        app.buttons["homeShelfSourcesButton"].tap()
        let weRead = app.buttons["shelfSourcePrimaryAction.weread"]
        XCTAssertTrue(weRead.waitForExistence(timeout: 5))
        weRead.tap()
        XCTAssertTrue(app.navigationBars["绑定微信读书"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8))
    }

    func testOnboardingGooglePlayBooksStartsExistingBindingFlow() {
        let app = launchZh()
        app.buttons["homeShelfSourcesButton"].tap()
        let googleBooks = app.buttons["shelfSourcePrimaryAction.google_books"]
        XCTAssertTrue(googleBooks.waitForExistence(timeout: 5))
        googleBooks.tap()
        XCTAssertTrue(app.navigationBars["绑定 Google Play 图书"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8))
        XCTAssertTrue(
            waitForEither(
                app.buttons["googleBooksSignInButton"],
                app.buttons["syncGoogleBooksLibraryButton"],
                timeout: 8
            ),
            "绑定页必须暴露登录或同步原生控制"
        )
    }

    /// A postponed first-use reminder must route from the always-mounted app
    /// root. This is the production path that 1.2.15 lost when the selected
    /// provider had no shelf rows and its conditional Home section was empty.
    func testDeferredGoogleReminderPresentsAfterOnboardingCoverDismissal() {
        UIPasteboard.general.items = []
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-boundLibraryOnboarding.v1.selectedSource", "google_books",
            "-boundLibraryOnboarding.v1.hasSeenChooser", "YES",
            "-boundLibraryOnboarding.v1.isActivated", "NO",
            "-boundLibraryOnboarding.v3.phase", "sample",
            "-boundLibraryOnboarding.v3.resumePhase", "sample",
            "-boundLibraryOnboarding.v3.hasCompletedSample", "NO",
            "-googlebooks.library.connected.v1", "NO",
            "-googlebooks.library.books.v1", "",
            "-CastReaderSkipSignInGate",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let postpone = app.buttons["kindleOnboarding.sample.skip"]
        XCTAssertTrue(postpone.waitForExistence(timeout: 8))
        postpone.tap()

        let continueButton = app.buttons["continueLibraryOnboarding"]
        XCTAssertTrue(continueButton.waitForExistence(timeout: 8))
        continueButton.tap()
        XCTAssertTrue(
            app.navigationBars["绑定 Google Play 图书"].waitForExistence(timeout: 10),
            "Google binding must wait for the onboarding full-screen cover to finish dismissing"
        )
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8))
    }

    func testDeferredLibraryReminderDirectlyRoutesEveryProvider() {
        let providers: [(source: String, title: String, booksKey: String, connectedKey: String)] = [
            ("google_books", "绑定 Google Play 图书", "googlebooks.library.books.v1", "googlebooks.library.connected.v1"),
            ("weread", "绑定微信读书", "weread.library.books.v1", "weread.library.connected.v1"),
            ("kobo", "绑定 Kobo", "kobo.library.books.v1", "kobo.library.connected.v1"),
            ("oreilly", "绑定 O’Reilly", "oreilly.library.books.v1", "oreilly.library.connected.v1"),
        ]

        for provider in providers {
            let app = XCUIApplication()
            app.launchArguments = [
                "-AppleLanguages", "(zh-Hans)",
                "-AppleLocale", "zh_CN",
                "-CastReaderSkipLibraryOnboarding",
                "-CastReaderSkipSignInGate",
                "-boundLibraryOnboarding.v1.selectedSource", provider.source,
                "-boundLibraryOnboarding.v1.hasSeenChooser", "YES",
                "-boundLibraryOnboarding.v1.isActivated", "NO",
                "-boundLibraryOnboarding.v3.phase", "postponed",
                "-boundLibraryOnboarding.v3.resumePhase", "firstListen",
                "-boundLibraryOnboarding.v3.hasCompletedSample", "YES",
                "-\(provider.connectedKey)", "NO",
                "-\(provider.booksKey)", "",
            ]
            app.launch()
            dismissSelfOpenSystemAlertIfPresent()

            let continueButton = app.buttons["continueLibraryOnboarding"]
            XCTAssertTrue(
                continueButton.waitForExistence(timeout: 8),
                "\(provider.source) should expose the deferred activation action"
            )
            continueButton.tap()
            XCTAssertTrue(
                app.navigationBars[provider.title].waitForExistence(timeout: 10),
                "\(provider.source) must present its binding flow directly from MainTab"
            )
            if provider.source == "google_books" {
                XCTAssertTrue(
                    app.webViews.firstMatch.waitForExistence(timeout: 8),
                    "Google Play Books binding must contain its real web login surface"
                )
            }
            app.terminate()
        }
    }

    /// Opt-in live-account gate. The test drives every native step and waits
    /// while a human completes Google's password/2FA/passkey UI in the shared
    /// WKWebView. It is deliberately skipped in ordinary CI:
    ///
    ///   CASTREADER_GOOGLE_BOOKS_LIVE_LOGIN=1 xcodebuild test ... \
    ///     -only-testing:CastReaderUITests/CastReaderUITests/testGoogleBooksLiveLoginAndSync
    func testGoogleBooksLiveLoginAndSync() throws {
        guard ProcessInfo.processInfo.environment["CASTREADER_GOOGLE_BOOKS_LIVE_LOGIN"] == "1" else {
            throw XCTSkip("Set CASTREADER_GOOGLE_BOOKS_LIVE_LOGIN=1 for the live Google account gate")
        }

        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderForceLibraryOnboardingRebind",
            "-CastReaderGoogleBooksLiveLoginGate",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()
        app.buttons["homeShelfSourcesButton"].tap()
        let googleBooks = app.buttons["shelfSourcePrimaryAction.google_books"]
        XCTAssertTrue(googleBooks.waitForExistence(timeout: 8))
        googleBooks.tap()
        let bindingTitle = app.navigationBars["绑定 Google Play 图书"]
        XCTAssertTrue(bindingTitle.waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))

        // The DEBUG hook opens the exact production sign-in URL immediately.
        // A human completes password/2FA/passkey in the real WKWebView. Once
        // the real shelf is complete, the app performs the same sync operation
        // as the native button and dismisses this sheet.
        XCTAssertTrue(
            waitForDisappearance(bindingTitle, timeout: 10 * 60),
            "Google login or library scan did not sync within ten minutes"
        )
        XCTAssertTrue(
            app.tabBars.buttons["首页"].waitForExistence(timeout: 15),
            "Google Books sync completed but the app did not return home"
        )
    }

    /// Opt-in, end-to-end Google Play Books reader gate. This test deliberately
    /// depends on the persistent account/shelf established by
    /// `testGoogleBooksLiveLoginAndSync`; it never injects a fake page or TTS
    /// response. Ordinary CI skips it:
    ///
    ///   CASTREADER_GOOGLE_BOOKS_LIVE_READER=1 xcodebuild test ... \
    ///     -only-testing:CastReaderUITests/CastReaderUITests/testGoogleBooksLiveReaderReadSwipeAndExplain
    func testGoogleBooksLiveReaderReadSwipeAndExplain() throws {
        guard ProcessInfo.processInfo.environment["CASTREADER_GOOGLE_BOOKS_LIVE_READER"] == "1" else {
            throw XCTSkip("Set CASTREADER_GOOGLE_BOOKS_LIVE_READER=1 for the live Google Books reader gate")
        }

        let volumeID = "b_40EQAAQBAJ"
        let exactReaderURL =
            "https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PP1.w.1.1.9_250"
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderGoogleBooksLiveTestURL", exactReaderURL,
        ]
        app.launch()

        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 15), "首页未就绪")
        guard let shelfEntry = googleBooksShelfEntry(in: app, volumeID: volumeID) else {
            XCTFail("已绑定的 Google Play 图书书架里没有指定验收书 \(volumeID)")
            return
        }
        shelfEntry.tap()

        let webView = app.webViews["googleBooksReaderWebView"]
        XCTAssertTrue(webView.waitForExistence(timeout: 45), "指定 Google Play 图书没有进入阅读器")
        XCTAssertTrue(
            app.segmentedControls["readerModePicker"].waitForExistence(timeout: 20),
            "阅读器缺少朗读/解读模式切换"
        )

        // Give the real cross-origin reader frame time to publish its first
        // stable rendered page before asking the cloud TTS pipeline to start.
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        let readButton = app.buttons["readPlayPauseButton"]
        XCTAssertTrue(readButton.waitForExistence(timeout: 20), "朗读控制没有出现")
        readButton.tap()
        XCTAssertTrue(
            waitForAccessibilityValue("playing", on: readButton, timeout: 150),
            "真实 Google Books 页面未能生成并播放朗读音频"
        )
        keepScreenshot(of: app, named: "GoogleBooks-01-read-playing")

        // A real touch gesture must suspend the old page immediately and then
        // restart on the newly committed page. Observing both states prevents a
        // no-op swipe or continuously playing stale queue from passing the gate.
        webView.swipeLeft()
        XCTAssertTrue(
            waitForAccessibilityValue("paused", on: readButton, timeout: 15),
            "手动滑页没有停止旧页朗读"
        )
        XCTAssertTrue(
            waitForAccessibilityValue("playing", on: readButton, timeout: 180),
            "手动滑页后没有在新页恢复朗读"
        )
        keepScreenshot(of: app, named: "GoogleBooks-02-manual-page-resumed")

        let modePicker = app.segmentedControls["readerModePicker"]
        let explainSegment = modePicker.buttons["解读"]
        XCTAssertTrue(explainSegment.waitForExistence(timeout: 10), "缺少解读模式")
        explainSegment.tap()

        // Active Read playback must carry its intent across the mode switch,
        // matching Kindle. No second tap on a tiny start icon is required.
        let explainPlayback = app.buttons["explainPlayPauseButton"]
        XCTAssertTrue(
            explainPlayback.waitForExistence(timeout: 240),
            "真实页面未能完成解读规划并进入可播放状态"
        )
        XCTAssertTrue(
            waitForAccessibilityValue("playing", on: explainPlayback, timeout: 150),
            "解读音频没有开始播放"
        )
        keepScreenshot(of: app, named: "GoogleBooks-03-explain-playing")
    }

    /// Opt-in live Kindle gate for a shelf that is already signed in on this
    /// simulator. It keeps the reader alive long enough for the external
    /// Kindle run log to observe OCR ordering, word paints, and at least one
    /// automatic page handoff without ever embedding Amazon credentials.
    func testKindleLiveHighlightAndAutomaticHandoff() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["CASTREADER_KINDLE_LIVE_HIGHLIGHT"] == "1",
              let bookID = environment["CASTREADER_KINDLE_LIVE_BOOK_ID"],
              !bookID.isEmpty else {
            throw XCTSkip(
                "Set CASTREADER_KINDLE_LIVE_HIGHLIGHT=1 and CASTREADER_KINDLE_LIVE_BOOK_ID"
            )
        }

        let observationSeconds = min(
            360,
            max(30, Double(environment["CASTREADER_KINDLE_LIVE_SECONDS"] ?? "210") ?? 210)
        )
        let interruptionMonitor = addUIInterruptionMonitor(
            withDescription: "CastReader system permission alerts"
        ) { alert in
            let denyLabels = ["Don’t Allow", "不允许", "Non consentire"]
            if let deny = denyLabels
                .map({ alert.buttons[$0] })
                .first(where: { $0.exists }) {
                deny.tap()
                return true
            }
            guard alert.buttons.count > 0 else { return false }
            alert.buttons.element(boundBy: 0).tap()
            return true
        }
        defer { removeUIInterruptionMonitor(interruptionMonitor) }

        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate"]
        app.launch()
        // Trigger the interruption monitor if a fresh Xcode install reset the
        // simulator's notification authorization while keeping shelf data.
        app.tap()

        let shelfEntry = app.buttons["homeShelfBook.kindle.\(bookID)"]
        XCTAssertTrue(shelfEntry.waitForExistence(timeout: 30), "Kindle live test book is missing from Home")
        shelfEntry.tap()

        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 45), "Kindle reader WebView did not open")
        // The WebView enters the hierarchy before Amazon finishes creating the
        // actual page image. Wait for that real navigation, then step back from
        // a possible persisted terminal page so the fixture always has prose.
        RunLoop.current.run(until: Date().addingTimeInterval(35))
        let previousPage = app.buttons["kindlePreviousPageButton"]
        if previousPage.waitForExistence(timeout: 10),
           previousPage.isEnabled,
           previousPage.isHittable {
            previousPage.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(10))
        }
        let readButton = app.buttons["kindleReadPlayPauseButton"]
        XCTAssertTrue(readButton.waitForExistence(timeout: 45), "Kindle read control did not appear")
        // Amazon can finish drawing the page before SwiftUI replaces the
        // temporary preparing control in the accessibility snapshot. The
        // visible control is already tappable at that point, so do not gate the
        // real start on a transient `paused` value from the previous bar.
        readButton.tap()
        XCTAssertTrue(
            waitForAccessibilityValue("playing", on: readButton, timeout: 150),
            "Kindle Italian page did not start real TTS playback"
        )
        keepScreenshot(of: app, named: "KindleLive-01-playing")

        RunLoop.current.run(until: Date().addingTimeInterval(observationSeconds))
        XCTAssertTrue(readButton.exists, "Kindle reader closed during continuous playback")
        keepScreenshot(of: app, named: "KindleLive-02-after-handoff-window")
    }

    /// 统一书架页仍必须提供其他书库；首启本身只保留一条 Kindle 路径。
    func testOnboardingOffersAllFiveBoundLibraries() {
        let app = launchZh()
        app.buttons["homeShelfSourcesButton"].tap()
        XCTAssertTrue(app.buttons["shelfSourcePrimaryAction.kindle"].waitForExistence(timeout: 6))
        XCTAssertTrue(app.buttons["shelfSourcePrimaryAction.weread"].exists)
        XCTAssertTrue(app.buttons["shelfSourcePrimaryAction.google_books"].exists)
        XCTAssertTrue(app.buttons["shelfSourcePrimaryAction.kobo"].exists)
        XCTAssertTrue(app.buttons["shelfSourcePrimaryAction.oreilly"].exists)
    }

    func testSettingsCanReopenLibraryOnboardingAfterDismissal() {
        let app = launchZh()
        app.tabBars.buttons["音色"].tap()
        XCTAssertTrue(app.buttons["settingsGearButton"].waitForExistence(timeout: 5))
        app.buttons["settingsGearButton"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5))

        let reopen = app.buttons["重新打开书库引导"]
        for _ in 0..<6 where !reopen.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(reopen.isHittable)
        reopen.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["boundLibraryOnboarding"]
                .waitForExistence(timeout: 6)
        )
    }

    func testCanSwitchInterfaceLanguageInsideTheApp() {
        let app = launchZh()
        // 齿轮只在「音色」Tab 的工具栏上（见 VoiceBrowserView）。冷启动停在首页时
        // 直接点会找不到元素——之前能过只是因为模拟器恢复了上一次选中的 Tab。
        app.tabBars.buttons["音色"].tap()
        XCTAssertTrue(app.buttons["settingsGearButton"].waitForExistence(timeout: 5))
        app.buttons["settingsGearButton"].tap()
        XCTAssertTrue(app.buttons["settingsLanguageLink"].waitForExistence(timeout: 5))
        app.buttons["settingsLanguageLink"].tap()
        XCTAssertTrue(app.buttons["appLanguage.en"].waitForExistence(timeout: 5))
        app.buttons["appLanguage.en"].tap()
        XCTAssertTrue(app.navigationBars["Language"].waitForExistence(timeout: 5))

        // Leave the shared simulator state deterministic for the remaining tests.
        app.buttons["appLanguage.zh-Hans"].tap()
        XCTAssertTrue(app.navigationBars["语言"].waitForExistence(timeout: 5))
    }

    func testInterfaceLanguageCanSwitchBetweenLTRAndRTLWithoutRelaunch() throws {
        let app = launchZh()
        mainNavigationItem(in: app, title: "音色", symbol: "waveform").tap()
        XCTAssertTrue(app.buttons["settingsGearButton"].waitForExistence(timeout: 5))
        app.buttons["settingsGearButton"].tap()
        openInterfaceLanguagePicker(in: app)
        let languages = [("en", "Language"), ("ar", "اللغة"), ("he", "שפה"),
                         ("de", "Sprache"), ("fil", "Wika"), ("vi", "Ngôn ngữ"), ("zh-Hans", "语言")]
        let expectedChrome: [String: [String]] = [
            "en": ["Settings", "Home", "Voice"],
            "ar": ["الإعدادات", "الرئيسية", "الصوت"],
            "he": ["הגדרות", "בית", "קול"],
            "de": ["Einstellungen", "Start", "Stimme"],
            "fil": ["Mga Setting", "Home", "Boses"],
            "vi": ["Cài đặt", "Trang chủ", "Giọng đọc"],
            "zh-Hans": ["设置", "首页", "音色"],
        ]
        for (code, title) in languages {
            let row = app.buttons["appLanguage.\(code)"]
            // List only materializes rows near its viewport. Return to the
            // beginning before each search, regardless of the current language.
            for _ in 0..<5 {
                let firstRow = app.buttons["appLanguage.system"]
                if firstRow.exists && firstRow.isHittable { break }
                app.collectionViews.firstMatch.swipeDown()
            }
            for _ in 0..<8 {
                if row.exists && row.isHittable { break }
                app.collectionViews.firstMatch.swipeUp()
            }
            XCTAssertTrue(row.exists && row.isHittable, code)
            guard row.exists && row.isHittable else { continue }
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), code)
            // Accessibility labels stay correct even when UIKit mirrors the
            // cell pixels. Read a stable Latin row from the rendered image too.
            let englishRow = app.buttons["appLanguage.en"]
            for _ in 0..<8 {
                if englishRow.exists && englishRow.isHittable {
                    let frame = englishRow.frame
                    if frame.minY > app.navigationBars[title].frame.maxY,
                       frame.maxY < app.collectionViews.firstMatch.frame.maxY - 20 { break }
                }
                app.collectionViews.firstMatch.swipeDown()
            }
            keepScreenshot(of: app, named: "runtime-language-pixels-\(code)")
            XCTAssertTrue(englishRow.exists && englishRow.isHittable, code)
            guard englishRow.exists && englishRow.isHittable else { continue }
            XCTAssertGreaterThan(englishRow.frame.minY, app.navigationBars[title].frame.maxY, code)
            let pixels = try XCTUnwrap(englishRow.screenshot().image.cgImage)
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.recognitionLanguages = ["en-US"]
            recognition.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: pixels).perform([recognition])
            let visibleWords = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            XCTAssertTrue(visibleWords.contains { $0.contains("English") }, "Mirrored language row in \(code): \(visibleWords)")
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "runtime-language-\(code)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            // The picker alone is insufficient: retained UIKit tabs and parent
            // navigation titles previously kept their creation-time language.
            let back = app.navigationBars[title].buttons.firstMatch
            XCTAssertTrue(back.exists)
            let isRTL = code == "ar" || code == "he"
            XCTAssertEqual(back.frame.midX > app.frame.midX, isRTL, code)
            back.tap()
            let expected = expectedChrome[code]!
            XCTAssertTrue(app.navigationBars[expected[0]].waitForExistence(timeout: 5), code)
            if code == "en" || code == "de" {
                revealSettingsLanguageRow(in: app)
                let pixels = try XCTUnwrap(app.buttons["settingsLanguageLink"].screenshot().image.cgImage)
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = ["en-US", "de-DE"]
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: pixels).perform([request])
                let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                XCTAssertTrue(words.contains { $0.contains(code == "en" ? "English" : "Deutsch") }, "Mirrored settings form: \(words)")
            }
            keepScreenshot(of: app, named: "runtime-settings-\(code)")
            app.buttons["settingsCloseButton"].tap()
            XCTAssertTrue(mainNavigationItem(in: app, title: expected[1], symbol: "house.fill").waitForExistence(timeout: 5), code)
            XCTAssertTrue(mainNavigationItem(in: app, title: expected[2], symbol: "waveform").exists, code)
            XCTAssertTrue(app.navigationBars[expected[2]].waitForExistence(timeout: 5), "Voice page title: \(code)")
            if code == "en" || code == "de" {
                let voiceTab = mainNavigationItem(in: app, title: expected[2], symbol: "waveform")
                let pixels = try XCTUnwrap(voiceTab.screenshot().image.cgImage)
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = ["en-US", "de-DE"]
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: pixels).perform([request])
                let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                XCTAssertTrue(words.contains { $0.contains(expected[2]) }, "Mirrored navigation item: \(words)")
                XCTAssertEqual(app.textFields["voiceSearchField"].placeholderValue,
                    code == "en" ? "Search voices or styles" : "Stimmen oder Stile suchen")
            }
            keepScreenshot(of: app, named: "runtime-voice-\(code)")
            // On iPad, importing is a Home toolbar action, not a global tab.
            mainNavigationItem(in: app, title: expected[1], symbol: "house.fill").tap()
            app.buttons["plusImportButton"].tap()
            let importCancel = app.buttons["importOptionsCancel"]
            XCTAssertTrue(importCancel.waitForExistence(timeout: 5), code)
            XCTAssertEqual(importCancel.frame.midX > app.frame.midX, isRTL, "Import sheet: \(code)")
            keepScreenshot(of: app, named: "runtime-import-\(code)")
            importCancel.tap()
            if code != "zh-Hans" {
                mainNavigationItem(in: app, title: expected[2], symbol: "waveform").tap()
                app.buttons["settingsGearButton"].tap()
                openInterfaceLanguagePicker(in: app)
            }
        }
    }

    private func openInterfaceLanguagePicker(in app: XCUIApplication) {
        revealSettingsLanguageRow(in: app)
        let language = app.buttons["settingsLanguageLink"]
        guard language.exists && language.isHittable else { return }
        language.tap()
        XCTAssertTrue(app.buttons["appLanguage.system"].waitForExistence(timeout: 5))
    }

    private func revealSettingsLanguageRow(in app: XCUIApplication) {
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(form.waitForExistence(timeout: 5))
        let language = app.buttons["settingsLanguageLink"]
        // iPad presents Settings in a shorter sheet and adds a New Window row.
        // Scroll the form itself; a gesture outside the sheet hits its backdrop.
        // A partially visible row under the translucent navigation bar can
        // report isHittable. Bring its entire frame below the bar before tapping.
        for _ in 0..<8 {
            let barBottom = app.navigationBars.allElementsBoundByIndex.last?.frame.maxY ?? form.frame.minY
            let aboveBar = language.exists && language.frame.minY <= barBottom
            if language.exists && language.isHittable,
               language.frame.minY > barBottom,
               language.frame.maxY < form.frame.maxY - 20 { break }
            let start = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: aboveBar ? 0.45 : 0.7))
            let end = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: aboveBar ? 0.7 : 0.45))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertTrue(language.exists && language.isHittable)
    }

    private func mainNavigationItem(in app: XCUIApplication, title: String, symbol: String) -> XCUIElement {
        if app.tabBars.firstMatch.exists { return app.tabBars.buttons[title] }
        // iPadOS exposes its top floating tabs as nested buttons instead of a
        // TabBar. Match both their symbol and localized title, not body copy.
        return app.buttons.matching(identifier: symbol)
            .matching(NSPredicate(format: "label == %@", title)).firstMatch
    }

    /// 首页只展示内容与一个统一书架入口，不再平铺未连接的平台卡片。
    func testHomeShowsScenarioChipsAndUnifiedShelfSources() {
        let app = launchZh()
        XCTAssertTrue(app.staticTexts["解读场景"].waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.buttons["homeShelfSourcesButton"].waitForExistence(timeout: 5),
            "首页右上角应始终显示书架来源入口"
        )
        for id in ["scenario-paper", "scenario-book", "scenario-report", "scenario-contract", "scenario-study", "scenario-manual"] {
            XCTAssertTrue(app.buttons[id].exists, "缺场景 chip: \(id)")
        }
        // The top-right button is now the stable unified source entry. The
        // body may legitimately contain no empty CTA while onboarding is
        // deferred, and connected source sections are data-dependent.
        for legacyID in [
            "connectKindleButton",
            "connectWeReadButton",
            "connectGoogleBooksButton",
            "connectKoboButton",
        ] {
            XCTAssertFalse(app.buttons[legacyID].exists, "首页不应再平铺未连接平台：\(legacyID)")
        }
    }

    /// 底部中间 ➕ 保持导入能力，同时正式提供 Google Drive；尚未开放的
    /// Dropbox / OneDrive 仍不得出现在发布界面。
    func testPlusOpensImportSheet() {
        let app = launchZh()
        let plus = app.buttons["plusImportButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        XCTAssertTrue(app.buttons["上传文件"].waitForExistence(timeout: 5), "➕ 未弹出导入方式")
        XCTAssertTrue(app.buttons["输入网址"].exists)
        XCTAssertTrue(app.buttons["librarySourcesImportButton"].exists)
        XCTAssertTrue(app.staticTexts["云端文件"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["cloudProvider.google_drive"].exists,
            "发布配置必须提供 Google Drive 导入"
        )
        for providerID in [
            "cloudProvider.dropbox",
            "cloudProvider.onedrive",
        ] {
            XCTAssertFalse(
                app.descendants(matching: .any)[providerID].exists,
                "发布配置不应显示云盘入口：\(providerID)"
            )
        }
    }

    /// Google Drive 已正式开放，不依赖历史调试参数；尚未开放的云盘仍不能
    /// 被该参数重新开启。
    func testGoogleDriveStaysEnabledAndUnreleasedProvidersStayExcludedEvenWithLegacyDebugArgument() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderCloudUITest",
            "-interfaceLanguage", "system",
            "-cloud.privacy.google_drive.version", "0",
            "-cloud.privacy.dropbox.version", "0",
            "-cloud.privacy.onedrive.version", "0",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let plus = app.buttons["plusImportButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 6))
        plus.tap()
        let importOptions = app.descendants(matching: .any)["importOptions.general"]
        XCTAssertTrue(importOptions.waitForExistence(timeout: 6))

        XCTAssertTrue(app.staticTexts["云端文件"].exists)
        XCTAssertTrue(
            app.descendants(matching: .any)["cloudProvider.google_drive"].exists,
            "Google Drive 应在发布配置中保持可见"
        )

        let unreleasedProviderIDs = [
            "cloudProvider.dropbox",
            "cloudProvider.onedrive",
        ]
        for providerID in unreleasedProviderIDs {
            XCTAssertFalse(
                app.descendants(matching: .any)[providerID].exists,
                "尚未开放的云盘不应被调试参数重新开启：\(providerID)"
            )
        }
    }

    /// 统一书架来源页承载所有商业阅读平台，新增平台不再挤占首页。
    func testShelfSourcesOffersAllFivePlatforms() {
        let app = launchZh()
        openShelfSources(in: app)

        for source in ["kindle", "weread", "google_books", "kobo", "oreilly"] {
            XCTAssertTrue(
                app.buttons["shelfSourcePrimaryAction.\(source)"]
                    .waitForExistence(timeout: 5),
                "统一书架来源页缺少平台：\(source)"
            )
        }
    }

    func testChinaRegionHidesYouTubeEntryButStillOffersAllFiveShelfPlatforms() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderRegion", "cn",
            "-CastReaderServiceRoute", "global",
            "-CastReaderSkipSignInGate",
            "-CastReaderSkipLibraryOnboarding",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        XCTAssertFalse(
            app.descendants(matching: .any)["homeShelfSection.youtube"]
                .waitForExistence(timeout: 1),
            "中国发行体验不应展示 YouTube 首页入口"
        )
        openShelfSources(in: app)

        for source in ["weread", "kindle", "google_books", "kobo", "oreilly"] {
            XCTAssertTrue(
                app.buttons["shelfSourcePrimaryAction.\(source)"]
                    .waitForExistence(timeout: 5),
                "中国发行体验仍必须保留平台：\(source)"
            )
        }
    }

    func testGlobalRegionKeepsYouTubeHomeEntry() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderRegion", "global",
            "-CastReaderServiceRoute", "cn",
            "-CastReaderSkipSignInGate",
            "-CastReaderSkipLibraryOnboarding",
        ]
        app.launch()
        dismissSelfOpenSystemAlertIfPresent()

        XCTAssertTrue(
            app.descendants(matching: .any)["homeShelfSection.youtube"]
                .waitForExistence(timeout: 5),
            "全球发行体验必须继续展示 YouTube 首页入口，且不应受服务线路影响"
        )
    }

    /// 首页和中间 ➕ 保持不变，只把右侧 Settings 替换成 Voice。
    func testHomePlusAndVoiceNavigation() {
        let app = launchZh()
        XCTAssertTrue(app.tabBars.buttons["首页"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["plusImportButton"].exists)
        XCTAssertTrue(app.tabBars.buttons["音色"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["设置"].exists)

        XCTAssertTrue(app.buttons["homeShelfSourcesButton"].exists)

        app.tabBars.buttons["音色"].tap()
        XCTAssertTrue(app.navigationBars["音色"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["探索"].exists)
        XCTAssertTrue(app.buttons["settingsGearButton"].exists)
        // 右上角这组入口在两个 Tab 上必须一致：切到音色时书架不能消失。
        XCTAssertTrue(
            app.buttons["voiceShelfSourcesButton"].exists,
            "音色 Tab 缺少书架来源入口，右上角在切 Tab 时又变了"
        )
    }

    /// 账号入口恢复 UI 分支介入前的尺寸，并且可访问名称不泄露会员状态。
    /// 头像自身的 28pt 尺寸与无会员装饰由发布前截图一起验收。
    func testSettingsToolbarUsesOriginalAccountEntry() {
        let app = launchZh()
        let settings = app.buttons["settingsGearButton"]

        XCTAssertTrue(settings.waitForExistence(timeout: 6))
        XCTAssertEqual(settings.label, "账号与设置")
        XCTAssertGreaterThanOrEqual(settings.frame.width, 28)
        XCTAssertGreaterThanOrEqual(settings.frame.height, 28)
    }

    /// 设置是 sheet，必须有「关闭」按钮，而不是只能下拉退出。
    func testSettingsSheetHasCloseButton() {
        let app = launchZh()
        let gear = app.buttons["settingsGearButton"]
        XCTAssertTrue(gear.waitForExistence(timeout: 6))
        gear.tap()

        let close = app.buttons["settingsCloseButton"]
        XCTAssertTrue(close.waitForExistence(timeout: 6), "设置没有关闭按钮")
        close.tap()
        XCTAssertTrue(
            app.tabBars.buttons["首页"].waitForExistence(timeout: 6),
            "点关闭后设置没有退出"
        )
    }

    /// 中国大陆发行体验必须在设置的「关于」区域公开备案号，并把整行做成
    /// 可点击的工信部查询入口；全球发行体验不得误显示中国备案信息。
    func testChinaSettingsShowsClickableICPRecordOnlyInChinaRegion() {
        let chinaApp = XCUIApplication()
        chinaApp.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-interfaceLanguage", "system",
            "-CastReaderRegion", "cn",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
        ]
        chinaApp.launch()
        dismissSelfOpenSystemAlertIfPresent()

        let chinaGear = chinaApp.buttons["settingsGearButton"]
        XCTAssertTrue(chinaGear.waitForExistence(timeout: 6))
        chinaGear.tap()
        let filingLink = chinaApp.descendants(matching: .any)["settingsICPLink"]
        for _ in 0..<16 where !filingLink.isHittable {
            chinaApp.swipeUp()
        }
        XCTAssertTrue(filingLink.waitForExistence(timeout: 5), "中国区设置缺少 ICP 备案号")
        XCTAssertTrue(filingLink.isEnabled, "ICP 备案号必须可点击前往工信部查询页")
        XCTAssertTrue(filingLink.label.contains("沪ICP备14008512号-12A"))

        chinaApp.terminate()

        let globalApp = XCUIApplication()
        globalApp.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-interfaceLanguage", "system",
            "-CastReaderRegion", "global",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
        ]
        globalApp.launch()
        dismissSelfOpenSystemAlertIfPresent()
        let globalGear = globalApp.buttons["settingsGearButton"]
        XCTAssertTrue(globalGear.waitForExistence(timeout: 6))
        globalGear.tap()
        for _ in 0..<16 { globalApp.swipeUp() }
        XCTAssertFalse(
            globalApp.descendants(matching: .any)["settingsICPLink"].exists,
            "全球发行体验不应显示中国 ICP 备案号"
        )
    }

    /// 点「论文 / 学术」→ 场景导入面板，列出上传文件 + 输入网址等来源。
    func testScenarioTapOpensSourcePicker() {
        let app = launchZh()
        let card = app.buttons["scenario-paper"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["输入网址"].waitForExistence(timeout: 5), "场景 Menu 未弹来源选择")
    }

    /// 从统一书架来源页连接 Kindle，进入现有 Amazon 登录 / 同步 WebView。
    func testKindleConnectOpensWebView() {
        let app = launchZh()
        openKindleBinding(in: app)
        XCTAssertTrue(app.navigationBars["绑定 Kindle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 8), "绑定 Kindle 未打开 WebView")
    }

    /// 可选真账号验收：由环境变量注入 KINDLE_EMAIL / KINDLE_PASSWORD，不把凭据写进仓库。
    func testKindleAmazonLoginAndSyncWhenCredentialsProvided() throws {
        let env = ProcessInfo.processInfo.environment
        guard let email = env["KINDLE_EMAIL"], !email.isEmpty,
              let password = env["KINDLE_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("KINDLE_EMAIL / KINDLE_PASSWORD not provided")
        }

        let app = launchZh()
        openKindleBinding(in: app)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))

        let web = app.webViews.firstMatch
        let emailField = web.textFields.firstMatch
        if emailField.waitForExistence(timeout: 12) {
            emailField.tap()
            emailField.typeText(email)
            tapFirstExisting(in: app, labels: ["Continue", "继续", "继续登录"])
        }

        let passwordField = web.secureTextFields.firstMatch
        guard passwordField.waitForExistence(timeout: 12) else {
            throw XCTSkip("Amazon did not expose a password field, likely already signed in or waiting for verification.")
        }
        passwordField.tap()
        UIPasteboard.general.string = password
        passwordField.press(forDuration: 1.0)
        tapFirstExisting(in: app, labels: ["Paste", "粘贴"])
        tapFirstExisting(in: app, labels: ["Sign in", "Sign-In", "登录"])

        sleep(5)
        if app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@", "verification", "captcha", "code")).firstMatch.exists {
            throw XCTSkip("Amazon requested verification/captcha.")
        }

        let sync = app.buttons["Sync"]
        XCTAssertTrue(sync.waitForExistence(timeout: 20), "Kindle sync button not visible after login attempt")
        sync.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "synced")).firstMatch.waitForExistence(timeout: 30))
    }

    /// 设置入口放在 Voice 右上角，首页本身保持不变。
    func testVoiceSettingsGearKeepsLibraryEntry() {
        let app = launchZh()
        app.tabBars.buttons["音色"].tap()
        let settingsGear = app.buttons["settingsGearButton"].firstMatch
        XCTAssertTrue(settingsGear.waitForExistence(timeout: 5), "Voice 右上角缺设置入口")
        settingsGear.tap()
        XCTAssertTrue(app.buttons["settingsLibraryLink"].waitForExistence(timeout: 5), "设置里缺文库入口")
        XCTAssertFalse(app.tabBars.buttons["设置"].exists)
    }

    private func tapFirstExisting(in app: XCUIApplication, labels: [String]) {
        for label in labels {
            let button = app.buttons[label]
            if button.waitForExistence(timeout: 3) {
                button.tap()
                return
            }
        }
        let returnKey = app.keyboards.buttons["Return"]
        if returnKey.exists { returnKey.tap() }
    }

    /// 书架来源是首页右上角常驻入口，不受账号绑定或首页是否已有书影响。
    private func openShelfSources(in app: XCUIApplication) {
        let sources = app.buttons["homeShelfSourcesButton"]
        XCTAssertTrue(sources.waitForExistence(timeout: 5), "首页右上角缺少书架来源入口")
        XCTAssertTrue(sources.isHittable, "首页右上角书架来源入口不可点击")
        sources.tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["shelfSourcesScreen"]
                .waitForExistence(timeout: 5),
            "没有进入统一书架来源页"
        )
    }

    private func openKindleBinding(in app: XCUIApplication) {
        openShelfSources(in: app)
        let action = app.buttons["shelfSourcePrimaryAction.kindle"]
        XCTAssertTrue(action.waitForExistence(timeout: 5), "Kindle 连接/同步入口不存在")
        action.tap()
    }

    /// Prefer the stable home-rail id. If this volume is not among the eight
    /// recent cards, enter the adjacent full-shelf view and page through its
    /// real rows instead of weakening the assertion to "open any book".
    private func googleBooksShelfEntry(
        in app: XCUIApplication,
        volumeID: String
    ) -> XCUIElement? {
        let homeEntry = app.buttons["homeShelfBook.google_books.\(volumeID)"]
        for _ in 0..<14 {
            if homeEntry.exists, homeEntry.isHittable { return homeEntry }
            if visibleStaticText("Google Play 图书", in: app) != nil { break }
            app.swipeUp()
        }
        if homeEntry.exists, homeEntry.isHittable { return homeEntry }

        guard let header = visibleStaticText("Google Play 图书", in: app) else { return nil }
        let seeAll = app.buttons.matching(identifier: "查看全部").allElementsBoundByIndex
            .filter { $0.exists && $0.isHittable }
            .min { lhs, rhs in
                abs(lhs.frame.midY - header.frame.midY) < abs(rhs.frame.midY - header.frame.midY)
            }
        guard let seeAll else { return nil }
        seeAll.tap()
        guard app.navigationBars["Google Play 图书书架"].waitForExistence(timeout: 15) else {
            return nil
        }

        let fullShelfEntry = app.buttons["googleBooksBook.\(volumeID)"]
        for _ in 0..<10 {
            for _ in 0..<28 {
                if fullShelfEntry.exists, fullShelfEntry.isHittable { return fullShelfEntry }
                app.swipeUp()
            }
            let loadMore = app.buttons["加载更多"]
            guard loadMore.exists, loadMore.isHittable else { return nil }
            loadMore.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        return fullShelfEntry.exists && fullShelfEntry.isHittable ? fullShelfEntry : nil
    }

    private func visibleStaticText(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement? {
        app.staticTexts.matching(identifier: identifier).allElementsBoundByIndex
            .first { $0.exists && $0.isHittable }
    }

    private func waitForAccessibilityValue(
        _ expected: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let identifier = element.identifier

        func currentCandidates() -> [XCUIElement] {
            guard !identifier.isEmpty else { return [element] }
            return XCUIApplication()
                .descendants(matching: .any)
                .matching(identifier: identifier)
                .allElementsBoundByIndex
        }

        func hasExpectedValue() -> Bool {
            currentCandidates().contains {
                $0.exists && ($0.value as? String) == expected
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            // SwiftUI can replace a temporary loading control with the real
            // playback control while preserving the accessibility identifier.
            // Re-query that identifier so the test does not keep polling the
            // detached pre-playback XCUIElement snapshot.
            if hasExpectedValue() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return hasExpectedValue()
    }

    private func waitForEither(
        _ first: XCUIElement,
        _ second: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if first.exists || second.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return first.exists || second.exists
    }

    private func waitForDisappearance(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if !element.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return !element.exists
    }

    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

// MARK: - App Store 素材采集

/// 商店截图 / App Preview 的可复现采集器。
///
/// 默认跳过——只有显式设置 `CASTREADER_CAPTURE=1` 时才运行，避免拖慢常规测试。
/// 配套外部录屏：`xcrun simctl io <udid> recordVideo`，所以这里的节奏刻意留了停顿，
/// 让「词级高亮跟读」这个真正的差异点在成片里看得清。
final class AppStoreCaptureUITests: XCTestCase {

    /// 用于演示的公有领域文本（梭罗《瓦尔登湖》节选），避免采集素材时触碰任何真实用户内容或版权文本。
    private let demoText = """
    I went to the woods because I wished to live deliberately, to front only the \
    essential facts of life, and see if I could not learn what it had to teach, and not, \
    when I came to die, discover that I had not lived. I did not wish to live what was not \
    life, living is so dear; nor did I wish to practise resignation, unless it was quite \
    necessary. I wanted to live deep and suck out all the marrow of life, to live so \
    sturdily and Spartan-like as to put to rout all that was not life, to cut a broad \
    swath and shave close, to drive life into a corner, and reduce it to its lowest terms.
    """

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CASTREADER_CAPTURE"] == "1",
            "仅在采集商店素材时运行：CASTREADER_CAPTURE=1"
        )
    }

    private func launchForCapture() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
        ]
        app.launch()
        return app
    }

    /// confirmationDialog / sheet 里的按钮层级不固定，逐个容器找第一个可点的。
    private func firstHittable(in app: XCUIApplication, label: String, timeout: TimeInterval = 10) -> XCUIElement? {
        let candidates = [app.buttons[label], app.sheets.buttons[label], app.scrollViews.buttons[label]]
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for candidate in candidates where candidate.exists && candidate.isHittable {
                return candidate
            }
            Thread.sleep(forTimeInterval: 0.4)
        }
        return nil
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// 首页 → 粘贴文本 → 朗读，全程停在关键画面上供录屏抓取。
    func testCaptureReadAloudHeroFlow() throws {
        let app = launchForCapture()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15), "首页未就绪")
        Thread.sleep(forTimeInterval: 2)
        snapshot(app, "01-home")

        let plus = app.buttons["plusImportButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 10))
        plus.tap()

        // 导入方式是 confirmationDialog，按钮可能挂在 app 或 sheet 下，两处都找。
        let pasteText = firstHittable(in: app, label: "Paste Text")
        XCTAssertNotNil(pasteText, "导入方式里没有「Paste Text」")
        pasteText?.tap()
        Thread.sleep(forTimeInterval: 1)
        snapshot(app, "02-import")

        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "文本输入框未出现")
        editor.tap()
        editor.typeText(demoText)

        let start = firstHittable(in: app, label: "Start")
        XCTAssertNotNil(start, "没有「Start」按钮")
        start?.tap()

        // 阅读器就绪。此时还是暂停态，正文是未生成的灰字。
        let play = app.buttons["play.circle.fill"]
        XCTAssertTrue(play.waitForExistence(timeout: 25), "阅读器没出现播放按钮")
        Thread.sleep(forTimeInterval: 1)
        snapshot(app, "03-reader-ready")

        play.tap()

        // TTS 走云端，首音可能要等几秒。播放按钮翻成暂停 = 真的播起来了。
        // 这条断言是这个采集器的意义所在：没播起来就没有词级高亮，录出来只是一张静止的文字页。
        let pause = app.buttons["pause.circle.fill"]
        XCTAssertTrue(
            pause.waitForExistence(timeout: 45),
            "TTS 未开始播放——录到的画面没有词级高亮，不能拿去做 App Preview"
        )

        // 播放中途取帧——这段是 App Preview 的主镜头：高亮逐词推进 + 自动滚动。
        // 停留时间要短于音频总长，否则截到的是「已读完」的静止页面。
        Thread.sleep(forTimeInterval: 8)
        snapshot(app, "04-word-highlight")
        Thread.sleep(forTimeInterval: 10)
        snapshot(app, "05-word-highlight-later")
        XCTAssertTrue(pause.exists, "主镜头还没录完音频就停了，演示文本太短")
        Thread.sleep(forTimeInterval: 8)
    }

    /// 付费页：验证 7 天免费试用文案在真机 UI 上的最终呈现，同时产出商店可用的订阅页截图。
    ///
    /// DEBUG 构建默认按真实账号权益运行；这里仍显式关闭模拟 Pro，避免开发者上次手动开启的
    /// 持久化调试开关污染免费用户截图。
    func testCapturePaywallWithFreeTrial() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderDisableDebugPro",
        ]
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Home"].waitForExistence(timeout: 15))

        // Pro 卡片在首页最底部，需要滚动到可见才能截图。
        let plans = app.buttons["homeProPlansButton"]
        XCTAssertTrue(plans.waitForExistence(timeout: 20), "免费用户视角下首页应出现 Pro 卡片")
        for _ in 0..<8 where !plans.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(plans.isHittable, "Pro 卡片没能滚到可见区域")
        Thread.sleep(forTimeInterval: 3)
        snapshot(app, "05-home-pro-card-trial")

        plans.tap()

        Thread.sleep(forTimeInterval: 5)
        snapshot(app, "06-paywall-free-trial")
    }
}

/// Bounded, opt-in acceptance of the shipping reader against the real service.
/// The simulator must already be signed in for Explain. No entitlement/session
/// is injected, no account state is reset, and the source is a public fixture.
final class MultilingualReaderLiveUITests: XCTestCase {
    private var duoFoldControlDirectory: String? {
        ProcessInfo.processInfo.environment["CASTREADER_LONG_DUO_FOLD_CONTROL"]
    }

    /// Body extraction can be verified while the shared speech budget is unavailable.
    /// Disable the normal Auto Play preference for this import-only launch.
    func testNewLanguageWebImportsWithoutStartingSpeech() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CASTREADER_LONG_MANIFEST"] else { throw XCTSkip("Opt-in manifest required") }
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
        var results: [[String: Any]] = []
        XCUIDevice.shared.orientation = .portrait
        try configureManualPlayback()
        for row in rows where row["format"] as? String == "web" {
            let language = row["language"] as! String
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
                "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate", "-CastReaderMultilingualAcceptance",
                "-CastReaderAcceptanceWebURL", row["url"] as! String]
            app.launch()
            var result: [String: Any] = ["language": language, "url": row["url"]!]
            do {
                let probe = app.descendants(matching: .any)["readerLanguagePlaybackMetrics"].firstMatch
                try require(probe.waitForExistence(timeout: 40), "web reader missing")
                try require(wait(90) { (self.metrics(probe)["readableParagraphs"] as? Int ?? 0) > 5 }, "web body not extracted")
                let value = metrics(probe)
                let detected = value["language"] as? String ?? ""
                try require(value["sourceKind"] as? String == "web", "wrong source")
                try require(detected.isEmpty || detected == language, "wrong language: \(detected)")
                try require(value["playing"] as? Bool == false, "import unexpectedly started speech")
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                let settled = metrics(probe)
                try require(settled["playing"] as? Bool == false && (settled["segment"] as? String ?? "").isEmpty,
                            "import started audio after extraction")
                try require((settled["readError"] as? String ?? "").isEmpty, "import attempted playback or failed")
                result["metrics"] = value
                result["status"] = detected.isEmpty ? "imported_language_uncertain" : "imported_language_resolved"
                snapshot(app, "\(language)-web-imported")
            } catch {
                result["status"] = "failed"; result["error"] = String(describing: error)
                snapshot(app, "\(language)-web-import-failure")
                XCTFail("\(language): \(error)")
            }
            results.append(result)
            if let report = env["CASTREADER_LONG_REPORT"] {
                try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted])
                    .write(to: URL(fileURLWithPath: report), options: .atomic)
            }
            app.terminate()
        }
        XCTAssertEqual(results.count, 19)
    }

    /// Each requested format gets its own real three-minute Read and Explain run.
    func testNewLanguagesWebPDFAndEPUBThreeMinutePlayback() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CASTREADER_LONG_MANIFEST"] else { throw XCTSkip("Opt-in long-session manifest required") }
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: Any]]
        let selected = env["CASTREADER_LONG_LANGUAGES"]?.split(separator: ",").map(String.init)
        let formats = env["CASTREADER_LONG_FORMATS"]?.split(separator: ",").map(String.init)
        let seconds = Double(env["CASTREADER_LONG_SECONDS"] ?? "180") ?? 180
        let modes = Set((env["CASTREADER_LONG_MODES"] ?? "read,explain").split(separator: ",").map(String.init))
        let reportPath = env["CASTREADER_LONG_REPORT"]
        if let directory = duoFoldControlDirectory {
            try require(directory.hasPrefix("/"), "Duo fold control must be an absolute directory")
            try require(!modes.isEmpty && modes.isSubset(of: ["read", "explain"]) && seconds >= 30,
                        "Duo acceptance requires at least 30 observed seconds per selected mode")
        }
        var results: [[String: Any]] = []
        XCUIDevice.shared.orientation = .portrait
        try configureManualPlayback()
        for row in rows {
            let language = row["language"] as! String, format = row["format"] as! String
            if let selected, !selected.contains(language) { continue }
            if let formats, !formats.contains(format) { continue }
            let app = XCUIApplication(), started = Date()
            var result: [String: Any] = ["language": language, "format": format,
                "requiredPlayingSeconds": seconds, "explanationDepth": "deep", "fixture": row]
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
                "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate", "-explain_language", "", "-explain_depth", "deep",
                "-CastReaderMultilingualAcceptance"]
            if format == "web" { app.launchArguments += ["-CastReaderAcceptanceWebURL", row["url"] as! String] }
            else { app.launchArguments += ["-CastReaderAcceptanceDocumentPath", row["file"] as! String] }
            app.launch()
            do {
                let probe = app.descendants(matching: .any)["readerLanguagePlaybackMetrics"].firstMatch
                try require(probe.waitForExistence(timeout: 90), "import did not open reader")
                let play = app.buttons["readPlayPauseButton"].firstMatch
                try require(play.waitForExistence(timeout: 30), "Read control missing")
                let notice = app.staticTexts["readerPlaybackFailureNotice"]
                try require(wait(60) { (self.metrics(probe)["readableParagraphs"] as? Int ?? 0) > 0 || notice.exists }, "content not ready")
                try require(wait(45) {
                    let state = self.metrics(probe)["readStartState"] as? [String: Any] ?? [:]
                    return state["isPro"] as? Bool == true
                }, "existing signed-in Pro account has not finished restoring")
                if modes.contains("read") {
                if format == "epub", (self.metrics(probe)["paragraph"] as? Int ?? 0) > 0 {
                    // A retry must exercise the full sample, while preserving
                    // the real account and saved library. Return through UI.
                    let first = app.descendants(matching: .any)["readerParagraph.0"].firstMatch
                    for _ in 0..<40 where !first.exists || !first.isHittable {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
                    }
                    try require(first.exists && first.isHittable, "EPUB beginning unavailable")
                    first.tap()
                    try require(wait(100) { self.metrics(probe)["playing"] as? Bool == true || notice.exists }, "EPUB restart did not begin")
                    result["readRestartedFromBeginning"] = true
                }
                if self.metrics(probe)["playing"] as? Bool != true { play.tap() }
                try require(wait(100) { self.metrics(probe)["playing"] as? Bool == true || notice.exists }, "Read did not start")
                var detected = self.metrics(probe)["language"] as? String ?? ""
                result["initialDetectedLanguage"] = detected
                if detected.isEmpty && notice.exists {
                    app.buttons["playbackVoiceButton"].firstMatch.tap()
                    let search = app.searchFields["Search Languages"]
                    try require(search.waitForExistence(timeout: 10), "language correction unavailable")
                    let locale = row["locale"] as! String
                    search.tap(); search.typeText(locale)
                    let target = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", locale)).firstMatch
                    try require(target.waitForExistence(timeout: 10), "language correction row missing")
                    target.tap()
                    // Selection regenerates audio, preserving playback intent.
                    // With auto-play disabled, wait for preparation before Play;
                    // tapping the loading spinner is explicitly a pause action.
                    result["manualLanguageCorrection"] = true
                    try require(wait(100) {
                        let value = self.metrics(probe)
                        let state = value["readStartState"] as? [String: Any] ?? [:]
                        return value["playing"] as? Bool == true ||
                            (state["hasQueuedSegments"] as? Bool == true &&
                             state["loading"] as? Bool == false && state["streaming"] as? Bool == false)
                    }, "corrected audio was not prepared")
                    if self.metrics(probe)["playing"] as? Bool != true { play.tap() }
                    try require(wait(100) { self.metrics(probe)["playing"] as? Bool == true }, "corrected Read did not start")
                    detected = self.metrics(probe)["language"] as? String ?? ""
                }
                try require(detected == language, "wrong Read language \(detected), expected \(language)")
                try require(self.metrics(probe)["sourceKind"] as? String == format, "wrong renderer/source format")
                if modes.contains("read") {
                    snapshot(app, "\(language)-\(format)-read-start")
                    result["read"] = try observeContinuousPlayback(app, probe: probe, seconds: seconds,
                        name: "\(language)-\(format)-read", playID: "readPlayPauseButton", errorID: "readerPlaybackFailureNotice")
                    // Preserve the completed mode even if the runner is stopped
                    // during Explain and Xcode never finalizes its result bundle.
                    result["status"] = "read_passed_explain_pending"
                    if let reportPath {
                        try JSONSerialization.data(withJSONObject: results + [result], options: [.sortedKeys, .prettyPrinted])
                            .write(to: URL(fileURLWithPath: reportPath), options: .atomic)
                    }
                }
                // A segment boundary can report playing=false while the
                // explicit playback request is still active. Pause that intent
                // before switching modes, or Explain correctly auto-starts and
                // the test waits for an idle Start button that should not exist.
                let readState = self.metrics(probe)
                let readIntent = readState["readStartState"] as? [String: Any] ?? [:]
                if readState["playing"] as? Bool == true || readIntent["hasPlaybackRequest"] as? Bool == true {
                    play.tap()
                }
                try require(wait(8) {
                    let value = self.metrics(probe)
                    let intent = value["readStartState"] as? [String: Any] ?? [:]
                    return value["playing"] as? Bool == false && intent["hasPlaybackRequest"] as? Bool == false
                }, "Read playback intent did not pause before mode switch")
                }
                if modes.contains("explain") {
                let picker = app.segmentedControls["readerModePicker"]
                if picker.exists { picker.buttons["Explain"].tap() }
                else { app.buttons["readerModeMenu"].tap(); app.buttons["Explain"].firstMatch.tap() }
                let startButton = app.buttons["explainStartButton"].firstMatch
                try require(startButton.waitForExistence(timeout: 15), "Explain start missing")
                if format == "pdf", row["explainFromCurrentPage"] as? Bool != true {
                    // PDF Explain starts at the visible page, including after
                    // a reimport restores the content's saved reading cursor.
                    // Navigate through the real view instead of clearing it.
                    for _ in 0..<25 where self.metrics(probe)["explainScopeStart"] as? Int != 0 {
                        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
                            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)))
                    }
                    try require(self.metrics(probe)["explainScopeStart"] as? Int == 0, "PDF Explain did not start at the beginning")
                    result["explainStartedFromFirstPage"] = true
                }
                result["explainStartingParagraph"] = self.metrics(probe)["explainScopeStart"]
                startButton.tap()
                let error = app.staticTexts["readerExplainError"]
                try require(wait(150) { self.metrics(probe)["playing"] as? Bool == true || error.exists }, "Explain did not start")
                try require(!error.exists, "Explain error: \(error.exists ? error.label : "")")
                try require(self.metrics(probe)["explainLanguage"] as? String == language, "wrong Explain language")
                snapshot(app, "\(language)-\(format)-explain-start")
                result["explain"] = try observeContinuousPlayback(app, probe: probe, seconds: seconds,
                    name: "\(language)-\(format)-explain", playID: "explainPlayPauseButton", errorID: "readerExplainError")
                if duoFoldControlDirectory != nil {
                    result["duoExplainResume"] = try verifyDuoExplainMinimizeAndReopen(
                        app, probe: probe, source: "\(language)-\(format)")
                }
                }
                result["status"] = "passed"
            } catch {
                result["status"] = "failed"; result["error"] = String(describing: error)
                result["lastMetrics"] = metrics(app.descendants(matching: .any)["readerLanguagePlaybackMetrics"].firstMatch)
                snapshot(app, "\(language)-\(format)-failure")
                XCTFail("\(language)/\(format): \(error)")
            }
            result["elapsedSeconds"] = Date().timeIntervalSince(started)
            results.append(result)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys, .prettyPrinted])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "long-\(language)-\(format).json"; attachment.lifetime = .keepAlways; add(attachment)
            if let reportPath { try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys, .prettyPrinted]).write(to: URL(fileURLWithPath: reportPath), options: .atomic) }
            app.terminate()
        }
        XCTAssertFalse(results.isEmpty)
    }

    private func metrics(_ element: XCUIElement) -> [String: Any] {
        guard element.exists, let text = element.value as? String,
              let data = text.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return result
    }

    /// Use the real preference control. Launch-argument strings do not satisfy
    /// AppSettings' stored Bool type check, so `-auto_play NO` is ineffective.
    private func configureManualPlayback() throws {
        // Duo's inner-display XCTest scroll events can miss the real surface.
        // The parent may prepare this preference through the visible app UI;
        // this opt-in skips only setup, never the live playback assertions.
        if duoFoldControlDirectory != nil,
           ProcessInfo.processInfo.environment["CASTREADER_LONG_DUO_PREFS_PREPARED"] == "1" {
            return
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
            "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate"]
        app.launch()
        let minimize = app.buttons["readerMinimizeButton"]
        if minimize.waitForExistence(timeout: 2) { minimize.tap() }
        let settings = app.buttons["settingsGearButton"]
        try require(settings.waitForExistence(timeout: 15), "settings unavailable for manual playback")
        let settingsClose = app.buttons["settingsCloseButton"]
        for _ in 0..<3 {
            settings.tap()
            if settingsClose.waitForExistence(timeout: 5) { break }
        }
        try require(settingsClose.exists, "Settings did not open after the home button tap")
        let autoplay = app.switches["Auto-play"].firstMatch
        for _ in 0..<8 where !autoplay.isHittable { app.swipeUp() }
        try require(autoplay.isHittable, "Auto-play preference unavailable")
        if autoplay.value as? String == "1" {
            // SwiftUI exposes both the whole Form row and its trailing switch.
            // Touch the control at the trailing edge rather than the label.
            autoplay.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        try require(wait(5) { autoplay.value as? String == "0" },
                    "Auto-play preference did not turn off: \(autoplay.value ?? "nil")")
        if settingsClose.exists { settingsClose.tap() }
        try require(app.buttons["settingsGearButton"].waitForExistence(timeout: 10),
                    "Home did not return after setting manual playback")
        app.terminate()
    }

    private func observeContinuousPlayback(_ app: XCUIApplication, probe: XCUIElement,
        seconds: Double, name: String, playID: String, errorID: String) throws -> [String: Any] {
        var deadline = Date().addingTimeInterval(seconds + 240)
        var prior = metrics(probe), priorDate = Date(), played = 0.0, lastProgress = Date()
        var samples: [[String: Any]] = [], segments = Set<String>(), paragraphs = Set<Int>()
        var captions = Set<String>(), highlights = Set<String>(), maximumMarks = 0
        var paused = false, halfwayShot = false
        var duoFoldStages: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "\(name)-playback-observations.json"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        while played < seconds && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            let current = metrics(probe), date = Date()
            let time = current["time"] as? Double ?? 0, priorTime = prior["time"] as? Double ?? 0
            let segment = current["segment"] as? String ?? ""
            let advanced = !segment.isEmpty && (segment != prior["segment"] as? String || time > priorTime + 0.03)
            if current["playing"] as? Bool == true && advanced {
                let audioDelta = segment == prior["segment"] as? String
                    ? max(0, time - priorTime)
                    : max(0, (prior["duration"] as? Double ?? 0) - priorTime) + time
                let rate = max(0.25, current["rate"] as? Double ?? 1)
                // Count actual media-clock progress, capped by wall time. At a
                // boundary this conservatively omits any unobserved segment.
                played += min(date.timeIntervalSince(priorDate), audioDelta / rate)
                lastProgress = date
                segments.insert(segment)
                paragraphs.insert(current["paragraph"] as? Int ?? -1)
                if let value = current["caption"] as? String, !value.isEmpty { captions.insert(value) }
                if let value = current["highlight"] as? String, !value.isEmpty { highlights.insert(value) }
                maximumMarks = max(maximumMarks, current["marks"] as? Int ?? 0)
            }
            var observation = current; observation["effectivePlayingSeconds"] = played; samples.append(observation)
            let error = app.staticTexts[errorID]
            let message = current[name.hasSuffix("explain") ? "explainError" : "readError"] as? String ?? ""
            try require(message.isEmpty, "playback error: \(message)")
            try require(!error.exists, "playback error: \(error.exists ? error.label : "")")
            if name.hasSuffix("explain"), current["explainFinished"] as? Bool == true, played < seconds {
                throw NSError(domain: "ReaderAcceptance", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Explanation completed normally after \(played) seconds; fixture is too short from the selected starting page"])
            }
            if name.hasSuffix("read"), current["readFinished"] as? Bool == true, played < seconds {
                throw NSError(domain: "ReaderAcceptance", code: 2, userInfo: [NSLocalizedDescriptionKey:
                    "Document completed normally after \(played) directly observed seconds; fold-handshake playback is excluded from the duration gate"])
            }
            try require(date.timeIntervalSince(lastProgress) < 75, "player stopped or stalled before three minutes")
            prior = current; priorDate = date
            if !paused && played >= 12 {
                let button = app.buttons[playID].firstMatch
                // Between Explain blocks the control temporarily represents
                // preparation rather than a pause action. Keep observing until
                // audible playback returns, then perform the real pause check.
                if button.exists && button.isEnabled && self.metrics(probe)["playing"] as? Bool == true {
                    button.tap()
                    try require(wait(8) { self.metrics(probe)["playing"] as? Bool == false }, "pause failed")
                    let pausedState = metrics(probe)
                    RunLoop.current.run(until: Date().addingTimeInterval(1))
                    let still = metrics(probe)
                    try require(abs((still["time"] as? Double ?? 0) - (pausedState["time"] as? Double ?? 0)) < 0.15, "audio clock moved while paused")
                    snapshot(app, "\(name)-paused")
                    button.tap()
                    try require(wait(30) { self.metrics(probe)["playing"] as? Bool == true }, "resume failed")
                    paused = true
                    prior = metrics(probe); priorDate = Date()
                }
            }
            if !halfwayShot && played >= seconds / 2 { snapshot(app, "\(name)-halfway"); halfwayShot = true }
            if duoFoldControlDirectory != nil, playID == "readPlayPauseButton", paused,
               duoFoldStages.count < 2,
               played >= (duoFoldStages.isEmpty ? min(20, seconds / 3) : seconds / 2) {
                let target = duoFoldStages.isEmpty ? "closed" : "open"
                let stageStarted = Date()
                try require(wait(30) { self.metrics(probe)["playing"] as? Bool == true },
                            "Read must be audible before the Duo \(target) request")
                let before = metrics(probe)
                var stage = try requestDuoFold(app, source: name, phase: "read-\(target)",
                                              target: target, before: before)
                try require(wait(30) {
                    let current = self.metrics(probe)
                    return current["playing"] as? Bool == true &&
                        (!(current["segment"] as? String ?? "").isEmpty) &&
                        (current["segment"] as? String != before["segment"] as? String ||
                         (current["time"] as? Double ?? 0) > (before["time"] as? Double ?? 0) + 0.1)
                }, "Duo \(target) stopped Read or lost its live audio clock")
                let after = metrics(probe)
                try require(after["sourceKind"] as? String == before["sourceKind"] as? String &&
                            after["mode"] as? String == before["mode"] as? String,
                            "Duo \(target) replaced the reading source or mode")
                try require((after["readError"] as? String ?? "").isEmpty,
                            "Read failed after Duo \(target)")
                stage["after"] = after
                duoFoldStages.append(stage)
                snapshot(app, "\(name)-duo-\(target)")
                // Handshake time is extra evidence, not credited toward the
                // existing minimum of directly observed live playing seconds.
                deadline = deadline.addingTimeInterval(Date().timeIntervalSince(stageStarted))
                prior = after; priorDate = Date(); lastProgress = Date()
            }
        }
        try require(played >= seconds, "insufficient actual playing time: \(played)")
        try require(paused, "pause and resume were not exercised during audible playback")
        try require(segments.count > 1, "no segment transition")
        if name.hasSuffix("explain") {
            try require(captions.count > 1, "Explain captions did not advance")
            try require(maximumMarks > 0, "Explain did not resolve any original-text marks")
        } else {
            try require(highlights.count > 1, "Read highlight cursor did not advance")
            if duoFoldControlDirectory != nil {
                try require(duoFoldStages.count == 2, "Both actual Duo Read fold stages must finish")
            }
        }
        snapshot(app, "\(name)-three-minutes")
        return ["effectivePlayingSeconds": played, "pauseResume": paused, "segmentsVisited": segments.count,
            "paragraphsVisited": paragraphs.sorted(), "captionChanges": captions.count,
            "highlightChanges": highlights.count, "maximumMarks": maximumMarks, "samples": samples,
            "duoFoldStages": duoFoldStages]
    }

    /// Only the parent operates the simulator's fold control. A unique request
    /// prevents an old acknowledgement from passing a later document or stage.
    private func requestDuoFold(_ app: XCUIApplication, source: String, phase: String,
                                target: String, before: [String: Any]) throws -> [String: Any] {
        guard let path = duoFoldControlDirectory else {
            throw NSError(domain: "ReaderAcceptance", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Duo control directory missing"])
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let requestID = UUID().uuidString
        let beforeFrame = app.windows.firstMatch.frame
        try require(beforeFrame.width.isFinite && beforeFrame.height.isFinite &&
                    beforeFrame.width > 0 && beforeFrame.height > 0, "Duo window has no usable size before folding")
        var request: [String: Any] = ["requestID": requestID, "source": source,
            "phase": phase, "target": target, "before": before,
            "windowBefore": String(describing: beforeFrame)]
        try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("request.json"), options: .atomic)
        var acknowledgement: [String: Any] = [:]
        let acknowledged = wait(180) {
            guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("ack.json")),
                  let value = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  value["requestID"] as? String == requestID,
                  value["target"] as? String == target else { return false }
            acknowledgement = value
            return true
        }
        try require(acknowledged, "Actual Duo \(phase) was not acknowledged within 180 seconds")
        try require(acknowledgement["error"] == nil,
                    "Duo fold controller failed: \(acknowledgement["error"] ?? "")")
        try require(acknowledgement["completed"] as? Bool == true, "Duo controller did not complete the physical fold")
        try require(wait(15) {
            let window = app.windows.firstMatch
            guard window.exists else { return false }
            let frame = window.frame
            return frame.width.isFinite && frame.height.isFinite && frame.width > 0 && frame.height > 0 &&
                (abs(frame.width - beforeFrame.width) > 2 || abs(frame.height - beforeFrame.height) > 2)
        }, "Duo acknowledgement did not produce a different app window size")
        request["acknowledgement"] = acknowledgement
        request["windowAfter"] = String(describing: app.windows.firstMatch.frame)
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys]),
                                      uniformTypeIdentifier: "public.json")
        attachment.name = "\(source)-\(phase)-fold-handshake.json"
        attachment.lifetime = .keepAlways
        add(attachment)
        return request
    }

    private func verifyDuoExplainMinimizeAndReopen(_ app: XCUIApplication, probe: XCUIElement,
                                                  source: String) throws -> [String: Any] {
        let play = app.buttons["explainPlayPauseButton"].firstMatch
        try require(wait(30) { play.exists && play.isHittable && play.isEnabled && self.metrics(probe)["playing"] as? Bool == true },
                    "Explain must still be playing before the paused fold check")
        play.tap()
        try require(wait(8) { self.metrics(probe)["playing"] as? Bool == false }, "Explain pause failed before folding")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        let paused = metrics(probe)
        try require(!(paused["segment"] as? String ?? "").isEmpty, "Paused Explain has no audio segment")
        app.buttons["readerMinimizeButton"].tap()
        let expand = app.buttons["readerMiniPlayerExpand"]
        try require(wait(10) { expand.exists && expand.isHittable }, "Paused Explain mini player missing")
        var closed = try requestDuoFold(app, source: source, phase: "explain-minimized-closed",
                                        target: "closed", before: paused)
        try require(wait(10) { expand.exists && expand.isHittable }, "Fold hid the existing mini player")
        expand.tap()
        try require(wait(15) { play.exists && play.isHittable }, "Explain controls missing after reopening")
        try requirePausedDuoExplain(probe, matches: paused)
        closed["after"] = metrics(probe)
        snapshot(app, "\(source)-explain-reopened-closed")
        var opened = try requestDuoFold(app, source: source, phase: "explain-paused-open",
                                        target: "open", before: metrics(probe))
        try requirePausedDuoExplain(probe, matches: paused)
        opened["after"] = metrics(probe)
        snapshot(app, "\(source)-explain-paused-open")
        play.tap()
        try require(wait(30) {
            let current = self.metrics(probe)
            return current["playing"] as? Bool == true &&
                (current["segment"] as? String != paused["segment"] as? String ||
                 (current["time"] as? Double ?? 0) > (paused["time"] as? Double ?? 0) + 0.1)
        }, "Explain did not resume after the fold round trip")
        snapshot(app, "\(source)-explain-resumed-open")
        play.tap()
        try require(wait(8) { self.metrics(probe)["playing"] as? Bool == false }, "Explain did not pause after acceptance")
        return ["stages": [closed, opened], "resumed": true]
    }

    private func requirePausedDuoExplain(_ probe: XCUIElement, matches expected: [String: Any]) throws {
        try require(wait(10) {
            let current = self.metrics(probe)
            return current["playing"] as? Bool == false &&
                current["mode"] as? String == expected["mode"] as? String &&
                current["sourceKind"] as? String == expected["sourceKind"] as? String &&
                current["segment"] as? String == expected["segment"] as? String &&
                current["block"] as? Int == expected["block"] as? Int &&
                current["marks"] as? Int == expected["marks"] as? Int &&
                abs((current["time"] as? Double ?? -10) - (expected["time"] as? Double ?? 0)) < 0.5
        }, "Paused Explain lost its mode, segment, block, marks or audio position across Duo folding")
    }


    func testEveryLanguageReadAndExplainMainFlow() throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CASTREADER_READER_ACCEPTANCE_MANIFEST"] else {
            throw XCTSkip("Opt-in fixture manifest required")
        }
        let all = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: String]]
        let selected = env["CASTREADER_READER_ACCEPTANCE_LANGUAGES"]?.split(separator: ",").map(String.init)
        let explainEnabled = env["CASTREADER_READER_ACCEPTANCE_EXPLAIN"] == "1"
        XCUIDevice.shared.orientation = .portrait
        var results: [[String: Any]] = []
        for row in all where selected == nil || selected!.contains(row["language"]!) {
            let language = row["language"]!, text = row["text"]!, locale = row["locale"]!
            let expectedName = Locale(identifier: "en").localizedString(forIdentifier: locale)!
            let app = XCUIApplication()
            let start = Date()
            var result: [String: Any] = ["language": language, "source": row["source"]!, "characters": text.count]
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
                "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate", "-CastReaderMultilingualAcceptance",
                "-explain_language", "", "-CastReaderCaptureTextB64", Data(text.utf8).base64EncodedString()]
            app.launch()
            do {
                let play = app.buttons["readPlayPauseButton"].firstMatch
                try require(play.waitForExistence(timeout: 35), "reader missing")
                let probe = app.descendants(matching: .any)["readerLanguagePlaybackMetrics"].firstMatch
                try require(probe.waitForExistence(timeout: 10), "playback metrics missing")
                // Repeat runs must start at the first paragraph, using the same
                // tap-to-read action as a reader instead of restoring an old tail.
                let firstParagraph = app.descendants(matching: .any)["readerParagraph.0"].firstMatch
                try require(firstParagraph.waitForExistence(timeout: 10), "first paragraph missing")
                firstParagraph.tap()
                let notice = app.staticTexts["readerPlaybackFailureNotice"]
                try require(wait(60) { (play.value as? String)?.lowercased() == "playing" || notice.exists }, "read did not start")
                let correctionNeeded = notice.exists
                result["automaticLanguage"] = correctionNeeded ? "uncertain; explicitly selected" : "resolved"
                if (play.value as? String)?.lowercased() == "playing" {
                    snapshot(app, "\(language)-read-playing")
                    play.tap()
                    try require(wait(5) { (play.value as? String)?.lowercased() == "paused" }, "read pause failed")
                    snapshot(app, "\(language)-read-paused")
                }
                let voice = app.buttons["playbackVoiceButton"].firstMatch
                try require(voice.waitForExistence(timeout: 8), "voice control missing")
                voice.tap()
                if correctionNeeded {
                    let search = app.searchFields["Search Languages"]
                    try require(search.waitForExistence(timeout: 8), "language correction picker missing")
                    search.tap(); search.typeText(locale)
                    let languageRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", locale)).firstMatch
                    try require(languageRow.waitForExistence(timeout: 8), "correction language missing")
                    languageRow.tap()
                    // Unknown-language correction returns directly to the reader.
                } else {
                    let languageControl = app.buttons["Reading Language"].firstMatch
                    try require(languageControl.waitForExistence(timeout: 8), "voice language missing")
                    result["detectedLanguageName"] = languageControl.value as? String ?? ""
                    try require(expectedName.hasPrefix(languageControl.value as? String ?? "UNRESOLVED"),
                                "wrong route: \(languageControl.value as? String ?? "none") != \(expectedName)")
                    let done = app.buttons["playbackVoiceDoneButton"].firstMatch
                    try require(done.waitForExistence(timeout: 5), "voice Done missing")
                    done.tap()
                }
                try require(play.waitForExistence(timeout: 8), "reader did not return")
                if (play.value as? String)?.lowercased() != "playing" { play.tap() }
                try require(wait(60) { (play.value as? String)?.lowercased() == "playing" }, "read resume failed")
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                snapshot(app, "\(language)-read-resumed")
                try require(wait(150) { self.metrics(probe)["readFinished"] as? Bool == true || notice.exists }, "read completion missing")
                try require(!notice.exists, "reader failed before completion")
                snapshot(app, "\(language)-read-completed")
                result["read"] = "passed: played, paused/resumed, returned to stopped controls without error"
                if explainEnabled {
                    let picker = app.segmentedControls["readerModePicker"]
                    if picker.exists { picker.buttons["Explain"].tap() }
                    else { app.buttons["readerModeMenu"].tap(); app.buttons["Explain"].firstMatch.tap() }
                    let startButton = app.buttons["explainStartButton"].firstMatch
                    try require(startButton.waitForExistence(timeout: 10), "Explain start missing")
                    startButton.tap()
                    let explainPlay = app.buttons["explainPlayPauseButton"].firstMatch
                    let error = app.staticTexts["readerExplainError"]
                    try require(wait(120) { (explainPlay.exists && (explainPlay.value as? String)?.lowercased() == "playing") || error.exists }, "Explain did not start")
                    try require(!error.exists, "Explain error: \(error.exists ? error.label : "")")
                    // The floating caption has a zero-height layout anchor and
                    // is visible in screenshots but omitted by XCTest's tree.
                    try require(wait(10) { !(self.metrics(probe)["caption"] as? String ?? "").isEmpty }, "Explain caption missing")
                    result["firstCaption"] = self.metrics(probe)["caption"]
                    snapshot(app, "\(language)-explain-playing")
                    explainPlay.tap()
                    try require(wait(5) { (explainPlay.value as? String)?.lowercased() == "paused" }, "Explain pause failed")
                    explainPlay.tap()
                    try require(wait(20) { (explainPlay.value as? String)?.lowercased() == "playing" }, "Explain resume failed")
                    RunLoop.current.run(until: Date().addingTimeInterval(4))
                    snapshot(app, "\(language)-explain-marks")
                    let replay = app.buttons["explainReplayButton"].firstMatch
                    try require(wait(180) { replay.exists || error.exists }, "Explain completion missing")
                    try require(replay.exists && !error.exists, "Explain failed before completion")
                    snapshot(app, "\(language)-explain-completed")
                    result["explain"] = "passed: real narration, caption, pause/resume and replay available"
                }
                result["status"] = "passed"
            } catch {
                result["status"] = "failed"; result["error"] = String(describing: error)
                snapshot(app, "\(language)-failure")
                XCTFail("\(language): \(error)")
            }
            result["elapsedSeconds"] = Date().timeIntervalSince(start)
            results.append(result)
            let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), uniformTypeIdentifier: "public.json")
            attachment.name = "reader-main-flow-\(language).json"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
        XCTAssertFalse(results.isEmpty)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "ReaderAcceptance", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < end
        return condition()
    }
    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let screenshot = app.screenshot()
        if let report = ProcessInfo.processInfo.environment["CASTREADER_LONG_REPORT"] {
            let directory = URL(fileURLWithPath: report).deletingLastPathComponent().appendingPathComponent("screenshots")
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try screenshot.pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
            } catch { XCTFail("Could not preserve acceptance screenshot: \(error)") }
        }
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

/// Real catalog/UI checks. Never replaces account state or entitlement data.
final class VoiceAlignmentLiveUITests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        guard let path = ProcessInfo.processInfo.environment["CASTREADER_VOICE_ALIGNMENT_REPORT"] else {
            throw XCTSkip("Opt-in report directory required")
        }
        directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    override func tearDownWithError() throws {
        if let directory, (testRun?.totalFailureCount ?? 0) > 0 {
            let app = XCUIApplication()
            guard app.state != .notRunning else { return }
            try? save(app, "failure-" + name.components(separatedBy: " ").last!.replacingOccurrences(of: "]", with: ""))
            try? JSONSerialization.data(withJSONObject: metrics(app), options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("failure-last-metrics.json"))
        }
    }
    private func save(_ app: XCUIApplication, _ name: String) throws {
        try app.screenshot().pngRepresentation.write(to: directory.appendingPathComponent(name + ".png"))
        try app.debugDescription.write(to: directory.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
    }
    private func launch(_ language: String, title: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", language,
            "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate", "-CastReaderRegion", "global", "-CastReaderServiceRoute", "global"]
        app.launch()
        let tab = app.tabBars.buttons[title].exists ? app.tabBars.buttons[title] : app.buttons[title].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20))
        tab.tap()
        XCTAssertTrue(app.descendants(matching: .any)["voiceBrowseLanguage"].firstMatch.waitForExistence(timeout: 15))
        return app
    }
    /// The app language is changed through iOS preferences while the region
    /// remains US. This catches using Locale.current to choose a voice language.
    func testAllTwentyEightSystemAppLanguagesSelectMatchingVoices() throws {
        let cases: [(String, String, String)] = [
            ("en", "en-US", "Voice"),
            ("zh-Hans", "zh-CN", "音色"),
            ("ja", "ja-JP", "音声"),
            ("es", "es-ES", "Voz"),
            ("fr", "fr-FR", "Voix"),
            ("pt-BR", "pt-BR", "Voz"),
            ("it", "it-IT", "Voce"),
            ("hi", "hi-IN", "आवाज़"),
            ("de", "de-DE", "Stimme"),
            ("nl", "nl-NL", "Stem"),
            ("ko", "ko-KR", "음성"),
            ("ar", "ar-XA", "الصوت"),
            ("ru", "ru-RU", "Голос"),
            ("pl", "pl-PL", "Głos"),
            ("sv", "sv-SE", "Röst"),
            ("da", "da-DK", "Stemme"),
            ("nb", "nb-NO", "Stemme"),
            ("fi", "fi-FI", "Ääni"),
            ("cs", "cs-CZ", "Hlas"),
            ("el", "el-GR", "Φωνή"),
            ("hu", "hu-HU", "Hang"),
            ("fil", "fil-PH", "Boses"),
            ("he", "he-IL", "קול"),
            ("id", "id-ID", "Suara"),
            ("ms", "ms-MY", "Suara"),
            ("ro", "ro-RO", "Voce"),
            ("tr", "tr-TR", "Ses"),
            ("vi", "vi-VN", "Giọng đọc")
        ]
        for (language, locale, title) in cases {
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US",
                "-interfaceLanguage", "system", "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate",
                "-CastReaderRegion", "global", "-CastReaderServiceRoute", "global"]
            app.launch()
            let tab = app.tabBars.buttons[title].exists ? app.tabBars.buttons[title] : app.buttons[title].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 20), language)
            try save(app, "system-" + language + "-home")
            tab.tap()
            let selector = app.buttons["voiceBrowseLanguage"]
            let expected = Locale(identifier: language).localizedString(forIdentifier: locale)!
            XCTAssertTrue(wait(25) {
                guard let value = selector.value as? String, !value.isEmpty else { return false }
                return expected.localizedCaseInsensitiveContains(value)
            }, "\(language): \(selector.value ?? "missing") != \(expected)")
            XCTAssertTrue(app.descendants(matching: .any)["voiceCurrentCard"].firstMatch.waitForExistence(timeout: 30))
            try save(app, "system-" + language + "-voices")
            let tabs = app.segmentedControls["voiceBrowserCategoryPicker"]
            XCTAssertEqual(tabs.buttons.count, 2)
            tabs.buttons.element(boundBy: 1).tap()
            try save(app, "system-" + language + "-my-voices")
            app.buttons["settingsGearButton"].tap()
            XCTAssertTrue(app.buttons["settingsLanguageLink"].waitForExistence(timeout: 10))
            try save(app, "system-" + language + "-settings")
            app.terminate()
        }
    }

    func testChangingAppLanguageToKoreanResetsPreviouslyChosenVoiceLanguage() throws {
        let app = launch("en", title: "Voice")
        app.buttons["voiceBrowseLanguage"].tap()
        let search = app.searchFields["Search Languages"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Finnish")
        app.buttons["voiceBrowseLanguage.fi"].tap()
        XCTAssertTrue(wait(10) { (app.buttons["voiceBrowseLanguage"].value as? String ?? "").contains("Finnish") })
        app.buttons["settingsGearButton"].tap()
        app.buttons["settingsLanguageLink"].tap()
        let korean = app.buttons["appLanguage.ko"]
        for _ in 0..<5 where !korean.isHittable { app.swipeUp() }
        XCTAssertTrue(korean.isHittable); korean.tap()
        try save(app, "in-app-korean-language-selected")
        app.navigationBars["언어"].buttons["BackButton"].tap()
        app.buttons["settingsCloseButton"].tap()
        XCTAssertTrue(wait(15) { (app.buttons["voiceBrowseLanguage"].value as? String ?? "").contains("한국어") })
        XCTAssertEqual(app.buttons["settingsGearButton"].firstMatch.label, "계정 및 설정")
        try save(app, "in-app-korean-voices")
        app.buttons["홈"].firstMatch.tap()
        XCTAssertEqual(app.buttons["scenario-paper"].label, "논문 / 학술")
        XCTAssertFalse(app.staticTexts["Paste a video link"].exists)
        try save(app, "in-app-korean-home")
        app.terminate()
    }

    /// Read starts real regular TTS. Explain opens its actual pinned panel using
    /// its output-language setting; prior long-play evidence covers generation.
    func testTwentyEightReaderVoicePanelsFollowNarrationLanguage() throws {
        let path = try XCTUnwrap(ProcessInfo.processInfo.environment["CASTREADER_READER_ACCEPTANCE_MANIFEST"])
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [[String: String]]
        let filter = ProcessInfo.processInfo.environment["CASTREADER_VOICE_UI_LANGUAGES"]?.split(separator: ",").map(String.init)
        for row in rows where filter == nil || filter!.contains(row["language"]!) {
            let code = row["language"]!, locale = row["locale"]!, text = row["text"]!
            let app = XCUIApplication()
            app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
                "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate", "-CastReaderMultilingualAcceptance",
                "-CastReaderRegion", "global", "-CastReaderServiceRoute", "global", "-explain_language", code,
                "-CastReaderCaptureTextB64", Data(text.utf8).base64EncodedString()]
            app.launch()
            let play = app.buttons["readPlayPauseButton"].firstMatch
            XCTAssertTrue(play.waitForExistence(timeout: 30)); play.tap()
            let notice = app.staticTexts["readerPlaybackFailureNotice"]
            XCTAssertTrue(wait(65) { (play.value as? String)?.lowercased() == "playing" || notice.exists }, code)
            if notice.exists {
                XCTAssertEqual(notice.label, "Cannot identify the text language. Choose a reading language.")
                // Ambiguous short samples use the same explicit correction
                // available to users; never force a language through a fixture.
                try save(app, "reader-" + code + "-language-correction-required")
                app.buttons["playbackVoiceButton"].firstMatch.tap()
                let search = app.searchFields["Search Languages"]
                XCTAssertTrue(search.waitForExistence(timeout: 10))
                search.tap(); search.typeText(locale)
                let target = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", locale)).firstMatch
                XCTAssertTrue(target.waitForExistence(timeout: 10)); target.tap()
                XCTAssertTrue(wait(65) {
                    let value = self.metrics(app)
                    let state = value["readStartState"] as? [String: Any] ?? [:]
                    return value["playing"] as? Bool == true ||
                        (state["hasQueuedSegments"] as? Bool == true && state["loading"] as? Bool == false && state["streaming"] as? Bool == false)
                }, code)
                if (play.value as? String)?.lowercased() != "playing" { play.tap() }
                XCTAssertTrue(wait(65) { (play.value as? String)?.lowercased() == "playing" }, code)
            }
            let voice = app.buttons["playbackVoiceButton"].firstMatch
            XCTAssertTrue(voice.waitForExistence(timeout: 10)); voice.tap()
            let panel = try XCTUnwrap(app.otherElements.matching(identifier: "playbackVoicePanel").allElementsBoundByIndex.last)
            let selector = panel.buttons["voiceBrowseLanguage"].firstMatch
            let expected = Locale(identifier: "en").localizedString(forIdentifier: locale)!
            XCTAssertTrue(wait(15) {
                guard let value = selector.value as? String, !value.isEmpty else { return false }
                return expected.localizedCaseInsensitiveContains(value)
            }, "Wrong read voice panel for \(code): \(selector.value ?? "missing")")
            try save(app, "reader-" + code + "-read-voice-panel")
            app.buttons["playbackVoiceDoneButton"].tap()
            if (play.value as? String)?.lowercased() == "playing" { play.tap() }
            app.segmentedControls["readerModePicker"].buttons["Explain"].tap()
            XCTAssertTrue(voice.waitForExistence(timeout: 10)); voice.tap()
            let pinned = panel.descendants(matching: .any)["voiceBrowseLanguage"].firstMatch
            XCTAssertTrue(wait(15) {
                guard let value = pinned.value as? String, !value.isEmpty else { return false }
                return expected.localizedCaseInsensitiveContains(value)
            }, "Wrong explain voice panel for \(code): \(pinned.value ?? "missing")")
            XCTAssertFalse(panel.buttons["Reading Language"].exists)
            try save(app, "reader-" + code + "-explain-voice-panel")
            app.terminate()
        }
    }

    func testVoiceLayoutAcrossLanguagesAndSearch() throws {
        let allCases = [("en", "Voice"), ("zh-Hans", "音色"), ("ko", "음성"), ("ru", "Голос"),
                     ("fi", "Ääni"), ("tr", "Ses"), ("it", "Voce"), ("ar", "الصوت"),
                     ("he", "קול"), ("de", "Stimme"), ("ja", "音声"), ("vi", "Giọng đọc"),
                     ("fr", "Voix"), ("es", "Voz"), ("pt-BR", "Voz")]
        let filter = ProcessInfo.processInfo.environment["CASTREADER_VOICE_UI_LANGUAGES"]?.split(separator: ",").map(String.init)
        let cases = allCases.filter { filter == nil || filter!.contains($0.0) }
        for (language, title) in cases {
            let app = launch(language, title: title)
            XCTAssertTrue(app.descendants(matching: .any)["voiceCurrentCard"].firstMatch.waitForExistence(timeout: 35))
            let picker = app.segmentedControls["voiceBrowserCategoryPicker"]
            XCTAssertEqual(picker.buttons.count, 2)
            XCTAssertFalse(app.textFields["voiceSearchField"].exists)
            if ["en", "zh-Hans", "ko", "ru", "de", "ja", "fr", "es", "pt-BR"].contains(language) {
                XCTAssertTrue(app.buttons["voiceFeaturedClones"].waitForExistence(timeout: 20), language)
            }
            if ["fi", "tr"].contains(language) {
                XCTAssertFalse(app.buttons["voiceSearchToggle"].exists, "Sparse voices must not have empty filters")
                let selects = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "presetVoiceSelect_"))
                let ids = selects.allElementsBoundByIndex.map(\.identifier)
                XCTAssertEqual(ids.count, Set(ids).count, "Current voice must not be duplicated")
            }
            if language == "fi" {
                XCTAssertFalse(app.buttons["voiceBrowseAll"].exists)
            }
            try save(app, "voice-" + language)
            if language == "en" {
                let toggle = app.buttons["voiceSearchToggle"]
                toggle.tap()
                let search = app.textFields["voiceSearchField"]
                XCTAssertTrue(search.waitForExistence(timeout: 5))
                search.tap(); search.typeText("Heart")
                XCTAssertTrue(app.buttons["voiceDiscoveryFilters"].exists)
                try save(app, "voice-en-search")
                toggle.tap()
                XCTAssertFalse(search.exists)
                XCTAssertTrue(app.descendants(matching: .any)["voiceCurrentCard"].firstMatch.waitForExistence(timeout: 10))
                let created = picker.buttons.element(boundBy: 1)
                created.tap()
                try save(app, "voice-en-my-voices")
                picker.buttons.element(boundBy: 0).tap()
                XCTAssertTrue(app.descendants(matching: .any)["voiceCurrentCard"].firstMatch.waitForExistence(timeout: 10))
            }
            app.terminate()
        }
    }
    func testBrowseLanguageContextAndChinaBoundary() throws {
        var app = launch("en", title: "Voice")
        XCTAssertTrue(app.descendants(matching: .any)["voiceCurrentCard"].firstMatch.waitForExistence(timeout: 35))
        app.buttons["voiceBrowseLanguage"].tap()
        let languageSearch = app.searchFields["Search Languages"]
        XCTAssertTrue(languageSearch.waitForExistence(timeout: 10))
        languageSearch.tap(); languageSearch.typeText("Finnish")
        let finnish = app.buttons["voiceBrowseLanguage.fi"]
        XCTAssertTrue(finnish.waitForExistence(timeout: 10)); finnish.tap()
        XCTAssertTrue(wait(10) { (app.buttons["voiceBrowseLanguage"].value as? String ?? "").contains("Finnish") })
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", "Default voice for", "Finnish")).firstMatch.exists)
        try save(app, "context-en-ui-fi-voices")
        app.terminate()
        app = launch("en", title: "Voice")
        XCTAssertTrue(wait(10) { (app.buttons["voiceBrowseLanguage"].value as? String ?? "").contains("Finnish") })
        try save(app, "context-en-relaunch-keeps-fi")
        app.terminate()
        for (language, title, expected) in [("de", "Stimme", "Deutsch"), ("vi", "Giọng đọc", "Tiếng Việt")] {
            app = launch(language, title: title)
            XCTAssertTrue(wait(20) { (app.buttons["voiceBrowseLanguage"].value as? String ?? "").localizedCaseInsensitiveContains(expected) })
            try save(app, "context-app-reset-" + language)
            app.terminate()
        }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
            "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate", "-CastReaderRegion", "cn", "-CastReaderServiceRoute", "cn"]
        app.launch()
        let voiceTab = app.tabBars.buttons["Voice"].exists ? app.tabBars.buttons["Voice"] : app.buttons["Voice"].firstMatch
        XCTAssertTrue(voiceTab.waitForExistence(timeout: 20)); voiceTab.tap()
        XCTAssertTrue(app.buttons["voiceBrowseLanguage"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.descendants(matching: .any)["voiceCurrentCard"].firstMatch.exists)
        try save(app, "cn-original-voice-page")
        app.buttons["voiceBrowseLanguage"].tap()
        let cnSearch = app.searchFields["Search Languages"]
        XCTAssertTrue(cnSearch.waitForExistence(timeout: 10)); cnSearch.tap(); cnSearch.typeText("Finnish")
        XCTAssertFalse(app.buttons["voiceBrowseLanguage.fi"].exists)
        try save(app, "cn-no-added-language")
        app.terminate()
    }

    func testFullPrivateLibraryRemainsVisibleForUnsupportedBrowseLanguage() throws {
        let app = launch("en", title: "Voice")
        let picker = app.segmentedControls["voiceBrowserCategoryPicker"]
        picker.buttons.element(boundBy: 1).tap()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voiceCloneApplyButton_"))
        XCTAssertTrue(wait(35) { rows.count > 3 })
        var identifiers = Set<String>()
        for _ in 0..<5 {
            identifiers.formUnion(rows.allElementsBoundByIndex.map(\.identifier))
            app.swipeUp()
        }
        XCTAssertGreaterThan(identifiers.count, 6)
        try save(app, "private-full-library-beyond-six")
        for _ in 0..<8 where !app.buttons["voiceBrowseLanguage"].isHittable { app.swipeDown() }
        app.buttons["voiceBrowseLanguage"].tap()
        let search = app.searchFields["Search Languages"]
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Finnish")
        app.buttons["voiceBrowseLanguage.fi"].tap()
        XCTAssertTrue(wait(15) { rows.count > 3 })
        XCTAssertTrue(rows.allElementsBoundByIndex.allSatisfy { !$0.isEnabled })
        XCTAssertFalse(app.buttons["voiceCloneCreateButton"].exists)
        XCTAssertFalse(app.buttons["voiceCloneQuotaCard"].exists)
        let preview = app.buttons["Preview"].firstMatch
        XCTAssertTrue(preview.exists && preview.isEnabled)
        try save(app, "private-finnish-retains-library-disabled-apply")
        preview.tap()
        let stop = app.buttons["Stop Preview"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 30))
        try save(app, "private-incompatible-fixed-preview")
        stop.tap()
        app.terminate()
    }

    func testLargeTypeVoiceControlsRemainReachable() throws {
        for (language, title) in [("de", "Stimme"), ("ar", "الصوت"), ("he", "קול")] {
            let app = launch(language, title: title)
            let languageButton = app.buttons["voiceBrowseLanguage"]
            XCTAssertTrue(languageButton.isHittable)
            XCTAssertEqual(app.segmentedControls["voiceBrowserCategoryPicker"].buttons.count, 2)
            let card = app.descendants(matching: .any)["voiceCurrentCard"].firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 35))
            try save(app, "large-type-" + language)
            let searchToggle = app.buttons["voiceSearchToggle"]
            if searchToggle.exists {
                XCTAssertTrue(searchToggle.isHittable); searchToggle.tap()
                let search = app.textFields["voiceSearchField"]
                XCTAssertTrue(search.waitForExistence(timeout: 10))
                XCTAssertTrue(search.isHittable)
                try save(app, "large-type-search-" + language)
                searchToggle.tap()
            }
            app.swipeUp()
            try save(app, "large-type-scroll-" + language)
            app.terminate()
        }
    }

    private func wait(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        } while Date() < deadline
        return condition()
    }
    private func metrics(_ app: XCUIApplication) -> [String: Any] {
        let probe = app.descendants(matching: .any)["readerLanguagePlaybackMetrics"].firstMatch
        guard let raw = probe.value as? String, let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, limit: Int = 18) {
        for _ in 0..<limit {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }
    func testCompleteCloneCollectionSearchAndPreviewCancellation() throws {
        let app = launch("ko", title: "음성")
        let featured = app.buttons["voiceFeaturedClones"]
        XCTAssertTrue(featured.waitForExistence(timeout: 25)); featured.tap()
        let search = app.textFields["voiceSearchField"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        var ids = Set<String>()
        for _ in 0..<5 {
            ids.formUnion(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "presetVoiceSelect_")).allElementsBoundByIndex.map(\.identifier))
            app.swipeUp()
        }
        XCTAssertGreaterThan(ids.count, 6)
        try save(app, "ko-clones-beyond-six")
        for _ in 0..<6 { app.swipeDown() }
        search.tap(); search.typeText("vl_d1efb23a380bdaa2f6b0")
        XCTAssertTrue(wait(10) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "presetVoiceSelect_")).count == 0 })
        try save(app, "ko-clones-no-english-source")
        app.buttons["지우기"].firstMatch.tap()
        XCTAssertTrue(wait(10) { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voicePreview_")).count > 0 })
        let preview = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voicePreview_")).firstMatch
        preview.tap()
        XCTAssertTrue(wait(30) { ["loading", "playing"].contains((preview.value as? String ?? "").lowercased()) })
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(featured.waitForExistence(timeout: 8))
        try save(app, "ko-clone-preview-returned")
        app.terminate()
    }
    func testLiveReaderRegularPublicPrivateSwitchAndPreviewRestoration() throws {
        let app = XCUIApplication()
        let paragraph = "A reading routine works best when attention has a clear place to return to. Listening while following the words can make an unfamiliar passage easier to understand. The reader can pause, consider the argument, and then continue at the same place. A change of voice should preserve that place and keep the spoken words connected to the text."
        let text = Array(repeating: paragraph, count: 9).joined(separator: "\n\n") + "\n\nAcceptance run " + UUID().uuidString
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
            "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate", "-CastReaderMultilingualAcceptance",
            "-CastReaderRegion", "global", "-CastReaderServiceRoute", "global", "-explain_language", "en",
            "-CastReaderCaptureTextB64", Data(text.utf8).base64EncodedString()]
        app.launch()
        let play = app.buttons["readPlayPauseButton"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 40))
        XCTAssertTrue(wait(40) {
            (self.metrics(app)["readStartState"] as? [String: Any])?["isPro"] as? Bool == true
        }, "Wait for the existing signed-in account to finish restoring before playback")
        if metrics(app)["playing"] as? Bool != true { play.tap() }
        XCTAssertTrue(wait(80) { self.metrics(app)["playing"] as? Bool == true })
        let originalVoice = metrics(app)["readVoiceID"] as? String ?? "af_heart"
        var evidence: [[String: Any]] = []
        let voicePanel = app.otherElements.matching(identifier: "playbackVoicePanel")
            .containing(.button, identifier: "playbackVoiceDoneButton").firstMatch
        func panel() {
            app.buttons["playbackVoiceButton"].firstMatch.tap()
            XCTAssertTrue(app.buttons["playbackVoiceDoneButton"].waitForExistence(timeout: 10))
            XCTAssertFalse(voicePanel.buttons["voiceFeaturedClones"].exists)
            XCTAssertFalse(voicePanel.buttons["voiceFamiliarSelf"].exists)
        }
        func close() { app.buttons["playbackVoiceDoneButton"].tap() }
        func verify(_ label: String, voice: String, mode: String = "read") throws {
            XCTAssertTrue(wait(90) { self.metrics(app)["playing"] as? Bool == true && self.metrics(app)[mode + "VoiceID"] as? String == voice }, label)
            let before = metrics(app)
            XCTAssertTrue(wait(45) {
                let current = self.metrics(app)
                return current["playing"] as? Bool == true &&
                    ((before["segment"] as? String != current["segment"] as? String) ||
                     (current["time"] as? Double ?? 0) > (before["time"] as? Double ?? 0) + 1)
            }, label)
            let visualKey = mode == "read" ? "highlight" : "caption"
            XCTAssertTrue(wait(15) { !(self.metrics(app)[visualKey] as? String ?? "").isEmpty }, label)
            let after = metrics(app)
            XCTAssertTrue((after[mode + "Error"] as? String ?? "").isEmpty)
            evidence.append(["step": label, "metrics": after])
            try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("reader-voice-live-results.json"))
            try save(app, "reader-" + label)
        }
        try verify("regular-start", voice: originalVoice)
        panel()
        try save(app, "reader-voice-panel")
        let privateRows = voicePanel.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "voiceFamiliarSelect_"))
        XCTAssertTrue(privateRows.firstMatch.waitForExistence(timeout: 30))
        let privateVoice = String(privateRows.firstMatch.identifier.dropFirst("voiceFamiliarSelect_".count))
        let privatePreview = voicePanel.buttons["voiceFamiliarPreview_" + privateVoice]
        reveal(privatePreview, in: app)
        privatePreview.tap()
        try save(app, "reader-preview-requested")
        var previewStates = Set<String>()
        let previewStarted = wait(45) {
            let value = (privatePreview.value as? String ?? "missing").lowercased()
            previewStates.insert(value)
            return value.contains("playing")
        }
        try JSONSerialization.data(withJSONObject: Array(previewStates).sorted(), options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("private-preview-observed-states.json"))
        try save(app, "reader-preview-outcome")
        XCTAssertTrue(previewStarted)
        XCTAssertTrue(wait(60) { (privatePreview.value as? String)?.lowercased() == "stopped" })
        close()
        try verify("preview-restored", voice: originalVoice)
        play.tap()
        XCTAssertTrue(wait(5) { self.metrics(app)["playing"] as? Bool == false })
        panel(); reveal(privatePreview, in: app); privatePreview.tap()
        XCTAssertTrue(wait(45) { (privatePreview.value as? String)?.lowercased() == "playing" })
        close()
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertFalse(metrics(app)["playing"] as? Bool ?? true)
        panel()
        let privateSelect = voicePanel.buttons["voiceFamiliarSelect_" + privateVoice]
        reveal(privateSelect, in: app); privateSelect.tap()
        XCTAssertTrue(wait(45) { self.metrics(app)["readVoiceID"] as? String == privateVoice }); close()
        play.tap()
        try verify("private-read", voice: privateVoice)
        panel()
        let toggle = voicePanel.buttons["voiceSearchToggle"]
        toggle.tap()
        let search = voicePanel.textFields["voiceSearchField"]
        search.tap(); search.typeText("vl_d1efb23a380bdaa2f6b0")
        let publicSelect = voicePanel.buttons["presetVoiceSelect_vl_d1efb23a380bdaa2f6b0"]
        reveal(publicSelect, in: app); publicSelect.tap()
        XCTAssertTrue(wait(45) { self.metrics(app)["readVoiceID"] as? String == "vl_d1efb23a380bdaa2f6b0" }); close()
        try verify("public-read", voice: "vl_d1efb23a380bdaa2f6b0")
        // Explicit pause survives a change back to the regular voice.
        play.tap(); panel(); toggle.tap(); search.tap(); search.typeText(originalVoice)
        let regular = voicePanel.buttons["presetVoiceSelect_" + originalVoice]
        reveal(regular, in: app); regular.tap(); close()
        XCTAssertFalse(metrics(app)["playing"] as? Bool ?? true)
        play.tap(); try verify("regular-return", voice: originalVoice)
        play.tap()
        app.segmentedControls["readerModePicker"].buttons["Explain"].tap()
        app.buttons["explainStartButton"].tap()
        try verify("regular-explain", voice: originalVoice, mode: "explain")
        app.buttons["explainPlayPauseButton"].firstMatch.tap()
        panel(); reveal(privateSelect, in: app); privateSelect.tap()
        XCTAssertTrue(wait(45) { self.metrics(app)["explainVoiceID"] as? String == privateVoice }); close()
        let explainPlay = app.buttons["explainPlayPauseButton"].firstMatch
        XCTAssertTrue(wait(45) { explainPlay.isEnabled })
        explainPlay.tap()
        try verify("private-explain", voice: privateVoice, mode: "explain")
        panel()
        let gifted = voicePanel.buttons.matching(NSPredicate(format:
            "identifier BEGINSWITH %@ AND label CONTAINS %@", "voiceFamiliarSelect_", "Friends’ voices")).firstMatch
        XCTAssertTrue(gifted.exists)
        let giftedVoice = String(gifted.identifier.dropFirst("voiceFamiliarSelect_".count))
        // Filter the long live library before tapping. SwiftUI can retain an
        // offscreen row's old accessibility frame during animated scrolling.
        toggle.tap(); search.tap(); search.typeText(giftedVoice)
        let filteredGifted = voicePanel.buttons["voiceFamiliarSelect_" + giftedVoice]
        XCTAssertTrue(filteredGifted.waitForExistence(timeout: 10))
        filteredGifted.tap()
        XCTAssertTrue(wait(45) { self.metrics(app)["explainVoiceID"] as? String == giftedVoice }); close()
        try verify("gifted-explain", voice: giftedVoice, mode: "explain")
        panel(); toggle.tap(); search.tap(); search.typeText(originalVoice)
        reveal(regular, in: app); regular.tap(); close()
        try verify("regular-explain-return", voice: originalVoice, mode: "explain")
        app.buttons["explainPlayPauseButton"].firstMatch.tap()
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("reader-voice-live-results.json"))
        app.terminate()
    }

}

/// Opt-in store capture using the user's already connected Kindle session.
/// Does not seed shelves, entitlements, explanation, audio, or reader marks.
final class LocalizedStoreCaptureUITests: XCTestCase {
    private var output: URL?
    private var currentName = "startup"
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_STORE_CAPTURE"] == "1")
        continueAfterFailure = false
        if let path = ProcessInfo.processInfo.environment["CASTREADER_STORE_OUTPUT"] {
            output = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: output!, withIntermediateDirectories: true)
        }
    }
    override func tearDownWithError() throws {
        if (testRun?.totalFailureCount ?? 0) > 0 { try? snapshot(XCUIApplication(), name: currentName + "-failure") }
    }
    private func wait(_ seconds: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        } while Date() < deadline
        return predicate()
    }
    private func snapshot(_ app: XCUIApplication, name: String) throws {
        let data: Data
        if (ProcessInfo.processInfo.environment["CASTREADER_STORE_DEVICE"] ?? "").hasPrefix("duo") {
            let closed = ProcessInfo.processInfo.environment["CASTREADER_STORE_DEVICE"] == "duo-closed"
            let expectedPoints = closed ? CGSize(width: 466, height: 678) : CGSize(width: 951, height: 669)
            let expectedPixels = closed ? CGSize(width: 1398, height: 2034) : CGSize(width: 2853, height: 2007)
            // An inactive inner framebuffer can retain a valid-sized old image.
            // Require the live app itself to occupy the unfolded landscape surface.
            let frame = app.windows.firstMatch.frame
            guard abs(frame.width - expectedPoints.width) <= 1, abs(frame.height - expectedPoints.height) <= 1 else {
                throw NSError(domain: "DuoStoreCapture", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Set Duo to the requested fold state before capture; actual app frame: \(frame)"])
            }
            // XCUIScreen currently rounds the 669 × 951 point inner display to
            // 2006 × 2852 pixels. Ask the host to capture its native framebuffer,
            // explicitly selecting the inner display; never resize those pixels.
            let output = try XCTUnwrap(output, "Duo capture requires a host output directory")
            let queue = output.appendingPathComponent("capture-requests", isDirectory: true)
            try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
            let token = UUID().uuidString
            let request = queue.appendingPathComponent(token + ".request.json")
            let reply = queue.appendingPathComponent(token + ".response.json")
            try JSONSerialization.data(withJSONObject: ["token": token, "name": name])
                .write(to: request, options: .atomic)
            XCTAssertTrue(wait(45) { FileManager.default.fileExists(atPath: reply.path) },
                "Start store/app-store/duo/capture-host.py before the Duo capture test")
            let response = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: reply)) as? [String: Any])
            XCTAssertEqual(response["token"] as? String, token)
            XCTAssertEqual(response["status"] as? String, "ok", response["error"] as? String ?? "Capture failed")
            data = try Data(contentsOf: queue.appendingPathComponent(token + ".png"))
            let image = try XCTUnwrap(UIImage(data: data))
            XCTAssertEqual(image.cgImage?.width, Int(expectedPixels.width))
            XCTAssertEqual(image.cgImage?.height, Int(expectedPixels.height))
            XCTAssertEqual(image.imageOrientation, .up)
        } else {
            data = XCUIScreen.main.screenshot().pngRepresentation
        }
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        #if targetEnvironment(simulator)
        if let output {
            try data.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
            try app.debugDescription.write(to: output.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        }
        #endif
    }
    private func metrics(_ app: XCUIApplication) -> [String: String] {
        let value = app.descendants(matching: .any)["kindlePlaybackMetrics"].firstMatch.value as? String ?? ""
        #if targetEnvironment(simulator)
        if let output { try? value.write(to: output.appendingPathComponent("current-metrics.txt"), atomically: true, encoding: .utf8) }
        #endif
        return Dictionary(value.split(separator: ";").compactMap { item -> (String, String)? in
            let pair = item.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        }, uniquingKeysWith: { _, last in last })
    }
    func testCaptureFiveScenes() throws {
        let env = ProcessInfo.processInfo.environment
        let languages = (env["CASTREADER_STORE_LANGUAGES"] ?? "en").split(separator: ",").map(String.init)
        let homeLabels = try JSONSerialization.jsonObject(with: Data((env["CASTREADER_STORE_HOME_LABELS"] ?? "{\"en\":\"Home\",\"zh-Hans\":\"首页\"}").utf8)) as! [String:String]
        let deviceProfile = env["CASTREADER_STORE_DEVICE"] ?? "iphone"
        XCTAssertTrue(["iphone", "ipad", "duo", "duo-closed"].contains(deviceProfile))
        let usesExpandedLayout = deviceProfile != "iphone"
        if !deviceProfile.hasPrefix("duo") {
            XCUIDevice.shared.orientation = usesExpandedLayout ? .landscapeLeft : .portrait
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                "-interfaceLanguage", "en", "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate",
                "-CastReaderIPadAcceptance", "-CastReaderRegion", "global", "-CastReaderServiceRoute", "global",
                "-explain_language", "en"]
        if env["CASTREADER_STORE_ATTACH"] != "1" { app.launch() } else { app.activate() }
        if !usesExpandedLayout && env["CASTREADER_STORE_ATTACH"] != "1" {
            let voiceTab = app.buttons["Voice"].firstMatch
            XCTAssertTrue(voiceTab.waitForExistence(timeout: 25)); voiceTab.tap()
            let search = app.textFields["voiceSearchField"].firstMatch
            if !search.exists { app.buttons["voiceSearchToggle"].firstMatch.tap() }
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("af_heart\n")
            let normal = app.buttons["presetVoiceSelect_af_heart"].firstMatch
            XCTAssertTrue(normal.waitForExistence(timeout: 20)); normal.tap()
            app.buttons["Home"].firstMatch.tap()
        }
        for language in languages {
            currentName = language
            let settingsClose = app.buttons["settingsCloseButton"].firstMatch
            if settingsClose.exists && settingsClose.isHittable { settingsClose.tap() }
            let minimize = app.buttons["kindleMinimizeButton"].firstMatch
            if minimize.waitForExistence(timeout: 2) && minimize.isHittable {
                let m = metrics(app)
                if m["playing"] == "true" {
                    let control = m["mode"] == "explain" ? "kindleExplainPlayPauseButton" : "kindleReadPlayPauseButton"
                    app.buttons[control].firstMatch.tap()
                }
                minimize.tap()
            }
            if language != "en" {
                app.buttons["settingsGearButton"].firstMatch.tap()
                let languageLink = app.buttons["settingsLanguageLink"].firstMatch
                XCTAssertTrue(app.buttons["settingsCloseButton"].waitForExistence(timeout: 10))
                for _ in 0..<6 where !languageLink.isHittable {
                    app.collectionViews.element(boundBy: app.collectionViews.count - 1).swipeUp()
                }
                XCTAssertTrue(languageLink.isHittable); languageLink.tap()
                let row = app.buttons["appLanguage." + language].firstMatch
                for _ in 0..<12 where !row.isHittable { app.collectionViews.element(boundBy: app.collectionViews.count - 1).swipeUp() }
                XCTAssertTrue(row.isHittable)
                let list = app.collectionViews.element(boundBy: app.collectionViews.count - 1)
                let offset = max(-0.3, min(0.3, (row.frame.midY - list.frame.midY) / list.frame.height))
                if abs(offset) > 0.08 {
                    list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                        thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5 - offset)),
                        withVelocity: .slow, thenHoldForDuration: 0.5)
                }
                row.tap()
                RunLoop.current.run(until: Date().addingTimeInterval(0.7))
                app.buttons["BackButton"].firstMatch.tap()
                app.buttons["settingsCloseButton"].tap()
            }
            let homeTitle = homeLabels[language] ?? "Home"
            let homeByID = app.descendants(matching: .any)["house.fill"].firstMatch
            let home = homeByID.exists ? homeByID : app.buttons[homeTitle].firstMatch
            XCTAssertTrue(home.waitForExistence(timeout: 25)); home.tap()
            let sidebar = app.buttons["ToggleSidebar"].firstMatch
            if usesExpandedLayout && sidebar.exists { sidebar.tap() }
            for label in ["Not Now", "以后", "以后再说"] where app.alerts.buttons[label].exists { app.alerts.buttons[label].tap() }
            let shelf = app.buttons.matching(NSPredicate(format: "identifier == %@ OR identifier == %@", "homeShelfViewAll.kindle", "homeShelfSection.kindle")).firstMatch
            XCTAssertTrue(shelf.waitForExistence(timeout: 30))
            func shelfOnScreen() -> Bool {
                shelf.exists && shelf.frame.minY > (deviceProfile.hasPrefix("duo") ? 10 : (usesExpandedLayout ? 70 : 110)) && shelf.frame.maxY < app.frame.height - 110
            }
            for _ in 0..<8 where !shelfOnScreen() {
                if shelf.frame.minY < 135 { app.swipeDown() } else { app.swipeUp() }
            }
            // Align the actual shelf without cropping or synthesizing UI.
            let headerY: CGFloat = deviceProfile.hasPrefix("duo") ? 35 : (usesExpandedLayout ? 95 : 135)
            let alignmentTolerance: CGFloat = deviceProfile.hasPrefix("duo") ? 5 : 25
            for _ in 0..<5 where abs(shelf.frame.minY - headerY) > alignmentTolerance {
                // Drag the shelf heading rather than a horizontal book row;
                // the nested row otherwise consumes the vertical gesture.
                let frame = shelf.frame
                let distance = frame.minY - headerY
                // A tiny drag stays inside UIScrollView's pan recognition slop.
                let panLead: CGFloat = deviceProfile.hasPrefix("duo") ? (distance > 0 ? 12 : -12) : 0
                let offset = max(-app.frame.height * 0.45, min(app.frame.height * 0.45, distance + panLead))
                let origin = shelf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -offset)),
                           withVelocity: .slow, thenHoldForDuration: 0.6)
            }
            XCTAssertLessThanOrEqual(abs(shelf.frame.minY - headerY), alignmentTolerance,
                                     "The store capture must start at Kindle, below Continue Listening")
            if deviceProfile.hasPrefix("duo") {
                let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "continue-item-"))
                for card in cards.allElementsBoundByIndex {
                    XCTAssertLessThanOrEqual(card.frame.maxY, app.windows.firstMatch.frame.minY,
                        "Continue cards must be fully above the visible store screenshot")
                }
            }
            try snapshot(app, name: language + "-1")
            if env["CASTREADER_STORE_HOME_ONLY"] == "1" { continue }
            XCTAssertTrue(shelfOnScreen())
            shelf.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.buttons["kindleOfflineLibrary"].waitForExistence(timeout: 10))
            try snapshot(app, name: language + "-4")
            let back = deviceProfile.hasPrefix("duo") ? app.buttons["BackButton"].firstMatch : app.navigationBars.buttons.firstMatch
            XCTAssertTrue(back.exists); back.tap()
            // A system notification can intercept the navigation tap. Require
            // the real home shelf before opening the next capture scene.
            for _ in 0..<2 where !shelf.waitForExistence(timeout: 5) {
                app.activate()
                let retryBack = app.buttons["BackButton"].firstMatch
                if retryBack.exists && retryBack.isHittable { retryBack.tap() }
            }
            XCTAssertTrue(shelf.waitForExistence(timeout: 10))
            let plus = app.buttons["plusImportButton"].firstMatch
            XCTAssertTrue(plus.waitForExistence(timeout: 10)); plus.tap()
            if !app.buttons["importOptionsCancel"].waitForExistence(timeout: 5) && plus.isHittable { plus.tap() }
            XCTAssertTrue(app.buttons["importOptionsCancel"].waitForExistence(timeout: 10))
            try snapshot(app, name: language + "-5")
            app.buttons["importOptionsCancel"].tap()
            let book = app.buttons["homeShelfBook.kindle.B002RKRMSY"].firstMatch
            XCTAssertTrue(book.waitForExistence(timeout: 15))
            // On the physical device, SwiftUI can report a visible shelf button
            // as non-hittable. Use its observed on-screen geometry, then require
            // the real reader to open before continuing.
            for _ in 0..<4 where book.frame.minY < 110 || book.frame.maxY > app.frame.height - 110 {
                if book.frame.minY < 110 { app.swipeDown() } else { app.swipeUp() }
            }
            XCTAssertTrue(book.frame.minY > 100 && book.frame.maxY < app.frame.height - 100)
            book.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 45))
            let keepPosition = app.webViews.buttons["No"].firstMatch
            if language == languages.first && keepPosition.waitForExistence(timeout: 12) { keepPosition.tap() }
            let readMode = app.buttons["kindleModeButton_read"].firstMatch
            if !readMode.exists { app.buttons["kindleModeMenu"].tap() }
            if readMode.exists { readMode.tap() }
            // Store screenshots use the regular English voice for this English
            // public-domain book, preserving the user's purchased clone balance.
            let read = app.buttons["kindleReadPlayPauseButton"].firstMatch
            XCTAssertTrue(wait(65) {
                // Amazon's own position question may appear after web navigation.
                let yes = app.webViews.buttons["No"].firstMatch
                if yes.exists { yes.tap() }
                return read.exists && read.isEnabled && read.isHittable
            })
            if metrics(app)["playing"] != "true" { read.tap() }
            var lastRetry = Date()
            XCTAssertTrue(wait(150) {
                if keepPosition.exists { keepPosition.tap(); lastRetry = .distantPast }
                let m = self.metrics(app)
                if m["playing"] != "true", Date().timeIntervalSince(lastRetry) > 30,
                   read.isEnabled && read.isHittable {
                    read.tap(); lastRetry = Date()
                }
                return m["playing"] == "true" && (Double(m["time"] ?? "0") ?? 0) > 3 && (Int(m["word"] ?? "-1") ?? -1) >= 0
            }, "Actual read playback and word highlight required")
            if usesExpandedLayout && language == languages.first {
                read.tap()
                XCTAssertTrue(wait(5) { self.metrics(app)["playing"] == "false" })
                XCTAssertTrue(app.buttons["playbackVoiceButton"].firstMatch.waitForExistence(timeout: 10))
                app.buttons["playbackVoiceButton"].firstMatch.tap()
                XCTAssertTrue(app.buttons["playbackVoiceDoneButton"].waitForExistence(timeout: 15))
                let panel = app.otherElements.matching(identifier: "playbackVoicePanel")
                    .containing(.button, identifier: "playbackVoiceDoneButton").firstMatch
                let search = panel.textFields["voiceSearchField"]
                if !search.exists { panel.buttons["voiceSearchToggle"].tap() }
                XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("af_heart\n")
                let normal = panel.buttons["presetVoiceSelect_af_heart"]
                XCTAssertTrue(normal.waitForExistence(timeout: 20)); normal.tap()
                app.buttons["playbackVoiceDoneButton"].tap()
                read.tap()
                XCTAssertTrue(wait(45) { self.metrics(app)["playing"] == "true" && self.metrics(app)["voice"] == "af_heart" })
            }
            if env["CASTREADER_STORE_DIRECTION_AUDIT"] == "1" && ["ar", "he"].contains(language) {
                // Pause at actual spoken words so pixels and word identity can
                // be inspected together, without a timing race during capture.
                for sample in 0..<3 {
                    read.tap()
                    XCTAssertTrue(wait(5) { self.metrics(app)["playing"] == "false" })
                    let state = metrics(app)
                    XCTAssertEqual(state["language"], "en")
                    XCTAssertEqual(state["progression"], "ltr")
                    let previous = app.buttons["kindlePreviousPageButton"].firstMatch
                    let next = app.buttons["kindleNextPageButton"].firstMatch
                    XCTAssertLessThan(previous.frame.midX, next.frame.midX,
                        "English book navigation must stay LTR under Arabic/Hebrew UI")
                    try snapshot(app, name: language + "-direction-\(sample)")
                    let proof = XCTAttachment(data: try JSONSerialization.data(withJSONObject: state,
                        options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
                    proof.name = language + "-direction-\(sample)-metrics"; proof.lifetime = .keepAlways; add(proof)
                    read.tap()
                    XCTAssertTrue(wait(20) {
                        let current = self.metrics(app)
                        return current["playing"] == "true" && current["wordB64"] != state["wordB64"] &&
                            (current["segment"] != state["segment"] || current["paragraph"] != state["paragraph"] ||
                             (Double(current["time"] ?? "0") ?? 0) > (Double(state["time"] ?? "0") ?? 0) + 1)
                    })
                }
            }
            try snapshot(app, name: language + "-2")
            read.tap()
            let explain = app.buttons["kindleModeButton_explain"].firstMatch
            if !explain.exists { app.buttons["kindleModeMenu"].tap() }
            XCTAssertTrue(explain.waitForExistence(timeout: 10)); explain.tap()
            let explainPlay = app.buttons["kindleExplainPlayPauseButton"].firstMatch
            if explainPlay.waitForExistence(timeout: 15) { if metrics(app)["playing"] != "true" { explainPlay.tap() } }
            else if read.exists && read.isEnabled { read.tap() }
            XCTAssertTrue(wait(240) {
                let m = self.metrics(app)
                return m["playing"] == "true" && (Int(m["ink"] ?? "0") ?? 0) > 0 && (Double(m["time"] ?? "0") ?? 0) > 3
            }, "Actual explanation playback with visible original-page ink required")
            try snapshot(app, name: language + "-3")
            if explainPlay.exists && metrics(app)["playing"] == "true" { explainPlay.tap() }
            XCTAssertTrue(wait(5) { self.metrics(app)["playing"] != "true" })
            let evidence = XCTAttachment(data: try JSONSerialization.data(withJSONObject: metrics(app), options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
            evidence.name = language + "-complete"; evidence.lifetime = .keepAlways; add(evidence)
            #if targetEnvironment(simulator)
            if let output {
                try JSONSerialization.data(withJSONObject: metrics(app), options: [.prettyPrinted,.sortedKeys])
                    .write(to: output.appendingPathComponent(language + "-complete.json"))
            }
            #endif
            app.buttons["kindleMinimizeButton"].firstMatch.tap()
        }
    }
}

/// Opt-in release gate: genuine account, production routing, original text and
/// fresh speech/explanation. Attachments preserve actual playback and marks.
final class CoreReleaseLiveUITests: XCTestCase {
    private var evidence: [[String: Any]] = []
    private var region = "global"
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_CORE_LIVE"] == "1")
        continueAfterFailure = false
        region = ProcessInfo.processInfo.environment["CASTREADER_CORE_REGION"] ?? "global"
    }
    private func metrics(_ app: XCUIApplication) -> [String: Any] {
        let probe = app.descendants(matching: .any)["readerLanguagePlaybackMetrics"].firstMatch
        guard probe.exists, let value = probe.value as? String,
              let object = try? JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else { return [:] }
        return object
    }
    private func wait(_ seconds: TimeInterval, _ predicate: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        repeat { if predicate() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.5)) } while Date() < end
        return predicate()
    }
    private func save(_ app: XCUIApplication, _ step: String) throws {
        let quota = app.descendants(matching: .any)["voiceGenerationQuotaSummary"].firstMatch
        let quotaText = quota.exists ? quota.descendants(matching: .any).allElementsBoundByIndex.map {
            ["label": $0.label, "value": $0.value as? String ?? ""]
        } : []
        evidence.append(["step": step, "region": region, "at": ISO8601DateFormatter().string(from: Date()), "metrics": metrics(app), "visibleQuota": quotaText])
        let data = XCTAttachment(data: try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
        data.name = "core-" + region + "-" + step; data.lifetime = .keepAlways; add(data)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "core-" + region + "-" + step; image.lifetime = .keepAlways; add(image)
    }
    override func tearDownWithError() throws {
        if (testRun?.totalFailureCount ?? 0) > 0 { try? save(XCUIApplication(), "failure") }
    }
    func testPrepareRegionalRegularVoice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
            "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate", "-CastReaderDisableDebugPro",
            "-CastReaderRegion", region, "-CastReaderServiceRoute", region]
        app.launch()
        let tab = app.tabBars.buttons["Voice"].exists ? app.tabBars.buttons["Voice"] : app.buttons["Voice"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30)); tab.tap()
        let language = app.buttons["voiceBrowseLanguage"]
        XCTAssertTrue(language.waitForExistence(timeout: 20)); language.tap()
        let searchLanguage = app.searchFields["Search Languages"]
        XCTAssertTrue(searchLanguage.waitForExistence(timeout: 10)); searchLanguage.tap()
        searchLanguage.typeText(region == "cn" ? "Chinese" : "English")
        let option = app.buttons["voiceBrowseLanguage." + (region == "cn" ? "zh" : "en")]
        XCTAssertTrue(option.waitForExistence(timeout: 10)); option.tap()
        let search = app.textFields["voiceSearchField"]
        if !search.exists { app.buttons["voiceSearchToggle"].tap() }
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap()
        if let current = search.value as? String, !current.isEmpty && current != search.placeholderValue {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        let voice = region == "cn" ? "zf_001" : "af_heart"
        search.typeText(voice + "\n")
        let row = app.buttons["presetVoiceSelect_" + voice]
        XCTAssertTrue(row.waitForExistence(timeout: 30)); row.tap()
        try save(app, "prepared-regular-voice")
        app.terminate()
    }

    func testRegionalReadAndExplainVoiceMatrix() throws {
        let cn = region == "cn"
        let language = cn ? "zh" : "en"
        let normal = cn ? "zf_001" : "af_heart"
        let community = cn ? "vl_65b2c4daaea282b057a7" : "vl_d1efb23a380bdaa2f6b0"
        let owned = cn ? "vc_63a448ca35794f57b0aea0e189a68cb3" : "vc_62934fe77f764051aa341b4b076bbb85"
        let english = [
            "A useful reading routine begins with one clear question. Before opening an article, decide what you want to understand and what evidence would answer that question.",
            "Read the first paragraph at a comfortable pace. Notice its main claim, then look for the examples that explain or support the author's point.",
            "Listening while following the words gives attention a place to return to. When a sentence feels difficult, pause and read it again before continuing.",
            "A summary should explain the idea in your own words. Copying an entire passage can hide the difference between recognizing a sentence and understanding it.",
            "After a short section, close the text and recall its main idea. This small exercise reveals which parts are clear and which deserve another look.",
            "Connect the argument to something you already know. A practical example can show both the usefulness of an idea and the limits of its explanation.",
            "Changing the reading voice should preserve your place. The spoken sentence, highlighted words and visible paragraph should continue to describe the same passage.",
            "Finish by returning to your original question. Write one answer supported by the text and one new question to guide your next reading session."
        ].joined(separator: "\n\n")
        let chinese = [
            "有效阅读从一个明确的问题开始。在打开文章之前，先想一想自己希望理解什么，以及哪些证据可以回答这个问题。带着目标阅读，更容易把注意力放在真正重要的内容上。",
            "阅读第一段时，先找出作者的主要观点，再留意支持观点的例子。不要因为一句话听起来很熟悉，就认为自己已经完全理解它。遇到困难的句子，可以暂停后重新阅读。",
            "一边听朗读，一边跟随文字，可以帮助注意力回到当前段落。声音、文字高亮和阅读位置应当保持一致。切换音色以后，也应当从合适的位置继续，而不是重新播放无关的内容。",
            "读完一个小节后，试着不用原文说出它的核心意思。主动回忆能够发现理解上的空白。然后回到文章，检查自己的概括是否准确，并找到需要补充的证据。",
            "最后，把新学到的观点与实际经验联系起来。写下一条由文章支持的结论，再提出一个值得继续探索的问题。这样，阅读就不只是完成篇幅，而是形成能够再次使用的理解。"
        ].joined(separator: "\n\n")
        let env = ProcessInfo.processInfo.environment
        let suppliedText = env["CASTREADER_CORE_TEXT_B64"].flatMap { Data(base64Encoded: $0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        let text = suppliedText ?? ((cn ? chinese : english) + "\n\n" + (cn ? "本次验证编号：" : "Session reference: ") + UUID().uuidString)
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en",
            "-CastReaderSkipLibraryOnboarding", "-CastReaderSkipSignInGate", "-CastReaderMultilingualAcceptance",
            "-CastReaderDisableDebugPro",
            "-CastReaderRegion", region, "-CastReaderServiceRoute", region, "-explain_language", language,
            "-CastReaderCaptureTextB64", Data(text.utf8).base64EncodedString()]
        // An externally launched normal app keeps stdout attached to devicectl
        // so request routing and voice IDs can be matched to the UI evidence.
        if env["CASTREADER_CORE_ATTACH"] == "1" { app.activate() } else { app.launch() }
        let read = app.buttons["readPlayPauseButton"].firstMatch
        XCTAssertTrue(read.waitForExistence(timeout: 45))
        XCTAssertTrue(wait(40) { (self.metrics(app)["readStartState"] as? [String: Any])?["isPro"] as? Bool == true }, "Existing real Pro account is required; never grant or inject entitlement")
        // The reader exposes its language-specific voice control only after
        // the first real reading session establishes the content language.
        if !app.buttons["playbackVoiceButton"].firstMatch.exists {
            read.tap()
            XCTAssertTrue(wait(120) {
                self.metrics(app)["playing"] as? Bool == true &&
                    (self.metrics(app)["time"] as? Double ?? 0) > 1 &&
                    app.buttons["playbackVoiceButton"].firstMatch.exists
            })
            read.tap()
            XCTAssertTrue(wait(5) { self.metrics(app)["playing"] as? Bool == false })
        }
        let panel = app.otherElements.matching(identifier: "playbackVoicePanel").containing(.button, identifier: "playbackVoiceDoneButton").firstMatch
        func select(_ voice: String, mode: String) throws {
            app.buttons["playbackVoiceButton"].firstMatch.tap()
            XCTAssertTrue(app.buttons["playbackVoiceDoneButton"].waitForExistence(timeout: 15))
            if cn {
                let category = panel.segmentedControls["voiceBrowserCategoryPicker"]
                let tab = category.buttons[voice.hasPrefix("vc_") ? "My Voices" : "Explore"]
                XCTAssertTrue(tab.waitForExistence(timeout: 10)); tab.tap()
            }
            let search = panel.textFields["voiceSearchField"]
            if !search.exists { panel.buttons["voiceSearchToggle"].tap() }
            XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap()
            if let current = search.value as? String, !current.isEmpty && current != search.placeholderValue {
                search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
            }
            search.typeText(voice + "\n")
            let rowID = voice.hasPrefix("vc_")
                ? (cn ? "voiceCloneApplyButton_" : "voiceFamiliarSelect_") + voice
                : "presetVoiceSelect_" + voice
            let row = panel.buttons[rowID]
            XCTAssertTrue(row.waitForExistence(timeout: 35), "Voice must be available in the existing account: " + voice)
            for _ in 0..<5 where !row.isHittable { panel.swipeUp() }
            XCTAssertTrue(row.isHittable); row.tap()
            try self.save(app, mode + "-selected-" + voice)
            app.buttons["playbackVoiceDoneButton"].tap()
            XCTAssertTrue(wait(45) { self.metrics(app)[mode + "VoiceID"] as? String == voice })
        }
        func verify(_ voice: String, mode: String, label: String, requireContinuation: Bool = true,
                    requestResume: Bool = true) throws {
            let play = app.buttons[mode == "read" ? "readPlayPauseButton" : "explainPlayPauseButton"].firstMatch
            if requestResume && self.metrics(app)["playing"] as? Bool != true {
                XCTAssertTrue(wait(90) { play.exists && play.isEnabled })
                // Preparation can finish and start audio while awaiting the
                // button. Never turn that successful autoplay into a pause.
                if self.metrics(app)["playing"] as? Bool != true { play.tap() }
            }
            XCTAssertTrue(wait(150) {
                let m = self.metrics(app)
                return m["playing"] as? Bool == true && m[mode + "VoiceID"] as? String == voice && (m["time"] as? Double ?? 0) > 2
            }, label + " real voice and playback progress")
            let start = self.metrics(app)
            XCTAssertTrue(wait(90) {
                let m = self.metrics(app)
                return mode == "read" ? !(m["highlight"] as? String ?? "").isEmpty : (m["marks"] as? Int ?? 0) > 0
            }, label + " actual original-text highlight/marks")
            try self.save(app, label + "-playing")
            if requireContinuation {
                XCTAssertTrue(wait(210) {
                    let m = self.metrics(app)
                    let key = mode == "read" ? "paragraph" : "block"
                    return m["playing"] as? Bool == true && (m[key] as? Int ?? -1) > (start[key] as? Int ?? -1)
                }, label + " automatic next paragraph/block")
                try self.save(app, label + "-continued")
            }
            XCTAssertTrue((self.metrics(app)[mode + "Error"] as? String ?? "").isEmpty)
        }
        try select(normal, mode: "read")
        if env["CASTREADER_CORE_MODE"] != "explain" {
            let startIndex = Int(env["CASTREADER_CORE_READ_START_INDEX"] ?? "0") ?? 0
            for (index, voice) in [normal, community, owned, normal].enumerated() where index >= startIndex {
                if index > 0 { try select(voice, mode: "read") }
                try verify(voice, mode: "read", label: "read-\(index)", requireContinuation: index < 3)
                read.tap(); XCTAssertTrue(wait(5) { self.metrics(app)["playing"] as? Bool == false })
            }
        }
        app.segmentedControls["readerModePicker"].buttons["Explain"].tap()
        let start = app.buttons["explainStartButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()
        for (index, voice) in [normal, community, owned, normal].enumerated() {
            if index > 0 { try select(voice, mode: "explain") }
            try verify(voice, mode: "explain", label: "explain-\(index)", requireContinuation: index < 3,
                       requestResume: index > 0)
            app.buttons["explainPlayPauseButton"].firstMatch.tap()
            XCTAssertTrue(wait(5) { self.metrics(app)["playing"] as? Bool == false })
        }
        try save(app, "complete")
    }
}
