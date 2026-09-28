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
        window.fixtureToken='\(token)'; window.moves=[];
        window.makePage=function(color){
          const el=document.createElement('div'), surface=document.createElement('canvas');
          surface.width=780;surface.height=1300;const ctx=surface.getContext('2d');
          ctx.fillStyle=color;ctx.fillRect(0,0,780,1300);ctx.fillStyle='black';ctx.fillText('Fixture words.',30,60);
          el.appendChild(surface);
          return {page:{startPositionId:1,endPositionId:20,pageIndex:0},renderResult:{pageElement:el}};
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
