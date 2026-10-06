import Foundation
import UIKit
import WebKit

private final class TestRepositoryBundleMarker: NSObject {}

/// Source-contract assertions run on the phone against the exact build inputs.
/// The snapshot belongs only to the XCTest bundle, never the shipping app.
enum TestRepository {
    @MainActor
    static func waitForWebFixture(_ web: WKWebView, token: String) async throws {
        let deadline = Date().addingTimeInterval(10)
        repeat {
            // Query the document itself: the first evaluation waits for WebKit's
            // process startup. isLoading alone can consume a short polling
            // budget before Catalyst's web process has committed the fixture.
            if (try? await web.evaluateJavaScript("window.fixtureToken==='\(token)'")) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(30))
        } while Date() < deadline
        throw NSError(domain: "CastReaderWebFixture", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Local WebKit fixture did not commit its expected document"
        ])
    }

    /// Catalyst WebKit fixtures need a scene-backed window to load and lay out.
    /// Keep the requested fixture viewport and the iOS harness unchanged.
    @MainActor
    static func makeWindow(frame: CGRect) -> UIWindow {
        #if targetEnvironment(macCatalyst)
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let window = UIWindow(windowScene: scene)
            window.frame = frame
            return window
        }
        #endif
        return UIWindow(frame: frame)
    }

    static var root: URL {
        let bundle = Bundle(for: TestRepositoryBundleMarker.self)
        let snapshot = bundle.bundleURL.appendingPathComponent("RepositorySnapshot")
        if FileManager.default.fileExists(atPath: snapshot.path) { return snapshot }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
