//
//  QuickReadService.swift
//  CastReader
//
//  解读后端客户端：extract-plan(SSE) → extract-block(JSON) → compose-block(JSON)。
//  base = Constants.API.quickReadBaseURL（quickread.castreader.ai:8444）。
//

import Foundation

enum QuickReadError: Error, LocalizedError {
    case invalidURL
    case httpError(Int)
    case serverError(String)
    case decodeError(String)
    case noBlock0

    var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "无效的解读服务地址")
        case .httpError(let c): return String(localized: "解读服务错误 (HTTP \(c))")
        case .serverError(let m): return String(localized: "解读失败：\(m)")
        case .decodeError(let m): return String(localized: "解读数据解析失败：\(m)")
        case .noBlock0: return String(localized: "解读未返回首块内容")
        }
    }
}

actor QuickReadService {
    static let shared = QuickReadService()
    private init() {}

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// 稳定设备 ID（复用 visitor id），用于 x-device-id。每次读取 UserDefaults，
    /// 让额度/测试可通过替换 visitor id 控制设备身份；生产环境读到的是稳定 id，行为不变。
    private static var deviceId: String {
        #if DEBUG
        // 开发期：每次请求用新 device id，规避后端按 device 的免费解读额度上限，方便反复测试。
        // block/compose 用 plan 返回的 jobId 关联，与 device id 无关，故不影响一次解读链路。生产不编译此分支。
        return UUID().uuidString
        #else
        let d = UserDefaults.standard
        if let id = d.string(forKey: Constants.Storage.visitorIdKey) { return id }
        let id = UUID().uuidString
        d.set(id, forKey: Constants.Storage.visitorIdKey)
        return id
        #endif
    }

    /// 解读后端鉴权 header（x-api-key + x-device-id，对齐扩展）。
    private func applyAuthHeaders(_ req: inout URLRequest) {
        if !Constants.API.quickReadAPIKey.isEmpty {
            req.setValue(Constants.API.quickReadAPIKey, forHTTPHeaderField: "x-api-key")
        }
        req.setValue(Self.deviceId, forHTTPHeaderField: "x-device-id")
    }

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 120
        return URLSession(configuration: cfg)
    }()

    // MARK: - 重试（网络波动 / 后端瞬时错误自愈，指数退避）

    /// 对网络层错误 / 5xx / 429 / 408 / 瞬时 400 / 流式截断自动重试（最多 3 次，0.6→1.2→2.4s 退避）。
    /// 让一次抖动不至于打断整条解读链路，用户无需手动 Retry。
    private func withRetry<T>(_ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            do { return try await operation() }
            catch {
                attempt += 1
                guard attempt < 3, Self.isRetryable(error) else { throw error }
                let backoff = min(4.0, 0.6 * pow(2.0, Double(attempt - 1)))
                try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            }
        }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if error is URLError { return true }                        // 网络层（超时 / 断连 / DNS）
        if case QuickReadError.httpError(let code) = error {
            return code >= 500 || code == 429 || code == 408 || code == 400   // 服务端临时 / 限流 / 网关瞬时
        }
        if case QuickReadError.decodeError = error { return true }   // 流式截断 / 部分响应
        if case QuickReadError.noBlock0 = error { return true }      // SSE 中途断、没拿到首块
        return false
    }

    // MARK: - extract-plan（SSE）

    /// 通读全文生成大纲 + 首块。onStage/onBlock0 在事件到达时回调；返回 done 载荷。
    @discardableResult
    func extractPlan(_ body: ExtractPlanRequest,
                     onStage: @escaping (String) -> Void,
                     onBlock0: @escaping (PlanBlock0) -> Void) async throws -> PlanDone {
        guard let url = URL(string: Constants.API.quickReadPlan) else { throw QuickReadError.invalidURL }
        let payload = try encoder.encode(body)
        // 重试整条 SSE（重连重建流）；onBlock0/onStage 在 ExplainViewModel 端幂等（box 覆盖 / 仅更新 UI 文字）。
        return try await withRetry {
            try await self.runExtractPlanOnce(url: url, payload: payload, onStage: onStage, onBlock0: onBlock0)
        }
    }

    private func runExtractPlanOnce(url: URL, payload: Data,
                                    onStage: @escaping (String) -> Void,
                                    onBlock0: @escaping (PlanBlock0) -> Void) async throws -> PlanDone {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuthHeaders(&req)
        req.httpBody = payload

        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QuickReadError.httpError(http.statusCode)
        }

        var eventName = ""
        var dataBuffer = ""
        var done: PlanDone?
        var gotBlock0 = false

        // 注意：URLSession.AsyncBytes.lines 会吞掉 SSE 事件间的空行，
        // 所以不能只靠空行判定边界——遇到下一个 `event:` 或空行就 flush 上一个事件。
        func flush() throws {
            defer { eventName = ""; dataBuffer = "" }
            try dispatch(event: eventName, data: dataBuffer,
                         onStage: onStage,
                         onBlock0: { gotBlock0 = true; onBlock0($0) },
                         onDone: { done = $0 })
        }

        for try await line in bytes.lines {
            if line.isEmpty { try flush(); continue }
            if line.hasPrefix(":") { continue }   // 注释行（如 ": stream-start"）
            if line.hasPrefix("event:") {
                if !eventName.isEmpty || !dataBuffer.isEmpty { try flush() }   // 上一个事件结束
                eventName = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("data:") {
                dataBuffer += String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        try flush()   // 末尾事件

        guard gotBlock0 else { throw QuickReadError.noBlock0 }
        return done ?? PlanDone(job_id: nil, total_blocks: nil, model_used: nil)
    }

    private func dispatch(event: String, data: String,
                          onStage: (String) -> Void,
                          onBlock0: (PlanBlock0) -> Void,
                          onDone: (PlanDone) -> Void) throws {
        guard !data.isEmpty else { return }
        let payload = Data(data.utf8)
        switch event {
        case "stage":
            if let obj = try? decoder.decode([String: String].self, from: payload), let s = obj["stage"] {
                onStage(s)
            }
        case "block0":
            do { onBlock0(try decoder.decode(PlanBlock0.self, from: payload)) }
            catch { throw QuickReadError.decodeError("block0: \(error)") }
        case "done":
            if let d = try? decoder.decode(PlanDone.self, from: payload) { onDone(d) }
        case "error":
            let msg = (try? decoder.decode([String: String].self, from: payload))?["message"] ?? "unknown"
            throw QuickReadError.serverError(msg)
        default:
            break   // 未知事件忽略
        }
    }

    // MARK: - extract-block / compose-block（JSON）

    func extractBlock(jobId: String, blockIdx: Int) async throws -> QuickreadSection {
        let body = ExtractBlockRequest(job_id: jobId, block_idx: blockIdx)
        return try await postSection(Constants.API.quickReadExtractBlock, body: body)
    }

    func composeBlock(jobId: String, blockIdx: Int,
                      timestamps: [ComposeTimestamp], duration: Double) async throws -> QuickreadSection {
        let body = ComposeBlockRequest(job_id: jobId, block_idx: blockIdx,
                                       timestamps: timestamps, duration: duration)
        return try await postSection(Constants.API.quickReadComposeBlock, body: body)
    }

    // MARK: - 快道（fast-block0）

    /// 快道：标题 + 开头 N 段 → 一次 LLM 直出 block_0{narration, marks}（marks 无 at），跳过读整篇 + compose。
    /// 失败即抛出、**不重试**（快道的意义是快；失败由竞速兜底——质道 block_0 自然顶上）。超时 8s。
    /// 返回精简 section（text=narration、events=过滤后的 marks）。
    func fastBlock0(title: String, openingParas: [String], lang: String?,
                    depth: String, prevSummary: String?, contentType: String?) async throws -> QuickreadSection {
        guard let url = URL(string: Constants.API.quickReadFastBlock0) else { throw QuickReadError.invalidURL }
        let body = FastBlock0Request(title: title,
                                     openingParas: openingParas.map { FastBlock0OpeningPara(text: $0) },
                                     lang: lang, depth: depth, prev_summary: prevSummary, content_type: contentType)
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(&req)
        req.httpBody = try encoder.encode(body)
        req.timeoutInterval = 8   // 快道超时即放弃，走质道

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QuickReadError.httpError(http.statusCode)
        }
        let resp = try decoder.decode(FastBlock0Response.self, from: data)
        guard let b0 = resp.block_0,
              !b0.narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw QuickReadError.noBlock0
        }
        // marks 精简形态 → QuickreadEvent：过滤 style 白名单 + 非空 text；at 留空（端侧均匀分布，见 ensureTiming）
        let allowed: Set<String> = ["circle", "underline", "highlight", "number"]
        let events = (b0.marks ?? [])
            .filter { allowed.contains($0.style) && !$0.text.isEmpty }
            .map { QuickreadEvent(at: nil, action: $0.style, text: $0.text, n: $0.n, role: nil, note: nil) }
        return QuickreadSection(id: "fast-0", text: b0.narration, style: "explain",
                                cinematic: QuickreadCinematic(events: events))
    }

    private func postSection<Body: Encodable>(_ urlString: String, body: Body) async throws -> QuickreadSection {
        guard let url = URL(string: urlString) else { throw QuickReadError.invalidURL }
        let payload = try encoder.encode(body)
        return try await withRetry {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            self.applyAuthHeaders(&req)
            req.httpBody = payload
            let (data, response) = try await self.session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw QuickReadError.httpError(http.statusCode)
            }
            do {
                return try self.decoder.decode(QuickreadSectionResponse.self, from: data).section
            } catch {
                throw QuickReadError.decodeError("\(error)")
            }
        }
    }
}
