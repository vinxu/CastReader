import CryptoKit
import Foundation

/// Durable position only: no source text, cookies, audio, or third-party body
/// enters History. Source coordinates and TTS output coordinates stay separate.
struct ReadingResumeCheckpoint: Codable, Equatable {
    var schemaVersion = 1
    let sourceKind: ReadingSourceKind
    let paragraphIndex: Int
    let paragraphFingerprint: String
    let previousFingerprint: String?
    let nextFingerprint: String?
    let structureFingerprint: String
    let audio: ReadingResumeAudioCursor?
    var visual: ReadingResumeVisualCursor? = nil
    var reflow: ReadingResumeReflowCursor? = nil
    let updatedAt: Date
    var activity: ReadingProgressActivity? = nil

    var isValid: Bool {
        schemaVersion == 1 && paragraphIndex >= 0
            && paragraphFingerprint.count == 64 && structureFingerprint.count == 64
            && (audio?.isValid ?? true)
    }
}

/// Short, hashed word context survives a provider changing its page/paragraph
/// boundaries. It stores no book text and never authorizes a nearest-word guess.
struct ReadingResumeReflowCursor: Codable, Equatable {
    let beforeHash: String
    let beforeCount: Int
    let wordHash: String
    let wordCount: Int
    let afterHash: String
    let afterCount: Int
    // Optional shorter hashes support compact pages containing only part of
    // either 48-character side. At least 32 verified context characters are
    // still required; older checkpoints retain their original strict rules.
    var beforeFragments: [Int: String]? = nil
    var afterFragments: [Int: String]? = nil
    var usesSentenceTiming: Bool? = nil

    var isValid: Bool {
        (0...48).contains(beforeCount) && (0...48).contains(afterCount)
            && (1...128).contains(wordCount)
            && beforeCount + afterCount + (usesSentenceTiming == true ? wordCount : 0) >= 32
            && [beforeHash, wordHash, afterHash].allSatisfy { $0.count == 64 }
    }
}

/// Source coordinates are used only to reveal a saved position before audio is
/// ready. Live highlighting continues to use the processed TTS output.
struct ReadingResumeVisualCursor: Codable, Equatable {
    let sourceFingerprint: String
    let utf16Offset: Int
    let utf16Length: Int

    func range(in source: String) -> NSRange? {
        guard utf16Offset >= 0, utf16Length > 0,
              utf16Offset <= source.utf16.count,
              utf16Length <= source.utf16.count - utf16Offset,
              sourceFingerprint == ReadingResumeContract.fingerprint(source) else { return nil }
        return NSRange(location: utf16Offset, length: utf16Length)
    }
}

/// Hashed spoken-text range for languages intentionally using segment timing.
/// A changed audio partition can replay the verified range's first chunk, but
/// cannot infer a word time from the old voice's elapsed seconds.
struct ReadingResumeUntimedAnchor: Codable, Equatable {
    let prefixUTF16Length: Int
    let prefixFingerprint: String
    let textUTF16Length: Int
    let textFingerprint: String
}

struct ReadingResumeAudioCursor: Codable, Equatable {
    let outputUTF16Offset: Int
    let outputPrefixFingerprint: String
    let wordFingerprint: String?
    let wordFraction: Double
    let segmentIndex: Int
    let segmentTextFingerprint: String
    let audioFingerprint: String
    let segmentTime: Double
    var segmentDuration: Double? = nil
    var outputUTF16Length: Int? = nil
    var semanticOffset: Int? = nil
    var semanticPrefixFingerprint: String? = nil
    var semanticWordFingerprint: String? = nil
    var semanticWordUTF16Length: Int? = nil
    var untimedAnchor: ReadingResumeUntimedAnchor? = nil

    var isValid: Bool {
        outputUTF16Offset >= 0 && segmentIndex >= 0
            && segmentTime.isFinite && segmentTime >= 0
            && wordFraction.isFinite && (0...1).contains(wordFraction)
            && outputPrefixFingerprint.count == 64
            && segmentTextFingerprint.count == 64 && audioFingerprint.count == 64
    }
}

struct ReadingResumeDocumentIndex: Codable, Equatable {
    let fingerprints: [String]
    let readable: Set<Int>
    let fingerprint: String

    init(paragraphs: [ReadingParagraph]) {
        fingerprints = paragraphs.map { ReadingResumeContract.fingerprint($0.resolvedSpeechText) }
        readable = Set(paragraphs.indices.filter {
            paragraphs[$0].type.isReadable
                && SpeechTextSanitizer.containsSpeakableContent(paragraphs[$0].resolvedSpeechText)
        })
        fingerprint = ReadingResumeContract.fingerprint(fingerprints.joined(separator: ":"))
    }

    func checkpoint(
        sourceKind: ReadingSourceKind, paragraphIndex: Int,
        audio: ReadingResumeAudioCursor?, now: Date = Date()
    ) -> ReadingResumeCheckpoint? {
        guard readable.contains(paragraphIndex) else { return nil }
        return ReadingResumeCheckpoint(
            sourceKind: sourceKind, paragraphIndex: paragraphIndex,
            paragraphFingerprint: fingerprints[paragraphIndex],
            previousFingerprint: paragraphIndex > 0 ? fingerprints[paragraphIndex - 1] : nil,
            nextFingerprint: paragraphIndex + 1 < fingerprints.count ? fingerprints[paragraphIndex + 1] : nil,
            structureFingerprint: fingerprint, audio: audio, updatedAt: now
        )
    }

    func resolve(_ checkpoint: ReadingResumeCheckpoint) -> Int? {
        guard checkpoint.isValid else { return nil }
        if checkpoint.structureFingerprint == fingerprint,
           readable.contains(checkpoint.paragraphIndex),
           fingerprints[checkpoint.paragraphIndex] == checkpoint.paragraphFingerprint {
            return checkpoint.paragraphIndex
        }
        let matches = readable.filter { fingerprints[$0] == checkpoint.paragraphFingerprint }
        if matches.count == 1 { return matches.first }
        let contextual = matches.filter { index in
            let before = index > 0 ? fingerprints[index - 1] : nil
            let after = index + 1 < fingerprints.count ? fingerprints[index + 1] : nil
            return before == checkpoint.previousFingerprint && after == checkpoint.nextFingerprint
        }
        // Repeated paragraphs are not resolved by guessing the closest index.
        return contextual.count == 1 ? contextual.first : nil
    }
}

enum ReadingResumeAudioResolution: Equatable {
    case waiting
    case seek(segmentIndex: Int, seconds: Double)
    case unavailable
}

enum ReadingResumeContract {
    struct SpeechSuffixPlan {
        let text: String
        /// Text/timestamp context only. These entries must never be enqueued.
        let prefix: [AudioSegment]
        let nextSegmentIndex: Int
    }

    static func speechSuffixPlan(source: String, segments: [AudioSegment],
                                 cursor: ReadingResumeAudioCursor) -> SpeechSuffixPlan? {
        guard cursor.isValid, segments.indices.contains(cursor.segmentIndex),
              cursor.segmentIndex > 0, source.utf16.count <= 65_536 else { return nil }
        let current = segments[cursor.segmentIndex]
        guard fingerprint(current.text) == cursor.segmentTextFingerprint else { return nil }
        let prior = Array(segments.prefix(cursor.segmentIndex))
        let prefix = semanticText(prior.map(\.text).joined())
        // Validate the whole prefix and target chunk together. A minimum
        // prefix length would make short sentences pay for discarded audio.
        guard !prefix.isEmpty,
              semanticText(source).hasPrefix(prefix + semanticText(current.text)) else { return nil }
        var offset = source.startIndex
        var consumed = 0
        while offset < source.endIndex, consumed < prefix.utf16.count {
            consumed += semanticText(String(source[offset])).utf16.count
            offset = source.index(after: offset)
        }
        guard consumed == prefix.utf16.count else { return nil }
        while offset < source.endIndex, semanticText(String(source[offset])).isEmpty {
            offset = source.index(after: offset)
        }
        guard offset < source.endIndex else { return nil }
        let suffix = String(source[offset...])
        guard SpeechTextSanitizer.containsSpeakableContent(suffix) else { return nil }
        let context = prior.map {
            AudioSegment(paragraphIndex: $0.paragraphIndex, segmentIndex: $0.segmentIndex,
                audioData: Data(), timestamps: $0.timestamps, duration: $0.duration,
                text: $0.text, isWavFormat: $0.isWavFormat, speaker: $0.speaker)
        }
        return SpeechSuffixPlan(text: suffix, prefix: context, nextSegmentIndex: prior.count)
    }

    private static func semanticText(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        return String(String.UnicodeScalarView(text.lowercased()
            .precomposedStringWithCanonicalMapping.unicodeScalars.filter { allowed.contains($0) }))
    }

    /// Exact source anchor for continuing at the first unread word after a
    /// provider reflow. Generated audio must verify its prefix and target word.
    static func sourceWordCursor(source: String, range: NSRange) -> ReadingResumeAudioCursor? {
        let text = source as NSString
        guard range.location >= 0, range.length > 0, range.location <= text.length,
              range.length <= text.length - range.location else { return nil }
        let prefix = text.substring(to: range.location)
        let word = text.substring(with: range)
        let normalizedPrefix = semanticText(prefix), normalizedWord = semanticText(word)
        guard !normalizedWord.isEmpty else { return nil }
        var cursor = ReadingResumeAudioCursor(outputUTF16Offset: range.location,
            outputPrefixFingerprint: fingerprint(prefix), wordFingerprint: fingerprint(word.lowercased()),
            wordFraction: 0, segmentIndex: 0,
            segmentTextFingerprint: fingerprint("source:verify-generated-words"),
            audioFingerprint: fingerprint("source:no-audio-identity"), segmentTime: 0)
        cursor.outputUTF16Length = range.length
        cursor.semanticOffset = normalizedPrefix.utf16.count
        cursor.semanticPrefixFingerprint = fingerprint(normalizedPrefix)
        cursor.semanticWordFingerprint = fingerprint(normalizedWord)
        cursor.semanticWordUTF16Length = normalizedWord.utf16.count
        return cursor
    }

    private struct SourceUnit {
        let character: Character
        let paragraph: Int
        let range: NSRange
    }

    private static func sourceUnits(_ paragraphs: [ReadingParagraph]) -> [SourceUnit] {
        paragraphs.enumerated().flatMap { index, paragraph -> [SourceUnit] in
            guard paragraph.type.isReadable else { return [] }
            var offset = 0
            return paragraph.text.flatMap { character -> [SourceUnit] in
                let value = String(character)
                let range = NSRange(location: offset, length: value.utf16.count)
                offset += range.length
                return semanticText(value).map { SourceUnit(character: $0, paragraph: index, range: range) }
            }
        }
    }

    static func captureReflow(source: String, visual: ReadingResumeVisualCursor?,
                              audio: ReadingResumeAudioCursor,
                              precedingSource: String = "", followingSource: String = "") -> ReadingResumeReflowCursor? {
        guard let range = visual?.range(in: source),
              let wordHash = audio.semanticWordFingerprint ?? audio.untimedAnchor?.textFingerprint else { return nil }
        let text = source as NSString
        let before = Array(semanticText(precedingSource + text.substring(to: range.location)).suffix(48))
        let word = Array(semanticText(text.substring(with: range)))
        let after = Array(semanticText(text.substring(from: NSMaxRange(range)) + followingSource).prefix(48))
        guard fingerprint(String(word)) == wordHash else { return nil }
        var result = ReadingResumeReflowCursor(beforeHash: fingerprint(String(before)), beforeCount: before.count,
            wordHash: wordHash, wordCount: word.count, afterHash: fingerprint(String(after)), afterCount: after.count)
        result.usesSentenceTiming = audio.untimedAnchor != nil && audio.semanticWordFingerprint == nil
        // An untimed sentence is itself fully hashed context. Compact pages
        // may contain little outside that sentence; still require at least
        // 32 exact semantic characters overall, with a unique match.
        let lengths = result.usesSentenceTiming == true ? [8, 12, 16, 24, 32, 48] : [16, 24, 32, 48]
        result.beforeFragments = Dictionary(uniqueKeysWithValues: lengths
            .filter { $0 <= before.count }.map { ($0, fingerprint(String(before.suffix($0)))) })
        result.afterFragments = Dictionary(uniqueKeysWithValues: lengths
            .filter { $0 <= after.count }.map { ($0, fingerprint(String(after.prefix($0)))) })
        return result.isValid ? result : nil
    }

    /// Relocate only an exact, unambiguous word plus at least 32 verified context
    /// characters. A page edge may omit one side. OCR may drop one letter after
    /// reflow; a one-character repair must reproduce the saved hash exactly.
    /// The TTS cursor is rebuilt for the new paragraph, so its old
    /// segment time can never accidentally seek into different spoken text.
    static func relocatedKindleCheckpoint(_ checkpoint: ReadingResumeCheckpoint,
                                           paragraphs: [ReadingParagraph]) -> ReadingResumeCheckpoint? {
        guard checkpoint.sourceKind == .kindle else { return nil }
        return relocatedCheckpoint(checkpoint, paragraphs: paragraphs, permitsOCRCorrection: true)
    }

    static func relocatedKoboCheckpoint(_ checkpoint: ReadingResumeCheckpoint,
                                        paragraphs: [ReadingParagraph]) -> ReadingResumeCheckpoint? {
        guard checkpoint.sourceKind == .kobo else { return nil }
        return relocatedCheckpoint(checkpoint, paragraphs: paragraphs, permitsOCRCorrection: false)
    }

    static func relocatedWeReadCheckpoint(_ checkpoint: ReadingResumeCheckpoint,
                                          paragraphs: [ReadingParagraph]) -> ReadingResumeCheckpoint? {
        guard checkpoint.sourceKind == .weread else { return nil }
        return relocatedCheckpoint(checkpoint, paragraphs: paragraphs, permitsOCRCorrection: false)
    }

    private static func relocatedCheckpoint(_ checkpoint: ReadingResumeCheckpoint,
                                            paragraphs: [ReadingParagraph],
                                            permitsOCRCorrection: Bool) -> ReadingResumeCheckpoint? {
        guard checkpoint.isValid,
              let context = checkpoint.reflow, context.isValid,
              let oldAudio = checkpoint.audio,
              context.usesSentenceTiming != true || oldAudio.untimedAnchor != nil,
              oldAudio.semanticWordFingerprint == context.wordHash ||
                (!permitsOCRCorrection && oldAudio.untimedAnchor?.textFingerprint == context.wordHash) else { return nil }
        let units = sourceUnits(paragraphs)
        guard units.count >= context.wordCount else { return nil }
        func hash(_ range: Range<Int>) -> String { fingerprint(String(units[range].map(\.character))) }
        var matches: [(Int, NSRange)] = []
        for start in 0...(units.count - context.wordCount) {
            let end = start + context.wordCount
            guard units[start].paragraph == units[end - 1].paragraph,
                  hash(start..<end) == context.wordHash else { continue }
            let hasBefore = start >= context.beforeCount
            let hasAfter = units.count - end >= context.afterCount
            func matchesContext(edge: Int, before: Bool, count: Int, expectedHash: String) -> Bool {
                if permitsOCRCorrection {
                    return matchesOCRContext(units: units, edge: edge, before: before,
                                             count: count, expectedHash: expectedHash)
                }
                return hash(before ? (edge - count)..<edge : edge..<(edge + count)) == expectedHash
            }
            func verifiedStrictContext(before: Bool) -> Int? {
                let maximum = before ? context.beforeCount : context.afterCount
                let available = before ? start : units.count - end
                let fullHash = before ? context.beforeHash : context.afterHash
                let fragments = before ? context.beforeFragments : context.afterFragments
                let count = available >= maximum ? maximum :
                    (fragments?.keys.filter { $0 >= (context.usesSentenceTiming == true ? 8 : 16) && $0 <= min(maximum, available) }.max() ?? 0)
                if count == 0 { return 0 }
                guard let expected = count == maximum ? fullHash : fragments?[count], expected.count == 64,
                      matchesContext(edge: before ? start : end, before: before,
                                     count: count, expectedHash: expected) else { return nil }
                return count
            }
            if permitsOCRCorrection {
                guard (!hasBefore || matchesContext(edge: start, before: true,
                            count: context.beforeCount, expectedHash: context.beforeHash)),
                      (!hasAfter || matchesContext(edge: end, before: false,
                            count: context.afterCount, expectedHash: context.afterHash)),
                      (hasBefore ? context.beforeCount : 0) + (hasAfter ? context.afterCount : 0) >= 32 else { continue }
            } else {
                guard let before = verifiedStrictContext(before: true),
                      let after = verifiedStrictContext(before: false),
                      before + after + (context.usesSentenceTiming == true ? context.wordCount : 0) >= 32 else { continue }
            }
            let first = units[start], last = units[end - 1]
            matches.append((first.paragraph, NSRange(location: first.range.location,
                length: NSMaxRange(last.range) - first.range.location)))
            if matches.count > 1 { return nil }
        }
        guard let (index, range) = matches.first else { return nil }
        let source = paragraphs[index].text as NSString
        let prefix = source.substring(to: range.location)
        let semanticPrefix = semanticText(prefix)
        var audio = ReadingResumeAudioCursor(outputUTF16Offset: range.location,
            outputPrefixFingerprint: fingerprint(prefix), wordFingerprint: oldAudio.wordFingerprint,
            wordFraction: oldAudio.wordFraction, segmentIndex: 0,
            segmentTextFingerprint: oldAudio.untimedAnchor == nil ? fingerprint("reflow:verify-generated-words") : oldAudio.segmentTextFingerprint,
            audioFingerprint: fingerprint("reflow:no-audio-identity"),
            segmentTime: oldAudio.untimedAnchor == nil ? 0 : oldAudio.segmentTime)
        audio.outputUTF16Length = range.length
        if oldAudio.untimedAnchor != nil {
            audio.segmentDuration = oldAudio.segmentDuration
            audio.untimedAnchor = ReadingResumeUntimedAnchor(prefixUTF16Length: semanticPrefix.utf16.count,
                prefixFingerprint: fingerprint(semanticPrefix),
                textUTF16Length: semanticText(source.substring(with: range)).utf16.count,
                textFingerprint: context.wordHash)
        } else {
            audio.semanticOffset = semanticPrefix.utf16.count
            audio.semanticPrefixFingerprint = fingerprint(semanticPrefix)
            audio.semanticWordFingerprint = context.wordHash
            audio.semanticWordUTF16Length = semanticText(source.substring(with: range)).utf16.count
        }
        var result = ReadingResumeDocumentIndex(paragraphs: paragraphs).checkpoint(
            sourceKind: checkpoint.sourceKind, paragraphIndex: index, audio: audio, now: checkpoint.updatedAt)
        result?.visual = ReadingResumeVisualCursor(sourceFingerprint: fingerprint(paragraphs[index].text),
            utf16Offset: range.location, utf16Length: range.length)
        result?.reflow = context
        return result
    }

    private static func matchesOCRContext(units: [SourceUnit], edge: Int, before: Bool,
                                           count: Int, expectedHash: String) -> Bool {
        func characters(_ length: Int) -> [Character]? {
            let range = before ? (edge - length)..<edge : edge..<(edge + length)
            guard range.lowerBound >= 0, range.upperBound <= units.count else { return nil }
            return units[range].map(\.character)
        }
        guard let exact = characters(count) else { return false }
        if fingerprint(String(exact)) == expectedHash { return true }
        guard count >= 16 else { return false }
        // Bounded to one ASCII OCR insertion/deletion/substitution per context
        // side. No source text is changed and the target word itself must match.
        let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        if let short = characters(count - 1) {
            for offset in 0...short.count {
                for character in alphabet {
                    var candidate = short; candidate.insert(character, at: offset)
                    if fingerprint(String(candidate)) == expectedHash { return true }
                }
            }
        }
        if let long = characters(count + 1) {
            for offset in long.indices {
                var candidate = long; candidate.remove(at: offset)
                if fingerprint(String(candidate)) == expectedHash { return true }
            }
        }
        for offset in exact.indices {
            for character in alphabet where character != exact[offset] {
                var candidate = exact; candidate[offset] = character
                if fingerprint(String(candidate)) == expectedHash { return true }
            }
        }
        return false
    }
    /// Match a saved word once, for the initial source viewport. Punctuation and
    /// whitespace normalization may differ in TTS. Ambiguous context fails closed.
    static func captureVisual(output: String, offset: Int, length: Int? = nil, source: String) -> ReadingResumeVisualCursor? {
        guard offset >= 0, offset < output.utf16.count else { return nil }
        if let length, length <= 0 || length > output.utf16.count - offset { return nil }
        func normalized(_ text: String) -> (characters: [Character], ranges: [NSRange]) {
            var characters: [Character] = [], ranges: [NSRange] = []
            var location = 0
            for character in text {
                let value = String(character)
                let range = NSRange(location: location, length: value.utf16.count)
                location += range.length
                guard value.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }
                for folded in value.lowercased().precomposedStringWithCanonicalMapping {
                    characters.append(folded); ranges.append(range)
                }
            }
            return (characters, ranges)
        }
        let out = normalized(output)
        let src = normalized(source)
        guard let wordStart = out.ranges.firstIndex(where: { $0.location >= offset }) else { return nil }
        let remainder = (output as NSString).substring(from: offset) as NSString
        let wordLength = remainder.rangeOfCharacter(from: .whitespacesAndNewlines).location
        // Timestamps define words in Chinese/Japanese too; whitespace alone
        // could otherwise select every remaining character of a long paragraph.
        let wordEnd = offset + (length ?? (wordLength == NSNotFound ? remainder.length : wordLength))
        let count = max(1, out.ranges[wordStart...].prefix(while: { $0.location < wordEnd }).count)
        guard wordStart + count <= out.characters.count else { return nil }
        let end = wordStart + count
        let sourceStart: Int
        if src.characters.count >= end,
           src.characters.prefix(end).elementsEqual(out.characters.prefix(end)) {
            sourceStart = wordStart
        } else {
            let contextStart = max(0, wordStart - 64)
            let needle = Array(out.characters[contextStart..<end])
            guard src.characters.count >= needle.count else { return nil }
            var matches: [Int] = []
            for i in 0...(src.characters.count - needle.count) {
                if src.characters[i..<(i + needle.count)].elementsEqual(needle) { matches.append(i) }
                if matches.count > 1 { return nil }
            }
            guard let match = matches.first else { return nil }
            sourceStart = match + wordStart - contextStart
        }
        let first = src.ranges[sourceStart], last = src.ranges[sourceStart + count - 1]
        return ReadingResumeVisualCursor(sourceFingerprint: fingerprint(source),
            utf16Offset: first.location, utf16Length: NSMaxRange(last) - first.location)
    }

    static func fingerprint(_ text: String) -> String {
        fingerprint(Data(text.precomposedStringWithCanonicalMapping.utf8))
    }

    static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private struct TimedWord {
        let range: NSRange
        let timestamp: TTSTimestamp
    }

    /// Align exclusively within processed TTS output, never back into source.
    private static func timedWords(_ segment: AudioSegment) -> [TimedWord] {
        let text = segment.text as NSString
        var offset = 0
        return segment.timestamps.compactMap { timestamp in
            let word = timestamp.word.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !word.isEmpty, timestamp.startTime.isFinite, timestamp.endTime.isFinite,
                  timestamp.startTime >= 0, timestamp.endTime > timestamp.startTime else { return nil }
            let range = text.range(of: word, options: [.caseInsensitive],
                                   range: NSRange(location: offset, length: text.length - offset))
            guard range.location != NSNotFound else { return nil }
            offset = NSMaxRange(range)
            return TimedWord(range: range, timestamp: timestamp)
        }
    }

    static func captureAudio(
        segments: [AudioSegment], currentSegmentID: String, time: Double
    ) -> ReadingResumeAudioCursor? {
        guard time.isFinite, time >= 0,
              let position = segments.firstIndex(where: { $0.id == currentSegmentID }) else { return nil }
        let segment = segments[position]
        let words = timedWords(segment)
        let currentWord = words.last(where: { $0.timestamp.startTime <= time }) ?? words.first
        let priorText = segments.prefix(position).map(\.text).joined()
        let localOffset = currentWord?.range.location ?? 0
        let prefix = priorText + (segment.text as NSString).substring(to: localOffset)
        let fraction: Double
        if let word = currentWord {
            fraction = min(1, max(0, (time - word.timestamp.startTime)
                / (word.timestamp.endTime - word.timestamp.startTime)))
        } else { fraction = 0 }
        var cursor = ReadingResumeAudioCursor(
            outputUTF16Offset: priorText.utf16.count + localOffset,
            outputPrefixFingerprint: fingerprint(prefix),
            wordFingerprint: currentWord.map { fingerprint($0.timestamp.word.lowercased()) },
            wordFraction: fraction, segmentIndex: position,
            segmentTextFingerprint: fingerprint(segment.text),
            audioFingerprint: fingerprint(segment.audioData), segmentTime: time
        )
        cursor.segmentDuration = segment.duration.isFinite && segment.duration > 0 ? segment.duration : nil
        cursor.outputUTF16Length = currentWord?.range.length
        if let word = currentWord {
            let semanticPrefix = semanticText(prefix)
            cursor.semanticOffset = semanticPrefix.utf16.count
            cursor.semanticPrefixFingerprint = fingerprint(semanticPrefix)
            cursor.semanticWordFingerprint = fingerprint(semanticText(word.timestamp.word))
            cursor.semanticWordUTF16Length = semanticText(word.timestamp.word).utf16.count
        } else if segment.timestamps.isEmpty {
            // Segment-timed speech anchors the actual spoken sentence. A
            // whitespace-derived range could otherwise swallow the remainder
            // of a Chinese paragraph and fail a later compact-page match.
            cursor.outputUTF16Length = segment.text.utf16.count
            let normalizedPrefix = semanticText(priorText)
            let normalizedText = semanticText(segment.text)
            cursor.untimedAnchor = ReadingResumeUntimedAnchor(
                prefixUTF16Length: normalizedPrefix.utf16.count,
                prefixFingerprint: fingerprint(normalizedPrefix),
                textUTF16Length: normalizedText.utf16.count,
                textFingerprint: fingerprint(normalizedText)
            )
        }
        return cursor
    }

#if DEBUG
    static func audioResumeDiagnostic(_ cursor: ReadingResumeAudioCursor, segments: [AudioSegment]) -> String {
        let segmentSummary = segments.enumerated().map { index, segment in
            "\(index):chars=\(segment.text.utf16.count),timed=\(timedWords(segment).count)/\(segment.timestamps.count),text=\(fingerprint(segment.text).prefix(10)),audio=\(fingerprint(segment.audioData).prefix(10))"
        }.joined(separator: ";")
        return "offset=\(cursor.outputUTF16Offset) seg=\(cursor.segmentIndex) time=\(cursor.segmentTime) word=\(cursor.wordFingerprint != nil) semantic=\(cursor.semanticOffset ?? -1) text=\(cursor.segmentTextFingerprint.prefix(10)) audio=\(cursor.audioFingerprint.prefix(10)) segments=[\(segmentSummary)]"
    }
#endif

    /// Automatic page handoff removes the sentence already completed on the
    /// preceding page. On reopening, WeRead renders that prefix again. Match
    /// the entire saved suffix by hash before removing it from the TTS input.
    static func restoreWeReadPage(_ page: [ReadingParagraph], checkpoint: ReadingResumeCheckpoint) -> [ReadingParagraph]? {
        if ReadingResumeDocumentIndex(paragraphs: page).resolve(checkpoint) != nil { return page }
        guard [.weread, .kobo].contains(checkpoint.sourceKind), checkpoint.paragraphIndex == 0,
              let first = page.first, first.text.utf16.count <= 16_384 else { return nil }
        for offset in first.text.indices.dropFirst() {
            let suffix = String(first.text[offset...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard suffix.utf16.count >= 8 else { break }
            let paragraph = ReadingParagraph(id: first.id, text: suffix, type: first.type)
            guard fingerprint(paragraph.resolvedSpeechText) == checkpoint.paragraphFingerprint else { continue }
            var restored = page
            restored[0] = paragraph
            return restored
        }
        return nil
    }

    static func resolveAudio(
        _ cursor: ReadingResumeAudioCursor, segments: [AudioSegment], isComplete: Bool
    ) -> ReadingResumeAudioResolution {
        guard cursor.isValid else { return .unavailable }
        // Identical bytes allow exact restoration, including silence or audio
        // without word timestamps. IDs alone are not immutable audio identity.
        if segments.indices.contains(cursor.segmentIndex) {
            let segment = segments[cursor.segmentIndex]
            let preceding = segments.prefix(cursor.segmentIndex).map(\.text).joined()
            let localOffset = cursor.outputUTF16Offset - preceding.utf16.count
            if (0...segment.text.utf16.count).contains(localOffset),
               fingerprint(preceding + (segment.text as NSString).substring(to: localOffset)) == cursor.outputPrefixFingerprint,
               fingerprint(segment.text) == cursor.segmentTextFingerprint {
                if fingerprint(segment.audioData) == cursor.audioFingerprint {
                    return .seek(segmentIndex: cursor.segmentIndex, seconds: cursor.segmentTime)
                }
                // Segment-timed languages have no word timeline. A fresh TTS
                // request may vary its waveform while reading the same verified
                // sentence. Preserve position within that sentence's measured
                // duration; do not pretend to infer a word timestamp.
                if cursor.wordFingerprint == nil, segment.timestamps.isEmpty,
                   segment.duration.isFinite, segment.duration > 0 {
                    let seconds: Double
                    if let duration = cursor.segmentDuration, duration.isFinite, duration > 0 {
                        seconds = min(1, max(0, cursor.segmentTime / duration)) * segment.duration
                    } else {
                        // Existing checkpoints did not record duration. Keep
                        // their elapsed time within the identical sentence.
                        seconds = min(cursor.segmentTime, segment.duration)
                    }
                    return .seek(segmentIndex: cursor.segmentIndex, seconds: seconds)
                }
            }
        }
        if cursor.wordFingerprint == nil, cursor.untimedAnchor != nil {
            return resolveUntimedAudio(cursor, segments: segments, isComplete: isComplete)
        }
        var precedingText = ""
        for (index, segment) in segments.enumerated() {
            let end = precedingText.utf16.count + segment.text.utf16.count
            if cursor.outputUTF16Offset < end {
                let localOffset = cursor.outputUTF16Offset - precedingText.utf16.count
                guard localOffset >= 0,
                      let word = timedWords(segment).first(where: { $0.range.location == localOffset }),
                      let expectedWord = cursor.wordFingerprint,
                      fingerprint(word.timestamp.word.lowercased()) == expectedWord,
                      fingerprint(precedingText + (segment.text as NSString).substring(to: localOffset))
                        == cursor.outputPrefixFingerprint else {
                    return resolveSemanticAudio(cursor, segments: segments, isComplete: isComplete)
                }
                return .seek(segmentIndex: index, seconds: word.timestamp.startTime
                    + cursor.wordFraction * (word.timestamp.endTime - word.timestamp.startTime))
            }
            precedingText += segment.text
        }
        return resolveSemanticAudio(cursor, segments: segments, isComplete: isComplete)
    }

    private static func resolveUntimedAudio(
        _ cursor: ReadingResumeAudioCursor, segments: [AudioSegment], isComplete: Bool
    ) -> ReadingResumeAudioResolution {
        guard let anchor = cursor.untimedAnchor,
              anchor.prefixUTF16Length >= 0, anchor.textUTF16Length > 0,
              anchor.textUTF16Length <= 16_384,
              segments.allSatisfy({ $0.timestamps.isEmpty }) else { return .unavailable }
        let texts = segments.map { semanticText($0.text) }
        let spoken = texts.joined() as NSString
        let start = anchor.prefixUTF16Length
        guard start <= spoken.length, anchor.textUTF16Length <= spoken.length - start else {
            return isComplete ? .unavailable : .waiting
        }
        guard fingerprint(spoken.substring(to: start)) == anchor.prefixFingerprint,
              fingerprint(spoken.substring(with: NSRange(location: start, length: anchor.textUTF16Length)))
                == anchor.textFingerprint else { return .unavailable }
        var offset = 0
        for (index, text) in texts.enumerated() {
            let end = offset + text.utf16.count
            if start < end {
                let segment = segments[index]
                if offset == start, text.utf16.count == anchor.textUTF16Length,
                   fingerprint(segment.text) == cursor.segmentTextFingerprint,
                   let oldDuration = cursor.segmentDuration, oldDuration.isFinite, oldDuration > 0,
                   segment.duration.isFinite, segment.duration > 0 {
                    return .seek(segmentIndex: index, seconds:
                        min(1, max(0, cursor.segmentTime / oldDuration)) * segment.duration)
                }
                // Exact chunk restoration above preserves fractional position.
                // Repartitioned audio replays this verified boundary, never an
                // estimated word/time that could skip previously unheard text.
                return .seek(segmentIndex: index, seconds: 0)
            }
            offset = end
        }
        return isComplete ? .unavailable : .waiting
    }

    /// A repeated request may normalize quotes/spaces differently or split its
    /// audio chunks differently. The entire preceding word stream and current
    /// word must still match; changed or missing spoken words never silently seek.
    private static func resolveSemanticAudio(
        _ cursor: ReadingResumeAudioCursor, segments: [AudioSegment], isComplete: Bool
    ) -> ReadingResumeAudioResolution {
        guard let offset = cursor.semanticOffset, offset >= 0,
              let prefixHash = cursor.semanticPrefixFingerprint,
              let wordHash = cursor.semanticWordFingerprint else {
            return isComplete ? .unavailable : .waiting
        }
        var preceding = ""
        for (index, segment) in segments.enumerated() {
            let normalized = semanticText(segment.text)
            if offset < preceding.utf16.count + normalized.utf16.count {
                for word in timedWords(segment) {
                    let localPrefix = semanticText((segment.text as NSString).substring(to: word.range.location))
                    guard preceding.utf16.count + localPrefix.utf16.count == offset else { continue }
                    if fingerprint(preceding + localPrefix) == prefixHash,
                       fingerprint(semanticText(word.timestamp.word)) == wordHash {
                        return .seek(segmentIndex: index, seconds: word.timestamp.startTime
                            + cursor.wordFraction * (word.timestamp.endTime - word.timestamp.startTime))
                    }
                }
                return resolveRetokenizedAudio(cursor, segments: segments, isComplete: isComplete)
            }
            preceding += normalized
        }
        return resolveRetokenizedAudio(cursor, segments: segments, isComplete: isComplete)
    }

    /// Engines can split or merge timestamp tokens while speaking identical
    /// text ("can't" vs "can" + "'t", or several Chinese characters). Verify the
    /// saved prefix AND full target word before accepting a different boundary.
    /// Replay the first overlapping timed token; an old fractional time cannot
    /// safely describe a differently sized token. Missing timing never guesses.
    private static func resolveRetokenizedAudio(
        _ cursor: ReadingResumeAudioCursor, segments: [AudioSegment], isComplete: Bool
    ) -> ReadingResumeAudioResolution {
        let unresolved: ReadingResumeAudioResolution = isComplete ? .unavailable : .waiting
        guard let offset = cursor.semanticOffset, offset >= 0,
              let prefixHash = cursor.semanticPrefixFingerprint,
              let wordHash = cursor.semanticWordFingerprint else { return unresolved }
        let raw = segments.map(\.text).joined() as NSString
        let normalized = semanticText(raw as String) as NSString
        var length = cursor.semanticWordUTF16Length
        if length == nil, let rawLength = cursor.outputUTF16Length,
           cursor.outputUTF16Offset <= raw.length, rawLength > 0,
           rawLength <= raw.length - cursor.outputUTF16Offset,
           fingerprint(raw.substring(to: cursor.outputUTF16Offset)) == cursor.outputPrefixFingerprint {
            // Recover checkpoints written before semantic word length existed.
            // The full normalized word hash below must still match exactly.
            length = semanticText(raw.substring(with: NSRange(
                location: cursor.outputUTF16Offset, length: rawLength))).utf16.count
        }
        guard let length, length > 0, offset <= normalized.length,
              length <= normalized.length - offset,
              fingerprint(normalized.substring(to: offset)) == prefixHash,
              fingerprint(normalized.substring(with: NSRange(location: offset, length: length))) == wordHash
        else { return unresolved }

        let end = offset + length
        var covered = offset
        var precedingLength = 0
        var first: (index: Int, time: Double)?
        for (index, segment) in segments.enumerated() {
            let text = segment.text as NSString
            for word in timedWords(segment) {
                let start = precedingLength + semanticText(text.substring(to: word.range.location)).utf16.count
                let wordEnd = start + semanticText(text.substring(with: word.range)).utf16.count
                guard wordEnd > covered else { continue }
                guard start <= covered,
                      word.timestamp.startTime < segment.duration,
                      word.timestamp.endTime <= segment.duration else { return unresolved }
                if first == nil { first = (index, word.timestamp.startTime) }
                covered = wordEnd
                if covered >= end, let first {
                    return .seek(segmentIndex: first.index, seconds: first.time)
                }
            }
            precedingLength += semanticText(segment.text).utf16.count
        }
        return unresolved
    }
}
