import XCTest
import WebKit
@testable import CastReader

@MainActor
final class KindleReadingSettingsScriptTests: XCTestCase {
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

    private func load(_ controls: String, setup: String = "") async throws {
        web.loadHTMLString("""
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <button id="aa" aria-label="Reading settings" onclick="panel.hidden=!panel.hidden">Aa</button>
        <section id="panel" hidden>\(controls)</section>
        <script>window.fixtureReady=true; window.commits=[]; \(setup)</script>
        """, baseURL: URL(string: "https://fixture.invalid"))
        for _ in 0..<100 {
            if (try? await web.evaluateJavaScript("window.fixtureReady===true")) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTFail("Local WKWebView fixture did not load")
    }

    private func json(_ js: String) async throws -> [String: Any] {
        let value = try await web.evaluateJavaScript(js)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(value as? String).utf8)) as? [String: Any])
    }

    func testLiveNativeRangeWinsOverStaleStorageAndCommitsOneStep() async throws {
        try await load("<input id='font' aria-label='Font size' type='range' min='1' max='10' step='1' value='6'>", setup: "localStorage.setItem('fontSize','5'); font.addEventListener('change',()=>commits.push(font.value));")
        let opening = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(opening["reason"] as? String, "opening-settings")
        let initial = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(initial["value"] as? Int, 6)
        let changed = try await json(KindleReadingSettingsScript.change(by: 1))
        XCTAssertEqual(changed["value"] as? Int, 7)
        let commits = try await web.evaluateJavaScript("commits") as? [String]
        XCTAssertEqual(commits, ["7"])
        _ = try await json(KindleReadingSettingsScript.close)
        _ = try await json(KindleReadingSettingsScript.read)
        let reopened = try await json(KindleReadingSettingsScript.read)
        XCTAssertEqual(reopened["value"] as? Int, 7)
        let observed1 = try await web.evaluateJavaScript("localStorage.getItem('fontSize')") as? String
        XCTAssertEqual(observed1, "5")
    }

    func testFractionalStepClampsAtBoundsAndDoesNotRedispatchNoOp() async throws {
        try await load("<input id='font' aria-label='Font size' type='range' min='0.5' max='1.5' step='0.5' value='1'>", setup: "font.addEventListener('change',()=>commits.push(font.value));")
        _ = try await json(KindleReadingSettingsScript.read)
        _ = try await json(KindleReadingSettingsScript.change(by: 1))
        _ = try await json(KindleReadingSettingsScript.change(by: 1))
        let observed2 = try await web.evaluateJavaScript("commits") as? [String]
        XCTAssertEqual(observed2, ["1.5"])
    }

    func testIonicRangeReceivesInputAndPersistenceChangeEvents() async throws {
        try await load("<ion-range id='font' aria-label='Font size' min='1' max='10' step='1' style='display:block;width:200px;height:40px'></ion-range>", setup: "font.value=6; font.addEventListener('ionChange',e=>commits.push(e.detail.value));")
        _ = try await json(KindleReadingSettingsScript.read)
        let changed = try await json(KindleReadingSettingsScript.change(by: -1))
        XCTAssertEqual(changed["value"] as? Int, 5)
        let observed3 = try await web.evaluateJavaScript("commits") as? [Int]
        XCTAssertEqual(observed3, [5])
    }

    func testUnlabelledAmbiguousRangesAreNotChanged() async throws {
        try await load("<input id='a' type='range'><input id='b' type='range'>", setup: "a.addEventListener('change',()=>commits.push('a')); b.addEventListener('change',()=>commits.push('b'));")
        _ = try await json(KindleReadingSettingsScript.read)
        let result = try await json(KindleReadingSettingsScript.change(by: 1))
        XCTAssertEqual(result["ok"] as? Bool, false)
        let observed4 = try await web.evaluateJavaScript("commits.length") as? Int
        XCTAssertEqual(observed4, 0)
    }

    func testSingleNonFontRangeIsNeverMistakenForFontSize() async throws {
        try await load("<input id='font' aria-label='Reading progress' type='range' value='50'>")
        _ = try await json(KindleReadingSettingsScript.read)
        let result = try await json(KindleReadingSettingsScript.change(by: -1))
        let actual = try await web.evaluateJavaScript("font.value") as? String
        XCTAssertEqual(result["ok"] as? Bool, false)
        XCTAssertEqual(actual, "50")
    }

    func testDefaultNativeRangeBoundsRetainOneStepSemantics() async throws {
        try await load("<input id='font' aria-label='Font size' type='range' value='50'>")
        _ = try await json(KindleReadingSettingsScript.read)
        let result = try await json(KindleReadingSettingsScript.change(by: -1))
        XCTAssertEqual(result["value"] as? Int, 49)
        XCTAssertEqual(result["max"] as? Int, 100)
    }

    func testCloseCannotReopenAnAlreadyClosedAmazonPanel() async throws {
        try await load("<input aria-label='Font size' type='range' min='1' max='10' value='6'>")
        _ = try await json(KindleReadingSettingsScript.read)
        _ = try await web.evaluateJavaScript("panel.hidden=true")
        let result = try await json(KindleReadingSettingsScript.close)
        let hidden = try await web.evaluateJavaScript("panel.hidden") as? Bool
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(hidden, true)
    }
}
