import CoreGraphics
import Foundation

/// Keeps recognized text complete when Vision cannot supply one token's box.
/// Estimated boxes are display fallbacks, never evidence for deleting speech.
enum OCRTokenGeometryCoverage {
    struct Token: Equatable {
        let text: String
        let bbox: CGRect
        var bboxSource: OCRWordBoxSource = .unknown
        var sourceLineID: Int? = nil
        var recognitionConfidence: Float? = nil
        var inkBoundsNorm: CGRect? = nil
        var inkBoundsChecked: Bool = false

        func word(id: Int) -> OCRWord {
            OCRWord(id: id, text: text, bboxNorm: bbox, bboxSource: bboxSource,
                    sourceLineID: sourceLineID, recognitionConfidence: recognitionConfidence,
                    inkBoundsNorm: inkBoundsNorm, inkBoundsChecked: inkBoundsChecked)
        }
    }

    static func resolve(text: String, language: String?, lineBox: CGRect,
                        sourceLineID: Int, confidence: Float,
                        tokenBoxes: [CGRect?]) -> [Token] {
        let tokens = KindleOCRTextContract.tokens(in: text, language: language)
        let total = max(1, tokens.reduce(0) { $0 + $1.count + 1 })
        var cursor = lineBox.minX
        return tokens.enumerated().map { index, text in
            let width = lineBox.width * CGFloat(text.count + 1) / CGFloat(total)
            defer { cursor += width }
            let supplied = tokenBoxes.indices.contains(index) ? tokenBoxes[index] : nil
            if let supplied, isUsable(supplied) {
                return Token(text: text, bbox: supplied, bboxSource: .visionTextRange,
                             sourceLineID: sourceLineID, recognitionConfidence: confidence)
            }
            let estimated = CGRect(x: cursor, y: lineBox.minY,
                                   width: width * 0.92, height: lineBox.height)
            return Token(text: text, bbox: estimated, bboxSource: .proportional,
                         sourceLineID: sourceLineID, recognitionConfidence: confidence)
        }
    }

    static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull && !rect.isInfinite && rect.width > 0 && rect.height > 0 &&
            [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite)
    }

    /// Geometry reconstruction must not reorder or omit tokens using guessed
    /// boxes. Keep this engine line's text/order authoritative instead.
    static func requiresEngineLineOrder(_ tokens: [Token]) -> Bool {
        tokens.contains { $0.bboxSource == .proportional }
    }
}
