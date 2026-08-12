//
//  YouTubeRouteCenter.swift
//  CastReader
//
//  One routing surface for Share Extension, clipboard, paste, sample, history
//  and castreader://youtube deep links. Extraction and presentation remain
//  owned by MainTabView, which also owns the global PlayerCoordinator.
//

import SwiftUI
import UIKit

enum YouTubeCacheProvider {
    static let shared: YouTubeCacheStore? = {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let root = base.appendingPathComponent(
            "YouTubeTranscriptCache",
            isDirectory: true
        )
        guard let store = try? YouTubeCacheStore(rootDirectory: root) else {
            return nil
        }
        // Exact byte accounting, orphan cleanup and pruning run once on the
        // cache actor after the first-listen window. Starting that recursive
        // walk immediately could place cache lookups behind it and delay a cold
        // share even though the filesystem work itself is off MainActor.
        Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 20_000_000_000)
            guard !Task.isCancelled else { return }
            try? await store.performStartupMaintenance()
        }
        return store
    }()
}

struct YouTubeListenRequest: Identifiable, Equatable {
    let id: UUID
    let rawURL: String
    let reference: YouTubeVideoReference
    let entry: YouTubeListenEntry
    let pendingItemID: UUID?

    init?(
        id: UUID = UUID(),
        rawURL: String,
        entry: YouTubeListenEntry,
        pendingItemID: UUID? = nil
    ) {
        guard let reference = YouTubeURLParser.parse(rawURL) else { return nil }
        self.id = id
        self.rawURL = rawURL
        self.reference = reference
        self.entry = entry
        self.pendingItemID = pendingItemID
    }
}

/// A durable Share Extension handoff is consumed only after the reader created
/// for that handoff reports audible playback. Manual and history routes never
/// enter this acknowledgement gate.
struct YouTubeDurablePlaybackAcceptance: Equatable {
    let request: YouTubeListenRequest
    let contentSessionKey: String

    init?(
        request: YouTubeListenRequest,
        contentSessionKey: String
    ) {
        guard request.entry == .share,
              request.pendingItemID != nil,
              !contentSessionKey.isEmpty else { return nil }
        self.request = request
        self.contentSessionKey = contentSessionKey
    }

    func matches(_ candidateSessionKey: String) -> Bool {
        candidateSessionKey == contentSessionKey
    }
}

@MainActor
final class YouTubeRouteCenter: ObservableObject {
    static let shared = YouTubeRouteCenter()

    @Published private(set) var request: YouTubeListenRequest?
    private var inFlightPendingItemID: UUID?

    private init() {}

    @discardableResult
    func open(
        _ rawURL: String,
        entry: YouTubeListenEntry,
        pendingItemID explicitPendingItemID: UUID? = nil
    ) -> Bool {
        guard let reference = YouTubeURLParser.parse(rawURL) else {
            return false
        }
        let pendingItemID = explicitPendingItemID ?? (
            entry == .share
                ? YouTubePendingLinkStore.matchingItemID(reference.canonicalURLString)
                : nil
        )
        if let pendingItemID, inFlightPendingItemID == pendingItemID {
            return true
        }
        if pendingItemID != nil, inFlightPendingItemID != nil {
            // Another durable share is already being handled. The new item
            // stays queued and will be routed on a later foreground pass.
            return true
        }
        if pendingItemID == nil, inFlightPendingItemID != nil {
            // A new explicit paste/sample/scheme route supersedes the current
            // extraction. Release only the in-memory claim; the durable share
            // remains queued and can be retried after this request or restart.
            inFlightPendingItemID = nil
        }
        guard let request = YouTubeListenRequest(
            rawURL: rawURL,
            entry: entry,
            pendingItemID: pendingItemID
        ) else { return false }
        if let pendingItemID {
            inFlightPendingItemID = pendingItemID
        }
        self.request = request
        return true
    }

    func consume(_ id: UUID) {
        guard request?.id == id else { return }
        request = nil
    }

    func acknowledge(_ completedRequest: YouTubeListenRequest) {
        guard let pendingItemID = completedRequest.pendingItemID else { return }
        YouTubePendingLinkStore.acknowledge(pendingItemID)
        if inFlightPendingItemID == pendingItemID {
            inFlightPendingItemID = nil
        }
    }


    func releaseWithoutAcknowledgement(
        _ interruptedRequest: YouTubeListenRequest
    ) {
        guard let pendingItemID = interruptedRequest.pendingItemID,
              inFlightPendingItemID == pendingItemID else { return }
        inFlightPendingItemID = nil
    }
}

enum YouTubeReadingDocumentBuilder {
    static func firstPlayableParagraph(
        in transcript: YouTubeTranscriptDocument
    ) -> Int? {
        transcript.paragraphs.first(where: isPlayable)?.id
    }

    static func playableParagraph(
        in transcript: YouTubeTranscriptDocument,
        atOrAfter paragraphID: Int
    ) -> Int? {
        guard let start = transcript.paragraphs.firstIndex(where: {
            $0.id == paragraphID
        }) else {
            return firstPlayableParagraph(in: transcript)
        }
        if let following = transcript.paragraphs[start...].first(where: isPlayable) {
            return following.id
        }
        return transcript.paragraphs[..<start].last(where: isPlayable)?.id
    }

    static func make(
        transcript: YouTubeTranscriptDocument,
        cacheHit: Bool
    ) -> ReadingDocument {
        let metadata = transcript.metadata
        let cacheKey = YouTubeCacheStore.cacheKey(for: transcript)
        let language = YouTubeTranscriptLanguagePolicy.documentLanguage(
            for: transcript.track.languageCode
        )
        let paragraphs = transcript.paragraphs.map {
            ReadingParagraph(id: $0.id, text: $0.text, startMs: $0.startMs)
        }
        return ReadingDocument(
            id: "youtube-\(metadata.videoId)",
            title: metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? AppLocalized("YouTube 字幕稿")
                : metadata.title,
            sourceKind: .youtube,
            language: language,
            paragraphs: paragraphs,
            sourceURL: metadata.sourceURL,
            coverURL: metadata.thumbnailURL,
            // Cache identity also includes selected language and track
            // identity. Two tracks can legitimately contain byte-identical
            // cues; they must still create different reader sessions.
            contentSessionKey: "youtube-\(cacheKey.storageKey)",
            youtubeTranscript: transcript,
            youtubeCacheHit: cacheHit,
            createdAt: transcript.extractedAt
        )
    }

    static func startingParagraph(
        in transcript: YouTubeTranscriptDocument,
        startSeconds: Int?
    ) -> Int {
        guard !transcript.paragraphs.isEmpty else { return 0 }
        guard let startSeconds else {
            return firstPlayableParagraph(in: transcript)
                ?? transcript.paragraphs.first?.id
                ?? 0
        }
        let seconds = max(0, startSeconds)
        let multiplied = seconds.multipliedReportingOverflow(by: 1_000)
        let targetMs = multiplied.overflow ? Int.max : multiplied.partialValue
        let timelineParagraph = transcript.paragraphs.last(where: {
            $0.startMs <= targetMs
        })?.id
            ?? transcript.paragraphs.first?.id
            ?? 0
        return playableParagraph(
            in: transcript,
            atOrAfter: timelineParagraph
        ) ?? timelineParagraph
    }

    /// A naturally completed paragraph resumes at the following paragraph.
    /// Completing the final paragraph makes the next open start from the
    /// beginning, while the persisted 100% value can still be shown in history.
    static func resumingParagraph(
        in transcript: YouTubeTranscriptDocument,
        progress: YouTubePlaybackProgress
    ) -> Int? {
        guard let position = transcript.paragraphs.firstIndex(
            where: { $0.id == progress.paragraphIndex }
        ) else { return nil }
        guard progress.resolvedParagraphFractionalProgress >= 0.999 else {
            return playableParagraph(
                in: transcript,
                atOrAfter: transcript.paragraphs[position].id
            )
        }
        let next = transcript.paragraphs.index(after: position)
        if next < transcript.paragraphs.endIndex,
           let following = transcript.paragraphs[next...].first(where: isPlayable) {
            return following.id
        }
        return firstPlayableParagraph(in: transcript)
    }

    private static func isPlayable(_ paragraph: YouTubeTranscriptParagraph) -> Bool {
        SpeechTextSanitizer.containsSpeakableContent(paragraph.text)
    }
}

@MainActor
enum YouTubeLinkOpener {
    static func open(videoId: String, startMs: Int) {
        guard let webURL = webURL(videoId: videoId, startMs: startMs) else { return }
        let application = applicationURL(videoId: videoId, startMs: startMs)
        guard let application,
              UIApplication.shared.canOpenURL(application) else {
            UIApplication.shared.open(webURL, options: [:])
            return
        }
        UIApplication.shared.open(application, options: [:]) { openedApplication in
            guard !openedApplication else { return }
            UIApplication.shared.open(webURL, options: [:])
        }
    }

    nonisolated static func applicationURL(videoId: String, startMs: Int) -> URL? {
        makeURL(
            scheme: "youtube",
            host: "www.youtube.com",
            videoId: videoId,
            startMs: startMs
        )
    }

    nonisolated static func webURL(videoId: String, startMs: Int) -> URL? {
        makeURL(
            scheme: "https",
            host: "www.youtube.com",
            videoId: videoId,
            startMs: startMs
        )
    }

    nonisolated private static func makeURL(
        scheme: String,
        host: String,
        videoId: String,
        startMs: Int
    ) -> URL? {
        guard YouTubeURLParser.parse(
            "https://www.youtube.com/watch?v=\(videoId)"
        ) != nil else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/watch"
        components.queryItems = [
            URLQueryItem(name: "v", value: videoId),
            URLQueryItem(name: "t", value: "\(max(0, startMs / 1_000))s"),
        ]
        return components.url
    }
}

extension YouTubeTranscriptFailure: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return AppLocalized("这不是有效的 YouTube 视频链接")
        case .noCaptions:
            return AppLocalized("这个视频没有字幕，无法朗读")
        case .live:
            return AppLocalized("暂不支持直播视频")
        case .restricted:
            return AppLocalized("该视频需要登录 YouTube 查看，无法解析")
        case .unavailable:
            return AppLocalized("该视频不可用")
        case .timeout:
            return AppLocalized("解析超时，请重试")
        case .cancelled:
            return AppLocalized("已取消解析")
        case .unsupportedLanguage:
            return AppLocalized("这个字幕语言暂不支持朗读")
        case .malformedResponse:
            return AppLocalized("字幕格式暂时无法读取，请重试")
        case .captionAccess:
            return AppLocalized("已检测到字幕，但暂时无法读取，请重试")
        case .playerBootstrapFailed:
            return AppLocalized("YouTube 播放器未能初始化或暂时限制了字幕访问，请重试或在 YouTube 中打开视频")
        case .youtubeAccessLimited:
            return AppLocalized("YouTube 暂时限制了字幕访问，视频本身可能仍可正常观看；请稍后重试或在 YouTube 中打开")
        case .trackUnavailable:
            return AppLocalized("这个语言的字幕暂时读不到，已保留当前语言")
        case .network:
            return AppLocalized("网络连接失败，请重试")
        }
    }
}
