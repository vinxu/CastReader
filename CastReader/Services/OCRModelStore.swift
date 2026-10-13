import Foundation
import CryptoKit
import Darwin

/// Immutable model data shared by the app and its Safari extension. No account,
/// document text, or remote executable code crosses this boundary.
actor OCRModelStore {
    static let shared = OCRModelStore()
    typealias Download = @Sendable (URL, Int, URL) async throws -> URL

    enum Failure: Error { case unsupported, storageUnavailable, corrupt, unavailable, busy, invalidRange }
    private let root: URL?
    private let bundleRoot: URL?
    private let assets: [String: OCRModelAsset]
    private let download: Download
    private var pending: [String: Task<URL, Error>] = [:]
    private var retryAfter: [String: Date] = [:]
    private var verified: [URL: Date] = [:]

    private func verifiedFile(_ url: URL, asset: OCRModelAsset) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              values.fileSize == asset.bytes, let modified = values.contentModificationDate else { return false }
        if verified[url] == modified { return true }
        guard Self.valid(url, asset: asset) else { verified[url] = nil; return false }
        verified[url] = modified
        return true
    }

    init(root: URL? = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.same.castreader")?
            .appendingPathComponent("Library/Application Support/OCRModels/v1", isDirectory: true),
         bundleRoot: URL? = OCRModelStore.bundledRoot(),
         assets: [String: OCRModelAsset] = OCRModelCatalog.assets,
         download: @escaping Download = { try await OCRModelDownload.fetch($0, bytes: $1, destination: $2) }) {
        self.root = root
        self.bundleRoot = bundleRoot
        self.assets = assets
        self.download = download
    }

    nonisolated static func bundledRoot(bundle: Bundle = .main) -> URL? {
        // Store one copy inside the embedded extension. Both processes can read
        // signed resources; mutable downloads live exclusively in the App Group.
        if bundle.bundleURL.pathExtension == "appex" {
            return bundle.resourceURL?.appendingPathComponent("tesseract-wasm", isDirectory: true)
        }
        return bundle.builtInPlugInsURL?
            .appendingPathComponent("CastReader Safari Extension.appex/tesseract-wasm", isDirectory: true)
    }

    func cached(_ model: String) throws -> URL? {
        guard let asset = assets[model] else { throw Failure.unsupported }
        if let bundleRoot {
            let url = bundleRoot.appendingPathComponent(model + ".traineddata")
            if verifiedFile(url, asset: asset) { return url }
        }
        guard let root else { return nil }
        let url = Self.location(asset, root: root)
        return verifiedFile(url, asset: asset) ? url : nil
    }

    func allowUserRetry(_ model: String) { retryAfter[model] = nil }

    func prepare(_ model: String, retry: Bool = false) async throws -> URL {
        try Task.checkCancellation()
        if let local = try cached(model) { return local }
        guard let asset = assets[model] else { throw Failure.unsupported }
        if let task = pending[model] {
            do {
                let url = try await task.value
                try Task.checkCancellation()
                return url
            } catch {
                try Task.checkCancellation()
                throw error
            }
        }
        if !retry, let date = retryAfter[model], date > Date() { throw Failure.unavailable }
        guard let root else { throw Failure.storageUnavailable }
        let download = self.download
        // Shared work survives cancellation of one waiter. Callers still check
        // cancellation before using it; timeouts bound an abandoned download.
        let task = Task.detached(priority: .utility) {
            try await Self.acquire(asset, root: root, download: download)
        }
        pending[model] = task
        do {
            let url = try await task.value
            pending[model] = nil
            retryAfter[model] = nil
            try Task.checkCancellation()
            return url
        } catch {
            pending[model] = nil
            if !(error is CancellationError) { retryAfter[model] = Date().addingTimeInterval(15) }
            try Task.checkCancellation()
            throw error
        }
    }

    /// A bounded, allowlisted native-message response, never an arbitrary file read.
    func read(_ model: String, offset: Int, count: Int) throws -> [String: Any] {
        guard let asset = assets[model] else { throw Failure.unsupported }
        guard offset >= 0, count > 0, count <= 256 * 1024,
              offset < asset.bytes, count <= asset.bytes - offset else { throw Failure.invalidRange }
        guard let url = try cached(model) else { throw Failure.unavailable }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        guard let data = try handle.read(upToCount: count), data.count == count else { throw Failure.corrupt }
        return ["ok": true, "offset": offset, "data": data.base64EncodedString()]
    }

    private nonisolated static func location(_ asset: OCRModelAsset, root: URL) -> URL {
        root.appendingPathComponent(asset.id + "-" + asset.sha256 + ".traineddata")
    }

    nonisolated static func valid(_ url: URL, asset: OCRModelAsset) -> Bool {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size == asset.bytes, let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        // Stream even very large models; the native extension has a much lower
        // memory budget than its JavaScript OCR process.
        var hash = SHA256()
        var count = 0
        do {
            while let chunk = try file.read(upToCount: 256 * 1024), !chunk.isEmpty {
                count += chunk.count
                guard count <= asset.bytes else { return false }
                hash.update(data: chunk)
            }
        } catch { return false }
        return count == asset.bytes && hash.finalize().map { String(format: "%02x", $0) }.joined() == asset.sha256
    }

    private nonisolated static func acquire(_ asset: OCRModelAsset, root: URL,
                                            download: Download) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var directory = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        // flock is shared across the app/extension processes. A process killed
        // by iOS automatically releases it; no permanent "downloading" marker.
        let lock = open(root.appendingPathComponent(asset.id + ".lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw Failure.storageUnavailable }
        defer { flock(lock, LOCK_UN); close(lock) }
        let deadline = ProcessInfo.processInfo.systemUptime + 125
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw Failure.storageUnavailable }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure.busy }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        let destination = location(asset, root: root)
        if valid(destination, asset: asset) { return destination }
        // An interrupted/failed attempt can leave only a staging file. Never
        // evict ready models (including other languages) to make a download fit.
        for file in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix(asset.id + "-") && file.pathExtension == "partial" {
            try? fm.removeItem(at: file)
        }
        var lastError: Error = Failure.unavailable
        for source in asset.sources {
            try Task.checkCancellation()
            let staging = root.appendingPathComponent(asset.id + "-" + UUID().uuidString + ".partial")
            defer { try? fm.removeItem(at: staging) }
            do {
                let downloaded = try await download(source, asset.bytes, staging)
                guard downloaded == staging, valid(staging, asset: asset) else { throw Failure.corrupt }
                // rename is atomic on this volume. A partial file is never a
                // ready model, and a network failure cannot replace a good one.
                guard rename(staging.path, destination.path) == 0 else { throw Failure.storageUnavailable }
                return destination
            } catch is CancellationError { throw CancellationError() }
            catch { lastError = error }
        }
        throw lastError
    }
}

/// Disk-backed, size-bounded transport. Each origin gets 22.5–60 seconds,
/// scaled by model size, and 10 seconds without data. A second pinned origin
/// is the single automatic retry. No infinite background/page retry loop.
final class OCRModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let bytes: Int
    private let destination: URL
    private var completion: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var result: Result<URL, Error>?

    private init(bytes: Int, destination: URL) { self.bytes = bytes; self.destination = destination }

    static func fetch(_ url: URL, bytes: Int, destination: URL) async throws -> URL {
        let transfer = OCRModelDownload(bytes: bytes, destination: destination)
        return try await transfer.run(url)
    }

    private func run(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            completion = continuation
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = min(60, max(22.5, 10 + Double(bytes) / (1024 * 1024)))
            config.waitsForConnectivity = false
            config.urlCache = nil
            config.httpCookieStorage = nil
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
            self.session = session
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            session.downloadTask(with: request).resume()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil) // Only immutable, explicitly listed origins.
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > bytes || totalBytesExpectedToWrite > bytes { downloadTask.cancel() }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200,
                  try location.resourceValues(forKeys: [.fileSizeKey]).fileSize == bytes else {
                throw OCRModelStore.Failure.corrupt
            }
            try FileManager.default.moveItem(at: location, to: destination)
            result = .success(destination)
        } catch { result = .failure(error) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let outcome = error.map { Result<URL, Error>.failure($0) } ?? result ?? .failure(OCRModelStore.Failure.unavailable)
        completion?.resume(with: outcome)
        completion = nil
        session.finishTasksAndInvalidate()
        self.session = nil
    }
}
