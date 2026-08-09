//
//  SystemIntegrationStores.swift
//  CastReader
//
//  App Group persistence shared by the app, widgets and App Intents.
//

import AppIntents
import Foundation

final class ContinueSnapshotStore: @unchecked Sendable {
    static let shared = ContinueSnapshotStore(
        sharedDefaults: UserDefaults(suiteName: CastReaderSystemIntegration.appGroupIdentifier)
    )

    private enum Storage {
        // v2 intentionally drops stale v1 snapshots after the cloud feature
        // was paused, so a widget cannot expose a remote item before the app
        // has launched and rebuilt the filtered projection.
        static let snapshotsKey = "systemIntegration.continueSnapshots.v2"
        static let maximumCount = 8

        // Keep the system surface aligned with HomeContinueContract without
        // importing the app-only ReadingSourceKind model into extension targets.
        static let excludedSourceKinds: Set<String> = [
            "kindle", "weread", "google_books", "kobo", "oreilly"
        ]
    }

    private let defaults: UserDefaults?
    private let lock = NSLock()

    /// Dependency-injection entry point for unit tests.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private init(sharedDefaults: UserDefaults?) {
        defaults = sharedDefaults
    }

    func snapshots() -> [ContinueSnapshot] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    func snapshot(id: String) -> ContinueSnapshot? {
        snapshots().first { $0.id == id }
    }

    /// Replaces the extension-safe Continue index as one deterministic value.
    /// Duplicate IDs keep their newest snapshot; ineligible Home sources are
    /// discarded and only the eight most recent entries are persisted.
    func replace(with snapshots: [ContinueSnapshot]) {
        var newestByID: [String: ContinueSnapshot] = [:]
        for snapshot in snapshots where Self.isEligible(snapshot) {
            let id = snapshot.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { continue }
            if let existing = newestByID[id], existing.updatedAt >= snapshot.updatedAt {
                continue
            }
            newestByID[id] = snapshot
        }

        let normalized = Array(newestByID.values.sorted(by: Self.isOrderedBefore).prefix(Storage.maximumCount))
        guard let data = try? JSONEncoder().encode(normalized) else { return }

        lock.lock()
        defaults?.set(data, forKey: Storage.snapshotsKey)
        lock.unlock()
    }

    private func loadLocked() -> [ContinueSnapshot] {
        guard let data = defaults?.data(forKey: Storage.snapshotsKey),
              let decoded = try? JSONDecoder().decode([ContinueSnapshot].self, from: data) else {
            return []
        }

        // Re-apply the contract while reading so a stale value written by an
        // older build cannot leak a connected-library item into Siri/widgets.
        return Array(
            decoded
                .filter(Self.isEligible)
                .sorted(by: Self.isOrderedBefore)
                .prefix(Storage.maximumCount)
        )
    }

    private static func isEligible(_ snapshot: ContinueSnapshot) -> Bool {
        let sourceKind = snapshot.sourceKind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return !Storage.excludedSourceKinds.contains(sourceKind)
    }

    private static func isOrderedBefore(_ lhs: ContinueSnapshot, _ rhs: ContinueSnapshot) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }
}

extension Notification.Name {
    /// In-process wake-up for an already running app. App/extension process
    /// boundaries are handled by consuming the App Group slot on scene active.
    static let castReaderSystemActionPending = Notification.Name(
        "com.same.castreader.systemActionPending"
    )
}

final class SystemActionStore: @unchecked Sendable {
    static let shared = SystemActionStore(
        sharedDefaults: UserDefaults(suiteName: CastReaderSystemIntegration.appGroupIdentifier)
    )

    private enum Storage {
        static let pendingActionKey = "systemIntegration.pendingAction.v1"
        static let pendingOriginKey = "systemIntegration.pendingActionOrigin.v1"
    }

    private let defaults: UserDefaults?
    private let lock = NSLock()

    /// Dependency-injection entry point for unit tests.
    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private init(sharedDefaults: UserDefaults?) {
        defaults = sharedDefaults
    }

    /// Stores one pending action. The slot is intentionally last-write-wins.
    @discardableResult
    func enqueue(_ action: SystemAction, origin: SystemActionOrigin = .appIntent) -> Bool {
        guard let data = try? JSONEncoder().encode(action) else { return false }

        lock.lock()
        guard let defaults else {
            lock.unlock()
            return false
        }
        defaults.set(data, forKey: Storage.pendingActionKey)
        defaults.set(origin.rawValue, forKey: Storage.pendingOriginKey)
        lock.unlock()

        NotificationCenter.default.post(name: .castReaderSystemActionPending, object: nil)
        return true
    }

    /// Non-destructive read of which surface deposited the pending action.
    ///
    /// An App Intent runs in its own process and only then launches the app, so
    /// by the time `startAppSession` runs the slot is already populated. Peeking
    /// must not consume it — routing the action is still MainTab's job.
    func peekPendingOrigin() -> SystemActionOrigin? {
        lock.lock()
        defer { lock.unlock() }
        guard let defaults,
              defaults.data(forKey: Storage.pendingActionKey) != nil,
              let raw = defaults.string(forKey: Storage.pendingOriginKey) else { return nil }
        return SystemActionOrigin(rawValue: raw)
    }

    /// Atomically claims the single pending slot within this process.
    /// Removal deliberately happens before decoding/returning, so corrupt data
    /// and re-entrant scene notifications cannot execute the action twice.
    func takePending() -> SystemAction? {
        lock.lock()
        guard let defaults else {
            lock.unlock()
            return nil
        }
        let data = defaults.data(forKey: Storage.pendingActionKey)
        defaults.removeObject(forKey: Storage.pendingActionKey)
        defaults.removeObject(forKey: Storage.pendingOriginKey)
        lock.unlock()

        guard let data else { return nil }
        return try? JSONDecoder().decode(SystemAction.self, from: data)
    }
}
