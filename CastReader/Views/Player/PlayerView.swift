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
    var language: String = "en"  // 文档语言，用于 TTS

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
                                paragraph: para,
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
        .background(Color(.systemBackground))
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
                    parsedParagraphs: parsedParagraphs, indices: indices,
                    language: language
                )
            }
        }
    }

}

// MARK: - Reader Text Style Constants
private enum ReaderStyle {
    // 基础字号
    static let fontSize: CGFloat = 18
    static let lineSpacing: CGFloat = 8

    // 标题字号（参考 Android 样式）
    static func headingFontSize(level: Int) -> CGFloat {
        switch level {
        case 1: return 28
        case 2: return 24
        case 3: return 20
        case 4: return 18
        case 5: return 16
        case 6: return 14
        default: return 18
        }
    }

    // 颜色
    static let textColor = AppTheme.readerText
    static let dimmedColor = AppTheme.readerDimmed
    static let currentParagraphBackground = AppTheme.readerHighlightBackground
    static let highlightWordBackground = AppTheme.readerActiveWord
    static let blockquoteBorderColor = AppTheme.primary
    static let codeBackground = Color(.systemGray6)
}

// MARK: - Paragraph View
struct ParagraphView: View {
    let paragraphIndex: Int
    let paragraph: ParsedParagraph  // 完整段落数据（包含类型和图片）
    let isCurrentParagraph: Bool
    let ttsState: ParagraphTTSState?
    let globalWordIndex: Int?
    let currentSegmentIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 渲染图片（如果有）
            if let images = paragraph.images, !images.isEmpty {
                ForEach(images) { image in
                    ParagraphImageView(image: image)
                }
            }

            // 渲染文本内容（根据段落类型应用不同样式）
            if !paragraph.text.isEmpty {
                textContentView
            }
        }
    }

    @ViewBuilder
    private var textContentView: some View {
        switch paragraph.type {
        case .heading(let level):
            headingView(level: level)
        case .blockquote:
            blockquoteView
        case .code:
            codeBlockView
        case .list:
            listItemView
        case .image:
            // 纯图片段落，文本部分可能为空或仅有描述
            if !paragraph.text.isEmpty {
                captionView
            }
        default:
            paragraphTextView
        }
    }

    // MARK: - 标题样式
    @ViewBuilder
    private func headingView(level: Int) -> some View {
        let fontSize = ReaderStyle.headingFontSize(level: level)
        Group {
            if isCurrentParagraph {
                highlightedTextView(fontSize: fontSize, fontWeight: .bold)
            } else {
                Text(paragraph.text)
                    .font(.custom("Georgia", size: fontSize))
                    .fontWeight(.bold)
                    .foregroundColor(ReaderStyle.textColor)
                    .lineSpacing(4)
            }
        }
        .padding(.top, level <= 2 ? 12 : 8)
        .padding(.bottom, level <= 2 ? 8 : 4)
    }

    // MARK: - 引用块样式
    @ViewBuilder
    private var blockquoteView: some View {
        HStack(alignment: .top, spacing: 12) {
            Rectangle()
                .fill(ReaderStyle.blockquoteBorderColor)
                .frame(width: 4)

            Group {
                if isCurrentParagraph {
                    highlightedTextView(fontSize: ReaderStyle.fontSize, fontWeight: .regular, italic: true)
                } else {
                    Text(paragraph.text)
                        .font(.custom("Georgia", size: ReaderStyle.fontSize))
                        .italic()
                        .foregroundColor(ReaderStyle.dimmedColor)
                        .lineSpacing(ReaderStyle.lineSpacing)
                }
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - 代码块样式
    @ViewBuilder
    private var codeBlockView: some View {
        Group {
            if isCurrentParagraph {
                highlightedTextView(fontSize: 14, fontWeight: .regular, monospace: true)
            } else {
                Text(paragraph.text)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(ReaderStyle.dimmedColor)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ReaderStyle.codeBackground)
        .cornerRadius(8)
    }

    // MARK: - 列表项样式
    @ViewBuilder
    private var listItemView: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•")
                .font(.custom("Georgia", size: ReaderStyle.fontSize))
                .foregroundColor(isCurrentParagraph ? ReaderStyle.textColor : ReaderStyle.dimmedColor)

            Group {
                if isCurrentParagraph {
                    highlightedTextView(fontSize: ReaderStyle.fontSize, fontWeight: .regular)
                } else {
                    Text(paragraph.text)
                        .font(.custom("Georgia", size: ReaderStyle.fontSize))
                        .foregroundColor(ReaderStyle.dimmedColor)
                        .lineSpacing(ReaderStyle.lineSpacing)
                }
            }
        }
    }

    // MARK: - 图片描述样式
    @ViewBuilder
    private var captionView: some View {
        Text(paragraph.text)
            .font(.custom("Georgia", size: 14))
            .foregroundColor(.secondary)
            .italic()
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - 普通段落样式
    @ViewBuilder
    private var paragraphTextView: some View {
        if isCurrentParagraph {
            let segments = ttsState?.segments ?? []
            let isFullyLoaded = ttsState?.status.isReady == true && !segments.isEmpty
            // 关键：unprocessedText 只在有 segments 时才有意义
            // 无 segments 时传空串，让 SegmentedTextView 显示 originalText
            let remaining = segments.isEmpty ? "" : (ttsState?.unprocessedText ?? "")
            SegmentedTextView(
                paragraphIndex: paragraphIndex,
                originalText: paragraph.text,
                segments: segments,
                globalWordIndex: globalWordIndex,
                currentSegmentIndex: currentSegmentIndex,
                isFullyLoaded: isFullyLoaded,
                unprocessedText: remaining
            )
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(ReaderStyle.currentParagraphBackground)
            )
        } else {
            Text(paragraph.text)
                .font(.custom("Georgia", size: ReaderStyle.fontSize))
                .foregroundColor(ReaderStyle.dimmedColor)
                .lineSpacing(ReaderStyle.lineSpacing)
        }
    }

    // MARK: - 高亮文本视图（用于当前播放段落）
    @ViewBuilder
    private func highlightedTextView(fontSize: CGFloat, fontWeight: Font.Weight, italic: Bool = false, monospace: Bool = false) -> some View {
        let segments = ttsState?.segments ?? []
        let isFullyLoaded = ttsState?.status.isReady == true && !segments.isEmpty
        let remaining = segments.isEmpty ? "" : (ttsState?.unprocessedText ?? "")
        SegmentedTextView(
            paragraphIndex: paragraphIndex,
            originalText: paragraph.text,
            segments: segments,
            globalWordIndex: globalWordIndex,
            currentSegmentIndex: currentSegmentIndex,
            isFullyLoaded: isFullyLoaded,
            unprocessedText: remaining,
            fontSize: fontSize,
            fontWeight: fontWeight,
            isMonospace: monospace,
            isItalic: italic
        )
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(ReaderStyle.currentParagraphBackground)
        )
    }
}

// MARK: - Paragraph Image View
struct ParagraphImageView: View {
    let image: ImageBlock

    /// 计算图片显示宽度
    private var displayWidth: CGFloat {
        if let width = image.width {
            // 小图使用原始宽度，大图最大为屏幕宽度的 90%
            let maxWidth = UIScreen.main.bounds.width * 0.9
            return min(width, maxWidth)
        }
        // 默认：大图全宽，小图 150pt
        return image.isSmallImage ? 150 : UIScreen.main.bounds.width * 0.9
    }

    /// 计算占位符高度
    private var placeholderHeight: CGFloat {
        if let width = image.width {
            // 假设图片宽高比约为 1:1
            return min(width, 300)
        }
        return image.isSmallImage ? 150 : 250
    }

    var body: some View {
        HStack {
            // 左对齐或居中时，不需要前置 Spacer
            if image.alignment == .right {
                Spacer()
            }

            VStack(spacing: 4) {
                if let url = URL(string: image.src) {
                    CachedAsyncImage(url: url) {
                        // Placeholder while loading
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: displayWidth, height: placeholderHeight)
                            .overlay(
                                ProgressView()
                            )
                    }
                    .frame(width: displayWidth)
                    .cornerRadius(8)
                }

                // 优先显示 caption，其次是 alt
                if let caption = image.caption, !caption.isEmpty {
                    Text(caption)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                } else if let alt = image.alt, !alt.isEmpty {
                    Text(alt)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }
            }

            // 右对齐或居中时，不需要后置 Spacer
            if image.alignment == .left {
                Spacer()
            }

            // 居中需要两侧 Spacer
            if image.alignment == .center {
                // 已经在 HStack 中，使用 frame 居中
            }
        }
        .frame(maxWidth: .infinity, alignment: imageAlignment)
        .padding(.vertical, image.isSmallImage ? 4 : 8)
    }

    /// SwiftUI 对齐方式
    private var imageAlignment: Alignment {
        switch image.alignment {
        case .left: return .leading
        case .right: return .trailing
        case .center, .inline: return .center
        }
    }
}

// MARK: - Segmented Text View
/// Android 风格：直接渲染 TTS 返回的文本，确保音频和文字完美对齐
/// 显示：segments[].timestamps[].word 拼接 + remainingText（半透明）
struct SegmentedTextView: View {
    let paragraphIndex: Int
    let originalText: String
    let segments: [AudioSegment]
    let globalWordIndex: Int?
    let currentSegmentIndex: Int?
    let isFullyLoaded: Bool
    let unprocessedText: String
    var fontSize: CGFloat = ReaderStyle.fontSize
    var fontWeight: Font.Weight = .regular
    var isMonospace: Bool = false
    var isItalic: Bool = false

    var body: some View {
        Text(buildAttributedText())
            .font(isMonospace ? .system(size: fontSize, design: .monospaced) : .custom("Georgia", size: fontSize))
            .fontWeight(fontWeight)
            .italic(isItalic)
            .lineSpacing(ReaderStyle.lineSpacing)
    }

    /// 检查是否是标点符号（不需要前置空格）
    private func isPunctuation(_ word: String) -> Bool {
        guard let first = word.first else { return false }
        return ".,!?;:—'\"".contains(first)
    }

    /// Android 风格构建：直接使用 TTS timestamps 的单词，不做映射
    private func buildAttributedText() -> AttributedString {
        // 无 segments 时，显示原文
        if segments.isEmpty {
            var attr = AttributedString(originalText)
            attr.foregroundColor = ReaderStyle.textColor
            return attr
        }

        // 计算总共有多少个 TTS 单词
        let totalTTSWords = segments.reduce(0) { $0 + $1.timestamps.count }

        // 如果没有 timestamps，使用 segment.text 进行段落级高亮
        if totalTTSWords == 0 {
            return buildSentenceLevelText()
        }

        // 有 timestamps，使用词级高亮
        return buildWordLevelText()
    }

    /// 词级高亮：使用 segment.text 保留原始空白（包括换行），在其中定位并高亮 timestamps 单词
    private func buildWordLevelText() -> AttributedString {
        var result = AttributedString()
        var globalWordIdx = 0

        // 渲染所有 segments，使用 segment.text 保留原始格式
        for (segmentIdx, segment) in segments.enumerated() {
            let segmentText = segment.text

            // segment 之间添加空格（如果需要）
            if segmentIdx > 0 && !result.characters.isEmpty {
                let lastChar = result.characters.last
                let firstChar = segmentText.first
                if let last = lastChar, let first = firstChar,
                   !last.isWhitespace && !first.isWhitespace && !isPunctuation(String(first)) {
                    var space = AttributedString(" ")
                    space.foregroundColor = ReaderStyle.textColor
                    result.append(space)
                }
            }

            // 在 segment.text 中定位每个 timestamp 单词，保留原始空白
            var searchStart = segmentText.startIndex

            for timestamp in segment.timestamps {
                let word = timestamp.word

                // 在 segmentText 中查找单词位置
                if let wordRange = segmentText.range(of: word, options: .literal, range: searchStart..<segmentText.endIndex) {
                    // 添加单词前的空白（包括换行）
                    if searchStart < wordRange.lowerBound {
                        let whitespace = String(segmentText[searchStart..<wordRange.lowerBound])
                        var wsAttr = AttributedString(whitespace)
                        wsAttr.foregroundColor = ReaderStyle.textColor
                        result.append(wsAttr)
                    }

                    // 添加单词（可能高亮）
                    var wordAttr = AttributedString(word)
                    if globalWordIdx == globalWordIndex {
                        wordAttr.backgroundColor = ReaderStyle.highlightWordBackground
                    }
                    wordAttr.foregroundColor = ReaderStyle.textColor
                    result.append(wordAttr)

                    searchStart = wordRange.upperBound
                } else {
                    // 找不到单词，直接添加（带空格）
                    if globalWordIdx > 0 && !isPunctuation(word) {
                        var space = AttributedString(" ")
                        space.foregroundColor = ReaderStyle.textColor
                        result.append(space)
                    }

                    var wordAttr = AttributedString(word)
                    if globalWordIdx == globalWordIndex {
                        wordAttr.backgroundColor = ReaderStyle.highlightWordBackground
                    }
                    wordAttr.foregroundColor = ReaderStyle.textColor
                    result.append(wordAttr)
                }

                globalWordIdx += 1
            }

            // 添加 segment 末尾剩余的文本（如果有）
            if searchStart < segmentText.endIndex {
                let trailing = String(segmentText[searchStart...])
                var trailAttr = AttributedString(trailing)
                trailAttr.foregroundColor = ReaderStyle.textColor
                result.append(trailAttr)
            }
        }

        // 渲染未处理的剩余文本（半透明）
        if !unprocessedText.isEmpty {
            // 添加空格分隔（如果需要）
            if !result.characters.isEmpty {
                let lastChar = result.characters.last
                let firstChar = unprocessedText.first
                if let last = lastChar, let first = firstChar,
                   !last.isWhitespace && !first.isWhitespace {
                    var space = AttributedString(" ")
                    space.foregroundColor = ReaderStyle.dimmedColor
                    result.append(space)
                }
            }

            var remainingAttr = AttributedString(unprocessedText)
            remainingAttr.foregroundColor = ReaderStyle.dimmedColor
            result.append(remainingAttr)
        }

        return result
    }

    /// 句级高亮：使用 segment.text 整句高亮
    private func buildSentenceLevelText() -> AttributedString {
        var result = AttributedString()

        // 渲染所有 segments 的 text
        for (segmentIdx, segment) in segments.enumerated() {
            // segment 之间加空格
            if segmentIdx > 0 && !segment.text.hasPrefix(" ") {
                var space = AttributedString(" ")
                space.foregroundColor = ReaderStyle.textColor
                result.append(space)
            }

            var segmentAttr = AttributedString(segment.text)

            // 高亮当前 segment
            if segmentIdx == currentSegmentIndex {
                segmentAttr.backgroundColor = ReaderStyle.highlightWordBackground
            }
            segmentAttr.foregroundColor = ReaderStyle.textColor
            result.append(segmentAttr)
        }

        // 渲染未处理的剩余文本（半透明）
        if !unprocessedText.isEmpty {
            if !result.characters.isEmpty && !unprocessedText.hasPrefix(" ") {
                var space = AttributedString(" ")
                space.foregroundColor = ReaderStyle.dimmedColor
                result.append(space)
            }

            var remainingAttr = AttributedString(unprocessedText)
            remainingAttr.foregroundColor = ReaderStyle.dimmedColor
            result.append(remainingAttr)
        }

        return result
    }
}

// MARK: - Segment Flow View
/// 将所有 segments 合并成一个 Text，保持文本自然流动（不强制换行）
struct SegmentFlowView: View {
    let paragraphIndex: Int
    let segments: [AudioSegment]
    let globalWordIndex: Int?
    let currentSegmentIndex: Int?

    var body: some View {
        Text(buildCombinedAttributedText())
            .font(.custom("Georgia", size: ReaderStyle.fontSize))
            .foregroundColor(ReaderStyle.textColor)
            .lineSpacing(ReaderStyle.lineSpacing)
    }

    /// 将所有 segments 合并成一个 AttributedString，支持词级和段落级高亮
    private func buildCombinedAttributedText() -> AttributedString {
        var result = AttributedString()
        var globalWordOffset = 0

        for (segmentIdx, segment) in segments.enumerated() {
            let isCurrentSegment = segmentIdx == currentSegmentIndex

            if segment.timestamps.isEmpty {
                // 无 timestamps → 段落级高亮
                var segmentAttr = AttributedString(segment.text)
                if isCurrentSegment {
                    segmentAttr.backgroundColor = ReaderStyle.highlightWordBackground
                }
                segmentAttr.foregroundColor = ReaderStyle.textColor
                result.append(segmentAttr)
                result.append(AttributedString(" "))
            } else {
                // 有 timestamps → 词级高亮
                for (localIdx, ts) in segment.timestamps.enumerated() {
                    var wordAttr = AttributedString(ts.word)
                    let globalIdx = globalWordOffset + localIdx

                    if globalIdx == globalWordIndex {
                        wordAttr.backgroundColor = ReaderStyle.highlightWordBackground
                    }
                    wordAttr.foregroundColor = ReaderStyle.textColor
                    result.append(wordAttr)

                    // 单词之间加空格
                    if localIdx < segment.timestamps.count - 1 {
                        result.append(AttributedString(" "))
                    }
                }
                // segment 之间加空格
                result.append(AttributedString(" "))
                globalWordOffset += segment.timestamps.count
            }
        }

        return result
    }
}

// MARK: - Segment Text View (保留用于单独渲染，但主要使用 SegmentFlowView)
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
