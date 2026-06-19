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

    /// 一次播放会话：一个文档配一对 VM。会话存活期间播放不断，跨阅读器开合、跨 Tab。
    struct Session: Identifiable {
        let id: String
        let document: ReadingDocument
        let readVM: ReadAloudViewModel
        let explainVM: ExplainViewModel
    }

    @Published private(set) var session: Session?
    @Published var mode: ReaderMode = .read
    @Published var isReaderPresented = false        // 完整阅读器是否展开（false = 收起为 Mini Player）

    /// 有活动会话且阅读器已收起 → Mini Player 显示。
    var showsMiniPlayer: Bool { session != nil && !isReaderPresented }

    /// 打开文档：新文档建会话（先停掉旧会话播放），同文档复用；展开完整阅读器；autoplay 时立即开播（剪贴板快捷入口用）。
    func open(_ document: ReadingDocument, mode: ReaderMode = .read, autoplay: Bool = false) {
        if session?.id != document.id {
            session?.readVM.stop()
            session?.explainVM.stop()
            session = Session(id: document.id,
                              document: document,
                              readVM: ReadAloudViewModel(document: document),
                              explainVM: ExplainViewModel(document: document))
        }
        self.mode = mode
        isReaderPresented = true
        HistoryStore.shared.record(document)   // 进文库历史（新增/置顶；纯本地、不上云）
        if autoplay, let s = session {
            if mode == .read { s.readVM.start() } else { s.explainVM.start() }
        }
    }

    /// 收起阅读器（不停播放）→ Mini Player 接管。
    func minimize() { isReaderPresented = false }

    /// 从 Mini Player 重新展开完整阅读器。
    func expand() { guard session != nil else { return }; isReaderPresented = true }

    /// 关闭会话（Mini Player 的 ✕）：停止播放并清空。
    func close() {
        session?.readVM.stop()
        session?.explainVM.stop()
        session = nil
        isReaderPresented = false
    }
}
