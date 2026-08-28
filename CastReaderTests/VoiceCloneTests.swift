import XCTest
@testable import CastReader

final class VoiceCloneTests: XCTestCase {
    @MainActor
    func testRecordingVisualLevelExpandsSpeechAndReleasesSmoothly() {
        let silence = VoiceCloneRecorder.visualLevel(
            previous: 0,
            averagePower: -160,
            peakPower: -160
        )
        let ordinarySpeech = VoiceCloneRecorder.visualLevel(
            previous: silence,
            averagePower: -30,
            peakPower: -18
        )
        let loudSpeech = VoiceCloneRecorder.visualLevel(
            previous: ordinarySpeech,
            averagePower: -18,
            peakPower: -7
        )
        let firstReleaseFrame = VoiceCloneRecorder.visualLevel(
            previous: loudSpeech,
            averagePower: -160,
            peakPower: -160
        )

        XCTAssertLessThan(silence, 0.03)
        XCTAssertGreaterThan(ordinarySpeech, 0.2)
        XCTAssertGreaterThan(loudSpeech, ordinarySpeech)
        XCTAssertLessThan(firstReleaseFrame, loudSpeech)
        XCTAssertGreaterThan(firstReleaseFrame, silence, "release should decay instead of snapping shut")

        let returnedToBaseline = (0..<30).reduce(loudSpeech) { level, _ in
            VoiceCloneRecorder.visualLevel(
                previous: level,
                averagePower: -160,
                peakPower: -160
            )
        }
        XCTAssertLessThan(returnedToBaseline, 0.01)
    }

    @MainActor
    func testRecordingMeterEnergyExpandsSpeechInput() {
        let quiet = VoiceCloneRecorder.meterEnergy(
            averagePower: -160,
            peakPower: -160
        )
        let speech = VoiceCloneRecorder.meterEnergy(
            averagePower: -30,
            peakPower: -18
        )
        let ordinaryRoomNoise = VoiceCloneRecorder.meterEnergy(
            averagePower: -50,
            peakPower: -40
        )

        XCTAssertEqual(quiet, 0)
        XCTAssertEqual(ordinaryRoomNoise, 0)
        XCTAssertGreaterThan(speech, 0.35)
    }

    @MainActor
    func testRecordingMeterEnergyPreservesSpeechAmplitudeDifferences() {
        let soft = VoiceCloneRecorder.meterEnergy(
            averagePower: -34,
            peakPower: -24
        )
        let medium = VoiceCloneRecorder.meterEnergy(
            averagePower: -24,
            peakPower: -14
        )
        let loud = VoiceCloneRecorder.meterEnergy(
            averagePower: -14,
            peakPower: -5
        )

        XCTAssertLessThan(soft, medium)
        XCTAssertLessThan(medium, loud)
        XCTAssertGreaterThan(medium - soft, 0.15)
        XCTAssertGreaterThan(loud - medium, 0.15)
    }

    func testRecordingWaveformStartsAsAnEqualHeightBaseline() {
        let samples = VoiceCloneWaveformGeometry.visibleSamples([], count: 49)
        let heights = samples.map {
            VoiceCloneWaveformGeometry.height(energy: $0, availableHeight: 94)
        }

        XCTAssertTrue(heights.allSatisfy { $0 == 5 })
    }

    func testRecordingWaveformUsesVoiceMemosLikeBarDensity() {
        let count = VoiceCloneWaveformGeometry.barCount(for: 380)

        XCTAssertGreaterThanOrEqual(count, 90)
        XCTAssertLessThanOrEqual(count, 104)
    }

    func testRecordingWaveformAddsNewestSampleAtRightEdge() {
        let visible = VoiceCloneWaveformGeometry.visibleSamples(
            [0.18, 0.76, 0.34],
            count: 5
        )

        XCTAssertEqual(visible, [0, 0, 0.18, 0.76, 0.34])
    }

    func testRecordingWaveformAdvancesHistoryFromRightToLeft() {
        let earlier = VoiceCloneWaveformGeometry.visibleSamples(
            [0.2, 0.8],
            count: 4
        )
        let later = VoiceCloneWaveformGeometry.visibleSamples(
            [0.2, 0.8, 0.4],
            count: 4
        )

        XCTAssertEqual(earlier, [0, 0, 0.2, 0.8])
        XCTAssertEqual(later, [0, 0.2, 0.8, 0.4])
    }

    func testRecordingWaveformOnlyKeepsVisibleNewestHistory() {
        let visible = VoiceCloneWaveformGeometry.visibleSamples(
            [0.1, 0.2, 0.3, 0.4],
            count: 3
        )

        XCTAssertEqual(visible, [0.2, 0.3, 0.4])
    }

    func testRecordingWaveformHeightTracksRecordedVolume() {
        let quiet = VoiceCloneWaveformGeometry.height(
            energy: 0.12,
            availableHeight: 94
        )
        let loud = VoiceCloneWaveformGeometry.height(
            energy: 0.8,
            availableHeight: 94
        )

        XCTAssertGreaterThan(loud, quiet)
    }

    @MainActor
    func testRecordingWaveformHistoryClampsAndTrimsSamples() {
        let samples = VoiceCloneRecorder.appendingWaveformSample(
            1.4,
            to: [0.1, 0.2, 0.3],
            limit: 3
        )

        XCTAssertEqual(samples, [0.2, 0.3, 1])
    }

    func testQuotaPresentationUsesServerCounters() {
        let presentation = VoiceCloneQuotaPresentation(
            capability: VoiceCloneCapability(
                monthlyLimitSeconds: 7_200,
                monthlyUsedSeconds: 1_230,
                monthlyRemainingSeconds: 5_970
            )
        )

        XCTAssertEqual(presentation.limitSeconds, 7_200)
        XCTAssertEqual(presentation.usedSeconds, 1_230)
        XCTAssertEqual(presentation.remainingSeconds, 5_970)
        XCTAssertEqual(
            presentation.progress ?? -1,
            1_230.0 / 7_200.0,
            accuracy: 0.000_001
        )
    }

    func testQuotaPresentationDerivesUsedFromRemaining() {
        let presentation = VoiceCloneQuotaPresentation(
            capability: VoiceCloneCapability(monthlyRemainingSeconds: 6_000)
        )

        XCTAssertEqual(presentation.limitSeconds, 7_200)
        XCTAssertEqual(presentation.usedSeconds, 1_200)
        XCTAssertEqual(presentation.remainingSeconds, 6_000)
    }

    func testReferenceUploadTransportIsRegionSpecific() {
        XCTAssertFalse(VoiceCloneReferenceTransport.usesDirectCOSUpload(for: .globalGateway))
        XCTAssertTrue(VoiceCloneReferenceTransport.usesDirectCOSUpload(for: .chinaGateway))
    }

    func testCloneGenerationUsesDedicatedRouteInBothServiceRegions() {
        XCTAssertEqual(
            TTSEndpoint.voiceCloneCaptionedURL(base: ServiceRoute.globalGateway.apiGatewayBaseURL),
            "https://api.castreader.ai/api/voice-clone/captioned-speech"
        )
        XCTAssertEqual(
            TTSEndpoint.voiceCloneCaptionedURL(base: ServiceRoute.chinaGateway.apiGatewayBaseURL),
            "https://api.castreader.cn/api/voice-clone/captioned-speech"
        )
    }

    func testSTSUploadHostHonorsServerEndpointAndKeepsRegionalFallback() throws {
        let accelerated = try JSONDecoder().decode(
            STSCredentials.self,
            from: Data(
                """
                {"accessKeyId":"id","secretAccessKey":"secret","sessionToken":"token","bucket":"voice-123","region":"ap-shanghai","prefix":"user/cn/hash/id/","endpoint":"cos.accelerate.myqcloud.com"}
                """.utf8
            )
        )
        XCTAssertEqual(accelerated.uploadHost, "voice-123.cos.accelerate.myqcloud.com")

        let regional = try JSONDecoder().decode(
            STSCredentials.self,
            from: Data(
                """
                {"accessKeyId":"id","secretAccessKey":"secret","sessionToken":"token","bucket":"voice-123","region":"ap-shanghai","prefix":"user/cn/hash/id/"}
                """.utf8
            )
        )
        XCTAssertEqual(regional.uploadHost, "voice-123.cos.ap-shanghai.myqcloud.com")
    }

    func testRecordingPromptFollowsAppOrSystemLanguageWithoutBindingTheVoice() {
        XCTAssertEqual(
            VoiceCloneRecordingPrompt.languageCode(for: .system, systemLanguageCode: "zh-Hans-CN"),
            "zh"
        )
        XCTAssertEqual(VoiceCloneRecordingPrompt.languageCode(for: .japanese), "ja")
        XCTAssertEqual(VoiceCloneRecordingPrompt.languageCode(for: .brazilianPortuguese), "pt")
        XCTAssertEqual(
            VoiceCloneRecordingPrompt.languageCode(for: .system, systemLanguageCode: "hi-IN"),
            "hi"
        )
        XCTAssertFalse(VoiceCloneRecordingPrompt.text(for: "ja").isEmpty)
        XCTAssertTrue(
            VoiceCloneRecordingPrompt.text(for: "hi").unicodeScalars.contains {
                (0x0900...0x097F).contains(Int($0.value))
            },
            "Hindi UI must provide a Hindi recording script instead of falling back to English or Chinese"
        )
    }

    func testEverySelectableAppLanguageHasItsOwnRecordingPrompt() {
        let expected: [AppLanguage: String] = [
            .english: "en",
            .simplifiedChinese: "zh",
            .japanese: "ja",
            .spanish: "es",
            .french: "fr",
            .german: "de",
            .brazilianPortuguese: "pt",
            .italian: "it",
            .hindi: "hi",
        ]

        for (language, promptCode) in expected {
            XCTAssertEqual(VoiceCloneRecordingPrompt.languageCode(for: language), promptCode)
            XCTAssertFalse(VoiceCloneRecordingPrompt.text(for: promptCode).isEmpty)
        }
        XCTAssertEqual(
            Set(expected.values.map(VoiceCloneRecordingPrompt.text(for:))).count,
            expected.count,
            "each app language must have a distinct recording script"
        )
    }

    @MainActor
    func testExplainSegmentProgressUsesTheSelectedAppLanguage() {
        let manager = AppLanguageManager.shared
        let original = manager.selectedLanguage
        defer { manager.select(original) }

        manager.select(.english)
        XCTAssertEqual(
            ExplainSegmentProgressCopy.text(block: 0, total: 2, preparingNext: false),
            "Part 1 of 2"
        )
        XCTAssertEqual(
            ExplainSegmentProgressCopy.text(block: 0, total: 2, preparingNext: true),
            "Part 2 of 2…"
        )

        manager.select(.simplifiedChinese)
        XCTAssertEqual(
            ExplainSegmentProgressCopy.text(block: 0, total: 2, preparingNext: false),
            "第 1/2 段"
        )
    }

    func testOneCloneDefaultsToEverySupportedOutputLanguage() {
        let voice = ClonedVoice(voiceId: "vc_shared")
        XCTAssertEqual(VoiceCloneLanguageSupport.languages(for: voice), VoiceCloneLanguageSupport.all)
        XCTAssertTrue(VoiceCloneLanguageSupport.languages(for: voice).contains("zh"))
        XCTAssertTrue(VoiceCloneLanguageSupport.languages(for: voice).contains("en"))
    }

    func testReferenceQualityErrorsHaveActionableLocalizedMessages() {
        XCTAssertEqual(
            VoiceCloneQualityMessage.localized(for: "VOICE_REFERENCE_TOO_NOISY"),
            AppLocalized("环境噪声太大，请换到更安静的地方重新录制")
        )
        XCTAssertEqual(
            VoiceCloneQualityMessage.localized(for: "VOICE_REFERENCE_MULTIPLE_SPEAKERS"),
            AppLocalized("录音中可能有多人说话，请确保只有本人朗读")
        )
        XCTAssertNil(VoiceCloneQualityMessage.localized(for: "VOICE_WORKER_ERROR"))
    }

    @MainActor
    func testCreationRemainsAvailableWhenLegacyServerCapabilitySaysSlotConsumed() {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = VoiceCloneStore(defaults: defaults)
        store.applyCapability(
            VoiceCloneCapability(canCreate: true, freeCreationConsumed: false)
        )
        XCTAssertTrue(store.canCreateNow)

        store.applyCapability(
            VoiceCloneCapability(canCreate: false, freeCreationConsumed: true)
        )
        XCTAssertTrue(store.canCreateNow)
        XCTAssertTrue(store.voices.isEmpty)
        XCTAssertEqual(store.capability.canCreate, true)
        XCTAssertEqual(store.capability.freeCreationConsumed, false)
    }

    @MainActor
    func testLegacyPersistedFreeCreationSlotDoesNotBlockCreationAfterRelaunch() {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let storageID = String(repeating: "a", count: 64)
        let key = "voice_clone_free_creation_consumed_v1.account.\(storageID)"
        defaults.set(true, forKey: key)

        let relaunchedStore = VoiceCloneStore(defaults: defaults)
        relaunchedStore.activateAccountScope(storageID: storageID)
        XCTAssertNil(relaunchedStore.capability.freeCreationConsumed)
        XCTAssertTrue(relaunchedStore.canCreateNow)

        relaunchedStore.applyCapability(
            VoiceCloneCapability(canCreate: false, freeCreationConsumed: true)
        )
        XCTAssertTrue(relaunchedStore.canCreateNow)
        XCTAssertEqual(relaunchedStore.capability.canCreate, true)
        XCTAssertEqual(relaunchedStore.capability.freeCreationConsumed, false)
        XCTAssertTrue(defaults.bool(forKey: key))
    }

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

    func testListParserReadsSimpleFreeAndProClonePolicy() throws {
        let data = Data(
            #"{"code":0,"data":{"voices":[{"voiceId":"vc_policy","previewStatus":"ready","previewDurationMs":4200}],"creation":{"canCreate":false,"freeCreationConsumed":true,"nextCreateAt":null},"usage":{"canApply":true,"monthlyLimitSeconds":7200,"monthlyUsedSeconds":121,"monthlyRemainingSeconds":7079,"resetAt":"2026-09-01T00:00:00Z"}}}"#.utf8
        )
        let result = try VoiceCloneResponseParser.list(from: data)

        XCTAssertEqual(result.voices.first?.previewStatus, "ready")
        XCTAssertEqual(result.voices.first?.previewDurationMs, 4_200)
        XCTAssertEqual(result.capability.canCreate, false)
        XCTAssertEqual(result.capability.freeCreationConsumed, true)
        XCTAssertEqual(result.capability.canApply, true)
        XCTAssertEqual(result.capability.monthlyLimitSeconds, 7_200)
        XCTAssertEqual(result.capability.monthlyUsedSeconds, 121)
        XCTAssertEqual(result.capability.monthlyRemainingSeconds, 7_079)
        XCTAssertNotNil(result.capability.resetAt)
    }

    func testQuotaErrorAndHeadersExposeRemainingSecondsAndReset() throws {
        let data = Data(
            #"{"code":"CLONE_QUOTA_EXHAUSTED","message":"limit","cloneMonthlyLimitSeconds":7200,"cloneMonthlyRemainingSeconds":0,"cloneQuotaResetAt":"2026-09-01T00:00:00Z"}"#.utf8
        )
        XCTAssertEqual(VoiceCloneResponseParser.serverCode(from: data), "CLONE_QUOTA_EXHAUSTED")
        XCTAssertNotNil(VoiceCloneResponseParser.quotaResetAt(from: data))

        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://api.castreader.ai/api/voice-clone/speech")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: [
                    "X-Clone-Quota-Limit-Seconds": "7200",
                    "X-Clone-Quota-Used-Seconds": "7200",
                    "X-Clone-Quota-Remaining-Seconds": "0",
                    "X-Clone-Quota-Reset-At": "2026-09-01T00:00:00Z",
                ]
            )
        )
        let capability = VoiceCloneResponseParser.quotaCapability(from: response)
        XCTAssertEqual(capability.monthlyLimitSeconds, 7_200)
        XCTAssertEqual(capability.monthlyUsedSeconds, 7_200)
        XCTAssertEqual(capability.monthlyRemainingSeconds, 0)
        XCTAssertNotNil(capability.resetAt)
    }

    func testQuotaExhaustedMessageExplainsResetAndPresetVoiceEscapeHatch() throws {
        let resetAt = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-01T00:00:00Z")
        )
        let message = VoiceCloneError.quotaExhausted(resetAt).localizedDescription
        let formatter = DateFormatter()
        formatter.locale = AppLanguageManager.shared.locale
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        let expected = String(
            format: AppLocalized("本月 120 分钟的克隆音色额度已用完，将于 %@ 自动恢复。你可以切换到预设音色继续朗读或解读。"),
            formatter.string(from: resetAt)
        )

        XCTAssertEqual(message, expected)
        XCTAssertNotEqual(
            message,
            VoiceCloneError.temporaryUnavailable.localizedDescription
        )
    }

    func testPreviewEndpointIsServerOwnedAndCannotCarryArbitraryText() throws {
        let path = try XCTUnwrap(VoiceCloneEndpoint.previewPath(for: "vc_fixed"))
        XCTAssertEqual(path, "/api/voice-clone/voices/vc_fixed/preview")
        XCTAssertFalse(path.contains("text"))
        XCTAssertFalse(path.contains("language"))
        XCTAssertNil(VoiceCloneEndpoint.previewPath(for: "preset_voice"))
    }

    func testOnlyStructuredVoiceNotFoundResponseMeansTheVoiceWasDeleted() {
        let missingVoice = Data(
            #"{"code":"VOICE_NOT_FOUND","message":"Voice not found"}"#.utf8
        )
        let missingRoute = Data("<!doctype html><title>404</title>".utf8)

        XCTAssertTrue(
            VoiceCloneResponseParser.isVoiceNotFound(
                statusCode: 404,
                data: missingVoice
            )
        )
        XCTAssertFalse(
            VoiceCloneResponseParser.isVoiceNotFound(
                statusCode: 404,
                data: missingRoute
            ),
            "a gateway route mismatch must not be presented as a deleted voice"
        )
        XCTAssertFalse(
            VoiceCloneResponseParser.isVoiceNotFound(
                statusCode: 503,
                data: missingVoice
            )
        )
    }

    func testProStatusDecodesCloneQuotaContract() throws {
        let data = Data(
            #"{"pro":true,"plan":"trialing","account":null,"freeRemaining":1,"freeMax":3,"listenSeconds":0,"listenLimit":1200,"listenRemaining":1200,"resolvedUserId":"user_1","clonePolicy":"monthly_120_v1","cloneCanCreate":true,"cloneCanApply":true,"cloneFreeCreationConsumed":true,"cloneMonthlyLimitSeconds":7200,"cloneMonthlyUsedSeconds":60,"cloneMonthlyRemainingSeconds":7140,"cloneQuotaResetAt":"2026-09-01T00:00:00Z"}"#.utf8
        )
        let status = try ProStatusDTO.decodeServerResponse(from: data)
        XCTAssertTrue(status.pro)
        XCTAssertEqual(status.plan, "trialing")
        XCTAssertEqual(status.clonePolicy, "monthly_120_v1")
        XCTAssertEqual(status.cloneCanApply, true)
        XCTAssertEqual(status.cloneMonthlyLimitSeconds, 7_200)
        XCTAssertEqual(status.cloneMonthlyRemainingSeconds, 7_140)
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
        XCTAssertEqual(object["return_timestamps"] as? Bool, false)
    }

    func testClonedTTSChunkingPreservesEveryCharacterBeyondWorkerLimit() {
        let text = String(repeating: "你", count: 598) + "🙂" + "尾巴"
        let chunk = ClonedTTSRequestChunker.split(text, maxUTF16Length: 600)

        XCTAssertEqual(chunk.input.utf16.count, 600)
        XCTAssertEqual(chunk.input + chunk.remainder, text)
        XCTAssertEqual(chunk.remainder, "尾巴")
    }

    func testClonedTTSContinuationKeepsServerTailBeforeLocalTail() {
        let response = TTSResponse(
            audio: "audio",
            audioFormat: "audio/mpeg",
            timestamps: [],
            duration: 1,
            processedText: nil,
            unprocessedText: "server tail"
        )

        let merged = ClonedTTSRequestChunker.appendingLocalRemainder(
            to: response,
            submittedInput: "submitted input",
            localRemainder: "local tail"
        )

        XCTAssertEqual(merged.processedText, "submitted input")
        XCTAssertEqual(merged.unprocessedText, "server tail\nlocal tail")
        XCTAssertEqual(merged.audio, response.audio)
        XCTAssertEqual(merged.audioFormat, response.audioFormat)
    }

    func testClonedTTSRetryPolicyRetriesOnlyTransientFailures() {
        XCTAssertTrue(
            ClonedTTSRetryPolicy.isRetryable(
                VoiceCloneError.temporaryUnavailable
            )
        )
        XCTAssertTrue(
            ClonedTTSRetryPolicy.isRetryable(
                VoiceCloneError.workerBusy(nil)
            )
        )
        XCTAssertTrue(
            ClonedTTSRetryPolicy.isRetryable(URLError(.networkConnectionLost))
        )
        XCTAssertFalse(
            ClonedTTSRetryPolicy.isRetryable(
                VoiceCloneError.quotaExhausted(nil)
            )
        )
        XCTAssertFalse(
            ClonedTTSRetryPolicy.isRetryable(VoiceCloneError.proRequired)
        )
        XCTAssertEqual(ClonedTTSRetryPolicy.delaysNanoseconds.count, 3)
    }
}
