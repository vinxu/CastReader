import XCTest
import UIKit
@testable import CastReader

@MainActor
final class ExplainSubtitleTests: XCTestCase {
    private let font = UIFont.systemFont(ofSize: 16, weight: .medium)

    private func segment(_ text: String, times: [TTSTimestamp] = [], duration: Double = 12) -> AudioSegment {
        AudioSegment(paragraphIndex: 0, segmentIndex: 0, audioData: Data(), timestamps: [],
                     duration: duration, text: text, timingTimestamps: times)
    }

    func testLongEnglishChineseAndUnicodeFitWithoutDroppingText() {
        let samples = [
            "creditors who had preyed on her during her life and hounded her to her deathbed were now circling like vultures to claim their dirty profits—proving the ancient wisdom that merchants and thieves truly worship the exact same god.",
            "这是一个没有逗号的很长的中文讲解句子需要根据真实屏幕宽度切成多条单行字幕并且不能丢失任何文字。下一句也要完整显示！",
            "Café résumé 👨‍👩‍👧‍👦 costs 3.14 dollars. AntidisestablishmentarianismAndAnotherVeryLongUnbrokenWord",
            "पहला वाक्य पूरा है। अगला वाक्य यहाँ शुरू होता है।",
            "第一行\n第二行\nThird line without an ellipsis."
        ]
        for size: CGFloat in [16, 23, 32] {
            let font = UIFont.systemFont(ofSize: size, weight: .medium)
            for width: CGFloat in [160, 280, 380, 700] {
                for text in samples {
                    let timeline = ExplainSubtitleTimeline(segment: segment(text), width: width, font: font)
                    XCTAssertGreaterThan(timeline.cues.count, 0)
                    let reconstructed = timeline.cues.map(\.text).joined().filter { !$0.isWhitespace }
                    XCTAssertEqual(reconstructed, text.filter { !$0.isWhitespace })
                    for cue in timeline.cues {
                        XCTAssertLessThanOrEqual((cue.text as NSString).size(withAttributes: [.font: font]).width, width + 0.5, cue.text)
                        XCTAssertFalse(cue.text.contains("\n"))
                        XCTAssertNotNil(Range(cue.range, in: text))
                    }
                }
            }
        }
    }

    func testIrregularWordTimesDriveEveryCueInsteadOfBlockPercentage() {
        let text = "First words. Second words. Last words."
        let starts = [0.2, 0.4, 5.8, 6.0, 7.0, 10.0]
        let words = ["First", "words", "Second", "words", "Last", "words"]
        let times = zip(words, starts).map { TTSTimestamp(word: $0, startTime: $1, endTime: $1 + 0.2) }
        let timeline = ExplainSubtitleTimeline(segment: segment(text, times: times), width: 280, font: font)
        XCTAssertTrue(timeline.usesWordTiming)
        XCTAssertEqual(timeline.cues.map(\.start), [0.2, 5.8, 7.0])
        XCTAssertEqual(timeline.cue(at: 5.79)?.text, "First words.")
        XCTAssertEqual(timeline.cue(at: 5.8)?.text, "Second words.")
        XCTAssertEqual(timeline.cue(at: 7)?.text, "Last words.")
        XCTAssertEqual(timeline.cue(at: 0.3)?.text, "First words.", "Seeking back must not retain a later cue")
    }

    func testChineseUsesRawTimingEvenWhenReadingHighlightsSuppressWordCues() {
        let text = "第一句。第二句。"
        let times = [TTSTimestamp(word: "第一句", startTime: 0, endTime: 1),
                     TTSTimestamp(word: "第二句", startTime: 4.2, endTime: 5)]
        let audio = segment(text, times: times, duration: 6)
        XCTAssertTrue(audio.timestamps.isEmpty)
        let timeline = ExplainSubtitleTimeline(segment: audio, width: 280, font: font)
        XCTAssertTrue(timeline.usesWordTiming)
        XCTAssertEqual(timeline.cue(at: 4.19)?.text, "第一句。")
        XCTAssertEqual(timeline.cue(at: 4.2)?.text, "第二句。")
    }

    func testPunctuationNormalizationPreservesCaptionAndRepeatedWordsStaySequential() {
        let text = "“Don't stop.” Don't stop!"
        let times = [TTSTimestamp(word: "dont", startTime: 0, endTime: 1),
                     TTSTimestamp(word: "stop", startTime: 1, endTime: 2),
                     TTSTimestamp(word: "don't", startTime: 4, endTime: 5),
                     TTSTimestamp(word: "stop", startTime: 5, endTime: 6)]
        let timeline = ExplainSubtitleTimeline(segment: segment(text, times: times), width: 280, font: font)
        XCTAssertTrue(timeline.usesWordTiming)
        XCTAssertEqual(timeline.cue(at: 3)?.text, "“Don't stop.”")
        XCTAssertEqual(timeline.cue(at: 4)?.text, "Don't stop!")
    }

    func testWidthChangeRetainsMediaPositionAndHasNoMissingWords() {
        let text = "These captions follow actual words without changing the continuous audio."
        let words = text.split(separator: " ").map(String.init)
        let times = words.enumerated().map { TTSTimestamp(word: $0.element, startTime: Double($0.offset), endTime: Double($0.offset) + 0.7) }
        let audio = segment(text, times: times)
        for width: CGFloat in [160, 300, 700] {
            let timeline = ExplainSubtitleTimeline(segment: audio, width: width, font: font)
            let cue = timeline.cue(at: 4.1)
            XCTAssertTrue(cue?.text.contains("words") == true)
            XCTAssertLessThanOrEqual(cue?.start ?? 100, 4.1)
        }
    }

    func testMissingOrInvalidTimestampsHaveExplicitSegmentLocalFallback() {
        for times in [[], [TTSTimestamp(word: "wrong", startTime: 0, endTime: 1)],
                      [TTSTimestamp(word: "One. Two.", startTime: .nan, endTime: 1)]] {
            let timeline = ExplainSubtitleTimeline(segment: segment("One. Two.", times: times, duration: 2), width: 280, font: font)
            XCTAssertFalse(timeline.usesWordTiming)
            XCTAssertEqual(timeline.cue(at: 0)?.text, "One.")
            XCTAssertEqual(timeline.cue(at: 1.5)?.text, "Two.")
        }
    }
}
