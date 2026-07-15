import XCTest
@testable import CastReader

final class VoiceCloneTests: XCTestCase {
    @MainActor
    func testCloneSelectionIsLanguageScopedAndPresetOnlyExitsThatLanguage() {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, voiceCloningEnabled: true)
        XCTAssertTrue(settings.setActiveClonedVoice("vc_english", for: "en-US"))
        XCTAssertTrue(settings.setActiveClonedVoice("vc_chinese", for: "zh-Hans"))
        XCTAssertEqual(settings.voice(for: "en"), "vc_english")
        XCTAssertEqual(settings.voice(for: "zh"), "vc_chinese")
        XCTAssertTrue(settings.setVoice("af_heart", for: "en"))
        XCTAssertNil(settings.activeClonedVoiceID(for: "en"))
        XCTAssertEqual(settings.activeClonedVoiceID(for: "zh"), "vc_chinese")
        XCTAssertEqual(settings.voice(for: "en"), "af_heart")
        XCTAssertEqual(settings.voice(for: "zh"), "vc_chinese")
    }

    @MainActor
    func testLegacyGlobalCloneMigratesToEnglishAndChinese() {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("vc_legacy", forKey: "active_cloned_voice_id_v1")

        let settings = AppSettings(defaults: defaults, voiceCloningEnabled: true)
        XCTAssertEqual(settings.voice(for: "en"), "vc_legacy")
        XCTAssertEqual(settings.voice(for: "zh"), "vc_legacy")
        XCTAssertEqual(settings.activeClonedVoiceId, "vc_legacy")
        XCTAssertNil(defaults.string(forKey: "active_cloned_voice_id_v1"))
    }

    @MainActor
    func testInvalidCloneIDIsRejectedAndNotPersisted() {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults, voiceCloningEnabled: true)
        XCTAssertFalse(settings.setActiveClonedVoice("af_heart", for: "en"))
        XCTAssertNil(settings.activeClonedVoiceId)
    }

    @MainActor
    func testDisabledReleasePreservesCloneDataButUsesPresetVoice() {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["en": "vc_saved"], forKey: "active_cloned_voice_by_language_v2")
        defaults.set(["en": "af_heart"], forKey: "tts_voice_by_language_v1")

        let settings = AppSettings(defaults: defaults, voiceCloningEnabled: false)

        XCTAssertEqual(settings.clonedVoicesByLanguage["en"], "vc_saved")
        XCTAssertNil(settings.activeClonedVoiceID(for: "en"))
        XCTAssertEqual(settings.voice(for: "en"), "af_heart")
        XCTAssertFalse(settings.setActiveClonedVoice("vc_other", for: "en"))
        XCTAssertEqual(settings.clonedVoicesByLanguage["en"], "vc_saved")
    }

    func testListParserSupportsEnvelopeAndCooldown() throws {
        let data = Data(#"{"code":0,"data":{"voices":[{"voice_id":"vc_one","created_at":"2026-07-12T10:00:00Z"},{"voiceId":"preset"}],"creation":{"nextCreateAt":"2026-07-13T10:00:00Z"}}}"#.utf8)
        let result = try VoiceCloneResponseParser.list(from: data)
        XCTAssertEqual(result.voices.map(\.voiceId), ["vc_one"])
        XCTAssertNotNil(result.nextCreateAt)
    }

    func testRateLimitCodeAndNestedDateAreParsed() {
        let limit = Data(#"{"code":"VOICE_CREATION_LIMIT","message":"wait","nextCreateAt":"2026-07-13T10:00:00Z"}"#.utf8)
        XCTAssertEqual(VoiceCloneResponseParser.serverCode(from: limit), "VOICE_CREATION_LIMIT")
        XCTAssertNotNil(VoiceCloneResponseParser.nextCreateAt(from: limit))
        let busy = Data(#"{"code":"CLONE_WORKER_BUSY","message":"busy"}"#.utf8)
        XCTAssertEqual(VoiceCloneResponseParser.serverCode(from: busy), "CLONE_WORKER_BUSY")
    }

    func testCreateParserSupportsEnvelope() throws {
        let data = Data(#"{"voice":{"voiceId":"vc_created","sampleUrl":"https://example.com/sample.wav","reference_language":"zh","supported_languages":["zh","en"]}}"#.utf8)
        let voice = try VoiceCloneResponseParser.createdVoice(from: data)
        XCTAssertEqual(voice.voiceId, "vc_created")
        XCTAssertEqual(voice.sampleURL, "https://example.com/sample.wav")
        XCTAssertEqual(voice.referenceLanguage, "zh")
        XCTAssertEqual(voice.supportedLanguages, ["zh", "en"])
    }

    func testTTSRequestSendsVoiceAndVoiceCode() throws {
        let data = try JSONEncoder().encode(TTSRequest(input: "hello", voice: "vc_one"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["voice"] as? String, "vc_one")
        XCTAssertEqual(object["voice_code"] as? String, "vc_one")
    }

    @MainActor
    func testChineseSelectionReachesResolvedRequestVoice() throws {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.setVoice("zm_yunxi", for: "zh-CN"))
        let selected = settings.voice(for: "zh-Hans")
        XCTAssertEqual(selected, "zm_yunxi")
        let data = try JSONEncoder().encode(TTSRequest(input: "你好", voice: selected, language: "zh-Hans"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["voice_code"] as? String, "zm_yunxi")
    }
}
