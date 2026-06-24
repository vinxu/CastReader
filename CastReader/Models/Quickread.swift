//
//  Quickread.swift
//  CastReader
//
//  解读（QuickRead）API 数据模型 —— 对齐扩展 quickread.castreader.ai:8444 的三段式协议。
//  extract-plan(SSE) → extract-block(JSON) → compose-block(JSON, 回填 mark.at)
//

import Foundation

// MARK: - Cinematic Event（核心标注数据）

/// 一个手写标注事件。`at` 由 compose-block 用 TTS timestamps 对齐后回填。
struct QuickreadEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    var at: Double?            // 触发时刻（秒）
    var action: String         // highlight | underline | circle | number | ...
    var text: String?          // 锚定原文（可能带【】或被改写）
    var n: Int?                // 序号（number action）
    var role: String?          // key | caution | term | example
    var note: String?          // 旁注

    enum CodingKeys: String, CodingKey {
        case at, action, text, n, role, note
    }
}

struct QuickreadCinematic: Codable, Equatable {
    var events: [QuickreadEvent] = []
}

struct QuickreadSection: Codable, Equatable, Identifiable {
    var id: String
    var text: String           // 讲解文本（TTS 朗读的内容，非原文）
    var style: String?
    var cinematic: QuickreadCinematic?

    var events: [QuickreadEvent] { cinematic?.events ?? [] }
}

// MARK: - Plan（extract-plan SSE）

enum QuickreadDepth: String, CaseIterable, Codable, Identifiable {
    case overview, standard, deep
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .overview: return String(localized: "速览")
        case .standard: return String(localized: "标准")
        case .deep: return String(localized: "深入")
        }
    }
}

/// extract-plan 的 `block0` 事件载荷
struct PlanBlock0: Codable, Equatable {
    let job_id: String
    let output_language: String?
    let total_blocks: Int
    let block_0: QuickreadSection
}

/// extract-plan 的 `done` 事件载荷（字段宽松）
struct PlanDone: Codable, Equatable {
    let job_id: String?
    let total_blocks: Int?
    let model_used: String?
}

// MARK: - Requests

struct QuickreadParagraphDTO: Codable, Equatable {
    let text: String
    let type: String
}

struct ExtractPlanRequest: Codable {
    let source_url: String
    let title: String
    let lang: String?          // nil = 跟随原文
    let depth: String
    let text: String
    let fullText: String
    let paragraphs: [QuickreadParagraphDTO]
    var prev_summary: String?  // 快道激活 → 质道承接快道 narration（block_1 不复述开头、衔接连贯）；书籍翻页承接同字段
}

struct ExtractBlockRequest: Codable {
    let job_id: String
    let block_idx: Int
}

struct ComposeTimestamp: Codable, Equatable {
    let word: String
    let start: Double
    let end: Double
}

struct ComposeBlockRequest: Codable {
    let job_id: String
    let block_idx: Int
    let timestamps: [ComposeTimestamp]
    let duration: Double
}

/// extract-block / compose-block 的响应包裹
struct QuickreadSectionResponse: Codable {
    let section: QuickreadSection
}

// MARK: - 快道（fast-block0）：跳过「读整篇」+「compose」，一次 LLM 直出 block_0 秒开

struct FastBlock0OpeningPara: Codable { let text: String }

struct FastBlock0Request: Codable {
    let title: String
    let openingParas: [FastBlock0OpeningPara]
    let lang: String?
    let depth: String
    let prev_summary: String?
}

/// 快道 mark 精简形态（无 at，端侧均匀分布；style ∈ circle|underline|highlight|number）
struct FastBlock0Mark: Codable {
    let style: String
    let text: String
    let n: Int?
}

struct FastBlock0Body: Codable {
    let narration: String
    let marks: [FastBlock0Mark]?
}

struct FastBlock0Response: Codable {
    let block_0: FastBlock0Body?
    let fast_ms: Double?
}

// MARK: - Status

enum ExplainStatus: Equatable {
    case idle
    case planning                       // extract-plan 进行中
    case streaming(block: Int, total: Int)
    case completed
    case error(String)

    var isActive: Bool {
        switch self {
        case .planning, .streaming: return true
        default: return false
        }
    }
}
