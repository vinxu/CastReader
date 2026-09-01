//
//  YouTubeHomeView.swift
//  CastReader
//
//  Discovery surface for YouTube subtitle transcripts: a one-time guide,
//  explicit paste/share actions and a dedicated local listening history.
//

import SwiftUI
import UIKit

enum YouTubeHistoryRefreshIdentity {
    static func value(for records: [HistoryRecord]) -> String {
        var identities: [String] = []
        identities.reserveCapacity(records.count)
        for record in records {
            identities.append(
                record.id + ":" +
                String(record.lastOpenedAt.timeIntervalSince1970) + ":" +
                (record.sourceURL ?? "-")
            )
        }
        return identities.joined(separator: "|")
    }
}

enum YouTubeHistoryMonitoringPolicy {
    static func isActive(
        isVisible: Bool,
        isSurfaceEnabled: Bool,
        isSceneActive: Bool
    ) -> Bool {
        isVisible && isSurfaceEnabled && isSceneActive
    }
}

/// A zero-layout probe owns the NotificationCenter subscription only while the
/// surface is active. Keeping it behind the page avoids waking a hidden Home
/// without changing the page's own structural identity.
private struct YouTubeCacheChangeListener: ViewModifier {
    let isActive: Bool
    let onArtworkChanged: (Notification) -> Void

    func body(content: Content) -> some View {
        content.background {
            if isActive {
                YouTubeCacheChangeProbe(
                    onArtworkChanged: onArtworkChanged
                )
            }
        }
    }
}

/// Keep the page's structural identity stable while monitoring is toggled.
/// Wrapping `content` in an if/else modifier here creates an appearance loop:
/// `onAppear` enables the wrapper, replacing the page, whose `onDisappear`
/// disables it again. A zero-layout sibling owns the subscription instead.
private struct YouTubeCacheChangeProbe: View {
    let onArtworkChanged: (Notification) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .castReaderYouTubeArtworkCacheChanged
                ),
                perform: onArtworkChanged
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

enum YouTubeHomeShelfProjection: Equatable {
    case empty
    case content(items: [HistoryRecord], hasMore: Bool)
}

/// Pure Home projection: keep YouTube out of the generic Continue rail while
/// making the current listen, unfinished videos and recent videos predictable.
/// The full YouTube page deliberately keeps the complete history.
enum YouTubeHomeShelfContract {
    static let maximumItemCount = 3
    static let completionThreshold = 0.999

    static func project(
        records: [HistoryRecord],
        activeDocumentID: String?,
        maximumItemCount: Int = YouTubeHomeShelfContract.maximumItemCount
    ) -> YouTubeHomeShelfProjection {
        let routeableRecords: [(index: Int, record: HistoryRecord)] = records
            .enumerated()
            .compactMap { element in
            let (index, record) = element
            guard record.sourceKind == .youtube,
                  let sourceURL = record.sourceURL,
                  YouTubeURLParser.parse(sourceURL) != nil else { return nil }
            return (index: index, record: record)
        }
        let candidates = routeableRecords.sorted { lhs, rhs in
            let lhsBucket = priorityBucket(
                for: lhs.record,
                activeDocumentID: activeDocumentID
            )
            let rhsBucket = priorityBucket(
                for: rhs.record,
                activeDocumentID: activeDocumentID
            )
            if lhsBucket != rhsBucket { return lhsBucket < rhsBucket }
            if lhs.record.lastOpenedAt != rhs.record.lastOpenedAt {
                return lhs.record.lastOpenedAt > rhs.record.lastOpenedAt
            }
            return lhs.index < rhs.index
        }

        var seen = Set<String>()
        let uniqueRecords = candidates.compactMap { candidate in
            seen.insert(candidate.record.id).inserted ? candidate.record : nil
        }
        guard !uniqueRecords.isEmpty else { return .empty }

        let limit = max(0, maximumItemCount)
        return .content(
            items: Array(uniqueRecords.prefix(limit)),
            hasMore: uniqueRecords.count > limit
        )
    }

    private static func priorityBucket(
        for record: HistoryRecord,
        activeDocumentID: String?
    ) -> Int {
        if record.id == activeDocumentID { return 0 }
        if let progress = record.youtubeProgressFraction,
           progress > 0,
           progress < completionThreshold {
            return 1
        }
        return 2
    }
}

private struct YouTubeHistoryStatus: Equatable {
    let durationMs: Int?
    let percent: Int?
    let offlineCoverage: YouTubeOfflineCacheCoverage
}

private func youtubeHistoryDetail(
    for record: HistoryRecord,
    status: YouTubeHistoryStatus?
) -> String? {
    var parts: [String] = []
    if let durationMs = status?.durationMs ?? record.youtubeDurationMs,
       durationMs > 0 {
        parts.append(YouTubeListenView.timestamp(durationMs))
    }
    if let percent = record.youtubeProgressFraction.map({
        min(100, max(0, Int(($0 * 100).rounded())))
    }) ?? status?.percent {
        parts.append(String(format: AppLocalized("已听 %d%%"), percent))
    }
    if let status {
        if status.offlineCoverage.isComplete {
            parts.append(AppLocalized("已缓存"))
        } else if status.offlineCoverage.hasAny {
            parts.append(AppLocalized("部分已缓存"))
        } else {
            parts.append(AppLocalized("未缓存"))
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
}

@MainActor
private final class YouTubeHistoryStatusLoader: ObservableObject {
    @Published private(set) var statuses: [String: YouTubeHistoryStatus] = [:]

    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var currentIdentity: String?
    private struct Request {
        let records: [HistoryRecord]
        let identity: String
        let debounceNanoseconds: UInt64
    }
    private var pendingRequest: Request?

    deinit { task?.cancel() }

    func schedule(
        records: [HistoryRecord],
        identity: String,
        debounceNanoseconds: UInt64 = 450_000_000
    ) {
        generation &+= 1
        currentIdentity = identity
        pendingRequest = Request(
            records: records,
            identity: identity,
            debounceNanoseconds: debounceNanoseconds
        )
        startWorkerIfNeeded()
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        pendingRequest = nil
    }

    private func startWorkerIfNeeded() {
        guard task == nil else { return }
        task = Task { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while !Task.isCancelled, let request = pendingRequest {
            pendingRequest = nil
            let expectedGeneration = generation
            if request.debounceNanoseconds > 0 {
                try? await Task.sleep(
                    nanoseconds: request.debounceNanoseconds
                )
            }
            guard !Task.isCancelled else { break }
            // A newer request received during the debounce supersedes this one
            // before any disk/cache work begins.
            if pendingRequest != nil { continue }
            let refreshed = await Self.load(records: request.records)
            guard !Task.isCancelled else { break }
            if generation == expectedGeneration,
               currentIdentity == request.identity,
               pendingRequest == nil {
                statuses = refreshed
            }
        }
        task = nil
        if pendingRequest != nil { startWorkerIfNeeded() }
    }

    private static func load(
        records: [HistoryRecord]
    ) async -> [String: YouTubeHistoryStatus] {
        guard let cache = YouTubeCacheProvider.shared else { return [:] }
        var result: [String: YouTubeHistoryStatus] = [:]
        for (historyIndex, record) in records.enumerated() {
            guard !Task.isCancelled else { return result }
            let persistedPercent = record.youtubeProgressFraction.map {
                min(100, max(0, Int(($0 * 100).rounded())))
            }
            result[record.id] = YouTubeHistoryStatus(
                durationMs: record.youtubeDurationMs,
                percent: persistedPercent,
                offlineCoverage: .none(totalParagraphs: 0)
            )
            guard historyIndex < YouTubeCacheLimits.production.maxVideoCount else {
                continue
            }
            guard let rawURL = record.sourceURL,
                  let reference = YouTubeURLParser.parse(rawURL),
                  let key = await cache.mostRecentKey(videoId: reference.videoId),
                  let transcript = await cache.peekTranscript(for: key) else { continue }
            let readingDocument = YouTubeReadingDocumentBuilder.make(
                transcript: transcript,
                cacheHit: true
            )
            let readableParagraphs = readingDocument.paragraphs
                .filter {
                    $0.type.isReadable &&
                        SpeechTextSanitizer.containsSpeakableContent(
                            $0.resolvedSpeechText
                        )
                }
            let paragraphIndexes = readableParagraphs.map(\.id)
            let offlineCoverage = await cache.declaredOfflineCacheCoverage(
                for: key,
                transcript: transcript,
                voiceCode: AppSettings.shared.voice(for: readingDocument.language),
                paragraphIndexes: paragraphIndexes
            )
            result[record.id] = YouTubeHistoryStatus(
                durationMs: transcript.metadata.durationMs ?? record.youtubeDurationMs,
                percent: persistedPercent,
                offlineCoverage: offlineCoverage
            )
        }
        return result
    }
}

struct YouTubeHomeSection: View {
    let activeDocumentID: String?
    var isSurfaceEnabled = true

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var history = HistoryStore.shared
    @StateObject private var historyStatusLoader = YouTubeHistoryStatusLoader()
    @State private var isVisible = false
    @State private var notice: String?

    private var projection: YouTubeHomeShelfProjection {
        YouTubeHomeShelfContract.project(
            records: history.visibleRecords,
            activeDocumentID: activeDocumentID
        )
    }

    private var homeRecords: [HistoryRecord] {
        guard case .content(let items, _) = projection else { return [] }
        return items
    }

    private var isMonitoringActive: Bool {
        YouTubeHistoryMonitoringPolicy.isActive(
            isVisible: isVisible,
            isSurfaceEnabled: isSurfaceEnabled
                && !coordinator.isReaderPresented,
            isSceneActive: scenePhase == .active
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeLayout.headerToContent) {
            header
            switch projection {
            case .empty:
                emptyState
            case .content:
                LazyVStack(spacing: HomeLayout.itemGap) {
                    ForEach(homeRecords) { record in
                        YouTubeHomeShelfRow(
                            record: record,
                            status: historyStatusLoader.statuses[record.id],
                            isActive: record.id == activeDocumentID
                        ) {
                            guard let sourceURL = record.sourceURL else { return }
                            route(sourceURL, entry: .history)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("homeShelfSection.youtube")
        .onAppear {
            isVisible = true
            if isMonitoringActive {
                scheduleHistoryStatusRefresh(debounceNanoseconds: 0)
            }
        }
        .onDisappear {
            isVisible = false
            historyStatusLoader.cancel()
        }
        .onChange(of: isMonitoringActive) { active in
            if active {
                scheduleHistoryStatusRefresh(debounceNanoseconds: 0)
            } else {
                historyStatusLoader.cancel()
            }
        }
        .onChange(of: historyRefreshID) { _ in
            guard isMonitoringActive else { return }
            scheduleHistoryStatusRefresh(debounceNanoseconds: 0)
        }
        .modifier(
            YouTubeCacheChangeListener(
                isActive: isMonitoringActive,
                onArtworkChanged: { _ in scheduleHistoryStatusRefresh() }
            )
        )
        .alert(
            AppLocalized("无法打开"),
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )
        ) {
            Button(AppLocalized("好"), role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: HomeLayout.titleToSubtitle) {
            HStack(alignment: .center, spacing: HomeLayout.itemGap) {
                Text(AppLocalized("听 YouTube"))
                    .font(.headline)
                    .foregroundStyle(AppTheme.foreground)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if case .content = projection {
                    NavigationLink(destination: YouTubeHomeView()) {
                        Label(AppLocalized("粘贴视频链接"), systemImage: "plus")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(AppTheme.primary)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    // Existing end-to-end tests use this stable entry to reach
                    // the paste/sample hub, regardless of whether history exists.
                    .accessibilityIdentifier("youtubeHomeEntryCard")
                }
            }
            Text(AppLocalized("分享视频链接，朗读公开字幕稿"))
                .font(.caption)
                .foregroundStyle(AppTheme.mutedForeground)
        }
    }

    /// 整卡即入口：标题和按钮原本都写「粘贴视频链接」，同一句话在一张卡里出现两次，
    /// 还配了一颗全宽实心按钮——空状态不需要这么强的视觉重量。
    private var emptyState: some View {
        NavigationLink(destination: YouTubeHomeView()) {
            HStack(spacing: HomeLayout.itemGap) {
                youtubeIcon
                VStack(alignment: .leading, spacing: HomeLayout.titleToSubtitle) {
                    Text(AppLocalized("粘贴视频链接"))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.foreground)
                    Text(AppLocalized("朗读过的字幕稿会显示在这里，方便继续收听。"))
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(HomeLayout.regularCardPadding)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.72), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("youtubeHomeEntryCard")
    }

    private var youtubeIcon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(red: 1, green: 0.08, blue: 0.08))
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 52, height: 52)
        .accessibilityHidden(true)
    }

    private var historyRefreshID: String {
        YouTubeHistoryRefreshIdentity.value(for: homeRecords)
    }

    private func scheduleHistoryStatusRefresh(
        debounceNanoseconds: UInt64 = 450_000_000
    ) {
        historyStatusLoader.schedule(
            records: homeRecords,
            identity: historyRefreshID,
            debounceNanoseconds: debounceNanoseconds
        )
    }

    private func route(_ rawURL: String, entry: YouTubeListenEntry) {
        guard YouTubeRouteCenter.shared.open(rawURL, entry: entry) else {
            notice = AppLocalized("这不是有效的 YouTube 视频链接")
            return
        }
    }
}

private struct YouTubeHomeShelfRow: View {
    let record: HistoryRecord
    let status: YouTubeHistoryStatus?
    let isActive: Bool
    let action: () -> Void

    private var detail: String? {
        youtubeHistoryDetail(for: record, status: status)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: HomeLayout.itemGap) {
                CoverThumbnail(
                    record: record,
                    contentMode: .fill,
                    cornerRadius: 9
                )
                .frame(width: 96, height: 54)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: HomeLayout.titleToSubtitle) {
                    Text(record.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AppTheme.foreground)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedForeground)
                            .lineLimit(2)
                    } else {
                        Text(record.lastOpenedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(AppTheme.mutedForeground)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(HomeLayout.compactCardPadding)
            .background(isActive ? AppTheme.primary.opacity(0.07) : AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isActive ? AppTheme.primary.opacity(0.72) : AppTheme.border.opacity(0.72),
                        lineWidth: 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(record.title))
        .accessibilityValue(Text(detail ?? AppLocalized("开始朗读")))
        .accessibilityHint(Text(AppLocalized("开始朗读")))
        .accessibilityIdentifier("homeShelfItem.youtube.\(record.id)")
    }
}

struct YouTubeHomeView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var coordinator: PlayerCoordinator
    @ObservedObject private var history = HistoryStore.shared
    @AppStorage("youtube.didCompleteFirstListen") private var didCompleteFirstListen = false
    @State private var linkText = ""
    @State private var notice: String?
    @State private var didTrackView = false
    @State private var isVisible = false
    @StateObject private var historyStatusLoader = YouTubeHistoryStatusLoader()

    private var youtubeHistory: [HistoryRecord] {
        history.records.filter { $0.sourceKind == .youtube }
    }

    private var historyStatuses: [String: YouTubeHistoryStatus] {
        historyStatusLoader.statuses
    }

    private var isMonitoringActive: Bool {
        YouTubeHistoryMonitoringPolicy.isActive(
            isVisible: isVisible,
            isSurfaceEnabled: !coordinator.isReaderPresented,
            isSceneActive: scenePhase == .active
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                guideSection
                pasteSection
                historySection
                complianceNote
            }
            .padding(20)
        }
        .reservesMiniPlayerSpace()
        .background(AppTheme.background.ignoresSafeArea())
        .navigationTitle(AppLocalized("听 YouTube"))
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isVisible = true
            trackViewIfNeeded()
            if isMonitoringActive {
                scheduleHistoryStatusRefresh(debounceNanoseconds: 0)
            }
        }
        .onDisappear {
            isVisible = false
            historyStatusLoader.cancel()
        }
        .onChange(of: isMonitoringActive) { active in
            if active {
                scheduleHistoryStatusRefresh(debounceNanoseconds: 0)
            } else {
                historyStatusLoader.cancel()
            }
        }
        .onChange(of: historyRefreshID) { _ in
            guard isMonitoringActive else { return }
            scheduleHistoryStatusRefresh(debounceNanoseconds: 0)
        }
        .modifier(
            YouTubeCacheChangeListener(
                isActive: isMonitoringActive,
                onArtworkChanged: { _ in scheduleHistoryStatusRefresh() }
            )
        )
        .alert(
            AppLocalized("无法打开"),
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            )
        ) {
            Button(AppLocalized("好"), role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    private var guideSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    didCompleteFirstListen
                        ? AppLocalized("怎样从 YouTube 分享")
                        : AppLocalized("三步开始听字幕稿"),
                    systemImage: "sparkles"
                )
                .font(.headline)
                .foregroundStyle(AppTheme.foreground)
                Spacer()
                if didCompleteFirstListen {
                    Text(AppLocalized("已学会"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.primary)
                }
            }

            if !didCompleteFirstListen {
                HStack(alignment: .top, spacing: 8) {
                    guideStep("1", AppLocalized("在 YouTube 点分享"), "square.and.arrow.up")
                    guideArrow
                    guideStep("2", AppLocalized("选择 CastReader"), "waveform")
                    guideArrow
                    guideStep("3", AppLocalized("自动朗读字幕"), "speaker.wave.2.fill")
                }
            } else {
                Text(AppLocalized("在视频的分享面板里选择 CastReader；字幕可用时会直接进入朗读。"))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedForeground)
            }

        }
        .padding(16)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.border.opacity(0.72), lineWidth: 1)
        }
    }

    private func guideStep(
        _ number: String,
        _ title: String,
        _ icon: String
    ) -> some View {
        VStack(spacing: 7) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)
                    .frame(width: 42, height: 42)
                    .background(AppTheme.primary.opacity(0.1), in: Circle())
                Text(number)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 17, height: 17)
                    .background(AppTheme.primary, in: Circle())
            }
            Text(title)
                .font(.caption)
                .foregroundStyle(AppTheme.foreground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var guideArrow: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(AppTheme.mutedForeground.opacity(0.55))
            .padding(.top, 15)
    }

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AppLocalized("粘贴视频链接"))
                .font(.headline)
                .foregroundStyle(AppTheme.foreground)

            HStack(spacing: 8) {
                TextField(
                    AppLocalized("youtube.com/watch?v=…"),
                    text: $linkText
                )
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .textContentType(.URL)
                .submitLabel(.go)
                .onSubmit(openPastedLink)
                .padding(.horizontal, 12)
                .frame(height: 46)
                .background(AppTheme.surfaceVariant)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                .accessibilityIdentifier("youtubeURLField")

                Button {
                    if let value = UIPasteboard.general.string {
                        linkText = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(Text(AppLocalized("粘贴")))

                Button(action: openPastedLink) {
                    Image(systemName: "headphones")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .accessibilityLabel(Text(AppLocalized("开始朗读")))
                .accessibilityIdentifier("youtubePasteListenButton")
            }
        }
    }

    @ViewBuilder
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(AppLocalized("收听历史"))
                .font(.headline)
                .foregroundStyle(AppTheme.foreground)

            if youtubeHistory.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.title2)
                        .foregroundStyle(AppTheme.mutedForeground)
                    Text(AppLocalized("朗读过的字幕稿会显示在这里，方便继续收听。"))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedForeground)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(youtubeHistory) { record in
                        Button {
                            guard let url = record.sourceURL else { return }
                            route(url, entry: .history)
                        } label: {
                            HStack(spacing: 12) {
                                CoverThumbnail(
                                    record: record,
                                    contentMode: .fill,
                                    cornerRadius: 9
                                )
                                .frame(width: 88, height: 52)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.title)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(AppTheme.foreground)
                                        .lineLimit(2)
                                    if let detail = historyDetail(for: record) {
                                        Text(detail)
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.mutedForeground)
                                    } else {
                                        Text(record.lastOpenedAt, style: .relative)
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.mutedForeground)
                                    }
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "play.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(AppTheme.primary)
                            }
                            .padding(10)
                            .background(AppTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("youtubeHistory_\(record.id)")
                    }
                }
            }
        }
    }

    private var complianceNote: some View {
        Label(
            AppLocalized("字幕读取通过 YouTube 官方播放器完成；播放器仅静音初始化并立即暂停，朗读声音由字幕文本生成。"),
            systemImage: "captions.bubble"
        )
        .font(.caption)
        .foregroundStyle(AppTheme.mutedForeground)
        .padding(.top, 2)
    }

    private func openPastedLink() {
        let value = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            notice = AppLocalized("请先粘贴 YouTube 视频链接")
            return
        }
        route(value, entry: .paste)
    }

    private func route(_ rawURL: String, entry: YouTubeListenEntry) {
        if YouTubeRouteCenter.shared.open(rawURL, entry: entry) {
            linkText = ""
        } else {
            notice = AppLocalized("这不是有效的 YouTube 视频链接")
        }
    }

    private func trackViewIfNeeded() {
        guard !didTrackView else { return }
        didTrackView = true
        ProductAnalytics.shared.track(
            .youtubeHomeView,
            context: AnalyticsEventContext(
                productArea: .reader,
                surface: "youtube_home",
                entryPoint: "youtube_home"
            ),
            properties: .init(firstTime: !didCompleteFirstListen)
        )
    }

    private var historyRefreshID: String {
        YouTubeHistoryRefreshIdentity.value(for: youtubeHistory)
    }

    private func historyDetail(for record: HistoryRecord) -> String? {
        youtubeHistoryDetail(
            for: record,
            status: historyStatuses[record.id]
        )
    }

    private func scheduleHistoryStatusRefresh(
        debounceNanoseconds: UInt64 = 450_000_000
    ) {
        historyStatusLoader.schedule(
            records: youtubeHistory,
            identity: historyRefreshID,
            debounceNanoseconds: debounceNanoseconds
        )
    }
}
