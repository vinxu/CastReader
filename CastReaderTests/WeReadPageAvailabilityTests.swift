import XCTest
import WebKit
@testable import CastReader

/// Actual WebKit adapter + native bridge + shared AVPlayer. Only TTS transport
/// is controlled, so delayed audio and DOM mutations use production ownership.
@MainActor
final class WeReadPageAvailabilityTests: XCTestCase {
    private let url = "https://weread.qq.com/web/reader/availability-fixture"
    private let first = "The first visible page is still here. Delayed tail."
    private let second = "The second visible page has arrived."
    private var oldAutoPlay = false
    private var oldPro = false
    private var root: URL!
    private var web: WKWebView!
    private var window: UIWindow!
    private var bridge: WebReaderBridge!
    private var read: ReadAloudViewModel!
    private var explain: ExplainViewModel!
    private var fixture: ReadAloudHTTPFixture!
    private var planFixture: ReadAloudHTTPFixture!
    private var planReply: ReadAloudHTTPFixture.Reply = .response(Data("{\"error\":\"text_too_short\"}".utf8), status: 400)

    private let audio = AudioPlayerService.shared

    override func setUp() async throws {
        oldAutoPlay = AppSettings.shared.autoPlay
        oldPro = ProManager.shared.debugForcePro
        AppSettings.shared.autoPlay = false
        ProManager.shared.debugForcePro = true
        useRegularVoiceForTest(language: "en")
        audio.clearForAccountBoundary()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fixture = ReadAloudHTTPFixture { text, _ in
            if text == "Delayed tail." {
                return .response(ReadAloudHTTPFixture.body(text, duration: 2), delay: 2.5)
            }
            if text == self.first {
                return .response(ReadAloudHTTPFixture.body("The first visible page is still here. ", tail: "Delayed tail.", duration: 0.25))
            }
            return .response(ReadAloudHTTPFixture.body(text, duration: 5))
        }
        let document = ReadingDocument(id: UUID().uuidString, title: "WeRead availability",
            sourceKind: .weread, language: "en", paragraphs: [], sourceURL: url)
        read = ReadAloudViewModel(document: document, audioService: audio,
            ttsService: fixture.service(), historyStore: HistoryStore(directory: root))
        planFixture = ReadAloudHTTPFixture.forRequests { [unowned self] request, _ in
            if request.url?.path == "/api/quickread/compose-block" {
                return .response(Data("{\"section\":{\"id\":\"block-0\",\"text\":\"An explanation of the new chapter.\",\"style\":\"explain\",\"cinematic\":{\"events\":[]}}}".utf8))
            }
            return self.planReply
        }
        explain = ExplainViewModel(document: document, speechGenerator: fixture.service(),
            quickReadService: QuickReadService(session: planFixture.session,
                mobileSessionProvider: WeReadFixtureSessionProvider()))
        bridge = WebReaderBridge()
        let content = WKUserContentController()
        content.add(bridge, name: "castreader")
        content.addUserScript(WKUserScript(source: WeReadWebScripts.readerBridge,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController = content
        web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: configuration)
        bridge.webView = web
        bridge.configure(expectsDynamicWebContent: true, isWeRead: true, readerURL: url)
        bridge.attach(readVM: read, explainVM: explain)
        web.navigationDelegate = bridge
        window = UIWindow(frame: web.frame)
        window.rootViewController = UIViewController()
        window.rootViewController!.view.addSubview(web)
        window.makeKeyAndVisible()
        web.loadHTMLString("""
        <html><meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{font:20px/1.6 -apple-system}.wr_readerContent{min-height:160px}</style>
        <body class="wr_page_reader"><div class="wr_readerContent"><p>\(first)</p></div>
        <button class="renderTarget_pager_button renderTarget_pager_button_right" onclick="document.querySelector('.wr_readerContent p').textContent='\(second)'">下一页</button>
        </body></html>
        """, baseURL: URL(string: url))
        try await wait({ self.read.stagedLiveWebParagraphTexts == [self.first] }, timeout: 20)
    }

    override func tearDown() async throws {
        read?.stop(); explain?.stop(); read?.deactivate(); explain?.deactivate()
        fixture?.close(); fixture = nil; planFixture?.close(); planFixture = nil
        web?.stopLoading(); web?.configuration.userContentController.removeScriptMessageHandler(forName: "castreader")
        web?.removeFromSuperview(); window?.isHidden = true
        bridge = nil; read = nil; explain = nil; web = nil; window = nil
        audio.clearForAccountBoundary()
        AppSettings.shared.autoPlay = oldAutoPlay
        ProManager.shared.debugForcePro = oldPro
        try? FileManager.default.removeItem(at: root)
    }

    private func wait(_ condition: () -> Bool, timeout: Double = 5) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try await Task.sleep(nanoseconds: 30_000_000) }
        guard condition() else {
            XCTFail("WeRead state did not settle")
            throw NSError(domain: "WeReadFixtureTimeout", code: 1)
        }
    }
    private func js(_ script: String) async throws { _ = try await web.evaluateJavaScript("(()=>{" + script + ";return true})()") }
    private func showError() async throws {
        try await js("document.body.innerHTML='<div class=readerError><h2>网络异常</h2><button>重新加载</button></div>'")
    }

    func testIPadViewportReflowRetainsPausedReadAndMarkGeometry() async throws {
        let container = WebReaderContainerView(webView: web, isWeRead: true, isKobo: false,
            initialSurfaceSize: web.bounds.size, loadAction: {})
        window.rootViewController!.view.addSubview(container)
        read.dbgGenerate(0)
        try await wait({ self.audio.isPlaying && self.audio.currentTime > 0.08 }, timeout: 10)
        read.togglePlayPause()
        try await wait({ !self.audio.isPlaying })
        let paragraph = read.currentParagraphIndex
        for (index, size) in [CGSize(width: 820, height: 1000), CGSize(width: 1180, height: 650), CGSize(width: 400, height: 650)].enumerated() {
            window.frame.size = size
            window.rootViewController!.view.frame.size = size
            container.frame = CGRect(origin: .zero, size: size)
            container.layoutIfNeeded()
            bridge.refocusIfNeeded(index + 1, readMode: true)
            try await Task.sleep(for: .milliseconds(1400))
            XCTAssertFalse(audio.isPlaying, "Resizing must preserve explicit pause")
            XCTAssertEqual(read.currentParagraphIndex, paragraph)
            XCTAssertEqual(read.stagedLiveWebParagraphTexts, [first])
            try await js("CR.highlightRange({paragraphIndex:0,charStart:0,charEnd:9});CR.showMark({id:'viewport',paragraphIndex:0,charStart:10,charEnd:22,action:'underline',seed:42})")
            let highlight = try await web.evaluateJavaScript("document.querySelectorAll('[data-cr-weread-highlight]').length")
            let marks = try await web.evaluateJavaScript("document.querySelectorAll('#castreader-weread-marks-svg path').length")
            XCTAssertGreaterThan(highlight as? Int ?? 0, 0)
            XCTAssertGreaterThan(marks as? Int ?? 0, 0)
            let screenshot = UIGraphicsImageRenderer(size: size).image { _ in container.drawHierarchy(in: container.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: screenshot)
            attachment.name = "weread-ipad-\(Int(size.width))x\(Int(size.height))"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testResizeDoesNotCommitTheProvidersIntermediatePartialCanvas() async throws {
        read.dbgGenerate(0)
        try await wait { self.audio.currentSegment != nil }
        read.togglePlayPause()
        try await wait { !self.audio.isPlaying }
        let segment = audio.currentSegment?.id
        let time = audio.currentTime
        // The real reader first paints one of two landscape columns, then
        // publishes both. That partial paint is geometry, not a manual turn.
        try await js("window.dispatchEvent(new Event('resize')); document.querySelector('.wr_readerContent p').textContent='The first visible page';setTimeout(()=>{document.querySelector('.wr_readerContent p').textContent=\"\(first)\"},600)")
        try await Task.sleep(for: .milliseconds(2200))
        XCTAssertEqual(read.stagedLiveWebParagraphTexts, [first])
        XCTAssertEqual(audio.currentSegment?.id, segment)
        XCTAssertEqual(audio.currentTime, time, accuracy: 0.1)
        XCTAssertFalse(audio.isPlaying)
    }

    func testCanvasReflowRetainsAudioMarksAndConsumesNewlyVisibleTail() async throws {
        // A real WK canvas plus a captured chapter layout: only the provider
        // drawing source is controlled. The production extraction, native
        // bridge, AVPlayer and semantic-next transaction remain in use.
        let spoken = "Canvas heading. " + first
        try await js("""
        const host=document.querySelector('.wr_readerContent');
        host.innerHTML='<canvas width="350" height="300" style="width:350px;height:300px"></canvas>';
        const source=document.createElement('div');source.className='preRenderContainer';
        source.style.cssText='position:absolute;left:-10000px;width:350px;height:300px';
        source.innerHTML='<p>\(spoken) \(second)</p>';document.body.append(source);
        const canvas=host.querySelector('canvas');window.testPaint=['\(spoken)'];window.testTurns=0;
        window.__castReaderWeReadCanvas={snapshot(){return{calls:window.testPaint.flatMap((text,row)=>Array.from(text).map((ch,i)=>({canvas,text:ch,x:10+i*5,y:35+row*60,width:5,a:1,d:1,tx:0,ty:0,fontSize:18,fontAscent:14,fontDescent:4}))),draws:[],epoch:1,columnFingerprint:''}}};
        document.querySelector('button').onclick=()=>{window.testTurns++;source.innerHTML='<p>The next physical page is confirmed.</p>';window.testPaint=['The next physical page is confirmed.'];window.dispatchEvent(new CustomEvent('castreader-weread-canvas'))};
        window.dispatchEvent(new CustomEvent('castreader-weread-canvas'));
        """)
        try await wait({ self.read.stagedLiveWebParagraphTexts == [spoken] }, timeout: 8)
        let visibleHeading = try await web.evaluateJavaScript("CastReaderWeRead.isVisibleChapterStart('\(spoken)')")
        let hiddenHeading = try await web.evaluateJavaScript("CastReaderWeRead.isVisibleChapterStart('\(second)')")
        XCTAssertEqual(visibleHeading as? Bool, true)
        XCTAssertEqual(hiddenHeading as? Bool, false)
        read.dbgGenerate(0)
        try await wait { self.audio.currentSegment != nil }
        read.pausePlayback()
        let oldSegment = audio.currentSegment?.id
        let oldTime = audio.currentTime
        // Simulate the observed WebKit ordering: a new viewport/paint is
        // visible to extraction before the bridge receives a resize event.
        try await js("CR.showMark({id:'retained',paragraphIndex:0,charStart:10,charEnd:22,action:'underline',seed:42});window.addEventListener('resize',event=>event.stopImmediatePropagation(),{capture:true,once:true})")
        web.frame.size.width = 500
        try await js("window.testPaint=['\(spoken)','\(second)'];window.dispatchEvent(new CustomEvent('castreader-weread-canvas'))")
        try await Task.sleep(for: .milliseconds(2300))
        XCTAssertEqual(read.stagedLiveWebParagraphTexts, [spoken])
        XCTAssertEqual(audio.currentSegment?.id, oldSegment)
        XCTAssertEqual(audio.currentTime, oldTime, accuracy: 0.1)
        XCTAssertFalse(audio.isPlaying)
        let ink = try await web.evaluateJavaScript("document.querySelectorAll('[data-cr-weread-mark-id=retained] path').length")
        XCTAssertGreaterThan(ink as? Int ?? 0, 0)
        // Finishing the old scope first consumes the newly revealed source,
        // without clicking past that unexplained/unspoken text.
        let continued = try await web.evaluateJavaScript("CastReaderWeRead.nextPage()")
        XCTAssertEqual(continued as? Bool, true)
        try await wait { self.read.stagedLiveWebParagraphTexts == [self.second] }
        let turns = try await web.evaluateJavaScript("window.testTurns")
        XCTAssertEqual(turns as? Int, 0)
        bridge.requestUserPageTurn(.next)
        try await wait { self.read.stagedLiveWebParagraphTexts == ["The next physical page is confirmed."] }
        let physicalTurns = try await web.evaluateJavaScript("window.testTurns")
        XCTAssertEqual(physicalTurns as? Int, 1)
    }

    func testErrorSurfaceStopsDelayedReadAndCannotBeRestartedByControls() async throws {
        read.dbgGenerate(0)
        try await wait { self.audio.isWaitingForNextSegment && self.audio.currentSegment != nil }
        try await showError()
        try await wait { self.read.webContentBlockMessage != nil }
        XCTAssertTrue(read.stagedLiveWebParagraphTexts.isEmpty)
        XCTAssertTrue(explain.stagedLiveWebParagraphTexts.isEmpty)
        read.start(); read.ensurePlaying(); read.jump(to: 0)
        explain.start(); explain.ensurePlaying(); explain.replay()
        try await Task.sleep(nanoseconds: 2_800_000_000)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(audio.hasQueuedSegments)
        XCTAssertFalse(read.isActive)
        XCTAssertFalse(explain.isActive)
    }

    func testSamePageRecoveryDoesNotAutoplayAfterError() async throws {
        read.pausePlayback()
        AppSettings.shared.autoPlay = true
        try await showError()
        try await wait { self.read.webContentBlockMessage != nil }
        try await js("document.body.innerHTML='<div class=wr_readerContent><p>\(first)</p></div>'")
        try await wait { self.read.webContentBlockMessage == nil && self.read.stagedLiveWebParagraphTexts == [self.first] }
        XCTAssertEqual(explain.stagedLiveWebParagraphTexts, [first])
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(read.isActive)
        XCTAssertFalse(explain.isActive)
        read.ensurePlaying()
        try await wait { self.audio.hasAudibleProgress }
    }

    func testHiddenErrorAndErrorWordsInsideProseDoNotBlock() async throws {
        try await js("document.body.insertAdjacentHTML('beforeend','<div class=readerError style=\"display:none\">网络异常 重新加载</div>');document.querySelector('p').textContent='网络异常，重新加载。故事里的人这样说道。'")
        try await wait { self.read.stagedLiveWebParagraphTexts.first?.contains("故事") == true }
        XCTAssertNil(read.webContentBlockMessage)
        try await js("document.querySelector('.readerError').style.display='block'")
        try await wait { self.read.webContentBlockMessage != nil }
    }

    func testTrialWallRetiresBothModesAndKeepsPlayBlocked() async throws {
        read.dbgGenerate(0)
        try await wait { self.audio.isWaitingForNextSegment }
        try await js("document.body.innerHTML='<h2>试读结束</h2><button>登录后获得专属福利</button>'")
        try await wait { self.read.webContentBlockMessage != nil }
        XCTAssertTrue(read.stagedLiveWebParagraphTexts.isEmpty)
        XCTAssertFalse(audio.hasQueuedSegments)
        read.ensurePlaying()
        XCTAssertFalse(audio.isPlaying)
    }

    func testErrorStopsExplanationAndClearsItsCachedNarration() async throws {
        bridge.setActive(readMode: false)
        let segment = AudioSegment(paragraphIndex: 0, segmentIndex: 0,
            audioData: ReadAloudHTTPFixture.wav(duration: 8), timestamps: [], duration: 8,
            text: "An explanation of this visible page.", isWavFormat: true)
        explain.debugSeedCachedNarration([segment], voiceID: AppSettings.shared.voice(for: "en"))
        explain.activate()
        explain.ensurePlaying()
        try await wait { self.audio.hasAudibleProgress }
        try await showError()
        try await wait { self.explain.webContentBlockMessage != nil }
        explain.ensurePlaying(); explain.replay()
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(audio.hasQueuedSegments)
        XCTAssertTrue(explain.activeMarks.isEmpty)
    }

    func testNaturalSegmentGapTurnResumesOnConfirmedNewPage() async throws {
        read.dbgGenerate(0)
        try await wait { self.audio.isWaitingForNextSegment && self.audio.currentSegment != nil }
        bridge.requestUserPageTurn(.next)
        try await wait { self.read.stagedLiveWebParagraphTexts == [self.second] && self.audio.currentSegment?.text == self.second && self.audio.hasAudibleProgress }
        XCTAssertEqual(fixture.requests.filter { $0 == second }.count, 1)
        XCTAssertEqual(explain.stagedLiveWebParagraphTexts, [second], "Switching to Explain must use the newly visible page")
        try await Task.sleep(nanoseconds: 2_800_000_000)
        XCTAssertEqual(audio.currentSegment?.text, second, "Late old tail cannot replace current page")
    }

    func testPausedTurnDoesNotResumeAndCancelledNavigationPreservesBody() async throws {
        read.dbgGenerate(0)
        try await wait { self.audio.isWaitingForNextSegment }
        read.pausePlayback()
        bridge.webView(web, didFailProvisionalNavigation: nil, withError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertNil(read.webContentBlockMessage)
        bridge.requestUserPageTurn(.next)
        try await wait { self.read.stagedLiveWebParagraphTexts == [self.second] }
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(fixture.requests.contains(second))
    }

    func testExplainPageTurnStagesReadAndCannotReplayThePreviousPage() async throws {
        read.dbgGenerate(0)
        try await wait { self.audio.isWaitingForNextSegment }
        read.pausePlayback()
        bridge.setActive(readMode: false)
        bridge.requestUserPageTurn(.next)
        try await wait { self.explain.stagedLiveWebParagraphTexts == [self.second] }
        XCTAssertEqual(read.stagedLiveWebParagraphTexts, [second])
        XCTAssertFalse(audio.isPlaying)
        bridge.setActive(readMode: true)
        read.ensurePlaying()
        try await wait { self.audio.currentSegment?.text == self.second && self.audio.hasAudibleProgress }
    }

    func testShortChapterTailContinuesToConfirmedNextPageAndPlaysExplanation() async throws {
        let next = "The next chapter has enough content to explain, and must be the source of the new narration."
        planReply = .response(Data("""
        event: block0
        data: {"job_id":"fixture-plan","output_language":"en","total_blocks":1,"block_0":{"id":"block-0","text":"An explanation of the new chapter.","style":"explain","cinematic":{"events":[]}}}

        event: done
        data: {"job_id":"fixture-plan","total_blocks":1}

        """.utf8))
        try await js("document.querySelector('p').textContent='A short tail.'; document.querySelector('button').onclick=()=>{document.querySelector('p').textContent='\(next)';document.querySelector('button').remove()}")
        try await wait { self.read.stagedLiveWebParagraphTexts == ["A short tail."] }
        bridge.setActive(readMode: false)
        explain.start()
        try await wait { self.explain.stagedLiveWebParagraphTexts == [next] && self.audio.hasAudibleProgress }
        XCTAssertEqual(audio.currentSegment?.text, "An explanation of the new chapter.")
        XCTAssertEqual(read.stagedLiveWebParagraphTexts, [next])
        let plans = planFixture.capturedRequests.filter { $0.path == "/api/quickread/extract-plan" }
        XCTAssertEqual(plans.count, 1, "The locally short page sends no plan request")
        let body = try XCTUnwrap(plans.first?.body)
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
        XCTAssertFalse(encoded.contains("A short tail."))
        XCTAssertTrue(encoded.contains(next), "Only the confirmed next page may reach explanation")
        XCTAssertEqual(planFixture.capturedRequests.filter { $0.path == "/api/quickread/compose-block" }.count, 1)
    }

    func testServerShortPageDoesNotRetryAndBookEndCompletes() async throws {
        let text = "就要被迫分离。从那天起，我再也不敢仅凭第一眼就轻视任何一个女人。"
        try await js("document.querySelector('p').textContent='\(text)';document.querySelector('button').remove()")
        try await wait { self.read.stagedLiveWebParagraphTexts == [text] }
        bridge.setActive(readMode: false)
        explain.start()
        try await wait { self.explain.status == .completed && !self.explain.isContinuingLivePage }
        XCTAssertEqual(planFixture.requests.count, 1, "Deterministic short-content rejection must not retry")
        XCTAssertFalse(audio.isPlaying)
        XCTAssertEqual(explain.stagedLiveWebParagraphTexts, [text])
    }

    func testUnknown400NeverSkipsPage() async throws {
        planReply = .response(Data("{\"error\":\"unsupported_content\"}".utf8), status: 400)
        let text = "This page has sufficient length but an unknown server rejection must not cause automatic page turning."
        try await js("document.querySelector('p').textContent='\(text)'")
        try await wait { self.read.stagedLiveWebParagraphTexts == [text] }
        bridge.setActive(readMode: false)
        explain.start()
        try await wait { if case .error = self.explain.status { return true }; return false }
        XCTAssertEqual(explain.stagedLiveWebParagraphTexts, [text])
        XCTAssertFalse(explain.isContinuingLivePage)
    }

    func testLateShortPageResponseCannotTurnAfterSwitchingMode() async throws {
        planReply = .response(Data("{\"error\":\"text_too_short\"}".utf8), status: 400, delay: 0.7)
        let text = "This page is long enough for local validation, but the server will reject it after the mode has changed."
        try await js("document.querySelector('p').textContent='\(text)'")
        try await wait { self.read.stagedLiveWebParagraphTexts == [text] }
        bridge.setActive(readMode: false)
        explain.start()
        try await wait { !self.planFixture.requests.isEmpty }
        bridge.setActive(readMode: true)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(read.stagedLiveWebParagraphTexts, [text])
        XCTAssertFalse(explain.isContinuingLivePage)
    }

    func testConsecutiveShortPagesHaveBoundedAutomaticTurns() async throws {
        try await js("window.shortPage=0;document.querySelector('p').textContent='Short page 0.';document.querySelector('button').onclick=()=>{document.querySelector('p').textContent='Short page '+(++window.shortPage)+'.'}")
        try await wait { self.read.stagedLiveWebParagraphTexts == ["Short page 0."] }
        bridge.setActive(readMode: false)
        explain.start()
        try await wait({ if case .error = self.explain.status { return true }; return false }, timeout: 10)
        XCTAssertEqual(explain.stagedLiveWebParagraphTexts, ["Short page 4."])
        XCTAssertTrue(planFixture.requests.isEmpty)
        XCTAssertFalse(explain.isContinuingLivePage)
    }

    func testStandaloneShortArticleDoesNotRequestPageTurn() {
        let document = ReadingDocument(id: UUID().uuidString, title: "Short article", sourceKind: .text,
            language: "en", paragraphs: [ReadingParagraph(id: 0, text: "Short article.")])
        let vm = ExplainViewModel(document: document)
        var turns = 0
        vm.onDocumentFinished = { turns += 1 }
        vm.start()
        if case .error = vm.status {} else { XCTFail("Standalone article should retain short-content guidance") }
        XCTAssertEqual(turns, 0)
        vm.stop(); vm.deactivate()
    }

    func testSSEShortContentContractIsTyped() {
        let error = QuickReadSSEErrorMapper.map(payload: Data("{\"error\":{\"code\":\"text_too_short\"}}".utf8))
        if case .textTooShort = error {} else { XCTFail("Must preserve short-content reason") }
    }

    func testCommittedNavigationFailureStopsButProvisionalFailureKeepsVisibleBody() async throws {
        read.dbgGenerate(0)
        try await wait { self.audio.isWaitingForNextSegment }
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        bridge.webView(web, didFailProvisionalNavigation: nil, withError: error)
        XCTAssertNil(read.webContentBlockMessage)
        XCTAssertEqual(read.stagedLiveWebParagraphTexts, [first])
        bridge.webView(web, didFail: nil, withError: error)
        XCTAssertNotNil(read.webContentBlockMessage)
        XCTAssertTrue(read.stagedLiveWebParagraphTexts.isEmpty)
        XCTAssertFalse(audio.hasQueuedSegments)
        XCTAssertFalse(audio.isPlaying)
    }

    func testFailedTurnTimeoutCannotReviveErrorPageAudio() async throws {
        read.dbgGenerate(0)
        try await wait { self.audio.isWaitingForNextSegment }
        try await js("document.querySelector('button').onclick=()=>{document.body.innerHTML='<div class=readerError>网络异常<button>重试</button></div>'}")
        bridge.requestUserPageTurn(.next)
        try await wait { self.read.webContentBlockMessage != nil }
        try await Task.sleep(nanoseconds: 3_000_000_000)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertTrue(read.stagedLiveWebParagraphTexts.isEmpty)
    }
}

private actor WeReadFixtureSessionProvider: MobileSessionProviding {
    func sessionToken() -> String? { "cms_fixture" }
    func refreshSession() -> String? { "cms_fixture" }
    func invalidateSession() {}
    func rejectSession(_ token: String?) {}
}
