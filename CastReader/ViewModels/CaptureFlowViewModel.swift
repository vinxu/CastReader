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

    /// OCR 候选语言与 TTS 八语目录共用同一来源；Vision 实际不支持的 locale 会在 OCRService 过滤。
    static func visionLanguages() -> [String] {
        SupportedTTSLanguage.allCases.map(\.visionRecognitionLanguage)
    }
}
