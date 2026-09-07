import XCTest
import UIKit
import WebKit
@testable import CastReader

/// Real WK messages enter the real model's sync resolver. Only the slow
/// document/readiness awaits are controlled; no Amazon, OCR or TTS is invoked.
@MainActor
final class KindleInitialStartSyncTests: XCTestCase {
    private enum FixtureError: Error { case reachedRestart, timedOut }

    @MainActor
    private final class Preparation {
        var calls = 0
        var pending: CheckedContinuation<ReadingDocument, Error>?
        func prepare() async throws -> ReadingDocument {
            calls += 1
            guard calls == 1 else { throw FixtureError.reachedRestart }
            return try await withCheckedThrowingContinuation { pending = $0 }
        }
        func finish() {
            pending?.resume(returning: ReadingDocument(
                title: "Local sync fixture", sourceKind: .kindle,
                language: "en", paragraphs: [ReadingParagraph(id: 0, text: "Local fixture.")]
            ))
            pending = nil
        }
    }

    func testInitialPlaySurvivesLateSyncAndOldPreparationCannotCommit() async throws {
        try await runScenario(cancellation: nil)
    }

    func testSettingsRevokesDeferredInitialPlay() async throws {
        try await runScenario(cancellation: "settings")
    }

    func testCallerCancellationAndDestroyEachRevokeDeferredInitialPlay() async throws {
        try await runScenario(cancellation: "caller")
        try await runScenario(cancellation: "destroy")
    }

    private func runScenario(cancellation: String?) async throws {
        AudioPlayerService.shared.stop()
        let previousKeyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow)
        let book = KindleBook(
            id: "start-sync-\(UUID().uuidString)", asin: "B000000001",
            title: "Local initial start fixture", author: "", coverURL: nil,
            readerURL: "https://read.amazon.com/sample/B000000001", progressLabel: "", storefrontID: "us",
            lastOpenedAt: nil, lastSyncedAt: Date(timeIntervalSince1970: 0),
            lastReadPageKey: nil, lastReadURL: nil
        )
        let model = KindleBookViewModel(book: book)
        model.webView.navigationDelegate = nil
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        model.webView.frame = window.bounds
        window.rootViewController!.view.addSubview(model.webView)
        let preparation = Preparation()
        model.startDocumentPreparationForTesting = { try await preparation.prepare() }
        model.syncDialogReadinessForTesting = {
            // Keep a real WebKit await in the readiness path as well.
            _ = try await model.webView.evaluateJavaScript("window.fixtureReady")
        }
        defer {
            preparation.finish()
            model.startDocumentPreparationForTesting = nil
            model.syncDialogReadinessForTesting = nil
            model.destroy()
            model.webView.removeFromSuperview()
            AudioPlayerService.shared.stop()
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }
        model.webView.loadHTMLString("""
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <button id="aa" aria-label="Reading settings" onclick="panel.hidden=!panel.hidden">Aa</button>
        <section id="panel" hidden><input aria-label="Font size" type="range" min="1" max="10" value="6"></section>
        <script>
          window.fixtureReady=true;
          window.__crKindleLiveClear=()=>JSON.stringify({ok:true});
          window.sendSync=visible=>webkit.messageHandlers.castReaderKindle.postMessage({
            type:'kindle-sync-dialog',visible,localLocation:1635,cloudLocation:1111
          });
          window.chooseNo=()=>webkit.messageHandlers.castReaderKindle.postMessage({
            type:'kindle-sync-dialog-choice',visible:true,choice:'no',localLocation:1635,cloudLocation:1111
          });
        </script>
        """, baseURL: URL(string: "https://read.amazon.com/sample/B000000001"))
        var loaded = false
        for _ in 0..<100 {
            loaded = (try? await model.webView.evaluateJavaScript("window.fixtureReady===true")) as? Bool == true
            if loaded && !model.webView.isLoading && !model.isNavigating { break }
            loaded = false
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard loaded else { throw FixtureError.timedOut }
        let controlsReady = await model.prepareReaderControls(reason: "initial-sync-fixture")
        XCTAssertTrue(controlsReady, "Use the real bootstrap before the settings cancellation scenario")
        let initialStart = Task { try await model.startCurrentMode() }
        defer { initialStart.cancel() }
        try await waitUntil { preparation.calls == 1 }
        NSLog("CRDBG SYNC_FIXTURE first preparation held scenario=%@", cancellation ?? "resume")
        XCTAssertNil(model.readVM, "The pending intent exists before OCR has created a Read VM")
        XCTAssertFalse(model.isPreparing, "Generic isPreparing is not used as evidence of a Play request")
        // A repeated Play coalesces without creating a second producer or Pause.
        let repeated = try await model.startCurrentMode()
        guard case .deferred = repeated else { return XCTFail("Repeated pending Play must coalesce") }
        XCTAssertEqual(preparation.calls, 1)
        NSLog("CRDBG SYNC_FIXTURE repeated start coalesced")
        // postMessage returns undefined. Return a supported primitive from the
        // evaluation rather than making the async WK result bridge marshal it.
        _ = try await model.webView.evaluateJavaScript("sendSync(true); true")
        try await waitUntil { model.isKindleSyncDialogVisible }
        NSLog("CRDBG SYNC_FIXTURE sync visible")
        if cancellation == "caller" { initialStart.cancel() }
        _ = try await model.webView.evaluateJavaScript("chooseNo();sendSync(false); true")
        try await waitUntil { !model.isKindleSyncDialogVisible }
        NSLog("CRDBG SYNC_FIXTURE sync hidden")
        if cancellation == "settings" {
            model.openReadingSettings()
            XCTAssertTrue(model.isReadingSettingsPresented)
        } else if cancellation == "destroy" {
            model.destroy()
        }
        preparation.finish()
        let oldOutcome = try await initialStart.value
        guard case .deferred = oldOutcome else { return XCTFail("The old capture must lose startup ownership") }
        if cancellation == nil {
            try await waitUntil { preparation.calls == 2 }
        } else {
            // Covers the resolver's 650 ms settle and a complete main/WK turn.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            XCTAssertEqual(preparation.calls, 1, "Cancelled intent must not start again: \(cancellation!)")
        }
        XCTAssertNil(model.readVM)
        XCTAssertFalse(AudioPlayerService.shared.isPlaying)
        XCTAssertEqual(preparation.calls, cancellation == nil ? 2 : 1)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate(), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        guard predicate() else { throw FixtureError.timedOut }
    }
}
