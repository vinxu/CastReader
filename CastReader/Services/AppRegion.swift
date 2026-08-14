//
//  AppRegion.swift
//  CastReader
//
//  发行区域判定。
//
//  设计前提：**默认必须是 global**。只有明确判定为中国大陆才返回 `.cn`，
//  任何判据缺失、超时或异常都退回 global —— 中国区适配不得影响其他国家用户。
//
//  `AppRegion` 按 **App Store storefront** 做发行区域判定，回答「这台设备属于
//    哪个发行版本，适用哪套合规与商业规则」；出差不改变发行区域。
//  自有 API 节点由与之独立的 `ServiceRouting` 决定，不再按时区直连上游。
//

import Foundation
import StoreKit

enum AppRegion: String, CaseIterable {
    case global
    case cn
}

extension AppRegion {

    struct Resolution: Equatable {
        let region: AppRegion
        let isAuthoritative: Bool
        let provenance: Provenance
    }

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
    private static let launchRuntime = AppRegionLaunchRuntime()

    // MARK: - 启动参数（UI 测试用）

    /// `-CastReaderRegion cn` / `-CastReaderRegion global` 强制区域，便于 UI 测试
    /// 两套引导而不必换 App Store 账号。
    private static func launchArgumentRegion(_ arguments: [String]) -> AppRegion? {
        guard let index = arguments.firstIndex(of: "-CastReaderRegion"),
              index + 1 < arguments.count else { return nil }
        return AppRegion(rawValue: arguments[index + 1])
    }

    // MARK: - 读取

    /// 当前区域。任何线程可调用，永远立即返回。
    ///
    /// 优先级：启动参数 → 用户覆盖 → storefront 缓存（权威）→ 时区兜底 → global。
    static var current: AppRegion {
        currentResolution.region
    }

    /// 权威判据（storefront）是否已就绪。
    ///
    /// 首启引导必须等这个为 true 之后再决定呈现哪一套，否则在中国出差的海外
    /// 用户会先闪一下中国区引导。启动参数与用户覆盖本身就是确定值，直接算就绪。
    static var isAuthoritative: Bool {
        currentResolution.isAuthoritative
    }

    /// 用户在设置页显式选择的区域；nil 表示跟随自动判定。
    static var overrideRegion: AppRegion? {
        get {
            guard DistributionTestingPolicy.allowsPersistedOverrides else { return nil }
            return defaults.string(forKey: Key.override).flatMap(AppRegion.init(rawValue:))
        }
        set {
            guard DistributionTestingPolicy.allowsPersistedOverrides else {
                defaults.removeObject(forKey: Key.override)
                return
            }
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
        case safeDefault = "安全默认"
    }

    static var provenance: Provenance {
        currentResolution.provenance
    }

    /// 已解析到的 App Store 国家码，未就绪时为 nil。
    static var resolvedStorefrontCode: String? {
        let code = defaults.string(forKey: Key.storefrontCountryCode) ?? ""
        return code.isEmpty ? nil : code
    }

    /// Pure distribution resolution used by production-upgrade regression
    /// tests. Invalid or disallowed persisted overrides are ignored; they can
    /// never manufacture an authoritative China storefront.
    static func resolve(
        defaults: UserDefaults = .standard,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        allowLocalOverride: Bool = DistributionTestingPolicy.allowsPersistedOverrides
    ) -> Resolution {
        if let forced = launchArgumentRegion(arguments) {
            return Resolution(
                region: forced,
                isAuthoritative: true,
                provenance: .launchArgument
            )
        }
        if allowLocalOverride,
           let raw = defaults.string(forKey: Key.override),
           let override = AppRegion(rawValue: raw) {
            return Resolution(
                region: override,
                isAuthoritative: true,
                provenance: .userOverride
            )
        }
        if let code = defaults.string(forKey: Key.storefrontCountryCode), !code.isEmpty {
            return Resolution(
                region: code == mainlandStorefrontCode ? .cn : .global,
                isAuthoritative: true,
                provenance: .storefront
            )
        }
        return Resolution(
            region: mainlandTimeZones.contains(timeZoneIdentifier) ? .cn : .global,
            isAuthoritative: false,
            provenance: .timeZone
        )
    }

    static func discardDisallowedOverride(
        defaults: UserDefaults = .standard,
        allowLocalOverride: Bool = DistributionTestingPolicy.allowsPersistedOverrides
    ) {
        guard !allowLocalOverride else { return }
        defaults.removeObject(forKey: Key.override)
    }

    /// The distribution decision used by live UI. Before the launch bootstrap
    /// completes this is the ordinary persisted/argument resolution. If StoreKit
    /// cannot provide a storefront on first launch, the bootstrap installs an
    /// in-memory authoritative global fallback so a mainland timezone alone can
    /// never expose the CN product or authorize the CN service route.
    private static var currentResolution: Resolution {
        let resolved = resolve()
        if resolved.isAuthoritative { return resolved }
        return launchRuntime.safeFallback ?? resolved
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

    /// Resolve the signed distribution region before any route-dependent object
    /// is created. Explicit Debug/UI-test instrumentation remains highest
    /// priority and avoids a StoreKit/network wait. Production otherwise requires
    /// a current storefront result. If StoreKit is temporarily unavailable, a
    /// previously cached storefront is retained to preserve account namespace;
    /// only a first launch with no signed-distribution evidence fails global.
    static func prepareForCurrentProcess(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        storefrontTimeout: TimeInterval = 5,
        storefrontCountryCode: @escaping @Sendable () async -> String? = {
            guard let storefront = await Storefront.current else { return nil }
            return storefront.countryCode
        }
    ) async -> Resolution {
        let initial = resolve(arguments: arguments)
        if initial.provenance == .launchArgument || initial.provenance == .userOverride {
            launchRuntime.safeFallback = nil
            return initial
        }

        // `Storefront.current` is backed by StoreKit and can take an unbounded
        // amount of time while the App Store account or network is unavailable.
        // Route-dependent services must still start deterministically, so race
        // it against a real five-second deadline. The race does not await the
        // losing task; even an uncooperative StoreKit call cannot hold launch.
        if let rawCode = await lookupStorefrontCountryCode(
            timeout: storefrontTimeout,
            provider: storefrontCountryCode
        ) {
            let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !code.isEmpty {
                defaults.set(code, forKey: Key.storefrontCountryCode)
                launchRuntime.safeFallback = nil
                return resolve(arguments: arguments)
            }
        }

        // StoreKit may be temporarily unavailable while the device is offline.
        // A previously resolved storefront remains the best signed-distribution
        // evidence and, critically, preserves the same account/route namespace.
        if initial.isAuthoritative, initial.provenance == .storefront {
            launchRuntime.safeFallback = nil
            return initial
        }

        // Only a genuine first launch with no cached storefront fails closed.
        // The fallback is process-local and authoritative, preventing MainTab
        // from retrying later and creating product/route drift mid-session.
        let fallback = Resolution(
            region: .global,
            isAuthoritative: true,
            provenance: .safeDefault
        )
        launchRuntime.safeFallback = fallback
        return fallback
    }

    private static func lookupStorefrontCountryCode(
        timeout: TimeInterval,
        provider: @escaping @Sendable () async -> String?
    ) async -> String? {
        await withCheckedContinuation { continuation in
            let race = StorefrontLookupRace(continuation: continuation)
            let lookupTask = Task {
                race.finish(await provider())
            }
            let timeoutTask = Task {
                let duration = max(0, timeout)
                try? await Task.sleep(for: .seconds(duration))
                guard !Task.isCancelled else { return }
                race.finish(nil)
            }
            race.install(lookupTask: lookupTask, timeoutTask: timeoutTask)
        }
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

    #if DEBUG
    static func resetProcessResolutionForTesting() {
        launchRuntime.safeFallback = nil
    }
    #endif

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

    /// Google 账号登录只在全球版展示。中国大陆网络不可用且已有手机号、Apple，
    /// 不在登录页暴露一个无法完成的入口。
    var showsGoogleSignIn: Bool { self == .global }

    /// 是否展示手机号登录（CN 首选）。
    var showsPhoneSignIn: Bool { self == .cn }

    /// 邮箱验证码当前只作为全球区兜底登录通道；中国区只保留手机号与 Apple。
    var showsEmailSignIn: Bool { self == .global }

    /// 订阅货币符号。中国区展示人民币。
    var currencySymbol: String {
        switch self {
        case .global: return "$"
        case .cn: return "¥"
        }
    }
}

private final class AppRegionLaunchRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSafeFallback: AppRegion.Resolution?

    var safeFallback: AppRegion.Resolution? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedSafeFallback
        }
        set {
            lock.lock()
            storedSafeFallback = newValue
            lock.unlock()
        }
    }
}

/// A lock-backed one-shot continuation lets launch return as soon as either
/// StoreKit or the deadline wins. `withTaskGroup` is intentionally not used:
/// its scope waits for cancelled children to exit, which would turn a hung
/// StoreKit lookup back into a hung launch.
private final class StorefrontLookupRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    private var lookupTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    init(continuation: CheckedContinuation<String?, Never>) {
        self.continuation = continuation
    }

    func install(
        lookupTask: Task<Void, Never>,
        timeoutTask: Task<Void, Never>
    ) {
        lock.lock()
        if isFinished {
            lock.unlock()
            lookupTask.cancel()
            timeoutTask.cancel()
            return
        }
        self.lookupTask = lookupTask
        self.timeoutTask = timeoutTask
        lock.unlock()
    }

    func finish(_ countryCode: String?) {
        lock.lock()
        guard !isFinished, let continuation else {
            lock.unlock()
            return
        }
        isFinished = true
        self.continuation = nil
        let lookupTask = self.lookupTask
        let timeoutTask = self.timeoutTask
        self.lookupTask = nil
        self.timeoutTask = nil
        lock.unlock()

        lookupTask?.cancel()
        timeoutTask?.cancel()
        continuation.resume(returning: countryCode)
    }
}
