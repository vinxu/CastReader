//
//  Constants.swift
//  CastReader
//

import SwiftUI

enum Constants {
    enum API {
        static let baseURL = "https://api.castreader.ai"
        static let readerServiceURL = "http://api.castreader.ai:8123"

        // Explore
        static let genres = "\(baseURL)/genre"
        static let books = "\(baseURL)/html-ebook-page"
        static let searchBooks = "\(baseURL)/search-html-books"

        // Library
        static let documents = "\(readerServiceURL)/documents"

        // Upload
        static let sts = "\(baseURL)/sts"
        static let asyncUpload = "\(readerServiceURL)/async-md-upload-by-url"
        static let syncUpload = "\(readerServiceURL)/upload"  // EPUB sync upload

        // TTS
        static let tts = "\(baseURL)/api/captioned_speech_partly"
    }

    enum Storage {
        static let visitorIdKey = "visitor_id"
        static let playbackProgressKey = "playback_progress"
        static let lastPlayedBookKey = "last_played_book"
        static let ttsProviderKey = "tts_provider"  // "local" or "cloud"
    }

    enum TTS {
        static let defaultVoice = "af_heart"
        static let defaultSpeed: Double = 1.0
        static let defaultLanguage = "en"
        static let model = "kokoro"

        // Local TTS Model Configuration (FluidAudioTTS - CoreML based)
        // Note: FluidAudioTTS automatically downloads models to ~/.cache/fluidaudio/Models/kokoro
        enum LocalModel {
            static let modelName = "kokoro-82m-coreml"
            // FluidAudioTTS auto-downloads from Hugging Face, no manual URL needed
            static let estimatedSize: Int64 = 170_000_000 // ~170MB CoreML model
            static let isDownloadedKey = "local_tts_model_initialized"
        }
    }

    enum UI {
        static let miniPlayerHeight: CGFloat = 64
        static let tabBarHeight: CGFloat = 49
        // 书封面比例约 2:3
        static let bookCardWidth: CGFloat = 110
        static let bookCardHeight: CGFloat = 165
    }
}
