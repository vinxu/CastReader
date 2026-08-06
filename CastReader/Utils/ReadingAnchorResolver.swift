//
//  ReadingAnchorResolver.swift
//  CastReader
//
//  定位抽象：把「段落 + 词索引」或「段落 + 字符范围」解析为可绘制的矩形。
//  - 照片源：用 OCRWord.bboxNorm + 显示几何（PhotoAnchorResolver）。
//  - 文本源：用 UITextView 布局（TextAnchorResolver，见 Reader 层，M3 实现）。
//

import CoreGraphics
import Foundation

protocol ReadingAnchorResolver {
    /// 朗读：当前段落内第 wordIndex 个词的矩形（可能跨行返回多个）。
    func rectsForWord(paragraphIndex: Int, wordIndex: Int) -> [CGRect]
    /// 解读：段落内 [range] 字符范围覆盖的矩形（按行返回）。
    func rectsForCharRange(paragraphIndex: Int, range: Range<Int>) -> [CGRect]
}

// MARK: - Photo 源实现（纯几何，无 UIKit）

struct PhotoAnchorResolver: ReadingAnchorResolver {
    let document: ReadingDocument
    /// 图片在容器内 aspectFit 后的显示矩形（SwiftUI 点，未缩放）。
    let fitted: CGRect

    func rectsForWord(paragraphIndex: Int, wordIndex: Int) -> [CGRect] {
        guard let para = paragraph(paragraphIndex),
              wordIndex >= 0, wordIndex < para.words.count else { return [] }
        return [ReadingGeometry.displayRect(forNorm: para.words[wordIndex].bboxNorm, in: fitted)]
    }

    func rectsForCharRange(paragraphIndex: Int, range: Range<Int>) -> [CGRect] {
        guard let para = paragraph(paragraphIndex), !para.words.isEmpty else { return [] }
        let hitWords = wordsIntersecting(charRange: range, in: para)
        guard !hitWords.isEmpty else { return [] }
        // 按行（归一化 midY 接近）分组后并集，再换算到显示坐标。
        let lines = groupByLine(hitWords.map { $0.bboxNorm })
        return lines.compactMap { ReadingGeometry.unionNorm($0) }
            .map { ReadingGeometry.displayRect(forNorm: $0, in: fitted) }
    }

    // MARK: helpers

    private func paragraph(_ index: Int) -> ReadingParagraph? {
        guard index >= 0, index < document.paragraphs.count else { return nil }
        return document.paragraphs[index]
    }

    /// 计算每个词在 paragraph.text 中的字符范围，返回与 charRange 相交的词。
    private func wordsIntersecting(charRange: Range<Int>, in para: ReadingParagraph) -> [OCRWord] {
        let chars = Array(para.text)
        var cursor = 0
        var result: [OCRWord] = []
        for w in para.words {
            let wChars = Array(w.text)
            guard !wChars.isEmpty else { continue }
            if let found = findSub(wChars, in: chars, from: cursor) {
                let wordRange = found..<(found + wChars.count)
                if wordRange.overlaps(charRange) { result.append(w) }
                cursor = found + wChars.count
            }
        }
        return result
    }

    private func findSub(_ needle: [Character], in hay: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, from <= hay.count - needle.count else {
            return from <= hay.count - needle.count ? nil : nil
        }
        var i = from
        while i <= hay.count - needle.count {
            var j = 0
            while j < needle.count && hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i }
            i += 1
        }
        return nil
    }

    /// 按归一化 y（行）聚类矩形。Vision y 为底部原点，同一行 midY 接近。
    /// 多栏版面上一个逻辑段落可以跨栏，所以同一「行」还必须在 x 方向连续：
    /// 否则左右两栏同高度的词会被并成一个横跨栏缝的矩形，标注就画到空白上了。
    private func groupByLine(_ rects: [CGRect]) -> [[CGRect]] {
        guard !rects.isEmpty else { return [] }
        let tol = (rects.map(\.height).max() ?? 0.01) * 0.6
        let sorted = rects.sorted { a, b in
            if abs(a.midY - b.midY) > tol { return a.midY > b.midY }   // 从上到下（y 大在上）
            return a.minX < b.minX
        }
        var lines: [[CGRect]] = []
        var current: [CGRect] = [sorted[0]]
        var lineY = sorted[0].midY
        var runMaxX = sorted[0].maxX
        for r in sorted.dropFirst() {
            let sameRow = abs(r.midY - lineY) <= tol
            let contiguous = r.minX - runMaxX <= Self.maxIntraLineGap
            if sameRow && contiguous {
                current.append(r)
                runMaxX = max(runMaxX, r.maxX)
            } else {
                lines.append(current)
                current = [r]
                lineY = r.midY
                runMaxX = r.maxX
            }
        }
        lines.append(current)
        return lines
    }

    /// 同一行内相邻词的最大空隙（归一化页宽）。超过即视为跨越栏缝或制表空白，
    /// 该行在此断开，分别绘制。
    private static let maxIntraLineGap: CGFloat = 0.035
}
