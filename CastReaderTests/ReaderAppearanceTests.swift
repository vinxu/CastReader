import XCTest
import WebKit
@testable import CastReader

@MainActor
final class ReaderAppearanceTests: XCTestCase {
    func testReaderMoreStringsExistInEverySupportedLanguageBundle() throws {
        let keys = [
            "定时停止", "阅读设置", "更多", "未开启", "阅读设置暂不可用", "完成",
            "请等待阅读页面加载完成后重试，或使用原阅读器的 Aa 设置。", "停止时间",
            "取消定时", "在此之后停止", "%lld 分钟", "自定义", "定时方式", "时长",
            "指定时间", "开始计时", "到时间自动暂停并保留进度。锁屏、暂停或切换模式不会重置倒计时。",
            "此内容保留原始版式", "图片和 PDF 的字号由原稿决定。", "让阅读更舒适",
            "字号", "缩小字号", "增大字号", "字体", "衬线", "系统", "行距", "恢复默认",
            "轻点 Aa，打开微信读书字体设置", "取消", "Kindle 字号", "减小字号",
            "正在应用阅读设置…", "调整后将重新排版当前页。点击播放，从当前页开始朗读。",
            "跳过脚注引用编号", "仅跳过可明确识别的上标脚注编号，保留正文数字和脚注内容。",
            "此页面暂时无法调整字号，请关闭设置后重试。"
        ]
        for language in AppLanguage.allCases where language != .system {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language.rawValue, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in keys {
                let value = bundle.localizedString(forKey: key, value: "__missing__", table: "Localizable")
                XCTAssertNotEqual(value, "__missing__", "\(language.rawValue): \(key)")
                XCTAssertFalse(value.isEmpty)
                if language != .simplifiedChinese, key.count > 4 {
                    XCTAssertNotEqual(value, key, "Untranslated \(language.rawValue): \(key)")
                }
            }
            let minutes = bundle.localizedString(forKey: "%lld 分钟", value: nil, table: "Localizable")
            XCTAssertTrue(minutes.contains("%lld"), language.rawValue)
        }
    }

    func testStopTimeUsesTheRequestedInterfaceLocale() {
        let date = Date(timeIntervalSince1970: 1_789_113_600)
        let english = ReaderMoreFormatting.stopTime(date, locale: Locale(identifier: "en_US"))
        let chinese = ReaderMoreFormatting.stopTime(date, locale: Locale(identifier: "zh_CN"))
        let german = ReaderMoreFormatting.stopTime(date, locale: Locale(identifier: "de_DE"))
        XCTAssertNotEqual(english, chinese)
        XCTAssertNotEqual(english, german)
        XCTAssertTrue(chinese.contains("月"))
        XCTAssertFalse(english.contains("月"))
    }

    func testWeReadPromptFollowsEveryInterfaceLanguage() async throws {
        let manager = AppLanguageManager.shared
        let original = manager.selectedLanguage
        defer { manager.select(original) }
        for language in AppLanguage.allCases where language != .system {
            manager.select(language)
            let view = try await fixture(html: """
            <button class="readerControls_item fontSizeButton">Aa</button>
            """, baseURL: URL(string: "https://weread.qq.com/web/reader/test"))
            let opened = await ReaderWebAppearanceCenter.shared.open(webView: view)
            XCTAssertTrue(opened, language.rawValue)
            let hint = try await view.evaluateJavaScript("document.querySelector('#castreader-weread-aa span').textContent")
            let cancel = try await view.evaluateJavaScript("document.querySelector('#castreader-weread-aa button:last-child').textContent")
            XCTAssertEqual(hint as? String, AppLocalized("轻点 Aa，打开微信读书字体设置"))
            XCTAssertEqual(cancel as? String, AppLocalized("取消"))
            _ = try await view.evaluateJavaScript("window.__crWeReadAppearance.close()")
        }
    }

    func testGenericProviderDelegatesToNativeControl() async throws {
        for label in ["Font settings", "阅读设置", "開啟閱讀設定", "Appearance", "Aa"] {
            let webView = try await fixture(label: label)
            let opened = await ReaderWebAppearanceCenter.shared.open(webView: webView)
            XCTAssertTrue(opened, label)
            let taps = try await webView.evaluateJavaScript("window.aaTaps")
            XCTAssertEqual(taps as? Int, 1)
        }
    }

    func testWeReadIconOnlyNativeAaButton() async throws {
        let webView = try await fixture(html: """
        <button class="readerControls_item fontSizeButton" style="width:40px;height:40px" onclick="window.aaTaps++;document.querySelector('.font-panel-content').style.display='block'"><span class="icon"></span></button>
        <div class="reader-font-control-panel-wrapper"><div class="font-panel-content" style="display:none;width:440px;height:300px"></div></div>
        """, baseURL: URL(string: "https://weread.qq.com/web/reader/test"))
        let opened = await ReaderWebAppearanceCenter.shared.open(webView: webView)
        XCTAssertTrue(opened)
        let taps = try await webView.evaluateJavaScript("window.aaTaps")
        XCTAssertEqual(taps as? Int, 0, "Expose the original control without synthesizing trusted input")
        let visible = try await webView.evaluateJavaScript("document.querySelector('#castreader-weread-aa button') === document.querySelector('.fontSizeButton')")
        XCTAssertEqual(visible as? Bool, true)
        _ = try await webView.evaluateJavaScript("window.__crWeReadAppearance.close()")
        let restored = try await webView.evaluateJavaScript("document.querySelector('.fontSizeButton').parentElement === document.body && !document.querySelector('#castreader-weread-aa')")
        XCTAssertEqual(restored as? Bool, true)
    }

    func testWeReadNativePanelFitsViewportAndRestoresAfterDismissal() async throws {
        let view = try await fixture(html: """
        <button class="readerControls_item fontSizeButton" onmouseenter="document.querySelector('.font-panel-content').style.display='block'" onclick="window.aaTaps++">Aa</button>
        <div class="reader-font-control-panel-wrapper"><div class="font-panel-content" style="display:none;position:absolute;left:800px;width:440px;height:300px"></div></div>
        """, baseURL: URL(string: "https://weread.qq.com/web/reader/test"))
        let opened = await ReaderWebAppearanceCenter.shared.open(webView: view)
        XCTAssertTrue(opened)
        // A fixture simulates the provider's post-tap state. Real trusted touch
        // is verified separately on the user's iPhone, not by this DOM fixture.
        _ = try await view.evaluateJavaScript("document.querySelector('.font-panel-content').style.display='block'")
        try await Task.sleep(nanoseconds: 100_000_000)
        let reopened = await ReaderWebAppearanceCenter.shared.open(webView: view)
        XCTAssertTrue(reopened)
        let result = try await view.evaluateJavaScript("({taps:window.aaTaps,left:document.querySelector('.font-panel-content').getBoundingClientRect().left,right:document.querySelector('.font-panel-content').getBoundingClientRect().right,width:innerWidth})")
        let values = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(values["taps"] as? Int, 0)
        XCTAssertGreaterThanOrEqual(values["left"] as? Double ?? -1, 0)
        XCTAssertLessThanOrEqual(values["right"] as? Double ?? .infinity, values["width"] as? Double ?? 0)
        _ = try await view.evaluateJavaScript("document.querySelector('.font-panel-content').style.display='none'")
        try await Task.sleep(nanoseconds: 100_000_000)
        let closed = try await view.evaluateJavaScript("!window.__crWeReadAppearance && getComputedStyle(document.querySelector('.font-panel-content')).display === 'none' && document.querySelector('.font-panel-content').style.left === '800px'")
        XCTAssertEqual(closed as? Bool, true)
    }

    func testGoogleDisplayOptionsInsideOverflow() async throws {
        let webView = try await fixture(html: """
        <button aria-label="更多" onclick="setTimeout(()=>document.querySelector('[role=menuitem]').style.display='block',50)">⋮</button>
        <button role="menuitem" style="display:none" onclick="window.aaTaps++">显示选项</button>
        """, baseURL: URL(string: "https://books.googleusercontent.com/books/reader/frame"))
        let opened = await ReaderWebAppearanceCenter.shared.open(webView: webView)
        XCTAssertTrue(opened)
        let taps = try await webView.evaluateJavaScript("window.aaTaps")
        XCTAssertEqual(taps as? Int, 1)
    }

    func testGenericAppearanceDoesNotAlterFontSizeOrOpenUnrelatedMore() async throws {
        let webView = try await fixture(html: """
        <button aria-label="Increase font size" onclick="window.wrong=true">+</button>
        <button aria-label="More" onclick="window.wrong=true">⋮</button>
        """, baseURL: URL(string: "https://example.invalid/article"))
        let opened = await ReaderWebAppearanceCenter.shared.open(webView: webView)
        XCTAssertFalse(opened)
        let wrong = try await webView.evaluateJavaScript("window.wrong === true")
        XCTAssertEqual(wrong as? Bool, false)
    }

    func testPresentationProbeExcludesAccountControls() async throws {
        let webView = try await fixture(html: """
        <button aria-label="Google 账号 Synthetic Person synthetic@example.invalid">Account</button>
        <button aria-label="显示选项">Aa</button>
        """)
        let snapshot = try await json(ReaderWebAppearanceCenter.presentationProbe, webView)
        let controls = try XCTUnwrap(snapshot["controls"] as? [[String: Any]])
        XCTAssertEqual(controls.count, 1)
        XCTAssertEqual(controls.first?["label"] as? String, "显示选项")
    }

    func testWeReadVisibleCoverOrAaDoesNotRequireExtractableText() async throws {
        for className in ["horizontalReaderCoverPage", "reader-font-control-panel-wrapper"] {
            let view = try await fixture(html: """
            <script>document.body.className='wr_page_reader'</script>
            <button class="readerControls_item fontSizeButton">Aa</button>
            <div class="\(className)" style="width:200px;height:300px"></div>
            """, baseURL: URL(string: "https://weread.qq.com/web/reader/test"))
            let usable = try await view.evaluateJavaScript(WeReadWebScripts.hasUsableNonTextReaderSurface)
            XCTAssertEqual(usable as? Bool, true, className)
            _ = try await view.evaluateJavaScript("document.querySelector('div').style.display='none'")
            let hidden = try await view.evaluateJavaScript(WeReadWebScripts.hasUsableNonTextReaderSurface)
            XCTAssertEqual(hidden as? Bool, false, "Hidden server-rendered placeholders are not ready")
        }
    }

    func testWeReadCanvasCoverRetainsItsRenderedNativePager() async throws {
        let view = try await fixture(html: """
        <script>document.body.className='wr_page_reader'</script>
        <button class="readerControls_item fontSizeButton">Aa</button>
        <div class="horizontalReaderCoverPage" style="display:none"></div>
        <canvas width="400" height="700"></canvas>
        <button class="renderTarget_pager_button renderTarget_pager_button_right" style="width:80px;height:40px">下一页</button>
        """, baseURL: URL(string: "https://weread.qq.com/web/reader/test"))
        let usable = try await view.evaluateJavaScript(WeReadWebScripts.hasUsableNonTextReaderSurface)
        XCTAssertEqual(usable as? Bool, true)
    }

    func testAppearanceHoldBlocksLateAudioAndSleepExpiryStillWins() async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        defer { audio.clearForAccountBoundary() }
        let token = audio.claimPlaybackSession(owner: .readAloud)
        let hold = audio.beginReaderAppearance()
        let segment = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
                                   audioData: ReadingResumeFixtureSpeech.wav(), timestamps: [],
                                   duration: 16, text: "Appearance test", isWavFormat: true)
        XCTAssertTrue(audio.loadSegment(segment, session: token))
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(audio.play(session: token))
        audio.sleepTimer.start(after: 0.05)
        try await Task.sleep(nanoseconds: 100_000_000)
        audio.sleepTimer.checkDeadline()
        audio.endReaderAppearance(hold)
        XCTAssertFalse(audio.play(session: token))
        audio.sleepTimer.resumeByUser()
        XCTAssertTrue(audio.play(session: token))
    }

    func testAppearanceHoldDoesNotPauseNewOwner() {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        defer { audio.clearForAccountBoundary() }
        _ = audio.claimPlaybackSession(owner: .readAloud)
        let hold = audio.beginReaderAppearance()
        let token = audio.claimPlaybackSession(owner: .explain)
        let segment = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
                                   audioData: ReadingResumeFixtureSpeech.wav(), timestamps: [],
                                   duration: 16, text: "New owner", isWavFormat: true)
        XCTAssertTrue(audio.loadSegments([segment], autoPlay: false, session: token))
        XCTAssertTrue(audio.play(session: token))
        audio.endReaderAppearance(hold, resumePlayback: false)
    }

    func testExplicitPauseDuringPreviewPreventsLateAutomaticResume() async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        defer { audio.clearForAccountBoundary() }
        let token = audio.claimPlaybackSession(owner: .readAloud)
        let segment = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadingResumeFixtureSpeech.wav(), timestamps: [],
            duration: 16, text: "Preview pause intent", isWavFormat: true)
        XCTAssertTrue(audio.loadSegments([segment], autoPlay: true, session: token))
        for _ in 0..<40 where !audio.isPlaying { try await Task.sleep(for: .milliseconds(25)) }
        let handle = try XCTUnwrap(audio.suspendActivePlaybackForVoicePreview())
        XCTAssertTrue(audio.pause(session: token))
        XCTAssertFalse(audio.resumePlaybackAfterVoicePreview(handle))
        XCTAssertFalse(audio.isPlaying)
    }

    private func json(_ script: String, _ webView: WKWebView) async throws -> [String: Any] {
        let raw = try await webView.evaluateJavaScript(script)
        let text = try XCTUnwrap(raw as? String)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func fixture(label: String = "Aa", shadow: Bool = false, html: String? = nil, baseURL: URL? = nil) async throws -> WKWebView {
        let content = html ?? """
        <button id="reader-font-settings" aria-expanded="false" onclick="window.aaTaps++; const p=this.getRootNode().querySelector('[role=dialog]'); p.style.display='block'; this.setAttribute('aria-expanded','true')">\(label)</button>
        <section role="dialog" aria-label="Font settings" style="display:none">
          <input type="range" aria-label="Font size" min="1" max="10" value="5">
          <select aria-label="Theme"><option value="light">Light</option><option value="dark">Dark</option></select>
          <button aria-label="Close" onclick="this.parentNode.style.display='none'; this.getRootNode().querySelector('#reader-font-settings').setAttribute('aria-expanded','false')">Close</button>
        </section>
        """
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [content]), encoding: .utf8)!
        let body = shadow ? "<div id='host'></div><script>document.querySelector('#host').attachShadow({mode:'open'}).innerHTML=\(encoded)[0]</script>" : content
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        view.loadHTMLString("<!doctype html><html><body><script>window.aaTaps=0</script>\(body)</body></html>", baseURL: baseURL)
        for _ in 0..<100 {
            let ready = try? await view.evaluateJavaScript("document.readyState") as? String
            if !view.isLoading, ready == "complete" { return view }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("Appearance WKWebView fixture did not load")
        return view
    }
}
