//
//  CastReaderUITests.swift
//  CastReaderUITests
//
//  Created by 许旭恒 on 1/7/26.
//

import XCTest
import UIKit

class CastReaderUITests: XCTestCase {

    /// 声音克隆发布开关关闭时，不向用户暴露尚未开放的「已创建」入口。
    func testVoiceBrowserHidesCreatedTabWhileFeatureDisabled() throws {
        let app = launchZh()
        app.tabBars.buttons["音色"].tap()
        XCTAssertTrue(app.buttons["探索"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["已创建"].exists)
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

    /// 九个正式语言包都必须能独立启动，并显示各自的首页标签。
    func testLaunchesInAllNineSupportedLanguages() {
        let configurations: [(language: String, locale: String, home: String)] = [
            ("en", "en_US", "Home"),
            ("zh-Hans", "zh_CN", "首页"),
            ("ja", "ja_JP", "ホーム"),
            ("es", "es_ES", "Inicio"),
            ("fr", "fr_FR", "Accueil"),
            ("de", "de_DE", "Start"),
            ("pt-BR", "pt_BR", "Início"),
            ("it", "it_IT", "Home"),
            ("hi", "hi_IN", "होम")
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
                app.tabBars.buttons[configuration.home].waitForExistence(timeout: 5),
                "Missing localized Home tab for \(configuration.language)"
            )
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

    /// 产品发行区域和自有 API 服务线路必须是两个独立开关。线路切换只写给
    /// 下次启动，当前进程保持 global，避免一次会话混用后端。
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

        let chinaRouteOption = app.buttons["中国备案网关"]
        for _ in 0..<8 where !chinaRouteOption.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(chinaRouteOption.isHittable, "必须提供独立的中国服务线路开关")
        let currentRoute = app.descendants(matching: .any)["settingsServiceRouteEffective"]
        let nextRoute = app.descendants(matching: .any)["settingsServiceRouteNextLaunch"]
        for _ in 0..<6 where !currentRoute.exists || !nextRoute.exists {
            app.swipeUp()
        }
        XCTAssertTrue(currentRoute.exists)
        XCTAssertTrue(nextRoute.exists)
        expect(currentRoute, toHaveValue: "global", "当前进程应保持全球网关")
        for _ in 0..<6 where !chinaRouteOption.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(chinaRouteOption.isHittable)
        chinaRouteOption.tap()
        for _ in 0..<6 where !currentRoute.exists || !nextRoute.exists {
            app.swipeUp()
        }
        expect(currentRoute, toHaveValue: "global", "设置后当前进程不得中途切线")
        expect(nextRoute, toHaveValue: "cn", "中国网关应在下次启动生效")

        // Restore the persistent override so this test cannot change the route
        // observed by a later UI test or a developer's next manual launch.
        let globalRouteOption = app.buttons["全球网关"]
        for _ in 0..<8 where !globalRouteOption.isHittable {
            app.swipeDown()
        }
        XCTAssertTrue(globalRouteOption.isHittable, "必须保留切回全球网关的入口")
        globalRouteOption.tap()
        for _ in 0..<6 where !nextRoute.exists {
            app.swipeUp()
        }
        expect(nextRoute, toHaveValue: "global", "测试结束前必须恢复全球网关")
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
        XCTAssertTrue(app.buttons["login.apple"].exists, "中国区必须保留 Apple 小图标入口")
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

        let settings = app.buttons["settingsGearButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), "手机号登录后必须进入主界面")
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

    /// 底部中间 ➕ 保持导入能力，同时提供统一的阅读平台连接入口。
    func testPlusOpensImportSheet() {
        let app = launchZh()
        let plus = app.buttons["plusImportButton"]
        XCTAssertTrue(plus.waitForExistence(timeout: 5))
        plus.tap()
        XCTAssertTrue(app.buttons["上传文件"].waitForExistence(timeout: 5), "➕ 未弹出导入方式")
        XCTAssertTrue(app.buttons["输入网址"].exists)
        XCTAssertTrue(app.buttons["librarySourcesImportButton"].exists)
        XCTAssertFalse(app.staticTexts["云端文件"].exists)
        for providerID in [
            "cloudProvider.google_drive",
            "cloudProvider.dropbox",
            "cloudProvider.onedrive",
        ] {
            XCTAssertFalse(
                app.descendants(matching: .any)[providerID].exists,
                "发布配置不应显示云盘入口：\(providerID)"
            )
        }
    }

    /// App Store 发布包必须保持云盘入口关闭；历史调试参数也不能重新开启。
    func testCloudProvidersStayExcludedEvenWithLegacyDebugArgument() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
            "-CastReaderSkipLibraryOnboarding",
            "-CastReaderSkipSignInGate",
            "-CastReaderCloudUITest",
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

        let providerIDs = [
            "cloudProvider.google_drive",
            "cloudProvider.dropbox",
            "cloudProvider.onedrive",
        ]
        for providerID in providerIDs {
            XCTAssertFalse(
                app.descendants(matching: .any)[providerID].exists,
                "发布配置不应被调试参数重新开启：\(providerID)"
            )
        }

        XCTAssertFalse(app.staticTexts["云端文件"].exists)
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
