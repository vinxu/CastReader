import Foundation

/// Disposable parsed content for user-owned PDF/EPUB files. Checkpoints remain
/// independent. Never used for cloud references or connected-library content.
enum LocalDocumentCache {
    // Bump when PDF extraction, OCR reflow or EPUB paragraph semantics change.
    static let parserVersion = 3
    static let maximumSnapshotBytes = 32 * 1_024 * 1_024
    static let maximumDirectoryBytes = 128 * 1_024 * 1_024

    struct Snapshot: Codable {
        struct Paragraph: Codable {
            let text: String
            let kind: String
            let heading: Int?
            let page: Int?
            let range: NSRange?
            let image: Int?
        }
        let version: Int
        let source: String
        let payloadFingerprint: String
        let language: String
        let paragraphs: [Paragraph]
        let images: [Data]
        let resumeIndex: ReadingResumeDocumentIndex
        let epubNavigation: EpubNavigation?

        init?(document: ReadingDocument, fingerprint: String) throws {
            guard supports(document.sourceKind), document.origin == nil,
                  document.persistencePolicy == .localPayload,
                  !document.paragraphs.isEmpty else { return nil }
            version = parserVersion
            source = document.sourceKind.rawValue
            payloadFingerprint = fingerprint
            language = document.language
            epubNavigation = document.epubNavigation
            resumeIndex = document.precomputedResumeIndex ?? ReadingResumeDocumentIndex(paragraphs: document.paragraphs)
            var images: [Data] = [], imageIDs: [String: Int] = [:]
            var paragraphs: [Paragraph] = []
            var bytes = 0
            for (index, p) in document.paragraphs.enumerated() {
                try Task.checkCancellation()
                // Reject richer inputs rather than silently dropping geometry.
                guard p.id == index, p.words.isEmpty, p.bboxNorm == nil,
                      p.visualFragments.isEmpty, p.speechText == nil,
                      p.speaker == nil, p.pageIndex == nil, p.startMs == nil else { return nil }
                var image: Int?
                if let data = p.imageData {
                    let key = ReadingResumeContract.fingerprint(data)
                    if let prior = imageIDs[key] { image = prior }
                    else {
                        image = images.count
                        imageIDs[key] = image
                        images.append(data)
                        bytes += data.count
                    }
                }
                let kind: String, heading: Int?
                switch p.type {
                case .paragraph: kind = "paragraph"; heading = nil
                case .heading(let level): kind = "heading"; heading = level
                case .blockquote: kind = "blockquote"; heading = nil
                case .code: kind = "code"; heading = nil
                case .list: kind = "list"; heading = nil
                case .caption: kind = "caption"; heading = nil
                case .image: kind = "image"; heading = nil
                }
                bytes += p.text.utf8.count + 128
                guard bytes <= maximumSnapshotBytes else { return nil }
                paragraphs.append(Paragraph(text: p.text, kind: kind, heading: heading,
                                            page: p.pdfPageIndex, range: p.pdfRange, image: image))
            }
            self.paragraphs = paragraphs
            self.images = images
        }

        func document(record: HistoryRecord, data: Data, fingerprint: String) throws -> ReadingDocument? {
            guard version == parserVersion, source == record.sourceKindRaw,
                  payloadFingerprint == fingerprint, !paragraphs.isEmpty,
                  resumeIndex.fingerprints.count == paragraphs.count,
                  resumeIndex.fingerprints.allSatisfy({ $0.count == 64 }),
                  resumeIndex.readable.allSatisfy({ paragraphs.indices.contains($0) }),
                  resumeIndex.fingerprint == ReadingResumeContract.fingerprint(resumeIndex.fingerprints.joined(separator: ":")),
                  !record.requiresRemoteReopen else { return nil }
            var result: [ReadingParagraph] = []
            result.reserveCapacity(paragraphs.count)
            for (index, p) in paragraphs.enumerated() {
                try Task.checkCancellation()
                let type: ReadingParagraphType
                switch p.kind {
                case "paragraph": type = .paragraph
                case "heading":
                    guard let level = p.heading, (1...6).contains(level) else { return nil }
                    type = .heading(level)
                case "blockquote": type = .blockquote
                case "code": type = .code
                case "list": type = .list
                case "caption": type = .caption
                case "image": type = .image
                default: return nil
                }
                if let image = p.image, !images.indices.contains(image) { return nil }
                if type == .image && p.image == nil { return nil }
                if let page = p.page, page < 0 { return nil }
                if let range = p.range,
                   range.location < 0 || range.length < 0 || range.location > Int.max - range.length { return nil }
                result.append(ReadingParagraph(id: index, text: p.text, type: type,
                    pdfPageIndex: p.page, pdfRange: p.range, imageData: p.image.map { images[$0] }))
            }
            var document = ReadingDocument(id: record.id, title: record.title, sourceKind: record.sourceKind,
                language: language, paragraphs: result, fileData: data)
            if record.sourceKind == .epub, let epubNavigation {
                guard epubNavigation.isValid(paragraphCount: result.count) else { return nil }
                document.epubNavigation = epubNavigation
            }
            document.precomputedResumeIndex = resumeIndex
            return document
        }
    }

    struct Loaded {
        let document: ReadingDocument
        let fingerprint: String
        let preparedSnapshot: URL?
        let cacheHit: Bool
    }

    static func supports(_ kind: ReadingSourceKind) -> Bool { kind == .epub || kind == .pdf }

    static func directory(in history: URL) -> URL {
        history.appendingPathComponent("ParsedDocuments", isDirectory: true)
    }

    static func url(id: String, in history: URL) -> URL {
        directory(in: history).appendingPathComponent(ReadingResumeContract.fingerprint(id) + ".parsed")
    }

    /// Only file reads, hashing and parsing run here, on a detached worker.
    static func load(record: HistoryRecord, payloadURL: URL, cacheURL: URL) async throws -> Loaded? {
        try Task.checkCancellation()
        guard supports(record.sourceKind), !record.requiresRemoteReopen,
              let values = try? payloadURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size >= 0,
              Int64(size) <= DocumentResourceLimits.maximumInputBytes,
              let data = try? Data(contentsOf: payloadURL, options: .mappedIfSafe) else { return nil }
        let start = Date()
        let fingerprint = ReadingResumeContract.fingerprint(data)
        if let values = try? cacheURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
           values.isRegularFile == true, let size = values.fileSize,
           size <= maximumSnapshotBytes,
           let encoded = try? Data(contentsOf: cacheURL),
           let snapshot = try? PropertyListDecoder().decode(Snapshot.self, from: encoded),
           let document = try snapshot.document(record: record, data: data, fingerprint: fingerprint) {
            ReaderRunLog.write("LOCAL reopen cache=hit source=\(record.sourceKindRaw) paragraphs=\(document.paragraphs.count) seconds=\(Date().timeIntervalSince(start))")
            return Loaded(document: document, fingerprint: fingerprint, preparedSnapshot: nil, cacheHit: true)
        }
        try Task.checkCancellation()
        let parsed: ReadingDocument?
        if record.sourceKind == .epub {
            parsed = try DocumentBuilder.fromEPUBCancellable(data: data, title: record.title)
        } else {
            parsed = try await DocumentBuilder.fromPDFWithOCR(data: data, title: record.title, fallbackTitle: record.title)
        }
        try Task.checkCancellation()
        guard var document = parsed else { return nil }
        document.id = record.id
        document.title = record.title
        document.precomputedResumeIndex = ReadingResumeDocumentIndex(paragraphs: document.paragraphs)
        let parseSeconds = Date().timeIntervalSince(start)
        let prepared = try prepare(document: document, fingerprint: fingerprint)
        ReaderRunLog.write("LOCAL reopen cache=miss source=\(record.sourceKindRaw) paragraphs=\(document.paragraphs.count) parseSeconds=\(parseSeconds) totalSeconds=\(Date().timeIntervalSince(start))")
        return Loaded(document: document, fingerprint: fingerprint, preparedSnapshot: prepared, cacheHit: false)
    }

    /// Encode away from MainActor. Publish only after rechecking account/record.
    static func prepare(document: ReadingDocument, fingerprint: String) throws -> URL? {
        guard let snapshot = try Snapshot(document: document, fingerprint: fingerprint) else { return nil }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(snapshot)
        guard data.count <= maximumSnapshotBytes else { return nil }
        try Task.checkCancellation()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".parsed")
        do {
            try data.write(to: temporary, options: .atomic)
            try Task.checkCancellation()
            return temporary
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            if error is CancellationError { throw error }
            return nil // Cache storage failure must not prevent reading.
        }
    }

    @MainActor
    static func publish(_ temporary: URL, to destination: URL) {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: temporary) }
        var directory = destination.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
            if fm.fileExists(atPath: destination.path) {
                _ = try fm.replaceItemAt(destination, withItemAt: temporary)
            } else { try fm.moveItem(at: temporary, to: destination) }
            prune(directory: directory, keeping: destination)
        } catch { ReaderRunLog.write("LOCAL parsed cache write failed") }
    }

    @MainActor
    private static func prune(directory: URL, keeping: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries where total > maximumDirectoryBytes && url != keeping {
            if (try? FileManager.default.removeItem(at: url)) != nil { total -= size }
        }
    }
}
