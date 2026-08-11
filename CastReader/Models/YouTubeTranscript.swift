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

    var canonicalURLString: String {
        var result = "https://www.youtube.com/watch?v=\(videoId)"
        if let startSeconds {
            result += "&t=\(startSeconds)s"
        }
        return result
    }

    var canonicalURL: URL? { URL(string: canonicalURLString) }
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

    init(text: String, startMs: Int, durationMs: Int = 0) {
        self.text = text
        self.startMs = startMs
        self.durationMs = durationMs
    }
}

struct YouTubeTranscriptParagraph: Codable, Equatable, Sendable, Identifiable {
    let id: Int
    let text: String
    let startMs: Int
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

enum YouTubeTranscriptGrouper {
    /// Line-for-line behavioral port of readout-desktop's
    /// `cuesIntoParagraphs`: stable sort, break on gap > 2000ms or the current
    /// UTF-16 length > 150 *before* appending the next cue.
    static func cuesIntoParagraphs(
        _ cues: [YouTubeTranscriptCue]
    ) -> [YouTubeTranscriptParagraph] {
        let sorted = cues.enumerated().sorted { lhs, rhs in
            if lhs.element.startMs != rhs.element.startMs {
                return lhs.element.startMs < rhs.element.startMs
            }
            return lhs.offset < rhs.offset
        }.map(\.element)

        var grouped: [(text: String, startMs: Int)] = []
        var current = ""
        var previousEnd: Int64 = 0
        var groupStart = 0

        for cue in sorted {
            let text = cue.text
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let gap = Int64(cue.startMs) - previousEnd
            if !current.isEmpty,
               gap > 2_000 || (current as NSString).length > 150 {
                grouped.append((current.trimmingCharacters(in: .whitespacesAndNewlines), groupStart))
                current = text
                groupStart = cue.startMs
            } else {
                if current.isEmpty { groupStart = cue.startMs }
                current = current.isEmpty ? text : "\(current) \(text)"
            }
            let end = Int64(cue.startMs).addingReportingOverflow(
                Int64(cue.durationMs)
            )
            previousEnd = end.overflow ? Int64.max : end.partialValue
        }

        if !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            grouped.append((current.trimmingCharacters(in: .whitespacesAndNewlines), groupStart))
        }

        return grouped.enumerated().map { index, item in
            YouTubeTranscriptParagraph(id: index, text: item.text, startMs: item.startMs)
        }
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
        self.availableTracks = availableTracks.map(
            YouTubeCaptionTrackOption.normalized
        )
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
              let data = defaults.data(forKey: storageKey),
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
            defaults?.removeObject(forKey: storageKey)
            defaults?.synchronize()
        }
    }

    private static func persistUnlocked(_ items: [Item]) -> Bool {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = try? JSONEncoder().encode(items) else { return false }
        defaults.set(data, forKey: storageKey)
        return defaults.synchronize()
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
