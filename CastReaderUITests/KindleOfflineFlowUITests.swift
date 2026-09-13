import XCTest

final class KindleOfflineFlowUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() { continueAfterFailure = false }
    override func tearDown() {
        if app.state == .runningForeground { capture("offline-flow-final") }
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func launch(partial: Bool = false, large: Bool = false, failure: Bool = false, resumeViewport: Bool = false, miniPlayer: Bool = false, tallPage: Bool = false, english: Bool = false, chinese: Bool = false) {
        app.launchArguments = ["-CastReaderOfflineFlowFixture", "-AppleLanguages", "(zh-Hans)", "-interfaceLanguage", "zh-Hans"]
        if english { app.launchArguments = ["-CastReaderOfflineFlowFixture", "-AppleLanguages", "(en)", "-interfaceLanguage", "en"] }
        if partial { app.launchArguments.append("-CastReaderOfflineFixturePartial") }
        if failure { app.launchArguments.append("-CastReaderOfflineFixtureFailure") }
        if resumeViewport { app.launchArguments.append("-CastReaderOfflineFixtureResumeViewport") }
        if miniPlayer { app.launchArguments.append("-CastReaderOfflineFixtureMiniPlayer") }
        if tallPage { app.launchArguments.append("-CastReaderOfflineFixtureTallPage") }
        if chinese { app.launchArguments.append("-CastReaderOfflineFixtureChinese") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-CastReaderFixtureAppearance", "Dark"] }
        app.launchEnvironment["CASTREADER_OFFLINE_FIXTURE_ID"] = UUID().uuidString
        app.launchEnvironment["CASTREADER_OFFLINE_FIXTURE_DELAY"] = partial ? "900" : "600"
        app.launch()
        XCTAssertTrue(app.buttons["offlineFlowOnlineBook"].waitForExistence(timeout: 15))
    }

    private func visibleButton(_ id: String) -> XCUIElement {
        let matches = app.buttons.matching(identifier: id)
        return matches.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? matches.firstMatch
    }

    private func tap(_ id: String, timeout: TimeInterval = 10) {
        XCTAssertTrue(app.buttons.matching(identifier: id).firstMatch.waitForExistence(timeout: timeout), "Missing \(id)")
        // Presented sheets leave the underlying navigation bar in the AX tree.
        // Select the visible product control, not the hidden copy underneath.
        for _ in 0..<5 {
            if visibleButton(id).isHittable { break }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(visibleButton(id).isHittable, "Not reachable: \(id)")
        visibleButton(id).tap()
    }

    private func wait(_ seconds: TimeInterval = 12, _ condition: @escaping () -> Bool) {
        let predicate = NSPredicate { _, _ in condition() }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: seconds), .completed)
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
    }

    private func openDownloadFromMore() {
        tap("offlineFlowOnlineBook")
        tap("readerMoreButton")
        tap("readerOfflineMenuItem")
        XCTAssertTrue(app.buttons["offlineDownloadStart"].waitForExistence(timeout: 10))
    }

    private func jump(to page: Int) {
        tap("offlineBookPageStatus")
        let input = app.textFields["offlineBookPageInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap()
        let existing = input.value as? String ?? ""
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count) + String(page))
        tap("offlineBookPageGo")
        wait { self.app.buttons["offlineBookPageStatus"].label.contains("第 \(page) /") }
    }

    func testDownloadedEntryAndPersistentMiniPlayer() {
        launch(partial: true)
        tap("homeDownloads")
        tap("offlineLibraryBook.offline-flow-book", timeout: 20)
        tap("offlineBookPlay")
        wait(25) { self.app.staticTexts["offlineBookSpeechStatus"].exists && self.app.staticTexts["offlineBookSpeechStatus"].label.contains("正在朗读") }
        let page = app.buttons["offlineBookPageStatus"].label
        tap("offlineBookClose")
        wait { self.app.buttons["offlineMiniPlay"].exists && self.app.buttons["offlineMiniPlay"].label == "暂停" }
        XCTAssertFalse(app.buttons["offlineBookPlay"].isHittable)
        capture("30-offline-mini-keeps-playing")
        tap("offlineMiniPlay")
        wait { self.app.buttons["offlineMiniPlay"].exists && self.app.buttons["offlineMiniPlay"].label == "播放" }
        tap("BackButton")
        XCTAssertTrue(app.buttons["homeDownloads"].isHittable)
        XCTAssertTrue(app.buttons["offlineMiniExpand"].isHittable)
        capture("31-home-downloads-and-mini")
        tap("offlineMiniExpand")
        XCTAssertEqual(app.buttons["offlineBookPageStatus"].label, page)
        XCTAssertEqual(app.buttons["offlineBookPlay"].label, "播放")
        tap("offlineBookPlay")
        wait { self.app.buttons["offlineBookPlay"].label == "暂停" }
        tap("offlineBookClose")
        tap("offlineMiniStop")
        wait { !self.app.buttons["offlineMiniPlay"].exists }
        tap("homeDownloads")
        tap("offlineLibraryBook.offline-flow-book")
        XCTAssertEqual(app.buttons["offlineBookPlay"].label, "播放")
        capture("32-reopen-after-explicit-stop")
    }

    func testChineseImageDownloadDetectsLanguageAndKeepsPlayingInMiniPlayer() {
        launch(chinese: true)
        openDownloadFromMore()
        tap("offlineDownloadStart")
        wait(35) { self.app.staticTexts["offlineDownloadStatus"].label == "整本已保存" }
        tap("offlineDownloadOpenBook")
        XCTAssertTrue(app.images["offlineBookSavedImage"].waitForExistence(timeout: 10))
        tap("offlineBookPlay")
        wait(25) { self.app.staticTexts["offlineBookSpeechStatus"].exists && self.app.staticTexts["offlineBookSpeechStatus"].label.contains("正在朗读") }
        XCTAssertNotEqual(app.buttons["offlineBookVoice"].value as? String, "Samantha")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "offlineBookParagraph.", "中文")).firstMatch.exists)
        capture("40-chinese-local-ocr-and-speech")
        tap("offlineBookPlay")
        tap("offlineBookVoice")
        XCTAssertTrue(app.staticTexts["zh-TW"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["en-US"].exists)
        tap("offlineBookVoiceDone")
        tap("offlineBookPlay")
        tap("offlineBookClose")
        wait { self.app.buttons["offlineMiniPlay"].label == "暂停" }
        tap("offlineMiniPlay")
        tap("offlineMiniExpand")
        XCTAssertEqual(app.buttons["offlineBookPlay"].label, "播放")
        capture("41-chinese-mini-player-return")
    }

    func testSaveReadOCRSpeechSettingsAndResumeAfterRelaunch() {
        launch()
        tap("libraryOfflineBooks")
        XCTAssertTrue(app.staticTexts["还没有离线书籍"].waitForExistence(timeout: 8))
        capture("01-empty-library")
        tap("BackButton")
        openDownloadFromMore()
        capture("02-download-ready")
        tap("offlineDownloadStart")
        XCTAssertTrue(app.buttons["offlineDownloadCancel"].waitForExistence(timeout: 5))
        capture("03-download-progress")
        wait(35) { self.app.staticTexts["offlineDownloadStatus"].label == "整本已保存" }
        capture("04-download-complete")
        tap("offlineDownloadOpenBook")
        XCTAssertTrue(app.images["offlineBookSavedImage"].waitForExistence(timeout: 10))
        capture("05-saved-original-page")
        tap("offlineBookZoom")
        let canvas = app.scrollViews["offlineBookZoomCanvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 8))
        canvas.doubleTap()
        wait { (canvas.value as? String) != "100%" }
        capture("05b-original-page-zoom")
        tap("offlineBookZoomClose")
        tap("offlineBookPlay")
        wait(25) { self.app.segmentedControls["offlineBookDisplayMode"].exists }
        wait { self.app.staticTexts["offlineBookSpeechStatus"].exists && self.app.staticTexts["offlineBookSpeechStatus"].label.contains("正在朗读") }
        capture("06-ocr-system-speech")
        tap("offlineBookPlay")
        tap("offlineBookVoice")
        XCTAssertTrue(app.navigationBars["本机声音"].waitForExistence(timeout: 5))
        capture("07-local-voice-picker")
        tap("offlineBookVoiceDone")
        tap("offlineBookRate")
        app.buttons["1.2×"].tap()
        tap("readerMoreButton")
        tap("readerAppearanceMenuItem")
        XCTAssertTrue(app.buttons["readerTextSizeIncrease"].waitForExistence(timeout: 5))
        tap("readerTextSizeIncrease")
        capture("08-reading-settings")
        tap("readerSettingsDone")
        jump(to: 5)
        capture("09-chapter-page-five")
        tap("offlineBookClose")
        tap("BackButton")
        tap("libraryOfflineBooks")
        tap("offlineLibraryBook.offline-flow-book")
        wait { self.app.buttons["offlineBookPageStatus"].label.contains("第 5 /") }
        XCTAssertEqual(app.buttons["offlineBookRate"].value as? String, "1.2×")
        XCTAssertEqual(app.buttons["offlineBookPlay"].label, "播放")
        capture("10-library-resumes-page-five")
        app.terminate(); app.launch()
        tap("libraryOfflineBooks")
        tap("offlineLibraryBook.offline-flow-book")
        wait { self.app.buttons["offlineBookPageStatus"].label.contains("第 5 /") }
        tap("offlineBookPlay")
        wait(25) { self.app.staticTexts["offlineBookSpeechStatus"].exists && self.app.staticTexts["offlineBookSpeechStatus"].label.contains("正在朗读") }
        capture("11-relaunch-offline-speech")
    }

    func testPartialEndContinueCancelAndLocalDeletion() {
        launch(partial: true)
        tap("libraryOfflineBooks")
        tap("offlineLibraryBook.offline-flow-book", timeout: 20)
        jump(to: 3)
        let end = app.staticTexts["已到已保存内容的末尾"]
        for _ in 0..<4 where !app.buttons["offlineBookContinueDownload"].isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(end.exists)
        XCTAssertLessThanOrEqual(app.buttons["offlineBookContinueDownload"].frame.maxY,
                                 app.staticTexts["offlineBookSpeechStatus"].frame.minY,
                                 "The continuation button must be above the playback bar, not tappable underneath it")
        capture("12-partial-download-end")
        tap("offlineBookContinueDownload")
        tap("offlineDownloadStart")
        tap("offlineDownloadCancel")
        app.alerts.buttons["继续下载"].tap()
        XCTAssertTrue(app.buttons["offlineDownloadCancel"].exists)
        tap("offlineDownloadClose")
        app.alerts.buttons["停止并关闭"].tap()
        wait { !self.app.buttons["offlineDownloadClose"].exists }
        // Continuing dismisses the independent reader before opening download.
        // After cancellation the library can reopen its saved reading position.
        tap("offlineLibraryBook.offline-flow-book")
        wait { self.app.buttons["offlineBookPageStatus"].label.contains("第 3 /") }
        tap("offlineBookPreviousPage")
        wait { self.app.buttons["offlineBookPageStatus"].label.contains("第 2 /") }
        tap("offlineBookClose")
        tap("offlineLibraryResume.offline-flow-book")
        tap("offlineDownloadStart")
        wait(40) { self.app.staticTexts["offlineDownloadStatus"].label == "整本已保存" }
        tap("offlineDownloadClose")
        let row = app.buttons["offlineLibraryBook.offline-flow-book"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.press(forDuration: 1)
        app.buttons["删除本机副本"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 8))
        capture("13-delete-confirmation")
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(row.exists)
        row.press(forDuration: 1)
        app.buttons["删除本机副本"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 8))
        app.alerts.buttons["删除本机副本"].tap()
        XCTAssertTrue(app.staticTexts["还没有离线书籍"].waitForExistence(timeout: 10))
        capture("14-deleted-local-copy")
    }

    func testLibraryReaderCoversRootMiniPlayerAndReturnsToLibrary() {
        launch(partial: true, miniPlayer: true)
        tap("libraryOfflineBooks")
        XCTAssertTrue(app.buttons["offlineFixtureRootMiniPlayer"].isHittable)
        tap("offlineLibraryBook.offline-flow-book", timeout: 20)
        XCTAssertTrue(app.buttons["offlineBookClose"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["offlineFixtureRootMiniPlayer"].isHittable)
        tap("offlineBookVoice")
        tap("offlineBookVoiceDone")
        tap("offlineBookRate")
        app.buttons["1.2×"].tap()
        XCTAssertEqual(app.buttons["offlineBookRate"].value as? String, "1.2×")
        capture("21-reader-covers-root-mini-player")
        tap("offlineBookClose")
        XCTAssertTrue(app.buttons["offlineLibraryBook.offline-flow-book"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["offlineMiniExpand"].isHittable)
        XCTAssertFalse(app.buttons["offlineFixtureRootMiniPlayer"].exists)
    }

    func testRateSelectionChangesTheSpeakingUtteranceWhilePlaying() {
        launch(partial: true)
        tap("libraryOfflineBooks")
        tap("offlineLibraryBook.offline-flow-book", timeout: 20)
        tap("offlineBookRate"); app.buttons["0.7×"].tap()
        tap("offlineBookPlay")
        wait(25) { self.app.staticTexts["offlineBookSpeechStatus"].exists && self.app.staticTexts["offlineBookSpeechStatus"].label.contains("正在朗读") }
        wait { self.app.staticTexts["offlineBookSpeechStatus"].value as? String == "0.7×" }
        tap("offlineBookRate"); app.buttons["1.3×"].tap()
        wait { self.app.staticTexts["offlineBookSpeechStatus"].value as? String == "1.3×" }
        XCTAssertTrue(app.staticTexts["offlineBookSpeechStatus"].label.contains("正在朗读"))
        capture("22-active-rate-change")
        tap("offlineBookPlay")
        tap("offlineBookClose")
        tap("offlineLibraryBook.offline-flow-book")
        XCTAssertEqual(app.buttons["offlineBookRate"].value as? String, "1.3×")
        XCTAssertEqual(app.buttons["offlineBookPlay"].label, "播放")
    }

    func testTallOriginalPageFitsAbovePlayerAndZoomStartsWithWholePage() {
        launch(partial: true, tallPage: true)
        tap("libraryOfflineBooks")
        tap("offlineLibraryBook.offline-flow-book", timeout: 20)
        let page = app.images["offlineBookSavedImage"]
        XCTAssertTrue(page.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(page.frame.minY, app.buttons["offlineBookPageStatus"].frame.maxY)
        XCTAssertLessThanOrEqual(page.frame.maxY, app.staticTexts["offlineBookSpeechStatus"].frame.minY)
        XCTAssertEqual(page.frame.width / page.frame.height, 1.0 / 3.0, accuracy: 0.02)
        XCTAssertLessThan(app.buttons["offlineBookRate"].frame.maxY - app.staticTexts["offlineBookSpeechStatus"].frame.minY, 150)
        capture("23-entire-tall-page-visible")
        tap("offlineBookZoom")
        let canvas = app.scrollViews["offlineBookZoomCanvas"]
        let enlarged = app.images["offlineBookZoomImage"]
        XCTAssertTrue(enlarged.waitForExistence(timeout: 8))
        XCTAssertTrue(canvas.frame.insetBy(dx: -1, dy: -1).contains(enlarged.frame))
        XCTAssertEqual(enlarged.frame.width / enlarged.frame.height, 1.0 / 3.0, accuracy: 0.02)
        capture("24-zoom-entire-page")
        canvas.doubleTap(); wait { canvas.value as? String != "100%" }
        canvas.doubleTap(); wait { canvas.value as? String == "100%" }
        XCTAssertTrue(canvas.frame.insetBy(dx: -1, dy: -1).contains(enlarged.frame))
        tap("offlineBookZoomClose")
    }

    func testEnglishReaderAndLandscapePageRemainComplete() {
        launch(partial: true, tallPage: true, english: true)
        tap("libraryOfflineBooks")
        XCTAssertTrue(app.navigationBars["Downloaded"].waitForExistence(timeout: 8))
        tap("offlineLibraryBook.offline-flow-book", timeout: 20)
        XCTAssertTrue(app.images["offlineBookSavedImage"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["offlineBookSpeechStatus"].label, "Tap play to start reading")
        XCTAssertEqual(app.buttons["offlineBookRate"].label, "Reading Speed")
        XCTAssertEqual(app.buttons["offlineBookPageStatus"].label, "Page 1 of 3")
        tap("offlineBookRate")
        XCTAssertTrue(app.navigationBars["Reading Speed"].exists)
        let rates = ["0.6×", "0.7×", "0.8×", "0.9×", "1.0×", "1.1×", "1.2×", "1.3×"]
        wait {
            rates.allSatisfy { label in
                let button = self.app.buttons[label]
                return button.isHittable && button.frame.height >= 44 && button.frame.maxY <= self.app.frame.maxY
            }
        }
        capture("25-english-speed-picker")
        app.buttons["1.0×"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        wait { self.app.frame.width > self.app.frame.height }
        let image = app.images["offlineBookSavedImage"]
        XCTAssertGreaterThan(image.frame.height, 60)
        XCTAssertEqual(image.frame.width / image.frame.height, 1.0 / 3.0, accuracy: 0.02)
        XCTAssertGreaterThanOrEqual(image.frame.minY, app.buttons["offlineBookPageStatus"].frame.maxY)
        XCTAssertLessThanOrEqual(image.frame.maxY, app.staticTexts["offlineBookSpeechStatus"].frame.minY)
        for id in ["offlineBookPlay", "offlineBookVoice", "offlineBookRate", "offlineBookZoom"] {
            XCTAssertTrue(app.buttons[id].isHittable)
        }
        capture("26-landscape-entire-page")
        tap("offlineBookNextPage"); tap("offlineBookNextPage")
        XCTAssertTrue(app.buttons["offlineBookContinueDownload"].waitForExistence(timeout: 8))
        XCTAssertGreaterThan(image.frame.height, 40, "The partial-end banner must leave room for the page")
        XCTAssertLessThanOrEqual(image.frame.maxY, app.buttons["offlineBookContinueDownload"].frame.minY)
        capture("27-landscape-partial-end")
    }

    func testFailedDownloadRetainsPagesAndCanResume() {
        launch(failure: true)
        openDownloadFromMore()
        tap("offlineDownloadStart")
        wait(25) { self.app.staticTexts.matching(identifier: "offlineDownloadError").firstMatch.exists }
        XCTAssertTrue(app.staticTexts["已保存 2 页"].exists)
        capture("18-download-failure-keeps-pages")
        tap("offlineDownloadStart")
        wait(35) { self.app.staticTexts["offlineDownloadStatus"].label == "整本已保存" }
        XCTAssertTrue(app.staticTexts["已保存 12 页"].exists)
        tap("offlineDownloadOpenBook")
        XCTAssertTrue(app.buttons["offlineBookPlay"].waitForExistence(timeout: 10))
        capture("19-download-retry-complete")
    }

    func testCachedSentenceRestoresVisibleParagraphWithoutAutoplay() {
        launch(resumeViewport: true)
        tap("libraryOfflineBooks")
        tap("offlineLibraryBook.offline-flow-book")
        let paragraph = app.staticTexts["offlineBookParagraph.18"]
        wait { paragraph.isHittable }
        XCTAssertGreaterThanOrEqual(paragraph.frame.minY, app.buttons["offlineBookPageStatus"].frame.maxY)
        XCTAssertLessThanOrEqual(paragraph.frame.maxY, app.staticTexts["offlineBookSpeechStatus"].frame.minY)
        XCTAssertEqual(app.buttons["offlineBookPlay"].label, "播放")
        capture("20-resumed-sentence-visible")
    }

    func testLargeTextDownloadAndReaderControlsRemainReachable() {
        launch(large: true)
        openDownloadFromMore()
        tap("offlineDownloadStart")
        wait(35) { self.app.staticTexts["offlineDownloadStatus"].label == "整本已保存" }
        capture("15-large-text-download")
        tap("offlineDownloadOpenBook")
        XCTAssertTrue(app.buttons["offlineBookPlay"].waitForExistence(timeout: 10))
        for id in ["offlineBookPlay", "offlineBookVoice", "offlineBookRate", "offlineBookPageStatus", "readerMoreButton"] {
            XCTAssertTrue(visibleButton(id).isHittable, "Control unreachable with large text: \(id)")
        }
        capture("16-large-text-reader")
        jump(to: 12)
        XCTAssertFalse(app.buttons["offlineBookNextPage"].isEnabled)
        tap("offlineBookPlay")
        wait(45) { self.app.staticTexts["offlineBookSpeechStatus"].exists && self.app.staticTexts["offlineBookSpeechStatus"].label.contains("整本朗读完成") }
        capture("17-book-finished")
    }
}
