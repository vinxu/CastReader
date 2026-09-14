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
