import UIKit
import PDFKit

/// OCR operates on the displayed (rotated/cropped) page. Persist its boxes in
/// unrotated PDF page coordinates, normalized to cropBox, for PDF annotations.
enum PDFOCRGeometry {
    struct RenderedPage {
        let image: UIImage
        let size: CGSize
        let bounds: CGRect
        let pageToImage: CGAffineTransform

        func normalizedPageRect(_ rect: CGRect) -> CGRect {
            let pixels = CGRect(x: rect.minX * size.width, y: rect.minY * size.height,
                                width: rect.width * size.width, height: rect.height * size.height)
            let page = pixels.applying(pageToImage.inverted())
            return CGRect(x: (page.minX - bounds.minX) / bounds.width,
                          y: (page.minY - bounds.minY) / bounds.height,
                          width: page.width / bounds.width, height: page.height / bounds.height)
        }
    }

    static func render(_ page: PDFPage) -> RenderedPage? {
        guard let reference = page.pageRef else { return nil }
        let bounds = reference.getBoxRect(.cropBox)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let rotated = abs(page.rotation % 180) == 90
        let width = rotated ? bounds.height : bounds.width
        let height = rotated ? bounds.width : bounds.height
        let scale = min(3, 2800 / max(width, height))
        let size = CGSize(width: width * scale, height: height * scale)
        // CGPDFPage's drawing transform centers small pages without scaling them
        // up. Resolve crop/rotation at page size, then explicitly apply the OCR
        // pixel scale so small print fills the higher-resolution raster.
        let transform = reference.getDrawingTransform(
            .cropBox, rect: CGRect(x: 0, y: 0, width: width, height: height),
            rotate: 0, preserveAspectRatio: true
        ).concatenating(CGAffineTransform(scaleX: scale, y: scale))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // Bound actual pixels, independently of screen scale.
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            context.cgContext.concatenate(transform)
            context.cgContext.drawPDFPage(reference)
        }
        return RenderedPage(image: image, size: size, bounds: bounds, pageToImage: transform)
    }

    static func pageRect(_ rect: CGRect, page: PDFPage) -> CGRect {
        let bounds = page.pageRef?.getBoxRect(.cropBox) ?? page.bounds(for: .cropBox)
        return CGRect(x: bounds.minX + rect.minX * bounds.width,
                      y: bounds.minY + rect.minY * bounds.height,
                      width: rect.width * bounds.width, height: rect.height * bounds.height)
    }

    static func rects(_ paragraph: ReadingParagraph, page: PDFPage,
                      characterRange: Range<Int>? = nil) -> [CGRect] {
        let indexes = characterRange.map { OCRWordAligner.wordIndexes(overlapping: $0, in: paragraph) }
            ?? Array(paragraph.words.indices)
        let boxes = indexes.map { pageRect(paragraph.words[$0].bboxNorm, page: page) }
        if !boxes.isEmpty { return boxes }
        if characterRange == nil, let bounds = paragraph.bboxNorm { return [pageRect(bounds, page: page)] }
        return []
    }
}
