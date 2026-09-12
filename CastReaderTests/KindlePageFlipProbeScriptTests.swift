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
