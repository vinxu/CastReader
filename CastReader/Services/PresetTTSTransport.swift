import AVFoundation
import Foundation

/// Synthesis has a separate anonymous transport and one logical deadline.
/// A missing response is not proof that the GPU did not execute the request.
enum PresetTTSTransport {
    static let readTimeout: TimeInterval = 125
    static let totalTimeout: TimeInterval = 140

    static func mayReplay(_ response: HTTPURLResponse) -> Bool {
        response.statusCode == 503 &&
            response.value(forHTTPHeaderField: "x-castreader-tts-contract") == "preset-gateway-v1" &&
            response.value(forHTTPHeaderField: "x-castreader-tts-attempts") == "0" &&
            response.value(forHTTPHeaderField: "x-tts-error-code") == "TTS_GATEWAY_BUSY" &&
            response.value(forHTTPHeaderField: "x-voice-retryable") == "true"
    }

    static func mayReplay(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        return [.cannotFindHost, .dnsLookupFailed, .cannotConnectToHost].contains(error.code)
    }

    static func generate(
        input: String, voice: String, body: Data, route: ServiceRoute,
        requestID: String, session: URLSession, sessionToken: String? = nil, google: Bool = false
    ) async throws -> TTSResponse {
        let projection = PresetTTSSourceProjection(input, normalizeHyphens: !google)
        guard !projection.wire.isEmpty else { throw APIError.serverError("TTS_EMPTY_INPUT") }
        guard var payload = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        payload["input"] = projection.wire
        let wireBody = try JSONSerialization.data(withJSONObject: payload)
        return try await withThrowingTaskGroup(of: TTSResponse.self) { group in
            group.addTask {
                try await sendOperation(
                    projection: projection, voice: voice, body: wireBody,
                    route: route, requestID: requestID, session: session, sessionToken: sessionToken, google: google
                )
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(totalTimeout * 1_000_000_000))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func sendOperation(
        projection: PresetTTSSourceProjection, voice: String, body: Data,
        route: ServiceRoute, requestID: String, session: URLSession, sessionToken: String?, google: Bool
    ) async throws -> TTSResponse {
        let primary = google ? route.apiGatewayBaseURL : TTSEndpoint.primaryBase(for: route)
        let fallback = !google && route == .globalGateway ? ServiceRoute.globalGateway.apiGatewayBaseURL : nil
        let started = ProcessInfo.processInfo.systemUptime
        var base = primary
        var replayed = false
        while true {
            try Task.checkCancellation()
            guard let url = URL(string: TTSEndpoint.partlyURL(base: base)) else { throw APIError.invalidURL }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = body
            request.timeoutInterval = readTimeout
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(Constants.clientPlatform, forHTTPHeaderField: "X-CastReader-Platform")
            request.setValue(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown", forHTTPHeaderField: "X-CastReader-Version")
            request.setValue(String(ServiceRouting.currentBuildNumber), forHTTPHeaderField: "X-CastReader-Build")
            request.setValue(requestID, forHTTPHeaderField: "X-Request-ID")
            if google, let sessionToken {
                request.setValue("Bearer \(sessionToken)", forHTTPHeaderField: "Authorization")
                request.setValue("session", forHTTPHeaderField: "X-Auth-Provider")
            }
            let result: (Data, URLResponse)
            do {
                result = try await session.data(for: request)
            } catch {
                try Task.checkCancellation()
                guard !replayed, let fallback, mayReplay(error) else { throw error }
                base = fallback
                replayed = true
                log("fallback request=\(requestID) reason=connection-not-established")
                continue
            }
            try Task.checkCancellation()
            guard let http = result.1 as? HTTPURLResponse else { throw APIError.invalidResponse }
            log("response request=\(requestID) host=\(url.host ?? "") status=\(http.statusCode) bytes=\(result.0.count) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) fallback=\(replayed)")
            if !replayed, let fallback, mayReplay(http) {
                base = fallback
                replayed = true
                log("fallback request=\(requestID) reason=gateway-not-dispatched")
                continue
            }
            guard (200..<300).contains(http.statusCode) else {
                if google { throw GoogleStandardTTSError(response: http, data: result.0, requestID: requestID) }
                throw APIError.httpError(http.statusCode)
            }
            // Parsing and audio inspection execute away from MainActor, including
            // when the next part arrives while the preceding part is playing.
            return try validate(result.0, projection: projection, voice: voice)
        }
    }

    static func validate(_ data: Data, projection: PresetTTSSourceProjection, voice: String) throws -> TTSResponse {
        let response: TTSResponse
        do { response = try JSONDecoder().decode(TTSResponse.self, from: data) }
        catch { throw APIError.decodingError(error) }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let returned = object?["voice_code"], !(returned is NSNull), returned as? String != voice {
            throw APIError.serverError("TTS_VOICE_MISMATCH")
        }
        if let format = object?["audio_format"], !(format is NSNull),
           !["mp3", "audio/mp3", "audio/mpeg", "wav", "audio/wav", "audio/x-wav"].contains((format as? String ?? "").lowercased()) {
            throw APIError.serverError("TTS_AUDIO_FORMAT")
        }
        let partition = try projection.resolve(processed: response.processedText, remaining: response.unprocessedText)
        guard let audio = Data(base64Encoded: response.audio), !audio.isEmpty,
              let player = try? AVAudioPlayer(data: audio),
              player.duration.isFinite, player.duration > 0 else {
            throw APIError.invalidResponse
        }
        if voice.hasPrefix("api_") {
            guard object?["model"] as? String == "google-wavenet",
                  object?["voice_code"] as? String == voice,
                  object?["timestamp_source"] as? String == "google-ssml-marks-v1",
                  object?["timestamp_end_mode"] as? String == "next_native_mark",
                  ["audio/mpeg", "mp3", "audio/mp3"].contains(response.audioFormat ?? ""),
                  let raw = object?["timestamps"] as? [[String: Any]],
                  raw.count == response.safeTimestamps.count,
                  GoogleNativeMarks.isValid(text: response.processedText ?? "",
                    timestamps: response.safeTimestamps, duration: player.duration) else {
                throw SpeechCapabilityError.invalidSynchronization
            }
        }
        return TTSResponse(
            audio: response.audio, audioFormat: response.audioFormat,
            timestamps: response.timestamps, duration: player.duration,
            processedText: voice.hasPrefix("api_") ? response.processedText : partition.processed,
            unprocessedText: partition.remaining
        )
    }

    private static func log(_ message: String) {
        #if DEBUG
        NSLog("CR_TTS_TRANSPORT %@", message)
        ReaderRunLog.write("TTS transport \(message)")
        #endif
    }
}

/// Keep server normalization and source consumption separate. This projection
/// maps an exact wire prefix back to the submitted source, including repeated
/// hyphens and the unsubmitted tail of a request longer than 5,000 UTF-16 units.
struct PresetTTSSourceProjection: Sendable {
    let source: String
    let wire: String
    private let sourceEnds: [String.Index]

    init(_ source: String, normalizeHyphens: Bool = true) {
        self.source = source
        var cursor = source.startIndex
        while cursor < source.endIndex, source[cursor].isWhitespace { cursor = source.index(after: cursor) }
        var end = source.endIndex
        while end > cursor, source[source.index(before: end)].isWhitespace { end = source.index(before: end) }
        var value = ""
        var ends: [String.Index] = []
        var units = 0
        while cursor < end {
            let character = source[cursor]
            guard units + String(character).utf16.count <= 5_000 else { break }
            cursor = source.index(after: cursor)
            if normalizeHyphens && character == "-" {
                while cursor < end, source[cursor] == "-" { cursor = source.index(after: cursor) }
            }
            value.append(character)
            units += String(character).utf16.count
            ends.append(cursor)
        }
        if cursor < end, let boundary = value.lastIndex(where: \.isWhitespace) {
            let count = value.distance(from: value.startIndex, to: value.index(after: boundary))
            if count >= ends.count / 2 {
                value = String(value.prefix(count))
                ends = Array(ends.prefix(count))
            }
        }
        // The gateway trims each submitted chunk, including a whitespace
        // boundary introduced by the local length limit. Keep that boundary in
        // the source mapping so the next part starts after it exactly once.
        let consumedEnd = ends.last
        while value.last?.isWhitespace == true {
            value.removeLast()
            ends.removeLast()
        }
        if let consumedEnd, !ends.isEmpty { ends[ends.count - 1] = consumedEnd }
        wire = value
        sourceEnds = ends
    }

    func resolve(processed: String?, remaining: String?) throws -> (processed: String, remaining: String) {
        let prefix: String
        if let processed {
            guard wire.hasPrefix(processed) else { throw APIError.serverError("TTS_SOURCE_MISMATCH") }
            let tail = String(wire.dropFirst(processed.count))
            guard remaining == nil || remaining == tail else { throw APIError.serverError("TTS_SOURCE_MISMATCH") }
            prefix = processed
        } else if let remaining {
            guard wire.hasSuffix(remaining) else { throw APIError.serverError("TTS_SOURCE_MISMATCH") }
            prefix = String(wire.dropLast(remaining.count))
        } else {
            prefix = wire
        }
        guard !prefix.isEmpty, sourceEnds.indices.contains(prefix.count - 1) else {
            throw APIError.serverError("TTS_NO_PROGRESS")
        }
        var end = sourceEnds[prefix.count - 1]
        if source[end...].allSatisfy(\.isWhitespace) { end = source.endIndex }
        return (String(source[..<end]), String(source[end...]))
    }
}

/// Match the gateway's whitespace-token SSML contract exactly, including marks
/// and combining characters. Never interpolate absent or damaged native points.
enum GoogleNativeMarks {
    static func isValid(text: String, timestamps: [TTSTimestamp], duration: Double) -> Bool {
        let expected = text.split(whereSeparator: \.isWhitespace).map(String.init).filter { token in
            token.unicodeScalars.contains { $0.properties.isAlphabetic ||
                CharacterSet.decimalDigits.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }
        }
        guard duration.isFinite, duration > 0, !expected.isEmpty,
              expected.count == timestamps.count else { return false }
        var previousStart = -Double.infinity
        var previousEnd: Double?
        for (word, mark) in zip(expected, timestamps) {
            guard word == mark.word, mark.startTime.isFinite, mark.endTime.isFinite,
                  mark.startTime >= 0, mark.startTime > previousStart,
                  mark.endTime > mark.startTime, mark.endTime <= duration + 0.05,
                  previousEnd.map({ abs($0 - mark.startTime) < 0.001 }) ?? true else { return false }
            previousStart = mark.startTime
            previousEnd = mark.endTime
        }
        return true
    }
}

/// Keep only a bounded machine code and logical request ID, never a server
/// message/body that may echo document text. These failures are not clone quota.
struct GoogleStandardTTSError: Error, LocalizedError {
    let status: Int
    let code: String
    let requestID: String

    init(response: HTTPURLResponse, data: Data, requestID: String) {
        status = response.statusCode
        self.requestID = requestID
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let proposed = response.value(forHTTPHeaderField: "x-tts-error-code") ?? object?["code"] as? String ?? ""
        code = proposed.range(of: "^[A-Z][A-Z0-9_]{0,79}$", options: .regularExpression) != nil ? proposed : "API_TTS_REQUEST_FAILED"
    }

    var requiresCatalogRefresh: Bool {
        ["API_TTS_LANGUAGE_MISMATCH", "API_TTS_VOICE_MISMATCH", "API_TTS_LANGUAGE_UNAVAILABLE"].contains(code)
    }

    var errorDescription: String? {
        switch code {
        case "API_TTS_CLONE_UNSUPPORTED": return SpeechCapabilityError.cloneUnsupported.localizedDescription
        case "UNSUPPORTED_TTS_LANGUAGE": return SpeechCapabilityError.unsupportedLanguage.localizedDescription
        case "API_TTS_ALIGNMENT_INVALID", "API_TTS_RESPONSE_INVALID": return SpeechCapabilityError.invalidSynchronization.localizedDescription
        case "API_TTS_REQUEST_PENDING": return AppLocalized("语音正在生成，请稍后重试")
        case "API_TTS_DAILY_LIMIT": return AppLocalized("语音服务今日额度已用完，请稍后重试")
        case "AUTH_REQUIRED", "SESSION_EXPIRED", "SESSION_INVALID": return AppLocalized("请先登录")
        case "PRO_REQUIRED": return AppLocalized("升级到 Pro")
        default: return SpeechCapabilityError.serviceUnavailable.localizedDescription
        }
    }
}
