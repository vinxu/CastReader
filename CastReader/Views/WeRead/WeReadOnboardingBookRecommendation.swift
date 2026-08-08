//
//  WeReadOnboardingBookRecommendation.swift
//  CastReader
//
//  中国区首启引导的「先从这本开始」候选选择。
//  与 `KindleOnboardingBookRecommendation` 同形：系统先替用户选好一本，
//  用户只需要点「开始听这本」。
//

import Foundation

enum WeReadOnboardingBookRecommendation {

    /// 选中这本书的理由，用于书卡副标题与埋点。
    enum Reason: String {
        /// 有阅读进度锚点或最近打开过。
        case recent
        /// 书架里的第一本。
        case first
    }

    /// 从书架里挑一本作为首听。
    ///
    /// 排序依据（依次）：有听读锚点 > 最近打开过 > 有阅读进度 > 标题序。
    /// 与 Kindle 版保持同一套优先级，用户在两端看到的选书逻辑一致。
    static func choose(
        from books: [WeReadBook],
        hasListeningAnchor: (String) -> Bool = { _ in false }
    ) -> WeReadBook? {
        sorted(books, hasListeningAnchor: hasListeningAnchor).first
    }

    /// 候选列表。首选打不开时按顺序换下一本（引导里最多试 3 本）。
    static func candidates(
        from books: [WeReadBook],
        hasListeningAnchor: (String) -> Bool = { _ in false }
    ) -> [WeReadBook] {
        sorted(books, hasListeningAnchor: hasListeningAnchor)
    }

    static func reason(
        for book: WeReadBook,
        hasListeningAnchor: (String) -> Bool = { _ in false }
    ) -> Reason {
        if hasListeningAnchor(book.id) { return .recent }
        if book.lastOpenedAt != nil { return .recent }
        if !book.progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .recent
        }
        return .first
    }

    private static func sorted(
        _ books: [WeReadBook],
        hasListeningAnchor: (String) -> Bool
    ) -> [WeReadBook] {
        books
            .filter { !$0.effectiveReaderURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { lhs, rhs in
                let lhsAnchor = hasListeningAnchor(lhs.id)
                let rhsAnchor = hasListeningAnchor(rhs.id)
                if lhsAnchor != rhsAnchor { return lhsAnchor }

                let lhsOpened = lhs.lastOpenedAt
                let rhsOpened = rhs.lastOpenedAt
                if (lhsOpened != nil) != (rhsOpened != nil) { return lhsOpened != nil }
                if lhsOpened != rhsOpened {
                    return (lhsOpened ?? .distantPast) > (rhsOpened ?? .distantPast)
                }

                let lhsProgress = !lhs.progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                let rhsProgress = !rhs.progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if lhsProgress != rhsProgress { return lhsProgress }

                let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return lhs.id < rhs.id
            }
    }
}
