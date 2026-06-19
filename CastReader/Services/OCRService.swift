//
//  OCRService.swift
//  CastReader
//
//  端上 Vision 文字识别：UIImage → ReadingDocument(.photo)，含逐词归一化 bbox（原点左下）。
//

import Foundation
import Vision
import UIKit

enum OCRError: Error, LocalizedError {
    case noCGImage
    case noText

    var errorDescription: String? {
        switch self {
        case .noCGImage: return String(localized: "无法读取图片")
        case .noText: return String(localized: "未识别到文字")
        }
    }
}

actor OCRService {
    static let shared = OCRService()
    private init() {}

    /// 识别图片文字，按行聚合为段落。languages 为 BCP-47（如 ["en-US"]、["zh-Hans","en-US"]）。
    func recognize(image: UIImage, languages: [String], title: String? = nil) async throws -> ReadingDocument {
        guard let cg = image.cgImage else { throw OCRError.noCGImage }

        let lines = try await recognizeLines(cgImage: cg, languages: languages)
        guard !lines.isEmpty else { throw OCRError.noText }

        // 行 → 段落聚类
        let paraGroups = groupLinesIntoParagraphs(lines)

        var paragraphs: [ReadingParagraph] = []
        var globalWordId = 0
        for (pIdx, group) in paraGroups.enumerated() {
            var words: [OCRWord] = []
            var pieces: [String] = []
            var union: CGRect? = nil
            for line in group {
                for w in line.words {
                    words.append(OCRWord(id: globalWordId, text: w.text, bboxNorm: w.bbox))
                    globalWordId += 1
                    union = union == nil ? w.bbox : union!.union(w.bbox)
                }
                pieces.append(line.text)
            }
            let text = pieces.joined(separator: " ")
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            paragraphs.append(ReadingParagraph(id: pIdx, text: text, type: .paragraph,
                                               words: words, bboxNorm: union))
        }

        // 重排连续 id
        paragraphs = paragraphs.enumerated().map { (i, p) in
            ReadingParagraph(id: i, text: p.text, type: p.type, words: p.words, bboxNorm: p.bboxNorm)
        }

        let joined = paragraphs.map(\.text).joined(separator: " ")
        let lang = detectLanguage(joined)
        NSLog("CRDBG OCR lang=%@ chars=%d head=%@", lang, joined.count, String(joined.prefix(50)))
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

    // MARK: - Vision

    private struct WordBox { let text: String; let bbox: CGRect }
    private struct LineBox { let text: String; let bbox: CGRect; let words: [WordBox] }

    private func recognizeLines(cgImage: CGImage, languages: [String]) async throws -> [LineBox] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[LineBox], Error>) in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error { cont.resume(throwing: error); return }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                var lines: [LineBox] = []
                for obs in observations {
                    guard let candidate = obs.topCandidates(1).first else { continue }
                    let str = candidate.string
                    var words: [WordBox] = []
                    // 逐词（空白切分）求 bbox
                    self.enumerateWordRanges(in: str) { range in
                        if let box = try? candidate.boundingBox(for: range), !box.boundingBox.isNull {
                            words.append(WordBox(text: String(str[range]), bbox: box.boundingBox))
                        }
                    }
                    // 兜底：逐词失败则按字符比例切分整行框
                    if words.isEmpty {
                        words = self.splitProportionally(text: str, lineBox: obs.boundingBox)
                    }
                    lines.append(LineBox(text: str, bbox: obs.boundingBox, words: words))
                }
                cont.resume(returning: lines)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            if !languages.isEmpty { request.recognitionLanguages = languages }

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])
            do { try handler.perform([request]) }
            catch { cont.resume(throwing: error) }
        }
    }

    private nonisolated func enumerateWordRanges(in s: String, _ body: (Range<String.Index>) -> Void) {
        var idx = s.startIndex
        while idx < s.endIndex {
            // 跳过空白
            while idx < s.endIndex, s[idx].isWhitespace { idx = s.index(after: idx) }
            guard idx < s.endIndex else { break }
            let start = idx
            while idx < s.endIndex, !s[idx].isWhitespace { idx = s.index(after: idx) }
            body(start..<idx)
        }
    }

    private nonisolated func splitProportionally(text: String, lineBox: CGRect) -> [WordBox] {
        let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
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

    // MARK: - 杂项

    private func detectLanguage(_ text: String) -> String {
        LanguageDetector.detect(text)
    }

    private func defaultTitle(from paragraphs: [ReadingParagraph]) -> String {
        let first = paragraphs.first?.text ?? "Scanned Text"
        return String(first.prefix(40))
    }
}
