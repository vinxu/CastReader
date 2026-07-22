//
//  WebReaderView.swift
//  CastReader
//
//  WKWebView 阅读容器：加载网页(URL)或本地渲染文件，注入扩展 DOM 高亮/标注 bundle，
//  通过 WebReaderBridge 与 native TTS/VM 双向通信。
//  M0：网址源加载 URL + 注入 bundle + 收 ready。高亮/标注/TTS 驱动在 M1 接入。
//

import Foundation
import SwiftUI
import WebKit

/// WeRead's legacy desktop reader chooses its complete Canvas/CSS palette from
/// browser-local state during boot.  Set that state before navigation rather
/// than repainting individual DOM colors after the Canvas is already rasterized.
enum WeReadNativeTheme {
    static func prepare(_ webView: WKWebView, isDark: Bool, completion: @escaping () -> Void) {
        let properties: [HTTPCookiePropertyKey: Any] = [
            .domain: ".weread.qq.com",
            .path: "/",
            .name: "wr_theme",
            .value: isDark ? "dark" : "white",
            .secure: "TRUE",
            .expires: Date(timeIntervalSinceNow: 31_536_000)
        ]
        guard let cookie = HTTPCookie(properties: properties) else {
            completion()
            return
        }
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) {
            DispatchQueue.main.async(execute: completion)
        }
    }

    static func themedURL(_ url: URL, isDark: Bool) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.removeAll { $0.name.caseInsensitiveCompare("wtheme") == .orderedSame }
        if !isDark { items.append(URLQueryItem(name: "wtheme", value: "white")) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url ?? url
    }

    static func readerURL(_ url: URL, isDark: Bool) -> URL {
        themedURL(url, isDark: isDark)
    }
}

/// ReaderHost resolves the final surface before this view is constructed, so
/// the WKWebView receives its one and only opening viewport in `init` rather
/// than being created at `.zero` and resized after WeRead has paginated.
final class WebReaderContainerView: UIView {
    let webView: WKWebView
    let isWeRead: Bool
    private let loadingCover = UIView()
    private var lastSurfaceSize: CGSize = .zero
    private var lastReportedViewport: (left: Double, right: Double)?
    private var lastAppliedWeReadStyle: UIUserInterfaceStyle

    init(
        webView: WKWebView,
        isWeRead: Bool,
        initialSurfaceSize: CGSize,
        loadAction: @escaping () -> Void
    ) {
        self.webView = webView
        self.isWeRead = isWeRead
        self.lastAppliedWeReadStyle = webView.overrideUserInterfaceStyle
        lastSurfaceSize = initialSurfaceSize
        super.init(frame: CGRect(origin: .zero, size: initialSurfaceSize))
        clipsToBounds = true
        addSubview(webView)
        if isWeRead {
            applyWeReadGeometry(for: initialSurfaceSize)
            backgroundColor = UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1)
                    : UIColor.white
            }
            loadingCover.backgroundColor = backgroundColor
            loadingCover.isUserInteractionEnabled = false
            loadingCover.frame = CGRect(origin: .zero, size: initialSurfaceSize)
        }

        // Navigation starts only after both native frames have their final
        // opening geometry. Dispatching one run-loop turn lets SwiftUI attach
        // the container without exposing any provisional browser viewport.
        DispatchQueue.main.async(execute: loadAction)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        if isWeRead {
            let surfaceChanged = abs(lastSurfaceSize.width - bounds.width) > 2 ||
                abs(lastSurfaceSize.height - bounds.height) > 2
            if surfaceChanged {
                lastSurfaceSize = bounds.size
                applyWeReadGeometry(for: bounds.size)
            }
            if loadingCover.superview != nil { loadingCover.frame = bounds }
        } else {
            webView.frame = bounds
        }
    }

    private func applyWeReadGeometry(for surface: CGSize) {
        guard surface.width > 1, surface.height > 1 else { return }
        let crop = WeReadViewportCrop.predicted(for: surface)

        webView.transform = .identity
        webView.frame = crop.webViewFrame(for: surface)
        ReaderRunLog.write(
            "WEREAD viewport geometry surface=\(Int(surface.width))x\(Int(surface.height)) " +
            "layoutScale=\(String(format: "%.2f", Double(crop.widthScale)))"
        )
    }

    func calibrateWeRead(contentLeftRatio: Double, contentRightRatio: Double) {
        guard isWeRead, bounds.width > 80, bounds.height > 80 else { return }
        if let prior = lastReportedViewport,
           abs(prior.left - contentLeftRatio) < 0.005,
           abs(prior.right - contentRightRatio) < 0.005 {
            return
        }
        lastReportedViewport = (contentLeftRatio, contentRightRatio)
        let left = String(format: "%.3f", contentLeftRatio)
        let right = String(format: "%.3f", contentRightRatio)
        ReaderRunLog.write(
            "WEREAD viewport report left=\(left) right=\(right) native=\(Int(bounds.width))x\(Int(bounds.height))"
        )
    }

    func showWeReadLoadingCover() {
        guard isWeRead else { return }
        loadingCover.backgroundColor = backgroundColor
        if loadingCover.superview == nil { addSubview(loadingCover) }
        loadingCover.frame = bounds
        bringSubviewToFront(loadingCover)
    }

    func finishWeReadSurfaceTransition() {
        guard isWeRead else { return }
        // Never gate visibility on an optional DOM measurement. Navigation and
        // Canvas stability can complete without a viewport report (for example
        // a title/cover page), and the old two-signal gate could stay white.
        UIView.performWithoutAnimation {
            loadingCover.removeFromSuperview()
        }
    }

    func syncWeReadSystemTheme(isDark: Bool, beforeReload: @escaping () -> Void) {
        guard isWeRead else { return }
        let style: UIUserInterfaceStyle = isDark ? .dark : .light
        // ExplainViewModel publishes frequently while LLM/TTS is preparing.
        // Dedupe against our own applied state rather than a UIKit property
        // which may be transiently republished during scene/material updates.
        guard lastAppliedWeReadStyle != style else { return }
        lastAppliedWeReadStyle = style
        webView.overrideUserInterfaceStyle = style
        showWeReadLoadingCover()
        beforeReload()
        WeReadNativeTheme.prepare(webView, isDark: isDark) { [weak webView] in
            guard let webView, let currentURL = webView.url else { return }
            webView.load(URLRequest(url: WeReadNativeTheme.readerURL(currentURL, isDark: isDark)))
        }
    }
}

struct WebReaderView: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    let document: ReadingDocument
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    let mode: ReaderMode
    let refocusToken: Int
    let initialSurfaceSize: CGSize

    func makeCoordinator() -> WebReaderBridge { WebReaderBridge() }

    func makeUIView(context: Context) -> WebReaderContainerView {
        let controller = WKUserContentController()
        if document.sourceKind == .weread {
            controller.add(context.coordinator, contentWorld: .page, name: WebReaderBridge.handlerName)
        } else {
            controller.add(context.coordinator, name: WebReaderBridge.handlerName)
        }

        // WeRead has a Canvas renderer, so it gets its dedicated document-start
        // bridge.  Normal sites continue to use the generic DOM-zone bundle.
        if document.sourceKind == .weread {
            controller.addUserScript(WKUserScript(
                source: WeReadWebScripts.canvasIntercept,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
            controller.addUserScript(WKUserScript(
                source: WeReadWebScripts.readerBridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
        } else if let js = Self.loadBundleJS() {
            controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true
        if document.sourceKind == .weread {
            config.websiteDataStore = .default()
            // Desktop identity and viewport sizing are separate concerns.
            // The custom desktop UA below keeps WeRead on its web reader, while
            // mobile content mode makes its existing `width=device-width` meta
            // viewport equal the already-final native surface. Forcing desktop
            // content mode gives WKWebView an approximately 980pt CSS viewport
            // and then shrinks it into 430pt, which both makes the book tiny and
            // breaks Canvas-to-DOM geometry matching used by TTS extraction.
            config.defaultWebpagePreferences.preferredContentMode = .mobile
        }

        let isWeRead = document.sourceKind == .weread
        let initialWebViewFrame = isWeRead
            ? WeReadViewportCrop.predicted(for: initialSurfaceSize).webViewFrame(for: initialSurfaceSize)
            : CGRect(origin: .zero, size: initialSurfaceSize)
        let webView = WKWebView(frame: initialWebViewFrame, configuration: config)
        if document.sourceKind == .weread {
            webView.customUserAgent = WeReadWebScripts.desktopUserAgent
            webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light
            let compact = initialSurfaceSize.width <= WeReadViewportCrop.compactReaderBreakpoint ? "Y" : "N"
            let openingCrop = WeReadViewportCrop.predicted(for: initialSurfaceSize)
            ReaderRunLog.write(
                "WEREAD viewport create frame=\(Int(openingCrop.offsetX)),0,\(Int(initialSurfaceSize.width * openingCrop.widthScale)),\(Int(initialSurfaceSize.height)) cssCompact=\(compact) pagePadding=\(Int(WeReadViewportCrop.compactPageHorizontalPadding))"
            )
        }
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .clear
        webView.isOpaque = false
        context.coordinator.webView = webView
        webView.navigationDelegate = context.coordinator
        context.coordinator.configure(expectsDynamicWebContent: document.sourceKind == .web, isWeRead: document.sourceKind == .weread)
        context.coordinator.attach(readVM: readVM, explainVM: explainVM)

        let isDarkMode = colorScheme == .dark
        let loadAction = {
            // 网址源：直接加载网页（保留原排版）。
            if (document.sourceKind == .web || document.sourceKind == .weread),
               let urlStr = document.sourceURL,
               let url = URL(string: urlStr) {
                if document.sourceKind == .weread {
                    WeReadNativeTheme.prepare(webView, isDark: isDarkMode) {
                        let themedURL = WeReadNativeTheme.readerURL(url, isDark: isDarkMode)
                        webView.load(URLRequest(url: themedURL))
                    }
                } else {
                    webView.load(URLRequest(url: url))
                }
            } else if document.sourceKind == .docx || document.sourceKind == .epub {
                // 本地 DOCX/EPUB：先载空白页（注入 bundle），ready 后 bridge 把字节交给 mammoth/epub.js 在 WebView 内渲染。
                let b64 = document.fileData?.base64EncodedString()
                if document.sourceKind == .docx { context.coordinator.pendingDocxBase64 = b64 }
                else { context.coordinator.pendingEpubBase64 = b64 }
                webView.loadHTMLString(
                    "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body style=\"margin:0;display:flex;align-items:center;justify-content:center;height:100vh;background:transparent\"><div style=\"width:30px;height:30px;border:3px solid rgba(150,150,150,.25);border-top-color:#999;border-radius:50%;animation:crspin .8s linear infinite\"></div><style>@keyframes crspin{to{transform:rotate(360deg)}}</style></body></html>",
                    baseURL: URL(string: "https://castreader.local/local"))
            }
        }
        let container = WebReaderContainerView(
            webView: webView,
            isWeRead: isWeRead,
            initialSurfaceSize: initialSurfaceSize,
            loadAction: loadAction
        )
        context.coordinator.onWeReadViewport = { [weak container] left, right in
            container?.calibrateWeRead(contentLeftRatio: left, contentRightRatio: right)
        }
        context.coordinator.onWeReadNeedsLoadingCover = { [weak container] in
            container?.showWeReadLoadingCover()
        }
        context.coordinator.onWeReadSurfaceStable = { [weak container] in
            container?.finishWeReadSurfaceTransition()
        }
        return container
    }

    func updateUIView(_ container: WebReaderContainerView, context: Context) {
        let isApplicationActive = scenePhase == .active
        context.coordinator.applicationActivityChanged(isActive: isApplicationActive)

        // SwiftUI can transiently republish a different colorScheme while the
        // scene is resigning active. Treating that inactive snapshot as a real
        // theme change used to start a WeRead refresh, whose first step stops
        // native TTS. WebKit is suspended in the background, so the refresh
        // could not finish and playback appeared to stop for no visible reason.
        // A genuine system-theme change is applied when the scene becomes
        // active again, before the user can interact with the reader.
        if isApplicationActive {
            container.syncWeReadSystemTheme(isDark: colorScheme == .dark) {
                context.coordinator.prepareWeReadReload(reason: "theme")
            }
        }
        context.coordinator.setActive(readMode: mode == .read)
        context.coordinator.refocusIfNeeded(refocusToken, readMode: mode == .read)
    }

    /// 读取 app bundle 内 WebAssets/bundle.js 作为注入脚本源。
    static func loadBundleJS() -> String? {
        let url = Bundle.main.url(forResource: "bundle", withExtension: "js", subdirectory: "WebAssets")
            ?? Bundle.main.url(forResource: "bundle", withExtension: "js")
        guard let url = url, let js = try? String(contentsOf: url, encoding: .utf8) else {
            print("[WebReader] ⚠️ WebAssets/bundle.js not found in app bundle")
            return nil
        }
        return js
    }
}
