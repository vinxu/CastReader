//
//  PlayerViewModel.swift
//  CastReader
//
//  Supports both local (CoreML) and cloud TTS based on user settings
//  Uses background tasks to continue TTS generation when app is backgrounded

import Foundation
import Combine
import UIKit

// MARK: - Scroll Direction Enum
enum ScrollDirection {
    case up
    case down
}

@MainActor
class PlayerViewModel: ObservableObject {
    // MARK: - Singleton
    static let shared = PlayerViewModel()

    // MARK: - Published Properties

    // Content
    @Published var bookTitle: String = ""
    @Published var chapterTitle: String = ""
    @Published var coverUrl: String?
    @Published var paragraphs: [String] = []
    @Published var currentBookId: String = ""

    // TOC
    @Published var indices: [BookIndex] = []
    @Published var parsedParagraphs: [ParsedParagraph] = []
    @Published var currentChapterIndex: Int = 0

    // Playback state
    @Published var currentParagraphIndex = 0
    @Published var currentSegmentIndex = 0
    @Published var isPlaying = false
    @Published var isLoading = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1.0

    // TTS state per paragraph
    @Published var paragraphStates: [Int: ParagraphTTSState] = [:]

    // Word highlighting
    @Published var highlightedWordIndex: Int?
    @Published var currentTimestamps: [TTSTimestamp] = []
    @Published var currentGlobalWordIndex: Int = 0

    // Settings
    @Published var selectedVoice: String = Constants.TTS.defaultVoice
    @Published var selectedLanguage: String = Constants.TTS.defaultLanguage

    // UI state
    @Published var showTOC = false
    @Published var autoScrollEnabled = true
    @Published var scrollBackDirection: ScrollDirection? = nil

    // Error
    @Published var error: String?

    // MARK: - Private Properties

    private let audioPlayer = AudioPlayerService.shared
    private let ttsService = TTSService.shared
    private var cancellables = Set<AnyCancellable>()

    // 章节映射表：paragraphIndex → chapterIndex（避免每次遍历）
    private var paragraphToChapterMap: [Int: Int] = [:]

    // Background task for continuing TTS generation when app is backgrounded
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid

    // Current loading task (can be cancelled)
    private var currentLoadTask: Task<Void, Never>?

    // Preload task for next paragraph (串行预加载)
    private var preloadTask: Task<Void, Never>?
    private var preloadedParagraphIndex: Int = -1

    // MARK: - Computed Properties

    var progress: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    var currentParagraphText: String {
        guard currentParagraphIndex < paragraphs.count else { return "" }
        return paragraphs[currentParagraphIndex]
    }

    var isCurrentParagraphLoading: Bool {
        paragraphStates[currentParagraphIndex]?.status.isLoading ?? false
    }

    // MARK: - Initialization

    private init() {
        setupObservers()
    }

    private func setupObservers() {
        audioPlayer.$isPlaying
            .receive(on: DispatchQueue.main)
            .assign(to: &$isPlaying)

        audioPlayer.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] time in
                self?.currentTime = time
                self?.updateHighlightedWord(at: time)
            }
            .store(in: &cancellables)

        audioPlayer.$duration
            .receive(on: DispatchQueue.main)
            .assign(to: &$duration)

        audioPlayer.$playbackRate
            .receive(on: DispatchQueue.main)
            .assign(to: &$playbackRate)

        audioPlayer.$currentSegment
            .receive(on: DispatchQueue.main)
            .sink { [weak self] segment in
                if let segment = segment {
                    self?.currentTimestamps = segment.timestamps
                    let oldIndex = self?.currentParagraphIndex ?? 0
                    self?.currentParagraphIndex = segment.paragraphIndex
                    self?.currentSegmentIndex = segment.segmentIndex

                    if oldIndex != segment.paragraphIndex {
                        self?.updateCurrentChapterFromMap(segment.paragraphIndex)
                    }
                } else {
                    self?.currentTimestamps = []
                    self?.highlightedWordIndex = nil
                    self?.currentGlobalWordIndex = 0
                }
            }
            .store(in: &cancellables)

        audioPlayer.onSegmentComplete = { [weak self] in
            Task { @MainActor in
                self?.onSegmentComplete()
            }
        }

        audioPlayer.onPlaybackComplete = { [weak self] in
            Task { @MainActor in
                self?.onPlaybackComplete()
            }
        }

        // App lifecycle observers for GPU/CPU mode switching (background audio support)
        NotificationCenter.default.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleAppWillResignActive()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.handleAppDidBecomeActive()
            }
        }
    }

    // MARK: - App Lifecycle (GPU/CPU Mode Switching)

    /// Handle app going to background - switch to CPU-only mode
    private func handleAppWillResignActive() async {
        // Only switch if using local TTS
        guard TTSService.shared.currentProvider == .local else {
            print("[PlayerViewModel] Using cloud TTS, no mode switch needed")
            return
        }

        print("[PlayerViewModel] 📱 App will resign active - switching to CPU-only mode")
        do {
            try await LocalTTSService.shared.switchToBackgroundMode()
        } catch {
            print("[PlayerViewModel] ⚠️ Failed to switch to background mode: \(error)")
        }
    }

    /// Handle app coming to foreground - switch to GPU mode
    private func handleAppDidBecomeActive() async {
        // Only switch if using local TTS
        guard TTSService.shared.currentProvider == .local else {
            print("[PlayerViewModel] Using cloud TTS, no mode switch needed")
            return
        }

        print("[PlayerViewModel] 📱 App did become active - switching to GPU mode")
        do {
            try await LocalTTSService.shared.switchToForegroundMode()
        } catch {
            print("[PlayerViewModel] ⚠️ Failed to switch to foreground mode: \(error)")
        }
    }

    // MARK: - Public Methods

    func loadContent(
        bookId: String,
        title: String,
        chapterTitle: String,
        coverUrl: String?,
        paragraphs: [String],
        parsedParagraphs: [ParsedParagraph] = [],
        indices: [BookIndex] = []
    ) {
        if self.currentBookId == bookId && !self.paragraphs.isEmpty {
            return
        }

        self.currentBookId = bookId
        self.bookTitle = title
        self.chapterTitle = chapterTitle
        self.coverUrl = coverUrl
        self.paragraphs = paragraphs
        self.parsedParagraphs = parsedParagraphs
        self.indices = indices
        self.currentParagraphIndex = 0
        self.currentSegmentIndex = 0
        self.currentGlobalWordIndex = 0
        self.currentChapterIndex = 0

        // 初始化段落状态
        paragraphStates = [:]
        for (index, _) in paragraphs.enumerated() {
            paragraphStates[index] = ParagraphTTSState()
        }

        // 预建章节映射表
        buildChapterMapping()

        audioPlayer.setBook(id: bookId, title: title, chapterTitle: chapterTitle, coverUrl: coverUrl)

        // Start background task for the entire playback session
        beginBackgroundTask()

        Task {
            await playParagraph(at: 0)
        }
    }

    func play() {
        // Start background task to keep app alive during playback
        beginBackgroundTask()

        if audioPlayer.currentSegment == nil && !paragraphs.isEmpty {
            if isLoading { return }
            Task {
                await playParagraph(at: currentParagraphIndex)
            }
        } else {
            audioPlayer.play()
        }
    }

    func pause() {
        audioPlayer.pause()
        // Keep background task alive - user might resume soon
    }

    func stop() {
        audioPlayer.clearQueue()
        endBackgroundTask()
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func seekToProgress(_ progress: Double) {
        audioPlayer.seekToProgress(progress)
    }

    func seekBackward(seconds: Double) {
        let newTime = max(0, currentTime - seconds)
        audioPlayer.seek(to: newTime)
    }

    func seekForward(seconds: Double) {
        let newTime = min(duration, currentTime + seconds)
        audioPlayer.seek(to: newTime)
    }

    func setPlaybackRate(_ rate: Float) {
        audioPlayer.setPlaybackRate(rate)
    }

    func nextParagraph() {
        let nextIndex = currentParagraphIndex + 1
        if nextIndex < paragraphs.count {
            Task {
                await playParagraph(at: nextIndex)
            }
        }
    }

    func previousParagraph() {
        if currentTime > 3 {
            audioPlayer.seek(to: 0)
        } else if currentParagraphIndex > 0 {
            Task {
                await playParagraph(at: currentParagraphIndex - 1)
            }
        }
    }

    func jumpToParagraph(_ index: Int) {
        guard index >= 0 && index < paragraphs.count else { return }
        Task {
            await playParagraph(at: index)
        }
        updateCurrentChapterFromMap(index)
    }

    func jumpToChapter(_ chapter: BookIndex) {
        guard let paragraphIndex = findParagraphForChapter(chapter) else {
            return
        }
        jumpToParagraph(paragraphIndex)
    }

    func onUserScroll() {
        autoScrollEnabled = false
    }

    func scrollToPlaying() {
        autoScrollEnabled = true
        scrollBackDirection = nil
    }

    // MARK: - Private Methods

    private func playParagraph(at index: Int) async {
        guard index >= 0 && index < paragraphs.count else { return }

        print("🎯 playParagraph: Starting paragraph \(index)")

        // 1. 取消当前加载任务
        currentLoadTask?.cancel()
        currentLoadTask = nil

        // 2. 取消预加载任务
        preloadTask?.cancel()
        preloadTask = nil

        // 3. 取消 TTS 服务的请求
        await ttsService.cancelCurrentRequest()

        // 4. 清空播放器队列
        audioPlayer.clearQueue()

        currentParagraphIndex = index
        currentSegmentIndex = 0
        highlightedWordIndex = nil
        currentGlobalWordIndex = 0

        // 5. 检查是否已预加载此段落
        if preloadedParagraphIndex == index,
           let state = paragraphStates[index],
           state.status == .ready,
           !state.segments.isEmpty {
            print("🎯 playParagraph: Using preloaded paragraph \(index)")
            // 使用预加载的数据，直接播放
            for segment in state.segments {
                audioPlayer.loadSegment(segment)
            }
            preloadedParagraphIndex = -1
            // 开始预加载下一个
            startPreloadingNextParagraph(after: index)
        } else {
            // 清空预加载状态
            preloadedParagraphIndex = -1

            // 清空之前的段落缓存（保留当前和下一个）
            cleanupOtherParagraphs(currentIndex: index)

            // 重置当前段落状态
            paragraphStates[index]?.status = .pending
            paragraphStates[index]?.segments = []
            paragraphStates[index]?.totalDuration = 0

            // 开始加载当前段落
            isLoading = true
            await loadParagraphForPlayback(at: index)
            isLoading = false
        }
    }

    /// 加载段落用于播放（加载完成后触发预加载下一个）
    private func loadParagraphForPlayback(at index: Int) async {
        guard index >= 0 && index < paragraphs.count else { return }

        print("📥 loadParagraphForPlayback: Loading paragraph \(index)")

        let text = paragraphs[index]
        paragraphStates[index]?.status = .loading

        do {
            try await ttsService.generateTTSForParagraph(
                paragraphIndex: index,
                text: text,
                voice: selectedVoice,
                speed: 1.0,
                language: selectedLanguage
            ) { [weak self] segment in
                await MainActor.run {
                    self?.onSegmentLoaded(segment, paragraphIndex: index)
                }
            }

            paragraphStates[index]?.status = .ready
            print("✅ loadParagraphForPlayback: Paragraph \(index) loaded successfully")

            // 当前段落加载完成，开始预加载下一个
            startPreloadingNextParagraph(after: index)

        } catch LocalTTSError.cancelled {
            print("❌ loadParagraphForPlayback: Paragraph \(index) cancelled")
            if paragraphStates[index]?.status == .loading {
                paragraphStates[index]?.status = .pending
                paragraphStates[index]?.segments = []
                paragraphStates[index]?.totalDuration = 0
            }
        } catch {
            print("❌ loadParagraphForPlayback: Paragraph \(index) error: \(error)")
            paragraphStates[index]?.status = .error(error.localizedDescription)
            self.error = error.localizedDescription
        }
    }

    /// 开始预加载下一个段落（串行，在当前段落加载完成后调用）
    private func startPreloadingNextParagraph(after index: Int) {
        let nextIndex = index + 1
        guard nextIndex < paragraphs.count else {
            print("📦 startPreloadingNextParagraph: No more paragraphs to preload")
            return
        }

        // 如果已经预加载过，跳过
        if preloadedParagraphIndex == nextIndex {
            print("📦 startPreloadingNextParagraph: Paragraph \(nextIndex) already preloaded")
            return
        }

        print("📦 startPreloadingNextParagraph: Starting preload for paragraph \(nextIndex)")

        preloadTask = Task { [weak self] in
            await self?.preloadParagraph(at: nextIndex)
        }
    }

    /// 预加载段落（只生成不播放）
    private func preloadParagraph(at index: Int) async {
        guard index >= 0 && index < paragraphs.count else { return }

        // 检查是否已取消
        if Task.isCancelled {
            print("📦 preloadParagraph: Task cancelled before starting")
            return
        }

        print("📦 preloadParagraph: Preloading paragraph \(index)")

        // 重置段落状态
        paragraphStates[index]?.status = .pending
        paragraphStates[index]?.segments = []
        paragraphStates[index]?.totalDuration = 0

        let text = paragraphs[index]
        paragraphStates[index]?.status = .loading

        do {
            try await ttsService.generateTTSForParagraph(
                paragraphIndex: index,
                text: text,
                voice: selectedVoice,
                speed: 1.0,
                language: selectedLanguage
            ) { [weak self] segment in
                await MainActor.run {
                    // 预加载的 segment 只存储，不发送给播放器
                    self?.onSegmentPreloaded(segment, paragraphIndex: index)
                }
            }

            // 检查是否取消
            if Task.isCancelled {
                print("📦 preloadParagraph: Task cancelled after completion")
                return
            }

            paragraphStates[index]?.status = .ready
            preloadedParagraphIndex = index
            print("✅ preloadParagraph: Paragraph \(index) preloaded successfully")

        } catch LocalTTSError.cancelled {
            print("📦 preloadParagraph: Paragraph \(index) cancelled")
            if paragraphStates[index]?.status == .loading {
                paragraphStates[index]?.status = .pending
                paragraphStates[index]?.segments = []
                paragraphStates[index]?.totalDuration = 0
            }
        } catch {
            print("📦 preloadParagraph: Paragraph \(index) error: \(error)")
            // 预加载失败不影响当前播放，只记录
            paragraphStates[index]?.status = .pending
        }
    }

    /// 预加载的 segment 只存储不播放
    private func onSegmentPreloaded(_ segment: AudioSegment, paragraphIndex: Int) {
        // 防止重复添加
        let existing = paragraphStates[paragraphIndex]?.segments ?? []
        if existing.contains(where: { $0.segmentIndex == segment.segmentIndex }) {
            return
        }

        paragraphStates[paragraphIndex]?.segments.append(segment)
        paragraphStates[paragraphIndex]?.totalDuration += segment.duration
        print("📦 onSegmentPreloaded: Stored segment \(segment.segmentIndex) for paragraph \(paragraphIndex)")
    }

    private func onSegmentLoaded(_ segment: AudioSegment, paragraphIndex: Int) {
        // 防止重复添加
        let existing = paragraphStates[paragraphIndex]?.segments ?? []
        if existing.contains(where: { $0.segmentIndex == segment.segmentIndex }) {
            return
        }

        paragraphStates[paragraphIndex]?.segments.append(segment)
        paragraphStates[paragraphIndex]?.totalDuration += segment.duration

        // 如果是当前段落，立即发送给播放器
        if paragraphIndex == currentParagraphIndex {
            audioPlayer.loadSegment(segment)

            if segment.segmentIndex == 0 {
                paragraphStates[paragraphIndex]?.status = .streaming
            }
        }
    }

    private func onSegmentComplete() {
        // Segment 播放完成
    }

    private func onPlaybackComplete() {
        let nextIndex = currentParagraphIndex + 1

        if nextIndex < paragraphs.count {
            Task {
                await playParagraph(at: nextIndex)
            }
        } else {
            isPlaying = false
            endBackgroundTask()
        }
    }

    // MARK: - Background Task Management

    /// Start background task when playback begins - keeps app alive during entire playback session
    private func beginBackgroundTask() {
        guard backgroundTaskId == .invalid else {
            print("🔄 Background task already active")
            return
        }

        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "CastReader Audio Playback") { [weak self] in
            // Called when time is about to expire - restart it to keep alive
            print("⚠️ Background task time expiring, restarting...")
            self?.restartBackgroundTask()
        }

        if backgroundTaskId != .invalid {
            print("🔄 Started background task: \(backgroundTaskId.rawValue)")
        }
    }

    /// Restart background task to extend time
    private func restartBackgroundTask() {
        let oldTaskId = backgroundTaskId
        backgroundTaskId = .invalid

        // Start new task before ending old one
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "CastReader Audio Playback") { [weak self] in
            print("⚠️ Background task time expiring, restarting...")
            self?.restartBackgroundTask()
        }

        // End old task
        if oldTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(oldTaskId)
        }

        print("🔄 Restarted background task: \(backgroundTaskId.rawValue)")
    }

    private func endBackgroundTask() {
        if backgroundTaskId != .invalid {
            print("✅ Ending background task: \(backgroundTaskId.rawValue)")
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
    }

    func clearAllAudioCache() {
        var cleanedCount = 0
        for (index, _) in paragraphStates {
            if index == currentParagraphIndex { continue }
            if !(paragraphStates[index]?.segments.isEmpty ?? true) {
                paragraphStates[index]?.segments = []
                paragraphStates[index]?.totalDuration = 0
                paragraphStates[index]?.status = .pending
                cleanedCount += 1
            }
        }
    }

    private func cleanupOtherParagraphs(currentIndex: Int) {
        let nextIndex = currentIndex + 1  // 保留预加载的下一个段落
        for (index, _) in paragraphStates {
            // 保留当前段落和预加载的下一个段落
            if index != currentIndex && index != nextIndex && !(paragraphStates[index]?.segments.isEmpty ?? true) {
                paragraphStates[index]?.segments = []
                paragraphStates[index]?.status = .pending
                paragraphStates[index]?.totalDuration = 0
            }
        }
    }

    private func updateHighlightedWord(at time: Double) {
        guard !currentTimestamps.isEmpty else {
            highlightedWordIndex = nil
            currentGlobalWordIndex = 0
            return
        }

        guard let state = paragraphStates[currentParagraphIndex],
              !state.segments.isEmpty else {
            return
        }

        let localIdx = currentTimestamps.firstIndex { $0.endTime > time } ?? (currentTimestamps.count - 1)

        if highlightedWordIndex != localIdx {
            highlightedWordIndex = localIdx
        }

        let wordOffset = getWordOffset(forSegmentIndex: currentSegmentIndex)
        currentGlobalWordIndex = wordOffset + localIdx
    }

    private func getWordOffset(forSegmentIndex segmentIndex: Int) -> Int {
        guard let state = paragraphStates[currentParagraphIndex] else { return 0 }
        return state.segments
            .prefix(segmentIndex)
            .reduce(0) { $0 + $1.timestamps.count }
    }

    // MARK: - Chapter Mapping (优化版)

    /// 预建章节映射表
    private func buildChapterMapping() {
        paragraphToChapterMap = [:]

        var chapterRanges: [(chapterIndex: Int, startParagraph: Int)] = []

        for (i, chapter) in indices.enumerated() {
            if let paragraphIndex = findParagraphForChapter(chapter) {
                chapterRanges.append((i, paragraphIndex))
            }
        }

        // 按段落索引排序
        chapterRanges.sort { $0.startParagraph < $1.startParagraph }

        // 填充映射表
        var currentChapter = 0
        for paragraphIndex in 0..<paragraphs.count {
            // 检查是否进入新章节
            for range in chapterRanges {
                if range.startParagraph <= paragraphIndex {
                    currentChapter = range.chapterIndex
                }
            }
            paragraphToChapterMap[paragraphIndex] = currentChapter
        }
    }

    /// 从映射表快速查找章节
    private func updateCurrentChapterFromMap(_ paragraphIndex: Int) {
        if let chapterIndex = paragraphToChapterMap[paragraphIndex] {
            if currentChapterIndex != chapterIndex {
                currentChapterIndex = chapterIndex
                if chapterIndex < indices.count, let title = indices[chapterIndex].text {
                    chapterTitle = title
                }
            }
        }
    }

    func findParagraphForChapter(_ chapter: BookIndex) -> Int? {
        guard let href = chapter.href, !href.isEmpty else {
            return findParagraphByText(chapter.text)
        }

        var cleanHref = href
        if let hashIndex = href.lastIndex(of: "#") {
            cleanHref = String(href[href.index(after: hashIndex)...])
        }
        cleanHref = cleanHref.removingPercentEncoding ?? cleanHref

        // ID 精确匹配
        if let idx = parsedParagraphs.firstIndex(where: { $0.id == cleanHref }) {
            return idx
        }

        // ID 包含匹配
        if let idx = parsedParagraphs.firstIndex(where: {
            guard let id = $0.id else { return false }
            return id.contains(cleanHref) || cleanHref.contains(id)
        }) {
            return idx
        }

        return findParagraphByText(chapter.text)
    }

    private func findParagraphByText(_ text: String?) -> Int? {
        guard let text = text, !text.isEmpty else { return nil }

        let normalizedText = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        if let idx = parsedParagraphs.firstIndex(where: {
            $0.text.lowercased().contains(normalizedText)
        }) {
            return idx
        }

        if let idx = parsedParagraphs.firstIndex(where: {
            let prefix = String($0.text.prefix(30)).lowercased()
            return normalizedText.contains(prefix) && !prefix.isEmpty
        }) {
            return idx
        }

        return nil
    }

    func updateCurrentChapter(paragraphIndex: Int) {
        updateCurrentChapterFromMap(paragraphIndex)
    }
}
