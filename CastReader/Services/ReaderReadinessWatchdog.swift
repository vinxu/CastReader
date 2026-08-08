//
//  ReaderReadinessWatchdog.swift
//  CastReader
//
//  商业阅读器首个可见页面的截止期/身份状态机。纯逻辑、无副作用，从 Android 的
//  reader/ReaderReadinessWatchdog.kt 移植（commit fe24532）。
//
//  它存在的原因：Kindle 阅读器的准备管线是一串等待，此前没有任何一环拥有
//  「这个阅读器到底有没有变得可用」这个问题——一个永不回来的 WebView 回调就能
//  把整条链无声卡死（白屏、无错误码、无诊断）。这个类型就是那个所有者：阅读器
//  文档提交时武装它，它保证结局要么是 REFRESH 重试后就绪，要么是调用方必须呈现
//  给用户的终态 TIMEOUT。
//
//  主文档、选中的书、命令会话权威共同构成身份。对同一身份重复 arm 永远不会
//  延长截止期；新身份使旧文档遗留的一切延迟动作作废。
//

import Foundation

struct ReaderReadinessWatchdog {

    struct Identity: Equatable {
        let readerDocumentEpoch: UInt64
        let bookID: String
        let commandSessionEpoch: UInt64
    }

    struct Ticket: Equatable {
        let identity: Identity
        let generation: UInt64
        let armedAtElapsedMs: Int64
        let deadlineElapsedMs: Int64
    }

    enum Action {
        case wait
        case refresh
        case timeout
        case stale
    }

    let timeoutMs: Int64
    let refreshIntervalMs: Int64

    private var active: Ticket?
    private var lastRefreshAtElapsedMs: Int64?
    private var nextGeneration: UInt64 = 0

    init(timeoutMs: Int64, refreshIntervalMs: Int64) {
        precondition(timeoutMs > 0)
        precondition(refreshIntervalMs >= 1 && refreshIntervalMs <= timeoutMs)
        self.timeoutMs = timeoutMs
        self.refreshIntervalMs = refreshIntervalMs
    }

    mutating func arm(_ identity: Identity, nowElapsedMs: Int64) -> Ticket {
        if let active, active.identity == identity { return active }
        nextGeneration = nextGeneration == .max ? 1 : nextGeneration + 1
        let ticket = Ticket(
            identity: identity,
            generation: nextGeneration,
            armedAtElapsedMs: nowElapsedMs,
            deadlineElapsedMs: Self.saturatingAdd(nowElapsedMs, timeoutMs)
        )
        active = ticket
        lastRefreshAtElapsedMs = nil
        return ticket
    }

    /// 只有当阅读器主体当前可以接收定向命令时才会给出 REFRESH。
    /// 在没有可用主体的情况下等待，永远不消耗也不推迟刷新资格。
    mutating func action(
        _ ticket: Ticket,
        nowElapsedMs: Int64,
        hasReadyFrame: Bool
    ) -> Action {
        guard active == ticket else { return .stale }
        if nowElapsedMs >= ticket.deadlineElapsedMs {
            return .timeout
        }
        guard hasReadyFrame else { return .wait }
        if lastRefreshAtElapsedMs == nil ||
            nowElapsedMs >= Self.saturatingAdd(lastRefreshAtElapsedMs ?? 0, refreshIntervalMs) {
            lastRefreshAtElapsedMs = nowElapsedMs
            return .refresh
        }
        return .wait
    }

    mutating func cancel(_ ticket: Ticket? = nil) {
        if ticket == nil || active == ticket { active = nil }
    }

    func isActive(_ ticket: Ticket) -> Bool {
        active == ticket
    }

    private static func saturatingAdd(_ left: Int64, _ right: Int64) -> Int64 {
        left > .max - right ? .max : left + right
    }
}
