//
//  PlayerCoordinator.swift
//  CastReader
//
//  全局播放协调器：把「正在朗读/解读的会话」（文档 + 两个 VM）从阅读器模态的生命周期里抽出，
//  让阅读器收起后播放继续、Mini Player 接管；首页/文库/剪贴板等入口统一经 open(_:mode:) 进入。
//  挂在 MainTabView 级（@StateObject + environmentObject）。
//

import SwiftUI

@MainActor
final class PlayerCoordinator: ObservableObject {
    private static let orientationOwner = "document-player"

    /// 一次播放会话：一个文档配一对 VM。会话存活期间播放不断，跨阅读器开合、跨 Tab。
    struct Session: Identifiable {
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

        if session?.id != document.id {
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
            let explainVM = ExplainViewModel(document: document, analyticsContext: analyticsContext)
            explainVM.scenario = scenario
            session = Session(id: document.id,
                              document: document,
                              analyticsContext: analyticsContext,
                              readVM: ReadAloudViewModel(document: document, analyticsContext: analyticsContext),
                              explainVM: explainVM)
        } else if let scenario {
            session?.explainVM.scenario = scenario   // 同文档以场景重新进入：更新场景信号
        }
        self.mode = mode
        updateOrientationForExpandedReader(document)
        isReaderPresented = true
        HistoryStore.shared.record(document)   // 进文库历史（新增/置顶；纯本地、不上云）
        if autoplay, let s = session {
            // web/docx/epub 源段落由 WebView 异步提取，autoplay 交给 WebReaderBridge.onRendered 段落就绪后按 mode 启动；
            // 此处立即 start 会用空段落请求后端（解读 HTTP 400 / 朗读无内容）。
            if !document.sourceKind.isWebRendered {
                if mode == .read { s.readVM.start() } else { s.explainVM.start() }
            }
        }
    }

    /// 收起阅读器（不停播放）→ Mini Player 接管。
    func minimize() {
        guard let document = session?.document else { return }
        if document.sourceKind == .weread {
            // WeRead is portrait-only in both full reader and Mini Player.
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
    func close() {
        session?.readVM.stop()
        session?.explainVM.stop()
        session = nil
        isReaderPresented = false
        AppOrientationLock.unlock(owner: Self.orientationOwner)
    }

    private func updateOrientationForExpandedReader(_ document: ReadingDocument) {
        if document.sourceKind == .weread {
            AppOrientationLock.lockPortrait(owner: Self.orientationOwner)
        } else {
            AppOrientationLock.unlock(owner: Self.orientationOwner)
        }
    }
}
