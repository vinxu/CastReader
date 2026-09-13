//
//  WebReaderProtocol.swift
//  CastReader
//
//  WebView 阅读器的 native↔JS bridge 协议。
//  - native→JS：WebReaderBridge.call("fn", payload) → evaluateJavaScript("window.CR.fn(json)")
//  - JS→native：window.webkit.messageHandlers.castreader.postMessage({type,payload})
//

import Foundation

/// JS → native 的入站事件（WKScriptMessage.body 解析）。
struct WebInboundMessage {
    let type: String
    let payload: [String: Any]

    init?(_ body: Any) {
        guard let dict = body as? [String: Any], let type = dict["type"] as? String else { return nil }
        self.type = type
        self.payload = dict["payload"] as? [String: Any] ?? [:]
    }
}

/// 渲染层回传的段落结构（rendered 事件）——native 用它重建 ReadingDocument.paragraphs（段落对齐单一事实源）。
struct WebRenderedParagraph {
    let paragraphIndex: Int
    let text: String
    let type: String

    init(paragraphIndex: Int, text: String, type: String = "paragraph") {
        self.paragraphIndex = paragraphIndex
        self.text = text
        self.type = type
    }

    init?(_ dict: [String: Any]) {
        guard let idx = dict["paragraphIndex"] as? Int, let text = dict["text"] as? String else { return nil }
        self.paragraphIndex = idx
        self.text = text
        self.type = dict["type"] as? String ?? "paragraph"
    }
}

/// AO3 has a replaceable chapter and a delayed, blocking site notice. Generic
/// paragraph-count heuristics cannot distinguish its notice from prose.
struct AO3PageUpdate {
    enum State: String { case ready, notice, unavailable }
    let state: State
    let documentID: String
    let pageKey: String
    let signature: String

    static func isAO3URL(_ raw: String?) -> Bool {
        guard let raw, let url = URL(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        return ["archiveofourown.org", "www.archiveofourown.org", "archiveofourown.com",
                "www.archiveofourown.com", "archiveofourown.net", "www.archiveofourown.net", "ao3.org"].contains(host)
    }

    static func pageKey(_ raw: String?) -> String? {
        guard isAO3URL(raw), let raw, var url = URLComponents(string: raw) else { return nil }
        url.fragment = nil
        return url.string
    }

    init?(_ payload: [String: Any], currentURL: String?) {
        guard payload["source"] as? String == "ao3",
              let state = (payload["state"] as? String).flatMap(State.init(rawValue:)),
              let id = payload["documentID"] as? String, !id.isEmpty,
              let key = Self.pageKey(payload["url"] as? String), key == Self.pageKey(currentURL),
              let signature = payload["signature"] as? String else { return nil }
        self.state = state; self.documentID = id; self.pageKey = key; self.signature = signature
    }

    var notice: String? {
        switch state {
        case .ready: return nil
        case .notice: return AppLocalized("请先在网页中完成 AO3 提示，再继续")
        case .unavailable: return AppLocalized("暂时无法读取 AO3 正文，请在网页中重试")
        }
    }
}

/// native→JS 的当前朗读高亮指令（.web 源）：高亮 DOM 段落内某句的字符范围（句级，随朗读推进）。
struct WebHighlightCmd: Equatable {
    let paragraphIndex: Int            // DOM 段落（data-cr-para）
    var charStart: Int = -1            // 句级（中文/无词时间戳）：当前句在段落文本内的字符范围
    var charEnd: Int = -1
    var words: [String]? = nil         // 词级（英文/有词时间戳）：当前 segment 的词文本数组
    var wordIndex: Int = -1            // 词级：当前词在 segment 内索引
    var segSeq: Int = -1               // 词级：segment 在段落的序号（JS 按此重建词 Range 缓存的前向 cursor）
    var segmentTexts: [String]? = nil   // 句级：当前段落全部 TTS segment；JS 按扩展算法重放匹配回页面原文
    var isWord: Bool { words != nil }
}
