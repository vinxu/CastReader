//
//  Constants.swift
//  CastReader
//

import SwiftUI

enum Constants {
    enum Features {
        /// Voice cloning remains implemented and its persisted data is retained,
        /// but the feature is intentionally unavailable in this release.
        static let voiceCloningEnabled = false

        /// The provider adapters are not part of this release target.
        static let cloudStorageEnabled = false

        /// 中国大陆账号、手机号、Pro 与埋点后端已在备案域名
        /// `api.castreader.cn` 上线并通过生产接口预检。
        static let chinaBackendEnabled = true

        /// 上海账号后端目前没有 TTS 兼容路由；保持既有 TTS 节点选择，避免中国区
        /// 因区域开关误打到 Next.js 404。后端补齐并通过合成冒烟后再单独开启。
        static let chinaTTSBackendEnabled = false

        /// `qr.castreader.cn` 当前尚未提供可验证的 TLS/QuickRead 服务。中国区暂时
        /// 沿用现有 QuickRead 路由，保证“其他保持不变”。
        static let chinaQuickReadBackendEnabled = false
    }

    enum API {
        static let baseURL = "https://api.castreader.ai"
        /// The reader service is exposed through the same TLS reverse proxy as
        /// TTS. Never send document metadata or uploads to the legacy plaintext
        /// `:8123` origin.
        static let readerServiceURL = baseURL

        // Library
        static let documents = "\(readerServiceURL)/documents"

        // Upload
        static let sts = "\(baseURL)/sts"
        static let asyncUpload = "\(readerServiceURL)/async-md-upload-by-url"
        static let syncUpload = "\(readerServiceURL)/upload"  // EPUB sync upload

        // TTS
        static let tts = "\(baseURL)/api/captioned_speech_partly"
        static let ttsCatalog = "\(baseURL)/api/tts/catalog?contract=tts-voice-catalog-v1"

        // 解读 / QuickRead（独立后端）
        /// 解读后端鉴权 key（对齐扩展的 QUICKREAD_API_KEY）。留空则不发送 x-api-key，后端会返回 401。
        /// 构建期注入：值来自 Secrets.xcconfig 的 QUICKREAD_API_KEY → Info.plist $(QUICKREAD_API_KEY) → 此处读取。
        /// 不进 git；缺失时为空（解读会 401，其余功能不受影响）。
        static var quickReadAPIKey: String {
            (Bundle.main.object(forInfoDictionaryKey: "QuickReadAPIKey") as? String) ?? ""
        }
        /// ⚠️ 运行时实际后端地址走 `QuickReadEndpoint`（COS 远程配置优先，兜底 qr.castreader.ai）。
        /// 下面这些常量已不再被调用（QuickReadService 改用 QuickReadEndpoint），仅保留兜底值供参考。
        static let quickReadBaseURL = "https://qr.castreader.ai"
        static let quickReadPlan = "\(quickReadBaseURL)/api/quickread/extract-plan"          // SSE
        static let quickReadExtractBlock = "\(quickReadBaseURL)/api/quickread/extract-block" // JSON
        static let quickReadComposeBlock = "\(quickReadBaseURL)/api/quickread/compose-block" // JSON
        static let quickReadFastBlock0 = "\(quickReadBaseURL)/api/quickread/fast-block0"     // 快道：直出 block_0 秒开

        // 账号 / Pro 后端（Web，readout-web）
        static let globalWebURL = "https://castreader.ai"

        /// 中国大陆 storefront 使用备案后的境内账号后端；其他 storefront 的地址
        /// 与改动前一致。按需计算，避免首启 Storefront 尚未解析时固化错误区域。
        static var webURL: String {
            guard Features.chinaBackendEnabled, AppRegion.current == .cn else {
                return globalWebURL
            }
            return AppRegion.cn.webBaseURL
        }

        static var proStatus: String { "\(webURL)/api/pro/status" }               // GET ?device_id=&user_id=&local_date=
        static var proListenTrack: String { "\(webURL)/api/pro/listen-track" }    // POST {device_id|user_id, seconds}
        static var proVerifyApple: String { "\(webURL)/api/pro/verify-apple" }    // POST signed StoreKit 2 transaction
        static var authSocialSignIn: String { "\(webURL)/api/auth/sign-in/social" } // POST {provider, idToken:{token}} (better-auth)
        static var analyticsEvents: String { "\(webURL)/api/events" }
        static var pricingURL: String { "\(webURL)/pricing" }

        /// 邮箱验证码登录（better-auth email-otp）走 castreader.com。
        ///
        /// 两站共用同一个 Supabase（user 表是同一份），但 auth 的正式归属是 .com，
        /// 插件也只装在那边——所以只有这条链路换域名，Pro / 额度 / 埋点仍走
        /// `webURL`（castreader.ai），避免为一个登录方式动整个 API 基址。
        static let emailOTPBaseURL = "https://castreader.com"

        /// 法务页面在 castreader.com（与 API 所在的 castreader.ai 是两个站点）。
        ///
        /// 该站只有 en / zh 两个版本，且**英文没有语言前缀**（`/en/...` 会 301 到
        /// `/...`）；其余语言前缀一律 301 回英文，唯独 `/pt-BR/...` 直接 404——
        /// 所以这里只能产出「zh 带前缀 / 其余无前缀」两种形态，不要按 UI 语言拼。
        private static let legalBaseURL = "https://castreader.com"

        /// 跟随 **App 内语言**而非系统语言：用户在设置里切成中文，法务页也要给中文。
        private static var legalLanguagePrefix: String {
            let code = AppLanguageManager.shared.selectedLanguage.resolvedLanguageCode
            return code == "zh" ? "/zh" : ""
        }
        static var termsURL: String { "\(legalBaseURL)\(legalLanguagePrefix)/terms-of-service" }
        static var privacyURL: String { "\(legalBaseURL)\(legalLanguagePrefix)/privacy-policy" }
    }

    /// Google OAuth（原生 ASWebAuthenticationSession + PKCE，无需 SDK）。
    enum GoogleOAuth {
        /// iOS 类型 OAuth client id（Google Cloud Console 创建）。上线前填入真实值。
        /// 形如 "1234567890-abcdef.apps.googleusercontent.com"
        static let clientID = "338957209183-b47lfgk489burf418j3uqs88ghtp35fb.apps.googleusercontent.com"

        static let authEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
        static let tokenEndpoint = "https://oauth2.googleapis.com/token"
        static let scope = "openid email profile"

        /// 反转 client id 作为回调 URL scheme（Google iOS client 约定）。
        static var reversedClientID: String {
            let head = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
            return "com.googleusercontent.apps.\(head)"
        }
        /// 完整 redirect uri：<reversed>:/oauth2redirect
        static var redirectURI: String { "\(reversedClientID):/oauth2redirect" }
        /// 是否已配置真实 client id（否则隐藏 Google 登录入口）。
        static var isConfigured: Bool { !clientID.hasPrefix("YOUR_GOOGLE") }
    }

    enum Storage {
        static let visitorIdKey = "visitor_id"
        static let playbackProgressKey = "playback_progress"
        static let lastPlayedBookKey = "last_played_book"
    }

    enum TTS {
        static let defaultVoice = "af_heart"
        static let defaultSpeed: Double = 1.0
        static let defaultLanguage = "en"
        static let model = "kokoro"
    }

    enum UI {
        static let miniPlayerHeight: CGFloat = 64
        static let tabBarHeight: CGFloat = 49
        // 书封面比例约 2:3
        static let bookCardWidth: CGFloat = 110
        static let bookCardHeight: CGFloat = 165
    }
}
