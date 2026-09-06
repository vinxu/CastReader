import Foundation
import AVFoundation

// Offline macOS AVFoundation probe. Never starts playback or sends requests.
// Generated silence is a container test fixture, not synthesized speech.
func little<T: FixedWidthInteger>(_ value: T) -> Data {
    var raw = value.littleEndian
    return withUnsafeBytes(of: &raw) { Data($0) }
}
func silenceWAV() -> Data {
    let samples: UInt32 = 800
    let byteCount = samples * 2
    var d = Data("RIFF".utf8)
    d += little(UInt32(36) + byteCount)
    d += Data("WAVEfmt ".utf8)
    d += little(UInt32(16))
    d += little(UInt16(1)); d += little(UInt16(1))
    d += little(UInt32(8000)); d += little(UInt32(16000))
    d += little(UInt16(2)); d += little(UInt16(16))
    d += Data("data".utf8); d += little(byteCount)
    d += Data(repeating: 0, count: Int(byteCount))
    return d
}
func chain(_ error: Error?) -> String {
    guard let e = error as NSError? else { return "none" }
    let underlying = e.userInfo[NSUnderlyingErrorKey] as? Error
    return "\(e.domain):\(e.code):\(e.localizedDescription)" + (underlying == nil ? "" : " <- " + chain(underlying))
}
print("OS=\(ProcessInfo.processInfo.operatingSystemVersionString)")
let inputs: [(String, String)] = [
    ("empty", ""),
    ("base64_junk", Data("not audio".utf8).base64EncodedString()),
    ("base64_json", Data("{\"error\":\"fixture\"}".utf8).base64EncodedString()),
    ("url_literal", "https://example.invalid/audio.mp3"),
    ("data_url", "data:audio/mp3;base64,aGVsbG8="),
    ("invalid_base64", "%%%"),
    ("base64_with_linebreak", "aGVs\nbG8=")
]
for (label, text) in inputs {
    let bytes = Data(base64Encoded: text)
    print("BASE64 \(label) baselinePass=\(bytes != nil) newPresetPass=\(bytes.map { !$0.isEmpty } ?? false) bytes=\(bytes?.count ?? -1)")
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
let cases: [(String, Data?)] = [
    ("empty.mp3", Data()),
    ("junk.mp3", Data("not audio".utf8)),
    ("json.mp3", Data("{\"error\":\"fixture\"}".utf8)),
    ("valid-silence.wav", silenceWAV()),
    ("valid-silence-named.mp3", silenceWAV()),
    ("missing.mp3", nil)
]
var items: [(String, AVPlayerItem, AVPlayer)] = []
for (name, data) in cases {
    let url = directory.appendingPathComponent(name)
    if let data {
        try data.write(to: url)
        let duration = (try? AVAudioPlayer(data: data))?.duration ?? 0
        print("DURATION \(name) bytes=\(data.count) ensureDurationFallback=\(duration)")
    }
    let item = AVPlayerItem(asset: AVURLAsset(url: url))
    item.audioTimePitchAlgorithm = .timeDomain
    items.append((name, item, AVPlayer(playerItem: item)))
}
let deadline = Date().addingTimeInterval(10)
while Date() < deadline && items.contains(where: { $0.1.status == .unknown }) {
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
}
for (name, item, player) in items {
    print("ITEM \(name) status=\(item.status.rawValue) error=\(chain(item.error)) playbackRate=\(player.rate)")
}
