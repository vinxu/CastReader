//
//  YouTubeExtractionOverlay.swift
//  CastReader
//

import SwiftUI

enum YouTubeExtractionPresentation: Identifiable, Equatable {
    case loading(YouTubeListenRequest)
    case failure(YouTubeListenRequest, YouTubeTranscriptFailure)

    var id: UUID {
        switch self {
        case .loading(let request), .failure(let request, _): return request.id
        }
    }

    var request: YouTubeListenRequest {
        switch self {
        case .loading(let request), .failure(let request, _): return request
        }
    }
}

/// Shown while an explicitly picked caption language is being fetched. Kept
/// separate from `YouTubeExtractionOverlay`: cancelling here returns to a
/// reader that is still playing, so it must not tear down the route request.
struct YouTubeCaptionLanguageSwitchOverlay: View {
    let targetLanguage: String
    let cancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
                Text(AppLocalized("正在切换字幕语言…"))
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(displayLanguage)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                Button(AppLocalized("取消"), role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(28)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .accessibilityIdentifier("youtubeCaptionLanguageSwitchOverlay")
    }

    private var displayLanguage: String {
        let locale = AppLanguageManager.shared.locale
        return locale.localizedString(forIdentifier: targetLanguage)
            ?? locale.localizedString(forLanguageCode: targetLanguage)
            ?? targetLanguage.uppercased()
    }
}

struct YouTubeExtractionOverlay: View {
    let presentation: YouTubeExtractionPresentation
    let cancel: () -> Void
    let retry: () -> Void

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            VStack(spacing: 22) {
                Spacer()
                skeleton
                stateContent
                Spacer()
            }
            .padding(24)
        }
        .accessibilityIdentifier("youtubeExtractionOverlay")
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: 12) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppTheme.surfaceVariant)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 42))
                        .foregroundStyle(AppTheme.primary.opacity(0.5))
                }
            RoundedRectangle(cornerRadius: 5)
                .fill(AppTheme.surfaceVariant)
                .frame(height: 18)
            RoundedRectangle(cornerRadius: 5)
                .fill(AppTheme.surfaceVariant)
                .frame(width: 190, height: 14)
            ForEach(0..<3, id: \.self) { index in
                HStack(alignment: .top, spacing: 10) {
                    Capsule()
                        .fill(AppTheme.primary.opacity(0.12))
                        .frame(width: 48, height: 24)
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppTheme.surfaceVariant)
                            .frame(height: 13)
                        RoundedRectangle(cornerRadius: 4)
                            .fill(AppTheme.surfaceVariant)
                            .frame(width: index == 1 ? 180 : 240, height: 13)
                    }
                }
            }
        }
        .padding(16)
        .background(AppTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch presentation {
        case .loading:
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                    .tint(AppTheme.primary)
                Text(AppLocalized("正在解析字幕…"))
                    .font(.headline)
                    .foregroundStyle(AppTheme.foreground)
                Text(AppLocalized("CastReader 不播放或保留 YouTube 视频和音频流；朗读声音由字幕文本生成。"))
                    .font(.caption)
                    .foregroundStyle(AppTheme.mutedForeground)
                    .multilineTextAlignment(.center)
                Button(AppLocalized("取消"), role: .cancel, action: cancel)
                    .buttonStyle(.bordered)
            }
        case .failure(_, let failure):
            VStack(spacing: 13) {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.orange)
                Text(failure.errorDescription ?? AppLocalized("字幕解析失败"))
                    .font(.headline)
                    .foregroundStyle(AppTheme.foreground)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    Button(AppLocalized("取消"), role: .cancel, action: cancel)
                        .buttonStyle(.bordered)
                    Button(AppLocalized("重试"), action: retry)
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.primary)
                        .accessibilityIdentifier("youtubeExtractionRetryButton")
                }
            }
        }
    }
}
