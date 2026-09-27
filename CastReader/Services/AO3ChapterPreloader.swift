import Foundation
import WebKit

/// One adjacent chapter, rendered by WebKit in the same account-scoped browser
/// profile. Never accepts notices, fetches whole works, or persists fiction.
@MainActor
final class AO3ChapterPreloader: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private final class Relay: NSObject, WKScriptMessageHandler {
        weak var owner: AO3ChapterPreloader?
        init(_ owner: AO3ChapterPreloader) { self.owner = owner }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            owner?.userContentController(controller, didReceive: message)
        }
    }
    struct Page {
        let url: String
        let signature: String
        let account: String?
        let paragraphs: [String]
    }
    private let makeWebView: (WKWebViewConfiguration) -> WKWebView
    init(makeWebView: @escaping (WKWebViewConfiguration) -> WKWebView = {
        WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800), configuration: $0)
    }) { self.makeWebView = makeWebView; super.init() }
    private var webView: WKWebView?
    private var completion: ((Page?) -> Void)?
    private var timeout: Task<Void, Never>?
    private var expectedURL: String?

    func load(_ url: URL, store: WKWebsiteDataStore, completion: @escaping (Page?) -> Void) {
        cancel()
        self.completion = completion; expectedURL = AO3PageUpdate.pageKey(url.absoluteString)
        guard let script = WebReaderView.loadBundleJS(readerURL: url.absoluteString) else { finish(nil); return }
        let controller = WKUserContentController()
        controller.add(Relay(self), name: "castreader")
        controller.addUserScript(WKUserScript(source: script, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store; config.userContentController = controller
        let web = makeWebView(config)
        web.navigationDelegate = self; webView = web
        web.load(URLRequest(url: url))
        timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            if !Task.isCancelled { self?.finish(nil) }
        }
    }
    func cancel() {
        timeout?.cancel(); timeout = nil
        webView?.stopLoading()
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "castreader")
        webView?.navigationDelegate = nil; webView = nil; completion = nil; expectedURL = nil
    }
    private func finish(_ page: Page?) {
        let callback = completion; cancel(); callback?(page)
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let msg = WebInboundMessage(message.body), msg.type == "rendered",
              let update = AO3PageUpdate(msg.payload, currentURL: webView?.url?.absoluteString),
              update.pageKey == expectedURL else { return }
        guard update.state == .ready else { finish(nil); return }
        let paragraphs = (msg.payload["paragraphs"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        guard !paragraphs.isEmpty, paragraphs.count <= 5_000,
              paragraphs.reduce(0, { $0 + $1.utf16.count }) <= 300_000 else { finish(nil); return }
        finish(Page(url: update.pageKey, signature: update.signature, account: msg.payload["account"] as? String, paragraphs: paragraphs))
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard action.targetFrame?.isMainFrame != false else { decisionHandler(.allow); return }
        decisionHandler(AO3PageUpdate.pageKey(action.request.url?.absoluteString) == expectedURL ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(nil) }
}
