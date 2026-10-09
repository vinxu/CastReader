import XCTest
@testable import CastReader

final class VoiceDiscoveryTests: XCTestCase {
    @MainActor
    func testEditorialTitlesUseLocalizedTopicWhenRemoteEditionLacksTheUILanguage() {
        let language = AppLanguageManager.shared
        let original = language.selectedLanguage
        defer { language.select(original) }
        let module = VoiceDiscoveryModule(id: "untranslated", layout: "feature",
            title: ["en": "Remote edition headline"], theme: .everyday, voiceIds: [])
        let collection = VoiceDiscoveryCollection(id: "untranslated", title: module.title,
            theme: .stories, voiceIds: [])
        for locale in AppLanguage.allCases where locale != .system {
            language.select(locale)
            XCTAssertEqual(module.localizedTitle, locale == .english ? "Remote edition headline" : VoiceDiscoveryTopic.everyday.title)
            XCTAssertEqual(collection.localizedTitle, locale == .english ? "Remote edition headline" : VoiceDiscoveryTopic.stories.title)
        }
        language.select(.brazilianPortuguese)
        XCTAssertEqual(VoiceDiscovery.localizedEditorialTitle(["pt-BR": "Título regional", "pt": "Título base"], theme: .everyday), "Título regional")
        language.select(.arabic)
        XCTAssertEqual(VoiceDiscovery.localizedEditorialTitle(["ar": "  ", "en": "English"], theme: .everyday), VoiceDiscoveryTopic.everyday.title)
        XCTAssertEqual(VoiceDiscovery.localizedEditorialTitle(["ar": "عنوان جديد"], theme: .everyday), "عنوان جديد")
    }

    private func voice(_ id: String, tags: [String] = [], language: String = "en", monthly: Bool = false) -> VoiceOption {
        VoiceOption(code: id, name: id, isPro: monthly, lang: language, gender: "female",
                    tags: tags, sampleURL: "https://api.castreader.ai/preview.mp3",
                    usagePolicy: monthly ? "monthly_generation" : "regular",
                    supportedLanguages: monthly ? ["en", "zh"] : [language],
                    sampleURLs: monthly ? ["en": "/api/voice-clone/public/\(id)/preview?language=en", "zh": "/api/voice-clone/public/\(id)/preview?language=zh"] : [:])
    }

    func testClassificationUsesStyleAndPurposeWithoutEngineBuckets() {
        let first = voice("af_warm", tags: ["warm", "narration"])
        let second = voice("vl_warm", tags: ["warm", "narration"], monthly: true)
        XCTAssertEqual(VoiceDiscovery.topics(for: first), VoiceDiscovery.topics(for: second))
        XCTAssertTrue(VoiceDiscovery.topics(for: first).contains(.gentle))
        XCTAssertTrue(VoiceUsageFilter.monthly.includes(second))
        XCTAssertFalse(VoiceUsageFilter.monthly.includes(first))
        XCTAssertTrue(VoiceDiscovery.topics(for: voice("unknown")).isEmpty)
    }

    func testRecommendationKeepsUnknownVoicesSearchableAndDeduplicates() {
        let warm = voice("warm", tags: ["warm"])
        let unknown = voice("unknown")
        let picks = VoiceDiscovery.recommended([warm, warm, unknown], language: "en", favoriteIDs: ["warm"])
        XCTAssertEqual(picks.map(\.id), ["warm", "unknown"])
        XCTAssertTrue(VoiceBrowserFilter.apply(voices: [unknown], search: "unknown", language: "en", gender: "", tier: .all).contains(unknown))
    }

    func testFavoriteFromEditorialModuleCanGuideOtherRecommendations() {
        let favorite = voice("featured", tags: ["warm", "soft"])
        let bright = voice("a_bright", tags: ["bright", "crisp"])
        let similar = voice("z_soft", tags: ["warm", "soft"])
        let picks = VoiceDiscovery.recommended([bright, similar], language: "en",
            favoriteIDs: [favorite.id], preferenceSource: [favorite, bright, similar])
        XCTAssertEqual(picks.first?.id, similar.id)
        XCTAssertFalse(picks.contains(favorite))
    }

    func testWeeklyEditionUsesSourceLanguageWithoutRestrictingSynthesis() {
        let regular = voice("af_en")
        let publicVoice = voice("vl_story", tags: ["storytelling"], monthly: true)
        let modules = [VoiceDiscoveryModule(id: "story", layout: "feature", title: ["en": "Stories"], theme: .stories,
                                           voiceIds: ["missing", regular.id, publicVoice.id, publicVoice.id]),
                       VoiceDiscoveryModule(id: "repeat", layout: "rows", title: ["en": "More"], theme: .stories, voiceIds: [publicVoice.id])]
        let edition = VoiceDiscoveryEdition(id: "week", startsAt: "2026-09-14T00:00:00Z", endsAt: "2026-09-21T00:00:00Z", modules: modules)
        let now = ISO8601DateFormatter().date(from: "2026-09-15T00:00:00Z")!
        let chinese = edition.activeModules(from: [regular, publicVoice], language: "zh", now: now)
        XCTAssertTrue(chinese.isEmpty, "English-source clones belong in English recommendations")
        XCTAssertTrue(publicVoice.supports("zh"), "Recommendation language must not restrict synthesis")
        XCTAssertEqual(edition.activeModules(from: [regular, publicVoice], language: "en", now: now).first?.voiceIds,
                       [regular.id, publicVoice.id])
        XCTAssertTrue(edition.activeModules(from: [regular, publicVoice], language: "en", now: now.addingTimeInterval(7 * 86400)).isEmpty)
    }

    func testMalformedEditorialContentDoesNotInvalidatePlayableCatalog() throws {
        let source = #"{"contract":"tts-voice-catalog-v1","version":"test","languages":[{"code":"en","locale":"en-US","name":"English","status":"ga","defaultVoice":"af_heart","timestampMode":"word"}],"voices":[{"id":"af_heart","name":"Heart","engine":"kokoro","modelVersion":"v1","language":"en","locale":"en-US","genderPresentation":"female","tier":"free","status":"ga","enabled":true,"selectable":true,"timestampMode":"word"}],"discovery":{"unknownVersion":100}}"#
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(from: Data(source.utf8))
        XCTAssertNil(catalog.discovery)
        XCTAssertEqual(catalog.voices.first?.id, "af_heart")
        XCTAssertEqual(try JSONDecoder().decode(TTSVoiceCatalogDocument.self, from: JSONEncoder().encode(catalog)), catalog)
    }

    func testOriginalAvatarAndEditorialArtworkResolveOnSelectedRegion() throws {
        let avatar = "/voice-library/avatars/v_original-1234.jpg"
        let artwork = "/voice-discovery/artwork/stories-paper-world.png"
        for path in [avatar, artwork] {
            XCTAssertEqual(VoiceCatalogAssetURL.resolve(path, route: .globalGateway)?.host, "api.castreader.ai")
            XCTAssertEqual(VoiceCatalogAssetURL.resolve(path, route: .chinaGateway)?.host, "api.castreader.cn")
        }
        let module = VoiceDiscoveryModule(id: "story", layout: "feature", title: ["en": "Stories"], theme: .stories,
                                          voiceIds: ["vl_story"], artworkURL: artwork)
        XCTAssertEqual(try JSONDecoder().decode(VoiceDiscoveryModule.self, from: JSONEncoder().encode(module)), module)
    }

    func testOperationalCollectionKeepsOrderMembershipAndCrossLanguageIdentity() throws {
        let regular = voice("af_en")
        let community = voice("vl_story", monthly: true)
        let collection = VoiceDiscoveryCollection(id: "cn-stories", title: ["en": "Stories", "zh": "故事现场"],
            theme: .stories, voiceIds: [community.id, regular.id, community.id, "withdrawn"])
        XCTAssertEqual(collection.voices(from: [regular, community], language: "en").map(\.id), [community.id, regular.id])
        XCTAssertEqual(collection.voices(from: [regular, community], language: "zh").map(\.id), [community.id])
        XCTAssertEqual(try JSONDecoder().decode(VoiceDiscoveryCollection.self, from: JSONEncoder().encode(collection)), collection)
    }

    @MainActor
    func testEditorialCacheIsIndependentFromServiceRoute() {
        let cnOnGlobal = VoiceCatalogService.cacheKey(for: .globalGateway, region: .cn)
        let internationalOnGlobal = VoiceCatalogService.cacheKey(for: .globalGateway, region: .international)
        XCTAssertNotEqual(cnOnGlobal, internationalOnGlobal)
        XCTAssertNotEqual(cnOnGlobal, VoiceCatalogService.cacheKey(for: .chinaGateway, region: .cn))
        XCTAssertEqual(VoiceEditorialRegion.allCases.count, 2)
    }

}

extension VoiceDiscoveryTests {
    private func standardVoiceID(_ language: String) -> String {
        SupportedTTSLanguage(identifier: language)?.isGoogle == true ? "api_\(language)_fixture" : "default_\(language)"
    }

    private func fullSnapshot(region: String = "cn", suffix: String = "") throws -> VoiceCatalogSnapshot {
        let codes = SupportedTTSLanguage.allCases.map(\.rawValue)
        func entry(_ id: String, _ language: String, _ monthly: Bool) -> [String: Any] {
            var item: [String: Any] = ["id": id, "name": id + suffix, "engine": monthly ? "clone" : (SupportedTTSLanguage(identifier: language)?.isGoogle == true ? "google" : "kokoro"),
                "modelVersion": SupportedTTSLanguage(identifier: language)?.isGoogle == true && !monthly ? "wavenet" : "v1", "language": language, "locale": language, "genderPresentation": "female",
                "tier": monthly ? "pro" : "free", "status": "ga", "enabled": true, "selectable": true,
                "timestampMode": "word", "sampleUrl": "https://example.invalid/preview/" + id, "tags": ["warm", "storytelling"], "description": "A calm narrator"]
            if monthly {
                let supported = ["en", "zh", "ja", "es", "fr", "de", "pt", "it", "ko", "ru"]
                item["usagePolicy"] = "monthly_generation"
                item["supportedLanguages"] = supported
                item["sampleUrls"] = Dictionary(uniqueKeysWithValues: supported.map { ($0, "/preview/\(id)/\($0)") })
            }
            return item
        }
        var voices = codes.map { entry(standardVoiceID($0), $0, false) }
        voices += (0..<274).map { entry("regular_\($0)", "en", false) }
        voices += (0..<1323).map { entry("vl_performance_\($0)", "en", true) }
        let languages: [[String: Any]] = codes.map { ["code": $0, "locale": $0, "name": $0, "status": "ga", "defaultVoice": standardVoiceID($0), "timestampMode": "word"] }
        let object: [String: Any] = ["contract": "tts-voice-catalog-v2", "version": "performance-" + region + suffix,
            "languages": languages, "voices": voices, "editorialRegion": region]
        var document = try TTSVoiceCatalogDocument.decodeServerResponse(from: JSONSerialization.data(withJSONObject: object))
        document.discovery = VoiceDiscoveryEdition(id: region, startsAt: "2026-09-14T00:00:00Z", endsAt: "2026-09-21T00:00:00Z", modules: [
            VoiceDiscoveryModule(id: region + "-stories", layout: "feature", title: ["en": "Stories"], theme: .stories, voiceIds: ["vl_performance_1322", "default_en"])
        ])
        document.collections = [VoiceDiscoveryCollection(id: region + "-collection", title: ["en": "Stories"], theme: .stories,
            voiceIds: ["vl_performance_1322", "vl_performance_0", "default_en"])]
        return VoiceCatalogSnapshot(document: document)
    }

    func testFullCatalogSnapshotIndexesLanguagesAndPreservesIdentity() throws {
        let snapshot = try fullSnapshot()
        XCTAssertEqual(snapshot.all.count, 1625)
        XCTAssertEqual(snapshot.languages.count, 28)
        XCTAssertEqual(snapshot.voices(for: "en", includingMonthly: true).count, 1598)
        XCTAssertEqual(snapshot.voices(for: "zh-Hans", includingMonthly: true).count, 1324)
        XCTAssertEqual(snapshot.voices(for: "zh", includingMonthly: false).map(\.id), ["default_zh"])
        XCTAssertEqual(snapshot.voices(for: "hi", includingMonthly: true).count, 1)
        let id = "vl_performance_1322"
        XCTAssertEqual(snapshot.voices(for: "zh", includingMonthly: true).last, snapshot.byID[id])
        let replacement = try fullSnapshot(region: "international", suffix: " updated")
        XCTAssertNotEqual(replacement.id, snapshot.id)
        XCTAssertEqual(snapshot.byID[id]?.name, id, "An in-flight request must retain its original immutable data")
        XCTAssertEqual(replacement.byID[id]?.name, id + " updated")
        let start = DispatchTime.now().uptimeNanoseconds
        var total = 0
        for _ in 0..<1000 { total += snapshot.voices(for: "zh", includingMonthly: true).count + snapshot.languages.count }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
        XCTAssertEqual(total, 1_352_000)
        XCTAssertLessThan(elapsed, 200, "Warm lookups must not rebuild 1,625 voice records")
        print("VOICE_PERF full catalog 1,000 language lookups: \(elapsed) ms")
    }

    @MainActor
    func testIndexedSearchMatchesFiltersAndKeepsCollectionOrder() async throws {
        let snapshot = try fullSnapshot(), worker = VoiceBrowseWorker()
        let vocabulary = VoiceSearchVocabulary.current
        var request = VoiceBrowseRequest(catalogID: snapshot.id, language: "zh", locale: "en")
        for query in ["", "calm", "WARM", "performance_1322", VoiceDiscovery.styleLabels(for: snapshot.all.last!).first!] {
            request.search = query
            let result = try await worker.results(request, snapshot: snapshot, vocabulary: vocabulary)
            let expected = VoiceBrowserFilter.apply(voices: snapshot.voices(for: "zh", includingMonthly: true), search: query, language: "zh", gender: "", tier: .all)
            XCTAssertEqual(result.map(\.id), expected.map(\.id), "Query: \(query)")
        }
        request.search = ""
        request.voiceIDs = ["vl_performance_1322", "missing", "vl_performance_0", "vl_performance_1322", "default_en"]
        let ordered = try await worker.results(request, snapshot: snapshot, vocabulary: vocabulary)
        XCTAssertEqual(ordered.map(\.id), ["vl_performance_1322", "vl_performance_0"])
        request.includingMonthly = false
        let hidden = try await worker.results(request, snapshot: snapshot, vocabulary: vocabulary)
        XCTAssertTrue(hidden.isEmpty)
    }

    @MainActor
    func testSearchInvalidatesWhenCatalogChangesAndLatestQueryWins() async throws {
        let first = try fullSnapshot(), next = try fullSnapshot(region: "international", suffix: " updated")
        let worker = VoiceBrowseWorker(), vocabulary = VoiceSearchVocabulary.current
        var request = VoiceBrowseRequest(catalogID: first.id, language: "zh", locale: "en", search: "updated")
        let old = try await worker.results(request, snapshot: first, vocabulary: vocabulary)
        XCTAssertTrue(old.isEmpty)
        request = VoiceBrowseRequest(catalogID: next.id, language: "zh", locale: "en", search: "updated")
        let refreshed = try await worker.results(request, snapshot: next, vocabulary: vocabulary)
        XCTAssertEqual(refreshed.count, 1324)
        let model = VoiceBrowseResults()
        var slow = request; slow.search = "performance_0"
        let oldQuery = Task { await model.update(slow, snapshot: next) }
        await Task.yield()
        var latest = request; latest.search = "performance_1322"
        await model.update(latest, snapshot: next)
        await oldQuery.value
        XCTAssertEqual(model.request, latest)
        XCTAssertEqual(model.voices.map(\.id), ["vl_performance_1322"])
    }

    func testFeedCacheHonorsRegionLanguageAndEditionExpiry() async throws {
        let cn = try fullSnapshot(), international = try fullSnapshot(region: "international")
        let worker = VoiceBrowseWorker()
        let now = ISO8601DateFormatter().date(from: "2026-09-15T00:00:00Z")!
        let cnRequest = VoiceBrowseRequest(catalogID: cn.id, language: "zh", locale: "zh")
        let feed = try await worker.feed(cnRequest, snapshot: cn, now: now)
        XCTAssertTrue(feed.sections.isEmpty)
        XCTAssertTrue(feed.featuredClones.isEmpty, "English-source clones must not populate Chinese recommendations")
        XCTAssertTrue(feed.collections.isEmpty)
        let expired = try await worker.feed(cnRequest, snapshot: cn, now: now.addingTimeInterval(7 * 86400))
        XCTAssertTrue(expired.sections.isEmpty)
        XCTAssertTrue(expired.featuredClones.isEmpty)
        let next = try await worker.feed(.init(catalogID: international.id, language: "en", locale: "en"), snapshot: international, now: now)
        XCTAssertEqual(next.sections.first?.id, "international-stories")
        XCTAssertEqual(next.collections.first?.count, 1)
        XCTAssertEqual(next.sections.first?.voices.map(\.id), ["default_en"])
    }
}

extension VoiceDiscoveryTests {
    func testScenesUseExplicitChinesePurposesAndKeepTimbreSeparate() {
        let reading = VoiceOption(code: "zf_read", name: "Reading", isPro: false, lang: "zh", gender: "female",
                                  tags: ["low", "measured"], bestFor: ["长文阅读", "专注学习"])
        XCTAssertEqual(VoiceDiscovery.purpose(for: reading), .stories)
        XCTAssertFalse(VoiceDiscovery.topics(for: reading).contains(.focus), "Generic study metadata without a clarity signal must not duplicate the entire long-reading category")
        XCTAssertTrue(VoiceListeningStyle.grounded.includes(reading))
        let news = VoiceOption(code: "zf_news", name: "News", isPro: false, lang: "zh", gender: "female",
                               tags: ["soft", "brisk"], bestFor: ["文章资讯", "知识讲解"])
        XCTAssertEqual(VoiceDiscovery.purpose(for: news), .everyday)
        XCTAssertFalse(VoiceDiscovery.topics(for: news).contains(.gentle), "Fast delivery must not become bedtime listening merely because timbre is soft")
        let clear = voice("clear-only", tags: ["clear"])
        XCTAssertNil(VoiceDiscovery.purpose(for: clear), "Timbre alone cannot establish educational use")
        XCTAssertEqual(VoiceDiscoveryTopic.browseCases, [.everyday, .stories, .focus, .gentle])
    }

    @MainActor
    func testClonePopularityCannotDisplaceRegularRecommendationsAndStyleFiltersWork() async throws {
        let snapshot = try fullSnapshot(), worker = VoiceBrowseWorker()
        let date = ISO8601DateFormatter().date(from: "2026-09-15T00:00:00Z")!
        let input = VoiceBrowseRequest(catalogID: snapshot.id, language: "en", locale: "en",
            favorites: Set((0..<100).map { "vl_performance_\($0)" }))
        let feed = try await worker.feed(input, snapshot: snapshot, now: date)
        XCTAssertFalse(feed.recommendations.isEmpty)
        XCTAssertTrue(feed.recommendations.allSatisfy { !$0.usesMonthlyGeneration })
        XCTAssertTrue(feed.sections.flatMap(\.voices).allSatisfy { !$0.usesMonthlyGeneration })
        XCTAssertTrue(feed.fallbackSections.flatMap(\.voices).allSatisfy { !$0.usesMonthlyGeneration })
        XCTAssertEqual(feed.featuredClones.map(\.id), ["vl_performance_1322"])
        var filter = input; filter.style = .bright
        let bright = try await worker.results(filter, snapshot: snapshot, vocabulary: .current)
        XCTAssertTrue(bright.isEmpty)
        filter.style = .gentle
        let gentle = try await worker.results(filter, snapshot: snapshot, vocabulary: .current)
        XCTAssertEqual(gentle.count, 1598)
    }
}

extension VoiceDiscoveryTests {
    @MainActor
    func testEveryCommunitySourceLanguageGetsItsOwnCuratedPool() async throws {
        // A multilingual CMS pool is split over bounded modules. Filtering must
        // happen before the six-card limit, even after cycling the feed cache.
        let languages = ["en", "zh", "ja", "de", "fr", "es", "pt", "ko", "ru"]
        let regularLanguages = languages.filter { SupportedTTSLanguage(identifier: $0) != nil }
        let outputLanguages = languages + ["it"]
        var voices: [[String: Any]] = regularLanguages.map { language in
            ["id": standardVoiceID(language), "name": language, "engine": SupportedTTSLanguage(identifier: language)?.isGoogle == true ? "google" : "kokoro", "modelVersion": SupportedTTSLanguage(identifier: language)?.isGoogle == true ? "wavenet" : "test",
             "language": language, "locale": language, "genderPresentation": "female", "tier": "free",
             "status": "ga", "enabled": true, "selectable": true, "timestampMode": "word",
             "sampleUrl": "https://example.invalid/\(language).mp3"]
        }
        var cloneIDs: [String] = []
        for language in languages {
            for index in 0..<(language == "ru" ? 4 : 6) {
                let id = "vl_\(language)_\(index)"
                cloneIDs.append(id)
                voices.append([
                    "id": id, "name": id, "engine": "clone", "modelVersion": "test",
                    "language": ["ko", "ru"].contains(language) ? "en" : language,
                    "referenceLanguage": language, "locale": language, "genderPresentation": "female",
                    "tier": "pro", "status": "ga", "enabled": true, "selectable": true,
                    "timestampMode": "sentence", "usagePolicy": "monthly_generation",
                    "supportedLanguages": outputLanguages,
                    "sampleUrls": Dictionary(uniqueKeysWithValues: outputLanguages.map { ($0, "https://example.invalid/\(id).mp3") }),
                ])
            }
        }
        let now = ISO8601DateFormatter().date(from: "2026-09-15T12:00:00Z")!
        for region in ["cn", "international"] {
            let modules: [[String: Any]] = stride(from: 0, to: cloneIDs.count, by: 24).map { start in
                ["id": "\(region)-pool-\(start)", "layout": "rows", "theme": "stories",
                 "title": ["en": "Curated"], "voiceIds": Array(cloneIDs[start..<min(start + 24, cloneIDs.count)])]
            }
            let json: [String: Any] = [
                "contract": "tts-voice-catalog-v2", "version": "multilingual-pools", "editorialRegion": region,
                "languages": regularLanguages.map { ["code": $0, "locale": $0, "name": $0, "status": "ga",
                    "defaultVoice": standardVoiceID($0), "timestampMode": "word"] }, "voices": voices,
                "discovery": ["id": region, "startsAt": "2026-09-15T00:00:00Z", "endsAt": "2026-09-22T00:00:00Z", "modules": modules],
            ]
            let document = try TTSVoiceCatalogDocument.decodeServerResponse(from: JSONSerialization.data(withJSONObject: json))
            let snapshot = VoiceCatalogSnapshot(document: document), worker = VoiceBrowseWorker()
            for language in languages + ["it", "hi", "ja", "en"] {
                // Interface locale is deliberately different from voice language.
                let request = VoiceBrowseRequest(catalogID: snapshot.id, language: language, locale: "zh")
                let feed = try await worker.feed(request, snapshot: snapshot, now: now)
                let expected = cloneIDs.filter { $0.hasPrefix("vl_\(language)_") }
                XCTAssertEqual(feed.featuredClones.map(\.id), expected, "\(region) / \(language)")
                XCTAssertTrue(feed.featuredClones.allSatisfy { $0.supports("en") && $0.supports("it") && $0.usesMonthlyGeneration })
                XCTAssertTrue(feed.recommendations.allSatisfy { !$0.usesMonthlyGeneration })
                XCTAssertTrue(feed.sections.flatMap(\.voices).allSatisfy { !$0.usesMonthlyGeneration })
            }
        }
    }

    @MainActor
    func testBrowseAllTabsSearchEveryVoiceRegardlessOfDiscoveryLanguage() async throws {
        let snapshot = try fullSnapshot(), worker = VoiceBrowseWorker()
        var request = VoiceBrowseRequest(catalogID: snapshot.id, language: "zh", locale: "en",
                                        usage: .regular, allLanguages: true)
        let regular = try await worker.results(request, snapshot: snapshot, vocabulary: .current)
        XCTAssertEqual(regular.count, 302)
        XCTAssertTrue(regular.allSatisfy { !$0.usesMonthlyGeneration })
        request.usage = .monthly
        let clones = try await worker.results(request, snapshot: snapshot, vocabulary: .current)
        XCTAssertEqual(clones.count, 1323)
        request.search = "performance_1322"
        let found = try await worker.results(request, snapshot: snapshot, vocabulary: .current)
        XCTAssertEqual(found.map(\.id), ["vl_performance_1322"])
        request = VoiceBrowseRequest(catalogID: snapshot.id, language: "hi", locale: "en",
                                     search: "performance_1322", usage: .monthly, allLanguages: true)
        let unsupported = try await worker.results(request, snapshot: snapshot, vocabulary: .current)
        XCTAssertEqual(unsupported.map(\.id), ["vl_performance_1322"], "Browsing must not hide unsupported-output entries")
    }

    func testSourceMetadataSeparatesChineseEnglishAndFallbackEncodedKorean() throws {
        let english = voice("vl_en", monthly: true)
        let chinese = voice("vl_zh", language: "zh", monthly: true)
        let korean = VoiceOption(code: "vl_ko", name: "Korean narrator", isPro: true, lang: "en", gender: "male",
            sampleURL: "https://example.invalid/ko.mp3", usagePolicy: "monthly_generation",
            supportedLanguages: ["en", "zh", "ko"], sampleURLs: ["ko": "https://example.invalid/ko.mp3"],
            referenceLanguage: "ko")
        let module = VoiceDiscoveryModule(id: "both", layout: "rows", title: [:], theme: .character,
                                         voiceIds: [english.id, chinese.id, korean.id])
        let all = [english, chinese, korean]
        XCTAssertEqual(module.voices(from: all, language: "zh").map(\.id), [chinese.id])
        XCTAssertEqual(module.voices(from: all, language: "en").map(\.id), [english.id])
        XCTAssertEqual(module.voices(from: all, language: "ko").map(\.id), [korean.id])
        XCTAssertTrue(korean.supports("en"))
        let legacy = VoiceOption(code: "vl_legacy", name: "Legacy", isPro: true, lang: "en", gender: "female",
            usagePolicy: "monthly_generation", supportedLanguages: ["en", "zh"], previewLanguages: ["en": "zh", "zh": "zh"])
        XCTAssertEqual(legacy.discoveryLanguage, "zh")
    }
}

extension VoiceDiscoveryTests {
    @MainActor
    func testBrowseLanguageFollowsAppContextAndPreservesPlaybackPreferences() throws {
        let suite = "voice-context-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("zh", forKey: "voice_browser_language_v1") // old contextless cache
        defaults.set("vc_saved", forKey: "unrelated-playback-preference")
        let languages = ["en", "vi", "zh", "ru"]
        let store = VoiceLibraryStore(defaults: defaults)
        store.synchronizeAppLanguage(context: "vi|vi", language: "vi", availableLanguages: languages)
        XCTAssertEqual(store.browserLanguage, "vi")
        store.setBrowserLanguage("ru")
        let restored = VoiceLibraryStore(defaults: defaults)
        restored.synchronizeAppLanguage(context: "vi|vi", language: "vi", availableLanguages: languages)
        XCTAssertEqual(restored.browserLanguage, "ru")
        restored.synchronizeAppLanguage(context: "en|en", language: "en", availableLanguages: languages)
        XCTAssertEqual(restored.browserLanguage, "en")
        restored.setBrowserLanguage("zh")
        // Language changed while this view was absent, then returned to English.
        defaults.removeObject(forKey: "voice_browser_app_language_v2")
        restored.synchronizeAppLanguage(context: "en|en", language: "en", availableLanguages: languages)
        XCTAssertEqual(restored.browserLanguage, "en")
        restored.synchronizeAppLanguage(context: "system|vi", language: "vi", availableLanguages: languages)
        XCTAssertEqual(restored.browserLanguage, "vi")
        restored.synchronizeAppLanguage(context: "system|xx", language: "xx", availableLanguages: languages)
        XCTAssertEqual(restored.browserLanguage, "en")
        XCTAssertEqual(defaults.string(forKey: "unrelated-playback-preference"), "vc_saved")
    }

    func testAdaptiveClonePoolIsCompleteAndSourceScopedWithoutEditorialRequirement() {
        let languages = ["de", "en", "es", "fr", "ja", "ko", "pt", "ru", "zh"]
        func clone(_ id: String, _ source: String, status: String = "ga", preview: Bool = true,
                   enabled: Bool = true, selectable: Bool = true) -> VoiceOption {
            VoiceOption(code: id, name: id, isPro: true, lang: "en", gender: "female",
                status: status, enabled: enabled, selectable: selectable, usagePolicy: "monthly_generation",
                supportedLanguages: VoiceCloneLanguageSupport.all,
                sampleURLs: preview ? Dictionary(uniqueKeysWithValues: VoiceCloneLanguageSupport.all.map { ($0, "https://example.invalid/preview.mp3") }) : [:],
                referenceLanguage: source)
        }
        let pool = languages.flatMap { language in (0..<8).map { clone("vl_\(language)_\($0)", language) } }
        for language in languages {
            let editorial = "vl_\(language)_6"
            let input = pool + [pool[0], clone("vl_lab", language, status: "lab"),
                clone("vl_old", language, status: "legacy"), clone("vl_silent", language, preview: false),
                clone("vl_off", language, enabled: false), clone("vl_unselectable", language, selectable: false)]
            let result = VoiceBrowsePresentation.featuredClones(input, language: language, editorialIDs: [editorial, editorial, "missing"])
            XCTAssertEqual(result.count, 8, "See all must retain the complete pool beyond the homepage limit")
            XCTAssertEqual(result.first?.id, editorial)
            XCTAssertTrue(result.allSatisfy { $0.discoveryLanguage == language })
            XCTAssertEqual(VoiceBrowsePresentation.featuredClones(pool, language: language, editorialIDs: []).count, 8)
        }
        for language in ["it", "hi", "fi", "vi", "und"] {
            XCTAssertTrue(VoiceBrowsePresentation.featuredClones(pool, language: language, editorialIDs: []).isEmpty)
        }
        XCTAssertTrue(VoiceCloneLanguageSupport.all.contains("ko"))
        XCTAssertTrue(VoiceCloneLanguageSupport.all.contains("ru"))
        XCTAssertFalse(VoiceCloneLanguageSupport.all.contains("hi"))
    }

    func testPersonalPreviewFiltersFullLibraryBeforeLimitAndKeepsReaderComplete() {
        func item(_ id: String, _ date: String?, lang: String = "en", status: String = "ready",
                  access: String = "active", gifted: Bool = false) -> ClonedVoice {
            ClonedVoice(voiceId: id, createdAt: date, status: status, supportedLanguages: [lang],
                access: VoiceGiftAccess(kind: gifted ? .gifted : .owner, status: access))
        }
        let voices = [item("incompatible", "2026-10-09T00:00:00Z", lang: "zh"),
            item("current", "2026-10-08T00:00:00Z"), item("old", "2026-10-01T00:00:00Z"),
            item("new-a", "2026-10-07T00:00:00.000Z", gifted: true), item("new-b", "2026-10-07T00:00:00Z"),
            item("middle", "2026-10-05T00:00:00Z"), item("missing-date", nil),
            item("bad-date", "bad"), item("new-a", "2026-10-07T00:00:00Z"),
            item("pending", "2026-10-09T00:00:00Z", status: "pending"),
            item("revoked", "2026-10-09T00:00:00Z", access: "revoked", gifted: true)]
        let preview = VoiceFamiliarSelection.latest(from: voices, language: "en", excluding: "current")
        XCTAssertEqual(preview.map(\.id), ["new-a", "new-b", "middle"])
        let reader = VoiceFamiliarSelection.latest(from: voices, language: "en", excluding: "current", limit: nil)
        XCTAssertEqual(reader.map(\.id), ["new-a", "new-b", "middle", "old", "missing-date", "bad-date"])
        XCTAssertEqual(voices.count, 11, "Presentation cannot truncate the authoritative library")
        XCTAssertTrue(VoiceFamiliarSelection.latest(from: voices, language: "vi").isEmpty)
    }

    func testAdaptiveFeedSuppressesSingletonGroupsAndRetainsCompleteClonePool() async throws {
        let snapshot = try fullSnapshot(region: "international")
        var input = VoiceBrowseRequest(catalogID: snapshot.id, language: "en", locale: "en")
        input.adaptiveDiscovery = true
        let feed = try await VoiceBrowseWorker().feed(input, snapshot: snapshot,
            now: ISO8601DateFormatter().date(from: "2026-09-15T00:00:00Z")!)
        XCTAssertEqual(feed.regularVoices.count, 275)
        XCTAssertEqual(feed.featuredClones.count, 1323)
        XCTAssertEqual(feed.featuredClones.first?.id, "vl_performance_1322")
        XCTAssertTrue(feed.sections.isEmpty)
        XCTAssertTrue(feed.collections.isEmpty)
        XCTAssertTrue(feed.fallbackSections.allSatisfy { Set($0.voices.map(\.id)).count >= 2 })
        XCTAssertTrue(feed.topics.allSatisfy { $0.count >= 2 })
    }
}


extension VoiceDiscoveryTests {
    func testAdaptiveVoicePresentationIsGlobalProductAndGlobalRouteOnly() {
        XCTAssertTrue(VoiceBrowsePresentation.isAdaptive(region: .global, route: .globalGateway))
        XCTAssertFalse(VoiceBrowsePresentation.isAdaptive(region: .cn, route: .globalGateway))
        XCTAssertFalse(VoiceBrowsePresentation.isAdaptive(region: .global, route: .chinaGateway))
        XCTAssertFalse(VoiceBrowsePresentation.isAdaptive(region: .cn, route: .chinaGateway))
    }
}
