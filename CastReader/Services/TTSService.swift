//
//  TTSService.swift
//  CastReader
//
//  Coordinates between local (CoreML) and cloud TTS based on:
//  1. If local model not downloaded → always use cloud
//  2. If local model downloaded → use user's setting (local or cloud)
//  3. If local TTS fails in background (GPU restriction) → fallback to cloud
//

import Foundation
import UIKit

// MARK: - TTS Provider

enum TTSProvider: String {
    case local = "local"
    case cloud = "cloud"
}

// MARK: - TTS Service

actor TTSService {
    static let shared = TTSService()

    private let localTTS = LocalTTSService.shared
    private var currentRequestId: UUID?

    private init() {}

    // MARK: - Provider Selection

    /// Get current TTS provider based on model availability and user setting
    nonisolated var currentProvider: TTSProvider {
        // If local model not downloaded → always cloud
        if !LocalTTSService.checkModelExists() {
            return .cloud
        }

        // If local model downloaded → use user setting
        let setting = UserDefaults.standard.string(forKey: Constants.Storage.ttsProviderKey) ?? "local"
        return TTSProvider(rawValue: setting) ?? .local
    }

    /// Check if local model is available
    nonisolated var isLocalModelAvailable: Bool {
        return LocalTTSService.checkModelExists()
    }

    /// Set preferred TTS provider (only effective when local model is downloaded)
    nonisolated func setPreferredProvider(_ provider: TTSProvider) {
        UserDefaults.standard.set(provider.rawValue, forKey: Constants.Storage.ttsProviderKey)
    }

    // MARK: - TTS Generation

    /// Cancel current TTS request
    func cancelCurrentRequest() async {
        currentRequestId = nil
        await localTTS.cancelCurrentRequest()
    }

    /// Generate TTS for a paragraph (streaming mode with segment callbacks)
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

        let modelExists = LocalTTSService.checkModelExists()
        let provider = currentProvider

        print("[TTSService] Model exists: \(modelExists), Provider: \(provider)")

        switch provider {
        case .local:
            print("[TTSService] 📱 Using LOCAL TTS for: \(text.prefix(30))...")
            do {
                try await generateLocalTTS(
                    requestId: requestId,
                    paragraphIndex: paragraphIndex,
                    text: text,
                    voice: voice,
                    speed: speed,
                    language: language,
                    onSegmentReady: onSegmentReady
                )
            } catch LocalTTSError.cancelled {
                // 取消请求不 fallback
                throw LocalTTSError.cancelled
            } catch {
                // 本地 TTS 失败（可能是后台 GPU 限制），fallback 到云端
                let errorDesc = error.localizedDescription
                if errorDesc.contains("background") || errorDesc.contains("GPU") || errorDesc.contains("Permission") {
                    print("[TTSService] ⚠️ Local TTS failed (background GPU restriction), falling back to cloud")
                } else {
                    print("[TTSService] ⚠️ Local TTS failed: \(errorDesc), falling back to cloud")
                }
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

        case .cloud:
            print("[TTSService] ☁️ Using CLOUD TTS for: \(text.prefix(30))...")
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
    }

    // MARK: - Local TTS

    private func generateLocalTTS(
        requestId: UUID,
        paragraphIndex: Int,
        text: String,
        voice: String,
        speed: Double,
        language: String,
        onSegmentReady: @escaping (AudioSegment) async -> Void
    ) async throws {
        try await localTTS.generateTTSForParagraph(
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
            throw LocalTTSError.cancelled
        }

        var remainingText = text
        var segmentIndex = 0

        // Loop until all text is processed (like web does)
        while !remainingText.isEmpty {
            guard currentRequestId == requestId else {
                throw LocalTTSError.cancelled
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
                    throw LocalTTSError.cancelled
                }

                // Debug: Log what API actually processed
                print("[TTSService] 📊 Cloud TTS response #\(segmentIndex):")
                print("[TTSService] 📊 - Input text length: \(remainingText.count) chars")
                print("[TTSService] 📊 - Processed text: \(response.processedText?.prefix(100) ?? "nil")...")
                print("[TTSService] 📊 - Unprocessed text: \(response.unprocessedText?.prefix(100) ?? "nil")...")
                print("[TTSService] 📊 - Duration: \(response.safeDuration)s")
                print("[TTSService] 📊 - Timestamps count: \(response.safeTimestamps.count)")

                // Decode base64 audio
                guard let audioData = Data(base64Encoded: response.audio) else {
                    throw LocalTTSError.generationFailed("Failed to decode audio data")
                }

                guard currentRequestId == requestId else {
                    throw LocalTTSError.cancelled
                }

                // Use timestamps from response (already in correct format)
                let timestamps = response.safeTimestamps
                let duration = response.safeDuration

                // Use processedText for this segment's text (not full remaining text)
                let segmentText = response.processedText ?? remainingText

                let segment = AudioSegment(
                    paragraphIndex: paragraphIndex,
                    segmentIndex: segmentIndex,
                    audioData: audioData,
                    timestamps: timestamps,
                    duration: duration,
                    text: segmentText,
                    unprocessedText: response.unprocessedText ?? ""
                )

                await onSegmentReady(segment)

                // Check if there's more text to process
                if let unprocessed = response.unprocessedText, !unprocessed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    remainingText = unprocessed
                    segmentIndex += 1
                    print("[TTSService] 📊 More text to process, continuing with segment #\(segmentIndex)")
                } else {
                    // All text processed
                    print("[TTSService] 📊 All text processed for paragraph \(paragraphIndex)")
                    break
                }

            } catch is CancellationError {
                throw LocalTTSError.cancelled
            } catch let error as LocalTTSError {
                throw error
            } catch {
                print("[TTSService] Cloud TTS failed: \(error)")
                throw LocalTTSError.generationFailed(error.localizedDescription)
            }
        }
    }

    // MARK: - Model Management

    /// Download local model if needed
    func downloadLocalModelIfNeeded(onProgress: ((Double) -> Void)? = nil) async throws {
        try await localTTS.downloadModelIfNeeded(onProgress: onProgress)
    }

    /// Load/initialize local TTS model
    func loadLocalModel() async throws {
        try await localTTS.loadModel()
    }
}
