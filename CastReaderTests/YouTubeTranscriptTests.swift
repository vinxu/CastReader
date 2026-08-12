import CoreGraphics
import Foundation
import XCTest
@testable import CastReader

final class YouTubeURLParserTests: XCTestCase {
    private let videoId = "dQw4w9WgXcQ"

    func testParsesEverySupportedPlanShape() {
        let cases: [(String, Int?)] = [
            ("https://www.youtube.com/watch?v=\(videoId)", nil),
            ("youtube.com/watch?v=\(videoId)", nil),
            ("https://m.youtube.com/watch?v=\(videoId)", nil),
            ("https://youtu.be/\(videoId)", nil),
            ("https://www.youtube.com/shorts/\(videoId)", nil),
            ("https://youtu.be/\(videoId)?t=123", 123),
            ("https://youtu.be/\(videoId)?t=123s", 123),
            ("https://www.youtube.com/shorts/\(videoId)?t=1m30s", 90),
            ("https://www.youtube.com/watch?v=\(videoId)#t=1h2m3s", 3_723),
            ("https://www.youtube.com/watch?v=\(videoId)#90", 90),
            ("https://www.youtube.com/watch?v=\(videoId)#1m30s", 90),
        ]

        for (url, expectedStart) in cases {
            let parsed = YouTubeURLParser.parse(url)
            XCTAssertEqual(parsed?.videoId, videoId, url)
            XCTAssertEqual(parsed?.startSeconds, expectedStart, url)
        }
    }

    func testPlaylistUsesCurrentVideoParameter() {
        let parsed = YouTubeURLParser.parse(
            "https://www.youtube.com/watch?list=PL123&index=7&v=\(videoId)&t=45s"
        )
        XCTAssertEqual(parsed, YouTubeVideoReference(videoId: videoId, startSeconds: 45))
    }

    func testQueryTimeTakesPrecedenceOverHash() {
        let parsed = YouTubeURLParser.parse(
            "https://www.youtube.com/watch?v=\(videoId)&t=30s#t=1m30s"
        )
        XCTAssertEqual(parsed?.startSeconds, 30)
    }

    func testCanonicalURLIsDeterministic() {
        let parsed = YouTubeVideoReference(videoId: videoId, startSeconds: 90)
        XCTAssertEqual(
            parsed.canonicalURLString,
            "https://www.youtube.com/watch?v=\(videoId)&t=90s"
        )
        XCTAssertEqual(parsed.canonicalURL?.host, "www.youtube.com")
    }

    func testReportedMobileURLDropsReferralParametersWithoutChangingVideo() {
        let parsed = YouTubeURLParser.parse(
            "https://m.youtube.com/watch?v=wpb-DrbhEiY&pp=iggCQAE%3D&ra=m"
        )

        XCTAssertEqual(parsed?.videoId, "wpb-DrbhEiY")
        XCTAssertNil(parsed?.startSeconds)
        XCTAssertEqual(
            parsed?.canonicalURLString,
            "https://www.youtube.com/watch?v=wpb-DrbhEiY"
        )
    }

    func testRejectsMaliciousAndUnsupportedHosts() {
        let rejected = [
            "https://youtube.com.evil.example/watch?v=\(videoId)",
            "https://notyoutube.com/watch?v=\(videoId)",
            "https://evil.example/?next=https://youtube.com/watch?v=\(videoId)",
            "https://youtube.com@evil.example/watch?v=\(videoId)",
            "https://music.youtube.com/watch?v=\(videoId)",
            "https://www.youtube-nocookie.com/watch?v=\(videoId)",
        ]
        for url in rejected {
            XCTAssertNil(YouTubeURLParser.parse(url), url)
        }
    }

    func testRejectsAmbiguousMalformedAndNonVideoURLs() {
        let rejected = [
            "ftp://www.youtube.com/watch?v=\(videoId)",
            "https://www.youtube.com:443/watch?v=\(videoId)",
            "https://user:pass@www.youtube.com/watch?v=\(videoId)",
            "https://www.youtube.com/playlist?list=PL123",
            "https://www.youtube.com/watch?list=PL123",
            "https://www.youtube.com/watch?v=tooShort",
            "https://youtu.be/\(videoId)/extra",
            "https://www.youtube.com/shorts/\(videoId)/extra",
            "https://www.youtube.com/watch?v=\(videoId)&v=aaaaaaaaaaa",
            "https://www.youtube.com/watch?v=\(videoId)&t=tomorrow",
            "https://www.youtube.com/watch?v=\(videoId)#t=1s30m",
            "https://www.youtube.com/watch?v=\(videoId)&t=-1",
            "https://www.youtube.com/watch?v=\(videoId)&t=1.5",
        ]
        for url in rejected {
            XCTAssertNil(YouTubeURLParser.parse(url), url)
        }
    }

    func testUnrelatedHashDoesNotInvalidateVideo() {
        let parsed = YouTubeURLParser.parse(
            "https://www.youtube.com/watch?v=\(videoId)#comments"
        )
        XCTAssertEqual(parsed, YouTubeVideoReference(videoId: videoId, startSeconds: nil))
    }
}

final class YouTubeTranscriptGroupingTests: XCTestCase {
    func testSortsAndBreaksOnlyWhenGapIsStrictlyGreaterThanTwoSeconds() {
        let cues = [
            YouTubeTranscriptCue(text: "third", startMs: 7_001, durationMs: 100),
            YouTubeTranscriptCue(text: "first", startMs: 0, durationMs: 1_000),
            YouTubeTranscriptCue(text: "second", startMs: 3_000, durationMs: 2_000),
        ]
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs(cues)

        XCTAssertEqual(result.map(\.id), [0, 1])
        XCTAssertEqual(result.map(\.startMs), [0, 7_001])
        XCTAssertEqual(result.map(\.text), ["first second", "third"])
        // first→second gap is exactly 2000ms, so it must not break.
    }

    func testDurationControlsGapRatherThanPreviousStart() {
        let cues = [
            YouTubeTranscriptCue(text: "one", startMs: 0, durationMs: 5_000),
            YouTubeTranscriptCue(text: "two", startMs: 6_500, durationMs: 0),
        ]
        XCTAssertEqual(
            YouTubeTranscriptGrouper.cuesIntoParagraphs(cues).map(\.text),
            ["one two"]
        )
    }

    func testExtremeCueDurationCannotOverflowGrouping() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "extreme",
                startMs: Int.max - 10,
                durationMs: Int.max
            ),
        ])
        XCTAssertEqual(result.map(\.text), ["extreme"])
        XCTAssertEqual(result.first?.startMs, Int.max - 10)
    }

    func testLengthCheckOccursBeforeAppendingNextCue() {
        let exactly150 = String(repeating: "a", count: 150)
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: exactly150, startMs: 0),
            YouTubeTranscriptCue(text: "b", startMs: 100),
            YouTubeTranscriptCue(text: "c", startMs: 200),
        ])

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, "\(exactly150) b")
        XCTAssertEqual(result[1].text, "c")
        XCTAssertEqual(result[1].startMs, 200)
    }

    func testUsesJavaScriptCompatibleUTF16Length() {
        let emoji = String(repeating: "😀", count: 76) // 152 UTF-16 code units
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: emoji, startMs: 0),
            YouTubeTranscriptCue(text: "next", startMs: 100),
        ])
        XCTAssertEqual(result.map(\.text), [emoji, "next"])
    }

    func testNormalizesNewlinesDropsEmptyCuesAndKeepsStableEqualTimeOrder() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "  ", startMs: 0),
            YouTubeTranscriptCue(text: "alpha\nbeta", startMs: 100),
            YouTubeTranscriptCue(text: "gamma", startMs: 100),
        ])
        XCTAssertEqual(result, [
            YouTubeTranscriptParagraph(id: 0, text: "alpha beta gamma", startMs: 100),
        ])
    }
}

final class YouTubeTrackTests: XCTestCase {
    func testDecodesYouTubeSimpleTextAndRunsNames() throws {
        let simple = Data(#"{"baseUrl":"https://captions.example/a","languageCode":"en","name":{"simpleText":"English"}}"#.utf8)
        let runs = Data(#"{"baseUrl":"https://captions.example/b","languageCode":"ja","name":{"runs":[{"text":"日本"},{"text":"語"}]},"kind":"asr"}"#.utf8)

        let decoder = JSONDecoder()
        XCTAssertEqual(try decoder.decode(YouTubeCaptionTrack.self, from: simple).name, "English")
        let automatic = try decoder.decode(YouTubeCaptionTrack.self, from: runs)
        XCTAssertEqual(automatic.name, "日本語")
        XCTAssertTrue(automatic.isAutomatic)
    }

    func testTrackSelectionMatchesExtensionPriority() {
        let tracks = [
            YouTubeCaptionTrack(baseURL: "es-auto", languageCode: "es", kind: "asr"),
            YouTubeCaptionTrack(baseURL: "en-manual", languageCode: "en-US"),
            YouTubeCaptionTrack(baseURL: "es-manual", languageCode: "es-ES"),
        ]
        XCTAssertEqual(
            YouTubeTrackSelector.selectBest(from: tracks, preferredLanguage: "es")?.baseURL,
            "es-manual"
        )
        XCTAssertEqual(
            YouTubeTrackSelector.selectBest(from: tracks, preferredLanguage: "es-MX")?.baseURL,
            "es-manual"
        )
        XCTAssertEqual(
            YouTubeTrackSelector.selectBest(from: tracks, preferredLanguage: "ja")?.baseURL,
            "en-manual"
        )
    }
}

final class YouTubeStoryboardTests: XCTestCase {
    private let template = "https://i.ytimg.com/sb/video/storyboard3_L$L/$N.jpg"

    func testSelectsL2AndMapsFramesAcrossSheets() throws {
        let spec = template
            + "|48#27#100#10#10#5000#L0#sig0"
            + "|160#90#25#5#5#10000#L1#sig1"
            + "|320#180#51#5#5#10000#L2#sig2"
        let storyboard = try XCTUnwrap(YouTubeStoryboardParser.parse(spec))

        XCTAssertEqual(storyboard.level, 2)
        XCTAssertEqual(storyboard.tileWidth, 320)
        XCTAssertEqual(storyboard.sheetCount, 3)
        XCTAssertEqual(storyboard.sheetURLString(for: 1),
                       "https://i.ytimg.com/sb/video/storyboard3_L2/1.jpg?sigh=sig2")

        XCTAssertEqual(storyboard.frame(atMs: 0),
                       YouTubeStoryboardFrame(sheetIndex: 0,
                                              cropRect: CGRect(x: 0, y: 0, width: 320, height: 180)))
        XCTAssertEqual(storyboard.frame(atMs: 240_000),
                       YouTubeStoryboardFrame(sheetIndex: 0,
                                              cropRect: CGRect(x: 1_280, y: 720, width: 320, height: 180)))
        XCTAssertEqual(storyboard.frame(atMs: 250_000),
                       YouTubeStoryboardFrame(sheetIndex: 1,
                                              cropRect: CGRect(x: 0, y: 0, width: 320, height: 180)))
        XCTAssertEqual(storyboard.frame(atMs: Int.max)?.sheetIndex, 2)
    }

    func testSelectsClearestSafeLevelWhenL3IsAvailable() throws {
        let spec = template
            + "|48#27#100#10#10#5000#M$M#sig0"
            + "|160#90#50#5#5#10000#M$M#sig1"
            + "|320#180#51#5#5#10000#M$M#sig2"
            + "|640#360#51#3#3#10000#M$M#sig3"
        let storyboard = try XCTUnwrap(YouTubeStoryboardParser.parse(spec))

        XCTAssertEqual(storyboard.level, 3)
        XCTAssertEqual(storyboard.tileWidth, 640)
        XCTAssertEqual(storyboard.tileHeight, 360)
        XCTAssertEqual(
            storyboard.sheetURLString(for: 1),
            "https://i.ytimg.com/sb/video/storyboard3_L3/M1.jpg?sigh=sig3"
        )
    }

    func testResolutionWinsOverDescriptorNumber() throws {
        let spec = template
            + "|160#90#25#5#5#10000#M$M#sig0"
            + "|320#180#25#5#5#10000#M$M#sig1"
            + "|640#360#25#5#5#10000#M$M#sig2"
            + "|320#180#25#5#5#10000#M$M#sig3"
        XCTAssertEqual(YouTubeStoryboardParser.parse(spec)?.level, 2)
    }

    func testFallsBackFromMalformedL2ToL1() throws {
        let spec = template
            + "|48#27#100#10#10#5000"
            + "|160#90#25#5#5#10000"
            + "|320#180#51#5#5#0"
        XCTAssertEqual(YouTubeStoryboardParser.parse(spec)?.level, 1)
    }

    func testResolvesNameAndSignaturePlaceholderVariants() throws {
        let named = try XCTUnwrap(
            YouTubeStoryboardParser.parse(
                "https://i.ytimg.com/sb/video/storyboard3_L$L/$N.jpg?sigh=$S" +
                "|160#90#50#5#5#10000#M$M#signed_value"
            )
        )
        XCTAssertEqual(
            named.sheetURLString(for: 1),
            "https://i.ytimg.com/sb/video/storyboard3_L0/M1.jpg?sigh=signed_value"
        )

        let redundant = try XCTUnwrap(
            YouTubeStoryboardParser.parse(
                "https://i.ytimg.com/sb/video/storyboard3_L$L/M$N.jpg" +
                "|160#90#50#5#5#10000#M$M.jpg#sig"
            )
        )
        XCTAssertEqual(
            redundant.sheetURLString(for: 1),
            "https://i.ytimg.com/sb/video/storyboard3_L0/M1.jpg?sigh=sig"
        )
    }

    func testCurrentUnsignedTemplateAppendsDescriptorSigh() throws {
        // Current player responses put the signature in descriptor field 8,
        // while the base template has no `$S` placeholder. Without `sigh`,
        // YouTube answers the otherwise-correct sprite request with 403.
        let currentSpec =
            "https://i.ytimg.com/sb/dQw4w9WgXcQ/storyboard3_L$L/$N.jpg?sqp=fixture" +
            "|48#27#100#10#10#5000#M$M#rs$level0" +
            "|160#90#50#5#5#10000#M$M#rs$level1" +
            "|320#180#51#5#5#10000#M$M#rs$level2"
        let storyboard = try XCTUnwrap(
            YouTubeStoryboardParser.parse(currentSpec)
        )

        XCTAssertEqual(
            storyboard.sheetURLString(for: 0),
            "https://i.ytimg.com/sb/dQw4w9WgXcQ/storyboard3_L2/M0.jpg?sqp=fixture&sigh=rs$level2"
        )
    }

    func testFallsBackToClearestOtherValidLevel() throws {
        let spec = template
            + "|bad"
            + "|bad"
            + "|bad"
            + "|640#360#20#4#5#12000#L3"
        XCTAssertEqual(YouTubeStoryboardParser.parse(spec)?.level, 3)
    }

    func testRejectsMalformedOrUnsafeSpecs() {
        XCTAssertNil(YouTubeStoryboardParser.parse(""))
        XCTAssertNil(YouTubeStoryboardParser.parse("https://i.ytimg.com/no-placeholders|160#90#10#5#5#10000"))
        XCTAssertNil(YouTubeStoryboardParser.parse("http://i.ytimg.com/L$L/$N.jpg|160#90#10#5#5#10000"))
        XCTAssertNil(YouTubeStoryboardParser.parse("\(template)|160#90#10#5#5#0"))
        XCTAssertNil(YouTubeStoryboardParser.parse("\(template)|160#90#0#5#5#10000"))
        XCTAssertNil(
            YouTubeStoryboardParser.parse(
                "\(template)|160#90#10000000#1#1#10000"
            ),
            "page-provided specs must not create millions of cache resources"
        )
    }

    func testNegativeTimeClampsToFirstFrameAndInvalidSheetIsRejected() throws {
        let storyboard = try XCTUnwrap(
            YouTubeStoryboardParser.parse("\(template)|160#90#10#5#2#10000")
        )
        XCTAssertEqual(storyboard.frame(atMs: -1)?.sheetIndex, 0)
        XCTAssertEqual(storyboard.frame(atMs: -1)?.cropRect.origin, .zero)
        XCTAssertNil(storyboard.sheetURLString(for: -1))
        XCTAssertNil(storyboard.sheetURLString(for: storyboard.sheetCount))
    }

    func testDecodedInvalidGeometryFailsClosedWithoutArithmeticTrap() throws {
        let storyboard = YouTubeStoryboard(
            sheetURLTemplate: template,
            level: 1,
            tileWidth: 160,
            tileHeight: 90,
            columns: 0,
            rows: 5,
            intervalMs: 0,
            frameCount: 10,
            nameTemplate: nil,
            signature: nil
        )

        XCTAssertFalse(storyboard.isValid)
        XCTAssertEqual(storyboard.tilesPerSheet, 0)
        XCTAssertEqual(storyboard.sheetCount, 0)
        XCTAssertNil(storyboard.frame(atMs: Int.max))
        XCTAssertNil(storyboard.sheetURLString(for: 0))

        let oversized = YouTubeStoryboard(
            sheetURLTemplate: template,
            level: 1,
            tileWidth: 160,
            tileHeight: 90,
            columns: 1,
            rows: 1,
            intervalMs: 10_000,
            frameCount: YouTubeStoryboard.maximumSheetCount + 1,
            nameTemplate: nil,
            signature: nil
        )
        XCTAssertFalse(oversized.isValid)
        XCTAssertNil(oversized.frame(atMs: 0))
    }

    func testArtworkQualityPolicyAvoidsStretchingSmallFramesToRetinaWidth() throws {
        let lowResolution = try XCTUnwrap(
            YouTubeStoryboardParser.parse(
                "\(template)|160#90#25#5#5#10000"
            )
        )
        XCTAssertEqual(
            YouTubeArtworkQualityPolicy.presentation(
                storyboard: lowResolution,
                hasThumbnail: true,
                displayWidthPoints: 398,
                displayScale: 3
            ),
            .coverWithStoryboardInset
        )
        XCTAssertEqual(
            YouTubeArtworkQualityPolicy.presentation(
                storyboard: lowResolution,
                hasThumbnail: false,
                displayWidthPoints: 398,
                displayScale: 3
            ),
            .storyboardOnly
        )

        let retinaReady = try XCTUnwrap(
            YouTubeStoryboardParser.parse(
                "\(template)|1280#720#25#5#5#10000"
            )
        )
        XCTAssertEqual(
            YouTubeArtworkQualityPolicy.presentation(
                storyboard: retinaReady,
                hasThumbnail: true,
                displayWidthPoints: 398,
                displayScale: 3
            ),
            .storyboardFullWidth
        )
        XCTAssertEqual(
            YouTubeArtworkQualityPolicy.insetWidthPoints(
                tileWidth: 320,
                displayScale: 3
            ),
            120
        )
    }
}

final class YouTubeTranscriptModelTests: XCTestCase {
    func testDocumentBuildsParagraphsAndRoundTripsCodable() throws {
        let cues = [
            YouTubeTranscriptCue(text: "hello", startMs: 0, durationMs: 500),
            YouTubeTranscriptCue(text: "world", startMs: 700, durationMs: 500),
        ]
        let document = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: "dQw4w9WgXcQ",
                title: "Example",
                channelName: "Channel",
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                thumbnailURL: "https://i.ytimg.com/example.jpg",
                durationMs: 10_000
            ),
            track: YouTubeCaptionTrack(
                baseURL: "https://captions.example/track",
                languageCode: "en",
                name: "English"
            ),
            cues: cues,
            extractedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(document.paragraphs.map(\.text), ["hello world"])

        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(YouTubeTranscriptDocument.self, from: data)
        XCTAssertEqual(decoded, document)
        XCTAssertEqual(
            decoded.artworkSchemaVersion,
            YouTubeArtworkCacheSchema.current
        )

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "artworkSchemaVersion")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacy = try JSONDecoder().decode(
            YouTubeTranscriptDocument.self,
            from: legacyData
        )
        XCTAssertNil(
            legacy.artworkSchemaVersion,
            "old cache entries must trigger an artwork-only metadata refresh"
        )
    }

    func testFailureReasonsAreStableForAnalyticsAndUIRouting() {
        XCTAssertEqual(YouTubeTranscriptFailure.noCaptions.reason, "no_captions")
        XCTAssertEqual(YouTubeTranscriptFailure.live.reason, "live")
        XCTAssertEqual(YouTubeTranscriptFailure.restricted.reason, "restricted")
        XCTAssertEqual(YouTubeTranscriptFailure.unavailable.reason, "unavailable")
        XCTAssertEqual(YouTubeTranscriptFailure.captionAccess.reason, "caption_access")
        XCTAssertEqual(
            YouTubeTranscriptFailure.playerBootstrapFailed.reason,
            "player_bootstrap_failed"
        )
        XCTAssertEqual(
            YouTubeTranscriptFailure.youtubeAccessLimited.reason,
            "youtube_access_limited"
        )
        XCTAssertEqual(YouTubeTranscriptFailure.timeout.reason, "timeout")
        XCTAssertNotEqual(
            YouTubeTranscriptFailure.playerBootstrapFailed.errorDescription,
            YouTubeTranscriptFailure.restricted.errorDescription
        )
        XCTAssertNotEqual(
            YouTubeTranscriptFailure.playerBootstrapFailed.errorDescription,
            YouTubeTranscriptFailure.timeout.errorDescription
        )
        XCTAssertNotEqual(
            YouTubeTranscriptFailure.youtubeAccessLimited.errorDescription,
            YouTubeTranscriptFailure.restricted.errorDescription
        )
        XCTAssertNotEqual(
            YouTubeTranscriptFailure.youtubeAccessLimited.errorDescription,
            YouTubeTranscriptFailure.timeout.errorDescription
        )
        XCTAssertEqual(Set(YouTubeTranscriptFailure.allCases.map(\.reason)).count,
                       YouTubeTranscriptFailure.allCases.count)
    }
}

final class YouTubeParagraphProgressTests: XCTestCase {
    func testTwoSegmentParagraphProgressDoesNotResetAtSegmentBoundary() throws {
        let segments = [
            makeSegment(index: 0, duration: 10),
            makeSegment(index: 1, duration: 30),
        ]

        let firstHalf = try XCTUnwrap(
            YouTubeParagraphProgressContract.position(
                in: segments,
                currentSegmentID: segments[0].id,
                currentTime: 5,
                currentSegmentDuration: 10
            )
        )
        let firstComplete = try XCTUnwrap(
            YouTubeParagraphProgressContract.position(
                in: segments,
                currentSegmentID: segments[0].id,
                currentTime: 10,
                currentSegmentDuration: 10
            )
        )
        let secondStart = try XCTUnwrap(
            YouTubeParagraphProgressContract.position(
                in: segments,
                currentSegmentID: segments[1].id,
                currentTime: 0,
                currentSegmentDuration: 30
            )
        )
        let secondHalf = try XCTUnwrap(
            YouTubeParagraphProgressContract.position(
                in: segments,
                currentSegmentID: segments[1].id,
                currentTime: 15,
                currentSegmentDuration: 30
            )
        )

        XCTAssertEqual(firstHalf.segmentFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(firstHalf.paragraphFraction, 0.125, accuracy: 0.0001)
        XCTAssertEqual(firstComplete.segmentFraction, 0.98, accuracy: 0.0001)
        XCTAssertEqual(firstComplete.paragraphFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(secondStart.segmentFraction, 0, accuracy: 0.0001)
        XCTAssertEqual(secondStart.paragraphFraction, 0.25, accuracy: 0.0001)
        XCTAssertEqual(secondHalf.segmentFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(secondHalf.paragraphFraction, 0.625, accuracy: 0.0001)
    }

    func testLegacyProgressKeepsSegmentResumeFallback() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "paragraphIndex": 3,
            "segmentId": "3-1",
            "segmentIndex": 1,
            "fractionalProgress": 0.4,
            "updatedAt": 0,
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(YouTubePlaybackProgress.self, from: data)

        XCTAssertEqual(decoded.segmentId, "3-1")
        XCTAssertEqual(decoded.fractionalProgress, 0.4)
        XCTAssertNil(decoded.paragraphFractionalProgress)
        XCTAssertEqual(decoded.resolvedParagraphFractionalProgress, 0.4)
    }

    func testParagraphCompletionIsIndependentFromSegmentSeekFraction() {
        let transcript = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: "dQw4w9WgXcQ",
                title: "Progress",
                channelName: nil,
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                thumbnailURL: nil,
                durationMs: 2_000
            ),
            track: YouTubeCaptionTrack(baseURL: "track", languageCode: "en"),
            cues: [
                YouTubeTranscriptCue(text: "one", startMs: 0),
                YouTubeTranscriptCue(text: "two", startMs: 1_000),
            ],
            paragraphs: [
                YouTubeTranscriptParagraph(id: 0, text: "one", startMs: 0),
                YouTubeTranscriptParagraph(id: 1, text: "two", startMs: 1_000),
            ]
        )
        let progress = YouTubePlaybackProgress(
            paragraphIndex: 0,
            segmentId: "0-1",
            segmentIndex: 1,
            fractionalProgress: 0.25,
            paragraphFractionalProgress: 1,
            updatedAt: Date()
        )

        XCTAssertEqual(
            YouTubeReadingDocumentBuilder.resumingParagraph(
                in: transcript,
                progress: progress
            ),
            1
        )
        XCTAssertEqual(progress.segmentId, "0-1")
        XCTAssertEqual(progress.fractionalProgress, 0.25)
    }

    private func makeSegment(index: Int, duration: Double) -> AudioSegment {
        AudioSegment(
            paragraphIndex: 7,
            segmentIndex: index,
            audioData: Data(),
            timestamps: [],
            duration: duration,
            text: "segment \(index)"
        )
    }
}

final class YouTubePlaybackAcceptanceTests: XCTestCase {
    func testAudibleTickAndFirstListenDoNotDependOnCachePersistence() {
        XCTAssertTrue(
            YouTubePlaybackAcceptancePolicy.shouldConfirm(
                currentTime: 0.051,
                segmentID: "0-0",
                lastConfirmedSegmentID: ""
            )
        )
        XCTAssertFalse(
            YouTubePlaybackAcceptancePolicy.shouldConfirm(
                currentTime: 0.051,
                segmentID: "0-0",
                lastConfirmedSegmentID: "0-0"
            )
        )
        XCTAssertFalse(
            YouTubePlaybackAcceptancePolicy.shouldConfirm(
                currentTime: .infinity,
                segmentID: "0-0",
                lastConfirmedSegmentID: ""
            )
        )
        XCTAssertFalse(
            YouTubePlaybackAcceptancePolicy.didCompleteFirstListen(
                currentTime: 0.999
            )
        )
        XCTAssertTrue(
            YouTubePlaybackAcceptancePolicy.didCompleteFirstListen(
                currentTime: 1
            )
        )
    }

    func testOnlyDurableShareWaitsForItsMatchingReader() throws {
        let pendingID = UUID()
        let share = try XCTUnwrap(
            YouTubeListenRequest(
                rawURL: "https://youtu.be/dQw4w9WgXcQ",
                entry: .share,
                pendingItemID: pendingID
            )
        )
        let acceptance = try XCTUnwrap(
            YouTubeDurablePlaybackAcceptance(
                request: share,
                contentSessionKey: "youtube-track-a"
            )
        )
        XCTAssertTrue(acceptance.matches("youtube-track-a"))
        XCTAssertFalse(acceptance.matches("youtube-track-b"))

        let manual = try XCTUnwrap(
            YouTubeListenRequest(
                rawURL: "https://youtu.be/dQw4w9WgXcQ",
                entry: .paste
            )
        )
        XCTAssertNil(
            YouTubeDurablePlaybackAcceptance(
                request: manual,
                contentSessionKey: "youtube-track-a"
            )
        )

        let history = try XCTUnwrap(
            YouTubeListenRequest(
                rawURL: "https://youtu.be/dQw4w9WgXcQ",
                entry: .history,
                pendingItemID: UUID()
            )
        )
        XCTAssertNil(
            YouTubeDurablePlaybackAcceptance(
                request: history,
                contentSessionKey: "youtube-track-a"
            )
        )
    }
}

final class YouTubeReadingDocumentBuilderTests: XCTestCase {
    func testNonCatalogCaptionLanguageIsNeverRelabeledAsEnglish() {
        let transcript = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: "dQw4w9WgXcQ",
                title: "Korean captions",
                channelName: nil,
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                thumbnailURL: nil,
                durationMs: 1_000
            ),
            track: YouTubeCaptionTrack(baseURL: "track", languageCode: "ko-KR"),
            cues: [YouTubeTranscriptCue(text: "안녕하세요", startMs: 0)]
        )

        let document = YouTubeReadingDocumentBuilder.make(
            transcript: transcript,
            cacheHit: false
        )

        XCTAssertEqual(document.language, "ko")
        XCTAssertThrowsError(
            try YouTubeTranscriptLanguagePolicy.playbackLanguage(for: "ko-KR")
        ) { error in
            XCTAssertEqual(error as? YouTubeTranscriptFailure, .unsupportedLanguage)
        }
    }

    func testIdenticalCuesFromDifferentTracksCreateDifferentReaderSessions() {
        func transcript(language: String, baseURL: String) -> YouTubeTranscriptDocument {
            YouTubeTranscriptDocument(
                metadata: YouTubeVideoMetadata(
                    videoId: "dQw4w9WgXcQ",
                    title: "Track identity",
                    channelName: nil,
                    sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                    thumbnailURL: nil,
                    durationMs: 1_000
                ),
                track: YouTubeCaptionTrack(
                    baseURL: baseURL,
                    languageCode: language
                ),
                cues: [
                    YouTubeTranscriptCue(
                        text: "shared caption",
                        startMs: 0,
                        durationMs: 1_000
                    )
                ]
            )
        }

        let firstTrack = YouTubeReadingDocumentBuilder.make(
            transcript: transcript(language: "en", baseURL: "stable-track-a"),
            cacheHit: false
        )
        let secondTrack = YouTubeReadingDocumentBuilder.make(
            transcript: transcript(language: "en", baseURL: "stable-track-b"),
            cacheHit: false
        )

        XCTAssertNotEqual(firstTrack.contentSessionKey, secondTrack.contentSessionKey)
    }

    func testExtremeStartTimeSaturatesWithoutOverflow() {
        let transcript = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: "dQw4w9WgXcQ",
                title: "Overflow safety",
                channelName: nil,
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                thumbnailURL: nil,
                durationMs: nil
            ),
            track: YouTubeCaptionTrack(
                baseURL: "track",
                languageCode: "en"
            ),
            cues: [
                YouTubeTranscriptCue(text: "first", startMs: 0, durationMs: 1_000),
                YouTubeTranscriptCue(text: "last", startMs: 10_000, durationMs: 1_000),
            ]
        )

        XCTAssertEqual(
            YouTubeReadingDocumentBuilder.startingParagraph(
                in: transcript,
                startSeconds: Int.max
            ),
            transcript.paragraphs.last?.id
        )
    }

    func testPlaybackSkipsCaptionRowsWithNoSpeakableText() {
        let transcript = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: "dQw4w9WgXcQ",
                title: "Music intro",
                channelName: nil,
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                thumbnailURL: nil,
                durationMs: 30_000
            ),
            track: YouTubeCaptionTrack(baseURL: "track", languageCode: "en"),
            cues: [
                YouTubeTranscriptCue(text: "[♪♪♪]", startMs: 1_000),
                YouTubeTranscriptCue(text: "First spoken line", startMs: 18_000),
                YouTubeTranscriptCue(text: "♪", startMs: 27_000),
            ],
            paragraphs: [
                YouTubeTranscriptParagraph(id: 0, text: "[♪♪♪]", startMs: 1_000),
                YouTubeTranscriptParagraph(id: 1, text: "First spoken line", startMs: 18_000),
                YouTubeTranscriptParagraph(id: 2, text: "♪", startMs: 27_000),
            ]
        )

        XCTAssertEqual(
            YouTubeReadingDocumentBuilder.firstPlayableParagraph(in: transcript),
            1
        )
        XCTAssertEqual(
            YouTubeReadingDocumentBuilder.startingParagraph(
                in: transcript,
                startSeconds: nil
            ),
            1
        )
        XCTAssertEqual(
            YouTubeReadingDocumentBuilder.startingParagraph(
                in: transcript,
                startSeconds: 27
            ),
            1,
            "A trailing music-only cue should fall back to the nearest playable row"
        )

        let completedIntro = YouTubePlaybackProgress(
            paragraphIndex: 0,
            segmentId: "music",
            segmentIndex: 0,
            fractionalProgress: 1,
            updatedAt: Date()
        )
        XCTAssertEqual(
            YouTubeReadingDocumentBuilder.resumingParagraph(
                in: transcript,
                progress: completedIntro
            ),
            1
        )
    }

    func testMusicOnlyTranscriptHasNoPlayableParagraph() {
        let transcript = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: "dQw4w9WgXcQ",
                title: "Music only",
                channelName: nil,
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                thumbnailURL: nil,
                durationMs: 1_000
            ),
            track: YouTubeCaptionTrack(baseURL: "track", languageCode: "en"),
            cues: [YouTubeTranscriptCue(text: "[♪♪♪]", startMs: 0)]
        )

        XCTAssertNil(
            YouTubeReadingDocumentBuilder.firstPlayableParagraph(in: transcript)
        )
    }

    func testReturnToYouTubeBuildsAppAndWebFallbackURLsAtCurrentTime() {
        XCTAssertEqual(
            YouTubeLinkOpener.applicationURL(
                videoId: "dQw4w9WgXcQ",
                startMs: 91_999
            )?.absoluteString,
            "youtube://www.youtube.com/watch?v=dQw4w9WgXcQ&t=91s"
        )
        XCTAssertEqual(
            YouTubeLinkOpener.webURL(
                videoId: "dQw4w9WgXcQ",
                startMs: 91_999
            )?.absoluteString,
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=91s"
        )
        XCTAssertNil(
            YouTubeLinkOpener.applicationURL(videoId: "unsafe", startMs: -1)
        )
    }

    func testCompletedParagraphResumesAtNextAndCompletedDocumentRestarts() {
        let transcript = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: "dQw4w9WgXcQ",
                title: "Resume",
                channelName: nil,
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                thumbnailURL: nil,
                durationMs: 3_000
            ),
            track: YouTubeCaptionTrack(baseURL: "track", languageCode: "en"),
            cues: [
                YouTubeTranscriptCue(text: "one", startMs: 0, durationMs: 1_000),
                YouTubeTranscriptCue(text: "two", startMs: 2_000, durationMs: 1_000),
            ],
            paragraphs: [
                YouTubeTranscriptParagraph(id: 0, text: "one", startMs: 0),
                YouTubeTranscriptParagraph(id: 1, text: "two", startMs: 2_000),
            ]
        )
        let first = try! XCTUnwrap(transcript.paragraphs.first)
        let last = try! XCTUnwrap(transcript.paragraphs.last)
        let completedFirst = YouTubePlaybackProgress(
            paragraphIndex: first.id,
            segmentId: "first",
            segmentIndex: 0,
            fractionalProgress: 1,
            updatedAt: Date()
        )
        let completedLast = YouTubePlaybackProgress(
            paragraphIndex: last.id,
            segmentId: "last",
            segmentIndex: 0,
            fractionalProgress: 1,
            updatedAt: Date()
        )

        XCTAssertEqual(
            YouTubeReadingDocumentBuilder.resumingParagraph(
                in: transcript,
                progress: completedFirst
            ),
            last.id
        )
        XCTAssertEqual(
            YouTubeReadingDocumentBuilder.resumingParagraph(
                in: transcript,
                progress: completedLast
            ),
            first.id
        )
    }
}

@MainActor
final class YouTubeHistoryPersistenceTests: XCTestCase {
    func testHomeShelfIsEmptyWithoutRouteableYouTubeHistory() {
        let records = [
            makeHistoryRecord(
                videoID: "not-youtube",
                sourceKind: .text,
                sourceURL: nil,
                openedAt: 3
            ),
            makeHistoryRecord(
                videoID: "invalid-url",
                sourceURL: "https://example.com/watch?v=dQw4w9WgXcQ",
                openedAt: 2
            ),
        ]

        XCTAssertEqual(
            YouTubeHomeShelfContract.project(
                records: records,
                activeDocumentID: nil
            ),
            .empty
        )
    }

    func testHomeShelfSortsThenLimitsToThreeAndReportsMore() throws {
        let completedRecent = makeHistoryRecord(
            videoID: "AAAAAA00001",
            openedAt: 50,
            progress: 1
        )
        let untouchedRecent = makeHistoryRecord(
            videoID: "AAAAAA00002",
            openedAt: 40,
            progress: nil
        )
        let incompleteOlder = makeHistoryRecord(
            videoID: "AAAAAA00003",
            openedAt: 20,
            progress: 0.25
        )
        let incompleteNewest = makeHistoryRecord(
            videoID: "AAAAAA00004",
            openedAt: 30,
            progress: 0.75
        )

        let projection = YouTubeHomeShelfContract.project(
            records: [completedRecent, untouchedRecent, incompleteOlder, incompleteNewest],
            activeDocumentID: nil
        )
        guard case .content(let items, let hasMore) = projection else {
            return XCTFail("Expected a populated YouTube Home shelf")
        }

        XCTAssertEqual(
            items.map(\.id),
            [incompleteNewest.id, incompleteOlder.id, completedRecent.id]
        )
        XCTAssertTrue(hasMore)
    }

    func testHomeShelfKeepsCurrentYouTubeSessionFirstEvenWhenOldAndComplete() throws {
        let newestIncomplete = makeHistoryRecord(
            videoID: "AAAAAA00005",
            openedAt: 100,
            progress: 0.5
        )
        let active = makeHistoryRecord(
            videoID: "AAAAAA00006",
            openedAt: 1,
            progress: 1
        )

        let projection = YouTubeHomeShelfContract.project(
            records: [newestIncomplete, active],
            activeDocumentID: active.id
        )
        guard case .content(let items, let hasMore) = projection else {
            return XCTFail("Expected a populated YouTube Home shelf")
        }

        XCTAssertEqual(items.map(\.id), [active.id, newestIncomplete.id])
        XCTAssertFalse(hasMore)
    }

    func testHomeShelfCompletionBoundaryAndDuplicateIDsAreDeterministic() throws {
        let sameDate = Date(timeIntervalSince1970: 10)
        let zero = makeHistoryRecord(
            videoID: "AAAAAA00007",
            openedAt: sameDate.timeIntervalSince1970,
            progress: 0
        )
        let boundary = makeHistoryRecord(
            videoID: "AAAAAA00008",
            openedAt: sameDate.timeIntervalSince1970,
            progress: YouTubeHomeShelfContract.completionThreshold
        )
        let incomplete = makeHistoryRecord(
            videoID: "AAAAAA00009",
            openedAt: 1,
            progress: 0.01
        )
        let duplicate = makeHistoryRecord(
            videoID: "AAAAAA00009",
            openedAt: 0,
            progress: 0.02
        )

        let projection = YouTubeHomeShelfContract.project(
            records: [zero, boundary, incomplete, duplicate],
            activeDocumentID: nil,
            maximumItemCount: 10
        )
        guard case .content(let items, let hasMore) = projection else {
            return XCTFail("Expected a populated YouTube Home shelf")
        }

        XCTAssertEqual(items.map(\.id), [incomplete.id, zero.id, boundary.id])
        XCTAssertFalse(hasMore)
    }

    func testHistoryPresentationRefreshesWhenPlaybackSummaryChanges() {
        let now = Date(timeIntervalSince1970: 1_000)
        var record = HistoryRecord(
            id: "youtube-dQw4w9WgXcQ",
            title: "History",
            sourceKindRaw: ReadingSourceKind.youtube.rawValue,
            sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            language: "en",
            createdAt: now,
            lastOpenedAt: now,
            coverPath: nil,
            youtubeDurationMs: 10_000,
            youtubeProgressFraction: 0.1,
            youtubeResumeStartMs: 0
        )
        let initial = YouTubeHistoryRefreshIdentity.value(for: [record])

        record.youtubeProgressFraction = 0.6
        record.youtubeResumeStartMs = 6_000

        XCTAssertNotEqual(
            initial,
            YouTubeHistoryRefreshIdentity.value(for: [record])
        )
    }

    func testHistoryDoesNotDuplicateTranscriptOutsideBoundedCache() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("youtube-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let transcript = YouTubeTranscriptDocument(
            metadata: YouTubeVideoMetadata(
                videoId: "dQw4w9WgXcQ",
                title: "History",
                channelName: nil,
                sourceURL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
                thumbnailURL: nil,
                durationMs: 10_000
            ),
            track: YouTubeCaptionTrack(baseURL: "track", languageCode: "en"),
            cues: [YouTubeTranscriptCue(text: "caption", startMs: 0)]
        )
        let document = YouTubeReadingDocumentBuilder.make(
            transcript: transcript,
            cacheHit: false
        )
        let store = HistoryStore(directory: directory)

        let staleCover = directory.appendingPathComponent("\(document.id).cover.jpg")
        try Data(repeating: 1, count: 32).write(to: staleCover)

        store.record(document)
        store.updateYouTubeListeningSummary(
            documentID: document.id,
            durationMs: 10_000,
            resumeStartMs: 4_000,
            progressFraction: 0.4
        )
        let reloaded = HistoryStore(directory: directory)

        XCTAssertEqual(reloaded.records.first?.sourceKind, .youtube)
        XCTAssertEqual(reloaded.records.first?.youtubeDurationMs, 10_000)
        XCTAssertEqual(reloaded.records.first?.youtubeResumeStartMs, 4_000)
        XCTAssertEqual(reloaded.records.first?.youtubeProgressFraction, 0.4)
        XCTAssertNil(reloaded.records.first?.coverPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleCover.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory
                    .appendingPathComponent("\(document.id).payload")
                    .path
            )
        )
    }

    private func makeHistoryRecord(
        videoID: String,
        sourceKind: ReadingSourceKind = .youtube,
        sourceURL: String? = nil,
        openedAt: TimeInterval,
        progress: Double? = nil
    ) -> HistoryRecord {
        let date = Date(timeIntervalSince1970: openedAt)
        let resolvedURL: String?
        if let sourceURL {
            resolvedURL = sourceURL
        } else if sourceKind == .youtube {
            resolvedURL = "https://www.youtube.com/watch?v=\(videoID)"
        } else {
            resolvedURL = nil
        }
        return HistoryRecord(
            id: "youtube-\(videoID)",
            title: videoID,
            sourceKindRaw: sourceKind.rawValue,
            sourceURL: resolvedURL,
            language: "en",
            createdAt: date,
            lastOpenedAt: date,
            coverPath: nil,
            youtubeProgressFraction: progress
        )
    }
}
