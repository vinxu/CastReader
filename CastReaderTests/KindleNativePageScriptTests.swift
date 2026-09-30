import XCTest
import WebKit
@testable import CastReader

/// Actual shipped bootstrap in WebKit; run on the connected device. These local
/// renderer fixtures complement, rather than replace, live Amazon acceptance.
@MainActor
final class KindleNativePageScriptTests: XCTestCase {
    private var window: UIWindow!
    private var web: WKWebView!

    override func setUp() {
        super.setUp()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame: window.bounds, configuration: config)
        controller.view.addSubview(web)
    }

    override func tearDown() {
        web.stopLoading()
        web.removeFromSuperview()
        window.isHidden = true
        web = nil
        window = nil
        super.tearDown()
    }

    private func load() async throws {
        let token = UUID().uuidString
        web.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0}#kr-renderer{width:390px;height:650px}canvas,img{width:390px;height:650px;display:block}</style>
        <button id="kr-chevron-right">Next</button><div id="kr-renderer"></div>
        <script>
        window.fixtureToken='\(token)'; window.moves=[]; window.fixturePageIndex=0;
        window.makePage=function(color){
          const el=document.createElement('div'), surface=document.createElement('canvas');
          surface.width=780;surface.height=1300;const ctx=surface.getContext('2d');
          ctx.fillStyle=color;ctx.fillRect(0,0,780,1300);ctx.fillStyle='black';ctx.fillText('Fixture words.',30,60);
          el.appendChild(surface);
          const index=fixturePageIndex++;
          return {page:{startPositionId:1+index*20,endPositionId:20+index*20,pageIndex:index},renderResult:{pageElement:el}};
        };
        window.a=makePage('white');window.b=makePage('yellow');window.c=makePage('blue');
        document.getElementById('kr-renderer').appendChild(a.renderResult.pageElement);
        window.nav={currentIndex:10,currentView:{renderedPage:a},
          options:{rendererController:{renderingProcessId:'layout-a',cache:new Map([[12,Promise.resolve(c)],[10,Promise.resolve(a)]])}},
          move(direction){moves.push(direction);return Promise.resolve();}};
        nav.options.rendererController.cache.set(11,new Promise(resolve=>window.resolveNext=resolve));
        document.getElementById('kr-chevron-right').__reactFiber$fixture={memoizedState:{memoizedState:{current:{client:{navigationService:nav}}}}};
        window.__crKindleNativeOrderEnabled=true;window.__crKindleNativeBook='NATIVE-FIXTURE';
        window.mount=function(page){document.getElementById('kr-renderer').replaceChildren(page.renderResult.pageElement);nav.currentView.renderedPage=page;};
        </script>
        """, baseURL: URL(string: "https://fixture.invalid"))
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("window.fixtureToken==='\(token)'")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        _ = try await web.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap)
        _ = try await web.evaluateJavaScript("window.__crKindleNativePages.refresh(true);true")
        for _ in 0..<50 {
            if let state = try? await json("window.__crKindleState()"), !(state["key"] as? String ?? "").isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native renderer fixture did not become ready")
    }

    private func json(_ code: String) async throws -> [String: Any] {
        let result = try await web.evaluateJavaScript(code)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(result as? String).utf8)) as? [String: Any])
    }

    private func resolveNext() async throws {
        _ = try await web.evaluateJavaScript("resolveNext(b);true")
        for _ in 0..<50 {
            let state = try await json("JSON.stringify(__crKindleNativePages.state())")
            if !(state["nextId"] as? String ?? "").isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Next cache slot did not resolve")
    }

    private func stageOverlay(_ ticket: String = "prepared") async throws -> [String: Any] {
        _ = try await json("__crKindleSetPageModeLocked(true)")
        let overlay = try await json("""
        __crKindleLiveSetPage({key:JSON.parse(__crKindleState()).key,
          sessionId:__crKindleProbe.liveSessionId,imagePixelWidth:780,imagePixelHeight:1300,
          paragraphs:[{id:0,text:'Fixture words.',words:[{text:'Fixture',bbox:[0.1,0.8,0.2,0.05]}]}]})
        """)
        XCTAssertEqual(overlay["ok"] as? Bool, true)
        let staged = try await json("__crKindleLiveStagePage('\(ticket)')")
        XCTAssertEqual(staged["ok"] as? Bool, true)
        return overlay
    }

    private func takeStagedOverlay(_ ticket: String = "prepared") async throws -> [String: Any] {
        try await json("__crKindleLiveTakeStagedPage('\(ticket)',__crKindleProbe.liveKey,__crKindleProbe.liveSessionId)")
    }

    func testPreparedOverlayRequiresExactReceiptAndCanOnlyBeConsumedOnce() async throws {
        try await load()
        let overlay = try await stageOverlay()
        let stale = try await takeStagedOverlay("stale")
        XCTAssertEqual(stale["ok"] as? Bool, false)
        let valid = try await takeStagedOverlay()
        XCTAssertEqual(valid["ok"] as? Bool, true)
        XCTAssertEqual(valid["key"] as? String, overlay["key"] as? String)
        let duplicate = try await takeStagedOverlay()
        XCTAssertEqual(duplicate["ok"] as? Bool, false)
        let moves = try await web.evaluateJavaScript("moves.length") as? Int
        XCTAssertEqual(moves, 0, "Presentation adoption must never dispatch another native Next")
    }

    func testPreparedOverlayRejectsPageLayoutAnchorAndSessionChanges() async throws {
        for mutation in [
            "a.renderResult.pageElement.style.transform='translateY(4px)'",
            "__crKindleProbe.liveParagraphs=[{id:0,text:'Different source'}]",
            "__crKindleProbe.liveSessionId+=1",
            "__crKindleSetPageModeLocked(false)",
            "__crKindleProbe.liveOverlay.remove()",
            "nav.currentIndex=11;mount(b);__crKindleNativePages.refresh(true)",
            "nav.options.rendererController.renderingProcessId='changed-layout';__crKindleNativePages.refresh(true)",
            "__crKindleLiveClear()"
        ] {
            try await load()
            try await resolveNext()
            _ = try await stageOverlay()
            _ = try await web.evaluateJavaScript(mutation + ";true")
            let result = try await takeStagedOverlay()
            XCTAssertEqual(result["ok"] as? Bool, false, mutation)
        }
    }

    func testReinstallingSamePageInvalidatesPreviousOverlayReceipt() async throws {
        try await load()
        _ = try await stageOverlay("old")
        _ = try await stageOverlay("new")
        let old = try await takeStagedOverlay("old")
        XCTAssertEqual(old["ok"] as? Bool, false)
        let new = try await takeStagedOverlay("new")
        XCTAssertEqual(new["ok"] as? Bool, true)
    }

    func testModeSwitchRestoresPresentedPageBeforeReplacingSource() async throws {
        try await withModeSwitchModel { model in
            let original = try await self.json("__crKindleState()")
            let key = try XCTUnwrap(original["key"] as? String)
            _ = try await self.web.evaluateJavaScript("nav.currentIndex=11;mount(b);__crKindleNativePages.refresh(true);true")
            let session = try await model.restorePresentedPageForModeSwitch(key, hadHiddenAdvance: true)
            // A restored raster retains its native page ID but capture sessions
            // change. Exercise the actual overlay installer with the new lease.
            let overlay = try await self.json("""
            __crKindleLiveSetPage({key:\(String(data: try JSONEncoder().encode(key), encoding: .utf8)!),
              sessionId:\(session),imagePixelWidth:780,imagePixelHeight:1300,
              paragraphs:[{id:0,text:'Fixture words.',words:[{text:'Fixture',bbox:[0.1,0.8,0.2,0.05]}]}]})
            """)
            XCTAssertEqual(overlay["ok"] as? Bool, true, "Recovered source must also accept its overlay")
            let state = try await self.json("__crKindleState()")
            XCTAssertEqual(state["key"] as? String, key)
            let moves = try await self.web.evaluateJavaScript("moves") as? [String]
            XCTAssertEqual(moves, ["PreviousPage"], "Exactly undo our speculative forward action")
            try await model.restorePresentedPageForModeSwitch(key, hadHiddenAdvance: false)
            let finalMoves = try await self.web.evaluateJavaScript("moves") as? [String]
            XCTAssertEqual(finalMoves, moves, "Already confirmed pages must not navigate again")
        }
    }

    func testModeSwitchRejectsUnrelatedPageWithoutNavigating() async throws {
        try await withModeSwitchModel { model in
            let original = try await self.json("__crKindleState()")
            let key = try XCTUnwrap(original["key"] as? String)
            _ = try await self.web.evaluateJavaScript("nav.currentIndex=11;mount(b);__crKindleNativePages.refresh(true);true")
            do {
                try await model.restorePresentedPageForModeSwitch(key, hadHiddenAdvance: false)
                XCTFail("A different visible source must not accept old OCR")
            } catch is CancellationError { XCTFail("Expected a source mismatch, not cancellation") }
              catch { /* expected source mismatch */ }
            let moves = try await self.web.evaluateJavaScript("moves") as? [String]
            XCTAssertEqual(moves, [])
        }
    }

    private func withModeSwitchModel(_ body: (KindleBookViewModel) async throws -> Void) async throws {
        let book = KindleBook(id: "mode-page-" + UUID().uuidString, asin: "B000000001",
            title: "Mode source fixture", author: "", coverURL: nil,
            readerURL: "https://read.amazon.com/?asin=B000000001", progressLabel: "",
            storefrontID: "us", lastOpenedAt: nil, lastSyncedAt: Date(), lastReadPageKey: nil, lastReadURL: nil)
        let model = KindleBookViewModel(book: book, websiteDataStore: .nonPersistent())
        web.removeFromSuperview()
        web = model.webView
        web.navigationDelegate = nil
        web.frame = window.bounds
        window.rootViewController!.view.addSubview(web)
        model.setReaderSurfaceAttached(true)
        defer { model.destroy() }
        try await load()
        try await resolveNext()
        _ = try await web.evaluateJavaScript("""
        nav.move=function(direction){
          moves.push(direction);
          this.currentIndex += direction==='PreviousPage' ? -1 : 1;
          mount(this.currentIndex===10 ? a : this.currentIndex===11 ? b : c);
          __crKindleNativePages.refresh(true);
          return Promise.resolve();
        }; true
        """)
        try await body(model)
    }

    func testPrefetchUsesExactNativeNeighborAndKeepsCurrentOverlayOwner() async throws {
        try await load()
        let initial = try await json("__crKindleCurrentPageSnapshot(2048,1)")
        XCTAssertEqual(initial["ok"] as? Bool, true)
        let missing = try await json("__crKindleNextPageSnapshot(__crKindleState && JSON.parse(__crKindleState()).key,2048,1)")
        XCTAssertEqual(missing["ok"] as? Bool, false, "A ready +2 cannot replace a pending +1")
        try await resolveNext()
        let next = try await json("__crKindleNextPageSnapshot(JSON.parse(__crKindleState()).key,2048,1)")
        XCTAssertEqual(next["ok"] as? Bool, true)
        XCTAssertEqual(next["nativeIndex"] as? Int, 11)
        XCTAssertNotEqual(next["image"] as? String, initial["image"] as? String)
        let state = try await json("__crKindleState()")
        XCTAssertEqual(state["key"] as? String, initial["key"] as? String)
        XCTAssertEqual(state["liveKey"] as? String, initial["key"] as? String)
        XCTAssertEqual(state["kind"] as? String, "native-page")
        let moves = try await web.evaluateJavaScript("moves.length") as? Int
        XCTAssertEqual(moves, 0)
    }

    func testTurnNeedsMountedPageObjectAndDeduplicatesRequest() async throws {
        try await load()
        try await resolveNext()
        let turn = try await json("__crKindleSemanticPageTurn('next','ltr',__crKindleNativePages.state().currentId,'one')")
        XCTAssertEqual(turn["strategy"] as? String, "native-cache-navigation")
        _ = try await web.evaluateJavaScript("__crKindleSemanticPageTurn('next','ltr','','one');true")
        let moves = try await web.evaluateJavaScript("moves.length") as? Int
        XCTAssertEqual(moves, 1)
        _ = try await web.evaluateJavaScript("nav.currentIndex=11;true")
        var state = try await json("__crKindleState()")
        XCTAssertEqual(state["key"] as? String, "", "Index alone cannot confirm a mount")
        _ = try await web.evaluateJavaScript("nav.currentView.renderedPage=b;true")
        state = try await json("__crKindleState()")
        XCTAssertEqual(state["key"] as? String, "", "Detached cache page cannot confirm a mount")
        _ = try await web.evaluateJavaScript("mount(b);true")
        state = try await json("__crKindleState()")
        XCTAssertEqual(state["key"] as? String, turn["expectedTargetKey"] as? String)
        let previous = try await json("__crKindleSemanticPageTurn('previous','rtl',__crKindleNativePages.state().currentId,'two')")
        XCTAssertEqual(previous["targetIndex"] as? Int, 10, "Semantic previous is independent of physical reading direction")
    }

    func testDuplicateNativeSourceRangeDoesNotPrefetchOrDispatchAnotherPage() async throws {
        try await load()
        try await resolveNext()
        _ = try await web.evaluateJavaScript("a.page.startPositionId=100;a.page.endPositionId=200;b.page.startPositionId=100;b.page.endPositionId=200;true")
        let next = try await json("__crKindleNextPageSnapshot(JSON.parse(__crKindleState()).key,2048,1)")
        XCTAssertEqual(next["ok"] as? Bool, false, "A second cache slot containing the same source cannot generate another narration")
        let turn = try await json("__crKindleSemanticPageTurn('next','ltr',__crKindleNativePages.state().currentId,'duplicate')")
        XCTAssertEqual(turn["ok"] as? Bool, false)
        XCTAssertEqual(turn["dispatchCount"] as? Int, 0)
        XCTAssertEqual(turn["reason"] as? String, "native-source-unchanged")
        let moves = try await web.evaluateJavaScript("moves.length") as? Int
        XCTAssertEqual(moves, 0)
    }

    func testIdenticalPixelsWithDifferentNativeSourcePositionsStillAdvance() async throws {
        try await load()
        try await resolveNext()
        _ = try await web.evaluateJavaScript("a.page.startPositionId=100;a.page.endPositionId=200;b.page.startPositionId=200;b.page.endPositionId=300;b.renderResult.pageElement.firstChild.getContext('2d').drawImage(a.renderResult.pageElement.firstChild,0,0);true")
        let turn = try await json("__crKindleSemanticPageTurn('next','ltr',__crKindleNativePages.state().currentId,'distinct-source')")
        XCTAssertEqual(turn["ok"] as? Bool, true)
        _ = try await web.evaluateJavaScript("nav.currentIndex=11;mount(b);true")
        let result = try await json("JSON.stringify({key:__crKindleNativePages.confirmed(__crKindleNativePages.id(10),1)})")
        XCTAssertEqual(result["key"] as? String, turn["expectedTargetKey"] as? String)
    }

    func testLateNativeDuplicateCannotConfirmByIndexAlone() async throws {
        try await load()
        _ = try await web.evaluateJavaScript("a.page.startPositionId=100;a.page.endPositionId=200;b.page.startPositionId=100;b.page.endPositionId=200;true")
        let turn = try await json("__crKindleSemanticPageTurn('next','ltr',__crKindleNativePages.state().currentId,'late-duplicate')")
        XCTAssertEqual(turn["ok"] as? Bool, true, "Pending source cannot be classified in advance")
        try await resolveNext()
        _ = try await web.evaluateJavaScript("nav.currentIndex=11;mount(b);true")
        let result = try await json("JSON.stringify({key:__crKindleNativePages.confirmed(__crKindleNativePages.id(10),1)})")
        XCTAssertEqual(result["key"] as? String, "")
    }

    func testReplacementAndReflowInvalidateInFlightCaptureIdentity() async throws {
        try await load()
        try await resolveNext()
        _ = try await web.evaluateJavaScript("window.oldID=__crKindleNativePages.state().nextId;nav.options.rendererController.cache.set(11,Promise.resolve(c));__crKindleNativePages.refresh(true);true")
        let result = try await json("JSON.stringify({valid:__crKindleNativePages.valid(oldID,false)})")
        XCTAssertEqual(result["valid"] as? Bool, false)
        let stale = try await json("__crKindlePrefetchSnapshotForKey(oldID,2048,1)")
        XCTAssertEqual(stale["ok"] as? Bool, false)
        _ = try await web.evaluateJavaScript("window.currentID=__crKindleNativePages.state().currentId;nav.options.rendererController.renderingProcessId='new-layout';__crKindleNativePages.refresh(true);true")
        let reflow = try await json("JSON.stringify({valid:__crKindleNativePages.valid(currentID,false)})")
        XCTAssertEqual(reflow["valid"] as? Bool, false)
    }

    func testDecodedImageSurvivesRevokedBlobURL() async throws {
        try await load()
        _ = try await web.callAsyncJavaScript("""
        const canvas=b.renderResult.pageElement.firstElementChild;
        const blob=await new Promise(resolve=>canvas.toBlob(resolve));
        const url=URL.createObjectURL(blob), image=new Image();
        await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=reject;image.src=url;});
        URL.revokeObjectURL(url);b.renderResult.pageElement.replaceChildren(image);
        resolveNext(b);return true;
        """, arguments: [:], in: nil, contentWorld: .page)
        let next = try await json("__crKindleNextPageSnapshot(JSON.parse(__crKindleState()).key,2048,1)")
        XCTAssertEqual(next["ok"] as? Bool, true)
        XCTAssertTrue((next["image"] as? String ?? "").hasPrefix("data:image/png;base64,"))
    }
}
