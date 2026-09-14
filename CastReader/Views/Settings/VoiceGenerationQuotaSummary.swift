import SwiftUI

/// All metered voices use the same server snapshot, including across languages.
struct VoiceGenerationQuotaSummary: View {
    @ObservedObject private var store = VoiceCloneStore.shared
    @ObservedObject private var pro = ProManager.shared
    @State private var showsExplanation = false

    var title: String.LocalizationValue = "生成额度"

    var body: some View {
        HStack(spacing: 8) {
            Text(AppLocalized(title))
                .font(.subheadline.weight(.semibold))
            Spacer(minLength: 4)
            Button { showsExplanation = true } label: {
                HStack(spacing: 5) {
                    Text(balanceLabel)
                        .font(.caption)
                        .monospacedDigit()
                    Image(systemName: "info.circle")
                        .font(.caption)
                }
                .foregroundStyle(AppTheme.mutedForeground)
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(AppLocalized("额度说明")))
            .accessibilityValue(Text(balanceLabel))
        }
        .accessibilityIdentifier("voiceGenerationQuotaSummary")
        .alert(AppLocalized("生成额度"), isPresented: $showsExplanation) {
            Button(AppLocalized("完成"), role: .cancel) {}
        } message: {
            Text(Self.sharedExplanation)
        }
    }

    private var balanceLabel: String {
        let quota = store.quotaPresentation
        if pro.isPro, let remaining = quota.remainingSeconds {
            return String(format: AppLocalized("%@ / %@ 剩余"), duration(remaining), duration(quota.limitSeconds))
        }
        return AppLocalized("120 分钟 / 月")
    }

    static var sharedExplanation: String {
        let store = VoiceCloneStore.shared
        let pro = ProManager.shared
        var value = AppLocalized("所有月额度音色与我的声音共享 2 小时/月，所有语言通用。") + "\n\n"
            + AppLocalized("按成功生成的音频时长计量；试听和重复播放已生成的音频不扣额度。")
        if pro.isPro {
            if let remaining = store.quotaPresentation.remainingSeconds {
                value += "\n\n" + String(format: AppLocalized("本月剩余 %lld 分钟"), Int64(max(0, remaining) / 60))
            }
            if let reset = store.quotaPresentation.resetAt, reset > Date() {
                value += "\n\n" + String(format: AppLocalized("下次更新：%@"), reset.formatted(date: .abbreviated, time: .omitted))
            } else if store.quotaPresentation.remainingSeconds == nil {
                value += "\n\n" + AppLocalized("生成额度正在同步")
            }
        }
        return value
    }

    private func duration(_ seconds: Int) -> String {
        if seconds > 0 && seconds < 60 { return AppLocalized("不足 1 分钟") }
        return String(format: AppLocalized("%lld 分钟"), Int64(max(0, seconds) / 60))
    }
}

#if DEBUG
/// Local UI acceptance only. No public assets or production allowance is seeded.
struct VoiceExploreAcceptanceFixture: View {
    @State private var prepared = false

    private func prepare() {
        let dictionary: [String: Any] = [
            "contract": "tts-voice-catalog-v1", "version": "ui-acceptance",
            "languages": [
                ["code": "en", "locale": "en-US", "name": "English", "status": "ga", "defaultVoice": "af_heart", "timestampMode": "word"],
                ["code": "zh", "locale": "zh-CN", "name": "Chinese", "status": "ga", "defaultVoice": "zf_001", "timestampMode": "word"]
            ],
            "voices": [
                Self.voice("af_heart", name: "Heart", language: "en", monthly: false),
                Self.voice("zf_001", name: "晓萱", language: "zh", monthly: false),
                Self.voice("vl_rowan", name: "Rowan", language: "en", monthly: true)
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let catalog = try? TTSVoiceCatalogDocument.decodeServerResponse(from: data) {
            try? VoiceCatalog.install(catalog)
        }
        #if targetEnvironment(simulator)
        if let path = ProcessInfo.processInfo.environment["CASTREADER_VOICE_FIXTURE_DIRECTORY"],
           let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("catalog.json")),
           let catalog = try? TTSVoiceCatalogDocument.decodeServerResponse(from: data) {
            try? VoiceCatalog.install(catalog)
            // Seed only the simulator test cache with verified original avatars.
            // Production continues to load the same avatar URLs from the catalog.
            for voice in VoiceCatalog.all {
                guard let url = VoiceCatalogAssetURL.resolve(voice.avatarURL64),
                      let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("\(voice.id)-avatar.\(url.pathExtension)")),
                      let image = UIImage(data: data) else { continue }
                ImageCache.shared.set(url.absoluteString, image: image, data: data)
            }
        }
        #endif
        ProManager.shared.debugForcePro = true
        VoiceLibraryStore.shared.setBrowserLanguage("en")
        let initialID = VoiceCatalog.option(for: "vl_04554c7370e94e483123") == nil ? "vl_rowan" : "vl_04554c7370e94e483123"
        for id in ["vl_rowan", "vl_04554c7370e94e483123", "vl_083fdead97ec221573f3"] where VoiceLibraryStore.shared.isFavorite(id) {
            VoiceLibraryStore.shared.toggleFavorite(id)
        }
        _ = AppSettings.shared.setVoice(initialID, for: "en")
        VoiceCloneStore.shared.applyCapability(VoiceCloneCapability(
            canApply: true, monthlyLimitSeconds: 7200, monthlyUsedSeconds: 2640,
            monthlyRemainingSeconds: 4560, resetAt: Date().addingTimeInterval(86400 * 15)
        ))
    }

    var body: some View {
        Group {
            if prepared { VoiceBrowserView(presentation: .tab) }
            else { ProgressView() }
        }
        .task {
            guard !prepared else { return }
            prepare()
            prepared = true
        }
    }

    private static func voice(_ id: String, name: String, language: String, monthly: Bool) -> [String: Any] {
        var voice: [String: Any] = ["id": id, "name": name, "language": language, "locale": language,
            "engine": monthly ? "clone" : "preset", "modelVersion": "fixture", "genderPresentation": "male",
            "tier": monthly ? "pro" : "free", "status": "ga", "enabled": true, "selectable": true, "timestampMode": "word"]
        if monthly {
            voice["usagePolicy"] = "monthly_generation"
            voice["supportedLanguages"] = ["en", "zh"]
            voice["sampleUrls"] = ["en": "/api/voice-clone/public/vl_rowan/preview?language=en", "zh": "/api/voice-clone/public/vl_rowan/preview?language=zh"]
        }
        return voice
    }
}
#endif
