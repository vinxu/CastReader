//
//  KindleReaderView.swift
//  CastReader
//
//  Kindle Cloud Reader：多页渲染图片 + OCR bbox。朗读沿用 ReadAloudViewModel，
//  解读沿用 ExplainViewModel；本 View 只负责把 OCR 高亮/mark 放回对应页面图。
//

import SwiftUI
import UIKit

struct KindleReaderView: View {
    let document: ReadingDocument
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    let mode: ReaderMode
    let refocusToken: Int
    let onVisiblePageChanged: ((Int) -> Void)?
    @State private var lastReportedPageIndex: Int?

    init(
        document: ReadingDocument,
        readVM: ReadAloudViewModel,
        explainVM: ExplainViewModel,
        mode: ReaderMode,
        refocusToken: Int,
        onVisiblePageChanged: ((Int) -> Void)? = nil
    ) {
        self.document = document
        self.readVM = readVM
        self.explainVM = explainVM
        self.mode = mode
        self.refocusToken = refocusToken
        self.onVisiblePageChanged = onVisiblePageChanged
    }

    private var pages: [KindlePage] {
        let imageParas = document.paragraphs.filter { $0.type == .image && $0.imageData != nil }
        return imageParas.enumerated().compactMap { offset, para in
            guard let data = para.imageData, let image = UIImage(data: data) else { return nil }
            let index = para.pageIndex ?? offset
            let paraIDs = document.paragraphs
                .filter { $0.pageIndex == index && $0.type.isReadable }
                .map(\.id)
            return KindlePage(index: index, id: "kindle-page-\(index)", image: image, paragraphIDs: Set(paraIDs))
        }
    }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(pages) { page in
                            KindlePageCanvas(
                                document: document,
                                page: page,
                                readVM: readVM,
                                explainVM: explainVM,
                                mode: mode
                            )
                            .background {
                                GeometryReader { pageProxy in
                                    Color.clear.preference(
                                        key: KindleVisiblePagePreferenceKey.self,
                                        value: [
                                            page.index: pageProxy.frame(
                                                in: .named(KindlePageScrollCoordinateSpace.name)
                                            ),
                                        ]
                                    )
                                }
                            }
                            .id(page.id)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 18)
                }
                .coordinateSpace(name: KindlePageScrollCoordinateSpace.name)
                .onPreferenceChange(KindleVisiblePagePreferenceKey.self) { frames in
                    reportVisiblePage(frames: frames, viewportHeight: viewport.size.height)
                }
                .onChange(of: readVM.currentParagraphIndex) { idx in
                    guard mode == .read, idx >= 0, let pageID = pageID(forParagraph: idx) else { return }
                    withAnimation(.easeInOut(duration: 0.35)) {
                        proxy.scrollTo(pageID, anchor: UnitPoint(x: 0.5, y: 0.28))
                    }
                }
                .onChange(of: explainVM.scrollTarget) { idx in
                    guard mode == .explain, idx >= 0, let pageID = pageID(forParagraph: idx) else { return }
                    withAnimation(.easeInOut(duration: 0.45)) {
                        proxy.scrollTo(pageID, anchor: UnitPoint(x: 0.5, y: 0.30))
                    }
                }
                .onChange(of: refocusToken) { _ in
                    refocus(proxy)
                }
            }
        }
    }

    private func reportVisiblePage(frames: [Int: CGRect], viewportHeight: CGFloat) {
        guard onVisiblePageChanged != nil, viewportHeight > 0 else { return }
        let centerY = viewportHeight / 2
        let visible = frames.filter { _, frame in
            frame.maxY > 0 && frame.minY < viewportHeight
        }
        guard let pageIndex = visible.min(by: { lhs, rhs in
            abs(lhs.value.midY - centerY) < abs(rhs.value.midY - centerY)
        })?.key,
        pageIndex != lastReportedPageIndex else { return }
        lastReportedPageIndex = pageIndex
        onVisiblePageChanged?(pageIndex)
    }

    private func refocus(_ proxy: ScrollViewProxy) {
        switch mode {
        case .read:
            guard readVM.autoScrollEnabled,
                  readVM.currentParagraphIndex >= 0,
                  let pageID = pageID(forParagraph: readVM.currentParagraphIndex) else { return }
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(pageID, anchor: UnitPoint(x: 0.5, y: 0.28))
            }
        case .explain:
            let target = explainVM.activeMarks.last?.paragraphIndex ?? explainVM.scrollTarget
            guard target >= 0, let pageID = pageID(forParagraph: target) else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                proxy.scrollTo(pageID, anchor: UnitPoint(x: 0.5, y: 0.30))
            }
        }
    }

    private func pageID(forParagraph idx: Int) -> String? {
        guard idx >= 0,
              let pageIndex = document.paragraphs.first(where: { $0.id == idx })?.pageIndex else { return nil }
        return "kindle-page-\(pageIndex)"
    }
}

private enum KindlePageScrollCoordinateSpace {
    static let name = "castreader-kindle-pages"
}

private struct KindleVisiblePagePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]

    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct KindlePage: Identifiable {
    let index: Int
    let id: String
    let image: UIImage
    let paragraphIDs: Set<Int>
}

private struct KindlePageCanvas: View {
    let document: ReadingDocument
    let page: KindlePage
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    let mode: ReaderMode

    var body: some View {
        Image(uiImage: page.image)
            .resizable()
            .scaledToFit()
            .overlay {
                GeometryReader { geo in
                    let fitted = CGRect(origin: .zero, size: geo.size)
                    let resolver = PhotoAnchorResolver(document: document, fitted: fitted)
                    ZStack(alignment: .topLeading) {
                        overlay(resolver: resolver)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
    }

    @ViewBuilder
    private func overlay(resolver: PhotoAnchorResolver) -> some View {
        if mode == .read {
            if page.paragraphIDs.contains(readVM.currentParagraphIndex),
               let wi = readVM.photoHighlightWordIndex {
                let indexes = readVM.photoHighlightWordRange ?? wi..<(wi + 1)
                let rects = indexes.flatMap {
                    resolver.rectsForWord(paragraphIndex: readVM.currentParagraphIndex, wordIndex: $0)
                }
                ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(readVM.highlightUIColor).opacity(0.38))
                        .frame(width: rect.width + 4, height: rect.height + 2)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        } else {
            ForEach(explainVM.activeMarks.filter { page.paragraphIDs.contains($0.paragraphIndex) }) { mark in
                let rects = resolver.rectsForCharRange(paragraphIndex: mark.paragraphIndex, range: mark.charRange)
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
