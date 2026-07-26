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
    /// Read/Explain controls must reserve one stable viewport boundary. WeRead
    /// paginates its Canvas from the WKWebView size; allowing the explanation
    /// subtitle/status rows to grow this area used to resize the Canvas, which
    /// was then mistaken for a real page turn and restarted QuickRead.
    private static let portraitPlaybackBarHeight: CGFloat = 124

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @ObservedObject var readVM: ReadAloudViewModel
    @ObservedObject var explainVM: ExplainViewModel
    @ObservedObject var coordinator: PlayerCoordinator
    let document: ReadingDocument

    @StateObject private var weReadTOC = WeReadTOCController()
    @State private var readerSurfaceSize: CGSize = .zero
    @State private var refocusToken = 0
    @State private var refocusTask: Task<Void, Never>?

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
        }
        .background(AppTheme.background.ignoresSafeArea())
        .onAppear { scheduleRefocusBurst(reason: "appear") }
        .onDisappear {
            refocusTask?.cancel()
        }
        .onPreferenceChange(ReaderSurfaceSizeKey.self) { size in
            guard coordinator.isReaderPresented else { return }
            guard size.width > 1, size.height > 1 else { return }
            guard abs(size.width - readerSurfaceSize.width) > 2
                    || abs(size.height - readerSurfaceSize.height) > 2 else { return }
            readerSurfaceSize = size
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
            if newMode == .read {
                explainVM.deactivate()
                readVM.activate()       // 切回朗读：重新接管音频回调（onPlaybackComplete）
            } else {
                readVM.deactivate()
                explainVM.activate()    // 切到解读：接管音频回调
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
            Picker("", selection: $coordinator.mode) {
                ForEach(ReaderMode.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, usesCompactPlaybackBar ? 6 : 10)
        .frame(height: usesCompactPlaybackBar ? 44 : nil)
        .background(.regularMaterial)
    }

    // MARK: 内容

    @ViewBuilder
    private func content(surfaceSize: CGSize) -> some View {
        switch document.sourceKind {
        case .web, .docx, .weread:
            WebReaderView(
                document: document,
                readVM: readVM,
                explainVM: explainVM,
                mode: mode,
                refocusToken: refocusToken,
                initialSurfaceSize: surfaceSize,
                weReadTOC: weReadTOC
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
                    showTOC: document.sourceKind == .weread ? { weReadTOC.present() } : nil
                )
            } else {
                ExplainControlBar(
                    vm: explainVM,
                    showTOC: document.sourceKind == .weread ? { weReadTOC.present() } : nil
                )
            }
        }
        .frame(height: Self.portraitPlaybackBarHeight)
        .clipped()
        .opacity(weReadTOC.isPresented ? 0 : 1)
        .allowsHitTesting(!weReadTOC.isPresented && !weReadTOC.isJumping)
        .accessibilityHidden(weReadTOC.isPresented || weReadTOC.isJumping)
    }

    @ViewBuilder
    private var landscapeControls: some View {
        if mode == .read {
            ReaderLandscapeReadOverlay(
                vm: readVM,
                showTOC: document.sourceKind == .weread ? { weReadTOC.present() } : nil
            )
        } else {
            ReaderLandscapeExplainOverlay(
                vm: explainVM,
                showTOC: document.sourceKind == .weread ? { weReadTOC.present() } : nil
            )
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

// MARK: - 朗读控制条

private struct ReadControlBar: View {
    @ObservedObject var vm: ReadAloudViewModel
    let showTOC: (() -> Void)?

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { vm.skipBackward() } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 20))
                        .frame(width: 36, height: 44)
                }
                Button { vm.togglePlayPause() } label: {
                    Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 52))
                        .foregroundColor(AppTheme.primary)
                }
                Button { vm.skipForward() } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 20))
                        .frame(width: 36, height: 44)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 10)

            HStack(spacing: 8) {
                if let showTOC {
                    Button(action: showTOC) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 20, weight: .semibold))
                            .frame(width: 34, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(AppLocalized("目录")))
                }
                if vm.hasStartedPlayback {
                    PlaybackVoiceButton(language: vm.playbackLanguage, size: 34)
                }
                SpeedMenu()
            }
            // The utility cluster is atomic. Let the middle spacer shrink;
            // never squeeze the speed value into a vertical stack.
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
        }
        .foregroundColor(AppTheme.foreground)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}

private struct ReaderLandscapeReadOverlay: View {
    @ObservedObject var vm: ReadAloudViewModel
    let showTOC: (() -> Void)?

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            HStack(spacing: 18) {
                Button { vm.skipBackward() } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 19))
                        .frame(width: 36, height: 36)
                }
                Button { vm.togglePlayPause() } label: {
                    Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(AppTheme.primary)
                }
                Button { vm.skipForward() } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 19))
                        .frame(width: 36, height: 36)
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

private struct ReaderLandscapeExplainOverlay: View {
    @ObservedObject var vm: ExplainViewModel
    let showTOC: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            caption
            HStack(alignment: .bottom, spacing: 14) {
                controlPill
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

    @ViewBuilder
    private var controlPill: some View {
        HStack(spacing: 14) {
            switch vm.status {
            case .idle:
                Button { vm.start() } label: {
                    Image(systemName: "sparkles.circle.fill")
                        .font(.system(size: 42))
                        .foregroundColor(AppTheme.primary)
                }
                Text(AppLocalized("开始解读"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            case .error:
                Button { vm.start() } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 38))
                        .foregroundColor(AppTheme.primary)
                }
                Text(AppLocalized("重试解读"))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            case .planning:
                ProgressView()
                    .frame(width: 38, height: 38)
                Text(vm.stageText.isEmpty ? AppLocalized("通读全文…") : vm.stageText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            case .streaming(let block, let total):
                if vm.isPreparingNext {
                    ProgressView()
                        .frame(width: 38, height: 38)
                    Text(AppLocalized("正在准备下一段…"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Button { vm.togglePlayPause() } label: {
                        Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(AppTheme.primary)
                    }
                    Text("Explaining · block \(block + 1)/\(total)")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            case .completed:
                if vm.isContinuingLivePage {
                    ProgressView()
                        .frame(width: 38, height: 38)
                    Text(AppLocalized("继续讲解…"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                } else {
                    Button { vm.replay() } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 38))
                            .foregroundColor(AppTheme.primary)
                    }
                    Text(AppLocalized("解读完成"))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
            }
        }
        .foregroundColor(AppTheme.foreground)
        .readerLandscapePill()
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
