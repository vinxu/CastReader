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

    // MARK: - 页面旋转（像素级）

    /// 旋转方向搞反是这类改动最容易犯的错：用不对称图像逐像素验证。
    /// 左黑右白的横条，顺时针转 90° 后必须变成「上黑下白」的竖条。
    func testRotateClockwiseMovesLeftEdgeToTop() {
        let source = Self.halfBlackHalfWhite(width: 40, height: 20)
        let rotated = source.rotatedClockwise(quarterTurns: 1)

        XCTAssertEqual(rotated.size.width, 20, accuracy: 0.5, "宽高必须互换")
        XCTAssertEqual(rotated.size.height, 40, accuracy: 0.5)
        XCTAssertEqual(rotated.imageOrientation, .up, "必须是像素级归正，不是只改 orientation 标记")

        let top = Self.brightness(of: rotated, atUnit: CGPoint(x: 0.5, y: 0.15))
        let bottom = Self.brightness(of: rotated, atUnit: CGPoint(x: 0.5, y: 0.85))
        XCTAssertLessThan(top, 0.3, "原来的左半（黑）必须转到上方")
        XCTAssertGreaterThan(bottom, 0.7, "原来的右半（白）必须转到下方")
    }

    func testRotateByZeroOrFourTurnsIsIdentity() {
        let source = Self.halfBlackHalfWhite(width: 40, height: 20)
        XCTAssertEqual(source.rotatedClockwise(quarterTurns: 0).size, source.size)

        let round = source.rotatedClockwise(quarterTurns: 4)
        XCTAssertEqual(round.size.width, source.size.width, accuracy: 0.5)
        XCTAssertLessThan(Self.brightness(of: round, atUnit: CGPoint(x: 0.15, y: 0.5)), 0.3)
        XCTAssertGreaterThan(Self.brightness(of: round, atUnit: CGPoint(x: 0.85, y: 0.5)), 0.7)
    }

    private static func halfBlackHalfWhite(width: CGFloat, height: CGFloat) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: renderFormat).image { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
            UIColor.white.setFill()
            context.fill(CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        }
    }

    /// 取归一化位置处的亮度（0 = 黑，1 = 白）。
    private static func brightness(of image: UIImage, atUnit point: CGPoint) -> CGFloat {
        guard let cgImage = image.cgImage else { return -1 }
        let x = min(cgImage.width - 1, max(0, Int(point.x * CGFloat(cgImage.width))))
        let y = min(cgImage.height - 1, max(0, Int(point.y * CGFloat(cgImage.height))))
        var pixel: UInt8 = 0
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 1,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return -1 }
        context.draw(cgImage, in: CGRect(x: -CGFloat(x), y: -CGFloat(cgImage.height - 1 - y),
                                         width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        return CGFloat(pixel) / 255
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

// MARK: - 照片 OCR 快照（重开不再重跑识别）

@MainActor
final class PhotoOCRSnapshotTests: XCTestCase {

    private func makeDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-ocr-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeImageData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60))
        let image = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }

    private func makeRecognizedPhoto(id: String, imageData: Data) -> ReadingDocument {
        ReadingDocument(
            id: id,
            title: "La Costanera",
            sourceKind: .photo,
            language: "en",
            paragraphs: [
                ReadingParagraph(
                    id: 0,
                    text: "Passion Ardiente",
                    words: [
                        OCRWord(id: 0, text: "Passion",
                                bboxNorm: CGRect(x: 0.1, y: 0.8, width: 0.2, height: 0.03)),
                        OCRWord(id: 1, text: "Ardiente",
                                bboxNorm: CGRect(x: 0.32, y: 0.8, width: 0.2, height: 0.03)),
                    ],
                    bboxNorm: CGRect(x: 0.1, y: 0.8, width: 0.42, height: 0.03)
                )
            ],
            imageData: imageData,
            imagePixelSize: CGSize(width: 40, height: 60),
            layoutColumnCount: 2
        )
    }

    func testRecognizedPhotoReopensFromSnapshotWithoutReRecognition() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageData = makeImageData()
        let store = HistoryStore(directory: directory)
        store.record(makeRecognizedPhoto(id: "photo-1", imageData: imageData))

        // 快照与 payload 同目录落盘
        let snapshotURL = directory.appendingPathComponent("photo-1.ocr.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))

        // 冷启动（新 store 实例）也能直接拿到完整结果，不需要跑 OCR
        let reloaded = HistoryStore(directory: directory)
        let record = try XCTUnwrap(reloaded.records.first(where: { $0.id == "photo-1" }))
        let document = try XCTUnwrap(reloaded.instantPhotoDocument(record))
        XCTAssertEqual(document.paragraphs.count, 1)
        XCTAssertEqual(document.paragraphs.first?.words.count, 2)
        XCTAssertEqual(document.paragraphs.first?.words.first?.bboxNorm.origin.x ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertEqual(document.language, "en")
        XCTAssertEqual(document.layoutColumnCount, 2)
        XCTAssertEqual(document.imageData, imageData)
    }

    func testPhotoWithoutSnapshotOpensImmediatelyWithNoParagraphs() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageData = makeImageData()
        let store = HistoryStore(directory: directory)
        store.record(makeRecognizedPhoto(id: "photo-2", imageData: imageData))
        // 模拟升级前的老记录：只有 payload，没有识别快照
        try FileManager.default.removeItem(at: directory.appendingPathComponent("photo-2.ocr.json"))

        let reloaded = HistoryStore(directory: directory)
        let record = try XCTUnwrap(reloaded.records.first(where: { $0.id == "photo-2" }))
        let document = try XCTUnwrap(reloaded.instantPhotoDocument(record))
        // 页面照样立刻打开：图在，段落留空等后台识别补
        XCTAssertTrue(document.paragraphs.isEmpty)
        XCTAssertEqual(document.imageData, imageData)
    }

    func testSnapshotIsRejectedWhenPayloadChanged() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = HistoryStore(directory: directory)
        store.record(makeRecognizedPhoto(id: "photo-3", imageData: makeImageData()))

        // 同 id 换了一张图（重新导入）：旧快照的几何不再代表这张图
        let replacement = Data(repeating: 0x42, count: 999)
        try replacement.write(to: directory.appendingPathComponent("photo-3.payload"), options: .atomic)

        let reloaded = HistoryStore(directory: directory)
        let record = try XCTUnwrap(reloaded.records.first(where: { $0.id == "photo-3" }))
        let document = try XCTUnwrap(reloaded.instantPhotoDocument(record))
        XCTAssertTrue(document.paragraphs.isEmpty, "payload 变了就必须重识别，不能用旧几何")
    }

    func testSnapshotSurvivesPlaceholderReopen() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageData = makeImageData()
        let store = HistoryStore(directory: directory)
        store.record(makeRecognizedPhoto(id: "photo-4", imageData: imageData))

        // 占位文档（段落为空）再次入历史时，不得抹掉已有的好快照
        store.record(ReadingDocument(
            id: "photo-4",
            title: "La Costanera",
            sourceKind: .photo,
            language: "en",
            paragraphs: [],
            imageData: imageData
        ))

        let reloaded = HistoryStore(directory: directory)
        let record = try XCTUnwrap(reloaded.records.first(where: { $0.id == "photo-4" }))
        let document = try XCTUnwrap(reloaded.instantPhotoDocument(record))
        XCTAssertEqual(document.paragraphs.count, 1)
    }
}
