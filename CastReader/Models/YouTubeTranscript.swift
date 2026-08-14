//
//  YouTubeTranscript.swift
//  CastReader
//
//  Pure YouTube URL/transcript/storyboard contracts shared by the app and the
//  Share Extension. Keep this file Foundation/CoreGraphics-only.
//

import CoreGraphics
import Darwin
import Foundation

// MARK: - URL parsing

struct YouTubeVideoReference: Codable, Equatable, Sendable {
    let videoId: String
    let startSeconds: Int?

    /// Stable app identity used by YouTube's official embedded player. The
    /// embed document's `origin` and initial request `Referer` must agree.
    static let embedOriginString = "https://com.same.castreader"

    var canonicalURLString: String {
        var result = "https://www.youtube.com/watch?v=\(videoId)"
        if let startSeconds {
            result += "&t=\(startSeconds)s"
        }
        return result
    }

    var canonicalURL: URL? { URL(string: canonicalURLString) }

    /// Official player document used internally by the short-lived WebView.
    /// Keep this separate from `canonicalURL`: history, sharing and "open in
    /// YouTube" must continue to use the ordinary watch URL.
    var embedURL: URL? { embedURL(preferredLanguage: nil) }

    func embedURL(preferredLanguage: String?) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.youtube.com"
        components.path = "/embed/\(videoId)"
        var queryItems = [
            URLQueryItem(name: "enablejsapi", value: "1"),
            URLQueryItem(name: "playsinline", value: "1"),
            // A no-autoplay Embed stays on YouTube's thumbnail preview in
            // iOS WebKit and never exposes the player/caption response. Start
            // the official player muted; the extraction bridge pauses it as
            // soon as the exact-video response is captured.
            URLQueryItem(name: "autoplay", value: "1"),
            URLQueryItem(name: "mute", value: "1"),
            URLQueryItem(name: "cc_load_policy", value: "1"),
            URLQueryItem(name: "origin", value: Self.embedOriginString),
        ]
        if let preferredLanguage, !preferredLanguage.isEmpty {
            queryItems.append(
                URLQueryItem(name: "cc_lang_pref", value: preferredLanguage)
            )
        }
        if let startSeconds, startSeconds > 0 {
            queryItems.append(
                URLQueryItem(name: "start", value: String(startSeconds))
            )
        }
        components.queryItems = queryItems
        return components.url
    }
}

enum YouTubeURLParser {
    private static let youtubeHosts: Set<String> = [
        "youtube.com",
        "www.youtube.com",
        "m.youtube.com",
    ]
    private static let shortHosts: Set<String> = [
        "youtu.be",
        "www.youtu.be",
    ]

    /// Accepts the v1 product URL surface and rejects look-alike hosts,
    /// credentials, non-web schemes, explicit ports and ambiguous video IDs.
    static func parse(_ rawValue: String) -> YouTubeVideoReference? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            return nil
        }

        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              components.user == nil,
              components.password == nil,
              components.port == nil,
              let host = components.host?.lowercased(),
              youtubeHosts.contains(host) || shortHosts.contains(host) else {
            return nil
        }

        let videoId: String?
        if shortHosts.contains(host) {
            videoId = shortLinkVideoId(path: components.path)
        } else if components.path == "/watch" || components.path == "/watch/" {
            videoId = uniqueQueryValue(named: "v", in: components.queryItems)
        } else {
            videoId = shortsVideoId(path: components.path)
        }

        guard let videoId, isValidVideoId(videoId) else { return nil }

        let queryTimeValues = (components.queryItems ?? [])
            .filter { $0.name == "t" }
            .compactMap(\.value)
        guard Set(queryTimeValues).count <= 1 else { return nil }

        let queryStart: Int?
        if let value = queryTimeValues.first {
            guard let parsed = parseTimecode(value) else { return nil }
            queryStart = parsed
        } else {
            queryStart = nil
        }

        let fragmentResult = parseFragmentTime(components.fragment)
        guard !fragmentResult.isInvalid else { return nil }

        return YouTubeVideoReference(
            videoId: videoId,
            // Query parameters are the canonical YouTube share form. A hash is
            // used only when the query did not already provide a start time.
            startSeconds: queryStart ?? fragmentResult.seconds
        )
    }

    static func isYouTubeURL(_ rawValue: String) -> Bool {
        parse(rawValue) != nil
    }

    private static func uniqueQueryValue(
        named name: String,
        in items: [URLQueryItem]?
    ) -> String? {
        let values = (items ?? [])
            .filter { $0.name == name }
            .compactMap(\.value)
        guard !values.isEmpty, Set(values).count == 1 else { return nil }
        return values[0]
    }

    private static func shortLinkVideoId(path: String) -> String? {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        guard normalized.hasPrefix("/"),
              normalized.dropFirst().contains("/") == false else { return nil }
        return String(normalized.dropFirst())
    }

    private static func shortsVideoId(path: String) -> String? {
        let normalized = path.hasSuffix("/") ? String(path.dropLast()) : path
        let prefix = "/shorts/"
        guard normalized.hasPrefix(prefix) else { return nil }
        let id = String(normalized.dropFirst(prefix.count))
        guard !id.isEmpty, !id.contains("/") else { return nil }
        return id
    }

    private static func isValidVideoId(_ value: String) -> Bool {
        guard value.utf8.count == 11 else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte)
                || (97...122).contains(byte) || byte == 45 || byte == 95
        }
    }

    private struct FragmentTimeResult {
        let seconds: Int?
        let isInvalid: Bool
    }

    private static func parseFragmentTime(_ fragment: String?) -> FragmentTimeResult {
        guard let fragment, !fragment.isEmpty else {
            return FragmentTimeResult(seconds: nil, isInvalid: false)
        }

        if fragment.hasPrefix("t=") {
            let value = String(fragment.dropFirst(2).split(separator: "&", maxSplits: 1)[0])
            return FragmentTimeResult(
                seconds: parseTimecode(value),
                isInvalid: parseTimecode(value) == nil
            )
        }

        // YouTube also emits direct numeric/timecode hashes such as #90 and
        // #1m30s. An unrelated page anchor is ignored rather than invalidating
        // an otherwise valid video URL.
        if let parsed = parseTimecode(fragment) {
            return FragmentTimeResult(seconds: parsed, isInvalid: false)
        }
        return FragmentTimeResult(seconds: nil, isInvalid: false)
    }

    /// Parses plain seconds, `90s`, `1m30s` and `1h2m3s` without accepting
    /// signs, fractions, reordered units or arithmetic overflow.
    private static func parseTimecode(_ rawValue: String) -> Int? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (48...57).contains($0) }) {
            return checkedInteger(value)
        }

        var total: Int64 = 0
        var digits = ""
        var priorUnitRank = 4
        var sawUnit = false

        for scalar in value.unicodeScalars {
            if (48...57).contains(scalar.value) {
                digits.unicodeScalars.append(scalar)
                continue
            }

            let multiplier: Int64
            let rank: Int
            switch scalar.value {
            case 104: // h
                multiplier = 3_600
                rank = 3
            case 109: // m
                multiplier = 60
                rank = 2
            case 115: // s
                multiplier = 1
                rank = 1
            default:
                return nil
            }

            guard !digits.isEmpty,
                  rank < priorUnitRank,
                  let amount = Int64(digits) else { return nil }
            let multiplied = amount.multipliedReportingOverflow(by: multiplier)
            guard !multiplied.overflow else { return nil }
            let added = total.addingReportingOverflow(multiplied.partialValue)
            guard !added.overflow else { return nil }
            total = added.partialValue
            digits = ""
            priorUnitRank = rank
            sawUnit = true
        }

        guard sawUnit, digits.isEmpty, total <= Int64(Int.max) else { return nil }
        return Int(total)
    }

    private static func checkedInteger(_ value: String) -> Int? {
        guard let parsed = Int64(value), parsed <= Int64(Int.max) else { return nil }
        return Int(parsed)
    }
}

// MARK: - Transcript models

struct YouTubeTranscriptCue: Codable, Equatable, Sendable {
    let text: String
    let startMs: Int
    let durationMs: Int
    /// High-confidence speaker evidence carried by the caption format itself
    /// (for example a WebVTT `<v Alice>` span). Textual prefixes such as
    /// `>> ALICE:` are interpreted later by the Foundation-only semantic
    /// analyzer so every extraction lane follows the same conservative rules.
    let speaker: String?

    init(
        text: String,
        startMs: Int,
        durationMs: Int = 0,
        speaker: String? = nil
    ) {
        self.text = text
        self.startMs = startMs
        self.durationMs = durationMs
        self.speaker = speaker
    }
}

struct YouTubeTranscriptParagraph: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    /// Original visible caption text. Accessibility annotations and speaker
    /// labels stay here even when they are intentionally not narrated.
    let text: String
    /// Text prepared specifically for TTS. `nil` means a legacy cached
    /// paragraph and falls back to `text`; an empty string explicitly marks a
    /// visible, non-spoken caption such as `[Music]`.
    let speechText: String?
    let startMs: Int
    let speaker: String?

    init(
        id: Int,
        text: String,
        speechText: String? = nil,
        startMs: Int,
        speaker: String? = nil
    ) {
        self.id = id
        self.text = text
        self.speechText = speechText
        self.startMs = startMs
        self.speaker = speaker
    }

    var resolvedSpeechText: String { speechText ?? text }
}

struct YouTubeCaptionTrack: Codable, Equatable, Sendable {
    let baseURL: String
    let languageCode: String
    let name: String?
    let kind: String?

    var isAutomatic: Bool { kind?.lowercased() == "asr" }

    init(baseURL: String, languageCode: String, name: String? = nil, kind: String? = nil) {
        self.baseURL = baseURL
        self.languageCode = languageCode
        self.name = name
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case languageCode
        case name
        case kind
    }

    private struct NamePayload: Codable {
        struct Run: Codable {
            let text: String
        }

        let simpleText: String?
        let runs: [Run]?

        var flattened: String? {
            if let simpleText, !simpleText.isEmpty { return simpleText }
            let joined = (runs ?? []).map(\.text).joined()
            return joined.isEmpty ? nil : joined
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try container.decode(String.self, forKey: .baseURL)
        languageCode = try container.decode(String.self, forKey: .languageCode)
        if let plain = try? container.decode(String.self, forKey: .name) {
            name = plain
        } else {
            name = try? container.decode(NamePayload.self, forKey: .name).flattened
        }
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(baseURL, forKey: .baseURL)
        try container.encode(languageCode, forKey: .languageCode)
        if let name {
            try container.encode(
                NamePayload(simpleText: name, runs: nil),
                forKey: .name
            )
        }
        try container.encodeIfPresent(kind, forKey: .kind)
    }
}

/// One caption track the page offered, as shown in the language picker.
///
/// This type deliberately has no URL field. YouTube's `baseUrl` is a
/// short-lived signed credential; the extraction adapter never returns it and a
/// list that is cached on disk must never become the place it leaks.
struct YouTubeCaptionTrackOption: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let languageCode: String
    let name: String?
    let kind: String?

    init(id: String, languageCode: String, name: String? = nil, kind: String? = nil) {
        self.id = id
        self.languageCode = languageCode
        self.name = name
        self.kind = kind
    }

    var isAutomatic: Bool { kind?.lowercased() == "asr" }

    /// Stable key for UI/cache state. The picker intentionally keeps manual
    /// and automatic captions as separate choices even when both use the same
    /// base language.
    var selectionKey: String {
        let base = YouTubeTrackSelector.baseLanguage(languageCode)
        return "\(base)|\(isAutomatic ? "asr" : "manual")"
    }

    /// Whether CastReader can narrate this track at all. An unsupported
    /// language stays visible in the picker — the user still wants to know the
    /// video carries it — but cannot be selected.
    var isPlayable: Bool {
        (try? YouTubeTranscriptLanguagePolicy.playbackLanguage(for: languageCode)) != nil
    }

    /// Whether this option describes the track a transcript was built from.
    /// Track identity is the primary signal; language + kind is the fallback
    /// for transcripts whose route could not bind a stable track id.
    func matches(_ track: YouTubeCaptionTrack) -> Bool {
        if id == track.baseURL { return true }
        return YouTubeTrackSelector.baseLanguage(languageCode)
            == YouTubeTrackSelector.baseLanguage(track.languageCode)
            && isAutomatic == track.isAutomatic
    }

    /// Page-provided lists are untrusted input: drop entries without a usable
    /// language, collapse duplicates and bound the count so one malformed
    /// response cannot bloat every cached transcript.
    ///
    /// De-duplication is by *base* language + kind. `en-US` and `en-GB` are one
    /// choice as far as the reader is concerned — both narrate with the same
    /// English voice — and listing them separately would only ask the user to
    /// pick between two identical-looking rows.
    static func normalized(_ options: [YouTubeCaptionTrackOption]) -> [YouTubeCaptionTrackOption] {
        var seen = Set<String>()
        var result: [YouTubeCaptionTrackOption] = []
        for option in options {
            let language = option.languageCode
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !language.isEmpty, !option.id.isEmpty else { continue }
            let kind = option.isAutomatic ? "asr" : "manual"
            let base = YouTubeTrackSelector.baseLanguage(language)
            guard seen.insert("\(base)|\(kind)").inserted else { continue }
            result.append(
                YouTubeCaptionTrackOption(
                    id: option.id,
                    languageCode: language,
                    name: option.name?.trimmingCharacters(in: .whitespacesAndNewlines),
                    kind: kind
                )
            )
            if result.count >= maximumOptionCount { break }
        }
        return result
    }

    static let maximumOptionCount = 40
}

/// A specific track the user asked for. Unlike the first-open preference, this
/// is an explicit choice: the adapter must not silently fall back to another
/// language when it cannot be fetched.
struct YouTubeTrackRequest: Equatable, Sendable {
    let id: String
    let languageCode: String
    let isAutomatic: Bool

    init(id: String, languageCode: String, isAutomatic: Bool) {
        self.id = id
        self.languageCode = languageCode
        self.isAutomatic = isAutomatic
    }

    init(option: YouTubeCaptionTrackOption) {
        self.init(
            id: option.id,
            languageCode: option.languageCode,
            isAutomatic: option.isAutomatic
        )
    }

    /// Refreshes a cached track whose signed URL/legacy identity may no longer
    /// be valid. Prefer a stable option id when the cached track list has one;
    /// otherwise pin by language + manual/ASR kind.
    init(refreshing document: YouTubeTranscriptDocument) {
        if let option = document.availableTracks?.first(where: {
            $0.matches(document.track) &&
                !$0.id.lowercased().hasPrefix("http://") &&
                !$0.id.lowercased().hasPrefix("https://")
        }) {
            self.init(option: option)
        } else {
            self.init(
                id: "",
                languageCode: document.track.languageCode,
                isAutomatic: document.track.isAutomatic
            )
        }
    }

    var kind: String { isAutomatic ? "asr" : "manual" }
}

enum YouTubeTrackSelector {
    static func baseLanguage(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }

    /// Matches the shipping extension policy: preferred manual, preferred ASR,
    /// English manual, English ASR, then the first available track.
    static func selectBest(
        from tracks: [YouTubeCaptionTrack],
        preferredLanguage: String
    ) -> YouTubeCaptionTrack? {
        guard !tracks.isEmpty else { return nil }
        let preferred = baseLanguage(preferredLanguage)
        func matches(_ track: YouTubeCaptionTrack, _ language: String) -> Bool {
            !language.isEmpty && baseLanguage(track.languageCode) == language
        }
        return tracks.first { matches($0, preferred) && !$0.isAutomatic }
            ?? tracks.first { matches($0, preferred) }
            ?? tracks.first { matches($0, "en") && !$0.isAutomatic }
            ?? tracks.first { matches($0, "en") }
            ?? tracks[0]
    }
}

// MARK: - Caption semantics

/// Version of the deterministic cue-to-speech contract. Raw transcript and
/// artwork cache identity deliberately stays stable across rule upgrades;
/// generated audio and paragraph-index progress carry this version instead.
enum YouTubeCaptionSemanticSchema {
    static let current = 3
}

/// YouTube captions contain both dialogue and visual accessibility metadata.
/// This analyzer keeps the source cue untouched while deriving conservative
/// speech text, speaker turns and natural TTS paragraph boundaries.
///
/// The implementation is Foundation-only because `YouTubeTranscript.swift` is
/// shared with the Share Extension target.
enum YouTubeCaptionSemanticAnalyzer {
    /// A bracketed caption span is classified before any text is removed.
    /// Keeping category, placement, disposition and evidence separate prevents
    /// the cleaner from turning into an order-dependent collection of regexes.
    enum SemanticLabelCategory: String, Hashable {
        case music
        case audienceReaction
        case ambientSound
        case mixedSound
        case delivery
        case unavailable
        case role
        case unknown

        var clearsDialogueContext: Bool {
            switch self {
            case .music, .audienceReaction, .ambientSound, .mixedSound, .unavailable:
                return true
            case .delivery, .role, .unknown:
                return false
            }
        }
    }

    enum SemanticLabelPosition: String, Equatable {
        case entireCue
        case leading
        case inline
        case trailing
    }

    enum SemanticLabelDisposition: String, Equatable {
        /// Accessibility metadata that must not reach TTS.
        case suppress
        /// A leading role label establishes speaker state but is not spoken.
        case extractSpeaker
        /// Unknown or prose-ambiguous content remains verbatim (fail open).
        case preserve
    }

    enum SemanticLabelEvidence: String, Equatable {
        case exactTaxonomy
        case unavailableTimestamp
        case unavailablePlaceholder
        case composedEventGrammar
        case ambientEventGrammar
        case musicNotation
        case unknown
    }

    enum SemanticLabelConfidence: String, Equatable {
        case high
        case medium
        case unknown
    }

    enum SemanticLabelDecisionReason: String, Equatable {
        case classifiedAccessibilityMetadata
        case leadingRole
        case inlineRoleAmbiguity
        case inlineParentheticalAmbiguity
        case unknownFailOpen
    }

    struct SemanticLabelSpan: Equatable {
        /// UTF-16 range in this cleaning stage's input. It is deliberately not
        /// named `sourceRange`: a second pass may run after prefix projection.
        let inputRange: NSRange
        let rawText: String
        let normalizedText: String
        let category: SemanticLabelCategory
        let position: SemanticLabelPosition
        let disposition: SemanticLabelDisposition
        let evidence: SemanticLabelEvidence
        let confidence: SemanticLabelConfidence
        let decisionReason: SemanticLabelDecisionReason
        let role: String?

        var isRemoved: Bool {
            disposition != .preserve
        }

        var clearsDialogueContext: Bool {
            isRemoved && category.clearsDialogueContext
        }
    }

    private struct LabelClassification {
        let category: SemanticLabelCategory
        let evidence: SemanticLabelEvidence
        let confidence: SemanticLabelConfidence
        let role: String?

        init(
            category: SemanticLabelCategory,
            evidence: SemanticLabelEvidence,
            confidence: SemanticLabelConfidence = .high,
            role: String? = nil
        ) {
            self.category = category
            self.evidence = evidence
            self.confidence = confidence
            self.role = role
        }
    }

    private struct SpeakerPrefix {
        let text: String
        let speaker: String?
        let speakerIdentity: String?
        let explicitTurn: Bool
    }

    private struct NormalizedCue {
        let source: YouTubeTranscriptCue
        let sourceIndex: Int
        /// Line breaks remain semantic turn boundaries until display projection.
        let semanticText: String
        let displayText: String
        let productionMetadata: Bool
    }

    private struct SemanticDocument {
        let cues: [NormalizedCue]
        let speakers: SpeakerRegistry
    }

    private enum SpeakerBoundary {
        case cueStart
        case lineBreak
        case explicitMarker
        case sentenceTerminal
    }

    private struct SpeakerCandidateSpan {
        let label: String
        let key: String
        /// UTF-16 offsets in the normalized semantic cue.
        let turnStart: Int
        let prefixEnd: Int
        let boundary: SpeakerBoundary
    }

    private struct SpeakerObservation {
        let label: String
        let key: String
        let cueIndex: Int
        let startMs: Int
        let durationMs: Int
        let payload: String
        let boundary: SpeakerBoundary
    }

    private struct SpeakerRegistry {
        let confirmedKeys: Set<String>
        let blockedKeys: Set<String>
        /// Aliases share identity without rewriting the source-visible label.
        let identityByKey: [String: String]

        func isConfirmed(_ key: String) -> Bool {
            confirmedKeys.contains(key) && !blockedKeys.contains(key)
        }

        func identity(_ key: String) -> String {
            identityByKey[key] ?? key
        }
    }

    private struct AnalyzedCue {
        let source: YouTubeTranscriptCue
        let displayText: String
        var speechText: String
        let speaker: String?
        let speakerIdentity: String?
        let explicitTurn: Bool
        let boundaryBefore: Bool
        let boundaryAfter: Bool
        var rollingComparisonText: String
        var suppressedRollingDuplicate: Bool = false
    }

    private struct LabelRemoval {
        let text: String
        let speaker: String?
        let spans: [SemanticLabelSpan]

        var boundaryBefore: Bool {
            spans.contains {
                $0.isRemoved && ($0.position == .leading || $0.position == .entireCue)
            }
        }

        var boundaryAfter: Bool {
            spans.contains {
                $0.isRemoved && ($0.position == .trailing || $0.position == .entireCue)
            }
        }

        var removedEvent: Bool {
            spans.contains { $0.clearsDialogueContext }
        }

        var clearsDialogueBefore: Bool {
            spans.contains {
                $0.clearsDialogueContext &&
                    ($0.position == .leading || $0.position == .entireCue)
            }
        }

        var clearsDialogueAfter: Bool {
            spans.contains {
                $0.clearsDialogueContext &&
                    ($0.position == .trailing || $0.position == .entireCue)
            }
        }
    }

    private struct MusicRemoval {
        let text: String
        let boundaryBefore: Bool
        let boundaryAfter: Bool
        let containedNotes: Bool
    }

    private struct TurnPiece {
        let text: String
        let displayText: String
        let explicitTurn: Bool
        /// A syntactically valid label immediately follows the marker.
        let markerSpeakerCandidate: Bool
        /// UTF-16 offsets in the normalized semantic cue.
        let startOffset: Int
        let endOffset: Int
    }

    private static let hardGapMs = 1_200
    private static let softGapMs = 600
    private static let maximumParagraphUTF16 = 240
    private static let maximumParagraphWords = 42
    private static let maximumParagraphSpanMs = 15_000
    private static let maximumCueDurationForBoundaryMs = 30_000

    private static let musicNotes = CharacterSet(charactersIn: "♪♫♩♬🎵🎶")
    private static let terminalCharacters: Set<Character> = [
        ".", "!", "?", ";", "。", "！", "？", "；", "…", "।", "॥"
    ]
    private static let closingCharacters: Set<Character> = [
        "\"", "'", "»", "’", "”", ")", "]", "）", "】", "」", "』", "〉", "》"
    ]
    private static let softBoundaryCharacters: Set<Character> = [
        ",", "，", ":", "：", "—", "–"
    ]
    private static let abbreviations: Set<String> = [
        "abb", "bsp", "bzw", "ca", "dr", "e.g", "etc", "ggf", "i.e",
        "inkl", "kap", "mr", "mrs", "ms", "nr", "prof", "s", "sog",
        "st", "u", "u.k", "u.s", "a.m", "p.m", "ph.d", "usw", "vgl", "vs", "z"
    ]
    private static let deniedSpeakerLabels: Set<String> = [
        "chapter", "section", "part", "step", "note", "warning", "example",
        "question", "answer", "summary", "agenda", "tip", "definition",
        "reason", "result", "source", "title", "topic", "date", "time", "url", "api",
        "章节", "章節", "部分",
        "步骤", "步驟", "注意", "示例", "标题", "標題", "主题", "主題",
        "capítulo", "sección", "seção", "chapitre", "abschnitt", "kapitel",
        "capitolo", "sezione"
    ]
    /// These labels describe the caption asset, never an in-video speaker.
    private static let productionCreditLabels: Set<String> = [
        "transcriber", "transcription", "transcribed by", "reviewer", "reviewed by",
        "translator", "translated by", "translation", "captions by", "captioned by",
        "subtitles by", "subtitle editor", "synchronization", "synced by",
        "字幕", "字幕制作", "字幕製作", "字幕翻译", "字幕翻譯", "翻译", "翻譯",
        "校对", "校對", "审校", "審校", "时间轴", "時間軸", "听译", "聽譯",
        "文字起こし", "翻訳", "校正", "transcripción", "transcriptor", "revisión",
        "revisor", "traducción", "traductor", "subtítulos", "transcription",
        "révision", "traducteur", "sous-titres", "transkription", "übersetzung",
        "untertitel", "trascrizione", "revisione", "traduzione", "sottotitoli"
    ]
    private static let productionSpeakerDenials = Set(
        productionCreditLabels.map(normalizedTaxonomyKey)
    )
    private static let speakerDeniedKeys = deniedSpeakerLabels.union(
        productionSpeakerDenials
    )
    private static let productionCreditFieldRegex: NSRegularExpression? = {
        let alternatives = productionCreditLabels
            .sorted { $0.count > $1.count }
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        return try? NSRegularExpression(
            pattern: "(?:^|[\\s\\p{Z}\\u0085])(\(alternatives))\\s*[:：]\\s*",
            options: [.caseInsensitive]
        )
    }()
    private static let nameParticles: Set<String> = [
        "al", "bin", "da", "de", "del", "della", "di", "dos", "du", "la", "le",
        "van", "von", "der", "den", "ter", "ten", "y", "e"
    ]
    /// Repetition alone is weak evidence: tutorial and status captions commonly repeat these
    /// discourse/entity headings. This is a semantic class guard, not a per-video denylist.
    private static let nonPersonHeadingLabels: Set<String> = [
        "user", "status", "input", "output", "system", "error", "result", "request",
        "response", "client", "server", "browser", "device", "model", "example", "exercise",
        "problem", "solution", "code", "command", "terminal", "console", "warning", "note",
        "context", "prompt", "assistant", "api", "cpu", "gpu", "url", "step", "chapter",
        "section", "question", "answer", "summary", "topic", "title", "source", "date", "time"
    ]
    private static let nonPersonHeadingTokens = Set(
        nonPersonHeadingLabels.flatMap { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
    )
    private static let numberedRoleLabels: Set<String> = [
        "speaker", "voice", "person", "man", "woman", "host", "guest",
        "说话者", "說話者", "角色", "人物", "sprecher", "sprecherin"
    ]
    private static let roleLabels: Set<String> = [
        "narrator", "host", "guest", "speaker", "interviewer", "interviewee",
        "moderator", "man", "woman", "male voice", "female voice", "voiceover",
        "voice-over", "旁白", "主持人", "嘉宾", "嘉賓", "说话者", "說話者",
        "男声", "男聲", "女声", "女聲", "ナレーター", "司会", "ゲスト",
        "narrador", "narradora", "presentador", "presentadora", "invitado",
        "invitada", "narrateur", "narratrice", "animateur", "animatrice",
        "erzähler", "erzählerin", "moderatorin", "sprecher", "sprecherin",
        "narratore", "narratrice", "conduttore", "conduttrice", "वाचक", "मेज़बान"
    ]
    private static let musicLabels: Set<String> = [
        "music", "background music", "instrumental", "singing",
        "音乐", "音樂", "背景音乐", "背景音樂", "歌声", "歌聲",
        "音楽", "bgm", "歌声", "música", "música de fondo", "cantando",
        "musique", "musique de fond", "musik", "hintergrundmusik",
        "música de fundo", "musica", "musica di sottofondo", "संगीत", "पृष्ठभूमि संगीत"
    ]
    private static let reactionLabels: Set<String> = [
        "laughter", "laughing", "laughs", "chuckles", "applause", "clapping",
        "cheering", "audience laughter", "笑声", "笑聲", "笑い声", "笑い",
        "掌声", "掌聲", "拍手", "欢呼", "歡呼", "歓声", "risas", "risa",
        "aplausos", "rires", "rire", "applaudissements", "gelächter", "lachen",
        "applaus", "risadas", "risos", "risate", "applausi", "हँसी", "तालियाँ"
    ]
    private static let ambientLabels: Set<String> = [
        "coughing", "coughs", "sigh", "sighs", "breathing", "gasps", "gasping",
        "footsteps", "door slams", "door closes", "door opens", "phone rings",
        "ringing", "thunder", "explosion", "crowd noise", "background noise",
        "wind", "rain", "traffic noise", "咳嗽", "叹气", "嘆氣", "喘息",
        "脚步声", "腳步聲", "关门声", "關門聲", "电话铃声", "電話鈴聲",
        "雷声", "雷聲", "爆炸声", "爆炸聲", "人群声", "人群聲", "雨声", "雨聲",
        "咳", "ため息", "息遣い", "足音", "ドアの音", "電話の音", "雷", "爆発音",
        "tos", "suspiro", "respiración", "pasos", "trueno", "explosión",
        "toux", "soupir", "respiration", "pas", "tonnerre", "explosion",
        "husten", "seufzen", "atmen", "schritte", "donner", "explosion",
        "tosse", "suspiro", "respiração", "passos", "trovão", "esplosione",
        "खाँसी", "आह", "साँस", "कदमों की आहट", "गरज", "विस्फोट"
    ]
    private static let deliveryLabels: Set<String> = [
        "whispering", "whispers", "shouting", "yelling", "screaming", "softly",
        "quietly", "sarcastically", "crying", "mumbling", "低声", "低聲", "耳语",
        "耳語", "小声", "小聲", "喊叫", "尖叫", "轻声", "輕聲", "讽刺地", "諷刺地",
        "哭泣", "ささやき", "小声で", "叫ぶ", "悲鳴", "泣きながら",
        "susurrando", "gritando", "en voz baja", "llorando", "chuchotant",
        "criant", "doucement", "en pleurant", "flüsternd", "schreiend", "leise",
        "weinend", "sussurrando", "gridando", "piano", "piangendo",
        "फुसफुसाते हुए", "चिल्लाते हुए", "धीरे से", "रोते हुए"
    ]
    private static let unavailableLabels: Set<String> = [
        "inaudible", "unintelligible", "indistinct speech", "audio unclear", "crosstalk",
        "听不清", "聽不清", "无法听清", "無法聽清", "语音不清", "語音不清",
        "聞き取れない", "不明瞭", "inaudible", "ininteligible", "audio poco claro",
        "inaudible", "incompréhensible", "audio indistinct", "unverständlich",
        "undeutlich", "inaudível", "ininteligível", "non udibile", "incomprensibile",
        "अस्पष्ट", "सुनाई नहीं दे रहा"
    ]
    private static let eventModifiers: Set<String> = [
        "background", "soft", "softly", "quiet", "quietly", "upbeat", "dramatic",
        "suspenseful", "gentle", "loud", "distant", "faint", "audience", "crowd",
        "背景", "轻柔", "輕柔", "欢快", "歡快", "激昂", "远处", "遠處"
    ]
    private static let eventLinkWords: Set<String> = ["and", "with", "y", "et", "und", "e"]
    private static let eventActivityWords: Set<String> = [
        "playing", "plays", "continues", "starts", "stops", "fades", "fading"
    ]
    /// Open event grammar: noun/activity pairs cover unseen descriptions without video cases.
    private static let ambientEventNouns: Set<String> = [
        "bird", "birds", "door", "doors", "phone", "phones", "baby", "babies", "engine",
        "engines", "audience", "crowd", "people", "dog", "dogs", "cat", "cats", "wind",
        "rain", "thunder", "traffic", "footstep", "footsteps", "bell", "bells", "alarm",
        "alarms", "siren", "sirens", "glass", "gunshot", "gunshots", "fireworks", "water",
        "waves", "car", "cars", "train", "trains", "airplane", "airplanes", "laughter",
        "applause", "music", "voice", "voices", "speech", "language"
    ]
    private static let ambientEventActivities: Set<String> = [
        "chirping", "tweeting", "creaking", "slamming", "closing", "opening", "ringing",
        "crying", "revving", "applauding", "clapping", "cheering", "laughing", "barking",
        "meowing", "howling", "blowing", "falling", "raining", "rumbling", "honking",
        "beeping", "buzzing", "whistling", "crashing", "breaking", "firing", "exploding",
        "splashing", "flowing", "roaring", "passing", "approaching", "departing", "singing",
        "speaking", "talking", "shouting", "screaming", "coughing", "breathing", "gasping"
    ]
    private static let ambientEventQualifiers: Set<String> = [
        "foreign", "indistinct", "unintelligible", "background", "distant", "nearby", "loud",
        "soft", "multiple", "several", "continuous", "language", "noise", "sound", "sounds"
    ]
    private static let commonNonNameWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "continue", "for", "from",
        "has", "have", "in", "into", "is", "it", "of", "on", "or", "press", "the",
        "this", "to", "use", "was", "were", "will", "with", "you", "your"
    ]

    static func paragraphs(
        from cues: [YouTubeTranscriptCue]
    ) -> [YouTubeTranscriptParagraph] {
        guard cues.count <= 200_000 else { return [] }
        let sorted = cues.enumerated().sorted { lhs, rhs in
            if lhs.element.startMs != rhs.element.startMs {
                return lhs.element.startMs < rhs.element.startMs
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
        guard !sorted.isEmpty else { return [] }

        let document = buildSemanticDocument(from: sorted)
        var activeSpeaker: String?
        var activeSpeakerIdentity: String?
        var analyzed: [AnalyzedCue] = []
        analyzed.reserveCapacity(sorted.count)

        for normalizedCue in document.cues {
            let cue = normalizedCue.source
            let display = normalizedCue.displayText
            if normalizedCue.productionMetadata {
                analyzed.append(
                    AnalyzedCue(
                        source: cue,
                        displayText: display,
                        speechText: "",
                        speaker: nil,
                        speakerIdentity: nil,
                        explicitTurn: false,
                        boundaryBefore: true,
                        boundaryAfter: true,
                        rollingComparisonText: ""
                    )
                )
                activeSpeaker = nil
                activeSpeakerIdentity = nil
                continue
            }
            let structuredSpeaker = normalizedSpeaker(cue.speaker)
            let structuredIdentity = structuredSpeaker.map(normalizedLabel)
                .map(document.speakers.identity)
            let turnPieces = splitTurns(
                normalizedCue.semanticText,
                speakers: document.speakers
            )
            for (pieceIndex, piece) in turnPieces.enumerated() {
                let leadingLabels = removeSemanticLabels(
                    from: piece.text,
                    initialSpeaker: structuredSpeaker
                )
                // A scene event before speech terminates inherited dialogue state. Clear it before
                // resolving a following explicit prefix so a new turn can establish its own role.
                if leadingLabels.clearsDialogueBefore {
                    activeSpeaker = nil
                    activeSpeakerIdentity = nil
                }
                let prefixCandidate = rawSpeakerCandidate(in: leadingLabels.text)
                let prefixCandidateKey = prefixCandidate.map { normalizedLabel($0.candidate) }
                let labelCreatedTurnEvidence = leadingLabels.boundaryBefore &&
                    prefixCandidate.map { isNameLikeSpeakerLabel($0.candidate) } == true &&
                    prefixCandidate.map { isUppercaseSpeakerLabel($0.candidate) } == true &&
                    !(prefixCandidateKey.map(speakerDeniedKeys.contains) ?? false)
                let markerCreatedTurnEvidence = piece.markerSpeakerCandidate &&
                    !(prefixCandidateKey.map(speakerDeniedKeys.contains) ?? false)
                let canUseTurnContextAsNameEvidence =
                    (labelCreatedTurnEvidence || markerCreatedTurnEvidence) &&
                    !(prefixCandidateKey.map(document.speakers.blockedKeys.contains) ?? false)
                let prefix = speakerPrefix(
                    in: leadingLabels.text,
                    structuredSpeaker: structuredSpeaker,
                    speakers: document.speakers,
                    allowsUppercaseEvidence: canUseTurnContextAsNameEvidence
                )
                let labels = removeSemanticLabels(
                    from: prefix.text,
                    initialSpeaker: prefix.speaker ?? leadingLabels.speaker
                )
                let music = removeMusicNotes(from: labels.text)
                let speech = collapseWhitespace(music.text)

                let explicitTurn = piece.explicitTurn || prefix.explicitTurn
                let explicitSpeaker = normalizedSpeaker(labels.speaker ?? prefix.speaker)
                let explicitSpeakerIdentity = prefix.speakerIdentity ??
                    explicitSpeaker.map(normalizedLabel).map(document.speakers.identity) ??
                    structuredIdentity
                let speakerChanged = explicitSpeakerIdentity != nil &&
                    explicitSpeakerIdentity != activeSpeakerIdentity
                if explicitTurn && explicitSpeaker == nil {
                    activeSpeaker = nil
                    activeSpeakerIdentity = nil
                } else if let explicitSpeaker {
                    activeSpeaker = explicitSpeaker
                    activeSpeakerIdentity = explicitSpeakerIdentity
                }
                let resolvedSpeaker = explicitSpeaker ?? activeSpeaker
                let resolvedSpeakerIdentity = explicitSpeakerIdentity ?? activeSpeakerIdentity
                let isSpeakable = containsSpeakableContent(speech)
                let clearsActiveSpeaker =
                    leadingLabels.clearsDialogueAfter ||
                    labels.clearsDialogueAfter ||
                    (music.containedNotes && music.boundaryAfter) ||
                    (!isSpeakable &&
                        (leadingLabels.removedEvent || labels.removedEvent ||
                            music.containedNotes))
                analyzed.append(
                    AnalyzedCue(
                        source: projectedCue(
                            cue,
                            piece: piece,
                            totalLength: (normalizedCue.semanticText as NSString).length
                        ),
                        displayText: collapseWhitespace(piece.displayText),
                        speechText: isSpeakable ? speech : "",
                        speaker: isSpeakable ? resolvedSpeaker : nil,
                        speakerIdentity: isSpeakable ? resolvedSpeakerIdentity : nil,
                        explicitTurn: explicitTurn,
                        boundaryBefore: explicitTurn || pieceIndex > 0 || speakerChanged ||
                            leadingLabels.boundaryBefore || labels.boundaryBefore ||
                            music.boundaryBefore || !isSpeakable,
                        boundaryAfter: leadingLabels.boundaryAfter || labels.boundaryAfter ||
                            music.boundaryAfter || !isSpeakable || pieceIndex < turnPieces.count - 1,
                        rollingComparisonText: speech
                    )
                )
                // Role-only cues establish the following turn. Scene events and unavailable audio
                // still clear the role so it cannot leak across a scene boundary.
                if clearsActiveSpeaker {
                    activeSpeaker = nil
                    activeSpeakerIdentity = nil
                }
            }
        }

        // Rolling captions repeat a whole logical cue. Remove that overlap
        // before sentence splitting; otherwise A1/A2/B1/B2 comparisons can
        // miss that B is an update of A and narrate the same text twice.
        suppressRollingDuplicates(&analyzed)
        let splitCues = analyzed.flatMap { cue in
            cue.suppressedRollingDuplicate ? [cue] : splitAnalyzedCueIfNeeded(cue)
        }
        return group(splitCues)
    }

    private static func splitAnalyzedCueIfNeeded(
        _ cue: AnalyzedCue
    ) -> [AnalyzedCue] {
        guard !cue.speechText.isEmpty else { return [cue] }
        let chunks = naturalSpeechChunks(
            cue.speechText,
            durationMs: cue.source.durationMs
        )
        guard chunks.count > 1 else { return [cue] }
        let displayChunks = mappedDisplayChunks(
            speechChunks: chunks,
            in: cue.displayText
        ) ?? proportionalDisplayChunks(
            speechChunks: chunks,
            displayText: cue.displayText
        )
        guard displayChunks.count == chunks.count else { return [cue] }

        let totalLength = max(1, (cue.speechText as NSString).length)
        let boundedDuration = min(
            max(0, cue.source.durationMs),
            maximumCueDurationForBoundaryMs
        )
        var consumedLength = 0
        return chunks.enumerated().map { index, chunk in
            let chunkLength = (chunk as NSString).length
            let startDelta = boundedDuration * consumedLength / totalLength
            let endDelta = boundedDuration * min(
                totalLength,
                consumedLength + chunkLength
            ) / totalLength
            consumedLength += chunkLength
            let start = cue.source.startMs.addingReportingOverflow(startDelta)
            return AnalyzedCue(
                source: YouTubeTranscriptCue(
                    text: displayChunks[index],
                    startMs: start.overflow ? cue.source.startMs : start.partialValue,
                    durationMs: max(0, endDelta - startDelta),
                    speaker: cue.source.speaker
                ),
                displayText: displayChunks[index],
                speechText: chunk,
                speaker: cue.speaker,
                speakerIdentity: cue.speakerIdentity,
                explicitTurn: index == 0 && cue.explicitTurn,
                boundaryBefore: index == 0 ? cue.boundaryBefore : true,
                boundaryAfter: index == chunks.count - 1 ? cue.boundaryAfter : true,
                rollingComparisonText: chunk
            )
        }
    }

    private static func naturalSpeechChunks(
        _ text: String,
        durationMs: Int
    ) -> [String] {
        let characters = Array(text)
        var sentences: [String] = []
        var start = 0
        var index = 0
        while index < characters.count {
            guard terminalCharacters.contains(characters[index]) else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < characters.count,
                  closingCharacters.contains(characters[end + 1]) {
                end += 1
            }
            let candidate = String(characters[start...end])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let nextIsNaturalStart = end + 1 >= characters.count ||
                characters[end + 1].isWhitespace ||
                isCJKOrKana(characters[end + 1])
            if !candidate.isEmpty,
               nextIsNaturalStart,
               hasTerminalBoundary(candidate) {
                sentences.append(candidate)
                start = end + 1
                while start < characters.count, characters[start].isWhitespace {
                    start += 1
                }
                index = start
            } else {
                index = end + 1
            }
        }
        if start < characters.count {
            let tail = String(characters[start...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty { sentences.append(tail) }
        }
        if sentences.isEmpty { sentences = [text] }

        var result = sentences.flatMap(splitOversizedSpeechChunk)
        let boundedDuration = min(
            max(0, durationMs),
            maximumCueDurationForBoundaryMs
        )
        let desiredForDuration = max(
            1,
            (boundedDuration + maximumParagraphSpanMs - 1) /
                maximumParagraphSpanMs
        )
        if (1...maximumCueDurationForBoundaryMs).contains(durationMs),
           desiredForDuration > result.count {
            result = splitChunksForDuration(
                result,
                desiredCount: desiredForDuration
            )
        }
        return result
    }

    private static func splitChunksForDuration(
        _ chunks: [String],
        desiredCount: Int
    ) -> [String] {
        var result = chunks
        while result.count < desiredCount {
            guard let index = result.indices.max(by: {
                result[$0].count < result[$1].count
            }),
            let split = splitSpeechChunkNearMiddle(result[index]) else {
                break
            }
            result.replaceSubrange(index...index, with: split)
        }
        return result
    }

    private static func splitSpeechChunkNearMiddle(_ text: String) -> [String]? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.count >= 2 {
            let middle = (tokens.count + 1) / 2
            return [
                tokens[..<middle].joined(separator: " "),
                tokens[middle...].joined(separator: " ")
            ]
        }
        let characters = Array(text)
        guard characters.count >= 2 else { return nil }
        let middle = characters.count / 2
        let split = [
            String(characters[..<middle]).trimmingCharacters(in: .whitespacesAndNewlines),
            String(characters[middle...]).trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        return split.allSatisfy { !$0.isEmpty } ? split : nil
    }

    private static func splitOversizedSpeechChunk(_ text: String) -> [String] {
        guard (text as NSString).length > maximumParagraphUTF16 ||
                wordCount(text) > maximumParagraphWords else { return [text] }
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if words.count > 1 {
            var result: [String] = []
            var current = ""
            for word in words {
                let candidate = current.isEmpty ? word : current + " " + word
                if !current.isEmpty,
                   ((candidate as NSString).length > maximumParagraphUTF16 ||
                    wordCount(candidate) > maximumParagraphWords) {
                    result.append(current)
                    current = word
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty { result.append(current) }
            return result.flatMap(splitOversizedSpeechChunk)
        }

        var result: [String] = []
        var current = ""
        for character in text {
            let candidate = current + String(character)
            if (candidate as NSString).length > maximumParagraphUTF16 {
                if current.isEmpty {
                    // A single extended grapheme can itself exceed the cap
                    // (for example one base letter plus hundreds of combining
                    // marks). Split its UTF-16 representation without trapping
                    // or allowing unbounded TTS input.
                    result.append(contentsOf: splitOversizedGrapheme(String(character)))
                    current = ""
                } else {
                    result.append(current)
                    if (String(character) as NSString).length > maximumParagraphUTF16 {
                        result.append(contentsOf: splitOversizedGrapheme(String(character)))
                        current = ""
                    } else {
                        current = String(character)
                    }
                }
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func splitOversizedGrapheme(_ text: String) -> [String] {
        guard (text as NSString).length > maximumParagraphUTF16 else { return [text] }
        var result: [String] = []
        var current = String.UnicodeScalarView()
        var currentLength = 0
        for scalar in text.unicodeScalars {
            let scalarLength = scalar.value > 0xFFFF ? 2 : 1
            if currentLength + scalarLength > maximumParagraphUTF16,
               !current.isEmpty {
                result.append(String(current))
                current = String.UnicodeScalarView()
                currentLength = 0
            }
            current.append(scalar)
            currentLength += scalarLength
        }
        if !current.isEmpty { result.append(String(current)) }
        return result
    }

    private static func mappedDisplayChunks(
        speechChunks: [String],
        in displayText: String
    ) -> [String]? {
        let source = displayText as NSString
        var ranges: [NSRange] = []
        var cursor = 0
        for chunk in speechChunks {
            let found = source.range(
                of: chunk,
                options: [.caseInsensitive],
                range: NSRange(
                    location: cursor,
                    length: max(0, source.length - cursor)
                )
            )
            guard found.location != NSNotFound else { return nil }
            ranges.append(found)
            cursor = found.location + found.length
        }
        return ranges.enumerated().map { index, range in
            let start = index == 0
                ? 0
                : ranges[index - 1].location + ranges[index - 1].length
            let end = index == ranges.count - 1
                ? source.length
                : range.location + range.length
            return collapseWhitespace(source.substring(with: NSRange(
                location: start,
                length: max(0, end - start)
            )))
        }
    }

    /// Cleaning can replace an inline accessibility label with a pause, so a
    /// speech chunk is not always a literal substring of the visible caption.
    /// Fall back to a stable proportional partition of the untouched display
    /// text. This preserves every visible character while keeping the hard TTS
    /// paragraph cap enforceable.
    private static func proportionalDisplayChunks(
        speechChunks: [String],
        displayText: String
    ) -> [String] {
        guard speechChunks.count > 1 else { return [displayText] }
        let characters = Array(displayText)
        guard characters.count >= speechChunks.count else {
            return speechChunks
        }
        let weights = speechChunks.map { max(1, $0.count) }
        let totalWeight = max(1, weights.reduce(0, +))
        var accumulatedWeight = 0
        var cursor = 0
        var result: [String] = []
        result.reserveCapacity(speechChunks.count)

        for index in speechChunks.indices.dropLast() {
            accumulatedWeight += weights[index]
            let remainingChunks = speechChunks.count - index - 1
            let minimum = cursor + 1
            let maximum = characters.count - remainingChunks
            let ideal = min(
                maximum,
                max(minimum, characters.count * accumulatedWeight / totalWeight)
            )
            let boundary = nearestDisplayBoundary(
                in: characters,
                around: ideal,
                minimum: minimum,
                maximum: maximum
            )
            result.append(collapseWhitespace(String(characters[cursor..<boundary])))
            cursor = boundary
        }
        result.append(collapseWhitespace(String(characters[cursor...])))
        return result
    }

    private static func nearestDisplayBoundary(
        in characters: [Character],
        around ideal: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        guard minimum < maximum else { return minimum }
        let searchRadius = min(48, maximum - minimum)
        for distance in 0...searchRadius {
            let forward = ideal + distance
            if forward <= maximum,
               forward > minimum,
               isDisplayBoundary(characters[forward - 1]) {
                return forward
            }
            let backward = ideal - distance
            if backward >= minimum,
               backward <= maximum,
               isDisplayBoundary(characters[backward - 1]) {
                return backward
            }
        }
        return min(maximum, max(minimum, ideal))
    }

    private static func isDisplayBoundary(_ character: Character) -> Bool {
        character.isWhitespace || terminalCharacters.contains(character) ||
            softBoundaryCharacters.contains(character)
    }

    private static func splitTurns(
        _ text: String,
        speakers: SpeakerRegistry
    ) -> [TurnPiece] {
        splitExplicitTurns(text).flatMap {
            splitConfirmedColonTurns($0, speakers: speakers)
        }
    }

    /// Preserve explicit caption turns with UTF-16 source ranges so their
    /// timing can be projected without using already-cleaned speech text.
    private static func splitExplicitTurns(_ text: String) -> [TurnPiece] {
        let source = text as NSString
        guard let regex = try? NSRegularExpression(
            pattern: #"(?:^|\s)(>>|＞＞)\s*"#
        ) else {
            return [TurnPiece(
                text: text,
                displayText: text,
                explicitTurn: false,
                markerSpeakerCandidate: false,
                startOffset: 0,
                endOffset: source.length
            )]
        }
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else {
            return [TurnPiece(
                text: text,
                displayText: text,
                explicitTurn: false,
                markerSpeakerCandidate: false,
                startOffset: 0,
                endOffset: source.length
            )]
        }
        let acceptedMatches: [NSTextCheckingResult] = matches.enumerated().compactMap {
            (index: Int, match: NSTextCheckingResult) -> NSTextCheckingResult? in
            let marker = match.range(at: 1)
            guard isExplicitTurnMarkerBoundary(in: source, markerStart: marker.location) else {
                return nil
            }
            if index == 0 { return match }
            let end = index + 1 < matches.count
                ? matches[index + 1].range(at: 1).location
                : source.length
            guard end > marker.location else { return nil }
            let candidateText = source.substring(with: NSRange(
                location: marker.location,
                length: end - marker.location
            ))
            if let candidate = rawSpeakerCandidate(in: candidateText)?.candidate,
               validSpeakerCandidate(candidate) {
                return match
            }
            // Nameless `>>` is still a real caption turn after a complete
            // sentence. Require that evidence so bit-shift prose stays whole.
            let previousStart = matches[index - 1].range(at: 1).location
            guard marker.location > previousStart else { return nil }
            let previous = source.substring(with: NSRange(
                location: previousStart,
                length: marker.location - previousStart
            ))
            return hasTerminalBoundary(collapseWhitespace(previous)) ? match : nil
        }
        guard !acceptedMatches.isEmpty,
              acceptedMatches[0].range(at: 1).location == 0 else {
            return [TurnPiece(
                text: text,
                displayText: text,
                explicitTurn: false,
                markerSpeakerCandidate: false,
                startOffset: 0,
                endOffset: source.length
            )]
        }
        var pieces: [TurnPiece] = []
        for (index, match) in acceptedMatches.enumerated() {
            let marker = match.range(at: 1)
            let start = index == 0 ? 0 : marker.location
            let end = index + 1 < acceptedMatches.count
                ? acceptedMatches[index + 1].range(at: 1).location
                : source.length
            guard end > start else { continue }
            let candidateText = source.substring(with: NSRange(
                location: start,
                length: end - start
            ))
            let markerSpeakerCandidate = rawSpeakerCandidate(in: candidateText).map {
                validSpeakerCandidate($0.candidate) &&
                    !speakerDeniedKeys.contains(normalizedLabel($0.candidate)) &&
                    isNameLikeSpeakerLabel($0.candidate)
            } ?? false
            if let piece = turnPiece(
                source: text,
                start: start,
                end: end,
                explicitTurn: true,
                markerSpeakerCandidate: markerSpeakerCandidate
            ) {
                pieces.append(piece)
            }
        }
        return pieces.isEmpty ? [TurnPiece(
            text: text,
            displayText: text,
            explicitTurn: false,
            markerSpeakerCandidate: false,
            startOffset: 0,
            endOffset: source.length
        )] : pieces
    }

    private static func isExplicitTurnMarkerBoundary(
        in text: NSString,
        markerStart: Int
    ) -> Bool {
        if markerStart == 0 { return true }
        var cursor = markerStart - 1
        while cursor >= 0, isWhitespaceUnit(text, at: cursor) {
            cursor -= 1
        }
        if cursor < 0 { return true }
        if text.substring(with: NSRange(location: cursor, length: 1)) == "\n" {
            return true
        }
        return hasTerminalBoundary(text.substring(to: cursor + 1))
    }

    private static func splitConfirmedColonTurns(
        _ piece: TurnPiece,
        speakers: SpeakerRegistry
    ) -> [TurnPiece] {
        let starts = Array(Set(
            scanSpeakerCandidates(in: piece.text)
                .filter { speakers.isConfirmed($0.key) && $0.turnStart > 0 }
                .map(\.turnStart)
        )).sorted()
        guard !starts.isEmpty else { return [piece] }
        let length = (piece.text as NSString).length
        let boundaries = [0] + starts + [length]
        var result: [TurnPiece] = []
        for index in 0..<(boundaries.count - 1) {
            if let child = turnPiece(
                source: piece.text,
                start: boundaries[index],
                end: boundaries[index + 1],
                explicitTurn: piece.explicitTurn || boundaries[index] > 0,
                markerSpeakerCandidate: piece.markerSpeakerCandidate,
                baseOffset: piece.startOffset
            ) {
                result.append(child)
            }
        }
        return result.isEmpty ? [piece] : result
    }

    private static func turnPiece(
        source: String,
        start: Int,
        end: Int,
        explicitTurn: Bool,
        markerSpeakerCandidate: Bool = false,
        baseOffset: Int = 0
    ) -> TurnPiece? {
        let ns = source as NSString
        var lower = min(max(0, start), ns.length)
        var upper = min(max(lower, end), ns.length)
        while lower < upper,
              ns.substring(with: NSRange(location: lower, length: 1))
                .rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            lower += 1
        }
        while upper > lower,
              ns.substring(with: NSRange(location: upper - 1, length: 1))
                .rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            upper -= 1
        }
        guard lower < upper else { return nil }
        let value = ns.substring(with: NSRange(location: lower, length: upper - lower))
        return TurnPiece(
            text: value,
            displayText: value,
            explicitTurn: explicitTurn,
            markerSpeakerCandidate: markerSpeakerCandidate,
            startOffset: baseOffset + lower,
            endOffset: baseOffset + upper
        )
    }

    private static func projectedCue(
        _ source: YouTubeTranscriptCue,
        piece: TurnPiece,
        totalLength: Int
    ) -> YouTubeTranscriptCue {
        guard totalLength > 0,
              piece.startOffset > 0 || piece.endOffset < totalLength else {
            return source
        }
        let boundedDuration = min(
            max(0, source.durationMs),
            maximumCueDurationForBoundaryMs
        )
        let lower = min(max(0, piece.startOffset), totalLength)
        let upper = min(max(lower, piece.endOffset), totalLength)
        let startDelta = boundedDuration * lower / totalLength
        let endDelta = boundedDuration * upper / totalLength
        let start = source.startMs.addingReportingOverflow(startDelta)
        return YouTubeTranscriptCue(
            text: piece.displayText,
            startMs: start.overflow ? source.startMs : start.partialValue,
            durationMs: max(0, endDelta - startDelta),
            speaker: source.speaker
        )
    }

    private static func group(_ cues: [AnalyzedCue]) -> [YouTubeTranscriptParagraph] {
        struct Pending {
            var displayText: String
            var speechText: String
            var startMs: Int
            var endMs: Int
            var speaker: String?
            var speakerIdentity: String?
            var boundaryAfter: Bool
        }

        var result: [YouTubeTranscriptParagraph] = []
        var pending: Pending?

        func appendPending() {
            guard let value = pending else { return }
            result.append(
                YouTubeTranscriptParagraph(
                    id: result.count,
                    text: value.displayText,
                    speechText: value.speechText,
                    startMs: value.startMs,
                    speaker: value.speaker
                )
            )
            pending = nil
        }

        for cue in cues {
            let cueEnd = safeCueEnd(cue.source)
            if cue.speechText.isEmpty && !cue.suppressedRollingDuplicate {
                appendPending()
                result.append(
                    YouTubeTranscriptParagraph(
                        id: result.count,
                        text: cue.displayText,
                        speechText: "",
                        startMs: cue.source.startMs,
                        speaker: cue.speaker
                    )
                )
                continue
            }

            guard var current = pending else {
                if cue.suppressedRollingDuplicate { continue }
                pending = Pending(
                    displayText: cue.displayText,
                    speechText: cue.speechText,
                    startMs: cue.source.startMs,
                    endMs: cueEnd,
                    speaker: cue.speaker,
                    speakerIdentity: cue.speakerIdentity,
                    boundaryAfter: cue.boundaryAfter || hasTerminalBoundary(cue.speechText)
                )
                continue
            }

            if cue.suppressedRollingDuplicate {
                current.displayText = joinCaptionText(current.displayText, cue.displayText)
                current.endMs = max(current.endMs, cueEnd)
                current.boundaryAfter = current.boundaryAfter || cue.boundaryAfter
                pending = current
                continue
            }

            let gap = Int64(cue.source.startMs) - Int64(current.endMs)
            let speakerChanged = current.speakerIdentity != cue.speakerIdentity &&
                (current.speakerIdentity != nil || cue.speakerIdentity != nil)
            let prospectiveSpeech = joinCaptionText(current.speechText, cue.speechText)
            let prospectiveSpan = Int64(cueEnd) - Int64(current.startMs)
            let exceedsCap = (prospectiveSpeech as NSString).length > maximumParagraphUTF16 ||
                wordCount(prospectiveSpeech) > maximumParagraphWords ||
                prospectiveSpan > Int64(maximumParagraphSpanMs)
            let softBreak = gap >= Int64(softGapMs) &&
                ((current.speechText as NSString).length >= 100 ||
                 endsWithSoftBoundary(current.speechText))
            let shouldBreak = cue.boundaryBefore || current.boundaryAfter || speakerChanged ||
                gap >= Int64(hardGapMs) || softBreak || exceedsCap

            if shouldBreak {
                appendPending()
                pending = Pending(
                    displayText: cue.displayText,
                    speechText: cue.speechText,
                    startMs: cue.source.startMs,
                    endMs: cueEnd,
                    speaker: cue.speaker,
                    speakerIdentity: cue.speakerIdentity,
                    boundaryAfter: cue.boundaryAfter || hasTerminalBoundary(cue.speechText)
                )
            } else {
                current.displayText = joinCaptionText(current.displayText, cue.displayText)
                current.speechText = prospectiveSpeech
                current.endMs = max(current.endMs, cueEnd)
                current.boundaryAfter = cue.boundaryAfter || hasTerminalBoundary(cue.speechText)
                pending = current
            }
        }
        appendPending()
        return result
    }

    private static func buildSemanticDocument(
        from cues: [YouTubeTranscriptCue]
    ) -> SemanticDocument {
        let normalized = cues.enumerated().compactMap { index, cue -> NormalizedCue? in
            let semanticText = normalizeSemanticWhitespace(cue.text)
            let displayText = collapseWhitespace(semanticText)
            guard !displayText.isEmpty else { return nil }
            return NormalizedCue(
                source: cue,
                sourceIndex: index,
                semanticText: semanticText,
                displayText: displayText,
                productionMetadata: isProductionMetadataCue(
                    semanticText,
                    startMs: cue.startMs,
                    cueIndex: index
                )
            )
        }
        return SemanticDocument(
            cues: normalized,
            speakers: buildSpeakerRegistry(from: normalized)
        )
    }

    /// Speaker prefixes are first collected as syntax, then confirmed from
    /// document-level evidence. This keeps a one-off prose colon from becoming
    /// a destructive speaker-label rule.
    private static func buildSpeakerRegistry(
        from cues: [NormalizedCue]
    ) -> SpeakerRegistry {
        var observations: [SpeakerObservation] = []
        for cue in cues where !cue.productionMetadata {
            var localCandidates = scanSpeakerCandidates(in: cue.semanticText)
            let labelRemoved = removeSemanticLabels(
                from: cue.semanticText,
                initialSpeaker: normalizedSpeaker(cue.source.speaker)
            )
            if let derived = rawSpeakerCandidate(in: labelRemoved.text),
               validSpeakerCandidate(derived.candidate) {
                let key = normalizedLabel(derived.candidate)
                if !localCandidates.contains(where: { $0.key == key }) {
                    localCandidates.append(
                        SpeakerCandidateSpan(
                            label: derived.candidate,
                            key: key,
                            turnStart: 0,
                            prefixEnd: 0,
                            boundary: .cueStart
                        )
                    )
                }
            }
            observations.append(contentsOf: localCandidates.map {
                SpeakerObservation(
                    label: $0.label,
                    key: $0.key,
                    cueIndex: cue.sourceIndex,
                    startMs: cue.source.startMs,
                    durationMs: cue.source.durationMs,
                    payload: speakerCandidatePayload(
                        in: cue.semanticText,
                        candidate: $0
                    ),
                    boundary: $0.boundary
                )
            })
        }

        var labelByKey: [String: String] = [:]
        for observation in observations where labelByKey[observation.key] == nil {
            labelByKey[observation.key] = observation.label
        }
        for cue in cues {
            guard let speaker = normalizedSpeaker(cue.source.speaker) else { continue }
            let key = normalizedLabel(speaker)
            if labelByKey[key] == nil { labelByKey[key] = speaker }
        }

        var countByKey: [String: Int] = [:]
        for (key, values) in Dictionary(grouping: observations, by: \.key) {
            countByKey[key] = independentSpeakerEvidenceCount(values)
        }
        let sawQ = observations.contains { $0.key == "q" }
        let sawA = observations.contains { $0.key == "a" }
        let explicitMarkerKeys = Set(
            observations.lazy
                .filter { $0.boundary == .explicitMarker }
                .map(\.key)
        )
        let repeatedConfirmed = Set(observations.compactMap { observation -> String? in
            let key = observation.key
            if (countByKey[key] ?? 0) >= 2,
               isNameLikeSpeakerLabel(observation.label),
               isPlausiblePersonSpeakerLabel(observation.label) {
                return key
            }
            return nil
        })
        var confirmed = Set(observations.compactMap { observation -> String? in
            let key = observation.key
            if roleLabels.contains(key) || repeatedConfirmed.contains(key) { return key }
            if (key == "q" || key == "a") && sawQ && sawA { return key }
            return nil
        })
        // A marker proves a turn, not necessarily a speaker. Distinct marker
        // labels provide the dialogue structure needed to promote them.
        if explicitMarkerKeys.count >= 2 {
            confirmed.formUnion(explicitMarkerKeys)
        }
        for cue in cues {
            if let speaker = normalizedSpeaker(cue.source.speaker) {
                confirmed.insert(normalizedLabel(speaker))
            }
        }

        // Keep every syntactically valid long form in the ambiguity graph. Person-likeness is
        // applied only when creating an alias, otherwise technical expansions disappear and let
        // their acronym self-confirm.
        var longFormKeysByInitials: [String: [String]] = [:]
        for (key, label) in labelByKey {
            guard !isSpeakerAcronym(label), label.split(whereSeparator: { $0.isWhitespace }).count >= 2,
                  let initials = speakerInitialsKey(label) else { continue }
            longFormKeysByInitials[initials, default: []].append(key)
        }
        for (key, label) in labelByKey where isSpeakerAcronym(label) {
            let longForms = Array(Set(longFormKeysByInitials[key] ?? []))
            if longForms.count > 1 {
                confirmed.remove(key)
            } else if let longForm = longForms.first,
                      normalizedLabel(labelByKey[longForm] ?? "")
                        .split(whereSeparator: { $0.isWhitespace })
                        .contains(where: { nonPersonHeadingTokens.contains(String($0)) }) {
                confirmed.remove(key)
                confirmed.remove(longForm)
            }
        }

        var blockedAliasKeys = Set<String>()
        for (initials, longForms) in longFormKeysByInitials {
            let distinct = Array(Set(longForms))
            if distinct.count > 1 {
                blockedAliasKeys.insert(initials)
            } else if let longForm = distinct.first,
                      normalizedLabel(labelByKey[longForm] ?? "")
                        .split(whereSeparator: { $0.isWhitespace })
                        .contains(where: { nonPersonHeadingTokens.contains(String($0)) }) {
                blockedAliasKeys.insert(initials)
                blockedAliasKeys.insert(longForm)
            }
        }
        blockedAliasKeys.formUnion(labelByKey.keys.filter { key in
            nonPersonHeadingLabels.contains(key) || nonPersonHeadingTokens.contains(key)
        })
        blockedAliasKeys.formUnion(longFormKeysByInitials.compactMap { initials, longForms in
            longForms.contains(where: blockedAliasKeys.contains) ? initials : nil
        })

        var fullNamesByInitials: [String: [String]] = [:]
        for (key, label) in labelByKey {
            guard !isSpeakerAcronym(label), label.split(whereSeparator: { $0.isWhitespace }).count >= 2,
                  isPlausiblePersonSpeakerLabel(label),
                  let initials = speakerInitialsKey(label) else { continue }
            fullNamesByInitials[initials, default: []].append(key)
        }
        var identityByKey: [String: String] = [:]
        let structuredKeys = Set(cues.compactMap { normalizedSpeaker($0.source.speaker) }
            .map(normalizedLabel))
        let highConfidenceAcronymKeys = Set(labelByKey.compactMap { key, label -> String? in
            guard isSpeakerAcronym(label) else { return nil }
            let longForms = Array(Set(fullNamesByInitials[key] ?? []))
            let speechShapedCount = independentSpeakerEvidenceCount(
                observations.filter { $0.key == key && isSpeechShapedSpeakerEvidence($0.payload) }
            )
            let independentlyRepeated = speechShapedCount >= 2 &&
                !nonPersonHeadingTokens.contains(key) &&
                (longForms.isEmpty || longForms.count == 1)
            return explicitMarkerKeys.contains(key) || structuredKeys.contains(key) ||
                independentlyRepeated ? key : nil
        })
        for key in highConfidenceAcronymKeys {
            confirmed.insert(key)
            if identityByKey[key] == nil { identityByKey[key] = key }
        }
        for (acronymKey, label) in labelByKey where isSpeakerAcronym(label) {
            guard highConfidenceAcronymKeys.contains(acronymKey) else {
                confirmed.remove(acronymKey)
                identityByKey.removeValue(forKey: acronymKey)
                continue
            }
            let fullNameKeys = Array(Set(fullNamesByInitials[acronymKey] ?? []))
            guard fullNameKeys.count == 1, let fullNameKey = fullNameKeys.first else {
                if fullNameKeys.count > 1 {
                    blockedAliasKeys.insert(acronymKey)
                    confirmed.remove(acronymKey)
                    identityByKey.removeValue(forKey: acronymKey)
                }
                continue
            }
            if normalizedLabel(labelByKey[fullNameKey] ?? "")
                .split(whereSeparator: { $0.isWhitespace })
                .contains(where: { nonPersonHeadingTokens.contains(String($0)) }) {
                blockedAliasKeys.formUnion([acronymKey, fullNameKey])
                confirmed.remove(acronymKey)
                confirmed.remove(fullNameKey)
                identityByKey.removeValue(forKey: acronymKey)
                identityByKey.removeValue(forKey: fullNameKey)
                continue
            }
            // Alias edges never create identity from two weak candidates. The long form must
            // have its own document-level observation.
            guard observations.contains(where: {
                $0.key == fullNameKey && isSpeechShapedSpeakerEvidence($0.payload)
            }) else { continue }
            confirmed.insert(acronymKey)
            confirmed.insert(fullNameKey)
            identityByKey[acronymKey] = fullNameKey
            identityByKey[fullNameKey] = fullNameKey
        }
        confirmed.subtract(blockedAliasKeys)
        for key in confirmed where identityByKey[key] == nil {
            identityByKey[key] = key
        }
        return SpeakerRegistry(
            confirmedKeys: confirmed,
            blockedKeys: blockedAliasKeys,
            identityByKey: identityByKey
        )
    }

    private static func speakerPrefix(
        in rawText: String,
        structuredSpeaker: String?,
        speakers: SpeakerRegistry,
        allowsUppercaseEvidence: Bool = false
    ) -> SpeakerPrefix {
        var remainder = rawText
        var explicitTurn = false
        if remainder.hasPrefix(">>") || remainder.hasPrefix("＞＞") {
            explicitTurn = true
            remainder = String(remainder.dropFirst(2))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var speaker = structuredSpeaker
        var speakerIdentity = structuredSpeaker.map(normalizedLabel).map(speakers.identity)
        if let raw = rawSpeakerCandidate(in: remainder),
           validSpeakerCandidate(raw.candidate) {
            let key = normalizedLabel(raw.candidate)
            let structuredKey = structuredSpeaker.map(normalizedLabel)
            let matchesStructuredSpeaker = structuredKey == key
            let conflictsWithStructured = structuredKey != nil && !matchesStructuredSpeaker
            let isConfirmed = matchesStructuredSpeaker ||
                (!speakers.blockedKeys.contains(key) &&
                    (speakers.isConfirmed(key) || roleLabels.contains(key) ||
                        (allowsUppercaseEvidence &&
                            !speakerDeniedKeys.contains(key) &&
                            isNameLikeSpeakerLabel(raw.candidate))))
            if isConfirmed && !conflictsWithStructured && !speakerDeniedKeys.contains(key) {
                if speaker == nil {
                    speaker = normalizedSpeaker(raw.candidate)
                    speakerIdentity = speakers.identity(key)
                }
                remainder = raw.remainder
            }
        }
        return SpeakerPrefix(
            text: collapseWhitespace(remainder),
            speaker: speaker,
            speakerIdentity: speakerIdentity,
            explicitTurn: explicitTurn
        )
    }

    private static func speakerCandidatePayload(
        in text: String,
        candidate: SpeakerCandidateSpan
    ) -> String {
        let source = text as NSString
        let start = min(max(0, candidate.prefixEnd), source.length)
        return normalizedLabel(
            source.substring(from: start)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    /// Bare acronyms are common section/entity headings. They become weak speaker evidence only
    /// when the payload looks like an utterance. Strong structured/marker evidence bypasses this.
    private static func isSpeechShapedSpeakerEvidence(_ payload: String) -> Bool {
        let clean = collapseWhitespace(payload)
        return containsSpeakableContent(clean) &&
            (hasTerminalBoundary(clean) || wordCount(clean) >= 4)
    }

    /// Rolling transport windows are snapshots of one utterance, not independent votes.
    private static func independentSpeakerEvidenceCount(
        _ values: [SpeakerObservation]
    ) -> Int {
        let sorted = values.sorted {
            $0.startMs == $1.startMs ? $0.cueIndex < $1.cueIndex : $0.startMs < $1.startMs
        }
        var episodes: [SpeakerObservation] = []
        for observation in sorted {
            guard let previous = episodes.last else {
                episodes.append(observation)
                continue
            }
            let boundedDuration = min(
                max(0, previous.durationMs),
                maximumCueDurationForBoundaryMs
            )
            let end = previous.startMs.addingReportingOverflow(boundedDuration)
            let previousEnd = end.overflow ? Int.max : end.partialValue
            let previousBody = previous.payload.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            let currentBody = observation.payload.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            let previousTokens = previousBody.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let currentTokens = currentBody.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let normalizedPrevious = previousTokens.map(normalizedLabel)
            let normalizedCurrent = currentTokens.map(normalizedLabel)
            let sharedRollingWindow: Bool = {
                guard normalizedPrevious.count >= 3, normalizedCurrent.count >= 3 else {
                    return false
                }
                if normalizedPrevious == Array(normalizedCurrent.prefix(normalizedPrevious.count)) ||
                    normalizedCurrent == Array(normalizedPrevious.prefix(normalizedCurrent.count)) {
                    return true
                }
                let maximum = min(normalizedPrevious.count, normalizedCurrent.count)
                guard maximum >= 3 else { return false }
                return stride(from: maximum, through: 3, by: -1).contains { count in
                    Array(normalizedPrevious.suffix(count)) == Array(normalizedCurrent.prefix(count))
                }
            }()
            let grace = previousEnd.addingReportingOverflow(250)
            let overlapEnd = grace.overflow ? Int.max : grace.partialValue
            let sameRollingEpisode = observation.startMs <= overlapEnd &&
                (observation.payload.contains(previous.payload) ||
                    previous.payload.contains(observation.payload) || sharedRollingWindow)
            if !sameRollingEpisode { episodes.append(observation) }
        }
        return episodes.count
    }

    private static func isUppercaseSpeakerLabel(_ value: String) -> Bool {
        let letters = value.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard letters.count >= 2 else { return false }
        return value == value.uppercased() && value != value.lowercased()
    }

    private static func isNameLikeSpeakerLabel(_ value: String) -> Bool {
        if isUppercaseSpeakerLabel(value) { return true }
        let tokens = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (1...4).contains(tokens.count) else { return false }
        return tokens.enumerated().allSatisfy { index, token in
            if index > 0, nameParticles.contains(normalizedLabel(token)) { return true }
            guard let firstLetter = token.first(where: { $0.isLetter }) else {
                return false
            }
            let letter = String(firstLetter)
            return letter == letter.uppercased() && letter != letter.lowercased()
        }
    }

    private static func isSpeakerAcronym(_ value: String) -> Bool {
        let letters = value.unicodeScalars.filter { $0.properties.isAlphabetic }
        return (2...4).contains(letters.count) &&
            value.split(whereSeparator: { $0.isWhitespace }).count == 1 &&
            value == value.uppercased() && value != value.lowercased()
    }

    private static func isPlausiblePersonSpeakerLabel(_ value: String) -> Bool {
        let keys = normalizedLabel(value)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !keys.isEmpty,
              !keys.contains(where: nonPersonHeadingTokens.contains) else { return false }
        if keys.count == 1,
           keys[0].count > 1,
           value == value.lowercased() {
            return false
        }
        return true
    }

    private static func speakerInitialsKey(_ value: String) -> String? {
        guard !isSpeakerAcronym(value) else { return nil }
        let tokens = value.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (2...4).contains(tokens.count), isNameLikeSpeakerLabel(value) else {
            return nil
        }
        let initials = tokens.compactMap { token -> Character? in
            guard !nameParticles.contains(normalizedLabel(token)) else { return nil }
            return token.first(where: { $0.isLetter })
        }
        guard (2...4).contains(initials.count) else { return nil }
        return normalizedLabel(String(initials))
    }

    /// Discover colon-prefix syntax without deciding whether it is a speaker.
    /// Only the document registry is allowed to promote and strip a span.
    private static func scanSpeakerCandidates(
        in text: String
    ) -> [SpeakerCandidateSpan] {
        let source = text as NSString
        guard let regex = try? NSRegularExpression(pattern: "[:：]") else { return [] }
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        var results: [SpeakerCandidateSpan] = []
        var seen = Set<String>()
        for match in matches {
            let colon = match.range.location
            guard let (rawStart, rawBoundary) = speakerCandidateBoundary(
                in: source,
                colon: colon
            ) else { continue }
            var labelStart = rawStart
            while labelStart < colon, isWhitespaceUnit(source, at: labelStart) {
                labelStart += 1
            }
            var boundary = rawBoundary
            if hasTurnMarker(source, at: labelStart, before: colon) {
                boundary = .explicitMarker
                labelStart += 2
                while labelStart < colon, isWhitespaceUnit(source, at: labelStart) {
                    labelStart += 1
                }
            }
            let label = source.substring(with: NSRange(
                location: labelStart,
                length: max(0, colon - labelStart)
            )).trimmingCharacters(in: .whitespacesAndNewlines)
            guard validSpeakerCandidate(label) else { continue }
            var prefixEnd = colon + match.range.length
            while prefixEnd < source.length, isWhitespaceUnit(source, at: prefixEnd) {
                prefixEnd += 1
            }
            let key = normalizedLabel(label)
            let identity = "\(rawStart)|\(prefixEnd)|\(key)"
            guard seen.insert(identity).inserted else { continue }
            results.append(
                SpeakerCandidateSpan(
                    label: label,
                    key: key,
                    turnStart: rawStart,
                    prefixEnd: prefixEnd,
                    boundary: boundary
                )
            )
        }
        return results
    }

    private static func speakerCandidateBoundary(
        in text: NSString,
        colon: Int
    ) -> (Int, SpeakerBoundary)? {
        guard colon > 0 else { return nil }
        let searchRange = NSRange(location: 0, length: colon)
        let lineBreak = text.range(of: "\n", options: .backwards, range: searchRange)
        if lineBreak.location != NSNotFound {
            return (lineBreak.location + lineBreak.length, .lineBreak)
        }

        let asciiMarker = text.range(of: ">>", options: .backwards, range: searchRange)
        let fullwidthMarker = text.range(of: "＞＞", options: .backwards, range: searchRange)
        let markerStart = max(
            asciiMarker.location == NSNotFound ? -1 : asciiMarker.location,
            fullwidthMarker.location == NSNotFound ? -1 : fullwidthMarker.location
        )
        if markerStart >= 0,
           isExplicitTurnMarkerBoundary(in: text, markerStart: markerStart) {
            let betweenStart = markerStart + 2
            let between = text.substring(with: NSRange(
                location: betweenStart,
                length: max(0, colon - betweenStart)
            ))
            if !between.contains(where: {
                terminalCharacters.contains($0) || $0 == "\n"
            }) {
                return (markerStart, .explicitMarker)
            }
        }

        var index = colon - 1
        while index >= 0 {
            let unit = text.substring(with: NSRange(location: index, length: 1))
            if unit.count == 1,
               let character = unit.first,
               terminalCharacters.contains(character),
               hasTerminalBoundary(text.substring(to: index + 1)) {
                var start = index + 1
                while start < colon {
                    let candidate = text.substring(with: NSRange(location: start, length: 1))
                    let isClosing = candidate.count == 1 &&
                        candidate.first.map(closingCharacters.contains) == true
                    if !isWhitespaceUnit(text, at: start) && !isClosing { break }
                    start += 1
                }
                if start < colon { return (start, .sentenceTerminal) }
            }
            index -= 1
        }
        return (0, .cueStart)
    }

    private static func hasTurnMarker(
        _ text: NSString,
        at location: Int,
        before upperBound: Int
    ) -> Bool {
        guard location >= 0, location + 2 <= upperBound else { return false }
        let marker = text.substring(with: NSRange(location: location, length: 2))
        return marker == ">>" || marker == "＞＞"
    }

    private static func isWhitespaceUnit(_ text: NSString, at location: Int) -> Bool {
        guard location >= 0, location < text.length else { return false }
        return text.substring(with: NSRange(location: location, length: 1))
            .rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    private static func rawSpeakerCandidate(
        in rawText: String
    ) -> (candidate: String, remainder: String)? {
        var text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(">>") || text.hasPrefix("＞＞") {
            text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            return nil
        }
        let candidate = String(text[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder = String(text[text.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return nil }
        return (candidate, remainder)
    }

    private static func validSpeakerCandidate(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.count <= 32,
              trimmed.split(whereSeparator: { $0.isWhitespace }).count <= 4,
              trimmed.unicodeScalars.contains(where: { $0.properties.isAlphabetic }),
              !trimmed.contains("/"),
              !trimmed.contains("@"),
              !trimmed.contains("="),
              !trimmed.contains("+"),
              !trimmed.contains("#"),
              !trimmed.contains(">"),
              !trimmed.contains("<") else { return false }
        let key = normalizedLabel(trimmed)
        let tokens = key.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !speakerDeniedKeys.contains(key),
              !tokens.contains(where: { speakerDeniedKeys.contains($0) }),
              key != "http", key != "https",
              !tokens.contains("http"), !tokens.contains("https") else {
            return false
        }
        if trimmed.unicodeScalars.contains(where: {
            CharacterSet.decimalDigits.contains($0)
        }) {
            guard tokens.count == 2,
                  numberedRoleLabels.contains(tokens[0]),
                  tokens[1].allSatisfy(\.isNumber) else { return false }
        }
        return true
    }

    /// Opening caption credits are classified as document metadata only when
    /// the complete record matches a field/value grammar. Prose fails open.
    private static func isProductionMetadataCue(
        _ text: String,
        startMs: Int,
        cueIndex: Int
    ) -> Bool {
        guard cueIndex <= 4, (0...15_000).contains(startMs),
              let regex = productionCreditFieldRegex else { return false }
        let source = text as NSString
        let matches = regex.matches(
            in: text,
            range: NSRange(location: 0, length: source.length)
        )
        guard !matches.isEmpty else { return false }
        let firstStart = matches[0].range.location
        if firstStart > 0 {
            let prefix = source.substring(to: firstStart)
            guard prefix.allSatisfy(\.isWhitespace) else { return false }
        }
        let values = matches.enumerated().map { index, match -> String in
            let start = match.range.location + match.range.length
            let end = index + 1 < matches.count
                ? matches[index + 1].range.location
                : source.length
            return source.substring(with: NSRange(
                location: start,
                length: max(0, end - start)
            )).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard values.allSatisfy(isProductionBylineValue) else { return false }
        if matches.count >= 2 { return true }
        guard matches[0].numberOfRanges > 1 else { return false }
        let field = normalizedTaxonomyKey(
            source.substring(with: matches[0].range(at: 1))
        )
        return field.contains(" by") || [
            "transcriber", "transcriptor", "translator", "traductor", "traducteur",
            "subtitle editor", "字幕制作", "字幕製作", "字幕翻译", "字幕翻譯",
            "翻译", "翻譯", "校对", "校對", "审校", "審校", "时间轴", "時間軸",
            "听译", "聽譯", "文字起こし", "翻訳", "校正"
        ].contains(field)
    }

    private static func isProductionBylineValue(_ value: String) -> Bool {
        let clean = collapseWhitespace(value)
        guard containsSpeakableContent(clean), clean.count <= 80,
              !clean.contains(where: terminalCharacters.contains) else { return false }
        let tokens = clean.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard (1...8).contains(tokens.count) else { return false }
        let punctuation = CharacterSet(charactersIn: "-'’.&")
        guard clean.unicodeScalars.allSatisfy({ scalar in
            scalar.properties.isAlphabetic || CharacterSet.whitespacesAndNewlines.contains(scalar) ||
                CharacterSet.decimalDigits.contains(scalar) || punctuation.contains(scalar)
        }) else { return false }
        let lexical = tokens.map(normalizedTaxonomyKey)
        guard !lexical.contains(where: commonNonNameWords.contains) else { return false }

        let hasUncasedLetters = clean.unicodeScalars.contains { scalar in
            guard scalar.properties.isAlphabetic else { return false }
            let grapheme = String(scalar)
            return grapheme.uppercased() == grapheme.lowercased()
        }
        // Without case morphology a lone free-form value is indistinguishable from prose.
        guard !hasUncasedLetters else { return false }
        return tokens.allSatisfy { token in
            guard let first = token.unicodeScalars.first(where: { $0.properties.isAlphabetic }) else {
                return token.allSatisfy(\.isNumber)
            }
            let grapheme = String(first)
            let hasCase = grapheme.uppercased() != grapheme.lowercased()
            return !hasCase || grapheme == grapheme.uppercased()
        }
    }

    private static func removeSemanticLabels(
        from text: String,
        initialSpeaker: String?
    ) -> LabelRemoval {
        let spans = semanticLabelSpans(in: text)
        let removedSpans = spans.filter(\.isRemoved)
        guard !removedSpans.isEmpty else {
            return LabelRemoval(
                text: text,
                speaker: initialSpeaker,
                spans: spans
            )
        }

        let source = text as NSString
        var output = ""
        var cursor = 0
        var speaker = initialSpeaker
        for span in removedSpans where span.inputRange.location >= cursor {
            let range = span.inputRange
            if cursor < range.location {
                output += source.substring(with: NSRange(
                    location: cursor,
                    length: range.location - cursor
                ))
            }
            if span.disposition == .extractSpeaker,
               let role = span.role {
                speaker = speaker ?? normalizedSpeaker(role)
            }
            if span.position == .inline {
                let existing = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if existing.last.map({ terminalCharacters.contains($0) }) == true {
                    output += " "
                } else {
                    output += ". "
                }
            }
            else { output += " " }
            cursor = range.location + range.length
        }
        if cursor < source.length {
            output += source.substring(from: cursor)
        }
        return LabelRemoval(
            text: collapseWhitespace(output),
            speaker: speaker,
            spans: spans
        )
    }

    /// Produces a complete, auditable plan for bracketed caption content.
    /// Unknown labels are included with `.preserve`, so callers never infer
    /// deletion merely from bracket shape.
    static func semanticLabelSpans(in text: String) -> [SemanticLabelSpan] {
        let source = text as NSString
        let patterns = [
            #"\[[^\[\]\n]{1,100}\]"#,
            #"［[^［］\n]{1,100}］"#,
            #"【[^【】\n]{1,100}】"#,
            #"\([^\(\)\n]{1,100}\)"#,
            #"（[^（）\n]{1,100}）"#,
        ]
        var ranges: [NSRange] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            ranges.append(contentsOf: regex.matches(
                in: text,
                range: NSRange(location: 0, length: source.length)
            ).map(\.range))
        }
        ranges.sort { $0.location < $1.location }
        let classified = ranges.map { range -> (NSRange, String, String, LabelClassification) in
            let whole = source.substring(with: range)
            let body = String(whole.dropFirst().dropLast())
            let key = normalizedLabel(body)
            return (range, whole, key, labelClassification(for: key))
        }
        let recognizedRanges = classified.compactMap { item in
            item.3.category == .unknown ? nil : item.0
        }
        return classified.map { item in
            let range = item.0
            let whole = item.1
            let key = item.2
            let classification = item.3
            let isRound = whole.hasPrefix("(") || whole.hasPrefix("（")
            let hasBefore = containsSemanticFreeContent(
                in: NSRange(location: 0, length: range.location),
                source: source,
                excluding: recognizedRanges
            )
            let afterLocation = range.location + range.length
            let hasAfter = containsSemanticFreeContent(
                in: NSRange(
                    location: afterLocation,
                    length: max(0, source.length - afterLocation)
                ),
                source: source,
                excluding: recognizedRanges
            )
            let position: SemanticLabelPosition
            switch (hasBefore, hasAfter) {
            case (false, false): position = .entireCue
            case (false, true): position = .leading
            case (true, false): position = .trailing
            case (true, true): position = .inline
            }

            let disposition: SemanticLabelDisposition
            let decisionReason: SemanticLabelDecisionReason
            if classification.category == .unknown {
                disposition = .preserve
                decisionReason = .unknownFailOpen
            } else if classification.category == .role {
                if hasBefore {
                    disposition = .preserve
                    decisionReason = .inlineRoleAmbiguity
                } else {
                    disposition = .extractSpeaker
                    decisionReason = .leadingRole
                }
            } else if isRound, position == .inline {
                // Inline round brackets are ordinary prose surprisingly often.
                // Exact delivery/unavailable annotations are unambiguously
                // accessibility metadata; sound nouns such as `(music)` remain
                // fail-open because they can be grammatical subject matter.
                let safeInlineCategories: Set<SemanticLabelCategory> = [
                    .delivery, .unavailable,
                ]
                if classification.confidence == .high,
                   safeInlineCategories.contains(classification.category) {
                    disposition = .suppress
                    decisionReason = .classifiedAccessibilityMetadata
                } else {
                    disposition = .preserve
                    decisionReason = .inlineParentheticalAmbiguity
                }
            } else {
                disposition = .suppress
                decisionReason = .classifiedAccessibilityMetadata
            }

            return SemanticLabelSpan(
                inputRange: range,
                rawText: whole,
                normalizedText: key,
                category: classification.category,
                position: position,
                disposition: disposition,
                evidence: classification.evidence,
                confidence: classification.confidence,
                decisionReason: decisionReason,
                role: classification.role
            )
        }
    }

    private static func containsSemanticFreeContent(
        in searchRange: NSRange,
        source: NSString,
        excluding ranges: [NSRange]
    ) -> Bool {
        let lowerBound = searchRange.location
        let upperBound = min(source.length, searchRange.location + searchRange.length)
        guard lowerBound < upperBound else { return false }
        var cursor = lowerBound
        for range in ranges {
            let rangeStart = max(lowerBound, range.location)
            let rangeEnd = min(upperBound, range.location + range.length)
            guard rangeEnd > lowerBound, rangeStart < upperBound else { continue }
            if cursor < rangeStart,
               containsSpeakableContent(source.substring(with: NSRange(
                   location: cursor,
                   length: rangeStart - cursor
               ))) {
                return true
            }
            cursor = max(cursor, rangeEnd)
        }
        guard cursor < upperBound else { return false }
        return containsSpeakableContent(source.substring(with: NSRange(
            location: cursor,
            length: upperBound - cursor
        )))
    }

    private static func labelClassification(for key: String) -> LabelClassification {
        guard !key.isEmpty else {
            return LabelClassification(
                category: .unknown,
                evidence: .unknown,
                confidence: .unknown
            )
        }
        let compact = key.replacingOccurrences(of: " ", with: "")
        if compact.count >= 2 && compact.allSatisfy({ $0 == "_" }) {
            return LabelClassification(
                category: .unavailable,
                evidence: .unavailablePlaceholder,
                role: nil
            )
        }
        if unavailableLabels.contains(key) {
            return LabelClassification(
                category: .unavailable,
                evidence: .exactTaxonomy,
                role: nil
            )
        }
        if unavailableLabelWithTimestamp(key) {
            return LabelClassification(
                category: .unavailable,
                evidence: .unavailableTimestamp,
                role: nil
            )
        }
        if roleLabels.contains(key) {
            return LabelClassification(
                category: .role,
                evidence: .exactTaxonomy,
                role: key
            )
        }
        if musicLabels.contains(key) {
            return LabelClassification(
                category: .music,
                evidence: .exactTaxonomy,
                role: nil
            )
        }
        if reactionLabels.contains(key) {
            return LabelClassification(
                category: .audienceReaction,
                evidence: .exactTaxonomy,
                role: nil
            )
        }
        if ambientLabels.contains(key) {
            return LabelClassification(
                category: .ambientSound,
                evidence: .exactTaxonomy,
                role: nil
            )
        }
        let tokens = key.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if !tokens.isEmpty,
           tokens.allSatisfy({ token in
               musicLabels.contains(token) || reactionLabels.contains(token) ||
                   ambientLabels.contains(token) || eventModifiers.contains(token) ||
                   eventLinkWords.contains(token) || eventActivityWords.contains(token)
           }),
           tokens.contains(where: { token in
               musicLabels.contains(token) || reactionLabels.contains(token) ||
                   ambientLabels.contains(token)
           }) {
            return LabelClassification(
                category: composedSoundCategory(tokens),
                evidence: .composedEventGrammar,
                confidence: .medium,
                role: nil
            )
        }
        let hasAmbientNoun = tokens.contains(where: ambientEventNouns.contains)
        let hasAmbientActivity = tokens.contains(where: ambientEventActivities.contains)
        if hasAmbientNoun,
           hasAmbientActivity,
           tokens.allSatisfy({ token in
               ambientEventNouns.contains(token) || ambientEventActivities.contains(token) ||
                   ambientEventQualifiers.contains(token) || eventModifiers.contains(token) ||
                   eventLinkWords.contains(token) || eventActivityWords.contains(token)
           }) {
            return LabelClassification(
                category: composedSoundCategory(tokens),
                evidence: .ambientEventGrammar,
                confidence: .medium,
                role: nil
            )
        }
        if deliveryLabels.contains(key) {
            return LabelClassification(
                category: .delivery,
                evidence: .exactTaxonomy,
                role: nil
            )
        }
        let withoutNotes = key.unicodeScalars.filter { !musicNotes.contains($0) }
        if withoutNotes.isEmpty && key.unicodeScalars.contains(where: { musicNotes.contains($0) }) {
            return LabelClassification(
                category: .music,
                evidence: .musicNotation,
                role: nil
            )
        }
        return LabelClassification(
            category: .unknown,
            evidence: .unknown,
            confidence: .unknown
        )
    }

    private static func composedSoundCategory(
        _ tokens: [String]
    ) -> SemanticLabelCategory {
        var categories: Set<SemanticLabelCategory> = []
        if tokens.contains(where: { musicLabels.contains($0) || $0 == "music" }) {
            categories.insert(.music)
        }
        if tokens.contains(where: {
            reactionLabels.contains($0) ||
                ["laughter", "laughing", "applause", "applauding", "clapping", "cheering"]
                    .contains($0)
        }) {
            categories.insert(.audienceReaction)
        }
        if tokens.contains(where: { ambientLabels.contains($0) }) {
            categories.insert(.ambientSound)
        }
        if categories.count > 1 { return .mixedSound }
        if let category = categories.first { return category }
        return .ambientSound
    }

    private static func unavailableLabelWithTimestamp(_ key: String) -> Bool {
        guard let regex = try? NSRegularExpression(
            pattern: #"^(.+?)\s+\d{1,2}:\d{2}$"#
        ) else { return false }
        let ns = key as NSString
        guard let match = regex.firstMatch(
            in: key,
            range: NSRange(location: 0, length: ns.length)
        ), match.numberOfRanges == 2 else { return false }
        return unavailableLabels.contains(ns.substring(with: match.range(at: 1)))
    }

    private static func removeMusicNotes(from text: String) -> MusicRemoval {
        let characters = Array(text)
        let firstSpeakable = characters.firstIndex(where: { containsSpeakableContent(String($0)) })
        let lastSpeakable = characters.lastIndex(where: { containsSpeakableContent(String($0)) })
        let hadNotes = text.unicodeScalars.contains(where: { musicNotes.contains($0) })
        guard hadNotes else {
            return MusicRemoval(
                text: text,
                boundaryBefore: false,
                boundaryAfter: false,
                containedNotes: false
            )
        }
        guard let firstSpeakable, let lastSpeakable else {
            return MusicRemoval(
                text: "",
                boundaryBefore: true,
                boundaryAfter: true,
                containedNotes: true
            )
        }
        var output = ""
        var inNoteRun = false
        for (index, character) in characters.enumerated() {
            let isNote = isMusicNoteCharacter(character)
            if isNote {
                inNoteRun = true
                continue
            }
            if inNoteRun && index > firstSpeakable && index <= lastSpeakable {
                output += ". "
            }
            inNoteRun = false
            output.append(character)
        }
        return MusicRemoval(
            text: collapseWhitespace(output),
            boundaryBefore: characters[..<firstSpeakable].contains(where: {
                isMusicNoteCharacter($0)
            }),
            boundaryAfter: characters[characters.index(after: lastSpeakable)...].contains(where: {
                isMusicNoteCharacter($0)
            }),
            containedNotes: true
        )
    }

    private static func isMusicNoteCharacter(_ character: Character) -> Bool {
        var sawNote = false
        for scalar in character.unicodeScalars {
            if musicNotes.contains(scalar) {
                sawNote = true
                continue
            }
            // Emoji/text presentation selectors are part of the same visible
            // glyph and must not turn a standalone music note into TTS input.
            if scalar.value == 0xFE0E || scalar.value == 0xFE0F { continue }
            return false
        }
        return sawNote
    }

    private static func suppressRollingDuplicates(_ cues: inout [AnalyzedCue]) {
        var previousSpokenIndex: Int?
        for index in cues.indices {
            guard !cues[index].speechText.isEmpty else {
                if !cues[index].suppressedRollingDuplicate { previousSpokenIndex = nil }
                continue
            }
            guard let previousIndex = previousSpokenIndex else {
                previousSpokenIndex = index
                continue
            }
            let previous = cues[previousIndex]
            guard previous.speakerIdentity == cues[index].speakerIdentity,
                  !previous.boundaryAfter,
                  !cues[index].boundaryBefore,
                  rollingCuesMayOverlap(previous.source, cues[index].source),
                  let trimmed = trimRollingPrefix(
                    from: cues[index].speechText,
                    matchingSuffixOf: previous.rollingComparisonText
                  ) else {
                previousSpokenIndex = index
                continue
            }
            cues[index].speechText = trimmed
            cues[index].suppressedRollingDuplicate = trimmed.isEmpty
            // Preserve the full rolling window for the next cue. Comparing
            // against only the newly spoken suffix makes a third update repeat
            // words that were already present in the second visible caption.
            cues[index].rollingComparisonText = joinCaptionText(
                previous.rollingComparisonText,
                trimmed
            )
            if cues[index].boundaryAfter {
                previousSpokenIndex = nil
            } else {
                // A fully repeated rolling update still advances the timing
                // window used to compare the next cue.
                previousSpokenIndex = index
            }
        }
    }

    private static func rollingCuesMayOverlap(
        _ previous: YouTubeTranscriptCue,
        _ current: YouTubeTranscriptCue
    ) -> Bool {
        if previous.durationMs == 0 || current.durationMs == 0 {
            return current.startMs >= previous.startMs &&
                current.startMs - previous.startMs <= 1_000
        }
        let previousEnd = Int64(safeCueEnd(previous))
        guard previousEnd < Int64.max - 250 else { return true }
        return Int64(current.startMs) <= previousEnd + 250
    }

    private static func trimRollingPrefix(
        from current: String,
        matchingSuffixOf previous: String
    ) -> String? {
        let previousTokens = previous.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let currentTokens = current.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if previousTokens.count >= 3, currentTokens.count >= 3 {
            let maximum = min(previousTokens.count, currentTokens.count)
            for count in stride(from: maximum, through: 3, by: -1) {
                let left = previousTokens.suffix(count).map { normalizedLabel($0) }
                let right = currentTokens.prefix(count).map { normalizedLabel($0) }
                let joined = right.joined(separator: " ")
                guard left == right,
                      joined.count >= 12,
                      Set(right).count >= 2 else { continue }
                return currentTokens.dropFirst(count).joined(separator: " ")
            }
        }

        let previousCharacters = Array(previous)
        let currentCharacters = Array(current)
        guard previousCharacters.contains(where: isCJKOrKana),
              currentCharacters.contains(where: isCJKOrKana) else { return nil }
        let maximum = min(previousCharacters.count, currentCharacters.count)
        guard maximum >= 6 else { return nil }
        for count in stride(from: maximum, through: 6, by: -1) {
            let left = Array(previousCharacters.suffix(count))
            let right = Array(currentCharacters.prefix(count))
            guard left == right, Set(right).count >= 3 else { continue }
            return String(currentCharacters.dropFirst(count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private static func safeCueEnd(_ cue: YouTubeTranscriptCue) -> Int {
        let boundedDuration = min(max(0, cue.durationMs), maximumCueDurationForBoundaryMs)
        let added = cue.startMs.addingReportingOverflow(boundedDuration)
        return added.overflow ? Int.max : added.partialValue
    }

    private static func hasTerminalBoundary(_ text: String) -> Bool {
        var characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = characters.last, closingCharacters.contains(last) {
            characters.removeLast()
        }
        guard let terminal = characters.last, terminalCharacters.contains(terminal) else {
            return false
        }
        guard terminal == "." else { return true }
        characters.removeLast()
        var token = ""
        while let last = characters.last,
              last.isLetter || last == "." {
            token.insert(last, at: token.startIndex)
            characters.removeLast()
        }
        let normalized = token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if abbreviations.contains(normalized) { return false }
        if normalized.count == 1 { return false }
        return true
    }

    private static func endsWithSoftBoundary(_ text: String) -> Bool {
        guard let last = text.trimmingCharacters(in: .whitespacesAndNewlines).last else {
            return false
        }
        return softBoundaryCharacters.contains(last)
    }

    private static func joinCaptionText(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if let last = left.last, let first = right.first,
           isCJKOrKana(last), isCJKOrKana(first) {
            return left + right
        }
        return left + " " + right
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Collapse horizontal whitespace while preserving line breaks as lexical
    /// speaker-turn boundaries for the document scanner.
    private static func normalizeSemanticWhitespace(_ text: String) -> String {
        var result = ""
        var pendingSpace = false
        var pendingLineBreak = false
        for scalar in text.unicodeScalars {
            if scalar.value == 10 || scalar.value == 13 {
                pendingLineBreak = !result.isEmpty
                pendingSpace = false
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !result.isEmpty && !pendingLineBreak { pendingSpace = true }
            } else {
                if pendingLineBreak && !result.isEmpty {
                    result.append("\n")
                } else if pendingSpace && !result.isEmpty {
                    result.append(" ")
                }
                result.unicodeScalars.append(scalar)
                pendingLineBreak = false
                pendingSpace = false
            }
        }
        return result
    }

    private static func normalizedTaxonomyKey(_ text: String) -> String {
        collapseWhitespace(
            text.precomposedStringWithCompatibilityMapping
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private static func normalizedLabel(_ text: String) -> String {
        collapseWhitespace(text.precomposedStringWithCompatibilityMapping.lowercased())
    }

    private static func normalizedSpeaker(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = collapseWhitespace(value)
        guard !normalized.isEmpty, normalized.count <= 128 else { return nil }
        return normalized
    }

    private static func containsSpeakableContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let value = scalar.value
            if (0x3400...0x9FFF).contains(value) ||
                (0x3040...0x30FF).contains(value) ||
                (0xAC00...0xD7AF).contains(value) ||
                (0x0900...0x097F).contains(value) {
                return true
            }
            return scalar.properties.isAlphabetic || CharacterSet.decimalDigits.contains(scalar)
        }
    }

    private static func isCJKOrKana(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x9FFF, 0x3040...0x30FF, 0x31F0...0x31FF:
                return true
            default:
                return false
            }
        }
    }
}

enum YouTubeTranscriptGrouper {
    /// Derives display-preserving, TTS-specific paragraphs from timed cues.
    static func cuesIntoParagraphs(
        _ cues: [YouTubeTranscriptCue]
    ) -> [YouTubeTranscriptParagraph] {
        YouTubeCaptionSemanticAnalyzer.paragraphs(from: cues)
    }
}

// MARK: - Storyboards

struct YouTubeStoryboardFrame: Codable, Equatable, Sendable {
    let sheetIndex: Int
    let cropRect: CGRect
}

struct YouTubeStoryboard: Codable, Equatable, Sendable {
    /// Current YouTube sprite sets normally contain only a handful of sheets.
    /// Keep page-provided specs from turning cache coverage into unbounded
    /// allocation, network and filesystem work.
    static let maximumSheetCount = 512

    let sheetURLTemplate: String
    let level: Int
    let tileWidth: Int
    let tileHeight: Int
    let columns: Int
    let rows: Int
    let intervalMs: Int
    let frameCount: Int
    let nameTemplate: String?
    let signature: String?

    var isValid: Bool {
        guard (0...1_000).contains(level),
              (1...8_192).contains(tileWidth),
              (1...8_192).contains(tileHeight),
              (1...1_000).contains(columns),
              (1...1_000).contains(rows),
              (1...86_400_000).contains(intervalMs),
              (1...10_000_000).contains(frameCount),
              sheetURLTemplate.contains("$L"),
              sheetURLTemplate.contains("$N") else { return false }
        let capacity = columns.multipliedReportingOverflow(by: rows)
        let maxX = (columns - 1).multipliedReportingOverflow(by: tileWidth)
        let maxY = (rows - 1).multipliedReportingOverflow(by: tileHeight)
        let sheetWidth = columns.multipliedReportingOverflow(by: tileWidth)
        let sheetHeight = rows.multipliedReportingOverflow(by: tileHeight)
        guard !capacity.overflow, capacity.partialValue > 0,
              !maxX.overflow, !maxY.overflow,
              !sheetWidth.overflow, !sheetHeight.overflow,
              sheetWidth.partialValue <= 8_192,
              sheetHeight.partialValue <= 8_192,
              Int64(sheetWidth.partialValue) * Int64(sheetHeight.partialValue)
                <= 32_000_000 else { return false }
        let boundedSheetCount = (frameCount - 1) / capacity.partialValue + 1
        guard boundedSheetCount <= Self.maximumSheetCount else { return false }

        let probe = sheetURLTemplate
            .replacingOccurrences(of: "$L", with: "0")
            .replacingOccurrences(of: "$N", with: "0")
            .replacingOccurrences(of: "$M", with: "0")
            .replacingOccurrences(of: "$S", with: "signature")
        guard !probe.contains("$"),
              let components = URLComponents(string: probe),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return false }
        return true
    }

    var tilesPerSheet: Int {
        let capacity = columns.multipliedReportingOverflow(by: rows)
        guard !capacity.overflow, capacity.partialValue > 0 else { return 0 }
        return capacity.partialValue
    }

    var sheetCount: Int {
        let capacity = tilesPerSheet
        guard capacity > 0, frameCount > 0 else { return 0 }
        return (frameCount - 1) / capacity + 1
    }

    func frame(atMs: Int) -> YouTubeStoryboardFrame? {
        guard isValid else { return nil }
        let requestedFrame = max(0, atMs) / intervalMs
        let frameIndex = min(frameCount - 1, requestedFrame)
        let sheetIndex = frameIndex / tilesPerSheet
        let indexInSheet = frameIndex % tilesPerSheet
        let column = indexInSheet % columns
        let row = indexInSheet / columns
        return YouTubeStoryboardFrame(
            sheetIndex: sheetIndex,
            cropRect: CGRect(
                x: column * tileWidth,
                y: row * tileHeight,
                width: tileWidth,
                height: tileHeight
            )
        )
    }

    func sheetURLString(for sheetIndex: Int) -> String? {
        guard isValid, (0..<sheetCount).contains(sheetIndex) else { return nil }
        let templateConsumesSignature = sheetURLTemplate.contains("$S")
        let templateWithoutKnownTokens = sheetURLTemplate
            .replacingOccurrences(of: "$L", with: "")
            .replacingOccurrences(of: "$N", with: "")
            .replacingOccurrences(of: "$M", with: "")
            .replacingOccurrences(of: "$S", with: "")
        guard !templateWithoutKnownTokens.contains("$") else { return nil }
        let replacement = sheetNameReplacement(for: sheetIndex)
        let value = sheetURLTemplate
            .replacingOccurrences(of: "$L", with: String(level))
            .replacingOccurrences(of: "$N", with: replacement)
            .replacingOccurrences(of: "$M", with: String(sheetIndex))
            .replacingOccurrences(of: "$S", with: signature ?? "")
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return nil }
        if !templateConsumesSignature,
           let signature,
           !signature.isEmpty {
            var queryItems = components.queryItems ?? []
            if !queryItems.contains(where: { $0.name.lowercased() == "sigh" }) {
                queryItems.append(URLQueryItem(name: "sigh", value: signature))
                components.queryItems = queryItems
            }
        }
        return components.url?.absoluteString
    }

    /// The `$N` token sometimes expands directly to the numeric sheet index
    /// and sometimes to the level descriptor's `M$M` name. Remove a prefix or
    /// suffix already present around `$N` so defensive variants such as
    /// `M$N.jpg` + `M$M.jpg` still resolve to exactly `M0.jpg`.
    private func sheetNameReplacement(for sheetIndex: Int) -> String {
        guard let nameTemplate,
              nameTemplate.contains("$M"),
              let tokenRange = sheetURLTemplate.range(of: "$N") else {
            return String(sheetIndex)
        }
        var name = nameTemplate.replacingOccurrences(
            of: "$M",
            with: String(sheetIndex)
        )
        let componentStart = sheetURLTemplate[..<tokenRange.lowerBound]
            .lastIndex(of: "/")
            .map { sheetURLTemplate.index(after: $0) }
            ?? sheetURLTemplate.startIndex
        let prefix = String(sheetURLTemplate[componentStart..<tokenRange.lowerBound])
        let suffixEnd = sheetURLTemplate[tokenRange.upperBound...]
            .firstIndex(where: { $0 == "?" || $0 == "#" })
            ?? sheetURLTemplate.endIndex
        let suffix = String(sheetURLTemplate[tokenRange.upperBound..<suffixEnd])
        if !prefix.isEmpty, name.hasPrefix(prefix) {
            name.removeFirst(prefix.count)
        }
        if !suffix.isEmpty, name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }
}

enum YouTubeStoryboardParser {
    private struct Candidate {
        let level: Int
        let width: Int
        let height: Int
        let frameCount: Int
        let columns: Int
        let rows: Int
        let intervalMs: Int
        let nameTemplate: String?
        let signature: String?

        var pixelArea: Int { width * height }
    }

    /// YouTube's current format is:
    /// URL-template | width#height#frames#columns#rows#interval#name#signature
    /// with the descriptor position defining L0/L1/L2/L3.... Unknown or
    /// malformed levels are skipped. YouTube now commonly exposes L3 artwork,
    /// so select the clearest safe candidate instead of pinning the reader to
    /// the legacy L2 preview size.
    static func parse(_ spec: String) -> YouTubeStoryboard? {
        let parts = spec.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return nil }
        let template = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard template.contains("$L"), template.contains("$N") else { return nil }
        let probeURL = template
            .replacingOccurrences(of: "$L", with: "0")
            .replacingOccurrences(of: "$N", with: "0")
            .replacingOccurrences(of: "$M", with: "0")
            .replacingOccurrences(of: "$S", with: "signature")
        guard let components = URLComponents(string: probeURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil else { return nil }

        let candidates = parts.dropFirst().enumerated().compactMap { offset, raw in
            parseCandidate(raw, level: offset)
        }
        guard !candidates.isEmpty else { return nil }

        let selected = candidates.max {
            if $0.pixelArea != $1.pixelArea { return $0.pixelArea < $1.pixelArea }
            return $0.level < $1.level
        }
        guard let selected else { return nil }

        return YouTubeStoryboard(
            sheetURLTemplate: template,
            level: selected.level,
            tileWidth: selected.width,
            tileHeight: selected.height,
            columns: selected.columns,
            rows: selected.rows,
            intervalMs: selected.intervalMs,
            frameCount: selected.frameCount,
            nameTemplate: selected.nameTemplate,
            signature: selected.signature
        )
    }

    private static func parseCandidate(_ raw: String, level: Int) -> Candidate? {
        let fields = raw.split(separator: "#", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6,
              let width = Int(fields[0]),
              let height = Int(fields[1]),
              let frameCount = Int(fields[2]),
              let columns = Int(fields[3]),
              let rows = Int(fields[4]),
              let intervalMs = Int(fields[5]),
              (1...8_192).contains(width),
              (1...8_192).contains(height),
              (1...10_000_000).contains(frameCount),
              (1...1_000).contains(columns),
              (1...1_000).contains(rows),
              (1...86_400_000).contains(intervalMs) else { return nil }

        let capacity = columns.multipliedReportingOverflow(by: rows)
        let area = width.multipliedReportingOverflow(by: height)
        let sheetWidth = width.multipliedReportingOverflow(by: columns)
        let sheetHeight = height.multipliedReportingOverflow(by: rows)
        guard !capacity.overflow, capacity.partialValue > 0,
              !area.overflow, area.partialValue > 0,
              !sheetWidth.overflow, !sheetHeight.overflow,
              sheetWidth.partialValue <= 8_192,
              sheetHeight.partialValue <= 8_192,
              Int64(sheetWidth.partialValue) * Int64(sheetHeight.partialValue)
                <= 32_000_000 else { return nil }
        let sheetCount = (frameCount - 1) / capacity.partialValue + 1
        guard sheetCount <= YouTubeStoryboard.maximumSheetCount else { return nil }

        let name = fields.count > 6 && !fields[6].isEmpty ? fields[6] : nil
        let signature = fields.count > 7 && !fields[7].isEmpty ? fields[7] : nil
        return Candidate(
            level: level,
            width: width,
            height: height,
            frameCount: frameCount,
            columns: columns,
            rows: rows,
            intervalMs: intervalMs,
            nameTemplate: name,
            signature: signature
        )
    }
}

enum YouTubeArtworkPresentation: Equatable, Sendable {
    case coverOnly
    case storyboardOnly
    case storyboardFullWidth
    case coverWithStoryboardInset
}

enum YouTubeArtworkQualityPolicy {
    /// A full-width image should provide most of the physical display pixels.
    /// Below this threshold, stretching the progress-bar preview makes text
    /// and faces visibly soft; retain it as a smaller time-synced inset instead.
    static let minimumFullWidthPixelCoverage: CGFloat = 0.8

    static func presentation(
        storyboard: YouTubeStoryboard?,
        hasThumbnail: Bool,
        displayWidthPoints: CGFloat,
        displayScale: CGFloat
    ) -> YouTubeArtworkPresentation {
        guard let storyboard else {
            return hasThumbnail ? .coverOnly : .storyboardOnly
        }
        guard hasThumbnail else { return .storyboardOnly }
        let requiredPixels = max(1, displayWidthPoints) * max(1, displayScale)
        let coverage = CGFloat(storyboard.tileWidth) / requiredPixels
        return coverage >= minimumFullWidthPixelCoverage
            ? .storyboardFullWidth
            : .coverWithStoryboardInset
    }

    static func insetWidthPoints(
        tileWidth: Int,
        displayScale: CGFloat
    ) -> CGFloat {
        let nativeWidth = CGFloat(max(1, tileWidth)) / max(1, displayScale)
        return min(180, max(120, nativeWidth))
    }
}

enum YouTubeArtworkCacheSchema {
    /// Version 2 selects the clearest safe storyboard level and treats the
    /// high-resolution thumbnail as a first-class full-width artwork source.
    static let current = 2
}

// MARK: - Cached document metadata

struct YouTubeVideoMetadata: Codable, Equatable, Sendable {
    let videoId: String
    let title: String
    let channelName: String?
    let sourceURL: String
    let thumbnailURL: String?
    let durationMs: Int?
}

struct YouTubeTranscriptDocument: Codable, Equatable, Sendable {
    let metadata: YouTubeVideoMetadata
    let track: YouTubeCaptionTrack
    let cues: [YouTubeTranscriptCue]
    let paragraphs: [YouTubeTranscriptParagraph]
    let storyboard: YouTubeStoryboard?
    /// Optional for decoding cache files written before artwork-quality
    /// versioning. A missing/old value refreshes only the transcript metadata;
    /// the cache key keeps generated TTS and reading progress reusable.
    let artworkSchemaVersion: Int?
    let extractedAt: Date
    /// UI language that asked the live selector for this track. This differs
    /// from `track.languageCode` when YouTube has to fall back to another
    /// language, and lets later opens reuse that intentional selection.
    let selectedForLanguage: String?
    /// Caption extraction + semantic contract used when raw cues were saved.
    /// Paragraphs are always re-derived on decode, but a pre-P0 cache lacks
    /// structured WebVTT speaker evidence that cannot be reconstructed from
    /// its already-flattened text. A missing version therefore remains a safe
    /// offline fallback while online opens try one fresh extraction first.
    let captionSemanticSchemaVersion: Int?
    /// Every caption track the page offered when this transcript was captured.
    ///
    /// `nil` means unknown — either a cache file written before the language
    /// picker shipped, or a page that never exposed its track list. An empty
    /// array is the authoritative "no alternatives". The picker must treat the
    /// two differently: unknown degrades to showing the current language only.
    ///
    /// Deliberately excluded from `YouTubeCacheStore.cacheKey`: YouTube adding
    /// one track later must not invalidate cached audio and reading progress.
    let availableTracks: [YouTubeCaptionTrackOption]?

    init(
        metadata: YouTubeVideoMetadata,
        track: YouTubeCaptionTrack,
        cues: [YouTubeTranscriptCue],
        paragraphs: [YouTubeTranscriptParagraph]? = nil,
        storyboard: YouTubeStoryboard? = nil,
        artworkSchemaVersion: Int? = YouTubeArtworkCacheSchema.current,
        extractedAt: Date = Date(),
        selectedForLanguage: String? = nil,
        captionSemanticSchemaVersion: Int? = YouTubeCaptionSemanticSchema.current,
        availableTracks: [YouTubeCaptionTrackOption]? = nil
    ) {
        self.metadata = metadata
        self.track = track
        self.cues = cues
        self.paragraphs = paragraphs ?? YouTubeTranscriptGrouper.cuesIntoParagraphs(cues)
        self.storyboard = storyboard
        self.artworkSchemaVersion = artworkSchemaVersion
        self.extractedAt = extractedAt
        self.selectedForLanguage = selectedForLanguage
        self.captionSemanticSchemaVersion = captionSemanticSchemaVersion
        self.availableTracks = availableTracks.map(
            YouTubeCaptionTrackOption.normalized
        )
    }

    private enum CodingKeys: String, CodingKey {
        case metadata
        case track
        case cues
        case paragraphs
        case storyboard
        case artworkSchemaVersion
        case extractedAt
        case selectedForLanguage
        case captionSemanticSchemaVersion
        case availableTracks
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try container.decode(YouTubeVideoMetadata.self, forKey: .metadata)
        track = try container.decode(YouTubeCaptionTrack.self, forKey: .track)
        cues = try container.decode([YouTubeTranscriptCue].self, forKey: .cues)
        // Paragraphs are derived data. Never trust stale paragraph IDs/text
        // from an older cache schema after cue-cleaning or grouping changes.
        paragraphs = YouTubeTranscriptGrouper.cuesIntoParagraphs(cues)
        storyboard = try container.decodeIfPresent(YouTubeStoryboard.self, forKey: .storyboard)
        artworkSchemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .artworkSchemaVersion
        )
        extractedAt = try container.decode(Date.self, forKey: .extractedAt)
        selectedForLanguage = try container.decodeIfPresent(
            String.self,
            forKey: .selectedForLanguage
        )
        captionSemanticSchemaVersion = try container.decodeIfPresent(
            Int.self,
            forKey: .captionSemanticSchemaVersion
        )
        availableTracks = try container.decodeIfPresent(
            [YouTubeCaptionTrackOption].self,
            forKey: .availableTracks
        ).map(YouTubeCaptionTrackOption.normalized)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metadata, forKey: .metadata)
        try container.encode(track, forKey: .track)
        try container.encode(cues, forKey: .cues)
        try container.encode(paragraphs, forKey: .paragraphs)
        try container.encodeIfPresent(storyboard, forKey: .storyboard)
        try container.encodeIfPresent(artworkSchemaVersion, forKey: .artworkSchemaVersion)
        try container.encode(extractedAt, forKey: .extractedAt)
        try container.encodeIfPresent(selectedForLanguage, forKey: .selectedForLanguage)
        try container.encodeIfPresent(
            captionSemanticSchemaVersion,
            forKey: .captionSemanticSchemaVersion
        )
        try container.encodeIfPresent(availableTracks, forKey: .availableTracks)
    }

    /// Tracks worth offering in the picker, current track included even when
    /// the page list is unknown or forgot to describe it.
    var switchableTracks: [YouTubeCaptionTrackOption] {
        let current = YouTubeCaptionTrackOption(
            id: track.baseURL,
            languageCode: track.languageCode,
            name: track.name,
            kind: track.isAutomatic ? "asr" : "manual"
        )
        guard let availableTracks, !availableTracks.isEmpty else { return [current] }
        if availableTracks.contains(where: { $0.matches(track) }) {
            return availableTracks
        }
        return [current] + availableTracks
    }
}

typealias YouTubeTranscriptDoc = YouTubeTranscriptDocument

enum YouTubeTranscriptFailure: String, Error, Codable, Equatable, Sendable, CaseIterable {
    case invalidURL = "invalid_url"
    case noCaptions = "no_captions"
    case live
    case restricted
    case unavailable
    case timeout
    case cancelled
    case unsupportedLanguage = "unsupported_language"
    case malformedResponse = "malformed_response"
    case captionAccess = "caption_access"
    /// YouTube's player document did not initialize far enough to expose its
    /// caption surface. This is transient and is not evidence that the video
    /// requires sign-in, has no captions, or timed out while parsing captions.
    case playerBootstrapFailed = "player_bootstrap_failed"
    /// YouTube presented an anti-automation verification wall. This says
    /// nothing about whether the video itself requires an account to watch.
    case youtubeAccessLimited = "youtube_access_limited"
    /// An explicitly requested caption track could not be fetched. Distinct
    /// from `captionAccess`: the video's captions work, this one track did not,
    /// so the reader keeps playing the track it already had.
    case trackUnavailable = "track_unavailable"
    case network

    var reason: String { rawValue }
}

enum YouTubeTranscriptLanguagePolicy {
    /// This contract is compiled into both the main app and Share Extension.
    /// Keep the small canonical language boundary Foundation-only instead of
    /// depending on the app-only `LanguageDetector.swift` target membership.
    private static let supportedPlaybackLanguages: Set<String> = [
        "en", "zh", "ja", "es", "fr", "de", "pt", "it", "hi",
    ]

    static func playbackLanguage(for identifier: String) throws -> String {
        guard let language = canonicalSupportedLanguage(identifier) else {
            throw YouTubeTranscriptFailure.unsupportedLanguage
        }
        return language
    }

    /// Preserve the selected caption language on document identity and UI even
    /// when a caller constructs an unsupported transcript directly. The
    /// playback route validates support and fails before opening the reader.
    static func documentLanguage(for identifier: String) -> String {
        let normalized = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return canonicalSupportedLanguage(normalized)
            ?? normalized.split(separator: "-").first.map(String.init)
            ?? "und"
    }

    private static func canonicalSupportedLanguage(_ identifier: String) -> String? {
        let primary = identifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        return supportedPlaybackLanguages.contains(primary) ? primary : nil
    }
}

// MARK: - Cross-process handoff

enum YouTubeListenEntry: String, Codable, Equatable, Sendable, CaseIterable {
    case share
    case clipboard
    case scheme
    case paste
    case sample
    case history
}

/// The Share Extension cannot rely on a supported API to launch its containing
/// app. Keep a tiny FIFO in the existing App Group so the next foreground app
/// scene can consume every explicitly shared YouTube link without scraping the
/// user's browser or clipboard history.
enum YouTubePendingLinkStore {
    struct Item: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let rawURL: String
        let entry: YouTubeListenEntry
        let createdAt: Date

        init(
            id: UUID = UUID(),
            rawURL: String,
            entry: YouTubeListenEntry,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.rawURL = rawURL
            self.entry = entry
            self.createdAt = createdAt
        }
    }

    static let appGroup = "group.com.same.castreader"
    private static let storageKey = "youtube.pendingLinks.v1"
    private static let maximumPendingItems = 10
    private static let processLock = NSLock()
    private static let lockFilename = ".youtube-pending-links.lock"

    @discardableResult
    static func enqueue(
        _ rawURL: String,
        entry: YouTubeListenEntry = .share
    ) -> Bool {
        guard let reference = YouTubeURLParser.parse(rawURL) else { return false }
        return withExclusiveAccess {
            var items = pendingUnlocked()
            let canonical = reference.canonicalURLString
            items.removeAll { $0.rawURL == canonical }
            items.append(Item(rawURL: canonical, entry: entry))
            if items.count > maximumPendingItems {
                items.removeFirst(items.count - maximumPendingItems)
            }
            return persistUnlocked(items)
        }
    }

    static func pending() -> [Item] {
        withExclusiveAccess { pendingUnlocked() }
    }

    static func peekNext() -> Item? {
        withExclusiveAccess { pendingUnlocked().first }
    }

    static func matchingItemID(_ rawURL: String) -> UUID? {
        guard let reference = YouTubeURLParser.parse(rawURL) else { return nil }
        let canonical = reference.canonicalURLString
        return withExclusiveAccess {
            pendingUnlocked().first(where: { $0.rawURL == canonical })?.id
        }
    }

    private static func pendingUnlocked() -> [Item] {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return [] }
        // The writer can be the Share Extension process. Refresh the suite
        // while holding the App Group file lock before decoding its queue.
        defaults.synchronize()
        guard
              let data = defaults.data(forKey: scopedStorageKey),
              let decoded = try? JSONDecoder().decode([Item].self, from: data) else {
            return []
        }
        return decoded.filter { YouTubeURLParser.parse($0.rawURL) != nil }
    }

    static func takeNext() -> Item? {
        withExclusiveAccess {
            var items = pendingUnlocked()
            guard !items.isEmpty else { return nil }
            let item = items.removeFirst()
            _ = persistUnlocked(items)
            return item
        }
    }

    static func removeMatching(_ rawURL: String) {
        guard let reference = YouTubeURLParser.parse(rawURL) else { return }
        withExclusiveAccess {
            let canonical = reference.canonicalURLString
            var items = pendingUnlocked()
            let priorCount = items.count
            items.removeAll { $0.rawURL == canonical }
            if items.count != priorCount { _ = persistUnlocked(items) }
        }
    }

    static func acknowledge(_ id: UUID) {
        withExclusiveAccess {
            var items = pendingUnlocked()
            let priorCount = items.count
            items.removeAll { $0.id == id }
            if items.count != priorCount { _ = persistUnlocked(items) }
        }
    }

    static func clear() {
        withExclusiveAccess {
            let defaults = UserDefaults(suiteName: appGroup)
            defaults?.removeObject(forKey: scopedStorageKey)
            defaults?.synchronize()
        }
    }

    private static func persistUnlocked(_ items: [Item]) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(items) else { return false }
        defaults.set(data, forKey: scopedStorageKey)
        return defaults.synchronize()
    }

    /// The extension queue follows the active opaque account namespace. An
    /// item shared while explicitly signed out stays in the fail-closed
    /// `unassigned` partition and is never surfaced to the next account.
    private static var scopedStorageKey: String {
        AccountContentScopeBridge.scopedDefaultsKey(storageKey)
    }

    /// UserDefaults has no atomic read-modify-write primitive across the app
    /// and its Share Extension. A tiny App Group file lock prevents a new share
    /// from being lost while the foreground app consumes another queued URL.
    private static func withExclusiveAccess<T>(_ operation: () -> T) -> T {
        processLock.lock()
        defer { processLock.unlock() }

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else { return operation() }
        let lockURL = container.appendingPathComponent(lockFilename)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard descriptor >= 0 else { return operation() }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            return operation()
        }
        defer { flock(descriptor, LOCK_UN) }
        return operation()
    }
}
