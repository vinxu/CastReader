import Foundation

/// A bounded text window for a single Kindle reading/navigation generation.
/// It consumes confirmed adjacent pages; speculative blob order is not input.
/// Audio generation and UI presentation consume its units independently.
struct KindleSentenceBuffer {
    struct Scope: Equatable {
        let bookID: String
        let layoutRevision: UInt64
        let navigationGeneration: UInt64
    }
    struct Paragraph {
        let id: Int
        let text: String
        var isHeading = false
    }
    struct Page {
        let key: String
        let scope: Scope
        let paragraphs: [Paragraph]
    }
    struct ConfirmedEdge {
        let previousPageKey: String
        let nextPageKey: String
        let scope: Scope
    }
    struct SourceSpan: Equatable {
        let pageKey: String
        let paragraphID: Int
        let sourceRange: NSRange
        let speechRange: NSRange
    }
    struct Unit: Equatable {
        let text: String
        let sources: [SourceSpan]
    }
    enum Failure: Error, Equatable {
        case staleScope, unconfirmedAdjacency, alreadyFinished
    }

    let scope: Scope
    private(set) var currentPageKey: String?
    private(set) var pending: Unit?
    private(set) var isFinished = false
    private var seenPageKeys = Set<String>()

    init(scope: Scope) { self.scope = scope }

    /// Duplicate observations are no-ops. Reordered/unconfirmed pages cannot
    /// consume the tail or change the cursor. A manual jump creates a new scope.
    mutating func accept(_ page: Page, after edge: ConfirmedEdge? = nil) throws -> [Unit] {
        guard !isFinished else { throw Failure.alreadyFinished }
        guard page.scope == scope else { throw Failure.staleScope }
        if seenPageKeys.contains(page.key) { return [] }
        guard !page.key.isEmpty else { throw Failure.unconfirmedAdjacency }
        if let currentPageKey {
            guard let edge, edge.scope == scope,
                  edge.previousPageKey == currentPageKey,
                  edge.nextPageKey == page.key,
                  edge.nextPageKey != edge.previousPageKey else { throw Failure.unconfirmedAdjacency }
        } else if edge != nil { throw Failure.unconfirmedAdjacency }

        let paragraphs = page.paragraphs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var result: [Unit] = []
        for (paragraphOffset, paragraph) in paragraphs.enumerated() {
            let ranges = KindleSpeechTextPlan.sentenceRanges(in: paragraph.text)
            if paragraph.isHeading, let tail = pending {
                result.append(tail)
                pending = nil
            }
            for (sentenceOffset, range) in ranges.enumerated() {
                let text = (paragraph.text as NSString).substring(with: range)
                let source = SourceSpan(pageKey: page.key, paragraphID: paragraph.id,
                                        sourceRange: range,
                                        speechRange: NSRange(location: 0, length: range.length))
                var unit = Unit(text: text, sources: [source])
                if paragraphOffset == 0, sentenceOffset == 0, !paragraph.isHeading,
                   let tail = pending {
                    unit = Self.join(tail, unit)
                    pending = nil
                }
                let isPageTail = paragraphOffset == paragraphs.count - 1 && sentenceOffset == ranges.count - 1
                if isPageTail, !paragraph.isHeading, !KindleSpeechTextPlan.hasSentenceEnd(unit.text), unit.text.count < 2_000 {
                    pending = unit
                } else {
                    result.append(unit)
                }
            }
        }
        currentPageKey = page.key
        seenPageKeys.insert(page.key)
        return result
    }

    /// Only a confirmed end of content flushes the final unfinished sentence.
    /// Cancellation discards it with this session; it must not start old audio.
    mutating func finish() -> [Unit] {
        guard !isFinished else { return [] }
        isFinished = true
        defer { pending = nil }
        return pending.map { [$0] } ?? []
    }

    mutating func cancel() {
        isFinished = true
        pending = nil
    }

    /// Small adjacent complete sentences share a TTS request; paragraph breaks
    /// remain double newlines and headings stay separate.
    /// The pending page tail is deliberately excluded until it is complete.
    /// Splitting an unusually long sentence retains exact UTF-16 provenance.
    static func playbackUnits(from sentences: [Unit], isHeading: (SourceSpan) -> Bool = { _ in false }) -> [Unit] {
        var result: [Unit] = []
        for sentence in sentences {
            for bounds in KindleSpeechTextPlan.chunkRanges(in: sentence.text) {
                let lower = sentence.text.index(sentence.text.startIndex, offsetBy: bounds.lowerBound)
                let upper = sentence.text.index(sentence.text.startIndex, offsetBy: bounds.upperBound)
                let range = NSRange(lower..<upper, in: sentence.text)
                let sources = sentence.sources.compactMap { source -> SourceSpan? in
                    let overlap = NSIntersectionRange(source.speechRange, range)
                    guard overlap.length > 0 else { return nil }
                    return SourceSpan(pageKey: source.pageKey, paragraphID: source.paragraphID,
                        sourceRange: NSRange(location: source.sourceRange.location + overlap.location - source.speechRange.location,
                                             length: overlap.length),
                        speechRange: NSRange(location: overlap.location - range.location, length: overlap.length))
                }
                let unit = Unit(text: String(sentence.text[lower..<upper]), sources: sources)
                if let previous = result.last, let lastSource = previous.sources.last, let firstSource = sources.first,
                   !previous.sources.contains(where: isHeading), !sources.contains(where: isHeading),
                   hasCompleteBoundary(previous.text), previous.text.count + 2 + unit.text.count <= 480 {
                    let sameParagraph = lastSource.pageKey == firstSource.pageKey && lastSource.paragraphID == firstSource.paragraphID
                    result[result.count - 1] = join(previous, unit, separator: sameParagraph ? " " : "\n\n")
                } else {
                    result.append(unit)
                }
            }
        }
        return result
    }

    private static func hasCompleteBoundary(_ text: String) -> Bool {
        KindleSpeechTextPlan.hasSentenceEnd(text)
    }

    private static func join(_ lhs: Unit, _ rhs: Unit, separator: String = " ") -> Unit {
        // Ordinary hyphens and em dashes are source content. Do not guess that
        // they are discretionary line-break hyphens and silently delete them.
        let offset = lhs.text.utf16.count + separator.utf16.count
        return Unit(text: lhs.text + separator + rhs.text,
                    sources: lhs.sources + rhs.sources.map {
            SourceSpan(pageKey: $0.pageKey, paragraphID: $0.paragraphID,
                       sourceRange: $0.sourceRange,
                       speechRange: NSRange(location: $0.speechRange.location + offset,
                                            length: $0.speechRange.length))
        })
    }

}
