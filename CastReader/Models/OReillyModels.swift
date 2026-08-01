//
//  OReillyModels.swift
//  CastReader
//
//  O'Reilly Learning 绑定书架的数据模型和安全合同。
//
//  O'Reilly 机构访问可能通过 EZproxy 改写域名。CastReader 只接受官方
//  learning.oreilly.com，或形如 learning-oreilly-com.<机构 proxy 域>
//  的 HTTPS 地址；从书架扫描到阅读器的整个链路必须保持同一可信 host。
//  真实 reader/continue/chapter URL 会原样规范化后持久化，不根据 ISBN 猜 URL。
//

import CryptoKit
import Foundation

// MARK: - Book

struct OReillyBook: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var author: String
    var coverURL: String?
    /// 书架 DOM 实际给出的书籍或 continue 地址。不得由 contentID 合成。
    var readerURL: String
    var progressLabel: String
    /// O'Reilly content identifier（常见为 13 位 ISBN，但合同不依赖 ISBN）。
    var contentID: String
    /// readerURL 被可信书架确认时的 host，用于阻止续读锚点跨 origin。
    var readerHost: String
    var lastOpenedAt: Date?
    var lastSyncedAt: Date
    /// 阅读器最后提交的真实章节地址。
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

struct OReillyReadingAnchor: Codable, Equatable {
    let bookID: String
    /// 真实章节 URL；O'Reilly 的章节和 hash 都可能携带官方进度。
    var readerURL: String
    /// 当前视觉页的 opaque fingerprint，仅用于恢复和诊断。
    var pageFingerprint: String
    var progressLabel: String?
    /// 同一长章节内的恢复证据。source 坐标优先，比例/像素仅作为
    /// O'Reilly 改版或重排后无法定位原 source block 时的兜底。
    var scrollOffset: Double?
    var scrollMaximum: Double?
    var scrollRatio: Double?
    var sourceParagraphIndex: Int?
    var sourceUTF16Start: Int?
    var sourceUTF16End: Int?
    var updatedAt: Date
}

struct OReillyAccountInfo: Equatable {
    var label: String?
    /// 原始邮箱、机构账号或组织身份进入 store 前必须 SHA-256。
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

    init(label evidence: OReillyScanAccountEvidence) {
        label = evidence.displayLabel
        identity = evidence.identity
        hasAccountEvidence = evidence.hasAccountEvidence
        isShelfContext = evidence.isShelfContext
        isCompleteSnapshot = evidence.isCompleteSnapshot
    }
}

enum OReillyLibrarySort: String, CaseIterable, Identifiable {
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

// MARK: - Metadata

enum OReillyBookMetadata {
    static func sanitizedTitle(_ raw: String) -> String {
        var value = collapsed(raw)
        let actionPrefix =
            #"(?i)^(?:continue(?:\s+reading)?|read(?:\s+now)?|open(?:\s+book)?|resume(?:\s+reading)?|start(?:\s+reading)?)\s*[:\-–—]\s*"#
        for _ in 0..<2 {
            guard let range = value.range(
                of: actionPrefix,
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
        if ["unknown", "unknown author", "author"].contains(lower) {
            return ""
        }
        return collapsed(value)
    }

    static func normalized(_ book: OReillyBook) -> OReillyBook {
        var result = book
        result.title = sanitizedTitle(result.title)
        result.author = sanitizedAuthor(result.author)
        result.coverURL = result.coverURL.flatMap {
            OReillyScanResult.normalizedCoverURL($0, relativeTo: nil)
        }
        result.contentID =
            OReillyBookValidator.canonicalContentID(result.contentID)
                ?? result.contentID
        result.readerHost = result.readerHost.lowercased()
        return result
    }

    static func merged(
        existing: OReillyBook?,
        incoming: OReillyBook
    ) -> OReillyBook {
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
        // These values came from a newly proven shelf snapshot. Preserve the
        // actual URLs rather than rebuilding them from contentID.
        result.readerURL = candidate.readerURL
        result.contentID = candidate.contentID
        result.readerHost = candidate.readerHost
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
        let placeholders: Set<String> = [
            "", "book", "book cover", "cover", "read", "read now",
            "continue", "continue reading", "unknown title", "untitled",
            "o'reilly", "o’reilly", "o'reilly learning",
        ]
        guard !placeholders.contains(value.lowercased()) else { return 0 }
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

// MARK: - URL / identity

enum OReillyBookValidator {
    static let directReaderHost = "learning.oreilly.com"

    static func usableReaderURL(
        _ raw: String?,
        trustedHost: String? = nil
    ) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let absolute: String
        if value.hasPrefix("//") {
            absolute = "https:" + value
        } else if value.hasPrefix("/") {
            guard let trusted = trustedHost?.lowercased(),
                  OReillyWebAccessPolicy.isAllowedReaderHost(trusted) else {
                return nil
            }
            absolute = "https://\(trusted)\(value)"
        } else {
            absolute = value
        }

        guard let components = URLComponents(string: absolute),
              let candidate = components.url,
              OReillyWebAccessPolicy.allowsReaderNavigation(
                  candidate,
                  trustedHost: trustedHost
              ),
              contentID(from: candidate) != nil else {
            return nil
        }
        return normalizedAbsoluteString(components)
    }

    static func usableResumeURL(
        _ raw: String?,
        expecting expectedContentID: String?,
        trustedHost: String
    ) -> String? {
        guard let expectedContentID,
              let expected = canonicalContentID(expectedContentID),
              let usable = usableReaderURL(raw, trustedHost: trustedHost),
              let url = URL(string: usable),
              contentID(from: url) == expected else {
            return nil
        }
        return usable
    }

    static func contentID(from raw: String) -> String? {
        guard let url = URL(string: raw) else { return nil }
        return contentID(from: url)
    }

    static func contentID(from url: URL) -> String? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        let path = components.percentEncodedPath
        guard path.hasPrefix("/library/view/"),
              !path.contains("//"),
              !path.contains("\\"),
              !path.contains("%") else {
            return nil
        }
        let segments = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard segments.count >= 4,
              segments[0].lowercased() == "library",
              segments[1].lowercased() == "view",
              isSafePathSegment(segments[2], allowDashOnly: true),
              let contentID = canonicalContentID(segments[3]),
              segments.dropFirst(4).allSatisfy({
                  isSafePathSegment($0, allowDashOnly: false)
              }) else {
            return nil
        }
        return contentID
    }

    static func canonicalContentID(_ value: String) -> String? {
        let candidate = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard (6...64).contains(candidate.utf8.count),
              candidate.unicodeScalars.allSatisfy({
                  (48...57).contains($0.value)
                      || (97...122).contains($0.value)
                      || $0 == "."
                      || $0 == "_"
                      || $0 == ":"
                      || $0 == "-"
              }) else {
            return nil
        }
        return candidate
    }

    static func stableID(contentID: String) -> String {
        let canonical = canonicalContentID(contentID) ?? contentID.lowercased()
        return "oreilly:\(canonical)"
    }

    static func isLikelyLibraryBook(_ book: OReillyBook) -> Bool {
        let normalized = OReillyBookMetadata.normalized(book)
        guard !normalized.title.isEmpty,
              let declared = canonicalContentID(normalized.contentID),
              normalized.id == stableID(contentID: declared),
              OReillyWebAccessPolicy.isAllowedReaderHost(
                  normalized.readerHost
              ),
              let usable = usableReaderURL(
                  normalized.readerURL,
                  trustedHost: normalized.readerHost
              ),
              let url = URL(string: usable),
              contentID(from: url) == declared,
              url.host?.lowercased() == normalized.readerHost else {
            return false
        }
        let discarded = [
            "o'reilly", "o’reilly", "o'reilly learning",
            "history", "your history", "playlists", "your playlists",
            "highlights", "your highlights", "library", "book cover",
            "cover", "more", "settings",
        ]
        return !discarded.contains {
            normalized.title.caseInsensitiveCompare($0) == .orderedSame
        }
    }

    private static func normalizedAbsoluteString(
        _ original: URLComponents
    ) -> String? {
        var result = original
        result.scheme = "https"
        result.host = original.host?.lowercased()
        result.user = nil
        result.password = nil
        result.port = nil
        return result.url?.absoluteString
    }

    private static func isSafePathSegment(
        _ value: String,
        allowDashOnly: Bool
    ) -> Bool {
        guard !value.isEmpty,
              value != "." && value != "..",
              !value.contains("%"),
              allowDashOnly || value != "-" else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (65...90).contains($0.value)
                || (97...122).contains($0.value)
                || $0 == "."
                || $0 == "_"
                || $0 == "~"
                || $0 == "-"
        }
    }
}

enum OReillyWebAccessPolicy {
    static func allowsReaderNavigation(
        _ url: URL?,
        trustedHost: String? = nil
    ) -> Bool {
        guard let components = strictHTTPSComponents(url),
              let host = components.host?.lowercased(),
              isAllowedReaderHost(host) else {
            return false
        }
        if let trustedHost,
           host != trustedHost.lowercased() {
            return false
        }
        guard let normalizedURL = components.url else { return false }
        return OReillyBookValidator.contentID(from: normalizedURL) != nil
    }

    /// Only the authenticated History/Profile surfaces can own a shelf
    /// snapshot. Home/discovery pages contain public recommendations and must
    /// never be mistaken for the user's library.
    static func allowsShelfURL(_ url: URL?) -> Bool {
        guard let components = strictHTTPSComponents(url),
              let host = components.host?.lowercased(),
              isAllowedReaderHost(host) else {
            return false
        }
        let path = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        return path == "history" || path == "profile"
    }

    static func isAllowedReaderHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == OReillyBookValidator.directReaderHost
            || isRecognizedInstitutionProxyHost(lower)
    }

    /// EZproxy commonly rewrites `learning.oreilly.com` into
    /// `learning-oreilly-com.ezproxy.school.edu`. Requiring both the exact
    /// rewrite prefix and an explicit proxy-labelled institutional suffix
    /// prevents a generic look-alike such as `learning-oreilly-com.evil.com`.
    static func isRecognizedInstitutionProxyHost(_ host: String) -> Bool {
        let prefix = "learning-oreilly-com."
        guard host.hasPrefix(prefix) else { return false }
        let suffix = String(host.dropFirst(prefix.count))
        let labels = suffix.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3,
              labels.allSatisfy({ isSafeDNSLabel(String($0)) }) else {
            return false
        }
        return labels.dropLast(2).contains {
            $0.lowercased().contains("proxy")
        }
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

    private static func isSafeDNSLabel(_ label: String) -> Bool {
        guard (1...63).contains(label.count),
              label.first != "-",
              label.last != "-" else {
            return false
        }
        return label.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (97...122).contains($0.value)
                || $0 == "-"
        }
    }
}

enum OReillyAccountIdentity {
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
            if !domain.isEmpty, domain.contains(".") {
                return "O’Reilly · \(domain)"
            }
            return "O’Reilly account"
        }
        let safe = String(value.prefix(72))
        if safe.localizedCaseInsensitiveContains("o'reilly")
            || safe.localizedCaseInsensitiveContains("o’reilly") {
            return safe
        }
        return "O’Reilly · \(safe)"
    }
}

// MARK: - Shelf snapshot

struct OReillyScanAccountEvidence: Equatable {
    let displayLabel: String?
    let identity: String?
    let hasAccountEvidence: Bool
    let isShelfContext: Bool
    let isCompleteSnapshot: Bool
}

struct OReillyScanResult {
    var authRequired: Bool
    var authenticated: Bool
    var hasAccountEvidence: Bool
    var isShelfContext: Bool
    var isCompleteSnapshot: Bool
    var account: OReillyScanAccountEvidence?
    var books: [OReillyBook]

    /// `pageURL` must come from native WKNavigation state, not JavaScript.
    /// This prevents injected dictionary fields from nominating a proxy host.
    init(_ raw: [String: Any], pageURL: URL?) {
        authRequired = raw["authRequired"] as? Bool ?? true
        hasAccountEvidence = raw["hasAccountEvidence"] as? Bool ?? false
        let trustedShelfPage = OReillyWebAccessPolicy.allowsShelfURL(pageURL)
        isShelfContext =
            (raw["isShelfContext"] as? Bool ?? false) && trustedShelfPage
        isCompleteSnapshot = raw["isCompleteSnapshot"] as? Bool ?? false
        let declaredAuthenticated = raw["authenticated"] as? Bool ?? false
        authenticated = declaredAuthenticated
            && hasAccountEvidence
            && isShelfContext
            && !authRequired

        if hasAccountEvidence && trustedShelfPage {
            account = OReillyScanAccountEvidence(
                displayLabel: OReillyAccountIdentity.safeDisplayLabel(
                    raw["account"] as? String
                ),
                identity: OReillyAccountIdentity.hash(
                    raw["accountIdentitySource"] as? String
                ),
                hasAccountEvidence: true,
                isShelfContext: isShelfContext,
                isCompleteSnapshot: isCompleteSnapshot
            )
        } else {
            account = nil
        }

        let trustedHost = trustedShelfPage
            ? pageURL?.host?.lowercased()
            : nil
        books = (raw["books"] as? [[String: Any]] ?? []).compactMap { item in
            guard (item["contentKind"] as? String)?.lowercased() == "book"
            else {
                return nil
            }
            let title = OReillyBookMetadata.sanitizedTitle(
                item["title"] as? String ?? ""
            )
            guard !title.isEmpty,
                  let trustedHost,
                  let readerURL = OReillyBookValidator.usableReaderURL(
                      item["readerURL"] as? String,
                      trustedHost: trustedHost
                  ),
                  let contentID = OReillyBookValidator.contentID(
                      from: readerURL
                  ) else {
                return nil
            }
            let lastReaderURL = OReillyBookValidator.usableResumeURL(
                item["resumeURL"] as? String,
                expecting: contentID,
                trustedHost: trustedHost
            )
            let book = OReillyBook(
                id: OReillyBookValidator.stableID(contentID: contentID),
                title: title,
                author: OReillyBookMetadata.sanitizedAuthor(
                    item["author"] as? String ?? ""
                ),
                coverURL: (item["coverURL"] as? String).flatMap {
                    Self.normalizedCoverURL($0, relativeTo: pageURL)
                },
                readerURL: readerURL,
                progressLabel: (item["progressLabel"] as? String ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                contentID: contentID,
                readerHost: trustedHost,
                lastOpenedAt: nil,
                lastSyncedAt: Date(),
                lastReaderURL: lastReaderURL
            )
            return OReillyBookValidator.isLikelyLibraryBook(book)
                ? book
                : nil
        }
    }

    static func normalizedCoverURL(
        _ raw: String,
        relativeTo baseURL: URL?
    ) -> String? {
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

        let candidate: URL?
        if trimmed.hasPrefix("//") {
            candidate = URL(string: "https:" + trimmed)
        } else if trimmed.hasPrefix("/") {
            candidate = baseURL.flatMap {
                URL(string: trimmed, relativeTo: $0)?.absoluteURL
            }
        } else {
            candidate = URL(string: trimmed)
        }
        guard let candidate,
              let components = URLComponents(
                  url: candidate,
                  resolvingAgainstBaseURL: false
              ),
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

/// O'Reilly History hydrates asynchronously. A complete DOM alone is not a
/// complete shelf; scanners must reach the end and observe a stable result.
enum OReillyShelfSyncContract {
    static let populatedShelfStablePasses = 3
    static let emptyShelfStablePasses = 8

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
        account: OReillyAccountInfo?,
        reachedEnd: Bool,
        stableEndPasses: Int
    ) -> Bool {
        guard isStableSnapshot(
            bookCount: bookCount,
            reachedEnd: reachedEnd,
            stableEndPasses: stableEndPasses
        ),
        account?.hasAccountEvidence == true,
        account?.isShelfContext == true,
        OReillyAccountIdentity.isValidStoredIdentity(account?.identity) else {
            return false
        }
        return bookCount > 0 || account?.isCompleteSnapshot == true
    }

    /// A brand-new temporary-access profile has no cross-browser History.
    /// Instead of binding an apparently broken empty shelf, let the user open
    /// one book in the same persistent WebKit profile and scan again. An
    /// already-populated local shelf may still accept a trusted empty snapshot
    /// so removals remain possible.
    static func requiresCatalogSeed(
        scannedBookCount: Int,
        existingBookCount: Int,
        isExistingAccount: Bool
    ) -> Bool {
        scannedBookCount == 0
            && (existingBookCount == 0 || !isExistingAccount)
    }
}
