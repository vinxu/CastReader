import UIKit
import CoreText

/// Captions belong to one media item, not a growing explanation block. Layout
/// changes only the visual cues; it never splits or regenerates the audio.
struct ExplainSubtitleTimeline {
    struct Cue {
        let text: String
        let range: NSRange
        let start: Double
        let exactWordStart: Bool
    }
    let cues: [Cue]
    let usesWordTiming: Bool
    let timingDiagnostic: String

    init(segment: AudioSegment, width: CGFloat, font: UIFont) {
        let ranges = Self.lineRanges(segment.text, width: width, font: font)
        let source = segment.text as NSString
        let units = Self.units(segment.text)
        let timestamps = segment.timingTimestamps.filter { !Self.units($0.word).isEmpty }
        let spoken = timestamps.flatMap { Self.units($0.word).map(\.value) }
        let coverage = !units.isEmpty && spoken == units.map(\.value)
        let granularity = TTSTimestampQuality.hasReliableWordGranularity(text: segment.text, timestamps: timestamps, duration: segment.duration)
        let valid = coverage && granularity &&
            timestamps.enumerated().allSatisfy { index, timestamp in
                timestamp.startTime.isFinite && timestamp.endTime.isFinite &&
                timestamp.startTime >= 0 && timestamp.endTime > timestamp.startTime &&
                (index == 0 || timestamp.startTime >= timestamps[index - 1].startTime)
            }
        usesWordTiming = valid
        timingDiagnostic = "coverage=\(coverage) granularity=\(granularity) tokens=\(timestamps.count) sourceUnits=\(units.count) timedUnits=\(spoken.count)"
        var starts: [Double] = []
        var wordStarts = Set<Int>()
        if valid {
            for timestamp in timestamps {
                wordStarts.insert(starts.count)
                let count = Self.units(timestamp.word).count
                // Normally a cue begins at a word boundary. Very long tokens
                // and CJK multi-character tokens may need an internal cut.
                for index in 0..<count {
                    starts.append(timestamp.startTime + (timestamp.endTime - timestamp.startTime) * Double(index) / Double(count))
                }
            }
        }
        let duration = max(0, segment.duration.isFinite ? segment.duration : 0)
        cues = ranges.map { range in
            let unitIndex = units.firstIndex { $0.range.location >= range.location } ?? max(0, units.count - 1)
            let start = valid ? starts[unitIndex] : duration * Double(unitIndex) / Double(max(1, units.count))
            return Cue(text: source.substring(with: range), range: range, start: start,
                       exactWordStart: valid && wordStarts.contains(unitIndex))
        }
    }

    func cue(at mediaTime: Double) -> Cue? {
        let time = mediaTime.isFinite ? max(0, mediaTime) : 0
        return cues.last { $0.start <= time } ?? cues.first
    }

    /// CoreText uses the same font metrics as the label. Keep complete Unicode
    /// graphemes and punctuation; a long unbroken token is wrapped, never elided.
    static func lineRanges(_ text: String, width: CGFloat, font: UIFont) -> [NSRange] {
        guard !text.isEmpty else { return [] }
        let source = text as NSString
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let available = Double(max(1, width - 2)) // fractional glyph/SwiftUI rounding
        var result: [NSRange] = []
        for sentence in ReadingSentenceContract.nsRanges(in: text, lineBreakIsBoundary: true) {
            var offset = sentence.location
            while offset < NSMaxRange(sentence) {
                var count = CTTypesetterSuggestLineBreak(typesetter, offset, available)
                if count <= 0 { count = source.rangeOfComposedCharacterSequence(at: offset).length }
                count = min(count, NSMaxRange(sentence) - offset)
                let raw = NSRange(location: offset, length: count)
                if let swiftRange = Range(raw, in: text) {
                    let trimmed = text[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        let range = source.range(of: trimmed, options: .literal, range: raw)
                        result.append(range)
                    }
                }
                offset += count
            }
        }
        return result
    }

    private struct Unit { let value: String; let range: NSRange }
    private static func units(_ text: String) -> [Unit] {
        var result: [Unit] = []
        for index in text.indices {
            let range = index..<text.index(after: index)
            let normalized = String(text[range]).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            for scalar in normalized.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
                result.append(Unit(value: String(scalar), range: NSRange(range, in: text)))
            }
        }
        return result
    }
}
