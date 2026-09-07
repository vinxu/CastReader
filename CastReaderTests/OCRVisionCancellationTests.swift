import UIKit
import Vision
import XCTest
@testable import CastReader

/// The real crash was a cancelled Vision callback followed by a throwing
/// `perform`, both resuming one continuation. Production now has no callback
/// continuation; these tests exercise its shared synchronous execution boundary
/// and both public OCR routes using actual Vision on the bundled PNG.
@MainActor
final class OCRVisionCancellationTests: XCTestCase {
    private enum FixtureError: Error, Equatable { case performFailed, gateTimedOut }

    func testSuccessfulPerformRunsOnceAndReturnsNormally() throws {
        let execution = VisionRequestExecution(request: VNRecognizeTextRequest())
        var executions = 0
        try execution.perform { executions += 1 }
        XCTAssertEqual(executions, 1)
    }

    func testPerformFailureHasOneThrowingOutcome() {
        let execution = VisionRequestExecution(request: VNRecognizeTextRequest())
        var executions = 0
        XCTAssertThrowsError(try execution.perform {
            executions += 1
            throw FixtureError.performFailed
        }) { XCTAssertEqual($0 as? FixtureError, .performFailed) }
        XCTAssertEqual(executions, 1)
    }

    func testCancellationBeforeEntryNeverStartsVision() async {
        let calls = LockedCount()
        let task = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let execution = VisionRequestExecution(request: VNRecognizeTextRequest())
            try await withTaskCancellationHandler {
                try execution.perform { calls.increment() }
            } onCancel: {
                execution.cancel()
            }
        }
        assertCancelled(await task.result)
        XCTAssertEqual(calls.value, 0)
    }

    func testCancellationDuringPerformWinsOverItsLaterError() async {
        await assertCancellationDuringPerform(throwsAtReturn: true)
    }

    func testCancellationDuringPerformDiscardsItsLaterSuccess() async {
        await assertCancellationDuringPerform(throwsAtReturn: false)
    }

    func testRealVisionOCRAndOrientationCancelThenFreshRecognitionSucceeds() async throws {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(
            bundle.url(forResource: "kindle-footnote-raised-reference", withExtension: "png") ??
                bundle.url(forResource: "kindle-footnote-raised-reference", withExtension: "png", subdirectory: "Fixtures")
        )
        let image = try XCTUnwrap(UIImage(contentsOfFile: url.path))
        // These use the actual public service, not an imitation of the old
        // continuation. A short delay permits the synchronous Vision pass to
        // start; pre-entry and in-operation cancellation are also deterministic
        // in the separate boundary tests above.
        for orientationProbe in [false, true, false] {
            let task = Task {
                if orientationProbe {
                    return try await OCRService.shared.recognizeImportedImage(
                        image: image, title: "Orientation cancellation", orientationSettled: false
                    )
                }
                return try await OCRService.shared.recognize(
                    image: image, languages: ["en-US"], title: "Page prefetch cancellation",
                    paragraphStrategy: KindleLivePageOCRContract.isolatedPageStrategy, languageHint: "en"
                )
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            task.cancel()
            assertCancelled(await task.result)
        }
        let recovered = try await OCRService.shared.recognize(
            image: image, languages: ["en-US"], title: "Fresh page after cancellation",
            paragraphStrategy: KindleLivePageOCRContract.isolatedPageStrategy, languageHint: "en"
        )
        XCTAssertFalse(recovered.isEmpty)
        for token in ["12", "1924", "1894"] {
            XCTAssertTrue(recovered.paragraphs.flatMap(\.words).contains {
                $0.text == token && $0.bboxSource == .visionTextRange
            }, "Fresh recognition must retain actual Vision token \(token)")
        }
    }

    private func assertCancellationDuringPerform(throwsAtReturn: Bool) async {
        let entered = expectation(description: "Production perform boundary entered")
        let release = DispatchSemaphore(value: 0)
        let calls = LockedCount()
        let task = Task.detached {
            let execution = VisionRequestExecution(request: VNRecognizeTextRequest())
            try await withTaskCancellationHandler {
                try execution.perform {
                    calls.increment()
                    entered.fulfill()
                    guard release.wait(timeout: .now() + 5) == .success else { throw FixtureError.gateTimedOut }
                    if throwsAtReturn { throw FixtureError.performFailed }
                }
            } onCancel: {
                execution.cancel()
            }
        }
        defer { task.cancel(); release.signal() }
        await fulfillment(of: [entered], timeout: 3)
        task.cancel()
        release.signal()
        assertCancelled(await task.result)
        XCTAssertEqual(calls.value, 1)
    }

    private func assertCancelled<Value>(_ result: Result<Value, Error>,
                                         file: StaticString = #filePath, line: UInt = #line) {
        switch result {
        case .success: XCTFail("Cancelled Vision work must not publish a result", file: file, line: line)
        case .failure(let error): XCTAssertTrue(error is CancellationError, "\(error)", file: file, line: line)
        }
    }

    private final class LockedCount: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    }
}
