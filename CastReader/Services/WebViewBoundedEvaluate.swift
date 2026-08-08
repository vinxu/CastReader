//
//  WebViewBoundedEvaluate.swift
//  CastReader
//
//  有界的 WKWebView JavaScript 等待。
//
//  Android 现场结论（2026-08，Chromium 150 上被 MutationObserver 风暴卡死的渲染进程）：
//  evaluateJavaScript 的回调可以永远不回来。任何用 continuation 包住它的 async 等待都会
//  随之永久挂起——链路上没有一环拥有「这个页面还能不能用」这个问题，用户看到的就是
//  无声白屏。所以对 WebView 的 JS 等待一律有界：超时按错误抛出，调用方照常走既有的
//  错误路径，阅读器就绪问题由 ReaderReadinessWatchdog 给终局答案。
//
//  8 秒与 Android 端 evaluate() 的选择一致：正常调用毫秒级返回，只有渲染进程已经
//  不响应时才会走到超时。
//

import Foundation
import WebKit

/// JS 等待超时。区别于脚本自身抛错：超时意味着回调根本没有回来。
struct WebViewEvaluationTimeout: LocalizedError, Equatable {
    let seconds: TimeInterval

    var errorDescription: String? {
        AppLocalized("页面脚本长时间无响应。")
    }
}

enum WebViewBoundedWait {
    static let defaultTimeout: TimeInterval = 8

    /// 把「回调最多来一次、也可能永远不来」的操作包成有界的 async 调用。
    ///
    /// 回调与超时谁先到谁生效；晚到的另一方是无害的 no-op。checked continuation
    /// 只允许 resume 一次，`ResumeGate` 用锁保证这一点。
    static func run<T>(
        timeout: TimeInterval = defaultTimeout,
        operation: @escaping (_ finish: @escaping (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let gate = ResumeGate<T>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                gate.finish(.failure(WebViewEvaluationTimeout(seconds: timeout)))
            }
            operation { gate.finish($0) }
        }
    }
}

extension WKWebView {
    /// `evaluateJavaScript` 的有界版本。所有把它包进 async 的调用点一律走这里，
    /// 不再直接手写无超时的 continuation。
    @MainActor
    @discardableResult
    func evaluateJavaScriptBounded(
        _ script: String,
        timeout: TimeInterval = WebViewBoundedWait.defaultTimeout
    ) async throws -> Any {
        try await WebViewBoundedWait.run(timeout: timeout) { [weak self] finish in
            guard let self else {
                finish(.failure(WebViewEvaluationTimeout(seconds: 0)))
                return
            }
            self.evaluateJavaScript(script) { result, error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(result as Any))
                }
            }
        }
    }
}

/// 单次放行门闩：install 一次，finish 最多生效一次。
private final class ResumeGate<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finish(_ result: Result<T, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
