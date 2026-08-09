//
//  SystemIntegrationModels.swift
//  CastReader
//
//  Value types shared by the app, widgets and App Intents. Keep this file
//  independent from the main app's UI and document model targets.
//

import AppIntents
import Foundation

enum CastReaderSystemIntegration {
    static let appGroupIdentifier = "group.com.same.castreader"
}

/// A compact, extension-safe projection of one item in Home's Continue rail.
struct ContinueSnapshot: Codable, Equatable, Hashable, Sendable, Identifiable {
    let id: String
    let title: String
    let sourceKind: String
    let updatedAt: Date

    init(id: String, title: String, sourceKind: String, updatedAt: Date) {
        self.id = id
        self.title = title
        self.sourceKind = sourceKind
        self.updatedAt = updatedAt
    }
}

/// Reader destination selected by Siri, Shortcuts or a widget.
enum CastReaderIntentMode: String, AppEnum, Codable, CaseIterable, Sendable {
    case read
    case explain

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reading Mode"

    static let caseDisplayRepresentations: [CastReaderIntentMode: DisplayRepresentation] = [
        .read: "Read Aloud",
        .explain: "Explain"
    ]
}

/// Which system surface deposited the pending action.
///
/// Recorded alongside the action so a launch caused by Siri, a widget or a
/// deep link can be told apart from an ordinary icon tap in analytics. The
/// value carries no user content — only which door the session came through.
enum SystemActionOrigin: String, Codable, Sendable {
    /// Siri, Spotlight, Shortcuts or the Action Button ran an App Intent.
    case appIntent = "intent"
    /// A widget button or link ran the intent from the widget process.
    case widget
    /// A `castreader://` URL opened the app directly.
    case deepLink = "deep_link"

    /// Value written to `app_session_start.launchType`.
    var launchType: String { rawValue }
}

/// A one-shot command deposited by an extension and consumed by the app.
///
/// The value intentionally carries identifiers and raw input only. Resolving a
/// history item and presenting reader UI remain responsibilities of the app.
enum SystemAction: Codable, Equatable, Sendable {
    case read(input: String, mode: CastReaderIntentMode)
    case continueReading(itemID: String?, mode: CastReaderIntentMode)
    case openImport

    /// Decodes the public `castreader://` contract used by widgets and links.
    /// Unknown schemes/hosts and a read action without input are rejected.
    static func from(url: URL) -> SystemAction? {
        guard url.scheme?.lowercased() == "castreader",
              let host = url.host?.lowercased() else { return nil }

        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryValue(_ names: String...) -> String? {
            for name in names {
                guard let value = queryItems.first(where: {
                    $0.name.caseInsensitiveCompare(name) == .orderedSame
                })?.value else { continue }
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            return nil
        }

        func queryMode() -> CastReaderIntentMode {
            guard let rawMode = queryValue("mode")?.lowercased() else { return .read }
            return CastReaderIntentMode(rawValue: rawMode) ?? .read
        }

        switch host {
        case "import":
            return .openImport
        case "continue":
            return .continueReading(itemID: queryValue("item", "id"), mode: queryMode())
        case "read":
            guard let input = queryValue("input") else { return nil }
            return .read(input: input, mode: queryMode())
        default:
            return nil
        }
    }
}

struct ReadingItemEntity: AppEntity, Codable, Equatable, Hashable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Reading Item"
    static let defaultQuery = ReadingItemQuery()

    let id: String
    let title: String
    let sourceKind: String
    let updatedAt: Date

    init(snapshot: ContinueSnapshot) {
        id = snapshot.id
        title = snapshot.title
        sourceKind = snapshot.sourceKind
        updatedAt = snapshot.updatedAt
    }

    var displayRepresentation: DisplayRepresentation {
        // `sourceKind` is a persistence identifier (for example `web` or
        // `epub`), not user-facing copy. Keep the system result clean instead
        // of leaking an unlocalized implementation value into Siri/Shortcuts.
        DisplayRepresentation(title: "\(title)")
    }
}

struct ReadingItemQuery: EntityQuery {
    init() {}

    func entities(for identifiers: [ReadingItemEntity.ID]) async throws -> [ReadingItemEntity] {
        let entitiesByID = Dictionary(
            uniqueKeysWithValues: ContinueSnapshotStore.shared.snapshots().map {
                ($0.id, ReadingItemEntity(snapshot: $0))
            }
        )
        return identifiers.compactMap { entitiesByID[$0] }
    }

    func suggestedEntities() async throws -> [ReadingItemEntity] {
        ContinueSnapshotStore.shared.snapshots().map(ReadingItemEntity.init(snapshot:))
    }
}
