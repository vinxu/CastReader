//
//  YouTubeCaptionLanguageSwitcher.swift
//  CastReader
//
//  Resolves the transcript for a caption language the user explicitly picked.
//  Presentation and playback ownership stay with MainTabView; this type only
//  owns picker state and the cache/extract decision behind it.
//

import Foundation

@MainActor
final class YouTubeCaptionLanguageSwitcher: ObservableObject {
    enum Phase: Equatable {
        case idle
        /// In flight, but not yet worth covering the reader for. A cached
        /// language resolves in milliseconds and must not flash a full-screen
        /// overlay on its way past.
        case resolving(targetLanguage: String)
        case switching(targetLanguage: String)

        var isSwitching: Bool {
            switch self {
            case .idle: return false
            case .resolving, .switching: return true
            }
        }

        /// Non-nil only once the switch has been slow enough to deserve an
        /// overlay.
        var overlayLanguage: String? {
            if case .switching(let language) = self { return language }
            return nil
        }

        var targetLanguage: String? {
            switch self {
            case .idle: return nil
            case .resolving(let language), .switching(let language): return language
            }
        }
    }

    struct Resolution: Equatable {
        let transcript: YouTubeTranscriptDocument
        let cacheKey: YouTubeTranscriptCacheKey
        let cacheHit: Bool
        /// Timeline position the previous track was at. The new track has its
        /// own paragraph boundaries, so time is the only meaningful anchor.
        let resumeAnchorMs: Int
    }

    /// Shared like `PlaybackVoicePanelCenter`: the picker is opened from deep
    /// inside the reader hierarchy but presented by `MainTabView`, and the
    /// reader must not be rebuilt just to thread a callback down to it.
    static let shared = YouTubeCaptionLanguageSwitcher()

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var presentedPickerVideoID: String?
    @Published var failureMessage: String?

    static let overlayGraceNanoseconds: UInt64 = 180_000_000

    private var task: Task<Void, Never>?
    private var overlayTask: Task<Void, Never>?

    private init() {}

    var isPickerPresented: Bool { presentedPickerVideoID != nil }

    func presentPicker(for videoID: String) {
        guard !phase.isSwitching else { return }
        presentedPickerVideoID = videoID
    }

    func dismissPicker() {
        presentedPickerVideoID = nil
    }

    /// Resolve `option` for `reference`, preferring an already cached transcript
    /// so a language the user has listened to before switches without network.
    ///
    /// `apply` runs only on success and owns the reader session swap. A failure
    /// deliberately changes nothing: the caller's current track keeps playing.
    func startSwitch(
        to option: YouTubeCaptionTrackOption,
        reference: YouTubeVideoReference,
        resumeAnchorMs: Int,
        cache: YouTubeCacheStore?,
        apply: @escaping (Resolution) async -> Void
    ) {
        guard option.isPlayable else {
            failureMessage = YouTubeTranscriptFailure.unsupportedLanguage.errorDescription
            return
        }
        dismissPicker()
        task?.cancel()
        // The extraction WebView is a single shared resource. Releasing it here
        // keeps a rapid second pick from racing the first one's page load.
        YouTubeTranscriptService.shared.cancel()

        let target = option.languageCode
        guard let accountBoundary = AccountContentIsolation.captureBoundaryToken() else {
            failureMessage = YouTubeTranscriptFailure.network.errorDescription
            return
        }
        phase = .resolving(targetLanguage: target)
        failureMessage = nil
        armOverlay(for: target)

        task = Task { @MainActor [weak self] in
            do {
                let resolution = try await Self.resolve(
                    option: option,
                    reference: reference,
                    resumeAnchorMs: resumeAnchorMs,
                    cache: cache
                )
                try Task.checkCancellation()
                guard AccountContentIsolation.isCurrent(accountBoundary) else {
                    throw CancellationError()
                }
                // Retire the overlay timer before the session swap: `apply`
                // awaits cache reads, and a grace window that fires mid-swap
                // would raise the overlay just as playback is starting.
                self?.finishOverlay()
                await apply(resolution)
                guard let self, !Task.isCancelled else { return }
                self.phase = .idle
            } catch is CancellationError {
                self?.finishOverlay()
                self?.phase = .idle
            } catch {
                guard let self else { return }
                self.finishOverlay()
                self.phase = .idle
                let failure = (error as? YouTubeTranscriptFailure) ?? .network
                // `.cancelled` reaches here when the shared service was taken
                // over by another request; that is not a user-facing error.
                self.failureMessage = failure == .cancelled
                    ? nil
                    : failure.errorDescription
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        overlayTask?.cancel()
        overlayTask = nil
        YouTubeTranscriptService.shared.cancel()
        phase = .idle
    }

    func resetForAccountBoundary() {
        cancel()
        presentedPickerVideoID = nil
        failureMessage = nil
    }

    private func finishOverlay() {
        overlayTask?.cancel()
        overlayTask = nil
    }

    /// Promote `.resolving` to `.switching` only if the switch is still running
    /// after the grace window, so an instant cache hit never covers the reader.
    private func armOverlay(for target: String) {
        overlayTask?.cancel()
        overlayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.overlayGraceNanoseconds)
            guard !Task.isCancelled,
                  let self,
                  self.phase == .resolving(targetLanguage: target) else { return }
            self.phase = .switching(targetLanguage: target)
        }
    }

    private static func resolve(
        option: YouTubeCaptionTrackOption,
        reference: YouTubeVideoReference,
        resumeAnchorMs: Int,
        cache: YouTubeCacheStore?
    ) async throws -> Resolution {
        let cachedCandidate = await cache?.mostRecentTranscript(
            videoId: reference.videoId,
            matching: option
        )
        let usableCached: YouTubeCachedTranscriptResolution? = cachedCandidate.flatMap {
            cached -> YouTubeCachedTranscriptResolution? in
            guard option.matches(cached.document.track),
                  (try? YouTubeTranscriptContentLanguagePolicy.validatedPlaybackLanguage(
                      for: cached.document
                  )) != nil,
                  YouTubeReadingDocumentBuilder.firstPlayableParagraph(
                      in: cached.document
                  ) != nil else { return nil }
            return cached
        }
        if let usableCached,
           usableCached.document.captionSemanticSchemaVersion ==
               YouTubeCaptionSemanticSchema.current ||
               !NetworkReachability.shared.isOnline {
            return Resolution(
                transcript: usableCached.document,
                cacheKey: usableCached.key,
                cacheHit: true,
                resumeAnchorMs: resumeAnchorMs
            )
        }

        let transcript: YouTubeTranscriptDocument
        do {
            transcript = try await YouTubeTranscriptService.shared.extract(
                reference,
                preferredLanguage: option.languageCode,
                requestedTrack: YouTubeTrackRequest(option: option),
                timeout: YouTubeTranscriptService.defaultExtractionTimeout
            )
        } catch let failure as YouTubeTranscriptFailure
            where failure == .network || failure == .timeout
                || failure == .captionAccess
                || failure == .playerBootstrapFailed
                || failure == .youtubeAccessLimited
                || (failure == .trackUnavailable && usableCached != nil) {
            if let usableCached {
                return Resolution(
                    transcript: usableCached.document,
                    cacheKey: usableCached.key,
                    cacheHit: true,
                    resumeAnchorMs: resumeAnchorMs
                )
            }
            throw failure
        }
        _ = try YouTubeTranscriptContentLanguagePolicy.validatedPlaybackLanguage(
            for: transcript
        )
        guard option.matches(transcript.track) else {
            throw YouTubeTranscriptFailure.trackUnavailable
        }
        guard YouTubeReadingDocumentBuilder.firstPlayableParagraph(
            in: transcript
        ) != nil else {
            throw YouTubeTranscriptFailure.trackUnavailable
        }
        let key = YouTubeCacheStore.cacheKey(for: transcript)
        if let cache {
            try? await cache.storeTranscript(transcript, for: key)
        }
        return Resolution(
            transcript: transcript,
            cacheKey: key,
            cacheHit: false,
            resumeAnchorMs: resumeAnchorMs
        )
    }
}

// MARK: - Picker presentation

extension YouTubeCaptionTrackOption {
    /// Track label for the picker, in the app's current interface language.
    /// YouTube's own `name` is localized to the *page* language, so it is only
    /// a fallback for codes `Locale` cannot name.
    func displayName(locale: Locale) -> String {
        if let localized = locale.localizedString(forIdentifier: languageCode)
            ?? locale.localizedString(
                forLanguageCode: YouTubeTrackSelector.baseLanguage(languageCode)
            ), !localized.isEmpty {
            return localized
        }
        if let name, !name.isEmpty { return name }
        return languageCode.uppercased()
    }
}
