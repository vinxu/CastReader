#if DEBUG
import Foundation

/// The diagnostic run stays with the reader while its sheet is dismissed.
/// A lost event makes the run inconclusive even if a later snapshot looks good.
@MainActor
final class KindleOfflineProbeSession {
    private var runID: String?
    private var cursor: UInt64 = 0
    private var lostEvents = false
    private var evidence = KindlePageFlipProbe.RunEvidence()
    private var records: [KindlePageFlipProbe.PollResponse] = []

    func run(_ command: String, evaluate: (String) async throws -> Any) async throws -> String {
        if command == "start" {
            _ = try await evaluate(KindleWebScripts.pageFlipProbeBootstrap)
            if let runID { _ = try await evaluate("window.__crKindlePFProbeStop('\(runID)')") }
            runID = UUID().uuidString
            cursor = 0
            lostEvents = false
            evidence = KindlePageFlipProbe.RunEvidence()
            records.removeAll()
            let response = try decode(await evaluate("window.__crKindlePFProbeStart('\(runID!)')"))
            try accept(response)
        } else {
            guard let runID else { return "请先开始采样。" }
            // Each poll is capped by JavaScript. Drain the bounded ring before
            // stopping; the stop API itself always includes its first batch.
            for _ in 0..<20 {
                let response = try decode(await evaluate("window.__crKindlePFProbePoll('\(runID)', \(cursor), 100)"))
                try accept(response)
                if !response.hasMore { break }
            }
            if command == "stop" {
                let response = try decode(await evaluate("window.__crKindlePFProbeStop('\(runID)')"))
                guard response.ok, response.runID == runID else { throw Failure.invalidResponse }
                evidence.accept(response, afterSeq: cursor)
                records.append(response)
            }
        }
        // A long diagnostics session must also stay bounded on the native side.
        if records.count > 200 { records.removeFirst(records.count - 200); lostEvents = true }
        let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("KindleOfflineDiagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excludedRoot = root
        try excludedRoot.setResourceValues({ var value = URLResourceValues(); value.isExcludedFromBackup = true; return value }())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(Record(lostEvents: lostEvents, responses: records)).write(
            to: root.appendingPathComponent("page-flip-latest.json"), options: .atomic)
        guard let last = records.last else { return "没有采样。" }
        let verdict = lostEvents ? KindlePageFlipProbe.Verdict.inconclusive : evidence.verdict(for: last)
        let summary = last.snapshot?.summary
        return "run=\(last.runID)\nverdict=\(verdict)\nactive=\(last.active); seq=\(last.seq); lostEvents=\(lostEvents)\nordinals=\(summary?.ordinalCount ?? 0)/\(summary?.declaredTotal ?? 0); gaps=\(summary?.ordinalGapCount ?? 0)\npositionStable=\(last.snapshot?.reader.positionStable.map(String.init) ?? "unknown")"
    }

    private func decode(_ value: Any) throws -> KindlePageFlipProbe.PollResponse {
        let data: Data
        if let string = value as? String { data = Data(string.utf8) }
        else { data = try JSONSerialization.data(withJSONObject: value) }
        return try JSONDecoder().decode(KindlePageFlipProbe.PollResponse.self, from: data)
    }

    private func accept(_ response: KindlePageFlipProbe.PollResponse) throws {
        guard response.ok, response.version == KindlePageFlipProbe.evidenceVersion,
              response.runID == runID else { throw Failure.invalidResponse }
        lostEvents = lostEvents || response.overflowed(afterSeq: cursor)
        evidence.accept(response, afterSeq: cursor)
        cursor = max(cursor, response.events.last?.seq ?? cursor)
        records.append(response)
    }

    private struct Record: Codable {
        let lostEvents: Bool
        let responses: [KindlePageFlipProbe.PollResponse]
    }
    private enum Failure: Error { case invalidResponse }
}
#endif
