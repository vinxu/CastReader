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

        /// Google Drive, Dropbox and OneDrive remain implemented while their
        /// public OAuth/provider reviews are pending. Release builds keep every
        /// cloud entry hidden; DEBUG builds can opt in explicitly for regression
        /// testing without exposing the feature to normal users.
        static var cloudStorageEnabled: Bool {
            #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            return arguments.contains("-CastReaderCloudUITest")
                || arguments.contains("-CastReaderEnableCloudStorage")
            #else
            return false
            #endif
        }
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
        static let webURL = "https://castreader.ai"
        static let proStatus = "\(webURL)/api/pro/status"               // GET ?device_id=&user_id=&local_date=
        static let proListenTrack = "\(webURL)/api/pro/listen-track"    // POST {device_id|user_id, seconds}
        static let proVerifyApple = "\(webURL)/api/pro/verify-apple"    // POST signed StoreKit 2 transaction
        static let authSocialSignIn = "\(webURL)/api/auth/sign-in/social" // POST {provider, idToken:{token}} (better-auth)
        static let pricingURL = "\(webURL)/pricing"
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

    /// 云盘连接使用独立 public-client 配置。值由本机 Secrets.xcconfig 注入 Info.plist；
    /// access/refresh token 永远不进入 Info.plist、UserDefaults 或 CastReader 后端。
    enum CloudStorage {
        private static func configuredValue(_ key: String) -> String {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-CastReaderCloudUITest") {
                switch key {
                case "GoogleDriveClientID":
                    return "ui-test.apps.googleusercontent.com"
                case "GoogleDriveRedirectScheme":
                    return "com.googleusercontent.apps.ui-test"
                case "DropboxAppKey":
                    return "ui-test-dropbox"
                case "MicrosoftClientID":
                    return "00000000-0000-0000-0000-000000000001"
                default:
                    break
                }
            }
            #endif
            guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String else { return "" }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  !value.hasPrefix("YOUR_"),
                  value != "unconfigured",
                  !value.contains("$(") else { return "" }
            return value
        }

        enum GoogleDrive {
            static var clientID: String { configuredValue("GoogleDriveClientID") }
            static var redirectScheme: String { configuredValue("GoogleDriveRedirectScheme") }
            static var redirectURI: String { redirectScheme.isEmpty ? "" : "\(redirectScheme):/oauth2redirect" }
            static var isConfigured: Bool { !clientID.isEmpty && !redirectScheme.isEmpty }
        }

        enum Dropbox {
            static var appKey: String { configuredValue("DropboxAppKey") }
            static var callbackScheme: String { appKey.isEmpty ? "" : "db-\(appKey)" }
            static var isConfigured: Bool { !appKey.isEmpty }
        }

        enum Microsoft {
            static var clientID: String { configuredValue("MicrosoftClientID") }
            static let authority = "https://login.microsoftonline.com/common"
            static let redirectURI = "msauth.com.same.castreader://auth"
            static var isConfigured: Bool { !clientID.isEmpty }
        }
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
