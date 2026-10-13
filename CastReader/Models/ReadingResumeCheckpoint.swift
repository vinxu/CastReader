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
    let updatedAt: Date

    var isValid: Bool {
        schemaVersion == 1 && paragraphIndex >= 0
            && paragraphFingerprint.count == 64 && structureFingerprint.count == 64
            && (audio?.isValid ?? true)
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

struct ReadingResumeAudioCursor: Codable, Equatable {
    let outputUTF16Offset: Int
    let outputPrefixFingerprint: String
    let wordFingerprint: String?
    let wordFraction: Double
    let segmentIndex: Int
    let segmentTextFingerprint: String
    let audioFingerprint: String
    let segmentTime: Double
    var outputUTF16Length: Int? = nil
    var semanticOffset: Int? = nil
    var semanticPrefixFingerprint: String? = nil
    var semanticWordFingerprint: String? = nil

    var isValid: Bool {
        outputUTF16Offset >= 0 && segmentIndex >= 0
            && segmentTime.isFinite && segmentTime >= 0
            && wordFraction.isFinite && (0...1).contains(wordFraction)
            && outputPrefixFingerprint.count == 64
            && segmentTextFingerprint.count == 64 && audioFingerprint.count == 64
    }
}

struct ReadingResumeDocumentIndex {
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
    private static func semanticText(_ text: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        return String(String.UnicodeScalarView(text.lowercased()
            .precomposedStringWithCanonicalMapping.unicodeScalars.filter { allowed.contains($0) }))
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
        cursor.outputUTF16Length = currentWord?.range.length
        if let word = currentWord {
            let semanticPrefix = semanticText(prefix)
            cursor.semanticOffset = semanticPrefix.utf16.count
            cursor.semanticPrefixFingerprint = fingerprint(semanticPrefix)
            cursor.semanticWordFingerprint = fingerprint(semanticText(word.timestamp.word))
        }
        return cursor
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
               fingerprint(segment.text) == cursor.segmentTextFingerprint,
               fingerprint(segment.audioData) == cursor.audioFingerprint {
                return .seek(segmentIndex: cursor.segmentIndex, seconds: cursor.segmentTime)
            }
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
                return isComplete ? .unavailable : .waiting
            }
            preceding += normalized
        }
        return isComplete ? .unavailable : .waiting
    }
}
