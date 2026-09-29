import Foundation

/// Speech boundaries belong to the source text, not the viewport or an OCR
/// rectangle. Ranges use Character offsets, matching Kindle's word mapping.
/// This planner never inserts punctuation or drops an unfinished page suffix.
enum KindleSpeechTextPlan {
    static func sentenceRanges(in text: String) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        var ends: [String.Index] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex,
                                 options: [.bySentences, .substringNotRequired]) { _, range, _, _ in
            if !endsInAbbreviation(String(text[..<range.upperBound])) {
                ends.append(range.upperBound)
            }
        }
        if ends.last != text.endIndex { ends.append(text.endIndex) }
        var start = text.startIndex
        return ends.compactMap { end in
            guard end > start else { return nil }
            defer { start = end }
            var lower = start
            var upper = end
            while lower < upper, text[lower].isWhitespace { lower = text.index(after: lower) }
            while upper > lower, text[text.index(before: upper)].isWhitespace { upper = text.index(before: upper) }
            return lower < upper ? NSRange(lower..<upper, in: text) : nil
        }
    }

    static func chunkRanges(
        in text: String,
        targetLength: Int = 240,
        maximumLength: Int = 600
    ) -> [Range<Int>] {
        guard !text.isEmpty, targetLength > 0, maximumLength >= targetLength else { return [] }
        let chars = Array(text)
        let sentences: [Range<Int>] = sentenceRanges(in: text).compactMap { sourceRange in
            guard let range = Range(sourceRange, in: text) else { return nil }
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: range.upperBound)
            return lower..<upper
        }
        // Use sentence ends rather than their starts so gaps returned by the
        // linguistic tokenizer (including punctuation) still belong to a unit.
        let ends = Array(Set(sentences.map(\.upperBound) + [chars.count])).sorted()
        var result: [Range<Int>] = []
        var start = 0
        var accumulatedEnd = 0
        for end in ends where end > accumulatedEnd {
            if accumulatedEnd > start, end - start > targetLength {
                appendBounded(start..<accumulatedEnd, chars: chars,
                              maximumLength: maximumLength, to: &result)
                start = accumulatedEnd
            }
            accumulatedEnd = end
            if end - start >= targetLength {
                appendBounded(start..<end, chars: chars,
                              maximumLength: maximumLength, to: &result)
                start = end
            }
        }
        if start < chars.count {
            appendBounded(start..<chars.count, chars: chars,
                          maximumLength: maximumLength, to: &result)
        }
        return result
    }

    static func hasSentenceEnd(_ text: String) -> Bool {
        let closers = CharacterSet(charactersIn: "\"'”’」』)]}）】》〉 ").union(.whitespacesAndNewlines)
        let trimmed = text.trimmingCharacters(in: closers)
        guard !endsInAbbreviation(trimmed), let last = trimmed.last else { return false }
        return Set<Character>(".!?。！？…।॥").contains(last)
    }

    private static func endsInAbbreviation(_ text: String) -> Bool {
        let token = text.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
        let titles: Set<String> = ["mr.", "mrs.", "ms.", "dr.", "prof.", "sr.", "jr.", "st.", "vs.", "e.g.", "i.e.", "fig.", "no."]
        if titles.contains(token.lowercased()) { return true }
        let characters = Array(token)
        return characters.count == 2 && characters[0].isLetter && characters[1] == "."
    }

    private static func appendBounded(
        _ range: Range<Int>, chars: [Character], maximumLength: Int,
        to result: inout [Range<Int>]
    ) {
        var start = range.lowerBound
        while start < range.upperBound {
            while start < range.upperBound, chars[start].isWhitespace { start += 1 }
            guard start < range.upperBound else { return }
            var end = range.upperBound
            if end - start > maximumLength {
                let limit = start + maximumLength
                // A complete sentence may exceed the target. Only the safety
                // bound permits a clause/word split, never an arbitrary letter.
                let clause = (start..<limit).last { index in
                    Set<Character>(",;:，；：、—").contains(chars[index]) &&
                        index + 1 - start >= maximumLength / 2
                }
                let space = (start..<limit).last { chars[$0].isWhitespace }
                if let clause { end = clause + 1 }
                else if let space, space > start { end = space }
                else {
                    // An unusually long indivisible token is kept intact. The
                    // TTS API's input limit is a separate admission constraint.
                    end = (limit..<range.upperBound).first { chars[$0].isWhitespace }
                        ?? range.upperBound
                }
            }
            var trimmedEnd = end
            while trimmedEnd > start, chars[trimmedEnd - 1].isWhitespace { trimmedEnd -= 1 }
            if trimmedEnd > start { result.append(start..<trimmedEnd) }
            start = end
        }
    }
}
