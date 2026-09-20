import Foundation

/// One producer survives read-ahead -> playback promotion. Pending audio is
/// bounded by measured playback time and bytes, independently of text length.
@MainActor
final class SpeechStreamBuffer {
    let paragraphIndex: Int
    let voice: String
    let language: String
    let requestID: String?
    var segments: [AudioSegment] = []
    var continuation: TTSContinuation?
    var task: Task<Void, Never>?
    var promoted = false
    var finished = false
    var failure: Error?
    private var requestStarted: TimeInterval?
    private(set) var generationSeconds: Double = 2

    init(paragraphIndex: Int, voice: String, language: String, requestID: String?) {
        self.paragraphIndex = paragraphIndex
        self.voice = voice
        self.language = language
        self.requestID = requestID
    }

    var targetSeconds: Double { min(20, max(12, generationSeconds * 3 + 3)) }

    func beginRequest(_ continuation: TTSContinuation) {
        self.continuation = continuation
        requestStarted = ProcessInfo.processInfo.systemUptime
    }

    func append(_ segment: AudioSegment) {
        if let started = requestStarted {
            let elapsed = ProcessInfo.processInfo.systemUptime - started
            generationSeconds = 0.7 * generationSeconds + 0.3 * min(15, max(0.1, elapsed))
        }
        requestStarted = nil
        segments.append(segment)
    }

    func canRequest(currentSegmentID: String?, position: Double, rate: Double, paused: Bool) -> Bool {
        guard !paused else { return false }
        let start = currentSegmentID.flatMap { id in segments.firstIndex { $0.id == id } } ?? 0
        let pending = segments.dropFirst(start)
        let duration = max(0, pending.reduce(0) { $0 + max(0, $1.duration) }
            - (currentSegmentID == nil ? 0 : position)) / max(0.25, rate)
        let bytes = pending.reduce(0) { $0 + $1.audioData.count }
        return pending.isEmpty || (duration < targetSeconds && pending.count < 64 && bytes < 4 * 1024 * 1024)
    }
}

/// Short narration units whose marks can be tied to spoken text without a
/// later whole-block retiming. Unmatched/paraphrased anchors use server compose.
enum ExplanationSpeechPlan {
    struct Unit { let text: String; let marks: [QuickreadEvent] }
    static func normalized(_ text: String) -> String {
        String(String.UnicodeScalarView(text.lowercased().precomposedStringWithCanonicalMapping.unicodeScalars
            .filter { CharacterSet.alphanumerics.union(.nonBaseCharacters).contains($0) }))
    }
    static func units(text: String, marks: [QuickreadEvent]) -> [Unit]? {
        let sentences = ReadingSentenceContract.segments(text, lineBreakIsBoundary: true)
        guard sentences.count > 1 else { return nil }
        var texts: [String] = []
        var pending = ""
        for sentence in sentences {
            if !pending.isEmpty && pending.count + sentence.count > 120 {
                texts.append(pending); pending = ""
            }
            pending += sentence
            if pending.count >= 64 { texts.append(pending); pending = "" }
        }
        if !pending.isEmpty { texts.append(pending) }
        guard texts.count > 1, texts.allSatisfy({ $0.count <= 180 }) else { return nil }
        var assigned = Array(repeating: [QuickreadEvent](), count: texts.count)
        for mark in marks {
            let anchor = normalized(mark.text ?? "")
            guard anchor.count >= 2,
                  normalized(text).components(separatedBy: anchor).count == 2 else { return nil }
            let matching = texts.indices.filter { normalized(texts[$0]).contains(anchor) }
            guard matching.count == 1, let index = matching.first else { return nil }
            assigned[index].append(mark)
        }
        return texts.indices.map { Unit(text: texts[$0], marks: assigned[$0]) }
    }

    static func timedMarks(_ marks: [QuickreadEvent], segments: [AudioSegment], offset: Double) -> [QuickreadEvent]? {
        var narration = ""
        var times: [Double] = []
        var elapsed = offset
        for segment in segments {
            // Word timing when present; the established Explain-only character
            // timing fallback is confined to this short narration unit.
            if segment.timestamps.isEmpty {
                let text = normalized(segment.text)
                for (index, char) in text.enumerated() {
                    narration.append(char)
                    times.append(elapsed + segment.duration * Double(index) / Double(max(1, text.count)))
                }
            } else {
                for timestamp in segment.timestamps {
                    for char in normalized(timestamp.word) {
                        narration.append(char); times.append(elapsed + timestamp.startTime)
                    }
                }
            }
            elapsed += segment.duration
        }
        var result: [QuickreadEvent] = []
        for mark in marks {
            let anchor = normalized(mark.text ?? "")
            guard let range = narration.range(of: anchor) else { return nil }
            let index = narration.distance(from: narration.startIndex, to: range.lowerBound)
            guard times.indices.contains(index) else { return nil }
            var timed = mark; timed.at = times[index]; result.append(timed)
        }
        return result.sorted { ($0.at ?? 0) < ($1.at ?? 0) }
    }
}
