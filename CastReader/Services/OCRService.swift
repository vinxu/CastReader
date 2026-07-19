//
//  OCRService.swift
//  CastReader
//
//  端上 Vision 文字识别：UIImage → ReadingDocument(.photo)，含逐词归一化 bbox（原点左下）。
//

import Foundation
import Vision
import UIKit
import WebKit

enum OCRError: Error, LocalizedError {
    case noCGImage
    case noText
    case unsupportedLanguages([String])
    case kindleEngine(String)

    var errorDescription: String? {
        switch self {
        case .noCGImage: return AppLocalized("无法读取图片")
        case .noText: return AppLocalized("未识别到文字")
        case .unsupportedLanguages(let languages):
            return String(format: AppLocalized("系统 OCR 不支持语言：%@"), languages.joined(separator: ", "))
        case .kindleEngine(let reason):
            return String(format: AppLocalized("Kindle 多语言 OCR 初始化失败：%@"), reason)
        }
    }
}

private struct KindleTesseractWordBox {
    let text: String
    let left: CGFloat
    let top: CGFloat
    let right: CGFloat
    let bottom: CGFloat
    let confidence: Double
}

private struct KindleTesseractResult {
    let model: String
    let imageWidth: CGFloat
    let imageHeight: CGFloat
    let words: [KindleTesseractWordBox]
    let lines: [KindleTesseractWordBox]
    let paragraphs: [String]
    let paragraphWords: [[KindleTesseractWordBox]]
    let verticalComplete: Bool?
    let verticalSource: String?
    let verticalColumns: Int
    let verticalRequiredColumns: Int
    let verticalUnresolvedColumns: Int
}

/// Hidden local WebKit host for the exact same tesseract-wasm models used by the
/// browser extension. It never loads remote content and is retained so consecutive
/// Kindle pages reuse the active language model.
@MainActor
private final class KindleTesseractOCRService {
    static let shared = KindleTesseractOCRService()

    private var webView: WKWebView?
    private var isReady = false
    private let schemeHandler = KindleOCRSchemeHandler()

    func recognize(
        imageData: Data,
        model: String,
        verticalColumnHints: [KindleVerticalColumnHint]
    ) async throws -> KindleTesseractResult {
        let webView = try await readyWebView()
        let dataURL = "data:image/png;base64,\(imageData.base64EncodedString())"
        let raw = try await webView.callAsyncJavaScript(
            "return await window.castReaderKindleOCR(dataURL, model, verticalColumnHints);",
            arguments: [
                "dataURL": dataURL,
                "model": model,
                "verticalColumnHints": verticalColumnHints.map(\.javaScriptValue)
            ],
            in: nil,
            contentWorld: .page
        )
        guard let payload = raw as? [String: Any], payload["success"] as? Bool == true else {
            throw OCRError.kindleEngine("invalid-result")
        }
        let width = Self.number(payload["imageWidth"])
        let height = Self.number(payload["imageHeight"])
        guard width > 0, height > 0 else { throw OCRError.kindleEngine("invalid-image-size") }
        func parseWords(_ raw: Any?) -> [KindleTesseractWordBox] {
            (raw as? [[String: Any]] ?? []).compactMap { item -> KindleTesseractWordBox? in
            guard let text = item["text"] as? String else { return nil }
            return KindleTesseractWordBox(
                text: text,
                left: Self.number(item["left"]),
                top: Self.number(item["top"]),
                right: Self.number(item["right"]),
                bottom: Self.number(item["bottom"]),
                confidence: Double(Self.number(item["confidence"]))
            )
            }
        }
        let words = parseWords(payload["wordBoxes"])
        let lines = parseWords(payload["lineBoxes"])
        let rawParagraphWords: [Any] = payload["paragraphWords"] as? [Any] ?? []
        let paragraphWords: [[KindleTesseractWordBox]] = rawParagraphWords.map { parseWords($0) }
        let diagnostics = payload["verticalDiagnostics"] as? [String: Any]
        return KindleTesseractResult(
            model: payload["model"] as? String ?? model,
            imageWidth: width,
            imageHeight: height,
            words: words,
            lines: lines,
            paragraphs: payload["paragraphs"] as? [String] ?? [],
            paragraphWords: paragraphWords,
            verticalComplete: diagnostics?["complete"] as? Bool,
            verticalSource: diagnostics?["source"] as? String,
            verticalColumns: Int(Self.number(diagnostics?["columns"])),
            verticalRequiredColumns: Int(Self.number(diagnostics?["requiredColumns"])),
            verticalUnresolvedColumns: Int(Self.number(diagnostics?["unresolvedColumns"]))
        )
    }

    private func readyWebView() async throws -> WKWebView {
        if let webView, isReady { return webView }
        guard Bundle.main.url(forResource: "ocr", withExtension: "html", subdirectory: "WebAssets/KindleOCR") != nil,
              let pageURL = URL(string: "castreader-ocr://local/ocr.html") else {
            throw OCRError.kindleEngine("missing-web-assets")
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "castreader-ocr")
        let webView = self.webView ?? WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        webView.load(URLRequest(url: pageURL))
        for _ in 0..<160 {
            if (try? await webView.evaluateJavaScript("window.castReaderKindleOCRReady === true")) as? Bool == true {
                isReady = true
                return webView
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        throw OCRError.kindleEngine("web-runtime-timeout")
    }

    private static func number(_ value: Any?) -> CGFloat {
        if let value = value as? NSNumber { return CGFloat(value.doubleValue) }
        if let value = value as? Double { return CGFloat(value) }
        if let value = value as? Int { return CGFloat(value) }
        return 0
    }
}

private final class KindleOCRSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              url.scheme == "castreader-ocr",
              let root = Bundle.main.resourceURL?
                .appendingPathComponent("WebAssets", isDirectory: true)
                .appendingPathComponent("KindleOCR", isDirectory: true) else {
            urlSchemeTask.didFailWithError(OCRError.kindleEngine("invalid-resource-request"))
            return
        }
        let relative = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relative.isEmpty, !relative.contains("..") else {
            urlSchemeTask.didFailWithError(OCRError.kindleEngine("invalid-resource-path"))
            return
        }
        let fileURL = root.appendingPathComponent(relative).standardizedFileURL
        guard fileURL.path.hasPrefix(root.standardizedFileURL.path),
              let data = try? Data(contentsOf: fileURL) else {
            urlSchemeTask.didFailWithError(OCRError.kindleEngine("resource-not-found-\(relative)"))
            return
        }
        let mimeType: String
        switch fileURL.pathExtension.lowercased() {
        case "html": mimeType = "text/html"
        case "js": mimeType = "text/javascript"
        case "wasm": mimeType = "application/wasm"
        case "traineddata": mimeType = "application/octet-stream"
        default: mimeType = "application/octet-stream"
        }
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: mimeType.hasPrefix("text/") ? "utf-8" : nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

enum OCRParagraphStrategy {
    case visionLines
    case kindleLayout

    var logName: String {
        switch self {
        case .visionLines: return "vision"
        case .kindleLayout: return "kindleLayout"
        }
    }
}

struct KindleOCRLanguageProbe: Equatable {
    let language: String
    let visionLocale: String
    let readableCharacterCount: Int
    let score: Double
}

enum KindleOCRConsensus {
    static func score(
        page: LanguageDetector.Evidence,
        requestedLanguage: String,
        title: LanguageDetector.Evidence
    ) -> (language: String, value: Double) {
        let useTitle = page.readableCharacterCount < 24 && title.confidence >= 0.55
        let language = useTitle ? title.language : page.language
        var value = Double(page.readableCharacterCount) * (0.45 + max(0.1, page.confidence))
        if language == requestedLanguage { value *= 1.2 }
        if language == title.language, title.confidence >= 0.55 {
            value += min(40, Double(max(8, title.readableCharacterCount))) * title.confidence
        }
        if page.language != language { value *= 0.8 }
        return (language, value)
    }
}

enum KindleOCRTextContract {
    /// Vision returns a line string. Latin scripts keep word ranges; CJK uses
    /// extended grapheme clusters so one OCR box cannot swallow a whole line.
    /// Swift `Character` also keeps variation selectors and combining marks intact.
    static func tokenRanges(in text: String, language: String?) -> [Range<String.Index>] {
        let normalized = KindleLanguageContract.normalize(language)
        if normalized == "zh" || normalized == "ja" {
            var ranges: [Range<String.Index>] = []
            var index = text.startIndex
            while index < text.endIndex {
                let next = text.index(after: index)
                if !text[index].isWhitespace { ranges.append(index..<next) }
                index = next
            }
            return ranges
        }

        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            while index < text.endIndex, text[index].isWhitespace {
                index = text.index(after: index)
            }
            guard index < text.endIndex else { break }
            let start = index
            while index < text.endIndex, !text[index].isWhitespace {
                index = text.index(after: index)
            }
            ranges.append(start..<index)
        }
        return ranges
    }

    static func tokens(in text: String, language: String?) -> [String] {
        tokenRanges(in: text, language: language).map { String(text[$0]) }
    }
}

actor OCRService {
    static let shared = OCRService()
    private init() {}

    /// 识别图片文字，按行聚合为段落。languages 为 BCP-47（如 ["en-US"]、["zh-Hans","en-US"]）。
    func recognize(
        image: UIImage,
        languages: [String],
        title: String? = nil,
        paragraphStrategy: OCRParagraphStrategy = .visionLines,
        languageHint: String? = nil
    ) async throws -> ReadingDocument {
        guard let cg = image.cgImage else { throw OCRError.noCGImage }

        let normalizedLanguage = KindleLanguageContract.normalize(languageHint)
        let lines = try await recognizeLines(
            cgImage: cg,
            languages: languages,
            language: normalizedLanguage
        )
        guard !lines.isEmpty else { throw OCRError.noText }

        let paraBoxes = buildParagraphBoxes(from: lines, strategy: paragraphStrategy, language: normalizedLanguage)
        var paragraphs: [ReadingParagraph] = []
        var globalWordId = 0
        for (pIdx, box) in paraBoxes.enumerated() {
            var words: [OCRWord] = []
            for w in box.words {
                words.append(OCRWord(id: globalWordId, text: w.text, bboxNorm: w.bbox))
                globalWordId += 1
            }
            let text = box.text
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            paragraphs.append(ReadingParagraph(id: pIdx, text: text, type: .paragraph,
                                               words: words, bboxNorm: box.bbox))
        }

        // 重排连续 id
        paragraphs = paragraphs.enumerated().map { (i, p) in
            ReadingParagraph(id: i, text: p.text, type: p.type, words: p.words, bboxNorm: p.bboxNorm)
        }

        let joined = paragraphs.map(\.text).joined(separator: " ")
        let lang = normalizedLanguage ?? detectLanguage(joined)
        #if DEBUG
        NSLog("CRDBG OCR strategy=%@ paras=%d lang=%@ chars=%d",
              paragraphStrategy.logName, paragraphs.count, lang, joined.count)
        #endif
        let pixel = CGSize(width: image.size.width * image.scale,
                           height: image.size.height * image.scale)
        let jpeg = image.jpegData(compressionQuality: 0.9)

        return ReadingDocument(
            title: title ?? defaultTitle(from: paragraphs),
            sourceKind: .photo,
            language: lang,
            paragraphs: paragraphs,
            imageData: jpeg,
            imagePixelSize: pixel,
            sourceURL: nil
        )
    }

    /// Kindle selects the best available iOS recognizer per language. The shared
    /// cross-platform authority is the resulting text/geometry contract, not a
    /// requirement that every platform run the same OCR binary.
    func recognizeKindle(
        image: UIImage,
        profile: KindleLanguageProfile,
        title: String? = nil,
        paragraphStrategy: OCRParagraphStrategy = .kindleLayout,
        verticalColumnHints: [KindleVerticalColumnHint] = []
    ) async throws -> ReadingDocument {
        let route = KindleOCRRoutingContract.route(for: profile)
        var lastError: Error = OCRError.noText
        for engine in route.engines {
            do {
                let document: ReadingDocument
                switch engine {
                case .vision:
                    document = try await recognizeKindleWithVision(
                        image: image,
                        profile: profile,
                        title: title,
                        paragraphStrategy: paragraphStrategy
                    )
                case .tesseract:
                    document = try await recognizeKindleWithTesseract(
                        image: image,
                        profile: profile,
                        title: title,
                        paragraphStrategy: paragraphStrategy,
                        verticalColumnHints: verticalColumnHints
                    )
                }
                let boxCoverage = try validateKindleDocument(document, profile: profile, engine: engine)
                KindleRunLog.write(
                    "KINDLE_OCR selectedEngine=\(engine.rawValue) language=\(profile.language) " +
                    "locale=\(profile.visionLocale) model=\(profile.tesseractModel) " +
                    "paras=\(document.paragraphs.count) words=\(document.paragraphs.reduce(0) { $0 + $1.words.count }) " +
                    "chars=\(document.fullText.count) boxCoverage=\(Int((boxCoverage * 100).rounded()))"
                )
                #if DEBUG
                NSLog("CRDBG Kindle OCR selected engine=%@ language=%@ locale=%@ model=%@ paras=%d words=%d chars=%d",
                      engine.rawValue, profile.language, profile.visionLocale, profile.tesseractModel,
                      document.paragraphs.count,
                      document.paragraphs.reduce(0) { $0 + $1.words.count },
                      document.fullText.count)
                #endif
                return document
            } catch {
                lastError = error
                KindleRunLog.write(
                    "KINDLE_OCR_REJECT engine=\(engine.rawValue) language=\(profile.language) " +
                    "reason=\(error.localizedDescription.prefix(160))"
                )
                #if DEBUG
                NSLog("CRDBG Kindle OCR failed engine=%@ language=%@ error=%@",
                      engine.rawValue, profile.language, error.localizedDescription)
                #endif
            }
        }
        throw lastError
    }

    private func recognizeKindleWithVision(
        image: UIImage,
        profile: KindleLanguageProfile,
        title: String?,
        paragraphStrategy: OCRParagraphStrategy
    ) async throws -> ReadingDocument {
        guard profile.writingMode == .horizontal else {
            throw OCRError.kindleEngine("vision-vertical-writing-not-authorized")
        }
        guard let cgImage = image.cgImage else { throw OCRError.noCGImage }
        let lines = try await recognizeLines(
            cgImage: cgImage,
            languages: [profile.visionLocale],
            language: profile.language
        )
        guard !lines.isEmpty else { throw OCRError.noText }
        let paragraphs = buildParagraphBoxes(
            from: lines,
            strategy: paragraphStrategy,
            language: profile.language
        )
        return makeDocument(
            image: image,
            imageData: nil,
            title: title,
            paraBoxes: paragraphs,
            language: profile.language
        )
    }

    private func recognizeKindleWithTesseract(
        image: UIImage,
        profile: KindleLanguageProfile,
        title: String?,
        paragraphStrategy: OCRParagraphStrategy,
        verticalColumnHints: [KindleVerticalColumnHint]
    ) async throws -> ReadingDocument {
        guard let png = image.pngData() else { throw OCRError.noCGImage }
        let result = try await KindleTesseractOCRService.shared.recognize(
            imageData: png,
            model: profile.tesseractModel,
            verticalColumnHints: verticalColumnHints
        )
        func normalizedWord(_ item: KindleTesseractWordBox) -> WordBox? {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let left = max(0, min(result.imageWidth, item.left))
            let right = max(left, min(result.imageWidth, item.right))
            let top = max(0, min(result.imageHeight, item.top))
            let bottom = max(top, min(result.imageHeight, item.bottom))
            guard right > left, bottom > top else { return nil }
            return WordBox(
                text: text,
                bbox: CGRect(
                    x: left / result.imageWidth,
                    y: 1 - bottom / result.imageHeight,
                    width: (right - left) / result.imageWidth,
                    height: (bottom - top) / result.imageHeight
                )
            )
        }
        let wordBoxes = result.words.compactMap(normalizedWord)
        guard !wordBoxes.isEmpty else { throw OCRError.noText }
        let paraBoxes: [ParagraphBox]
        if profile.tesseractModel == "jpn_vert" {
            guard !verticalColumnHints.isEmpty else {
                throw OCRError.kindleEngine("vertical-token-columns-missing")
            }
            guard result.verticalComplete == true,
                  result.verticalRequiredColumns > 0,
                  result.verticalUnresolvedColumns == 0 else {
                throw OCRError.kindleEngine(
                    "vertical-column-mapping-incomplete-\(result.verticalUnresolvedColumns)-of-\(result.verticalRequiredColumns)"
                )
            }
            paraBoxes = result.paragraphWords.enumerated().compactMap { index, rawWords in
                let mapped = rawWords.compactMap(normalizedWord)
                guard !mapped.isEmpty else { return nil }
                let text = index < result.paragraphs.count
                    ? result.paragraphs[index]
                    : KindleLanguageContract.join(mapped.map(\.text), language: "ja")
                return ParagraphBox(text: text, words: mapped, bbox: union(mapped.map(\.bbox)))
            }
        } else {
            let engineLines = result.lines.compactMap(normalizedWord)
            let lines = makeTesseractLineBoxes(
                engineLines: engineLines,
                words: wordBoxes,
                language: profile.language
            )
            paraBoxes = buildParagraphBoxes(
                from: lines,
                strategy: paragraphStrategy,
                language: profile.language
            )
        }
        let confidenceValues = result.words.map(\.confidence).filter { $0.isFinite && $0 >= 0 }
        let meanConfidence = confidenceValues.isEmpty
            ? -1
            : confidenceValues.reduce(0, +) / Double(confidenceValues.count)
        KindleRunLog.write(
            "KINDLE_OCR_ENGINE engine=tesseract model=\(result.model) " +
            "rawLines=\(result.lines.count) words=\(wordBoxes.count) " +
            "meanConfidence=\(Int(meanConfidence.rounded()))"
        )
        #if DEBUG
        NSLog("CRDBG Kindle Tesseract model=%@ lines=%d words=%d confidence=%d vertical=%@ columns=%d/%d unresolved=%d",
              result.model, result.lines.count, wordBoxes.count, Int(meanConfidence.rounded()),
              result.verticalSource ?? "-", result.verticalColumns,
              result.verticalRequiredColumns, result.verticalUnresolvedColumns)
        #endif
        return makeDocument(
            image: image,
            imageData: png,
            title: title,
            paraBoxes: paraBoxes,
            language: profile.language
        )
    }

    /// Preserve Tesseract's line units and attach each word to exactly one of
    /// those lines. Word-center regrouping alone collapses Hindi list items and
    /// headings because Devanagari has no Latin upper/lowercase boundary signal.
    private func makeTesseractLineBoxes(
        engineLines: [WordBox],
        words: [WordBox],
        language: String
    ) -> [LineBox] {
        guard !engineLines.isEmpty else {
            return rebuildOcrLines(words).map { line in
                LineBox(
                    text: line.text,
                    bbox: union(line.words.map(\.bbox)) ?? .zero,
                    words: line.words
                )
            }
        }

        var assigned = Array(repeating: [WordBox](), count: engineLines.count)
        for word in words {
            let center = CGPoint(x: word.bbox.midX, y: word.bbox.midY)
            let best = engineLines.indices.min { lhs, rhs in
                tesseractLineScore(line: engineLines[lhs].bbox, word: word.bbox, center: center)
                    < tesseractLineScore(line: engineLines[rhs].bbox, word: word.bbox, center: center)
            }
            if let best { assigned[best].append(word) }
        }

        return engineLines.indices.compactMap { index in
            let mapped = assigned[index].sorted { $0.bbox.minX < $1.bbox.minX }
            guard !mapped.isEmpty else { return nil }
            let engineText = engineLines[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = engineText.isEmpty
                ? KindleLanguageContract.join(mapped.map(\.text), language: language)
                : engineText
            return LineBox(text: text, bbox: engineLines[index].bbox, words: mapped)
        }
    }

    private func tesseractLineScore(line: CGRect, word: CGRect, center: CGPoint) -> CGFloat {
        let expanded = line.insetBy(dx: -0.012, dy: -0.004)
        let containsPenalty: CGFloat = expanded.contains(center) ? 0 : 1
        let vertical = abs(line.midY - word.midY) / max(0.001, line.height)
        let horizontal: CGFloat
        if word.maxX < line.minX { horizontal = (line.minX - word.maxX) * 2 }
        else if word.minX > line.maxX { horizontal = (word.minX - line.maxX) * 2 }
        else { horizontal = 0 }
        return containsPenalty + vertical + horizontal
    }

    private func validateKindleDocument(
        _ document: ReadingDocument,
        profile: KindleLanguageProfile,
        engine: KindleOCREngine
    ) throws -> Double {
        guard !document.paragraphs.isEmpty else { throw OCRError.noText }
        let words = document.paragraphs.flatMap(\.words)
        guard !words.isEmpty else { throw OCRError.kindleEngine("ocr-boxes-missing") }
        let textKey = KindleLanguageContract.alignmentText(document.fullText)
        let boxedKey = KindleLanguageContract.alignmentText(words.map(\.text).joined())
        guard !textKey.isEmpty else { throw OCRError.noText }
        let coverage = min(1, Double(boxedKey.count) / Double(max(1, textKey.count)))
        guard coverage >= 0.85 else {
            throw OCRError.kindleEngine(
                "ocr-box-coverage-\(Int((coverage * 100).rounded()))-engine-\(engine.rawValue)"
            )
        }
        if ["zh", "ja", "hi"].contains(profile.language) {
            let evidence = LanguageDetector.evidence(for: document.fullText)
            guard evidence.language == profile.language, evidence.confidence >= 0.55 else {
                throw OCRError.kindleEngine(
                    "ocr-script-mismatch-expected-\(profile.language)-actual-\(evidence.language)"
                )
            }
        }
        return coverage
    }

    /// Kindle fallback for renderer payloads that do not expose language metadata.
    /// Each locale gets its own Vision request. This is intentionally different from
    /// passing all locales to one request, whose first model biased Japanese pages to English.
    func probeKindleLanguage(image: UIImage, titleContext: String) async throws -> KindleOCRLanguageProbe {
        let titleEvidence = LanguageDetector.evidence(for: titleContext)
        var candidates: [KindleOCRLanguageProbe] = []
        for language in SupportedTTSLanguage.allCases {
            do {
                let document = try await recognize(
                    image: image,
                    languages: [language.visionRecognitionLanguage],
                    title: titleContext,
                    paragraphStrategy: .visionLines,
                    languageHint: language.rawValue
                )
                let pageEvidence = LanguageDetector.evidence(for: document.fullText)
                let scored = KindleOCRConsensus.score(
                    page: pageEvidence,
                    requestedLanguage: language.rawValue,
                    title: titleEvidence
                )
                candidates.append(KindleOCRLanguageProbe(
                    language: scored.language,
                    visionLocale: language.visionRecognitionLanguage,
                    readableCharacterCount: pageEvidence.readableCharacterCount,
                    score: scored.value
                ))
            } catch OCRError.noText {
                continue
            } catch OCRError.unsupportedLanguages {
                continue
            }
        }
        guard let best = candidates.max(by: { $0.score < $1.score }),
              best.readableCharacterCount > 0 else {
            throw OCRError.noText
        }
        #if DEBUG
        let summary = candidates.map {
            "\($0.visionLocale):\($0.language):\($0.readableCharacterCount):\(Int($0.score))"
        }.joined(separator: ",")
        NSLog("CRDBG Kindle OCR consensus selected=%@ candidates=%@", best.language, summary)
        #endif
        return best
    }

    // MARK: - Vision

    private struct WordBox { let text: String; let bbox: CGRect }
    private struct LineBox { let text: String; let bbox: CGRect; let words: [WordBox] }

    private func recognizeLines(
        cgImage: CGImage,
        languages: [String],
        language: String?
    ) async throws -> [LineBox] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[LineBox], Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error { cont.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var lines: [LineBox] = []
                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    let str = candidate.string
                    var words: [WordBox] = []
                    // Latin uses words; Chinese/Japanese use grapheme ranges so
                    // a whole no-space line never collapses into one highlight box.
                    for range in KindleOCRTextContract.tokenRanges(in: str, language: language) {
                        if let box = try? candidate.boundingBox(for: range), !box.boundingBox.isNull {
                            words.append(WordBox(text: String(str[range]), bbox: box.boundingBox))
                        }
                    }
                    // Geometry fallback preserves the same script-aware tokens.
                    if words.isEmpty {
                        words = self.splitProportionally(
                            text: str,
                            lineBox: obs.boundingBox,
                            language: language
                        )
                    }
                    lines.append(LineBox(text: str, bbox: obs.boundingBox, words: words))
                }
                cont.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !languages.isEmpty {
                let available = Set((try? request.supportedRecognitionLanguages()) ?? [])
                let supported = languages.filter(available.contains)
                guard !supported.isEmpty else {
                    cont.resume(throwing: OCRError.unsupportedLanguages(languages))
                    return
                }
                request.recognitionLanguages = supported
            }

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do { try handler.perform([request]) }
            catch { cont.resume(throwing: error) }
        }
    }

    private nonisolated func splitProportionally(
        text: String,
        lineBox: CGRect,
        language: String?
    ) -> [WordBox] {
        let tokens = KindleOCRTextContract.tokens(in: text, language: language)
        guard !tokens.isEmpty else { return [] }
        let totalChars = max(1, tokens.reduce(0) { $0 + $1.count + 1 })
        var cursor = lineBox.minX
        var result: [WordBox] = []
        for tok in tokens {
            let frac = CGFloat(tok.count + 1) / CGFloat(totalChars)
            let w = lineBox.width * frac
            result.append(WordBox(text: tok, bbox: CGRect(x: cursor, y: lineBox.minY, width: w * 0.92, height: lineBox.height)))
            cursor += w
        }
        return result
    }

    // MARK: - 段落聚类

    private struct ParagraphBox {
        let text: String
        let words: [WordBox]
        let bbox: CGRect?
    }

    private func makeDocument(
        image: UIImage,
        imageData: Data?,
        title: String?,
        paraBoxes: [ParagraphBox],
        language: String
    ) -> ReadingDocument {
        var paragraphs: [ReadingParagraph] = []
        var globalWordID = 0
        for box in paraBoxes {
            let text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let words = box.words.map { word -> OCRWord in
                defer { globalWordID += 1 }
                return OCRWord(id: globalWordID, text: word.text, bboxNorm: word.bbox)
            }
            paragraphs.append(ReadingParagraph(
                id: paragraphs.count,
                text: text,
                type: .paragraph,
                words: words,
                bboxNorm: box.bbox
            ))
        }
        let pixel = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        return ReadingDocument(
            title: title ?? defaultTitle(from: paragraphs),
            sourceKind: .photo,
            language: language,
            paragraphs: paragraphs,
            imageData: imageData,
            imagePixelSize: pixel,
            sourceURL: nil
        )
    }

    private struct LayoutLine {
        let words: [WordBox]
        let text: String
        let left: CGFloat
        let top: CGFloat
        let right: CGFloat
        let bottom: CGFloat
        let centerY: CGFloat
        let height: CGFloat
    }

    private struct LayoutMetrics {
        let bodyLeft: CGFloat
        let bodyWidth: CGFloat
        let medianGap: CGFloat
        let medianLineHeight: CGFloat
        let medianWordWidth: CGFloat
    }

    private func buildParagraphBoxes(from lines: [LineBox], strategy: OCRParagraphStrategy, language: String?) -> [ParagraphBox] {
        switch strategy {
        case .visionLines:
            return buildVisionParagraphBoxes(lines, language: language)
        case .kindleLayout:
            return rebuildKindleParagraphBoxes(from: lines, language: language)
        }
    }

    private func buildVisionParagraphBoxes(_ lines: [LineBox], language: String?) -> [ParagraphBox] {
        let groups = groupLinesIntoParagraphs(lines)
        return groups.compactMap { group in
            let words = group.flatMap(\.words)
            let text = normalizeOcrParagraphText(
                KindleLanguageContract.join(group.map(\.text), language: language ?? "")
            )
            guard !text.isEmpty else { return nil }
            return ParagraphBox(text: text, words: words, bbox: union(words.map(\.bbox)))
        }
    }

    private func groupLinesIntoParagraphs(_ lines: [LineBox]) -> [[LineBox]] {
        // Vision y 为底部原点，maxY 越大越靠上 → 从上到下排序
        let sorted = lines.sorted { $0.bbox.maxY > $1.bbox.maxY }
        guard !sorted.isEmpty else { return [] }

        let heights = sorted.map { $0.bbox.height }.sorted()
        let medianH = heights[heights.count / 2]

        var groups: [[LineBox]] = []
        var current: [LineBox] = [sorted[0]]
        for prevNext in zip(sorted, sorted.dropFirst()) {
            let prev = prevNext.0, next = prevNext.1
            let gap = prev.bbox.minY - next.bbox.maxY            // 行间垂直空隙（归一化）
            let indentJump = abs(next.bbox.minX - prev.bbox.minX)
            let newParagraph = gap > medianH * 1.1 || indentJump > 0.08
            if newParagraph {
                groups.append(current)
                current = [next]
            } else {
                current.append(next)
            }
        }
        groups.append(current)
        return groups
    }

    private func rebuildKindleParagraphBoxes(from lines: [LineBox], language: String?) -> [ParagraphBox] {
        let raw = buildVisionParagraphBoxes(lines, language: language)
        let fallback = repairBrokenContinuations(raw, language: language)
        let wordBoxes = lines.flatMap(\.words)
        let layoutLines = rebuildOcrLines(wordBoxes)
        guard !layoutLines.isEmpty else { return fallback }
        if layoutLines.count == 1 {
            return [makeParagraphBox(from: layoutLines)]
        }

        let gaps = zip(layoutLines, layoutLines.dropFirst())
            .map { prev, next in next.top - prev.bottom }
            .filter { $0 >= 0 }
        let medianLineHeight = median(layoutLines.map(\.height), fallback: 0.014)
        let medianGap = max(0.001, median(gaps, fallback: medianLineHeight * 0.35))
        let bodyLeft = percentile(layoutLines.map(\.left), p: 0.2, fallback: layoutLines[0].left)
        let rightMost = percentile(layoutLines.map(\.right), p: 0.9, fallback: layoutLines[0].right)
        let medianWordWidth = median(
            wordBoxes.map { $0.bbox.width }.filter { $0 > 0 },
            fallback: medianLineHeight * 1.8
        )
        let metrics = LayoutMetrics(
            bodyLeft: bodyLeft,
            bodyWidth: max(0.001, rightMost - bodyLeft),
            medianGap: medianGap,
            medianLineHeight: medianLineHeight,
            medianWordWidth: medianWordWidth
        )

        var paragraphs: [ParagraphBox] = []
        var current: [LayoutLine] = [layoutLines[0]]
        for idx in 1..<layoutLines.count {
            let prev = layoutLines[idx - 1]
            let next = layoutLines[idx]
            if shouldStartNewOcrParagraph(prev: prev, next: next, metrics: metrics, language: language) {
                paragraphs.append(makeParagraphBox(from: current))
                current = [next]
            } else {
                current.append(next)
            }
        }
        paragraphs.append(makeParagraphBox(from: current))

        let repaired = repairBrokenContinuations(paragraphs, language: language).filter { !$0.text.isEmpty }
        guard !repaired.isEmpty else { return fallback }

        if KindleLanguageContract.shouldPreferRawParagraphs(
            language: language ?? "",
            raw: raw.count,
            visualLines: layoutLines.count,
            rebuilt: repaired.count
        ) {
            return raw
        }

        let largestLines = repaired.map { rebuildOcrLines($0.words).count }.max() ?? 0
        let collapsedTooMuch =
            fallback.count >= 4 &&
            (repaired.count <= max(1, fallback.count / 3) || largestLines >= 12)
        if collapsedTooMuch {
            NSLog("CRDBG OCR kindleLayout fallback raw=%d lines=%d rebuilt=%d largestLines=%d",
                  fallback.count, layoutLines.count, repaired.count, largestLines)
            return fallback
        }

        NSLog("CRDBG OCR kindleLayout raw=%d lines=%d rebuilt=%d lineH=%.4f gap=%.4f",
              fallback.count, layoutLines.count, repaired.count, medianLineHeight, medianGap)
        return repaired
    }

    private func rebuildOcrLines(_ words: [WordBox]) -> [LayoutLine] {
        let valid = words
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.bbox.width > 0 && $0.bbox.height > 0 }
            .sorted { a, b in
                let ac = layoutCenterY(a.bbox)
                let bc = layoutCenterY(b.bbox)
                if abs(ac - bc) > 0.003 { return ac < bc }
                return a.bbox.minX < b.bbox.minX
            }
        guard !valid.isEmpty else { return [] }

        let medianWordHeight = median(valid.map { layoutHeight($0.bbox) }, fallback: 0.012)
        let baseYTolerance = max(0.004, medianWordHeight * 0.62)
        var groups: [[WordBox]] = []

        for word in valid {
            let centerY = layoutCenterY(word.bbox)
            var bestIdx = -1
            var bestDelta = CGFloat.greatestFiniteMagnitude
            for idx in groups.indices {
                let line = rebuildLine(groups[idx])
                let tolerance = max(baseYTolerance, line.height * 0.7)
                let delta = abs(centerY - line.centerY)
                if delta <= tolerance && delta < bestDelta {
                    bestIdx = idx
                    bestDelta = delta
                }
            }
            if bestIdx >= 0 {
                groups[bestIdx].append(word)
            } else {
                groups.append([word])
            }
        }

        return groups
            .map(rebuildLine)
            .filter { !$0.text.isEmpty }
            .sorted { a, b in
                if abs(a.top - b.top) > max(0.004, medianWordHeight * 0.5) { return a.top < b.top }
                return a.left < b.left
            }
    }

    private func rebuildLine(_ words: [WordBox]) -> LayoutLine {
        let sorted = words.sorted { $0.bbox.minX < $1.bbox.minX }
        let left = sorted.map { $0.bbox.minX }.min() ?? 0
        let right = sorted.map { $0.bbox.maxX }.max() ?? left
        let top = sorted.map { layoutTop($0.bbox) }.min() ?? 0
        let bottom = sorted.map { layoutBottom($0.bbox) }.max() ?? top
        return LayoutLine(
            words: sorted,
            text: joinOcrWordTexts(sorted.map(\.text)),
            left: left,
            top: top,
            right: right,
            bottom: bottom,
            centerY: (top + bottom) / 2,
            height: max(0.001, bottom - top)
        )
    }

    private func makeParagraphBox(from lines: [LayoutLine]) -> ParagraphBox {
        let words = lines.flatMap(\.words)
        return ParagraphBox(
            text: joinOcrLineTexts(lines),
            words: words,
            bbox: union(words.map(\.bbox))
        )
    }

    private func shouldStartNewOcrParagraph(prev: LayoutLine, next: LayoutLine, metrics: LayoutMetrics, language: String?) -> Bool {
        let normalizedLanguage = KindleLanguageContract.normalize(language) ?? ""
        let caseless = ["zh", "ja", "hi"].contains(normalizedLanguage)
        let gap = next.top - prev.bottom
        let bigGap = gap > max(metrics.medianGap * 1.65, metrics.medianLineHeight * 0.75)
        let nextIndent = next.left - metrics.bodyLeft
        let indented = nextIndent > max(0.012, metrics.medianLineHeight * 0.9, metrics.medianWordWidth * 0.45)
        let prevShort = prev.right - prev.left < metrics.bodyWidth * 0.58

        // Lists and bullets are paragraph authority in every script. This must
        // run before the hard-terminal check because headings commonly end in
        // neither Latin nor CJK sentence punctuation.
        if KindleLanguageContract.startsWithListMarker(next.text) { return true }
        if caseless,
           KindleLanguageContract.endsWithHeadingDelimiter(prev.text),
           (prevShort || bigGap || indented) { return true }
        if !caseless && (isLikelyOcrHeading(prev.text) || isLikelyOcrHeading(next.text)) { return true }
        if !caseless && startsWithLowercaseLetter(next.text) { return false }
        if !endsWithHardTerminal(prev.text) { return false }

        return bigGap || indented || (prevShort && gap > metrics.medianGap * 1.25)
    }

    private func repairBrokenContinuations(_ paragraphs: [ParagraphBox], language: String?) -> [ParagraphBox] {
        var output: [ParagraphBox] = []
        for paragraph in paragraphs {
            guard let last = output.last else {
                output.append(paragraph)
                continue
            }
            if shouldMergeBrokenOcrParagraph(prev: last.text, next: paragraph.text, language: language) {
                output.removeLast()
                let words = last.words + paragraph.words
                output.append(ParagraphBox(
                    text: joinOcrParagraphs(prev: last.text, next: paragraph.text, language: language),
                    words: words,
                    bbox: union(words.map(\.bbox))
                ))
            } else {
                output.append(paragraph)
            }
        }
        return output
    }

    private func shouldMergeBrokenOcrParagraph(prev: String, next: String, language: String?) -> Bool {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || n.isEmpty { return false }
        let caseless = ["zh", "ja", "hi"].contains(KindleLanguageContract.normalize(language) ?? "")
        if KindleLanguageContract.startsWithListMarker(n) { return false }
        if !caseless && (isLikelyOcrHeading(p) || isLikelyOcrHeading(n)) { return false }
        if endsWithDash(p) { return true }
        if endsWithHardTerminal(p) { return false }
        if !caseless && startsWithLowercaseLetter(n) { return true }
        return endsWithSoftContinuationPunctuation(p)
    }

    private func joinOcrParagraphs(prev: String, next: String, language: String?) -> String {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if endsWithDash(p) {
            return String(p.dropLast()) + n
        }
        return normalizeOcrParagraphText(KindleLanguageContract.join([p, n], language: language ?? ""))
    }

    private func joinOcrLineTexts(_ lines: [LayoutLine]) -> String {
        var text = ""
        for line in lines {
            let part = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if text.isEmpty {
                text = part
            } else if endsWithDash(text) {
                text += part
            } else if shouldInsertSpace(between: text, and: part) {
                text += " " + part
            } else {
                text += part
            }
        }
        return normalizeOcrParagraphText(text)
    }

    private func joinOcrWordTexts(_ words: [String]) -> String {
        var text = ""
        for raw in words {
            let part = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if text.isEmpty {
                text = part
            } else if shouldInsertSpace(between: text, and: part) {
                text += " " + part
            } else {
                text += part
            }
        }
        return normalizeOcrParagraphText(text)
    }

    private func shouldInsertSpace(between leftText: String, and rightText: String) -> Bool {
        guard let left = leftText.unicodeScalars.last,
              let right = rightText.unicodeScalars.first else { return false }
        if isCJK(left) || isCJK(right) { return false }
        if CharacterSet.punctuationCharacters.contains(right) { return false }
        if dashScalars.contains(left) { return false }
        return true
    }

    private var dashScalars: Set<UnicodeScalar> {
        Set("-‐‑‒–—―".unicodeScalars)
    }

    private func endsWithDash(_ text: String) -> Bool {
        guard let scalar = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last else { return false }
        return dashScalars.contains(scalar)
    }

    private func endsWithSoftContinuationPunctuation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var scalars = Array(trimmed.unicodeScalars)
        let closers = Set("\"')]\u{201D}\u{2019}".unicodeScalars)
        while let last = scalars.last, closers.contains(last) {
            scalars.removeLast()
        }
        guard let last = scalars.last else { return false }
        return Set(",;:–—".unicodeScalars).contains(last)
    }

    private func isCJK(_ scalar: UnicodeScalar) -> Bool {
        (0x4E00...0x9FFF).contains(Int(scalar.value)) ||
        (0x3400...0x4DBF).contains(Int(scalar.value)) ||
        (0x3040...0x30FF).contains(Int(scalar.value)) ||
        (0xAC00...0xD7AF).contains(Int(scalar.value))
    }

    private func normalizeOcrParagraphText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    private func isLikelyOcrHeading(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.range(of: #"^(chapter|book|part|contents)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let lowercase = t.unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) }
        return t.count <= 90 && letters.count >= 5 && lowercase.isEmpty
    }

    private func firstLetter(_ text: String) -> String {
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            return String(scalar)
        }
        return ""
    }

    private func startsWithLowercaseLetter(_ text: String) -> Bool {
        let c = firstLetter(text)
        return !c.isEmpty && c == c.lowercased() && c != c.uppercased()
    }

    private func endsWithHardTerminal(_ text: String) -> Bool {
        KindleLanguageContract.endsWithHardTerminal(text)
    }

    private func layoutTop(_ bbox: CGRect) -> CGFloat { 1 - bbox.maxY }
    private func layoutBottom(_ bbox: CGRect) -> CGFloat { 1 - bbox.minY }
    private func layoutHeight(_ bbox: CGRect) -> CGFloat { max(0.001, layoutBottom(bbox) - layoutTop(bbox)) }
    private func layoutCenterY(_ bbox: CGRect) -> CGFloat { (layoutTop(bbox) + layoutBottom(bbox)) / 2 }

    private func union(_ rects: [CGRect]) -> CGRect? {
        guard var result = rects.first else { return nil }
        for rect in rects.dropFirst() {
            result = result.union(rect)
        }
        return result
    }

    private func median(_ values: [CGFloat], fallback: CGFloat) -> CGFloat {
        let xs = values.filter { $0.isFinite }.sorted()
        guard !xs.isEmpty else { return fallback }
        let mid = xs.count / 2
        if xs.count % 2 == 1 { return xs[mid] }
        return (xs[mid - 1] + xs[mid]) / 2
    }

    private func percentile(_ values: [CGFloat], p: CGFloat, fallback: CGFloat) -> CGFloat {
        let xs = values.filter { $0.isFinite }.sorted()
        guard !xs.isEmpty else { return fallback }
        let idx = max(0, min(xs.count - 1, Int(CGFloat(xs.count - 1) * p)))
        return xs[idx]
    }

    // MARK: - 杂项

    private func detectLanguage(_ text: String) -> String {
        LanguageDetector.detect(text)
    }

    private func defaultTitle(from paragraphs: [ReadingParagraph]) -> String {
        let first = paragraphs.first?.text ?? "Scanned Text"
        return String(first.prefix(40))
    }
}
