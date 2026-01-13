//
//  LocalTTSService.swift
//  CastReader
//
//  Local TTS service using FluidAudioTTS (CoreML-based Kokoro).
//  Uses sentence-based synthesis for responsive cancellation.
//  Supports GPU/CPU mode switching for background audio playback.
//

import Foundation
import AVFoundation
import CoreML
import FluidAudio
import FluidAudioTTS
import ZIPFoundation

// MARK: - Local TTS Error

enum LocalTTSError: Error, LocalizedError {
    case modelNotLoaded
    case modelNotDownloaded
    case voiceNotLoaded
    case generationFailed(String)
    case invalidOutput
    case audioEncodingFailed
    case cancelled
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "TTS model is not loaded"
        case .modelNotDownloaded:
            return "TTS model is not downloaded"
        case .voiceNotLoaded:
            return "Voice embedding not loaded"
        case .generationFailed(let message):
            return "TTS generation failed: \(message)"
        case .invalidOutput:
            return "Invalid TTS output"
        case .audioEncodingFailed:
            return "Failed to encode audio to WAV"
        case .cancelled:
            return "TTS request was cancelled"
        case .downloadFailed(let message):
            return "Model download failed: \(message)"
        }
    }
}

// MARK: - Local TTS Service

actor LocalTTSService {
    static let shared = LocalTTSService()

    // COS model download URL
    private static let modelDownloadURL = "https://castreader-kokoro-ios-1323065328.cos.accelerate.myqcloud.com/kokoro-82m-coreml.zip"

    private var isModelLoaded = false
    private var ttsManager: TtSManager?
    private var currentRequestId: UUID?
    private var isDownloading = false

    // Audio sample rate (FluidAudioTTS Kokoro uses 24kHz)
    private let sampleRate: Double = 24000

    // GPU/CPU mode switching for background playback
    private var currentComputeUnits: MLComputeUnits = .cpuAndGPU
    private var isSwitchingMode = false

    private init() {}

    // MARK: - WAV Helper

    /// Check if data has a valid WAV header
    private func hasWavHeader(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let header = String(data: data.prefix(4), encoding: .ascii)
        return header == "RIFF"
    }

    /// Create WAV header for PCM audio data
    private func createWavData(from pcmData: Data) -> Data {
        let sampleRate: UInt32 = 24000
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        let fileSize = 36 + dataSize

        var wavData = Data()

        // RIFF header
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt subchunk
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // Subchunk1Size
        wavData.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // AudioFormat (PCM)
        wavData.append(contentsOf: withUnsafeBytes(of: channels.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: sampleRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        wavData.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data subchunk
        wavData.append(contentsOf: "data".utf8)
        wavData.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        wavData.append(pcmData)

        return wavData
    }

    /// Ensure audio data is in WAV format
    private func ensureWavFormat(_ data: Data) -> Data {
        if hasWavHeader(data) {
            print("[LocalTTSService] Audio already has WAV header")
            return data
        } else {
            print("[LocalTTSService] Adding WAV header to PCM data (\(data.count) bytes)")
            return createWavData(from: data)
        }
    }

    // MARK: - Model Directory

    /// Get the FluidAudioTTS cache directory
    private static func getCacheDirectory() -> URL {
        #if os(macOS)
        let baseDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache")
        #else
        let baseDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #endif
        return baseDirectory.appendingPathComponent("fluidaudio")
    }

    /// Get the Kokoro models directory
    private static func getKokoroDirectory() -> URL {
        return getCacheDirectory().appendingPathComponent("Models/kokoro")
    }

    /// Check if the model files are already downloaded
    static func checkModelExists() -> Bool {
        let kokoroDir = getKokoroDirectory()
        let model5s = kokoroDir.appendingPathComponent("kokoro_21_5s.mlmodelc")
        let model15s = kokoroDir.appendingPathComponent("kokoro_21_15s.mlmodelc")
        let vocab = kokoroDir.appendingPathComponent("vocab_index.json")

        let exists = FileManager.default.fileExists(atPath: model5s.path) &&
                     FileManager.default.fileExists(atPath: model15s.path) &&
                     FileManager.default.fileExists(atPath: vocab.path)

        return exists
    }

    // MARK: - Public API

    /// Check if the local TTS is ready
    var isReady: Bool {
        return isModelLoaded && ttsManager?.isAvailable == true
    }

    /// Check if model is downloaded
    var isModelDownloaded: Bool {
        return Self.checkModelExists()
    }

    /// Cancel current TTS request
    func cancelCurrentRequest() {
        currentRequestId = nil
        print("[LocalTTSService] Request cancelled")
    }

    /// Download model from COS if not already downloaded
    /// Returns progress updates via callback
    func downloadModelIfNeeded(onProgress: ((Double) -> Void)? = nil) async throws {
        // Already downloaded
        if Self.checkModelExists() {
            print("[LocalTTSService] Model already exists, skipping download")
            onProgress?(1.0)
            return
        }

        // Already downloading
        if isDownloading {
            print("[LocalTTSService] Download already in progress")
            return
        }

        isDownloading = true
        defer { isDownloading = false }

        print("[LocalTTSService] Starting model download from COS...")

        guard let url = URL(string: Self.modelDownloadURL) else {
            throw LocalTTSError.downloadFailed("Invalid download URL")
        }

        // Download to temp file
        let tempDir = FileManager.default.temporaryDirectory
        let zipPath = tempDir.appendingPathComponent("kokoro-82m-coreml.zip")

        // Remove existing temp file
        try? FileManager.default.removeItem(at: zipPath)

        // Download with progress tracking using bytes
        let (asyncBytes, response) = try await URLSession.shared.bytes(from: url)

        let expectedLength = response.expectedContentLength
        var downloadedData = Data()
        downloadedData.reserveCapacity(expectedLength > 0 ? Int(expectedLength) : 200_000_000)

        var downloadedBytes: Int64 = 0
        let progressInterval: Int64 = 1_000_000 // Update every 1MB
        var lastProgressUpdate: Int64 = 0

        for try await byte in asyncBytes {
            downloadedData.append(byte)
            downloadedBytes += 1

            // Update progress periodically
            if downloadedBytes - lastProgressUpdate >= progressInterval {
                lastProgressUpdate = downloadedBytes
                if expectedLength > 0 {
                    let progress = Double(downloadedBytes) / Double(expectedLength) * 0.8 // 80% for download
                    await MainActor.run {
                        onProgress?(progress)
                    }
                    print("[LocalTTSService] Download progress: \(Int(progress * 100))%")
                }
            }
        }

        // Write to file
        try downloadedData.write(to: zipPath)
        print("[LocalTTSService] Download complete (\(downloadedData.count) bytes), unzipping...")
        await MainActor.run {
            onProgress?(0.85)
        }

        // Create destination directory
        let kokoroDir = Self.getKokoroDirectory()
        try FileManager.default.createDirectory(at: kokoroDir, withIntermediateDirectories: true)

        // Unzip
        try FileManager.default.unzipItem(at: zipPath, to: kokoroDir.deletingLastPathComponent())
        print("[LocalTTSService] Unzip complete")
        await MainActor.run {
            onProgress?(0.95)
        }

        // Clean up zip file
        try? FileManager.default.removeItem(at: zipPath)

        await MainActor.run {
            onProgress?(1.0)
        }
        print("[LocalTTSService] Model download and extraction complete")
    }

    /// Load/initialize the TTS model
    func loadModel() async throws {
        // Ensure model is downloaded first
        if !Self.checkModelExists() {
            try await downloadModelIfNeeded()
        }

        do {
            print("[LocalTTSService] Initializing FluidAudioTTS TtSManager...")

            let manager = TtSManager(defaultVoice: Constants.TTS.defaultVoice)
            try await manager.initialize()

            ttsManager = manager
            isModelLoaded = true
            print("[LocalTTSService] FluidAudioTTS model loaded successfully")
        } catch {
            print("[LocalTTSService] Failed to load FluidAudioTTS model: \(error)")
            throw LocalTTSError.generationFailed(error.localizedDescription)
        }
    }

    /// Unload the model to free memory
    func unloadModel() {
        cancelCurrentRequest()
        ttsManager?.cleanup()
        ttsManager = nil
        isModelLoaded = false
        print("[LocalTTSService] Model unloaded")
    }

    // MARK: - GPU/CPU Mode Switching (for background playback)

    /// Current compute mode (for debugging/status)
    var computeMode: String {
        switch currentComputeUnits {
        case .cpuOnly:
            return "CPU-only"
        case .cpuAndGPU:
            return "CPU+GPU"
        case .cpuAndNeuralEngine:
            return "CPU+ANE"
        case .all:
            return "All"
        @unknown default:
            return "Unknown"
        }
    }

    /// Check if currently switching modes
    var isModeSwitching: Bool {
        isSwitchingMode
    }

    /// Switch to background mode (CPU-only) for iOS background execution
    /// iOS doesn't allow GPU work in background, so we reload the model with CPU-only
    func switchToBackgroundMode() async throws {
        // Already in CPU-only mode
        guard currentComputeUnits != .cpuOnly else {
            print("[LocalTTSService] Already in CPU-only mode")
            return
        }

        // Don't switch if model not loaded
        guard isModelLoaded else {
            print("[LocalTTSService] Model not loaded, skipping background mode switch")
            currentComputeUnits = .cpuOnly
            return
        }

        isSwitchingMode = true
        defer { isSwitchingMode = false }

        print("[LocalTTSService] 🔄 Switching to CPU-only mode for background...")

        // 1. Cancel any current synthesis request
        cancelCurrentRequest()

        // 2. Unload current GPU model
        unloadModel()

        // 3. Reload with CPU-only
        currentComputeUnits = .cpuOnly
        try await loadModelWithComputeUnits(.cpuOnly)

        print("[LocalTTSService] ✅ Switched to CPU-only mode")
    }

    /// Switch to foreground mode (CPU+GPU) for optimal performance
    func switchToForegroundMode() async throws {
        // Already in GPU mode
        guard currentComputeUnits != .cpuAndGPU else {
            print("[LocalTTSService] Already in GPU mode")
            return
        }

        // Don't switch if model not loaded
        guard isModelLoaded else {
            print("[LocalTTSService] Model not loaded, skipping foreground mode switch")
            currentComputeUnits = .cpuAndGPU
            return
        }

        isSwitchingMode = true
        defer { isSwitchingMode = false }

        print("[LocalTTSService] 🔄 Switching to GPU mode for foreground...")

        // 1. Unload current CPU-only model
        unloadModel()

        // 2. Reload with GPU
        currentComputeUnits = .cpuAndGPU
        try await loadModelWithComputeUnits(.cpuAndGPU)

        print("[LocalTTSService] ✅ Switched to GPU mode")
    }

    /// Load model with specific compute units (bypasses TtsModels.download() hardcoded units)
    private func loadModelWithComputeUnits(_ units: MLComputeUnits) async throws {
        // Ensure model files are downloaded first
        if !Self.checkModelExists() {
            try await downloadModelIfNeeded()
        }

        print("[LocalTTSService] Loading model with compute units: \(units == .cpuOnly ? "CPU-only" : "CPU+GPU")")

        do {
            // Get the cache directory (same as TtsModels uses)
            let cacheDirectory = Self.getCacheDirectory()
            let modelsDirectory = cacheDirectory.appendingPathComponent("Models")

            // Model filenames
            let modelNames = [
                ModelNames.TTS.Variant.fiveSecond.fileName,
                ModelNames.TTS.Variant.fifteenSecond.fileName
            ]

            // Load models with custom compute units using DownloadUtils
            let modelDict = try await DownloadUtils.loadModels(
                .kokoro,
                modelNames: modelNames,
                directory: modelsDirectory,
                computeUnits: units
            )

            // Wrap into TtsModels
            var loaded: [ModelNames.TTS.Variant: MLModel] = [:]
            for variant in ModelNames.TTS.Variant.allCases {
                if let model = modelDict[variant.fileName] {
                    loaded[variant] = model
                }
            }

            let ttsModels = TtsModels(models: loaded)

            // Initialize TtsManager with pre-loaded models
            let manager = TtSManager(defaultVoice: Constants.TTS.defaultVoice)
            try await manager.initialize(models: ttsModels)

            ttsManager = manager
            isModelLoaded = true

            print("[LocalTTSService] Model loaded with \(units == .cpuOnly ? "CPU-only" : "CPU+GPU") mode")
        } catch {
            print("[LocalTTSService] Failed to load model with custom compute units: \(error)")
            throw LocalTTSError.generationFailed(error.localizedDescription)
        }
    }

    /// Generate TTS for a single text (used by simple generateTTS API)
    func generateTTS(
        text: String,
        voice: String = Constants.TTS.defaultVoice,
        speed: Double = Constants.TTS.defaultSpeed,
        language: String = Constants.TTS.defaultLanguage
    ) async throws -> AudioSegment {
        let requestId = UUID()
        currentRequestId = requestId

        // Ensure model is loaded
        if !isModelLoaded || ttsManager == nil {
            try await loadModel()
        }

        guard currentRequestId == requestId else {
            throw LocalTTSError.cancelled
        }

        guard let manager = ttsManager else {
            throw LocalTTSError.modelNotLoaded
        }

        do {
            print("[LocalTTSService] Generating TTS for: \(text.prefix(50))...")

            let rawAudioData = try await manager.synthesize(
                text: text,
                voice: voice,
                voiceSpeed: Float(speed)
            )

            guard currentRequestId == requestId else {
                throw LocalTTSError.cancelled
            }

            // Ensure audio data has proper WAV header
            let audioData = ensureWavFormat(rawAudioData)

            // Calculate duration from audio data
            // If we added WAV header, use raw data size; otherwise subtract header
            let pcmDataSize = hasWavHeader(rawAudioData) ? rawAudioData.count - 44 : rawAudioData.count
            let duration = Double(pcmDataSize) / (sampleRate * 2)

            print("[LocalTTSService] Generated audio, duration: \(duration)s, size: \(audioData.count) bytes")

            let timestamps = createApproximateTimestamps(text: text, duration: duration)

            currentRequestId = nil

            return AudioSegment(
                paragraphIndex: 0,
                segmentIndex: 0,
                audioData: audioData,
                timestamps: timestamps,
                duration: duration,
                text: text,
                isWavFormat: true  // Local TTS generates WAV format
            )
        } catch let error as LocalTTSError {
            throw error
        } catch {
            print("[LocalTTSService] TTS generation failed: \(error)")
            throw LocalTTSError.generationFailed(error.localizedDescription)
        }
    }

    /// Generate TTS for a paragraph using sentence-based synthesis
    /// This allows cancellation between sentences (max 1-2 seconds wait)
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

        // Ensure model is loaded
        if !isModelLoaded || ttsManager == nil {
            try await loadModel()
        }

        // Check cancellation after model load
        guard currentRequestId == requestId else {
            print("[LocalTTSService] Request cancelled after model load")
            throw LocalTTSError.cancelled
        }

        guard let manager = ttsManager else {
            throw LocalTTSError.modelNotLoaded
        }

        // Split paragraph into sentences
        let sentences = splitIntoSentences(text)
        var segmentIndex = 0

        print("[LocalTTSService] Paragraph \(paragraphIndex): \(sentences.count) sentences")

        for sentence in sentences {
            // Check cancellation BEFORE each sentence
            guard currentRequestId == requestId else {
                print("[LocalTTSService] Request cancelled before sentence \(segmentIndex)")
                throw LocalTTSError.cancelled
            }

            do {
                // Synthesize single sentence (max 1-2 seconds)
                let rawAudioData = try await manager.synthesize(
                    text: sentence,
                    voice: voice,
                    voiceSpeed: Float(speed)
                )

                // Check cancellation AFTER each sentence
                guard currentRequestId == requestId else {
                    print("[LocalTTSService] Request cancelled after sentence \(segmentIndex)")
                    throw LocalTTSError.cancelled
                }

                // Ensure audio data has proper WAV header
                let audioData = ensureWavFormat(rawAudioData)

                // Calculate duration from audio data
                let pcmDataSize = hasWavHeader(rawAudioData) ? rawAudioData.count - 44 : rawAudioData.count
                let duration = Double(pcmDataSize) / (sampleRate * 2)
                let timestamps = createApproximateTimestamps(text: sentence, duration: duration)

                let segment = AudioSegment(
                    paragraphIndex: paragraphIndex,
                    segmentIndex: segmentIndex,
                    audioData: audioData,
                    timestamps: timestamps,
                    duration: duration,
                    text: sentence,
                    isWavFormat: true  // Local TTS generates WAV format
                )

                // Callback with segment
                await onSegmentReady(segment)

                segmentIndex += 1
            } catch is CancellationError {
                // Task was cancelled (preloadTask.cancel()) - treat as normal cancellation
                print("[LocalTTSService] Sentence \(segmentIndex) cancelled by Task.cancel()")
                throw LocalTTSError.cancelled
            } catch let error as LocalTTSError {
                throw error
            } catch {
                print("[LocalTTSService] Sentence synthesis failed: \(error)")
                throw LocalTTSError.generationFailed(error.localizedDescription)
            }
        }

        // Clear request ID on successful completion
        if currentRequestId == requestId {
            currentRequestId = nil
        }
    }

    // MARK: - Private Methods

    /// Split text into sentences for incremental synthesis
    private func splitIntoSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var currentSentence = ""

        // Sentence ending punctuation (Chinese + English)
        let sentenceEnders: Set<Character> = [".", "!", "?", "。", "！", "？"]

        for char in text {
            currentSentence.append(char)

            if sentenceEnders.contains(char) {
                let trimmed = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    sentences.append(trimmed)
                }
                currentSentence = ""
            }
        }

        // Handle remaining text (no sentence ender)
        let remaining = currentSentence.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remaining.isEmpty {
            sentences.append(remaining)
        }

        // Return original text if no sentences found
        return sentences.isEmpty ? [text] : sentences
    }

    /// Create approximate word-level timestamps based on text length distribution
    private func createApproximateTimestamps(text: String, duration: Double) -> [TTSTimestamp] {
        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        var timestamps: [TTSTimestamp] = []
        var currentTime: Double = 0

        let totalChars = words.reduce(0) { $0 + $1.count }
        guard totalChars > 0 else { return [] }

        for word in words {
            let wordDuration = duration * Double(word.count) / Double(totalChars)
            let endTime = min(currentTime + wordDuration, duration)

            timestamps.append(TTSTimestamp(
                word: word,
                startTime: currentTime,
                endTime: endTime
            ))

            currentTime = endTime
        }

        return timestamps
    }
}
