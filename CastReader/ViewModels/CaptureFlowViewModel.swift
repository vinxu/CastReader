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
            // File/clipboard/share-sheet images do not necessarily pass through
            // UIImagePickerController, so normalize EXIF orientation here once
            // before both OCR and display geometry are generated.
            let normalized = image.fixedOrientation()
            let doc = try await OCRService.shared.recognizeImportedImage(image: normalized)
            self.document = doc
        } catch {
            self.error = error.localizedDescription
        }
    }

    func reset() {
        document = nil
        error = nil
    }
}
