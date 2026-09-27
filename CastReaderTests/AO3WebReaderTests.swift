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
    init(url: String, speech: (any ParagraphSpeechGenerating)? = nil, pages: [String: String]? = nil, quickRead: QuickReadService? = nil) throws {
        let document = try XCTUnwrap(DocumentBuilder.fromWebURL(url))
        read = ReadAloudViewModel(document: document, speechGenerator: speech)
        explain = ExplainViewModel(document: document, speechGenerator: speech, quickReadService: quickRead)
        relay = AO3TestRelay(bridge)
        let content = WKUserContentController()
        content.add(relay, name: "castreader")
        content.addUserScript(WKUserScript(source: try XCTUnwrap(WebReaderView.loadBundleJS(readerURL: url)),
                                          injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = content
        configuration.websiteDataStore = .nonPersistent()
        if let pages {
            web = AO3FixtureWebView(configuration: configuration, pages: pages)
            bridge.makeAO3Preloader = { AO3ChapterPreloader { AO3FixtureWebView(configuration: $0, pages: pages) } }
        } else {
            web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        }
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
        bridge.stopAO3Preparation()
        read.stop(); explain.stop()
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


@MainActor
final class AO3FixtureWebView: WKWebView {
    let pages: [String: String]
    init(configuration: WKWebViewConfiguration, pages: [String: String]) {
        self.pages = pages
        super.init(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func load(_ request: URLRequest) -> WKNavigation? {
        guard let url = request.url, let key = AO3PageUpdate.pageKey(url.absoluteString), let page = pages[key] else { return nil }
        return loadHTMLString(page, baseURL: url)
    }
}

private actor AO3SpeechFixture: ParagraphSpeechGenerating {
    private(set) var inputs: [String] = []
    func generateTTSForParagraph(paragraphIndex: Int, text: String, voice: String?, speed: Double,
        language: String, includeVoiceCode: Bool, speaker: String?, cloneRequestID: String?,
        continuation: TTSContinuation?, onCheckpoint: ((TTSContinuation) async -> Void)?,
        onSegmentReady: @escaping (AudioSegment) async -> Void) async throws {
        inputs.append(text)
        await onSegmentReady(AudioSegment(paragraphIndex: paragraphIndex, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 3),
            timestamps: [TTSTimestamp(word: text, startTime: 0, endTime: 2.8)],
            duration: 3, text: text, isWavFormat: true))
    }
}

extension AO3WebReaderTests {
    private func chapterPages() -> [String: String] {
        (1...3).reduce(into: [:]) { result, chapter in
            let navigation = "<ul class='actions'>" +
                (chapter > 1 ? "<li class='chapter previous'><a href='/works/1/chapters/\(chapter - 1)#workskin'>Previous</a></li>" : "") +
                (chapter < 3 ? "<li class='chapter next'><a href='/works/1/chapters/\(chapter + 1)#workskin'>Next</a></li>" : "") + "</ul>"
            result["https://archiveofourown.org/works/1/chapters/\(chapter)"] = html(body: "<p>Chapter \(chapter) prose. The traveler followed the river home and remembered the journey.</p>").replacingOccurrences(of: "</body>", with: navigation + "</body>")
        }
    }
    private func withPlaybackReader(_ body: (AO3TestReader, AO3SpeechFixture) async throws -> Void) async throws {
        let auto = AppSettings.shared.autoPlay, pro = ProManager.shared.debugForcePro
        AppSettings.shared.autoPlay = false; ProManager.shared.debugForcePro = true
        let speech = AO3SpeechFixture(), pages = chapterPages()
        let reader = try AO3TestReader(url: "https://archiveofourown.org/works/1/chapters/1", speech: speech, pages: pages)
        defer { reader.close(); AppSettings.shared.autoPlay = auto; ProManager.shared.debugForcePro = pro }
        reader.web.load(URLRequest(url: URL(string: "https://archiveofourown.org/works/1/chapters/1")!))
        try await wait { reader.read.stagedLiveWebParagraphTexts == ["Chapter 1 prose. The traveler followed the river home and remembered the journey."] }
        try await body(reader, speech)
    }
    func testPreloadedChapterDoesNotReplaceCurrentDOMAndNaturalCompletionContinuesAudio() async throws {
        try await withPlaybackReader { reader, speech in
            try await wait { reader.bridge.ao3PreparedChapterURL?.hasSuffix("/2") == true }
            XCTAssertEqual(reader.read.stagedLiveWebParagraphTexts, ["Chapter 1 prose. The traveler followed the river home and remembered the journey."])
            XCTAssertFalse(reader.read.isPlaying)
            reader.read.start()
            try await wait { reader.read.isPlaying && reader.bridge.ao3PreparedSpeechCount > 0 }
            try await wait { (try await reader.web.evaluateJavaScript("document.querySelectorAll('.cr-hl-ov').length")) as? Int ?? 0 > 0 }
            try await wait { reader.read.stagedLiveWebParagraphTexts == ["Chapter 2 prose. The traveler followed the river home and remembered the journey."] && reader.read.isPlaying }
            XCTAssertEqual(reader.explain.stagedLiveWebParagraphTexts, ["Chapter 2 prose. The traveler followed the river home and remembered the journey."])
            let requests = await speech.inputs
            XCTAssertEqual(requests.filter { $0 == "Chapter 2 prose. The traveler followed the river home and remembered the journey." }.count, 1, "Promote preloaded audio without generating it twice")
        }
    }
    func testManualPreviousDuringAutomaticTurnWinsAndPausedNavigationStaysPaused() async throws {
        try await withPlaybackReader { reader, _ in
            reader.bridge.requestUserPageTurn(.next)
            try await wait { reader.read.stagedLiveWebParagraphTexts == ["Chapter 2 prose. The traveler followed the river home and remembered the journey."] }
            reader.read.pausePlayback()
            reader.bridge.requestUserPageTurn(.next)
            try await wait { reader.read.stagedLiveWebParagraphTexts == ["Chapter 3 prose. The traveler followed the river home and remembered the journey."] }
            XCTAssertFalse(reader.read.isPlaying)
            reader.bridge.requestUserPageTurn(.previous)
            try await wait { reader.read.stagedLiveWebParagraphTexts == ["Chapter 2 prose. The traveler followed the river home and remembered the journey."] }
            reader.read.start()
            try await wait { reader.read.isPlaying }
            reader.read.onDocumentFinished?(nil)
            reader.bridge.requestUserPageTurn(.previous)
            try await wait { reader.read.stagedLiveWebParagraphTexts == ["Chapter 1 prose. The traveler followed the river home and remembered the journey."] }
            XCTAssertFalse(reader.read.stagedLiveWebParagraphTexts.contains("Chapter 3 prose. The traveler followed the river home and remembered the journey."))
        }
    }
    func testReplayUsesCommittedChapterAndPauseDuringTurnPreventsLateAudio() async throws {
        try await withPlaybackReader { reader, speech in
            reader.read.start()
            try await wait { reader.read.isPlaying }
            reader.bridge.requestUserPageTurn(.next)
            reader.read.pausePlayback()
            try await wait { reader.read.stagedLiveWebParagraphTexts == ["Chapter 2 prose. The traveler followed the river home and remembered the journey."] }
            XCTAssertFalse(reader.read.isPlaying)
            reader.read.jump(to: 0)
            try await wait { reader.read.isPlaying }
            XCTAssertEqual(AudioPlayerService.shared.currentSegment?.text, "Chapter 2 prose. The traveler followed the river home and remembered the journey.")
            reader.read.pausePlayback()
            reader.read.jump(to: 0)
            try await wait { reader.read.isPlaying }
            XCTAssertEqual(AudioPlayerService.shared.currentSegment?.text, "Chapter 2 prose. The traveler followed the river home and remembered the journey.")
            let requests = await speech.inputs
            XCTAssertFalse(requests.isEmpty)
        }
    }
    func testPreloadNoticeNeverBecomesPlayableAndFailureLeavesCurrentChapterIntact() async throws {
        let pages = chapterPages().merging(["https://archiveofourown.org/works/1/chapters/2": html(notice: true)]) { _, new in new }
        let reader = try AO3TestReader(url: "https://archiveofourown.org/works/1/chapters/1", pages: pages)
        let auto = AppSettings.shared.autoPlay; AppSettings.shared.autoPlay = false
        defer { reader.close(); AppSettings.shared.autoPlay = auto }
        reader.web.load(URLRequest(url: URL(string: "https://archiveofourown.org/works/1/chapters/1")!))
        try await wait { reader.read.stagedLiveWebParagraphTexts == ["Chapter 1 prose. The traveler followed the river home and remembered the journey."] }
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNil(reader.bridge.ao3PreparedChapterURL)
        XCTAssertEqual(reader.read.stagedLiveWebParagraphTexts, ["Chapter 1 prose. The traveler followed the river home and remembered the journey."])
        reader.bridge.requestUserPageTurn(.next)
        try await wait { reader.read.webContentBlockMessage != nil }
        XCTAssertTrue(reader.read.stagedLiveWebParagraphTexts.isEmpty)
        XCTAssertTrue(reader.explain.stagedLiveWebParagraphTexts.isEmpty)
    }
}


private actor AO3FixtureSessionProvider: MobileSessionProviding {
    func sessionToken() -> String? { "cms_fixture" }
    func refreshSession() -> String? { "cms_fixture" }
    func invalidateSession() {}
    func rejectSession(_ token: String?) {}
}

extension AO3WebReaderTests {
    func testExplainReplayAndManualChapterTurnReplaceNarrationAndOriginalTextTogether() async throws {
        let auto = AppSettings.shared.autoPlay, pro = ProManager.shared.debugForcePro
        AppSettings.shared.autoPlay = false; ProManager.shared.debugForcePro = true
        var chapterText = "Chapter 1 prose. The traveler followed the river home and remembered the journey."
        var jobSources: [String: String] = [:]
        let plan = ReadAloudHTTPFixture.forRequests { request, body in
            if request.url?.path == "/api/quickread/extract-plan" {
                let source = body["markdown"] as? String ?? body["text"] as? String ?? chapterText
                let job = UUID().uuidString
                jobSources[job] = source
                let mark: [String: Any] = ["action":"underline", "text":source, "at":0.1]
                let section: [String: Any] = ["id":"block-0", "text":"Explanation of \(source)", "style":"explain", "cinematic":["events":[mark]]]
                let block: [String: Any] = ["job_id":job, "output_language":"en", "total_blocks":1, "block_0":section]
                let json = String(data: try! JSONSerialization.data(withJSONObject: block), encoding: .utf8)!
                return .response(Data("event: block0\ndata: \(json)\n\nevent: done\ndata: {\"total_blocks\":1}\n\n".utf8))
            }
            let source = jobSources[body["job_id"] as? String ?? ""] ?? chapterText
            let mark: [String: Any] = ["action":"underline", "text":source, "at":0.1]
            let section: [String: Any] = ["id":"block-0", "text":"Explanation of \(source)", "style":"explain", "cinematic":["events":[mark]]]
            return .response(try! JSONSerialization.data(withJSONObject: ["section":section]))
        }
        let reader = try AO3TestReader(url: "https://archiveofourown.org/works/1/chapters/1", speech: AO3SpeechFixture(), pages: chapterPages(),
            quickRead: QuickReadService(session: plan.session, mobileSessionProvider: AO3FixtureSessionProvider()))
        defer { reader.close(); plan.close(); AppSettings.shared.autoPlay = auto; ProManager.shared.debugForcePro = pro }
        reader.web.load(URLRequest(url: URL(string: "https://archiveofourown.org/works/1/chapters/1")!))
        try await wait { reader.read.stagedLiveWebParagraphTexts == ["Chapter 1 prose. The traveler followed the river home and remembered the journey."] }
        reader.bridge.setActive(readMode: false)
        reader.explain.start()
        try await wait { reader.explain.isPlaying }
        try await wait { reader.bridge.ao3HasPreparedExplanation }
        let countBeforeReplay = plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count
        reader.explain.replay()
        try await wait { reader.explain.isPlaying }
        XCTAssertEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count, countBeforeReplay)
        chapterText = "Chapter 2 prose. The traveler followed the river home and remembered the journey."
        reader.bridge.requestUserPageTurn(.next)
        try await wait { reader.explain.stagedLiveWebParagraphTexts == ["Chapter 2 prose. The traveler followed the river home and remembered the journey."] && reader.explain.isPlaying }
        XCTAssertEqual(reader.read.stagedLiveWebParagraphTexts, ["Chapter 2 prose. The traveler followed the river home and remembered the journey."])
        XCTAssertTrue(AudioPlayerService.shared.currentSegment?.text.contains("Chapter 2") == true)
        try await wait { !reader.explain.activeMarks.isEmpty }
        XCTAssertTrue(reader.explain.activeMarks.allSatisfy { $0.paragraphIndex == 0 })
        XCTAssertGreaterThanOrEqual(plan.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }.count, 2)
    }
}


extension AO3WebReaderTests {
    func testLastChapterEndsOnceAndPlaybackButtonReplaysItsOpening() async throws {
        try await withPlaybackReader { reader, _ in
            reader.bridge.requestUserPageTurn(.next)
            try await wait { reader.read.stagedLiveWebParagraphTexts.first?.hasPrefix("Chapter 2") == true }
            reader.bridge.requestUserPageTurn(.next)
            try await wait { reader.read.stagedLiveWebParagraphTexts.first?.hasPrefix("Chapter 3") == true }
            reader.read.start()
            try await wait { reader.read.isFinished }
            XCTAssertTrue(reader.web.url?.path.hasSuffix("/3") == true)
            reader.read.togglePlayPause()
            try await wait { reader.read.isPlaying && !reader.read.isFinished }
            XCTAssertTrue(AudioPlayerService.shared.currentSegment?.text.hasPrefix("Chapter 3") == true)
        }
    }
}
