import Foundation

/// Exact source provenance for a speech unit that can span two visual pages.
/// TTS still aligns against its processed text; this map only selects the
/// original OCR geometry and persistent reading position for the aligned word.
enum KindleSpeechProjection {
    struct Start {
        let paragraphID: Int
        let wordIndex: Int
    }

    /// Resolve a confirmed source-word cursor through the footnote projection.
    /// Never renumber/cut OCR words: later highlights still use the full page.
    static func sentenceParagraphs(_ page: KindleSpeechPage, startingAt start: Start? = nil) throws -> [KindleSentenceBuffer.Paragraph] {
        var result: [KindleSentenceBuffer.Paragraph] = []
        if let start {
            guard let source = page.paragraphs.first(where: { $0.sourceParagraphID == start.paragraphID }),
                  source.sourceParagraph.words.indices.contains(start.wordIndex) else { throw Failure.invalidRange }
        }
        for projection in page.paragraphs where projection.spokenParagraph.type.isReadable &&
            SpeechTextSanitizer.containsSpeakableContent(projection.spokenText) && !projection.spokenParagraph.words.isEmpty {
            let paragraph = projection.spokenParagraph
            if let start, paragraph.id < start.paragraphID { continue }
            var offset = 0
            if let start, paragraph.id == start.paragraphID {
                guard let wordIndex = projection.spokenWordSourceIndices.firstIndex(where: { $0 >= start.wordIndex }) else { continue }
                let text = paragraph.text as NSString
                for (index, word) in paragraph.words.enumerated() {
                    let range = text.range(of: word.text, options: [.caseInsensitive, .diacriticInsensitive],
                                           range: NSRange(location: offset, length: text.length - offset))
                    guard range.location != NSNotFound else { throw Failure.unmappedText }
                    if index == wordIndex { offset = range.location; break }
                    offset = NSMaxRange(range)
                }
            }
            let heading: Bool
            if case .heading = paragraph.type { heading = true } else { heading = false }
            result.append(.init(id: paragraph.id, text: paragraph.text, isHeading: heading, startUTF16: offset))
        }
        return result
    }

    struct Page {
        let key: String
        let paragraphs: [ReadingParagraph]
        var speechProjections: [Int: KindleSpeechParagraph] = [:]
    }
    struct Anchor: Equatable {
        let pageKey: String
        let paragraphID: Int
        let wordIndex: Int
        let characterRange: NSRange
    }
    struct Projected {
        let paragraph: ReadingParagraph
        let anchors: [Anchor]
    }
    enum Failure: Error { case missingSource, invalidRange, unmappedText }

    static func project(
        _ unit: KindleSentenceBuffer.Unit, paragraphID: Int, pages: [String: Page]
    ) throws -> Projected {
        var words: [OCRWord] = []
        var anchors: [Anchor] = []
        var type: ReadingParagraphType = .paragraph
        for (sourceIndex, source) in unit.sources.enumerated() {
            guard let page = pages[source.pageKey],
                  let paragraph = page.paragraphs.first(where: { $0.id == source.paragraphID }) else {
                throw Failure.missingSource
            }
            let text = paragraph.text as NSString
            guard source.sourceRange.location >= 0, source.sourceRange.length > 0,
                  NSMaxRange(source.sourceRange) <= text.length,
                  source.speechRange.location >= 0,
                  NSMaxRange(source.speechRange) <= unit.text.utf16.count,
                  source.speechRange.length == source.sourceRange.length,
                  (unit.text as NSString).substring(with: source.speechRange) == text.substring(with: source.sourceRange) else {
                throw Failure.invalidRange
            }
            if sourceIndex == 0 { type = paragraph.type }
            var cursor = 0
            let before = words.count
            for (wordIndex, word) in paragraph.words.enumerated() {
                let range = text.range(of: word.text, options: [.caseInsensitive, .diacriticInsensitive],
                                       range: NSRange(location: cursor, length: text.length - cursor))
                guard range.location != NSNotFound else { continue }
                cursor = NSMaxRange(range)
                let overlap = NSIntersectionRange(range, source.sourceRange)
                guard overlap.length > 0 else { continue }
                let visibleText = text.substring(with: overlap)
                guard !visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                words.append(OCRWord(id: words.count, text: visibleText,
                                     bboxNorm: word.bboxNorm, bboxSource: word.bboxSource,
                                     sourceLineID: word.sourceLineID,
                                     recognitionConfidence: word.recognitionConfidence,
                                     inkBoundsNorm: word.inkBoundsNorm, inkBoundsChecked: word.inkBoundsChecked))
                let projection = page.speechProjections[paragraph.id]
                let characterRange: NSRange
                if let projection {
                    guard let spokenRange = Range(overlap, in: paragraph.text) else { throw Failure.invalidRange }
                    let characterLower = paragraph.text.distance(from: paragraph.text.startIndex, to: spokenRange.lowerBound)
                    let characterUpper = paragraph.text.distance(from: paragraph.text.startIndex, to: spokenRange.upperBound)
                    guard let origin = projection.sourceCharacterRange(forSpokenRange: characterLower..<characterUpper) else {
                        throw Failure.invalidRange
                    }
                    let original = projection.sourceParagraph.text
                    guard let lower = original.index(original.startIndex, offsetBy: origin.lowerBound, limitedBy: original.endIndex),
                          let upper = original.index(original.startIndex, offsetBy: origin.upperBound, limitedBy: original.endIndex) else {
                        throw Failure.invalidRange
                    }
                    characterRange = NSRange(lower..<upper, in: original)
                } else {
                    characterRange = overlap
                }
                anchors.append(Anchor(pageKey: page.key, paragraphID: paragraph.id,
                                      wordIndex: projection?.sourceWordIndex(forSpokenWordIndex: wordIndex) ?? wordIndex,
                                      characterRange: characterRange))
            }
            guard words.count > before else { throw Failure.unmappedText }
        }
        return Projected(paragraph: ReadingParagraph(id: paragraphID, text: unit.text,
                                                      type: type, words: words), anchors: anchors)
    }
}
