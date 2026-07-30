//
//  ReaderHostView.swift
//  CastReader
//
//  阅读宿主：持有 ReadAloud / Explain 两个 VM，顶部切换「朗读 / 解读」，底部对应控制条。
//

import SwiftUI

enum ReaderMode: String, CaseIterable, Identifiable {
    case read = "朗读"
    case explain = "解读"
    var id: String { rawValue }
}

enum ReaderPlaybackNavigationContract {
    static func usesPageTurns(for sourceKind: ReadingSourceKind) -> Bool {
        switch sourceKind {
        case .weread, .googleBooks, .kobo:
            return true
        default:
            return false
        }
    }
}

/// Shared portrait playback geometry for Kindle and every generic reader.
/// Captions deliberately paint outside this reserved area so a changing
/// sentence never resizes a WebView/PDF surface or triggers repagination.
enum ReaderPlaybackBarLayoutContract {
    static let portraitHeight: CGFloat = 72
    static let consoleHeight: CGFloat = 64
    static let landscapeControlHeight: CGFloat = 68
    static let explainCaptionOffset: CGFloat = -42
    static let explainCaptionConsumesReservedHeight = false

    static func reservedPortraitHeight(for mode: ReaderMode) -> CGFloat {
        switch mode {
        case .read, .explain:
            return portraitHeight
        }
    }

    /// The Web adapter's scalar occlusion can only describe a full-width
    /// bottom band. Compact landscape capsules leave most of that band
    /// readable, so they must report zero until the bridge supports exact
    /// occlusion rectangles.
    static func bottomContentOcclusion(
        controlsCoverFullWidth: Bool
    ) -> CGFloat {
        controlsCoverFullWidth ? landscapeControlHeight : 0
    }
}

enum ReadPlaybackPresentationState: Equatable {
    case playing
    case waiting
    case retry
    case paused
}

enum ReadPlaybackPresentationContract {
    static func resolve(
        isPlaying: Bool,
        isWaitingForPlayableAudio: Bool,
        status: TTSStatus
    ) -> ReadPlaybackPresentationState {
        if isPlaying { return .playing }
        if isWaitingForPlayableAudio { return .waiting }
        if case .error = status { return .retry }
        return .paused
    }
}

enum ReaderExplainPlaybackPresentationState: Equatable {
    case start
    case playing
    case paused
    case retry
    case replay
    case waiting
}

/// Short AVPlayer/TTS staging gaps are normal between streamed segments. Keep
/// the last stable control state for 300ms so those gaps do not flash the play
/// button or status copy. A sustained wait then becomes an explicit spinner.
enum ReaderPlaybackWaitingDebounceContract {
    static let delayMilliseconds: UInt64 = 300
    static let delayNanoseconds = delayMilliseconds * 1_000_000

    static func hasExceededDelay(elapsedMilliseconds: UInt64) -> Bool {
        elapsedMilliseconds >= delayMilliseconds
    }

    static func resolve<Presentation: Equatable>(
        rawWaiting: Bool,
        waitingHasExceededDelay: Bool,
        previousStablePresentation: Presentation,
        currentStablePresentation: Presentation,
        waitingPresentation: Presentation
    ) -> Presentation {
        guard rawWaiting else { return currentStablePresentation }
        return waitingHasExceededDelay
            ? waitingPresentation
            : previousStablePresentation
    }
}

enum ReaderPrimaryPlaybackButtonIcon: Equatable {
    case play
    case pause
    case retry
    case sparkles
    case loading
}

enum ReaderPrimaryPlaybackButtonVisualContract {
    static let portraitSize: CGFloat = 52
    static let landscapeSize: CGFloat = 44
    static let keepsPrimaryCircleWhileLoading = true
}

/// One stable orange control shell for Read and Explain. Loading only swaps the
/// white glyph inside the circle, so changing playback state never removes or
/// resizes the user's visual anchor.
struct ReaderPrimaryPlaybackButtonContent: View {
    let icon: ReaderPrimaryPlaybackButtonIcon
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(AppTheme.primary)

            switch icon {
            case .loading:
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
                    .scaleEffect(size >= ReaderPrimaryPlaybackButtonVisualContract.portraitSize ? 1 : 0.86)
            case .play:
                Image(systemName: "play.fill")
                    .offset(x: size * 0.035)
            case .pause:
                Image(systemName: "pause.fill")
            case .retry:
                Image(systemName: "arrow.clockwise")
            case .sparkles:
                Image(systemName: "sparkles")
            }
        }
        .font(.system(size: size * 0.34, weight: .bold))
        .foregroundStyle(Color.white)
        .frame(width: size, height: size)
        .contentShape(Circle())
    }
}

/// SwiftUI adapter for the pure waiting contract above. While `rawWaiting`
/// remains true it deliberately refuses to accept transient `.paused` values
/// caused by `isPlaying` dropping at a segment boundary.
struct ReaderDebouncedWaitingPresentation<Presentation: Equatable, Content: View>: View {
    let stablePresentation: Presentation
    let rawWaiting: Bool
    let waitingPresentation: Presentation
    let content: (Presentation) -> Content

    @State private var previousStablePresentation: Presentation
    @State private var waitingHasExceededDelay = false

    init(
        stablePresentation: Presentation,
        rawWaiting: Bool,
        waitingPresentation: Presentation,
        @ViewBuilder content: @escaping (Presentation) -> Content
    ) {
        self.stablePresentation = stablePresentation
        self.rawWaiting = rawWaiting
        self.waitingPresentation = waitingPresentation
        self.content = content
        _previousStablePresentation = State(initialValue: stablePresentation)
    }

    var body: some View {
        content(displayedPresentation)
            .onAppear {
                if !rawWaiting {
                    previousStablePresentation = stablePresentation
                }
            }
            .onChange(of: stablePresentation) { newValue in
                guard !rawWaiting else { return }
                previousStablePresentation = newValue
            }
            .onChange(of: rawWaiting) { isWaiting in
                if !isWaiting {
                    waitingHasExceededDelay = false
                    previousStablePresentation = stablePresentation
                }
            }
            .task(id: rawWaiting) {
                guard rawWaiting else {
                    waitingHasExceededDelay = false
                    return
                }
                waitingHasExceededDelay = false
                try? await Task.sleep(
                    nanoseconds: ReaderPlaybackWaitingDebounceContract.delayNanoseconds
                )
                guard !Task.isCancelled else { return }
                waitingHasExceededDelay = true
            }
    }

    private var displayedPresentation: Presentation {
        ReaderPlaybackWaitingDebounceContract.resolve(
            rawWaiting: rawWaiting,
            waitingHasExceededDelay: waitingHasExceededDelay,
            previousStablePresentation: previousStablePresentation,
            currentStablePresentation: stablePresentation,
            waitingPresentation: waitingPresentation
        )
    }
}

enum ReaderModeSwitchPlaybackContract {
    static func shouldContinueFromRead(
        audioIsPlaying: Bool,
        viewModelIsPlaying: Bool,
        status: TTSStatus
    ) -> Bool {
        audioIsPlaying || viewModelIsPlaying || status.isLoading
    }

    static func shouldContinueFromExplain(
        audioIsPlaying: Bool,
        viewModelIsPlaying: Bool,
        status: ExplainStatus,
        isPreparingNext: Bool
    ) -> Bool {
        if audioIsPlaying || viewModelIsPlaying { return true }
        switch status {
        case .planning:
            return true
        case .streaming:
            return isPreparingNext
        case .idle, .completed, .error:
            return false
        }
    }
}

/// Matches Kindle's native TOC sheet so both bound-library readers have the
/// same hierarchy, active-chapter indicator and loading/error interaction.
private struct WeReadNativeTOCPanel: View {
    let entries: [WeReadTOCEntry]
    let isLoading: Bool
    let errorText: String?
    let isLandscape: Bool
    let close: () -> Void
    let select: (WeReadTOCEntry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(AppLocalized("目录"))
                    .font(.headline.weight(.semibold))
                    .foregroundColor(AppTheme.foreground)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(AppTheme.mutedForeground)
                        .frame(width: 34, height: 34)
                        .background(AppTheme.surfaceVariant, in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, isLandscape ? 18 : 14)
            .padding(.bottom, 10)

            Divider()

            Group {
                if isLoading && entries.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView().tint(AppTheme.primary)
                        Text(AppLocalized("正在加载目录…"))
                            .font(.subheadline)
                            .foregroundColor(AppTheme.mutedForeground)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorText, entries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundColor(AppTheme.mutedForeground)
                        Text(errorText)
                            .font(.subheadline)
                            .foregroundColor(AppTheme.mutedForeground)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { scrollProxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(entries) { entry in
                                    Button { select(entry) } label: {
                                        HStack(spacing: 10) {
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(entry.active ? AppTheme.primary : Color.clear)
                                                .frame(width: 3, height: 24)

                                            Text(entry.title)
                                                .font(.subheadline.weight(entry.active ? .semibold : .regular))
                                                .foregroundColor(entry.active ? AppTheme.foreground : AppTheme.foreground.opacity(0.88))
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)

                                            Spacer(minLength: 8)

                                            Image(systemName: "chevron.right")
                                                .font(.system(size: 12, weight: .semibold))
                                                .foregroundColor(AppTheme.mutedForeground.opacity(0.7))
                                        }
                                        .padding(.leading, 16 + CGFloat(min(entry.level, 3)) * 16)
                                        .padding(.trailing, 16)
                                        .padding(.vertical, 12)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!entry.isActionable)
                                    .opacity(entry.isActionable ? 1 : 0.48)
                                    .id(entry.id)

                                    Divider()
                                        .padding(.leading, 52 + CGFloat(min(entry.level, 3)) * 16)
                                }

                                if isLoading {
                                    HStack(spacing: 10) {
                                        ProgressView().scaleEffect(0.82).tint(AppTheme.primary)
                                        Text(AppLocalized("正在更新目录…"))
                                            .font(.footnote)
                                            .foregroundColor(AppTheme.mutedForeground)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 16)
                                }
                            }
                            .padding(.bottom, isLandscape ? 18 : 26)
                        }
                        .onAppear {
                            if let active = entries.first(where: \.active) {
                                DispatchQueue.main.async {
                                    scrollProxy.scrollTo(active.id, anchor: .center)
                                }
                            }
                        }
                    }
                }
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: isLandscape ? 18 : 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: isLandscape ? 18 : 24, style: .continuous)
                .stroke(AppTheme.border.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)
        .padding(isLandscape ? 14 : 0)
    }
}

struct ReaderHostView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    @ObservedObject var coordinator: PlayerCoordinator
    let document: ReadingDocument

    @ObservedObject private var googleBooksStore = GoogleBooksLibraryStore.shared
    @ObservedObject private var koboStore = KoboLibraryStore.shared
    @StateObject private var weReadTOC = WeReadTOCController()
    @StateObject private var liveWebPageTurn = LiveWebPageTurnController()
    @State private var readerSurfaceSize: CGSize = .zero
    @State private var refocusToken = 0
    @State private var refocusTask: Task<Void, Never>?
    @State private var pendingModeSwitch: PendingReaderModeSwitch?

    private struct PendingReaderModeSwitch {
        let target: ReaderMode
        let shouldContinuePlayback: Bool
    }

    private var mode: ReaderMode { coordinator.mode }
    private var usesCompactPlaybackBar: Bool { verticalSizeClass == .compact }

    var body: some View {
        // Keep one structural path for the reader surface in both orientations.
        // Putting portrait and landscape in separate `if` branches destroys the
        // UIViewRepresentable when verticalSizeClass changes. For WeRead that
        // meant throwing away the live WKWebView, booting a second reader and
        // leaving the old TTS timer briefly attached to the new page model.
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                Divider()
                readerSurface
                if !usesCompactPlaybackBar {
                    Divider()
                    controls
                }
            }

            if usesCompactPlaybackBar {
                landscapeControls
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
                    .opacity(weReadTOC.isPresented ? 0 : 1)
                    .allowsHitTesting(!weReadTOC.isPresented && !weReadTOC.isJumping)
                    .accessibilityHidden(weReadTOC.isPresented || weReadTOC.isJumping)
            }

            if document.sourceKind == .weread, weReadTOC.isPresented {
                weReadTOCOverlay
                    .zIndex(10)
            }

            if document.sourceKind == .weread, weReadTOC.isJumping {
                weReadTOCJumpLockOverlay
                    .zIndex(20)
            }

            if document.sourceKind == .googleBooks,
               let message = googleBooksStore.lastError {
                googleBooksRecoveryOverlay(message: message)
                    .zIndex(30)
            }

            if document.sourceKind == .kobo,
               let message = koboStore.lastError {
                koboRecoveryOverlay(message: message)
                    .zIndex(30)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .onAppear { scheduleRefocusBurst(reason: "appear") }
        .onDisappear {
            refocusTask?.cancel()
        }
        .onPreferenceChange(ReaderSurfaceSizeKey.self) { size in
            guard size.width > 1, size.height > 1 else { return }
            guard abs(size.width - readerSurfaceSize.width) > 2
                    || abs(size.height - readerSurfaceSize.height) > 2 else { return }
            // ReaderHost is kept alive off-screen while minimized. Its first
            // valid geometry preference can therefore arrive just before
            // `isReaderPresented` flips to true. Always cache that geometry;
            // only the visible reader needs an immediate refocus burst.
            readerSurfaceSize = size
            guard coordinator.isReaderPresented else { return }
            scheduleRefocusBurst(reason: "surfaceSize")
        }
        .onChange(of: scenePhase) { phase in
            guard phase == .active, coordinator.isReaderPresented else { return }
            scheduleRefocusBurst(reason: "foreground")
        }
        .onChange(of: coordinator.isReaderPresented) { isPresented in
            if isPresented {
                scheduleRefocusBurst(reason: "expand")
            } else {
                refocusTask?.cancel()
            }
        }
        .onChange(of: coordinator.mode) { newMode in
            let shouldContinuePlayback: Bool
            if pendingModeSwitch?.target == newMode {
                shouldContinuePlayback =
                    pendingModeSwitch?.shouldContinuePlayback == true
            } else {
                shouldContinuePlayback =
                    shouldContinuePlaybackFromOutgoingMode(entering: newMode)
            }
            pendingModeSwitch = nil
            ReaderRunLog.write(
                "HOST mode switch target=\(newMode.rawValue) " +
                "continue=\(shouldContinuePlayback ? "Y" : "N")"
            )
            if newMode == .read {
                explainVM.deactivate()
                readVM.activate()       // 切回朗读：重新接管音频回调（onPlaybackComplete）
                if shouldContinuePlayback {
                    readVM.ensurePlaying()
                }
            } else {
                readVM.deactivate()
                explainVM.activateAfterModeSwitch(
                    autoplay: shouldContinuePlayback
                )
            }
            scheduleRefocusBurst(reason: "mode")
        }
        .onChange(of: verticalSizeClass) { _ in
            guard coordinator.isReaderPresented else { return }
            scheduleRefocusBurst(reason: "orientation")
        }
        // 收起阅读器（minimize）不停播放，由 Mini Player 接管；真正停止只在 Mini Player ✕（coordinator.close）。
        .sheet(isPresented: paywallBinding) {
            PaywallView(
                analyticsTrigger: readVM.showPaywall ? "listen_quota" : "explain_quota",
                analyticsSurface: "reader"
            )
        }
    }

    private var readerSurface: some View {
        GeometryReader { geometry in
            let surfaceSize = geometry.size
            Group {
                if surfaceSize.width > 1, surfaceSize.height > 1 {
                    content(surfaceSize: surfaceSize)
                } else {
                    AppTheme.background
                }
            }
            .frame(width: surfaceSize.width, height: surfaceSize.height)
            .preference(key: ReaderSurfaceSizeKey.self, value: surfaceSize)
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(document.id)   // 锁定 identity 到文档：切朗读/解读不重建 reader（保住 EPUB 已渲染的 WebView，避免闪白重载）
    }

    // MARK: 顶部

    private var header: some View {
        HStack(spacing: 12) {
            Button { coordinator.minimize() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(AppTheme.foreground)
            }
            Text(document.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundColor(AppTheme.foreground)
            Spacer(minLength: 8)
            Picker("", selection: modeSelection) {
                ForEach(ReaderMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .accessibilityIdentifier("readerModePicker")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, usesCompactPlaybackBar ? 6 : 10)
        .frame(height: usesCompactPlaybackBar ? 44 : nil)
        .background(.regularMaterial)
    }

    /// Capture playback intent in the Picker setter, before either SwiftUI's
    /// `updateUIView` or this view's `onChange` can deactivate the outgoing VM.
    /// Kindle preserves an active narration across mode switches; generic
    /// readers must follow the same contract.
    private var modeSelection: Binding<ReaderMode> {
        Binding(
            get: { coordinator.mode },
            set: { newMode in
                guard newMode != coordinator.mode else { return }
                pendingModeSwitch = PendingReaderModeSwitch(
                    target: newMode,
                    shouldContinuePlayback:
                        shouldContinuePlaybackFromOutgoingMode(
                            entering: newMode
                        )
                )
                coordinator.mode = newMode
            }
        )
    }

    private func shouldContinuePlaybackFromOutgoingMode(
        entering newMode: ReaderMode
    ) -> Bool {
        let audioIsPlaying = AudioPlayerService.shared.isPlaying
        switch newMode {
        case .explain:
            guard readVM.isActive else { return false }
            return ReaderModeSwitchPlaybackContract.shouldContinueFromRead(
                audioIsPlaying: audioIsPlaying,
                viewModelIsPlaying: readVM.isPlaying,
                status: readVM.status
            )
        case .read:
            guard explainVM.isActive else { return false }
            return ReaderModeSwitchPlaybackContract.shouldContinueFromExplain(
                audioIsPlaying: audioIsPlaying,
                viewModelIsPlaying: explainVM.isPlaying,
                status: explainVM.status,
                isPreparingNext: explainVM.isPreparingNext
            )
        }
    }

    // MARK: 内容

    @ViewBuilder
    private func content(surfaceSize: CGSize) -> some View {
        switch document.sourceKind {
        case .web, .docx, .weread, .googleBooks, .kobo:
            WebReaderView(
                document: document,
                readVM: readVM,
                explainVM: explainVM,
                mode: mode,
                refocusToken: refocusToken,
                initialSurfaceSize: surfaceSize,
                // The compact landscape controls are two local capsules, not
                // a full-width bottom bar. `bottomContentOcclusion` describes
                // only a full-width covered band; reporting 68pt here made
                // Kobo discard visible text across the entire bottom of both
                // columns, so playback reached its (truncated) snapshot end
                // and turned while words were still visible on screen.
                bottomContentOcclusion:
                    ReaderPlaybackBarLayoutContract.bottomContentOcclusion(
                        controlsCoverFullWidth: false
                    ),
                weReadTOC: weReadTOC,
                pageTurnController: liveWebPageTurn
            )
        case .pdf:
            if document.usesNativePDFRendering {
                PDFReaderView(document: document, readVM: readVM, explainVM: explainVM, mode: mode, refocusToken: refocusToken)
            } else {
                TextReaderView(document: document, readVM: readVM, explainVM: explainVM, mode: mode, refocusToken: refocusToken)
            }
        case .photo:
            PhotoReaderCanvas(document: document, readVM: readVM, explainVM: explainVM, mode: mode, refocusToken: refocusToken)
        case .kindle:
            KindleReaderView(document: document, readVM: readVM, explainVM: explainVM, mode: mode, refocusToken: refocusToken)
        case .epub, .text:
            // EPUB 已原生解析为段落（含图片段），与 text 源共用 TextReaderView 渲染管线
            TextReaderView(document: document, readVM: readVM, explainVM: explainVM, mode: mode, refocusToken: refocusToken)
        }
    }

    // MARK: 控制条

    private var controls: some View {
        Group {
            if mode == .read {
                ReadControlBar(
                    vm: readVM,
                    showTOC: document.sourceKind == .weread ? { weReadTOC.present() } : nil,
                    previousPage: pageTurnAction(.previous),
                    nextPage: pageTurnAction(.next)
                )
            } else {
                ExplainControlBar(
                    vm: explainVM,
                    showTOC: document.sourceKind == .weread ? { weReadTOC.present() } : nil,
                    previousPage: pageTurnAction(.previous),
                    nextPage: pageTurnAction(.next)
                )
            }
        }
        // Keep the same fixed 72pt boundary as Kindle in every state. Explain
        // captions overflow upward as a visual overlay and never take layout
        // space, so WeRead/Google Books do not repaginate sentence by sentence.
        .frame(height: ReaderPlaybackBarLayoutContract.reservedPortraitHeight(for: mode))
        .background(.regularMaterial)
        .zIndex(1)
        .accessibilityIdentifier("readerPlaybackBar")
        .opacity(weReadTOC.isPresented ? 0 : 1)
        .allowsHitTesting(!weReadTOC.isPresented && !weReadTOC.isJumping)
        .accessibilityHidden(weReadTOC.isPresented || weReadTOC.isJumping)
    }

    @ViewBuilder
    private var landscapeControls: some View {
        if mode == .read {
            ReaderLandscapeReadOverlay(
                vm: readVM,
                showTOC: document.sourceKind == .weread ? { weReadTOC.present() } : nil,
                previousPage: pageTurnAction(.previous),
                nextPage: pageTurnAction(.next)
            )
        } else {
            ReaderLandscapeExplainOverlay(
                vm: explainVM,
                showTOC: document.sourceKind == .weread ? { weReadTOC.present() } : nil,
                previousPage: pageTurnAction(.previous),
                nextPage: pageTurnAction(.next)
            )
        }
    }

    private func pageTurnAction(
        _ direction: LiveWebPageTurnDirection
    ) -> (() -> Void)? {
        guard ReaderPlaybackNavigationContract.usesPageTurns(
            for: document.sourceKind
        ) else {
            return nil
        }
        return {
            ReaderRunLog.write(
                "HOST page button direction=\(direction.rawValue) " +
                "source=\(document.sourceKind.rawValue) mode=\(mode.rawValue)"
            )
            liveWebPageTurn.turn(direction)
        }
    }

    private var weReadTOCOverlay: some View {
        GeometryReader { proxy in
            let isLandscape = usesCompactPlaybackBar
            let panelWidth = isLandscape ? min(420, max(320, proxy.size.width * 0.44)) : proxy.size.width
            let panelHeight = isLandscape ? proxy.size.height : min(proxy.size.height * 0.72, 620)

            ZStack(alignment: isLandscape ? .trailing : .bottom) {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture { weReadTOC.dismiss() }

                WeReadNativeTOCPanel(
                    entries: weReadTOC.entries,
                    isLoading: weReadTOC.isLoading,
                    errorText: weReadTOC.errorText,
                    isLandscape: isLandscape,
                    close: { weReadTOC.dismiss() },
                    select: { weReadTOC.select($0) }
                )
                .frame(width: panelWidth, height: panelHeight)
                .padding(.trailing, isLandscape ? 12 : 0)
                .transition(
                    isLandscape
                        ? .move(edge: .trailing).combined(with: .opacity)
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }
        }
    }

    private var weReadTOCJumpLockOverlay: some View {
        ZStack {
            Color.black.opacity(0.16)
                .ignoresSafeArea()

            HStack(spacing: 10) {
                ProgressView()
                    .tint(AppTheme.foreground)
                Text(AppLocalized("正在跳转章节…"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.foreground)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.mutedForeground.opacity(0.16), lineWidth: 0.5))
        }
        .allowsHitTesting(true)
    }

    private func googleBooksRecoveryOverlay(message: String) -> some View {
        ZStack {
            Color.black.opacity(0.34)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundColor(AppTheme.primary)

                Text(AppLocalized("Google Play 图书"))
                    .font(.headline)
                    .foregroundColor(AppTheme.foreground)

                Text(message)
                    .font(.subheadline)
                    .foregroundColor(AppTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    rebindGoogleBooks()
                } label: {
                    Text(AppLocalized("重新登录"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .accessibilityIdentifier("googleBooksReaderRebindButton")

                Button {
                    closeGoogleBooksReader()
                } label: {
                    Text(AppLocalized("关闭"))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.mutedForeground)
                .accessibilityIdentifier("googleBooksReaderExitButton")
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.55), lineWidth: 1)
            )
            .padding(.horizontal, 24)
        }
        .allowsHitTesting(true)
        .accessibilityIdentifier("googleBooksReaderRecoveryOverlay")
    }

    private func rebindGoogleBooks() {
        googleBooksStore.clearError()
        // The Home shelf owns the one canonical binding sheet. Notify it before
        // closing this session so SwiftUI can present that flow immediately.
        NotificationCenter.default.post(
            name: .castReaderGoogleBooksRebindRequested,
            object: nil
        )
        coordinator.close()
    }

    private func closeGoogleBooksReader() {
        googleBooksStore.clearError()
        coordinator.close()
    }

    private func koboRecoveryOverlay(message: String) -> some View {
        ZStack {
            Color.black.opacity(0.34).ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundColor(AppTheme.primary)
                Text("Kobo")
                    .font(.headline)
                    .foregroundColor(AppTheme.foreground)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(AppTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    koboStore.clearError()
                    liveWebPageTurn.retryReader()
                } label: {
                    Text(AppLocalized("重试打开"))
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                .accessibilityIdentifier("koboReaderRetryButton")
                Button {
                    koboStore.clearError()
                    NotificationCenter.default.post(
                        name: .castReaderKoboRebindRequested,
                        object: nil
                    )
                    coordinator.close()
                } label: {
                    Text(AppLocalized("重新登录"))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.mutedForeground)
                .accessibilityIdentifier("koboReaderRebindButton")
                Button {
                    koboStore.clearError()
                    coordinator.close()
                } label: {
                    Text(AppLocalized("关闭"))
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .tint(AppTheme.mutedForeground)
                .accessibilityIdentifier("koboReaderExitButton")
            }
            .padding(20)
            .frame(maxWidth: 340)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(AppTheme.border.opacity(0.55), lineWidth: 1)
            )
            .padding(.horizontal, 24)
        }
        .allowsHitTesting(true)
        .accessibilityIdentifier("koboReaderRecoveryOverlay")
    }

    private var paywallBinding: Binding<Bool> {
        Binding(
            get: { readVM.showPaywall || explainVM.showPaywall },
            set: { newValue in
                if !newValue { readVM.showPaywall = false; explainVM.showPaywall = false }
            }
        )
    }

    private func scheduleRefocus(reason: String, delay: UInt64) {
        refocusTask?.cancel()
        refocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            refocusToken &+= 1
            ReaderRunLog.write("HOST refocus reason=\(reason) token=\(refocusToken) mode=\(mode.rawValue) size=\(Int(readerSurfaceSize.width))x\(Int(readerSurfaceSize.height))")
            #if DEBUG
            NSLog("CRDBG REFOCUS host reason=%@ token=%d mode=%@ size=%.0fx%.0f",
                  reason, refocusToken, mode.rawValue, readerSurfaceSize.width, readerSurfaceSize.height)
            #endif
        }
    }

    private func scheduleRefocusBurst(reason: String) {
        refocusTask?.cancel()
        refocusTask = Task { @MainActor in
            let delays: [UInt64] = [220_000_000, 650_000_000, 1_150_000_000, 2_000_000_000]
            for (index, delay) in delays.enumerated() {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                refocusToken &+= 1
                ReaderRunLog.write("HOST refocus-burst reason=\(reason) pass=\(index + 1) token=\(refocusToken) mode=\(mode.rawValue) size=\(Int(readerSurfaceSize.width))x\(Int(readerSurfaceSize.height))")
                #if DEBUG
                NSLog("CRDBG REFOCUS host burst reason=%@ pass=%d token=%d mode=%@ size=%.0fx%.0f",
                      reason, index + 1, refocusToken, mode.rawValue, readerSurfaceSize.width, readerSurfaceSize.height)
                #endif
            }
        }
    }
}

private struct ReaderSurfaceSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

/// Kindle-style one-line console used by the generic Read and Explain bars.
/// The left playback area and right utility area receive equal width so the
/// control deck stays visually stable as voice/status availability changes.
struct ReaderPlaybackConsole<PlaybackControls: View>: View {
    let playbackStatus: String
    let statusMessage: String?
    let voiceLanguage: String?
    let showTOC: (() -> Void)?
    let playbackControls: PlaybackControls

    init(
        playbackStatus: String,
        statusMessage: String? = nil,
        voiceLanguage: String?,
        showTOC: (() -> Void)?,
        @ViewBuilder playbackControls: () -> PlaybackControls
    ) {
        self.playbackStatus = playbackStatus
        self.statusMessage = statusMessage
        self.voiceLanguage = voiceLanguage
        self.showTOC = showTOC
        self.playbackControls = playbackControls()
    }

    var body: some View {
        HStack(spacing: 0) {
            playbackControls
                .frame(maxWidth: .infinity)
                .layoutPriority(1)

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.mutedForeground)
                    .lineLimit(1)
                    .frame(maxWidth: 72)
            }

            Divider().frame(height: 30)

            utilityCluster
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .frame(height: ReaderPlaybackBarLayoutContract.consoleHeight)
        .foregroundStyle(AppTheme.foreground)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(playbackStatus))
    }

    private var utilityCluster: some View {
        HStack(spacing: 8) {
            if let showTOC {
                Button(action: showTOC) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(AppLocalized("目录")))
            }

            voiceControl
            SpeedMenu(style: .compact)
        }
    }

    @ViewBuilder
    private var voiceControl: some View {
        if let voiceLanguage, !voiceLanguage.isEmpty {
            PlaybackVoiceButton(
                language: voiceLanguage,
                size: 32,
                showsLabel: false
            )
        } else {
            ZStack {
                Circle()
                    .stroke(AppTheme.mutedForeground.opacity(0.55), lineWidth: 1.5)
                Image(systemName: "waveform")
                    .font(.system(size: 14))
                    .foregroundStyle(AppTheme.mutedForeground.opacity(0.55))
            }
            .frame(width: 28, height: 28)
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)
        }
    }
}

struct ReaderPlaybackPageTurnButton: View {
    let direction: LiveWebPageTurnDirection
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(
                systemName: direction == .previous
                    ? "chevron.left"
                    : "chevron.right"
            )
            .font(.system(size: 20, weight: .semibold))
            .frame(width: 36, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(
            direction == .previous
                ? "readerPreviousPageButton"
                : "readerNextPageButton"
        )
        .accessibilityLabel(
            Text(
                direction == .previous
                    ? AppLocalized("上一页")
                    : AppLocalized("下一页")
            )
        )
    }
}

// MARK: - 朗读控制条

private struct ReadControlBar: View {
    @ObservedObject var vm: ReadAloudViewModel
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared
    let showTOC: (() -> Void)?
    let previousPage: (() -> Void)?
    let nextPage: (() -> Void)?

    private var stablePresentationState: ReadPlaybackPresentationState {
        ReadPlaybackPresentationContract.resolve(
            isPlaying: vm.isPlaying,
            isWaitingForPlayableAudio: false,
            status: vm.status
        )
    }

    private var rawWaiting: Bool {
        !vm.isPlaying && (vm.isWaitingForPlayableAudio || vm.isBuffering)
    }

    var body: some View {
        ReaderDebouncedWaitingPresentation(
            stablePresentation: stablePresentationState,
            rawWaiting: rawWaiting,
            waitingPresentation: .waiting
        ) { presentationState in
            ReaderPlaybackConsole(
                playbackStatus: playbackStatus(for: presentationState),
                statusMessage: voiceSwitch.progress?.localizedMessage,
                voiceLanguage: vm.hasStartedPlayback ? vm.playbackLanguage : nil,
                showTOC: showTOC
            ) {
                HStack(spacing: 10) {
                    if let previousPage {
                        ReaderPlaybackPageTurnButton(
                            direction: .previous,
                            action: previousPage
                        )
                    } else {
                        Button { vm.skipBackward() } label: {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 20))
                                .frame(width: 36, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        guard presentationState != .waiting else { return }
                        vm.togglePlayPause()
                    } label: {
                        ReaderPrimaryPlaybackButtonContent(
                            icon: playButtonIcon(for: presentationState),
                            size: ReaderPrimaryPlaybackButtonVisualContract.portraitSize
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(presentationState == .waiting)
                    .accessibilityIdentifier("readPlayPauseButton")
                    .accessibilityLabel(Text(playbackStatus(for: presentationState)))
                    .accessibilityValue(Text(presentationState == .playing ? "playing" : "paused"))
                    if let nextPage {
                        ReaderPlaybackPageTurnButton(
                            direction: .next,
                            action: nextPage
                        )
                    } else {
                        Button { vm.skipForward() } label: {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 20))
                                .frame(width: 36, height: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private func playbackStatus(
        for presentationState: ReadPlaybackPresentationState
    ) -> String {
        if voiceSwitch.progress != nil {
            return AppLocalized("正在准备…")
        }
        switch presentationState {
        case .playing:
            return AppLocalized("朗读中")
        case .waiting:
            return AppLocalized("正在准备下一段…")
        case .retry:
            return AppLocalized("重试朗读")
        case .paused:
            return AppLocalized("已暂停")
        }
    }

    private func playButtonIcon(
        for presentationState: ReadPlaybackPresentationState
    ) -> ReaderPrimaryPlaybackButtonIcon {
        switch presentationState {
        case .playing:
            return .pause
        case .retry:
            return .retry
        case .waiting:
            return .loading
        case .paused:
            return .play
        }
    }
}

private struct ReaderLandscapeReadOverlay: View {
    @ObservedObject var vm: ReadAloudViewModel
    let showTOC: (() -> Void)?
    let previousPage: (() -> Void)?
    let nextPage: (() -> Void)?

    private var stablePresentationState: ReadPlaybackPresentationState {
        ReadPlaybackPresentationContract.resolve(
            isPlaying: vm.isPlaying,
            isWaitingForPlayableAudio: false,
            status: vm.status
        )
    }

    private var rawWaiting: Bool {
        !vm.isPlaying && (vm.isWaitingForPlayableAudio || vm.isBuffering)
    }

    var body: some View {
        ReaderDebouncedWaitingPresentation(
            stablePresentation: stablePresentationState,
            rawWaiting: rawWaiting,
            waitingPresentation: .waiting
        ) { presentationState in
            HStack(alignment: .bottom, spacing: 14) {
                HStack(spacing: 18) {
                    if let previousPage {
                        ReaderPlaybackPageTurnButton(
                            direction: .previous,
                            action: previousPage
                        )
                    } else {
                        Button { vm.skipBackward() } label: {
                            Image(systemName: "gobackward.15")
                                .font(.system(size: 19))
                                .frame(width: 36, height: 36)
                        }
                    }
                    Button {
                        guard presentationState != .waiting else { return }
                        vm.togglePlayPause()
                    } label: {
                        ReaderPrimaryPlaybackButtonContent(
                            icon: playButtonIcon(for: presentationState),
                            size: ReaderPrimaryPlaybackButtonVisualContract.landscapeSize
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(presentationState == .waiting)
                    .accessibilityIdentifier("readPlayPauseButton")
                    .accessibilityLabel(Text(playbackStatus(for: presentationState)))
                    .accessibilityValue(Text(presentationState == .playing ? "playing" : "paused"))
                    if let nextPage {
                        ReaderPlaybackPageTurnButton(
                            direction: .next,
                            action: nextPage
                        )
                    } else {
                        Button { vm.skipForward() } label: {
                            Image(systemName: "goforward.15")
                                .font(.system(size: 19))
                                .frame(width: 36, height: 36)
                        }
                    }
                }
                .foregroundColor(AppTheme.foreground)
                .readerLandscapePill()

                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    if let showTOC {
                        Button(action: showTOC) {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 19, weight: .semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(AppLocalized("目录")))
                    }
                    if vm.hasStartedPlayback {
                        PlaybackVoiceButton(language: vm.playbackLanguage)
                    }
                    SpeedMenu()
                }
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            }
        }
    }

    private func playbackStatus(
        for presentationState: ReadPlaybackPresentationState
    ) -> String {
        switch presentationState {
        case .playing: return AppLocalized("朗读中")
        case .waiting: return AppLocalized("正在准备下一段…")
        case .retry: return AppLocalized("重试朗读")
        case .paused: return AppLocalized("已暂停")
        }
    }

    private func playButtonIcon(
        for presentationState: ReadPlaybackPresentationState
    ) -> ReaderPrimaryPlaybackButtonIcon {
        switch presentationState {
        case .playing: return .pause
        case .waiting: return .loading
        case .retry: return .retry
        case .paused: return .play
        }
    }
}

private struct ReaderLandscapeExplainOverlay: View {
    @ObservedObject var vm: ExplainViewModel
    let showTOC: (() -> Void)?
    let previousPage: (() -> Void)?
    let nextPage: (() -> Void)?

    private var stablePresentationState: ReaderExplainPlaybackPresentationState {
        switch vm.status {
        case .idle, .planning:
            return .start
        case .error:
            return .retry
        case .streaming:
            return vm.isPlaying ? .playing : .paused
        case .completed:
            return .replay
        }
    }

    private var rawWaiting: Bool {
        vm.isPreparingNext || vm.isContinuingLivePage || statusIsPlanning
    }

    private var statusIsPlanning: Bool {
        if case .planning = vm.status { return true }
        return false
    }

    var body: some View {
        ReaderDebouncedWaitingPresentation(
            stablePresentation: stablePresentationState,
            rawWaiting: rawWaiting,
            waitingPresentation: .waiting
        ) { presentationState in
            VStack(spacing: 8) {
                caption
                HStack(alignment: .bottom, spacing: 14) {
                    controlPill(for: presentationState)
                    Spacer(minLength: 0)
                    HStack(spacing: 10) {
                        if let showTOC {
                            Button(action: showTOC) {
                                Image(systemName: "list.bullet")
                                    .font(.system(size: 19, weight: .semibold))
                                    .frame(width: 34, height: 34)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text(AppLocalized("目录")))
                        }
                        PlaybackVoiceButton(language: vm.playbackLanguage, size: 34)
                        SpeedMenu()
                    }
                    .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                }
            }
        }
    }

    @ViewBuilder
    private var caption: some View {
        if shouldShowCaption {
            Text(vm.explanationText)
                .font(.callout.weight(.medium))
                .foregroundColor(AppTheme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(maxWidth: 760)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.mutedForeground.opacity(0.12), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var shouldShowCaption: Bool {
        guard !vm.isPreparingNext, !vm.explanationText.isEmpty else { return false }
        if case .streaming = vm.status { return true }
        return false
    }

    private func controlPill(
        for presentationState: ReaderExplainPlaybackPresentationState
    ) -> some View {
        HStack(spacing: 14) {
            if let previousPage {
                ReaderPlaybackPageTurnButton(
                    direction: .previous,
                    action: previousPage
                )
            }
            Button {
                performExplainAction(for: presentationState)
            } label: {
                ReaderPrimaryPlaybackButtonContent(
                    icon: explainButtonIcon(for: presentationState),
                    size: ReaderPrimaryPlaybackButtonVisualContract.landscapeSize
                )
            }
            .buttonStyle(.plain)
            .disabled(presentationState == .waiting)
            .accessibilityIdentifier(
                explainAccessibilityIdentifier(for: presentationState)
            )
            .accessibilityLabel(Text(explainStatusLabel(for: presentationState)))
            .accessibilityValue(
                Text(presentationState == .playing ? "playing" : "paused")
            )

            if let nextPage {
                ReaderPlaybackPageTurnButton(
                    direction: .next,
                    action: nextPage
                )
            } else {
                Text(explainStatusLabel(for: presentationState))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .foregroundColor(AppTheme.foreground)
        .readerLandscapePill()
    }

    private func performExplainAction(
        for presentationState: ReaderExplainPlaybackPresentationState
    ) {
        switch presentationState {
        case .start, .retry:
            vm.start()
        case .playing, .paused:
            vm.togglePlayPause()
        case .replay:
            vm.replay()
        case .waiting:
            break
        }
    }

    private func explainButtonIcon(
        for presentationState: ReaderExplainPlaybackPresentationState
    ) -> ReaderPrimaryPlaybackButtonIcon {
        switch presentationState {
        case .start: return .sparkles
        case .playing: return .pause
        case .paused: return .play
        case .retry, .replay: return .retry
        case .waiting: return .loading
        }
    }

    private func explainAccessibilityIdentifier(
        for presentationState: ReaderExplainPlaybackPresentationState
    ) -> String {
        switch presentationState {
        case .start, .retry:
            return "explainStartButton"
        case .playing, .paused, .waiting:
            return "explainPlayPauseButton"
        case .replay:
            return "explainReplayButton"
        }
    }

    private func explainStatusLabel(
        for presentationState: ReaderExplainPlaybackPresentationState
    ) -> String {
        if presentationState == .waiting {
            if case .streaming = vm.status {
                return AppLocalized("正在准备下一段…")
            }
            if vm.isContinuingLivePage {
                return AppLocalized("继续讲解…")
            }
            return vm.stageText.isEmpty
                ? AppLocalized("通读全文…")
                : vm.stageText
        }
        switch vm.status {
        case .idle:
            return AppLocalized("开始解读")
        case .error:
            return AppLocalized("重试解读")
        case .planning:
            return AppLocalized("开始解读")
        case .streaming(let block, let total):
            return "Explaining · block \(block + 1)/\(total)"
        case .completed:
            return AppLocalized("解读完成")
        }
    }
}

private extension View {
    func readerLandscapePill() -> some View {
        self
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.mutedForeground.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 10, y: 2)
    }
}

enum ReaderRunLog {
    static func write(_ message: String) {
        #if DEBUG
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let line = "\(formatter.string(from: Date())) \(message)\n"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = docs.appendingPathComponent("reader-refocus.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data(line.utf8).write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } catch {
            try? handle.close()
        }
        #endif
    }
}

/// 共享调速菜单（朗读 / 解读控制条复用）：选速即写入全局 speed 并立刻作用于当前播放（共享 AudioPlayerService）。
enum SpeedMenuStyle {
    case capsule
    case console
    case compact
}

struct SpeedMenu: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var pro = ProManager.shared
    @ObservedObject private var audio = AudioPlayerService.shared
    @State private var showSpeedPicker = false
    @State private var showPaywall = false
    var style: SpeedMenuStyle = .capsule

    private var displayedSpeed: Float {
        Float(settings.effectiveSpeed(isPro: pro.isPro))
    }

    var body: some View {
        Button {
            showSpeedPicker = true
        } label: {
            switch style {
            case .capsule:
                HStack(spacing: 3) {
                    Image(systemName: "speedometer").font(.caption)
                    Text(String(format: "%.2gx", Double(displayedSpeed)))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(width: 70, height: 36)
                .background(AppTheme.surfaceVariant)
                .foregroundColor(AppTheme.foreground)
                .cornerRadius(8)
            case .console:
                VStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(height: 28)
                    Text(String(format: "%.2gx", Double(displayedSpeed)))
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(AppTheme.foreground)
                .frame(maxWidth: .infinity)
            case .compact:
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                    Text(String(format: "%.2gx", Double(displayedSpeed)))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(AppTheme.foreground)
                .frame(width: 62, height: 36)
            }
        }
        .buttonStyle(.plain)
        .fixedSize(horizontal: style != .console, vertical: false)
        .layoutPriority(style == .console ? 0 : 1)
        .contentShape(Rectangle())
        .accessibilityLabel(Text(AppLocalized("Playback Speed")))
        .accessibilityValue(Text(String(format: "%.2gx", Double(displayedSpeed))))
        .popover(isPresented: $showSpeedPicker, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            speedPicker
                .presentationCompactAdaptation(.popover)
        }
        .sheet(isPresented: $showPaywall) {
            PaywallView(analyticsTrigger: "pro_speed", analyticsSurface: "reader_controls")
        }
    }

    private var speedPicker: some View {
        VStack(spacing: 14) {
            HStack {
                Text(AppLocalized("Playback Speed"))
                    .font(.headline)
                    .foregroundStyle(AppTheme.foreground)
                Spacer()
                Button {
                    showSpeedPicker = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(AppTheme.mutedForeground)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(AppLocalized("关闭")))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(AudioPlayerService.proSpeedOptions, id: \.self) { speed in
                    Button {
                        selectSpeed(speed)
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: isSelected(speed) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(isSelected(speed) ? AppTheme.primary : AppTheme.mutedForeground)
                            Text(String(format: "%.2gx", Double(speed)))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(AppTheme.foreground)
                            Spacer(minLength: 2)
                            if requiresPro(speed) {
                                Text("PRO")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(AppTheme.primary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(
                            isSelected(speed)
                                ? AppTheme.primary.opacity(0.12)
                                : AppTheme.surfaceVariant,
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(
                                    isSelected(speed) ? AppTheme.primary.opacity(0.45) : Color.clear,
                                    lineWidth: 1
                                )
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(String(format: "%.2gx", Double(speed))))
                }
            }
        }
        .padding(16)
        .frame(width: 292)
        .background(AppTheme.surface)
    }

    private func isSelected(_ speed: Float) -> Bool {
        abs(speed - displayedSpeed) < 0.01
    }

    private func requiresPro(_ speed: Float) -> Bool {
        !pro.isPro && Double(speed) > AppSettings.freeMaxSpeed
    }

    private func selectSpeed(_ speed: Float) {
        if requiresPro(speed) {
            showSpeedPicker = false
            refreshAccessThenSelectSpeed(speed)
            return
        }
        applySelectedSpeed(speed)
        showSpeedPicker = false
    }

    private func refreshAccessThenSelectSpeed(_ speed: Float) {
        Task { @MainActor in
            await pro.refresh()
            if pro.isPro {
                applySelectedSpeed(speed)
            } else {
                // Present after the speed popover has completed dismissal;
                // presenting two modal surfaces in one update loses the tap on
                // recent iOS versions.
                try? await Task.sleep(nanoseconds: 220_000_000)
                showPaywall = true
            }
        }
    }

    private func applySelectedSpeed(_ speed: Float) {
        settings.speed = Double(speed)
        let effective = Float(settings.effectiveSpeed(isPro: pro.isPro))
        audio.setPlaybackRate(effective)
        ReaderRunLog.write(
            "SPEED selected=\(String(format: "%.2f", Double(speed))) effective=\(String(format: "%.2f", Double(effective))) playing=\(audio.isPlaying ? "Y" : "N")"
        )
        #if DEBUG
        NSLog("CRDBG SPEED selected=%.2f effective=%.2f isPlaying=%@",
              Double(speed),
              Double(effective),
              audio.isPlaying ? "Y" : "N")
        #endif
    }
}
