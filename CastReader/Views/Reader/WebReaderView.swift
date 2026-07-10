//
//  WebReaderView.swift
//  CastReader
//
//  WKWebView 阅读容器：加载网页(URL)或本地渲染文件，注入扩展 DOM 高亮/标注 bundle，
//  通过 WebReaderBridge 与 native TTS/VM 双向通信。
//  M0：网址源加载 URL + 注入 bundle + 收 ready。高亮/标注/TTS 驱动在 M1 接入。
//

import SwiftUI
import WebKit

struct WebReaderView: UIViewRepresentable {
    let document: ReadingDocument
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    let mode: ReaderMode
    let refocusToken: Int

    func makeCoordinator() -> WebReaderBridge { WebReaderBridge() }

    func makeUIView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: WebReaderBridge.handlerName)

        // 注入扩展高亮/标注 bundle（documentEnd）——任意加载的页面都获得 window.CR + HighlightSync。
        if let js = Self.loadBundleJS() {
            controller.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        }

        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.allowsInlineMediaPlayback = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .clear
        webView.isOpaque = false
        context.coordinator.webView = webView
        context.coordinator.attach(readVM: readVM, explainVM: explainVM)

        // 网址源：直接加载网页（保留原排版）。
        if document.sourceKind == .web,
           let urlStr = document.sourceURL,
           let url = URL(string: urlStr) {
            webView.load(URLRequest(url: url))
        } else if document.sourceKind == .docx || document.sourceKind == .epub {
            // 本地 DOCX/EPUB：先载空白页（注入 bundle），ready 后 bridge 把字节交给 mammoth/epub.js 在 WebView 内渲染。
            let b64 = document.fileData?.base64EncodedString()
            if document.sourceKind == .docx { context.coordinator.pendingDocxBase64 = b64 }
            else { context.coordinator.pendingEpubBase64 = b64 }
            webView.loadHTMLString(
                "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"></head><body style=\"margin:0;display:flex;align-items:center;justify-content:center;height:100vh;background:transparent\"><div style=\"width:30px;height:30px;border:3px solid rgba(150,150,150,.25);border-top-color:#999;border-radius:50%;animation:crspin .8s linear infinite\"></div><style>@keyframes crspin{to{transform:rotate(360deg)}}</style></body></html>",
                baseURL: URL(string: "https://castreader.local/local"))
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
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
