import Foundation
import UIKit
import XCTest
@testable import CastReader

private final class YouTubeCacheTestClock: YouTubeCacheClock, @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date = Date(timeIntervalSince1970: 1_700_000_000)) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(seconds)
        lock.unlock()
    }
}

final class YouTubeCacheStoreTests: XCTestCase {
    func testCacheRootIsExcludedFromDeviceBackup() throws {
        let fixture = try makeFixture()
        _ = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)

        let values = try fixture.cacheRoot.resourceValues(
            forKeys: [.isExcludedFromBackupKey]
        )
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    func testTranscriptRoundTripSurvivesStoreRecreation() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "hello world")
        let key = YouTubeCacheStore.cacheKey(for: document)

        try await store.storeTranscript(document, for: key)
        let firstRead = await store.transcript(for: key)
        XCTAssertEqual(firstRead, document)

        let reopened = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let secondRead = await reopened.transcript(for: key)
        XCTAssertEqual(secondRead, document)
        let stats = await reopened.stats()
        XCTAssertEqual(stats.videoCount, 1)
        XCTAssertEqual(stats.entryCount, 1)
        XCTAssertGreaterThan(stats.totalBytes, 0)
    }

    func testAudioRoundTripRebuildsEveryAudioSegmentField() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "audio")
        let transcriptKey = YouTubeCacheStore.cacheKey(for: document)
        let audioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current
        )
        let segments = [
            AudioSegment(
                paragraphIndex: 2,
                segmentIndex: 0,
                audioData: Data([0x49, 0x44, 0x33, 0x01]),
                timestamps: [
                    TTSTimestamp(word: "hello", startTime: 0, endTime: 0.4),
                    TTSTimestamp(word: "world", startTime: 0.4, endTime: 0.9),
                ],
                duration: 0.9,
                text: "hello world",
                isWavFormat: false,
                unprocessedText: "remaining",
                speaker: "narrator"
            ),
            AudioSegment(
                paragraphIndex: 2,
                segmentIndex: 1,
                audioData: Data([0x52, 0x49, 0x46, 0x46]),
                timestamps: [],
                duration: 1.25,
                text: "second",
                isWavFormat: true,
                unprocessedText: "",
                speaker: nil
            ),
        ]

        try await store.storeAudioSegments(
            segments,
            for: audioKey,
            transcriptKey: transcriptKey
        )
        let cachedSegments = await store.audioSegments(
            for: audioKey,
            transcriptKey: transcriptKey
        )
        let rebuilt = try XCTUnwrap(cachedSegments)
        XCTAssertEqual(rebuilt.count, segments.count)
        for (actual, expected) in zip(rebuilt, segments) {
            XCTAssertEqual(actual.id, expected.id)
            XCTAssertEqual(actual.paragraphIndex, expected.paragraphIndex)
            XCTAssertEqual(actual.segmentIndex, expected.segmentIndex)
            XCTAssertEqual(actual.audioData, expected.audioData)
            XCTAssertEqual(actual.timestamps.map(\.word), expected.timestamps.map(\.word))
            XCTAssertEqual(actual.timestamps.map(\.startTime), expected.timestamps.map(\.startTime))
            XCTAssertEqual(actual.timestamps.map(\.endTime), expected.timestamps.map(\.endTime))
            XCTAssertEqual(actual.duration, expected.duration)
            XCTAssertEqual(actual.text, expected.text)
            XCTAssertEqual(actual.isWavFormat, expected.isWavFormat)
            XCTAssertEqual(actual.unprocessedText, expected.unprocessedText)
            XCTAssertEqual(actual.speaker, expected.speaker)
        }

        let firstPlayback = await store.cachedAudioPlayback(
            for: audioKey,
            transcriptKey: transcriptKey
        )
        XCTAssertEqual(firstPlayback?.isReplayEligible, false)
        try await store.markAudioReplayEligible(
            for: audioKey,
            transcriptKey: transcriptKey
        )

        let reopened = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let replay = await reopened.cachedAudioPlayback(
            for: audioKey,
            transcriptKey: transcriptKey
        )
        XCTAssertEqual(replay?.segments.map(\.text), segments.map(\.text))
        XCTAssertEqual(replay?.isReplayEligible, true)

        // A late generation-cache write racing the completion marker must not
        // turn an already-listened paragraph back into billable first audio.
        try await reopened.storeAudioSegments(
            segments,
            for: audioKey,
            transcriptKey: transcriptKey
        )
        let afterRewrite = await reopened.cachedAudioPlayback(
            for: audioKey,
            transcriptKey: transcriptKey
        )
        XCTAssertEqual(afterRewrite?.isReplayEligible, true)
    }

    func testNeverGeneratedAudioVariantIsACleanMissWithoutManifestMutation() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "fresh audio miss")
        let transcriptKey = YouTubeCacheStore.cacheKey(for: document)
        try await store.storeTranscript(document, for: transcriptKey)
        let beforeSummary = await store.summary(for: transcriptKey)
        let before = try XCTUnwrap(beforeSummary)

        clock.advance(30)
        let missingAudioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "voice-never-generated",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        let playback = await store.cachedAudioPlayback(
            for: missingAudioKey,
            transcriptKey: transcriptKey
        )
        let afterSummary = await store.summary(for: transcriptKey)
        let after = try XCTUnwrap(afterSummary)

        XCTAssertNil(playback)
        XCTAssertEqual(after, before)
    }

    func testParagraphScopedAudioKeysCannotOverwriteEachOther() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "two paragraphs")
        let transcriptKey = YouTubeCacheStore.cacheKey(for: document)
        let firstKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        let secondKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 1
        )
        let first = makeAudioSegment(paragraphIndex: 0, text: "first")
        let second = makeAudioSegment(paragraphIndex: 1, text: "second")

        XCTAssertNotEqual(firstKey.storageKey, secondKey.storageKey)
        try await store.storeAudioSegments(
            [first],
            for: firstKey,
            transcriptKey: transcriptKey
        )
        try await store.storeAudioSegments(
            [second],
            for: secondKey,
            transcriptKey: transcriptKey
        )

        let restoredFirst = await store.audioSegments(
            for: firstKey,
            transcriptKey: transcriptKey
        )
        let restoredSecond = await store.audioSegments(
            for: secondKey,
            transcriptKey: transcriptKey
        )
        XCTAssertEqual(restoredFirst?.map(\.text), ["first"])
        XCTAssertEqual(restoredSecond?.map(\.text), ["second"])
    }

    func testVoiceFingerprintAndSchemaChangesInvalidateAudio() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "version one")
        let transcriptKey = YouTubeCacheStore.cacheKey(for: document)
        let storedKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: 1
        )
        try await store.storeAudioSegments(
            [makeAudioSegment()],
            for: storedKey,
            transcriptKey: transcriptKey
        )

        let otherVoice = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "am_adam",
            playbackLanguage: "en",
            schemaVersion: 1
        )
        let otherSchema = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: 2
        )
        let otherVoiceSegments = await store.audioSegments(
            for: otherVoice,
            transcriptKey: transcriptKey
        )
        let otherSchemaSegments = await store.audioSegments(
            for: otherSchema,
            transcriptKey: transcriptKey
        )
        XCTAssertNil(otherVoiceSegments)
        XCTAssertNil(otherSchemaSegments)

        let changedDocument = makeDocument(videoId: "aaaaaaaaaaa", text: "version two")
        let changedTranscriptKey = YouTubeCacheStore.cacheKey(for: changedDocument)
        let changedFingerprintAudio = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: changedTranscriptKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: 1
        )
        let changedFingerprintSegments = await store.audioSegments(
            for: changedFingerprintAudio,
            transcriptKey: changedTranscriptKey
        )
        XCTAssertNil(changedFingerprintSegments)
    }

    func testPlaybackLanguageIsCanonicalAndSeparatesSharedVoiceAudio() {
        let fingerprint = String(repeating: "a", count: 64)
        let englishUS = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: fingerprint,
            voiceCode: "shared_cloned_voice",
            playbackLanguage: "en-US",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        let englishGB = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: fingerprint,
            voiceCode: "shared_cloned_voice",
            playbackLanguage: " EN_gb ",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        let chinese = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: fingerprint,
            voiceCode: "shared_cloned_voice",
            playbackLanguage: "zh-Hans",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )

        XCTAssertEqual(englishUS.playbackLanguage, "en")
        XCTAssertEqual(englishGB.playbackLanguage, "en")
        XCTAssertEqual(chinese.playbackLanguage, "zh")
        XCTAssertEqual(englishUS.storageKey, englishGB.storageKey)
        XCTAssertNotEqual(englishUS.storageKey, chinese.storageKey)
        XCTAssertEqual(YouTubeTTSAudioCacheSchema.current, 4)
    }

    func testProgressRoundTripAndAccessTimeTouch() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "progress")
        let key = YouTubeCacheStore.cacheKey(for: document)
        try await store.storeTranscript(document, for: key)
        let summaryBeforeHit = await store.summary(for: key)
        let beforeHit = try XCTUnwrap(summaryBeforeHit).lastAccessAt

        clock.advance(30)
        _ = await store.transcript(for: key)
        let summaryAfterHit = await store.summary(for: key)
        let afterHit = try XCTUnwrap(summaryAfterHit).lastAccessAt
        XCTAssertEqual(afterHit.timeIntervalSince(beforeHit), 30, accuracy: 0.001)

        clock.advance(10)
        let saved = try await store.saveProgress(
            paragraphIndex: 4,
            segmentId: "4-2",
            segmentIndex: 2,
            fractionalProgress: 0.625,
            paragraphFractionalProgress: 0.8125,
            for: key
        )
        let restored = await store.progress(for: key)
        XCTAssertEqual(restored, saved)
        XCTAssertEqual(restored?.paragraphIndex, 4)
        XCTAssertEqual(restored?.segmentId, "4-2")
        XCTAssertEqual(restored?.segmentIndex, 2)
        XCTAssertEqual(restored?.fractionalProgress, 0.625)
        XCTAssertEqual(restored?.paragraphFractionalProgress, 0.8125)
        XCTAssertEqual(restored?.resolvedParagraphFractionalProgress, 0.8125)
    }

    func testOfflineTranscriptSelectionPrefersBaseLanguageThenEnglish() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let videoID = "aaaaaaaaaaa"

        let english = makeDocument(
            videoId: videoID,
            text: "English",
            trackLanguage: "en-US"
        )
        try await store.storeTranscript(english, for: YouTubeCacheStore.cacheKey(for: english))
        clock.advance(10)
        let chinese = makeDocument(
            videoId: videoID,
            text: "中文",
            trackLanguage: "zh-Hans"
        )
        try await store.storeTranscript(chinese, for: YouTubeCacheStore.cacheKey(for: chinese))
        clock.advance(10)
        let french = makeDocument(
            videoId: videoID,
            text: "Français",
            trackLanguage: "fr"
        )
        try await store.storeTranscript(french, for: YouTubeCacheStore.cacheKey(for: french))

        let regionalChinese = await store.mostRecentPreferredKey(
            videoId: videoID,
            preferredLanguage: "zh-CN"
        )
        let germanFallback = await store.mostRecentPreferredKey(
            videoId: videoID,
            preferredLanguage: "de-DE"
        )
        XCTAssertEqual(regionalChinese?.trackLanguage, "zh-hans")
        XCTAssertNil(germanFallback)
        let newest = await store.mostRecentKey(videoId: videoID)
        XCTAssertEqual(newest?.trackLanguage, "fr")
    }

    func testPreferredSelectionSkipsCorruptManualTrackAndUsesValidASR() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let videoID = "aaaaaaaaaaa"
        let automatic = makeDocument(
            videoId: videoID,
            text: "automatic captions",
            trackLanguage: "en-US",
            trackKind: "asr"
        )
        let automaticKey = YouTubeCacheStore.cacheKey(for: automatic)
        try await store.storeTranscript(automatic, for: automaticKey)

        clock.advance(10)
        let manual = makeDocument(
            videoId: videoID,
            text: "manual captions",
            trackLanguage: "en-GB"
        )
        let manualKey = YouTubeCacheStore.cacheKey(for: manual)
        try await store.storeTranscript(manual, for: manualKey)
        let manualURL = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(manualKey.storageKey)
            .appendingPathComponent("transcript.json")
        try Data("corrupt".utf8).write(to: manualURL, options: .atomic)

        let selected = await store.mostRecentPreferredKey(
            videoId: videoID,
            preferredLanguage: "en-AU"
        )
        XCTAssertEqual(selected, automaticKey)
        let resolved = await store.mostRecentPreferredTranscript(
            videoId: videoID,
            preferredLanguage: "en-AU"
        )
        XCTAssertEqual(resolved?.key, automaticKey)
        XCTAssertEqual(resolved?.document, automatic)
        let newestValid = await store.mostRecentKey(videoId: videoID)
        XCTAssertEqual(newestValid, automaticKey)
        let corruptSummary = await store.summary(for: manualKey)
        XCTAssertEqual(corruptSummary?.hasTranscript, false)
    }

    func testResolvedTranscriptLookupReturnsDecodedDocumentAndTouchesSelection() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let videoID = "aaaaaaaaaaa"
        let english = makeDocument(
            videoId: videoID,
            text: "English transcript",
            trackLanguage: "en-US"
        )
        let englishKey = YouTubeCacheStore.cacheKey(for: english)
        try await store.storeTranscript(english, for: englishKey)

        clock.advance(10)
        let french = makeDocument(
            videoId: videoID,
            text: "Transcription française",
            trackLanguage: "fr"
        )
        let frenchKey = YouTubeCacheStore.cacheKey(for: french)
        try await store.storeTranscript(french, for: frenchKey)

        clock.advance(10)
        let resolved = await store.mostRecentPreferredTranscript(
            videoId: videoID,
            preferredLanguage: "en-AU"
        )
        XCTAssertEqual(resolved?.key, englishKey)
        XCTAssertEqual(resolved?.document, english)

        // The selected entry becomes the newest playback candidate without a
        // second transcript decode through `transcript(for:)`.
        let newest = await store.mostRecentKey(videoId: videoID)
        XCTAssertEqual(newest, englishKey)
    }

    func testTranscriptBridgeWithCollapsedTimelineIsRejectedBeforeCaching() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let videoID = "aaaaaaaaaaa"
        let base = makeDocument(videoId: videoID, text: "fixture")
        let collapsed = YouTubeTranscriptDocument(
            metadata: base.metadata,
            track: YouTubeCaptionTrack(
                baseURL: "transcript-bridge:\(videoID):en",
                languageCode: "en"
            ),
            cues: [
                YouTubeTranscriptCue(text: "0:011 secondMusic", startMs: 0),
                YouTubeTranscriptCue(text: "0:1818 secondsCaption", startMs: 0),
            ],
            extractedAt: base.extractedAt
        )
        let key = YouTubeCacheStore.cacheKey(for: collapsed)

        do {
            try await store.storeTranscript(collapsed, for: key)
            XCTFail("Expected a collapsed transcript-panel timeline to be rejected")
        } catch let error as YouTubeCacheError {
            XCTAssertEqual(error, .keyMismatch)
        }
    }

    func testDecodedStoryboardWithInvalidGeometrySelfHealsAsCorrupt() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let base = makeDocument(videoId: "aaaaaaaaaaa", text: "valid captions")
        let storyboard = try XCTUnwrap(
            YouTubeStoryboardParser.parse(
                "https://i.ytimg.com/sb/aaaaaaaaaaa/storyboard3_L$L/$N.jpg" +
                "|160#90#10#5#2#10000"
            )
        )
        let document = YouTubeTranscriptDocument(
            metadata: base.metadata,
            track: base.track,
            cues: base.cues,
            paragraphs: base.paragraphs,
            storyboard: storyboard,
            extractedAt: base.extractedAt,
            selectedForLanguage: base.selectedForLanguage
        )
        let key = YouTubeCacheStore.cacheKey(for: document)
        try await store.storeTranscript(document, for: key)

        let transcriptURL = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(key.storageKey)
            .appendingPathComponent("transcript.json")
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: transcriptURL))
                as? [String: Any]
        )
        var corruptStoryboard = try XCTUnwrap(object["storyboard"] as? [String: Any])
        corruptStoryboard["columns"] = 0
        corruptStoryboard["intervalMs"] = 0
        object["storyboard"] = corruptStoryboard
        try JSONSerialization.data(withJSONObject: object)
            .write(to: transcriptURL, options: .atomic)

        let loadedTranscript = await store.transcript(for: key)
        let loadedSummary = await store.summary(for: key)
        XCTAssertNil(loadedTranscript)
        XCTAssertEqual(loadedSummary?.hasTranscript, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: transcriptURL.path))
    }

    func testPreferredSelectionReusesExplicitCrossLanguageFallback() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let videoID = "aaaaaaaaaaa"
        let englishFallback = makeDocument(
            videoId: videoID,
            text: "English fallback",
            trackLanguage: "en",
            selectedForLanguage: "zh-Hans"
        )
        let key = YouTubeCacheStore.cacheKey(for: englishFallback)
        try await store.storeTranscript(englishFallback, for: key)

        let repeatedChinese = await store.mostRecentPreferredKey(
            videoId: videoID,
            preferredLanguage: "zh-CN"
        )
        let firstJapaneseOpen = await store.mostRecentPreferredKey(
            videoId: videoID,
            preferredLanguage: "ja-JP"
        )

        XCTAssertEqual(repeatedChinese, key)
        XCTAssertNil(firstJapaneseOpen)
    }

    func testHistoryPeekDoesNotChangeLRUAccessTime() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "peek")
        let key = YouTubeCacheStore.cacheKey(for: document)
        try await store.storeTranscript(document, for: key)
        let thumbnail = makeStillImageData()
        try await store.storeThumbnail(thumbnail, for: key)
        try await store.saveProgress(
            paragraphIndex: 0,
            segmentId: "segment",
            segmentIndex: 0,
            fractionalProgress: 0.5,
            for: key
        )
        let beforeSummary = await store.summary(for: key)
        let before = try XCTUnwrap(beforeSummary).lastAccessAt
        clock.advance(60)

        let peekedTranscript = await store.peekTranscript(for: key)
        let peekedProgress = await store.peekProgress(for: key)
        let peekedThumbnail = await store.peekThumbnail(videoId: "aaaaaaaaaaa")
        XCTAssertEqual(peekedTranscript, document)
        XCTAssertEqual(peekedProgress?.fractionalProgress, 0.5)
        XCTAssertEqual(peekedThumbnail, thumbnail)

        let afterSummary = await store.summary(for: key)
        let after = try XCTUnwrap(afterSummary).lastAccessAt
        XCTAssertEqual(after, before)
    }

    func testExactTrackSelectionFallsBackFromNewestCorruptFingerprint() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let videoID = "aaaaaaaaaaa"
        let older = makeDocument(videoId: videoID, text: "older transcript")
        let olderKey = YouTubeCacheStore.cacheKey(for: older)
        try await store.storeTranscript(older, for: olderKey)

        clock.advance(10)
        let newer = makeDocument(videoId: videoID, text: "newer transcript")
        let newerKey = YouTubeCacheStore.cacheKey(for: newer)
        try await store.storeTranscript(newer, for: newerKey)
        let newerURL = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(newerKey.storageKey)
            .appendingPathComponent("transcript.json")
        try Data("corrupt".utf8).write(to: newerURL, options: .atomic)

        let selected = await store.mostRecentKey(
            videoId: videoID,
            trackLanguage: older.track.languageCode,
            trackIdentity: YouTubeCacheStore.selectedTrackIdentity(older.track)
        )
        XCTAssertEqual(selected, olderKey)
    }

    func testAudioCoverageDistinguishesNonePartialCompleteAndCorruption() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "coverage")
        let transcriptKey = YouTubeCacheStore.cacheKey(for: document)
        try await store.storeTranscript(document, for: transcriptKey)

        let none = await store.audioCacheCoverage(
            for: transcriptKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0, 1]
        )
        XCTAssertEqual(none, .none(totalParagraphs: 2))

        let firstKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        try await store.storeAudioSegments(
            [makeAudioSegment(paragraphIndex: 0, text: "first")],
            for: firstKey,
            transcriptKey: transcriptKey
        )
        let partial = await store.audioCacheCoverage(
            for: transcriptKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0, 1]
        )
        XCTAssertEqual(
            partial,
            .partial(cachedParagraphs: 1, totalParagraphs: 2)
        )

        let secondKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 1
        )
        try await store.storeAudioSegments(
            [makeAudioSegment(paragraphIndex: 1, text: "second")],
            for: secondKey,
            transcriptKey: transcriptKey
        )
        let complete = await store.audioCacheCoverage(
            for: transcriptKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0, 1]
        )
        XCTAssertEqual(complete, .complete(totalParagraphs: 2))

        let secondAudioURL = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(transcriptKey.storageKey)
            .appendingPathComponent("audio")
            .appendingPathComponent(secondKey.storageKey)
            .appendingPathComponent("segment-000000.mp3")
        try Data().write(to: secondAudioURL, options: .atomic)
        let afterCorruption = await store.audioCacheCoverage(
            for: transcriptKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0, 1]
        )
        XCTAssertEqual(
            afterCorruption,
            .partial(cachedParagraphs: 1, totalParagraphs: 2)
        )
        let summaryAfterCorruption = await store.summary(for: transcriptKey)
        XCTAssertEqual(summaryAfterCorruption?.audioVariantCount, 1)
    }

    func testOfflineCoverageRequiresStoryboardSheetsAndHDThumbnailAfterAudioCompletes() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let base = makeDocument(videoId: "aaaaaaaaaaa", text: "storyboard offline")
        let storyboard = try XCTUnwrap(
            YouTubeStoryboardParser.parse(
                "https://i.ytimg.com/sb/aaaaaaaaaaa/storyboard3_L$L/$N.jpg" +
                "|160#90#5#2#2#10000"
            )
        )
        XCTAssertEqual(storyboard.sheetCount, 2)
        let document = YouTubeTranscriptDocument(
            metadata: base.metadata,
            track: base.track,
            cues: base.cues,
            paragraphs: base.paragraphs,
            storyboard: storyboard,
            extractedAt: base.extractedAt
        )
        let transcriptKey = YouTubeCacheStore.cacheKey(for: document)
        try await store.storeTranscript(document, for: transcriptKey)
        let audioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: transcriptKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        try await store.storeAudioSegments(
            [makeAudioSegment()],
            for: audioKey,
            transcriptKey: transcriptKey
        )

        let audioOnly = await store.offlineCacheCoverage(
            for: transcriptKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertTrue(audioOnly.audio.isComplete)
        XCTAssertFalse(audioOnly.isComplete)
        XCTAssertEqual(audioOnly.cachedArtworkResourceCount, 0)
        XCTAssertEqual(audioOnly.requiredArtworkResourceCount, 3)
        let initiallyMissing = await store.missingStoryboardSheetIndexes(
            for: storyboard,
            cacheKey: transcriptKey
        )
        XCTAssertEqual(initiallyMissing, [0, 1])

        do {
            try await store.storeStoryboardSheet(
                makeStillImageData(width: 1, height: 1),
                sheetIndex: 0,
                for: transcriptKey
            )
            XCTFail("Expected an undersized storyboard sheet to be rejected")
        } catch let error as YouTubeCacheError {
            XCTAssertEqual(error, .invalidImageResource)
        }

        try await store.storeStoryboardSheet(
            makeStillImageData(width: 320, height: 180, marker: 1),
            sheetIndex: 0,
            for: transcriptKey
        )
        // An unexpected manifest index cannot make the expected two-sheet
        // storyboard look complete.
        do {
            try await store.storeStoryboardSheet(
                makeStillImageData(marker: 9),
                sheetIndex: 99,
                for: transcriptKey
            )
            XCTFail("Expected an out-of-range storyboard sheet to be rejected")
        } catch let error as YouTubeCacheError {
            XCTAssertEqual(error, .invalidKey)
        }
        let oneMissing = await store.missingStoryboardSheetIndexes(
            for: storyboard,
            cacheKey: transcriptKey
        )
        XCTAssertEqual(oneMissing, [1], "a failed fetch remains retryable")
        let partial = await store.offlineCacheCoverage(
            for: transcriptKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertFalse(partial.isComplete)
        XCTAssertEqual(partial.cachedArtworkResourceCount, 1)

        try await store.storeStoryboardSheet(
            makeStillImageData(width: 160, height: 90, marker: 2),
            sheetIndex: 1,
            for: transcriptKey
        )
        let sheetsComplete = await store.offlineCacheCoverage(
            for: transcriptKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertFalse(sheetsComplete.isComplete)
        XCTAssertEqual(sheetsComplete.cachedArtworkResourceCount, 2)

        try await store.storeThumbnail(
            makeStillImageData(width: 1280, height: 720, marker: 3),
            for: transcriptKey
        )
        let withThumbnail = await store.offlineCacheCoverage(
            for: transcriptKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertTrue(withThumbnail.isComplete)
        XCTAssertEqual(withThumbnail.cachedArtworkResourceCount, 3)

        let secondSheetURL = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(transcriptKey.storageKey)
            .appendingPathComponent("storyboard")
            .appendingPathComponent("sheet-000001.bin")
        try FileManager.default.removeItem(at: secondSheetURL)
        let afterDiskLoss = await store.offlineCacheCoverage(
            for: transcriptKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertFalse(afterDiskLoss.isComplete)
        XCTAssertEqual(afterDiskLoss.cachedArtworkResourceCount, 2)
        let missingAfterDiskLoss = await store.missingStoryboardSheetIndexes(
            for: storyboard,
            cacheKey: transcriptKey
        )
        XCTAssertEqual(missingAfterDiskLoss, [1])
    }

    func testOfflineCoverageUsesThumbnailOnlyWhenStaticArtworkWasDeclared() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)

        let withThumbnail = makeDocument(
            videoId: "aaaaaaaaaaa",
            text: "static artwork"
        )
        let withThumbnailKey = YouTubeCacheStore.cacheKey(for: withThumbnail)
        try await store.storeTranscript(withThumbnail, for: withThumbnailKey)
        let withThumbnailAudioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: withThumbnailKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        try await store.storeAudioSegments(
            [makeAudioSegment()],
            for: withThumbnailAudioKey,
            transcriptKey: withThumbnailKey
        )
        let beforeThumbnail = await store.offlineCacheCoverage(
            for: withThumbnailKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertFalse(beforeThumbnail.isComplete)
        XCTAssertEqual(beforeThumbnail.requiredArtworkResourceCount, 1)
        try await store.storeThumbnail(makeStillImageData(), for: withThumbnailKey)
        let afterThumbnail = await store.offlineCacheCoverage(
            for: withThumbnailKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertTrue(afterThumbnail.isComplete)

        let baseWithoutThumbnail = makeDocument(
            videoId: "bbbbbbbbbbb",
            text: "native placeholder"
        )
        let withoutThumbnail = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: baseWithoutThumbnail.metadata.videoId,
                title: baseWithoutThumbnail.metadata.title,
                channelName: baseWithoutThumbnail.metadata.channelName,
                sourceURL: baseWithoutThumbnail.metadata.sourceURL,
                thumbnailURL: nil,
                durationMs: baseWithoutThumbnail.metadata.durationMs
            ),
            track: baseWithoutThumbnail.track,
            cues: baseWithoutThumbnail.cues,
            paragraphs: baseWithoutThumbnail.paragraphs,
            extractedAt: baseWithoutThumbnail.extractedAt
        )
        let withoutThumbnailKey = YouTubeCacheStore.cacheKey(for: withoutThumbnail)
        try await store.storeTranscript(withoutThumbnail, for: withoutThumbnailKey)
        let withoutThumbnailAudioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: withoutThumbnailKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        try await store.storeAudioSegments(
            [makeAudioSegment()],
            for: withoutThumbnailAudioKey,
            transcriptKey: withoutThumbnailKey
        )
        let placeholderCoverage = await store.offlineCacheCoverage(
            for: withoutThumbnailKey,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertTrue(placeholderCoverage.isComplete)
        XCTAssertEqual(placeholderCoverage.requiredArtworkResourceCount, 0)
    }

    func testThumbnailAndStoryboardSheetsRoundTrip() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let key = YouTubeCacheStore.cacheKey(
            for: makeDocument(videoId: "aaaaaaaaaaa", text: "images")
        )
        let thumbnail = makeStillImageData(marker: 1)
        let sheet = makeStillImageData(marker: 9)

        try await store.storeThumbnail(thumbnail, for: key)
        try await store.storeStoryboardSheet(sheet, sheetIndex: 3, for: key)
        let restoredThumbnail = await store.thumbnail(for: key)
        let restoredSheet = await store.storyboardSheet(sheetIndex: 3, for: key)
        let missingSheet = await store.storyboardSheet(sheetIndex: 2, for: key)
        XCTAssertEqual(restoredThumbnail, thumbnail)
        XCTAssertEqual(restoredSheet, sheet)
        XCTAssertNil(missingSheet)

        let optionalSummary = await store.summary(for: key)
        let summary = try XCTUnwrap(optionalSummary)
        XCTAssertTrue(summary.hasThumbnail)
        XCTAssertEqual(summary.storyboardSheetCount, 1)
    }

    func testInvalidAndCorruptArtworkCannotReportOfflineComplete() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "image integrity")
        let key = YouTubeCacheStore.cacheKey(for: document)
        try await store.storeTranscript(document, for: key)
        let audioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: key.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        try await store.storeAudioSegments(
            [makeAudioSegment()],
            for: audioKey,
            transcriptKey: key
        )

        do {
            try await store.storeThumbnail(Data("<html>not an image</html>".utf8), for: key)
            XCTFail("Expected invalid image bytes to be rejected")
        } catch let error as YouTubeCacheError {
            XCTAssertEqual(error, .invalidImageResource)
        }

        try await store.storeThumbnail(makeStillImageData(), for: key)
        let complete = await store.offlineCacheCoverage(
            for: key,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertTrue(complete.isComplete)

        let thumbnailURL = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(key.storageKey)
            .appendingPathComponent("thumbnail.bin")
        try Data("still not an image".utf8).write(to: thumbnailURL, options: .atomic)

        let afterCorruption = await store.offlineCacheCoverage(
            for: key,
            voiceCode: "af_heart",
            paragraphIndexes: [0]
        )
        XCTAssertFalse(afterCorruption.isComplete)
        XCTAssertEqual(afterCorruption.cachedArtworkResourceCount, 0)
        let corruptThumbnail = await store.thumbnail(for: key)
        let healedSummary = await store.summary(for: key)
        XCTAssertNil(corruptThumbnail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: thumbnailURL.path))
        XCTAssertEqual(healedSummary?.hasThumbnail, false)
    }

    func testCorruptAndMissingFilesFailOpenAndSelfHeal() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "corruption")
        let key = YouTubeCacheStore.cacheKey(for: document)
        try await store.storeTranscript(document, for: key)
        let transcriptURL = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(key.storageKey)
            .appendingPathComponent("transcript.json")
        try Data("not-json".utf8).write(to: transcriptURL, options: .atomic)

        let firstCorruptRead = await store.transcript(for: key)
        let secondCorruptRead = await store.transcript(for: key)
        let summaryAfterTranscriptCorruption = await store.summary(for: key)
        XCTAssertNil(firstCorruptRead)
        XCTAssertNil(secondCorruptRead)
        XCTAssertEqual(summaryAfterTranscriptCorruption?.hasTranscript, false)

        let audioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: key.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: 1
        )
        try await store.storeAudioSegments(
            [makeAudioSegment()],
            for: audioKey,
            transcriptKey: key
        )
        let audioDirectory = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(key.storageKey)
            .appendingPathComponent("audio")
            .appendingPathComponent(audioKey.storageKey)
        try FileManager.default.removeItem(
            at: audioDirectory.appendingPathComponent("segment-000000.mp3")
        )
        let corruptAudioRead = await store.audioSegments(
            for: audioKey,
            transcriptKey: key
        )
        let summaryAfterAudioCorruption = await store.summary(for: key)
        XCTAssertNil(corruptAudioRead)
        XCTAssertEqual(summaryAfterAudioCorruption?.audioVariantCount, 0)
    }

    func testCorruptManifestStartsWithEmptyCache() async throws {
        let fixture = try makeFixture()
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "manifest")
        let key = YouTubeCacheStore.cacheKey(for: document)
        let first = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        try await first.storeTranscript(document, for: key)
        let oldEntryDirectory = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(key.storageKey)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldEntryDirectory.path))
        try Data("broken-manifest".utf8).write(
            to: fixture.cacheRoot.appendingPathComponent("manifest.json"),
            options: .atomic
        )

        let reopened = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldEntryDirectory.path))
        try await reopened.performStartupMaintenance()
        let recoveredTranscript = await reopened.transcript(for: key)
        let recoveredStats = await reopened.stats()
        XCTAssertNil(recoveredTranscript)
        XCTAssertEqual(recoveredStats.entryCount, 0)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: oldEntryDirectory.path),
            "untracked payloads must not escape the physical cache limit"
        )
    }

    func testSemanticManifestByteOverflowIsSaturatedAndSelfHeals() async throws {
        let fixture = try makeFixture()
        let firstDocument = makeDocument(videoId: "aaaaaaaaaaa", text: "first")
        let secondDocument = makeDocument(videoId: "bbbbbbbbbbb", text: "second")
        let firstKey = YouTubeCacheStore.cacheKey(for: firstDocument)
        let secondKey = YouTubeCacheStore.cacheKey(for: secondDocument)
        let initial = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        try await initial.storeTranscript(firstDocument, for: firstKey)
        try await initial.storeTranscript(secondDocument, for: secondKey)

        let manifestURL = fixture.cacheRoot.appendingPathComponent("manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        var root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
        )
        var entries = try XCTUnwrap(root["entries"] as? [String: Any])
        for storageKey in [firstKey.storageKey, secondKey.storageKey] {
            var entry = try XCTUnwrap(entries[storageKey] as? [String: Any])
            entry["byteSize"] = NSNumber(value: Int64.max)
            entries[storageKey] = entry
        }
        root["entries"] = entries
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
            .write(to: manifestURL, options: .atomic)

        let reopened = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        // A normal hot-path mutation previously trapped while summing the two
        // attacker-sized persisted values before delayed maintenance ran.
        try await reopened.storeTranscript(firstDocument, for: firstKey)
        try await reopened.performStartupMaintenance()
        let stats = await reopened.stats()
        XCTAssertLessThanOrEqual(stats.totalBytes, YouTubeCacheLimits.production.maxBytes)
    }

    func testStartupRemovesCrashLeftAudioStagingDirectory() async throws {
        let fixture = try makeFixture()
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "staging")
        let key = YouTubeCacheStore.cacheKey(for: document)
        let first = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        try await first.storeTranscript(document, for: key)
        let staging = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(key.storageKey)
            .appendingPathComponent("audio")
            .appendingPathComponent("staging-interrupted")
        try FileManager.default.createDirectory(
            at: staging,
            withIntermediateDirectories: true
        )
        try Data(repeating: 1, count: 128).write(
            to: staging.appendingPathComponent("partial.mp3")
        )

        let reopened = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: staging.path),
            "construction must not recursively inspect the cache on its caller"
        )
        try await reopened.performStartupMaintenance()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testStartupReconcilesPhysicalBytesBeforePruning() async throws {
        let fixture = try makeFixture()
        let limits = YouTubeCacheLimits(maxVideoCount: 10, maxBytes: 1_000)
        let document = makeDocument(videoId: "aaaaaaaaaaa", text: "startup bytes")
        let key = YouTubeCacheStore.cacheKey(for: document)
        let first = try YouTubeCacheStore(
            rootDirectory: fixture.cacheRoot,
            limits: limits
        )
        try await first.storeThumbnail(
            makeStillImageData(minimumByteCount: 400, marker: 1),
            for: key
        )

        let entryDirectory = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(key.storageKey)
        try Data(repeating: 2, count: 800).write(
            to: entryDirectory.appendingPathComponent("crash-left-resource.bin")
        )

        let reopened = try YouTubeCacheStore(
            rootDirectory: fixture.cacheRoot,
            limits: limits
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: entryDirectory.path),
            "construction must leave exact byte reconciliation to actor maintenance"
        )
        try await reopened.performStartupMaintenance()
        let reconciledSummary = await reopened.summary(for: key)
        XCTAssertNil(
            reconciledSummary,
            "startup must count on-disk bytes before enforcing the physical limit"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDirectory.path))
    }

    func testSteadyStateMutationDoesNotRescanMatureCacheUntilManualPrune() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(
            rootDirectory: fixture.cacheRoot,
            limits: YouTubeCacheLimits(maxVideoCount: 10, maxBytes: 2_000),
            clock: clock
        )
        let first = makeDocument(videoId: "aaaaaaaaaaa", text: "older")
        let firstKey = YouTubeCacheStore.cacheKey(for: first)
        try await store.storeThumbnail(
            makeStillImageData(minimumByteCount: 400, marker: 1),
            for: firstKey
        )
        let initialFirstSummary = await store.summary(for: firstKey)
        let recordedFirstBytes = try XCTUnwrap(initialFirstSummary).byteSize

        let firstEntryDirectory = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(firstKey.storageKey)
        try Data(repeating: 3, count: 800).write(
            to: firstEntryDirectory.appendingPathComponent("externally-added.bin")
        )

        clock.advance(10)
        let second = makeDocument(videoId: "bbbbbbbbbbb", text: "newer")
        let secondKey = YouTubeCacheStore.cacheKey(for: second)
        try await store.storeThumbnail(
            makeStillImageData(minimumByteCount: 400, marker: 2),
            for: secondKey
        )

        let firstBeforeMaintenance = await store.summary(for: firstKey)
        let secondBeforeMaintenance = await store.summary(for: secondKey)
        XCTAssertEqual(
            firstBeforeMaintenance?.byteSize,
            recordedFirstBytes,
            "a normal write must not recursively inspect unrelated mature entries"
        )
        XCTAssertNotNil(secondBeforeMaintenance)

        try await store.pruneNow()
        let firstAfterMaintenance = await store.summary(for: firstKey)
        let secondAfterMaintenance = await store.summary(for: secondKey)
        XCTAssertNil(
            firstAfterMaintenance,
            "explicit maintenance must reconcile bytes and evict the older video"
        )
        XCTAssertNotNil(secondAfterMaintenance)
    }

    func testIncrementalByteAccountingStaysExactAcrossResourceAndAudioReplacement() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let original = makeDocument(videoId: "aaaaaaaaaaa", text: "byte accounting")
        let key = YouTubeCacheStore.cacheKey(for: original)
        try await store.storeTranscript(original, for: key)

        let rewritten = makeDocument(
            videoId: "aaaaaaaaaaa",
            text: "byte accounting",
            selectedForLanguage: "zh-Hans"
        )
        XCTAssertEqual(YouTubeCacheStore.cacheKey(for: rewritten), key)
        try await store.storeTranscript(rewritten, for: key)
        try await store.storeThumbnail(
            makeStillImageData(minimumByteCount: 128, marker: 4),
            for: key
        )
        try await store.storeThumbnail(
            makeStillImageData(minimumByteCount: 384, marker: 5),
            for: key
        )

        let audioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: key.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        try await store.storeAudioSegments(
            [makeAudioSegment(paragraphIndex: 0, text: "small", audioByteCount: 32)],
            for: audioKey,
            transcriptKey: key
        )
        try await store.storeAudioSegments(
            [makeAudioSegment(paragraphIndex: 0, text: "larger", audioByteCount: 512)],
            for: audioKey,
            transcriptKey: key
        )
        try await store.markAudioReplayEligible(
            for: audioKey,
            transcriptKey: key
        )

        let entryDirectory = fixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(key.storageKey)
        let physicalBytes = recursiveFileByteSize(in: entryDirectory)
        let summary = await store.summary(for: key)
        XCTAssertEqual(summary?.byteSize, physicalBytes)
    }

    func testLRUEvictsOldestVideoAtItemLimit() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(
            rootDirectory: fixture.cacheRoot,
            limits: YouTubeCacheLimits(maxVideoCount: 1, maxBytes: 1_000_000),
            clock: clock
        )
        let firstDocument = makeDocument(videoId: "aaaaaaaaaaa", text: "first")
        let firstKey = YouTubeCacheStore.cacheKey(for: firstDocument)
        try await store.storeTranscript(firstDocument, for: firstKey)

        clock.advance(10)
        let secondDocument = makeDocument(videoId: "bbbbbbbbbbb", text: "second")
        let secondKey = YouTubeCacheStore.cacheKey(for: secondDocument)
        try await store.storeTranscript(secondDocument, for: secondKey)

        let evictedTranscript = await store.transcript(for: firstKey)
        let retainedTranscript = await store.transcript(for: secondKey)
        let stats = await store.stats()
        XCTAssertNil(evictedTranscript)
        XCTAssertEqual(retainedTranscript, secondDocument)
        XCTAssertEqual(stats.videoCount, 1)
    }

    func testLRUEvictsOldestVideoAtByteLimit() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(
            rootDirectory: fixture.cacheRoot,
            limits: YouTubeCacheLimits(maxVideoCount: 10, maxBytes: 1_500),
            clock: clock
        )
        let firstKey = YouTubeCacheStore.cacheKey(
            for: makeDocument(videoId: "aaaaaaaaaaa", text: "first")
        )
        let secondKey = YouTubeCacheStore.cacheKey(
            for: makeDocument(videoId: "bbbbbbbbbbb", text: "second")
        )
        let firstThumbnail = makeStillImageData(minimumByteCount: 900, marker: 1)
        try await store.storeThumbnail(firstThumbnail, for: firstKey)
        clock.advance(10)
        let secondThumbnail = makeStillImageData(minimumByteCount: 900, marker: 2)
        try await store.storeThumbnail(secondThumbnail, for: secondKey)

        let evictedThumbnail = await store.thumbnail(for: firstKey)
        let retainedThumbnail = await store.thumbnail(for: secondKey)
        XCTAssertNil(evictedThumbnail)
        XCTAssertEqual(retainedThumbnail, secondThumbnail)
        let stats = await store.stats()
        XCTAssertLessThanOrEqual(stats.totalBytes, 1_500)
        XCTAssertEqual(stats.videoCount, 1)
    }

    func testOpaquePathsAndSymlinkContainmentProtectOutsideRoot() async throws {
        let fixture = try makeFixture()
        let document = makeDocument(
            videoId: "secretVID01",
            text: "private transcript sentence",
            trackName: "Private Track Name"
        )
        let key = YouTubeCacheStore.cacheKey(for: document)
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        try await store.storeTranscript(document, for: key)
        let audioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: key.transcriptFingerprint,
            voiceCode: "secret_voice_code",
            playbackLanguage: "en",
            schemaVersion: 1
        )
        try await store.storeAudioSegments(
            [makeAudioSegment()],
            for: audioKey,
            transcriptKey: key
        )

        let allNames = recursiveRelativePaths(in: fixture.cacheRoot)
        for path in allNames {
            XCTAssertFalse(path.contains("secretVID01"), path)
            XCTAssertFalse(path.contains("private transcript"), path)
            XCTAssertFalse(path.contains("Private Track"), path)
            XCTAssertFalse(path.contains("secret_voice_code"), path)
            XCTAssertFalse(path.contains("youtube.com"), path)
        }

        let guardedFixture = try makeFixture()
        let guardedStore = try YouTubeCacheStore(rootDirectory: guardedFixture.cacheRoot)
        let guardedDocument = makeDocument(videoId: "ccccccccccc", text: "guarded")
        let guardedKey = YouTubeCacheStore.cacheKey(for: guardedDocument)
        let outsideSentinel = guardedFixture.containerRoot
            .appendingPathComponent("outside")
            .appendingPathComponent("sentinel.txt")
        try FileManager.default.createDirectory(
            at: outsideSentinel.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: outsideSentinel)
        let maliciousEntry = guardedFixture.cacheRoot
            .appendingPathComponent("entries")
            .appendingPathComponent(guardedKey.storageKey)
        try FileManager.default.createSymbolicLink(
            at: maliciousEntry,
            withDestinationURL: outsideSentinel.deletingLastPathComponent()
        )

        do {
            try await guardedStore.storeTranscript(guardedDocument, for: guardedKey)
            XCTFail("Expected symlink escape to be rejected")
        } catch let error as YouTubeCacheError {
            XCTAssertEqual(error, .unsafePath)
        }
        XCTAssertEqual(try Data(contentsOf: outsideSentinel), Data("keep".utf8))
    }

    func testInvalidProgressAndOversizedResourceAreRejected() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(
            rootDirectory: fixture.cacheRoot,
            limits: YouTubeCacheLimits(maxVideoCount: 2, maxBytes: 32)
        )
        let key = YouTubeCacheStore.cacheKey(
            for: makeDocument(videoId: "aaaaaaaaaaa", text: "limits")
        )
        do {
            _ = try await store.saveProgress(
                paragraphIndex: -1,
                segmentId: "",
                segmentIndex: -1,
                fractionalProgress: .nan,
                for: key
            )
            XCTFail("Expected invalid progress")
        } catch let error as YouTubeCacheError {
            XCTAssertEqual(error, .invalidProgress)
        }
        do {
            try await store.storeThumbnail(Data(repeating: 1, count: 33), for: key)
            XCTFail("Expected oversized resource")
        } catch let error as YouTubeCacheError {
            XCTAssertEqual(error, .resourceTooLarge)
        }
    }

    // MARK: Fixtures

    private struct Fixture {
        let containerRoot: URL
        let cacheRoot: URL
    }

    private func makeFixture() throws -> Fixture {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-cache-tests-\(UUID().uuidString)", isDirectory: true)
        let cache = container.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: container)
        }
        return Fixture(containerRoot: container, cacheRoot: cache)
    }

    // MARK: Caption language availability

    func testCaptionLanguageAvailabilityReportsPerLanguageOfflineState() async throws {
        let fixture = try makeFixture()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot)
        let videoId = "aaaaaaaaaaa"

        let english = makeDocument(videoId: videoId, text: "hello world", trackLanguage: "en")
        let englishKey = YouTubeCacheStore.cacheKey(for: english)
        try await store.storeTranscript(english, for: englishKey)
        // German transcript only: switching to it is instant, but it cannot be
        // listened to offline yet.
        let german = makeDocument(
            videoId: videoId,
            text: "hallo welt",
            trackName: "Deutsch",
            trackLanguage: "de"
        )
        try await store.storeTranscript(german, for: YouTubeCacheStore.cacheKey(for: german))

        let englishAudioKey = YouTubeTTSAudioCacheKey(
            transcriptFingerprint: englishKey.transcriptFingerprint,
            voiceCode: "af_heart",
            playbackLanguage: "en",
            schemaVersion: YouTubeTTSAudioCacheSchema.current,
            paragraphIndex: 0
        )
        try await store.storeAudioSegments(
            [makeAudioSegment()],
            for: englishAudioKey,
            transcriptKey: englishKey
        )

        let availability = await store.captionLanguageAvailability(
            videoId: videoId,
            voiceCodeByLanguage: ["en": "af_heart", "de": "df_voice"]
        )

        XCTAssertEqual(availability["en"]?.hasTranscript, true)
        XCTAssertEqual(availability["en"]?.isFullyDownloaded, true)
        XCTAssertEqual(availability["de"]?.hasTranscript, true)
        XCTAssertEqual(
            availability["de"]?.isFullyDownloaded,
            false,
            "a transcript without its audio is instant to switch to, not offline-ready"
        )
        XCTAssertNil(availability["ja"], "languages never cached must not appear")
    }

    func testCaptionLanguageAvailabilityDoesNotDisturbEvictionOrder() async throws {
        let fixture = try makeFixture()
        let clock = YouTubeCacheTestClock()
        let store = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let videoId = "aaaaaaaaaaa"
        let document = makeDocument(videoId: videoId, text: "hello world")
        let key = YouTubeCacheStore.cacheKey(for: document)
        try await store.storeTranscript(document, for: key)

        clock.advance(3_600)
        _ = await store.captionLanguageAvailability(
            videoId: videoId,
            voiceCodeByLanguage: ["en": "af_heart"]
        )

        // Opening the picker must not look like usage: it would otherwise
        // reorder LRU eviction across every language of every video.
        let reopened = try YouTubeCacheStore(rootDirectory: fixture.cacheRoot, clock: clock)
        let stillPreferred = await reopened.mostRecentPreferredKey(
            videoId: videoId,
            preferredLanguage: "en"
        )
        XCTAssertEqual(stillPreferred, key)
        let lastAccessAt = await reopened.lastAccessAtForTesting(key)
        XCTAssertEqual(lastAccessAt, Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func makeDocument(
        videoId: String,
        text: String,
        trackName: String = "English",
        trackLanguage: String = "en",
        trackKind: String? = nil,
        selectedForLanguage: String? = nil
    ) -> YouTubeTranscriptDocument {
        let cue = YouTubeTranscriptCue(text: text, startMs: 1_000, durationMs: 2_000)
        return YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: videoId,
                title: "Video title",
                channelName: "Channel",
                sourceURL: "https://www.youtube.com/watch?v=\(videoId)",
                thumbnailURL: "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
                durationMs: 60_000
            ),
            track: YouTubeCaptionTrack(
                baseURL: "https://www.youtube.com/api/timedtext?v=\(videoId)&lang=\(trackLanguage)",
                languageCode: trackLanguage,
                name: trackName,
                kind: trackKind
            ),
            cues: [cue],
            extractedAt: Date(timeIntervalSince1970: 1_700_000_000),
            selectedForLanguage: selectedForLanguage
        )
    }

    private func makeAudioSegment(
        paragraphIndex: Int = 0,
        text: String = "cached",
        audioByteCount: Int = 4
    ) -> AudioSegment {
        AudioSegment(
            paragraphIndex: paragraphIndex,
            segmentIndex: 0,
            audioData: Data(repeating: 0x49, count: audioByteCount),
            timestamps: [TTSTimestamp(word: text, startTime: 0, endTime: 0.5)],
            duration: 0.5,
            text: text,
            isWavFormat: false,
            unprocessedText: "",
            speaker: nil
        )
    }

    /// A valid JPEG with optional trailing padding. JPEG decoders ignore bytes
    /// after EOI, which lets byte-accounting tests keep exact payload sizes
    /// without treating arbitrary bytes as cached artwork.
    private func makeStillImageData(
        width: Int = 1,
        height: Int = 1,
        minimumByteCount: Int = 0,
        marker: UInt8 = 0
    ) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: width, height: height),
            format: format
        ).image { context in
            UIColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1).setFill()
            context.fill(
                CGRect(x: 0, y: 0, width: width, height: height)
            )
        }
        var data = image.jpegData(compressionQuality: 0.8)!
        if data.count < minimumByteCount {
            data.append(
                Data(repeating: marker, count: minimumByteCount - data.count)
            )
        } else if marker != 0 {
            data.append(marker)
        }
        return data
    }

    private func recursiveRelativePaths(in root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            return String(url.path.dropFirst(root.path.count))
        }
    }

    private func recursiveFileByteSize(in root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        return enumerator.reduce(into: Int64(0)) { total, item in
            guard let url = item as? URL,
                  let values = try? url.resourceValues(
                      forKeys: [.isRegularFileKey, .fileSizeKey]
                  ),
                  values.isRegularFile == true,
                  let size = values.fileSize else { return }
            total += Int64(size)
        }
    }
}
