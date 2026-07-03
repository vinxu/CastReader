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

actor OCRService {
    static let shared = OCRService()
    private init() {}

    /// 识别图片文字，按行聚合为段落。languages 为 BCP-47（如 ["en-US"]、["zh-Hans","en-US"]）。
    func recognize(
        image: UIImage,
        languages: [String],
        title: String? = nil,
        paragraphStrategy: OCRParagraphStrategy = .visionLines
    ) async throws -> ReadingDocument {
        guard let cg = image.cgImage else { throw OCRError.noCGImage }

        let lines = try await recognizeLines(cgImage: cg, languages: languages)
        guard !lines.isEmpty else { throw OCRError.noText }

        let paraBoxes = buildParagraphBoxes(from: lines, strategy: paragraphStrategy)
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
        let lang = detectLanguage(joined)
        NSLog("CRDBG OCR strategy=%@ paras=%d lang=%@ chars=%d head=%@",
              paragraphStrategy.logName, paragraphs.count, lang, joined.count, String(joined.prefix(50)))
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

    private struct ParagraphBox {
        let text: String
        let words: [WordBox]
        let bbox: CGRect?
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

    private func buildParagraphBoxes(from lines: [LineBox], strategy: OCRParagraphStrategy) -> [ParagraphBox] {
        switch strategy {
        case .visionLines:
            return buildVisionParagraphBoxes(lines)
        case .kindleLayout:
            return rebuildKindleParagraphBoxes(from: lines)
        }
    }

    private func buildVisionParagraphBoxes(_ lines: [LineBox]) -> [ParagraphBox] {
        let groups = groupLinesIntoParagraphs(lines)
        return groups.compactMap { group in
            let words = group.flatMap(\.words)
            let text = normalizeOcrParagraphText(group.map(\.text).joined(separator: " "))
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

    private func rebuildKindleParagraphBoxes(from lines: [LineBox]) -> [ParagraphBox] {
        let fallback = repairBrokenContinuations(buildVisionParagraphBoxes(lines))
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
            if shouldStartNewOcrParagraph(prev: prev, next: next, metrics: metrics) {
                paragraphs.append(makeParagraphBox(from: current))
                current = [next]
            } else {
                current.append(next)
            }
        }
        paragraphs.append(makeParagraphBox(from: current))

        let repaired = repairBrokenContinuations(paragraphs).filter { !$0.text.isEmpty }
        guard !repaired.isEmpty else { return fallback }

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

    private func shouldStartNewOcrParagraph(prev: LayoutLine, next: LayoutLine, metrics: LayoutMetrics) -> Bool {
        if isLikelyOcrHeading(prev.text) || isLikelyOcrHeading(next.text) { return true }
        if startsWithLowercaseLetter(next.text) { return false }
        if !endsWithHardTerminal(prev.text) { return false }

        let gap = next.top - prev.bottom
        let bigGap = gap > max(metrics.medianGap * 1.65, metrics.medianLineHeight * 0.75)
        let nextIndent = next.left - metrics.bodyLeft
        let indented = nextIndent > max(0.012, metrics.medianLineHeight * 0.9, metrics.medianWordWidth * 0.45)
        let prevShort = prev.right - prev.left < metrics.bodyWidth * 0.58

        return bigGap || indented || (prevShort && gap > metrics.medianGap * 1.25)
    }

    private func repairBrokenContinuations(_ paragraphs: [ParagraphBox]) -> [ParagraphBox] {
        var output: [ParagraphBox] = []
        for paragraph in paragraphs {
            guard let last = output.last else {
                output.append(paragraph)
                continue
            }
            if shouldMergeBrokenOcrParagraph(prev: last.text, next: paragraph.text) {
                output.removeLast()
                let words = last.words + paragraph.words
                output.append(ParagraphBox(
                    text: joinOcrParagraphs(prev: last.text, next: paragraph.text),
                    words: words,
                    bbox: union(words.map(\.bbox))
                ))
            } else {
                output.append(paragraph)
            }
        }
        return output
    }

    private func shouldMergeBrokenOcrParagraph(prev: String, next: String) -> Bool {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || n.isEmpty { return false }
        if isLikelyOcrHeading(p) || isLikelyOcrHeading(n) { return false }
        if endsWithDash(p) { return true }
        if endsWithHardTerminal(p) { return false }
        if startsWithLowercaseLetter(n) { return true }
        return endsWithSoftContinuationPunctuation(p)
    }

    private func joinOcrParagraphs(prev: String, next: String) -> String {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if endsWithDash(p) {
            return String(p.dropLast()) + n
        }
        return normalizeOcrParagraphText("\(p) \(n)")
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
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"[.!?。！？]["')\]\u{201D}\u{2019}]*$"#, options: .regularExpression) != nil
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
