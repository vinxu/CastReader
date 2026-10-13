import Foundation
import AVFoundation

@main struct AppleAudioClockProbe {
    static func main() async throws {
        let fixturePath = CommandLine.arguments[1]
        let outputPath = CommandLine.arguments[2]
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: fixturePath))) as! [[String: Any]]
        var results = [[String: Any]]()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for row in rows {
            let response = row["response"] as! [String: Any]
            let data = Data(base64Encoded: response["audio"] as! String)!
            let path = directory.appendingPathComponent("sample.mp3")
            try data.write(to: path)
            let audio = try AVAudioFile(forReading: path)
            let duration = Double(audio.length) / audio.processingFormat.sampleRate
            let expected = row["duration"] as! Double
            let asset = AVURLAsset(url: path)
            let assetDuration = try await asset.load(.duration).seconds
            let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length))!
            try audio.read(into: buffer)
            let decodedPath = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
                .appendingPathComponent("apple-decoded-\(row["id"] as! String).wav")
            let decoded = try AVAudioFile(forWriting: decodedPath, settings: audio.processingFormat.settings)
            try decoded.write(from: buffer)
            results.append(["id": row["id"]!, "duration": duration, "expected": expected,
                            "assetDuration": assetDuration, "decodedFrames": buffer.frameLength,
                            "errorSamples": (duration - expected) * audio.processingFormat.sampleRate])
        }
        let output = try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted, .sortedKeys])
        try output.write(to: URL(fileURLWithPath: outputPath))
        print("Apple AVAudioFile clock: \(results.count) samples")
    }
}
