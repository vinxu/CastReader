import XCTest
@testable import CastReader

final class KindleSpeechTextPlanTests: XCTestCase {
    private func chunks(_ text: String, target: Int = 240, maximum: Int = 600) -> [String] {
        let chars = Array(text)
        return KindleSpeechTextPlan.chunkRanges(in: text, targetLength: target, maximumLength: maximum)
            .map { String(chars[$0]) }
    }

    func testLongNaturalSentenceIsNotCutAtOld240CharacterLimit() {
        let text = "The professor " + Array(repeating: "continued his careful explanation", count: 9).joined(separator: " ") + "."
        XCTAssertGreaterThan(text.count, 240)
        XCTAssertLessThan(text.count, 600)
        XCTAssertEqual(chunks(text), [text])
    }

    func testBoundaryFallsBetweenSentencesAndPreservesQuotes() {
        let first = "“" + Array(repeating: "We kept moving", count: 9).joined(separator: " ") + ".”"
        let second = Array(repeating: "The journey continued", count: 6).joined(separator: " ") + "."
        XCTAssertEqual(chunks(first + "\n" + second), [first, second])
    }

    func testAbbreviationsAndDecimalsStayInsideSentence() {
        let text = "Dr. Smith measured 3.14 metres before Mr. Jones arrived."
        XCTAssertEqual(chunks(text, target: 20), [text])
    }

    func testLongSentenceUsesClauseInsteadOfCuttingAWord() {
        let first = Array(repeating: "careful observation", count: 18).joined(separator: " ") + ","
        let second = Array(repeating: "uninterrupted narrative", count: 15).joined(separator: " ") + "."
        XCTAssertEqual(chunks(first + " " + second), [first, second])
    }

    func testNoSpacesDoesNotSplitAnIndivisibleToken() {
        let token = String(repeating: "a", count: 650)
        XCTAssertEqual(chunks(token), [token])
    }

    func testUnfinishedPageSuffixIsPreservedWithoutInventedPunctuation() {
        let text = "Was not the journey being accomplished under the most favorable circumstances? Was"
        XCTAssertEqual(chunks(text).joined(separator: " "), text)
        XCTAssertTrue(chunks(text).last?.hasSuffix("Was") == true)
    }

    func testUnicodeAndEveryNonWhitespaceCharacterArePreservedExactlyOnce() {
        for text in [
            "他说：“旅途仍在继续。”\n下一页还没有结束的句子",
            "👩🏽‍🔬 The cafe\u{301} is open. " + Array(repeating: "verylongword", count: 80).joined(separator: " "),
            "  First sentence.\n\nSecond sentence!  Third sentence?  "
        ] {
            let ranges = KindleSpeechTextPlan.chunkRanges(in: text)
            let chars = Array(text)
            for pair in zip(ranges, ranges.dropFirst()) {
                XCTAssertLessThanOrEqual(pair.0.upperBound, pair.1.lowerBound)
            }
            let actual = ranges.flatMap { Array(chars[$0]) }.filter { !$0.isWhitespace }
            XCTAssertEqual(actual, chars.filter { !$0.isWhitespace })
        }
    }
}
