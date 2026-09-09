import Foundation

/// Stored with the locator in the same atomic checkpoint. These fields do not
/// participate in source/audio matching and are optional for existing records.
struct ReadingProgressActivity: Codable, Equatable {
    var listenedSeconds: Double = 0
    var lastListenedAt: Date
    var completedAt: Date? = nil
    var revision: Int = 0
    var isValid: Bool {
        listenedSeconds.isFinite && listenedSeconds >= 0 && revision >= 0
            && lastListenedAt.timeIntervalSince1970.isFinite
            && (completedAt?.timeIntervalSince1970.isFinite ?? true)
    }
}

enum ContentListeningState: String, CaseIterable {
    case unstarted, inProgress, completed

    var label: String {
        switch self {
        case .unstarted: AppLocalized("尚未开始")
        case .inProgress: AppLocalized("进行中")
        case .completed: AppLocalized("已完成")
        }
    }
}

enum ContentAvailability: Equatable {
    case local, requiresValidation, missingResource, connectionRequired

    var permitsReminder: Bool { self == .local || self == .requiresValidation }
}

struct ContentCatalogItem: Identifiable {
    let record: HistoryRecord
    let checkpoint: ReadingResumeCheckpoint?
    let availability: ContentAvailability
    var id: String { record.id }
    var state: ContentListeningState {
        if checkpoint?.activity?.completedAt != nil { return .completed }
        return checkpoint != nil || record.lastParagraphIndex != nil ? .inProgress : .unstarted
    }
    var lastListenedAt: Date? { checkpoint.map { $0.activity?.lastListenedAt ?? $0.updatedAt } }
    var canContinue: Bool { record.archivedAt == nil && state == .inProgress }
    var positionLabel: String {
        if availability == .missingResource { return AppLocalized("进度已保留，请重新导入原文件") }
        if availability == .connectionRequired { return AppLocalized("进度已保留，请重新连接书架") }
        if state == .completed { return state.label }
        guard let checkpoint else {
            if let paragraph = record.lastParagraphIndex {
                return String(format: AppLocalized("上次听到第 %d 段"), paragraph + 1)
            }
            return AppLocalized("尚未开始")
        }
        // A provider page is not the whole book; do not publish its local
        // paragraph index as a chapter or a global percentage.
        if record.sourceKind.isLiveWebLibrary || record.sourceKind == .kindle {
            return AppLocalized("上次收听位置已保存")
        }
        return String(format: AppLocalized("上次听到第 %d 段"), checkpoint.paragraphIndex + 1)
    }
}

/// One repository over the existing account-scoped, per-content checkpoint.
/// No second locator database or independent list/notification progress exists.
@MainActor
struct ContentProgressRepository {
    let history: HistoryStore

    func latest(for itemID: String) -> ReadingResumeCheckpoint? {
        history.latestReadingCheckpoint(for: itemID)
    }

    @discardableResult
    func markCompleted(_ completed: Bool, itemID: String) -> Bool {
        history.setReadingCompleted(completed, for: itemID)
    }
}

/// History is the local catalog's persistence adapter. Provider shelves remain
/// provider-owned; an imported/opened item is registered once under its old ID.
@MainActor
struct ContentCatalog {
    let history: HistoryStore

    var items: [ContentCatalogItem] {
        history.visibleRecords.map { record in
            ContentCatalogItem(record: record,
                checkpoint: ContentProgressRepository(history: history).latest(for: record.id),
                availability: availability(for: record))
        }
    }

    var continuing: [ContentCatalogItem] {
        items.filter(\.canContinue).sorted {
            let lhs = $0.lastListenedAt ?? .distantPast, rhs = $1.lastListenedAt ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
    }

    func item(id: String) -> ContentCatalogItem? {
        guard let record = history.visibleRecords.first(where: { $0.id == id }) else { return nil }
        return ContentCatalogItem(record: record, checkpoint: history.latestReadingCheckpoint(for: id),
            availability: availability(for: record))
    }

    private func availability(for record: HistoryRecord) -> ContentAvailability {
        if record.requiresRemoteReopen { return .requiresValidation }
        switch record.sourceKind {
        case .kindle:
            return KindleLibraryStore.shared.needsConnection ? .connectionRequired : .requiresValidation
        case .weread:
            return WeReadLibraryStore.shared.needsConnection ? .connectionRequired : .requiresValidation
        case .googleBooks:
            return GoogleBooksLibraryStore.shared.needsConnection ? .connectionRequired : .requiresValidation
        case .kobo:
            return KoboLibraryStore.shared.needsConnection ? .connectionRequired : .requiresValidation
        case .oreilly:
            return OReillyLibraryStore.shared.needsConnection ? .connectionRequired : .requiresValidation
        case .web, .youtube: return .requiresValidation
        default: return history.hasLocalResource(for: record.id) ? .local : .missingResource
        }
    }
}
