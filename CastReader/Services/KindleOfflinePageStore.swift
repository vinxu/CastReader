import CryptoKit
import Foundation
import UIKit

/// Explicit saves live outside Caches and are never removed by an LRU policy.
/// Each capture is an independently confirmed occurrence, not proof of adjacency.
actor KindleOfflinePageStore {
    static let shared = KindleOfflinePageStore()
    enum Failure: Error { case invalidIdentity, invalidPage, corruptPage, unsupportedVersion, oversizedPage }

    struct SavedPage: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        let language: String
        let savedAt: Date
        let imageHash: String
        let snapshotHash: String
        let pageKeyHash: String
        let byteCount: Int
    }

    struct Checkpoint: Codable, Equatable {
        let snapshotHash: String
        let paragraphID: Int
        let sentenceStart: Int
        let voiceID: String
    }

    private struct Index: Codable {
        var version = 1
        var pages: [SavedPage] = []
    }

    private let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KindleOfflinePages", isDirectory: true)) { self.root = root }

    static func digest(_ value: String) -> String { digest(Data(value.utf8)) }
    static func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }

    func save(document: ReadingDocument, pageKey: String, scope: String) throws -> SavedPage {
        guard !pageKey.isEmpty, document.sourceKind == .kindle,
              let image = document.paragraphs.first(where: { $0.type == .image })?.imageData,
              document.paragraphs.filter({ $0.type == .image }).count == 1,
              UIImage(data: image) != nil else { throw Failure.invalidPage }
        guard image.count <= 20 * 1_024 * 1_024 else { throw Failure.oversizedPage }
        let directory = try directory(scope: scope, create: true)
        let snapshot = Snapshot(document: document)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(snapshot)
        guard bytes.count <= 2 * 1_024 * 1_024 else { throw Failure.oversizedPage }
        let imageHash = Self.digest(image), snapshotHash = Self.digest(bytes)
        let keyHash = Self.digest(pageKey)
        let id = Self.digest(keyHash + ":" + imageHash + ":" + snapshotHash)
        var index = try readIndex(directory)
        if let prior = index.pages.first(where: { $0.id == id }) {
            // Explicitly saving a damaged item repairs it with the new capture.
            try write(image, to: directory.appendingPathComponent(imageHash + ".image"))
            try write(bytes, to: directory.appendingPathComponent(snapshotHash + ".page"))
            return prior
        }
        let record = SavedPage(id: id, title: document.title, language: document.language, savedAt: Date(),
            imageHash: imageHash, snapshotHash: snapshotHash, pageKeyHash: keyHash, byteCount: image.count + bytes.count)
        // The index is the commit point. A kill/disk-full before it leaves only
        // unreferenced immutable files; existing saves and progress stay intact.
        try write(image, to: directory.appendingPathComponent(imageHash + ".image"))
        try write(bytes, to: directory.appendingPathComponent(snapshotHash + ".page"))
        index.pages.append(record)
        let indexBytes = try encoder.encode(index)
        guard indexBytes.count <= 4 * 1_024 * 1_024 else { throw Failure.oversizedPage }
        try write(indexBytes, to: directory.appendingPathComponent("index.json"))
        return record
    }

    func list(scope: String) throws -> [SavedPage] {
        try readIndex(directory(scope: scope, create: false)).pages.sorted { $0.savedAt > $1.savedAt }
    }

    func open(_ id: String, scope: String) throws -> (SavedPage, ReadingDocument) {
        let directory = try directory(scope: scope, create: false)
        guard let page = try readIndex(directory).pages.first(where: { $0.id == id }),
              Self.validDigest(page.imageHash), Self.validDigest(page.snapshotHash) else { throw Failure.invalidPage }
        let image = try readLimited(directory.appendingPathComponent(page.imageHash + ".image"), limit: 20 * 1_024 * 1_024)
        let bytes = try readLimited(directory.appendingPathComponent(page.snapshotHash + ".page"), limit: 2 * 1_024 * 1_024)
        guard Self.digest(image) == page.imageHash, Self.digest(bytes) == page.snapshotHash,
              UIImage(data: image) != nil else { throw Failure.corruptPage }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: bytes)
        guard snapshot.version == 1 else { throw Failure.unsupportedVersion }
        return (page, snapshot.document(id: page.id, title: page.title, image: image))
    }

    func saveCheckpoint(_ checkpoint: Checkpoint, pageID: String, scope: String) throws {
        let directory = try directory(scope: scope, create: false)
        guard checkpoint.paragraphID >= 0, checkpoint.sentenceStart >= 0,
              let page = try readIndex(directory).pages.first(where: { $0.id == pageID }),
              page.snapshotHash == checkpoint.snapshotHash else { throw Failure.invalidPage }
        try write(JSONEncoder().encode(checkpoint), to: directory.appendingPathComponent(page.id + ".position"))
    }

    func checkpoint(pageID: String, scope: String) throws -> Checkpoint? {
        let directory = try directory(scope: scope, create: false)
        guard let page = try readIndex(directory).pages.first(where: { $0.id == pageID }) else { throw Failure.invalidPage }
        let url = directory.appendingPathComponent(page.id + ".position")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let value = try JSONDecoder().decode(Checkpoint.self, from: readLimited(url, limit: 32_768))
        guard value.snapshotHash == page.snapshotHash, value.paragraphID >= 0, value.sentenceStart >= 0 else { return nil }
        return value
    }

    private static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func directory(scope: String, create: Bool) throws -> URL {
        guard Self.validDigest(scope) else { throw Failure.invalidIdentity }
        var directory = root.appendingPathComponent(scope, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
        }
        return directory
    }

    private func readIndex(_ directory: URL) throws -> Index {
        let url = directory.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return Index() }
        let index = try JSONDecoder().decode(Index.self, from: readLimited(url, limit: 4 * 1_024 * 1_024))
        guard index.version == 1 else { throw Failure.unsupportedVersion }
        guard index.pages.allSatisfy({ Self.validDigest($0.id) && Self.validDigest($0.imageHash) && Self.validDigest($0.snapshotHash) }),
              Set(index.pages.map(\.id)).count == index.pages.count else { throw Failure.corruptPage }
        return index
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func readLimited(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
        guard size <= limit else { throw Failure.oversizedPage }
        return try Data(contentsOf: url)
    }

    private struct Snapshot: Codable {
        var version = 1
        let language: String
        let paragraphs: [Paragraph]
        init(document: ReadingDocument) {
            language = document.language
            paragraphs = document.paragraphs.filter { $0.type != .image }.map(Paragraph.init)
        }
        func document(id: String, title: String, image: Data) -> ReadingDocument {
            ReadingDocument(id: id, title: title, sourceKind: .kindle, language: language,
                paragraphs: [ReadingParagraph(id: 0, text: "", type: .image, pageIndex: 0, imageData: image)] +
                    paragraphs.enumerated().map { $0.element.value(id: $0.offset + 1) })
        }
    }

    private struct Paragraph: Codable {
        let text: String
        let kind: String
        let heading: Int?
        let words: [Word]
        let box: CGRect?
        let fragments: [Fragment]
        init(_ value: ReadingParagraph) {
            text = value.text; box = value.bboxNorm; words = value.words.map(Word.init)
            fragments = value.visualFragments.map { Fragment(column: $0.column.rawValue, box: $0.bboxNorm, wordIDs: $0.wordIDs) }
            switch value.type {
            case .heading(let level): kind = "heading"; heading = level
            case .blockquote: kind = "blockquote"; heading = nil
            case .code: kind = "code"; heading = nil
            case .list: kind = "list"; heading = nil
            case .caption: kind = "caption"; heading = nil
            default: kind = "paragraph"; heading = nil
            }
        }
        func value(id: Int) -> ReadingParagraph {
            let type: ReadingParagraphType
            switch kind {
            case "heading": type = .heading(heading ?? 1)
            case "blockquote": type = .blockquote
            case "code": type = .code
            case "list": type = .list
            case "caption": type = .caption
            default: type = .paragraph
            }
            return ReadingParagraph(id: id, text: text, type: type, words: words.map(\.value), bboxNorm: box,
                visualFragments: fragments.map { OCRVisualFragment(column: .init(rawValue: $0.column) ?? .single, bboxNorm: $0.box, wordIDs: $0.wordIDs) }, pageIndex: 0)
        }
    }
    private struct Fragment: Codable { let column: String; let box: CGRect; let wordIDs: [Int] }
    private struct Word: Codable {
        let id: Int; let text: String; let box: CGRect; let source: String
        let line: Int?; let confidence: Float?; let inkBox: CGRect?; let inkChecked: Bool
        init(_ word: OCRWord) {
            id = word.id; text = word.text; box = word.bboxNorm; source = word.bboxSource.rawValue
            line = word.sourceLineID; confidence = word.recognitionConfidence
            inkBox = word.inkBoundsNorm; inkChecked = word.inkBoundsChecked
        }
        var value: OCRWord { OCRWord(id: id, text: text, bboxNorm: box, bboxSource: .init(rawValue: source) ?? .unknown,
            sourceLineID: line, recognitionConfidence: confidence, inkBoundsNorm: inkBox, inkBoundsChecked: inkChecked) }
    }
}
