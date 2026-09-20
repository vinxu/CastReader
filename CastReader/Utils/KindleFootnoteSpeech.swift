import CoreGraphics
import CryptoKit
import Foundation

/// Speech-only projection. Source paragraphs, global word IDs and progress
/// anchors remain unchanged; array indexes below always refer to source words.
struct KindleSpeechParagraph {
    let sourceParagraph: ReadingParagraph
    let spokenParagraph: ReadingParagraph
    let spokenWordSourceIndices: [Int]
    let skippedSourceWordIndices: Set<Int>
    /// Swift Character offsets, matching OCRWordAligner and Kindle chunk ranges.
    /// These are not UTF-16 offsets or post-TTS-sanitization positions.
    let spokenCharacterSourceOffsets: [Int]

    var sourceParagraphID: Int { sourceParagraph.id }
    var spokenText: String { spokenParagraph.text }

    func sourceWordIndex(forSpokenWordIndex index: Int) -> Int? {
        spokenWordSourceIndices.indices.contains(index) ? spokenWordSourceIndices[index] : nil
    }

    func sourceCharacterRange(forSpokenRange range: Range<Int>) -> Range<Int>? {
        guard !range.isEmpty, range.lowerBound >= 0,
              range.upperBound <= spokenCharacterSourceOffsets.count else { return nil }
        return spokenCharacterSourceOffsets[range.lowerBound]..<(spokenCharacterSourceOffsets[range.upperBound - 1] + 1)
    }

    func mapTimestampWords(_ timestamps: [TTSTimestamp]) -> [Int?] {
        OCRWordAligner.mapTimestampWords(
            timestamps, in: spokenParagraph,
            allowFallback: false, allowBoundedFallback: true
        ).map { $0.flatMap(sourceWordIndex(forSpokenWordIndex:)) }
    }
}

struct KindleSpeechPage {
    let paragraphs: [KindleSpeechParagraph]
    /// Add to prepared audio identities, never to the image/source progress key.
    let cacheSignature: String
}

/// Same-page, term-linked notes and independently proven raised references.
/// Ambiguous definitions and incompletely bound OCR stay audible.
enum KindleFootnoteSpeech {
    static let policyVersion = "kindle-vision-footnotes-v3"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "kindle.skipFootnoteReferences.v1") as? Bool ?? true
    }

    static func explanationDocument(_ document: ReadingDocument, page: KindleSpeechPage) -> ReadingDocument {
        var result = document
        // Silent placeholders preserve original paragraph IDs for marks/progress.
        result.paragraphs = page.paragraphs.map(\.spokenParagraph)
        return result
    }

    static func prepare(document: ReadingDocument, skipReferences: Bool = true) -> KindleSpeechPage {
        let omitted = skipReferences ? pairedFootnotes(document) : [:]
        let paragraphs = document.paragraphs.enumerated().map { index, paragraph in
            project(paragraph, pixelSize: document.imagePixelSize, language: document.language,
                    skipReferences: skipReferences, omittedRanges: omitted[index] ?? [])
        }
        var digest = SHA256()
        func add(_ value: String) {
            let data = Data(value.utf8)
            digest.update(data: Data("\(data.count):".utf8))
            digest.update(data: data)
        }
        add(policyVersion)
        add(String(skipReferences))
        for paragraph in paragraphs {
            add(String(paragraph.sourceParagraphID))
            add(paragraph.sourceParagraph.text)
            add(paragraph.spokenText)
            add(paragraph.spokenWordSourceIndices.map(String.init).joined(separator: ","))
        }
        let hash = digest.finalize().map { String(format: "%02x", $0) }.joined()
        return KindleSpeechPage(paragraphs: paragraphs,
                                cacheSignature: "\(policyVersion):\(skipReferences):\(hash)")
    }

    private static func project(_ source: ReadingParagraph, pixelSize: CGSize?, language: String,
                                skipReferences: Bool, omittedRanges: [Range<Int>]) -> KindleSpeechParagraph {
        let chars = Array(source.text)
        func identity() -> KindleSpeechParagraph {
            KindleSpeechParagraph(sourceParagraph: source, spokenParagraph: source,
                                  spokenWordSourceIndices: Array(source.words.indices),
                                  skippedSourceWordIndices: [],
                                  spokenCharacterSourceOffsets: Array(chars.indices))
        }
        guard skipReferences, source.type.isReadable,
              ["en", "de", "es", "fr", "it", "pt"].contains(KindleLanguageContract.normalize(language) ?? ""),
              let pixelSize, pixelSize.width.isFinite, pixelSize.height.isFinite,
              pixelSize.width > 0, pixelSize.height > 0,
              let ranges = exactWordRanges(source) else { return identity() }

        var skipped = Set<Int>()
        let lineIDs = Set(source.words.compactMap(\.sourceLineID))
        for lineID in lineIDs {
            let indexes = source.words.indices.filter { source.words[$0].sourceLineID == lineID }
            let words = indexes.map { source.words[$0] }
            // Guessed or mixed-engine line geometry cannot prove typography.
            guard words.allSatisfy(isTrustedVisionWord) else { continue }
            for index in words.indices where isReference(words, index: index, pixelSize: pixelSize) {
                skipped.insert(indexes[index])
            }
        }
        guard !skipped.isEmpty || !omittedRanges.isEmpty else { return identity() }

        var keep = Array(repeating: true, count: chars.count)
        for index in skipped {
            for offset in ranges[index] { keep[offset] = false }
        }
        for range in omittedRanges {
            for offset in range where keep.indices.contains(offset) { keep[offset] = false }
        }
        var retainedWords: [OCRWord] = []
        var keptIndexes: [Int] = []
        for (index, word) in source.words.enumerated() {
            let text = String(ranges[index].filter { keep[$0] }.map { chars[$0] })
            if text.isEmpty { skipped.insert(index); continue }
            keptIndexes.append(index)
            retainedWords.append(OCRWord(id: word.id, text: text, bboxNorm: word.bboxNorm,
                bboxSource: word.bboxSource, sourceLineID: word.sourceLineID,
                recognitionConfidence: word.recognitionConfidence,
                inkBoundsNorm: word.inkBoundsNorm, inkBoundsChecked: word.inkBoundsChecked))
        }
        var spoken: [Character] = []
        var offsets: [Int] = []
        for (index, character) in chars.enumerated() where keep[index] {
            if character.isWhitespace && (spoken.isEmpty || spoken.last?.isWhitespace == true) { continue }
            spoken.append(character)
            offsets.append(index)
        }
        while spoken.last?.isWhitespace == true {
            spoken.removeLast()
            offsets.removeLast()
        }
        let speech = ReadingParagraph(
            id: source.id, text: String(spoken), speaker: source.speaker, type: source.type,
            words: retainedWords, bboxNorm: source.bboxNorm,
            pageIndex: source.pageIndex
        )
        return KindleSpeechParagraph(sourceParagraph: source, spokenParagraph: speech,
                                     spokenWordSourceIndices: keptIndexes,
                                     skippedSourceWordIndices: skipped,
                                     spokenCharacterSourceOffsets: offsets)
    }

    private struct Marker {
        let range: Range<Int>
        let id: String
    }
    private struct Definition {
        let paragraph: Int
        let marker: Marker
        let range: Range<Int>
        let body: String
        let ambiguousID: String?
    }
    private struct Reference {
        let paragraph: Int
        let marker: Marker
        let term: String
    }

    /// Regex offsets are converted at this boundary; all projection offsets are
    /// Swift Characters, including non-BMP letters and combining accents.
    private static func matches(_ pattern: String, _ text: String) -> [(Range<Int>, [String])] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let offsets = text.distance(from: text.startIndex, to: range.lowerBound)..<text.distance(from: text.startIndex, to: range.upperBound)
            return (offsets, (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            })
        }
    }

    private static func markers(_ text: String) -> [Marker] {
        matches(#"[\[{|［]\s*(\d{1,3}|\?)\s*[\]|)］}]|(?<![\p{L}\p{N}])(\d{1,3})\s*[\]|］]"#, text).map {
            Marker(range: $0.0, id: $0.1.first(where: { !$0.isEmpty }) ?? "")
        }
    }

    private static func pairedFootnotes(_ document: ReadingDocument) -> [Int: [Range<Int>]] {
        guard ["en", "de", "es", "fr", "it", "pt"].contains(KindleLanguageContract.normalize(document.language) ?? ""),
              let size = document.imagePixelSize, size.width > 0, size.height > 0 else { return [:] }
        var definitions: [Definition] = []
        for (index, paragraph) in document.paragraphs.enumerated() where paragraph.type.isReadable {
            guard let ranges = exactWordRanges(paragraph) else { continue }
            let chars = Array(paragraph.text)
            var starts: Set<Int> = [0]
            var seenLines = Set<Int>()
            for (wordIndex, word) in paragraph.words.enumerated() {
                if word.bboxSource == .visionTextRange,
                   let line = word.sourceLineID, seenLines.insert(line).inserted {
                    starts.insert(ranges[wordIndex].lowerBound)
                }
            }
            var candidates: [(Int, Marker, String?)] = []
            for start in starts.sorted() {
                let tail = String(chars.dropFirst(start))
                let normal = markers(tail).first.flatMap { marker -> Marker? in
                    guard marker.id != "?", tail.prefix(marker.range.lowerBound).allSatisfy(\.isWhitespace) else { return nil }
                    return marker
                }
                // Vision: "12 The declination ..." can be [2]; ML Kit: "[21".
                // A matching reference for the unrepaired ID always vetoes repair.
                let damaged = normal == nil ? matches(#"^\s*(?:[\[［]([1-9][0-9]{0,2})[1lI]|1([1-9][0-9]?))(?=\s+[\p{L}\p{M}])"#, tail).first : nil
                let marker = normal ?? damaged.map { Marker(range: $0.0, id: $0.1.first(where: { !$0.isEmpty }) ?? "") }
                guard let marker else { continue }
                let absoluteRange = (marker.range.lowerBound + start)..<(marker.range.upperBound + start)
                // Leading whitespace can expose the same marker at offset zero
                // and at the first OCR word. It is one definition, not two.
                guard !candidates.contains(where: { $0.1.range == absoluteRange }) else { continue }
                let ambiguous = damaged.map { $0.1[0].isEmpty ? "1" + marker.id : marker.id + "1" }
                candidates.append((start, Marker(range: absoluteRange, id: marker.id), ambiguous))
            }
            for (offset, candidate) in candidates.enumerated() {
                let end = offset + 1 < candidates.count ? candidates[offset + 1].0 : chars.count
                definitions.append(Definition(paragraph: index, marker: candidate.1,
                    range: candidate.0..<end, body: String(chars[candidate.1.range.upperBound..<end]), ambiguousID: candidate.2))
            }
        }
        let references: [Reference] = document.paragraphs.enumerated().flatMap { index, paragraph in
            guard paragraph.type.isReadable, exactWordRanges(paragraph) != nil else { return [Reference]() }
            return markers(paragraph.text).compactMap { marker in
                guard !definitions.contains(where: { $0.paragraph == index && $0.range.contains(marker.range.lowerBound) }),
                      let term = matches(#"([\p{L}\p{M}]{3,})\s*$"#, String(paragraph.text.prefix(marker.range.lowerBound))).first?.1.first else { return nil }
                return Reference(paragraph: index, marker: marker, term: term.lowercased())
            }
        }
        var omitted: [Int: [Range<Int>]] = [:]
        for reference in references {
            let matching = definitions.filter { note in
                guard reference.marker.id == "?" || reference.marker.id == note.marker.id else { return false }
                if let ambiguous = note.ambiguousID,
                   reference.marker.id == "?" || references.contains(where: { $0.term == reference.term && $0.marker.id == ambiguous }) { return false }
                // Never swallow narrative merged after a definition's final sentence.
                guard matches(#"[.!?][\"”’')]*\s+\S"#, note.body.trimmingCharacters(in: .whitespacesAndNewlines)).isEmpty else { return false }
                let words = matches(#"([\p{L}\p{M}]+)"#, note.body).map { $0.1[0].lowercased() }
                return words.count >= 4 && (words[0] == reference.term ||
                    (["the", "a", "an"].contains(words[0]) && words[1] == reference.term))
            }
            guard matching.count == 1, let note = matching.first else { continue }
            omitted[note.paragraph, default: []].append(note.range)
            omitted[reference.paragraph, default: []].append(reference.marker.range)
        }
        return omitted
    }

    /// Require exact, complete binding. Searching past unbound non-whitespace
    /// could delete the wrong repeated number after an OCR join/normalization.
    private static func exactWordRanges(_ paragraph: ReadingParagraph) -> [Range<Int>]? {
        let text = Array(paragraph.text)
        var cursor = 0
        var ranges: [Range<Int>] = []
        for word in paragraph.words {
            let token = Array(word.text)
            guard !token.isEmpty else { return nil }
            while cursor < text.count && text[cursor].isWhitespace { cursor += 1 }
            guard cursor + token.count <= text.count,
                  Array(text[cursor..<(cursor + token.count)]) == token else { return nil }
            ranges.append(cursor..<(cursor + token.count))
            cursor += token.count
        }
        guard text.dropFirst(cursor).allSatisfy(\.isWhitespace) else { return nil }
        return ranges
    }

    private static func isTrustedVisionWord(_ word: OCRWord) -> Bool {
        word.bboxSource == .visionTextRange && word.sourceLineID != nil &&
            word.recognitionConfidence.map { $0.isFinite && $0 >= 0.80 } == true &&
            OCRTokenGeometryCoverage.isUsable(word.bboxNorm) &&
            word.bboxNorm.minX >= 0 && word.bboxNorm.minY >= 0 &&
            word.bboxNorm.maxX <= 1 && word.bboxNorm.maxY <= 1
    }

    private static func isReference(_ words: [OCRWord], index: Int, pixelSize: CGSize) -> Bool {
        guard index > 0 else { return false }
        let candidate = words[index]
        guard candidate.text.range(of: "^[1-9][0-9]{0,2}$", options: .regularExpression) != nil else { return false }
        let anchor = words[index - 1]
        guard anchor.text.range(of: "[.!?][\"'’”»)]*$", options: .regularExpression) != nil,
              anchor.text.prefix(while: \.isLetter).count >= 3,
              !anchor.text.contains(where: \.isNumber) else { return false }
        let preceding = words.prefix(index).map(\.text).joined(separator: " ")
        guard preceding.range(of: "[=+×÷^√∑∫<>≤≥²³⁰¹⁴⁵⁶⁷⁸⁹₀-₉]", options: .regularExpression) == nil,
              preceding.range(of: unsafeContext, options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        func isBodyWord(_ word: OCRWord) -> Bool {
            let value = word.text.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
            return !value.isEmpty && value.allSatisfy(\.isLetter)
        }
        guard words.prefix(index).filter(isBodyWord).count >= 3 else { return false }
        // Typography belongs to the whole recognized line. Real Vision ranges
        // can cut an earlier glyph; use only independently complete ink boxes,
        // including following prose, without relaxing the sentence-end context.
        let body = words.filter {
            isBodyWord($0)
        }.compactMap { rect($0, pixelSize: pixelSize) }
        guard body.count >= 3 else { return false }
        let height = median(body.map(\.height))
        let baseline = median(body.map(\.maxY))
        let top = median(body.map(\.minY))
        guard height > 0, body.filter({ abs($0.maxY - baseline) <= height * 0.15 }).count >= 3 else { return false }
        guard let a = rect(anchor, pixelSize: pixelSize),
              let marker = rect(candidate, pixelSize: pixelSize),
              (height * 0.80...height * 1.25).contains(a.height),
              abs(a.maxY - baseline) <= height * 0.15,
              (height * 0.35...height * 0.78).contains(marker.height),
              marker.maxY <= baseline - height * 0.20,
              marker.maxY >= top + height * 0.20,
              marker.minY <= top + height * 0.15,
              marker.minY >= top - height * 0.65,
              (0...height * 0.85).contains(marker.minX - a.maxX) else { return false }
        if index + 1 < words.count {
            let nextLeft = words[index + 1].bboxNorm.minX * pixelSize.width
            if nextLeft < marker.maxX { return false }
        }
        return true
    }

    private static func rect(_ word: OCRWord, pixelSize: CGSize) -> CGRect? {
        let box: CGRect
        if word.inkBoundsChecked {
            guard let ink = word.inkBoundsNorm, OCRTokenGeometryCoverage.isUsable(ink),
                  ink.minX >= 0, ink.minY >= 0, ink.maxX <= 1, ink.maxY <= 1 else { return nil }
            box = ink
        } else {
            box = word.bboxNorm
        }
        return CGRect(x: box.minX * pixelSize.width,
                      y: (1 - box.maxY) * pixelSize.height,
                      width: box.width * pixelSize.width,
                      height: box.height * pixelSize.height)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat { values.sorted()[values.count / 2] }

    private static let unsafeContext =
        "\\b(chapter|chap|section|sec|part|book|volume|vol|figure|fig|table|equation|eq|page|pp|" +
        "appendix|item|number|no|verse|theorem|lemma|corollary|formula|squared|cubed|power|exponent|" +
        "sin|cos|tan|log|exp|polynomial|derivative|integral|meters|metres|inches|" +
        "kapitel|abschnitt|chapitre|capitolo|capítulo|sección|sezione|seção|" +
        "january|february|march|april|may|june|july|august|september|october|november|december)\\b"
}
