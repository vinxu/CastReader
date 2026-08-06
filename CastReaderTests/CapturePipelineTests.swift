//
//  CapturePipelineTests.swift
//  CastReaderTests
//
//  采集质量层（透视矫正判据、清晰度评估）与多页合并的回归集。
//

import UIKit
import XCTest
@testable import CastReader

final class CapturePipelineTests: XCTestCase {

    // MARK: - 文档四边形判据

    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 1400)

    func testPlausibleDocumentAcceptsSlightPerspective() {
        // 略带梯形畸变的一页纸：顶边比底边窄一点，仍应矫正。
        XCTAssertTrue(ImagePreprocessor.isPlausibleDocument(
            topLeft: CGPoint(x: 120, y: 1300),
            topRight: CGPoint(x: 880, y: 1310),
            bottomLeft: CGPoint(x: 80, y: 100),
            bottomRight: CGPoint(x: 920, y: 90),
            extent: frame
        ))
    }

    func testPlausibleDocumentRejectsTinyQuad() {
        // 只占画面一小块 —— 多半是误检（桌面上的一张便签、画里的相框）。
        XCTAssertFalse(ImagePreprocessor.isPlausibleDocument(
            topLeft: CGPoint(x: 400, y: 700),
            topRight: CGPoint(x: 600, y: 700),
            bottomLeft: CGPoint(x: 400, y: 500),
            bottomRight: CGPoint(x: 600, y: 500),
            extent: frame
        ))
    }

    func testPlausibleDocumentRejectsExtremePerspective() {
        // 顶边只有底边的三分之一：矫正后会被严重拉伸，宁可不动。
        XCTAssertFalse(ImagePreprocessor.isPlausibleDocument(
            topLeft: CGPoint(x: 400, y: 1300),
            topRight: CGPoint(x: 600, y: 1300),
            bottomLeft: CGPoint(x: 50, y: 100),
            bottomRight: CGPoint(x: 950, y: 100),
            extent: frame
        ))
    }

    func testPlausibleDocumentRejectsDegenerateExtent() {
        XCTAssertFalse(ImagePreprocessor.isPlausibleDocument(
            topLeft: .zero, topRight: .zero, bottomLeft: .zero, bottomRight: .zero,
            extent: .zero
        ))
    }

    // MARK: - 清晰度

    func testSharpnessSeparatesFlatAndDetailedImages() {
        let flat = Self.solidImage(size: CGSize(width: 600, height: 600))
        let detailed = Self.checkerboardImage(size: CGSize(width: 600, height: 600), cell: 6)

        let flatScore = ImagePreprocessor.sharpness(of: flat)
        let detailedScore = ImagePreprocessor.sharpness(of: detailed)

        XCTAssertLessThan(flatScore, ImagePreprocessor.Tuning.minSharpness,
                          "纯色图没有边缘，必须判为模糊")
        XCTAssertGreaterThan(detailedScore, ImagePreprocessor.Tuning.minSharpness,
                             "高对比细节必须判为清晰")
    }

    func testAssessFlagsLowResolution() {
        let small = Self.checkerboardImage(size: CGSize(width: 320, height: 240), cell: 4)
        let quality = ImagePreprocessor.assess(small)

        XCTAssertFalse(quality.isUsable)
        XCTAssertNotNil(quality.advice)
        XCTAssertEqual(quality.shortestSide, 240)
    }

    func testAssessAcceptsLargeSharpImage() {
        let large = Self.checkerboardImage(size: CGSize(width: 1600, height: 1200), cell: 8)
        let quality = ImagePreprocessor.assess(large)

        XCTAssertTrue(quality.isUsable, "advice=\(quality.advice ?? "-") sharpness=\(quality.sharpness)")
        XCTAssertNil(quality.advice)
    }

    // MARK: - 多页合并

    func testMergedPagesBecomeContinuousTextDocument() {
        let first = ReadingDocument(
            title: "第一页",
            sourceKind: .photo,
            language: "en",
            paragraphs: [
                ReadingParagraph(id: 0, text: "page one para one"),
                ReadingParagraph(id: 1, text: "page one para two")
            ]
        )
        let second = ReadingDocument(
            title: "第二页",
            sourceKind: .photo,
            language: "en",
            paragraphs: [ReadingParagraph(id: 0, text: "page two para one")]
        )

        let merged = CaptureFlowViewModel.merged([first, second])

        XCTAssertEqual(merged.sourceKind, .text, "多页是一份文件，不是一张照片")
        XCTAssertEqual(merged.paragraphs.map(\.text),
                       ["page one para one", "page one para two", "page two para one"])
        XCTAssertEqual(merged.paragraphs.map(\.id), [0, 1, 2], "段落 id 必须连续，否则 mark 锚定会错位")
        XCTAssertEqual(merged.title, "第一页")
        XCTAssertEqual(merged.language, "en")
    }

    func testMergedSkipsUnreadableAndEmptyParagraphs() {
        let document = ReadingDocument(
            title: "扫描",
            sourceKind: .photo,
            language: "en",
            paragraphs: [
                ReadingParagraph(id: 0, text: "keep me"),
                ReadingParagraph(id: 1, text: "   "),
                ReadingParagraph(id: 2, text: "cover", type: .image)
            ]
        )

        let merged = CaptureFlowViewModel.merged([document])
        XCTAssertEqual(merged.paragraphs.map(\.text), ["keep me"])
    }

    // MARK: - 失败提示

    func testFailureMessageAppendsAdviceOnlyWhenPresent() {
        XCTAssertEqual(CaptureFlowViewModel.message(for: "未识别到文字", advice: nil), "未识别到文字")
        XCTAssertEqual(CaptureFlowViewModel.message(for: "未识别到文字", advice: ""), "未识别到文字")
        XCTAssertEqual(
            CaptureFlowViewModel.message(for: "未识别到文字", advice: "画面有点模糊"),
            "未识别到文字\n画面有点模糊"
        )
    }

    // MARK: - 选区裁剪

    /// Vision bbox（原点左下）→ layout（原点左上）的翻转不能搞反，
    /// 否则用户框上半页会读到下半页。
    func testLayoutRectFlipsVisionOrigin() {
        let visionTopBand = CGRect(x: 0.1, y: 0.8, width: 0.3, height: 0.1)
        let layout = PhotoRegionCropper.layoutRect(fromVision: visionTopBand)
        XCTAssertEqual(layout.minY, 0.1, accuracy: 0.0001, "Vision 的高 y 是画面上方")
        XCTAssertEqual(layout.minX, 0.1, accuracy: 0.0001)
        XCTAssertEqual(layout.height, 0.1, accuracy: 0.0001)
    }

    func testCropKeepsParagraphsMostlyInsideSelection() {
        let document = Self.photoDocument(columns: 3, boxes: [
            // Vision 坐标：y 越大越靠上
            ("left top", CGRect(x: 0.10, y: 0.70, width: 0.22, height: 0.08)),
            ("left bottom", CGRect(x: 0.10, y: 0.20, width: 0.22, height: 0.08)),
            ("right top", CGRect(x: 0.70, y: 0.70, width: 0.22, height: 0.08))
        ])
        // 选左栏上半：layout 里 y ∈ [0.15, 0.40]，x ∈ [0.05, 0.40]
        let selection = CGRect(x: 0.05, y: 0.15, width: 0.35, height: 0.25)

        guard let cropped = PhotoRegionCropper.crop(document, to: selection) else {
            return XCTFail("选区内有段落，不该返回 nil")
        }
        XCTAssertEqual(cropped.paragraphs.map(\.text), ["left top"])
        XCTAssertEqual(cropped.paragraphs.map(\.id), [0], "裁剪后 id 必须从 0 连续")
        XCTAssertEqual(cropped.imageData, document.imageData, "原图要保留，高亮还要画在上面")
    }

    func testCropReturnsNilWhenSelectionMissesEverything() {
        let document = Self.photoDocument(columns: 3, boxes: [
            ("only", CGRect(x: 0.10, y: 0.70, width: 0.22, height: 0.08))
        ])
        XCTAssertNil(PhotoRegionCropper.crop(document, to: CGRect(x: 0.6, y: 0.6, width: 0.2, height: 0.2)),
                     "空选区必须回退整页，而不是产出空文档")
        XCTAssertNil(PhotoRegionCropper.crop(document, to: .zero))
    }

    func testCropExcludesBarelyTouchedParagraph() {
        let document = Self.photoDocument(columns: 2, boxes: [
            ("grazed", CGRect(x: 0.10, y: 0.70, width: 0.40, height: 0.08))
        ])
        // 只擦到段落左边一小条（约 12%）
        let selection = CGRect(x: 0.05, y: 0.20, width: 0.10, height: 0.20)
        XCTAssertNil(PhotoRegionCropper.crop(document, to: selection))
    }

    // MARK: - 何时该问用户

    func testSelectionOfferedOnlyForMultiColumnPhotoWithEnoughContent() {
        let boxes = (0..<8).map { index in
            ("p\(index)", CGRect(x: 0.1, y: 0.9 - CGFloat(index) * 0.1, width: 0.2, height: 0.05))
        }
        XCTAssertTrue(PhotoRegionCropper.shouldOfferSelection(for: Self.photoDocument(columns: 3, boxes: boxes)))

        XCTAssertFalse(PhotoRegionCropper.shouldOfferSelection(for: Self.photoDocument(columns: 1, boxes: boxes)),
                       "单栏文档不该打扰用户")
        XCTAssertFalse(PhotoRegionCropper.shouldOfferSelection(for: Self.photoDocument(columns: nil, boxes: boxes)),
                       "没有版面结论时不问")
        XCTAssertFalse(
            PhotoRegionCropper.shouldOfferSelection(for: Self.photoDocument(columns: 3, boxes: Array(boxes.prefix(3)))),
            "内容太少时整页就是一篇，不必选"
        )

        var textDocument = Self.photoDocument(columns: 3, boxes: boxes)
        textDocument.sourceKind = .text
        XCTAssertFalse(PhotoRegionCropper.shouldOfferSelection(for: textDocument), "非照片源没有可框选的图")
    }

    // MARK: - Fixtures

    private static func photoDocument(columns: Int?, boxes: [(String, CGRect)]) -> ReadingDocument {
        ReadingDocument(
            title: "page",
            sourceKind: .photo,
            language: "en",
            paragraphs: boxes.enumerated().map { index, item in
                ReadingParagraph(id: index, text: item.0, type: .paragraph, words: [], bboxNorm: item.1)
            },
            imageData: solidImage(size: CGSize(width: 40, height: 40)).pngData(),
            imagePixelSize: CGSize(width: 40, height: 40),
            layoutColumnCount: columns
        )
    }

    /// scale 固定为 1，让 pt 尺寸等于像素尺寸 —— 否则断言会随运行设备的
    /// 屏幕倍率漂移（3x 设备上 320pt 其实是 960px）。
    private static var renderFormat: UIGraphicsImageRendererFormat {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return format
    }

    private static func solidImage(size: CGSize) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: renderFormat).image { context in
            UIColor(white: 0.6, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private static func checkerboardImage(size: CGSize, cell: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: size, format: renderFormat).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.black.setFill()
            var row = 0
            var y: CGFloat = 0
            while y < size.height {
                var column = 0
                var x: CGFloat = 0
                while x < size.width {
                    if (row + column) % 2 == 0 {
                        context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                    }
                    x += cell
                    column += 1
                }
                y += cell
                row += 1
            }
        }
    }
}
