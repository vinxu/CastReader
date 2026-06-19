//
//  Constants.swift
//  CastReader
//

import SwiftUI

enum Constants {
    enum API {
        static let baseURL = "https://api.castreader.ai"
        static let readerServiceURL = "http://api.castreader.ai:8123"

        // Library
        static let documents = "\(readerServiceURL)/documents"

        // Upload
        static let sts = "\(baseURL)/sts"
        static let asyncUpload = "\(readerServiceURL)/async-md-upload-by-url"
        static let syncUpload = "\(readerServiceURL)/upload"  // EPUB sync upload

        // TTS
        static let tts = "\(baseURL)/api/captioned_speech_partly"

        // 解读 / QuickRead（独立后端）
        /// 解读后端鉴权 key（对齐扩展的 QUICKREAD_API_KEY）。留空则不发送 x-api-key，后端会返回 401。
        /// 构建期注入：值来自 Secrets.xcconfig 的 QUICKREAD_API_KEY → Info.plist $(QUICKREAD_API_KEY) → 此处读取。
        /// 不进 git；缺失时为空（解读会 401，其余功能不受影响）。
        static var quickReadAPIKey: String {
            (Bundle.main.object(forInfoDictionaryKey: "QuickReadAPIKey") as? String) ?? ""
        }
        static let quickReadBaseURL = "https://quickread.castreader.ai:8444"
        static let quickReadPlan = "\(quickReadBaseURL)/api/quickread/extract-plan"          // SSE
        static let quickReadExtractBlock = "\(quickReadBaseURL)/api/quickread/extract-block" // JSON
        static let quickReadComposeBlock = "\(quickReadBaseURL)/api/quickread/compose-block" // JSON

        // 账号 / Pro 后端（Web，readout-web）
        static let webURL = "https://castreader.ai"
        static let proStatus = "\(webURL)/api/pro/status"               // GET ?device_id=&user_id=&local_date=
        static let proListenTrack = "\(webURL)/api/pro/listen-track"    // POST {device_id|user_id, seconds}
        static let authSocialSignIn = "\(webURL)/api/auth/sign-in/social" // POST {provider, idToken:{token}} (better-auth)
        static let pricingURL = "\(webURL)/pricing"
        static let termsURL = "\(webURL)/terms"
        static let privacyURL = "\(webURL)/privacy"
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
