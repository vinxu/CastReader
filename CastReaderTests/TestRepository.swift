import Foundation

private final class TestRepositoryBundleMarker: NSObject {}

/// Source-contract assertions run on the phone against the exact build inputs.
/// The snapshot belongs only to the XCTest bundle, never the shipping app.
enum TestRepository {
    static var root: URL {
        let bundle = Bundle(for: TestRepositoryBundleMarker.self)
        let snapshot = bundle.bundleURL.appendingPathComponent("RepositorySnapshot")
        if FileManager.default.fileExists(atPath: snapshot.path) { return snapshot }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
