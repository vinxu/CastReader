import SwiftUI
import Combine

/// Search belongs to the scrolling content. Keeping a second native search
/// controller out of a pushed voice page avoids navigation-bar/safe-area
/// relayout during interactive transitions on iOS 26.
struct VoiceBrowseSearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(AppTheme.mutedForeground)
            TextField(AppLocalized("搜索音色或听感"), text: $text)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).accessibilityIdentifier("voiceSearchField")
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(AppTheme.mutedForeground)
                }.buttonStyle(.plain).accessibilityLabel(Text(AppLocalized("清除")))
            }
        }.padding(.horizontal, 12).frame(height: 44)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal).padding(.vertical, 8)
    }
}

/// Reserve scrollable content, not another safe area on each navigation page.
/// Safe-area changes feed UIKit's scroll-offset/navigation-bar coordination.
struct VoiceBrowseContentMargins: ViewModifier {
    @ObservedObject private var metrics = BottomOverlayMetrics.shared
    func body(content: Content) -> some View {
        content.contentMargins(.bottom, metrics.height, for: .scrollContent)
    }
}

struct VoiceDiscoveryFeed: View {
    let snapshot: VoiceCatalogSnapshot
    let language: String
    let favoriteIDs: Set<String>
    let recentIDs: [String]
    let selectedID: String
    let selectingID: String?
    let onSelect: (VoiceOption) -> Void
    let onPreview: (VoiceOption) -> Void
    let onFavorite: (VoiceOption) -> Void
    let onOpenPersonal: () -> Void
    let onCreate: (VoiceCreationEntry) -> Void
    @StateObject private var model = VoiceDiscoveryFeedModel()
    @ObservedObject private var appLanguage = AppLanguageManager.shared

    private var request: VoiceBrowseRequest {
        VoiceBrowseRequest(catalogID: snapshot.id, language: language,
            locale: appLanguage.selectedLanguage.resolvedLanguageCode,
            favorites: favoriteIDs, recents: recentIDs, includingMonthly: Constants.Features.voiceCloningEnabled)
    }

    var body: some View {
        // The parent browser already owns the vertical lazy stack and its
        // pinned header. A second vertical lazy stack can repeatedly invalidate
        // its estimated height while scrolling (observed with the short French
        // feed on iOS 26). This is a bounded editorial feed, not the full catalog;
        // give the parent a stable height and keep catalog rows lazy separately.
        VStack(alignment: .leading, spacing: 28) {
            // Keep navigation origins mounted while only preference ranking
            // changes; otherwise favoriting a detail voice can pop its screen.
            if model.request?.catalogID == request.catalogID,
               model.request?.language == request.language,
               model.request?.locale == request.locale, let data = model.data {
                ForEach(data.sections) { editorialSection($0) }
                if !data.recommendations.isEmpty {
                    recommendationSection(data.recommendations)
                }
                if !data.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        heading(AppLocalized("按场景找声音"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: [GridItem(.fixed(106)), GridItem(.fixed(106))], spacing: 12) {
                                ForEach(data.collections) { item in
                                    NavigationLink(value: VoiceDiscoveryDestination.collection(item.id)) {
                                        VoiceTopicTile(topic: item.collection.theme, count: item.count, title: item.collection.localizedTitle)
                                    }.buttonStyle(.plain).accessibilityIdentifier("voiceCollection_\(item.id)")
                                }
                            }.padding(.horizontal)
                        }
                    }
                } else if !data.topics.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        heading(AppLocalized("按场景找声音"))
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHGrid(rows: [GridItem(.fixed(106)), GridItem(.fixed(106))], spacing: 12) {
                                ForEach(data.topics) { item in
                                    NavigationLink(value: item.topic) { VoiceTopicTile(topic: item.topic, count: item.count) }
                                        .buttonStyle(.plain).accessibilityIdentifier("voiceTopic_\(item.id)")
                                }
                            }.padding(.horizontal)
                        }
                    }
                }
                ForEach(data.fallbackSections) { editorialSection($0, fallback: true) }
                if !data.featuredClones.isEmpty { featuredClonesSection(data.featuredClones) }
                if Constants.Features.voiceCloningEnabled {
                    VoiceFamiliarSection(language: language, onOpen: onOpenPersonal, onCreate: onCreate).padding(.horizontal)
                }
                NavigationLink(value: VoiceDiscoveryDestination.all) {
                    HStack {
                        Label(AppLocalized("浏览全部音色"), systemImage: "square.grid.2x2")
                        Spacer(); Image(systemName: "arrow.right")
                    }.font(.subheadline.weight(.semibold)).padding(18).foregroundStyle(AppTheme.foreground)
                        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).padding(.horizontal).accessibilityIdentifier("voiceBrowseAll")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 180)
            }
        }.padding(.top, 16).padding(.bottom, 28)
            .task(id: request) { await model.update(request, snapshot: snapshot) }
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.title3.weight(.bold)).padding(.horizontal)
    }
    private func recommendationSection(_ voices: [VoiceOption]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(favoriteIDs.isEmpty && recentIDs.isEmpty ? AppLocalized("先听这几个") : AppLocalized("你可能喜欢"))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(stride(from: 0, to: voices.count, by: 2)), id: \.self) { start in
                        VStack(spacing: 6) {
                            ForEach(Array(voices.dropFirst(start).prefix(2))) { row($0).frame(width: 285) }
                        }
                    }
                }.padding(.horizontal)
            }
        }
    }
    private func featuredClonesSection(_ voices: [VoiceOption]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: VoiceDiscoveryDestination.featuredClones(voices.map(\.id))) {
                HStack {
                    Text(AppLocalized("精选音色")).font(.title3.weight(.bold)).foregroundStyle(AppTheme.foreground)
                    Spacer()
                    Image(systemName: "arrow.right").frame(width: 44, height: 32)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).padding(.horizontal).accessibilityIdentifier("voiceFeaturedClones")
            VoiceClonedSelectionNote().padding(.horizontal)
            ForEach(voices.prefix(3)) { row($0).padding(.horizontal) }
        }
    }
    private func editorialSection(_ section: VoiceFeedSection, fallback: Bool = false) -> some View {
        let module = section.module
        let selected = section.voices
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(module.layout == "feature" ? AppLocalized("本周发现") : module.localizedTitle)
                    .font(.title3.weight(.bold))
                Spacer()
                if fallback {
                    NavigationLink(value: module.theme) { Image(systemName: "arrow.right").frame(width: 44, height: 32) }
                } else {
                    NavigationLink(value: VoiceDiscoveryDestination.edition(module.id)) {
                        Image(systemName: "arrow.right").frame(width: 44, height: 32)
                    }.accessibilityLabel(Text(AppLocalized("查看全部") + " · " + module.localizedTitle))
                }
            }.padding(.horizontal)
            if module.layout == "feature" {
                NavigationLink(value: VoiceDiscoveryDestination.edition(module.id)) {
                    VoiceEditorialCover(module: module, count: selected.count)
                }.buttonStyle(.plain).accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(module.localizedTitle)).accessibilityIdentifier("voiceEdition_\(module.id)")
                    .padding(.horizontal)
                if let voice = selected.first {
                    VoiceEditorialVoiceRow(voice: voice, selected: selectedID == voice.id,
                        onSelect: { onSelect(voice) }, onPreview: { onPreview(voice) }).padding(.horizontal)
                }
            } else if module.layout == "portraits" {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(selected.prefix(8)) { voice in
                            VoicePortraitCard(voice: voice, selected: selectedID == voice.id, favorite: favoriteIDs.contains(voice.id),
                                onSelect: { onSelect(voice) }, onPreview: { onPreview(voice) }, onFavorite: { onFavorite(voice) })
                        }
                    }.padding(.horizontal)
                }
            } else {
                ForEach(selected.prefix(3)) { row($0).padding(.horizontal) }
            }
        }
    }
    private func row(_ voice: VoiceOption) -> some View {
        VoiceDiscoveryRow(voice: voice, selected: selectedID == voice.id, favorite: favoriteIDs.contains(voice.id),
            selecting: selectingID == voice.id, onSelect: { onSelect(voice) }, onPreview: { onPreview(voice) }, onFavorite: { onFavorite(voice) })
    }
}

/// Error state belongs to the preview surface, not the catalog/filter owner.
struct VoicePreviewErrorPresentation: ViewModifier {
    private let sample = VoiceSamplePlayer.shared
    @State private var error: String?
    func body(content: Content) -> some View {
        content.alert(AppLocalized("试听"), isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil; sample.previewError = nil } }
        )) { Button(AppLocalized("完成"), role: .cancel) { sample.previewError = nil } }
        message: { Text(error ?? "") }
            .onReceive(sample.$previewError.removeDuplicates()) { error = $0 }
    }
}

enum VoiceDiscoveryDestination: Hashable {
    case all, edition(String), collection(String), featuredClones([String])
}

private struct VoiceClonedSelectionNote: View {
    var body: some View {
        Text(AppLocalized("克隆音色 · 多语言适用 · 生成消耗月额度"))
            .font(.caption).foregroundStyle(AppTheme.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("voiceClonedSelectionNote")
    }
}

/// Artwork introduces the collection. Voice identity stays in its own row,
/// using the same catalog avatar, name and actions as every other category.
private struct VoiceEditorialCover: View {
    let module: VoiceDiscoveryModule
    let count: Int
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                VoiceAssetImage(url: VoiceCatalogAssetURL.resolve(module.artworkURL), route: ComputeRouting.current, pixels: 1200) {
                    Image("VoiceStoriesEditorial").resizable().scaledToFill()
                }
                .frame(width: geometry.size.width, height: geometry.size.height).clipped()
            }
            LinearGradient(stops: [.init(color: .clear, location: 0.3),
                                   .init(color: .black.opacity(0.18), location: 0.5),
                                   .init(color: .black.opacity(0.72), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 7) {
                Text(module.theme.shortTitle.uppercased())
                    .font(.caption.weight(.bold)).tracking(1.5).foregroundStyle(.white.opacity(0.8))
                Text(module.localizedTitle).font(.system(.title, design: .default).weight(.bold))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text(VoiceBrowserLanguage.voiceCountText(count))
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                }.font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.8))
            }.foregroundStyle(.white).padding(22)
        }
        .frame(height: 254)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct VoiceEditorialVoiceRow: View {
    let voice: VoiceOption
    let selected: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    @State private var previewStatus: VoiceSamplePlayer.Status = .stopped
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    var body: some View {
        HStack(spacing: 12) {
            VoiceAvatarView(voice: voice).frame(width: 48, height: 48).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Button(action: onSelect) {
                    HStack(spacing: 5) {
                        Text(voice.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.primary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain).accessibilityIdentifier("presetVoiceSelect_\(voice.id)")
                HStack(spacing: 8) {
                    Text(VoiceDiscovery.subtitle(voice, chinese: appLanguage.selectedLanguage.resolvedLanguageCode == "zh"))
                        .font(.caption).foregroundStyle(AppTheme.mutedForeground).lineLimit(1)
                    HStack(spacing: 6) {
                    VoiceUsageBadge(voice: voice)
                    if let language = voice.originalPreviewLanguageName {
                        Text(language + " · " + AppLocalized("试听"))
                            .font(.system(size: 10)).foregroundStyle(AppTheme.mutedForeground).lineLimit(1)
                    }
                }
                }
            }
            Button(action: onPreview) {
                HStack(spacing: 8) {
                    ZStack {
                        Image(systemName: previewStatus == .playing ? "stop.fill" : "play.fill")
                            .opacity(previewStatus == .loading ? 0 : 1)
                        if previewStatus == .loading { ProgressView().controlSize(.mini) }
                    }.frame(width: 14, height: 14)
                    Text(AppLocalized("试听")).lineLimit(1)
                }.font(.caption.weight(.semibold))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(AppTheme.primary)
                    .background(AppTheme.primary.opacity(0.09), in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("voicePreview_\(voice.id)")
                .accessibilityLabel(Text(AppLocalized("试听") + " · " + voice.name))
                .accessibilityValue(Text(verbatim: previewStatus.rawValue))
        }.padding(.horizontal, 4).padding(.vertical, 2)
            .onReceive(VoiceSamplePlayer.shared.$playbackState.map { $0.status(for: voice.id) }.removeDuplicates()) { previewStatus = $0 }
    }
}

private struct VoiceTopicTile: View {
    let topic: VoiceDiscoveryTopic
    let count: Int
    var title: String? = nil
    private var tint: Color {
        switch topic {
        case .everyday: return Color(red: 0.16, green: 0.49, blue: 0.48)
        case .focus: return Color(red: 0.26, green: 0.43, blue: 0.73)
        case .stories: return Color(red: 0.52, green: 0.43, blue: 0.29)
        case .gentle: return Color(red: 0.64, green: 0.36, blue: 0.46)
        case .conversation: return Color(red: 0.66, green: 0.4, blue: 0.22)
        case .character: return Color(red: 0.48, green: 0.32, blue: 0.66)
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: topic.symbol).font(.system(size: 23, weight: .medium))
                Spacer()
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).opacity(0.5)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(title ?? topic.shortTitle).font(.headline).lineLimit(2).minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                Text(String(count)).font(.caption).opacity(0.7)
            }
        }.foregroundStyle(tint).padding(16).frame(width: 178, height: 106)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text((title ?? topic.title) + " · " + VoiceBrowserLanguage.voiceCountText(count)))
    }
}

struct VoiceDiscoveryRow: View {
    let voice: VoiceOption
    let selected: Bool
    let favorite: Bool
    let selecting: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onFavorite: () -> Void
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    var body: some View {
        HStack(spacing: 11) {
            VoicePreviewAvatar(voice: voice, size: 48, onPreview: onPreview)
            VStack(alignment: .leading, spacing: 4) {
                Button(action: onSelect) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 5) {
                            Text(voice.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            if selecting { ProgressView().controlSize(.mini) }
                            else if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.primary) }
                        }
                        Text(VoiceDiscovery.subtitle(voice, chinese: appLanguage.selectedLanguage.resolvedLanguageCode == "zh"))
                            .font(.caption).foregroundStyle(AppTheme.mutedForeground).lineLimit(1)
                    }.frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityIdentifier("presetVoiceSelect_\(voice.id)")
                    .accessibilityValue(Text(selected ? AppLocalized("已选择") : ""))
                HStack(spacing: 6) {
                    VoiceUsageBadge(voice: voice)
                    if let language = voice.originalPreviewLanguageName {
                        Text(language + " · " + AppLocalized("试听"))
                            .font(.system(size: 10)).foregroundStyle(AppTheme.mutedForeground).lineLimit(1)
                    }
                }
            }
            Button(action: onFavorite) {
                Image(systemName: favorite ? "heart.fill" : "heart")
                    .foregroundStyle(favorite ? AppTheme.primary : AppTheme.mutedForeground)
                    .frame(width: 36, height: 44)
            }.buttonStyle(.plain)
                .accessibilityLabel(Text(favorite ? AppLocalized("取消收藏") : AppLocalized("收藏")))
                .accessibilityIdentifier("voiceFavorite_\(voice.id)")
        }.padding(.vertical, 6)
    }
}

private struct VoicePreviewAvatar: View {
    let voice: VoiceOption
    let size: CGFloat
    let onPreview: () -> Void
    @State private var previewStatus: VoiceSamplePlayer.Status = .stopped
    var body: some View {
        Button(action: onPreview) {
            VoiceAvatarView(voice: voice).frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    Group {
                        if previewStatus == .loading { ProgressView().controlSize(.mini).tint(.white) }
                        else { Image(systemName: previewStatus == .playing ? "stop.fill" : "play.fill").font(.system(size: 9, weight: .bold)) }
                    }.foregroundStyle(.white).frame(width: 23, height: 23)
                        .background(AppTheme.foreground, in: Circle())
                        .overlay(Circle().stroke(AppTheme.background, lineWidth: 2))
                }
        }.buttonStyle(.plain).accessibilityLabel(Text(AppLocalized("试听") + " · " + voice.name))
            .accessibilityIdentifier("voicePreview_\(voice.id)")
            .accessibilityValue(Text(verbatim: previewStatus.rawValue))
            .onReceive(VoiceSamplePlayer.shared.$playbackState.map { $0.status(for: voice.id) }.removeDuplicates()) { previewStatus = $0 }
    }
}

private struct VoicePortraitCard: View {
    let voice: VoiceOption
    let selected: Bool
    let favorite: Bool
    let onSelect: () -> Void
    let onPreview: () -> Void
    let onFavorite: () -> Void
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    var body: some View {
        VStack(spacing: 10) {
            VoicePreviewAvatar(voice: voice, size: 70, onPreview: onPreview)
            Button(action: onSelect) {
                VStack(spacing: 4) {
                    Text(voice.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(VoiceDiscovery.subtitle(voice, chinese: appLanguage.selectedLanguage.resolvedLanguageCode == "zh"))
                        .font(.caption).foregroundStyle(AppTheme.mutedForeground).lineLimit(1)
                }.frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.plain).accessibilityIdentifier("presetVoiceSelect_\(voice.id)")
                .accessibilityValue(Text(selected ? AppLocalized("已选择") : ""))
            if let language = voice.originalPreviewLanguageName {
                Text(language + " · " + AppLocalized("试听"))
                    .font(.system(size: 10)).foregroundStyle(AppTheme.mutedForeground).lineLimit(1)
            }
            HStack {
                VoiceUsageBadge(voice: voice)
                Spacer(minLength: 0)
                Button(action: onFavorite) {
                    Image(systemName: favorite ? "heart.fill" : "heart")
                        .foregroundStyle(favorite ? AppTheme.primary : AppTheme.mutedForeground)
                        .frame(width: 36, height: 36)
                }.buttonStyle(.plain)
                    .accessibilityLabel(Text(favorite ? AppLocalized("取消收藏") : AppLocalized("收藏")))
                    .accessibilityIdentifier("voiceFavorite_\(voice.id)")
            }
        }.padding(14).frame(width: 142)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(selected ? AppTheme.primary.opacity(0.5) : .clear))
    }
}

struct VoiceUsageBadge: View {
    let voice: VoiceOption
    @ObservedObject private var pro = ProManager.shared
    @State private var showsQuota = false
    var body: some View {
        Group {
            if voice.usesMonthlyGeneration {
                Button { showsQuota = true } label: {
                    Label(AppLocalized("月额度"), systemImage: "clock")
                        .foregroundStyle(AppTheme.primary)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("voiceQuota_\(voice.id)")
            } else if voice.isPro && !pro.isPro {
                Text("Pro")
                    .foregroundStyle(AppTheme.mutedForeground)
            }
        }.font(.system(size: 10, weight: .medium))
            .alert(AppLocalized("生成额度"), isPresented: $showsQuota) {
                Button(AppLocalized("完成"), role: .cancel) {}
            } message: {
                VoiceQuotaExplanation()
            }
    }
}

private struct VoiceQuotaExplanation: View {
    @ObservedObject private var store = VoiceCloneStore.shared
    var body: some View { Text(VoiceGenerationQuotaSummary.sharedExplanation) }
}

struct VoiceDiscoveryCollectionView: View {
    let title: String
    var voiceIDs: [String]? = nil
    var topic: VoiceDiscoveryTopic? = nil
    var usageScope: VoiceUsageFilter = .all
    var subgroupCollections: [VoiceDiscoveryCollection] = []
    var showsCatalogTabs = false
    let language: String
    let onSelect: (VoiceOption) -> Void
    let onPreview: (VoiceOption) -> Void
    @ObservedObject private var library = VoiceLibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var subgroupID: String?
    @State private var listeningStyle: VoiceListeningStyle = .all
    @State private var query = ""
    @State private var usage: VoiceUsageFilter = .all
    @State private var catalogTab: VoiceUsageFilter = .regular
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    @StateObject private var resultModel = VoiceBrowseResults()
    private var request: VoiceBrowseRequest {
        VoiceBrowseRequest(catalogID: VoiceCatalog.snapshot.id, language: language,
            locale: appLanguage.selectedLanguage.resolvedLanguageCode, search: query, usage: effectiveUsage,
            includingMonthly: Constants.Features.voiceCloningEnabled, allLanguages: showsCatalogTabs,
            voiceIDs: subgroupIDs, topic: topic, style: listeningStyle)
    }
    private var subgroupIDs: [String]? {
        guard let selected = subgroupCollections.first(where: { $0.id == subgroupID }) else { return voiceIDs }
        let members = Set(selected.voiceIds)
        return voiceIDs?.filter { members.contains($0) }
    }
    private var results: [VoiceOption] { resultModel.voices }
    private var effectiveUsage: VoiceUsageFilter {
        showsCatalogTabs ? catalogTab : usageScope == .all ? usage : usageScope
    }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                VoiceBrowseSearchField(text: $query)
                if showsCatalogTabs {
                    Picker(AppLocalized("全部音色"), selection: $catalogTab) {
                        Text(AppLocalized("常规音色")).tag(VoiceUsageFilter.regular)
                        Text(AppLocalized("精选音色")).tag(VoiceUsageFilter.monthly)
                    }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                        .accessibilityIdentifier("voiceCatalogTabs")
                }
                if effectiveUsage == .monthly { VoiceClonedSelectionNote().frame(maxWidth: .infinity, alignment: .leading).padding() }
                if !subgroupCollections.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            subgroupButton(AppLocalized("全部"), id: nil)
                            ForEach(subgroupCollections) { subgroupButton($0.localizedTitle, id: $0.id) }
                        }.padding(.horizontal).padding(.bottom, 12)
                    }
                }
                if resultModel.request != request {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else if results.isEmpty {
                    ContentUnavailableView(AppLocalized("没有匹配的音色"), systemImage: "waveform",
                                           description: Text(AppLocalized("尝试其他搜索或筛选条件"))).padding(.top, 50)
                } else {
                    ForEach(results) { voice in
                        VoiceDiscoveryRow(voice: voice, selected: settings.voice(for: voice.usesMonthlyGeneration ? language : voice.lang) == voice.id,
                                          favorite: library.isFavorite(voice.id), selecting: false,
                                          onSelect: { onSelect(voice) }, onPreview: { onPreview(voice) },
                                          onFavorite: { library.toggleFavorite(voice.id) }).padding(.horizontal)
                        if showsCatalogTabs && !voice.usesMonthlyGeneration {
                            Text(Locale(identifier: appLanguage.selectedLanguage.resolvedLanguageCode).localizedString(forLanguageCode: voice.lang) ?? voice.lang)
                                .font(.caption2).foregroundStyle(AppTheme.mutedForeground)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 76).padding(.bottom, 6)
                        }
                        Divider().padding(.leading, 76)
                    }
                }
            }.padding(.vertical, 12)
        }.background(AppTheme.background).modifier(VoiceBrowseContentMargins())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .task(id: request) { await resultModel.update(request, snapshot: VoiceCatalog.snapshot) }
            .onDisappear { VoiceSamplePlayer.shared.stop() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(AppLocalized("声音特点"), selection: $listeningStyle) {
                            ForEach(VoiceListeningStyle.allCases) { Text($0.title).tag($0) }
                        }
                        if usageScope == .all && !showsCatalogTabs {
                            Picker(AppLocalized("使用权益"), selection: $usage) {
                                ForEach(VoiceUsageFilter.allCases) { Text($0.title).tag($0) }
                            }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .accessibilityLabel(Text(AppLocalized("筛选")))
                }
            }
    }
    private func subgroupButton(_ title: String, id: String?) -> some View {
        Button { subgroupID = id } label: {
            Text(title).font(.subheadline.weight(.medium)).padding(.horizontal, 14).padding(.vertical, 9)
                .foregroundStyle(subgroupID == id ? AppTheme.primary : AppTheme.foreground)
                .background(subgroupID == id ? AppTheme.primary.opacity(0.1) : AppTheme.surface, in: Capsule())
        }.buttonStyle(.plain).accessibilityIdentifier("voiceIdentity_" + (id ?? "all"))
    }

}

/// Only this compact section observes personal voice state, keeping account and
/// invitation updates out of the catalog/recommendation computation path.
private struct VoiceFamiliarSection: View {
    let language: String
    let onOpen: () -> Void
    let onCreate: (VoiceCreationEntry) -> Void
    @ObservedObject private var store = VoiceCloneStore.shared
    @ObservedObject private var auth = AuthService.shared
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var preview = VoiceClonePreviewPlayer.shared
    @State private var selectingID: String?
    @State private var selectionTask: Task<Void, Never>?
    @State private var selectionOperation: UUID?

    var body: some View {
        VoiceFamiliarContent(voices: auth.isSignedIn ? store.familiarVoices : [],
            name: store.displayName, selectedID: settings.activeClonedVoiceID(for: language),
            selectingID: selectingID, playingID: preview.playingVoiceId, loadingID: preview.loadingVoiceId,
            onOpen: onOpen, onCreate: onCreate, onPreview: preview.toggle, onSelect: { voice in
                guard selectingID == nil else { return }
                let operation = UUID()
                selectionOperation = operation
                selectingID = voice.id
                selectionTask = Task { @MainActor in
                    defer {
                        if selectionOperation == operation {
                            selectingID = nil; selectionOperation = nil; selectionTask = nil
                        }
                    }
                    _ = await store.select(voice, for: language)
                }
            })
            .onDisappear { stopInteractions() }
            .onChange(of: language) { _ in stopInteractions() }
            .onChange(of: auth.accountBoundaryID) { _ in stopInteractions() }
            .alert(AppLocalized("声音克隆"), isPresented: Binding(
                get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } }
            )) { Button("完成") { store.errorMessage = nil } }
            message: { Text(store.errorMessage ?? "") }
    }

    private func stopInteractions() {
        selectionTask?.cancel(); selectionTask = nil; selectingID = nil; selectionOperation = nil
        let ids = Set(store.familiarVoices.map(\.id))
        if preview.playingVoiceId.map(ids.contains) == true || preview.loadingVoiceId.map(ids.contains) == true {
            preview.stop()
        }
    }
}

/// Presentation stays independent of catalog ranking and account fetching.
struct VoiceFamiliarContent: View {
    let voices: [ClonedVoice]
    let name: (ClonedVoice) -> String
    let selectedID: String?
    let selectingID: String?
    let playingID: String?
    let loadingID: String?
    let onOpen: () -> Void
    let onCreate: (VoiceCreationEntry) -> Void
    let onPreview: (ClonedVoice) -> Void
    let onSelect: (ClonedVoice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(AppLocalized("听见熟悉的声音")).font(.title3.weight(.bold))
                Spacer()
                if !voices.isEmpty {
                    Button(action: onOpen) { Image(systemName: "arrow.right").frame(width: 44, height: 44) }
                        .buttonStyle(.plain).foregroundStyle(AppTheme.primary)
                        .accessibilityLabel(AppLocalized("查看全部"))
                        .accessibilityIdentifier("voiceFamiliarAll")
                }
            }
            if voices.isEmpty {
                entry(title: AppLocalized("我的声音"), action: AppLocalized("录制自己的声音"),
                      symbol: "mic", id: "voiceFamiliarSelf") { onCreate(.recordMyVoice) }
                entry(title: AppLocalized("朋友的声音"), action: AppLocalized("邀请朋友录制声音"),
                      symbol: "person.2", id: "voiceFamiliarFriend") {
                    onCreate(VoiceGiftFeature.isRegionEligible() ? .inviteFriend : .chooser)
                }
            } else {
                ForEach(voices.prefix(3)) { voice in
                    HStack(spacing: 14) {
                        Button { onPreview(voice) } label: {
                            ClonedVoiceAvatarView(voice: voice, size: 50, isAnimating: playingID == voice.id)
                                .overlay(alignment: .bottomTrailing) {
                                    ZStack {
                                        Circle().fill(AppTheme.foreground)
                                        if loadingID == voice.id { ProgressView().controlSize(.mini).tint(AppTheme.surface) }
                                        else { Image(systemName: playingID == voice.id ? "stop.fill" : "play.fill")
                                            .font(.system(size: 10, weight: .bold)).foregroundStyle(AppTheme.surface) }
                                    }.frame(width: 24, height: 24)
                                        .overlay(Circle().stroke(AppTheme.background, lineWidth: 2)).offset(x: 2, y: 2)
                                }
                        }.buttonStyle(.plain).disabled(!voice.access.capabilities.canPreview)
                            .accessibilityLabel(AppLocalized(playingID == voice.id ? "停止试听" : "试听") + " · " + name(voice))
                            .accessibilityValue(loadingID == voice.id ? "loading" : (playingID == voice.id ? "playing" : "stopped"))
                            .accessibilityIdentifier("voiceFamiliarPreview_" + voice.id)
                        Button { onSelect(voice) } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(name(voice)).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.foreground).lineLimit(1)
                                    HStack(spacing: 8) {
                                        Text(AppLocalized(voice.isInvitedVoice ? "朋友的声音" : "我的声音"))
                                            .foregroundStyle(AppTheme.mutedForeground)
                                        Label(AppLocalized("月额度"), systemImage: "clock")
                                            .foregroundStyle(AppTheme.primary)
                                    }.font(.caption).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if selectingID == voice.id { ProgressView().controlSize(.small) }
                                else if selectedID == voice.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(AppTheme.primary) }
                            }.frame(minHeight: 50).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(selectingID != nil)
                            .accessibilityValue(selectedID == voice.id ? AppLocalized("已选择") : "")
                            .accessibilityIdentifier("voiceFamiliarSelect_" + voice.id)
                    }.padding(.vertical, 6)
                }
            }
        }
    }
    private func entry(title: String, action: String, symbol: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.title3).foregroundStyle(AppTheme.primary).frame(width: 38, height: 42)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(AppTheme.foreground)
                    Text(action).font(.caption).foregroundStyle(AppTheme.mutedForeground)
                }
                Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(AppTheme.mutedForeground)
            }.padding(12).background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier(id)
    }
}
