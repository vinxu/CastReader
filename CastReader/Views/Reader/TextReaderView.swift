//
//  TextReaderView.swift
//  CastReader
//
//  文本源阅读：段落滚动列表。朗读高亮当前词；解读把手写标注用 UITextView 字符矩形画在原文上。
//

import SwiftUI
import UIKit
import ImageIO

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
private final class TextViewRegistry {
    var map: [Int: ReaderUITextView] = [:]
}

struct TextReaderView: View {
    let document: ReadingDocument
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    let mode: ReaderMode

    @State private var registry = TextViewRegistry()

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(document.paragraphs) { para in
                        paragraphRow(para).id(para.id)
                    }
                }
                .padding(20)
            }
            .onChange(of: readVM.currentParagraphIndex) { idx in
                guard mode == .read, readVM.autoScrollEnabled, idx >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(idx, anchor: UnitPoint(x: 0.5, y: 0.30)) }
            }
            .onChange(of: explainVM.scrollTarget) { target in
                guard mode == .explain, target >= 0 else { return }
                withAnimation(.easeInOut(duration: 0.45)) { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.35)) }
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
        if let data = para.imageData, let ui = EpubImageDecoder.downsampled(data) {
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
            highlightColor: readVM.highlightUIColor,
            onReady: { tv in registry.map[para.id] = tv }
        )
        .overlay(alignment: .topLeading) { markOverlay(for: para) }
        .contentShape(Rectangle())
        .onTapGesture {
            if mode == .read { readVM.jump(to: para.id) }
        }
    }

    @ViewBuilder
    private func markOverlay(for para: ReadingParagraph) -> some View {
        if mode == .explain, let tv = registry.map[para.id] {
            ForEach(explainVM.activeMarks.filter { $0.paragraphIndex == para.id }) { mark in
                if let ns = nsRange(mark.charRange, in: para.text) {
                    let rects = tv.rects(forCharRange: ns)
                    if !rects.isEmpty {
                        MarkInkView(rects: rects, action: mark.action, seed: mark.seed, n: mark.n,
                                    inkColor: Color(readVM.markBaseColor),
                                    highlightColor: Color(readVM.markBaseColor))
                    }
                }
            }
        }
    }

    private func fontSize(for type: ReadingParagraphType) -> CGFloat {
        switch type {
        case .heading(let l): return l <= 1 ? 24 : (l == 2 ? 21 : 19)
        default: return 18
        }
    }

    private func nsRange(_ r: Range<Int>, in text: String) -> NSRange? {
        guard r.lowerBound >= 0, r.upperBound <= text.count, r.lowerBound < r.upperBound else { return nil }
        let s = text.index(text.startIndex, offsetBy: r.lowerBound)
        let e = text.index(text.startIndex, offsetBy: r.upperBound)
        return NSRange(s..<e, in: text)
    }
}
