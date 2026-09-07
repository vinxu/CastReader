import CoreGraphics
import XCTest
@testable import CastReader

final class OCRTokenGeometryCoverageTests: XCTestCase {
    private let line = CGRect(x: 0.1, y: 0.7, width: 0.8, height: 0.06)

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
