//
//  KindleBookView.swift
//  CastReader
//

import Combine
import AVFoundation
import SwiftUI
import UIKit
import WebKit

struct KindleBookView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var importRouter: ImportRouter
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var playbackCenter = KindlePlaybackCenter.shared
    @ObservedObject private var playbackVoicePanel = PlaybackVoicePanelCenter.shared
    @StateObject private var model: KindleBookViewModel
    @State private var refocusTask: Task<Void, Never>?
    @State private var readerSurfaceSize: CGSize = .zero

    init(book: KindleBook) {
        _model = StateObject(wrappedValue: KindleBookViewModel(book: book))
    }

    private var usesCompactPlaybackBar: Bool {
        verticalSizeClass == .compact
    }

    private var shouldHidePlaybackForNativeTOC: Bool {
        model.isNativeTOCPresented || model.isKindleTOCVisible
    }

    private var headerHeight: CGFloat {
        usesCompactPlaybackBar ? 44 : 52
    }

    init(model: KindleBookViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                Divider()
                readerSurface
                if !usesCompactPlaybackBar {
                    Divider()
                    playbackBar
                        .opacity(shouldHidePlaybackForNativeTOC ? 0 : (model.isKindleSyncDialogVisible ? 0.45 : 1))
                        .allowsHitTesting(!shouldHidePlaybackForNativeTOC && !model.isKindleSyncDialogVisible)
                        .accessibilityHidden(shouldHidePlaybackForNativeTOC || model.isKindleSyncDialogVisible)
                }
            }

            if usesCompactPlaybackBar {
                landscapePlaybackOverlay
                    .padding(.horizontal, 22)
                    .padding(.bottom, 8)
                    .opacity(shouldHidePlaybackForNativeTOC ? 0 : (model.isKindleSyncDialogVisible ? 0.45 : 1))
                    .allowsHitTesting(!shouldHidePlaybackForNativeTOC && !model.isKindleSyncDialogVisible)
                    .accessibilityHidden(shouldHidePlaybackForNativeTOC || model.isKindleSyncDialogVisible)
            }

            if model.isNativeTOCPresented {
                nativeTOCOverlay
                    .zIndex(10)
            }

            if model.isNativeTOCJumpBlocking {
                nativeTOCJumpLockOverlay
                    .zIndex(20)
            }
        }
        .background(AppTheme.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .navigationBarHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(playbackCenter.isPresented ? .hidden : .visible, for: .tabBar)
        .onAppear {
            importRouter.hideMainChrome = playbackCenter.isPresented
            model.setReaderSurfaceAttached(true)
            model.setReaderPresented(playbackCenter.isPresented)
            model.setApplicationActive(scenePhase == .active)
            model.setPlayerControlOverlayPresented(playbackVoicePanel.isPresented)
            model.loadIfNeeded()
            schedulePlaybackRefocus(reason: "appear")
        }
        .onChange(of: playbackCenter.isPresented) { isPresented in
            guard playbackCenter.isOwning(model) else { return }
            importRouter.hideMainChrome = isPresented
            model.setReaderPresented(isPresented)
            if isPresented {
                model.noteReaderLayoutChange(reason: "expand")
                model.notePlaybackLayoutChange(reason: "expand")
                schedulePlaybackRefocus(reason: "expand")
            } else {
                refocusTask?.cancel()
                model.flushListeningAnchor(reason: "mini-player")
            }
        }
        .onChange(of: verticalSizeClass) { _ in
            guard playbackCenter.isPresented else { return }
            model.noteReaderLayoutChange(reason: "orientation")
            model.notePlaybackLayoutChange(reason: "orientation")
        }
        .onChange(of: playbackVoicePanel.isPresented) { presented in
            model.setPlayerControlOverlayPresented(presented)
        }
        .onPreferenceChange(KindleReaderSurfaceSizePreferenceKey.self) { size in
            guard playbackCenter.isPresented else { return }
            if model.isNativeTOCPresented || model.isKindleTOCVisible || playbackVoicePanel.isPresented {
                return
            }
            let previous = readerSurfaceSize
            readerSurfaceSize = size
            guard size.width > 4, size.height > 4 else { return }
            model.updateReaderSurfaceSize(size)
            let isInitialSurface = previous == .zero
            if !isInitialSurface, abs(previous.width - size.width) > 4 || abs(previous.height - size.height) > 4 {
                let reason = isInitialSurface ? "surfaceSize" : "reader-size"
                model.noteReaderLayoutChange(reason: reason)
                model.notePlaybackLayoutChange(reason: reason)
            }
        }
        .onChange(of: scenePhase) { phase in
            model.setApplicationActive(phase == .active)
            if phase == .active {
                model.noteReaderLayoutChange(reason: "foreground")
                model.notePlaybackLayoutChange(reason: "foreground")
                schedulePlaybackRefocus(reason: "foreground")
            } else {
                model.flushListeningAnchor(reason: phase == .background ? "background" : "inactive")
            }
        }
        .onReceive(AudioPlayerService.shared.$isPlaying.removeDuplicates()) { isPlaying in
            if !isPlaying, model.shouldCancelPlaybackRefocusOnAudioPause {
                refocusTask?.cancel()
                model.cancelPlaybackRefocusEffects(reason: "audio-paused")
            }
        }
        .onDisappear {
            // A model replacement can remove this old view while the new Kindle
            // reader is already presented. Do not briefly expose main chrome over
            // the replacement reader; explicit close/minimize owns that change.
            if !playbackCenter.isPresented || playbackCenter.model == nil {
                importRouter.hideMainChrome = false
            }
            refocusTask?.cancel()
            model.flushListeningAnchor(reason: "reader-disappear")
            model.setReaderPresented(false)
            model.setReaderSurfaceAttached(false)
            model.setPlayerControlOverlayPresented(false)
        }
        .sheet(isPresented: kindlePaywallBinding) {
            PaywallView(
                analyticsTrigger: model.mode == .read ? "listen_quota" : "explain_quota",
                analyticsSurface: "kindle_reader"
            )
        }
    }

    private var kindlePaywallBinding: Binding<Bool> {
        Binding(
            get: { model.showPaywall },
            set: { newValue in
                if !newValue { model.dismissPaywall() }
            }
        )
    }

    private var readerSurface: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { proxy in
                let webSize = KindleReaderSurfaceContract.renderSize(
                    measured: proxy.size,
                    stable: readerSurfaceSize,
                    isPlayerOverlayPresented: playbackVoicePanel.isPresented
                )
                let crop = model.effectiveViewportCrop(forSurfaceSize: webSize)
                KindleWebView(
                    webView: model.libraryRecoveryWebView ?? model.webView,
                    crop: model.libraryRecoveryWebView == nil ? crop : .identity
                )
                    .id(ObjectIdentifier(model.libraryRecoveryWebView ?? model.webView))
                    .frame(width: webSize.width, height: webSize.height)
                    .onAppear {
                        if !model.isNativeTOCPresented && !model.isKindleTOCVisible {
                            model.updateReaderSurfaceSize(webSize)
                        }
                    }
                    .onChange(of: webSize.width) { _ in
                        if !model.isNativeTOCPresented && !model.isKindleTOCVisible {
                            model.updateReaderSurfaceSize(webSize)
                        }
                    }
                    .onChange(of: webSize.height) { _ in
                        if !model.isNativeTOCPresented && !model.isKindleTOCVisible {
                            model.updateReaderSurfaceSize(webSize)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            preparingStatusOverlay
            if model.isStaleBookEntryError {
                staleBookRecoveryOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: KindleReaderSurfaceSizePreferenceKey.self, value: proxy.size)
            }
        )
    }

    private var staleBookRecoveryOverlay: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppTheme.primary)
            Text("Kindle 书籍需要重新同步")
                .font(.headline)
            Text("刷新会重新同步书架并更新这本书的入口，不会清除朗读设置。")
                .font(.subheadline)
                .foregroundStyle(AppTheme.mutedForeground)
                .multilineTextAlignment(.center)
            if model.isStaleBookRecovering {
                Text(model.staleBookRecoveryProgressText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedForeground)
            }
            if let message = model.staleBookRecoveryMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.destructive)
                    .multilineTextAlignment(.center)
            }
            Button {
                model.retryStaleBookRecovery()
            } label: {
                HStack(spacing: 8) {
                    if model.isStaleBookRecovering { ProgressView().tint(.white) }
                    Text(LocalizedStringKey(model.isStaleBookRecovering ? "正在修复…" : "修复并打开"))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppTheme.primary)
            .disabled(model.isStaleBookRecovering)
            Button("返回") {
                if KindlePlaybackCenter.shared.isPresented && KindlePlaybackCenter.shared.isOwning(model) {
                    KindlePlaybackCenter.shared.minimize()
                } else {
                    dismiss()
                }
            }
            .disabled(model.isStaleBookRecovering)
        }
        .padding(22)
        .frame(maxWidth: 380)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border, lineWidth: 0.5))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.2))
        .allowsHitTesting(true)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                if KindlePlaybackCenter.shared.isPresented && KindlePlaybackCenter.shared.isOwning(model) {
                    KindlePlaybackCenter.shared.minimize()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.foreground)
                    .frame(width: 34, height: 34)
            }

            Text(model.book.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundColor(AppTheme.foreground)

            Spacer(minLength: 8)

            HStack(spacing: 2) {
                kindleModeButton(.read, title: AppLocalized("朗读"))
                kindleModeButton(.explain, title: AppLocalized("解读"))
            }
            .padding(3)
            .background(AppTheme.surfaceVariant, in: Capsule())
            .opacity(model.isKindleSyncDialogVisible ? 0.5 : 1)
            .allowsHitTesting(!model.isKindleSyncDialogVisible)
        }
        .frame(height: headerHeight)
        .padding(.horizontal, 14)
        .background(.regularMaterial)
    }

    private func kindleModeButton(_ mode: ReaderMode, title: String) -> some View {
        Button {
            model.selectMode(mode)
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(model.mode == mode ? AppTheme.foreground : AppTheme.mutedForeground)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(model.mode == mode ? AppTheme.surface : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var nativeTOCOverlay: some View {
        GeometryReader { proxy in
            let isLandscape = usesCompactPlaybackBar
            let panelWidth = isLandscape ? min(420, max(320, proxy.size.width * 0.44)) : proxy.size.width
            let panelHeight = isLandscape ? proxy.size.height : min(proxy.size.height * 0.72, 620)

            ZStack(alignment: isLandscape ? .trailing : .bottom) {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .onTapGesture {
                        model.dismissNativeTOCPanel()
                    }

                KindleNativeTOCPanel(
                    entries: model.nativeTOCEntries,
                    isLoading: model.isNativeTOCLoading,
                    errorText: model.nativeTOCError,
                    isLandscape: isLandscape,
                    close: { model.dismissNativeTOCPanel() },
                    select: { model.selectNativeTOCEntry($0) }
                )
                .frame(width: panelWidth, height: panelHeight)
                .padding(.trailing, isLandscape ? 12 : 0)
                .padding(.bottom, isLandscape ? 0 : 0)
                .transition(isLandscape ? .move(edge: .trailing).combined(with: .opacity) : .move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var nativeTOCJumpLockOverlay: some View {
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

    @ViewBuilder
    private var preparingStatusOverlay: some View {
        if model.isKindleSyncDialogVisible {
            VStack {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text(AppLocalized("请先确认 Kindle 阅读位置。"))
                        .font(.caption.weight(.semibold))
                }
                .foregroundColor(AppTheme.foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(AppTheme.mutedForeground.opacity(0.16), lineWidth: 0.5))
                .padding(.top, 12)
                Spacer()
            }
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var playbackBar: some View {
        ZStack(alignment: .top) {
            if model.mode == .explain, let vm = model.explainVM {
                KindleExplainPlaybackBar(
                    vm: vm,
                    compact: usesCompactPlaybackBar,
                    isContinuingPage: model.isExplainTransitionLoading,
                    start: { startCurrentMode() },
                    previousPage: { previousPage() },
                    nextPage: { nextPage() },
                    showTOC: { showTOC() }
                )
            } else if let vm = model.readVM {
                KindleReadPlaybackBar(
                    vm: vm,
                    isPreparing: model.isPlaybackPreparing,
                    compact: usesCompactPlaybackBar,
                    start: { startCurrentMode() },
                    previousPage: { previousPage() },
                    nextPage: { nextPage() },
                    showTOC: { showTOC() }
                )
            } else {
                KindleEmptyPlaybackBar(
                    isPreparing: model.isPlaybackPreparing,
                    compact: usesCompactPlaybackBar,
                    play: { startCurrentMode() },
                    previousPage: { previousPage() },
                    nextPage: { nextPage() },
                    showTOC: { showTOC() }
                )
            }

            if let error = model.playbackErrorText, !error.isEmpty {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.red)
                    .lineLimit(2)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: -42)
                    .allowsHitTesting(false)
            }
        }
        // Playback state, voice availability and errors must never change the
        // Kindle viewport height. A fixed single-line console prevents React
        // from reconciling the reader surface when playback begins.
        .frame(maxWidth: .infinity)
        .frame(height: 72)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private var landscapePlaybackOverlay: some View {
        if model.mode == .explain, let vm = model.explainVM {
            KindleLandscapeExplainOverlay(
                vm: vm,
                isContinuingPage: model.isExplainTransitionLoading,
                start: { startCurrentMode() },
                previousPage: { previousPage() },
                nextPage: { nextPage() },
                showTOC: { showTOC() }
            )
        } else if let vm = model.readVM {
            KindleLandscapeReadOverlay(
                vm: vm,
                isPreparing: model.isPlaybackPreparing,
                start: { startCurrentMode() },
                previousPage: { previousPage() },
                nextPage: { nextPage() },
                showTOC: { showTOC() }
            )
        } else {
            KindleLandscapeEmptyOverlay(
                isPreparing: model.isPlaybackPreparing,
                start: { startCurrentMode() },
                previousPage: { previousPage() },
                nextPage: { nextPage() },
                showTOC: { showTOC() }
            )
        }
    }

    private func showTOC() {
        model.toggleTOCProbeFromButton(preferCachedOnly: usesCompactPlaybackBar || !model.nativeTOCEntries.isEmpty)
    }

    private func startCurrentMode() {
        Task {
            do {
                model.playbackErrorText = nil
                try await model.startCurrentMode()
            } catch is CancellationError {
                // Cancellation is an internal lifecycle signal (for example while
                // Kindle is applying its cloud/local position), not a user-facing
                // playback failure.
                KindleRunLog.write("KINDLE start cancelled mode=\(model.mode.rawValue)")
            } catch {
                #if DEBUG
                NSLog("CRDBG KINDLE start error mode=%@ %@", model.mode.rawValue, error.localizedDescription)
                #endif
                model.statusText = error.localizedDescription
                model.playbackErrorText = error.localizedDescription
                KindleRunLog.write("KINDLE start failed mode=\(model.mode.rawValue) error=\(error.localizedDescription)")
            }
        }
    }

    private func previousPage() {
        KindleRunLog.write("KINDLE button tap previous")
        Task { await model.turnPage(.previous) }
    }

    private func nextPage() {
        KindleRunLog.write("KINDLE button tap next")
        Task { await model.turnPage(.next) }
    }

    private func schedulePlaybackRefocus(reason: String) {
        refocusTask?.cancel()
        guard model.shouldRunPlaybackRefocus else { return }
        refocusTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.refocusDelayNanoseconds(reason: reason))
            guard !Task.isCancelled else { return }
            guard model.shouldRunPlaybackRefocus else { return }
            await model.refocusPlaybackPosition(reason: reason)
        }
    }

    private static func refocusDelayNanoseconds(reason: String) -> UInt64 {
        switch reason {
        case "orientation":
            return 1_650_000_000
        case "reader-size", "surfaceSize":
            return 1_250_000_000
        case "foreground":
            return 950_000_000
        default:
            return 650_000_000
        }
    }
}

private struct KindleReaderSurfaceSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

enum KindleReaderSurfaceContract {
    static func renderSize(
        measured: CGSize,
        stable: CGSize,
        isPlayerOverlayPresented: Bool
    ) -> CGSize {
        guard isPlayerOverlayPresented,
              stable.width > 4,
              stable.height > 4 else { return measured }
        return stable
    }
}

private struct KindleEmptyPlaybackBar: View {
    let isPreparing: Bool
    let compact: Bool
    let play: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void

    var body: some View {
        KindlePlaybackConsole(
            isLandscape: compact,
            playbackStatus: isPreparing ? AppLocalized("正在准备…") : AppLocalized("已暂停"),
            voiceLanguage: nil,
            previousPage: previousPage,
            nextPage: nextPage,
            showTOC: showTOC
        ) {
            Button(action: play) {
                KindlePlayButtonContent(
                    isLoading: isPreparing,
                    isPlaying: false,
                    size: compact ? 44 : 52
                )
            }
            .disabled(isPreparing)
        }
    }
}

private struct KindleReadPlaybackBar: View {
    @ObservedObject var vm: ReadAloudViewModel
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared
    let isPreparing: Bool
    let compact: Bool
    let start: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void

    private var isLoading: Bool {
        voiceSwitch.progress != nil ||
            isPreparing ||
            (vm.status.isLoadingOrStreaming && !vm.isPlaying && !vm.canResumePlayback)
    }

    var body: some View {
        KindlePlaybackConsole(
            isLandscape: compact,
            playbackStatus: playbackStatus,
            statusMessage: voiceSwitch.progress?.localizedMessage,
            voiceLanguage: vm.hasStartedPlayback ? vm.playbackLanguage : nil,
            previousPage: previousPage,
            nextPage: nextPage,
            showTOC: showTOC
        ) {
            Button(action: start) {
                KindlePlayButtonContent(
                    isLoading: isLoading,
                    isPlaying: vm.isPlaying,
                    size: compact ? 44 : 52
                )
            }
            .disabled(isLoading)
        }
    }

    private var playbackStatus: String {
        if voiceSwitch.progress != nil || isLoading { return AppLocalized("正在准备…") }
        return vm.isPlaying ? AppLocalized("朗读中") : AppLocalized("已暂停")
    }
}

private struct KindlePlayButtonContent: View {
    let isLoading: Bool
    let isPlaying: Bool
    let size: CGFloat
    @State private var isRotating = false

    var body: some View {
        ZStack {
            if isLoading {
                Circle()
                    .fill(AppTheme.primary)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundColor(.white)
                    .rotationEffect(.degrees(isRotating ? 360 : 0))
                    .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: isRotating)
            } else {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: size))
                    .foregroundColor(AppTheme.primary)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            isRotating = isLoading
        }
        .onChange(of: isLoading) { loading in
            isRotating = loading
        }
    }
}

private struct KindlePageTurnButton: View {
    let systemName: String
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 20, weight: .semibold))
                .frame(width: 36, height: 36)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabel ?? systemName))
    }
}

/// One single-line control deck for every Kindle playback state and
/// orientation. Previous/next stay immediately beside play; TOC, voice and
/// speed form one compact tool group. Button order and height never change.
private struct KindlePlaybackConsole<PlayControl: View>: View {
    let isLandscape: Bool
    let playbackStatus: String
    let statusMessage: String?
    let voiceLanguage: String?
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void
    let playControl: PlayControl

    init(
        isLandscape: Bool,
        playbackStatus: String,
        statusMessage: String? = nil,
        voiceLanguage: String?,
        previousPage: @escaping () -> Void,
        nextPage: @escaping () -> Void,
        showTOC: @escaping () -> Void,
        @ViewBuilder playControl: () -> PlayControl
    ) {
        self.isLandscape = isLandscape
        self.playbackStatus = playbackStatus
        self.statusMessage = statusMessage
        self.voiceLanguage = voiceLanguage
        self.previousPage = previousPage
        self.nextPage = nextPage
        self.showTOC = showTOC
        self.playControl = playControl()
    }

    var body: some View {
        if isLandscape {
            compactSingleLineBody
                .kindleLandscapePill()
        } else {
            fullWidthBody
                .frame(height: 64)
        }
    }

    /// Portrait uses the full bar width as two balanced interaction zones.
    /// Keeping the playback cluster and tool cluster in equal flexible columns
    /// prevents an intrinsic-width HStack from bunching every button together
    /// in the middle while the surrounding material spans the whole screen.
    private var fullWidthBody: some View {
        HStack(spacing: 0) {
            playbackCluster(spacing: 8)
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

            utilityCluster(spacing: 8)
                .frame(maxWidth: .infinity)
                .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .foregroundStyle(AppTheme.foreground)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(playbackStatus))
    }

    /// Landscape remains an intrinsic capsule overlay, so it deliberately
    /// keeps the compact single-line composition instead of expanding.
    private var compactSingleLineBody: some View {
        HStack(spacing: 12) {
            playbackCluster(spacing: 12)

            if let statusMessage, !statusMessage.isEmpty {
                Text(statusMessage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AppTheme.mutedForeground)
                    .lineLimit(1)
                    .frame(maxWidth: 180)
            }

            Divider().frame(height: 30)
            utilityCluster(spacing: 12)
        }
        .foregroundStyle(AppTheme.foreground)
        .accessibilityElement(children: .contain)
        .accessibilityValue(Text(playbackStatus))
    }

    private func playbackCluster(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            KindlePageTurnButton(
                systemName: "chevron.left",
                accessibilityLabel: AppLocalized("上一页"),
                action: previousPage
            )
            playControl
            KindlePageTurnButton(
                systemName: "chevron.right",
                accessibilityLabel: AppLocalized("下一页"),
                action: nextPage
            )
        }
    }

    private func utilityCluster(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            KindlePageTurnButton(
                systemName: "list.bullet",
                accessibilityLabel: AppLocalized("目录"),
                action: showTOC
            )
            voiceControl(showsLabel: false)
            SpeedMenu(style: .compact)
        }
    }

    @ViewBuilder
    private func voiceControl(showsLabel: Bool) -> some View {
        if let voiceLanguage, !voiceLanguage.isEmpty {
            PlaybackVoiceButton(
                language: voiceLanguage,
                size: 32,
                showsLabel: showsLabel
            )
        } else {
            VStack(spacing: showsLabel ? 4 : 0) {
                ZStack {
                    Circle()
                        .stroke(AppTheme.mutedForeground.opacity(0.55), lineWidth: 1.5)
                    Image(systemName: "waveform")
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(AppTheme.mutedForeground.opacity(0.55))
                }
                .frame(width: 28, height: 28)
                    .frame(width: 32, height: 32)
                if showsLabel {
                    Text(AppLocalized("音色"))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AppTheme.mutedForeground.opacity(0.65))
                }
            }
            .accessibilityHidden(true)
        }
    }
}

private struct KindleExplainPlaybackBar: View {
    @ObservedObject var vm: ExplainViewModel
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared
    let compact: Bool
    let isContinuingPage: Bool
    let start: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            if !compact {
                KindleExplainCaption(
                    vm: vm,
                    isContinuingPage: isContinuingPage,
                    alignment: .center,
                    maxWidth: 620
                )
                .padding(.horizontal, 18)
                .offset(y: -42)
                .allowsHitTesting(false)
                .zIndex(1)
            }

            KindlePlaybackConsole(
                isLandscape: compact,
                playbackStatus: playbackStatus,
                statusMessage: voiceSwitch.progress?.localizedMessage,
                voiceLanguage: vm.playbackLanguage,
                previousPage: previousPage,
                nextPage: nextPage,
                showTOC: showTOC
            ) {
                centerControl
            }
        }
        .foregroundColor(AppTheme.foreground)
    }

    private var playbackStatus: String {
        if voiceSwitch.progress != nil || isContinuingPage || vm.isPreparingNext {
            return AppLocalized("正在准备…")
        }
        switch vm.status {
        case .idle: return AppLocalized("开始解读")
        case .planning: return AppLocalized("正在准备…")
        case .streaming: return vm.isPlaying ? AppLocalized("解读中") : AppLocalized("已暂停")
        case .completed: return AppLocalized("解读完成")
        case .error: return AppLocalized("重试解读")
        }
    }

    @ViewBuilder
    private var centerControl: some View {
        switch vm.status {
        case .idle:
            if isContinuingPage {
                playButton(isLoading: true, isPlaying: false, action: {})
                    .disabled(true)
            } else {
                playButton(isLoading: false, isPlaying: false, action: start)
            }
        case .planning:
            playButton(isLoading: true, isPlaying: false, action: {})
                .disabled(true)
        case .streaming:
            let loading = (isContinuingPage || vm.isPreparingNext) && !vm.isPlaying
            playButton(isLoading: loading, isPlaying: vm.isPlaying, action: { vm.togglePlayPause() })
                .disabled(loading)
        case .completed:
            if isContinuingPage {
                playButton(isLoading: true, isPlaying: false, action: {})
                    .disabled(true)
            } else {
                Button { vm.replay() } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: compact ? 40 : 48))
                        .foregroundColor(AppTheme.primary)
                        .frame(width: compact ? 44 : 52, height: compact ? 44 : 52)
                }
                .buttonStyle(.plain)
            }
        case .error:
            if isContinuingPage {
                playButton(isLoading: true, isPlaying: false, action: {})
                    .disabled(true)
            } else {
                Button(action: start) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: compact ? 40 : 48))
                        .foregroundColor(AppTheme.primary)
                        .frame(width: compact ? 44 : 52, height: compact ? 44 : 52)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func playButton(isLoading: Bool, isPlaying: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            KindlePlayButtonContent(
                isLoading: isLoading,
                isPlaying: isPlaying,
                size: compact ? 44 : 52
            )
        }
        .buttonStyle(.plain)
    }
}

private struct KindleExplainCaption: View {
    @ObservedObject var vm: ExplainViewModel
    let isContinuingPage: Bool
    let alignment: Alignment
    let maxWidth: CGFloat

    @ViewBuilder
    var body: some View {
        if shouldShowCaption {
            Text(vm.explanationText)
                .font(.callout.weight(.medium))
                .foregroundColor(AppTheme.foreground)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(AppTheme.surface.opacity(0.18)))
                }
                .overlay(Capsule().stroke(AppTheme.mutedForeground.opacity(0.18), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                .frame(maxWidth: maxWidth, alignment: alignment)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var shouldShowCaption: Bool {
        guard !isContinuingPage, !vm.isPreparingNext, !vm.explanationText.isEmpty else { return false }
        if case .streaming = vm.status { return true }
        return false
    }
}

private struct KindleLandscapeEmptyOverlay: View {
    let isPreparing: Bool
    let start: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            KindlePlaybackConsole(
                isLandscape: true,
                playbackStatus: isPreparing ? AppLocalized("正在准备…") : AppLocalized("已暂停"),
                voiceLanguage: nil,
                previousPage: previousPage,
                nextPage: nextPage,
                showTOC: showTOC
            ) {
                Button(action: start) {
                    KindlePlayButtonContent(
                        isLoading: isPreparing,
                        isPlaying: false,
                        size: 44
                    )
                }
                .disabled(isPreparing)
            }
        }
    }
}

private struct KindleLandscapeReadOverlay: View {
    @ObservedObject var vm: ReadAloudViewModel
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared
    let isPreparing: Bool
    let start: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void

    private var isLoading: Bool {
        voiceSwitch.progress != nil ||
            isPreparing ||
            (vm.status.isLoadingOrStreaming && !vm.isPlaying && !vm.canResumePlayback)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            KindlePlaybackConsole(
                isLandscape: true,
                playbackStatus: isLoading ? AppLocalized("正在准备…") : (vm.isPlaying ? AppLocalized("朗读中") : AppLocalized("已暂停")),
                statusMessage: voiceSwitch.progress?.localizedMessage,
                voiceLanguage: vm.hasStartedPlayback ? vm.playbackLanguage : nil,
                previousPage: previousPage,
                nextPage: nextPage,
                showTOC: showTOC
            ) {
                Button(action: start) {
                    KindlePlayButtonContent(
                        isLoading: isLoading,
                        isPlaying: vm.isPlaying,
                        size: 44
                    )
                }
                .disabled(isLoading)
            }
        }
    }
}

private struct KindleLandscapeExplainOverlay: View {
    @ObservedObject var vm: ExplainViewModel
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared
    let isContinuingPage: Bool
    let start: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            caption
            controlPill
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private var caption: some View {
        KindleExplainCaption(
            vm: vm,
            isContinuingPage: isContinuingPage,
            alignment: .trailing,
            maxWidth: 620
        )
    }

    @ViewBuilder
    private var controlPill: some View {
        KindlePlaybackConsole(
            isLandscape: true,
            playbackStatus: playbackStatus,
            statusMessage: voiceSwitch.progress?.localizedMessage,
            voiceLanguage: vm.playbackLanguage,
            previousPage: previousPage,
            nextPage: nextPage,
            showTOC: showTOC
        ) {
            centerPlayControl
        }
    }

    private var playbackStatus: String {
        if voiceSwitch.progress != nil || isContinuingPage || vm.isPreparingNext {
            return AppLocalized("正在准备…")
        }
        switch vm.status {
        case .idle: return AppLocalized("开始解读")
        case .planning: return AppLocalized("正在准备…")
        case .streaming: return vm.isPlaying ? AppLocalized("解读中") : AppLocalized("已暂停")
        case .completed: return AppLocalized("解读完成")
        case .error: return AppLocalized("重试解读")
        }
    }

    @ViewBuilder
    private var centerPlayControl: some View {
        switch vm.status {
        case .idle:
            if isContinuingPage {
                ProgressView().frame(width: 38, height: 38)
            } else {
                Button(action: start) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(AppTheme.primary)
                }
            }
        case .planning:
            ProgressView().frame(width: 38, height: 38)
        case .streaming:
            if isContinuingPage || vm.isPreparingNext {
                ProgressView().frame(width: 38, height: 38)
            } else {
                Button { vm.togglePlayPause() } label: {
                    Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(AppTheme.primary)
                }
            }
        case .completed:
            if isContinuingPage {
                ProgressView().frame(width: 38, height: 38)
            } else {
                Button { vm.replay() } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 38))
                        .foregroundColor(AppTheme.primary)
                }
            }
        case .error:
            if isContinuingPage {
                ProgressView().frame(width: 38, height: 38)
            } else {
                Button(action: start) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 38))
                        .foregroundColor(AppTheme.primary)
                }
            }
        }
    }
}

private extension View {
    func kindleLandscapePill() -> some View {
        self
            .padding(.horizontal, 14)
            .frame(height: 56)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(AppTheme.mutedForeground.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.10), radius: 10, y: 2)
    }
}

enum KindleRunLog {
    static func write(_ message: String) {
        #if DEBUG
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let line = "\(formatter.string(from: Date())) [\(UIApplication.shared.applicationState.debugName)] \(message)\n"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = docs.appendingPathComponent("kindle-background-probe.log")
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

/// Pure access contract used before Kindle performs screenshot capture/OCR.
/// The ReadAloud/Explain view models remain the final authority at playback
/// time, while this gate prevents an already exhausted user from waiting for
/// unnecessary page preparation before the paywall appears.
enum KindlePlaybackAccessGate {
    static func canStart(
        mode: ReaderMode,
        isPro: Bool,
        listenRemaining: Double,
        explainRemaining: Int
    ) -> Bool {
        if isPro { return true }
        switch mode {
        case .read:
            return listenRemaining > 0
        case .explain:
            return explainRemaining > 0
        }
    }
}

private extension UIApplication.State {
    var debugName: String {
        switch self {
        case .active: return "active"
        case .inactive: return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}

struct KindleMiniPlayerView: View {
    @ObservedObject var center: KindlePlaybackCenter
    @ObservedObject private var audio = AudioPlayerService.shared
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared

    private var model: KindleBookViewModel? { center.model }

    private var statusText: String {
        if let progress = voiceSwitch.progress { return progress.localizedMessage }
        guard model != nil else { return AppLocalized("已暂停") }
        if audio.isPlaying { return AppLocalized("朗读中") }
        return AppLocalized("已暂停")
    }

    var body: some View {
        if let model {
            HStack(spacing: 12) {
                KindleCoverView(urlString: model.book.coverURL)
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(AppTheme.mutedForeground.opacity(0.12), lineWidth: 0.5))
                    .onTapGesture { center.expand() }

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.book.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .foregroundColor(AppTheme.foreground)
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(AppTheme.mutedForeground)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { center.expand() }

                if model.mode == .explain, let vm = model.explainVM {
                    PlaybackVoiceButton(language: vm.playbackLanguage, size: 34)
                } else if let vm = model.readVM, vm.hasStartedPlayback {
                    PlaybackVoiceButton(language: vm.playbackLanguage, size: 34)
                }

                Button {
                    Task { try? await model.startCurrentMode() }
                } label: {
                    Group {
                        if voiceSwitch.progress != nil {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: audio.isPlaying ? "pause.fill" : "play.fill")
                                .font(.system(size: 19))
                                .foregroundColor(AppTheme.foreground)
                        }
                    }
                    .frame(width: 34, height: 34)
                }
                .disabled(voiceSwitch.progress != nil)

                Button { center.close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.mutedForeground)
                        .frame(width: 30, height: 30)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(AppTheme.mutedForeground.opacity(0.18), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
            .padding(.horizontal, 8)
        }
    }
}

@MainActor
final class KindlePlaybackCenter: ObservableObject {
    static let shared = KindlePlaybackCenter()
    private static let orientationOwner = "kindle-player"

    @Published private(set) var model: KindleBookViewModel?
    @Published var isPresented = false

    var showsMiniPlayer: Bool {
        model != nil && !isPresented
    }

    private init() {}

    func open(book: KindleBook, continueListening: Bool = false) {
        AppOrientationLock.unlock(owner: Self.orientationOwner)
        if let active = model, active.isSameBook(as: book) {
            active.refreshMetadata(from: book)
            if continueListening {
                active.requestContinueListening()
            }
            isPresented = true
            return
        }

        let old = model
        let next = KindleBookViewModel(book: book)
        model = next
        if continueListening {
            KindleRunLog.write("KINDLE audiobook cold continue ignored book=\(String(book.id.prefix(24))) reason=no-live-session")
        }
        isPresented = true
        old?.stopAll()
    }

    func replaceAfterLibraryRecovery(current: KindleBookViewModel, book: KindleBook) {
        guard model === current else {
            KindleRunLog.write("KINDLE stale-entry fresh-reader skipped reason=ownership-changed book=\(String(book.id.prefix(24)))")
            return
        }
        let next = KindleBookViewModel(book: book, staleRecoveryAlreadyAttempted: true)
        model = next
        AppOrientationLock.unlock(owner: Self.orientationOwner)
        isPresented = true
        KindleRunLog.write("KINDLE stale-entry fresh-reader created book=\(String(book.id.prefix(24)))")
    }

    func activate(model: KindleBookViewModel) {
        self.model = model
    }

    func isOwning(_ candidate: KindleBookViewModel) -> Bool {
        model === candidate
    }

    func expand() {
        guard model != nil else { return }
        AppOrientationLock.unlock(owner: Self.orientationOwner)
        isPresented = true
    }

    func minimize() {
        guard model != nil else { return }
        AppOrientationLock.lockCurrent(owner: Self.orientationOwner)
        isPresented = false
    }

    func close() {
        let active = model
        model = nil
        isPresented = false
        AppOrientationLock.unlock(owner: Self.orientationOwner)
        active?.stopAll()
    }

    func clear(ifModel candidate: KindleBookViewModel) {
        guard model === candidate else { return }
        model = nil
        isPresented = false
        AppOrientationLock.unlock(owner: Self.orientationOwner)
    }
}

struct KindleTOCEntry: Identifiable, Equatable {
    let id: String
    let index: Int
    let text: String
    let level: Int
    let active: Bool
    let path: String
    let sourcePath: String
    let href: String
    let role: String
    let aria: String
    let actionSummary: String

    init(
        index: Int,
        text: String,
        level: Int,
        active: Bool,
        path: String = "",
        sourcePath: String = "",
        href: String = "",
        role: String = "",
        aria: String = "",
        actionSummary: String = ""
    ) {
        self.index = index
        self.text = text
        self.level = max(0, level)
        self.active = active
        self.path = path
        self.sourcePath = sourcePath
        self.href = href
        self.role = role
        self.aria = aria
        self.actionSummary = actionSummary
        self.id = "\(index)-\(text)"
    }
}

private struct KindleNativeTOCPanel: View {
    let entries: [KindleTOCEntry]
    let isLoading: Bool
    let errorText: String?
    let isLandscape: Bool
    let close: () -> Void
    let select: (KindleTOCEntry) -> Void

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
                        ProgressView()
                            .tint(AppTheme.primary)
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
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(entries) { entry in
                                Button {
                                    select(entry)
                                } label: {
                                    HStack(spacing: 10) {
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(entry.active ? AppTheme.primary : Color.clear)
                                            .frame(width: 3, height: 24)

                                        Text(entry.text)
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
                                .disabled(isLoading)

                                Divider()
                                    .padding(.leading, 52 + CGFloat(min(entry.level, 3)) * 16)
                            }

                            if isLoading {
                                HStack(spacing: 10) {
                                    ProgressView()
                                        .scaleEffect(0.82)
                                        .tint(AppTheme.primary)
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

@MainActor
final class KindleBookViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler {
    @Published var book: KindleBook
    @Published var isPreparing = false
    @Published var statusText = ""
    @Published var playbackErrorText: String?
    @Published var mode: ReaderMode = .read
    @Published var readVM: ReadAloudViewModel?
    @Published var explainVM: ExplainViewModel?
    @Published var showPaywall = false
    @Published var isContinuingExplainPage = false
    @Published var isPageTurnResuming = false
    @Published var viewportCrop: KindleViewportCrop = .identity
    @Published var isKindleTOCVisible = false
    @Published var isNativeTOCPresented = false
    @Published var isNativeTOCLoading = false
    @Published var nativeTOCError: String?
    @Published var nativeTOCEntries: [KindleTOCEntry] = []
    @Published private(set) var isKindleSyncDialogVisible = false
    @Published private(set) var kindleSyncLocalLocation: Int?
    @Published private(set) var kindleSyncCloudLocation: Int?
    @Published private(set) var isStaleBookEntryError = false
    @Published private(set) var isStaleBookRecovering = false
    @Published private(set) var staleBookRecoveryMessage: String?
    @Published private(set) var staleBookRecoveryProgressText = AppLocalized("正在准备…")
    @Published private(set) var libraryRecoveryWebView: WKWebView?
    private var lastNativeTOCSelectionText: String?
    private var lastNativeTOCSelectionPageKey: String?
    private var nativeTOCTask: Task<Void, Never>?
    private var nativeTOCEpoch: UInt64 = 0
    private var isNativeTOCBridgeJumping = false
    private var readerSurfaceFreezeUntil: Date?

    let webView: WKWebView

    var isPlaybackPreparing: Bool {
        isPreparing || isPageTurnResuming
    }

    var isExplainTransitionLoading: Bool {
        isContinuingExplainPage || isPageTurnResuming
    }

    var isNativeTOCJumpBlocking: Bool {
        isNativeTOCLoading && !isNativeTOCPresented
    }

    private var liveDocument: ReadingDocument?
    private var livePage: CapturedKindlePage?
    private var livePageKey: String?
    private var liveStartParagraphIndex: Int?
    private var liveStartIndexKind: KindleStartIndexKind = .sourceParagraph
    private var liveVisibleTopNorm: CGFloat?
    private var liveVisibleBottomNorm: CGFloat?
    private var pendingCaptureKey: String?
    private var suppressNextScrollParagraphIndex: Int?
    private var lastHighlightedWordByParagraph: [String: Int] = [:]
    private var shownMarkIds = Set<String>()
    private var animatedMarkIds = Set<String>()
    private var didLoad = false
    private var staleBookRecoveryAttempted = false
    private var staleBookRecoveryTask: Task<Void, Never>?
    private var staleBookErrorProbeTask: Task<Void, Never>?
    private var readerSetupTask: Task<Void, Never>?
    private var pageKeysByDocumentID: [String: [Int: String]] = [:]
    private var lastSyncedPageIndex: Int?
    private var isAdvancingLivePage = false
    private var readPageSessionGeneration: UInt64 = 0
    private var activeReadPageSession: KindleReadPageSession?
    private var consumedReadPageGeneration: UInt64?
    private var cancellables = Set<AnyCancellable>()
    private var playbackCancellables = Set<AnyCancellable>()
    private let store = KindleLibraryStore.shared
    private let analyticsContext: AnalyticsContentContext
    private var analyticsContentReadyTracked = false
    /// Preserve native Kindle glyph pixels for OCR. The JavaScript capture uses
    /// lossless PNG; this cap only protects against abnormally large renderer images.
    private static let ocrCaptureMaxWidth = 2048
    private static var ocrCaptureJavaScriptArguments: String {
        "\(ocrCaptureMaxWidth)"
    }

    // Render layer: consumes word routes and paints highlight/marks onto the live Kindle page.
    private var visualSyncTask: Task<Void, Never>?
    private var visualScrollTask: Task<Void, Never>?
    private var visualRecoveryTask: Task<Void, Never>?
    private var readerLayoutRepairTask: Task<Void, Never>?
    private var readerLayoutRepairRetry = 0
    private var pendingLayoutPlaybackMode: ReaderMode?
    private var pendingLayoutPlaybackOldKey: String?
    private var visualSyncSequence: UInt64 = 0
    private var lastVisualRecoveryAt: Date?
    private var scrolledHighlightLineKeys = Set<String>()
    private var paragraphResetKeys = Set<String>()
    private var paragraphPrepTasks: [String: Task<Void, Never>] = [:]
    private var preparedParagraphKeys = Set<String>()
    private var nextPagePreloadRetryAt: [String: Date] = [:]
    private var nextPagePreloadFailureCount: [String: Int] = [:]
    private var nextPagePreloadCooldownUntil: [String: Date] = [:]

    // Page cache layer: captures ordered Kindle page images + OCR documents. It does not own playback text.
    private var pageCacheTask: Task<Void, Never>?
    private var pageKeyWatchTask: Task<Void, Never>?
    private var navigationRestartTask: Task<Void, Never>?
    private var manualPageResumeTask: Task<Void, Never>?
    private var layoutPlaybackRestartTask: Task<Void, Never>?
    private var modeSwitchTask: Task<Void, Never>?
    private var handledKindleNavigationSeq = 0
    private var preloadEpoch: UInt64 = 0
    private var pendingManualPageResumeMode: ReaderMode?
    private var pendingManualTurnDirection: KindlePageTurnDirection?
    private var pendingManualTurnShouldResume = false
    private var activeManualTurnShouldResume = false
    private var cachingNextPageAfterKey: String?
    private var cachedNextPage: KindleCachedPage?
    private var cachedPageCandidates: [String: KindleCachedPage] = [:]
    private var pageBackStack: [KindleCachedPage] = []
    private var pageForwardStack: [KindleCachedPage] = []

    // Playback prefetch layer: owns audio generated for a known utterance. Kept separate from page cache.
    private var cachedStartAudio: KindleAudioPrefetch?
    private var cachedStartAudioCandidates: [String: KindleAudioPrefetch] = [:]
    private var continuousReadHandoff: KindleContinuousReadHandoff?
    private var continuousReadTurnTask: Task<Void, Never>?
    private var continuousReadCommitTask: Task<Void, Never>?
    private var continuousReadStagedPage: KindleCachedPage?
    private var continuousReadStagedLiveKey: String?
    private var continuousReadHandoffSerial = 0
    private var continuousReadOldVMDetached = false
    private var continuousReadAudioCompletedBeforeCommit = false
    private var continuousReadTurnFailureCount = 0
    /// Semantic page actions are non-idempotent. Once attempted, visual/cache
    /// staging may retry, but the React paired action may not be sent again.
    private var continuousReadSemanticTurnAttempted = false
    private var continuousReadConfirmedTargetKey: String?

    // Explain prefetch layer: owns the next page block_0 plan + TTS + marks.
    private var explainPrefetchTask: Task<Void, Never>?
    private var explainPrefetchingAfterKey: String?
    private var deferredExplainPreloadTask: Task<Void, Never>?
    private var deferredExplainPreloadAfterKey: String?
    private var cachedExplainPrefetch: KindleExplainPrefetch?
    private var cachedExplainPrefetchCandidates: [String: KindleExplainPrefetch] = [:]

    // Text queue layer: converts cached pages into logical utterances + render routes.
    private var textQueue: KindleTextQueue?
    private var activeReadPageSlot: KindleReadPageSlot = .current
    private var bridgedNextResumeByPageKey: [String: Int] = [:]
    private var refocusWordRoutes: [String: KindleRenderRoute] = [:]
    private var playbackAnchor: KindlePlaybackAnchor?
    private let continueListeningGate = KindleAutoplayRequestGate()
    private var continueListeningRequestedAt: [Int: Date] = [:]
    private var continueListeningTask: Task<Void, Never>?
    private var continueListeningBaselineTask: Task<Void, Never>?
    private var syncDialogResolutionTask: Task<Void, Never>?
    private var syncDialogEpoch: UInt64 = 0
    private var syncDialogShouldResume = false
    private var syncDialogResumeMode: ReaderMode?
    private var pendingStartAfterSyncResolution = false
    private var pendingPersistentAnchor: KindleListeningAnchor?
    private var listeningAnchorPersistTask: Task<Void, Never>?
    private var lastListeningAnchorPersistedAt: Date?
    private var pageTextHashByKey: [String: String] = [:]
    private var expectedNextBlobByAfterKey: [String: String] = [:]
    private var blobOrderByKey: [String: Int] = [:]
    private var lastActivatedBlobKey: String?
    private var isRefocusingPlayback = false
    private var suppressExternalPageChangeUntil: Date?
    private var readerLayoutUnstableUntil: Date?
    private var externalMismatchKey: String?
    private var readerSurfaceSize: CGSize = .zero
    private var isReaderSurfaceAttached = false
    private var isReaderPresented = false
    private var isPlayerControlOverlayPresented = false
    private var isApplicationActive = true
    private var needsForegroundVisualResync = false
    private var lastConfirmedTurnFingerprint: String?
    private var kindleVerticalColumnHints: [KindleVerticalColumnHint] = []

    // Playback layer: tracks continuation after a cross-page utterance has consumed the next page's first paragraph.
    private var pendingCurrentPageContinuation = false
    private var pendingContinuationParagraphIndex: Int?
    private var pendingContinuationSegments: [AudioSegment] = []
    private var pendingContinuationTask: Task<Void, Never>?

    var shouldRunPlaybackRefocus: Bool {
        guard AudioPlayerService.shared.currentBookId == book.id else { return false }
        switch mode {
        case .read:
            return readVM?.isPlaying == true ||
                (readVM != nil && AudioPlayerService.shared.isPlaying) ||
                hasActivePlaybackSession
        case .explain:
            return explainVM?.isPlaying == true ||
                (explainVM != nil && AudioPlayerService.shared.isPlaying) ||
                hasActivePlaybackSession
        }
    }

    var shouldCancelPlaybackRefocusOnAudioPause: Bool {
        !hasActivePlaybackSession
    }

    func setReaderSurfaceAttached(_ attached: Bool) {
        guard isReaderSurfaceAttached != attached else { return }
        isReaderSurfaceAttached = attached
        KindleRunLog.write("KINDLE lifecycle surfaceAttached=\(attached ? "Y" : "N")")
    }

    func setReaderPresented(_ presented: Bool) {
        guard isReaderPresented != presented else { return }
        isReaderPresented = presented
        KindleRunLog.write("KINDLE lifecycle presented=\(presented ? "Y" : "N")")
        if presented, needsForegroundVisualResync {
            KindleRunLog.write("KINDLE lifecycle visual-resync pending reason=reader-presented")
        }
    }

    func setPlayerControlOverlayPresented(_ presented: Bool) {
        guard isPlayerControlOverlayPresented != presented else { return }
        isPlayerControlOverlayPresented = presented
        clearExternalMismatchState()
        if presented {
            suppressExternalPageChangeUntil = .distantFuture
            KindleRunLog.write("KINDLE player overlay begin stableSurface=\(Self.sizeLog(readerSurfaceSize))")
        } else {
            // Let the custom panel finish its dismissal animation without
            // interpreting transient geometry or candidate order as a page turn.
            suppressExternalPageChangeUntil = Date().addingTimeInterval(1.5)
            KindleRunLog.write("KINDLE player overlay end grace=1.5 stableSurface=\(Self.sizeLog(readerSurfaceSize))")
        }
    }

    func setApplicationActive(_ active: Bool) {
        guard isApplicationActive != active else { return }
        isApplicationActive = active
        KindleRunLog.write("KINDLE lifecycle appActive=\(active ? "Y" : "N")")
        if active, needsForegroundVisualResync {
            KindleRunLog.write("KINDLE lifecycle visual-resync pending reason=app-active")
        }
    }

    private var requiresImmediateVisualSync: Bool {
        KindlePlaybackLifecycleContract.requiresImmediateVisualSync(
            readerPresented: isReaderPresented,
            applicationActive: isApplicationActive
        )
    }

    private func deferVisualSyncUntilForeground(reason: String) {
        needsForegroundVisualResync = true
        KindleRunLog.write("KINDLE lifecycle visual-sync deferred reason=\(reason)")
    }

    func notePlaybackLayoutChange(reason: String) {
        guard !isPlayerControlOverlayPresented else {
            KindleRunLog.write("KINDLE layout ignored reason=\(reason) source=player-overlay")
            return
        }
        guard hasActivePlaybackSession || shouldRunPlaybackRefocus else { return }
        let seconds: TimeInterval
        switch reason {
        case "orientation", "reader-size", "surfaceSize":
            seconds = 10.0
        case "foreground":
            seconds = 6.0
        default:
            seconds = 1.5
        }
        suppressExternalPageChangeUntil = Date().addingTimeInterval(seconds)
        clearExternalMismatchState()
        KindleRunLog.write("KINDLE external watcher grace reason=\(reason) seconds=\(seconds)")
    }

    func updateReaderSurfaceSize(_ size: CGSize) {
        let normalized = CGSize(
            width: max(1, size.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, size.height.rounded(.toNearestOrAwayFromZero))
        )
        guard !isPlayerControlOverlayPresented else {
            KindleRunLog.write("KINDLE viewport crop keep-current reason=player-overlay surface=\(Self.sizeLog(normalized))")
            return
        }
        if isReaderSurfaceFrozen {
            if Self.isOrientationChange(from: readerSurfaceSize, to: normalized) {
                readerSurfaceFreezeUntil = nil
                KindleRunLog.write("KINDLE viewport freeze cleared reason=orientation-change from=\(Self.sizeLog(readerSurfaceSize)) to=\(Self.sizeLog(normalized))")
            } else {
                KindleRunLog.write("KINDLE viewport crop keep-current reason=surface-freeze surface=\(Self.sizeLog(normalized))")
                return
            }
        }
        if isNativeTOCPresented || isKindleTOCVisible {
            KindleRunLog.write("KINDLE viewport crop keep-current reason=surface-native-toc surface=\(Self.sizeLog(normalized))")
            return
        }
        guard abs(normalized.width - readerSurfaceSize.width) > 1 ||
              abs(normalized.height - readerSurfaceSize.height) > 1 else {
            if !didLoad {
                loadIfNeeded()
            }
            return
        }

        readerSurfaceSize = normalized
        let crop = Self.predictedViewportCrop(for: normalized)
        applyViewportCropIfNeeded(
            crop,
            reason: "surface-predict",
            source: "surface=\(Self.sizeLog(normalized))"
        )
        if !didLoad {
            loadIfNeeded()
        }
    }

    func effectiveViewportCrop(forSurfaceSize size: CGSize) -> KindleViewportCrop {
        let normalized = CGSize(
            width: max(1, size.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, size.height.rounded(.toNearestOrAwayFromZero))
        )
        if isPlayerControlOverlayPresented {
            return viewportCrop
        }
        guard normalized.width > 80, normalized.height > 80 else {
            return viewportCrop
        }
        if isReaderSurfaceFrozen {
            if Self.isOrientationChange(from: readerSurfaceSize, to: normalized) {
                readerSurfaceFreezeUntil = nil
                return Self.predictedViewportCrop(for: normalized)
            }
            return viewportCrop
        }
        if isNativeTOCPresented || isKindleTOCVisible {
            return viewportCrop
        }
        let sizeMatchesModel = abs(normalized.width - readerSurfaceSize.width) <= 1 &&
            abs(normalized.height - readerSurfaceSize.height) <= 1
        if sizeMatchesModel {
            return viewportCrop
        }
        return Self.predictedViewportCrop(for: normalized)
    }

    private var isReaderSurfaceFrozen: Bool {
        guard let until = readerSurfaceFreezeUntil else { return false }
        if Date() < until { return true }
        readerSurfaceFreezeUntil = nil
        return false
    }

    private func freezeReaderSurface(reason: String, seconds: TimeInterval) {
        readerSurfaceFreezeUntil = Date().addingTimeInterval(seconds)
        KindleRunLog.write("KINDLE viewport freeze reason=\(reason) seconds=\(seconds)")
    }

    func noteReaderLayoutChange(reason: String) {
        guard !isPlayerControlOverlayPresented else {
            KindleRunLog.write("KINDLE reader layout ignored reason=\(reason) source=player-overlay")
            return
        }
        guard didLoad else { return }
        preparePlaybackForReaderLayoutRestartIfNeeded(reason: reason)
        markReaderLayoutUnstable(reason: reason)
        readerLayoutRepairTask?.cancel()
        layoutPlaybackRestartTask?.cancel()
        layoutPlaybackRestartTask = nil
        readerLayoutRepairRetry = 0
        let delay: UInt64
        switch reason {
        case "orientation":
            delay = 520_000_000
        case "reader-size":
            delay = 360_000_000
        case "foreground":
            delay = 260_000_000
        default:
            delay = 180_000_000
        }
        guard shouldRunFullReaderLayoutRepair else {
            let idleDelay = min(delay, reason == "orientation" ? 180_000_000 : 220_000_000)
            readerLayoutRepairTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: idleDelay)
                guard !Task.isCancelled else { return }
                await self?.recoverReaderLayoutForIdle(reason: reason, maxAttempts: reason == "orientation" ? 5 : 3)
            }
            return
        }
        readerLayoutRepairTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.repairReaderLayout(reason: reason, attempt: 1)
        }
    }

    private var shouldRunFullReaderLayoutRepair: Bool {
        hasActivePlaybackSession || shouldRunPlaybackRefocus || AudioPlayerService.shared.currentBookId == book.id
    }

    private func preparePlaybackForReaderLayoutRestartIfNeeded(reason: String) {
        guard Self.layoutReasonShouldRestartPlayback(reason),
              pendingLayoutPlaybackMode == nil,
              hasActivePlaybackSession,
              AudioPlayerService.shared.currentBookId == book.id else { return }
        let oldMode = mode
        pendingLayoutPlaybackMode = oldMode
        pendingLayoutPlaybackOldKey = livePageKey?.nilIfEmpty
        stopPlaybackForPageTurn(reason: "layout-\(reason)-pending", clearLiveOverlay: false)
        mode = oldMode
        statusText = AppLocalized("正在适配屏幕方向…")
        KindleRunLog.write("KINDLE layout playback pending reason=\(reason) mode=\(oldMode.rawValue) old=\(Self.keyLog(pendingLayoutPlaybackOldKey ?? ""))")
    }

    private var isReaderLayoutCurrentlyUnstable: Bool {
        guard let until = readerLayoutUnstableUntil else { return false }
        if Date() < until { return true }
        readerLayoutUnstableUntil = nil
        return false
    }

    private func markReaderLayoutUnstable(reason: String) {
        let seconds: TimeInterval
        switch reason {
        case "orientation":
            seconds = 8.0
        case "reader-size", "surfaceSize":
            seconds = 6.0
        case "foreground":
            seconds = 4.0
        default:
            seconds = 2.0
        }
        readerLayoutUnstableUntil = Date().addingTimeInterval(seconds)
        visualRecoveryTask?.cancel()
        visualRecoveryTask = nil
        clearExternalMismatchState()
        KindleRunLog.write("KINDLE reader layout unstable reason=\(reason) seconds=\(seconds)")
    }

    private func clearReaderLayoutUnstableIfRecovered(
        reason: String,
        key: String?,
        liveKey: String?,
        orderedCount: Int,
        visibleArea: Double
    ) {
        guard readerLayoutUnstableUntil != nil else { return }
        let normalizedKey = key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedLiveKey = liveKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasUsablePage = orderedCount > 0 && visibleArea > 0
        let sameLivePage = normalizedLiveKey.isEmpty || normalizedKey.isEmpty || normalizedKey == normalizedLiveKey
        guard hasUsablePage, sameLivePage else { return }
        readerLayoutUnstableUntil = nil
        KindleRunLog.write("KINDLE reader layout recovered reason=\(reason) key=\(Self.keyLog(normalizedKey)) live=\(Self.keyLog(normalizedLiveKey)) ordered=\(orderedCount) visible=\(visibleArea)")
    }

    private func repairReaderLayout(reason: String, attempt: Int = 1) async {
        guard didLoad else { return }
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        webView.scrollView.setNeedsLayout()
        webView.scrollView.layoutIfNeeded()
        configurePageModeGestures()
        installCaptureScript()
        await setKindlePageModeLocked(true)

        let script = """
        (function() {
          try { window.dispatchEvent(new Event('resize')); } catch (_) {}
          try { document.dispatchEvent(new Event('visibilitychange')); } catch (_) {}
          try {
            if (window.__crKindleProbe) {
              window.__crKindleProbe.layoutRepairAt = Date.now ? Date.now() : new Date().getTime();
            }
          } catch (_) {}
          try {
            if (window.crKindleUpdateLiveOverlay) window.crKindleUpdateLiveOverlay();
          } catch (_) {}
          try {
            var state = window.__crKindleState ? window.__crKindleState() : '{}';
            var parsed = typeof state === 'string' ? JSON.parse(state) : state;
            return JSON.stringify({
              ok: true,
              key: parsed && parsed.key || '',
              liveKey: parsed && parsed.liveKey || '',
              orderedCount: parsed && parsed.orderedCount || 0,
              viewportWidth: parsed && parsed.viewportWidth || 0,
              viewportHeight: parsed && parsed.viewportHeight || 0,
              visibleArea: parsed && parsed.visibleArea || 0,
              bandVisibleArea: parsed && parsed.bandVisibleArea || 0
            });
          } catch (e) {
            return JSON.stringify({ ok:false, reason:String(e && e.message || e) });
          }
        })()
        """

        do {
            let result = try await evaluateJSON(script)
            let key = result["key"] as? String ?? ""
            let liveKey = result["liveKey"] as? String ?? ""
            let orderedCount = Self.int(from: result["orderedCount"]) ?? 0
            let visibleArea = Self.numberValue(result["visibleArea"]) ?? 0
            KindleRunLog.write(
                "KINDLE reader layout repair reason=\(reason) ok=\(String(describing: result["ok"] ?? false)) key=\(Self.keyLog(key)) live=\(Self.keyLog(liveKey)) ordered=\(String(describing: result["orderedCount"] ?? 0)) viewport=\(String(describing: result["viewportWidth"] ?? 0))x\(String(describing: result["viewportHeight"] ?? 0)) visible=\(String(describing: result["visibleArea"] ?? 0)) band=\(String(describing: result["bandVisibleArea"] ?? 0))"
            )
            await logKindleGeometrySnapshot(reason: "layout-repair-\(reason)")
            clearReaderLayoutUnstableIfRecovered(
                reason: reason,
                key: key,
                liveKey: liveKey,
                orderedCount: orderedCount,
                visibleArea: visibleArea
            )
            if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || orderedCount <= 0 || visibleArea <= 0 {
                scheduleReaderLayoutRepairRetry(reason: reason, attempt: attempt)
            } else {
                schedulePlaybackRestartAfterReaderLayoutIfNeeded(
                    reason: reason,
                    visibleKey: key,
                    orderedCount: orderedCount,
                    visibleArea: visibleArea
                )
                await alignCurrentPageForIdleLayoutIfNeeded(
                    reason: reason,
                    visibleKey: key,
                    orderedCount: orderedCount,
                    visibleArea: visibleArea
                )
            }
        } catch {
            KindleRunLog.write("KINDLE reader layout repair error reason=\(reason) \(error.localizedDescription)")
            scheduleReaderLayoutRepairRetry(reason: reason, attempt: attempt)
        }
    }

    private func scheduleReaderLayoutRepairRetry(reason: String, attempt: Int) {
        guard attempt < 8 else {
            KindleRunLog.write("KINDLE reader layout repair give-up reason=\(reason) attempt=\(attempt) key=\(Self.keyLog(livePageKey ?? ""))")
            return
        }
        readerLayoutRepairTask?.cancel()
        readerLayoutRepairTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 420_000_000)
            guard !Task.isCancelled else { return }
            await self?.repairReaderLayout(reason: reason, attempt: attempt + 1)
        }
        KindleRunLog.write("KINDLE reader layout repair retry reason=\(reason) nextAttempt=\(attempt + 1)")
    }

    private func schedulePlaybackRestartAfterReaderLayoutIfNeeded(
        reason: String,
        visibleKey: String?,
        orderedCount: Int,
        visibleArea: Double
    ) {
        guard shouldRestartPlaybackAfterReaderLayout(reason: reason) else { return }
        guard let key = visibleKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              orderedCount > 0,
              visibleArea > 0 else {
            KindleRunLog.write("KINDLE layout playback restart blocked-unstable reason=\(reason) key=\(Self.keyLog(visibleKey ?? "")) ordered=\(orderedCount) visible=\(visibleArea)")
            return
        }
        layoutPlaybackRestartTask?.cancel()
        layoutPlaybackRestartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 720_000_000)
            guard let self, !Task.isCancelled else { return }
            await self.restartPlaybackFromCurrentVisiblePageAfterLayout(reason: reason, preferredKey: key)
        }
        KindleRunLog.write("KINDLE layout playback restart scheduled reason=\(reason) key=\(Self.keyLog(key))")
    }

    private func alignCurrentPageForIdleLayoutIfNeeded(
        reason: String,
        visibleKey: String?,
        orderedCount: Int,
        visibleArea: Double
    ) async {
        guard !shouldRestartPlaybackAfterReaderLayout(reason: reason),
              !hasActivePlaybackSession,
              !isPreparing,
              !isAdvancingLivePage,
              let key = visibleKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
              orderedCount > 0,
              visibleArea > 0 else { return }
        do {
            try await waitForKindleImageStable()
            if await restorePlaybackKeyVisibility(key, reason: "layout-idle-\(reason)", maxSteps: 2) {
                KindleRunLog.write("KINDLE layout idle aligned reason=\(reason) key=\(Self.keyLog(key))")
            } else {
                KindleRunLog.write("KINDLE layout idle align-miss reason=\(reason) key=\(Self.keyLog(key))")
            }
        } catch {
            KindleRunLog.write("KINDLE layout idle align-error reason=\(reason) key=\(Self.keyLog(key)) \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func recoverReaderLayoutForIdle(reason: String, maxAttempts: Int) async -> Bool {
        guard didLoad else { return false }
        guard !isNativeTOCPresented, !isKindleTOCVisible else {
            KindleRunLog.write("KINDLE reader layout idle-recover skipped reason=\(reason) nativeTOC=1")
            return false
        }

        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        webView.scrollView.setNeedsLayout()
        webView.scrollView.layoutIfNeeded()
        configurePageModeGestures()
        installCaptureScript()
        await setKindlePageModeLocked(true)

        for attempt in 1...max(1, maxAttempts) {
            guard !Task.isCancelled else { return false }
            if let result = try? await readKindleReaderLayoutState(),
               handleIdleRecoverState(result, reason: reason, attempt: attempt, phase: "before") {
                return true
            }

            await pokeKindleReaderRendering(reason: "\(reason)-\(attempt)")
            try? await Task.sleep(nanoseconds: 170_000_000)

            if let result = try? await readKindleReaderLayoutState(),
               handleIdleRecoverState(result, reason: reason, attempt: attempt, phase: "after") {
                return true
            }

            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 210_000_000)
            }
        }

        KindleRunLog.write("KINDLE reader layout idle-recover miss reason=\(reason) attempts=\(maxAttempts)")
        return false
    }

    private func handleIdleRecoverState(
        _ result: [String: Any],
        reason: String,
        attempt: Int,
        phase: String
    ) -> Bool {
        let key = result["key"] as? String ?? ""
        let liveKey = result["liveKey"] as? String ?? ""
        let orderedCount = Self.int(from: result["orderedCount"]) ?? 0
        let visibleArea = Self.numberValue(result["visibleArea"]) ?? 0
        let bandVisibleArea = Self.numberValue(result["bandVisibleArea"]) ?? 0
        let usableVisibleArea = max(visibleArea, bandVisibleArea)
        let viewportWidth = String(describing: result["viewportWidth"] ?? 0)
        let viewportHeight = String(describing: result["viewportHeight"] ?? 0)
        let surfaceArea = Double(max(0, readerSurfaceSize.width) * max(0, readerSurfaceSize.height))
        let coverage = surfaceArea > 1 ? usableVisibleArea / surfaceArea : 1
        let hasEnoughCoverage = surfaceArea < 50_000 || coverage >= 0.82
        let ok = !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            orderedCount > 0 &&
            usableVisibleArea > 0 &&
            hasEnoughCoverage
        KindleRunLog.write(
            "KINDLE reader layout idle-recover reason=\(reason) attempt=\(attempt) phase=\(phase) ok=\(ok) key=\(Self.keyLog(key)) live=\(Self.keyLog(liveKey)) ordered=\(orderedCount) viewport=\(viewportWidth)x\(viewportHeight) visible=\(visibleArea) band=\(bandVisibleArea) coverage=\(String(format: "%.3f", coverage))"
        )
        guard ok else { return false }
        clearReaderLayoutUnstableIfRecovered(
            reason: "idle-\(reason)",
            key: key,
            liveKey: liveKey,
            orderedCount: orderedCount,
            visibleArea: usableVisibleArea
        )
        return true
    }

    private func readKindleReaderLayoutState() async throws -> [String: Any] {
        try await evaluateJSON("""
        (function() {
          try {
            var state = window.__crKindleState ? window.__crKindleState() : '{}';
            var parsed = typeof state === 'string' ? JSON.parse(state) : state;
            return JSON.stringify({
              ok: true,
              key: parsed && parsed.key || '',
              liveKey: parsed && parsed.liveKey || '',
              orderedCount: parsed && parsed.orderedCount || 0,
              viewportWidth: parsed && parsed.viewportWidth || 0,
              viewportHeight: parsed && parsed.viewportHeight || 0,
              visibleArea: parsed && parsed.visibleArea || 0,
              bandVisibleArea: parsed && parsed.bandVisibleArea || 0
            });
          } catch (e) {
            return JSON.stringify({ ok:false, reason:String(e && e.message || e) });
          }
        })()
        """)
    }

    private func pokeKindleReaderRendering(reason: String) async {
        do {
            let result = try await evaluateJSON("""
            (function() {
              try { window.dispatchEvent(new Event('resize')); } catch (_) {}
              try { document.dispatchEvent(new Event('visibilitychange')); } catch (_) {}
              try {
                if (window.__crKindleProbe) {
                  window.__crKindleProbe.idleRecoverAt = Date.now ? Date.now() : new Date().getTime();
                  window.__crKindleProbe.idleRecoverReason = '\(Self.jsString(reason))';
                }
              } catch (_) {}
              try {
                if (window.crKindleUpdateLiveOverlay) window.crKindleUpdateLiveOverlay();
              } catch (_) {}
              return JSON.stringify({ ok:true, reason:'\(Self.jsString(reason))' });
            })()
            """)
            KindleRunLog.write("KINDLE reader layout idle-recover poke reason=\(reason) ok=\(String(describing: result["ok"] ?? false))")
        } catch {
            KindleRunLog.write("KINDLE reader layout idle-recover poke-error reason=\(reason) \(error.localizedDescription)")
        }
    }

    private func shouldRestartPlaybackAfterReaderLayout(reason: String) -> Bool {
        Self.layoutReasonShouldRestartPlayback(reason) && pendingLayoutPlaybackMode != nil
    }

    private static func layoutReasonShouldRestartPlayback(_ reason: String) -> Bool {
        switch reason {
        case "orientation", "reader-size", "surfaceSize":
            return true
        default:
            return false
        }
    }

    init(book: KindleBook, staleRecoveryAlreadyAttempted: Bool = false) {
        self.book = book
        self.analyticsContext = ProductAnalytics.shared.beginContentIntent(
            source: .kindle,
            format: .kindle,
            entryPoint: "kindle_library",
            intendedMode: "read"
        )
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let userContentController = WKUserContentController()
        if #available(iOS 14.0, *) {
            userContentController.addUserScript(WKUserScript(
                source: KindleWebScripts.metadataBootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
            userContentController.addUserScript(WKUserScript(
                source: KindleWebScripts.pageCaptureBootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
        } else {
            userContentController.addUserScript(WKUserScript(
                source: KindleWebScripts.metadataBootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            userContentController.addUserScript(WKUserScript(
                source: KindleWebScripts.pageCaptureBootstrap,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        config.userContentController = userContentController
        webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = KindleWebScripts.desktopChromeUserAgent
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        if #available(iOS 13.0, *) {
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        super.init()
        staleBookRecoveryAttempted = staleRecoveryAlreadyAttempted
        nativeTOCEntries = Self.loadCachedNativeTOCEntries(for: book)
        if !nativeTOCEntries.isEmpty {
            KindleRunLog.write("KINDLE native toc cache restored entries=\(nativeTOCEntries.count)")
        }
        webView.navigationDelegate = self
        webView.configuration.userContentController.add(self, name: "castReaderKindle")
        configurePageModeGestures()
        webView.allowsBackForwardNavigationGestures = false
        NotificationCenter.default.publisher(for: .castReaderPlaybackVoiceWillSwitch)
            .receive(on: RunLoop.main)
            .sink { [weak self] notification in
                self?.handlePlaybackVoiceWillSwitch(notification)
            }
            .store(in: &cancellables)
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "castReaderKindle")
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        Task { @MainActor [weak self] in
            self?.handleKindleScriptMessage(body)
        }
    }

    private func handleKindleScriptMessage(_ body: Any) {
        guard let payload = body as? [String: Any] else {
            KindleRunLog.write("KINDLE script message invalid \(String(describing: body))")
            return
        }
        if let event = KindleSyncDialogEvent(payload: payload) {
            handleKindleSyncDialogEvent(event)
            return
        }
        let type = payload["type"] as? String ?? "unknown"
        switch type {
        case "kindle-user-page-gesture":
            let direction = payload["direction"] as? String ?? "unknown"
            guard shouldResumeAfterUserPageTurn,
                  !isPageTurnResuming,
                  !isAdvancingLivePage,
                  let oldKey = livePageKey?.nilIfEmpty else {
                KindleRunLog.write("KINDLE user page gesture ignored direction=\(direction) active=\(shouldResumeAfterUserPageTurn ? "Y" : "N")")
                return
            }
            KindleRunLog.write("KINDLE user page gesture direction=\(direction) old=\(Self.keyLog(oldKey))")
            scheduleExternalPageChangeResume(
                visibleKey: nil,
                oldKey: oldKey,
                reason: "kindle-swipe-\(direction)",
                force: true
            )
        case "toc-click", "toc-after-click", "toc-close", "toc-close-error":
            if isNativeTOCBridgeJumping {
                KindleRunLog.write("KINDLE toc event ignored-bridge-jump type=\(type) text=\(Self.keyLog(payload["text"] as? String ?? ""))")
            } else if type == "toc-click" || type == "toc-after-click" {
                isKindleTOCVisible = true
                if type == "toc-after-click" {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        await self?.finishNativeTOCUserSelection()
                    }
                }
            } else if type == "toc-close" {
                isKindleTOCVisible = false
                isNativeTOCPresented = false
                isNativeTOCLoading = false
                Task { @MainActor [weak self] in
                    await self?.setNativeKindleTOCSheetStyled(false, reason: "toc-event-close")
                    await self?.setNativeKindleTOCHidden(false, reason: "toc-event-close")
                    await self?.setKindlePageModeLocked(true)
                }
            }
            let text = Self.keyLog(payload["text"] as? String ?? "")
            let active = Self.keyLog(payload["activeEntries"] as? String ?? "")
            let label = Self.keyLog(payload["label"] as? String ?? payload["closeLabel"] as? String ?? "")
            let raw = Self.int(from: payload["rawCount"]) ?? -1
            let count = Self.int(from: payload["count"]) ?? -1
            let clicked = String(describing: payload["clicked"] ?? "")
            KindleRunLog.write("KINDLE toc event type=\(type) text=\(text) active=\(active) label=\(label) raw=\(raw) count=\(count) clicked=\(clicked) url=\(Self.keyLog(payload["url"] as? String ?? ""))")
        default:
            KindleRunLog.write("KINDLE script event type=\(type) payload=\(payload)")
        }
    }

    private func handleKindleSyncDialogEvent(_ event: KindleSyncDialogEvent) {
        if let localLocation = event.localLocation { kindleSyncLocalLocation = localLocation }
        if let cloudLocation = event.cloudLocation { kindleSyncCloudLocation = cloudLocation }

        if let choice = event.choice {
            statusText = AppLocalized("正在应用 Kindle 阅读位置…")
            KindleRunLog.write("KINDLE sync dialog choice=\(choice.rawValue) local=\(kindleSyncLocalLocation ?? -1) cloud=\(kindleSyncCloudLocation ?? -1)")
            return
        }

        if event.isVisible {
            guard !isKindleSyncDialogVisible else { return }
            syncDialogEpoch &+= 1
            syncDialogResolutionTask?.cancel()
            syncDialogResolutionTask = nil
            syncDialogResumeMode = mode
            syncDialogShouldResume = isCurrentModePlaybackActiveOrPreparing || isAdvancingLivePage || isPageTurnResuming
            pendingStartAfterSyncResolution = false
            isKindleSyncDialogVisible = true
            if syncDialogShouldResume {
                stopPlaybackForPageTurn(reason: "kindle-sync-dialog", clearLiveOverlay: false)
                if let resumeMode = syncDialogResumeMode { mode = resumeMode }
            }
            statusText = AppLocalized("请先确认 Kindle 阅读位置。")
            KindleRunLog.write("KINDLE sync dialog shown local=\(kindleSyncLocalLocation ?? -1) cloud=\(kindleSyncCloudLocation ?? -1) resume=\(syncDialogShouldResume ? "Y" : "N") mode=\(mode.rawValue)")
            return
        }

        finishKindleSyncDialog(reason: "observer-hidden")
    }

    private func finishKindleSyncDialog(reason: String) {
        guard isKindleSyncDialogVisible else { return }
        isKindleSyncDialogVisible = false
        syncDialogEpoch &+= 1
        let epoch = syncDialogEpoch
        let shouldResume = syncDialogShouldResume
        let resumeMode = syncDialogResumeMode ?? mode
        syncDialogShouldResume = false
        syncDialogResumeMode = nil
        statusText = AppLocalized("正在应用 Kindle 阅读位置…")
        KindleRunLog.write("KINDLE sync dialog hidden reason=\(reason) local=\(kindleSyncLocalLocation ?? -1) cloud=\(kindleSyncCloudLocation ?? -1) resume=\(shouldResume ? "Y" : "N")")

        syncDialogResolutionTask?.cancel()
        syncDialogResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard !Task.isCancelled, self.syncDialogEpoch == epoch, !self.isKindleSyncDialogVisible else { return }
            do {
                try await self.ensureCaptureScriptInstalled(reason: "kindle-sync-dialog-resolved")
                try await self.waitForPageReady()
                try await self.waitForKindleImageStable()
                guard !Task.isCancelled, self.syncDialogEpoch == epoch, !self.isKindleSyncDialogVisible else { return }
                self.resetLiveSession(clearPlaybackCenter: false)
                self.mode = resumeMode
                let shouldStart = shouldResume || self.pendingStartAfterSyncResolution
                self.pendingStartAfterSyncResolution = false
                // Publish resolution before starting. startCurrentMode() otherwise
                // sees this task and correctly defers a user tap, which would make
                // an automatic resume defer itself forever.
                self.syncDialogResolutionTask = nil
                if shouldStart {
                    try await self.startCurrentMode()
                } else {
                    self.statusText = AppLocalized("打开任意位置，然后点播放开始朗读。")
                }
                KindleRunLog.write("KINDLE sync dialog resolved resume=\(shouldResume ? "Y" : "N") requested=\(shouldStart ? "Y" : "N") mode=\(resumeMode.rawValue) key=\(Self.keyLog(self.livePageKey ?? ""))")
            } catch is CancellationError {
                KindleRunLog.write("KINDLE sync dialog resolve cancelled resume=\(shouldResume ? "Y" : "N")")
            } catch {
                self.statusText = error.localizedDescription
                KindleRunLog.write("KINDLE sync dialog resolve failed resume=\(shouldResume ? "Y" : "N") error=\(error.localizedDescription)")
            }
            if self.syncDialogEpoch == epoch {
                self.syncDialogResolutionTask = nil
            }
        }
    }

    private func finishNativeTOCUserSelection() async {
        isNativeTOCPresented = false
        isNativeTOCLoading = false
        nativeTOCError = nil
        statusText = ""
        isKindleTOCVisible = false
        await setNativeKindleTOCSheetStyled(false, reason: "toc-user-select")
        await setNativeKindleTOCHidden(false, reason: "toc-user-select")
        await setKindlePageModeLocked(true)
        KindleRunLog.write("KINDLE native toc user selection closed keep-viewport")
    }

    func isSameBook(as candidate: KindleBook) -> Bool {
        if book.id == candidate.id { return true }
        if let lhs = book.asin?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           let rhs = candidate.asin?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           !lhs.isEmpty,
           lhs == rhs {
            return true
        }
        return Self.normalizedReaderIdentity(book.readerURL) == Self.normalizedReaderIdentity(candidate.readerURL)
    }

    func refreshMetadata(from latest: KindleBook) {
        guard isSameBook(as: latest) else { return }
        book.title = latest.title.isEmpty ? book.title : latest.title
        book.author = latest.author.isEmpty ? book.author : latest.author
        book.coverURL = latest.coverURL ?? book.coverURL
        book.readerURL = latest.readerURL.isEmpty ? book.readerURL : latest.readerURL
        book.progressLabel = latest.progressLabel.isEmpty ? book.progressLabel : latest.progressLabel
        book.lastOpenedAt = latest.lastOpenedAt ?? book.lastOpenedAt
        book.lastSyncedAt = max(book.lastSyncedAt, latest.lastSyncedAt)
        book.lastReadPageKey = latest.lastReadPageKey ?? book.lastReadPageKey
        book.lastReadURL = latest.lastReadURL ?? book.lastReadURL
    }

    private static func normalizedReaderIdentity(_ raw: String) -> String {
        guard var components = URLComponents(string: raw) else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        let keep = Set(["asin"])
        components.queryItems = components.queryItems?
            .filter { keep.contains($0.name.lowercased()) }
            .sorted { $0.name < $1.name }
        components.fragment = nil
        return components.string ?? raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func nativeTOCCacheKey(for book: KindleBook) -> String {
        let identity = normalizedReaderIdentity(book.readerURL.isEmpty ? book.id : book.readerURL)
        let safeIdentity = identity
            .replacingOccurrences(of: "[^a-zA-Z0-9._-]+", with: "_", options: .regularExpression)
            .prefix(180)
        return "kindle.nativeTOC.\(safeIdentity)"
    }

    private static func loadCachedNativeTOCEntries(for book: KindleBook) -> [KindleTOCEntry] {
        guard let rows = UserDefaults.standard.array(forKey: nativeTOCCacheKey(for: book)) as? [[String: Any]] else {
            return []
        }
        return rows.enumerated().compactMap { offset, row in
            let text = (row["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return KindleTOCEntry(
                index: Self.int(from: row["index"]) ?? offset,
                text: text,
                level: Self.int(from: row["level"]) ?? 0,
                active: Self.boolValue(row["active"]),
                path: row["path"] as? String ?? "",
                sourcePath: row["sourcePath"] as? String ?? "",
                href: row["href"] as? String ?? "",
                role: row["role"] as? String ?? "",
                aria: row["aria"] as? String ?? "",
                actionSummary: row["actionSummary"] as? String ?? ""
            )
        }
    }

    private func saveNativeTOCEntriesToCache(_ entries: [KindleTOCEntry], reason: String) {
        guard !entries.isEmpty else { return }
        let rows = entries.map { entry -> [String: Any] in
            [
                "index": entry.index,
                "text": entry.text,
                "level": entry.level,
                "active": entry.active,
                "path": entry.path,
                "sourcePath": entry.sourcePath,
                "href": entry.href,
                "role": entry.role,
                "aria": entry.aria,
                "actionSummary": entry.actionSummary
            ]
        }
        UserDefaults.standard.set(rows, forKey: Self.nativeTOCCacheKey(for: book))
        KindleRunLog.write("KINDLE native toc cache saved reason=\(reason) entries=\(entries.count)")
    }

    func loadIfNeeded() {
        guard !didLoad else { return }
        guard readerSurfaceSize.width > 80, readerSurfaceSize.height > 80 else {
            KindleRunLog.write("KINDLE webview load deferred waiting-surface")
            return
        }
        didLoad = true
        restoreReaderViewportCrop(reason: "preload-surface")
        load(book.effectiveReaderURL, reason: "open-book")
        store.markOpened(book)
    }

    func requestContinueListening() {
        guard !isKindleSyncDialogVisible else {
            statusText = AppLocalized("请先确认 Kindle 阅读位置。")
            return
        }
        let request = continueListeningGate.request(for: book.id)
        continueListeningRequestedAt[request] = Date()
        KindleRunLog.write("KINDLE audiobook continue requested request=\(request) book=\(Self.keyLog(book.id)) anchor=\(store.hasListeningAnchor(for: book.id) ? "Y" : "N")")

        if mode != .read {
            flushListeningAnchor(reason: "continue-mode-switch")
            stopPlaybackForPageTurn(reason: "continue-listening-mode-switch", clearLiveOverlay: false)
            applyModeSelection(.read)
        }
        if webView.url != nil, !webView.isLoading {
            schedulePendingContinueListening(reason: "request-ready-webview")
        }
    }

    func flushListeningAnchor(reason: String) {
        listeningAnchorPersistTask?.cancel()
        listeningAnchorPersistTask = nil
        guard let anchor = pendingPersistentAnchor else { return }
        pendingPersistentAnchor = nil
        persistListeningAnchor(anchor, reason: reason)
    }

    func reload() {
        resetLiveSession(clearPlaybackCenter: false)
        if webView.url == nil {
            load(book.effectiveReaderURL, reason: "reload-empty")
        } else {
            KindleRunLog.write("KINDLE webview reload current=\(webView.url?.absoluteString ?? "")")
            webView.reload()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let finishedURL = webView.url?.absoluteString ?? ""
        KindleRunLog.write("KINDLE webview didFinish url=\(finishedURL)")
        if isStaleBookRecovering, finishedURL.contains("kindle-library") {
            readerSetupTask?.cancel()
            readerSetupTask = nil
            statusText = AppLocalized("正在同步 Kindle 书架…")
            KindleRunLog.write("KINDLE webview didFinish library-recovery skip-reader-setup")
            return
        }
        statusText = AppLocalized("打开任意位置，然后点播放开始朗读。")
        scheduleReaderSetup(reason: "didFinish")
        detectAndRecoverStaleBookEntry()
    }

    private func scheduleReaderSetup(reason: String) {
        readerSetupTask?.cancel()
        configurePageModeGestures()
        readerSetupTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.applyKindleReaderPreferences(reason: reason)
            guard !Task.isCancelled else { return }
            self.installCaptureScript()
            await self.setKindlePageModeLocked(true)
            guard !Task.isCancelled else { return }
            try? await self.waitForKindleImageStable()
            guard !Task.isCancelled else { return }
            await self.logReaderLayoutProbe(reason: reason)
            await self.logKindleGeometrySnapshot(reason: reason)
            self.schedulePendingContinueListening(reason: "webview-\(reason)")
        }
    }

    private func detectAndRecoverStaleBookEntry() {
        guard staleBookRecoveryTask == nil, !isStaleBookRecovering else { return }
        staleBookErrorProbeTask?.cancel()
        staleBookErrorProbeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 0..<48 {
                guard !Task.isCancelled else { return }
                if await self.hasStaleBookErrorDOM() {
                    self.isStaleBookEntryError = true
                    KindleRunLog.write("KINDLE stale-entry error detected attempt=\(attempt)")
                    if self.staleBookRecoveryAttempted {
                        self.statusText = AppLocalized("书架已同步，但 Kindle 未能打开这本书。请重试或返回书架。")
                        self.staleBookRecoveryMessage = self.statusText
                        KindleRunLog.write("KINDLE stale-entry fresh-reader failed no-auto-loop book=\(Self.keyLog(self.book.id))")
                    } else {
                        self.startStaleBookRecovery()
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            KindleRunLog.write("KINDLE stale-entry probe clear attempts=48")
        }
    }

    private func hasStaleBookErrorDOM() async -> Bool {
        let script = """
        (function() {
          function norm(v) { return String(v || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
          var bodyText = norm(document.body && document.body.innerText);
          var exact = bodyText.indexOf('please try to open this book from the library again') >= 0;
          var title = bodyText.indexOf('oops') >= 0 && bodyText.indexOf('something went wrong') >= 0;
          var nodes = Array.prototype.slice.call(document.querySelectorAll('[role="dialog"], [aria-modal="true"], button, a'));
          var back = nodes.some(function(el) {
            var t = norm((el.innerText || '') + ' ' + (el.getAttribute && el.getAttribute('aria-label') || ''));
            return t.indexOf('back to library') >= 0 || t.indexOf('return to library') >= 0;
          });
          var dialog = nodes.some(function(el) {
            if (!(el.matches && el.matches('[role="dialog"], [aria-modal="true"]'))) return false;
            var t = norm(el.innerText);
            return t.indexOf('something went wrong') >= 0 || t.indexOf('open this book from the library') >= 0;
          });
          return !!(exact || dialog || (title && back));
        })();
        """
        do {
            return (try await evaluate(script) as? Bool) == true
        } catch {
            return false
        }
    }

    func retryStaleBookRecovery() {
        guard !isStaleBookRecovering else { return }
        staleBookRecoveryAttempted = false
        staleBookRecoveryTask?.cancel()
        staleBookRecoveryTask = nil
        startStaleBookRecovery()
    }

    private func startStaleBookRecovery() {
        guard !staleBookRecoveryAttempted, staleBookRecoveryTask == nil else { return }
        staleBookRecoveryAttempted = true
        isStaleBookRecovering = true
        staleBookRecoveryMessage = nil
        staleBookRecoveryProgressText = AppLocalized("正在准备…")
        isPreparing = true
        statusText = AppLocalized("正在重新同步 Kindle 书籍…")
        let target = book
        KindleRunLog.write("KINDLE stale-entry auto-recovery start book=\(Self.keyLog(target.id))")
        staleBookErrorProbeTask?.cancel()
        staleBookErrorProbeTask = nil
        readerSetupTask?.cancel()
        readerSetupTask = nil
        let recoveryWebView = makeLibraryRecoveryWebView()
        libraryRecoveryWebView = recoveryWebView
        // Keep the current reader mounted while the same visible WKWebView
        // is replaced by a clean, mobile-UA shelf WebView. Clearing
        // PlaybackCenter here would dismiss that visible recovery surface.
        resetLiveSession(clearPlaybackCenter: false)
        staleBookRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Allow SwiftUI to attach the recovery WebView at a real size before
            // loading Kindle's SPA. A zero-sized/unattached WebView does not
            // render the virtualized shelf.
            await Task.yield()
            try? await Task.sleep(nanoseconds: 250_000_000)
            let result = await KindleLibraryRecoveryService.shared.recover(
                book: target,
                in: recoveryWebView
            ) { progress in
                self.staleBookRecoveryProgressText = progress
            }
            guard !Task.isCancelled else { return }
            self.libraryRecoveryWebView = nil
            self.staleBookRecoveryTask = nil
            self.isPreparing = false
            self.isStaleBookRecovering = false
            switch result {
            case .recovered(let latest):
                self.isStaleBookEntryError = false
                self.staleBookRecoveryMessage = nil
                self.staleBookRecoveryProgressText = AppLocalized("正在重新打开书籍…")
                self.refreshMetadata(from: latest)
                self.statusText = AppLocalized("打开任意位置，然后点播放开始朗读。")
                KindleRunLog.write("KINDLE stale-entry auto-recovery synced book=\(Self.keyLog(latest.id)) fresh-reader=begin")
                KindlePlaybackCenter.shared.replaceAfterLibraryRecovery(current: self, book: latest)
            case .signInRequired:
                self.statusText = AppLocalized("Kindle 登录已过期，请重新登录并同步书架。")
                self.staleBookRecoveryMessage = self.statusText
                KindleRunLog.write("KINDLE stale-entry auto-recovery auth-required")
            case .notFound:
                self.statusText = AppLocalized("未能在 Kindle 书架找到这本书，请手动同步书架。")
                self.staleBookRecoveryMessage = self.statusText
                KindleRunLog.write("KINDLE stale-entry auto-recovery not-found book=\(Self.keyLog(target.id))")
            case .reopenFailed:
                self.statusText = AppLocalized("书架已同步，但 Kindle 未能打开这本书。请重试或返回书架。")
                self.staleBookRecoveryMessage = self.statusText
                KindleRunLog.write("KINDLE stale-entry auto-recovery reopen-failed book=\(Self.keyLog(target.id))")
            }
        }
    }

    private func makeLibraryRecoveryWebView() -> WKWebView {
        // Keep this configuration aligned with KindleLibrarySyncViewModel. In
        // particular, do not set the desktop reader UA and do not inject reader
        // scripts; Amazon uses the shelf client to refresh its book session.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let recovery = WKWebView(frame: .zero, configuration: config)
        recovery.scrollView.contentInsetAdjustmentBehavior = .never
        recovery.scrollView.contentInset = .zero
        recovery.scrollView.scrollIndicatorInsets = .zero
        if #available(iOS 13.0, *) {
            recovery.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        return recovery
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        finishKindleSyncDialog(reason: "navigation-start")
        KindleRunLog.write("KINDLE webview didStart url=\(webView.url?.absoluteString ?? "")")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        KindleRunLog.write("KINDLE webview didFail url=\(webView.url?.absoluteString ?? "") error=\(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        KindleRunLog.write("KINDLE webview didFailProvisional url=\(webView.url?.absoluteString ?? "") error=\(error.localizedDescription)")
    }

    private func schedulePendingContinueListening(reason: String) {
        guard continueListeningGate.hasPendingRequest(for: book.id), continueListeningTask == nil else { return }
        continueListeningTask = Task { @MainActor [weak self] in
            guard let self else { return }
            guard let request = self.continueListeningGate.consume(for: self.book.id) else {
                self.continueListeningTask = nil
                return
            }
            let requestedAt = self.continueListeningRequestedAt.removeValue(forKey: request) ?? Date()
            await self.performContinueListening(request: request, requestedAt: requestedAt, reason: reason)
            self.continueListeningTask = nil
            self.schedulePendingContinueListening(reason: "coalesced-request")
        }
    }

    private func performContinueListening(request: Int, requestedAt: Date, reason: String) async {
        let audio = AudioPlayerService.shared
        if mode == .read,
           let vm = readVM,
           vm.currentParagraphIndex >= 0,
           !vm.isFinished,
           audio.currentBookId == book.id {
            startContinueListeningBaseline(
                request: request,
                requestedAt: requestedAt,
                match: .exact,
                reason: "memory-session",
                pageTextHash: store.listeningAnchor(for: book.id)?.pageTextHash ?? ""
            )
            vm.ensurePlaying()
            startPageKeyWatcher()
            KindlePlaybackCenter.shared.activate(model: self)
            KindleRunLog.write("KINDLE audiobook continue existing-session request=\(request) key=\(Self.keyLog(livePageKey ?? "")) p=\(vm.currentParagraphIndex)")
            return
        }

        statusText = AppLocalized("打开任意位置，然后点播放开始朗读。")
        KindleRunLog.write("KINDLE audiobook continue unavailable request=\(request) reason=no-live-session source=\(reason) anchor=\(store.hasListeningAnchor(for: book.id) ? "Y" : "N")")
    }

    private func startContinueListeningBaseline(
        request: Int,
        requestedAt: Date,
        match: KindleListeningAnchorMatch,
        reason: String,
        pageTextHash: String
    ) {
        continueListeningBaselineTask?.cancel()
        continueListeningBaselineTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for _ in 0..<200 {
                guard !Task.isCancelled else { return }
                let audio = AudioPlayerService.shared
                if audio.isPlaying, audio.currentBookId == self.book.id {
                    let elapsedMs = Int(Date().timeIntervalSince(requestedAt) * 1_000)
                    KindleRunLog.write("KINDLE audiobook first-audio request=\(request) elapsedMs=\(elapsedMs) match=\(match.rawValue) reason=\(reason) key=\(Self.keyLog(self.livePageKey ?? "")) hash=\(pageTextHash.prefix(12))")
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            let elapsedMs = Int(Date().timeIntervalSince(requestedAt) * 1_000)
            KindleRunLog.write("KINDLE audiobook first-audio-timeout request=\(request) elapsedMs=\(elapsedMs) match=\(match.rawValue) reason=\(reason) key=\(Self.keyLog(self.livePageKey ?? "")) hash=\(pageTextHash.prefix(12))")
        }
    }

    private func stabilizeInitialReaderLayout(reason: String) async {
        configurePageModeGestures()
        installCaptureScript()
        await setKindlePageModeLocked(true)
        do {
            try await waitForKindleImageStable()
            let state = try await evaluateJSON("window.__crKindleState && window.__crKindleState()")
            let key = (state["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let orderedCount = Self.int(from: state["orderedCount"]) ?? 0
            let visibleArea = Self.numberValue(state["visibleArea"]) ?? 0
            let observedIndex = String(describing: state["observedIndex"] ?? "?")
            let observedCount = String(describing: state["observedCount"] ?? "?")
            let heldIndex = String(describing: state["heldIndex"] ?? "?")
            let heldCount = String(describing: state["heldCount"] ?? "?")
            guard !key.isEmpty, orderedCount > 0, visibleArea > 0 else {
                KindleRunLog.write("KINDLE initial layout align skipped reason=\(reason) key=\(Self.keyLog(key)) ordered=\(orderedCount) observed=\(observedIndex)/\(observedCount) held=\(heldIndex)/\(heldCount) visible=\(visibleArea)")
                return
            }
            let aligned = await restorePlaybackKeyVisibility(key, reason: "initial-\(reason)", maxSteps: 2)
            KindleRunLog.write("KINDLE initial layout align \(aligned ? "hit" : "miss") reason=\(reason) key=\(Self.keyLog(key)) ordered=\(orderedCount) observed=\(observedIndex)/\(observedCount) held=\(heldIndex)/\(heldCount) visible=\(visibleArea)")
        } catch {
            KindleRunLog.write("KINDLE initial layout align error reason=\(reason) \(error.localizedDescription)")
        }
    }

    private func configurePageModeGestures() {
        // Keep WKWebView's native scroll machinery alive so Kindle can lay out
        // and render its internal scroll containers. The injected Kindle script
        // blocks manual body scrolling while still allowing UI surfaces like TOC
        // to scroll, matching the Android WebView behavior.
        webView.scrollView.isScrollEnabled = true
        webView.scrollView.bounces = false
        webView.scrollView.alwaysBounceVertical = false
        webView.scrollView.alwaysBounceHorizontal = false
        webView.scrollView.panGestureRecognizer.isEnabled = true
        webView.scrollView.pinchGestureRecognizer?.isEnabled = false
    }

    private func applyKindleReaderPreferences(reason: String) async {
        var lastStage = ""
        for attempt in 1...5 {
            guard !Task.isCancelled else {
                KindleRunLog.write("KINDLE reader prefs cancelled reason=\(reason) attempt=\(attempt)")
                return
            }
            do {
                try await Task.sleep(nanoseconds: attempt == 1 ? 1_000_000_000 : 450_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            do {
                let result = try await evaluateJSON(KindleWebScripts.applyReaderPreferences)
                let ok = Self.boolValue(result["ok"])
                let stage = (result["stage"] as? String) ?? ""
                lastStage = stage
                KindleRunLog.write(
                    "KINDLE reader prefs reason=\(reason) attempt=\(attempt) ok=\(ok) stage=\(stage) single=\(String(describing: result["singleClicked"] ?? false)) narrow=\(String(describing: result["narrowClicked"] ?? false)) fontSize=\(String(describing: result["fontSize"] ?? [:])) close=\(String(describing: result["closeMode"] ?? "")) hasNext=\(String(describing: result["hasNext"] ?? false)) hasPrev=\(String(describing: result["hasPrev"] ?? false))"
                )
                if ok {
                    try? await Task.sleep(nanoseconds: 900_000_000)
                    return
                }
            } catch {
                KindleRunLog.write("KINDLE reader prefs error reason=\(reason) attempt=\(attempt) \(error.localizedDescription)")
            }
        }
        KindleRunLog.write("KINDLE reader prefs incomplete reason=\(reason) lastStage=\(lastStage)")
    }

    func toggleTOCProbeFromButton(preferCachedOnly: Bool = false) {
        guard !isNativeTOCLoading, !isNativeTOCBridgeJumping else {
            KindleRunLog.write("KINDLE native toc open ignored reason=jump-in-flight loading=\(isNativeTOCLoading) bridge=\(isNativeTOCBridgeJumping) epoch=\(nativeTOCEpoch)")
            return
        }
        if isNativeTOCPresented || isKindleTOCVisible {
            dismissNativeTOCPanel()
            return
        }
        nativeTOCTask?.cancel()
        nativeTOCEpoch &+= 1
        let epoch = nativeTOCEpoch
        if preferCachedOnly {
            nativeTOCTask = Task { @MainActor [weak self] in
                guard let self else { return }
                if !self.shouldRunFullReaderLayoutRepair {
                    self.layoutPlaybackRestartTask?.cancel()
                    self.layoutPlaybackRestartTask = nil
                    self.readerLayoutRepairRetry = 0
                    let attempts = self.isReaderLayoutCurrentlyUnstable ? 8 : 2
                    let recovered = await self.recoverReaderLayoutForIdle(reason: "toc-cached-open", maxAttempts: attempts)
                    KindleRunLog.write("KINDLE reader layout idle-recover before-cached-toc recovered=\(recovered) attempts=\(attempts)")
                }
                guard !Task.isCancelled, epoch == self.nativeTOCEpoch else { return }
                self.freezeReaderSurface(reason: "toc-cached-open", seconds: 30)
                self.isNativeTOCPresented = true
                self.isKindleTOCVisible = false
                self.isNativeTOCLoading = false
                self.nativeTOCError = self.nativeTOCEntries.isEmpty ? AppLocalized("暂未缓存这本书的目录，请先竖屏打开一次目录。") : nil
                self.statusText = ""
                KindleRunLog.write("KINDLE native toc cached panel source=playback-bar entries=\(self.nativeTOCEntries.count) epoch=\(epoch)")
            }
            return
        }
        nativeTOCTask = Task { @MainActor [weak self] in
            await self?.presentNativeTOC(reason: "playback-bar", epoch: epoch)
        }
    }

    func runTOCProbeFromButton() {
        toggleTOCProbeFromButton()
    }

    func dismissNativeTOCPanel() {
        nativeTOCEpoch &+= 1
        nativeTOCTask?.cancel()
        nativeTOCTask = nil
        isNativeTOCLoading = false
        nativeTOCError = nil
        statusText = ""
        let shouldCloseNativeTOC = isKindleTOCVisible
        Task { @MainActor [weak self] in
            guard let self else { return }
            if shouldCloseNativeTOC {
                _ = await self.closeTOCIfVisible(reason: "native-dismiss")
                try? await Task.sleep(nanoseconds: 180_000_000)
                await self.setNativeKindleTOCHidden(false, reason: "native-dismiss")
                await self.setNativeKindleTOCSheetStyled(false, reason: "native-dismiss")
                self.freezeReaderSurface(reason: "native-dismiss", seconds: 1.6)
                self.isNativeTOCPresented = false
                self.isKindleTOCVisible = false
                await self.setKindlePageModeLocked(true)
            } else {
                self.freezeReaderSurface(reason: "cached-dismiss", seconds: 1.6)
                KindleRunLog.write("KINDLE native toc cached panel dismissed no-native-close epoch=\(self.nativeTOCEpoch)")
                self.isNativeTOCPresented = false
                self.isKindleTOCVisible = false
            }
            KindleRunLog.write("KINDLE native toc dismissed keep-viewport epoch=\(self.nativeTOCEpoch)")
        }
    }

    func selectNativeTOCEntry(_ entry: KindleTOCEntry) {
        guard !isNativeTOCLoading else { return }
        nativeTOCTask?.cancel()
        nativeTOCEpoch &+= 1
        let epoch = nativeTOCEpoch
        nativeTOCTask = Task { @MainActor [weak self] in
            await self?.jumpToNativeTOCEntry(entry, epoch: epoch)
        }
    }

    private func presentNativeTOC(reason: String, epoch: UInt64) async {
        guard nativeTOCEpoch == epoch else { return }
        isNativeTOCPresented = true
        isNativeTOCLoading = true
        nativeTOCError = nil
        statusText = ""
        nativeTOCEntries = []
        KindleRunLog.write("KINDLE tocOpen requested source=\(reason) epoch=\(epoch) bridge=hidden-panel")
        installCaptureScript()
        await setNativeKindleTOCSheetStyled(false, reason: "native-open-clear-stale-\(reason)")
        await setNativeKindleTOCHidden(true, reason: "native-open-hidden-bridge-\(reason)")
        await setKindlePageModeLocked(false)
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard nativeTOCEpoch == epoch, !Task.isCancelled else { return }

        var didOpenNativeTOC = false
        for attempt in 1...7 {
            do {
                let result = try await evaluateJSON(KindleWebScripts.tocProbe)
                let stage = result["stage"] as? String ?? ""
                let rawCount = Self.int(from: result["rawCount"]) ?? -1
                let count = Self.int(from: result["count"]) ?? ((result["entries"] as? [[String: Any]])?.count ?? 0)
                didOpenNativeTOC = count > 0 || stage == "toc-visible"
                KindleRunLog.write("KINDLE tocOpen panelFound=\(didOpenNativeTOC) source=\(reason) attempt=\(attempt) stage=\(stage) raw=\(rawCount) count=\(count) epoch=\(epoch)")
                if didOpenNativeTOC {
                    isKindleTOCVisible = true
                    isNativeTOCPresented = true
                    nativeTOCError = nil
                    break
                }
            } catch {
                KindleRunLog.write("KINDLE native toc sheet open error reason=\(reason) attempt=\(attempt) \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: attempt == 1 ? 900_000_000 : 650_000_000)
            guard nativeTOCEpoch == epoch, !Task.isCancelled else { return }
        }

        if didOpenNativeTOC {
            await setNativeKindleTOCHidden(true, reason: "native-open-hidden-ready-\(reason)")
            guard nativeTOCEpoch == epoch, !Task.isCancelled else { return }
            let scanned = await scanNativeTOCEntries(reason: "bridge-\(reason)")
            guard nativeTOCEpoch == epoch, !Task.isCancelled else { return }
            await setKindlePageModeLocked(true)
            if scanned {
                isNativeTOCLoading = false
                nativeTOCError = nil
                statusText = ""
                KindleRunLog.write("KINDLE native toc bridge ready source=\(reason) entries=\(nativeTOCEntries.count) epoch=\(epoch)")
            } else {
                isNativeTOCLoading = false
                nativeTOCError = AppLocalized("暂未找到这本书的目录。")
                _ = await closeTOCIfVisible(reason: "native-scan-empty")
                await setNativeKindleTOCHidden(false, reason: "native-scan-empty")
                isKindleTOCVisible = false
                KindleRunLog.write("KINDLE native toc bridge empty source=\(reason) epoch=\(epoch)")
            }
            return
        } else {
            isNativeTOCLoading = false
            nativeTOCError = AppLocalized("暂未找到这本书的目录。")
            _ = await closeTOCIfVisible(reason: "native-load-open-failed")
            await setNativeKindleTOCHidden(false, reason: "native-load-open-failed")
            await setNativeKindleTOCSheetStyled(false, reason: "native-load-open-failed")
            await setKindlePageModeLocked(true)
            return
        }
    }

    private func jumpToNativeTOCEntry(_ entry: KindleTOCEntry, epoch: UInt64) async {
        guard nativeTOCEpoch == epoch else { return }
        isNativeTOCBridgeJumping = true
        defer { isNativeTOCBridgeJumping = false }
        nativeTOCError = nil
        isNativeTOCLoading = true
        let resumeMode = pendingManualPageResumeMode ?? mode
        let shouldResume = shouldResumeAfterUserPageTurn
        KindleRunLog.write("KINDLE toc select begin index=\(entry.index) path=\(Self.keyLog(entry.path)) text=\(Self.keyLog(entry.text)) resume=\(shouldResume) mode=\(resumeMode.rawValue) epoch=\(epoch)")
        isNativeTOCPresented = false
        isKindleTOCVisible = false
        statusText = AppLocalized("正在跳转章节…")
        readerSurfaceFreezeUntil = nil
        restoreReaderViewportCrop(reason: "toc-select-start")

        let visibleOldKey = await currentVisibleKindlePageKey()
        let oldKey: String
        if let visibleKey = visibleOldKey.nilIfEmpty {
            oldKey = visibleKey
        } else {
            oldKey = await currentKindlePageKey()
        }
        resetLiveSession(clearPlaybackCenter: false)
        mode = resumeMode
        cancelInFlightProcessingForManualPageTurn(reason: "toc-jump")
        pendingCaptureKey = nil
        clearExternalMismatchState()
        if shouldResume {
            isPageTurnResuming = true
            KindlePlaybackCenter.shared.activate(model: self)
            statusText = AppLocalized("正在切换 Kindle 页面…")
        }
        installCaptureScript()
        await setKindlePageModeLocked(false)
        await setNativeKindleTOCHidden(true, reason: "native-jump-open")
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard nativeTOCEpoch == epoch, !Task.isCancelled else { return }

        var didOpenNativeTOC = false
        for attempt in 1...7 {
            do {
                let probe = try await evaluateJSON(KindleWebScripts.tocProbe)
                let count = Self.int(from: probe["count"]) ?? ((probe["entries"] as? [[String: Any]])?.count ?? 0)
                let stage = probe["stage"] as? String ?? ""
                didOpenNativeTOC = count > 0 || stage == "toc-visible"
                KindleRunLog.write("KINDLE native toc jump open attempt=\(attempt) stage=\(stage) count=\(count) target=\(entry.index) epoch=\(epoch)")
                if didOpenNativeTOC {
                    break
                }
            } catch {
                KindleRunLog.write("KINDLE native toc jump open error attempt=\(attempt) index=\(entry.index) \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: attempt == 1 ? 700_000_000 : 520_000_000)
            guard nativeTOCEpoch == epoch, !Task.isCancelled else { return }
        }

        guard didOpenNativeTOC else {
            isNativeTOCLoading = false
            nativeTOCError = AppLocalized("跳转失败，请重试。")
            _ = await closeTOCIfVisible(reason: "native-jump-open-failed")
            await setNativeKindleTOCHidden(false, reason: "native-jump-open-failed")
            await restoreViewportAfterNativeTOCBridge(reason: "native-jump-open-failed")
            isPageTurnResuming = false
            return
        }

        await setNativeKindleTOCHidden(true, reason: "native-jump-keep-hidden")
        try? await Task.sleep(nanoseconds: 80_000_000)
        guard nativeTOCEpoch == epoch, !Task.isCancelled else { return }

        for step in 1...54 {
            do {
                guard nativeTOCEpoch == epoch, !Task.isCancelled else { return }
                let jump = try await evaluateJSON(nativeTOCJumpScript(entry: entry, reset: step == 1))
                let ok = Self.boolValue(jump["ok"])
                let clicked = Self.boolValue(jump["clicked"])
                let stage = jump["stage"] as? String ?? ""
                let jumpText = jump["text"] as? String ?? ""
                let minVisible = Self.int(from: jump["minVisible"]) ?? -1
                let maxVisible = Self.int(from: jump["maxVisible"]) ?? -1
                let scrollTop = Self.int(from: jump["scrollTop"]) ?? -1
                let next = Self.int(from: jump["next"]) ?? -1
                let containerTag = jump["containerTag"] as? String ?? ""
                let scrollTag = jump["scrollTag"] as? String ?? ""
                let href = jump["href"] as? String ?? ""
                let action = jump["action"] as? String ?? ""
                let actionPath = jump["actionPath"] as? String ?? ""
                let framework = jump["framework"] as? [String: Any] ?? [:]
                let frameworkLog = Self.longLog("\(framework)")
                KindleRunLog.write("KINDLE native toc jump step=\(step) ok=\(ok) stage=\(stage) target=\(entry.index) visible=\(minVisible)-\(maxVisible) y=\(scrollTop)->\(next) tags=\(containerTag)->\(scrollTag) text=\(Self.keyLog(jumpText)) href=\(Self.keyLog(href)) actionPath=\(Self.keyLog(actionPath)) framework=\(frameworkLog) action=\(Self.longLog(action)) epoch=\(epoch)")
                if !ok && stage == "toc-jump-clicked-no-navigation" {
                    KindleRunLog.write("KINDLE native toc jump no-navigation-stop index=\(entry.index) step=\(step) old=\(Self.keyLog(oldKey)) text=\(Self.keyLog(entry.text)) epoch=\(epoch)")
                    break
                }
                if ok {
                    let strategy = Self.int(from: framework["strategy"]) ?? Self.int(from: framework["skip"]) ?? 0
                    let navigationTimeout: UInt64
                    let requiredStableHits: Int
                    if clicked && stage.hasPrefix("toc-jump-clicked") {
                        navigationTimeout = strategy == 0 ? 1_350_000_000 : 2_700_000_000
                        requiredStableHits = strategy == 0 ? 0 : 1
                    } else {
                        navigationTimeout = 3_600_000_000
                        requiredStableHits = 2
                    }
                    let waitedKey = await waitForNavigationTargetKey(
                        oldKey: oldKey,
                        timeoutNanoseconds: navigationTimeout,
                        requiredStableHits: requiredStableHits
                    )
                    let currentKey = await currentVisibleKindlePageKey()
                    let newKey = waitedKey ?? ((entry.active || currentKey != oldKey) ? currentKey.nilIfEmpty : nil)
                    guard let newKey else {
                        if clicked && step < 8 {
                            KindleRunLog.write("KINDLE native toc jump clicked-no-navigation retry index=\(entry.index) step=\(step) stage=\(stage) old=\(Self.keyLog(oldKey)) current=\(Self.keyLog(currentKey)) text=\(Self.keyLog(entry.text))")
                            try? await Task.sleep(nanoseconds: 180_000_000)
                            continue
                        }
                        KindleRunLog.write("KINDLE native toc jump clicked-no-navigation index=\(entry.index) old=\(Self.keyLog(oldKey)) current=\(Self.keyLog(currentKey)) text=\(Self.keyLog(entry.text))")
                        isNativeTOCLoading = false
                        nativeTOCError = AppLocalized("跳转失败，请重试。")
                        _ = await closeTOCIfVisible(reason: "native-jump-no-navigation")
                        await setNativeKindleTOCHidden(false, reason: "native-jump-no-navigation")
                        await restoreViewportAfterNativeTOCBridge(reason: "native-jump-no-navigation")
                        isPageTurnResuming = false
                        return
                    }

                    lastNativeTOCSelectionText = entry.text
                    lastNativeTOCSelectionPageKey = newKey
                    nativeTOCEntries = nativeTOCEntries.map { item in
                        KindleTOCEntry(
                            index: item.index,
                            text: item.text,
                            level: item.level,
                            active: item.id == entry.id,
                            path: item.path,
                            sourcePath: item.sourcePath,
                            href: item.href,
                            role: item.role,
                            aria: item.aria,
                            actionSummary: item.actionSummary
                        )
                    }
                    saveNativeTOCEntriesToCache(nativeTOCEntries, reason: "jump-active")
                    isNativeTOCPresented = false
                    isNativeTOCLoading = false
                    isKindleTOCVisible = false
                    statusText = ""
                    KindleRunLog.write("KINDLE native toc jump navigation-ok index=\(entry.index) old=\(Self.keyLog(oldKey)) new=\(Self.keyLog(newKey)) text=\(Self.keyLog(entry.text)) resume=\(shouldResume) epoch=\(epoch)")
                    _ = await closeTOCIfVisible(reason: "native-jump-complete")
                    try? await Task.sleep(nanoseconds: 240_000_000)
                    await setNativeKindleTOCHidden(false, reason: "native-jump")
                    await restoreViewportAfterNativeTOCBridge(reason: "native-jump-complete")
                    if shouldResume {
                        pendingCaptureKey = newKey
                        scheduleManualPageTurnResume(
                            mode: resumeMode,
                            oldKey: oldKey,
                            targetKey: newKey,
                            direction: nil,
                            reason: "toc-jump"
                        )
                    } else {
                        pendingManualPageResumeMode = nil
                        isPageTurnResuming = false
                        statusText = AppLocalized("打开任意位置后，选择朗读或解读。")
                    }
                    KindleRunLog.write("KINDLE native toc jump complete keep-viewport resume=\(shouldResume) epoch=\(epoch)")
                    return
                }
            } catch {
                KindleRunLog.write("KINDLE native toc jump error step=\(step) index=\(entry.index) \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 120_000_000)
        }

        isNativeTOCLoading = false
        nativeTOCError = AppLocalized("跳转失败，请重试。")
        _ = await closeTOCIfVisible(reason: "native-jump-failed")
        await setNativeKindleTOCHidden(false, reason: "native-jump-failed")
        await restoreViewportAfterNativeTOCBridge(reason: "native-jump-failed")
        isPageTurnResuming = false
    }

    private func restoreViewportAfterNativeTOCBridge(reason: String) async {
        isNativeTOCPresented = false
        isKindleTOCVisible = false
        readerSurfaceFreezeUntil = nil
        restoreReaderViewportCrop(reason: reason)
        await setKindlePageModeLocked(true)
        let recovered = await recoverReaderLayoutForIdle(reason: reason, maxAttempts: 8)
        KindleRunLog.write("KINDLE native toc viewport restored reason=\(reason) recovered=\(recovered)")
    }

    private static func makeTOCEntries(_ entries: [[String: Any]]) -> [KindleTOCEntry] {
        return entries.enumerated().compactMap { (offset: Int, entry: [String: Any]) -> KindleTOCEntry? in
            let rawText = (entry["text"] as? String ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else { return nil }
            let index = int(from: entry["index"]) ?? offset
            let level = int(from: entry["level"]) ?? 0
            let path = entry["path"] as? String ?? ""
            let sourcePath = entry["sourcePath"] as? String ?? ""
            let href = entry["href"] as? String ?? ""
            let role = entry["role"] as? String ?? ""
            let aria = entry["aria"] as? String ?? ""
            let actionSummary = entry["actionSummary"] as? String ?? ""
            return KindleTOCEntry(
                index: index,
                text: rawText,
                level: level,
                active: boolValue(entry["active"]),
                path: path,
                sourcePath: sourcePath,
                href: href,
                role: role,
                aria: aria,
                actionSummary: actionSummary
            )
        }
    }

    @discardableResult
    private func scanNativeTOCEntries(reason: String) async -> Bool {
        var bestEntries: [[String: Any]] = []
        var lastStage = ""

        for step in 1...90 {
            do {
                let result = try await evaluateJSON(nativeTOCScanScript(reset: step == 1))
                let stage = result["stage"] as? String ?? ""
                lastStage = stage
                let done = Self.boolValue(result["done"])
                let count = Self.int(from: result["count"]) ?? ((result["entries"] as? [[String: Any]])?.count ?? 0)
                let added = Self.int(from: result["added"]) ?? 0
                let scrollTop = Self.int(from: result["scrollTop"]) ?? -1
                let maxScroll = Self.int(from: result["maxScroll"]) ?? -1
                let score = Self.int(from: result["containerScore"]) ?? -1
                let entryHint = Self.int(from: result["entryHint"]) ?? -1
                let containerTag = result["containerTag"] as? String ?? ""
                let scrollTag = result["scrollTag"] as? String ?? ""
                let activeHint = result["activeHint"] as? String ?? ""
                let entries = result["entries"] as? [[String: Any]] ?? []
                if entries.count >= bestEntries.count {
                    bestEntries = entries
                }
                let first = (entries.first?["text"] as? String) ?? ""
                let last = (entries.last?["text"] as? String) ?? ""
                KindleRunLog.write("KINDLE native toc scan reason=\(reason) pass=\(step) stage=\(stage) scrollerFound=\(!scrollTag.isEmpty) count=\(count) added=\(added) scrollTop=\(scrollTop)/\(maxScroll) score=\(score) hint=\(entryHint) activeHint=\(Self.keyLog(activeHint)) tags=\(containerTag)->\(scrollTag) first=\(Self.keyLog(first)) last=\(Self.keyLog(last))")
                if done {
                    break
                }
            } catch {
                KindleRunLog.write("KINDLE native toc scan error reason=\(reason) step=\(step) \(error.localizedDescription)")
            }
            try? await Task.sleep(nanoseconds: 90_000_000)
        }

        let currentKey = await currentVisibleKindlePageKey()
        let entries = Self.makeTOCEntries(bestEntries)
        if let nativeActiveText = entries.first(where: { $0.active })?.text {
            lastNativeTOCSelectionText = nativeActiveText
            lastNativeTOCSelectionPageKey = currentKey.nilIfEmpty
        } else {
            lastNativeTOCSelectionText = nil
            lastNativeTOCSelectionPageKey = nil
        }
        nativeTOCEntries = entries
        saveNativeTOCEntriesToCache(entries, reason: "scan-\(reason)")
        let activeTexts = entries.filter(\.active).map(\.text).prefix(4).joined(separator: " | ")
        KindleRunLog.write("KINDLE native toc scan complete reason=\(reason) entries=\(entries.count) lastStage=\(lastStage) current=\(Self.keyLog(currentKey)) source=native active=\(Self.keyLog(activeTexts)) first=\(Self.keyLog(entries.first?.text ?? "")) last=\(Self.keyLog(entries.last?.text ?? ""))")
        return !entries.isEmpty
    }

    private func setNativeKindleTOCHidden(_ hidden: Bool, reason: String) async {
        do {
            let script = hidden ? KindleWebScripts.hideNativeTOCOverlay : KindleWebScripts.showNativeTOCOverlay
            let result = try await evaluateJSON(script)
            KindleRunLog.write("KINDLE native toc hidden reason=\(reason) hidden=\(hidden) ok=\(Self.boolValue(result["ok"]))")
        } catch {
            KindleRunLog.write("KINDLE native toc hidden error reason=\(reason) hidden=\(hidden) \(error.localizedDescription)")
        }
    }

    private func setNativeKindleTOCSheetStyled(_ styled: Bool, reason: String) async {
        do {
            let script = styled ? KindleWebScripts.styleNativeTOCSheet : KindleWebScripts.clearNativeTOCSheetStyle
            let result = try await evaluateJSON(script)
            let entryCount = Self.int(from: result["entryCount"]) ?? -1
            let rootTag = result["rootTag"] as? String ?? ""
            let scrollTag = result["scrollTag"] as? String ?? ""
            let jsReason = result["reason"] as? String ?? ""
            let first = result["first"] as? String ?? ""
            KindleRunLog.write("KINDLE native toc sheet style reason=\(reason) styled=\(styled) ok=\(Self.boolValue(result["ok"])) entries=\(entryCount) root=\(rootTag) scroll=\(scrollTag) jsReason=\(jsReason) first=\(Self.keyLog(first))")
        } catch {
            KindleRunLog.write("KINDLE native toc sheet style error reason=\(reason) styled=\(styled) \(error.localizedDescription)")
        }
    }

    private func padNativeKindleTOCScrollArea(reason: String) async {
        do {
            let result = try await evaluateJSON(KindleWebScripts.padNativeTOCScrollArea)
            let count = Self.int(from: result["count"]) ?? -1
            let rootTag = result["rootTag"] as? String ?? ""
            let scrollTag = result["scrollTag"] as? String ?? ""
            let first = result["first"] as? String ?? ""
            let last = result["last"] as? String ?? ""
            let pull = result["pull"] as? [String: Any] ?? [:]
            let gap = Self.int(from: pull["gap"]) ?? -1
            let chromeCount = (result["chrome"] as? [[String: Any]])?.count ?? 0
            let topCount = (result["topFillers"] as? [[String: Any]])?.count ?? 0
            KindleRunLog.write("KINDLE native toc padding reason=\(reason) ok=\(Self.boolValue(result["ok"])) count=\(count) root=\(rootTag) scroll=\(scrollTag) top=\(topCount) chrome=\(chromeCount) gap=\(gap) first=\(Self.keyLog(first)) last=\(Self.keyLog(last))")
        } catch {
            KindleRunLog.write("KINDLE native toc padding error reason=\(reason) \(error.localizedDescription)")
        }
    }

    private func nativeTOCScanScript(reset: Bool) -> String {
        KindleWebScripts.nativeTOCScanStep
            .replacingOccurrences(of: "arguments[0]", with: reset ? "true" : "false")
    }

    private func nativeTOCJumpScript(entry: KindleTOCEntry, reset: Bool) throws -> String {
        let textJSONData = try JSONEncoder().encode(entry.text)
        let textJSON = String(data: textJSONData, encoding: .utf8) ?? "\"\""
        let pathJSONData = try JSONEncoder().encode(entry.path.isEmpty ? entry.sourcePath : entry.path)
        let pathJSON = String(data: pathJSONData, encoding: .utf8) ?? "\"\""
        let hrefJSONData = try JSONEncoder().encode(entry.href)
        let hrefJSON = String(data: hrefJSONData, encoding: .utf8) ?? "\"\""
        let cachedRows = nativeTOCEntries.map { item in
            ["index": item.index, "text": item.text] as [String: Any]
        }
        let cachedJSONData = try JSONSerialization.data(withJSONObject: cachedRows, options: [])
        let cachedJSON = String(data: cachedJSONData, encoding: .utf8) ?? "[]"
        var script = KindleWebScripts.nativeTOCJumpStep
        script = script.replacingOccurrences(of: "arguments[0]", with: "\(entry.index)")
        script = script.replacingOccurrences(of: "arguments[1]", with: textJSON)
        script = script.replacingOccurrences(of: "arguments[2]", with: pathJSON)
        script = script.replacingOccurrences(of: "arguments[3]", with: hrefJSON)
        script = script.replacingOccurrences(of: "arguments[4]", with: reset ? "true" : "false")
        script = script.replacingOccurrences(of: "arguments[5]", with: cachedJSON)
        return script
    }

    @discardableResult
    private func closeTOCIfVisible(reason: String) async -> Bool {
        do {
            let result = try await evaluateJSON(KindleWebScripts.closeTOCOverlay)
            let ok = Self.boolValue(result["ok"])
            let visibleBefore = Self.boolValue(result["visibleBefore"])
            let clicked = Self.boolValue(result["clicked"])
            let escaped = Self.boolValue(result["escaped"])
            let label = result["closeLabel"] as? String ?? ""
            let containers = result["containers"] as? [[String: Any]] ?? []
            KindleRunLog.write("KINDLE toc close reason=\(reason) ok=\(ok) clicked=\(clicked) escaped=\(escaped) visibleBefore=\(visibleBefore) label=\(Self.keyLog(label)) containers=\(containers.count)")
            #if DEBUG
            NSLog("CRDBG KINDLE toc close reason=%@ ok=%@ clicked=%@ escaped=%@ visibleBefore=%@ label=%@ containers=%@",
                  reason,
                  String(ok),
                  String(clicked),
                  String(escaped),
                  String(visibleBefore),
                  label,
                  String(describing: containers.prefix(4)))
            #endif
            if ok {
                isKindleTOCVisible = false
                statusText = ""
                await setKindlePageModeLocked(true)
                return true
            }
            if visibleBefore {
                isKindleTOCVisible = true
            }
            return false
        } catch {
            KindleRunLog.write("KINDLE toc close error reason=\(reason) \(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE toc close error reason=%@ %@", reason, error.localizedDescription)
            #endif
            return false
        }
    }

    private func runTOCProbe(reason: String) async {
        statusText = AppLocalized("正在探测 Kindle 目录…")
        isKindleTOCVisible = true
        installCaptureScript()
        await setKindlePageModeLocked(false)
        try? await Task.sleep(nanoseconds: 350_000_000)

        var lastStage = ""
        for attempt in 1...6 {
            do {
                let result = try await evaluateJSON(KindleWebScripts.tocProbe)
                let stage = result["stage"] as? String ?? ""
                lastStage = stage
                let entries = result["entries"] as? [[String: Any]] ?? []
                let containers = result["containers"] as? [[String: Any]] ?? []
                let opener = result["opener"] as? [String: Any] ?? [:]
                let openerLabel = opener["label"] as? String ?? ""
                let candidates = result["openerCandidates"] as? [[String: Any]] ?? []
                let rawCount = Self.int(from: result["rawCount"]) ?? -1
                let count = Self.int(from: result["count"]) ?? entries.count
                let entryPreview = entries.prefix(6).enumerated().map { offset, entry -> String in
                    let text = (entry["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                    return "#\(offset):\(Self.keyLog(text))"
                }.joined(separator: " | ")
                let activeEntries = result["activeEntries"] as? [[String: Any]] ?? []
                let activePreview = activeEntries.prefix(4).enumerated().map { offset, entry -> String in
                    let text = (entry["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                    return "#\(offset):\(Self.keyLog(text))"
                }.joined(separator: " | ")
                let events = result["events"] as? [[String: Any]] ?? []
                let eventPreview = events.suffix(4).enumerated().map { offset, item -> String in
                    let text = (item["text"] as? String ?? "").replacingOccurrences(of: "\n", with: " ")
                    let active = Self.boolValue(item["active"])
                    return "#\(offset):\(Self.keyLog(text)) active=\(active)"
                }.joined(separator: " | ")
                let openerPreview = candidates.prefix(4).enumerated().map { offset, item -> String in
                    let label = item["label"] as? String ?? ""
                    let score = String(describing: item["score"] ?? "?")
                    return "#\(offset)(\(score)):\(Self.keyLog(label))"
                }.joined(separator: " | ")
                KindleRunLog.write(
                    "KINDLE toc probe reason=\(reason) attempt=\(attempt) stage=\(stage) raw=\(rawCount) count=\(count) containers=\(containers.count) opener=\(Self.keyLog(openerLabel)) candidates=\(openerPreview) active=\(activePreview) events=\(eventPreview) entries=\(entryPreview)"
                )
                #if DEBUG
                NSLog("CRDBG KINDLE toc probe reason=%@ attempt=%d stage=%@ raw=%d count=%d active=%@ events=%@ entries=%@ opener=%@ candidates=%@ containers=%@",
                      reason,
                      attempt,
                      stage,
                      rawCount,
                      count,
                      String(describing: activeEntries.prefix(8).map { $0["text"] as? String ?? "" }),
                      String(describing: events.suffix(8).map { $0["text"] as? String ?? "" }),
                      String(describing: entries.prefix(12).map { $0["text"] as? String ?? "" }),
                      openerLabel,
                      String(describing: candidates.prefix(6)),
                      String(describing: containers.prefix(4)))
                #endif
                if count > 0 {
                    isKindleTOCVisible = true
                    statusText = AppLocalized("已探测到 Kindle 目录。")
                    return
                }
            } catch {
                KindleRunLog.write("KINDLE toc probe error reason=\(reason) attempt=\(attempt) \(error.localizedDescription)")
                #if DEBUG
                NSLog("CRDBG KINDLE toc probe error reason=%@ attempt=%d %@", reason, attempt, error.localizedDescription)
                #endif
            }
            try? await Task.sleep(nanoseconds: attempt == 1 ? 900_000_000 : 650_000_000)
        }
        statusText = AppLocalized("暂未探测到 Kindle 目录。")
        isKindleTOCVisible = false
        await setKindlePageModeLocked(true)
        KindleRunLog.write("KINDLE toc probe incomplete reason=\(reason) lastStage=\(lastStage)")
    }

    private func restoreReaderViewportCrop(reason: String) {
        guard readerSurfaceSize.width > 80, readerSurfaceSize.height > 80 else {
            applyViewportCropIfNeeded(.identity, reason: reason, source: "no-surface-size")
            return
        }
        let crop = Self.predictedViewportCrop(for: readerSurfaceSize)
        applyViewportCropIfNeeded(crop, reason: reason, source: "surface=\(Self.sizeLog(readerSurfaceSize))")
    }

    private func logReaderLayoutProbe(reason: String) async {
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        do {
            let result = try await evaluateJSON(KindleWebScripts.readerLayoutProbe)
            let viewport = result["viewport"] as? [String: Any] ?? [:]
            let controls = result["pageControls"] as? [[String: Any]] ?? []
            let labels = controls.compactMap { ($0["label"] as? String)?.nilIfEmpty }.prefix(4).joined(separator: " | ")
            KindleRunLog.write(
                "KINDLE layout probe reason=\(reason) viewport=\(String(describing: viewport["width"] ?? 0))x\(String(describing: viewport["height"] ?? 0)) blobs=\(String(describing: result["blobImages"] ?? 0)) fullPage=\(String(describing: result["fullPageImages"] ?? 0)) runways=\(String(describing: result["scrollRunways"] ?? 0)) columns=\(String(describing: result["columns"] ?? 0)) controls=\(controls.count) labels=\(labels) ua=\(Self.keyLog(result["ua"] as? String ?? ""))"
            )
            #if DEBUG
            NSLog("CRDBG KINDLE layout probe %@ %@", reason, String(describing: result))
            #endif
        } catch {
            KindleRunLog.write("KINDLE layout probe error reason=\(reason) \(error.localizedDescription)")
        }
    }

    private func logKindleGeometrySnapshot(reason: String) async {
        installCaptureScript()
        do {
            let result = try await evaluateJSON("window.__crKindleGeometry && window.__crKindleGeometry()")
            let viewport = result["viewport"] as? [String: Any] ?? [:]
            let visualViewport = result["visualViewport"] as? [String: Any] ?? [:]
            let candidate = result["candidate"] as? [String: Any] ?? [:]
            let rect = candidate["rect"] as? [String: Any] ?? [:]
            let natural = candidate["natural"] as? [String: Any] ?? [:]
            let scale = candidate["displayScale"] as? [String: Any] ?? [:]
            let visibleNorm = candidate["visibleNorm"] as? [String: Any] ?? [:]
            let swiftBounds = webView.bounds
            let containerBounds = webView.superview?.bounds ?? webView.bounds
            let swiftFrameInWindow = webView.superview?.convert(webView.frame, to: nil) ?? webView.convert(webView.bounds, to: nil)
            let windowBounds = webView.window?.bounds ?? .zero
            let screenScale = webView.window?.screen.scale ?? UIScreen.main.scale
            let scrollBounds = webView.scrollView.bounds
            let inset = webView.scrollView.adjustedContentInset
            let viewportWidth = Self.numberValue(viewport["width"]) ?? 0
            let viewportHeight = Self.numberValue(viewport["height"]) ?? 0
            let domToSwiftX = viewportWidth > 0 ? Double(swiftBounds.width) / viewportWidth : 0
            let domToSwiftY = viewportHeight > 0 ? Double(swiftBounds.height) / viewportHeight : 0
            let rectLeft = Self.numberValue(rect["left"]) ?? 0
            let rectTop = Self.numberValue(rect["top"]) ?? 0
            let rectWidth = Self.numberValue(rect["width"]) ?? 0
            let rectHeight = Self.numberValue(rect["height"]) ?? 0
            let swiftBlob = CGRect(
                x: rectLeft * domToSwiftX,
                y: rectTop * domToSwiftY,
                width: rectWidth * domToSwiftX,
                height: rectHeight * domToSwiftY
            )
            let swiftBlobInContainer = swiftBlob.offsetBy(dx: webView.frame.minX, dy: webView.frame.minY)
            let swiftBlobWindow = swiftBlob.offsetBy(dx: swiftFrameInWindow.minX, dy: swiftFrameInWindow.minY)
            let coverageX = containerBounds.width > 0 ? swiftBlobInContainer.width / containerBounds.width : 0
            let coverageY = containerBounds.height > 0 ? swiftBlobInContainer.height / containerBounds.height : 0
            updateViewportCropIfNeeded(
                reason: reason,
                ok: Self.boolValue(result["ok"]),
                swiftBlob: swiftBlobInContainer,
                surfaceSize: containerBounds.size,
                coverageX: coverageX,
                coverageY: coverageY
            )

            func value(_ dict: [String: Any], _ key: String, default fallback: Any = 0) -> String {
                String(describing: dict[key] ?? fallback)
            }

            func cg(_ value: CGFloat) -> String {
                String(format: "%.1f", Double(value))
            }

            KindleRunLog.write(
                "KINDLE geometry reason=\(reason) ok=\(Self.boolValue(result["ok"])) window=\(cg(windowBounds.width))x\(cg(windowBounds.height)) screenScale=\(String(format: "%.2f", screenScale)) swiftFrame=\(cg(swiftFrameInWindow.minX))|\(cg(swiftFrameInWindow.minY))|\(cg(swiftFrameInWindow.width))|\(cg(swiftFrameInWindow.height)) visibleSurface=\(cg(containerBounds.width))x\(cg(containerBounds.height)) swiftWeb=\(cg(swiftBounds.width))x\(cg(swiftBounds.height)) swiftScroll=\(cg(scrollBounds.width))x\(cg(scrollBounds.height)) inset=\(cg(inset.top)),\(cg(inset.left)),\(cg(inset.bottom)),\(cg(inset.right)) viewport=\(value(viewport, "width"))x\(value(viewport, "height")) domToSwift=\(String(format: "%.4f", domToSwiftX))|\(String(format: "%.4f", domToSwiftY)) dpr=\(value(viewport, "devicePixelRatio", default: 1)) visual=\(value(visualViewport, "width"))x\(value(visualViewport, "height"))@\(value(visualViewport, "scale", default: 1)) key=\(Self.keyLog(candidate["key"] as? String ?? "")) kind=\(value(candidate, "kind", default: "")) rect=\(value(rect, "left"))|\(value(rect, "top"))|\(value(rect, "width"))|\(value(rect, "height")) swiftBlob=\(cg(swiftBlob.minX))|\(cg(swiftBlob.minY))|\(cg(swiftBlob.width))|\(cg(swiftBlob.height)) blobVisible=\(cg(swiftBlobInContainer.minX))|\(cg(swiftBlobInContainer.minY))|\(cg(swiftBlobInContainer.width))|\(cg(swiftBlobInContainer.height)) blobWindow=\(cg(swiftBlobWindow.minX))|\(cg(swiftBlobWindow.minY))|\(cg(swiftBlobWindow.width))|\(cg(swiftBlobWindow.height)) coverage=\(String(format: "%.3f", coverageX))|\(String(format: "%.3f", coverageY)) natural=\(value(natural, "width"))x\(value(natural, "height")) scale=\(value(scale, "x"))|\(value(scale, "y")) aspectErr=\(value(candidate, "aspectError")) visibleNorm=\(value(visibleNorm, "top"))...\(value(visibleNorm, "bottom", default: 1)) chromeHidden=\(String(describing: result["hiddenChromeCount"] ?? 0))"
            )
            #if DEBUG
            NSLog("CRDBG KINDLE geometry %@ %@", reason, String(describing: result))
            #endif
        } catch {
            KindleRunLog.write("KINDLE geometry error reason=\(reason) \(error.localizedDescription)")
        }
    }

    private func updateViewportCropIfNeeded(
        reason: String,
        ok: Bool,
        swiftBlob: CGRect,
        surfaceSize: CGSize,
        coverageX: CGFloat,
        coverageY: CGFloat
    ) {
        guard !isNativeTOCPresented, !isKindleTOCVisible else {
            KindleRunLog.write("KINDLE viewport crop keep-current reason=\(reason)-native-toc")
            return
        }
        guard ok,
              surfaceSize.width > 80,
              surfaceSize.height > 80,
              swiftBlob.width > 80,
              swiftBlob.height > 80 else {
            return
        }

        KindleRunLog.write(
            "KINDLE viewport measured reason=\(reason) visibleBlob=\(Self.rectLog(swiftBlob)) surface=\(Self.sizeLog(surfaceSize)) coverage=\(String(format: "%.3f", coverageX))|\(String(format: "%.3f", coverageY)) crop=\(Self.cropLog(viewportCrop))"
        )
    }

    private func applyViewportCropIfNeeded(_ crop: KindleViewportCrop, reason: String, source: String) {
        guard abs(crop.scale - viewportCrop.scale) > 0.01 ||
              abs(crop.heightScale - viewportCrop.heightScale) > 0.01 ||
              abs(crop.offsetX - viewportCrop.offsetX) > 0.8 ||
              abs(crop.offsetY - viewportCrop.offsetY) > 0.8 else {
            return
        }

        viewportCrop = crop
        KindleRunLog.write(
            "KINDLE viewport crop reason=\(reason) \(Self.cropLog(crop)) \(source)"
        )
    }

    private static func predictedViewportCrop(for surfaceSize: CGSize) -> KindleViewportCrop {
        guard surfaceSize.width > 80, surfaceSize.height > 80 else {
            return .identity
        }

        let isLandscape = surfaceSize.width > surfaceSize.height
        // Kindle page mode lays the active page inside a fixed chrome box:
        // about 60pt above the page and 90pt below it. Size the WKWebView
        // before loading so the page blob itself matches our visible reader
        // surface, then clip those fixed Kindle chrome bands away.
        let contentWidthRatio: CGFloat = 0.80
        let topChrome: CGFloat = 60
        let bottomChrome: CGFloat = 90
        let widthScale = 1 / contentWidthRatio
        let webWidth = surfaceSize.width * widthScale
        let webHeight = surfaceSize.height + topChrome + bottomChrome
        let crop = KindleViewportCrop(
            scale: widthScale,
            heightScale: webHeight / surfaceSize.height,
            offsetX: -(webWidth - surfaceSize.width) / 2,
            offsetY: -topChrome
        )
        KindleRunLog.write(
            "KINDLE viewport layout-model orientation=\(isLandscape ? "landscape" : "portrait") surface=\(sizeLog(surfaceSize)) web=\(sizeLog(CGSize(width: webWidth, height: webHeight))) \(cropLog(crop))"
        )
        return crop
    }

    private static func isOrientationChange(from oldSize: CGSize, to newSize: CGSize) -> Bool {
        guard oldSize.width > 80,
              oldSize.height > 80,
              newSize.width > 80,
              newSize.height > 80 else { return false }
        return (oldSize.width > oldSize.height) != (newSize.width > newSize.height)
    }

    private static func viewportCrop(forBlob blob: CGRect, in surfaceSize: CGSize) -> KindleViewportCrop {
        let scaleX = surfaceSize.width / blob.width
        let scaleY = surfaceSize.height / blob.height
        let widthScale = max(1, scaleX)
        let heightScale = max(1, scaleY)
        return KindleViewportCrop(
            scale: widthScale,
            heightScale: heightScale,
            offsetX: -blob.minX * widthScale,
            offsetY: -blob.minY * heightScale
        )
    }

    private static func sizeLog(_ size: CGSize) -> String {
        "\(String(format: "%.1f", size.width))x\(String(format: "%.1f", size.height))"
    }

    private static func rectLog(_ rect: CGRect) -> String {
        "\(String(format: "%.1f", rect.minX))|\(String(format: "%.1f", rect.minY))|\(String(format: "%.1f", rect.width))|\(String(format: "%.1f", rect.height))"
    }

    private static func cropLog(_ crop: KindleViewportCrop) -> String {
        "scale=\(String(format: "%.4f", crop.scale))|\(String(format: "%.4f", crop.heightScale)) offset=\(String(format: "%.1f", crop.offsetX))|\(String(format: "%.1f", crop.offsetY))"
    }

    private func clearKindleMarkState(resetAnimationHistory: Bool) {
        shownMarkIds.removeAll()
        if resetAnimationHistory {
            animatedMarkIds.removeAll()
        }
    }

    func selectMode(_ newMode: ReaderMode, autoStart: Bool = false) {
        guard !isKindleSyncDialogVisible else {
            statusText = AppLocalized("请先确认 Kindle 阅读位置。")
            return
        }
        guard mode != newMode else {
            if autoStart {
                Task { try? await startCurrentMode() }
            }
            return
        }
        let shouldContinuePlayback = autoStart || shouldContinuePlaybackOnModeSwitch
        if shouldContinuePlayback {
            modeSwitchTask?.cancel()
            let oldMode = mode
            modeSwitchTask = Task { [weak self] in
                await self?.switchModeAndContinuePlayback(
                    from: oldMode,
                    to: newMode,
                    reason: autoStart ? "mode-switch-auto-start" : "mode-switch-active-playback"
                )
            }
            return
        }

        modeSwitchTask?.cancel()
        applyModeSelection(newMode)
    }

    private func applyModeSelection(_ newMode: ReaderMode) {
        if newMode == .read {
            isContinuingExplainPage = false
            explainVM?.deactivate()
            readVM?.activate()
            clearKindleMarkState(resetAnimationHistory: false)
            Task { _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()") }
        } else {
            readVM?.deactivate()
            explainVM?.activate()
            lastHighlightedWordByParagraph.removeAll()
            Task { _ = try? await evaluateJSON("window.__crKindleLiveClearWord && window.__crKindleLiveClearWord()") }
        }
        mode = newMode
    }

    private func switchModeAndContinuePlayback(from oldMode: ReaderMode, to newMode: ReaderMode, reason: String) async {
        let snapshot = currentPreparedPageSnapshot()
        let oldKey = livePageKey?.nilIfEmpty ?? snapshot?.page.key ?? ""
        KindleRunLog.write("KINDLE mode switch continue requested from=\(oldMode.rawValue) to=\(newMode.rawValue) reason=\(reason) key=\(Self.keyLog(oldKey)) snapshot=\(snapshot == nil ? "N" : "Y")")
        stopPlaybackForPageTurn(reason: "\(reason)-stop-\(oldMode.rawValue)-to-\(newMode.rawValue)", clearLiveOverlay: false)
        applyModeSelection(newMode)

        do {
            let prepared: KindleCachedPage
            if let snapshot {
                prepared = snapshot
            } else {
                _ = try await ensureLiveDocument(force: true)
                guard let current = currentPreparedPageSnapshot() else {
                    throw KindleBookError.captureFailed("mode-switch-no-current-page")
                }
                prepared = current
            }
            guard !Task.isCancelled else { return }

            liveDocument = prepared.document
            livePage = prepared.page
            livePageKey = prepared.page.key.nilIfEmpty ?? livePageKey
            liveStartParagraphIndex = prepared.startParagraphIndex ?? firstReadableParagraph(in: prepared.document)
            liveStartIndexKind = .sourceParagraph
            liveVisibleTopNorm = 0
            liveVisibleBottomNorm = 1
            resetViewModels(document: prepared.document)
            applyModeSelection(newMode)

            try await restartPlaybackAfterPageTurn(
                document: prepared.document,
                target: prepared,
                oldKey: oldKey,
                reason: reason
            )
            KindleRunLog.write("KINDLE mode switch continue started from=\(oldMode.rawValue) to=\(newMode.rawValue) key=\(Self.keyLog(prepared.page.key))")
        } catch is CancellationError {
            KindleRunLog.write("KINDLE mode switch continue cancelled from=\(oldMode.rawValue) to=\(newMode.rawValue) reason=\(reason)")
        } catch {
            statusText = error.localizedDescription
            KindleRunLog.write("KINDLE mode switch continue failed from=\(oldMode.rawValue) to=\(newMode.rawValue) reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    func startCurrentMode() async throws {
        guard !isKindleSyncDialogVisible else {
            statusText = AppLocalized("请先确认 Kindle 阅读位置。")
            return
        }
        if syncDialogResolutionTask != nil {
            pendingStartAfterSyncResolution = true
            statusText = AppLocalized("正在应用 Kindle 阅读位置…")
            KindleRunLog.write("KINDLE start deferred waiting-sync mode=\(mode.rawValue)")
            return
        }
        #if DEBUG
        NSLog("CRDBG KINDLE start requested mode=%@ hasRead=%@ readPara=%d preparing=%@",
              mode.rawValue,
              readVM == nil ? "N" : "Y",
              readVM?.currentParagraphIndex ?? -99,
              isPreparing ? "Y" : "N")
        #endif
        switch mode {
        case .read:
            if let vm = readVM, vm.currentParagraphIndex >= 0, !vm.isFinished {
                let audio = AudioPlayerService.shared
                let hasPlayableAudio = audio.isPlaying || audio.currentSegment != nil || audio.duration > 0
                if hasPlayableAudio {
                    vm.togglePlayPause()
                    startPageKeyWatcher()
                    return
                }
                KindleRunLog.write("KINDLE read restart stale-vm p=\(vm.currentParagraphIndex) status=\(String(describing: vm.status)) audioBook=\(Self.keyLog(audio.currentBookId ?? ""))")
            }
            guard await ensurePlaybackAccess(for: .read) else { return }
            let singlePageDoc = try await ensureLiveDocument(force: true)
            let doc = try await buildTextQueueForCurrentPage(baseDocument: singlePageDoc)
            let vm = readVM ?? makeReadVM(document: doc)
            readVM = vm
            recordPlaybackStart(language: doc.language)
            explainVM?.deactivate()
            vm.activate()
            let start = liveStartParagraphIndex ?? doc.paragraphs.first(where: { $0.type.isReadable })?.id ?? 0
            suppressNextScrollParagraphIndex = start
            #if DEBUG
            NSLog("CRDBG KINDLE read start doc=%@ paras=%d start=%d liveKey=%@",
                  String(doc.id.prefix(8)),
                  doc.paragraphs.count,
                  start,
                  Self.keyLog(livePageKey ?? ""))
            #endif
            if start > 0 {
                vm.jump(to: start)
            } else {
                vm.start()
            }
            startPageKeyWatcher()
            KindlePlaybackCenter.shared.activate(model: self)
        case .explain:
            if let vm = explainVM {
                switch vm.status {
                case .planning, .streaming:
                    vm.togglePlayPause()
                    startPageKeyWatcher()
                    return
                case .completed:
                    vm.replay()
                    startPageKeyWatcher()
                    KindlePlaybackCenter.shared.activate(model: self)
                    return
                default:
                    break
                }
            }
            guard await ensurePlaybackAccess(for: .explain) else { return }
            let singlePageDoc = try await ensureLiveDocument(force: true)
            guard let vm = explainVM else { return }
            mode = .explain
            readVM?.deactivate()
            vm.activate()
            recordPlaybackStart(language: singlePageDoc.language)
            clearKindleMarkState(resetAnimationHistory: true)
            _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()")
            if let key = livePageKey {
                startCachingNextPage(afterKey: key)
            }
            #if DEBUG
            NSLog("CRDBG KINDLE explain start doc=%@ paras=%d liveKey=%@",
                  String(singlePageDoc.id.prefix(8)),
                  singlePageDoc.paragraphs.count,
                  Self.keyLog(livePageKey ?? ""))
            #endif
            KindleRunLog.write("KINDLE explain start key=\(Self.keyLog(livePageKey ?? "")) paras=\(singlePageDoc.paragraphs.count)")
            vm.start()
            startPageKeyWatcher()
            KindlePlaybackCenter.shared.activate(model: self)
        }
    }

    private func ensurePlaybackAccess(for requestedMode: ReaderMode) async -> Bool {
        let pro = ProManager.shared
        let quota = QuotaManager.shared
        quota.rollIfNewDay()

        func hasAccess() -> Bool {
            KindlePlaybackAccessGate.canStart(
                mode: requestedMode,
                isPro: pro.isPro,
                listenRemaining: quota.listenRemaining,
                explainRemaining: quota.explainRemaining
            )
        }

        guard !hasAccess() else { return true }
        await pro.refresh()
        guard !hasAccess() else { return true }

        showPaywall = true
        playbackErrorText = nil
        KindleRunLog.write(
            "KINDLE paywall requested mode=\(requestedMode.rawValue) listenRemaining=\(Int(quota.listenRemaining)) explainRemaining=\(quota.explainRemaining)"
        )
        return false
    }

    func dismissPaywall() {
        readVM?.showPaywall = false
        explainVM?.showPaywall = false
        showPaywall = false
    }

    func turnPage(_ direction: KindlePageTurnDirection) async {
        guard !isKindleSyncDialogVisible else {
            statusText = AppLocalized("请先确认 Kindle 阅读位置。")
            KindleRunLog.write("KINDLE page turn blocked sync-dialog direction=\(direction.logName)")
            return
        }
        let resumeMode = pendingManualPageResumeMode ?? mode
        let shouldResume = shouldResumeAfterUserPageTurn
        KindleRunLog.write("KINDLE page turn requested \(direction.logName) mode=\(mode.rawValue) resume=\(shouldResume)")
        if shouldResume {
            activeManualTurnShouldResume = true
            defer { activeManualTurnShouldResume = false }
            _ = await performManualPageTurn(
                direction,
                shouldResumeAfterTurn: true,
                resumeMode: resumeMode
            )
            return
        }

        KindleRunLog.write("KINDLE page turn dispatch-only \(direction.logName) mode=\(mode.rawValue)")
        manualPageResumeTask?.cancel()
        manualPageResumeTask = nil
        pendingManualPageResumeMode = nil
        isPageTurnResuming = false
        pendingManualTurnDirection = nil
        pendingManualTurnShouldResume = false
        activeManualTurnShouldResume = false
        stopPageKeyWatcher()

        do {
            try await ensureCaptureScriptInstalled(reason: "dispatch-only-\(direction.logName)")
            let oldKey = await currentVisibleKindlePageKey()
            let target = try await requestKindlePageTurnTarget(direction, oldKey: oldKey)
            let result = target.result
            let strategy = result["strategy"] as? String ?? ""
            KindleRunLog.write("KINDLE page turn dispatch-only result \(direction.logName) old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(target.targetKey)) strategy=\(strategy) tried=\(String(describing: result["tried"] ?? result["fallbackTried"] ?? "")) reason=\(String(describing: result["reason"] ?? ""))")
        } catch {
            statusText = error.localizedDescription
            KindleRunLog.write("KINDLE page turn dispatch-only error \(direction.logName) \(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE page turn dispatch-only %@ error %@", direction.logName, error.localizedDescription)
            #endif
        }
    }

    private func performManualPageTurn(
        _ direction: KindlePageTurnDirection,
        shouldResumeAfterTurn: Bool,
        resumeMode: ReaderMode
    ) async -> Bool {
        let fallbackOldKey = livePageKey
        let reason = "manual-\(direction.logName)"
        // Stop the old page before any WebView readiness/geometry await. Audio,
        // TTS generation and continuous-page handoff must not survive a user turn.
        if shouldResumeAfterTurn {
            stopPlaybackForPageTurn(reason: reason, clearLiveOverlay: false)
            mode = resumeMode
            isPageTurnResuming = true
        }
        cancelInFlightProcessingForManualPageTurn(reason: reason)

        do {
            try await ensureCaptureScriptInstalled(reason: "manual-\(direction.logName)")
            await setKindlePageModeLocked(true)

            let visibleOldKey = await currentVisibleKindlePageKey()
            let oldKey: String
            if let visibleKey = visibleOldKey.nilIfEmpty {
                oldKey = visibleKey
            } else if let fallbackOldKey = fallbackOldKey?.nilIfEmpty {
                oldKey = fallbackOldKey
            } else {
                oldKey = await currentKindlePageKey()
            }
            manualPageResumeTask?.cancel()
            pendingCaptureKey = nil
            clearExternalMismatchState()
            if shouldResumeAfterTurn {
                _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")
                liveDocument = nil
                livePage = nil
                livePageKey = nil
                liveStartParagraphIndex = nil
                liveStartIndexKind = .sourceParagraph
                liveVisibleTopNorm = nil
                liveVisibleBottomNorm = nil
                pageBackStack.removeAll()
                pageForwardStack.removeAll()
                KindlePlaybackCenter.shared.activate(model: self)
                statusText = AppLocalized("正在切换 Kindle 页面…")
            }

            let turnTarget = try await requestKindlePageTurnTarget(direction, oldKey: oldKey)
            let turnResult = turnTarget.result
            let strategy = turnResult["strategy"] as? String ?? ""
            KindleRunLog.write("KINDLE page turn only \(direction.logName) old=\(Self.keyLog(oldKey)) visibleOld=\(Self.keyLog(visibleOldKey)) target=\(Self.keyLog(turnTarget.targetKey)) strategy=\(strategy) tried=\(String(describing: turnResult["tried"] ?? turnResult["fallbackTried"] ?? "")) resume=\(shouldResumeAfterTurn)")
            if shouldResumeAfterTurn {
                scheduleManualPageTurnResume(
                    mode: resumeMode,
                    oldKey: oldKey,
                    targetKey: turnTarget.targetKey,
                    direction: direction,
                    reason: reason
                )
            } else {
                pendingManualPageResumeMode = nil
                isPageTurnResuming = false
                statusText = AppLocalized("打开任意位置后，选择朗读或解读。")
            }
            return true
        } catch {
            pendingManualPageResumeMode = nil
            isPageTurnResuming = false
            statusText = error.localizedDescription
            KindleRunLog.write("KINDLE page turn \(direction.logName) error \(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE page turn %@ error %@", direction.logName, error.localizedDescription)
            #endif
            return false
        }
    }

    private func scheduleManualPageTurnResume(
        mode resumeMode: ReaderMode,
        oldKey: String,
        targetKey: String?,
        direction: KindlePageTurnDirection?,
        reason: String
    ) {
        let epoch = preloadEpoch
        pendingManualPageResumeMode = resumeMode
        isPageTurnResuming = true
        manualPageResumeTask?.cancel()
        statusText = AppLocalized("正在等待 Kindle 页面稳定…")
        KindleRunLog.write("KINDLE manual resume scheduled mode=\(resumeMode.rawValue) old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(targetKey ?? "")) dir=\(direction?.logName ?? "unknown") reason=\(reason) epoch=\(epoch)")
        manualPageResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 850_000_000)
            guard let self else { return }
            guard !Task.isCancelled,
                  self.preloadEpoch == epoch else {
                if self.pendingManualPageResumeMode == resumeMode {
                    self.pendingManualPageResumeMode = nil
                }
                self.isPageTurnResuming = false
                return
            }
            await self.resumePlaybackFromStableManualPage(
                mode: resumeMode,
                oldKey: oldKey,
                targetKey: targetKey,
                direction: direction,
                reason: reason,
                epoch: epoch
            )
        }
    }

    private func resumePlaybackFromStableManualPage(
        mode resumeMode: ReaderMode,
        oldKey: String,
        targetKey: String?,
        direction: KindlePageTurnDirection?,
        reason: String,
        epoch: UInt64
    ) async {
        guard preloadEpoch == epoch,
              !isAdvancingLivePage else {
            if pendingManualPageResumeMode == resumeMode {
                pendingManualPageResumeMode = nil
            }
            isPageTurnResuming = false
            manualPageResumeTask = nil
            return
        }

        var didRestartPlayback = false
        defer {
            let resumedKey = didRestartPlayback ? livePageKey?.nilIfEmpty : nil
            if pendingManualPageResumeMode == resumeMode {
                pendingManualPageResumeMode = nil
            }
            isPageTurnResuming = false
            manualPageResumeTask = nil
            if let resumedKey {
                startCachingNextPage(afterKey: resumedKey)
            }
        }

        do {
            statusText = AppLocalized("正在从当前 Kindle 页面继续…")
            try await ensureCaptureScriptInstalled(reason: "\(reason)-resume")
            guard !Task.isCancelled, preloadEpoch == epoch else { return }
            await setKindlePageModeLocked(true)
            try await waitForPageReady()
            guard !Task.isCancelled, preloadEpoch == epoch else { return }

            var prepared = try await preparedPageForManualResume(
                oldKey: oldKey,
                targetKey: targetKey,
                direction: direction,
                reason: reason
            )
            var activationOldKey = oldKey
            if direction == nil {
                for redirectAttempt in 1...3 {
                    guard let visibleKey = await manualResumeRedirectKey(
                        preparedKey: prepared.page.key,
                        reason: reason,
                        attempt: redirectAttempt
                    ) else { break }
                    activationOldKey = normalizedPageKey(prepared.page.key).nilIfEmpty ?? activationOldKey
                    prepared = try await preparedPageForManualResume(
                        oldKey: activationOldKey,
                        targetKey: visibleKey,
                        direction: nil,
                        reason: "\(reason)-redirect"
                    )
                    guard !Task.isCancelled, preloadEpoch == epoch else { return }
                }
            }
            guard !Task.isCancelled, preloadEpoch == epoch else { return }
            self.mode = resumeMode
            let singlePageDoc = try await activatePreparedNextPage(
                prepared,
                oldKey: activationOldKey,
                startOverride: prepared.startParagraphIndex,
                startKindOverride: .sourceParagraph
            )
            guard !Task.isCancelled, preloadEpoch == epoch else { return }
            try await restartPlaybackAfterPageTurn(
                document: singlePageDoc,
                target: prepared,
                oldKey: activationOldKey,
                reason: "\(reason)-resume"
            )
            didRestartPlayback = true
            KindleRunLog.write("KINDLE manual resume started mode=\(resumeMode.rawValue) old=\(Self.keyLog(activationOldKey)) new=\(Self.keyLog(prepared.page.key)) reason=\(reason) epoch=\(epoch)")
        } catch {
            pendingCaptureKey = nil
            statusText = AppLocalized("已暂停，请点击播放继续。")
            KindleRunLog.write("KINDLE manual resume failed mode=\(resumeMode.rawValue) old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(targetKey ?? "")) reason=\(reason) error=\(error.localizedDescription)")
        }
    }

    private func preparedPageForManualResume(
        oldKey rawOldKey: String,
        targetKey rawTargetKey: String?,
        direction: KindlePageTurnDirection?,
        reason: String
    ) async throws -> KindleCachedPage {
        let oldKey = normalizedPageKey(rawOldKey)
        let requestedKey = normalizedPageKey(rawTargetKey)
        let visibleKey = normalizedPageKey(await currentVisibleKindlePageKey())
        let visibleTargetKey = visibleKey.isEmpty || visibleKey == oldKey ? "" : visibleKey
        let effectiveTargetKey = visibleTargetKey.isEmpty ? requestedKey : visibleTargetKey

        if !visibleTargetKey.isEmpty,
           !requestedKey.isEmpty,
           visibleTargetKey != requestedKey {
            KindleRunLog.write("KINDLE manual resume target-shift old=\(Self.keyLog(oldKey)) requested=\(Self.keyLog(requestedKey)) visible=\(Self.keyLog(visibleTargetKey)) reason=\(reason)")
        }

        if !effectiveTargetKey.isEmpty,
           effectiveTargetKey != oldKey {
            pendingCaptureKey = effectiveTargetKey
            if direction == nil {
                KindleRunLog.write("KINDLE manual resume prepared-skip source=target-cache old=\(Self.keyLog(oldKey)) key=\(Self.keyLog(effectiveTargetKey)) dir=unknown reason=\(reason)")
            } else {
                if let prepared = preparedCandidate(forKey: effectiveTargetKey),
                   normalizedPageKey(prepared.page.key) == effectiveTargetKey,
                   canUsePreparedPageForManualResume(
                       prepared,
                       oldKey: oldKey,
                       direction: direction,
                       source: "target-cache",
                       reason: reason
                   ) {
                    KindleRunLog.write("KINDLE manual resume prepared-hit source=target-cache old=\(Self.keyLog(oldKey)) key=\(Self.keyLog(effectiveTargetKey)) after=\(Self.keyLog(prepared.afterKey)) reason=\(reason)")
                    return prepared
                }
                if let prepared = await waitForPreparedCandidate(pageKey: effectiveTargetKey, timeoutNanoseconds: 1_200_000_000),
                   canUsePreparedPageForManualResume(
                       prepared,
                       oldKey: oldKey,
                       direction: direction,
                       source: "target-wait",
                       reason: reason
                   ) {
                    KindleRunLog.write("KINDLE manual resume prepared-hit source=target-wait old=\(Self.keyLog(oldKey)) key=\(Self.keyLog(effectiveTargetKey)) after=\(Self.keyLog(prepared.afterKey)) reason=\(reason)")
                    return prepared
                }
            }
        }

        if direction == .next {
            if requestedKey.isEmpty,
               let prepared = preparedCandidate(afterKey: oldKey),
               !prepared.page.key.isEmpty,
               prepared.page.key != oldKey {
                KindleRunLog.write("KINDLE manual resume prepared-hit source=after-cache old=\(Self.keyLog(oldKey)) key=\(Self.keyLog(prepared.page.key)) reason=\(reason)")
                return prepared
            }
            if requestedKey.isEmpty,
               let prepared = await waitForCachedNextPage(afterKey: oldKey, timeoutNanoseconds: 1_200_000_000) {
                KindleRunLog.write("KINDLE manual resume prepared-hit source=after-wait old=\(Self.keyLog(oldKey)) key=\(Self.keyLog(prepared.page.key)) reason=\(reason)")
                return prepared
            }
            if effectiveTargetKey.isEmpty {
                let prepared = try await prepareManualNextPage(afterKey: oldKey)
                KindleRunLog.write("KINDLE manual resume prepared-hit source=next-snapshot old=\(Self.keyLog(oldKey)) key=\(Self.keyLog(prepared.page.key)) reason=\(reason)")
                return prepared
            }
        }

        let captureTarget = effectiveTargetKey.nilIfEmpty
        if captureTarget == nil {
            try await waitForKindleImageStable()
        }
        pendingCaptureKey = captureTarget
        KindleRunLog.write("KINDLE manual resume fallback-capture old=\(Self.keyLog(oldKey)) visible=\(Self.keyLog(visibleKey)) requested=\(Self.keyLog(requestedKey)) target=\(Self.keyLog(captureTarget ?? "")) dir=\(direction?.logName ?? "unknown") reason=\(reason)")
        let page = try await captureVisiblePage(pageIndex: 0, targetKey: captureTarget)
        let prepared = try makePreparedPage(afterKey: oldKey, page: page)
        let preparedKey = normalizedPageKey(prepared.page.key)
        guard preparedKey != oldKey || requestedKey.isEmpty else {
            throw KindleBookError.captureFailed("manual-resume-same-key:\(preparedKey)")
        }
        cachePreparedCandidate(prepared)
        return prepared
    }

    private func manualResumeRedirectKey(preparedKey rawPreparedKey: String, reason: String, attempt: Int) async -> String? {
        let preparedKey = normalizedPageKey(rawPreparedKey)
        let visibleKey = normalizedPageKey(await currentVisibleKindlePageKey())
        guard !visibleKey.isEmpty,
              !preparedKey.isEmpty,
              visibleKey != preparedKey else {
            return nil
        }
        KindleRunLog.write("KINDLE manual resume redirect visible-changed attempt=\(attempt) prepared=\(Self.keyLog(preparedKey)) visible=\(Self.keyLog(visibleKey)) reason=\(reason)")
        return visibleKey
    }

    private func canUsePreparedPageForManualResume(
        _ prepared: KindleCachedPage,
        oldKey: String,
        direction: KindlePageTurnDirection?,
        source: String,
        reason: String
    ) -> Bool {
        let preparedKey = normalizedPageKey(prepared.page.key)
        let afterKey = normalizedPageKey(prepared.afterKey)
        guard !preparedKey.isEmpty, preparedKey != oldKey else {
            KindleRunLog.write("KINDLE manual resume prepared-stale-skip source=\(source) old=\(Self.keyLog(oldKey)) key=\(Self.keyLog(preparedKey)) after=\(Self.keyLog(afterKey)) dir=\(direction?.logName ?? "unknown") session=\(prepared.page.sessionId) reason=\(reason)")
            return false
        }
        if afterKey == oldKey {
            return true
        }
        KindleRunLog.write("KINDLE manual resume prepared-stale-skip source=\(source) old=\(Self.keyLog(oldKey)) key=\(Self.keyLog(preparedKey)) after=\(Self.keyLog(afterKey)) dir=\(direction?.logName ?? "unknown") session=\(prepared.page.sessionId) reason=\(reason)")
        return false
    }

    private func currentKindlePageKey() async -> String {
        if let key = livePageKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        do {
            let state = try await evaluateJSON("window.__crKindleState && window.__crKindleState()")
            return (state["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func currentVisibleKindlePageKey() async -> String {
        do {
            let state = try await evaluateJSON("window.__crKindleState && window.__crKindleState()")
            return (state["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }

    private func lockCurrentPageForCachedPlayback(expectedKey rawKey: String) async -> (key: String, sessionId: Int)? {
        let key = normalizedPageKey(rawKey)
        guard !key.isEmpty else { return nil }
        let escapedKey = key
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        guard let result = try? await evaluateJSON(
            "window.__crKindleLockCurrentPageForPlayback && window.__crKindleLockCurrentPageForPlayback('\(escapedKey)')"
        ),
        Self.boolValue(result["ok"]),
        normalizedPageKey(result["key"] as? String) == key,
        let sessionId = Self.int(from: result["sessionId"]),
        sessionId > 0 else {
            return nil
        }
        return (key, sessionId)
    }

    private func requestKindlePageTurnTarget(_ direction: KindlePageTurnDirection, oldKey: String) async throws -> (targetKey: String, result: [String: Any]) {
        lastConfirmedTurnFingerprint = nil
        guard isReaderSurfaceAttached, webView.window != nil else {
            throw KindleBookError.captureFailed("reader-surface-not-visible")
        }
        let beforeState = try await evaluateJSON("window.__crKindleState && window.__crKindleState()")
        let beforeFingerprint = (beforeState["pixelFingerprint"] as? String)?.nilIfEmpty
        let beforeProgress = KindleTurnContract.progressNumber(beforeState["progress"] as? String)
        guard beforeFingerprint != nil else {
            throw KindleBookError.captureFailed("visible-pixel-fingerprint-unavailable")
        }

        var result = try await requestKindlePageTurn(direction)
        guard Self.boolValue(result["ok"]), Self.int(from: result["dispatchCount"]) == 1 else {
            throw KindleBookError.captureFailed(result["reason"] as? String ?? "semantic-page-action-unavailable")
        }

        var lastFingerprint: String?
        var stableSamples = 0
        var lastState: [String: Any] = beforeState
        for _ in 0..<24 {
            try await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { throw CancellationError() }
            let state = try await evaluateJSON("window.__crKindleState && window.__crKindleState()")
            lastState = state
            let fingerprint = (state["pixelFingerprint"] as? String)?.nilIfEmpty
            if fingerprint != beforeFingerprint, fingerprint == lastFingerprint {
                stableSamples += 1
            } else {
                stableSamples = fingerprint != beforeFingerprint ? 1 : 0
            }
            lastFingerprint = fingerprint
            let afterProgress = KindleTurnContract.progressNumber(state["progress"] as? String)
            let progress = KindleTurnContract.progress(
                beforeLocation: beforeProgress, afterLocation: afterProgress,
                beforeRenderer: nil, afterRenderer: nil
            )
            if KindleTurnContract.confirms(
                progress: progress,
                beforeFingerprint: beforeFingerprint,
                afterFingerprint: fingerprint,
                semanticActionDispatched: true,
                stableVisualSamples: stableSamples
            ) {
                let targetKey = (state["key"] as? String)?.nilIfEmpty ?? oldKey
                result["targetKey"] = targetKey
                result["afterFingerprint"] = fingerprint
                result["stableVisualSamples"] = stableSamples
                lastConfirmedTurnFingerprint = fingerprint
                KindleRunLog.write("KINDLE_TURN_CONFIRM progress=\(String(describing: progress)) before=\(beforeFingerprint?.prefix(18) ?? "") after=\(fingerprint?.prefix(18) ?? "") stable=\(stableSamples) accepted=Y")
                return (targetKey, result)
            }
            if progress == .backward { break }
        }
        KindleRunLog.write("KINDLE_TURN_CONFIRM before=\(beforeFingerprint?.prefix(18) ?? "") after=\((lastState["pixelFingerprint"] as? String)?.prefix(18) ?? "") stable=\(stableSamples) accepted=N")
        throw KindleBookError.captureFailed("semantic-page-turn-unconfirmed")
    }

    private func requestKindlePageTurn(_ direction: KindlePageTurnDirection) async throws -> [String: Any] {
        await setKindlePageModeLockedLightweight(true, reason: "turn-\(direction.logName)")
        let jsDirection: String
        switch direction {
        case .previous:
            jsDirection = "previous"
        case .next:
            jsDirection = "next"
        }
        let escapedDirection = jsDirection
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let progressionFallback = persistedKindleLanguageProfile()?.pageProgressionFallback.rawValue ?? "ltr"
        let script = """
        (function() {
          if (typeof window.__crKindleSemanticPageTurn !== 'function') {
            return JSON.stringify({ ok:false, reason:'semantic-page-action-unavailable', dispatchCount:0 });
          }
          return window.__crKindleSemanticPageTurn('\(escapedDirection)', '\(progressionFallback)');
        })()
        """
        return try await evaluateJSON(script)
    }

    @discardableResult
    private func alignManualPageTarget(_ rawKey: String, direction: KindlePageTurnDirection) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }

        var lastSignature = ""
        var stableHits = 0
        for attempt in 1...10 {
            guard !Task.isCancelled else { return false }
            if attempt == 1 || attempt == 4 || attempt == 7 {
                do {
                    let result = try await scrollToKey(key, block: "start")
                    KindleRunLog.write("KINDLE manual align scroll direction=\(direction.logName) attempt=\(attempt) key=\(Self.keyLog(key)) ok=\(String(describing: result["ok"] ?? false)) current=\(Self.keyLog(result["currentKey"] as? String ?? "")) rect=\(String(describing: result["rect"] ?? ""))")
                } catch {
                    KindleRunLog.write("KINDLE manual align scroll error direction=\(direction.logName) attempt=\(attempt) key=\(Self.keyLog(key)) error=\(error.localizedDescription)")
                }
            }

            try? await Task.sleep(nanoseconds: attempt == 1 ? 260_000_000 : 180_000_000)
            guard let state = try? await playbackKeyVisibility(key) else {
                continue
            }

            let currentKey = (state["visibleKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let width = Self.number(from: state["width"]) ?? 0
            let height = Self.number(from: state["height"]) ?? 0
            let top = Self.number(from: state["top"]) ?? 0
            let bottom = Self.number(from: state["bottom"]) ?? 0
            let viewportHeight = Self.number(from: state["viewportH"]) ?? 0
            let visible = Self.boolValue(state["visible"])
            let aligned = Self.boolValue(state["aligned"])
            let keyOK = currentKey.isEmpty || currentKey == key
            let geometryOK = keyOK && visible && aligned && width > 80 && height > 80
            let signature = [
                key,
                String(Int(width.rounded())),
                String(Int(height.rounded())),
                String(Int(top.rounded())),
                String(Int(bottom.rounded())),
                String(Int(viewportHeight.rounded()))
            ].joined(separator: "|")

            if geometryOK && signature == lastSignature {
                stableHits += 1
            } else {
                stableHits = geometryOK ? 1 : 0
                lastSignature = signature
            }

            KindleRunLog.write("KINDLE manual align stable-check direction=\(direction.logName) attempt=\(attempt) key=\(Self.keyLog(key)) current=\(Self.keyLog(currentKey)) keyOK=\(keyOK) visible=\(visible) aligned=\(aligned) top=\(Int(top.rounded())) bottom=\(Int(bottom.rounded())) stable=\(stableHits)")
            if stableHits >= 2 {
                return true
            }
        }
        return false
    }

    func stopAll() {
        flushListeningAnchor(reason: "stop-all")
        continueListeningTask?.cancel()
        continueListeningTask = nil
        continueListeningBaselineTask?.cancel()
        continueListeningBaselineTask = nil
        syncDialogResolutionTask?.cancel()
        syncDialogResolutionTask = nil
        pendingStartAfterSyncResolution = false
        readerLayoutRepairTask?.cancel()
        readerLayoutRepairTask = nil
        layoutPlaybackRestartTask?.cancel()
        layoutPlaybackRestartTask = nil
        modeSwitchTask?.cancel()
        modeSwitchTask = nil
        manualPageResumeTask?.cancel()
        manualPageResumeTask = nil
        pendingManualPageResumeMode = nil
        isPageTurnResuming = false
        pendingLayoutPlaybackMode = nil
        pendingLayoutPlaybackOldKey = nil
        stopPageKeyWatcher()
        navigationRestartTask?.cancel()
        navigationRestartTask = nil
        stopFollowing()
        isContinuingExplainPage = false
        cancelPageCaching(clearPrepared: true)
        clearPendingContinuation()
        invalidateReadPageSession(reason: "stop-all")
        readVM?.stop()
        explainVM?.stop()
        readVM?.deactivate()
        explainVM?.deactivate()
        playbackCancellables.removeAll()
        Task { _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()") }
    }

    func prepareDocument(pageBudget: Int) async throws -> ReadingDocument {
        guard !isPreparing else {
            throw KindleBookError.busy
        }
        isPreparing = true
        statusText = AppLocalized("正在准备 Kindle 页面…")
        defer { isPreparing = false }

        installCaptureScript()
        await setKindlePageModeLocked(true)
        try await waitForPageReady()

        var captured: [CapturedKindlePage] = []
        var seenKeys = Set<String>()
        let target = max(1, min(pageBudget, 10))

        for index in 0..<target {
            if index > 0 {
                statusText = String(format: AppLocalized("正在预加载第 %d 页…"), index + 1)
                try await scrollForward()
                try await Task.sleep(nanoseconds: 850_000_000)
            }
            statusText = String(format: AppLocalized("正在捕获第 %d 页…"), index + 1)
            let page = try await captureVisiblePage(pageIndex: index)
            guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                if captured.isEmpty { throw KindleBookError.noText }
                break
            }
            if !page.key.isEmpty, seenKeys.contains(page.key) { break }
            if !page.key.isEmpty { seenKeys.insert(page.key) }
            captured.append(page)
        }

        guard !captured.isEmpty else { throw KindleBookError.noImage }
        if let firstKey = captured.first?.key, !firstKey.isEmpty {
            _ = try? await scrollToKey(firstKey)
        }

        let doc = makeDocument(from: captured)
        pageKeysByDocumentID[doc.id] = Dictionary(uniqueKeysWithValues: captured.map { ($0.pageIndex, $0.key) })
        if let first = captured.first {
            store.updateProgress(bookID: book.id, pageKey: first.key, url: first.url, progressLabel: first.progress)
        }
        statusText = AppLocalized("已就绪。")
        return doc
    }

    private func ensureLiveDocument(force: Bool = false) async throws -> ReadingDocument {
        if !force, let liveDocument { return liveDocument }
        guard !isPreparing else { throw KindleBookError.busy }
        isPreparing = true
        statusText = AppLocalized("正在准备当前 Kindle 页面…")
        var prepareEpoch = preloadEpoch
        defer { isPreparing = false }

        if force {
            liveDocument = nil
            livePage = nil
            livePageKey = nil
            liveStartParagraphIndex = nil
            liveStartIndexKind = .sourceParagraph
            liveVisibleTopNorm = nil
            liveVisibleBottomNorm = nil
            pendingCaptureKey = nil
            suppressNextScrollParagraphIndex = nil
            textQueue = nil
            activeReadPageSlot = .current
            pageBackStack.removeAll()
            pageForwardStack.removeAll()
            refocusWordRoutes.removeAll()
            playbackAnchor = nil
            clearPendingContinuation()
            invalidatePagePreloads(clearPrepared: true, reason: "force-live-document")
            lastHighlightedWordByParagraph.removeAll()
            clearKindleMarkState(resetAnimationHistory: true)
            cancelLiveHighlightTasks()
            playbackCancellables.removeAll()
            invalidateReadPageSession(reason: "force-live-document")
            readVM?.stop()
            explainVM?.stop()
            readVM = nil
            explainVM = nil
            isContinuingExplainPage = false
            resetBlobOrderTracker()
            _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")
            prepareEpoch = preloadEpoch
        }

        installCaptureScript()
        await setKindlePageModeLocked(true)
        try await waitForPageReady()
        guard !Task.isCancelled, preloadEpoch == prepareEpoch else { throw CancellationError() }
        if force {
            // Starting playback must not move the Kindle page. Capture exactly what
            // the user is looking at, then derive the first readable paragraph from
            // that visible band. Page turns and layout recovery own explicit alignment.
            statusText = AppLocalized("正在读取当前 Kindle 页面…")
        }
        try await waitForKindleImageStable()
        guard !Task.isCancelled, preloadEpoch == prepareEpoch else { throw CancellationError() }
        if force {
            await logKindleGeometrySnapshot(reason: "pre-capture-\(mode.rawValue)")
        }
        var lastOverlayError: Error?
        for attempt in 1...3 {
            guard !Task.isCancelled, preloadEpoch == prepareEpoch else { throw CancellationError() }
            if attempt > 1 {
                statusText = AppLocalized("正在刷新当前 Kindle 页面…")
                _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")
                try await Task.sleep(nanoseconds: 220_000_000)
                try await waitForKindleImageStable()
                guard !Task.isCancelled, preloadEpoch == prepareEpoch else { throw CancellationError() }
            }
            let page = try await captureVisiblePage(pageIndex: 0, targetKey: pendingCaptureKey)
            guard !Task.isCancelled, preloadEpoch == prepareEpoch else { throw CancellationError() }
            guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw KindleBookError.noText
            }
            let doc = makeLiveDocument(from: page)
            guard hasReadableParagraphs(doc) else {
                throw KindleBookError.noText
            }
            do {
                let actualLiveKey = try await installLiveOverlay(page: page, document: doc)
                guard !Task.isCancelled, preloadEpoch == prepareEpoch else { throw CancellationError() }
                liveDocument = doc
                livePage = page
                livePageKey = actualLiveKey
                liveStartParagraphIndex = firstVisibleReadableParagraph(
                    in: doc,
                    visibleTopNorm: page.visibleTopNorm,
                    visibleBottomNorm: page.visibleBottomNorm
                ) ?? firstReadableParagraph(in: doc)
                liveStartIndexKind = .sourceParagraph
                liveVisibleTopNorm = 0
                liveVisibleBottomNorm = 1
                if pendingCaptureKey == page.key {
                    pendingCaptureKey = nil
                }
                markBlobTransition(
                    source: "live-document",
                    oldKey: nil,
                    expectedKey: page.key,
                    actualKey: actualLiveKey
                )
                #if DEBUG
                let wordCount = doc.paragraphs.reduce(0) { $0 + $1.words.count }
                let textHash = KindleListeningAnchorResolver.pageTextHash(paragraphs: doc.paragraphs)
                NSLog("CRDBG KINDLE live document key=%@ captured=%@ session=%d kind=%@ paras=%d words=%d chars=%d hash=%@ visible=%.3f..%.3f start=%d attempt=%d",
                      Self.keyLog(actualLiveKey),
                      Self.keyLog(page.key),
                      page.sessionId,
                      page.kind,
                      doc.paragraphs.count,
                      wordCount,
                      doc.fullText.count,
                      String(textHash.prefix(12)),
                      liveVisibleTopNorm ?? -1,
                      liveVisibleBottomNorm ?? -1,
                      liveStartParagraphIndex ?? -1,
                      attempt)
                #endif
                resetViewModels(document: doc)
                store.updateProgress(bookID: book.id, pageKey: page.key, url: page.url, progressLabel: page.progress)
                if mode == .read || mode == .explain {
                    startCachingNextPage(afterKey: actualLiveKey)
                }
                if force {
                    await logKindleGeometrySnapshot(reason: "post-overlay-\(mode.rawValue)")
                }
                statusText = AppLocalized("当前 Kindle 页面已就绪。")
                return doc
            } catch KindleBookError.overlayFailed(let reason) where reason == "live-candidate-not-visible" || reason == "captured-page-not-visible" {
                lastOverlayError = KindleBookError.overlayFailed(reason)
                #if DEBUG
                NSLog("CRDBG KINDLE live recapture attempt=%d key=%@ reason=%@",
                      attempt,
                      Self.keyLog(page.key),
                      reason)
                #endif
                liveDocument = nil
                livePage = nil
                livePageKey = nil
                liveStartParagraphIndex = nil
                liveStartIndexKind = .sourceParagraph
                liveVisibleTopNorm = nil
                liveVisibleBottomNorm = nil
                pendingCaptureKey = nil
                textQueue = nil
                activeReadPageSlot = .current
                continue
            }
        }
        throw lastOverlayError ?? KindleBookError.overlayFailed("live-candidate-not-visible")
    }

    private func resetLiveSession(clearPlaybackCenter: Bool = true) {
        KindleRunLog.write("KINDLE live session reset clearCenter=\(clearPlaybackCenter ? "Y" : "N")")
        readerLayoutRepairTask?.cancel()
        readerLayoutRepairTask = nil
        layoutPlaybackRestartTask?.cancel()
        layoutPlaybackRestartTask = nil
        modeSwitchTask?.cancel()
        modeSwitchTask = nil
        manualPageResumeTask?.cancel()
        manualPageResumeTask = nil
        pendingManualPageResumeMode = nil
        isPageTurnResuming = false
        pendingLayoutPlaybackMode = nil
        pendingLayoutPlaybackOldKey = nil
        stopPageKeyWatcher()
        navigationRestartTask?.cancel()
        navigationRestartTask = nil
        liveDocument = nil
        livePage = nil
        livePageKey = nil
        liveStartParagraphIndex = nil
        liveStartIndexKind = .sourceParagraph
        liveVisibleTopNorm = nil
        liveVisibleBottomNorm = nil
        pendingCaptureKey = nil
        suppressNextScrollParagraphIndex = nil
        invalidateReadPageSession(reason: "reset-live-session")
        textQueue = nil
        activeReadPageSlot = .current
        pageBackStack.removeAll()
        pageForwardStack.removeAll()
        refocusWordRoutes.removeAll()
        playbackAnchor = nil
        resetBlobOrderTracker()
        clearPendingContinuation()
        isContinuingExplainPage = false
        invalidatePagePreloads(clearPrepared: true, reason: "reset-live-session")
        lastHighlightedWordByParagraph.removeAll()
        clearKindleMarkState(resetAnimationHistory: true)
        cancelLiveHighlightTasks()
        playbackCancellables.removeAll()
        readVM?.stop()
        explainVM?.stop()
        readVM = nil
        explainVM = nil
        if clearPlaybackCenter {
            KindlePlaybackCenter.shared.clear(ifModel: self)
        }
        Task { _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()") }
    }

    private func resetViewModels(document: ReadingDocument) {
        playbackCancellables.removeAll()
        clearKindleMarkState(resetAnimationHistory: true)
        lastHighlightedWordByParagraph.removeAll()
        refocusWordRoutes.removeAll()
        playbackAnchor = nil
        cancelLiveHighlightTasks()
        readVM = makeReadVM(document: document)
        explainVM = makeExplainVM(document: document)
        showPaywall = false
        bindLivePlayback(document: document)
    }

    private func currentPreparedPageSnapshot() -> KindleCachedPage? {
        guard let page = livePage else { return nil }
        let document = makeLiveDocument(from: page)
        let start = liveStartParagraphIndex ?? firstReadableParagraph(in: document)
        return KindleCachedPage(
            afterKey: "",
            page: page,
            document: document,
            startParagraphIndex: start
        )
    }

    private func makePreparedPage(afterKey: String, page: CapturedKindlePage) throws -> KindleCachedPage {
        guard !page.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KindleBookError.captureFailed("empty-page-key")
        }
        guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw KindleBookError.noText
        }
        let document = makeLiveDocument(from: page)
        guard hasReadableParagraphs(document) else {
            throw KindleBookError.noText
        }
        return KindleCachedPage(
            afterKey: afterKey,
            page: page,
            document: document,
            startParagraphIndex: firstReadableParagraph(in: document)
        )
    }

    private func normalizedPageKey(_ key: String?) -> String {
        key?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func cachePreparedCandidate(_ prepared: KindleCachedPage) {
        let pageKey = normalizedPageKey(prepared.page.key)
        guard !pageKey.isEmpty else { return }
        cachedPageCandidates[pageKey] = prepared
        cachedNextPage = prepared
        pruneCandidateCaches()
    }

    private func preparedCandidate(forKey rawKey: String?) -> KindleCachedPage? {
        let key = normalizedPageKey(rawKey)
        guard !key.isEmpty else { return nil }
        if let prepared = cachedPageCandidates[key] {
            return prepared
        }
        if let prepared = cachedNextPage,
           normalizedPageKey(prepared.page.key) == key {
            return prepared
        }
        return nil
    }

    private func preparedCandidate(afterKey rawAfterKey: String, targetKey rawTargetKey: String? = nil) -> KindleCachedPage? {
        let afterKey = normalizedPageKey(rawAfterKey)
        let targetKey = normalizedPageKey(rawTargetKey)
        if !targetKey.isEmpty, let prepared = preparedCandidate(forKey: targetKey), prepared.afterKey == afterKey {
            return prepared
        }
        return cachedPageCandidates.values.first { prepared in
            prepared.afterKey == afterKey &&
            !normalizedPageKey(prepared.page.key).isEmpty &&
            normalizedPageKey(prepared.page.key) != afterKey
        }
    }

    private func cacheStartAudioCandidate(_ audio: KindleAudioPrefetch) {
        let key = normalizedPageKey(audio.pageKey)
        guard !key.isEmpty else { return }
        cachedStartAudio = audio
        cachedStartAudioCandidates[key] = audio
        pruneCandidateCaches()
    }

    private func startAudioCandidate(
        pageKey rawPageKey: String,
        textFingerprint: String,
        voiceID: String
    ) -> KindleAudioPrefetch? {
        let pageKey = normalizedPageKey(rawPageKey)
        guard !pageKey.isEmpty else { return nil }
        if let audio = cachedStartAudioCandidates[pageKey],
           audio.textFingerprint == textFingerprint,
           audio.voiceID == voiceID {
            return audio
        }
        if let audio = cachedStartAudio,
           normalizedPageKey(audio.pageKey) == pageKey,
           audio.textFingerprint == textFingerprint,
           audio.voiceID == voiceID {
            return audio
        }
        return nil
    }

    private func consumeStartAudioCandidate(
        pageKey rawPageKey: String,
        textFingerprint: String,
        voiceID: String
    ) -> KindleAudioPrefetch? {
        let pageKey = normalizedPageKey(rawPageKey)
        guard !pageKey.isEmpty else { return nil }
        if let audio = cachedStartAudioCandidates[pageKey] {
            if audio.textFingerprint == textFingerprint, audio.voiceID == voiceID {
                cachedStartAudioCandidates[pageKey] = nil
                if cachedStartAudio?.pageKey == audio.pageKey {
                    cachedStartAudio = nil
                }
                return audio
            }
            cachedStartAudioCandidates[pageKey] = nil
            KindleRunLog.write("KINDLE read prefetch discard key=\(Self.keyLog(pageKey)) reason=text-or-voice-mismatch cachedVoice=\(audio.voiceID) expectedVoice=\(voiceID)")
        }
        if let audio = cachedStartAudio,
           normalizedPageKey(audio.pageKey) == pageKey {
            cachedStartAudio = nil
            if audio.textFingerprint == textFingerprint, audio.voiceID == voiceID {
                return audio
            }
            KindleRunLog.write("KINDLE read prefetch discard key=\(Self.keyLog(pageKey)) reason=text-or-voice-mismatch cachedVoice=\(audio.voiceID) expectedVoice=\(voiceID)")
        }
        return nil
    }

    private func cacheExplainPrefetchCandidate(_ prefetch: KindleExplainPrefetch) {
        let key = normalizedPageKey(prefetch.pageKey)
        guard !key.isEmpty else { return }
        cachedExplainPrefetch = prefetch
        cachedExplainPrefetchCandidates[key] = prefetch
        pruneCandidateCaches()
    }

    private func consumeExplainPrefetchCandidate(afterKey rawAfterKey: String, pageKey rawPageKey: String, textFingerprint: String) -> ExplainViewModel.PrefetchedFirstBlock? {
        let afterKey = normalizedPageKey(rawAfterKey)
        let pageKey = normalizedPageKey(rawPageKey)
        guard !pageKey.isEmpty else { return nil }
        if let prefetch = cachedExplainPrefetchCandidates[pageKey] {
            if prefetch.textFingerprint == textFingerprint {
                cachedExplainPrefetchCandidates[pageKey] = nil
                if cachedExplainPrefetch?.pageKey == prefetch.pageKey {
                    cachedExplainPrefetch = nil
                }
                if prefetch.afterKey != afterKey {
                    KindleRunLog.write("KINDLE explain prefetch consume reordered key=\(Self.keyLog(pageKey)) originalAfter=\(Self.keyLog(prefetch.afterKey)) actualAfter=\(Self.keyLog(afterKey)) fingerprint=match")
                }
                return prefetch.payload
            }
            cachedExplainPrefetchCandidates[pageKey] = nil
            KindleRunLog.write("KINDLE explain prefetch discard key=\(Self.keyLog(pageKey)) reason=fingerprint-mismatch")
        }
        if let prefetch = cachedExplainPrefetch,
           normalizedPageKey(prefetch.pageKey) == pageKey {
            cachedExplainPrefetch = nil
            if prefetch.textFingerprint == textFingerprint {
                return prefetch.payload
            }
            KindleRunLog.write("KINDLE explain prefetch discard key=\(Self.keyLog(pageKey)) reason=fingerprint-mismatch")
        }
        return nil
    }

    private func clearPreparedCandidateCaches() {
        cachedNextPage = nil
        cachedPageCandidates.removeAll()
        cachedStartAudio = nil
        cachedStartAudioCandidates.removeAll()
        cachedExplainPrefetch = nil
        cachedExplainPrefetchCandidates.removeAll()
    }

    private func pruneCandidateCaches(limit: Int = 12) {
        guard cachedPageCandidates.count > limit else { return }
        let keysToKeep = Set(cachedPageCandidates.keys.suffix(limit))
        cachedPageCandidates = cachedPageCandidates.filter { keysToKeep.contains($0.key) }
        cachedStartAudioCandidates = cachedStartAudioCandidates.filter { keysToKeep.contains($0.key) }
        cachedExplainPrefetchCandidates = cachedExplainPrefetchCandidates.filter { keysToKeep.contains($0.key) }
    }

    private func prepareManualNextPage(afterKey oldKey: String) async throws -> KindleCachedPage {
        let key = oldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if let prepared = preparedCandidate(afterKey: key),
           !prepared.page.key.isEmpty,
           prepared.page.key != key {
            return prepared
        }
        if let prepared = await waitForCachedNextPage(afterKey: key, timeoutNanoseconds: 1_200_000_000) {
            return prepared
        }

          do {
              let page = try await captureNextPage(afterKey: key)
              guard page.key != key else {
                  throw KindleBookError.captureFailed("next-page-same-key")
              }
              let prepared = try makePreparedPage(afterKey: key, page: page)
              cachePreparedCandidate(prepared)
              return prepared
          } catch {
              KindleRunLog.write("KINDLE page turn next cache-miss after=\(Self.keyLog(key)) error=\(error.localizedDescription)")
              throw error
          }
      }

    private func prepareManualPreviousPage(beforeKey oldKey: String) async throws -> KindleCachedPage {
        let key = oldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty {
            _ = await restorePlaybackKeyVisibility(key, reason: "manual-previous-anchor", maxSteps: 4)
        }

          do {
              let page = try await captureNearbyPage(offset: -1)
              guard page.key != key else {
                  throw KindleBookError.captureFailed("previous-page-same-key")
              }
              return try makePreparedPage(afterKey: "", page: page)
          } catch {
              KindleRunLog.write("KINDLE page turn previous nearby-miss before=\(Self.keyLog(key)) error=\(error.localizedDescription)")
              throw error
          }
      }

    private func stopPlaybackForPageTurn(reason: String, clearLiveOverlay: Bool = true) {
        flushListeningAnchor(reason: "page-turn")
        stopPageKeyWatcher()
        manualPageResumeTask?.cancel()
        manualPageResumeTask = nil
        pendingManualPageResumeMode = nil
        isContinuingExplainPage = false
        cancelPageCaching(clearPrepared: false)
        clearPendingContinuation()
        cancelLiveHighlightTasks()
        playbackCancellables.removeAll()
        readVM?.stop()
        explainVM?.stop()
        readVM?.deactivate()
        explainVM?.deactivate()
        clearKindleMarkState(resetAnimationHistory: true)
        lastHighlightedWordByParagraph.removeAll()
        refocusWordRoutes.removeAll()
        playbackAnchor = nil
        invalidateReadPageSession(reason: "page-turn-\(reason)")
        textQueue = nil
        activeReadPageSlot = .current
        if clearLiveOverlay {
            Task { _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()") }
        }
        KindleRunLog.write("KINDLE page turn stop old-playback reason=\(reason)")
    }

    private func cancelInFlightProcessingForManualPageTurn(reason: String) {
        readerLayoutRepairTask?.cancel()
        readerLayoutRepairTask = nil
        layoutPlaybackRestartTask?.cancel()
        layoutPlaybackRestartTask = nil
        navigationRestartTask?.cancel()
        navigationRestartTask = nil
        manualPageResumeTask?.cancel()
        manualPageResumeTask = nil
        isContinuingExplainPage = false
        invalidatePagePreloads(clearPrepared: false, reason: reason)
        cancelLiveHighlightTasks()
        clearExternalMismatchState()
        // Manual page turns have priority over OCR/TTS preparation. Any older
        // preparation path is invalidated by preloadEpoch above; clearing the UI
        // flag keeps next/previous page actions responsive while old awaits unwind.
        if isPreparing {
            isPreparing = false
        }
        Task { await TTSService.shared.cancelCurrentRequest() }
        KindleRunLog.write("KINDLE page turn cancel in-flight processing reason=\(reason) epoch=\(preloadEpoch)")
    }

    private var hasActivePlaybackSession: Bool {
        switch mode {
        case .read:
            guard let vm = readVM else { return false }
            return vm.currentParagraphIndex >= 0 && !vm.isFinished
        case .explain:
            guard let vm = explainVM else { return false }
            switch vm.status {
            case .planning, .streaming:
                return true
            default:
                return vm.isPlaying
            }
        }
    }

    private var shouldResumeAfterUserPageTurn: Bool {
        if pendingManualPageResumeMode != nil || activeManualTurnShouldResume {
            return true
        }
        let audio = AudioPlayerService.shared
        if audio.currentBookId == book.id, audio.currentSegment != nil {
            // Includes a user-paused item and the continuous-page boundary where
            // the old VM can already be detached while its audio still owns the book.
            return true
        }
        return isCurrentModePlaybackActiveOrPreparing
    }

    private var shouldContinuePlaybackOnModeSwitch: Bool {
        let audio = AudioPlayerService.shared
        let audioBelongsToBook = audio.currentBookId == book.id
        switch mode {
        case .read:
            guard let vm = readVM else { return false }
            if audioBelongsToBook, audio.isPlaying || vm.isPlaying {
                return true
            }
            return vm.status.isLoading
        case .explain:
            guard let vm = explainVM else { return false }
            if audioBelongsToBook, audio.isPlaying || vm.isPlaying {
                return true
            }
            switch vm.status {
            case .planning:
                return true
            case .streaming:
                return vm.isPreparingNext
            default:
                return false
            }
        }
    }

    private var isCurrentModePlaybackActiveOrPreparing: Bool {
        let audio = AudioPlayerService.shared
        let audioBelongsToBook = audio.currentBookId == book.id
        switch mode {
        case .read:
            guard let vm = readVM else { return false }
            if audioBelongsToBook, audio.isPlaying || vm.isPlaying {
                return true
            }
            return vm.status.isLoadingOrStreaming
        case .explain:
            guard let vm = explainVM else { return false }
            if audioBelongsToBook, audio.isPlaying || vm.isPlaying {
                return true
            }
            return vm.status.isActive || vm.isPreparingNext
        }
    }

    private func startPageKeyWatcher() {
        pageKeyWatchTask?.cancel()
        pageKeyWatchTask = Task { @MainActor [weak self] in
            if let self,
               let initialState = try? await self.evaluateJSON("window.__crKindleState && window.__crKindleState()") {
                self.handledKindleNavigationSeq = Self.int(from: initialState["navigationSeq"]) ?? self.handledKindleNavigationSeq
            }
            while let self, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled,
                      self.shouldResumeAfterUserPageTurn,
                      !self.isKindleSyncDialogVisible,
                      !self.isPageTurnResuming,
                      !self.isAdvancingLivePage,
                      self.continuousReadTurnTask == nil,
                      self.continuousReadCommitTask == nil,
                      let liveKey = self.livePageKey?.nilIfEmpty else { continue }

                if self.isPlayerControlOverlayPresented {
                    self.clearExternalMismatchState()
                    continue
                }

                let state = try? await self.evaluateJSON("window.__crKindleState && window.__crKindleState()")
                let navigationSeq = Self.int(from: state?["navigationSeq"]) ?? self.handledKindleNavigationSeq
                let semanticSequenceAdvanced = navigationSeq > self.handledKindleNavigationSeq
                if semanticSequenceAdvanced {
                    self.handledKindleNavigationSeq = navigationSeq
                    let reason = state?["navigationReason"] as? String ?? "navigation"
                    let canResume = KindleExternalNavigationContract.shouldBeginResume(
                        semanticSequenceAdvanced: true,
                        hasActivePlayback: self.shouldResumeAfterUserPageTurn,
                        isReaderStable: !self.isReaderLayoutCurrentlyUnstable,
                        isInternalTurnInFlight: self.isPageTurnResuming || self.isAdvancingLivePage
                    )
                    KindleRunLog.write("KINDLE navigation intent seq=\(navigationSeq) reason=\(reason) live=\(Self.keyLog(liveKey)) accepted=\(canResume ? "Y" : "N")")
                    if canResume {
                        self.scheduleExternalPageChangeResume(
                            visibleKey: nil,
                            oldKey: liveKey,
                            reason: "kindle-navigation-\(reason)"
                        )
                    }
                    continue
                }

                let visibleKey = (state?["key"] as? String)?.nilIfEmpty
                guard let visibleKey, visibleKey != liveKey else {
                    self.clearExternalMismatchState()
                    continue
                }
                // A different visual candidate alone is not user navigation.
                // Preload capture, OCR overlays and Kindle React reconciliation
                // all produce these transient keys. Only navigationSeq above is
                // authorized to stop/restart playback.
                let changed = self.externalMismatchKey != visibleKey
                self.clearExternalMismatchState()
                self.externalMismatchKey = visibleKey
                if changed {
                    KindleRunLog.write("KINDLE visual candidate drift ignored-no-semantic visible=\(Self.keyLog(visibleKey)) live=\(Self.keyLog(liveKey))")
                }
            }
        }
    }

    private func scheduleExternalPageChangeFromCurrentVisiblePage(reason: String) async -> Bool {
        guard shouldResumeAfterUserPageTurn,
              !isPageTurnResuming,
              !isAdvancingLivePage,
              let liveKey = livePageKey?.nilIfEmpty else { return false }
        let state = try? await evaluateJSON("window.__crKindleState && window.__crKindleState()")
        guard let visibleKey = (state?["key"] as? String)?.nilIfEmpty,
              visibleKey != liveKey else {
            clearExternalMismatchState()
            return false
        }
        clearExternalMismatchState()
        KindleRunLog.write("KINDLE refocus visual drift ignored-no-semantic visible=\(Self.keyLog(visibleKey)) live=\(Self.keyLog(liveKey)) reason=\(reason)")
        return false
    }

    private func isPlaybackKeyStillVisibleAndAligned(_ key: String) async -> Bool {
        guard let state = try? await playbackKeyVisibility(key) else { return false }
        let visible = Self.boolValue(state["visible"])
        let aligned = Self.boolValue(state["aligned"])
        let width = Self.numberValue(state["width"]) ?? 0
        let height = Self.numberValue(state["height"]) ?? 0
        let usable = width > 80 && height > 80
        return usable && visible && aligned
    }

    private func stopPageKeyWatcher() {
        pageKeyWatchTask?.cancel()
        pageKeyWatchTask = nil
        clearExternalMismatchState()
    }

    private func clearExternalMismatchState() {
        externalMismatchKey = nil
    }

    private func scheduleExternalPageChangeResume(
        visibleKey: String?,
        oldKey: String,
        reason: String,
        force: Bool = false
    ) {
        guard !isPageTurnResuming else {
            KindleRunLog.write("KINDLE external page resume ignored-manual-resume reason=\(reason) visible=\(Self.keyLog(visibleKey ?? "")) live=\(Self.keyLog(oldKey))")
            return
        }
        guard force || shouldResumeAfterUserPageTurn else {
            KindleRunLog.write("KINDLE external page resume ignored-inactive reason=\(reason) visible=\(Self.keyLog(visibleKey ?? "")) live=\(Self.keyLog(oldKey))")
            return
        }

        let resumeMode = pendingManualPageResumeMode ?? mode
        let oldMode = resumeMode
        KindleRunLog.write("KINDLE external page resume schedule reason=\(reason) mode=\(resumeMode.rawValue) visible=\(Self.keyLog(visibleKey ?? "")) live=\(Self.keyLog(oldKey))")

        stopPlaybackForPageTurn(reason: reason, clearLiveOverlay: false)
        mode = oldMode
        invalidatePagePreloads(clearPrepared: false, reason: reason)
        liveDocument = nil
        livePage = nil
        livePageKey = nil
        liveStartParagraphIndex = nil
        liveStartIndexKind = .sourceParagraph
        liveVisibleTopNorm = nil
        liveVisibleBottomNorm = nil
        pageBackStack.removeAll()
        pageForwardStack.removeAll()
        bridgedNextResumeByPageKey.removeAll()
        pendingCaptureKey = visibleKey?.nilIfEmpty
        clearExternalMismatchState()
        KindlePlaybackCenter.shared.activate(model: self)

        // Do not lock to the first observed key. If the user flips several pages
        // quickly, resume from the final visible Kindle page after the debounce.
        scheduleManualPageTurnResume(
            mode: resumeMode,
            oldKey: oldKey,
            targetKey: nil,
            direction: nil,
            reason: reason
        )
    }

    private func handleKindleNavigationIntent(oldKey: String, reason: String) async {
        guard hasActivePlaybackSession, !isAdvancingLivePage else { return }
        isAdvancingLivePage = true
        defer { isAdvancingLivePage = false }

        let oldMode = mode
        stopPlaybackForPageTurn(reason: "kindle-navigation-\(reason)")
        mode = oldMode
        invalidatePagePreloads(clearPrepared: false, reason: "kindle-navigation-\(reason)")
        pageBackStack.removeAll()
        pageForwardStack.removeAll()
        pendingCaptureKey = nil
        statusText = AppLocalized("正在切换 Kindle 页面…")

        do {
            installCaptureScript()
            await setKindlePageModeLocked(true)
            guard let targetKey = await waitForNavigationTargetKey(oldKey: oldKey, timeoutNanoseconds: 20_000_000_000) else {
                KindleRunLog.write("KINDLE navigation restart timeout old=\(Self.keyLog(oldKey))")
                statusText = AppLocalized("已暂停，请选择要朗读的位置。")
                return
            }
            pendingCaptureKey = targetKey
            try await waitForKindleImageStable()
            let page = try await captureVisiblePage(pageIndex: 0, targetKey: targetKey)
            let prepared = try makePreparedPage(afterKey: "", page: page)
            cachePreparedCandidate(prepared)
            let singlePageDoc = try await activatePreparedNextPage(
                prepared,
                oldKey: oldKey,
                startOverride: prepared.startParagraphIndex,
                startKindOverride: .sourceParagraph
            )
            try await restartPlaybackAfterPageTurn(
                document: singlePageDoc,
                target: prepared,
                oldKey: oldKey,
                reason: "kindle-navigation-\(reason)"
            )
            KindleRunLog.write("KINDLE navigation restart old=\(Self.keyLog(oldKey)) new=\(Self.keyLog(prepared.page.key)) reason=\(reason)")
        } catch {
            statusText = error.localizedDescription
            KindleRunLog.write("KINDLE navigation restart error old=\(Self.keyLog(oldKey)) \(error.localizedDescription)")
        }
    }

    private func waitForNavigationTargetKey(
        oldKey: String,
        timeoutNanoseconds: UInt64,
        requiredStableHits: Int = 2
    ) async -> String? {
        var waited: UInt64 = 0
        var lastKey = ""
        var stableHits = 0

        while waited <= timeoutNanoseconds, !Task.isCancelled {
            let state = try? await evaluateJSON("window.__crKindleState && window.__crKindleState()")
            let key = (state?["key"] as? String)?.nilIfEmpty ?? ""
            if !key.isEmpty {
                if key != lastKey {
                    lastKey = key
                    stableHits = 0
                } else {
                    stableHits += 1
                }
                let changed = key != oldKey
                if changed && stableHits >= requiredStableHits {
                    KindleRunLog.write("KINDLE navigation target key=\(Self.keyLog(key)) waitedMs=\(waited / 1_000_000)")
                    return key
                }
            }

            guard waited < timeoutNanoseconds else { break }
            let step: UInt64
            if waited < 1_600_000_000 {
                step = 100_000_000
            } else if waited < 4_000_000_000 {
                step = 160_000_000
            } else {
                step = 300_000_000
            }
            let remaining = timeoutNanoseconds - waited
            let sleep = min(step, remaining)
            try? await Task.sleep(nanoseconds: sleep)
            waited += sleep
        }
        return nil
    }

    private func handleExternalKindlePageChange(visibleKey: String, oldKey: String) async {
        guard hasActivePlaybackSession, !isAdvancingLivePage else { return }
        isAdvancingLivePage = true
        defer { isAdvancingLivePage = false }

        do {
            installCaptureScript()
            await setKindlePageModeLocked(true)
            pendingCaptureKey = visibleKey
            try await waitForKindleImageStable()
            let page = try await captureVisiblePage(pageIndex: 0, targetKey: visibleKey)
            let prepared = try makePreparedPage(afterKey: "", page: page)
            cachePreparedCandidate(prepared)
            let oldMode = mode
            stopPlaybackForPageTurn(reason: "external-page-change", clearLiveOverlay: false)
            mode = oldMode
            invalidatePagePreloads(clearPrepared: false, reason: "external-page-change")
            pageBackStack.removeAll()
            pageForwardStack.removeAll()
            pendingCaptureKey = visibleKey
            let singlePageDoc = try await activatePreparedNextPage(
                prepared,
                oldKey: oldKey,
                startOverride: prepared.startParagraphIndex,
                startKindOverride: .sourceParagraph
            )
            try await restartPlaybackAfterPageTurn(
                document: singlePageDoc,
                target: prepared,
                oldKey: oldKey,
                reason: "external-page-change"
            )
            KindleRunLog.write("KINDLE external page restart old=\(Self.keyLog(oldKey)) new=\(Self.keyLog(prepared.page.key))")
        } catch {
            pendingCaptureKey = nil
            statusText = error.localizedDescription
            KindleRunLog.write("KINDLE external page restart error-kept-playing visible=\(Self.keyLog(visibleKey)) live=\(Self.keyLog(oldKey)) \(error.localizedDescription)")
        }
    }

    private func restartPlaybackFromCurrentVisiblePageAfterLayout(reason: String, preferredKey: String?) async {
        guard let pendingMode = pendingLayoutPlaybackMode,
              !isPreparing,
              !isAdvancingLivePage else { return }
        let layoutReason = "layout-\(reason)"
        let oldKey = pendingLayoutPlaybackOldKey ?? livePageKey?.nilIfEmpty ?? preferredKey?.nilIfEmpty ?? ""
        let oldMode = pendingMode
        isAdvancingLivePage = true
        defer { isAdvancingLivePage = false }

        do {
            installCaptureScript()
            await setKindlePageModeLocked(true)
            try await waitForPageReady()
            try await waitForKindleImageStable()

            pendingCaptureKey = preferredKey?.nilIfEmpty
            if let preferred = pendingCaptureKey {
                _ = await restorePlaybackKeyVisibility(preferred, reason: "\(layoutReason)-target", maxSteps: 6)
                try await waitForKindleImageStable()
            }
            let page = try await captureVisiblePage(pageIndex: 0, targetKey: preferredKey?.nilIfEmpty)
            let prepared = try makePreparedPage(afterKey: "", page: page)
            cachePreparedCandidate(prepared)

            if hasActivePlaybackSession {
                stopPlaybackForPageTurn(reason: layoutReason, clearLiveOverlay: false)
            }
            mode = oldMode
            pendingCaptureKey = page.key

            let singlePageDoc = try await activatePreparedNextPage(
                prepared,
                oldKey: oldKey,
                startOverride: prepared.startParagraphIndex,
                startKindOverride: .sourceParagraph
            )
            try await restartPlaybackAfterPageTurn(
                document: singlePageDoc,
                target: prepared,
                oldKey: oldKey,
                reason: layoutReason
            )
            readerLayoutUnstableUntil = nil
            pendingLayoutPlaybackMode = nil
            pendingLayoutPlaybackOldKey = nil
            clearExternalMismatchState()
            KindleRunLog.write("KINDLE layout playback restart old=\(Self.keyLog(oldKey)) new=\(Self.keyLog(prepared.page.key)) reason=\(reason)")
        } catch {
            pendingCaptureKey = nil
            pendingLayoutPlaybackMode = nil
            pendingLayoutPlaybackOldKey = nil
            KindleRunLog.write("KINDLE layout playback restart error old=\(Self.keyLog(oldKey)) reason=\(reason) \(error.localizedDescription)")
        }
    }

    private func restartPlaybackAfterPageTurn(
        document: ReadingDocument,
        target: KindleCachedPage,
        oldKey: String,
        reason: String
    ) async throws {
        switch mode {
        case .read:
            let queuedDocument = try await buildTextQueueForCurrentPage(baseDocument: document)
            let start = liveStartParagraphIndex
                ?? queuedDocument.paragraphs.first(where: { $0.type.isReadable })?.id
                ?? 0
            let fingerprint = Self.explainFingerprint(document)
            let startAudio = consumeStartAudioCandidate(
                pageKey: target.page.key,
                textFingerprint: fingerprint,
                voiceID: AppSettings.shared.voice(for: document.language)
            )
            let hasPrefetchedStart = startAudio?.paragraphIndex == start && !(startAudio?.segments.isEmpty ?? true)
            let prefetchedSegmentCount = hasPrefetchedStart ? (startAudio?.segments.count ?? 0) : 0
            KindleRunLog.write("KINDLE read restart after-turn begin reason=\(reason) key=\(Self.keyLog(target.page.key)) start=\(start) prefetched=\(hasPrefetchedStart ? "Y" : "N") segs=\(prefetchedSegmentCount)")
            await prepareVisualSurfaceForPlayback(reason: reason)
            let started = startReadPlayback(
                document: queuedDocument,
                startHint: start,
                prefetchedIndex: startAudio?.paragraphIndex,
                prefetchedSegments: startAudio?.segments ?? [],
                reason: reason
            )
            guard started else {
                throw KindleBookError.captureFailed("read-restart-not-started")
            }
            KindleRunLog.write("KINDLE read restart after-turn started reason=\(reason) key=\(Self.keyLog(target.page.key)) start=\(start)")
        case .explain:
            let fingerprint = Self.explainFingerprint(document)
            let usablePrefetch = consumeExplainPrefetchCandidate(
                afterKey: oldKey,
                pageKey: target.page.key,
                textFingerprint: fingerprint
            )
            KindleRunLog.write("KINDLE explain restart after-turn begin reason=\(reason) key=\(Self.keyLog(target.page.key)) prefetched=\(usablePrefetch == nil ? "N" : "Y")")
            startExplainPlayback(document: document, reason: reason, prefetched: usablePrefetch)
            KindleRunLog.write("KINDLE explain restart after-turn started reason=\(reason) key=\(Self.keyLog(target.page.key))")
        }
    }

    private func makeReadVM(document: ReadingDocument) -> ReadAloudViewModel {
        trackAnalyticsContentReadyIfNeeded(document)
        readPageSessionGeneration &+= 1
        let session = KindleReadPageSession(
            generation: readPageSessionGeneration,
            documentID: document.id
        )
        activeReadPageSession = session
        consumedReadPageGeneration = nil
        let vm = ReadAloudViewModel(document: document, analyticsContext: analyticsContext)
        vm.configurePlaybackMetadata(id: book.id, title: book.title, coverURL: book.coverURL)
        bindReadPageFinished(vm, session: session)
        KindleRunLog.write(
            "KINDLE read session installed generation=\(session.generation) " +
            "document=\(session.documentID.prefix(8)) key=\(Self.keyLog(livePageKey ?? ""))"
        )
        return vm
    }

    private func bindReadPageFinished(_ vm: ReadAloudViewModel, session: KindleReadPageSession) {
        vm.onDocumentFinished = { [weak self, weak vm] in
            guard let self, let vm else { return }
            Task { @MainActor [weak self, weak vm] in
                guard let self, let vm else { return }
                await self.handleReadPageFinished(
                    source: "vm-callback",
                    session: session,
                    owner: vm
                )
            }
        }
    }

    private func invalidateReadPageSession(reason: String) {
        if let activeReadPageSession {
            KindleRunLog.write(
                "KINDLE read session invalidated reason=\(reason) " +
                "generation=\(activeReadPageSession.generation) " +
                "document=\(activeReadPageSession.documentID.prefix(8))"
            )
        }
        activeReadPageSession = nil
        consumedReadPageGeneration = nil
    }

    private func makeExplainVM(document: ReadingDocument) -> ExplainViewModel {
        trackAnalyticsContentReadyIfNeeded(document)
        let vm = ExplainViewModel(document: document, analyticsContext: analyticsContext)
        vm.scenario = ExplainContentType.book.rawValue
        vm.configurePlaybackMetadata(
            id: book.id,
            title: book.title,
            coverURL: book.coverURL,
            chapterTitle: AppLocalized("解读")
        )
        return vm
    }

    private func trackAnalyticsContentReadyIfNeeded(_ document: ReadingDocument) {
        guard !analyticsContentReadyTracked else { return }
        analyticsContentReadyTracked = true
        ProductAnalytics.shared.contentReady(analyticsContext, document: document)
    }

    private func recordPlaybackStart(language: String) {
        store.markOpened(book)
        HistoryStore.shared.recordKindleBook(book, language: language)
    }

    func refocusPlaybackPosition(reason: String) async {
        guard readVM != nil || explainVM != nil else { return }
        guard shouldRunPlaybackRefocus else { return }
        guard !isPageTurnResuming else {
            KindleRunLog.write("KINDLE refocus skipped-manual-resume reason=\(reason) key=\(Self.keyLog(livePageKey ?? ""))")
            return
        }
        guard !isRefocusingPlayback else { return }
        // Foreground/expand recovery is anchored to what audio is currently
        // speaking. Treating the stale visible page as a manual page change here
        // would rewind playback after a long background session.
        if reason != "foreground", reason != "expand", reason != "highlight-recovery",
           await scheduleExternalPageChangeFromCurrentVisiblePage(reason: reason) {
            return
        }
        if Self.refocusHandledByLayoutRestart(reason) {
            KindleRunLog.write("KINDLE refocus skipped-layout-restart reason=\(reason) key=\(Self.keyLog(livePageKey ?? ""))")
            return
        }
        if isReaderLayoutCurrentlyUnstable, Self.refocusShouldWaitForStableLayout(reason) {
            KindleRunLog.write("KINDLE refocus skipped-layout-unstable reason=\(reason) key=\(Self.keyLog(livePageKey ?? ""))")
            return
        }
        isRefocusingPlayback = true
        defer { isRefocusingPlayback = false }

        let target = currentRefocusTarget()
        let targetPageKey = target?.pageKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let canUseCurrentOverlay = targetPageKey.isEmpty || targetPageKey == (livePageKey ?? "")
        let requiresFreshProjection = Self.refocusNeedsFreshProjection(reason)
        if !requiresFreshProjection,
           reason != "route-miss",
           canUseCurrentOverlay,
           await refreshLiveOverlay(reason: reason, attempt: 1) {
            await refocusPlaybackPositionOnce(reason: reason, attempt: 1)
            needsForegroundVisualResync = false
            return
        }

        for attempt in 1...2 {
            guard !Task.isCancelled else { return }
            guard shouldRunPlaybackRefocus else { return }
            await refreshRenderSurfaceForCurrentPlayback(reason: reason, attempt: attempt)
            guard shouldRunPlaybackRefocus else { return }
            await refocusPlaybackPositionOnce(reason: reason, attempt: attempt + 1)
            if attempt < 2 {
                try? await Task.sleep(nanoseconds: 320_000_000)
            }
        }
    }

    func cancelPlaybackRefocusEffects(reason: String) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.evaluateJSON("window.__crKindleCancelScrollAnimations && window.__crKindleCancelScrollAnimations()")
                KindleRunLog.write("KINDLE refocus cancel-effects reason=\(reason) cancelled=\(String(describing: result["cancelled"] ?? 0))")
            } catch {
                KindleRunLog.write("KINDLE refocus cancel-effects error reason=\(reason) \(error.localizedDescription)")
            }
        }
    }

    private static func refocusNeedsFreshProjection(_ reason: String) -> Bool {
        switch reason {
        case "orientation", "reader-size", "surfaceSize", "foreground", "expand", "highlight-recovery":
            return true
        default:
            return false
        }
    }

    private static func refocusRequiresExactPageKey(_ reason: String) -> Bool {
        true
    }

    private static func refocusShouldWaitForStableLayout(_ reason: String) -> Bool {
        switch reason {
        case "orientation", "reader-size", "surfaceSize", "highlight-miss", "route-miss", "highlight-recovery":
            return true
        default:
            return false
        }
    }

    private static func refocusHandledByLayoutRestart(_ reason: String) -> Bool {
        switch reason {
        case "orientation", "reader-size", "surfaceSize":
            return true
        default:
            return false
        }
    }

    private static func restoreShouldUseAnchor(reason: String) -> Bool {
        let normalized = reason.lowercased()
        return !normalized.contains("orientation") &&
            !normalized.contains("reader-size") &&
            !normalized.contains("surfacesize")
    }

    @discardableResult
    private func refreshLiveOverlay(reason: String, attempt: Int) async -> Bool {
        do {
            let result = try await evaluateJSON("window.__crKindleLiveRefresh && window.__crKindleLiveRefresh()")
            let ok = result["ok"] as? Bool == true
            #if DEBUG
            NSLog("CRDBG KINDLE refocus overlay-refresh reason=%@ attempt=%d ok=%@ key=%@ result=%@",
                  reason,
                  attempt,
                  String(describing: result["ok"] ?? false),
                  Self.keyLog(result["key"] as? String ?? livePageKey ?? ""),
                  String(describing: result))
            #endif
            KindleRunLog.write("KINDLE refocus overlay-refresh reason=\(reason) attempt=\(attempt) ok=\(String(describing: result["ok"] ?? false)) key=\(Self.keyLog(result["key"] as? String ?? livePageKey ?? ""))")
            return ok
        } catch {
            KindleRunLog.write("KINDLE refocus overlay-refresh error reason=\(reason) attempt=\(attempt) \(error.localizedDescription)")
            return false
        }
    }

    private func prepareVisualSurfaceForPlayback(reason: String) async {
        guard let key = livePageKey?.nilIfEmpty else { return }
        let refreshed = await refreshLiveOverlay(reason: "preplay-\(reason)", attempt: 1)
        KindleRunLog.write("KINDLE preplay visual reason=\(reason) key=\(Self.keyLog(key)) restored=skipped refreshed=\(refreshed)")
    }

    private func refreshRenderSurfaceForCurrentPlayback(reason: String, attempt: Int) async {
        guard !isPreparing, !isPageTurnResuming, shouldRunPlaybackRefocus, let target = currentRefocusTarget() else { return }
        do {
            try await scrollTowardRefocusTarget(target)
            guard shouldRunPlaybackRefocus else { return }
            try await Task.sleep(nanoseconds: attempt == 1 ? 260_000_000 : 120_000_000)
            guard shouldRunPlaybackRefocus else { return }
            installCaptureScript()
            await setKindlePageModeLocked(true)
            try await waitForPageReady()
            try await waitForKindleImageStable()
            guard shouldRunPlaybackRefocus else { return }
            guard let match = try await findRefocusMatch(for: target, reason: reason, attempt: attempt) else {
                #if DEBUG
                NSLog("CRDBG KINDLE refocus refresh miss reason=%@ attempt=%d targetP=%d targetW=%@",
                      reason,
                      attempt,
                      target.paragraphIndex,
                      target.wordIndex.map(String.init) ?? "nil")
                #endif
                KindleRunLog.write("KINDLE refocus refresh miss reason=\(reason) attempt=\(attempt) p=\(target.paragraphIndex) w=\(target.wordIndex.map(String.init) ?? "nil")")
                return
            }

            let previousKey = livePageKey
            if Self.refocusRequiresExactPageKey(reason),
               let expectedKey = target.pageKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               !expectedKey.isEmpty,
               match.page.key != expectedKey {
                KindleRunLog.write("KINDLE refocus match reject-key reason=\(reason) expected=\(Self.keyLog(expectedKey)) actual=\(Self.keyLog(match.page.key))")
                return
            }
            let actualKey = try await installLiveOverlay(page: match.page, document: match.projection.document)
            if Self.refocusRequiresExactPageKey(reason),
               let expectedKey = target.pageKey?.trimmingCharacters(in: .whitespacesAndNewlines),
               !expectedKey.isEmpty,
               actualKey != expectedKey {
                KindleRunLog.write("KINDLE refocus install reject-key reason=\(reason) expected=\(Self.keyLog(expectedKey)) actual=\(Self.keyLog(actualKey))")
                return
            }
            if Self.refocusRequiresExactPageKey(reason),
               !(await waitForPlaybackKeyStable(actualKey, reason: "post-refocus-\(reason)", phase: "installed")) {
                KindleRunLog.write("KINDLE refocus install reject-unstable reason=\(reason) key=\(Self.keyLog(actualKey))")
                return
            }
            livePage = match.page
            livePageKey = actualKey
            liveVisibleTopNorm = match.page.visibleTopNorm
            liveVisibleBottomNorm = match.page.visibleBottomNorm
            refocusWordRoutes = match.projection.wordRoutes
            lastHighlightedWordByParagraph.removeAll()
            clearKindleMarkState(resetAnimationHistory: false)
            store.updateProgress(bookID: book.id, pageKey: match.page.key, url: match.page.url, progressLabel: match.page.progress)
            if !isAdvancingLivePage {
                startCachingNextPage(afterKey: actualKey)
            }
            markBlobTransition(
                source: "refocus-\(reason)",
                oldKey: previousKey,
                expectedKey: target.pageKey ?? match.page.key,
                actualKey: actualKey
            )
            #if DEBUG
            NSLog("CRDBG KINDLE refocus refresh hit reason=%@ attempt=%d offset=%d key=%@ actual=%@ targetP=%d targetW=%@ paras=%d routes=%d matchedWords=%d",
                  reason,
                  attempt,
                  match.offset,
                  Self.keyLog(match.page.key),
                  Self.keyLog(actualKey),
                  target.paragraphIndex,
                  target.wordIndex.map(String.init) ?? "nil",
                  match.projection.document.paragraphs.count,
                  match.projection.wordRoutes.count,
                  match.projection.matchedWordCount)
            #endif
            KindleRunLog.write("KINDLE refocus refresh hit reason=\(reason) attempt=\(attempt) offset=\(match.offset) key=\(Self.keyLog(actualKey)) p=\(target.paragraphIndex) w=\(target.wordIndex.map(String.init) ?? "nil") paras=\(match.projection.document.paragraphs.count) routes=\(match.projection.wordRoutes.count)")
            needsForegroundVisualResync = false
        } catch {
            KindleRunLog.write("KINDLE refocus refresh error reason=\(reason) attempt=\(attempt) \(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE refocus refresh error reason=%@ attempt=%d %@",
                  reason,
                  attempt,
                  error.localizedDescription)
            #endif
        }
    }

    private func findRefocusMatch(
        for target: KindleRefocusTarget,
        reason: String,
        attempt: Int
    ) async throws -> KindleRefocusCandidateMatch? {
        guard shouldRunPlaybackRefocus else { return nil }
        var seenKeys = Set<String>()
        if let direct = try await scanRefocusCandidates(
            offsets: [0, 1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6],
            target: target,
            reason: reason,
            attempt: attempt,
            phase: "loaded",
            seenKeys: &seenKeys
        ) {
            return direct
        }

        KindleRunLog.write("KINDLE refocus search-skip reason=\(reason) attempt=\(attempt) targetKey=\(Self.keyLog(target.pageKey ?? ""))")
        return nil
    }

    private func scanRefocusCandidates(
        offsets: [Int],
        target: KindleRefocusTarget,
        reason: String,
        attempt: Int,
        phase: String,
        seenKeys: inout Set<String>
    ) async throws -> KindleRefocusCandidateMatch? {
        for offset in offsets {
            guard !Task.isCancelled else { return nil }
            guard shouldRunPlaybackRefocus else { return nil }
            do {
                let page = try await captureNearbyPage(offset: offset)
                let expectedKey = target.pageKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if Self.refocusRequiresExactPageKey(reason),
                   !expectedKey.isEmpty,
                   page.key != expectedKey {
                    KindleRunLog.write("KINDLE refocus scan key-mismatch reason=\(reason) phase=\(phase) attempt=\(attempt) offset=\(offset) expected=\(Self.keyLog(expectedKey)) actual=\(Self.keyLog(page.key))")
                    continue
                }
                if Self.refocusRequiresExactPageKey(reason),
                   page.visibleBottomNorm - page.visibleTopNorm < 0.08 {
                    KindleRunLog.write("KINDLE refocus scan not-visible reason=\(reason) phase=\(phase) attempt=\(attempt) offset=\(offset) key=\(Self.keyLog(page.key)) visible=\(String(format: "%.3f", Double(page.visibleTopNorm)))..\(String(format: "%.3f", Double(page.visibleBottomNorm)))")
                    continue
                }
                if !page.key.isEmpty, !seenKeys.insert(page.key).inserted {
                    continue
                }
                let capturedDocument = makeLiveDocument(from: page)
                guard let projection = projectCapturedDocumentForRefocus(
                    capturedDocument,
                    playbackDocument: target.document,
                    centerParagraphIndex: target.paragraphIndex,
                    centerWordIndex: target.wordIndex,
                    centerCharRange: target.charRange
                ) else {
                    #if DEBUG
                    let capturedHash = KindleListeningAnchorResolver.pageTextHash(paragraphs: capturedDocument.paragraphs)
                    NSLog("CRDBG KINDLE refocus scan miss reason=%@ phase=%@ attempt=%d offset=%d key=%@ targetP=%d targetW=%@ paras=%d chars=%d hash=%@",
                          reason,
                          phase,
                          attempt,
                          offset,
                          Self.keyLog(page.key),
                          target.paragraphIndex,
                          target.wordIndex.map(String.init) ?? "nil",
                          capturedDocument.paragraphs.count,
                          capturedDocument.fullText.count,
                          String(capturedHash.prefix(12)))
                    #endif
                    continue
                }
                return KindleRefocusCandidateMatch(
                    offset: offset,
                    page: page,
                    projection: projection
                )
            } catch {
                #if DEBUG
                NSLog("CRDBG KINDLE refocus scan error reason=%@ phase=%@ attempt=%d offset=%d %@",
                      reason,
                      phase,
                      attempt,
                      offset,
                      error.localizedDescription)
                #endif
                continue
            }
        }
        return nil
    }

    private func currentRefocusTarget() -> KindleRefocusTarget? {
        switch mode {
        case .read:
            guard let vm = readVM,
                  vm.currentParagraphIndex >= 0,
                  !vm.isFinished else { return nil }
            if let anchor = playbackAnchor,
               anchor.mode == .read,
               anchor.documentID == vm.document.id,
               anchor.paragraphIndex == vm.currentParagraphIndex {
                return KindleRefocusTarget(
                    document: vm.document,
                    paragraphIndex: anchor.paragraphIndex,
                    wordIndex: anchor.wordIndex,
                    charRange: anchor.charRange,
                    pageKey: anchor.pageKey
                )
            }
            return KindleRefocusTarget(
                document: vm.document,
                paragraphIndex: vm.currentParagraphIndex,
                wordIndex: vm.photoHighlightWordIndex,
                charRange: nil,
                pageKey: playbackPageKey(document: vm.document, paragraphIndex: vm.currentParagraphIndex, wordIndex: vm.photoHighlightWordIndex)
            )
        case .explain:
            guard let vm = explainVM else { return nil }
            if let anchor = playbackAnchor,
               anchor.mode == .explain,
               anchor.documentID == vm.document.id,
               anchor.paragraphIndex >= 0 {
                return KindleRefocusTarget(
                    document: vm.document,
                    paragraphIndex: anchor.paragraphIndex,
                    wordIndex: anchor.wordIndex,
                    charRange: anchor.charRange,
                    pageKey: anchor.pageKey
                )
            }
            let paragraphIndex = vm.activeMarks.last?.paragraphIndex ?? vm.scrollTarget
            guard paragraphIndex >= 0 else { return nil }
            return KindleRefocusTarget(
                document: vm.document,
                paragraphIndex: paragraphIndex,
                wordIndex: nil,
                charRange: nil,
                pageKey: playbackPageKey(document: vm.document, paragraphIndex: paragraphIndex, wordIndex: nil)
            )
        }
    }

    private func recordPlaybackAnchor(
        mode: ReaderMode,
        document: ReadingDocument,
        paragraphIndex: Int,
        wordIndex: Int?,
        charRange: Range<Int>?
    ) {
        guard paragraphIndex >= 0 else { return }
        let previous = playbackAnchor
        let canReusePrevious =
            previous?.mode == mode &&
            previous?.documentID == document.id &&
            previous?.paragraphIndex == paragraphIndex
        let pageKey = playbackPageKey(document: document, paragraphIndex: paragraphIndex, wordIndex: wordIndex)
        playbackAnchor = KindlePlaybackAnchor(
            mode: mode,
            documentID: document.id,
            paragraphIndex: paragraphIndex,
            wordIndex: wordIndex ?? (canReusePrevious ? previous?.wordIndex : nil),
            charRange: charRange ?? (canReusePrevious ? previous?.charRange : nil),
            pageKey: pageKey ?? (canReusePrevious ? previous?.pageKey : nil),
            updatedAt: Date()
        )
        if mode == .read {
            updatePersistentListeningAnchor(
                document: document,
                paragraphIndex: paragraphIndex,
                wordIndex: wordIndex ?? (canReusePrevious ? previous?.wordIndex : nil),
                charRange: charRange ?? (canReusePrevious ? previous?.charRange : nil),
                pageKey: pageKey ?? (canReusePrevious ? previous?.pageKey : nil)
            )
        }
    }

    private func updatePersistentListeningAnchor(
        document: ReadingDocument,
        paragraphIndex: Int,
        wordIndex: Int?,
        charRange _: Range<Int>?,
        pageKey rawPageKey: String?
    ) {
        guard let pageKey = rawPageKey?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pageKey.isEmpty,
              let page = livePage,
              page.key == pageKey || livePageKey == pageKey else { return }

        let route = wordIndex.flatMap { textQueue?.wordRoutes["\(paragraphIndex)#\($0)"] }
            ?? textQueue.flatMap { Self.firstRenderRoute(in: $0.wordRoutes, paragraphIndex: paragraphIndex) }
        guard let route else { return }

        let pageHash: String
        let baseDocument = makeLiveDocument(from: page)
        if let cached = pageTextHashByKey[pageKey] {
            pageHash = cached
        } else {
            pageHash = KindleListeningAnchorResolver.pageTextHash(paragraphs: baseDocument.paragraphs)
            pageTextHashByKey[pageKey] = pageHash
        }
        guard let sourceParagraph = baseDocument.paragraphs.first(where: { $0.id == route.sourceParagraphID }) else {
            return
        }
        let charOffset = KindleListeningAnchorResolver.charOffset(
            in: sourceParagraph,
            wordIndex: route.sourceWordIndex
        )
        let phrase = KindleListeningAnchorResolver.anchorPhrase(in: sourceParagraph.text, charOffset: charOffset)
        guard !phrase.phrase.isEmpty else { return }
        let settings = AppSettings.shared
        let anchor = KindleListeningAnchor(
            bookId: book.id,
            pageKey: pageKey,
            pageTextHash: pageHash,
            paragraphIndex: route.sourceParagraphID,
            wordIndex: route.sourceWordIndex,
            charOffset: charOffset,
            anchorPhrase: phrase.phrase,
            anchorWordOffset: phrase.anchorWordOffset,
            voice: settings.voice(for: document.language),
            speed: settings.speed,
            updatedAt: Date(),
            schemaVersion: KindleListeningAnchor.currentSchemaVersion,
            readerImplementationVersion: KindleListeningAnchor.currentReaderImplementationVersion
        )
        enqueuePersistentListeningAnchor(anchor)
    }

    private func playbackPosition(
        forSourceParagraph sourceParagraph: Int,
        sourceWordIndex: Int?
    ) -> (paragraphIndex: Int, wordIndex: Int)? {
        guard let routes = textQueue?.wordRoutes else { return nil }
        var candidates: [(paragraphIndex: Int, wordIndex: Int, sourceWordIndex: Int)] = []
        for (key, route) in routes where route.sourceParagraphID == sourceParagraph {
            let components = key.split(separator: "#", maxSplits: 1).compactMap { Int($0) }
            guard components.count == 2 else { continue }
            let candidate = (
                paragraphIndex: components[0],
                wordIndex: components[1],
                sourceWordIndex: route.sourceWordIndex
            )
            if let sourceWordIndex, route.sourceWordIndex == sourceWordIndex {
                return (candidate.paragraphIndex, candidate.wordIndex)
            }
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else { return nil }
        let target = sourceWordIndex ?? candidates.map(\.sourceWordIndex).min() ?? 0
        let nearest = candidates.min {
            let lhsDistance = abs($0.sourceWordIndex - target)
            let rhsDistance = abs($1.sourceWordIndex - target)
            if lhsDistance == rhsDistance {
                if $0.paragraphIndex == $1.paragraphIndex { return $0.wordIndex < $1.wordIndex }
                return $0.paragraphIndex < $1.paragraphIndex
            }
            return lhsDistance < rhsDistance
        }
        guard let nearest else { return nil }
        return (nearest.paragraphIndex, nearest.wordIndex)
    }

    private func enqueuePersistentListeningAnchor(_ anchor: KindleListeningAnchor) {
        pendingPersistentAnchor = anchor
        let interval: TimeInterval = 1.0
        let elapsed = lastListeningAnchorPersistedAt.map { Date().timeIntervalSince($0) } ?? interval
        if elapsed >= interval {
            pendingPersistentAnchor = nil
            persistListeningAnchor(anchor, reason: "coalesced-immediate")
            return
        }
        guard listeningAnchorPersistTask == nil else { return }
        let delay = max(0.05, interval - elapsed)
        listeningAnchorPersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.listeningAnchorPersistTask = nil
            guard let latest = self.pendingPersistentAnchor else { return }
            self.pendingPersistentAnchor = nil
            self.persistListeningAnchor(latest, reason: "coalesced-timer")
        }
    }

    private func persistListeningAnchor(_ anchor: KindleListeningAnchor, reason: String) {
        store.saveListeningAnchor(anchor)
        lastListeningAnchorPersistedAt = Date()
        KindleRunLog.write("KINDLE audiobook anchor saved reason=\(reason) book=\(Self.keyLog(anchor.bookId)) key=\(Self.keyLog(anchor.pageKey)) hash=\(anchor.pageTextHash.prefix(12)) p=\(anchor.paragraphIndex) w=\(anchor.wordIndex ?? -1) offset=\(anchor.charOffset) schema=\(anchor.schemaVersion) reader=\(anchor.readerImplementationVersion)")
    }

    private func scrollTowardRefocusTarget(_ target: KindleRefocusTarget) async throws {
        if await scheduleExternalPageChangeFromCurrentVisiblePage(reason: "scroll-\(target.paragraphIndex)") {
            throw CancellationError()
        }
        if let pageKey = target.pageKey?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pageKey.isEmpty {
            if !(await restorePlaybackKeyVisibility(pageKey, reason: "refocus-target", maxSteps: 4)) {
                _ = try? await scrollToKey(pageKey, block: "nearest")
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
        if let wordIndex = target.wordIndex,
           let route = textQueue?.wordRoutes["\(target.paragraphIndex)#\(wordIndex)"] {
            await switchRenderPageIfNeeded(to: route.slot)
            return
        }
        if let route = renderRoute(forParagraph: target.paragraphIndex, charRange: nil) {
            await switchRenderPageIfNeeded(to: route.slot)
            return
        }
        if let key = livePageKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            _ = try? await scrollToKey(key, block: "nearest")
        }
    }

    private func playbackPageKey(document: ReadingDocument, paragraphIndex: Int, wordIndex: Int?) -> String? {
        if let wordIndex,
           let route = textQueue?.wordRoutes["\(paragraphIndex)#\(wordIndex)"] {
            return pageKey(for: route.slot)
        }
        if let route = renderRoute(forParagraph: paragraphIndex, charRange: nil) {
            return pageKey(for: route.slot)
        }
        if document.id == liveDocument?.id || document.id == readVM?.document.id || document.id == explainVM?.document.id {
            return livePageKey
        }
        return nil
    }

    private func pageKey(for slot: KindleReadPageSlot) -> String? {
        guard let queue = textQueue else { return livePageKey }
        switch slot {
        case .current:
            return queue.currentPage.key.nilIfEmpty ?? livePageKey
        case .next:
            return queue.nextPage?.key.nilIfEmpty
        }
    }

    private func refocusPlaybackPositionOnce(reason: String, attempt: Int) async {
        guard shouldRunPlaybackRefocus else { return }
        switch mode {
        case .read:
            guard let vm = readVM,
                  vm.currentParagraphIndex >= 0,
                  !vm.isFinished else { return }
            let paragraphIndex = vm.currentParagraphIndex
            let wordIndex = vm.photoHighlightWordIndex
            #if DEBUG
            NSLog("CRDBG KINDLE refocus read reason=%@ attempt=%d key=%@ p=%d w=%@",
                  reason,
                  attempt,
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex,
                  wordIndex.map(String.init) ?? "nil")
            #endif
            KindleRunLog.write("KINDLE refocus read reason=\(reason) attempt=\(attempt) key=\(Self.keyLog(livePageKey ?? "")) p=\(paragraphIndex) w=\(wordIndex.map(String.init) ?? "nil")")
            await scrollToParagraph(paragraphIndex, force: true)
            if let wordIndex {
            await highlightWord(
                paragraphIndex: paragraphIndex,
                wordIndex: wordIndex,
                force: true,
                sequence: nextVisualSyncSequence()
            )
            }
        case .explain:
            guard let vm = explainVM else { return }
            let target = vm.activeMarks.last?.paragraphIndex ?? vm.scrollTarget
            guard target >= 0 else { return }
            #if DEBUG
            NSLog("CRDBG KINDLE refocus explain reason=%@ attempt=%d key=%@ target=%d marks=%d",
                  reason,
                  attempt,
                  Self.keyLog(livePageKey ?? ""),
                  target,
                  vm.activeMarks.count)
            #endif
            KindleRunLog.write("KINDLE refocus explain reason=\(reason) attempt=\(attempt) key=\(Self.keyLog(livePageKey ?? "")) target=\(target) marks=\(vm.activeMarks.count)")
            if !vm.activeMarks.isEmpty {
                await pushMarks(vm.activeMarks, force: true)
            }
            await scrollToParagraph(target, force: true)
        }
    }

    private func projectCapturedDocumentForRefocus(
        _ capturedDocument: ReadingDocument,
        playbackDocument: ReadingDocument,
        centerParagraphIndex: Int,
        centerWordIndex: Int?,
        centerCharRange: Range<Int>?
    ) -> KindleRefocusProjection? {
        let capturedWords = flattenCapturedWords(capturedDocument)
        guard !capturedWords.isEmpty else { return nil }
        let resolvedCenterWordIndex: Int? = {
            if let centerWordIndex { return centerWordIndex }
            guard let centerParagraph = playbackDocument.paragraphs.first(where: { $0.id == centerParagraphIndex }) else { return nil }
            return routedWordIndex(in: centerParagraph, charRange: centerCharRange)
        }()

        var projectedParagraphs: [ReadingParagraph] = []
        var routes: [String: KindleRenderRoute] = [:]
        var matchedWordCount = 0
        let candidateParagraphs = refocusCandidateParagraphs(
            in: playbackDocument,
            around: centerParagraphIndex
        )

        for oldParagraph in candidateParagraphs {
            guard !oldParagraph.words.isEmpty else { continue }
            let preferred = oldParagraph.id == centerParagraphIndex ? resolvedCenterWordIndex : nil
            guard let match = matchPlaybackParagraph(
                oldParagraph,
                capturedWords: capturedWords,
                preferredWordIndex: preferred
            ), !match.wordPairs.isEmpty else {
                continue
            }

            var projectedWords: [OCRWord] = []
            for pair in match.wordPairs.sorted(by: { $0.oldWordIndex < $1.oldWordIndex }) {
                let oldWord = oldParagraph.words[pair.oldWordIndex]
                let captured = capturedWords[pair.capturedWordIndex]
                let overlayWordIndex = projectedWords.count
                projectedWords.append(OCRWord(
                    id: overlayWordIndex,
                    text: oldWord.text,
                    bboxNorm: captured.bboxNorm
                ))
                routes["\(oldParagraph.id)#\(pair.oldWordIndex)"] = KindleRenderRoute(
                    slot: .current,
                    overlayParagraphID: oldParagraph.id,
                    overlayWordIndex: overlayWordIndex,
                    sourceParagraphID: oldParagraph.id,
                    sourceWordIndex: pair.oldWordIndex
                )
            }

            guard !projectedWords.isEmpty else { continue }
            matchedWordCount += projectedWords.count
            projectedParagraphs.append(ReadingParagraph(
                id: oldParagraph.id,
                text: oldParagraph.text,
                type: oldParagraph.type,
                words: projectedWords,
                bboxNorm: unionNorm(for: projectedWords),
                pageIndex: 0
            ))
        }

        if let centerWordIndex = resolvedCenterWordIndex {
            guard routes["\(centerParagraphIndex)#\(centerWordIndex)"] != nil else { return nil }
        } else {
            guard projectedParagraphs.contains(where: { $0.id == centerParagraphIndex }) else { return nil }
        }

        let document = ReadingDocument(
            title: playbackDocument.title,
            sourceKind: .kindle,
            language: playbackDocument.language,
            paragraphs: projectedParagraphs.sorted { $0.id < $1.id },
            sourceURL: playbackDocument.sourceURL
        )
        return KindleRefocusProjection(
            document: document,
            wordRoutes: routes,
            matchedWordCount: matchedWordCount
        )
    }

    private func refocusCandidateParagraphs(
        in document: ReadingDocument,
        around centerParagraphIndex: Int
    ) -> [ReadingParagraph] {
        let readable = document.paragraphs.filter(Self.isReadableKindleParagraph)
        guard !readable.isEmpty else { return [] }
        let nearby = readable
            .filter { abs($0.id - centerParagraphIndex) <= 10 }
            .sorted { abs($0.id - centerParagraphIndex) < abs($1.id - centerParagraphIndex) }
        if !nearby.isEmpty { return nearby }
        return readable.sorted { abs($0.id - centerParagraphIndex) < abs($1.id - centerParagraphIndex) }.prefix(12).map { $0 }
    }

    private func flattenCapturedWords(_ document: ReadingDocument) -> [KindleCapturedWord] {
        var words: [KindleCapturedWord] = []
        for paragraph in document.paragraphs.sorted(by: { $0.id < $1.id }) where paragraph.type.isReadable {
            for (index, word) in paragraph.words.enumerated() {
                let token = Self.refocusToken(word.text)
                guard !token.isEmpty else { continue }
                words.append(KindleCapturedWord(
                    token: token,
                    text: word.text,
                    bboxNorm: word.bboxNorm,
                    paragraphIndex: paragraph.id,
                    wordIndex: index
                ))
            }
        }
        return words
    }

    private func matchPlaybackParagraph(
        _ paragraph: ReadingParagraph,
        capturedWords: [KindleCapturedWord],
        preferredWordIndex: Int?
    ) -> KindleParagraphRefocusMatch? {
        let oldTokens = paragraph.words.map { Self.refocusToken($0.text) }
        let nonEmptyOldIndices = oldTokens.indices.filter { !oldTokens[$0].isEmpty }
        guard !nonEmptyOldIndices.isEmpty else { return nil }

        let anchorOldIndices: [Int] = {
            if let preferredWordIndex {
                let lower = max(0, preferredWordIndex - 10)
                let upper = min(oldTokens.count, preferredWordIndex + 18)
                let slice = Array(lower..<upper).filter { !oldTokens[$0].isEmpty }
                if slice.count >= 3 { return slice }
            }
            return Array(nonEmptyOldIndices.prefix(28))
        }()
        guard !anchorOldIndices.isEmpty else { return nil }

        let anchorStart = anchorOldIndices.first ?? 0
        var bestStart = 0
        var bestScore = 0
        var bestExact = 0
        for newStart in capturedWords.indices {
            var score = 0
            var exact = 0
            for oldIndex in anchorOldIndices {
                let newIndex = newStart + (oldIndex - anchorStart)
                guard newIndex >= 0, newIndex < capturedWords.count else { continue }
                let oldToken = oldTokens[oldIndex]
                let newToken = capturedWords[newIndex].token
                if oldToken == newToken {
                    exact += 1
                    score += oldToken.count >= 5 ? 4 : 3
                } else if Self.refocusTokensSimilar(oldToken, newToken) {
                    score += 1
                }
            }
            if score > bestScore {
                bestScore = score
                bestStart = newStart
                bestExact = exact
            }
        }

        let requiredExact = preferredWordIndex == nil ? 4 : 5
        let requiredScore = preferredWordIndex == nil ? 14 : 18
        guard bestExact >= requiredExact && bestScore >= requiredScore else { return nil }

        var pairs: [KindleRefocusWordPair] = []
        var usedCaptured = Set<Int>()
        let offset = bestStart - anchorStart
        for oldIndex in nonEmptyOldIndices {
            let newIndex = oldIndex + offset
            guard newIndex >= 0, newIndex < capturedWords.count else { continue }
            let oldToken = oldTokens[oldIndex]
            let newToken = capturedWords[newIndex].token
            guard oldToken == newToken || Self.refocusTokensSimilar(oldToken, newToken) else { continue }
            guard usedCaptured.insert(newIndex).inserted else { continue }
            pairs.append(KindleRefocusWordPair(oldWordIndex: oldIndex, capturedWordIndex: newIndex))
        }

        if let preferredWordIndex {
            guard pairs.contains(where: { $0.oldWordIndex == preferredWordIndex }) else { return nil }
        }

        guard !pairs.isEmpty else { return nil }
        return KindleParagraphRefocusMatch(wordPairs: pairs)
    }

    private func buildTextQueueForCurrentPage(baseDocument: ReadingDocument, includeNextPageFully: Bool = false) async throws -> ReadingDocument {
        guard (mode == .read || includeNextPageFully), let currentPage = livePage else {
            textQueue = nil
            activeReadPageSlot = .current
            return baseDocument
        }

        let currentKey = (livePageKey ?? currentPage.key).trimmingCharacters(in: .whitespacesAndNewlines)
        clearPendingContinuation()
        bridgedNextResumeByPageKey.removeAll()

        let window = buildTextQueue(
            currentPage: currentPage,
            currentDocument: baseDocument,
            nextPrepared: nil,
            includeNextPageFully: includeNextPageFully
        )
        textQueue = window
        activeReadPageSlot = .current
        liveDocument = window.document
        liveStartParagraphIndex = window.startParagraphIndex
        liveStartIndexKind = .playbackChunk
        resetViewModels(document: window.document)
        let previousKey = livePageKey
        let actualKey = try await installLiveOverlay(page: currentPage, document: window.currentOverlayDocument)
        livePageKey = actualKey
        markBlobTransition(
            source: "read-window-current",
            oldKey: previousKey,
            expectedKey: currentPage.key,
            actualKey: actualKey
        )
        if !actualKey.isEmpty {
            startCachingNextPage(afterKey: actualKey)
        } else if !currentKey.isEmpty {
            startCachingNextPage(afterKey: currentKey)
        }
        #if DEBUG
        NSLog("CRDBG KINDLE read window ready current=%@ paras=%d start=%d bridge=N",
              Self.keyLog(actualKey),
              window.document.paragraphs.count,
              window.startParagraphIndex ?? -1)
        #endif
        return window.document
    }

    private func waitForCachedNextPage(afterKey: String, timeoutNanoseconds: UInt64) async -> KindleCachedPage? {
        let step: UInt64 = 100_000_000
        var waited: UInt64 = 0
        while waited < timeoutNanoseconds {
            if let prepared = preparedCandidate(afterKey: afterKey),
               !prepared.page.key.isEmpty,
               prepared.page.key != afterKey {
                KindleRunLog.write("KINDLE read window waited-next after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(prepared.page.key)) waitedMs=\(waited / 1_000_000)")
                return prepared
            }
            guard cachingNextPageAfterKey == afterKey else { break }
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
        return nil
    }

    private func waitForPreparedCandidate(pageKey: String, timeoutNanoseconds: UInt64) async -> KindleCachedPage? {
        let key = normalizedPageKey(pageKey)
        guard !key.isEmpty else { return nil }
        let step: UInt64 = 100_000_000
        var waited: UInt64 = 0
        while waited < timeoutNanoseconds, !Task.isCancelled {
            if let prepared = preparedCandidate(forKey: key),
               normalizedPageKey(prepared.page.key) == key {
                KindleRunLog.write("KINDLE page cache waited-key key=\(Self.keyLog(key)) after=\(Self.keyLog(prepared.afterKey)) waitedMs=\(waited / 1_000_000)")
                return prepared
            }
            guard pageCacheTask != nil || cachingNextPageAfterKey != nil else { break }
            try? await Task.sleep(nanoseconds: step)
            waited += step
        }
        return nil
    }

    private func buildTextQueue(
        currentPage: CapturedKindlePage,
        currentDocument: ReadingDocument,
        nextPrepared: KindleCachedPage?,
        includeNextPageFully: Bool = false
    ) -> KindleTextQueue {
        let currentParas = currentDocument.paragraphs.filter(Self.isReadableKindleParagraph)
        let nextPrepared: KindleCachedPage? = nil
        let currentChunks = currentParas.flatMap { playbackChunks(for: $0, slot: .current) }

        var logical: [ReadingParagraph] = []
        var currentOverlay: [ReadingParagraph] = []
        var routes: [String: KindleRenderRoute] = [:]
        var firstChunkBySource: [String: Int] = [:]
        var nextWordID = 0

        func remap(_ words: [OCRWord]) -> [OCRWord] {
            words.map { word in
                defer { nextWordID += 1 }
                return OCRWord(id: nextWordID, text: word.text, bboxNorm: word.bboxNorm)
            }
        }

        func routeKey(paragraphID: Int, wordIndex: Int) -> String { "\(paragraphID)#\(wordIndex)" }
        func sourceKey(slot: KindleReadPageSlot, sourceID: Int) -> String { "\(slot.logName)#\(sourceID)" }

        func appendChunk(_ chunk: KindlePlaybackChunk) {
            let paragraphID = logical.count
            let type = chunk.parts.first?.source.type ?? .paragraph
            let pageIndex = 0
            var logicalWords: [OCRWord] = []
            var currentWords: [OCRWord] = []

            for part in chunk.parts {
                let lower = max(0, min(part.source.words.count, part.wordRange.lowerBound))
                let upper = max(lower, min(part.source.words.count, part.wordRange.upperBound))
                guard lower < upper else { continue }
                let mapped = remap(Array(part.source.words[lower..<upper]))
                let logicalStart = logicalWords.count
                logicalWords.append(contentsOf: mapped)

                let overlayStart = currentWords.count
                currentWords.append(contentsOf: mapped)
                for offset in mapped.indices {
                    routes[routeKey(paragraphID: paragraphID, wordIndex: logicalStart + offset)] = KindleRenderRoute(
                        slot: .current,
                        overlayParagraphID: paragraphID,
                        overlayWordIndex: overlayStart + offset,
                        sourceParagraphID: part.source.id,
                        sourceWordIndex: lower + offset
                    )
                }
            }

            guard !logicalWords.isEmpty else { return }
            for part in chunk.parts where firstChunkBySource[sourceKey(slot: part.slot, sourceID: part.source.id)] == nil {
                firstChunkBySource[sourceKey(slot: part.slot, sourceID: part.source.id)] = paragraphID
            }
            logical.append(ReadingParagraph(
                id: paragraphID,
                text: chunk.text,
                type: type,
                words: logicalWords,
                bboxNorm: unionNorm(for: logicalWords),
                pageIndex: pageIndex
            ))
            if !currentWords.isEmpty {
                currentOverlay.append(ReadingParagraph(
                    id: paragraphID,
                    text: chunk.text,
                    type: type,
                    words: currentWords,
                    bboxNorm: unionNorm(for: currentWords),
                    pageIndex: 0
                ))
            }
        }

        for idx in currentChunks.indices {
            appendChunk(currentChunks[idx])
        }

        let start = liveStartParagraphIndex.flatMap { idx in
            switch liveStartIndexKind {
            case .playbackChunk:
                return logical.indices.contains(idx) ? idx : nil
            case .sourceParagraph:
                return firstChunkBySource[sourceKey(slot: .current, sourceID: idx)]
                    ?? firstChunkBySource[sourceKey(slot: .next, sourceID: idx)]
                    ?? (logical.indices.contains(idx) ? idx : nil)
            }
        } ?? logical.first(where: { $0.type.isReadable })?.id

        let language = currentDocument.language
        let document = ReadingDocument(
            title: currentDocument.title,
            sourceKind: .kindle,
            language: language,
            paragraphs: logical,
            sourceURL: currentDocument.sourceURL
        )
        let currentOverlayDocument = ReadingDocument(
            title: currentDocument.title,
            sourceKind: .kindle,
            language: language,
            paragraphs: currentOverlay,
            sourceURL: currentDocument.sourceURL
        )
        let nextOverlayDocument = nextPrepared.map { prepared in
            ReadingDocument(
                title: prepared.document.title,
                sourceKind: .kindle,
                language: prepared.document.language,
                paragraphs: [],
                sourceURL: prepared.document.sourceURL
            )
        }
        let nextResumeParagraphIndex: Int? = nil

        if let nextKey = nextPrepared?.page.key.nilIfEmpty {
            bridgedNextResumeByPageKey.removeValue(forKey: nextKey)
            KindleRunLog.write("KINDLE read queue page-only current=\(Self.keyLog(currentPage.key)) next=\(Self.keyLog(nextKey)) currentChunks=\(currentChunks.count)")
        } else {
            KindleRunLog.write("KINDLE read queue page-only current=\(Self.keyLog(currentPage.key)) currentChunks=\(currentChunks.count)")
        }

        return KindleTextQueue(
            document: document,
            currentPage: currentPage,
            currentOverlayDocument: currentOverlayDocument,
            nextPage: nextPrepared?.page,
            nextBaseDocument: nextPrepared?.document,
            nextOverlayDocument: nextOverlayDocument,
            nextResumeParagraphIndex: nextResumeParagraphIndex,
            wordRoutes: routes,
            startParagraphIndex: start,
            hasCrossPageBridge: false
        )
    }

    private func playbackChunks(for paragraph: ReadingParagraph, slot: KindleReadPageSlot) -> [KindlePlaybackChunk] {
        splitKindleParagraph(paragraph).map { range in
            KindlePlaybackChunk(
                text: range.text,
                parts: [
                    KindlePlaybackChunkPart(
                        source: paragraph,
                        slot: slot,
                        wordRange: range.wordRange
                    )
                ]
            )
        }
    }

    private func splitKindleParagraph(_ paragraph: ReadingParagraph) -> [KindlePlaybackChunkRange] {
        let text = paragraph.text
        let chars = Array(text)
        let wordRanges = kindleWordCharRanges(for: paragraph)
        guard !chars.isEmpty, !paragraph.words.isEmpty else { return [] }
        guard !wordRanges.isEmpty else {
            let normalized = Self.normalizeKindleText(text)
            guard SpeechTextSanitizer.containsSpeakableContent(normalized) else { return [] }
            return [
                KindlePlaybackChunkRange(
                    text: normalized,
                    wordRange: paragraph.words.startIndex..<paragraph.words.endIndex
                )
            ]
        }

        let minChars = 80
        let maxChars = 240
        var charRanges: [Range<Int>] = []
        var start = 0
        var lastSoftBreak: Int?
        var i = 0

        while i < chars.count {
            let ch = chars[i]
            if Self.isKindleChunkTerminator(ch) {
                let end = Self.kindleChunkEndIncludingClosers(from: i, in: chars)
                if end - start >= minChars {
                    charRanges.append(start..<end)
                    start = end
                    lastSoftBreak = nil
                    i = end
                    continue
                }
                lastSoftBreak = end
            } else if Self.isKindleChunkSoftBreak(ch), i + 1 - start >= minChars {
                lastSoftBreak = i + 1
            }

            if i + 1 - start >= maxChars {
                let end = max(start + 1, lastSoftBreak ?? (i + 1))
                charRanges.append(start..<end)
                start = end
                lastSoftBreak = nil
                i = end
                continue
            }
            i += 1
        }

        if start < chars.count {
            charRanges.append(start..<chars.count)
        }

        var chunks: [KindlePlaybackChunkRange] = []
        for charRange in charRanges {
            let hits = wordRanges.filter { $0.end > charRange.lowerBound && $0.start < charRange.upperBound }
            guard let first = hits.first, let last = hits.last else { continue }
            let wordRange = first.wordIndex..<(last.wordIndex + 1)
            let chunkText = String(chars[charRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = Self.normalizeKindleText(chunkText)
            guard SpeechTextSanitizer.containsSpeakableContent(normalized),
                  wordRange.lowerBound < wordRange.upperBound else { continue }
            chunks.append(KindlePlaybackChunkRange(text: normalized, wordRange: wordRange))
        }

        if chunks.isEmpty {
            let normalized = Self.normalizeKindleText(text)
            guard SpeechTextSanitizer.containsSpeakableContent(normalized) else { return [] }
            return [
                KindlePlaybackChunkRange(
                    text: normalized,
                    wordRange: paragraph.words.startIndex..<paragraph.words.endIndex
                )
            ]
        }
        return chunks
    }

    private func kindleWordCharRanges(for paragraph: ReadingParagraph) -> [KindleWordCharRange] {
        let text = paragraph.text
        guard !text.isEmpty else { return [] }
        var ranges: [KindleWordCharRange] = []
        var cursor = text.startIndex
        let stripSet = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)

        for (wordIndex, word) in paragraph.words.enumerated() {
            let raw = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let searchRange = cursor..<text.endIndex
            var found = text.range(of: raw, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            if found == nil {
                let stripped = raw.trimmingCharacters(in: stripSet)
                if stripped.count >= 1, stripped != raw {
                    found = text.range(of: stripped, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                }
            }
            guard let found else { continue }
            let start = text.distance(from: text.startIndex, to: found.lowerBound)
            let end = text.distance(from: text.startIndex, to: found.upperBound)
            ranges.append(KindleWordCharRange(wordIndex: wordIndex, start: start, end: end))
            cursor = found.upperBound
        }
        return ranges
    }

    private func hasReadableParagraphs(_ document: ReadingDocument) -> Bool {
        document.paragraphs.contains {
            $0.type.isReadable && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private func bindLivePlayback(document: ReadingDocument) {
        guard let readVM, let explainVM else { return }

        readVM.$showPaywall
            .combineLatest(explainVM.$showPaywall)
            .map { $0 || $1 }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] shouldShow in
                guard shouldShow else { return }
                self?.showPaywall = true
            }
            .store(in: &playbackCancellables)

        // The range is authoritative for OCR-rendered content. Listening only to
        // the lower-bound word index loses Japanese/Chinese sentence updates when
        // consecutive segments share the same anchor during streaming/refocus.
        readVM.$photoHighlightWordRange
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self, weak readVM] range in
                guard let self,
                      let readVM,
                      self.mode == .read,
                      let range,
                      !range.isEmpty else { return }
                let wordIndex = range.lowerBound
                let paragraphIndex = readVM.currentParagraphIndex
                guard paragraphIndex >= 0 else { return }
                self.recordPlaybackAnchor(
                    mode: .read,
                    document: readVM.document,
                    paragraphIndex: paragraphIndex,
                    wordIndex: wordIndex,
                    charRange: nil
                )
                if range.count > 1 {
                    self.enqueueHighlightWordRange(paragraphIndex: paragraphIndex, range: range)
                } else {
                    self.enqueueHighlightWord(paragraphIndex: paragraphIndex, wordIndex: wordIndex)
                }
            }
            .store(in: &playbackCancellables)

        readVM.$currentParagraphIndex
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] paragraphIndex in
                guard let self, self.mode == .read, paragraphIndex >= 0 else { return }
                let key = "\(self.livePageKey ?? "")#\(paragraphIndex)"
                self.lastHighlightedWordByParagraph.removeValue(forKey: key)
                self.preparedParagraphKeys.remove(key)
                if let readVM = self.readVM {
                    self.recordPlaybackAnchor(
                        mode: .read,
                        document: readVM.document,
                        paragraphIndex: paragraphIndex,
                        wordIndex: readVM.photoHighlightWordIndex,
                        charRange: nil
                    )
                }
                Task { await self.resetVisualPositionForParagraph(paragraphIndex) }
            }
            .store(in: &playbackCancellables)

        readVM.$status
            .combineLatest(readVM.$currentParagraphIndex)
            .receive(on: RunLoop.main)
            .sink { [weak self] status, paragraphIndex in
                guard let self,
                      self.mode == .read,
                      paragraphIndex >= 0,
                      status.isReady else { return }
                self.maybeArmContinuousReadHandoff(reason: "read-status-ready")
            }
            .store(in: &playbackCancellables)

        let audio = AudioPlayerService.shared
        audio.$currentTime
            .combineLatest(audio.$duration, audio.$currentSegment)
            .receive(on: RunLoop.main)
            .sink { [weak self] currentTime, duration, segment in
                self?.handleContinuousReadHandoffProgress(
                    currentTime: currentTime,
                    duration: duration,
                    segment: segment
                )
            }
            .store(in: &playbackCancellables)
        audio.$isPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                guard isPlaying else { return }
                self?.maybeArmContinuousReadHandoff(reason: "audio-resumed")
            }
            .store(in: &playbackCancellables)

        explainVM.$activeMarks
            .receive(on: RunLoop.main)
            .sink { [weak self] marks in
                guard let self else { return }
                Task { await self.pushMarks(marks) }
            }
            .store(in: &playbackCancellables)

        explainVM.$scrollTarget
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] paragraphIndex in
                guard let self, self.mode == .explain, paragraphIndex >= 0 else { return }
                if let explainVM = self.explainVM {
                    self.recordPlaybackAnchor(
                        mode: .explain,
                        document: explainVM.document,
                        paragraphIndex: paragraphIndex,
                        wordIndex: nil,
                        charRange: nil
                    )
                }
                Task { [weak self] in
                    try? await Task.sleep(nanoseconds: 180_000_000)
                    guard let self, self.mode == .explain else { return }
                    await self.scrollToParagraph(paragraphIndex)
                }
            }
            .store(in: &playbackCancellables)

        explainVM.$status
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                guard let self, self.mode == .explain else { return }
                if case .completed = status {
                    self.isContinuingExplainPage = true
                    Task { await self.advanceToNextExplainPageIfNeeded() }
                }
            }
            .store(in: &playbackCancellables)
    }

    @discardableResult
    private func startReadPlayback(
        document: ReadingDocument,
        startHint: Int? = nil,
        prefetchedIndex: Int? = nil,
        prefetchedSegments: [AudioSegment] = [],
        reason: String
    ) -> Bool {
        guard mode == .read, let vm = readVM else { return false }
        let readableIDs = document.paragraphs
            .filter { $0.type.isReadable && SpeechTextSanitizer.containsSpeakableContent($0.text) }
            .map(\.id)
        guard let fallbackStart = readableIDs.first else {
            KindleRunLog.write("KINDLE read playback start failed reason=\(reason) key=\(Self.keyLog(livePageKey ?? "")) no-readable-paragraph")
            return false
        }
        let requestedStart = startHint ?? liveStartParagraphIndex
        let start = requestedStart.flatMap { readableIDs.contains($0) ? $0 : nil } ?? fallbackStart
        if let requestedStart, requestedStart != start {
            let readablePreview = readableIDs.prefix(8).map(String.init).joined(separator: ",")
            KindleRunLog.write("KINDLE read playback start remap reason=\(reason) key=\(Self.keyLog(livePageKey ?? "")) requested=\(requestedStart) start=\(start) readable=\(readablePreview)")
        }
        suppressNextScrollParagraphIndex = start
        let hasPrefetchedStart = prefetchedIndex == start && !prefetchedSegments.isEmpty
        let prefetchedSegmentCount = hasPrefetchedStart ? prefetchedSegments.count : 0
        KindleRunLog.write("KINDLE read playback start reason=\(reason) key=\(Self.keyLog(livePageKey ?? "")) p=\(start) prefetched=\(hasPrefetchedStart ? "Y" : "N") segs=\(prefetchedSegmentCount)")
        if hasPrefetchedStart {
            vm.startWithPrefetchedSegments(prefetchedSegments, paragraphIndex: start)
        } else if start > 0 {
            vm.jump(to: start)
        } else {
            vm.start()
        }
        startPageKeyWatcher()
        if let key = livePageKey?.nilIfEmpty {
            startCachingNextPage(afterKey: key)
        }
        KindlePlaybackCenter.shared.activate(model: self)
        return true
    }

    /// Arm a true audio-queue handoff once the current page's final chunk and
    /// the next page's OCR + first TTS utterance are all complete. Page preload
    /// used to stop at the cache; this promotes that cache into the live queue so
    /// AVPlayer can cross the page boundary just like an ordinary segment edge.
    private func maybeArmContinuousReadHandoff(reason: String) {
        guard continuousReadHandoff == nil,
              continuousReadCommitTask == nil,
              mode == .read,
              !isAdvancingLivePage,
              !isPageTurnResuming,
              !isKindleSyncDialogVisible,
              let vm = readVM,
              let oldKey = livePageKey?.nilIfEmpty,
              let target = preparedCandidate(afterKey: oldKey) else { return }

        let fingerprint = Self.explainFingerprint(target.document)
        guard let prefetched = startAudioCandidate(
            pageKey: target.page.key,
            textFingerprint: fingerprint,
            voiceID: AppSettings.shared.voice(for: target.document.language)
        ) else { return }

        let shouldArm = KindleContinuousPageHandoffContract.shouldArm(
            isReadMode: mode == .read,
            isLastReadableParagraph: vm.isOnLastReadableParagraph,
            currentTTSComplete: vm.currentTTSCompleteForPageHandoff,
            hasPreparedPage: true,
            hasPreparedAudio: !prefetched.segments.isEmpty,
            audioIsPlaying: AudioPlayerService.shared.isPlaying
        )
        guard shouldArm,
              prefetched.paragraphIndex >= 0,
              !prefetched.segments.isEmpty,
              let predecessor = AudioPlayerService.shared.queuedTailSegmentID else { return }

        continuousReadHandoffSerial += 1
        let serial = continuousReadHandoffSerial
        let rebased = prefetched.segments.enumerated().map { offset, segment in
            AudioSegment(
                paragraphIndex: segment.paragraphIndex,
                segmentIndex: 700_000_000 + (serial % 100_000) * 1_000 + offset,
                audioData: segment.audioData,
                timestamps: segment.timestamps,
                duration: segment.duration,
                text: segment.text,
                isWavFormat: segment.isWavFormat,
                unprocessedText: segment.unprocessedText,
                speaker: segment.speaker
            )
        }
        let handoff = KindleContinuousReadHandoff(
            serial: serial,
            oldKey: oldKey,
            target: target,
            previousSnapshot: currentPreparedPageSnapshot(),
            paragraphIndex: prefetched.paragraphIndex,
            segments: rebased,
            segmentIDs: Set(rebased.map(\.id)),
            predecessorSegmentID: predecessor
        )

        continuousReadHandoff = handoff
        continuousReadOldVMDetached = false
        continuousReadAudioCompletedBeforeCommit = false
        continuousReadTurnFailureCount = 0
        continuousReadSemanticTurnAttempted = false
        continuousReadConfirmedTargetKey = nil
        continuousReadStagedPage = nil
        continuousReadStagedLiveKey = nil
        let audio = AudioPlayerService.shared
        audio.canStartQueuedSegment = { [weak self] segment in
            guard let self,
                  let active = self.continuousReadHandoff,
                  active.serial == serial,
                  active.segmentIDs.contains(segment.id) else {
                return true
            }
            self.beginContinuousReadPageTurnIfNeeded(serial: serial, trigger: "queue-gate")
            let fingerprintMatches = self.continuousReadStagedPage.map {
                Self.explainFingerprint($0.document) ==
                    Self.explainFingerprint(active.target.document)
            } ?? false
            if self.continuousReadStagedPage != nil, !fingerprintMatches {
                // The semantic action reached a different surface than the
                // speculative cache predicted. Wait for this audio boundary,
                // then commit the confirmed surface with freshly generated audio.
                self.beginContinuousReadCommitIfNeeded(serial: serial)
            }
            return KindleContinuousPageHandoffContract.shouldReleaseAudioGate(
                hasConfirmedVisibleSurface: self.continuousReadStagedPage != nil,
                textFingerprintMatches: fingerprintMatches
            )
        }
        let appendedAfter = audio.appendPreparedSegmentsForContinuousPlayback(rebased)
        guard appendedAfter == predecessor else {
            cancelContinuousReadHandoff(reason: "queue-boundary-changed")
            return
        }

        KindleRunLog.write(
            "KINDLE read continuous armed reason=\(reason) serial=\(serial) old=\(Self.keyLog(oldKey)) " +
            "next=\(Self.keyLog(target.page.key)) predecessor=\(predecessor) segs=\(rebased.count)"
        )
        handleContinuousReadHandoffProgress(
            currentTime: audio.currentTime,
            duration: audio.duration,
            segment: audio.currentSegment
        )
    }

    private func handleContinuousReadHandoffProgress(
        currentTime: Double,
        duration: Double,
        segment: AudioSegment?
    ) {
        guard mode == .read,
              let handoff = continuousReadHandoff,
              let segment else { return }

        if handoff.segmentIDs.contains(segment.id) {
            beginContinuousReadCommitIfNeeded(serial: handoff.serial)
            return
        }

        let remaining = max(0, duration - currentTime)
        if KindleContinuousPageHandoffContract.shouldBeginVisualTurn(
            currentSegmentID: segment.id,
            predecessorSegmentID: handoff.predecessorSegmentID,
            remainingAudioSeconds: remaining,
            playbackRate: AudioPlayerService.shared.playbackRate
        ) {
            beginContinuousReadPageTurnIfNeeded(serial: handoff.serial, trigger: "tail-lead")
        }
    }

    private func beginContinuousReadPageTurnIfNeeded(serial: Int, trigger: String) {
        guard continuousReadTurnTask == nil,
              let handoff = continuousReadHandoff,
              handoff.serial == serial else { return }
        suppressExternalPageChangeUntil = Date().addingTimeInterval(6)
        clearExternalMismatchState()
        cancelLiveHighlightTasks()
        KindleRunLog.write(
            "KINDLE read continuous visual-turn begin trigger=\(trigger) serial=\(serial) " +
            "old=\(Self.keyLog(handoff.oldKey)) target=\(Self.keyLog(handoff.target.page.key))"
        )
        continuousReadTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.stageContinuousReadPage(handoff)
            } catch is CancellationError {
                KindleRunLog.write("KINDLE read continuous visual-turn cancelled serial=\(serial)")
            } catch {
                KindleRunLog.write("KINDLE read continuous visual-turn miss serial=\(serial) error=\(error.localizedDescription)")
                guard self.continuousReadHandoff?.serial == serial else { return }
                self.continuousReadTurnFailureCount += 1
                let failureCount = self.continuousReadTurnFailureCount
                self.continuousReadTurnTask = nil
                if failureCount < 2 {
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 180_000_000)
                        self?.beginContinuousReadPageTurnIfNeeded(serial: serial, trigger: "retry-\(failureCount)")
                    }
                } else {
                    let wasWaitingAtBoundary = AudioPlayerService.shared.isBuffering
                    self.cancelContinuousReadHandoff(reason: "visual-turn-retries-exhausted")
                    if wasWaitingAtBoundary {
                        AudioPlayerService.shared.nextSegment()
                    }
                }
            }
        }
    }

    private func stageContinuousReadPage(_ handoff: KindleContinuousReadHandoff) async throws {
        guard continuousReadHandoff?.serial == handoff.serial else { throw CancellationError() }
        try await ensureCaptureScriptInstalled(reason: "read-continuous-page-turn")
        await setKindlePageModeLocked(true)

        let expectedKey = normalizedPageKey(handoff.target.page.key)
        let oldKey = normalizedPageKey(handoff.oldKey)
        var visibleKey = normalizedPageKey(await currentVisibleKindlePageKey())
        var targetKey = KindleContinuousVisualTurnContract.stagingTargetKey(
            oldKey: oldKey,
            expectedKey: expectedKey,
            visibleKey: visibleKey,
            semanticActionAttempted: continuousReadSemanticTurnAttempted,
            confirmedTargetKey: continuousReadConfirmedTargetKey
        )

        if KindleContinuousVisualTurnContract.shouldDispatchSemanticAction(
            expectedKey: expectedKey,
            visibleKey: visibleKey,
            semanticActionAttempted: continuousReadSemanticTurnAttempted,
            confirmedTargetKey: continuousReadConfirmedTargetKey
        ) {
            // Mark before entering the non-idempotent request. Even when its
            // confirmation throws, a retry is observation-only.
            continuousReadSemanticTurnAttempted = true
            do {
                let turnedKey = try await requestNativeNextPageForAutoAdvance(
                    oldKey: handoff.oldKey,
                    reason: "read-continuous-page-turn"
                )
                guard continuousReadHandoff?.serial == handoff.serial else {
                    throw CancellationError()
                }
                let confirmed = normalizedPageKey(turnedKey)
                continuousReadConfirmedTargetKey = confirmed.nilIfEmpty
                targetKey = confirmed.nilIfEmpty
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The action may already have changed the page even if its
                // evidence probe timed out. Recover the visible surface without
                // ever dispatching a second action.
                visibleKey = normalizedPageKey(await currentVisibleKindlePageKey())
                targetKey = KindleContinuousVisualTurnContract.stagingTargetKey(
                    oldKey: oldKey,
                    expectedKey: expectedKey,
                    visibleKey: visibleKey,
                    semanticActionAttempted: true,
                    confirmedTargetKey: continuousReadConfirmedTargetKey
                )
                guard let recovered = targetKey?.nilIfEmpty else { throw error }
                continuousReadConfirmedTargetKey = recovered
                KindleRunLog.write(
                    "KINDLE read continuous turn-confirmation recovered serial=\(handoff.serial) " +
                    "expected=\(Self.keyLog(expectedKey)) visible=\(Self.keyLog(recovered))"
                )
            }
        }

        guard let targetKey = targetKey?.nilIfEmpty else {
            throw KindleBookError.captureFailed("continuous-stage-target-unavailable")
        }
        if targetKey != expectedKey {
            KindleRunLog.write(
                "KINDLE read continuous target-reconciled serial=\(handoff.serial) " +
                "prefetched=\(Self.keyLog(expectedKey)) confirmed=\(Self.keyLog(targetKey)) " +
                "actionAttempted=\(continuousReadSemanticTurnAttempted ? "Y" : "N")"
            )
        }

        let staged = try await preparedPageForNativeAutoAdvance(
            afterKey: handoff.oldKey,
            targetKey: targetKey,
            mode: .read
        )
        let actualKey = try await installLiveOverlay(page: staged.page, document: staged.document)
        guard continuousReadHandoff?.serial == handoff.serial else { throw CancellationError() }
        let prefetchedFingerprint = Self.explainFingerprint(handoff.target.document)
        let stagedFingerprint = Self.explainFingerprint(staged.document)
        let fingerprintMatches = prefetchedFingerprint == stagedFingerprint
        continuousReadStagedPage = staged
        continuousReadStagedLiveKey = actualKey
        continuousReadTurnFailureCount = 0
        KindleRunLog.write(
            "KINDLE read continuous visual-turn ready serial=\(handoff.serial) " +
            "target=\(Self.keyLog(staged.page.key)) actual=\(Self.keyLog(actualKey)) " +
            "fingerprint=\(fingerprintMatches ? "match" : "fallback")"
        )
        if fingerprintMatches {
            AudioPlayerService.shared.resumeGatedSegmentIfPossible()
        } else if KindleContinuousPageHandoffContract.shouldCommitConfirmedFallbackAtBoundary(
            hasConfirmedVisibleSurface: true,
            textFingerprintMatches: false,
            isQueuedSegmentGated: AudioPlayerService.shared.isQueuedSegmentGated
        ) {
            // The gate may have been evaluated while visual confirmation was
            // still in flight. It is now holding the next-page audio, so no new
            // callback will wake the fallback path. Commit the confirmed real
            // page and regenerate its audio without dispatching another turn.
            KindleRunLog.write(
                "KINDLE read continuous fallback-boundary-ready serial=\(handoff.serial) " +
                "target=\(Self.keyLog(staged.page.key))"
            )
            beginContinuousReadCommitIfNeeded(serial: handoff.serial)
        }
    }

    private func beginContinuousReadCommitIfNeeded(serial: Int) {
        guard continuousReadCommitTask == nil,
              let handoff = continuousReadHandoff,
              handoff.serial == serial else { return }

        if !continuousReadOldVMDetached {
            readVM?.detachForContinuousPageHandoff()
            invalidateReadPageSession(reason: "continuous-handoff-\(serial)-detached")
            continuousReadOldVMDetached = true
            AudioPlayerService.shared.onPlaybackComplete = { [weak self] in
                guard let self,
                      self.continuousReadHandoff?.serial == serial else { return }
                self.continuousReadAudioCompletedBeforeCommit = true
                KindleRunLog.write("KINDLE read continuous queued-audio completed-before-commit serial=\(serial)")
            }
        }
        beginContinuousReadPageTurnIfNeeded(serial: serial, trigger: "audio-boundary")
        KindleRunLog.write("KINDLE read continuous audio-boundary serial=\(serial) key=\(Self.keyLog(handoff.target.page.key))")
        continuousReadCommitTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.commitContinuousReadHandoff(serial: serial)
        }
    }

    private func commitContinuousReadHandoff(serial: Int) async {
        guard let initial = continuousReadHandoff, initial.serial == serial else { return }
        if let turnTask = continuousReadTurnTask {
            _ = await turnTask.value
        }

        if continuousReadStagedPage == nil {
            do {
                try await stageContinuousReadPage(initial)
            } catch {
                statusText = AppLocalized("下一页已缓存，但 Kindle 页面同步失败，已暂停。")
                continuousReadCommitTask = nil
                cancelContinuousReadHandoff(reason: "commit-page-sync-failed")
                AudioPlayerService.shared.clearQueue()
                KindleRunLog.write("KINDLE read continuous commit failed serial=\(serial) error=\(error.localizedDescription)")
                return
            }
        }

        guard let handoff = continuousReadHandoff,
              handoff.serial == serial,
              let staged = continuousReadStagedPage else { return }
        let actualKey = continuousReadStagedLiveKey?.nilIfEmpty ?? staged.page.key
        let completedBeforeCommit = continuousReadAudioCompletedBeforeCommit
        let prefetchedFingerprint = Self.explainFingerprint(handoff.target.document)
        let stagedFingerprint = Self.explainFingerprint(staged.document)
        let canAdoptPrefetchedAudio = prefetchedFingerprint == stagedFingerprint

        continuousReadHandoff = nil
        continuousReadTurnTask = nil
        continuousReadCommitTask = nil
        continuousReadStagedPage = nil
        continuousReadStagedLiveKey = nil
        continuousReadOldVMDetached = false
        continuousReadAudioCompletedBeforeCommit = false
        continuousReadTurnFailureCount = 0
        continuousReadSemanticTurnAttempted = false
        continuousReadConfirmedTargetKey = nil
        AudioPlayerService.shared.canStartQueuedSegment = nil
        invalidatePagePreloads(clearPrepared: false, reason: "continuous-page-commit")

        liveDocument = staged.document
        livePage = staged.page
        livePageKey = actualKey
        liveStartParagraphIndex = staged.startParagraphIndex ?? firstReadableParagraph(in: staged.document)
        liveStartIndexKind = .sourceParagraph
        liveVisibleTopNorm = 0
        liveVisibleBottomNorm = 1
        pendingCaptureKey = nil
        textQueue = nil
        activeReadPageSlot = .current
        store.updateProgress(
            bookID: book.id,
            pageKey: staged.page.key,
            url: staged.page.url,
            progressLabel: staged.page.progress
        )
        markBlobTransition(
            source: "read-continuous-handoff",
            oldKey: handoff.oldKey,
            expectedKey: staged.page.key,
            actualKey: actualKey
        )
        if let previousSnapshot = handoff.previousSnapshot {
            pageBackStack.append(previousSnapshot)
            pageForwardStack.removeAll()
        }

        do {
            let previousOwner = readVM
            let previousOwnerDocumentID = previousOwner?.document.id
            let queuedDocument = try await buildTextQueueForCurrentPage(baseDocument: staged.document)
            let start = liveStartParagraphIndex
                ?? queuedDocument.paragraphs.first(where: { $0.type.isReadable })?.id
                ?? handoff.paragraphIndex

            // buildTextQueueForCurrentPage normally installs a fresh VM as part
            // of publishing the new page. Keep the invariant explicit here so a
            // future queue refactor cannot silently let page-local paragraph IDs
            // make the previous page owner look compatible.
            if readVM == nil || readVM === previousOwner || readVM?.document.id != queuedDocument.id {
                resetViewModels(document: queuedDocument)
            }
            guard let vm = readVM else {
                throw KindleBookError.captureFailed("continuous-target-owner-unavailable")
            }
            let ownerCanAdopt = KindleContinuousPageHandoffContract.canAdoptPreparedAudio(
                previousOwnerDocumentID: previousOwnerDocumentID,
                activeOwnerDocumentID: vm.document.id,
                targetDocumentID: queuedDocument.id
            )
            guard canAdoptPrefetchedAudio, ownerCanAdopt else {
                AudioPlayerService.shared.clearQueue()
                _ = consumeStartAudioCandidate(
                    pageKey: staged.page.key,
                    textFingerprint: stagedFingerprint,
                    voiceID: AppSettings.shared.voice(for: staged.document.language)
                )
                let started = startReadPlayback(
                    document: queuedDocument,
                    startHint: start,
                    prefetchedIndex: ownerCanAdopt && canAdoptPrefetchedAudio ? start : nil,
                    prefetchedSegments: ownerCanAdopt && canAdoptPrefetchedAudio ? handoff.segments : [],
                    reason: canAdoptPrefetchedAudio
                        ? "continuous-owner-fallback"
                        : "continuous-fingerprint-fallback"
                )
                guard started else {
                    throw KindleBookError.captureFailed("continuous-safe-fallback-not-started")
                }
                KindleRunLog.write(
                    "KINDLE read continuous safe-fallback serial=\(serial) key=\(Self.keyLog(actualKey)) " +
                    "fingerprint=\(canAdoptPrefetchedAudio ? "Y" : "N") owner=\(ownerCanAdopt ? "Y" : "N") " +
                    "prefetched=\(prefetchedFingerprint.prefix(12)) staged=\(stagedFingerprint.prefix(12))"
                )
                return
            }
            guard vm.adoptContinuousPlayback(handoff.segments, paragraphIndex: start) else {
                // The prepared item may have ended while the visual surface was
                // committing. Restart the confirmed current page from its first
                // prepared utterance instead of pausing or advancing again.
                AudioPlayerService.shared.clearQueue()
                let restarted = startReadPlayback(
                    document: queuedDocument,
                    startHint: start,
                    prefetchedIndex: start,
                    prefetchedSegments: handoff.segments,
                    reason: "continuous-adoption-restart"
                )
                guard restarted else {
                    throw KindleBookError.captureFailed("continuous-audio-adoption-restart-failed")
                }
                KindleRunLog.write(
                    "KINDLE read continuous adoption-restarted serial=\(serial) key=\(Self.keyLog(actualKey))"
                )
                return
            }
            _ = consumeStartAudioCandidate(
                pageKey: staged.page.key,
                textFingerprint: Self.explainFingerprint(staged.document),
                voiceID: AppSettings.shared.voice(for: staged.document.language)
            )
            startPageKeyWatcher()
            KindlePlaybackCenter.shared.activate(model: self)
            statusText = AppLocalized("正在朗读 Kindle…")
            KindleRunLog.write(
                "KINDLE read continuous committed serial=\(serial) old=\(Self.keyLog(handoff.oldKey)) " +
                "new=\(Self.keyLog(actualKey)) p=\(start) segs=\(handoff.segments.count)"
            )
            if completedBeforeCommit {
                vm.continueAfterAdoptedPlaybackCompleted()
            }
        } catch {
            statusText = AppLocalized("下一页播放衔接失败，请点击播放继续。")
            AudioPlayerService.shared.clearQueue()
            KindleRunLog.write("KINDLE read continuous adoption failed serial=\(serial) error=\(error.localizedDescription)")
        }
    }

    private func cancelContinuousReadHandoff(reason: String, force: Bool = false) {
        guard let handoff = continuousReadHandoff else { return }
        let audio = AudioPlayerService.shared
        if !force,
           let currentID = audio.currentSegment?.id,
           handoff.segmentIDs.contains(currentID),
           continuousReadCommitTask != nil {
            KindleRunLog.write("KINDLE read continuous cancel deferred-active reason=\(reason) serial=\(handoff.serial)")
            return
        }
        continuousReadTurnTask?.cancel()
        continuousReadCommitTask?.cancel()
        _ = audio.removePendingSegments(withIDs: handoff.segmentIDs)
        audio.canStartQueuedSegment = nil
        continuousReadHandoff = nil
        continuousReadTurnTask = nil
        continuousReadCommitTask = nil
        continuousReadStagedPage = nil
        continuousReadStagedLiveKey = nil
        continuousReadOldVMDetached = false
        continuousReadAudioCompletedBeforeCommit = false
        continuousReadTurnFailureCount = 0
        continuousReadSemanticTurnAttempted = false
        continuousReadConfirmedTargetKey = nil
        KindleRunLog.write("KINDLE read continuous cancelled reason=\(reason) serial=\(handoff.serial)")
    }

    private func handleReadPageFinished(
        source: String,
        session: KindleReadPageSession,
        owner: ReadAloudViewModel
    ) async {
        let liveKey = normalizedPageKey(livePageKey?.nilIfEmpty ?? livePage?.key)
        let decision = KindleReadPageCompletionContract.decision(
            isReadMode: mode == .read,
            ownerMatches: readVM === owner,
            activeSession: activeReadPageSession,
            eventSession: session,
            consumedGeneration: consumedReadPageGeneration,
            currentPageKey: liveKey
        )
        guard decision == .accept else {
            KindleRunLog.write(
                "KINDLE read page finished rejected source=\(source) decision=\(String(describing: decision)) " +
                "eventGeneration=\(session.generation) activeGeneration=\(activeReadPageSession?.generation.description ?? "nil") " +
                "key=\(Self.keyLog(liveKey))"
            )
            return
        }

        // Consume before the first suspension point. A second callback from the
        // same VM can then never overlap this page turn, even if it is already
        // queued on the main RunLoop.
        consumedReadPageGeneration = session.generation
        let observedKey = await currentVisibleKindlePageKey()
        guard activeReadPageSession == session,
              consumedReadPageGeneration == session.generation,
              readVM === owner,
              normalizedPageKey(livePageKey?.nilIfEmpty ?? livePage?.key) == liveKey else {
            KindleRunLog.write(
                "KINDLE read page finished stale-after-probe source=\(source) " +
                "eventGeneration=\(session.generation) key=\(Self.keyLog(liveKey))"
            )
            return
        }
        if let observed = observedKey.nilIfEmpty,
           observed != liveKey {
            KindleRunLog.write("KINDLE read page finished visible-changed source=\(source) live=\(Self.keyLog(liveKey)) visible=\(Self.keyLog(observed))")
            scheduleExternalPageChangeResume(
                visibleKey: observed,
                oldKey: liveKey,
                reason: "read-finished-visible-change",
                force: true
            )
            return
        }
        KindleRunLog.write(
            "KINDLE read page finished accepted source=\(source) generation=\(session.generation) " +
            "key=\(Self.keyLog(liveKey))"
        )
        #if DEBUG
        NSLog("CRDBG KINDLE read page finished source=%@ generation=%llu key=%@",
              source, session.generation, Self.keyLog(liveKey))
        #endif
        await advanceToNextLivePageIfNeeded(session: session, expectedPageKey: liveKey)
    }

    private func resetReadSourceStateForAdvance() async {
        liveDocument = nil
        livePage = nil
        livePageKey = nil
        liveStartParagraphIndex = nil
        liveStartIndexKind = .sourceParagraph
        liveVisibleTopNorm = nil
        liveVisibleBottomNorm = nil
        pendingCaptureKey = nil
        suppressNextScrollParagraphIndex = nil
        textQueue = nil
        activeReadPageSlot = .current
        refocusWordRoutes.removeAll()
        playbackAnchor = nil
        lastHighlightedWordByParagraph.removeAll()
        clearKindleMarkState(resetAnimationHistory: true)
        cancelLiveHighlightTasks()
        _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")
    }

    private func advanceToNextLivePageIfNeeded(
        session: KindleReadPageSession,
        expectedPageKey: String
    ) async {
        guard mode == .read,
              !isAdvancingLivePage,
              activeReadPageSession == session,
              consumedReadPageGeneration == session.generation,
              normalizedPageKey(livePageKey?.nilIfEmpty ?? livePage?.key) == expectedPageKey else {
            KindleRunLog.write(
                "KINDLE read auto advance rejected-stale generation=\(session.generation) " +
                "key=\(Self.keyLog(expectedPageKey))"
            )
            return
        }
        let visibleOldKey = await currentVisibleKindlePageKey()
        guard activeReadPageSession == session,
              consumedReadPageGeneration == session.generation,
              normalizedPageKey(livePageKey?.nilIfEmpty ?? livePage?.key) == expectedPageKey else {
            KindleRunLog.write(
                "KINDLE read auto advance stale-after-visible-probe generation=\(session.generation) " +
                "key=\(Self.keyLog(expectedPageKey))"
            )
            return
        }
        if let visibleKey = visibleOldKey.nilIfEmpty, visibleKey != expectedPageKey {
            KindleRunLog.write(
                "KINDLE read auto advance visible-changed generation=\(session.generation) " +
                "expected=\(Self.keyLog(expectedPageKey)) visible=\(Self.keyLog(visibleKey))"
            )
            scheduleExternalPageChangeResume(
                visibleKey: visibleKey,
                oldKey: expectedPageKey,
                reason: "read-auto-visible-change",
                force: true
            )
            return
        }
        let oldKey = visibleOldKey.nilIfEmpty ?? expectedPageKey
        isAdvancingLivePage = true
        defer { isAdvancingLivePage = false }

        statusText = AppLocalized("正在加载下一页 Kindle 页面…")
        KindleRunLog.write("KINDLE read auto advance begin key=\(Self.keyLog(oldKey)) visible=\(Self.keyLog(visibleOldKey))")
        #if DEBUG
        NSLog("CRDBG KINDLE read auto advance begin key=%@", Self.keyLog(oldKey))
        #endif

        await advanceByNativePageTurnAndContinue(
            oldKey: oldKey,
            continuationMode: .read,
            status: AppLocalized("正在翻到下一页 Kindle 页面…"),
            reason: "read-auto-next-page"
        )
    }

    private func advanceToNextExplainPageIfNeeded() async {
        guard mode == .explain, !isAdvancingLivePage else {
            isContinuingExplainPage = false
            return
        }
        isAdvancingLivePage = true
        let visibleOldKey = await currentVisibleKindlePageKey()
        let oldKey: String
        if let visibleKey = visibleOldKey.nilIfEmpty {
            oldKey = visibleKey
        } else {
            oldKey = await currentKindlePageKey()
        }
        defer {
            isAdvancingLivePage = false
            isContinuingExplainPage = false
        }

        statusText = AppLocalized("正在加载下一页 Kindle 解读…")
        KindleRunLog.write("KINDLE explain auto advance begin key=\(Self.keyLog(oldKey)) visible=\(Self.keyLog(visibleOldKey))")
        #if DEBUG
        NSLog("CRDBG KINDLE explain auto advance begin key=%@", Self.keyLog(oldKey))
        #endif

        await advanceByNativePageTurnAndContinue(
            oldKey: oldKey,
            continuationMode: .explain,
            status: AppLocalized("正在翻到下一页 Kindle 解读…"),
            reason: "explain-auto-next-page"
        )
    }

    private func advanceByNativePageTurnAndContinue(
        oldKey rawOldKey: String,
        continuationMode: ReaderMode,
        status: String,
        reason: String
    ) async {
        guard mode == continuationMode, !isKindleSyncDialogVisible else {
            KindleRunLog.write("KINDLE auto advance blocked sync-dialog mode=\(continuationMode.rawValue) reason=\(reason)")
            return
        }
        let oldKey = rawOldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSnapshot = currentPreparedPageSnapshot()
        statusText = status
        pendingCaptureKey = nil
        invalidatePagePreloads(clearPrepared: false, reason: "\(reason)-generation")

        do {
            try await ensureCaptureScriptInstalled(reason: reason)
            await setKindlePageModeLocked(true)
            _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")

            let targetKey = try await requestNativeNextPageForAutoAdvance(oldKey: oldKey, reason: reason)
            guard mode == continuationMode, !isKindleSyncDialogVisible else {
                KindleRunLog.write("KINDLE \(continuationMode.rawValue) auto advance suspended sync-dialog old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(targetKey)) reason=\(reason)")
                return
            }
            pendingCaptureKey = targetKey

            let prepared = try await preparedPageForNativeAutoAdvance(
                afterKey: oldKey,
                targetKey: targetKey,
                mode: continuationMode
            )
            let singlePageDoc = try await activatePreparedNextPage(
                prepared,
                oldKey: oldKey,
                startOverride: prepared.startParagraphIndex,
                startKindOverride: .sourceParagraph
            )
            guard !isKindleSyncDialogVisible else {
                KindleRunLog.write("KINDLE \(continuationMode.rawValue) auto advance suspended-before-play sync-dialog old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(prepared.page.key)) reason=\(reason)")
                return
            }

            if let previousSnapshot {
                pageBackStack.append(previousSnapshot)
                pageForwardStack.removeAll()
            }

            mode = continuationMode
            try await restartPlaybackAfterPageTurn(
                document: singlePageDoc,
                target: prepared,
                oldKey: oldKey,
                reason: reason
            )
            KindleRunLog.write("KINDLE \(continuationMode.rawValue) auto advance success old=\(Self.keyLog(oldKey)) new=\(Self.keyLog(prepared.page.key)) reason=\(reason)")
        } catch {
            pendingCaptureKey = nil
            statusText = AppLocalized("已停在当前页，请点击播放继续。")
            KindleRunLog.write("KINDLE \(continuationMode.rawValue) auto advance failed old=\(Self.keyLog(oldKey)) reason=\(reason) error=\(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE auto advance failed mode=%@ old=%@ error=%@",
                  continuationMode.rawValue,
                  Self.keyLog(oldKey),
                  error.localizedDescription)
            #endif
        }
    }

    private func preparedPageForNativeAutoAdvance(
        afterKey oldKey: String,
        targetKey rawTargetKey: String?,
        mode continuationMode: ReaderMode
    ) async throws -> KindleCachedPage {
        try await waitForKindleImageStable()
        let targetKey = normalizedPageKey(rawTargetKey)
        let visibleKey = normalizedPageKey(await currentVisibleKindlePageKey())
        guard !targetKey.isEmpty, visibleKey == targetKey else {
            throw KindleBookError.captureFailed("auto-next-visible-key-mismatch:\(visibleKey)")
        }

        let confirmedPixelFingerprint = lastConfirmedTurnFingerprint
        if let cached = preparedCandidate(forKey: targetKey),
           cached.page.pixelFingerprint != nil,
           cached.page.pixelFingerprint == confirmedPixelFingerprint,
           let locked = await lockCurrentPageForCachedPlayback(expectedKey: targetKey) {
            let reboundPage = cached.page.replacingSessionId(locked.sessionId)
            let rebound = KindleCachedPage(
                afterKey: oldKey,
                page: reboundPage,
                document: cached.document,
                startParagraphIndex: cached.startParagraphIndex
            )
            let fingerprint = Self.explainFingerprint(cached.document)
            KindleRunLog.write("KINDLE \(continuationMode.rawValue) auto next candidate-hit old=\(Self.keyLog(oldKey)) current=\(Self.keyLog(targetKey)) source=page-key-cache originalAfter=\(Self.keyLog(cached.afterKey)) fingerprint=\(fingerprint.prefix(12)) session=\(locked.sessionId)")
            return rebound
        }

        let page = try await captureVisiblePage(pageIndex: 0, targetKey: targetKey.nilIfEmpty)
        let captured = try makePreparedPage(afterKey: oldKey, page: page)
        let capturedKey = captured.page.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let pixelChanged = captured.page.pixelFingerprint != nil &&
            captured.page.pixelFingerprint == confirmedPixelFingerprint &&
            captured.page.pixelFingerprint != livePage?.pixelFingerprint
        guard capturedKey != oldKey || pixelChanged else {
            throw KindleBookError.captureFailed("auto-next-same-visible-page")
        }
        if !targetKey.isEmpty, capturedKey != targetKey {
            throw KindleBookError.captureFailed("auto-next-target-mismatch:\(capturedKey)")
        }

        let fingerprint = Self.explainFingerprint(captured.document)
        if let candidate = preparedCandidate(forKey: capturedKey),
           candidate.afterKey == oldKey,
           candidate.page.pixelFingerprint == captured.page.pixelFingerprint,
           candidate.document.language == captured.document.language,
           candidate.page.columnLayout == captured.page.columnLayout,
           Self.explainFingerprint(candidate.document) == fingerprint {
            KindleRunLog.write("KINDLE \(continuationMode.rawValue) auto next candidate-hit old=\(Self.keyLog(oldKey)) current=\(Self.keyLog(capturedKey)) source=current-visible fingerprint=match")
        } else {
            KindleRunLog.write("KINDLE \(continuationMode.rawValue) auto next candidate-miss old=\(Self.keyLog(oldKey)) current=\(Self.keyLog(capturedKey)) source=current-visible")
        }
        cachePreparedCandidate(captured)
        return captured
    }

    private func cachedPreparedNextPage(afterKey oldKey: String, targetKey rawTargetKey: String) -> KindleCachedPage? {
        let targetKey = rawTargetKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return preparedCandidate(afterKey: oldKey, targetKey: targetKey)
    }

    private func requestNativeNextPageForAutoAdvance(oldKey: String, reason: String) async throws -> String {
        let target = try await requestKindlePageTurnTarget(.next, oldKey: oldKey)
        let result = target.result
        let ok = Self.boolValue(result["ok"])
        let strategy = result["strategy"] as? String ?? ""
        KindleRunLog.write("KINDLE auto next turn-only old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(target.targetKey)) ok=\(ok) strategy=\(strategy) reason=\(reason) tried=\(String(describing: result["tried"] ?? result["fallbackTried"] ?? ""))")
        guard ok else {
            throw KindleBookError.captureFailed("auto-next-turn-failed:\(result["reason"] as? String ?? "unknown")")
        }
        return target.targetKey
    }

    private func advanceExplainUsingCachedPageIfAvailable(after oldKey: String) async -> Bool {
        if let prepared = preparedCandidate(afterKey: oldKey),
           !prepared.page.key.isEmpty,
           prepared.page.key != oldKey {
            do {
                let previousSnapshot = currentPreparedPageSnapshot()
                let singlePageDoc = try await activatePreparedNextPage(prepared, oldKey: oldKey)
                let fingerprint = Self.explainFingerprint(singlePageDoc)
                let usablePrefetch = consumeExplainPrefetchCandidate(
                    afterKey: oldKey,
                    pageKey: prepared.page.key,
                    textFingerprint: fingerprint
                )
                if usablePrefetch != nil {
                    KindleRunLog.write("KINDLE explain prefetch consume after=\(Self.keyLog(oldKey)) key=\(Self.keyLog(prepared.page.key))")
                } else {
                    KindleRunLog.write("KINDLE explain prefetch miss after=\(Self.keyLog(oldKey)) key=\(Self.keyLog(prepared.page.key))")
                }
                if let previousSnapshot {
                    pageBackStack.append(previousSnapshot)
                    pageForwardStack.removeAll()
                }
                startExplainPlayback(document: singlePageDoc, reason: usablePrefetch == nil ? "cached-next-page" : "cached-next-page-prefetched", prefetched: usablePrefetch)
                return true
            } catch {
                #if DEBUG
                NSLog("CRDBG KINDLE explain prepared advance fallback oldKey=%@ prepared=%@ error=%@",
                      Self.keyLog(oldKey),
                      Self.keyLog(prepared.page.key),
                      error.localizedDescription)
                #endif
                cachedPageCandidates[prepared.page.key] = nil
            }
        }
        return false
    }

      private func advanceExplainBySourceScroll(oldKey: String) async {
          let previousSnapshot = currentPreparedPageSnapshot()
          do {
              let page = try await captureNextPage(afterKey: oldKey)
              guard page.key != oldKey else {
                  throw KindleBookError.captureFailed("next-page-same-key")
              }
              let prepared = try makePreparedPage(afterKey: oldKey, page: page)
              let doc = try await activatePreparedNextPage(
                  prepared,
                  oldKey: oldKey,
                  startOverride: prepared.startParagraphIndex,
                  startKindOverride: .sourceParagraph
              )
              let newKey = livePageKey ?? ""
              if !oldKey.isEmpty, oldKey == newKey {
                  statusText = AppLocalized("已到达当前 Kindle 内容末尾。")
                  return
            }
            markBlobTransition(
                source: "explain-source-advance",
                oldKey: oldKey,
                expectedKey: nil,
                actualKey: newKey
            )
              if let previousSnapshot {
                  pageBackStack.append(previousSnapshot)
                  pageForwardStack.removeAll()
              }
              startExplainPlayback(document: doc, reason: "page-key-advance")
          } catch {
              statusText = error.localizedDescription
              KindleRunLog.write("KINDLE explain advance error \(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE explain advance error %@", error.localizedDescription)
            #endif
        }
    }

    private func startExplainPlayback(
        document: ReadingDocument,
        reason: String,
        prefetched: ExplainViewModel.PrefetchedFirstBlock? = nil
    ) {
        guard mode == .explain, let vm = explainVM else { return }
        readVM?.deactivate()
        vm.activate()
        recordPlaybackStart(language: document.language)
        clearKindleMarkState(resetAnimationHistory: true)
        Task { _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()") }
        if let key = livePageKey {
            ensureExplainNextPagePrefetch(afterKey: key, reason: reason)
        }
        KindleRunLog.write("KINDLE explain playback start reason=\(reason) key=\(Self.keyLog(livePageKey ?? "")) paras=\(document.paragraphs.count)")
        #if DEBUG
        NSLog("CRDBG KINDLE explain playback start reason=%@ key=%@ paras=%d",
              reason,
              Self.keyLog(livePageKey ?? ""),
              document.paragraphs.count)
        #endif
        if let prefetched {
            vm.startFromPrefetched(prefetched)
        } else {
            vm.start()
        }
        startPageKeyWatcher()
        KindlePlaybackCenter.shared.activate(model: self)
    }

    private func ensureExplainNextPagePrefetch(afterKey rawKey: String, reason: String) {
        let afterKey = normalizedPageKey(rawKey)
        guard !afterKey.isEmpty, mode == .explain else { return }

        if let prepared = preparedCandidate(afterKey: afterKey),
           !prepared.page.key.isEmpty,
           prepared.page.key != afterKey {
            let pageKey = normalizedPageKey(prepared.page.key)
            let fingerprint = Self.explainFingerprint(prepared.document)
            if let cached = cachedExplainPrefetchCandidates[pageKey] ?? cachedExplainPrefetch,
               cached.afterKey == afterKey,
               cached.pageKey == pageKey,
               cached.textFingerprint == fingerprint {
                KindleRunLog.write("KINDLE explain prefetch followup cached reason=\(reason) after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey))")
                return
            }
            KindleRunLog.write("KINDLE explain prefetch followup start reason=\(reason) after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey))")
            startExplainFirstBlockPrefetch(
                afterKey: afterKey,
                pageKey: pageKey,
                document: prepared.document,
                epoch: preloadEpoch
            )
            return
        }

        KindleRunLog.write("KINDLE explain prefetch followup needs-page-cache reason=\(reason) after=\(Self.keyLog(afterKey))")
        startCachingNextPage(afterKey: afterKey)
    }

    private func continueCurrentTextQueueIfNeeded() async -> Bool {
        if pendingCurrentPageContinuation,
           let continuationDocument = liveDocument,
           let resumeIndex = liveStartParagraphIndex {
            do {
                pendingCurrentPageContinuation = false
                let prefetchedIndex = pendingContinuationParagraphIndex
                let prefetchedSegments = pendingContinuationSegments
                pendingContinuationParagraphIndex = nil
                pendingContinuationSegments = []
                pendingContinuationTask?.cancel()
                pendingContinuationTask = nil

                let doc = try await buildTextQueueForCurrentPage(baseDocument: continuationDocument)
                let start = liveStartParagraphIndex ?? resumeIndex
                KindleRunLog.write("KINDLE read bridge continue key=\(Self.keyLog(livePageKey ?? "")) start=\(start) prefetched=\(prefetchedIndex == start ? prefetchedSegments.count : 0)")
                #if DEBUG
                NSLog("CRDBG KINDLE bridge continue key=%@ start=%d paras=%d prefetched=%d",
                      Self.keyLog(livePageKey ?? ""),
                      start,
                      doc.paragraphs.count,
                      prefetchedIndex == start ? prefetchedSegments.count : 0)
                #endif
                _ = startReadPlayback(
                    document: doc,
                    startHint: start,
                    prefetchedIndex: prefetchedIndex,
                    prefetchedSegments: prefetchedSegments,
                    reason: "current-page-continuation"
                )
                return true
            } catch {
                KindleRunLog.write("KINDLE read bridge continue miss key=\(Self.keyLog(livePageKey ?? "")) error=\(error.localizedDescription)")
                clearPendingContinuation()
            }
        }
        return false
    }

    private func advanceUsingCachedPageIfAvailable(after oldKey: String) async -> Bool {
        if let prepared = preparedCandidate(afterKey: oldKey),
           !prepared.page.key.isEmpty,
           prepared.page.key != oldKey {
            do {
                let previousSnapshot = currentPreparedPageSnapshot()
                let singlePageDoc = try await activatePreparedNextPage(
                    prepared,
                    oldKey: oldKey,
                    startOverride: prepared.startParagraphIndex,
                    startKindOverride: .sourceParagraph
                )
                let doc = try await buildTextQueueForCurrentPage(baseDocument: singlePageDoc)
                let newKey = livePageKey ?? ""
                let start = liveStartParagraphIndex ?? doc.paragraphs.first(where: { $0.type.isReadable })?.id ?? 0
                let fingerprint = Self.explainFingerprint(singlePageDoc)
                let startAudio = consumeStartAudioCandidate(
                    pageKey: prepared.page.key,
                    textFingerprint: fingerprint,
                    voiceID: AppSettings.shared.voice(for: singlePageDoc.language)
                )
                #if DEBUG
                NSLog("CRDBG KINDLE live advance prepared ready oldKey=%@ newKey=%@ start=%d paras=%d chars=%d",
                      Self.keyLog(oldKey),
                      Self.keyLog(newKey),
                      start,
                      doc.paragraphs.count,
                      doc.fullText.count)
                #endif
                KindleRunLog.write("KINDLE read advance cached-ready old=\(Self.keyLog(oldKey)) new=\(Self.keyLog(newKey)) start=\(start) pageOnly=Y paras=\(doc.paragraphs.count)")
                if start == startAudio?.paragraphIndex, !(startAudio?.segments.isEmpty ?? true) {
                    KindleRunLog.write("KINDLE read advance prefetched-audio key=\(Self.keyLog(newKey)) p=\(start) segs=\(startAudio?.segments.count ?? 0)")
                    #if DEBUG
                    NSLog("CRDBG KINDLE live advance use prefetched audio key=%@ p=%d segs=%d",
                          Self.keyLog(newKey),
                          start,
                      startAudio?.segments.count ?? 0)
                    #endif
                }
                if let previousSnapshot {
                    pageBackStack.append(previousSnapshot)
                    pageForwardStack.removeAll()
                }
                _ = startReadPlayback(
                    document: doc,
                    startHint: start,
                    prefetchedIndex: startAudio?.paragraphIndex,
                    prefetchedSegments: startAudio?.segments ?? [],
                    reason: "cached-next-page"
                )
                return true
            } catch {
                #if DEBUG
                NSLog("CRDBG KINDLE prepared advance fallback oldKey=%@ prepared=%@ error=%@",
                      Self.keyLog(oldKey),
                      Self.keyLog(prepared.page.key),
                      error.localizedDescription)
                #endif
                cachedPageCandidates[prepared.page.key] = nil
            }
        }
        return false
    }

      private func advanceBySourceScroll(oldKey: String, oldTop: CGFloat?, oldBottom: CGFloat?) async {
          let previousSnapshot = currentPreparedPageSnapshot()
          do {
              let page = try await captureNextPage(afterKey: oldKey)
              guard page.key != oldKey else {
                  throw KindleBookError.captureFailed("next-page-same-key")
              }
              let prepared = try makePreparedPage(afterKey: oldKey, page: page)
              let singlePageDoc = try await activatePreparedNextPage(
                  prepared,
                  oldKey: oldKey,
                  startOverride: prepared.startParagraphIndex,
                  startKindOverride: .sourceParagraph
              )
              let doc = try await buildTextQueueForCurrentPage(baseDocument: singlePageDoc)
              let newKey = livePageKey ?? ""
              let newTop = liveVisibleTopNorm
              let newBottom = liveVisibleBottomNorm
            if !oldKey.isEmpty, oldKey == newKey {
                statusText = AppLocalized("已到达当前 Kindle 内容末尾。")
                #if DEBUG
                NSLog("CRDBG KINDLE live advance no-move key=%@ oldTop=%@ newTop=%@",
                      Self.keyLog(newKey),
                      String(describing: oldTop),
                      String(describing: newTop))
                #endif
                return
            }
            let start = liveStartParagraphIndex ?? doc.paragraphs.first(where: { $0.type.isReadable })?.id ?? 0
            markBlobTransition(
                source: "read-source-advance",
                oldKey: oldKey,
                expectedKey: nil,
                actualKey: newKey
            )
            if let previousSnapshot {
                pageBackStack.append(previousSnapshot)
                pageForwardStack.removeAll()
            }
            KindleRunLog.write("KINDLE read advance ready key=\(Self.keyLog(newKey)) old=\(Self.keyLog(oldKey)) start=\(start) paras=\(doc.paragraphs.count)")
            #if DEBUG
            NSLog("CRDBG KINDLE live advance ready key=%@ oldKey=%@ oldTop=%@ oldBottom=%@ newTop=%@ newBottom=%@ start=%d advance=%@",
                  Self.keyLog(newKey),
                  Self.keyLog(oldKey),
                  String(describing: oldTop),
                  String(describing: oldBottom),
                    String(describing: newTop),
                    String(describing: newBottom),
                    start,
                    "page-key")
              #endif
              _ = startReadPlayback(document: doc, startHint: start, reason: "page-key-advance")
          } catch {
              statusText = error.localizedDescription
              KindleRunLog.write("KINDLE read advance error \(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE live advance error %@", error.localizedDescription)
            #endif
        }
    }

    private func installLiveOverlay(page: CapturedKindlePage, document: ReadingDocument) async throws -> String {
        guard isReaderSurfaceAttached, webView.window != nil else {
            throw KindleBookError.overlayFailed("reader-surface-not-visible")
        }
        let payload: [String: Any] = [
            "key": page.key,
            "sessionId": page.sessionId,
            "title": page.title,
            "imagePixelWidth": Double(page.document.imagePixelSize?.width ?? 0),
            "imagePixelHeight": Double(page.document.imagePixelSize?.height ?? 0),
            "paragraphs": document.paragraphs.map { paragraphPayload($0) }
        ]
        let json = try jsonString(payload)
        var result: [String: Any] = [:]
        var lastReason = "unknown"
        for attempt in 0..<8 {
            result = try await evaluateJSON("window.__crKindleLiveSetPage && window.__crKindleLiveSetPage(\(json))")
            if result["ok"] as? Bool == true { break }
            lastReason = result["reason"] as? String ?? lastReason
            #if DEBUG
            NSLog("CRDBG KINDLE live overlay wait attempt=%d key=%@ reason=%@ candidates=%@",
                  attempt + 1,
                  Self.keyLog(page.key),
                  lastReason,
                  String(describing: result["candidates"] ?? ""))
            #endif
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        if result["ok"] as? Bool != true {
            throw KindleBookError.overlayFailed(lastReason)
        }
        let actualKey = result["key"] as? String ?? page.key
        #if DEBUG
        NSLog("CRDBG KINDLE live overlay key=%@ requested=%@ session=%d kind=%@ paras=%d resultKind=%@ fallback=%@ parent=%@ position=%@ local=%@",
              Self.keyLog(actualKey),
              Self.keyLog(page.key),
              page.sessionId,
              page.kind,
              document.paragraphs.count,
              String(describing: result["kind"] ?? ""),
              String(describing: result["fallback"] ?? false),
              String(describing: result["parent"] ?? ""),
              String(describing: result["position"] ?? ""),
              String(describing: result["local"] ?? ""))
        #endif
        return actualKey
    }

    private func highlightWord(
        paragraphIndex: Int,
        wordIndex: Int,
        force: Bool = false,
        sequence: UInt64? = nil
    ) async {
        guard isCurrentVisualSequence(sequence) else { return }
        if let route = refocusWordRoutes["\(paragraphIndex)#\(wordIndex)"] {
            await paintHighlightWord(
                paragraphIndex: route.overlayParagraphID,
                wordIndex: route.overlayWordIndex,
                force: true,
                sequence: sequence ?? nextVisualSyncSequence()
            )
            return
        }
        if Self.hasRenderRoute(in: refocusWordRoutes, paragraphIndex: paragraphIndex) {
            KindleRunLog.write("KINDLE refocus route-miss p=\(paragraphIndex) w=\(wordIndex)")
            Task { [weak self] in
                await self?.refocusPlaybackPosition(reason: "route-miss")
            }
            return
        }
        let route = textQueue?.wordRoutes["\(paragraphIndex)#\(wordIndex)"]
        if let route {
            guard isCurrentVisualSequence(sequence) else { return }
            await switchRenderPageIfNeeded(to: route.slot)
            guard isCurrentVisualSequence(sequence) else { return }
            await paintHighlightWord(
                paragraphIndex: route.overlayParagraphID,
                wordIndex: route.overlayWordIndex,
                force: force,
                sequence: sequence ?? nextVisualSyncSequence()
            )
            scheduleProactiveNextRenderSwitchIfNeeded(
                paragraphIndex: paragraphIndex,
                wordIndex: wordIndex,
                route: route,
                sequence: sequence
            )
        } else {
            await paintHighlightWord(
                paragraphIndex: paragraphIndex,
                wordIndex: wordIndex,
                force: force,
                sequence: sequence ?? nextVisualSyncSequence()
            )
        }
    }

    private func scheduleProactiveNextRenderSwitchIfNeeded(
        paragraphIndex: Int,
        wordIndex: Int,
        route: KindleRenderRoute,
        sequence: UInt64?
    ) {
        guard mode == .read,
              route.slot == .current,
              let nextRoute = textQueue?.wordRoutes["\(paragraphIndex)#\(wordIndex + 1)"],
              nextRoute.slot == .next else { return }
        let expectedSequence = sequence ?? visualSyncSequence
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard let self,
                  self.mode == .read,
                  self.isCurrentVisualSequence(expectedSequence) else { return }
            KindleRunLog.write("KINDLE read bridge pre-switch p=\(paragraphIndex) w=\(wordIndex)")
            await self.switchRenderPageIfNeeded(to: .next)
        }
    }

    private func isCurrentVisualSequence(_ sequence: UInt64?) -> Bool {
        guard let sequence else { return true }
        return sequence == visualSyncSequence
    }

    private static func nearestRenderRoute(
        in routes: [String: KindleRenderRoute],
        paragraphIndex: Int,
        wordIndex: Int
    ) -> KindleRenderRoute? {
        if let exact = routes["\(paragraphIndex)#\(wordIndex)"] {
            return exact
        }
        var best: (distance: Int, route: KindleRenderRoute)?
        let prefix = "\(paragraphIndex)#"
        for (key, route) in routes where key.hasPrefix(prefix) {
            guard let candidateIndex = Int(key.dropFirst(prefix.count)) else { continue }
            let distance = abs(candidateIndex - wordIndex)
            guard distance <= 8 else { continue }
            if best == nil || distance < best!.distance {
                best = (distance, route)
            }
        }
        return best?.route
    }

    private static func firstRenderRoute(
        in routes: [String: KindleRenderRoute],
        paragraphIndex: Int
    ) -> KindleRenderRoute? {
        let prefix = "\(paragraphIndex)#"
        return routes
            .compactMap { key, route -> (Int, KindleRenderRoute)? in
                guard key.hasPrefix(prefix),
                      let wordIndex = Int(key.dropFirst(prefix.count)) else { return nil }
                return (wordIndex, route)
            }
            .sorted { $0.0 < $1.0 }
            .first?
            .1
    }

    private static func hasRenderRoute(
        in routes: [String: KindleRenderRoute],
        paragraphIndex: Int
    ) -> Bool {
        routes.keys.contains { $0.hasPrefix("\(paragraphIndex)#") }
    }

    private func paintHighlightWord(
        paragraphIndex: Int,
        wordIndex: Int,
        force: Bool = false,
        sequence: UInt64
    ) async {
        let paragraphKey = liveParagraphKey(paragraphIndex)
        guard !Task.isCancelled else { return }
        if !force, let last = lastHighlightedWordByParagraph[paragraphKey], wordIndex < last {
            #if DEBUG
            NSLog("CRDBG KINDLE highlight skip backwards key=%@ p=%d word=%d<%d",
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex,
                  wordIndex,
                  last)
            #endif
            return
        }
        lastHighlightedWordByParagraph[paragraphKey] = wordIndex
        do {
            let result = try await evaluateJSON("window.__crKindleLiveHighlightWord && window.__crKindleLiveHighlightWord(\(paragraphIndex), \(wordIndex), \(sequence))")
            if result["stale"] as? Bool == true {
                KindleRunLog.write("KINDLE read highlight stale seq=\(sequence) p=\(paragraphIndex) w=\(wordIndex)")
                return
            }
            if result["ok"] as? Bool == true,
               let key = livePageKey?.nilIfEmpty {
                maybeRetryCachingNextPage(afterKey: key, reason: "highlight")
                scheduleScrollAfterHighlight(result: result, paragraphIndex: paragraphIndex, wordIndex: wordIndex)
            } else {
                let reason = result["reason"] as? String ?? "unknown"
                KindleRunLog.write("KINDLE read highlight miss key=\(Self.keyLog(livePageKey ?? "")) p=\(paragraphIndex) w=\(wordIndex) reason=\(reason)")
                scheduleVisualRecoveryIfNeeded(
                    reason: reason,
                    paragraphIndex: paragraphIndex,
                    wordIndex: wordIndex,
                    sequence: sequence
                )
            }
            #if DEBUG
            if result["ok"] as? Bool != true {
                let reason = result["reason"] as? String ?? "unknown"
                NSLog("CRDBG KINDLE highlight miss key=%@ p=%d w=%d reason=%@",
                      Self.keyLog(livePageKey ?? ""),
                      paragraphIndex,
                      wordIndex,
                      reason)
            } else {
                if wordIndex == 0 || wordIndex % 12 == 0 {
                    KindleRunLog.write("KINDLE read highlight hit key=\(Self.keyLog(livePageKey ?? "")) p=\(paragraphIndex) w=\(wordIndex)")
                }
                NSLog("CRDBG KINDLE highlight key=%@ p=%d w=%d bbox=%@ pct=%@ xy=%@,%@ %@x%@ screen=%@ ov=%@,%@ %@x%@ img=%@ imgOffset=%@ parentRect=%@ stale=%@ position=%@ parent=%@ point=%@ local=%@",
                      Self.keyLog(livePageKey ?? ""),
                      paragraphIndex,
                      wordIndex,
                      String(describing: result["bboxNorm"] ?? ""),
                      String(describing: result["pct"] ?? ""),
                      String(describing: result["left"] ?? "?"),
                      String(describing: result["top"] ?? "?"),
                      String(describing: result["width"] ?? "?"),
                      String(describing: result["height"] ?? "?"),
                      String(describing: result["screen"] ?? ""),
                      String(describing: result["overlayLeft"] ?? "?"),
                      String(describing: result["overlayTop"] ?? "?"),
                      String(describing: result["overlayWidth"] ?? "?"),
                      String(describing: result["overlayHeight"] ?? "?"),
                      String(describing: result["imgRect"] ?? ""),
                      String(describing: result["imgOffset"] ?? ""),
                      String(describing: result["parentRect"] ?? ""),
                      String(describing: result["stale"] ?? false),
                      String(describing: result["position"] ?? ""),
                      String(describing: result["parent"] ?? ""),
                      String(describing: result["point"] ?? ""),
                      String(describing: result["local"] ?? ""))
            }
            #endif
        } catch {
            KindleRunLog.write("KINDLE read highlight error key=\(Self.keyLog(livePageKey ?? "")) p=\(paragraphIndex) w=\(wordIndex) error=\(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE highlight error key=%@ p=%d w=%d %@",
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex,
                  wordIndex,
                  error.localizedDescription)
            #endif
        }
    }

    private func scheduleScrollAfterHighlight(
        result: [String: Any],
        paragraphIndex: Int,
        wordIndex: Int
    ) {
        guard mode == .read else { return }
        #if DEBUG
        if wordIndex == 0 {
            NSLog("CRDBG KINDLE highlight-follow disabled page-only key=%@ p=%d result=%@",
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex,
                  String(describing: result["lineKey"] ?? ""))
        }
        #endif
    }

    private func scheduleVisualRecoveryIfNeeded(
        reason: String,
        paragraphIndex: Int,
        wordIndex: Int,
        sequence: UInt64
    ) {
        guard mode == .read,
              hasActivePlaybackSession,
              Self.highlightMissNeedsVisualRecovery(reason),
              !isPreparing,
              !isAdvancingLivePage,
              !isRefocusingPlayback else { return }

        if isReaderLayoutCurrentlyUnstable {
            KindleRunLog.write("KINDLE visual recovery skipped-layout-unstable reason=\(reason) key=\(Self.keyLog(livePageKey ?? "")) p=\(paragraphIndex) w=\(wordIndex)")
            return
        }

        let now = Date()
        if let lastVisualRecoveryAt,
           now.timeIntervalSince(lastVisualRecoveryAt) < 1.05 {
            return
        }
        lastVisualRecoveryAt = now

        visualRecoveryTask?.cancel()
        visualRecoveryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self,
                  self.mode == .read,
                  self.hasActivePlaybackSession,
                  !self.isPreparing,
                  !self.isAdvancingLivePage else { return }

            KindleRunLog.write("KINDLE visual recovery begin reason=\(reason) key=\(Self.keyLog(self.livePageKey ?? "")) p=\(paragraphIndex) w=\(wordIndex)")
            await self.refocusPlaybackPosition(reason: "highlight-miss")

            guard self.isCurrentVisualSequence(sequence),
                  self.mode == .read,
                  self.hasActivePlaybackSession else { return }
            await self.highlightWord(
                paragraphIndex: paragraphIndex,
                wordIndex: wordIndex,
                force: true,
                sequence: self.nextVisualSyncSequence()
            )
        }
    }

    private static func highlightMissNeedsVisualRecovery(_ reason: String) -> Bool {
        switch reason {
        case "captured-page-not-visible",
             "live-candidate-not-visible",
             "key-not-visible",
             "anchor-missing",
             "anchor-scroll-node-detached",
             "no-overlay",
             "no-page-rect",
             "no-page-percent",
             "word-not-found":
            return true
        default:
            return reason.contains("not-visible") || reason.contains("detached")
        }
    }

    private static func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            return string == "true" || string == "1"
        }
        return false
    }

    private static func numberValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func verticalColumnHints(from value: Any?) -> [KindleVerticalColumnHint] {
        (value as? [[String: Any]] ?? []).compactMap { raw in
            guard let left = numberValue(raw["leftRatio"]),
                  let right = numberValue(raw["rightRatio"]),
                  let top = numberValue(raw["topRatio"]),
                  let bottom = numberValue(raw["bottomRatio"]),
                  right > left, bottom > top else { return nil }
            return KindleVerticalColumnHint(
                leftRatio: left,
                rightRatio: right,
                topRatio: top,
                bottomRatio: bottom,
                expectedCharacters: Int(numberValue(raw["expectedCharacters"]) ?? 0),
                startPositionID: numberValue(raw["startPositionId"]).map(Int.init),
                endPositionID: numberValue(raw["endPositionId"]).map(Int.init)
            )
        }
    }

    private func resetBlobOrderTracker() {
        expectedNextBlobByAfterKey.removeAll()
        blobOrderByKey.removeAll()
        lastActivatedBlobKey = nil
    }

    private func markExpectedNextBlob(afterKey rawAfterKey: String, nextKey rawNextKey: String, source: String) {
        let afterKey = rawAfterKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextKey = rawNextKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !afterKey.isEmpty, !nextKey.isEmpty else { return }
        let previous = expectedNextBlobByAfterKey[afterKey]
        expectedNextBlobByAfterKey[afterKey] = nextKey
        let status: String
        if nextKey == afterKey {
            status = "same-key"
        } else if let previous, previous != nextKey {
            status = "replaced"
        } else {
            status = "ready"
        }
        KindleRunLog.write("KINDLE blob expected source=\(source) status=\(status) after=\(Self.keyLog(afterKey)) next=\(Self.keyLog(nextKey)) previous=\(Self.keyLog(previous ?? ""))")
        #if DEBUG
        NSLog("CRDBG KINDLE blob expected source=%@ status=%@ after=%@ next=%@ previous=%@",
              source,
              status,
              Self.keyLog(afterKey),
              Self.keyLog(nextKey),
              Self.keyLog(previous ?? ""))
        #endif
    }

    private func markBlobTransition(
        source: String,
        oldKey rawOldKey: String?,
        expectedKey rawExpectedKey: String?,
        actualKey rawActualKey: String
    ) {
        let oldKey = rawOldKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let expectedKey = (rawExpectedKey?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty)
            ?? expectedNextBlobByAfterKey[oldKey]
            ?? ""
        let actualKey = rawActualKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousLiveKey = lastActivatedBlobKey ?? ""

        var status = "ok"
        if actualKey.isEmpty {
            status = "empty"
        } else if !oldKey.isEmpty, actualKey == oldKey {
            status = "repeat"
        } else if !expectedKey.isEmpty, actualKey != expectedKey {
            status = "wrong-next"
        } else if let ordinal = blobOrderByKey[actualKey] {
            if actualKey == previousLiveKey {
                status = "same-active"
            } else if let previousOrdinal = blobOrderByKey[previousLiveKey], ordinal < previousOrdinal {
                status = "backtrack"
            } else {
                status = "duplicate"
            }
        } else if !oldKey.isEmpty, expectedKey.isEmpty {
            status = "unverified"
        } else if oldKey.isEmpty {
            status = "initial"
        }

        if !actualKey.isEmpty, blobOrderByKey[actualKey] == nil {
            blobOrderByKey[actualKey] = blobOrderByKey.count
        }
        if !actualKey.isEmpty {
            lastActivatedBlobKey = actualKey
        }
        if !oldKey.isEmpty, expectedNextBlobByAfterKey[oldKey] == actualKey {
            expectedNextBlobByAfterKey.removeValue(forKey: oldKey)
        }

        let trail = blobOrderByKey
            .sorted { $0.value < $1.value }
            .suffix(6)
            .map { Self.keyLog($0.key) }
            .joined(separator: ">")
        KindleRunLog.write("KINDLE blob transition source=\(source) status=\(status) old=\(Self.keyLog(oldKey)) expected=\(Self.keyLog(expectedKey)) actual=\(Self.keyLog(actualKey)) previous=\(Self.keyLog(previousLiveKey)) order=\(blobOrderByKey[actualKey] ?? -1) trail=\(trail)")
        #if DEBUG
        NSLog("CRDBG KINDLE blob transition source=%@ status=%@ old=%@ expected=%@ actual=%@ previous=%@ order=%d trail=%@",
              source,
              status,
              Self.keyLog(oldKey),
              Self.keyLog(expectedKey),
              Self.keyLog(actualKey),
              Self.keyLog(previousLiveKey),
              blobOrderByKey[actualKey] ?? -1,
              trail)
        #endif
    }

    private func switchRenderPageIfNeeded(to slot: KindleReadPageSlot) async {
        guard activeReadPageSlot != slot, let window = textQueue else { return }
        switch slot {
        case .current:
            guard let key = window.currentPage.key.nilIfEmpty else { return }
            await activateRenderPage(
                slot: .current,
                page: window.currentPage,
                overlayDocument: window.currentOverlayDocument,
                key: key
            )
        case .next:
            guard let page = window.nextPage,
                  let overlayDocument = window.nextOverlayDocument,
                  let key = page.key.nilIfEmpty else { return }
            await activateRenderPage(
                slot: .next,
                page: page,
                overlayDocument: overlayDocument,
                key: key
            )
        }
    }

    private func activateRenderPage(
        slot: KindleReadPageSlot,
        page: CapturedKindlePage,
        overlayDocument: ReadingDocument,
        key: String
    ) async {
        do {
            guard await restorePlaybackKeyVisibility(key, reason: "render-switch-\(slot.logName)", maxSteps: 8) else {
                throw KindleBookError.captureFailed("playback-key-not-visible")
            }
            try await waitForKindleImageStable()
            let previousKey = livePageKey
            let actualKey = try await installLiveOverlay(page: page, document: overlayDocument)
            livePage = page
            livePageKey = actualKey
            activeReadPageSlot = slot
            refocusWordRoutes.removeAll()
            playbackAnchor = nil
            lastHighlightedWordByParagraph.removeAll()
            scrolledHighlightLineKeys.removeAll()
            paragraphResetKeys.removeAll()
            store.updateProgress(bookID: book.id, pageKey: page.key, url: page.url, progressLabel: page.progress)
            markBlobTransition(
                source: "render-switch-\(slot.logName)",
                oldKey: previousKey,
                expectedKey: page.key,
                actualKey: actualKey
            )
            if slot == .next {
                if mode == .read {
                    if let window = textQueue,
                       let document = window.nextBaseDocument,
                       let resumeIndex = window.nextResumeParagraphIndex {
                        liveDocument = document
                        liveStartParagraphIndex = resumeIndex
                        liveStartIndexKind = .playbackChunk
                        pendingCurrentPageContinuation = true
                        startPrepareCurrentPageContinuation(document: document, paragraphIndex: resumeIndex)
                        KindleRunLog.write("KINDLE read bridge switched key=\(Self.keyLog(actualKey)) resume=\(resumeIndex)")
                    }
                    startCachingNextPage(afterKey: actualKey)
                } else if mode == .explain {
                    if let window = textQueue {
                        liveDocument = window.nextBaseDocument ?? overlayDocument
                        liveStartParagraphIndex = window.nextResumeParagraphIndex ?? firstReadableParagraph(in: overlayDocument)
                        liveStartIndexKind = window.nextResumeParagraphIndex == nil ? .sourceParagraph : .playbackChunk
                    }
                    startCachingNextPage(afterKey: actualKey)
                    KindleRunLog.write("KINDLE explain render switched key=\(Self.keyLog(actualKey))")
                }
            }
            #if DEBUG
            NSLog("CRDBG KINDLE read window switch slot=%@ key=%@ paras=%d",
                  slot.logName,
                  Self.keyLog(actualKey),
                  overlayDocument.paragraphs.count)
            #endif
        } catch {
            #if DEBUG
            NSLog("CRDBG KINDLE read window switch miss slot=%@ key=%@ error=%@",
                  slot.logName,
                  Self.keyLog(key),
                  error.localizedDescription)
            #endif
        }
    }

    private func liveParagraphKey(_ paragraphIndex: Int) -> String {
        "\(livePageKey ?? "")#\(paragraphIndex)"
    }

    private func cancelLiveHighlightTasks() {
        visualSyncSequence &+= 1
        visualSyncTask?.cancel()
        visualSyncTask = nil
        visualScrollTask?.cancel()
        visualScrollTask = nil
        visualRecoveryTask?.cancel()
        visualRecoveryTask = nil
        lastVisualRecoveryAt = nil
        scrolledHighlightLineKeys.removeAll()
        paragraphResetKeys.removeAll()
        paragraphPrepTasks.values.forEach { $0.cancel() }
        paragraphPrepTasks.removeAll()
        preparedParagraphKeys.removeAll()
    }

    private func invalidatePagePreloads(clearPrepared: Bool, reason: String) {
        cancelContinuousReadHandoff(reason: reason)
        preloadEpoch &+= 1
        cancelPageCaching(clearPrepared: clearPrepared)
        clearPendingContinuation()
        paragraphPrepTasks.values.forEach { $0.cancel() }
        paragraphPrepTasks.removeAll()
        preparedParagraphKeys.removeAll()
        nextPagePreloadRetryAt.removeAll()
        nextPagePreloadFailureCount.removeAll()
        nextPagePreloadCooldownUntil.removeAll()
        KindleRunLog.write("KINDLE preload invalidate reason=\(reason) epoch=\(preloadEpoch) clear=\(clearPrepared)")
    }

    private func handlePlaybackVoiceWillSwitch(_ notification: Notification) {
        let requestedLanguage = VoiceCatalog.normalizedLanguage(
            notification.userInfo?["language"] as? String ?? ""
        )
        guard !requestedLanguage.isEmpty else { return }

        if mode == .explain,
           let activeExplainVM = explainVM,
           let sourceVM = notification.object as? ExplainViewModel,
           sourceVM === activeExplainVM,
           requestedLanguage == activeExplainVM.playbackLanguage {
            explainPrefetchTask?.cancel()
            explainPrefetchTask = nil
            explainPrefetchingAfterKey = nil
            deferredExplainPreloadTask?.cancel()
            deferredExplainPreloadTask = nil
            deferredExplainPreloadAfterKey = nil
            cachedExplainPrefetch = nil
            cachedExplainPrefetchCandidates.removeAll()
            let fromVoice = notification.userInfo?["fromVoiceID"] as? String ?? "-"
            let toVoice = notification.userInfo?["toVoiceID"] as? String ?? "-"
            KindleRunLog.write("KINDLE explain voice switch invalidate audio-prefetch from=\(fromVoice) to=\(toVoice) lang=\(requestedLanguage)")
            return
        }

        guard mode == .read,
              let activeReadVM = readVM,
              let sourceVM = notification.object as? ReadAloudViewModel,
              sourceVM === activeReadVM else { return }
        let playbackLanguage = VoiceCatalog.normalizedLanguage(
            readVM?.document.language ?? liveDocument?.language ?? ""
        )
        guard requestedLanguage == playbackLanguage else { return }

        // Audio prefetched with voice A must never be adopted after the live VM
        // has switched to voice B. Keep OCR/page captures, invalidate only audio
        // continuations, and immediately warm the prepared next page again.
        cancelContinuousReadHandoff(reason: "voice-switch", force: true)
        clearPendingContinuation()
        cachedStartAudio = nil
        cachedStartAudioCandidates.removeAll()
        let fromVoice = notification.userInfo?["fromVoiceID"] as? String ?? "-"
        let toVoice = notification.userInfo?["toVoiceID"] as? String ?? "-"
        KindleRunLog.write("KINDLE voice switch invalidate audio-prefetch from=\(fromVoice) to=\(toVoice) lang=\(requestedLanguage)")
        if let liveKey = livePageKey?.nilIfEmpty {
            startCachingNextPage(afterKey: liveKey)
        }
    }

    private func cancelPageCaching(clearPrepared: Bool) {
        pageCacheTask?.cancel()
        pageCacheTask = nil
        cachingNextPageAfterKey = nil
        explainPrefetchTask?.cancel()
        explainPrefetchTask = nil
        explainPrefetchingAfterKey = nil
        deferredExplainPreloadTask?.cancel()
        deferredExplainPreloadTask = nil
        deferredExplainPreloadAfterKey = nil
        if clearPrepared {
            clearPreparedCandidateCaches()
            bridgedNextResumeByPageKey.removeAll()
        }
    }

    private func clearPendingContinuation() {
        pendingCurrentPageContinuation = false
        pendingContinuationParagraphIndex = nil
        pendingContinuationSegments = []
        pendingContinuationTask?.cancel()
        pendingContinuationTask = nil
    }

    private func startPrepareCurrentPageContinuation(document: ReadingDocument, paragraphIndex: Int) {
        guard pendingContinuationParagraphIndex != paragraphIndex || pendingContinuationSegments.isEmpty else { return }
        pendingContinuationTask?.cancel()
        pendingContinuationParagraphIndex = paragraphIndex
        pendingContinuationSegments = []
        let chunks = document.paragraphs
            .filter(Self.isReadableKindleParagraph)
            .flatMap { playbackChunks(for: $0, slot: .current) }
        let text = chunks.indices.contains(paragraphIndex)
            ? chunks[paragraphIndex].text
            : document.paragraphs.first(where: { $0.id == paragraphIndex })?.text
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        KindleRunLog.write("KINDLE read continuation preload start p=\(paragraphIndex)")
        pendingContinuationTask = Task { [weak self] in
            do {
                let segments = try await self?.generateDetachedTTSSegments(
                    paragraphIndex: paragraphIndex,
                    text: text,
                    language: document.language
                ) ?? []
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    guard let self, self.pendingContinuationParagraphIndex == paragraphIndex else { return }
                    self.pendingContinuationSegments = segments
                    self.pendingContinuationTask = nil
                    KindleRunLog.write("KINDLE read continuation preload ready p=\(paragraphIndex) segs=\(segments.count)")
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.pendingContinuationParagraphIndex == paragraphIndex else { return }
                    self.pendingContinuationTask = nil
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.pendingContinuationParagraphIndex == paragraphIndex else { return }
                    self.pendingContinuationTask = nil
                    KindleRunLog.write("KINDLE read continuation preload miss p=\(paragraphIndex) error=\(error.localizedDescription)")
                }
            }
        }
    }

    private func startCachingNextPage(afterKey rawKey: String) {
        let afterKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !afterKey.isEmpty else { return }
        guard !isPageTurnResuming else {
            KindleRunLog.write("KINDLE read preload skip-page-turn after=\(Self.keyLog(afterKey))")
            return
        }
        if shouldDeferExplainPagePreload() {
            scheduleDeferredExplainPagePreload(afterKey: afterKey)
            return
        }
        if let prepared = preparedCandidate(afterKey: afterKey) {
            ensurePreparedNextPagePrefetch(afterKey: afterKey, prepared: prepared, reason: "prepared-cache-hit")
            return
        }
        if cachingNextPageAfterKey == afterKey { return }
        if let remaining = nextPagePreloadCooldownRemaining(afterKey: afterKey) {
            KindleRunLog.write("KINDLE read preload skip-cooldown after=\(Self.keyLog(afterKey)) remainingMs=\(Int(remaining * 1000))")
            return
        }

        let epoch = preloadEpoch
        cancelPageCaching(clearPrepared: false)
        cachingNextPageAfterKey = afterKey
        #if DEBUG
        NSLog("CRDBG KINDLE page preload start after=%@ epoch=%llu", Self.keyLog(afterKey), epoch)
        #endif
        KindleRunLog.write("KINDLE read preload start after=\(Self.keyLog(afterKey)) epoch=\(epoch)")
        pageCacheTask = Task { [weak self] in
            await self?.cacheNextPage(afterKey: afterKey, epoch: epoch)
        }
    }

    private func shouldDeferExplainPagePreload() -> Bool {
        guard mode == .explain else { return false }
        return explainVM?.shouldDeferExternalPagePrefetchForCurrentBlock() == true
    }

    private func scheduleDeferredExplainPagePreload(afterKey: String) {
        if deferredExplainPreloadAfterKey == afterKey { return }
        deferredExplainPreloadTask?.cancel()
        let epoch = preloadEpoch
        deferredExplainPreloadAfterKey = afterKey
        KindleRunLog.write("KINDLE explain preload defer-current-block after=\(Self.keyLog(afterKey)) epoch=\(epoch)")
        deferredExplainPreloadTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 900_000_000)
            } catch {
                return
            }
            await MainActor.run { [weak self] in
                guard let self,
                      !Task.isCancelled,
                      self.preloadEpoch == epoch,
                      self.deferredExplainPreloadAfterKey == afterKey else { return }
                self.deferredExplainPreloadAfterKey = nil
                self.deferredExplainPreloadTask = nil
                self.startCachingNextPage(afterKey: afterKey)
            }
        }
    }

    private func ensurePreparedNextPagePrefetch(afterKey: String, prepared: KindleCachedPage, reason: String) {
        switch mode {
        case .read:
            startPreparedReadStartAudioPrefetch(afterKey: afterKey, prepared: prepared, reason: reason)
        case .explain:
            ensureExplainNextPagePrefetch(afterKey: afterKey, reason: reason)
        }
    }

    private func startPreparedReadStartAudioPrefetch(afterKey: String, prepared: KindleCachedPage, reason: String) {
        guard mode == .read else { return }
        let pageKey = normalizedPageKey(prepared.page.key)
        guard !pageKey.isEmpty, pageKey != afterKey else { return }
        let fingerprint = Self.explainFingerprint(prepared.document)
        if let cached = cachedStartAudioCandidates[pageKey] ?? cachedStartAudio,
           normalizedPageKey(cached.pageKey) == pageKey,
           cached.textFingerprint == fingerprint {
            KindleRunLog.write("KINDLE read preload tts-skip-cache reason=\(reason) after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey))")
            return
        }
        if cachingNextPageAfterKey == afterKey { return }

        let epoch = preloadEpoch
        cachingNextPageAfterKey = afterKey
        pageCacheTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.cachingNextPageAfterKey == afterKey && self.preloadEpoch == epoch {
                    self.cachingNextPageAfterKey = nil
                    self.pageCacheTask = nil
                }
            }
            do {
                guard self.preloadEpoch == epoch else { return }
                let current = self.preparedCandidate(afterKey: afterKey, targetKey: pageKey) ?? prepared
                _ = try await self.ensureReadStartSegmentsPrepared(current, epoch: epoch, reason: reason)
            } catch is CancellationError {
                KindleRunLog.write("KINDLE read preload tts-cancelled reason=\(reason) after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) epoch=\(epoch)")
            } catch {
                KindleRunLog.write("KINDLE read preload tts-miss reason=\(reason) after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) error=\(error.localizedDescription)")
            }
        }
    }

    private func maybeRetryCachingNextPage(afterKey rawKey: String, reason: String) {
        let afterKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !afterKey.isEmpty, mode == .read || mode == .explain else { return }
        guard !isPageTurnResuming else { return }
        if preparedCandidate(afterKey: afterKey) != nil || cachingNextPageAfterKey == afterKey { return }
        if let remaining = nextPagePreloadCooldownRemaining(afterKey: afterKey) {
            KindleRunLog.write("KINDLE preload retry skip-cooldown reason=\(reason) after=\(Self.keyLog(afterKey)) remainingMs=\(Int(remaining * 1000))")
            return
        }
        let now = Date()
        if let last = nextPagePreloadRetryAt[afterKey],
           now.timeIntervalSince(last) < 1.4 {
            return
        }
        nextPagePreloadRetryAt[afterKey] = now
        KindleRunLog.write("KINDLE preload retry reason=\(reason) after=\(Self.keyLog(afterKey))")
        startCachingNextPage(afterKey: afterKey)
    }

    private func cacheNextPage(afterKey: String, epoch: UInt64) async {
        defer {
            if cachingNextPageAfterKey == afterKey && preloadEpoch == epoch {
                cachingNextPageAfterKey = nil
                pageCacheTask = nil
            }
        }
        do {
            guard preloadEpoch == epoch else { return }
            let captureLimit = mode == .explain ? 1 : 4
            KindleRunLog.write("KINDLE \(mode.rawValue) preload capture-limit after=\(Self.keyLog(afterKey)) limit=\(captureLimit) epoch=\(epoch)")
            let pages = try await captureCandidatePages(afterKey: afterKey, limit: captureLimit)
            guard !Task.isCancelled, preloadEpoch == epoch else { return }
            guard !pages.isEmpty else {
                throw KindleBookError.noText
            }

            var previousKey = afterKey
            var warmedAudioCount = 0
            var preparedCount = 0
            for page in pages {
                try Task.checkCancellation()
                guard preloadEpoch == epoch else { return }
                guard !page.key.isEmpty, page.key != previousKey else {
                    KindleRunLog.write("KINDLE blob transition source=preload-capture status=repeat old=\(Self.keyLog(previousKey)) expected= actual=\(Self.keyLog(page.key))")
                    continue
                }
                guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                let doc = makeLiveDocument(from: page)
                guard hasReadableParagraphs(doc) else { continue }
                let prepared = KindleCachedPage(
                    afterKey: previousKey,
                    page: page,
                    document: doc,
                    startParagraphIndex: firstReadableParagraph(in: doc)
                )
                cachePreparedCandidate(prepared)
                if preparedCount == 0 {
                    markExpectedNextBlob(afterKey: afterKey, nextKey: page.key, source: "preload-ready")
                }
                cachedStartAudioCandidates[page.key] = nil
                preparedCount += 1
                #if DEBUG
                NSLog("CRDBG KINDLE page preload ready after=%@ key=%@ paras=%d words=%d chars=%d",
                      Self.keyLog(prepared.afterKey),
                      Self.keyLog(page.key),
                      doc.paragraphs.count,
                      doc.paragraphs.reduce(0) { $0 + $1.words.count },
                      doc.fullText.count)
                #endif
                KindleRunLog.write("KINDLE read preload candidate-ready after=\(Self.keyLog(prepared.afterKey)) key=\(Self.keyLog(page.key)) paras=\(doc.paragraphs.count) chars=\(doc.fullText.count) ordinal=\(preparedCount) epoch=\(epoch)")
                if mode == .explain {
                    if preparedCount == 1 {
                        startExplainFirstBlockPrefetch(afterKey: prepared.afterKey, pageKey: page.key, document: doc, epoch: epoch)
                    }
                    previousKey = page.key
                    continue
                }
                guard mode == .read else {
                    KindleRunLog.write("KINDLE page preload skip-read-tts mode=\(mode.rawValue) after=\(Self.keyLog(prepared.afterKey)) key=\(Self.keyLog(page.key))")
                    previousKey = page.key
                    continue
                }
                guard warmedAudioCount < 2 else {
                    previousKey = page.key
                    continue
                }
                do {
                    let preparedAudio = try await ensureReadStartSegmentsPrepared(prepared, epoch: epoch, reason: "page-preload")
                    if preparedAudio {
                        warmedAudioCount += 1
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    KindleRunLog.write("KINDLE read preload tts-miss after=\(Self.keyLog(prepared.afterKey)) key=\(Self.keyLog(page.key)) error=\(error.localizedDescription)")
                    #if DEBUG
                    NSLog("CRDBG KINDLE page preload tts miss after=%@ key=%@ error=%@",
                          Self.keyLog(prepared.afterKey),
                          Self.keyLog(page.key),
                          error.localizedDescription)
                    #endif
                }
                previousKey = page.key
            }
            guard preparedCount > 0 else {
                throw KindleBookError.noText
            }
            recordNextPagePreloadSuccess(afterKey: afterKey)
        } catch is CancellationError {
            KindleRunLog.write("KINDLE read preload cancelled after=\(Self.keyLog(afterKey)) epoch=\(epoch)")
            #if DEBUG
            NSLog("CRDBG KINDLE page preload cancelled after=%@", Self.keyLog(afterKey))
            #endif
        } catch {
            recordNextPagePreloadFailure(afterKey: afterKey, error: error)
            KindleRunLog.write("KINDLE read preload miss after=\(Self.keyLog(afterKey)) error=\(error.localizedDescription) epoch=\(epoch)")
            #if DEBUG
            NSLog("CRDBG KINDLE page preload miss after=%@ error=%@",
                  Self.keyLog(afterKey),
                  error.localizedDescription)
            #endif
        }
    }

    @discardableResult
    private func ensureReadStartSegmentsPrepared(
        _ prepared: KindleCachedPage,
        epoch: UInt64,
        reason: String
    ) async throws -> Bool {
        guard mode == .read, preloadEpoch == epoch else { return false }
        let afterKey = normalizedPageKey(prepared.afterKey)
        let pageKey = normalizedPageKey(prepared.page.key)
        guard !afterKey.isEmpty, !pageKey.isEmpty, pageKey != afterKey else { return false }

        let fingerprint = Self.explainFingerprint(prepared.document)
        let voiceID = AppSettings.shared.voice(for: prepared.document.language)
        if let cached = cachedStartAudioCandidates[pageKey] ?? cachedStartAudio,
           normalizedPageKey(cached.pageKey) == pageKey {
            if cached.textFingerprint == fingerprint, cached.voiceID == voiceID {
                KindleRunLog.write("KINDLE read preload tts-skip-cache reason=\(reason) after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey))")
                return false
            }
            cachedStartAudioCandidates[pageKey] = nil
            if normalizedPageKey(cachedStartAudio?.pageKey) == pageKey {
                cachedStartAudio = nil
            }
            KindleRunLog.write("KINDLE read preload tts-discard-stale reason=\(reason) after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey))")
        }

        let chunks = prepared.document.paragraphs
            .filter(Self.isReadableKindleParagraph)
            .flatMap { playbackChunks(for: $0, slot: .current) }
        let preferredStart = bridgedNextResumeByPageKey[pageKey]
        let startIndex = preferredStart.flatMap { chunks.indices.contains($0) ? $0 : nil } ?? chunks.indices.first ?? -1
        guard startIndex >= 0 else { return false }

        let segments = try await generateDetachedTTSSegments(
            paragraphIndex: startIndex,
            text: chunks[startIndex].text,
            language: prepared.document.language,
            voiceOverride: voiceID
        )
        guard !Task.isCancelled, preloadEpoch == epoch else { throw CancellationError() }
        guard AppSettings.shared.voice(for: prepared.document.language) == voiceID else {
            KindleRunLog.write("KINDLE read preload tts-drop-stale reason=voice-changed key=\(Self.keyLog(pageKey)) generatedVoice=\(voiceID)")
            return false
        }
        guard let current = preparedCandidate(forKey: pageKey),
              normalizedPageKey(current.afterKey) == afterKey,
              normalizedPageKey(current.page.key) == pageKey,
              preloadEpoch == epoch else {
            KindleRunLog.write("KINDLE read preload tts-drop-stale reason=\(reason) after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) epoch=\(epoch)")
            return false
        }

        let audio = KindleAudioPrefetch(
            pageKey: pageKey,
            textFingerprint: fingerprint,
            voiceID: voiceID,
            paragraphIndex: startIndex,
            segments: segments
        )
        cacheStartAudioCandidate(audio)
        #if DEBUG
        NSLog("CRDBG KINDLE page preload tts ready after=%@ key=%@ p=%d segs=%d",
              Self.keyLog(afterKey),
              Self.keyLog(pageKey),
              startIndex,
              segments.count)
        #endif
        KindleRunLog.write("KINDLE read preload tts-ready reason=\(reason) after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) p=\(startIndex) resumePreferred=\(preferredStart ?? -1) segs=\(segments.count) epoch=\(epoch)")
        maybeArmContinuousReadHandoff(reason: "next-page-audio-ready")
        return true
    }

    private func nextPagePreloadCooldownRemaining(afterKey: String) -> TimeInterval? {
        guard let until = nextPagePreloadCooldownUntil[afterKey] else { return nil }
        let remaining = until.timeIntervalSinceNow
        if remaining > 0 {
            return remaining
        }
        nextPagePreloadCooldownUntil[afterKey] = nil
        return nil
    }

    private func recordNextPagePreloadSuccess(afterKey: String) {
        nextPagePreloadFailureCount[afterKey] = nil
        nextPagePreloadCooldownUntil[afterKey] = nil
    }

    private func recordNextPagePreloadFailure(afterKey: String, error: Error) {
        let count = (nextPagePreloadFailureCount[afterKey] ?? 0) + 1
        nextPagePreloadFailureCount[afterKey] = count
        let delay: TimeInterval
        switch count {
        case 1:
            delay = 4
        case 2:
            delay = 8
        default:
            delay = 18
        }
        nextPagePreloadCooldownUntil[afterKey] = Date().addingTimeInterval(delay)
        KindleRunLog.write("KINDLE preload cooldown after=\(Self.keyLog(afterKey)) failures=\(count) delayMs=\(Int(delay * 1000)) error=\(error.localizedDescription)")
    }

    private func startExplainFirstBlockPrefetch(afterKey: String, pageKey: String, document: ReadingDocument, epoch: UInt64) {
        guard mode == .explain, preloadEpoch == epoch else { return }
        guard ProManager.shared.isPro else {
            KindleRunLog.write("KINDLE explain prefetch skip free-user after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) epoch=\(epoch)")
            return
        }
        let fingerprint = Self.explainFingerprint(document)
        if let cached = cachedExplainPrefetchCandidates[pageKey] ?? cachedExplainPrefetch,
           cached.afterKey == afterKey,
           cached.pageKey == pageKey,
           cached.textFingerprint == fingerprint {
            return
        }
        if explainPrefetchingAfterKey == afterKey { return }
        explainPrefetchTask?.cancel()
        explainPrefetchingAfterKey = afterKey
        let previousSummary = explainVM?.currentContinuitySummary()
        KindleRunLog.write("KINDLE explain prefetch start after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) chars=\(document.fullText.count) epoch=\(epoch)")
        #if DEBUG
        NSLog("CRDBG KINDLE explain prefetch start after=%@ key=%@ paras=%d chars=%d",
              Self.keyLog(afterKey),
              Self.keyLog(pageKey),
              document.paragraphs.count,
              document.fullText.count)
        #endif
        explainPrefetchTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.preloadEpoch == epoch else { return }
                guard let vm = self.explainVM else { return }
                let payload = try await vm.prefetchFirstBlock(
                    for: document,
                    previousSummary: previousSummary,
                    textFingerprint: fingerprint
                )
                guard !Task.isCancelled, self.preloadEpoch == epoch else { return }
                if self.explainPrefetchingAfterKey == afterKey,
                   self.preloadEpoch == epoch {
                    let prefetch = KindleExplainPrefetch(
                        afterKey: afterKey,
                        pageKey: pageKey,
                        textFingerprint: fingerprint,
                        payload: payload
                    )
                    self.cacheExplainPrefetchCandidate(prefetch)
                    self.explainPrefetchingAfterKey = nil
                    self.explainPrefetchTask = nil
                    KindleRunLog.write("KINDLE explain prefetch ready after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) blocks=\(payload.totalBlocks) epoch=\(epoch)")
                    #if DEBUG
                    NSLog("CRDBG KINDLE explain prefetch ready after=%@ key=%@ blocks=%d",
                          Self.keyLog(afterKey),
                          Self.keyLog(pageKey),
                          payload.totalBlocks)
                    #endif
                }
            } catch is CancellationError {
                if self.explainPrefetchingAfterKey == afterKey,
                   self.preloadEpoch == epoch {
                    self.explainPrefetchingAfterKey = nil
                    self.explainPrefetchTask = nil
                }
                KindleRunLog.write("KINDLE explain prefetch cancelled after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) epoch=\(epoch)")
            } catch {
                if self.explainPrefetchingAfterKey == afterKey,
                   self.preloadEpoch == epoch {
                    self.explainPrefetchingAfterKey = nil
                    self.explainPrefetchTask = nil
                }
                KindleRunLog.write("KINDLE explain prefetch miss after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) error=\(error.localizedDescription) epoch=\(epoch)")
                #if DEBUG
                NSLog("CRDBG KINDLE explain prefetch miss after=%@ key=%@ error=%@",
                      Self.keyLog(afterKey),
                      Self.keyLog(pageKey),
                      error.localizedDescription)
                #endif
            }
        }
    }

    private func activatePreparedNextPage(
        _ prepared: KindleCachedPage,
        oldKey: String,
        startOverride: Int? = nil,
        startKindOverride: KindleStartIndexKind? = nil
    ) async throws -> ReadingDocument {
        statusText = AppLocalized("正在打开下一页 Kindle 页面…")
        liveDocument = nil
        livePage = nil
        livePageKey = nil
        liveStartParagraphIndex = nil
        liveStartIndexKind = .sourceParagraph
        liveVisibleTopNorm = nil
        liveVisibleBottomNorm = nil
        pendingCaptureKey = nil
        suppressNextScrollParagraphIndex = nil
        textQueue = nil
        activeReadPageSlot = .current
        lastHighlightedWordByParagraph.removeAll()
        clearKindleMarkState(resetAnimationHistory: true)
        cancelLiveHighlightTasks()
        _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")

        let preparedKey = prepared.page.key.trimmingCharacters(in: .whitespacesAndNewlines)
        let alreadyVisible = await waitForPlaybackKeyStable(
            preparedKey,
            reason: "activate-prepared-visible",
            phase: "current"
        )
        if alreadyVisible {
            KindleRunLog.write("KINDLE activate prepared visible-skip key=\(Self.keyLog(preparedKey))")
        } else if !(await restorePlaybackKeyVisibility(preparedKey, reason: "activate-prepared", maxSteps: 10)) {
            KindleRunLog.write("KINDLE activate prepared visibility-soft-miss key=\(Self.keyLog(preparedKey))")
            #if DEBUG
            NSLog("CRDBG KINDLE activate prepared visibility soft miss key=%@",
                  Self.keyLog(preparedKey))
            #endif
        }
        try await waitForKindleImageStable()

        let previousKey = oldKey.nilIfEmpty ?? lastActivatedBlobKey
        var activatedPage = prepared.page
        var activatedDocument = prepared.document
        var actualLiveKey: String
        do {
            actualLiveKey = try await installLiveOverlay(page: activatedPage, document: activatedDocument)
        } catch {
            let visibleKey = normalizedPageKey(await currentVisibleKindlePageKey())
            let recaptureTarget = visibleKey.nilIfEmpty ?? preparedKey.nilIfEmpty
            KindleRunLog.write("KINDLE activate prepared overlay-recapture key=\(Self.keyLog(preparedKey)) visible=\(Self.keyLog(visibleKey)) target=\(Self.keyLog(recaptureTarget ?? "")) error=\(error.localizedDescription)")
            let recapturedPage = try await captureVisiblePage(pageIndex: 0, targetKey: recaptureTarget)
            let recapturedDocument = makeLiveDocument(from: recapturedPage)
            actualLiveKey = try await installLiveOverlay(page: recapturedPage, document: recapturedDocument)
            activatedPage = recapturedPage
            activatedDocument = recapturedDocument
            KindleRunLog.write("KINDLE activate prepared overlay-recapture-ready requested=\(Self.keyLog(preparedKey)) actual=\(Self.keyLog(actualLiveKey)) session=\(recapturedPage.sessionId)")
        }
        liveDocument = activatedDocument
        livePage = activatedPage
        livePageKey = actualLiveKey
        let requestedStart = startOverride ?? prepared.startParagraphIndex
        if let requestedStart,
           activatedDocument.paragraphs.contains(where: { $0.id == requestedStart }) {
            liveStartParagraphIndex = requestedStart
        } else {
            liveStartParagraphIndex = firstReadableParagraph(in: activatedDocument)
        }
        liveStartIndexKind = startKindOverride ?? .sourceParagraph
        liveVisibleTopNorm = 0
        liveVisibleBottomNorm = 1
        resetViewModels(document: activatedDocument)
        store.updateProgress(bookID: book.id, pageKey: activatedPage.key, url: activatedPage.url, progressLabel: activatedPage.progress)
        markBlobTransition(
            source: "activate-prepared",
            oldKey: previousKey,
            expectedKey: activatedPage.key,
            actualKey: actualLiveKey
        )
        statusText = AppLocalized("下一页 Kindle 页面已就绪。")
        #if DEBUG
        NSLog("CRDBG KINDLE page preload consumed oldKey=%@ requested=%@ actual=%@ start=%d",
              Self.keyLog(oldKey),
              Self.keyLog(activatedPage.key),
              Self.keyLog(actualLiveKey),
              liveStartParagraphIndex ?? -1)
        #endif
        KindleRunLog.write("KINDLE read preload consumed old=\(Self.keyLog(oldKey)) requested=\(Self.keyLog(activatedPage.key)) actual=\(Self.keyLog(actualLiveKey)) start=\(liveStartParagraphIndex ?? -1) override=\(startOverride ?? -1)")
        return activatedDocument
    }

    private func generateDetachedTTSSegments(
        paragraphIndex: Int,
        text: String,
        language: String,
        voiceOverride: String? = nil
    ) async throws -> [AudioSegment] {
        let voice = voiceOverride ?? AppSettings.shared.voice(for: language)
        return try await TTSService.shared.generatePrefetchSegments(
            paragraphIndex: paragraphIndex,
            text: text,
            voice: voice,
            speed: 1.0,
            language: language
        )
    }

    private func nextVisualSyncSequence() -> UInt64 {
        visualSyncSequence &+= 1
        return visualSyncSequence
    }

    private var isContinuousReadVisualTransition: Bool {
        continuousReadHandoff != nil &&
            (continuousReadTurnTask != nil || continuousReadStagedPage != nil)
    }

    private func enqueueHighlightWord(paragraphIndex: Int, wordIndex: Int) {
        guard !isContinuousReadVisualTransition else { return }
        let sequence = nextVisualSyncSequence()
        visualSyncTask?.cancel()
        visualSyncTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.highlightWord(paragraphIndex: paragraphIndex, wordIndex: wordIndex, sequence: sequence)
        }
    }

    private func enqueueHighlightWordRange(paragraphIndex: Int, range: Range<Int>) {
        guard !isContinuousReadVisualTransition else { return }
        let sequence = nextVisualSyncSequence()
        visualSyncTask?.cancel()
        visualSyncTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await self.highlightWordRange(paragraphIndex: paragraphIndex, range: range, sequence: sequence)
        }
    }

    private func highlightWordRange(paragraphIndex: Int, range: Range<Int>, sequence: UInt64) async {
        guard !range.isEmpty, isCurrentVisualSequence(sequence) else { return }
        // A refocus projection describes the pixels currently visible after an
        // expand/orientation change, so it must win over the older preload
        // queue. Resolve every word instead of extrapolating a union range from
        // two possibly missing endpoints (the Japanese segment failure).
        let mappedRoutes: [KindleRenderRoute] = range.compactMap { wordIndex in
            refocusWordRoutes["\(paragraphIndex)#\(wordIndex)"]
                ?? textQueue?.wordRoutes["\(paragraphIndex)#\(wordIndex)"]
        }
        let anchorRoute = mappedRoutes.first
        let compatibleRoutes: [KindleRenderRoute]
        if let anchorRoute {
            compatibleRoutes = mappedRoutes.filter {
                $0.slot == anchorRoute.slot && $0.overlayParagraphID == anchorRoute.overlayParagraphID
            }
        } else {
            compatibleRoutes = []
        }
        let overlayParagraph = anchorRoute?.overlayParagraphID ?? paragraphIndex
        let start = compatibleRoutes.map(\.overlayWordIndex).min() ?? range.lowerBound
        let end = (compatibleRoutes.map(\.overlayWordIndex).max().map { $0 + 1 }) ?? range.upperBound
        if let anchorRoute {
            await switchRenderPageIfNeeded(to: anchorRoute.slot)
        }
        guard isCurrentVisualSequence(sequence) else { return }
        do {
            let result = try await evaluateJSON(
                "window.__crKindleLiveHighlightWords && window.__crKindleLiveHighlightWords(\(overlayParagraph), \(start), \(end), \(sequence))"
            )
            guard Self.boolValue(result["ok"]) else {
                throw KindleBookError.overlayFailed(result["reason"] as? String ?? "segment-highlight-failed")
            }
            KindleRunLog.write("KINDLE_HIGHLIGHT p=\(paragraphIndex) mode=segment words=\(range.count) routed=\(compatibleRoutes.count) rects=\(Self.int(from: result["rects"]) ?? 0)")
        } catch {
            KindleRunLog.write("KINDLE read segment highlight error p=\(paragraphIndex) range=\(range.lowerBound)..<\(range.upperBound) error=\(error.localizedDescription)")
            if requiresImmediateVisualSync {
                // Projection mismatch is recoverable and must never destroy the
                // VM/TTS queue. Pause at the same audio item, rebuild routes from
                // the visible pixels, then resume the exact item.
                let audio = AudioPlayerService.shared
                let shouldResume = audio.isPlaying
                audio.pause()
                await refocusPlaybackPosition(reason: "highlight-recovery")
                if shouldResume,
                   audio.currentBookId == book.id,
                   readVM != nil {
                    audio.play()
                }
                KindleRunLog.write("KINDLE read segment highlight recovered p=\(paragraphIndex) resumed=\(shouldResume ? "Y" : "N")")
            } else {
                deferVisualSyncUntilForeground(reason: "segment-highlight-unavailable")
            }
        }
    }

    private func resetVisualPositionForParagraph(_ paragraphIndex: Int) async {
        guard mode == .read, paragraphIndex >= 0 else { return }
        KindleRunLog.write("KINDLE read paragraph-reset deferred-to-highlight key=\(Self.keyLog(livePageKey ?? "")) p=\(paragraphIndex)")
    }

    private func scrollToParagraph(_ paragraphIndex: Int, force: Bool = false) async {
        if let route = Self.firstRenderRoute(in: refocusWordRoutes, paragraphIndex: paragraphIndex) {
            await switchRenderPageIfNeeded(to: route.slot)
            #if DEBUG
            NSLog("CRDBG KINDLE paragraph scroll page-only refocus-route key=%@ p=%d slot=%@",
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex,
                  route.slot.logName)
            #endif
            return
        } else if let route = renderRoute(forParagraph: paragraphIndex, charRange: nil) {
            await switchRenderPageIfNeeded(to: route.slot)
            #if DEBUG
            NSLog("CRDBG KINDLE paragraph scroll page-only route key=%@ p=%d slot=%@",
                  Self.keyLog(livePageKey ?? ""),
                  paragraphIndex,
                  route.slot.logName)
            #endif
            return
        }
        #if DEBUG
        NSLog("CRDBG KINDLE paragraph scroll ignored page-only key=%@ p=%d force=%@",
              Self.keyLog(livePageKey ?? ""),
              paragraphIndex,
              force ? "true" : "false")
        #endif
    }

    private func renderRoute(forParagraph paragraphIndex: Int, charRange: Range<Int>?) -> KindleRenderRoute? {
        guard let queue = textQueue,
              let paragraph = queue.document.paragraphs.first(where: { $0.id == paragraphIndex }) else {
            return nil
        }
        let routesForParagraph = queue.wordRoutes
            .compactMap { key, value -> (Int, KindleRenderRoute)? in
                guard key.hasPrefix("\(paragraphIndex)#"),
                      let suffix = key.split(separator: "#").last,
                      let index = Int(suffix) else { return nil }
                return (index, value)
            }
            .sorted { $0.0 < $1.0 }
        if charRange == nil,
           let activeRoute = routesForParagraph.first(where: { $0.1.slot == activeReadPageSlot })?.1 {
            return activeRoute
        }
        let wordIndex = routedWordIndex(in: paragraph, charRange: charRange)
        if let wordIndex,
           let route = queue.wordRoutes["\(paragraphIndex)#\(wordIndex)"] {
            return route
        }
        return routesForParagraph.first?.1
    }

    private func routedWordIndex(in paragraph: ReadingParagraph, charRange: Range<Int>?) -> Int? {
        guard !paragraph.words.isEmpty else { return nil }
        guard let charRange else { return paragraph.words.indices.first }

        let text = paragraph.text
        var cursor = text.startIndex
        for (index, word) in paragraph.words.enumerated() {
            let raw = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            if let range = text.range(of: raw, options: [], range: cursor..<text.endIndex) {
                let start = text.distance(from: text.startIndex, to: range.lowerBound)
                let end = text.distance(from: text.startIndex, to: range.upperBound)
                if end > charRange.lowerBound && start < charRange.upperBound {
                    return index
                }
                cursor = range.upperBound
            }
        }
        return paragraph.words.indices.first
    }

    private func pushMarks(_ marks: [ResolvedMark], force: Bool = false) async {
        guard mode == .explain else { return }
        if marks.isEmpty {
            clearKindleMarkState(resetAnimationHistory: false)
            _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()")
            return
        }
        if force {
            clearKindleMarkState(resetAnimationHistory: false)
            _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()")
        }
        for mark in marks {
            let markId = mark.id.uuidString
            guard !shownMarkIds.contains(markId) else { continue }
            let shouldAnimate = !animatedMarkIds.contains(markId)
            if let explainVM,
               let paragraph = explainVM.document.paragraphs.first(where: { $0.id == mark.paragraphIndex }) {
                recordPlaybackAnchor(
                    mode: .explain,
                    document: explainVM.document,
                    paragraphIndex: mark.paragraphIndex,
                    wordIndex: routedWordIndex(in: paragraph, charRange: mark.charRange),
                    charRange: mark.charRange
                )
            }
            let refocusRoute: KindleRenderRoute? = {
                guard let explainVM,
                      let paragraph = explainVM.document.paragraphs.first(where: { $0.id == mark.paragraphIndex }),
                      let wordIndex = routedWordIndex(in: paragraph, charRange: mark.charRange) else {
                    return Self.firstRenderRoute(in: refocusWordRoutes, paragraphIndex: mark.paragraphIndex)
                }
                return Self.nearestRenderRoute(in: refocusWordRoutes, paragraphIndex: mark.paragraphIndex, wordIndex: wordIndex)
                    ?? Self.firstRenderRoute(in: refocusWordRoutes, paragraphIndex: mark.paragraphIndex)
            }()
            let route = refocusRoute ?? renderRoute(forParagraph: mark.paragraphIndex, charRange: mark.charRange)
            if let route, refocusRoute == nil {
                await switchRenderPageIfNeeded(to: route.slot)
            }
            var payload: [String: Any] = [
                "id": markId,
                "paragraphIndex": route?.overlayParagraphID ?? mark.paragraphIndex,
                "charStart": mark.charRange.lowerBound,
                "charEnd": mark.charRange.upperBound,
                "action": mark.action,
                "seed": Int(truncatingIfNeeded: mark.seed & 0xFFFFFFFF),
                "animate": shouldAnimate
            ]
            if let n = mark.n { payload["n"] = n }
            if let weight = mark.weight { payload["weight"] = weight }
            if let role = mark.role { payload["role"] = role }
            if let json = try? jsonString(payload) {
                let result = try? await evaluateJSON("window.__crKindleLiveShowMark && window.__crKindleLiveShowMark(\(json))")
                if result?["ok"] as? Bool == true {
                    shownMarkIds.insert(markId)
                    animatedMarkIds.insert(markId)
                    KindleRunLog.write("KINDLE mark draw ok id=\(markId.prefix(8)) animate=\(shouldAnimate) p=\(mark.paragraphIndex) result=\(String(describing: result ?? [:]))")
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 80_000_000)
                        guard let self, self.mode == .explain else { return }
                        await self.scrollToMark(payloadJSON: json, mark: mark, route: route)
                    }
                } else {
                    KindleRunLog.write("KINDLE mark draw miss id=\(markId.prefix(8)) animate=\(shouldAnimate) p=\(mark.paragraphIndex) result=\(String(describing: result ?? [:]))")
                }
            }
        }
    }

    private func scrollToMark(payloadJSON: String, mark: ResolvedMark, route: KindleRenderRoute?) async {
        #if DEBUG
        NSLog("CRDBG KINDLE mark scroll disabled page-only key=%@ p=%d",
              Self.keyLog(livePageKey ?? ""),
              route?.overlayParagraphID ?? mark.paragraphIndex)
        #endif
    }

    private func paragraphPayload(_ paragraph: ReadingParagraph) -> [String: Any] {
        var payload: [String: Any] = [
            "id": paragraph.id,
            "text": paragraph.text,
            "words": paragraph.words.map { wordPayload($0) }
        ]
        if let bbox = paragraph.bboxNorm {
            payload["bboxNorm"] = rectPayload(bbox)
        }
        payload["visualFragments"] = paragraph.visualFragments.map { fragment in
            [
                "column": fragment.column.rawValue,
                "bboxNorm": rectPayload(fragment.bboxNorm),
                "wordIDs": fragment.wordIDs
            ] as [String: Any]
        }
        return payload
    }

    private func wordPayload(_ word: OCRWord) -> [String: Any] {
        [
            "id": word.id,
            "text": word.text,
            "bboxNorm": rectPayload(word.bboxNorm)
        ]
    }

    private func rectPayload(_ rect: CGRect) -> [String: Double] {
        [
            "x": rect.origin.x,
            "y": rect.origin.y,
            "width": rect.size.width,
            "height": rect.size.height
        ]
    }

    private func jsonString(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let string = String(data: data, encoding: .utf8) else { throw KindleBookError.invalidPayload }
        return string
    }

    func follow(coordinator: PlayerCoordinator, document: ReadingDocument) {
        stopFollowing()
        lastSyncedPageIndex = nil
        guard let session = coordinator.session, session.id == document.id else { return }

        session.readVM.$currentParagraphIndex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] idx in
                self?.syncToParagraph(idx, document: document)
            }
            .store(in: &cancellables)

        session.explainVM.$scrollTarget
            .receive(on: DispatchQueue.main)
            .sink { [weak self] idx in
                self?.syncToParagraph(idx, document: document)
            }
            .store(in: &cancellables)
    }

    func stopFollowing() {
        cancellables.removeAll()
    }

    private func syncToParagraph(_ paragraphIndex: Int, document: ReadingDocument) {
        guard paragraphIndex >= 0,
              paragraphIndex < document.paragraphs.count,
              let pageIndex = document.paragraphs[paragraphIndex].pageIndex,
              pageIndex != lastSyncedPageIndex else { return }
        lastSyncedPageIndex = pageIndex
        guard let key = pageKeysByDocumentID[document.id]?[pageIndex], !key.isEmpty else { return }
        Task {
            _ = try? await scrollToKey(key)
            store.updateProgress(bookID: book.id, pageKey: key, url: webView.url?.absoluteString)
        }
    }

    private func load(_ raw: String, reason: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? trimmed
        guard let url = URL(string: trimmed) ?? URL(string: encoded) ?? URL(string: KindleWebScripts.libraryURL.absoluteString) else {
            KindleRunLog.write("KINDLE webview load failed-invalid reason=\(reason) raw=\(Self.keyLog(raw))")
            return
        }
        KindleRunLog.write("KINDLE webview load reason=\(reason) raw=\(Self.keyLog(raw)) url=\(url.absoluteString) last=\(Self.keyLog(book.lastReadURL ?? ""))")
        webView.load(URLRequest(url: url))
    }

    private func installCaptureScript() {
        webView.evaluateJavaScript(KindleWebScripts.metadataBootstrap, completionHandler: nil)
        webView.evaluateJavaScript(KindleWebScripts.pageCaptureBootstrap, completionHandler: nil)
    }

    @discardableResult
    private func ensureCaptureScriptInstalled(reason: String) async throws -> [String: Any] {
        let script = """
        (function() {
          try {
            \(KindleWebScripts.metadataBootstrap)
            \(KindleWebScripts.pageCaptureBootstrap)
          } catch (e) {
            return JSON.stringify({
              ok:false,
              reason:'install-error:' + String(e),
              turn:false,
              state:false,
              url:location.href
            });
          }
          var turnReady = typeof window.__crKindleTurnPage === 'function';
          var stateReady = typeof window.__crKindleState === 'function';
          return JSON.stringify({
            ok:turnReady && stateReady,
            reason:(turnReady && stateReady) ? '' : 'missing-functions',
            turn:turnReady,
            state:stateReady,
            installedVersion:window.__crKindleInstalledVersion || 0,
            url:location.href
          });
        })()
        """
        let result = try await evaluateJSON(script)
        let ok = Self.boolValue(result["ok"])
        KindleRunLog.write("KINDLE script install reason=\(reason) ok=\(ok) turn=\(String(describing: result["turn"] ?? false)) state=\(String(describing: result["state"] ?? false)) version=\(String(describing: result["installedVersion"] ?? 0)) jsReason=\(String(describing: result["reason"] ?? ""))")
        guard ok else {
            throw KindleBookError.captureFailed("kindle-script-not-ready:\(result["reason"] as? String ?? "unknown")")
        }
        return result
    }

    private func setKindlePageModeLockedLightweight(_ locked: Bool, reason: String) async {
        let flag = locked ? "true" : "false"
        let script = """
        \(KindleWebScripts.pageModeLockBootstrap)
        window.__crKindleSetPageModeLocked && window.__crKindleSetPageModeLocked(\(flag))
        """
        do {
            let result = try await evaluateJSON(script)
            KindleRunLog.write("KINDLE page mode light-lock reason=\(reason) locked=\(String(describing: result["locked"] ?? false)) blocked=\(String(describing: result["blocked"] ?? 0)) allowed=\(String(describing: result["allowed"] ?? 0))")
        } catch {
            KindleRunLog.write("KINDLE page mode light-lock error reason=\(reason) \(error.localizedDescription)")
        }
    }

    private func setKindlePageModeLocked(_ locked: Bool) async {
        let flag = locked ? "true" : "false"
        let script = """
        (function() {
          if (window.__crKindleSetPageModeLocked) {
            return window.__crKindleSetPageModeLocked(\(flag));
          }
          window.__crKindleProbe = window.__crKindleProbe || {};
          window.__crKindleProbe.pageModeLocked = \(flag);
          window.__crKindleProbe.programmaticScrollUntil = window.__crKindleProbe.programmaticScrollUntil || 0;
          window.__crKindleProbe.manualScrollRestoreRaf = window.__crKindleProbe.manualScrollRestoreRaf || 0;
          window.__crKindleProbe.navigationSeq = window.__crKindleProbe.navigationSeq || 0;
          window.__crKindleProbe.navigationAt = window.__crKindleProbe.navigationAt || 0;
          window.__crKindleProbe.navigationReason = window.__crKindleProbe.navigationReason || '';
          return JSON.stringify({ ok:true, locked:!!window.__crKindleProbe.pageModeLocked, url:location.href });
        })()
        """
        do {
            let result = try await evaluateJSON(script)
            KindleRunLog.write("KINDLE page mode lock=\(String(describing: result["locked"] ?? false))")
        } catch {
            KindleRunLog.write("KINDLE page mode lock error \(error.localizedDescription)")
        }
    }

    private func waitForPageReady() async throws {
        for _ in 0..<12 {
            installCaptureScript()
            if let state = try? await evaluateJSON("window.__crKindleState && window.__crKindleState()"),
               (state["heldKeys"] as? Int ?? 0) > 0 || !(state["key"] as? String ?? "").isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func waitForKindleImageStable() async throws {
        var previousSignature: String?
        var stableHits = 0
        for attempt in 0..<24 {
            installCaptureScript()
            if let state = try? await evaluateJSON("window.__crKindleState && window.__crKindleState()"),
               let rect = state["rect"] as? [String: Any] {
                let key = (state["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let orderedCount = Self.int(from: state["orderedCount"]) ?? 0
                let visibleArea = Self.numberValue(state["visibleArea"]) ?? 0
                let bandVisibleArea = Self.numberValue(state["bandVisibleArea"]) ?? 0
                guard !key.isEmpty, orderedCount > 0, max(visibleArea, bandVisibleArea) > 0 else {
                    previousSignature = nil
                    stableHits = 0
                    KindleRunLog.write("KINDLE layout stable wait-empty attempt=\(attempt + 1) key=\(Self.keyLog(key)) ordered=\(orderedCount) visible=\(visibleArea) band=\(bandVisibleArea)")
                    try await Task.sleep(nanoseconds: 180_000_000)
                    continue
                }
                let signature = [
                    String(describing: state["viewportWidth"] ?? ""),
                    String(describing: state["viewportHeight"] ?? ""),
                    key,
                    String(describing: rect["left"] ?? ""),
                    String(describing: rect["top"] ?? ""),
                    String(describing: rect["width"] ?? ""),
                    String(describing: rect["height"] ?? ""),
                    String(describing: orderedCount),
                    state["ordered"] as? String ?? ""
                ].joined(separator: "|")
                if signature == previousSignature {
                    stableHits += 1
                    if stableHits >= 3 {
                        #if DEBUG
                        NSLog("CRDBG KINDLE layout stable attempt=%d sig=%@",
                              attempt + 1,
                              signature)
                        #endif
                        return
                    }
                } else {
                    previousSignature = signature
                    stableHits = 0
                }
            }
            try await Task.sleep(nanoseconds: 160_000_000)
        }
        #if DEBUG
        NSLog("CRDBG KINDLE layout stable timeout")
        #endif
    }

    private func alignCurrentReadingPageToTop() async throws -> String? {
        let result = try await evaluateJSON("window.__crKindleAlignBestPageToTop && window.__crKindleAlignBestPageToTop()")
        #if DEBUG
        NSLog("CRDBG KINDLE align current result=%@",
              String(describing: result))
        #endif
        guard result["ok"] as? Bool == true else { return nil }
        return (result["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func captureVisiblePage(pageIndex: Int, targetKey: String? = nil) async throws -> CapturedKindlePage {
        var lastReason = "no-visible-kindle-image"
        for _ in 0..<10 {
            let trimmedTarget = targetKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let script: String
            if trimmedTarget.isEmpty {
                script = "window.__crKindleCurrentPageSnapshot && window.__crKindleCurrentPageSnapshot(\(Self.ocrCaptureJavaScriptArguments))"
            } else {
                let escapedTarget = trimmedTarget
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                script = "window.__crKindlePageSnapshotForKey && window.__crKindlePageSnapshotForKey('\(escapedTarget)', \(Self.ocrCaptureJavaScriptArguments))"
            }
            let payload = try await evaluateJSON(script)
            if payload["ok"] as? Bool == true {
                #if DEBUG
                let rect = payload["pageRect"] as? [String: Any] ?? [:]
                NSLog("CRDBG KINDLE capture key=%@ target=%@ session=%@ kind=%@ visible=%@..%@ rect=%@,%@ %@x%@ area=%@ band=%@",
                      Self.keyLog(payload["key"] as? String ?? ""),
                      Self.keyLog(trimmedTarget),
                      String(describing: payload["sessionId"] ?? "?"),
                      payload["kind"] as? String ?? "",
                      String(describing: payload["visibleTopNorm"] ?? "?"),
                      String(describing: payload["visibleBottomNorm"] ?? "?"),
                      String(describing: rect["left"] ?? "?"),
                      String(describing: rect["top"] ?? "?"),
                      String(describing: rect["width"] ?? "?"),
                      String(describing: rect["height"] ?? "?"),
                      String(describing: payload["visibleArea"] ?? "?"),
                      String(describing: payload["bandVisibleArea"] ?? "?"))
                #endif
                return try await makeCapturedPage(from: payload, pageIndex: pageIndex)
            }
            lastReason = payload["reason"] as? String ?? lastReason
            try await Task.sleep(nanoseconds: 350_000_000)
        }
        throw KindleBookError.captureFailed(lastReason)
    }

    private func captureNearbyPage(offset: Int) async throws -> CapturedKindlePage {
        var lastReason = "no-nearby-kindle-image"
        for _ in 0..<5 {
            let payload = try await evaluateJSON("window.__crKindleCandidateSnapshotNearCurrent && window.__crKindleCandidateSnapshotNearCurrent(\(offset), \(Self.ocrCaptureJavaScriptArguments))")
            if payload["ok"] as? Bool == true {
                #if DEBUG
                let rect = payload["pageRect"] as? [String: Any] ?? [:]
                NSLog("CRDBG KINDLE nearby capture offset=%d key=%@ idx=%@/%@ rect=%@,%@ %@x%@ ordered=%@",
                      offset,
                      Self.keyLog(payload["key"] as? String ?? ""),
                      String(describing: payload["targetIndex"] ?? "?"),
                      String(describing: payload["currentIndex"] ?? "?"),
                      String(describing: rect["left"] ?? "?"),
                      String(describing: rect["top"] ?? "?"),
                      String(describing: rect["width"] ?? "?"),
                      String(describing: rect["height"] ?? "?"),
                      String(describing: payload["ordered"] ?? ""))
                #endif
                return try await makeCapturedPage(from: payload, pageIndex: 0)
            }
            lastReason = payload["reason"] as? String ?? lastReason
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        throw KindleBookError.captureFailed(lastReason)
    }

    private func captureNextPage(afterKey: String) async throws -> CapturedKindlePage {
        installCaptureScript()
        await setKindlePageModeLocked(true)
        let escapedKey = afterKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        var lastReason = "no-next-candidate"
        for attempt in 0..<6 {
            let payload = try await evaluateJSON("window.__crKindleNextPageSnapshot && window.__crKindleNextPageSnapshot('\(escapedKey)', \(Self.ocrCaptureJavaScriptArguments))")
            if payload["ok"] as? Bool == true {
                #if DEBUG
                let rect = payload["pageRect"] as? [String: Any] ?? [:]
                NSLog("CRDBG KINDLE preload capture after=%@ key=%@ session=%@ kind=%@ rect=%@,%@ %@x%@ ordered=%@",
                      Self.keyLog(afterKey),
                      Self.keyLog(payload["key"] as? String ?? ""),
                      String(describing: payload["sessionId"] ?? "?"),
                      payload["kind"] as? String ?? "",
                      String(describing: rect["left"] ?? "?"),
                      String(describing: rect["top"] ?? "?"),
                      String(describing: rect["width"] ?? "?"),
                      String(describing: rect["height"] ?? "?"),
                      String(describing: payload["ordered"] ?? ""))
                #endif
                return try await makeCapturedPage(from: payload, pageIndex: 0)
            }
            lastReason = payload["reason"] as? String ?? lastReason
            #if DEBUG
            NSLog("CRDBG KINDLE preload capture wait attempt=%d after=%@ reason=%@ ordered=%@",
                  attempt + 1,
                  Self.keyLog(afterKey),
                  lastReason,
                  String(describing: payload["ordered"] ?? ""))
            #endif
            try await Task.sleep(nanoseconds: 260_000_000)
        }
        throw KindleBookError.captureFailed(lastReason)
    }

    private func captureCandidatePages(afterKey: String, limit: Int) async throws -> [CapturedKindlePage] {
        installCaptureScript()
        await setKindlePageModeLocked(true)
        let escapedKey = afterKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let boundedLimit = max(1, min(8, limit))
        let payload = try await evaluateJSON("window.__crKindleCandidateSnapshotsAfterKey && window.__crKindleCandidateSnapshotsAfterKey('\(escapedKey)', \(boundedLimit), \(Self.ocrCaptureJavaScriptArguments))")
        let rawPages = payload["pages"] as? [[String: Any]] ?? []
        var pages: [CapturedKindlePage] = []
        var seen = Set<String>()
        for raw in rawPages {
            try Task.checkCancellation()
            guard raw["ok"] as? Bool == true else { continue }
            let key = (raw["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty, key != afterKey, !seen.contains(key) else { continue }
            let page = try await makeCapturedPage(from: raw, pageIndex: pages.count)
            try Task.checkCancellation()
            guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            seen.insert(key)
            pages.append(page)
        }
        if !pages.isEmpty {
            let orderedKeys = (payload["orderedKeys"] as? [String] ?? []).map(Self.keyLog).joined(separator: ",")
            KindleRunLog.write("KINDLE preload multi-capture after=\(Self.keyLog(afterKey)) pages=\(pages.map { Self.keyLog($0.key) }.joined(separator: ",")) held=\(String(describing: payload["heldCount"] ?? "")) ordered=\(orderedKeys)")
            return pages
        }

        let reason = payload["reason"] as? String ?? "no-candidate-pages"
        let heldCount = String(describing: payload["heldCount"] ?? "")
        let afterHeldIndex = String(describing: payload["afterHeldIndex"] ?? "")
        let orderedKeys = (payload["orderedKeys"] as? [String] ?? []).map(Self.keyLog).joined(separator: ",")
        KindleRunLog.write("KINDLE preload multi-capture miss after=\(Self.keyLog(afterKey)) reason=\(reason) held=\(heldCount) afterHeldIndex=\(afterHeldIndex) ordered=\(orderedKeys)")
        return [try await captureNextPage(afterKey: afterKey)]
    }

    private func makeCapturedPage(from payload: [String: Any], pageIndex: Int) async throws -> CapturedKindlePage {
        let decodeStartedAt = Date()
        guard let dataURL = payload["image"] as? String,
              let imageData = Self.decodeDataURL(dataURL),
              let image = UIImage(data: imageData) else {
            throw KindleBookError.badImage
        }
        let decodeMs = max(0, Int(Date().timeIntervalSince(decodeStartedAt) * 1000))

        try Task.checkCancellation()
        let ocrStartedAt = Date()
        let recognized = try await recognizeKindlePage(image: image, imageData: imageData)
        let ocrMs = max(0, Int(Date().timeIntervalSince(ocrStartedAt) * 1000))
        try Task.checkCancellation()
        var ocrDoc = recognized.document
        ocrDoc.sourceKind = .kindle
        let source = payload["source"] as? String ?? "unknown"
        let key = payload["key"] as? String ?? ""
        let afterKey = payload["afterKey"] as? String ?? ""
        let natural = payload["natural"] as? String ?? "?"
        let rendered = payload["rendered"] as? String ?? "?"
        let encoding = payload["ocrEncoding"] as? String ?? "unknown"
        let bitmapWidth = image.cgImage?.width ?? Int((image.size.width * image.scale).rounded())
        let bitmapHeight = image.cgImage?.height ?? Int((image.size.height * image.scale).rounded())
        let words = ocrDoc.paragraphs.reduce(0) { $0 + $1.words.count }
        let dataKb = max(1, (imageData.count + 1023) / 1024)
        KindleRunLog.write("KINDLE OCR snapshot source=\(source) key=\(Self.keyLog(key)) after=\(Self.keyLog(afterKey)) natural=\(natural) rendered=\(rendered) bitmap=\(bitmapWidth)x\(bitmapHeight) encoding=\(encoding) dataKb=\(dataKb) decodeMs=\(decodeMs) ocrMs=\(ocrMs) layout=\(recognized.layout) paras=\(ocrDoc.paragraphs.count) words=\(words) chars=\(ocrDoc.fullText.count)")
        #if DEBUG
        Self.persistKindleOCRDebugFixture(
            imageData: imageData,
            document: ocrDoc,
            layout: recognized.layout,
            natural: natural,
            rendered: rendered,
            encoding: encoding
        )
        #endif
        return CapturedKindlePage(
            pageIndex: pageIndex,
            key: key,
            pixelFingerprint: payload["pixelFingerprint"] as? String,
            sessionId: Self.int(from: payload["sessionId"]) ?? 0,
            kind: payload["kind"] as? String ?? "",
            title: payload["title"] as? String ?? book.title,
            url: payload["url"] as? String ?? webView.url?.absoluteString,
            progress: payload["progress"] as? String,
            visibleTopNorm: Self.number(from: payload["visibleTopNorm"]) ?? 0,
            visibleBottomNorm: Self.number(from: payload["visibleBottomNorm"]) ?? 1,
            imageData: imageData,
            document: ocrDoc,
            text: ocrDoc.fullText,
            columnLayout: recognized.layout
        )
    }

    private func recognizeKindlePage(image: UIImage, imageData: Data) async throws -> (document: ReadingDocument, layout: String) {
        // Same authority order as the extension: renderer metadata first, then a
        // previously verified profile, finally independent single-locale OCR consensus.
        var profile = await rendererKindleLanguageProfile()
        if profile == nil, KindleLanguageContract.isVerified(language: book.language, source: book.languageSource) {
            profile = persistedKindleLanguageProfile()
        }
        if profile == nil {
            let probe = try await OCRService.shared.probeKindleLanguage(
                image: image,
                titleContext: [book.title, book.author].filter { !$0.isEmpty }.joined(separator: " ")
            )
            profile = KindleLanguageContract.profile(language: probe.language)
            if let profile {
                persistKindleLanguageProfile(profile, source: "ocr-consensus-v2")
                KindleRunLog.write("KINDLE_PROFILE_PROBE selected=\(profile.language) winningLocale=\(probe.visionLocale) chars=\(probe.readableCharacterCount) score=\(Int(probe.score))")
            }
        }
        guard let profile else {
            throw KindleBookError.captureFailed("unsupported-kindle-language")
        }
        guard profile.isSupported else {
            throw KindleBookError.verticalJapaneseUnsupported
        }
        let ocrRoute = KindleOCRRoutingContract.route(for: profile).engines.map(\.rawValue).joined(separator: ">")
        KindleRunLog.write("KINDLE_PROFILE asin=\(Self.keyLog(book.asin ?? book.id)) language=\(profile.language) ocrRoute=\(ocrRoute) ocrModel=\(profile.tesseractModel) ocrLocale=\(profile.visionLocale) reading=\(profile.readingDirection.rawValue) progressionFallback=\(profile.pageProgressionFallback.rawValue) writing=\(profile.writingMode.rawValue)")
        let layout = detectKindleColumnLayout(image)
        if layout.isDual,
           let split = splitKindleDualColumns(image) {
            let left = try? await OCRService.shared.recognizeKindle(
                image: split.left.image,
                profile: profile,
                title: book.title,
                paragraphStrategy: .kindleLayout,
                verticalColumnHints: kindleVerticalColumnHints
            )
            let right = try? await OCRService.shared.recognizeKindle(
                image: split.right.image,
                profile: profile,
                title: book.title,
                paragraphStrategy: .kindleLayout,
                verticalColumnHints: kindleVerticalColumnHints
            )

            var columns = [
                left.map { (document: $0, originX: split.left.originX, width: split.left.width) },
                right.map { (document: $0, originX: split.right.originX, width: split.right.width) }
            ].compactMap { $0 }
            if profile.readingDirection == .rtl { columns.reverse() }

            if !columns.isEmpty {
                let merged = mergeKindleColumnDocuments(
                    columns,
                    fullPixelWidth: split.fullWidth,
                    fullPixelHeight: split.fullHeight,
                    imageData: imageData,
                    language: profile.language
                )
                if hasReadableParagraphs(merged) {
                    try validateKindleWritingMode(profile: profile, document: merged)
                    return (merged, "dual:\(layout.reason)")
                }
            }

            KindleRunLog.write("KINDLE OCR dual fallback reason=\(layout.reason) left=\(left?.paragraphs.count ?? -1) right=\(right?.paragraphs.count ?? -1)")
        }

        var doc = try await OCRService.shared.recognizeKindle(
            image: image,
            profile: profile,
            title: book.title,
            paragraphStrategy: .kindleLayout,
            verticalColumnHints: kindleVerticalColumnHints
        )
        doc.sourceKind = .kindle
        doc.paragraphs = doc.paragraphs.map { paragraph in
            var paragraph = paragraph
            if paragraph.visualFragments.isEmpty,
               let bbox = paragraph.bboxNorm ?? unionNorm(for: paragraph.words) {
                paragraph.visualFragments = [OCRVisualFragment(
                    column: .single,
                    bboxNorm: bbox,
                    wordIDs: paragraph.words.map(\.id)
                )]
            }
            return paragraph
        }
        try validateKindleWritingMode(profile: profile, document: doc)
        return (doc, layout.isDual ? "single-fallback:\(layout.reason)" : "single:\(layout.reason)")
    }

    private func persistedKindleLanguageProfile() -> KindleLanguageProfile? {
        let writingMode = KindleWritingMode(rawValue: book.kindleWritingMode ?? "") ?? .horizontal
        let reading = KindleReadingDirection(rawValue: book.kindleReadingDirection ?? "")
        let progression = KindleReadingDirection(rawValue: book.kindlePageProgressionDirection ?? "")
        return KindleLanguageContract.profile(
            language: book.language,
            writingMode: writingMode,
            readingDirection: reading,
            pageProgressionDirection: progression
        )
    }

    private func rendererKindleLanguageProfile() async -> KindleLanguageProfile? {
        guard let payload = try? await evaluateJSON(KindleWebScripts.readMetadataProfile),
              let language = payload["language"] as? String else { return nil }
        kindleVerticalColumnHints = Self.verticalColumnHints(from: payload["verticalColumnHints"])
        var writingMode = KindleWritingMode(rawValue: payload["writingMode"] as? String ?? "") ?? .horizontal
        let tokenGeometry = payload["writingModeSource"] as? String == "token-geometry"
        var source = tokenGeometry ? "renderer-token-geometry" : "renderer-metadata"
        if writingMode == .vertical,
           !tokenGeometry,
           KindleLanguageContract.normalize(language) == KindleLanguageContract.normalize(book.language),
           book.languageSource == "renderer-metadata+geometry",
           book.kindleWritingMode == KindleWritingMode.horizontal.rawValue {
            writingMode = .horizontal
            source = "renderer-metadata+geometry"
        }
        let reading = KindleReadingDirection(rawValue: payload["readingDirection"] as? String ?? "")
        let progression = KindleReadingDirection(rawValue: payload["pageProgressionDirection"] as? String ?? "")
        guard let profile = KindleLanguageContract.profile(
            language: language,
            writingMode: writingMode,
            readingDirection: reading,
            pageProgressionDirection: progression
        ) else { return nil }
        KindleRunLog.write("KINDLE_PROFILE_RENDERER language=\(profile.language) writing=\(profile.writingMode.rawValue) source=\(source) verticalHints=\(kindleVerticalColumnHints.count)")
        persistKindleLanguageProfile(profile, source: source)
        return profile
    }

    private func persistKindleLanguageProfile(_ profile: KindleLanguageProfile, source: String) {
        book.language = profile.language
        book.languageSource = source
        book.kindleWritingMode = profile.writingMode.rawValue
        book.kindleReadingDirection = profile.readingDirection.rawValue
        book.kindlePageProgressionDirection = profile.pageProgressionFallback.rawValue
        store.updateLanguageProfile(
            bookID: book.id,
            language: profile.language,
            source: source,
            writingMode: profile.writingMode,
            readingDirection: profile.readingDirection,
            pageProgressionDirection: profile.pageProgressionFallback
        )
    }

    private func validateKindleWritingMode(profile: KindleLanguageProfile, document: ReadingDocument) throws {
        if profile.tesseractModel == "jpn_vert" {
            guard !kindleVerticalColumnHints.isEmpty else {
                throw KindleBookError.verticalJapaneseUnsupported
            }
            return
        }
        let sizes = document.paragraphs.compactMap { paragraph -> CGSize? in
            guard let bbox = paragraph.bboxNorm, bbox.width > 0, bbox.height > 0 else { return nil }
            return bbox.size
        }
        let geometryMode = KindleWritingModeContract.infer(from: sizes)
        guard let geometryMode, geometryMode != profile.writingMode,
              let corrected = KindleLanguageContract.profile(
                language: profile.language,
                writingMode: geometryMode,
                readingDirection: profile.readingDirection,
                pageProgressionDirection: profile.pageProgressionFallback
              ) else { return }
        KindleRunLog.write("KINDLE_PROFILE_GEOMETRY corrected=\(profile.writingMode.rawValue)->\(geometryMode.rawValue) language=\(profile.language) paras=\(sizes.count)")
        persistKindleLanguageProfile(corrected, source: "renderer-metadata+geometry")
    }

    private func makeDocument(from pages: [CapturedKindlePage]) -> ReadingDocument {
        var paragraphs: [ReadingParagraph] = []
        var nextParagraphID = 0
        var nextWordID = 0

        for page in pages {
            paragraphs.append(ReadingParagraph(
                id: nextParagraphID,
                text: "",
                type: .image,
                pageIndex: page.pageIndex,
                imageData: page.imageData
            ))
            nextParagraphID += 1

            for para in page.document.paragraphs where para.type.isReadable && SpeechTextSanitizer.containsSpeakableContent(para.text) {
                var wordIDMap: [Int: Int] = [:]
                let remappedWords = para.words.map { word -> OCRWord in
                    let newID = nextWordID
                    nextWordID += 1
                    wordIDMap[word.id] = newID
                    return OCRWord(id: newID, text: word.text, bboxNorm: word.bboxNorm)
                }
                paragraphs.append(ReadingParagraph(
                    id: nextParagraphID,
                    text: para.text,
                    type: para.type,
                    words: remappedWords,
                    bboxNorm: para.bboxNorm,
                    visualFragments: para.visualFragments.map {
                        OCRVisualFragment(column: $0.column, bboxNorm: $0.bboxNorm,
                                          wordIDs: $0.wordIDs.compactMap { wordIDMap[$0] })
                    },
                    pageIndex: page.pageIndex
                ))
                nextParagraphID += 1
            }
        }

        return ReadingDocument(
            title: "\(book.title) · Kindle",
            sourceKind: .kindle,
            language: pages.first?.document.language ?? Constants.TTS.defaultLanguage,
            paragraphs: paragraphs,
            sourceURL: book.readerURL
        )
    }

    private func makeLiveDocument(from page: CapturedKindlePage) -> ReadingDocument {
        var paragraphs: [ReadingParagraph] = []
        var nextParagraphID = 0
        var nextWordID = 0

        for para in page.document.paragraphs where para.type.isReadable && !para.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard !para.words.isEmpty else { continue }
            let paraText = para.text
            guard !paraText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let remappedWords = para.words.map { word -> OCRWord in
                defer { nextWordID += 1 }
                return OCRWord(id: nextWordID, text: word.text, bboxNorm: word.bboxNorm)
            }
            let remappedIDs = Dictionary(uniqueKeysWithValues: zip(para.words.map(\.id), remappedWords.map(\.id)))
            paragraphs.append(ReadingParagraph(
                id: nextParagraphID,
                text: paraText,
                type: para.type,
                words: remappedWords,
                bboxNorm: para.bboxNorm ?? unionNorm(for: remappedWords),
                visualFragments: para.visualFragments.map {
                    OCRVisualFragment(column: $0.column, bboxNorm: $0.bboxNorm,
                                      wordIDs: $0.wordIDs.compactMap { remappedIDs[$0] })
                },
                pageIndex: 0
            ))
            nextParagraphID += 1
        }
        #if DEBUG
        NSLog("CRDBG KINDLE live full-page paras=%d words=%d imageVisible=%.3f..%.3f",
              paragraphs.count,
              paragraphs.reduce(0) { $0 + $1.words.count },
              Double(page.visibleTopNorm),
              Double(page.visibleBottomNorm))
        #endif

        return ReadingDocument(
            title: book.title,
            sourceKind: .kindle,
            language: page.document.language,
            paragraphs: paragraphs,
            sourceURL: page.url ?? book.readerURL
        )
    }

    private struct KindleColumnDetection {
        let isDual: Bool
        let reason: String
    }

    private struct KindleColumnImage {
        let image: UIImage
        let originX: CGFloat
        let width: CGFloat
    }

    private struct KindleDualColumnSplit {
        let left: KindleColumnImage
        let right: KindleColumnImage
        let fullWidth: CGFloat
        let fullHeight: CGFloat
    }

    private func detectKindleColumnLayout(_ image: UIImage) -> KindleColumnDetection {
        guard let cg = image.cgImage else {
            return KindleColumnDetection(isDual: false, reason: "no-cg-image")
        }
        let width = CGFloat(cg.width)
        let height = CGFloat(cg.height)
        guard width > 0, height > 0 else {
            return KindleColumnDetection(isDual: false, reason: "empty-image")
        }
        let aspect = width / height
        guard let bands = sampleKindleColumnBands(cgImage: cg) else {
            return KindleColumnDetection(isDual: aspect > 1.35, reason: "aspect-fallback-\(String(format: "%.2f", Double(aspect)))")
        }
        let side = max(bands.leftText, bands.rightText)
        let balancedSides = min(bands.leftText, bands.rightText) > max(0.006, side * 0.28)
        let paleCenter = bands.center < 0.008 && bands.center < side * 0.32
        let dual = side > 0.012 && balancedSides && paleCenter
        let reason = String(
            format: "aspect=%.2f center=%.4f left=%.4f right=%.4f",
            Double(aspect),
            Double(bands.center),
            Double(bands.leftText),
            Double(bands.rightText)
        )
        return KindleColumnDetection(isDual: dual, reason: reason)
    }

    private func sampleKindleColumnBands(cgImage: CGImage) -> (center: CGFloat, leftText: CGFloat, rightText: CGFloat)? {
        let sampleWidth = 240
        let sampleHeight = max(90, Int((CGFloat(cgImage.height) / CGFloat(max(1, cgImage.width))) * CGFloat(sampleWidth)))
        let bytesPerPixel = 4
        let bytesPerRow = sampleWidth * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: sampleHeight * bytesPerRow)
        guard let context = CGContext(
            data: &pixels,
            width: sampleWidth,
            height: sampleHeight,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: sampleWidth, height: sampleHeight))

        func darkRatio(x0: CGFloat, x1: CGFloat, y0: CGFloat, y1: CGFloat) -> CGFloat {
            let sx0 = max(0, min(sampleWidth, Int(floor(CGFloat(sampleWidth) * x0))))
            let sx1 = max(0, min(sampleWidth, Int(ceil(CGFloat(sampleWidth) * x1))))
            let sy0 = max(0, min(sampleHeight, Int(floor(CGFloat(sampleHeight) * y0))))
            let sy1 = max(0, min(sampleHeight, Int(ceil(CGFloat(sampleHeight) * y1))))
            var dark = 0
            var total = 0
            guard sx1 > sx0, sy1 > sy0 else { return 0 }
            for y in stride(from: sy0, to: sy1, by: 2) {
                for x in stride(from: sx0, to: sx1, by: 2) {
                    let idx = y * bytesPerRow + x * bytesPerPixel
                    let r = CGFloat(pixels[idx])
                    let g = CGFloat(pixels[idx + 1])
                    let b = CGFloat(pixels[idx + 2])
                    let alpha = pixels[idx + 3]
                    if alpha < 16 { continue }
                    let lum = 0.299 * r + 0.587 * g + 0.114 * b
                    if lum < 190 { dark += 1 }
                    total += 1
                }
            }
            return total > 0 ? CGFloat(dark) / CGFloat(total) : 0
        }

        return (
            center: darkRatio(x0: 0.485, x1: 0.515, y0: 0.08, y1: 0.92),
            leftText: darkRatio(x0: 0.27, x1: 0.34, y0: 0.08, y1: 0.92),
            rightText: darkRatio(x0: 0.66, x1: 0.73, y0: 0.08, y1: 0.92)
        )
    }

    private func splitKindleDualColumns(_ image: UIImage) -> KindleDualColumnSplit? {
        guard let cg = image.cgImage else { return nil }
        let fullWidth = cg.width
        let fullHeight = cg.height
        guard fullWidth > 2, fullHeight > 2 else { return nil }
        let mid = fullWidth / 2
        let leftRect = CGRect(x: 0, y: 0, width: mid, height: fullHeight)
        let rightRect = CGRect(x: mid, y: 0, width: fullWidth - mid, height: fullHeight)
        guard let leftCG = cg.cropping(to: leftRect),
              let rightCG = cg.cropping(to: rightRect) else { return nil }
        return KindleDualColumnSplit(
            left: KindleColumnImage(
                image: UIImage(cgImage: leftCG, scale: image.scale, orientation: image.imageOrientation),
                originX: 0,
                width: CGFloat(mid)
            ),
            right: KindleColumnImage(
                image: UIImage(cgImage: rightCG, scale: image.scale, orientation: image.imageOrientation),
                originX: CGFloat(mid),
                width: CGFloat(fullWidth - mid)
            ),
            fullWidth: CGFloat(fullWidth),
            fullHeight: CGFloat(fullHeight)
        )
    }

    private func mergeKindleColumnDocuments(
        _ columns: [(document: ReadingDocument, originX: CGFloat, width: CGFloat)],
        fullPixelWidth: CGFloat,
        fullPixelHeight: CGFloat,
        imageData: Data,
        language: String
    ) -> ReadingDocument {
        var paragraphs: [ReadingParagraph] = []
        var nextParagraphID = 0
        var nextWordID = 0

        for (columnIndex, column) in columns.enumerated() {
            for paragraph in column.document.paragraphs where paragraph.type.isReadable {
                let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let words = paragraph.words.map { word -> OCRWord in
                    defer { nextWordID += 1 }
                    return OCRWord(
                        id: nextWordID,
                        text: word.text,
                        bboxNorm: remapColumnRectToFullPage(
                            word.bboxNorm,
                            originX: column.originX,
                            width: column.width,
                            fullWidth: fullPixelWidth
                        )
                    )
                }
                let paragraphBox = unionNorm(for: words) ?? paragraph.bboxNorm.map {
                    remapColumnRectToFullPage($0, originX: column.originX, width: column.width, fullWidth: fullPixelWidth)
                }
                let physicalColumn: OCRVisualFragment.Column = column.originX > 0 ? .right : .left
                let fragment = OCRVisualFragment(
                    column: physicalColumn,
                    bboxNorm: paragraphBox ?? .zero,
                    wordIDs: words.map(\.id)
                )
                paragraphs.append(ReadingParagraph(
                    id: nextParagraphID,
                    text: text,
                    type: paragraph.type,
                    words: words,
                    bboxNorm: paragraphBox,
                    visualFragments: [fragment],
                    pageIndex: 0
                ))
                nextParagraphID += 1
            }

            if columnIndex == 0, columns.count == 2,
               let boundary = paragraphs.indices.last {
                // Remember the logical boundary; after the second column is
                // appended it may be joined without losing either fragment.
                paragraphs[boundary].pageIndex = -1
            }
        }


        if let boundary = paragraphs.lastIndex(where: { $0.pageIndex == -1 }),
           paragraphs.indices.contains(boundary + 1),
           !KindleLanguageContract.endsWithHardTerminal(paragraphs[boundary].text) {
            let left = paragraphs[boundary]
            let right = paragraphs[boundary + 1]
            let mergedWords = left.words + right.words
            paragraphs[boundary] = ReadingParagraph(
                id: left.id,
                text: KindleLanguageContract.join([left.text, right.text], language: language),
                type: left.type,
                words: mergedWords,
                bboxNorm: unionNorm(for: mergedWords),
                visualFragments: left.visualFragments + right.visualFragments,
                pageIndex: 0
            )
            paragraphs.remove(at: boundary + 1)
        }
        paragraphs = paragraphs.enumerated().map { index, paragraph in
            var value = paragraph
            value.pageIndex = 0
            return ReadingParagraph(id: index, text: value.text, type: value.type, words: value.words,
                                    bboxNorm: value.bboxNorm, visualFragments: value.visualFragments, pageIndex: 0)
        }

        let joined = paragraphs.map(\.text).joined(separator: " ")
        return ReadingDocument(
            title: "\(book.title) · Kindle",
            sourceKind: .kindle,
            language: language,
            paragraphs: paragraphs,
            imageData: imageData,
            imagePixelSize: CGSize(width: fullPixelWidth, height: fullPixelHeight),
            sourceURL: book.readerURL
        )
    }

    private func remapColumnRectToFullPage(
        _ rect: CGRect,
        originX: CGFloat,
        width: CGFloat,
        fullWidth: CGFloat
    ) -> CGRect {
        guard fullWidth > 0, width > 0 else { return rect }
        let x = (originX + rect.minX * width) / fullWidth
        let w = rect.width * width / fullWidth
        return CGRect(
            x: max(0, min(1, x)),
            y: max(0, min(1, rect.minY)),
            width: max(0.001, min(1, w)),
            height: max(0.001, min(1, rect.height))
        )
    }

    private func firstReadableParagraph(in document: ReadingDocument) -> Int? {
        document.paragraphs.first {
            $0.type.isReadable && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.id
    }

    private func firstVisibleReadableParagraph(
        in document: ReadingDocument,
        visibleTopNorm: CGFloat,
        visibleBottomNorm: CGFloat
    ) -> Int? {
        let top = max(0, min(1, visibleTopNorm))
        let bottom = max(top, min(1, visibleBottomNorm))
        return document.paragraphs.first { paragraph in
            guard paragraph.type.isReadable,
                  !paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let bbox = paragraph.bboxNorm else { return false }
            let paraTop = max(0, min(1, 1 - bbox.maxY))
            let paraBottom = max(paraTop, min(1, 1 - bbox.minY))
            return paraBottom >= top && paraTop <= bottom
        }?.id
    }

    private func unionNorm(for words: [OCRWord]) -> CGRect? {
        guard let first = words.first else { return nil }
        var minX = first.bboxNorm.minX
        var minY = first.bboxNorm.minY
        var maxX = first.bboxNorm.maxX
        var maxY = first.bboxNorm.maxY
        for word in words.dropFirst() {
            minX = min(minX, word.bboxNorm.minX)
            minY = min(minY, word.bboxNorm.minY)
            maxX = max(maxX, word.bboxNorm.maxX)
            maxY = max(maxY, word.bboxNorm.maxY)
        }
        return CGRect(x: minX, y: minY, width: max(0.001, maxX - minX), height: max(0.001, maxY - minY))
    }

    private static func isReadableKindleParagraph(_ paragraph: ReadingParagraph) -> Bool {
        paragraph.type.isReadable &&
        SpeechTextSanitizer.containsSpeakableContent(paragraph.text) &&
        !paragraph.words.isEmpty
    }

    private static func refocusToken(_ text: String) -> String {
        let lowered = text.lowercased()
        let scalars = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar) ||
            CharacterSet.letters.contains(scalar) ||
            CharacterSet.decimalDigits.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private static func refocusTokensSimilar(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        if lhs == rhs { return true }
        if lhs.count >= 5 && rhs.count >= 5 {
            if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) { return true }
            let lPrefix = lhs.prefix(5)
            let rPrefix = rhs.prefix(5)
            return lPrefix == rPrefix
        }
        return false
    }

    private static func shouldMergeKindleContinuation(prev: String, next: String) -> Bool {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if p.isEmpty || n.isEmpty { return false }
        if isLikelyKindleHeading(p) || isLikelyKindleHeading(n) { return false }
        if endsWithKindleDash(p) { return true }
        if endsWithKindleHardTerminal(p) { return false }
        return true
    }

    private static func joinKindleContinuation(prev: String, next: String) -> String {
        let p = prev.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if endsWithKindleDash(p) {
            return normalizeKindleText(String(p.dropLast()) + n)
        }
        return normalizeKindleText("\(p) \(n)")
    }

    private static func normalizeKindleText(_ text: String) -> String {
        SpeechTextSanitizer.sanitizedForTTS(text)
    }

    private static func isKindleChunkTerminator(_ ch: Character) -> Bool {
        Set<Character>(".!?;:。！？；：…।॥").contains(ch)
    }

    private static func isKindleChunkSoftBreak(_ ch: Character) -> Bool {
        if Set<Character>(",，、").contains(ch) { return true }
        if Set<Character>("—–-").contains(ch) { return true }
        return String(ch).rangeOfCharacter(from: .whitespacesAndNewlines) != nil
    }

    private static func kindleChunkEndIncludingClosers(from index: Int, in chars: [Character]) -> Int {
        var end = min(chars.count, index + 1)
        let closers = Set<Character>("\"'”’)]}）】》")
        while end < chars.count, closers.contains(chars[end]) {
            end += 1
        }
        return end
    }

    private static func isLikelyKindleHeading(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        if t.range(of: #"^(chapter|book|part|contents)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        let letters = t.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let lowercase = t.unicodeScalars.filter { CharacterSet.lowercaseLetters.contains($0) }
        return t.count <= 90 && letters.count >= 5 && lowercase.isEmpty
    }

    private static func startsWithLowercaseLetter(_ text: String) -> Bool {
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            let s = String(scalar)
            return s == s.lowercased() && s != s.uppercased()
        }
        return false
    }

    private static func endsWithKindleDash(_ text: String) -> Bool {
        guard let scalar = text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.last else { return false }
        return Set("-‐‑‒–—―".unicodeScalars).contains(scalar)
    }

    private static func endsWithKindleHardTerminal(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"[.!?。！？…।॥]["')\]\u{201D}\u{2019}]*$"#, options: .regularExpression) != nil
    }

    private static func endsWithKindleSoftContinuationPunctuation(_ text: String) -> Bool {
        var scalars = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars)
        let closers = Set("\"')]\u{201D}\u{2019}".unicodeScalars)
        while let last = scalars.last, closers.contains(last) {
            scalars.removeLast()
        }
        guard let last = scalars.last else { return false }
        return Set(",;:–—".unicodeScalars).contains(last)
    }

    private func scrollForward() async throws {
        _ = try await scrollForward(fromVisibleBottom: nil, keepingKey: "")
    }

    @discardableResult
    private func scrollForward(fromVisibleBottom visibleBottom: CGFloat?, keepingKey key: String) async throws -> [String: Any] {
        let bottomArg = visibleBottom.map { String(format: "%.6f", Double($0)) } ?? "null"
        let escapedKey = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let script = "window.__crKindleLiveAdvanceScroll ? window.__crKindleLiveAdvanceScroll(\(bottomArg), '\(escapedKey)') : (window.__crKindleScroll && window.__crKindleScroll(Math.max(520, Math.floor((window.innerHeight || 700) * 0.82))))"
        let result = try await evaluateJSON(script)
        #if DEBUG
        NSLog("CRDBG KINDLE advance scroll bottom=%@ key=%@ result=%@",
              String(describing: visibleBottom),
              Self.keyLog(key),
              String(describing: result))
        #endif
        return result
    }

    @discardableResult
    private func scrollToKey(_ key: String, block: String = "nearest") async throws -> [String: Any] {
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let escapedBlock = block.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return try await evaluateJSON("window.__crKindleScrollToKey && window.__crKindleScrollToKey('\(escaped)', '\(escapedBlock)')")
    }

    private func playbackKeyVisibility(_ key: String) async throws -> [String: Any] {
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return try await evaluateJSON("window.__crKindleKeyVisibility && window.__crKindleKeyVisibility('\(escaped)')")
    }

    private func positionPlaybackKey(_ key: String) async throws -> [String: Any] {
        let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return try await evaluateJSON("window.__crKindlePositionKeyForPlayback && window.__crKindlePositionKeyForPlayback('\(escaped)')")
    }

    @discardableResult
    private func restorePlaybackKeyVisibility(
        _ rawKey: String,
        reason: String,
        maxSteps: Int
    ) async -> Bool {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }

        if await tryScrollToPlaybackKey(key, reason: reason, phase: "direct", attempt: 0) {
            if await waitForPlaybackKeyStable(key, reason: reason, phase: "direct") {
                return true
            }
        }

        guard Self.restoreShouldUseAnchor(reason: reason) else {
            KindleRunLog.write("KINDLE playback restore skip-anchor reason=\(reason) key=\(Self.keyLog(key))")
            return false
        }

        if await restorePlaybackKeyAnchor(key, reason: reason) {
            for attempt in 1...max(1, maxSteps) {
                try? await Task.sleep(nanoseconds: attempt == 1 ? 420_000_000 : 220_000_000)
                if await tryScrollToPlaybackKey(key, reason: reason, phase: "anchor", attempt: attempt) {
                    if await waitForPlaybackKeyStable(key, reason: reason, phase: "anchor-\(attempt)") {
                        return true
                    }
                }
            }
        }

        KindleRunLog.write("KINDLE playback restore miss reason=\(reason) key=\(Self.keyLog(key))")
        #if DEBUG
        NSLog("CRDBG KINDLE playback restore miss reason=%@ key=%@",
              reason,
              Self.keyLog(key))
        #endif
        return false
    }

    private func waitForPlaybackKeyStable(
        _ key: String,
        reason: String,
        phase: String
    ) async -> Bool {
        var lastSignature = ""
        var stableHits = 0
        for attempt in 1...10 {
            guard !Task.isCancelled else { return false }
            installCaptureScript()
            guard let state = try? await playbackKeyVisibility(key) else {
                try? await Task.sleep(nanoseconds: 180_000_000)
                continue
            }

            let currentKey = (state["visibleKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let width = Self.number(from: state["width"]) ?? 0
            let height = Self.number(from: state["height"]) ?? 0
            let viewportHeight = Self.number(from: state["viewportH"]) ?? 0
            let rectTop = Self.number(from: state["top"]) ?? 0
            let rectBottom = Self.number(from: state["bottom"]) ?? 0
            let visible = Self.boolValue(state["visible"])
            let aligned = Self.boolValue(state["aligned"])
            let observedIndex = String(describing: state["observedIndex"] ?? "?")
            let observedCount = String(describing: state["observedCount"] ?? "?")
            let heldIndex = String(describing: state["heldIndex"] ?? "?")
            let heldCount = String(describing: state["heldCount"] ?? "?")
            let requiresTopAlignment = Self.playbackRestoreRequiresTopAlignment(reason)
            let geometryOK = width > 80 && height > 80 && visible && (!requiresTopAlignment || aligned)
            let keyOK = currentKey.isEmpty || currentKey == key
            let widthToken = String(Int(width.rounded()))
            let heightToken = String(Int(height.rounded()))
            let topToken = String(Int(rectTop.rounded()))
            let viewportHeightToken = String(Int(viewportHeight.rounded()))
            let bottomToken = String(Int(rectBottom.rounded()))
            let signature = key + "|" +
                widthToken + "|" +
                heightToken + "|" +
                topToken + "|" +
                bottomToken + "|" +
                viewportHeightToken

            if keyOK && geometryOK && signature == lastSignature {
                stableHits += 1
            } else {
                stableHits = keyOK && geometryOK ? 1 : 0
                lastSignature = signature
            }

            KindleRunLog.write("KINDLE playback restore stable-check reason=\(reason) phase=\(phase) attempt=\(attempt) expected=\(Self.keyLog(key)) current=\(Self.keyLog(currentKey)) keyOK=\(keyOK) geometryOK=\(geometryOK) visible=\(visible) aligned=\(aligned) alignRequired=\(requiresTopAlignment) top=\(Int(rectTop.rounded())) bottom=\(Int(rectBottom.rounded())) observed=\(observedIndex)/\(observedCount) held=\(heldIndex)/\(heldCount) stable=\(stableHits)")
            if stableHits >= 2 {
                return true
            }
            try? await Task.sleep(nanoseconds: 180_000_000)
        }
        return false
    }

    private func restorePlaybackKeyAnchor(_ key: String, reason: String) async -> Bool {
        do {
            let escaped = key.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let result = try await evaluateJSON("window.__crKindleRestoreAnchor && window.__crKindleRestoreAnchor('\(escaped)')")
            let ok = Self.boolValue(result["ok"])
            let jsReason = result["reason"] as? String ?? ""
            KindleRunLog.write("KINDLE playback anchor-restore \(ok ? "hit" : "miss") reason=\(reason) key=\(Self.keyLog(key)) target=\(result["target"] ?? "?") before=\(result["before"] ?? "?") after=\(result["after"] ?? "?") delta=\(result["delta"] ?? "?") ageMs=\(result["ageMs"] ?? "?") jsReason=\(jsReason)")
            #if DEBUG
            NSLog("CRDBG KINDLE playback anchor-restore %@ reason=%@ key=%@ target=%@ before=%@ after=%@ delta=%@ ageMs=%@ jsReason=%@",
                  ok ? "hit" : "miss",
                  reason,
                  Self.keyLog(key),
                  String(describing: result["target"] ?? "?"),
                  String(describing: result["before"] ?? "?"),
                  String(describing: result["after"] ?? "?"),
                  String(describing: result["delta"] ?? "?"),
                  String(describing: result["ageMs"] ?? "?"),
                  jsReason)
            #endif
            return ok
        } catch {
            KindleRunLog.write("KINDLE playback anchor-restore error reason=\(reason) key=\(Self.keyLog(key)) error=\(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE playback anchor-restore error reason=%@ key=%@ error=%@",
                  reason,
                  Self.keyLog(key),
                  error.localizedDescription)
            #endif
            return false
        }
    }

    private func tryScrollToPlaybackKey(
        _ key: String,
        reason: String,
        phase: String,
        attempt: Int
    ) async -> Bool {
        do {
            let result = try await positionPlaybackKey(key)
            let ok = Self.boolValue(result["ok"])
            let missReason = result["reason"] as? String ?? ""
            let currentKey = result["currentKey"] as? String ?? ""
            let top = Self.number(from: result["top"]).map { Int($0.rounded()) }
            let bottom = Self.number(from: result["bottom"]).map { Int($0.rounded()) }
            let observedIndex = String(describing: result["observedIndex"] ?? result["targetIndex"] ?? "?")
            let observedCount = String(describing: result["observedCount"] ?? "?")
            let heldIndex = String(describing: result["heldIndex"] ?? result["targetHeldIndex"] ?? "?")
            let heldCount = String(describing: result["heldCount"] ?? "?")
            KindleRunLog.write("KINDLE playback restore \(ok ? "hit" : "wait") reason=\(reason) key=\(Self.keyLog(key)) current=\(Self.keyLog(currentKey)) phase=\(phase) attempt=\(attempt) top=\(String(describing: top ?? -9999)) bottom=\(String(describing: bottom ?? -9999)) observed=\(observedIndex)/\(observedCount) held=\(heldIndex)/\(heldCount) jsReason=\(missReason)")
            #if DEBUG
            NSLog("CRDBG KINDLE playback restore %@ reason=%@ key=%@ current=%@ phase=%@ attempt=%d top=%@ bottom=%@ jsReason=%@",
                  ok ? "hit" : "wait",
                  reason,
                  Self.keyLog(key),
                  Self.keyLog(currentKey),
                  phase,
                  attempt,
                  String(describing: top ?? -9999),
                  String(describing: bottom ?? -9999),
                  missReason)
            #endif
            if ok {
                try? await Task.sleep(nanoseconds: 260_000_000)
                return true
            }
        } catch {
            KindleRunLog.write("KINDLE playback restore error reason=\(reason) key=\(Self.keyLog(key)) phase=\(phase) attempt=\(attempt) error=\(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE playback restore error reason=%@ key=%@ phase=%@ attempt=%d error=%@",
                  reason,
                  Self.keyLog(key),
                  phase,
                  attempt,
                  error.localizedDescription)
            #endif
        }
        return false
    }

    private static func playbackRestoreRequiresTopAlignment(_ reason: String) -> Bool {
        reason.hasPrefix("render-switch") ||
        reason.hasPrefix("read-advance-anchor") ||
        reason.hasPrefix("explain-advance-anchor")
    }

    private static func playbackTopMargin(forViewportHeight viewportHeight: CGFloat? = nil) -> CGFloat {
        let height = viewportHeight ?? 690
        return max(8, min(18, height * 0.018))
    }

    private func evaluateJSON(_ script: String) async throws -> [String: Any] {
        let result = try await evaluate(script)
        let data: Data
        if let string = result as? String {
            data = Data(string.utf8)
        } else if JSONSerialization.isValidJSONObject(result) {
            data = try JSONSerialization.data(withJSONObject: result)
        } else {
            throw KindleBookError.invalidPayload
        }
        let object = try JSONSerialization.jsonObject(with: data)
        return object as? [String: Any] ?? [:]
    }

    @discardableResult
    private func evaluate(_ script: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: result as Any)
                }
            }
        }
    }

    private static func decodeDataURL(_ dataURL: String) -> Data? {
        guard let comma = dataURL.firstIndex(of: ",") else { return nil }
        return Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
    }

    #if DEBUG
    /// Local-only fixture used during connected-device OCR verification. It is
    /// never uploaded and deliberately lives in Caches so it can be exported,
    /// compared with the source pixels, then deleted after the test session.
    private static func persistKindleOCRDebugFixture(
        imageData: Data,
        document: ReadingDocument,
        layout: String,
        natural: String,
        rendered: String,
        encoding: String
    ) {
        let fileManager = FileManager.default
        guard let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let directory = caches.appendingPathComponent("KindleOCRDebug", isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let nonce = UUID().uuidString.prefix(8)
            let stem = "\(document.language)-\(timestamp)-\(nonce)"
            let imageName = "\(stem).png"
            let manifestName = "\(stem).json"
            try imageData.write(to: directory.appendingPathComponent(imageName), options: .atomic)

            let paragraphs: [[String: Any]] = document.paragraphs.map { paragraph in
                let words: [[String: Any]] = paragraph.words.map { word in
                    [
                        "text": word.text,
                        "x": word.bboxNorm.origin.x,
                        "y": word.bboxNorm.origin.y,
                        "width": word.bboxNorm.width,
                        "height": word.bboxNorm.height
                    ]
                }
                return [
                    "id": paragraph.id,
                    "text": paragraph.text,
                    "words": words
                ]
            }
            let manifest: [String: Any] = [
                "createdAtMs": timestamp,
                "language": document.language,
                "layout": layout,
                "natural": natural,
                "rendered": rendered,
                "encoding": encoding,
                "image": imageName,
                "paragraphs": paragraphs
            ]
            let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try json.write(to: directory.appendingPathComponent(manifestName), options: .atomic)

            let files = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ).sorted {
                let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhs < rhs
            }
            for old in files.dropLast(120) { try? fileManager.removeItem(at: old) }
            KindleRunLog.write("KINDLE_OCR_FIXTURE saved=\(stem) files=\(files.count + 2)")
        } catch {
            KindleRunLog.write("KINDLE_OCR_FIXTURE failed=\(error.localizedDescription.prefix(120))")
        }
    }
    #endif

    private static func stableKey(_ data: Data) -> String {
        let head = data.prefix(384)
        return "\(data.count)-\(head.base64EncodedString().prefix(18))"
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private static func keyLog(_ key: String) -> String {
        guard !key.isEmpty else { return "" }
        return String(key.prefix(24))
    }

    private static func jsString(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func longLog(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        let normalized = value
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(normalized.prefix(360))
    }

    private static func explainFingerprint(_ document: ReadingDocument) -> String {
        let normalized = document.readableParagraphs
            .map(\.text)
            .joined(separator: " ")
            .lowercased()
            .replacingOccurrences(of: "[^\\p{L}\\p{N}]+", with: "", options: .regularExpression)
        return String(normalized.prefix(360))
    }

    private static func number(from value: Any?) -> CGFloat? {
        if let n = value as? NSNumber { return CGFloat(truncating: n) }
        if let d = value as? Double { return CGFloat(d) }
        if let s = value as? String, let d = Double(s) { return CGFloat(d) }
        return nil
    }

    private static func int(from value: Any?) -> Int? {
        if let n = value as? NSNumber { return n.intValue }
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String, let i = Int(s) { return i }
        return nil
    }
}

private struct KindleCachedPage {
    let afterKey: String
    let page: CapturedKindlePage
    let document: ReadingDocument
    let startParagraphIndex: Int?
}

private struct KindleAudioPrefetch {
    let pageKey: String
    let textFingerprint: String
    let voiceID: String
    let paragraphIndex: Int
    let segments: [AudioSegment]
}

private struct KindleContinuousReadHandoff {
    let serial: Int
    let oldKey: String
    let target: KindleCachedPage
    let previousSnapshot: KindleCachedPage?
    let paragraphIndex: Int
    let segments: [AudioSegment]
    let segmentIDs: Set<String>
    let predecessorSegmentID: String
}

private struct KindleRefocusTarget {
    let document: ReadingDocument
    let paragraphIndex: Int
    let wordIndex: Int?
    let charRange: Range<Int>?
    let pageKey: String?
}

private struct KindlePlaybackAnchor {
    let mode: ReaderMode
    let documentID: String
    let paragraphIndex: Int
    let wordIndex: Int?
    let charRange: Range<Int>?
    let pageKey: String?
    let updatedAt: Date
}

private struct KindleCapturedWord {
    let token: String
    let text: String
    let bboxNorm: CGRect
    let paragraphIndex: Int
    let wordIndex: Int
}

private struct KindleRefocusWordPair {
    let oldWordIndex: Int
    let capturedWordIndex: Int
}

private struct KindleParagraphRefocusMatch {
    let wordPairs: [KindleRefocusWordPair]
}

private struct KindleRefocusProjection {
    let document: ReadingDocument
    let wordRoutes: [String: KindleRenderRoute]
    let matchedWordCount: Int
}

private struct KindleRefocusCandidateMatch {
    let offset: Int
    let page: CapturedKindlePage
    let projection: KindleRefocusProjection
}

private struct KindleExplainPrefetch {
    let afterKey: String
    let pageKey: String
    let textFingerprint: String
    let payload: ExplainViewModel.PrefetchedFirstBlock
}

private enum KindleReadPageSlot {
    case current
    case next

    var logName: String {
        switch self {
        case .current: return "current"
        case .next: return "next"
        }
    }
}

enum KindlePageTurnDirection {
    case previous
    case next

    var logName: String {
        switch self {
        case .previous: return "previous"
        case .next: return "next"
        }
    }
}

private enum KindleStartIndexKind {
    case sourceParagraph
    case playbackChunk
}

private struct KindleRenderRoute {
    let slot: KindleReadPageSlot
    let overlayParagraphID: Int
    let overlayWordIndex: Int
    let sourceParagraphID: Int
    let sourceWordIndex: Int
}

private struct KindleWordCharRange {
    let wordIndex: Int
    let start: Int
    let end: Int
}

private struct KindlePlaybackChunkRange {
    let text: String
    let wordRange: Range<Int>
}

private struct KindlePlaybackChunkPart {
    let source: ReadingParagraph
    let slot: KindleReadPageSlot
    let wordRange: Range<Int>
}

private struct KindlePlaybackChunk {
    let text: String
    let parts: [KindlePlaybackChunkPart]
}

private struct KindleTextQueue {
    let document: ReadingDocument
    let currentPage: CapturedKindlePage
    let currentOverlayDocument: ReadingDocument
    let nextPage: CapturedKindlePage?
    let nextBaseDocument: ReadingDocument?
    let nextOverlayDocument: ReadingDocument?
    let nextResumeParagraphIndex: Int?
    let wordRoutes: [String: KindleRenderRoute]
    let startParagraphIndex: Int?
    let hasCrossPageBridge: Bool
}

private struct CapturedKindlePage {
    let pageIndex: Int
    let key: String
    let pixelFingerprint: String?
    let sessionId: Int
    let kind: String
    let title: String
    let url: String?
    let progress: String?
    let visibleTopNorm: CGFloat
    let visibleBottomNorm: CGFloat
    let imageData: Data
    let document: ReadingDocument
    let text: String
    let columnLayout: String

    func replacingSessionId(_ sessionId: Int) -> CapturedKindlePage {
        CapturedKindlePage(
            pageIndex: pageIndex,
            key: key,
            pixelFingerprint: pixelFingerprint,
            sessionId: sessionId,
            kind: kind,
            title: title,
            url: url,
            progress: progress,
            visibleTopNorm: visibleTopNorm,
            visibleBottomNorm: visibleBottomNorm,
            imageData: imageData,
            document: document,
            text: text,
            columnLayout: columnLayout
        )
    }
}

private enum KindleBookError: LocalizedError {
    case busy
    case noImage
    case noText
    case badImage
    case invalidPayload
    case captureFailed(String)
    case overlayFailed(String)
    case verticalJapaneseUnsupported

    var errorDescription: String? {
        switch self {
        case .busy:
            return AppLocalized("Kindle 页面正在准备中。")
        case .noImage:
            return AppLocalized("没有找到 Kindle 页面图片，请打开书籍页面后重试。")
        case .noText:
            return AppLocalized("当前 Kindle 页面没有识别到可朗读文本。")
        case .badImage:
            return AppLocalized("Kindle 页面图片无法解析。")
        case .invalidPayload:
            return AppLocalized("Kindle 返回了异常的页面数据。")
        case .captureFailed(let reason):
            return String(format: AppLocalized("无法捕获 Kindle 页面：%@"), reason)
        case .overlayFailed(let reason):
            return String(format: AppLocalized("无法把高亮附加到 Kindle 页面：%@"), reason)
        case .verticalJapaneseUnsupported:
            return AppLocalized("当前日文竖排页没有获得完整的 Kindle 文字列映射，或处于双页模式。为避免漏句和错高亮，已在朗读前停止；请切换为单页后重试。")
        }
    }
}

private struct KindlePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(.white)
            .padding(.vertical, 12)
            .background(AppTheme.primary.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct KindleSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundColor(AppTheme.primary)
            .padding(.vertical, 12)
            .background(AppTheme.primary.opacity(configuration.isPressed ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
