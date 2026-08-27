import Foundation
import Combine
import AVFoundation
import CommonCrypto

enum VoiceCloneReferenceTransport {
    static func usesDirectCOSUpload(for route: ServiceRoute) -> Bool {
        route == .chinaGateway
    }
}

enum VoiceCloneEndpoint {
    static func previewPath(for voiceID: String) -> String? {
        guard voiceID.hasPrefix("vc_"),
              let encoded = voiceID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return "/api/voice-clone/voices/\(encoded)/preview"
    }
}

actor VoiceCloneService {
    static let shared = VoiceCloneService(sessionProvider: MobileSessionStore.shared)

    private let baseURL: URL
    private let session: URLSession
    private let sessionProvider: any MobileSessionProviding
    private let route: ServiceRoute

    init(
        baseURL: URL? = nil,
        session: URLSession? = nil,
        route: ServiceRoute = ServiceRouting.current,
        sessionProvider: any MobileSessionProviding
    ) {
        self.baseURL = baseURL
            ?? URL(string: route.webBaseURL)
            ?? URL(string: ServiceRoute.globalGateway.apiGatewayBaseURL)!
        self.session = session ?? OwnedAPIURLSession.make(route: route)
        self.route = route
        self.sessionProvider = sessionProvider
    }

    func hasSession() async -> Bool {
        guard Constants.Features.voiceCloningEnabled else { return false }
        return await sessionProvider.sessionToken() != nil
    }

    func listVoices() async throws -> VoiceCloneListResult {
        let data = try await perform(path: "/api/voice-clone/voices", method: "GET")
        return try VoiceCloneResponseParser.list(from: data)
    }

    func createVoice(
        recordingURL: URL,
        referenceLanguage: String,
        referenceText: String,
        consentConfirmed: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ClonedVoice {
        guard Constants.Features.voiceCloningEnabled else {
            throw VoiceCloneError.temporaryUnavailable
        }
        guard consentConfirmed else {
            throw VoiceCloneError.invalidRecording(AppLocalized("请先确认声音授权"))
        }
        let spokenText = referenceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spokenText.isEmpty, spokenText.count <= 600 else {
            throw VoiceCloneError.invalidRecording(AppLocalized("朗读文本无效，请重新录制"))
        }
        let values = try recordingURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= 4 * 1024 * 1024 else {
            throw VoiceCloneError.invalidRecording(AppLocalized("录音文件必须不超过 4 MB"))
        }
        let reference = try Data(contentsOf: recordingURL)
        if VoiceCloneReferenceTransport.usesDirectCOSUpload(for: route) {
            return try await createChinaVoice(
                reference: reference,
                referenceLanguage: referenceLanguage,
                referenceText: spokenText,
                onProgress: onProgress
            )
        }
        let boundary = "CastReaderVoiceClone-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"consent_confirmed\"\r\n\r\ntrue\r\n")
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"reference_language\"\r\n\r\n")
        body.appendMultipart("\(VoiceCatalog.normalizedLanguage(referenceLanguage))\r\n")
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"reference_text\"\r\n\r\n")
        body.appendMultipart("\(spokenText)\r\n")
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"reference\"; filename=\"reference.wav\"\r\n")
        body.appendMultipart("Content-Type: audio/wav\r\n\r\n")
        body.append(reference)
        body.appendMultipart("\r\n--\(boundary)--\r\n")

        var token = try await requireToken()
        var request = createUploadRequest(boundary: boundary, token: token)
        let uploader = VoiceCloneUploader(route: route)
        var (data, response) = try await uploader.upload(request: request, body: body, onProgress: onProgress)
        if let http = response as? HTTPURLResponse, http.statusCode == 401,
           let refreshed = await sessionProvider.refreshSession() {
            token = refreshed
            request = createUploadRequest(boundary: boundary, token: token)
            (data, response) = try await uploader.upload(request: request, body: body, onProgress: onProgress)
        }
        try await validate(response: response, data: data, originalRequest: request, canRefresh: false)
        return try VoiceCloneResponseParser.createdVoice(from: data)
    }

    private func createChinaVoice(
        reference: Data,
        referenceLanguage: String,
        referenceText: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ClonedVoice {
        onProgress(0.03)
        let sts: STSCredentials
        do {
            sts = try await APIService.shared.fetchSTSCredentials()
        } catch {
            throw VoiceCloneError.temporaryUnavailable
        }
        let objectKey = try await VoiceCloneCOSUploader().upload(
            data: reference,
            filename: "voice-reference.wav",
            credentials: sts
        ) { progress in
            onProgress(0.05 + progress * 0.75)
        }
        let payload = try JSONSerialization.data(withJSONObject: [
            "consentConfirmed": true,
            "referenceLanguage": VoiceCatalog.normalizedLanguage(referenceLanguage),
            "referenceText": referenceText,
            "referenceObjectKey": objectKey,
        ])
        var token = try await requireToken()
        var request = createChinaObjectRequest(token: token, body: payload)
        onProgress(0.82)
        var (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401,
           let refreshed = await sessionProvider.refreshSession() {
            token = refreshed
            request = createChinaObjectRequest(token: token, body: payload)
            (data, response) = try await session.data(for: request)
        }
        try await validate(response: response, data: data, originalRequest: request, canRefresh: false)
        onProgress(1)
        return try VoiceCloneResponseParser.createdVoice(from: data)
    }

    func deleteVoice(_ voiceId: String) async throws {
        guard voiceId.hasPrefix("vc_"),
              let encoded = voiceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw VoiceCloneError.voiceNotFound
        }
        _ = try await perform(path: "/api/voice-clone/voices/\(encoded)", method: "DELETE")
    }

    func preview(voiceId: String, fallbackLanguage: String?) async throws -> Data {
        guard let path = VoiceCloneEndpoint.previewPath(for: voiceId) else {
            throw VoiceCloneError.voiceNotFound
        }
        // The server owns both preview text and language. Free users can hear
        // exactly this cached sample without gaining an arbitrary TTS endpoint.
        do {
            return try await perform(path: path, method: "GET")
        } catch VoiceCloneError.server(404, _) {
            // Compatibility during a staggered backend rollout. Older regional
            // gateways do not have the fixed-preview route yet, but they do
            // expose the original authenticated speech route. Once both regions
            // serve the new route this branch is no longer used.
            return try await legacyPreviewSpeech(
                voiceId: voiceId,
                languageId: fallbackLanguage
            )
        }
    }

    private func legacyPreviewSpeech(
        voiceId: String,
        languageId: String?
    ) async throws -> Data {
        let normalized = VoiceCatalog.normalizedLanguage(languageId ?? "en")
        let language = normalized == "zh" ? "zh" : "en"
        let text = language == "zh"
            ? "你好，这是我在 CastReader 中创建的声音。"
            : "Hello, this is my voice in CastReader."
        let body = try JSONSerialization.data(withJSONObject: [
            "voiceId": voiceId,
            "text": text,
            "languageId": language,
        ])
        return try await perform(
            path: "/api/voice-clone/speech",
            method: "POST",
            body: body
        )
    }

    private func perform(path: String, method: String, body: Data? = nil, canRefresh: Bool = true) async throws -> Data {
        guard Constants.Features.voiceCloningEnabled else {
            throw VoiceCloneError.temporaryUnavailable
        }
        let token = try await requireToken()
        var request = URLRequest(url: baseURL.appendingPathComponent(String(path.dropFirst())))
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        authorize(&request, token: token)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401, canRefresh,
           let refreshed = await sessionProvider.refreshSession() {
            authorize(&request, token: refreshed)
            let (retryData, retryResponse) = try await session.data(for: request)
            try await validate(response: retryResponse, data: retryData, originalRequest: request, canRefresh: false)
            return retryData
        }
        try await validate(response: response, data: data, originalRequest: request, canRefresh: false)
        return data
    }

    private func requireToken() async throws -> String {
        guard let token = await sessionProvider.sessionToken(), !token.isEmpty else {
            await sessionProvider.rejectSession(nil)
            throw VoiceCloneError.sessionUnavailable
        }
        return token
    }

    private func authorize(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func createUploadRequest(boundary: String, token: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/voice-clone/voices"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        authorize(&request, token: token)
        return request
    }

    private func createChinaObjectRequest(token: String, body: Data) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/voice-clone/voices"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request, token: token)
        return request
    }

    private func validate(response: URLResponse, data: Data, originalRequest: URLRequest, canRefresh: Bool) async throws {
        guard let http = response as? HTTPURLResponse else { throw VoiceCloneError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = VoiceCloneResponseParser.serverMessage(from: data)
        let code = VoiceCloneResponseParser.serverCode(from: data)?.uppercased()
        if code == "CLONE_QUOTA_EXHAUSTED" {
            let headerReset = VoiceCloneResponseParser.quotaCapability(from: http).resetAt
            throw VoiceCloneError.quotaExhausted(
                VoiceCloneResponseParser.quotaResetAt(from: data) ?? headerReset
            )
        }
        if ["VOICE_SLOT_FULL", "VOICE_FREE_CREATION_CONSUMED"].contains(code ?? "") {
            // Legacy rollout response. Creation is no longer limited by plan
            // or voice count; surface this as a temporary server mismatch.
            throw VoiceCloneError.temporaryUnavailable
        }
        switch http.statusCode {
        case 401:
            let authorization = originalRequest.value(
                forHTTPHeaderField: "Authorization"
            ) ?? ""
            let rejectedToken = authorization.hasPrefix("Bearer ")
                ? String(authorization.dropFirst("Bearer ".count))
                : nil
            await sessionProvider.rejectSession(rejectedToken)
            throw VoiceCloneError.signInRequired
        case 403: throw VoiceCloneError.proRequired
        case 404 where VoiceCloneResponseParser.isVoiceNotFound(
            statusCode: http.statusCode,
            data: data
        ):
            throw VoiceCloneError.voiceNotFound
        case 404:
            throw VoiceCloneError.server(404, message)
        case 413, 422:
            let localized = VoiceCloneQualityMessage.localized(
                for: code
            )
            throw VoiceCloneError.invalidRecording(
                localized ?? AppLocalized("录音未通过服务器校验")
            )
        case 429 where code == "VOICE_CREATION_LIMIT":
            throw VoiceCloneError.temporaryUnavailable
        case 429 where ["CLONE_WORKER_BUSY", "VOICE_WORKER_BUSY"].contains(code ?? ""):
            throw VoiceCloneError.workerBusy(message)
        case 429: throw VoiceCloneError.server(429, message)
        case 503: throw VoiceCloneError.temporaryUnavailable
        default: throw VoiceCloneError.server(http.statusCode, message)
        }
    }
}

private final class VoiceCloneCOSUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var progress: (@Sendable (Double) -> Void)?

    func upload(
        data: Data,
        filename: String,
        credentials: STSCredentials,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        let cleanPrefix = credentials.prefix.hasSuffix("/")
            ? String(credentials.prefix.dropLast())
            : credentials.prefix
        let key = "\(cleanPrefix)/\(UUID().uuidString)_\(filename)"
        let host = credentials.uploadHost
        guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://\(host)/\(encodedKey)") else {
            throw VoiceCloneError.invalidRecording(AppLocalized("录音上传地址无效，请重试"))
        }

        let startTime = Int(Date().timeIntervalSince1970)
        let keyTime = "\(startTime);\(startTime + 600)"
        let contentType = "audio/wav"
        let signedHeaders = [
            "content-type": contentType,
            "host": host,
            "x-cos-security-token": credentials.sessionToken,
        ]
        let headerList = signedHeaders.keys.sorted().joined(separator: ";")
        let headerString = signedHeaders.keys.sorted().map { name in
            "\(name)=\(Self.urlEncode(signedHeaders[name]!))"
        }.joined(separator: "&")
        let signKey = Self.hmacSHA1(key: credentials.secretAccessKey, data: keyTime)
        let httpString = "put\n/\(key)\n\n\(headerString)\n"
        let stringToSign = "sha1\n\(keyTime)\n\(Self.sha1Hash(httpString))\n"
        let signature = Self.hmacSHA1(key: signKey, data: stringToSign)
        let authorization = "q-sign-algorithm=sha1&q-ak=\(credentials.accessKeyId)&q-sign-time=\(keyTime)&q-key-time=\(keyTime)&q-header-list=\(headerList)&q-url-param-list=&q-signature=\(signature)"

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(credentials.sessionToken, forHTTPHeaderField: "x-cos-security-token")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")

        progress = onProgress
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let uploadSession = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { uploadSession.finishTasksAndInvalidate() }
        let (_, response) = try await uploadSession.upload(for: request, from: data)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw VoiceCloneError.temporaryUnavailable
        }
        return key
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    private static func hmacSHA1(key: String, data: String) -> String {
        let keyData = Data(key.utf8)
        let dataData = Data(data.utf8)
        var result = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        keyData.withUnsafeBytes { keyBytes in
            dataData.withUnsafeBytes { dataBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyBytes.baseAddress,
                    keyData.count,
                    dataBytes.baseAddress,
                    dataData.count,
                    &result
                )
            }
        }
        return result.map { String(format: "%02x", $0) }.joined()
    }

    private static func sha1Hash(_ string: String) -> String {
        let data = Data(string.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.~")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}

private final class VoiceCloneUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var progress: (@Sendable (Double) -> Void)?
    private let route: ServiceRoute

    init(route: ServiceRoute) {
        self.route = route
    }

    func upload(
        request: URLRequest,
        body: Data,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (Data, URLResponse) {
        progress = onProgress
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        return try await session.upload(for: request, from: body)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress?(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalURL = task.originalRequest?.url ?? task.currentRequest?.url
        completionHandler(
            OwnedAPIRedirectPolicy.allowsRedirect(
                route: route,
                originalURL: originalURL,
                proposedURL: request.url
            ) ? request : nil
        )
    }
}

private extension Data {
    mutating func appendMultipart(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}

@MainActor
final class VoiceCloneAccessCoordinator: ObservableObject {
    static let shared = VoiceCloneAccessCoordinator()
    enum Prompt: Identifiable {
        case signIn, paywall, message(String)
        var id: String {
            switch self {
            case .signIn: return "signIn"
            case .paywall: return "paywall"
            case .message(let value): return "message-\(value)"
            }
        }
    }
    @Published var prompt: Prompt?
}

@MainActor
final class VoiceClonePreviewPlayer: NSObject, ObservableObject, @preconcurrency AVAudioPlayerDelegate {
    static let shared = VoiceClonePreviewPlayer()
    @Published private(set) var playingVoiceId: String?
    @Published private(set) var loadingVoiceId: String?
    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?

    func toggle(_ voice: ClonedVoice) {
        guard Constants.Features.voiceCloningEnabled else { return }
        if playingVoiceId == voice.voiceId || loadingVoiceId == voice.voiceId { stop(); return }
        stop(resumeSuspendedPlayback: false)
        VoiceSamplePlayer.shared.stop(resumeSuspendedPlayback: false)
        VoicePreviewPlaybackCoordinator.shared.begin()
        loadingVoiceId = voice.voiceId
        task = Task {
            do {
                let data = try await VoiceCloneService.shared.preview(
                    voiceId: voice.voiceId,
                    fallbackLanguage: voice.referenceLanguage
                )
                guard !Task.isCancelled else { return }
                let player = try AVAudioPlayer(data: data)
                player.delegate = self
                self.player = player
                loadingVoiceId = nil
                playingVoiceId = voice.voiceId
                player.play()
            } catch {
                guard loadingVoiceId == voice.voiceId else { return }
                loadingVoiceId = nil
                VoicePreviewPlaybackCoordinator.shared.end()
                VoiceCloneStore.shared.errorMessage = error.localizedDescription
            }
        }
    }

    func stop(resumeSuspendedPlayback: Bool = true) {
        task?.cancel(); task = nil
        player?.stop(); player = nil
        playingVoiceId = nil; loadingVoiceId = nil
        if resumeSuspendedPlayback { VoicePreviewPlaybackCoordinator.shared.end() }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard self.player === player else { return }
        stop()
    }
}
