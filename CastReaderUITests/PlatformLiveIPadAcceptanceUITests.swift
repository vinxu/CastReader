import XCTest

/// Explicit opt-in against already authorized platform accounts. No fixture
/// book, speech, authentication bypass, cookie reset or library mutation.
final class PlatformLiveIPadAcceptanceUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state == .runningForeground { capture(app, "live-platform-final-state") }
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func wait(_ timeout: Double = 30, _ condition: @escaping () -> Bool,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed { capture(XCUIApplication(), "live-platform-wait-failure") }
        XCTAssertEqual(result, .completed, file: file, line: line)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
        let metrics = app.otherElements["livePlatformPlaybackMetrics"]
        if metrics.exists {
            let values = XCTAttachment(string: metrics.value as? String ?? "unavailable")
            values.name = name + "-metrics"; values.lifetime = .keepAlways; add(values)
        }
    }

    private func field(_ key: String, _ app: XCUIApplication) -> String {
        let metrics = app.otherElements["livePlatformPlaybackMetrics"]
        guard metrics.exists else { return "" }
        return (metrics.value as? String ?? "").split(separator: ";")
            .first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } ?? ""
    }

    private func number(_ key: String, _ app: XCUIApplication) -> Double {
        Double(field(key, app)) ?? -1
    }

    private func rotate(_ app: XCUIApplication, _ orientation: UIDeviceOrientation) {
        XCUIDevice.shared.orientation = orientation
        wait(15) {
            let size = app.windows.firstMatch.frame.size
            return orientation.isLandscape ? size.width > size.height : size.height > size.width
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<14 {
            if element.exists, element.frame.width > 1, element.isHittable,
               element.frame.minY > app.windows.firstMatch.frame.minY + 100,
               element.frame.maxY < app.windows.firstMatch.frame.maxY - 90 { return }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.exists && element.isHittable)
    }

    private func home(_ platform: String, extra: [String] = []) throws -> XCUIApplication {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_PLATFORM_LIVE_ACCEPTANCE"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipLibraryOnboarding", "-CastReaderLivePlatformAcceptance",
                               "-CastReaderTTSClockDiagnostics",
                               "-AppleLanguages", "(en)", "-interfaceLanguage", "en"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["plusImportButton"].waitForExistence(timeout: 30),
                      "The existing signed-in account must remain usable")
        if app.windows.firstMatch.frame.width < 700 {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.055)).doubleTap()
            wait(15) { app.windows.firstMatch.frame.width >= 700 }
        }
        let ignore = app.buttons["Ignore"]
        if app.staticTexts["There's text in your clipboard"].exists && ignore.isHittable { ignore.tap() }
        let shelf = app.buttons["homeShelfViewAll.\(platform)"]
        reveal(shelf, in: app)
        capture(app, "\(platform)-home-shelf-portrait")
        shelf.tap()
        wait { !shelf.exists || !shelf.isHittable }
        capture(app, "\(platform)-full-shelf-portrait")
        rotate(app, .landscapeLeft)
        capture(app, "\(platform)-full-shelf-landscape")
        rotate(app, .portrait)
        let back = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 10)); back.tap()
        return app
    }

    func testGoogleBooksReadExplainRotation() throws { try verify("google_books") }
    func testGoogleBooksBodyReadExplainRotation() throws {
        // An observed, authorized real-book location; this chooses the same
        // provider page as its native pagination and supplies no fixture data.
        try verify("google_books", launch: ["-CastReaderGoogleBooksLiveTestURL",
            "https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PP2.w.0.2.34_114"])
    }
    func testKoboReadExplainRotation() throws { try verify("kobo") }
    func testWeReadReadExplainRotation() throws { try verify("weread") }

    func testGoogleBooksNaturalContinuation() throws { try continuation("google_books") }
    func testKoboNaturalContinuation() throws { try continuation("kobo") }
    func testWeReadNaturalContinuation() throws { try continuation("weread") }

    func testWeReadCompactToWideColdResume() throws {
        var app = try home("weread")
        let bookID = "homeShelfBook.weread.weread:f8832a00728d9ff9f8847b2"
        var book = app.buttons[bookID]
        reveal(book, in: app); book.tap()
        wait(120) { app.buttons["readPlayPauseButton"].exists && self.field("ready", app) == "true" }
        if field("playing", app) == "true" { app.buttons["readPlayPauseButton"].tap() }
        // Select an actual catalog position, then a real confirmed page turn.
        // A legacy checkpoint must never be erased or rewritten by the test.
        app.buttons["Table of Contents"].tap()
        let chapter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadTOCEntry.", "第一章 开往蒙古的列车")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 30)); chapter.tap()
        var settled: Date?
        wait(90) {
            guard self.field("ready", app) == "true", self.field("surfaceCovered", app) == "false",
                  !app.buttons["weReadTOCClose"].exists else { settled = nil; return false }
            if settled == nil { settled = Date() }
            return Date().timeIntervalSince(settled!) > 3
        }
        let initialPage = field("page", app)
        app.buttons["readerNextPageButton"].tap()
        wait(60) { self.field("ready", app) == "true" && self.field("page", app) != initialPage && self.number("characters", app) > 250 }
        let legacyNotice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "saved position cannot be restored")).firstMatch
        wait(15) { !legacyNotice.exists }
        if field("readActive", app) != "true" || field("readPaused", app) == "true" { app.buttons["readPlayPauseButton"].tap() }
        wait(120) { self.field("playing", app) == "true" && self.number("time", app) > 1 && self.number("wordVisible", app) > 0 }
        app.buttons["readPlayPauseButton"].tap()
        wait { self.field("playing", app) == "false" }
        capture(app, "weread-wide-original-listening-position")
        app.terminate()

        app = try home("weread")
        let all = app.buttons["homeShelfViewAll.weread"]
        reveal(all, in: app); all.tap()
        let window = app.windows.firstMatch, width = window.frame.width
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.992, dy: 0.992))
            .press(forDuration: 1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.65)))
        wait { window.frame.width >= 320 && window.frame.height >= 400 && window.frame.width < width - 100 }
        let compactBook = app.buttons["weReadLibraryBook.weread:f8832a00728d9ff9f8847b2"]
        XCTAssertTrue(compactBook.isHittable); compactBook.tap()
        wait(120) { app.buttons["readPlayPauseButton"].exists && self.field("ready", app) == "true" }
        var notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "saved position cannot be restored")).firstMatch
        XCTAssertFalse(notice.exists)
        if field("readActive", app) != "true" || field("readPaused", app) == "true" { app.buttons["readPlayPauseButton"].tap() }
        wait(120) { self.field("playing", app) == "true" && self.number("time", app) > 1 && self.number("wordVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        app.buttons["readPlayPauseButton"].tap()
        wait { self.field("playing", app) == "false" }
        XCTAssertLessThan(number("characters", app), 250, "Exercise the provider's genuinely short compact page")
        XCTAssertFalse(notice.exists)
        capture(app, "weread-compact-sentence-checkpoint-paused")
        app.terminate()

        app = try home("weread")
        book = app.buttons[bookID]
        reveal(book, in: app); book.tap()
        wait(120) { app.buttons["readPlayPauseButton"].exists && self.field("ready", app) == "true" }
        notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "saved position cannot be restored")).firstMatch
        XCTAssertFalse(notice.exists, "The short compact sentence must restore into the wider provider paragraph")
        if field("readActive", app) != "true" || field("readPaused", app) == "true" { app.buttons["readPlayPauseButton"].tap() }
        wait(120) { self.field("playing", app) == "true" && self.number("time", app) > 1 && self.number("wordVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        XCTAssertFalse(notice.exists)
        app.buttons["readPlayPauseButton"].tap()
        wait { self.field("playing", app) == "false" }
        capture(app, "weread-wide-cold-restored-sentence-highlight")
        app.buttons["readerMinimizeButton"].tap()
    }

    func testWeReadContentsAfterReflow() throws {
        let app = try home("weread")
        let book = app.buttons["homeShelfBook.weread.weread:f8832a00728d9ff9f8847b2"]
        reveal(book, in: app); book.tap()
        let read = app.buttons["readPlayPauseButton"]
        wait(120) { read.exists && self.field("ready", app) == "true" }
        if field("playing", app) == "true" { read.tap() }
        app.buttons["Table of Contents"].tap()
        let portraitIntro = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadTOCEntry.", "说明")).firstMatch
        XCTAssertTrue(portraitIntro.waitForExistence(timeout: 20)); portraitIntro.tap()
        wait(60) { !app.buttons["weReadTOCClose"].exists && self.field("ready", app) == "true" && self.number("characters", app) > 20 && self.number("characters", app) < 100 }
        capture(app, "weread-portrait-contents-exact-introduction")
        app.buttons["Table of Contents"].tap()
        let portraitChapter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadTOCEntry.", "第一章 开往蒙古的列车")).firstMatch
        XCTAssertTrue(portraitChapter.waitForExistence(timeout: 15)); portraitChapter.tap()
        wait(60) { !app.buttons["weReadTOCClose"].exists && self.field("ready", app) == "true" && self.number("characters", app) > 250 }
        let portraitHeading = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "开往蒙古的列车")).firstMatch
        XCTAssertTrue(portraitHeading.waitForExistence(timeout: 15))
        capture(app, "weread-portrait-contents-exact-first-chapter")
        rotate(app, .landscapeLeft)
        app.buttons["Table of Contents"].tap()
        let intro = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadTOCEntry.", "说明")).firstMatch
        XCTAssertTrue(intro.waitForExistence(timeout: 20)); intro.tap()
        wait(30) { !app.buttons["weReadTOCClose"].exists && self.field("surfaceCovered", app) == "false" && self.number("characters", app) > 20 }
        // Wait for the provider's observed introduction commit, not just the
        // native overlay closing while a new route is still loading.
        let introduction = app.webViews.staticTexts["说明"].firstMatch
        XCTAssertTrue(introduction.waitForExistence(timeout: 30))
        capture(app, "weread-contents-introduction-two-columns")
        app.buttons["Table of Contents"].tap()
        let chapter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadTOCEntry.", "第一章 开往蒙古的列车")).firstMatch
        XCTAssertTrue(chapter.waitForExistence(timeout: 15)); chapter.tap()
        wait(90) { !app.buttons["weReadTOCClose"].exists && self.field("ready", app) == "true" && self.number("characters", app) > 20 }
        // The provider may already show this chapter in its second column.
        // Selecting that visible chapter closes the catalog without forcing
        // a second physical turn, just like selecting an active catalog row.
        let visibleChapter = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "开往蒙古的列车")).firstMatch
        XCTAssertTrue(visibleChapter.waitForExistence(timeout: 15))
        capture(app, "weread-contents-chapter-selected-after-reflow")
        app.buttons["readerMinimizeButton"].tap(); rotate(app, .portrait)
    }

    private func continuation(_ platform: String) throws {
        let launch = platform == "google_books" ? ["-CastReaderGoogleBooksLiveTestURL",
            "https://play.google.com/books/reader?id=b_40EQAAQBAJ&pg=GBS.PP2.w.0.2.34_114"] : []
        let app = try home(platform, extra: launch)
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.\(platform).")).firstMatch
        reveal(book, in: app); book.tap()
        let read = app.buttons["readPlayPauseButton"]
        if platform == "weread" {
            wait(45) { read.exists && (self.field("ready", app) == "true" || app.buttons["下一页"].exists) }
            if field("ready", app) != "true" { read.tap() }
        }
        wait(120) { read.exists && self.field("ready", app) == "true" }
        if platform == "weread", number("characters", app) < 250 {
            if field("playing", app) == "true" { read.tap() }
            app.buttons["Table of Contents"].tap()
            let chapter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadTOCEntry.", "第一章 开往蒙古的列车")).firstMatch
            XCTAssertTrue(chapter.waitForExistence(timeout: 30)); chapter.tap()
            wait(90) { self.field("ready", app) == "true" && self.number("characters", app) > 250 && !app.buttons["weReadTOCClose"].exists }
        }
        let notice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "saved position cannot be restored")).firstMatch
        if notice.exists {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.26)).tap()
            wait { !notice.exists }
        }
        app.buttons["Playback Speed"].tap(); app.buttons["3x"].tap()
        if field("readActive", app) != "true" || field("readPaused", app) == "true" { read.tap() }
        wait(180) { self.field("playing", app) == "true" && self.number("wordVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        let firstPage = field("page", app)
        let readTurns = number("automaticReadTurns", app)
        capture(app, "\(platform)-natural-read-before")
        wait(240) { self.number("automaticReadTurns", app) > readTurns && self.field("page", app) != firstPage && self.field("playing", app) == "true" && self.number("wordVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        capture(app, "\(platform)-natural-read-next")
        read.tap(); wait { self.field("playing", app) == "false" }
        app.segmentedControls["readerModePicker"].buttons["Explain"].tap()
        let start = app.buttons["explainStartButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()
        wait(240) { self.field("playing", app) == "true" && self.number("inkVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        let explainTurns = number("automaticExplainTurns", app)
        let physicalExplainPages = number("physicalExplainPages", app)
        let firstScope = field("explainScope", app)
        // Finish an explanation after a real reflow as well: a wider page
        // can reveal text beyond the immutable scope already being narrated.
        rotate(app, .landscapeLeft)
        wait(90) { self.field("playing", app) == "true" && self.number("inkVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        let explainedPage = field("page", app)
        capture(app, "\(platform)-natural-explain-before")
        wait(300) {
            self.number("automaticExplainTurns", app) > explainTurns &&
            (platform != "weread" || self.number("physicalExplainPages", app) > physicalExplainPages) && self.field("page", app) != explainedPage &&
            self.field("explainScope", app) != firstScope && self.field("playing", app) == "true" && self.number("inkVisible", app) > 0 && self.field("surfaceCovered", app) == "false"
        }
        capture(app, "\(platform)-natural-explain-next")
        app.buttons["explainPlayPauseButton"].tap()
        wait { self.field("playing", app) == "false" }
        app.buttons["Playback Speed"].tap(); app.buttons["1x"].tap()
        app.buttons["readerMinimizeButton"].tap()
    }

    func testGoogleBooksShelfAccessibilitySearchAndNarrowWindow() throws {
        var app = try home("google_books", extra: ["-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL", "-CastReaderIPadDarkAppearance"])
        var viewAll = app.buttons["homeShelfViewAll.google_books"]
        reveal(viewAll, in: app); viewAll.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Sasha")
        let match = app.buttons["googleBooksBook.QrpAEQAAQBAJ"]
        XCTAssertTrue(match.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["googleBooksBook.b_40EQAAQBAJ"].exists)
        capture(app, "google_books-largest-type-search-keyboard")
        rotate(app, .landscapeLeft)
        XCTAssertTrue(match.isHittable)
        capture(app, "google_books-largest-type-search-landscape")
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        let sort = app.buttons["googleBooksShelfSort"]
        if sort.exists && sort.isHittable { sort.tap(); app.buttons["Title"].firstMatch.tap() }
        let refresh = app.buttons["refreshGoogleBooksLibraryButton"]
        XCTAssertGreaterThanOrEqual(refresh.frame.width, 44)
        XCTAssertGreaterThanOrEqual(refresh.frame.height, 44)
        capture(app, "google_books-largest-type-sorted")
        app.terminate(); XCUIDevice.shared.orientation = .portrait
        app = try home("google_books")
        viewAll = app.buttons["homeShelfViewAll.google_books"]
        reveal(viewAll, in: app); viewAll.tap()
        let window = app.windows.firstMatch
        let original = window.frame
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.992, dy: 0.992))
            .press(forDuration: 1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.65)))
        wait {
            let size = window.frame.size
            return size.width >= 320 && size.height >= 400 && size.width < original.width - 100
                && app.searchFields.firstMatch.isHittable
        }
        XCTAssertTrue(app.searchFields.firstMatch.isHittable)
        XCTAssertTrue(app.buttons["googleBooksBook.b_40EQAAQBAJ"].isHittable)
        capture(app, "google_books-narrow-shelf")
        app.buttons["googleBooksBook.b_40EQAAQBAJ"].tap()
        wait(120) { app.buttons["readPlayPauseButton"].exists && self.field("ready", app) == "true" }
        if field("playing", app) == "true" { app.buttons["readPlayPauseButton"].tap() }
        capture(app, "google_books-narrow-reader")
        app.buttons["readerMoreButton"].tap(); app.buttons["readerAppearanceMenuItem"].tap()
        wait { self.number("panelCount", app) > 0 && self.number("panelClipped", app) == 0 }
        let enlarge = app.buttons["放大字体"]
        // Scroll inside the provider dialog's visible body, not the native
        // transport underneath it. Tiny windows may need several short pans.
        for _ in 0..<6 {
            if enlarge.isHittable && enlarge.frame.maxY < app.webViews["googleBooksReaderWebView"].frame.maxY - 44 { break }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.60))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.43)))
        }
        XCTAssertTrue(enlarge.isHittable)
        enlarge.tap(); app.buttons["缩小字体"].tap()
        // Native value changes can scroll their row back toward the bottom.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.60))
            .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.49)))
        capture(app, "google_books-narrow-native-appearance")
        let closeAppearance = app.buttons["关闭显示选项"]
        for _ in 0..<6 {
            if closeAppearance.isHittable { break }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.43))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.60)))
        }
        closeAppearance.tap()
        app.buttons["readerMinimizeButton"].tap()
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.055)).doubleTap()
        wait { app.windows.firstMatch.frame.width >= 700 }
        app.buttons["readerMiniPlayerExpand"].tap()
        let contents = app.buttons["打开目录"]
        XCTAssertTrue(contents.waitForExistence(timeout: 15)); contents.tap()
        let closeContents = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "关闭")).firstMatch
        XCTAssertTrue(closeContents.waitForExistence(timeout: 15))
        capture(app, "google_books-native-contents-portrait")
        rotate(app, .landscapeLeft)
        XCTAssertTrue(closeContents.isHittable)
        capture(app, "google_books-native-contents-landscape")
        closeContents.tap()
        app.buttons["readerMinimizeButton"].tap()
        rotate(app, .portrait)
    }

    func testKoboShelfAccessibilitySearchAndNarrowWindow() throws {
        var app = try home("kobo", extra: ["-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL", "-CastReaderIPadDarkAppearance"])
        var all = app.buttons["homeShelfViewAll.kobo"]
        reveal(all, in: app); all.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Two")
        let result = app.buttons["koboLibraryBook.b849f0ce-d6b3-42f6-bcb6-e6774d00d132"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["koboLibraryBook.68e59395-a923-4e9f-83ff-d4033694af84"].exists)
        capture(app, "kobo-largest-type-search-keyboard")
        rotate(app, .landscapeLeft)
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        XCTAssertTrue(result.isHittable)
        capture(app, "kobo-largest-type-search-landscape")
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 3))
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        let options = app.buttons["koboShelfOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(options.frame.width, 44)
        XCTAssertGreaterThanOrEqual(options.frame.height, 44)
        options.tap()
        let titleSort = app.buttons["Title"].firstMatch
        if !titleSort.waitForExistence(timeout: 3) { options.tap() }
        XCTAssertTrue(titleSort.waitForExistence(timeout: 10)); titleSort.tap()
        capture(app, "kobo-largest-type-sorted")
        app.terminate(); XCUIDevice.shared.orientation = .portrait
        app = try home("kobo")
        all = app.buttons["homeShelfViewAll.kobo"]
        reveal(all, in: app); all.tap()
        let window = app.windows.firstMatch, width = app.windows.firstMatch.frame.width
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.992, dy: 0.992))
            .press(forDuration: 1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.65)))
        wait { window.frame.width >= 320 && window.frame.height >= 400 && window.frame.width < width - 100 }
        XCTAssertTrue(app.searchFields.firstMatch.isHittable)
        let book = app.buttons["koboLibraryBook.68e59395-a923-4e9f-83ff-d4033694af84"]
        XCTAssertTrue(book.isHittable); capture(app, "kobo-narrow-shelf")
        book.tap()
        wait(120) { app.buttons["readPlayPauseButton"].exists && self.field("ready", app) == "true" }
        if field("playing", app) == "true" { app.buttons["readPlayPauseButton"].tap() }
        for id in ["readerMinimizeButton", "readerModeMenu", "readPlayPauseButton", "readerMoreButton"] {
            XCTAssertTrue(app.buttons[id].isHittable, id)
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height, 44, id)
        }
        capture(app, "kobo-narrow-reader")
        app.buttons["readerMoreButton"].tap(); app.buttons["readerAppearanceMenuItem"].tap()
        wait(15) { self.number("panelCount", app) > 0 && self.number("panelClipped", app) == 0 }
        let larger = app.buttons["Increase font size"]
        for _ in 0..<5 {
            if larger.isHittable && larger.frame.maxY < app.buttons["readerMoreButton"].frame.minY { break }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.62))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.40)))
        }
        XCTAssertTrue(larger.isHittable); larger.tap(); app.buttons["Decrease font size"].tap()
        capture(app, "kobo-narrow-native-appearance")
        let close = app.buttons["Close dialog"]
        for _ in 0..<5 {
            if close.isHittable { break }
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.40))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.70, dy: 0.62)))
        }
        close.tap()
        app.buttons["readerMinimizeButton"].tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.055)).doubleTap()
        wait { window.frame.width >= 700 }
        app.buttons["readerMiniPlayerExpand"].tap()
        let contents = app.buttons["Table of Contents"]
        XCTAssertTrue(contents.waitForExistence(timeout: 15)); contents.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        capture(app, "kobo-native-contents-portrait")
        rotate(app, .landscapeLeft)
        wait { self.field("surfaceCovered", app) == "false" }
        XCTAssertTrue(close.isHittable)
        capture(app, "kobo-native-contents-landscape")
        close.tap(); app.buttons["readerMinimizeButton"].tap()
        rotate(app, .portrait)
    }

    func testWeReadShelfAccessibilitySearchAndNarrowWindow() throws {
        var app = try home("weread", extra: ["-UIPreferredContentSizeCategoryName",
            "UICTContentSizeCategoryAccessibilityXXXL", "-CastReaderIPadDarkAppearance"])
        var all = app.buttons["homeShelfViewAll.weread"]
        reveal(all, in: app); all.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 10)); search.tap(); search.typeText("Franklin")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadLibraryBook.", "Franklin")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["weReadLibraryBook.weread:f8832a00728d9ff9f8847b2"].exists)
        capture(app, "weread-largest-type-search-keyboard")
        rotate(app, .landscapeLeft)
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        XCTAssertTrue(result.isHittable)
        capture(app, "weread-largest-type-search-landscape")
        search.tap(); search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        if app.buttons["Cancel"].exists { app.buttons["Cancel"].tap() }
        if app.buttons["Hide keyboard"].exists { app.buttons["Hide keyboard"].tap() }
        let sort = app.buttons["weReadShelfSort"]
        XCTAssertTrue(sort.waitForExistence(timeout: 10)); sort.tap()
        let title = app.buttons["Title"].firstMatch
        if !title.waitForExistence(timeout: 3) { sort.tap() }
        XCTAssertTrue(title.waitForExistence(timeout: 10)); title.tap()
        let refresh = app.buttons["refreshWeReadLibraryButton"]
        XCTAssertGreaterThanOrEqual(refresh.frame.width, 44)
        XCTAssertGreaterThanOrEqual(refresh.frame.height, 44)
        capture(app, "weread-largest-type-sorted")
        app.terminate(); XCUIDevice.shared.orientation = .portrait
        app = try home("weread")
        all = app.buttons["homeShelfViewAll.weread"]
        reveal(all, in: app); all.tap()
        let loadMore = app.buttons["weReadLoadMore"]
        for _ in 0..<20 {
            if loadMore.exists && loadMore.isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(loadMore.isHittable); capture(app, "weread-first-page-load-more")
        loadMore.tap()
        wait { !loadMore.isHittable }
        capture(app, "weread-second-page-loaded")
        app.terminate()
        app = try home("weread")
        all = app.buttons["homeShelfViewAll.weread"]
        reveal(all, in: app); all.tap()
        let window = app.windows.firstMatch, width = app.windows.firstMatch.frame.width
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.992, dy: 0.992))
            .press(forDuration: 1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.65)))
        wait { window.frame.width >= 320 && window.frame.height >= 400 && window.frame.width < width - 100 }
        let book = app.buttons["weReadLibraryBook.weread:f8832a00728d9ff9f8847b2"]
        XCTAssertTrue(book.isHittable); capture(app, "weread-narrow-shelf")
        book.tap()
        let read = app.buttons["readPlayPauseButton"]
        wait(120) { read.exists && self.field("ready", app) == "true" }
        if field("playing", app) == "true" { read.tap() }
        let resumeNotice = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "saved position cannot be restored")).firstMatch
        XCTAssertFalse(resumeNotice.exists, "The actual listening position must survive reopening into a compact page")
        if field("readActive", app) != "true" || field("readPaused", app) == "true" { read.tap() }
        wait(120) { self.field("playing", app) == "true" && self.number("time", app) > 1 && self.number("wordVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        XCTAssertFalse(resumeNotice.exists)
        capture(app, "weread-narrow-resumed-audio-highlight")
        read.tap(); wait { self.field("playing", app) == "false" }
        for id in ["readerMinimizeButton", "readerModeMenu", "readPlayPauseButton", "readerMoreButton"] {
            XCTAssertTrue(app.buttons[id].isHittable, id)
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(app.buttons[id].frame.height, 44, id)
        }
        capture(app, "weread-narrow-reader")
        app.buttons["readerMoreButton"].tap(); app.buttons["readerAppearanceMenuItem"].tap()
        let nativeAa = app.webViews.buttons["Reading settings"]
        XCTAssertTrue(nativeAa.waitForExistence(timeout: 15)); XCTAssertTrue(nativeAa.isHittable)
        capture(app, "weread-narrow-native-appearance-trigger")
        nativeAa.tap()
        wait { self.number("panelCount", app) > 0 && self.number("panelClipped", app) == 0 }
        capture(app, "weread-narrow-native-appearance")
        // The provider dismisses its floating panel when the visible body is tapped.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.015, dy: 0.40)).tap()
        wait { self.number("panelCount", app) == 0 }
        app.buttons["readerMinimizeButton"].tap()
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.055)).doubleTap()
        wait { window.frame.width >= 700 }
        app.buttons["readerMiniPlayerExpand"].tap()
        app.buttons["Table of Contents"].tap()
        let close = app.buttons["weReadTOCClose"]
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "weReadTOCEntry.")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30))
        capture(app, "weread-native-contents-portrait")
        rotate(app, .landscapeLeft)
        XCTAssertTrue(close.isHittable)
        capture(app, "weread-native-contents-landscape")
        let oldPage = field("page", app)
        let introduction = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadTOCEntry.", "说明")).firstMatch
        XCTAssertTrue(introduction.isHittable); introduction.tap()
        wait(90) { !close.exists && self.field("ready", app) == "true" && self.field("page", app) != oldPage && self.number("characters", app) > 20 }
        capture(app, "weread-contents-introduction-selected-after-reflow")
        app.buttons["Table of Contents"].tap()
        let chapter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadTOCEntry.", "第一章 开往蒙古的列车")).firstMatch
        XCTAssertTrue(chapter.isHittable); chapter.tap()
        wait(90) { !close.exists && self.field("ready", app) == "true" && self.number("characters", app) > 20 }
        let visibleChapter = app.webViews.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "开往蒙古的列车")).firstMatch
        XCTAssertTrue(visibleChapter.waitForExistence(timeout: 15))
        XCTAssertFalse(resumeNotice.exists)
        capture(app, "weread-contents-chapter-selected-after-reflow")
        app.buttons["readerMinimizeButton"].tap()
        rotate(app, .portrait)
    }

    private func verify(_ platform: String, launch: [String] = []) throws {
        let app = try home(platform, extra: launch)
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.\(platform).")).firstMatch
        reveal(book, in: app)
        book.tap()
        let read = app.buttons["readPlayPauseButton"]
        if platform == "weread" {
            wait(45) { read.exists && (self.field("ready", app) == "true" || app.buttons["下一页"].exists) }
            if field("ready", app) != "true" { read.tap() }
        }
        wait(120) { read.exists && self.field("ready", app) == "true" }
        if platform == "weread" {
            if field("playing", app) == "true" { read.tap() }
            app.buttons["Table of Contents"].tap()
            let chapter = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "weReadTOCEntry.", "第一章 开往蒙古的列车")).firstMatch
            XCTAssertTrue(chapter.waitForExistence(timeout: 30)); chapter.tap()
            wait(90) { self.field("ready", app) == "true" && self.number("characters", app) > 250 && !app.buttons["weReadTOCClose"].exists }
        }
        XCTAssertGreaterThan(number("characters", app), 20)
        capture(app, "\(platform)-reader-ready-portrait")
        let changedPosition = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "saved position cannot be restored")).firstMatch
        if platform == "google_books" || platform == "kobo" || changedPosition.exists {
            // Select a real paragraph so rotation starts with enough audio
            // remaining to assert exact source identity. A nearly finished
            // restored segment could legitimately advance during rotation.
            if platform == "kobo" {
                let web = app.webViews["koboReaderWebView"], bounds = app.webViews["koboReaderWebView"].frame
                let paragraph = web.staticTexts.allElementsBoundByIndex.first {
                    let frame = $0.frame
                    return $0.label.count > 80 && frame.width > 20 && frame.height > 20 &&
                        frame.minX >= bounds.minX + 20 && frame.maxX <= bounds.maxX - 20 &&
                        frame.minY >= bounds.minY + 20 && frame.maxY <= bounds.maxY - 20
                }
                XCTAssertNotNil(paragraph, "Select observed body text inside the chapter viewport")
                if let paragraph {
                    // Kobo's gesture layer owns hit testing above its iframe;
                    // tap the observed text position through that real layer.
                    let point = paragraph.frame
                    app.windows.firstMatch.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: point.minX + 12, dy: point.minY + 12)).tap()
                }
                wait { self.field("readActive", app) == "true" && self.field("readPaused", app) == "false" }
            } else {
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.26)).tap()
            }
            wait { !changedPosition.exists }
        }
        // Preserve the user's automatic playback preference. If opening the
        // real book already requested speech, tapping now would pause loading.
        if field("readActive", app) != "true" || field("readPaused", app) == "true" { read.tap() }
        wait(180) { self.field("playing", app) == "true" && self.number("time", app) > 1 && self.number("wordVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        capture(app, "\(platform)-read-highlight-portrait")
        let session = field("readSession", app)
        let spokenSource = field("audioText", app)
        let time = number("time", app), segment = field("segment", app)
        rotate(app, .landscapeLeft)
        wait(90) { self.field("playing", app) == "true" && self.number("wordVisible", app) > 0 && self.field("surfaceCovered", app) == "false" &&
            (self.field("segment", app) != segment || self.number("time", app) > time + 0.3) }
        XCTAssertEqual(field("readSession", app), session)
        if field("segment", app) == segment {
            XCTAssertEqual(field("audioText", app), spokenSource, "Rotation must keep the speaking source")
        } else {
            // A restored segment may naturally finish during the gesture.
            // Allow only forward queue progression, never restart/reversal.
            let before = segment.split(separator: "-").compactMap { Int($0) }
            let after = field("segment", app).split(separator: "-").compactMap { Int($0) }
            XCTAssertEqual(before.count, 2); XCTAssertEqual(after.count, 2)
            XCTAssertTrue(after[0] > before[0] || (after[0] == before[0] && after[1] > before[1]))
        }
        capture(app, "\(platform)-read-highlight-landscape")
        read.tap()
        wait { self.field("playing", app) == "false" }
        let paused = number("time", app), pausedAudioText = field("audioText", app)
        rotate(app, .portrait)
        wait(60) { self.number("wordVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        XCTAssertEqual(number("time", app), paused, accuracy: 0.4)
        XCTAssertEqual(field("audioText", app), pausedAudioText)
        capture(app, "\(platform)-read-paused-reflow")

        // Platform-native Aa is opened through the same More entry as Kindle.
        app.buttons["readerMoreButton"].tap()
        let appearance = app.buttons["readerAppearanceMenuItem"]
        XCTAssertTrue(appearance.waitForExistence(timeout: 10)); appearance.tap()
        if platform == "google_books" {
            wait { self.number("panelCount", app) > 0 && self.number("panelClipped", app) == 0 }
            let larger = app.buttons["放大字体"], smaller = app.buttons["缩小字体"]
            XCTAssertTrue(larger.isHittable); larger.tap()
            XCTAssertTrue(smaller.isHittable); smaller.tap()
        }
        if platform == "weread" {
            let nativeAa = app.webViews.buttons["Reading settings"]
            XCTAssertTrue(nativeAa.waitForExistence(timeout: 15)); nativeAa.tap()
            wait { self.number("panelCount", app) > 0 && self.number("panelClipped", app) == 0 }
            let label = app.staticTexts["字号大小"]
            XCTAssertTrue(label.isHittable)
            label.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 53)).tap()
            wait(30) { self.number("providerFont", app) == 18 }
            let font = number("providerFont", app)
            // Real provider slider observed in the live accessibility tree:
            // seven stops across its 404 pt track below this native heading.
            label.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 74, dy: 53)).tap()
            wait(30) { self.number("providerFont", app) > 0 && self.number("providerFont", app) != font }
            capture(app, "weread-native-font-increased")
            label.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 12, dy: 53)).tap()
            wait(30) { self.number("providerFont", app) == font }
        }
        if platform == "kobo" {
            XCTAssertTrue(app.buttons["Increase font size"].waitForExistence(timeout: 15))
            app.buttons["Increase font size"].tap()
            app.buttons["Decrease font size"].tap()
        }
        capture(app, "\(platform)-appearance-portrait")
        rotate(app, .landscapeLeft)
        if platform == "google_books" {
            wait { self.number("panelCount", app) > 0 && self.number("panelClipped", app) == 0 }
        }
        if platform == "kobo" {
            wait { self.field("surfaceCovered", app) == "false" }
            XCTAssertTrue(app.buttons["Close dialog"].isHittable)
        }
        capture(app, "\(platform)-appearance-landscape")
        if platform == "google_books" {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.75))
                .press(forDuration: 0.1, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.84, dy: 0.40)))
            let increase = app.buttons["增大行高"], decrease = app.buttons["减小行高"]
            XCTAssertTrue(increase.isHittable); XCTAssertTrue(decrease.isHittable)
            XCTAssertLessThan(increase.frame.maxY, app.buttons["readerMoreButton"].frame.minY)
            increase.tap(); decrease.tap()
            capture(app, "google_books-appearance-landscape-scrolled")
        }
        // Native platform panels are dismissed using a tap on the book body;
        // the following playback/mode assertion verifies the dismissal.
        if platform == "google_books" {
            app.buttons["关闭显示选项"].tap()
            wait { self.number("panelCount", app) == 0 }
        } else if platform == "kobo" {
            app.buttons["Close dialog"].tap()
        } else {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.40)).tap()
            wait { self.number("panelCount", app) == 0 }
        }
        rotate(app, .portrait)

        let picker = app.segmentedControls["readerModePicker"]
        XCTAssertTrue(picker.buttons["Explain"].isHittable); picker.buttons["Explain"].tap()
        let start = app.buttons["explainStartButton"]
        XCTAssertTrue(start.waitForExistence(timeout: 15)); start.tap()
        let explain = app.buttons["explainPlayPauseButton"]
        wait(240) { explain.exists && self.field("playing", app) == "true" && self.number("inkVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        capture(app, "\(platform)-explain-ink-portrait")
        explain.tap()
        wait { self.field("playing", app) == "false" }
        let explainSession = field("explainSession", app)
        let explainTime = number("time", app), markIDs = field("markIDs", app)
        rotate(app, .landscapeLeft)
        var settled: Date?
        wait(90) {
            guard self.number("inkVisible", app) > 0 && self.field("surfaceCovered", app) == "false", self.field("playing", app) == "false" else { settled = nil; return false }
            if settled == nil { settled = Date() }
            return Date().timeIntervalSince(settled!) > 2
        }
        XCTAssertEqual(field("explainSession", app), explainSession)
        XCTAssertEqual(field("markIDs", app), markIDs)
        XCTAssertEqual(number("time", app), explainTime, accuracy: 0.4)
        capture(app, "\(platform)-explain-ink-landscape")
        app.buttons["readerMinimizeButton"].tap()
        rotate(app, .portrait)
        let mini = app.buttons["readerMiniPlayerExpand"]
        XCTAssertTrue(mini.waitForExistence(timeout: 15)); XCTAssertTrue(mini.isHittable)
        XCTAssertGreaterThanOrEqual(mini.frame.height, 44); mini.tap()
        wait(60) { explain.exists && explain.isHittable && self.number("inkVisible", app) > 0 && self.field("surfaceCovered", app) == "false" }
        XCTAssertEqual(field("explainSession", app), explainSession)
        XCTAssertEqual(number("time", app), explainTime, accuracy: 0.4)
        capture(app, "\(platform)-expanded-paused-portrait")

        picker.buttons["Read Aloud"].tap()
        wait { read.exists && read.isHittable }
        let oldPage = field("page", app)
        let next = app.buttons["readerNextPageButton"]
        XCTAssertTrue(next.isHittable); next.tap()
        wait(120) { self.field("ready", app) == "true" && !self.field("page", app).isEmpty && self.field("page", app) != oldPage }
        XCTAssertEqual(field("playing", app), "false", "Manual browsing while paused must remain paused")
        capture(app, "\(platform)-manual-next-page")
    }
}
