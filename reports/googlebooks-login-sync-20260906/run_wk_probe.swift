import AppKit
import WebKit
import Foundation
import Darwin

/// Standalone macOS WebKit runner. No simulator, app login, persistent browser
/// profile, cookies, or live Google library participates in this experiment.
@MainActor
final class ShelfProbe: NSObject, WKNavigationDelegate {
    let view: WKWebView
    let script: String
    let fixtureHTML: String
    let label: String
    let outputPath: String?

    init(scriptPath: String, fixturePath: String, label: String, outputPath: String?) throws {
        script = try String(contentsOfFile: scriptPath, encoding: .utf8)
        fixtureHTML = try String(contentsOfFile: fixturePath, encoding: .utf8)
        self.label = label
        self.outputPath = outputPath
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        view = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700), configuration: configuration)
        super.init()
        view.navigationDelegate = self
    }

    func begin() {
        // The base URL establishes the production URL context. All content is
        // supplied by loadHTMLString; the fixture has no remote resources.
        view.loadHTMLString(fixtureHTML, baseURL: URL(string: "https://play.google.com/books")!)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            do {
                var ids = Set<String>()
                var completed = false
                var samples = 0
                for _ in 0..<180 {
                    guard let raw = try await view.evaluateJavaScript(script) as? [String: Any] else {
                        throw NSError(domain: "SyntheticShelfProbe", code: 1)
                    }
                    samples += 1
                    if raw["hasPendingWork"] as? Bool != true {
                        for item in raw["books"] as? [[String: Any]] ?? [] {
                            if let url = item["readerURL"] as? String { ids.insert(url) }
                        }
                    }
                    if raw["isCompleteSnapshot"] as? Bool == true { completed = true; break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                try writeResult([
                    "variant": label,
                    "unique_books_collected": ids.count,
                    "samples": samples,
                    "reported_complete": completed,
                    "complete_library_collected": ids.count == 100,
                    "engine": "macOS WKWebView",
                    "website_data_store": "nonPersistent",
                    "synthetic_fixture_only": true,
                ])
                exit(completed ? 0 : 2)
            } catch {
                let failure = error as NSError
                try? writeResult(["variant": label, "error_domain": failure.domain, "error_code": failure.code])
                exit(1)
            }
        }
    }

    private func writeResult(_ result: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        if let outputPath { try data.write(to: URL(fileURLWithPath: outputPath), options: .atomic) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

guard CommandLine.arguments.count >= 4 else {
    print("Usage: xcrun swift run_wk_probe.swift SCRIPT FIXTURE LABEL [RESULT_JSON]")
    exit(64)
}
let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
let probe = try MainActor.assumeIsolated {
    try ShelfProbe(
        scriptPath: CommandLine.arguments[1], fixturePath: CommandLine.arguments[2],
        label: CommandLine.arguments[3], outputPath: CommandLine.arguments.count > 4 ? CommandLine.arguments[4] : nil
    )
}
MainActor.assumeIsolated { probe.begin() }
DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("Synthetic WK probe timed out"); exit(3) }
application.run()
