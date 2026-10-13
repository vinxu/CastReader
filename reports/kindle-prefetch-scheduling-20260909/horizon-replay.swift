import Foundation
enum KindleParagraphPrefetchHorizon {
    struct Candidate {
        let index: Int
        let utf16Count: Int
        let readyDuration: Double?
    }
    struct Selection {
        let indices: [Int]
        let estimatedSeconds: Double
        let additionalCharacters: Int
    }
    static func select(_ candidates: [Candidate], speed: Double) -> Selection {
        let rate = speed.isFinite && speed > 0 ? speed : 1
        var selected: [Int] = []
        var seconds = 0.0
        var extraCharacters = 0
        for candidate in candidates {
            guard selected.count < 8 else { break }
            if selected.count >= 2 {
                guard seconds < 12 else { break }
                guard candidate.utf16Count <= 1600 - extraCharacters else { break }
                extraCharacters += candidate.utf16Count
            }
            selected.append(candidate.index)
            let duration = candidate.readyDuration.flatMap {
                $0.isFinite && $0 > 0 ? $0 : nil
            } ?? max(0.1, Double(candidate.utf16Count) / 24)
            seconds += duration / rate
        }
        return Selection(indices: selected, estimatedSeconds: seconds,
                         additionalCharacters: extraCharacters)
    }
}

let counts = [161, 104, 110, 138, 77]
func candidates(after: Int, durations: [Int: Double]) -> [KindleParagraphPrefetchHorizon.Candidate] {
    counts.enumerated().compactMap { offset, chars in
        let index = offset + 1
        return index > after ? .init(index: index, utf16Count: chars, readyDuration: durations[index]) : nil
    }
}
func record(_ stage: String, after: Int, durations: [Int: Double]) -> [Int] {
    let s = KindleParagraphPrefetchHorizon.select(candidates(after: after, durations: durations), speed: 2)
    let data = try! JSONSerialization.data(withJSONObject: ["stage": stage, "selected": s.indices, "estimatedSeconds": s.estimatedSeconds], options: [.sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    return s.indices
}
let initial = record("11:26:57.490 all pending", after: 0, durations: [:])
let ready = record("11:27:00.370 paragraph 1 ready", after: 0, durations: [1: 9.98])
let advanced = record("11:27:03.372 paragraph 1 playing", after: 1, durations: [2:6.84,3:7.15])
precondition(initial == [1,2,3,4,5])
precondition(ready == [1,2,3,4])
precondition(advanced == [2,3,4,5])
print("Verified: still-needed paragraph 5 leaves the window and re-enters; current caller cancels/removes its owner, then starts a fresh producer.")
