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

private struct YouTubeCaptionSemanticGoldenContract: Decodable {
    let schemaVersion: Int
    let cases: [YouTubeCaptionSemanticGoldenCase]
}

private struct YouTubeCaptionSemanticGoldenCase: Decodable {
    let id: String
    let cues: [YouTubeTranscriptCue]
    let expectedParagraphs: [YouTubeTranscriptParagraph]
}

final class YouTubeTranscriptGroupingTests: XCTestCase {
    func testEnvironmentAndDeliveryLabelsStayVisibleButAreNotNarrated() {
        let cues = [
            YouTubeTranscriptCue(text: "[Music]", startMs: 0, durationMs: 500),
            YouTubeTranscriptCue(
                text: "(whispering) Keep quiet",
                startMs: 2_000,
                durationMs: 500
            ),
            YouTubeTranscriptCue(text: "【掌声】", startMs: 4_000, durationMs: 500),
        ]
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs(cues)

        XCTAssertEqual(result.map(\.text), ["[Music]", "(whispering) Keep quiet", "【掌声】"])
        XCTAssertEqual(result.map(\.resolvedSpeechText), ["", "Keep quiet", ""])
    }

    func testConsecutiveLeadingEventAndDeliveryLabelsAreRemovedFromSpeech() throws {
        let source = "(laughing) (whispering) Keep quiet"
        let paragraph = try XCTUnwrap(
            YouTubeTranscriptGrouper.cuesIntoParagraphs([
                YouTubeTranscriptCue(text: source, startMs: 0),
            ]).first
        )

        XCTAssertEqual(paragraph.text, source)
        XCTAssertEqual(paragraph.resolvedSpeechText, "Keep quiet")
    }

    func testEventBeforeSpeakerPrefixDoesNotLeakLabelOrRoleIntoSpeech() throws {
        for source in [
            "[Music] ALICE: Hello",
            ">> [Music] ALICE: Hello",
        ] {
            let paragraph = try XCTUnwrap(
                YouTubeTranscriptGrouper.cuesIntoParagraphs([
                    YouTubeTranscriptCue(text: source, startMs: 0),
                ]).first,
                source
            )
            XCTAssertEqual(paragraph.text, source)
            XCTAssertEqual(paragraph.resolvedSpeechText, "Hello", source)
            XCTAssertEqual(paragraph.speaker, "ALICE", source)
        }
    }

    func testCommonCombinedEventLabelsStayVisibleButAreNotNarrated() throws {
        for source in [
            "[upbeat music]",
            "[music playing]",
            "[laughter and applause]",
        ] {
            let paragraph = try XCTUnwrap(
                YouTubeTranscriptGrouper.cuesIntoParagraphs([
                    YouTubeTranscriptCue(text: source, startMs: 0),
                ]).first,
                source
            )
            XCTAssertEqual(paragraph.text, source)
            XCTAssertEqual(paragraph.resolvedSpeechText, "", source)
        }
    }

    func testInlineOrdinaryMusicAndManAnnotationsRemainSpokenWithoutSpeakerInference() throws {
        for source in [
            "I study (music) theory every day",
            "The word [man] appears in this example",
        ] {
            let paragraph = try XCTUnwrap(
                YouTubeTranscriptGrouper.cuesIntoParagraphs([
                    YouTubeTranscriptCue(text: source, startMs: 0),
                ]).first,
                source
            )

            XCTAssertEqual(paragraph.text, source, source)
            XCTAssertEqual(paragraph.resolvedSpeechText, source, source)
            XCTAssertNil(paragraph.speaker, source)
        }
    }

    func testLyricsKeepWordsWhileRemovingOnlyMusicNotesFromSpeech() throws {
        let paragraph = try XCTUnwrap(
            YouTubeTranscriptGrouper.cuesIntoParagraphs([
                YouTubeTranscriptCue(text: "♪ We are alive ♪", startMs: 0),
            ]).first
        )

        XCTAssertEqual(paragraph.text, "♪ We are alive ♪")
        XCTAssertEqual(paragraph.resolvedSpeechText, "We are alive")
    }

    func testExplicitSpeakerPrefixesAreExtracted() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: ">> ALICE: Hello there", startMs: 0),
            YouTubeTranscriptCue(text: ">> BOB：Hi", startMs: 500),
        ])

        XCTAssertEqual(result.map(\.text), [">> ALICE: Hello there", ">> BOB：Hi"])
        XCTAssertEqual(result.map(\.resolvedSpeechText), ["Hello there", "Hi"])
        XCTAssertEqual(result.map(\.speaker), ["ALICE", "BOB"])
    }

    func testRoleOnlyCueCarriesSpeakerIntoFollowingSpeech() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "[narrator]", startMs: 0, durationMs: 100),
            YouTubeTranscriptCue(text: "Welcome.", startMs: 100, durationMs: 500),
        ])

        XCTAssertEqual(result.map(\.text), ["[narrator]", "Welcome."])
        XCTAssertEqual(result.map(\.resolvedSpeechText), ["", "Welcome."])
        XCTAssertEqual(result.map(\.speaker), [nil, "narrator"])
    }

    func testSceneEventClearsActiveSpeaker() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: ">> ALICE: Hello", startMs: 0),
            YouTubeTranscriptCue(text: "[Music]", startMs: 100),
            YouTubeTranscriptCue(text: "A new scene", startMs: 200),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), ["Hello", "", "A new scene"])
        XCTAssertEqual(result.map(\.speaker), ["ALICE", nil, nil])
    }

    func testEventPlacementResetsInheritedSpeakerBeforeOrAfterAdjacentSpeech() {
        let leading = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: ">> ALICE: Hello", startMs: 0, durationMs: 500),
            YouTubeTranscriptCue(text: "[Music] A new scene", startMs: 1_000, durationMs: 500),
        ])
        XCTAssertEqual(leading.map(\.resolvedSpeechText), ["Hello", "A new scene"])
        XCTAssertEqual(leading.map(\.speaker), ["ALICE", nil])

        let trailing = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: ">> ALICE: Goodbye [Music]", startMs: 0, durationMs: 500),
            YouTubeTranscriptCue(text: "A new scene", startMs: 1_000, durationMs: 500),
        ])
        XCTAssertEqual(trailing.map(\.resolvedSpeechText), ["Goodbye", "A new scene"])
        XCTAssertEqual(trailing.map(\.speaker), ["ALICE", nil])

        let newExplicitTurn = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: ">> ALICE: Hello", startMs: 0, durationMs: 500),
            YouTubeTranscriptCue(text: "[Music] BOB: Welcome", startMs: 1_000, durationMs: 500),
        ])
        XCTAssertEqual(newExplicitTurn.map(\.resolvedSpeechText), ["Hello", "Welcome"])
        XCTAssertEqual(newExplicitTurn.map(\.speaker), ["ALICE", "BOB"])
    }

    func testOneOffLabelsURLsAndClockTextAreNotGuessedAsSpeakers() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "Alice: this appears once", startMs: 0),
            YouTubeTranscriptCue(text: "Note: keep this heading", startMs: 2_000),
            YouTubeTranscriptCue(text: "https://example.com/watch", startMs: 4_000),
            YouTubeTranscriptCue(text: "Meet at 10:30 tomorrow", startMs: 6_000),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), [
            "Alice: this appears once",
            "Note: keep this heading",
            "https://example.com/watch",
            "Meet at 10:30 tomorrow",
        ])
        XCTAssertTrue(result.allSatisfy { $0.speaker == nil })
    }

    func testHeadingsLanguagesAndAcronymsAreNotGuessedAsSpeakers() throws {
        for source in [
            "CHAPTER 1: Introduction",
            "C++: Basics",
            "API: request failed",
        ] {
            let paragraph = try XCTUnwrap(
                YouTubeTranscriptGrouper.cuesIntoParagraphs([
                    YouTubeTranscriptCue(text: source, startMs: 0),
                ]).first,
                source
            )
            XCTAssertEqual(paragraph.resolvedSpeechText, source)
            XCTAssertNil(paragraph.speaker, source)
        }
    }

    func testBreaksAtExactTwelveHundredMillisecondGap() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "first", startMs: 0),
            YouTubeTranscriptCue(text: "second", startMs: 1_199),
            YouTubeTranscriptCue(text: "third", startMs: 2_399),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), ["first second", "third"])
        XCTAssertEqual(result.map(\.startMs), [0, 2_399])
    }

    func testSentenceTerminalCreatesNaturalBoundaryWithoutTimeGap() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "A complete sentence.", startMs: 0, durationMs: 1_000),
            YouTubeTranscriptCue(text: "Next thought", startMs: 1_000),
        ])

        XCTAssertEqual(
            result.map(\.resolvedSpeechText),
            ["A complete sentence.", "Next thought"]
        )
    }

    func testStructuredSpeakerChangeCreatesBoundary() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "hello", startMs: 0, speaker: "Alice"),
            YouTubeTranscriptCue(text: "again", startMs: 300, speaker: "Alice"),
            YouTubeTranscriptCue(text: "response", startMs: 600, speaker: "Bob"),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), ["hello again", "response"])
        XCTAssertEqual(result.map(\.speaker), ["Alice", "Bob"])
    }

    func testRollingCaptionOverlapIsRemovedOnlyFromSpeech() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "today we are learning how to code",
                startMs: 0,
                durationMs: 2_000
            ),
            YouTubeTranscriptCue(
                text: "learning how to code with Swift",
                startMs: 1_500,
                durationMs: 2_000
            ),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(
            result[0].text,
            "today we are learning how to code learning how to code with Swift"
        )
        XCTAssertEqual(
            result[0].resolvedSpeechText,
            "today we are learning how to code with Swift"
        )
    }

    func testThreeRollingCaptionUpdatesDoNotReintroducePriorWords() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "today we are learning how to code",
                startMs: 0,
                durationMs: 2_000
            ),
            YouTubeTranscriptCue(
                text: "learning how to code with Swift",
                startMs: 1_500,
                durationMs: 2_000
            ),
            YouTubeTranscriptCue(
                text: "how to code with Swift safely",
                startMs: 2_500,
                durationMs: 2_000
            ),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(
            result[0].resolvedSpeechText,
            "today we are learning how to code with Swift safely"
        )
    }

    func testExactRollingDuplicateAdvancesTimeWindowBeforeFollowingUpdate() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "today we are learning how to code",
                startMs: 0,
                durationMs: 1_000
            ),
            YouTubeTranscriptCue(
                text: "today we are learning how to code",
                startMs: 1_000,
                durationMs: 1_000
            ),
            YouTubeTranscriptCue(
                text: "learning how to code with Swift",
                startMs: 2_000,
                durationMs: 1_000
            ),
        ])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(
            result[0].resolvedSpeechText,
            "today we are learning how to code with Swift"
        )
    }

    func testOverlappingDuplicateMultiSentenceCuesAreNarratedOnlyOnce() {
        let source = "Alpha sentence. Beta sentence."
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: source, startMs: 0, durationMs: 2_000),
            YouTubeTranscriptCue(text: source, startMs: 500, durationMs: 2_000),
        ])

        XCTAssertEqual(
            result.map(\.resolvedSpeechText),
            ["Alpha sentence.", "Beta sentence."]
        )
        XCTAssertEqual(
            result.map(\.resolvedSpeechText).joined(separator: " "),
            source
        )
    }

    func testSuppressedDuplicateThenMusicStillBreaksBeforeNextScene() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "Welcome to the show",
                startMs: 0,
                durationMs: 2_000
            ),
            YouTubeTranscriptCue(
                text: "Welcome to the show",
                startMs: 1_500,
                durationMs: 2_000
            ),
            YouTubeTranscriptCue(text: "[Music]", startMs: 3_000, durationMs: 500),
            YouTubeTranscriptCue(text: "A new scene begins", startMs: 3_500),
        ])

        XCTAssertEqual(result.map(\.id), [0, 1, 2])
        XCTAssertEqual(
            result.map(\.resolvedSpeechText),
            ["Welcome to the show", "", "A new scene begins"]
        )
        XCTAssertEqual(result[1].text, "[Music]")
    }

    func testShortRepeatedWordsAreNotMistakenForRollingOverlap() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "no no no", startMs: 0, durationMs: 1_000),
            YouTubeTranscriptCue(text: "no no no", startMs: 500, durationMs: 1_000),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), ["no no no no no no"])
    }

    func testMultipleSpeakerTurnsInsideOneCueBecomeSeparateParagraphs() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: ">> ALICE: Hi. >> BOB: Hello.",
                startMs: 0,
                durationMs: 2_000
            ),
        ])

        XCTAssertEqual(result.map(\.speaker), ["ALICE", "BOB"])
        XCTAssertEqual(result.map(\.resolvedSpeechText), ["Hi.", "Hello."])
    }

    func testTechnicalBitShiftOperatorsAreNotTreatedAsSpeakerTurns() throws {
        let source = "Use x >> 1 and y >> 2"
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: source, startMs: 0),
        ])
        let paragraph = try XCTUnwrap(result.first)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(paragraph.text, source)
        XCTAssertEqual(paragraph.resolvedSpeechText, source)
        XCTAssertNil(paragraph.speaker)
    }

    func testNamelessTurnMarkerDoesNotTurnIntroductoryProseIntoSpeaker() throws {
        for source in [
            ">> To summarize: we need two things",
            ">> Visit https://example.com",
        ] {
            let paragraph = try XCTUnwrap(
                YouTubeTranscriptGrouper.cuesIntoParagraphs([
                    YouTubeTranscriptCue(text: source, startMs: 0),
                ]).first
            )
            XCTAssertEqual(
                paragraph.resolvedSpeechText,
                String(source.dropFirst(2)).trimmingCharacters(in: .whitespaces),
                source
            )
            XCTAssertNil(paragraph.speaker, source)
        }
    }

    func testNamelessThenNamedTurnsInsideOneCueDoNotLeakMarkerOrRole() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: ">> Hello. >> BOB: Hi.",
                startMs: 0,
                durationMs: 2_000
            ),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), ["Hello.", "Hi."])
        XCTAssertEqual(result.map(\.speaker), [nil, "BOB"])
    }

    func testTitleCaseNamesOnExplicitTurnsAreRecognizedOnce() throws {
        let paragraph = try XCTUnwrap(
            YouTubeTranscriptGrouper.cuesIntoParagraphs([
                YouTubeTranscriptCue(text: ">> Alice: Hello", startMs: 0),
            ]).first
        )

        XCTAssertEqual(paragraph.resolvedSpeechText, "Hello")
        XCTAssertEqual(paragraph.speaker, "Alice")
    }

    func testRollingDuplicateProsePrefixDoesNotBecomeSpeakerEvidence() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "To summarize: we need two things",
                startMs: 0,
                durationMs: 0
            ),
            YouTubeTranscriptCue(
                text: "To summarize: we need two things today",
                startMs: 500,
                durationMs: 0
            ),
            YouTubeTranscriptCue(
                text: "To summarize: we need two things today together",
                startMs: 1_100,
                durationMs: 0
            ),
        ])

        XCTAssertEqual(
            result.map(\.resolvedSpeechText).joined(separator: " "),
            "To summarize: we need two things today together"
        )
        XCTAssertTrue(result.allSatisfy { $0.speaker == nil })
    }

    func testRollingSpeakerEvidenceUsesSameOverlapGraceAsSpeechDedupe() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "To summarize: we need two things",
                startMs: 0,
                durationMs: 1_000
            ),
            YouTubeTranscriptCue(
                text: "To summarize: we need two things today",
                startMs: 1_100,
                durationMs: 1_000
            ),
        ])

        XCTAssertEqual(
            result.map(\.resolvedSpeechText).joined(separator: " "),
            "To summarize: we need two things today"
        )
        XCTAssertTrue(result.allSatisfy { $0.speaker == nil })
    }

    func testRepeatedSpeakerAfterLeadingSemanticLabelIsRecognized() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "[Music] Alice: Hello", startMs: 0),
            YouTubeTranscriptCue(text: "(whispering) Alice: Quiet", startMs: 2_000),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), ["Hello", "Quiet"])
        XCTAssertEqual(result.map(\.speaker), ["Alice", "Alice"])
    }

    func testFullNamesAndInitialAliasesShareIdentityWithoutEnteringTTS() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "David Biello: No, no, no. Stay there for a second.",
                startMs: 1_028_204,
                durationMs: 2_750
            ),
            YouTubeTranscriptCue(
                text: "Matt Walker: You're welcome. DB: Yes, thank you, thank you.",
                startMs: 1_034_829,
                durationMs: 3_084
            ),
            YouTubeTranscriptCue(
                text: "MW: So you're right, we can't catch up on sleep.",
                startMs: 1_050_163,
                durationMs: 2_333
            ),
            YouTubeTranscriptCue(
                text: "DB: Because we're smart.",
                startMs: 1_072_579,
                durationMs: 1_125
            ),
            YouTubeTranscriptCue(
                text: "MW: And I make one more point.",
                startMs: 1_073_746,
                durationMs: 1_500
            ),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), [
            "No, no, no.",
            "Stay there for a second.",
            "You're welcome.",
            "Yes, thank you, thank you.",
            "So you're right, we can't catch up on sleep.",
            "Because we're smart.",
            "And I make one more point.",
        ])
        XCTAssertEqual(result.map(\.speaker), [
            "David Biello", "David Biello", "Matt Walker", "DB", "MW", "DB", "MW",
        ])
        let visible = result.map(\.text).joined(separator: " ")
        let spoken = result.map(\.resolvedSpeechText).joined(separator: " ")
        for label in ["David Biello:", "Matt Walker:", "DB:", "MW:"] {
            XCTAssertTrue(visible.contains(label), label)
            XCTAssertFalse(spoken.contains(label), label)
        }
    }

    func testOpeningProductionCreditsAreVisibleButSilentAndDoNotLeakSpeaker() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "Transcriber: Tijana Mihajlović Reviewer: Denise RQ",
                startMs: 0,
                durationMs: 7_000
            ),
            YouTubeTranscriptCue(text: "Hi.", startMs: 3_292, durationMs: 800),
            YouTubeTranscriptCue(
                text: "Reviewer: This approach is wrong.",
                startMs: 20_000,
                durationMs: 1_000
            ),
        ])

        XCTAssertEqual(result.map(\.text), [
            "Transcriber: Tijana Mihajlović Reviewer: Denise RQ",
            "Hi.",
            "Reviewer: This approach is wrong.",
        ])
        XCTAssertEqual(
            result.map(\.resolvedSpeechText),
            ["", "Hi.", "Reviewer: This approach is wrong."]
        )
        XCTAssertTrue(result.allSatisfy { $0.speaker == nil })
    }

    func testSingleOpeningBylineIsSilentOnlyForCompleteNameLikeRecord() throws {
        let metadata = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "Transcriber: Rhonda Jacobs",
                startMs: 0,
                durationMs: 1_000
            ),
        ])
        XCTAssertEqual(metadata.map(\.resolvedSpeechText), [""])

        let prose = try XCTUnwrap(
            YouTubeTranscriptGrouper.cuesIntoParagraphs([
                YouTubeTranscriptCue(
                    text: "Reviewer: This approach is wrong.",
                    startMs: 0,
                    durationMs: 1_000
                ),
            ]).first
        )
        XCTAssertEqual(prose.resolvedSpeechText, "Reviewer: This approach is wrong.")
        XCTAssertNil(prose.speaker)

        for source in [
            "Translator: Press Continue",
            "Transcriber: This Is A Test",
            "翻译：把这句话翻译成英文",
        ] {
            let paragraph = try XCTUnwrap(
                YouTubeTranscriptGrouper.cuesIntoParagraphs([
                    YouTubeTranscriptCue(text: source, startMs: 0, durationMs: 1_000),
                ]).first,
                source
            )
            XCTAssertEqual(paragraph.resolvedSpeechText, source, source)
            XCTAssertNil(paragraph.speaker, source)
        }
    }

    func testRepeatedNonPersonHeadingsAndTechnicalInitialsRemainSpeech() {
        let headings = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "User: signs in", startMs: 0, durationMs: 500),
            YouTubeTranscriptCue(text: "User: redirects", startMs: 2_000, durationMs: 500),
            YouTubeTranscriptCue(text: "Status: pending", startMs: 4_000, durationMs: 500),
            YouTubeTranscriptCue(text: "Status: complete", startMs: 6_000, durationMs: 500),
        ])
        XCTAssertEqual(headings.map(\.resolvedSpeechText), [
            "User: signs in", "User: redirects", "Status: pending", "Status: complete",
        ])
        XCTAssertTrue(headings.allSatisfy { $0.speaker == nil })

        let technical = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "Machine Learning: overview", startMs: 0, durationMs: 500),
            YouTubeTranscriptCue(text: "ML: training", startMs: 2_000, durationMs: 500),
            YouTubeTranscriptCue(text: "ML: inference", startMs: 4_000, durationMs: 500),
        ])
        XCTAssertEqual(technical.map(\.resolvedSpeechText), [
            "Machine Learning: overview", "ML: training", "ML: inference",
        ])
        XCTAssertTrue(technical.allSatisfy { $0.speaker == nil })

        let transformedTechnical = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "Quantum Computing: overview", startMs: 0, durationMs: 500),
            YouTubeTranscriptCue(text: "QC: training", startMs: 2_000, durationMs: 500),
            YouTubeTranscriptCue(text: "QC: inference", startMs: 4_000, durationMs: 500),
        ])
        XCTAssertEqual(transformedTechnical.map(\.resolvedSpeechText), [
            "Quantum Computing: overview", "QC: training", "QC: inference",
        ])
        XCTAssertTrue(transformedTechnical.allSatisfy { $0.speaker == nil })
    }

    func testRollingWindowsDoNotCastTwoSpeakerVotes() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "Alice: today we are learning how to code",
                startMs: 0,
                durationMs: 2_000
            ),
            YouTubeTranscriptCue(
                text: "Alice: today we are learning how to code with Swift",
                startMs: 1_500,
                durationMs: 2_000
            ),
        ])
        XCTAssertEqual(
            result.map(\.resolvedSpeechText).joined(separator: " "),
            "Alice: today we are learning how to code with Swift"
        )
        XCTAssertTrue(result.allSatisfy { $0.speaker == nil })
    }

    func testOpenEventGrammarSilencesDescriptionsButPreservesUnknownLabels() throws {
        for source in [
            "[birds chirping]", "[door creaking]", "[phone ringing]", "[baby crying]",
            "[engine revving]", "[audience applauding]", "[speaking foreign language]",
        ] {
            let paragraph = try XCTUnwrap(
                YouTubeTranscriptGrouper.cuesIntoParagraphs([
                    YouTubeTranscriptCue(text: source, startMs: 0),
                ]).first,
                source
            )
            XCTAssertEqual(paragraph.resolvedSpeechText, "", source)
        }
        let unknown = "[Project Update]"
        XCTAssertEqual(
            YouTubeTranscriptGrouper.cuesIntoParagraphs([
                YouTubeTranscriptCue(text: unknown, startMs: 0),
            ]).first?.resolvedSpeechText,
            unknown
        )
    }

    func testShiftOperatorsWithColonOperandsNeverCreateSpeakerTurns() {
        let source = "Use x >> A: first. Use y >> B: second."
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: source, startMs: 0, durationMs: 1_000),
        ])
        XCTAssertEqual(result.map(\.resolvedSpeechText).joined(separator: " "), source)
        XCTAssertTrue(result.allSatisfy { $0.speaker == nil })
    }

    func testStructuredSpeakerConflictFailsOpenInsteadOfMisattributingText() throws {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "Bob: first", startMs: 0, speaker: "Bob"),
            YouTubeTranscriptCue(text: "Bob: again", startMs: 2_000, speaker: "Bob"),
            YouTubeTranscriptCue(text: "Bob: hello", startMs: 4_000, speaker: "Alice"),
        ])
        let last = try XCTUnwrap(result.last)
        XCTAssertEqual(last.resolvedSpeechText, "Bob: hello")
        XCTAssertEqual(last.speaker, "Alice")
    }

    func testDurationCapSplitsOneWordAndUnevenSentenceCues() {
        let singleWord = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "helloworld", startMs: 0, durationMs: 30_000),
        ])
        XCTAssertEqual(singleWord.count, 2)
        XCTAssertEqual(singleWord.map(\.resolvedSpeechText).joined(), "helloworld")

        let uneven = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "Hi. " + Array(repeating: "word", count: 40).joined(separator: " "),
                startMs: 0,
                durationMs: 30_000
            ),
        ])
        XCTAssertGreaterThanOrEqual(uneven.count, 2)
        XCTAssertEqual(uneven.first?.startMs, 0)
        XCTAssertTrue(zip(uneven, uneven.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
    }

    func testAmbiguousInitialsDoNotMergeWeakFullNameCandidates() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "Mary Clark: First statement.", startMs: 0),
            YouTubeTranscriptCue(text: "Michael Chen: Second statement.", startMs: 2_000),
            YouTubeTranscriptCue(text: "MC: Third statement.", startMs: 4_000),
            YouTubeTranscriptCue(text: "MC: Fourth statement.", startMs: 6_000),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), [
            "Mary Clark: First statement.",
            "Michael Chen: Second statement.",
            "MC: Third statement.",
            "MC: Fourth statement.",
        ])
        XCTAssertEqual(result.map(\.speaker), [nil, nil, nil, nil])
    }

    func testSpeakerInferenceDependsOnStructureNotSpecificNames() {
        func projection(_ first: String, _ second: String) -> [(String, Bool)] {
            let firstAlias = first.split(separator: " ")
                .compactMap(\.first)
                .map(String.init)
                .joined()
                .uppercased()
            let secondAlias = second.split(separator: " ")
                .compactMap(\.first)
                .map(String.init)
                .joined()
                .uppercased()
            return YouTubeTranscriptGrouper.cuesIntoParagraphs([
                YouTubeTranscriptCue(text: "\(first): Welcome.", startMs: 0, durationMs: 1_000),
                YouTubeTranscriptCue(
                    text: "\(second): Thanks. \(firstAlias): Agreed.",
                    startMs: 2_000,
                    durationMs: 2_000
                ),
                YouTubeTranscriptCue(text: "\(secondAlias): Continue.", startMs: 5_000, durationMs: 1_000),
                YouTubeTranscriptCue(text: "\(firstAlias): Done.", startMs: 7_000, durationMs: 1_000),
                YouTubeTranscriptCue(text: "\(secondAlias): Goodbye.", startMs: 9_000, durationMs: 1_000),
            ]).enumerated().map { index, paragraph in
                let speech = index < 2
                    ? paragraph.resolvedSpeechText.components(separatedBy: ": ").dropFirst()
                        .joined(separator: ": ")
                    : paragraph.resolvedSpeechText
                return (speech, paragraph.speaker != nil)
            }
        }

        let baseline = projection("David Biello", "Matt Walker")
        let renamed = projection("Nora Patel", "Luis Garcia")
        XCTAssertEqual(baseline.map(\.0), renamed.map(\.0))
        XCTAssertEqual(baseline.map(\.1), renamed.map(\.1))
    }

    func testRealCueEndGapsDriveSoftAndHardUtteranceBoundaries() {
        let oneMillisecond = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "But about a month ago, I was up early, panicking about this,",
                startMs: 14_966,
                durationMs: 5_283
            ),
            YouTubeTranscriptCue(
                text: "and I watched an old TED Talk that Brené Brown did on vulnerability.",
                startMs: 20_250,
                durationMs: 5_751
            ),
        ])
        XCTAssertEqual(oneMillisecond.count, 1)
        XCTAssertEqual(oneMillisecond.first?.startMs, 14_966)

        let soft = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "She is a shame researcher,",
                startMs: 30_266,
                durationMs: 2_830
            ),
            YouTubeTranscriptCue(
                text: "and I am a recovering bulimic, alcoholic, and drug user.",
                startMs: 33_781,
                durationMs: 5_450
            ),
        ])
        XCTAssertEqual(soft.map(\.startMs), [30_266, 33_781])

        let hard = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "But what I learned during that time",
                startMs: 759_547,
                durationMs: 3_509
            ),
            YouTubeTranscriptCue(
                text: "is that sitting with the pain and the joy of being a human being",
                startMs: 763_057,
                durationMs: 4_810
            ),
            YouTubeTranscriptCue(
                text: "while refusing to run for any exits",
                startMs: 769_148,
                durationMs: 3_020
            ),
            YouTubeTranscriptCue(
                text: "is the only way to become a real human being.",
                startMs: 772_758,
                durationMs: 3_630
            ),
        ])
        XCTAssertEqual(hard.map(\.startMs), [759_547, 769_148])
    }

    func testSingleOversizedExtendedGraphemeCannotBypassUTF16Cap() {
        for source in [
            "a" + String(repeating: "\u{0301}", count: 300),
            "a" + String(repeating: "\u{1D165}", count: 150),
        ] {
            let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
                YouTubeTranscriptCue(text: source, startMs: 0),
            ])

            XCTAssertGreaterThan(result.count, 1)
            XCTAssertTrue(result.allSatisfy {
                ($0.resolvedSpeechText as NSString).length <= 240
            })
            XCTAssertEqual(result.map(\.resolvedSpeechText).joined(), source)
        }
    }

    func testOversizedTextKeepsOrdinaryExtendedGraphemesIntact() {
        let first = "a" + String(repeating: "\u{0301}", count: 150)
        let second = "b" + String(repeating: "\u{0301}", count: 150)
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: first + second, startMs: 0),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), [first, second])
        XCTAssertTrue(result.allSatisfy {
            ($0.resolvedSpeechText as NSString).length <= 240
        })
    }

    func testLargeInlineLabelUsesOverflowSafeDisplayPartitioning() {
        let source = String(repeating: "a", count: 25_000) +
            " [laughter] " + String(repeating: "b", count: 25_000)
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: source, startMs: 0, durationMs: 30_000),
        ])
        let speech = result.map(\.resolvedSpeechText).joined()

        XCTAssertGreaterThan(result.count, 100)
        XCTAssertTrue(result.allSatisfy { ($0.resolvedSpeechText as NSString).length <= 240 })
        XCTAssertTrue(result.allSatisfy { ($0.text as NSString).length <= 300 })
        XCTAssertEqual(speech.filter { $0 == "a" }.count, 25_000)
        XCTAssertEqual(speech.filter { $0 == "b" }.count, 25_000)
        XCTAssertFalse(speech.localizedCaseInsensitiveContains("laughter"))
    }

    func testMultipleSentencesInsideOneCueUseNaturalBoundaries() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "First sentence. Second sentence! Third sentence?",
                startMs: 0,
                durationMs: 3_000
            ),
        ])

        XCTAssertEqual(
            result.map(\.resolvedSpeechText),
            ["First sentence.", "Second sentence!", "Third sentence?"]
        )
    }

    func testSingleOversizedCueIsSplitWithoutDroppingWords() {
        let source = (1...60).map { "word\($0)" }.joined(separator: " ")
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: source, startMs: 0, durationMs: 12_000),
        ])

        XCTAssertGreaterThan(result.count, 1)
        XCTAssertTrue(result.allSatisfy {
            $0.resolvedSpeechText.split(whereSeparator: { $0.isWhitespace }).count <= 42
        })
        XCTAssertEqual(
            result.map(\.resolvedSpeechText).joined(separator: " "),
            source
        )
    }

    func testOversizedCueWithInlineLaughterStillSplitsWithoutDroppingSpeechWords() {
        let expectedWords = (1...60).map { "word\($0)" }
        let source = expectedWords.prefix(30).joined(separator: " ")
            + " [laughter] "
            + expectedWords.suffix(30).joined(separator: " ")
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: source, startMs: 0, durationMs: 12_000),
        ])
        let spokenWords = result.flatMap { paragraph in
            paragraph.resolvedSpeechText
                .split(whereSeparator: { $0.isWhitespace })
                .map {
                    String($0).trimmingCharacters(in: .punctuationCharacters)
                }
                .filter { !$0.isEmpty }
        }

        XCTAssertGreaterThan(result.count, 1)
        XCTAssertTrue(result.allSatisfy {
            $0.resolvedSpeechText.split(whereSeparator: { $0.isWhitespace }).count <= 42
        })
        XCTAssertEqual(spokenWords, expectedWords)
        XCTAssertFalse(
            result.map(\.resolvedSpeechText).joined(separator: " ")
                .localizedCaseInsensitiveContains("laughter")
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

    func testNormalizesNewlinesDropsEmptyCuesAndKeepsStableEqualTimeOrder() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "  ", startMs: 0),
            YouTubeTranscriptCue(text: "alpha\nbeta", startMs: 100),
            YouTubeTranscriptCue(text: "gamma", startMs: 100),
        ])
        XCTAssertEqual(result, [
            YouTubeTranscriptParagraph(
                id: 0,
                text: "alpha beta gamma",
                speechText: "alpha beta gamma",
                startMs: 100
            ),
        ])
    }

    /// Conservative cleaning is an information-safety property: bracket
    /// syntax alone is never enough to suppress content. These labels are
    /// deliberately varied by delimiter, language and proximity to the event
    /// grammar so a future taxonomy expansion cannot silently turn unknown
    /// text into an empty TTS payload.
    func testUnknownSemanticLabelsFailOpenAcrossDelimiterAndLanguageTransforms() throws {
        let unknownLabels = [
            "[Project Update]",
            "(Quarterly Results)",
            "【项目更新】",
            "［設計レビュー］",
            "[birds reviewing]",
            "(door architecture)",
        ]

        for (index, source) in unknownLabels.enumerated() {
            let paragraph = try XCTUnwrap(
                YouTubeTranscriptGrouper.cuesIntoParagraphs([
                    YouTubeTranscriptCue(
                        text: source,
                        startMs: index * 2_000,
                        durationMs: 500
                    ),
                ]).first,
                source
            )
            XCTAssertEqual(paragraph.text, source, source)
            XCTAssertEqual(paragraph.resolvedSpeechText, source, source)
            XCTAssertNil(paragraph.speaker, source)
        }
    }

    /// Role state, delivery annotations and scene events are different
    /// semantic classes. A delivery label preserves the active role, while a
    /// scene event clears it on the side of the speech where the event occurs.
    func testRoleAndEventStateMachineIsStableAcrossLeadingAndTrailingLabels() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "[narrator]", startMs: 0, durationMs: 100),
            YouTubeTranscriptCue(
                text: "(whispering) first statement",
                startMs: 100,
                durationMs: 500
            ),
            YouTubeTranscriptCue(text: "second statement", startMs: 600, durationMs: 500),
            YouTubeTranscriptCue(
                text: "[birds chirping] third statement",
                startMs: 1_100,
                durationMs: 500
            ),
            YouTubeTranscriptCue(text: "fourth statement", startMs: 1_600, durationMs: 500),
            YouTubeTranscriptCue(text: "[host]", startMs: 2_100, durationMs: 100),
            YouTubeTranscriptCue(
                text: "fifth statement [door closing]",
                startMs: 2_200,
                durationMs: 500
            ),
            YouTubeTranscriptCue(text: "sixth statement", startMs: 2_700, durationMs: 500),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), [
            "", "first statement second statement", "third statement fourth statement",
            "", "fifth statement", "sixth statement",
        ])
        XCTAssertEqual(result.map(\.speaker), [
            nil, "narrator", nil, nil, "host", nil,
        ])
    }

    /// Boundary and scene-reset evidence must come from the same typed span.
    /// A leading delivery label cannot lend its position to an unrelated
    /// inline event and accidentally clear the inherited speaker.
    func testDialogueResetDoesNotCombineEvidenceAcrossDifferentSpans() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(text: "[narrator]", startMs: 0, durationMs: 100),
            YouTubeTranscriptCue(
                text: "(whispering) alpha [laughter] beta",
                startMs: 100,
                durationMs: 1_000
            ),
        ])

        let spoken = result.filter { !$0.resolvedSpeechText.isEmpty }
        XCTAssertEqual(
            spoken.map { $0.resolvedSpeechText.replacingOccurrences(of: " ", with: "") },
            ["alpha.", "beta"]
        )
        XCTAssertTrue(spoken.allSatisfy { $0.speaker == "narrator" })
    }

    /// Suppression is permitted only after classification. This directly
    /// verifies the auditable intermediate representation, including category,
    /// placement, evidence strength and the UTF-16 source range used to remove
    /// a span from TTS text.
    func testSemanticLabelSpansRequireTypedEvidenceBeforeSuppression() throws {
        let source = "[music] alpha [laughter and applause] beta (whispering) gamma [Project Update]"
        let spans = YouTubeCaptionSemanticAnalyzer.semanticLabelSpans(in: source)

        XCTAssertEqual(spans.map(\.rawText), [
            "[music]", "[laughter and applause]", "(whispering)", "[Project Update]",
        ])
        XCTAssertEqual(spans.map(\.category), [
            .music, .audienceReaction, .delivery, .unknown,
        ])
        XCTAssertEqual(spans.map(\.position), [
            .leading, .inline, .inline, .trailing,
        ])
        XCTAssertEqual(spans.map(\.disposition), [
            .suppress, .suppress, .suppress, .preserve,
        ])
        XCTAssertEqual(spans.map(\.evidence), [
            .exactTaxonomy, .composedEventGrammar, .exactTaxonomy, .unknown,
        ])
        XCTAssertEqual(spans.map(\.confidence), [
            .high, .medium, .high, .unknown,
        ])
        XCTAssertEqual(spans.map(\.decisionReason), [
            .classifiedAccessibilityMetadata,
            .classifiedAccessibilityMetadata,
            .classifiedAccessibilityMetadata,
            .unknownFailOpen,
        ])

        let sourceNSString = source as NSString
        for span in spans {
            XCTAssertEqual(sourceNSString.substring(with: span.inputRange), span.rawText)
            if span.disposition != .preserve {
                XCTAssertNotEqual(span.category, .unknown)
                XCTAssertNotEqual(span.evidence, .unknown)
                XCTAssertNotEqual(span.confidence, .unknown)
            }
        }
    }

    /// Parentheses are prose-ambiguous. Exact delivery/unavailable markers may
    /// be removed inline; sound words and open-grammar guesses remain verbatim.
    func testInlineRoundLabelDispositionDependsOnCategoryAndConfidence() {
        let source = "A (music) B (birds chirping) C (whispering) D (inaudible) E"
        let spans = YouTubeCaptionSemanticAnalyzer.semanticLabelSpans(in: source)

        XCTAssertEqual(spans.map(\.category), [
            .music, .ambientSound, .delivery, .unavailable,
        ])
        XCTAssertEqual(spans.map(\.confidence), [.high, .medium, .high, .high])
        XCTAssertEqual(spans.map(\.disposition), [
            .preserve, .preserve, .suppress, .suppress,
        ])
    }

    func testInlineMetadataPauseDoesNotDuplicateExistingTerminalPunctuation() throws {
        let paragraph = try XCTUnwrap(
            YouTubeTranscriptGrouper.cuesIntoParagraphs([
                YouTubeTranscriptCue(
                    text: "alpha. (whispering) beta",
                    startMs: 0,
                    durationMs: 1_000
                ),
            ]).first
        )
        XCTAssertEqual(paragraph.resolvedSpeechText, "alpha.")
        let fullSpeech = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: "alpha. (whispering) beta",
                startMs: 0,
                durationMs: 1_000
            ),
        ]).map(\.resolvedSpeechText).joined(separator: " ")
        XCTAssertEqual(fullSpeech, "alpha. beta")
    }

    /// Speaker names are data, not segmentation rules. Replacing every name
    /// and its initials with equally shaped alternatives must leave utterance
    /// text, timing projection and paragraph boundaries unchanged.
    func testSpeakerRenamingDoesNotChangeUtteranceSegmentationOrTiming() {
        func projection(
            first: String,
            firstAlias: String,
            second: String,
            secondAlias: String
        ) -> [YouTubeTranscriptParagraph] {
            YouTubeTranscriptGrouper.cuesIntoParagraphs([
                YouTubeTranscriptCue(
                    text: ">> \(first): Alpha sentence. >> \(second): Beta sentence.",
                    startMs: 10_000,
                    durationMs: 4_000
                ),
                YouTubeTranscriptCue(
                    text: ">> \(firstAlias): Gamma sentence. >> \(secondAlias): Delta sentence.",
                    startMs: 15_000,
                    durationMs: 4_000
                ),
            ])
        }

        let baseline = projection(
            first: "Alice Stone",
            firstAlias: "AS",
            second: "Bruno Mills",
            secondAlias: "BM"
        )
        let renamed = projection(
            first: "Clara Jones",
            firstAlias: "CJ",
            second: "Derek Young",
            secondAlias: "DY"
        )

        XCTAssertEqual(
            baseline.map(\.resolvedSpeechText),
            ["Alpha sentence.", "Beta sentence.", "Gamma sentence.", "Delta sentence."]
        )
        XCTAssertEqual(renamed.map(\.resolvedSpeechText), baseline.map(\.resolvedSpeechText))
        XCTAssertEqual(renamed.map(\.startMs), baseline.map(\.startMs))
        XCTAssertEqual(renamed.map { $0.speaker != nil }, baseline.map { $0.speaker != nil })
    }

    /// Acronym aliasing is allowed only after person-like evidence. Repeating
    /// the structural pattern with unrelated technical concepts must preserve
    /// both the expansion and acronym as ordinary speech.
    func testTechnicalAcronymFamiliesRemainSpeechUnderLexicalTransformation() {
        let families: [(longForm: String, acronym: String)] = [
            ("Vector Database", "VD"),
            ("Transport Layer Security", "TLS"),
            ("Domain Driven Design", "DDD"),
        ]

        for family in families {
            let source = [
                "\(family.longForm): overview",
                "\(family.acronym): configuration",
                "\(family.acronym): diagnostics",
            ]
            let result = YouTubeTranscriptGrouper.cuesIntoParagraphs(
                source.enumerated().map { index, text in
                    YouTubeTranscriptCue(
                        text: text,
                        startMs: index * 2_000,
                        durationMs: 500
                    )
                }
            )

            XCTAssertEqual(result.map(\.resolvedSpeechText), source, family.longForm)
            XCTAssertTrue(result.allSatisfy { $0.speaker == nil }, family.longForm)
        }
    }

    /// Every derived timestamp is an anchor into the source media. Splitting
    /// turns and sentences may project a later start, but it must remain
    /// monotonic and inside the originating cue's bounded time interval.
    func testProjectedUtteranceStartsAreMonotonicAndInsideSourceCueWindows() {
        let firstWindow = 10_000...19_000
        let secondWindow = 30_000...36_000
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: ">> ALICE: alpha sentence. >> BOB: beta sentence. >> ALICE: gamma sentence.",
                startMs: firstWindow.lowerBound,
                durationMs: firstWindow.upperBound - firstWindow.lowerBound
            ),
            YouTubeTranscriptCue(
                text: "First unit. Second unit!",
                startMs: secondWindow.lowerBound,
                durationMs: secondWindow.upperBound - secondWindow.lowerBound
            ),
        ])

        XCTAssertEqual(result.map(\.resolvedSpeechText), [
            "alpha sentence.", "beta sentence.", "gamma sentence.",
            "First unit.", "Second unit!",
        ])
        XCTAssertTrue(zip(result, result.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
        for paragraph in result {
            let sourceWindow = paragraph.resolvedSpeechText.first?.isLowercase == true
                ? firstWindow
                : secondWindow
            XCTAssertTrue(
                sourceWindow.contains(paragraph.startMs),
                "\(paragraph.resolvedSpeechText) @ \(paragraph.startMs)"
            )
        }
    }

    /// Known removable spans may disappear, but every ordinary body token
    /// must survive exactly once and in source order after segmentation.
    func testSpeechProjectionPreservesAllBodyTokensWhileSuppressingTypedSpans() {
        let result = YouTubeTranscriptGrouper.cuesIntoParagraphs([
            YouTubeTranscriptCue(
                text: ">> ALICE: alphaone alphatwo [laughter] alphathree. " +
                    ">> BOB: betaone (whispering) betatwo.",
                startMs: 5_000,
                durationMs: 5_000
            ),
        ])
        let spoken = result.map(\.resolvedSpeechText).joined(separator: " ")
        let bodyTokens = spoken
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: .punctuationCharacters).lowercased() }
            .filter { !$0.isEmpty }

        XCTAssertEqual(bodyTokens, [
            "alphaone", "alphatwo", "alphathree", "betaone", "betatwo",
        ])
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("laughter"))
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("whispering"))
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("alice"))
        XCTAssertFalse(spoken.localizedCaseInsensitiveContains("bob"))
    }

    func testMatchesVersionedCrossPlatformGoldenUtterances() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixtureURL = repositoryRoot
            .appendingPathComponent("docs/contracts/youtube-caption-semantics-v3.json")
        let contract = try JSONDecoder().decode(
            YouTubeCaptionSemanticGoldenContract.self,
            from: Data(contentsOf: fixtureURL)
        )

        XCTAssertEqual(contract.schemaVersion, YouTubeCaptionSemanticSchema.current)
        for fixture in contract.cases {
            XCTAssertEqual(
                YouTubeTranscriptGrouper.cuesIntoParagraphs(fixture.cues),
                fixture.expectedParagraphs,
                fixture.id
            )
        }
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

    func testLegacyCodableWithoutSemanticFieldsUsesSafeDefaultsAndRederivesParagraphs() throws {
        let decoder = JSONDecoder()
        let legacyCue = try decoder.decode(
            YouTubeTranscriptCue.self,
            from: Data(#"{"text":"legacy cue","startMs":10,"durationMs":20}"#.utf8)
        )
        XCTAssertNil(legacyCue.speaker)

        let legacyParagraph = try decoder.decode(
            YouTubeTranscriptParagraph.self,
            from: Data(#"{"id":7,"text":"legacy paragraph","startMs":10}"#.utf8)
        )
        XCTAssertNil(legacyParagraph.speechText)
        XCTAssertNil(legacyParagraph.speaker)
        XCTAssertEqual(legacyParagraph.resolvedSpeechText, "legacy paragraph")

        let legacyDocument = Data(#"""
        {
          "metadata": {
            "videoId": "dQw4w9WgXcQ",
            "title": "Legacy",
            "sourceURL": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
          },
          "track": {
            "baseUrl": "https://captions.example/legacy",
            "languageCode": "en"
          },
          "cues": [
            {"text": "[Music]", "startMs": 0, "durationMs": 500},
            {"text": ">> ALICE: Hello.", "startMs": 2000, "durationMs": 500}
          ],
          "paragraphs": [
            {"id": 99, "text": "stale cached paragraph", "startMs": 0}
          ],
          "extractedAt": 0
        }
        """#.utf8)
        let decoded = try decoder.decode(
            YouTubeTranscriptDocument.self,
            from: legacyDocument
        )

        XCTAssertNil(
            decoded.captionSemanticSchemaVersion,
            "pre-P0 cues stay usable offline but must be refreshed online for structured speakers"
        )
        XCTAssertEqual(decoded.paragraphs.map(\.id), [0, 1])
        XCTAssertEqual(decoded.paragraphs.map(\.text), ["[Music]", ">> ALICE: Hello."])
        XCTAssertEqual(decoded.paragraphs.map(\.resolvedSpeechText), ["", "Hello."])
        XCTAssertEqual(decoded.paragraphs.last?.speaker, "ALICE")
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
