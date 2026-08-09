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

        /// 中国大陆后端（`api.castreader.cn`）是否已就绪。
        ///
        /// **服务本身已经跑起来了**（2026-08-08 部署在上海的 CVM，手机号短信登录、
        /// 支付宝、Pro 状态、埋点全部上线并通过冒烟测试），但仍然保持 `false`，
        /// 原因只有一个：**域名 ICP 备案还卡在管局审核**（8/6 提交）。
        ///
        /// 实测（2026-08-08，境内网络直连）：同一个 IP、同一个 nginx，
        /// 随便编的 SNI 都能完成 TLS 握手，唯独带 `castreader.cn` 的连接
        /// 在 Client Hello 之后被 RST。80 端口正常，443 被按域名切断 ——
        /// 这是未备案域名的标准待遇，**对境内外用户一视同仁**。
        ///
        /// ⚠️ 不要因为「服务器上 curl 自己是通的」就以为可以打开：那是同机
        /// 回环，根本不经过运营商的拦截点，会得到假的健康结论。
        ///
        /// 备案下号后改成 `true` 即可整体切换，无需改动任何调用方。
        static let chinaBackendEnabled = false
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
        /// 全球版后端。中国大陆后端就绪前，`.cn` 设备也走这里（见
        /// `Constants.Features.chinaBackendEnabled`）。
        static let globalWebURL = "https://castreader.ai"

        /// 当前设备应使用的 Web 后端。
        ///
        /// 只有「区域判定为中国大陆」且「境内后端已就绪」时才切到 `castreader.cn`；
        /// 任一条件不满足都退回 `globalWebURL`，因此其他国家的行为与改动前逐字节一致。
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
        static var analyticsEvents: String { "\(webURL)/api/events" }             // POST 自研埋点
        static var pricingURL: String { "\(webURL)/pricing" }
        private static var legalLanguagePath: String {
            Locale.current.language.languageCode?.identifier == "zh" ? "zh" : "en"
        }
        static var termsURL: String { "\(webURL)/\(legalLanguagePath)/terms-of-service" }
        static var privacyURL: String { "\(webURL)/\(legalLanguagePath)/privacy-policy" }
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
