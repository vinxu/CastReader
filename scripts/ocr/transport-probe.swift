// Compiled with the production catalog/store by test-transport.py (macOS).
import Foundation
import CryptoKit

@main struct Probe {
    static func main() async throws {
        let base = CommandLine.arguments[1]
        let data = Data((0..<1024).map { UInt8($0 % 251) })
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["timeout", "corrupt", "oversize", "redirect", "short", "unavailable"] {
            let asset = OCRModelAsset(id: path, bytes: data.count, sha256: hash,
                                      sources: [URL(string: base + "/" + path)!, URL(string: base + "/good")!])
            let store = OCRModelStore(root: root, bundleRoot: nil, assets: [path: asset])
            let start = Date()
            let url = try await store.prepare(path)
            guard try Data(contentsOf: url) == data else { fatalError("Unverified data escaped") }
            print("PASS \(path) -> mirror: \(String(format: "%.2f", Date().timeIntervalSince(start)))s")
        }
        let model = OCRModelAsset(id: "both-fail", bytes: data.count, sha256: hash,
                                  sources: [URL(string: base + "/unavailable")!, URL(string: base + "/corrupt")!])
        let store = OCRModelStore(root: root, bundleRoot: nil, assets: [model.id: model])
        do { _ = try await store.prepare(model.id); fatalError("Both failures must not be accepted") } catch { }
        guard try await store.cached(model.id) == nil else { fatalError("Failure published a model") }
        print("PASS both origins fail -> no ready model")
    }
}
