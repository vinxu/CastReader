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
                        .id(page.id)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 18)
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
        }
    }

    private func pageID(forParagraph idx: Int) -> String? {
        guard idx >= 0, idx < document.paragraphs.count,
              let pageIndex = document.paragraphs[idx].pageIndex else { return nil }
        return "kindle-page-\(pageIndex)"
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
                let rects = resolver.rectsForWord(paragraphIndex: readVM.currentParagraphIndex, wordIndex: wi)
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
