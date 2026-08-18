//
//  PlayerCoordinator.swift
//  CastReader
//
//  全局播放协调器：把「正在朗读/解读的会话」（文档 + 两个 VM）从阅读器模态的生命周期里抽出，
//  让阅读器收起后播放继续、Mini Player 接管；首页/文库/剪贴板等入口统一经 open(_:mode:) 进入。
//  挂在 MainTabView 级（@StateObject + environmentObject）。
//

import SwiftUI

/// One-shot gate used by WebView-backed readers whose paragraphs arrive after
/// `PlayerCoordinator.open`. A second explicit request remains meaningful after
/// the first one was consumed (for example, tapping Continue again while the
/// same article is paused).
struct DeferredAutoplayGate: Equatable {
    private(set) var isPending = false

    mutating func request(isReady: Bool) -> Bool {
        isPending = true
        return consumeIfReady(isReady)
    }

    mutating func contentBecameReady(isReady: Bool) -> Bool {
        consumeIfReady(isReady)
    }

    private mutating func consumeIfReady(_ isReady: Bool) -> Bool {
        guard isPending, isReady else { return false }
        isPending = false
        return true
    }
}

@MainActor
final class PlayerCoordinator: ObservableObject {
    private static let orientationOwner = "document-player"

    /// 一次播放会话：一个文档配一对 VM。会话存活期间播放不断，跨阅读器开合、跨 Tab。
    struct Session: Identifiable {
        /// Rendering/playback identity. Cloud revisions intentionally create a
        /// new session while retaining the stable remote document ID in
        /// `document.id` for History and playback metadata.
        let id: String
        let document: ReadingDocument
        let analyticsContext: AnalyticsContentContext
        let readVM: ReadAloudViewModel
        let explainVM: ExplainViewModel
    }

    @Published private(set) var session: Session?
    @Published var mode: ReaderMode = .read
    @Published var isReaderPresented = false        // 完整阅读器是否展开（false = 收起为 Mini Player）

    /// 有活动会话且阅读器已收起 → Mini Player 显示。
    var showsMiniPlayer: Bool { session != nil && !isReaderPresented }

    /// 打开文档：新文档建会话（先停掉旧会话播放），同文档复用；展开完整阅读器；autoplay 时立即开播（剪贴板快捷入口用）。
    /// scenario：从首页场景入口进入时的 content_type（注入 ExplainViewModel 驱动「划什么/怎么批」+ 深度预设）；nil = 通用。
    func open(
        _ document: ReadingDocument,
        mode: ReaderMode = .read,
        autoplay: Bool = false,
        scenario: String? = nil,
        analyticsContext suppliedAnalyticsContext: AnalyticsContentContext? = nil
    ) {
        KindlePlaybackCenter.shared.close()
        if document.sourceKind != .youtube {
            YouTubeTranscriptService.shared.releaseWarmSession()
        }

        if session?.id != document.contentSessionKey {
            session?.readVM.stop()
            session?.explainVM.stop()
            let analyticsContext: AnalyticsContentContext
            if let suppliedAnalyticsContext {
                analyticsContext = suppliedAnalyticsContext
            } else {
                let fallback = AnalyticsContentContext.fallback(for: document)
                analyticsContext = ProductAnalytics.shared.beginContentIntent(
                    source: fallback.source,
                    format: fallback.format,
                    entryPoint: fallback.entryPoint,
                    intendedMode: mode == .read ? "read" : "explain"
                )
            }
            ProductAnalytics.shared.contentReady(analyticsContext, document: document)
            let readVM = ReadAloudViewModel(
                document: document,
                analyticsContext: analyticsContext
            )
            let explainVM = ExplainViewModel(
                document: document,
                analyticsContext: analyticsContext
            )
            explainVM.scenario = scenario
            readVM.configurePlaybackMetadata(
                id: document.id,
                title: document.title,
                coverURL: document.coverURL
            )
            explainVM.configurePlaybackMetadata(
                id: document.id,
                title: document.title,
                coverURL: document.coverURL
            )
            if let resumeIndex = HistoryStore.shared.resumeParagraphIndex(for: document.id) {
                readVM.restoreReadingPosition(resumeIndex)
            }
            session = Session(id: document.contentSessionKey,
                              document: document,
                              analyticsContext: analyticsContext,
                              readVM: readVM,
                              explainVM: explainVM)
        } else if let scenario {
            session?.explainVM.scenario = scenario   // 同文档以场景重新进入：更新场景信号
        }
        session?.readVM.configurePlaybackMetadata(
            id: document.id,
            title: document.title,
            coverURL: document.coverURL
        )
        session?.explainVM.configurePlaybackMetadata(
            id: document.id,
            title: document.title,
            coverURL: document.coverURL
        )
        self.mode = mode
        updateOrientationForExpandedReader(document)
        isReaderPresented = true
        HistoryStore.shared.record(document)   // 进文库历史（新增/置顶；纯本地、不上云）
        if autoplay, let s = session {
            // web/docx/epub 源段落由 WebView 异步提取，autoplay 交给 WebReaderBridge.onRendered 段落就绪后按 mode 启动；
            // 此处立即 start 会用空段落请求后端（解读 HTTP 400 / 朗读无内容）。
            if document.sourceKind.isWebRendered {
                if mode == .read {
                    s.readVM.requestAutoplayWhenWebReady()
                } else {
                    s.explainVM.requestAutoplayWhenWebReady()
                }
            } else {
                if mode == .read { s.readVM.start() } else { s.explainVM.start() }
            }
        }
    }

    /// 收起阅读器（不停播放）→ Mini Player 接管。
    func minimize() {
        guard let document = session?.document else { return }
        if Self.isPortraitOnly(document.sourceKind) {
            // Portrait-only in both the full reader and the Mini Player: the
            // reader stays mounted off-screen, so releasing the lock here would
            // let a rotation reflow it behind the user's back.
            AppOrientationLock.lockPortrait(owner: Self.orientationOwner)
        } else {
            AppOrientationLock.lockCurrent(owner: Self.orientationOwner)
        }
        isReaderPresented = false
    }

    /// 从 Mini Player 重新展开完整阅读器。
    func expand() {
        guard let document = session?.document else { return }
        updateOrientationForExpandedReader(document)
        isReaderPresented = true
    }

    /// 关闭会话（Mini Player 的 ✕）：停止播放并清空。
    /// - Parameter releasingYouTubeWarmSession: pass `false` when this close is
    ///   only a step in swapping to another session for the *same* video — a
    ///   caption-language switch. The kept-alive document is exactly what makes
    ///   the next switch fast, so it must outlive that internal churn.
    func close(releasingYouTubeWarmSession: Bool = true) {
        // The YouTube extractor may be holding a hidden document alive so
        // caption-language switches stay fast. Nothing justifies that once the
        // reader it belonged to is gone.
        if releasingYouTubeWarmSession, session?.document.sourceKind == .youtube {
            YouTubeTranscriptService.shared.releaseWarmSession()
        }
        session?.readVM.stop()
        session?.explainVM.stop()
        session = nil
        isReaderPresented = false
        AppOrientationLock.unlock(owner: Self.orientationOwner)
    }

    private func updateOrientationForExpandedReader(_ document: ReadingDocument) {
        if Self.isPortraitOnly(document.sourceKind) {
            AppOrientationLock.lockPortrait(owner: Self.orientationOwner)
        } else {
            AppOrientationLock.unlock(owner: Self.orientationOwner)
        }
    }

    /// Sources whose reader is designed for one column only.
    ///
    /// The YouTube transcript reader stacks a 16:9 artwork header over a
    /// timestamped list; in landscape the artwork eats the viewport and the
    /// layout falls apart. WeRead is portrait-only for a different reason —
    /// rotating its live WebView reflows the page mid-playback.
    private static func isPortraitOnly(_ sourceKind: ReadingSourceKind) -> Bool {
        sourceKind == .weread || sourceKind == .youtube
    }
}
