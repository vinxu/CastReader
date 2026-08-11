//
//  GoogleDriveProvider.swift
//  CastReader
//
//  Google Drive establishes a durable read-only OAuth connection, then lists
//  files and folders in CastReader's native browser. Downloaded bytes stay on
//  device and flow into the shared document import pipeline.
//

import AuthenticationServices
import CryptoKit
import Foundation
import OSLog
import Security
import UIKit

// MARK: - Injectable boundaries

protocol GoogleDriveHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)

    func download(
        for request: URLRequest,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> (URL, URLResponse)
}

struct GoogleDriveURLSessionTransport: GoogleDriveHTTPTransport, @unchecked Sendable {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }

    func download(
        for request: URLRequest,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> (URL, URLResponse) {
        let delegate = GoogleDriveDownloadProgressDelegate(
            maximumBytes: maximumBytes,
            progress: progress
        )
        do {
            let result = try await session.download(for: request, delegate: delegate)
            if delegate.exceededLimit {
                try? FileManager.default.removeItem(at: result.0)
                throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
            }
            return result
        } catch {
            if delegate.exceededLimit {
                throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
            }
            throw error
        }
    }
}

@MainActor
protocol GoogleDriveWebAuthenticating: AnyObject, Sendable {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
    func cancel()
}

@MainActor
final class GoogleDriveSystemWebAuthenticator: NSObject,
    GoogleDriveWebAuthenticating,
    ASWebAuthenticationPresentationContextProviding,
    @unchecked Sendable
{
    private struct Attempt {
        let id: UUID
        let callbackScheme: String
        let redirectURI: String
        let expectedState: String
        let continuation: CheckedContinuation<URL, Error>
    }

    private static weak var activeAuthenticator: GoogleDriveSystemWebAuthenticator?
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.same.castreader",
        category: "GoogleDriveOAuth"
    )

    private var session: ASWebAuthenticationSession?
    private var attempt: Attempt?
    private var timeoutTask: Task<Void, Never>?
    private let timeoutNanoseconds: UInt64

    init(timeoutInterval: TimeInterval = 180) {
        timeoutNanoseconds = UInt64(max(1, timeoutInterval) * 1_000_000_000)
        super.init()
    }

    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let attemptID = UUID()
        try Task.checkCancellation()
        cancel()
        #if DEBUG
        print("GoogleDriveOAuth event=authenticator_begin")
        #endif
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let query = URLComponents(
                    url: url,
                    resolvingAgainstBaseURL: false
                )?.queryItems ?? []
                let redirectURI = query.first(where: {
                    $0.name == "redirect_uri"
                })?.value ?? ""
                let expectedState = query.first(where: {
                    $0.name == "state"
                })?.value ?? ""
                attempt = Attempt(
                    id: attemptID,
                    callbackScheme: callbackScheme,
                    redirectURI: redirectURI,
                    expectedState: expectedState,
                    continuation: continuation
                )
                Self.activeAuthenticator = self
                let webSession = ASWebAuthenticationSession(
                    url: url,
                    callback: .customScheme(callbackScheme)
                ) { [weak self] callbackURL, error in
                    Task { @MainActor [weak self] in
                        self?.finishSessionAttempt(
                            attemptID: attemptID,
                            callbackURL: callbackURL,
                            error: error
                        )
                    }
                }
                webSession.presentationContextProvider = self
                webSession.prefersEphemeralWebBrowserSession = false
                session = webSession
                timeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: self?.timeoutNanoseconds ?? 0)
                    } catch {
                        return
                    }
                    self?.finish(
                        attemptID: attemptID,
                        result: .failure(
                            CloudStorageError.network(code: "google_web_auth_timeout")
                        ),
                        cancelSession: true
                    )
                }

                guard !Task.isCancelled else {
                    finish(
                        attemptID: attemptID,
                        result: .failure(CancellationError()),
                        cancelSession: false
                    )
                    return
                }

                guard webSession.start() else {
                    finish(
                        attemptID: attemptID,
                        result: .failure(
                            CloudStorageError.provider(
                                code: "google_web_auth_not_started",
                                retryable: true
                            )
                        ),
                        cancelSession: false
                    )
                    return
                }
                Self.logger.notice("oauth_browser_started")
                #if DEBUG
                print("GoogleDriveOAuth event=browser_started")
                #endif
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.cancel(attemptID: attemptID) }
        }
    }

    func cancel() {
        guard let attempt else {
            timeoutTask?.cancel()
            timeoutTask = nil
            session?.cancel()
            session = nil
            if Self.activeAuthenticator === self {
                Self.activeAuthenticator = nil
            }
            return
        }
        finish(
            attemptID: attempt.id,
            result: .failure(CloudStorageError.userCancelled),
            cancelSession: true
        )
    }

    private func cancel(attemptID: UUID) {
        guard attempt?.id == attemptID else { return }
        finish(
            attemptID: attemptID,
            result: .failure(CloudStorageError.userCancelled),
            cancelSession: true
        )
    }

    /// Google OAuth may hand its custom-scheme callback to the app after
    /// opening a new tab in the default browser. Normally
    /// `ASWebAuthenticationSession` consumes that redirect itself; this entry
    /// point is the safe fallback when UIKit/SwiftUI receives it instead.
    @discardableResult
    static func handleRedirectURL(_ url: URL) -> Bool {
        guard let authenticator = activeAuthenticator,
              let attempt = authenticator.attempt,
              matches(
                  url,
                  callbackScheme: attempt.callbackScheme,
                  redirectURI: attempt.redirectURI,
                  expectedState: attempt.expectedState
              ) else {
            return false
        }
        logger.notice("oauth_app_callback_received")
        #if DEBUG
        print("GoogleDriveOAuth event=app_callback_received")
        #endif
        authenticator.finish(
            attemptID: attempt.id,
            result: .success(url),
            cancelSession: true
        )
        return true
    }

    nonisolated static func matches(_ url: URL, callbackScheme: String) -> Bool {
        guard let scheme = url.scheme, !callbackScheme.isEmpty else { return false }
        return scheme.caseInsensitiveCompare(callbackScheme) == .orderedSame
    }

    nonisolated static func matches(
        _ url: URL,
        callbackScheme: String,
        redirectURI: String,
        expectedState: String
    ) -> Bool {
        guard matches(url, callbackScheme: callbackScheme),
              !redirectURI.isEmpty,
              !expectedState.isEmpty,
              let callback = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              let redirect = URLComponents(string: redirectURI),
              callback.host?.lowercased() == redirect.host?.lowercased(),
              callback.path == redirect.path else {
            return false
        }
        return callback.queryItems?.first(where: {
            $0.name == "state"
        })?.value == expectedState
    }

    private func finishSessionAttempt(
        attemptID: UUID,
        callbackURL: URL?,
        error: Error?
    ) {
        guard attempt?.id == attemptID else { return }
        if let error {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                finish(
                    attemptID: attemptID,
                    result: .failure(CloudStorageError.userCancelled),
                    cancelSession: false
                )
            } else {
                Self.logger.error("oauth_browser_failed")
                finish(
                    attemptID: attemptID,
                    result: .failure(
                        CloudStorageError.network(code: "google_web_auth_failed")
                    ),
                    cancelSession: false
                )
            }
            return
        }

        guard let callbackURL else {
            finish(
                attemptID: attemptID,
                result: .failure(
                    CloudStorageError.invalidResponse(code: "google_missing_callback")
                ),
                cancelSession: false
            )
            return
        }
        guard let attempt,
              Self.matches(
                  callbackURL,
                  callbackScheme: attempt.callbackScheme,
                  redirectURI: attempt.redirectURI,
                  expectedState: attempt.expectedState
              ) else {
            Self.logger.error("oauth_callback_contract_mismatch")
            finish(
                attemptID: attemptID,
                result: .failure(
                    CloudStorageError.invalidResponse(
                        code: "google_callback_contract_mismatch"
                    )
                ),
                cancelSession: false
            )
            return
        }
        Self.logger.notice("oauth_session_callback_received")
        #if DEBUG
        print("GoogleDriveOAuth event=session_callback_received")
        #endif
        finish(
            attemptID: attemptID,
            result: .success(callbackURL),
            cancelSession: false
        )
    }

    private func finish(
        attemptID: UUID,
        result: Result<URL, Error>,
        cancelSession: Bool
    ) {
        guard let attempt, attempt.id == attemptID else { return }
        self.attempt = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        let retainedSession = session
        session = nil
        if Self.activeAuthenticator === self {
            Self.activeAuthenticator = nil
        }
        if cancelSession {
            retainedSession?.cancel()
        }
        attempt.continuation.resume(with: result)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        return window ?? ASPresentationAnchor()
    }
}

protocol GoogleDriveCredentialStoring: Sendable {
    func load() async -> GoogleDriveCredential?
    func save(_ credential: GoogleDriveCredential) async throws
    func delete() async

    /// Atomic compare-and-swap used to keep a stale OAuth/refresh completion
    /// from overwriting or deleting a newer credential generation.
    func replace(
        expected: GoogleDriveCredential?,
        with replacement: GoogleDriveCredential?
    ) async throws -> Bool
}

actor GoogleDriveKeychainCredentialStore: GoogleDriveCredentialStoring {
    private let key: String

    init(key: String = "google_drive_credentials_v1") {
        self.key = key
    }

    func load() -> GoogleDriveCredential? {
        guard let raw = KeychainStore.get(key),
              let data = raw.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(GoogleDriveCredential.self, from: data)
    }

    func save(_ credential: GoogleDriveCredential) throws {
        let data = try JSONEncoder().encode(credential)
        guard let raw = String(data: data, encoding: .utf8),
              KeychainStore.set(
                  raw,
                  for: key,
                  accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
              ) else {
            throw CloudStorageError.provider(
                code: "google_keychain_write_failed",
                retryable: false
            )
        }
    }

    func delete() {
        KeychainStore.delete(key)
    }

    func replace(
        expected: GoogleDriveCredential?,
        with replacement: GoogleDriveCredential?
    ) throws -> Bool {
        guard load() == expected else { return false }
        if let replacement {
            try save(replacement)
        } else {
            delete()
        }
        return true
    }
}

/// A revocation-only token is tied to the Google account that issued it. The
/// optional fingerprint is a crash marker for the exact local credential that
/// was being disconnected: it must never be interpreted as a disconnect for a
/// later credential, even when that credential belongs to the same account.
struct GoogleDrivePendingRevocation: Codable, Hashable, Sendable {
    let stableAccountKey: String
    let token: String
    let disconnectedCredentialFingerprint: String?
}

/// Revocation-only records survive a network failure or process restart, but
/// are isolated from the active Drive credential and can never authorize file
/// API requests. Google confirmation removes a record; a successful new grant
/// removes only records for that same account and leaves other accounts intact.
protocol GoogleDriveRevocationStoring: Sendable {
    func loadRecords() async -> Set<GoogleDrivePendingRevocation>
    func saveRecords(_ records: Set<GoogleDrivePendingRevocation>) async throws
}

actor GoogleDriveKeychainRevocationStore: GoogleDriveRevocationStoring {
    private let key: String

    init(key: String = "google_drive_pending_revocations_v1") {
        self.key = key
    }

    func loadRecords() -> Set<GoogleDrivePendingRevocation> {
        guard let raw = KeychainStore.get(key),
              let data = raw.data(using: .utf8) else {
            return []
        }
        if let records = try? JSONDecoder().decode(
            [GoogleDrivePendingRevocation].self,
            from: data
        ) {
            return Set(records.filter { !$0.token.isEmpty })
        }

        // Pre-release builds stored a bare token array. Preserve its remote
        // cleanup value without letting an unowned legacy token disconnect an
        // active account whose identity cannot be proven.
        if let legacyTokens = try? JSONDecoder().decode([String].self, from: data) {
            return Set(legacyTokens.compactMap { token in
                guard !token.isEmpty else { return nil }
                return GoogleDrivePendingRevocation(
                    stableAccountKey: "",
                    token: token,
                    disconnectedCredentialFingerprint: nil
                )
            })
        }
        return []
    }

    func saveRecords(_ records: Set<GoogleDrivePendingRevocation>) throws {
        guard !records.isEmpty else {
            KeychainStore.delete(key)
            return
        }
        let ordered = records.sorted { lhs, rhs in
            if lhs.stableAccountKey != rhs.stableAccountKey {
                return lhs.stableAccountKey < rhs.stableAccountKey
            }
            if lhs.token != rhs.token { return lhs.token < rhs.token }
            return (lhs.disconnectedCredentialFingerprint ?? "")
                < (rhs.disconnectedCredentialFingerprint ?? "")
        }
        let data = try JSONEncoder().encode(ordered)
        guard let raw = String(data: data, encoding: .utf8),
              KeychainStore.set(
                raw,
                for: key,
                accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
              ) else {
            throw CloudStorageError.provider(
                code: "google_revocation_keychain_write_failed",
                retryable: false
            )
        }
    }
}

/// Directly constructed providers are used by deterministic tests. Production
/// explicitly supplies the Keychain-backed store in `live(configuration:)`.
actor GoogleDriveVolatileRevocationStore: GoogleDriveRevocationStoring {
    private var records = Set<GoogleDrivePendingRevocation>()
    func loadRecords() -> Set<GoogleDrivePendingRevocation> { records }
    func saveRecords(_ records: Set<GoogleDrivePendingRevocation>) {
        self.records = records
    }
}

struct GoogleDriveCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let account: CloudAccount
    let rawPermissionID: String
    /// Scopes associated with this local grant. Optional for migration from
    /// the legacy drive.file Picker credential; browser connection setup
    /// deliberately reauthorizes those credentials for drive.readonly.
    let authorizedScopes: [String]?
    /// Device-local authorization generation. Optional only so credentials
    /// written by older builds remain decodable; refresh keeps the generation,
    /// while every authorization-code exchange creates a new one.
    let localGenerationID: UUID?

    init(
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        account: CloudAccount,
        rawPermissionID: String,
        authorizedScopes: [String]? = nil,
        localGenerationID: UUID? = UUID()
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.account = account
        self.rawPermissionID = rawPermissionID
        self.authorizedScopes = authorizedScopes
        self.localGenerationID = localGenerationID
    }
}

// MARK: - Provider

actor GoogleDriveProvider: CloudAtomicPickerProvider, CloudDriveListingProvider {
    nonisolated let id: CloudProviderID = .googleDrive
    nonisolated let selectionCapability: CloudSelectionCapability =
        .persistentConnectionAndNativeBrowser

    struct Configuration: Equatable, Sendable {
        static let driveReadonlyScope =
            "https://www.googleapis.com/auth/drive.readonly"
        /// Legacy mobile Picker scope retained only by authorizeAndPick().
        static let driveFileScope = "https://www.googleapis.com/auth/drive.file"
        static let googleDocumentMIMEType = "application/vnd.google-apps.document"
        static let googleSpreadsheetMIMEType =
            "application/vnd.google-apps.spreadsheet"
        static let googlePresentationMIMEType =
            "application/vnd.google-apps.presentation"
        static let googleDrawingMIMEType = "application/vnd.google-apps.drawing"
        static let googleFolderMIMEType = "application/vnd.google-apps.folder"
        static let googleShortcutMIMEType = "application/vnd.google-apps.shortcut"
        static let pdfMIMEType = "application/pdf"
        static let docxMIMEType =
            "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

        let clientID: String
        let redirectURI: String
        let callbackScheme: String
        let authorizationEndpoint: URL
        let tokenEndpoint: URL
        let revokeEndpoint: URL
        let driveAPIBaseURL: URL

        init(
            clientID: String,
            redirectURI: String,
            callbackScheme: String,
            authorizationEndpoint: URL = URL(
                string: "https://accounts.google.com/o/oauth2/v2/auth"
            )!,
            tokenEndpoint: URL = URL(string: "https://oauth2.googleapis.com/token")!,
            revokeEndpoint: URL = URL(string: "https://oauth2.googleapis.com/revoke")!,
            driveAPIBaseURL: URL = URL(
                string: "https://www.googleapis.com/drive/v3"
            )!
        ) {
            self.clientID = clientID
            self.redirectURI = redirectURI
            self.callbackScheme = callbackScheme
            self.authorizationEndpoint = authorizationEndpoint
            self.tokenEndpoint = tokenEndpoint
            self.revokeEndpoint = revokeEndpoint
            self.driveAPIBaseURL = driveAPIBaseURL
        }
    }

    private struct RefreshOperation {
        let id: UUID
        let epoch: UInt64
        let task: Task<GoogleDriveCredential, Error>
    }

    private struct StagedPick {
        let credential: GoogleDriveCredential
        let item: CloudItem
    }

    /// A stable pseudo-folder shown only on the first root page. Opening it
    /// maps to Drive's `sharedWithMe` query and never travels to the API as an
    /// actual file identifier.
    nonisolated static let sharedWithMeFolderID =
        "__castreader_google_shared_with_me__"

    private let configuration: Configuration
    private let transport: any GoogleDriveHTTPTransport
    private let credentialStore: any GoogleDriveCredentialStoring
    private let revocationStore: any GoogleDriveRevocationStoring
    private let webAuthenticator: any GoogleDriveWebAuthenticating
    private let now: @Sendable () -> Date
    private let randomData: @Sendable (Int) throws -> Data
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let capacityPreflight: CloudDownloadCapacityPreflight

    private var epoch: UInt64 = 0
    private var authorizingEpoch: UInt64?
    private var refreshOperation: RefreshOperation?
    private var stagedPick: StagedPick?
    private var candidateCredential: GoogleDriveCredential?
    private var volatilePendingRevocations = Set<GoogleDrivePendingRevocation>()

    init(
        configuration: Configuration,
        transport: any GoogleDriveHTTPTransport,
        credentialStore: any GoogleDriveCredentialStoring,
        revocationStore: any GoogleDriveRevocationStoring = GoogleDriveVolatileRevocationStore(),
        webAuthenticator: any GoogleDriveWebAuthenticating,
        now: @escaping @Sendable () -> Date = { Date() },
        randomData: @escaping @Sendable (Int) throws -> Data = { byteCount in
            try GoogleDriveProvider.secureRandomData(byteCount)
        },
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        capacityPreflight: @escaping CloudDownloadCapacityPreflight =
            CloudDownloadCapacityPolicy.live
    ) {
        self.configuration = configuration
        self.transport = transport
        self.credentialStore = credentialStore
        self.revocationStore = revocationStore
        self.webAuthenticator = webAuthenticator
        self.now = now
        self.randomData = randomData
        self.sleep = sleep
        self.capacityPreflight = capacityPreflight
    }

    @MainActor
    static func live(configuration: Configuration) -> GoogleDriveProvider {
        GoogleDriveProvider(
            configuration: configuration,
            transport: GoogleDriveURLSessionTransport(),
            credentialStore: GoogleDriveKeychainCredentialStore(),
            revocationStore: GoogleDriveKeychainRevocationStore(),
            webAuthenticator: GoogleDriveSystemWebAuthenticator()
        )
    }

    func connectionState() async -> CloudConnectionState {
        if authorizingEpoch != nil { return .connecting }
        guard let credential = await credentialStore.load() else {
            return .disconnected
        }

        let records = await pendingRevocations()
        let fingerprint = Self.revocationCredentialFingerprint(credential)
        if records.contains(where: {
            $0.stableAccountKey == credential.account.stableAccountKey
                && $0.disconnectedCredentialFingerprint == fingerprint
        }) {
            // The process died after persisting this exact credential's local
            // disconnect intent but before clearing it. Finish that deletion;
            // records for another account must never affect this credential.
            await credentialStore.delete()
            return .disconnected
        }

        if records.contains(where: {
            $0.stableAccountKey == credential.account.stableAccountKey
        }) {
            // A different credential generation for the same account was
            // deliberately authorized after the old disconnect. The old grant
            // must neither disconnect nor later revoke the replacement grant.
            await discardPendingRevocations(
                forAccountKey: credential.account.stableAccountKey
            )
        }
        guard Self.hasReadonlyScope(credential.authorizedScopes) else {
            return .needsReauthorization(credential.account)
        }
        if !credential.accessToken.isEmpty,
           credential.expiresAt > now().addingTimeInterval(30) {
            return .connected(credential.account)
        }
        if !credential.refreshToken.isEmpty {
            return .connected(credential.account)
        }
        return .needsReauthorization(credential.account)
    }

    #if DEBUG
    /// Device-test escape hatch used only by an explicit launch argument. It
    /// clears Google Drive's local OAuth state without touching reading history
    /// or any other provider/account data.
    func resetLocalStateForDeviceTesting() async {
        epoch &+= 1
        authorizingEpoch = nil
        refreshOperation?.task.cancel()
        refreshOperation = nil
        stagedPick = nil
        candidateCredential = nil
        volatilePendingRevocations.removeAll()
        await webAuthenticator.cancel()
        await credentialStore.delete()
        try? await revocationStore.saveRecords([])
    }
    #endif

    // MARK: Persistent native-browser connection

    /// Restores only a credential that was granted the full read-only Drive
    /// scope. Legacy `drive.file` Picker grants are intentionally not treated
    /// as browser-capable because they cannot enumerate the user's Drive.
    func restorePersistedAccount(
        expectedAccountKey: String? = nil
    ) async throws -> CloudAccount {
        let valid = try await validBrowsingCredential(
            accountKey: expectedAccountKey
        )
        return valid.account
    }

    func ensureConnected() async throws -> CloudAccount {
        try await ensureConnected(
            expectedAccountKey: nil,
            forceAccountSelection: false
        )
    }

    /// Explicit connection entry point. Silent restoration is attempted first;
    /// OAuth is presented only when no browser-capable grant can be restored.
    func ensureConnected(
        expectedAccountKey: String? = nil,
        forceAccountSelection: Bool = false
    ) async throws -> CloudAccount {
        guard candidateCredential == nil else {
            throw CloudStorageError.accountMismatch
        }
        if !forceAccountSelection {
            do {
                return try await restorePersistedAccount(
                    expectedAccountKey: expectedAccountKey
                )
            } catch let error as CloudStorageError {
                switch error {
                case .needsReauthorization, .notConnected:
                    break
                default:
                    throw error
                }
            }
        }

        let prior = await credentialStore.load()
        let candidate: GoogleDriveCredential
        do {
            candidate = try await authorizeBrowsingCredential(
                forceAccountSelection: forceAccountSelection
            )
        } catch is CancellationError {
            throw CloudStorageError.userCancelled
        }

        let violatesExpectedOwner = expectedAccountKey.map {
            $0 != candidate.account.stableAccountKey
        } ?? false
        let replacesCurrentAccount = prior.map {
            $0.account.stableAccountKey != candidate.account.stableAccountKey
        } ?? false
        if violatesExpectedOwner || replacesCurrentAccount {
            candidateCredential = candidate
            throw CloudStorageError.accountMismatch
        }

        do {
            try await commitBrowsingCredential(candidate, replacing: prior)
            return candidate.account
        } catch {
            await revokeCredentialBestEffort(candidate)
            throw error
        }
    }

    /// Authorizes B without replacing the durable A credential. The caller must
    /// explicitly commit or discard after presenting account-switch UI.
    func stageAnotherAccount() async throws -> CloudAccount {
        let prior = try await restorePersistedAccount()
        if candidateCredential != nil { await discardCandidate() }
        let candidate: GoogleDriveCredential
        do {
            candidate = try await authorizeBrowsingCredential(
                forceAccountSelection: true
            )
        } catch is CancellationError {
            throw CloudStorageError.userCancelled
        }
        // The authorization helper never writes the candidate, so A remains
        // usable while the confirmation sheet is visible.
        guard (await credentialStore.load())?.account == prior else {
            await revokeCredentialBestEffort(candidate)
            throw CloudStorageError.staleSession
        }
        candidateCredential = candidate
        return candidate.account
    }

    func commitCandidate() async throws -> CloudAccount {
        guard let candidateCredential else {
            throw CloudStorageError.invalidResponse(
                code: "google_candidate_missing"
            )
        }
        let prior = await credentialStore.load()
        do {
            try await commitBrowsingCredential(
                candidateCredential,
                replacing: prior
            )
        } catch {
            self.candidateCredential = nil
            if prior?.account.stableAccountKey
                != candidateCredential.account.stableAccountKey {
                await revokeCredentialBestEffort(candidateCredential)
            }
            throw error
        }
        self.candidateCredential = nil
        if prior?.account.stableAccountKey
            != candidateCredential.account.stableAccountKey {
            await revokeCredentialBestEffort(prior)
        }
        return candidateCredential.account
    }

    func discardCandidate() async {
        guard let candidate = candidateCredential else { return }
        candidateCredential = nil
        let active = await credentialStore.load()
        // Google can bind multiple token strings to the same underlying grant.
        // Revoking a same-account candidate can invalidate active A as well.
        guard active?.account.stableAccountKey
                != candidate.account.stableAccountKey else {
            return
        }
        await revokeCredentialBestEffort(candidate)
    }

    func authorizeAndPick() async throws -> (account: CloudAccount, item: CloudItem) {
        let result: CloudAtomicPickResult
        do {
            result = try await performAuthorizeAndPick(preserveExistingAccount: false)
        } catch is CancellationError {
            throw CloudStorageError.userCancelled
        }
        return (result.account, result.item)
    }

    /// Normal app entry point. If Picker returns another Google account, keep
    /// A's Keychain credential active and hold B only in actor memory until the
    /// user explicitly confirms the account replacement.
    func authorizeAndPickPreservingExistingAccount(
        forceAccountSelection: Bool = false,
        expectedAccountKey: String? = nil
    ) async throws -> CloudAtomicPickResult {
        do {
            return try await performAuthorizeAndPick(
                preserveExistingAccount: true,
                forceAccountSelection: forceAccountSelection,
                expectedAccountKey: expectedAccountKey
            )
        } catch is CancellationError {
            throw CloudStorageError.userCancelled
        }
    }

    func commitStagedAccount() async throws -> (account: CloudAccount, item: CloudItem) {
        guard let stagedPick else {
            throw CloudStorageError.invalidResponse(code: "google_candidate_missing")
        }
        let operationEpoch = epoch
        let prior = await credentialStore.load()
        var commitEpoch: UInt64?
        do {
            let startedEpoch = try beginCredentialReplacement(expectedEpoch: operationEpoch)
            commitEpoch = startedEpoch
            guard try await credentialStore.replace(
                expected: prior,
                with: stagedPick.credential
            ) else {
                throw CloudStorageError.staleSession
            }
            try ensureCurrent(startedEpoch)
        } catch {
            await restoreCredentialAfterFailedReplacement(
                prior,
                attempted: stagedPick.credential,
                operationEpoch: commitEpoch ?? operationEpoch
            )
            throw error
        }
        await discardPendingRevocations(
            forAccountKey: stagedPick.credential.account.stableAccountKey
        )
        self.stagedPick = nil
        if prior?.account.stableAccountKey
            != stagedPick.credential.account.stableAccountKey {
            // B is already the durable local account. Revoking A is deliberately
            // best-effort so a provider/network failure cannot roll back the
            // completed account switch.
            await revokeCredentialBestEffort(prior)
        }
        return (stagedPick.credential.account, stagedPick.item)
    }

    func discardStagedAccount() async {
        let credential = stagedPick?.credential
        stagedPick = nil
        // The candidate was never made active locally, but its OAuth grant was
        // already issued. Canceling the switch should not leave that grant
        // behind. Failure is intentionally non-fatal because local state has
        // already returned to the prior account.
        await revokeCredentialBestEffort(credential)
    }

    /// Non-secret candidate projection used only to preserve or reconcile the
    /// app-level two-phase switch record. Credentials never leave this actor.
    func stagedCandidateAccount() -> CloudAccount? {
        candidateCredential?.account ?? stagedPick?.credential.account
    }

    private func revokeCredentialBestEffort(
        _ credential: GoogleDriveCredential?
    ) async {
        guard let token = credential?.refreshToken.nonEmpty
            ?? credential?.accessToken.nonEmpty else {
            return
        }

        do {
            var request = URLRequest(url: configuration.revokeEndpoint)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Self.formBody(["token": token])
            _ = try await transport.data(for: request)
        } catch {
            // Best-effort lifecycle cleanup. Local account state is authoritative
            // and must not be undone when the provider cannot be reached.
        }
    }

    private func performAuthorizeAndPick(
        preserveExistingAccount: Bool,
        forceAccountSelection: Bool = false,
        expectedAccountKey: String? = nil
    ) async throws -> CloudAtomicPickResult {
        try validateConfiguration()
        guard authorizingEpoch == nil else {
            throw CloudStorageError.provider(
                code: "google_authorization_in_progress",
                retryable: false
            )
        }

        let operationEpoch = epoch
        stagedPick = nil
        authorizingEpoch = operationEpoch
        defer {
            if authorizingEpoch == operationEpoch {
                authorizingEpoch = nil
            }
        }

        let verifier = Self.base64URL(try randomData(32))
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.base64URL(try randomData(24))
        let authorizationURL = try makeAuthorizationURL(
            challenge: challenge,
            state: state,
            forceAccountSelection: forceAccountSelection
        )

        let existing = await credentialStore.load()
        let callbackURL = try await webAuthenticator.authenticate(
            url: authorizationURL,
            callbackScheme: configuration.callbackScheme
        )
        try ensureCurrent(operationEpoch)

        let callback = try parsePickerCallback(callbackURL, expectedState: state)
        let token = try await exchangeAuthorizationCode(
            callback.code,
            verifier: verifier
        )
        var discoveredAccountKey: String?
        var transferredTokenOwnership = false
        do {
            try ensureCurrent(operationEpoch)

            let about = try await fetchAbout(accessToken: token.accessToken)
            let account = makeAccount(about.user)
            discoveredAccountKey = account.stableAccountKey
            let refreshToken: String
            if let received = token.refreshToken, !received.isEmpty {
                refreshToken = received
            } else if existing?.rawPermissionID == about.user.permissionID,
                      let saved = existing?.refreshToken,
                      !saved.isEmpty {
                refreshToken = saved
            } else {
                throw CloudStorageError.invalidResponse(
                    code: "google_missing_refresh_token"
                )
            }

            let metadata = try await fetchMetadata(
                fileID: callback.fileID,
                resourceKey: nil,
                accessToken: token.accessToken
            )
            let item = try makeCloudItem(metadata, account: account)
            let credential = GoogleDriveCredential(
                accessToken: token.accessToken,
                refreshToken: refreshToken,
                expiresAt: now().addingTimeInterval(TimeInterval(token.expiresIn)),
                account: account,
                rawPermissionID: about.user.permissionID,
                authorizedScopes: [Configuration.driveFileScope]
            )

            try ensureCurrent(operationEpoch)
            let violatesExpectedOwner = expectedAccountKey.map {
                $0 != account.stableAccountKey
            } ?? false
            let replacesCurrentAccount = existing.map {
                $0.account.stableAccountKey != account.stableAccountKey
            } ?? false
            // These are separate invariants: history must select its recorded A,
            // and replacing any currently active B still requires explicit B -> A
            // confirmation. Satisfying the history owner cannot bypass the switch
            // confirmation contract.
            if preserveExistingAccount, violatesExpectedOwner {
                // History explicitly requires A. If Picker returns the already
                // active B, staging B would later revoke B when the candidate is
                // discarded, potentially invalidating the still-active grant.
                // Throw first; transient cleanup deliberately preserves a grant
                // whose discovered owner matches the existing local account.
                throw CloudStorageError.accountMismatch
            }
            if preserveExistingAccount, replacesCurrentAccount {
                stagedPick = StagedPick(credential: credential, item: item)
                transferredTokenOwnership = true
                return CloudAtomicPickResult(
                    account: account,
                    item: item,
                    requiresAccountSwitchConfirmation: true
                )
            }
            var commitEpoch: UInt64?
            do {
                let startedEpoch = try beginCredentialReplacement(
                    expectedEpoch: operationEpoch
                )
                commitEpoch = startedEpoch
                guard try await credentialStore.replace(
                    expected: existing,
                    with: credential
                ) else {
                    throw CloudStorageError.staleSession
                }
                try ensureCurrent(startedEpoch)
            } catch {
                await restoreCredentialAfterFailedReplacement(
                    existing,
                    attempted: credential,
                    operationEpoch: commitEpoch ?? operationEpoch
                )
                throw error
            }
            await discardPendingRevocations(
                forAccountKey: credential.account.stableAccountKey
            )
            transferredTokenOwnership = true
            return CloudAtomicPickResult(
                account: account,
                item: item,
                requiresAccountSwitchConfirmation: false
            )
        } catch {
            if !transferredTokenOwnership {
                await revokeTransientAuthorizationBestEffort(
                    token,
                    discoveredAccountKey: discoveredAccountKey,
                    existing: existing
                )
            }
            throw error
        }
    }

    /// An authorization code exchange creates a provider-side grant before we
    /// can validate the selected account/file. Revoke an abandoned grant when
    /// it is safe to prove it is not the currently active account. If account
    /// discovery itself was cancelled while A is active, preserving A is safer
    /// than revoking an ambiguous Google grant.
    private func revokeTransientAuthorizationBestEffort(
        _ token: TokenValues,
        discoveredAccountKey: String?,
        existing: GoogleDriveCredential?
    ) async {
        if let existing {
            guard let discoveredAccountKey,
                  discoveredAccountKey != existing.account.stableAccountKey else {
                return
            }
        }
        guard let value = token.refreshToken?.nonEmpty
            ?? token.accessToken.nonEmpty else { return }

        let endpoint = configuration.revokeEndpoint
        let transport = self.transport
        // An unstructured cleanup task does not inherit cancellation from the
        // failed authorization task, so URLSession still gets one best-effort
        // chance to revoke the newly issued grant.
        let cleanup = Task {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue(
                    "application/x-www-form-urlencoded",
                    forHTTPHeaderField: "Content-Type"
                )
                request.httpBody = Self.formBody(["token": value])
                _ = try await transport.data(for: request)
            } catch {
                // The token was never persisted locally; provider cleanup is
                // deliberately best-effort and cannot roll back active A.
            }
        }
        _ = await cleanup.result
    }

    // MARK: Native file browser

    func listDrives() async throws -> [CloudDrive] {
        var credential = try await validBrowsingCredential()
        let operationEpoch = epoch
        var result = [CloudDrive(
            provider: .googleDrive,
            accountKey: credential.account.stableAccountKey,
            id: "root",
            name: CloudLocalized("我的云端硬盘"),
            isDefault: true
        )]
        var pageToken: String?
        var seenTokens = Set<String>()
        repeat {
            let url = try sharedDriveListURL(pageToken: pageToken)
            let response: DriveListResponse
            do {
                response = try await fetchDriveList(
                    url: url,
                    accessToken: credential.accessToken
                )
            } catch CloudStorageError.needsReauthorization {
                credential = try await refreshCredential(credential, force: true)
                response = try await fetchDriveList(
                    url: url,
                    accessToken: credential.accessToken
                )
            }
            try ensureCurrent(operationEpoch)
            result.append(contentsOf: response.drives.map {
                CloudDrive(
                    provider: .googleDrive,
                    accountKey: credential.account.stableAccountKey,
                    id: $0.id,
                    name: $0.name
                )
            })
            pageToken = response.nextPageToken?.nonEmpty
            if let pageToken, !seenTokens.insert(pageToken).inserted {
                throw CloudStorageError.invalidResponse(
                    code: "google_drive_page_token_loop"
                )
            }
        } while pageToken != nil
        return result
    }

    func list(folder: CloudFolder?, cursor: CloudCursor?) async throws -> CloudPage {
        let credential = try await validBrowsingCredential()
        try validateBrowserFolder(folder, account: credential.account)
        let operationEpoch = epoch
        let isRoot = folder == nil || folder?.id == "root"
        let isSharedWithMe = folder?.id == Self.sharedWithMeFolderID
        let query: String
        if isSharedWithMe {
            query = "sharedWithMe = true and trashed = false"
        } else {
            let selectedDriveID = folder?.driveID?.nonEmpty
            let isSharedDriveRoot = isRoot
                && selectedDriveID != nil
                && selectedDriveID != "root"
            query = Self.parentQuery(
                folderID: isSharedDriveRoot
                    ? selectedDriveID
                    : (isRoot ? nil : folder?.id)
            )
        }
        let response = try await fetchFileListWithAuthorizationRetry(
            query: query,
            cursor: cursor,
            driveID: folder?.driveID,
            initialCredential: credential
        )
        try ensureCurrent(operationEpoch)
        return makeBrowserPage(
            response,
            account: credential.account,
            includesSharedWithMeFolder: isRoot
                && cursor == nil
                && (folder?.driveID == nil || folder?.driveID == "root")
        )
    }

    func search(_ query: String, cursor: CloudCursor?) async throws -> CloudPage {
        try await search(query, driveID: nil, cursor: cursor)
    }

    func search(
        _ query: String,
        driveID: String?,
        cursor: CloudCursor?
    ) async throws -> CloudPage {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return CloudPage() }
        let credential = try await validBrowsingCredential()
        let operationEpoch = epoch
        let response = try await fetchFileListWithAuthorizationRetry(
            query: Self.searchQuery(trimmed),
            cursor: cursor,
            driveID: driveID,
            initialCredential: credential
        )
        try ensureCurrent(operationEpoch)
        return makeBrowserPage(
            response,
            account: credential.account,
            includesSharedWithMeFolder: false
        )
    }

    private func validateBrowserFolder(
        _ folder: CloudFolder?,
        account: CloudAccount
    ) throws {
        guard let folder else { return }
        guard folder.provider == .googleDrive else {
            throw CloudStorageError.unsupportedItem
        }
        guard folder.accountKey == account.stableAccountKey else {
            throw CloudStorageError.accountMismatch
        }
        guard folder.id.nonEmpty != nil else {
            throw CloudStorageError.invalidResponse(
                code: "google_folder_id_missing"
            )
        }
    }

    private func fetchFileListWithAuthorizationRetry(
        query: String,
        cursor: CloudCursor?,
        driveID: String?,
        initialCredential: GoogleDriveCredential
    ) async throws -> FileListResponse {
        let url = try fileListURL(
            query: query,
            cursor: cursor,
            driveID: driveID
        )
        do {
            return try await fetchFileList(
                url: url,
                accessToken: initialCredential.accessToken
            )
        } catch CloudStorageError.needsReauthorization {
            let refreshed = try await refreshCredential(
                initialCredential,
                force: true
            )
            return try await fetchFileList(
                url: url,
                accessToken: refreshed.accessToken
            )
        }
    }

    private func fetchFileList(
        url: URL,
        accessToken: String
    ) async throws -> FileListResponse {
        let data = try await authorizedData(
            URLRequest(url: url),
            accessToken: accessToken,
            resourceKeyHeader: nil
        )
        do {
            return try JSONDecoder().decode(FileListResponse.self, from: data)
        } catch {
            throw CloudStorageError.invalidResponse(
                code: "google_file_list_json"
            )
        }
    }

    private func fetchDriveList(
        url: URL,
        accessToken: String
    ) async throws -> DriveListResponse {
        let data = try await authorizedData(
            URLRequest(url: url),
            accessToken: accessToken,
            resourceKeyHeader: nil
        )
        do {
            return try JSONDecoder().decode(DriveListResponse.self, from: data)
        } catch {
            throw CloudStorageError.invalidResponse(
                code: "google_shared_drive_list_json"
            )
        }
    }

    private func makeBrowserPage(
        _ response: FileListResponse,
        account: CloudAccount,
        includesSharedWithMeFolder: Bool
    ) -> CloudPage {
        var folders: [CloudFolder] = []
        if includesSharedWithMeFolder {
            folders.append(CloudFolder(
                provider: .googleDrive,
                accountKey: account.stableAccountKey,
                id: Self.sharedWithMeFolderID,
                name: CloudLocalized("与我共享")
            ))
        }
        var items: [CloudItem] = []
        for metadata in response.files {
            if metadata.mimeType == Configuration.googleFolderMIMEType {
                folders.append(CloudFolder(
                    provider: .googleDrive,
                    accountKey: account.stableAccountKey,
                    driveID: metadata.driveID,
                    id: metadata.id,
                    name: metadata.name
                ))
            } else {
                items.append(makeListedCloudItem(metadata, account: account))
            }
        }
        return CloudPage(
            folders: folders,
            items: items,
            nextCursor: response.nextPageToken?.nonEmpty.map(CloudCursor.init(rawValue:))
        )
    }

    /// Browser pages intentionally retain unsupported files so the native list
    /// reflects the user's Drive. PDF, DOCX, EPUB and reflowable text files are
    /// downloaded directly; Google Docs export to DOCX, while Sheets, Slides
    /// and Drawings export to PDF and enter the same local reader pipeline.
    private func makeListedCloudItem(
        _ metadata: FileMetadata,
        account: CloudAccount
    ) -> CloudItem {
        let supportedFormat = Self.supportedFormat(
            mimeType: metadata.mimeType,
            filename: metadata.name
        )
        let kind: CloudItemKind
        let exportOptions = Self.exportOptions(
            forGoogleWorkspaceMIMEType: metadata.mimeType,
            // Listing is descriptive only. Permission and size are checked
            // again from fresh metadata after the user taps the row, so a
            // supported-but-blocked file can report the real policy error
            // instead of being mislabeled as an unsupported format.
            canDownload: true
        )
        if !exportOptions.isEmpty {
            kind = .exportableDocument
        } else if supportedFormat != nil {
            kind = .file
        } else {
            kind = .unsupported
        }
        return CloudItem(
            provider: .googleDrive,
            accountKey: account.stableAccountKey,
            driveID: metadata.driveID,
            id: metadata.id,
            name: metadata.name,
            mimeType: metadata.mimeType,
            size: metadata.size.flatMap(Int64.init),
            modifiedAt: Self.parseDate(metadata.modifiedTime),
            revision: Self.revision(for: metadata),
            resourceKey: metadata.resourceKey,
            kind: kind,
            exportOptions: exportOptions
        )
    }

    func download(
        _ item: CloudItem,
        exportFormat: CloudExportFormat?,
        to destination: URL,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> CloudDownloadReceipt {
        #if DEBUG
        print(
            "GoogleDriveDownload event=provider_enter "
                + "isFileURL=\(destination.isFileURL) "
                + "kind=\(String(describing: item.kind)) "
                + "mime=\(item.mimeType ?? "missing")"
        )
        #endif
        guard destination.isFileURL else {
            throw CloudStorageError.downloadNotAllowed
        }
        guard item.provider == .googleDrive else {
            throw CloudStorageError.unsupportedItem
        }

        let operationEpoch = epoch
        let initialCredential = try await validCredential(accountKey: item.accountKey)
        var metadata = try await fetchMetadataWithAuthorizationRetry(
            fileID: item.id,
            resourceKey: item.resourceKey,
            initialCredential: initialCredential
        )
        try ensureCurrent(operationEpoch)

        var temporaryURL: URL?
        defer {
            if let temporaryURL {
                try? FileManager.default.removeItem(at: temporaryURL)
            }
        }

        // A Drive file can be edited while it is being downloaded. Always
        // describe the bytes from fresh metadata and retry once if the remote
        // revision changes during transfer; never label old bytes as a newer
        // revision in history.
        for consistencyAttempt in 0...1 {
            guard metadata.id == item.id else {
                throw CloudStorageError.invalidResponse(
                    code: "google_metadata_id_mismatch"
                )
            }
            let canonicalItem = try makeCloudItem(
                metadata,
                account: initialCredential.account,
                fallbackResourceKey: item.resourceKey
            )
            let descriptor = try downloadDescriptor(
                for: canonicalItem,
                exportFormat: exportFormat
            )
            // Google Workspace exports do not expose the eventual byte count.
            // Use the export cap as a conservative estimate; ordinary files
            // use the fresh metadata size when available.
            let expectedBytes = descriptor.isExport
                ? descriptor.maximumBytes
                : canonicalItem.size ?? descriptor.maximumBytes
            try capacityPreflight(expectedBytes, destination)

            progress(
                CloudDownloadProgress(
                    completedBytes: 0,
                    totalBytes: canonicalItem.size
                )
            )
            temporaryURL = try await downloadWithAuthorizationRetry(
                item: canonicalItem,
                descriptor: descriptor,
                progress: progress
            )
            try ensureCurrent(operationEpoch)

            let finalCredential = try await validCredential(
                accountKey: item.accountKey
            )
            let finalMetadata = try await fetchMetadataWithAuthorizationRetry(
                fileID: item.id,
                resourceKey: canonicalItem.resourceKey ?? item.resourceKey,
                initialCredential: finalCredential
            )
            try ensureCurrent(operationEpoch)
            guard finalMetadata.id == item.id else {
                throw CloudStorageError.invalidResponse(
                    code: "google_metadata_id_mismatch"
                )
            }

            if Self.downloadIdentity(for: metadata)
                != Self.downloadIdentity(for: finalMetadata) {
                if let staleTemporaryURL = temporaryURL {
                    try? FileManager.default.removeItem(at: staleTemporaryURL)
                    temporaryURL = nil
                }
                guard consistencyAttempt == 0 else {
                    throw CloudStorageError.provider(
                        code: "google_file_changed_during_download",
                        retryable: true
                    )
                }
                metadata = finalMetadata
                continue
            }

            let finalItem = try makeCloudItem(
                finalMetadata,
                account: initialCredential.account,
                fallbackResourceKey: canonicalItem.resourceKey ?? item.resourceKey
            )
            let finalDescriptor = try downloadDescriptor(
                for: finalItem,
                exportFormat: exportFormat
            )
            guard let completedTemporaryURL = temporaryURL else {
                throw CloudStorageError.invalidResponse(
                    code: "google_missing_download_file"
                )
            }

            let byteCount = try Self.fileByteCount(completedTemporaryURL)
            guard byteCount <= finalDescriptor.maximumBytes else {
                throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
            }

            let parent = destination.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(
                at: completedTemporaryURL,
                to: destination
            )
            temporaryURL = nil
            progress(
                CloudDownloadProgress(
                    completedBytes: byteCount,
                    totalBytes: byteCount
                )
            )
            return CloudDownloadReceipt(
                localURL: destination,
                effectiveFilename: finalDescriptor.filename,
                effectiveMIMEType: finalDescriptor.mimeType,
                effectiveFormat: finalDescriptor.format,
                exportFormat: exportFormat,
                finalRevision: Self.revision(for: finalMetadata),
                byteCount: byteCount
            )
        }

        throw CloudStorageError.provider(
            code: "google_file_changed_during_download",
            retryable: true
        )
    }

    func disconnect() async -> CloudDisconnectResult {
        epoch &+= 1
        authorizingEpoch = nil
        let stagedCredential = stagedPick?.credential
        stagedPick = nil
        let browsingCandidate = candidateCredential
        candidateCredential = nil
        refreshOperation?.task.cancel()
        refreshOperation = nil
        await webAuthenticator.cancel()

        let credential = await credentialStore.load()
        var records = await pendingRevocations()
        if let credential,
           let token = credential.refreshToken.nonEmpty
            ?? credential.accessToken.nonEmpty {
            records.insert(GoogleDrivePendingRevocation(
                stableAccountKey: credential.account.stableAccountKey,
                token: token,
                disconnectedCredentialFingerprint:
                    Self.revocationCredentialFingerprint(credential)
            ))
        }
        if let stagedCredential,
           let token = stagedCredential.refreshToken.nonEmpty
            ?? stagedCredential.accessToken.nonEmpty {
            // A staged grant was never the durable local credential, so it has
            // no local-disconnect crash marker.
            records.insert(GoogleDrivePendingRevocation(
                stableAccountKey: stagedCredential.account.stableAccountKey,
                token: token,
                disconnectedCredentialFingerprint: nil
            ))
        }
        if let browsingCandidate,
           let token = browsingCandidate.refreshToken.nonEmpty
            ?? browsingCandidate.accessToken.nonEmpty {
            records.insert(GoogleDrivePendingRevocation(
                stableAccountKey: browsingCandidate.account.stableAccountKey,
                token: token,
                disconnectedCredentialFingerprint: nil
            ))
        }

        // Persist the disconnect intent before deleting the active credential.
        // A cold start can therefore finish cleanup without ever reconnecting A.
        volatilePendingRevocations = records
        try? await revocationStore.saveRecords(records)
        await credentialStore.delete()
        return await retryPendingRevocations()
    }

    /// Retries only revocation-only tokens; it can never restore Drive access.
    /// The UI exposes this after an unconfirmed disconnect and the same method
    /// works after a process restart because tokens live in a separate Keychain
    /// entry from the active credential.
    func retryPendingRevocations() async -> CloudDisconnectResult {
        let records = await pendingRevocations()
        guard !records.isEmpty else {
            return CloudDisconnectResult(
                provider: .googleDrive,
                remoteRevocationStatus: .confirmed
            )
        }

        var activeCredential = await credentialStore.load()
        if let active = activeCredential {
            let fingerprint = Self.revocationCredentialFingerprint(active)
            if records.contains(where: {
                $0.stableAccountKey == active.account.stableAccountKey
                    && $0.disconnectedCredentialFingerprint == fingerprint
            }) {
                // Complete a crash-interrupted local disconnect before making
                // any remote request. No pending record can reactivate access.
                await credentialStore.delete()
                self.epoch &+= 1
                self.refreshOperation?.task.cancel()
                self.refreshOperation = nil
                activeCredential = nil
            }
        }

        var remaining = Set<GoogleDrivePendingRevocation>()
        var isRetryable = false
        var diagnosticCode: String?
        for record in records {
            if let activeCredential,
               record.stableAccountKey == activeCredential.account.stableAccountKey {
                // A successful later authorization supersedes all cleanup for
                // this same account. Revoking an older refresh token may revoke
                // the replacement Google grant as well, so discard it locally.
                continue
            }

            let outcome = await revokeToken(record.token)
            guard !outcome.confirmed else { continue }
            remaining.insert(record)
            isRetryable = isRetryable || outcome.retryable
            diagnosticCode = diagnosticCode ?? outcome.diagnosticCode
        }

        volatilePendingRevocations = remaining
        do {
            try await revocationStore.saveRecords(remaining)
        } catch {
            // Retain process-local retry capability even if Keychain is
            // temporarily unavailable; never put the token back in active use.
            isRetryable = true
            diagnosticCode = diagnosticCode ?? "google_revocation_persistence"
        }

        return CloudDisconnectResult(
            provider: .googleDrive,
            remoteRevocationStatus: remaining.isEmpty ? .confirmed : .unconfirmed,
            retryable: !remaining.isEmpty && isRetryable,
            diagnosticCode: remaining.isEmpty ? nil : diagnosticCode
        )
    }

    private struct RevocationOutcome {
        let confirmed: Bool
        let retryable: Bool
        let diagnosticCode: String?
    }

    private func revokeToken(_ token: String) async -> RevocationOutcome {
        do {
            var request = URLRequest(url: configuration.revokeEndpoint)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Self.formBody(["token": token])
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return RevocationOutcome(
                    confirmed: false,
                    retryable: true,
                    diagnosticCode: "google_revoke_non_http"
                )
            }
            if (200..<300).contains(http.statusCode) {
                return RevocationOutcome(confirmed: true, retryable: false, diagnosticCode: nil)
            }
            // Google reports an already-invalid token as invalid_token. The
            // desired end state is already achieved, so no secret need remain.
            if http.statusCode == 400,
               (try? JSONDecoder().decode(OAuthErrorBody.self, from: data).error)
                    == "invalid_token" {
                return RevocationOutcome(confirmed: true, retryable: false, diagnosticCode: nil)
            }
            return RevocationOutcome(
                confirmed: false,
                retryable: http.statusCode == 429 || (500..<600).contains(http.statusCode),
                diagnosticCode: "google_revoke_http_\(http.statusCode)"
            )
        } catch {
            return RevocationOutcome(
                confirmed: false,
                retryable: true,
                diagnosticCode: "google_revoke_network"
            )
        }
    }

    private func pendingRevocations() async -> Set<GoogleDrivePendingRevocation> {
        (await revocationStore.loadRecords()).union(volatilePendingRevocations)
    }

    private func discardPendingRevocations(forAccountKey accountKey: String) async {
        let remaining = await pendingRevocations().filter {
            $0.stableAccountKey != accountKey
        }
        volatilePendingRevocations = Set(remaining)
        try? await revocationStore.saveRecords(Set(remaining))
    }

    /// Hashes the complete local credential generation, not only its account.
    /// A later OAuth grant for the same Google account therefore cannot satisfy
    /// an earlier crash marker and be deleted by `connectionState()`.
    nonisolated static func revocationCredentialFingerprint(
        _ credential: GoogleDriveCredential
    ) -> String {
        let material = [
            credential.account.stableAccountKey,
            credential.localGenerationID?.uuidString
                ?? "legacy:\(credential.accessToken):\(credential.refreshToken)",
        ].joined(separator: "\u{0}")
        return SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // MARK: OAuth

    private func authorizeBrowsingCredential(
        forceAccountSelection: Bool
    ) async throws -> GoogleDriveCredential {
        try validateConfiguration()
        guard authorizingEpoch == nil else {
            throw CloudStorageError.provider(
                code: "google_authorization_in_progress",
                retryable: false
            )
        }

        let operationEpoch = epoch
        authorizingEpoch = operationEpoch
        #if DEBUG
        print("GoogleDriveOAuth event=authorization_begin")
        #endif
        defer {
            if authorizingEpoch == operationEpoch { authorizingEpoch = nil }
        }

        let verifier = Self.base64URL(try randomData(32))
        let challenge = Self.codeChallenge(for: verifier)
        let state = Self.base64URL(try randomData(24))
        let authorizationURL = try makeBrowsingAuthorizationURL(
            challenge: challenge,
            state: state,
            forceAccountSelection: forceAccountSelection
        )
        let existing = await credentialStore.load()
        let callbackURL = try await webAuthenticator.authenticate(
            url: authorizationURL,
            callbackScheme: configuration.callbackScheme
        )
        try ensureCurrent(operationEpoch)
        #if DEBUG
        print("GoogleDriveOAuth event=authorization_callback_validating")
        #endif
        let code = try parseAuthorizationCallback(
            callbackURL,
            expectedState: state
        )
        #if DEBUG
        print("GoogleDriveOAuth event=token_exchange_begin")
        #endif
        let token = try await exchangeAuthorizationCode(code, verifier: verifier)
        var discoveredAccountKey: String?
        do {
            try ensureCurrent(operationEpoch)
            #if DEBUG
            print("GoogleDriveOAuth event=account_lookup_begin")
            #endif
            let about = try await fetchAbout(accessToken: token.accessToken)
            let account = makeAccount(about.user)
            discoveredAccountKey = account.stableAccountKey
            let refreshToken: String
            if let received = token.refreshToken?.nonEmpty {
                refreshToken = received
            } else if Self.hasReadonlyScope(existing?.authorizedScopes),
                      existing?.rawPermissionID == about.user.permissionID,
                      let saved = existing?.refreshToken.nonEmpty {
                refreshToken = saved
            } else {
                throw CloudStorageError.invalidResponse(
                    code: "google_missing_refresh_token"
                )
            }
            try ensureCurrent(operationEpoch)
            #if DEBUG
            print("GoogleDriveOAuth event=authorization_complete")
            #endif
            return GoogleDriveCredential(
                accessToken: token.accessToken,
                refreshToken: refreshToken,
                expiresAt: now().addingTimeInterval(TimeInterval(token.expiresIn)),
                account: account,
                rawPermissionID: about.user.permissionID,
                authorizedScopes: [Configuration.driveReadonlyScope]
            )
        } catch {
            await revokeTransientAuthorizationBestEffort(
                token,
                discoveredAccountKey: discoveredAccountKey,
                existing: existing
            )
            throw error
        }
    }

    private func commitBrowsingCredential(
        _ credential: GoogleDriveCredential,
        replacing prior: GoogleDriveCredential?
    ) async throws {
        let operationEpoch = epoch
        var commitEpoch: UInt64?
        do {
            let startedEpoch = try beginCredentialReplacement(
                expectedEpoch: operationEpoch
            )
            commitEpoch = startedEpoch
            guard try await credentialStore.replace(
                expected: prior,
                with: credential
            ) else {
                throw CloudStorageError.staleSession
            }
            try ensureCurrent(startedEpoch)
        } catch {
            await restoreCredentialAfterFailedReplacement(
                prior,
                attempted: credential,
                operationEpoch: commitEpoch ?? operationEpoch
            )
            throw error
        }
        await discardPendingRevocations(
            forAccountKey: credential.account.stableAccountKey
        )
    }

    /// Standard installed-app OAuth request for Drive browsing. No Google
    /// Picker parameters are present; file selection happens in-app afterward.
    func makeBrowsingAuthorizationURL(
        challenge: String,
        state: String,
        forceAccountSelection: Bool = false
    ) throws -> URL {
        var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Configuration.driveReadonlyScope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(
                name: "prompt",
                value: forceAccountSelection ? "select_account consent" : "consent"
            ),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else {
            throw CloudStorageError.invalidConfiguration(
                code: "google_authorization_url"
            )
        }
        return url
    }

    private func parseAuthorizationCallback(
        _ url: URL,
        expectedState: String
    ) throws -> String {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw CloudStorageError.invalidResponse(
                code: "google_callback_components"
            )
        }
        try validateCallbackRoute(components)
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }
        guard value("state") == expectedState else {
            throw CloudStorageError.invalidResponse(code: "google_state_mismatch")
        }
        if let error = value("error") {
            if error == "access_denied" { throw CloudStorageError.userCancelled }
            throw CloudStorageError.provider(
                code: "google_oauth_\(Self.safeErrorCode(error))",
                retryable: false
            )
        }
        if let returnedScope = value("scope") {
            let scopes = Set(
                returnedScope.split(whereSeparator: \.isWhitespace).map(String.init)
            )
            guard scopes == [Configuration.driveReadonlyScope] else {
                throw CloudStorageError.invalidResponse(
                    code: "google_scope_mismatch"
                )
            }
        }
        guard let code = value("code")?.nonEmpty else {
            throw CloudStorageError.invalidResponse(code: "google_missing_code")
        }
        return code
    }

    private func validateCallbackRoute(_ components: URLComponents) throws {
        guard let redirect = URLComponents(string: configuration.redirectURI),
              components.scheme?.lowercased()
                == configuration.callbackScheme.lowercased(),
              components.host?.lowercased() == redirect.host?.lowercased(),
              components.path == redirect.path else {
            throw CloudStorageError.invalidResponse(
                code: "google_callback_route_mismatch"
            )
        }
    }

    /// Legacy mobile Picker URL kept only for the old atomic API.
    func makeAuthorizationURL(
        challenge: String,
        state: String,
        forceAccountSelection: Bool = false
    ) throws -> URL {
        var components = URLComponents(
            url: configuration.authorizationEndpoint,
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Configuration.driveFileScope),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(
                name: "prompt",
                value: forceAccountSelection ? "select_account consent" : "consent"
            ),
            URLQueryItem(name: "trigger_onepick", value: "true"),
            URLQueryItem(name: "allow_multiple", value: "false"),
            URLQueryItem(name: "mimetypes", value: Self.pickerMIMETypes.joined(separator: ",")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
        ]
        guard let url = components?.url else {
            throw CloudStorageError.invalidConfiguration(
                code: "google_authorization_url"
            )
        }
        return url
    }

    private func parsePickerCallback(
        _ url: URL,
        expectedState: String
    ) throws -> (code: String, fileID: String) {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            throw CloudStorageError.invalidResponse(code: "google_callback_components")
        }
        try validateCallbackRoute(components)
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first(where: { $0.name == name })?.value
        }

        guard value("state") == expectedState else {
            throw CloudStorageError.invalidResponse(code: "google_state_mismatch")
        }
        if let error = value("error") {
            if error == "access_denied" { throw CloudStorageError.userCancelled }
            throw CloudStorageError.provider(
                code: "google_oauth_\(Self.safeErrorCode(error))",
                retryable: false
            )
        }
        if let returnedScope = value("scope") {
            let scopes = Set(returnedScope.split(whereSeparator: \.isWhitespace).map(String.init))
            guard scopes == [Configuration.driveFileScope] else {
                throw CloudStorageError.invalidResponse(code: "google_scope_mismatch")
            }
        }
        guard let code = value("code")?.nonEmpty else {
            throw CloudStorageError.invalidResponse(code: "google_missing_code")
        }
        let fileIDs = (value("picked_file_ids") ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard fileIDs.count == 1, let fileID = fileIDs.first else {
            throw CloudStorageError.invalidResponse(code: "google_invalid_pick_count")
        }
        return (code, fileID)
    }

    private func exchangeAuthorizationCode(
        _ code: String,
        verifier: String
    ) async throws -> TokenValues {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = Self.formBody([
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": configuration.redirectURI,
        ])
        return try await tokenValues(from: request)
    }

    private func tokenValues(from request: URLRequest) async throws -> TokenValues {
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudStorageError.invalidResponse(code: "google_token_non_http")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let oauthError = try? JSONDecoder().decode(OAuthErrorBody.self, from: data),
               oauthError.error == "invalid_grant" {
                throw CloudStorageError.needsReauthorization
            }
            throw CloudStorageError.provider(
                code: "google_token_http_\(http.statusCode)",
                retryable: (500..<600).contains(http.statusCode)
            )
        }
        let responseBody: TokenResponse
        do {
            responseBody = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw CloudStorageError.invalidResponse(code: "google_token_json")
        }
        guard let accessToken = responseBody.accessToken?.nonEmpty else {
            throw CloudStorageError.invalidResponse(code: "google_missing_access_token")
        }
        return TokenValues(
            accessToken: accessToken,
            refreshToken: responseBody.refreshToken?.nonEmpty,
            expiresIn: max(60, responseBody.expiresIn ?? 3_600)
        )
    }

    // MARK: Authorized API requests

    private func validBrowsingCredential(
        accountKey: String? = nil
    ) async throws -> GoogleDriveCredential {
        guard let saved = await credentialStore.load() else {
            throw CloudStorageError.needsReauthorization
        }
        guard Self.hasReadonlyScope(saved.authorizedScopes) else {
            throw CloudStorageError.needsReauthorization
        }
        if let accountKey,
           saved.account.stableAccountKey != accountKey {
            throw CloudStorageError.accountMismatch
        }
        return try await validCredential(accountKey: accountKey)
    }

    private func validCredential(accountKey: String? = nil) async throws -> GoogleDriveCredential {
        guard let credential = await credentialStore.load() else {
            throw CloudStorageError.notConnected
        }
        if let accountKey, credential.account.stableAccountKey != accountKey {
            throw CloudStorageError.accountMismatch
        }
        if credential.expiresAt > now().addingTimeInterval(60) {
            return credential
        }
        return try await refreshCredential(credential)
    }

    private func refreshCredential(
        _ source: GoogleDriveCredential,
        force: Bool = false
    ) async throws -> GoogleDriveCredential {
        if !force, source.expiresAt > now().addingTimeInterval(60) {
            return source
        }
        let operationEpoch = epoch
        if let operation = refreshOperation, operation.epoch == operationEpoch {
            let refreshed = try await operation.task.value
            try ensureCurrent(operationEpoch)
            return refreshed
        }

        let operationID = UUID()
        let configuration = configuration
        let transport = transport
        let now = now
        let task = Task<GoogleDriveCredential, Error> {
            var request = URLRequest(url: configuration.tokenEndpoint)
            request.httpMethod = "POST"
            request.setValue(
                "application/x-www-form-urlencoded",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = Self.formBody([
                "client_id": configuration.clientID,
                "grant_type": "refresh_token",
                "refresh_token": source.refreshToken,
            ])
            let (data, response) = try await transport.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CloudStorageError.invalidResponse(code: "google_refresh_non_http")
            }
            guard (200..<300).contains(http.statusCode) else {
                if let body = try? JSONDecoder().decode(OAuthErrorBody.self, from: data),
                   body.error == "invalid_grant" {
                    throw CloudStorageError.needsReauthorization
                }
                throw CloudStorageError.provider(
                    code: "google_refresh_http_\(http.statusCode)",
                    retryable: (500..<600).contains(http.statusCode)
                )
            }
            let decoded: TokenResponse
            do {
                decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
            } catch {
                throw CloudStorageError.invalidResponse(code: "google_refresh_json")
            }
            guard let accessToken = decoded.accessToken?.nonEmpty else {
                throw CloudStorageError.invalidResponse(
                    code: "google_refresh_missing_access_token"
                )
            }
            return GoogleDriveCredential(
                accessToken: accessToken,
                refreshToken: decoded.refreshToken?.nonEmpty ?? source.refreshToken,
                expiresAt: now().addingTimeInterval(
                    TimeInterval(max(60, decoded.expiresIn ?? 3_600))
                ),
                account: source.account,
                rawPermissionID: source.rawPermissionID,
                authorizedScopes: source.authorizedScopes,
                localGenerationID: source.localGenerationID
            )
        }
        refreshOperation = RefreshOperation(id: operationID, epoch: operationEpoch, task: task)

        do {
            let refreshed = try await task.value
            if refreshOperation?.id == operationID { refreshOperation = nil }
            try ensureCurrent(operationEpoch)
            guard try await credentialStore.replace(
                expected: source,
                with: refreshed
            ) else {
                throw CloudStorageError.staleSession
            }
            try ensureCurrent(operationEpoch)
            return refreshed
        } catch {
            if refreshOperation?.id == operationID { refreshOperation = nil }
            if error as? CloudStorageError == .needsReauthorization,
               epoch == operationEpoch {
                _ = try? await credentialStore.replace(expected: source, with: nil)
            }
            throw error
        }
    }

    private func fetchAbout(accessToken: String) async throws -> AboutResponse {
        let url = try apiURL(
            pathComponents: ["about"],
            queryItems: [
                URLQueryItem(
                    name: "fields",
                    value: "user(displayName,emailAddress,permissionId)"
                )
            ]
        )
        let data = try await authorizedData(
            URLRequest(url: url),
            accessToken: accessToken,
            resourceKeyHeader: nil
        )
        do {
            return try JSONDecoder().decode(AboutResponse.self, from: data)
        } catch {
            throw CloudStorageError.invalidResponse(code: "google_about_json")
        }
    }

    private func fetchMetadata(
        fileID: String,
        resourceKey: String?,
        accessToken: String
    ) async throws -> FileMetadata {
        let url = try metadataURL(fileID: fileID)
        let header = Self.resourceKeyHeader(fileID: fileID, resourceKey: resourceKey)
        let data = try await authorizedData(
            URLRequest(url: url),
            accessToken: accessToken,
            resourceKeyHeader: header
        )
        do {
            return try JSONDecoder().decode(FileMetadata.self, from: data)
        } catch {
            throw CloudStorageError.invalidResponse(code: "google_file_metadata_json")
        }
    }

    private func fetchMetadataWithAuthorizationRetry(
        fileID: String,
        resourceKey: String?,
        initialCredential: GoogleDriveCredential
    ) async throws -> FileMetadata {
        do {
            return try await fetchMetadata(
                fileID: fileID,
                resourceKey: resourceKey,
                accessToken: initialCredential.accessToken
            )
        } catch CloudStorageError.needsReauthorization {
            let refreshed = try await refreshCredential(initialCredential, force: true)
            return try await fetchMetadata(
                fileID: fileID,
                resourceKey: resourceKey,
                accessToken: refreshed.accessToken
            )
        }
    }

    private func authorizedData(
        _ baseRequest: URLRequest,
        accessToken: String,
        resourceKeyHeader: String?
    ) async throws -> Data {
        var request = baseRequest
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let resourceKeyHeader {
            request.setValue(
                resourceKeyHeader,
                forHTTPHeaderField: "X-Goog-Drive-Resource-Keys"
            )
        }

        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudStorageError.invalidResponse(code: "google_api_non_http")
        }
        if http.statusCode == 401 {
            throw CloudStorageError.needsReauthorization
        }
        try Self.validateAPIResponse(http, data: data)
        return data
    }

    private func downloadWithAuthorizationRetry(
        item: CloudItem,
        descriptor: DownloadDescriptor,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> URL {
        var credential = try await validCredential(accountKey: item.accountKey)
        for authorizationAttempt in 0...1 {
            let request = try makeDownloadRequest(
                item: item,
                descriptor: descriptor,
                accessToken: credential.accessToken
            )
            do {
                return try await performDownloadRequest(
                    request,
                    maximumBytes: descriptor.maximumBytes,
                    progress: progress
                )
            } catch CloudStorageError.needsReauthorization where authorizationAttempt == 0 {
                credential = try await refreshCredential(credential, force: true)
            }
        }
        throw CloudStorageError.needsReauthorization
    }

    private func performDownloadRequest(
        _ request: URLRequest,
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) async throws -> URL {
        var lastError: Error?
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let (temporaryURL, response) = try await transport.download(
                    for: request,
                    maximumBytes: maximumBytes,
                    progress: progress
                )
                guard let http = response as? HTTPURLResponse else {
                    try? FileManager.default.removeItem(at: temporaryURL)
                    throw CloudStorageError.invalidResponse(
                        code: "google_download_non_http"
                    )
                }
                if (200..<300).contains(http.statusCode) {
                    return temporaryURL
                }

                let body = (try? Data(contentsOf: temporaryURL)) ?? Data()
                try? FileManager.default.removeItem(at: temporaryURL)
                if http.statusCode == 401 {
                    throw CloudStorageError.needsReauthorization
                }
                if Self.isRetryableRateLimit(http, data: body) {
                    lastError = CloudStorageError.rateLimited(
                        retryAfterSeconds: Self.retryAfterSeconds(http)
                    )
                } else if (500..<600).contains(http.statusCode) {
                    lastError = CloudStorageError.provider(
                        code: "google_download_http_\(http.statusCode)",
                        retryable: true
                    )
                } else {
                    try Self.validateAPIResponse(http, data: body)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as DocumentImportError {
                throw error
            } catch CloudStorageError.needsReauthorization {
                throw CloudStorageError.needsReauthorization
            } catch let error as CloudStorageError {
                switch error {
                case .rateLimited, .network:
                    lastError = error
                case .provider(_, let retryable) where retryable:
                    lastError = error
                default:
                    throw error
                }
            } catch {
                let nsError = error as NSError
                guard nsError.domain == NSURLErrorDomain else { throw error }
                lastError = CloudStorageError.network(
                    code: "google_download_url_\(nsError.code)"
                )
            }

            if attempt < 2 {
                let retryAfter = (lastError as? CloudStorageError).flatMap { error -> Int? in
                    if case let .rateLimited(seconds) = error { return seconds }
                    return nil
                }
                let delay = retryAfter.map { UInt64(max(0, $0)) * 1_000_000_000 }
                    ?? UInt64(1 << attempt) * 1_000_000_000
                try await sleep(delay)
            }
        }
        throw lastError ?? CloudStorageError.network(code: "google_download_failed")
    }

    // MARK: Mapping and request construction

    private func makeAccount(_ user: AboutUser) -> CloudAccount {
        CloudAccount(
            provider: .googleDrive,
            stableAccountKey: CloudStableIdentifier.accountKey(
                provider: .googleDrive,
                rawAccountID: user.permissionID
            ),
            displayName: user.displayName?.nonEmpty,
            maskedEmail: Self.maskedEmail(user.emailAddress)
        )
    }

    private func makeCloudItem(
        _ metadata: FileMetadata,
        account: CloudAccount,
        fallbackResourceKey: String? = nil
    ) throws -> CloudItem {
        #if DEBUG
        let capability = metadata.capabilities?.canDownload.map(String.init) ?? "missing"
        print(
            "GoogleDriveDownload event=metadata_resolved "
                + "mime=\(metadata.mimeType) canDownload=\(capability)"
        )
        #endif
        // Do not turn the optional capability hint into a client-side hard
        // stop. The browser is intentionally an all-files view, and Drive has
        // returned blanket `false` capability values on the real account even
        // though its content endpoint is the authoritative permission check.
        // We therefore attempt the user-selected read/export below. A genuine
        // owner or administrator restriction is still enforced by Google and
        // mapped from the content endpoint's explicit 403 reason.
        guard metadata.mimeType != "application/vnd.google-apps.shortcut" else {
            throw CloudStorageError.unsupportedItem
        }
        let kind: CloudItemKind
        let exportOptions = Self.exportOptions(
            forGoogleWorkspaceMIMEType: metadata.mimeType,
            canDownload: true
        )
        if !exportOptions.isEmpty {
            kind = .exportableDocument
        } else if Self.supportedFormat(
            mimeType: metadata.mimeType,
            filename: metadata.name
        ) != nil {
            kind = .file
        } else {
            throw CloudStorageError.unsupportedItem
        }

        if kind == .file,
           let format = Self.supportedFormat(
               mimeType: metadata.mimeType,
               filename: metadata.name
           ),
           let size = metadata.size.flatMap(Int64.init),
           size > format.maximumInputBytes {
            throw DocumentImportError.resourceLimitExceeded(.inputFileTooLarge)
        }

        return CloudItem(
            provider: .googleDrive,
            accountKey: account.stableAccountKey,
            driveID: metadata.driveID,
            id: metadata.id,
            name: metadata.name,
            mimeType: metadata.mimeType,
            size: metadata.size.flatMap(Int64.init),
            modifiedAt: Self.parseDate(metadata.modifiedTime),
            revision: Self.revision(for: metadata),
            resourceKey: metadata.resourceKey ?? fallbackResourceKey,
            kind: kind,
            exportOptions: exportOptions
        )
    }

    private func downloadDescriptor(
        for item: CloudItem,
        exportFormat: CloudExportFormat?
    ) throws -> DownloadDescriptor {
        if item.kind == .exportableDocument
            || Self.isGoogleWorkspaceExportableMIMEType(item.mimeType) {
            guard let exportFormat,
                  item.exportOptions.contains(exportFormat) else {
                throw CloudStorageError.unsupportedExportFormat(exportFormat)
            }
            let fileExtension = exportFormat.rawValue
            let filename = item.name.lowercased().hasSuffix(".\(fileExtension)")
                ? item.name
                : item.name + ".\(fileExtension)"
            return DownloadDescriptor(
                isExport: true,
                filename: filename,
                mimeType: exportFormat.documentFormat.preferredMIMEType,
                format: exportFormat.documentFormat
            )
        }

        guard exportFormat == nil,
              let format = Self.supportedFormat(
                  mimeType: item.mimeType,
                  filename: item.name
              ) else {
            throw CloudStorageError.unsupportedExportFormat(exportFormat)
        }
        return DownloadDescriptor(
            isExport: false,
            filename: Self.normalizedDownloadFilename(
                item.name,
                format: format,
                mimeType: item.mimeType
            ),
            mimeType: item.mimeType ?? format.preferredMIMEType,
            format: format
        )
    }

    private func makeDownloadRequest(
        item: CloudItem,
        descriptor: DownloadDescriptor,
        accessToken: String
    ) throws -> URLRequest {
        let url: URL
        if descriptor.isExport {
            url = try apiURL(
                pathComponents: ["files", item.id, "export"],
                queryItems: [
                    URLQueryItem(name: "mimeType", value: descriptor.mimeType)
                ]
            )
        } else {
            url = try apiURL(
                pathComponents: ["files", item.id],
                queryItems: [
                    URLQueryItem(name: "alt", value: "media"),
                    URLQueryItem(name: "supportsAllDrives", value: "true"),
                ]
            )
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let resourceHeader = Self.resourceKeyHeader(
            fileID: item.id,
            resourceKey: item.resourceKey
        ) {
            request.setValue(
                resourceHeader,
                forHTTPHeaderField: "X-Goog-Drive-Resource-Keys"
            )
        }
        return request
    }

    private func fileListURL(
        query: String,
        cursor: CloudCursor?,
        driveID: String?
    ) throws -> URL {
        let sharedDriveID = driveID?.nonEmpty.flatMap { $0 == "root" ? nil : $0 }
        var queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "spaces", value: "drive"),
            URLQueryItem(
                name: "corpora",
                value: sharedDriveID == nil ? "user" : "drive"
            ),
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "orderBy", value: "folder,name_natural"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(
                    name: "fields",
                    value: [
                        "nextPageToken",
                        "files(id,name,mimeType,size,modifiedTime,version,driveId,resourceKey,shortcutDetails(targetId,targetMimeType,targetResourceKey))",
                    ].joined(separator: ",")
                ),
        ]
        if let sharedDriveID {
            queryItems.append(URLQueryItem(name: "driveId", value: sharedDriveID))
        }
        if let pageToken = cursor?.rawValue.nonEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        return try apiURL(pathComponents: ["files"], queryItems: queryItems)
    }

    private func sharedDriveListURL(pageToken: String?) throws -> URL {
        var queryItems = [
            URLQueryItem(name: "pageSize", value: "100"),
            URLQueryItem(name: "useDomainAdminAccess", value: "false"),
            URLQueryItem(name: "fields", value: "nextPageToken,drives(id,name)"),
        ]
        if let pageToken = pageToken?.nonEmpty {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        return try apiURL(pathComponents: ["drives"], queryItems: queryItems)
    }

    private func metadataURL(fileID: String) throws -> URL {
        try apiURL(
            pathComponents: ["files", fileID],
            queryItems: [
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(
                    name: "fields",
                    value: [
                        "id", "name", "mimeType", "size", "modifiedTime", "version",
                        "driveId", "resourceKey",
                        "shortcutDetails(targetId,targetMimeType,targetResourceKey)",
                    ].joined(separator: ",")
                ),
            ]
        )
    }

    private func apiURL(
        pathComponents: [String],
        queryItems: [URLQueryItem]
    ) throws -> URL {
        var url = configuration.driveAPIBaseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = queryItems
        guard let result = components?.url else {
            throw CloudStorageError.invalidConfiguration(code: "google_api_url")
        }
        return result
    }

    private func validateConfiguration() throws {
        guard configuration.clientID.nonEmpty != nil,
              configuration.redirectURI.nonEmpty != nil,
              configuration.callbackScheme.nonEmpty != nil,
              configuration.authorizationEndpoint.scheme == "https",
              configuration.tokenEndpoint.scheme == "https",
              configuration.revokeEndpoint.scheme == "https",
              configuration.driveAPIBaseURL.scheme == "https" else {
            throw CloudStorageError.invalidConfiguration(code: "google_oauth_config")
        }
        guard URL(string: configuration.redirectURI)?.scheme
                == configuration.callbackScheme else {
            throw CloudStorageError.invalidConfiguration(
                code: "google_redirect_scheme_mismatch"
            )
        }
    }

    private func ensureCurrent(_ operationEpoch: UInt64) throws {
        try Task.checkCancellation()
        guard operationEpoch == epoch else { throw CloudStorageError.staleSession }
    }

    /// Starts a compare-and-swap style credential commit. Any refresh or API
    /// work created from the previous credential generation becomes stale
    /// before the new token can be written, including same-account Picker
    /// reauthorization that rotates the refresh token.
    private func beginCredentialReplacement(expectedEpoch: UInt64) throws -> UInt64 {
        try ensureCurrent(expectedEpoch)
        epoch &+= 1
        refreshOperation?.task.cancel()
        refreshOperation = nil
        return epoch
    }

    private func restoreCredentialAfterFailedReplacement(
        _ prior: GoogleDriveCredential?,
        attempted: GoogleDriveCredential,
        operationEpoch: UInt64
    ) async {
        // A newer replacement or disconnect owns the durable credential now.
        // A stale completion must never delete/restore over that generation.
        guard operationEpoch == epoch else { return }
        _ = try? await credentialStore.replace(expected: attempted, with: prior)
    }
}

// MARK: - Wire types and pure helpers

extension GoogleDriveProvider {
    struct PickerCallback {
        let code: String
        let fileID: String
    }

    struct TokenValues {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
    }

    struct TokenResponse: Decodable {
        let accessToken: String?
        let refreshToken: String?
        let expiresIn: Int?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
        }
    }

    struct OAuthErrorBody: Decodable {
        let error: String
    }

    struct AboutResponse: Decodable {
        let user: AboutUser
    }

    struct AboutUser: Decodable {
        let displayName: String?
        let emailAddress: String?
        let permissionID: String

        enum CodingKeys: String, CodingKey {
            case displayName
            case emailAddress
            case permissionID = "permissionId"
        }
    }

    struct FileMetadata: Decodable {
        let id: String
        let name: String
        let mimeType: String
        let size: String?
        let modifiedTime: String?
        let version: String?
        let driveID: String?
        let resourceKey: String?
        let capabilities: Capabilities?
        let shortcutDetails: ShortcutDetails?

        enum CodingKeys: String, CodingKey {
            case id, name, mimeType, size, modifiedTime, version, resourceKey
            case driveID = "driveId"
            case capabilities, shortcutDetails
        }
    }

    struct FileListResponse: Decodable {
        let files: [FileMetadata]
        let nextPageToken: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            files = try container.decodeIfPresent(
                [FileMetadata].self,
                forKey: .files
            ) ?? []
            nextPageToken = try container.decodeIfPresent(
                String.self,
                forKey: .nextPageToken
            )
        }

        private enum CodingKeys: String, CodingKey {
            case files, nextPageToken
        }
    }

    struct DriveListResponse: Decodable {
        let drives: [DriveMetadata]
        let nextPageToken: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            drives = try container.decodeIfPresent(
                [DriveMetadata].self,
                forKey: .drives
            ) ?? []
            nextPageToken = try container.decodeIfPresent(
                String.self,
                forKey: .nextPageToken
            )
        }

        private enum CodingKeys: String, CodingKey {
            case drives, nextPageToken
        }
    }

    struct DriveMetadata: Decodable {
        let id: String
        let name: String
    }

    struct Capabilities: Decodable {
        let canDownload: Bool?
    }

    struct ShortcutDetails: Decodable {
        let targetID: String?
        let targetMimeType: String?
        let targetResourceKey: String?

        enum CodingKeys: String, CodingKey {
            case targetID = "targetId"
            case targetMimeType, targetResourceKey
        }
    }

    struct DownloadDescriptor {
        let isExport: Bool
        let filename: String
        let mimeType: String
        let format: SupportedDocumentFormat

        var maximumBytes: Int64 {
            // Drive's files.export response has a stricter 10 MiB ceiling.
            isExport
                ? min(format.maximumInputBytes, 10 * 1_024 * 1_024)
                : format.maximumInputBytes
        }
    }

    private struct DownloadIdentity: Equatable {
        let revision: String?
        let mimeType: String
        let size: String?
    }

    struct GoogleAPIErrorEnvelope: Decodable {
        let error: GoogleAPIError
    }

    struct GoogleAPIError: Decodable {
        let errors: [GoogleAPIErrorReason]?
    }

    struct GoogleAPIErrorReason: Decodable {
        let reason: String?
    }

    static let pickerMIMETypes = [
        SupportedDocumentFormat.pdf.preferredMIMEType,
        SupportedDocumentFormat.docx.preferredMIMEType,
        SupportedDocumentFormat.epub.preferredMIMEType,
        SupportedDocumentFormat.text.preferredMIMEType,
        "text/markdown",
        "application/rtf",
        Configuration.googleDocumentMIMEType,
    ]

    static func secureRandomData(_ byteCount: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw CloudStorageError.provider(
                code: "google_secure_random_failed",
                retryable: false
            )
        }
        return Data(bytes)
    }

    static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hasReadonlyScope(_ scopes: [String]?) -> Bool {
        scopes?.contains(Configuration.driveReadonlyScope) == true
    }

    static func parentQuery(folderID: String?) -> String {
        let parent = escapeDriveQueryLiteral(folderID?.nonEmpty ?? "root")
        return "'\(parent)' in parents and trashed = false"
    }

    static func searchQuery(_ query: String) -> String {
        let escaped = escapeDriveQueryLiteral(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return "name contains '\(escaped)' and trashed = false"
    }

    static func escapeDriveQueryLiteral(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
    }

    static func formBody(_ values: [String: String]) -> Data {
        values.keys.sorted().map { key in
            "\(formEncode(key))=\(formEncode(values[key] ?? ""))"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    /// Google Workspace-native files do not expose blob bytes through
    /// `alt=media`. Keep the supported export mapping in one place so the
    /// browser row and the fresh-metadata download gate cannot disagree.
    static func exportOptions(
        forGoogleWorkspaceMIMEType mimeType: String?,
        canDownload: Bool
    ) -> [CloudExportFormat] {
        guard canDownload else { return [] }
        switch mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case Configuration.googleDocumentMIMEType:
            return [.docx]
        case Configuration.googleSpreadsheetMIMEType,
             Configuration.googlePresentationMIMEType,
             Configuration.googleDrawingMIMEType:
            return [.pdf]
        default:
            return []
        }
    }

    static func isGoogleWorkspaceExportableMIMEType(_ mimeType: String?) -> Bool {
        !exportOptions(
            forGoogleWorkspaceMIMEType: mimeType,
            canDownload: true
        ).isEmpty
    }

    static func supportedFormat(
        mimeType: String?,
        filename: String
    ) -> SupportedDocumentFormat? {
        SupportedDocumentFormat.resolve(
            filename: filename,
            mimeType: mimeType
        )
    }

    static func normalizedDownloadFilename(
        _ filename: String,
        format: SupportedDocumentFormat,
        mimeType: String?
    ) -> String {
        SupportedDocumentFormat.normalizedFilename(
            filename,
            format: format,
            mimeType: mimeType
        )
    }

    static func revision(for metadata: FileMetadata) -> String? {
        let parts = [metadata.version?.nonEmpty, metadata.modifiedTime?.nonEmpty]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    private static func downloadIdentity(
        for metadata: FileMetadata
    ) -> DownloadIdentity {
        DownloadIdentity(
            revision: revision(for: metadata),
            mimeType: metadata.mimeType,
            size: metadata.size
        )
    }

    static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func maskedEmail(_ email: String?) -> String? {
        guard let email = email?.nonEmpty,
              let separator = email.firstIndex(of: "@") else {
            return nil
        }
        let local = email[..<separator]
        let domain = email[separator...]
        guard let first = local.first else { return "***\(domain)" }
        return "\(first)***\(domain)"
    }

    static func resourceKeyHeader(fileID: String, resourceKey: String?) -> String? {
        guard let resourceKey = resourceKey?.nonEmpty else { return nil }
        return "\(fileID)/\(resourceKey)"
    }

    static func validateAPIResponse(_ response: HTTPURLResponse, data: Data) throws {
        guard !(200..<300).contains(response.statusCode) else { return }
        if isRetryableRateLimit(response, data: data) {
            throw CloudStorageError.rateLimited(
                retryAfterSeconds: retryAfterSeconds(response)
            )
        }
        switch response.statusCode {
        case 401:
            throw CloudStorageError.needsReauthorization
        case 403:
            throw googleForbiddenError(data: data)
        case 404:
            throw CloudStorageError.itemUnavailable
        default:
            throw CloudStorageError.provider(
                code: "google_api_http_\(response.statusCode)",
                retryable: (500..<600).contains(response.statusCode)
            )
        }
    }

    static func googleForbiddenError(data: Data) -> CloudStorageError {
        let reasons = googleErrorReasons(data: data)
        let normalizedReasons = Set(reasons.map(normalizedGoogleReason))
        #if DEBUG
        print(
            "GoogleDriveDownload event=forbidden reasons="
                + normalizedReasons.sorted().joined(separator: ",")
        )
        #endif
        if !normalizedReasons.isDisjoint(with: [
            "downloadrestrictedforrevision", "cannotdownloadfile",
            "filenotdownloadable", "restrictedcontent",
        ]) {
            return .downloadNotAllowed
        }
        if normalizedReasons.contains("exportsizelimitexceeded") {
            return .provider(code: "google_export_size_limit", retryable: false)
        }
        if normalizedReasons.contains("domainpolicy") {
            return .provider(code: "google_domain_policy", retryable: false)
        }
        if normalizedReasons.contains("accessnotconfigured") {
            return .provider(code: "google_access_not_configured", retryable: false)
        }
        if normalizedReasons.contains("insufficientfilepermissions") {
            return .provider(
                code: "google_insufficient_file_permissions",
                retryable: false
            )
        }
        if normalizedReasons.contains("filenotexportable") {
            return .unsupportedItem
        }
        return .provider(code: "google_api_forbidden", retryable: false)
    }

    private static func googleErrorReasons(data: Data) -> Set<String> {
        guard let envelope = try? JSONDecoder().decode(
            GoogleAPIErrorEnvelope.self,
            from: data
        ) else {
            return []
        }
        return Set(envelope.error.errors?.compactMap(\.reason) ?? [])
    }

    private static func normalizedGoogleReason(_ value: String) -> String {
        String(value.unicodeScalars.filter(CharacterSet.alphanumerics.contains))
            .lowercased()
    }

    static func isRetryableRateLimit(
        _ response: HTTPURLResponse,
        data: Data
    ) -> Bool {
        if response.statusCode == 429 { return true }
        guard response.statusCode == 403 else { return false }
        let reasons = Set(googleErrorReasons(data: data).map(normalizedGoogleReason))
        return !reasons.isDisjoint(with: [
            "ratelimitexceeded", "userratelimitexceeded", "sharingratelimitexceeded",
        ])
    }

    static func retryAfterSeconds(_ response: HTTPURLResponse) -> Int? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        return Int(value)
    }

    static func fileByteCount(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    static func safeErrorCode(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let filtered = value.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(filtered)).prefix(40).lowercased()
    }
}

private final class GoogleDriveDownloadProgressDelegate: NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let progress: CloudDownloadProgressHandler
    private let maximumBytes: Int64
    private var didExceedLimit = false

    init(
        maximumBytes: Int64,
        progress: @escaping CloudDownloadProgressHandler
    ) {
        self.maximumBytes = maximumBytes
        self.progress = progress
    }

    var exceededLimit: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didExceedLimit
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if totalBytesWritten > maximumBytes
            || totalBytesExpectedToWrite > maximumBytes {
            lock.lock()
            didExceedLimit = true
            lock.unlock()
            downloadTask.cancel()
            return
        }
        progress(
            CloudDownloadProgress(
                completedBytes: totalBytesWritten,
                totalBytes: totalBytesExpectedToWrite > 0
                    ? totalBytesExpectedToWrite
                    : nil
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
