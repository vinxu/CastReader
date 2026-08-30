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

    func testRecordingLanguagePickerCoversEverySupportedAppLanguage() {
        XCTAssertEqual(
            VoiceCloneRecordingPrompt.selectableLanguages,
            ["zh", "en", "ja", "es", "fr", "de", "pt", "it", "hi"]
        )
        for language in VoiceCloneRecordingPrompt.selectableLanguages {
            XCTAssertFalse(VoiceCloneRecordingPrompt.text(for: language).isEmpty)
            XCTAssertFalse(
                VoiceCloneRecordingPrompt.displayName(
                    for: language,
                    locale: Locale(identifier: "en_US")
                ).isEmpty
            )
        }
    }

    func testFailedCreationPreservesTheOriginalRecordingForRetry() {
        XCTAssertEqual(
            VoiceCloneCreationSubmissionOutcome(succeeded: true),
            .completed
        )
        XCTAssertEqual(
            VoiceCloneCreationSubmissionOutcome(succeeded: false),
            .retryOriginalRecording
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
            AppLocalized("录音中可能有多人说话，请确保只有本人说话")
        )
        XCTAssertEqual(
            VoiceCloneQualityMessage.localized(for: "VOICE_REFERENCE_SPEECH_TOO_SHORT"),
            AppLocalized("有效讲话时间太短，请连续清晰说话至少 3 秒")
        )
        XCTAssertEqual(
            VoiceCloneQualityMessage.localized(for: "VOICE_REFERENCE_TEXT_MISMATCH"),
            AppLocalized("声音服务仍在更新。录音已保留，请稍后重试")
        )
        XCTAssertEqual(
            VoiceCloneQualityMessage.localized(for: "REFERENCE_LANGUAGE_UNSUPPORTED"),
            AppLocalized("暂不支持所选录音语言，请选择其他语言")
        )
        XCTAssertNil(VoiceCloneQualityMessage.localized(for: "VOICE_WORKER_ERROR"))
    }

    func testSemanticMismatchMigrationMessageIsLocalized() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot
                .appendingPathComponent("CastReader/Localizable.xcstrings")
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let entry = try XCTUnwrap(
            strings["声音服务仍在更新。录音已保留，请稍后重试"] as? [String: Any]
        )
        let localizations = try XCTUnwrap(
            entry["localizations"] as? [String: Any]
        )

        XCTAssertEqual(
            Set(localizations.keys),
            Set(["de", "en", "es", "fr", "hi", "it", "ja", "pt-BR", "zh-Hans"])
        )
    }

    func testVoiceIdentityUXCopyIsCompleteInEverySupportedLocale() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: repositoryRoot
                .appendingPathComponent("CastReader/Localizable.xcstrings")
        )
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(root["strings"] as? [String: Any])
        let expectedLocales = Set([
            "de", "en", "es", "fr", "hi", "it", "ja", "pt-BR", "zh-Hans",
        ])
        let identityKeys = [
            "保存",
            "修改名称",
            "免费版可创建并试听多个自己的声音",
            "创建成功后可随时修改，不影响声音使用",
            "声音仍可正常使用，名称同步暂不可用，请稍后重试",
            "声音名称",
            "声音名称不能为空",
            "声音名称不能包含换行或控制字符",
            "声音名称不能超过 %lld 个字符",
            "声音名称已在其他设备更新，请确认后重试",
            "声音名称无效，请修改后重试",
            "恢复默认名称",
            "朗读文本不能超过 600 个字符",
        ]

        for key in identityKeys {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            XCTAssertEqual(Set(localizations.keys), expectedLocales, key)
            for locale in expectedLocales {
                let localization = try XCTUnwrap(
                    localizations[locale] as? [String: Any],
                    "\(key) [\(locale)]"
                )
                let unit = try XCTUnwrap(
                    localization["stringUnit"] as? [String: Any],
                    "\(key) [\(locale)]"
                )
                let value = try XCTUnwrap(
                    unit["value"] as? String,
                    "\(key) [\(locale)]"
                )
                XCTAssertFalse(value.isEmpty, "\(key) [\(locale)]")
                if key.contains("%lld") {
                    XCTAssertTrue(value.contains("%lld"), "\(key) [\(locale)]")
                }
            }
        }
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

    func testListParserSkipsOneMalformedHistoricalVoiceWithoutHidingValidVoices() throws {
        let data = Data(
            #"{"voices":[{"voiceId":"vc_new","supportedLanguages":["en"]},{"voiceId":42,"supportedLanguages":"legacy"},{"voice_id":"vc_old","created_at":"2025-01-01T00:00:00Z"}]}"#.utf8
        )

        let result = try VoiceCloneResponseParser.list(from: data)

        XCTAssertEqual(result.voices.map(\.voiceId), ["vc_new", "vc_old"])
    }

    func testIdentityDecodingIsLossyWithoutHidingTheVoice() throws {
        let data = Data(
            ##"{"voices":[{"voiceId":"vc_old"},{"voiceId":"vc_null","identity":null},{"voiceId":"vc_bad","identity":{"schemaVersion":"v2","nameMode":"auto"}},{"voiceId":"vc_good","identity":{"schemaVersion":"v1","nameMode":"custom","autoNameIndex":4,"customName":"Bedtime","avatarToken":"v1:012345abcdef","avatar":{"styleVersion":"v1","backgroundStart":"#258BD9","backgroundEnd":"#244EC7","foreground":"#FFFFFF","glyph":"wave-bars"},"revision":3}}]}"##.utf8
        )

        let result = try VoiceCloneResponseParser.list(from: data)

        XCTAssertEqual(
            result.voices.map(\.voiceId),
            ["vc_old", "vc_null", "vc_bad", "vc_good"]
        )
        XCTAssertNil(result.voices[0].identity)
        XCTAssertNil(result.voices[1].identity)
        XCTAssertNil(result.voices[2].identity)
        XCTAssertEqual(result.voices[3].identity?.customName, "Bedtime")
        XCTAssertEqual(result.voices[3].identity?.revision, 3)
        XCTAssertEqual(result.voices[3].identity?.avatar.glyph, .waveBars)
    }

    func testCreateAndRenameIdentityParsersSupportSuccessAndRootConflict() throws {
        let identityJSON = ##"{"schemaVersion":"v1","nameMode":"auto","autoNameIndex":2,"customName":null,"avatarToken":"v1:012345abcdef","avatar":{"styleVersion":"v1","backgroundStart":"#258BD9","backgroundEnd":"#244EC7","foreground":"#FFFFFF","glyph":"wave-ripple"},"revision":2}"##
        let created = try VoiceCloneResponseParser.createdVoice(
            from: Data(#"{"code":0,"data":{"voiceId":"vc_created","identity":\#(identityJSON)}}"#.utf8)
        )
        let renamed = try VoiceCloneResponseParser.identity(
            from: Data(#"{"code":0,"data":{"voiceId":"vc_created","identity":\#(identityJSON)}}"#.utf8)
        )
        let conflict = VoiceCloneResponseParser.conflictIdentity(
            from: Data(#"{"code":"VOICE_IDENTITY_CONFLICT","message":"changed","identity":\#(identityJSON)}"#.utf8)
        )

        XCTAssertEqual(created.identity?.autoNameIndex, 2)
        XCTAssertEqual(renamed, created.identity)
        XCTAssertEqual(conflict, created.identity)
    }

    func testRenameSuccessParserRejectsWrongEnvelopeVoiceRevisionOrName() throws {
        let identity = ##"{"schemaVersion":"v1","nameMode":"custom","autoNameIndex":2,"customName":"Bedtime","avatarToken":"v1:012345abcdef","avatar":{"styleVersion":"v1","backgroundStart":"#258BD9","backgroundEnd":"#244EC7","foreground":"#FFFFFF","glyph":"wave-bars"},"revision":3}"##
        func response(code: String, voiceID: String, identityJSON: String = identity) -> Data {
            Data(
                #"{"code":\#(code),"data":{"voiceId":"\#(voiceID)","identity":\#(identityJSON)}}"#.utf8
            )
        }

        let accepted = try VoiceCloneResponseParser.renamedIdentity(
            from: response(code: "0", voiceID: "vc_expected"),
            expectedVoiceID: "vc_expected",
            requestedName: "Bedtime",
            expectedRevision: 2
        )
        XCTAssertEqual(accepted.revision, 3)

        XCTAssertThrowsError(try VoiceCloneResponseParser.renamedIdentity(
            from: response(code: "1", voiceID: "vc_expected"),
            expectedVoiceID: "vc_expected",
            requestedName: "Bedtime",
            expectedRevision: 2
        ))
        XCTAssertThrowsError(try VoiceCloneResponseParser.renamedIdentity(
            from: response(code: "0", voiceID: "vc_wrong"),
            expectedVoiceID: "vc_expected",
            requestedName: "Bedtime",
            expectedRevision: 2
        ))
        XCTAssertThrowsError(try VoiceCloneResponseParser.renamedIdentity(
            from: response(code: "0", voiceID: "vc_expected"),
            expectedVoiceID: "vc_expected",
            requestedName: "Bedtime",
            expectedRevision: 3
        ))
        XCTAssertThrowsError(try VoiceCloneResponseParser.renamedIdentity(
            from: response(code: "0", voiceID: "vc_expected"),
            expectedVoiceID: "vc_expected",
            requestedName: "Other Name",
            expectedRevision: 2
        ))

        for malformedCode in ["false", "0.5"] {
            XCTAssertThrowsError(try VoiceCloneResponseParser.renamedIdentity(
                from: response(code: malformedCode, voiceID: "vc_expected"),
                expectedVoiceID: "vc_expected",
                requestedName: "Bedtime",
                expectedRevision: 2
            ))
        }
    }

    func testIdentityRejectsNonASCIIHexPresentationValues() throws {
        let fullwidthToken = Data(
            ##"{"voices":[{"voiceId":"vc_token","identity":{"schemaVersion":"v1","nameMode":"auto","autoNameIndex":1,"customName":null,"avatarToken":"v1:０１２３４５abcdef","avatar":{"styleVersion":"v1","backgroundStart":"#258BD9","backgroundEnd":"#244EC7","foreground":"#FFFFFF","glyph":"wave-bars"},"revision":1}}]}"##.utf8
        )
        let fullwidthColor = Data(
            ##"{"voices":[{"voiceId":"vc_color","identity":{"schemaVersion":"v1","nameMode":"auto","autoNameIndex":1,"customName":null,"avatarToken":"v1:012345abcdef","avatar":{"styleVersion":"v1","backgroundStart":"#１２８BD9","backgroundEnd":"#244EC7","foreground":"#FFFFFF","glyph":"wave-bars"},"revision":1}}]}"##.utf8
        )

        XCTAssertNil(try VoiceCloneResponseParser.list(from: fullwidthToken).voices.first?.identity)
        XCTAssertNil(try VoiceCloneResponseParser.list(from: fullwidthColor).voices.first?.identity)
    }

    func testVoiceNameValidationMatchesBackendGraphemeContract() throws {
        XCTAssertEqual(try VoiceCloneNameValidator.normalized("  爸爸读书  "), "爸爸读书")
        XCTAssertEqual(try VoiceCloneNameValidator.normalized("\u{FEFF}Name\u{FEFF}"), "Name")
        XCTAssertEqual(
            try VoiceCloneNameValidator.normalized("\u{200B}Name\u{200B}"),
            "\u{200B}Name\u{200B}"
        )
        XCTAssertEqual(
            try VoiceCloneNameValidator.normalized(String(repeating: "👨‍👩‍👧‍👦", count: 40)),
            String(repeating: "👨‍👩‍👧‍👦", count: 40)
        )
        XCTAssertThrowsError(
            try VoiceCloneNameValidator.normalized(String(repeating: "🙂", count: 41))
        )
        XCTAssertThrowsError(try VoiceCloneNameValidator.normalized("line\nbreak"))
        XCTAssertThrowsError(try VoiceCloneNameValidator.normalized("   "))
        XCTAssertNil(try VoiceCloneNameValidator.normalized(nil))
    }

    func testRenameServiceSendsAuthenticatedPatchAndExplicitNullReset() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceCloneTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            VoiceCloneTestURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let recorder = VoiceCloneRequestRecorder()
        let responseData = Data(
            ##"{"code":0,"data":{"voiceId":"vc_http","identity":{"schemaVersion":"v1","nameMode":"auto","autoNameIndex":6,"customName":null,"avatarToken":"v1:012345abcdef","avatar":{"styleVersion":"v1","backgroundStart":"#258BD9","backgroundEnd":"#244EC7","foreground":"#FFFFFF","glyph":"wave-bars"},"revision":4}}}"##.utf8
        )
        VoiceCloneTestURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseData
            )
        }
        let service = VoiceCloneService(
            baseURL: URL(string: "https://voice-contract.test")!,
            session: session,
            route: .globalGateway,
            sessionProvider: VoiceCloneTestSessionProvider(token: "cms_contract")
        )

        let identity = try await service.renameVoice(
            "vc_http",
            name: nil,
            expectedRevision: 3
        )

        XCTAssertEqual(identity.nameMode, .auto)
        XCTAssertEqual(identity.revision, 4)
        let request = try XCTUnwrap(recorder.lastRequest())
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(request.url?.path, "/api/voice-clone/voices/vc_http")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cms_contract")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Auth-Provider"), "session")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertTrue(object["name"] is NSNull, "reset must send JSON null, not omit name")
        XCTAssertEqual(object["expectedRevision"] as? Int, 3)
    }

    func testRenameServiceMapsConflictInvalidAndUnavailableContracts() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceCloneTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            VoiceCloneTestURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let service = VoiceCloneService(
            baseURL: URL(string: "https://voice-contract.test")!,
            session: session,
            route: .globalGateway,
            sessionProvider: VoiceCloneTestSessionProvider(token: "cms_contract")
        )
        let conflictIdentity = makeVoiceIdentity(
            index: 2,
            name: "Another Device",
            revision: 5
        )
        let conflictData = Data(
            ##"{"code":"VOICE_IDENTITY_CONFLICT","message":"changed","identity":{"schemaVersion":"v1","nameMode":"custom","autoNameIndex":2,"customName":"Another Device","avatarToken":"v1:012345abcdef","avatar":{"styleVersion":"v1","backgroundStart":"#258BD9","backgroundEnd":"#244EC7","foreground":"#FFFFFF","glyph":"wave-bars"},"revision":5}}"##.utf8
        )
        VoiceCloneTestURLProtocol.handler = VoiceCloneTestURLProtocol.json(
            statusCode: 409,
            data: conflictData
        )
        do {
            _ = try await service.renameVoice("vc_http", name: "Mine", expectedRevision: 4)
            XCTFail("expected optimistic concurrency conflict")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .identityConflict(conflictIdentity))
        }

        VoiceCloneTestURLProtocol.handler = VoiceCloneTestURLProtocol.json(
            statusCode: 422,
            data: Data(
                #"{"code":"VOICE_IDENTITY_INVALID","message":"name must not be empty"}"#.utf8
            )
        )
        do {
            _ = try await service.renameVoice("vc_http", name: "Valid", expectedRevision: 5)
            XCTFail("expected identity validation error")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .identityInvalid(nil))
        }

        VoiceCloneTestURLProtocol.handler = VoiceCloneTestURLProtocol.json(
            statusCode: 503,
            data: Data(
                #"{"code":"VOICE_IDENTITY_UNAVAILABLE","message":"temporarily unavailable"}"#.utf8
            )
        )
        do {
            _ = try await service.renameVoice("vc_http", name: "Valid", expectedRevision: 5)
            XCTFail("expected isolated identity availability error")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .identityUnavailable)
        }
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
        XCTAssertTrue(
            ClonedTTSNotFoundPolicy.isConfirmedVoiceDeletion(
                statusCode: 404,
                data: missingVoice
            )
        )
        XCTAssertFalse(
            ClonedTTSNotFoundPolicy.isConfirmedVoiceDeletion(
                statusCode: 404,
                data: missingRoute
            ),
            "the TTS branch must preserve an active clone on a gateway 404"
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

    func testFastAPIDetailCodeAndMessageAreParsed() throws {
        let data = Data(
            #"{"detail":{"code":"VOICE_REFERENCE_TOO_NOISY","message":"sample is noisy"}}"#.utf8
        )

        XCTAssertEqual(
            VoiceCloneResponseParser.serverCode(from: data),
            "VOICE_REFERENCE_TOO_NOISY"
        )
        XCTAssertEqual(
            VoiceCloneResponseParser.serverMessage(from: data),
            "sample is noisy"
        )
    }

    func testVoiceErrorCodeFallsBackToResponseHeader() throws {
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://api.castreader.ai/api/voice-clone/voices")!,
                statusCode: 422,
                httpVersion: nil,
                headerFields: ["X-Voice-Error-Code": "VOICE_REFERENCE_MULTIPLE_SPEAKERS"]
            )
        )

        XCTAssertEqual(
            VoiceCloneResponseParser.serverCode(from: Data(#"{"detail":"invalid"}"#.utf8), response: response),
            "VOICE_REFERENCE_MULTIPLE_SPEAKERS"
        )
    }

    func testCreationUXMakesTheSampleOptional() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let viewSource = try String(
            contentsOf: repositoryRoot
                .appendingPathComponent("CastReader/Views/Settings/VoiceCloneCreatedView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(viewSource.contains("示例文本（可选）"))
        XCTAssertTrue(viewSource.contains("无需逐字一致"))
        XCTAssertTrue(viewSource.contains("referenceText: nil"))
        XCTAssertFalse(viewSource.contains("referenceText: exampleText"))
        let retryStart = try XCTUnwrap(
            viewSource.range(of: "case .retryOriginalRecording:")?.lowerBound
        )
        let retryTail = String(viewSource[retryStart...].prefix(360))
        XCTAssertTrue(retryTail.contains("phase = .ready"))
        XCTAssertFalse(retryTail.contains("replaceRecording"))

    }

    func testSpeakerOnlyCreateMetadataOmitsUnconfirmedExampleTextOnBothRoutes() throws {
        let metadata = try VoiceCloneCreateMetadata(
            referenceLanguage: "hi-IN",
            referenceText: nil
        )
        let multipart = Dictionary(
            uniqueKeysWithValues: metadata.multipartFields.map { ($0.name, $0.value) }
        )
        let china = metadata.chinaPayload(referenceObjectKey: "user/reference.wav")

        XCTAssertEqual(metadata.referenceLanguage, "hi")
        XCTAssertNil(metadata.referenceText)
        XCTAssertNil(multipart["reference_text"])
        XCTAssertNil(china["referenceText"])
        XCTAssertEqual(china["referenceLanguage"] as? String, "hi")
    }

    func testCreateMetadataSendsTextOnlyWhenTheCallerExplicitlyProvidesIt() throws {
        let blank = try VoiceCloneCreateMetadata(
            referenceLanguage: "en",
            referenceText: "  \n "
        )
        XCTAssertNil(blank.referenceText)
        XCTAssertFalse(blank.multipartFields.contains { $0.name == "reference_text" })

        let confirmed = try VoiceCloneCreateMetadata(
            referenceLanguage: "en",
            referenceText: "  I chose these words.  "
        )
        XCTAssertEqual(confirmed.referenceText, "I chose these words.")
        XCTAssertEqual(
            confirmed.multipartFields.first { $0.name == "reference_text" }?.value,
            "I chose these words."
        )
        XCTAssertEqual(
            confirmed.chinaPayload(referenceObjectKey: "key")["referenceText"] as? String,
            "I chose these words."
        )
    }

    @MainActor
    func testDelayedRefreshFromPreviousAccountCannotOverwriteNewAccount() async {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledVoiceCloneService()
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        let accountA = String(repeating: "a", count: 64)
        let accountB = String(repeating: "b", count: 64)
        store.activateAccountScope(storageID: accountA)

        let refresh = Task { await store.refresh() }
        await service.waitForListCall(count: 1)
        store.activateAccountScope(storageID: accountB)
        await service.completeNextList(
            VoiceCloneListResult(
                voices: [ClonedVoice(voiceId: "vc_account_a")],
                nextCreateAt: nil
            )
        )
        await refresh.value

        XCTAssertTrue(store.voices.isEmpty)
        XCTAssertNil(store.lastCreatedVoiceID)
        XCTAssertFalse(store.isLoading)
    }

    @MainActor
    func testEventuallyConsistentListCannotSwallowAuthoritativeCreateResponse() async throws {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let created = ClonedVoice(
            voiceId: "vc_just_created",
            createdAt: "2026-08-30T00:00:00Z",
            referenceLanguage: "en"
        )
        let service = ControlledVoiceCloneService(createdVoice: created)
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        store.activateAccountScope(storageID: String(repeating: "c", count: 64))
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clone-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: recordingURL) }

        let succeeded = await store.create(
            recordingURL: recordingURL,
            referenceLanguage: "en",
            referenceText: nil,
            consentConfirmed: true
        )
        XCTAssertTrue(succeeded)
        XCTAssertEqual(store.voices.map(\.voiceId), [created.voiceId])

        await service.waitForListCall(count: 1)
        await service.completeNextList(
            VoiceCloneListResult(voices: [], nextCreateAt: nil)
        )
        for _ in 0..<20 where store.isLoading {
            await Task.yield()
        }

        XCTAssertEqual(store.voices.map(\.voiceId), [created.voiceId])
        XCTAssertEqual(store.lastCreatedVoiceID, created.voiceId)
    }

    @MainActor
    func testDisplayNameUsesServerCustomThenAutoThenLegacyFallback() {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = String(repeating: "d", count: 64)
        defaults.set(
            ["vc_named": "Legacy Name", "vc_legacy": "Legacy Only"],
            forKey: "voice_clone_labels_v1.account.\(account)"
        )
        let store = VoiceCloneStore(
            service: ControlledVoiceCloneService(),
            defaults: defaults,
            isSignedIn: { true }
        )
        store.activateAccountScope(storageID: account)

        let custom = ClonedVoice(
            voiceId: "vc_named",
            identity: makeVoiceIdentity(index: 7, name: "Server Name", revision: 2)
        )
        let automatic = ClonedVoice(
            voiceId: "vc_auto",
            identity: makeVoiceIdentity(index: 9, revision: 1)
        )
        let legacy = ClonedVoice(voiceId: "vc_legacy")

        XCTAssertEqual(store.displayName(for: custom), "Server Name")
        XCTAssertEqual(
            store.displayName(for: automatic),
            String(format: AppLocalized("我的声音 %lld"), Int64(9))
        )
        XCTAssertEqual(store.displayName(for: legacy), "Legacy Only")
    }

    @MainActor
    func testRefreshNeverRegressesIdentityRevisionOrDropsKnownIdentity() async {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledVoiceCloneService()
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        store.activateAccountScope(storageID: String(repeating: "e", count: 64))

        let firstRefresh = Task { await store.refresh() }
        await service.waitForListCall(count: 1)
        await service.completeNextList(VoiceCloneListResult(
            voices: [ClonedVoice(
                voiceId: "vc_merge",
                identity: makeVoiceIdentity(index: 1, name: "Revision 2", revision: 2)
            )],
            nextCreateAt: nil
        ))
        await firstRefresh.value

        let staleRefresh = Task { await store.refresh() }
        await service.waitForListCall(count: 2)
        await service.completeNextList(VoiceCloneListResult(
            voices: [ClonedVoice(voiceId: "vc_merge", identity: nil)],
            nextCreateAt: nil
        ))
        await staleRefresh.value
        XCTAssertEqual(store.voice(withID: "vc_merge")?.identity?.revision, 2)

        let newerRefresh = Task { await store.refresh() }
        await service.waitForListCall(count: 3)
        await service.completeNextList(VoiceCloneListResult(
            voices: [ClonedVoice(
                voiceId: "vc_merge",
                identity: makeVoiceIdentity(index: 1, name: "Revision 3", revision: 3)
            )],
            nextCreateAt: nil
        ))
        await newerRefresh.value
        let newestVoice = try! XCTUnwrap(store.voice(withID: "vc_merge"))
        XCTAssertEqual(store.displayName(for: newestVoice), "Revision 3")
    }

    @MainActor
    func testIdentityPresentationCacheSurvivesRelaunchAndStaysAccountScoped() async {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let accountA = String(repeating: "a", count: 64)
        let accountB = String(repeating: "b", count: 64)
        let identity = makeVoiceIdentity(
            index: 4,
            name: "Cached Voice",
            revision: 2
        )

        let firstService = ControlledVoiceCloneService()
        let firstStore = VoiceCloneStore(
            service: firstService,
            defaults: defaults,
            isSignedIn: { true }
        )
        firstStore.activateAccountScope(storageID: accountA)
        let firstRefresh = Task { await firstStore.refresh() }
        await firstService.waitForListCall(count: 1)
        await firstService.completeNextList(VoiceCloneListResult(
            voices: [ClonedVoice(voiceId: "vc_cached", identity: identity)],
            nextCreateAt: nil
        ))
        await firstRefresh.value

        let secondService = ControlledVoiceCloneService()
        let relaunched = VoiceCloneStore(
            service: secondService,
            defaults: defaults,
            isSignedIn: { true }
        )
        relaunched.activateAccountScope(storageID: accountA)
        let cached = try! XCTUnwrap(
            relaunched.presentationVoice(withID: "vc_cached")
        )
        XCTAssertEqual(cached.identity, identity)
        XCTAssertEqual(relaunched.displayName(for: cached), "Cached Voice")
        XCTAssertTrue(relaunched.voices.isEmpty)

        let refresh = Task { await relaunched.refresh() }
        await secondService.waitForListCall(count: 1)
        await secondService.completeNextList(VoiceCloneListResult(
            voices: [ClonedVoice(voiceId: "vc_cached", identity: nil)],
            nextCreateAt: nil
        ))
        await refresh.value
        XCTAssertEqual(relaunched.voice(withID: "vc_cached")?.identity, identity)

        relaunched.activateAccountScope(storageID: accountB)
        XCTAssertNil(relaunched.presentationVoice(withID: "vc_cached"))
        relaunched.activateAccountScope(storageID: accountA)
        XCTAssertEqual(
            relaunched.presentationVoice(withID: "vc_cached")?.identity,
            identity
        )
    }

    @MainActor
    func testRenameSuccessAndConflictUseLatestRevisionWithoutChangingVoiceID() async {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledVoiceCloneService()
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        store.activateAccountScope(storageID: String(repeating: "f", count: 64))
        let refresh = Task { await store.refresh() }
        await service.waitForListCall(count: 1)
        await service.completeNextList(VoiceCloneListResult(
            voices: [ClonedVoice(
                voiceId: "vc_rename",
                identity: makeVoiceIdentity(index: 1, revision: 1)
            )],
            nextCreateAt: nil
        ))
        await refresh.value

        let rename = Task { await store.rename("vc_rename", to: "First Name") }
        await service.waitForRenameCall(count: 1)
        let firstRenameCalls = await service.renameCalls()
        XCTAssertEqual(firstRenameCalls.first?.expectedRevision, 1)
        await service.completeNextRename(
            returning: makeVoiceIdentity(index: 1, name: "First Name", revision: 2)
        )
        let renameSucceeded = await rename.value
        XCTAssertTrue(renameSucceeded)
        XCTAssertEqual(store.voice(withID: "vc_rename")?.voiceId, "vc_rename")
        XCTAssertEqual(store.voice(withID: "vc_rename")?.identity?.revision, 2)

        let conflict = Task { await store.rename("vc_rename", to: "My Edit") }
        await service.waitForRenameCall(count: 2)
        let conflictCalls = await service.renameCalls()
        XCTAssertEqual(conflictCalls.last?.expectedRevision, 2)
        await service.completeNextRename(
            throwing: VoiceCloneError.identityConflict(
                makeVoiceIdentity(index: 1, name: "Other Device", revision: 3)
            )
        )
        let conflictSucceeded = await conflict.value
        XCTAssertFalse(conflictSucceeded)
        XCTAssertEqual(store.voice(withID: "vc_rename")?.identity?.revision, 3)
        XCTAssertEqual(store.displayName(for: store.voice(withID: "vc_rename")!), "Other Device")

        let recovered = Task { await store.rename("vc_rename", to: "Recovered Name") }
        await service.waitForRenameCall(count: 3)
        await service.completeNextRename(
            throwing: VoiceCloneError.identityConflict(
                makeVoiceIdentity(index: 1, name: "Recovered Name", revision: 4)
            )
        )
        let recoveredSucceeded = await recovered.value
        XCTAssertTrue(recoveredSucceeded)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.voice(withID: "vc_rename")?.identity?.revision, 4)
        XCTAssertEqual(store.displayName(for: store.voice(withID: "vc_rename")!), "Recovered Name")

        let reset = Task { await store.rename("vc_rename", to: nil) }
        await service.waitForRenameCall(count: 4)
        let resetCalls = await service.renameCalls()
        XCTAssertNil(resetCalls.last?.name)
        XCTAssertEqual(resetCalls.last?.expectedRevision, 4)
        await service.completeNextRename(
            returning: makeVoiceIdentity(index: 1, revision: 5)
        )
        let resetSucceeded = await reset.value
        XCTAssertTrue(resetSucceeded)
        let resetVoice = try! XCTUnwrap(store.voice(withID: "vc_rename"))
        XCTAssertEqual(resetVoice.identity?.nameMode, .auto)
        XCTAssertEqual(store.displayName(for: resetVoice), "我的声音 1")
    }

    @MainActor
    func testRenameResponseFromPreviousAccountCannotMutateNewAccount() async {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledVoiceCloneService()
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        let accountA = String(repeating: "1", count: 64)
        let accountB = String(repeating: "2", count: 64)
        store.activateAccountScope(storageID: accountA)
        let refresh = Task { await store.refresh() }
        await service.waitForListCall(count: 1)
        await service.completeNextList(VoiceCloneListResult(
            voices: [ClonedVoice(
                voiceId: "vc_account_a",
                identity: makeVoiceIdentity(index: 1, revision: 1)
            )],
            nextCreateAt: nil
        ))
        await refresh.value

        let rename = Task { await store.rename("vc_account_a", to: "Late Name") }
        await service.waitForRenameCall(count: 1)
        store.activateAccountScope(storageID: accountB)
        await service.completeNextRename(
            returning: makeVoiceIdentity(index: 1, name: "Late Name", revision: 2)
        )

        let renameSucceeded = await rename.value
        XCTAssertFalse(renameSucceeded)
        XCTAssertTrue(store.voices.isEmpty)
        XCTAssertNil(store.renamingVoiceId)
        XCTAssertNil(store.errorMessage)
    }

    @MainActor
    func testDeleteResponseFromPreviousAccountCannotRefreshOrMutateNewAccount() async {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledVoiceCloneService()
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        let accountA = String(repeating: "3", count: 64)
        let accountB = String(repeating: "4", count: 64)
        store.activateAccountScope(storageID: accountA)
        let refreshA = Task { await store.refresh() }
        await service.waitForListCall(count: 1)
        await service.completeNextList(VoiceCloneListResult(
            voices: [ClonedVoice(
                voiceId: "vc_account_a",
                identity: makeVoiceIdentity(index: 1, name: "A Voice", revision: 1)
            )],
            nextCreateAt: nil
        ))
        await refreshA.value

        let delete = Task {
            await store.delete(try! XCTUnwrap(store.voice(withID: "vc_account_a")))
        }
        await service.waitForDeleteCall(count: 1)

        store.activateAccountScope(storageID: accountB)
        let refreshB = Task { await store.refresh() }
        await service.waitForListCall(count: 2)
        await service.completeNextList(VoiceCloneListResult(
            voices: [ClonedVoice(
                voiceId: "vc_account_b",
                identity: makeVoiceIdentity(index: 1, name: "B Voice", revision: 1)
            )],
            nextCreateAt: nil
        ))
        await refreshB.value
        await service.enqueueImmediateList(VoiceCloneListResult(
            voices: [],
            nextCreateAt: nil
        ))
        await service.completeNextDelete()
        await delete.value

        let current = try! XCTUnwrap(store.voice(withID: "vc_account_b"))
        XCTAssertEqual(store.displayName(for: current), "B Voice")
        XCTAssertNil(store.deletingVoiceId)
        XCTAssertNil(store.errorMessage)
        let listCallCount = await service.listCalls()
        XCTAssertEqual(listCallCount, 2)
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

private func makeVoiceIdentity(
    index: Int,
    name: String? = nil,
    revision: Int
) -> VoiceCloneIdentity {
    VoiceCloneIdentity(
        schemaVersion: "v1",
        nameMode: name == nil ? .auto : .custom,
        autoNameIndex: index,
        customName: name,
        avatarToken: "v1:012345abcdef",
        avatar: VoiceCloneAvatarPresentation(
            styleVersion: "v1",
            backgroundStart: "#258BD9",
            backgroundEnd: "#244EC7",
            foreground: "#FFFFFF",
            glyph: .waveBars
        ),
        revision: revision
    )
}

private actor ControlledVoiceCloneService: VoiceCloneStoreServicing {
    private typealias ListContinuation = CheckedContinuation<VoiceCloneListResult, Error>
    private typealias DeleteContinuation = CheckedContinuation<Void, Error>
    private typealias RenameContinuation = CheckedContinuation<VoiceCloneIdentity, Error>
    private typealias CallWaiter = (
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )

    private let createdVoice: ClonedVoice
    private var listCallCount = 0
    private var pendingLists: [ListContinuation] = []
    private var immediateListResults: [VoiceCloneListResult] = []
    private var callWaiters: [CallWaiter] = []
    private var deleteCallValues: [String] = []
    private var pendingDeletes: [DeleteContinuation] = []
    private var deleteWaiters: [CallWaiter] = []
    private var renameCallValues: [RenameCall] = []
    private var pendingRenames: [RenameContinuation] = []
    private var renameWaiters: [CallWaiter] = []

    struct RenameCall: Equatable, Sendable {
        let voiceID: String
        let name: String?
        let expectedRevision: Int
    }

    init(createdVoice: ClonedVoice = ClonedVoice(voiceId: "vc_created")) {
        self.createdVoice = createdVoice
    }

    func hasSession() async -> Bool { true }

    func listVoices() async throws -> VoiceCloneListResult {
        listCallCount += 1
        let ready = callWaiters.filter { listCallCount >= $0.count }
        callWaiters.removeAll { listCallCount >= $0.count }
        ready.forEach { $0.continuation.resume() }
        if !immediateListResults.isEmpty {
            return immediateListResults.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pendingLists.append(continuation)
        }
    }

    func createVoice(
        recordingURL: URL,
        referenceLanguage: String,
        referenceText: String?,
        consentConfirmed: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ClonedVoice {
        onProgress(1)
        return createdVoice
    }

    func deleteVoice(_ voiceId: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            deleteCallValues.append(voiceId)
            pendingDeletes.append(continuation)
            let ready = deleteWaiters.filter {
                deleteCallValues.count >= $0.count
            }
            deleteWaiters.removeAll {
                deleteCallValues.count >= $0.count
            }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func renameVoice(
        _ voiceId: String,
        name: String?,
        expectedRevision: Int
    ) async throws -> VoiceCloneIdentity {
        try await withCheckedThrowingContinuation { continuation in
            renameCallValues.append(RenameCall(
                voiceID: voiceId,
                name: name,
                expectedRevision: expectedRevision
            ))
            pendingRenames.append(continuation)
            let ready = renameWaiters.filter {
                renameCallValues.count >= $0.count
            }
            renameWaiters.removeAll {
                renameCallValues.count >= $0.count
            }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func waitForListCall(count: Int) async {
        guard listCallCount < count else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((count: count, continuation: continuation))
        }
    }

    func completeNextList(_ result: VoiceCloneListResult) {
        precondition(!pendingLists.isEmpty, "No pending list request")
        pendingLists.removeFirst().resume(returning: result)
    }

    func enqueueImmediateList(_ result: VoiceCloneListResult) {
        immediateListResults.append(result)
    }

    func listCalls() -> Int {
        listCallCount
    }

    func waitForDeleteCall(count: Int) async {
        guard deleteCallValues.count < count else { return }
        await withCheckedContinuation { continuation in
            deleteWaiters.append((count: count, continuation: continuation))
        }
    }

    func completeNextDelete() {
        precondition(!pendingDeletes.isEmpty, "No pending delete request")
        pendingDeletes.removeFirst().resume()
    }

    func waitForRenameCall(count: Int) async {
        guard renameCallValues.count < count else { return }
        await withCheckedContinuation { continuation in
            renameWaiters.append((count: count, continuation: continuation))
        }
    }

    func renameCalls() -> [RenameCall] {
        renameCallValues
    }

    func completeNextRename(returning identity: VoiceCloneIdentity) {
        precondition(!pendingRenames.isEmpty, "No pending rename request")
        pendingRenames.removeFirst().resume(returning: identity)
    }

    func completeNextRename(throwing error: Error) {
        precondition(!pendingRenames.isEmpty, "No pending rename request")
        pendingRenames.removeFirst().resume(throwing: error)
    }
}

private final class VoiceCloneRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func record(_ request: URLRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

private final class VoiceCloneTestURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func json(
        statusCode: Int,
        data: Data
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(Self.materializedRequest(request))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func materializedRequest(_ request: URLRequest) -> URLRequest {
        guard request.httpBody == nil, let stream = request.httpBodyStream else {
            return request
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else {
                break
            }
        }
        var copy = request
        copy.httpBodyStream = nil
        copy.httpBody = data
        return copy
    }
}

private actor VoiceCloneTestSessionProvider: MobileSessionProviding {
    private var token: String?

    init(token: String?) {
        self.token = token
    }

    func sessionToken() -> String? { token }
    func refreshSession() -> String? { token }
    func invalidateSession() { token = nil }
}
