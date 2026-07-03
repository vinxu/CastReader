//
//  OCRWordAligner.swift
//  CastReader
//
//  Align TTS timestamp words back to OCR word boxes.
//  This mirrors the extension's Kindle bbox path: TTS reads OCR text, then each
//  timestamp word is resolved to a character position and finally to an OCR bbox.
//

import Foundation

enum OCRWordAligner {
    struct Match: Equatable {
        let pos: Int
        let matchLen: Int
    }

    static func mapTimestampWords(
        in paragraph: ReadingParagraph,
        segments: [AudioSegment],
        allowFallback: Bool = true
    ) -> [Int?] {
        let timestamps = segments.flatMap(\.timestamps)
        return mapTimestampWords(timestamps, in: paragraph, allowFallback: allowFallback)
    }

    static func mapTimestampWords(
        _ timestamps: [TTSTimestamp],
        in paragraph: ReadingParagraph,
        allowFallback: Bool = true
    ) -> [Int?] {
        guard !timestamps.isEmpty, !paragraph.words.isEmpty else { return [] }
        let textChars = Array(paragraph.text)
        let wordRanges = buildOCRWordRanges(paragraph: paragraph, textChars: textChars)
        let comparableWords = paragraph.words.map { comparable($0.text) }
        var searchPos = 0
        var ocrCursor = 0
        var output: [Int?] = []
        output.reserveCapacity(timestamps.count)

        for ts in timestamps {
            let word = ts.word
            if let match = findWordPositionNormalized(textChars: textChars, word: word, startPos: searchPos, distanceGuard: true) {
                let idx = nearestOCRWordIndex(forCharPos: match.pos, ranges: wordRanges, tolerance: 3, minIndex: ocrCursor)
                    ?? (allowFallback ? fallbackWordIndex(word, comparableWords: comparableWords, from: ocrCursor, window: 14) : nil)
                output.append(idx)
                searchPos = match.pos + match.matchLen
                if let idx { ocrCursor = max(ocrCursor, idx + 1) }
            } else if allowFallback, let idx = fallbackWordIndex(word, comparableWords: comparableWords, from: ocrCursor, window: 14) {
                output.append(idx)
                ocrCursor = idx + 1
            } else {
                output.append(nil)
            }
        }

        return output
    }

    static func wordIndexes(overlapping range: Range<Int>, in paragraph: ReadingParagraph) -> [Int] {
        guard !paragraph.words.isEmpty, !paragraph.text.isEmpty else { return [] }
        let textChars = Array(paragraph.text)
        let wordRanges = buildOCRWordRanges(paragraph: paragraph, textChars: textChars)
        guard !wordRanges.isEmpty else { return [] }
        return wordRanges
            .filter { max($0.start, range.lowerBound) < min($0.end, range.upperBound) }
            .map(\.idx)
    }

    private static func buildOCRWordRanges(paragraph: ReadingParagraph, textChars: [Character]) -> [(idx: Int, start: Int, end: Int)] {
        var cursor = 0
        var ranges: [(idx: Int, start: Int, end: Int)] = []
        for (idx, word) in paragraph.words.enumerated() {
            guard !word.text.isEmpty else { continue }
            if let match = findWordPositionNormalized(textChars: textChars, word: word.text, startPos: cursor, distanceGuard: false) {
                ranges.append((idx, match.pos, match.pos + match.matchLen))
                cursor = match.pos + match.matchLen
            }
        }
        return ranges
    }

    private static func nearestOCRWordIndex(
        forCharPos pos: Int,
        ranges: [(idx: Int, start: Int, end: Int)],
        tolerance: Int,
        minIndex: Int
    ) -> Int? {
        // Prefer the character-owning OCR token even when the TTS token is a
        // split inside the previous OCR word, e.g. OCR "buttheright" while TTS
        // says "but the right". The cursor still keeps repeated words ordered.
        if let exact = ranges.first(where: { pos >= $0.start && pos < $0.end }) {
            return exact.idx
        }
        var best: (idx: Int, dist: Int)?
        for r in ranges where r.idx >= minIndex {
            let dist: Int
            if pos >= r.start && pos < r.end {
                dist = 0
            } else {
                dist = min(abs(pos - r.start), abs(pos - r.end))
            }
            if best == nil || dist < best!.dist {
                best = (r.idx, dist)
            }
        }
        guard let best, best.dist <= tolerance else { return nil }
        return best.idx
    }

    private static func fallbackWordIndex(_ word: String, comparableWords: [String], from cursor: Int, window: Int) -> Int? {
        let target = comparable(word)
        guard !target.isEmpty else { return nil }
        let start = min(max(0, cursor), comparableWords.count)
        let end = min(comparableWords.count, start + window)
        guard start < end else { return nil }
        for i in start..<end where comparableWords[i] == target {
            return i
        }
        for i in start..<end where fuzzyWordMatch(target: target, candidate: comparableWords[i]) {
            return i
        }
        return nil
    }

    private static func fuzzyWordMatch(target: String, candidate: String) -> Bool {
        guard !target.isEmpty, !candidate.isEmpty else { return false }
        if target == candidate { return true }

        let t = foldOcrConfusables(target)
        let c = foldOcrConfusables(candidate)
        if t == c { return true }

        let minLen = min(t.count, c.count)
        let maxLen = max(t.count, c.count)
        if minLen >= 4 {
            let ratio = Double(minLen) / Double(maxLen)
            if ratio >= 0.58, (t.contains(c) || c.contains(t)) {
                return true
            }
        } else if minLen >= 2, c.count >= 4, c.hasPrefix(t) {
            // OCR occasionally glues "If followed" into "iffollowed"; allow
            // only prefix matches for very short words to keep the cursor stable.
            return true
        }

        if minLen >= 4 {
            let limit = maxLen >= 8 ? 2 : 1
            return levenshteinLimited(t, c, limit: limit) <= limit
        }
        return false
    }

    private static func foldOcrConfusables(_ raw: String) -> String {
        raw.map { ch -> Character in
            switch ch {
            case "0": return "o"
            case "1": return "l"
            default: return ch
            }
        }
        .map(String.init)
        .joined()
    }

    private static func levenshteinLimited(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs)
        let b = Array(rhs)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMin = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
                rowMin = min(rowMin, current[j])
            }
            if rowMin > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func findWordPositionNormalized(
        textChars: [Character],
        word: String,
        startPos: Int,
        distanceGuard: Bool
    ) -> Match? {
        let wordChars = Array(word)
        guard !wordChars.isEmpty, startPos <= textChars.count else { return nil }
        let maxDistance = wordChars.count <= 2 ? 30 : (wordChars.count <= 4 ? 50 : 150)
        func guardDistance(_ m: Match?) -> Match? {
            guard distanceGuard, let m else { return m }
            return m.pos - startPos > maxDistance ? nil : m
        }

        if let m = guardDistance(find(wordChars, in: textChars, from: startPos, caseInsensitive: false)) { return m }
        if let m = guardDistance(find(wordChars, in: textChars, from: startPos, caseInsensitive: true)) { return m }

        let stripped = stripEdgePunctuation(wordChars)
        if !stripped.isEmpty, stripped != wordChars {
            if let m = guardDistance(find(stripped, in: textChars, from: startPos, caseInsensitive: false)) { return m }
            if let m = guardDistance(find(stripped, in: textChars, from: startPos, caseInsensitive: true)) { return m }
        }

        let quoteText = textChars.map(normalizeQuote)
        let quoteWord = wordChars.map(normalizeQuote)
        if quoteText != textChars || quoteWord != wordChars {
            if let m = guardDistance(find(quoteWord, in: quoteText, from: startPos, caseInsensitive: false)) { return m }
            if let m = guardDistance(find(quoteWord, in: quoteText, from: startPos, caseInsensitive: true)) { return m }
            let quoteStripped = stripEdgePunctuation(quoteWord)
            if !quoteStripped.isEmpty, quoteStripped != quoteWord {
                if let m = guardDistance(find(quoteStripped, in: quoteText, from: startPos, caseInsensitive: true)) { return m }
            }
        }

        if let m = findWithRemovedCharacters(textChars: textChars, wordChars: wordChars, startPos: startPos, shouldRemove: isApostrophe) {
            if let guarded = guardDistance(m) { return guarded }
        }

        let sepText = textChars.map(normalizeSeparator)
        let sepWord = wordChars.map(normalizeSeparator)
        if sepText != textChars || sepWord != wordChars {
            if let m = guardDistance(find(sepWord, in: sepText, from: startPos, caseInsensitive: true)) { return m }
            let trimmed = trimTrailingSeparators(sepWord)
            if !trimmed.isEmpty, trimmed != sepWord,
               let m = guardDistance(find(trimmed, in: sepText, from: startPos, caseInsensitive: true)) {
                return m
            }
        }

        let lowerWord = String(wordChars).lowercased()
        let symbolMap: [String: Character] = ["and": "&", "percent": "%", "plus": "+", "equals": "=", "at": "@"]
        if let symbol = symbolMap[lowerWord],
           let m = guardDistance(find([symbol], in: textChars, from: startPos, caseInsensitive: false)) {
            return m
        }

        if let m = findWithRemovedCharacters(textChars: textChars, wordChars: wordChars, startPos: startPos, shouldRemove: isHyphen) {
            if let guarded = guardDistance(m) { return guarded }
        }

        return nil
    }

    private static func findWithRemovedCharacters(
        textChars: [Character],
        wordChars: [Character],
        startPos: Int,
        shouldRemove: (Character) -> Bool
    ) -> Match? {
        let strippedWord = wordChars.filter { !shouldRemove($0) }
        guard !strippedWord.isEmpty, strippedWord != wordChars else { return nil }

        var strippedText: [Character] = []
        var originalMap: [Int] = []
        strippedText.reserveCapacity(textChars.count)
        for (idx, ch) in textChars.enumerated() where !shouldRemove(ch) {
            strippedText.append(ch)
            originalMap.append(idx)
        }
        let strippedStart = textChars.prefix(min(startPos, textChars.count)).filter { !shouldRemove($0) }.count
        guard let match = find(strippedWord, in: strippedText, from: strippedStart, caseInsensitive: true),
              match.pos < originalMap.count else { return nil }
        let originalStart = originalMap[match.pos]
        let endMappedIndex = min(originalMap.count - 1, match.pos + max(0, match.matchLen - 1))
        let originalEnd = originalMap[endMappedIndex] + 1
        return Match(pos: originalStart, matchLen: max(1, originalEnd - originalStart))
    }

    private static func find(
        _ needle: [Character],
        in haystack: [Character],
        from rawStart: Int,
        caseInsensitive: Bool
    ) -> Match? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let start = max(0, rawStart)
        let last = haystack.count - needle.count
        guard start <= last else { return nil }
        var i = start
        while i <= last {
            var j = 0
            while j < needle.count, charsEqual(haystack[i + j], needle[j], caseInsensitive: caseInsensitive) {
                j += 1
            }
            if j == needle.count {
                return Match(pos: i, matchLen: needle.count)
            }
            i += 1
        }
        return nil
    }

    private static func charsEqual(_ a: Character, _ b: Character, caseInsensitive: Bool) -> Bool {
        if a == b { return true }
        guard caseInsensitive else { return false }
        return String(a).lowercased() == String(b).lowercased()
    }

    private static func stripEdgePunctuation(_ chars: [Character]) -> [Character] {
        var start = 0
        var end = chars.count
        while start < end, !isWordChar(chars[start]) { start += 1 }
        while end > start, !isWordChar(chars[end - 1]) { end -= 1 }
        return Array(chars[start..<end])
    }

    private static func isWordChar(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }

    private static func normalizeQuote(_ ch: Character) -> Character {
        switch ch {
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{201F}", "\u{00AB}", "\u{00BB}": return "\""
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{201B}", "`": return "'"
        case "\u{2013}", "\u{2014}": return "-"
        default: return ch
        }
    }

    private static func normalizeSeparator(_ ch: Character) -> Character {
        switch ch {
        case ".", "-", "\u{2010}", "\u{2011}": return "\u{0}"
        default: return ch
        }
    }

    private static func trimTrailingSeparators(_ chars: [Character]) -> [Character] {
        var out = chars
        while out.last == "\u{0}" { out.removeLast() }
        return out
    }

    private static func isApostrophe(_ ch: Character) -> Bool {
        ch == "'" || ch == "\u{2018}" || ch == "\u{2019}" || ch == "\u{201A}" || ch == "\u{201B}" || ch == "`"
    }

    private static func isHyphen(_ ch: Character) -> Bool {
        ch == "-" || ch == "\u{2010}" || ch == "\u{2011}"
    }

    private static func comparable(_ raw: String) -> String {
        raw.map(normalizeQuote)
            .filter { isWordChar($0) }
            .map { String($0).lowercased() }
            .joined()
    }
}
