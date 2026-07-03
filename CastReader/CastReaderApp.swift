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

    init() {
        // 简单的内存警告监听
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("⚠️ Memory warning received, clearing audio cache...")
            Task { @MainActor in
                AudioPlayerService.shared.clearQueue()
            }
        }

        // Pro 订阅状态 + 每日额度初始化
        Task { @MainActor in
            ProManager.shared.start()
            QuotaManager.shared.rollIfNewDay()
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
                QuotaManager.shared.rollIfNewDay()
                await ProManager.shared.refresh()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(visitorService)
                // 深色/浅色跟随系统（AppTheme 已全动态化，见 Utils/AppTheme.swift）
        }
    }
}
