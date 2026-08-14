//
//  AuthService.swift
//  CastReader
//
//  登录服务。Google 用原生 ASWebAuthenticationSession + PKCE（无第三方 SDK），
//  Google id_token 必须先换成当前线路的 cms_ 会话；better-auth
//  canonical user id 的辅助换取用于按账号查 Pro。
//  Apple 登录见扩展（AuthService+Apple）。
//

import Foundation
import AuthenticationServices
import CryptoKit
import UIKit
import Combine

/// Opaque namespace for every piece of user-owned local content.
///
/// The raw backend/provider id is never written to a filename or UserDefaults
/// key.  Route is part of the digest so an internal CN/global account switch
/// cannot accidentally reuse another gateway's local shelf.
struct AccountContentScope: Equatable, Sendable {
    let storageID: String

    private static let aliasKeyPrefix = "account.content.scope.alias.v1"

    init?(account: UserAccount, route: ServiceRoute = ServiceRouting.current) {
        let backendID = account.backendUserId?.trimmed ?? ""
        let providerID = account.id.trimmed
        let identity = !backendID.isEmpty
            ? "backend:\(backendID)"
            : "provider:\(account.provider):\(providerID)"
        guard !providerID.isEmpty || !backendID.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data("\(route.rawValue)|\(identity)".utf8))
        storageID = digest.map { String(format: "%02x", $0) }.joined()
    }

    private init(storageID: String) {
        self.storageID = storageID
    }

    /// Resolves a stable namespace while an older provider-only account is
    /// upgraded to a canonical backend id.  Without this alias, a temporary
    /// backend exchange failure would create a provider namespace and the next
    /// successful refresh/relaunch would appear to erase that account's local
    /// library by switching to a different digest.
    ///
    /// Alias keys and values are opaque SHA-256 values; raw provider ids,
    /// backend ids, phone numbers and emails are never persisted here.
    static func resolved(
        account: UserAccount,
        route: ServiceRoute = ServiceRouting.current,
        defaults: UserDefaults = .standard
    ) -> AccountContentScope? {
        guard let deterministic = AccountContentScope(account: account, route: route) else {
            return nil
        }

        let backendID = account.backendUserId?.trimmed ?? ""
        let providerID = account.id.trimmed
        var identities: [String] = []
        if !backendID.isEmpty { identities.append("backend:\(backendID)") }
        if !providerID.isEmpty {
            identities.append("provider:\(account.provider):\(providerID)")
        }
        let aliasKeys = identities.map { aliasKey(identity: $0, route: route) }
        let existingStorageID = aliasKeys
            .compactMap { defaults.string(forKey: $0) }
            .first(where: isValidStorageID)
        let scope = existingStorageID.map(AccountContentScope.init(storageID:)) ?? deterministic
        for key in aliasKeys {
            defaults.set(scope.storageID, forKey: key)
        }
        return scope
    }

    private static func aliasKey(identity: String, route: ServiceRoute) -> String {
        let digest = SHA256.hash(data: Data("\(route.rawValue)|\(identity)".utf8))
        let opaqueIdentity = digest.map { String(format: "%02x", $0) }.joined()
        return "\(aliasKeyPrefix).\(opaqueIdentity)"
    }

    private static func isValidStorageID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit }
    }

    func storageKey(_ legacyKey: String) -> String {
        "\(legacyKey).account.\(storageID)"
    }
}

/// Captures one exact signed-in content boundary. The monotonic revision keeps
/// A -> B -> A from making an old asynchronous operation look current merely
/// because the final storage id happens to match its starting account again.
struct AccountContentBoundaryToken: Equatable, Sendable {
    fileprivate let storageID: String
    fileprivate let revision: UInt64
}

/// Switches every user-visible local shelf before AuthService publishes a new
/// identity.  This ordering is the privacy boundary: SwiftUI must never get a
/// frame in which account B is visible while account A's cached content remains.
@MainActor
enum AccountContentIsolation {
    private static var activeStorageID: String?
    private static var boundaryRevision: UInt64 = 0

    static func captureBoundaryToken() -> AccountContentBoundaryToken? {
        guard let activeStorageID else { return nil }
        return AccountContentBoundaryToken(
            storageID: activeStorageID,
            revision: boundaryRevision
        )
    }

    static func isCurrent(_ token: AccountContentBoundaryToken) -> Bool {
        token.storageID == activeStorageID
            && token.revision == boundaryRevision
    }

    private static func advanceBoundaryRevision() {
        boundaryRevision &+= 1
        if boundaryRevision == 0 { boundaryRevision = 1 }
    }

    @discardableResult
    static func activate(for account: UserAccount) -> String? {
        guard let scope = AccountContentScope.resolved(account: account) else {
            deactivate()
            return nil
        }
        let didChangeScope = activeStorageID != scope.storageID
        if didChangeScope {
            advanceBoundaryRevision()
            AudioPlayerService.shared.clearForAccountBoundary()
            KindlePlaybackCenter.shared.close()
            YouTubeCaptionLanguageSwitcher.shared.resetForAccountBoundary()
            YouTubeRouteCenter.shared.resetForAccountBoundary()
            SafariExtensionBridge.invalidateForAccountBoundary()
        }
        activeStorageID = scope.storageID
        _ = AccountContentScopeBridge.activate(storageID: scope.storageID)
        CommercialWebSession.activateAccountScope(scope)
        HistoryStore.shared.activateAccountScope(storageID: scope.storageID)
        YouTubeCacheProvider.activateAccountScope(storageID: scope.storageID)
        ResumeReminderManager.shared.activateAccountScope(storageID: scope.storageID)
        QuotaManager.shared.activateAccountScope(storageID: scope.storageID)
        VoiceCloneStore.shared.activateAccountScope(storageID: scope.storageID)
        KindleLibraryStore.shared.activateAccountScope(scope)
        WeReadLibraryStore.shared.activateAccountScope(scope)
        GoogleBooksLibraryStore.shared.activateAccountScope(scope)
        KoboLibraryStore.shared.activateAccountScope(scope)
        OReillyLibraryStore.shared.activateAccountScope(scope)
        return scope.storageID
    }

    static func deactivate() {
        advanceBoundaryRevision()
        AudioPlayerService.shared.clearForAccountBoundary()
        KindlePlaybackCenter.shared.close()
        YouTubeCaptionLanguageSwitcher.shared.resetForAccountBoundary()
        YouTubeRouteCenter.shared.resetForAccountBoundary()
        SafariExtensionBridge.invalidateForAccountBoundary()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CastReaderSkipSignInGate") {
            activeStorageID = "debug-legacy"
            AccountContentScopeBridge.activateLegacyTestingScope()
            CommercialWebSession.activateLegacyTestingScope()
            _ = HistoryStore.shared.activateLegacyTestingScope()
            YouTubeCacheProvider.activateLegacyTestingScope()
            ResumeReminderManager.shared.activateLegacyTestingScope()
            QuotaManager.shared.activateLegacyTestingScope()
            VoiceCloneStore.shared.activateLegacyTestingScope()
            KindleLibraryStore.shared.activateLegacyTestingScope()
            WeReadLibraryStore.shared.activateLegacyTestingScope()
            GoogleBooksLibraryStore.shared.activateLegacyTestingScope()
            KoboLibraryStore.shared.activateLegacyTestingScope()
            OReillyLibraryStore.shared.activateLegacyTestingScope()
            return
        }
        #endif

        activeStorageID = nil
        AccountContentScopeBridge.deactivate()
        CommercialWebSession.deactivateAccountScope()
        HistoryStore.shared.deactivateAccountScope()
        YouTubeCacheProvider.deactivateAccountScope()
        ResumeReminderManager.shared.deactivateAccountScope()
        QuotaManager.shared.deactivateAccountScope()
        VoiceCloneStore.shared.deactivateAccountScope()
        KindleLibraryStore.shared.deactivateAccountScope()
        WeReadLibraryStore.shared.deactivateAccountScope()
        GoogleBooksLibraryStore.shared.deactivateAccountScope()
        KoboLibraryStore.shared.deactivateAccountScope()
        OReillyLibraryStore.shared.deactivateAccountScope()
    }
}

enum AuthError: Error, LocalizedError, Equatable {
    case notConfigured
    case cancelled
    case invalidCallback
    case tokenExchangeFailed(String)
    case invalidIDToken
    case invalidEmail
    case emailOTPUnavailable
    case invalidOTP
    case emailOTPTimeout
    case emailOTPNetwork
    case emailOTPFailed
    case secureSessionUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured: return AppLocalized("尚未配置 Google 登录")
        case .cancelled: return AppLocalized("已取消登录")
        case .invalidCallback: return AppLocalized("登录回调无效")
        case .tokenExchangeFailed(let m): return AppLocalized("登录失败：\(m)")
        case .invalidIDToken: return AppLocalized("无法解析登录信息")
        case .invalidEmail: return AppLocalized("请输入有效的邮箱地址")
        case .emailOTPUnavailable: return AppLocalized("邮箱登录暂未开放，请使用其他登录方式")
        case .invalidOTP: return AppLocalized("验证码错误或已过期，请重试")
        case .emailOTPTimeout: return AppLocalized("请求超时，请检查网络后重试")
        case .emailOTPNetwork: return AppLocalized("无法连接网络，请检查网络后重试")
        case .emailOTPFailed: return AppLocalized("登录失败，请稍后重试")
        case .secureSessionUnavailable:
            return AppLocalized("登录失败，请稍后重试")
        }
    }
}

@MainActor
final class AuthService: NSObject, ObservableObject {
    static let shared = AuthService()

    enum EmailOTPOperation: Equatable {
        case send
        case verify
    }

    /// Email OTP is a bearer-token JSON flow, not a browser-cookie flow.  A
    /// dedicated stateless client also mirrors Android's no-CookieJar client and
    /// bounds the complete request to the same 20 seconds.
    static var emailOTPSessionConfiguration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        return configuration
    }

    private static let emailOTPSession = OwnedAPIURLSession.make(
        configuration: emailOTPSessionConfiguration
    )
    /// Only CastReader's own account exchange uses this guarded session.
    /// Google token exchange below intentionally remains on URLSession.shared.
    private static let backendSession = OwnedAPIURLSession.shared

    @Published private(set) var account: UserAccount?
    /// Recreates every MainTab-owned StateObject at an account boundary. The
    /// persistent stores below are scope-aware, but transient reader/import
    /// coordinators live in the view tree and must not survive account A -> B.
    @Published private(set) var accountBoundaryID = UUID()
    @Published var isWorking = false
    /// Survives the immediate account->login gate transition long enough for
    /// the root UI to show the server's actual deletion/grace result.
    @Published private(set) var lastAccountDeletionReceipt: AccountDeletionReceipt?

    var isSignedIn: Bool { account != nil }
    var normalizedEmail: String? {
        guard let raw = account?.email else {
            return nil
        }
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !email.isEmpty else { return nil }
        return email
    }
    var hasEmailAccount: Bool { normalizedEmail != nil }

    /// 是否具备可跨设备同步 Pro 的账号身份。
    ///
    /// 全球版靠邮箱（Google/Apple 一定会给），但中国区手机号账号**没有邮箱**，
    /// 它拿到的是后端直接下发的 user id。把邮箱当作唯一判据会把所有手机号
    /// 用户挡在购买之外——付费按钮点不动、Pro 也同步不回来。
    ///
    /// 因此购买与同步类门禁一律用这个判据；只有「确实要把邮箱发给后端」的
    /// 地方才继续读 `normalizedEmail`。
    var hasSyncableAccount: Bool {
        if normalizedEmail != nil { return true }
        return proUserId != nil
    }

    /// 查 Pro 用的账号 id：仅用后端 better-auth user id；关联失败时为 nil → Pro 查询退回 device_id 维度。
    /// 不回退 provider sub（account.id），因其与后端 user_id 不同命名空间，会查不到 Web 端付费的 Pro。
    var proUserId: String? {
        guard let rawValue = account?.backendUserId else { return nil }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return value
    }

    /// Apple 登录未能关联后端 user id 的状态——需要用户重新登录一次才能修复。
    ///
    /// Apple 的 identity token 只在授权回调期间存在，`ensureBackendUserIdForPro()` 对
    /// Apple 账号无能为力（拿不到可重放的 token）。未关联时 Pro 只能按 device_id 查，
    /// 于是 Web 端（Stripe）付费和换过设备的订阅都会被当成未订阅。重新走一遍
    /// Sign in with Apple 会重新换取，是唯一的自救路径，所以要让用户看得见。
    var needsAppleRelink: Bool {
        guard let acc = account, acc.provider == "apple" else { return false }
        return (acc.backendUserId ?? "").isEmpty
    }

    private var webSession: ASWebAuthenticationSession?
    private var activeContentStorageID: String?
    private var accountTransitionEpoch: UInt64 = 0
    private static let legacyAccountKey = "auth_account_v1"
    private static let legacyGoogleIDTokenKey = "google_id_token"
    private static let legacyGoogleAccessTokenKey = "google_access_token"
    private static let legacyBetterAuthSessionTokenKey = "betterauth_session_token"
    private var accountKey: String { Self.accountDefaultsKey(for: ServiceRouting.current) }
    private var credentialKeys: CredentialKeys {
        Self.credentialKeys(for: ServiceRouting.current)
    }

    struct CredentialKeys: Equatable {
        let googleIDToken: String
        let googleAccessToken: String
        let betterAuthSessionToken: String
    }

    static func accountDefaultsKey(for route: ServiceRoute) -> String {
        route.isolatedStorageKey(legacyAccountKey)
    }

    /// Provider token 同样属于后端账号命名空间。global 网关继续读历史 key，
    /// 中国线路则使用 `.cn` 后缀，避免两条线路登录不同账号时互相覆盖或登出。
    static func credentialKeys(for route: ServiceRoute) -> CredentialKeys {
        CredentialKeys(
            googleIDToken: route.isolatedStorageKey(legacyGoogleIDTokenKey),
            googleAccessToken: route.isolatedStorageKey(legacyGoogleAccessTokenKey),
            betterAuthSessionToken: route.isolatedStorageKey(legacyBetterAuthSessionTokenKey)
        )
    }

    static func clearProviderCredentials(for route: ServiceRoute) {
        let keys = credentialKeys(for: route)
        KeychainStore.delete(keys.googleIDToken)
        KeychainStore.delete(keys.googleAccessToken)
        KeychainStore.delete(keys.betterAuthSessionToken)
    }

    override private init() {
        super.init()
        restore()
        startAppleCredentialMonitoring()
    }

    // MARK: - 持久化

    /// A persisted profile alone is not an authenticated account. This pure
    /// policy helper makes the cold-launch migration contract regression
    /// testable without mutating the process-wide AuthService singleton.
    nonisolated static func restorableAccount(
        from data: Data?,
        persistedSessionToken: String?
    ) -> UserAccount? {
        guard persistedSessionToken != nil, let data else { return nil }
        return try? JSONDecoder().decode(UserAccount.self, from: data)
    }

    /// A delayed 401 for account A must not evict a newer account B session.
    /// A nil rejected token means the protected call found no bearer and is
    /// actionable only if the current boundary still has no bearer.
    nonisolated static func shouldCloseAccountForRejectedSession(
        currentToken: String?,
        rejectedToken: String?
    ) -> Bool {
        if let rejectedToken {
            return currentToken == nil || currentToken == rejectedToken
        }
        return currentToken == nil
    }

    func restore() {
        let data = UserDefaults.standard.data(forKey: accountKey)
        let token = MobileSessionStore.persistedSessionToken(
            for: ServiceRouting.current
        )
        if let acc = Self.restorableAccount(
            from: data,
            persistedSessionToken: token
        ) {
            // A persisted profile is not an authenticated session. Older
            // builds could leave `auth_account_v1*` behind after the route's
            // cms_ bearer was missing/cleared, which rendered MainTab with
            // cached content while every protected request returned 401.
            guard let storageID = AccountContentIsolation.activate(for: acc) else {
                discardInvalidRestoredIdentity()
                return
            }
            activeContentStorageID = storageID
            account = acc
        } else {
            discardInvalidRestoredIdentity()
        }
    }

    private func discardInvalidRestoredIdentity() {
        _ = MobileSessionStore.detachLocalSession(for: ServiceRouting.current)
        AccountContentIsolation.deactivate()
        activeContentStorageID = nil
        accountTransitionEpoch &+= 1
        accountBoundaryID = UUID()
        account = nil
        UserDefaults.standard.removeObject(forKey: accountKey)
        Self.clearProviderCredentials(for: ServiceRouting.current)
    }

    private func persist() {
        if let acc = account, let data = try? JSONEncoder().encode(acc) {
            UserDefaults.standard.set(data, forKey: accountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: accountKey)
        }
    }

    func signOut() {
        // Playback and lock-screen metadata are user-owned state too.  Stop
        // them before publishing the signed-out identity so account B can
        // never inherit account A's active queue or Now Playing card.
        AudioPlayerService.shared.stop()
        let detachedToken = MobileSessionStore.detachLocalSession(
            for: ServiceRouting.current
        )
        AccountContentIsolation.deactivate()
        activeContentStorageID = nil
        accountTransitionEpoch &+= 1
        let signedOutEpoch = accountTransitionEpoch
        accountBoundaryID = UUID()
        account = nil
        AppSettings.shared.clearActiveClonedVoice()
        Task {
            await MobileSessionStore.shared.revokeDetachedSession(detachedToken)
        }
        persist()
        Self.clearProviderCredentials(for: ServiceRouting.current)
        Task { @MainActor [weak self] in
            guard let self,
                  self.accountTransitionEpoch == signedOutEpoch,
                  self.account == nil else { return }
            ProManager.shared.clearServerEntitlement()   // 先本地清，避免 refreshServer 失败时 serverPro 滞留为 true
            await ProManager.shared.refreshServer()       // 再按 device_id 维度刷新
            guard self.accountTransitionEpoch == signedOutEpoch,
                  self.account == nil else { return }
            ProManager.shared.refreshSyncState(reason: "sign-out")
        }
    }

    /// Ensures every Build-39 account has an authenticated first-party session.
    /// New Pro/status endpoints never trust a client-supplied user id.
    func ensureMobileSession() async -> Bool {
        guard account != nil else { return false }
        let expectedEpoch = accountTransitionEpoch
        if await MobileSessionStore.shared.sessionToken() != nil {
            return account != nil && accountTransitionEpoch == expectedEpoch
        }
        if await MobileSessionStore.shared.refreshSession() != nil {
            return account != nil && accountTransitionEpoch == expectedEpoch
        }
        guard accountTransitionEpoch == expectedEpoch,
              let provider = account?.provider else { return false }
        let boundaryGeneration = MobileSessionStore.boundaryGeneration(
            for: ServiceRouting.current
        )
        let fallbackToken: String?
        switch provider {
        case "google": fallbackToken = KeychainStore.get(credentialKeys.googleIDToken)
        case "email": fallbackToken = KeychainStore.get(credentialKeys.betterAuthSessionToken)
        default: fallbackToken = nil
        }
        if let fallbackToken, !fallbackToken.isEmpty,
           (try? await MobileSessionStore.shared.exchange(
               provider: provider,
               idToken: fallbackToken,
               expectedBoundaryGeneration: boundaryGeneration
           )) != nil {
            return account != nil && accountTransitionEpoch == expectedEpoch
        }
        guard account != nil, accountTransitionEpoch == expectedEpoch else {
            return false
        }
        // A signed-in UI with no route-local cms_ credential is never valid.
        // This is local state corruption/migration, not a transient transport
        // failure: close the account boundary immediately.
        signOut()
        return false
    }

    /// Called only after a protected first-party endpoint has explicitly
    /// rejected a bearer (or a protected operation found it missing). Network,
    /// DNS and timeout errors never enter this path. Token comparison prevents
    /// a late 401 from account A from signing out a newly logged-in account B.
    func handleRejectedMobileSession(rejectedToken: String?) async {
        guard account != nil else { return }
        let expectedEpoch = accountTransitionEpoch
        let currentToken = await MobileSessionStore.shared.sessionToken()
        guard account != nil, accountTransitionEpoch == expectedEpoch else { return }
        guard Self.shouldCloseAccountForRejectedSession(
            currentToken: currentToken,
            rejectedToken: rejectedToken
        ) else { return }
        signOut()
    }

    /// Voice-clone compatibility wrapper; the session itself is now shared by
    /// all authenticated mobile Pro/account endpoints.
    func ensureMobileSessionForVoiceClone() async -> Bool {
        guard Constants.Features.voiceCloningEnabled else { return false }
        return await ensureMobileSession()
    }

    /// 供 Apple 登录扩展写入账号（private(set) 仅本文件可设）。
    func applyAccount(_ acc: UserAccount) {
        lastAccountDeletionReceipt = nil
        let nextStorageID = AccountContentIsolation.activate(for: acc)
        if activeContentStorageID != nextStorageID {
            accountBoundaryID = UUID()
        }
        activeContentStorageID = nextStorageID
        accountTransitionEpoch &+= 1
        account = acc
        // `serverPro` is account-owned memory. Clear it only after publishing
        // the new account, so Safari's synchronous bridge can never pair the
        // new scope with the previous identity while the refresh is pending.
        ProManager.shared.clearServerEntitlement()
        persist()
    }

    func dismissAccountDeletionReceipt() {
        lastAccountDeletionReceipt = nil
    }

    /// 用服务端返回的资料补齐本地缺失的昵称/头像，**只填空不覆盖**。
    ///
    /// 两条路径拿不到完整资料：邮箱验证码登录（better-auth 响应常不带 name/image）
    /// 与 Apple 的二次登录（只有首次授权给资料）。它们和 Google 登录落在同一个后端
    /// 账号上，而 `/api/pro/status` 会回传 `account{name,email,image}`——用它回填，
    /// 用户就不会看到「同一个账号换个方式登进来就没头像了」。
    func fillMissingProfile(name: String?, pictureURL: String?) {
        guard var acc = account else { return }
        var changed = false
        if (acc.name ?? "").isEmpty, let name, !name.isEmpty {
            acc.name = name
            changed = true
        }
        if (acc.pictureURL ?? "").isEmpty, let pictureURL, !pictureURL.isEmpty {
            acc.pictureURL = pictureURL
            changed = true
        }
        guard changed else { return }
        account = acc
        persist()
    }

    // MARK: - 手机号登录（中国区）

    /// 手机号 + 短信验证码登录。
    ///
    /// 与 Google/Apple 的差别：后端直接下发 mobile session token 与 user id，
    /// 不需要再走 `exchangeWithBackend`。手机号本身只保留脱敏形式。
    func signInWithPhone(phone rawPhone: String, code: String) async throws {
        isWorking = true
        defer { isWorking = false }

        let result = try await PhoneAuthService.shared.verify(phone: rawPhone, code: code)
        do {
            _ = try await MobileSessionStore.shared.adoptExternalSession(
                token: result.sessionToken,
                provider: "phone"
            )
        } catch {
            throw AuthError.secureSessionUnavailable
        }

        let masked = ChinaPhoneNumber.masked(rawPhone)
        applyAccount(
            UserAccount(
                id: result.userId,
                email: nil,
                name: result.displayName,
                pictureURL: nil,
                provider: "phone",
                backendUserId: result.userId,
                maskedPhone: masked.isEmpty ? nil : masked
            )
        )

        // 登录后立刻按账号维度刷新 Pro，避免继续停留在 device_id 维度。
        ProManager.shared.refreshSyncState(reason: "phone-sign-in")
        await ProManager.shared.refresh()
    }

    /// 注销账号：先请求后端删除，再清空本地身份。
    ///
    /// 后端失败时**不**清本地——否则用户会以为已注销，实际数据还在。
    @discardableResult
    func deleteAccount() async throws -> AccountDeletionReceipt {
        isWorking = true
        defer { isWorking = false }

        guard let token = await MobileSessionStore.shared.sessionToken() else {
            throw PhoneAuthError.server(status: 401, message: AppLocalized("请先重新登录后再注销账号"))
        }
        let deletedAccount = account
        let receipt = try await PhoneAuthService.shared.deleteAccount(sessionToken: token)
        if let deletedAccount, deletedAccount.provider == "apple" {
            Self.removeArchivedAppleProfile(for: deletedAccount.id)
        }
        signOut()
        lastAccountDeletionReceipt = receipt
        return receipt
    }

    /// Pro 查询需要 readout-web / better-auth 的 user id。旧版本若登录时换取失败，
    /// 会持久化成 backendUserId=nil；刷新 Pro 前用已保存的 Google id_token 轻量重试一次。
    func ensureBackendUserIdForPro() async -> String? {
        guard var acc = account else { return nil }
        if let id = proUserId { return id }
        guard acc.provider == "google",
              let idToken = KeychainStore.get(credentialKeys.googleIDToken),
              !idToken.isEmpty else {
            return nil
        }
        do {
            guard let id = try await exchangeWithBackend(provider: "google", idToken: idToken),
                  !id.isEmpty else {
                return nil
            }
            acc.backendUserId = id
            applyAccount(acc)
            return id
        } catch {
            return nil
        }
    }

    // MARK: - Google 登录

    func signInWithGoogle() async throws {
        guard Constants.GoogleOAuth.isConfigured else { throw AuthError.notConfigured }
        isWorking = true
        defer { isWorking = false }

        let verifier = Self.randomURLSafe(32)
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.randomURLSafe(16)

        let authURL = try buildGoogleAuthURL(challenge: challenge, state: state)
        let callbackURL = try await presentWebAuth(url: authURL, scheme: Constants.GoogleOAuth.reversedClientID)

        guard let code = Self.queryItem(callbackURL, "code"),
              Self.queryItem(callbackURL, "state") == state else {
            throw AuthError.invalidCallback
        }

        let tokens = try await exchangeGoogleCode(code, verifier: verifier)
        guard let idToken = tokens.id_token, let claims = Self.decodeJWTClaims(idToken) else {
            throw AuthError.invalidIDToken
        }

        var acc = UserAccount(
            id: (claims["sub"] as? String) ?? UUID().uuidString,
            email: claims["email"] as? String,
            name: claims["name"] as? String,
            pictureURL: claims["picture"] as? String,
            provider: "google",
            backendUserId: nil
        )
        // best-effort：换后端 user id（失败不影响登录，Pro 退回 device_id）
        acc.backendUserId = try? await exchangeWithBackend(provider: "google", idToken: idToken)

        // The account is not published until the selected first-party gateway
        // has issued and durably stored a cms_ session. Otherwise Home would
        // look signed in while Documents/QuickRead were anonymous, and could
        // continue showing another account's locally cached state.
        do {
            _ = try await MobileSessionStore.shared.exchange(
                provider: "google",
                idToken: idToken
            )
        } catch {
            Self.clearProviderCredentials(for: ServiceRouting.current)
            throw AuthError.secureSessionUnavailable
        }

        // Duplicate provider credentials are only repair aids. The required
        // cms_ session and its refresh identity were already persisted
        // atomically by MobileSessionStore above.
        _ = KeychainStore.set(idToken, for: credentialKeys.googleIDToken)
        if let at = tokens.access_token {
            _ = KeychainStore.set(at, for: credentialKeys.googleAccessToken)
        }

        applyAccount(acc)
        await ProManager.shared.refreshServer()   // 按账号刷新 Pro
    }

    // MARK: - 邮箱验证码登录（better-auth email-otp）
    //
    // 第三条登录通道：不依赖任何第三方授权服务（中国区 Google 不通时 Apple 之外的
    // 唯一冗余）。后端未启用 email-otp 插件时两个路由返回 404 → emailOTPUnavailable，
    // 插件上线后此通道自动点亮，无需发版。
    //
    // globalGateway / chinaGateway 分别通过各自统一 API 网关进入
    // 同一 canonical account authority。两条线路的本地 session 命名空间仍隔离，
    // 但同一身份解析出的 backend user id 必须相同。
    //
    // Pro 一致性：登录响应里的 user.id 就是 better-auth user id，直接作为
    // backendUserId（无 social idToken 可换，也不需要）。refreshServer 会传 canonical
    // user id，并在可用时附带 email 作为兼容线索；订阅归属不能只靠 email 判断。
    // Better Auth OTP token 会立即换成 cms_ 会话；后端只按该会话解析账号。

    /// 发送登录验证码。成功返回；失败抛 AuthError。
    func sendEmailOTP(to email: String) async throws {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isPlausibleEmail(normalized) else { throw AuthError.invalidEmail }
        isWorking = true
        defer { isWorking = false }
        _ = try await postEmailOTP(
            path: "email-otp/send-verification-otp",
            body: ["email": normalized, "type": "sign-in"],
            operation: .send
        )
    }

    /// 用邮箱+验证码完成登录，成功后与 Google/Apple 一样刷新服务端 Pro。
    func signInWithEmailOTP(email: String, code: String) async throws {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard Self.isPlausibleEmail(normalized) else { throw AuthError.invalidEmail }
        let otp = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !otp.isEmpty else { throw AuthError.invalidOTP }
        isWorking = true
        defer { isWorking = false }

        let obj = try await postEmailOTP(
            path: "sign-in/email-otp",
            body: ["email": normalized, "otp": otp],
            operation: .verify
        )
        let user = obj["user"] as? [String: Any]
        guard let backendId = (user?["id"] as? String) ?? (obj["userId"] as? String),
              !backendId.isEmpty else {
            throw AuthError.invalidIDToken
        }

        // Better Auth 会话 token 只在这里拿到：保存后立即换 cms_；若当下网络
        // 失败，ensureMobileSession() 可在 token 有效期内重试。
        guard let token = obj["token"] as? String, !token.isEmpty else {
            throw AuthError.secureSessionUnavailable
        }
        do {
            _ = try await MobileSessionStore.shared.exchange(
                provider: "email",
                idToken: token
            )
        } catch {
            throw AuthError.secureSessionUnavailable
        }
        _ = KeychainStore.set(token, for: credentialKeys.betterAuthSessionToken)

        // 同一个后端账号可能之前用 Google 登过（email-otp 按 email 命中同一条 user
        // 记录，backendUserId 相同）。better-auth 的登录响应常常不带 name/image，
        // 直接采用会把已有的头像和昵称覆盖成空。所以缺什么就沿用旧账号的。
        let prior = account?.backendUserId == backendId ? account : nil
        let signedInAccount = UserAccount(
            id: backendId,
            email: (user?["email"] as? String) ?? normalized,
            name: (user?["name"] as? String) ?? prior?.name,
            pictureURL: (user?["image"] as? String) ?? prior?.pictureURL,
            provider: "email",
            backendUserId: backendId
        )
        applyAccount(signedInAccount)
        await ProManager.shared.refreshServer()   // 按账号刷新 Pro + 额度
    }

    /// Builds the native OTP request without accepting or replaying browser
    /// cookies. A stale Better Auth cookie makes its CSRF middleware require an
    /// Origin header, which native clients intentionally do not synthesize.
    static func makeEmailOTPRequest(url: URL, body: [String: String]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// Maps Better Auth and the delivery wrapper without calling every 4xx an
    /// invalid code. In particular, a send-stage 403 is never an OTP error.
    static func mapEmailOTPFailure(
        statusCode: Int,
        data: Data,
        operation: EmailOTPOperation
    ) -> AuthError {
        let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let code = (payload?["code"] as? String)?.uppercased() ?? ""

        if code == "INVALID_EMAIL" { return .invalidEmail }
        if operation == .verify,
           code == "INVALID_OTP" || code == "OTP_EXPIRED" || code == "TOO_MANY_ATTEMPTS" {
            return .invalidOTP
        }
        if operation == .verify, [400, 401, 403].contains(statusCode) {
            return .invalidOTP
        }
        switch statusCode {
        case 404:
            return .emailOTPUnavailable
        case 504:
            return .emailOTPTimeout
        default:
            return .emailOTPFailed
        }
    }

    static func mapEmailOTPTransportError(_ error: Error) -> AuthError {
        guard let urlError = error as? URLError else { return .emailOTPFailed }
        switch urlError.code {
        case .timedOut:
            return .emailOTPTimeout
        case .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff,
             .dataNotAllowed:
            return .emailOTPNetwork
        default:
            return .emailOTPFailed
        }
    }

    /// better-auth email-otp 的两个 POST。发码与验码使用同一个无 Cookie
    /// 客户端，但错误语义必须按阶段分开。
    private func postEmailOTP(
        path: String,
        body: [String: String],
        operation: EmailOTPOperation
    ) async throws -> [String: Any] {
        guard let url = URL(string: "\(Constants.API.emailOTPBaseURL)/api/auth/\(path)") else {
            throw AuthError.tokenExchangeFailed("invalid endpoint")
        }
        let request = Self.makeEmailOTPRequest(url: url, body: body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.emailOTPSession.data(for: request)
        } catch {
            throw Self.mapEmailOTPTransportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AuthError.emailOTPFailed
        }
        switch http.statusCode {
        case 200..<300:
            return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        default:
            throw Self.mapEmailOTPFailure(
                statusCode: http.statusCode,
                data: data,
                operation: operation
            )
        }
    }

    private static func isPlausibleEmail(_ s: String) -> Bool {
        guard s.count >= 5, s.count <= 254 else { return false }
        let parts = s.split(separator: "@")
        return parts.count == 2 && parts[1].contains(".") && !parts[0].isEmpty
    }

    // MARK: - Google OAuth 细节

    private func buildGoogleAuthURL(challenge: String, state: String) throws -> URL {
        var comps = URLComponents(string: Constants.GoogleOAuth.authEndpoint)!
        comps.queryItems = [
            .init(name: "client_id", value: Constants.GoogleOAuth.clientID),
            .init(name: "redirect_uri", value: Constants.GoogleOAuth.redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: Constants.GoogleOAuth.scope),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "state", value: state),
            .init(name: "prompt", value: "select_account")
        ]
        guard let url = comps.url else { throw AuthError.notConfigured }
        return url
    }

    private struct GoogleTokenResponse: Decodable {
        let access_token: String?
        let id_token: String?
        let expires_in: Int?
        let refresh_token: String?
    }

    private func exchangeGoogleCode(_ code: String, verifier: String) async throws -> GoogleTokenResponse {
        guard let url = URL(string: Constants.GoogleOAuth.tokenEndpoint) else {
            throw AuthError.tokenExchangeFailed("invalid token endpoint")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let form: [String: String] = [
            "code": code,
            "client_id": Constants.GoogleOAuth.clientID,
            "redirect_uri": Constants.GoogleOAuth.redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier
        ]
        req.httpBody = form.map { "\($0.key)=\(Self.formEncode($0.value))" }.joined(separator: "&").data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw AuthError.tokenExchangeFailed("HTTP \(http.statusCode): \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(GoogleTokenResponse.self, from: data)
    }

    /// 把社交 id_token 发给 better-auth，换取后端 user id（best-effort）。
    func exchangeWithBackend(provider: String, idToken: String) async throws -> String? {
        guard let url = URL(string: Constants.API.authSocialSignIn) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "provider": provider,
            "idToken": ["token": idToken],
            "device_id": ProBackendService.deviceId
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await Self.backendSession.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let user = obj["user"] as? [String: Any], let id = user["id"] as? String { return id }
        if let id = obj["userId"] as? String { return id }
        return nil
    }

    // MARK: - ASWebAuthenticationSession

    private func presentWebAuth(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let error = error {
                    let nsErr = error as NSError
                    if nsErr.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        cont.resume(throwing: AuthError.cancelled)
                    } else {
                        cont.resume(throwing: error)
                    }
                    return
                }
                guard let callback = callback else { cont.resume(throwing: AuthError.invalidCallback); return }
                cont.resume(returning: callback)
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.webSession = session
            if !session.start() {
                cont.resume(throwing: AuthError.cancelled)
            }
        }
    }

    // MARK: - PKCE / JWT 工具

    static func randomURLSafe(_ bytes: Int) -> String {
        var buf = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buf)
        return base64URL(Data(buf))
    }

    static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    static func queryItem(_ url: URL, _ name: String) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == name }?.value
    }

    static func decodeJWTClaims(_ jwt: String) -> [String: Any]? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}

// MARK: - 呈现锚点

extension AuthService: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            return window ?? ASPresentationAnchor()
        }
    }
}
