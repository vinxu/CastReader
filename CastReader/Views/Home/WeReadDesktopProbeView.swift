#if DEBUG

import SwiftUI
import WebKit

/// Temporary device-only probe for validating that WeRead accepts a desktop-mode WKWebView.
/// It intentionally does not extract content or connect to CastReader playback yet.
struct WeReadDesktopProbeView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var state = WeReadDesktopProbeState()
    @State private var reloadToken = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusBanner
                WeReadDesktopWebView(state: state, reloadToken: reloadToken)
                    .ignoresSafeArea(edges: .bottom)
            }
            .background(Color(UIColor.systemBackground))
            .navigationTitle("微信读书登录测试")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        state.goBackToken += 1
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(!state.canGoBack)

                    Button {
                        reloadToken += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var statusBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if state.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state.desktopModeDetected ? "checkmark.circle.fill" : "desktopcomputer")
                        .foregroundStyle(state.desktopModeDetected ? Color.green : AppTheme.primary)
                }
                Text(state.statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(AppTheme.foreground)
                Spacer()
                Text("Cookie 持久化")
                    .font(.caption2)
                    .foregroundColor(AppTheme.mutedForeground)
            }

            Text("验证：出现登录入口 → 扫码登录 → 进入书架 → 打开一本书。若二维码在本机，可截图后用微信从相册识别。")
                .font(.caption2)
                .foregroundColor(AppTheme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(AppTheme.surfaceVariant)
    }
}

@MainActor
private final class WeReadDesktopProbeState: ObservableObject {
    @Published var statusText = "正在以电脑端模式加载…"
    @Published var isLoading = true
    @Published var desktopModeDetected = false
    @Published var canGoBack = false
    @Published var goBackToken = 0
}

private struct WeReadDesktopWebView: UIViewRepresentable {
    @ObservedObject var state: WeReadDesktopProbeState
    let reloadToken: Int

    private static let startURL = URL(string: "https://weread.qq.com/")!
    private static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    func makeCoordinator() -> Coordinator {
        Coordinator(state: state)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = CommercialWebSession.websiteDataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences.preferredContentMode = .desktop

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.desktopUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView
        context.coordinator.lastReloadToken = reloadToken
        context.coordinator.lastGoBackToken = state.goBackToken
        webView.load(URLRequest(url: Self.startURL, cachePolicy: .reloadRevalidatingCacheData))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        if context.coordinator.lastReloadToken != reloadToken {
            context.coordinator.lastReloadToken = reloadToken
            webView.reload()
        }
        if context.coordinator.lastGoBackToken != state.goBackToken {
            context.coordinator.lastGoBackToken = state.goBackToken
            if webView.canGoBack { webView.goBack() }
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        weak var webView: WKWebView?
        let state: WeReadDesktopProbeState
        var lastReloadToken = 0
        var lastGoBackToken = 0

        init(state: WeReadDesktopProbeState) {
            self.state = state
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            state.isLoading = true
            state.statusText = "正在以电脑端模式加载…"
            refreshNavigationState(webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            state.isLoading = false
            refreshNavigationState(webView)
            inspectDesktopMode(in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            show(error: error, webView: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            show(error: error, webView: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.targetFrame == nil,
               ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }

            let scheme = url.scheme?.lowercased() ?? ""
            let allowedSchemes = ["http", "https", "about", "data", "blob"]
            if allowedSchemes.contains(scheme) {
                decisionHandler(.allow)
            } else {
                state.statusText = "已拦截跳转 App，继续保留在网页版"
                decisionHandler(.cancel)
            }
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let requestURL = navigationAction.request.url {
                webView.load(URLRequest(url: requestURL))
            }
            return nil
        }

        private func inspectDesktopMode(in webView: WKWebView) {
            let script = """
            (() => JSON.stringify({
              ua: navigator.userAgent || '',
              width: window.innerWidth || 0,
              mobileClass: document.documentElement.classList.contains('wr_mobile') || document.body?.classList.contains('wr_mobile') || false,
              loginHints: document.querySelectorAll('.login_qrcode_container, [class*=login], iframe[src*=login], iframe[src*=connect]').length
            }))()
            """
            webView.evaluateJavaScript(script) { [weak self] result, _ in
                guard let self else { return }
                guard let raw = result as? String,
                      let data = raw.data(using: .utf8),
                      let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    self.state.statusText = "网页已加载，请检查是否出现登录入口"
                    return
                }
                let ua = payload["ua"] as? String ?? ""
                let mobileClass = payload["mobileClass"] as? Bool ?? true
                let loginHints = payload["loginHints"] as? Int ?? 0
                let desktop = ua.contains("Macintosh") && !mobileClass
                self.state.desktopModeDetected = desktop
                if desktop && loginHints > 0 {
                    self.state.statusText = "电脑端模式已生效，页面包含登录入口"
                } else if desktop {
                    self.state.statusText = "电脑端模式已生效，请在页面内寻找登录"
                } else {
                    self.state.statusText = "页面仍识别为移动端，请截图反馈"
                }
                NSLog("CRDBG WeRead probe desktop=%@ loginHints=%d ua=%@", desktop.description, loginHints, ua)
            }
        }

        private func refreshNavigationState(_ webView: WKWebView) {
            state.canGoBack = webView.canGoBack
        }

        private func show(error: Error, webView: WKWebView) {
            state.isLoading = false
            state.statusText = "加载失败：\(error.localizedDescription)"
            refreshNavigationState(webView)
        }
    }
}

#endif
