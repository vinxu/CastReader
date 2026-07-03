//
//  QuickReadService.swift
//  CastReader
//
//  解读后端客户端：extract-plan(SSE) → extract-block(JSON) → compose-block(JSON)。
//  base = QuickReadEndpoint.base()（COS 远程配置优先，本地兜底 qr.castreader.ai —— 换后端零发版）。
//

import Foundation

/// 解读后端地址 —— 远程配置(COS quickread-config.json)优先，否则本地兜底。
/// 对齐 TTSEndpoint 的远程配置模式 + 浏览器扩展 loadRemoteConfig。
/// 价值：换后端 / 容灾零发版 —— 改云端 JSON，客户端下次启动即生效（这次旧机被弃用，扩展靠它零改动切换，
/// iOS 因写死地址被迫发版；补上这个机制后，这是最后一次为换后端而发版）。
enum QuickReadEndpoint {
    /// 本地兜底：新东京干净节点。远程配置可覆盖。**绝不再用旧的 quickread.castreader.ai:8444**。
    static let defaultBase = "https://qr.castreader.ai"
    static let remoteConfigURL = "https://castreader-config-1323065328.cos.accelerate.myqcloud.com/quickread-config.json"
    private static let cacheKey = "quickread_base_v1"

    /// 当前 base：远程配置缓存优先，否则兜底。
    static func base() -> String {
        if let s = UserDefaults.standard.string(forKey: cacheKey), s.hasPrefix("http") { return s }
        return defaultBase
    }

    static var planURL: String         { "\(base())/api/quickread/extract-plan" }   // SSE
    static var extractBlockURL: String { "\(base())/api/quickread/extract-block" }  // JSON
    static var composeBlockURL: String { "\(base())/api/quickread/compose-block" }  // JSON
    static var fastBlock0URL: String   { "\(base())/api/quickread/fast-block0" }    // JSON 快道

    /// 启动时拉一次远程配置（非阻塞；4s 超时；失败保留缓存/兜底）。每次启动刷新 → 换后端隔次启动即生效。
    static func refreshRemoteConfig() async {
        guard let url = URL(string: remoteConfigURL) else { return }
        do {
            var req = URLRequest(url: url)
            req.timeoutInterval = 4
            let (data, _) = try await URLSession.shared.data(for: req)
            if let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let b = obj["base"] as? String, b.hasPrefix("http") {
                UserDefaults.standard.set(b, forKey: cacheKey)
            }
        } catch {
            // 保留缓存 / 兜底
        }
    }
}

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

    private func debugLog(_ message: String) {
        #if DEBUG
        print("[QuickRead] \(message)")
        #endif
    }

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

    private struct AuthHeaderIdentity {
        let userId: String?
        let email: String?
    }

    private func authHeaderIdentity() async -> AuthHeaderIdentity {
        await MainActor.run {
            let email = (AuthService.shared.account?.email ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AuthHeaderIdentity(
                userId: AuthService.shared.proUserId,
                email: email.isEmpty ? nil : email.lowercased()
            )
        }
    }

    /// 解读后端鉴权 header。device 兜底；登录后附带 user/email，保证 Pro gate 与 /api/pro/status 同口径。
    private func applyAuthHeaders(_ req: inout URLRequest, identity: AuthHeaderIdentity) {
        if !Constants.API.quickReadAPIKey.isEmpty {
            req.setValue(Constants.API.quickReadAPIKey, forHTTPHeaderField: "x-api-key")
        }
        req.setValue(Self.deviceId, forHTTPHeaderField: "x-device-id")
        if let userId = identity.userId, !userId.isEmpty {
            req.setValue(userId, forHTTPHeaderField: "x-user-id")
        }
        if let email = identity.email, !email.isEmpty {
            req.setValue(email, forHTTPHeaderField: "x-user-email")
        }
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
        guard let url = URL(string: QuickReadEndpoint.planURL) else { throw QuickReadError.invalidURL }
        let payload = try encoder.encode(body)
        debugLog("extract-plan START base=\(QuickReadEndpoint.base()) source=\(body.source_url) scenario=\(body.content_type ?? "general") depth=\(body.depth) lang=\(body.lang ?? "auto") paras=\(body.paragraphs.count) chars=\(body.text.count) bytes=\(payload.count)")
        // 重试整条 SSE（重连重建流）；onBlock0/onStage 在 ExplainViewModel 端幂等（box 覆盖 / 仅更新 UI 文字）。
        let startedAt = Date()
        do {
            let done = try await withRetry {
                try await self.runExtractPlanOnce(url: url, payload: payload, onStage: onStage, onBlock0: onBlock0)
            }
            debugLog("extract-plan DONE job=\(done.job_id ?? "nil") total=\(done.total_blocks.map(String.init) ?? "nil") model=\(done.model_used ?? "nil") elapsed=\(Self.elapsed(startedAt))")
            return done
        } catch {
            debugLog("extract-plan FAIL elapsed=\(Self.elapsed(startedAt)) error=\(error.localizedDescription)")
            throw error
        }
    }

    private func runExtractPlanOnce(url: URL, payload: Data,
                                    onStage: @escaping (String) -> Void,
                                    onBlock0: @escaping (PlanBlock0) -> Void) async throws -> PlanDone {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let identity = await authHeaderIdentity()
        applyAuthHeaders(&req, identity: identity)
        req.httpBody = payload

        let startedAt = Date()
        let (bytes, response) = try await session.bytes(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            debugLog("extract-plan HTTP \(http.statusCode) elapsed=\(Self.elapsed(startedAt))")
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
        return done ?? PlanDone(job_id: nil, total_blocks: nil, model_used: nil, page_summary: nil)
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
                debugLog("SSE stage=\(s)")
                onStage(s)
            }
        case "block0":
            do {
                let block = try decoder.decode(PlanBlock0.self, from: payload)
                debugLog("SSE block0 job=\(block.job_id) total_hint=\(block.total_blocks) marks=\(block.block_0.events.count) text=\(block.block_0.text.count)")
                onBlock0(block)
            }
            catch { throw QuickReadError.decodeError("block0: \(error)") }
        case "done":
            if let d = try? decoder.decode(PlanDone.self, from: payload) {
                debugLog("SSE done job=\(d.job_id ?? "nil") total=\(d.total_blocks.map(String.init) ?? "nil") model=\(d.model_used ?? "nil")")
                onDone(d)
            }
        case "error":
            let msg = (try? decoder.decode([String: String].self, from: payload))?["message"] ?? "unknown"
            debugLog("SSE error=\(msg)")
            throw QuickReadError.serverError(msg)
        default:
            break   // 未知事件忽略
        }
    }

    // MARK: - extract-block / compose-block（JSON）

    func extractBlock(jobId: String, blockIdx: Int) async throws -> QuickreadSection {
        let body = ExtractBlockRequest(job_id: jobId, block_idx: blockIdx)
        return try await postSection(QuickReadEndpoint.extractBlockURL, body: body, label: "extract-block[\(blockIdx)]")
    }

    func composeBlock(jobId: String, blockIdx: Int,
                      timestamps: [ComposeTimestamp], duration: Double) async throws -> QuickreadSection {
        let body = ComposeBlockRequest(job_id: jobId, block_idx: blockIdx,
                                       timestamps: timestamps, duration: duration)
        return try await postSection(QuickReadEndpoint.composeBlockURL, body: body, label: "compose-block[\(blockIdx)] ts=\(timestamps.count) dur=\(String(format: "%.1f", duration))")
    }

    // MARK: - 快道（fast-block0）

    /// 快道：标题 + 开头 N 段 → 一次 LLM 直出 block_0{narration, marks}（marks 无 at），跳过读整篇 + compose。
    /// 失败即抛出、**不重试**（快道的意义是快；失败由竞速兜底——质道 block_0 自然顶上）。超时 8s。
    /// 返回精简 section（text=narration、events=过滤后的 marks）。
    func fastBlock0(title: String, openingParas: [String], lang: String?,
                    depth: String, prevSummary: String?, contentType: String?) async throws -> QuickreadSection {
        guard let url = URL(string: QuickReadEndpoint.fastBlock0URL) else { throw QuickReadError.invalidURL }
        let body = FastBlock0Request(title: title,
                                     openingParas: openingParas.map { FastBlock0OpeningPara(text: $0) },
                                     lang: lang, depth: depth, prev_summary: prevSummary, content_type: contentType)
        let startedAt = Date()
        debugLog("fast-block0 START scenario=\(contentType ?? "general") depth=\(depth) lang=\(lang ?? "auto") opening=\(openingParas.count) chars=\(openingParas.reduce(0) { $0 + $1.count })")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let identity = await authHeaderIdentity()
        applyAuthHeaders(&req, identity: identity)
        req.httpBody = try encoder.encode(body)
        req.timeoutInterval = 8   // 快道超时即放弃，走质道

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            debugLog("fast-block0 HTTP \(http.statusCode) elapsed=\(Self.elapsed(startedAt))")
            throw QuickReadError.httpError(http.statusCode)
        }
        let resp = try decoder.decode(FastBlock0Response.self, from: data)
        guard let b0 = resp.block_0,
              !b0.narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            debugLog("fast-block0 noBlock0 elapsed=\(Self.elapsed(startedAt))")
            throw QuickReadError.noBlock0
        }
        // marks 精简形态 → QuickreadEvent：非空 text 保留；at 留空（端侧均匀分布，见 ensureTiming）。
        // 场景化后端会返回 wave/star/strike/weight/role。旧白名单只保留 4 种，导致快道首块可见 mark 被压低。
        let supported: Set<String> = ["highlight", "underline", "wave", "strike", "circle", "star", "number"]
        let events = (b0.marks ?? [])
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map {
                let style = supported.contains($0.style) ? $0.style : "underline"
                return QuickreadEvent(at: nil, action: style, text: $0.text, n: $0.n,
                                      role: $0.role, weight: $0.weight, note: $0.note)
            }
        debugLog("fast-block0 DONE marks_raw=\(b0.marks?.count ?? 0) marks_kept=\(events.count) text=\(b0.narration.count) elapsed=\(Self.elapsed(startedAt))")
        return QuickreadSection(id: "fast-0", text: b0.narration, style: "explain",
                                cinematic: QuickreadCinematic(events: events))
    }

    private func postSection<Body: Encodable>(_ urlString: String, body: Body, label: String) async throws -> QuickreadSection {
        guard let url = URL(string: urlString) else { throw QuickReadError.invalidURL }
        let payload = try encoder.encode(body)
        debugLog("\(label) START bytes=\(payload.count)")
        let startedAt = Date()
        return try await withRetry {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let identity = await self.authHeaderIdentity()
            self.applyAuthHeaders(&req, identity: identity)
            req.httpBody = payload
            let (data, response) = try await self.session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                self.debugLog("\(label) HTTP \(http.statusCode) elapsed=\(Self.elapsed(startedAt))")
                throw QuickReadError.httpError(http.statusCode)
            }
            do {
                let section = try self.decoder.decode(QuickreadSectionResponse.self, from: data).section
                self.debugLog("\(label) DONE marks=\(section.events.count) text=\(section.text.count) elapsed=\(Self.elapsed(startedAt))")
                return section
            } catch {
                self.debugLog("\(label) DECODE_FAIL elapsed=\(Self.elapsed(startedAt)) error=\(error)")
                throw QuickReadError.decodeError("\(error)")
            }
        }
    }

    private static func elapsed(_ startedAt: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(startedAt))
    }
}
