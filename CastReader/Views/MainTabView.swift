//
//  MainTabView.swift
//  CastReader
//
//  底部导航 [首页 | ➕ | 音色]：保留原首页与快速导入，只将设置 Tab 替换为音色。
//

import StoreKit
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

    private enum LibraryOnboardingPostDismissAction {
        case kindleBook(KindleBook)
        case wereadBook(WeReadBook)
        case restoreClipboard
    }

    private struct LibraryConnectionRoute: Identifiable, Equatable {
        let source: BoundLibraryOnboardingSource
        let analyticsSession: AnalyticsLibraryConnectionSession

        var id: String { analyticsSession.bindSessionId }
    }

    @StateObject private var coordinator = PlayerCoordinator()
    @StateObject private var kindleCenter = KindlePlaybackCenter.shared
    @StateObject private var clipboard = ClipboardImportViewModel()
    @StateObject private var importRouter = ImportRouter()
    @StateObject private var voiceCloneAccess = VoiceCloneAccessCoordinator.shared
    @StateObject private var playbackVoicePanel = PlaybackVoicePanelCenter.shared
    @StateObject private var captionLanguageSwitcher = YouTubeCaptionLanguageSwitcher.shared
    @StateObject private var libraryOnboarding = BoundLibraryOnboardingStore.shared
    @StateObject private var reviewPrompt = AppReviewPromptManager.shared
    @StateObject private var studyBoostRouter = StudyBoostRouter.shared
    @StateObject private var youtubeRouteCenter = YouTubeRouteCenter.shared
    @ObservedObject private var audioPlayer = AudioPlayerService.shared
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @State private var selectedTab: Int
    @State private var miniPlayerTop: CGFloat?
    @State private var tabContentBottom: CGFloat?
    @State private var isImportingSharedContent = false
    @State private var shareInboxItems: [ShareInboxItem] = []
    @State private var shareInboxUnreadCount = 0
    @State private var shareInboxErrors: [UUID: String] = [:]
    @State private var shareInboxMetadataLoadingIDs: Set<UUID> = []
    @State private var shareInboxImportTask: Task<Void, Never>?
    @State private var showShareInbox = false
    @State private var pendingLibraryOnboardingAction: LibraryOnboardingPostDismissAction?
    /// 区域的权威判据是否已就绪。首启引导要等它，避免呈现错版本的引导。
    @State private var isRegionResolved = AppRegion.isAuthoritative
    @State private var reviewRequestTask: Task<Void, Never>?
    @State private var systemActionTask: Task<Void, Never>?
    @State private var systemActionNotice: String?
    @State private var systemCloudFailure: CloudHistoryFailurePresentation?
    @State private var systemCloudFailureMode: CastReaderIntentMode = .read
    @State private var libraryConnectionPresentationTask: Task<Void, Never>?
    @State private var activeLibraryConnection: LibraryConnectionRoute?
    @State private var pendingLibraryConnection: LibraryConnectionRoute?
    @State private var homeBlocksReviewPresentation = false
    @State private var youtubeExtractionPresentation: YouTubeExtractionPresentation?
    @State private var youtubeExtractionTask: Task<Void, Never>?
    @State private var youtubePresentationWaitTask: Task<Void, Never>?
    @State private var activeYouTubeRequestID: UUID?
    @State private var showYouTubeShareAha = false
    @State private var pendingYouTubeShareAhaSessionKey: String?
    @State private var pendingYouTubePlaybackAcceptance: YouTubeDurablePlaybackAcceptance?
    @AppStorage("youtube.didShowShareAha") private var didShowYouTubeShareAha = false

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
        presentationContent
    }

    private var mainContent: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeView(
                    shareInboxUnreadCount: shareInboxUnreadCount,
                    isSurfaceActive: selectedTab == 0
                        && !coordinator.isReaderPresented,
                    onOpenShareInbox: {
                        reloadShareInbox(showWhenPending: false)
                        markShareInboxSeen()
                        showShareInbox = true
                    },
                    onReviewPresentationBlockedChanged: {
                        homeBlocksReviewPresentation = $0
                    },
                    onRequestLibraryConnection: {
                        requestLibraryConnection(
                            $0,
                            entryPoint: "library_onboarding_reminder"
                        )
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

            if studyBoostRouter.isPresented {
                StudyBoostView(
                    onStartStudy: startStudyBoostImport,
                    onClose: studyBoostRouter.dismiss
                )
                .zIndex(200)
            }

            if let youtubeExtractionPresentation {
                YouTubeExtractionOverlay(
                    presentation: youtubeExtractionPresentation,
                    cancel: cancelYouTubeExtraction,
                    retry: {
                        beginYouTubeExtraction(
                            youtubeExtractionPresentation.request
                        )
                    }
                )
                .transition(.opacity)
                .zIndex(300)
            }

            if let transcript = presentedCaptionLanguageTranscript {
                YouTubeCaptionLanguagePanelOverlay(
                    switcher: captionLanguageSwitcher,
                    transcript: transcript,
                    select: switchYouTubeCaptionLanguage
                )
                .zIndex(310)
            }

            if let targetLanguage = captionLanguageSwitcher.phase.overlayLanguage {
                YouTubeCaptionLanguageSwitchOverlay(
                    targetLanguage: targetLanguage,
                    cancel: captionLanguageSwitcher.cancel
                )
                .transition(.opacity)
                .zIndex(320)
            }

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
        .onReceive(importRouter.$cloudReconnectRequest.compactMap { $0 }) { _ in
            selectedTab = 0
        }
        .toolbar(importRouter.hideMainChrome ? .hidden : .visible, for: .tabBar)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: coordinator.showsMiniPlayer)
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: kindleCenter.showsMiniPlayer)
        .animation(.spring(response: 0.32, dampingFraction: 0.9), value: importRouter.hideMainChrome)
        .animation(.spring(response: 0.34, dampingFraction: 0.9), value: playbackVoicePanel.isPresented)
        .animation(.spring(response: 0.38, dampingFraction: 0.9), value: studyBoostRouter.isPresented)
        .animation(
            .spring(response: 0.34, dampingFraction: 0.9),
            value: captionLanguageSwitcher.isPickerPresented
        )
        .alert(
            AppLocalized("切换字幕语言失败"),
            isPresented: captionLanguageFailureBinding
        ) {
            Button(AppLocalized("好的"), role: .cancel) {
                captionLanguageSwitcher.failureMessage = nil
            }
        } message: {
            Text(captionLanguageSwitcher.failureMessage ?? "")
        }
    }

    private var lifecycleContent: some View {
        mainContent
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                reviewPrompt.recordActiveDay()
                ResumeReminderManager.shared.appBecameActive()   // 取消待发召回 + 时机成熟则请求通知权限
                let routedYouTube = routePendingYouTubeIfAvailable()
                let routedSystemAction = routedYouTube
                    ? false
                    : routePendingSystemActionIfAvailable()
                if !routedYouTube,
                   !routedSystemAction,
                   !libraryOnboarding.isChooserPresented {
                    clipboard.check()   // 进 App / 回前台 → 探测剪贴板
                }
                reloadShareInbox(showWhenPending: false)
            }
        }
        .task {
            reviewPrompt.recordActiveDay()
            reloadShareInbox(showWhenPending: false)
            if !routePendingYouTubeIfAvailable() {
                routePendingSystemActionIfAvailable()
            }
            restartReviewRequestMonitor()
        }
        .task {
            // 首启引导要按发行区域分派两套完全不同的界面，所以先把 storefront
            // 解析出来。已就绪时这里立即返回，不会拖慢冷启动。
            guard !isRegionResolved else { return }
            _ = await AppRegion.awaitAuthoritative()
            isRegionResolved = true
        }
        .onChange(of: reviewOpportunityState) {
            restartReviewRequestMonitor()
        }
        .onChange(of: coordinator.session?.id) { sessionID in
            guard let pending = pendingYouTubePlaybackAcceptance,
                  pending.contentSessionKey != sessionID else { return }
            youtubeRouteCenter.releaseWithoutAcknowledgement(pending.request)
            pendingYouTubePlaybackAcceptance = nil
            if pendingYouTubeShareAhaSessionKey == pending.contentSessionKey {
                pendingYouTubeShareAhaSessionKey = nil
            }
        }
        .onDisappear(perform: handleMainTabDisappear)
        .onReceive(NotificationCenter.default.publisher(for: .castReaderSystemActionPending)) { _ in
            Task { @MainActor in
                routePendingSystemActionIfAvailable()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .castReaderShareInboxChanged)) { _ in
            reloadShareInbox(showWhenPending: true)
        }
        .onReceive(youtubeRouteCenter.$request.compactMap { $0 }) { request in
            guard scenePhase == .active else { return }
            beginYouTubeExtraction(request)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .castReaderYouTubePlaybackConfirmed
            )
        ) { notification in
            guard let sessionKey = notification.object as? String else { return }
            if let pending = pendingYouTubePlaybackAcceptance,
               pending.matches(sessionKey) {
                pendingYouTubePlaybackAcceptance = nil
                youtubeRouteCenter.acknowledge(pending.request)
                scheduleNextPendingYouTubeHandoff()
            }
            if !didShowYouTubeShareAha,
               pendingYouTubeShareAhaSessionKey == sessionKey {
                pendingYouTubeShareAhaSessionKey = nil
                didShowYouTubeShareAha = true
                showYouTubeShareAha = true
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .castReaderLibraryConnectedForReview
            )
        ) { _ in
            reviewPrompt.recordPositiveOutcome(.libraryConnected)
        }
        // Legacy reader recovery paths still post these notifications. MainTab
        // is the stable presentation owner; invisible Home sections no longer
        // race to present their own sheets.
        .onReceive(NotificationCenter.default.publisher(for: .castReaderKindleRebindRequested)) { _ in
            requestLibraryConnection(.kindle, entryPoint: "reader_reconnect")
        }
        .onReceive(NotificationCenter.default.publisher(for: .castReaderWeReadRebindRequested)) { _ in
            requestLibraryConnection(.weread, entryPoint: "reader_reconnect")
        }
        .onReceive(NotificationCenter.default.publisher(for: .castReaderGoogleBooksRebindRequested)) { _ in
            requestLibraryConnection(.googleBooks, entryPoint: "reader_reconnect")
        }
        .onReceive(NotificationCenter.default.publisher(for: .castReaderKoboRebindRequested)) { _ in
            requestLibraryConnection(.kobo, entryPoint: "reader_reconnect")
        }
        .onReceive(NotificationCenter.default.publisher(for: .castReaderOReillyRebindRequested)) { _ in
            requestLibraryConnection(.oreilly, entryPoint: "reader_reconnect")
        }
        .onChange(of: kindleCenter.isPresented) { isPresented in
            if isPresented { coordinator.close() }
        }
    }

    private var presentationContent: some View {
        lifecycleContent
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
        .sheet(
            item: $activeLibraryConnection,
            onDismiss: presentPendingLibraryConnectionWhenReady
        ) { route in
            libraryConnectionView(for: route)
        }
        .fullScreenCover(
            isPresented: libraryOnboardingPresentation,
            onDismiss: handleLibraryOnboardingDismissal
        ) {
            // 中国区强绑定微信读书（四屏），其余地区保持 Kindle 五屏引导不变。
            if AppRegion.current == .cn {
                WeReadFirstLaunchFlowView(
                    onboarding: libraryOnboarding,
                    onSkip: handleLibraryOnboardingPostpone,
                    onStartBook: handleWeReadOnboardingStartBook
                )
                .interactiveDismissDisabled()
            } else {
                KindleFirstLaunchFlowView(
                    onboarding: libraryOnboarding,
                    onSkip: handleLibraryOnboardingPostpone,
                    onStartBook: handleKindleOnboardingStartBook
                )
                .interactiveDismissDisabled()
            }
        }
        .alert(
            AppLocalized("以后在 YouTube 里点分享，就能直接听字幕稿。"),
            isPresented: $showYouTubeShareAha
        ) {
            Button(AppLocalized("好"), role: .cancel) {}
        } message: {
            Text(AppLocalized("在视频的分享面板里选择 CastReader；字幕可用时会直接进入朗读。"))
        }
        .alert(
            CloudLocalized("提示"),
            isPresented: Binding(
                get: { systemActionNotice != nil || systemCloudFailure != nil },
                set: {
                    if !$0 {
                        systemActionNotice = nil
                        systemCloudFailure = nil
                    }
                }
            )
        ) {
            systemActionAlertActions
        } message: {
            Text(systemCloudFailure?.message ?? systemActionNotice ?? "")
        }
    }

    @ViewBuilder
    private var systemActionAlertActions: some View {
        if let failure = systemCloudFailure {
            switch failure.recovery {
            case .reconnect:
                Button(CloudLocalized("连接账号")) {
                    recoverSystemCloudFailure(failure)
                }
                Button(CloudLocalized("取消"), role: .cancel) {}
            case .removeRecord:
                Button(CloudLocalized("从历史记录移除"), role: .destructive) {
                    recoverSystemCloudFailure(failure)
                }
                Button(CloudLocalized("取消"), role: .cancel) {}
            case .retry:
                Button(CloudLocalized("重试")) {
                    recoverSystemCloudFailure(failure)
                }
                Button(CloudLocalized("取消"), role: .cancel) {}
            case .dismiss:
                Button(CloudLocalized("好"), role: .cancel) {}
            }
        } else {
            Button(CloudLocalized("好"), role: .cancel) {}
        }
    }

    private func handleMainTabDisappear() {
        if let interruptedRequest = youtubeExtractionPresentation?.request {
            youtubeRouteCenter.releaseWithoutAcknowledgement(interruptedRequest)
        }
        if let pending = pendingYouTubePlaybackAcceptance {
            youtubeRouteCenter.releaseWithoutAcknowledgement(pending.request)
            pendingYouTubePlaybackAcceptance = nil
        }
        reviewRequestTask?.cancel()
        reviewRequestTask = nil
        systemActionTask?.cancel()
        systemActionTask = nil
        shareInboxImportTask?.cancel()
        shareInboxImportTask = nil
        libraryConnectionPresentationTask?.cancel()
        libraryConnectionPresentationTask = nil
        youtubeExtractionTask?.cancel()
        youtubeExtractionTask = nil
        youtubePresentationWaitTask?.cancel()
        youtubePresentationWaitTask = nil
        YouTubeTranscriptService.shared.cancel()
    }

    private var libraryOnboardingPresentation: Binding<Bool> {
        Binding(
            // 等区域的权威判据（App Store storefront）就绪再呈现引导。
            // 否则首次安装时只有时区兜底可用，人在中国大陆出差的海外用户会先
            // 闪一下微信读书引导再跳回 Kindle 引导。最多等 2 秒，超时按兜底值走。
            get: { isRegionResolved && libraryOnboarding.isChooserPresented },
            set: { presented in
                if presented {
                    libraryOnboarding.presentChooser()
                } else {
                    libraryOnboarding.dismissChooser()
                }
            }
        )
    }

    private var reviewOpportunityState: AppReviewPresentationGate {
        AppReviewPresentationGate(
            pending: reviewPrompt.isPending,
            appIsActive: scenePhase == .active,
            isHome: selectedTab == 0,
            playbackIsQuiescent: audioPlayer.isQuiescentForReviewPrompt,
            readerIsHidden: !coordinator.isReaderPresented,
            kindleReaderIsHidden: !kindleCenter.isPresented,
            importChromeIsVisible: !importRouter.hideMainChrome,
            homeIsIdle: !homeBlocksReviewPresentation
                && !studyBoostRouter.isPresented
                && activeLibraryConnection == nil
                && pendingLibraryConnection == nil
                && youtubeExtractionPresentation == nil,
            clipboardSheetIsHidden: clipboard.detected == nil,
            shareInboxIsHidden: !showShareInbox,
            voiceCloneSheetIsHidden: voiceCloneAccess.prompt == nil,
            voicePanelIsHidden: !playbackVoicePanel.isPresented,
            onboardingIsHidden: !libraryOnboarding.isChooserPresented
        )
    }

    private func startStudyBoostImport() {
        playbackVoicePanel.dismiss()
        if coordinator.isReaderPresented { coordinator.minimize() }
        if kindleCenter.isPresented { kindleCenter.minimize() }
        selectedTab = 0
        studyBoostRouter.dismiss()
        DispatchQueue.main.async {
            importRouter.openStudyBoostImport()
        }
    }

    /// Consumes either an already-routed deep link or the oldest Share
    /// Extension handoff. The App Group queue is authoritative because iOS does
    /// not guarantee that a Share Extension can foreground its containing app.
    @discardableResult
    private func routePendingYouTubeIfAvailable() -> Bool {
        guard scenePhase == .active else { return false }
        if let request = youtubeRouteCenter.request {
            beginYouTubeExtraction(request)
            return true
        }
        guard let pending = YouTubePendingLinkStore.peekNext() else { return false }
        return youtubeRouteCenter.open(
            pending.rawURL,
            entry: pending.entry,
            pendingItemID: pending.id
        )
    }

    private func beginYouTubeExtraction(_ request: YouTubeListenRequest) {
        // Deep-link publishers can fire while the scene is still inactive.
        // Leave the request unconsumed until the foreground routing pass so an
        // extraction never starts invisibly behind system presentation.
        guard scenePhase == .active else { return }
        if activeYouTubeRequestID == request.id,
           youtubeExtractionTask != nil {
            return
        }

        // The extraction overlay lives below UIKit sheets/covers. Clear
        // app-owned blockers, then wait for their dismissal animation before
        // consuming the route so first-launch shares cannot autoplay invisibly.
        selectedTab = 0
        showShareInbox = false
        clipboard.consume()
        playbackVoicePanel.dismiss()
        studyBoostRouter.dismiss()
        voiceCloneAccess.prompt = nil
        pendingLibraryConnection = nil
        activeLibraryConnection = nil
        libraryConnectionPresentationTask?.cancel()
        libraryConnectionPresentationTask = nil
        if libraryOnboarding.isChooserPresented {
            pendingLibraryOnboardingAction = nil
            libraryOnboarding.postpone()
        }
        if hasBlockingSystemPresentation {
            youtubePresentationWaitTask?.cancel()
            youtubePresentationWaitTask = Task { @MainActor in
                while !Task.isCancelled {
                    guard scenePhase == .active else { return }
                    if !hasBlockingSystemPresentation,
                       !libraryOnboarding.isChooserPresented {
                        youtubePresentationWaitTask = nil
                        beginYouTubeExtraction(request)
                        return
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            return
        }
        youtubePresentationWaitTask?.cancel()
        youtubePresentationWaitTask = nil

        youtubeExtractionTask?.cancel()
        YouTubeTranscriptService.shared.cancel()
        pendingYouTubeShareAhaSessionKey = nil
        activeYouTubeRequestID = request.id
        youtubeExtractionPresentation = .loading(request)
        youtubeRouteCenter.consume(request.id)
        if request.entry != .history {
            ProductAnalytics.shared.track(
                .youtubeShareReceived,
                context: AnalyticsEventContext(
                    productArea: .reader,
                    surface: "youtube_entry",
                    entryPoint: "youtube_\(request.entry.rawValue)"
                ),
                properties: .init(entry: request.entry.rawValue)
            )
        }

        let analyticsContext = ProductAnalytics.shared.beginContentIntent(
            source: .youtubeIOS,
            format: .youtube,
            entryPoint: "youtube_\(request.entry.rawValue)",
            intendedMode: "read"
        )
        let startedAt = Date()

        youtubeExtractionTask = Task { @MainActor in
            do {
                // Fresh TTS starts only after the final paragraph/resume target
                // is known. ReadAloudViewModel already streams its first audio
                // segment immediately; an off-player full-paragraph prewarm
                // delayed first sound and could probe the wrong resume paragraph.
                let result = try await resolveYouTubeTranscript(for: request)
                try Task.checkCancellation()
                guard activeYouTubeRequestID == request.id else { return }

                if !result.cacheHit {
                    ProductAnalytics.shared.track(
                        .youtubeExtractDone,
                        context: AnalyticsEventContext(
                            productArea: .reader,
                            surface: "youtube_extract",
                            entryPoint: analyticsContext.entryPoint,
                            contentSessionId: analyticsContext.contentSessionId
                        ),
                        properties: .init(
                            language: result.transcript.track.languageCode,
                            cueCount: result.transcript.cues.count,
                            paragraphCount: result.transcript.paragraphs.count,
                            elapsedMs: max(
                                0,
                                Int(Date().timeIntervalSince(startedAt) * 1_000)
                            ),
                            warmSession: YouTubeTranscriptService.shared
                                .lastExtractionServedFromWarmSession
                        )
                    )
                }

                let document = YouTubeReadingDocumentBuilder.make(
                    transcript: result.transcript,
                    cacheHit: result.cacheHit
                )
                if let current = coordinator.session?.document,
                   current.id == document.id,
                   current.contentSessionKey != document.contentSessionKey {
                    coordinator.close()
                }
                coordinator.open(
                    document,
                    mode: .read,
                    autoplay: false,
                    analyticsContext: analyticsContext
                )
                let durableAcceptance = YouTubeDurablePlaybackAcceptance(
                    request: request,
                    contentSessionKey: document.contentSessionKey
                )
                let didStart = await startYouTubePlayback(
                    request: request,
                    transcript: result.transcript,
                    cacheKey: result.cacheKey,
                    durableAcceptance: durableAcceptance
                )
                guard didStart else {
                    youtubeRouteCenter.releaseWithoutAcknowledgement(request)
                    throw CancellationError()
                }
                cacheYouTubeThumbnailIfNeeded(
                    result.transcript.metadata.thumbnailURL,
                    key: result.cacheKey
                )

                youtubeExtractionPresentation = nil
                activeYouTubeRequestID = nil
                youtubeExtractionTask = nil
                if durableAcceptance == nil {
                    youtubeRouteCenter.acknowledge(request)
                    scheduleNextPendingYouTubeHandoff()
                }
            } catch is CancellationError {
                finishCancelledYouTubeRequest(request.id)
            } catch let failure as YouTubeTranscriptFailure {
                handleYouTubeExtractionFailure(
                    failure,
                    request: request,
                    analyticsContext: analyticsContext
                )
            } catch {
                handleYouTubeExtractionFailure(
                    .network,
                    request: request,
                    analyticsContext: analyticsContext
                )
            }
        }
    }

    private struct YouTubeTranscriptResolution {
        let transcript: YouTubeTranscriptDocument
        let cacheKey: YouTubeTranscriptCacheKey
        let cacheHit: Bool
    }

    private func resolveYouTubeTranscript(
        for request: YouTubeListenRequest
    ) async throws -> YouTubeTranscriptResolution {
        let cache = YouTubeCacheProvider.shared
        let immediate: YouTubeCachedTranscriptResolution?
        if request.entry == .history {
            immediate = await cache?.mostRecentTranscript(
                videoId: request.reference.videoId
            )
        } else {
            immediate = await cache?.mostRecentPreferredTranscript(
                videoId: request.reference.videoId,
                preferredLanguage: preferredYouTubeCaptionLanguage
            )
        }
        let usableImmediate: YouTubeCachedTranscriptResolution? = immediate.flatMap {
            candidate -> YouTubeCachedTranscriptResolution? in
            guard (try? YouTubeTranscriptContentLanguagePolicy.validatedPlaybackLanguage(
                for: candidate.document
            )) != nil,
            YouTubeReadingDocumentBuilder.firstPlayableParagraph(
                in: candidate.document
            ) != nil else { return nil }
            return candidate
        }
        if let usableImmediate,
           usableImmediate.document.captionSemanticSchemaVersion ==
               YouTubeCaptionSemanticSchema.current ||
               !NetworkReachability.shared.isOnline {
            return YouTubeTranscriptResolution(
                transcript: usableImmediate.document,
                cacheKey: usableImmediate.key,
                cacheHit: true
            )
        }

        let transcript: YouTubeTranscriptDocument
        let refreshPreference = usableImmediate?.document.track.languageCode
            ?? preferredYouTubeCaptionLanguage
        let refreshTrack: YouTubeTrackRequest? = usableImmediate.flatMap { cached in
            guard cached.document.captionSemanticSchemaVersion !=
                    YouTubeCaptionSemanticSchema.current else { return nil }
            return YouTubeTrackRequest(refreshing: cached.document)
        }
        do {
            transcript = try await YouTubeTranscriptService.shared.extract(
                request.reference,
                preferredLanguage: refreshPreference,
                requestedTrack: refreshTrack,
                timeout: YouTubeTranscriptService.defaultExtractionTimeout
            )
        } catch let failure as YouTubeTranscriptFailure
            where failure == .network || failure == .timeout
                || failure == .captionAccess
                || failure == .playerBootstrapFailed
                || failure == .youtubeAccessLimited
                || (failure == .trackUnavailable && usableImmediate != nil) {
            // A pre-P0 cache cannot reconstruct WebVTT speaker tags, so an
            // online open first tries to refresh it. Keep that exact language
            // and track as the first fallback when YouTube is unreachable.
            if let usableImmediate {
                return YouTubeTranscriptResolution(
                    transcript: usableImmediate.document,
                    cacheKey: usableImmediate.key,
                    cacheHit: true
                )
            }
            if let cachedResolution = await cache?.mostRecentTranscript(
                videoId: request.reference.videoId
            ),
               (try? YouTubeTranscriptContentLanguagePolicy.validatedPlaybackLanguage(
                   for: cachedResolution.document
               )) != nil,
               YouTubeReadingDocumentBuilder.firstPlayableParagraph(
                   in: cachedResolution.document
               ) != nil {
                let fallbackKey = cachedResolution.key
                let cached = cachedResolution.document
                return YouTubeTranscriptResolution(
                    transcript: cached,
                    cacheKey: fallbackKey,
                    cacheHit: true
                )
            }
            throw failure
        }
        _ = try YouTubeTranscriptContentLanguagePolicy.validatedPlaybackLanguage(
            for: transcript
        )
        guard YouTubeReadingDocumentBuilder.firstPlayableParagraph(
            in: transcript
        ) != nil else {
            throw YouTubeTranscriptFailure.noCaptions
        }
        let key = YouTubeCacheStore.cacheKey(for: transcript)
        if let cache = YouTubeCacheProvider.shared {
            try? await cache.storeTranscript(transcript, for: key)
        }
        return YouTubeTranscriptResolution(
            transcript: transcript,
            cacheKey: key,
            cacheHit: false
        )
    }

    private var preferredYouTubeCaptionLanguage: String {
        let selected = AppLanguageManager.shared.selectedLanguage
        if selected == .system {
            return Locale.preferredLanguages.first ?? "en"
        }
        return selected.rawValue
    }

    private func startYouTubePlayback(
        request: YouTubeListenRequest,
        transcript: YouTubeTranscriptDocument,
        cacheKey: YouTubeTranscriptCacheKey,
        durableAcceptance: YouTubeDurablePlaybackAcceptance?
    ) async -> Bool {
        guard let session = coordinator.session else { return false }
        let readVM = session.readVM
        let contentSessionKey = session.id

        // History is a continuation surface: its saved progress wins over the
        // timestamp that may have been present on the originally shared URL.
        let explicitStart = request.entry == .history
            ? nil
            : request.reference.startSeconds
        let savedProgress: YouTubePlaybackProgress?
        if explicitStart == nil, let cache = YouTubeCacheProvider.shared {
            // Transcript selection/store already touched this entry. Resume
            // lookup is read-only so it does not add another atomic manifest
            // write on the path to first audio.
            savedProgress = await cache.peekProgress(for: cacheKey)
        } else {
            savedProgress = nil
        }

        let persistedHistorySummary: HistoryRecord? = {
            guard request.entry == .history else { return nil }
            return HistoryStore.shared.records.first { record in
                guard record.sourceKind == .youtube,
                      let sourceURL = record.sourceURL,
                      let reference = YouTubeURLParser.parse(sourceURL) else {
                    return false
                }
                return reference.videoId == request.reference.videoId
            }
        }()

        let resumedParagraph = savedProgress.flatMap {
            YouTubeReadingDocumentBuilder.resumingParagraph(
                in: transcript,
                progress: $0
            )
        }
        let persistedHistoryIsComplete = (
            persistedHistorySummary?.youtubeProgressFraction ?? 0
        ) >= 0.999
        let paragraphIndex = resumedParagraph
            ?? YouTubeReadingDocumentBuilder.startingParagraph(
                in: transcript,
                startSeconds: persistedHistoryIsComplete
                    ? nil
                    : explicitStart ?? persistedHistorySummary?.youtubeResumeStartMs.map {
                        $0 / 1_000
                    }
            )
        return await beginYouTubeAudio(
            transcript: transcript,
            paragraphIndex: paragraphIndex,
            readVM: readVM
        ) {
            armYouTubePlaybackAcceptance(
                request: request,
                readVM: readVM,
                contentSessionKey: contentSessionKey,
                durableAcceptance: durableAcceptance
            )
        }
    }

    /// Shared tail of every YouTube open. Audio is intentionally session-only,
    /// matching book playback; only transcript/progress/artwork survive a
    /// reader session. `acceptance` is evaluated immediately before generation
    /// so a session that changed while progress was read cannot be started into.
    private func beginYouTubeAudio(
        transcript: YouTubeTranscriptDocument,
        paragraphIndex: Int,
        readVM: ReadAloudViewModel,
        acceptance: () -> Bool
    ) async -> Bool {
        guard transcript.paragraphs.contains(where: { $0.id == paragraphIndex }) else {
            guard acceptance() else { return false }
            readVM.start()
            return true
        }

        guard acceptance() else { return false }
        readVM.jump(to: paragraphIndex)
        return true
    }

    // MARK: YouTube caption language

    /// The picker is bound to the reader that is actually on screen. A session
    /// that closed while the panel was open must not keep it alive.
    private var presentedCaptionLanguageTranscript: YouTubeTranscriptDocument? {
        guard let videoID = captionLanguageSwitcher.presentedPickerVideoID,
              let document = coordinator.session?.document,
              document.sourceKind == .youtube,
              let transcript = document.youtubeTranscript,
              transcript.metadata.videoId == videoID else { return nil }
        return transcript
    }

    private var captionLanguageFailureBinding: Binding<Bool> {
        Binding(
            get: { captionLanguageSwitcher.failureMessage != nil },
            set: { presented in
                if !presented { captionLanguageSwitcher.failureMessage = nil }
            }
        )
    }

    private func switchYouTubeCaptionLanguage(to option: YouTubeCaptionTrackOption) {
        guard let session = coordinator.session,
              session.document.sourceKind == .youtube,
              let transcript = session.document.youtubeTranscript,
              let reference = YouTubeURLParser.parse(
                  transcript.metadata.sourceURL
              ) else { return }
        let document = session.document

        // Paragraph ids do not survive a track change — the new language has
        // its own cue grouping — so the timeline position is the only anchor
        // that carries meaning across the switch.
        let resumeAnchorMs = document.paragraphs.first {
            $0.id == session.readVM.currentParagraphIndex
        }?.startMs ?? 0

        ProductAnalytics.shared.track(
            .youtubeCaptionLanguageSwitch,
            context: AnalyticsEventContext(
                productArea: .reader,
                surface: "youtube_caption_language",
                entryPoint: "youtube_reader"
            ),
            properties: .init(
                fromLanguage: YouTubeTrackSelector.baseLanguage(
                    transcript.track.languageCode
                ),
                toLanguage: YouTubeTrackSelector.baseLanguage(option.languageCode),
                kind: option.isAutomatic ? "asr" : "manual"
            )
        )

        captionLanguageSwitcher.startSwitch(
            to: option,
            reference: reference,
            resumeAnchorMs: resumeAnchorMs,
            cache: YouTubeCacheProvider.shared
        ) { resolution in
            await applyYouTubeCaptionLanguageSwitch(resolution)
        }
    }

    private func applyYouTubeCaptionLanguageSwitch(
        _ resolution: YouTubeCaptionLanguageSwitcher.Resolution
    ) async {
        let document = YouTubeReadingDocumentBuilder.make(
            transcript: resolution.transcript,
            cacheHit: resolution.cacheHit
        )
        // Every YouTube document for one video shares `document.id`; only the
        // session key changes per track. Without this explicit close the
        // coordinator would keep the old track's view model and voice.
        if let current = coordinator.session?.document,
           current.id == document.id,
           coordinator.session?.id != document.contentSessionKey {
            // Same video, different track: keep the warm document, it is what
            // makes the *next* switch fast.
            coordinator.close(releasingYouTubeWarmSession: false)
        }
        coordinator.open(document, mode: .read, autoplay: false)
        guard let session = coordinator.session,
              session.id == document.contentSessionKey else { return }

        let paragraphIndex = YouTubeReadingDocumentBuilder.startingParagraph(
            in: resolution.transcript,
            startSeconds: resolution.resumeAnchorMs / 1_000
        )
        _ = await beginYouTubeAudio(
            transcript: resolution.transcript,
            paragraphIndex: paragraphIndex,
            readVM: session.readVM
        ) {
            coordinator.session?.id == document.contentSessionKey
        }
        cacheYouTubeThumbnailIfNeeded(
            resolution.transcript.metadata.thumbnailURL,
            key: resolution.cacheKey
        )
    }

    private func armYouTubePlaybackAcceptance(
        request: YouTubeListenRequest,
        readVM: ReadAloudViewModel,
        contentSessionKey: String,
        durableAcceptance: YouTubeDurablePlaybackAcceptance?
    ) -> Bool {
        guard !Task.isCancelled,
              let currentSession = coordinator.session,
              currentSession.readVM === readVM,
              currentSession.id == contentSessionKey else { return false }
        readVM.prepareForYouTubePlaybackAcceptanceSignal()
        pendingYouTubePlaybackAcceptance = durableAcceptance
        pendingYouTubeShareAhaSessionKey = request.entry == .share
            && !didShowYouTubeShareAha
            ? contentSessionKey
            : nil
        return true
    }

    private func cacheYouTubeThumbnailIfNeeded(
        _ rawURL: String?,
        key: YouTubeTranscriptCacheKey
    ) {
        guard let cache = YouTubeCacheProvider.shared,
              let rawURL,
              let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let url = components.url else { return }
        Task {
            if await cache.thumbnail(for: key) != nil { return }
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  !data.isEmpty,
                  data.count <= 20 * 1_024 * 1_024 else { return }
            try? await cache.storeThumbnail(data, for: key)
        }
    }

    private func handleYouTubeExtractionFailure(
        _ failure: YouTubeTranscriptFailure,
        request: YouTubeListenRequest,
        analyticsContext: AnalyticsContentContext
    ) {
        guard activeYouTubeRequestID == request.id else { return }
        if failure == .cancelled {
            finishCancelledYouTubeRequest(request.id)
            return
        }
        ProductAnalytics.shared.contentFailed(
            analyticsContext,
            stage: "youtube_extract",
            code: failure.rawValue
        )
        if let reason = youtubeAnalyticsFailureReason(failure) {
            ProductAnalytics.shared.track(
                .youtubeExtractFail,
                context: AnalyticsEventContext(
                    productArea: .reader,
                    surface: "youtube_extract",
                    entryPoint: analyticsContext.entryPoint,
                    contentSessionId: analyticsContext.contentSessionId
                ),
                properties: .init(reason: reason)
            )
        }
        youtubeExtractionPresentation = .failure(request, failure)
        pendingYouTubeShareAhaSessionKey = nil
        activeYouTubeRequestID = nil
        youtubeExtractionTask = nil
    }

    private func youtubeAnalyticsFailureReason(
        _ failure: YouTubeTranscriptFailure
    ) -> String? {
        switch failure {
        case .noCaptions: return "no_captions"
        case .live: return "live"
        case .restricted: return "restricted"
        case .unavailable, .invalidURL, .malformedResponse: return "unavailable"
        case .captionAccess: return "caption_access"
        case .playerBootstrapFailed: return "player_bootstrap_failed"
        case .youtubeAccessLimited: return "youtube_access_limited"
        case .trackUnavailable: return "track_unavailable"
        case .timeout, .network: return "timeout"
        case .unsupportedLanguage: return "unsupported_language"
        case .cancelled: return nil
        }
    }

    private func finishCancelledYouTubeRequest(_ requestID: UUID) {
        guard activeYouTubeRequestID == requestID else { return }
        youtubeExtractionPresentation = nil
        activeYouTubeRequestID = nil
        pendingYouTubeShareAhaSessionKey = nil
        youtubeExtractionTask = nil
    }

    private func cancelYouTubeExtraction() {
        let cancelledRequest = youtubeExtractionPresentation?.request
        youtubeExtractionTask?.cancel()
        youtubeExtractionTask = nil
        YouTubeTranscriptService.shared.cancel()
        youtubeExtractionPresentation = nil
        activeYouTubeRequestID = nil
        pendingYouTubeShareAhaSessionKey = nil
        if let cancelledRequest {
            youtubeRouteCenter.acknowledge(cancelledRequest)
        }
        scheduleNextPendingYouTubeHandoff()
    }

    /// Keep the App Group FIFO moving without requiring another background /
    /// foreground cycle. Terminal failures intentionally do not call this: the
    /// failed item stays visible until the user retries or explicitly cancels.
    private func scheduleNextPendingYouTubeHandoff() {
        Task { @MainActor in
            // Let the reader cover and first-share acknowledgement alert settle
            // before presenting the next extraction state.
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard scenePhase == .active,
                  youtubeExtractionPresentation == nil,
                  activeYouTubeRequestID == nil else { return }
            _ = routePendingYouTubeIfAvailable()
        }
    }

    /// App Intents and widgets can run before the containing app has built its
    /// view hierarchy. They persist one action in the App Group; MainTab owns
    /// the only consumer because it also owns PlayerCoordinator and import UI.
    @discardableResult
    private func routePendingSystemActionIfAvailable() -> Bool {
        guard scenePhase == .active,
              systemActionTask == nil,
              let action = SystemActionStore.shared.takePending() else {
            return false
        }

        selectedTab = 0
        playbackVoicePanel.dismiss()
        studyBoostRouter.dismiss()
        showShareInbox = false
        clipboard.consume()
        if libraryOnboarding.isChooserPresented {
            pendingLibraryOnboardingAction = nil
            libraryOnboarding.postpone()
        }

        systemActionTask = Task { @MainActor in
            await handleSystemAction(action)
            systemActionTask = nil
            routePendingSystemActionIfAvailable()
        }
        return true
    }

    private func handleSystemAction(_ action: SystemAction) async {
        switch action {
        case .openImport:
            openQuickImportFromSystemAction()

        case .read(let input, let intentMode):
            let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                openQuickImportFromSystemAction()
                return
            }

            if YouTubeURLParser.parse(value) != nil {
                _ = youtubeRouteCenter.open(value, entry: .scheme)
                return
            }

            let mode = intentMode.readerMode
            let isWebURL: Bool = {
                guard let url = URL(string: value),
                      let scheme = url.scheme?.lowercased(),
                      ["http", "https"].contains(scheme),
                      url.host != nil else { return false }
                return true
            }()
            let analyticsContext = ProductAnalytics.shared.beginContentIntent(
                source: .system,
                format: isWebURL ? .web : .text,
                entryPoint: "app_intent_read",
                intendedMode: mode == .read ? "read" : "explain"
            )
            let document = isWebURL
                ? DocumentBuilder.fromWebURL(value)
                : DocumentBuilder.fromPlainText(value, title: AppLocalized("快捷指令文本"))
            guard let document,
                  !document.isEmpty || document.sourceKind.isWebRendered else {
                ProductAnalytics.shared.contentFailed(
                    analyticsContext,
                    stage: "parse",
                    code: "empty_or_invalid_system_input"
                )
                openQuickImportFromSystemAction()
                return
            }
            coordinator.open(
                document,
                mode: mode,
                autoplay: true,
                analyticsContext: analyticsContext
            )

        case .continueReading(let itemID, let intentMode):
            guard let record = SystemContinueContract.record(
                in: HistoryStore.shared.records,
                itemID: itemID
            ) else {
                openQuickImportFromSystemAction()
                return
            }

            let mode = intentMode.readerMode
            let analyticsContext = ProductAnalytics.shared.beginContentIntent(
                source: .history,
                format: AnalyticsContentFormat(record.sourceKind),
                entryPoint: "app_intent_continue",
                intendedMode: mode == .read ? "read" : "explain"
            )
            let document: ReadingDocument
            if record.requiresRemoteReopen {
                guard Constants.Features.cloudStorageEnabled else {
                    openQuickImportFromSystemAction()
                    return
                }
                do {
                    document = try await CloudHistoryReopenService().reopen(
                        record,
                        mode: mode,
                        analyticsContext: analyticsContext
                    ).document
                } catch {
                    ProductAnalytics.shared.contentFailed(
                        analyticsContext,
                        stage: "cloud_reopen",
                        code: "cloud_history_reopen_failed"
                    )
                    if let failure = CloudHistoryFailurePresentation.make(
                        record: record,
                        error: error
                    ) {
                        systemCloudFailureMode = intentMode
                        systemCloudFailure = failure
                    }
                    return
                }
            } else {
                do {
                    guard let reopened = try await HistoryStore.shared.reopen(record) else {
                        ProductAnalytics.shared.contentFailed(
                            analyticsContext,
                            stage: "reopen",
                            code: "missing_history_payload"
                        )
                        openQuickImportFromSystemAction()
                        return
                    }
                    document = reopened
                } catch is CancellationError {
                    return
                } catch {
                    ProductAnalytics.shared.contentFailed(
                        analyticsContext,
                        stage: "reopen",
                        code: "history_reopen_failed"
                    )
                    openQuickImportFromSystemAction()
                    return
                }
            }
            coordinator.open(
                document,
                mode: mode,
                autoplay: true,
                analyticsContext: analyticsContext
            )
        }
    }

    private func recoverSystemCloudFailure(
        _ failure: CloudHistoryFailurePresentation
    ) {
        systemCloudFailure = nil
        switch failure.recovery {
        case .reconnect(let forceAccountSelection):
            importRouter.reconnectCloud(
                failure.record.origin?.provider ?? .unavailableA,
                forceAccountSelection: forceAccountSelection,
                expectedAccount: failure.record.origin.map {
                    CloudAccount(
                        provider: $0.provider,
                        stableAccountKey: $0.accountKey,
                        maskedEmail: $0.maskedAccountHint
                    )
                }
            )
        case .removeRecord:
            HistoryStore.shared.delete(failure.record.id)
        case .retry:
            _ = SystemActionStore.shared.enqueue(
                .continueReading(
                    itemID: failure.record.id,
                    mode: systemCloudFailureMode
                )
            )
            _ = routePendingSystemActionIfAvailable()
        case .dismiss:
            break
        }
    }

    private func openQuickImportFromSystemAction() {
        if coordinator.isReaderPresented { coordinator.minimize() }
        if kindleCenter.isPresented { kindleCenter.minimize() }
        DispatchQueue.main.async {
            importRouter.openQuickImport()
        }
    }

    /// Pending is deliberately separated from presentation. The monitor starts
    /// only on the Home root and requires two uninterrupted seconds with audio
    /// stopped and every in-app/system presentation gone.
    private func restartReviewRequestMonitor() {
        reviewRequestTask?.cancel()
        reviewRequestTask = nil
        guard reviewOpportunityState.canStabilize else { return }

        reviewRequestTask = Task { @MainActor in
            var stableSince: Date?
            while !Task.isCancelled {
                guard reviewOpportunityState.canStabilize else { return }
                if hasBlockingSystemPresentation {
                    stableSince = nil
                } else if let stableSince {
                    if Date().timeIntervalSince(stableSince) >= 2 {
                        reviewPrompt.performSystemReviewRequest {
                            requestReview()
                        }
                        return
                    }
                } else {
                    stableSince = Date()
                }

                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return
                }
            }
        }
    }

    private var hasBlockingSystemPresentation: Bool {
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard let window = activeScenes
            .flatMap(\.windows)
            .first(where: \.isKeyWindow),
              let root = window.rootViewController else {
            return true
        }
        return root.presentedViewController != nil
    }

    private func handleKindleOnboardingStartBook(_ book: KindleBook) {
        pendingLibraryOnboardingAction = .kindleBook(book)
    }

    private func handleWeReadOnboardingStartBook(_ book: WeReadBook) {
        pendingLibraryOnboardingAction = .wereadBook(book)
    }

    private func handleLibraryOnboardingPostpone() {
        pendingLibraryOnboardingAction = .restoreClipboard
        libraryOnboarding.postpone()
    }

    private func handleLibraryOnboardingDismissal() {
        defer { presentPendingLibraryConnectionWhenReady() }
        guard let action = pendingLibraryOnboardingAction else { return }
        pendingLibraryOnboardingAction = nil
        switch action {
        case .kindleBook(let book):
            selectedTab = 0
            KindlePlaybackCenter.shared.open(
                book: book,
                intent: .autoplayRead(requestID: UUID())
            )
        case .wereadBook(let book):
            selectedTab = 0
            openWeReadOnboardingBook(book)
        case .restoreClipboard:
            clipboard.check()
        }
    }

    /// 引导的首听：进阅读器并自动朗读。归因保持在 `library_onboarding`，
    /// 激活仍然只由真实播放的 30 秒累计完成。
    private func openWeReadOnboardingBook(_ book: WeReadBook) {
        WeReadLibraryStore.shared.markOpened(book)
        let document = ReadingDocument(
            id: book.id,
            title: book.title,
            sourceKind: .weread,
            language: Constants.TTS.defaultLanguage,
            paragraphs: [],
            sourceURL: book.effectiveReaderURL,
            coverURL: book.coverURL
        )
        let context = ProductAnalytics.shared.beginContentIntent(
            source: .weread,
            format: .weread,
            entryPoint: libraryOnboarding.analyticsEntryPoint(for: .weread) ?? "library_onboarding",
            intendedMode: "read"
        )
        coordinator.open(document, mode: .read, autoplay: true, analyticsContext: context)
    }

    /// Route every library connection request through one always-mounted root.
    /// A pending slot deliberately separates the tap from UIKit presentation:
    /// dismissing the full-screen onboarding and presenting a sheet in the same
    /// run-loop otherwise produces the intermittent no-op reported in 1.2.15.
    private func requestLibraryConnection(
        _ source: BoundLibraryOnboardingSource,
        entryPoint: String
    ) {
        // 所有 UI 与程序化触发都统一经过区域能力矩阵。中国区当前保留全部
        // 既有书架平台，仅把微信读书设为默认引导来源。
        guard AppRegion.current.availableBoundLibraries.contains(source) else { return }
        selectedTab = 0
        if let superseded = pendingLibraryConnection {
            ProductAnalytics.shared.trackLibraryConnection(
                superseded.analyticsSession,
                stage: .cancelled,
                result: .cancelled
            )
        }
        let session = ProductAnalytics.shared.beginLibraryConnection(
            source: source.analyticsLibrarySource,
            entryPoint: entryPoint
        )
        pendingLibraryConnection = LibraryConnectionRoute(
            source: source,
            analyticsSession: session
        )
        presentPendingLibraryConnectionWhenReady()
    }

    private func presentPendingLibraryConnectionWhenReady() {
        guard activeLibraryConnection == nil,
              pendingLibraryConnection != nil else { return }
        libraryConnectionPresentationTask?.cancel()
        libraryConnectionPresentationTask = Task { @MainActor in
            while !Task.isCancelled, pendingLibraryConnection != nil {
                if canPresentPendingLibraryConnection {
                    // Require a short, continuously clear window. A sheet's
                    // state can change one run-loop before UIKit actually
                    // installs/removes its presented controller.
                    do {
                        try await Task.sleep(nanoseconds: 200_000_000)
                    } catch {
                        return
                    }
                    guard !Task.isCancelled,
                          canPresentPendingLibraryConnection,
                          let route = pendingLibraryConnection else { continue }
                    pendingLibraryConnection = nil
                    activeLibraryConnection = route
                    libraryConnectionPresentationTask = nil
                    return
                }
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                } catch {
                    return
                }
            }
            libraryConnectionPresentationTask = nil
        }
    }

    private var canPresentPendingLibraryConnection: Bool {
        !libraryOnboarding.isChooserPresented
            && clipboard.detected == nil
            && !showShareInbox
            && voiceCloneAccess.prompt == nil
            && !hasBlockingSystemPresentation
    }

    @ViewBuilder
    private func libraryConnectionView(
        for route: LibraryConnectionRoute
    ) -> some View {
        switch route.source {
        case .kindle:
            KindleLibraryConnectView(
                analyticsSession: route.analyticsSession,
                entryTapAlreadyTracked: true
            )
        case .weread:
            WeReadLibraryConnectView(
                analyticsSession: route.analyticsSession,
                entryTapAlreadyTracked: true
            )
        case .googleBooks:
            GoogleBooksLibraryConnectView(
                analyticsSession: route.analyticsSession,
                entryTapAlreadyTracked: true
            )
        case .kobo:
            KoboLibraryConnectView(
                analyticsSession: route.analyticsSession,
                entryTapAlreadyTracked: true
            )
        case .oreilly:
            OReillyLibraryConnectView(
                analyticsSession: route.analyticsSession,
                entryTapAlreadyTracked: true
            )
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
        if case .url(let rawURL) = content,
           YouTubeURLParser.parse(rawURL) != nil {
            if mode == .explain {
                systemActionNotice = AppLocalized("YouTube 字幕稿目前仅支持朗读，已自动切换为朗读。")
            }
            _ = YouTubeRouteCenter.shared.open(rawURL, entry: .clipboard)
            return
        }
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
        shareInboxImportTask?.cancel()
        shareInboxImportTask = nil
        isImportingSharedContent = true
        guard let boundary = AccountContentIsolation.captureBoundaryToken() else {
            isImportingSharedContent = false
            return
        }
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
            guard AccountContentIsolation.isCurrent(boundary) else { return }
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
            if let rawURL = record.sourceURL,
               YouTubeURLParser.parse(rawURL) != nil {
                isImportingSharedContent = false
                showShareInbox = false
                _ = YouTubeRouteCenter.shared.open(rawURL, entry: .share)
            } else {
                complete(record.sourceURL.flatMap(DocumentBuilder.fromWebURL))
            }
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
        case .pdf, .docx, .epub:
            guard let url = ShareInboxStore.payloadURL(for: record) else {
                complete(nil)
                return
            }
            let documentFormat: SupportedDocumentFormat = switch record.kind {
            case .pdf: .pdf
            case .docx: .docx
            case .epub: .epub
            default: .pdf
            }
            let displayTitle = record.localizedDisplayTitle
            let effectiveFilename = displayTitle.lowercased().hasSuffix(".\(documentFormat.rawValue)")
                ? displayTitle
                : "\(displayTitle).\(documentFormat.rawValue)"
            shareInboxImportTask = Task { @MainActor in
                do {
                    let result = try await DocumentImportPipeline().importDocument(
                        DocumentImportRequest(
                            localURL: url,
                            effectiveFilename: effectiveFilename,
                            expectedFormat: documentFormat
                        )
                    )
                    guard !Task.isCancelled,
                          AccountContentIsolation.isCurrent(boundary) else { return }
                    complete(result.document)
                } catch {
                    guard !Task.isCancelled,
                          AccountContentIsolation.isCurrent(boundary) else { return }
                    complete(nil)
                }
            }
        case .image:
            guard let url = ShareInboxStore.payloadURL(for: record),
                  let data = try? Data(contentsOf: url),
                  let image = UIImage(data: data) else { complete(nil); return }
            shareInboxImportTask = Task { @MainActor in
                let capture = CaptureFlowViewModel()
                await capture.process(image: image)
                guard !Task.isCancelled,
                      AccountContentIsolation.isCurrent(boundary) else { return }
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

/// 书架来源入口。首页与音色 Tab 共用同一颗按钮，切 Tab 时右上角不再变化。
struct ShelfSourcesToolbarButton: View {
    /// 传入时由调用方负责呈现（首页统一走自己的 `activeSheet`，避免同屏多 sheet 互吞，
    /// 见 CLAUDE.md 避坑 #9）；不传则这颗按钮自己挂 sheet。
    var accessibilityID: String = "homeShelfSourcesButton"
    var onTap: (() -> Void)?

    @State private var showsShelfSources = false

    var body: some View {
        Button {
            if let onTap { onTap() } else { showsShelfSources = true }
        } label: {
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AppTheme.foreground)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityID)
        .accessibilityLabel(Text(AppLocalized("管理书架来源")))
        .sheet(isPresented: $showsShelfSources) { LibrarySourcesSheet() }
    }
}

struct SettingsToolbarButton: View {
    /// 收件箱从首页 toolbar 下沉进设置后，未读数改由这颗按钮代为提示。
    var shareInboxUnreadCount: Int = 0
    var onOpenShareInbox: (() -> Void)?

    @ObservedObject private var auth = AuthService.shared
    @State private var showSettings = false
    @State private var pendingLibraryOnboardingReset: Bool?
    @State private var pendingOpenShareInbox = false

    var body: some View {
        Button { showSettings = true } label: {
            ZStack(alignment: .topTrailing) {
                // 露头像而不是齿轮：用户来这里多半是找账号和订阅，不是找"设置"。
                avatar
                    .frame(width: 28, height: 28)
                    .clipShape(Circle())
                if shareInboxUnreadCount > 0 {
                    Circle()
                        .fill(AppTheme.primary)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(AppTheme.background, lineWidth: 1.5))
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(AppLocalized("账号与设置")))
        .accessibilityIdentifier("settingsGearButton")
        .sheet(isPresented: $showSettings, onDismiss: handleSettingsDismissed) {
            SettingsView(
                shareInboxUnreadCount: shareInboxUnreadCount,
                onOpenShareInbox: { pendingOpenShareInbox = true }
            ) { reset in
                pendingLibraryOnboardingReset = reset
            }
        }
    }

    @ViewBuilder
    private var avatar: some View {
        if let acc = auth.account {
            if let s = acc.pictureURL, let url = URL(string: s) {
                CachedAsyncImage(url: url) { initialCircle(acc) }
            } else {
                initialCircle(acc)
            }
        } else {
            Image(systemName: "person.crop.circle")
                .resizable()
                .scaledToFit()
                .foregroundStyle(AppTheme.foreground)
        }
    }

    private func initialCircle(_ acc: UserAccount) -> some View {
        ZStack {
            Circle().fill(AppTheme.primary.opacity(0.15))
            Text(acc.initial).font(.subheadline).foregroundColor(AppTheme.primary)
        }
    }

    /// 设置是 sheet，从它内部再开一个 sheet 会互相吞掉（见 CLAUDE.md 避坑 #9），
    /// 所以收件箱只在设置关闭之后由父层打开。
    private func handleSettingsDismissed() {
        if pendingOpenShareInbox {
            pendingOpenShareInbox = false
            onOpenShareInbox?()
        }
        presentRequestedLibraryOnboarding()
    }

    private func presentRequestedLibraryOnboarding() {
        guard let reset = pendingLibraryOnboardingReset else { return }
        pendingLibraryOnboardingReset = nil
        if reset {
            BoundLibraryOnboardingStore.shared.reset()
        } else {
            BoundLibraryOnboardingStore.shared.presentChooser()
        }
    }
}

private extension CastReaderIntentMode {
    var readerMode: ReaderMode {
        switch self {
        case .read: .read
        case .explain: .explain
        }
    }
}

private extension BoundLibraryOnboardingSource {
    var analyticsLibrarySource: AnalyticsLibrarySource {
        switch self {
        case .kindle: .kindle
        case .weread: .weread
        case .googleBooks: .googleBooks
        case .kobo: .kobo
        case .oreilly: .oreilly
        }
    }
}
