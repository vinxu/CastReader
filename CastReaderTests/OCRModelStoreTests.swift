import XCTest
import CryptoKit
@testable import CastReader

final class OCRModelStoreTests: XCTestCase {
    private actor Recorder {
        var urls: [URL] = []
        func record(_ url: URL) { urls.append(url) }
        var count: Int { urls.count }
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func asset(_ data: Data, id: String = "test") -> OCRModelAsset {
        OCRModelAsset(id: id, bytes: data.count,
                      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                      sources: [URL(string: "https://primary.invalid/\(id)")!, URL(string: "https://mirror.invalid/\(id)")!])
    }

    func testCriticalLanguagesAndEnglishAreUsableWithoutStorageOrNetwork() async throws {
        let store = OCRModelStore(root: nil, download: { _, _, _ in
            XCTFail("Bundled first use must not access the network")
            throw URLError(.notConnectedToInternet)
        })
        for model in OCRModelCatalog.bundled {
            let url = try await store.prepare(model)
            XCTAssertTrue(url.path.contains(".appex/tesseract-wasm/"))
            XCTAssertTrue(OCRModelStore.valid(url, asset: OCRModelCatalog.assets[model]!))
        }
        let copies = FileManager.default.enumerator(at: Bundle.main.bundleURL, includingPropertiesForKeys: nil)!
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "traineddata" }
        XCTAssertEqual(copies.count, OCRModelCatalog.bundled.count, "Only one copy of each retained model")
    }

    func testTimeoutSwitchesOriginThenRestartWorksOffline() async throws {
        let data = Data(repeating: 17, count: 500_000), root = try directory(), calls = Recorder()
        let model = asset(data)
        let store = OCRModelStore(root: root, bundleRoot: nil, assets: [model.id: model]) { url, _, target in
            await calls.record(url)
            if url.host == "primary.invalid" { throw URLError(.timedOut) }
            try data.write(to: target); return target
        }
        let url = try await store.prepare(model.id)
        XCTAssertEqual(try Data(contentsOf: url), data)
        let count = await calls.count; XCTAssertEqual(count, 2)
        XCTAssertTrue(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        let offline = OCRModelStore(root: root, bundleRoot: nil, assets: [model.id: model]) { _, _, _ in
            XCTFail("Verified download must survive process recreation offline")
            throw URLError(.notConnectedToInternet)
        }
        let same = try await offline.prepare(model.id); XCTAssertEqual(url, same)
    }

    func testPartialCorruptAndOversizeDownloadsNeverBecomeReady() async throws {
        let good = Data(repeating: 42, count: 128), model = asset(Data(repeating: 42, count: 128))
        for bad in [Data(good.prefix(20)), Data(repeating: 0, count: good.count), good + Data([0])] {
            let root = try directory()
            let store = OCRModelStore(root: root, bundleRoot: nil, assets: [model.id: model]) { _, _, target in
                try bad.write(to: target); return target
            }
            do { _ = try await store.prepare(model.id); XCTFail("Bad bytes accepted") } catch { }
            let cached = try await store.cached(model.id); XCTAssertNil(cached)
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
        }
    }

    func testInterruptedDownloadCanRetryAndDoesNotRemovePreviousVersion() async throws {
        let old = Data("previous".utf8), next = Data("next-version".utf8), root = try directory()
        let first = asset(old), second = asset(next)
        let store = OCRModelStore(root: root, bundleRoot: nil, assets: [first.id: first]) { _, _, target in
            try old.write(to: target); return target
        }
        let oldURL = try await store.prepare(first.id)
        let failed = OCRModelStore(root: root, bundleRoot: nil, assets: [second.id: second]) { _, _, target in
            try next.prefix(2).write(to: target); throw URLError(.networkConnectionLost)
        }
        do { _ = try await failed.prepare(second.id); XCTFail() } catch { }
        XCTAssertTrue(OCRModelStore.valid(oldURL, asset: first))
        let retry = OCRModelStore(root: root, bundleRoot: nil, assets: [second.id: second]) { _, _, target in
            try next.write(to: target); return target
        }
        let newURL = try await retry.prepare(second.id)
        XCTAssertTrue(OCRModelStore.valid(newURL, asset: second))
        XCTAssertNotEqual(newURL, oldURL)
    }

    func testCorruptCacheIsRepairedAndAbandonedPartialDoesNotCountAsReady() async throws {
        let data = Data("correct-model".utf8), root = try directory(), model = asset(Data("correct-model".utf8))
        let url = root.appendingPathComponent("test-\(model.sha256).traineddata")
        try Data(repeating: 0, count: data.count).write(to: url)
        try data.write(to: root.appendingPathComponent("test-abandoned.partial"))
        let store = OCRModelStore(root: root, bundleRoot: nil, assets: [model.id: model]) { _, _, target in
            try data.write(to: target); return target
        }
        let invalid = try await store.cached(model.id); XCTAssertNil(invalid)
        let repaired = try await store.prepare(model.id)
        XCTAssertEqual(try Data(contentsOf: repaired), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("test-abandoned.partial").path))
    }

    func testAppAndExtensionStoresDeduplicateConcurrentRequests() async throws {
        let data = Data("shared-model".utf8), model = asset(Data("shared-model".utf8)), root = try directory(), calls = Recorder()
        let transport: OCRModelStore.Download = { url, _, target in
            await calls.record(url)
            try await Task.sleep(nanoseconds: 200_000_000)
            try data.write(to: target); return target
        }
        let app = OCRModelStore(root: root, bundleRoot: nil, assets: [model.id: model], download: transport)
        let ext = OCRModelStore(root: root, bundleRoot: nil, assets: [model.id: model], download: transport)
        try await withThrowingTaskGroup(of: URL.self) { group in
            for i in 0..<16 { group.addTask { try await (i % 2 == 0 ? app : ext).prepare(model.id) } }
            var urls = Set<URL>(); for try await url in group { urls.insert(url) }
            XCTAssertEqual(urls.count, 1)
        }
        let count = await calls.count; XCTAssertEqual(count, 1)
    }

    func testCancelledWaiterDoesNotCancelOtherWaiterOrPublishSuccess() async throws {
        let data = Data("model".utf8), model = asset(Data("model".utf8)), calls = Recorder()
        let store = OCRModelStore(root: try directory(), bundleRoot: nil, assets: [model.id: model]) { url, _, target in
            await calls.record(url)
            try await Task.sleep(nanoseconds: 200_000_000)
            try data.write(to: target); return target
        }
        let cancelled = Task { try await store.prepare(model.id) }
        try await Task.sleep(nanoseconds: 20_000_000)
        cancelled.cancel()
        let url = try await store.prepare(model.id)
        XCTAssertTrue(OCRModelStore.valid(url, asset: model))
        switch await cancelled.result {
        case .success: XCTFail("Cancelled waiter published a model")
        case .failure(let error): XCTAssertTrue(error is CancellationError)
        }
        let count = await calls.count; XCTAssertEqual(count, 1)
    }

    func testCancellationWinsOverLateDownloadFailure() async throws {
        let model = asset(Data("model".utf8))
        let store = OCRModelStore(root: try directory(), bundleRoot: nil, assets: [model.id: model]) { _, _, _ in
            try await Task.sleep(nanoseconds: 100_000_000)
            throw URLError(.timedOut)
        }
        let owner = Task { try await store.prepare(model.id) }
        try await Task.sleep(nanoseconds: 20_000_000)
        let waiter = Task { try await store.prepare(model.id) }
        owner.cancel()
        waiter.cancel()
        for result in [await owner.result, await waiter.result] {
            switch result {
            case .success: XCTFail("Cancelled request returned a model")
            case .failure(let error): XCTAssertTrue(error is CancellationError, "Late failure: \(error)")
            }
        }
    }

    func testFailureCooldownPreventsEveryPageFromRepeatingDownloadsAndManualRetryWorks() async throws {
        let model = asset(Data("test".utf8)), calls = Recorder()
        let store = OCRModelStore(root: try directory(), bundleRoot: nil, assets: [model.id: model]) { url, _, _ in
            await calls.record(url); throw URLError(.notConnectedToInternet)
        }
        for _ in 0..<4 { do { _ = try await store.prepare(model.id); XCTFail() } catch { } }
        let first = await calls.count; XCTAssertEqual(first, 2)
        do { _ = try await store.prepare(model.id, retry: true); XCTFail() } catch { }
        let retried = await calls.count; XCTAssertEqual(retried, 4)
    }

    func testDiskFailureAndUnknownModelDoNotStartNetwork() async throws {
        let root = try directory().appendingPathComponent("file"), model = asset(Data("test".utf8))
        try Data([1]).write(to: root)
        let store = OCRModelStore(root: root, bundleRoot: nil, assets: [model.id: model]) { _, _, _ in
            XCTFail("Invalid request/storage must not download"); throw URLError(.badURL)
        }
        for id in ["../Secrets", model.id] { do { _ = try await store.prepare(id); XCTFail() } catch { } }
    }

    func testNativeChunksAreBoundedAndReconstructExactVerifiedFile() async throws {
        let data = Data((0..<600_000).map { UInt8($0 % 251) }), root = try directory()
        let model = asset(data)
        let store = OCRModelStore(root: root, bundleRoot: nil, assets: [model.id: model]) { _, _, target in
            try data.write(to: target); return target
        }
        _ = try await store.prepare(model.id)
        var reconstructed = Data()
        for offset in stride(from: 0, to: data.count, by: 256 * 1024) {
            let response = try await store.read(model.id, offset: offset, count: min(256 * 1024, data.count - offset))
            reconstructed.append(try XCTUnwrap(Data(base64Encoded: response["data"] as! String)))
        }
        XCTAssertEqual(reconstructed, data)
        for (offset, count) in [(-1, 1), (0, 0), (0, 262145), (data.count, 1), (Int.max, 1)] {
            do { _ = try await store.read(model.id, offset: offset, count: count); XCTFail() } catch { }
        }
    }
}
