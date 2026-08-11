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

@main
struct CastReaderApp: App {
    @UIApplicationDelegateAdaptor(CastReaderAppDelegate.self) private var appDelegate
    @StateObject private var visitorService = VisitorService.shared
    @StateObject private var appLanguage = AppLanguageManager.shared
    @State private var showSafariPro = false
    @State private var showSafariAccount = false
    @State private var pendingSafariLibraryOnboardingReset: Bool?

    init() {
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
        Task { @MainActor in
            ProductAnalytics.shared.startAppSession()
            ProManager.shared.start()
            QuotaManager.shared.rollIfNewDay()
            VoiceCatalogService.shared.start()
            NetworkReachability.shared.start()
            YouTubeTranscriptService.resetWebsiteDataStoreIfNeeded()
        }
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
            MainTabView()
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
                        SystemActionStore.shared.enqueue(systemAction)
                    } else if url.scheme == "castreader", url.host == "share-inbox" {
                        NotificationCenter.default.post(name: .castReaderShareInboxChanged, object: nil)
                    } else if url.scheme == "castreader", url.host == "pro" {
                        showSafariPro = true
                    } else if url.scheme == "castreader", url.host == "account" {
                        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                        let action = components?.queryItems?.first(where: { $0.name == "action" })?.value
                        if action == "signout" {
                            AuthService.shared.signOut()
                            SafariExtensionBridge.syncFromApp()
                            showSafariAccount = false
                        } else {
                            showSafariAccount = true
                        }
                    }
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
