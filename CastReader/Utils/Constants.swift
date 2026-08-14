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

        /// 中国备案网关的代码能力已编入，但是否使用由 ServiceRouting 的启动快照
        /// 决定。不能再用编译期开关把 CHN storefront 自动切到新线路。
        static let chinaGatewayAvailable = true
    }

    enum API {
        static let globalServiceBaseURL = "https://api.castreader.ai"

        /// App 自有的 TTS、文档和上传网关。它读取本次进程已经冻结的线路，
        /// 不再跟随 AppRegion 动态变化。平台书架（Kindle、微信读书、YouTube 等）
        /// 仍按各自原有域名连接，不属于这层自有 API 路由。
        static var baseURL: String {
            ServiceRouting.current.apiGatewayBaseURL
        }
        /// The reader service is exposed through the same TLS reverse proxy as
        /// TTS. Never send document metadata or uploads to the legacy plaintext
        /// `:8123` origin.
        static var readerServiceURL: String { baseURL }

        // Library
        /// Authenticated, route-scoped document list.  New clients must never
        /// fall back to the historical anonymous `/documents?user_id=...`
        /// contract: the server derives ownership exclusively from the cms_
        /// session presented to this endpoint.
        static var documents: String { "\(readerServiceURL)/api/mobile/documents" }

        // Upload
        /// New clients obtain temporary COS credentials only from the
        /// authenticated, route-scoped mobile upload endpoint. The historical
        /// anonymous `/sts` path remains a server-side compatibility contract
        /// for already released binaries and must never be used as a fallback.
        static var sts: String { "\(baseURL)/api/mobile/upload/sts" }
        static var asyncUpload: String { "\(readerServiceURL)/api/mobile/upload/notify" }

        // TTS
        static var tts: String { "\(baseURL)/api/captioned_speech_partly" }
        static var ttsCatalog: String { "\(baseURL)/api/tts/catalog?contract=tts-voice-catalog-v1" }

        // 解读 / QuickRead。新版客户端不再内置上游 API key。global 保持
        // api.castreader.ai；cn 直接进入 quickread.castreader.cn，避免先到
        // api.castreader.cn 再绕境外 QuickRead。两个入口都必须直接验证 cms_
        // session，客户端禁止携带模型供应商或 QuickRead 服务端密钥。
        static var quickReadBaseURL: String { ServiceRouting.current.quickReadBaseURL }
        static var quickReadPlan: String { "\(quickReadBaseURL)/api/quickread/extract-plan" }
        static var quickReadExtractBlock: String { "\(quickReadBaseURL)/api/quickread/extract-block" }
        static var quickReadComposeBlock: String { "\(quickReadBaseURL)/api/quickread/compose-block" }
        static var quickReadFastBlock0: String { "\(quickReadBaseURL)/api/quickread/fast-block0" }

        // 账号 / Pro 后端（Web，readout-web）
        static let globalWebURL = "https://api.castreader.ai"

        /// 账号、Pro、埋点与手机号后端同样读取进程级固定线路。新版的
        /// 全球/中国自有业务分别统一进入 api.castreader.ai / api.castreader.cn。
        static var webURL: String {
            ServiceRouting.current.webBaseURL
        }

        static var proStatus: String { "\(webURL)/api/pro/status" }               // GET ?device_id=&user_id=&local_date=
        static var proListenTrack: String { "\(webURL)/api/pro/listen-track" }    // POST {device_id|user_id, seconds}
        /// Build-39 native contract: cms_ session is the only Pro identity;
        /// the server derives quota from canonical user + ingress route. The
        /// route-scoped device id is compatibility/diagnostic data only.
        static var mobileProStatusV2: String { "\(webURL)/api/mobile/pro/status/v2" }
        static var mobileProListenTrackV2: String { "\(webURL)/api/mobile/pro/listen-track/v2" }
        static var proVerifyApple: String { "\(webURL)/api/pro/verify-apple" }    // POST signed StoreKit 2 transaction
        static var authSocialSignIn: String { "\(webURL)/api/auth/sign-in/social" } // POST {provider, idToken:{token}} (better-auth)
        static var analyticsEvents: String { "\(webURL)/api/events" }
        static var pricingURL: String { "\(webURL)/pricing" }

        /// 邮箱验证码也走当前网关；两入口最终解析到同一 canonical
        /// user.id 与共享账本，但 session 和本地缓存仍按线路隔离。
        static var emailOTPBaseURL: String { webURL }

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
