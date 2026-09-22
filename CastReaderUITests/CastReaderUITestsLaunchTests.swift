//
//  CastReaderUITestsLaunchTests.swift
//  CastReaderUITests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest

class CastReaderUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        // Language and appearance configurations are covered by dedicated UI tests.
        // Running this generic launch test for every Xcode-generated configuration
        // creates hundreds of redundant launches on Xcode 26.
        false
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipSignInGate"]
        app.launch()

        // Insert steps here to perform after app launch but before taking a screenshot,
        // such as logging into a test account or navigating somewhere in the app

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Launch Screen"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// A connection probe for the authorized physical release device. No login
    /// bypass, account reset, generated audio, or synthetic content is enabled.
    func testAuthorizedDeviceHomeWithoutAuthenticationBypass() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_DEVICE_RELEASE_ACCEPTANCE"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipLibraryOnboarding", "-CastReaderRegion", "global",
                               "-interfaceLanguage", "en", "-auto_play", "NO"]
        app.launch()
        let home = app.buttons["plusImportButton"]
        let ready = NSPredicate { _, _ in
            home.isHittable || app.buttons["readerMinimizeButton"].isHittable
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app)], timeout: 30), .completed)
        if !home.isHittable { app.buttons["readerMinimizeButton"].tap() }
        XCTAssertTrue(home.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "authorized-device-normal-home"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Opt-in observation of real CN services on the already authorized phone.
    /// No credentials, entitlement bypasses, injected audio or account resets.
    /// Core acceptance additionally requires reviewing attachments and device logs.
    func testAuthorizedCNCloneReadExplainObservation() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["CASTREADER_DEVICE_RELEASE_ACCEPTANCE"] == "1")
        let app = XCUIApplication()
        app.launchArguments = ["-CastReaderSkipLibraryOnboarding", "-CastReaderRegion", "cn",
            "-CastReaderServiceRoute", "cn", "-AppleLanguages", "(zh-Hans)",
            "-interfaceLanguage", "zh-Hans", "-explain_language", "zh", "-auto_play", "NO",
            "-tts_speed", "1", "-CastReaderTTSClockDiagnostics"]
        app.launch()
        func waitFor(_ timeout: TimeInterval = 60, _ condition: @escaping () -> Bool) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
                predicate: NSPredicate { _, _ in condition() }, object: app)], timeout: timeout), .completed)
        }
        func capture(_ name: String) {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = name; image.lifetime = .keepAlways; add(image)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = name + "-accessibility"; tree.lifetime = .keepAlways; add(tree)
        }
        func playing(_ button: XCUIElement) -> Bool {
            ["playing", "正在播放", "朗读中", "解读中"].contains(button.value as? String ?? "")
        }
        func observe(_ seconds: TimeInterval, _ name: String) {
            capture(name + "-start")
            let end = Date().addingTimeInterval(seconds)
            var nextCapture = Date().addingTimeInterval(12)
            while Date() < end {
                XCTAssertEqual(app.state, .runningForeground)
                XCTAssertTrue(app.buttons["playbackVoiceButton"].exists)
                RunLoop.current.run(until: Date().addingTimeInterval(2))
                if Date() >= nextCapture {
                    capture(name + "-" + String(Int(end.timeIntervalSinceNow)))
                    nextCapture = Date().addingTimeInterval(12)
                }
            }
            capture(name + "-end")
        }
        func selectVoice(_ id: String, privateVoice: Bool = false) {
            app.buttons["playbackVoiceButton"].tap()
            let picker = app.segmentedControls["voiceBrowserCategoryPicker"]
            XCTAssertTrue(picker.waitForExistence(timeout: 20))
            picker.buttons[privateVoice ? "我的声音" : "最近"].tap()
            let row = app.buttons[(privateVoice ? "voiceCloneApplyButton_" : "presetVoiceSelect_") + id]
            waitFor(30) { row.exists }
            for _ in 0..<5 {
                if row.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(row.isHittable)
            capture("cn-select-" + id)
            row.tap()
            app.buttons["playbackVoiceDoneButton"].tap()
            waitFor(15) { !app.buttons["playbackVoiceDoneButton"].exists }
        }
        waitFor(40) { app.buttons["plusImportButton"].isHittable || app.buttons["readerMinimizeButton"].isHittable }
        if app.buttons["readerMinimizeButton"].isHittable { app.buttons["readerMinimizeButton"].tap() }
        app.buttons["plusImportButton"].tap()
        let textEntry = app.buttons["importSource.text"]
        XCTAssertTrue(textEntry.waitForExistence(timeout: 10)); textEntry.tap()
        let editor = app.textViews["importTextBody"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        app.textFields["importTextTitle"].tap()
        app.textFields["importTextTitle"].typeText("iPad 中文发布验收")
        editor.tap()
        editor.typeText("""
这次验证关注手机和平板之间一致的阅读体验。

好的阅读工具让人同时用眼睛和耳朵跟随一个想法。朗读的声音应当与屏幕上的高亮文字对应。用户暂停时，当前阅读位置应当保留；再次播放，应当从这个位置继续，而不是回到开头。清晰的控制按钮帮助用户随时掌握自己的阅读节奏。

大屏幕能够容纳舒适的文字行宽和清楚的操作区域。设备旋转时，文字会重新排版，但当前句子的含义没有改变。应用需要重新找到同一句话，把阅读位置、高亮和原文标注放回正确的地方。调整字号时也需要遵守同样的原则。

解读与直接朗读有不同的目的。解读用新的语言解释主要观点，同时指出原文中有价值的细节。一个圆圈或一条下划线，可以帮助用户把听到的讲解和看到的原文联系起来。讲解进入下一块时，标注和声音也应当自然衔接。

用户可以选择常规声音、社区声音或自己的私人声音。切换声音时，应当保留当前位置，并使用新选中的声音生成音频。在等待音频时主动暂停，应用就不能突然开始播放。只有用户再次点击继续，阅读才应当恢复。

完整的测试需要检查整个体验。网络请求成功只是第一步，还需要确认实际出声、播放时间推进、高亮与声音同步，以及下一段或下一块能够自动继续。测试结束后，用户的账号、书架和阅读记录都应该保持可用。
""")
        app.navigationBars.buttons["开始"].tap()
        let read = app.buttons["readPlayPauseButton"]
        XCTAssertTrue(read.waitForExistence(timeout: 30))
        selectVoice("zf_001")
        if !playing(read) { read.tap() }
        waitFor { playing(read) }
        selectVoice("vl_b4bb75aa2d3e56fd90a2")
        waitFor(120) { playing(read) }
        observe(40, "cn-read-community")
        selectVoice("vc_12e286594652455dae539cabbf93c2c0", privateVoice: true)
        waitFor(120) { playing(read) }
        observe(35, "cn-read-private")
        read.tap()
        waitFor { !playing(read) }
        capture("cn-read-private-paused")
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertFalse(playing(read)); read.tap()
        waitFor { playing(read) }
        selectVoice("zf_001")
        waitFor(90) { playing(read) }
        observe(12, "cn-read-return-regular")
        if playing(read) { read.tap() }
        app.segmentedControls["readerModePicker"].buttons["解读"].tap()
        let start = app.buttons["explainStartButton"]
        if start.waitForExistence(timeout: 5) { start.tap() }
        let explain = app.buttons["explainPlayPauseButton"]
        let replay = app.buttons["explainReplayButton"]
        waitFor(180) { explain.exists && playing(explain) }
        observe(10, "cn-explain-regular")
        selectVoice("vl_b4bb75aa2d3e56fd90a2")
        waitFor(120) { explain.exists && playing(explain) }
        observe(40, "cn-explain-community")
        waitFor(180) { replay.exists }
        selectVoice("vc_12e286594652455dae539cabbf93c2c0", privateVoice: true)
        waitFor(120) { explain.exists && explain.isEnabled }
        if !playing(explain) { explain.tap() }
        waitFor(120) { replay.exists }
        replay.tap()
        waitFor(120) { explain.exists && playing(explain) }
        observe(30, "cn-explain-private")
        if playing(explain) {
            explain.tap(); waitFor { !playing(explain) }
            capture("cn-explain-private-paused")
            RunLoop.current.run(until: Date().addingTimeInterval(4))
            XCTAssertFalse(playing(explain)); explain.tap()
            waitFor { playing(explain) }
        }
        observe(16, "cn-explain-private-continuation")
        selectVoice("zf_001")
        waitFor(120) { explain.exists && explain.isEnabled }
        if !playing(explain) { explain.tap() }
        waitFor(120) { playing(explain) }
        observe(12, "cn-explain-return-regular")
        if playing(explain) { explain.tap() }
        capture("cn-live-core-final-paused")
    }

}
