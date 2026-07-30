//
//  KoboModels.swift
//  CastReader
//
//  Kobo 绑定书架的数据模型与纯函数安全合同。
//
//  Kobo 的网页阅读地址使用稳定 UUID：
//  https://readnow.kobo.com/<book-uuid>
//
//  CastReader 只持久化书架元数据、规范阅读地址和本地页面锚点；
//  网页凭据只存在共享的持久 WKWebsiteDataStore，正文不落库。
//

import CryptoKit
import Foundation

// MARK: - Book

struct KoboBook: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var author: String
    var coverURL: String?
    var readerURL: String
    var progressLabel: String
    var bookUUID: String
    var lastOpenedAt: Date?
    var lastSyncedAt: Date
    /// Kobo 的 URL 通常不携带视觉页位置；保留这个字段是为了让后续
    /// 官方 reader URL 出现可信定位参数时无需迁移书架模型。
    var lastReaderURL: String?

    var displayAuthor: String {
        author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLocalized("未知作者")
            : author
    }

    var displayProgress: String {
        progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AppLocalized("尚未开始")
            : progressLabel
    }

    var effectiveReaderURL: String { lastReaderURL ?? readerURL }
}

enum KoboBookMetadata {
    static func sanitizedTitle(_ raw: String) -> String {
        var value = collapsed(raw)
        let pattern =
            #"(?i)^(?:read\s*now|continue(?:\s*reading)?|open(?:\s*book)?|start\s*reading|resume(?:\s*reading)?)\s*[:\-–—]\s*"#
        for _ in 0..<2 {
            guard let range = value.range(
                of: pattern,
                options: .regularExpression
            ) else {
                break
            }
            value.removeSubrange(range)
            value = collapsed(value)
        }
        return value
    }

    static func sanitizedAuthor(_ raw: String) -> String {
        var value = collapsed(raw)
        if let range = value.range(
            of: #"(?i)^(?:by|author)\s*[:\-]?\s*"#,
            options: .regularExpression
        ) {
            value.removeSubrange(range)
        }
        let lower = collapsed(value).lowercased()
        if ["unknown author", "unknown", "author"].contains(lower) {
            return ""
        }
        return collapsed(value)
    }

    static func normalized(_ book: KoboBook) -> KoboBook {
        var result = book
        result.title = sanitizedTitle(result.title)
        result.author = sanitizedAuthor(result.author)
        result.coverURL = result.coverURL.flatMap(
            KoboScanResult.normalizedCoverURL
        )
        return result
    }

    static func merged(
        existing: KoboBook?,
        incoming: KoboBook
    ) -> KoboBook {
        let candidate = normalized(incoming)
        guard var result = existing.map(normalized) else {
            return candidate
        }
        if titleScore(candidate.title) > 0 {
            result.title = candidate.title
        }
        if authorScore(candidate.author) > 0 {
            result.author = candidate.author
        }
        if let cover = candidate.coverURL {
            result.coverURL = cover
        }
        result.readerURL = candidate.readerURL
        result.bookUUID = candidate.bookUUID
        if !candidate.progressLabel
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty {
            result.progressLabel = candidate.progressLabel
        }
        result.lastSyncedAt = max(
            result.lastSyncedAt,
            candidate.lastSyncedAt
        )
        if let opened = candidate.lastOpenedAt,
           opened > (result.lastOpenedAt ?? .distantPast) {
            result.lastOpenedAt = opened
        }
        if let resume = candidate.lastReaderURL {
            result.lastReaderURL = resume
        }
        return result
    }

    private static func titleScore(_ raw: String) -> Int {
        let value = sanitizedTitle(raw)
        let lower = value.lowercased()
        let placeholders: Set<String> = [
            "", "book", "book cover", "cover", "read now",
            "continue reading", "unknown title", "untitled",
            "kobo", "rakuten kobo",
        ]
        guard !placeholders.contains(lower) else { return 0 }
        return 1_000 + min(value.count, 200)
    }

    private static func authorScore(_ raw: String) -> Int {
        let value = sanitizedAuthor(raw)
        guard !value.isEmpty else { return 0 }
        return 100 + min(value.count, 120)
    }

    private static func collapsed(_ raw: String) -> String {
        raw
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct KoboReadingAnchor: Codable, Equatable {
    let bookID: String
    var readerURL: String
    /// 当前已提交视觉页的 opaque fingerprint。它用于恢复/诊断，
    /// 不得被当作绕过 Kobo 官方进度同步的定位令牌。
    var pageFingerprint: String
    var progressLabel: String?
    var updatedAt: Date
}

struct KoboAccountInfo: Equatable {
    var label: String?
    /// 登录证据在进入 store 前已做 SHA-256；原始邮箱/账号不得持久化。
    var identity: String?
    var hasAccountEvidence: Bool
    var isShelfContext: Bool
    var isCompleteSnapshot: Bool

    init(
        label: String?,
        identity: String? = nil,
        hasAccountEvidence: Bool = false,
        isShelfContext: Bool = false,
        isCompleteSnapshot: Bool = false
    ) {
        self.label = label
        self.identity = identity
        self.hasAccountEvidence = hasAccountEvidence
        self.isShelfContext = isShelfContext
        self.isCompleteSnapshot = isCompleteSnapshot
    }

    init(label evidence: KoboScanAccountEvidence) {
        label = evidence.displayLabel
        identity = evidence.identity
        hasAccountEvidence = evidence.hasAccountEvidence
        isShelfContext = evidence.isShelfContext
        isCompleteSnapshot = evidence.isCompleteSnapshot
    }
}

enum KoboLibrarySort: String, CaseIterable, Identifiable {
    case recent, title, author

    var id: String { rawValue }

    var label: String {
        switch self {
        case .recent: return AppLocalized("最近阅读")
        case .title: return AppLocalized("书名")
        case .author: return AppLocalized("作者")
        }
    }
}

// MARK: - URL / identity

enum KoboBookValidator {
    static let readerHost = "readnow.kobo.com"

    /// Accepts a canonical URL, protocol-relative URL, or root-relative UUID
    /// path. Query and fragment values are deliberately discarded: the UUID is
    /// Kobo's book identity, while account progress remains owned by Kobo.
    static func usableReaderURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let absolute: String
        if trimmed.hasPrefix("//") {
            absolute = "https:" + trimmed
        } else if trimmed.hasPrefix("/") {
            absolute = "https://\(readerHost)" + trimmed
        } else {
            absolute = trimmed
        }

        guard let components = URLComponents(string: absolute),
              let candidateURL = components.url,
              KoboWebAccessPolicy.allowsReaderNavigation(candidateURL),
              let bookUUID = bookUUID(from: components) else {
            return nil
        }
        return canonicalReaderURL(bookUUID: bookUUID)
    }

    /// Kobo currently restores the visual position from its authenticated
    /// account rather than a URL page parameter. Still enforce same-book
    /// identity so a stale or forged URL cannot replace another book's anchor.
    static func usableResumeURL(
        _ raw: String?,
        expecting expectedBookUUID: String?
    ) -> String? {
        guard let usable = usableReaderURL(raw),
              let parsed = bookUUID(from: usable) else {
            return nil
        }
        if let expectedBookUUID,
           let expected = canonicalBookUUID(expectedBookUUID),
           parsed != expected {
            return nil
        }
        if let expectedBookUUID,
           canonicalBookUUID(expectedBookUUID) == nil {
            return nil
        }
        return usable
    }

    static func bookUUID(from raw: String) -> String? {
        guard let components = URLComponents(string: raw) else { return nil }
        return bookUUID(from: components)
    }

    static func isValidBookUUID(_ value: String) -> Bool {
        canonicalBookUUID(value) != nil
    }

    static func canonicalReaderURL(bookUUID: String) -> String {
        let canonical = canonicalBookUUID(bookUUID) ?? bookUUID.lowercased()
        return "https://\(readerHost)/\(canonical)"
    }

    static func stableID(bookUUID: String) -> String {
        let canonical = canonicalBookUUID(bookUUID) ?? bookUUID.lowercased()
        return "kobo:\(canonical)"
    }

    static func isLikelyLibraryBook(_ book: KoboBook) -> Bool {
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let declaredUUID = canonicalBookUUID(book.bookUUID),
              let usableURL = usableReaderURL(book.readerURL),
              let readerUUID = bookUUID(from: usableURL),
              declaredUUID == readerUUID,
              book.id == stableID(bookUUID: readerUUID) else {
            return false
        }
        let discarded = [
            "kobo", "rakuten kobo", "my books", "my library", "library",
            "book cover", "cover", "more", "settings",
            "我的书籍", "我的书库", "书库", "封面", "更多", "设置",
        ]
        return !discarded.contains {
            title.caseInsensitiveCompare($0) == .orderedSame
        }
    }

    private static func bookUUID(from components: URLComponents) -> String? {
        // Use percentEncodedPath so encoded slashes/braces cannot be decoded
        // into an apparently valid authority/path after validation.
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.first == "/" else { return nil }
        let raw = String(path.dropFirst())
        guard !raw.contains("/") else { return nil }
        return canonicalBookUUID(raw)
    }

    private static func canonicalBookUUID(_ value: String) -> String? {
        let candidate = value.lowercased()
        guard candidate.utf8.count == 36 else { return nil }
        let hyphenOffsets: Set<Int> = [8, 13, 18, 23]
        for (offset, scalar) in candidate.unicodeScalars.enumerated() {
            if hyphenOffsets.contains(offset) {
                guard scalar == "-" else { return nil }
            } else {
                let isHex =
                    (48...57).contains(scalar.value)
                        || (97...102).contains(scalar.value)
                guard isHex else { return nil }
            }
        }
        guard UUID(uuidString: candidate) != nil else { return nil }
        return candidate
    }
}

enum KoboWebAccessPolicy {
    static func allowsReaderNavigation(_ url: URL?) -> Bool {
        guard let components = strictHTTPSComponents(url),
              components.host?.lowercased() == KoboBookValidator.readerHost else {
            return false
        }
        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.first == "/" else { return false }
        let candidate = String(path.dropFirst())
        return !candidate.contains("/")
            && KoboBookValidator.isValidBookUUID(candidate)
    }

    /// The shelf scanner may run on regional Kobo library URLs such as
    /// `/sg/en/library/books`. This is intentionally narrower than a general
    /// `*.kobo.com` allowlist.
    static func allowsLibraryURL(_ url: URL?) -> Bool {
        guard let components = strictHTTPSComponents(url),
              let host = components.host?.lowercased(),
              host == "kobo.com" || host == "www.kobo.com" else {
            return false
        }
        let segments = components.path
            .lowercased()
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if segments == ["library", "books"] { return true }
        guard segments.count == 4,
              segments[2] == "library",
              segments[3] == "books" else {
            return false
        }
        // Kobo regional shelves use `/<market>/<language>/library/books`.
        // Keep both components deliberately conservative.
        return isSafeRegionalComponent(segments[0])
            && isSafeRegionalComponent(segments[1])
    }

    private static func strictHTTPSComponents(_ url: URL?) -> URLComponents? {
        guard let url,
              let components = URLComponents(
                  url: url,
                  resolvingAgainstBaseURL: false
              ),
              components.scheme?.lowercased() == "https",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443,
              components.host != nil else {
            return nil
        }
        return components
    }

    private static func isSafeRegionalComponent(_ value: String) -> Bool {
        guard (2...16).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (97...122).contains($0.value)
                || $0 == "-"
        }
    }
}

enum KoboAccountIdentity {
    static func hash(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return nil }
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return "sha256:" + digest.map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func isValidStoredIdentity(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }

    /// A DOM account menu may expose the email as its aria-label. Keep only a
    /// non-identifying domain label for UI/persistence.
    static func safeDisplayLabel(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"\s+"#,
                with: " ",
                options: .regularExpression
            )
        guard !value.isEmpty else { return nil }
        if let at = value.lastIndex(of: "@") {
            let suffix = value[value.index(after: at)...].lowercased()
            let domain = String(suffix.prefix {
                $0.isLetter || $0.isNumber || $0 == "." || $0 == "-"
            })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
            if !domain.isEmpty,
               domain.contains(".") {
                return "Kobo · \(domain)"
            }
            // Never persist the original value once it looks email-shaped,
            // even if a future Kobo aria-label format defeats domain parsing.
            return "Kobo account"
        }
        return String(value.prefix(80))
    }
}

// MARK: - Shelf snapshot

struct KoboScanAccountEvidence: Equatable {
    let displayLabel: String?
    let identity: String?
    let hasAccountEvidence: Bool
    let isShelfContext: Bool
    let isCompleteSnapshot: Bool
}

struct KoboScanResult {
    var authRequired: Bool
    var authenticated: Bool
    var hasAccountEvidence: Bool
    var isShelfContext: Bool
    var isCompleteSnapshot: Bool
    var account: KoboScanAccountEvidence?
    var books: [KoboBook]

    init(_ raw: [String: Any]) {
        authRequired = raw["authRequired"] as? Bool ?? true
        hasAccountEvidence = raw["hasAccountEvidence"] as? Bool ?? false
        isShelfContext = raw["isShelfContext"] as? Bool ?? false
        isCompleteSnapshot = raw["isCompleteSnapshot"] as? Bool ?? false
        let declaredAuthenticated = raw["authenticated"] as? Bool ?? false
        authenticated = declaredAuthenticated
            && hasAccountEvidence
            && isShelfContext
            && !authRequired

        if hasAccountEvidence {
            account = KoboScanAccountEvidence(
                displayLabel: KoboAccountIdentity.safeDisplayLabel(
                    raw["account"] as? String
                ),
                identity: KoboAccountIdentity.hash(
                    raw["accountIdentitySource"] as? String
                ),
                hasAccountEvidence: true,
                isShelfContext: isShelfContext,
                isCompleteSnapshot: isCompleteSnapshot
            )
        } else {
            account = nil
        }

        books = (raw["books"] as? [[String: Any]] ?? []).compactMap { item in
            let title = KoboBookMetadata.sanitizedTitle(
                item["title"] as? String ?? ""
            )
            let rawURL = item["readerURL"] as? String ?? ""
            guard !title.isEmpty,
                  let readerURL = KoboBookValidator.usableReaderURL(rawURL),
                  let bookUUID = KoboBookValidator.bookUUID(from: readerURL) else {
                return nil
            }
            let book = KoboBook(
                id: KoboBookValidator.stableID(bookUUID: bookUUID),
                title: title,
                author: KoboBookMetadata.sanitizedAuthor(
                    item["author"] as? String ?? ""
                ),
                coverURL: (item["coverURL"] as? String)
                    .flatMap(Self.normalizedCoverURL),
                readerURL: readerURL,
                progressLabel: (item["progressLabel"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                bookUUID: bookUUID,
                lastOpenedAt: nil,
                lastSyncedAt: Date(),
                lastReaderURL: nil
            )
            return KoboBookValidator.isLikelyLibraryBook(book) ? book : nil
        }
    }

    static func normalizedCoverURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard !trimmed.isEmpty,
              !lower.hasPrefix("data:"),
              !lower.hasPrefix("blob:"),
              !lower.contains("transparent"),
              !lower.contains("spacer"),
              !lower.contains("blank."),
              !lower.contains("pixel.") else {
            return nil
        }
        let absolute = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard let components = URLComponents(string: absolute),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443 else {
            return nil
        }
        return components.url?.absoluteString
    }
}

/// A complete DOM does not prove that Kobo's lazy/virtualized shelf has
/// finished. Empty shelves require more stable passes to avoid a transient
/// "0 books" result while cards are still hydrating.
enum KoboShelfSyncContract {
    static let populatedShelfStablePasses = 4
    static let emptyShelfStablePasses = 10

    static func requiredStablePasses(bookCount: Int) -> Int {
        bookCount == 0 ? emptyShelfStablePasses : populatedShelfStablePasses
    }

    static func isStableSnapshot(
        bookCount: Int,
        reachedEnd: Bool,
        stableEndPasses: Int
    ) -> Bool {
        reachedEnd
            && stableEndPasses >= requiredStablePasses(bookCount: bookCount)
    }

    static func canCommit(
        bookCount: Int,
        account: KoboAccountInfo?,
        reachedEnd: Bool,
        stableEndPasses: Int
    ) -> Bool {
        guard isStableSnapshot(
            bookCount: bookCount,
            reachedEnd: reachedEnd,
            stableEndPasses: stableEndPasses
        ) else {
            return false
        }
        guard account?.hasAccountEvidence == true,
              account?.isShelfContext == true,
              KoboAccountIdentity.isValidStoredIdentity(account?.identity) else {
            return false
        }
        if bookCount == 0 {
            return account?.isCompleteSnapshot == true
        }
        return true
    }
}
