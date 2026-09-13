//
//  KindleBookView.swift
//  CastReader
//

import Combine
import AVFoundation
import CryptoKit
import SwiftUI
import UIKit
import WebKit

/// A cancelled caller must revoke a deferred start even while its WK/OCR await
/// has not returned to the main actor yet.
private final class KindlePlaybackStartCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var finished = false
    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
    }
    var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return finished
    }
    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
    }
}

private struct KindleContinuousReadVisualHold: View {
    let image: UIImage
    let highlightRectsNorm: [CGRect]
    let imageRect: CGRect?
    let highlightContentRect: CGRect?

    var body: some View {
        GeometryReader { proxy in
            let paintedRect = imageRect ?? CGRect(origin: .zero, size: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: paintedRect.width, height: paintedRect.height)
                    .position(x: paintedRect.midX, y: paintedRect.midY)

                if let highlightContentRect {
                  ForEach(highlightRectsNorm.indices, id: \.self) { index in
                    let rect = ReadingGeometry
                        .displayRect(
                            forNorm: highlightRectsNorm[index],
                            in: highlightContentRect
                        )
                        .insetBy(dx: -2, dy: -1)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color(red: 242 / 255, green: 101 / 255, blue: 34 / 255, opacity: 0.52))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(
                                    Color(red: 242 / 255, green: 101 / 255, blue: 34 / 255, opacity: 0.30),
                                    lineWidth: 1
                                )
                        }
                        .frame(width: max(1, rect.width), height: max(1, rect.height))
                        .position(x: rect.midX, y: rect.midY)
                  }
                }
            }
            .clipped()
        }
    }
}

struct KindleExplainVisualHoldState {
    let image: UIImage
    let imageRect: CGRect
    let document: ReadingDocument
    let initiallyDrawnMarks: Set<UUID>
}

private struct KindleExplainVisualHoldView: View {
    let state: KindleExplainVisualHoldState
    @ObservedObject var owner: ExplainViewModel

    var body: some View {
        // Author paths in page-local points, exactly as the live SVG renderer.
        // Apply the page origin after drawing so number placement and jitter do
        // not change when a live page becomes a native hold.
        let resolver = PhotoAnchorResolver(document: state.document,
                                           fitted: CGRect(origin: .zero, size: state.imageRect.size))
        ZStack(alignment: .topLeading) {
            Image(uiImage: state.image)
                .resizable()
                .frame(width: state.imageRect.width, height: state.imageRect.height)
                .position(x: state.imageRect.midX, y: state.imageRect.midY)
            ForEach(owner.activeMarks) { mark in
                MarkInkView(
                    rects: resolver.rectsForCharRange(paragraphIndex: mark.paragraphIndex, range: mark.charRange),
                    action: mark.action, seed: mark.seed, n: mark.n, weight: mark.weight,
                    animateOnAppear: !state.initiallyDrawnMarks.contains(mark.id)
                )
                .offset(x: state.imageRect.minX, y: state.imageRect.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

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
    #if DEBUG
    @State private var showOfflineDiagnostics = false
    #endif

    init(book: KindleBook) {
        _model = StateObject(wrappedValue: KindleBookViewModel(book: book))
    }

    private var usesCompactPlaybackBar: Bool {
        verticalSizeClass == .compact
    }

    private var shouldHidePlaybackForNativeTOC: Bool {
        model.isNativeTOCPresented || model.isKindleTOCVisible
    }

    private var shouldHidePlaybackControls: Bool {
        shouldHidePlaybackForNativeTOC || model.isAmazonCookieConsentVisible
    }

    private var headerHeight: CGFloat {
        usesCompactPlaybackBar ? 44 : 52
    }

    @State private var showOfflineDownload = false

    init(model: KindleBookViewModel) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                Divider()
                KindleReaderPlaybackDock(isLandscape: usesCompactPlaybackBar) {
                    readerSurface
                } playback: {
                    Group {
                        if usesCompactPlaybackBar {
                            landscapePlaybackOverlay
                                .padding(.horizontal, 22)
                                .padding(.bottom, 8)
                        } else {
                            playbackBar
                        }
                    }
                    .opacity(shouldHidePlaybackControls ? 0 : (model.isKindleSyncDialogVisible ? 0.45 : 1))
                    .allowsHitTesting(!shouldHidePlaybackControls && !model.isKindleSyncDialogVisible)
                    .accessibilityHidden(shouldHidePlaybackControls || model.isKindleSyncDialogVisible)
                }
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
        .environment(\.readerAppearanceSource, .web {
            model.openReadingSettings()
            return model.isReadingSettingsPresented
        })
        // Let Kindle finish mounting its native font controls before the
        // SwiftUI sheet occludes the WKWebView. The model already owns the
        // operation and pauses playback throughout this preparation.
        .sheet(isPresented: Binding(
            get: { model.isReadingSettingsPresented && (model.readerFontValue != nil || model.readingSettingsError != nil) },
            set: { model.isReadingSettingsPresented = $0 }
        ), onDismiss: {
            model.closeReadingSettings()
        }) {
            KindleReadingSettingsView(
                fontValue: model.readerFontValue,
                canDecrease: model.canDecreaseReaderFont,
                canIncrease: model.canIncreaseReaderFont,
                isBusy: model.isApplyingReadingSettings,
                error: model.readingSettingsError,
                skipsFootnotes: Binding(
                    get: { model.skipsFootnoteReferences },
                    set: { model.setSkipsFootnoteReferences($0) }
                ),
                changeFont: { model.changeReaderFont(by: $0) }
            )
        }
        .environment(\.readerOfflineAction, ReaderOfflineAction(title: "离线保存整本书", open: { showOfflineDownload = true }))
        .task(id: playbackCenter.offlineDownloadRequestID) {
            guard playbackCenter.consumeOfflineDownloadRequest(for: model.offlineSourceBook.id) else { return }
            showOfflineDownload = true
        }
        .sheet(isPresented: $showOfflineDownload, onDismiss: { KindleOfflinePlaybackCenter.shared.presentAfterDownload() }) {
            KindleOfflineDownloadView(model: model, download: model.offlineDownload)
        }
        #if DEBUG
        .sheet(isPresented: $showOfflineDiagnostics) { KindleOfflineDiagnosticsView(model: model) }
        #endif
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
            if model.isNativeTOCPresented || model.isKindleTOCVisible || model.playerOverlayViewport != nil {
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
                analyticsTrigger: QuotaManager.shared.paywallTrigger(
                    replacing: KindlePaywallPresentationContract.analyticsTrigger(
                        requestedMode: model.paywallMode,
                        currentMode: model.mode
                    )
                ),
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
                    stable: model.playerOverlayViewport?.surfaceSize ?? proxy.size,
                    isPlayerOverlayPresented: model.playerOverlayViewport != nil
                )
                let crop = model.effectiveViewportCrop(forSurfaceSize: webSize)
                KindleWebView(
                    webView: model.libraryRecoveryWebView ?? model.webView,
                    crop: model.libraryRecoveryWebView == nil ? crop : .identity,
                    presentationFit: model.libraryRecoveryWebView == nil
                        ? model.effectiveViewportPresentationFit(forSurfaceSize: webSize) : .identity
                )
                    .id(ObjectIdentifier(model.libraryRecoveryWebView ?? model.webView))
                    .accessibilityHidden(model.isWarmingBookSession || model.contentCover != nil)
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
            if let image = model.continuousReadVisualHoldImage {
                KindleContinuousReadVisualHold(
                    image: image,
                    highlightRectsNorm: model.continuousReadVisualHoldHighlightRectsNorm,
                    imageRect: model.continuousReadVisualHoldImageRect,
                    highlightContentRect: model.continuousReadVisualHoldHighlightContentRect
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            if let hold = model.explainVisualHold, let owner = model.explainVM {
                KindleExplainVisualHoldView(state: hold, owner: owner)
            }
            // What a browser gives you and a bare WKWebView does not: proof that
            // something is happening. Before the first byte arrives there is no
            // page, so Kindle's own spinner cannot exist yet — measured on device,
            // Amazon once took 31s to answer, and all the user saw was white.
            // This only mirrors `estimatedProgress`; it makes no judgement about
            // when the book is "ready".
            if model.isNavigating {
                GeometryReader { proxy in
                    Capsule()
                        .fill(AppTheme.primary)
                        .frame(width: proxy.size.width * max(0.03, model.loadProgress), height: 2.5)
                        .animation(.easeOut(duration: 0.25), value: model.loadProgress)
                }
                .frame(height: 2.5)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
            }
            #if DEBUG
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Kindle page state")
                .accessibilityValue(model.debugAcceptancePage)
                .accessibilityIdentifier("kindleAcceptanceState")
            Color.clear.frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Kindle prepared navigation")
                .accessibilityValue(model.debugHeldPageNavigation)
                .accessibilityIdentifier("kindleHeldPageNavigationState")
            #endif
            preparingStatusOverlay
            if model.isStaleBookEntryError {
                staleBookRecoveryOverlay
            }
            // Topmost: hides both Amazon's sign-in page and the shelf being
            // loaded to reactivate the session. If recovery fails the cover is
            // removed so the user can complete a real sign-in.
            if model.contentCover != nil || model.isWarmingBookSession {
                authRecoveryOverlay
            }
            if model.needsKindleRebind {
                kindleRebindOverlay
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

    private var kindleRebindOverlay: some View {
        ZStack {
            AppTheme.background
            VStack(spacing: 14) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(AppTheme.primary)
                Text("Kindle 登录已失效")
                    .font(.headline)
                Text("需要重新绑定 Amazon 账号才能继续。重新绑定并同步后，书架和听书进度都会回来。")
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                Button {
                    model.startKindleRebind()
                } label: {
                    Text("重新绑定 Kindle").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.primary)
                Button("返回") {
                    KindlePlaybackCenter.shared.close()
                }
            }
            .padding(22)
            .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var authRecoveryOverlay: some View {
        ZStack {
            AppTheme.background
            VStack(spacing: 12) {
                ProgressView().tint(AppTheme.primary)
                Text(model.contentCover ?? AppLocalized("正在打开…"))
                    .font(.subheadline)
                    .foregroundStyle(AppTheme.mutedForeground)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("kindleSessionPreparation")
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

            .accessibilityIdentifier("kindleMinimizeButton")

            Text(model.book.title)
                .layoutPriority(-1)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .foregroundColor(AppTheme.foreground)

            Spacer(minLength: 8)

            #if DEBUG
            Button {
                model.prepareOfflineDiagnostics()
                showOfflineDiagnostics = true
            } label: { Image(systemName: "flask").frame(width: 32, height: 34) }
            .accessibilityLabel("离线能力诊断")
            .accessibilityIdentifier("kindleOfflineDiagnostics")
            #endif

            HStack(spacing: 2) {
                kindleModeButton(.read, title: AppLocalized("朗读"))
                kindleModeButton(.explain, title: AppLocalized("解读"))
            }
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
            .padding(3)
            .background(AppTheme.surfaceVariant, in: Capsule())
            .opacity(model.isKindleSyncDialogVisible || model.isAmazonCookieConsentVisible ? 0.5 : 1)
            .allowsHitTesting(!model.isKindleSyncDialogVisible && !model.isAmazonCookieConsentVisible)
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
        .accessibilityIdentifier(mode == .read ? "kindleModeButton_read" : "kindleModeButton_explain")
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
                    pause: { model.pauseReadPlayback() },
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
                    .offset(y: ReaderPlaybackBarLayoutContract.explainCaptionOffset)
                    .allowsHitTesting(false)
            }
        }
        // Playback state, voice availability and errors must never change the
        // Kindle viewport height. A fixed single-line console prevents React
        // from reconciling the reader surface when playback begins.
        .frame(maxWidth: .infinity)
        .frame(height: ReaderPlaybackBarLayoutContract.portraitHeight)
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
                    pause: { model.pauseReadPlayback() },
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
        AudioPlayerService.shared.sleepTimer.resumeByUser()
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

/// Keep the full reader surface above the controls in either orientation.
/// A fixed dock prevents loading, pause and temporary hidden controls from
/// changing WebKit's CSS viewport. Explain captions retain their existing
/// overflow behavior; the control capsule itself never covers the page.
struct KindleReaderPlaybackDock<Reader: View, Playback: View>: View {
    let isLandscape: Bool
    let reader: Reader
    let playback: Playback

    init(isLandscape: Bool, @ViewBuilder reader: () -> Reader, @ViewBuilder playback: () -> Playback) {
        self.isLandscape = isLandscape
        self.reader = reader()
        self.playback = playback()
    }

    var body: some View {
        VStack(spacing: 0) {
            reader.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            playback
                .frame(maxWidth: .infinity)
                .frame(height: isLandscape ? ReaderPlaybackBarLayoutContract.landscapeControlHeight
                       : ReaderPlaybackBarLayoutContract.portraitHeight, alignment: .bottom)
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
            .accessibilityIdentifier("kindleReadPlayPauseButton")
            .accessibilityValue(isPreparing ? "loading" : "paused")
        }
    }
}

private struct KindleReadPlaybackBar: View {
    @ObservedObject private var sleepTimer = AudioPlayerService.shared.sleepTimer
    @ObservedObject var vm: ReadAloudViewModel
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared
    let isPreparing: Bool
    let compact: Bool
    let start: () -> Void
    let pause: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void

    private var isLoading: Bool {
        if sleepTimer.requiresExplicitResume { return false }
        return !vm.isPlaybackPausedByUser && (voiceSwitch.progress != nil ||
            isPreparing ||
            vm.isWaitingForPlayableAudio)
    }

    var body: some View {
        KindlePlaybackConsole(
            isLandscape: compact,
            playbackStatus: playbackStatus,
            statusMessage: voiceSwitch.progress?.localizedMessage,
            voiceLanguage: vm.hasStartedPlayback ? vm.playbackLanguage : nil,
            onCorrectReadingLanguage: { [weak vm] in vm?.correctReadingLanguage($0) },
            previousPage: previousPage,
            nextPage: nextPage,
            showTOC: showTOC
        ) {
            Button(action: { if isLoading { pause() } else { start() } }) {
                KindlePlayButtonContent(
                    isLoading: false,
                    isPlaying: vm.isPlaying || isLoading,
                    size: compact ? 44 : 52
                )
            }
            .accessibilityIdentifier("kindleReadPlayPauseButton")
            .accessibilityValue(isLoading ? "loading" : (vm.isPlaying ? "playing" : "paused"))
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
    /// Read-aloud only: lets the voice panel correct which language this book is
    /// narrated in. Explain leaves it nil, which keeps its language pinned.
    let onCorrectReadingLanguage: ((String) -> Void)?
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void
    let playControl: PlayControl

    init(
        isLandscape: Bool,
        playbackStatus: String,
        statusMessage: String? = nil,
        voiceLanguage: String?,
        onCorrectReadingLanguage: ((String) -> Void)? = nil,
        previousPage: @escaping () -> Void,
        nextPage: @escaping () -> Void,
        showTOC: @escaping () -> Void,
        @ViewBuilder playControl: () -> PlayControl
    ) {
        self.isLandscape = isLandscape
        self.playbackStatus = playbackStatus
        self.statusMessage = statusMessage
        self.voiceLanguage = voiceLanguage
        self.onCorrectReadingLanguage = onCorrectReadingLanguage
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
                .frame(height: ReaderPlaybackBarLayoutContract.consoleHeight)
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

    /// Landscape keeps an intrinsic capsule inside the reserved bottom dock,
    /// with the compact single-line composition instead of expanding.
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
            .accessibilityIdentifier("kindlePreviousPageButton")
            playControl
            KindlePageTurnButton(
                systemName: "chevron.right",
                accessibilityLabel: AppLocalized("下一页"),
                action: nextPage
            )
            .accessibilityIdentifier("kindleNextPageButton")
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
            ReaderMoreButton()
        }
    }

    @ViewBuilder
    private func voiceControl(showsLabel: Bool) -> some View {
        if let voiceLanguage, !voiceLanguage.isEmpty {
            PlaybackVoiceButton(
                language: voiceLanguage,
                size: 32,
                showsLabel: showsLabel,
                onCorrectReadingLanguage: onCorrectReadingLanguage
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
    @ObservedObject private var sleepTimer = AudioPlayerService.shared.sleepTimer
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
                .offset(y: ReaderPlaybackBarLayoutContract.explainCaptionOffset)
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
        if sleepTimer.requiresExplicitResume {
            playButton(isLoading: false, isPlaying: false) { vm.ensurePlaying() }
        } else {
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
    }

    private func playButton(isLoading: Bool, isPlaying: Bool, action: @escaping () -> Void) -> some View {
        Button {
            sleepTimer.resumeByUser()
            action()
        } label: {
            KindlePlayButtonContent(
                isLoading: isLoading,
                isPlaying: isPlaying,
                size: compact ? 44 : 52
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("kindleExplainPlayPauseButton")
        .accessibilityValue(isLoading ? "loading" : (isPlaying ? "playing" : "paused"))
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
            ExplainPlaybackCaptionBubble(
                text: vm.explanationText,
                alignment: alignment,
                maxWidth: maxWidth
            )
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
    @ObservedObject private var sleepTimer = AudioPlayerService.shared.sleepTimer
    @ObservedObject var vm: ReadAloudViewModel
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared
    let isPreparing: Bool
    let start: () -> Void
    let pause: () -> Void
    let previousPage: () -> Void
    let nextPage: () -> Void
    let showTOC: () -> Void

    private var isLoading: Bool {
        if sleepTimer.requiresExplicitResume { return false }
        return !vm.isPlaybackPausedByUser && (voiceSwitch.progress != nil ||
            isPreparing ||
            vm.isWaitingForPlayableAudio)
    }

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            KindlePlaybackConsole(
                isLandscape: true,
                playbackStatus: isLoading ? AppLocalized("正在准备…") : (vm.isPlaying ? AppLocalized("朗读中") : AppLocalized("已暂停")),
                statusMessage: voiceSwitch.progress?.localizedMessage,
                voiceLanguage: vm.hasStartedPlayback ? vm.playbackLanguage : nil,
                onCorrectReadingLanguage: { [weak vm] in vm?.correctReadingLanguage($0) },
                previousPage: previousPage,
                nextPage: nextPage,
                showTOC: showTOC
            ) {
                Button(action: { if isLoading { pause() } else { start() } }) {
                    KindlePlayButtonContent(
                        isLoading: false,
                        isPlaying: vm.isPlaying || isLoading,
                        size: 44
                    )
                }
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

extension Notification.Name {
    /// Posted when the reader has given up on an expired Amazon session and the
    /// user chose to rebind. Home listens and opens the Kindle connect flow.
    static let castReaderKindleRebindRequested = Notification.Name("castreader.kindle.rebindRequested")
}

enum KindleRunLog {
    #if DEBUG
    /// One banner per process launch. Without it a relaunch cannot be told apart
    /// from a long-lived session when the probe log is read hours later, and the
    /// two have very different implications for an expired Amazon session.
    private static let launchMarker: Void = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        append("\n===== launch \(formatter.string(from: Date())) =====\n")
    }()
    #endif

    static func write(_ message: String) {
        #if DEBUG
        _ = launchMarker
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let stateName: String
        if Thread.isMainThread {
            stateName = MainActor.assumeIsolated {
                UIApplication.shared.applicationState.debugName
            }
        } else {
            stateName = "off-main"
        }
        append(
            "\(formatter.string(from: Date())) [\(stateName)] \(sanitized(message))\n"
        )
        #endif
    }

    #if DEBUG
    private static func sanitized(_ message: String) -> String {
        var value = message
        let replacements: [(String, String)] = [
            (#"https?://[^\s\"'<>]+"#, "<url>"),
            (#"\bB[0-9A-Z]{9}\b"#, "<asin>"),
            (#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
            (#"(?i)(?:openid\.|return_to|token|session|secret|password)=[^\s&]+"#, "<credential>"),
        ]
        for (pattern, replacement) in replacements {
            value = value.replacingOccurrences(
                of: pattern,
                with: replacement,
                options: .regularExpression
            )
        }
        return value
    }

    private static func append(_ text: String) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let url = docs.appendingPathComponent("kindle-background-probe.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data(text.utf8).write(to: url, options: .atomic)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } catch {
            try? handle.close()
        }
    }
    #endif
}

/// Read-only diagnostics for the Amazon session behind the Kindle WebViews.
/// Observation only: nothing here changes navigation, cookies or reader state.
///
/// Cookie *values* are never written to the log. Each value is reduced to a
/// truncated one-way digest, which is enough to see a token rotate or vanish
/// between a working and a failing book open, and never enough to reconstruct
/// the credential.
enum KindleSessionProbe {
    /// Privacy-safe route diagnostics. Never persist a Kindle URL, path, query,
    /// ASIN, title, or account identifier; storefront and eTLD+1 are sufficient
    /// to diagnose routing and marketplace drift.
    static func safeRouteLabel(_ rawURL: String) -> String {
        guard let url = URL(string: rawURL) else { return "invalid" }
        return safeRouteLabel(url)
    }

    static func safeRouteLabel(_ url: URL?) -> String {
        guard let url else { return "empty" }
        let landing = landingKind(url.absoluteString)
        if let storefront = KindleStorefront.storefront(url: url) {
            return "storefront=\(storefront.id) landing=\(landing)"
        }
        if let domain = KindleStorefront.registrableDomain(for: url.host) {
            return "domain=\(domain) landing=\(landing)"
        }
        return "invalid landing=\(landing)"
    }

    /// Classifies where a navigation actually landed. Amazon answers an expired
    /// reader session with a 302 into the OpenID sign-in portal, so the finished
    /// URL is the only reliable signal that the page on screen is not a book.
    static func landingKind(_ rawURL: String) -> String {
        guard !rawURL.isEmpty else { return "empty" }
        guard let url = URL(string: rawURL) else { return "other" }

        let path = url.path.lowercased()
        if KindleStorefrontNavigationPolicy.isSafeAmazonAuthenticationURL(url) {
            return "auth"
        }

        guard KindleStorefront.matches(url: url) else { return "other" }
        if path.contains("kindle-library") { return "library" }
        if KindleBookValidator.containsASIN(rawURL)
            || KindleBookValidator.isKindleReaderPath(rawURL) {
            return "reader"
        }
        return "other"
    }

    static func driftDomain(for rawURL: String) -> String? {
        KindleDomainDriftSentinel.registrableDomainIfNeeded(rawURL: rawURL)
    }

    @MainActor
    static func logCookies(reason: String) {
        #if DEBUG
        CommercialWebSession.websiteDataStore.httpCookieStore.getAllCookies { cookies in
            let amazon = cookies
                .filter { KindleStorefront.isAmazonWebsiteDataDomain($0.domain) }
            guard !amazon.isEmpty else {
                KindleRunLog.write(
                    "KINDLE session-data reason=\(reason) amazonCount=0 totalCount=\(cookies.count)"
                )
                return
            }
            let now = Date()
            let storefrontCounts = KindleStorefront.all.compactMap { storefront -> String? in
                let count = amazon.filter {
                    KindleStorefront.isAmazonWebsiteDataDomain(
                        $0.domain,
                        for: storefront
                    )
                }.count
                return count > 0 ? "\(storefront.id):\(count)" : nil
            }.joined(separator: ",")
            let sessionCount = amazon.filter { $0.expiresDate == nil }.count
            let expiredCount = amazon.filter {
                guard let expiry = $0.expiresDate else { return false }
                return expiry <= now
            }.count
            let persistentCount = amazon.count - sessionCount
            KindleRunLog.write(
                "KINDLE session-data reason=\(reason) amazonCount=\(amazon.count) totalCount=\(cookies.count) session=\(sessionCount) persistent=\(persistentCount) expired=\(expiredCount) storefrontCounts=\(storefrontCounts.isEmpty ? "none" : storefrontCounts)"
            )
        }
        #endif
    }

    /// `id_pk`/`id_pkel` 是 Amazon 深链 reader 会话的配对 cookie（14 分钟 TTL，
    /// 仅认证域/书架加载补发）。在→开书成功、缺→被打回登录页，为 2026-07 真机
    /// 采样的 100% 相关指标。留 30s 余量，避免带着即将过期的 cookie 起跳。
    @MainActor
    static func hasFreshAuthPairingCookie(for storefront: KindleStorefront) async -> Bool {
        await withCheckedContinuation { continuation in
            CommercialWebSession.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let deadline = Date().addingTimeInterval(30)
                let fresh = cookies.contains { cookie in
                    (cookie.name == "id_pk" || cookie.name == "id_pkel")
                        && KindleStorefront.isAmazonWebsiteDataDomain(cookie.domain, for: storefront)
                        && (cookie.expiresDate.map { $0 > deadline } ?? true)
                }
                continuation.resume(returning: fresh)
            }
        }
    }

}

/// Tracks when the reader and the shelf were last known-good, so a failing open
/// can be read against how stale the Amazon session was at that moment.
enum KindleSessionFreshness {
    private static let readerKey = "kindle.probe.lastReaderOK"
    private static let shelfKey = "kindle.probe.lastShelfOK"

    static func markReaderOK() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: readerKey)
    }

    static func markShelfOK() {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: shelfKey)
    }

    static var sinceReaderOK: String { elapsed(readerKey) }
    static var sinceShelfOK: String { elapsed(shelfKey) }

    /// Minutes since the shelf last loaded successfully; `nil` if never.
    static var minutesSinceShelfOK: Int? {
        let raw = UserDefaults.standard.double(forKey: shelfKey)
        guard raw > 0 else { return nil }
        return Int((Date().timeIntervalSince1970 - raw) / 60)
    }

    private static func elapsed(_ key: String) -> String {
        let raw = UserDefaults.standard.double(forKey: key)
        guard raw > 0 else { return "never" }
        return "\(Int((Date().timeIntervalSince1970 - raw) / 60))m"
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

struct KindleModeSwitchAccessPlan: Equatable {
    let shouldStopCurrentPlayback: Bool
    let shouldApplyRequestedMode: Bool
    let paywallMode: ReaderMode?
}

enum KindleModeSwitchAccessContract {
    static func resolve(requestedMode: ReaderMode, hasAccess: Bool) -> KindleModeSwitchAccessPlan {
        KindleModeSwitchAccessPlan(
            shouldStopCurrentPlayback: hasAccess,
            shouldApplyRequestedMode: hasAccess,
            paywallMode: hasAccess ? nil : requestedMode
        )
    }
}

enum KindlePaywallPresentationContract {
    /// 纯函数：模式 → 基础 trigger（保持可测）。two_tier 的层级化换名由
    /// 调用点经 `QuotaManager.paywallTrigger(replacing:)` 完成。
    static func analyticsTrigger(requestedMode: ReaderMode?, currentMode: ReaderMode) -> String {
        switch requestedMode ?? currentMode {
        case .read:
            return "listen_quota"
        case .explain:
            return "explain_quota"
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
                .accessibilityIdentifier("kindleMiniPlayerExpand")

                if model.mode == .explain, let vm = model.explainVM {
                    PlaybackVoiceButton(language: vm.playbackLanguage, size: 34)
                } else if let vm = model.readVM, vm.hasStartedPlayback {
                    PlaybackVoiceButton(
                        language: vm.playbackLanguage,
                        size: 34,
                        onCorrectReadingLanguage: { [weak vm] in
                            vm?.correctReadingLanguage($0)
                        }
                    )
                }

                Button {
                    audio.sleepTimer.resumeByUser()
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
            #if DEBUG
            .overlay(alignment: .bottomLeading) {
                KindleMiniAcceptanceState(model: model)
            }
            #endif
        }
    }
}

#if DEBUG
/// Exposes only a page hash while the full reader is offscreen. Observing the
/// model keeps this probe independent from the mini player's audio callbacks.
private struct KindleMiniAcceptanceState: View {
    @ObservedObject var model: KindleBookViewModel
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Kindle page state")
            .accessibilityValue(model.debugAcceptancePage)
            .accessibilityIdentifier("kindleMiniAcceptanceState")
            .allowsHitTesting(false)
    }
}
#endif

@MainActor
enum KindleOpenIntent: Equatable {
    case present
    case autoplayRead(requestID: UUID)
}

enum KindlePlaybackStartOutcome: Equatable {
    case started
    case deferred
    case blocked
}

@MainActor
final class KindlePlaybackCenter: ObservableObject {
    static let shared = KindlePlaybackCenter()
    private static let orientationOwner = "kindle-player"

    @Published private(set) var model: KindleBookViewModel?
    @Published var isPresented = false
    @Published private(set) var offlineDownloadRequestID: UUID?
    private var offlineDownloadBookID: String?

    var showsMiniPlayer: Bool {
        model != nil && !isPresented
    }

    private init() {}

    func openOfflineDownload(book: KindleBook) {
        offlineDownloadBookID = book.id
        open(book: book)
        offlineDownloadRequestID = UUID()
    }

    func consumeOfflineDownloadRequest(for bookID: String) -> Bool {
        guard offlineDownloadRequestID != nil, offlineDownloadBookID == bookID, isPresented else { return false }
        offlineDownloadBookID = nil
        return true
    }

    func open(book: KindleBook, intent: KindleOpenIntent = .present) {
        KindleOfflinePlaybackCenter.shared.stop(preservingSleepTimer: true)
        AppOrientationLock.unlock(owner: Self.orientationOwner)
        if let active = model, active.isSameBook(as: book) {
            active.refreshMetadata(from: book)
            if case .autoplayRead(let requestID) = intent {
                active.requestAutoplayRead(requestID: requestID)
            }
            isPresented = true
            return
        }

        let old = model
        let next = KindleBookViewModel(book: book, openIntent: intent)
        model = next
        isPresented = true
        old?.destroy()
    }

    func replaceAfterLibraryRecovery(current: KindleBookViewModel, book: KindleBook) {
        guard model === current else {
            KindleRunLog.write("KINDLE stale-entry fresh-reader skipped reason=ownership-changed book=\(String(book.id.prefix(24)))")
            return
        }
        let next = KindleBookViewModel(
            book: book,
            staleRecoveryAlreadyAttempted: true,
            openIntent: current.pendingOpenIntentForReplacement
        )
        model = next
        current.destroy()
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

    func close(preservingSleepTimer: Bool = false) {
        if !preservingSleepTimer { AudioPlayerService.shared.sleepTimer.endPlaybackSession() }
        let active = model
        model = nil
        isPresented = false
        AppOrientationLock.unlock(owner: Self.orientationOwner)
        active?.destroy()
    }

    func clear(ifModel candidate: KindleBookViewModel) {
        guard model === candidate else { return }
        model = nil
        isPresented = false
        AppOrientationLock.unlock(owner: Self.orientationOwner)
        candidate.destroy()
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
final class KindleBookViewModel: NSObject, ObservableObject, WKNavigationDelegate, WKScriptMessageHandler, KindleOfflineBookSource {
    @Published var book: KindleBook
    @Published var isPreparing = false
    @Published var statusText = ""
    @Published var playbackErrorText: String?
    @Published var mode: ReaderMode = .read
    @Published var readVM: ReadAloudViewModel?
    @Published var explainVM: ExplainViewModel?
    @Published var showPaywall = false
    @Published private(set) var paywallMode: ReaderMode?
    @Published var isContinuingExplainPage = false
    @Published var isPageTurnResuming = false
    @Published var isReadingSettingsPresented = false
    @Published private(set) var isApplyingReadingSettings = false
    @Published private(set) var readerFontValue: Double?
    @Published private(set) var readingSettingsError: String?
    @Published private(set) var skipsFootnoteReferences = UserDefaults.standard.object(forKey: "kindle.skipFootnoteReferences.v1") as? Bool ?? true
    private var readerFontMinimum: Double = 0
    private var readerFontMaximum: Double = 0
    private var readingSettingsTask: Task<Void, Never>?
    private var readingSettingsRevision: UInt64 = 0
    let offlineDownload = KindleOfflineDownloadCoordinator()
    private var offlineCaptureOriginal: KindleOfflineSourcePosition?
    private var offlineCaptureNavigationGeneration: UInt64?
    private var offlineCaptureScope: String?
    private var suppressReadingSettingsCloseAfterSync = false
    private var readingSettingsSessionActive = false
    private var readingSettingsCloseInProgress = false
    #if DEBUG
    private let offlineProbeSession = KindleOfflineProbeSession()
    private var offlineDiagnosticPageKey: String?
    @Published private var debugPreparedHeldPageKey: String?
    var debugHeldPageNavigation: String {
        guard let held = heldPageForManualNavigation, let target = debugPreparedHeldPageKey else { return "none" }
        func hash(_ key: String) -> String {
            SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return "old=" + hash(held.key) + " next=" + hash(target)
    }
    var debugAcceptancePage: String {
        guard let page = livePageKey, !page.isEmpty else { return "page=none" }
        return "page=" + SHA256.hash(data: Data(page.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    #endif
    var canDecreaseReaderFont: Bool { readerFontValue.map { $0 > readerFontMinimum } ?? false }
    var canIncreaseReaderFont: Bool { readerFontValue.map { $0 < readerFontMaximum } ?? false }
    @Published var viewportCrop: KindleViewportCrop = .identity
    @Published private(set) var viewportPresentationFit: KindleViewportPresentationFit = .identity
    private var viewportPresentationGeneration: UInt64 = 0
    private var viewportPresentationProbeTask: Task<Void, Never>?
    private var viewportPresentationPageRect: CGRect?
    private var viewportPresentationPageKey: String?
    private var viewportPresentationPageCount = 0
    @Published var isKindleTOCVisible = false
    @Published var isNativeTOCPresented = false
    @Published var isNativeTOCLoading = false
    @Published var nativeTOCError: String?
    @Published var nativeTOCEntries: [KindleTOCEntry] = []
    @Published private(set) var isAmazonCookieConsentVisible = false
    @Published private(set) var isKindleSyncDialogVisible = false
    @Published private(set) var kindleSyncLocalLocation: Int?
    @Published private(set) var kindleSyncCloudLocation: Int?
    @Published private(set) var isStaleBookEntryError = false
    @Published private(set) var isStaleBookRecovering = false
    @Published private(set) var staleBookRecoveryMessage: String?
    @Published private(set) var staleBookRecoveryProgressText = AppLocalized("正在准备…")
    @Published private(set) var libraryRecoveryWebView: WKWebView?
    /// The shelf client must be mounted at real size to refresh Amazon's
    /// session, but this internal preflight is not a reader destination.
    @Published private(set) var isWarmingBookSession = false
    /// Set while the Amazon reader session is being reactivated behind a cover.
    /// The sign-in page must never be the thing the user is left looking at.
    /// Only ever set while the Amazon session is being repaired. Normal loading
    /// is deliberately NOT covered: the reader is an ordinary web page and should
    /// behave like one. The cover exists for exactly one reason — the user must
    /// not be left staring at Amazon's sign-in form while we fix it.
    @Published private(set) var contentCover: String?
    /// Straight mirrors of the WebView's own loading state — no interpretation.
    @Published private(set) var isNavigating = false
    @Published private(set) var readerControlsReady = false
    private var readerControlsNavigationGeneration: UInt64 = 0
    @Published private(set) var loadProgress: Double = 0
    /// While Kindle advances its WebView shortly before an audio boundary, keep
    /// the last visible frame on screen. It is released only after the old page
    /// has finished speaking and the confirmed new page is ready underneath.
    @Published private(set) var continuousReadVisualHoldImage: UIImage?
    @Published private(set) var explainVisualHold: KindleExplainVisualHoldState?
    @Published private(set) var continuousReadVisualHoldImageRect: CGRect?
    @Published private(set) var continuousReadVisualHoldHighlightContentRect: CGRect?
    /// The held page is a clean Kindle page raster. These OCR-space rectangles
    /// keep its word highlight live while the underlying WebView stages ahead.
    @Published private(set) var continuousReadVisualHoldHighlightRectsNorm: [CGRect] = []
    /// Recovery is exhausted and Amazon still refuses the session: the account
    /// must be bound again. Surfaced as a native card because a bare Amazon
    /// sign-in form inside the reader tells the user nothing about what to do.
    @Published private(set) var needsKindleRebind = false
    /// One automatic repair per reader session; reset once a book actually
    /// opens, so a signed-out account cannot spin here.
    private var authRecoveryAttempted = false
    private var lastMainFrameStatus: Int?
    private var authRecoveryTask: Task<Void, Never>?
    /// 首次开书前的会话预检（id_pk 缺失 → 先预热书架），见 openBookWithSessionPreflight。
    private var openPreflightTask: Task<Void, Never>?
    private let cookieConsentRuntimeToken: String
    private var cookieConsentDocumentToken: String?
    private var retiredCookieConsentDocumentTokens = Set<String>()
    private var cookieConsentRecoveryTask: Task<Void, Never>?
    private var cookieConsentEpoch: UInt64 = 0
    private var cookieConsentResumeMode: ReaderMode?
    private var cookieConsentShouldResumePlayback = false
    private var cookieConsentAwaitingRecovery = false
    private var lastNativeTOCSelectionText: String?
    private var lastNativeTOCSelectionPageKey: String?
    private var nativeTOCTask: Task<Void, Never>?
    private var nativeTOCEpoch: UInt64 = 0
    private var isNativeTOCBridgeJumping = false
    private var readerSurfaceFreezeUntil: Date?

    let webView: WKWebView

    var isPlaybackPreparing: Bool {
        isPreparing || isPageTurnResuming || isApplyingReadingSettings || isNavigating
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
    private var automaticAppReviewContinuation = AppReviewAutomaticPageContinuation()
    private var automaticAppReviewContinuationGeneration: UInt64?
    private var cancellables = Set<AnyCancellable>()
    private var playbackCancellables = Set<AnyCancellable>()
    private let store: KindleLibraryStore
    private let historyStore: HistoryStore
    private let positionStorageGeneration: UUID
    private var activeReadNavigationID: UUID?
    private var userGestureNavigation: (gesture: String, position: UUID)?
    private let analyticsContext: AnalyticsContentContext

    /// One reader WebView is bound to one concrete book identity. Storefront
    /// ownership alone is not enough because an auth redirect could otherwise
    /// return to a bare reader root or a different ASIN.
    private var expectedReaderASIN: String? {
        KindleBookValidator.asinValue(in: book.asin)
            ?? KindleBookValidator.asinValue(in: book.id)
            ?? KindleBookValidator.asinValue(in: book.effectiveReaderURL)
    }
    /// Page-local OCR documents all participate in one user-initiated Kindle
    /// reading session. The coordinator survives resetViewModels(page:).
    private let readAnalyticsSessionCoordinator = ReadAnalyticsSessionCoordinator()
    private var analyticsContentReadyTracked = false
    private var analyticsReportedDriftDomains = Set<String>()
    private var storefrontHandoffInFlight = false
    /// Preserve native Kindle glyph pixels for OCR. The JavaScript capture uses
    /// lossless PNG; this cap only protects against abnormally large renderer images.
    private static let ocrCaptureMaxWidth = 2048
    private static var ocrCaptureJavaScriptArguments: String {
        "\(ocrCaptureMaxWidth)"
    }

    // Render layer: consumes word routes and paints highlight/marks onto the live Kindle page.
    private enum PendingVisualHighlight {
        case word(paragraphIndex: Int, wordIndex: Int)
        case range(paragraphIndex: Int, range: Range<Int>)
    }

    private var visualSyncTask: Task<Void, Never>?
    private var activeVisualSyncSequence: UInt64?
    private var pendingVisualHighlight: PendingVisualHighlight?
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
    private var candidateCacheOrder: [String] = []
    private var pageBackStack: [KindleCachedPage] = []
    private var pageForwardStack: [KindleCachedPage] = []

    // Playback prefetch layer: owns audio generated for a known utterance. Kept separate from page cache.
    private var cachedStartAudio: KindleAudioPrefetch?
    private var cachedStartAudioCandidates: [String: KindleAudioPrefetch] = [:]
    private var continuousReadHandoff: KindleContinuousReadHandoff?
    private var continuousReadAudioAppended = false
    private var continuousReadTurnTask: Task<Void, Never>?
    private var continuousReadCommitTask: Task<Void, Never>?
    private var continuousReadStagedPage: KindleCachedPage?
    private var continuousReadStagedLiveKey: String?
    private var continuousReadHandoffSerial = 0
    private var continuousReadOldVMDetached = false
    private var continuousReadAppReviewSession: AppReviewReadSessionProgress?
    private var continuousReadAnalyticsOwner: ReadAloudViewModel?
    private var continuousReadAudioCompletedBeforeCommit = false
    private var continuousReadAudioBoundaryReached = false
    private var continuousReadAudioGateReleasePresented = false
    private var continuousReadAudioGateReleaseTask: Task<Void, Never>?
    private var continuousReadTurnFailureCount = 0
    private var continuousReadVisualPreparation = KindleReadVisualPreparation()
    /// Semantic page actions are non-idempotent. Once attempted, visual/cache
    /// staging may retry, but the React paired action may not be sent again.
    private var continuousReadSemanticTurnAttempted = false
    private var continuousReadConfirmedTargetKey: String?

    // Explain prefetch layer: owns the next page block_0 plan + TTS + marks.
    private var explainPrefetchTask: Task<Void, Never>?
    private var explainPrefetchRequestID: UUID?
    private var explainPrefetchingPageKey: String?
    private var explainPagePreparation: KindleExplainPagePreparation?
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
    private var needsColdListeningPageRestore = true
    private let continueListeningGate = KindleAutoplayRequestGate()
    private var pendingAutoplayRequestID: UUID?
    private var onboardingAutoplayRetryCount = 0
    private var onboardingAutoplayRetryTask: Task<Void, Never>?
    private var continueListeningRequestedAt: [Int: Date] = [:]
    private var continueListeningTask: Task<Void, Never>?
    private var continueListeningBaselineTask: Task<Void, Never>?
    private var syncDialogResolutionTask: Task<Void, Never>?
    private var syncDialogEpoch: UInt64 = 0
    private var syncDialogShouldResume = false
    private var syncDialogResumeMode: ReaderMode?
    private var pendingStartAfterSyncResolution = false
    private struct PendingPlaybackStart {
        let id = UUID()
        let bookID: String
        let mode: ReaderMode
        let settingsRevision: UInt64
        let cancellationEpoch: UInt64
        let cancellation = KindlePlaybackStartCancellation()
    }
    private var playbackStartCancellationEpoch: UInt64 = 0
    private var pendingPlaybackStart: PendingPlaybackStart?
    private var syncDialogPlaybackStart: PendingPlaybackStart?
    private var syncDialogInterruptedStart: PendingPlaybackStart?
    #if DEBUG
    // Controlled await seams for real-model/WK tests; shared production paths
    // remain the default and the fixture never needs an Amazon or TTS request.
    var startDocumentPreparationForTesting: (() async throws -> ReadingDocument)?
    var syncDialogReadinessForTesting: (() async throws -> Void)?
    var readSpeechGeneratorForTesting: (any ParagraphSpeechGenerating)?
    #endif
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
    @Published private(set) var playerOverlayViewport: KindlePlayerOverlayViewport?
    private var playerOverlaySubscription: AnyCancellable?
    private var playerOverlayDismissTask: Task<Void, Never>?
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
        if attached {
            scheduleCookieConsentRecovery()
            webView.evaluateJavaScript(
                "window.__crKindleCookieConsentProbe && window.__crKindleCookieConsentProbe()",
                completionHandler: nil
            )
        } else {
            resetAmazonCookieConsentState(reason: .readerHidden)
        }
    }

    func setReaderPresented(_ presented: Bool) {
        guard isReaderPresented != presented else { return }
        isReaderPresented = presented
        KindleRunLog.write("KINDLE lifecycle presented=\(presented ? "Y" : "N")")
        if presented {
            // Messages received while the mini player owned the WebView are
            // intentionally rejected. Probe again when the reader becomes
            // visible so JS de-duplication cannot strand a still-visible
            // Amazon notice outside native state.
            scheduleCookieConsentRecovery()
            webView.evaluateJavaScript(
                "window.__crKindleCookieConsentProbe && window.__crKindleCookieConsentProbe()",
                completionHandler: nil
            )
            if needsForegroundVisualResync {
                KindleRunLog.write("KINDLE lifecycle visual-resync pending reason=reader-presented")
            }
        }
    }

    func setPlayerControlOverlayPresented(_ presented: Bool) {
        guard isPlayerControlOverlayPresented != presented ||
              (presented && playerOverlayViewport == nil && isReaderPresented && isReaderSurfaceAttached) else { return }
        isPlayerControlOverlayPresented = presented
        playerOverlayDismissTask?.cancel()
        playerOverlayDismissTask = nil
        clearExternalMismatchState()
        if presented {
            if isReaderSurfaceAttached, isReaderPresented,
               let visible = KindlePlayerOverlayViewport(webView: webView) {
                // @Published emits before the panel request is installed, so
                // capture and reconcile all three values before SwiftUI lays it out.
                readerSurfaceSize = visible.surfaceSize
                viewportCrop = visible.crop
                viewportPresentationFit = visible.fit
                playerOverlayViewport = visible
            }
            suppressExternalPageChangeUntil = .distantFuture
            KindleRunLog.write("KINDLE player overlay begin stableSurface=\(Self.sizeLog(readerSurfaceSize))")
        } else {
            // Let the custom panel finish its dismissal animation without
            // interpreting transient geometry or candidate order as a page turn.
            suppressExternalPageChangeUntil = Date().addingTimeInterval(1.5)
            KindleRunLog.write("KINDLE player overlay end grace=1.5 stableSurface=\(Self.sizeLog(readerSurfaceSize))")
            playerOverlayDismissTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: 600_000_000) } catch { return }
                guard let self, !self.isPlayerControlOverlayPresented else { return }
                self.playerOverlayViewport = nil
                self.playerOverlayDismissTask = nil
            }
        }
    }

    func setApplicationActive(_ active: Bool) {
        guard isApplicationActive != active else { return }
        isApplicationActive = active
        if !active { offlineDownload.pause(reason: .background) }
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
        guard readerOperationAllowed(.layoutRepair, reason: reason) else { return }
        guard !isPlayerControlOverlayPresented, playerOverlayViewport == nil else {
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
        guard size.width.isFinite, size.height.isFinite, size.width > 80, size.height > 80 else { return }
        let normalized = CGSize(
            width: max(1, size.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, size.height.rounded(.toNearestOrAwayFromZero))
        )
        guard !isPlayerControlOverlayPresented, playerOverlayViewport == nil, !isReadingSettingsPresented else {
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

        resetViewportPresentation(reason: "surface-size")
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
        if let snapshot = playerOverlayViewport { return snapshot.crop }
        if isAmazonCookieConsentVisible {
            return KindleCookieConsentViewportPolicy.effectiveCrop(
                normalCrop: viewportCrop,
                isConsentVisible: true
            )
        }
        let normalized = CGSize(
            width: max(1, size.width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, size.height.rounded(.toNearestOrAwayFromZero))
        )
        if isPlayerControlOverlayPresented || isReadingSettingsPresented {
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

    func effectiveViewportPresentationFit(forSurfaceSize size: CGSize) -> KindleViewportPresentationFit {
        if let snapshot = playerOverlayViewport { return snapshot.fit }
        guard !isAmazonCookieConsentVisible else { return .identity }
        if isPlayerControlOverlayPresented || isReadingSettingsPresented || isNativeTOCPresented || isKindleTOCVisible {
            return viewportPresentationFit
        }
        guard size.width > 80, size.height > 80 else { return viewportPresentationFit }
        if isReaderSurfaceFrozen && !Self.isOrientationChange(from: readerSurfaceSize, to: size) {
            return viewportPresentationFit
        }
        guard abs(size.width - readerSurfaceSize.width) <= 1,
              abs(size.height - readerSurfaceSize.height) <= 1 else { return .identity }
        return viewportPresentationFit
    }

    private func resetViewportPresentation(reason: String) {
        viewportPresentationGeneration &+= 1
        viewportPresentationProbeTask?.cancel()
        viewportPresentationProbeTask = nil
        viewportPresentationFit = .identity
        viewportPresentationPageRect = nil
        viewportPresentationPageKey = nil
        viewportPresentationPageCount = 0
        KindleRunLog.write("KINDLE viewport presentation reset reason=\(reason)")
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
        guard readerOperationAllowed(.layoutRepair, reason: reason) else { return }
        guard !isPlayerControlOverlayPresented, playerOverlayViewport == nil else {
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
        guard readerOperationAllowed(.layoutRepair, reason: reason) else { return }
        guard didLoad, !Task.isCancelled else { return }
        let navigation = readerControlsNavigationGeneration
        let settings = readingSettingsRevision
        webView.setNeedsLayout()
        webView.layoutIfNeeded()
        webView.scrollView.setNeedsLayout()
        webView.scrollView.layoutIfNeeded()
        configurePageModeGestures()
        installCaptureScript()
        await setKindlePageModeLocked(true)
        guard !Task.isCancelled, readerControlsNavigationGeneration == navigation,
              readingSettingsRevision == settings,
              readerOperationAllowed(.layoutRepair, reason: reason) else { return }

        do {
            let result = try await refreshReaderLayoutState(reason: reason)
            let key = result["key"] as? String ?? ""
            let liveKey = result["liveKey"] as? String ?? ""
            let orderedCount = Self.int(from: result["orderedCount"]) ?? 0
            let visibleArea = Self.numberValue(result["visibleArea"]) ?? 0
            KindleRunLog.write(
                "KINDLE reader layout repair reason=\(reason) ok=\(String(describing: result["ok"] ?? false)) key=\(Self.keyLog(key)) live=\(Self.keyLog(liveKey)) ordered=\(String(describing: result["orderedCount"] ?? 0)) viewport=\(String(describing: result["viewportWidth"] ?? 0))x\(String(describing: result["viewportHeight"] ?? 0)) visible=\(String(describing: result["visibleArea"] ?? 0)) band=\(String(describing: result["bandVisibleArea"] ?? 0))"
            )
            await logKindleGeometrySnapshot(reason: "layout-repair-\(reason)")
            guard !Task.isCancelled, readerControlsNavigationGeneration == navigation,
                  readingSettingsRevision == settings,
                  readerOperationAllowed(.layoutRepair, reason: reason) else { return }
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
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, readerOperationAllowed(.layoutRepair, reason: reason) else { return }
            KindleRunLog.write("KINDLE reader layout repair error reason=\(reason) \(error.localizedDescription)")
            scheduleReaderLayoutRepairRetry(reason: reason, attempt: attempt)
        }
    }

    /// The same core runs for the visible reader and local WK regression tests.
    /// Expanding an already usable, unchanged viewport needs only an overlay
    /// refresh. Amazon can otherwise persist an older mounted font preference
    /// from its resize handler even though the current font already reflowed.
    func refreshReaderLayoutState(reason: String) async throws -> [String: Any] {
        try requireReaderOperation(.layoutRepair, reason: reason)
        try Task.checkCancellation()
        let navigation = readerControlsNavigationGeneration
        let settings = readingSettingsRevision
        let bounds = webView.bounds
        let host = webView.superview
        let window = webView.window
        let viewportGeneration = viewportPresentationGeneration
        let surface = (host as? KindleWebViewContainer)?.bounds.size ?? readerSurfaceSize
        guard bounds.width.isFinite, bounds.height.isFinite,
              surface.width.isFinite, surface.height.isFinite else { throw CancellationError() }
        let result = try await evaluateJSON("""
        (function() {
          function read() {
            try {
              var raw = window.__crKindleState ? window.__crKindleState() : '{}';
              var state = typeof raw === 'string' ? JSON.parse(raw) : raw;
              return {
                ok: true,
                key: state && state.key || '', liveKey: state && state.liveKey || '',
                orderedCount: Number(state && state.orderedCount || 0),
                naturalWidth: Number(state && state.naturalSize && state.naturalSize.width || 0),
                naturalHeight: Number(state && state.naturalSize && state.naturalSize.height || 0),
                viewportWidth: Number(state && state.viewportWidth || 0),
                viewportHeight: Number(state && state.viewportHeight || 0),
                visibleArea: Number(state && state.visibleArea || 0),
                bandVisibleArea: Number(state && state.bandVisibleArea || 0)
              };
            } catch (_) { return {ok:false}; }
          }
          var before = read();
          var key = String(before.key || '').trim(), liveKey = String(before.liveKey || '').trim();
          var area = Math.max(before.visibleArea || 0, before.bandVisibleArea || 0);
          var surfaceWidth = \(Double(surface.width)), surfaceHeight = \(Double(surface.height));
          var retain = '\(Self.jsString(reason))' === 'expand' && before.ok && key.length > 0 &&
            before.orderedCount > 0 && Number.isFinite(area) && area > 0 &&
            Number.isFinite(before.naturalWidth) && before.naturalWidth > 0 &&
            Number.isFinite(before.naturalHeight) && before.naturalHeight > 0 &&
            surfaceWidth > 80 && surfaceHeight > 80 && area >= surfaceWidth * surfaceHeight * 0.82 &&
            innerWidth > 80 && innerHeight > 80 &&
            Math.abs(before.viewportWidth - innerWidth) <= 1 &&
            Math.abs(before.viewportHeight - innerHeight) <= 1 &&
            Math.abs(innerWidth - \(Double(bounds.width))) <= 1 &&
            Math.abs(innerHeight - \(Double(bounds.height))) <= 1 &&
            (!liveKey || liveKey === key);
          if (!retain) {
            try { window.dispatchEvent(new Event('resize')); } catch (_) {}
            try { document.dispatchEvent(new Event('visibilitychange')); } catch (_) {}
          }
          try {
            if (window.__crKindleProbe) window.__crKindleProbe.layoutRepairAt = Date.now();
          } catch (_) {}
          try { if (window.crKindleUpdateLiveOverlay) window.crKindleUpdateLiveOverlay(); } catch (_) {}
          var result = read();
          result.repairMode = retain ? 'retained' : 'poked';
          return JSON.stringify(result);
        })()
        """)
        try Task.checkCancellation()
        try requireReaderOperation(.layoutRepair, reason: reason)
        guard readerControlsNavigationGeneration == navigation, readingSettingsRevision == settings,
              viewportPresentationGeneration == viewportGeneration, webView.bounds == bounds,
              webView.superview === host, webView.window === window else { throw CancellationError() }
        KindleRunLog.write("KINDLE reader layout refresh reason=\(reason) mode=\(result["repairMode"] as? String ?? "unknown")")
        return result
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
        guard readerOperationAllowed(.layoutRepair, reason: reason) else { return false }
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

    init(
        book: KindleBook,
        staleRecoveryAlreadyAttempted: Bool = false,
        openIntent: KindleOpenIntent = .present,
        websiteDataStore: WKWebsiteDataStore? = nil,
        libraryStore: KindleLibraryStore = .shared,
        historyStore: HistoryStore = .shared
    ) {
        self.store = libraryStore
        self.historyStore = historyStore
        self.positionStorageGeneration = libraryStore.positionStorageGeneration
        var resolvedBook = book
        if KindleStorefront.entry(id: resolvedBook.storefrontID) == nil {
            resolvedBook.storefrontID = KindleStorefront.entry(url: URL(string: book.readerURL))?.id
                ?? KindleLibraryStore.shared.boundStorefrontID
        }
        self.book = resolvedBook
        let analyticsEntryPoint = BoundLibraryOnboardingStore.shared
            .analyticsEntryPoint(for: .kindle) ?? "kindle_library"
        self.analyticsContext = ProductAnalytics.shared.beginContentIntent(
            source: .kindle,
            format: .kindle,
            entryPoint: analyticsEntryPoint,
            intendedMode: "read",
            storefront: resolvedBook.storefrontID
        )
        self.cookieConsentRuntimeToken = UUID().uuidString
        let readerStorefront = KindleStorefront.entry(id: resolvedBook.storefrontID)
            ?? KindleLibraryStore.shared.boundStorefront
        let cookieConsentBridge = KindleWebScripts.amazonCookieConsentBridge(
            token: cookieConsentRuntimeToken,
            storefront: readerStorefront
        )
        let config = WKWebViewConfiguration()
        config.websiteDataStore = websiteDataStore ?? CommercialWebSession.websiteDataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let userContentController = WKUserContentController()
        userContentController.addUserScript(WKUserScript(
            source: KindleWebScripts.restrictedToKnownStorefronts(KindleOfflineSourceScript.bootstrap),
            injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        // These are the only scripts that must run before Amazon's renderer:
        // metadata wraps fetch, the small blob hook captures pre-rendered page
        // images before Kindle revokes their original object URLs, and the
        // close-only consent bridge leaves every privacy choice to Amazon and
        // asks native to reveal the full viewport when no unique close exists.
        // The ~207KB capture/UI payload stays lazy and installs after navigation.
        if #available(iOS 14.0, *) {
            userContentController.addUserScript(WKUserScript(
                source: KindleWebScripts.restrictedToKnownStorefronts(
                    KindleWebScripts.earlyPageBlobCaptureBootstrap
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
            userContentController.addUserScript(WKUserScript(
                source: KindleWebScripts.restrictedToKnownStorefronts(
                    KindleWebScripts.metadataBootstrap
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
            userContentController.addUserScript(WKUserScript(
                source: cookieConsentBridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true,
                in: .page
            ))
        } else {
            userContentController.addUserScript(WKUserScript(
                source: KindleWebScripts.restrictedToKnownStorefronts(
                    KindleWebScripts.earlyPageBlobCaptureBootstrap
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            userContentController.addUserScript(WKUserScript(
                source: KindleWebScripts.restrictedToKnownStorefronts(
                    KindleWebScripts.metadataBootstrap
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            userContentController.addUserScript(WKUserScript(
                source: cookieConsentBridge,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
        }
        // Kindle's resize handler persists a stale font closure. Keep the
        // current native preference through that event without reloading the
        // reader or changing its reading position.
        userContentController.addUserScript(WKUserScript(
            source: KindleWebScripts.restrictedToKnownStorefronts(
                KindleReadingSettingsScript.resizePreferenceCompatibilityBootstrap
            ),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true,
            in: .page
        ))
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CastReaderKindleFontDiagnostics") {
            // Opt-in, read-only diagnostics. Only a numeric font preference and
            // viewport events leave the page; never observe other storage keys.
            userContentController.addUserScript(WKUserScript(
                source: KindleWebScripts.restrictedToKnownStorefronts("""
                (() => {
                  let last, count = 0;
                  function sample(event, trusted) {
                    if (count >= 300) return;
                    let value = null;
                    try {
                      const parsed = JSON.parse(localStorage.getItem('KWR_Display_Settings') || '{}').fontSizeIndex;
                      if (typeof parsed === 'number' && Number.isFinite(parsed)) value = parsed;
                    } catch (_) {}
                    if (event === 'poll' && last === value) return;
                    last = value; count++;
                    window.webkit.messageHandlers.castReaderKindle.postMessage({
                      type:'kindle-font-diagnostic', event, value, trusted:!!trusted,
                      time:Date.now(), width:innerWidth, height:innerHeight,
                      knownReaderBundle:performance.getEntriesByType('resource').some(r => r.name.split('?')[0].endsWith('/91FlWPKIGuL.js')),
                      knownFontBundle:performance.getEntriesByType('resource').some(r => r.name.split('?')[0].endsWith('/C1I2cjCoo7L.js')),
                      locked:!!(window.__crKindleProbe && window.__crKindleProbe.pageModeLocked)
                    });
                  }
                  for (const event of ['resize', 'visibilitychange', 'pagehide']) {
                    (event === 'visibilitychange' ? document : window).addEventListener(event, e => {
                      sample(event, e.isTrusted);
                      setTimeout(() => sample(event + '-after', e.isTrusted), 50);
                    }, true);
                  }
                  sample('initial', false);
                  setInterval(() => sample('poll', false), 100);
                })();
                """), injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page
            ))
        }
        #endif
        config.userContentController = userContentController
        webView = WKWebView(frame: .zero, configuration: config)
#if DEBUG
        // Match the WeRead reader: keep the development Kindle reader inspectable so its
        // authenticated requests can be compared against the Android client. No effect in
        // App Store builds.
        webView.isInspectable = true
#endif
        webView.customUserAgent = KindleWebScripts.desktopChromeUserAgent
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        if #available(iOS 13.0, *) {
            webView.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        super.init()
        // Do not hop to RunLoop.main here: receiving the will-set publication
        // synchronously is what prevents the first panel frame from resizing WK.
        playerOverlaySubscription = PlaybackVoicePanelCenter.shared.$request
            .map { $0 != nil }
            .removeDuplicates()
            .sink { [weak self] presented in
                self?.setPlayerControlOverlayPresented(presented)
            }
        staleBookRecoveryAttempted = staleRecoveryAlreadyAttempted
        nativeTOCEntries = Self.loadCachedNativeTOCEntries(for: resolvedBook)
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

        webView.publisher(for: \.isLoading)
            .receive(on: RunLoop.main)
            .sink { [weak self] loading in
                self?.isNavigating = loading
                if loading { self?.readerControlsReady = false }
            }
            .store(in: &cancellables)
        webView.publisher(for: \.estimatedProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.loadProgress = $0 }
            .store(in: &cancellables)

        if case .autoplayRead(let requestID) = openIntent {
            requestAutoplayRead(requestID: requestID)
        }
    }

    /// Explicit teardown — the only correct place for it.
    ///
    /// `WKUserContentController` retains its script message handler **strongly**,
    /// so registering `self` creates view model → webView → configuration →
    /// userContentController → view model. That cycle means `deinit` can never
    /// run, which is exactly where the old teardown lived: replaced readers kept
    /// loading read.amazon.com with their delegates attached, and four of them at
    /// once turned a 1s redirect into 13s, then 31s, then four timeouts.
    ///
    /// Every path that stops owning a reader must call this. Do not move any of
    /// it back into `deinit`.
    func destroy() {
        offlineDownload.pause()
        playerOverlaySubscription?.cancel()
        playerOverlaySubscription = nil
        playerOverlayDismissTask?.cancel()
        playerOverlayDismissTask = nil
        playerOverlayViewport = nil
        resetReaderControlsForNavigation()
        resetViewportPresentation(reason: "destroy")
        stopAll()
        resetAmazonCookieConsentState(reason: .destroy)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "castReaderKindle")
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.scrollView.delegate = nil
        webView.stopLoading()
        cancellables.removeAll()
        libraryRecoveryWebView?.stopLoading()
        libraryRecoveryWebView = nil
        isWarmingBookSession = false
        KindleRunLog.write("KINDLE reader destroyed book=\(Self.keyLog(book.id))")
    }

    deinit {
        // Best effort only. This will not run while the content-controller cycle
        // above is intact, which is why `destroy()` exists.
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "castReaderKindle")
    }

    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body
        let isMainFrame = message.frameInfo.isMainFrame
        let sourceURL = message.frameInfo.request.url
        let sourceWebView = message.webView
        Task { @MainActor [weak self] in
            self?.handleKindleScriptMessage(
                body,
                sourceWebView: sourceWebView,
                sourceContentController: userContentController,
                isMainFrame: isMainFrame,
                sourceURL: sourceURL
            )
        }
    }

    private func handleKindleScriptMessage(
        _ body: Any,
        sourceWebView: WKWebView?,
        sourceContentController: WKUserContentController,
        isMainFrame: Bool,
        sourceURL: URL?
    ) {
        guard let payload = body as? [String: Any] else {
            KindleRunLog.write("KINDLE script message rejected reason=malformed-body")
            return
        }
        if let event = KindleSyncDialogEvent(payload: payload) {
            handleKindleSyncDialogEvent(event)
            return
        }
        let type = payload["type"] as? String ?? "unknown"
        #if DEBUG
        if type == "kindle-font-diagnostic" {
            guard ProcessInfo.processInfo.arguments.contains("-CastReaderKindleFontDiagnostics"),
                  isMainFrame, sourceWebView === webView,
                  sourceContentController === webView.configuration.userContentController else { return }
            let events: Set<String> = ["initial", "poll", "resize", "resize-after", "visibilitychange", "visibilitychange-after", "pagehide", "pagehide-after"]
            guard let event = payload["event"] as? String, events.contains(event) else { return }
            func scalar(_ key: String) -> String {
                guard let value = payload[key] as? NSNumber, value.doubleValue.isFinite else { return "unknown" }
                return value.stringValue
            }
            KindleRunLog.write("KINDLE font diagnostic event=\(event) value=\(scalar("value")) time=\(scalar("time")) trusted=\(scalar("trusted")) locked=\(scalar("locked")) viewport=\(scalar("width"))x\(scalar("height")) knownReaderBundle=\(scalar("knownReaderBundle")) knownFontBundle=\(scalar("knownFontBundle"))")
            return
        }
        #endif
        switch type {
        case "kindle-cookie-consent":
            handleAmazonCookieConsentMessage(
                payload,
                sourceWebView: sourceWebView,
                sourceContentController: sourceContentController,
                isMainFrame: isMainFrame,
                sourceURL: sourceURL
            )
        case "kindle-user-page-gesture":
            let direction = payload["direction"] as? String ?? "unknown"
            guard sourceWebView === webView,
                  sourceContentController === webView.configuration.userContentController,
                  !isKindleSyncDialogVisible else { return }
            let shouldResume = shouldResumeAfterUserPageTurn
            let navigation = beginUserNavigation(reason: "swipe-\(direction)")
            if let gesture = payload["gestureID"] as? String, let navigation {
                userGestureNavigation = (gesture, navigation.id)
            }
            if !shouldResume {
                stopPlaybackForPageTurn(reason: "paused-swipe", clearLiveOverlay: true)
                cancelInFlightProcessingForManualPageTurn(reason: "paused-swipe")
                statusText = ""
                return
            }
            guard shouldResumeAfterUserPageTurn,
                  !isPageTurnResuming,
                  !isAdvancingLivePage,
                  let oldKey = livePageKey?.nilIfEmpty else {
                let audio = AudioPlayerService.shared
                KindleRunLog.write("KINDLE user page gesture ignored direction=\(direction) active=\(shouldResumeAfterUserPageTurn ? "Y" : "N") bookMatch=\(audio.currentBookId == book.id ? "Y" : "N") playing=\(audio.isPlaying ? "Y" : "N") resuming=\(isPageTurnResuming ? "Y" : "N") advancing=\(isAdvancingLivePage ? "Y" : "N") livePage=\(livePageKey?.nilIfEmpty == nil ? "N" : "Y")")
                return
            }
            KindleRunLog.write("KINDLE user page gesture direction=\(direction) old=\(Self.keyLog(oldKey))")
            scheduleExternalPageChangeResume(
                visibleKey: nil,
                oldKey: oldKey,
                reason: "kindle-swipe-\(direction)",
                force: true
            )
        case "kindle-user-page-settled":
            guard sourceWebView === webView,
                  sourceContentController === webView.configuration.userContentController,
                  !isKindleSyncDialogVisible,
                  let navigation = userGestureNavigation,
                  payload["gestureID"] as? String == navigation.gesture else { return }
            confirmUserNavigation(id: navigation.position, state: payload)
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

    private func handleAmazonCookieConsentMessage(
        _ dictionary: [String: Any],
        sourceWebView: WKWebView?,
        sourceContentController: WKUserContentController,
        isMainFrame: Bool,
        sourceURL: URL?
    ) {
        guard let payload = KindleCookieConsentBridgePayload(dictionary: dictionary),
              let expectedASIN = expectedReaderASIN else {
            KindleRunLog.write("KINDLE cookie message rejected reason=malformed-envelope")
            return
        }
        let expected = KindleStorefront.entry(id: analyticsContext.storefront)
            ?? store.boundStorefront
        let expectedWebView = sourceWebView === webView &&
            sourceContentController === webView.configuration.userContentController
        guard isReaderSurfaceAttached,
              isReaderPresented,
              libraryRecoveryWebView == nil,
              KindleCookieConsentBridgePolicy.accepts(
                  payload,
                  expectedRuntimeToken: cookieConsentRuntimeToken,
                  activeDocumentToken: cookieConsentDocumentToken,
                  retiredDocumentTokens: retiredCookieConsentDocumentTokens,
                  isMainFrame: isMainFrame,
                  isExpectedWebView: expectedWebView,
                  sourceURL: sourceURL,
                  currentURL: webView.url,
                  expectedStorefrontID: expected.id,
                  expectedASIN: expectedASIN
              ) else {
            KindleRunLog.write("KINDLE cookie message rejected reason=origin-or-token")
            return
        }
        if cookieConsentDocumentToken == nil {
            cookieConsentDocumentToken = payload.documentToken
        }
        updateAmazonCookieConsentState(
            visible: payload.visible,
            reason: .observer,
            decision: payload.decision,
            attemptedAutoClose: payload.attemptedAutoClose
        )
    }

    private func retireAmazonCookieConsentDocument() {
        if let token = cookieConsentDocumentToken {
            retiredCookieConsentDocumentTokens.insert(token)
            if retiredCookieConsentDocumentTokens.count > 16,
               let oldest = retiredCookieConsentDocumentTokens.first {
                retiredCookieConsentDocumentTokens.remove(oldest)
            }
        }
        cookieConsentDocumentToken = nil
    }

    private func resetAmazonCookieConsentState(
        reason: KindleCookieConsentStateChangeReason
    ) {
        let wasVisible = isAmazonCookieConsentVisible
        cookieConsentEpoch &+= 1
        cookieConsentRecoveryTask?.cancel()
        cookieConsentRecoveryTask = nil
        cookieConsentAwaitingRecovery = false
        cookieConsentResumeMode = nil
        cookieConsentShouldResumePlayback = false
        isAmazonCookieConsentVisible = false
        retireAmazonCookieConsentDocument()
        if wasVisible {
            KindleRunLog.write("KINDLE cookie consent reset reason=\(reason.rawValue)")
        }
    }

    private func updateAmazonCookieConsentState(
        visible: Bool,
        reason: KindleCookieConsentStateChangeReason,
        decision: KindleCookieConsentDecision,
        attemptedAutoClose: Bool
    ) {
        let wasVisible = isAmazonCookieConsentVisible
        if wasVisible == visible {
            KindleRunLog.write(
                "KINDLE cookie consent unchanged state=\(visible ? "visible" : "hidden") storefront=\(book.storefrontID ?? "unknown") decision=\(decision.rawValue) attempted=\(attemptedAutoClose ? "Y" : "N")"
            )
            return
        }
        isAmazonCookieConsentVisible = visible
        cookieConsentEpoch &+= 1
        let epoch = cookieConsentEpoch
        KindleRunLog.write(
            "KINDLE cookie consent state=\(visible ? "visible" : "hidden") storefront=\(book.storefrontID ?? "unknown") decision=\(decision.rawValue) attempted=\(attemptedAutoClose ? "Y" : "N")"
        )
        if visible {
            cookieConsentAwaitingRecovery = false
            cookieConsentRecoveryTask?.cancel()
            cookieConsentRecoveryTask = nil
            pauseReaderAutomationForCookieConsent()
            return
        }

        cookieConsentAwaitingRecovery = wasVisible && reason == .observer
        guard KindleCookieConsentRecoveryPolicy.shouldScheduleRecovery(
            wasVisible: wasVisible,
            isVisible: visible,
            reason: reason,
            isSyncDialogVisible: isKindleSyncDialogVisible
        ) else { return }
        scheduleCookieConsentRecovery(epoch: epoch)
    }

    private func readerOperationAllowed(
        _ operation: KindleCookieConsentPipelineOperation,
        reason: String
    ) -> Bool {
        if operation == .automaticPageTurn,
           !AudioPlayerService.shared.sleepTimer.permitsAutomaticPlayback() { return false }
        let playerOverlayBlocksLayout = operation == .layoutRepair &&
            (isPlayerControlOverlayPresented || playerOverlayViewport != nil)
        let allowed = !playerOverlayBlocksLayout && !isReadingSettingsPresented && !isApplyingReadingSettings && KindleCookieConsentPipelinePolicy.allows(
            operation,
            isConsentVisible: isAmazonCookieConsentVisible
        )
        if !allowed {
            KindleRunLog.write(
                "KINDLE operation paused operation=\(operation.rawValue) reason=\(reason)"
            )
        }
        return allowed
    }

    private func requireReaderOperation(
        _ operation: KindleCookieConsentPipelineOperation,
        reason: String
    ) throws {
        guard readerOperationAllowed(operation, reason: reason) else {
            throw KindleBookError.cookieConsentVisible
        }
    }

    private func pauseReaderAutomationForCookieConsent() {
        // The identity-viewport switch resizes the WebView enough that the
        // bridge can briefly report the notice gone and visible again within
        // one episode (observed live 2026-08-09: visible → resolved → visible
        // in the same second). A later pause must not forget that the first
        // one stopped live playback, so the resume intent is sticky until the
        // episode ends via reset, navigation, or completed recovery.
        cookieConsentResumeMode = cookieConsentResumeMode ?? mode
        cookieConsentShouldResumePlayback = cookieConsentShouldResumePlayback ||
            isCurrentModePlaybackActiveOrPreparing ||
            isAdvancingLivePage ||
            isPageTurnResuming ||
            isPreparing ||
            pendingAutoplayRequestID != nil

        readerSetupTask?.cancel()
        readerSetupTask = nil
        readerLayoutRepairTask?.cancel()
        readerLayoutRepairTask = nil
        layoutPlaybackRestartTask?.cancel()
        layoutPlaybackRestartTask = nil
        navigationRestartTask?.cancel()
        navigationRestartTask = nil
        manualPageResumeTask?.cancel()
        manualPageResumeTask = nil
        modeSwitchTask?.cancel()
        modeSwitchTask = nil
        continueListeningTask?.cancel()
        continueListeningTask = nil
        onboardingAutoplayRetryTask?.cancel()
        onboardingAutoplayRetryTask = nil
        cancelContinuousReadHandoff(reason: "cookie-consent", force: true)
        invalidatePagePreloads(clearPrepared: false, reason: "cookie-consent")
        cancelLiveHighlightTasks()
        clearExternalMismatchState()

        if cookieConsentShouldResumePlayback {
            let resumeMode = cookieConsentResumeMode ?? mode
            stopPlaybackForPageTurn(
                reason: "cookie-consent",
                clearLiveOverlay: false
            )
            mode = resumeMode
        }
        isPreparing = false
        isPageTurnResuming = false
        isAdvancingLivePage = false
        statusText = AppLocalized("请先处理 Amazon 的 Cookie 提示。")
        KindleRunLog.write(
            "KINDLE cookie pipeline paused resume=\(cookieConsentShouldResumePlayback ? "Y" : "N") mode=\((cookieConsentResumeMode ?? mode).rawValue)"
        )
    }

    private func scheduleCookieConsentRecovery(epoch: UInt64? = nil) {
        guard cookieConsentAwaitingRecovery,
              !isAmazonCookieConsentVisible,
              !isKindleSyncDialogVisible,
              isReaderSurfaceAttached else { return }
        let expectedEpoch = epoch ?? cookieConsentEpoch
        cookieConsentRecoveryTask?.cancel()
        cookieConsentRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 360_000_000)
            guard !Task.isCancelled,
                  self.cookieConsentEpoch == expectedEpoch,
                  self.cookieConsentAwaitingRecovery,
                  !self.isAmazonCookieConsentVisible,
                  !self.isKindleSyncDialogVisible,
                  self.isReaderSurfaceAttached else { return }

            do {
                try self.requireReaderOperation(.readerSetup, reason: "cookie-recovery")
                self.configurePageModeGestures()
                _ = try await self.ensureCaptureScriptInstalled(
                    reason: "cookie-consent-hidden"
                )
                await self.setKindlePageModeLocked(true)
                try await self.waitForPageReady()
                try await self.waitForKindleImageStable()
                guard !Task.isCancelled,
                      self.cookieConsentEpoch == expectedEpoch,
                      !self.isAmazonCookieConsentVisible,
                      !self.isKindleSyncDialogVisible else { return }

                self.cookieConsentAwaitingRecovery = false
                self.cookieConsentRecoveryTask = nil
                let shouldResume = self.cookieConsentShouldResumePlayback
                let resumeMode = self.cookieConsentResumeMode ?? self.mode
                self.cookieConsentShouldResumePlayback = false
                self.cookieConsentResumeMode = nil
                self.mode = resumeMode

                if shouldResume {
                    _ = try await self.startCurrentMode()
                } else {
                    self.statusText = AppLocalized("打开任意位置，然后点播放开始朗读。")
                    if let key = self.livePageKey?.nilIfEmpty {
                        self.startCachingNextPage(afterKey: key)
                    }
                }
                KindleRunLog.write(
                    "KINDLE cookie pipeline recovered resume=\(shouldResume ? "Y" : "N") mode=\(resumeMode.rawValue)"
                )
            } catch is CancellationError {
                KindleRunLog.write("KINDLE cookie pipeline recovery cancelled")
            } catch {
                self.cookieConsentRecoveryTask = nil
                self.statusText = AppLocalized("Cookie 提示已关闭，点击播放即可继续。")
                KindleRunLog.write(
                    "KINDLE cookie pipeline recovery deferred error=\(error.localizedDescription)"
                )
            }
        }
    }

    private func handleKindleSyncDialogEvent(_ event: KindleSyncDialogEvent) {
        if let localLocation = event.localLocation { kindleSyncLocalLocation = localLocation }
        if let cloudLocation = event.cloudLocation { kindleSyncCloudLocation = cloudLocation }

        if let choice = event.choice {
            // Both choices select a page: Yes selects Amazon's location; No
            // selects the currently displayed one. Neither may restore an older
            // CastReader listening cursor over that explicit decision.
            _ = beginUserNavigation(reason: "sync-choice-\(choice.rawValue)")
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
            if let request = pendingPlaybackStart, playbackStartIsCurrent(request) {
                // A real Play may still be awaiting OCR, before readVM exists.
                // Transfer its intent to the dialog; its old capture cannot
                // commit when it eventually returns from that await.
                syncDialogPlaybackStart = request
                syncDialogInterruptedStart = request
                pendingPlaybackStart = nil
                pendingStartAfterSyncResolution = true
            }
            pendingStartAfterSyncResolution = pendingStartAfterSyncResolution || pendingAutoplayRequestID != nil
            isKindleSyncDialogVisible = true
            preemptReadingSettingsForSyncDialog()
            if syncDialogShouldResume || hasPendingSyncPlaybackStart {
                stopPlaybackForPageTurn(reason: "kindle-sync-dialog", clearLiveOverlay: false, preservingStartIntent: true)
                if let resumeMode = syncDialogResumeMode { mode = resumeMode }
            }
            statusText = AppLocalized("请先确认 Kindle 阅读位置。")
            KindleRunLog.write("KINDLE sync dialog shown local=\(kindleSyncLocalLocation ?? -1) cloud=\(kindleSyncCloudLocation ?? -1) resume=\((syncDialogShouldResume || hasPendingSyncPlaybackStart) ? "Y" : "N") pendingStart=\(hasPendingSyncPlaybackStart ? "Y" : "N") mode=\(mode.rawValue)")
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
        let cancellationEpoch = playbackStartCancellationEpoch
        let settingsRevision = readingSettingsRevision
        let expectedBookID = book.id
        let interruptedStart = syncDialogInterruptedStart
        syncDialogShouldResume = false
        syncDialogResumeMode = nil

        if isAmazonCookieConsentVisible || cookieConsentAwaitingRecovery {
            cookieConsentShouldResumePlayback = cookieConsentShouldResumePlayback ||
                shouldResume ||
                hasPendingSyncPlaybackStart
            cookieConsentResumeMode = cookieConsentResumeMode ?? resumeMode
            pendingStartAfterSyncResolution = false
            cookieConsentAwaitingRecovery = true
            statusText = isAmazonCookieConsentVisible
                ? AppLocalized("请先处理 Amazon 的 Cookie 提示。")
                : AppLocalized("正在恢复 Kindle 阅读页面…")
            KindleRunLog.write(
                "KINDLE sync dialog handed-off cookie recovery visible=\(isAmazonCookieConsentVisible ? "Y" : "N") resume=\(cookieConsentShouldResumePlayback ? "Y" : "N")"
            )
            scheduleCookieConsentRecovery()
            return
        }
        statusText = AppLocalized("正在应用 Kindle 阅读位置…")
        KindleRunLog.write("KINDLE sync dialog hidden reason=\(reason) local=\(kindleSyncLocalLocation ?? -1) cloud=\(kindleSyncCloudLocation ?? -1) resume=\(shouldResume ? "Y" : "N")")

        syncDialogResolutionTask?.cancel()
        syncDialogResolutionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            @MainActor func retainsResolutionOwnership() -> Bool {
                !Task.isCancelled && self.syncDialogEpoch == epoch && !self.isKindleSyncDialogVisible &&
                    self.playbackStartCancellationEpoch == cancellationEpoch &&
                    self.readingSettingsRevision == settingsRevision && self.book.id == expectedBookID &&
                    self.mode == resumeMode && !self.isReadingSettingsPresented && !self.isApplyingReadingSettings
            }
            try? await Task.sleep(nanoseconds: 650_000_000)
            guard retainsResolutionOwnership() else { return }
            do {
                try await self.prepareAfterSyncDialog(retainsOwnership: retainsResolutionOwnership)
                guard retainsResolutionOwnership() else { return }
                if let navigation = self.store.navigationPositions[self.book.id] {
                    await self.captureUserNavigation(id: navigation.id)
                    guard retainsResolutionOwnership() else { return }
                }
                self.resetLiveSession(clearPlaybackCenter: false, preservingStartIntent: true)
                // The old capture may still be returning from Vision/WK when
                // the dialog has settled. Let that specific start unwind its
                // preparation flag before creating a replacement capture.
                while let interruptedStart, !interruptedStart.cancellation.isFinished,
                      shouldResume || self.hasPendingSyncPlaybackStart {
                    try await Task.sleep(nanoseconds: 20_000_000)
                    guard retainsResolutionOwnership() else { throw CancellationError() }
                }
                let shouldStart = shouldResume || self.hasPendingSyncPlaybackStart
                self.mode = resumeMode
                self.pendingStartAfterSyncResolution = false
                self.syncDialogPlaybackStart = nil
                self.syncDialogInterruptedStart = nil
                // Publish resolution before starting. startCurrentMode() otherwise
                // sees this task and correctly defers a user tap, which would make
                // an automatic resume defer itself forever.
                self.syncDialogResolutionTask = nil
                if shouldStart {
                    let outcome = try await self.startCurrentMode()
                    self.resolvePendingOnboardingAutoplay(
                        outcome,
                        reason: "sync-dialog-resolved"
                    )
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

    private func prepareAfterSyncDialog(retainsOwnership: @MainActor () -> Bool) async throws {
        #if DEBUG
        if let prepare = syncDialogReadinessForTesting {
            try await prepare()
            return
        }
        #endif
        try await ensureCaptureScriptInstalled(reason: "kindle-sync-dialog-resolved")
        guard retainsOwnership() else { throw CancellationError() }
        try await waitForPageReady()
        guard retainsOwnership() else { throw CancellationError() }
        try await waitForKindleImageStable()
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
        let lhsStorefront = book.storefrontID
            ?? KindleStorefront.storefront(url: URL(string: book.readerURL))?.id
        let rhsStorefront = candidate.storefrontID
            ?? KindleStorefront.storefront(url: URL(string: candidate.readerURL))?.id
        if let lhsStorefront, let rhsStorefront, lhsStorefront != rhsStorefront {
            return false
        }
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
        book.storefrontID = latest.storefrontID ?? book.storefrontID
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
        openBookWithSessionPreflight()
        store.markOpened(book)
    }

    /// Amazon 用 `id_pk`/`id_pkel`（www 域，14 分钟 TTL）配对深链 reader 会话：
    /// 实测（2026-07 真机采样）它们在则开书必成、不在则必被 302 到 OpenID 登录页，
    /// 且只有书架/认证域的加载会补发——深链开书永远不会。所以开书前先查这组
    /// cookie，缺失就静默预热一次书架再开书，用户不再撞见登录页或"恢复会话"中断。
    /// cookie 在但会话仍被拒的残余情况，didFinish 的 landing == "auth" 反应式
    /// 恢复（startAuthRecovery）继续兜底，行为不变。
    private func openBookWithSessionPreflight() {
        openPreflightTask?.cancel()
        openPreflightTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let storefront = KindleStorefront.entry(id: self.book.storefrontID)
                ?? self.store.boundStorefront
            let fresh = await KindleSessionProbe.hasFreshAuthPairingCookie(for: storefront)
            guard !Task.isCancelled else { return }
            if !fresh {
                KindleRunLog.write(
                    "KINDLE open-preflight id_pk=missing warming shelf book=\(Self.keyLog(self.book.id)) sinceShelfOK=\(KindleSessionFreshness.sinceShelfOK)"
                )
                let warmed = await self.warmShelfSession()
                guard !Task.isCancelled else { return }
                KindleRunLog.write(
                    "KINDLE open-preflight shelf-warm \(warmed ? "ok" : "failed") book=\(Self.keyLog(self.book.id))"
                )
            } else {
                KindleRunLog.write("KINDLE open-preflight id_pk=fresh book=\(Self.keyLog(self.book.id))")
            }
            guard !Task.isCancelled else { return }
            self.openPreflightTask = nil
            self.load(self.book.effectiveReaderURL, reason: "open-book")
        }
    }

    func requestContinueListening() {
        guard readerOperationAllowed(.ttsPreparation, reason: "continue-listening") else {
            statusText = AppLocalized("请先处理 Amazon 的 Cookie 提示。")
            return
        }
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

    func requestAutoplayRead(requestID: UUID) {
        onboardingAutoplayRetryTask?.cancel()
        onboardingAutoplayRetryTask = nil
        onboardingAutoplayRetryCount = 0
        pendingAutoplayRequestID = requestID
        if !readerOperationAllowed(.ttsPreparation, reason: "onboarding-autoplay") {
            cookieConsentShouldResumePlayback = true
            cookieConsentResumeMode = .read
            statusText = AppLocalized("请先处理 Amazon 的 Cookie 提示。")
            return
        }
        KindleRunLog.write(
            "KINDLE onboarding autoplay requested id=\(requestID.uuidString.prefix(8)) book=\(Self.keyLog(book.id))"
        )
        if isKindleSyncDialogVisible {
            pendingStartAfterSyncResolution = true
            statusText = AppLocalized("请先确认 Kindle 阅读位置。")
            return
        }
        requestContinueListening()
    }

    var pendingOpenIntentForReplacement: KindleOpenIntent {
        pendingAutoplayRequestID.map { .autoplayRead(requestID: $0) } ?? .present
    }

    func flushListeningAnchor(reason: String) {
        listeningAnchorPersistTask?.cancel()
        listeningAnchorPersistTask = nil
        guard let anchor = pendingPersistentAnchor else { return }
        pendingPersistentAnchor = nil
        persistListeningAnchor(anchor, reason: reason)
    }

    @discardableResult
    private func beginUserNavigation(reason: String) -> KindleNavigationPosition? {
        flushListeningAnchor(reason: "before-user-navigation")
        needsColdListeningPageRestore = false
        userGestureNavigation = nil
        readVM?.discardReadingResumeForConfirmedNavigation()
        let position = store.beginNavigation(bookID: book.id, boundary: positionStorageGeneration)
        KindleRunLog.write("KINDLE user position intent reason=\(reason) saved=\(position == nil ? "N" : "Y")")
        return position
    }

    private func confirmUserNavigation(id: UUID, state: [String: Any], document: ReadingDocument? = nil) {
        guard let key = (state["key"] as? String)?.nilIfEmpty,
              let pixels = (state["pixelFingerprint"] as? String)?.nilIfEmpty,
              store.positionStorageGeneration == positionStorageGeneration,
              store.confirmNavigation(bookID: book.id, id: id, pageKey: key, pixelFingerprint: pixels,
                  pageTextHash: document.map { KindleListeningAnchorResolver.pageTextHash(paragraphs: $0.paragraphs) },
                  progressLabel: state["progress"] as? String, readerURL: state["url"] as? String) else { return }
        book.lastReadPageKey = key
        if let url = state["url"] as? String { book.lastReadURL = url }
        if let progress = state["progress"] as? String, !progress.isEmpty { book.progressLabel = progress }
        historyStore.recordKindleBook(book)
        KindleRunLog.write("KINDLE user position confirmed key=\(Self.keyLog(key)) request=\(id.uuidString.prefix(8))")
    }

    private func captureUserNavigation(id: UUID) async {
        guard let state = try? await evaluateJSON("window.__crKindleState && window.__crKindleState()") else { return }
        confirmUserNavigation(id: id, state: state)
    }

    private func restoreColdNavigationPosition(_ position: KindleNavigationPosition) async {
        guard needsColdListeningPageRestore, !isKindleSyncDialogVisible,
              store.positionStorageGeneration == positionStorageGeneration else { return }
        func stillCurrent() -> Bool {
            !Task.isCancelled && needsColdListeningPageRestore && !isKindleSyncDialogVisible &&
                store.navigationPositions[book.id]?.id == position.id &&
                store.positionStorageGeneration == positionStorageGeneration
        }
        // Even a close before the settled-page callback must not resurrect an
        // older listening cursor over the user's navigation intent.
        guard position.pixelFingerprint != nil || position.pageTextHash != nil else {
            needsColdListeningPageRestore = false
            return
        }
        do {
            try await ensureCaptureScriptInstalled(reason: "cold-user-position")
            let initialKey = await currentVisibleKindlePageKey()
            let directions: [KindlePageTurnDirection] = Array(repeating: .previous, count: 4)
                + Array(repeating: .next, count: 8)
            for step in 0...directions.count {
                guard stillCurrent() else { return }
                try await waitForKindleImageStable()
                guard stillCurrent() else { return }
                let state = try await evaluateJSON("window.__crKindleState && window.__crKindleState()")
                guard stillCurrent() else { return }
                var matches = position.pixelFingerprint != nil &&
                    state["pixelFingerprint"] as? String == position.pixelFingerprint
                if !matches, let hash = position.pageTextHash {
                    let page = try await captureVisiblePage(pageIndex: 0)
                    guard stillCurrent() else { return }
                    matches = KindleListeningAnchorResolver.pageTextHash(paragraphs: makeLiveDocument(from: page).paragraphs) == hash
                }
                if matches {
                    confirmUserNavigation(id: position.id, state: state)
                    pendingCaptureKey = state["key"] as? String
                    needsColdListeningPageRestore = false
                    KindleRunLog.write("KINDLE user position restored steps=\(step) key=\(Self.keyLog(pendingCaptureKey ?? ""))")
                    return
                }
                guard step < directions.count else { break }
                _ = try await requestKindlePageTurnTarget(directions[step], oldKey: state["key"] as? String ?? "")
            }
            if stillCurrent() {
                _ = await restorePlaybackKeyVisibility(initialKey, reason: "user-position-search-rollback", maxSteps: 2)
            }
        } catch {
            KindleRunLog.write("KINDLE user position restore deferred error=\(error.localizedDescription)")
        }
        if stillCurrent() {
            needsColdListeningPageRestore = false
            KindleRunLog.write("KINDLE user position uses visible page reason=location-unavailable")
        }
    }

    func reload() {
        guard readerOperationAllowed(.reload, reason: "user-reload") else {
            statusText = AppLocalized("请先处理 Amazon 的 Cookie 提示。")
            return
        }
        resetLiveSession(clearPlaybackCenter: false)
        if webView.url == nil {
            load(book.effectiveReaderURL, reason: "reload-empty")
        } else {
            KindleRunLog.write(
                "KINDLE webview reload \(KindleSessionProbe.safeRouteLabel(webView.url))"
            )
            webView.reload()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let finishedURL = webView.url?.absoluteString ?? ""
        let landing = KindleSessionProbe.landingKind(finishedURL)
        KindleRunLog.write("KINDLE webview didFinish \(KindleSessionProbe.safeRouteLabel(webView.url)) sinceReaderOK=\(KindleSessionFreshness.sinceReaderOK) sinceShelfOK=\(KindleSessionFreshness.sinceShelfOK)")
        let expected = KindleStorefront.entry(id: analyticsContext.storefront)
            ?? store.boundStorefront
        if let finishedDestination = webView.url,
           (expectedReaderASIN == nil ||
            !KindleStorefrontNavigationPolicy.allowsReaderMainFrame(
                finishedDestination,
                expectedStorefrontID: expected.id,
                expectedASIN: expectedReaderASIN ?? ""
            )) {
            rejectUnexpectedMainFrameDestination(
                finishedDestination,
                expected: expected
            )
            return
        }
        if let driftDomain = KindleSessionProbe.driftDomain(for: finishedURL) {
            KindleRunLog.write("KINDLE storefront drift domain=\(driftDomain)")
            if analyticsReportedDriftDomains.insert(driftDomain).inserted {
                ProductAnalytics.shared.contentFailed(
                    analyticsContext,
                    stage: "storefront_resolution",
                    code: "unknown_host:\(driftDomain)"
                )
            }
        }
        KindleSessionProbe.logCookies(reason: "book-didFinish-\(landing)")
        if landing == "reader" {
            if let observed = KindleStorefront.storefront(rawURL: finishedURL) {
                guard observed.entryEnabled, observed.id == expected.id else {
                    handoffUnexpectedStorefront(observed, expected: expected)
                    return
                }
                book.storefrontID = expected.id
            }
            KindleSessionFreshness.markReaderOK()
            authRecoveryAttempted = false
            contentCover = nil
        }
        // The one case we step in for: Amazon replaced the book with its sign-in
        // page. Reader setup would otherwise spend 12s failing against a form and
        // then tell the user the book is ready to play.
        if landing == "auth" {
            startAuthRecovery()
            return
        }
        if isStaleBookRecovering, landing == "library" {
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
        guard readerOperationAllowed(.readerSetup, reason: reason) else { return }
        readerSetupTask?.cancel()
        configurePageModeGestures()
        readerSetupTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            // Preserve Amazon's current font, margins and columns. The native
            // settings controls are only used for explicit user changes.
            guard await self.prepareReaderControls(reason: reason) else { return }
            guard !Task.isCancelled else { return }
            try? await self.waitForKindleImageStable()
            guard !Task.isCancelled else { return }
            await self.logReaderLayoutProbe(reason: reason)
            await self.logKindleGeometrySnapshot(reason: reason)
            self.schedulePendingContinueListening(reason: "webview-\(reason)")
        }
    }

    /// Basic capture and dialog observers must exist before Aa may cancel the
    /// remaining setup work. This is independent of whether a visible Amazon
    /// sync/cookie dialog currently permits interaction.
    @discardableResult
    func prepareReaderControls(reason: String) async -> Bool {
        let generation = readerControlsNavigationGeneration
        do {
            _ = try await ensureCaptureScriptInstalled(reason: "controls-\(reason)")
            guard !Task.isCancelled, readerControlsNavigationGeneration == generation,
                  !webView.isLoading else { return false }
            await setKindlePageModeLocked(true)
            return !Task.isCancelled && readerControlsNavigationGeneration == generation && readerControlsReady
        } catch {
            KindleRunLog.write("KINDLE reader controls ready=false reason=bootstrap-unconfirmed")
            return false
        }
    }

    private func resetReaderControlsForNavigation() {
        readingSettingsSessionActive = false
        readingSettingsCloseInProgress = false
        readerControlsReady = false
        readerControlsNavigationGeneration &+= 1
        readerSetupTask?.cancel()
        readerSetupTask = nil
        guard isReadingSettingsPresented || isApplyingReadingSettings else { return }
        // Only dismiss our sheet. Its onDismiss must not close/relock controls
        // in the replacement document on behalf of the old settings session.
        if isReadingSettingsPresented { suppressReadingSettingsCloseAfterSync = true }
        readingSettingsRevision &+= 1
        readingSettingsTask?.cancel()
        readingSettingsTask = nil
        isReadingSettingsPresented = false
        isApplyingReadingSettings = false
        readerFontValue = nil
        readingSettingsError = nil
        KindleRunLog.write("KINDLE reading settings preempted reason=navigation")
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
          function visible(el) {
            try {
              var style = getComputedStyle(el);
              var rect = el.getBoundingClientRect();
              return style.display !== 'none' && style.visibility !== 'hidden' &&
                rect.width > 4 && rect.height > 4;
            } catch (_) { return false; }
          }
          function structure(el) {
            try {
              return norm([
                el.id || '',
                typeof el.className === 'string' ? el.className : '',
                el.getAttribute && (el.getAttribute('data-testid') || ''),
                el.getAttribute && (el.getAttribute('data-test') || ''),
                el.getAttribute && (el.getAttribute('data-action') || ''),
                el.getAttribute && (el.getAttribute('href') || '')
              ].join(' '));
            } catch (_) { return ''; }
          }
          function errorText(value) {
            return /something went wrong|please try to open this book|algo (?:salió mal|ha salido mal)|abre este libro desde la biblioteca|algo deu errado|abra este livro (?:na|pela) biblioteca|問題が発生しました|ライブラリから.*(?:開|開き)|etwas ist schiefgelaufen|buch.*bibliothek.*öffnen|(?:une erreur s'est produite|un problème est survenu)|livre.*bibliothèque.*ouvrir|qualcosa è andato storto|libro.*libreria.*apri|कुछ गलत हो गया|किताब.*लाइब्रेरी.*खोल/i.test(value);
          }
          function libraryActionText(value) {
            return /back to library|return to library|volver a la biblioteca|voltar (?:para|à) (?:a )?biblioteca|ライブラリに戻|zurück zur bibliothek|retour à la bibliothèque|torna alla libreria|लाइब्रेरी (?:पर|में) वापस/i.test(value);
          }
          var bodyText = norm(document.body && document.body.innerText);
          var nodes = Array.prototype.slice.call(document.querySelectorAll(
            '[role="dialog"],[aria-modal="true"],[data-testid*="error" i],[class*="error" i],button,a'
          )).filter(visible);
          var libraryAction = nodes.some(function(el) {
            var text = norm((el.innerText || '') + ' ' + (el.getAttribute && el.getAttribute('aria-label') || ''));
            var token = structure(el);
            return libraryActionText(text) ||
              /kindle-library|back.*library|library.*back|return.*library/.test(token);
          });
          var errorSurface = nodes.some(function(el) {
            var token = structure(el);
            if (!/(?:^|[-_\\s])(error|failure|failed|oops)(?:$|[-_\\s])/.test(token) &&
                !(el.matches && el.matches('[role="dialog"],[aria-modal="true"]'))) {
              return false;
            }
            return errorText(norm(el.innerText || el.textContent || '')) ||
              /(?:^|[-_\\s])(error|failure|failed|oops)(?:$|[-_\\s])/.test(token);
          });
          return !!(errorText(bodyText) || (errorSurface && libraryAction));
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

    // MARK: - Amazon 会话恢复（落到登录页时）

    /// Amazon gates `read.amazon.com/?asin=` behind a reader session that only
    /// its own shelf client reactivates. Measured on device: seven consecutive
    /// book opens kept landing on the sign-in portal and never self-healed, then
    /// a single `/kindle-library` load — with no sync and no scraping — made the
    /// very next open succeed. So: load the shelf, then retry the book.
    private func startAuthRecovery() {
        guard contentCover == nil, !needsKindleRebind else { return }
        guard !authRecoveryAttempted else {
            contentCover = nil
            statusText = AppLocalized("Kindle 登录已过期，请重新登录并同步书架。")
            needsKindleRebind = true
            KindleRunLog.write("KINDLE auth-recovery exhausted book=\(Self.keyLog(book.id)) needs-rebind")
            return
        }
        authRecoveryAttempted = true
        contentCover = AppLocalized("正在恢复 Kindle 会话…")
        statusText = AppLocalized("正在恢复 Kindle 会话…")
        KindleRunLog.write("KINDLE auth-recovery start book=\(Self.keyLog(book.id)) sinceReaderOK=\(KindleSessionFreshness.sinceReaderOK) sinceShelfOK=\(KindleSessionFreshness.sinceShelfOK)")

        authRecoveryTask?.cancel()
        authRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let warmed = await self.warmShelfSession()
            guard !Task.isCancelled else { return }
            self.authRecoveryTask = nil
            if warmed {
                KindleRunLog.write("KINDLE auth-recovery shelf-warmed retrying book=\(Self.keyLog(self.book.id))")
                self.load(self.book.effectiveReaderURL, reason: "auth-recovery-retry")
            } else {
                // The shelf itself is refused, so this is not a stale reader
                // session — the account is signed out.
                self.contentCover = nil
                self.statusText = AppLocalized("Kindle 登录已过期，请重新登录并同步书架。")
                self.needsKindleRebind = true
                KindleRunLog.write("KINDLE auth-recovery shelf-failed book=\(Self.keyLog(self.book.id)) needs-rebind")
            }
        }
    }

    /// A reader session and its analytics context both belong to one
    /// marketplace. If Amazon lands this WebView on another recognized site,
    /// close the old session and hand the user to a clean rebind flow instead
    /// of silently mutating only the in-memory book.
    private func handoffUnexpectedStorefront(
        _ observed: KindleStorefront,
        expected: KindleStorefront
    ) {
        guard !storefrontHandoffInFlight else { return }
        storefrontHandoffInFlight = true
        let supported = observed.entryEnabled
        ProductAnalytics.shared.contentFailed(
            analyticsContext,
            stage: "storefront_resolution",
            code: supported
                ? "cross_storefront:\(observed.id)"
                : "unsupported_storefront:\(observed.id)"
        )
        KindleRunLog.write(
            "KINDLE storefront handoff expected=\(expected.id) observed=\(observed.id) " +
            "supported=\(supported ? "Y" : "N")"
        )
        if supported {
            store.switchStorefront(to: observed.id)
        }
        KindlePlaybackCenter.shared.clear(ifModel: self)
        NotificationCenter.default.post(
            name: .castReaderKindleRebindRequested,
            object: supported ? observed.id : expected.id
        )
    }

    /// Unknown, insecure and non-Amazon main-frame destinations receive the
    /// same atomic handoff as a recognized cross-storefront redirect, but never
    /// change the user's bound marketplace. Only a sanitized registrable domain
    /// is emitted to analytics.
    private func rejectUnexpectedMainFrameDestination(
        _ url: URL?,
        expected: KindleStorefront
    ) {
        if let observed = KindleStorefront.storefront(url: url) {
            handoffUnexpectedStorefront(observed, expected: expected)
            return
        }
        guard !storefrontHandoffInFlight else { return }
        storefrontHandoffInFlight = true
        let domain = KindleStorefront.registrableDomain(for: url?.host)
            ?? "invalid_destination"
        ProductAnalytics.shared.contentFailed(
            analyticsContext,
            stage: "storefront_resolution",
            code: "blocked_destination:\(domain)"
        )
        KindleRunLog.write(
            "KINDLE storefront navigation blocked expected=\(expected.id) domain=\(domain)"
        )
        KindlePlaybackCenter.shared.clear(ifModel: self)
        NotificationCenter.default.post(
            name: .castReaderKindleRebindRequested,
            object: expected.id
        )
    }

    /// Clears the dead Amazon session, closes the reader and hands the user to
    /// the Kindle connect flow. Reading positions are kept so rebinding restores
    /// where they were.
    func startKindleRebind() {
        KindleRunLog.write("KINDLE rebind requested book=\(Self.keyLog(book.id))")
        needsKindleRebind = false
        Task { @MainActor in
            if let storefrontID = book.storefrontID,
               storefrontID != store.boundStorefrontID {
                store.switchStorefront(to: storefrontID)
            }
            await store.markSessionExpiredForRebind()
            KindlePlaybackCenter.shared.close()
            NotificationCenter.default.post(
                name: .castReaderKindleRebindRequested,
                object: book.storefrontID
            )
        }
    }

    /// Loads the shelf purely to reactivate the session. Nothing is scraped —
    /// the page load itself is the whole mechanism. Uses the shelf-client
    /// configuration (no desktop reader UA, no reader scripts) because that is
    /// the client Amazon refreshes the book session for.
    private func warmShelfSession() async -> Bool {
        let storefront = KindleStorefront.entry(id: book.storefrontID)
            ?? store.boundStorefront
        let warmer = makeLibraryRecoveryWebView()
        let navigationGate = KindleCanonicalShelfNavigationGate(
            storefront: storefront
        )
        warmer.navigationDelegate = navigationGate
        isWarmingBookSession = true
        libraryRecoveryWebView = warmer
        defer {
            warmer.stopLoading()
            warmer.navigationDelegate = nil
            if libraryRecoveryWebView === warmer {
                libraryRecoveryWebView = nil
                isWarmingBookSession = false
            }
        }
        KindleRunLog.write("KINDLE auth-recovery shelf storefront=\(storefront.id)")
        warmer.load(URLRequest(
            url: KindleWebScripts.libraryURL(for: storefront),
            cachePolicy: .reloadIgnoringLocalCacheData
        ))

        for _ in 0..<60 {   // ~15s
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return false }
            if navigationGate.hasBlockedNavigation { return false }
            guard !warmer.isLoading else { continue }
            switch KindleSessionProbe.landingKind(warmer.url?.absoluteString ?? "") {
            case "library":
                KindleSessionFreshness.markShelfOK()
                KindleSessionProbe.logCookies(reason: "auth-recovery-shelf-ok")
                return true
            case "auth":
                KindleRunLog.write("KINDLE auth-recovery shelf landed=auth")
                return false
            default:
                continue
            }
        }
        KindleRunLog.write("KINDLE auth-recovery shelf timeout")
        return false
    }

    private func makeLibraryRecoveryWebView() -> WKWebView {
        // Keep this configuration aligned with KindleLibrarySyncViewModel. In
        // particular, do not set the desktop reader UA and do not inject reader
        // scripts; Amazon uses the shelf client to refresh its book session.
        let config = WKWebViewConfiguration()
        config.websiteDataStore = CommercialWebSession.websiteDataStore
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        let recovery = WKWebView(frame: .zero, configuration: config)
#if DEBUG
        recovery.isInspectable = true
#endif
        recovery.scrollView.contentInsetAdjustmentBehavior = .never
        recovery.scrollView.contentInset = .zero
        recovery.scrollView.scrollIndicatorInsets = .zero
        if #available(iOS 13.0, *) {
            recovery.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        }
        return recovery
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true,
              let destination = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let expected = KindleStorefront.entry(id: analyticsContext.storefront)
            ?? store.boundStorefront
        guard let expectedASIN = expectedReaderASIN,
              KindleStorefrontNavigationPolicy.allowsReaderMainFrame(
                  destination,
                  expectedStorefrontID: expected.id,
                  expectedASIN: expectedASIN
              ) else {
            decisionHandler(.cancel)
            rejectUnexpectedMainFrameDestination(destination, expected: expected)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if webView === self.webView {
            resetReaderControlsForNavigation()
            resetViewportPresentation(reason: "new-document")
        }
        finishKindleSyncDialog(reason: "navigation-start")
        resetAmazonCookieConsentState(reason: .navigationStart)
        KindleRunLog.write(
            "KINDLE webview didStart \(KindleSessionProbe.safeRouteLabel(webView.url))"
        )
        // Authoritative "what did we send" snapshot. The pre-load one is empty on
        // the first open of a launch because the shared cookie store is not
        // populated until the WebView's network process exists.
        KindleSessionProbe.logCookies(reason: "book-didStart")
    }

    /// HTTP status of the main-frame response. An expired session shows up as a
    /// 302 into the sign-in portal, while a genuine 401/403 means the request was
    /// rejected outright — worth telling apart before blaming the session.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse {
            let url = http.url?.absoluteString ?? ""
            let landing = KindleSessionProbe.landingKind(url)
            lastMainFrameStatus = http.statusCode
            KindleRunLog.write(
                "KINDLE webview response status=\(http.statusCode) \(KindleSessionProbe.safeRouteLabel(http.url))"
            )

            let expected = KindleStorefront.entry(id: analyticsContext.storefront)
                ?? store.boundStorefront
            if expectedReaderASIN == nil ||
                !KindleStorefrontNavigationPolicy.allowsReaderMainFrame(
                    http.url,
                    expectedStorefrontID: expected.id,
                    expectedASIN: expectedReaderASIN ?? ""
                ) {
                decisionHandler(.cancel)
                rejectUnexpectedMainFrameDestination(http.url, expected: expected)
                return
            }

            // Act on the response, not on `didFinish`. Amazon's sign-in page
            // does not reliably finish loading — measured on device: the response
            // arrived in 1s and `didFinish` never came at all. Everything else is
            // left alone; the reader is an ordinary web page.
            if landing == "auth" {
                Task { @MainActor [weak self] in self?.startAuthRecovery() }
            }
        }
        decisionHandler(.allow)
    }

    /// Records each server-side hop. A reader URL that ends on the sign-in portal
    /// gets there through Amazon's redirect chain, and only these hops show where
    /// the session is judged stale.
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        KindleRunLog.write(
            "KINDLE webview redirect \(KindleSessionProbe.safeRouteLabel(webView.url))"
        )
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        KindleRunLog.write(
            "KINDLE webview didFail \(KindleSessionProbe.safeRouteLabel(webView.url)) code=\((error as NSError).code)"
        )
        routeTransportFailure(error, reason: "didFail")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        KindleRunLog.write(
            "KINDLE webview didFailProvisional \(KindleSessionProbe.safeRouteLabel(webView.url)) code=\((error as NSError).code)"
        )
        routeTransportFailure(error, reason: "didFailProvisional")
    }

    /// Recorded for diagnosis only. A failed load is left to the WebView, the
    /// same as any other web page — inventing app-side retry ladders for it is
    /// what made this screen complicated in the first place.
    private func routeTransportFailure(_ error: Error, reason: String) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled else { return }
        KindleRunLog.write("KINDLE transport failure \(reason) code=\(code)")
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
        guard readerOperationAllowed(.ttsPreparation, reason: reason) else { return }
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
            pendingAutoplayRequestID = nil
            startPageKeyWatcher()
            KindlePlaybackCenter.shared.activate(model: self)
            KindleRunLog.write("KINDLE audiobook continue existing-session request=\(request) key=\(Self.keyLog(livePageKey ?? "")) p=\(vm.currentParagraphIndex)")
            return
        }

        if let autoplayRequestID = pendingAutoplayRequestID {
            startContinueListeningBaseline(
                request: request,
                requestedAt: requestedAt,
                match: .fallback,
                reason: "cold-autoplay",
                pageTextHash: ""
            )
            do {
                let outcome = try await startCurrentMode()
                resolvePendingOnboardingAutoplay(
                    outcome,
                    reason: "cold-autoplay"
                )
            } catch is CancellationError {
                KindleRunLog.write(
                    "KINDLE onboarding autoplay cancelled id=\(autoplayRequestID.uuidString.prefix(8))"
                )
            } catch {
                playbackErrorText = error.localizedDescription
                statusText = error.localizedDescription
                KindleRunLog.write(
                    "KINDLE onboarding autoplay failed id=\(autoplayRequestID.uuidString.prefix(8)) error=\(error.localizedDescription)"
                )
                schedulePendingOnboardingAutoplayRetry(reason: "start-error")
            }
            return
        }

        statusText = AppLocalized("打开任意位置，然后点播放开始朗读。")
        KindleRunLog.write("KINDLE audiobook continue unavailable request=\(request) reason=no-live-session source=\(reason) anchor=\(store.hasListeningAnchor(for: book.id) ? "Y" : "N")")
    }

    private func resolvePendingOnboardingAutoplay(
        _ outcome: KindlePlaybackStartOutcome,
        reason: String
    ) {
        guard let requestID = pendingAutoplayRequestID else { return }
        switch outcome {
        case .started:
            pendingAutoplayRequestID = nil
            onboardingAutoplayRetryTask?.cancel()
            onboardingAutoplayRetryTask = nil
            onboardingAutoplayRetryCount = 0
            KindleRunLog.write(
                "KINDLE onboarding autoplay consumed id=\(requestID.uuidString.prefix(8)) book=\(Self.keyLog(book.id)) reason=\(reason)"
            )
        case .deferred:
            if syncDialogResolutionTask == nil,
               !isKindleSyncDialogVisible,
               !pendingStartAfterSyncResolution {
                schedulePendingOnboardingAutoplayRetry(reason: reason)
            }
        case .blocked:
            KindleRunLog.write(
                "KINDLE onboarding autoplay retained id=\(requestID.uuidString.prefix(8)) reason=blocked"
            )
        }
    }

    private func schedulePendingOnboardingAutoplayRetry(reason: String) {
        guard let requestID = pendingAutoplayRequestID,
              onboardingAutoplayRetryCount < 1,
              onboardingAutoplayRetryTask == nil else { return }
        onboardingAutoplayRetryCount += 1
        onboardingAutoplayRetryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 900_000_000)
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled,
                  self.pendingAutoplayRequestID == requestID else { return }
            self.onboardingAutoplayRetryTask = nil
            KindleRunLog.write(
                "KINDLE onboarding autoplay retry id=\(requestID.uuidString.prefix(8)) reason=\(reason)"
            )
            if self.isKindleSyncDialogVisible || self.syncDialogResolutionTask != nil {
                self.pendingStartAfterSyncResolution = true
            } else {
                self.requestContinueListening()
            }
        }
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

    /// Settings deliberately own this lock while the ordinary reader pipeline
    /// is gated. Do not call the general layout-repair entry point here: it is
    /// correctly blocked while the sheet is presented.
    private func readingSettingsOwnsPage(revision: UInt64, bookID: String, viewportGeneration: UInt64) -> Bool {
        !Task.isCancelled && readingSettingsRevision == revision && book.id == bookID &&
            viewportPresentationGeneration == viewportGeneration &&
            !isKindleSyncDialogVisible && !isAmazonCookieConsentVisible
    }

    private func setReadingSettingsPageModeLocked(
        _ locked: Bool,
        revision: UInt64,
        bookID: String,
        viewportGeneration: UInt64,
        phase: String
    ) async -> Bool {
        guard readingSettingsOwnsPage(revision: revision, bookID: bookID, viewportGeneration: viewportGeneration) else { return false }
        let flag = locked ? "true" : "false"
        let script = """
        (() => {
          if (typeof window.__crKindleSetPageModeLocked !== 'function') {
            \(KindleWebScripts.pageModeLockBootstrap)
          }
          if (typeof window.__crKindleSetPageModeLocked !== 'function') return JSON.stringify({ok:false});
          if (!\(flag)) {
            // React can replace the native toolbar in the same document after
            // rotation. A dispatch flag belonging to detached nodes cannot own
            // the replacement menu; retain it while the original nodes live.
            const button=window.__crKindleFontSettingsButton, panel=window.__crKindleFontSettingsPanel;
            if ((panel && !panel.isConnected) || (button && !button.isConnected && !(panel && panel.isConnected))) {
              window.__crKindleFontOpenedByNative=false;
              window.__crKindleFontSettingsButton=null;
              window.__crKindleFontSettingsPanel=null;
            }
          }
          // Native font controls already repaginate. A synthetic resize here
          // can run Amazon's stale mount-time preference closure on relock.
          return window.__crKindleSetPageModeLocked(\(flag), false);
        })()
        """
        let result = try? await evaluateJSON(script)
        guard readingSettingsOwnsPage(revision: revision, bookID: bookID, viewportGeneration: viewportGeneration) else { return false }
        let confirmed = result.map { Self.boolValue($0["ok"]) && ($0["locked"] as? NSNumber)?.boolValue == locked } ?? false
        KindleRunLog.write("KINDLE reading settings lock phase=\(phase) requested=\(locked) confirmed=\(confirmed)")
        return confirmed
    }

    private func logReadingSettingsSample(_ result: [String: Any]?, operation: String, attempt: Int) {
        let allowedReasons: Set<String> = ["range-not-found", "settings-unavailable", "opening-settings", "invalid-range", "unsupported-range", "ambiguous-settings-button", "font-button-unavailable", "font-button-disabled", "ambiguous-font-button", "settings-menu-animating", "close-control-pending", "ambiguous-close-button", "settings-panel-ambiguous", "settings-panel-unresolved", "closing-native-menu", "native-menu-close-failed"]
        let rawReason = result?["reason"] as? String ?? ""
        let reason = result == nil ? "bridge-error" : (rawReason.isEmpty ? "none" : (allowedReasons.contains(rawReason) ? rawReason : "other"))
        func scalar(_ key: String) -> String {
            guard let number = result?[key] as? NSNumber, number.doubleValue.isFinite else { return "unknown" }
            return number.stringValue
        }
        KindleRunLog.write("KINDLE reading settings sample operation=\(operation) attempt=\(attempt) ok=\(result.map { Self.boolValue($0["ok"]) } ?? false) reason=\(reason) value=\(scalar("value")) min=\(scalar("min")) max=\(scalar("max")) persisted=\(scalar("persistedValue"))")
        #if DEBUG
        if let probe = result?["probe"], let data = try? JSONSerialization.data(withJSONObject: probe, options: .sortedKeys),
           let snapshot = String(data: data, encoding: .utf8) {
            KindleRunLog.write("KINDLE reading settings controls \(snapshot)")
        }
        #endif
    }

    /// SwiftUI can already be displaying a size-derived crop before its size
    /// callback reaches the model. Freeze that attached presentation for Aa;
    /// freezing the older model crop would resize WebKit during menu mounting.
    private func retainAttachedViewportForReadingSettings() -> Bool {
        guard let host = webView.superview as? KindleWebViewContainer else { return true }
        guard host.webView === webView, host.window != nil else { return false }
        let size = host.bounds.size
        guard size.width.isFinite, size.height.isFinite, size.width > 80, size.height > 80 else { return false }
        let crop = host.crop
        let fit = host.presentationFit.isValid ? host.presentationFit : .identity
        let canonical = KindleViewportPresentationPolicy.canonicalFrame(surfaceSize: size, crop: crop)
        guard canonical.minX.isFinite, canonical.minY.isFinite,
              canonical.width.isFinite, canonical.height.isFinite,
              abs(webView.bounds.width - canonical.width) <= 1,
              abs(webView.bounds.height - canonical.height) <= 1,
              abs(webView.center.x - (canonical.midX * fit.scale + fit.translationX)) <= 1,
              abs(webView.center.y - (canonical.midY * fit.scale + fit.translationY)) <= 1,
              webView.transform == CGAffineTransform(scaleX: fit.scale, y: fit.scale) else {
            return false
        }

        // No await or native frame assignment: discard old measurement owners,
        // then make the upcoming settings freeze use exactly the visible host.
        resetViewportPresentation(reason: "reading-settings-attached-snapshot")
        readerSurfaceSize = CGSize(width: size.width.rounded(.toNearestOrAwayFromZero),
                                   height: size.height.rounded(.toNearestOrAwayFromZero))
        viewportCrop = crop
        viewportPresentationFit = fit
        KindleRunLog.write("KINDLE reading settings viewport retained surface=\(Self.sizeLog(readerSurfaceSize)) \(Self.cropLog(crop)) fit=\(fit.scale)")
        return true
    }

    func openReadingSettings() {
        guard readerControlsReady, !isNavigating, !webView.isLoading else {
            KindleRunLog.write("KINDLE reading settings open deferred reason=reader-controls-not-ready")
            return
        }
        guard !isReadingSettingsPresented, !isApplyingReadingSettings, !isPreparing, !isPageTurnResuming,
              !isNativeTOCLoading, !isKindleSyncDialogVisible, !isAmazonCookieConsentVisible else { return }
        guard retainAttachedViewportForReadingSettings() else {
            KindleRunLog.write("KINDLE reading settings open deferred reason=reader-viewport-not-applied")
            return
        }
        suppressReadingSettingsCloseAfterSync = false
        readingSettingsSessionActive = true
        readingSettingsCloseInProgress = false
        isReadingSettingsPresented = true
        readingSettingsError = nil
        readerFontValue = nil
        readingSettingsRevision &+= 1
        let revision = readingSettingsRevision
        // Set the gate before cancelling: late page/TTS callbacks cannot resume
        // while the native sheet owns a user-requested reflow.
        cancelInFlightProcessingForManualPageTurn(reason: "reading-settings")
        cancelContinuousReadHandoff(reason: "reading-settings", force: true)
        stopPlaybackForPageTurn(reason: "reading-settings")
        invalidatePagePreloads(clearPrepared: true, reason: "reading-settings")
        readerSetupTask?.cancel()
        modeSwitchTask?.cancel()
        refocusWordRoutes.removeAll()
        isApplyingReadingSettings = true
        let expectedBookID = book.id
        let expectedViewportGeneration = viewportPresentationGeneration
        readingSettingsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.readingSettingsRevision == revision { self.isApplyingReadingSettings = false } }
            let ownsPage = { self.readingSettingsOwnsPage(revision: revision, bookID: expectedBookID, viewportGeneration: expectedViewportGeneration) }
            guard await self.setReadingSettingsPageModeLocked(false, revision: revision, bookID: expectedBookID, viewportGeneration: expectedViewportGeneration, phase: "open-unlock") else {
                if ownsPage() { self.readingSettingsError = AppLocalized("此页面暂时无法调整字号，请关闭设置后重试。") }
                return
            }
            for attempt in 1...8 {
                guard ownsPage(), self.isReadingSettingsPresented else { return }
                let result = try? await self.evaluateJSON(KindleReadingSettingsScript.read)
                guard ownsPage(), self.isReadingSettingsPresented else { return }
                self.logReadingSettingsSample(result, operation: "read", attempt: attempt)
                if let result, Self.boolValue(result["ok"]) {
                    self.adoptReaderFont(result)
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard ownsPage() else { return }
            self.readingSettingsError = AppLocalized("此页面暂时无法调整字号，请关闭设置后重试。")
        }
    }

    private func adoptReaderFont(_ result: [String: Any]) {
        readerFontValue = (result["value"] as? NSNumber)?.doubleValue
        readerFontMinimum = (result["min"] as? NSNumber)?.doubleValue ?? 0
        readerFontMaximum = (result["max"] as? NSNumber)?.doubleValue ?? 0
    }

    func changeReaderFont(by delta: Int) {
        guard isReadingSettingsPresented, !isApplyingReadingSettings,
              delta < 0 ? canDecreaseReaderFont : canIncreaseReaderFont else { return }
        readingSettingsError = nil
        isApplyingReadingSettings = true
        let revision = readingSettingsRevision
        let expectedBookID = book.id
        let expectedViewportGeneration = viewportPresentationGeneration
        readingSettingsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.readingSettingsRevision == revision { self.isApplyingReadingSettings = false } }
            let ownsPage = { self.readingSettingsOwnsPage(revision: revision, bookID: expectedBookID, viewportGeneration: expectedViewportGeneration) }
            guard ownsPage(), self.isReadingSettingsPresented else { return }
            // Never repeat a dispatched mutation when its reply is lost.
            guard let changed = try? await self.evaluateJSON(KindleReadingSettingsScript.change(by: delta)),
                  Self.boolValue(changed["ok"]), let target = changed["value"] as? NSNumber else {
                guard ownsPage() else { return }
                self.readingSettingsError = AppLocalized("此页面暂时无法调整字号，请关闭设置后重试。")
                return
            }
            guard ownsPage(), self.isReadingSettingsPresented else { return }
            for attempt in 1...8 {
                try? await Task.sleep(for: .milliseconds(200))
                guard ownsPage(), self.isReadingSettingsPresented else { return }
                let result = try? await self.evaluateJSON(KindleReadingSettingsScript.read)
                guard ownsPage(), self.isReadingSettingsPresented else { return }
                self.logReadingSettingsSample(result, operation: "confirm-change", attempt: attempt)
                if let result, Self.boolValue(result["ok"]) {
                    self.adoptReaderFont(result)
                    if self.readerFontValue == target.doubleValue { return }
                }
            }
            guard ownsPage(), self.isReadingSettingsPresented else { return }
            self.readingSettingsError = AppLocalized("此页面暂时无法调整字号，请关闭设置后重试。")
        }
    }

    func setSkipsFootnoteReferences(_ value: Bool) {
        guard isReadingSettingsPresented, !isApplyingReadingSettings else { return }
        skipsFootnoteReferences = value
        UserDefaults.standard.set(value, forKey: "kindle.skipFootnoteReferences.v1")
        invalidatePagePreloads(clearPrepared: true, reason: "footnote-setting")
    }

    private func preemptReadingSettingsForSyncDialog() {
        guard isReadingSettingsPresented || isApplyingReadingSettings else { return }
        // Dismissing the SwiftUI sheet invokes closeReadingSettings again. That
        // dismissal must not click Amazon's settings control over its dialog.
        if isReadingSettingsPresented { suppressReadingSettingsCloseAfterSync = true }
        readingSettingsRevision &+= 1
        readingSettingsTask?.cancel()
        readingSettingsTask = nil
        isReadingSettingsPresented = false
        isApplyingReadingSettings = false
        readingSettingsSessionActive = false
        readingSettingsCloseInProgress = false
        readingSettingsError = nil
        // Keep the confirmed native font and footnote preference. The user
        // chooses the sync outcome; no No/Yes or native Aa action is sent here.
        KindleRunLog.write("KINDLE reading settings preempted reason=sync-dialog")
    }

    func closeReadingSettings() {
        if suppressReadingSettingsCloseAfterSync {
            suppressReadingSettingsCloseAfterSync = false
            return
        }
        guard !isKindleSyncDialogVisible else { return }
        guard !readingSettingsCloseInProgress,
              readingSettingsSessionActive || isReadingSettingsPresented else { return }
        readingSettingsCloseInProgress = true
        readingSettingsRevision &+= 1
        readingSettingsTask?.cancel()
        readingSettingsTask = nil
        isApplyingReadingSettings = true
        isReadingSettingsPresented = false
        // The range can reflow across page boundaries. Re-capture on the next
        // explicit Play; old paragraph indices are no longer valid evidence.
        needsColdListeningPageRestore = true
        liveDocument = nil
        livePage = nil
        livePageKey = nil
        liveStartParagraphIndex = nil
        liveStartIndexKind = .sourceParagraph
        textQueue = nil
        readVM = nil
        explainVM = nil
        pageBackStack.removeAll()
        pageForwardStack.removeAll()
        let revision = readingSettingsRevision
        let expectedBookID = book.id
        let expectedViewportGeneration = viewportPresentationGeneration
        readingSettingsTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.readingSettingsRevision == revision else { return }
            defer {
                if self.readingSettingsRevision == revision {
                    self.isApplyingReadingSettings = false
                    self.readingSettingsCloseInProgress = false
                }
            }
            let ownsPage = { self.readingSettingsOwnsPage(revision: revision, bookID: expectedBookID, viewportGeneration: expectedViewportGeneration) }
            guard await self.setReadingSettingsPageModeLocked(false, revision: revision, bookID: expectedBookID, viewportGeneration: expectedViewportGeneration, phase: "close-unlock") else {
                if ownsPage() {
                    self.isReadingSettingsPresented = true
                    self.readingSettingsError = AppLocalized("此页面暂时无法调整字号，请关闭设置后重试。")
                }
                return
            }
            for attempt in 1...5 {
                guard ownsPage() else { return }
                let result = try? await self.evaluateJSON(KindleReadingSettingsScript.close(attempt: revision))
                guard ownsPage() else { return }
                let closed = result.map({ Self.boolValue($0["ok"]) }) == true
                KindleRunLog.write("KINDLE reading settings close attempt=\(attempt) confirmed=\(closed)")
                if closed {
                    if await self.setReadingSettingsPageModeLocked(true, revision: revision, bookID: expectedBookID, viewportGeneration: expectedViewportGeneration, phase: "close-relock") {
                        guard ownsPage() else { return }
                        self.readingSettingsSessionActive = false
                        return
                    }
                    break
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
            guard ownsPage() else { return }
            self.isReadingSettingsPresented = true
            self.readingSettingsError = AppLocalized("此页面暂时无法调整字号，请关闭设置后重试。")
        }
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
        needsColdListeningPageRestore = false
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
        let expectedBook = book.id
        let expectedEpoch = preloadEpoch
        let expectedGeneration = viewportPresentationGeneration
        installCaptureScript()
        do {
            let result = try await evaluateJSON("window.__crKindleGeometry && window.__crKindleGeometry()")
            guard !Task.isCancelled, book.id == expectedBook, preloadEpoch == expectedEpoch,
                  viewportPresentationGeneration == expectedGeneration else { return }
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
            let canonicalFrame = KindleViewportPresentationPolicy.canonicalFrame(surfaceSize: containerBounds.size, crop: viewportCrop)
            let swiftBlobInContainer = swiftBlob.offsetBy(dx: canonicalFrame.minX, dy: canonicalFrame.minY)
            let swiftBlobWindow = webView.convert(swiftBlob, to: nil)
            let coverageX = containerBounds.width > 0 ? swiftBlobInContainer.width / containerBounds.width : 0
            let coverageY = containerBounds.height > 0 ? swiftBlobInContainer.height / containerBounds.height : 0
            updateViewportCropIfNeeded(
                reason: reason,
                geometry: result,
                surfaceSize: containerBounds.size
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
        geometry: [String: Any],
        surfaceSize: CGSize
    ) {
        guard !isNativeTOCPresented, !isKindleTOCVisible, !isReadingSettingsPresented,
              !isPlayerControlOverlayPresented, playerOverlayViewport == nil, !isAmazonCookieConsentVisible,
              libraryRecoveryWebView == nil, !isNavigating, isReaderSurfaceAttached,
              webView.window != nil, webView.navigationDelegate === self,
              abs(surfaceSize.width - readerSurfaceSize.width) <= 1,
              abs(surfaceSize.height - readerSurfaceSize.height) <= 1 else { return }
        let canonical = KindleViewportPresentationPolicy.canonicalFrame(surfaceSize: surfaceSize, crop: viewportCrop)
        guard abs(webView.bounds.width - canonical.width) <= 2,
              abs(webView.bounds.height - canonical.height) <= 2,
              let first = KindleViewportPresentationPolicy.measurement(from: geometry, canonicalFrame: canonical) else { return }
        let generation = viewportPresentationGeneration
        let expectedBook = book.id
        let expectedEpoch = preloadEpoch
        let settingsRevision = readingSettingsRevision
        let expectedCrop = viewportCrop
        viewportPresentationProbeTask?.cancel()
        viewportPresentationProbeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 140_000_000)
                guard let self, !Task.isCancelled else { return }
                let secondResult = try await self.evaluateJSON("window.__crKindleGeometry && window.__crKindleGeometry()")
                guard !Task.isCancelled, self.viewportPresentationGeneration == generation,
                      self.book.id == expectedBook, self.preloadEpoch == expectedEpoch,
                      self.readingSettingsRevision == settingsRevision,
                      self.viewportCrop == expectedCrop,
                      abs(self.readerSurfaceSize.width - surfaceSize.width) <= 1,
                      abs(self.readerSurfaceSize.height - surfaceSize.height) <= 1,
                      !self.isNativeTOCPresented, !self.isKindleTOCVisible, !self.isReadingSettingsPresented,
                      !self.isPlayerControlOverlayPresented, self.playerOverlayViewport == nil, !self.isAmazonCookieConsentVisible,
                      self.libraryRecoveryWebView == nil, !self.isNavigating, self.isReaderSurfaceAttached,
                      self.webView.window != nil, self.webView.navigationDelegate === self,
                      abs(self.webView.bounds.width - canonical.width) <= 2,
                      abs(self.webView.bounds.height - canonical.height) <= 2,
                      let second = KindleViewportPresentationPolicy.measurement(from: secondResult, canonicalFrame: canonical),
                      first.isStable(with: second),
                      let fit = KindleViewportPresentationPolicy.contain(contentRect: second.union, surfaceSize: surfaceSize, current: self.viewportPresentationFit) else { return }
                self.viewportPresentationPageRect = second.currentPage
                self.viewportPresentationPageKey = second.pageKey
                self.viewportPresentationPageCount = second.pages.count
                if self.viewportPresentationFit != fit {
                    self.viewportPresentationFit = fit
                    KindleRunLog.write("KINDLE viewport presentation reason=\(reason) scale=\(fit.scale) offset=\(fit.translationX)|\(fit.translationY) pages=\(second.pages.count) key=\(Self.keyLog(second.pageKey))")
                }
            } catch { /* A stale or undecoded page retains the last confirmed fit. */ }
        }
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
        if mode != newMode { cancelPendingPlaybackStart(reason: "mode-selection") }
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
        guard readerOperationAllowed(.ttsPreparation, reason: reason) else { return }
        guard !Task.isCancelled, mode == oldMode else { return }
        // A mode switch tears down the active playback pipeline. Refresh the
        // authoritative quota first so a stale positive cache cannot stop the
        // current reading before the server reports that Explain is exhausted.
        let hasAccess = await resolvePlaybackAccess(
            for: newMode,
            refreshBeforeDecision: true
        )
        guard !Task.isCancelled, mode == oldMode else { return }
        let accessPlan = KindleModeSwitchAccessContract.resolve(
            requestedMode: newMode,
            hasAccess: hasAccess
        )
        if let blockedMode = accessPlan.paywallMode {
            presentPlaybackQuotaPaywall(for: blockedMode)
            return
        }
        guard accessPlan.shouldStopCurrentPlayback,
              accessPlan.shouldApplyRequestedMode else { return }

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

    @discardableResult
    func startCurrentMode() async throws -> KindlePlaybackStartOutcome {
        guard AudioPlayerService.shared.sleepTimer.permitsAutomaticPlayback() else { return .deferred }
        try requireReaderOperation(.ttsPreparation, reason: "start-current-mode")
        if isKindleSyncDialogVisible,
           (try? await evaluate("window.__crKindleSyncDialogVisible && window.__crKindleSyncDialogVisible()")) as? Bool == false {
            finishKindleSyncDialog(reason: "play-probe-hidden")
        }
        if let existing = pendingPlaybackStart, playbackStartIsCurrent(existing) {
            return .deferred // Repeated Play while preparing coalesces; it is not Pause.
        }
        let request = PendingPlaybackStart(bookID: book.id, mode: mode,
                                           settingsRevision: readingSettingsRevision,
                                           cancellationEpoch: playbackStartCancellationEpoch)
        let cancellation = request.cancellation
        return try await withTaskCancellationHandler {
            defer { cancellation.finish() }
            return try await startCurrentMode(request: request)
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func playbackStartIsCurrent(_ request: PendingPlaybackStart) -> Bool {
        !request.cancellation.isCancelled && request.bookID == book.id && request.mode == mode &&
            request.settingsRevision == readingSettingsRevision &&
            request.cancellationEpoch == playbackStartCancellationEpoch
    }

    private var hasPendingSyncPlaybackStart: Bool {
        pendingStartAfterSyncResolution && (syncDialogPlaybackStart.map(playbackStartIsCurrent) ?? true)
    }

    private func cancelPendingPlaybackStart(reason: String) {
        playbackStartCancellationEpoch &+= 1
        pendingPlaybackStart?.cancellation.cancel()
        syncDialogPlaybackStart?.cancellation.cancel()
        syncDialogInterruptedStart?.cancellation.cancel()
        pendingPlaybackStart = nil
        syncDialogPlaybackStart = nil
        syncDialogInterruptedStart = nil
        pendingStartAfterSyncResolution = false
        syncDialogShouldResume = false
        syncDialogResolutionTask?.cancel()
        syncDialogResolutionTask = nil
        KindleRunLog.write("KINDLE start intent cancelled reason=\(reason)")
    }

    private func prepareDocumentForPlaybackStart() async throws -> ReadingDocument {
        #if DEBUG
        if let prepare = startDocumentPreparationForTesting { return try await prepare() }
        #endif
        if mode == .read {
            await restoreColdListeningPageIfNeeded()
        }
        return try await ensureLiveDocument(force: true)
    }

    /// Amazon may reopen its prefetched page after process death. Resolve the
    /// durable content key before OCR builds a new paragraph index; the generic
    /// resume checkpoint then verifies the paragraph and seeks the saved word.
    private func restoreColdListeningPageIfNeeded() async {
        if let position = store.navigationPositions[book.id] {
            await restoreColdNavigationPosition(position)
            return
        }
        guard needsColdListeningPageRestore, !isKindleSyncDialogVisible,
              readerOperationAllowed(.capture, reason: "cold-resume"),
              let anchor = store.listeningAnchor(for: book.id), anchor.bookId == book.id,
              anchor.schemaVersion == KindleListeningAnchor.currentSchemaVersion,
              let checkpoint = historyStore.readingCheckpoint(for: book.id) else { return }
        guard let boundary = AccountContentIsolation.captureBoundaryToken() else { return }
        try? await ensureCaptureScriptInstalled(reason: "cold-resume")
        guard !Task.isCancelled else { return }
        if await restorePlaybackKeyVisibility(anchor.pageKey, reason: "cold-resume", maxSteps: 2) {
            needsColdListeningPageRestore = false
            pendingCaptureKey = anchor.pageKey
            KindleRunLog.write("KINDLE cold-resume page restored=true source=live-key")
            return
        }
        // Kindle raster/blob keys may change across process launches. Search
        // only adjacent rendered pages, verifying the whole normalized source
        // hash before accepting any page; never use an estimated page number.
        // This handles a provider's one-page-ahead prefetch bookmark without
        // crawling an entire long book or silently choosing a nearby sentence.
        let originalKey = await currentVisibleKindlePageKey()
        let directions: [KindlePageTurnDirection] = Array(repeating: .previous, count: 4)
            + Array(repeating: .next, count: 8)
        for step in 0...directions.count {
            guard !Task.isCancelled, needsColdListeningPageRestore,
                  AccountContentIsolation.isCurrent(boundary), !isKindleSyncDialogVisible,
                  readerOperationAllowed(.capture, reason: "cold-resume-search") else { return }
            do {
                try await waitForKindleImageStable()
                let candidate = try await captureVisiblePage(pageIndex: 0)
                let document = makeLiveDocument(from: candidate)
                let hash = KindleListeningAnchorResolver.pageTextHash(paragraphs: document.paragraphs)
                let relocated = ReadingResumeContract.relocatedKindleCheckpoint(checkpoint, paragraphs: document.paragraphs)
                if hash == anchor.pageTextHash || relocated != nil {
                    needsColdListeningPageRestore = false
                    pendingCaptureKey = candidate.key
                    KindleRunLog.write("KINDLE cold-resume page restored=true source=\(hash == anchor.pageTextHash ? "text-hash" : "word-context") steps=\(step) key=\(Self.keyLog(candidate.key))")
                    return
                }
                guard step < directions.count else { break }
                statusText = AppLocalized("正在恢复朗读位置…")
                _ = try await requestKindlePageTurnTarget(directions[step], oldKey: candidate.key)
            } catch {
                KindleRunLog.write("KINDLE cold-resume search interrupted step=\(step) error=\(error.localizedDescription)")
                break
            }
        }
        if !Task.isCancelled, AccountContentIsolation.isCurrent(boundary), needsColdListeningPageRestore {
            _ = await restorePlaybackKeyVisibility(originalKey, reason: "cold-resume-rollback", maxSteps: 2)
        }
        KindleRunLog.write("KINDLE cold-resume page restored=false source=text-hash")
    }

    private func startCurrentMode(request: PendingPlaybackStart) async throws -> KindlePlaybackStartOutcome {
        guard !Task.isCancelled, playbackStartIsCurrent(request) else { return .deferred }
        pendingPlaybackStart = request
        defer { if pendingPlaybackStart?.id == request.id { pendingPlaybackStart = nil } }
        func retainsStartOwnership() -> Bool {
            !Task.isCancelled && pendingPlaybackStart?.id == request.id && playbackStartIsCurrent(request) &&
                !isKindleSyncDialogVisible && syncDialogResolutionTask == nil &&
                !isReadingSettingsPresented && !isApplyingReadingSettings
        }
        guard !isKindleSyncDialogVisible else {
            statusText = AppLocalized("请先确认 Kindle 阅读位置。")
            pendingStartAfterSyncResolution = true
            syncDialogPlaybackStart = request
            return .deferred
        }
        if syncDialogResolutionTask != nil {
            pendingStartAfterSyncResolution = true
            syncDialogPlaybackStart = request
            statusText = AppLocalized("正在应用 Kindle 阅读位置…")
            KindleRunLog.write("KINDLE start deferred waiting-sync mode=\(mode.rawValue)")
            return .deferred
        }
        #if DEBUG
        NSLog("CRDBG KINDLE start requested mode=%@ hasRead=%@ readPara=%d preparing=%@",
              mode.rawValue,
              readVM == nil ? "N" : "Y",
              readVM?.currentParagraphIndex ?? -99,
              isPreparing ? "Y" : "N")
        #endif
        let requestedMode = mode
        switch requestedMode {
        case .read:
            if let vm = readVM, vm.currentParagraphIndex >= 0, !vm.isFinished {
                let audio = AudioPlayerService.shared
                let hasPlayableAudio = audio.isPlaying || audio.currentSegment != nil || audio.duration > 0
                if hasPlayableAudio {
                    vm.togglePlayPause()
                    startPageKeyWatcher()
                    return .started
                }
                KindleRunLog.write("KINDLE read restart stale-vm p=\(vm.currentParagraphIndex) status=\(String(describing: vm.status)) audioBook=\(Self.keyLog(audio.currentBookId ?? ""))")
            }
            guard await ensurePlaybackAccess(for: .read),
                  retainsStartOwnership(),
                  mode == requestedMode else {
                return Task.isCancelled || mode != requestedMode ? .deferred : .blocked
            }
            let singlePageDoc = try await prepareDocumentForPlaybackStart()
            guard retainsStartOwnership(), mode == requestedMode else { return .deferred }
            let doc = try await buildTextQueueForCurrentPage(baseDocument: singlePageDoc)
            guard retainsStartOwnership(), mode == requestedMode else { return .deferred }
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
            if vm.resumeNotice != nil {
                // Play is an explicit request to read the visible page even
                // when an old exact cursor cannot be relocated there.
                vm.discardReadingResumeForConfirmedNavigation()
                KindleRunLog.write("KINDLE play uses current page reason=old-cursor-unavailable")
            }
            if vm.hasPendingReadingResume {
                vm.ensurePlaying()
            } else if start > 0 {
                vm.jump(to: start)
            } else {
                vm.start()
            }
            startPageKeyWatcher()
            KindlePlaybackCenter.shared.activate(model: self)
            return .started
        case .explain:
            if let vm = explainVM {
                switch vm.status {
                case .planning, .streaming:
                    vm.togglePlayPause()
                    startPageKeyWatcher()
                    return .started
                case .completed:
                    vm.replay()
                    startPageKeyWatcher()
                    KindlePlaybackCenter.shared.activate(model: self)
                    return .started
                default:
                    break
                }
            }
            guard await ensurePlaybackAccess(for: .explain),
                  retainsStartOwnership(),
                  mode == requestedMode else {
                return Task.isCancelled || mode != requestedMode ? .deferred : .blocked
            }
            let singlePageDoc = try await prepareDocumentForPlaybackStart()
            guard retainsStartOwnership(), mode == requestedMode else { return .deferred }
            guard let vm = explainVM else { return .blocked }
            mode = .explain
            readVM?.deactivate()
            vm.activate()
            recordPlaybackStart(language: singlePageDoc.language)
            clearKindleMarkState(resetAnimationHistory: true)
            _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()")
            guard retainsStartOwnership(), mode == requestedMode else { return .deferred }
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
            return .started
        }
    }

    private func ensurePlaybackAccess(for requestedMode: ReaderMode) async -> Bool {
        let hasAccess = await resolvePlaybackAccess(for: requestedMode)
        guard !Task.isCancelled, mode == requestedMode else { return false }
        guard hasAccess else {
            presentPlaybackQuotaPaywall(for: requestedMode)
            return false
        }
        return true
    }

    private func resolvePlaybackAccess(
        for requestedMode: ReaderMode,
        refreshBeforeDecision: Bool = false
    ) async -> Bool {
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

        var didRefresh = false
        if refreshBeforeDecision, !pro.isPro {
            await pro.refresh()
            didRefresh = true
            guard !Task.isCancelled else { return false }
        }

        guard !hasAccess() else { return true }
        if !didRefresh {
            await pro.refresh()
            guard !Task.isCancelled else { return false }
        }
        return hasAccess()
    }

    private func presentPlaybackQuotaPaywall(for requestedMode: ReaderMode) {
        let quota = QuotaManager.shared
        presentPaywall(for: requestedMode, replaceExistingMode: true)
        playbackErrorText = nil
        KindleRunLog.write(
            "KINDLE paywall requested mode=\(requestedMode.rawValue) listenRemaining=\(Int(quota.listenRemaining)) explainRemaining=\(quota.explainRemaining)"
        )
    }

    private func presentPaywall(for requestedMode: ReaderMode, replaceExistingMode: Bool = false) {
        if showPaywall {
            if replaceExistingMode {
                paywallMode = requestedMode
            }
            return
        }
        paywallMode = requestedMode
        showPaywall = true
    }

    func dismissPaywall() {
        readVM?.showPaywall = false
        explainVM?.showPaywall = false
        showPaywall = false
        paywallMode = nil
    }

    func turnPage(_ direction: KindlePageTurnDirection) async {
        guard readerOperationAllowed(.pageTurn, reason: direction.logName) else {
            statusText = AppLocalized("请先处理 Amazon 的 Cookie 提示。")
            return
        }
        guard !isKindleSyncDialogVisible else {
            statusText = AppLocalized("请先确认 Kindle 阅读位置。")
            KindleRunLog.write("KINDLE page turn blocked sync-dialog direction=\(direction.logName)")
            return
        }
        let resumeMode = pendingManualPageResumeMode ?? mode
        let shouldResume = shouldResumeAfterUserPageTurn
        let navigation = beginUserNavigation(reason: "button-\(direction.logName)")
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
        stopPlaybackForPageTurn(reason: "paused-page-turn")
        cancelInFlightProcessingForManualPageTurn(reason: "paused-page-turn")

        do {
            try await ensureCaptureScriptInstalled(reason: "dispatch-only-\(direction.logName)")
            let oldKey = await currentVisibleKindlePageKey()
            let target = try await requestKindlePageTurnTarget(direction, oldKey: oldKey)
            if let navigation, let state = target.result["confirmedState"] as? [String: Any] {
                confirmUserNavigation(id: navigation.id, state: state)
            }
            let result = target.result
            let strategy = result["strategy"] as? String ?? ""
            KindleRunLog.write("KINDLE page turn dispatch-only result \(direction.logName) old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(target.targetKey)) strategy=\(strategy) tried=\(String(describing: result["tried"] ?? result["fallbackTried"] ?? "")) reason=\(String(describing: result["reason"] ?? ""))")
        } catch {
            statusText = error.localizedDescription
            KindleRunLog.write("KINDLE page turn dispatch-only error \(direction.logName) \(error.localizedDescription)")
            // 翻页失败时抓一次现场：hasNext=0 / pagination-component-unavailable 只
            // 说明「按现有规则找不到」，不说明页面变成了什么样。每次会话只抓一次。
            if !Self.didCapturePageTurnForensics {
                Self.didCapturePageTurnForensics = true
                Task { @MainActor in
                    if let dump = try? await self.evaluate(
                        KindleWebScripts.readerPageTurnForensics
                    ) {
                        KindleRunLog.write("KINDLE_TURN_FORENSICS \(dump)")
                    }
                }
            }
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
        guard readerOperationAllowed(.pageTurn, reason: "manual-\(direction.logName)") else {
            return false
        }
        let fallbackOldKey = livePageKey
        let positionID = store.navigationPositions[book.id]?.id
        let heldPage = heldPageForManualNavigation
        let reason = "manual-\(direction.logName)"
        // Stop the old page before any WebView readiness/geometry await. Audio,
        // TTS generation and continuous-page handoff must not survive a user turn.
        if shouldResumeAfterTurn {
            stopPlaybackForPageTurn(reason: reason, clearLiveOverlay: false)
            mode = resumeMode
            isPageTurnResuming = true
        }
        cancelInFlightProcessingForManualPageTurn(reason: reason)
        let navigationEpoch = preloadEpoch

        do {
            // Cancellation revokes the producer first. Wait for its one native
            // action to unwind before observing where that action actually landed.
            await heldPage?.task?.value
            guard !Task.isCancelled, preloadEpoch == navigationEpoch else { return false }
            try await ensureCaptureScriptInstalled(reason: "manual-\(direction.logName)")
            await setKindlePageModeLocked(true)

            let visibleOldKey = await currentVisibleKindlePageKey()
            let oldKey: String
            if let heldPage {
                oldKey = heldPage.key
            } else if let visibleKey = visibleOldKey.nilIfEmpty {
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

            let turnTarget = try await requestManualPageTurnTarget(
                direction, oldKey: oldKey, heldPage: heldPage
            )
            guard !Task.isCancelled, preloadEpoch == navigationEpoch else { return false }
            if let positionID, let state = turnTarget.result["confirmedState"] as? [String: Any] {
                confirmUserNavigation(id: positionID, state: state)
            }
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

    private typealias HeldPageNavigation = (key: String, fingerprint: String?, task: Task<Void, Never>?)

    private var heldPageForManualNavigation: HeldPageNavigation? {
        if explainVisualHold != nil, let preparation = explainPagePreparation,
           preparation.semanticActionAttempted {
            return (preparation.oldKey, livePage?.pixelFingerprint, preparation.task)
        }
        if continuousReadVisualHoldImage != nil, let handoff = continuousReadHandoff,
           continuousReadSemanticTurnAttempted {
            return (handoff.oldKey, livePage?.pixelFingerprint, continuousReadTurnTask)
        }
        return nil
    }

    private func requestManualPageTurnTarget(
        _ direction: KindlePageTurnDirection,
        oldKey: String,
        heldPage: HeldPageNavigation?
    ) async throws -> (targetKey: String, result: [String: Any]) {
        guard let heldPage else {
            return try await requestKindlePageTurnTarget(direction, oldKey: oldKey)
        }
        let epoch = preloadEpoch
        func requireOwner() throws {
            guard !Task.isCancelled, preloadEpoch == epoch else { throw CancellationError() }
        }
        let visible = await observedAutoAdvanceRecoveryKey(oldKey: heldPage.key)
        try requireOwner()
        guard !visible.isEmpty, visible != heldPage.key else {
            // An uncertain in-flight action cannot authorize a second forward
            // action. Leave recovery to a fresh explicit user request.
            throw KindleBookError.captureFailed("held-page-turn-not-observed")
        }
        try await waitForKindleImageStable()
        let state = try await evaluateJSON("window.__crKindleState && window.__crKindleState()")
        try requireOwner()
        guard state["key"] as? String == visible,
              let fingerprint = (state["pixelFingerprint"] as? String)?.nilIfEmpty,
              fingerprint != heldPage.fingerprint else {
            throw KindleBookError.captureFailed("held-page-target-not-stable")
        }
        if direction == .next {
            lastConfirmedTurnFingerprint = fingerprint
            KindleRunLog.write("KINDLE manual next adopts prepared page old=\(Self.keyLog(heldPage.key)) target=\(Self.keyLog(visible))")
            return (visible, ["strategy": "adopt-prepared-next", "dispatchCount": 0])
        }
        // Previous is relative to the page the user was still seeing. Reverse
        // the prepared forward action once, prove the old page, then apply the
        // user's Previous. Never silently navigate relative to the hidden page.
        let restored = try await requestKindlePageTurnTarget(.previous, oldKey: visible)
        try requireOwner()
        guard restored.targetKey == heldPage.key ||
                (heldPage.fingerprint != nil && lastConfirmedTurnFingerprint == heldPage.fingerprint) else {
            throw KindleBookError.captureFailed("held-page-restore-not-confirmed")
        }
        KindleRunLog.write("KINDLE manual previous restored displayed page key=\(Self.keyLog(restored.targetKey))")
        return try await requestKindlePageTurnTarget(.previous, oldKey: restored.targetKey)
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
            if let navigation = store.navigationPositions[book.id], let pixels = prepared.page.pixelFingerprint {
                confirmUserNavigation(id: navigation.id, state: [
                    "key": prepared.page.key, "pixelFingerprint": pixels,
                    "progress": prepared.page.progress ?? "", "url": prepared.page.url ?? book.effectiveReaderURL
                ], document: prepared.document)
            }
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

    private func requestKindlePageTurnTarget(
        _ direction: KindlePageTurnDirection,
        oldKey: String,
        onDispatchEvidence: ((KindlePageTurnDispatchEvidence) -> Void)? = nil
    ) async throws -> (targetKey: String, result: [String: Any]) {
        try requireReaderOperation(.pageTurn, reason: "dispatch-target-\(direction.logName)")
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
        let dispatchCount = Self.int(from: result["dispatchCount"])
        if dispatchCount == 0 {
            onDispatchEvidence?(.notDispatched)
        } else if dispatchCount == 1 {
            onDispatchEvidence?(.dispatched)
        }
        guard Self.boolValue(result["ok"]), dispatchCount == 1 else {
            throw KindleBookError.captureFailed(result["reason"] as? String ?? "semantic-page-action-unavailable")
        }

        var lastFingerprint: String?
        var stableSamples = 0
        var lastState: [String: Any] = beforeState
        for _ in 0..<24 {
            try await Task.sleep(nanoseconds: 200_000_000)
            try requireReaderOperation(.pageTurn, reason: "dispatch-confirm-\(direction.logName)")
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
                beforeRenderer: nil, afterRenderer: nil, direction: direction
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
                result["confirmedState"] = state
                lastConfirmedTurnFingerprint = fingerprint
                KindleRunLog.write("KINDLE_TURN_CONFIRM progress=\(String(describing: progress)) before=\(beforeFingerprint?.prefix(18) ?? "") after=\(fingerprint?.prefix(18) ?? "") stable=\(stableSamples) accepted=Y")
                return (targetKey, result)
            }
            if progress == .backward { break }
        }
        KindleRunLog.write("KINDLE_TURN_CONFIRM before=\(beforeFingerprint?.prefix(18) ?? "") after=\((lastState["pixelFingerprint"] as? String)?.prefix(18) ?? "") stable=\(stableSamples) accepted=N")
        throw KindleBookError.captureFailed("semantic-page-turn-unconfirmed")
    }

    func requestKindlePageTurn(_ direction: KindlePageTurnDirection) async throws -> [String: Any] {
        try requireReaderOperation(.pageTurn, reason: "dispatch-\(direction.logName)")
        try Task.checkCancellation()
        let settingsRevision = readingSettingsRevision
        let expectedBook = book.id
        let expectedEpoch = preloadEpoch
        let expectedViewportGeneration = viewportPresentationGeneration
        let expectedHost = webView.superview
        let expectedWindow = webView.window
        let expectedBounds = webView.bounds
        let expectedSurface = readerSurfaceSize
        let expectedAttached = isReaderSurfaceAttached
        await setKindlePageModeLockedLightweight(true, reason: "turn-\(direction.logName)")
        // The lock bridge yields to the main actor. A settings sheet, another
        // page owner, or a host replacement may have taken over during it.
        try Task.checkCancellation()
        try requireReaderOperation(.pageTurn, reason: "dispatch-after-lock-\(direction.logName)")
        guard readingSettingsRevision == settingsRevision, book.id == expectedBook,
              preloadEpoch == expectedEpoch, viewportPresentationGeneration == expectedViewportGeneration,
              webView.superview === expectedHost, webView.window === expectedWindow,
              expectedWindow != nil, webView.bounds == expectedBounds,
              readerSurfaceSize == expectedSurface, isReaderSurfaceAttached == expectedAttached else {
            throw CancellationError()
        }
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
        cancelExplainPagePreparation(reason: "stop-all")
        explainVisualHold = nil
        readingSettingsSessionActive = false
        readingSettingsCloseInProgress = false
        cancelPendingPlaybackStart(reason: "stop-all")
        readingSettingsRevision &+= 1
        readingSettingsTask?.cancel()
        flushListeningAnchor(reason: "stop-all")
        terminateContinuousReadHandoffForClosure(reason: "stop-all")
        onboardingAutoplayRetryTask?.cancel()
        onboardingAutoplayRetryTask = nil
        pendingAutoplayRequestID = nil
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
        // A replaced reader used to keep its WKWebView loading read.amazon.com in
        // the background with its delegate still attached. Four such leftovers
        // hammering the same host turned a 1s redirect into 13s, then 31s, then
        // four timeouts — and each one independently started its own session
        // recovery. Tear the transport down with the view model.
        staleBookRecoveryTask?.cancel()
        staleBookRecoveryTask = nil
        authRecoveryTask?.cancel()
        authRecoveryTask = nil
        openPreflightTask?.cancel()
        openPreflightTask = nil
        contentCover = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        Task { _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()") }
    }

    func prepareDocument(pageBudget: Int) async throws -> ReadingDocument {
        try requireReaderOperation(.capture, reason: "prepare-document")
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
            try requireReaderOperation(.capture, reason: "prepare-document-loop")
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
        try requireReaderOperation(.capture, reason: "ensure-live-document")
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
        try requireReaderOperation(.capture, reason: "ensure-live-document-ready")
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

    private func resetLiveSession(clearPlaybackCenter: Bool = true, preservingStartIntent: Bool = false) {
        if !preservingStartIntent { cancelPendingPlaybackStart(reason: "reset-live-session") }
        KindleRunLog.write("KINDLE live session reset clearCenter=\(clearPlaybackCenter ? "Y" : "N")")
        terminateContinuousReadHandoffForClosure(reason: "reset-live-session")
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
        touchCandidateCacheKey(pageKey)
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
        if let prepared = cachedNextPage,
           prepared.afterKey == afterKey,
           !normalizedPageKey(prepared.page.key).isEmpty,
           normalizedPageKey(prepared.page.key) != afterKey {
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
        touchCandidateCacheKey(key)
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
            if prefetch.textFingerprint == textFingerprint, prefetch.payload.matchesCurrentSettings {
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
            if prefetch.textFingerprint == textFingerprint, prefetch.payload.matchesCurrentSettings {
                return prefetch.payload
            }
            KindleRunLog.write("KINDLE explain prefetch discard key=\(Self.keyLog(pageKey)) reason=fingerprint-mismatch")
        }
        return nil
    }

    private func clearPreparedCandidateCaches() {
        cachedNextPage = nil
        cachedPageCandidates.removeAll()
        candidateCacheOrder.removeAll()
        cachedStartAudio = nil
        cachedStartAudioCandidates.removeAll()
        cachedExplainPrefetch = nil
        cachedExplainPrefetchCandidates.removeAll()
    }

    private func touchCandidateCacheKey(_ key: String) {
        candidateCacheOrder.removeAll { $0 == key }
        candidateCacheOrder.append(key)
    }

    private func pruneCandidateCaches(limit: Int = 24) {
        candidateCacheOrder.removeAll { cachedPageCandidates[$0] == nil }
        guard candidateCacheOrder.count > limit else { return }
        let overflow = candidateCacheOrder.count - limit
        let keysToDrop = candidateCacheOrder.prefix(overflow)
        candidateCacheOrder.removeFirst(overflow)
        for key in keysToDrop {
            cachedPageCandidates[key] = nil
            cachedStartAudioCandidates[key] = nil
            cachedExplainPrefetchCandidates[key] = nil
        }
        let keysToKeep = Set(candidateCacheOrder)
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

    private func stopPlaybackForPageTurn(reason: String, clearLiveOverlay: Bool = true, preservingStartIntent: Bool = false) {
        cancelExplainPagePreparation(reason: reason)
        if !preservingStartIntent { cancelPendingPlaybackStart(reason: reason) }
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

    var offlineSourceBook: KindleBook { book }

    private struct OfflineSourceEvidence {
        let position: KindleOfflineSourcePosition
        let words: Int
        let imageIdentity: String
    }

    private func readOfflineSourceEvidence(includeImageIdentity: Bool = false) async throws -> OfflineSourceEvidence {
        let script = includeImageIdentity
            ? "JSON.stringify({...JSON.parse(window.__crOfflineSourceRead()), imageIdentity:window.__crKindleOfflineImageIdentity()})"
            : "window.__crOfflineSourceRead && window.__crOfflineSourceRead()"
        return try parseOfflineSourceEvidence(await evaluateJSON(script))
    }

    private func parseOfflineSourceEvidence(_ value: [String: Any]) throws -> OfflineSourceEvidence {
        guard value["loading"] as? Bool == false,
              let asin = value["asin"] as? String, asin == expectedReaderASIN,
              let revision = value["revision"] as? String, !revision.isEmpty,
              let metadata = value["metadata"] as? [String: Any],
              let minimum = Self.int(from: metadata["minimum"]), let maximum = Self.int(from: metadata["maximum"]),
              minimum >= 0, maximum > minimum, maximum < Int.max,
              let start = Self.int(from: value["start"]), let end = Self.int(from: value["end"]),
              Self.int(from: value["current"]) == start,
              let page = value["page"] as? [String: Any], Self.int(from: page["start"]) == start,
              let rawEnd = Self.int(from: page["end"]), rawEnd < Int.max,
              end == rawEnd,
              let words = Self.int(from: page["words"]), words >= 0,
              let layout = value["layout"] as? [String: Any], layout["width"] != nil, layout["height"] != nil else {
            throw KindleBookError.invalidPayload
        }
        // Kindle's first sentinel is position zero; the cover glyph starts at
        // one. The renderer metadata explicitly associates that sentinel with
        // the cover. All subsequent pages retain their exact source bounds.
        let isCover = Self.int(from: metadata["cover"]) == minimum && start <= minimum + 1
        let normalizedStart = isCover ? minimum : start
        let layoutData = try JSONSerialization.data(withJSONObject: ["asin": asin, "revision": revision, "layout": layout], options: [.sortedKeys])
        let position = KindleOfflineSourcePosition(start: normalizedStart, end: min(maximum, end + 1), minimum: minimum, maximum: maximum,
            layoutID: KindleOfflinePageStore.digest(layoutData), fingerprint: "source-\(start)-\(end)")
        guard position.isValid else { throw KindleBookError.invalidPayload }
        return OfflineSourceEvidence(position: position, words: words, imageIdentity: value["imageIdentity"] as? String ?? "")
    }

    private func waitForOfflineSource(target: Int? = nil) async throws -> OfflineSourceEvidence {
        var previous: KindleOfflineSourcePosition?, stable = 0
        for _ in 0..<100 {
            try Task.checkCancellation()
            if let evidence = try? await readOfflineSourceEvidence(),
               target.map({ evidence.position.start <= $0 && evidence.position.end >= $0 }) ?? true {
                stable = previous == evidence.position ? stable + 1 : 0
                previous = evidence.position
                if stable >= 3 { return evidence }
            } else { previous = nil; stable = 0 }
            try await Task.sleep(for: .milliseconds(200))
        }
        #if DEBUG
        if let raw = try? await evaluate("window.__crOfflineSourceRead && window.__crOfflineSourceRead()") as? String,
           let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? Data(raw.utf8).write(to: root.appendingPathComponent("kindle-offline-source-timeout.json"), options: .atomic)
        }
        #endif
        throw KindleBookError.captureFailed("offline-source-not-stable")
    }

    private func waitForOfflineImage(target: Int, previousIdentity: String) async throws -> OfflineSourceEvidence {
        try Task.checkCancellation()
        try requireOfflineCapture()
        let token = UUID().uuidString
        let result = try await withTaskCancellationHandler {
            try await webView.callAsyncJavaScript("return await window.__crOfflineWaitForImage(target, previousIdentity, token);",
                arguments: ["target": target, "previousIdentity": previousIdentity, "token": token], in: nil, contentWorld: .page)
        } onCancel: { [weak self] in
            Task { @MainActor in
                self?.webView.evaluateJavaScript("window.__crOfflineCancelWait && window.__crOfflineCancelWait('\(token)')", completionHandler: nil)
            }
        }
        try Task.checkCancellation()
        try requireOfflineCapture()
        guard let json = result as? String,
              let value = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let status = value["status"] as? String else { throw KindleBookError.invalidPayload }
        if let metrics = value["metrics"] as? [String: Any] {
            KindleRunLog.write("KINDLE_OFFLINE_WAIT target=\(target) checks=\(Self.int(from: metrics["checks"]) ?? -1) loadingChecks=\(Self.int(from: metrics["loadingChecks"]) ?? -1) elapsedMs=\(Self.int(from: metrics["elapsedMs"]) ?? -1) recovered=\(metrics["recovered"] as? Bool ?? false) status=\(status)")
        }
        if status == "cancelled" { throw CancellationError() }
        if status == "timeout" { throw KindleOfflineCaptureFailure.pageNotReady }
        guard status == "ready" || status == "same-image", let raw = value["source"] as? [String: Any] else {
            throw KindleBookError.invalidPayload
        }
        var source = try parseOfflineSourceEvidence(raw)
        if status == "same-image" {
            try await waitForKindleImageStable()
            let confirmed = try await readOfflineSourceEvidence(includeImageIdentity: true)
            guard confirmed.position == source.position, confirmed.imageIdentity == source.imageIdentity else {
                throw KindleOfflineBookStore.Failure.discontinuousPage
            }
            source = confirmed
        }
        guard source.position.start <= target, source.position.end >= target, !source.imageIdentity.isEmpty else {
            throw KindleOfflineBookStore.Failure.discontinuousPage
        }
        return source
    }

    func beginOfflineBookCapture(restoring interruptedPosition: KindleOfflineSourcePosition?) async throws -> KindleOfflineSourcePosition {
        guard offlineCaptureOriginal == nil, let scope = KindleOfflineContext.currentScope else { throw KindleBookError.busy }
        cancelInFlightProcessingForManualPageTurn(reason: "offline-book-download")
        stopPlaybackForPageTurn(reason: "offline-book-download")
        stopFollowing()
        stopPageKeyWatcher()
        _ = try await ensureCaptureScriptInstalled(reason: "offline-book-download")
        try await waitForPageReady()
        let observed = try await waitForOfflineSource()
        if let interruptedPosition {
            guard interruptedPosition.layoutID == observed.position.layoutID,
                  interruptedPosition.minimum == observed.position.minimum,
                  interruptedPosition.maximum == observed.position.maximum else { throw KindleOfflineBookStore.Failure.staleGeneration }
        }
        let original = interruptedPosition ?? observed.position
        let asinJSON = try jsonString([expectedReaderASIN ?? ""])
        guard (try await evaluate("window.__crOfflineProgressGuard(true, (\(asinJSON))[0])") as? Bool) == true else {
            throw KindleBookError.captureFailed("offline-progress-guard-unavailable")
        }
        offlineCaptureOriginal = original
        offlineCaptureScope = scope
        offlineCaptureNavigationGeneration = readerControlsNavigationGeneration
        if interruptedPosition != nil {
            guard (try await evaluate("window.__crOfflineSourceMove(\(original.start))") as? Bool) == true else { throw KindleBookError.invalidPayload }
            _ = try await waitForOfflineSource(target: original.start)
        }
        return original
    }

    private func requireOfflineCapture() throws {
        guard offlineCaptureOriginal != nil, offlineCaptureScope == KindleOfflineContext.currentScope,
              offlineCaptureNavigationGeneration == readerControlsNavigationGeneration else { throw CancellationError() }
        try requireReaderOperation(.capture, reason: "offline-book-capture")
    }

    func captureOfflineBookPage(after previous: KindleOfflineSourcePosition?) async throws -> KindleOfflineCapturedPage {
        try requireOfflineCapture()
        guard let original = offlineCaptureOriginal else { throw CancellationError() }
        let started = Date()
        let target = previous.map { $0.end + 1 } ?? original.minimum
        let end = previous.map { String($0.end) } ?? "null"
        // Read the old image and advance in one WebKit round trip. Property
        // evaluation order preserves the identity from before the page turn.
        let advance = try await evaluateJSON("JSON.stringify({identity:window.__crKindleOfflineImageIdentity(), advanced:window.__crOfflineSourceAdvance(\(target), \(end))})")
        guard advance["advanced"] as? Bool == true, let previousIdentity = advance["identity"] as? String else { throw KindleBookError.invalidPayload }
        let before = try await waitForOfflineImage(target: target, previousIdentity: previousIdentity)
        let readyAt = Date()
        guard before.position.layoutID == original.layoutID else { throw KindleOfflineBookStore.Failure.staleGeneration }
        if let previous { guard before.position.follows(previous) else { throw KindleOfflineBookStore.Failure.discontinuousPage } }
        else { guard before.position.isFirst else { throw KindleOfflineBookStore.Failure.discontinuousPage } }
        try requireOfflineCapture()
        let raw = try await webView.callAsyncJavaScript("return await window.__crKindleOfflineImage();",
            arguments: [:], in: nil, contentWorld: .page)
        guard let value = raw as? String, let bytes = value.data(using: .utf8),
              let payload = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let dataURL = payload["image"] as? String, let imageData = Self.decodeDataURL(dataURL) else { throw KindleBookError.badImage }
        let document = ReadingDocument(title: book.title, sourceKind: .kindle, language: book.language ?? "und",
            paragraphs: [ReadingParagraph(id: 0, text: "", type: .image, pageIndex: 0, imageData: imageData)])
        try requireOfflineCapture()
        guard let sourceEvidence = payload["source"] as? [String: Any] else { throw KindleBookError.invalidPayload }
        let after = try parseOfflineSourceEvidence(sourceEvidence)
        guard after.position == before.position, payload["identity"] as? String == before.imageIdentity else {
            throw KindleOfflineBookStore.Failure.discontinuousPage
        }
        let position = KindleOfflineSourcePosition(start: before.position.start, end: before.position.end,
            minimum: before.position.minimum, maximum: before.position.maximum, layoutID: before.position.layoutID,
            fingerprint: KindleOfflinePageStore.digest(imageData))
        KindleRunLog.write("KINDLE_OFFLINE_IMAGE start=\(position.start) end=\(position.end) bytes=\(imageData.count) readyMs=\(Int(readyAt.timeIntervalSince(started)*1000)) transferMs=\(Int(Date().timeIntervalSince(readyAt)*1000)) ocr=0")
        return KindleOfflineCapturedPage(position: position, document: document, requiresOCR: true, sourceWordCount: before.words)
    }

    func endOfflineBookCapture() async -> Bool {
        guard let original = offlineCaptureOriginal else { return true }
        defer {
            offlineCaptureOriginal = nil; offlineCaptureScope = nil; offlineCaptureNavigationGeneration = nil
            webView.evaluateJavaScript("window.__crOfflineProgressGuard && window.__crOfflineProgressGuard(false); window.__crKindleOfflineResetCandidates && window.__crKindleOfflineResetCandidates();", completionHandler: nil)
        }
        guard offlineCaptureScope == KindleOfflineContext.currentScope,
              offlineCaptureNavigationGeneration == readerControlsNavigationGeneration else { return false }
        do {
            guard (try await evaluate("window.__crOfflineSourceMove(\(original.start))") as? Bool) == true else { return false }
            let restored = try await waitForOfflineSource(target: original.start)
            return restored.position.start == original.start && restored.position.end == original.end
        } catch { return false }
    }

    #if DEBUG
    func prepareOfflineDiagnostics() {
        cancelInFlightProcessingForManualPageTurn(reason: "offline-diagnostic")
        stopPlaybackForPageTurn(reason: "offline-diagnostic")
        stopFollowing()
    }

    func captureOfflineDiagnosticPage() async throws -> ReadingDocument {
        guard !isPreparing else { throw KindleBookError.busy }
        prepareOfflineDiagnostics()
        isPreparing = true
        defer { isPreparing = false }
        let generation = readerControlsNavigationGeneration
        _ = try await ensureCaptureScriptInstalled(reason: "offline-diagnostic")
        try await waitForPageReady()
        try await waitForKindleImageStable()
        let page = try await captureVisiblePage(pageIndex: 0)
        guard generation == readerControlsNavigationGeneration else { throw CancellationError() }
        offlineDiagnosticPageKey = page.key
        return makeDocument(from: [page])
    }

    func saveCurrentOfflinePage() async throws -> KindleOfflinePageStore.SavedPage {
        guard let scope = KindleOfflineContext.currentScope,
              let boundary = AccountContentIsolation.captureBoundaryToken() else { throw KindleBookError.invalidPayload }
        let document = try await captureOfflineDiagnosticPage()
        guard AccountContentIsolation.isCurrent(boundary), scope == KindleOfflineContext.currentScope,
              let key = offlineDiagnosticPageKey else { throw CancellationError() }
        let saved = try await KindleOfflinePageStore.shared.save(document: document, pageKey: book.id + ":" + key, scope: scope)
        guard AccountContentIsolation.isCurrent(boundary), scope == KindleOfflineContext.currentScope else { throw CancellationError() }
        return saved
    }

    private func offlineDiagnosticMove(to position: Int) async throws {
        let script = """
        (() => { const context = \(KindleWebScripts.offlineSourceNavigation);
          if (!context || \(position) < context.minimum || \(position) > context.maximum) return false;
          context.navigation.moveToPosition(\(position)); return true; })()
        """
        guard (try await evaluate(script) as? Bool) == true else { throw KindleBookError.invalidPayload }
        var stable = 0
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(200))
            let state = try await evaluateJSON("JSON.stringify((() => { const c = \(KindleWebScripts.offlineSourceNavigation); return c ? {current:c.current,range:c.range,loading:c.loading} : {}; })())")
            let range = state["range"] as? [String: Any] ?? [:]
            let start = Self.int(from: range["startPosition"]), end = Self.int(from: range["endPosition"])
            if let start, let end, (start <= position || position == 0 && start == 1), end >= position,
               Self.int(from: state["current"]) == start, state["loading"] as? Bool == false {
                stable += 1
                if stable >= 5 { return }
            } else { stable = 0 }
        }
        throw KindleBookError.invalidPayload
    }

    func runOfflinePageFlipDiagnostic(_ command: String) async throws -> String {
        guard KindleStorefront.matches(url: webView.url) else { throw KindleBookError.invalidPayload }
        if command.hasPrefix("jump:"), let position = Int(command.dropFirst(5)), position >= 0 {
            prepareOfflineDiagnostics()
            try await offlineDiagnosticMove(to: position)
            return "已确认源阅读位置：\(position)"
        }
        if command == "renderer" {
            prepareOfflineDiagnostics()
            let installed = try await evaluateJSON(KindleWebScripts.offlineRendererProbeInstall)
            guard Self.boolValue(installed["ok"]) else { throw KindleBookError.invalidPayload }
            guard let originalPosition = Self.int(from: installed["originalPosition"]) else { throw KindleBookError.invalidPayload }
            try await offlineDiagnosticMove(to: 0)
            var report: [String: Any] = [:]
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(250))
                report = try await evaluateJSON("JSON.stringify(window.__crOfflineRendererProbe.report)")
                if Self.boolValue(report["complete"]) { break }
            }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("KindleOfflineDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]).write(
                to: directory.appendingPathComponent("renderer-capabilities.json"), options: .atomic)
            try await offlineDiagnosticMove(to: originalPosition)
            return "源渲染页面请求已记录，已确认返回原位置。"
        }
        if command == "source" {
            guard let result = try await evaluate(KindleWebScripts.offlineSourceCapabilities) as? String else {
                throw KindleBookError.invalidPayload
            }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("KindleOfflineDiagnostics", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(result.utf8).write(to: directory.appendingPathComponent("source-capabilities.json"), options: .atomic)
            return "整书定位能力已记录到本机。"
        }
        return try await offlineProbeSession.run(command) { [weak self] script in
            guard let self else { throw CancellationError() }
            return try await self.evaluate(script)
        }
    }
    #endif

    func pauseReadPlayback() {
        guard mode == .read else { return }
        cancelInFlightProcessingForManualPageTurn(reason: "user-pause")
        readVM?.pausePlayback()
    }

    private func cancelInFlightProcessingForManualPageTurn(reason: String) {
        cancelPendingPlaybackStart(reason: reason)
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
        if mode == .read, readVM?.isPlaybackPausedByUser == true { return false }
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
                      self.readerOperationAllowed(.automaticPageTurn, reason: "page-key-watcher"),
                      !self.isKindleSyncDialogVisible,
                      !self.isPageTurnResuming,
                      !self.isAdvancingLivePage,
                      self.continuousReadTurnTask == nil,
                      self.continuousReadCommitTask == nil,
                      self.explainPagePreparation == nil,
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
        guard readerOperationAllowed(.layoutRepair, reason: reason) else { return }
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
        reason: String,
        appReviewReadSession: AppReviewReadSessionProgress? = nil,
        continueLogicalReadSession: Bool = false
    ) async throws {
        try requireReaderOperation(.ttsPreparation, reason: "restart-after-page-turn")
        switch mode {
        case .read:
            let queuedDocument = try await buildTextQueueForCurrentPage(baseDocument: document)
            let start = liveStartParagraphIndex
                ?? queuedDocument.paragraphs.first(where: { $0.type.isReadable })?.id
                ?? 0
            let fingerprint = readSpeechFingerprint(document)
            let startAudio = consumeStartAudioCandidate(
                pageKey: target.page.key,
                textFingerprint: fingerprint,
                voiceID: AppSettings.shared.voice(for: document.language)
            )
            let hasPrefetchedStart = startAudio?.paragraphIndex == start && !(startAudio?.segments.isEmpty ?? true)
            let prefetchedSegmentCount = hasPrefetchedStart ? (startAudio?.segments.count ?? 0) : 0
            KindleRunLog.write("KINDLE read restart after-turn begin reason=\(reason) key=\(Self.keyLog(target.page.key)) start=\(start) prefetched=\(hasPrefetchedStart ? "Y" : "N") segs=\(prefetchedSegmentCount)")
            if let appReviewReadSession,
               readVM?.inheritAppReviewReadSession(appReviewReadSession) != true {
                throw KindleBookError.captureFailed("automatic-review-session-adoption-failed")
            }
            if continueLogicalReadSession {
                _ = readVM?.claimLogicalAnalyticsSessionForPageHandoff()
            }
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
        var speechGenerator: (any ParagraphSpeechGenerating)? = nil
        #if DEBUG
        speechGenerator = readSpeechGeneratorForTesting
        #endif
        let vm = ReadAloudViewModel(
            document: document,
            analyticsContext: analyticsContext,
            analyticsSessionCoordinator: readAnalyticsSessionCoordinator,
            historyStore: historyStore,
            speechGenerator: speechGenerator
        )
        vm.configurePlaybackMetadata(id: book.id, title: book.title, coverURL: book.coverURL)
        activeReadNavigationID = store.navigationPositions[book.id]?.id
        if activeReadNavigationID != nil { vm.discardReadingResumeForConfirmedNavigation() }
        bindReadPageFinished(vm, session: session)
        KindleRunLog.write(
            "KINDLE read session installed generation=\(session.generation) " +
            "document=\(session.documentID.prefix(8)) key=\(Self.keyLog(livePageKey ?? ""))"
        )
        return vm
    }

    private func bindReadPageFinished(_ vm: ReadAloudViewModel, session: KindleReadPageSession) {
        vm.onAppReviewReadSessionInvalidated = { [weak self, weak vm] in
            guard let self, self.readVM === vm else { return }
            self.cancelAutomaticAppReviewContinuation(for: session)
        }
        vm.onDocumentFinished = { [weak self, weak vm] appReviewContinuation in
            guard let self, let vm else { return }
            if let appReviewContinuation,
               self.readVM === vm,
               self.activeReadPageSession == session {
                self.automaticAppReviewContinuation.arm(appReviewContinuation)
                self.automaticAppReviewContinuationGeneration = session.generation
            } else {
                self.cancelAutomaticAppReviewContinuation(for: session)
            }
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
        automaticAppReviewContinuation.cancel()
        automaticAppReviewContinuationGeneration = nil
        activeReadPageSession = nil
        consumedReadPageGeneration = nil
    }

    private func cancelAutomaticAppReviewContinuation(for session: KindleReadPageSession) {
        guard automaticAppReviewContinuationGeneration == session.generation else { return }
        automaticAppReviewContinuation.cancel()
        automaticAppReviewContinuationGeneration = nil
    }

    private func takeAutomaticAppReviewContinuation(
        for session: KindleReadPageSession
    ) -> AppReviewReadSessionProgress? {
        let matches = automaticAppReviewContinuationGeneration == session.generation
        automaticAppReviewContinuationGeneration = nil
        return automaticAppReviewContinuation.takeForConfirmedAutomaticCommit(matches)
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
        historyStore.recordKindleBook(book, language: language)
    }

    func refocusPlaybackPosition(reason: String) async {
        guard readerOperationAllowed(.visualRecovery, reason: reason) else { return }
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
        let audio = AudioPlayerService.shared
        guard audio.currentBookId == book.id, audio.hasAudibleProgress,
              !audio.isBuffering, audio.isPlaying,
              let pageKey = rawPageKey?.trimmingCharacters(in: .whitespacesAndNewlines),
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
        guard store.positionStorageGeneration == positionStorageGeneration,
              store.saveListeningAnchor(anchor, navigationID: activeReadNavigationID) else { return }
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
        try requireReaderOperation(.ttsPreparation, reason: "build-read-window")
        let settingsRevision = readingSettingsRevision
        let epoch = preloadEpoch
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
        guard !Task.isCancelled, settingsRevision == readingSettingsRevision, epoch == preloadEpoch,
              !isReadingSettingsPresented, !isApplyingReadingSettings else { throw CancellationError() }
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
        let speechPage = KindleFootnoteSpeech.prepare(document: currentDocument, skipReferences: skipsFootnoteReferences)
        let projections = Dictionary(uniqueKeysWithValues: speechPage.paragraphs.map { ($0.sourceParagraphID, $0) })
        let currentParas = speechPage.paragraphs.map(\.spokenParagraph).filter(Self.isReadableKindleParagraph)
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
                return word.reidentified(id: nextWordID)
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
                        sourceWordIndex: projections[part.source.id]?.sourceWordIndex(forSpokenWordIndex: lower + offset) ?? (lower + offset)
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

    private func readSpeechFingerprint(_ document: ReadingDocument) -> String {
        KindleFootnoteSpeech.prepare(document: document, skipReferences: skipsFootnoteReferences).cacheSignature
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
            .removeDuplicates()
            .sink { [weak self] shouldShow in
                guard shouldShow else { return }
                self?.presentPaywall(for: .read)
            }
            .store(in: &playbackCancellables)

        explainVM.$showPaywall
            .removeDuplicates()
            .sink { [weak self] shouldShow in
                guard shouldShow else { return }
                self?.presentPaywall(for: .explain)
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
                if self.refreshContinuousReadVisualHoldHighlight(
                    document: readVM.document,
                    paragraphIndex: paragraphIndex,
                    wordRange: range
                ) {
                    return
                }
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
                self?.maybePrepareExplainPageDuringAudioTail()
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
                    guard let self, self.mode == .explain,
                          self.explainPagePreparation == nil else { return }
                    await self.scrollToParagraph(paragraphIndex)
                }
            }
            .store(in: &playbackCancellables)

        // A fast opening may finish before the quality plan's final block
        // count arrives. Only the VM's settled-plan completion may turn the
        // page; observing `.completed` directly could skip the remaining plan.
        explainVM.onDocumentFinished = { [weak self, weak explainVM] in
            guard let self, let explainVM,
                  self.mode == .explain, self.explainVM === explainVM else { return }
            self.isContinuingExplainPage = true
            Task { @MainActor [weak self, weak explainVM] in
                guard let self, let explainVM,
                      self.explainVM === explainVM else { return }
                await self.advanceToNextExplainPageIfNeeded()
            }
        }
    }

    @discardableResult
    private func startReadPlayback(
        document: ReadingDocument,
        startHint: Int? = nil,
        prefetchedIndex: Int? = nil,
        prefetchedSegments: [AudioSegment] = [],
        reason: String
    ) -> Bool {
        guard readerOperationAllowed(.ttsPreparation, reason: reason) else { return false }
        guard mode == .read, let vm = readVM else { return false }
        vm.discardReadingResumeForConfirmedNavigation()
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
        guard readerOperationAllowed(.automaticPageTurn, reason: reason) else { return }
        if continuousReadHandoff != nil {
            appendContinuousReadAudioIfReady()
            return
        }
        guard continuousReadHandoff == nil,
              continuousReadCommitTask == nil,
              mode == .read,
              !isAdvancingLivePage,
              !isPageTurnResuming,
              !isKindleSyncDialogVisible,
              let vm = readVM,
              vm.canContinueAcrossLivePageBoundary,
              let oldKey = livePageKey?.nilIfEmpty,
              let target = preparedCandidate(afterKey: oldKey) else { return }

        let fingerprint = readSpeechFingerprint(target.document)
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
        let tail = vm.preparedKindlePageAudioTail
        let canPrepare = AudioPlayerService.shared.isPlaying && tail.map {
            KindleContinuousPageHandoffContract.shouldBeginPagePreparation($0, playbackRate: AudioPlayerService.shared.playbackRate)
        } == true
        guard shouldArm || canPrepare,
              prefetched.paragraphIndex >= 0,
              !prefetched.segments.isEmpty,
              let predecessor = tail?.lastSegmentID ?? AudioPlayerService.shared.queuedTailSegmentID else { return }

        continuousReadHandoffSerial += 1
        let serial = continuousReadHandoffSerial
        let rebased = continuousReadSegments(prefetched.segments, serial: serial)
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
        continuousReadAudioAppended = false
        continuousReadOldVMDetached = false
        continuousReadAppReviewSession = nil
        continuousReadAnalyticsOwner = nil
        continuousReadAudioCompletedBeforeCommit = false
        continuousReadAudioBoundaryReached = false
        continuousReadAudioGateReleasePresented = false
        continuousReadAudioGateReleaseTask?.cancel()
        continuousReadAudioGateReleaseTask = nil
        continuousReadVisualHoldImage = nil
        continuousReadVisualHoldHighlightRectsNorm = []
        continuousReadVisualPreparation = KindleReadVisualPreparation()
        continuousReadTurnFailureCount = 0
        continuousReadSemanticTurnAttempted = false
        continuousReadConfirmedTargetKey = nil
        continuousReadStagedPage = nil
        continuousReadStagedLiveKey = nil
        let audio = AudioPlayerService.shared

        KindleRunLog.write(
            "KINDLE read continuous armed reason=\(reason) serial=\(serial) old=\(Self.keyLog(oldKey)) " +
            "next=\(Self.keyLog(target.page.key)) predecessor=\(predecessor) segs=\(rebased.count)"
        )
        appendContinuousReadAudioIfReady()
        handleContinuousReadHandoffProgress(
            currentTime: audio.currentTime,
            duration: audio.duration,
            segment: audio.currentSegment
        )
    }

    /// Preparation may span the last two paragraphs. Queue publication may
    /// not: ordinary paragraph playback replaces its own queue, so append only
    /// after the final paragraph has actually installed its complete audio.
    private func appendContinuousReadAudioIfReady() {
        guard !continuousReadAudioAppended,
              let handoff = continuousReadHandoff,
              let vm = readVM, vm.isOnLastReadableParagraph,
              vm.currentTTSCompleteForPageHandoff else { return }
        let audio = AudioPlayerService.shared
        guard audio.queuedTailSegmentID == handoff.predecessorSegmentID else {
            cancelContinuousReadHandoff(reason: "prepared-page-tail-changed")
            return
        }
        let serial = handoff.serial
        audio.canStartQueuedSegment = { [weak self] segment in
            guard let self,
                  let active = self.continuousReadHandoff,
                  active.serial == serial,
                  active.segmentIDs.contains(segment.id) else {
                return true
            }
            self.beginContinuousReadPageTurnIfNeeded(serial: serial, trigger: "queue-gate")
            let fingerprintMatches = self.continuousReadStagedPage.map {
                self.readSpeechFingerprint($0.document) ==
                    self.readSpeechFingerprint(active.target.document)
            } ?? false
            if self.continuousReadStagedPage != nil, !fingerprintMatches {
                // The semantic action reached a different surface than the
                // speculative cache predicted. Wait for this audio boundary,
                // then commit the confirmed surface with freshly generated audio.
                self.beginContinuousReadCommitIfNeeded(serial: serial)
            }
            let shouldRelease = KindleContinuousPageHandoffContract.shouldReleaseAudioGate(
                hasConfirmedVisibleSurface: self.continuousReadStagedPage != nil,
                textFingerprintMatches: fingerprintMatches,
                firstHighlightHandshakeFinished: self.continuousReadAudioGateReleasePresented
            )
            if !shouldRelease,
               self.continuousReadStagedPage != nil,
               fingerprintMatches {
                self.scheduleContinuousReadAudioGateRelease(serial: serial)
            }
            return shouldRelease
        }
        continuousReadAudioAppended = true
        let appendedAfter = audio.appendPreparedSegmentsForContinuousPlayback(handoff.segments)
        guard appendedAfter == handoff.predecessorSegmentID else {
            cancelContinuousReadHandoff(reason: "queue-boundary-changed")
            return
        }

        KindleRunLog.write("KINDLE read continuous queue-attached serial=\(serial) predecessor=\(handoff.predecessorSegmentID)")
    }

    private func handleContinuousReadHandoffProgress(
        currentTime: Double,
        duration: Double,
        segment: AudioSegment?
    ) {
        guard mode == .read else { return }
        if continuousReadHandoff == nil {
            maybeArmContinuousReadHandoff(reason: "prepared-page-tail")
        } else {
            appendContinuousReadAudioIfReady()
        }
        guard let handoff = continuousReadHandoff, let segment else { return }

        if handoff.segmentIDs.contains(segment.id) {
            beginContinuousReadCommitIfNeeded(serial: handoff.serial)
            return
        }

        guard AudioPlayerService.shared.isPlaying,
              let tail = readVM?.preparedKindlePageAudioTail,
              tail.lastSegmentID == handoff.predecessorSegmentID else { return }
        let remaining = tail.remainingAudioSeconds
        if KindleContinuousPageHandoffContract.shouldBeginPagePreparation(
            tail, playbackRate: AudioPlayerService.shared.playbackRate
        ) {
            guard continuousReadTurnTask == nil,
                  continuousReadVisualPreparation.canPrepareEarly else { return }
            let rate = max(0.25, Double(AudioPlayerService.shared.playbackRate))
            KindleRunLog.write(
                "KINDLE read continuous tail-threshold serial=\(handoff.serial) " +
                "remainingMs=\(Int(remaining / rate * 1_000)) " +
                "leadMs=\(Int(KindleContinuousPageHandoffContract.visualTurnLeadSeconds * 1_000))"
            )
            beginContinuousReadPageTurnIfNeeded(serial: handoff.serial, trigger: "tail-lead")
        }
    }

    private func beginContinuousReadPageTurnIfNeeded(serial: Int, trigger: String) {
        guard readerOperationAllowed(.automaticPageTurn, reason: trigger) else { return }
        guard continuousReadTurnTask == nil,
              let handoff = continuousReadHandoff,
              handoff.serial == serial,
              continuousReadVisualPreparation.begin(atAudioBoundary: trigger != "tail-lead") else { return }
        suppressExternalPageChangeUntil = Date().addingTimeInterval(6)
        clearExternalMismatchState()
        KindleRunLog.write(
            "KINDLE read continuous visual-turn begin trigger=\(trigger) serial=\(serial) " +
            "old=\(Self.keyLog(handoff.oldKey)) target=\(Self.keyLog(handoff.target.page.key))"
        )
        continuousReadTurnTask = Task { @MainActor [weak self] in
            guard let self else { return }
            if trigger == "tail-lead" {
                let captured = await self.captureContinuousReadVisualHold(serial: serial)
                guard !Task.isCancelled, self.continuousReadHandoff?.serial == serial else { return }
                self.continuousReadVisualPreparation.finishCapture(succeeded: captured)
                if !captured {
                    // Without a cover, an early semantic action would expose the
                    // next page while the previous sentence is still audible.
                    // Fall back to doing the real turn at the queue boundary.
                    self.continuousReadTurnTask = nil
                    KindleRunLog.write(
                        "KINDLE read continuous visual-turn deferred serial=\(serial) reason=hold-capture-failed retry=audio-boundary highlight=preserved"
                    )
                    self.restoreContinuousReadLiveHighlight()
                    // The queue gate may have run while WebKit was capturing.
                    // Wake that concrete held item instead of waiting for a
                    // playback tick that can no longer arrive at the boundary.
                    AudioPlayerService.shared.resumeGatedSegmentIfPossible()
                    return
                }
                // Let SwiftUI publish the held frame before changing Kindle's
                // underlying page.
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
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
                        AudioPlayerService.shared.nextSegment(automatically: true)
                    }
                }
            }
        }
    }

    private func stageContinuousReadPage(_ handoff: KindleContinuousReadHandoff) async throws {
        guard !Task.isCancelled, continuousReadHandoff?.serial == handoff.serial else {
            throw CancellationError()
        }
        continuousReadVisualPreparation.beginStaging()
        cancelLiveHighlightTasks()
        let started = ProcessInfo.processInfo.systemUptime
        func mark(_ stage: String) {
            KindleRunLog.write("KINDLE_HANDOFF serial=\(handoff.serial) stage=\(stage) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
        }
        mark("begin")
        try requireReaderOperation(.automaticPageTurn, reason: "continuous-stage")
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

        mark("turn-confirmed")
        let staged = try await preparedPageForNativeAutoAdvance(
            afterKey: handoff.oldKey,
            targetKey: targetKey,
            mode: .read
        )
        mark("page-prepared")
        let actualKey = try await installLiveOverlay(page: staged.page, document: staged.document)
        guard continuousReadHandoff?.serial == handoff.serial else { throw CancellationError() }
        let prefetchedFingerprint = readSpeechFingerprint(handoff.target.document)
        let stagedFingerprint = readSpeechFingerprint(staged.document)
        var fingerprintMatches = prefetchedFingerprint == stagedFingerprint
        var resolvedHandoff = handoff

        if !fingerprintMatches {
            do {
                let retargeted = try await prepareContinuousReadRetarget(
                    handoff: handoff,
                    staged: staged
                )
                guard continuousReadHandoff?.serial == handoff.serial else {
                    throw CancellationError()
                }
                resolvedHandoff = retargeted
                continuousReadHandoff = retargeted
                fingerprintMatches =
                    readSpeechFingerprint(retargeted.target.document) == stagedFingerprint
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                KindleRunLog.write(
                    "KINDLE read continuous retarget-miss serial=\(handoff.serial) " +
                    "key=\(Self.keyLog(staged.page.key)) error=\(error.localizedDescription)"
                )
            }
        }

        mark("overlay-audio-ready")
        continuousReadStagedPage = staged
        continuousReadStagedLiveKey = actualKey
        #if DEBUG
        debugPreparedHeldPageKey = staged.page.key
        #endif
        continuousReadTurnFailureCount = 0
        releaseContinuousReadVisualHoldIfReady(reason: "staged-after-audio-boundary")

        if continuousReadAudioAppended,
           resolvedHandoff.target.page.key == staged.page.key,
           resolvedHandoff.target.page.key != handoff.target.page.key {
            let audio = AudioPlayerService.shared
            let wasGated = audio.isQueuedSegmentGated
            let removed = audio.removePendingSegments(withIDs: handoff.segmentIDs)
            let appendedAfter = removed
                ? audio.appendPreparedSegmentsForContinuousPlayback(resolvedHandoff.segments)
                : nil
            guard removed, appendedAfter == resolvedHandoff.predecessorSegmentID else {
                throw KindleBookError.captureFailed("continuous-retarget-queue-changed")
            }
            KindleRunLog.write(
                "KINDLE read continuous retargeted serial=\(handoff.serial) " +
                "from=\(Self.keyLog(handoff.target.page.key)) to=\(Self.keyLog(staged.page.key)) " +
                "segs=\(resolvedHandoff.segments.count) gated=\(wasGated ? "Y" : "N")"
            )
            if wasGated {
                audio.nextSegment(automatically: true)
            }
        }

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

    private func captureContinuousReadVisualHold(serial: Int) async -> Bool {
        #if DEBUG
        debugPreparedHeldPageKey = nil
        #endif
        func failed(_ reason: String) -> Bool {
            KindleRunLog.write("KINDLE read continuous visual-hold unavailable serial=\(serial) reason=\(reason)")
            return false
        }
        guard continuousReadHandoff?.serial == serial else { return failed("handoff-changed") }
        guard webView.window != nil else { return failed("webview-detached") }

        let surface = readerSurfaceSize
        guard surface.width > 40, surface.height > 40 else { return failed("surface-size") }
        var leaseFailure = "viewport-lease"
        guard let viewportLease = KindleVisualHoldViewportLease(
            webView: webView, surfaceSize: surface, onFailure: { leaseFailure = $0 }
        ) else { return failed(leaseFailure) }
        let fit = viewportLease.fit
        let canonical = viewportLease.canonical
        let expectedBook = book.id
        let expectedEpoch = preloadEpoch
        let settingsRevision = readingSettingsRevision
        let expectedGeneration = viewportPresentationGeneration
        let expectedModelFit = viewportPresentationFit
        let expectedCrop = viewportCrop
        func retainsCaptureOwnership() -> Bool {
            !Task.isCancelled && continuousReadHandoff?.serial == serial &&
                book.id == expectedBook && preloadEpoch == expectedEpoch &&
                readingSettingsRevision == settingsRevision &&
                !isReadingSettingsPresented && !isApplyingReadingSettings &&
                viewportPresentationGeneration == expectedGeneration &&
                viewportPresentationFit == expectedModelFit && viewportCrop == expectedCrop &&
                readerSurfaceSize == surface && viewportLease.isCurrent
        }
        var pageRect = viewportPresentationPageRect
        var pageCount = viewportPresentationPageCount
        if normalizedPageKey(viewportPresentationPageKey) != normalizedPageKey(continuousReadHandoff?.oldKey) {
            pageRect = nil
        }
        if pageRect == nil,
           let geometry = try? await evaluateJSON("window.__crKindleGeometry && window.__crKindleGeometry()"),
           let measured = KindleViewportPresentationPolicy.measurement(from: geometry, canonicalFrame: canonical),
           normalizedPageKey(measured.pageKey) == normalizedPageKey(continuousReadHandoff?.oldKey) {
            pageRect = measured.currentPage
            pageCount = measured.pages.count
        }
        guard retainsCaptureOwnership() else { return failed("ownership-before-capture") }
        let paintedPage = pageRect.map { fit.applying(to: $0) }

        // Prefer the lossless page raster already used for OCR. Unlike a
        // WKWebView snapshot it never bakes the last DOM highlight into the held
        // frame, which lets SwiftUI keep painting one moving word above it.
        if let page = livePage,
           pageCount == 1, let paintedPage,
           normalizedPageKey(page.key) == normalizedPageKey(continuousReadHandoff?.oldKey),
           let image = UIImage(data: page.imageData) {
            continuousReadVisualHoldImageRect = paintedPage
            continuousReadVisualHoldHighlightContentRect = paintedPage
            continuousReadVisualHoldImage = image
            refreshContinuousReadVisualHoldHighlight()
            KindleRunLog.write(
                "KINDLE read continuous visual-hold captured serial=\(serial) " +
                "source=page-raster image=\(Self.sizeLog(image.size)) " +
                "highlightRects=\(continuousReadVisualHoldHighlightRectsNorm.count)"
            )
            return true
        }

        // Snapshot the canonical viewport, then apply the same native mapping
        // as the live WKWebView. This also preserves the second visible page.
        let rect = viewportLease.webBounds
        // Temporarily mask the word only for the snapshot. Never delete the
        // live highlight: a rejected snapshot must reveal the latest position.
        // Reject a changed transform before dispatch and after WKWebView's
        // asynchronous snapshot. Falling back to the audio boundary is safer
        // than covering the live page with an image using a stale mapping.
        guard let image = await viewportLease.snapshotExcludingLiveHighlight(isOwnerCurrent: retainsCaptureOwnership) else {
            return failed(retainsCaptureOwnership() ? "snapshot-unavailable" : "ownership-during-snapshot")
        }
        guard retainsCaptureOwnership() else { return failed("ownership-after-snapshot") }
        continuousReadVisualHoldImageRect = fit.applying(to: canonical)
        continuousReadVisualHoldHighlightContentRect = paintedPage
        continuousReadVisualHoldImage = image
        refreshContinuousReadVisualHoldHighlight()
        KindleRunLog.write(
            "KINDLE read continuous visual-hold captured serial=\(serial) " +
            "source=web-snapshot rect=\(Self.rectLog(rect)) image=\(Self.sizeLog(image.size)) " +
            "highlightRects=\(continuousReadVisualHoldHighlightRectsNorm.count)"
        )
        return true
    }

    @discardableResult
    private func refreshContinuousReadVisualHoldHighlight(
        document: ReadingDocument? = nil,
        paragraphIndex: Int? = nil,
        wordRange: Range<Int>? = nil
    ) -> Bool {
        guard continuousReadVisualHoldImage != nil,
              continuousReadHandoff != nil,
              let owner = readVM else { return false }
        let document = document ?? owner.document
        let paragraphIndex = paragraphIndex ?? owner.currentParagraphIndex
        let wordRange = wordRange
            ?? owner.photoHighlightWordRange
            ?? owner.photoHighlightWordIndex.map { $0..<($0 + 1) }
        guard paragraphIndex >= 0,
              let paragraph = document.paragraphs.first(where: { $0.id == paragraphIndex }),
              let wordRange else {
            continuousReadVisualHoldHighlightRectsNorm = []
            return true
        }

        let lower = max(paragraph.words.startIndex, wordRange.lowerBound)
        let upper = min(paragraph.words.endIndex, wordRange.upperBound)
        guard lower < upper else {
            continuousReadVisualHoldHighlightRectsNorm = []
            return true
        }
        continuousReadVisualHoldHighlightRectsNorm = paragraph.words[lower..<upper].map(\.bboxNorm)
        return true
    }

    private func releaseContinuousReadVisualHoldIfReady(reason: String) {
        guard KindleContinuousPageHandoffContract.shouldReleaseVisualHold(
            audioBoundaryReached: continuousReadAudioBoundaryReached,
            hasConfirmedVisibleSurface: continuousReadStagedPage != nil
        ),
              continuousReadVisualHoldImage != nil else { return }
        continuousReadVisualHoldImage = nil
        continuousReadVisualHoldHighlightRectsNorm = []
        KindleRunLog.write("KINDLE read continuous visual-hold released reason=\(reason)")
    }

    /// Reaching the queue boundary and assigning `visualHoldImage = nil` happen
    /// in the same main-thread turn. If the prepared audio is released in that
    /// turn as well, AVPlayer can speak several words before SwiftUI has drawn
    /// the already-staged Kindle page. Hold the concrete queue item for a few
    /// display frames, paint the first mapped word on the staged surface, then
    /// retry the gate. Audio is never released onto a blank-highlight page.
    private func scheduleContinuousReadAudioGateRelease(serial: Int) {
        guard continuousReadHandoff?.serial == serial,
              continuousReadStagedPage != nil,
              !continuousReadAudioGateReleasePresented,
              continuousReadAudioGateReleaseTask == nil else { return }

        continuousReadAudioBoundaryReached = true
        releaseContinuousReadVisualHoldIfReady(reason: "queue-boundary-awaiting-frame")
        KindleRunLog.write("KINDLE read continuous audio-gate awaiting-frame serial=\(serial)")
        continuousReadAudioGateReleaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self,
                  !Task.isCancelled,
                  self.continuousReadHandoff?.serial == serial,
                  self.continuousReadStagedPage != nil else { return }
            let primed = await self.primeContinuousReadFirstHighlight(serial: serial)
            guard !Task.isCancelled,
                  self.continuousReadHandoff?.serial == serial,
                  self.continuousReadStagedPage != nil else { return }
            self.continuousReadAudioGateReleasePresented = true
            self.continuousReadAudioGateReleaseTask = nil
            KindleRunLog.write(
                "KINDLE read continuous audio-gate frame-highlight-ready " +
                "serial=\(serial) primed=\(primed ? "Y" : "N")"
            )
            AudioPlayerService.shared.resumeGatedSegmentIfPossible()
        }
    }

    /// The staged overlay exists before the queued audio item is released, so
    /// use that window to establish the first visible word. This avoids the
    /// circular handoff where AVPlayer had to start before the new VM could emit
    /// its first range. Failure is logged and remains fail-open: playback must
    /// not deadlock if WebKit is temporarily unavailable.
    private func primeContinuousReadFirstHighlight(serial: Int) async -> Bool {
        guard let handoff = continuousReadHandoff,
              handoff.serial == serial,
              let staged = continuousReadStagedPage,
              let paragraph = staged.document.paragraphs.first(where: { $0.id == handoff.paragraphIndex })
                ?? staged.document.paragraphs.first(where: { $0.type.isReadable }),
              !paragraph.words.isEmpty else {
            KindleRunLog.write("KINDLE read continuous highlight-prime unavailable serial=\(serial) reason=no-paragraph")
            return false
        }

        let mappings = OCRWordAligner.mapTimestampWordRanges(
            handoff.segments.flatMap(\.timestamps),
            in: paragraph,
            allowFallback: false,
            allowBoundedFallback: true
        )
        guard let wordRange = mappings.compactMap({ $0 }).first else {
            KindleRunLog.write("KINDLE read continuous highlight-prime unavailable serial=\(serial) reason=no-mapping")
            return false
        }

        let wordIndex = wordRange.lowerBound
        let sequence = nextVisualSyncSequence()
        var lastReason = "unknown"
        for attempt in 1...3 {
            do {
                let result = try await evaluateJSON(
                    "window.__crKindleLiveHighlightWords && " +
                    "window.__crKindleLiveHighlightWords(\(paragraph.id), \(wordIndex), \(wordRange.upperBound), \(sequence))"
                )
                let ok = result["ok"] as? Bool == true && result["stale"] as? Bool != true
                if ok {
                    let key = continuousReadStagedLiveKey?.nilIfEmpty ?? staged.page.key
                    lastHighlightedWordByParagraph["\(key)#\(paragraph.id)"] = wordIndex
                    KindleRunLog.write(
                        "KINDLE read continuous highlight-prime serial=\(serial) " +
                        "p=\(paragraph.id) w=\(wordIndex) attempt=\(attempt) ok=Y"
                    )
                    return true
                }
                lastReason = result["reason"] as? String ?? "not-painted"
            } catch {
                lastReason = error.localizedDescription
            }
            guard attempt < 3, !Task.isCancelled else { break }
            try? await Task.sleep(nanoseconds: 70_000_000)
        }
        KindleRunLog.write(
            "KINDLE read continuous highlight-prime serial=\(serial) " +
            "p=\(paragraph.id) w=\(wordIndex) ok=N reason=\(lastReason)"
        )
        return false
    }

    private func continuousReadSegments(_ segments: [AudioSegment], serial: Int) -> [AudioSegment] {
        segments.enumerated().map { offset, segment in
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
    }

    /// Kindle's retained Blob order is speculative. Once the paired React page
    /// action confirms the real key, promote that exact OCR page and synthesize
    /// its first utterance while the old tail is still playing (or held at the
    /// queue gate). This turns a wrong guess into a late cache hit instead of a
    /// stop-and-restart fallback.
    private func prepareContinuousReadRetarget(
        handoff: KindleContinuousReadHandoff,
        staged: KindleCachedPage
    ) async throws -> KindleContinuousReadHandoff {
        guard continuousReadHandoff?.serial == handoff.serial else {
            throw CancellationError()
        }
        let rebound = KindleCachedPage(
            afterKey: handoff.oldKey,
            page: staged.page,
            document: staged.document,
            startParagraphIndex: staged.startParagraphIndex
        )
        cachePreparedCandidate(rebound)
        _ = try await ensureReadStartSegmentsPrepared(
            rebound,
            epoch: preloadEpoch,
            reason: "confirmed-page-retarget"
        )
        guard continuousReadHandoff?.serial == handoff.serial else {
            throw CancellationError()
        }

        let fingerprint = readSpeechFingerprint(rebound.document)
        let voiceID = AppSettings.shared.voice(for: rebound.document.language)
        guard let prefetched = startAudioCandidate(
            pageKey: rebound.page.key,
            textFingerprint: fingerprint,
            voiceID: voiceID
        ), !prefetched.segments.isEmpty else {
            throw KindleBookError.captureFailed("continuous-retarget-audio-unavailable")
        }
        let rebased = continuousReadSegments(prefetched.segments, serial: handoff.serial)
        return KindleContinuousReadHandoff(
            serial: handoff.serial,
            oldKey: handoff.oldKey,
            target: rebound,
            previousSnapshot: handoff.previousSnapshot,
            paragraphIndex: prefetched.paragraphIndex,
            segments: rebased,
            segmentIDs: Set(rebased.map(\.id)),
            predecessorSegmentID: handoff.predecessorSegmentID
        )
    }

    private func beginContinuousReadCommitIfNeeded(serial: Int) {
        guard continuousReadCommitTask == nil,
              let handoff = continuousReadHandoff,
              handoff.serial == serial else { return }

        // The speculative cache is never an entitlement. Re-check at the exact
        // queue boundary because a free user can consume the final allowance
        // while the next page/audio is being prepared.
        guard let currentOwner = readVM else {
            cancelContinuousReadHandoff(reason: "missing-read-owner", force: true)
            return
        }
        guard currentOwner.canContinueAcrossLivePageBoundary else {
            statusText = AppLocalized("免费朗读额度已用完。")
            presentPlaybackQuotaPaywall(for: .read)
            _ = currentOwner.finishLogicalAnalyticsSession(
                result: .blocked,
                reason: "listen_quota"
            )
            cancelContinuousReadHandoff(reason: "listen-quota", force: true)
            _ = AudioPlayerService.shared.clearActiveQueueForCoordinator(owner: .readAloud)
            return
        }

        continuousReadAudioBoundaryReached = true
        releaseContinuousReadVisualHoldIfReady(reason: "audio-boundary")
        if !continuousReadOldVMDetached {
            continuousReadAnalyticsOwner = readVM
            continuousReadAppReviewSession = readVM?.detachForContinuousPageHandoff(
                nextSegmentID: handoff.segments.first?.id
            )
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
                _ = AudioPlayerService.shared.clearActiveQueueForCoordinator(owner: .readAloud)
                KindleRunLog.write("KINDLE read continuous commit failed serial=\(serial) error=\(error.localizedDescription)")
                return
            }
        }

        guard let handoff = continuousReadHandoff,
              handoff.serial == serial,
              let staged = continuousReadStagedPage else { return }
        let actualKey = continuousReadStagedLiveKey?.nilIfEmpty ?? staged.page.key
        let completedBeforeCommit = continuousReadAudioCompletedBeforeCommit
        let inheritedAppReviewSession = continuousReadAppReviewSession
        let retainedAnalyticsOwner = continuousReadAnalyticsOwner
        let prefetchedFingerprint = readSpeechFingerprint(handoff.target.document)
        let stagedFingerprint = readSpeechFingerprint(staged.document)
        let canAdoptPrefetchedAudio = prefetchedFingerprint == stagedFingerprint

        continuousReadHandoff = nil
        continuousReadAudioAppended = false
        continuousReadTurnTask = nil
        continuousReadCommitTask = nil
        continuousReadStagedPage = nil
        continuousReadStagedLiveKey = nil
        continuousReadOldVMDetached = false
        continuousReadAppReviewSession = nil
        continuousReadAnalyticsOwner = nil
        continuousReadAudioCompletedBeforeCommit = false
        continuousReadAudioBoundaryReached = false
        continuousReadAudioGateReleasePresented = false
        continuousReadAudioGateReleaseTask?.cancel()
        continuousReadAudioGateReleaseTask = nil
        continuousReadVisualHoldImage = nil
        continuousReadVisualHoldHighlightRectsNorm = []
        continuousReadVisualPreparation = KindleReadVisualPreparation()
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
            if let inheritedAppReviewSession,
               !vm.inheritAppReviewReadSession(inheritedAppReviewSession) {
                throw KindleBookError.captureFailed("continuous-review-session-adoption-failed")
            }
            _ = vm.claimLogicalAnalyticsSessionForPageHandoff()
            let ownerCanAdopt = KindleContinuousPageHandoffContract.canAdoptPreparedAudio(
                previousOwnerDocumentID: previousOwnerDocumentID,
                activeOwnerDocumentID: vm.document.id,
                targetDocumentID: queuedDocument.id
            )
            guard canAdoptPrefetchedAudio, ownerCanAdopt else {
                _ = AudioPlayerService.shared.clearActiveQueueForCoordinator(owner: .readAloud)
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
                _ = AudioPlayerService.shared.clearActiveQueueForCoordinator(owner: .readAloud)
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
            KindleRunLog.write(
                "KINDLE read continuous highlight-synced serial=\(serial) " +
                "timeMs=\(Int(AudioPlayerService.shared.currentTime * 1_000)) " +
                "p=\(vm.currentParagraphIndex) w=\(vm.photoHighlightWordIndex ?? -1)"
            )
            _ = consumeStartAudioCandidate(
                pageKey: staged.page.key,
                textFingerprint: readSpeechFingerprint(staged.document),
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
            _ = AudioPlayerService.shared.clearActiveQueueForCoordinator(owner: .readAloud)
            let endedByRetiredOwner = retainedAnalyticsOwner?
                .finishLogicalAnalyticsSession(
                    result: .failed,
                    reason: "kindle_continuous_handoff_failed",
                    errorStage: "page_handoff",
                    errorCode: "audio_adoption_failed"
                ) ?? false
            if !endedByRetiredOwner {
                _ = readVM?.finishLogicalAnalyticsSession(
                    result: .failed,
                    reason: "kindle_continuous_handoff_failed",
                    errorStage: "page_handoff",
                    errorCode: "audio_adoption_failed"
                )
            }
            KindleRunLog.write("KINDLE read continuous adoption failed serial=\(serial) error=\(error.localizedDescription)")
        }
    }

    /// Closing/resetting the reader is terminal even when the old page VM was
    /// already detached. End its logical session first, then force-cancel every
    /// async handoff task so an awaited page-turn cannot publish a new VM later.
    private func terminateContinuousReadHandoffForClosure(reason: String) {
        let ownsCurrentContinuousSegment = continuousReadHandoff.map { handoff in
            AudioPlayerService.shared.currentSegment.map {
                handoff.segmentIDs.contains($0.id)
            } ?? false
        } ?? false
        _ = continuousReadAnalyticsOwner?.finishLogicalAnalyticsSession(
            result: .cancelled,
            reason: "closed"
        )
        _ = readVM?.finishLogicalAnalyticsSession(
            result: .cancelled,
            reason: "closed"
        )
        cancelContinuousReadHandoff(reason: reason, force: true)
        if ownsCurrentContinuousSegment {
            _ = AudioPlayerService.shared.clearActiveQueueForCoordinator(owner: .readAloud)
        }
    }

    private func cancelContinuousReadHandoff(reason: String, force: Bool = false) {
        let handoff = continuousReadHandoff
        let audio = AudioPlayerService.shared
        if !force,
           let handoff,
           let currentID = audio.currentSegment?.id,
           handoff.segmentIDs.contains(currentID),
           continuousReadCommitTask != nil {
            KindleRunLog.write("KINDLE read continuous cancel deferred-active reason=\(reason) serial=\(handoff.serial)")
            return
        }
        let detachedOwner = continuousReadOldVMDetached
            ? continuousReadAnalyticsOwner
            : nil
        continuousReadTurnTask?.cancel()
        continuousReadCommitTask?.cancel()
        if let handoff {
            _ = audio.removePendingSegments(withIDs: handoff.segmentIDs)
            audio.canStartQueuedSegment = nil
        }
        continuousReadHandoff = nil
        continuousReadAudioAppended = false
        continuousReadTurnTask = nil
        continuousReadCommitTask = nil
        continuousReadStagedPage = nil
        continuousReadStagedLiveKey = nil
        continuousReadOldVMDetached = false
        continuousReadAppReviewSession = nil
        continuousReadAnalyticsOwner = nil
        continuousReadAudioCompletedBeforeCommit = false
        continuousReadAudioBoundaryReached = false
        continuousReadAudioGateReleasePresented = false
        continuousReadAudioGateReleaseTask?.cancel()
        continuousReadAudioGateReleaseTask = nil
        continuousReadVisualHoldImage = nil
        continuousReadVisualHoldHighlightRectsNorm = []
        continuousReadVisualPreparation = KindleReadVisualPreparation()
        continuousReadTurnFailureCount = 0
        continuousReadSemanticTurnAttempted = false
        continuousReadConfirmedTargetKey = nil
        if handoff != nil, let detachedOwner {
            let endedByRetiredOwner = detachedOwner.finishLogicalAnalyticsSession(
                result: .failed,
                reason: "kindle_continuous_handoff_cancelled",
                errorStage: "page_handoff",
                errorCode: "handoff_cancelled"
            )
            if !endedByRetiredOwner {
                _ = readVM?.finishLogicalAnalyticsSession(
                    result: .failed,
                    reason: "kindle_continuous_handoff_cancelled",
                    errorStage: "page_handoff",
                    errorCode: "handoff_cancelled"
                )
            }
        }
        KindleRunLog.write(
            "KINDLE read continuous cancelled reason=\(reason) " +
            "serial=\(handoff?.serial.description ?? "none") force=\(force ? "Y" : "N")"
        )
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
            cancelAutomaticAppReviewContinuation(for: session)
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
            cancelAutomaticAppReviewContinuation(for: session)
            KindleRunLog.write(
                "KINDLE read page finished stale-after-probe source=\(source) " +
                "eventGeneration=\(session.generation) key=\(Self.keyLog(liveKey))"
            )
            return
        }
        if let observed = observedKey.nilIfEmpty,
           observed != liveKey {
            cancelAutomaticAppReviewContinuation(for: session)
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
        guard readerOperationAllowed(.automaticPageTurn, reason: "read-auto-advance") else {
            cancelAutomaticAppReviewContinuation(for: session)
            return
        }
        guard mode == .read,
              !isAdvancingLivePage,
              activeReadPageSession == session,
              consumedReadPageGeneration == session.generation,
              normalizedPageKey(livePageKey?.nilIfEmpty ?? livePage?.key) == expectedPageKey else {
            cancelAutomaticAppReviewContinuation(for: session)
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
            cancelAutomaticAppReviewContinuation(for: session)
            KindleRunLog.write(
                "KINDLE read auto advance stale-after-visible-probe generation=\(session.generation) " +
                "key=\(Self.keyLog(expectedPageKey))"
            )
            return
        }
        if let visibleKey = visibleOldKey.nilIfEmpty, visibleKey != expectedPageKey {
            cancelAutomaticAppReviewContinuation(for: session)
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
        let appReviewReadSession = takeAutomaticAppReviewContinuation(for: session)
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
            reason: "read-auto-next-page",
            appReviewReadSession: appReviewReadSession
        )
    }

    private func maybePrepareExplainPageDuringAudioTail() {
        guard mode == .explain, explainPagePreparation == nil,
              !isAdvancingLivePage, !isPageTurnResuming,
              !isPlayerControlOverlayPresented, !isReadingSettingsPresented,
              !isApplyingReadingSettings, !isKindleSyncDialogVisible,
              isReaderPresented, isReaderSurfaceAttached,
              ProManager.shared.isPro,
              AudioPlayerService.shared.isPlaying,
              let owner = explainVM, let tail = owner.preparedLivePageAudioTail,
              let oldKey = livePageKey?.nilIfEmpty,
              let page = livePage, normalizedPageKey(page.key) == normalizedPageKey(oldKey),
              viewportPresentationPageCount == 1,
              normalizedPageKey(viewportPresentationPageKey) == normalizedPageKey(oldKey),
              let pageRect = viewportPresentationPageRect,
              let lease = KindleVisualHoldViewportLease(webView: webView, surfaceSize: readerSurfaceSize),
              lease.isCurrent,
              let image = UIImage(data: page.imageData) else { return }
        let rate = Double(AudioPlayerService.shared.playbackRate)
        guard rate.isFinite, rate > 0 else { return }
        let remaining = tail.remainingAudioSeconds / rate
        guard remaining > 0, remaining <= owner.kindlePagePreparationLeadSeconds else { return }
        guard readerOperationAllowed(.automaticPageTurn, reason: "explain-tail-preparation") else { return }

        let preparation = KindleExplainPagePreparation(owner: owner, oldKey: oldKey, epoch: preloadEpoch)
        explainPagePreparation = preparation
        #if DEBUG
        debugPreparedHeldPageKey = nil
        #endif
        explainVisualHold = KindleExplainVisualHoldState(
            image: image, imageRect: lease.fit.applying(to: pageRect),
            document: owner.document, initiallyDrawnMarks: Set(owner.activeMarks.map(\.id))
        )
        // The same OCR anchors keep drawing timed marks on the old page while
        // WebKit prepares the actual next page underneath it. No speculative
        // narration is allowed to determine which page will be spoken.
        KindleRunLog.write("KINDLE explain tail-preparation begin old=\(Self.keyLog(oldKey)) remainingMs=\(Int(remaining * 1000))")
        preparation.task = Task { @MainActor [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            @MainActor func requireOwner() throws {
                guard !Task.isCancelled, self.explainPagePreparation === preparation,
                      self.explainVM === owner, self.mode == .explain,
                      self.preloadEpoch == preparation.epoch,
                      self.isReaderSurfaceAttached else { throw CancellationError() }
            }
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
                try requireOwner()
                try await self.ensureCaptureScriptInstalled(reason: "explain-tail-preparation")
                try requireOwner()
                preparation.semanticActionAttempted = true
                let target = try await self.requestNativeNextPageForAutoAdvance(
                    oldKey: oldKey, reason: "explain-tail-preparation",
                    onDispatchEvidence: { preparation.dispatchEvidence = $0 }
                )
                try requireOwner()
                preparation.confirmedTargetKey = target
                #if DEBUG
                self.debugPreparedHeldPageKey = target
                #endif
                let prepared = try await self.preparedPageForNativeAutoAdvance(
                    afterKey: oldKey, targetKey: target, mode: .explain
                )
                try requireOwner()
                preparation.prepared = prepared
                self.cachePreparedCandidate(prepared)
                self.startExplainFirstBlockPrefetch(
                    afterKey: oldKey, pageKey: prepared.page.key,
                    document: prepared.document, epoch: preparation.epoch
                )
                if self.explainPrefetchingPageKey == prepared.page.key {
                    await self.explainPrefetchTask?.value
                }
                try requireOwner()
                KindleRunLog.write("KINDLE explain tail-preparation ready old=\(Self.keyLog(oldKey)) next=\(Self.keyLog(target)) elapsedMs=\(Int((ProcessInfo.processInfo.systemUptime - started) * 1000))")
            } catch {
                guard self.explainPagePreparation === preparation else { return }
                KindleRunLog.write("KINDLE explain tail-preparation deferred old=\(Self.keyLog(oldKey)) dispatched=\(preparation.semanticActionAttempted) error=\(error.localizedDescription)")
                // Once dispatched, completion must observe/recover that action;
                // dropping it here could turn a second time and skip a page.
                if !preparation.semanticActionAttempted {
                    self.cancelExplainPagePreparation(reason: "pre-dispatch-cancelled")
                }
            }
        }
    }

    private func cancelExplainPagePreparation(reason: String) {
        guard let preparation = explainPagePreparation else { return }
        explainPagePreparation = nil
        preparation.task?.cancel()
        explainVisualHold = nil
        KindleRunLog.write("KINDLE explain tail-preparation cancelled reason=\(reason) dispatched=\(preparation.semanticActionAttempted)")
    }

    private func advanceToNextExplainPageIfNeeded() async {
        guard readerOperationAllowed(.automaticPageTurn, reason: "explain-auto-advance") else {
            isContinuingExplainPage = false
            return
        }
        guard mode == .explain, !isAdvancingLivePage else {
            isContinuingExplainPage = false
            return
        }
        isAdvancingLivePage = true
        let earlyPreparation = explainPagePreparation
        if let earlyPreparation, explainVM === earlyPreparation.owner {
            await earlyPreparation.task?.value
            if explainPrefetchingPageKey == earlyPreparation.confirmedTargetKey {
                await explainPrefetchTask?.value
            }
            guard explainPagePreparation === earlyPreparation,
                  explainVM === earlyPreparation.owner, mode == .explain else {
                isAdvancingLivePage = false
                isContinuingExplainPage = false
                return
            }
            explainPagePreparation = nil
        }
        let visibleOldKey = await currentVisibleKindlePageKey()
        let oldKey: String
        if let earlyPreparation {
            oldKey = earlyPreparation.oldKey
        } else if let visibleKey = visibleOldKey.nilIfEmpty {
            oldKey = visibleKey
        } else {
            oldKey = await currentKindlePageKey()
        }
        defer {
            isAdvancingLivePage = false
            isContinuingExplainPage = false
            explainVisualHold = nil
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
            reason: "explain-auto-next-page",
            preparedExplainTurn: earlyPreparation
        )
    }

    private func advanceByNativePageTurnAndContinue(
        oldKey rawOldKey: String,
        continuationMode: ReaderMode,
        status: String,
        reason: String,
        appReviewReadSession: AppReviewReadSessionProgress? = nil,
        recoveryAttempt: Int = 0,
        preparedExplainTurn: KindleExplainPagePreparation? = nil
    ) async {
        guard readerOperationAllowed(.automaticPageTurn, reason: reason) else { return }
        // Retain the page owner until the next page has actually claimed the
        // shared logical analytics coordinator. If navigation fails before
        // that claim, this owner is still responsible for the one terminal
        // read_end event.
        let completedReadOwner = continuationMode == .read ? readVM : nil
        let completedExplainOwner = continuationMode == .explain ? explainVM : nil
        let completedReadSession = continuationMode == .read ? activeReadPageSession : nil
        let liveProgressAtBoundary = livePage?.progress
        let storedProgressAtBoundary = book.progressLabel
        func finishReadSession(
            result: AnalyticsResult,
            endReason: String,
            errorStage: String? = nil,
            errorCode: String? = nil
        ) {
            guard continuationMode == .read else { return }
            let endedByCompletedOwner = completedReadOwner?
                .finishLogicalAnalyticsSession(
                    result: result,
                    reason: endReason,
                    errorStage: errorStage,
                    errorCode: errorCode
                ) ?? false
            if !endedByCompletedOwner {
                _ = readVM?.finishLogicalAnalyticsSession(
                    result: result,
                    reason: endReason,
                    errorStage: errorStage,
                    errorCode: errorCode
                )
            }
        }
        func finishInterruptedReadSession(errorCode: String) {
            finishReadSession(
                result: .failed,
                endReason: "kindle_page_advance_failed",
                errorStage: "navigation",
                errorCode: errorCode
            )
        }
        func continuationIsOwned() -> Bool {
            // A mode switch/cancellation belongs to the new owner. The sync
            // dialog has its own resume task; neither is a navigation failure.
            guard !Task.isCancelled, mode == continuationMode else {
                KindleRunLog.write("KINDLE auto advance abandoned context-change reason=\(reason)")
                return false
            }
            guard !isKindleSyncDialogVisible else {
                KindleRunLog.write("KINDLE auto advance deferred to sync-dialog recovery reason=\(reason)")
                return false
            }
            return true
        }
        guard continuationIsOwned() else { return }
        let oldKey = rawOldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousSnapshot = currentPreparedPageSnapshot()
        var attemptedForwardTurn = false
        var confirmedForwardTurn = false
        var activatedNextPage = false
        var dispatchEvidence = KindlePageTurnDispatchEvidence.unknown
        statusText = status
        pendingCaptureKey = nil
        invalidatePagePreloads(clearPrepared: false, reason: "\(reason)-generation")
        let recoveryEpoch = preloadEpoch
        func recoveryStillOwned() -> Bool {
            guard !Task.isCancelled,
                  preloadEpoch == recoveryEpoch,
                  mode == continuationMode,
                  isAdvancingLivePage,
                  !isKindleSyncDialogVisible,
                  isReaderSurfaceAttached,
                  webView.window != nil,
                  !hasActivePlaybackSession else {
                return false
            }
            switch continuationMode {
            case .read:
                return readVM === completedReadOwner && activeReadPageSession == completedReadSession
            case .explain:
                return explainVM === completedExplainOwner
            }
        }

        do {
            try await ensureCaptureScriptInstalled(reason: reason)
            await setKindlePageModeLocked(true)
            _ = try? await evaluateJSON("window.__crKindleLiveClear && window.__crKindleLiveClear()")

            let targetKey: String
            if let preparedExplainTurn, preparedExplainTurn.semanticActionAttempted {
                // A staged semantic action is never repeated, including when
                // confirmation was lost. Recovery observes the visible page.
                attemptedForwardTurn = true
                dispatchEvidence = preparedExplainTurn.dispatchEvidence
                let visible = await currentVisibleKindlePageKey()
                guard !visible.isEmpty, visible != oldKey,
                      preparedExplainTurn.confirmedTargetKey == nil ||
                        preparedExplainTurn.confirmedTargetKey == visible else {
                    throw KindleBookError.captureFailed("explain-prepared-turn-not-visible")
                }
                targetKey = visible
            } else {
                attemptedForwardTurn = true
                targetKey = try await requestNativeNextPageForAutoAdvance(
                    oldKey: oldKey,
                    reason: reason,
                    onDispatchEvidence: { dispatchEvidence = $0 }
                )
            }
            confirmedForwardTurn = true
            guard continuationIsOwned() else { return }
            pendingCaptureKey = targetKey

            let prepared = try await preparedPageForNativeAutoAdvance(
                afterKey: oldKey,
                targetKey: targetKey,
                mode: continuationMode
            )
            guard recoveryStillOwned() else {
                KindleRunLog.write(
                    "KINDLE \(continuationMode.rawValue) auto advance abandoned-before-activate " +
                    "old=\(Self.keyLog(oldKey)) reason=\(reason)"
                )
                return
            }
            let singlePageDoc = try await activatePreparedNextPage(
                prepared,
                oldKey: oldKey,
                startOverride: prepared.startParagraphIndex,
                startKindOverride: .sourceParagraph
            )
            activatedNextPage = true
            guard continuationIsOwned() else { return }
            if explainVisualHold != nil {
                explainVisualHold = nil
                try await Task.sleep(nanoseconds: 80_000_000)
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
                reason: reason,
                appReviewReadSession: appReviewReadSession,
                continueLogicalReadSession: continuationMode == .read
            )
            KindleRunLog.write("KINDLE \(continuationMode.rawValue) auto advance success old=\(Self.keyLog(oldKey)) new=\(Self.keyLog(prepared.page.key)) reason=\(reason)")
        } catch {
            pendingCaptureKey = nil
            if error is CancellationError || (!activatedNextPage && !recoveryStillOwned()) {
                KindleRunLog.write(
                    "KINDLE \(continuationMode.rawValue) auto advance abandoned-context-change " +
                    "old=\(Self.keyLog(oldKey)) reason=\(reason)"
                )
                return
            }
            let reachedNaturalEnd = continuationMode == .read &&
                attemptedForwardTurn &&
                !confirmedForwardTurn &&
                !(error is CancellationError) &&
                KindleTurnContract.isTerminalPage(
                    liveProgress: liveProgressAtBoundary,
                    storedProgress: storedProgressAtBoundary
                )
            if reachedNaturalEnd {
                statusText = AppLocalized("已读完这本书。")
                finishReadSession(result: .success, endReason: "completed")
                KindleRunLog.write(
                    "KINDLE read auto advance reached terminal page old=\(Self.keyLog(oldKey)) " +
                    "progress=\(liveProgressAtBoundary ?? storedProgressAtBoundary) reason=\(reason)"
                )
                return
            }

            if !(error is CancellationError), attemptedForwardTurn, !activatedNextPage {
                let visibleKey = await observedAutoAdvanceRecoveryKey(oldKey: oldKey)
                guard recoveryStillOwned() else {
                    KindleRunLog.write(
                        "KINDLE \(continuationMode.rawValue) auto advance recovery-abandoned-after-observe " +
                        "old=\(Self.keyLog(oldKey)) reason=\(reason)"
                    )
                    return
                }
                switch KindleAutoAdvanceRecoveryContract.action(
                    oldKey: oldKey,
                    visibleKey: visibleKey,
                    retryAttempt: recoveryAttempt,
                    dispatchEvidence: dispatchEvidence
                ) {
                case .resumeVisiblePage(let targetKey):
                    do {
                        pendingCaptureKey = targetKey
                        let prepared = try await preparedPageForNativeAutoAdvance(
                            afterKey: oldKey,
                            targetKey: targetKey,
                            mode: continuationMode
                        )
                        guard recoveryStillOwned() else {
                            KindleRunLog.write(
                                "KINDLE \(continuationMode.rawValue) auto advance recovery-abandoned-before-activate " +
                                "old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(targetKey)) reason=\(reason)"
                            )
                            return
                        }
                        let singlePageDoc = try await activatePreparedNextPage(
                            prepared,
                            oldKey: oldKey,
                            startOverride: prepared.startParagraphIndex,
                            startKindOverride: .sourceParagraph
                        )
                        guard mode == continuationMode, !isKindleSyncDialogVisible else {
                            throw KindleBookError.captureFailed("auto-recovery-context-changed")
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
                            reason: "\(reason)-visible-recovery",
                            appReviewReadSession: appReviewReadSession,
                            continueLogicalReadSession: continuationMode == .read
                        )
                        KindleRunLog.write(
                            "KINDLE \(continuationMode.rawValue) auto advance recovered-visible " +
                            "old=\(Self.keyLog(oldKey)) new=\(Self.keyLog(prepared.page.key)) reason=\(reason)"
                        )
                        return
                    } catch {
                        pendingCaptureKey = nil
                        if error is CancellationError || !recoveryStillOwned() {
                            KindleRunLog.write(
                                "KINDLE \(continuationMode.rawValue) auto advance recovery-abandoned-context-change " +
                                "old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(targetKey)) reason=\(reason)"
                            )
                            return
                        }
                        KindleRunLog.write(
                            "KINDLE \(continuationMode.rawValue) auto advance visible-recovery failed " +
                            "old=\(Self.keyLog(oldKey)) target=\(Self.keyLog(targetKey)) reason=\(reason)"
                        )
                    }
                case .retryPageTurn:
                    KindleRunLog.write(
                        "KINDLE \(continuationMode.rawValue) auto advance retry-stable-old " +
                        "attempt=\(recoveryAttempt + 1) old=\(Self.keyLog(oldKey)) reason=\(reason)"
                    )
                    await advanceByNativePageTurnAndContinue(
                        oldKey: oldKey,
                        continuationMode: continuationMode,
                        status: status,
                        reason: reason,
                        appReviewReadSession: appReviewReadSession,
                        recoveryAttempt: recoveryAttempt + 1
                    )
                    return
                case .stop:
                    break
                }
            }

            statusText = AppLocalized("已停在当前页，请点击播放继续。")
            finishInterruptedReadSession(errorCode: "page_turn_failed")
            KindleRunLog.write("KINDLE \(continuationMode.rawValue) auto advance failed old=\(Self.keyLog(oldKey)) reason=\(reason) error=\(error.localizedDescription)")
            #if DEBUG
            NSLog("CRDBG KINDLE auto advance failed mode=%@ old=%@ error=%@",
                  continuationMode.rawValue,
                  Self.keyLog(oldKey),
                  error.localizedDescription)
            #endif
        }
    }

    /// Confirmation can time out while Kindle is still publishing the page it
    /// already turned to. Observe that page before any retry; never issue a
    /// second semantic action merely because the first confirmation timed out.
    private func observedAutoAdvanceRecoveryKey(oldKey: String) async -> String {
        var latestKey = ""
        for sample in 0..<8 {
            guard !Task.isCancelled else { return "" }
            latestKey = normalizedPageKey(await currentVisibleKindlePageKey())
            if !latestKey.isEmpty, latestKey != oldKey { return latestKey }
            if sample < 7 {
                do {
                    try await Task.sleep(nanoseconds: 250_000_000)
                } catch {
                    return ""
                }
            }
        }
        return latestKey
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

    private func requestNativeNextPageForAutoAdvance(
        oldKey: String,
        reason: String,
        onDispatchEvidence: ((KindlePageTurnDispatchEvidence) -> Void)? = nil
    ) async throws -> String {
        try requireReaderOperation(.automaticPageTurn, reason: reason)
        let target = try await requestKindlePageTurnTarget(
            .next,
            oldKey: oldKey,
            onDispatchEvidence: onDispatchEvidence
        )
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
        guard readerOperationAllowed(.ttsPreparation, reason: reason) else { return }
        guard mode == .explain, let vm = explainVM else { return }
        readVM?.deactivate()
        vm.activate()
        recordPlaybackStart(language: document.language)
        clearKindleMarkState(resetAnimationHistory: true)
        Task { _ = try? await evaluateJSON("window.__crKindleLiveClearMarks && window.__crKindleLiveClearMarks()") }
        if let key = livePageKey {
            ensureExplainNextPagePrefetch(afterKey: key, reason: reason)
            // Each committed page owns new geometry, even when its dimensions
            // match the previous page. Otherwise only the first page's cached
            // key passes the visual-hold gate and later turns become cold.
            Task { @MainActor [weak self, weak vm] in
                guard let self, let vm, self.explainVM === vm,
                      self.mode == .explain, self.livePageKey == key else { return }
                await self.logKindleGeometrySnapshot(reason: "explain-page-start")
            }
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
        guard readerOperationAllowed(.ttsPreparation, reason: reason) else { return }
        let afterKey = normalizedPageKey(rawKey)
        guard !afterKey.isEmpty, mode == .explain else { return }

        if let prepared = explainPagePreparation?.prepared ?? preparedCandidate(afterKey: afterKey),
           !prepared.page.key.isEmpty,
           prepared.page.key != afterKey {
            let pageKey = normalizedPageKey(prepared.page.key)
            let fingerprint = Self.explainFingerprint(prepared.document)
            if let cached = cachedExplainPrefetchCandidates[pageKey] ?? cachedExplainPrefetch,
               cached.afterKey == afterKey,
               cached.pageKey == pageKey,
               cached.textFingerprint == fingerprint,
               cached.payload.matchesCurrentSettings {
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
                let fingerprint = readSpeechFingerprint(singlePageDoc)
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
        activeVisualSyncSequence = nil
        pendingVisualHighlight = nil
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
        cancelExplainPagePreparation(reason: reason)
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
            explainPrefetchRequestID = nil
            explainPrefetchingAfterKey = nil
            explainPrefetchingPageKey = nil
            deferredExplainPreloadTask?.cancel()
            deferredExplainPreloadTask = nil
            deferredExplainPreloadAfterKey = nil
            cachedExplainPrefetch = nil
            cachedExplainPrefetchCandidates.removeAll()
            let fromVoice = notification.userInfo?["fromVoiceID"] as? String ?? "-"
            let toVoice = notification.userInfo?["toVoiceID"] as? String ?? "-"
            KindleRunLog.write("KINDLE explain voice switch invalidate audio-prefetch from=\(fromVoice) to=\(toVoice) lang=\(requestedLanguage)")
            if let liveKey = livePageKey?.nilIfEmpty {
                ensureExplainNextPagePrefetch(afterKey: liveKey, reason: "voice-switch")
            }
            return
        }

        guard mode == .read,
              let activeReadVM = readVM,
              let sourceVM = notification.object as? ReadAloudViewModel,
              sourceVM === activeReadVM else { return }
        // The language being spoken, not the language the page was recognized as.
        // A correction changes the first without changing the second, and comparing
        // against the document would drop the notification exactly then.
        guard requestedLanguage == activeReadVM.playbackLanguage else { return }

        // Audio prefetched with voice A must never be adopted after the live VM
        // has switched to voice B. An ordinary voice change invalidates only the
        // audio continuations — the page captures are still valid — and then warms
        // the prepared next page again.
        cancelContinuousReadHandoff(reason: "voice-switch", force: true)
        clearPendingContinuation()
        cachedStartAudio = nil
        cachedStartAudioCandidates.removeAll()
        let fromVoice = notification.userInfo?["fromVoiceID"] as? String ?? "-"
        let toVoice = notification.userInfo?["toVoiceID"] as? String ?? "-"
        KindleRunLog.write("KINDLE voice switch invalidate audio-prefetch from=\(fromVoice) to=\(toVoice) lang=\(requestedLanguage)")

        // A language correction is different: it also changes the locale the next
        // page must be recognized under. Anything already captured was read under
        // the old one, so keeping it would delay the correction by a page — drop
        // the captures as well and let the warm-up below redo them.
        let recognizedLanguage = VoiceCatalog.normalizedLanguage(
            activeReadVM.document.language.isEmpty
                ? (liveDocument?.language ?? "")
                : activeReadVM.document.language
        )
        if !recognizedLanguage.isEmpty, requestedLanguage != recognizedLanguage {
            cancelPageCaching(clearPrepared: true)
            KindleRunLog.write(
                "KINDLE language corrected recognized=\(recognizedLanguage) " +
                "narration=\(requestedLanguage) prepared-captures=dropped"
            )
        }
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
        explainPrefetchRequestID = nil
        explainPrefetchingPageKey = nil
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
        guard readerOperationAllowed(.ttsPreparation, reason: "current-page-continuation") else { return }
        guard pendingContinuationParagraphIndex != paragraphIndex || pendingContinuationSegments.isEmpty else { return }
        pendingContinuationTask?.cancel()
        pendingContinuationParagraphIndex = paragraphIndex
        pendingContinuationSegments = []
        let chunks = KindleFootnoteSpeech.prepare(document: document, skipReferences: skipsFootnoteReferences).paragraphs.map(\.spokenParagraph)
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
        guard readerOperationAllowed(.capture, reason: "cache-next-page") else { return }
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
        guard readerOperationAllowed(.ttsPreparation, reason: reason) else { return }
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
        guard readerOperationAllowed(.capture, reason: "cache-next-page-task") else { return }
        defer {
            if cachingNextPageAfterKey == afterKey && preloadEpoch == epoch {
                cachingNextPageAfterKey = nil
                pageCacheTask = nil
            }
        }
        do {
            guard preloadEpoch == epoch else { return }
            // Renderer allocation order is speculative in both modes. Share
            // the bounded OCR cache so Explain can reconcile the real next
            // page without doing OCR at the audio boundary. Generation below
            // still warms only the first Explain candidate, not all 12 pages.
            let captureLimit = 12
            KindleRunLog.write("KINDLE \(mode.rawValue) preload capture-limit after=\(Self.keyLog(afterKey)) limit=\(captureLimit) epoch=\(epoch)")
            var preparedCount = 0
            var firstPrepared: KindleCachedPage?
            _ = try await captureCandidatePages(afterKey: afterKey, limit: captureLimit) { [self] page in
                try Task.checkCancellation()
                guard preloadEpoch == epoch else { return }
                guard !page.key.isEmpty, page.key != afterKey else {
                    KindleRunLog.write("KINDLE blob transition source=preload-capture status=repeat old=\(Self.keyLog(afterKey)) expected= actual=\(Self.keyLog(page.key))")
                    return
                }
                guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let doc = makeLiveDocument(from: page)
                guard hasReadableParagraphs(doc) else { return }
                let prepared = KindleCachedPage(
                    afterKey: afterKey,
                    page: page,
                    document: doc,
                    startParagraphIndex: firstReadableParagraph(in: doc)
                )
                cachePreparedCandidate(prepared)
                if firstPrepared == nil { firstPrepared = prepared }
                cachedNextPage = firstPrepared
                if preparedCount == 0 {
                    markExpectedNextBlob(afterKey: afterKey, nextKey: page.key, source: "preload-ready")
                }
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
                    return
                }
                guard mode == .read else {
                    KindleRunLog.write("KINDLE page preload skip-read-tts mode=\(mode.rawValue) after=\(Self.keyLog(prepared.afterKey)) key=\(Self.keyLog(page.key))")
                    return
                }
                guard preparedCount <= 2 else {
                    return
                }
                do {
                    _ = try await ensureReadStartSegmentsPrepared(prepared, epoch: epoch, reason: "page-preload")
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
            }
            guard preparedCount > 0 else {
                throw KindleBookError.noText
            }
            // cachePreparedCandidate updates the legacy single-value shortcut
            // for every candidate. Restore it to the first speculative target;
            // exact-key reconciliation still uses cachedPageCandidates.
            if let firstPrepared {
                cachedNextPage = firstPrepared
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
        try requireReaderOperation(.ttsPreparation, reason: reason)
        guard mode == .read, preloadEpoch == epoch else { return false }
        let afterKey = normalizedPageKey(prepared.afterKey)
        let pageKey = normalizedPageKey(prepared.page.key)
        guard !afterKey.isEmpty, !pageKey.isEmpty, pageKey != afterKey else { return false }

        let fingerprint = readSpeechFingerprint(prepared.document)
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

        let chunks = KindleFootnoteSpeech.prepare(document: prepared.document, skipReferences: skipsFootnoteReferences).paragraphs.map(\.spokenParagraph)
            .filter(Self.isReadableKindleParagraph)
            .flatMap { playbackChunks(for: $0, slot: .current) }
        let preferredStart = bridgedNextResumeByPageKey[pageKey]
        let startIndex = preferredStart.flatMap { chunks.indices.contains($0) ? $0 : nil } ?? chunks.indices.first ?? -1
        guard startIndex >= 0 else { return false }

        let segments = try await generateDetachedTTSSegments(
            paragraphIndex: startIndex,
            text: chunks[startIndex].text,
            language: prepared.document.language,
            voiceOverride: voiceID,
            presetPriority: .speculative
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
        guard readerOperationAllowed(.ttsPreparation, reason: "explain-first-block") else { return }
        guard mode == .explain, preloadEpoch == epoch else { return }
        guard ProManager.shared.isPro else {
            KindleRunLog.write("KINDLE explain prefetch skip free-user after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) epoch=\(epoch)")
            return
        }
        let fingerprint = Self.explainFingerprint(document)
        if let cached = cachedExplainPrefetchCandidates[pageKey] ?? cachedExplainPrefetch,
           cached.afterKey == afterKey,
           cached.pageKey == pageKey,
           cached.textFingerprint == fingerprint,
           cached.payload.matchesCurrentSettings {
            return
        }
        if let confirmed = explainPagePreparation?.confirmedTargetKey, pageKey != confirmed { return }
        if explainPrefetchingAfterKey == afterKey, explainPrefetchingPageKey == pageKey { return }
        explainPrefetchTask?.cancel()
        let requestID = UUID()
        explainPrefetchRequestID = requestID
        explainPrefetchingAfterKey = afterKey
        explainPrefetchingPageKey = pageKey
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
            // Cancellation of an earlier voice must not clear the replacement
            // request for the same page/epoch when its catch/defer runs later.
            defer {
                if self.explainPrefetchRequestID == requestID {
                    self.explainPrefetchRequestID = nil
                    self.explainPrefetchingAfterKey = nil
                    self.explainPrefetchingPageKey = nil
                    self.explainPrefetchTask = nil
                }
            }
            do {
                guard self.preloadEpoch == epoch,
                      self.explainPrefetchRequestID == requestID else { return }
                guard let vm = self.explainVM else { return }
                let payload = try await vm.prefetchFirstBlock(
                    for: document,
                    previousSummary: previousSummary,
                    textFingerprint: fingerprint
                )
                guard !Task.isCancelled, self.preloadEpoch == epoch,
                      self.explainPrefetchRequestID == requestID else { return }
                if self.explainPrefetchingAfterKey == afterKey,
                   self.preloadEpoch == epoch {
                    let prefetch = KindleExplainPrefetch(
                        afterKey: afterKey,
                        pageKey: pageKey,
                        textFingerprint: fingerprint,
                        payload: payload
                    )
                    self.cacheExplainPrefetchCandidate(prefetch)
                    KindleRunLog.write("KINDLE explain prefetch ready after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) blocks=\(payload.totalBlocks) epoch=\(epoch)")
                    #if DEBUG
                    NSLog("CRDBG KINDLE explain prefetch ready after=%@ key=%@ blocks=%d",
                          Self.keyLog(afterKey),
                          Self.keyLog(pageKey),
                          payload.totalBlocks)
                    #endif
                }
            } catch is CancellationError {
                KindleRunLog.write("KINDLE explain prefetch cancelled after=\(Self.keyLog(afterKey)) key=\(Self.keyLog(pageKey)) epoch=\(epoch)")
            } catch {
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
        } else {
            if !(await restorePlaybackKeyVisibility(preparedKey, reason: "activate-prepared", maxSteps: 10)) {
                KindleRunLog.write("KINDLE activate prepared visibility-soft-miss key=\(Self.keyLog(preparedKey))")
                #if DEBUG
                NSLog("CRDBG KINDLE activate prepared visibility soft miss key=%@",
                      Self.keyLog(preparedKey))
                #endif
            }
            // Restoration can move/reflow the surface and needs a fresh wait.
            // The already-visible path just verified this exact key and stable
            // visible geometry twice; repeating a 480 ms wait adds only silence.
            try await waitForKindleImageStable()
        }

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
        voiceOverride: String? = nil,
        presetPriority: PresetTTSRequestScheduler.Priority = .interactive
    ) async throws -> [AudioSegment] {
        try requireReaderOperation(.ttsPreparation, reason: "detached-tts")
        let voice = voiceOverride ?? AppSettings.shared.voice(for: language)
        return try await TTSService.shared.generatePrefetchSegments(
            paragraphIndex: paragraphIndex,
            text: text,
            voice: voice,
            speed: 1.0,
            language: language,
            presetPriority: presetPriority
        )
    }

    private func nextVisualSyncSequence() -> UInt64 {
        visualSyncSequence &+= 1
        return visualSyncSequence
    }

    private var isContinuousReadVisualTransition: Bool {
        continuousReadHandoff != nil &&
            continuousReadVisualPreparation.suppressesLiveHighlight
    }

    private func restoreContinuousReadLiveHighlight() {
        guard mode == .read, !isContinuousReadVisualTransition,
              let owner = readVM, owner.currentParagraphIndex >= 0,
              let range = owner.photoHighlightWordRange
                ?? owner.photoHighlightWordIndex.map({ $0..<($0 + 1) }),
              !range.isEmpty else { return }
        if range.count > 1 {
            enqueueHighlightWordRange(paragraphIndex: owner.currentParagraphIndex, range: range)
        } else {
            enqueueHighlightWord(paragraphIndex: owner.currentParagraphIndex, wordIndex: range.lowerBound)
        }
    }

    private func enqueueHighlightWord(paragraphIndex: Int, wordIndex: Int) {
        guard !isContinuousReadVisualTransition else { return }
        enqueueVisualHighlight(.word(paragraphIndex: paragraphIndex, wordIndex: wordIndex))
    }

    private func enqueueHighlightWordRange(paragraphIndex: Int, range: Range<Int>) {
        guard !isContinuousReadVisualTransition else { return }
        enqueueVisualHighlight(.range(paragraphIndex: paragraphIndex, range: range))
    }

    /// Serialize WebKit paint calls. Cancelling an in-flight first word on every
    /// audio tick made a busy page discard word 0, then word 1, then word 2 until
    /// one request finally completed. Keep the current paint alive and coalesce
    /// only the pending request to the latest timestamp.
    private func enqueueVisualHighlight(_ request: PendingVisualHighlight) {
        if visualSyncTask != nil {
            pendingVisualHighlight = request
            return
        }
        startVisualHighlight(request)
    }

    private func startVisualHighlight(_ request: PendingVisualHighlight) {
        let sequence = nextVisualSyncSequence()
        activeVisualSyncSequence = sequence
        visualSyncTask = Task { [weak self] in
            guard let self else { return }
            if !Task.isCancelled {
                switch request {
                case let .word(paragraphIndex, wordIndex):
                    await self.highlightWord(
                        paragraphIndex: paragraphIndex,
                        wordIndex: wordIndex,
                        sequence: sequence
                    )
                case let .range(paragraphIndex, range):
                    await self.highlightWordRange(
                        paragraphIndex: paragraphIndex,
                        range: range,
                        sequence: sequence
                    )
                }
            }

            let completion = KindleVisualHighlightQueueContract.completion(
                activeSequence: self.activeVisualSyncSequence,
                completedSequence: sequence,
                taskCancelled: Task.isCancelled,
                hasPending: self.pendingVisualHighlight != nil
            )
            guard completion != .stale else { return }
            self.visualSyncTask = nil
            self.activeVisualSyncSequence = nil
            guard completion == .drainPending,
                  let pending = self.pendingVisualHighlight else {
                self.pendingVisualHighlight = nil
                return
            }
            self.pendingVisualHighlight = nil
            self.startVisualHighlight(pending)
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
                _ = audio.pauseActivePlaybackForCoordinator(owner: .readAloud)
                await refocusPlaybackPosition(reason: "highlight-recovery")
                if shouldResume,
                   audio.currentBookId == book.id,
                   readVM != nil {
                    _ = audio.playActivePlaybackForCoordinator(owner: .readAloud)
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
        if let hold = explainVisualHold {
            let resolver = PhotoAnchorResolver(document: hold.document, fitted: hold.imageRect)
            for mark in marks where !shownMarkIds.contains(mark.id.uuidString) {
                let rects = resolver.rectsForCharRange(paragraphIndex: mark.paragraphIndex, range: mark.charRange)
                shownMarkIds.insert(mark.id.uuidString)
                KindleRunLog.write("KINDLE explain held-mark id=\(mark.id.uuidString.prefix(8)) rects=\(rects.count)")
            }
            return
        }
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
            guard explainVisualHold == nil else { return }
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
            if let owner = explainVM,
               let json = await markDrawingPayload(payload, mark: mark, owner: owner) {
                let result = try? await evaluateJSON("window.__crKindleLiveShowMark && window.__crKindleLiveShowMark(\(json))")
                guard explainVM === owner, mode == .explain, explainVisualHold == nil else { return }
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

    private func markDrawingPayload(_ payload: [String: Any], mark: ResolvedMark,
                                    owner: ExplainViewModel) async -> String? {
        var geometryPayload = payload
        geometryPayload["canvasOnly"] = true
        guard let geometryJSON = try? jsonString(geometryPayload) else { return nil }
        let epoch = preloadEpoch
        let fit = (webView.superview as? KindleWebViewContainer)?.presentationFit ?? viewportPresentationFit
        guard let canvas = try? await evaluateJSON(
            "window.__crKindleLiveShowMark && window.__crKindleLiveShowMark(\(geometryJSON))"
        ), canvas["ok"] as? Bool == true,
           explainVM === owner, mode == .explain, explainVisualHold == nil, preloadEpoch == epoch,
           fit == ((webView.superview as? KindleWebViewContainer)?.presentationFit ?? viewportPresentationFit),
           let key = canvas["key"] as? String,
           let width = canvas["width"] as? Double, let height = canvas["height"] as? Double,
           width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
        let size = CGSize(width: width * fit.scale, height: height * fit.scale)
        let resolver = PhotoAnchorResolver(document: owner.document, fitted: CGRect(origin: .zero, size: size))
        let rects = resolver.rectsForCharRange(paragraphIndex: mark.paragraphIndex, range: mark.charRange)
        guard !rects.isEmpty else { return nil }
        let ink = HandwrittenMark.stroke(action: mark.action, rects: rects, seed: mark.seed,
                                         n: mark.n, weight: mark.weight)
        var drawingPayload = payload
        drawingPayload["canvasKey"] = key
        drawingPayload["canvasWidth"] = width
        drawingPayload["canvasHeight"] = height
        drawingPayload["ink"] = ink.svgPayload(canvasSize: size)
        return try? jsonString(drawingPayload)
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
        guard let session = coordinator.session, session.document.id == document.id else { return }

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
        let storefront = KindleStorefront.entry(id: book.storefrontID) ?? store.boundStorefront
        guard let url = URL(string: trimmed) ?? URL(string: encoded),
              let expectedASIN = expectedReaderASIN,
              KindleStorefrontNavigationPolicy.isExactReaderURL(
                  url,
                  expectedStorefrontID: storefront.id,
                  expectedASIN: expectedASIN
              ) else {
            KindleRunLog.write("KINDLE webview load failed-invalid reason=\(reason) raw=\(Self.keyLog(raw))")
            isStaleBookEntryError = true
            statusText = AppLocalized("Kindle 书籍入口已失效，请重新同步书架。")
            return
        }
        KindleRunLog.write("KINDLE webview load reason=\(reason) storefront=\(storefront.id) route=\(KindleSessionProbe.safeRouteLabel(url)) raw=\(Self.keyLog(raw)) last=\(Self.keyLog(book.lastReadURL ?? "")) sinceReaderOK=\(KindleSessionFreshness.sinceReaderOK) sinceShelfOK=\(KindleSessionFreshness.sinceShelfOK)")
        KindleSessionProbe.logCookies(reason: "book-load-\(reason)")
        resetReaderControlsForNavigation()
        webView.load(URLRequest(url: url))
    }

    /// Now the only place the capture bootstrap is injected — it used to run here
    /// *and* at document start on every navigation, paying the 207KB parse twice.
    /// Metadata is already installed by the user script, so it is not repeated.
    private func installCaptureScript() {
        guard readerOperationAllowed(.readerSetup, reason: "install-capture-script") else { return }
        guard KindleStorefront.matches(url: webView.url) else { return }
        webView.evaluateJavaScript(
            KindleWebScripts.restrictedToKnownStorefronts(KindleWebScripts.pageCaptureBootstrap),
            completionHandler: nil
        )
    }

    @discardableResult
    private func ensureCaptureScriptInstalled(reason: String) async throws -> [String: Any] {
        try requireReaderOperation(.readerSetup, reason: reason)
        guard KindleStorefront.matches(url: webView.url) else {
            KindleRunLog.write("KINDLE script install blocked unknown-origin reason=\(reason)")
            throw KindleBookError.invalidPayload
        }
        let generation = readerControlsNavigationGeneration
        let expectedBookID = book.id
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
          var lockReady = typeof window.__crKindleSetPageModeLocked === 'function';
          var syncObserverReady = !!window.__crKindleSyncDialogTimer;
          var ready = turnReady && stateReady && lockReady && syncObserverReady;
          return JSON.stringify({
            ok:ready,
            reason:ready ? '' : 'missing-functions',
            turn:turnReady,
            state:stateReady,
            lock:lockReady,
            syncObserver:syncObserverReady,
            installedVersion:window.__crKindleInstalledVersion || 0,
            url:location.href
          });
        })()
        """
        let result = try await evaluateJSON(script)
        guard !Task.isCancelled, readerControlsNavigationGeneration == generation,
              book.id == expectedBookID, !webView.isLoading else { throw CancellationError() }
        let ok = Self.boolValue(result["ok"])
        // A sync prompt is allowed to be visible here. Readiness describes its
        // installed observer, while the interaction gate owns the user choice.
        readerControlsReady = ok
        KindleRunLog.write("KINDLE reader controls ready=\(ok) syncObserver=\(Self.boolValue(result["syncObserver"]))")
        KindleRunLog.write("KINDLE script install reason=\(reason) ok=\(ok) turn=\(String(describing: result["turn"] ?? false)) state=\(String(describing: result["state"] ?? false)) version=\(String(describing: result["installedVersion"] ?? 0)) jsReason=\(String(describing: result["reason"] ?? ""))")
        guard ok else {
            throw KindleBookError.captureFailed("kindle-script-not-ready:\(result["reason"] as? String ?? "unknown")")
        }
        return result
    }

    private func setKindlePageModeLockedLightweight(_ locked: Bool, reason: String) async {
        guard readerOperationAllowed(.layoutRepair, reason: reason) else { return }
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
        guard readerOperationAllowed(.layoutRepair, reason: "page-mode-lock") else { return }
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
        try requireReaderOperation(.readerSetup, reason: "wait-page-ready")
        for _ in 0..<12 {
            try requireReaderOperation(.readerSetup, reason: "wait-page-ready-loop")
            installCaptureScript()
            if let state = try? await evaluateJSON("window.__crKindleState && window.__crKindleState()"),
               (state["heldKeys"] as? Int ?? 0) > 0 || !(state["key"] as? String ?? "").isEmpty {
                return
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private func waitForKindleImageStable() async throws {
        try requireReaderOperation(.layoutRepair, reason: "wait-image-stable")
        var previousSignature: String?
        var stableHits = 0
        for attempt in 0..<24 {
            try requireReaderOperation(.layoutRepair, reason: "wait-image-stable-loop")
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
        try requireReaderOperation(.capture, reason: "visible-page")
        var lastReason = "no-visible-kindle-image"
        for _ in 0..<10 {
            try requireReaderOperation(.capture, reason: "visible-page-loop")
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
        try requireReaderOperation(.capture, reason: "nearby-page")
        var lastReason = "no-nearby-kindle-image"
        for _ in 0..<5 {
            try requireReaderOperation(.capture, reason: "nearby-page-loop")
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
        try requireReaderOperation(.capture, reason: "next-page")
        installCaptureScript()
        await setKindlePageModeLocked(true)
        let escapedKey = afterKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        var lastReason = "no-next-candidate"
        for attempt in 0..<6 {
            try requireReaderOperation(.capture, reason: "next-page-loop")
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

    private func captureCandidatePages(
        afterKey: String, limit: Int,
        onCaptured: ((CapturedKindlePage) async throws -> Void)? = nil
    ) async throws -> [CapturedKindlePage] {
        try requireReaderOperation(.capture, reason: "candidate-pages")
        installCaptureScript()
        await setKindlePageModeLocked(true)
        let escapedKey = afterKey
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let boundedLimit = max(1, min(12, limit))
        var payload: [String: Any] = [:]
        for attempt in 0..<3 {
            let candidatePayload = try await evaluateJSON("window.__crKindleCandidateSnapshotsAfterKey && window.__crKindleCandidateSnapshotsAfterKey('\(escapedKey)', \(boundedLimit), \(Self.ocrCaptureJavaScriptArguments), true)")
            let candidateCount = (candidatePayload["pages"] as? [[String: Any]] ?? []).count
            let heldCount = Self.int(from: candidatePayload["heldCount"]) ?? 0
            if candidateCount > (payload["pages"] as? [[String: Any]] ?? []).count {
                payload = candidatePayload
            }
            let expectedCount = min(boundedLimit, max(1, heldCount - 1))
            if candidateCount >= expectedCount || attempt == 2 {
                if candidateCount >= (payload["pages"] as? [[String: Any]] ?? []).count {
                    payload = candidatePayload
                }
                break
            }
            // The early document-start hook owns independent Blob URLs, but the
            // full capture script creates Image decoders lazily. Give those
            // held images one run-loop turn before taking the final snapshots.
            try await Task.sleep(nanoseconds: 180_000_000)
        }
        let rawPages = payload["pages"] as? [[String: Any]] ?? []
        var pages: [CapturedKindlePage] = []
        var seen = Set<String>()
        for raw in rawPages {
            try Task.checkCancellation()
            guard raw["ok"] as? Bool == true else { continue }
            let key = (raw["key"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !key.isEmpty, key != afterKey, !seen.contains(key) else { continue }
            let page: CapturedKindlePage
            if let fingerprint = raw["pixelFingerprint"] as? String, !fingerprint.isEmpty,
               let cached = preparedCandidate(forKey: key), cached.page.pixelFingerprint == fingerprint {
                page = cached.page.replacingSessionId(Self.int(from: raw["sessionId"]) ?? 0)
                KindleRunLog.write("KINDLE preload OCR-cache-hit key=\(Self.keyLog(key))")
            } else {
                let encodedKey = String(data: try JSONSerialization.data(withJSONObject: [key]), encoding: .utf8)!
                let snapshot = try await evaluateJSON("window.__crKindlePrefetchSnapshotForKey && window.__crKindlePrefetchSnapshotForKey(\(encodedKey)[0], \(Self.ocrCaptureJavaScriptArguments))")
                guard snapshot["ok"] as? Bool == true,
                      snapshot["key"] as? String == key,
                      snapshot["pixelFingerprint"] as? String == raw["pixelFingerprint"] as? String else { continue }
                var capture = raw
                capture.merge(snapshot) { _, fresh in fresh }
                capture["source"] = raw["source"]
                page = try await makeCapturedPage(from: capture, pageIndex: pages.count)
            }
            try Task.checkCancellation()
            guard !page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            seen.insert(key)
            pages.append(page)
            try await onCaptured?(page)
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
        let page = try await captureNextPage(afterKey: afterKey)
        try await onCaptured?(page)
        return [page]
    }

    private func makeCapturedPage(from payload: [String: Any], pageIndex: Int) async throws -> CapturedKindlePage {
        try requireReaderOperation(.capture, reason: "make-captured-page")
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
        try requireReaderOperation(.ocr, reason: "recognize-page")
        // Same authority order as the extension: renderer metadata first, then a
        // previously verified profile, finally independent single-locale OCR consensus.
        var profile = await rendererKindleLanguageProfile()
        if profile == nil, KindleLanguageContract.isVerified(language: book.language, source: book.languageSource) {
            profile = persistedKindleLanguageProfile()
        }
        let correction = ReadingLanguageStore.shared.override(for: readingLanguageContentKey)
        // The consensus probe recognizes the page once per supported language, so
        // it is a last resort — and pointless once the reader has said what this
        // book is. Skipping it also keeps a wrong guess from being persisted as a
        // verified profile behind a correction that already answered the question.
        if profile == nil, KindleLanguageContract.normalize(correction) == nil {
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
        // The reader's own correction outranks all three, and is deliberately kept
        // in its own store rather than written back over `book.language`: those
        // record what the renderer and the OCR consensus believe, this records what
        // the reader said. Mixing them is how a wrong guess becomes unappealable.
        if let corrected = KindleReadingLanguageCorrection.profile(
            correcting: profile,
            with: correction
        ) {
            KindleRunLog.write(
                "KINDLE_PROFILE_USER_CORRECTED asin=\(Self.keyLog(book.asin ?? book.id)) " +
                "from=\(profile?.language ?? "none") to=\(corrected.language) " +
                "ocrLocale=\(corrected.visionLocale)"
            )
            profile = corrected
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
                // The spread detector has already isolated one visible page.
                paragraphStrategy: KindleLivePageOCRContract.isolatedPageStrategy,
                verticalColumnHints: kindleVerticalColumnHints
            )
            let right = try? await OCRService.shared.recognizeKindle(
                image: split.right.image,
                profile: profile,
                title: book.title,
                paragraphStrategy: KindleLivePageOCRContract.isolatedPageStrategy,
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
            // A failed spread crop still needs the general column fallback;
            // an explicitly single renderer page must never be re-cut by the
            // generic document layout analyzer.
            paragraphStrategy: KindleLivePageOCRContract.wholeImageStrategy(
                rendererDetectedDualPage: layout.isDual
            ),
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

    /// Must agree with `ReadAloudViewModel.readingLanguageContentKey`, which files
    /// the correction under the playback book id this reader hands it.
    private var readingLanguageContentKey: String {
        ReadingLanguageStore.contentKey(
            namespace: ReadingSourceKind.kindle.rawValue,
            bookID: book.id
        )
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
                    return word.reidentified(id: newID)
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
                return word.reidentified(id: nextWordID)
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
            imagePixelSize: page.document.imagePixelSize,
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
        var nextSourceLineID = 0
        var sourceLineIDs: [String: Int] = [:]

        for (columnIndex, column) in columns.enumerated() {
            for paragraph in column.document.paragraphs where paragraph.type.isReadable {
                let text = paragraph.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let words = paragraph.words.map { word -> OCRWord in
                    defer { nextWordID += 1 }
                    let sourceLineID = word.sourceLineID.map { original -> Int in
                        let key = "\(columnIndex):\(original)"
                        if let existing = sourceLineIDs[key] { return existing }
                        defer { nextSourceLineID += 1 }
                        sourceLineIDs[key] = nextSourceLineID
                        return nextSourceLineID
                    }
                    return OCRWord(
                        id: nextWordID,
                        text: word.text,
                        bboxNorm: remapColumnRectToFullPage(
                            word.bboxNorm,
                            originX: column.originX,
                            width: column.width,
                            fullWidth: fullPixelWidth
                        ),
                        bboxSource: word.bboxSource, sourceLineID: sourceLineID,
                        recognitionConfidence: word.recognitionConfidence,
                        inkBoundsNorm: word.inkBoundsNorm.map {
                            remapColumnRectToFullPage($0, originX: column.originX, width: column.width, fullWidth: fullPixelWidth)
                        },
                        inkBoundsChecked: word.inkBoundsChecked
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

    /// 翻页取证每个进程只抓一次，避免连续失败时刷屏。
    private static var didCapturePageTurnForensics = false

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
        let hash = SHA256.hash(data: Data(key.utf8))
        return hash.prefix(6).map { String(format: "%02x", $0) }.joined()
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

/// A held image is useful only while the exact native presentation that it
/// covers remains owned by this reader. CSS bounds and native transform are
/// tracked separately so a presentation-only calibration also invalidates it.
@MainActor
struct KindleVisualHoldViewportLease {
    let webView: WKWebView
    let host: KindleWebViewContainer
    let window: UIWindow
    let hostBounds: CGRect
    let webBounds: CGRect
    let webCenter: CGPoint
    let webTransform: CGAffineTransform
    let crop: KindleViewportCrop
    let fit: KindleViewportPresentationFit
    let canonical: CGRect

    init?(webView: WKWebView, surfaceSize: CGSize, onFailure: (String) -> Void = { _ in }) {
        guard let host = webView.superview as? KindleWebViewContainer else {
            onFailure("viewport-host"); return nil
        }
        guard let window = webView.window, host.window === window else {
            onFailure("viewport-window"); return nil
        }
        guard surfaceSize.width > 40, surfaceSize.height > 40,
              abs(host.bounds.width - surfaceSize.width) <= 1,
              abs(host.bounds.height - surfaceSize.height) <= 1,
              webView.bounds.width > 40, webView.bounds.height > 40 else {
            onFailure("viewport-size surface=\(surfaceSize) host=\(host.bounds.size) web=\(webView.bounds.size)"); return nil
        }
        let canonical = KindleViewportPresentationPolicy.canonicalFrame(surfaceSize: host.bounds.size, crop: host.crop)
        let fit = host.presentationFit
        let expectedCenter = CGPoint(x: canonical.midX * fit.scale + fit.translationX,
                                     y: canonical.midY * fit.scale + fit.translationY)
        guard abs(webView.bounds.width - canonical.width) <= 1,
              abs(webView.bounds.height - canonical.height) <= 1, fit.isValid else {
            onFailure("viewport-canonical web=\(webView.bounds.size) canonical=\(canonical.size) fitValid=\(fit.isValid)"); return nil
        }
        guard abs(webView.center.x - expectedCenter.x) <= 0.01,
              abs(webView.center.y - expectedCenter.y) <= 0.01,
              webView.transform == CGAffineTransform(scaleX: fit.scale, y: fit.scale) else {
            onFailure("viewport-transform center=\(webView.center) expected=\(expectedCenter) transform=\(webView.transform) scale=\(fit.scale)"); return nil
        }
        self.webView = webView
        self.host = host
        self.window = window
        hostBounds = host.bounds
        webBounds = webView.bounds
        webCenter = webView.center
        webTransform = webView.transform
        crop = host.crop
        self.fit = fit
        self.canonical = canonical
    }

    var isCurrent: Bool {
        webView.superview === host && webView.window === window && host.window === window &&
            host.bounds == hostBounds && webView.bounds == webBounds &&
            webView.center == webCenter && webView.transform == webTransform &&
            host.crop == crop && host.presentationFit == fit &&
            KindleViewportPresentationPolicy.canonicalFrame(surfaceSize: host.bounds.size, crop: host.crop) == canonical
    }

    /// A private CSS mask leaves the live word/range node intact, including
    /// updates received while WebKit captures. Cleanup always runs, even if
    /// the capture is cancelled or loses its viewport/page owner. Removing
    /// only this mask cannot clear a newer page's highlight.
    func snapshotExcludingLiveHighlight(isOwnerCurrent: () -> Bool) async -> UIImage? {
        guard !Task.isCancelled, isCurrent, isOwnerCurrent() else { return nil }
        let maskID = "cr-kindle-snapshot-mask-" + UUID().uuidString
        let installed = try? await webView.evaluateJavaScript("""
        (function(){
          var mask = document.createElement('style');
          mask.id = '\(maskID)';
          mask.textContent = '#castreader-kindle-live-word { visibility: hidden !important; }';
          (document.head || document.documentElement).appendChild(mask);
          return true;
        })()
        """)
        guard installed as? Bool == true else { return nil }
        let image = await snapshot(isOwnerCurrent: isOwnerCurrent)
        _ = try? await webView.evaluateJavaScript("""
        (function(){ var mask = document.getElementById('\(maskID)'); if (mask) mask.remove(); })()
        """)
        guard !Task.isCancelled, isCurrent, isOwnerCurrent() else { return nil }
        return image
    }

    func snapshot(isOwnerCurrent: () -> Bool) async -> UIImage? {
        guard !Task.isCancelled, isCurrent, isOwnerCurrent() else { return nil }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = webBounds
        configuration.snapshotWidth = NSNumber(value: Double(webBounds.width))
        let image: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, _ in
                continuation.resume(returning: image)
            }
        }
        guard !Task.isCancelled, isCurrent, isOwnerCurrent() else { return nil }
        return image
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

private final class KindleExplainPagePreparation {
    let owner: ExplainViewModel
    let oldKey: String
    let epoch: UInt64
    var task: Task<Void, Never>?
    var semanticActionAttempted = false
    var dispatchEvidence = KindlePageTurnDispatchEvidence.unknown
    var confirmedTargetKey: String?
    var prepared: KindleCachedPage?

    init(owner: ExplainViewModel, oldKey: String, epoch: UInt64) {
        self.owner = owner
        self.oldKey = oldKey
        self.epoch = epoch
    }
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
    case cookieConsentVisible
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
        case .cookieConsentVisible:
            return AppLocalized("请先处理 Amazon 的 Cookie 提示。")
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
