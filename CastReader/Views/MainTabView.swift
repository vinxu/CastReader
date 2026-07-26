//
//  MainTabView.swift
//  CastReader
//
//  底部导航 [首页 | ➕ | 音色]：保留原首页与快速导入，只将设置 Tab 替换为音色。
//

import SwiftUI

/// How far the floating mini player currently reaches up into tab content.
///
/// Published from `MainTabView`, which is the only place that can measure both
/// edges, and consumed by each scrollable screen. It has to be consumed *inside*
/// the screen, directly on its ScrollView: a `safeAreaInset` applied outside a
/// `NavigationView`/`NavigationStack` — whether on the tab's root view or on the
/// TabView itself — never reaches the scroll view inside it. Both earlier
/// attempts failed for exactly that reason and left the last rows unreachable
/// under the player.
@MainActor
final class BottomOverlayMetrics: ObservableObject {
    static let shared = BottomOverlayMetrics()
    @Published private(set) var height: CGFloat = 0

    func update(_ newValue: CGFloat) {
        guard abs(height - newValue) > 0.5 else { return }
        height = newValue
    }
}

extension View {
    /// Apply to a scrollable view so its content can clear the mini player.
    /// Must be inside the screen's navigation container.
    func reservesMiniPlayerSpace() -> some View {
        modifier(MiniPlayerSpaceReserver())
    }
}

private struct MiniPlayerSpaceReserver: ViewModifier {
    @ObservedObject private var metrics = BottomOverlayMetrics.shared

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear
                .frame(height: metrics.height)
                .accessibilityHidden(true)
        }
    }
}

/// Top edge of the floating mini player, in the root coordinate space.
/// Absent when no player is showing.
private struct MiniPlayerTopKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

/// Bottom edge of a tab's content area (i.e. the top of the tab bar), in the
/// same space. Measured rather than assumed so no tab-bar height constant is
/// needed.
private struct TabContentBottomKey: PreferenceKey {
    static var defaultValue: CGFloat?
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

struct MainTabView: View {
    /// Where the floating player sits. Purely visual — the space tab content
    /// gives up for it is measured, not derived from this number, so the two can
    /// no longer drift apart.
    private static let miniPlayerBottomPadding: CGFloat = 68
    private static let rootSpace = "mainTabRoot"

    @StateObject private var coordinator = PlayerCoordinator()
    @StateObject private var kindleCenter = KindlePlaybackCenter.shared
    @StateObject private var clipboard = ClipboardImportViewModel()
    @StateObject private var importRouter = ImportRouter()
    @StateObject private var voiceCloneAccess = VoiceCloneAccessCoordinator.shared
    @StateObject private var playbackVoicePanel = PlaybackVoicePanelCenter.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab: Int
    @State private var miniPlayerTop: CGFloat?
    @State private var tabContentBottom: CGFloat?
    @State private var isImportingSharedContent = false
    @State private var shareInboxItems: [ShareInboxItem] = []
    @State private var shareInboxUnreadCount = 0
    @State private var shareInboxErrors: [UUID: String] = [:]
    @State private var shareInboxMetadataLoadingIDs: Set<UUID> = []
    @State private var showShareInbox = false

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
                HomeView(
                    shareInboxUnreadCount: shareInboxUnreadCount,
                    onOpenShareInbox: {
                        reloadShareInbox(showWhenPending: false)
                        markShareInboxSeen()
                        showShareInbox = true
                    }
                )
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
                VoiceBrowserView(presentation: .tab)
                    .tabItem { Label("音色", systemImage: "waveform") }
                    .tag(2)
            }
            // Zero-height probe: reserves nothing, only reports where a tab's
            // content actually ends (the top of the tab bar) so the overlap can
            // be measured instead of guessed. The reservation itself happens
            // inside each screen — see `reservesMiniPlayerSpace()`.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TabContentBottomKey.self,
                        value: proxy.frame(in: .named(Self.rootSpace)).maxY
                    )
                }
                .frame(height: 0)
                .accessibilityHidden(true)
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
            if !importRouter.hideMainChrome {
                if coordinator.showsMiniPlayer {
                    MiniPlayerView(coordinator: coordinator)
                        .padding(.bottom, Self.miniPlayerBottomPadding)
                        .background(miniPlayerTopReporter)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else if kindleCenter.showsMiniPlayer {
                    KindleMiniPlayerView(center: kindleCenter)
                        .padding(.bottom, Self.miniPlayerBottomPadding)
                        .background(miniPlayerTopReporter)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
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

            // Kindle reader follows the same keep-alive model as ReaderHostView:
            // minimizing moves it offscreen instead of removing its WKWebView.
            // This keeps semantic page turns, TTS generation and playback alive
            // for Mini Player/background use, while preserving the exact page.
            if let model = kindleCenter.model {
                KindleBookView(model: model)
                    .id(ObjectIdentifier(model))
                    .offset(y: kindleCenter.isPresented ? 0 : UIScreen.main.bounds.height)
                    .allowsHitTesting(kindleCenter.isPresented)
                    .transition(.move(edge: .bottom))
                    .animation(.spring(response: 0.4, dampingFraction: 0.9), value: kindleCenter.isPresented)
                    .zIndex(11)
            }

            // Player voice selection is an in-app overlay, not a system sheet.
            // This keeps ReaderHost/Kindle WKWebView geometry completely stable
            // while the user previews or switches voices.
            PlaybackVoicePanelOverlay(center: playbackVoicePanel)
                .zIndex(100)

        }
        .coordinateSpace(name: Self.rootSpace)
        .onPreferenceChange(MiniPlayerTopKey.self) { value in
            miniPlayerTop = value
            publishOverlap()
        }
        .onPreferenceChange(TabContentBottomKey.self) { value in
            tabContentBottom = value
            publishOverlap()
        }
        .environmentObject(coordinator)
        .environmentObject(importRouter)
        .toolbar(importRouter.hideMainChrome ? .hidden : .visible, for: .tabBar)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.showsMiniPlayer)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: kindleCenter.showsMiniPlayer)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: importRouter.hideMainChrome)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: playbackVoicePanel.isPresented)
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                clipboard.check()   // 进 App / 回前台 → 探测剪贴板
                reloadShareInbox(showWhenPending: false)
            }
        }
        .task {
            reloadShareInbox(showWhenPending: false)
        }
        .onReceive(NotificationCenter.default.publisher(for: .castReaderShareInboxChanged)) { _ in
            reloadShareInbox(showWhenPending: true)
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
        .sheet(isPresented: $showShareInbox) {
            ShareInboxView(
                items: shareInboxItems,
                errors: shareInboxErrors,
                isProcessing: isImportingSharedContent,
                onRead: { openSharedItem($0, mode: .read) },
                onExplain: { openSharedItem($0, mode: .explain) },
                onDelete: deleteSharedItem
            )
        }
        .sheet(item: voiceClonePromptBinding) { prompt in
            switch prompt {
            case .signIn:
                LoginView()
            case .paywall:
                PaywallView(analyticsTrigger: "voice_clone", analyticsSurface: "voice_clone")
            case .message(let message):
                NavigationStack {
                    ContentUnavailableView("声音克隆", systemImage: "waveform.badge.exclamationmark", description: Text(message))
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("完成") { voiceCloneAccess.prompt = nil }
                            }
                        }
                }
            }
        }
    }

    private var voiceClonePromptBinding: Binding<VoiceCloneAccessCoordinator.Prompt?> {
        Binding(
            get: { Constants.Features.voiceCloningEnabled ? voiceCloneAccess.prompt : nil },
            set: { voiceCloneAccess.prompt = Constants.Features.voiceCloningEnabled ? $0 : nil }
        )
    }

    private var miniPlayerTopReporter: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: MiniPlayerTopKey.self,
                value: proxy.frame(in: .named(Self.rootSpace)).minY
            )
        }
    }

    /// How far the floating player reaches up into the tab's content area.
    /// Both edges are measured in the same coordinate space, so this stays
    /// correct if the player's height, its padding, or the tab bar ever change.
    private func publishOverlap() {
        guard let top = miniPlayerTop, let bottom = tabContentBottom else {
            BottomOverlayMetrics.shared.update(0)
            return
        }
        BottomOverlayMetrics.shared.update(max(0, bottom - top))
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
        .accessibilityLabel(Text(AppLocalized("导入内容")))
        .offset(y: 4)
    }

    /// 剪贴板选朗读/解读 → 构建文档 → 进入对应播放（autoplay 直接开播，链路最短）。
    private func handleClipboard(_ kind: ClipboardImportViewModel.Kind, mode: ReaderMode) {
        clipboard.consume()
        guard let content = clipboard.read(kind) else { return }   // 用户确认后才读取剪贴板（系统弹一次 Allow Paste）；拒绝→nil
        let format: AnalyticsContentFormat
        switch content {
        case .url: format = .web
        case .text: format = .text
        case .image: format = .photo
        }
        let analyticsContext = ProductAnalytics.shared.beginContentIntent(
            source: .clipboard,
            format: format,
            entryPoint: "clipboard_prompt",
            intendedMode: mode == .read ? "read" : "explain"
        )
        switch content {
        case .url(let s):
            if let doc = DocumentBuilder.fromWebURL(s) {
                coordinator.open(doc, mode: mode, autoplay: true, analyticsContext: analyticsContext)
            } else {
                ProductAnalytics.shared.contentFailed(analyticsContext, stage: "validation", code: "invalid_url")
            }
        case .text(let t):
            let doc = DocumentBuilder.fromPlainText(t, title: AppLocalized("剪贴板文本"))
            if !doc.isEmpty {
                coordinator.open(doc, mode: mode, autoplay: true, analyticsContext: analyticsContext)
            } else {
                ProductAnalytics.shared.contentFailed(analyticsContext, stage: "parse", code: "empty_content")
            }
        case .image(let img):
            Task { @MainActor in
                let cap = CaptureFlowViewModel()
                await cap.process(image: img)
                if let doc = cap.document {
                    coordinator.open(doc, mode: mode, autoplay: true, analyticsContext: analyticsContext)
                } else {
                    ProductAnalytics.shared.contentFailed(
                        analyticsContext,
                        stage: "ocr",
                        code: cap.error == nil ? "empty_content" : "recognition_failed"
                    )
                }
            }
        }
    }

    private func reloadShareInbox(showWhenPending: Bool) {
        let pending = ShareInboxStore.pending()
        shareInboxItems = pending.map {
            ShareInboxItem(record: $0.record, metadataURL: $0.metadataURL)
        }
        shareInboxUnreadCount = ShareInboxStore.unreadCount(in: pending.map(\.record))
        scheduleShareInboxMetadataHydration()
        if showWhenPending && !shareInboxItems.isEmpty {
            showShareInbox = true
        }
    }

    private func scheduleShareInboxMetadataHydration() {
        let candidates = shareInboxItems.filter { item in
            item.record.kind == .url
                && item.record.linkMetadataFetchedAt == nil
                && !shareInboxMetadataLoadingIDs.contains(item.id)
        }
        for item in candidates {
            shareInboxMetadataLoadingIDs.insert(item.id)
            Task { @MainActor in
                let metadata: ShareInboxLinkMetadata?
                if let source = item.record.sourceURL.flatMap(URL.init(string:)) {
                    metadata = await ShareInboxLinkMetadataLoader.fetch(for: source)
                } else {
                    metadata = nil
                }
                _ = try? ShareInboxStore.updateLinkMetadata(
                    for: item.record,
                    metadataURL: item.metadataURL,
                    title: metadata?.title,
                    previewImageData: metadata?.previewImageData
                )
                shareInboxMetadataLoadingIDs.remove(item.id)
                reloadShareInbox(showWhenPending: false)
            }
        }
    }

    private func markShareInboxSeen() {
        ShareInboxStore.markAllSeen(shareInboxItems.map(\.record))
        shareInboxUnreadCount = 0
    }

    private func deleteSharedItem(_ item: ShareInboxItem) {
        ShareInboxStore.remove(item.record, metadataURL: item.metadataURL)
        shareInboxErrors[item.id] = nil
        reloadShareInbox(showWhenPending: false)
    }

    /// Parsing, OCR, playback and explain stay in the containing app. App Group records remain
    /// in the content inbox after opening, so users can replay them and failures stay retryable;
    /// only the explicit Delete action removes the private payload.
    private func openSharedItem(_ pending: ShareInboxItem, mode: ReaderMode) {
        guard !isImportingSharedContent else { return }
        isImportingSharedContent = true
        let record = pending.record
        shareInboxErrors[record.id] = nil
        let format: AnalyticsContentFormat = switch record.kind {
        case .url: .web
        case .text: .text
        case .image: .photo
        case .pdf: .pdf
        case .epub: .epub
        case .docx: .docx
        }
        let analyticsContext = ProductAnalytics.shared.beginContentIntent(
            source: .shareSheet,
            format: format,
            entryPoint: "system_share_sheet",
            intendedMode: mode == .read ? "read" : "explain"
        )

        func complete(_ document: ReadingDocument?) {
            guard let document, !document.isEmpty || document.sourceKind.isWebRendered else {
                ProductAnalytics.shared.contentFailed(analyticsContext, stage: "parse", code: "empty_or_unsupported")
                shareInboxErrors[record.id] = AppLocalized("内容暂时无法打开，请重试")
                isImportingSharedContent = false
                return
            }
            isImportingSharedContent = false
            showShareInbox = false
            coordinator.open(document, mode: mode, autoplay: true, analyticsContext: analyticsContext)
        }

        switch record.kind {
        case .url:
            complete(record.sourceURL.flatMap(DocumentBuilder.fromWebURL))
        case .text:
            guard let url = ShareInboxStore.payloadURL(for: record),
                  let data = try? Data(contentsOf: url) else { complete(nil); return }
            let raw = String(data: data, encoding: .utf8) ?? ""
            let text: String
            if ["html", "htm"].contains(url.pathExtension.lowercased()),
               let attributed = try? NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html,
                              .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil
               ) {
                text = attributed.string
            } else {
                text = raw
            }
            complete(DocumentBuilder.fromPlainText(text, title: record.localizedDisplayTitle))
        case .pdf:
            guard let url = ShareInboxStore.payloadURL(for: record),
                  let data = try? Data(contentsOf: url) else { complete(nil); return }
            Task { @MainActor in
                let document = await DocumentBuilder.fromPDFWithOCR(
                    data: data,
                    title: record.localizedDisplayTitle,
                    fallbackTitle: record.localizedDisplayTitle
                )
                complete(document)
            }
        case .docx:
            guard let url = ShareInboxStore.payloadURL(for: record),
                  let data = try? Data(contentsOf: url) else { complete(nil); return }
            let title = DocumentBuilder.docxTitle(data: data) ?? record.localizedDisplayTitle
            complete(ReadingDocument(title: title, sourceKind: .docx, paragraphs: [], fileData: data))
        case .epub:
            guard let url = ShareInboxStore.payloadURL(for: record),
                  let data = try? Data(contentsOf: url) else { complete(nil); return }
            Task {
                let document = await Task.detached(priority: .userInitiated) {
                    DocumentBuilder.fromEPUB(data: data, title: record.localizedDisplayTitle)
                }.value
                await MainActor.run { complete(document) }
            }
        case .image:
            guard let url = ShareInboxStore.payloadURL(for: record),
                  let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { complete(nil); return }
            Task { @MainActor in
                let capture = CaptureFlowViewModel()
                await capture.process(image: image)
                if let document = capture.document {
                    complete(document)
                } else {
                    ProductAnalytics.shared.contentFailed(
                        analyticsContext,
                        stage: "ocr",
                        code: capture.error == nil ? "empty_content" : "recognition_failed"
                    )
                    shareInboxErrors[record.id] = AppLocalized("内容暂时无法打开，请重试")
                    isImportingSharedContent = false
                }
            }
        }
    }
}

private struct ShareInboxItem: Identifiable {
    let record: ShareInboxRecord
    let metadataURL: URL

    var id: UUID { record.id }
}

private struct ShareInboxView: View {
    let items: [ShareInboxItem]
    let errors: [UUID: String]
    let isProcessing: Bool
    let onRead: (ShareInboxItem) -> Void
    let onExplain: (ShareInboxItem) -> Void
    let onDelete: (ShareInboxItem) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView(
                        AppLocalized("接收箱是空的"),
                        systemImage: "tray",
                        description: Text(AppLocalized("从其他应用分享网页、文字、文档或图片到 CastReader，内容会保存在这里。"))
                    )
                } else {
                    List(items) { item in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 12) {
                                inboxArtwork(for: item.record)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.record.localizedDisplayTitle)
                                        .font(.headline)
                                        .lineLimit(2)
                                    if item.record.kind == .url,
                                       let source = item.record.sourceURL.flatMap(URL.init(string:)),
                                       let host = source.host?.replacingOccurrences(of: "www.", with: "") {
                                        Text(host)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(item.record.createdAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }

                            if let error = errors[item.id] {
                                Label(error, systemImage: "exclamationmark.circle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }

                            HStack(spacing: 10) {
                                Button(errors[item.id] == nil ? AppLocalized("朗读") : AppLocalized("重试")) {
                                    onRead(item)
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(isProcessing)

                                Button(AppLocalized("解读")) { onExplain(item) }
                                    .buttonStyle(.bordered)
                                    .disabled(isProcessing)

                                Spacer()

                                Button(role: .destructive) { onDelete(item) } label: {
                                    Image(systemName: "trash")
                                }
                                .disabled(isProcessing)
                                .accessibilityLabel(Text(AppLocalized("删除")))
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            .navigationTitle(AppLocalized("内容接收箱"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(AppLocalized("完成")) { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func inboxArtwork(for record: ShareInboxRecord) -> some View {
        if let url = ShareInboxStore.previewImageURL(for: record),
           let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 58, height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(AppTheme.surfaceVariant)
                .frame(width: 58, height: 58)
                .overlay {
                    Image(systemName: icon(for: record.kind))
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(AppTheme.primary)
                }
        }
    }

    private func icon(for kind: ShareInboxKind) -> String {
        switch kind {
        case .url: "link"
        case .text: "text.alignleft"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .epub: "books.vertical"
        case .docx: "doc.text"
        }
    }
}

struct SettingsToolbarButton: View {
    @State private var showSettings = false

    var body: some View {
        Button { showSettings = true } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityLabel(Text(AppLocalized("设置")))
        .accessibilityIdentifier("settingsGearButton")
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}
