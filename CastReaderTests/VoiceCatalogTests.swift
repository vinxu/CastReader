import XCTest
@testable import CastReader

final class VoiceCatalogTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"))
        return try Data(contentsOf: url)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suite = "VoiceCatalogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testDirectCatalogFixtureDecodesContractMetadata() throws {
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-direct")
        )

        XCTAssertEqual(catalog.contract, "tts-voice-catalog-v1")
        XCTAssertEqual(catalog.version, "fixture.direct")
        XCTAssertEqual(catalog.languages.first?.timestampMode, "word")
        XCTAssertEqual(catalog.voices.first?.modelVersion, "v1.0")
    }

    func testEnvelopeCatalogFixtureDecodes() throws {
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-envelope")
        )

        XCTAssertEqual(catalog.version, "fixture.envelope")
        XCTAssertEqual(catalog.voices.map(\.id), ["af_heart"])
    }

    func testMissingRequiredFieldRejectsCatalogAndKeepsFallback() throws {
        VoiceCatalog.resetForTesting()
        let malformed = """
        {
          "contract":"tts-voice-catalog-v1",
          "version":"bad",
          "languages":[{"code":"en","locale":"en-US","name":"English","status":"ga","defaultVoice":"af_heart","timestampMode":"word"}],
          "voices":[{"id":"af_heart","name":"Heart","engine":"kokoro","modelVersion":"v1","language":"en","locale":"en-US","genderPresentation":"female","status":"ga","enabled":true,"selectable":true,"timestampMode":"word"}]
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try TTSVoiceCatalogDocument.decodeServerResponse(from: malformed))
        XCTAssertFalse(VoiceCatalog.hasRemoteCatalog())
        XCTAssertEqual(VoiceCatalog.voices(for: "en").count, 28)
        XCTAssertEqual(VoiceCatalog.voices(for: "zh").count, 10)
        XCTAssertEqual(VoiceCatalog.availableLanguages.map(\.code), ["en", "zh", "ja", "es", "fr", "pt", "it", "hi"])
    }

    func testSelectableIsTheOnlyPickerVisibilityAuthority() throws {
        defer { VoiceCatalog.resetForTesting() }
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-direct")
        )
        try VoiceCatalog.install(catalog)

        let english = VoiceCatalog.voices(for: "en-US")
        XCTAssertEqual(english.map(\.code), ["af_heart", "af_nova", "am_adam"])
        XCTAssertTrue(english.contains { $0.code == "am_adam" })
        XCTAssertFalse(english.contains { $0.code == "af_maple" })
        XCTAssertFalse(english.contains { $0.code == "af_sol" })
        XCTAssertFalse(english.contains { $0.code == "bf_vale" })
        XCTAssertEqual(english.first(where: { $0.code == "af_nova" })?.isPro, true)
        XCTAssertEqual(english.first(where: { $0.code == "af_nova" })?.status, "beta")
        XCTAssertEqual(english.first(where: { $0.code == "af_nova" })?.timestampMode, "word")
        XCTAssertEqual(VoiceCatalog.voices(for: "zh-Hans").map(\.code), ["zf_001"])
        XCTAssertTrue(VoiceCatalog.voices(for: "ja-JP").isEmpty)
    }

    func testSelectableVoiceRemainsVisibleWhenEnabledIsFalse() throws {
        defer { VoiceCatalog.resetForTesting() }
        let language = TTSVoiceCatalogLanguage(
            code: "en", locale: "en-US", name: "English", status: "ga",
            defaultVoice: "af_heart", timestampMode: "word"
        )
        let voice = TTSVoiceCatalogVoice(
            id: "af_heart", name: "Heart", engine: "kokoro", modelVersion: "v1.0",
            language: "en", locale: "en-US", genderPresentation: "female", tier: "free",
            status: "ga", enabled: false, selectable: true, timestampMode: "word",
            tags: [], avatar: nil, sampleUrl: nil, accent: nil, sourceModelVersion: nil,
            collection: nil, recommended: nil, qualityGrade: nil, trainingDuration: nil,
            description: nil, descriptionZh: nil, bestFor: nil
        )
        try VoiceCatalog.install(TTSVoiceCatalogDocument(
            contract: TTSVoiceCatalogDocument.expectedContract,
            version: "visibility-contract", languages: [language], voices: [voice]
        ))

        XCTAssertEqual(VoiceCatalog.voices(for: "en").map(\.code), ["af_heart"])
    }

    func testStaticEnglishFallbackMatchesEnglish31SelectableContract() {
        VoiceCatalog.resetForTesting()
        let expectedIDs = [
            "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore",
            "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky", "am_adam",
            "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx",
            "am_puck", "am_santa", "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
            "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        ]

        XCTAssertEqual(VoiceCatalog.voices(for: "en").map(\.code), expectedIDs)
        XCTAssertEqual(VoiceCatalog.voices(for: "en").filter { !$0.isPro }.map(\.code), [
            "af_heart", "af_bella", "am_adam", "bf_emma",
        ])
        XCTAssertTrue(VoiceCatalog.voices(for: "en").allSatisfy {
            $0.modelVersion == "v1.0" && $0.selectable && $0.sampleURL == nil
        })
        XCTAssertFalse(Set(expectedIDs).contains("af_maple"))
        XCTAssertFalse(Set(expectedIDs).contains("af_sol"))
        XCTAssertFalse(Set(expectedIDs).contains("bf_vale"))

        let british = VoiceCatalog.voices(for: "en").filter { $0.accent == "British" }
        XCTAssertEqual(british.count, 8)
        XCTAssertTrue(british.allSatisfy { $0.locale == "en-GB" })
        XCTAssertTrue(VoiceCatalog.voices(for: "en").filter { $0.accent == "American" }
            .allSatisfy { $0.locale == "en-US" })
    }

    func testEightLanguageAuthorityAndOfflineDefaults() {
        VoiceCatalog.resetForTesting()
        XCTAssertEqual(SupportedTTSLanguage.allCases.map(\.rawValue), [
            "en", "zh", "ja", "es", "fr", "pt", "it", "hi",
        ])
        XCTAssertEqual(SupportedTTSLanguage(identifier: "pt-BR"), .brazilianPortuguese)
        XCTAssertEqual(SupportedTTSLanguage(identifier: "zh_Hans"), .chinese)
        XCTAssertNil(SupportedTTSLanguage(identifier: "ko-KR"))

        for language in SupportedTTSLanguage.allCases {
            XCTAssertEqual(
                VoiceCatalog.resolvedVoice(preferred: "", for: language.localeIdentifier),
                language.defaultVoiceID
            )
            XCTAssertFalse(VoiceCatalog.voices(for: language.rawValue).isEmpty)
        }
    }

    func testLegacyPreferenceSurvivesRemoteCatalogAndRemainsCurrentSessionVoice() throws {
        defer { VoiceCatalog.resetForTesting() }
        let defaults = isolatedDefaults()
        defaults.set("am_adam", forKey: "voice_en")
        let settings = AppSettings(defaults: defaults)
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-direct")
        )
        try VoiceCatalog.install(catalog)

        XCTAssertEqual(settings.voiceEN, "am_adam")
        XCTAssertEqual(settings.voice(for: "en-US"), "am_adam")
        XCTAssertEqual(defaults.string(forKey: "voice_en"), "am_adam")
        XCTAssertEqual(VoiceCatalog.displayName(for: "am_adam"), "Adam")
        XCTAssertTrue(VoiceCatalog.voices(for: "en").contains { $0.code == "am_adam" })
    }

    func testPhaseOneCandidatesUseProductionModelVersionAndRemainHidden() throws {
        defer { VoiceCatalog.resetForTesting() }
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-direct")
        )
        try VoiceCatalog.install(catalog)

        for code in ["af_maple", "af_sol", "bf_vale"] {
            let voice = try XCTUnwrap(catalog.voices.first { $0.id == code })
            XCTAssertEqual(voice.modelVersion, "v1.1-zh")
            XCTAssertTrue(voice.enabled)
            XCTAssertFalse(voice.selectable)
            XCTAssertFalse(VoiceCatalog.voices(for: "en").contains { $0.code == code })
        }
    }

    func testStructuredAvatarDecodes() throws {
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-envelope")
        )

        XCTAssertEqual(catalog.voices.first?.avatar?.id, "heart")
        XCTAssertEqual(catalog.voices.first?.avatar?.url64, "https://cdn.example/heart-64.png")
        try VoiceCatalog.install(catalog)
        defer { VoiceCatalog.resetForTesting() }
        XCTAssertEqual(VoiceCatalog.option(for: "af_heart")?.avatarURL64, "https://cdn.example/heart-64.png")
    }

    func testEnglishCatalogEnhancementMetadataDecodesAndMaps() throws {
        defer { VoiceCatalog.resetForTesting() }
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-english-31")
        )
        try VoiceCatalog.install(catalog)

        XCTAssertEqual(catalog.version, "2026-07-12.english-31")
        XCTAssertEqual(VoiceCatalog.voices(for: "en").map(\.code), ["af_heart", "bf_alice"])
        let voice = try XCTUnwrap(VoiceCatalog.option(for: "bf_alice"))
        XCTAssertEqual(voice.accent, "British")
        XCTAssertEqual(voice.sourceModelVersion, "Kokoro-v1.0")
        XCTAssertEqual(voice.collection, "English Essentials")
        XCTAssertTrue(voice.recommended)
        XCTAssertEqual(voice.bestFor, ["audiobooks", "long-form"])
        XCTAssertEqual(voice.sampleURL, "https://cdn.example/bf_alice.mp3")
        XCTAssertEqual(voice.descriptionZh, "清晰自然的英式女声")
    }

    func testRemoteLanguageDefaultAndFallbackResolution() throws {
        let defaults = isolatedDefaults()
        defaults.set("af_bella", forKey: "voice_en")
        let settings = AppSettings(defaults: defaults)

        VoiceCatalog.resetForTesting()
        XCTAssertEqual(settings.voice(for: "ja-JP"), "jf_alpha")
        XCTAssertEqual(VoiceCatalog.voices(for: "ja-JP").map(\.code), ["jf_alpha"])

        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-direct")
        )
        try VoiceCatalog.install(catalog)
        defer { VoiceCatalog.resetForTesting() }
        XCTAssertEqual(settings.voice(for: "ja-JP"), "jf_alpha")
    }

    func testVoiceBrowserSearchAndFiltersUseCatalogMetadata() {
        let voices = [
            VoiceOption(
                code: "af_nova", name: "Nova", isPro: true, lang: "en", gender: "female",
                locale: "en-US", tags: ["warm", "narration"]
            ),
            VoiceOption(
                code: "zm_009", name: "云泽", isPro: false, lang: "zh", gender: "male",
                locale: "zh-CN", tags: ["calm"]
            ),
            VoiceOption(
                code: "hidden", name: "Hidden", isPro: false, lang: "en", gender: "male",
                selectable: false, locale: "en-GB", tags: ["news"]
            ),
        ]

        XCTAssertEqual(VoiceBrowserFilter.apply(
            voices: voices, search: "narration", language: "", gender: "", tier: .all
        ).map(\.code), ["af_nova"])
        XCTAssertEqual(VoiceBrowserFilter.apply(
            voices: voices, search: "nova", language: "", gender: "", tier: .all
        ).map(\.code), ["af_nova"])
        XCTAssertEqual(VoiceBrowserFilter.apply(
            voices: voices, search: "zm_", language: "zh-Hans", gender: "male", tier: .free
        ).map(\.code), ["zm_009"])
        XCTAssertEqual(VoiceBrowserFilter.apply(
            voices: voices, search: "en-us", language: "en", gender: "female", tier: .pro
        ).map(\.code), ["af_nova"])
        XCTAssertFalse(VoiceBrowserFilter.apply(
            voices: voices, search: "hidden", language: "", gender: "", tier: .all
        ).contains { $0.code == "hidden" })
    }

    func testEnglishAccentRecommendedAndDescriptionFilters() {
        let voices = [
            VoiceOption(
                code: "af_heart", name: "Heart", isPro: false, lang: "en", gender: "female",
                locale: "en-US", accent: "American", recommended: true,
                description: "Warm conversational narrator", bestFor: ["audiobooks"]
            ),
            VoiceOption(
                code: "bf_alice", name: "Alice", isPro: true, lang: "en", gender: "female",
                locale: "en-GB", accent: "British", recommended: false,
                description: "Clear documentary voice", bestFor: ["documentaries"]
            ),
        ]

        XCTAssertEqual(VoiceBrowserFilter.apply(
            voices: voices, search: "audiobooks", language: "en", gender: "female",
            tier: .free, accent: "us", recommendedOnly: true
        ).map(\.code), ["af_heart"])
        XCTAssertEqual(VoiceBrowserFilter.apply(
            voices: voices, search: "documentary", language: "en", gender: "female",
            tier: .pro, accent: "uk"
        ).map(\.code), ["bf_alice"])
    }

    func testSampleURLAcceptsHTTPAndRejectsUnsupportedSchemes() {
        XCTAssertEqual(
            VoiceSamplePlayer.validSampleURL("https://cdn.example/sample.mp3")?.absoluteString,
            "https://cdn.example/sample.mp3"
        )
        XCTAssertNotNil(VoiceSamplePlayer.validSampleURL("http://localhost/sample.mp3"))
        XCTAssertNil(VoiceSamplePlayer.validSampleURL("file:///tmp/sample.mp3"))
        XCTAssertNil(VoiceSamplePlayer.validSampleURL("not a url"))
        XCTAssertNil(VoiceSamplePlayer.validSampleURL(nil))
        XCTAssertNil(VoiceOption(
            code: "empty", name: "Empty", isPro: false, lang: "en", gender: "female",
            sampleURL: "  "
        ).sampleURL)
    }

    @MainActor
    func testFavoritesAndRecentPersistWithDedupAndLimit() {
        let defaults = isolatedDefaults()
        let store = VoiceLibraryStore(defaults: defaults)

        store.toggleFavorite("af_heart")
        store.toggleFavorite("zf_001")
        for index in 0..<15 { store.recordRecent("voice_\(index)") }
        store.recordRecent("voice_7")

        XCTAssertEqual(store.favoriteIDs, Set(["af_heart", "zf_001"]))
        XCTAssertEqual(store.recentIDs.count, VoiceLibraryStore.recentLimit)
        XCTAssertEqual(store.recentIDs.first, "voice_7")
        XCTAssertEqual(store.recentIDs.filter { $0 == "voice_7" }.count, 1)

        let reloaded = VoiceLibraryStore(defaults: defaults)
        XCTAssertEqual(reloaded.favoriteIDs, store.favoriteIDs)
        XCTAssertEqual(reloaded.recentIDs, store.recentIDs)
        reloaded.toggleFavorite("af_heart")
        XCTAssertFalse(reloaded.isFavorite("af_heart"))
    }

    @MainActor
    func testVoiceBrowserLanguageDefaultsAndPersistsExplicitChoice() {
        XCTAssertEqual(
            VoiceBrowserLanguage.defaultLanguage(preferredLanguages: ["zh-Hans-CN", "en-US"]),
            "zh"
        )
        XCTAssertEqual(
            VoiceBrowserLanguage.defaultLanguage(preferredLanguages: ["fr-FR"]),
            "fr"
        )
        XCTAssertEqual(
            VoiceBrowserLanguage.defaultLanguage(preferredLanguages: ["de-DE"]),
            "en"
        )
        XCTAssertEqual(
            VoiceBrowserLanguage.defaultLanguage(
                preferredLanguages: ["ja-JP"],
                availableLanguages: ["en", "ja", "es"]
            ),
            "ja"
        )

        let defaults = isolatedDefaults()
        defaults.set("en", forKey: "voice_browser_language_v1")
        let store = VoiceLibraryStore(defaults: defaults)
        XCTAssertEqual(store.browserLanguage, "en")
        store.setBrowserLanguage("hi-IN")
        XCTAssertEqual(store.browserLanguage, "hi")
        XCTAssertEqual(VoiceLibraryStore(defaults: defaults).browserLanguage, "hi")
    }

    @MainActor
    func testInferredDefaultRemainsSingleLanguageAndExplicitChoiceWins() {
        let defaults = isolatedDefaults()
        let store = VoiceLibraryStore(defaults: defaults)

        XCTAssertFalse(store.hasExplicitBrowserLanguageSelection)
        store.applyDefaultBrowserLanguage("es-ES")
        XCTAssertEqual(store.browserLanguage, "es")
        XCTAssertNil(defaults.string(forKey: "voice_browser_language_v1"))

        store.setBrowserLanguage("en-US")
        store.applyDefaultBrowserLanguage("zh-CN")
        XCTAssertTrue(store.hasExplicitBrowserLanguageSelection)
        XCTAssertEqual(store.browserLanguage, "en")
        XCTAssertEqual(defaults.string(forKey: "voice_browser_language_v1"), "en")
    }

    func testAvailableLanguagesAreCatalogDrivenAndCountSelectableVoices() throws {
        defer { VoiceCatalog.resetForTesting() }
        let data = """
        {
          "contract":"tts-voice-catalog-v1",
          "version":"dynamic-languages",
          "languages":[
            {"code":"en","locale":"en-US","name":"English","status":"ga","defaultVoice":"af_heart","timestampMode":"word"},
            {"code":"ja","locale":"ja-JP","name":"Japanese","status":"beta","defaultVoice":"jf_alpha","timestampMode":"segment"}
          ],
          "voices":[
            {"id":"af_heart","name":"Heart","engine":"kokoro","modelVersion":"v1","language":"en","locale":"en-US","genderPresentation":"female","tier":"free","status":"ga","enabled":true,"selectable":true,"timestampMode":"word"},
            {"id":"am_adam","name":"Adam","engine":"kokoro","modelVersion":"v1","language":"en","locale":"en-US","genderPresentation":"male","tier":"free","status":"ga","enabled":true,"selectable":true,"timestampMode":"word"},
            {"id":"jf_alpha","name":"Alpha","engine":"kokoro","modelVersion":"v1","language":"ja","locale":"ja-JP","genderPresentation":"female","tier":"free","status":"beta","enabled":true,"selectable":true,"timestampMode":"segment"}
          ]
        }
        """.data(using: .utf8)!
        try VoiceCatalog.install(TTSVoiceCatalogDocument.decodeServerResponse(from: data))

        XCTAssertEqual(VoiceCatalog.availableLanguages.map(\.code), ["en", "ja"])
        XCTAssertEqual(VoiceCatalog.languageOption(for: "en-GB")?.voiceCount, 2)
        XCTAssertEqual(VoiceCatalog.languageOption(for: "ja-JP")?.voiceCount, 1)
        let japanese = try XCTUnwrap(VoiceCatalog.languageOption(for: "ja"))
        XCTAssertTrue(VoiceBrowserLanguage.matchesSearch(
            japanese,
            query: "ja-JP",
            locale: Locale(identifier: "en_US")
        ))
    }

    func testLegacyVoicePreferencesMigrateAndStayLanguageScoped() throws {
        defer { VoiceCatalog.resetForTesting() }
        let defaults = isolatedDefaults()
        defaults.set("am_adam", forKey: "voice_en")
        defaults.set("zm_009", forKey: "voice_zh")
        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-direct")
        )
        try VoiceCatalog.install(catalog)

        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.voiceEN, "am_adam")
        XCTAssertEqual(settings.voiceZH, "zm_009")
        XCTAssertEqual(settings.voice(for: "ja-JP"), "jf_alpha")
        XCTAssertTrue(settings.setVoice("jf_alpha", for: "ja-JP"))
        XCTAssertFalse(settings.setVoice("af_heart", for: "zh-Hans"))

        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.selectedVoiceID(for: "ja"), "jf_alpha")
        XCTAssertEqual(reloaded.voice(for: "en-GB"), "am_adam")
        XCTAssertEqual(reloaded.voice(for: "zh-CN"), "zm_009")
    }

    @MainActor
    func testProSelectionGateDoesNotSaveBeforeEntitlement() {
        VoiceCatalog.resetForTesting()
        let settings = AppSettings(defaults: isolatedDefaults())
        let proVoice = VoiceOption(
            code: "af_nova", name: "Nova", isPro: true, lang: "en", gender: "female"
        )
        let freeVoice = VoiceOption(
            code: "af_bella", name: "Bella", isPro: false, lang: "en", gender: "female"
        )

        XCTAssertFalse(VoiceSelectionPolicy.select(proVoice, isPro: false, settings: settings))
        XCTAssertEqual(settings.voiceEN, "af_heart")
        XCTAssertTrue(VoiceSelectionPolicy.select(freeVoice, isPro: false, settings: settings))
        XCTAssertEqual(settings.voiceEN, "af_bella")
        XCTAssertTrue(VoiceSelectionPolicy.select(proVoice, isPro: true, settings: settings))
        XCTAssertEqual(settings.voiceEN, "af_nova")
    }

    @MainActor
    func testNetworkCatalogCachesAndReloadsWithoutChangingPreferences() async throws {
        let defaults = isolatedDefaults()
        defaults.set("af_bella", forKey: "voice_en")
        let session = URLSession(configuration: .voiceCatalogTest)
        VoiceCatalogTestURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-catalog-contract"), "tts-voice-catalog-v1")
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, try self.fixture("tts-voice-catalog-direct"))
        }

        let service = VoiceCatalogService(
            session: session,
            defaults: defaults,
            endpoint: URL(string: "https://example.com/api/tts/catalog")!
        )
        await service.refresh()

        XCTAssertEqual(service.source, .network)
        XCTAssertTrue(VoiceCatalog.hasRemoteCatalog())
        XCTAssertEqual(defaults.string(forKey: "voice_en"), "af_bella")

        VoiceCatalog.resetForTesting()
        let cached = VoiceCatalogService(
            session: session,
            defaults: defaults,
            endpoint: URL(string: "https://example.com/api/tts/catalog")!
        )
        XCTAssertTrue(cached.loadCachedCatalog())
        XCTAssertEqual(cached.source, .cache)
        XCTAssertEqual(VoiceCatalog.voices(for: "zh").map(\.code), ["zf_001"])
        VoiceCatalog.resetForTesting()
        VoiceCatalogTestURLProtocol.handler = nil
    }

    @MainActor
    func testNetworkFailureWithoutCacheRetainsStaticFallback() async {
        VoiceCatalog.resetForTesting()
        let defaults = isolatedDefaults()
        let session = URLSession(configuration: .voiceCatalogTest)
        VoiceCatalogTestURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let service = VoiceCatalogService(
            session: session,
            defaults: defaults,
            endpoint: URL(string: "https://example.com/api/tts/catalog")!
        )

        await service.refresh()

        XCTAssertEqual(service.source, .fallback)
        XCTAssertEqual(VoiceCatalog.voices(for: "en").count, 28)
        XCTAssertEqual(VoiceCatalog.voices(for: "zh").count, 10)
        VoiceCatalogTestURLProtocol.handler = nil
    }

    @MainActor
    func testNewestVoiceSwitchTransactionCannotBeClearedByStaleCompletion() async {
        let center = VoiceSwitchStatusCenter.shared
        let first = center.begin(language: "ja", from: "jf_alpha", to: "jf_beta")
        let second = center.begin(language: "ja", from: "jf_beta", to: "jf_gamma")

        center.finish(first)
        XCTAssertEqual(center.progress?.id, second)
        XCTAssertEqual(center.progress?.fromVoiceID, "jf_beta")
        XCTAssertEqual(center.progress?.toVoiceID, "jf_gamma")
        XCTAssertTrue(center.progress?.localizedMessage.contains("→") == true)

        center.finish(second)
        try? await Task.sleep(nanoseconds: 750_000_000)
        XCTAssertNil(center.progress)
    }
}

private final class VoiceCatalogTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLSessionConfiguration {
    static var voiceCatalogTest: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceCatalogTestURLProtocol.self]
        return configuration
    }
}
