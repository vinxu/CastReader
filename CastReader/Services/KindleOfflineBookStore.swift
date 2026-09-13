import Foundation

/// Source positions are renderer coordinates, independent of Kindle's rounded
/// location labels and of the number of images in the live prefetch window.
struct KindleOfflineSourcePosition: Codable, Equatable {
    let start: Int
    let end: Int
    let minimum: Int
    let maximum: Int
    let layoutID: String
    let fingerprint: String

    var isValid: Bool {
        minimum >= 0 && maximum > minimum && maximum < Int.max && start >= minimum && end >= start &&
            end <= maximum && !layoutID.isEmpty && !fingerprint.isEmpty
    }
    var isFirst: Bool { start == minimum }
    var isLast: Bool { end == maximum }

    func follows(_ previous: Self) -> Bool {
        isValid && previous.isValid && layoutID == previous.layoutID &&
            minimum == previous.minimum && maximum == previous.maximum &&
            // Source adapters may share a normalized boundary or use adjacent
            // inclusive ranges. Interior overlap is never a next page.
            start > previous.start && end > previous.end && start >= previous.end && start <= previous.end + 1
    }
}

struct KindleOfflineBook: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case preparing, paused, verifying, complete, failed }
    struct Page: Codable, Equatable {
        let ordinal: Int
        let position: KindleOfflineSourcePosition
        let resource: KindleOfflinePageStore.SavedPage
        // Absent in v1 downloads whose OCR was already committed with the image.
        var requiresOCR: Bool?
        var sourceWordCount: Int?
    }
    struct ReadingPosition: Codable, Equatable {
        var page = 0
        var paragraphID = 1
        var sentenceStart = 0
        var voiceID = ""
        var speechRate: Double?
    }

    var version = 1
    let id: String
    let sourceBookID: String
    let title: String
    let author: String
    let generation: UUID
    let createdAt: Date
    var updatedAt: Date
    var language: String
    var status: Status
    var pages: [Page]
    var originalPosition: KindleOfflineSourcePosition?
    var originalPositionRestored = false
    var lastError: String?
    var readingPosition = ReadingPosition()
    var hasLocalReadingPosition: Bool?
    var sourceBook: KindleBook?

    var downloadFraction: Double {
        guard let position = pages.last?.position, position.maximum > position.minimum else { return 0 }
        return min(1, max(0, Double(position.end - position.minimum) / Double(position.maximum - position.minimum)))
    }
    var byteCount: Int { pages.reduce(0) { $0 + $1.resource.byteCount } }
    var coverageIsContinuous: Bool {
        guard let first = pages.first, first.ordinal == 0, first.position.isValid, first.position.isFirst else { return false }
        for index in pages.indices.dropFirst() {
            guard pages[index].ordinal == index, pages[index].position.follows(pages[index - 1].position) else { return false }
        }
        return true
    }
    var coversWholeBook: Bool { coverageIsContinuous && pages.last?.position.isLast == true }
}

/// The book manifest is the commit point. Each page uses the existing verified
/// image/OCR store; the manifest never loads the images of other pages.
actor KindleOfflineBookStore {
    static let shared = KindleOfflineBookStore()
    static let didChange = Notification.Name("KindleOfflineBooksDidChange")
    #if DEBUG
    static let imageBenchmark = KindleOfflineBookStore(root: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KindleOfflineImageBenchmark-v5", isDirectory: true))
    #endif
    enum Failure: Error { case invalidIdentity, corruptManifest, staleGeneration, discontinuousPage, incompleteBook }
    private let root: URL
    init(root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("KindleOfflineBooks", isDirectory: true)) { self.root = root }

    static func bookID(_ sourceBookID: String) -> String { KindleOfflinePageStore.digest(sourceBookID) }

    func list(scope: String) throws -> [KindleOfflineBook] {
        let directory = try scopeDirectory(scope, create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "book" }
            .compactMap { try? read($0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Remove only this account's local copy. Invalidate the manifest first so
    /// a late OCR/checkpoint task cannot recreate a deleted generation.
    func remove(id: String, scope: String) throws {
        defer { notifyChange(scope: scope) }
        let manifest = try manifestURL(id: id, scope: scope)
        if FileManager.default.fileExists(atPath: manifest.path) { try FileManager.default.removeItem(at: manifest) }
        let resources = try scopeDirectory(scope, create: false).appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: resources.path) { try FileManager.default.removeItem(at: resources) }
    }

    func unreadableBookIDs(scope: String) throws -> [String] {
        let directory = try scopeDirectory(scope, create: false)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "book" && validID($0.deletingPathExtension().lastPathComponent) }
            .filter { (try? read($0)) == nil }.map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    func load(id: String, scope: String) throws -> KindleOfflineBook? {
        let url = try manifestURL(id: id, scope: scope)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try read(url)
    }

    func prepare(source: KindleBook, scope: String, originalPosition: KindleOfflineSourcePosition) throws -> KindleOfflineBook {
        guard originalPosition.isValid else { throw Failure.discontinuousPage }
        let id = Self.bookID(source.id)
        if var prior = try load(id: id, scope: scope) {
            // Resume only within the same confirmed layout/content coordinate space.
            if let first = prior.pages.first,
               first.position.layoutID != originalPosition.layoutID || first.position.maximum != originalPosition.maximum {
                throw Failure.staleGeneration
            }
            prior.sourceBook = source
            if prior.status != .complete {
                prior.originalPosition = originalPosition
                prior.originalPositionRestored = false
                prior.status = .preparing
                prior.lastError = nil
                try persist(prior, scope: scope)
            }
            return prior
        }
        let now = Date()
        var book = KindleOfflineBook(id: id, sourceBookID: source.id, title: source.title, author: source.author,
            generation: UUID(), createdAt: now, updatedAt: now, language: source.language ?? "en",
            status: .preparing, pages: [], originalPosition: originalPosition)
        book.sourceBook = source
        try persist(book, scope: scope)
        return book
    }

    func append(document: ReadingDocument, position: KindleOfflineSourcePosition,
                to expected: KindleOfflineBook, scope: String, requiresOCR: Bool = false,
                sourceWordCount: Int? = nil) async throws -> KindleOfflineBook {
        var book = try current(expected, scope: scope)
        guard position.isValid, book.status != .complete else { throw Failure.discontinuousPage }
        if let last = book.pages.last {
            guard position.follows(last.position) else { throw Failure.discontinuousPage }
        } else {
            guard position.isFirst else { throw Failure.discontinuousPage }
        }
        let ordinal = book.pages.count
        let repository = try pageRepository(book, scope: scope)
        let resource = try await repository.save(document: document,
            pageKey: "\(book.generation.uuidString):\(ordinal):\(position.start):\(position.end)", scope: book.id)
        // An actor suspension must not let a stale capture overwrite newer state.
        let fresh = try current(expected, scope: scope)
        guard fresh.pages.count == ordinal else { throw Failure.staleGeneration }
        book = fresh
        book.pages.append(.init(ordinal: ordinal, position: position, resource: resource,
            requiresOCR: requiresOCR, sourceWordCount: sourceWordCount))
        if book.hasLocalReadingPosition != true, let original = book.originalPosition,
           position.start <= original.start, position.end >= original.start {
            book.readingPosition.page = ordinal
        }
        book.language = document.language
        book.status = .preparing
        book.lastError = nil
        try persist(book, scope: scope)
        return book
    }

    func openPage(book expected: KindleOfflineBook, ordinal: Int, scope: String) async throws -> ReadingDocument {
        let book = try current(expected, scope: scope)
        guard book.pages.indices.contains(ordinal) else { throw Failure.incompleteBook }
        let (_, document) = try await pageRepository(book, scope: scope).open(book.pages[ordinal].resource.id, scope: book.id)
        return document
    }

    func cachedSpeechPage(book expected: KindleOfflineBook, ordinal: Int, scope: String) async throws -> ReadingDocument? {
        let book = try current(expected, scope: scope)
        guard book.pages.indices.contains(ordinal) else { throw Failure.incompleteBook }
        let page = book.pages[ordinal]
        if page.requiresOCR != true { return try await openPage(book: book, ordinal: ordinal, scope: scope) }
        let cached = try await pageRepository(book, scope: scope).recognition(for: page.resource, language: book.language, scope: book.id)
        if let cached, page.sourceWordCount != 0, !Self.hasRecognizedText(cached) { return nil }
        return cached
    }

    func saveSpeechPage(_ document: ReadingDocument, book expected: KindleOfflineBook, ordinal: Int, scope: String) async throws {
        let book = try current(expected, scope: scope)
        guard book.pages.indices.contains(ordinal) else { throw Failure.incompleteBook }
        if book.pages[ordinal].requiresOCR == true, book.pages[ordinal].sourceWordCount != 0, !Self.hasRecognizedText(document) {
            throw OCRError.noText
        }
        try await pageRepository(book, scope: scope).saveRecognition(document, for: book.pages[ordinal].resource,
            language: book.language, scope: book.id)
    }

    private static func hasRecognizedText(_ document: ReadingDocument) -> Bool {
        document.paragraphs.contains { $0.type.isReadable && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    func finish(_ expected: KindleOfflineBook, scope: String) async throws -> KindleOfflineBook {
        var book = try current(expected, scope: scope)
        guard book.coversWholeBook else { throw Failure.incompleteBook }
        book.status = .verifying
        try persist(book, scope: scope)
        let repository = try pageRepository(book, scope: scope)
        try await repository.verify(book.pages.map(\.resource), scope: book.id)
        try Task.checkCancellation()
        let fresh = try current(expected, scope: scope)
        guard fresh.pages == book.pages else { throw Failure.staleGeneration }
        book = fresh
        book.status = .complete
        book.lastError = nil
        try persist(book, scope: scope)
        notifyChange(scope: scope)
        return book
    }

    func setStatus(_ status: KindleOfflineBook.Status, error: String?, book expected: KindleOfflineBook,
                   scope: String, originalRestored: Bool? = nil) throws -> KindleOfflineBook {
        var book = try current(expected, scope: scope)
        // Completion may only be established by finish after verifying resources.
        guard status != .complete || book.status == .complete else { throw Failure.incompleteBook }
        book.status = status
        book.lastError = error
        if let originalRestored { book.originalPositionRestored = originalRestored }
        try persist(book, scope: scope)
        notifyChange(scope: scope)
        return book
    }

    func saveReadingPosition(_ value: KindleOfflineBook.ReadingPosition, book expected: KindleOfflineBook,
                             scope: String) throws {
        var book = try current(expected, scope: scope)
        guard book.pages.indices.contains(value.page), value.paragraphID >= 0, value.sentenceStart >= 0 else {
            throw Failure.incompleteBook
        }
        book.readingPosition = value
        book.hasLocalReadingPosition = true
        try persist(book, scope: scope)
        notifyChange(scope: scope)
    }

    private func notifyChange(scope: String) {
        NotificationCenter.default.post(name: Self.didChange, object: self, userInfo: ["scope": scope])
    }

    private func current(_ expected: KindleOfflineBook, scope: String) throws -> KindleOfflineBook {
        guard let book = try load(id: expected.id, scope: scope), book.generation == expected.generation else {
            throw Failure.staleGeneration
        }
        return book
    }

    private func pageRepository(_ book: KindleOfflineBook, scope: String) throws -> KindleOfflinePageStore {
        let directory = try scopeDirectory(scope, create: false)
            .appendingPathComponent(book.id, isDirectory: true)
            .appendingPathComponent(book.generation.uuidString, isDirectory: true)
        return KindleOfflinePageStore(root: directory)
    }

    private func persist(_ value: KindleOfflineBook, scope: String) throws {
        var book = value
        book.updatedAt = Date()
        let directory = try scopeDirectory(scope, create: true)
        guard validID(book.id) else { throw Failure.invalidIdentity }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(book)
        guard bytes.count <= 8 * 1_024 * 1_024 else { throw Failure.corruptManifest }
        try bytes.write(to: directory.appendingPathComponent(book.id + ".book"),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func read(_ url: URL) throws -> KindleOfflineBook {
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 8 * 1_024 * 1_024 else {
            throw Failure.corruptManifest
        }
        let book = try JSONDecoder().decode(KindleOfflineBook.self, from: Data(contentsOf: url))
        guard book.version == 1, validID(book.id), book.id == url.deletingPathExtension().lastPathComponent,
              book.pages.isEmpty || book.coverageIsContinuous,
              book.status != .complete || book.coversWholeBook else { throw Failure.corruptManifest }
        for page in book.pages {
            let key = "\(book.generation.uuidString):\(page.ordinal):\(page.position.start):\(page.position.end)"
            let keyHash = KindleOfflinePageStore.digest(key)
            guard page.resource.pageKeyHash == keyHash,
                  page.resource.id == KindleOfflinePageStore.digest(keyHash + ":" + page.resource.imageHash + ":" + page.resource.snapshotHash) else {
                throw Failure.corruptManifest
            }
        }
        return book
    }

    private func manifestURL(id: String, scope: String) throws -> URL {
        guard validID(id) else { throw Failure.invalidIdentity }
        return try scopeDirectory(scope, create: false).appendingPathComponent(id + ".book")
    }
    private func scopeDirectory(_ scope: String, create: Bool) throws -> URL {
        guard validID(scope) else { throw Failure.invalidIdentity }
        var directory = root.appendingPathComponent(scope, isDirectory: true)
        if create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true
            try directory.setResourceValues(resources)
        }
        return directory
    }
    private func validID(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
