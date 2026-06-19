//
//  MainTabView.swift
//  CastReader
//
//  三 Tab：首页（拍摄/上传/输入）· 文库（历史文档）· 设置。
//

import SwiftUI

struct MainTabView: View {
    @StateObject private var coordinator = PlayerCoordinator()
    @StateObject private var clipboard = ClipboardImportViewModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Int

    init() {
        _selectedTab = State(initialValue: 0)

        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor(AppTheme.background)
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor(AppTheme.mutedForeground)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [.foregroundColor: UIColor(AppTheme.mutedForeground)]
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(AppTheme.primary)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [.foregroundColor: UIColor(AppTheme.primary)]
        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView()
                    .tabItem { Label("首页", systemImage: "house.fill") }
                    .tag(0)
                LibraryView()
                    .tabItem { Label("文库", systemImage: "books.vertical.fill") }
                    .tag(1)
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
                    .tag(2)
            }
            .tint(AppTheme.primary)

            // Mini Player 悬浮在 tab bar 上方（有会话且阅读器收起时）
            if coordinator.showsMiniPlayer {
                MiniPlayerView(coordinator: coordinator)
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .environmentObject(coordinator)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.showsMiniPlayer)
        .fullScreenCover(isPresented: $coordinator.isReaderPresented) {
            if let s = coordinator.session {
                ReaderHostView(readVM: s.readVM, explainVM: s.explainVM, coordinator: coordinator, document: s.document)
            }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { clipboard.check() }   // 进 App / 回前台 → 探测剪贴板
        }
        .sheet(item: $clipboard.detected) { kind in
            ClipboardPromptView(
                kind: kind,
                onRead: { handleClipboard(kind, mode: .read) },
                onExplain: { handleClipboard(kind, mode: .explain) },
                onIgnore: { clipboard.consume() }
            )
            .presentationDetents([.height(290)])
        }
    }

    /// 剪贴板选朗读/解读 → 构建文档 → 进入对应播放（autoplay 直接开播，链路最短）。
    private func handleClipboard(_ kind: ClipboardImportViewModel.Kind, mode: ReaderMode) {
        clipboard.consume()
        guard let content = clipboard.read(kind) else { return }   // 用户确认后才读取剪贴板（系统弹一次 Allow Paste）；拒绝→nil
        switch content {
        case .url(let s):
            if let doc = DocumentBuilder.fromWebURL(s) { coordinator.open(doc, mode: mode, autoplay: true) }
        case .text(let t):
            let doc = DocumentBuilder.fromPlainText(t, title: String(localized: "剪贴板文本"))
            if !doc.isEmpty { coordinator.open(doc, mode: mode, autoplay: true) }
        case .image(let img):
            Task { @MainActor in
                let cap = CaptureFlowViewModel()
                await cap.process(image: img)
                if let doc = cap.document { coordinator.open(doc, mode: mode, autoplay: true) }
            }
        }
    }
}
