//
//  MainTabView.swift
//  CastReader
//
//  底部导航 [首页 | ➕ | 设置]：首页（场景化批注本）· 中间凸起 ➕（通用导入弹层）· 设置（含文库入口）。
//

import SwiftUI

struct MainTabView: View {
    private static let miniPlayerBottomPadding: CGFloat = 68

    @StateObject private var coordinator = PlayerCoordinator()
    @StateObject private var kindleCenter = KindlePlaybackCenter.shared
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
                    .tabItem {
                        Image(uiImage: Self.plusTabImage)
                            .renderingMode(.original)
                        Text("")
                    }
                    .tag(1)
                SettingsView()
                    .tabItem { Label("设置", systemImage: "gearshape.fill") }
                    .tag(2)
            }
            .tint(AppTheme.primary)
            .onChange(of: selectedTab) { newTab in
                if newTab == 1 {
                    selectedTab = 0
                    importRouter.openQuickImport()
                }
            }

            if !importRouter.hideMainChrome {
                plusTapTarget
            }

            // Mini Player 悬浮在 tab bar 上方（有会话且阅读器收起时）
            if coordinator.showsMiniPlayer && !importRouter.hideMainChrome {
                MiniPlayerView(coordinator: coordinator)
                    .padding(.bottom, Self.miniPlayerBottomPadding)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if kindleCenter.showsMiniPlayer && !importRouter.hideMainChrome {
                KindleMiniPlayerView(center: kindleCenter)
                    .padding(.bottom, Self.miniPlayerBottomPadding)
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

            if let model = kindleCenter.model, kindleCenter.isPresented {
                KindleBookView(model: model)
                    .id(ObjectIdentifier(model))
                    .transition(.move(edge: .bottom))
                    .animation(.spring(response: 0.4, dampingFraction: 0.9), value: kindleCenter.isPresented)
                    .zIndex(11)
            }
        }
        .environmentObject(coordinator)
        .environmentObject(importRouter)
        .toolbar(importRouter.hideMainChrome ? .hidden : .visible, for: .tabBar)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.showsMiniPlayer)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: kindleCenter.showsMiniPlayer)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: importRouter.hideMainChrome)
        .onChange(of: scenePhase) { phase in
            if phase == .active { clipboard.check() }   // 进 App / 回前台 → 探测剪贴板
        }
        .onChange(of: kindleCenter.isPresented) { isPresented in
            if isPresented { coordinator.close() }
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

    private static let plusTabImage: UIImage = {
        let size = CGSize(width: 40, height: 40)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor(AppTheme.primary).setFill()
            context.cgContext.fillEllipse(in: rect)

            let path = UIBezierPath()
            path.lineWidth = 3.2
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: size.width / 2, y: 10.5))
            path.addLine(to: CGPoint(x: size.width / 2, y: size.height - 10.5))
            path.move(to: CGPoint(x: 10.5, y: size.height / 2))
            path.addLine(to: CGPoint(x: size.width - 10.5, y: size.height / 2))
            UIColor.white.setStroke()
            path.stroke()
        }
        return image.withRenderingMode(.alwaysOriginal)
    }()

    private var plusTapTarget: some View {
        Button {
            selectedTab = 0
            importRouter.openQuickImport()
        } label: {
            Color.clear
                .frame(width: 88, height: 58)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("plusImportButton")
        .accessibilityLabel(Text("导入内容"))
        .offset(y: 4)
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
