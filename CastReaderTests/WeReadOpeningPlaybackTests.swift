import XCTest
import WebKit
@testable import CastReader

@MainActor
final class WeReadOpeningPlaybackTests: XCTestCase {
    func testCoverAdvancesOnceAndWaitsForCommittedBody() async {
        var probes = 0, turns = 0
        let ready = await WeReadOpeningPlayback.prepare(maximumProbes: 12, delayNanoseconds: 1,
            probe: { probes += 1; return probes < 8 ? .cover("cover") : .ready },
            advance: { _ in turns += 1; return true }, allowed: { true })
        XCTAssertTrue(ready)
        XCTAssertEqual(turns, 1)
    }

    func testNoChangeTimesOutWithoutClickingTwice() async {
        var turns = 0
        let ready = await WeReadOpeningPlayback.prepare(maximumProbes: 12, delayNanoseconds: 1,
            probe: { .cover("same") }, advance: { _ in turns += 1; return true }, allowed: { true })
        XCTAssertFalse(ready)
        XCTAssertEqual(turns, 1)
    }

    func testSlowBodyAndPaywallAreNeverSkipped() async {
        for state in [WeReadOpeningPlayback.Page.waiting, .unavailable, .ready] {
            var turns = 0
            let result = await WeReadOpeningPlayback.prepare(maximumProbes: 8, delayNanoseconds: 1,
                probe: { state }, advance: { _ in turns += 1; return true }, allowed: { true })
            XCTAssertEqual(result, state == .ready)
            XCTAssertEqual(turns, 0)
        }
    }

    func testChangedCoversAreBoundedToFourTurns() async {
        var page = 0
        let result = await WeReadOpeningPlayback.prepare(maximumProbes: 30, delayNanoseconds: 1,
            probe: { .cover("page-\(page)") }, advance: { _ in page += 1; return true }, allowed: { true })
        XCTAssertFalse(result)
        XCTAssertEqual(page, 4)
    }

    func testSleepExpiryOrOwnershipChangeWhileProbingCannotClickOrResume() async {
        var allowed = true, turns = 0
        let result = await WeReadOpeningPlayback.prepare(delayNanoseconds: 1,
            probe: { allowed = false; return .ready },
            advance: { _ in turns += 1; return true }, allowed: { allowed })
        XCTAssertFalse(result)
        XCTAssertEqual(turns, 0)
    }

    func testCancellationOwnsLateProbe() async {
        var turns = 0
        let task = Task { @MainActor in
            await WeReadOpeningPlayback.prepare(delayNanoseconds: 1,
                probe: { try? await Task.sleep(nanoseconds: 30_000_000); return .ready },
                advance: { _ in turns += 1; return true }, allowed: { true })
        }
        task.cancel()
        let result = await task.value
        XCTAssertFalse(result)
        XCTAssertEqual(turns, 0)
    }

    func testViewModelPauseCancelsPendingCoverPreparation() async throws {
        let audio = AudioPlayerService.shared
        audio.clearForAccountBoundary()
        defer { audio.clearForAccountBoundary() }
        let doc = ReadingDocument(id: UUID().uuidString, title: "茶花女", sourceKind: .weread,
            language: "zh", paragraphs: [])
        let vm = ReadAloudViewModel(document: doc)
        defer { vm.stop() }
        var requests = 0
        vm.prepareReadableWebPage = {
            requests += 1
            try? await Task.sleep(nanoseconds: 50_000_000)
            return true
        }
        vm.togglePlayPause()
        XCTAssertTrue(vm.isPreparingReadablePage)
        XCTAssertTrue(vm.isWaitingForPlayableAudio)
        await Task.yield()
        vm.start()
        vm.pausePlayback()
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(requests, 1)
        XCTAssertFalse(vm.isPreparingReadablePage)
        XCTAssertTrue(vm.isPlaybackPausedByUser)
        XCTAssertFalse(audio.isPlaying)
        XCTAssertFalse(audio.hasQueuedSegments)
    }

    func testProductionBridgeCoverToBodyUsesNativeNextAndDetectsChinese() async throws {
        let (view, window) = try await fixture()
        defer { window.isHidden = true }
        let initial = try await state(view)
        XCTAssertEqual(initial["kind"] as? String, "cover")
        let identity = try XCTUnwrap(initial["identity"] as? String)
        let wrong = try await view.evaluateJavaScript("CastReaderWeRead.advanceOpeningPage('stale')")
        XCTAssertEqual(wrong as? Bool, false)
        let advanced = try await view.evaluateJavaScript("CastReaderWeRead.advanceOpeningPage('\(identity)')")
        XCTAssertEqual(advanced as? Bool, true)
        for _ in 0..<50 {
            if try await state(view)["kind"] as? String == "reading" { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let body = try await state(view)
        XCTAssertEqual(body["kind"] as? String, "reading")
        let taps = try await view.evaluateJavaScript("window.nextTaps")
        XCTAssertEqual(taps as? Int, 1)
        let text = try await view.evaluateJavaScript("document.querySelector('.wr_readerContent').textContent")
        XCTAssertEqual(ReadingLanguagePolicy.confidentLanguage(for: text as? String ?? ""), "zh")
    }

    func testHiddenCoverOnSlowBodyPageAndOpenAaCannotAdvance() async throws {
        let (view, window) = try await fixture()
        defer { window.isHidden = true }
        _ = try await view.evaluateJavaScript("document.querySelector('.horizontalReaderCoverPage').style.display='none';document.querySelector('.renderTarget_pager_button_left').style.display='block'")
        let slow = try await state(view)
        XCTAssertEqual(slow["kind"] as? String, "waiting")
        _ = try await view.evaluateJavaScript("document.querySelector('.renderTarget_pager_button_left').style.display='none';window.__crWeReadAppearance={}")
        let panel = try await state(view)
        XCTAssertEqual(panel["kind"] as? String, "waiting")
    }

    func testCanvasCoverWithHiddenSourceAndNoPreviousIsRecognized() async throws {
        let (view, window) = try await fixture()
        defer { window.isHidden = true }
        _ = try await view.evaluateJavaScript("document.querySelector('.horizontalReaderCoverPage').style.display='none'")
        let cover = try await state(view)
        XCTAssertEqual(cover["kind"] as? String, "cover")
        _ = try await view.evaluateJavaScript("document.querySelector('.renderTarget_pager_button_right').disabled=true")
        let unavailable = try await state(view)
        XCTAssertEqual(unavailable["kind"] as? String, "unavailable")
    }

    func testHiddenDuplicateNextIsNotClickedAndHiddenPanelDoesNotBlock() async throws {
        let (view, window) = try await fixture()
        defer { window.isHidden = true }
        _ = try await view.evaluateJavaScript("""
        const hidden=document.createElement('div');hidden.style.opacity='0';
        hidden.innerHTML='<div class="font-panel-content" style="width:300px;height:200px"></div><button class="renderTarget_pager_button renderTarget_pager_button_right" onclick="window.wrongNext=true">下一页</button>';
        document.body.prepend(hidden);
        """)
        let cover = try await state(view)
        XCTAssertEqual(cover["kind"] as? String, "cover")
        let identity = try XCTUnwrap(cover["identity"] as? String)
        _ = try await view.evaluateJavaScript("CastReaderWeRead.advanceOpeningPage('\(identity)')")
        let wrong = try await view.evaluateJavaScript("window.wrongNext === true")
        let taps = try await view.evaluateJavaScript("window.nextTaps")
        XCTAssertEqual(wrong as? Bool, false)
        XCTAssertEqual(taps as? Int, 1)
    }

    func testVisibleFlyleafIntroWithPreviousIsSkippedButHiddenIntroIsNot() async throws {
        let (view, window) = try await fixture()
        defer { window.isHidden = true }
        _ = try await view.evaluateJavaScript("""
        document.querySelector('.horizontalReaderCoverPage').style.display='none';
        document.querySelector('.renderTarget_pager_button_left').style.display='block';
        const wrapper=document.createElement('div');wrapper.id='flyleaf';
        wrapper.innerHTML='<div class="wr_flyleaf_page wr_flyleaf_page_bookInfo" style="display:none">封面</div><div class="wr_flyleaf_page wr_flyleaf_page_bookIntro" style="width:300px;height:400px">这只是封面信息的第二页，并非正文章节。</div>';
        document.body.prepend(wrapper);
        """)
        let intro = try await state(view)
        XCTAssertEqual(intro["kind"] as? String, "cover")
        XCTAssertEqual(intro["reason"] as? String, "visible-flyleaf")
        _ = try await view.evaluateJavaScript("document.getElementById('flyleaf').style.display='none'")
        let chapterLoading = try await state(view)
        XCTAssertEqual(chapterLoading["kind"] as? String, "waiting")
    }

    private func state(_ view: WKWebView) async throws -> [String: Any] {
        let result = try await view.evaluateJavaScript("CastReaderWeRead.openingPageState()")
        return try XCTUnwrap(result as? [String: Any])
    }

    private func fixture() async throws -> (WKWebView, UIWindow) {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        let window = UIWindow(frame: view.frame)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(view)
        window.makeKeyAndVisible()
        view.loadHTMLString("""
        <html><meta name="viewport" content="width=device-width"><body class="wr_page_reader">
        <div class="horizontalReaderCoverPage" style="width:300px;height:400px">茶花女 微信读书推荐值</div>
        <button class="renderTarget_pager_button renderTarget_pager_button_left" style="display:none">上一页</button>
        <button class="renderTarget_pager_button renderTarget_pager_button_right" onclick="window.nextTaps++;document.querySelector('.horizontalReaderCoverPage').remove();const p=document.createElement('div');p.className='wr_readerContent';p.innerHTML='<p>版权信息 书名：茶花女 作者：小仲马 译者：钟仪 出版时间：2026年 品牌方：上海铭书文化传播有限公司</p>';document.body.appendChild(p)">下一页</button>
        <script>window.nextTaps=0</script></body></html>
        """, baseURL: URL(string: "https://weread.qq.com/web/reader/fixture"))
        for _ in 0..<80 {
            if (try? await view.evaluateJavaScript("window.nextTaps === 0")) as? Bool == true { break }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        _ = try await view.evaluateJavaScript(WeReadWebScripts.readerBridge)
        return (view, window)
    }
}
