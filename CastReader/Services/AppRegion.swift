//
//  AppRegion.swift
//  CastReader
//
//  发行区域判定。
//
//  设计前提：**默认必须是 global**。只有明确判定为中国大陆才返回 `.cn`，
//  任何判据缺失、超时或异常都退回 global —— 中国区适配不得影响其他国家用户。
//
//  与 `TTSEndpoint.isMainlandChina()` 的区别（不要混用）：
//  - `TTSEndpoint` 按**时区**做网络就近路由，回答「现在人在哪，哪个节点快」；
//    海外用户到中国出差也应该走 CN 节点，这是正确行为。
//  - `AppRegion` 按 **App Store storefront** 做发行区域判定，回答「这台设备属于
//    哪个发行版本，适用哪套合规与商业规则」；出差不改变发行区域。
//

import Foundation
import StoreKit

enum AppRegion: String, CaseIterable {
    case global
    case cn
}

extension AppRegion {

    // MARK: - 存储

    private enum Key {
        /// 用户在设置页显式选择的区域。nil 表示跟随自动判定。
        static let override = "appRegion.v1.override"
        /// 最近一次解析到的 App Store storefront 国家码（权威判据的缓存）。
        static let storefrontCountryCode = "appRegion.v1.storefrontCountryCode"
    }

    /// App Store 中国大陆的 storefront 国家码。
    private static let mainlandStorefrontCode = "CHN"

    /// 中国大陆 IANA 时区（港澳台不含）。仅用于权威判据就绪前的临时兜底。
    private static let mainlandTimeZones: Set<String> = [
        "Asia/Shanghai", "Asia/Urumqi", "Asia/Chongqing", "Asia/Harbin", "Asia/Kashgar"
    ]

    private static var defaults: UserDefaults { .standard }

    // MARK: - 启动参数（UI 测试用）

    /// `-CastReaderRegion cn` / `-CastReaderRegion global` 强制区域，便于 UI 测试
    /// 两套引导而不必换 App Store 账号。
    private static var launchArgumentRegion: AppRegion? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-CastReaderRegion"),
              index + 1 < arguments.count else { return nil }
        return AppRegion(rawValue: arguments[index + 1])
    }

    // MARK: - 读取

    /// 当前区域。任何线程可调用，永远立即返回。
    ///
    /// 优先级：启动参数 → 用户覆盖 → storefront 缓存（权威）→ 时区兜底 → global。
    static var current: AppRegion {
        if let forced = launchArgumentRegion { return forced }
        if let override = overrideRegion { return override }
        if let code = defaults.string(forKey: Key.storefrontCountryCode), !code.isEmpty {
            // 权威判据已就绪：只有 CHN 是 cn，其余一律 global。
            return code == mainlandStorefrontCode ? .cn : .global
        }
        // 权威判据尚未就绪，用时区兜底，避免首帧无值。
        return mainlandTimeZones.contains(TimeZone.current.identifier) ? .cn : .global
    }

    /// 权威判据（storefront）是否已就绪。
    ///
    /// 首启引导必须等这个为 true 之后再决定呈现哪一套，否则在中国出差的海外
    /// 用户会先闪一下中国区引导。启动参数与用户覆盖本身就是确定值，直接算就绪。
    static var isAuthoritative: Bool {
        if launchArgumentRegion != nil { return true }
        if overrideRegion != nil { return true }
        let code = defaults.string(forKey: Key.storefrontCountryCode) ?? ""
        return !code.isEmpty
    }

    /// 用户在设置页显式选择的区域；nil 表示跟随自动判定。
    static var overrideRegion: AppRegion? {
        get {
            defaults.string(forKey: Key.override).flatMap(AppRegion.init(rawValue:))
        }
        set {
            if let newValue {
                defaults.set(newValue.rawValue, forKey: Key.override)
            } else {
                defaults.removeObject(forKey: Key.override)
            }
        }
    }

    /// 设置页用来存这个覆盖值的 key。`@AppStorage` 绑同一个 key 才能让开关即时响应。
    static var overrideDefaultsKey: String { Key.override }

    // MARK: - 诊断

    /// 当前区域是由哪一级判据决定的。只用于内部调试展示。
    enum Provenance: String {
        case launchArgument = "启动参数"
        case userOverride = "手动切换"
        case storefront = "App Store 地区"
        case timeZone = "时区推断（未就绪）"
    }

    static var provenance: Provenance {
        if launchArgumentRegion != nil { return .launchArgument }
        if overrideRegion != nil { return .userOverride }
        let code = defaults.string(forKey: Key.storefrontCountryCode) ?? ""
        return code.isEmpty ? .timeZone : .storefront
    }

    /// 已解析到的 App Store 国家码，未就绪时为 nil。
    static var resolvedStorefrontCode: String? {
        let code = defaults.string(forKey: Key.storefrontCountryCode) ?? ""
        return code.isEmpty ? nil : code
    }

    // MARK: - 解析

    /// 从 StoreKit 拉取 storefront 并缓存。启动时调用一次，前台恢复时可再调。
    ///
    /// 失败时**保留**上次缓存（而不是清空退回时区兜底）—— 已知的发行区域比
    /// 一次网络抖动更可信。
    static func refreshStorefront() async {
        guard let storefront = await Storefront.current else { return }
        let code = storefront.countryCode
        guard !code.isEmpty else { return }
        defaults.set(code, forKey: Key.storefrontCountryCode)
    }

    /// 等待权威判据就绪后返回区域，最多等 `timeout` 秒。
    ///
    /// 给首启引导用：宁可多等一瞬，也不要让海外用户闪现中国区界面。
    /// 超时后返回 `current`（即时区兜底值），不阻塞用户。
    static func awaitAuthoritative(timeout: TimeInterval = 2) async -> AppRegion {
        if isAuthoritative { return current }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await refreshStorefront() }
            group.addTask { try? await Task.sleep(for: .seconds(timeout)) }
            await group.next()
            group.cancelAll()
        }
        return current
    }

    // MARK: - 能力矩阵

    var isChinaMainland: Bool { self == .cn }

    /// 「书架来源」页里可以手动绑定的书库。
    ///
    /// 中国区把微信读书排在第一，但**不封杀** Kindle / Kobo / O'Reilly——
    /// 国内用户完全可能持有这些账号（Kindle 中国商店虽已停运，海外账号仍可
    /// 正常登录 read.amazon.com）。默认与首页一级入口是另一回事，见
    /// `onboardingSource` 与首页的 `showsOverseasLibraryModules`。
    ///
    /// 包括 Google Play 图书在内的既有入口全部保留；网络不可达时由各连接页
    /// 继续使用原有的错误与重试路径，不在发行区域层面删除功能。
    var availableBoundLibraries: [BoundLibraryOnboardingSource] {
        switch self {
        case .global: return [.kindle, .weread, .googleBooks, .kobo, .oreilly]
        case .cn: return [.weread, .kindle, .googleBooks, .kobo, .oreilly]
        }
    }

    /// 首启引导强绑定的书库。
    var onboardingSource: BoundLibraryOnboardingSource {
        switch self {
        case .global: return .kindle
        case .cn: return .weread
        }
    }

    /// Google 登录在中国区仍保留为可选通道；手机号只是默认首选，不删除既有入口。
    var showsGoogleSignIn: Bool { true }

    /// 是否展示手机号登录（CN 首选）。
    var showsPhoneSignIn: Bool { self == .cn }

    /// 账号 / Pro / 埋点的 Web 后端。
    ///
    /// 中国区是 `api.` 子域而不是裸域：境内服务部署在上海的 CVM 上
    /// （2026-08-08 上线），裸域 `castreader.cn` 暂无解析记录。
    /// 备案通过后可以再把裸域指过来做落地页，接口地址不受影响。
    var webBaseURL: String {
        switch self {
        case .global: return "https://castreader.ai"
        case .cn: return "https://api.castreader.cn"
        }
    }

    /// TTS、文档、上传与解读使用的自有 API 网关。
    var apiGatewayBaseURL: String {
        switch self {
        case .global: return "https://api.castreader.ai"
        case .cn: return "https://api.castreader.cn"
        }
    }

    /// 订阅货币符号。中国区展示人民币。
    var currencySymbol: String {
        switch self {
        case .global: return "$"
        case .cn: return "¥"
        }
    }
}
