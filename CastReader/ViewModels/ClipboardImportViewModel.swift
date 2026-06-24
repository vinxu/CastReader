//
//  ClipboardImportViewModel.swift
//  CastReader
//
//  剪贴板快捷入口：进 App / 回前台时**只探测**剪贴板（hasURLs/hasStrings/hasImages + changeCount，
//  均不读取内容、不触发系统「Allow Paste」弹框），有可处理内容才弹自家卡片让用户选朗读/解读；
//  **真正读取剪贴板内容延迟到用户点了朗读/解读那一刻**（那一下才弹一次系统框，且是用户主动粘贴）。
//
//  为什么这么做：iOS 16+ 凡是 App 主动读取剪贴板内容（.string/.url/.image）都会弹系统「Allow Paste」，
//  且**没有「永久允许」的 API**（不像相机/相册可持久授权）。旧实现在 check() 里直接读内容 → 每次进 App 都弹。
//

import SwiftUI
import UIKit

@MainActor
final class ClipboardImportViewModel: ObservableObject {

    /// 探测到的类型（仅类型，不含内容——内容读取延迟到用户确认时）。
    enum Kind: String, Identifiable {
        case url, text, image
        var id: String { rawValue }
    }

    /// 读取后的实际内容（仅用户点朗读/解读时才产生）。
    enum Content {
        case url(String)
        case text(String)
        case image(UIImage)
    }

    @Published var detected: Kind?

    /// 上次已探测过的剪贴板 changeCount，**持久化**（UserDefaults）：App 重启/冷启后仍记得用户已对这版
    /// 剪贴板操作过，同一内容不再重复弹卡片（changeCount 系统级单调递增，仅剪贴板变化时才 +1）。
    /// 之前是内存变量 → 每次新实例重置 -1 → 同一剪贴板重进 App 又弹，故改为持久化。
    private var lastSeenChangeCount: Int {
        get { UserDefaults.standard.object(forKey: Self.changeCountKey) as? Int ?? -1 }
        set { UserDefaults.standard.set(newValue, forKey: Self.changeCountKey) }
    }
    private static let changeCountKey = "clipboard.lastSeenChangeCount"

    /// 探测（进前台调用）：只看 has*/changeCount，**绝不读取 url/string/image**（读取才触发系统弹框）。
    func check() {
        let pb = UIPasteboard.general
        let cur = pb.changeCount
        // changeCount 系统级单调递增，但**设备重启会重置变小**：当前 < 持久值 = 重启过，旧去重值失效，
        // 清掉按新内容处理（否则重启后新内容的低 changeCount 可能碰撞旧持久值 → 卡片该弹却不弹）。
        if cur < lastSeenChangeCount { lastSeenChangeCount = -1 }
        // 剪贴板自上次探测后没变（含用户已忽略的那版）→ 不再提示。
        guard cur != lastSeenChangeCount else { return }
        lastSeenChangeCount = cur

        if pb.hasURLs { detected = .url }
        else if pb.hasStrings { detected = .text }   // 是否真为网址留到读取时 looksLikeURL 细分
        else if pb.hasImages { detected = .image }
        // 否则剪贴板无可处理内容 → 不提示
    }

    /// 用户点朗读/解读时调用：**此处才读取**剪贴板内容（弹一次系统「Allow Paste」）。返回 nil = 用户拒绝或无内容。
    func read(_ kind: Kind) -> Content? {
        let pb = UIPasteboard.general
        switch kind {
        case .url:
            if let u = pb.url { return .url(u.absoluteString) }
            if let s = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return .url(s) }
            return nil
        case .text:
            guard let s = pb.string?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
            return Self.looksLikeURL(s) ? .url(s) : .text(s)
        case .image:
            if let img = pb.image { return .image(img) }
            return nil
        }
    }

    /// 收起卡片（朗读/解读/忽略后）。changeCount 已记录，同一剪贴板不再重复弹。
    func consume() { detected = nil }

    private static func looksLikeURL(_ s: String) -> Bool {
        if s.contains(" ") || s.contains("\n") || s.count > 2000 { return false }
        let low = s.lowercased()
        if low.hasPrefix("http://") || low.hasPrefix("https://") { return true }
        // 形如 example.com / example.com/path
        return s.range(of: #"^[a-z0-9.-]+\.[a-z]{2,}(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
