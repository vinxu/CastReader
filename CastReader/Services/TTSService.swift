//
//  TTSService.swift
//  CastReader
//
//  云端 TTS 单声道路由：把段落文本流式合成为 AudioSegment（边生成边回调入队）。
//  历史：曾支持本地 Kokoro/CoreML（FluidAudio）双引擎，为减小包体积已移除——现仅云端 TTS（见 git 历史）。
//

import Foundation
import UIKit
import AVFoundation

// MARK: - TTS Error

enum TTSError: Error {
    case cancelled
    case generationFailed(String)
}

// MARK: - TTS Service

actor TTSService {
    static let shared = TTSService()

    private var currentRequestId: UUID?

    private init() {}

    // MARK: - TTS Generation

    /// 取消当前 TTS 请求（使流式回调内的 requestId 校验失败而提前退出）。
    func cancelCurrentRequest() async {
        currentRequestId = nil
    }

    /// 生成段落 TTS（流式：每段 AudioSegment 经 onSegmentReady 回调）。仅云端。
    func generateTTSForParagraph(
        paragraphIndex: Int,
        text: String,
        voice: String = Constants.TTS.defaultVoice,
        speed: Double = Constants.TTS.defaultSpeed,
        language: String = Constants.TTS.defaultLanguage,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        let requestId = UUID()
        currentRequestId = requestId
        print("[TTSService] ☁️ Cloud TTS for: \(text.prefix(30))...")
        try await generateCloudTTS(
            requestId: requestId,
            paragraphIndex: paragraphIndex,
            text: text,
            voice: voice,
            speed: speed,
            language: language,
            onSegmentReady: onSegmentReady
        )
    }

    // MARK: - Cloud TTS

    private func generateCloudTTS(
        requestId: UUID,
        paragraphIndex: Int,
        text: String,
        voice: String,
        speed: Double,
        language: String,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        guard currentRequestId == requestId else {
            throw TTSError.cancelled
        }

        var remainingText = text
        var segmentIndex = 0

        // 循环处理后端逐段返回的 unprocessedText（与扩展一致：一次请求只处理一部分）。
        while !remainingText.isEmpty {
            guard currentRequestId == requestId else {
                throw TTSError.cancelled
            }

            do {
                print("[TTSService] 📊 Cloud TTS request #\(segmentIndex): \(remainingText.prefix(50))...")

                let response = try await APIService.shared.generateTTS(
                    text: remainingText,
                    voice: voice,
                    speed: speed,
                    language: language
                )

                guard currentRequestId == requestId else {
                    throw TTSError.cancelled
                }

                print("[TTSService] 📊 Cloud TTS response #\(segmentIndex):")
                print("[TTSService] 📊 - Input text length: \(remainingText.count) chars")
                print("[TTSService] 📊 - Processed text: \(response.processedText?.prefix(100) ?? "nil")...")
                print("[TTSService] 📊 - Unprocessed text: \(response.unprocessedText?.prefix(100) ?? "nil")...")
                print("[TTSService] 📊 - Duration: \(response.safeDuration)s")
                print("[TTSService] 📊 - Timestamps count: \(response.safeTimestamps.count)")

                guard let audioData = Data(base64Encoded: response.audio) else {
                    throw TTSError.generationFailed("Failed to decode audio data")
                }

                guard currentRequestId == requestId else {
                    throw TTSError.cancelled
                }

                let timestamps = response.safeTimestamps
                let duration = response.safeDuration
                // 用 processedText 作为本 segment 文本（不是整段剩余文本）
                let segmentText = response.processedText ?? remainingText

                let rawSegment = AudioSegment(
                    paragraphIndex: paragraphIndex,
                    segmentIndex: segmentIndex,
                    audioData: audioData,
                    timestamps: timestamps,
                    duration: duration,
                    text: segmentText,
                    unprocessedText: response.unprocessedText ?? ""
                )
                // 中文云端常无 duration（且无词时间戳）→ 用真实音频时长兜底，供解读时间线/进度。
                // 词时间戳不合成：朗读对齐扩展，无词时间戳语言走句子级高亮。
                let segment = ensureDuration(rawSegment)

                await onSegmentReady(segment)

                if let unprocessed = response.unprocessedText, !unprocessed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    remainingText = unprocessed
                    segmentIndex += 1
                    print("[TTSService] 📊 More text to process, continuing with segment #\(segmentIndex)")
                } else {
                    print("[TTSService] 📊 All text processed for paragraph \(paragraphIndex)")
                    break
                }

            } catch is CancellationError {
                throw TTSError.cancelled
            } catch let error as TTSError {
                throw error
            } catch {
                print("[TTSService] Cloud TTS failed: \(error)")
                throw TTSError.generationFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - 时间戳合成（后端对中文等语言不返回词时间戳时，按真实音频时长在字符上均匀合成）

    /// 若 segment 无 API duration（中文云端常为 0），用音频真实时长兜底（解读时间线/进度依赖）。
    /// **不合成词时间戳**——朗读对齐扩展：无词时间戳的语言走句子级高亮（见 ReadAloudViewModel）；
    /// 解读需要时间线时由 ExplainViewModel 用 synthesizeTimestamps 自行合成（仅解读路径）。
    nonisolated private func ensureDuration(_ seg: AudioSegment) -> AudioSegment {
        guard seg.duration <= 0.01 else { return seg }
        let dur = audioDuration(seg.audioData)
        guard dur > 0 else { return seg }
        return AudioSegment(
            paragraphIndex: seg.paragraphIndex,
            segmentIndex: seg.segmentIndex,
            audioData: seg.audioData,
            timestamps: seg.timestamps,
            duration: dur,
            text: seg.text,
            isWavFormat: seg.isWavFormat,
            unprocessedText: seg.unprocessedText,
            speaker: seg.speaker
        )
    }

    /// 解析 MP3/WAV 音频的真实时长（API duration 缺失时兜底）。
    nonisolated private func audioDuration(_ data: Data) -> Double {
        (try? AVAudioPlayer(data: data))?.duration ?? 0
    }

    /// 把文本切成可在原文中顺序定位的 token：CJK / 标点逐字，ASCII 字母数字成串，空白跳过。
    /// internal（非 private）以便 EvalTests 做离线确定性校验。
    nonisolated func tokenizeForTimestamps(_ text: String) -> [String] {
        var tokens: [String] = []
        var run = ""
        func flush() { if !run.isEmpty { tokens.append(run); run = "" } }
        for ch in text {
            if ch.isWhitespace { flush(); continue }
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                run.append(ch)
            } else {
                flush()
                tokens.append(String(ch))
            }
        }
        flush()
        return tokens
    }

    /// 时长在 token 上均匀分配，token 即可在 segment 文本中顺序定位（满足词高亮匹配）。
    /// internal（非 private）以便 EvalTests 做离线确定性校验。
    nonisolated func synthesizeTimestamps(text: String, duration: Double) -> [TTSTimestamp] {
        guard duration > 0 else { return [] }
        let tokens = tokenizeForTimestamps(text)
        guard !tokens.isEmpty else { return [] }
        let per = duration / Double(tokens.count)
        return tokens.enumerated().map { i, tok in
            TTSTimestamp(word: tok, startTime: Double(i) * per, endTime: Double(i + 1) * per)
        }
    }
}
