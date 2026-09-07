import CoreGraphics
import Foundation

/// Independent, conservative pixel evidence for a Vision text-range box. Vision
/// may return the entire line's vertical extent for a raised digit. A clean
/// perimeter and separation from neighboring words are required before using
/// ink geometry; missing brackets, clipped glyphs and uncertain colors reject it.
struct OCRWordInkBounds {
    static let maximumPixelCount = 4_000_000
    let width: Int
    let height: Int
    private let rgba: [UInt8]

    init?(image: CGImage) {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= Self.maximumPixelCount / height else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.rgba = pixels
    }

    /// Raw RGBA rows are top-to-bottom. This entry point also makes malformed
    /// buffers and edge/color rejection independently testable without Vision.
    init?(rgba: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0, width <= Self.maximumPixelCount / height,
              rgba.count == width * height * 4 else { return nil }
        self.width = width
        self.height = height
        self.rgba = rgba
    }

    func measure(word: CGRect, previous: CGRect? = nil, next: CGRect? = nil) -> CGRect? {
        guard isNormalizedBox(word), previous.map(isNormalizedBox) ?? true,
              next.map(isNormalizedBox) ?? true else { return nil }
        let box = pixels(word)
        let boxHeight = Int(ceil(box.height))
        guard boxHeight >= 8, box.width >= 3 else { return nil }
        let padding = max(5, boxHeight / 2)
        let left = max(Int(floor(box.minX)) - padding, previous.map { Int(ceil(pixels($0).maxX)) + 2 } ?? 0)
        let right = min(Int(ceil(box.maxX)) + padding, next.map { Int(floor(pixels($0).minX)) - 2 } ?? width)
        let top = Int(floor(box.minY)) - padding
        let bottom = Int(ceil(box.maxY)) + padding
        // Image/crop boundaries do not prove that an entire glyph was measured.
        guard left >= 1, top >= 1, right < width, bottom < height,
              CGFloat(left) < box.minX, CGFloat(right) > box.maxX,
              right - left >= 5, bottom - top >= 5,
              (right - left) <= 200_000 / (bottom - top) else { return nil }
        let background = color(left, top)
        let corners = [background, color(right - 1, top), color(left, bottom - 1), color(right - 1, bottom - 1)]
        guard corners.allSatisfy({ $0.a >= 250 && $0.distance(to: background) <= 18 }),
              background.chroma <= 18,
              background.luminance <= 55 || background.luminance >= 210 else { return nil }

        var inkLeft = right
        var inkTop = bottom
        var inkRight = left
        var inkBottom = top
        var count = 0
        for y in top..<bottom {
            for x in left..<right {
                let value = color(x, y)
                if x == left || x == right - 1 || y == top || y == bottom - 1 {
                    guard value.a >= 250, value.distance(to: background) <= 24 else { return nil }
                }
                let hasContrast = background.luminance >= 210
                    ? value.luminance <= background.luminance - 80
                    : value.luminance >= background.luminance + 100
                guard hasContrast else { continue }
                // Colored/translucent foreground needs a separate proof. Keep
                // its text instead of treating a partial grayscale mask as ink.
                guard value.a >= 250, value.chroma <= 24 else { return nil }
                inkLeft = min(inkLeft, x)
                inkTop = min(inkTop, y)
                inkRight = max(inkRight, x + 1)
                inkBottom = max(inkBottom, y + 1)
                count += 1
            }
        }
        guard count >= 8, inkRight > inkLeft, inkBottom > inkTop else { return nil }
        let tolerance = CGFloat(max(2, boxHeight / 14))
        // Includes untranscribed brackets beside digits: broadening OCR's
        // horizontal ownership would silently delete punctuation it missed.
        guard CGFloat(inkLeft) >= box.minX - tolerance,
              CGFloat(inkRight) <= box.maxX + tolerance else { return nil }
        let coverage = Double(count) / Double((inkRight - inkLeft) * (inkBottom - inkTop))
        guard (0.02...0.85).contains(coverage) else { return nil }
        return CGRect(x: CGFloat(inkLeft) / CGFloat(width),
                      y: 1 - CGFloat(inkBottom) / CGFloat(height),
                      width: CGFloat(inkRight - inkLeft) / CGFloat(width),
                      height: CGFloat(inkBottom - inkTop) / CGFloat(height))
    }

    private func pixels(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * CGFloat(width), y: (1 - rect.maxY) * CGFloat(height),
               width: rect.width * CGFloat(width), height: rect.height * CGFloat(height))
    }

    private func isNormalizedBox(_ rect: CGRect) -> Bool {
        OCRTokenGeometryCoverage.isUsable(rect) && rect.minX >= 0 && rect.minY >= 0 &&
            rect.maxX <= 1 && rect.maxY <= 1
    }

    private struct Color {
        let r: Int, g: Int, b: Int, a: Int
        var luminance: Int { (r * 299 + g * 587 + b * 114) / 1000 }
        var chroma: Int { max(r, max(g, b)) - min(r, min(g, b)) }
        func distance(to other: Color) -> Int {
            max(abs(r - other.r), max(abs(g - other.g), abs(b - other.b)))
        }
    }

    private func color(_ x: Int, _ y: Int) -> Color {
        let offset = (y * width + x) * 4
        return Color(r: Int(rgba[offset]), g: Int(rgba[offset + 1]),
                     b: Int(rgba[offset + 2]), a: Int(rgba[offset + 3]))
    }
}
