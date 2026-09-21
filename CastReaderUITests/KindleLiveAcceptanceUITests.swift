import XCTest

/// Explicitly selected only on a device the user has signed into Kindle.
/// Never signs in, clears a shelf or copies WebKit credentials.
final class KindleLiveAcceptanceUITests: XCTestCase {
    private lazy var localizedPlaybackStates: [String: Set<String>] = {
        // Physical devices cannot read the build machine's #filePath. Keep the
        // two release-core languages usable there, then expand from the catalog
        // when running the nine-language simulator capture workflow.
        let fallback: [String: Set<String>] = [
            "paused": ["paused", "已暂停"],
            "playing": ["playing", "正在播放", "朗读中", "解读中"]
        ]
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        guard let data = try? Data(contentsOf: root.appendingPathComponent("CastReader/Localizable.xcstrings")),
              let catalog = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let strings = catalog["strings"] as? [String: Any] else { return fallback }
        var result: [String: Set<String>] = [:]
        for (state, keys) in ["paused": ["已暂停"], "playing": ["正在播放", "朗读中", "解读中"]] {
            var values: Set<String> = [state]
            for key in keys {
                values.insert(key)
                let localizations = (strings[key] as? [String: Any])?["localizations"] as? [String: Any] ?? [:]
                for locale in localizations.values {
                    if let unit = (locale as? [String: Any])?["stringUnit"] as? [String: Any],
                       let value = unit["value"] as? String { values.insert(value.lowercased()) }
                }
            }
            result[state] = values
        }
        return result
    }()

    private func playbackIs(_ element: XCUIElement, _ state: String) -> Bool {
        localizedPlaybackStates[state]?.contains((element.value as? String ?? "").lowercased()) == true
    }

    private func wait(_ timeout: Double, _ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let app = XCUIApplication()
            // The user's clipboard may legitimately offer a different reading
            // task at launch. Dismiss that visible suggestion through its UI;
            // never read or overwrite clipboard contents for this Kindle test.
            if app.staticTexts["There's text in your clipboard"].exists {
                let ignore = app.buttons["Ignore"]
                if ignore.isHittable { ignore.tap() }
                return false
            }
            // The authorized account can have another device's saved location.
            // Keep this test's current page through Amazon's visible native UI.
            if !app.buttons["kindleTOCClose"].exists,
               app.staticTexts["Most Recent Page Read"].exists {
                let keepCurrentPage = app.buttons["No"]
                if keepCurrentPage.isHittable { keepCurrentPage.tap() }
                // Let Amazon finish dismissing/reflowing before evaluating a
                // control that may still be covered by this modal animation.
                return false
            }
            return condition()
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }

    private func openReadingSettings(_ app: XCUIApplication) {
        let appearance = app.buttons["readerAppearanceMenuItem"]
        if !appearance.exists {
            app.buttons["readerMoreButton"].tap()
        }
        XCTAssertTrue(appearance.waitForExistence(timeout: 5))
        appearance.tap()
    }

    private func waitForPausedReader(_ app: XCUIApplication) {
        var readySince: Date?
        wait(60) {
            let play = app.buttons["kindleReadPlayPauseButton"]
            let settings = app.buttons["readerMoreButton"]
            let loading = app.webViews.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Loading content")).firstMatch
            // During the reader's presentation iOS can publish controls with
            // zero frames. Asking isHittable then raises an XCTest failure
            // instead of returning false. Wait for actual laid-out controls.
            let playFrame = play.frame
            let settingsFrame = settings.frame
            let ready = !loading.exists && !app.activityIndicators.firstMatch.exists &&
                !app.buttons["kindleReadingSettingsDone"].exists &&
                !app.staticTexts["Most Recent Page Read"].exists &&
                playFrame.width > 1 && playFrame.height > 1 && playFrame.intersects(app.windows.firstMatch.frame) &&
                settingsFrame.width > 1 && settingsFrame.height > 1 && settingsFrame.intersects(app.windows.firstMatch.frame) &&
                self.playbackIs(play, "paused") && play.isEnabled && play.isHittable &&
                settings.isEnabled && settings.isHittable
            guard ready else { readySince = nil; return false }
            if readySince == nil { readySince = Date() }
            return Date().timeIntervalSince(readySince!) >= 2
        }
    }

    private func waitForReadingSettingsReady(_ app: XCUIApplication) {
        var readySince: Date?
        wait(60) {
            let font = app.staticTexts["kindleFontValue"]
            let done = app.buttons["kindleReadingSettingsDone"]
            // A visible Amazon sync dialog revokes the native settings request.
            // After the wait helper chooses No, make one new explicit request;
            // a displayed error is retained and cannot pass this readiness gate.
            if !done.exists, !app.staticTexts["Most Recent Page Read"].exists {
                let settings = app.buttons["readerMoreButton"]
                if settings.isHittable && settings.isEnabled { self.openReadingSettings(app) }
            }
            let ready = done.exists && font.exists && Double(font.label) != nil &&
                (app.buttons["kindleFontIncrease"].isEnabled || app.buttons["kindleFontDecrease"].isEnabled) &&
                !app.activityIndicators.firstMatch.exists
            guard ready else { readySince = nil; return false }
            if readySince == nil { readySince = Date() }
            return Date().timeIntervalSince(readySince!) >= 1
        }
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    private func tapFootnoteSwitch(_ app: XCUIApplication) {
        let row = app.switches["kindleSkipFootnotes"]
        let control = row.descendants(matching: .switch).firstMatch
        XCTAssertTrue(control.waitForExistence(timeout: 5))
        for _ in 0..<5 {
            if control.isHittable,
               control.frame.minY >= app.navigationBars.firstMatch.frame.maxY,
               control.frame.maxY <= app.frame.maxY - 44 { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(control.isHittable)
        control.tap()
    }

    override func tearDown() {
        let app = XCUIApplication()
        if app.state == .runningForeground { snapshot(app, "Kindle-live-at-teardown") }
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    func testCaptureIPadAppStoreFiveScreens() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_IPAD_STORE_CAPTURE"] == "1")
        continueAfterFailure = false
        let language = ProcessInfo.processInfo.environment["CASTREADER_CAPTURE_LANGUAGE"] ?? "en"
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-CastReaderSkipLibraryOnboarding", "-CastReaderIPadAcceptance",
            "-CastReaderTTSClockDiagnostics", "-auto_play", "NO", "-tts_speed", "1",
            "-CastReaderRegion", "global", "-AppleLanguages", "(\(language))",
            "-interfaceLanguage", language, "-explain_language", "en"]
        app.launch()
        wait(40) { app.buttons["plusImportButton"].exists }
        if app.windows.firstMatch.frame.width < 700 {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.055)).doubleTap()
            wait(15) { app.windows.firstMatch.frame.width >= 700 }
        }
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS[c] %@", "homeShelfBook.kindle.", "Journey")).firstMatch
        wait(30) {
            guard book.exists else { return false }
            if book.isHittable { return true }
            app.scrollViews.firstMatch.swipeUp(); return false
        }
        snapshot(app, "store-\(language)-01-home")
        book.tap()
        waitForPausedReader(app)
        let metrics = app.otherElements["kindlePlaybackMetrics"]
        func number(_ key: String) -> Double {
            let value = (metrics.value as? String ?? "").split(separator: ";").first { $0.hasPrefix(key + "=") }
            return value.flatMap { Double($0.dropFirst(key.count + 1)) } ?? -1
        }
        let read = app.buttons["kindleReadPlayPauseButton"]
        read.tap()
        wait(150) { self.playbackIs(read, "playing") && number("time") >= 2 }
        snapshot(app, "store-\(language)-02-kindle-read")
        read.tap()
        waitForPausedReader(app)
        app.buttons["kindleModeButton_explain"].tap()
        let explain = app.buttons["kindleExplainPlayPauseButton"]
        wait(30) { explain.exists && explain.isEnabled && explain.isHittable }
        explain.tap()
        wait(180) { self.playbackIs(explain, "playing") && number("marks") >= 2 && number("ink") > 0 }
        explain.tap()
        wait(15) { self.playbackIs(explain, "paused") }
        snapshot(app, "store-\(language)-03-kindle-explain")
        app.buttons["kindleMinimizeButton"].tap()
        wait(15) { app.buttons["plusImportButton"].isHittable }
        // iPad floating tabs expose duplicate labels; target the tab's icon ID,
        // not a retained reader's off-screen Voice button during minimization.
        let voice = app.buttons["waveform"].firstMatch
        wait(15) { voice.exists && voice.isHittable }
        voice.tap()
        wait(30) { app.textFields["voiceSearchField"].exists || app.segmentedControls["voiceBrowserCategoryPicker"].exists }
        snapshot(app, "store-\(language)-04-voices")
        let home = app.buttons["house.fill"].firstMatch
        wait(15) { home.isHittable }
        home.tap()
        app.buttons["plusImportButton"].tap()
        wait(15) { app.buttons["importSource.file"].exists && app.buttons["importSource.file"].isHittable }
        snapshot(app, "store-\(language)-05-import")
        app.terminate()
    }

    func testAuthorizedIPadTOCAndSettingsPanels() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_KINDLE_LIVE_ACCEPTANCE"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
            "-auto_play", "NO", "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        if app.windows.firstMatch.frame.width < 700 {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.055)).doubleTap()
            wait(10) { app.windows.firstMatch.frame.width >= 700 }
        }
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.kindle.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        wait(20) {
            let frame = book.frame
            if frame.width > 1 && frame.height > 1 && frame.intersects(app.windows.firstMatch.frame) && book.isHittable { return true }
            app.scrollViews.firstMatch.swipeUp(); return false
        }
        book.tap()
        waitForPausedReader(app)
        app.buttons["Table of Contents"].tap()
        let entry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "kindleTOCEntry.")).firstMatch
        wait(45) { entry.exists && entry.isEnabled }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            wait(10) { app.buttons["kindleTOCClose"].isHittable }
            XCTAssertLessThanOrEqual(entry.frame.width, 420)
            snapshot(app, "iPad-live-TOC-\(orientation.rawValue)")
        }
        app.buttons["kindleTOCClose"].tap()
        waitForPausedReader(app)
        openReadingSettings(app)
        waitForReadingSettingsReady(app)
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(15) { app.buttons["kindleReadingSettingsDone"].isHittable }
        snapshot(app, "iPad-live-Aa-landscape")
        app.buttons["kindleReadingSettingsDone"].tap()
        waitForPausedReader(app)
        snapshot(app, "iPad-live-after-Aa-landscape")
        app.terminate()
    }

    func testAuthorizedIPadReadExplainAndRotation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_KINDLE_LIVE_ACCEPTANCE"] == "1")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
            "-CastReaderIPadAcceptance", "-CastReaderTTSClockDiagnostics", "-auto_play", "NO",
            "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        if app.windows.firstMatch.frame.width < 700 {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.055)).doubleTap()
            wait(10) { app.windows.firstMatch.frame.width >= 700 }
        }
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.kindle.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        wait(20) {
            let frame = book.frame
            if frame.width > 1 && frame.height > 1 && frame.intersects(app.windows.firstMatch.frame) && book.isHittable { return true }
            app.scrollViews.firstMatch.swipeUp(); return false
        }
        snapshot(app, "iPad-live-Kindle-shelf")
        book.tap()
        waitForPausedReader(app)
        let read = app.buttons["kindleReadPlayPauseButton"]
        let metrics = app.otherElements["kindlePlaybackMetrics"]
        func field(_ key: String) -> String {
            guard metrics.exists else { return "" }
            return (metrics.value as? String ?? "").split(separator: ";").first { $0.hasPrefix(key + "=") }
                .map { String($0.dropFirst(key.count + 1)) } ?? ""
        }
        func number(_ key: String) -> Double { Double(field(key)) ?? -1 }
        read.tap()
        wait(150) { read.value as? String == "Playing" && number("time") >= 1.5 }
        wait(45) { read.exists && read.value as? String == "Playing" && number("duration") - number("time") >= 3 }
        snapshot(app, "iPad-live-Read-portrait")
        let priorTime = number("time")
        let priorSegment = field("segment")
        let readSession = field("readSession")
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(6) { read.exists && read.value as? String == "Playing" && (field("segment") != priorSegment || number("time") >= priorTime + 0.3) }
        snapshot(app, "iPad-live-Read-reflow-in-progress")
        wait(90) { app.frame.width > app.frame.height && read.exists && read.value as? String == "Playing" && number("time") >= 1.5 && field("stable") == "true" }
        XCTAssertEqual(field("readSession"), readSession, "Rotation must not regenerate the reading session")
        snapshot(app, "iPad-live-Read-landscape")
        if ProcessInfo.processInfo.environment["CASTREADER_KINDLE_REFLOW_CONTINUATION"] == "1" {
            wait(420) { read.exists && read.value as? String == "Playing" && number("continuations") > 0 && field("stable") == "true" }
            XCTAssertNotEqual(field("readSession"), readSession, "Only natural page completion creates the next page session")
            snapshot(app, "iPad-live-Read-continued-after-reflow")
        }
        read.tap()
        waitForPausedReader(app)
        app.buttons["kindleModeButton_explain"].tap()
        let explain = app.buttons["kindleExplainPlayPauseButton"]
        wait(30) { explain.exists && explain.isEnabled && explain.isHittable }
        explain.tap()
        wait(180) { explain.exists && (explain.value as? String)?.lowercased() == "playing" && number("time") >= 1.5 && number("marks") > 0 }
        snapshot(app, "iPad-live-Explain-landscape-marks")
        explain.tap()
        wait(15) { explain.exists && (explain.value as? String)?.lowercased() == "paused" }
        let marks = number("marks")
        let explainSession = field("explainSession")
        let pausedTime = number("time")
        XCUIDevice.shared.orientation = .portrait
        var stableSince: Date?
        wait(60) {
            guard app.frame.height > app.frame.width, field("stable") == "true",
                  number("marks") >= marks, number("shown") >= marks, number("ink") > 0, explain.exists, explain.isHittable else {
                stableSince = nil; return false
            }
            if stableSince == nil { stableSince = Date() }
            return Date().timeIntervalSince(stableSince!) > 3
        }
        XCTAssertEqual(field("explainSession"), explainSession)
        XCTAssertEqual(number("time"), pausedTime, accuracy: 0.4)
        XCTAssertEqual((explain.value as? String)?.lowercased(), "paused")
        snapshot(app, "iPad-live-Explain-portrait-marks")
        app.buttons["kindleMinimizeButton"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        wait(15) { app.frame.width > app.frame.height && app.buttons["kindleMiniPlayerExpand"].exists && app.buttons["kindleMiniPlayerExpand"].isHittable }
        snapshot(app, "iPad-live-mini-landscape")
        app.buttons["kindleMiniPlayerExpand"].tap()
        wait(30) { explain.exists && explain.isHittable && (explain.value as? String)?.lowercased() == "paused" }
        stableSince = nil
        wait(60) {
            guard field("stable") == "true", number("ink") > 0 else { stableSince = nil; return false }
            if stableSince == nil { stableSince = Date() }
            return Date().timeIntervalSince(stableSince!) > 3
        }
        XCTAssertEqual(field("explainSession"), explainSession)
        XCTAssertEqual(number("time"), pausedTime, accuracy: 0.4)
        snapshot(app, "iPad-live-expanded-paused")
        if ProcessInfo.processInfo.environment["CASTREADER_KINDLE_EXPLAIN_REFLOW_CONTINUATION"] == "1" {
            explain.tap()
            wait(60) { explain.exists && (explain.value as? String)?.lowercased() == "playing" }
            XCUIDevice.shared.orientation = .portrait
            wait(420) {
                explain.exists && (explain.value as? String)?.lowercased() == "playing" &&
                    field("explainSession") != explainSession && field("explainSession") != "none" &&
                    !field("explainSession").isEmpty && field("stable") == "true"
            }
            wait(90) { number("marks") > 0 && number("ink") > 0 }
            snapshot(app, "iPad-live-Explain-continued-after-reflow")
            explain.tap()
            wait(15) { (explain.value as? String)?.lowercased() == "paused" }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testAuthorizedKindleColdResumeThenManualPageTurns() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_KINDLE_LIVE_ACCEPTANCE"] == "1",
                          "Requires the user's authorized Kindle shelf and an existing listening checkpoint")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
                               "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.terminate()
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.kindle.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        for _ in 0..<6 where !book.isHittable { app.swipeUp() }
        XCTAssertTrue(book.isHittable)
        book.tap()
        waitForPausedReader(app)
        let play = app.buttons["kindleReadPlayPauseButton"]
        let surface = app.otherElements["kindleAcceptanceState"]
        play.tap()
        wait(90) { play.value as? String == "Playing" &&
            (surface.value as? String)?.hasPrefix("page=") == true &&
            surface.value as? String != "page=none" }
        snapshot(app, "Kindle-cold-resume-playing")

        func swipe(left: Bool) {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.8 : 0.2, dy: 0.45))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: left ? 0.2 : 0.8, dy: 0.45))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        for action in ["swipe-left", "swipe-right", "next", "previous", "rapid-left"] {
            let before = surface.value as? String
            switch action {
            case "swipe-left": swipe(left: true)
            case "swipe-right": swipe(left: false)
            case "rapid-left": swipe(left: true); swipe(left: true)
            default:
                let button = app.buttons[action == "next" ? "kindleNextPageButton" : "kindlePreviousPageButton"]
                wait(10) { button.isHittable && button.isEnabled }
                button.tap()
            }
            var readySince: Date?
            wait(25) {
                let page = surface.value as? String
                guard let page, page != "page=none", page != before,
                      play.value as? String == "Playing" else { readySince = nil; return false }
                if readySince == nil { readySince = Date() }
                return Date().timeIntervalSince(readySince!) > 2
            }
            snapshot(app, "Kindle-cold-resume-" + action)
        }
        play.tap()
        wait(10) { play.value as? String == "Paused" }
        snapshot(app, "Kindle-manual-turns-complete-paused")
    }

    func testAuthorizedKindleEightPageContinuousRead() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_KINDLE_LIVE_ACCEPTANCE"] == "1")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
                               "-CastReaderTTSClockDiagnostics", "-AppleLanguages", "(en)",
                               "-interfaceLanguage", "en"]
        app.launch()
        let book = app.buttons["homeShelfBook.kindle.B002RKRMSY"]
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        for _ in 0..<6 where !book.isHittable { app.swipeUp() }
        XCTAssertTrue(book.isHittable)
        book.tap()
        let play = app.buttons["kindleReadPlayPauseButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 60))
        waitForPausedReader(app)
        play.tap()
        wait(90) { play.value as? String == "Playing" }
        let surface = app.otherElements["kindleAcceptanceState"]
        let first = try XCTUnwrap(surface.value as? String)
        XCTAssertNotEqual(first, "page=none")
        var previous = first
        var visited: Set<String> = [first]
        snapshot(app, "Eight-page-start")
        for number in 1...8 {
            wait(180) {
                guard let current = surface.value as? String,
                      current != "page=none", current != previous else { return false }
                return play.value as? String == "Playing"
            }
            let current = try XCTUnwrap(surface.value as? String)
            XCTAssertTrue(visited.insert(current).inserted, "Automatic reading must not repeat a visited page")
            previous = current
            snapshot(app, "Eight-page-turn-\(number)")
        }
        play.tap()
        wait(10) { play.value as? String == "Paused" }
        snapshot(app, "Eight-page-complete-paused")
    }

    func testAuthorizedKindleVoiceAndModeContinuousRead() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["CASTREADER_KINDLE_LIVE_ACCEPTANCE"] == "1")
        let mode = try XCTUnwrap(environment["CASTREADER_ACCEPTANCE_MODE"])
        let voice = try XCTUnwrap(environment["CASTREADER_ACCEPTANCE_VOICE"])
        XCTAssertTrue(["read", "explain"].contains(mode))
        XCTAssertTrue(["preset", "clone"].contains(voice))
        let turns = Int(environment["CASTREADER_ACCEPTANCE_TURNS"] ?? "3") ?? 3
        XCTAssertTrue((1...8).contains(turns))
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding",
                               "-CastReaderTTSClockDiagnostics", "-AppleLanguages", "(en)",
                               "-interfaceLanguage", "en"]
        app.launch()
        let book = app.buttons["homeShelfBook.kindle.B002RKRMSY"]
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        wait(30) {
            if book.isHittable { return true }
            app.swipeUp()
            return false
        }
        book.tap()
        XCTAssertTrue(app.buttons["readerMoreButton"].waitForExistence(timeout: 60))
        waitForPausedReader(app)
        app.buttons["kindleModeButton_\(mode)"].tap()

        func playControl() -> XCUIElement {
            let explain = app.buttons["kindleExplainPlayPauseButton"]
            return explain.exists ? explain : app.buttons["kindleReadPlayPauseButton"]
        }
        func playbackState() -> String {
            (playControl().value as? String ?? "").lowercased()
        }
        // Resolve the current mode's real reading/output language before using
        // its voice panel. This avoids selecting a voice for a stale browser
        // language, and exercises the ordinary UI instead of injecting settings.
        wait(60) { playControl().isEnabled && playControl().isHittable }
        playControl().tap()
        wait(180) { playbackState() == "playing" }
        playControl().tap()
        wait(15) { playbackState() == "paused" }
        app.buttons["playbackVoiceButton"].tap()
        let categories = app.segmentedControls["voiceBrowserCategoryPicker"]
        XCTAssertTrue(categories.waitForExistence(timeout: 20))
        categories.buttons[voice == "clone" ? "Created" : "Explore"].tap()
        let selectorPrefix = voice == "clone" ? "voiceCloneApplyButton_" : "presetVoiceSelect_"
        let selection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", selectorPrefix)).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 60))
        snapshot(app, "\(mode)-\(voice)-voice-library")
        XCTAssertTrue(selection.isHittable)
        let selectedVoice = XCTAttachment(string: selection.identifier)
        selectedVoice.name = "\(mode)-\(voice)-selected-voice"
        selectedVoice.lifetime = .keepAlways
        add(selectedVoice)
        selection.tap()
        app.buttons["playbackVoiceDoneButton"].tap()
        wait(180) { ["paused", "playing"].contains(playbackState()) && playControl().isEnabled }
        if playbackState() == "paused" { playControl().tap() }
        wait(180) { playbackState() == "playing" }

        let surface = app.otherElements["kindleAcceptanceState"]
        var previous = try XCTUnwrap(surface.value as? String)
        XCTAssertNotEqual(previous, "page=none")
        var visited: Set<String> = [previous]
        snapshot(app, "\(mode)-\(voice)-continuous-start")
        if environment["CASTREADER_ACCEPTANCE_MANUAL_HELD_PAGE"] == "1" {
            let held = app.otherElements["kindleHeldPageNavigationState"]
            for direction in ["next", "previous"] {
                wait(240) { (held.value as? String ?? "none").contains(" next=") }
                let state = try XCTUnwrap(held.value as? String)
                let fields = state.split(separator: " ").map(String.init)
                let old = try XCTUnwrap(fields.first?.replacingOccurrences(of: "old=", with: "page="))
                let target = try XCTUnwrap(fields.last?.replacingOccurrences(of: "next=", with: "page="))
                XCTAssertNotEqual(old, target)
                app.buttons[direction == "next" ? "kindleNextPageButton" : "kindlePreviousPageButton"].tap()
                wait(90) {
                    guard playbackState() == "playing", let actual = surface.value as? String else { return false }
                    return actual != "page=none" && actual != old
                }
                let actual = try XCTUnwrap(surface.value as? String)
                if direction == "next" {
                    XCTAssertEqual(actual, target, "Next must adopt the already prepared successor, never turn twice")
                } else {
                    XCTAssertNotEqual(actual, target, "Previous must be relative to the displayed old page")
                }
                snapshot(app, "\(mode)-\(voice)-held-manual-\(direction)")
            }
            playControl().tap()
            wait(15) { playbackState() == "paused" }
            return
        }
        if let seconds = environment["CASTREADER_ACCEPTANCE_QUIET_SECONDS"].flatMap(Double.init) {
            XCTAssertTrue((60...900).contains(seconds))
            // Frequent XCTest AX snapshots can stall short-word display on a
            // physical device. Observe the app's own logs during this interval;
            // do not query or interact with its UI until the sample has ended.
            Thread.sleep(forTimeInterval: seconds)
            XCTAssertEqual(playbackState(), "playing", "Continuous playback stopped during the quiet sample")
            snapshot(app, "\(mode)-\(voice)-quiet-end")
            playControl().tap()
            wait(15) { playbackState() == "paused" }
            snapshot(app, "\(mode)-\(voice)-complete-paused")
            return
        }
        for number in 1...turns {
            var pausedSince: Date?
            wait(300) {
                let state = playbackState()
                if state == "paused" {
                    if pausedSince == nil { pausedSince = Date() }
                    XCTAssertLessThan(Date().timeIntervalSince(pausedSince!), 15,
                                      "Playback paused without an explicit pause action")
                } else { pausedSince = nil }
                guard let current = surface.value as? String,
                      current != "page=none", current != previous else { return false }
                return state == "playing"
            }
            let current = try XCTUnwrap(surface.value as? String)
            XCTAssertTrue(visited.insert(current).inserted, "Automatic reading repeated a visited page")
            previous = current
            snapshot(app, "\(mode)-\(voice)-turn-\(number)")
        }
        playControl().tap()
        wait(15) { playbackState() == "paused" }
        snapshot(app, "\(mode)-\(voice)-complete-paused")
    }

    func testAuthorizedKindleReadTurnSettingsMinimizeAndRelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_KINDLE_LIVE_ACCEPTANCE"] == "1",
                          "Live acceptance requires the user's authorized Kindle session")
        continueAfterFailure = false
        defer { XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-CastReaderKindleFontDiagnostics", "-CastReaderTTSClockDiagnostics",
                               "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.kindle.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20), "Use the already authorized, synced Kindle shelf")
        for _ in 0..<6 where !book.isHittable { app.swipeUp() }
        XCTAssertTrue(book.isHittable)
        let bookID = book.identifier
        book.tap()
        let play = app.buttons["kindleReadPlayPauseButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 60))
        // Amazon can briefly display its shelf before navigating into the book.
        // Check real reader readiness, including after the screenshot's await,
        // so the one Play action is not sent to a now-disabled loading control.
        waitForPausedReader(app)
        snapshot(app, "Kindle-live-initial-page")
        waitForPausedReader(app)
        play.tap()
        wait(90) { play.value as? String == "Playing" }
        let surface = app.otherElements["kindleAcceptanceState"]
        XCTAssertTrue(surface.waitForExistence(timeout: 10))
        let initial = surface.value as? String
        XCTAssertFalse(initial?.contains("page=none") ?? true)
        snapshot(app, "Kindle-live-playing-before-turn")

        for number in 1...3 {
            let before = surface.value as? String
            let next = app.buttons["kindleNextPageButton"]
            wait(30) { next.isHittable }
            next.tap()
            wait(60) { (surface.value as? String).map { $0 != "page=none" && $0 != before } == true && play.value as? String == "Playing" }
            snapshot(app, "Kindle-live-next-\(number)")
        }
        let beforePrevious = surface.value as? String
        let previous = app.buttons["kindlePreviousPageButton"]
        wait(30) { previous.isHittable }
        previous.tap()
        wait(60) { (surface.value as? String).map { $0 != "page=none" && $0 != beforePrevious } == true && play.value as? String == "Playing" }
        snapshot(app, "Kindle-live-previous")

        XCUIDevice.shared.orientation = .landscapeLeft
        wait(30) { app.frame.width > app.frame.height && app.buttons["pause.circle.fill"].isHittable }
        XCTAssertLessThanOrEqual(surface.frame.maxY, app.buttons["pause.circle.fill"].frame.minY,
                                 "The landscape playback bar must not cover the Kindle page")
        snapshot(app, "Kindle-live-landscape")
        XCUIDevice.shared.orientation = .portrait
        wait(30) { app.frame.height > app.frame.width && play.isHittable }
        wait(90) { play.value as? String == "Playing" }
        snapshot(app, "Kindle-live-portrait-restored")

        let readingSettings = app.buttons["readerMoreButton"]
        wait(60) { readingSettings.isEnabled && readingSettings.isHittable }
        openReadingSettings(app)
        let font = app.staticTexts["kindleFontValue"]
        waitForReadingSettingsReady(app)
        let initialFont = font.label
        let increase = app.buttons["kindleFontIncrease"]
        let decrease = app.buttons["kindleFontDecrease"]
        wait(10) { increase.isEnabled || decrease.isEnabled }
        let increasing = increase.isEnabled
        (increasing ? increase : decrease).tap()
        wait(15) { font.label != initialFont && !app.activityIndicators.firstMatch.exists }
        let changedFont = font.label
        let skip = app.switches["kindleSkipFootnotes"]
        let initialSkip = skip.value as? String
        tapFootnoteSwitch(app)
        wait(5) { skip.value as? String != initialSkip }
        snapshot(app, "Kindle-live-settings-changed")
        app.buttons["kindleReadingSettingsDone"].tap()
        waitForPausedReader(app)
        snapshot(app, "Kindle-live-font-page-before-play")
        // Screenshots and AX attachments await; a late sync prompt can arrive
        // during them. Recheck before the single action, never retry a tap.
        waitForPausedReader(app)
        play.tap()
        wait(90) { play.value as? String == "Playing" }

        var hiddenPage = surface.value as? String
        XCTAssertNotNil(hiddenPage)
        XCTAssertNotEqual(hiddenPage, "page=none")
        app.buttons["kindleMinimizeButton"].tap()
        let expand = app.descendants(matching: .any)["kindleMiniPlayerExpand"].firstMatch
        XCTAssertTrue(expand.waitForExistence(timeout: 10))
        let hiddenSurface = app.otherElements["kindleMiniAcceptanceState"]
        XCTAssertTrue(hiddenSurface.waitForExistence(timeout: 10))
        snapshot(app, "Kindle-live-mini-player")
        // The state contains only a page hash. Two actual hidden automatic
        // turns are required; changing paragraphs or playback flags cannot pass.
        for _ in 0..<2 {
            wait(180) {
                guard let page = hiddenSurface.value as? String, page != "page=none" else { return false }
                return page != hiddenPage
            }
            hiddenPage = hiddenSurface.value as? String
        }
        expand.tap()
        wait(30) { play.value as? String == "Playing" }
        snapshot(app, "Kindle-live-expanded")
        play.tap()
        wait(10) { play.value as? String == "Paused" }
        app.terminate()
        app.launch()
        let restoredBook = app.buttons[bookID]
        XCTAssertTrue(restoredBook.waitForExistence(timeout: 20))
        for _ in 0..<6 where !restoredBook.isHittable { app.swipeUp() }
        restoredBook.tap()
        XCTAssertTrue(app.buttons["readerMoreButton"].waitForExistence(timeout: 60))
        wait(60) { readingSettings.isEnabled && readingSettings.isHittable }
        openReadingSettings(app)
        waitForReadingSettingsReady(app)
        XCTAssertEqual(font.label, changedFont, "The native font must survive process relaunch")
        XCTAssertNotEqual(skip.value as? String, initialSkip)
        snapshot(app, "Kindle-live-settings-persisted-after-relaunch")
        // A retry can restore the known pre-test preferences from a previous
        // interrupted run, while a normal run restores its own initial values.
        let restoreFont = ProcessInfo.processInfo.environment["CASTREADER_TEST_RESTORE_KINDLE_FONT"] ?? initialFont
        let restoreSkip = ProcessInfo.processInfo.environment["CASTREADER_TEST_RESTORE_KINDLE_SKIP"] ?? initialSkip
        for _ in 0..<12 where font.label != restoreFont {
            let current = try XCTUnwrap(Double(font.label))
            let target = try XCTUnwrap(Double(restoreFont))
            let before = font.label
            (current > target ? decrease : increase).tap()
            wait(15) { font.label != before && !app.activityIndicators.firstMatch.exists }
        }
        XCTAssertEqual(font.label, restoreFont)
        if skip.value as? String != restoreSkip { tapFootnoteSwitch(app) }
        wait(5) { skip.value as? String == restoreSkip }
        app.buttons["kindleReadingSettingsDone"].tap()
        waitForPausedReader(app)
        snapshot(app, "Kindle-live-acceptance-complete")
        app.buttons["kindleMinimizeButton"].tap()
        let settings = app.buttons["settingsGearButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        openReadingSettings(app)
        let version = app.descendants(matching: .any)["settingsAppVersion"].firstMatch
        for _ in 0..<8 where !version.isHittable { app.swipeUp() }
        XCTAssertTrue(version.isHittable)
        let expectedVersion = try XCTUnwrap(ProcessInfo.processInfo.environment["CASTREADER_TEST_APP_VERSION"])
        // LabeledContent exposes its title and value as one accessibility
        // element ("App version, 1.2.35 (55)"), not a separate value label.
        XCTAssertTrue(version.label.hasSuffix(expectedVersion), "Settings must show the installed app's actual version and build")
        snapshot(app, "Kindle-live-app-version")
        app.buttons["settingsCloseButton"].tap()
    }

    func testAuthorizedKindleFontCommitSurvivesSettingsCloseAndProcessRelaunch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_KINDLE_LIVE_ACCEPTANCE"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-CastReaderKindleFontDiagnostics",
                               "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.kindle.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 20))
        for _ in 0..<6 where !book.isHittable { app.swipeUp() }
        let bookID = book.identifier
        book.tap()
        let settings = app.buttons["readerMoreButton"]
        wait(60) { settings.isEnabled && settings.isHittable }
        // Keep this focused on native font commit. Rotation is exercised by
        // the complete read/turn/settings/minimize/relaunch acceptance flow.
        openReadingSettings(app)
        let font = app.staticTexts["kindleFontValue"]
        waitForReadingSettingsReady(app)
        let before = try XCTUnwrap(Double(font.label))
        let increase = app.buttons["kindleFontIncrease"], decrease = app.buttons["kindleFontDecrease"]
        wait(10) { increase.isEnabled || decrease.isEnabled }
        let target = before + (increase.isEnabled ? 1 : -1)
        (increase.isEnabled ? increase : decrease).tap()
        wait(15) { Double(font.label) == target && !app.activityIndicators.firstMatch.exists }
        snapshot(app,"Kindle-font-committed")
        app.buttons["kindleReadingSettingsDone"].tap()
        waitForPausedReader(app)
        snapshot(app,"Kindle-font-page-after-close")
        if ProcessInfo.processInfo.environment["CASTREADER_KINDLE_FONT_ROTATE_AFTER_COMMIT"] == "1" {
            XCUIDevice.shared.orientation = .landscapeLeft
            wait(30) { app.frame.width > app.frame.height && settings.isEnabled && settings.isHittable }
            snapshot(app, "Kindle-font-landscape-after-change")
            XCUIDevice.shared.orientation = .portrait
            wait(30) { app.frame.height > app.frame.width && settings.isEnabled && settings.isHittable }
            snapshot(app, "Kindle-font-portrait-after-change")
        }
        openReadingSettings(app)
        waitForReadingSettingsReady(app)
        XCTAssertEqual(Double(font.label), target, "Native font must survive closing its settings menu")
        snapshot(app,"Kindle-font-preserved-after-close")
        app.buttons["kindleReadingSettingsDone"].tap()
        wait(20) { !app.buttons["kindleReadingSettingsDone"].exists }
        app.terminate()
        app.launch()
        let restoredBook = app.buttons[bookID]
        XCTAssertTrue(restoredBook.waitForExistence(timeout:20))
        for _ in 0..<6 where !restoredBook.isHittable { app.swipeUp() }
        restoredBook.tap()
        wait(60) { settings.isEnabled && settings.isHittable }
        openReadingSettings(app)
        waitForReadingSettingsReady(app)
        XCTAssertEqual(Double(font.label), target, "Native font must survive process relaunch")
        snapshot(app,"Kindle-font-preserved-after-relaunch")
        let restoredFont = Double(ProcessInfo.processInfo.environment["CASTREADER_TEST_RESTORE_KINDLE_FONT"] ?? "") ?? before
        for _ in 0..<14 where Double(font.label) != restoredFont {
            let current = try XCTUnwrap(Double(font.label))
            (current > restoredFont ? decrease : increase).tap()
            wait(15) { Double(font.label) != current && !app.activityIndicators.firstMatch.exists }
        }
        XCTAssertEqual(Double(font.label),restoredFont)
        let skip = app.switches["kindleSkipFootnotes"]
        let restoredSkip = ProcessInfo.processInfo.environment["CASTREADER_TEST_RESTORE_KINDLE_SKIP"] ?? "1"
        if skip.value as? String != restoredSkip { tapFootnoteSwitch(app) }
        wait(5) { skip.value as? String == restoredSkip }
        app.buttons["kindleReadingSettingsDone"].tap()
        waitForPausedReader(app)
        snapshot(app,"Kindle-font-focused-complete")
    }

}

extension KindleLiveAcceptanceUITests {
    func testAuthorizedIPadNarrowWindowAndKeyboard() throws { try verifyNarrowWindow(usingKeyboard: true) }
    func testAuthorizedIPadNarrowWindowAndControls() throws { try verifyNarrowWindow(usingKeyboard: false) }

    private func verifyNarrowWindow(usingKeyboard: Bool) throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_KINDLE_LIVE_ACCEPTANCE"] == "1")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate", "-CastReaderSkipLibraryOnboarding", "-CastReaderIPadAcceptance", "-auto_play", "NO", "-AppleLanguages", "(en)", "-interfaceLanguage", "en"]
        app.launch()
        if app.windows.firstMatch.frame.width < 700 {
            app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.33, dy: 0.055)).doubleTap()
            wait(10) { app.windows.firstMatch.frame.width >= 700 }
        }
        let book = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "homeShelfBook.kindle.")).firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        wait(20) {
            let frame = book.frame
            if frame.width > 1 && frame.height > 1 && frame.intersects(app.windows.firstMatch.frame) && book.isHittable { return true }
            app.scrollViews.firstMatch.swipeUp(); return false
        }
        book.tap(); waitForPausedReader(app)
        let read = app.buttons["kindleReadPlayPauseButton"]
        if usingKeyboard { app.windows.firstMatch.typeKey(" ", modifierFlags: []) }
        else { read.tap() }
        wait(150) { read.value as? String == "Playing" }
        if usingKeyboard { app.windows.firstMatch.typeKey(" ", modifierFlags: []) }
        else { read.tap() }
        waitForPausedReader(app)
        let original = app.windows.firstMatch.frame
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.992, dy: 0.992)).press(forDuration: 1,
            thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.58, dy: 0.65)))
        wait(15) { app.windows.firstMatch.frame.width < original.width - 100 }
        waitForPausedReader(app)
        for id in ["kindleMinimizeButton", "kindleModeMenu", "kindleReadPlayPauseButton", "readerMoreButton"] {
            let b = app.buttons[id]; XCTAssertTrue(b.isHittable, id)
            XCTAssertGreaterThanOrEqual(b.frame.width, 44, id); XCTAssertGreaterThanOrEqual(b.frame.height, 44, id)
        }
        snapshot(app, "module6-live-kindle-narrow-paused")
        app.buttons["Table of Contents"].tap()
        wait(30) { app.buttons["kindleTOCClose"].isHittable }
        snapshot(app, "module6-live-kindle-narrow-toc")
        if usingKeyboard { app.windows.firstMatch.typeKey(.escape, modifierFlags: []) }
        else { app.buttons["kindleTOCClose"].tap() }
        waitForPausedReader(app)
        openReadingSettings(app); waitForReadingSettingsReady(app)
        snapshot(app, "module6-live-kindle-narrow-aa")
        app.buttons["kindleReadingSettingsDone"].tap(); waitForPausedReader(app)
        app.buttons["kindleMinimizeButton"].tap()
        wait(10) { app.buttons["kindleMiniPlayerExpand"].isHittable }
        snapshot(app, "module6-live-kindle-narrow-minimized")
        app.terminate()
    }
}
