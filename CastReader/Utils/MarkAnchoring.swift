//
//  MarkAnchoring.swift
//  CastReader
//
//  把解读 mark 的锚文本（可能带【】或被改写）模糊定位到某段落的字符范围。
//  失败即返回 nil（fail-open，跳过该 mark，宁缺毋错）。
//

import Foundation

struct MarkHit: Equatable {
    let paragraphIndex: Int
    let range: Range<Int>      // paragraph.text 的字符（Character）范围
}

enum MarkAnchoring {

    /// 在文档中定位 markText。先在 near 段落附近找，再放宽到全文。
    static func locate(markText raw: String, in document: ReadingDocument, near: Int?) -> MarkHit? {
        let query = normalize(Array(strippingDecorations(raw))).norm
        guard query.count >= 2 else { return nil }

        // 搜索顺序：near 及其邻域优先，再其余。
        let order = searchOrder(count: document.paragraphs.count, near: near)
        for idx in order {
            let para = document.paragraphs[idx]
            guard para.type.isReadable, !para.text.isEmpty else { continue }
            if let r = match(query: query, inParagraph: para.text) {
                return MarkHit(paragraphIndex: idx, range: r)
            }
        }
        return nil
    }

    // MARK: - 单段匹配（阶梯）

    private static func match(query: [Character], inParagraph text: String) -> Range<Int>? {
        let (norm, map) = normalize(Array(text))
        guard !norm.isEmpty else { return nil }

        // ① 归一化精确子串
        if let r = indexOf(query, in: norm, from: 0) {
            return originalRange(normStart: r, normEnd: r + query.count, map: map, originalCount: text.count)
        }

        // ② 首尾窗口匹配（容忍中间改写）
        let k = max(3, min(10, query.count / 3))
        guard query.count > k * 2 else { return nil }
        let head = Array(query.prefix(k))
        let tail = Array(query.suffix(k))
        guard let hs = indexOf(head, in: norm, from: 0) else { return nil }
        guard let ts = indexOf(tail, in: norm, from: hs + head.count) else { return nil }
        let spanStart = hs
        let spanEnd = ts + tail.count
        let spanLen = spanEnd - spanStart
        // 跨度需与查询长度同量级
        guard spanLen >= query.count / 2, spanLen <= query.count * 2 else { return nil }
        return originalRange(normStart: spanStart, normEnd: spanEnd, map: map, originalCount: text.count)
    }

    // MARK: - 归一化（保留回原偏移的映射）

    /// 归一化：只保留字母/数字/表意文字（汉字·假名·谚文），标点/装饰/符号一律剔除（对齐扩展 fuzzyFind 的 clean），
    /// 空白坍缩为单空格。map[i] = 第 i 个归一化字符对应的原始字符索引（供回填原文范围）。
    /// 剔除标点能容忍 LLM 锚文本里多出的【】《》（）…、引号、破折号等与原文的差异——匹配失败的主因。
    private static func normalize(_ chars: [Character]) -> (norm: [Character], map: [Int]) {
        var out: [Character] = []
        var map: [Int] = []
        var lastWasSpace = false
        for (i, ch) in chars.enumerated() {
            if ch.isWhitespace {
                if lastWasSpace || out.isEmpty { continue }
                out.append(" "); map.append(i); lastWasSpace = true
            } else if ch.isLetter || ch.isNumber {
                let lower = ch.lowercased().first ?? ch
                out.append(lower); map.append(i); lastWasSpace = false
            }
            // 标点/装饰/符号（含【】《》（）…、各式引号、破折号）→ 剔除，不进归一化串
        }
        // 去掉尾随空格
        while out.last == " " { out.removeLast(); map.removeLast() }
        return (out, map)
    }

    private static func strippingDecorations(_ s: String) -> String {
        var t = s
        for ch in ["【", "】", "〔", "〕", "「", "」", "『", "』"] {
            t = t.replacingOccurrences(of: ch, with: "")
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func originalRange(normStart: Int, normEnd: Int, map: [Int], originalCount: Int) -> Range<Int> {
        let start = (normStart >= 0 && normStart < map.count) ? map[normStart] : 0
        let end = (normEnd < map.count) ? map[normEnd] : originalCount
        return start..<max(start + 1, end)
    }

    private static func indexOf(_ needle: [Character], in hay: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count, from >= 0 else { return nil }
        var i = from
        let last = hay.count - needle.count
        while i <= last {
            var j = 0
            while j < needle.count && hay[i + j] == needle[j] { j += 1 }
            if j == needle.count { return i }
            i += 1
        }
        return nil
    }

    /// near → near±1 → near±2 … 然后其余。
    private static func searchOrder(count: Int, near: Int?) -> [Int] {
        guard count > 0 else { return [] }
        guard let n = near, n >= 0, n < count else { return Array(0..<count) }
        var order: [Int] = []
        var seen = Set<Int>()
        for d in 0..<count {
            for cand in [n - d, n + d] where cand >= 0 && cand < count && !seen.contains(cand) {
                order.append(cand); seen.insert(cand)
            }
            if order.count == count { break }
        }
        return order
    }
}
