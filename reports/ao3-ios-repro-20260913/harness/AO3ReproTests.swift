import XCTest
import WebKit
import UIKit

@MainActor
final class Probe: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var events: [[String: Any]] = []
    var errors: [String] = []
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let value = message.body as? [String: Any], value["type"] as? String == "rendered" else { return }
        let rows = (value["payload"] as? [String: Any])?["paragraphs"] as? [[String: Any]] ?? []
        let texts = rows.compactMap { $0["text"] as? String }
        events.append(["uptime": ProcessInfo.processInfo.systemUptime, "count": rows.count,
                       "characters": texts.reduce(0) { $0 + $1.count }, "first": String((texts.first ?? "").prefix(160)),
                       "containsTerms": texts.joined().contains("Terms of Service")])
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { errors.append(error.localizedDescription) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { errors.append(error.localizedDescription) }
}

@MainActor
final class AO3ReproTests: XCTestCase {
    let pages = [("86539701", "228985126"), ("86539701", "231697481"), ("85592371", "227434811")]
    var output: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("AO3Evidence") }
    let statsJS = """
    (()=>{
      const rows=window.__crLastRendered||[];
      const chapter=document.querySelector('#chapters .userstuff[role="article"]');
      const chosen=Array.from(document.querySelectorAll('[data-cr-para]'));
      const terms=document.querySelector('#tos_prompt');
      const outer=document.querySelector('#outer');
      return {title:document.title,url:location.href,method:window.__crExtractMethod||null,
        rendered:rows.length,characters:rows.reduce((n,p)=>n+p.text.length,0),
        first:rows.slice(0,3).map(p=>p.text.slice(0,160)),
        chapterParagraphs:chapter?Array.from(chapter.querySelectorAll('p')).filter(e=>e.textContent.trim()).length:0,
        chapterCharacters:chapter?chapter.textContent.trim().length:0,
        selectedInChapter:chapter?chosen.filter(e=>chapter.contains(e)).length:0,
        selectedInTerms:terms?chosen.filter(e=>terms.contains(e)).length:0,
        termsPresent:!!terms,termsDisplay:terms?getComputedStyle(terms).display:null,
        outerVisibility:outer?getComputedStyle(outer).visibility:null,
        outerAriaHidden:outer?outer.getAttribute('aria-hidden'):null,
        qualifiesForNativeCommit:rows.length>=3&&rows.reduce((n,p)=>n+p.text.length,0)>=200,
        zones:window.__castreaderLastExtraction||null};
    })()
    """
    func setupWeb() throws -> (WKWebView, UIWindow, Probe) {
        let probe = Probe()
        let controller = WKUserContentController()
        controller.add(probe, name: "castreader")
        let js = try String(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: "release-bundle", withExtension: "js")))
        controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()
        config.allowsInlineMediaPlayback = true
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: config)
        view.navigationDelegate = probe
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        window.rootViewController = UIViewController()
        window.isHidden = false
        window.rootViewController!.view.addSubview(view)
        return (view, window, probe)
    }
    func waitRendered(_ probe: Probe, limit: Int = 60) async {
        for _ in 0..<limit {
            if !probe.events.isEmpty || !probe.errors.isEmpty { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    func capture(_ web: WKWebView, _ name: String, _ probe: Probe) async throws -> [String: Any] {
        var data = try await web.evaluateJavaScript(statsJS) as! [String: Any]
        data["events"] = probe.events
        data["navigationErrors"] = probe.errors
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(name + ".json"))
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(x: 0, y: 0, width: 390, height: 800)
        if let png = try? await web.takeSnapshot(configuration: config).pngData() {
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
        let compact = data.filter { $0.key != "zones" && $0.key != "events" }
        print("AO3_EVIDENCE \(name) \(String(data: try JSONSerialization.data(withJSONObject: compact, options: .sortedKeys), encoding: .utf8)!)")
        return data
    }
    func testOfflineThreeChaptersBlockedAndClear() async throws {
        for (work, chapter) in pages {
            for state in ["blocked", "clear"] {
                let (web, window, probe) = try setupWeb()
                let html = try String(contentsOf: XCTUnwrap(Bundle(for: Self.self).url(forResource: chapter + "-" + state, withExtension: "html")))
                web.loadHTMLString(html, baseURL: URL(string: "https://archiveofourown.org/works/\(work)/chapters/\(chapter)"))
                await waitRendered(probe)
                let data = try await capture(web, chapter + "-offline-" + state, probe)
                XCTAssertGreaterThan(data["chapterParagraphs"] as? Int ?? 0, 20)
                if state == "blocked" {
                    XCTAssertEqual(data["selectedInChapter"] as? Int, 0)
                    XCTAssertGreaterThan(data["selectedInTerms"] as? Int ?? 0, 0)
                    XCTAssertEqual(data["qualifiesForNativeCommit"] as? Bool, true)
                    // Local static HTML only. No AO3 scripts, agreement action, cookies or network.
                    _ = try await web.evaluateJavaScript("document.querySelector('#tos_prompt').remove();document.querySelector('#outer').removeAttribute('style');document.querySelector('#outer').removeAttribute('aria-hidden');")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let revealed = try await capture(web, chapter + "-offline-revealed-without-reextract", probe)
                    XCTAssertEqual(revealed["selectedInChapter"] as? Int, 0)
                    XCTAssertEqual(probe.events.count, 1)
                    _ = try await web.evaluateJavaScript("window.CR.extract()")
                    let extracted = try await capture(web, chapter + "-offline-explicit-reextract", probe)
                    XCTAssertGreaterThan(extracted["selectedInChapter"] as? Int ?? 0, 20)
                } else {
                    XCTAssertGreaterThan(data["selectedInChapter"] as? Int ?? 0, 20)
                    XCTAssertEqual(data["selectedInTerms"] as? Int, 0)
                }
                web.removeFromSuperview()
                window.isHidden = true
            }
        }
    }
    func testLiveThreeChapterFirstExtraction() async throws {
        for (work, chapter) in pages {
            let (web, window, probe) = try setupWeb()
            let suffix = chapter == "228985126" ? "" : "#workskin"
            web.load(URLRequest(url: URL(string: "https://archiveofourown.org/works/\(work)/chapters/\(chapter)\(suffix)")!))
            await waitRendered(probe, limit: 160)
            _ = try await capture(web, chapter + "-live-first", probe)
            try await Task.sleep(nanoseconds: 4_000_000_000)
            _ = try await capture(web, chapter + "-live-settled", probe)
            // Read-only diagnostic extraction. Does not accept the AO3 agreement.
            _ = try? await web.evaluateJavaScript("window.CR.extract()")
            _ = try await capture(web, chapter + "-live-explicit-reextract", probe)
            web.removeFromSuperview()
            window.isHidden = true
        }
    }
}
