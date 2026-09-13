import Foundation
import NaturalLanguage
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
        let recognized: ReadingDocument
        var language = page.language
        do {
            if KindleLanguageContract.normalize(language) == nil {
                language = try await detectLanguage(image)
            }
            guard let profile = KindleLanguageContract.profile(language: language) else {
                throw OCRError.unsupportedLanguages([language])
            }
            if language == "zh-Hant" {
                // The bundled Tesseract fallback is simplified Chinese only.
                // Traditional pages use the on-device Vision Traditional model.
                recognized = try await OCRService.shared.recognize(image: image, languages: ["zh-Hant"],
                    title: page.title, paragraphStrategy: KindleLivePageOCRContract.isolatedPageStrategy, languageHint: "zh")
            } else {
                recognized = try await OCRService.shared.recognizeKindle(image: image, profile: profile,
                    title: page.title, paragraphStrategy: KindleLivePageOCRContract.isolatedPageStrategy)
            }
        } catch OCRError.noText where sourceWordCount == 0 {
            return page
        }
        try Task.checkCancellation()
        var result = page
        result.language = language
        result.paragraphs = [ReadingParagraph(id: 0, text: "", type: .image, pageIndex: 0, imageData: data)] +
            recognized.paragraphs.filter { $0.type != .image }.enumerated().map { index, value in
                ReadingParagraph(id: index + 1, text: value.text, speechText: value.speechText,
                    type: value.type, words: value.words, bboxNorm: value.bboxNorm,
                    visualFragments: value.visualFragments, pageIndex: 0)
            }
        return result
    }

    private func detectLanguage(_ image: UIImage) async throws -> String {
        // Independent requests avoid Vision's first-locale bias. A book title
        // (often English marketing copy) must not override the page's script.
        let locales = ["zh-Hans", "zh-Hant", "ja-JP"] + SupportedTTSLanguage.allCases
            .filter { $0 != .chinese && $0 != .japanese }.map(\.visionRecognitionLanguage)
        var best: (language: String, score: Double)?
        var strongCJK = false
        for (index, locale) in locales.enumerated() {
            try Task.checkCancellation()
            if index == 3, strongCJK { break }
            do {
                let probe = try await OCRService.shared.recognize(image: image, languages: [locale],
                    paragraphStrategy: .visionLines, languageHint: locale)
                let evidence = LanguageDetector.evidence(for: probe.fullText)
                guard evidence.readableCharacterCount > 0 else { continue }
                let scored = KindleOCRConsensus.score(page: evidence,
                    requestedLanguage: KindleLanguageContract.normalize(locale) ?? locale,
                    title: LanguageDetector.evidence(for: ""))
                var language = scored.language
                if language == "zh" {
                    language = NLLanguageRecognizer.dominantLanguage(for: probe.fullText) == .traditionalChinese
                        ? "zh-Hant" : "zh-Hans"
                }
                if best == nil || scored.value > best!.score { best = (language, scored.value) }
                if ["zh", "ja"].contains(evidence.language), evidence.confidence >= 0.8,
                   evidence.readableCharacterCount >= 8 { strongCJK = true }
            } catch is CancellationError { throw CancellationError() }
            catch OCRError.noText { continue }
            catch OCRError.unsupportedLanguages { continue }
        }
        guard let best else { throw OCRError.noText }
        return best.language
    }
}
