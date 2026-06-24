//
//  MainTabView.swift
//  CastReader
//
//  底部导航 [首页 | ➕ | 设置]：首页（场景化批注本）· 中间凸起 ➕（通用导入弹层）· 设置（含文库入口）。
//

import SwiftUI

struct MainTabView: View {
    @StateObject private var coordinator = PlayerCoordinator()
    @StateObject private var clipboard = ClipboardImportViewModel()
    @StateObject private var importRouter = ImportRouter()
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
                // 中间占位：被凸起 ➕ 覆盖；万一点到 tab item 也走通用导入并回首页。
                Color.clear
                    .tabItem { Label("", systemImage: "plus") }
                    .tag(1)
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
                    .tag(2)
            }
            .tint(AppTheme.primary)
            .onChange(of: selectedTab) { newTab in
                if newTab == 1 { selectedTab = 0; importRouter.requestGeneral() }
            }

            // 中间凸起 ➕：通用导入入口（scenario=null）。reader 展开时被其顶层覆盖，收起时显示。
            plusButton

            // Mini Player 悬浮在 tab bar 上方（有会话且阅读器收起时）
            if coordinator.showsMiniPlayer {
                MiniPlayerView(coordinator: coordinator)
                    .padding(.bottom, 50)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 阅读器常驻顶层（会话存活期间）：用上移/下移替代 fullScreenCover 的 present/dismiss，
            // View 永不重建 → 收起再展开保留滚动位置、UITextView registry、解读 mark（根治重建丢状态）。
            if let s = coordinator.session {
                ReaderHostView(readVM: s.readVM, explainVM: s.explainVM, coordinator: coordinator, document: s.document)
                    .id(s.id)   // 仅换文档（session 变）才重建；同文档收起/展开不重建
                    .offset(y: coordinator.isReaderPresented ? 0 : UIScreen.main.bounds.height)
                    .transition(.move(edge: .bottom))   // 首次 open / close 时从底部滑入滑出
                    .animation(.spring(response: 0.4, dampingFraction: 0.9), value: coordinator.isReaderPresented)
                    .zIndex(10)
            }
        }
        .environmentObject(coordinator)
        .environmentObject(importRouter)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.showsMiniPlayer)
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

    /// 中间凸起 ➕：点开通用导入弹层（切到首页承载）。
    private var plusButton: some View {
        Button {
            selectedTab = 0
            importRouter.requestGeneral()
        } label: {
            ZStack {
                Circle()
                    .fill(AppTheme.primary)
                    .frame(width: 56, height: 56)
                    .shadow(color: AppTheme.primary.opacity(0.4), radius: 8, y: 3)
                Image(systemName: "plus")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            }
        }
        .accessibilityIdentifier("plusImportButton")
        .accessibilityLabel(Text("导入内容"))
        .offset(y: -6)
        .allowsHitTesting(!coordinator.isReaderPresented)   // 阅读器展开时不拦截（其实已被顶层覆盖）
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
