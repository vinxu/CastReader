import Foundation
import LinkPresentation
import UniformTypeIdentifiers
import UIKit

enum ShareInboxMode: String, Codable {
    case read
    case explain
}

enum ShareInboxKind: String, Codable {
    case url
    case text
    case image
    case pdf
    case epub
    case docx
}

enum ShareInboxFallbackTitle: String, Codable {
    case document
    case text
    case image
}

struct ShareInboxRecord: Codable, Identifiable {
    let id: UUID
    let createdAt: Date
    let kind: ShareInboxKind
    let mode: ShareInboxMode
    let title: String
    let fallbackTitle: ShareInboxFallbackTitle?
    let payloadFilename: String?
    let sourceURL: String?
    let previewImageFilename: String?
    let linkMetadataFetchedAt: Date?

    init(
        id: UUID,
        createdAt: Date,
        kind: ShareInboxKind,
        mode: ShareInboxMode,
        title: String,
        fallbackTitle: ShareInboxFallbackTitle? = nil,
        payloadFilename: String?,
        sourceURL: String?,
        previewImageFilename: String?,
        linkMetadataFetchedAt: Date?
    ) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.mode = mode
        self.title = title
        self.fallbackTitle = fallbackTitle
        self.payloadFilename = payloadFilename
        self.sourceURL = sourceURL
        self.previewImageFilename = previewImageFilename
        self.linkMetadataFetchedAt = linkMetadataFetchedAt
    }
}

/// A share provider may expose a post caption and its URL as one plain-text value.
/// Normalize that input at the boundary so the containing app opens the actual page
/// instead of reading the caption and URL aloud as ordinary text.
enum ShareInboxLinkExtractor {
    static func firstWebURL(in text: String) -> URL? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        return detector.matches(in: text, options: [], range: range)
            .compactMap(\.url)
            .first(where: isReadableWebURL)
    }

    static func isReadableWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}

struct ShareInboxLinkMetadata {
    let title: String?
    let previewImageData: Data?
}

/// LinkPresentation is intentionally used only for inbox presentation. Reading still
/// opens the original URL through the normal web-document path, so metadata failure is
/// never allowed to block an import.
enum ShareInboxLinkMetadataLoader {
    static func fetch(for url: URL) async -> ShareInboxLinkMetadata? {
        guard ShareInboxLinkExtractor.isReadableWebURL(url) else { return nil }
        let provider = LPMetadataProvider()
        provider.timeout = 8
        let metadata: LPLinkMetadata? = await withCheckedContinuation { continuation in
            provider.startFetchingMetadata(for: url) { metadata, _ in
                continuation.resume(returning: metadata)
            }
        }
        guard let metadata else { return nil }
        let imageData = await loadPreviewData(from: metadata.imageProvider ?? metadata.iconProvider)
        let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ShareInboxLinkMetadata(
            title: title?.isEmpty == false ? title : nil,
            previewImageData: imageData
        )
    }

    private static func loadPreviewData(from provider: NSItemProvider?) async -> Data? {
        guard let provider,
              provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { return nil }
        let data: Data? = await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
        guard let data, let image = UIImage(data: data) else { return nil }
        return image.jpegData(compressionQuality: 0.82)
    }
}

/// App Group-backed handoff shared by the Share Extension and the containing app.
/// Each record is an independent atomic JSON file, so an extension and the app never rewrite
/// the same queue manifest concurrently.
enum ShareInboxStore {
    static let appGroup = "group.com.same.castreader"
    private static let directoryName = "ShareInbox"
    private static let maximumItemCount = 50
    private static let maximumPayloadBytes: Int64 = 300 * 1024 * 1024
    private static let lastSeenDefaultsKey = "shareInbox.lastSeenAt"

    static func enqueue(
        kind: ShareInboxKind,
        mode: ShareInboxMode,
        title: String,
        fallbackTitle: ShareInboxFallbackTitle? = nil,
        payload: Data? = nil,
        payloadExtension: String? = nil,
        sourceURL: String? = nil
    ) throws {
        let directory = try inboxDirectory()
        let id = UUID()
        var payloadFilename: String?
        if let payload {
            let ext = payloadExtension?.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let filename = ext.flatMap { $0.isEmpty ? nil : "\(id.uuidString).\($0)" } ?? id.uuidString
            try payload.write(to: directory.appendingPathComponent(filename), options: .atomic)
            payloadFilename = filename
        }
        let record = ShareInboxRecord(
            id: id,
            createdAt: Date(),
            kind: kind,
            mode: mode,
            title: title,
            fallbackTitle: fallbackTitle,
            payloadFilename: payloadFilename,
            sourceURL: sourceURL,
            previewImageFilename: nil,
            linkMetadataFetchedAt: nil
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)
        pruneOldestItemsIfNeeded()
    }

    static func pending() -> [(record: ShareInboxRecord, metadataURL: URL)] {
        guard let directory = try? inboxDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> (ShareInboxRecord, URL)? in
                guard let data = try? Data(contentsOf: url),
                      let record = try? JSONDecoder().decode(ShareInboxRecord.self, from: data) else { return nil }
                return (record, url)
            }
            .sorted { $0.0.createdAt > $1.0.createdAt }
    }

    /// The Home badge represents unseen arrivals, not the total number of saved items.
    /// Keeping the read cursor in the App Group makes the state survive app relaunches
    /// without deleting anything from the inbox.
    static func unreadCount(in records: [ShareInboxRecord]) -> Int {
        let lastSeenAt = UserDefaults(suiteName: appGroup)?.object(forKey: lastSeenDefaultsKey) as? Date
        return unreadCount(in: records, lastSeenAt: lastSeenAt)
    }

    static func unreadCount(in records: [ShareInboxRecord], lastSeenAt: Date?) -> Int {
        guard let lastSeenAt else { return records.count }
        return records.reduce(into: 0) { count, record in
            if record.createdAt > lastSeenAt { count += 1 }
        }
    }

    static func markAllSeen(_ records: [ShareInboxRecord]) {
        guard let newestCreatedAt = records.map(\.createdAt).max(),
              let defaults = UserDefaults(suiteName: appGroup) else { return }
        let existing = defaults.object(forKey: lastSeenDefaultsKey) as? Date
        if existing.map({ newestCreatedAt > $0 }) ?? true {
            defaults.set(newestCreatedAt, forKey: lastSeenDefaultsKey)
        }
    }

    static func payloadURL(for record: ShareInboxRecord) -> URL? {
        guard let filename = record.payloadFilename,
              let directory = try? inboxDirectory() else { return nil }
        return directory.appendingPathComponent(filename)
    }

    static func previewImageURL(for record: ShareInboxRecord) -> URL? {
        guard let filename = record.previewImageFilename,
              let directory = try? inboxDirectory() else { return nil }
        return directory.appendingPathComponent(filename)
    }

    /// Persist presentation metadata independently from the source URL. A failed fetch is
    /// recorded as attempted to avoid retrying on every foreground transition.
    @discardableResult
    static func updateLinkMetadata(
        for record: ShareInboxRecord,
        metadataURL: URL,
        title: String?,
        previewImageData: Data?
    ) throws -> ShareInboxRecord {
        let directory = try inboxDirectory()
        var previewImageFilename = record.previewImageFilename
        if let previewImageData, !previewImageData.isEmpty {
            let filename = "\(record.id.uuidString)-preview.jpg"
            try previewImageData.write(to: directory.appendingPathComponent(filename), options: .atomic)
            previewImageFilename = filename
        }
        let cleanedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = ShareInboxRecord(
            id: record.id,
            createdAt: record.createdAt,
            kind: record.kind,
            mode: record.mode,
            title: cleanedTitle?.isEmpty == false ? cleanedTitle! : record.title,
            fallbackTitle: cleanedTitle?.isEmpty == false ? nil : record.fallbackTitle,
            payloadFilename: record.payloadFilename,
            sourceURL: record.sourceURL,
            previewImageFilename: previewImageFilename,
            linkMetadataFetchedAt: Date()
        )
        try JSONEncoder().encode(updated).write(to: metadataURL, options: .atomic)
        pruneOldestItemsIfNeeded()
        return updated
    }

    static func remove(_ record: ShareInboxRecord, metadataURL: URL) {
        if let payload = payloadURL(for: record) { try? FileManager.default.removeItem(at: payload) }
        if let preview = previewImageURL(for: record) { try? FileManager.default.removeItem(at: preview) }
        try? FileManager.default.removeItem(at: metadataURL)
    }

    private static func pruneOldestItemsIfNeeded() {
        var items = Array(pending().reversed())
        func payloadBytes() -> Int64 {
            items.reduce(into: 0) { total, item in
                [payloadURL(for: item.record), previewImageURL(for: item.record)].compactMap { $0 }.forEach { url in
                    guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                          let size = values.fileSize else { return }
                    total += Int64(size)
                }
            }
        }
        while items.count > maximumItemCount || payloadBytes() > maximumPayloadBytes {
            guard !items.isEmpty else { break }
            let oldest = items.removeFirst()
            remove(oldest.record, metadataURL: oldest.metadataURL)
        }
    }

    private static func inboxDirectory() throws -> URL {
        guard let root = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroup
        ) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let directory = root.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

extension Notification.Name {
    static let castReaderShareInboxChanged = Notification.Name("castreader.shareInbox.changed")
}
