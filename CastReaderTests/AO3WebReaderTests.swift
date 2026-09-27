import XCTest
import WebKit
@testable import CastReader

@MainActor
private final class AO3TestRelay: NSObject, WKScriptMessageHandler {
    let bridge: WebReaderBridge
    var taps: [Int] = []
    init(_ bridge: WebReaderBridge) { self.bridge = bridge }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        if let value = WebInboundMessage(message.body), value.type == "paragraphTapped" {
            if let index = value.payload["paragraphIndex"] as? Int { taps.append(index) }
            // Verify emitted tap coordinates without starting a cloud TTS job.
        } else { bridge.userContentController(controller, didReceive: message) }
    }
}

@MainActor
private final class AO3TestReader {
    let read: ReadAloudViewModel
    let explain: ExplainViewModel
    let bridge = WebReaderBridge()
    let web: WKWebView
    let window: UIWindow
    let relay: AO3TestRelay
    init(url: String) throws {
        let document = try XCTUnwrap(DocumentBuilder.fromWebURL(url))
        read = ReadAloudViewModel(document: document)
        explain = ExplainViewModel(document: document)
        relay = AO3TestRelay(bridge)
        let content = WKUserContentController()
        content.add(relay, name: "castreader")
        content.addUserScript(WKUserScript(source: try XCTUnwrap(WebReaderView.loadBundleJS(readerURL: url)),
                                          injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        bridge.webView = web
        bridge.configure(expectsDynamicWebContent: true, readerURL: url)
        bridge.attach(readVM: read, explainVM: explain)
        web.navigationDelegate = bridge
        window = UIWindow(frame: web.frame)
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.rootViewController!.view.addSubview(web)
    }
    func close() {
        read.deactivate(); explain.deactivate()
        web.stopLoading(); web.removeFromSuperview(); window.isHidden = true
        web.configuration.userContentController.removeScriptMessageHandler(forName: "castreader")
    }
}

@MainActor
final class AO3WebReaderTests: XCTestCase {
    private let url = "https://archiveofourown.org/works/86539701/chapters/231697481#workskin"
    private let lines = ["A short first paragraph.", "A repeated line.", "A repeated line.", "Last paragraph with emphasis."]
    private func html(notice: Bool = false, hiddenNotice: Bool = false, body: String? = nil) -> String {
        """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:18px/1.5 -apple-system;margin:12px}.landmark{display:none}p{margin:15px 0}</style></head><body>
        \(notice ? "<div id='tos_prompt' style='display:\(hiddenNotice ? "none" : "block")'><p>Terms of Service text must never be read as fiction.</p><input id='tos_agree' type='checkbox'><button id='accept_tos'>Accept</button></div>" : "")
        <div id="outer"><div class="preface"><p>Work summary is not chapter prose.</p></div>
        <div id="chapters"><div class="chapter"><div class="notes"><p>Author note is not chapter prose.</p></div>
        <div class="userstuff module" role="article"><h3 class="landmark">Chapter Text</h3>
        \(body ?? "<p>A short first paragraph.</p><p>A repeated line.</p><p>A repeated line.</p><p>Last paragraph with <em>emphasis</em>.</p>")
        </div></div></div><div id="comments"><p>Comments are not chapter prose.</p></div></div>
        </body></html>
        """
    }
    private func wait(_ condition: () async throws -> Bool) async throws {
        for _ in 0..<80 {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("AO3 page did not reach the expected state")
    }
    private func withReader(_ run: (AO3TestReader) async throws -> Void) async throws {
        let previous = AppSettings.shared.autoPlay
        AppSettings.shared.autoPlay = false
        let reader = try AO3TestReader(url: url)
        defer { reader.close(); AppSettings.shared.autoPlay = previous }
        try await run(reader)
    }

    func testNoticeIncludingHiddenPendingPhaseNeverCommitsAndRecoversAutomatically() async throws {
        for hidden in [false, true] {
            try await withReader { reader in
                reader.web.loadHTMLString(html(notice: true, hiddenNotice: hidden), baseURL: URL(string: url))
                try await wait { (try await reader.web.evaluateJavaScript("window.__crLastRendered?.length === 0")) as? Bool == true }
                XCTAssertTrue(reader.read.stagedLiveWebParagraphTexts.isEmpty)
                XCTAssertTrue(reader.explain.stagedLiveWebParagraphTexts.isEmpty)
                reader.read.start(); reader.read.ensurePlaying(); reader.read.jump(to: 0)
                reader.explain.start(); reader.explain.ensurePlaying(); reader.explain.replay()
                XCTAssertFalse(reader.read.isActive)
                XCTAssertFalse(reader.explain.isActive)
                let checked = try await reader.web.evaluateJavaScript("document.getElementById('tos_agree').checked") as? Bool
                XCTAssertEqual(checked, false, "Never automatically accept AO3 terms")
                _ = try await reader.web.evaluateJavaScript("document.getElementById('tos_prompt').remove()")
                try await wait { reader.read.stagedLiveWebParagraphTexts == self.lines }
                XCTAssertEqual(reader.explain.stagedLiveWebParagraphTexts, lines)
                XCTAssertNil(reader.read.webContentBlockMessage)
                XCTAssertNil(reader.explain.webContentBlockMessage)
                _ = try await reader.web.evaluateJavaScript("document.querySelectorAll('#chapters [role=article] p')[2].click()")
                try await wait { reader.relay.taps == [2] }
            }
        }
    }

    func testLateNoticeInvalidatesBothModesAndDoesNotRestartPausedPlayback() async throws {
        try await withReader { reader in
            reader.web.loadHTMLString(html(), baseURL: URL(string: url))
            try await wait { reader.read.stagedLiveWebParagraphTexts == self.lines }
            // The site notice is not a new opening even if Auto Play is now
            // enabled; an explicit pause must still own the recovery.
            AppSettings.shared.autoPlay = true
            reader.read.pausePlayback()
            _ = try await reader.web.evaluateJavaScript("var n=document.createElement('div');n.id='tos_prompt';n.textContent='Terms';document.body.prepend(n)")
            try await wait { reader.read.stagedLiveWebParagraphTexts.isEmpty }
            XCTAssertTrue(reader.explain.stagedLiveWebParagraphTexts.isEmpty)
            let mapped = try await reader.web.evaluateJavaScript("document.querySelectorAll('[data-cr-para]').length") as? Int
            XCTAssertEqual(mapped, 0)
            _ = try await reader.web.evaluateJavaScript("document.getElementById('tos_prompt').remove()")
            try await wait { reader.read.stagedLiveWebParagraphTexts == self.lines }
            XCTAssertFalse(reader.read.isActive)
            XCTAssertFalse(reader.explain.isActive)
        }
    }

    func testChapterNavigationReplacesCommittedContentAndErrorPageClearsIt() async throws {
        try await withReader { reader in
            reader.web.loadHTMLString(html(), baseURL: URL(string: url))
            try await wait { reader.read.stagedLiveWebParagraphTexts == self.lines }
            let next = "https://archiveofourown.org/works/86539701/chapters/228985126"
            reader.web.loadHTMLString(html(body: "<p>New chapter.</p>"), baseURL: URL(string: next))
            try await wait { reader.read.stagedLiveWebParagraphTexts == ["New chapter."] }
            XCTAssertEqual(reader.explain.stagedLiveWebParagraphTexts, ["New chapter."])
            reader.web.loadHTMLString("<html><body><h1>SSL handshake failed</h1><p>Error code 525</p></body></html>", baseURL: URL(string: next))
            try await wait { reader.read.webContentBlockMessage != nil && reader.read.stagedLiveWebParagraphTexts.isEmpty }
            XCTAssertTrue(reader.explain.stagedLiveWebParagraphTexts.isEmpty)
        }
    }

    func testSameTextReplacementRebindsDOMAndRepeatedProseIsPreserved() async throws {
        try await withReader { reader in
            reader.web.loadHTMLString(html(), baseURL: URL(string: url))
            try await wait { reader.read.stagedLiveWebParagraphTexts == self.lines }
            _ = try await reader.web.evaluateJavaScript("var a=document.querySelector('[role=article]');a.innerHTML=a.innerHTML.replace(/ data-cr-para=\"[^\"]*\"/g,'')")
            try await wait { (try await reader.web.evaluateJavaScript("document.querySelectorAll('#chapters [data-cr-para]').length")) as? Int == 4 }
            XCTAssertEqual(reader.read.stagedLiveWebParagraphTexts, lines)
            let segments = try await reader.web.evaluateJavaScript("window.__crLastRendered.map(p=>p.text)") as? [String]
            XCTAssertEqual(segments, lines)
        }
    }

    func testUnwrappedMixedBlocksStayStableAcrossRepeatedExtraction() async throws {
        try await withReader { reader in
            reader.web.loadHTMLString(html(body: "Intro <em>inline</em><p>Middle.</p>Tail <strong>inline</strong>"), baseURL: URL(string: url))
            let expected = ["Intro inline", "Middle.", "Tail inline"]
            try await wait { reader.read.stagedLiveWebParagraphTexts == expected }
            for _ in 0..<3 { _ = try await reader.web.evaluateJavaScript("window.CR.extract()") }
            let segments = try await reader.web.evaluateJavaScript("window.__crLastRendered.map(p=>p.text)") as? [String]
            XCTAssertEqual(segments, expected)
            let count = try await reader.web.evaluateJavaScript("document.querySelectorAll('[data-cr-ao3-inline]').length") as? Int
            XCTAssertEqual(count, 2)
        }
    }

    func testRepeatedCachedPageRestorationRenewsIdentityAndObserver() async throws {
        try await withReader { reader in
            reader.web.loadHTMLString(html(), baseURL: URL(string: url))
            try await wait { reader.read.stagedLiveWebParagraphTexts == self.lines }
            for _ in 0..<3 {
                _ = try await reader.web.evaluateJavaScript("window.dispatchEvent(new PageTransitionEvent('pagehide',{persisted:true}))")
                reader.bridge.webView(reader.web, didStartProvisionalNavigation: nil)
                XCTAssertTrue(reader.read.stagedLiveWebParagraphTexts.isEmpty)
                _ = try await reader.web.evaluateJavaScript("window.dispatchEvent(new PageTransitionEvent('pageshow',{persisted:true}))")
                try await wait { reader.read.stagedLiveWebParagraphTexts == self.lines }
                _ = try await reader.web.evaluateJavaScript("var n=document.createElement('div');n.id='tos_prompt';n.textContent='Terms';document.body.prepend(n)")
                try await wait { reader.read.stagedLiveWebParagraphTexts.isEmpty }
                _ = try await reader.web.evaluateJavaScript("document.getElementById('tos_prompt').remove()")
                try await wait { reader.read.stagedLiveWebParagraphTexts == self.lines }
            }
        }
    }

    func testPayloadRejectsForeignHostsAndStaleChapterButIgnoresAnchor() {
        let payload: [String: Any] = ["source": "ao3", "state": "ready", "documentID": "doc-1", "signature": "abc", "url": url]
        XCTAssertNotNil(AO3PageUpdate(payload, currentURL: url.replacingOccurrences(of: "#workskin", with: "")))
        XCTAssertNil(AO3PageUpdate(payload, currentURL: url.replacingOccurrences(of: "231697481", with: "228985126")))
        XCTAssertFalse(AO3PageUpdate.isAO3URL("https://archiveofourown.org.example.com/works/1"))
        XCTAssertFalse(AO3PageUpdate.isAO3URL("file://archiveofourown.org/works/1"))
    }
}
