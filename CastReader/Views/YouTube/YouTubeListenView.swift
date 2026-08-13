//
//  YouTubeListenView.swift
//  CastReader
//
//  Native subtitle transcript reader. The temporary extraction WKWebView is
//  never retained here and this surface never embeds or plays YouTube media.
//

import SwiftUI
import UIKit

struct YouTubeListenView: View {
    let document: ReadingDocument
    @ObservedObject var readVM: ReadAloudViewModel
    let refocusToken: Int

    @State private var followsPlayback = true

    private var transcript: YouTubeTranscriptDocument? {
        document.youtubeTranscript
    }

    var body: some View {
        Group {
            if let transcript {
                VStack(spacing: 0) {
                    YouTubeArtworkHeader(
                        transcript: transcript,
                        paragraphStartMs: currentStartMs,
                        cacheKey: YouTubeCacheStore.cacheKey(for: transcript),
                        paragraphIndexes: document.paragraphs
                            .filter {
                                $0.type.isReadable &&
                                    SpeechTextSanitizer.containsSpeakableContent(
                                        $0.resolvedSpeechText
                                    )
                            }
                            .map(\.id),
                        documentLanguage: document.language
                    )
                    Divider()
                    transcriptList(transcript)
                }
            } else {
                ContentUnavailableView(
                    AppLocalized("字幕稿不可用"),
                    systemImage: "captions.bubble",
                    description: Text(AppLocalized("请返回后重新解析这个视频"))
                )
            }
        }
        .background(AppTheme.background)
    }

    private func transcriptList(_ transcript: YouTubeTranscriptDocument) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(document.paragraphs) { paragraph in
                        transcriptRow(
                            paragraph,
                            videoId: transcript.metadata.videoId
                        )
                        .id(paragraph.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 5)
                    .onChanged { _ in followsPlayback = false }
            )
            .overlay(alignment: .bottomTrailing) {
                if !followsPlayback, readVM.currentParagraphIndex >= 0 {
                    Button {
                        followsPlayback = true
                        scrollToPlayback(proxy, animated: true)
                    } label: {
                        Label(AppLocalized("回到当前位置"), systemImage: "location.fill")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(AppTheme.border, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.primary)
                    .padding(14)
                    .accessibilityIdentifier("youtubeReturnToPlaybackButton")
                }
            }
            .onChange(of: readVM.currentParagraphIndex) { _ in
                guard followsPlayback else { return }
                scrollToPlayback(proxy, animated: true)
            }
            .onChange(of: refocusToken) { _ in
                followsPlayback = true
                scrollToPlayback(proxy, animated: true)
            }
            .task(id: document.contentSessionKey) {
                // The resume/timestamp index can be assigned before this lazy
                // list mounts, in which case no onChange event is emitted.
                await Task.yield()
                guard followsPlayback else { return }
                scrollToPlayback(proxy, animated: false)
            }
        }
    }

    private func transcriptRow(
        _ paragraph: ReadingParagraph,
        videoId: String
    ) -> some View {
        let isCurrent = paragraph.id == readVM.currentParagraphIndex
        let displayedText = readVM.displayText(for: paragraph.id)
        return HStack(alignment: .top, spacing: 10) {
            Button {
                YouTubeLinkOpener.open(
                    videoId: videoId,
                    startMs: paragraph.startMs ?? 0
                )
            } label: {
                Text(Self.timestamp(paragraph.startMs ?? 0))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isCurrent ? Color.white : AppTheme.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        isCurrent ? AppTheme.primary : AppTheme.primary.opacity(0.11),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                Text(
                    String(
                        format: AppLocalized("回到 YouTube %@"),
                        Self.timestamp(paragraph.startMs ?? 0)
                    )
                )
            )

            VStack(alignment: .leading, spacing: 3) {
                if let speaker = paragraph.speaker?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ), !speaker.isEmpty,
                   !Self.hasVisibleSpeakerPrefix(
                       paragraph.text,
                       speaker: speaker
                   ) || displayedText != paragraph.text {
                    Text(speaker)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(
                            isCurrent ? AppTheme.primary : AppTheme.secondaryForeground
                        )
                        .accessibilityIdentifier(
                            "youtubeTranscriptSpeaker_\(paragraph.id)"
                        )
                }
                ReaderTextView(
                    text: displayedText,
                    highlightRange: isCurrent ? readVM.highlightRange : nil,
                    isCurrent: isCurrent,
                    fontSize: 18,
                    highlightColor: readVM.highlightUIColor,
                    onReady: { _ in }
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 10)
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isCurrent ? AppTheme.primary : Color.clear)
                    .frame(width: 4)
                    .padding(.vertical, 3)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                followsPlayback = true
                readVM.jump(to: paragraph.id)
            }
            .accessibilityIdentifier("youtubeTranscriptParagraph_\(paragraph.id)")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 2)
        .background(
            isCurrent ? AppTheme.primary.opacity(0.065) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .animation(.easeInOut(duration: 0.2), value: isCurrent)
    }

    private var currentStartMs: Int {
        let index = readVM.currentParagraphIndex
        guard document.paragraphs.indices.contains(index) else {
            return document.paragraphs.first?.startMs ?? 0
        }
        return document.paragraphs[index].startMs ?? 0
    }

    private func scrollToPlayback(
        _ proxy: ScrollViewProxy,
        animated: Bool
    ) {
        let index = readVM.currentParagraphIndex
        guard index >= 0 else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.30))
            }
        } else {
            proxy.scrollTo(index, anchor: UnitPoint(x: 0.5, y: 0.30))
        }
    }

    static func timestamp(_ milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1_000)
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private static func hasVisibleSpeakerPrefix(
        _ text: String,
        speaker: String
    ) -> Bool {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix(">>") || value.hasPrefix("＞＞") {
            value = String(value.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let folded = value.precomposedStringWithCompatibilityMapping.lowercased()
        let name = speaker.precomposedStringWithCompatibilityMapping.lowercased()
        return folded.hasPrefix(name + ":") || folded.hasPrefix(name + "：")
    }
}

private struct YouTubeArtworkHeader: View {
    let transcript: YouTubeTranscriptDocument
    let paragraphStartMs: Int
    let cacheKey: YouTubeTranscriptCacheKey
    let paragraphIndexes: [Int]
    let documentLanguage: String

    @StateObject private var loader = YouTubeArtworkLoader()
    @StateObject private var cacheBadge = YouTubeCacheBadgeLoader()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var switcher = YouTubeCaptionLanguageSwitcher.shared
    @ObservedObject private var languageManager = AppLanguageManager.shared
    @Environment(\.displayScale) private var displayScale

    private var frame: YouTubeStoryboardFrame? {
        transcript.storyboard?.frame(atMs: paragraphStartMs)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                YouTubeLinkOpener.open(
                    videoId: transcript.metadata.videoId,
                    startMs: paragraphStartMs
                )
            } label: {
                ZStack(alignment: .bottomTrailing) {
                    artwork
                        .frame(maxWidth: .infinity)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(Color.black.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Text(YouTubeListenView.timestamp(paragraphStartMs))
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.72), in: Capsule())
                        .padding(9)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(AppLocalized("回到 YouTube 当前时间")))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(transcript.metadata.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.foreground)
                    .lineLimit(2)
                Spacer(minLength: 6)
                if cacheBadge.coverage.isComplete {
                    Label(AppLocalized("已缓存"), systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("youtubeOfflineCacheBadge")
                        .accessibilityLabel(Text(AppLocalized("已缓存")))
                        .accessibilityValue(Text(verbatim: cacheBadgeAccessibilityValue))
                } else if cacheBadge.coverage.hasAny {
                    Label(AppLocalized("部分已缓存"), systemImage: "arrow.down.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityIdentifier("youtubeOfflineCacheBadge")
                        .accessibilityLabel(Text(AppLocalized("部分已缓存")))
                        .accessibilityValue(Text(verbatim: cacheBadgeAccessibilityValue))
                }
            }
            HStack(spacing: 5) {
                if let channel = transcript.metadata.channelName, !channel.isEmpty {
                    Text(channel)
                    Text("·")
                }
                captionLanguageControl
            }
            .font(.caption)
            .foregroundStyle(AppTheme.mutedForeground)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .task(id: artworkTaskID) {
            await loader.load(
                storyboard: transcript.storyboard,
                frame: frame,
                thumbnailURL: transcript.metadata.thumbnailURL,
                cacheKey: cacheKey,
                requestToken: artworkTaskID
            )
        }
        .task(id: cacheBadgeTaskID) {
            scheduleCacheBadgeRefresh(debounceNanoseconds: 0)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .castReaderYouTubeAudioCacheChanged
            )
        ) { notification in
            guard notification.object as? String == cacheKey.storageKey else { return }
            scheduleCacheBadgeRefresh()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .castReaderYouTubeArtworkCacheChanged
            )
        ) { notification in
            guard notification.object as? String == cacheKey.storageKey else { return }
            // Artwork completion is a user-visible state transition. Refresh
            // it immediately even while TTS segment writes are still arriving.
            scheduleCacheBadgeRefresh(debounceNanoseconds: 0)
        }
        .onDisappear { cacheBadge.cancel() }
    }

    /// The picker only earns its place when there is somewhere else to go.
    /// A single-track video keeps the plain "字幕稿" label.
    @ViewBuilder
    private var captionLanguageControl: some View {
        let options = transcript.switchableTracks
        if options.count > 1 {
            Button {
                ProductAnalytics.shared.track(
                    .youtubeCaptionLanguageOpen,
                    context: AnalyticsEventContext(
                        productArea: .reader,
                        surface: "youtube_caption_language",
                        entryPoint: "youtube_reader"
                    ),
                    properties: .init(
                        trackCount: options.count,
                        playableTrackCount: options.filter(\.isPlayable).count
                    )
                )
                switcher.presentPicker(for: transcript.metadata.videoId)
            } label: {
                HStack(spacing: 3) {
                    Text(currentTrackName(among: options))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(AppTheme.primary)
            }
            .buttonStyle(.plain)
            .disabled(switcher.phase.isSwitching)
            .accessibilityIdentifier("youtubeCaptionLanguageChip")
            .accessibilityLabel(Text(AppLocalized("字幕语言")))
        } else {
            Text(AppLocalized("字幕稿"))
        }
    }

    private func currentTrackName(among options: [YouTubeCaptionTrackOption]) -> String {
        let current = options.first { $0.matches(transcript.track) }
        let option = current ?? YouTubeCaptionTrackOption(
            id: transcript.track.baseURL,
            languageCode: transcript.track.languageCode,
            name: transcript.track.name,
            kind: transcript.track.isAutomatic ? "asr" : "manual"
        )
        return option.displayName(locale: languageManager.locale)
    }

    private func scheduleCacheBadgeRefresh(
        debounceNanoseconds: UInt64 = 350_000_000
    ) {
        cacheBadge.schedule(
            cacheKey: cacheKey,
            voiceCode: selectedVoiceCode,
            paragraphIndexes: paragraphIndexes,
            identity: cacheBadgeTaskID,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    private var selectedVoiceCode: String {
        settings.voice(for: documentLanguage)
    }

    private var cacheBadgeAccessibilityValue: String {
        if cacheBadge.coverage.cachedArtworkResourceCount
            == cacheBadge.coverage.requiredArtworkResourceCount {
            return "artwork complete"
        }
        return "artwork \(cacheBadge.coverage.cachedArtworkResourceCount)/" +
            "\(cacheBadge.coverage.requiredArtworkResourceCount)"
    }

    private var cacheBadgeTaskID: String {
        let artworkRequirement = transcript.storyboard.map {
            "storyboard:\($0.sheetCount)"
        } ?? "thumbnail:\(transcript.metadata.thumbnailURL?.isEmpty == false)"
        return "\(cacheKey.storageKey)|\(selectedVoiceCode)|\(artworkRequirement)"
    }

    private var artwork: some View {
        GeometryReader { proxy in
            let presentation = YouTubeArtworkQualityPolicy.presentation(
                storyboard: transcript.storyboard,
                hasThumbnail: transcript.metadata.thumbnailURL?.isEmpty == false,
                displayWidthPoints: proxy.size.width,
                displayScale: displayScale
            )
            ZStack(alignment: .bottomLeading) {
                mainArtwork(for: presentation)

                if presentation == .coverWithStoryboardInset,
                   let storyboard = transcript.storyboard,
                   let frameImage = loader.frameImage,
                   loader.coverImage != nil {
                    let insetWidth = YouTubeArtworkQualityPolicy.insetWidthPoints(
                        tileWidth: storyboard.tileWidth,
                        displayScale: displayScale
                    )
                    Image(uiImage: frameImage)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(
                            width: insetWidth,
                            height: insetWidth * 9 / 16
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(.white.opacity(0.92), lineWidth: 1.5)
                        }
                        .shadow(color: .black.opacity(0.34), radius: 5, y: 2)
                        .padding(10)
                        .id(loader.frameToken)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.15), value: loader.frameToken)
                }
            }
        }
    }

    @ViewBuilder
    private func mainArtwork(
        for presentation: YouTubeArtworkPresentation
    ) -> some View {
        if let image = preferredMainImage(for: presentation) {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .id(mainArtworkToken(for: presentation))
                .transition(.opacity)
                .animation(
                    .easeInOut(duration: 0.15),
                    value: mainArtworkToken(for: presentation)
                )
        } else {
            ZStack {
                LinearGradient(
                    colors: [Color.black.opacity(0.85), Color.red.opacity(0.68)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if loader.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.88))
                }
            }
        }
    }

    private func preferredMainImage(
        for presentation: YouTubeArtworkPresentation
    ) -> UIImage? {
        switch presentation {
        case .coverOnly, .coverWithStoryboardInset:
            return loader.coverImage ?? loader.frameImage
        case .storyboardOnly, .storyboardFullWidth:
            return loader.frameImage ?? loader.coverImage
        }
    }

    private func mainArtworkToken(
        for presentation: YouTubeArtworkPresentation
    ) -> String {
        switch presentation {
        case .coverOnly, .coverWithStoryboardInset:
            return loader.coverImage == nil ? loader.frameToken : "cover"
        case .storyboardOnly, .storyboardFullWidth:
            return loader.frameImage == nil ? "cover" : loader.frameToken
        }
    }

    private var artworkTaskID: String {
        if let frame {
            return "\(frame.sheetIndex)-\(Int(frame.cropRect.minX))-\(Int(frame.cropRect.minY))"
        }
        return "thumbnail"
    }
}

@MainActor
private final class YouTubeCacheBadgeLoader: ObservableObject {
    @Published private(set) var coverage = YouTubeOfflineCacheCoverage.none(
        totalParagraphs: 0
    )

    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var refreshPending = false
    private var pendingDebounceNanoseconds = UInt64.max

    deinit { task?.cancel() }

    func schedule(
        cacheKey: YouTubeTranscriptCacheKey,
        voiceCode: String,
        paragraphIndexes: [Int],
        identity: String,
        debounceNanoseconds: UInt64
    ) {
        if currentIdentity != identity {
            generation &+= 1
            task?.cancel()
            task = nil
            currentIdentity = identity
            refreshPending = false
            pendingDebounceNanoseconds = UInt64.max
        }

        refreshPending = true
        pendingDebounceNanoseconds = min(
            pendingDebounceNanoseconds,
            debounceNanoseconds
        )
        guard task == nil else { return }

        let expectedGeneration = generation
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.generation == expectedGeneration,
                      self.currentIdentity == identity else { return }
                let delay = self.pendingDebounceNanoseconds == UInt64.max
                    ? debounceNanoseconds
                    : self.pendingDebounceNanoseconds
                self.pendingDebounceNanoseconds = UInt64.max
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard !Task.isCancelled,
                      self.generation == expectedGeneration,
                      self.currentIdentity == identity else { return }

                // Clear before the actor hop so a notification received while
                // the cache is being inspected schedules exactly one trailing
                // refresh instead of cancelling this in-flight result.
                self.refreshPending = false
                let refreshed: YouTubeOfflineCacheCoverage
                if let cache = YouTubeCacheProvider.shared {
                    refreshed = await cache.offlineCacheCoverage(
                        for: cacheKey,
                        voiceCode: voiceCode,
                        paragraphIndexes: paragraphIndexes
                    )
                } else {
                    refreshed = .none(totalParagraphs: paragraphIndexes.count)
                }
                guard !Task.isCancelled,
                      self.generation == expectedGeneration,
                      self.currentIdentity == identity else { return }
                self.coverage = refreshed
                guard self.refreshPending else {
                    self.task = nil
                    return
                }
            }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        currentIdentity = nil
        refreshPending = false
        pendingDebounceNanoseconds = UInt64.max
    }

    private var currentIdentity: String?
}

@MainActor
private final class YouTubeArtworkLoader: ObservableObject {
    @Published private(set) var coverImage: UIImage?
    @Published private(set) var frameImage: UIImage?
    @Published private(set) var isLoading = true
    @Published private(set) var frameToken = ""
    private var task: Task<Void, Never>?
    /// Unlike `task`, this lifetime is not tied to the current paragraph. A
    /// frame change may cancel its foreground image request, but must not abort
    /// the all-sheets offline warmup halfway through.
    private var offlineWarmTask: Task<Void, Never>?
    private var offlineWarmIdentity: String?

    deinit {
        task?.cancel()
        offlineWarmTask?.cancel()
    }

    func load(
        storyboard: YouTubeStoryboard?,
        frame: YouTubeStoryboardFrame?,
        thumbnailURL: String?,
        cacheKey: YouTubeTranscriptCacheKey,
        requestToken: String
    ) async {
        task?.cancel()
        isLoading = coverImage == nil && frameImage == nil
        let task = Task { [weak self] in
            if self?.coverImage == nil,
               let data = await Self.thumbnailData(
                   remoteURL: thumbnailURL,
                   cacheKey: cacheKey
               ),
               !Task.isCancelled,
               let cover = UIImage(data: data) {
                self?.coverImage = cover
            }

            let storyboardImage: UIImage?
            if let storyboard,
               let frame,
               let data = await Self.storyboardData(
                   storyboard: storyboard,
                   sheetIndex: frame.sheetIndex,
                   cacheKey: cacheKey
               ),
               !Task.isCancelled,
               let sheet = UIImage(data: data) {
                storyboardImage = Self.crop(sheet, to: frame.cropRect)
            } else {
                storyboardImage = nil
            }
            guard !Task.isCancelled else { return }
            // A transient sheet failure must keep the last visible frame rather
            // than flashing the placeholder on every paragraph boundary.
            if let storyboardImage {
                self?.frameImage = storyboardImage
                self?.frameToken = requestToken
            }
            self?.isLoading = false

            if let storyboard, let frame {
                for index in [frame.sheetIndex - 1, frame.sheetIndex + 1]
                    where index >= 0 && index < storyboard.sheetCount {
                    guard !Task.isCancelled else { return }
                    _ = await Self.storyboardData(
                        storyboard: storyboard,
                        sheetIndex: index,
                        cacheKey: cacheKey
                    )
                }
            }
        }
        self.task = task
        await task.value
        scheduleOfflineWarm(
            storyboard: storyboard,
            thumbnailURL: thumbnailURL,
            cacheKey: cacheKey
        )
    }

    private func scheduleOfflineWarm(
        storyboard: YouTubeStoryboard?,
        thumbnailURL: String?,
        cacheKey: YouTubeTranscriptCacheKey
    ) {
        let identity = "\(cacheKey.storageKey)|\(storyboard?.sheetCount ?? -1)"
        guard offlineWarmIdentity != identity else { return }
        offlineWarmTask?.cancel()
        offlineWarmIdentity = identity

        // The visible frame/thumbnail above has already resolved or degraded,
        // so this never gates first audio. Missing resources retry with bounded
        // backoff during the same reader session. A storyboard pass emits one
        // cache notification instead of one full badge rescan per sheet.
        offlineWarmTask = Task { [weak self] in
            let retryDelays: [UInt64] = [
                0,
                2_000_000_000,
                6_000_000_000,
                18_000_000_000,
                54_000_000_000,
                60_000_000_000,
            ]
            for delay in retryDelays {
                guard !Task.isCancelled else { return }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                    guard !Task.isCancelled else { return }
                }

                let storyboardIsComplete: Bool
                if let storyboard,
                   storyboard.isValid,
                   storyboard.sheetCount <= YouTubeStoryboard.maximumSheetCount,
                   let cache = YouTubeCacheProvider.shared {
                    let missing = await cache.missingStoryboardSheetIndexes(
                        for: storyboard,
                        cacheKey: cacheKey
                    )
                    var changed = false
                    var failed = false
                    for sheetIndex in missing {
                        guard !Task.isCancelled else { return }
                        guard await Self.storyboardData(
                            storyboard: storyboard,
                            sheetIndex: sheetIndex,
                            cacheKey: cacheKey,
                            notifyChange: false
                        ) != nil else {
                            failed = true
                            break
                        }
                        changed = true
                    }
                    if changed {
                        await cache.notifyArtworkCacheChanged(for: cacheKey)
                    }
                    storyboardIsComplete = !failed
                } else {
                    storyboardIsComplete = true
                }
                let thumbnailIsComplete: Bool
                if thumbnailURL?.isEmpty == false {
                    thumbnailIsComplete = await Self.thumbnailData(
                        remoteURL: thumbnailURL,
                        cacheKey: cacheKey
                    ) != nil
                } else {
                    thumbnailIsComplete = true
                }
                if storyboardIsComplete && thumbnailIsComplete { return }
            }

            // Allow a later frame/load event to start a fresh retry series.
            if self?.offlineWarmIdentity == identity {
                self?.offlineWarmIdentity = nil
            }
        }
    }

    private static func storyboardData(
        storyboard: YouTubeStoryboard,
        sheetIndex: Int,
        cacheKey: YouTubeTranscriptCacheKey,
        notifyChange: Bool = true
    ) async -> Data? {
        if let cache = YouTubeCacheProvider.shared,
           let cached = await cache.storyboardSheet(
               sheetIndex: sheetIndex,
               for: cacheKey
           ), UIImage(data: cached) != nil {
            return cached
        }
        guard let rawURL = storyboard.sheetURLString(for: sheetIndex),
              let data = await downloadStillImage(rawURL) else { return nil }
        if let cache = YouTubeCacheProvider.shared {
            do {
                try await cache.storeStoryboardSheet(
                    data,
                    sheetIndex: sheetIndex,
                    for: cacheKey,
                    notifyChange: notifyChange
                )
            } catch {
                return nil
            }
        }
        return data
    }

    private static func thumbnailData(
        remoteURL: String?,
        cacheKey: YouTubeTranscriptCacheKey
    ) async -> Data? {
        if let cache = YouTubeCacheProvider.shared,
           let cached = await cache.thumbnail(
               for: cacheKey,
               minimumPixelWidth: 640,
               minimumPixelHeight: 360
           ),
           UIImage(data: cached) != nil {
            return cached
        }

        // Prefer the page-selected URL here; extraction already chooses the
        // highest declared thumbnail candidate. Requiring at least
        // 640x360 evicts old low-resolution cache entries without touching the
        // transcript, generated TTS, or reading progress.
        guard let remoteURL else { return nil }
        if let data = await downloadStillImage(
            remoteURL,
            minimumPixels: (width: 640, height: 360)
        ) {
            if let cache = YouTubeCacheProvider.shared {
                try? await cache.storeThumbnail(data, for: cacheKey)
            }
            return data
        }
        // Preserve a lower-resolution cover as a last resort for videos whose
        // publishers did not provide HD artwork; it is still preferable to a
        // blank header and remains visually separate from the dynamic frame.
        guard let data = await downloadStillImage(remoteURL) else { return nil }
        if let cache = YouTubeCacheProvider.shared {
            try? await cache.storeThumbnail(data, for: cacheKey)
        }
        return data
    }

    private static func downloadStillImage(
        _ rawURL: String,
        minimumPixels: (width: Int, height: Int)? = nil
    ) async -> Data? {
        guard let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              data.count <= 20 * 1_024 * 1_024,
              let image = UIImage(data: data),
              let pixels = image.cgImage.map({
                  (width: $0.width, height: $0.height)
              }) else { return nil }
        if let minimumPixels,
           (pixels.width < minimumPixels.width ||
            pixels.height < minimumPixels.height) {
            return nil
        }
        return data
    }

    private static func crop(_ image: UIImage, to rect: CGRect) -> UIImage? {
        guard let cgImage = image.cgImage else { return image }
        let imageRect = CGRect(
            x: 0,
            y: 0,
            width: cgImage.width,
            height: cgImage.height
        )
        let integral = rect.integral.intersection(imageRect)
        guard integral.width > 0,
              integral.height > 0,
              let cropped = cgImage.cropping(to: integral) else { return nil }
        return UIImage(cgImage: cropped, scale: image.scale, orientation: .up)
    }
}
