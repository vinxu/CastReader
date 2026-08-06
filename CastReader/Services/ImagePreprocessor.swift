//
//  ImagePreprocessor.swift
//  CastReader
//
//  拍摄/选图的采集质量层：文档透视矫正 + 可用性评估。
//
//  版面理解建立在「正投影页面」的假设上：栏是竖直的、行是水平的。
//  手持拍摄的报纸倾斜十几度、带梯形畸变时，列检测的投影直方图会糊掉。
//  这一层把画面尽量拉回正投影，再交给 OCR。
//

import CoreImage
import UIKit
import Vision

enum ImagePreprocessor {

    // MARK: - Tuning

    enum Tuning {
        /// 低于该短边像素数，报纸正文会糊到 Vision 认不出来。
        static let minShortSide = 900
        /// 拉普拉斯方差低于此值判为模糊（在 512 宽灰度图上测）。
        static let minSharpness: Double = 55
        /// 文档四角检测的置信度门槛。
        static let minSegmentationConfidence: Float = 0.5
        /// 矫正后的四边形至少要占画面这么大，否则多半是误检。
        static let minDocumentAreaRatio: CGFloat = 0.25
        /// 评估用的缩略图宽度。
        static let assessWidth: CGFloat = 512
    }

    // MARK: - Quality

    struct Quality: Equatable {
        let shortestSide: Int
        let sharpness: Double
        /// `nil` 表示可以直接识别；否则是给用户的重拍建议。
        let advice: String?

        var isUsable: Bool { advice == nil }
    }

    /// 只做判断，不改图。不可用时由调用方决定是提示重拍还是继续（fail-open）。
    static func assess(_ image: UIImage) -> Quality {
        let pixelSize = CGSize(width: image.size.width * image.scale,
                               height: image.size.height * image.scale)
        let shortest = Int(min(pixelSize.width, pixelSize.height).rounded())
        let sharpness = self.sharpness(of: image)

        var advice: String?
        if shortest < Tuning.minShortSide {
            advice = AppLocalized("画面太小，靠近一点或用更高分辨率重拍")
        } else if sharpness < Tuning.minSharpness {
            advice = AppLocalized("画面有点模糊，端稳手机重拍会识别得更准")
        }
        return Quality(shortestSide: shortest, sharpness: sharpness, advice: advice)
    }

    /// 拉普拉斯方差：对焦清晰的文本边缘多、方差大；糊掉的照片方差小。
    /// 在固定宽度的灰度缩略图上测，结果与原图分辨率无关。
    static func sharpness(of image: UIImage) -> Double {
        guard let gray = grayscaleBuffer(of: image, width: Int(Tuning.assessWidth)) else { return .greatestFiniteMagnitude }
        let width = gray.width
        let height = gray.height
        guard width > 2, height > 2 else { return .greatestFiniteMagnitude }

        var sum = 0.0
        var sumSquares = 0.0
        var count = 0.0
        gray.pixels.withUnsafeBufferPointer { buffer in
            for y in 1..<(height - 1) {
                for x in 1..<(width - 1) {
                    let index = y * width + x
                    // 4-邻域拉普拉斯
                    let value = Double(buffer[index]) * 4
                        - Double(buffer[index - 1])
                        - Double(buffer[index + 1])
                        - Double(buffer[index - width])
                        - Double(buffer[index + width])
                    sum += value
                    sumSquares += value * value
                    count += 1
                }
            }
        }
        guard count > 0 else { return .greatestFiniteMagnitude }
        let mean = sum / count
        return max(0, sumSquares / count - mean * mean)
    }

    private struct GrayBuffer {
        let pixels: [UInt8]
        let width: Int
        let height: Int
    }

    private static func grayscaleBuffer(of image: UIImage, width targetWidth: Int) -> GrayBuffer? {
        guard let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 else { return nil }
        let scale = min(1, CGFloat(targetWidth) / CGFloat(cgImage.width))
        let width = max(1, Int((CGFloat(cgImage.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(cgImage.height) * scale).rounded()))
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayBuffer(pixels: pixels, width: width, height: height)
    }

    // MARK: - Perspective correction

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 检测画面里的文档四角并拉回正投影。检测不到、置信度低、或四边形
    /// 小得不像一页纸时**原样返回** —— 宁可不矫正，也不能把画面拧坏。
    ///
    /// 系统文档扫描器（`VNDocumentCameraViewController`）自己会做这件事，
    /// 所以这条路径只用于相册 / 剪贴板 / 系统分享进来的图。
    static func documentCorrected(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }
        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return image
        }
        guard let observation = request.results?.first,
              observation.confidence >= Tuning.minSegmentationConfidence else { return image }

        // Vision 归一化点（原点左下）→ CoreImage 图像坐标（同样原点左下）。
        let extent = CIImage(cgImage: cgImage).extent
        func point(_ normalized: CGPoint) -> CGPoint {
            CGPoint(x: extent.minX + normalized.x * extent.width,
                    y: extent.minY + normalized.y * extent.height)
        }
        let topLeft = point(observation.topLeft)
        let topRight = point(observation.topRight)
        let bottomLeft = point(observation.bottomLeft)
        let bottomRight = point(observation.bottomRight)

        guard isPlausibleDocument(
            topLeft: topLeft, topRight: topRight,
            bottomLeft: bottomLeft, bottomRight: bottomRight,
            extent: extent
        ) else { return image }

        let corrected = CIImage(cgImage: cgImage).applyingFilter("CIPerspectiveCorrection", parameters: [
            "inputTopLeft": CIVector(cgPoint: topLeft),
            "inputTopRight": CIVector(cgPoint: topRight),
            "inputBottomLeft": CIVector(cgPoint: bottomLeft),
            "inputBottomRight": CIVector(cgPoint: bottomRight)
        ])
        guard corrected.extent.width >= 1, corrected.extent.height >= 1,
              let output = ciContext.createCGImage(corrected, from: corrected.extent) else {
            return image
        }
        return UIImage(cgImage: output, scale: image.scale, orientation: .up)
    }

    /// 四边形得像一页纸：面积够大、四条边都不退化、对边长度不悬殊。
    static func isPlausibleDocument(
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomLeft: CGPoint,
        bottomRight: CGPoint,
        extent: CGRect
    ) -> Bool {
        guard extent.width > 0, extent.height > 0 else { return false }
        func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot()
        }
        let top = distance(topLeft, topRight)
        let bottom = distance(bottomLeft, bottomRight)
        let left = distance(topLeft, bottomLeft)
        let right = distance(topRight, bottomRight)
        let minimumEdge = min(extent.width, extent.height) * 0.2
        guard top > minimumEdge, bottom > minimumEdge,
              left > minimumEdge, right > minimumEdge else { return false }

        // 鞋带公式求四边形面积
        let points = [topLeft, topRight, bottomRight, bottomLeft]
        var area: CGFloat = 0
        for index in points.indices {
            let current = points[index]
            let next = points[(index + 1) % points.count]
            area += current.x * next.y - next.x * current.y
        }
        area = abs(area) / 2
        guard area >= extent.width * extent.height * Tuning.minDocumentAreaRatio else { return false }

        // 透视太夸张（对边长度差一倍以上）多半是误检，矫正后会严重拉伸。
        let horizontalRatio = max(top, bottom) / max(1, min(top, bottom))
        let verticalRatio = max(left, right) / max(1, min(left, right))
        return horizontalRatio <= 2.0 && verticalRatio <= 2.0
    }
}
