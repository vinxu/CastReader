import Foundation
import CryptoKit
import Darwin

/// Short, public audition files only. The actor keeps disk work off the UI
/// thread; network bytes are bounded while receiving, never accumulated whole.
actor VoiceSampleCache {
    static let shared = VoiceSampleCache()
    static let maximumSampleBytes = 12 * 1_024 * 1_024
    private let directory: URL
    private let sessions: [ServiceRoute: URLSession]
    private let maximumBytes: Int
    private let lifetime: TimeInterval

    init(directory: URL? = nil, session: URLSession? = nil,
         maximumBytes: Int = 32 * 1_024 * 1_024, lifetime: TimeInterval = 86_400) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceSamples-v1", isDirectory: true)
        self.maximumBytes = maximumBytes
        self.lifetime = lifetime
        sessions = Dictionary(uniqueKeysWithValues: ServiceRoute.allCases.map { route in
            (route, session ?? OwnedAPIURLSession.makeExplicitCredentialSession(
                route: route, requestTimeout: 15, resourceTimeout: 30))
        })
    }

    func file(for url: URL, route: ServiceRoute) async throws -> URL {
        try Task.checkCancellation()
        guard let routedURL = OwnedAPIRedirectPolicy.routedResponseURL(url, route: route),
              let session = sessions[route] else { throw URLError(.unsupportedURL) }
        let digest = SHA256.hash(data: Data(routedURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let ext = ["mp3", "wav", "m4a", "aac"].contains(routedURL.pathExtension.lowercased())
            ? routedURL.pathExtension.lowercased() : "mp3"
        let destination = directory.appendingPathComponent(digest).appendingPathExtension(ext)
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        if let values = try? destination.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           let size = values.fileSize, size > 0, size <= Self.maximumSampleBytes,
           let modified = values.contentModificationDate, Date().timeIntervalSince(modified) < lifetime {
            return destination
        }
        try? manager.removeItem(at: destination)
        let partial = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("partial")
        defer { try? manager.removeItem(at: partial) }
        let (bytes, response) = try await session.bytes(from: routedURL)
        // Explicit cancellation also stops rejected HTTP/size responses before
        // their bodies can continue transferring in the background.
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              response.expectedContentLength <= Self.maximumSampleBytes,
              let mime = response.mimeType?.lowercased(),
              mime.hasPrefix("audio/") || mime == "application/octet-stream" else {
            throw URLError(.badServerResponse)
        }
        guard manager.createFile(atPath: partial.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: partial)
        defer { try? output.close() }
        var buffer = Data()
        buffer.reserveCapacity(64 * 1_024)
        var total = 0
        for try await byte in bytes {
            total += 1
            guard total <= Self.maximumSampleBytes else { throw URLError(.dataLengthExceedsMaximum) }
            buffer.append(byte)
            if buffer.count == 64 * 1_024 {
                try Task.checkCancellation()
                try output.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        guard total > 0 else { throw URLError(.zeroByteResource) }
        if !buffer.isEmpty { try output.write(contentsOf: buffer) }
        try output.close()
        // A cancelled/replaced preview never installs an incomplete cache file.
        // Another request may already have completed the same immutable URL.
        if manager.fileExists(atPath: destination.path) { try? manager.removeItem(at: destination) }
        try manager.moveItem(at: partial, to: destination)
        trim(keeping: destination)
        return destination
    }

    private func trim(keeping current: URL) {
        let manager = FileManager.default
        let files = (try? manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        var entries: [(URL, Int, Date)] = []
        for file in files where file.pathExtension != "partial" {
            guard let value = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { continue }
            let date = value.contentModificationDate ?? .distantPast
            if file != current && Date().timeIntervalSince(date) >= lifetime {
                try? manager.removeItem(at: file)
            } else { entries.append((file, value.fileSize ?? 0, date)) }
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where entry.0 != current && total > maximumBytes {
            try? manager.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

#if DEBUG
/// Opt-in device acceptance evidence, including samples while the UI is stuck.
/// No account, content, or URL is logged. Stops 20 s after the last preview tap.
enum VoiceSampleDiagnostics {
    private static let queue = DispatchQueue(label: "voice.preview.diagnostics", qos: .utility)
    private static var timer: DispatchSourceTimer?
    private static var deadline = Date.distantPast
    private static var lastHeartbeat = Date()
    private static var lastCPU: Double = 0
    private static var lastSample = Date()

    static func start() {
        guard ProcessInfo.processInfo.arguments.contains("-CastReaderVoicePreviewDiagnostics") else { return }
        queue.async {
            deadline = Date().addingTimeInterval(20)
            guard timer == nil else { return }
            lastHeartbeat = Date()
            lastCPU = cpuSeconds()
            lastSample = Date()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + 1, repeating: 1)
            source.setEventHandler {
                guard Date() < deadline else { timer?.cancel(); timer = nil; return }
                let now = Date()
                let cpu = cpuSeconds()
                var info = task_vm_info_data_t()
                var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
                let result = withUnsafeMutablePointer(to: &info) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                    }
                }
                let line = String(format: "%.3f cpu=%.1f%% footprint=%.1fMiB mainLag=%.2fs\n",
                    now.timeIntervalSince1970, 100 * (cpu - lastCPU) / max(0.01, now.timeIntervalSince(lastSample)),
                    result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1,
                    max(0, now.timeIntervalSince(lastHeartbeat) - 1))
                lastSample = now; lastCPU = cpu
                let file = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("voice-preview-performance.log")
                if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
                if let output = try? FileHandle(forWritingTo: file) {
                    try? output.seekToEnd(); try? output.write(contentsOf: Data(line.utf8)); try? output.close()
                }
                DispatchQueue.main.async { queue.async { lastHeartbeat = Date() } }
            }
            timer = source
            source.resume()
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
#endif
