//
//  TTSTimestamp.swift
//  CastReader
//

import Foundation

// MARK: - TTS Request
struct TTSRequest: Codable {
    let model: String
    let input: String
    let voice: String
    let voiceCode: String?
    let responseFormat: String
    let returnTimestamps: Bool
    let speed: Double
    let stream: Bool
    let language: String

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
        case voiceCode = "voice_code"
        case responseFormat = "response_format"
        case returnTimestamps = "return_timestamps"
        case speed
        case stream
        case language
    }

    init(
        input: String,
        voice: String = "af_heart",
        speed: Double = 1.0,
        language: String = "en",
        includeVoiceCode: Bool = true
    ) {
        self.model = "kokoro"
        self.input = input
        self.voice = voice
        // Preserve the existing request body for every caller by default.
        // YouTube explicitly opts out for non-English/Chinese caption tracks,
        // whose backend contract accepts only the canonical `voice` field.
        self.voiceCode = includeVoiceCode ? voice : nil
        self.responseFormat = "mp3"
        // Han/Kana/Hangul readers intentionally paint the natural request
        // unit as one sentence. Asking either engine for synthetic per-glyph
        // timing wastes work and can accidentally re-enable character chasing.
        self.returnTimestamps = TTSHighlightPolicy.usesWordTimestamps(language: language)
        self.speed = speed
        self.stream = false
        self.language = language
    }
}

/// Product-level highlighting contract. This is deliberately stricter than
/// `TTSTimestampQuality`: a response can be internally well-formed while the
/// selected reading language still calls for natural sentence highlighting.
enum TTSHighlightPolicy {
    private static let segmentTimedLanguageCodes: Set<String> = ["zh", "ja", "ko"]

    static func usesWordTimestamps(language: String) -> Bool {
        let primary = language.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
        if segmentTimedLanguageCodes.contains(primary) { return false }
        return SupportedTTSLanguage(identifier: language)?.timestampMode != "segment"
    }

    static func displayTimestamps(
        _ timestamps: [TTSTimestamp],
        language: String
    ) -> [TTSTimestamp] {
        usesWordTimestamps(language: language) ? timestamps : []
    }
}

// MARK: - TTS Response
struct TTSResponse: Codable {
    let audio: String // base64 encoded mp3
    let audioFormat: String?
    let timestamps: [TTSTimestamp]?  // Made optional
    let duration: Double?  // Made optional
    let processedText: String?
    let unprocessedText: String?

    enum CodingKeys: String, CodingKey {
        case audio
        case audioFormat = "audio_format"
        case timestamps
        case duration
        case processedText = "processed_text"
        case unprocessedText = "unprocessed_text"
    }

    // Provide defaults for optional fields
    var safeDuration: Double {
        duration ?? 0
    }

    var safeTimestamps: [TTSTimestamp] {
        timestamps ?? []
    }
}

// MARK: - TTS Timestamp
struct TTSTimestamp: Codable {
    let word: String
    let startTime: Double
    let endTime: Double

    enum CodingKeys: String, CodingKey {
        case word
        case startTime = "start_time"
        case endTime = "end_time"
    }
}

/// Response-level safety gate shared by every reader source. This validates
/// the shape and text coverage of a candidate word timeline. The separate
/// `TTSHighlightPolicy` first decides whether the reading language is allowed
/// to use word highlighting at all.
enum TTSTimestampQuality {
    static func hasReliableWordGranularity(
        text: String,
        timestamps: [TTSTimestamp],
        duration: Double
    ) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              duration.isFinite,
              duration > 0,
              !timestamps.isEmpty else { return false }

        let normalizedReference = normalizeCoverageText(text)
        let meaningfulTokens = timestamps.compactMap { timestamp -> String? in
            let token = normalizeCoverageText(timestamp.word)
            return token.isEmpty ? nil : token
        }
        guard !normalizedReference.isEmpty, meaningfulTokens.count >= 2 else {
            // Chinese/Japanese sentence responses commonly contain exactly
            // one timestamp whose `word` is the entire sentence.
            return false
        }

        let rangeTolerance = min(0.5, max(0.15, duration * 0.02))
        var previousStart = -Double.infinity
        var previousEnd = -Double.infinity
        for timestamp in timestamps {
            let start = timestamp.startTime
            let end = timestamp.endTime
            guard start.isFinite,
                  end.isFinite,
                  start >= 0,
                  end > start,
                  end <= duration + rangeTolerance,
                  start + 0.001 >= previousStart,
                  end + 0.001 >= previousEnd else {
                return false
            }
            previousStart = start
            previousEnd = end
        }

        let sourceWordCount = text.split(whereSeparator: { $0.isWhitespace })
            .filter { !normalizeCoverageText(String($0)).isEmpty }.count
        guard sourceWordCount > 0 else { return false }
        if sourceWordCount > 1 {
            // Space-delimited languages: tolerate a small number of tokenizer
            // merges, but reject phrase/sentence timestamps.
            guard meaningfulTokens.count >= Int(ceil(Double(sourceWordCount) * 0.75)) else {
                return false
            }
        } else if normalizedReference.count >= 8 {
            // Compact scripts have no dependable whitespace word count. A
            // loose density floor rejects sparse phrase timing without
            // assuming that one Han/Kana grapheme equals one spoken word.
            let minimumCompactTokens = max(2, Int(ceil(Double(normalizedReference.count) / 6.0)))
            guard meaningfulTokens.count >= minimumCompactTokens else { return false }
        }

        // Measure ordered text coverage instead of raw length. This prevents
        // duplicated or unrelated timestamp words from passing the gate.
        var cursor = normalizedReference.startIndex
        var matchedCharacters = 0
        var firstMatchedStart: String.Index?
        var lastMatchedEnd: String.Index?
        for token in meaningfulTokens {
            guard cursor < normalizedReference.endIndex,
                  let range = normalizedReference.range(
                    of: token,
                    range: cursor..<normalizedReference.endIndex
                  ) else { continue }
            if firstMatchedStart == nil { firstMatchedStart = range.lowerBound }
            matchedCharacters += token.count
            cursor = range.upperBound
            lastMatchedEnd = range.upperBound
        }
        guard Double(matchedCharacters) / Double(normalizedReference.count) >= 0.8 else {
            return false
        }

        // Overall coverage alone can hide a missing prefix or suffix. In
        // particular, the TTS aligner used to return 90%+ coverage for lyric
        // captions while omitting the final 2–3 spoken words. A segment is
        // word-reliable only when the ordered timestamps reach both readable
        // ends; otherwise the reader must use its sentence-level fallback.
        return firstMatchedStart == normalizedReference.startIndex
            && lastMatchedEnd == normalizedReference.endIndex
    }

    private static func normalizeCoverageText(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(String.init).joined()
    }
}

/// Script-neutral sentence boundary contract shared by TTS, native text, OCR,
/// PDF reflow and Now Playing captions. Keeping the ranges here prevents each
/// input format from silently losing Japanese/Chinese/Hindi punctuation or
/// splitting common German abbreviations into fake sentences.
enum ReadingSentenceContract {
    private static let terminals: Set<Character> = [
        ".", "!", "?", ";", "。", "！", "？", "；", "…", "।", "॥"
    ]
    private static let closers: Set<Character> = [
        "\"", "'", "»", "’", "”", ")", "]", "）", "】", "」", "』", "〉", "》"
    ]
    private static let periodAbbreviations: Set<String> = [
        "abb", "bsp", "bzw", "ca", "dr", "etc", "ggf", "inkl", "kap",
        "mr", "mrs", "nr", "prof", "s", "sog", "u", "usw", "vgl", "z"
    ]

    static func segments(_ text: String, lineBreakIsBoundary: Bool = false) -> [String] {
        stringRanges(in: text, lineBreakIsBoundary: lineBreakIsBoundary).map {
            String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    /// Character offsets are used by the DOM bridge, whose paragraph contract
    /// is expressed in user-visible characters rather than OCR boxes.
    static func characterRanges(in text: String, lineBreakIsBoundary: Bool = false) -> [Range<Int>] {
        stringRanges(in: text, lineBreakIsBoundary: lineBreakIsBoundary).map {
            text.distance(from: text.startIndex, to: $0.lowerBound)
                ..< text.distance(from: text.startIndex, to: $0.upperBound)
        }
    }

    /// PDFKit/NSString consumers require UTF-16 ranges. Derive them from real
    /// String.Index ranges so emoji and supplementary-plane characters do not
    /// shift every highlight that follows them.
    static func nsRanges(in text: String, lineBreakIsBoundary: Bool = false) -> [NSRange] {
        stringRanges(in: text, lineBreakIsBoundary: lineBreakIsBoundary).map { NSRange($0, in: text) }
    }

    static func normalizeWhitespace(_ text: String, language: String) -> String {
        let code = SupportedTTSLanguage.canonicalCode(language)
        let characters = Array(text)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard character.isWhitespace else {
                output.append(character)
                index += 1
                continue
            }

            var end = index + 1
            var containsLineBreak = character == "\n" || character == "\r"
            while end < characters.count, characters[end].isWhitespace {
                containsLineBreak = containsLineBreak || characters[end] == "\n" || characters[end] == "\r"
                end += 1
            }
            let previous = output.last
            let next = end < characters.count ? characters[end] : nil
            let removesVisualCJKWrap = (code == "zh" || code == "ja") && containsLineBreak &&
                previous.map(isCJKOrKana) == true && next.map(isCJKOrKana) == true
            if !removesVisualCJKWrap, !output.isEmpty, !output.hasSuffix(" "), next != nil {
                output.append(" ")
            }
            index = end
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isCJKOrKana(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x9FFF, 0x3040...0x30FF, 0x31F0...0x31FF,
                 0x3000...0x303F, 0xFF00...0xFFEF:
                return true
            default:
                return false
            }
        }
    }

    private static func stringRanges(
        in text: String,
        lineBreakIsBoundary: Bool
    ) -> [Range<String.Index>] {
        guard !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var start = text.startIndex
        var cursor = text.startIndex
        var terminalSeen = false

        func appendRange(endingAt end: String.Index) {
            var lower = start
            var upper = end
            while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
            while upper > lower {
                let previous = text.index(before: upper)
                guard text[previous].isWhitespace else { break }
                upper = previous
            }
            if lower < upper { ranges.append(lower..<upper) }
            start = end
            terminalSeen = false
        }

        func isAbbreviationPeriod(at index: String.Index) -> Bool {
            var lower = index
            while lower > start {
                let previous = text.index(before: lower)
                guard text[previous].isLetter else { break }
                lower = previous
            }
            let token = String(text[lower..<index]).lowercased()
            if periodAbbreviations.contains(token) { return true }

            // Initials and spaced forms such as “z. B.” stay in the same
            // sentence. The final punctuation still closes the real sentence.
            if token.count == 1 {
                var lookahead = text.index(after: index)
                while lookahead < text.endIndex, text[lookahead].isWhitespace {
                    lookahead = text.index(after: lookahead)
                }
                return lookahead < text.endIndex && text[lookahead].isLetter
            }
            return false
        }

        while cursor < text.endIndex {
            let character = text[cursor]
            if terminalSeen, !closers.contains(character), !character.isWhitespace {
                appendRange(endingAt: cursor)
            }
            let next = text.index(after: cursor)
            if terminals.contains(character) {
                if character != "." ||
                    ((next == text.endIndex || text[next].isWhitespace) && !isAbbreviationPeriod(at: cursor)) {
                    terminalSeen = true
                }
            } else if lineBreakIsBoundary, (character == "\n" || character == "\r") {
                terminalSeen = true
            }
            cursor = next
        }
        appendRange(endingAt: text.endIndex)
        return ranges
    }
}

/// Natural TTS request units shared by every reader source. Catalog capability
/// controls request batching only: word-capable profiles may keep a paragraph,
/// while segment profiles use one natural sentence per request so audio and
/// the painted sentence own the same text unit. Actual highlight granularity
/// is still decided independently for every returned AudioSegment above.
enum TTSSentenceSegmenter {

    static func requestUnits(_ text: String, language: String) -> [String] {
        let normalized = ReadingSentenceContract.normalizeWhitespace(text, language: language)
        guard !normalized.isEmpty else { return [] }
        if SupportedTTSLanguage(identifier: language)?.timestampMode == "word" {
            return [normalized]
        }
        let units = ReadingSentenceContract.segments(normalized)
        return units.isEmpty ? [normalized] : units
    }
}

// MARK: - Audio Segment
struct AudioSegment: Identifiable {
    let id: String
    let paragraphIndex: Int
    let segmentIndex: Int
    let audioData: Data
    let timestamps: [TTSTimestamp]
    let duration: Double
    let text: String
    let isWavFormat: Bool  // true for local TTS (WAV), false for cloud TTS (MP3)
    let unprocessedText: String  // API 返回的未处理文本（用于流式渲染）
    let speaker: String?  // 当前说话者 ID（如 "A", "B"）或 "narrator"

    init(paragraphIndex: Int, segmentIndex: Int, audioData: Data, timestamps: [TTSTimestamp], duration: Double, text: String, isWavFormat: Bool = false, unprocessedText: String = "", speaker: String? = nil) {
        self.id = "\(paragraphIndex)-\(segmentIndex)"
        self.paragraphIndex = paragraphIndex
        self.segmentIndex = segmentIndex
        self.audioData = audioData
        self.timestamps = timestamps
        self.duration = duration
        self.text = text
        self.isWavFormat = isWavFormat
        self.unprocessedText = unprocessedText
        self.speaker = speaker
    }
}

// MARK: - Paragraph TTS State
enum TTSStatus: Equatable {
    case pending
    case loading
    case streaming
    case ready
    case error(String)

    var isLoading: Bool {
        self == .loading
    }

    var isStreaming: Bool {
        self == .streaming
    }

    var isLoadingOrStreaming: Bool {
        self == .loading || self == .streaming
    }

    var isReady: Bool {
        self == .ready
    }

    var isPending: Bool {
        self == .pending
    }
}

struct ParagraphTTSState {
    var status: TTSStatus = .pending
    var segments: [AudioSegment] = []
    var totalDuration: Double = 0
    var error: String?
    var unprocessedText: String = ""  // API 返回的未处理文本（流式渲染时显示）
}
