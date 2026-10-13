import XCTest
import WebKit
@testable import CastReader

@MainActor
final class ReaderAppearanceTests: XCTestCase {
    func testKindleOpensNativeAaWithoutChangingPreferences() async throws {
        let webView = try await fixture()
        let result = try await json(KindleWebScripts.openReaderAppearance, webView)
        XCTAssertEqual(result["ok"] as? Bool, true)
        let state = try await json(KindleWebScripts.readerAppearanceState, webView)
        XCTAssertEqual(state["open"] as? Bool, true)
        let value = try await webView.evaluateJavaScript("document.querySelector('input').value")
        XCTAssertEqual(value as? String, "5")
        // Reopening must be idempotent, not toggle the native panel closed.
        _ = try await json(KindleWebScripts.openReaderAppearance, webView)
        let taps = try await webView.evaluateJavaScript("window.aaTaps")
        XCTAssertEqual(taps as? Int, 1)
    }

    func testKindleClosePreservesUserFontAndTheme() async throws {
        let webView = try await fixture()
        _ = try await json(KindleWebScripts.openReaderAppearance, webView)
        _ = try await webView.evaluateJavaScript("document.querySelector('input').value='8'; document.querySelector('select').value='dark'")
        _ = try await json(KindleWebScripts.closeReaderAppearance, webView)
        let state = try await json(KindleWebScripts.readerAppearanceState, webView)
        XCTAssertEqual(state["open"] as? Bool, false)
        let values = try await webView.evaluateJavaScript("[document.querySelector('input').value,document.querySelector('select').value]")
        XCTAssertEqual(values as? [String], ["8", "dark"])
    }

    func testKindleLocalizedSettingsAndShadowDOM() async throws {
        for label in ["Impostazioni di lettura", "Lettertype-instellingen", "Aa"] {
            let webView = try await fixture(label: label, shadow: true)
            let result = try await json(KindleWebScripts.openReaderAppearance, webView)
            XCTAssertEqual(result["ok"] as? Bool, true, label)
            let state = try await json(KindleWebScripts.readerAppearanceState, webView)
            XCTAssertEqual(state["open"] as? Bool, true, label)
        }
    }

    func testKindleDoesNotClickFontSizeControlAsAa() async throws {
        let webView = try await fixture(html: "<button id='font-size-increase' aria-label='Increase font size' onclick='window.wrong=true'>+</button>")
        let result = try await json(KindleWebScripts.openReaderAppearance, webView)
        XCTAssertEqual(result["ok"] as? Bool, false)
        let wrong = try await webView.evaluateJavaScript("window.wrong === true")
        XCTAssertEqual(wrong as? Bool, false)
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

    func testKindleAppearanceTemporarilyReleasesNativeChromeLock() async throws {
        let webView = try await fixture()
        _ = try await webView.evaluateJavaScript(KindleWebScripts.pageModeLockBootstrap)
        _ = try await webView.evaluateJavaScript("window.__crKindleSetPageModeLocked(true)")
        _ = try await json(KindleWebScripts.beginReaderAppearance, webView)
        let unlocked = try await webView.evaluateJavaScript("!window.__crKindleProbe.pageModeLocked && window.__crKindleAppearanceActive")
        XCTAssertEqual(unlocked as? Bool, true)
        let result = try await json(KindleWebScripts.openReaderAppearance, webView)
        XCTAssertEqual(result["ok"] as? Bool, true)
        _ = try await json(KindleWebScripts.closeReaderAppearance, webView)
        _ = try await json(KindleWebScripts.endReaderAppearance, webView)
        let restored = try await webView.evaluateJavaScript("window.__crKindleProbe.pageModeLocked && !window.__crKindleAppearanceActive")
        XCTAssertEqual(restored as? Bool, true)
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
