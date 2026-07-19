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
    let voiceCode: String
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

    init(input: String, voice: String = "af_heart", speed: Double = 1.0, language: String = "en") {
        self.model = "kokoro"
        self.input = input
        self.voice = voice
        self.voiceCode = voice
        self.responseFormat = "mp3"
        self.returnTimestamps = true
        self.speed = speed
        self.stream = false
        self.language = language
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

/// Response-level safety gate shared by every reader source. A language may
/// advertise word timing, but one sparse response must only downgrade that
/// audio segment to sentence/segment highlighting.
enum TTSTimestampQuality {
    static func hasReliableWordGranularity(text: String, timestamps: [TTSTimestamp]) -> Bool {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !timestamps.isEmpty else { return false }
        let sourceWordCount = text.split(whereSeparator: { $0.isWhitespace })
            .filter { !normalizeCoverageText(String($0)).isEmpty }.count
        guard sourceWordCount > 0,
              timestamps.count >= max(1, Int(ceil(Double(sourceWordCount) * 0.75))) else {
            return false
        }
        let reference = normalizeCoverageText(text)
        let timed = normalizeCoverageText(timestamps.map(\.word).joined(separator: " "))
        guard !reference.isEmpty, !timed.isEmpty else { return false }
        return Double(timed.count) / Double(reference.count) >= 0.8
    }

    private static func normalizeCoverageText(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
            .map(String.init).joined()
    }
}

/// Natural TTS request units shared by every reader source. English and the
/// production-verified Spanish voices keep paragraph requests for word timing;
/// segment-timed languages use one natural sentence per request so audio and
/// the painted sentence own exactly the same text unit. This mirrors Android
/// `TtsSentenceSegmenter` and the browser extension's sentence contract.
enum TTSSentenceSegmenter {
    private static let terminals: Set<Character> = [".", "!", "?", "。", "！", "？", "…", "।", "॥"]
    private static let closers: Set<Character> = ["\"", "'", "»", "’", "”", ")", "]", "）", "】", "」", "』", "〉", "》"]

    static func requestUnits(_ text: String, language: String) -> [String] {
        let normalized = normalizeWhitespace(text, language: language)
        guard !normalized.isEmpty else { return [] }
        if SupportedTTSLanguage(identifier: language)?.timestampMode == "word" {
            return [normalized]
        }
        let units = fallbackSentenceSegments(normalized)
        return units.isEmpty ? [normalized] : units
    }

    private static func normalizeWhitespace(_ text: String, language: String) -> String {
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
            let removesVisualCJKWrap = (code == "zh" || code == "ja") &&
                containsLineBreak &&
                previous.map(isCJKOrKana) == true &&
                next.map(isCJKOrKana) == true
            if !removesVisualCJKWrap, !output.isEmpty, !output.hasSuffix(" "), next != nil {
                output.append(" ")
            }
            index = end
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private static func fallbackSentenceSegments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var terminalSeen = false

        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            current = ""
            terminalSeen = false
        }

        for character in text {
            if terminalSeen, !closers.contains(character), !character.isWhitespace {
                flush()
            }
            current.append(character)
            if terminals.contains(character) { terminalSeen = true }
        }
        flush()
        return result
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
