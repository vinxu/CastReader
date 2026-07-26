//
//  ExplainControlBar.swift
//  CastReader
//
//  解读控制条：上层字幕（讲解文本，全宽多行，逐句推进），下层控制（播放/暂停 · 段进度 · 倍速）。
//  字幕独占一行不被按钮挤压，避免截断。
//

import SwiftUI

struct ExplainControlBar: View {
    @ObservedObject var vm: ExplainViewModel
    let showTOC: (() -> Void)?

    init(vm: ExplainViewModel, showTOC: (() -> Void)? = nil) {
        self.vm = vm
        self.showTOC = showTOC
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            subtitleRow
            HStack(spacing: 0) {
                controlContent
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
                    PlaybackVoiceButton(language: vm.playbackLanguage, size: 34)
                    if showsSpeedControl {
                        SpeedMenu()
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            }
        }
        .foregroundColor(AppTheme.foreground)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // Keep the subtitle slot and the complete bar height invariant across
        // idle/planning/streaming. In WeRead this view sits next to WKWebView;
        // an intrinsic-height animation would repaginate the Canvas for every
        // generated sentence.
        .frame(height: 124)
        .animation(.easeInOut(duration: 0.2), value: vm.explanationText)
    }

    // MARK: 字幕（播放中显示讲解文本，全宽 2 行，独立空间不被控制按钮挤）

    @ViewBuilder
    private var subtitleRow: some View {
        ZStack(alignment: .topLeading) {
            if case .streaming = vm.status, !vm.isPreparingNext, !vm.explanationText.isEmpty {
                Text(vm.explanationText)
                    .font(.callout)
                    .foregroundColor(AppTheme.foreground)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 40, maxHeight: 40, alignment: .topLeading)
        .clipped()
    }

    // MARK: 控制行

    @ViewBuilder
    private var controlContent: some View {
        switch vm.status {
        case .idle:
            startButton(title: AppLocalized("开始解读"), icon: "sparkles")
        case .error(let msg):
            VStack(alignment: .leading, spacing: 4) {
                startButton(title: AppLocalized("重试解读"), icon: "arrow.clockwise")
                Text(msg).font(.caption2).foregroundColor(AppTheme.destructive).lineLimit(1)
            }
        case .planning:
            ProgressView()
            Text(vm.stageText.isEmpty ? AppLocalized("通读全文…") : vm.stageText)
                .font(.subheadline)
                .foregroundColor(AppTheme.mutedForeground)
        case .streaming(let block, let total):
            if vm.isPreparingNext {
                // 块间等待下一段处理：左下角变 loading，避免静默被误以为卡住。
                ProgressView().frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("正在准备第 \(min(block + 2, total))/\(total) 段…")
                        .font(.subheadline.weight(.semibold))
                    Text("讲解生成中，请稍候")
                        .font(.caption).foregroundColor(AppTheme.mutedForeground)
                }
            } else {
                Button { vm.togglePlayPause() } label: {
                    Image(systemName: vm.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 44))
                        .foregroundColor(AppTheme.primary)
                }
                Text("讲解中 · 第 \(block + 1)/\(total) 段")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
        case .completed:
            if vm.isContinuingLivePage {
                ProgressView().frame(width: 44, height: 44)
                Text(AppLocalized("继续讲解…"))
                    .font(.subheadline.weight(.semibold))
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text(AppLocalized("解读完成")).font(.subheadline.weight(.semibold))
                Button { vm.replay() } label: {
                    Label("重播", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(AppTheme.primary)
                }
            }
        }
    }

    private var showsSpeedControl: Bool {
        switch vm.status {
        case .streaming:
            return true
        case .completed:
            return !vm.isContinuingLivePage
        case .idle, .error, .planning:
            return false
        }
    }

    private func startButton(title: String, icon: String) -> some View {
        Button { vm.start() } label: {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(AppTheme.primary)
                .foregroundColor(.white)
                .cornerRadius(12)
        }
    }
}
