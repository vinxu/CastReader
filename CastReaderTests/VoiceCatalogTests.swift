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
        XCTAssertEqual(VoiceCatalog.voices(for: "en").count, 8)
        XCTAssertEqual(VoiceCatalog.voices(for: "zh").count, 10)
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
            tags: [], avatar: nil, sampleUrl: nil
        )
        try VoiceCatalog.install(TTSVoiceCatalogDocument(
            contract: TTSVoiceCatalogDocument.expectedContract,
            version: "visibility-contract", languages: [language], voices: [voice]
        ))

        XCTAssertEqual(VoiceCatalog.voices(for: "en").map(\.code), ["af_heart"])
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
    }

    func testRemoteLanguageDefaultAndFallbackResolution() throws {
        let defaults = isolatedDefaults()
        defaults.set("af_bella", forKey: "voice_en")
        let settings = AppSettings(defaults: defaults)

        VoiceCatalog.resetForTesting()
        XCTAssertEqual(settings.voice(for: "ja-JP"), "af_bella")

        let catalog = try TTSVoiceCatalogDocument.decodeServerResponse(
            from: fixture("tts-voice-catalog-direct")
        )
        try VoiceCatalog.install(catalog)
        defer { VoiceCatalog.resetForTesting() }
        XCTAssertEqual(settings.voice(for: "ja-JP"), "jf_alpha")
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
        XCTAssertEqual(VoiceCatalog.voices(for: "en").count, 8)
        XCTAssertEqual(VoiceCatalog.voices(for: "zh").count, 10)
        VoiceCatalogTestURLProtocol.handler = nil
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
