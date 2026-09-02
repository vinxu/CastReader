//
//  OfflineReadingCacheStore.swift
//  CastReader
//
//  Account-scoped, integrity-checked offline reading packages. Kindle is the
//  first producer, while the package/manifest boundary is intentionally
//  provider-neutral so the other readers can adopt it without another cache.
//

import CoreGraphics
import CryptoKit
import Foundation

extension Notification.Name {
    static let offlineReadingCacheDidChange = Notification.Name(
        "CastReader.OfflineReadingCacheDidChange"
    )
}

protocol OfflineReadingCacheClock: Sendable {
    func now() -> Date
}

struct SystemOfflineReadingCacheClock: OfflineReadingCacheClock {
    func now() -> Date { Date() }
}

struct OfflineReadingCacheLimits: Equatable, Sendable {
    static let production = OfflineReadingCacheLimits(
        maxBookCount: 20,
        maxBytes: 2 * 1024 * 1024 * 1024
    )

    let maxBookCount: Int
    let maxBytes: Int64
}

enum OfflineReadingProvider: String, Codable, Equatable, Sendable {
    case kindle
}

struct OfflineReadingCacheSummary: Equatable, Sendable {
    /// Opaque SHA-256 key. It is safe to use for diagnostics and filesystem
    /// lookup; it cannot reveal an ASIN, title or account identifier.
    let cacheKey: String
    let provider: OfflineReadingProvider
    let pageCount: Int
    let paragraphCount: Int
    let readableParagraphCount: Int
    let audioSegmentCount: Int
    let byteSize: Int64
    let voiceID: String
    let createdAt: Date
    let updatedAt: Date
    let lastAccessAt: Date
}

struct OfflineReadingPackage {
    let document: ReadingDocument
    let pageKeys: [String]
    let segmentsByParagraph: [Int: [AudioSegment]]
    let summary: OfflineReadingCacheSummary
}

enum OfflineReadingCacheError: Error, Equatable, LocalizedError {
    case invalidLimits
    case invalidBookIdentity
    case invalidDocument(String)
    case invalidPageKeys
    case incompleteAudio(paragraphIndex: Int?)
    case packageTooLarge(actualBytes: Int64, maximumBytes: Int64)
    case corruptPackage
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .invalidLimits:
            return "Offline cache limits must be greater than zero."
        case .invalidBookIdentity:
            return "The book does not have a stable Kindle identity."
        case let .invalidDocument(reason):
            return "The Kindle document is incomplete: \(reason)"
        case .invalidPageKeys:
            return "The Kindle page keys do not exactly match the cached pages."
        case let .incompleteAudio(paragraphIndex):
            if let paragraphIndex {
                return "Offline audio is incomplete for paragraph \(paragraphIndex)."
            }
            return "Offline audio does not cover every readable paragraph."
        case let .packageTooLarge(actualBytes, maximumBytes):
            return "The offline package is \(actualBytes) bytes, above the \(maximumBytes)-byte limit."
        case .corruptPackage:
            return "The offline package failed its integrity check."
        case let .ioFailure(message):
            return "Offline cache I/O failed: \(message)"
        }
    }
}

/// Internal deterministic failure points keep crash-recovery behavior covered
/// without making production code depend on a mock FileManager subclass.
enum OfflineReadingCacheManifestWriteReason: Equatable, Sendable {
    case accessTouch
    case publish
    case remove
    case recovery
    case corruptionCleanup
}

enum OfflineReadingCacheFaultPoint: Equatable, Sendable {
    case beforeManifestWrite(OfflineReadingCacheManifestWriteReason)
    case beforePublish
    case afterPreviousMoved
    case afterCandidateInstalled
    case afterManifestCommitted
    case beforeEntryRemoval(String)
}

enum OfflineReadingCacheInjectedFailure: Error, Sendable {
    case io
    /// The store deliberately leaves the journal in place so reopening the
    /// actor exercises the same state produced by process termination.
    case simulatedCrash
}

typealias OfflineReadingCacheFaultHandler = @Sendable (
    OfflineReadingCacheFaultPoint
) throws -> Void

/// A one-way, thread-safe authorization lease for the final cache publication.
///
/// The entitlement owner revokes this lease synchronously when Pro access is
/// lost. `OfflineReadingCacheStore` holds the same lock while it performs the
/// final cancellation/lease check and atomically writes the manifest, giving
/// revoke and commit an explicit linearization order:
///
/// - revoke wins the lock: publication throws `CancellationError` and the
///   journal restores the previous package;
/// - commit wins the lock: the manifest becomes durable before revoke returns.
///
/// Staging and validation intentionally happen outside this lock so an
/// entitlement update is never blocked by image/audio I/O.
final class OfflineReadingCachePublishLease: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false

    init() {}

    func revoke() {
        lock.lock()
        revoked = true
        lock.unlock()
    }

    fileprivate func commitIfValid<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !revoked else { throw CancellationError() }
        try Task.checkCancellation()
        return try body()
    }
}

/// The account boundary intentionally comes from AccountContentScopeBridge:
/// it contains only the already-hashed storage ID shared by the app processes.
/// A raw account ID is never accepted by this provider or written to a manifest.
enum OfflineReadingCacheProvider {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var storageID: String?
        var store: OfflineReadingCacheStore?
    }

    private static let state = State()

    /// Resolves the active account lazily, which keeps this service independent
    /// from AuthService's account-switch transaction. A scope change returns a
    /// different actor before any caller can observe the prior account's store.
    static var shared: OfflineReadingCacheStore? {
        let storageID: String?
        #if DEBUG
        if AccountContentScopeBridge.usesLegacyTestingStorage {
            storageID = "debug-legacy"
        } else {
            storageID = AccountContentScopeBridge.activeStorageID
        }
        #else
        storageID = AccountContentScopeBridge.activeStorageID
        #endif

        guard let storageID else {
            deactivateAccountScope()
            return nil
        }

        state.lock.lock()
        if state.storageID == storageID, let store = state.store {
            state.lock.unlock()
            return store
        }
        state.lock.unlock()

        guard let root = accountCacheDirectory(storageID: storageID),
              let store = try? OfflineReadingCacheStore(rootDirectory: root) else {
            deactivateAccountScope()
            return nil
        }

        state.lock.lock()
        state.storageID = storageID
        state.store = store
        state.lock.unlock()
        return store
    }

    @discardableResult
    static func activateAccountScope(storageID: String) -> Bool {
        guard let root = accountCacheDirectory(storageID: storageID),
              let store = try? OfflineReadingCacheStore(rootDirectory: root) else {
            deactivateAccountScope()
            return false
        }
        state.lock.lock()
        state.storageID = storageID
        state.store = store
        state.lock.unlock()
        return true
    }

    static func deactivateAccountScope() {
        state.lock.lock()
        state.storageID = nil
        state.store = nil
        state.lock.unlock()
    }

    static func accountCacheDirectory(storageID: String) -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return accountCacheDirectory(
            applicationSupportRoot: applicationSupport,
            storageID: storageID
        )
    }

    static func accountCacheDirectory(
        applicationSupportRoot: URL,
        storageID: String
    ) -> URL? {
        let isProductionID = OfflineReadingCacheDigest.isDigest(storageID.lowercased())
        #if DEBUG
        let isAllowed = isProductionID || storageID == "debug-legacy"
        #else
        let isAllowed = isProductionID
        #endif
        guard isAllowed else { return nil }
        return applicationSupportRoot
            .appendingPathComponent("AccountData", isDirectory: true)
            .appendingPathComponent(storageID.lowercased(), isDirectory: true)
            .appendingPathComponent("OfflineReadingCache", isDirectory: true)
    }
}

actor OfflineReadingCacheStore {
    private static let packageSchemaVersion = 1
    private static let manifestFilename = "manifest.json"
    private static let entriesDirectoryName = "entries"
    private static let stagingDirectoryName = ".staging"
    private static let resourcesDirectoryName = "resources"
    private static let transactionJournalFilename = "journal.json"
    private static let transactionCandidateDirectoryName = "candidate"
    private static let transactionPreviousDirectoryName = "previous"

    private let rootDirectory: URL
    private let entriesDirectory: URL
    private let stagingDirectory: URL
    private let limits: OfflineReadingCacheLimits
    private let clock: any OfflineReadingCacheClock
    private let fileManager: FileManager
    private let faultHandler: OfflineReadingCacheFaultHandler
    private var manifest: OfflineReadingCacheManifest

    init(
        rootDirectory: URL,
        limits: OfflineReadingCacheLimits = .production,
        clock: any OfflineReadingCacheClock = SystemOfflineReadingCacheClock(),
        fileManager: FileManager = .default,
        faultHandler: @escaping OfflineReadingCacheFaultHandler = { _ in }
    ) throws {
        guard limits.maxBookCount > 0, limits.maxBytes > 0 else {
            throw OfflineReadingCacheError.invalidLimits
        }
        self.rootDirectory = rootDirectory
        entriesDirectory = rootDirectory.appendingPathComponent(
            Self.entriesDirectoryName,
            isDirectory: true
        )
        stagingDirectory = rootDirectory.appendingPathComponent(
            Self.stagingDirectoryName,
            isDirectory: true
        )
        self.limits = limits
        self.clock = clock
        self.fileManager = fileManager
        self.faultHandler = faultHandler
        manifest = OfflineReadingCacheManifest()

        do {
            try fileManager.createDirectory(
                at: rootDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: entriesDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.createDirectory(
                at: stagingDirectory,
                withIntermediateDirectories: true
            )
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableRoot = rootDirectory
            try mutableRoot.setResourceValues(resourceValues)
            let protection: [FileAttributeKey: Any] = [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
            try fileManager.setAttributes(protection, ofItemAtPath: rootDirectory.path)
            try fileManager.setAttributes(protection, ofItemAtPath: entriesDirectory.path)
            try fileManager.setAttributes(protection, ofItemAtPath: stagingDirectory.path)
            let manifestURL = rootDirectory.appendingPathComponent(Self.manifestFilename)
            var manifestWasReset = false
            var recoveredManifest: OfflineReadingCacheManifest
            do {
                recoveredManifest = try Self.readManifest(
                    at: manifestURL,
                    fileManager: fileManager
                )
            } catch OfflineReadingCacheError.corruptPackage {
                // A corrupt manifest cannot safely claim any package bytes.
                // Start from an empty commit record; journal recovery below can
                // still restore a known previous version, and reconciliation
                // removes every remaining privacy-sensitive orphan.
                recoveredManifest = OfflineReadingCacheManifest()
                manifestWasReset = true
            }
            let didRecoverTransactions = try Self.recoverTransactions(
                entriesDirectory: entriesDirectory,
                stagingDirectory: stagingDirectory,
                manifest: &recoveredManifest,
                fileManager: fileManager
            )
            let didReconcileEntries = try Self.reconcileEntries(
                entriesDirectory: entriesDirectory,
                manifest: &recoveredManifest,
                fileManager: fileManager
            )
            if manifestWasReset || didRecoverTransactions || didReconcileEntries {
                try faultHandler(.beforeManifestWrite(.recovery))
                try Self.writeManifest(
                    recoveredManifest,
                    at: manifestURL
                )
            }
            if didRecoverTransactions {
                // Journal removal happens only after the recovered manifest is
                // durable, so another crash can replay the same transaction.
                try Self.purgeStagingDirectory(
                    stagingDirectory,
                    fileManager: fileManager
                )
            }
            manifest = recoveredManifest
        } catch let error as OfflineReadingCacheError {
            throw error
        } catch {
            throw OfflineReadingCacheError.ioFailure(error.localizedDescription)
        }
    }

    static func cacheKey(forKindleBook book: KindleBook) -> String? {
        let storefront = book.storefrontID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let asin = book.asin?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let fallbackID = book.id
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let stableBookID = asin.isEmpty ? fallbackID : asin
        guard !stableBookID.isEmpty else { return nil }
        return OfflineReadingCacheDigest.sha256([
            OfflineReadingProvider.kindle.rawValue,
            storefront,
            stableBookID,
        ])
    }

    @discardableResult
    func saveKindlePackage(
        book: KindleBook,
        document: ReadingDocument,
        pageKeys: [String],
        voiceID: String,
        segmentsByParagraph: [Int: [AudioSegment]],
        publishLease: OfflineReadingCachePublishLease? = nil
    ) throws -> OfflineReadingCacheSummary {
        // A cancelled producer must never publish after account unbinding has
        // already queued cache deletion on this actor.
        try Task.checkCancellation()
        guard let cacheKey = Self.cacheKey(forKindleBook: book) else {
            throw OfflineReadingCacheError.invalidBookIdentity
        }
        let normalizedPageKeys = pageKeys.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let normalizedVoiceID = voiceID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        try Self.validateCompleteKindlePackage(
            document: document,
            pageKeys: normalizedPageKeys,
            voiceID: normalizedVoiceID,
            segmentsByParagraph: segmentsByParagraph
        )

        let now = clock.now()
        let oldEntry = manifest.entries[cacheKey]
        let createdAt = oldEntry?.createdAt ?? now
        let stagingKey = OfflineReadingCacheDigest.sha256(UUID().uuidString)
        let stagedPackageDirectory = stagingDirectory.appendingPathComponent(
            stagingKey,
            isDirectory: true
        )
        let stagedResourcesDirectory = stagedPackageDirectory.appendingPathComponent(
            Self.resourcesDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagedResourcesDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: stagedPackageDirectory) }

        do {
            var writtenResources = Set<String>()
            let documentRecord = try makeDocumentRecord(
                document,
                resourcesDirectory: stagedResourcesDirectory,
                writtenResources: &writtenResources
            )
            let audioRecords = try makeAudioRecords(
                segmentsByParagraph,
                resourcesDirectory: stagedResourcesDirectory,
                writtenResources: &writtenResources
            )
            let packageRecord = OfflineReadingPackageRecord(
                version: Self.packageSchemaVersion,
                cacheKey: cacheKey,
                provider: .kindle,
                pageKeys: normalizedPageKeys,
                voiceID: normalizedVoiceID,
                document: documentRecord,
                audioByParagraph: audioRecords,
                createdAt: createdAt,
                updatedAt: now
            )
            let metadata = try Self.encode(packageRecord)
            let metadataDigest = OfflineReadingCacheDigest.sha256(metadata)
            let metadataFilename = OfflineReadingCacheDigest.sha256([
                cacheKey,
                "package",
                String(Self.packageSchemaVersion),
            ])
            try metadata.write(
                to: stagedPackageDirectory.appendingPathComponent(metadataFilename),
                options: .atomic
            )
            let byteSize = try exactByteSize(of: stagedPackageDirectory)
            guard byteSize <= limits.maxBytes else {
                throw OfflineReadingCacheError.packageTooLarge(
                    actualBytes: byteSize,
                    maximumBytes: limits.maxBytes
                )
            }

            let entry = OfflineReadingCacheManifestEntry(
                provider: .kindle,
                metadataFilename: metadataFilename,
                metadataDigest: metadataDigest,
                createdAt: createdAt,
                updatedAt: now,
                lastAccessAt: now,
                byteSize: byteSize,
                pageCount: normalizedPageKeys.count,
                paragraphCount: document.paragraphs.count,
                readableParagraphCount: document.readableParagraphs.count,
                audioSegmentCount: segmentsByParagraph.values.reduce(0) { $0 + $1.count },
                voiceID: normalizedVoiceID
            )

            // Validate the exact staged bytes before they can replace a known-
            // good package. This also proves every resource digest round-trips.
            _ = try validatedPackage(
                cacheKey: cacheKey,
                entry: entry,
                packageDirectory: stagedPackageDirectory,
                lastAccessAt: now
            )
            try faultHandler(.beforePublish)
            try Task.checkCancellation()

            let evictedKeys = evictionKeys(
                afterSaving: entry,
                for: cacheKey
            )
            try publish(
                stagedPackageDirectory: stagedPackageDirectory,
                entry: entry,
                cacheKey: cacheKey,
                evictedKeys: evictedKeys,
                publishLease: publishLease
            )
            let result = summary(cacheKey: cacheKey, entry: entry)
            notifyCacheChanged()
            return result
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as OfflineReadingCacheError {
            throw error
        } catch {
            throw OfflineReadingCacheError.ioFailure(error.localizedDescription)
        }
    }

    func loadKindlePackage(book: KindleBook) -> OfflineReadingPackage? {
        guard let cacheKey = Self.cacheKey(forKindleBook: book),
              let entry = manifest.entries[cacheKey],
              entry.provider == .kindle else { return nil }
        let package: OfflineReadingPackage
        do {
            let now = clock.now()
            package = try validatedPackage(
                cacheKey: cacheKey,
                entry: entry,
                packageDirectory: entryDirectory(for: cacheKey),
                lastAccessAt: now
            )
        } catch OfflineReadingCacheError.corruptPackage {
            discardCorruptEntry(cacheKey: cacheKey)
            return nil
        } catch {
            // A transient read/permission failure is not proof that the bytes
            // are corrupt. Keep the manifest and package for a later retry.
            return nil
        }

        var touchedEntry = entry
        touchedEntry.lastAccessAt = clock.now()
        var touchedManifest = manifest
        touchedManifest.entries[cacheKey] = touchedEntry
        do {
            try commitManifest(touchedManifest, reason: .accessTouch)
            return OfflineReadingPackage(
                document: package.document,
                pageKeys: package.pageKeys,
                segmentsByParagraph: package.segmentsByParagraph,
                summary: summary(cacheKey: cacheKey, entry: touchedEntry)
            )
        } catch {
            // Access time is advisory. A manifest write failure must never turn
            // a fully validated package into data loss or a playback miss.
            return OfflineReadingPackage(
                document: package.document,
                pageKeys: package.pageKeys,
                segmentsByParagraph: package.segmentsByParagraph,
                summary: summary(cacheKey: cacheKey, entry: entry)
            )
        }
    }

    func summary(forKindleBook book: KindleBook) -> OfflineReadingCacheSummary? {
        guard let cacheKey = Self.cacheKey(forKindleBook: book),
              let entry = manifest.entries[cacheKey],
              entry.provider == .kindle else { return nil }
        // Shelf badges must stay O(1). Full decoding and hashing belongs to
        // loadKindlePackage, immediately before untrusted bytes reach playback.
        return summary(cacheKey: cacheKey, entry: entry)
    }

    func containsKindlePackage(book: KindleBook) -> Bool {
        summary(forKindleBook: book) != nil
    }

    func removeKindlePackage(book: KindleBook) throws {
        guard let cacheKey = Self.cacheKey(forKindleBook: book),
              manifest.entries[cacheKey]?.provider == .kindle else { return }
        do {
            let directory = entryDirectory(for: cacheKey)
            try faultHandler(.beforeEntryRemoval(cacheKey))
            try Self.removeIfPresent(directory, fileManager: fileManager)
        } catch {
            throw OfflineReadingCacheError.ioFailure(error.localizedDescription)
        }
        // If this write fails the entry deliberately remains in memory/on disk.
        // A retry sees missing bytes as an already-completed first phase and
        // can finish removing the manifest record.
        var updated = manifest
        updated.entries.removeValue(forKey: cacheKey)
        try commitManifest(updated, reason: .remove)
        notifyCacheChanged()
    }

    func removeAllKindlePackages() throws {
        let keys = manifest.entries.compactMap { key, entry in
            entry.provider == .kindle ? key : nil
        }
        guard !keys.isEmpty else { return }
        do {
            for key in keys {
                let directory = entryDirectory(for: key)
                try faultHandler(.beforeEntryRemoval(key))
                try Self.removeIfPresent(directory, fileManager: fileManager)
            }
        } catch {
            throw OfflineReadingCacheError.ioFailure(error.localizedDescription)
        }
        var updated = manifest
        for key in keys { updated.entries.removeValue(forKey: key) }
        try commitManifest(updated, reason: .remove)
        notifyCacheChanged()
    }

    // MARK: - Package validation

    private static func validateCompleteKindlePackage(
        document: ReadingDocument,
        pageKeys: [String],
        voiceID: String,
        segmentsByParagraph: [Int: [AudioSegment]]
    ) throws {
        guard document.sourceKind == .kindle else {
            throw OfflineReadingCacheError.invalidDocument("source is not Kindle")
        }
        guard document.origin == nil, document.youtubeTranscript == nil else {
            throw OfflineReadingCacheError.invalidDocument("contains a foreign provider payload")
        }
        guard !document.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !document.language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OfflineReadingCacheError.invalidDocument("missing identity or language")
        }
        guard !voiceID.isEmpty else {
            throw OfflineReadingCacheError.incompleteAudio(paragraphIndex: nil)
        }
        guard !document.paragraphs.isEmpty,
              document.paragraphs.map(\.id) == Array(document.paragraphs.indices) else {
            throw OfflineReadingCacheError.invalidDocument("paragraph IDs are not contiguous")
        }

        let imageParagraphs = document.paragraphs.filter { $0.type == .image }
        guard !imageParagraphs.isEmpty else {
            throw OfflineReadingCacheError.invalidDocument("contains no rendered pages")
        }
        let imagePageIndexes = imageParagraphs.compactMap(\.pageIndex)
        guard imagePageIndexes.count == imageParagraphs.count,
              Set(imagePageIndexes).count == imageParagraphs.count,
              Set(imagePageIndexes) == Set(0..<imageParagraphs.count),
              imageParagraphs.allSatisfy({ !($0.imageData?.isEmpty ?? true) }) else {
            throw OfflineReadingCacheError.invalidDocument("page images are incomplete")
        }
        guard pageKeys.count == imageParagraphs.count,
              pageKeys.allSatisfy({ !$0.isEmpty }),
              Set(pageKeys).count == pageKeys.count else {
            throw OfflineReadingCacheError.invalidPageKeys
        }

        var wordIDs = Set<Int>()
        for paragraph in document.paragraphs where paragraph.type != .image {
            guard paragraph.type.isReadable,
                  !paragraph.resolvedSpeechText
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let pageIndex = paragraph.pageIndex,
                  imagePageIndexes.contains(pageIndex),
                  !paragraph.words.isEmpty else {
                throw OfflineReadingCacheError.invalidDocument(
                    "OCR paragraph \(paragraph.id) is incomplete"
                )
            }
            if let bbox = paragraph.bboxNorm, !isValidNormalizedRect(bbox) {
                throw OfflineReadingCacheError.invalidDocument("invalid paragraph geometry")
            }
            let paragraphWordIDs = Set(paragraph.words.map(\.id))
            guard paragraphWordIDs.count == paragraph.words.count,
                  wordIDs.isDisjoint(with: paragraphWordIDs),
                  paragraph.words.allSatisfy({
                      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && isValidNormalizedRect($0.bboxNorm)
                  }) else {
                throw OfflineReadingCacheError.invalidDocument("invalid OCR words")
            }
            wordIDs.formUnion(paragraphWordIDs)
            guard paragraph.visualFragments.allSatisfy({ fragment in
                isValidNormalizedRect(fragment.bboxNorm)
                    && !fragment.wordIDs.isEmpty
                    && Set(fragment.wordIDs).isSubset(of: paragraphWordIDs)
            }) else {
                throw OfflineReadingCacheError.invalidDocument("invalid OCR fragments")
            }
        }

        let readableIDs = Set(document.readableParagraphs.map(\.id))
        guard !readableIDs.isEmpty,
              Set(segmentsByParagraph.keys) == readableIDs else {
            throw OfflineReadingCacheError.incompleteAudio(paragraphIndex: nil)
        }
        for paragraphID in readableIDs {
            guard let segments = segmentsByParagraph[paragraphID], !segments.isEmpty else {
                throw OfflineReadingCacheError.incompleteAudio(paragraphIndex: paragraphID)
            }
            let ordered = segments.sorted { $0.segmentIndex < $1.segmentIndex }
            guard ordered.map(\.segmentIndex) == Array(ordered.indices) else {
                throw OfflineReadingCacheError.incompleteAudio(paragraphIndex: paragraphID)
            }
            for segment in ordered {
                guard segment.paragraphIndex == paragraphID,
                      !segment.audioData.isEmpty,
                      segment.duration.isFinite,
                      segment.duration > 0,
                      !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      validTimestamps(segment.timestamps, duration: segment.duration) else {
                    throw OfflineReadingCacheError.incompleteAudio(paragraphIndex: paragraphID)
                }
            }
        }
    }

    private static func isValidNormalizedRect(_ rect: CGRect) -> Bool {
        let values = [rect.minX, rect.minY, rect.width, rect.height]
        guard values.allSatisfy({ $0.isFinite }), rect.width > 0, rect.height > 0 else {
            return false
        }
        let tolerance: CGFloat = 0.000_1
        return rect.minX >= -tolerance && rect.minY >= -tolerance
            && rect.maxX <= 1 + tolerance && rect.maxY <= 1 + tolerance
    }

    private static func validTimestamps(
        _ timestamps: [TTSTimestamp],
        duration: Double
    ) -> Bool {
        guard !timestamps.isEmpty else { return false }
        var previousStart = -Double.infinity
        for timestamp in timestamps {
            guard !timestamp.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  timestamp.startTime.isFinite, timestamp.endTime.isFinite,
                  timestamp.startTime >= 0,
                  timestamp.endTime >= timestamp.startTime,
                  timestamp.startTime >= previousStart,
                  timestamp.endTime <= duration + max(1, duration * 0.05) else {
                return false
            }
            previousStart = timestamp.startTime
        }
        return true
    }

    // MARK: - Encoding

    private func makeDocumentRecord(
        _ document: ReadingDocument,
        resourcesDirectory: URL,
        writtenResources: inout Set<String>
    ) throws -> OfflineReadingDocumentRecord {
        let imageResource = try writeResource(
            document.imageData,
            to: resourcesDirectory,
            writtenResources: &writtenResources
        )
        let fileResource = try writeResource(
            document.fileData,
            to: resourcesDirectory,
            writtenResources: &writtenResources
        )
        let paragraphs = try document.paragraphs.map { paragraph in
            OfflineReadingParagraphRecord(
                id: paragraph.id,
                text: paragraph.text,
                speechText: paragraph.speechText,
                speaker: paragraph.speaker,
                type: OfflineReadingParagraphTypeRecord(paragraph.type),
                words: paragraph.words.map {
                    OfflineReadingWordRecord(
                        id: $0.id,
                        text: $0.text,
                        bbox: OfflineReadingRectRecord($0.bboxNorm)
                    )
                },
                bbox: paragraph.bboxNorm.map(OfflineReadingRectRecord.init),
                visualFragments: paragraph.visualFragments.map {
                    OfflineReadingFragmentRecord(
                        column: $0.column.rawValue,
                        bbox: OfflineReadingRectRecord($0.bboxNorm),
                        wordIDs: $0.wordIDs
                    )
                },
                pdfPageIndex: paragraph.pdfPageIndex,
                pdfRange: paragraph.pdfRange.map(OfflineReadingRangeRecord.init),
                pageIndex: paragraph.pageIndex,
                imageResource: try writeResource(
                    paragraph.imageData,
                    to: resourcesDirectory,
                    writtenResources: &writtenResources
                ),
                startMs: paragraph.startMs
            )
        }
        return OfflineReadingDocumentRecord(
            id: document.id,
            title: document.title,
            sourceKind: document.sourceKind,
            language: document.language,
            paragraphs: paragraphs,
            imageResource: imageResource,
            imagePixelSize: document.imagePixelSize.map(OfflineReadingSizeRecord.init),
            sourceURL: document.sourceURL,
            coverURL: document.coverURL,
            fileResource: fileResource,
            persistencePolicy: document.persistencePolicy,
            effectiveFormat: document.effectiveFormat,
            exportFormat: document.exportFormat,
            contentRevision: document.contentRevision,
            contentSessionKey: document.contentSessionKey,
            layoutColumnCount: document.layoutColumnCount,
            createdAt: document.createdAt
        )
    }

    private func makeAudioRecords(
        _ segmentsByParagraph: [Int: [AudioSegment]],
        resourcesDirectory: URL,
        writtenResources: inout Set<String>
    ) throws -> [OfflineReadingParagraphAudioRecord] {
        try segmentsByParagraph.keys.sorted().map { paragraphIndex in
            let segments = (segmentsByParagraph[paragraphIndex] ?? [])
                .sorted { $0.segmentIndex < $1.segmentIndex }
            return OfflineReadingParagraphAudioRecord(
                paragraphIndex: paragraphIndex,
                segments: try segments.map { segment in
                    guard let audioResource = try writeResource(
                        segment.audioData,
                        to: resourcesDirectory,
                        writtenResources: &writtenResources
                    ) else {
                        throw OfflineReadingCacheError.incompleteAudio(
                            paragraphIndex: paragraphIndex
                        )
                    }
                    return OfflineReadingAudioSegmentRecord(
                        paragraphIndex: segment.paragraphIndex,
                        segmentIndex: segment.segmentIndex,
                        audioResource: audioResource,
                        timestamps: segment.timestamps,
                        duration: segment.duration,
                        text: segment.text,
                        isWavFormat: segment.isWavFormat,
                        unprocessedText: segment.unprocessedText,
                        speaker: segment.speaker
                    )
                }
            )
        }
    }

    private func writeResource(
        _ data: Data?,
        to directory: URL,
        writtenResources: inout Set<String>
    ) throws -> OfflineReadingResourceRecord? {
        // Kindle packages can contain hundreds of image/audio resources. Check
        // between writes so cancellation does not have to wait for all bytes.
        try Task.checkCancellation()
        guard let data else { return nil }
        let digest = OfflineReadingCacheDigest.sha256(data)
        if writtenResources.insert(digest).inserted {
            try data.write(to: directory.appendingPathComponent(digest), options: .atomic)
        }
        return OfflineReadingResourceRecord(digest: digest, byteSize: Int64(data.count))
    }

    private func validatedPackage(
        cacheKey: String,
        entry: OfflineReadingCacheManifestEntry,
        packageDirectory: URL,
        lastAccessAt: Date
    ) throws -> OfflineReadingPackage {
        guard OfflineReadingCacheDigest.isDigest(cacheKey),
              OfflineReadingCacheDigest.isDigest(entry.metadataFilename),
              OfflineReadingCacheDigest.isDigest(entry.metadataDigest) else {
            throw OfflineReadingCacheError.corruptPackage
        }
        let metadataURL = packageDirectory.appendingPathComponent(entry.metadataFilename)
        let metadata = try readIntegrityData(at: metadataURL)
        guard OfflineReadingCacheDigest.sha256(metadata) == entry.metadataDigest else {
            throw OfflineReadingCacheError.corruptPackage
        }
        let record: OfflineReadingPackageRecord
        do {
            record = try Self.decode(OfflineReadingPackageRecord.self, from: metadata)
        } catch {
            throw OfflineReadingCacheError.corruptPackage
        }
        guard record.version == Self.packageSchemaVersion,
              record.cacheKey == cacheKey,
              record.provider == entry.provider,
              record.pageKeys.count == entry.pageCount,
              record.document.paragraphs.count == entry.paragraphCount,
              record.audioByParagraph.reduce(0, { $0 + $1.segments.count })
                == entry.audioSegmentCount,
              record.voiceID == entry.voiceID else {
            throw OfflineReadingCacheError.corruptPackage
        }

        let resourcesDirectory = packageDirectory.appendingPathComponent(
            Self.resourcesDirectoryName,
            isDirectory: true
        )
        var referencedResources = Set<String>()
        let document = try restoreDocument(
            record.document,
            resourcesDirectory: resourcesDirectory,
            referencedResources: &referencedResources
        )
        var segmentsByParagraph: [Int: [AudioSegment]] = [:]
        for paragraphRecord in record.audioByParagraph {
            guard segmentsByParagraph[paragraphRecord.paragraphIndex] == nil else {
                throw OfflineReadingCacheError.corruptPackage
            }
            segmentsByParagraph[paragraphRecord.paragraphIndex] = try paragraphRecord.segments.map {
                let audioData = try readResource(
                    $0.audioResource,
                    from: resourcesDirectory,
                    referencedResources: &referencedResources
                )
                return AudioSegment(
                    paragraphIndex: $0.paragraphIndex,
                    segmentIndex: $0.segmentIndex,
                    audioData: audioData,
                    timestamps: $0.timestamps,
                    duration: $0.duration,
                    text: $0.text,
                    isWavFormat: $0.isWavFormat,
                    unprocessedText: $0.unprocessedText,
                    speaker: $0.speaker
                )
            }
        }

        do {
            try Self.validateCompleteKindlePackage(
                document: document,
                pageKeys: record.pageKeys,
                voiceID: record.voiceID,
                segmentsByParagraph: segmentsByParagraph
            )
        } catch {
            // A package that decodes but no longer satisfies the schema's
            // completeness contract is persisted corruption, not transient I/O.
            throw OfflineReadingCacheError.corruptPackage
        }
        try validateDirectoryShape(
            packageDirectory: packageDirectory,
            metadataFilename: entry.metadataFilename,
            referencedResources: referencedResources
        )
        guard try exactByteSize(of: packageDirectory) == entry.byteSize else {
            throw OfflineReadingCacheError.corruptPackage
        }
        return OfflineReadingPackage(
            document: document,
            pageKeys: record.pageKeys,
            segmentsByParagraph: segmentsByParagraph,
            summary: summary(
                cacheKey: cacheKey,
                entry: entry,
                lastAccessAt: lastAccessAt
            )
        )
    }

    private func restoreDocument(
        _ record: OfflineReadingDocumentRecord,
        resourcesDirectory: URL,
        referencedResources: inout Set<String>
    ) throws -> ReadingDocument {
        let paragraphs = try record.paragraphs.map { paragraph in
            guard let type = paragraph.type.value,
                  paragraph.visualFragments.allSatisfy({
                      OCRVisualFragment.Column(rawValue: $0.column) != nil
                  }) else {
                throw OfflineReadingCacheError.corruptPackage
            }
            return ReadingParagraph(
                id: paragraph.id,
                text: paragraph.text,
                speechText: paragraph.speechText,
                speaker: paragraph.speaker,
                type: type,
                words: paragraph.words.map {
                    OCRWord(id: $0.id, text: $0.text, bboxNorm: $0.bbox.value)
                },
                bboxNorm: paragraph.bbox?.value,
                visualFragments: paragraph.visualFragments.compactMap {
                    guard let column = OCRVisualFragment.Column(rawValue: $0.column) else {
                        return nil
                    }
                    return OCRVisualFragment(
                        column: column,
                        bboxNorm: $0.bbox.value,
                        wordIDs: $0.wordIDs
                    )
                },
                pdfPageIndex: paragraph.pdfPageIndex,
                pdfRange: paragraph.pdfRange?.value,
                pageIndex: paragraph.pageIndex,
                imageData: try readOptionalResource(
                    paragraph.imageResource,
                    from: resourcesDirectory,
                    referencedResources: &referencedResources
                ),
                startMs: paragraph.startMs
            )
        }
        return ReadingDocument(
            id: record.id,
            title: record.title,
            sourceKind: record.sourceKind,
            language: record.language,
            paragraphs: paragraphs,
            imageData: try readOptionalResource(
                record.imageResource,
                from: resourcesDirectory,
                referencedResources: &referencedResources
            ),
            imagePixelSize: record.imagePixelSize?.value,
            sourceURL: record.sourceURL,
            coverURL: record.coverURL,
            fileData: try readOptionalResource(
                record.fileResource,
                from: resourcesDirectory,
                referencedResources: &referencedResources
            ),
            origin: nil,
            persistencePolicy: record.persistencePolicy,
            effectiveFormat: record.effectiveFormat,
            exportFormat: record.exportFormat,
            contentRevision: record.contentRevision,
            contentSessionKey: record.contentSessionKey,
            youtubeTranscript: nil,
            youtubeCacheHit: false,
            layoutColumnCount: record.layoutColumnCount,
            createdAt: record.createdAt
        )
    }

    private func readOptionalResource(
        _ record: OfflineReadingResourceRecord?,
        from directory: URL,
        referencedResources: inout Set<String>
    ) throws -> Data? {
        guard let record else { return nil }
        return try readResource(
            record,
            from: directory,
            referencedResources: &referencedResources
        )
    }

    private func readResource(
        _ record: OfflineReadingResourceRecord,
        from directory: URL,
        referencedResources: inout Set<String>
    ) throws -> Data {
        guard OfflineReadingCacheDigest.isDigest(record.digest), record.byteSize >= 0 else {
            throw OfflineReadingCacheError.corruptPackage
        }
        let data = try readIntegrityData(
            at: directory.appendingPathComponent(record.digest)
        )
        guard Int64(data.count) == record.byteSize,
              OfflineReadingCacheDigest.sha256(data) == record.digest else {
            throw OfflineReadingCacheError.corruptPackage
        }
        referencedResources.insert(record.digest)
        return data
    }

    private func validateDirectoryShape(
        packageDirectory: URL,
        metadataFilename: String,
        referencedResources: Set<String>
    ) throws {
        let packageNames: Set<String>
        do {
            packageNames = try Set(
                fileManager.contentsOfDirectory(atPath: packageDirectory.path)
            )
        } catch {
            throw Self.integrityReadError(error)
        }
        guard packageNames == Set([metadataFilename, Self.resourcesDirectoryName]) else {
            throw OfflineReadingCacheError.corruptPackage
        }
        let resourcesURL = packageDirectory.appendingPathComponent(
            Self.resourcesDirectoryName,
            isDirectory: true
        )
        let resourceNames: Set<String>
        do {
            resourceNames = try Set(
                fileManager.contentsOfDirectory(atPath: resourcesURL.path)
            )
        } catch {
            throw Self.integrityReadError(error)
        }
        guard resourceNames == referencedResources,
              resourceNames.allSatisfy(OfflineReadingCacheDigest.isDigest) else {
            throw OfflineReadingCacheError.corruptPackage
        }
    }

    private func readIntegrityData(at url: URL) throws -> Data {
        do {
            return try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw Self.integrityReadError(error)
        }
    }

    private static func integrityReadError(_ error: Error) -> OfflineReadingCacheError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            let code = CocoaError.Code(rawValue: nsError.code)
            if code == .fileNoSuchFile || code == .fileReadNoSuchFile {
                return .corruptPackage
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return .corruptPackage
        }
        return .ioFailure(error.localizedDescription)
    }

    // MARK: - Manifest and LRU

    private func publish(
        stagedPackageDirectory: URL,
        entry: OfflineReadingCacheManifestEntry,
        cacheKey: String,
        evictedKeys: [String],
        publishLease: OfflineReadingCachePublishLease?
    ) throws {
        try Task.checkCancellation()
        let destination = entryDirectory(for: cacheKey)
        let transactionDirectory = stagingDirectory.appendingPathComponent(
            OfflineReadingCacheDigest.sha256(UUID().uuidString),
            isDirectory: true
        )
        let candidateDirectory = transactionDirectory.appendingPathComponent(
            Self.transactionCandidateDirectoryName,
            isDirectory: true
        )
        let previousDirectory = transactionDirectory.appendingPathComponent(
            Self.transactionPreviousDirectoryName,
            isDirectory: true
        )
        var journal = OfflineReadingCacheTransactionJournal(
            version: OfflineReadingCacheTransactionJournal.currentVersion,
            cacheKey: cacheKey,
            newEntry: entry,
            previousEntry: manifest.entries[cacheKey],
            evictedKeys: evictedKeys,
            previousEvictedEntries: Dictionary(uniqueKeysWithValues: evictedKeys.compactMap {
                key in manifest.entries[key].map { (key, $0) }
            }),
            phase: .prepared
        )
        do {
            try fileManager.createDirectory(
                at: transactionDirectory,
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(
                at: stagedPackageDirectory,
                to: candidateDirectory
            )
            try Self.writeTransactionJournal(
                journal,
                in: transactionDirectory
            )
            try Task.checkCancellation()

            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.moveItem(at: destination, to: previousDirectory)
            }
            journal.phase = .previousMoved
            try Self.writeTransactionJournal(journal, in: transactionDirectory)
            try Task.checkCancellation()
            try faultHandler(.afterPreviousMoved)

            try fileManager.moveItem(at: candidateDirectory, to: destination)
            journal.phase = .candidateInstalled
            try Self.writeTransactionJournal(journal, in: transactionDirectory)
            try Task.checkCancellation()
            try faultHandler(.afterCandidateInstalled)

            var updated = manifest
            updated.entries[cacheKey] = entry
            for key in evictedKeys { updated.entries.removeValue(forKey: key) }
            if let publishLease {
                try publishLease.commitIfValid {
                    // Both checks and the manifest commit happen while revoke
                    // is excluded by the lease lock.
                    try Task.checkCancellation()
                    try commitManifest(updated, reason: .publish)
                }
            } else {
                // Compatibility path for existing callers and non-Pro tests.
                try Task.checkCancellation()
                try commitManifest(updated, reason: .publish)
            }
            journal.phase = .manifestCommitted
            try Self.writeTransactionJournal(journal, in: transactionDirectory)
            try faultHandler(.afterManifestCommitted)

            for key in evictedKeys where key != cacheKey {
                try Self.removeIfPresent(
                    entryDirectory(for: key),
                    fileManager: fileManager
                )
            }
            try Self.removeIfPresent(transactionDirectory, fileManager: fileManager)
        } catch OfflineReadingCacheInjectedFailure.simulatedCrash {
            // Tests use this to emulate abrupt process termination. Production
            // never installs a throwing handler; reopening consumes the journal.
            throw OfflineReadingCacheInjectedFailure.simulatedCrash
        } catch is CancellationError {
            do {
                try recoverPublishTransaction(
                    transactionDirectory: transactionDirectory,
                    journal: journal
                )
            } catch let recoveryError {
                throw OfflineReadingCacheError.ioFailure(
                    "Save cancelled; recovery failed: \(recoveryError.localizedDescription)"
                )
            }
            throw CancellationError()
        } catch let originalError as OfflineReadingCacheError {
            do {
                try recoverPublishTransaction(
                    transactionDirectory: transactionDirectory,
                    journal: journal
                )
                if manifest.entries[cacheKey] == entry { return }
            } catch let recoveryError {
                throw OfflineReadingCacheError.ioFailure(
                    "\(originalError.localizedDescription); recovery failed: \(recoveryError.localizedDescription)"
                )
            }
            throw originalError
        } catch let originalError {
            do {
                try recoverPublishTransaction(
                    transactionDirectory: transactionDirectory,
                    journal: journal
                )
                if manifest.entries[cacheKey] == entry { return }
            } catch let recoveryError {
                throw OfflineReadingCacheError.ioFailure(
                    "\(originalError.localizedDescription); recovery failed: \(recoveryError.localizedDescription)"
                )
            }
            throw OfflineReadingCacheError.ioFailure(originalError.localizedDescription)
        }
    }

    /// Synchronous publish failures are recovered in-process, but the journal
    /// remains until the recovered commit record is durable. This is the same
    /// ordering used by startup recovery and makes a second crash replayable.
    private func recoverPublishTransaction(
        transactionDirectory: URL,
        journal: OfflineReadingCacheTransactionJournal
    ) throws {
        _ = try Self.recoverTransaction(
            transactionDirectory: transactionDirectory,
            entriesDirectory: entriesDirectory,
            journal: journal,
            manifest: &manifest,
            fileManager: fileManager,
            cleanupTransaction: false
        )
        let recoveredManifest = manifest
        try commitManifest(recoveredManifest, reason: .recovery)
        try Self.removeIfPresent(transactionDirectory, fileManager: fileManager)
    }

    private static func writeTransactionJournal(
        _ journal: OfflineReadingCacheTransactionJournal,
        in transactionDirectory: URL
    ) throws {
        let data = try encode(journal)
        try data.write(
            to: transactionDirectory.appendingPathComponent(
                transactionJournalFilename
            ),
            options: .atomic
        )
    }

    /// Resolves a single interrupted publish from durable facts. The manifest
    /// is the commit record: if it points to `newEntry`, finish the new package;
    /// otherwise restore the prior bytes and discard the candidate.
    @discardableResult
    private static func recoverTransaction(
        transactionDirectory: URL,
        entriesDirectory: URL,
        journal: OfflineReadingCacheTransactionJournal,
        manifest: inout OfflineReadingCacheManifest,
        fileManager: FileManager,
        cleanupTransaction: Bool
    ) throws -> Bool {
        let destination = entriesDirectory.appendingPathComponent(
            journal.cacheKey,
            isDirectory: true
        )
        let candidate = transactionDirectory.appendingPathComponent(
            transactionCandidateDirectoryName,
            isDirectory: true
        )
        let previous = transactionDirectory.appendingPathComponent(
            transactionPreviousDirectoryName,
            isDirectory: true
        )
        let committed = manifest.entries[journal.cacheKey] == journal.newEntry

        if committed {
            if try !directory(
                destination,
                matches: journal.newEntry,
                fileManager: fileManager
            ) {
                if try directory(
                    candidate,
                    matches: journal.newEntry,
                    fileManager: fileManager
                ) {
                    try removeIfPresent(destination, fileManager: fileManager)
                    try fileManager.moveItem(at: candidate, to: destination)
                } else if let previousEntry = journal.previousEntry,
                          try directory(
                              previous,
                              matches: previousEntry,
                              fileManager: fileManager
                          ) {
                    // The committed candidate vanished, but the previous bytes
                    // are still recoverable. Roll the commit record back rather
                    // than leaving either content set orphaned.
                    try removeIfPresent(destination, fileManager: fileManager)
                    try fileManager.moveItem(at: previous, to: destination)
                    manifest.entries[journal.cacheKey] = previousEntry
                    for (key, entry) in journal.previousEvictedEntries {
                        manifest.entries[key] = entry
                    }
                } else if let previousEntry = journal.previousEntry,
                          try directory(
                              destination,
                              matches: previousEntry,
                              fileManager: fileManager
                          ) {
                    manifest.entries[journal.cacheKey] = previousEntry
                    for (key, entry) in journal.previousEvictedEntries {
                        manifest.entries[key] = entry
                    }
                } else {
                    try removeIfPresent(destination, fileManager: fileManager)
                    manifest.entries.removeValue(forKey: journal.cacheKey)
                }
            }
        } else if let previousEntry = journal.previousEntry {
            if try directory(previous, matches: previousEntry, fileManager: fileManager) {
                try removeIfPresent(destination, fileManager: fileManager)
                try fileManager.moveItem(at: previous, to: destination)
                manifest.entries[journal.cacheKey] = previousEntry
                for (key, entry) in journal.previousEvictedEntries {
                    manifest.entries[key] = entry
                }
            } else if try directory(
                destination,
                matches: previousEntry,
                fileManager: fileManager
            ) {
                manifest.entries[journal.cacheKey] = previousEntry
                for (key, entry) in journal.previousEvictedEntries {
                    manifest.entries[key] = entry
                }
            } else {
                // Neither version is trustworthy enough to expose. Removing the
                // stale manifest avoids pointing another account session at an
                // unrelated candidate directory.
                try removeIfPresent(destination, fileManager: fileManager)
                manifest.entries.removeValue(forKey: journal.cacheKey)
            }
        } else {
            // An interrupted first save has no previously committed package.
            try removeIfPresent(destination, fileManager: fileManager)
            manifest.entries.removeValue(forKey: journal.cacheKey)
        }

        for key in journal.evictedKeys where manifest.entries[key] == nil {
            try removeIfPresent(
                entriesDirectory.appendingPathComponent(key, isDirectory: true),
                fileManager: fileManager
            )
        }
        if cleanupTransaction {
            try removeIfPresent(transactionDirectory, fileManager: fileManager)
        }
        return true
    }

    private static func recoverTransactions(
        entriesDirectory: URL,
        stagingDirectory: URL,
        manifest: inout OfflineReadingCacheManifest,
        fileManager: FileManager
    ) throws -> Bool {
        let items = try fileManager.contentsOfDirectory(
            at: stagingDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        guard !items.isEmpty else { return false }
        for item in items {
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  OfflineReadingCacheDigest.isDigest(item.lastPathComponent) else {
                try removeIfPresent(item, fileManager: fileManager)
                continue
            }
            let journalURL = item.appendingPathComponent(transactionJournalFilename)
            let data: Data
            do {
                data = try Data(contentsOf: journalURL, options: .mappedIfSafe)
            } catch {
                let mappedError = integrityReadError(error)
                if mappedError == .corruptPackage {
                    try removeIfPresent(item, fileManager: fileManager)
                    continue
                }
                throw mappedError
            }
            let journal: OfflineReadingCacheTransactionJournal
            do {
                journal = try decode(
                    OfflineReadingCacheTransactionJournal.self,
                    from: data
                )
            } catch {
                // A journal whose bytes are present but undecodable cannot be
                // tied to an account package safely. Purge all staged payloads.
                try removeIfPresent(item, fileManager: fileManager)
                continue
            }
            guard journal.version == OfflineReadingCacheTransactionJournal.currentVersion,
                  OfflineReadingCacheDigest.isDigest(journal.cacheKey),
                  isValidManifestEntry(journal.newEntry),
                  journal.previousEntry.map(isValidManifestEntry) ?? true,
                  journal.evictedKeys.allSatisfy(OfflineReadingCacheDigest.isDigest),
                  journal.previousEvictedEntries.keys.allSatisfy(
                      OfflineReadingCacheDigest.isDigest
                  ),
                  journal.previousEvictedEntries.values.allSatisfy(
                      isValidManifestEntry
                  ) else {
                // Invalid journals may contain private page/audio bytes. They
                // have no safe commit identity, so never retain them as orphans.
                try removeIfPresent(item, fileManager: fileManager)
                continue
            }
            _ = try recoverTransaction(
                transactionDirectory: item,
                entriesDirectory: entriesDirectory,
                journal: journal,
                manifest: &manifest,
                fileManager: fileManager,
                cleanupTransaction: false
            )
        }
        return true
    }

    private static func purgeStagingDirectory(
        _ stagingDirectory: URL,
        fileManager: FileManager
    ) throws {
        let leftovers = try fileManager.contentsOfDirectory(atPath: stagingDirectory.path)
        for name in leftovers {
            try removeIfPresent(
                stagingDirectory.appendingPathComponent(name),
                fileManager: fileManager
            )
        }
    }

    private static func reconcileEntries(
        entriesDirectory: URL,
        manifest: inout OfflineReadingCacheManifest,
        fileManager: FileManager
    ) throws -> Bool {
        let items = try fileManager.contentsOfDirectory(
            at: entriesDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        var changed = false
        var retainedKeys = Set<String>()
        for item in items {
            let key = item.lastPathComponent
            let values = try item.resourceValues(forKeys: [.isDirectoryKey])
            guard values.isDirectory == true,
                  OfflineReadingCacheDigest.isDigest(key),
                  let entry = manifest.entries[key] else {
                try removeIfPresent(item, fileManager: fileManager)
                changed = true
                continue
            }
            let metadataURL = item.appendingPathComponent(entry.metadataFilename)
            let metadataExists: Bool
            do {
                metadataExists = try metadataURL.resourceValues(
                    forKeys: [.isRegularFileKey]
                ).isRegularFile == true
            } catch {
                let mappedError = integrityReadError(error)
                if mappedError != .corruptPackage { throw mappedError }
                metadataExists = false
            }
            guard metadataExists else {
                try removeIfPresent(item, fileManager: fileManager)
                manifest.entries.removeValue(forKey: key)
                changed = true
                continue
            }
            retainedKeys.insert(key)
        }
        for key in Array(manifest.entries.keys) where !retainedKeys.contains(key) {
            manifest.entries.removeValue(forKey: key)
            changed = true
        }
        return changed
    }

    private static func directory(
        _ directory: URL,
        matches entry: OfflineReadingCacheManifestEntry,
        fileManager: FileManager
    ) throws -> Bool {
        let metadataURL = directory.appendingPathComponent(entry.metadataFilename)
        do {
            let data = try Data(contentsOf: metadataURL, options: .mappedIfSafe)
            return OfflineReadingCacheDigest.sha256(data) == entry.metadataDigest
        } catch {
            let mappedError = integrityReadError(error)
            if mappedError == .corruptPackage { return false }
            throw mappedError
        }
    }

    private static func removeIfPresent(
        _ url: URL,
        fileManager: FileManager
    ) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            if integrityReadError(error) == .corruptPackage { return }
            throw error
        }
    }

    private func evictionKeys(
        afterSaving entry: OfflineReadingCacheManifestEntry,
        for cacheKey: String
    ) -> [String] {
        var projected = manifest.entries
        projected[cacheKey] = entry
        var count = projected.count
        var bytes = projected.values.reduce(Int64(0)) { $0 + $1.byteSize }
        let candidates = projected
            .filter { $0.key != cacheKey }
            .sorted {
                if $0.value.lastAccessAt == $1.value.lastAccessAt {
                    return $0.key < $1.key
                }
                return $0.value.lastAccessAt < $1.value.lastAccessAt
            }
        var evicted: [String] = []
        for candidate in candidates
        where count > limits.maxBookCount || bytes > limits.maxBytes {
            evicted.append(candidate.key)
            count -= 1
            bytes -= candidate.value.byteSize
        }
        return evicted
    }

    private func discardCorruptEntry(cacheKey: String) {
        let directory = entryDirectory(for: cacheKey)
        do {
            try Self.removeIfPresent(directory, fileManager: fileManager)
            var updated = manifest
            updated.entries.removeValue(forKey: cacheKey)
            try commitManifest(updated, reason: .corruptionCleanup)
            notifyCacheChanged()
        } catch {
            // Keep the manifest record if bytes could not be removed. A later
            // load/recovery retry remains able to complete the purge.
        }
    }

    private func notifyCacheChanged() {
        NotificationCenter.default.post(name: .offlineReadingCacheDidChange, object: nil)
    }

    private func commitManifest(
        _ updated: OfflineReadingCacheManifest,
        reason: OfflineReadingCacheManifestWriteReason
    ) throws {
        let previous = manifest
        manifest = updated
        do {
            try writeManifest(reason: reason)
        } catch {
            manifest = previous
            throw error
        }
    }

    private func writeManifest(reason: OfflineReadingCacheManifestWriteReason) throws {
        do {
            try faultHandler(.beforeManifestWrite(reason))
            try Self.writeManifest(
                manifest,
                at: rootDirectory.appendingPathComponent(Self.manifestFilename)
            )
        } catch {
            throw OfflineReadingCacheError.ioFailure(error.localizedDescription)
        }
    }

    private static func writeManifest(
        _ manifest: OfflineReadingCacheManifest,
        at url: URL
    ) throws {
        let data = try encode(manifest)
        try data.write(to: url, options: .atomic)
    }

    private static func readManifest(
        at url: URL,
        fileManager: FileManager
    ) throws -> OfflineReadingCacheManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            let mappedError = integrityReadError(error)
            if mappedError == .corruptPackage {
                return OfflineReadingCacheManifest()
            }
            throw mappedError
        }
        let manifest: OfflineReadingCacheManifest
        do {
            manifest = try decode(OfflineReadingCacheManifest.self, from: data)
        } catch {
            throw OfflineReadingCacheError.corruptPackage
        }
        guard manifest.version == OfflineReadingCacheManifest.currentVersion,
              manifest.entries.keys.allSatisfy(OfflineReadingCacheDigest.isDigest),
              manifest.entries.values.allSatisfy(isValidManifestEntry) else {
            throw OfflineReadingCacheError.corruptPackage
        }
        return manifest
    }

    private static func isValidManifestEntry(
        _ entry: OfflineReadingCacheManifestEntry
    ) -> Bool {
        OfflineReadingCacheDigest.isDigest(entry.metadataFilename)
            && OfflineReadingCacheDigest.isDigest(entry.metadataDigest)
            && entry.byteSize >= 0
            && entry.pageCount >= 0
            && entry.paragraphCount >= 0
            && entry.readableParagraphCount >= 0
            && entry.audioSegmentCount >= 0
            && !entry.voiceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func entryDirectory(for cacheKey: String) -> URL {
        entriesDirectory.appendingPathComponent(cacheKey, isDirectory: true)
    }

    private func summary(
        cacheKey: String,
        entry: OfflineReadingCacheManifestEntry,
        lastAccessAt: Date? = nil
    ) -> OfflineReadingCacheSummary {
        OfflineReadingCacheSummary(
            cacheKey: cacheKey,
            provider: entry.provider,
            pageCount: entry.pageCount,
            paragraphCount: entry.paragraphCount,
            readableParagraphCount: entry.readableParagraphCount,
            audioSegmentCount: entry.audioSegmentCount,
            byteSize: entry.byteSize,
            voiceID: entry.voiceID,
            createdAt: entry.createdAt,
            updatedAt: entry.updatedAt,
            lastAccessAt: lastAccessAt ?? entry.lastAccessAt
        )
    }

    private func exactByteSize(of directory: URL) throws -> Int64 {
        var enumerationError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            if !fileManager.fileExists(atPath: directory.path) {
                throw OfflineReadingCacheError.corruptPackage
            }
            throw OfflineReadingCacheError.ioFailure("Unable to enumerate package bytes.")
        }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values: URLResourceValues
            do {
                values = try url.resourceValues(
                    forKeys: [.isRegularFileKey, .fileSizeKey]
                )
            } catch {
                throw Self.integrityReadError(error)
            }
            if values.isRegularFile == true { total += Int64(values.fileSize ?? 0) }
        }
        if let enumerationError {
            throw Self.integrityReadError(enumerationError)
        }
        return total
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return try encoder.encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(type, from: data)
    }
}

// MARK: - Codable package schema

private struct OfflineReadingCacheManifest: Codable, Equatable {
    static let currentVersion = 1
    var version: Int = currentVersion
    var entries: [String: OfflineReadingCacheManifestEntry] = [:]
}

private struct OfflineReadingCacheManifestEntry: Codable, Equatable {
    let provider: OfflineReadingProvider
    let metadataFilename: String
    let metadataDigest: String
    let createdAt: Date
    let updatedAt: Date
    var lastAccessAt: Date
    let byteSize: Int64
    let pageCount: Int
    let paragraphCount: Int
    let readableParagraphCount: Int
    let audioSegmentCount: Int
    let voiceID: String
}

private enum OfflineReadingCacheTransactionPhase: String, Codable {
    case prepared
    case previousMoved
    case candidateInstalled
    case manifestCommitted
}

private struct OfflineReadingCacheTransactionJournal: Codable {
    static let currentVersion = 1

    let version: Int
    let cacheKey: String
    let newEntry: OfflineReadingCacheManifestEntry
    let previousEntry: OfflineReadingCacheManifestEntry?
    let evictedKeys: [String]
    let previousEvictedEntries: [String: OfflineReadingCacheManifestEntry]
    var phase: OfflineReadingCacheTransactionPhase
}

private struct OfflineReadingPackageRecord: Codable {
    let version: Int
    let cacheKey: String
    let provider: OfflineReadingProvider
    let pageKeys: [String]
    let voiceID: String
    let document: OfflineReadingDocumentRecord
    let audioByParagraph: [OfflineReadingParagraphAudioRecord]
    let createdAt: Date
    let updatedAt: Date
}

private struct OfflineReadingDocumentRecord: Codable {
    let id: String
    let title: String
    let sourceKind: ReadingSourceKind
    let language: String
    let paragraphs: [OfflineReadingParagraphRecord]
    let imageResource: OfflineReadingResourceRecord?
    let imagePixelSize: OfflineReadingSizeRecord?
    let sourceURL: String?
    let coverURL: String?
    let fileResource: OfflineReadingResourceRecord?
    let persistencePolicy: DocumentPersistencePolicy
    let effectiveFormat: SupportedDocumentFormat?
    let exportFormat: CloudExportFormat?
    let contentRevision: String?
    let contentSessionKey: String
    let layoutColumnCount: Int?
    let createdAt: Date
}

private struct OfflineReadingParagraphRecord: Codable {
    let id: Int
    let text: String
    let speechText: String?
    let speaker: String?
    let type: OfflineReadingParagraphTypeRecord
    let words: [OfflineReadingWordRecord]
    let bbox: OfflineReadingRectRecord?
    let visualFragments: [OfflineReadingFragmentRecord]
    let pdfPageIndex: Int?
    let pdfRange: OfflineReadingRangeRecord?
    let pageIndex: Int?
    let imageResource: OfflineReadingResourceRecord?
    let startMs: Int?
}

private struct OfflineReadingParagraphTypeRecord: Codable {
    let kind: String
    let headingLevel: Int?

    init(_ value: ReadingParagraphType) {
        switch value {
        case .paragraph: kind = "paragraph"; headingLevel = nil
        case let .heading(level): kind = "heading"; headingLevel = level
        case .blockquote: kind = "blockquote"; headingLevel = nil
        case .code: kind = "code"; headingLevel = nil
        case .list: kind = "list"; headingLevel = nil
        case .caption: kind = "caption"; headingLevel = nil
        case .image: kind = "image"; headingLevel = nil
        }
    }

    var value: ReadingParagraphType? {
        switch kind {
        case "paragraph": return .paragraph
        case "heading": return headingLevel.map(ReadingParagraphType.heading)
        case "blockquote": return .blockquote
        case "code": return .code
        case "list": return .list
        case "caption": return .caption
        case "image": return .image
        default: return nil
        }
    }
}

private struct OfflineReadingWordRecord: Codable {
    let id: Int
    let text: String
    let bbox: OfflineReadingRectRecord
}

private struct OfflineReadingFragmentRecord: Codable {
    let column: String
    let bbox: OfflineReadingRectRecord
    let wordIDs: [Int]
}

private struct OfflineReadingParagraphAudioRecord: Codable {
    let paragraphIndex: Int
    let segments: [OfflineReadingAudioSegmentRecord]
}

private struct OfflineReadingAudioSegmentRecord: Codable {
    let paragraphIndex: Int
    let segmentIndex: Int
    let audioResource: OfflineReadingResourceRecord
    let timestamps: [TTSTimestamp]
    let duration: Double
    let text: String
    let isWavFormat: Bool
    let unprocessedText: String
    let speaker: String?
}

private struct OfflineReadingResourceRecord: Codable {
    let digest: String
    let byteSize: Int64
}

private struct OfflineReadingRectRecord: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ value: CGRect) {
        x = Double(value.origin.x)
        y = Double(value.origin.y)
        width = Double(value.size.width)
        height = Double(value.size.height)
    }

    var value: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

private struct OfflineReadingSizeRecord: Codable {
    let width: Double
    let height: Double

    init(_ value: CGSize) {
        width = Double(value.width)
        height = Double(value.height)
    }

    var value: CGSize { CGSize(width: width, height: height) }
}

private struct OfflineReadingRangeRecord: Codable {
    let location: Int
    let length: Int

    init(_ value: NSRange) {
        location = value.location
        length = value.length
    }

    var value: NSRange { NSRange(location: location, length: length) }
}

private enum OfflineReadingCacheDigest {
    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func sha256(_ values: [String]) -> String {
        var data = Data()
        for value in values {
            let bytes = Data(value.utf8)
            data.append(Data(String(bytes.count).utf8))
            data.append(0x3A)
            data.append(bytes)
            data.append(0x0A)
        }
        return sha256(data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}
