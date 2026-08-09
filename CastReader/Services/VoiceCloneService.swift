import Foundation
import Combine
import AVFoundation

actor VoiceCloneService {
    static let shared = VoiceCloneService(sessionProvider: MobileSessionStore.shared)

    private let baseURL: URL
    private let session: URLSession
    private let sessionProvider: any MobileSessionProviding

    init(
        baseURL: URL = URL(string: Constants.API.webURL) ?? URL(string: "https://castreader.ai")!,
        session: URLSession = .shared,
        sessionProvider: any MobileSessionProviding
    ) {
        self.baseURL = baseURL
        self.session = session
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
        consentConfirmed: Bool,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> ClonedVoice {
        guard Constants.Features.voiceCloningEnabled else {
            throw VoiceCloneError.temporaryUnavailable
        }
        guard consentConfirmed else {
            throw VoiceCloneError.invalidRecording(AppLocalized("请先确认声音授权"))
        }
        let values = try recordingURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize, size > 0, size <= 4 * 1024 * 1024 else {
            throw VoiceCloneError.invalidRecording(AppLocalized("录音文件必须不超过 4 MB"))
        }
        let reference = try Data(contentsOf: recordingURL)
        let boundary = "CastReaderVoiceClone-\(UUID().uuidString)"
        var body = Data()
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"consent_confirmed\"\r\n\r\ntrue\r\n")
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"reference_language\"\r\n\r\n")
        body.appendMultipart("\(VoiceCatalog.normalizedLanguage(referenceLanguage))\r\n")
        body.appendMultipart("--\(boundary)\r\n")
        body.appendMultipart("Content-Disposition: form-data; name=\"reference\"; filename=\"reference.wav\"\r\n")
        body.appendMultipart("Content-Type: audio/wav\r\n\r\n")
        body.append(reference)
        body.appendMultipart("\r\n--\(boundary)--\r\n")

        var token = try await requireToken()
        var request = createUploadRequest(boundary: boundary, token: token)
        let uploader = VoiceCloneUploader()
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

    func deleteVoice(_ voiceId: String) async throws {
        guard voiceId.hasPrefix("vc_"),
              let encoded = voiceId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw VoiceCloneError.voiceNotFound
        }
        _ = try await perform(path: "/api/voice-clone/voices/\(encoded)", method: "DELETE")
    }

    func previewSpeech(voiceId: String, text: String, languageId: String) async throws -> Data {
        let body = try JSONSerialization.data(withJSONObject: [
            "voiceId": voiceId,
            "text": String(text.prefix(600)),
            "languageId": VoiceCatalog.normalizedLanguage(languageId),
        ])
        return try await perform(path: "/api/voice-clone/speech", method: "POST", body: body)
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

    private func validate(response: URLResponse, data: Data, originalRequest: URLRequest, canRefresh: Bool) async throws {
        guard let http = response as? HTTPURLResponse else { throw VoiceCloneError.invalidResponse }
        guard !(200..<300).contains(http.statusCode) else { return }
        let message = VoiceCloneResponseParser.serverMessage(from: data)
        switch http.statusCode {
        case 401:
            await sessionProvider.invalidateSession()
            throw VoiceCloneError.signInRequired
        case 403: throw VoiceCloneError.proRequired
        case 404: throw VoiceCloneError.voiceNotFound
        case 413, 422: throw VoiceCloneError.invalidRecording(message ?? AppLocalized("录音未通过服务器校验"))
        case 429 where VoiceCloneResponseParser.serverCode(from: data)?.uppercased() == "VOICE_CREATION_LIMIT":
            throw VoiceCloneError.creationLimit(VoiceCloneResponseParser.nextCreateAt(from: data))
        case 429 where ["CLONE_WORKER_BUSY", "VOICE_WORKER_BUSY"].contains(VoiceCloneResponseParser.serverCode(from: data)?.uppercased() ?? ""):
            throw VoiceCloneError.workerBusy(message)
        case 429: throw VoiceCloneError.server(429, message)
        case 503: throw VoiceCloneError.temporaryUnavailable
        default: throw VoiceCloneError.server(http.statusCode, message)
        }
    }
}

private final class VoiceCloneUploader: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private var progress: (@Sendable (Double) -> Void)?

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

    func toggle(_ voice: ClonedVoice, language: String) {
        guard Constants.Features.voiceCloningEnabled else { return }
        if playingVoiceId == voice.voiceId || loadingVoiceId == voice.voiceId { stop(); return }
        stop(resumeSuspendedPlayback: false)
        VoiceSamplePlayer.shared.stop(resumeSuspendedPlayback: false)
        VoicePreviewPlaybackCoordinator.shared.begin()
        loadingVoiceId = voice.voiceId
        let supported = Set(["ar", "da", "de", "el", "en", "es", "fi", "fr", "he", "hi", "it", "ja", "ko", "ms", "nl", "no", "pl", "pt", "ru", "sv", "sw", "tr", "zh"])
        let normalized = VoiceCatalog.normalizedLanguage(language)
        let id = supported.contains(normalized) ? normalized : "en"
        let text = id == "zh" ? "你好，这是我在 CastReader 中创建的声音。" : "Hello, this is my voice in CastReader."
        task = Task {
            do {
                let data = try await VoiceCloneService.shared.previewSpeech(voiceId: voice.voiceId, text: text, languageId: id)
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
