//
//  YouTubeCacheStore.swift
//  CastReader
//
//  App-owned cache for YouTube caption text, CastReader-generated TTS audio,
//  progress, thumbnails and storyboard still images. This cache deliberately
//  has no API for storing YouTube video or audio streams.
//

import CryptoKit
import Foundation
import ImageIO

// These immutable value types predate the cache actor. Their stored fields are
// Sendable, but Swift requires retroactive conformances to be unchecked.
extension TTSTimestamp: @unchecked Sendable {}
extension AudioSegment: @unchecked Sendable {}

protocol YouTubeCacheClock: Sendable {
    func now() -> Date
}

struct SystemYouTubeCacheClock: YouTubeCacheClock {
    func now() -> Date { Date() }
}

struct YouTubeCacheLimits: Equatable, Sendable {
    static let production = YouTubeCacheLimits(
        maxVideoCount: 50,
        maxBytes: 500 * 1024 * 1024
    )

    let maxVideoCount: Int
    let maxBytes: Int64
}

struct YouTubeTranscriptCacheKey: Codable, Equatable, Hashable, Sendable {
    let videoIdHash: String
    let trackLanguage: String
    let trackIdentityHash: String
    let transcriptFingerprint: String

    init(
        videoId: String,
        trackLanguage: String,
        trackIdentity: String,
        transcriptFingerprint: String
    ) {
        videoIdHash = YouTubeCacheDigest.sha256(videoId)
        self.trackLanguage = YouTubeCacheStore.normalizedLanguage(trackLanguage)
        trackIdentityHash = YouTubeCacheDigest.sha256(trackIdentity)
        self.transcriptFingerprint = transcriptFingerprint.lowercased()
    }

    /// The only value used as a directory name. Raw video IDs, URLs, language
    /// names, voice names and transcript text never enter filesystem paths.
    var storageKey: String {
        YouTubeCacheDigest.sha256([
            videoIdHash,
            trackLanguage,
            trackIdentityHash,
            transcriptFingerprint,
        ])
    }
}

/// A transcript selected from the cache in one actor turn. Returning the
/// decoded document together with its key avoids the former select-then-read
/// pattern, which decoded and fingerprint-validated the same JSON twice on the
/// latency-sensitive YouTube open path.
struct YouTubeCachedTranscriptResolution: Equatable, Sendable {
    let key: YouTubeTranscriptCacheKey
    let document: YouTubeTranscriptDocument
}

struct YouTubeTTSAudioCacheKey: Codable, Equatable, Hashable, Sendable {
    let transcriptFingerprint: String
    let voiceCodeHash: String
    let playbackLanguage: String
    let schemaVersion: Int
    let paragraphIndex: Int?

    init(
        transcriptFingerprint: String,
        voiceCode: String,
        playbackLanguage: String,
        schemaVersion: Int,
        paragraphIndex: Int? = nil
    ) {
        self.transcriptFingerprint = transcriptFingerprint.lowercased()
        voiceCodeHash = YouTubeCacheDigest.sha256(voiceCode)
        self.playbackLanguage = Self.canonicalPlaybackLanguage(playbackLanguage)
        self.schemaVersion = schemaVersion
        self.paragraphIndex = paragraphIndex
    }

    private static func canonicalPlaybackLanguage(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .first
            .map(String.init) ?? ""
    }

    var storageKey: String {
        YouTubeCacheDigest.sha256([
            transcriptFingerprint,
            voiceCodeHash,
            playbackLanguage,
            String(schemaVersion),
            paragraphIndex.map(String.init) ?? "all",
        ])
    }
}

enum YouTubeTTSAudioCacheSchema {
    /// Increment whenever AudioSegment persistence semantics change.
    /// Version 4 binds audio to the canonical playback language. Some cloned
    /// voices are shared across languages, so voice identity alone cannot keep
    /// an old synthesis from crossing a language correction boundary.
    static let current = 4
}

struct YouTubePlaybackProgress: Codable, Equatable, Sendable {
    let paragraphIndex: Int
    let segmentId: String
    let segmentIndex: Int
    /// Position inside `segmentId`; this remains segment-local so a cached
    /// paragraph can seek back into the exact stable audio segment.
    let fractionalProgress: Double
    /// Duration-weighted position across every audio segment in the paragraph.
    /// Older manifests do not contain this field, so readers fall back to the
    /// legacy segment-local value until playback writes a fresh checkpoint.
    let paragraphFractionalProgress: Double?
    let updatedAt: Date

    init(
        paragraphIndex: Int,
        segmentId: String,
        segmentIndex: Int,
        fractionalProgress: Double,
        paragraphFractionalProgress: Double? = nil,
        updatedAt: Date
    ) {
        self.paragraphIndex = paragraphIndex
        self.segmentId = segmentId
        self.segmentIndex = segmentIndex
        self.fractionalProgress = fractionalProgress
        self.paragraphFractionalProgress = paragraphFractionalProgress
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case paragraphIndex
        case segmentId
        case segmentIndex
        case fractionalProgress
        case paragraphFractionalProgress
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        paragraphIndex = try container.decode(Int.self, forKey: .paragraphIndex)
        segmentId = try container.decode(String.self, forKey: .segmentId)
        segmentIndex = try container.decode(Int.self, forKey: .segmentIndex)
        fractionalProgress = try container.decode(
            Double.self,
            forKey: .fractionalProgress
        )
        paragraphFractionalProgress = try container.decodeIfPresent(
            Double.self,
            forKey: .paragraphFractionalProgress
        )
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(paragraphIndex, forKey: .paragraphIndex)
        try container.encode(segmentId, forKey: .segmentId)
        try container.encode(segmentIndex, forKey: .segmentIndex)
        try container.encode(fractionalProgress, forKey: .fractionalProgress)
        try container.encodeIfPresent(
            paragraphFractionalProgress,
            forKey: .paragraphFractionalProgress
        )
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    var resolvedParagraphFractionalProgress: Double {
        paragraphFractionalProgress ?? fractionalProgress
    }
}

struct YouTubeParagraphPlaybackPosition: Equatable, Sendable {
    let segmentFraction: Double
    let paragraphFraction: Double
}

/// Keeps cached resume semantics (segment id + segment-local fraction) separate
/// from the duration-weighted paragraph completion shown in History.
enum YouTubeParagraphProgressContract {
    static func position(
        in segments: [AudioSegment],
        currentSegmentID: String,
        currentTime: Double,
        currentSegmentDuration: Double
    ) -> YouTubeParagraphPlaybackPosition? {
        guard currentTime.isFinite,
              let currentIndex = segments.firstIndex(where: {
                  $0.id == currentSegmentID
              }) else { return nil }

        let durations = segments.enumerated().map { index, segment -> Double in
            let candidate = index == currentIndex && currentSegmentDuration.isFinite
                ? currentSegmentDuration
                : segment.duration
            return candidate.isFinite ? max(0, candidate) : 0
        }
        let activeDuration = durations[currentIndex]
        let paragraphDuration = durations.reduce(0, +)
        guard activeDuration > 0.01, paragraphDuration > 0.01 else { return nil }

        let elapsedInSegment = min(activeDuration, max(0, currentTime))
        let segmentFraction = min(0.98, elapsedInSegment / activeDuration)
        let elapsedBeforeSegment = durations.prefix(currentIndex).reduce(0, +)
        let paragraphFraction = min(
            0.98,
            max(0, (elapsedBeforeSegment + elapsedInSegment) / paragraphDuration)
        )
        return YouTubeParagraphPlaybackPosition(
            segmentFraction: segmentFraction,
            paragraphFraction: paragraphFraction
        )
    }
}

struct YouTubeCacheEntrySummary: Equatable, Sendable {
    let key: YouTubeTranscriptCacheKey
    let lastAccessAt: Date
    let byteSize: Int64
    let hasTranscript: Bool
    let hasThumbnail: Bool
    let storyboardSheetCount: Int
    let audioVariantCount: Int
    let hasProgress: Bool
}

enum YouTubeAudioCacheCoverage: Equatable, Sendable {
    case none(totalParagraphs: Int)
    case partial(cachedParagraphs: Int, totalParagraphs: Int)
    case complete(totalParagraphs: Int)

    var hasAny: Bool {
        switch self {
        case .none: false
        case .partial, .complete: true
        }
    }

    var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }
}

/// What one caption language already has on disk, as shown in the picker.
/// `hasTranscript` alone means the switch itself needs no network; complete
/// audio additionally means it can be listened to offline.
struct YouTubeCaptionLanguageAvailability: Equatable, Sendable {
    let hasTranscript: Bool
    let audio: YouTubeAudioCacheCoverage

    static let unavailable = YouTubeCaptionLanguageAvailability(
        hasTranscript: false,
        audio: .none(totalParagraphs: 0)
    )

    var isFullyDownloaded: Bool { hasTranscript && audio.isComplete }
}

/// A truthful "available offline" projection for the native YouTube reader.
/// Complete means the transcript, every readable paragraph's selected-voice
/// TTS, and every still-image resource needed by that transcript are all on
/// disk. A storyboard requires every sheet. When a high-resolution thumbnail
/// is declared it is also required because low-resolution storyboards are
/// presented as a time-synced inset over that full-width cover. If YouTube
/// supplied neither, CastReader's native placeholder is already fully offline.
struct YouTubeOfflineCacheCoverage: Equatable, Sendable {
    let audio: YouTubeAudioCacheCoverage
    let hasTranscript: Bool
    let cachedArtworkResourceCount: Int
    let requiredArtworkResourceCount: Int

    static func none(totalParagraphs: Int) -> Self {
        YouTubeOfflineCacheCoverage(
            audio: .none(totalParagraphs: totalParagraphs),
            hasTranscript: false,
            cachedArtworkResourceCount: 0,
            requiredArtworkResourceCount: 0
        )
    }

    var hasAny: Bool {
        hasTranscript || audio.hasAny || cachedArtworkResourceCount > 0
    }

    var isComplete: Bool {
        hasTranscript
            && audio.isComplete
            && cachedArtworkResourceCount == requiredArtworkResourceCount
    }
}

extension Notification.Name {
    static let castReaderYouTubeAudioCacheChanged = Notification.Name(
        "castreader.youtube.audioCache.changed"
    )
    static let castReaderYouTubeThumbnailCacheChanged = Notification.Name(
        "castreader.youtube.thumbnailCache.changed"
    )
    static let castReaderYouTubeArtworkCacheChanged = Notification.Name(
        "castreader.youtube.artworkCache.changed"
    )
    static let castReaderYouTubePlaybackConfirmed = Notification.Name(
        "castreader.youtube.playback.confirmed"
    )
}

struct YouTubeCacheStats: Equatable, Sendable {
    let videoCount: Int
    let entryCount: Int
    let totalBytes: Int64
}

struct YouTubeCachedAudioPlayback: Sendable {
    let segments: [AudioSegment]
    /// Only audio that has reached the end of this paragraph once is a replay.
    /// Merely generating/persisting bytes must not bypass first-listen quota.
    let isReplayEligible: Bool
}

enum YouTubeCacheError: Error, Equatable {
    case invalidRootDirectory
    case invalidLimits
    case invalidKey
    case keyMismatch
    case invalidProgress
    case emptyResource
    case invalidImageResource
    case resourceTooLarge
    case unsafePath
}

private enum YouTubeCacheDigest {
    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            data.append(Data(String(bytes.count).utf8))
            data.append(0x3A) // ':'
            data.append(bytes)
            data.append(0x0A) // newline
        }
        return sha256(data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

private struct YouTubeCacheManifest: Codable {
    static let currentVersion = 1

    var version: Int = currentVersion
    var entries: [String: YouTubeCacheManifestEntry] = [:]
}

private struct YouTubeCacheManifestEntry: Codable {
    let key: YouTubeTranscriptCacheKey
    let createdAt: Date
    var lastAccessAt: Date
    var byteSize: Int64
    var hasTranscript: Bool
    var hasThumbnail: Bool
    var storyboardSheetIndexes: Set<Int>
    var audioVariantKeys: Set<String>
    var progress: YouTubePlaybackProgress?
    /// Base UI languages for which the live selector deliberately chose this
    /// transcript, including cross-language fallback selections.
    var selectionLanguageBases: Set<String>?
}

private struct YouTubeCachedAudioManifest: Codable {
    let key: YouTubeTTSAudioCacheKey
    let segments: [YouTubeCachedAudioSegment]
    let isReplayEligible: Bool

    init(
        key: YouTubeTTSAudioCacheKey,
        segments: [YouTubeCachedAudioSegment],
        isReplayEligible: Bool = false
    ) {
        self.key = key
        self.segments = segments
        self.isReplayEligible = isReplayEligible
    }

    private enum CodingKeys: String, CodingKey {
        case key, segments, isReplayEligible
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(YouTubeTTSAudioCacheKey.self, forKey: .key)
        segments = try container.decode(
            [YouTubeCachedAudioSegment].self,
            forKey: .segments
        )
        // Audio written by builds before replay provenance existed is treated
        // conservatively as first-listen/billable until it completes once.
        isReplayEligible = try container.decodeIfPresent(
            Bool.self,
            forKey: .isReplayEligible
        ) ?? false
    }
}

private struct YouTubeCachedAudioSegment: Codable {
    let id: String
    let paragraphIndex: Int
    let segmentIndex: Int
    let audioFilename: String
    let timestamps: [TTSTimestamp]
    let duration: Double
    let text: String
    let isWavFormat: Bool
    let unprocessedText: String
    let speaker: String?
}

actor YouTubeCacheStore {
    private static let manifestFilename = "manifest.json"
    private static let entriesDirectoryName = "entries"
    private static let transcriptFilename = "transcript.json"
    private static let thumbnailFilename = "thumbnail.bin"
    private static let storyboardDirectoryName = "storyboard"
    private static let audioDirectoryName = "audio"
    private static let audioManifestFilename = "segments.json"

    private let rootDirectory: URL
    private let entriesDirectory: URL
    private let manifestURL: URL
    private let limits: YouTubeCacheLimits
    private let clock: any YouTubeCacheClock
    private let fileManager: FileManager
    private var manifest: YouTubeCacheManifest
    private var didPerformStartupMaintenance = false

    init(
        rootDirectory requestedRoot: URL,
        limits: YouTubeCacheLimits = .production,
        clock: any YouTubeCacheClock = SystemYouTubeCacheClock(),
        fileManager: FileManager = .default
    ) throws {
        guard limits.maxVideoCount > 0, limits.maxBytes > 0 else {
            throw YouTubeCacheError.invalidLimits
        }

        let standardized = requestedRoot.standardizedFileURL
        guard standardized.isFileURL,
              standardized.path != "/",
              standardized.pathComponents.count >= 3 else {
            throw YouTubeCacheError.invalidRootDirectory
        }
        try fileManager.createDirectory(
            at: standardized,
            withIntermediateDirectories: true
        )
        let resolvedRoot = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard resolvedRoot.path != "/" else {
            throw YouTubeCacheError.invalidRootDirectory
        }

        // The cache can grow to hundreds of megabytes and is entirely
        // reproducible from the public transcript/TTS pipeline. Keep it out of
        // device backups; this also applies to every descendant created later.
        var backupExcludedRoot = resolvedRoot
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try backupExcludedRoot.setResourceValues(resourceValues)

        rootDirectory = resolvedRoot
        entriesDirectory = resolvedRoot.appendingPathComponent(
            Self.entriesDirectoryName,
            isDirectory: true
        )
        manifestURL = resolvedRoot.appendingPathComponent(Self.manifestFilename)
        self.limits = limits
        self.clock = clock
        self.fileManager = fileManager

        try fileManager.createDirectory(
            at: entriesDirectory,
            withIntermediateDirectories: true
        )
        manifest = Self.loadManifest(from: manifestURL) ?? YouTubeCacheManifest()
        if manifest.version != YouTubeCacheManifest.currentVersion {
            manifest = YouTubeCacheManifest()
        }
        manifest.entries = manifest.entries.filter { storageKey, entry in
            YouTubeCacheDigest.isDigest(storageKey)
                && storageKey == entry.key.storageKey
                && Self.valid(key: entry.key)
        }
    }

    // MARK: Stable keys

    nonisolated static func normalizedLanguage(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }

    nonisolated private static func baseLanguage(_ value: String) -> String {
        normalizedLanguage(value).split(separator: "-").first.map(String.init) ?? ""
    }

    nonisolated static func selectedTrackIdentity(_ track: YouTubeCaptionTrack) -> String {
        [
            normalizedLanguage(track.languageCode),
            track.kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "manual",
            track.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            // Decoder stores the stable caption id/vssId here, never the
            // short-lived signed timedtext URL. Same-name tracks remain
            // distinct even when their current cues happen to be identical.
            track.baseURL.trimmingCharacters(in: .whitespacesAndNewlines),
        ].joined(separator: "\u{1F}")
    }

    nonisolated static func transcriptFingerprint(
        for cues: [YouTubeTranscriptCue]
    ) -> String {
        var data = Data()
        for cue in cues {
            let text = Data(cue.text.utf8)
            data.append(Data(String(cue.startMs).utf8))
            data.append(0x1F)
            data.append(Data(String(cue.durationMs).utf8))
            data.append(0x1F)
            data.append(Data(String(text.count).utf8))
            data.append(0x3A)
            data.append(text)
            data.append(0x0A)
        }
        return YouTubeCacheDigest.sha256(data)
    }

    nonisolated static func cacheKey(
        for document: YouTubeTranscriptDocument
    ) -> YouTubeTranscriptCacheKey {
        YouTubeTranscriptCacheKey(
            videoId: document.metadata.videoId,
            trackLanguage: document.track.languageCode,
            trackIdentity: selectedTrackIdentity(document.track),
            transcriptFingerprint: transcriptFingerprint(for: document.cues)
        )
    }

    // MARK: Transcript

    func storeTranscript(
        _ document: YouTubeTranscriptDocument,
        for key: YouTubeTranscriptCacheKey
    ) throws {
        try validate(document: document, for: key)
        let data = try Self.encode(document)
        try validateResourceSize(data.count)

        let storageKey = try validatedStorageKey(key.storageKey)
        let directory = try entryDirectory(storageKey, create: true)
        let url = try safeURL(
            directory.appendingPathComponent(Self.transcriptFilename)
        )
        let replacedByteSize = regularFileByteSize(url)
        try data.write(to: url, options: .atomic)

        var entry = try ensuredEntry(for: key)
        entry.hasTranscript = true
        if let selectedForLanguage = document.selectedForLanguage {
            let base = Self.baseLanguage(selectedForLanguage)
            if !base.isEmpty {
                var bases = entry.selectionLanguageBases ?? []
                bases.insert(base)
                entry.selectionLanguageBases = bases
            }
        }
        entry.lastAccessAt = clock.now()
        manifest.entries[storageKey] = entry
        try finalizeMutation(
            for: storageKey,
            replacing: replacedByteSize,
            with: Int64(data.count)
        )
    }

    func transcript(
        for key: YouTubeTranscriptCacheKey
    ) -> YouTubeTranscriptDocument? {
        guard let storageKey = try? validatedStorageKey(key.storageKey),
              var entry = manifest.entries[storageKey],
              entry.key == key,
              entry.hasTranscript,
              let directory = try? entryDirectory(storageKey, create: false),
              let url = try? safeURL(directory.appendingPathComponent(Self.transcriptFilename)),
              let data = try? Data(contentsOf: url),
              let document = try? Self.decode(YouTubeTranscriptDocument.self, from: data),
              (try? validate(document: document, for: key)) != nil else {
            markTranscriptCorrupt(for: key)
            return nil
        }
        entry.lastAccessAt = clock.now()
        manifest.entries[storageKey] = entry
        try? persistManifest()
        return document
    }

    /// Read-only presentation lookup. History badges must not become playback
    /// activity and reorder the video-level LRU merely because a list appeared.
    func peekTranscript(
        for key: YouTubeTranscriptCacheKey
    ) -> YouTubeTranscriptDocument? {
        guard let document = transcriptWithoutTouch(for: key) else {
            markTranscriptCorrupt(for: key)
            return nil
        }
        return document
    }

    /// Lets history reopen the newest cached transcript without knowing its
    /// fingerprint in advance. Returned keys remain opaque and filename-safe.
    func mostRecentKey(
        videoId: String,
        trackLanguage: String,
        trackIdentity: String
    ) -> YouTubeTranscriptCacheKey? {
        let videoHash = YouTubeCacheDigest.sha256(videoId)
        let language = Self.normalizedLanguage(trackLanguage)
        let identityHash = YouTubeCacheDigest.sha256(trackIdentity)
        let candidates = manifest.entries.values
            .filter {
                $0.key.videoIdHash == videoHash
                    && $0.key.trackLanguage == language
                    && $0.key.trackIdentityHash == identityHash
                    && $0.hasTranscript
            }
            .sorted { $0.lastAccessAt > $1.lastAccessAt }
        for candidate in candidates {
            if transcriptWithoutTouch(for: candidate.key) != nil {
                return candidate.key
            }
            markTranscriptCorrupt(for: candidate.key)
        }
        return nil
    }

    /// Entry-point lookup before extraction has revealed a track. The newest
    /// locally cached transcript for the requested video is the deterministic
    /// offline/replay candidate; its own key still pins language, track and
    /// transcript fingerprint for audio correctness.
    func mostRecentKey(videoId: String) -> YouTubeTranscriptCacheKey? {
        let videoHash = YouTubeCacheDigest.sha256(videoId)
        let candidates = manifest.entries.values
            .filter { $0.key.videoIdHash == videoHash && $0.hasTranscript }
            .sorted { $0.lastAccessAt > $1.lastAccessAt }
        for candidate in candidates {
            if transcriptWithoutTouch(for: candidate.key) != nil {
                return candidate.key
            }
            markTranscriptCorrupt(for: candidate.key)
        }
        return nil
    }

    /// Playback lookup that returns the already validated transcript instead
    /// of throwing it away and reading the same file again through
    /// `transcript(for:)`.
    func mostRecentTranscript(
        videoId: String
    ) -> YouTubeCachedTranscriptResolution? {
        let videoHash = YouTubeCacheDigest.sha256(videoId)
        let candidates = manifest.entries.values
            .filter { $0.key.videoIdHash == videoHash && $0.hasTranscript }
            .sorted { $0.lastAccessAt > $1.lastAccessAt }
        for candidate in candidates {
            guard let document = transcriptWithoutTouch(for: candidate.key) else {
                markTranscriptCorrupt(for: candidate.key)
                continue
            }
            touchTranscriptAccess(for: candidate.key)
            return YouTubeCachedTranscriptResolution(
                key: candidate.key,
                document: document
            )
        }
        return nil
    }

    /// Preferred-language cache hit used before live extraction. A track in
    /// the preferred base language wins (manual before ASR). A cross-language
    /// track is reusable only after the live selector has explicitly chosen it
    /// for this same UI language, so changing the app language still gets one
    /// chance to discover a better caption track.
    func mostRecentPreferredKey(
        videoId: String,
        preferredLanguage: String
    ) -> YouTubeTranscriptCacheKey? {
        let videoHash = YouTubeCacheDigest.sha256(videoId)
        let preferredBase = Self.baseLanguage(preferredLanguage)
        guard !preferredBase.isEmpty else { return nil }
        let candidates = manifest.entries.values
            .filter {
                $0.key.videoIdHash == videoHash
                    && $0.hasTranscript
            }
            .sorted { $0.lastAccessAt > $1.lastAccessAt }
        var newestValidAutomaticKey: YouTubeTranscriptCacheKey?
        var newestSelectedFallbackKey: YouTubeTranscriptCacheKey?
        for candidate in candidates {
            guard let document = transcriptWithoutTouch(for: candidate.key) else {
                markTranscriptCorrupt(for: candidate.key)
                continue
            }
            if Self.baseLanguage(candidate.key.trackLanguage) == preferredBase {
                if !document.track.isAutomatic { return candidate.key }
                if newestValidAutomaticKey == nil {
                    newestValidAutomaticKey = candidate.key
                }
            } else if newestSelectedFallbackKey == nil,
                      candidate.selectionLanguageBases?.contains(preferredBase) == true {
                newestSelectedFallbackKey = candidate.key
            }
        }
        return newestValidAutomaticKey ?? newestSelectedFallbackKey
    }

    /// Preferred-language playback lookup with a single decode per candidate.
    /// The selected document is returned directly and touched exactly once.
    func mostRecentPreferredTranscript(
        videoId: String,
        preferredLanguage: String
    ) -> YouTubeCachedTranscriptResolution? {
        let videoHash = YouTubeCacheDigest.sha256(videoId)
        let preferredBase = Self.baseLanguage(preferredLanguage)
        guard !preferredBase.isEmpty else { return nil }
        let candidates = manifest.entries.values
            .filter {
                $0.key.videoIdHash == videoHash
                    && $0.hasTranscript
            }
            .sorted { $0.lastAccessAt > $1.lastAccessAt }
        var newestValidAutomatic: YouTubeCachedTranscriptResolution?
        var newestSelectedFallback: YouTubeCachedTranscriptResolution?
        for candidate in candidates {
            guard let document = transcriptWithoutTouch(for: candidate.key) else {
                markTranscriptCorrupt(for: candidate.key)
                continue
            }
            let resolution = YouTubeCachedTranscriptResolution(
                key: candidate.key,
                document: document
            )
            if Self.baseLanguage(candidate.key.trackLanguage) == preferredBase {
                if !document.track.isAutomatic {
                    touchTranscriptAccess(for: candidate.key)
                    return resolution
                }
                if newestValidAutomatic == nil {
                    newestValidAutomatic = resolution
                }
            } else if newestSelectedFallback == nil,
                      candidate.selectionLanguageBases?.contains(preferredBase) == true {
                newestSelectedFallback = resolution
            }
        }
        guard let selected = newestValidAutomatic ?? newestSelectedFallback else {
            return nil
        }
        touchTranscriptAccess(for: selected.key)
        return selected
    }

    /// What the caption-language picker can promise for each language, in one
    /// actor turn.
    ///
    /// Deliberately does not touch `lastAccessAt`: merely opening the picker
    /// must not reorder LRU eviction across every language of a video.
    func captionLanguageAvailability(
        videoId: String,
        voiceCodeByLanguage: [String: String]
    ) -> [String: YouTubeCaptionLanguageAvailability] {
        let videoHash = YouTubeCacheDigest.sha256(videoId)
        let candidates = manifest.entries.values
            .filter { $0.key.videoIdHash == videoHash && $0.hasTranscript }
            .sorted { $0.lastAccessAt > $1.lastAccessAt }

        var result: [String: YouTubeCaptionLanguageAvailability] = [:]
        for candidate in candidates {
            let base = Self.baseLanguage(candidate.key.trackLanguage)
            guard !base.isEmpty else { continue }
            // Newest entry wins: a second transcript for the same language is
            // an older fingerprint the picker would never select anyway.
            guard result[base] == nil else { continue }
            guard let document = transcriptWithoutTouch(for: candidate.key) else {
                markTranscriptCorrupt(for: candidate.key)
                continue
            }
            let readableIndexes = document.paragraphs
                .filter { SpeechTextSanitizer.containsSpeakableContent($0.text) }
                .map(\.id)
            let audio: YouTubeAudioCacheCoverage
            if let voiceCode = voiceCodeByLanguage[base], !readableIndexes.isEmpty {
                audio = audioCacheCoverage(
                    for: candidate.key,
                    voiceCode: voiceCode,
                    paragraphIndexes: readableIndexes
                )
            } else {
                audio = .none(totalParagraphs: readableIndexes.count)
            }
            result[base] = YouTubeCaptionLanguageAvailability(
                hasTranscript: true,
                audio: audio
            )
        }
        return result
    }

    private func transcriptWithoutTouch(
        for key: YouTubeTranscriptCacheKey
    ) -> YouTubeTranscriptDocument? {
        guard let storageKey = try? validatedStorageKey(key.storageKey),
              let directory = try? entryDirectory(storageKey, create: false),
              let url = try? safeURL(directory.appendingPathComponent(Self.transcriptFilename)),
              let data = try? Data(contentsOf: url),
              let document = try? Self.decode(YouTubeTranscriptDocument.self, from: data),
              (try? validate(document: document, for: key)) != nil else { return nil }
        return document
    }

    /// Read-only view of the LRU timestamp, so tests can prove that a lookup
    /// which must not count as usage really did not touch it.
    func lastAccessAtForTesting(_ key: YouTubeTranscriptCacheKey) -> Date? {
        guard let storageKey = try? validatedStorageKey(key.storageKey) else { return nil }
        return manifest.entries[storageKey]?.lastAccessAt
    }

    private func touchTranscriptAccess(for key: YouTubeTranscriptCacheKey) {
        guard let storageKey = try? validatedStorageKey(key.storageKey),
              var entry = manifest.entries[storageKey],
              entry.key == key,
              entry.hasTranscript else { return }
        entry.lastAccessAt = clock.now()
        manifest.entries[storageKey] = entry
        try? persistManifest()
    }

    // MARK: TTS audio generated by CastReader

    func storeAudioSegments(
        _ segments: [AudioSegment],
        for audioKey: YouTubeTTSAudioCacheKey,
        transcriptKey: YouTubeTranscriptCacheKey
    ) throws {
        guard !segments.isEmpty,
              audioKey.schemaVersion > 0,
              audioKey.transcriptFingerprint == transcriptKey.transcriptFingerprint,
              audioKey.paragraphIndex.map({ paragraph in
                  paragraph >= 0 && segments.allSatisfy { $0.paragraphIndex == paragraph }
              }) ?? true else {
            throw YouTubeCacheError.keyMismatch
        }
        guard segments.allSatisfy({ !$0.audioData.isEmpty }) else {
            throw YouTubeCacheError.emptyResource
        }

        var totalAudioBytes: Int64 = 0
        for segment in segments {
            let added = totalAudioBytes.addingReportingOverflow(Int64(segment.audioData.count))
            guard !added.overflow else { throw YouTubeCacheError.resourceTooLarge }
            totalAudioBytes = added.partialValue
        }
        guard totalAudioBytes <= limits.maxBytes else {
            throw YouTubeCacheError.resourceTooLarge
        }

        let storageKey = try validatedStorageKey(transcriptKey.storageKey)
        let variantKey = try validatedStorageKey(audioKey.storageKey)
        let entryDir = try entryDirectory(storageKey, create: true)
        let audioRoot = try safeURL(
            entryDir.appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
        )
        try fileManager.createDirectory(at: audioRoot, withIntermediateDirectories: true)
        let finalDirectory = try safeURL(
            audioRoot.appendingPathComponent(variantKey, isDirectory: true)
        )
        let replacedByteSize = fileManager.fileExists(atPath: finalDirectory.path)
            ? directoryByteSize(finalDirectory)
            : 0
        let existingReplayEligibility: Bool = {
            guard let metadataURL = try? safeURL(
                finalDirectory.appendingPathComponent(Self.audioManifestFilename)
            ),
            let data = try? Data(contentsOf: metadataURL),
            let cached = try? Self.decode(
                YouTubeCachedAudioManifest.self,
                from: data
            ),
            cached.key == audioKey else { return false }
            return cached.isReplayEligible
        }()

        let stagingName = "staging-\(UUID().uuidString.lowercased())"
        let staging = try safeURL(audioRoot.appendingPathComponent(stagingName, isDirectory: true))
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var cachedSegments: [YouTubeCachedAudioSegment] = []
        var storedByteSize: Int64 = 0

        do {
            for (position, segment) in segments.enumerated() {
                let ext = segment.isWavFormat ? "wav" : "mp3"
                let filename = String(format: "segment-%06d.%@", position, ext)
                let audioURL = try safeURL(staging.appendingPathComponent(filename))
                try segment.audioData.write(to: audioURL, options: .atomic)
                cachedSegments.append(
                    YouTubeCachedAudioSegment(
                        id: segment.id,
                        paragraphIndex: segment.paragraphIndex,
                        segmentIndex: segment.segmentIndex,
                        audioFilename: filename,
                        timestamps: segment.timestamps,
                        duration: segment.duration,
                        text: segment.text,
                        isWavFormat: segment.isWavFormat,
                        unprocessedText: segment.unprocessedText,
                        speaker: segment.speaker
                    )
                )
            }

            let audioManifest = YouTubeCachedAudioManifest(
                key: audioKey,
                segments: cachedSegments,
                isReplayEligible: existingReplayEligibility
            )
            let metadata = try Self.encode(audioManifest)
            let combined = totalAudioBytes.addingReportingOverflow(Int64(metadata.count))
            guard !combined.overflow, combined.partialValue <= limits.maxBytes else {
                throw YouTubeCacheError.resourceTooLarge
            }
            storedByteSize = combined.partialValue
            try metadata.write(
                to: try safeURL(staging.appendingPathComponent(Self.audioManifestFilename)),
                options: .atomic
            )

            if fileManager.fileExists(atPath: finalDirectory.path) {
                try safeRemove(finalDirectory)
            }
            try fileManager.moveItem(at: staging, to: finalDirectory)
        } catch {
            try? safeRemove(staging)
            throw error
        }

        var entry = try ensuredEntry(for: transcriptKey)
        entry.audioVariantKeys.insert(variantKey)
        entry.lastAccessAt = clock.now()
        manifest.entries[storageKey] = entry
        try finalizeMutation(
            for: storageKey,
            replacing: replacedByteSize,
            with: storedByteSize
        )
        NotificationCenter.default.post(
            name: .castReaderYouTubeAudioCacheChanged,
            object: transcriptKey.storageKey
        )
    }

    func audioSegments(
        for audioKey: YouTubeTTSAudioCacheKey,
        transcriptKey: YouTubeTranscriptCacheKey
    ) -> [AudioSegment]? {
        cachedAudioPlayback(
            for: audioKey,
            transcriptKey: transcriptKey
        )?.segments
    }

    func cachedAudioPlayback(
        for audioKey: YouTubeTTSAudioCacheKey,
        transcriptKey: YouTubeTranscriptCacheKey
    ) -> YouTubeCachedAudioPlayback? {
        guard !Task.isCancelled else { return nil }
        guard audioKey.schemaVersion > 0,
              audioKey.transcriptFingerprint == transcriptKey.transcriptFingerprint,
              let storageKey = try? validatedStorageKey(transcriptKey.storageKey),
              let variantKey = try? validatedStorageKey(audioKey.storageKey),
              var entry = manifest.entries[storageKey],
              entry.key == transcriptKey else {
            return nil
        }

        // A never-generated voice/paragraph variant is an ordinary cache miss,
        // not corruption. The previous combined guard called self-heal here,
        // causing a directory recount and manifest rewrite before every first
        // TTS request (and Main + ReadVM could trigger it twice).
        guard entry.audioVariantKeys.contains(variantKey) else { return nil }

        guard !Task.isCancelled else { return nil }
        guard let entryDir = try? entryDirectory(storageKey, create: false),
              let variantDir = try? safeURL(
                entryDir
                    .appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
                    .appendingPathComponent(variantKey, isDirectory: true)
              ),
              let metadataURL = try? safeURL(
                variantDir.appendingPathComponent(Self.audioManifestFilename)
              ),
              let metadataData = try? Data(contentsOf: metadataURL),
              let cached = try? Self.decode(
                YouTubeCachedAudioManifest.self,
                from: metadataData
              ),
              cached.key == audioKey,
              !cached.segments.isEmpty,
              audioKey.paragraphIndex.map({ paragraphIndex in
                  cached.segments.allSatisfy {
                      $0.paragraphIndex == paragraphIndex
                  }
              }) ?? true else {
            markAudioCorrupt(audioKey: audioKey, transcriptKey: transcriptKey)
            return nil
        }

        var rebuilt: [AudioSegment] = []
        for item in cached.segments {
            guard !Task.isCancelled else { return nil }
            guard Self.isSafeResourceFilename(item.audioFilename),
                  let url = try? safeURL(variantDir.appendingPathComponent(item.audioFilename)),
                  let audioData = try? Data(contentsOf: url),
                  !audioData.isEmpty else {
                markAudioCorrupt(audioKey: audioKey, transcriptKey: transcriptKey)
                return nil
            }
            let segment = AudioSegment(
                paragraphIndex: item.paragraphIndex,
                segmentIndex: item.segmentIndex,
                audioData: audioData,
                timestamps: item.timestamps,
                duration: item.duration,
                text: item.text,
                isWavFormat: item.isWavFormat,
                unprocessedText: item.unprocessedText,
                speaker: item.speaker
            )
            guard segment.id == item.id else {
                markAudioCorrupt(audioKey: audioKey, transcriptKey: transcriptKey)
                return nil
            }
            rebuilt.append(segment)
        }

        guard !Task.isCancelled else { return nil }
        entry.lastAccessAt = clock.now()
        manifest.entries[storageKey] = entry
        try? persistManifest()
        return YouTubeCachedAudioPlayback(
            segments: rebuilt,
            isReplayEligible: cached.isReplayEligible
        )
    }

    /// Marks a paragraph as a true replay only after its queue has naturally
    /// completed once. This closes the generate-close-reopen quota loophole.
    func markAudioReplayEligible(
        for audioKey: YouTubeTTSAudioCacheKey,
        transcriptKey: YouTubeTranscriptCacheKey
    ) throws {
        guard audioKey.transcriptFingerprint == transcriptKey.transcriptFingerprint,
              let storageKey = try? validatedStorageKey(transcriptKey.storageKey),
              let variantKey = try? validatedStorageKey(audioKey.storageKey),
              var entry = manifest.entries[storageKey],
              entry.key == transcriptKey,
              entry.audioVariantKeys.contains(variantKey),
              let entryDir = try? entryDirectory(storageKey, create: false),
              let variantDir = try? safeURL(
                  entryDir
                      .appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
                      .appendingPathComponent(variantKey, isDirectory: true)
              ),
              let metadataURL = try? safeURL(
                  variantDir.appendingPathComponent(Self.audioManifestFilename)
              ),
              let metadata = try? Data(contentsOf: metadataURL),
              let cached = try? Self.decode(
                  YouTubeCachedAudioManifest.self,
                  from: metadata
              ),
              cached.key == audioKey,
              !cached.segments.isEmpty else {
            throw YouTubeCacheError.keyMismatch
        }
        guard !cached.isReplayEligible else { return }
        let updated = YouTubeCachedAudioManifest(
            key: cached.key,
            segments: cached.segments,
            isReplayEligible: true
        )
        let updatedMetadata = try Self.encode(updated)
        try updatedMetadata.write(to: metadataURL, options: .atomic)
        entry.lastAccessAt = clock.now()
        manifest.entries[storageKey] = entry
        try finalizeMutation(
            for: storageKey,
            replacing: Int64(metadata.count),
            with: Int64(updatedMetadata.count)
        )
        NotificationCenter.default.post(
            name: .castReaderYouTubeAudioCacheChanged,
            object: transcriptKey.storageKey
        )
    }

    /// Reports whether every readable transcript paragraph already has a
    /// complete CastReader-generated TTS variant for the selected voice. This
    /// deliberately checks the small per-paragraph manifests and file sizes,
    /// without loading the cached audio bytes into memory merely to draw UI.
    func audioCacheCoverage(
        for transcriptKey: YouTubeTranscriptCacheKey,
        voiceCode: String,
        paragraphIndexes: [Int]
    ) -> YouTubeAudioCacheCoverage {
        let indexes = Array(Set(paragraphIndexes.filter { $0 >= 0 })).sorted()
        guard !indexes.isEmpty else { return .none(totalParagraphs: 0) }
        guard let storageKey = try? validatedStorageKey(transcriptKey.storageKey),
              let entry = manifest.entries[storageKey],
              entry.key == transcriptKey,
              let entryDir = try? entryDirectory(storageKey, create: false) else {
            return .none(totalParagraphs: indexes.count)
        }

        var cachedCount = 0
        for paragraphIndex in indexes {
            let audioKey = YouTubeTTSAudioCacheKey(
                transcriptFingerprint: transcriptKey.transcriptFingerprint,
                voiceCode: voiceCode,
                playbackLanguage: transcriptKey.trackLanguage,
                schemaVersion: YouTubeTTSAudioCacheSchema.current,
                paragraphIndex: paragraphIndex
            )
            guard let variantKey = try? validatedStorageKey(audioKey.storageKey),
                  entry.audioVariantKeys.contains(variantKey) else { continue }
            if audioVariantIsUsable(
                audioKey: audioKey,
                variantKey: variantKey,
                entryDirectory: entryDir
            ) {
                cachedCount += 1
            } else {
                markAudioCorrupt(
                    audioKey: audioKey,
                    transcriptKey: transcriptKey
                )
            }
        }

        if cachedCount == indexes.count {
            return .complete(totalParagraphs: indexes.count)
        }
        if cachedCount > 0 {
            return .partial(
                cachedParagraphs: cachedCount,
                totalParagraphs: indexes.count
            )
        }
        return .none(totalParagraphs: indexes.count)
    }

    /// Combines transcript, generated audio and still-image persistence into
    /// the single cache state shown by the reader and History. This is kept in
    /// the cache actor so every surface applies the same offline definition.
    func offlineCacheCoverage(
        for transcriptKey: YouTubeTranscriptCacheKey,
        voiceCode: String,
        paragraphIndexes: [Int]
    ) -> YouTubeOfflineCacheCoverage {
        let audio = audioCacheCoverage(
            for: transcriptKey,
            voiceCode: voiceCode,
            paragraphIndexes: paragraphIndexes
        )
        guard let transcript = transcriptWithoutTouch(for: transcriptKey) else {
            markTranscriptCorrupt(for: transcriptKey)
            return YouTubeOfflineCacheCoverage(
                audio: audio,
                hasTranscript: false,
                cachedArtworkResourceCount: 0,
                requiredArtworkResourceCount: 0
            )
        }

        if let storyboard = transcript.storyboard {
            let requiresThumbnail = transcript.metadata.thumbnailURL?.isEmpty == false
            let hasThumbnail = requiresThumbnail && resourceIsPresent(
                filename: Self.thumbnailFilename,
                for: transcriptKey,
                isDeclared: { $0.hasThumbnail },
                markMissing: { $0.hasThumbnail = false }
            )
            let requiredCount = storyboard.sheetCount + (requiresThumbnail ? 1 : 0)
            let missingCount = missingStoryboardSheetIndexes(
                for: storyboard,
                cacheKey: transcriptKey
            ).count
            let cachedSheetCount = max(0, storyboard.sheetCount - missingCount)
            return YouTubeOfflineCacheCoverage(
                audio: audio,
                hasTranscript: true,
                cachedArtworkResourceCount: cachedSheetCount + (hasThumbnail ? 1 : 0),
                requiredArtworkResourceCount: requiredCount
            )
        }

        let requiresThumbnail = transcript.metadata.thumbnailURL?.isEmpty == false
        let hasThumbnail = requiresThumbnail && resourceIsPresent(
            filename: Self.thumbnailFilename,
            for: transcriptKey,
            isDeclared: { $0.hasThumbnail },
            markMissing: { $0.hasThumbnail = false }
        )
        return YouTubeOfflineCacheCoverage(
            audio: audio,
            hasTranscript: true,
            cachedArtworkResourceCount: hasThumbnail ? 1 : 0,
            requiredArtworkResourceCount: requiresThumbnail ? 1 : 0
        )
    }

    // MARK: Progress

    @discardableResult
    func saveProgress(
        paragraphIndex: Int,
        segmentId: String,
        segmentIndex: Int,
        fractionalProgress: Double,
        paragraphFractionalProgress: Double? = nil,
        for key: YouTubeTranscriptCacheKey
    ) throws -> YouTubePlaybackProgress {
        guard paragraphIndex >= 0,
              segmentIndex >= 0,
              !segmentId.isEmpty,
              fractionalProgress.isFinite,
              (0...1).contains(fractionalProgress),
              paragraphFractionalProgress.map({
                  $0.isFinite && (0...1).contains($0)
              }) ?? true else {
            throw YouTubeCacheError.invalidProgress
        }
        let storageKey = try validatedStorageKey(key.storageKey)
        _ = try entryDirectory(storageKey, create: true)
        let progress = YouTubePlaybackProgress(
            paragraphIndex: paragraphIndex,
            segmentId: segmentId,
            segmentIndex: segmentIndex,
            fractionalProgress: fractionalProgress,
            paragraphFractionalProgress: paragraphFractionalProgress,
            updatedAt: clock.now()
        )
        var entry = try ensuredEntry(for: key)
        entry.progress = progress
        entry.lastAccessAt = progress.updatedAt
        manifest.entries[storageKey] = entry
        // Progress changes no file payload sizes. A full recursive byte scan at
        // the 1 Hz playback cadence can serialize ahead of audio-cache reads
        // and create an audible paragraph-boundary stall.
        try persistManifest()
        return progress
    }

    func progress(for key: YouTubeTranscriptCacheKey) -> YouTubePlaybackProgress? {
        guard let storageKey = try? validatedStorageKey(key.storageKey),
              var entry = manifest.entries[storageKey],
              entry.key == key,
              let progress = entry.progress,
              progress.paragraphIndex >= 0,
              progress.segmentIndex >= 0,
              !progress.segmentId.isEmpty,
              progress.fractionalProgress.isFinite,
              (0...1).contains(progress.fractionalProgress),
              progress.paragraphFractionalProgress.map({
                  $0.isFinite && (0...1).contains($0)
              }) ?? true else { return nil }
        entry.lastAccessAt = clock.now()
        manifest.entries[storageKey] = entry
        try? persistManifest()
        return progress
    }

    /// Status-only counterpart of `progress(for:)`; deliberately leaves the
    /// entry access time untouched so rendering History cannot poison LRU.
    func peekProgress(
        for key: YouTubeTranscriptCacheKey
    ) -> YouTubePlaybackProgress? {
        guard let storageKey = try? validatedStorageKey(key.storageKey),
              let entry = manifest.entries[storageKey],
              entry.key == key,
              let progress = entry.progress,
              progress.paragraphIndex >= 0,
              progress.segmentIndex >= 0,
              !progress.segmentId.isEmpty,
              progress.fractionalProgress.isFinite,
              (0...1).contains(progress.fractionalProgress),
              progress.paragraphFractionalProgress.map({
                  $0.isFinite && (0...1).contains($0)
              }) ?? true else { return nil }
        return progress
    }

    // MARK: Still-image resources

    func storeThumbnail(
        _ data: Data,
        for key: YouTubeTranscriptCacheKey
    ) throws {
        try validateStillImageResource(data)
        try storeResource(
            data,
            filename: Self.thumbnailFilename,
            for: key
        ) { entry in
            entry.hasThumbnail = true
        }
        NotificationCenter.default.post(
            name: .castReaderYouTubeThumbnailCacheChanged,
            object: key.storageKey
        )
        NotificationCenter.default.post(
            name: .castReaderYouTubeArtworkCacheChanged,
            object: key.storageKey
        )
    }

    func thumbnail(
        for key: YouTubeTranscriptCacheKey,
        minimumPixelWidth: Int = 1,
        minimumPixelHeight: Int = 1
    ) -> Data? {
        resource(
            filename: Self.thumbnailFilename,
            for: key,
            minimumPixels: (
                width: max(1, minimumPixelWidth),
                height: max(1, minimumPixelHeight)
            ),
            isDeclared: { $0.hasThumbnail },
            markMissing: { $0.hasThumbnail = false }
        )
    }

    /// Presentation-only lookup for History cards. It reads the newest cached
    /// thumbnail for a video without turning list rendering into LRU activity.
    func peekThumbnail(videoId: String) -> Data? {
        let videoHash = YouTubeCacheDigest.sha256(videoId)
        let candidates = manifest.entries.values
            .filter { $0.key.videoIdHash == videoHash && $0.hasThumbnail }
            .sorted { $0.lastAccessAt > $1.lastAccessAt }
        for candidate in candidates {
            if let data = resource(
                filename: Self.thumbnailFilename,
                for: candidate.key,
                touchAccess: false,
                isDeclared: { $0.hasThumbnail },
                markMissing: { $0.hasThumbnail = false }
            ) {
                return data
            }
        }
        return nil
    }

    func storeStoryboardSheet(
        _ data: Data,
        sheetIndex: Int,
        for key: YouTubeTranscriptCacheKey,
        notifyChange: Bool = true
    ) throws {
        guard sheetIndex >= 0 else { throw YouTubeCacheError.invalidKey }
        let expectedPixels: (width: Int, height: Int)?
        if let storyboard = transcriptWithoutTouch(for: key)?.storyboard {
            guard let expected = Self.requiredStoryboardPixels(
                storyboard,
                sheetIndex: sheetIndex
            ) else { throw YouTubeCacheError.invalidKey }
            expectedPixels = expected
        } else {
            expectedPixels = nil
        }
        try validateStillImageResource(data, minimumPixels: expectedPixels)
        let filename = Self.storyboardFilename(sheetIndex)
        try storeResource(
            data,
            subdirectory: Self.storyboardDirectoryName,
            filename: filename,
            for: key
        ) { entry in
            entry.storyboardSheetIndexes.insert(sheetIndex)
        }
        if notifyChange {
            notifyArtworkCacheChanged(for: key)
        }
    }

    func notifyArtworkCacheChanged(for key: YouTubeTranscriptCacheKey) {
        NotificationCenter.default.post(
            name: .castReaderYouTubeArtworkCacheChanged,
            object: key.storageKey
        )
    }

    func storyboardSheet(
        sheetIndex: Int,
        for key: YouTubeTranscriptCacheKey
    ) -> Data? {
        guard sheetIndex >= 0 else { return nil }
        let minimumPixels = transcriptWithoutTouch(for: key)?.storyboard.flatMap {
            Self.requiredStoryboardPixels($0, sheetIndex: sheetIndex)
        }
        return resource(
            subdirectory: Self.storyboardDirectoryName,
            filename: Self.storyboardFilename(sheetIndex),
            for: key,
            minimumPixels: minimumPixels,
            isDeclared: { $0.storyboardSheetIndexes.contains(sheetIndex) },
            markMissing: { $0.storyboardSheetIndexes.remove(sheetIndex) }
        )
    }

    /// Missing sheets remain missing after a failed best-effort download, so a
    /// later reader session can retry them. Unexpected manifest indexes never
    /// count toward the expected storyboard coverage.
    func missingStoryboardSheetIndexes(
        for storyboard: YouTubeStoryboard,
        cacheKey key: YouTubeTranscriptCacheKey
    ) -> [Int] {
        guard storyboard.isValid,
              storyboard.sheetCount <= YouTubeStoryboard.maximumSheetCount else { return [] }
        return (0..<storyboard.sheetCount).filter { sheetIndex in
            !resourceIsPresent(
                subdirectory: Self.storyboardDirectoryName,
                filename: Self.storyboardFilename(sheetIndex),
                for: key,
                minimumPixels: Self.requiredStoryboardPixels(
                    storyboard,
                    sheetIndex: sheetIndex
                ),
                isDeclared: { $0.storyboardSheetIndexes.contains(sheetIndex) },
                markMissing: { $0.storyboardSheetIndexes.remove(sheetIndex) }
            )
        }
    }

    // MARK: Inspection / maintenance

    /// Runs exact byte reconciliation and orphan cleanup on the cache actor.
    /// Construction stays lightweight because the first provider access can
    /// occur on MainActor while handling a share/deep-link route.
    func performStartupMaintenance() throws {
        guard !didPerformStartupMaintenance else { return }
        try Self.reconcileOnDiskCache(
            manifest: &manifest,
            rootDirectory: rootDirectory,
            entriesDirectory: entriesDirectory,
            manifestURL: manifestURL,
            limits: limits,
            fileManager: fileManager
        )
        didPerformStartupMaintenance = true
    }

    func summary(for key: YouTubeTranscriptCacheKey) -> YouTubeCacheEntrySummary? {
        guard let storageKey = try? validatedStorageKey(key.storageKey),
              let entry = manifest.entries[storageKey],
              entry.key == key else { return nil }
        return Self.summary(entry)
    }

    func stats() -> YouTubeCacheStats {
        refreshByteSizes()
        try? persistManifest()
        return YouTubeCacheStats(
            videoCount: Set(manifest.entries.values.map { $0.key.videoIdHash }).count,
            entryCount: manifest.entries.count,
            totalBytes: Self.saturatedByteTotal(
                manifest.entries.values.map(\.byteSize)
            )
        )
    }

    func pruneNow() throws {
        refreshByteSizes()
        try pruneIfNeeded()
        try persistManifest()
    }

    // MARK: Resource helpers

    private func storeResource(
        _ data: Data,
        subdirectory: String? = nil,
        filename: String,
        for key: YouTubeTranscriptCacheKey,
        update: (inout YouTubeCacheManifestEntry) -> Void
    ) throws {
        guard !data.isEmpty else { throw YouTubeCacheError.emptyResource }
        try validateResourceSize(data.count)
        let storageKey = try validatedStorageKey(key.storageKey)
        var directory = try entryDirectory(storageKey, create: true)
        if let subdirectory {
            directory = try safeURL(
                directory.appendingPathComponent(subdirectory, isDirectory: true)
            )
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let url = try safeURL(directory.appendingPathComponent(filename))
        let replacedByteSize = regularFileByteSize(url)
        try data.write(to: url, options: .atomic)

        var entry = try ensuredEntry(for: key)
        update(&entry)
        entry.lastAccessAt = clock.now()
        manifest.entries[storageKey] = entry
        try finalizeMutation(
            for: storageKey,
            replacing: replacedByteSize,
            with: Int64(data.count)
        )
    }

    private func resource(
        subdirectory: String? = nil,
        filename: String,
        for key: YouTubeTranscriptCacheKey,
        touchAccess: Bool = true,
        minimumPixels: (width: Int, height: Int)? = nil,
        isDeclared: (YouTubeCacheManifestEntry) -> Bool,
        markMissing: (inout YouTubeCacheManifestEntry) -> Void
    ) -> Data? {
        guard let storageKey = try? validatedStorageKey(key.storageKey),
              var entry = manifest.entries[storageKey],
              entry.key == key,
              isDeclared(entry),
              var directory = try? entryDirectory(storageKey, create: false) else {
            return nil
        }
        if let subdirectory {
            guard let nested = try? safeURL(
                directory.appendingPathComponent(subdirectory, isDirectory: true)
            ) else { return nil }
            directory = nested
        }
        let resourceURL = try? safeURL(directory.appendingPathComponent(filename))
        guard let resourceURL,
              let data = try? Data(contentsOf: resourceURL),
              Self.isUsableStillImage(data, minimumPixels: minimumPixels) else {
            if let resourceURL {
                try? safeRemove(resourceURL)
            }
            markMissing(&entry)
            manifest.entries[storageKey] = entry
            refreshByteSize(for: storageKey)
            try? persistManifest()
            return nil
        }
        if touchAccess {
            entry.lastAccessAt = clock.now()
            manifest.entries[storageKey] = entry
            try? persistManifest()
        }
        return data
    }

    /// Non-LRU-touching presence check used by cache badges and prefetch
    /// planning. Decode validation is intentional: a CDN 200 HTML response or
    /// corrupt file must never earn the "available offline" badge.
    private func resourceIsPresent(
        subdirectory: String? = nil,
        filename: String,
        for key: YouTubeTranscriptCacheKey,
        minimumPixels: (width: Int, height: Int)? = nil,
        isDeclared: (YouTubeCacheManifestEntry) -> Bool,
        markMissing: (inout YouTubeCacheManifestEntry) -> Void
    ) -> Bool {
        guard let storageKey = try? validatedStorageKey(key.storageKey),
              var entry = manifest.entries[storageKey],
              entry.key == key,
              isDeclared(entry),
              var directory = try? entryDirectory(storageKey, create: false) else {
            return false
        }
        if let subdirectory {
            guard let nested = try? safeURL(
                directory.appendingPathComponent(subdirectory, isDirectory: true)
            ) else { return false }
            directory = nested
        }
        let resourceURL = try? safeURL(directory.appendingPathComponent(filename))
        let isPresent = resourceURL
            .flatMap { try? Data(contentsOf: $0) }
            .map { Self.isUsableStillImage($0, minimumPixels: minimumPixels) }
            == true
        guard !isPresent else { return true }

        if let resourceURL {
            try? safeRemove(resourceURL)
        }

        markMissing(&entry)
        manifest.entries[storageKey] = entry
        refreshByteSize(for: storageKey)
        try? persistManifest()
        return false
    }

    // MARK: Manifest / LRU

    /// Remove only cache-owned opaque entry directories that the manifest can
    /// no longer account for, plus crash-left audio staging directories. This
    /// keeps the physical 500 MB ceiling meaningful after a corrupt manifest
    /// or an interrupted atomic audio replacement.
    private nonisolated static func reconcileOnDiskCache(
        manifest: inout YouTubeCacheManifest,
        rootDirectory: URL,
        entriesDirectory: URL,
        manifestURL: URL,
        limits: YouTubeCacheLimits,
        fileManager: FileManager
    ) throws {
        func safeURL(_ candidate: URL) throws -> URL {
            let standardized = candidate.standardizedFileURL
            guard standardized.isFileURL,
                  Self.isStrictDescendant(standardized, of: rootDirectory) else {
                throw YouTubeCacheError.unsafePath
            }
            let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
            guard Self.isStrictDescendant(resolved, of: rootDirectory) else {
                throw YouTubeCacheError.unsafePath
            }
            return standardized
        }

        func safeRemove(_ candidate: URL) throws {
            let safe = try safeURL(candidate)
            guard fileManager.fileExists(atPath: safe.path) else { return }
            try fileManager.removeItem(at: safe)
        }

        func directoryByteSize(_ directory: URL) -> Int64 {
            guard let safeDirectory = try? safeURL(directory),
                  let enumerator = fileManager.enumerator(
                      at: safeDirectory,
                      includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                      options: []
                  ) else { return 0 }
            var total: Int64 = 0
            while let url = enumerator.nextObject() as? URL {
                guard (try? safeURL(url)) != nil,
                      let values = try? url.resourceValues(
                          forKeys: [.isRegularFileKey, .fileSizeKey]
                      ),
                      values.isRegularFile == true,
                      let size = values.fileSize else { continue }
                let added = total.addingReportingOverflow(Int64(size))
                if added.overflow { return Int64.max }
                total = added.partialValue
            }
            return total
        }

        let children = try fileManager.contentsOfDirectory(
            at: entriesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        for child in children {
            let name = child.lastPathComponent
            guard YouTubeCacheDigest.isDigest(name),
                  let values = try? child.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            guard manifest.entries[name] != nil else {
                try safeRemove(child)
                continue
            }

            let audioDirectory = child.appendingPathComponent(
                Self.audioDirectoryName,
                isDirectory: true
            )
            guard let audioChildren = try? fileManager.contentsOfDirectory(
                at: try safeURL(audioDirectory),
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for staging in audioChildren where staging.lastPathComponent.hasPrefix("staging-") {
                let stagingValues = try? staging.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard stagingValues?.isDirectory == true,
                      stagingValues?.isSymbolicLink != true else { continue }
                try safeRemove(staging)
            }
        }

        for storageKey in Array(manifest.entries.keys) {
            let directory = entriesDirectory.appendingPathComponent(
                storageKey,
                isDirectory: true
            )
            var isDirectory: ObjCBool = false
            guard var entry = manifest.entries[storageKey],
                  let safeDirectory = try? safeURL(directory),
                  fileManager.fileExists(
                      atPath: safeDirectory.path,
                      isDirectory: &isDirectory
                  ),
                  isDirectory.boolValue else {
                manifest.entries.removeValue(forKey: storageKey)
                continue
            }
            entry.byteSize = directoryByteSize(safeDirectory)
            manifest.entries[storageKey] = entry
        }

        func exceedsLimits() -> Bool {
            let videoCount = Set(manifest.entries.values.map { $0.key.videoIdHash }).count
            let bytes = saturatedByteTotal(
                manifest.entries.values.map(\.byteSize)
            )
            return videoCount > limits.maxVideoCount || bytes > limits.maxBytes
        }

        while exceedsLimits() {
            let grouped = Dictionary(
                grouping: manifest.entries.values,
                by: { $0.key.videoIdHash }
            )
            guard let oldestVideoHash = grouped.map({ videoHash, entries in
                (
                    videoHash,
                    entries.map(\.lastAccessAt).max() ?? .distantPast
                )
            }).min(by: {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                return $0.0 < $1.0
            })?.0 else { break }

            let storageKeys = manifest.entries.compactMap { storageKey, entry in
                entry.key.videoIdHash == oldestVideoHash ? storageKey : nil
            }
            guard !storageKeys.isEmpty else { break }
            for storageKey in storageKeys {
                let directory = entriesDirectory.appendingPathComponent(
                    storageKey,
                    isDirectory: true
                )
                try? safeRemove(directory)
                manifest.entries.removeValue(forKey: storageKey)
            }
        }

        let data = try Self.encode(manifest)
        try data.write(to: try safeURL(manifestURL), options: .atomic)
    }

    private func ensuredEntry(
        for key: YouTubeTranscriptCacheKey
    ) throws -> YouTubeCacheManifestEntry {
        guard Self.valid(key: key) else { throw YouTubeCacheError.invalidKey }
        let storageKey = try validatedStorageKey(key.storageKey)
        if let existing = manifest.entries[storageKey] {
            guard existing.key == key else { throw YouTubeCacheError.keyMismatch }
            return existing
        }
        let now = clock.now()
        return YouTubeCacheManifestEntry(
            key: key,
            createdAt: now,
            lastAccessAt: now,
            byteSize: 0,
            hasTranscript: false,
            hasThumbnail: false,
            storyboardSheetIndexes: [],
            audioVariantKeys: [],
            progress: nil,
            selectionLanguageBases: nil
        )
    }

    /// Normal writes update only the bytes they replaced. Startup, explicit
    /// maintenance and diagnostics retain full reconciliation, while the hot
    /// first-audio path never walks every mature cache entry.
    private func finalizeMutation(
        for storageKey: String,
        replacing replacedByteSize: Int64,
        with storedByteSize: Int64
    ) throws {
        updateByteSize(
            for: storageKey,
            replacing: replacedByteSize,
            with: storedByteSize
        )
        try pruneIfNeeded()
        try persistManifest()
    }

    private func updateByteSize(
        for storageKey: String,
        replacing replacedByteSize: Int64,
        with storedByteSize: Int64
    ) {
        guard var entry = manifest.entries[storageKey],
              replacedByteSize >= 0,
              storedByteSize >= 0,
              entry.byteSize >= replacedByteSize else {
            refreshByteSize(for: storageKey)
            return
        }
        let retainedByteSize = entry.byteSize - replacedByteSize
        let updated = retainedByteSize.addingReportingOverflow(storedByteSize)
        guard !updated.overflow else {
            refreshByteSize(for: storageKey)
            return
        }
        entry.byteSize = updated.partialValue
        manifest.entries[storageKey] = entry
    }

    private func audioVariantIsUsable(
        audioKey: YouTubeTTSAudioCacheKey,
        variantKey: String,
        entryDirectory: URL
    ) -> Bool {
        guard let variantDirectory = try? safeURL(
            entryDirectory
                .appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
                .appendingPathComponent(variantKey, isDirectory: true)
        ),
        let metadataURL = try? safeURL(
            variantDirectory.appendingPathComponent(Self.audioManifestFilename)
        ),
        let metadata = try? Data(contentsOf: metadataURL),
        let cached = try? Self.decode(YouTubeCachedAudioManifest.self, from: metadata),
        cached.key == audioKey,
        !cached.segments.isEmpty else { return false }

        return cached.segments.allSatisfy { item in
            guard item.paragraphIndex == audioKey.paragraphIndex,
                  Self.isSafeResourceFilename(item.audioFilename),
                  let url = try? safeURL(
                      variantDirectory.appendingPathComponent(item.audioFilename)
                  ),
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .fileSizeKey]
                  ) else { return false }
            return values.isRegularFile == true && (values.fileSize ?? 0) > 0
        }
    }

    private func refreshByteSizes() {
        for storageKey in Array(manifest.entries.keys) {
            refreshByteSize(for: storageKey)
        }
    }

    private func refreshByteSize(for storageKey: String) {
        guard var entry = manifest.entries[storageKey],
              let directory = try? entryDirectory(storageKey, create: false) else {
            manifest.entries.removeValue(forKey: storageKey)
            return
        }
        entry.byteSize = directoryByteSize(directory)
        manifest.entries[storageKey] = entry
    }

    private func pruneIfNeeded() throws {
        while exceedsLimits, let videoHash = oldestVideoHash() {
            let storageKeys = manifest.entries.compactMap { storageKey, entry in
                entry.key.videoIdHash == videoHash ? storageKey : nil
            }
            guard !storageKeys.isEmpty else { break }
            for storageKey in storageKeys {
                if let directory = try? entryDirectory(storageKey, create: false) {
                    // Unsafe/symlinked paths are dropped from the manifest but
                    // never followed or deleted outside the resolved root.
                    try? safeRemove(directory)
                }
                manifest.entries.removeValue(forKey: storageKey)
            }
        }
    }

    private var exceedsLimits: Bool {
        let videoCount = Set(manifest.entries.values.map { $0.key.videoIdHash }).count
        let bytes = Self.saturatedByteTotal(
            manifest.entries.values.map(\.byteSize)
        )
        return videoCount > limits.maxVideoCount || bytes > limits.maxBytes
    }

    private nonisolated static func saturatedByteTotal<S: Sequence>(
        _ sizes: S
    ) -> Int64 where S.Element == Int64 {
        var total: Int64 = 0
        for rawSize in sizes {
            let added = total.addingReportingOverflow(max(0, rawSize))
            if added.overflow { return Int64.max }
            total = added.partialValue
        }
        return total
    }

    private func oldestVideoHash() -> String? {
        let grouped = Dictionary(grouping: manifest.entries.values, by: { $0.key.videoIdHash })
        return grouped.map { videoHash, entries in
            (
                videoHash,
                entries.map(\.lastAccessAt).max() ?? .distantPast
            )
        }.min {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0 < $1.0
        }?.0
    }

    private func persistManifest() throws {
        let data = try Self.encode(manifest)
        try data.write(to: try safeURL(manifestURL), options: .atomic)
    }

    private static func loadManifest(from url: URL) -> YouTubeCacheManifest? {
        guard let data = try? Data(contentsOf: url),
              let value = try? decode(YouTubeCacheManifest.self, from: data) else {
            return nil
        }
        return value
    }

    // MARK: Corruption recovery

    private func markTranscriptCorrupt(for key: YouTubeTranscriptCacheKey) {
        guard let storageKey = try? validatedStorageKey(key.storageKey),
              var entry = manifest.entries[storageKey],
              entry.key == key else { return }
        entry.hasTranscript = false
        if let directory = try? entryDirectory(storageKey, create: false),
           let url = try? safeURL(directory.appendingPathComponent(Self.transcriptFilename)) {
            try? safeRemove(url)
        }
        manifest.entries[storageKey] = entry
        refreshByteSize(for: storageKey)
        try? persistManifest()
    }

    private func markAudioCorrupt(
        audioKey: YouTubeTTSAudioCacheKey,
        transcriptKey: YouTubeTranscriptCacheKey
    ) {
        guard let storageKey = try? validatedStorageKey(transcriptKey.storageKey),
              let variantKey = try? validatedStorageKey(audioKey.storageKey),
              var entry = manifest.entries[storageKey],
              entry.key == transcriptKey else { return }
        entry.audioVariantKeys.remove(variantKey)
        if let entryDir = try? entryDirectory(storageKey, create: false),
           let variantDir = try? safeURL(
            entryDir
                .appendingPathComponent(Self.audioDirectoryName, isDirectory: true)
                .appendingPathComponent(variantKey, isDirectory: true)
           ) {
            try? safeRemove(variantDir)
        }
        manifest.entries[storageKey] = entry
        refreshByteSize(for: storageKey)
        try? persistManifest()
    }

    // MARK: Validation / filesystem containment

    private func validate(
        document: YouTubeTranscriptDocument,
        for key: YouTubeTranscriptCacheKey
    ) throws {
        guard Self.valid(key: key),
              YouTubeCacheDigest.sha256(document.metadata.videoId) == key.videoIdHash,
              Self.normalizedLanguage(document.track.languageCode) == key.trackLanguage,
              YouTubeCacheDigest.sha256(Self.selectedTrackIdentity(document.track))
                == key.trackIdentityHash,
              Self.transcriptFingerprint(for: document.cues) == key.transcriptFingerprint,
              document.storyboard?.isValid != false,
              document.artworkSchemaVersion == YouTubeArtworkCacheSchema.current,
              Self.hasUsableTimeline(document) else {
            throw YouTubeCacheError.keyMismatch
        }
    }

    /// Older internal builds could cache transcript-panel accessibility text
    /// after YouTube collapsed each DOM row, leaving every cue at one default
    /// timestamp. Treat that artifact as corrupt during both writes and reads
    /// so cache recovery deletes it and performs a fresh timedtext extraction.
    private static func hasUsableTimeline(
        _ document: YouTubeTranscriptDocument
    ) -> Bool {
        guard document.track.baseURL.hasPrefix("transcript-bridge:"),
              document.cues.count > 1,
              let firstStart = document.cues.first?.startMs else {
            return true
        }
        return document.cues.dropFirst().contains { $0.startMs != firstStart }
    }

    private static func valid(key: YouTubeTranscriptCacheKey) -> Bool {
        YouTubeCacheDigest.isDigest(key.videoIdHash)
            && !key.trackLanguage.isEmpty
            && YouTubeCacheDigest.isDigest(key.trackIdentityHash)
            && YouTubeCacheDigest.isDigest(key.transcriptFingerprint)
            && YouTubeCacheDigest.isDigest(key.storageKey)
    }

    private func validateStillImageResource(
        _ data: Data,
        minimumPixels: (width: Int, height: Int)? = nil
    ) throws {
        try validateResourceSize(data.count)
        guard data.count <= 20 * 1_024 * 1_024,
              Self.isUsableStillImage(
                  data,
                  minimumPixels: minimumPixels
              ) else {
            throw YouTubeCacheError.invalidImageResource
        }
    }

    /// ImageIO inspects dimensions without eagerly decoding the full source,
    /// then proves the first frame can actually be decoded through a tiny
    /// thumbnail. The pixel ceiling bounds the later UIImage/crop allocation.
    private nonisolated static func isUsableStillImage(
        _ data: Data,
        minimumPixels: (width: Int, height: Int)? = nil
    ) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(
                  data as CFData,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(
                  source,
                  0,
                  [kCGImageSourceShouldCache: false] as CFDictionary
              ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              (1...8_192).contains(width),
              (1...8_192).contains(height),
              Int64(width) * Int64(height) <= 32_000_000 else { return false }
        if let minimumPixels,
           (width < minimumPixels.width || height < minimumPixels.height) {
            return false
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) != nil
    }

    private nonisolated static func requiredStoryboardPixels(
        _ storyboard: YouTubeStoryboard,
        sheetIndex: Int
    ) -> (width: Int, height: Int)? {
        guard storyboard.isValid,
              (0..<storyboard.sheetCount).contains(sheetIndex) else { return nil }
        let consumed = sheetIndex.multipliedReportingOverflow(
            by: storyboard.tilesPerSheet
        )
        guard !consumed.overflow, consumed.partialValue < storyboard.frameCount else {
            return nil
        }
        let framesOnSheet = min(
            storyboard.tilesPerSheet,
            storyboard.frameCount - consumed.partialValue
        )
        let usedColumns = min(storyboard.columns, framesOnSheet)
        let usedRows = (framesOnSheet - 1) / storyboard.columns + 1
        let width = usedColumns.multipliedReportingOverflow(by: storyboard.tileWidth)
        let height = usedRows.multipliedReportingOverflow(by: storyboard.tileHeight)
        guard !width.overflow, !height.overflow else { return nil }
        return (width.partialValue, height.partialValue)
    }

    private func validateResourceSize(_ count: Int) throws {
        guard count > 0 else { throw YouTubeCacheError.emptyResource }
        guard Int64(count) <= limits.maxBytes else {
            throw YouTubeCacheError.resourceTooLarge
        }
    }

    private func validatedStorageKey(_ value: String) throws -> String {
        guard YouTubeCacheDigest.isDigest(value) else {
            throw YouTubeCacheError.invalidKey
        }
        return value
    }

    private func entryDirectory(_ storageKey: String, create: Bool) throws -> URL {
        let validated = try validatedStorageKey(storageKey)
        let directory = try safeURL(
            entriesDirectory.appendingPathComponent(validated, isDirectory: true)
        )
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } else {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CocoaError(.fileNoSuchFile)
            }
        }
        return directory
    }

    private func safeURL(_ candidate: URL) throws -> URL {
        let standardized = candidate.standardizedFileURL
        guard standardized.isFileURL,
              Self.isStrictDescendant(standardized, of: rootDirectory) else {
            throw YouTubeCacheError.unsafePath
        }
        let resolved = standardized.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isStrictDescendant(resolved, of: rootDirectory) else {
            throw YouTubeCacheError.unsafePath
        }
        return standardized
    }

    private func safeRemove(_ candidate: URL) throws {
        let safe = try safeURL(candidate)
        guard fileManager.fileExists(atPath: safe.path) else { return }
        try fileManager.removeItem(at: safe)
    }

    private static func isStrictDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootParts = root.standardizedFileURL.pathComponents
        let candidateParts = candidate.standardizedFileURL.pathComponents
        guard candidateParts.count > rootParts.count else { return false }
        return Array(candidateParts.prefix(rootParts.count)) == rootParts
    }

    private func directoryByteSize(_ directory: URL) -> Int64 {
        guard let safeDirectory = try? safeURL(directory),
              let enumerator = fileManager.enumerator(
                at: safeDirectory,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: []
              ) else { return 0 }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard (try? safeURL(url)) != nil,
                  let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  let size = values.fileSize else { continue }
            let added = total.addingReportingOverflow(Int64(size))
            if added.overflow { return Int64.max }
            total = added.partialValue
        }
        return total
    }

    private func regularFileByteSize(_ url: URL) -> Int64 {
        guard let safe = try? safeURL(url),
              let values = try? safe.resourceValues(
                  forKeys: [.isRegularFileKey, .fileSizeKey]
              ),
              values.isRegularFile == true,
              let size = values.fileSize else { return 0 }
        return max(0, Int64(size))
    }

    private static func storyboardFilename(_ index: Int) -> String {
        String(format: "sheet-%06d.bin", index)
    }

    private static func isSafeResourceFilename(_ value: String) -> Bool {
        !value.isEmpty
            && value == URL(fileURLWithPath: value).lastPathComponent
            && !value.contains("/")
            && !value.contains("\\")
    }

    private static func summary(
        _ entry: YouTubeCacheManifestEntry
    ) -> YouTubeCacheEntrySummary {
        YouTubeCacheEntrySummary(
            key: entry.key,
            lastAccessAt: entry.lastAccessAt,
            byteSize: entry.byteSize,
            hasTranscript: entry.hasTranscript,
            hasThumbnail: entry.hasThumbnail,
            storyboardSheetCount: entry.storyboardSheetIndexes.count,
            audioVariantCount: entry.audioVariantKeys.count,
            hasProgress: entry.progress != nil
        )
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        try JSONDecoder().decode(type, from: data)
    }
}
