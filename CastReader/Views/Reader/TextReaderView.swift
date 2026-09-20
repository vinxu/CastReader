//
//  TextReaderView.swift
//  CastReader
//
//  文本源阅读：段落滚动列表。朗读高亮当前词；解读把手写标注用 UITextView 字符矩形画在原文上。
//

import SwiftUI
import UIKit
import ImageIO
import WebKit

/// EPUB 图片降采样解码器（对齐 Android Coil 自动降采样）：用 ImageIO 缩略图避免大图全分辨率解码占内存/卡顿；
/// 按字节 hash 缓存（同图复用、换书不串）。LazyVStack 仅可见段触发，配合此降采样根治大图性能问题。
enum EpubImageDecoder {
    private static let cache = NSCache<NSNumber, UIImage>()

    static func downsampled(_ data: Data, maxPixel: CGFloat = 1400) -> UIImage? {
        let key = NSNumber(value: data.hashValue)
        if let hit = cache.object(forKey: key) { return hit }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel * UIScreen.main.scale
        ]
        let img: UIImage?
        if let src = CGImageSourceCreateWithData(data as CFData, nil),
           let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) {
            img = UIImage(cgImage: cg)
        } else {
            img = UIImage(data: data)   // 缩略图失败兜底全解码
        }
        if let img { cache.setObject(img, forKey: key) }
        return img
    }
}

/// 持有各段 ReaderUITextView 引用（供解读 mark 取矩形）。非 ObservableObject，避免触发刷新循环。
final class TextViewRegistry {
    private final class Entry {
        weak var view: ReaderUITextView?
        init(_ view: ReaderUITextView?) { self.view = view }
    }
    private var entries: [Int: Entry] = [:]
    subscript(index: Int) -> ReaderUITextView? {
        get { entries[index]?.view }
        set {
            entries[index] = Entry(newValue)
            if entries.count > 100 { entries = entries.filter { $0.value.view != nil } }
        }
    }
}

struct TextReaderView: View {
    @ObservedObject private var appearance = ReaderAppearanceSettings.shared
    let document: ReadingDocument
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    let mode: ReaderMode
    let refocusToken: Int

    @State private var registry = TextViewRegistry()
    @State private var layoutRevision = 0
    @State private var pendingRefocus: DispatchWorkItem?
    private struct ParagraphStart: Hashable { let index: Int }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(document.paragraphs) { para in
                        // This must be a direct lazy-stack child: a nested ID
                        // cannot materialize a distant row that does not exist.
                        Color.clear.frame(height: 0).id(ParagraphStart(index: para.id))
                        paragraphRow(para).padding(.bottom, 18).id(para.id)
                            .accessibilityIdentifier("readerParagraph.\(para.id)")
                    }
                }
                .padding(20)
            }
            .onChange(of: readVM.currentParagraphIndex) { idx in
                guard mode == .read, readVM.autoScrollEnabled, idx >= 0 else { return }
                scheduleRefocus(proxy)
            }
            .onChange(of: readVM.epubNavigationParagraphIndex) { _ in scheduleRefocus(proxy) }
            // Word ticks are handled after ReaderTextView updates its range
            // and layout, rather than scrolling using the previous UIView state.
            .onChange(of: readVM.processedDisplayText) { _ in
                // Streaming can change a huge lazy row's measured height and
                // evict it from the viewport. Reacquire the row, then the word.
                if mode == .read { scheduleRefocus(proxy) }
            }
            .onAppear {
                scheduleRefocus(proxy)
            }
            .onDisappear { pendingRefocus?.cancel() }
            .onChange(of: explainVM.scrollTarget) { target in
                guard mode == .explain, target >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.35)) }
            }
            .onChange(of: refocusToken) { _ in
                scheduleRefocus(proxy)
            }
            .onChange(of: appearance.textSize) { _ in
                layoutRevision += 1; scheduleRefocus(proxy)
            }
            .onChange(of: appearance.lineSpacing) { _ in
                layoutRevision += 1; scheduleRefocus(proxy)
            }
            .onChange(of: appearance.usesSerif) { _ in
                layoutRevision += 1; scheduleRefocus(proxy)
            }
        }
    }

    private func scheduleRefocus(_ proxy: ScrollViewProxy) {
        pendingRefocus?.cancel()
        let work = DispatchWorkItem { refocus(proxy) }
        pendingRefocus = work
        DispatchQueue.main.async(execute: work)
    }

    private func refocus(_ proxy: ScrollViewProxy) {
        switch mode {
        case .read:
            if let target = readVM.epubNavigationParagraphIndex {
                proxy.scrollTo(target, anchor: .top)
                return
            }
            guard readVM.autoScrollEnabled, readVM.currentParagraphIndex >= 0 else { return }
            ReaderRunLog.write("TEXT refocus read para=\(readVM.currentParagraphIndex) token=\(refocusToken)")
            if let view = registry[readVM.currentParagraphIndex], view.window != nil {
                // A transient missing glyph/range is layout work, not a request
                // to abandon word positioning and jump to the paragraph top.
                view.revealFocusInReader()
                return
            }
            proxy.scrollTo(ParagraphStart(index: readVM.currentParagraphIndex),
                           anchor: UnitPoint(x: 0.5, y: ReaderViewportFollow.readingAnchor))
        case .explain:
            let target = explainVM.activeMarks.last?.paragraphIndex ?? explainVM.scrollTarget
            guard target >= 0 else { return }
            ReaderRunLog.write("TEXT refocus explain para=\(target) token=\(refocusToken)")
            withAnimation(.easeInOut(duration: 0.45)) {
                proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.35))
            }
        }
    }

    @ViewBuilder
    private func paragraphRow(_ para: ReadingParagraph) -> some View {
        if para.type == .image {
            imageRow(para)
        } else {
            textRow(para)
        }
    }

    /// EPUB 内嵌图片段（降采样解码防大图 OOM/卡顿——对齐 Android Coil；aspectFit 适宽）。
    @ViewBuilder
    private func imageRow(_ para: ReadingParagraph) -> some View {
        if let data = para.imageData, EpubImageResource.isSVG(data) {
            EpubSVGView(data: data)
                .aspectRatio(EpubImageResource.svgAspectRatio(data), contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else if let data = para.imageData, let ui = EpubImageDecoder.downsampled(data) {
            Image(uiImage: ui)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                .cornerRadius(6)
        }
    }

    @ViewBuilder
    private func textRow(_ para: ReadingParagraph) -> some View {
        let isCurrent = (mode == .read && para.id == readVM.currentParagraphIndex)
        let text = (mode == .read) ? readVM.displayText(for: para.id) : para.text
        ReaderTextView(
            text: text,
            highlightRange: isCurrent ? readVM.highlightRange : nil,
            isCurrent: mode == .read ? isCurrent : true,
            fontSize: fontSize(for: para.type),
            lineSpacing: appearance.lineSpacing,
            usesSerif: appearance.usesSerif,
            highlightColor: readVM.highlightUIColor,
            readerViewportRange: isCurrent && readVM.autoScrollEnabled && readVM.epubNavigationParagraphIndex == nil
                ? (readVM.highlightRange ?? readVM.initialResumeViewportRange
                   ?? (text.isEmpty ? nil : NSRange(location: 0, length: 1))) : nil,
            onReady: { tv in registry[para.id] = tv }
        )
        .overlay(alignment: .topLeading) { markOverlay(for: para).id(layoutRevision) }
        .contentShape(Rectangle())
        .onTapGesture {
            if mode == .read { readVM.jump(to: para.id) }
        }
    }

    @ViewBuilder
    private func markOverlay(for para: ReadingParagraph) -> some View {
        if mode == .explain, let tv = registry[para.id] {
            ForEach(explainVM.activeMarks.filter { $0.paragraphIndex == para.id }) { mark in
                if let ns = nsRange(mark.charRange, in: para.text) {
                    let rects = tv.rects(forCharRange: ns)
                    if !rects.isEmpty {
                        MarkInkView(rects: rects, action: mark.action, seed: mark.seed, n: mark.n,
                                    inkColor: Color(readVM.markBaseColor),
                                    highlightColor: Color(readVM.markBaseColor),
                                    weight: mark.weight)
                    }
                }
            }
        }
    }

    private func fontSize(for type: ReadingParagraphType) -> CGFloat {
        let scale = appearance.textSize / 18
        switch type {
        case .heading(let l): return (l <= 1 ? 24 : (l == 2 ? 21 : 19)) * scale
        default: return appearance.textSize
        }
    }

    private func nsRange(_ r: Range<Int>, in text: String) -> NSRange? {
        guard r.lowerBound >= 0, r.upperBound <= text.count, r.lowerBound < r.upperBound else { return nil }
        let s = text.index(text.startIndex, offsetBy: r.lowerBound)
        let e = text.index(text.startIndex, offsetBy: r.upperBound)
        return NSRange(s..<e, in: text)
    }
}

/// Only individual vector illustrations use WebKit. Text, scrolling and
/// highlighting retain the native paragraph pipeline.
struct EpubSVGView: UIViewRepresentable {
    let data: Data
    final class Coordinator { var loadedData: Data? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedData != data else { return }
        context.coordinator.loadedData = data
        let svg = String(data: data, encoding: .utf8) ?? ""
        view.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'">
        <style>html,body{margin:0;width:100%;height:100%;overflow:hidden}svg{display:block;width:100%;height:100%}</style>
        </head><body>\(svg)</body></html>
        """, baseURL: nil)
    }
}
