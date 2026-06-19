//
//  PhotoReaderCanvas.swift
//  CastReader
//
//  拍摄/相册源阅读：照片按宽度自适应铺满 + 上下滚动 + 双指/双击缩放（像 PDF），
//  朗读高亮当前 OCR 词、解读画手写标注，并自动滚动跟随当前位置。
//  外层 UIScrollView 负责 fit width / 滚动 / 缩放 / 程序化滚动；内容（图片 + 叠加层）是 SwiftUI（PhotoContent）。
//

import SwiftUI
import Combine

struct PhotoReaderCanvas: UIViewRepresentable {
    let document: ReadingDocument
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    let mode: ReaderMode

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, readVM: readVM, explainVM: explainVM, mode: mode)
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.alwaysBounceVertical = true
        scroll.showsVerticalScrollIndicator = true
        scroll.backgroundColor = UIColor(AppTheme.background)
        scroll.contentInsetAdjustmentBehavior = .never

        let host = UIHostingController(
            rootView: PhotoContent(document: document, readVM: readVM, explainVM: explainVM, mode: mode))
        host.view.backgroundColor = .clear
        scroll.addSubview(host.view)

        // 双击放大 / 还原（同 PDF 阅读手感）
        let dbl = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        dbl.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(dbl)

        context.coordinator.attach(scroll: scroll, host: host)
        DispatchQueue.main.async { context.coordinator.relayoutIfNeeded() }
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        context.coordinator.update(mode: mode)
        context.coordinator.relayoutIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        let document: ReadingDocument
        let readVM: ReadAloudViewModel
        let explainVM: ExplainViewModel
        private(set) var mode: ReaderMode

        private weak var scroll: UIScrollView?
        private var host: UIHostingController<PhotoContent>?
        private var cancellables = Set<AnyCancellable>()
        private var laidOutWidth: CGFloat = 0

        init(document: ReadingDocument, readVM: ReadAloudViewModel, explainVM: ExplainViewModel, mode: ReaderMode) {
            self.document = document
            self.readVM = readVM
            self.explainVM = explainVM
            self.mode = mode
        }

        fileprivate func attach(scroll: UIScrollView, host: UIHostingController<PhotoContent>) {
            self.scroll = scroll
            self.host = host
            // 朗读：当前 OCR 词变化 → 滚动跟随
            readVM.$photoHighlightWordIndex
                .combineLatest(readVM.$currentParagraphIndex)
                .receive(on: RunLoop.main)
                .sink { [weak self] wi, pi in self?.scrollToWord(paragraph: pi, word: wi) }
                .store(in: &cancellables)
            // 解读：最新 mark 变化 → 滚动跟随
            explainVM.$activeMarks
                .receive(on: RunLoop.main)
                .sink { [weak self] marks in self?.scrollToMark(marks.last) }
                .store(in: &cancellables)
        }

        /// mode 切换（朗读↔解读）→ 更新叠加层（高亮 / 手写标注互换）。
        func update(mode newMode: ReaderMode) {
            guard newMode != mode else { return }
            mode = newMode
            host?.rootView = PhotoContent(document: document, readVM: readVM, explainVM: explainVM, mode: newMode)
        }

        private var imageAspect: CGFloat {
            let p = document.imagePixelSize
                ?? document.imageData.flatMap(UIImage.init)?.size
                ?? CGSize(width: 1, height: 1)
            return p.width > 0 ? p.height / p.width : 1
        }

        /// 按 scrollView 宽度铺满（fit width），高度按图片比例；仅宽度变化（首次 / 旋转）才重排，避免打断缩放。
        func relayoutIfNeeded() {
            guard let scroll, let host else { return }
            let W = scroll.bounds.width
            guard W > 0, abs(W - laidOutWidth) > 0.5 else { return }
            laidOutWidth = W
            scroll.zoomScale = 1
            let H = W * imageAspect
            host.view.frame = CGRect(x: 0, y: 0, width: W, height: H)
            scroll.contentSize = CGSize(width: W, height: H)
        }

        // MARK: UIScrollViewDelegate

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host?.view }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            // 缩放后内容窄于视口时水平居中
            guard let host else { return }
            let cw = host.view.frame.width
            let inset = max(0, (scrollView.bounds.width - cw) / 2)
            scrollView.contentInset = UIEdgeInsets(top: 0, left: inset, bottom: 0, right: inset)
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) {
            guard let scroll, let host else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let p = g.location(in: host.view)
                let target: CGFloat = 2.5
                let size = CGSize(width: scroll.bounds.width / target, height: scroll.bounds.height / target)
                scroll.zoom(to: CGRect(x: p.x - size.width / 2, y: p.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }

        // MARK: 自动滚动

        private func scrollToWord(paragraph: Int, word: Int?) {
            guard mode == .read, let word, let host else { return }
            let resolver = PhotoAnchorResolver(document: document, fitted: host.view.bounds)
            scrollToContent(resolver.rectsForWord(paragraphIndex: paragraph, wordIndex: word))
        }

        private func scrollToMark(_ mark: ResolvedMark?) {
            guard mode == .explain, let mark, let host else { return }
            let resolver = PhotoAnchorResolver(document: document, fitted: host.view.bounds)
            scrollToContent(resolver.rectsForCharRange(paragraphIndex: mark.paragraphIndex, range: mark.charRange))
        }

        /// 把内容坐标矩形（未缩放）滚到可见（含上下留白；已可见则 scrollRectToVisible 自动不滚，避免抖动）。
        private func scrollToContent(_ rects: [CGRect]) {
            guard let scroll, !rects.isEmpty else { return }
            let union = rects.reduce(CGRect.null) { $0.union($1) }
            guard !union.isNull else { return }
            let z = scroll.zoomScale
            let target = CGRect(x: union.minX * z, y: union.minY * z - 100,
                                width: max(1, union.width * z), height: union.height * z + 200)
            scroll.scrollRectToVisible(target, animated: true)
        }
    }
}

/// 照片内容（图片 + 高亮 / 手写标注叠加）。尺寸由外层 UIScrollView 决定；叠加层订阅 VM 自更新。
private struct PhotoContent: View {
    let document: ReadingDocument
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    let mode: ReaderMode

    private var image: UIImage? { document.imageData.flatMap(UIImage.init) }

    var body: some View {
        GeometryReader { geo in
            let fitted = CGRect(origin: .zero, size: geo.size)
            let resolver = PhotoAnchorResolver(document: document, fitted: fitted)
            ZStack(alignment: .topLeading) {
                if let image = image {
                    Image(uiImage: image)
                        .resizable()
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                overlay(resolver: resolver)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    @ViewBuilder
    private func overlay(resolver: PhotoAnchorResolver) -> some View {
        if mode == .read {
            if let wi = readVM.photoHighlightWordIndex {
                ForEach(resolver.rectsForWord(paragraphIndex: readVM.currentParagraphIndex, wordIndex: wi), id: \.self) { rect in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(readVM.highlightUIColor).opacity(0.38))
                        .frame(width: rect.width + 4, height: rect.height + 2)
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        } else {
            ForEach(explainVM.activeMarks) { mark in
                let rects = resolver.rectsForCharRange(paragraphIndex: mark.paragraphIndex, range: mark.charRange)
                if !rects.isEmpty {
                    MarkInkView(rects: rects, action: mark.action, seed: mark.seed, n: mark.n,
                                highlightColor: Color(readVM.highlightUIColor))
                }
            }
        }
    }
}
