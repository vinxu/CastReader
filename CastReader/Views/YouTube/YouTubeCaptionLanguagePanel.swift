//
//  YouTubeCaptionLanguagePanel.swift
//  CastReader
//
//  Caption-language picker for the YouTube reader. Presented as a ZStack
//  overlay rather than a sheet: the reader already owns a paywall sheet, and
//  two sheets on one view swallow each other.
//

import SwiftUI

struct YouTubeCaptionLanguagePanelOverlay: View {
    @ObservedObject var switcher: YouTubeCaptionLanguageSwitcher
    let transcript: YouTubeTranscriptDocument
    let select: (YouTubeCaptionTrackOption) -> Void

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = proxy.size.width > 700 ? 42 : 12
            let panelWidth = min(560, proxy.size.width - horizontalInset * 2)
            let panelHeight = min(560, max(300, proxy.size.height * 0.62))

            ZStack(alignment: .bottom) {
                Color.black.opacity(0.32)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { switcher.dismissPicker() }

                YouTubeCaptionLanguagePanel(
                    transcript: transcript,
                    select: select,
                    dismiss: { switcher.dismissPicker() }
                )
                .frame(width: panelWidth, height: panelHeight)
                .background(AppTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(AppTheme.mutedForeground.opacity(0.16), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
                .padding(.bottom, max(8, proxy.safeAreaInsets.bottom))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .accessibilityIdentifier("youtubeCaptionLanguagePanel")
    }
}

/// Picker rules kept out of the view body so they can be tested directly.
enum YouTubeCaptionLanguagePickerPolicy {
    /// Above this many tracks, scanning the list stops being practical. Some
    /// videos carry 30+ community tracks.
    static let searchFieldThreshold = 8

    /// Playable languages keep the page's own ranking; the rest sink to the
    /// bottom. They stay listed because "this video has Vietnamese subtitles we
    /// cannot narrate" is still information the user came here for.
    static func ordered(
        _ options: [YouTubeCaptionTrackOption]
    ) -> [YouTubeCaptionTrackOption] {
        options.filter(\.isPlayable) + options.filter { !$0.isPlayable }
    }

    static func filtered(
        _ options: [YouTubeCaptionTrackOption],
        query: String,
        locale: Locale
    ) -> [YouTubeCaptionTrackOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return options }
        let needle = trimmed.lowercased()
        return options.filter { option in
            option.displayName(locale: locale).lowercased().contains(needle)
                || option.languageCode.lowercased().contains(needle)
                || (option.name?.lowercased().contains(needle) ?? false)
        }
    }

    /// A language that is not on disk cannot be fetched without a network.
    /// Refusing the tap here replaces a 30-second timeout with an answer.
    static func requiresNetwork(
        hasTranscript: Bool,
        isOnline: Bool
    ) -> Bool {
        !hasTranscript && !isOnline
    }

    static func isSelectable(
        _ option: YouTubeCaptionTrackOption,
        isCurrent: Bool,
        hasTranscript: Bool,
        isOnline: Bool
    ) -> Bool {
        option.isPlayable
            && !isCurrent
            && !requiresNetwork(hasTranscript: hasTranscript, isOnline: isOnline)
    }
}

struct YouTubeCaptionLanguagePanel: View {
    let transcript: YouTubeTranscriptDocument
    let select: (YouTubeCaptionTrackOption) -> Void
    let dismiss: () -> Void

    @StateObject private var availability = YouTubeCaptionLanguageAvailabilityLoader()
    @ObservedObject private var languageManager = AppLanguageManager.shared
    @ObservedObject private var reachability = NetworkReachability.shared
    @ObservedObject private var quota = QuotaManager.shared
    @ObservedObject private var pro = ProManager.shared
    @State private var query = ""

    private var options: [YouTubeCaptionTrackOption] {
        YouTubeCaptionLanguagePickerPolicy.ordered(transcript.switchableTracks)
    }

    private var visibleOptions: [YouTubeCaptionTrackOption] {
        YouTubeCaptionLanguagePickerPolicy.filtered(
            options,
            query: query,
            locale: locale
        )
    }

    private var locale: Locale { languageManager.locale }

    var body: some View {
        VStack(spacing: 0) {
            header
            if options.count > YouTubeCaptionLanguagePickerPolicy.searchFieldThreshold {
                searchField
            }
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(visibleOptions) { option in
                        row(option)
                        if option.id != visibleOptions.last?.id {
                            Divider().padding(.leading, 16)
                        }
                    }
                    if visibleOptions.isEmpty {
                        Text(AppLocalized("没有匹配的语言"))
                            .font(.subheadline)
                            .foregroundStyle(AppTheme.mutedForeground)
                            .padding(.vertical, 28)
                    }
                }
            }
            quotaFooter
        }
        .task(id: transcript.metadata.videoId) {
            await availability.load(
                videoId: transcript.metadata.videoId,
                options: options.filter(\.isPlayable)
            )
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(AppTheme.mutedForeground)
            TextField(AppLocalized("搜索语言"), text: $query)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(AppTheme.mutedForeground.opacity(0.6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(AppLocalized("清空")))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(AppTheme.surfaceVariant, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .accessibilityIdentifier("youtubeCaptionLanguageSearchField")
    }

    /// Switching regenerates every paragraph's audio under a new voice, so a
    /// free listener is spending quota. Say so before the tap, not after.
    @ViewBuilder
    private var quotaFooter: some View {
        if !pro.isPro {
            let remainingMinutes = max(0, Int(quota.listenRemaining / 60))
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalized("切换语言会重新生成朗读音频"))
                Text(String(
                    format: AppLocalized("今日剩余朗读 %d 分钟"),
                    remainingMinutes
                ))
                .foregroundStyle(
                    remainingMinutes == 0 ? AppTheme.destructive : AppTheme.mutedForeground
                )
            }
            .font(.caption2)
            .foregroundStyle(AppTheme.mutedForeground)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .accessibilityIdentifier("youtubeCaptionLanguageQuotaFooter")
        }
    }

    private var header: some View {
        HStack {
            Text(AppLocalized("字幕语言"))
                .font(.headline)
                .foregroundStyle(AppTheme.foreground)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(AppTheme.mutedForeground.opacity(0.6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(AppLocalized("关闭")))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func row(_ option: YouTubeCaptionTrackOption) -> some View {
        let isCurrent = option.matches(transcript.track)
        let state = availability.state(for: option)
        let needsNetwork = YouTubeCaptionLanguagePickerPolicy.requiresNetwork(
            hasTranscript: state.hasTranscript,
            isOnline: reachability.isOnline
        )
        let isSelectable = YouTubeCaptionLanguagePickerPolicy.isSelectable(
            option,
            isCurrent: isCurrent,
            hasTranscript: state.hasTranscript,
            isOnline: reachability.isOnline
        )
        return Button {
            guard isSelectable else { return }
            select(option)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(AppTheme.primary)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.displayName(locale: locale))
                        .font(.subheadline)
                        .foregroundStyle(
                            option.isPlayable && !needsNetwork
                                ? AppTheme.foreground
                                : AppTheme.mutedForeground
                        )
                    if let caption = subtitle(
                        for: option,
                        needsNetwork: needsNetwork
                    ) {
                        Text(caption)
                            .font(.caption2)
                            .foregroundStyle(AppTheme.mutedForeground)
                    }
                }
                Spacer(minLength: 8)
                downloadBadge(for: state)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable && !isCurrent)
        .accessibilityIdentifier("youtubeCaptionLanguageRow_\(option.selectionKey)")
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
    }

    private func subtitle(
        for option: YouTubeCaptionTrackOption,
        needsNetwork: Bool
    ) -> String? {
        if !option.isPlayable { return AppLocalized("暂不支持朗读") }
        if needsNetwork { return AppLocalized("需要联网才能获取") }
        if option.isAutomatic { return AppLocalized("自动生成") }
        return nil
    }

    /// Only a fully downloaded language earns the offline badge. A transcript
    /// with partial audio still switches instantly, but promising "offline"
    /// for it would be a lie the first time playback reaches a missing
    /// paragraph, so it stays unmarked.
    @ViewBuilder
    private func downloadBadge(
        for state: YouTubeCaptionLanguageAvailability
    ) -> some View {
        if state.isFullyDownloaded {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.primary)
                .accessibilityLabel(Text(AppLocalized("已下载")))
        } else if state.hasTranscript {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 14))
                .foregroundStyle(AppTheme.mutedForeground.opacity(0.7))
                .accessibilityLabel(Text(AppLocalized("可立即切换")))
        }
    }
}

/// Loads per-language cache state once per picker presentation. Kept off the
/// row bodies so a 30-track list does not fan out 30 actor hops per redraw.
@MainActor
private final class YouTubeCaptionLanguageAvailabilityLoader: ObservableObject {
    @Published private(set) var states: [String: YouTubeCaptionLanguageAvailability] = [:]

    func state(for option: YouTubeCaptionTrackOption) -> YouTubeCaptionLanguageAvailability {
        states[option.selectionKey] ?? .unavailable
    }

    func load(videoId: String, options: [YouTubeCaptionTrackOption]) async {
        guard let cache = YouTubeCacheProvider.shared else { return }
        let settings = AppSettings.shared
        let voiceCodeByLanguage = options.reduce(into: [String: String]()) { result, option in
            let base = YouTubeTrackSelector.baseLanguage(option.languageCode)
            guard !base.isEmpty, result[base] == nil else { return }
            result[base] = settings.voice(for: base)
        }
        let resolved = await cache.captionTrackAvailability(
            videoId: videoId,
            options: options,
            voiceCodeByLanguage: voiceCodeByLanguage
        )
        guard !Task.isCancelled else { return }
        states = resolved
    }
}
