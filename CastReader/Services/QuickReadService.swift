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

    // MARK: - extract-plan（SSE）

    /// 通读全文生成大纲 + 首块。onStage/onBlock0 在事件到达时回调；返回 done 载荷。
    @discardableResult
    func extractPlan(_ body: ExtractPlanRequest,
                     onStage: @escaping (String) -> Void,
                     onBlock0: @escaping (PlanBlock0) -> Void) async throws -> PlanDone {
        guard let url = URL(string: Constants.API.quickReadPlan) else { throw QuickReadError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        applyAuthHeaders(&req)
        req.httpBody = try encoder.encode(body)

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

    private func postSection<Body: Encodable>(_ urlString: String, body: Body) async throws -> QuickreadSection {
        guard let url = URL(string: urlString) else { throw QuickReadError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        applyAuthHeaders(&req)
        req.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw QuickReadError.httpError(http.statusCode)
        }
        do {
            return try decoder.decode(QuickreadSectionResponse.self, from: data).section
        } catch {
            throw QuickReadError.decodeError("\(error)")
        }
    }
}
