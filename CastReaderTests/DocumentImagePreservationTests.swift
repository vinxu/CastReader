import XCTest
import UIKit
import SwiftUI
import PDFKit
import WebKit
import ZIPFoundation
@testable import CastReader

@MainActor
final class DocumentImagePreservationTests: XCTestCase {
    private func image() -> Data {
        UIGraphicsImageRenderer(size: CGSize(width: 320, height: 160)).pngData { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 320, height: 160))
            UIColor.systemBlue.setStroke()
            let path = UIBezierPath(); path.move(to: CGPoint(x: 15, y: 135))
            path.addLine(to: CGPoint(x: 100, y: 110)); path.addLine(to: CGPoint(x: 210, y: 75))
            path.addLine(to: CGPoint(x: 300, y: 15)); path.lineWidth = 5; path.stroke()
        }
    }

    private func epub(_ body: String) throws -> Data {
        let archive = try Archive(accessMode: .create)
        let entries: [String: Data] = [
            "mimetype": Data("application/epub+zip".utf8),
            "META-INF/container.xml": Data("<container><rootfiles><rootfile full-path='OEBPS/content.opf'/></rootfiles></container>".utf8),
            "OEBPS/content.opf": Data("""
            <package><metadata><title>Illustrations</title></metadata><manifest>
            <item id="chapter" href="Text/chapter.xhtml" media-type="application/xhtml+xml"/>
            <item id="chart" href="Images/chart.png" media-type="image/png"/>
            <item id="encoded" href="Images/图表.png" media-type="image/png"/>
            <item id="vector" href="Images/vector.svg" media-type="image/svg+xml"/>
            </manifest><spine><itemref idref="chapter"/></spine></package>
            """.utf8),
            "OEBPS/Text/chapter.xhtml": Data(("<html><body>" + body + "</body></html>").utf8),
            "OEBPS/Images/chart.png": image(),
            "OEBPS/Images/图表.png": image(),
            "OEBPS/Images/vector.svg": Data("<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 320 160'><image href='chart.png' width='320' height='160'/></svg>".utf8)
        ]
        for (name, data) in entries {
            try archive.addEntry(with: name, type: .file, uncompressedSize: Int64(data.count), provider: { offset, count in
                data.subdata(in: Int(offset)..<(Int(offset) + count))
            })
        }
        return try XCTUnwrap(archive.data)
    }

    func testScreenshotPatternPreservesTwoChartsAndCaptionsInOrder() throws {
        let data = try epub("""
        <p>Table 1-1. AVERAGE ANNUAL RETURN</p><p><img src='../Images/chart.png'/></p>
        <p><img src='../Images/chart.png' alt=''/></p><p>FIGURE 1-1</p><p>After the illustration.</p>
        """)
        let doc = try XCTUnwrap(DocumentBuilder.fromEPUB(data: data, title: "Sample"))
        XCTAssertEqual(doc.paragraphs.map(\.type), [.paragraph, .image, .image, .paragraph, .paragraph])
        XCTAssertEqual(doc.paragraphs[0].text, "Table 1-1. AVERAGE ANNUAL RETURN")
        XCTAssertEqual(doc.paragraphs[3].text, "FIGURE 1-1")
        XCTAssertTrue(doc.paragraphs.filter { $0.type == .image }.allSatisfy { UIImage(data: $0.imageData!) != nil })
        XCTAssertEqual(doc.paragraphs.map(\.id), Array(doc.paragraphs.indices))
        XCTAssertEqual(doc.readableParagraphs.count, 3)
        XCTAssertEqual(doc.fileData, data)
    }

    func testInlineRepeatedFigureImagesAndTableCellsSurvive() throws {
        let doc = try XCTUnwrap(DocumentBuilder.fromEPUB(data: epub("""
        <p>Before <a><img src='../Images/chart.png' alt='图'/></a> after.</p>
        <figure><img src='../Images/chart.png'/><img src='../Images/chart.png'/><figcaption>Both charts</figcaption></figure>
        <table><caption>Annual returns</caption><tr><th>Asset</th><th>Return</th></tr><tr><td>Stocks</td><td>19.2%</td></tr>
        <tr><td><img src='../Images/chart.png'/></td><td>Table chart</td></tr></table>
        <div>Embedded example <img src='../Images/chart.png'/> final text.</div>
        """), title: "Sample"))
        XCTAssertEqual(doc.paragraphs.filter { $0.type == .image }.count, 5)
        XCTAssertEqual(doc.paragraphs.prefix(3).map(\.text), ["Before", "", "after."])
        for text in ["Both charts", "Annual returns", "Asset | Return", "Stocks | 19.2%", "Table chart", "final text."] {
            XCTAssertTrue(doc.fullText.contains(text), text)
        }
    }

    func testSVGWrapperVectorResourceEncodedPathsAndDataImages() throws {
        let inline = "data:image/png;base64," + image().base64EncodedString()
        let doc = try XCTUnwrap(DocumentBuilder.fromEPUB(data: epub("""
        <p>Figures</p>
        <svg viewBox='0 0 320 160'><image xlink:href='../Images/chart.png' width='320' height='160'/></svg>
        <p><img src='../Images/vector.svg'/></p>
        <img src='../Images/%E5%9B%BE%E8%A1%A8.png#image'/>
        <img src='\(inline)'/>
        """), title: "Sample"))
        let images = doc.paragraphs.filter { $0.type == .image }.compactMap(\.imageData)
        XCTAssertEqual(images.count, 4)
        XCTAssertTrue(EpubImageResource.isSVG(images[0]))
        XCTAssertTrue(EpubImageResource.isSVG(images[1]))
        for svg in images.prefix(2) {
            let source = String(decoding: svg, as: UTF8.self)
            XCTAssertTrue(source.contains("data:image/png;base64,"))
            XCTAssertEqual(EpubImageResource.svgAspectRatio(svg), 2, accuracy: 0.001)
        }
        XCTAssertNotNil(UIImage(data: images[2]))
        XCTAssertNotNil(UIImage(data: images[3]))
    }

    func testSVGDoesNotLoadActiveOrRemoteContent() throws {
        let source = Data("<svg viewBox='0 0 200 100' onload='alert(1)'><script>alert(1)</script><foreignObject>bad</foreignObject><image href='https://example.com/tracker'/><path d='M0 0 L200 100'/></svg>".utf8)
        let data = try XCTUnwrap(EpubImageResource.svg(source, resolve: { _ in nil }))
        let sanitized = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(sanitized.contains("alert"))
        XCTAssertFalse(sanitized.contains("example.com"))
        XCTAssertTrue(sanitized.contains("<path"))
    }

    func testStandaloneVectorIllustrationActuallyPaints() async throws {
        let data = try XCTUnwrap(EpubImageResource.svg(Data("<svg viewBox='0 0 200 100'><rect width='200' height='100' fill='#127cbb'/></svg>".utf8), resolve: { _ in nil }))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let prior = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        let host = UIHostingController(rootView: EpubSVGView(data: data).frame(width: 400, height: 200))
        window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; prior?.makeKeyAndVisible() }
        func web(_ view: UIView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap(web).first
        }
        host.view.layoutIfNeeded()
        let deadline = Date().addingTimeInterval(10)
        var target: WKWebView?
        while Date() < deadline {
            target = web(host.view)
            if let target, !target.isLoading, target.url != nil { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let browser = try XCTUnwrap(target)
        try await Task.sleep(nanoseconds: 250_000_000)
        let snapshot = try await browser.takeSnapshot(configuration: nil)
        let cg = try XCTUnwrap(snapshot.cgImage)
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThan(pixel[0], 50)
        XCTAssertGreaterThan(pixel[1], 80)
        XCTAssertGreaterThan(pixel[2], 150)
        let attachment = XCTAttachment(image: snapshot); attachment.name = "standalone-svg-painted"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    private func pdf() -> Data {
        let size = CGSize(width: 400, height: 600)
        let scan = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            ("Scanned chapter\n\nThe chart remains on the original page.\nReading follows the printed words." as NSString).draw(
                in: CGRect(x: 30, y: 45, width: 340, height: 200),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.black])
            UIImage(data: image())!.draw(in: CGRect(x: 30, y: 300, width: 340, height: 170))
        }
        return UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage() // Image-only cover used to force whole-book reflow.
            UIImage(data: image())!.draw(in: CGRect(x: 30, y: 200, width: 340, height: 170))
            context.beginPage()
            ("Searchable chapter. The original chart must stay visible." as NSString).draw(
                in: CGRect(x: 30, y: 45, width: 340, height: 180),
                withAttributes: [.font: UIFont.systemFont(ofSize: 22), .foregroundColor: UIColor.black])
            UIImage(data: image())!.draw(in: CGRect(x: 30, y: 300, width: 340, height: 170))
            context.beginPage(); scan.draw(at: .zero)
            context.beginPage() // Blank separator must remain a visible PDF page.
        }
    }

    func testMixedPDFKeepsOriginalPagesNativeRangesAndOCRGeometry() async throws {
        let bytes = pdf()
        let parsed = try await DocumentBuilder.fromPDFWithOCR(data: bytes)
        let doc = try XCTUnwrap(parsed)
        XCTAssertTrue(doc.usesNativePDFRendering)
        XCTAssertFalse(doc.usesNativeTextRendering)
        XCTAssertEqual(doc.fileData, bytes)
        XCTAssertEqual(PDFDocument(data: try XCTUnwrap(doc.fileData))?.pageCount, 4)
        let searchable = doc.paragraphs.filter { $0.pdfPageIndex == 1 }
        XCTAssertFalse(searchable.isEmpty)
        XCTAssertTrue(searchable.allSatisfy { $0.pdfRange != nil })
        let scanned = doc.paragraphs.filter { $0.pdfPageIndex == 2 }
        XCTAssertTrue(scanned.map(\.text).joined(separator: " ").contains("original page"))
        XCTAssertTrue(scanned.allSatisfy { $0.pdfRange == nil && !$0.words.isEmpty })
        XCTAssertTrue(scanned.flatMap(\.words).allSatisfy { CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.bboxNorm) })
        let attachment = XCTAttachment(data: bytes, uniformTypeIdentifier: "com.adobe.pdf")
        attachment.name = "mixed-original-pages"; attachment.lifetime = .keepAlways; add(attachment)
        try await assertColdReopen(doc)
    }

    func testSparseScannedTextIsNotDiscardedAsBlank() async throws {
        let size = CGSize(width: 612, height: 792)
        let scan = UIGraphicsImageRenderer(size: size).image { context in
            UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
            ("A sparsely printed page still needs its words." as NSString).draw(at: CGPoint(x: 36, y: 400),
                withAttributes: [.font: UIFont.systemFont(ofSize: 15), .foregroundColor: UIColor.black])
        }
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            context.beginPage(); scan.draw(at: .zero)
            context.beginPage()
        }
        let parsed = try await DocumentBuilder.fromPDFWithOCR(data: bytes)
        let doc = try XCTUnwrap(parsed)
        XCTAssertTrue(doc.usesNativePDFRendering)
        XCTAssertTrue(doc.fullText.contains("sparsely printed"), doc.fullText)
        XCTAssertTrue(doc.paragraphs.allSatisfy { $0.pdfPageIndex == 0 && !$0.words.isEmpty })
    }

    private func assertColdReopen(_ doc: ReadingDocument) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(directory: directory)
        history.record(doc)
        let rec = try XCTUnwrap(history.records.first)
        _ = try await history.reopen(rec)
        let cold = HistoryStore(directory: directory)
        let reopened = try await cold.reopen(try XCTUnwrap(cold.records.first))
        XCTAssertEqual(reopened?.paragraphs, doc.paragraphs)
        XCTAssertEqual(reopened?.fileData, doc.fileData)
        XCTAssertEqual(reopened?.usesNativePDFRendering, doc.usesNativePDFRendering)
    }

    func testOldEPUBCacheRebuildsImagesOnColdOpen() async throws {
        let bytes = try epub("<p>Before.</p><p><img src='../Images/chart.png'/></p><p>After.</p>")
        let doc = try XCTUnwrap(DocumentBuilder.fromEPUB(data: bytes, title: "Sample"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let history = HistoryStore(directory: directory)
        var legacy = doc
        legacy.paragraphs = doc.paragraphs.filter { $0.type != .image }.enumerated().map {
            ReadingParagraph(id: $0.offset, text: $0.element.text, type: $0.element.type)
        }
        history.record(legacy)
        let checkpoint = try XCTUnwrap(ReadingResumeDocumentIndex(paragraphs: legacy.paragraphs)
            .checkpoint(sourceKind: .epub, paragraphIndex: 1, audio: nil))
        XCTAssertTrue(history.saveReadingCheckpoint(checkpoint, for: legacy.id, boundary: history.progressBoundaryToken))
        let record = try XCTUnwrap(history.records.first)
        _ = try await history.reopen(record)
        let cacheURL = LocalDocumentCache.url(id: record.id, in: directory)
        var plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: cacheURL), format: nil) as? [String: Any])
        plist["version"] = 2 // The shipped parser cached a document with missing illustrations.
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: cacheURL)
        let cold = HistoryStore(directory: directory)
        let reopened = try await cold.reopen(record)
        let resumed = ReadAloudViewModel(document: try XCTUnwrap(reopened), historyStore: cold)
        XCTAssertEqual(resumed.currentParagraphIndex, 2, "Inserted image must not move the saved reading position")
        XCTAssertNil(resumed.resumeNotice)
        resumed.stop()
        XCTAssertEqual(reopened?.paragraphs.filter { $0.type == .image }.count, 1)
        let snapshot = try PropertyListDecoder().decode(LocalDocumentCache.Snapshot.self, from: Data(contentsOf: cacheURL))
        XCTAssertEqual(snapshot.version, LocalDocumentCache.parserVersion)
        try await assertColdReopen(doc)
    }

    func testOCRPageTransformHandlesRotationAndOffsetCrop() throws {
        let pdf = try XCTUnwrap(PDFDocument(data: pdf()))
        let page = try XCTUnwrap(pdf.page(at: 2))
        page.setBounds(CGRect(x: 20, y: 30, width: 350, height: 500), for: .cropBox)
        for rotation in [0, 90, 180, 270] {
            page.rotation = rotation
            let reloaded = try XCTUnwrap(PDFDocument(data: pdf.dataRepresentation()!))
            let actual = try XCTUnwrap(reloaded.page(at: 2))
            let rendered = try XCTUnwrap(PDFOCRGeometry.render(actual))
            let expected = CGRect(x: 50, y: 100, width: 100, height: 40)
            let pixels = expected.applying(rendered.pageToImage)
            XCTAssertEqual(pixels.width, rotation % 180 == 0 ? 300 : 120, accuracy: 0.01)
            XCTAssertEqual(pixels.height, rotation % 180 == 0 ? 120 : 300, accuracy: 0.01)
            let normalized = CGRect(x: pixels.minX / rendered.size.width, y: pixels.minY / rendered.size.height,
                                    width: pixels.width / rendered.size.width, height: pixels.height / rendered.size.height)
            let restored = PDFOCRGeometry.pageRect(rendered.normalizedPageRect(normalized), page: actual)
            XCTAssertEqual(restored.minX, expected.minX, accuracy: 0.01)
            XCTAssertEqual(restored.minY, expected.minY, accuracy: 0.01)
            XCTAssertEqual(restored.width, expected.width, accuracy: 0.01)
            XCTAssertEqual(restored.height, expected.height, accuracy: 0.01)
            XCTAssertLessThanOrEqual(max(rendered.image.size.width, rendered.image.size.height), 2800)
        }
    }

    func testOCRRasterFillsRequestedResolution() throws {
        let bytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { context in
            context.beginPage()
            UIColor.blue.setFill()
            context.cgContext.fill(CGRect(x: 20, y: 30, width: 100, height: 80))
        }
        let document = try XCTUnwrap(PDFDocument(data: bytes))
        let rendered = try XCTUnwrap(PDFOCRGeometry.render(try XCTUnwrap(document.page(at: 0))))
        let cg = try XCTUnwrap(rendered.image.cgImage)
        XCTAssertEqual(cg.width, 1200)
        XCTAssertEqual(cg.height, 1800)
        // This patch is near the page corner. A centered, unscaled PDF raster
        // leaves it white even if forward/inverse coordinate roundtrips pass.
        let patch = try XCTUnwrap(cg.cropping(to: CGRect(x: 90, y: 120, width: 60, height: 60)))
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(patch, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertLessThan(pixel[0], 10)
        XCTAssertLessThan(pixel[1], 10)
        XCTAssertGreaterThan(pixel[2], 245)
    }

    func testOCRHighlightsUseOriginalPageGeometry() throws {
        let bytes = pdf()
        let paragraph = ReadingParagraph(id: 0, text: "Chart remains", words: [
            OCRWord(id: 0, text: "Chart", bboxNorm: CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.05)),
            OCRWord(id: 1, text: "remains", bboxNorm: CGRect(x: 0.4, y: 0.7, width: 0.3, height: 0.05))
        ], pdfPageIndex: 2)
        let doc = ReadingDocument(title: "Scanned", sourceKind: .pdf, paragraphs: [paragraph], fileData: bytes)
        let view = PDFView(); view.document = PDFDocument(data: bytes)
        let coordinator = PDFReaderView.Coordinator(); coordinator.pdfView = view
        let read = ReadAloudViewModel(document: doc); let explain = ExplainViewModel(document: doc)
        read.currentParagraphIndex = 0
        coordinator.attach(readVM: read, explainVM: explain, doc: doc)
        coordinator.highlight(0)
        let page = try XCTUnwrap(view.document?.page(at: 2))
        XCTAssertEqual(page.annotations.count, 2)
        coordinator.highlightWord(PDFWordHighlight(paragraphIndex: 0, words: ["Chart", "remains"], wordIndex: 1))
        XCTAssertEqual(page.annotations.count, 3)
        let word = try XCTUnwrap(page.annotations.last)
        XCTAssertEqual(word.bounds.minX, 160, accuracy: 0.1)
        XCTAssertEqual(word.bounds.minY, 420, accuracy: 0.1)
        XCTAssertEqual(word.bounds.width, 120, accuracy: 0.1)
        XCTAssertEqual(PDFOCRGeometry.rects(paragraph, page: page, characterRange: 6..<13).count, 1)
        coordinator.highlightWord(PDFWordHighlight(paragraphIndex: 0, words: ["Chart remains"], wordIndex: 0))
        XCTAssertEqual(page.annotations.count, 4, "A spoken phrase can span multiple OCR boxes")
        coordinator.highlightWord(PDFWordHighlight(paragraphIndex: 0, words: ["unmatched"], wordIndex: 0))
        XCTAssertEqual(page.annotations.count, 2, "An unmatched token must clear the prior word highlight")
    }
}
