//
//  CastReaderApp.swift
//  CastReader
//
//  Created by 许旭恒 on 1/7/26.
//

import SwiftUI
import UIKit

@MainActor
final class CastReaderAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppOrientationLock.supportedOrientations
    }
}

/// Scene-scoped orientation policy used by reader integrations that cannot
/// provide a usable landscape layout. WeRead owns this lock only while its
/// reader is visible; every other CastReader surface keeps the app defaults.
@MainActor
enum AppOrientationLock {
    private struct Request {
        let orientations: UIInterfaceOrientationMask
        let order: UInt64
    }

    private static var requests: [String: Request] = [:]
    private static var requestOrder: UInt64 = 0
    private static var applicationRevision: UInt64 = 0

    static var supportedOrientations: UIInterfaceOrientationMask {
        requests.values.max(by: { $0.order < $1.order })?.orientations
            ?? defaultOrientations
    }

    static func lockPortrait(owner: String) {
        lock(.portrait, owner: owner, reason: "portrait")
    }

    /// Freeze the interface exactly where the user minimized the reader. This
    /// avoids an off-screen WKWebView receiving a rotation/reflow while its TTS
    /// session is owned by Mini Player.
    static func lockCurrent(owner: String) {
        lock(currentInterfaceOrientationMask(), owner: owner, reason: "current")
    }

    static func unlock(owner: String) {
        guard requests.removeValue(forKey: owner) != nil else { return }
        applyCurrentPolicy(reason: "unlock", owner: owner)
    }

    private static var defaultOrientations: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .allButUpsideDown
    }

    private static func lock(
        _ orientations: UIInterfaceOrientationMask,
        owner: String,
        reason: String
    ) {
        requestOrder &+= 1
        requests[owner] = Request(orientations: orientations, order: requestOrder)
        applyCurrentPolicy(reason: reason, owner: owner)
    }

    private static func currentInterfaceOrientationMask() -> UIInterfaceOrientationMask {
        let orientation = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .interfaceOrientation
        switch orientation {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        case .landscapeRight: return .landscapeRight
        default: return .portrait
        }
    }

    private static func applyCurrentPolicy(
        reason: String,
        owner: String
    ) {
        applicationRevision &+= 1
        let revision = applicationRevision
        let orientations = supportedOrientations
        // Update the delegate policy before asking UIKit to resolve geometry.
        // Dispatch one run-loop turn so the ReaderHost has an attached scene
        // even when it was presented while the device was already landscape.
        DispatchQueue.main.async {
            // A close/open or Mini Player expand can enqueue two policies in
            // one render pass. Never let the older geometry request win later.
            guard revision == applicationRevision else { return }
            let scenes = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .filter { $0.activationState != .unattached }
            for scene in scenes {
                let root = scene.windows.first(where: \.isKeyWindow)?.rootViewController
                    ?? scene.windows.first?.rootViewController
                root?.setNeedsUpdateOfSupportedInterfaceOrientations()
                scene.requestGeometryUpdate(
                    UIWindowScene.GeometryPreferences.iOS(interfaceOrientations: orientations)
                ) { error in
                    ReaderRunLog.write(
                        "ORIENTATION \(reason) failed owner=\(owner) error=\(error.localizedDescription)"
                    )
                }
            }
            ReaderRunLog.write(
                "ORIENTATION \(reason) owner=\(owner) mask=\(orientations.rawValue)"
            )
        }
    }
}

/// 硬登录门：未登录时整个 App 只渲染登录页。
///
/// 对全部未登录用户生效，包括从旧版本升级上来的老用户——`AuthService.restore()`
/// 在 init 里同步跑完，登录过的人不会看到这道门闪一下。
///
/// MainTabView 只在登录后创建，所以常驻阅读器（ReaderHostView / KindleBookView）
/// 的生命周期不受影响；只有主动登出才会销毁它们，这与登出语义一致。
struct RootAuthGate: View {
    @ObservedObject private var auth = AuthService.shared

    /// UI 测试无法走真实的 Google/Apple 授权，所以它们需要一条绕过。沿用
    /// BoundLibraryOnboardingStore 既有的 launch-argument 约定。
    private let bypassesGate = ProcessInfo.processInfo.arguments
        .contains("-CastReaderSkipSignInGate")

    var body: some View {
        if auth.isSignedIn || bypassesGate {
            MainTabView()
        } else {
            LoginView(isRootGate: true)
        }
    }
}

@main
struct CastReaderApp: App {
    @UIApplicationDelegateAdaptor(CastReaderAppDelegate.self) private var appDelegate
    @StateObject private var visitorService = VisitorService.shared
    @StateObject private var appLanguage = AppLanguageManager.shared
    @State private var showSafariPro = false
    @State private var showSafariAccount = false
    @State private var showSignOutConfirm = false
    @State private var pendingSafariLibraryOnboardingReset: Bool?

    init() {
        // Reclaim playback artifacts left by a previous process before any
        // reader is opened. AudioPlayerService is lazy, so putting this only in
        // its initializer would let legacy segment/prestage files survive on
        // the login and home surfaces indefinitely.
        _ = AudioPlaybackTemporaryFiles.prepare()

        // 简单的内存警告监听
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("⚠️ Memory warning received")
            Task { @MainActor in
                // Never turn an ordinary memory warning into a playback stop.
                // The queue is the active spoken-audio pipeline, not a disposable
                // cache; iOS background audio must remain uninterrupted.
                guard !AudioPlayerService.shared.hasActivePlayback else {
                    print("⚠️ Keeping active audio queue during memory warning")
                    return
                }
                AudioPlayerService.shared.clearQueue()
            }
        }

        // Pro 订阅状态 + 每日额度初始化
        // An App Intent runs in its own process and deposits the action before
        // launching us, so the pending slot already says which system surface
        // opened this session. Peeking never consumes it — MainTab still routes.
        let launchType = SystemActionStore.shared.peekPendingOrigin()?.launchType ?? "cold"
        Task { @MainActor in
            ProductAnalytics.shared.startAppSession(launchType: launchType)
            ProManager.shared.start()
            QuotaManager.shared.rollIfNewDay()
            VoiceCatalogService.shared.start()
            NetworkReachability.shared.start()
            YouTubeTranscriptService.resetWebsiteDataStoreIfNeeded()
        }
        // 解析发行区域（App Store storefront）。首启引导会等这个结果，
        // 所以要尽早发起；失败保留上次缓存，默认 global。
        Task { await AppRegion.refreshStorefront() }
        // 刷新云端 TTS 节点配置（CN/US 路由）
        Task { await TTSEndpoint.refreshRemoteConfig() }
        // 刷新云端解读(quickread)后端地址（换后端零发版；兜底 qr.castreader.ai）
        Task { await QuickReadEndpoint.refreshRemoteConfig() }

        // 回前台刷新 Pro/额度
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in
                ProductAnalytics.shared.didBecomeActive()
                QuotaManager.shared.rollIfNewDay()
                await ProManager.shared.refresh()
                await VoiceCatalogService.shared.refreshIfStale()
            }
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in ProductAnalytics.shared.didEnterBackground() }
        }

        ResumeReminderManager.shared.start()   // 「继续听」召回：进后台调度、回前台取消
    }

    var body: some Scene {
        WindowGroup {
            RootAuthGate()
                .environmentObject(visitorService)
                .environment(\.locale, appLanguage.locale)
                // 深色/浅色跟随系统（AppTheme 已全动态化，见 Utils/AppTheme.swift）
                .onOpenURL { url in
                    if StudyBoostDeepLink.matches(url) {
                        StudyBoostRouter.shared.open()
                    } else if url.scheme == "castreader", url.host == "youtube" {
                        let components = URLComponents(
                            url: url,
                            resolvingAgainstBaseURL: false
                        )
                        if let rawURL = components?.queryItems?
                            .first(where: { $0.name == "url" })?.value {
                            let entryValue = components?.queryItems?
                                .first(where: { $0.name == "entry" })?.value
                            let entry = entryValue.flatMap(YouTubeListenEntry.init(rawValue:))
                                ?? .scheme
                            _ = YouTubeRouteCenter.shared.open(
                                rawURL,
                                entry: entry
                            )
                        }
                    } else if let systemAction = SystemAction.from(url: url) {
                        SystemActionStore.shared.enqueue(systemAction, origin: .deepLink)
                    } else if url.scheme == "castreader", url.host == "share-inbox" {
                        NotificationCenter.default.post(name: .castReaderShareInboxChanged, object: nil)
                    } else if url.scheme == "castreader", url.host == "pro" {
                        showSafariPro = true
                    } else if url.scheme == "castreader", url.host == "account" {
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let action = components?.queryItems?.first(where: { $0.name == "action" })?.value
                        if action == "signout" {
                            // 硬登录墙下登出 = App 回到登录页。深链是外部输入
                            // （Safari 扩展页面），不能未经确认直接执行。
                            showSignOutConfirm = true
                        } else {
                            showSafariAccount = true
                        }
                    }
                }
                .alert(AppLocalized("退出登录"), isPresented: $showSignOutConfirm) {
                    Button(AppLocalized("退出登录"), role: .destructive) {
                        AuthService.shared.signOut()
                        SafariExtensionBridge.syncFromApp()
                        showSafariAccount = false
                    }
                    Button(AppLocalized("取消"), role: .cancel) {}
                } message: {
                    Text(AppLocalized("退出登录后需要重新登录才能继续使用 CastReader。"))
                }
                .sheet(isPresented: $showSafariPro) {
                    PaywallView(
                        reason: AppLocalized("从 Safari 解锁完整朗读与解读"),
                        analyticsTrigger: "safari_extension",
                        analyticsSurface: "safari_extension"
                    )
                }
                .sheet(
                    isPresented: $showSafariAccount,
                    onDismiss: presentSafariRequestedLibraryOnboarding
                ) {
                    if AuthService.shared.isSignedIn {
                        SettingsView { reset in
                            pendingSafariLibraryOnboardingReset = reset
                        }
                    } else {
                        LoginView()
                    }
                }
        }
    }

    private func presentSafariRequestedLibraryOnboarding() {
        guard let reset = pendingSafariLibraryOnboardingReset else { return }
        pendingSafariLibraryOnboardingReset = nil
        if reset {
            BoundLibraryOnboardingStore.shared.reset()
        } else {
            BoundLibraryOnboardingStore.shared.presentChooser()
        }
    }
}
