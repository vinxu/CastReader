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
    case playerOverlay
}

/// Player-owned voice selection is rendered inside the app's root ZStack
/// instead of a UIKit sheet. Presenting a sheet from a control embedded in the
/// Kindle reader temporarily changes the underlying WKWebView geometry on
/// iPhone, which invalidates the live OCR projection and can restart playback.
@MainActor
final class PlaybackVoicePanelCenter: ObservableObject {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let language: String
        /// Read-aloud arrives with a way to correct which language this content is
        /// narrated in; Explain does not. Only a language that cannot be corrected
        /// stays pinned in the panel — see `VoiceBrowserView.languagePinned`.
        let isReadingLanguageCorrectable: Bool
    }

    static let shared = PlaybackVoicePanelCenter()

    @Published private(set) var request: Request?
    /// Held outside `Request` so the published value stays `Equatable`.
    private var correctionHandler: ((String) -> Void)?

    var isPresented: Bool { request != nil }

    private init() {}

    func present(language: String, onCorrectReadingLanguage: ((String) -> Void)? = nil) {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard !normalized.isEmpty else { return }
        correctionHandler = onCorrectReadingLanguage
        request = Request(
            language: normalized,
            isReadingLanguageCorrectable: onCorrectReadingLanguage != nil
        )
    }

    func correctReadingLanguage(_ language: String) {
        correctionHandler?(language)
    }

    func dismiss() {
        request = nil
        correctionHandler = nil
    }
}

@MainActor
struct VoiceBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var pro: ProManager
    @ObservedObject private var catalog: VoiceCatalogService
    @ObservedObject private var library: VoiceLibraryStore
    @ObservedObject private var samplePlayer: VoiceSamplePlayer
    @ObservedObject private var voiceSwitch: VoiceSwitchStatusCenter
    private let presentation: VoiceBrowserPresentation
    /// The reader seeds the panel with the language it is currently narrating in.
    /// It is the initial selection, not a lock: it used to filter everything —
    /// including this panel's own search box — while the control that could change
    /// it was disabled, so one page misdetected as English left no reachable
    /// Italian voice to correct it with. See `ReadingLanguagePolicy`.
    private let initialLanguage: String?
    /// Supplied by read-aloud only: picking a language re-narrates the content in it.
    private let onCorrectReadingLanguage: ((String) -> Void)?
    private let onDone: (() -> Void)?

    @State private var tab: VoiceBrowserTab = .explore
    @State private var searchText = ""
    @State private var genderFilter = ""
    @State private var tierFilter: VoiceTierFilter = .all
    @State private var accentFilter = ""
    @State private var recommendedOnly = false
    @State private var selectingVoiceID: String?
    @State private var showLanguagePicker = false
    @State private var showPaywall = false
    @State private var languageChosenByUser = false

    init(
        presentation: VoiceBrowserPresentation = .sheet,
        language: String? = nil,
        onCorrectReadingLanguage: ((String) -> Void)? = nil,
        onDone: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        let normalized = language.map(VoiceCatalog.normalizedLanguage) ?? ""
        self.initialLanguage = normalized.isEmpty ? nil : normalized
        self.onCorrectReadingLanguage = onCorrectReadingLanguage
        self.onDone = onDone
        _settings = ObservedObject(wrappedValue: .shared)
        _pro = ObservedObject(wrappedValue: .shared)
        _catalog = ObservedObject(wrappedValue: .shared)
        _library = ObservedObject(wrappedValue: .shared)
        _samplePlayer = ObservedObject(wrappedValue: .shared)
        _voiceSwitch = ObservedObject(wrappedValue: .shared)
    }

    init(
        settings: AppSettings,
        pro: ProManager,
        catalog: VoiceCatalogService,
        library: VoiceLibraryStore,
        presentation: VoiceBrowserPresentation = .sheet,
        language: String? = nil,
        onCorrectReadingLanguage: ((String) -> Void)? = nil,
        onDone: (() -> Void)? = nil
    ) {
        self.presentation = presentation
        let normalized = language.map(VoiceCatalog.normalizedLanguage) ?? ""
        self.initialLanguage = normalized.isEmpty ? nil : normalized
        self.onCorrectReadingLanguage = onCorrectReadingLanguage
        self.onDone = onDone
        _settings = ObservedObject(wrappedValue: settings)
        _pro = ObservedObject(wrappedValue: pro)
        _catalog = ObservedObject(wrappedValue: catalog)
        _library = ObservedObject(wrappedValue: library)
        _samplePlayer = ObservedObject(wrappedValue: .shared)
        _voiceSwitch = ObservedObject(wrappedValue: .shared)
    }

    /// Pin the language only when it was supplied from outside *and* cannot be
    /// corrected — that is the Explain panel alone, whose language is a user
    /// setting and whose cross-language picks are rejected downstream, so opening
    /// it up would only produce voices that do nothing when tapped. Read-aloud
    /// always arrives with a correction, so it can never be pinned again.
    private var languagePinned: Bool {
        initialLanguage != nil && onCorrectReadingLanguage == nil
    }

    /// In the reader this control *is* "which language is this content narrated in".
    /// In Settings there is no current book, so it keeps its browse-filter meaning.
    private var isReadingLanguageControl: Bool { initialLanguage != nil }

    private var languageControlTitle: String {
        isReadingLanguageControl ? AppLocalized("朗读语言") : AppLocalized("语言")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    languageSelector
                        .padding(.horizontal)
                        .padding(.top, 8)
                        .padding(.bottom, 2)

                    if let progress = voiceSwitch.progress {
                        VoiceSwitchBanner(progress: progress)
                            .padding(.horizontal)
                            .padding(.top, 8)
                    }

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
            // Inside the NavigationStack on purpose — an inset applied outside it
            // never reaches this ScrollView.
            .reservesMiniPlayerSpace()
            .background(AppTheme.background)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("音色")
            .navigationBarTitleDisplayMode(presentation == .tab ? .large : .inline)
            .searchable(text: $searchText, prompt: "搜索音色")
            .toolbar {
                if presentation != .tab {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            if let onDone { onDone() } else { dismiss() }
                        }
                    }
                } else {
                    // 与首页右上角保持同一组入口：切 Tab 时书架按钮不再消失。
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        ShelfSourcesToolbarButton(
                            accessibilityID: "voiceShelfSourcesButton"
                        )
                        SettingsToolbarButton()
                            .frame(width: 30, height: 30)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .sheet(isPresented: $showLanguagePicker) {
            VoiceLanguagePickerView(
                title: languageControlTitle,
                languages: availableLanguages,
                selection: Binding(
                    get: { library.browserLanguage },
                    set: { chooseLanguage($0) }
                )
            )
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(
                reason: AppLocalized("此音色需要 CastReader Pro"),
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
                    isSelecting: selectingVoiceID == voice.code || voiceSwitch.progress?.toVoiceID == voice.code,
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
        Group {
            if languagePinned {
                languageSelectorContent(showsDisclosure: false)
            } else {
                Button {
                    showLanguagePicker = true
                } label: {
                    languageSelectorContent(showsDisclosure: true)
                }
                .buttonStyle(.plain)
            }
        }
        .accessibilityLabel(Text(languageControlTitle))
        .accessibilityValue(Text(selectedLanguageName))
    }

    private func languageSelectorContent(showsDisclosure: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .font(.title3)
                .foregroundStyle(AppTheme.primary)

            VStack(alignment: .leading, spacing: 2) {
                Text(languageControlTitle)
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

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.mutedForeground)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 58)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(AppTheme.surface)
        )
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
                    title: genderFilter.isEmpty ? AppLocalized("性别") : genderName(genderFilter),
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
                        title: accentFilter.isEmpty ? AppLocalized("口音") : accentName(accentFilter),
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
            description: Text(searchText.isEmpty ? "" : AppLocalized("尝试其他搜索或筛选条件"))
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
            applyReadingLanguage(of: voice)
            return
        }
        guard voice.isPro else { return }

        selectingVoiceID = voice.code
        Task { @MainActor in
            await pro.refresh()
            if VoiceSelectionPolicy.select(voice, isPro: pro.isPro, settings: settings) {
                library.recordRecent(voice.code)
                applyReadingLanguage(of: voice)
            } else {
                showPaywall = true
            }
            selectingVoiceID = nil
        }
    }

    /// Picking a voice from another language is the user telling us what language
    /// this content is. The preference is stored under the voice's own language
    /// first — `AppSettings.setVoice` refusing to file a voice under a foreign
    /// language is the right invariant and stays — and only then does the reading
    /// language follow, so a single re-narration lands on the voice just tapped.
    /// Without this the pick was stored and then ignored: playback still read the
    /// misdetected English preference, and tapping an Italian voice did nothing.
    private func applyReadingLanguage(of voice: VoiceOption) {
        guard let onCorrectReadingLanguage else { return }
        let language = VoiceCatalog.normalizedLanguage(voice.lang)
        guard !language.isEmpty else { return }
        onCorrectReadingLanguage(language)
    }

    /// The user picked a language in this panel. In the reader that is a statement
    /// about the content — "read this book in Italian" — so it corrects the reading
    /// language and re-narrates immediately, instead of only filtering the list and
    /// leaving the user to guess which voice belongs to which language.
    private func chooseLanguage(_ language: String) {
        let normalized = VoiceCatalog.normalizedLanguage(language)
        guard !normalized.isEmpty else { return }
        languageChosenByUser = true
        library.setBrowserLanguage(normalized)
        onCorrectReadingLanguage?(normalized)
    }

    private func synchronizeBrowserLanguage() {
        if let initialLanguage {
            // Follow the reading language until the user picks one themselves. After
            // that, pulling the panel back would undo the correction that is still on
            // its way into playback — which is exactly what "and I cannot change it"
            // felt like. Only a pinned language keeps following unconditionally.
            guard languagePinned || !languageChosenByUser else { return }
            if library.browserLanguage != initialLanguage {
                library.setBrowserLanguage(initialLanguage)
            }
            return
        }
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
        case "female": return AppLocalized("女声")
        case "male": return AppLocalized("男声")
        default: return value.capitalized
        }
    }

    private func tierName(_ tier: VoiceTierFilter) -> String {
        switch tier {
        case .all: return AppLocalized("全部")
        case .free: return AppLocalized("免费")
        case .pro: return "Pro"
        }
    }

    private func accentName(_ accent: String) -> String {
        switch accent.lowercased() {
        case "us": return AppLocalized("美国")
        case "uk": return AppLocalized("英国")
        default: return accent.uppercased()
        }
    }
}

/// A stable in-app bottom panel. Because it is an overlay rather than a modal
/// presentation, showing, dismissing and switching voices never changes the
/// reader's measured surface.
@MainActor
struct PlaybackVoicePanelOverlay: View {
    @ObservedObject var center: PlaybackVoicePanelCenter

    var body: some View {
        if let request = center.request {
            GeometryReader { proxy in
                let horizontalInset: CGFloat = proxy.size.width > 700 ? 42 : 12
                let panelWidth = min(720, proxy.size.width - horizontalInset * 2)
                let panelHeight = min(720, max(470, proxy.size.height * 0.78))

                ZStack(alignment: .bottom) {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .contentShape(Rectangle())
                        .onTapGesture { center.dismiss() }

                    VoiceBrowserView(
                        presentation: .playerOverlay,
                        language: request.language,
                        onCorrectReadingLanguage: request.isReadingLanguageCorrectable
                            ? { center.correctReadingLanguage($0) }
                            : nil,
                        onDone: { center.dismiss() }
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
            .accessibilityIdentifier("playbackVoicePanel")
        }
    }
}

private struct VoiceLanguagePickerView: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
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
            .navigationTitle(title)
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

private struct VoiceSwitchBanner: View {
    let progress: VoiceSwitchProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(AppTheme.primary)
            Text(progress.localizedMessage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.foreground)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 44)
        .background(AppTheme.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
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
            .accessibilityLabel(Text(LocalizedStringKey(isPreviewing ? "停止试听" : "试听")))

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "heart.fill" : "heart")
                    .foregroundColor(isFavorite ? AppTheme.primary : AppTheme.mutedForeground)
                    .frame(width: 32, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isFavorite
                ? AppLocalized("取消收藏")
                : AppLocalized("收藏")))
        }
        .padding(.vertical, 3)
    }

    private var metadata: String {
        let locale = voice.locale.isEmpty ? voice.lang.uppercased() : voice.locale
        var values = [locale]
        if voice.recommended { values.append(AppLocalized("推荐")) }
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

struct VoiceAvatarView: View {
    let voice: VoiceOption

    var body: some View {
        let route = ComputeRouting.current
        CachedAsyncImage(url: avatarURL(route: route), route: route) {
            ZStack {
                Circle().fill(fallbackColor.opacity(0.18))
                Text(initial)
                    .font(.headline.weight(.semibold))
                    .foregroundColor(fallbackColor)
            }
        }
        .clipShape(Circle())
    }

    private func avatarURL(route: ServiceRoute) -> URL? {
        [voice.avatarURL64, voice.avatarURL256]
            .compactMap { VoiceCatalogAssetURL.resolve($0, route: route) }
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

/// One player-owned entry point for selecting the voice of its active content
/// language. It owns its sheet so every full-size and mini player gets exactly
/// the same avatar, language lock and switching behavior.
@MainActor
struct PlaybackVoiceButton: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var catalog = VoiceCatalogService.shared
    @ObservedObject private var cloneStore = VoiceCloneStore.shared

    let language: String
    var size: CGFloat = 36
    var showsLabel = false
    /// Read-aloud passes this so the panel's language control becomes the way to
    /// correct which language this content is narrated in. Explain leaves it nil:
    /// its language is a user setting, not something detection can get wrong.
    var onCorrectReadingLanguage: ((String) -> Void)?

    private var normalizedLanguage: String {
        VoiceCatalog.normalizedLanguage(language)
    }

    private var voiceID: String {
        settings.voice(for: normalizedLanguage)
    }

    private var selectedVoice: VoiceOption? {
        _ = catalog.revision
        return VoiceCatalog.option(for: voiceID)
    }

    private var displayName: String {
        if let selectedVoice { return selectedVoice.name }
        if let clone = cloneStore.voices.first(where: { $0.voiceId == voiceID }) {
            return cloneStore.displayName(for: clone)
        }
        return AppLocalized("音色")
    }

    var body: some View {
        Button {
            PlaybackVoicePanelCenter.shared.present(
                language: normalizedLanguage,
                onCorrectReadingLanguage: onCorrectReadingLanguage
            )
        } label: {
            VStack(spacing: showsLabel ? 4 : 0) {
                avatar
                    .frame(width: size, height: size)
                    .overlay {
                        Circle()
                            .stroke(AppTheme.mutedForeground.opacity(0.16), lineWidth: 0.5)
                    }
                if showsLabel {
                    Text(AppLocalized("音色"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.mutedForeground)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("playbackVoiceButton")
        .accessibilityLabel(Text(AppLocalized("音色")))
        .accessibilityValue(Text(displayName))
    }

    @ViewBuilder
    private var avatar: some View {
        if let selectedVoice {
            VoiceAvatarView(voice: selectedVoice)
                .id(voiceID)
        } else {
            ZStack {
                Circle().fill(AppTheme.primary.opacity(0.16))
                Image(systemName: voiceID.hasPrefix("vc_") ? "person.wave.2.fill" : "speaker.wave.2.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)
            }
            .id(voiceID)
        }
    }
}
