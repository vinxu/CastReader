import XCTest

final class KindleOfflineFlowUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() { continueAfterFailure = false }
    override func tearDown() {
        if app.state == .runningForeground { capture("offline-flow-final") }
        app.terminate()
        super.tearDown()
    }

    private func launch(partial: Bool = false, large: Bool = false, failure: Bool = false, resumeViewport: Bool = false) {
        app.launchArguments = ["-CastReaderOfflineFlowFixture", "-AppleLanguages", "(zh-Hans)", "-interfaceLanguage", "zh-Hans"]
        if partial { app.launchArguments.append("-CastReaderOfflineFixturePartial") }
        if failure { app.launchArguments.append("-CastReaderOfflineFixtureFailure") }
        if resumeViewport { app.launchArguments.append("-CastReaderOfflineFixtureResumeViewport") }
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL", "-CastReaderFixtureAppearance", "Dark"] }
        app.launchEnvironment["CASTREADER_OFFLINE_FIXTURE_ID"] = UUID().uuidString
        app.launchEnvironment["CASTREADER_OFFLINE_FIXTURE_DELAY"] = partial ? "900" : "600"
        app.launch()
        XCTAssertTrue(app.buttons["libraryOfflineBooks"].waitForExistence(timeout: 15))
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
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
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
        wait { self.app.staticTexts["offlineBookSpeechStatus"].label.contains("正在朗读") }
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
        tap("offlineDownloadClose")
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
        wait(25) { self.app.staticTexts["offlineBookSpeechStatus"].label.contains("正在朗读") }
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
        // Returning from a modal must reopen the same reader model for interaction.
        tap("offlineBookPreviousPage")
        wait { self.app.buttons["offlineBookPageStatus"].label.contains("第 2 /") }
        tap("BackButton")
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
        wait(45) { self.app.staticTexts["offlineBookSpeechStatus"].label.contains("整本朗读完成") }
        capture("17-book-finished")
    }
}
