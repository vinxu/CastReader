import SwiftUI
import ImageIO
import CryptoKit

/// Voice imagery uses its own bounded pipeline; large original community
/// portraits are never decoded at full resolution on the main actor.
private final class VoiceDecodedImage: @unchecked Sendable {
    let image: UIImage
    init(_ image: UIImage) { self.image = image }
}

private actor VoiceImagePermits {
    private var available = 4
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 }
        else { waiters.removeFirst().resume() }
    }
}

private actor VoiceImageStore {
    static let shared = VoiceImageStore()
    private let permits = VoiceImagePermits()
    private let cache = NSCache<NSString, UIImage>()
    private var pending: [String: Task<VoiceDecodedImage, Error>] = [:]
    private var failedUntil: [String: Date] = [:]
    init() {
        cache.countLimit = 100
        cache.totalCostLimit = 24 * 1024 * 1024
    }
    func image(url: URL, route: ServiceRoute, pixels: Int) async throws -> VoiceDecodedImage {
        let key = route.rawValue + "|" + String(pixels) + "|" + url.absoluteString
        if let cached = cache.object(forKey: key as NSString) { return VoiceDecodedImage(cached) }
        if let existing = pending[key] { return try await existing.value }
        if let until = failedUntil[key], until > Date() { throw URLError(.resourceUnavailable) }
        let gate = permits
        let task = Task.detached(priority: .utility) {
            await gate.acquire()
            do {
                let image = try await Self.load(url: url, route: route, pixels: pixels, key: key)
                await gate.release()
                return VoiceDecodedImage(image)
            } catch {
                await gate.release()
                throw error
            }
        }
        pending[key] = task
        defer { pending[key] = nil }
        do {
            let result = try await task.value
            let cost = result.image.cgImage.map { $0.bytesPerRow * $0.height } ?? pixels * pixels * 4
            cache.setObject(result.image, forKey: key as NSString, cost: cost)
            return result
        } catch {
            if failedUntil.count > 100 { failedUntil.removeAll() }
            failedUntil[key] = Date().addingTimeInterval(30)
            throw error
        }
    }

    private nonisolated static func load(url: URL, route: ServiceRoute, pixels: Int, key: String) async throws -> UIImage {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceThumbnails", isDirectory: true)
        let filename = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".jpg"
        let file = root.appendingPathComponent(filename)
        if let cached = try? Data(contentsOf: file), let image = decode(cached, pixels: pixels) { return image }
        try Task.checkCancellation()
        let (data, response) = try await OwnedAPIURLSession.data(from: url, route: route)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 12 * 1024 * 1024, let image = decode(data, pixels: pixels) else { throw URLError(.cannotDecodeContentData) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let thumbnail = image.jpegData(compressionQuality: 0.88) {
            try? thumbnail.write(to: file, options: .atomic)
        }
        return image
    }

    private nonisolated static func decode(_ data: Data, pixels: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels
              ] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct VoiceAssetImage<Placeholder: View>: View {
    let url: URL?
    let route: ServiceRoute
    var pixels = 192
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { placeholder() }
        }.task(id: route.rawValue + "|" + String(pixels) + "|" + (url?.absoluteString ?? "")) {
            image = nil
            guard let routed = url.flatMap({ OwnedAPIRedirectPolicy.routedResponseURL($0, route: route) }) else { return }
            do {
                let result = try await VoiceImageStore.shared.image(url: routed, route: route, pixels: pixels)
                try Task.checkCancellation()
                image = result.image
            } catch { /* Keep the local placeholder; failures are briefly cached. */ }
        }
    }
}
