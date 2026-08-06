//
//  CaptureFlowViewModel.swift
//  CastReader
//
//  拍摄/选图/扫描 → 采集质量处理 → Vision OCR → ReadingDocument。
//
//  单页走 `.photo`（原图 + 词 bbox，朗读高亮与解读标注画在照片上）；
//  多页扫描合并成 `.text`（重排文本连续朗读）—— 多页更像一份文件而不是一张照片，
//  照片叠加在多图上既无处安放，也不是用户在那个场景下要的东西。
//

import Foundation
import UIKit

@MainActor
final class CaptureFlowViewModel: ObservableObject {
    @Published var isProcessing = false
    @Published var document: ReadingDocument?
    @Published var error: String?
    /// 采集质量提示（画面太小 / 模糊）。不阻断流程，只是让用户知道可以拍得更好。
    @Published var qualityAdvice: String?
    /// 多页时的进度，用于「正在识别第 n / m 页」。
    @Published var pageProgress: (current: Int, total: Int)?

    /// 相册 / 剪贴板 / 系统分享进来的单张图片。会尝试文档透视矫正。
    func process(image: UIImage) async {
        await process(images: [image], alreadyRectified: false)
    }

    /// 系统文档扫描器产出的页面：已由 VisionKit 矫正过，不再二次矫正。
    func processScannedPages(_ images: [UIImage]) async {
        await process(images: images, alreadyRectified: true)
    }

    func process(images: [UIImage], alreadyRectified: Bool) async {
        guard !images.isEmpty else { return }
        isProcessing = true
        error = nil
        qualityAdvice = nil
        pageProgress = images.count > 1 ? (1, images.count) : nil
        defer {
            isProcessing = false
            pageProgress = nil
        }

        var documents: [ReadingDocument] = []
        var firstAdvice: String?
        for (index, image) in images.enumerated() {
            if images.count > 1 { pageProgress = (index + 1, images.count) }
            let prepared = await Self.prepare(image, alreadyRectified: alreadyRectified)
            if firstAdvice == nil { firstAdvice = prepared.advice }
            do {
                documents.append(try await OCRService.shared.recognizeImportedImage(image: prepared.image))
            } catch {
                // 多页时单页失败不该毁掉整次扫描；全部失败才报错。
                if images.count == 1 {
                    self.error = Self.message(for: error.localizedDescription, advice: prepared.advice)
                    return
                }
            }
        }

        guard !documents.isEmpty else {
            error = Self.message(for: OCRError.noText.localizedDescription, advice: firstAdvice)
            return
        }
        qualityAdvice = firstAdvice
        document = documents.count == 1 ? documents[0] : Self.merged(documents)
    }

    func reset() {
        document = nil
        error = nil
        qualityAdvice = nil
        pageProgress = nil
    }

    // MARK: - Helpers

    /// 识别成功时不打扰用户；只有失败了才把「为什么」和「怎么改」一起说清楚。
    nonisolated static func message(for reason: String, advice: String?) -> String {
        guard let advice, !advice.isEmpty else { return reason }
        return "\(reason)\n\(advice)"
    }

    private static func prepare(
        _ image: UIImage,
        alreadyRectified: Bool
    ) async -> (image: UIImage, advice: String?) {
        // 文件/剪贴板/分享进来的图未必经过 UIImagePickerController，
        // 所以先统一 EXIF 方向，再做几何矫正与质量评估。
        let normalized = image.fixedOrientation()
        let rectified = alreadyRectified
            ? normalized
            : await Task.detached(priority: .userInitiated) {
                ImagePreprocessor.documentCorrected(normalized)
            }.value
        let quality = await Task.detached(priority: .userInitiated) {
            ImagePreprocessor.assess(rectified)
        }.value
        return (rectified, quality.advice)
    }

    /// 多页 → 单个重排文本文档。逐页段落顺序拼接，丢弃词 bbox（无处叠加）。
    nonisolated static func merged(_ documents: [ReadingDocument]) -> ReadingDocument {
        var paragraphs: [ReadingParagraph] = []
        for document in documents {
            for paragraph in document.paragraphs where paragraph.type.isReadable {
                let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                paragraphs.append(ReadingParagraph(
                    id: paragraphs.count,
                    text: text,
                    type: paragraph.type
                ))
            }
        }
        let title = documents.first?.title ?? AppLocalized("扫描文档")
        return ReadingDocument(
            title: title,
            sourceKind: .text,
            language: documents.first?.language ?? Constants.TTS.defaultLanguage,
            paragraphs: paragraphs
        )
    }
}
