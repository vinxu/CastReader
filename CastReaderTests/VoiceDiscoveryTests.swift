import XCTest
@testable import CastReader

final class VoiceDiscoveryTests: XCTestCase {
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

    func testWeeklyEditionExpiresOfflineAndPreservesCrossLanguageIdentity() {
        let regular = voice("af_en")
        let publicVoice = voice("vl_story", tags: ["storytelling"], monthly: true)
        let modules = [VoiceDiscoveryModule(id: "story", layout: "feature", title: ["en": "Stories"], theme: .stories,
                                           voiceIds: ["missing", regular.id, publicVoice.id, publicVoice.id]),
                       VoiceDiscoveryModule(id: "repeat", layout: "rows", title: ["en": "More"], theme: .stories, voiceIds: [publicVoice.id])]
        let edition = VoiceDiscoveryEdition(id: "week", startsAt: "2026-09-14T00:00:00Z", endsAt: "2026-09-21T00:00:00Z", modules: modules)
        let now = ISO8601DateFormatter().date(from: "2026-09-15T00:00:00Z")!
        let chinese = edition.activeModules(from: [regular, publicVoice], language: "zh", now: now)
        XCTAssertEqual(chinese.count, 1)
        XCTAssertEqual(chinese[0].voiceIds, [publicVoice.id])
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
    private func fullSnapshot(region: String = "cn", suffix: String = "") throws -> VoiceCatalogSnapshot {
        let codes = SupportedTTSLanguage.allCases.map(\.rawValue)
        func entry(_ id: String, _ language: String, _ monthly: Bool) -> [String: Any] {
            var item: [String: Any] = ["id": id, "name": id + suffix, "engine": monthly ? "clone" : "kokoro",
                "modelVersion": "v1", "language": language, "locale": language, "genderPresentation": "female",
                "tier": monthly ? "pro" : "free", "status": "ga", "enabled": true, "selectable": true,
                "timestampMode": "word", "tags": ["warm", "storytelling"], "description": "A calm narrator"]
            if monthly {
                let supported = codes.filter { $0 != "hi" }
                item["usagePolicy"] = "monthly_generation"
                item["supportedLanguages"] = supported
                item["sampleUrls"] = Dictionary(uniqueKeysWithValues: supported.map { ($0, "/preview/\(id)/\($0)") })
            }
            return item
        }
        var voices = codes.map { entry("default_" + $0, $0, false) }
        voices += (0..<274).map { entry("regular_\($0)", "en", false) }
        voices += (0..<1323).map { entry("vl_performance_\($0)", "en", true) }
        let languages: [[String: Any]] = codes.map { ["code": $0, "locale": $0, "name": $0, "status": "ga", "defaultVoice": "default_" + $0, "timestampMode": "word"] }
        let object: [String: Any] = ["contract": "tts-voice-catalog-v1", "version": "performance-" + region + suffix,
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
        XCTAssertEqual(snapshot.all.count, 1606)
        XCTAssertEqual(snapshot.languages.count, 9)
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
        XCTAssertEqual(total, 1_333_000)
        XCTAssertLessThan(elapsed, 200, "Warm lookups must not rebuild 1,606 voice records")
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
        XCTAssertEqual(feed.sections.first?.id, "cn-stories")
        XCTAssertEqual(feed.sections.first?.voices.map(\.id), ["vl_performance_1322"])
        XCTAssertEqual(feed.collections.first?.count, 2)
        let expired = try await worker.feed(cnRequest, snapshot: cn, now: now.addingTimeInterval(7 * 86400))
        XCTAssertTrue(expired.sections.isEmpty)
        let next = try await worker.feed(.init(catalogID: international.id, language: "en", locale: "en"), snapshot: international, now: now)
        XCTAssertEqual(next.sections.first?.id, "international-stories")
        XCTAssertEqual(next.collections.first?.count, 3)
    }
}
