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
        // Local TTS model will be loaded on-demand when user starts reading
        // (in LocalTTSService.generateTTSForParagraph)
        // No need to pre-load at app startup

        // 简单的内存警告监听
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            print("⚠️ Memory warning received, clearing audio cache...")
            Task { @MainActor in
                PlayerViewModel.shared.clearAllAudioCache()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(visitorService)
        }
    }
}
