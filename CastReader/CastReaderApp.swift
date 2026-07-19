//
//  CastReaderApp.swift
//  CastReader
//
//  Created by 许旭恒 on 1/7/26.
//

import SwiftUI

@main
struct CastReaderApp: App {
    @StateObject private var visitorService = VisitorService.shared
    @StateObject private var appLanguage = AppLanguageManager.shared
    @State private var showSafariPro = false
    @State private var showSafariAccount = false

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
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(visitorService)
                .environment(\.locale, appLanguage.locale)
                // 深色/浅色跟随系统（AppTheme 已全动态化，见 Utils/AppTheme.swift）
                .onOpenURL { url in
                    if url.scheme == "castreader", url.host == "pro" {
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
                .sheet(isPresented: $showSafariAccount) {
                    if AuthService.shared.isSignedIn {
                        SettingsView()
                    } else {
                        LoginView()
                    }
                }
        }
    }
}
