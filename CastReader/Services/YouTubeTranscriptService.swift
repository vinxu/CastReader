//
//  YouTubeTranscriptService.swift
//  CastReader
//
//  Short-lived, isolated WebKit extraction for public YouTube captions.
//  This service never shares the embedded-reader browser profile and never
//  asks for, reads or persists a YouTube account credential.
//

import Dispatch
import Foundation
import NaturalLanguage
import UIKit
import WebKit

// MARK: - Pure message/security contracts

struct YouTubeTranscriptMessageFrame: Equatable, Sendable {
    let isMainFrame: Bool
    let securityScheme: String
    let securityHost: String
    let securityPort: Int
    let requestURL: String?
}

enum YouTubeTranscriptSecurityPolicy {
    static let canonicalHost = "www.youtube.com"

    static func allowsMainFrameNavigation(
        _ url: URL?,
        expectedVideoID: String
    ) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == canonicalHost,
              components.port == nil,
              components.user == nil,
              components.password == nil else {
            return false
        }
        let pathComponents = components.path.split(separator: "/")
        guard pathComponents.count == 2,
              pathComponents[0] == "embed",
              pathComponents[1] == expectedVideoID else { return false }

        let items = components.queryItems ?? []
        func uniqueValue(_ name: String) -> String? {
            let values = items.filter { $0.name == name }.compactMap(\.value)
            return values.count == 1 ? values[0] : nil
        }
        guard uniqueValue("enablejsapi") == "1",
              uniqueValue("playsinline") == "1",
              uniqueValue("autoplay") == "1",
              uniqueValue("mute") == "1",
              uniqueValue("cc_load_policy") == "1",
              uniqueValue("origin") == YouTubeVideoReference.embedOriginString else {
            return false
        }
        let startValues = items.filter { $0.name == "start" }.compactMap(\.value)
        let languageValues = items
            .filter { $0.name == "cc_lang_pref" }
            .compactMap(\.value)
        guard startValues.count <= 1,
              startValues.first.map({ Int($0).map { $0 >= 0 } ?? false }) ?? true,
              languageValues.count <= 1 else {
            return false
        }
        let allowedNames: Set<String> = [
            "enablejsapi", "playsinline", "autoplay", "cc_load_policy",
            "cc_lang_pref", "mute", "origin", "start",
        ]
        return items.allSatisfy { allowedNames.contains($0.name) }
    }

    static func allowsMessageFrame(
        _ frame: YouTubeTranscriptMessageFrame,
        expectedVideoID: String
    ) -> Bool {
        let scheme = frame.securityScheme
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()
        guard frame.isMainFrame,
              scheme == "https",
              frame.securityHost.lowercased() == canonicalHost,
              frame.securityPort == 0 || frame.securityPort == 443,
              let rawURL = frame.requestURL,
              let requestURL = URL(string: rawURL) else {
            return false
        }
        return allowsMainFrameNavigation(requestURL, expectedVideoID: expectedVideoID)
    }

    static func allowsEnvelope(
        requestToken: String?,
        requestVideoID: String?,
        videoID: String?,
        expectedToken: String,
        expectedVideoID: String
    ) -> Bool {
        !expectedToken.isEmpty
            && requestToken == expectedToken
            && requestVideoID == expectedVideoID
            && videoID == expectedVideoID
    }

    static func rejectedNavigationFailure(
        for url: URL?
    ) -> YouTubeTranscriptFailure {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else { return .unavailable }
        if host == "consent.youtube.com" || host == "consent.google.com" {
            // The extractor deliberately does not automate Google's consent
            // wall. This is an access restriction, not slow transcript parsing.
            return .restricted
        }
        if host == "accounts.google.com" {
            return .restricted
        }
        let path = url.path.lowercased()
        if (host == canonicalHost &&
            (path.contains("/sorry") || path.contains("/signin") ||
             path.contains("/verify"))) ||
            (host == "google.com" || host.hasSuffix(".google.com")) &&
            (path.contains("/sorry") || path.contains("/recaptcha")) {
            return .restricted
        }
        return .unavailable
    }
}

enum YouTubeTranscriptHTTPPolicy {
    static func failure(for statusCode: Int) -> YouTubeTranscriptFailure? {
        guard statusCode >= 400 else { return nil }
        switch statusCode {
        case 401, 403:
            return .restricted
        case 404, 410:
            return .unavailable
        case 408, 425, 429, 500...599:
            // Rate limits and server transients describe the current request,
            // not the video's product availability. Keep the retryable network
            // copy instead of falsely telling the user the video disappeared.
            return .network
        default:
            return .unavailable
        }
    }
}

/// Privacy-safe, monotonic checkpoints for the native half of extraction.
/// Snapshots intentionally contain no URL, video ID, request token, title or
/// caption text, so DEBUG timing logs cannot accidentally retain page data.
enum YouTubeTranscriptNativeStage: String, CaseIterable, Equatable, Sendable {
    case requestStarted = "request_started"
    case navigationStarted = "navigation_started"
    case messageReceived = "message_received"
    case transcriptReady = "transcript_ready"
    case completed = "completed"
    case failed = "failed"
}

struct YouTubeTranscriptStageSnapshot: Equatable, Sendable {
    let stage: YouTubeTranscriptNativeStage
    let elapsedMilliseconds: Int
}

struct YouTubeTranscriptStageTimeline: Sendable {
    private let startedAtNanoseconds: UInt64
    private var lastElapsedMilliseconds = 0

    init(
        startedAtNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) {
        self.startedAtNanoseconds = startedAtNanoseconds
    }

    mutating func record(
        _ stage: YouTubeTranscriptNativeStage,
        nowNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> YouTubeTranscriptStageSnapshot {
        let delta = nowNanoseconds >= startedAtNanoseconds
            ? nowNanoseconds - startedAtNanoseconds
            : 0
        let milliseconds = Int(delta / 1_000_000)
        lastElapsedMilliseconds = max(lastElapsedMilliseconds, milliseconds)
        return YouTubeTranscriptStageSnapshot(
            stage: stage,
            elapsedMilliseconds: lastElapsedMilliseconds
        )
    }
}

struct YouTubeTranscriptExtractionEnvelope: Decodable, Equatable, Sendable {
    struct CaptionTrackIdentity: Decodable, Equatable, Sendable {
        let id: String?
        let name: String?
        let languageCode: String?
        let kind: String?
        let vssId: String?
        let index: Int?
    }

    struct Playability: Decodable, Equatable, Sendable {
        let status: String?
        let reason: String?
        let classification: String?
    }

    struct FailurePayload: Decodable, Equatable, Sendable {
        let code: String?
        let message: String?
    }

    let schemaVersion: Int
    let requestToken: String
    /// Present only on warm-session follow-ups. Correlates this envelope with
    /// one specific follow-up request on a document that has already delivered
    /// its first transcript.
    let followUpToken: String?
    let ok: Bool
    let requestVideoId: String?
    let videoId: String?
    let title: String?
    let thumbnailURL: String?
    let channel: String?
    let captionLanguage: String?
    let captionTrack: CaptionTrackIdentity?
    let availableTracks: [CaptionTrackIdentity]?
    let transcriptSource: String?
    let cues: [YouTubeTranscriptCue]
    let isLive: Bool
    let durationSeconds: Double?
    let storyboardSpec: String?
    let playability: Playability?
    let error: FailurePayload?
    let diagnostics: [String]?
}

/// Cross-checks the caption identity against the words that will actually be
/// spoken. This is intentionally separate from UI locale: a Chinese App locale
/// is a selection preference, never evidence that an English video's cues are
/// Chinese (or vice versa).
enum YouTubeTranscriptContentLanguagePolicy {
    struct Evidence: Equatable, Sendable {
        let language: String?
        let confidence: Double
        let readableCharacterCount: Int
    }

    static func evidence(for cues: [YouTubeTranscriptCue]) -> Evidence {
        evidence(for: cues.prefix(80).map(\.text).joined(separator: " "))
    }

    static func evidence(for text: String) -> Evidence {
        let sample = String(text.prefix(4_000))
        let readableCount = sample.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.properties.isAlphabetic {
                count += 1
            }
        }
        guard readableCount > 0 else {
            return Evidence(
                language: nil,
                confidence: 0,
                readableCharacterCount: 0
            )
        }

        // Script evidence is more reliable than statistical recognition for
        // subtitle fragments containing names, acronyms and punctuation.
        let scriptEvidence = LanguageDetector.evidence(for: sample)
        if ["zh", "ja", "hi"].contains(scriptEvidence.language),
           scriptEvidence.confidence >= 0.65 {
            return Evidence(
                language: scriptEvidence.language,
                confidence: scriptEvidence.confidence,
                readableCharacterCount: readableCount
            )
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        let best = recognizer.languageHypotheses(withMaximum: 5)
            .map { language, probability in
                (canonical(language.rawValue), probability)
            }
            .filter { !$0.0.isEmpty }
            .max { $0.1 < $1.1 }
        if let best {
            return Evidence(
                language: best.0,
                confidence: best.1,
                readableCharacterCount: readableCount
            )
        }
        return Evidence(
            language: scriptEvidence.language,
            confidence: scriptEvidence.confidence,
            readableCharacterCount: readableCount
        )
    }

    static func stronglyConflicts(
        claimedLanguage: String,
        evidence: Evidence
    ) -> Bool {
        guard evidence.readableCharacterCount >= 48,
              evidence.confidence >= 0.78,
              let detected = evidence.language else { return false }
        let claimed = canonical(claimedLanguage)
        return !claimed.isEmpty && claimed != canonical(detected)
    }

    static func validatedPlaybackLanguage(
        for transcript: YouTubeTranscriptDocument
    ) throws -> String {
        let claimed = try YouTubeTranscriptLanguagePolicy.playbackLanguage(
            for: transcript.track.languageCode
        )
        guard !stronglyConflicts(
            claimedLanguage: claimed,
            evidence: evidence(for: transcript.cues)
        ) else {
            throw YouTubeTranscriptFailure.captionAccess
        }
        return claimed
    }

    private static func canonical(_ identifier: String) -> String {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return SupportedTTSLanguage(identifier: normalized)?.rawValue
            ?? normalized.split(separator: "-").first.map(String.init)
            ?? ""
    }
}

enum YouTubeTranscriptEnvelopeDecoder {
    static let maximumMessageBytes = 20 * 1_024 * 1_024

    static func requestToken(from body: Any) -> String? {
        stringField("requestToken", from: body)
    }

    static func followUpToken(from body: Any) -> String? {
        stringField("followUpToken", from: body)
    }

    private static func stringField(_ name: String, from body: Any) -> String? {
        guard let data = data(from: body),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary[name] as? String
    }

    static func decode(_ body: Any) throws -> YouTubeTranscriptExtractionEnvelope {
        guard let data = data(from: body) else {
            throw YouTubeTranscriptFailure.malformedResponse
        }
        do {
            return try JSONDecoder().decode(
                YouTubeTranscriptExtractionEnvelope.self,
                from: data
            )
        } catch {
            throw YouTubeTranscriptFailure.malformedResponse
        }
    }

    static func document(
        from envelope: YouTubeTranscriptExtractionEnvelope,
        reference: YouTubeVideoReference,
        preferredLanguage: String,
        requestedTrack: YouTubeTrackRequest? = nil,
        extractedAt: Date = Date()
    ) throws -> YouTubeTranscriptDocument {
        guard envelope.schemaVersion == 1,
              envelope.videoId == reference.videoId,
              envelope.requestVideoId == reference.videoId,
              envelope.cues.count <= 200_000 else {
            throw YouTubeTranscriptFailure.malformedResponse
        }
        if let failure = YouTubeTranscriptEnvelopeClassifier.failure(for: envelope) {
            throw failure
        }

        var seen = Set<String>()
        var cues: [YouTubeTranscriptCue] = []
        cues.reserveCapacity(envelope.cues.count)
        for cue in envelope.cues {
            let text = cue.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, cue.startMs >= 0, cue.durationMs >= 0 else {
                throw YouTubeTranscriptFailure.malformedResponse
            }
            let key = "\(cue.startMs)|\(text)"
            guard seen.insert(key).inserted else { continue }
            cues.append(
                YouTubeTranscriptCue(
                    text: text,
                    startMs: cue.startMs,
                    durationMs: cue.durationMs
                )
            )
        }
        cues = cues.enumerated().sorted { lhs, rhs in
            if lhs.element.startMs != rhs.element.startMs {
                return lhs.element.startMs < rhs.element.startMs
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        guard !cues.isEmpty else { throw YouTubeTranscriptFailure.noCaptions }

        // These page-level transcript routes are not cryptographically or
        // structurally bound to the caption candidate selected above. YouTube
        // may return a UI-localized `tlang` transcript while the player track
        // still says `en`. Never let that unverified identity choose the TTS
        // language; detect the language of the actual cue text instead.
        let transcriptSource = cleaned(envelope.transcriptSource)
        let unverifiedTranscriptSources: Set<String> = [
            "transcript_bridge",
            "transcript_endpoint",
            "transcript_fetch_capture",
        ]
        let usedUnverifiedTranscriptSource = transcriptSource.map {
            unverifiedTranscriptSources.contains($0)
        } ?? false
        // A YouTube DOM change can expose accessibility text without the cue
        // timing fields. Multiple panel rows all pinned to zero are not a
        // usable transcript: accepting them would render every timestamp as
        // 00:00 and break resume/highlight semantics. Fail closed instead of
        // caching visibly corrupted text.
        if usedUnverifiedTranscriptSource,
           cues.count > 1,
           cues.allSatisfy({ $0.startMs == 0 }) {
            throw YouTubeTranscriptFailure.malformedResponse
        }
        let cueLanguageEvidence = YouTubeTranscriptContentLanguagePolicy.evidence(
            for: cues
        )
        let detectedCueLanguage = usedUnverifiedTranscriptSource
            ? cueLanguageEvidence.language
            : nil
        let claimedLanguage = cleaned(envelope.captionTrack?.languageCode)
            ?? cleaned(envelope.captionLanguage)
        if !usedUnverifiedTranscriptSource,
           let claimedLanguage,
           YouTubeTranscriptContentLanguagePolicy.stronglyConflicts(
               claimedLanguage: claimedLanguage,
               evidence: cueLanguageEvidence
           ) {
            // A verified candidate whose body is overwhelmingly another
            // language is normally a translated timedtext response. Reject it
            // instead of caching translated words under the source-track key.
            throw YouTubeTranscriptFailure.captionAccess
        }
        let languageCode = detectedCueLanguage
            ?? claimedLanguage
            ?? cueLanguageEvidence.language
            ?? "und"
        if let requestedTrack {
            // The page-level lanes (transcript panel/endpoint) are not bound to
            // the pinned candidate and can still answer in YouTube's default
            // language. An explicit language choice must fail rather than hand
            // back another language's words under the requested track.
            let requestedBase = YouTubeTrackSelector.baseLanguage(
                requestedTrack.languageCode
            )
            let resolvedBase = YouTubeTrackSelector.baseLanguage(languageCode)
            guard !requestedBase.isEmpty, requestedBase == resolvedBase else {
                throw YouTubeTranscriptFailure.trackUnavailable
            }
        }
        let unverifiedIdentityPrefix: String = {
            switch transcriptSource {
            case "transcript_endpoint": return "transcript-endpoint"
            case "transcript_fetch_capture": return "transcript-capture"
            default: return "transcript-bridge"
            }
        }()
        let trackIdentity = usedUnverifiedTranscriptSource
            ? "\(unverifiedIdentityPrefix):\(reference.videoId):\(languageCode)"
            : cleaned(envelope.captionTrack?.id)
                ?? "transcript-bridge:\(reference.videoId):\(languageCode)"
        let track = YouTubeCaptionTrack(
            // The adapter intentionally never returns YouTube's short-lived,
            // signed timedtext URL. The stable track ID occupies this legacy
            // model field so cached documents cannot retain a bearer-like URL.
            baseURL: trackIdentity,
            languageCode: languageCode,
            name: usedUnverifiedTranscriptSource
                ? nil
                : cleaned(envelope.captionTrack?.name),
            kind: usedUnverifiedTranscriptSource
                ? nil
                : cleaned(envelope.captionTrack?.kind)
        )

        let title = cleaned(envelope.title) ?? reference.videoId
        let durationMs = durationMilliseconds(envelope.durationSeconds)
        let metadata = YouTubeVideoMetadata(
            videoId: reference.videoId,
            title: title,
            channelName: cleaned(envelope.channel),
            sourceURL: reference.canonicalURLString,
            thumbnailURL: secureRemoteURLString(envelope.thumbnailURL),
            durationMs: durationMs
        )
        return YouTubeTranscriptDocument(
            metadata: metadata,
            track: track,
            cues: cues,
            storyboard: envelope.storyboardSpec.flatMap(YouTubeStoryboardParser.parse),
            extractedAt: extractedAt,
            selectedForLanguage: cleaned(preferredLanguage),
            availableTracks: envelope.availableTracks.map(captionTrackOptions)
        )
    }

    /// Page-provided track identities, reduced to the picker's contract.
    /// `YouTubeCaptionTrackOption.normalized` then bounds and de-duplicates it.
    private static func captionTrackOptions(
        _ identities: [YouTubeTranscriptExtractionEnvelope.CaptionTrackIdentity]
    ) -> [YouTubeCaptionTrackOption] {
        identities.compactMap { identity in
            guard let languageCode = cleaned(identity.languageCode) else { return nil }
            let id = cleaned(identity.id)
                ?? cleaned(identity.vssId)
                ?? "\(languageCode)|\(cleaned(identity.kind) ?? "manual")"
            return YouTubeCaptionTrackOption(
                id: id,
                languageCode: languageCode,
                name: cleaned(identity.name),
                kind: cleaned(identity.kind)
            )
        }
    }

    private static func data(from body: Any) -> Data? {
        guard let source = body as? String,
              !source.isEmpty,
              source.lengthOfBytes(using: .utf8) <= maximumMessageBytes else {
            return nil
        }
        return source.data(using: .utf8)
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    private static func secureRemoteURLString(_ rawValue: String?) -> String? {
        guard let rawValue = cleaned(rawValue),
              let components = URLComponents(string: rawValue),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return nil }
        return components.url?.absoluteString
    }

    private static func durationMilliseconds(_ seconds: Double?) -> Int? {
        guard let seconds,
              seconds.isFinite,
              seconds >= 0,
              seconds <= Double(Int.max) / 1_000 else { return nil }
        return Int((seconds * 1_000).rounded())
    }
}

enum YouTubeTranscriptEnvelopeClassifier {
    static func failure(
        for envelope: YouTubeTranscriptExtractionEnvelope
    ) -> YouTubeTranscriptFailure? {
        guard envelope.schemaVersion == 1 else { return .malformedResponse }

        let status = normalized(envelope.playability?.status)
        let classification = normalized(envelope.playability?.classification)
        let errorCode = normalizedOptional(envelope.error?.code)
        if envelope.isLive || classification == "live_offline"
            || status == "live_stream_offline" {
            return .live
        }

        // A verification wall often carries YouTube's generic LOGIN_REQUIRED
        // playability status even when the video itself remains public. Trust
        // the adapter's specific evidence before account-gating heuristics so
        // the UI never tells the user that signing in will unlock the video.
        if errorCode == "youtube_verification_required" {
            return .youtubeAccessLimited
        }

        let restricted = [
            "age_restricted",
            "sign_in_required",
            "membership_required",
        ]
        if restricted.contains(classification)
            || status == "login_required"
            || status == "age_check_required"
            || status == "content_check_required"
            || errorCode == "restricted_video" {
            return .restricted
        }

        // A failed player bootstrap is a transient access/initialization
        // failure. YouTube can pair it with a generic UNPLAYABLE status, so
        // classify the explicit adapter code before the status-only fallback.
        // It is neither proof of sign-in gating nor a caption parsing timeout.
        if errorCode == "player_bootstrap_failed" {
            return .playerBootstrapFailed
        }

        let unavailable = ["geo_restricted", "removed", "unavailable", "private"]
        if unavailable.contains(classification)
            || status == "unplayable"
            || status == "error" {
            return .unavailable
        }

        if let code = errorCode {
            if code == "requested_track_unavailable" { return .trackUnavailable }
            // The kept-alive document could not serve this track. Not a product
            // error: the caller retries through a full bootstrap.
            if code == "warm_session_miss" { return .captionAccess }
            if code.contains("timeout") { return .timeout }
            if code.contains("network") || code == "fetch_failed" {
                return .network
            }
            if code == "transcript_empty"
                || code == "transcript_access_failed"
                || code == "transcript_access_rejected" {
                return .captionAccess
            }
            if code == "captions_unavailable" || code == "no_captions" {
                return .noCaptions
            }
            return .malformedResponse
        }

        if !envelope.ok || envelope.cues.isEmpty {
            // Absence of cue data is not proof that the video has no captions.
            // Only the explicit adapter codes above may make that authoritative
            // product claim. A selected track means caption access failed;
            // otherwise the incomplete envelope is structurally untrustworthy.
            return envelope.captionTrack == nil
                ? .malformedResponse
                : .captionAccess
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    private static func normalizedOptional(_ value: String?) -> String? {
        let result = normalized(value)
        return result.isEmpty ? nil : result
    }
}

// MARK: - WebKit extraction

@MainActor
final class YouTubeTranscriptService: NSObject {
    static let shared = YouTubeTranscriptService()
    nonisolated static let defaultExtractionTimeout: TimeInterval = 42
    private nonisolated static let nativeBootstrapAndDeliveryGraceMilliseconds = 7_500

    /// Deliberately unique to YouTube extraction. It is not the default store
    /// and not `CommercialWebSession`/`LiveWebPlatform`'s browser profile.
    static let websiteDataStoreIdentifier =
        UUID(uuidString: "CB7A25B5-7C7A-4D92-AEF6-75924CB709B8")!

    static var websiteDataStore: WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: websiteDataStoreIdentifier)
    }

    /// Bump to discard the extraction store's cookies and caches once on the
    /// next launch. Reputation from a session YouTube decided to distrust is
    /// carried in that store, and it outlives the code change that caused it.
    private static let websiteDataStoreResetVersion = 2
    private static let websiteDataStoreResetKey = "youtube.dataStoreResetVersion"

    static func resetWebsiteDataStoreIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.integer(forKey: websiteDataStoreResetKey)
                < websiteDataStoreResetVersion else { return }
        defaults.set(websiteDataStoreResetVersion, forKey: websiteDataStoreResetKey)
        // Nothing in this store is user data: extraction never signs in, and
        // transcripts live in the app's own cache.
        websiteDataStore.removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0)
        ) {
            #if DEBUG
            NSLog("CRYT extraction website data store reset")
            #endif
        }
    }

    private static let viewport = CGRect(x: 0, y: 0, width: 1_280, height: 800)

    private let vendoredBridgeLoader: () -> String?
    private let pageLoader: (WKWebView, URLRequest) -> Void

    private final class ActiveRequest {
        let id: UUID
        let token: String
        let reference: YouTubeVideoReference
        let preferredLanguage: String
        let requestedTrack: YouTubeTrackRequest?
        let onTranscriptReady: ((YouTubeTranscriptDocument) -> Void)?
        let continuation: CheckedContinuation<YouTubeTranscriptDocument, Error>
        var webView: WKWebView?
        var hostingWindow: UIWindow?
        var timeoutTask: Task<Void, Never>?
        var stageTimeline = YouTubeTranscriptStageTimeline()

        init(
            id: UUID,
            token: String,
            reference: YouTubeVideoReference,
            preferredLanguage: String,
            requestedTrack: YouTubeTrackRequest?,
            onTranscriptReady: ((YouTubeTranscriptDocument) -> Void)?,
            continuation: CheckedContinuation<YouTubeTranscriptDocument, Error>
        ) {
            self.id = id
            self.token = token
            self.reference = reference
            self.preferredLanguage = preferredLanguage
            self.requestedTrack = requestedTrack
            self.onTranscriptReady = onTranscriptReady
            self.continuation = continuation
        }
    }

    /// A document that already delivered one transcript and is being kept
    /// alive so further caption languages skip the page bootstrap.
    ///
    /// Bound to one `videoId`: YouTube's subtitle proof is video-scoped, so a
    /// different video can never reuse this document.
    private final class WarmSession {
        let videoId: String
        let token: String
        let webView: WKWebView
        let hostingWindow: UIWindow
        var idleTask: Task<Void, Never>?
        var followUp: FollowUpRequest?

        init(
            videoId: String,
            token: String,
            webView: WKWebView,
            hostingWindow: UIWindow
        ) {
            self.videoId = videoId
            self.token = token
            self.webView = webView
            self.hostingWindow = hostingWindow
        }
    }

    private final class FollowUpRequest {
        let id: UUID
        let followUpToken: String
        let reference: YouTubeVideoReference
        let preferredLanguage: String
        let requestedTrack: YouTubeTrackRequest
        let continuation: CheckedContinuation<YouTubeTranscriptDocument, Error>
        var timeoutTask: Task<Void, Never>?
        let startedAtNanoseconds = DispatchTime.now().uptimeNanoseconds

        var elapsedMilliseconds: Int {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now >= startedAtNanoseconds else { return 0 }
            return Int((now - startedAtNanoseconds) / 1_000_000)
        }

        init(
            id: UUID,
            followUpToken: String,
            reference: YouTubeVideoReference,
            preferredLanguage: String,
            requestedTrack: YouTubeTrackRequest,
            continuation: CheckedContinuation<YouTubeTranscriptDocument, Error>
        ) {
            self.id = id
            self.followUpToken = followUpToken
            self.reference = reference
            self.preferredLanguage = preferredLanguage
            self.requestedTrack = requestedTrack
            self.continuation = continuation
        }
    }

    /// Whether an extraction document is kept alive for further caption
    /// languages. **Off**, and the follow-up lane is incomplete — see below.
    ///
    /// The warm follow-up fetches captions over `timedtext`, which requires
    /// YouTube's video-scoped proof-of-origin token. On device that token is
    /// never captured (`subtitle proof required=true captured=false` in every
    /// observed run); extraction succeeds through the direct transcript lane
    /// instead, which needs no proof. So every follow-up returned
    /// `warm_session_miss` within milliseconds and fell back to a full
    /// bootstrap — all of the cost, none of the benefit.
    ///
    /// Finishing it means porting the follow-up onto the direct transcript
    /// lane (it accepts a `languageCode`). Measured first: a full extraction is
    /// ~4.0s, of which ~2.0s *is* that transcript request and would still be
    /// paid per language. The win is ~1–1.5s, and the user judged switching
    /// already fast enough. Kept behind this flag rather than deleted.
    static let warmSessionEnabled = false

    /// Idle window before a kept-alive document is released. Long enough to
    /// cover a user browsing the language picker, short enough that a hidden
    /// youtube.com page never lingers behind their back.
    static let warmSessionIdleTimeout: TimeInterval = 180
    /// Outer bound on one warm follow-up. The page lane carries its own
    /// per-fetch ceiling; this covers a wedged document that never answers.
    static let warmFollowUpTimeout: TimeInterval = 12

    private var activeRequest: ActiveRequest?
    private var warmSession: WarmSession?
    private var lifecycleObservers: [NSObjectProtocol] = []

    /// Whether the most recent successful extraction was served by a kept-alive
    /// document instead of a full page bootstrap. Read by analytics right after
    /// `extract` returns; deliberately not part of the transcript model.
    private(set) var lastExtractionServedFromWarmSession = false

    override init() {
        vendoredBridgeLoader = { YouTubeWebScripts.loadVendoredBridge() }
        pageLoader = { webView, request in
            _ = webView.load(request)
        }
        super.init()
        observeWarmSessionLifecycle()
    }

    /// A hidden youtube.com document is only justified while the app is in
    /// front of the user and memory is not under pressure.
    private func observeWarmSessionLifecycle() {
        let center = NotificationCenter.default
        for name in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.didReceiveMemoryWarningNotification,
        ] {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.discardWarmSession(
                        reason: name == UIApplication.didEnterBackgroundNotification
                            ? "background"
                            : "memory_warning"
                    )
                }
            }
            lifecycleObservers.append(observer)
        }
    }

    /// Network-free seam for focused lifecycle tests. Production always uses
    /// `init()`/`shared`, the bundled bridge and `WKWebView.load(_:)` above.
    init(
        vendoredBridgeLoader: @escaping () -> String?,
        pageLoader: @escaping (WKWebView, URLRequest) -> Void
    ) {
        self.vendoredBridgeLoader = vendoredBridgeLoader
        self.pageLoader = pageLoader
        super.init()
    }

    var activeVideoIDForTesting: String? {
        activeRequest?.reference.videoId
    }

    /// Kept as one factory so tests can lock the document-start/page-world
    /// ordering that makes early LOGIN_REQUIRED classification deterministic.
    static func documentStartScripts(
        vendoredBridge: String,
        expectedVideoID: String,
        requestToken: String,
        preferredLanguage: String,
        requestedTrack: YouTubeTrackRequest? = nil,
        timeout: TimeInterval = YouTubeTranscriptService.defaultExtractionTimeout
    ) -> [WKUserScript] {
        [
            WKUserScript(
                source: YouTubeWebScripts.earlyBridgeBootstrap(vendoredBridge),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ),
            WKUserScript(
                source: YouTubeWebScripts.extractionAdapter(
                    expectedVideoID: expectedVideoID,
                    requestToken: requestToken,
                    preferredLanguage: preferredLanguage,
                    requestedTrack: requestedTrack,
                    adapterBudgetMilliseconds: adapterBudgetMilliseconds(
                        for: timeout
                    )
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ),
        ]
    }

    func extract(
        _ reference: YouTubeVideoReference,
        preferredLanguage: String,
        requestedTrack: YouTubeTrackRequest? = nil,
        timeout: TimeInterval = YouTubeTranscriptService.defaultExtractionTimeout,
        onTranscriptReady: ((YouTubeTranscriptDocument) -> Void)? = nil
    ) async throws -> YouTubeTranscriptDocument {
        finishActive(throwing: .cancelled)

        // A kept-alive document for this exact video can answer an explicit
        // track request without paying for the page bootstrap again. Any
        // failure here falls through to the full path below rather than
        // surfacing as a product error.
        if Self.warmSessionEnabled,
           let requestedTrack,
           let warm = warmSession,
           warm.videoId == reference.videoId,
           warm.followUp == nil {
            do {
                let document = try await extractFromWarmSession(
                    warm,
                    reference: reference,
                    preferredLanguage: Self.safeLanguageTag(preferredLanguage),
                    requestedTrack: requestedTrack
                )
                lastExtractionServedFromWarmSession = true
                return document
            } catch is CancellationError {
                throw YouTubeTranscriptFailure.cancelled
            } catch {
                discardWarmSession(reason: "follow_up_failed")
            }
        }

        lastExtractionServedFromWarmSession = false
        let requestID = UUID()
        let token = UUID().uuidString.lowercased() + UUID().uuidString.lowercased()
        let language = Self.safeLanguageTag(preferredLanguage)
        let boundedTimeout = timeout.isFinite
            ? min(max(timeout, 0.1), 300)
            : Self.defaultExtractionTimeout
        guard let request = Self.initialEmbedRequest(
            reference: reference,
            preferredLanguage: language,
            timeout: boundedTimeout
        ) else {
            throw YouTubeTranscriptFailure.invalidURL
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: YouTubeTranscriptFailure.cancelled)
                    return
                }
                beginExtraction(
                    requestID: requestID,
                    token: token,
                    reference: reference,
                    preferredLanguage: language,
                    requestedTrack: requestedTrack,
                    request: request,
                    timeout: boundedTimeout,
                    onTranscriptReady: onTranscriptReady,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(requestID: requestID)
            }
        }
    }

    func cancel() {
        finishActive(throwing: .cancelled)
    }

    /// Release the kept-alive document. Call this when the reader that
    /// justified holding it goes away — nothing else should be paying for a
    /// hidden youtube.com page.
    func releaseWarmSession() {
        discardWarmSession(reason: "released")
    }

    var warmSessionVideoIDForTesting: String? { warmSession?.videoId }

    // MARK: Warm session

    private func extractFromWarmSession(
        _ warm: WarmSession,
        reference: YouTubeVideoReference,
        preferredLanguage: String,
        requestedTrack: YouTubeTrackRequest
    ) async throws -> YouTubeTranscriptDocument {
        let requestID = UUID()
        let followUpToken = UUID().uuidString.lowercased()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: YouTubeTranscriptFailure.cancelled)
                    return
                }
                guard warmSession === warm, warm.followUp == nil else {
                    continuation.resume(throwing: YouTubeTranscriptFailure.cancelled)
                    return
                }
                let request = FollowUpRequest(
                    id: requestID,
                    followUpToken: followUpToken,
                    reference: reference,
                    preferredLanguage: preferredLanguage,
                    requestedTrack: requestedTrack,
                    continuation: continuation
                )
                warm.followUp = request
                warm.idleTask?.cancel()
                warm.idleTask = nil
                startFollowUpTimeout(request)
                invokeWarmExtractor(on: warm, request: request)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishFollowUp(requestID, throwing: .cancelled)
            }
        }
    }

    private func receiveFollowUp(
        _ message: WKScriptMessage,
        warm: WarmSession,
        followUpToken: String
    ) {
        guard let followUp = warm.followUp,
              followUp.followUpToken == followUpToken else { return }

        let origin = message.frameInfo.securityOrigin
        let frame = YouTubeTranscriptMessageFrame(
            isMainFrame: message.frameInfo.isMainFrame,
            securityScheme: origin.protocol,
            securityHost: origin.host,
            securityPort: origin.port,
            requestURL: message.frameInfo.request.url?.absoluteString
        )
        guard YouTubeTranscriptSecurityPolicy.allowsMessageFrame(
            frame,
            expectedVideoID: warm.videoId
        ),
              YouTubeTranscriptEnvelopeDecoder.requestToken(from: message.body)
                == warm.token else { return }

        do {
            let envelope = try YouTubeTranscriptEnvelopeDecoder.decode(message.body)
            #if DEBUG
            ReaderRunLog.write(
                "CRYT warm envelope ok=\(envelope.ok ? "Y" : "N")"
                    + " error=\(envelope.error?.code ?? "-")"
                    + " track=\(envelope.captionTrack?.languageCode ?? "-")"
                    + " cues=\(envelope.cues.count)"
            )
            for rawLine in (envelope.diagnostics ?? []).suffix(12) {
                ReaderRunLog.write("CRYT warm diag \(Self.debugSafeDiagnostic(rawLine))")
            }
            #endif
            guard YouTubeTranscriptSecurityPolicy.allowsEnvelope(
                requestToken: envelope.requestToken,
                requestVideoID: envelope.requestVideoId,
                videoID: envelope.videoId,
                expectedToken: warm.token,
                expectedVideoID: warm.videoId
            ) else {
                finishFollowUp(followUp.id, throwing: .malformedResponse)
                return
            }
            let document = try YouTubeTranscriptEnvelopeDecoder.document(
                from: envelope,
                reference: followUp.reference,
                preferredLanguage: followUp.preferredLanguage,
                requestedTrack: followUp.requestedTrack
            )
            finishFollowUp(followUp.id, returning: document)
        } catch let failure as YouTubeTranscriptFailure {
            finishFollowUp(followUp.id, throwing: failure)
        } catch {
            finishFollowUp(followUp.id, throwing: .malformedResponse)
        }
    }

    private func invokeWarmExtractor(on warm: WarmSession, request: FollowUpRequest) {
        // The entry point is `async`, so its return value is a Promise, which
        // `evaluateJavaScript` cannot serialize. Start it and report only
        // whether it was reachable; the transcript itself arrives through the
        // message handler.
        // Returns a short status string rather than a bool: "started" is the
        // only success, and every other value names why the document could not
        // take the request.
        let script = """
        (function () {
          var kind = typeof window.__crYtExtractTrack;
          if (kind !== 'function') { return 'missing:' + kind; }
          try {
            window.__crYtExtractTrack(\
        \(YouTubeWebScripts.javaScriptStringLiteral(warm.token)), \
        \(YouTubeWebScripts.javaScriptStringLiteral(request.followUpToken)), \
        \(YouTubeWebScripts.javaScriptStringLiteral(request.requestedTrack.id)), \
        \(YouTubeWebScripts.javaScriptStringLiteral(request.requestedTrack.languageCode)), \
        \(YouTubeWebScripts.javaScriptStringLiteral(request.requestedTrack.kind)));
          } catch (error) {
            return 'threw:' + String(error);
          }
          return 'started';
        })();
        """
        // Must run in `.page`: that is the world the adapter — and therefore
        // the entry point — was injected into. The default client world has
        // its own `window`, where this function simply does not exist.
        //
        // The await is bounded by the follow-up timeout, which resolves the
        // continuation even if this call never comes back.
        Task { @MainActor [weak self] in
            do {
                let value = try await warm.webView.evaluateJavaScript(
                    script,
                    in: nil,
                    contentWorld: .page
                )
                let outcome = (value as? String) ?? "unexpected:\(value)"
                #if DEBUG
                ReaderRunLog.write("CRYT warm invoke outcome=\(outcome)")
                #endif
                // Anything but "started" means the document cannot serve this
                // request. Fail now rather than waiting out the timeout.
                guard outcome != "started" else { return }
                self?.finishFollowUp(request.id, throwing: .captionAccess)
            } catch {
                #if DEBUG
                ReaderRunLog.write("CRYT warm invoke error=\(error)")
                #endif
                self?.finishFollowUp(request.id, throwing: .captionAccess)
            }
        }
    }

    private func startFollowUpTimeout(_ request: FollowUpRequest) {
        request.timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.warmFollowUpTimeout * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.finishFollowUp(request.id, throwing: .timeout)
        }
    }

    private func takeFollowUp(_ requestID: UUID) -> FollowUpRequest? {
        guard let warm = warmSession,
              let followUp = warm.followUp,
              followUp.id == requestID else { return nil }
        warm.followUp = nil
        followUp.timeoutTask?.cancel()
        followUp.timeoutTask = nil
        return followUp
    }

    private func finishFollowUp(
        _ requestID: UUID,
        returning document: YouTubeTranscriptDocument
    ) {
        guard let followUp = takeFollowUp(requestID) else { return }
        #if DEBUG
        ReaderRunLog.write(
            "CRYT warm hit lang=\(document.track.languageCode)"
                + " cues=\(document.cues.count)"
                + " elapsedMs=\(followUp.elapsedMilliseconds)"
        )
        #endif
        armWarmSessionIdleTimeout()
        followUp.continuation.resume(returning: document)
    }

    private func finishFollowUp(
        _ requestID: UUID,
        throwing failure: YouTubeTranscriptFailure
    ) {
        guard let followUp = takeFollowUp(requestID) else { return }
        #if DEBUG
        NSLog("CRYT warm follow-up failed reason=%@", failure.reason)
        ReaderRunLog.write(
            "CRYT warm miss reason=\(failure.reason)"
                + " lang=\(followUp.requestedTrack.languageCode)"
                + " elapsedMs=\(followUp.elapsedMilliseconds)"
        )
        #endif
        // The warm document just proved unreliable for this request. Drop it so
        // the caller's retry goes through a clean bootstrap.
        discardWarmSession(reason: "follow_up_failed")
        followUp.continuation.resume(throwing: failure)
    }

    /// Adopt the finished request's document instead of tearing it down, so the
    /// next caption language can reuse its proof and track list.
    private func adoptWarmSession(from active: ActiveRequest) {
        guard Self.warmSessionEnabled,
              let webView = active.webView,
              let hostingWindow = active.hostingWindow else { return }
        discardWarmSession(reason: "superseded")
        active.timeoutTask?.cancel()
        active.timeoutTask = nil
        let warm = WarmSession(
            videoId: active.reference.videoId,
            token: active.token,
            webView: webView,
            hostingWindow: hostingWindow
        )
        // Ownership moves to the warm session; the ActiveRequest teardown path
        // must no longer touch this WebView.
        active.webView = nil
        active.hostingWindow = nil
        warmSession = warm
        armWarmSessionIdleTimeout()
        #if DEBUG
        NSLog("CRYT warm session retained video=%@", warm.videoId)
        ReaderRunLog.write("CRYT warm retained")
        #endif
    }

    private func armWarmSessionIdleTimeout() {
        guard let warm = warmSession else { return }
        warm.idleTask?.cancel()
        warm.idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(Self.warmSessionIdleTimeout * 1_000_000_000)
            )
            guard !Task.isCancelled else { return }
            self?.discardWarmSession(reason: "idle")
        }
    }

    private func discardWarmSession(reason: String) {
        guard let warm = warmSession else { return }
        warmSession = nil
        warm.idleTask?.cancel()
        warm.idleTask = nil
        if let followUp = warm.followUp {
            warm.followUp = nil
            followUp.timeoutTask?.cancel()
            followUp.continuation.resume(throwing: YouTubeTranscriptFailure.cancelled)
        }
        destroy(webView: warm.webView, hostingWindow: warm.hostingWindow)
        #if DEBUG
        NSLog("CRYT warm session discarded reason=%@", reason)
        ReaderRunLog.write("CRYT warm discarded reason=\(reason)")
        #endif
    }

    private func beginExtraction(
        requestID: UUID,
        token: String,
        reference: YouTubeVideoReference,
        preferredLanguage: String,
        requestedTrack: YouTubeTrackRequest?,
        request: URLRequest,
        timeout: TimeInterval,
        onTranscriptReady: ((YouTubeTranscriptDocument) -> Void)?,
        continuation: CheckedContinuation<YouTubeTranscriptDocument, Error>
    ) {
        // A full bootstrap supersedes whatever document was being kept alive,
        // including one for this same video whose warm path just failed.
        discardWarmSession(reason: "new_extraction")

        guard let vendoredBridge = vendoredBridgeLoader() else {
            continuation.resume(throwing: YouTubeTranscriptFailure.malformedResponse)
            return
        }

        let controller = WKUserContentController()
        controller.add(
            self,
            contentWorld: .page,
            name: YouTubeWebScripts.messageHandlerName
        )
        for script in Self.documentStartScripts(
            vendoredBridge: vendoredBridge,
            expectedVideoID: reference.videoId,
            requestToken: token,
            preferredLanguage: preferredLanguage,
            requestedTrack: requestedTrack,
            timeout: timeout
        ) {
            controller.addUserScript(script)
        }

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = Self.websiteDataStore
        // Let the exact-video official Embed bootstrap itself silently. The
        // page-world adapter mutes before its one controlled play request and
        // pauses as soon as the correlated player response is captured. A real
        // user tap remains the fallback when YouTube still holds a preview shell.
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = false
        configuration.allowsPictureInPictureMediaPlayback = false
        // Keep WebKit's native mobile identity. The official embed endpoint is
        // responsive and does not need the desktop watch-page presentation.
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile

        let webView = WKWebView(frame: Self.viewport, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false

        let context = ActiveRequest(
            id: requestID,
            token: token,
            reference: reference,
            preferredLanguage: preferredLanguage,
            requestedTrack: requestedTrack,
            onTranscriptReady: onTranscriptReady,
            continuation: continuation
        )
        context.webView = webView
        context.hostingWindow = attachToTransparentWindow(webView)
        activeRequest = context
        recordStage(.requestStarted, for: context)
        // This is the total native deadline, including navigation bootstrap.
        startTimeout(requestID: requestID, timeout: timeout)
        recordStage(.navigationStarted, for: context)
        pageLoader(webView, request)
    }

    /// Builds the exact first-party embed request YouTube requires on iOS.
    /// Kept as a pure contract so tests can prevent an accidental regression
    /// back to `/watch` or loss of the app-identity Referer header.
    static func initialEmbedRequest(
        reference: YouTubeVideoReference,
        preferredLanguage: String,
        timeout: TimeInterval
    ) -> URLRequest? {
        let language = safeLanguageTag(preferredLanguage)
        guard let url = reference.embedURL(preferredLanguage: language),
              YouTubeTranscriptSecurityPolicy.allowsMainFrameNavigation(
                  url,
                  expectedVideoID: reference.videoId
              ) else { return nil }
        var request = URLRequest(
            url: url,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.setValue(language, forHTTPHeaderField: "Accept-Language")
        request.setValue(
            YouTubeVideoReference.embedOriginString,
            forHTTPHeaderField: "Referer"
        )
        return request
    }

    private func startTimeout(requestID: UUID, timeout: TimeInterval) {
        guard let active = activeRequest, active.id == requestID else { return }
        active.timeoutTask?.cancel()
        let nanoseconds = UInt64(timeout * 1_000_000_000)
        active.timeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            self?.finish(requestID: requestID, throwing: .timeout)
        }
    }

    private func recordStage(
        _ stage: YouTubeTranscriptNativeStage,
        for active: ActiveRequest
    ) {
        let snapshot = active.stageTimeline.record(stage)
        #if DEBUG
        NSLog(
            "CRYT native stage=%@ elapsedMs=%d",
            snapshot.stage.rawValue,
            snapshot.elapsedMilliseconds
        )
        // NSLog only reaches the device console, which needs root to collect.
        // Mirror into the app container so a failure can be pulled off the
        // device without asking the user for their password.
        ReaderRunLog.write(
            "CRYT stage=\(snapshot.stage.rawValue) elapsedMs=\(snapshot.elapsedMilliseconds)"
        )
        #endif
    }

    static func adapterBudgetMilliseconds(for timeout: TimeInterval) -> Int {
        let bounded = timeout.isFinite ? min(max(timeout, 0.1), 300) :
            defaultExtractionTimeout
        let totalMilliseconds = Int((bounded * 1_000).rounded(.down))
        return max(
            1_000,
            totalMilliseconds - nativeBootstrapAndDeliveryGraceMilliseconds
        )
    }

    private func attachToTransparentWindow(_ webView: WKWebView) -> UIWindow {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
        let window: UIWindow
        if let scene {
            window = UIWindow(windowScene: scene)
            window.frame = Self.viewport
        } else {
            window = UIWindow(frame: Self.viewport)
        }

        let root = UIViewController()
        root.view.frame = window.bounds
        root.view.backgroundColor = .clear
        root.view.isUserInteractionEnabled = false
        webView.frame = Self.viewport
        root.view.addSubview(webView)

        window.rootViewController = root
        window.backgroundColor = .clear
        window.isUserInteractionEnabled = false
        window.alpha = 0.01
        // `isHidden = false` attaches WebKit to a live scene without taking key
        // window status; fully hidden/unattached WebViews can freeze timers.
        window.isHidden = false
        return window
    }

    private func receive(_ message: WKScriptMessage) {
        guard message.name == YouTubeWebScripts.messageHandlerName else { return }
        if let warm = warmSession,
           message.webView === warm.webView,
           let followUpToken = YouTubeTranscriptEnvelopeDecoder.followUpToken(
               from: message.body
           ) {
            receiveFollowUp(message, warm: warm, followUpToken: followUpToken)
            return
        }
        guard let active = activeRequest,
              message.webView === active.webView else { return }

        let origin = message.frameInfo.securityOrigin
        let frame = YouTubeTranscriptMessageFrame(
            isMainFrame: message.frameInfo.isMainFrame,
            securityScheme: origin.protocol,
            securityHost: origin.host,
            securityPort: origin.port,
            requestURL: message.frameInfo.request.url?.absoluteString
        )
        guard YouTubeTranscriptSecurityPolicy.allowsMessageFrame(
            frame,
            expectedVideoID: active.reference.videoId
        ) else { return }

        // Inspect only the token first. A stale callback must not be allowed to
        // fail the newest request merely because its older schema cannot decode.
        guard YouTubeTranscriptEnvelopeDecoder.requestToken(from: message.body)
                == active.token else { return }
        recordStage(.messageReceived, for: active)

        let envelope: YouTubeTranscriptExtractionEnvelope
        do {
            envelope = try YouTubeTranscriptEnvelopeDecoder.decode(message.body)
        } catch {
            finish(requestID: active.id, throwing: .malformedResponse)
            return
        }
        #if DEBUG
        let diagnosticLines = envelope.diagnostics ?? []
        NSLog(
            "CRYT envelope ok=%@ status=%@ class=%@ error=%@ cues=%d diagnosticCount=%d",
            envelope.ok ? "Y" : "N",
            envelope.playability?.status ?? "-",
            envelope.playability?.classification ?? "-",
            envelope.error?.code ?? "-",
            envelope.cues.count,
            diagnosticLines.count
        )
        ReaderRunLog.write(
            "CRYT envelope ok=\(envelope.ok ? "Y" : "N")"
                + " status=\(envelope.playability?.status ?? "-")"
                + " class=\(envelope.playability?.classification ?? "-")"
                + " error=\(envelope.error?.code ?? "-")"
                + " track=\(envelope.captionTrack?.languageCode ?? "-")"
                + " source=\(envelope.transcriptSource ?? "-")"
                + " cues=\(envelope.cues.count)"
                + " tracks=\(envelope.availableTracks?.count ?? -1)"
        )
        for rawLine in diagnosticLines.prefix(80) {
            // Same redaction as the console path: diagnostics can quote page
            // payloads, and this copy lands in a file that gets pulled off the
            // device.
            ReaderRunLog.write("CRYT diag \(Self.debugSafeDiagnostic(rawLine))")
        }
        let visibleCount = min(diagnosticLines.count, 80)
        for (offset, rawLine) in diagnosticLines.prefix(visibleCount).enumerated() {
            NSLog(
                "CRYT diagnostic[%02d/%02d] %@",
                offset + 1,
                visibleCount,
                Self.debugSafeDiagnostic(rawLine)
            )
        }
        #endif
        guard YouTubeTranscriptSecurityPolicy.allowsEnvelope(
            requestToken: envelope.requestToken,
            requestVideoID: envelope.requestVideoId,
            videoID: envelope.videoId,
            expectedToken: active.token,
            expectedVideoID: active.reference.videoId
        ) else {
            // The token already matched above, so this is not a late request;
            // it is a malformed/cross-video payload from the current document.
            finish(requestID: active.id, throwing: .malformedResponse)
            return
        }

        do {
            let document = try YouTubeTranscriptEnvelopeDecoder.document(
                from: envelope,
                reference: active.reference,
                preferredLanguage: active.preferredLanguage,
                requestedTrack: active.requestedTrack
            )
            #if DEBUG
            let languageEvidence = YouTubeTranscriptContentLanguagePolicy.evidence(
                for: document.cues
            )
            NSLog(
                "CRYT language source=%@ claimed=%@ selected=%@ detected=%@ confidence=%.2f chars=%d",
                envelope.transcriptSource ?? "-",
                envelope.captionTrack?.languageCode
                    ?? envelope.captionLanguage
                    ?? "-",
                document.track.languageCode,
                languageEvidence.language ?? "-",
                languageEvidence.confidence,
                languageEvidence.readableCharacterCount
            )
            if let storyboard = document.storyboard {
                NSLog(
                    "CRYT storyboard level=%d tile=%dx%d intervalMs=%d sheets=%d",
                    storyboard.level,
                    storyboard.tileWidth,
                    storyboard.tileHeight,
                    storyboard.intervalMs,
                    storyboard.sheetCount
                )
            }
            #endif
            // This is the earliest point at which the selected caption track
            // has trustworthy paragraph text. Let the route start first-
            // paragraph TTS before WebKit teardown, cache persistence and
            // reader construction complete; the final continuation remains
            // the authoritative extraction result.
            recordStage(.transcriptReady, for: active)
            active.onTranscriptReady?(document)
            finish(requestID: active.id, returning: document)
        } catch let failure as YouTubeTranscriptFailure {
            finish(requestID: active.id, throwing: failure)
        } catch {
            finish(requestID: active.id, throwing: .malformedResponse)
        }
    }

    private func cancel(requestID: UUID) {
        guard activeRequest?.id == requestID else { return }
        finish(requestID: requestID, throwing: .cancelled)
    }

    private func finish(
        requestID: UUID,
        returning document: YouTubeTranscriptDocument
    ) {
        guard let active = activeRequest, active.id == requestID else { return }
        // Hand the document over before the teardown path runs, so the page
        // that just proved it works survives for the next caption language.
        adoptWarmSession(from: active)
        guard let active = takeActive(requestID: requestID) else { return }
        recordStage(.completed, for: active)
        active.continuation.resume(returning: document)
    }

    private func finish(
        requestID: UUID,
        throwing failure: YouTubeTranscriptFailure
    ) {
        guard let active = takeActive(requestID: requestID) else { return }
        recordStage(.failed, for: active)
        #if DEBUG
        NSLog("CRYT extraction failed video=%@ reason=%@", active.reference.videoId, failure.reason)
        #endif
        active.continuation.resume(throwing: failure)
    }

    private func finishActive(throwing failure: YouTubeTranscriptFailure) {
        guard let requestID = activeRequest?.id else { return }
        finish(requestID: requestID, throwing: failure)
    }

    private func takeActive(requestID: UUID) -> ActiveRequest? {
        guard let active = activeRequest, active.id == requestID else { return nil }
        activeRequest = nil
        tearDown(active)
        return active
    }

    private func tearDown(_ active: ActiveRequest) {
        active.timeoutTask?.cancel()
        active.timeoutTask = nil
        destroy(webView: active.webView, hostingWindow: active.hostingWindow)
        active.webView = nil
        active.hostingWindow = nil
    }

    /// The single place a YouTube extraction WebView is released. The message
    /// handler and user scripts must go with it: `WKUserContentController`
    /// strongly retains its handler, so leaving them attached keeps this
    /// service alive through a WebView nobody is using.
    private func destroy(webView: WKWebView?, hostingWindow: UIWindow?) {
        if let webView {
            // Belt-and-suspenders cleanup for an autoplay+mute Embed. The page
            // bridge already pauses on the correlated exact-video response;
            // this also covers cancellation or teardown during bootstrap.
            webView.pauseAllMediaPlayback {}
            webView.stopLoading()
            webView.navigationDelegate = nil
            webView.uiDelegate = nil
            let controller = webView.configuration.userContentController
            controller.removeScriptMessageHandler(
                forName: YouTubeWebScripts.messageHandlerName,
                contentWorld: .page
            )
            controller.removeAllUserScripts()
            webView.removeFromSuperview()
        }
        hostingWindow?.isHidden = true
        hostingWindow?.rootViewController = nil
    }

    private static func safeLanguageTag(_ value: String) -> String {
        let candidate = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard !candidate.isEmpty,
              candidate.count <= 35,
              candidate.unicodeScalars.allSatisfy(allowed.contains) else {
            return "en"
        }
        return candidate
    }

    #if DEBUG
    private nonisolated static func debugSafeDiagnostic(_ raw: String) -> String {
        let line = String(raw.prefix(240))
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        let lower = line.lowercased()
        if lower.contains("bridge: intercepted (500):") {
            return "bridge: intercepted payload=[redacted]"
        }
        let sensitiveMarkers = [
            "http://", "https://", "pot=", "pot%3d", "potoken",
            "clicktrackingparams", "\"params\"",
        ]
        if sensitiveMarkers.contains(where: lower.contains) {
            return "[redacted diagnostic]"
        }
        return line
    }
    #endif

}

extension YouTubeTranscriptService: WKScriptMessageHandler {
    nonisolated func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        MainActor.assumeIsolated { [weak self] in
            self?.receive(message)
        }
    }
}

extension YouTubeTranscriptService: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
    ) {
        if let warm = warmSession, webView === warm.webView {
            // A kept-alive document has already delivered its transcript. Any
            // further main-frame navigation — YouTube's SPA moving on its own,
            // a reload — invalidates the proof and track list it is being held
            // for, so stop it and drop the session.
            guard navigationAction.targetFrame?.isMainFrame == true else {
                decisionHandler(navigationAction.targetFrame == nil ? .cancel : .allow)
                return
            }
            decisionHandler(.cancel)
            discardWarmSession(reason: "unexpected_navigation")
            return
        }
        guard let active = activeRequest, webView === active.webView else {
            decisionHandler(.cancel)
            return
        }

        if navigationAction.targetFrame == nil {
            decisionHandler(.cancel)
            return
        }
        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.allow)
            return
        }

        let url = navigationAction.request.url
        if YouTubeTranscriptSecurityPolicy.allowsMainFrameNavigation(
            url,
            expectedVideoID: active.reference.videoId
        ) {
            decisionHandler(.allow)
            return
        }

        decisionHandler(.cancel)
        #if DEBUG
        NSLog(
            "CRYT rejected main-frame navigation url=%@",
            url?.absoluteString ?? "nil"
        )
        #endif
        finish(
            requestID: active.id,
            throwing: YouTubeTranscriptSecurityPolicy.rejectedNavigationFailure(for: url)
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if let warm = warmSession, webView === warm.webView {
            guard navigationResponse.isForMainFrame else {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            discardWarmSession(reason: "unexpected_navigation")
            return
        }
        guard let active = activeRequest, webView === active.webView else {
            decisionHandler(.cancel)
            return
        }
        guard navigationResponse.isForMainFrame else {
            decisionHandler(.allow)
            return
        }
        let url = navigationResponse.response.url
        guard YouTubeTranscriptSecurityPolicy.allowsMainFrameNavigation(
            url,
            expectedVideoID: active.reference.videoId
        ) else {
            decisionHandler(.cancel)
            #if DEBUG
            NSLog(
                "CRYT rejected main-frame response url=%@",
                url?.absoluteString ?? "nil"
            )
            #endif
            finish(
                requestID: active.id,
                throwing: YouTubeTranscriptSecurityPolicy.rejectedNavigationFailure(for: url)
            )
            return
        }
        if let response = navigationResponse.response as? HTTPURLResponse,
           let failure = YouTubeTranscriptHTTPPolicy.failure(
               for: response.statusCode
           ) {
            decisionHandler(.cancel)
            #if DEBUG
            NSLog("CRYT navigation HTTP status=%d", response.statusCode)
            #endif
            finish(requestID: active.id, throwing: failure)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(webView, error: error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleNavigationFailure(webView, error: error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let active = activeRequest, webView === active.webView else { return }
        finish(requestID: active.id, throwing: .network)
    }

    private func handleNavigationFailure(_ webView: WKWebView, error: Error) {
        guard let active = activeRequest, webView === active.webView else { return }
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        #if DEBUG
        NSLog(
            "CRYT navigation failure domain=%@ code=%d description=%@",
            (error as NSError).domain,
            code,
            (error as NSError).localizedDescription
        )
        #endif
        finish(requestID: active.id, throwing: .network)
    }
}

extension YouTubeTranscriptService: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        nil
    }
}
