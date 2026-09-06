import XCTest
import UIKit

/// Exercises native controls using local fixtures, plus an explicitly opted-in
/// live session already authorized by its owner. No test enters credentials.
final class GoogleBooksBindingUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testGoogleBooksLoginFixtureKeepsFormUsableWithoutNativeOverlay() throws {
        let app = launch(fixture: "-CastReaderGoogleBooksLoginFixture")
        let web = app.webViews["googleBooksBindingWebView"]
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        let email = web.textFields["Email"]
        let password = web.secureTextFields["Password"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        XCTAssertTrue(password.exists)
        XCTAssertTrue(app.buttons["googleBooksReloadButton"].exists)
        assertNativeGuideStaysHidden(in: app)

        email.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        email.typeText("fixture@example.invalid")
        XCTAssertEqual(email.value as? String, "fixture@example.invalid")
        assertNativeBarsHidden(in: app)
        keepScreenshot(app, named: "GoogleBooks-login-email-keyboard")

        scrollTo(password, in: web)
        XCTAssertTrue(password.isHittable)
        password.tap()
        password.typeText("local-fixture-only")
        XCTAssertFalse((password.value as? String ?? "").isEmpty)
        assertNativeBarsHidden(in: app)
        let submit = web.buttons["Continue"]
        scrollTo(submit, in: web)
        XCTAssertTrue(submit.isHittable)
        keepScreenshot(app, named: "GoogleBooks-login-password-action")
        submit.tap()
        XCTAssertTrue(web.staticTexts["Form submitted locally"].waitForExistence(timeout: 5))
        keepScreenshot(app, named: "GoogleBooks-login-local-form-submitted")
    }

    func testGoogleBooksBlankFixtureShowsVisibleRetry() throws {
        let app = launch(fixture: "-CastReaderGoogleBooksBlankFixture")
        let web = app.webViews["googleBooksBindingWebView"]
        XCTAssertTrue(web.waitForExistence(timeout: 15))
        let error = app.staticTexts["googleBooksBindingError"]
        XCTAssertTrue(error.waitForExistence(timeout: 12))
        XCTAssertTrue(error.isHittable, "A blank page must expose its error and recovery action")
        let reload = app.buttons["googleBooksReloadButton"]
        XCTAssertTrue(reload.isHittable)
        XCTAssertTrue(reload.isEnabled)
        XCTAssertLessThanOrEqual(web.frame.maxY, error.frame.minY + 1,
                                 "The native error must occupy space below the webpage")
        keepScreenshot(app, named: "GoogleBooks-blank-visible-retry")
        reload.tap()
        XCTAssertTrue(web.exists)
        XCTAssertTrue(error.waitForExistence(timeout: 12),
                      "Reloading a still-blank fixture must remain recoverable")
        keepScreenshot(app, named: "GoogleBooks-blank-reloaded-retry")
    }

    func testGoogleBooksPopupFixtureKeepsCloseUsable() throws {
        let app = launch(fixture: "-CastReaderGoogleBooksPopupFixture")
        let main = app.webViews["googleBooksBindingWebView"]
        XCTAssertTrue(main.waitForExistence(timeout: 15))
        let signIn = app.buttons["googleBooksSignInButton"]
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.isHittable)
        signIn.tap()

        let popup = app.webViews["googleBooksLoginPopupWebView"]
        XCTAssertTrue(popup.waitForExistence(timeout: 10))
        let password = popup.secureTextFields["Password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        assertNativeGuideStaysHidden(in: app)
        keepScreenshot(app, named: "GoogleBooks-popup-before-input")
        // about:blank popup fields can have no WebKit AX hit point despite
        // being visibly usable; verify actual touch and keyboard input.
        password.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        password.typeText("local-popup-only")
        XCTAssertFalse((password.value as? String ?? "").isEmpty)
        assertNativeBarsHidden(in: app)
        let close = app.buttons["googleBooksClosePopupButton"]
        XCTAssertTrue(close.isHittable)
        keepScreenshot(app, named: "GoogleBooks-popup-password-input")
        close.tap()

        XCTAssertTrue(waitForDisappearance(popup, timeout: 5))
        XCTAssertTrue(main.waitForExistence(timeout: 5))
        XCTAssertTrue(signIn.waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.isHittable)
        XCTAssertFalse(close.exists)
        keepScreenshot(app, named: "GoogleBooks-popup-close-returns-to-entry")
    }

    /// Requires the owner's authorization and an already signed-in WebKit
    /// profile. Ordinary CI skips this test; it never fills credentials, clears
    /// cookies, injects shelf entries, or changes the shared website profile.
    func testGoogleBooksAuthorizedLiveShelfSync() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(
            environment["CASTREADER_GOOGLE_BOOKS_LIVE_SYNC"] == "1",
            "Live Google Books sync requires CASTREADER_GOOGLE_BOOKS_LIVE_SYNC=1 after user authorization"
        )
        let volumeIDs = (environment["CASTREADER_GOOGLE_BOOKS_LIVE_VOLUME_IDS"]
                         ?? "b_40EQAAQBAJ,QrpAEQAAQBAJ")
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard volumeIDs.count == 2, Set(volumeIDs).count == 2,
              volumeIDs.allSatisfy({ !$0.isEmpty }) else {
            XCTFail("CASTREADER_GOOGLE_BOOKS_LIVE_VOLUME_IDS must contain the two verified, distinct volume IDs separated by a comma")
            return
        }
        let expectedCount = volumeIDs.count
        let app = XCUIApplication()
        app.launchArguments = languageArguments + [
            "-CastReaderGoogleBooksHomeValidation", "-CastReaderSkipLibraryOnboarding",
        ]
        app.launch()
        openSources(in: app)
        let connect = app.buttons["shelfSourcePrimaryAction.google_books"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        scrollTo(connect, in: app)
        XCTAssertTrue(connect.isHittable)
        connect.tap()

        let binding = app.webViews["googleBooksBindingWebView"]
        XCTAssertTrue(binding.waitForExistence(timeout: 15))
        let sync = app.buttons["syncGoogleBooksLibraryButton"]
        let bindingError = app.staticTexts["googleBooksBindingError"]
        XCTAssertTrue(waitForGoogleBooksSyncOrError(sync, error: bindingError, timeout: 60),
                      "The authorized shelf must expose native Sync or a visible binding error")
        var networkRetryCount = 0
        if bindingError.exists {
            keepScreenshot(app, named: "GoogleBooks-live-binding-error-before-recovery")
            guard bindingError.label == "Network connection failed. Please try again." else {
                XCTFail("Live Google Books binding failed with a non-network error; no retry was attempted: \(bindingError.label)")
                return
            }
            let retry = app.buttons["retryGoogleBooksBindingButton"]
            XCTAssertTrue(bindingError.isHittable,
                          "The initial network failure must be visible to the user")
            XCTAssertTrue(retry.waitForExistence(timeout: 5))
            XCTAssertTrue(retry.isHittable)
            XCTAssertTrue(retry.isEnabled)
            keepScreenshot(app, named: "GoogleBooks-live-network-error-before-one-native-retry")
            retry.tap()
            networkRetryCount = 1
            XCTAssertTrue(waitForDisappearance(bindingError, timeout: 5),
                          "The single native Retry must clear the previous network error")
            XCTAssertTrue(waitForGoogleBooksSyncOrError(sync, error: bindingError, timeout: 60),
                          "The single network retry must reach Sync or expose its failure")
            if bindingError.exists {
                keepScreenshot(app, named: "GoogleBooks-live-error-after-single-network-retry")
                XCTFail("Live Google Books binding still failed after one native network retry; no further retry was attempted: \(bindingError.label)")
                return
            }
        }
        XCTAssertTrue(sync.exists && sync.isHittable && sync.isEnabled,
                      "The authorized shelf must reach an actionable native Sync button")
        let recoveryRecord = XCTAttachment(string: "nativeNetworkRetryCount=\(networkRetryCount)")
        recoveryRecord.name = "GoogleBooks-live-network-recovery-count"
        recoveryRecord.lifetime = .keepAlways
        add(recoveryRecord)
        XCTAssertEqual(sync.label, "Sync \(expectedCount) Books")
        XCTAssertTrue(app.staticTexts["\(expectedCount) books detected"].exists,
                      "The completed scan must match the independently verified account count")
        keepScreenshot(app, named: "GoogleBooks-live-\(expectedCount)-ready-for-native-sync")
        if networkRetryCount == 1 {
            keepScreenshot(app, named: "GoogleBooks-live-ready-after-one-native-network-retry")
        }
        sync.tap()
        XCTAssertTrue(waitForDisappearance(binding, timeout: 15),
                      "Native Sync must save the shelf and dismiss the binding sheet")
        XCTAssertTrue(app.staticTexts["Synced \(expectedCount) books."].waitForExistence(timeout: 10))
        keepScreenshot(app, named: "GoogleBooks-live-\(expectedCount)-synced-source")
        let closeSources = app.buttons["Close"].firstMatch
        XCTAssertTrue(closeSources.waitForExistence(timeout: 10))
        closeSources.tap()
        dismissSystemReviewPromptIfPresent(in: app, timeout: 4)

        let homeBooks = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "homeShelfBook.google_books."
        ))
        XCTAssertTrue(homeBooks.firstMatch.waitForExistence(timeout: 15))
        let expectedHomeIDs = Set(volumeIDs.map { "homeShelfBook.google_books.\($0)" })
        XCTAssertEqual(Set(homeBooks.allElementsBoundByIndex.map(\.identifier)), expectedHomeIDs,
                       "Home must contain exactly the two verified live Google Books entries")
        keepScreenshot(app, named: "GoogleBooks-live-home-after-sync")

        for (index, volumeID) in volumeIDs.enumerated() {
            let book = app.buttons["homeShelfBook.google_books.\(volumeID)"]
            scrollTo(book, in: app)
            dismissSystemReviewPromptIfPresent(in: app, timeout: 0.5)
            XCTAssertTrue(book.isHittable)
            book.tap()
            let reader = app.webViews["googleBooksReaderWebView"]
            XCTAssertTrue(reader.waitForExistence(timeout: 30),
                          "The Home entry must open the official Google Books reader")
            let minimize = app.buttons["readerMinimizeButton"]
            XCTAssertTrue(minimize.waitForExistence(timeout: 10))
            let next = app.buttons["readerNextPageButton"]
            guard waitForGoogleBooksReadablePage(reader, volumeID: volumeID, timeout: 90) else {
                keepScreenshot(app, named: "GoogleBooks-live-book-\(index + 1)-initial-text-missing")
                var diagnostic = "The native Next action was unavailable."
                if next.exists, next.isHittable, next.isEnabled {
                    next.tap()
                    let nextReadable = waitForGoogleBooksReadablePage(
                        reader, volumeID: volumeID, timeout: 30
                    )
                    diagnostic = nextReadable
                        ? "One diagnostic Next action produced later-page text; the initial page still failed."
                        : "One diagnostic Next action also failed to produce text within 30 seconds."
                    keepScreenshot(app, named: "GoogleBooks-live-book-\(index + 1)-diagnostic-next")
                }
                XCTFail("Google Books \(volumeID) initial page did not provide parsed text within 90 seconds. \(diagnostic)")
                return
            }
            let firstDigest = try XCTUnwrap(googleBooksReadableDigest(reader, volumeID: volumeID))
            keepScreenshot(app, named: "GoogleBooks-live-book-\(index + 1)-readable")
            XCTAssertTrue(next.isHittable)
            XCTAssertTrue(next.isEnabled)
            next.tap()
            XCTAssertTrue(waitForGoogleBooksReadablePage(
                reader, volumeID: volumeID, excludingDigest: firstDigest, timeout: 30
            ), "Next must commit nonempty text for this book with a different body digest")
            keepScreenshot(app, named: "GoogleBooks-live-book-\(index + 1)-next-page")
            XCTAssertTrue(minimize.isHittable)
            minimize.tap()
            XCTAssertTrue(app.buttons["homeShelfSourcesButton"].waitForExistence(timeout: 10))
        }

        app.terminate()
        app.launch()
        XCTAssertTrue(homeBooks.firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(Set(homeBooks.allElementsBoundByIndex.map(\.identifier)), expectedHomeIDs,
                       "A fresh process must reload exactly the same two live books on Home")
        keepScreenshot(app, named: "GoogleBooks-live-home-persisted-after-relaunch")
        openSources(in: app)
        XCTAssertTrue(app.staticTexts["Synced \(expectedCount) books."].waitForExistence(timeout: 10))
        keepScreenshot(app, named: "GoogleBooks-live-count-persisted-after-relaunch")
        XCTAssertTrue(closeSources.waitForExistence(timeout: 10))
        closeSources.tap()
        dismissSystemReviewPromptIfPresent(in: app, timeout: 1)
    }

    func testGoogleBooksHundredBooksBindSyncAndPersistOnHome() throws {
        let app = XCUIApplication()
        app.launchArguments = languageArguments + [
            "-CastReaderGoogleBooksHomeValidation", "-CastReaderSkipLibraryOnboarding",
            "-CastReaderGoogleBooksHundredShelfFixture", "-CastReaderResetGoogleBooksHundredFixture",
        ]
        app.launch()
        openSources(in: app)
        let connect = app.buttons["shelfSourcePrimaryAction.google_books"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        scrollTo(connect, in: app)
        XCTAssertTrue(connect.isHittable)
        connect.tap()
        let binding = app.webViews["googleBooksBindingWebView"]
        XCTAssertTrue(binding.waitForExistence(timeout: 15))
        let sync = app.buttons["syncGoogleBooksLibraryButton"]
        let syncReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"),
            object: sync
        )
        XCTAssertEqual(XCTWaiter.wait(for: [syncReady], timeout: 90), .completed)
        XCTAssertTrue(sync.label.contains("100"), "Only the complete 100-book scan may become actionable")
        keepScreenshot(app, named: "GoogleBooks-100-ready-for-native-sync")
        sync.tap()
        XCTAssertTrue(waitForDisappearance(binding, timeout: 15),
                      "The normal Sync button must save and dismiss the binding sheet")
        let closeSources = app.buttons["Close"].firstMatch
        XCTAssertTrue(closeSources.waitForExistence(timeout: 10))
        closeSources.tap()
        dismissSystemReviewPromptIfPresent(in: app, timeout: 4)

        let rail = app.buttons.matching(NSPredicate(
            format: "identifier BEGINSWITH %@", "homeShelfBook.google_books."
        ))
        XCTAssertTrue(rail.firstMatch.waitForExistence(timeout: 15))
        let viewAll = app.descendants(matching: .any)["homeShelfViewAll.google_books"].firstMatch
        scrollTo(viewAll, in: app)
        dismissSystemReviewPromptIfPresent(in: app, timeout: 1)
        XCTAssertTrue(viewAll.isHittable)
        keepScreenshot(app, named: "GoogleBooks-100-home-after-sync")
        viewAll.tap()
        let shelfRefresh = app.buttons["refreshGoogleBooksLibraryButton"]
        if !shelfRefresh.waitForExistence(timeout: 5),
           dismissSystemReviewPromptIfPresent(in: app, timeout: 2) {
            // StoreKit may present between the Home check and the tap. Once
            // its prompt is gone, retry the real navigation exactly once.
            XCTAssertTrue(viewAll.isHittable)
            viewAll.tap()
        }
        XCTAssertTrue(shelfRefresh.waitForExistence(timeout: 10),
                      "View All must reach the native shelf before checking search")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        // The native full library initially exposes 24 entries. Search must
        // reach every batch boundary without pressing Load More repeatedly.
        for number in [1, 24, 25, 48, 49, 72, 73, 96, 97, 100] {
            search.tap()
            // Tapping a long search query can place the caret in its middle.
            // Use the real clear control instead of deleting from that caret.
            let clear = search.buttons["Clear text"]
            if clear.exists { clear.tap() }
            let query = String(format: "Google 合成测试书 %03d", number)
            search.typeText(query)
            XCTAssertEqual(search.value as? String, query)
            let volumeID = String(format: "GBFIX%04d", number)
            XCTAssertTrue(app.buttons["googleBooksBook.\(volumeID)"].waitForExistence(timeout: 5),
                          "Saved book \(number) must be searchable in the full native library")
        }
        keepScreenshot(app, named: "GoogleBooks-100-last-book-searchable")
        app.terminate()
        app.launchArguments.removeAll { $0 == "-CastReaderResetGoogleBooksHundredFixture" }
        app.launch()
        XCTAssertTrue(rail.firstMatch.waitForExistence(timeout: 15))
        openSources(in: app)
        XCTAssertTrue(app.buttons["shelfSourcePrimaryAction.google_books"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Synced 100 books."].waitForExistence(timeout: 10),
                      "A fresh process must report all 100 saved books in the actual source UI")
        keepScreenshot(app, named: "GoogleBooks-100-count-persisted-after-relaunch")
    }

    private var languageArguments: [String] {
        ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-interfaceLanguage", "en"]
    }

    private func launch(fixture: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = languageArguments + [fixture]
        app.launch()
        return app
    }

    private func googleBooksReadableDigest(_ reader: XCUIElement, volumeID: String) -> String? {
        guard let value = reader.value as? String else { return nil }
        let fields = value.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, fields[0] == "ready", fields[1] == volumeID,
              let characterCount = Int(fields[2]), characterCount > 0,
              !fields[3].isEmpty else { return nil }
        return fields[3]
    }

    private func waitForGoogleBooksSyncOrError(
        _ sync: XCUIElement,
        error: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        let outcome = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (sync.exists && sync.isHittable && sync.isEnabled) || error.exists
        }, object: sync)
        return XCTWaiter.wait(for: [outcome], timeout: timeout) == .completed
    }

    private func waitForGoogleBooksReadablePage(
        _ reader: XCUIElement,
        volumeID: String,
        excludingDigest previousDigest: String? = nil,
        timeout: TimeInterval
    ) -> Bool {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let digest = self.googleBooksReadableDigest(reader, volumeID: volumeID) else {
                return false
            }
            return digest != previousDigest
        }, object: reader)
        return XCTWaiter.wait(for: [ready], timeout: timeout) == .completed
    }

    private func openSources(in app: XCUIApplication) {
        dismissSystemReviewPromptIfPresent(in: app, timeout: 0.5)
        let sources = app.buttons["homeShelfSourcesButton"]
        XCTAssertTrue(sources.waitForExistence(timeout: 15))
        scrollTo(sources, in: app)
        XCTAssertTrue(sources.isHittable)
        sources.tap()
    }

    /// A successful sync can trigger SKStoreReviewController after the source
    /// sheet closes. The observed remote view is in the app's AX tree, although
    /// some OS versions expose system prompts through SpringBoard instead.
    /// Dismiss only the identified review prompt; never touch stars or submit.
    @discardableResult
    private func dismissSystemReviewPromptIfPresent(
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> Bool {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for surface in [app, springboard] {
                let title = surface.staticTexts["Enjoying CastReader?"]
                let notNow = surface.buttons["Not Now"].firstMatch
                guard title.exists, notNow.exists else { continue }
                keepScreenshot(app, named: "GoogleBooks-100-system-review-before-dismiss")
                XCTAssertTrue(notNow.isHittable)
                notNow.tap()
                XCTAssertTrue(waitForDisappearance(title, timeout: 5),
                              "Not Now must close the system rating prompt")
                return true
            }
            if Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            }
        } while Date() < deadline
        return false
    }

    private func assertNativeGuideStaysHidden(in app: XCUIApplication) {
        let guide = app.descendants(matching: .any)["googleBooksLoginGuide"].firstMatch
        XCTAssertTrue(waitForDisappearance(guide, timeout: 5))
        let reappears = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true"), object: guide
        )
        reappears.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [reappears], timeout: 2), .completed,
                       "Delayed native probes must not restore the guide above the form")
        assertNativeBarsHidden(in: app)
    }

    private func assertNativeBarsHidden(in app: XCUIApplication) {
        XCTAssertFalse(app.descendants(matching: .any)["googleBooksLoginGuide"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["googleBooksSyncBar"].firstMatch.exists)
        XCTAssertFalse(app.buttons["googleBooksSignInButton"].exists)
    }

    private func scrollTo(_ element: XCUIElement, in surface: XCUIElement) {
        for _ in 0..<8 where !element.isHittable { surface.swipeUp() }
    }

    private func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element
        )
        return XCTWaiter.wait(for: [gone], timeout: timeout) == .completed
    }

    private func keepScreenshot(_ app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
