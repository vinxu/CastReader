import Foundation
import PDFKit
import UIKit
import XCTest
@testable import CastReader

final class PDFImportMemoryTests: XCTestCase {
    func testScannedAndNativePagesSurviveMixedPDFImport() async throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(bounds)
            ("Scanned page contains readable words." as NSString).draw(
                in: CGRect(x: 40, y: 80, width: 520, height: 400),
                withAttributes: [.font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black])
        }
        let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            ("Native page contains searchable text." as NSString).draw(
                at: CGPoint(x: 24, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            context.beginPage()
            image.draw(in: bounds)
            context.beginPage() // A genuine blank page does not create OCR text.
        }
        let result = try await DocumentBuilder.fromPDFWithOCR(data: data)
        let document = try XCTUnwrap(result)
        XCTAssertTrue(document.paragraphs.contains { $0.pdfPageIndex == 0 && $0.text.contains("Native page") })
        XCTAssertTrue(document.paragraphs.contains { $0.pdfPageIndex == 1 && $0.text.contains("Scanned page") })
        XCTAssertFalse(document.paragraphs.contains { $0.pdfPageIndex == 2 })
        XCTAssertTrue(document.usesNativeTextRendering)
        XCTAssertEqual(document.fileData, data)
    }

    func testSearchablePDFWithBlankPageKeepsOriginalTextRanges() async throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage()
            ("Searchable native PDF keeps the original page layout." as NSString).draw(
                at: CGPoint(x: 24, y: 24), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
            context.beginPage()
        }
        let result = try await DocumentBuilder.fromPDFWithOCR(data: data)
        let document = try XCTUnwrap(result)
        XCTAssertTrue(document.usesNativePDFRendering)
        XCTAssertTrue(document.paragraphs.allSatisfy { $0.pdfPageIndex == 0 && $0.pdfRange != nil })
    }

    func testCancelledRasterDoesNotAllocateAnImage() async throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { $0.beginPage() }
        let operation = Task.detached {
            let pdf = try XCTUnwrap(PDFDocument(data: data))
            let page = try XCTUnwrap(pdf.page(at: 0))
            withUnsafeCurrentTask { $0?.cancel() }
            return try DocumentBuilder.renderPDFPageForOCRCancellable(page)
        }
        do {
            _ = try await operation.value
            XCTFail("A cancelled PDF renderer must stop before allocating its bitmap")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testPDFOCRRasterIsBoundedInPixelsOnRetinaDisplays() throws {
        for size in [CGSize(width: 612, height: 792), CGSize(width: 792, height: 612), CGSize(width: 2000, height: 3000)] {
            let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
                context.beginPage()
                ("Readable PDF raster" as NSString).draw(at: CGPoint(x: 24, y: 24),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            }
            let pdf = try XCTUnwrap(PDFDocument(data: data))
            let page = try XCTUnwrap(pdf.page(at: 0))
            let image = try XCTUnwrap(DocumentBuilder.renderPDFPageForOCRCancellable(page))
            let cg = try XCTUnwrap(image.cgImage)
            print("PDF RASTER points=\(size) pixels=\(cg.width)x\(cg.height) bytes=\(cg.bytesPerRow * cg.height) scale=\(image.scale)")
            XCTAssertLessThanOrEqual(max(cg.width, cg.height), 2800)
            XCTAssertEqual(image.scale, 1)
            XCTAssertLessThanOrEqual(cg.bitsPerPixel, 32)
        }
    }

    func testReportedMoneyPDFImportsEveryPageWithoutExcessiveRasterMemory() async throws {
        guard let path = ProcessInfo.processInfo.environment["CASTREADER_PDF_REGRESSION_PATH"] else {
            throw XCTSkip("Set CASTREADER_PDF_REGRESSION_PATH to the private reproduction PDF.")
        }
        let start = Date()
        let initial = PDFImportMemorySample.bytes()
        let monitor = Task.detached { () -> UInt64 in
            var peak = PDFImportMemorySample.bytes()
            while !Task.isCancelled {
                peak = max(peak, PDFImportMemorySample.bytes())
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return peak
        }
        defer { monitor.cancel() }
        let result = try await DocumentImportPipeline().importDocument(
            DocumentImportRequest(localURL: URL(fileURLWithPath: path, relativeTo:
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!))
        )
        monitor.cancel()
        let peak = await monitor.value
        let document = result.document
        XCTAssertEqual(document.sourceKind, .pdf)
        XCTAssertFalse(document.isEmpty)
        XCTAssertEqual(document.paragraphs.map(\.id), Array(document.paragraphs.indices))
        XCTAssertEqual(document.paragraphs.compactMap(\.pdfPageIndex).max(), 241)
        XCTAssertTrue(document.paragraphs.contains { $0.pdfPageIndex == 0 && $0.text.localizedCaseInsensitiveContains("psychology") })
        let pages = Set(document.paragraphs.compactMap(\.pdfPageIndex))
        XCTAssertEqual(pages, Set((0..<242).filter { $0 != 7 }), "Only source page 8 is blank")
        // A regression ceiling for this exact reproduction fixture, not a claim
        // about the OS's device-specific jetsam limit. The old path used 4 GiB.
        XCTAssertLessThan(peak, 1_024 * 1_024 * 1_024)
        let report: [String: Any] = ["seconds": Date().timeIntervalSince(start), "initialBytes": initial,
            "peakBytes": peak, "finalBytes": PDFImportMemorySample.bytes(),
            "paragraphs": document.paragraphs.count, "pagesWithText": pages.sorted()]
        print("PDF IMPORT \(report)")
        if let output = ProcessInfo.processInfo.environment["CASTREADER_PDF_REGRESSION_REPORT"] {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output, relativeTo:
                    FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!))
        }
    }

}

private enum PDFImportMemorySample {
    static func bytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
