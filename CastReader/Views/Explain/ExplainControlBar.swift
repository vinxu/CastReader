//
//  ExplainControlBar.swift
//  CastReader
//
//  解读控制条：阶段提示 / 块进度 / 播放暂停 / 开始 / 重试。
//

import SwiftUI

struct ExplainControlBar: View {
    @ObservedObject var vm: ExplainViewModel

    var body: some View {
        HStack(spacing: 14) {
            content
            Spacer(minLength: 0)
        }
        .foregroundColor(AppTheme.foreground)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(minHeight: 64)
    }

    @ViewBuilder
    private var content: some View {
        switch vm.status {
        case .idle:
            startButton(title: String(localized: "开始解读"), icon: "sparkles")
        case .error(let msg):
            VStack(alignment: .leading, spacing: 4) {
                startButton(title: String(localized: "重试解读"), icon: "arrow.clockwise")
                Text(msg).font(.caption2).foregroundColor(AppTheme.destructive).lineLimit(1)
            }
        case .planning:
            ProgressView()
            Text(vm.stageText.isEmpty ? String(localized: "通读全文…") : vm.stageText)
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("讲解中 · 第 \(block + 1)/\(total) 段")
                        .font(.subheadline.weight(.semibold))
                    if !vm.explanationText.isEmpty {
                        Text(vm.explanationText)
                            .font(.caption)
                            .foregroundColor(AppTheme.mutedForeground)
                            .lineLimit(1)
                    }
                }
            }
        case .completed:
            Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
            Text("解读完成").font(.subheadline.weight(.semibold))
            Spacer()
            Button { vm.replay() } label: {
                Label("重播", systemImage: "arrow.clockwise")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppTheme.primary)
            }
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
