//
//  APIService.swift
//  CastReader
//

import Foundation

/// Keeps the cloned-voice request below the worker's JavaScript UTF-16 limit
/// without silently dropping the remainder. The server may split the submitted
/// chunk again, so its continuation must precede the local remainder.
enum ClonedTTSRequestChunker {
    struct Chunk: Equatable {
        let input: String
        let remainder: String
    }

    static func split(_ text: String, maxUTF16Length: Int) -> Chunk {
        guard maxUTF16Length > 0, text.utf16.count > maxUTF16Length else {
            return Chunk(input: text, remainder: "")
        }

        var end = text.startIndex
        var usedUTF16Units = 0
        while end < text.endIndex {
            let next = text.index(after: end)
            let characterUnits = text[end..<next].utf16.count
            guard usedUTF16Units + characterUnits <= maxUTF16Length else { break }
            usedUTF16Units += characterUnits
            end = next
        }

        // A normal speech character is always far smaller than the 600-unit
        // production limit. Keep this defensive fallback progress-safe.
        if end == text.startIndex {
            end = text.index(after: end)
        }
        return Chunk(
            input: String(text[..<end]),
            remainder: String(text[end...])
        )
    }

    static func appendingLocalRemainder(
        to response: TTSResponse,
        submittedInput: String,
        localRemainder: String
    ) -> TTSResponse {
        guard !localRemainder.isEmpty else { return response }
        let serverRemainder = response.unprocessedText?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let continuation = [serverRemainder, localRemainder]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return TTSResponse(
            audio: response.audio,
            audioFormat: response.audioFormat,
            timestamps: response.timestamps,
            duration: response.duration,
            processedText: response.processedText ?? submittedInput,
            unprocessedText: continuation
        )
    }
}

enum ClonedTTSRetryPolicy {
    static let delaysNanoseconds: [UInt64] = [
        350_000_000,
        900_000_000,
        1_800_000_000,
    ]

    static func isRetryable(_ error: Error) -> Bool {
        if let cloneError = error as? VoiceCloneError {
            switch cloneError {
            case .workerBusy, .temporaryUnavailable:
                return true
            default:
                return false
            }
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
        ].contains(urlError.code)
    }
}

private func apiDebugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}

enum APIError: Error, LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(Int)
    case decodingError(Error)
    case networkError(Error)
    case bookNotFound
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid response from server"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .decodingError(let error):
            return "Decoding error: \(error.localizedDescription)"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .bookNotFound:
            return "Book not available"
        case .serverError(let message):
            return message
        }
    }
}

enum PresetTTSFallbackPolicy {
    /// A single same-region retry is permitted only when the direct transport
    /// is unavailable or returns a server failure. Client/auth/rate-limit and
    /// decoding failures must not duplicate synthesis or bypass policy.
    static func shouldRetry(_ error: Error) -> Bool {
        if let apiError = error as? APIError,
           case .httpError(let status) = apiError {
            return (500..<600).contains(status)
        }
        guard let urlError = error as? URLError else { return false }
        return [
            .timedOut,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed,
            .networkConnectionLost,
            .notConnectedToInternet,
            .internationalRoamingOff,
            .callIsActive,
            .dataNotAllowed,
            .secureConnectionFailed,
            .serverCertificateUntrusted,
            .serverCertificateHasBadDate,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
        ].contains(urlError.code)
    }
}

actor APIService {
    static let shared = APIService()

    private let session: URLSession
    private let ttsSessions: [ServiceRoute: URLSession]
    private let cloneTTSSession: URLSession
    private let decoder: JSONDecoder
    private let mobileSessionProvider: any MobileSessionProviding

    private init() {
        // APIService APIs use explicit bearer credentials (or are intentionally
        // anonymous). Keep them isolated from Better Auth's shared cookie jar so
        // an account/route cookie can never shadow the request's explicit auth.
        self.session = OwnedAPIURLSession.makeExplicitCredentialSession(
            route: ServiceRouting.current,
            requestTimeout: 30,
            resourceTimeout: 60
        )
        self.ttsSessions = Dictionary(
            uniqueKeysWithValues: ServiceRoute.allCases.map { route in
                (
                    route,
                    OwnedAPIURLSession.makeExplicitCredentialSession(
                        route: route,
                        requestTimeout: 30,
                        resourceTimeout: 60
                    )
                )
            }
        )
        // Clone requests may spend a bounded amount of time in the single-GPU
        // scheduler. The generic 30-second session previously timed out before
        // a queued request could receive its first byte.
        self.cloneTTSSession = OwnedAPIURLSession.makeExplicitCredentialSession(
            route: ServiceRouting.current,
            requestTimeout: 75,
            resourceTimeout: 120
        )

        self.decoder = JSONDecoder()
        self.mobileSessionProvider = MobileSessionStore.shared
    }

    /// Test-only dependency seam used by transport-boundary contract tests.
    /// Production continues to use `shared` and the default pinned timeouts.
    init(
        session: URLSession,
        ttsSessions: [ServiceRoute: URLSession]? = nil,
        mobileSessionProvider: any MobileSessionProviding = MobileSessionStore.shared
    ) {
        self.session = session
        self.ttsSessions = ttsSessions ?? Dictionary(
            uniqueKeysWithValues: ServiceRoute.allCases.map { ($0, session) }
        )
        self.cloneTTSSession = session
        self.decoder = JSONDecoder()
        self.mobileSessionProvider = mobileSessionProvider
    }

    // MARK: - Generic Request

    private func request<T: Decodable>(
        _ url: URL,
        method: String = "GET",
        body: Data? = nil,
        session requestSession: URLSession? = nil,
        headers: [String: String] = [:]
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }

        if let body = body {
            request.httpBody = body
        }

        let (data, response) = try await (requestSession ?? session).data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            // Print error response body for debugging
            if let errorBody = String(data: data, encoding: .utf8) {
                apiDebugLog("🔴 [API] HTTP \(httpResponse.statusCode) error response: \(errorBody)")
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            // Debug: print raw response and detailed error
            if let jsonString = String(data: data, encoding: .utf8) {
                apiDebugLog("🔴 Decoding failed. Raw response: \(String(jsonString.prefix(1500)))")
            }
            apiDebugLog("🔴 Decoding error details: \(error)")
            throw APIError.decodingError(error)
        }
    }


    // MARK: - Library API

    func fetchDocuments(limit: Int = 100, offset: Int = 0) async throws -> [Document] {
        var components = URLComponents(string: Constants.API.documents)
        components?.queryItems = [
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "offset", value: "\(offset)")
        ]

        guard let url = components?.url else {
            throw APIError.invalidURL
        }

        return try await fetchDocuments(
            url: url,
            suppliedToken: nil,
            canRefreshSession: true
        )
    }

    /// Document ownership is an authenticated server concern.  In particular,
    /// this method never accepts a caller-provided user/device/email identifier
    /// and never falls back to the released-client compatibility endpoint.
    private func fetchDocuments(
        url: URL,
        suppliedToken: String?,
        canRefreshSession: Bool
    ) async throws -> [Document] {
        var token: String?
        if let suppliedToken {
            token = suppliedToken
        } else {
            token = await mobileSessionProvider.sessionToken()
        }
        if !Self.isValidMobileSession(token), canRefreshSession {
            token = await mobileSessionProvider.refreshSession()
        }
        guard let token, Self.isValidMobileSession(token) else {
            await mobileSessionProvider.rejectSession(nil)
            throw APIError.httpError(401)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            if canRefreshSession,
               let refreshed = await mobileSessionProvider.refreshSession(),
               Self.isValidMobileSession(refreshed) {
                return try await fetchDocuments(
                    url: url,
                    suppliedToken: refreshed,
                    canRefreshSession: false
                )
            }
            await mobileSessionProvider.rejectSession(token)
            throw APIError.httpError(401)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        do {
            let payload = try decoder.decode(DocumentListResponse.self, from: data)
            return payload.documents ?? []
        } catch {
            // A protected library response may contain private titles and URLs;
            // do not emit the raw body into device logs on decode failure.
            throw APIError.decodingError(error)
        }
    }

    // MARK: - Upload API

    func fetchSTSCredentials() async throws -> STSCredentials {
        guard let url = URL(string: Constants.API.sts) else {
            throw APIError.invalidURL
        }

        return try await fetchSTSCredentials(
            url: url,
            suppliedToken: nil,
            canRefreshSession: true
        )
    }

    /// The protected mobile STS endpoint is deliberately separate from the
    /// generic request helper: it must never make an anonymous request or fall
    /// back to the historical `/sts` compatibility endpoint.
    private func fetchSTSCredentials(
        url: URL,
        suppliedToken: String?,
        canRefreshSession: Bool
    ) async throws -> STSCredentials {
        var token: String?
        if let suppliedToken {
            token = suppliedToken
        } else {
            token = await mobileSessionProvider.sessionToken()
        }
        if !Self.isValidMobileSession(token), canRefreshSession {
            token = await mobileSessionProvider.refreshSession()
        }
        guard let token, Self.isValidMobileSession(token) else {
            await mobileSessionProvider.rejectSession(nil)
            throw APIError.httpError(401)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if httpResponse.statusCode == 401 {
            if canRefreshSession,
               let refreshed = await mobileSessionProvider.refreshSession(),
               Self.isValidMobileSession(refreshed) {
                return try await fetchSTSCredentials(
                    url: url,
                    suppliedToken: refreshed,
                    canRefreshSession: false
                )
            }
            await mobileSessionProvider.rejectSession(token)
            throw APIError.httpError(401)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            throw APIError.httpError(httpResponse.statusCode)
        }

        let payload: STSResponse
        do {
            payload = try decoder.decode(STSResponse.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
        guard let sts = payload.sts else {
            throw APIError.invalidResponse
        }
        return sts
    }

    private static func isValidMobileSession(_ token: String?) -> Bool {
        guard let token else { return false }
        return MobileSessionStore.isServerSessionToken(token)
    }

    func notifyUpload(
        filename: String,
        filepath: String,
        voiceId: String? = nil
    ) async throws -> UploadResponse {
        guard let url = URL(string: Constants.API.asyncUpload) else {
            throw APIError.invalidURL
        }
        guard !filename.trimmed.isEmpty, !filepath.trimmed.isEmpty else {
            throw APIError.invalidResponse
        }

        apiDebugLog("📤 [API] notifyUpload URL: \(url)")
        let resolvedVoice = VoiceCatalog.resolvedVoice(
            preferred: voiceId ?? "",
            for: Constants.TTS.defaultLanguage
        )
        apiDebugLog("📤 [API] notifyUpload params: filename=\(filename), voice_id=\(resolvedVoice)")

        // Use multipart/form-data format (same as web)
        let boundary = "Boundary-\(UUID().uuidString)"
        var bodyData = Data()

        // Helper to append form field
        func appendFormField(name: String, value: String) {
            bodyData.append("--\(boundary)\r\n".data(using: .utf8)!)
            bodyData.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            bodyData.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendFormField(name: "filename", value: filename)
        appendFormField(name: "filepath", value: filepath)
        appendFormField(name: "voice_id", value: resolvedVoice)

        bodyData.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return try await notifyUpload(
            url: url,
            boundary: boundary,
            bodyData: bodyData,
            suppliedToken: nil,
            canRefreshSession: true
        )
    }

    private func notifyUpload(
        url: URL,
        boundary: String,
        bodyData: Data,
        suppliedToken: String?,
        canRefreshSession: Bool
    ) async throws -> UploadResponse {
        var token: String?
        if let suppliedToken {
            token = suppliedToken
        } else {
            token = await mobileSessionProvider.sessionToken()
        }
        if !Self.isValidMobileSession(token), canRefreshSession {
            token = await mobileSessionProvider.refreshSession()
        }
        guard let token, Self.isValidMobileSession(token) else {
            await mobileSessionProvider.rejectSession(nil)
            throw APIError.httpError(401)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        request.httpBody = bodyData

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        if httpResponse.statusCode == 401 {
            if canRefreshSession,
               let refreshed = await mobileSessionProvider.refreshSession(),
               Self.isValidMobileSession(refreshed) {
                return try await notifyUpload(
                    url: url,
                    boundary: boundary,
                    bodyData: bodyData,
                    suppliedToken: refreshed,
                    canRefreshSession: false
                )
            }
            await mobileSessionProvider.rejectSession(token)
            throw APIError.httpError(401)
        }
        guard 200..<300 ~= httpResponse.statusCode else {
            if let errorBody = String(data: data, encoding: .utf8) {
                apiDebugLog("🔴 [API] HTTP \(httpResponse.statusCode) error response: \(errorBody)")
            }
            throw APIError.httpError(httpResponse.statusCode)
        }

        do {
            return try decoder.decode(UploadResponse.self, from: data)
        } catch {
            if let jsonString = String(data: data, encoding: .utf8) {
                apiDebugLog("🔴 [API] Decoding failed. Raw response: \(String(jsonString.prefix(1500)))")
            }
            apiDebugLog("🔴 [API] Decoding error details: \(error)")
            throw APIError.decodingError(error)
        }
    }


    /// Fetch Markdown content from URL
    func fetchMarkdownContent(url urlString: String) async throws -> String {
        // URL encode to handle spaces and special characters
        guard let encoded = urlString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let decodedURL = URL(string: encoded),
              let contentURL = OwnedAPIRedirectPolicy.routedResponseURL(decodedURL) else {
            throw APIError.invalidURL
        }

        let (data, response) = try await session.data(from: contentURL)

        guard let httpResponse = response as? HTTPURLResponse,
              200..<300 ~= httpResponse.statusCode else {
            throw APIError.invalidResponse
        }

        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - TTS API

    func generateTTS(
        text: String,
        voice: String? = nil,
        speed: Double = Constants.TTS.defaultSpeed,
        language: String = Constants.TTS.defaultLanguage,
        includeVoiceCode: Bool = true,
        priority: TTSRequestPriority = .interactive,
        requestID: String? = nil
    ) async throws -> TTSResponse {
        // Compute locality is independent from the account/content route. TTS
        // is anonymous, so a mainland user may use the filed CN compute ingress
        // without moving or exposing the account's cms_ session.
        let sanitized = SpeechTextSanitizer.sanitizedForTTS(text)
        guard SpeechTextSanitizer.containsSpeakableContent(sanitized) else {
            throw APIError.serverError("No speakable text for TTS")
        }
        let canonicalLanguage = SupportedTTSLanguage.canonicalCode(language)
        let requestedVoice = voice ?? ""
        let featureSafeVoice = !Constants.Features.voiceCloningEnabled && requestedVoice.hasPrefix("vc_")
            ? ""
            : requestedVoice
        let resolvedVoice = VoiceCatalog.resolvedVoice(
            preferred: featureSafeVoice,
            for: canonicalLanguage
        )
        // Clone compatibility endpoint accepts at most 600 JavaScript UTF-16
        // units. Preserve the local tail and append it to the server's own
        // continuation so a long paragraph is never silently truncated.
        let isClonedVoice = resolvedVoice.hasPrefix("vc_")
        let requestChunk = isClonedVoice
            ? ClonedTTSRequestChunker.split(sanitized, maxUTF16Length: 600)
            : ClonedTTSRequestChunker.Chunk(input: sanitized, remainder: "")
        let inputText = requestChunk.input
        let ttsRequest = TTSRequest(
            input: inputText,
            voice: resolvedVoice,
            speed: speed,
            language: canonicalLanguage,
            includeVoiceCode: includeVoiceCode
        )
        let bodyData = try JSONEncoder().encode(ttsRequest)
        apiDebugLog("[TTSRoute] language=\(canonicalLanguage) voice=\(resolvedVoice) clone=\(resolvedVoice.hasPrefix("vc_") ? "Y" : "N")")

        if isClonedVoice {
            // Clone synthesis stays on the authenticated account gateway. The
            // gateway owns compute authorization and returns the same captioned
            // JSON contract as preset voices.
            let response = try await requestClonedVoiceTTS(
                body: bodyData,
                voiceID: resolvedVoice,
                priority: priority,
                requestID: requestID ?? UUID().uuidString
            )
            return ClonedTTSRequestChunker.appendingLocalRemainder(
                to: response,
                submittedInput: inputText,
                localRemainder: requestChunk.remainder
            )
        }

        let route = ComputeRouting.current
        let isMainlandChina = route == .chinaGateway
        let primaryBase = TTSEndpoint.primaryBase(isMainlandChina: isMainlandChina)
        let transportHeaders = [
            "X-CastReader-Platform": "ios",
            "X-CastReader-Version": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "unknown",
        ]
        guard let url = URL(string: TTSEndpoint.partlyURL(base: primaryBase)) else {
            throw APIError.invalidURL
        }
        do {
            return try await request(
                url,
                method: "POST",
                body: bodyData,
                session: ttsSessions[route],
                headers: transportHeaders
            )
        } catch {
            guard PresetTTSFallbackPolicy.shouldRetry(error),
                  let fallbackBase = TTSEndpoint.fallbackBase(
                    isMainlandChina: isMainlandChina
                  ),
                  fallbackBase != primaryBase,
                  let fallbackURL = URL(
                    string: TTSEndpoint.partlyURL(base: fallbackBase)
                  ) else {
                throw error
            }
            apiDebugLog(
                "[TTSRoute] same-region fallback \(url.host ?? "?") → " +
                "\(fallbackURL.host ?? "?")"
            )
            return try await request(
                fallbackURL,
                method: "POST",
                body: bodyData,
                session: ttsSessions[route],
                headers: transportHeaders
            )
        }
    }

    private func requestClonedVoiceTTS(
        body: Data,
        voiceID: String,
        priority: TTSRequestPriority,
        requestID: String = UUID().uuidString,
        canRefresh: Bool = true,
        transientAttempt: Int = 0
    ) async throws -> TTSResponse {
        // Authentication is the first hard boundary for cloned-voice compute.
        // This also guarantees that a stale locally selected clone can never
        // fall through to the anonymous preset-voice endpoint.
        guard let token = await MobileSessionStore.shared.sessionToken(), !token.isEmpty else {
            await MobileSessionStore.shared.rejectSession(nil)
            await MainActor.run { VoiceCloneAccessCoordinator.shared.prompt = .signIn }
            throw VoiceCloneError.sessionUnavailable
        }
        let accessState = await MainActor.run {
            (
                isPro: ProManager.shared.isPro,
                canApply: VoiceCloneStore.shared.canApply,
                blocked: VoiceCloneStore.shared.isQuotaBlocked,
                resetAt: VoiceCloneStore.shared.capability.resetAt
            )
        }
        if !accessState.isPro {
            await MainActor.run {
                VoiceCloneAccessCoordinator.shared.prompt = .paywall
            }
            throw VoiceCloneError.proRequired
        }
        if accessState.blocked {
            let error = VoiceCloneError.quotaExhausted(accessState.resetAt)
            await MainActor.run {
                VoiceCloneAccessCoordinator.shared.prompt = .message(error.localizedDescription)
            }
            throw error
        }
        if !accessState.canApply {
            await MainActor.run {
                VoiceCloneAccessCoordinator.shared.prompt = .message(
                    AppLocalized("Pro 权益正在同步，请稍后重试")
                )
            }
            throw VoiceCloneError.proRequired
        }
        guard let url = URL(string: Constants.API.tts) else { throw APIError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        request.setValue(priority.rawValue, forHTTPHeaderField: "X-TTS-Priority")
        request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await cloneTTSSession.data(for: request)
        } catch {
            if let retry = try await retryClonedVoiceTTSIfNeeded(
                error: error,
                body: body,
                voiceID: voiceID,
                priority: priority,
                requestID: requestID,
                canRefresh: canRefresh,
                transientAttempt: transientAttempt
            ) {
                return retry
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        if http.statusCode == 401, canRefresh,
           await MobileSessionStore.shared.refreshSession() != nil {
            return try await requestClonedVoiceTTS(
                body: body,
                voiceID: voiceID,
                priority: priority,
                requestID: requestID,
                canRefresh: false,
                transientAttempt: transientAttempt
            )
        }
        let responseRequestID = http.value(forHTTPHeaderField: "X-Request-ID")
            ?? requestID
        let quotaMode = http.value(forHTTPHeaderField: "X-Clone-Quota-Mode")
            ?? "unknown"
        ReaderRunLog.write(
            "TTS clone response request=\(responseRequestID) " +
            "status=\(http.statusCode) quota=\(quotaMode) attempt=\(transientAttempt + 1)"
        )
        await MainActor.run {
            VoiceCloneStore.shared.applyQuotaHeaders(http)
        }
        guard 200..<300 ~= http.statusCode else {
            let code = VoiceCloneResponseParser.serverCode(from: data)?.uppercased()
            let message = VoiceCloneResponseParser.serverMessage(from: data)
            if code == "CLONE_QUOTA_EXHAUSTED" {
                let resetAt = VoiceCloneResponseParser.quotaResetAt(from: data)
                    ?? VoiceCloneResponseParser.quotaCapability(from: http).resetAt
                let error = VoiceCloneError.quotaExhausted(resetAt)
                await MainActor.run {
                    VoiceCloneStore.shared.markQuotaExhausted(resetAt: resetAt)
                    VoiceCloneAccessCoordinator.shared.prompt = .message(error.localizedDescription)
                }
                throw error
            }
            switch http.statusCode {
            case 401:
                await MobileSessionStore.shared.rejectSession(token)
                await MainActor.run { VoiceCloneAccessCoordinator.shared.prompt = .signIn }
                throw VoiceCloneError.sessionUnavailable
            case 403:
                await MainActor.run {
                    if ProManager.shared.isPro {
                        VoiceCloneAccessCoordinator.shared.prompt = .message(
                            message ?? AppLocalized("Pro 权益正在同步，请稍后重试")
                        )
                    } else {
                        VoiceCloneAccessCoordinator.shared.prompt = .paywall
                    }
                }
                throw VoiceCloneError.proRequired
            case 404:
                await MainActor.run { AppSettings.shared.clearActiveClonedVoice(ifMatching: voiceID) }
                throw VoiceCloneError.voiceNotFound
            case 429 where ["CLONE_WORKER_BUSY", "VOICE_WORKER_BUSY"].contains(code ?? ""):
                let error = VoiceCloneError.workerBusy(message)
                if let retry = try await retryClonedVoiceTTSIfNeeded(
                    error: error,
                    body: body,
                    voiceID: voiceID,
                    priority: priority,
                    requestID: requestID,
                    canRefresh: canRefresh,
                    transientAttempt: transientAttempt
                ) {
                    return retry
                }
                throw error
            case 503:
                let error = VoiceCloneError.temporaryUnavailable
                if let retry = try await retryClonedVoiceTTSIfNeeded(
                    error: error,
                    body: body,
                    voiceID: voiceID,
                    priority: priority,
                    requestID: requestID,
                    canRefresh: canRefresh,
                    transientAttempt: transientAttempt
                ) {
                    return retry
                }
                throw error
            default:
                throw VoiceCloneError.server(http.statusCode, message)
            }
        }
        do {
            return try decoder.decode(TTSResponse.self, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func retryClonedVoiceTTSIfNeeded(
        error: Error,
        body: Data,
        voiceID: String,
        priority: TTSRequestPriority,
        requestID: String,
        canRefresh: Bool,
        transientAttempt: Int
    ) async throws -> TTSResponse? {
        let delays = ClonedTTSRetryPolicy.delaysNanoseconds
        guard transientAttempt < delays.count,
              ClonedTTSRetryPolicy.isRetryable(error) else { return nil }
        let nextAttempt = transientAttempt + 1
        ReaderRunLog.write(
            "TTS clone retry request=\(requestID) " +
            "next=\(nextAttempt + 1) error=\(error.localizedDescription)"
        )
        try await Task.sleep(nanoseconds: delays[transientAttempt])
        try Task.checkCancellation()
        return try await requestClonedVoiceTTS(
            body: body,
            voiceID: voiceID,
            priority: priority,
            requestID: requestID,
            canRefresh: canRefresh,
            transientAttempt: nextAttempt
        )
    }

}
