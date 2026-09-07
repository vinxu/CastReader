import CoreGraphics
import Foundation
import XCTest
@testable import CastReader

final class OCRWordInkBoundsTests: XCTestCase {
    private let width = 300
    private let height = 200
    private var word: CGRect { norm(100, 80, 130, 120) }
    private var previous: CGRect { norm(10, 80, 80, 120) }
    private var next: CGRect { norm(152, 80, 200, 120) }

    func testIndependentInkRecoversRaisedDigitsWithoutChangingVisionBox() throws {
        XCTAssertEqual(try measure(glyphs()), norm(103, 68, 127, 91))
        XCTAssertEqual(word, norm(100, 80, 130, 120))
    }

    func testCGImageBufferPreservesTopLeftPixelCoordinates() throws {
        let rgba = glyphs()
        let provider = try XCTUnwrap(CGDataProvider(data: Data(rgba) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                                   CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        ))
        let measurement = try XCTUnwrap(OCRWordInkBounds(image: image))
        XCTAssertEqual(measurement.measure(word: word, previous: previous, next: next), norm(103, 68, 127, 91))
    }

    func testDroppedBracketPixelsRejectOtherwiseRaisedDigits() throws {
        var rgba = glyphs()
        for y in 65...94 { set(&rgba, x: 94, y: y, color: [0, 0, 0, 255]) }
        XCTAssertNil(try measure(rgba))
    }

    func testNeighborAndImageEdgeClippingRejectIncompleteMeasurement() throws {
        var rgba = glyphs()
        for y in 80...110 { set(&rgba, x: 82, y: y, color: [0, 0, 0, 255]) }
        XCTAssertNil(try measure(rgba))
        let measurement = try XCTUnwrap(OCRWordInkBounds(rgba: glyphs(), width: width, height: height))
        XCTAssertNil(measurement.measure(word: norm(0, 80, 30, 120)))
    }

    func testLowContrastColorTransparencyAndNonuniformBackgroundAreRejected() throws {
        XCTAssertNil(try measure(glyphs(ink: [191, 191, 191, 255])))
        XCTAssertNil(try measure(glyphs(ink: [0, 0, 255, 255])))
        XCTAssertNil(try measure(glyphs(background: [255, 255, 255, 0])))
        var rgba = glyphs()
        set(&rgba, x: 82, y: 60, color: [180, 180, 180, 255])
        XCTAssertNil(try measure(rgba))
    }

    func testUniformDarkThemeRequiresTheSameCompleteHighContrastEvidence() throws {
        XCTAssertEqual(try measure(glyphs(background: [17, 17, 17, 255], ink: [238, 238, 238, 255])),
                       norm(103, 68, 127, 91))
    }

    func testMalformedAndOversizedBuffersDoNotAllocateOrSupplyEvidence() {
        XCTAssertNil(OCRWordInkBounds(rgba: [0], width: width, height: height))
        XCTAssertNil(OCRWordInkBounds(rgba: [], width: OCRWordInkBounds.maximumPixelCount + 1, height: 1))
        XCTAssertNil(OCRWordInkBounds(rgba: [], width: 0, height: height))
    }

    private func measure(_ rgba: [UInt8]) throws -> CGRect? {
        let measurement = try XCTUnwrap(OCRWordInkBounds(rgba: rgba, width: width, height: height))
        return measurement.measure(word: word, previous: previous, next: next)
    }

    private func glyphs(background: [UInt8] = [255, 255, 255, 255],
                        ink: [UInt8] = [0, 0, 0, 255]) -> [UInt8] {
        var rgba = Array(repeating: background, count: width * height).flatMap { $0 }
        for y in 68...90 {
            for x in [103, 115, 126] { set(&rgba, x: x, y: y, color: ink) }
        }
        for x in 115...126 {
            set(&rgba, x: x, y: 68, color: ink)
            set(&rgba, x: x, y: 90, color: ink)
        }
        return rgba
    }

    private func set(_ rgba: inout [UInt8], x: Int, y: Int, color: [UInt8]) {
        for component in 0..<4 { rgba[(y * width + x) * 4 + component] = color[component] }
    }

    private func norm(_ left: Int, _ top: Int, _ right: Int, _ bottom: Int) -> CGRect {
        CGRect(x: CGFloat(left) / CGFloat(width), y: 1 - CGFloat(bottom) / CGFloat(height),
               width: CGFloat(right - left) / CGFloat(width), height: CGFloat(bottom - top) / CGFloat(height))
    }
}
