//
//  ModelDownloadService.swift
//  CastReader
//
//  Manages TTS model status.
//  Note: FluidAudioTTS automatically downloads and caches models on first use.
//  This service is kept for UI state management and backward compatibility.
//

import Foundation

// MARK: - Model Status

enum ModelStatus: Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case error(String)

    var isDownloaded: Bool {
        self == .downloaded
    }

    var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

// MARK: - Model Download Error

enum ModelDownloadError: Error, LocalizedError {
    case downloadFailed(String)
    case fileSystemError(String)
    case invalidData
    case cancelled

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message):
            return "Download failed: \(message)"
        case .fileSystemError(let message):
            return "File system error: \(message)"
        case .invalidData:
            return "Invalid model data"
        case .cancelled:
            return "Download cancelled"
        }
    }
}

// MARK: - Model Download Service

@MainActor
class ModelDownloadService: NSObject, ObservableObject {
    static let shared = ModelDownloadService()

    @Published private(set) var status: ModelStatus = .notDownloaded
    @Published private(set) var downloadProgress: Double = 0

    private override init() {
        super.init()
        checkModelStatus()
    }

    // MARK: - Public API

    /// Check if the local model is ready to use
    /// FluidAudioTTS automatically manages model downloads, so we check initialization status
    var isModelReady: Bool {
        status == .downloaded
    }

    // MARK: - Status Management

    /// Check current model status
    func checkModelStatus() {
        // FluidAudioTTS auto-downloads models to ~/.cache/fluidaudio/Models/kokoro
        // Check if we've previously successfully initialized
        let hasInitialized = UserDefaults.standard.bool(forKey: Constants.TTS.LocalModel.isDownloadedKey)
        if hasInitialized {
            status = .downloaded
        } else {
            status = .notDownloaded
        }
    }

    /// Mark model as ready after successful initialization
    func markModelAsReady() {
        status = .downloaded
        downloadProgress = 1.0
        UserDefaults.standard.set(true, forKey: Constants.TTS.LocalModel.isDownloadedKey)
    }

    /// Mark model as downloading (for UI feedback during first TTS request)
    func markAsDownloading() {
        status = .downloading(progress: 0.5)
        downloadProgress = 0.5
    }

    /// Start model initialization
    /// Downloads model from COS with progress tracking
    func startDownload() async throws {
        guard !status.isDownloading else { return }

        status = .downloading(progress: 0)
        downloadProgress = 0

        do {
            // Download with progress callback
            try await LocalTTSService.shared.downloadModelIfNeeded { [weak self] progress in
                Task { @MainActor in
                    self?.downloadProgress = progress
                    self?.status = .downloading(progress: progress)
                }
            }

            // Model will be loaded on-demand when user starts reading
            // (in LocalTTSService.generateTTSForParagraph)

            status = .downloaded
            downloadProgress = 1.0
            UserDefaults.standard.set(true, forKey: Constants.TTS.LocalModel.isDownloadedKey)
        } catch {
            status = .error(error.localizedDescription)
            throw error
        }
    }

    /// Reset model status (for re-initialization)
    func resetModel() {
        status = .notDownloaded
        downloadProgress = 0
        UserDefaults.standard.set(false, forKey: Constants.TTS.LocalModel.isDownloadedKey)
    }

    /// Get estimated model size in bytes
    var estimatedModelSize: Int64 {
        Constants.TTS.LocalModel.estimatedSize
    }

    /// Get formatted model size string
    var formattedModelSize: String {
        ByteCountFormatter.string(fromByteCount: estimatedModelSize, countStyle: .file)
    }
}
