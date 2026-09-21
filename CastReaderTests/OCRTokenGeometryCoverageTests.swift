import CoreGraphics
import XCTest
@testable import CastReader

final class OCRTokenGeometryCoverageTests: XCTestCase {
    private let line = CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.06)

    func testReflowRemainderKeepsOnlyUnreadTextAndOriginalBoxes() throws {
        func paragraph(_ id: Int, _ text: String) -> ReadingParagraph {
            ReadingParagraph(id: id, text: text, words: text.split(separator: " ").enumerated().map {
                OCRWord(id: $0.offset, text: String($0.element), bboxNorm: line.offsetBy(dx: CGFloat($0.offset) * 0.01, dy: 0))
            })
        }
        let original = [paragraph(0, "Read all these words."), paragraph(1, "Read this then continue here."), paragraph(2, "Next paragraph.")]
        let remaining = try XCTUnwrap(KindleViewportTextAlignment.remainingParagraphs(original, afterParagraph: 1, afterWord: 2))
        XCTAssertEqual(remaining.map(\.id), [0, 1])
        XCTAssertEqual(remaining.map(\.text), ["continue here.", "Next paragraph."])
        XCTAssertEqual(remaining[0].words.first?.bboxNorm, original[1].words[3].bboxNorm)
        XCTAssertEqual(KindleViewportTextAlignment.remainingParagraphs(original, afterParagraph: 2, afterWord: 1), [])
        XCTAssertNil(KindleViewportTextAlignment.remainingParagraphs(original, afterParagraph: 1, afterWord: 50))
    }

    func testKindleViewportAlignmentSurvivesJoinedHyphenAndMissingOCRWord() throws {
        let original = "the waves appear to be fire eating monsters beneath which seethes intense fire".components(separatedBy: " ")
        let captured = "other page the waves appear to be fireeating monsters beneath seethes intense fire remaining".components(separatedBy: " ")
        let pairs = try XCTUnwrap(KindleViewportTextAlignment.match(original: original, captured: captured, anchor: 6))
        XCTAssertTrue(pairs.contains(.init(original: 5, captured: 7)))
        XCTAssertTrue(pairs.contains(.init(original: 6, captured: 7)))
        XCTAssertTrue(pairs.contains(.init(original: 12, captured: 12)), "A dropped OCR word must not lose the rest of the sentence")
        XCTAssertFalse(pairs.contains { $0.original == 9 })
    }

    func testKindleViewportAlignmentReturnsBothHalvesOfSplitWord() throws {
        let original = "bright fireeating monsters beneath their crests of flame".components(separatedBy: " ")
        let captured = "bright fire eating monsters beneath their crests of flame".components(separatedBy: " ")
        let pairs = try XCTUnwrap(KindleViewportTextAlignment.match(original: original, captured: captured, anchor: 1))
        XCTAssertEqual(pairs.filter { $0.original == 1 }.map(\.captured), [1, 2])
        XCTAssertEqual(pairs.last, .init(original: 7, captured: 8))
    }

    func testKindleViewportRejectsAbsentAnchorAndUnrelatedText() {
        let original = "distinct opening sentence then unrelated closing discussion ends here".components(separatedBy: " ")
        XCTAssertNil(KindleViewportTextAlignment.match(original: original,
            captured: "closing discussion ends here".components(separatedBy: " "), anchor: 0))
        XCTAssertNil(KindleViewportTextAlignment.match(original: original,
            captured: "an entirely different chapter about the voyage and the ship".components(separatedBy: " "), anchor: 0))
    }

    func testProjectedMarkKeepsRepeatedWordIdentityAndSplitLineBoxes() {
        let text = "fire and fireeating monsters"
        let words = text.components(separatedBy: " ").enumerated().map { OCRWord(id: $0.offset, text: $0.element, bboxNorm: line) }
        let doc = ReadingDocument(title: "Projection", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: text, type: .paragraph, words: words)])
        let first = CGRect(x: 0.8, y: 0.7, width: 0.1, height: 0.05)
        let second = CGRect(x: 0.1, y: 0.6, width: 0.2, height: 0.05)
        let resolver = PhotoAnchorResolver(document: doc, fitted: CGRect(x: 0, y: 0, width: 1000, height: 1000),
            wordBoxOverrides: [0: [2: [first, second]]])
        XCTAssertTrue(resolver.rectsForCharRange(paragraphIndex: 0, range: 0..<4).isEmpty,
                      "The first repeated word is off-page and must not reuse stale geometry")
        XCTAssertEqual(resolver.rectsForCharRange(paragraphIndex: 0, range: 9..<19).count, 2)
        XCTAssertEqual(resolver.rectsForWord(paragraphIndex: 0, wordIndex: 2).count, 2)
    }

    func testReflowProjectionUsesSemanticParagraphIDsForMarksAndWords() {
        let word = OCRWord(id: 0, text: "anchor", bboxNorm: line)
        let projected = ReadingDocument(title: "Projection", sourceKind: .kindle, language: "en",
            paragraphs: [ReadingParagraph(id: 7, text: "anchor", type: .paragraph, words: [word], bboxNorm: line)])
        let surface = CGRect(x: 20, y: 40, width: 800, height: 1000)
        let resolver = PhotoAnchorResolver(document: projected, fitted: surface)
        let expected = ReadingGeometry.displayRect(forNorm: line, in: surface)
        XCTAssertEqual(resolver.rectsForWord(paragraphIndex: 7, wordIndex: 0), [expected])
        XCTAssertEqual(resolver.rectsForCharRange(paragraphIndex: 7, range: 0..<6), [expected])
        XCTAssertTrue(resolver.rectsForCharRange(paragraphIndex: 0, range: 0..<6).isEmpty,
                      "An absent paragraph must not paint a different paragraph at the same array offset")
    }

    func testOneUnavailableBoxKeepsEveryRecognizedTokenAndOriginalRealBoxes() {
        let first = CGRect(x: 0.1, y: 0.7, width: 0.13, height: 0.06)
        let last = CGRect(x: 0.65, y: 0.7, width: 0.24, height: 0.06)
        let tokens = OCRTokenGeometryCoverage.resolve(
            text: "Every missing word survives.", language: "en", lineBox: line,
            sourceLineID: 7, confidence: 0.99,
            tokenBoxes: [first, nil, .null, last]
        )
        XCTAssertEqual(tokens.map(\.text), ["Every", "missing", "word", "survives."])
        XCTAssertEqual(tokens.map(\.bboxSource), [.visionTextRange, .proportional, .proportional, .visionTextRange])
        XCTAssertEqual(tokens.first?.bbox, first)
        XCTAssertEqual(tokens.last?.bbox, last)
        XCTAssertTrue(tokens.allSatisfy { $0.sourceLineID == 7 })
        XCTAssertTrue(OCRTokenGeometryCoverage.requiresEngineLineOrder(tokens),
                      "Estimated geometry must not cause a word to reorder or disappear during layout rebuilding.")
    }

    func testAllUnavailableBoxesPreserveCJKGraphemeTokens() {
        let tokens = OCRTokenGeometryCoverage.resolve(
            text: "山 川と空。", language: "ja", lineBox: line,
            sourceLineID: 0, confidence: 0.9, tokenBoxes: []
        )
        XCTAssertEqual(tokens.map(\.text), ["山", "川", "と", "空", "。"])
        XCTAssertTrue(tokens.allSatisfy { $0.bboxSource == .proportional })
        XCTAssertTrue(tokens.allSatisfy { OCRTokenGeometryCoverage.isUsable($0.bbox) })
        XCTAssertEqual(tokens.map(\.bbox.minX), tokens.map(\.bbox.minX).sorted())
    }

    func testZeroAndNonfiniteBoxesAreEstimatedWithoutDroppingDigits() {
        let tokens = OCRTokenGeometryCoverage.resolve(
            text: "In 1924 12", language: "en", lineBox: line,
            sourceLineID: 0, confidence: 0.9,
            tokenBoxes: [.zero, CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1), nil]
        )
        XCTAssertEqual(tokens.map(\.text), ["In", "1924", "12"])
        XCTAssertTrue(tokens.allSatisfy { $0.bboxSource == .proportional })
    }

    func testCompleteGenuineGeometryRetainsExistingLayoutEligibility() {
        let boxes = [line, line.offsetBy(dx: 0.1, dy: 0)]
        let tokens = OCRTokenGeometryCoverage.resolve(
            text: "Two tokens", language: "en", lineBox: line,
            sourceLineID: 0, confidence: 0.95, tokenBoxes: boxes.map(Optional.some)
        )
        XCTAssertEqual(tokens.map(\.bbox), boxes)
        XCTAssertFalse(OCRTokenGeometryCoverage.requiresEngineLineOrder(tokens))
    }
}
