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
    let responseFormat: String
    let returnTimestamps: Bool
    let speed: Double
    let stream: Bool
    let language: String

    enum CodingKeys: String, CodingKey {
        case model
        case input
        case voice
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

    init(paragraphIndex: Int, segmentIndex: Int, audioData: Data, timestamps: [TTSTimestamp], duration: Double, text: String, isWavFormat: Bool = false) {
        self.id = "\(paragraphIndex)-\(segmentIndex)"
        self.paragraphIndex = paragraphIndex
        self.segmentIndex = segmentIndex
        self.audioData = audioData
        self.timestamps = timestamps
        self.duration = duration
        self.text = text
        self.isWavFormat = isWavFormat
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
}
