import Foundation
import UIKit

@MainActor
protocol KindleOfflineRecognizing {
    func recognize(_ page: ReadingDocument, sourceWordCount: Int?) async throws -> ReadingDocument
}

/// Only called by local playback, never by the download coordinator. Both
/// Vision and the existing bundled Kindle language engines run on this device.
@MainActor
final class KindleOfflineOCRService: KindleOfflineRecognizing {
    func recognize(_ page: ReadingDocument, sourceWordCount: Int?) async throws -> ReadingDocument {
        guard let data = page.paragraphs.first(where: { $0.type == .image })?.imageData,
              let image = UIImage(data: data) else { throw OCRError.noCGImage }
        guard let profile = KindleLanguageContract.profile(language: page.language) else {
            throw OCRError.unsupportedLanguages([page.language])
        }
        let recognized: ReadingDocument
        do {
            recognized = try await OCRService.shared.recognizeKindle(image: image, profile: profile,
                title: page.title, paragraphStrategy: KindleLivePageOCRContract.isolatedPageStrategy)
        } catch OCRError.noText where sourceWordCount == 0 {
            return page
        }
        try Task.checkCancellation()
        var result = page
        result.paragraphs = [ReadingParagraph(id: 0, text: "", type: .image, pageIndex: 0, imageData: data)] +
            recognized.paragraphs.filter { $0.type != .image }.enumerated().map { index, value in
                ReadingParagraph(id: index + 1, text: value.text, speechText: value.speechText,
                    type: value.type, words: value.words, bboxNorm: value.bboxNorm,
                    visualFragments: value.visualFragments, pageIndex: 0)
            }
        return result
    }
}
