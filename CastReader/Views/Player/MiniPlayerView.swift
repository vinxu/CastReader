//
//  MiniPlayerView.swift
//  CastReader
//
//  迷你播放器：悬浮在 tab bar 上方，显示当前朗读/解读会话与状态（播放中/已暂停/已播完）。
//  点主体 → 展开完整阅读器；播放/暂停 → 驱动 AudioPlayerService；已播完 → 点播放从头重读；✕ → 关闭会话。
//

import SwiftUI
import UIKit

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
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var voiceSwitch = VoiceSwitchStatusCenter.shared
    @State private var cover: UIImage?

    init(session: PlayerCoordinator.Session, coordinator: PlayerCoordinator) {
        self.session = session
        self.coordinator = coordinator
        _readVM = ObservedObject(wrappedValue: session.readVM)
        _explainVM = ObservedObject(wrappedValue: session.explainVM)
    }

    private var isExplain: Bool { coordinator.mode == .explain }

    private var isFinished: Bool {
        if isExplain {
            if case .completed = explainVM.status {
                return !explainVM.isContinuingLivePage
            }
            return false
        }
        return readVM.isFinished
    }

    private var statusText: String {
        if let progress = voiceSwitch.progress { return progress.localizedMessage }
        if isExplain, explainVM.isContinuingLivePage { return AppLocalized("继续讲解…") }
        if isFinished { return AppLocalized("已播完 · 点播放重读") }
        if audio.isPlaying { return isExplain ? AppLocalized("解读中") : AppLocalized("朗读中") }
        return AppLocalized("已暂停")
    }

    private var playIcon: String {
        if isFinished { return "arrow.counterclockwise" }
        return audio.isPlaying ? "pause.fill" : "play.fill"
    }

    private func onPlayTap() {
        if isFinished {
            if isExplain { explainVM.replay() } else { readVM.start() }
        } else if isExplain {
            explainVM.togglePlayPause()    // VM validates/rebuilds its owned queue after a mode handoff
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

            if isExplain {
                PlaybackVoiceButton(language: explainVM.playbackLanguage, size: 34)
            } else if readVM.hasStartedPlayback {
                PlaybackVoiceButton(language: readVM.playbackLanguage, size: 34)
            }

            Button { onPlayTap() } label: {
                Group {
                    if voiceSwitch.progress != nil {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: playIcon)
                            .font(.system(size: 19))
                            .foregroundColor(AppTheme.foreground)
                    }
                }
                .frame(width: 34, height: 34)
            }
            .disabled(voiceSwitch.progress != nil || (isExplain && explainVM.isContinuingLivePage))
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

    private var playbackCoverID: String { audio.currentBookId ?? session.id }

    /// 封面 key：随当前播放书籍、远程封面、本地封面落地变化触发重载。
    private var coverKey: String {
        let local = history.records.first(where: { $0.id == playbackCoverID })?.coverPath
            ?? history.records.first(where: { $0.id == session.id })?.coverPath
            ?? ""
        return "\(playbackCoverID)|\(local)|\(audio.currentCoverUrl ?? "")"
    }

    private func loadCover() async -> UIImage? {
        let id = playbackCoverID
        if let image = await Task.detached(operation: { AudioPlayerService.localCoverImage(forID: id) }).value {
            return image
        }
        guard let raw = audio.currentCoverUrl?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if let cached = ImageCache.shared.get(raw) {
            return cached
        }
        let url = URL(string: raw)
            ?? raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
        guard let url else { return nil }
        guard let data = try? await URLSession.shared.data(from: url).0 else { return nil }
        guard let image = UIImage(data: data) else { return nil }
        ImageCache.shared.set(raw, image: image, data: data)
        return image
    }

    private var icon: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(AppTheme.primary.opacity(0.15))
                .frame(width: 40, height: 40)
            if let cover {
                Image(uiImage: cover).resizable().scaledToFill()
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: isExplain ? "sparkles" : "speaker.wave.2.fill")
                    .font(.system(size: 17))
                    .foregroundColor(AppTheme.primary)
            }
        }
        .frame(width: 40, height: 40)
        .contentShape(Rectangle())
        .onTapGesture { coordinator.expand() }
        .task(id: coverKey) {
            cover = await loadCover()
        }
    }
}
