//
//  PlayerView.swift
//  CastReader
//

import SwiftUI

// MARK: - PreferenceKey for tracking paragraph frames
struct ParagraphFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]  // key: paragraphIndex
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - PreferenceKey for ScrollView visible height
struct ScrollViewHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct PlayerView: View {
    @Environment(\.dismiss) var dismiss
    @ObservedObject private var viewModel = PlayerViewModel.shared
    @State private var showSpeedPicker = false
    @State private var scrollViewProxy: ScrollViewProxy?

    // 用于可见性检测 - 段落级别追踪
    @State private var paragraphFrames: [Int: CGRect] = [:]  // key: paragraphIndex
    @State private var scrollViewHeight: CGFloat = 0

    // Initial parameters
    var bookId: String = ""
    var bookTitle: String = ""
    var coverUrl: String?
    var paragraphs: [String] = []
    var parsedParagraphs: [ParsedParagraph] = []
    var indices: [BookIndex] = []

    // 舒适区域：屏幕高度的 15% ~ 70%（上下都留边距）
    private let comfortTopRatio: CGFloat = 0.15    // 顶部舒适边界 15%
    private let comfortBottomRatio: CGFloat = 0.70 // 底部舒适边界 70%

    // 检测段落是否在舒适可见区域内
    private func isParagraphVisible(_ paragraphIndex: Int) -> Bool {
        guard let frame = paragraphFrames[paragraphIndex], scrollViewHeight > 0 else {
            return false  // frame 未知时认为不可见，需要滚动
        }

        let comfortTop = scrollViewHeight * comfortTopRatio
        let comfortBottom = scrollViewHeight * comfortBottomRatio

        // 段落顶部在舒适区域内才算可见
        let isFirstParagraph = paragraphIndex == 0
        let isAboveComfortZone = !isFirstParagraph && frame.minY < comfortTop
        let isBelowComfortZone = frame.minY > comfortBottom

        return !isAboveComfortZone && !isBelowComfortZone
    }

    var body: some View {
        VStack(spacing: 0) {
            // ScrollView with content
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        ForEach(Array(viewModel.parsedParagraphs.enumerated()), id: \.offset) { index, para in
                            ParagraphView(
                                paragraphIndex: index,
                                text: para.text,
                                isCurrentParagraph: index == viewModel.currentParagraphIndex,
                                ttsState: viewModel.paragraphStates[index],
                                globalWordIndex: index == viewModel.currentParagraphIndex
                                    ? viewModel.currentGlobalWordIndex : nil,
                                currentSegmentIndex: index == viewModel.currentParagraphIndex
                                    ? viewModel.currentSegmentIndex : nil
                            )
                            .id(index)  // 段落 ID
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ParagraphFramePreferenceKey.self,
                                        value: [index: geo.frame(in: .named("scrollArea"))]
                                    )
                                }
                            )
                            .onTapGesture {
                                viewModel.jumpToParagraph(index)
                                viewModel.autoScrollEnabled = true
                                let anchor: UnitPoint = index == 0 ? .top : UnitPoint(x: 0.5, y: 0.15)
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    proxy.scrollTo(index, anchor: anchor)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 16)
                }
                .coordinateSpace(name: "scrollArea")
                // 获取 ScrollView 的可视高度 - 使用 overlay 确保正确测量
                .overlay(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ScrollViewHeightPreferenceKey.self, value: geo.size.height)
                    }
                )
                // 收集 ScrollView 高度
                .onPreferenceChange(ScrollViewHeightPreferenceKey.self) { height in
                    if height != scrollViewHeight {
                        scrollViewHeight = height
                        NSLog("📐 ScrollView height updated: %.1f", height)
                    }
                }
                // 收集段落位置
                .onPreferenceChange(ParagraphFramePreferenceKey.self) { frames in
                    paragraphFrames.merge(frames) { _, new in new }
                }
                // 段落切换时检查可见性并滚动
                .onChange(of: viewModel.currentParagraphIndex) { newIndex in
                    NSLog("📍 Paragraph changed to %d, auto=%@", newIndex, viewModel.autoScrollEnabled ? "Y" : "N")
                    guard viewModel.autoScrollEnabled, newIndex >= 0 else { return }

                    // 延迟检查，给 LazyVStack 时间渲染
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        // 确保仍然是当前段落
                        guard newIndex == viewModel.currentParagraphIndex else { return }

                        if !isParagraphVisible(newIndex) {
                            NSLog("📍 Paragraph %d not visible, scrolling...", newIndex)
                            // 第一段滚动到顶部，其他段落留出舒适边距（15%）
                            let anchor: UnitPoint = newIndex == 0 ? .top : UnitPoint(x: 0.5, y: 0.15)
                            withAnimation(.easeInOut(duration: 0.3)) {
                                proxy.scrollTo(newIndex, anchor: anchor)
                            }
                        }
                    }
                }
                // 检测用户滚动
                .simultaneousGesture(
                    DragGesture().onChanged { _ in
                        viewModel.onUserScroll()
                    }
                )
                .onAppear { scrollViewProxy = proxy }
            }

            Divider()
            PlayerControlsView(viewModel: viewModel, showSpeedPicker: $showSpeedPicker)
        }
        .overlay(alignment: .bottomTrailing) {
            // 回弹按钮 - 仅在手动模式显示
            if !viewModel.autoScrollEnabled && viewModel.currentParagraphIndex >= 0 {
                Button(action: {
                    if let proxy = scrollViewProxy {
                        // 先滚动到当前段落，不立即启用自动滚动
                        let index = viewModel.currentParagraphIndex
                        let anchor: UnitPoint = index == 0 ? .top : UnitPoint(x: 0.5, y: 0.15)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(index, anchor: anchor)
                        }
                        // 动画完成后再启用自动滚动
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            viewModel.scrollToPlaying()
                        }
                    }
                }) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 36, height: 36)
                        Image(systemName: "scope")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                }
                .shadow(color: .black.opacity(0.15), radius: 4, x: 0, y: 2)
                .padding(.trailing, 16)
                .padding(.bottom, 160)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left").font(.headline)
                }
            }
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(viewModel.bookTitle)
                        .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                    Text(viewModel.chapterTitle)
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button(action: { viewModel.showTOC = true }) {
                    Image(systemName: "list.bullet")
                }
            }
        }
        .sheet(isPresented: $viewModel.showTOC) {
            TOCSheet(indices: viewModel.indices, currentChapterIndex: viewModel.currentChapterIndex) { chapter in
                viewModel.jumpToChapter(chapter)
                viewModel.showTOC = false
            }
        }
        .sheet(isPresented: $showSpeedPicker) {
            SpeedPickerSheet(currentSpeed: viewModel.playbackRate) { speed in
                viewModel.setPlaybackRate(speed)
                showSpeedPicker = false
            }
        }
        .onAppear {
            if !paragraphs.isEmpty && (viewModel.currentBookId != bookId || viewModel.paragraphs.isEmpty) {
                let initialChapterTitle = indices.first?.text ?? "Chapter 1"
                viewModel.loadContent(
                    bookId: bookId, title: bookTitle, chapterTitle: initialChapterTitle,
                    coverUrl: coverUrl, paragraphs: paragraphs,
                    parsedParagraphs: parsedParagraphs, indices: indices
                )
            }
        }
    }

}

// MARK: - Reader Text Style Constants
private enum ReaderStyle {
    static let fontSize: CGFloat = 18
    static let lineSpacing: CGFloat = 8
    static let textColor = AppTheme.readerText
    static let dimmedColor = AppTheme.readerDimmed
    static let currentParagraphBackground = AppTheme.readerHighlightBackground
    static let highlightWordBackground = AppTheme.readerActiveWord
}

// MARK: - Paragraph View
struct ParagraphView: View {
    let paragraphIndex: Int
    let text: String
    let isCurrentParagraph: Bool
    let ttsState: ParagraphTTSState?
    let globalWordIndex: Int?
    let currentSegmentIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isCurrentParagraph {
                // TTS 完全加载 = status 为 ready 且有 segments
                let isFullyLoaded = ttsState?.status.isReady == true && !(ttsState?.segments.isEmpty ?? true)
                SegmentedTextView(
                    paragraphIndex: paragraphIndex,
                    originalText: text,
                    segments: ttsState?.segments ?? [],
                    globalWordIndex: globalWordIndex,
                    currentSegmentIndex: currentSegmentIndex,
                    isFullyLoaded: isFullyLoaded
                )
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(ReaderStyle.currentParagraphBackground)
                )
            } else {
                Text(text)
                    .font(.custom("Georgia", size: ReaderStyle.fontSize))
                    .foregroundColor(ReaderStyle.dimmedColor)
                    .lineSpacing(ReaderStyle.lineSpacing)
            }
        }
    }
}

// MARK: - Segmented Text View
struct SegmentedTextView: View {
    let paragraphIndex: Int
    let originalText: String
    let segments: [AudioSegment]
    let globalWordIndex: Int?
    let currentSegmentIndex: Int?
    let isFullyLoaded: Bool  // TTS 是否完全加载

    var body: some View {
        if segments.isEmpty {
            // 没有 segments，显示原始文本
            Text(originalText)
                .font(.custom("Georgia", size: ReaderStyle.fontSize))
                .foregroundColor(ReaderStyle.textColor)
                .lineSpacing(ReaderStyle.lineSpacing)
        } else if isFullyLoaded {
            // 完全加载，使用 segments 渲染（支持高亮）
            SegmentFlowView(
                paragraphIndex: paragraphIndex,
                segments: segments,
                globalWordIndex: globalWordIndex,
                currentSegmentIndex: currentSegmentIndex
            )
        } else {
            // 流式加载中：已加载部分用 segments 渲染 + 未加载部分用原始文本填充
            let loadedText = segments.flatMap { $0.timestamps.map { $0.word } }.joined(separator: " ")
            let remainingText = getRemainingText(original: originalText, loaded: loadedText)

            VStack(alignment: .leading, spacing: 0) {
                // 已加载的 segments（支持高亮）
                SegmentFlowView(
                    paragraphIndex: paragraphIndex,
                    segments: segments,
                    globalWordIndex: globalWordIndex,
                    currentSegmentIndex: currentSegmentIndex
                )

                // 未加载部分的原始文本（无高亮）
                if !remainingText.isEmpty {
                    Text(remainingText)
                        .font(.custom("Georgia", size: ReaderStyle.fontSize))
                        .foregroundColor(ReaderStyle.textColor)
                        .lineSpacing(ReaderStyle.lineSpacing)
                }
            }
        }
    }

    /// 获取原始文本中未被 segments 覆盖的部分
    private func getRemainingText(original: String, loaded: String) -> String {
        // 简单策略：找到 loaded 在 original 中的位置，返回剩余部分
        // 处理标点符号和空格差异
        let loadedClean = loaded.trimmingCharacters(in: .whitespaces)

        // 尝试找到 loaded 文本在 original 中结束的位置
        if let range = original.range(of: loadedClean, options: [.caseInsensitive]) {
            let remaining = String(original[range.upperBound...])
            return remaining.trimmingCharacters(in: .whitespaces)
        }

        // 如果找不到精确匹配，用字符数估算
        let loadedLength = loadedClean.count
        if loadedLength < original.count {
            let idx = original.index(original.startIndex, offsetBy: min(loadedLength, original.count))
            return String(original[idx...]).trimmingCharacters(in: .whitespaces)
        }

        return ""
    }
}

// MARK: - Segment Flow View
struct SegmentFlowView: View {
    let paragraphIndex: Int
    let segments: [AudioSegment]
    let globalWordIndex: Int?
    let currentSegmentIndex: Int?

    var body: some View {
        let segmentOffsets = calculateSegmentOffsets()

        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(segments.enumerated()), id: \.offset) { segmentIdx, segment in
                SegmentTextView(
                    paragraphIndex: paragraphIndex,
                    segmentIndex: segmentIdx,
                    words: segment.timestamps.map { $0.word },
                    wordOffset: segmentOffsets[segmentIdx],
                    globalWordIndex: globalWordIndex,
                    isCurrentSegment: segmentIdx == currentSegmentIndex
                )
            }
        }
    }

    private func calculateSegmentOffsets() -> [Int] {
        var offsets: [Int] = []
        var currentOffset = 0
        for segment in segments {
            offsets.append(currentOffset)
            currentOffset += segment.timestamps.count
        }
        return offsets
    }
}

// MARK: - Segment Text View
struct SegmentTextView: View {
    let paragraphIndex: Int
    let segmentIndex: Int
    let words: [String]
    let wordOffset: Int
    let globalWordIndex: Int?
    let isCurrentSegment: Bool

    var body: some View {
        Text(buildAttributedText())
            .font(.custom("Georgia", size: ReaderStyle.fontSize))
            .lineSpacing(ReaderStyle.lineSpacing)
    }

    private func buildAttributedText() -> AttributedString {
        var result = AttributedString()
        for (localIdx, word) in words.enumerated() {
            var wordAttr = AttributedString(word)
            let globalIdx = wordOffset + localIdx

            if globalIdx == globalWordIndex {
                // 高亮单词：50% 品牌色背景
                // 注：AttributedString 不支持圆角，这是 iOS 15 SwiftUI 限制
                wordAttr.backgroundColor = ReaderStyle.highlightWordBackground
                wordAttr.foregroundColor = ReaderStyle.textColor
            } else {
                wordAttr.foregroundColor = ReaderStyle.textColor
            }
            result.append(wordAttr)

            if localIdx < words.count - 1 {
                result.append(AttributedString(" "))
            }
        }
        result.append(AttributedString(" "))
        return result
    }
}

// MARK: - Player Controls
struct PlayerControlsView: View {
    @ObservedObject var viewModel: PlayerViewModel
    @Binding var showSpeedPicker: Bool

    var body: some View {
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(AppTheme.progressBackground)
                        .frame(height: 4).cornerRadius(2)
                    Rectangle()
                        .fill(AppTheme.progressFill)
                        .frame(width: geometry.size.width * CGFloat(viewModel.progress), height: 4)
                        .cornerRadius(2)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let progress = max(0, min(1, value.location.x / geometry.size.width))
                            viewModel.seekToProgress(Double(progress))
                        }
                )
            }
            .frame(height: 4)

            HStack {
                Text(viewModel.currentTime.timeString)
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()
                Spacer()
                Text(viewModel.duration.timeString)
                    .font(.caption).foregroundColor(.secondary).monospacedDigit()
            }

            HStack(spacing: 0) {
                // 书籍封面
                BookCoverImage(
                    url: viewModel.coverUrl,
                    width: 36,
                    height: 36,
                    cornerRadius: 6
                )
                .frame(maxWidth: .infinity)

                Button(action: { viewModel.seekBackward(seconds: 15) }) {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 24)).foregroundColor(.primary)
                }.frame(maxWidth: .infinity)

                Button(action: { viewModel.togglePlayPause() }) {
                    Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32)).foregroundColor(.primary)
                }.frame(maxWidth: .infinity)

                Button(action: { viewModel.seekForward(seconds: 30) }) {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 24)).foregroundColor(.primary)
                }.frame(maxWidth: .infinity)

                Button(action: { showSpeedPicker = true }) {
                    Text(viewModel.playbackRate == 1.0 ? "1x" : String(format: "%.1gx", viewModel.playbackRate))
                        .font(.system(size: 16, weight: .medium)).foregroundColor(.primary)
                }.frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
        .background(Color(.systemBackground))
    }
}

// MARK: - TOC Sheet
struct TOCSheet: View {
    let indices: [BookIndex]
    let currentChapterIndex: Int
    var onSelect: (BookIndex) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            contentView
                .navigationTitle("Contents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var contentView: some View {
        if indices.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "text.book.closed")
                    .font(.system(size: 48)).foregroundColor(.secondary)
                Text("No table of contents available")
                    .font(.headline).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(Array(indices.enumerated()), id: \.offset) { index, chapter in
                    Button(action: { onSelect(chapter) }) {
                        HStack {
                            Text(chapter.text ?? "Chapter \(index + 1)")
                                .font(index == currentChapterIndex ? .subheadline.weight(.semibold) : .subheadline)
                                .lineLimit(2)
                                .foregroundColor(index == currentChapterIndex ? AppTheme.primary : .primary)
                            Spacer()
                            if index == currentChapterIndex {
                                Image(systemName: "speaker.wave.2.fill")
                                    .foregroundColor(AppTheme.primary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }
}

// MARK: - Speed Picker Sheet
struct SpeedPickerSheet: View {
    let currentSpeed: Float
    var onSelect: (Float) -> Void
    @Environment(\.dismiss) var dismiss
    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    var body: some View {
        NavigationView {
            List {
                ForEach(speeds, id: \.self) { speed in
                    Button(action: { onSelect(speed) }) {
                        HStack {
                            Text(speed == 1.0 ? "Normal" : String(format: "%.2gx", speed))
                                .foregroundColor(.primary)
                            Spacer()
                            if speed == currentSpeed {
                                Image(systemName: "checkmark").foregroundColor(AppTheme.primary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Playback Speed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

struct PlayerView_Previews: PreviewProvider {
    static var previews: some View {
        PlayerView()
    }
}
