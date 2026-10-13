// Research executable only. Linked against iOS Simulator frameworks and the
// unchanged production classifier, normalization, and fastText bridge.
import Foundation
import NaturalLanguage
import Darwin

// Routing is unrelated to LID; these two symbols let the unchanged generated
// language enum compile without starting the application's services.
enum ServiceRoute { case chinaGateway, global }
enum ServiceRouting { static let current = ServiceRoute.global }

@main enum Probe {
    static func native(_ text: String) -> [String: Double] {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        var result: [String: Double] = [:]
        for (language, value) in recognizer.languageHypotheses(withMaximum: 8) {
            result[SupportedTTSLanguage.normalizedIdentifier(language.rawValue), default: 0] += value
        }
        return result
    }

    static func timed<T>(_ operation: () -> T) -> (T, Double) {
        let start = DispatchTime.now().uptimeNanoseconds
        let value = operation()
        return (value, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
    }

    static func memory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    static func output(_ evidence: LanguageDetector.Evidence) -> String {
        switch evidence.status {
        case .supported(let language): return language.rawValue
        case .unsupported(let code): return code
        case .uncertain: return ""
        }
    }

    static func main() throws {
        let args = CommandLine.arguments
        let mode = args[1]
        let model = args[4]
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: args[2]))) as! [[String: Any]]
        let before = memory()
        var afterFirst: UInt64 = 0
        var peak = before
        var results: [[String: Any]] = []
        for (index, row) in rows.enumerated() {
            try autoreleasepool {
                let text = String((row["text"] as! String).prefix(4000))
                let count = text.unicodeScalars.filter { $0.properties.isAlphabetic }.count
                var result: [String: Any] = ["key": row["key"]!, "count": count]
                if mode == "native" {
                    let (candidates, ms) = timed { native(text) }
                    result["candidates"] = candidates; result["ms"] = ms
                } else if mode == "fasttext" {
                    let (raw, ms) = timed {
                        NativeLanguageIdentifier.hypotheses(for: text, modelPath: model, count: 8).mapValues(\.doubleValue)
                    }
                    result["candidates"] = SupplementalLanguageIdentifier.normalized(raw)
                    result["raw"] = raw; result["ms"] = ms
                } else if mode == "production" {
                    let (evidence, ms) = timed { LanguageDetector.evidence(for: text) }
                    result["candidates"] = evidence.supplementalCandidates
                    result["native"] = evidence.nativeCandidates
                    result["embedded"] = evidence.embeddedTermCandidates
                    result["language"] = evidence.language
                    result["confidence"] = evidence.confidence
                    result["output"] = output(evidence); result["ms"] = ms
                    result["missingModelOutput"] = output(LanguageDetector.reconcile(
                        native: evidence.nativeCandidates, supplemental: [:], readableCharacterCount: count))
                } else { fatalError("Unknown probe mode") }
                results.append(result)
                if index == 0 { afterFirst = memory() }
                peak = max(peak, memory())
                if index % 2000 == 0 { fputs("\(mode): \(index)/\(rows.count)\n", stderr) }
            }
        }
        let report: [String: Any] = [
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "platform": "iOS Simulator arm64; not physical-device performance",
            "mode": mode, "model": model, "bundle": Bundle.main.bundlePath,
            "glotResource": Bundle.main.path(forResource: "glotlid-v3-q300k", ofType: "ftz", inDirectory: "LanguageIdentification") ?? "MISSING",
            "residentBefore": before, "residentAfterFirst": afterFirst, "residentPeakSampled": peak,
            "results": results
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(to: URL(fileURLWithPath: args[3]))
    }
}
