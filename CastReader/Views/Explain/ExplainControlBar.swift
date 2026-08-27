//
//  ExplainControlBar.swift
//  CastReader
//
//  解读控制条：与 Kindle 共用紧凑单行控制台；字幕悬浮在控制台
//  上方，不参与阅读区域布局。
//

import SwiftUI

enum ExplainSegmentProgressCopy {
    static func text(block: Int, total: Int, preparingNext: Bool) -> String {
        let safeTotal = max(1, total)
        let current = preparingNext
            ? min(block + 2, safeTotal)
            : min(block + 1, safeTotal)
        let key = preparingNext
            ? AppLocalized("第 %1$lld/%2$lld 段…")
            : AppLocalized("第 %1$lld/%2$lld 段")
        return String(format: key, Int64(current), Int64(safeTotal))
    }
}

/// Shared Kindle-style single-line caption. The bubble keeps its intrinsic
/// width while the outer frame controls center/trailing alignment.
struct ExplainPlaybackCaptionBubble: View {
    let text: String
    var foregroundColor: Color = AppTheme.foreground
    var alignment: Alignment = .center
    var maxWidth: CGFloat = 620
    var accessibilityIdentifier = "readerExplainCaption"

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .foregroundColor(foregroundColor)
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
            .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct ExplainControlBar: View {
    @ObservedObject var vm: ExplainViewModel
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared
    let showTOC: (() -> Void)?
    let previousPage: (() -> Void)?
    let nextPage: (() -> Void)?

    init(
        vm: ExplainViewModel,
        showTOC: (() -> Void)? = nil,
        previousPage: (() -> Void)? = nil,
        nextPage: (() -> Void)? = nil
    ) {
        self.vm = vm
        self.showTOC = showTOC
        self.previousPage = previousPage
        self.nextPage = nextPage
    }

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
        voiceSwitch.progress != nil
            || vm.isPreparingNext
            || vm.isContinuingLivePage
            || statusIsPlanning
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
            ZStack(alignment: .top) {
                if shouldShowCaption {
                    ExplainPlaybackCaptionBubble(text: vm.explanationText)
                        .padding(.horizontal, 18)
                        .offset(y: ReaderPlaybackBarLayoutContract.explainCaptionOffset)
                        .allowsHitTesting(false)
                        .zIndex(1)
                } else if let errorText {
                    ExplainPlaybackCaptionBubble(
                        text: errorText,
                        foregroundColor: AppTheme.destructive,
                        accessibilityIdentifier: "readerExplainError"
                    )
                    .padding(.horizontal, 18)
                    .offset(y: ReaderPlaybackBarLayoutContract.explainCaptionOffset)
                    .allowsHitTesting(false)
                    .zIndex(1)
                }

                ReaderPlaybackConsole(
                    playbackStatus: playbackStatus(for: presentationState),
                    statusMessage: voiceSwitch.progress?.localizedMessage,
                    voiceLanguage: vm.playbackLanguage,
                    showTOC: showTOC
                ) {
                    controlCluster(for: presentationState)
                }
            }
        }
        .frame(height: ReaderPlaybackBarLayoutContract.consoleHeight)
        .animation(.easeInOut(duration: 0.2), value: vm.explanationText)
    }

    private var shouldShowCaption: Bool {
        guard !vm.isPreparingNext, !vm.explanationText.isEmpty else { return false }
        if case .streaming = vm.status { return true }
        return false
    }

    private var errorText: String? {
        guard case .error(let message) = vm.status, !message.isEmpty else { return nil }
        return message
    }

    private func playbackStatus(
        for presentationState: ReaderExplainPlaybackPresentationState
    ) -> String {
        switch presentationState {
        case .start: return AppLocalized("开始解读")
        case .retry: return AppLocalized("重试解读")
        case .waiting:
            if case .streaming = vm.status {
                return AppLocalized("正在准备下一段…")
            }
            return AppLocalized("正在准备…")
        case .playing: return AppLocalized("解读中")
        case .paused: return AppLocalized("已暂停")
        case .replay: return AppLocalized("解读完成")
        }
    }

    private func statusLabel(
        for presentationState: ReaderExplainPlaybackPresentationState
    ) -> String {
        if presentationState == .waiting {
            if case .streaming = vm.status {
                return AppLocalized("正在准备下一段…")
            }
            if vm.isContinuingLivePage {
                return AppLocalized("继续讲解…")
            }
        }
        switch vm.status {
        case .idle:
            return AppLocalized("开始解读")
        case .error:
            return AppLocalized("重试解读")
        case .planning:
            return vm.stageText.isEmpty ? AppLocalized("通读全文…") : vm.stageText
        case .streaming(let block, let total):
            return ExplainSegmentProgressCopy.text(
                block: block,
                total: total,
                preparingNext: vm.isPreparingNext
            )
        case .completed:
            if vm.isContinuingLivePage {
                return AppLocalized("继续讲解…")
            }
            return AppLocalized("解读完成")
        }
    }

    private func controlCluster(
        for presentationState: ReaderExplainPlaybackPresentationState
    ) -> some View {
        HStack(spacing: 8) {
            if let previousPage {
                ReaderPlaybackPageTurnButton(
                    direction: .previous,
                    action: previousPage
                )
            }
            Button {
                performAction(for: presentationState)
            } label: {
                ReaderPrimaryPlaybackButtonContent(
                    icon: buttonIcon(for: presentationState),
                    size: ReaderPrimaryPlaybackButtonVisualContract.portraitSize
                )
            }
            .buttonStyle(.plain)
            .disabled(presentationState == .waiting)
            .accessibilityIdentifier(accessibilityIdentifier(for: presentationState))
            .accessibilityLabel(Text(statusLabel(for: presentationState)))
            .accessibilityValue(
                Text(presentationState == .playing ? "playing" : "paused")
            )

            if let nextPage {
                ReaderPlaybackPageTurnButton(
                    direction: .next,
                    action: nextPage
                )
            } else {
                statusText(for: presentationState)
            }
        }
    }

    private func performAction(
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

    private func buttonIcon(
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

    private func accessibilityIdentifier(
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

    private func statusText(
        for presentationState: ReaderExplainPlaybackPresentationState
    ) -> some View {
        Text(statusLabel(for: presentationState))
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.mutedForeground)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 100, alignment: .leading)
    }
}
