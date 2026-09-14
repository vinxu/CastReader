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
            Text(explanation)
        }
    }

    private var balanceLabel: String {
        let quota = store.quotaPresentation
        if pro.isPro, let remaining = quota.remainingSeconds {
            return String(format: AppLocalized("%@ / %@ 剩余"), duration(remaining), duration(quota.limitSeconds))
        }
        return AppLocalized("120 分钟 / 月")
    }

    private var explanation: String {
        var value = AppLocalized("精选音色与我的声音共享，所有语言通用。") + "\n\n"
            + AppLocalized("按成功生成的音频时长计量；试听和重复播放已生成的音频不扣额度。")
        if pro.isPro {
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
        ProManager.shared.debugForcePro = true
        VoiceLibraryStore.shared.setBrowserLanguage("en")
        if VoiceLibraryStore.shared.isFavorite("vl_rowan") {
            VoiceLibraryStore.shared.toggleFavorite("vl_rowan")
        }
        _ = AppSettings.shared.setVoice("vl_rowan", for: "en")
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
