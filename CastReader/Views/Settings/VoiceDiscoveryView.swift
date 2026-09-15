import SwiftUI

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
    @StateObject private var model = VoiceDiscoveryFeedModel()
    @ObservedObject private var appLanguage = AppLanguageManager.shared

    private var request: VoiceBrowseRequest {
        VoiceBrowseRequest(catalogID: snapshot.id, language: language,
            locale: appLanguage.selectedLanguage.resolvedLanguageCode,
            favorites: favoriteIDs, recents: recentIDs, includingMonthly: Constants.Features.voiceCloningEnabled)
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 28) {
            if model.request == request, let data = model.data {
                ForEach(data.sections) { editorialSection($0) }
                if !data.recommendations.isEmpty {
                    recommendationSection(data.recommendations)
                }
                if !data.collections.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        heading(AppLocalized("声音专题"))
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
                        heading(AppLocalized("声音专题"))
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
            heading(AppLocalized("先听这几个"))
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
    @ObservedObject private var sample = VoiceSamplePlayer.shared
    func body(content: Content) -> some View {
        content.alert(AppLocalized("试听"), isPresented: Binding(
            get: { sample.previewError != nil }, set: { if !$0 { sample.previewError = nil } }
        )) { Button(AppLocalized("完成"), role: .cancel) { sample.previewError = nil } }
        message: { Text(sample.previewError ?? "") }
    }
}

enum VoiceDiscoveryDestination: Hashable { case all, edition(String), collection(String) }

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
    @ObservedObject private var sample = VoiceSamplePlayer.shared
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
                Group {
                    if sample.loadingVoiceID == voice.id { ProgressView().controlSize(.small) }
                    else {
                        Label(AppLocalized("试听"), systemImage: sample.playingVoiceID == voice.id ? "stop.fill" : "play.fill")
                            .font(.caption.weight(.bold))
                    }
                }.frame(minWidth: 60, minHeight: 40).padding(.horizontal, 8)
                    .foregroundStyle(AppTheme.primary)
                    .background(AppTheme.primary.opacity(0.09), in: Capsule())
            }.buttonStyle(.plain).accessibilityIdentifier("voicePreview_\(voice.id)")
                .accessibilityLabel(Text(AppLocalized("试听") + " · " + voice.name))
                .accessibilityValue(sample.playingVoiceID == voice.id ? "playing" : sample.loadingVoiceID == voice.id ? "loading" : "stopped")
        }.padding(.horizontal, 4).padding(.vertical, 2)
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
    @ObservedObject private var sample = VoiceSamplePlayer.shared
    var body: some View {
        Button(action: onPreview) {
            VoiceAvatarView(voice: voice).frame(width: size, height: size)
                .overlay(alignment: .bottomTrailing) {
                    Group {
                        if sample.loadingVoiceID == voice.id { ProgressView().controlSize(.mini).tint(.white) }
                        else { Image(systemName: sample.playingVoiceID == voice.id ? "stop.fill" : "play.fill").font(.system(size: 9, weight: .bold)) }
                    }.foregroundStyle(.white).frame(width: 23, height: 23)
                        .background(AppTheme.foreground, in: Circle())
                        .overlay(Circle().stroke(AppTheme.background, lineWidth: 2))
                }
        }.buttonStyle(.plain).accessibilityLabel(Text(AppLocalized("试听") + " · " + voice.name))
            .accessibilityIdentifier("voicePreview_\(voice.id)")
            .accessibilityValue(sample.playingVoiceID == voice.id ? "playing" : sample.loadingVoiceID == voice.id ? "loading" : "stopped")
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
            } else {
                Text(pro.isPro ? AppLocalized("不限时") : voice.isPro ? "Pro" : AppLocalized("免费"))
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
    let language: String
    let onSelect: (VoiceOption) -> Void
    let onPreview: (VoiceOption) -> Void
    @ObservedObject private var library = VoiceLibraryStore.shared
    @ObservedObject private var settings = AppSettings.shared
    @State private var query = ""
    @State private var usage: VoiceUsageFilter = .all
    @ObservedObject private var appLanguage = AppLanguageManager.shared
    @StateObject private var resultModel = VoiceBrowseResults()
    private var request: VoiceBrowseRequest {
        VoiceBrowseRequest(catalogID: VoiceCatalog.snapshot.id, language: language,
            locale: appLanguage.selectedLanguage.resolvedLanguageCode, search: query, usage: usage,
            includingMonthly: Constants.Features.voiceCloningEnabled, voiceIDs: voiceIDs, topic: topic)
    }
    private var results: [VoiceOption] { resultModel.voices }
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if resultModel.request != request {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                } else if results.isEmpty {
                    ContentUnavailableView(AppLocalized("没有匹配的音色"), systemImage: "waveform",
                                           description: Text(AppLocalized("尝试其他搜索或筛选条件"))).padding(.top, 50)
                } else {
                    ForEach(results) { voice in
                        VoiceDiscoveryRow(voice: voice, selected: settings.voice(for: language) == voice.id,
                                          favorite: library.isFavorite(voice.id), selecting: false,
                                          onSelect: { onSelect(voice) }, onPreview: { onPreview(voice) },
                                          onFavorite: { library.toggleFavorite(voice.id) }).padding(.horizontal)
                        Divider().padding(.leading, 76)
                    }
                }
            }.padding(.vertical, 12)
        }.background(AppTheme.background).reservesMiniPlayerSpace()
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: AppLocalized("搜索音色或听感"))
            .task(id: request) { await resultModel.update(request, snapshot: VoiceCatalog.snapshot) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker(AppLocalized("使用权益"), selection: $usage) {
                            ForEach(VoiceUsageFilter.allCases) { Text($0.title).tag($0) }
                        }
                    } label: { Image(systemName: "line.3.horizontal.decrease") }
                    .accessibilityLabel(Text(AppLocalized("使用权益")))
                }
            }
    }
}
