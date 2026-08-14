//
//  Quickread.swift
//  CastReader
//
//  解读（QuickRead）API 数据模型 —— 对齐 global / cn 网关后的三段式协议。
//  extract-plan(SSE) → extract-block(JSON) → compose-block(JSON, 回填 mark.at)
//

import Foundation

// MARK: - Cinematic Event（核心标注数据）

/// 一个手写标注事件。`at` 由 compose-block 用 TTS timestamps 对齐后回填。
struct QuickreadEvent: Codable, Equatable, Identifiable {
    var id = UUID()
    var at: Double?            // 触发时刻（秒）
    var action: String         // highlight | underline | wave | strike | circle | star | number | ...
    var text: String?          // 锚定原文（可能带【】或被改写）
    var n: Int?                // 序号（number action）
    var role: String?          // key | caution | term | example（语义角色，P1 透传，渲染主要看 weight+action）
    var weight: String?        // primary | secondary | tertiary（重要度分层 → 笔触粗细；nil = 普通，零回归）
    var note: String?          // 旁注

    enum CodingKeys: String, CodingKey {
        case at, action, text, n, role, weight, note
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
        case .overview: return AppLocalized("速览")
        case .standard: return AppLocalized("标准")
        case .deep: return AppLocalized("深入")
        }
    }
}

/// 场景化「划重点·批注」预设（PRD：6 个长内容场景）。rawValue = 后端 content_type，按值分支划/批 prompt。
/// 客户端只负责把场景信号（content_type + depth 预设）传到位；未知值后端降级为通用解读、零回归。
enum ExplainContentType: String, CaseIterable, Identifiable {
    case paper, book, report, contract, study, manual
    var id: String { rawValue }

    /// 场景名（首页入口标题）。
    var displayName: String {
        switch self {
        case .paper:    return AppLocalized("论文 / 学术")
        case .book:     return AppLocalized("书籍 / 长篇")
        case .report:   return AppLocalized("报告 / 研报")
        case .contract: return AppLocalized("合同 / 条款")
        case .study:    return AppLocalized("教材 / 学习")
        case .manual:   return AppLocalized("说明书 / 文档")
        }
    }

    /// 一句「这个场景划什么」。
    var subtitle: String {
        switch self {
        case .paper:    return AppLocalized("研究问题 · 方法 · 结论 · 贡献")
        case .book:     return AppLocalized("核心观点 · 金句 · 概念 · 转折")
        case .report:   return AppLocalized("核心结论 · 关键数据 · 风险")
        case .contract: return AppLocalized("权利义务 · 金额期限 · 风险条款")
        case .study:    return AppLocalized("知识点 · 定义 · 易考点")
        case .manual:   return AppLocalized("关键步骤 · 警告 · 参数")
        }
    }

    /// 首页入口图标（SF Symbol）。
    var icon: String {
        switch self {
        case .paper:    return "doc.text.magnifyingglass"
        case .book:     return "book"
        case .report:   return "chart.bar.doc.horizontal"
        case .contract: return "doc.plaintext"
        case .study:    return "graduationcap"
        case .manual:   return "wrench.and.screwdriver"
        }
    }
}

// 注：content_type 与 depth 正交——场景不预设/不覆盖深度。深度始终由用户在设置里选的 3 档 QuickreadDepth 决定。
// 见 docs/场景解读适配规范.md。

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
    let page_summary: String?
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
    var content_type: String?  // 场景化「划什么/怎么批」（paper|book|report|contract|study|manual）；nil = 通用解读
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
    let content_type: String?  // 同 extract-plan：场景 content_type，快道 block_0 也按场景划/批
}

/// 快道 mark 精简形态（无 at，端侧均匀分布；style 走统一工具箱）。
struct FastBlock0Mark: Codable {
    let style: String
    let text: String
    let n: Int?
    let role: String?
    let weight: String?
    let note: String?
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
