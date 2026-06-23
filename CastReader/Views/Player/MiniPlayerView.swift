//
//  MiniPlayerView.swift
//  CastReader
//
//  迷你播放器：悬浮在 tab bar 上方，显示当前朗读/解读会话与状态（播放中/已暂停/已播完）。
//  点主体 → 展开完整阅读器；播放/暂停 → 驱动 AudioPlayerService；已播完 → 点播放从头重读；✕ → 关闭会话。
//

import SwiftUI

struct MiniPlayerView: View {
    @ObservedObject var coordinator: PlayerCoordinator

    var body: some View {
        if let session = coordinator.session {
            MiniPlayerBar(session: session, coordinator: coordinator)
                .id(session.id)   // 切会话 → 重建以重新订阅新会话的 VM
        }
    }
}

private struct MiniPlayerBar: View {
    let session: PlayerCoordinator.Session
    @ObservedObject var coordinator: PlayerCoordinator
    @ObservedObject private var audio = AudioPlayerService.shared
    @ObservedObject private var readVM: ReadAloudViewModel
    @ObservedObject private var explainVM: ExplainViewModel

    init(session: PlayerCoordinator.Session, coordinator: PlayerCoordinator) {
        self.session = session
        self.coordinator = coordinator
        _readVM = ObservedObject(wrappedValue: session.readVM)
        _explainVM = ObservedObject(wrappedValue: session.explainVM)
    }

    private var isExplain: Bool { coordinator.mode == .explain }

    private var isFinished: Bool {
        if isExplain { if case .completed = explainVM.status { return true }; return false }
        return readVM.isFinished
    }

    private var statusText: String {
        if isFinished { return String(localized: "已播完 · 点播放重读") }
        if audio.isPlaying { return isExplain ? String(localized: "解读中") : String(localized: "朗读中") }
        return String(localized: "已暂停")
    }

    private var playIcon: String {
        if isFinished { return "arrow.counterclockwise" }
        return audio.isPlaying ? "pause.fill" : "play.fill"
    }

    private func onPlayTap() {
        if isFinished {
            if isExplain { explainVM.replay() } else { readVM.start() }
        } else if isExplain {
            audio.togglePlayPause()        // 解读次数已在 start 计扣，暂停/恢复不涉及额度
        } else {
            readVM.togglePlayPause()       // 朗读按时长计 → 经 VM 补额度闸门，防暂停后绕过
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(session.document.title)
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
            .onTapGesture { coordinator.expand() }

            Button { onPlayTap() } label: {
                Image(systemName: playIcon)
                    .font(.system(size: 19))
                    .foregroundColor(AppTheme.foreground)
                    .frame(width: 34, height: 34)
            }
            Button { coordinator.close() } label: {
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

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.primary.opacity(0.15))
                .frame(width: 40, height: 40)
            Image(systemName: isExplain ? "sparkles" : "speaker.wave.2.fill")
                .font(.system(size: 17))
                .foregroundColor(AppTheme.primary)
        }
        .contentShape(Rectangle())
        .onTapGesture { coordinator.expand() }
    }
}
