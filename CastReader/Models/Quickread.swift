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
