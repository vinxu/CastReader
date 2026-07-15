//
//  VoiceBrowserView.swift
//  CastReader
//
//  动态 TTS catalog 的浏览、搜索、筛选、收藏和最近使用界面。
//

import SwiftUI

enum VoiceBrowserPresentation: Equatable {
    case sheet
    case tab
}

@MainActor
struct VoiceBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var pro: ProManager
    @ObservedObject private var catalog: VoiceCatalogService
    @ObservedObject private var library: VoiceLibraryStore
    @ObservedObject private var samplePlayer: VoiceSamplePlayer
    private let presentation: VoiceBrowserPresentation

    @State private var tab: VoiceBrowserTab = .explore
    @State private var searchText = ""
    @State private var genderFilter = ""
    @State private var tierFilter: VoiceTierFilter = .all
    @State private var accentFilter = ""
    @State private var recommendedOnly = false
    @State private var selectingVoiceID: String?
    @State private var showLanguagePicker = false
    @State private var showPaywall = false

    init(presentation: VoiceBrowserPresentation = .sheet) {
        self.presentation = presentation
        _settings = ObservedObject(wrappedValue: .shared)
        _pro = ObservedObject(wrappedValue: .shared)
        _catalog = ObservedObject(wrappedValue: .shared)
        _library = ObservedObject(wrappedValue: .shared)
        _samplePlayer = ObservedObject(wrappedValue: .shared)
    }

    init(
        settings: AppSettings,
        pro: ProManager,
        catalog: VoiceCatalogService,
        library: VoiceLibraryStore,
        presentation: VoiceBrowserPresentation = .sheet
    ) {
        self.presentation = presentation
        _settings = ObservedObject(wrappedValue: settings)
        _pro = ObservedObject(wrappedValue: pro)
        _catalog = ObservedObject(wrappedValue: catalog)
        _library = ObservedObject(wrappedValue: library)
        _samplePlayer = ObservedObject(wrappedValue: .shared)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    languageSelector
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    Section {
                        if tab == .explore {
                            filterBar
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                        }
                        voiceResults
                    } header: {
                        categoryTabs
                    }
                }
            }
            .background(AppTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("音色")
            .navigationBarTitleDisplayMode(presentation == .tab ? .large : .inline)
            .searchable(text: $searchText, prompt: "搜索音色")
            .toolbar {
                if presentation == .sheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                } else {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        SettingsToolbarButton()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showLanguagePicker) {
            VoiceLanguagePickerView(
                languages: availableLanguages,
                selection: Binding(
                    get: { library.browserLanguage },
                    set: { library.setBrowserLanguage($0) }
                )
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                reason: String(localized: "此音色需要 CastReader Pro"),
                analyticsTrigger: "pro_voice",
                analyticsSurface: "voice_browser"
            )
        }
        .onDisappear { samplePlayer.stop() }
        .onAppear {
            if !Constants.Features.voiceCloningEnabled, tab == .created {
                tab = .explore
            }
            synchronizeBrowserLanguage()
        }
        .onChange(of: catalog.revision) { _ in synchronizeBrowserLanguage() }
        .onChange(of: library.browserLanguage) { _ in
            searchText = ""
            genderFilter = ""
            accentFilter = ""
            recommendedOnly = false
            samplePlayer.stop()
        }
    }

    private var categoryTabs: some View {
        Picker("音色分类", selection: $tab) {
            Text("最近").tag(VoiceBrowserTab.recent)
            Text("收藏").tag(VoiceBrowserTab.favorites)
            Text("探索").tag(VoiceBrowserTab.explore)
            if Constants.Features.voiceCloningEnabled {
                Text("已创建").tag(VoiceBrowserTab.created)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(AppTheme.background)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    @ViewBuilder
    private var voiceResults: some View {
        if Constants.Features.voiceCloningEnabled, tab == .created {
            VoiceCloneCreatedView(language: library.browserLanguage)
                .frame(minHeight: 360)
        } else if displayedVoices.isEmpty {
            emptyState
                .frame(maxWidth: .infinity)
                .frame(minHeight: 320)
        } else {
            ForEach(displayedVoices) { voice in
                VoiceBrowserRow(
                    voice: voice,
                    isSelected: settings.activeClonedVoiceID(for: voice.lang) == nil && settings.voice(for: voice.lang) == voice.code,
                    isFavorite: library.isFavorite(voice.code),
                    isSelecting: selectingVoiceID == voice.code,
                    isPreviewing: samplePlayer.playingVoiceID == voice.code,
                    isPreviewLoading: samplePlayer.loadingVoiceID == voice.code,
                    onSelect: { select(voice) },
                    onPreview: { samplePlayer.toggle(voiceID: voice.code, sampleURL: voice.sampleURL) },
                    onToggleFavorite: { library.toggleFavorite(voice.code) }
                )
                .padding(.horizontal)

                Divider()
                    .padding(.leading, 74)
            }
        }
    }

    private var languageSelector: some View {
        Button {
            showLanguagePicker = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.title3)
                    .foregroundStyle(AppTheme.primary)

                VStack(alignment: .leading, spacing: 2) {
                    Text("朗读语言")
                        .font(.caption)
                        .foregroundStyle(AppTheme.mutedForeground)
                    Text(selectedLanguageName)
                        .font(.headline)
                        .foregroundStyle(AppTheme.foreground)
                        .lineLimit(1)
                }

                Spacer()

                if let language = selectedLanguage {
                    Text(VoiceBrowserLanguage.voiceCountText(language.voiceCount))
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.mutedForeground)
                } else if catalog.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                }

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedForeground)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 58)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppTheme.surface)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("朗读语言"))
        .accessibilityValue(Text(selectedLanguageName))
    }

    private var availableLanguages: [VoiceCatalogLanguageOption] {
        VoiceCatalog.availableLanguages
    }

    private var selectedLanguage: VoiceCatalogLanguageOption? {
        VoiceCatalog.languageOption(for: library.browserLanguage)
    }

    private var selectedLanguageName: String {
        guard let selectedLanguage else { return library.browserLanguage.uppercased() }
        return VoiceBrowserLanguage.displayName(for: selectedLanguage)
    }

    private var sourceVoices: [VoiceOption] {
        switch tab {
        case .recent:
            return library.recentIDs.compactMap { VoiceCatalog.option(for: $0) }
                .filter { VoiceCatalog.normalizedLanguage($0.lang) == library.browserLanguage }
        case .favorites:
            return VoiceCatalog.voices(for: library.browserLanguage)
                .filter { library.favoriteIDs.contains($0.code) }
        case .explore:
            return VoiceCatalog.voices(for: library.browserLanguage)
        case .created:
            return []
        }
    }

    private var displayedVoices: [VoiceOption] {
        VoiceBrowserFilter.apply(
            voices: sourceVoices,
            search: searchText,
            language: library.browserLanguage,
            gender: tab == .explore ? genderFilter : "",
            tier: tab == .explore ? tierFilter : .all,
            accent: tab == .explore ? accentFilter : "",
            recommendedOnly: tab == .explore && recommendedOnly
        )
    }

    private var availableGenders: [String] {
        Array(Set(VoiceCatalog.voices(for: library.browserLanguage).map { $0.gender.trimmed.lowercased() }))
            .filter { !$0.isEmpty }
            .sorted()
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
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

                if library.browserLanguage == "en" {
                    filterMenu(
                        title: accentFilter.isEmpty ? String(localized: "口音") : accentName(accentFilter),
                        systemImage: "character.bubble"
                    ) {
                        Button("全部") { accentFilter = "" }
                        Button("美国") { accentFilter = "us" }
                        Button("英国") { accentFilter = "uk" }
                    }
                }

                Button {
                    recommendedOnly.toggle()
                } label: {
                    Label("推荐", systemImage: recommendedOnly ? "sparkles" : "sparkle")
                        .foregroundStyle(recommendedOnly ? AppTheme.primary : AppTheme.foreground)
                }
                .buttonStyle(.plain)
            }
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
            systemImage: tab == .favorites ? "heart" : "waveform",
            description: Text(searchText.isEmpty ? "" : String(localized: "尝试其他搜索或筛选条件"))
        )
    }

    private var emptyTitle: LocalizedStringKey {
        switch tab {
        case .recent: return "暂无最近使用的音色"
        case .favorites: return "暂无收藏的音色"
        case .explore: return "没有匹配的音色"
        case .created: return "还没有创建的声音"
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

    private func synchronizeBrowserLanguage() {
        // fallback 阶段可能尚未拿到上次选择的远端语言，先保留；只有完整目录
        // 已安装后才纠正已下线的语言，避免冷启动把用户偏好覆盖成英文。
        guard catalog.source != .fallback else { return }
        let codes = availableLanguages.map(\.code)
        guard !codes.isEmpty else { return }
        let fallback = VoiceBrowserLanguage.defaultLanguage(
            preferredLanguages: Locale.preferredLanguages + Bundle.main.preferredLocalizations,
            availableLanguages: codes
        )
        if !library.hasExplicitBrowserLanguageSelection {
            library.applyDefaultBrowserLanguage(fallback)
        } else if !codes.contains(library.browserLanguage) {
            library.replaceUnavailableBrowserLanguage(with: fallback)
        }
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

    private func accentName(_ accent: String) -> String {
        switch accent.lowercased() {
        case "us": return String(localized: "美国")
        case "uk": return String(localized: "英国")
        default: return accent.uppercased()
        }
    }
}

private struct VoiceLanguagePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let languages: [VoiceCatalogLanguageOption]
    @Binding var selection: String
    @State private var searchText = ""

    var body: some View {
        NavigationStack {
            List(filteredLanguages) { language in
                Button {
                    selection = language.code
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(VoiceBrowserLanguage.displayName(for: language))
                                .font(.body.weight(.medium))
                                .foregroundStyle(AppTheme.foreground)
                            Text(languageMetadata(language))
                                .font(.caption)
                                .foregroundStyle(AppTheme.mutedForeground)
                        }
                        Spacer()
                        if VoiceCatalog.normalizedLanguage(selection) == language.code {
                            Image(systemName: "checkmark")
                                .font(.body.weight(.semibold))
                                .foregroundStyle(AppTheme.primary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(Text(VoiceBrowserLanguage.voiceCountText(language.voiceCount)))
            }
            .navigationTitle("朗读语言")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "搜索语言")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var filteredLanguages: [VoiceCatalogLanguageOption] {
        languages.filter {
            VoiceBrowserLanguage.matchesSearch($0, query: searchText)
        }
    }

    private func languageMetadata(_ language: VoiceCatalogLanguageOption) -> String {
        "\(language.locale) · \(VoiceBrowserLanguage.voiceCountText(language.voiceCount))"
    }
}

private struct VoiceBrowserRow: View {
    let voice: VoiceOption
    let isSelected: Bool
    let isFavorite: Bool
    let isSelecting: Bool
    let isPreviewing: Bool
    let isPreviewLoading: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VoiceAvatarView(voice: voice)
                .frame(width: 46, height: 46)

            Button(action: onSelect) {
                HStack(spacing: 12) {
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
                        if let description = localizedDescription, !description.isEmpty {
                            Text(description)
                                .font(.caption)
                                .foregroundColor(AppTheme.mutedForeground)
                                .lineLimit(2)
                        }
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

            Button(action: onPreview) {
                Group {
                    if isPreviewLoading {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: isPreviewing ? "stop.circle.fill" : "play.circle")
                            .font(.system(size: 20, weight: .medium))
                            .foregroundStyle(AppTheme.primary)
                    }
                }
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isPreviewing ? "停止试听" : "试听"))

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
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
        var values = [locale]
        if voice.recommended { values.append(String(localized: "推荐")) }
        values.append(contentsOf: voice.bestFor.prefix(2))
        if values.count == 1 { values.append(contentsOf: voice.tags.prefix(2)) }
        return values.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var localizedDescription: String? {
        let isChinese = Locale.current.language.languageCode?.identifier == "zh"
        if isChinese, let value = voice.descriptionZh?.trimmed, !value.isEmpty { return value }
        return voice.description?.trimmed
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
