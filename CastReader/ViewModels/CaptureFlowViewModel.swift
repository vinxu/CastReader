//
//  CaptureFlowViewModel.swift
//  CastReader
//
//  拍摄/选图 → Vision OCR → ReadingDocument(.photo)。
//

import Foundation
import UIKit

@MainActor
final class CaptureFlowViewModel: ObservableObject {
    @Published var isProcessing = false
    @Published var document: ReadingDocument?
    @Published var error: String?

    func process(image: UIImage) async {
        isProcessing = true
        error = nil
        defer { isProcessing = false }
        do {
            let doc = try await OCRService.shared.recognize(image: image, languages: Self.visionLanguages())
            self.document = doc
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reset() {
        document = nil
        error = nil
    }

    /// 同时识别中英（Vision 支持多语言列表）。中文在前——Vision 按顺序作识别偏好，
    /// 中文为主的截图/文档若英文在前会偏向英文模型、漏识别中文行，导致语言误判为英文。
    static func visionLanguages() -> [String] {
        ["zh-Hans", "en-US"]
    }
}
