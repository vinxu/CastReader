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

    func testVoiceGiftLocaleMappingUsesExactlyNineCanonicalLocales() {
        let explicit: [AppLanguage: String] = [
            .english: "en",
            .simplifiedChinese: "zh-Hans",
            .japanese: "ja",
            .spanish: "es",
            .french: "fr",
            .german: "de",
            .brazilianPortuguese: "pt-BR",
            .italian: "it",
            .hindi: "hi",
        ]

        XCTAssertEqual(AppLanguage.voiceGiftLocales, [
            "en", "zh-Hans", "ja", "es", "fr", "de", "pt-BR", "it", "hi",
        ])
        for (language, locale) in explicit {
            XCTAssertEqual(language.voiceGiftLocale, locale)
        }
    }

    func testSystemVoiceGiftLocaleNormalizesRegionalAndUnsupportedIdentifiers() {
        let expected = [
            "en-GB": "en",
            "zh_Hant_HK": "zh-Hans",
            "ja-JP": "ja",
            "es-MX": "es",
            "fr-CA": "fr",
            "de-AT": "de",
            "pt-PT": "pt-BR",
            "it-CH": "it",
            "hi-IN": "hi",
            " pt_BR ": "pt-BR",
            "ar-SA": "en",
        ]
        for (identifier, locale) in expected {
            XCTAssertEqual(
                AppLanguage.system.voiceGiftLocale(systemLanguageIdentifier: identifier),
                locale,
                identifier
            )
        }
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

    func testVoiceGiftCopyIsCompleteInEverySupportedLocale() throws {
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
        let giftKeys = [
            "邀请朋友录制声音暂未在当前地区开放",
            "朗读者已收回这个声音的使用授权，已为你取消选择",
            "这个声音的使用授权已过期，已为你取消选择",
            "这个朗读者声音暂时无法使用，请刷新声音列表后重试",
            "移除访问",
            "移除这个朗读者声音？",
            "只会从你的朗读者列表移除，不会删除对方创建的声音。",
            "我的朗读者",
            "朋友完成授权后，他的声音会自动出现在这里。",
            "待回应邀请",
            "邀请朋友录制声音",
            "朋友授权后，你可用他的声音朗读和解读 Kindle、文件与网页，直到他撤回。",
            "点击后直接分享链接，无需填写邮箱。",
            "等待朋友录制",
            "朋友正在录制",
            "再次分享邀请链接",
            "修改私有备注",
            "来自 %@",
            "朋友授权的声音",
            "朗读者声音 %lld",
            "授权已过期",
            "授权已收回",
            "可用于朗读和解读",
            "让重要的声音，陪你读懂每一页。",
            "CastReader 把 Kindle 书籍、照片、PDF 和网页变成同步指读与 AI 解读。",
            "录一小段声音，成为我的朗读者；授权有效且你未收回期间，我可以用于朗读和解读。",
            "私有备注",
            "只有你能看到这个备注，不会修改朗读者创建的声音名称。",
            "例如：妈妈讲故事",
            "最多可同时保留 %1$lld 个未完成邀请。最早一条将于 %2$@ 自动过期，之后即可再次邀请。",
            "最多可同时保留 %lld 个未完成邀请。未完成邀请会在创建 48 小时后自动过期，之后即可再次邀请。",
            "24 小时内最多发送 %1$lld 个邀请。请于 %2$@ 后再试；未完成邀请会在创建 48 小时后自动过期。",
            "24 小时内最多发送 %lld 个邀请。请稍后再试；未完成邀请会在创建 48 小时后自动过期。",
            "邀请数量已达当前上限。请于 %@ 后再试；未完成邀请会在创建 48 小时后自动过期。",
            "邀请数量已达当前上限。未完成邀请会在创建 48 小时后自动过期，请稍后再试。",
        ]

        for key in giftKeys {
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
                if key.contains("%@") {
                    XCTAssertTrue(value.contains("%@"), "\(key) [\(locale)]")
                }
                if key.contains("%lld") {
                    XCTAssertTrue(value.contains("%lld"), "\(key) [\(locale)]")
                }
                if key.contains("%1$lld") {
                    XCTAssertTrue(value.contains("%1$lld"), "\(key) [\(locale)]")
                    XCTAssertTrue(value.contains("%2$@"), "\(key) [\(locale)]")
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

        VoiceCloneTestURLProtocol.handler = VoiceCloneTestURLProtocol.json(
            statusCode: 409,
            data: Data(
                #"{"code":"VOICE_CREATION_IDEMPOTENCY_IN_PROGRESS"}"#.utf8
            )
        )
        do {
            _ = try await service.renameVoice("vc_http", name: "Valid", expectedRevision: 5)
            XCTFail("expected idempotent create in-progress response")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .creationIdempotencyInProgress)
        }

        VoiceCloneTestURLProtocol.handler = VoiceCloneTestURLProtocol.json(
            statusCode: 409,
            data: Data(
                #"{"code":"VOICE_CREATION_IDEMPOTENCY_RETIRED"}"#.utf8
            )
        )
        do {
            _ = try await service.renameVoice("vc_http", name: "Valid", expectedRevision: 5)
            XCTFail("expected retired idempotency response")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .creationIdempotencyConflict)
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
        let china = metadata.chinaPayload(
            referenceObjectKey: "user/reference.wav",
            referenceSha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )

        XCTAssertEqual(metadata.referenceLanguage, "hi")
        XCTAssertNil(metadata.referenceText)
        XCTAssertNil(multipart["reference_text"])
        XCTAssertNil(china["referenceText"])
        XCTAssertEqual(china["referenceLanguage"] as? String, "hi")
        XCTAssertEqual(
            china["referenceSha256"] as? String,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            multipart["consent_version"],
            "voice-owner-consent-2026-07-12-v1"
        )
        XCTAssertEqual(multipart["consent_source"], "ios")
        XCTAssertEqual(china["consentConfirmed"] as? Bool, true)
        XCTAssertEqual(
            china["consentVersion"] as? String,
            "voice-owner-consent-2026-07-12-v1"
        )
        XCTAssertEqual(china["consentSource"] as? String, "ios")
        let structuredConsent = try XCTUnwrap(china["consent"] as? [String: Any])
        XCTAssertEqual(structuredConsent["confirmed"] as? Bool, true)
        XCTAssertEqual(
            structuredConsent["version"] as? String,
            "voice-owner-consent-2026-07-12-v1"
        )
        XCTAssertEqual(structuredConsent["source"] as? String, "ios")
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
            confirmed.chinaPayload(
                referenceObjectKey: "key",
                referenceSha256: String(repeating: "a", count: 64)
            )["referenceText"] as? String,
            "I chose these words."
        )
    }

    func testCreateIdempotencyHeaderAndInputFingerprintContract() throws {
        let key = VoiceCloneCreateIdempotency.makeKey(
            uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        XCTAssertEqual(key, "ios:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        XCTAssertTrue(VoiceCloneCreateIdempotency.isValidKey(key))
        XCTAssertFalse(VoiceCloneCreateIdempotency.isValidKey("android:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))

        var request = URLRequest(url: URL(string: "https://api.castreader.ai/api/voice-clone/voices")!)
        try VoiceCloneCreateIdempotency.apply(key, to: &request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), key)
        XCTAssertThrowsError(
            try VoiceCloneCreateIdempotency.apply("ios:not-a-uuid", to: &request)
        )

        let baseline = VoiceCloneCreateIdempotency.fingerprint(
            recordingData: Data([0, 1, 2, 3]),
            referenceLanguage: "en-US",
            referenceText: "  Optional words  "
        )
        XCTAssertEqual(
            baseline,
            VoiceCloneCreateIdempotency.fingerprint(
                recordingData: Data([0, 1, 2, 3]),
                referenceLanguage: "en",
                referenceText: "Optional words"
            )
        )
        XCTAssertNotEqual(
            baseline,
            VoiceCloneCreateIdempotency.fingerprint(
                recordingData: Data([0, 1, 2, 4]),
                referenceLanguage: "en",
                referenceText: "Optional words"
            )
        )
        XCTAssertNotEqual(
            baseline,
            VoiceCloneCreateIdempotency.fingerprint(
                recordingData: Data([0, 1, 2, 3]),
                referenceLanguage: "zh",
                referenceText: "Optional words"
            )
        )
        XCTAssertEqual(
            VoiceCloneReferenceIntegrity.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testGlobalAndChinaCreateRequestsSendTheSameIdempotencyHeader() async throws {
        let key = VoiceCloneCreateIdempotency.makeKey(
            uuid: UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
        )
        let service = VoiceCloneService(
            baseURL: URL(string: "https://voice-contract.test")!,
            session: .shared,
            route: .globalGateway,
            sessionProvider: VoiceCloneTestSessionProvider(token: "cms_contract")
        )

        let global = try await service.createUploadRequest(
            boundary: "boundary",
            token: "cms_contract",
            idempotencyKey: key
        )
        let chinaBody = try JSONSerialization.data(withJSONObject: [
            "referenceObjectKey": "users/example/reference.wav",
            "referenceSha256": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        ])
        let china = try await service.createChinaObjectRequest(
            token: "cms_contract",
            body: chinaBody,
            idempotencyKey: key
        )

        XCTAssertEqual(global.value(forHTTPHeaderField: "Idempotency-Key"), key)
        XCTAssertEqual(china.value(forHTTPHeaderField: "Idempotency-Key"), key)
        let decodedChina = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(china.httpBody)) as? [String: Any]
        )
        XCTAssertEqual(
            decodedChina["referenceSha256"] as? String,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
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
    func testCreateRetryReusesKeyButInputAccountAndSuccessRotateIt() async throws {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SequencedCreateVoiceCloneService(outcomes: [
            .failure(.creationIdempotencyInProgress),
            .failure(.creationIdempotencyInProgress),
            .failure(.creationIdempotencyConflict),
            .success("vc_account_a_after_conflict"),
            .failure(.creationIdempotencyInProgress),
            .success("vc_account_b_first"),
            .success("vc_account_b_second"),
        ])
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clone-idempotency-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0, 1, 2, 3]).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: recordingURL) }

        store.activateAccountScope(storageID: String(repeating: "a", count: 64))
        let firstAmbiguous = await store.create(
            recordingURL: recordingURL,
            referenceLanguage: "en",
            referenceText: nil,
            consentConfirmed: true
        )
        let repeatedAmbiguous = await store.create(
            recordingURL: recordingURL,
            referenceLanguage: "en-US",
            referenceText: nil,
            consentConfirmed: true
        )
        let changedInputConflict = await store.create(
            recordingURL: recordingURL,
            referenceLanguage: "zh",
            referenceText: nil,
            consentConfirmed: true
        )
        let retriedAfterConflict = await store.create(
            recordingURL: recordingURL,
            referenceLanguage: "zh",
            referenceText: nil,
            consentConfirmed: true
        )
        XCTAssertFalse(firstAmbiguous)
        XCTAssertFalse(repeatedAmbiguous)
        XCTAssertFalse(changedInputConflict)
        XCTAssertTrue(retriedAfterConflict)

        store.activateAccountScope(storageID: String(repeating: "b", count: 64))
        let accountBAmbiguous = await store.create(
            recordingURL: recordingURL,
            referenceLanguage: "en",
            referenceText: nil,
            consentConfirmed: true
        )
        let accountBRetry = await store.create(
            recordingURL: recordingURL,
            referenceLanguage: "en",
            referenceText: nil,
            consentConfirmed: true
        )
        let accountBAfterSuccess = await store.create(
            recordingURL: recordingURL,
            referenceLanguage: "en",
            referenceText: nil,
            consentConfirmed: true
        )
        XCTAssertFalse(accountBAmbiguous)
        XCTAssertTrue(accountBRetry)
        XCTAssertTrue(accountBAfterSuccess)

        let calls = await service.createCalls()
        XCTAssertEqual(calls.count, 7)
        XCTAssertEqual(calls[0].idempotencyKey, calls[1].idempotencyKey)
        XCTAssertNotEqual(calls[1].idempotencyKey, calls[2].idempotencyKey)
        XCTAssertNotEqual(calls[2].idempotencyKey, calls[3].idempotencyKey)
        XCTAssertNotEqual(calls[0].idempotencyKey, calls[4].idempotencyKey)
        XCTAssertEqual(calls[4].idempotencyKey, calls[5].idempotencyKey)
        XCTAssertNotEqual(calls[5].idempotencyKey, calls[6].idempotencyKey)
        XCTAssertTrue(calls.allSatisfy {
            VoiceCloneCreateIdempotency.isValidKey($0.idempotencyKey)
        })
    }

    @MainActor
    func testCreateRetryPreservesKeyForTimeoutNetworkLossAndInProgress() async throws {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = SequencedCreateVoiceCloneService(outcomes: [
            .transport(.timedOut),
            .transport(.networkConnectionLost),
            .failure(.creationIdempotencyInProgress),
            .failure(.creationIdempotencyConflict),
            .success("vc_after_conflict"),
            .success("vc_after_success"),
        ])
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        let recordingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-clone-ambiguous-\(UUID().uuidString).wav")
        try Data([0x52, 0x49, 0x46, 0x46, 4, 3, 2, 1]).write(to: recordingURL)
        defer { try? FileManager.default.removeItem(at: recordingURL) }
        store.activateAccountScope(storageID: String(repeating: "e", count: 64))

        var outcomes: [Bool] = []
        for _ in 0..<6 {
            outcomes.append(await store.create(
                recordingURL: recordingURL,
                referenceLanguage: "en",
                referenceText: "same optional words",
                consentConfirmed: true
            ))
        }

        XCTAssertEqual(outcomes, [false, false, false, false, true, true])
        let calls = await service.createCalls()
        XCTAssertEqual(calls.count, 6)
        XCTAssertEqual(calls[0].idempotencyKey, calls[1].idempotencyKey)
        XCTAssertEqual(calls[1].idempotencyKey, calls[2].idempotencyKey)
        XCTAssertEqual(calls[2].idempotencyKey, calls[3].idempotencyKey)
        XCTAssertNotEqual(calls[3].idempotencyKey, calls[4].idempotencyKey)
        XCTAssertNotEqual(calls[4].idempotencyKey, calls[5].idempotencyKey)
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

    @MainActor
    func testDeleteFailsClosedWhenExplicitOwnerCapabilityForbidsIt() async {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledVoiceCloneService()
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        store.activateAccountScope(storageID: String(repeating: "5", count: 64))
        let blocked = ClonedVoice(
            voiceId: "vc_owner_delete_forbidden",
            access: VoiceGiftAccess(
                kind: .owner,
                capabilities: VoiceGiftCapabilities(
                    canPreview: true,
                    canUse: true,
                    canRename: true,
                    canDelete: false
                )
            )
        )

        await store.delete(blocked)

        let deleteCalls = await service.deleteCalls()
        XCTAssertTrue(deleteCalls.isEmpty)
        XCTAssertNil(store.deletingVoiceId)
        XCTAssertTrue(ClonedVoice(voiceId: "vc_legacy_owner").access.capabilities.canDelete)
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

    func testUnifiedVoiceLibraryDecodesOwnerGiftAndIncompleteSnapshotLossily() throws {
        let data = try Data(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/voice-gift-library-v1.json")
        )

        let result = try VoiceCloneResponseParser.list(from: data)

        XCTAssertEqual(result.schemaVersion, "voice-library-v1")
        XCTAssertFalse(result.snapshotComplete)
        XCTAssertEqual(
            result.voices.map(\.voiceId),
            ["vc_owner_fixture", "vc_gift_fixture"]
        )
        XCTAssertEqual(result.voices[0].access.kind, .owner)
        XCTAssertTrue(result.voices[0].access.capabilities.canUse)
        XCTAssertTrue(result.voices[0].access.capabilities.canRename)
        XCTAssertTrue(result.voices[0].access.capabilities.canDelete)
        XCTAssertEqual(result.voices[0].presentation?.normalizedTitle, "My Voice 1")
        XCTAssertEqual(
            result.voices[0].presentation?.avatar?.resolvedStyle?.glyph,
            .waveBars
        )
        XCTAssertEqual(result.voices[1].access.kind, .gifted)
        XCTAssertEqual(result.voices[1].access.grantId, "grant_fixture")
        XCTAssertEqual(result.voices[1].access.mutationID, "share_fixture")
        XCTAssertEqual(result.voices[1].access.status, "active")
        XCTAssertEqual(result.voices[1].access.donor?.displayName, "Lina")
        XCTAssertEqual(
            result.voices[1].access.donor?.avatarURL,
            "https://castreader.com/assets/avatars/lina.png"
        )
        XCTAssertEqual(result.voices[1].access.recipientAlias, "Bedtime Reader")
        XCTAssertTrue(result.voices[1].access.capabilities.canUse)
        XCTAssertTrue(result.voices[1].access.capabilities.canEditAlias)
        XCTAssertTrue(result.voices[1].access.capabilities.canRemoveAccess)
        XCTAssertFalse(result.voices[1].access.capabilities.canDelete)
        XCTAssertEqual(
            result.voices[1].presentation?.normalizedTitle,
            "Bedtime Reader"
        )
        XCTAssertEqual(
            result.voices[1].presentation?.avatar?.remoteURL?.absoluteString,
            "https://castreader.com/assets/avatars/lina.png"
        )
        XCTAssertTrue(result.invitations.isEmpty)
    }

    func testGiftAccessToleratesNewStatusButNeverPromotesUnknownKindToOwner() throws {
        let result = try VoiceCloneResponseParser.list(from: Data(
            #"{"schemaVersion":"voice-library-v1","snapshotComplete":true,"voices":[{"voiceId":"vc_future_status","access":{"kind":"gifted","status":"future_state","capabilities":{"useTts":true}}},{"voiceId":"vc_unknown_kind","access":{"kind":"future_kind","status":"active","capabilities":{"delete":true}}},{"voiceId":"vc_missing_access"}]}"#.utf8
        ))

        XCTAssertEqual(result.voices.map(\.voiceId), ["vc_future_status"])
        XCTAssertFalse(result.snapshotComplete)
        XCTAssertEqual(result.voices.first?.access.status, "future_state")
        XCTAssertEqual(result.voices.first?.access.kind, .gifted)

        let explicitOwnerWithoutCapabilities = try VoiceCloneResponseParser.list(
            from: Data(
                #"{"schemaVersion":"voice-library-v1","snapshotComplete":true,"voices":[{"voiceId":"vc_owner_closed","access":{"kind":"owner"}}]}"#.utf8
            )
        )
        XCTAssertFalse(
            try XCTUnwrap(explicitOwnerWithoutCapabilities.voices.first)
                .access.capabilities.canRename
        )
        XCTAssertFalse(
            try XCTUnwrap(explicitOwnerWithoutCapabilities.voices.first)
                .access.capabilities.canDelete
        )

        let legacy = try VoiceCloneResponseParser.list(from: Data(
            #"{"voices":[{"voiceId":"vc_legacy_owner"}]}"#.utf8
        ))
        XCTAssertTrue(
            try XCTUnwrap(legacy.voices.first).access.capabilities.canDelete
        )

        let grantOnly = VoiceGiftAccess(
            kind: .gifted,
            grantId: "grant_not_share",
            capabilities: VoiceGiftCapabilities(
                canEditAlias: true,
                canRemoveAccess: true
            )
        )
        XCTAssertNil(grantOnly.mutationID)
    }

    func testGiftInvitationParserCombinesRequestEnvelopeAndInvitationURL() throws {
        let data = Data(
            #"{"data":{"request":{"id":"request_open","status":"pending","createdAt":"2026-08-31T00:00:00Z","futureField":"ok"},"invitationURL":"https://castreader.com/voice-gift/request#open-token"}}"#.utf8
        )

        let invitation = try VoiceCloneResponseParser.giftInvitation(from: data)

        XCTAssertEqual(invitation.id, "request_open")
        XCTAssertTrue(invitation.isPending)
        XCTAssertEqual(invitation.invitationURL, "https://castreader.com/voice-gift/request#open-token")

        let sent = try VoiceCloneResponseParser.sentGiftInvitations(from: Data(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures/voice-gift-sent-requests-v1.json")
        ))
        XCTAssertEqual(sent.schemaVersion, "voice-gift-v1")
        XCTAssertTrue(sent.snapshotComplete)
        XCTAssertEqual(sent.invitations.map(\.id), ["request_fixture"])
        XCTAssertEqual(sent.invitations.first?.authorization?.mode, "until_revoked")
    }

    func testGiftInvitationURLIsPinnedToCanonicalFragmentRoute() throws {
        XCTAssertNotNil(VoiceGiftInvitationURLValidator.validatedURL(
            "https://castreader.com/voice-gift/request#signed-token"
        ))
        XCTAssertNotNil(VoiceGiftInvitationURLValidator.validatedURL(
            "https://www.castreader.com/zh-Hans/voice-gift/request#signed-token"
        ))
        XCTAssertNil(VoiceGiftInvitationURLValidator.validatedURL(
            "https://attacker.example/voice-gift/request#signed-token"
        ))
        XCTAssertNil(VoiceGiftInvitationURLValidator.validatedURL(
            "https://castreader.com/voice-gift/request?token=query-token"
        ))
        XCTAssertNil(VoiceGiftInvitationURLValidator.validatedURL(
            "https://castreader.com/voice-gift/other#signed-token"
        ))
    }

    func testGiftShareExportsOneTappableHTTPSInvitationWithoutAttachmentText() throws {
        let invitationURL = try XCTUnwrap(
            VoiceGiftInvitationURLValidator.validatedURL(
                "https://castreader.com/voice-gift/request#signed-token"
            )
        )

        let items = VoiceGiftShareContract.activityItems(for: invitationURL)

        XCTAssertEqual(items.count, 1)
        XCTAssertFalse(items.contains { $0 is String })
        let sharedURL = try XCTUnwrap(items.first as? URL)
        XCTAssertFalse(sharedURL.isFileURL)
        XCTAssertEqual(sharedURL.scheme, "https")
        XCTAssertEqual(sharedURL.host, "castreader.com")
        XCTAssertEqual(sharedURL.path, "/voice-gift/request")
        XCTAssertEqual(sharedURL.fragment, "signed-token")
        XCTAssertEqual(sharedURL.absoluteString, invitationURL.absoluteString)
    }

    func testVoiceGiftInviterMVPUIContractLivesBehindCreationMethodChooser() throws {
        XCTAssertEqual(
            VoiceGiftInviterUIContract.primaryActionIdentifier,
            "voiceCreationMethodInviteButton"
        )
        XCTAssertEqual(
            VoiceGiftInviterUIContract.primaryTitleKey,
            "邀请朋友录制声音"
        )
        XCTAssertTrue(VoiceGiftInviterUIContract.primaryBenefitKey.contains("Kindle"))
        XCTAssertTrue(VoiceGiftInviterUIContract.primaryBenefitKey.contains("朗读和解读"))
        XCTAssertTrue(VoiceGiftInviterUIContract.primaryBenefitKey.contains("撤回"))
        XCTAssertTrue(VoiceGiftInviterUIContract.primaryControlNoteKey.contains("直接分享链接"))
        XCTAssertTrue(VoiceGiftInviterUIContract.primaryControlNoteKey.contains("无需填写邮箱"))
        XCTAssertFalse(VoiceGiftInviterUIContract.primaryBenefitKey.contains("永久"))
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CastReader/Views/Settings/VoiceCloneCreatedView.swift"))
        XCTAssertFalse(source.contains("pendingInvitationRow"))
        XCTAssertFalse(source.contains("pendingSectionTitle"))
        XCTAssertFalse(source.contains("voiceGiftPending_"))
        XCTAssertFalse(source.contains("private var voiceGiftInvitationAction"))
        XCTAssertTrue(source.contains("voiceCreationMethodSheet"))
        XCTAssertTrue(source.contains("voiceCreationMethodRecordButton"))
        XCTAssertTrue(source.contains("voiceCreationMethodInviteButton"))
        XCTAssertTrue(source.contains("voiceCreationMethodUploadButton"))
        XCTAssertTrue(source.contains("voiceCreationMethodUploadComingSoon"))
        XCTAssertEqual(VoiceGiftContract.authorizationMode, "until_revoked")
    }

    func testVoiceCreationLaunchRequestKeepsDestinationTyped() {
        let record = VoiceBrowserLaunchRequest(creationEntry: .recordMyVoice)
        XCTAssertEqual(record.tab, .created)
        XCTAssertEqual(record.creationEntry, .recordMyVoice)

        let invite = VoiceBrowserLaunchRequest(creationEntry: .inviteFriend)
        XCTAssertEqual(invite.tab, .created)
        XCTAssertEqual(invite.creationEntry, .inviteFriend)

        let explore = VoiceBrowserLaunchRequest(tab: .explore)
        XCTAssertEqual(explore.tab, .explore)
        XCTAssertNil(explore.creationEntry)
    }

    func testVoiceGiftEntryRequiresBothGlobalRegionAndServerCapability() {
        XCTAssertTrue(VoiceGiftHomeEntryPolicy.showsInvite(
            regionEligible: true,
            capabilityEnabled: true
        ))
        XCTAssertFalse(VoiceGiftHomeEntryPolicy.showsInvite(
            regionEligible: true,
            capabilityEnabled: false
        ))
        XCTAssertFalse(VoiceGiftHomeEntryPolicy.showsInvite(
            regionEligible: false,
            capabilityEnabled: true
        ))
    }

    func testHomeVoiceCarouselNeverExceedsItsFixedContainerHeight() {
        for width: CGFloat in [320, 393, 852, 1_366] {
            let cardWidth = HomeVoiceFeatureCarouselLayout.cardWidth(for: width)
            XCTAssertGreaterThanOrEqual(
                cardWidth,
                HomeVoiceFeatureCarouselLayout.minimumCardWidth
            )
            XCTAssertLessThanOrEqual(
                cardWidth,
                HomeVoiceFeatureCarouselLayout.maximumCardWidth
            )
            XCTAssertLessThanOrEqual(
                cardWidth,
                HomeVoiceFeatureCarouselLayout.containerHeight
            )
        }
        XCTAssertEqual(
            HomeVoiceFeatureCarouselLayout.cardWidth(for: 353),
            (353 - 24) / 2.5,
            accuracy: 0.001
        )
    }

    func testVoiceCreationSheetHandoffUsesDismissCallbacksInsteadOfTimingGuess() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CastReader/Views/Settings/VoiceCloneCreatedView.swift"))
        XCTAssertTrue(source.contains("onDismiss: resumeCreationAfterLogin"))
        XCTAssertTrue(source.contains("onDismiss: resumeCreationAfterSheetDismiss"))
        XCTAssertTrue(source.contains("pendingCreationRoute"))
        XCTAssertFalse(source.contains("creationRouteAfterSheetDismiss"))
        XCTAssertFalse(source.contains("280_000_000"))
    }

    func testMainTabRemainsTheOnlyLaunchRequestOwner() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let mainTab = try String(contentsOf: repositoryRoot
            .appendingPathComponent("CastReader/Views/MainTabView.swift"))
        let browser = try String(contentsOf: repositoryRoot
            .appendingPathComponent("CastReader/Views/Settings/VoiceBrowserView.swift"))
        XCTAssertTrue(mainTab.contains("consumeVoiceBrowserLaunchRequest"))
        XCTAssertTrue(mainTab.contains("voiceBrowserLaunchRequest = nil"))
        XCTAssertFalse(browser.contains("consumedCreationLaunchRequestIDs"))
    }

    func testVoiceInviteHomeIllustrationProvidesLightAndDarkAssets() throws {
        let assetURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("CastReader/Assets.xcassets/HomeVoiceInviteIllustration.imageset")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: assetURL.appendingPathComponent("home-voice-invite.png").path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: assetURL.appendingPathComponent("home-voice-invite-dark.png").path
        ))

        let contents = try String(
            contentsOf: assetURL.appendingPathComponent("Contents.json"),
            encoding: .utf8
        )
        XCTAssertTrue(contents.contains("home-voice-invite.png"))
        XCTAssertTrue(contents.contains("home-voice-invite-dark.png"))
        XCTAssertTrue(contents.contains("luminosity"))
        XCTAssertTrue(contents.contains("dark"))
    }

    func testVoiceGiftCapabilityManifestRequiresEveryFrozenDimension() throws {
        let supported = try XCTUnwrap(VoiceGiftCapabilityManifest.decode(from: Data(
            #"{"voiceGift":{"enabled":true,"version":"voice-gift-v1","libraryVersion":"voice-library-v1","serviceRoute":"global","futureField":true}}"#.utf8
        )))
        XCTAssertTrue(supported.isCompatible)

        for mutation in [
            #"{"voiceGift":{"enabled":false,"version":"voice-gift-v1","libraryVersion":"voice-library-v1","serviceRoute":"global"}}"#,
            #"{"voiceGift":{"enabled":true,"version":"voice-gift-v2","libraryVersion":"voice-library-v1","serviceRoute":"global"}}"#,
            #"{"voiceGift":{"enabled":true,"version":"voice-gift-v1","libraryVersion":"voice-library-v2","serviceRoute":"global"}}"#,
            #"{"voiceGift":{"enabled":true,"version":"voice-gift-v1","libraryVersion":"voice-library-v1","serviceRoute":"china"}}"#,
        ] {
            XCTAssertFalse(try XCTUnwrap(
                VoiceGiftCapabilityManifest.decode(from: Data(mutation.utf8))
            ).isCompatible)
        }
    }

    func testInvitationProtocolStillClassifiesOpenAndTerminalStatuses() {
        for status in ["pending", "claimed", "accepted", "future_state"] {
            let invitation = VoiceGiftInvitation(
                requestId: "request_\(status)",
                invitationURL: "https://castreader.com/voice-gift/request#\(status)",
                status: status
            )
            XCTAssertTrue(invitation.isPending, status)
            XCTAssertEqual(
                invitation.isClaimed,
                status == "claimed" || status == "accepted",
                status
            )
        }
        for status in ["fulfilled", "cancelled", "expired"] {
            XCTAssertFalse(VoiceGiftInvitation(
                requestId: "request_\(status)",
                invitationURL: "https://castreader.com/voice-gift/request#\(status)",
                status: status
            ).isPending, status)
        }
    }

    func testGlobalGiftServiceUsesLibraryAndCreatesOpenInviteWithoutEmail() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceCloneTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            VoiceCloneTestURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let recorder = VoiceCloneRequestRecorder()
        VoiceCloneTestURLProtocol.handler = { request in
            recorder.record(request)
            let responseBody: Data
            if request.url?.path == "/api/capabilities" {
                responseBody = Data(
                    #"{"voiceGift":{"enabled":true,"version":"voice-gift-v1","libraryVersion":"voice-library-v1","serviceRoute":"global"}}"#.utf8
                )
            } else if request.url?.path == "/api/voice-clone/library" {
                responseBody = Data(
                    #"{"schemaVersion":"voice-library-v1","snapshotComplete":true,"voices":[]}"#.utf8
                )
            } else {
                responseBody = Data(
                    #"{"data":{"schemaVersion":"voice-gift-v1","request":{"id":"request_1","status":"pending"},"invitationURL":"https://castreader.com/voice-gift/request#token","authorization":{"mode":"until_revoked","expiresAt":null}}}"#.utf8
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                responseBody
            )
        }
        let service = VoiceCloneService(
            baseURL: URL(string: "https://voice-contract.test")!,
            session: session,
            route: .globalGateway,
            sessionProvider: VoiceCloneTestSessionProvider(token: "cms_contract")
        )

        let library = try await service.listVoices()
        XCTAssertEqual(library.schemaVersion, "voice-library-v1")
        XCTAssertTrue(library.voiceGiftEnabled)
        XCTAssertEqual(
            recorder.allRequests().map { $0.url?.path },
            ["/api/capabilities", "/api/voice-clone/library"]
        )
        XCTAssertFalse(recorder.allRequests().contains {
            $0.url?.path == "/api/voice-clone/requests" && $0.httpMethod == "GET"
        })

        let invitation = try await service.createGiftInvitation(
            clientRequestID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            locale: "pt_BR"
        )
        XCTAssertEqual(invitation.id, "request_1")
        XCTAssertEqual(invitation.authorization?.mode, "until_revoked")
        let request = try XCTUnwrap(recorder.lastRequest())
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/voice-clone/requests")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Language"), "pt-BR")
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        let fixtureObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(
                contentsOf: URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .appendingPathComponent("Fixtures/voice-gift-create-request-v1.json")
            )) as? [String: Any]
        )
        XCTAssertEqual(
            NSDictionary(dictionary: object),
            NSDictionary(dictionary: fixtureObject)
        )
        XCTAssertEqual(object["purpose"] as? String, "personal_tts")
        let authorization = try XCTUnwrap(
            object["authorization"] as? [String: Any]
        )
        XCTAssertEqual(authorization["mode"] as? String, "until_revoked")
        XCTAssertNil(
            object["consent"],
            "the inviter cannot consent on behalf of the donor"
        )
        XCTAssertEqual(
            object["clientRequestId"] as? String,
            "11111111-2222-3333-4444-555555555555"
        )
        XCTAssertEqual(object["locale"] as? String, "pt-BR")
        XCTAssertNil(object["email"])
        XCTAssertNil(object["inviteeEmail"])
    }

    func testDelayed401CannotRefreshOrReplayGiftMutationAcrossSessionBoundary() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceCloneTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let requestStarted = expectation(description: "gift mutation started")
        let releaseResponse = DispatchSemaphore(value: 0)
        let recorder = VoiceCloneRequestRecorder()
        let provider = VoiceCloneTestSessionProvider(token: "cms_account_a")
        defer {
            releaseResponse.signal()
            VoiceCloneTestURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        VoiceCloneTestURLProtocol.handler = { request in
            recorder.record(request)
            if request.url?.path == "/api/capabilities" {
                return (
                    HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["Content-Type": "application/json"]
                    )!,
                    Data(
                        #"{"voiceGift":{"enabled":true,"version":"voice-gift-v1","libraryVersion":"voice-library-v1","serviceRoute":"global"}}"#.utf8
                    )
                )
            }
            requestStarted.fulfill()
            _ = releaseResponse.wait(timeout: .now() + 3)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"code":"UNAUTHORIZED"}"#.utf8)
            )
        }
        let service = VoiceCloneService(
            baseURL: URL(string: "https://voice-contract.test")!,
            session: session,
            route: .globalGateway,
            sessionProvider: provider
        )

        let mutation = Task {
            do {
                _ = try await service.createGiftInvitation(
                    clientRequestID: UUID(),
                    locale: "de"
                )
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        await fulfillment(of: [requestStarted], timeout: 3)
        await provider.setToken("cms_account_b")
        releaseResponse.signal()

        let cancelledAtBoundary = await mutation.value
        let refreshCallCount = await provider.refreshCallCount()
        XCTAssertTrue(cancelledAtBoundary)
        XCTAssertEqual(refreshCallCount, 0)
        XCTAssertEqual(
            recorder.allRequests().filter {
                $0.url?.path == "/api/voice-clone/requests"
            }.count,
            1
        )
    }

    func testGlobalOldBackendFallsBackToOwnerVoicesWhenCapabilityIsMissing() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceCloneTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            VoiceCloneTestURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let recorder = VoiceCloneRequestRecorder()
        VoiceCloneTestURLProtocol.handler = { request in
            recorder.record(request)
            let statusCode: Int
            let data: Data
            if request.url?.path == "/api/capabilities" {
                statusCode = 404
                data = Data(#"{"code":"NOT_FOUND"}"#.utf8)
            } else {
                statusCode = 200
                data = Data(#"{"voices":[{"voiceId":"vc_legacy_owner"}]}"#.utf8)
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                data
            )
        }
        let service = VoiceCloneService(
            baseURL: URL(string: "https://voice-contract.test")!,
            session: session,
            route: .globalGateway,
            sessionProvider: VoiceCloneTestSessionProvider(token: "cms_contract")
        )

        let result = try await service.listVoices()

        XCTAssertFalse(result.voiceGiftEnabled)
        XCTAssertEqual(result.voices.map(\.voiceId), ["vc_legacy_owner"])
        XCTAssertEqual(
            recorder.allRequests().map { $0.url?.path },
            ["/api/capabilities", "/api/voice-clone/voices"]
        )
    }

    func testVoiceGiftIsFailClosedOnChinaRouteWithoutSendingARequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceCloneTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            VoiceCloneTestURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        let recorder = VoiceCloneRequestRecorder()
        VoiceCloneTestURLProtocol.handler = { request in
            recorder.record(request)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(#"{"voices":[]}"#.utf8)
            )
        }
        let service = VoiceCloneService(
            baseURL: URL(string: "https://voice-contract.test")!,
            session: session,
            route: .chinaGateway,
            sessionProvider: VoiceCloneTestSessionProvider(token: "cms_contract")
        )

        let library = try await service.listVoices()
        XCTAssertFalse(library.voiceGiftEnabled)
        XCTAssertEqual(
            recorder.allRequests().map { $0.url?.path },
            ["/api/voice-clone/voices"]
        )
        XCTAssertFalse(VoiceGiftFeature.isRegionEligible(on: .chinaGateway))
        do {
            _ = try await service.createGiftInvitation(
                clientRequestID: UUID(),
                locale: "ja"
            )
            XCTFail("China must not call the global Voice Gift contract")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .giftUnavailableInRegion)
        }
        XCTAssertEqual(recorder.allRequests().count, 1)
    }

    func testGiftMutationMapsStableRevokedAndExpiredErrors() async throws {
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

        VoiceCloneTestURLProtocol.handler = { request in
            if request.url?.path == "/api/capabilities" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"voiceGift":{"enabled":true,"version":"voice-gift-v1","libraryVersion":"voice-library-v1","serviceRoute":"global"}}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 410, httpVersion: nil, headerFields: nil)!,
                Data(#"{"code":"VOICE_GIFT_REVOKED"}"#.utf8)
            )
        }
        do {
            try await service.updateGiftAlias(shareID: "share_1", alias: "Mom")
            XCTFail("expected revoked access")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .giftRevoked)
        }

        VoiceCloneTestURLProtocol.handler = VoiceCloneTestURLProtocol.json(
            statusCode: 410,
            data: Data(#"{"code":"VOICE_GIFT_EXPIRED"}"#.utf8)
        )
        do {
            try await service.removeGiftAccess(shareID: "share_1")
            XCTFail("expected expired access")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .giftExpired)
        }
    }

    func testVoiceGiftLimitDetailsParseNestedFieldsAndRetryAfterHeader() throws {
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-01T03:00:00Z")
        )
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: URL(string: "https://api.castreader.ai/api/voice-clone/requests")!,
                statusCode: 429,
                httpVersion: nil,
                headerFields: ["Retry-After": "120"]
            )
        )
        let details = VoiceCloneResponseParser.voiceGiftInvitationLimitDetails(
            from: Data(
                #"{"code":"VOICE_GIFT_ACTIVE_INVITATION_LIMIT_REACHED","details":{"limitType":"active_invitations","limit":20,"current":20,"invitationTtlSeconds":172800,"earliestExpiryAt":"2026-09-02T03:00:00Z"}}"#.utf8
            ),
            response: response,
            now: now
        )

        XCTAssertEqual(details.limitType, "active_invitations")
        XCTAssertEqual(details.limit, 20)
        XCTAssertEqual(details.current, 20)
        XCTAssertEqual(details.invitationTTLSeconds, 172_800)
        XCTAssertEqual(details.retryAfterSeconds, 120)
        XCTAssertEqual(details.retryAt, now.addingTimeInterval(120))
        XCTAssertEqual(
            details.earliestExpiryAt,
            ISO8601DateFormatter().date(from: "2026-09-02T03:00:00Z")
        )
    }

    func testGiftInvitationMapsActiveAndDailyLimitsToActionableErrors() async throws {
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
        let capability = Data(
            #"{"voiceGift":{"enabled":true,"version":"voice-gift-v1","libraryVersion":"voice-library-v1","serviceRoute":"global"}}"#.utf8
        )
        VoiceCloneTestURLProtocol.handler = { request in
            if request.url?.path == "/api/capabilities" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    capability
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "3600"]
                )!,
                Data(
                    #"{"code":"VOICE_GIFT_ACTIVE_INVITATION_LIMIT_REACHED","legacyCode":"VOICE_GIFT_RATE_LIMITED","details":{"limitType":"active_invitations","limit":20,"current":20,"invitationTtlSeconds":172800,"earliestExpiryAt":"2026-09-02T03:00:00Z","retryAfterSeconds":3600}}"#.utf8
                )
            )
        }
        do {
            _ = try await service.createGiftInvitation(
                clientRequestID: UUID(),
                locale: "en"
            )
            XCTFail("expected active invitation limit")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(
                error,
                .giftActiveInvitationLimit(
                    limit: 20,
                    earliestExpiryAt: ISO8601DateFormatter().date(
                        from: "2026-09-02T03:00:00Z"
                    )
                )
            )
        }

        VoiceCloneTestURLProtocol.handler = { request in
            if request.url?.path == "/api/capabilities" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    capability
                )
            }
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "7200"]
                )!,
                Data(
                    #"{"code":"VOICE_GIFT_DAILY_RATE_LIMITED","legacyCode":"VOICE_GIFT_RATE_LIMITED","details":{"limitType":"rolling_24h_creations","limit":20,"current":20,"windowSeconds":86400,"retryAt":"2026-09-02T05:00:00Z","retryAfterSeconds":7200}}"#.utf8
                )
            )
        }
        do {
            _ = try await service.createGiftInvitation(
                clientRequestID: UUID(),
                locale: "en"
            )
            XCTFail("expected rolling 24-hour invitation limit")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(
                error,
                .giftDailyInvitationLimit(
                    limit: 20,
                    retryAt: ISO8601DateFormatter().date(
                        from: "2026-09-02T05:00:00Z"
                    )
                )
            )
        }
    }

    func testLegacyVoiceGiftRateLimitNeverFallsBackToGenericCloneFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [VoiceCloneTestURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer {
            VoiceCloneTestURLProtocol.handler = nil
            session.invalidateAndCancel()
        }
        VoiceCloneTestURLProtocol.handler = { request in
            if request.url?.path == "/api/capabilities" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"voiceGift":{"enabled":true,"version":"voice-gift-v1","libraryVersion":"voice-library-v1","serviceRoute":"global"}}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
                Data(#"{"code":"VOICE_GIFT_RATE_LIMITED","message":"Too many requests"}"#.utf8)
            )
        }
        let service = VoiceCloneService(
            baseURL: URL(string: "https://voice-contract.test")!,
            session: session,
            route: .globalGateway,
            sessionProvider: VoiceCloneTestSessionProvider(token: "cms_contract")
        )

        do {
            _ = try await service.createGiftInvitation(
                clientRequestID: UUID(),
                locale: "zh-Hans"
            )
            XCTFail("expected legacy Voice Gift rate limit")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(error, .giftInvitationRateLimited(retryAt: nil))
            XCTAssertNotEqual(
                error.localizedDescription,
                VoiceCloneError.server(429, nil).localizedDescription
            )
        }

        VoiceCloneTestURLProtocol.handler = { request in
            if request.url?.path == "/api/capabilities" {
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"voiceGift":{"enabled":true,"version":"voice-gift-v1","libraryVersion":"voice-library-v1","serviceRoute":"global"}}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!,
                Data(#"{"code":"VOICE_GIFT_RATE_LIMITED","limitType":"active_invitations","limit":20,"earliestExpiryAt":"2026-09-02T03:00:00Z"}"#.utf8)
            )
        }
        do {
            _ = try await service.createGiftInvitation(
                clientRequestID: UUID(),
                locale: "zh-Hans"
            )
            XCTFail("expected legacy active-invitation limit")
        } catch let error as VoiceCloneError {
            XCTAssertEqual(
                error,
                .giftActiveInvitationLimit(
                    limit: 20,
                    earliestExpiryAt: ISO8601DateFormatter().date(
                        from: "2026-09-02T03:00:00Z"
                    )
                )
            )
        }
    }

    @MainActor
    func testVoiceGiftLimitMessagesExplainTwentyAndFortyEightHourExpiry() throws {
        let manager = AppLanguageManager.shared
        let original = manager.selectedLanguage
        defer { manager.select(original) }
        manager.select(.simplifiedChinese)
        let expiry = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-02T03:00:00Z")
        )

        let active = VoiceCloneError.giftActiveInvitationLimit(
            limit: 20,
            earliestExpiryAt: expiry
        ).localizedDescription
        let daily = VoiceCloneError.giftDailyInvitationLimit(
            limit: 20,
            retryAt: nil
        ).localizedDescription
        let legacy = VoiceCloneError.giftInvitationRateLimited(
            retryAt: nil
        ).localizedDescription

        XCTAssertTrue(active.contains("20"))
        XCTAssertTrue(active.contains("自动过期"))
        XCTAssertTrue(daily.contains("20"))
        XCTAssertTrue(daily.contains("48 小时"))
        XCTAssertTrue(legacy.contains("已达当前上限"))
        XCTAssertTrue(legacy.contains("48 小时"))
        XCTAssertFalse(active.contains("声音克隆请求失败"))
        XCTAssertFalse(daily.contains("声音克隆请求失败"))
        XCTAssertFalse(legacy.contains("声音克隆请求失败"))
    }

    @MainActor
    func testVoiceGiftLimitMessagesFormatInEverySupportedAppLanguage() throws {
        let manager = AppLanguageManager.shared
        let original = manager.selectedLanguage
        defer { manager.select(original) }
        let expiry = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-09-02T03:00:00Z")
        )

        for language in AppLanguage.allCases where language != .system {
            manager.select(language)
            let messages = [
                VoiceCloneError.giftActiveInvitationLimit(
                    limit: 20,
                    earliestExpiryAt: expiry
                ).localizedDescription,
                VoiceCloneError.giftActiveInvitationLimit(
                    limit: 20,
                    earliestExpiryAt: nil
                ).localizedDescription,
                VoiceCloneError.giftDailyInvitationLimit(
                    limit: 20,
                    retryAt: expiry
                ).localizedDescription,
                VoiceCloneError.giftDailyInvitationLimit(
                    limit: 20,
                    retryAt: nil
                ).localizedDescription,
                VoiceCloneError.giftInvitationRateLimited(
                    retryAt: expiry
                ).localizedDescription,
                VoiceCloneError.giftInvitationRateLimited(
                    retryAt: nil
                ).localizedDescription,
            ]
            for message in messages {
                XCTAssertFalse(message.isEmpty, language.rawValue)
                XCTAssertFalse(message.contains("%@"), language.rawValue)
                XCTAssertFalse(message.contains("%lld"), language.rawValue)
                XCTAssertFalse(message.contains("%1$lld"), language.rawValue)
                XCTAssertFalse(message.contains("%2$@"), language.rawValue)
            }
        }
    }

    @MainActor
    func testIncompleteLibrarySnapshotMergesWithoutDeletingGiftedVoice() async {
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
        let gift = ClonedVoice(
            voiceId: "vc_gift",
            access: VoiceGiftAccess(
                kind: .gifted,
                grantId: "grant_1",
                shareId: "share_1",
                status: "active",
                donor: VoiceGiftDonor(displayName: "Lina"),
                capabilities: VoiceGiftCapabilities(canPreview: true, canUse: true)
            )
        )
        await service.enqueueImmediateList(VoiceCloneListResult(
            schemaVersion: "voice-library.v1",
            snapshotComplete: true,
            voices: [ClonedVoice(voiceId: "vc_owner"), gift],
            nextCreateAt: nil
        ))
        await store.refresh()

        await service.enqueueImmediateList(VoiceCloneListResult(
            schemaVersion: "voice-library.v1",
            snapshotComplete: false,
            voices: [ClonedVoice(voiceId: "vc_owner")],
            nextCreateAt: nil
        ))
        await store.refresh()

        XCTAssertEqual(Set(store.voices.map(\.voiceId)), ["vc_owner", "vc_gift"])
        XCTAssertEqual(store.giftedVoices.first?.access.donor?.displayName, "Lina")
    }

    @MainActor
    func testInvitationSnapshotsDoNotCreateAnInviterTaskList() async {
        let service = ControlledVoiceCloneService()
        let store = VoiceCloneStore(
            service: service,
            defaults: UserDefaults(suiteName: "VoiceCloneTests-\(UUID().uuidString)")!,
            isSignedIn: { true }
        )
        store.activateAccountScope(storageID: String(repeating: "d", count: 64))
        let pending = VoiceGiftInvitation(
            requestId: "request_terminal",
            invitationURL: "https://castreader.com/voice-gift/request#terminal",
            status: "pending"
        )
        await service.enqueueImmediateList(VoiceCloneListResult(
            invitationsSnapshotComplete: true,
            voiceGiftEnabled: true,
            voices: [],
            invitations: [pending],
            nextCreateAt: nil
        ))
        await store.refresh()
        XCTAssertTrue(store.voices.isEmpty)

        let fulfilled = VoiceGiftInvitation(
            requestId: pending.id,
            invitationURL: pending.invitationURL,
            status: "fulfilled"
        )
        await service.enqueueImmediateList(VoiceCloneListResult(
            invitationsSnapshotComplete: false,
            voiceGiftEnabled: true,
            voices: [],
            invitations: [fulfilled],
            nextCreateAt: nil
        ))
        await store.refresh()
        XCTAssertTrue(store.voices.isEmpty)
    }

    @MainActor
    func testGiftEntitlementFalseDoesNotClearAuthorizationButTerminalStatusDoes() async {
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

        let settings = AppSettings.shared
        let previousSelections = settings.clonedVoicesByLanguage
        defer {
            let languages = Set(previousSelections.keys).union(["en"])
            for language in languages {
                settings.clearActiveClonedVoice(for: language)
            }
            for (language, voiceID) in previousSelections {
                _ = settings.setActiveClonedVoice(voiceID, for: language)
            }
        }
        let voiceID = "vc_gift_entitlement"
        XCTAssertTrue(settings.setActiveClonedVoice(voiceID, for: "en"))

        let activeAccess = VoiceGiftAccess(
            kind: .gifted,
            grantId: "grant_entitlement",
            status: "active",
            capabilities: VoiceGiftCapabilities(canUse: false)
        )
        XCTAssertTrue(activeAccess.authorizationActive)
        await service.enqueueImmediateList(VoiceCloneListResult(
            schemaVersion: "voice-library-v1",
            snapshotComplete: true,
            voiceGiftEnabled: true,
            voices: [ClonedVoice(voiceId: voiceID, access: activeAccess)],
            nextCreateAt: nil
        ))
        await store.refresh()
        XCTAssertEqual(settings.activeClonedVoiceID(for: "en"), voiceID)

        let revokedAccess = VoiceGiftAccess(
            kind: .gifted,
            grantId: "grant_entitlement",
            status: "revoked",
            capabilities: VoiceGiftCapabilities(canUse: false)
        )
        XCTAssertTrue(revokedAccess.hasTerminalRevocation)
        await service.enqueueImmediateList(VoiceCloneListResult(
            schemaVersion: "voice-library-v1",
            snapshotComplete: true,
            voiceGiftEnabled: true,
            voices: [ClonedVoice(voiceId: voiceID, access: revokedAccess)],
            nextCreateAt: nil
        ))
        await store.refresh()
        XCTAssertNil(settings.activeClonedVoiceID(for: "en"))
    }

    @MainActor
    func testGiftDisplayNamePrefersPrivateAliasThenDonor() {
        let store = VoiceCloneStore(
            service: ControlledVoiceCloneService(),
            defaults: UserDefaults(suiteName: "VoiceCloneTests-\(UUID().uuidString)")!,
            isSignedIn: { true }
        )
        let access = VoiceGiftAccess(
            kind: .gifted,
            grantId: "grant",
            status: "active",
            donor: VoiceGiftDonor(displayName: "Dad"),
            recipientAlias: "Bedtime Reader",
            capabilities: VoiceGiftCapabilities(canUse: true)
        )
        XCTAssertEqual(
            store.displayName(for: ClonedVoice(voiceId: "vc_alias", access: access)),
            "Bedtime Reader"
        )
        let withoutAlias = VoiceGiftAccess(
            kind: .gifted,
            donor: VoiceGiftDonor(displayName: "Dad"),
            capabilities: VoiceGiftCapabilities(canUse: true)
        )
        XCTAssertEqual(
            store.displayName(for: ClonedVoice(voiceId: "vc_donor", access: withoutAlias)),
            "Dad"
        )
        let identityFallback = ClonedVoice(
            voiceId: "vc_identity_fallback",
            identity: makeVoiceIdentity(index: 4, revision: 1),
            access: VoiceGiftAccess(kind: .gifted)
        )
        XCTAssertEqual(
            store.displayName(for: identityFallback),
            String(format: AppLocalized("朗读者声音 %lld"), Int64(4))
        )

        let serverPresentation = VoiceGiftPresentation(
            title: "Server Reader Title",
            titleSource: "donor_display_name",
            avatar: VoiceGiftPresentation.Avatar(
                source: "default",
                style: VoiceCloneAvatarPresentation(
                    styleVersion: "v1",
                    backgroundStart: "#586FD1",
                    backgroundEnd: "#31419E",
                    foreground: "#FFFFFF",
                    glyph: .waveBars
                ),
                url: nil,
                defaultKey: "voice-gift-default-v1"
            )
        )
        let presented = ClonedVoice(
            voiceId: "vc_server_presentation",
            identity: makeVoiceIdentity(index: 8, name: "Local Fallback", revision: 1),
            access: access,
            presentation: serverPresentation
        )
        XCTAssertEqual(store.displayName(for: presented), "Server Reader Title")
        XCTAssertEqual(
            presented.presentation?.avatar?.resolvedStyle?.backgroundStart,
            "#586FD1"
        )
    }

    @MainActor
    func testStorePassesCanonicalLocaleToGiftInvitationService() async throws {
        let suite = "VoiceCloneTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = ControlledVoiceCloneService()
        let store = VoiceCloneStore(
            service: service,
            defaults: defaults,
            isSignedIn: { true }
        )
        store.activateAccountScope(storageID: String(repeating: "a", count: 64))
        await service.enqueueImmediateList(VoiceCloneListResult(
            voiceGiftEnabled: true,
            voices: [],
            nextCreateAt: nil
        ))
        await store.refresh()

        let invitation = await store.createGiftInvitation(locale: "hi_IN")

        XCTAssertNotNil(invitation)
        let calls = await service.giftInvitationCalls()
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.locale, "hi")
        XCTAssertFalse(call.clientRequestID.uuidString.isEmpty)
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

private actor SequencedCreateVoiceCloneService: VoiceCloneStoreServicing {
    enum Outcome: Sendable {
        case success(String)
        case failure(VoiceCloneError)
        case transport(URLError.Code)
    }

    struct CreateCall: Equatable, Sendable {
        let referenceLanguage: String
        let referenceText: String?
        let idempotencyKey: String
    }

    private var outcomes: [Outcome]
    private var calls: [CreateCall] = []

    init(outcomes: [Outcome]) {
        self.outcomes = outcomes
    }

    func hasSession() async -> Bool { true }

    func listVoices() async throws -> VoiceCloneListResult {
        VoiceCloneListResult(voices: [], nextCreateAt: nil)
    }

    func createVoice(
        recordingURL: URL,
        referenceLanguage: String,
        referenceText: String?,
        consentConfirmed: Bool,
        idempotencyKey: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ClonedVoice {
        calls.append(CreateCall(
            referenceLanguage: referenceLanguage,
            referenceText: referenceText,
            idempotencyKey: idempotencyKey
        ))
        onProgress(1)
        guard !outcomes.isEmpty else { throw VoiceCloneError.temporaryUnavailable }
        switch outcomes.removeFirst() {
        case .success(let voiceID):
            return ClonedVoice(voiceId: voiceID)
        case .failure(let error):
            throw error
        case .transport(let code):
            throw URLError(code)
        }
    }

    func renameVoice(
        _ voiceId: String,
        name: String?,
        expectedRevision: Int
    ) async throws -> VoiceCloneIdentity {
        throw VoiceCloneError.identityUnavailable
    }

    func deleteVoice(_ voiceId: String) async throws {
        throw VoiceCloneError.temporaryUnavailable
    }

    func createCalls() -> [CreateCall] {
        calls
    }
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
    private var giftInvitationCallValues: [GiftInvitationCall] = []

    struct RenameCall: Equatable, Sendable {
        let voiceID: String
        let name: String?
        let expectedRevision: Int
    }

    struct GiftInvitationCall: Equatable, Sendable {
        let clientRequestID: UUID
        let locale: String
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
        idempotencyKey: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ClonedVoice {
        onProgress(1)
        return createdVoice
    }

    func createGiftInvitation(
        clientRequestID: UUID,
        locale: String
    ) async throws -> VoiceGiftInvitation {
        giftInvitationCallValues.append(GiftInvitationCall(
            clientRequestID: clientRequestID,
            locale: locale
        ))
        return VoiceGiftInvitation(
            requestId: "request_mock",
            invitationURL: "https://castreader.com/voice-gift/request#mock",
            status: "pending"
        )
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

    func deleteCalls() -> [String] {
        deleteCallValues
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

    func giftInvitationCalls() -> [GiftInvitationCall] {
        giftInvitationCallValues
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
    private var requests: [URLRequest] = []

    func record(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func lastRequest() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return requests.last
    }

    func allRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
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
    private var refreshCalls = 0

    init(token: String?) {
        self.token = token
    }

    func sessionToken() -> String? { token }
    func refreshSession() -> String? {
        refreshCalls += 1
        return token
    }
    func invalidateSession() { token = nil }

    func setToken(_ value: String?) {
        token = value
    }

    func refreshCallCount() -> Int {
        refreshCalls
    }
}
