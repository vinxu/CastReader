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

/// Deliberately narrow: independently recognized, raised reference digits at
/// a prose sentence end. This is neither a general superscript remover nor a
/// footnote-body filter. Ambiguous or incompletely bound paragraphs stay intact.
enum KindleFootnoteSpeech {
    static let policyVersion = "kindle-vision-reference-v2"

    static func prepare(document: ReadingDocument, skipReferences: Bool = true) -> KindleSpeechPage {
        let paragraphs = document.paragraphs.map {
            project($0, pixelSize: document.imagePixelSize, language: document.language,
                    skipReferences: skipReferences)
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
                                skipReferences: Bool) -> KindleSpeechParagraph {
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
        guard !skipped.isEmpty else { return identity() }

        var keep = Array(repeating: true, count: chars.count)
        for index in skipped {
            for offset in ranges[index] { keep[offset] = false }
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
        let keptIndexes = source.words.indices.filter { !skipped.contains($0) }
        let speech = ReadingParagraph(
            id: source.id, text: String(spoken), speaker: source.speaker, type: source.type,
            words: keptIndexes.map { source.words[$0] }, bboxNorm: source.bboxNorm,
            pageIndex: source.pageIndex
        )
        return KindleSpeechParagraph(sourceParagraph: source, spokenParagraph: speech,
                                     spokenWordSourceIndices: keptIndexes,
                                     skippedSourceWordIndices: skipped,
                                     spokenCharacterSourceOffsets: offsets)
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
