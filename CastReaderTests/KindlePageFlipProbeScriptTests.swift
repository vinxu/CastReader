import XCTest
import WebKit
@testable import CastReader

@MainActor
final class KindlePageFlipProbeScriptTests: XCTestCase {
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

    private func load(host: String = "read.amazon.com") async throws {
        let token = UUID().uuidString
        web.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>body{margin:0}#page-flip{display:grid;grid-template-columns:1fr 1fr;width:380px;height:440px}
        .cell{width:180px;height:200px}canvas{width:170px;height:190px}</style>
        <section id="page-flip" role="grid" aria-setsize="4">
        \((1...4).map { "<div class='cell' aria-posinset='\($0)' aria-setsize='4'><canvas width='1000' height='1400'></canvas></div>" }.joined())
        </section><p id="private-content">PRIVATE_BOOK_TEXT_9A6C</p>
        <script>
        window.fixtureToken='\(token)'; window.key='private-key-8f31'; window.nav=1; window.clicks=0;
        window.__crKindleState=()=>({key:window.key,navigationSeq:window.nav});
        document.addEventListener('click',()=>window.clicks++);
        window.originalFetch=window.fetch;window.originalXHR=XMLHttpRequest.prototype.open;
        window.originalBlob=URL.createObjectURL;
        </script>
        """, baseURL: URL(string: "https://\(host)"))
        for _ in 0..<100 {
            if !web.isLoading, (try? await web.evaluateJavaScript("window.fixtureToken==='\(token)'")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "PageFlipFixture", code: 1)
    }

    private func installOfflineImageFixture() async throws {
        try await load()
        _ = try await web.evaluateJavaScript(KindleOfflineSourceScript.bootstrap)
        _ = try await web.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap)
        _ = try await web.callAsyncJavaScript("""
          document.body.innerHTML='<div id="kr-renderer"><img id="fixture-image" style="width:330px;height:450px"></div>';
          window.fixtureSource={asin:'B000000001',revision:'fixture',layout:{width:390,height:700},
            metadata:{minimum:0,maximum:100,cover:0},start:3,end:19,current:3,page:{start:3,end:19,words:10},loading:false};
          window.__crOfflineSourceRead=()=>JSON.stringify(window.fixtureSource);
          window.__crOfflineSourceRecover=()=>false;
          window.setFixtureImage=async color=>{
            const canvas=document.createElement('canvas');canvas.width=40;canvas.height=60;
            const ctx=canvas.getContext('2d');ctx.fillStyle=color;ctx.fillRect(0,0,40,60);
            const blob=await new Promise(resolve=>canvas.toBlob(resolve));
            const img=document.getElementById('fixture-image');
            await new Promise((resolve,reject)=>{img.onload=resolve;img.onerror=reject;img.src=URL.createObjectURL(blob);});
          };
          await window.setFixtureImage('red');
          await new Promise(resolve=>setTimeout(resolve,50));
          return true;
        """, arguments: [:], in: nil, contentWorld: .page)
    }

    func testOfflineEventWaitUsesRealWebKitAndCapturesTheConfirmedImage() async throws {
        try await installOfflineImageFixture()
        let output = try await web.callAsyncJavaScript("""
          const oldIdentity=window.__crKindleOfflineImageIdentity();
          window.fixtureSource={...window.fixtureSource,start:20,end:39,current:20,page:{start:20,end:39,words:10},loading:true};
          const pending=window.__crOfflineWaitForImage(21,oldIdentity,'native-bridge-fixture');
          setTimeout(async()=>{await window.setFixtureImage('blue');window.fixtureSource.loading=false;},30);
          const ready=JSON.parse(await pending);
          const image=JSON.parse(await window.__crKindleOfflineImage());
          window.__crKindleOfflineResetCandidates();
          return JSON.stringify({ready,image,oldIdentity});
        """, arguments: [:], in: nil, contentWorld: .page)
        let value = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output as? String).utf8)) as! [String: Any]
        let ready = try XCTUnwrap(value["ready"] as? [String: Any])
        let image = try XCTUnwrap(value["image"] as? [String: Any])
        let source = try XCTUnwrap(image["source"] as? [String: Any])
        XCTAssertEqual(ready["status"] as? String, "ready")
        XCTAssertEqual(source["start"] as? Int, 20)
        XCTAssertNotEqual(image["identity"] as? String, value["oldIdentity"] as? String)
        XCTAssertEqual(image["identity"] as? String, (ready["source"] as? [String: Any])?["imageIdentity"] as? String)
        XCTAssertTrue((image["image"] as? String)?.hasPrefix("data:image/png;base64,") == true)
    }

    func testOfflineWebKitCancellationDoesNotCancelTheNextRequest() async throws {
        try await installOfflineImageFixture()
        let output = try await web.callAsyncJavaScript("""
          window.fixtureSource.loading=true;
          const pending=window.__crOfflineWaitForImage(4,'old','cancel-fixture');
          setTimeout(()=>window.__crOfflineCancelWait('cancel-fixture'),20);
          const cancelled=JSON.parse(await pending);
          window.fixtureSource.loading=false;
          const next=window.__crOfflineWaitForImage(4,'old','next-fixture');
          window.__crOfflineCancelWait('cancel-fixture');
          const ready=JSON.parse(await next);
          window.__crKindleOfflineResetCandidates();
          return JSON.stringify({cancelled:cancelled.status,next:ready.status});
        """, arguments: [:], in: nil, contentWorld: .page)
        let value = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(output as? String).utf8)) as! [String: String]
        XCTAssertEqual(value["cancelled"], "cancelled")
        XCTAssertEqual(value["next"], "ready")
    }

    private func response(_ command: String) async throws -> KindlePageFlipProbe.PollResponse {
        let value = try await web.evaluateJavaScript(command)
        let text = try XCTUnwrap(value as? String)
        XCTAssertFalse(text.contains("PRIVATE_BOOK_TEXT_9A6C"))
        XCTAssertFalse(text.contains("private-key-8f31"))
        return try JSONDecoder().decode(KindlePageFlipProbe.PollResponse.self, from: Data(text.utf8))
    }

    func testManualProbeHasNoClicksOrScrollsAndRestoresItsHooks() async throws {
        try await load()
        _ = try await web.evaluateJavaScript(KindleWebScripts.pageFlipProbeBootstrap)
        let idle = try await web.evaluateJavaScript("window.fetch===originalFetch && URL.createObjectURL===originalBlob")
        XCTAssertEqual(idle as? Bool, true)
        let initial = try await response("__crKindlePFProbeStart('local-probe-1234')")
        XCTAssertTrue(initial.ok)
        let active = try await response("__crKindlePFProbePoll('local-probe-1234',0,100)")
        XCTAssertEqual(active.snapshot?.summary.ordinalCount, 4)
        XCTAssertTrue(active.snapshot?.summary.pageFlipConfirmed == true)
        XCTAssertEqual(active.snapshot?.reader.positionStable, true)
        // A canvas has pixels but no reusable source URL. Enumeration alone
        // must not authorize the direct-image download route.
        XCTAssertEqual(KindlePageFlipProbe.evaluate(active), .enumerable)
        XCTAssertEqual(active.snapshot?.summary.directImageCount, 0)
        let noActions = try await web.evaluateJavaScript("window.clicks===0 && window.nav===1 && scrollY===0 && document.getElementById('page-flip').scrollTop===0")
        XCTAssertEqual(noActions as? Bool, true)
        let stopped = try await response("__crKindlePFProbeStop('local-probe-1234')")
        XCTAssertFalse(stopped.active)
        let restored = try await web.evaluateJavaScript("window.fetch===originalFetch && XMLHttpRequest.prototype.open===originalXHR && URL.createObjectURL===originalBlob")
        XCTAssertEqual(restored as? Bool, true)
    }

    func testRingOverflowIsVisibleAndPositionChangeFailsClosed() async throws {
        try await load()
        _ = try await web.evaluateJavaScript(KindleWebScripts.pageFlipProbeBootstrap)
        _ = try await response("__crKindlePFProbeStart('local-probe-1234')")
        _ = try await web.evaluateJavaScript("for(let i=0;i<1600;i++){let u=URL.createObjectURL(new Blob(['fixture'],{type:'image/png'}));URL.revokeObjectURL(u)};window.key='changed-page';window.nav=2;")
        let active = try await response("__crKindlePFProbePoll('local-probe-1234',0,100)")
        XCTAssertTrue(active.overflowed(afterSeq: 0))
        XCTAssertLessThanOrEqual(active.events.count, 100)
        XCTAssertTrue(active.hasMore)
        XCTAssertEqual(KindlePageFlipProbe.evaluate(active), .positionUnsafe)
        _ = try await response("__crKindlePFProbeStop('local-probe-1234')")
    }

    func testProbeDoesNotInstallOnUnknownOrigin() async throws {
        try await load(host: "fixture.invalid")
        _ = try await web.evaluateJavaScript(KindleWebScripts.pageFlipProbeBootstrap)
        let untouched = try await web.evaluateJavaScript("typeof window.__crKindlePFProbeStart==='undefined' && window.fetch===originalFetch")
        XCTAssertEqual(untouched as? Bool, true)
    }
}
