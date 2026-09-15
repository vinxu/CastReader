import Foundation
import Combine

/// The view captures these small translated labels on the main actor once per
/// request. Background search never reads the mutable app-language singleton.
struct VoiceSearchVocabulary {
    let styles: [String]
    let topics: [[String]]
    @MainActor static var current: Self {
        Self(styles: VoiceDiscovery.styleRules.map { AppLocalized($0.1) },
             topics: VoiceDiscoveryTopic.allCases.map { [$0.title, $0.shortTitle] })
    }
}

struct VoiceBrowseRequest: Equatable {
    let catalogID: UUID
    let language: String
    let locale: String
    var tab: VoiceBrowserTab = .explore
    var search = ""
    var gender = ""
    var tier: VoiceTierFilter = .all
    var accent = ""
    var recommendedOnly = false
    var usage: VoiceUsageFilter = .all
    var favorites: Set<String> = []
    var recents: [String] = []
    var includingMonthly = true
    /// nil = entire language catalog; non-nil preserves a collection's order.
    var voiceIDs: [String]? = nil
    var topic: VoiceDiscoveryTopic? = nil
}

struct VoiceFeedSection: Identifiable {
    let module: VoiceDiscoveryModule
    let voices: [VoiceOption]
    var id: String { module.id }
}
struct VoiceFeedCollection: Identifiable {
    let collection: VoiceDiscoveryCollection
    let count: Int
    var id: String { collection.id }
}
struct VoiceFeedTopic: Identifiable {
    let topic: VoiceDiscoveryTopic
    let count: Int
    var id: String { topic.id }
}
struct VoiceFeedData {
    let sections: [VoiceFeedSection]
    let recommendations: [VoiceOption]
    let collections: [VoiceFeedCollection]
    let topics: [VoiceFeedTopic]
    let fallbackSections: [VoiceFeedSection]
    let validUntil: Date
}

/// One serial background worker owns bounded derived caches. SwiftUI receives
/// immutable results; neither body evaluation nor a playback update scans data.
actor VoiceBrowseWorker {
    static let shared = VoiceBrowseWorker()
    private var catalogID: UUID?
    private var searchIndexes: [String: [String: String]] = [:]
    private var queries: [(VoiceBrowseRequest, [VoiceOption])] = []
    private var feeds: [(VoiceBrowseRequest, VoiceFeedData)] = []

    private func use(_ snapshot: VoiceCatalogSnapshot) {
        guard catalogID != snapshot.id else { return }
        catalogID = snapshot.id
        searchIndexes.removeAll(); queries.removeAll(); feeds.removeAll()
    }

    func results(_ request: VoiceBrowseRequest, snapshot: VoiceCatalogSnapshot,
                 vocabulary: VoiceSearchVocabulary) throws -> [VoiceOption] {
        try Task.checkCancellation()
        use(snapshot)
        if let cached = queries.first(where: { $0.0 == request }) { return cached.1 }
        let language = VoiceCatalog.normalizedLanguage(request.language)
        let source: [VoiceOption]
        if let ids = request.voiceIDs {
            var seen = Set<String>()
            source = ids.prefix(2000).compactMap { id in
                guard seen.insert(id).inserted, let voice = snapshot.byID[id], voice.enabled else { return nil }
                return voice
            }
        } else if request.tab == .recent {
            source = request.recents.compactMap { snapshot.byID[$0] }
        } else {
            let voices = snapshot.voices(for: language, includingMonthly: request.includingMonthly)
            source = request.tab == .favorites ? voices.filter { request.favorites.contains($0.id) } : voices
        }
        let query = VoiceDiscovery.normalized(request.search)
        var index: [String: String] = [:]
        if !query.isEmpty {
            if let cached = searchIndexes[request.locale] { index = cached }
            else {
                for (offset, voice) in snapshot.byID.values.enumerated() {
                    if offset.isMultiple(of: 64) { try Task.checkCancellation() }
                    let features = VoiceDiscovery.features(voice)
                    let styles = VoiceDiscovery.styleRules.enumerated().compactMap { pair in
                        pair.element.0.isDisjoint(with: features) ? nil : vocabulary.styles[pair.offset]
                    }
                    let topics = VoiceDiscoveryTopic.allCases.enumerated().flatMap { pair in
                        pair.element.keywords.isDisjoint(with: features) ? [] : vocabulary.topics[pair.offset]
                    }
                    let raw = [voice.name, voice.id, voice.locale, voice.accent ?? "",
                               voice.description ?? "", voice.descriptionZh ?? "", voice.collection ?? ""]
                    index[voice.id] = VoiceDiscovery.normalized((raw + voice.tags + voice.bestFor + styles + topics).joined(separator: " "))
                }
                if searchIndexes.count >= 2 { searchIndexes.removeAll() }
                searchIndexes[request.locale] = index
            }
        }
        let gender = request.gender.trimmed.lowercased(), accent = request.accent.trimmed.lowercased()
        var result: [VoiceOption] = []
        for (offset, voice) in source.enumerated() {
            if offset.isMultiple(of: 64) { try Task.checkCancellation() }
            guard voice.selectable, voice.supportedLanguages.contains(language),
                  request.includingMonthly || !voice.usesMonthlyGeneration,
                  request.usage.includes(voice) else { continue }
            if !gender.isEmpty && voice.gender.trimmed.lowercased() != gender { continue }
            if !accent.isEmpty && VoiceBrowserFilter.normalizedAccentValue(for: voice) != accent { continue }
            if let topic = request.topic, !VoiceDiscovery.topics(for: voice).contains(topic) { continue }
            if request.recommendedOnly && !voice.recommended { continue }
            if request.tier == .free && voice.isPro { continue }
            if request.tier == .pro && !voice.isPro { continue }
            if !query.isEmpty && !(index[voice.id]?.contains(query) ?? false) { continue }
            result.append(voice)
        }
        queries.insert((request, result), at: 0)
        if queries.count > 8 { queries.removeLast() }
        return result
    }

    func feed(_ request: VoiceBrowseRequest, snapshot: VoiceCatalogSnapshot, now: Date = Date()) throws -> VoiceFeedData {
        try Task.checkCancellation()
        use(snapshot)
        if let cached = feeds.first(where: { $0.0 == request && $0.1.validUntil > now }) { return cached.1 }
        let voices = snapshot.voices(for: request.language, includingMonthly: request.includingMonthly)
        let indexed = Dictionary(voices.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let modules = snapshot.document?.discovery?.activeModules(from: voices, language: request.language, now: now) ?? []
        let sections = modules.map { VoiceFeedSection(module: $0, voices: $0.voiceIds.compactMap { indexed[$0] }) }
        let editorialIDs = Set(modules.flatMap(\.voiceIds))
        let collections = (snapshot.document?.collections ?? []).compactMap { collection -> VoiceFeedCollection? in
            let count = Set(collection.voiceIds).reduce(0) { count, id in
                count + (indexed[id].map { $0.enabled && $0.selectable } == true ? 1 : 0)
            }
            return count == 0 ? nil : VoiceFeedCollection(collection: collection, count: count)
        }
        let curated = Set(collections.flatMap { $0.collection.voiceIds })
        let recommendations = VoiceDiscovery.recommended(curated.isEmpty ? voices : voices.filter { curated.contains($0.id) },
            language: request.language, favoriteIDs: request.favorites, recentIDs: request.recents, excluding: editorialIDs)
        var topics: [VoiceFeedTopic] = [], fallback: [VoiceFeedSection] = []
        if collections.isEmpty {
            var byTopic: [VoiceDiscoveryTopic: [VoiceOption]] = [:]
            for voice in voices {
                try Task.checkCancellation()
                for topic in VoiceDiscovery.topics(for: voice) { byTopic[topic, default: []].append(voice) }
            }
            topics = VoiceDiscoveryTopic.allCases.compactMap { topic in
                guard let values = byTopic[topic], !values.isEmpty else { return nil }
                return VoiceFeedTopic(topic: topic, count: values.count)
            }
            var excluded = editorialIDs.union(recommendations.map(\.id))
            for topic in [VoiceDiscoveryTopic.gentle, .stories, .focus] {
                let picks = VoiceDiscovery.recommended(byTopic[topic] ?? [], language: request.language, excluding: excluded, limit: 5)
                guard !picks.isEmpty else { continue }
                excluded.formUnion(picks.prefix(topic == .stories ? 3 : 5).map(\.id))
                let module = VoiceDiscoveryModule(id: "fallback-" + topic.id, layout: topic == .stories ? "rows" : "portraits",
                    title: [:], theme: topic, voiceIds: picks.map(\.id))
                fallback.append(VoiceFeedSection(module: module, voices: picks))
            }
        }
        let parser = ISO8601DateFormatter()
        func date(_ value: String) -> Date? {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = parser.date(from: value) { return date }
            parser.formatOptions = [.withInternetDateTime]
            return parser.date(from: value)
        }
        let boundaries = snapshot.document?.discovery.map { [date($0.startsAt), date($0.endsAt)].compactMap { $0 }.filter { $0 > now } } ?? []
        let data = VoiceFeedData(sections: sections, recommendations: recommendations, collections: collections,
            topics: topics, fallbackSections: fallback, validUntil: boundaries.min() ?? .distantFuture)
        feeds.insert((request, data), at: 0)
        if feeds.count > 4 { feeds.removeLast() }
        return data
    }
}

@MainActor
final class VoiceBrowseResults: ObservableObject {
    @Published private(set) var voices: [VoiceOption] = []
    private(set) var request: VoiceBrowseRequest?
    private var generation = 0
    func update(_ input: VoiceBrowseRequest, snapshot: VoiceCatalogSnapshot) async {
        guard request != input else { return }
        generation &+= 1
        let token = generation
        let vocabulary = VoiceSearchVocabulary.current
        do {
            if !input.search.trimmed.isEmpty { try await Task.sleep(nanoseconds: 120_000_000) }
            let result = try await VoiceBrowseWorker.shared.results(input, snapshot: snapshot, vocabulary: vocabulary)
            guard !Task.isCancelled, generation == token else { return }
            request = input
            voices = result
        } catch { /* Cancelled queries must never replace the current results. */ }
    }
}

@MainActor
final class VoiceDiscoveryFeedModel: ObservableObject {
    @Published private(set) var data: VoiceFeedData?
    private(set) var request: VoiceBrowseRequest?
    func update(_ input: VoiceBrowseRequest, snapshot: VoiceCatalogSnapshot) async {
        do {
            while !Task.isCancelled {
                let result = try await VoiceBrowseWorker.shared.feed(input, snapshot: snapshot)
                try Task.checkCancellation()
                request = input
                data = result
                guard result.validUntil != .distantFuture else { return }
                let delay = max(0.05, result.validUntil.timeIntervalSinceNow)
                try await Task.sleep(nanoseconds: UInt64(min(delay, 86_400 * 30) * 1_000_000_000))
            }
        } catch { /* A new language, catalog, or disappearance cancels this task. */ }
    }
}
