import Foundation

/// Aligns the same passage after OCR line wrapping changes. Local sequence
/// alignment tolerates a missing token and split/joined hyphenated words, while
/// requiring several exact words and the actual spoken/annotated anchor.
enum KindleViewportTextAlignment {
    struct Pair: Equatable {
        let original: Int
        let captured: Int
    }

    static func remainingParagraphs(_ paragraphs: [ReadingParagraph], afterParagraph: Int, afterWord: Int) -> [ReadingParagraph]? {
        guard let boundary = paragraphs.first(where: { $0.id == afterParagraph }),
              boundary.words.indices.contains(afterWord) else { return nil }
        var result: [ReadingParagraph] = []
        for paragraph in paragraphs.sorted(by: { $0.id < $1.id }) where paragraph.id >= afterParagraph {
            let start = paragraph.id == afterParagraph ? afterWord + 1 : 0
            guard start < paragraph.words.count else { continue }
            var text = paragraph.text
            if start > 0 {
                let source = paragraph.text as NSString
                var cursor = 0
                for word in paragraph.words.prefix(start) {
                    let found = source.range(of: word.text, range: NSRange(location: cursor, length: source.length - cursor))
                    guard found.location != NSNotFound else { return nil }
                    cursor = NSMaxRange(found)
                }
                text = source.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let words = Array(paragraph.words.dropFirst(start))
            result.append(ReadingParagraph(id: result.count, text: text, type: paragraph.type,
                words: words, bboxNorm: ReadingGeometry.unionNorm(words.map(\.bboxNorm)), pageIndex: paragraph.pageIndex))
        }
        return result
    }

    static func match(original: [String], captured: [String], anchor: Int?) -> [Pair]? {
        guard !original.isEmpty, !captured.isEmpty else { return nil }
        let columns = captured.count + 1
        var scores = [Int](repeating: 0, count: (original.count + 1) * columns)
        var steps = [UInt8](repeating: 0, count: scores.count)
        var best = 0
        for i in 1...original.count {
            for j in 1...captured.count {
                let index = i * columns + j
                let exact = !original[i - 1].isEmpty && original[i - 1] == captured[j - 1]
                var score = scores[index - columns - 1] + (exact ? 5 : -6)
                var step: UInt8 = 1
                if i > 1, original[i - 2] + original[i - 1] == captured[j - 1],
                   !original[i - 2].isEmpty, !original[i - 1].isEmpty {
                    let joined = scores[index - 2 * columns - 1] + 10
                    if joined > score { score = joined; step = 4 }
                }
                if j > 1, original[i - 1] == captured[j - 2] + captured[j - 1],
                   !captured[j - 2].isEmpty, !captured[j - 1].isEmpty {
                    let split = scores[index - columns - 2] + 10
                    if split > score { score = split; step = 5 }
                }
                if scores[index - columns] - 6 > score { score = scores[index - columns] - 6; step = 2 }
                if scores[index - 1] - 6 > score { score = scores[index - 1] - 6; step = 3 }
                if score > 0 {
                    scores[index] = score; steps[index] = step
                    if score > scores[best] { best = index }
                }
            }
        }
        guard scores[best] >= 20 else { return nil }
        var pairs: [Pair] = []
        var i = best / columns, j = best % columns
        while i > 0, j > 0, scores[i * columns + j] > 0 {
            switch steps[i * columns + j] {
            case 1:
                if original[i - 1] == captured[j - 1] { pairs.append(Pair(original: i - 1, captured: j - 1)) }
                i -= 1; j -= 1
            case 2: i -= 1
            case 3: j -= 1
            case 4:
                pairs.append(Pair(original: i - 1, captured: j - 1))
                pairs.append(Pair(original: i - 2, captured: j - 1))
                i -= 2; j -= 1
            case 5:
                pairs.append(Pair(original: i - 1, captured: j - 1))
                pairs.append(Pair(original: i - 1, captured: j - 2))
                i -= 1; j -= 2
            default: return nil
            }
        }
        pairs.reverse()
        let originals = Set(pairs.map(\.original))
        guard originals.count >= 4,
              originals.reduce(0, { $0 + original[$1].count }) >= 24,
              anchor.map({ originals.contains($0) }) ?? true else { return nil }
        return pairs
    }
}
