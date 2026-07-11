//
//  VoiceBrowserView.swift
//  CastReader
//
//  动态 TTS catalog 的浏览、搜索、筛选、收藏和最近使用界面。
//

import SwiftUI

@MainActor
struct VoiceBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var pro: ProManager
    @ObservedObject private var catalog: VoiceCatalogService
    @ObservedObject private var library: VoiceLibraryStore

    @State private var tab: VoiceBrowserTab = .explore
    @State private var searchText = ""
    @State private var languageFilter = ""
    @State private var genderFilter = ""
    @State private var tierFilter: VoiceTierFilter = .all
    @State private var selectingVoiceID: String?
    @State private var showPaywall = false

    init() {
        _settings = ObservedObject(wrappedValue: .shared)
        _pro = ObservedObject(wrappedValue: .shared)
        _catalog = ObservedObject(wrappedValue: .shared)
        _library = ObservedObject(wrappedValue: .shared)
    }

    init(
        settings: AppSettings,
        pro: ProManager,
        catalog: VoiceCatalogService,
        library: VoiceLibraryStore
    ) {
        _settings = ObservedObject(wrappedValue: settings)
        _pro = ObservedObject(wrappedValue: pro)
        _catalog = ObservedObject(wrappedValue: catalog)
        _library = ObservedObject(wrappedValue: library)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("音色分类", selection: $tab) {
                    Text("最近").tag(VoiceBrowserTab.recent)
                    Text("收藏").tag(VoiceBrowserTab.favorites)
                    Text("探索").tag(VoiceBrowserTab.explore)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 10)

                if tab == .explore {
                    filterBar
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }

                if displayedVoices.isEmpty {
                    emptyState
                } else {
                    List(displayedVoices) { voice in
                        VoiceBrowserRow(
                            voice: voice,
                            isSelected: settings.selectedVoiceID(for: voice.lang) == voice.code,
                            isFavorite: library.isFavorite(voice.code),
                            isSelecting: selectingVoiceID == voice.code,
                            onSelect: { select(voice) },
                            onToggleFavorite: { library.toggleFavorite(voice.code) }
                        )
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("音色")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索音色")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showPaywall) { PaywallView() }
    }

    private var sourceVoices: [VoiceOption] {
        switch tab {
        case .recent:
            return library.recentIDs.compactMap { VoiceCatalog.option(for: $0) }
        case .favorites:
            return VoiceCatalog.selectableVoices.filter { library.favoriteIDs.contains($0.code) }
        case .explore:
            return VoiceCatalog.selectableVoices
        }
    }

    private var displayedVoices: [VoiceOption] {
        VoiceBrowserFilter.apply(
            voices: sourceVoices,
            search: searchText,
            language: tab == .explore ? languageFilter : "",
            gender: tab == .explore ? genderFilter : "",
            tier: tab == .explore ? tierFilter : .all
        )
    }

    private var availableLanguages: [String] {
        Array(Set(VoiceCatalog.selectableVoices.map { VoiceCatalog.normalizedLanguage($0.lang) }))
            .filter { !$0.isEmpty }
            .sorted()
    }

    private var availableGenders: [String] {
        Array(Set(VoiceCatalog.selectableVoices.map { $0.gender.trimmed.lowercased() }))
            .filter { !$0.isEmpty }
            .sorted()
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            filterMenu(
                title: languageFilter.isEmpty ? String(localized: "语言") : languageName(languageFilter),
                systemImage: "globe"
            ) {
                Button("全部") { languageFilter = "" }
                ForEach(availableLanguages, id: \.self) { language in
                    Button(languageName(language)) { languageFilter = language }
                }
            }

            filterMenu(
                title: genderFilter.isEmpty ? String(localized: "性别") : genderName(genderFilter),
                systemImage: "person.2"
            ) {
                Button("全部") { genderFilter = "" }
                ForEach(availableGenders, id: \.self) { gender in
                    Button(genderName(gender)) { genderFilter = gender }
                }
            }

            filterMenu(title: tierName(tierFilter), systemImage: "crown") {
                ForEach(VoiceTierFilter.allCases) { tier in
                    Button(tierName(tier)) { tierFilter = tier }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }

    private func filterMenu<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        Menu(content: content) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView(
            emptyTitle,
            systemImage: tab == .favorites ? "star" : "waveform",
            description: Text(searchText.isEmpty ? "" : String(localized: "尝试其他搜索或筛选条件"))
        )
    }

    private var emptyTitle: LocalizedStringKey {
        switch tab {
        case .recent: return "暂无最近使用的音色"
        case .favorites: return "暂无收藏的音色"
        case .explore: return "没有匹配的音色"
        }
    }

    private func select(_ voice: VoiceOption) {
        guard selectingVoiceID == nil else { return }
        if VoiceSelectionPolicy.select(voice, isPro: pro.isPro, settings: settings) {
            library.recordRecent(voice.code)
            return
        }
        guard voice.isPro else { return }

        selectingVoiceID = voice.code
        Task { @MainActor in
            await pro.refresh()
            if VoiceSelectionPolicy.select(voice, isPro: pro.isPro, settings: settings) {
                library.recordRecent(voice.code)
            } else {
                showPaywall = true
            }
            selectingVoiceID = nil
        }
    }

    private func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private func genderName(_ value: String) -> String {
        switch value.lowercased() {
        case "female": return String(localized: "女声")
        case "male": return String(localized: "男声")
        default: return value.capitalized
        }
    }

    private func tierName(_ tier: VoiceTierFilter) -> String {
        switch tier {
        case .all: return String(localized: "全部")
        case .free: return String(localized: "免费")
        case .pro: return "Pro"
        }
    }
}

private struct VoiceBrowserRow: View {
    let voice: VoiceOption
    let isSelected: Bool
    let isFavorite: Bool
    let isSelecting: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    VoiceAvatarView(voice: voice)
                        .frame(width: 46, height: 46)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(voice.name)
                                .font(.headline)
                                .foregroundColor(AppTheme.foreground)
                            if voice.isPro {
                                Text("PRO")
                                    .font(.caption2.weight(.bold))
                                    .foregroundColor(AppTheme.primary)
                            }
                        }
                        Text(metadata)
                            .font(.caption)
                            .foregroundColor(AppTheme.mutedForeground)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isSelecting {
                        ProgressView()
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(AppTheme.primary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .foregroundColor(isFavorite ? AppTheme.primary : AppTheme.mutedForeground)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isFavorite
                ? String(localized: "取消收藏")
                : String(localized: "收藏")))
        }
        .padding(.vertical, 3)
    }

    private var metadata: String {
        let locale = voice.locale.isEmpty ? voice.lang.uppercased() : voice.locale
        return ([locale] + voice.tags.prefix(3)).filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct VoiceAvatarView: View {
    let voice: VoiceOption

    var body: some View {
        CachedAsyncImage(url: avatarURL) {
            ZStack {
                Circle().fill(fallbackColor.opacity(0.18))
                Text(initial)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(fallbackColor)
            }
        }
        .clipShape(Circle())
    }

    private var avatarURL: URL? {
        [voice.avatarURL64, voice.avatarURL256]
            .compactMap { $0.flatMap(URL.init(string:)) }
            .first
    }

    private var initial: String {
        let value = String(voice.name.trimmed.prefix(1)).uppercased()
        return value.isEmpty ? "V" : value
    }

    private var fallbackColor: Color {
        let colors: [Color] = [.blue, .green, .pink, .purple, .teal, AppTheme.primary]
        var hash: UInt64 = 1469598103934665603
        for byte in voice.code.utf8 {
            hash = (hash ^ UInt64(byte)) &* 1099511628211
        }
        return colors[Int(hash % UInt64(colors.count))]
    }
}
