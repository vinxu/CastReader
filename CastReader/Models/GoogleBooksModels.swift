//
//  GoogleBooksModels.swift
//  CastReader
//
//  Google Play 图书（play.google.com/books）绑定书库的数据模型与纯函数契约。
//
//  与 Kindle / 微信读书同一条产品线：内容始终来自用户已登录的 WKWebView，
//  CastReader 只持久化书籍元数据与本地阅读位置，**不落库正文、不存凭据**。
//

import CryptoKit
import Foundation

// MARK: - 书籍

struct GoogleBooksBook: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var author: String
    var coverURL: String?
    /// 书架给出的规范阅读地址：https://play.google.com/books/reader?id=<volumeID>
    var readerURL: String
    var progressLabel: String
    /// Google 的 volume id（如 b_40EQAAQBAJ）。
    var volumeID: String?
    var lastOpenedAt: Date?
    var lastSyncedAt: Date
    /// 上次离开时的完整阅读地址（带 pg 定位参数），用于本地续读。
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

struct GoogleBooksReadingAnchor: Codable, Equatable {
    let bookID: String
    var readerURL: String
    var pageFingerprint: String
    var progressLabel: String?
    var updatedAt: Date
}

struct GoogleBooksAccountInfo: Codable, Equatable {
    var label: String?
    /// Stable, non-display account key. The raw account/email evidence is
    /// normalized and SHA-256 hashed before it reaches the persistent store.
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

    /// Keeps the existing binding view call site source-compatible while
    /// carrying non-display scan evidence into the store.
    init(label evidence: GoogleBooksScanAccountEvidence) {
        label = evidence.displayLabel
        identity = evidence.identity
        hasAccountEvidence = evidence.hasAccountEvidence
        isShelfContext = evidence.isShelfContext
        isCompleteSnapshot = evidence.isCompleteSnapshot
    }

    private enum CodingKeys: String, CodingKey {
        case label, identity, hasAccountEvidence, isShelfContext, isCompleteSnapshot
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        label = try values.decodeIfPresent(String.self, forKey: .label)
        identity = try values.decodeIfPresent(String.self, forKey: .identity)
        hasAccountEvidence =
            try values.decodeIfPresent(Bool.self, forKey: .hasAccountEvidence) ?? false
        isShelfContext =
            try values.decodeIfPresent(Bool.self, forKey: .isShelfContext) ?? false
        isCompleteSnapshot =
            try values.decodeIfPresent(Bool.self, forKey: .isCompleteSnapshot) ?? false
    }
}

enum GoogleBooksLibrarySort: String, CaseIterable, Identifiable {
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

// MARK: - 地址 / 身份

enum GoogleBooksBookValidator {
    static let readerHost = "play.google.com"
    static let readerFrameHost = "books.googleusercontent.com"

    /// 把书架上抓到的任意形态地址收敛为规范阅读地址；不是 Play 图书阅读器的一律拒收。
    static func usableReaderURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let absolute = trimmed.hasPrefix("//")
            ? "https:" + trimmed
            : (trimmed.hasPrefix("/") ? "https://\(readerHost)" + trimmed : trimmed)
        guard let components = URLComponents(string: absolute),
              let url = components.url,
              GoogleBooksWebAccessPolicy.allowsMainFrameNavigation(url) else {
            return nil
        }
        guard let volume = volumeID(from: absolute) else { return nil }
        return canonicalReaderURL(volumeID: volume)
    }

    /// 保留 pg 定位参数的续读地址（只接受同一 volume 的地址）。
    static func usableResumeURL(_ raw: String?, expecting expectedVolumeID: String?) -> String? {
        guard let raw,
              let components = URLComponents(string: raw),
              let candidateURL = components.url,
              GoogleBooksWebAccessPolicy.allowsMainFrameNavigation(candidateURL),
              let volumeItems = components.queryItems?.filter({ $0.name == "id" }),
              volumeItems.count == 1,
              let parsed = volumeItems[0].value else { return nil }
        if let expectedVolumeID, !expectedVolumeID.isEmpty, parsed != expectedVolumeID { return nil }

        // Rebuild the authority instead of returning the caller-controlled
        // spelling. This drops an explicit default port and guarantees that a
        // persisted resume URL always re-enters the one supported reader host.
        var normalized = URLComponents()
        normalized.scheme = "https"
        normalized.host = readerHost
        normalized.path = "/books/reader"
        normalized.queryItems = components.queryItems
        normalized.fragment = components.fragment
        return normalized.url?.absoluteString
    }

    static func volumeID(from raw: String) -> String? {
        guard let components = URLComponents(string: raw) else { return nil }
        if let item = components.queryItems?.first(where: { $0.name == "id" })?.value,
           isValidVolumeID(item) {
            return item
        }
        // 移动端偶尔把参数放在 fragment 里（#id=...）。
        if let fragment = components.fragment {
            for pair in fragment.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0] == "id", isValidVolumeID(String(parts[1])) {
                    return String(parts[1])
                }
            }
        }
        return nil
    }

    static func isValidVolumeID(_ value: String) -> Bool {
        guard (6...64).contains(value.count) else { return false }
        return value.unicodeScalars.allSatisfy {
            (65...90).contains($0.value)
                || (97...122).contains($0.value)
                || (48...57).contains($0.value)
                || $0 == "_"
                || $0 == "-"
        }
    }

    static func canonicalReaderURL(volumeID: String) -> String {
        "https://\(readerHost)/books/reader?id=\(volumeID)"
    }

    static func isLikelyLibraryBook(_ book: GoogleBooksBook) -> Bool {
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, usableReaderURL(book.readerURL) != nil else { return false }
        // 书架页上的功能入口/占位卡片会带同样的链接形状，靠标题排掉。
        let discarded = [
            "google play", "play books", "google play 图书", "我的图书", "my books",
            "book cover", "cover", "封面", "更多", "more", "settings", "设置",
        ]
        return !discarded.contains { title.caseInsensitiveCompare($0) == .orderedSame }
    }

    static func stableID(volumeID: String?, readerURL: String, title: String) -> String {
        if let volumeID, !volumeID.isEmpty { return "googlebooks:\(volumeID)" }
        let payload = "\(readerURL)|\(title)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return "googlebooks:" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

}

// MARK: - Reader Web 安全边界

/// `WKScriptMessage` cannot be constructed in unit tests, so native extracts
/// only these immutable primitives from `WKFrameInfo` before crossing to the
/// main actor. The policy below is intentionally independent of WebKit.
struct GoogleBooksScriptMessageFrame: Equatable, Sendable {
    let isMainFrame: Bool
    let securityScheme: String
    let securityHost: String
    let securityPort: Int
    let requestURL: String?
}

/// Fail-closed host/path policy shared by Reader navigation and JS→native
/// messages. Subresources remain Google's responsibility; this policy governs
/// only top-level navigation and frames allowed to control native playback.
enum GoogleBooksWebAccessPolicy {
    private static let readerFrameMessageTypes: Set<String> = [
        "ready",
        "rendered",
        "paragraphTapped",
        "log",
        "error",
        "googleBooksTurnRequested",
        "googleBooksTurnFailed",
        "googleBooksPageChanging",
        "googleBooksPagePreview",
        "googleBooksSpeechPreview",
        "googleBooksPreviewDiagnostic",
    ]

    /// The top-level WKWebView must never leave the one supported reader
    /// endpoint. Query/fragment changes are allowed because Google stores the
    /// live `pg` position there.
    static func allowsMainFrameNavigation(_ url: URL?) -> Bool {
        guard let components = strictHTTPSComponents(url),
              components.host?.lowercased() == GoogleBooksBookValidator.readerHost,
              normalizedPath(components.path) == "/books/reader" else {
            return false
        }
        let volumeItems = (components.queryItems ?? []).filter {
            $0.name == "id"
        }
        guard volumeItems.count == 1,
              let volumeID = volumeItems[0].value else {
            return false
        }
        return GoogleBooksBookValidator.isValidVolumeID(volumeID)
    }

    /// The actual book DOM is hosted in a cross-origin reader frame. Allow the
    /// exact host and the reader path (including `/books/reader/frame`), but no
    /// arbitrary googleusercontent document or sibling Google origin.
    static func allowsReaderFrameURL(_ url: URL?) -> Bool {
        guard let components = strictHTTPSComponents(url),
              components.host?.lowercased() == GoogleBooksBookValidator.readerFrameHost else {
            return false
        }
        let path = normalizedPath(components.path)
        return path == "/books/reader" || path.hasPrefix("/books/reader/")
    }

    /// Main-frame messages are limited to the Play Books shell (currently only
    /// `googleBooksLocation`). Content/highlight/page events must originate in
    /// the exact googleusercontent reader frame. Relay-only containers do not
    /// post native messages and therefore receive no extra exception here.
    static func allowsScriptMessage(
        type messageType: String?,
        from frame: GoogleBooksScriptMessageFrame
    ) -> Bool {
        guard normalizedScheme(frame.securityScheme) == "https",
              isDefaultHTTPSPort(frame.securityPort),
              let messageType,
              !messageType.isEmpty,
              let rawURL = frame.requestURL,
              let requestURL = URL(string: rawURL) else {
            return false
        }

        let host = frame.securityHost
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if frame.isMainFrame {
            // The Play Books shell owns only the canonical `pg` location.
            // Rendered text, page-turn and highlight events are accepted only
            // from the actual googleusercontent reader frame below.
            return messageType == "googleBooksLocation"
                && host == GoogleBooksBookValidator.readerHost
                && allowsMainFrameNavigation(requestURL)
        }
        return readerFrameMessageTypes.contains(messageType)
            && host == GoogleBooksBookValidator.readerFrameHost
            && allowsReaderFrameURL(requestURL)
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

    private static func normalizedScheme(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    }

    private static func isDefaultHTTPSPort(_ value: Int) -> Bool {
        value == 0 || value == 443
    }

    private static func normalizedPath(_ path: String) -> String {
        var value = path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }
}

// MARK: - 书架扫描结果

/// Account evidence returned by the in-page shelf scan. `identity` is already
/// hashed; it is never used as visible UI text.
struct GoogleBooksScanAccountEvidence: Equatable {
    let displayLabel: String?
    let identity: String?
    let hasAccountEvidence: Bool
    let isShelfContext: Bool
    let isCompleteSnapshot: Bool
}

struct GoogleBooksScanResult {
    var authRequired: Bool
    var authenticated: Bool
    var hasAccountEvidence: Bool
    var isShelfContext: Bool
    var isCompleteSnapshot: Bool
    var account: GoogleBooksScanAccountEvidence?
    var books: [GoogleBooksBook]

    init(_ raw: [String: Any]) {
        authRequired = raw["authRequired"] as? Bool ?? true
        hasAccountEvidence = raw["hasAccountEvidence"] as? Bool ?? false
        isShelfContext = raw["isShelfContext"] as? Bool ?? false
        isCompleteSnapshot = raw["isCompleteSnapshot"] as? Bool ?? false
        let declaredAuthenticated = raw["authenticated"] as? Bool ?? false
        // A public preview can contain valid reader links. Books alone are
        // therefore never authentication evidence.
        authenticated = declaredAuthenticated
            && hasAccountEvidence
            && isShelfContext
            && !authRequired
        if hasAccountEvidence {
            account = GoogleBooksScanAccountEvidence(
                displayLabel: raw["account"] as? String,
                identity: GoogleBooksAccountIdentity.hash(
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
            let rawURL = item["readerURL"] as? String ?? ""
            let title = (item["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = GoogleBooksBookValidator.usableReaderURL(rawURL), !title.isEmpty else { return nil }
            let volumeID = GoogleBooksBookValidator.volumeID(from: url)
            return GoogleBooksBook(
                id: GoogleBooksBookValidator.stableID(volumeID: volumeID, readerURL: url, title: title),
                title: title,
                author: (item["author"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                coverURL: (item["coverURL"] as? String).flatMap(GoogleBooksScanResult.normalizedCoverURL),
                readerURL: url,
                progressLabel: (item["progressLabel"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                volumeID: volumeID,
                lastOpenedAt: nil,
                lastSyncedAt: Date(),
                lastReaderURL: nil
            )
        }
    }

    static func normalizedCoverURL(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        guard let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else { return nil }
        return components.url?.absoluteString
    }
}

// MARK: - 绑定页状态契约

/// 绑定页的底部提示必须跟随网页所处的实际阶段。特别是 Google 登录页会遮住
/// `WKWebView` 下方的区域，因此登录进行中不能再叠一张 CastReader 登录卡。
enum GoogleBooksBindingPhase: Equatable {
    case needsSignIn
    case signingIn
    case awaitingShelf
    case scanning
    case ready
}

enum GoogleBooksBindingFlowContract {
    static func isGoogleCredentialURL(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil else {
            return false
        }
        return url.host?.lowercased() == "accounts.google.com"
    }

    static func showsLoginGuide(for phase: GoogleBooksBindingPhase) -> Bool {
        phase == .needsSignIn
    }

    static func showsSyncBar(for phase: GoogleBooksBindingPhase) -> Bool {
        phase == .scanning || phase == .ready
    }

    /// The scan card may be visible while Google hydrates its virtual shelf,
    /// but the actionable "sync N books" control must not appear until the
    /// snapshot has settled. In particular, never render "sync 0 books" during
    /// the first empty DOM passes after login.
    static func showsSyncAction(for phase: GoogleBooksBindingPhase) -> Bool {
        phase == .ready
    }

    /// A successful Google credential page may return `about:blank` or a
    /// non-shelf Google destination before the `continue` navigation settles.
    /// In either case the app owns the next step: return to My Books using the
    /// existing authenticated WebKit data store instead of leaving a white page.
    static func shouldRecoverShelfAfterLogin(
        phase: GoogleBooksBindingPhase,
        didEnterCredentialFlow: Bool,
        isBlankDocument: Bool,
        isPlayBooksDestination: Bool = false,
        hasAccountEvidence: Bool,
        isShelfContext: Bool
    ) -> Bool {
        guard phase == .signingIn, didEnterCredentialFlow else { return false }
        return isBlankDocument
            || isPlayBooksDestination
            || (hasAccountEvidence && !isShelfContext)
    }
}

/// A complete DOM does not mean Google's virtualized shelf has finished
/// hydrating. Non-empty shelves can be committed after the usual end-of-list
/// confirmation; an empty shelf deliberately needs a longer confirmation so
/// the binding UI never reports "0 books" while cards are still appearing.
enum GoogleBooksShelfSyncContract {
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
        reachedEnd && stableEndPasses >= requiredStablePasses(bookCount: bookCount)
    }

    static func canCommit(
        bookCount: Int,
        account: GoogleBooksAccountInfo?,
        reachedEnd: Bool,
        stableEndPasses: Int
    ) -> Bool {
        guard isStableSnapshot(
            bookCount: bookCount,
            reachedEnd: reachedEnd,
            stableEndPasses: stableEndPasses
        ) else { return false }
        guard bookCount > 0 else {
            return account?.hasAccountEvidence == true
                && account?.isShelfContext == true
                && account?.isCompleteSnapshot == true
        }
        return true
    }
}

enum GoogleBooksAccountIdentity {
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
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isValidStoredIdentity(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("sha256:") else { return false }
        let digest = value.dropFirst("sha256:".count)
        return digest.count == 64 && digest.allSatisfy {
            $0.isNumber || ("a"..."f").contains(String($0))
        }
    }
}

// MARK: - 页面事件契约

/// 一次可见页事件的证据。Play 图书把整章渲进同一容器再裁剪分页，所以「换页」的
/// 判据是**可见区指纹**，不是 DOM 变化，也不是 URL 变化。
struct GoogleBooksPageEvidence: Equatable {
    let signature: String
    let contentFingerprint: String
    let paragraphCount: Int
}

enum GoogleBooksPageEventReason: String, Equatable {
    case initial
    case auto
    case manual
    case refresh
}

/// 翻页只有一次语义动作：native 请求 → JS 点下一页 → 可见区指纹变化才算成功。
/// 超时**不重试**（重试会跳页），把控制权交回用户。
enum GoogleBooksPageTurnContract {
    // New chapters may clear the frame and fetch before rendering. JS reports
    // a definitive no-change failure at ~5.2s, so native can safely allow a
    // much wider confirmation window without ever repeating the physical turn.
    static let turnConfirmationTimeoutNanoseconds: UInt64 = 15_000_000_000
    static let manualRestartDelayNanoseconds: UInt64 = 500_000_000
    static let manualChangeConfirmationTimeoutNanoseconds: UInt64 = 6_000_000_000
    /// The frame bundle itself waits up to 15 seconds for Google's rendered
    /// custom elements. The main-frame watchdog must fire after that budget,
    /// not race it and incorrectly report a healthy slow reader as empty.
    static let readerBootstrapTimeoutNanoseconds: UInt64 = 18_000_000_000
    /// A swipe/key intent pauses the old page before Google has committed the
    /// visual turn. If no new signature arrives, resume the untouched queue.
    static let manualIntentTimeoutNanoseconds: UInt64 = 2_000_000_000

    /// The shared bundle is injected into every frame. Auxiliary Google frames
    /// may run the generic extractor and emit an empty `rendered` event; only
    /// the dedicated Play Books reader adapter is allowed to drive paging.
    static func isReaderPagePayload(_ payload: [String: Any]) -> Bool {
        guard let source = payload["source"] as? String else { return false }
        return source == "google-books"
            || source == "kobo"
            || source == "oreilly"
    }

    static func frameSessionID(from payload: [String: Any]) -> String? {
        guard let value = payload["frameSessionID"] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A page signature ends with a literal DOM text slice, so a trailing
    /// whitespace code unit is part of the identity. Validate with a trimmed
    /// view but return the original wire value for strict turn matching.
    static func opaqueSignature(from value: Any?) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }

    /// 只有指纹真的变了才提交新页；同一指纹重复上报（重绘/resize）必须忽略，
    /// 否则会 stop→start 循环打断朗读。
    static func shouldCommit(
        reason: GoogleBooksPageEventReason,
        previousSignature: String,
        incomingSignature: String,
        paragraphCount: Int
    ) -> Bool {
        guard paragraphCount > 0 else { return false }
        if reason == .initial { return true }
        if reason == .refresh { return true }
        return !incomingSignature.isEmpty && incomingSignature != previousSignature
    }

    /// 翻页后是否应当继续播放：自动翻页永远续播；手动翻页只有在用户原本正在播放时续播。
    static func shouldResumePlayback(
        reason: GoogleBooksPageEventReason,
        wasAutomaticTurn: Bool,
        wasPlaying: Bool
    ) -> Bool {
        switch reason {
        case .initial: return false
        case .auto: return wasAutomaticTurn
        case .manual, .refresh: return wasPlaying
        }
    }
}

/// A preview never owns the visible page. Native may consume its work only
/// after the real page commits with the exact predicted text, prior signature,
/// and voice. This fail-closed contract prevents a reflow, manual reverse turn,
/// sibling reader frame, or settings change from playing speculative content.
enum GoogleBooksSinglePagePreloadContract {
    static func canConsume(
        sourceSignature: String,
        previousSignature: String,
        predictedParagraphs: [String],
        visibleParagraphs: [String],
        preparedVoiceID: String,
        selectedVoiceID: String
    ) -> Bool {
        !sourceSignature.isEmpty
            && sourceSignature == previousSignature
            && !predictedParagraphs.isEmpty
            && predictedParagraphs == visibleParagraphs
            && !preparedVoiceID.isEmpty
            && preparedVoiceID == selectedVoiceID
    }
}

/// Read-only fallback used when Google has not materialized an adjacent visual
/// column. JavaScript may expose exactly one natural source sentence, but that
/// sentence is speculative until the real page commits and proves the same
/// source coordinate and text.
struct GoogleBooksSpeechPreviewCandidate: Equatable {
    let sourceSignature: String
    let originFrameSessionID: String
    let contentFingerprint: String
    let sourceParagraphIndex: Int
    let sourceUTF16Start: Int
    let sourceUTF16End: Int
    let text: String
}

struct GoogleBooksSpeechPageSplit: Equatable {
    let paragraphs: [String]
    let domParagraphIndices: [Int]
    let domCharacterOffsets: [Int]
    let preparedParagraphIndex: Int
    let splitOriginalParagraphIndex: Int
    let insertedRemainder: Bool
    let prefixUTF16Length: Int
    let remainderLeadingWhitespaceUTF16Length: Int
}

enum GoogleBooksSpeechPreloadContract {
    static let maximumPreviewUTF16Length = 260

    /// The source-stream fallback is intentionally narrower than a visual page
    /// preview. A 32-bit fingerprint is only a cache key; authorization comes
    /// from the exact active frame, committed source signature, UTF-16
    /// coordinates, and source text. The real committed page is checked again
    /// by `splitCommittedPage` before any speculative audio can become audible.
    static func canPrepare(
        candidate: GoogleBooksSpeechPreviewCandidate,
        exactText: Bool,
        currentSourceSignature: String,
        activeFrameSessionID: String
    ) -> Bool {
        let fingerprintIsValid =
            candidate.contentFingerprint.count == 8
                && candidate.contentFingerprint.allSatisfy {
                    $0.isNumber || ("a"..."f").contains(String($0))
                }
        let textLength = (candidate.text as NSString).length
        return exactText
            && !candidate.sourceSignature.isEmpty
            && candidate.sourceSignature == currentSourceSignature
            && !candidate.originFrameSessionID.isEmpty
            && candidate.originFrameSessionID == activeFrameSessionID
            && fingerprintIsValid
            && candidate.sourceParagraphIndex >= 0
            && candidate.sourceUTF16Start >= 0
            && candidate.sourceUTF16End > candidate.sourceUTF16Start
            && textLength > 0
            && textLength <= maximumPreviewUTF16Length
            && candidate.sourceUTF16End - candidate.sourceUTF16Start
                == textLength
            && SpeechTextSanitizer.containsSpeakableContent(candidate.text)
    }

    /// Convert the first exact unconsumed source sentence into its own native
    /// paragraph. The remainder aliases the same DOM `<p>` at a later UTF-16
    /// offset, preventing either a repeated prefix or skipped text after the
    /// prefetched sentence finishes.
    static func splitCommittedPage(
        candidate: GoogleBooksSpeechPreviewCandidate,
        previousSignature: String,
        activeFrameSessionID: String,
        sourceSlices: [LiveWebPageSourceSlice],
        paragraphs: [String],
        domCharacterOffsets: [Int]
    ) -> GoogleBooksSpeechPageSplit? {
        guard !candidate.sourceSignature.isEmpty,
              candidate.sourceSignature == previousSignature,
              !candidate.originFrameSessionID.isEmpty,
              candidate.originFrameSessionID == activeFrameSessionID,
              !candidate.contentFingerprint.isEmpty,
              candidate.sourceParagraphIndex >= 0,
              candidate.sourceUTF16Start >= 0,
              candidate.sourceUTF16End > candidate.sourceUTF16Start,
              !candidate.text.isEmpty,
              candidate.sourceUTF16End - candidate.sourceUTF16Start
                == (candidate.text as NSString).length,
              sourceSlices.count == paragraphs.count,
              domCharacterOffsets.count == paragraphs.count else {
            return nil
        }

        guard let splitIndex = sourceSlices.indices.first(where: { index in
            sourceSlices[index].sourceParagraphIndex
                == candidate.sourceParagraphIndex
                && domCharacterOffsets[index] == candidate.sourceUTF16Start
                && (paragraphs[index] as NSString).length
                    >= (candidate.text as NSString).length
                && paragraphs[index].hasPrefix(candidate.text)
        }) else {
            return nil
        }

        // A source preview is allowed to become audible only as the first
        // unconsumed TTS unit on the committed page. Empty placeholders remain
        // before it so DOM indices stay stable, but any earlier speakable text
        // makes the prediction ambiguous and therefore a miss.
        guard paragraphs[..<splitIndex].allSatisfy({
            !SpeechTextSanitizer.containsSpeakableContent($0)
        }) else {
            return nil
        }

        let full = paragraphs[splitIndex] as NSString
        let prefixLength = (candidate.text as NSString).length
        let suffix = full.substring(from: prefixLength) as NSString
        let firstContent = suffix.rangeOfCharacter(
            from: CharacterSet.whitespacesAndNewlines.inverted
        )
        let leadingWhitespace = firstContent.location == NSNotFound
            ? suffix.length
            : firstContent.location
        let remainder = suffix.substring(from: leadingWhitespace)
        let hasRemainder =
            SpeechTextSanitizer.containsSpeakableContent(remainder)

        var outputParagraphs: [String] = []
        var outputDOMIndices: [Int] = []
        var outputDOMOffsets: [Int] = []
        outputParagraphs.reserveCapacity(paragraphs.count + (hasRemainder ? 1 : 0))
        outputDOMIndices.reserveCapacity(outputParagraphs.capacity)
        outputDOMOffsets.reserveCapacity(outputParagraphs.capacity)

        for index in paragraphs.indices {
            if index != splitIndex {
                outputParagraphs.append(paragraphs[index])
                outputDOMIndices.append(index)
                outputDOMOffsets.append(domCharacterOffsets[index])
                continue
            }
            outputParagraphs.append(candidate.text)
            outputDOMIndices.append(index)
            outputDOMOffsets.append(candidate.sourceUTF16Start)
            if hasRemainder {
                outputParagraphs.append(remainder)
                outputDOMIndices.append(index)
                outputDOMOffsets.append(
                    candidate.sourceUTF16End + leadingWhitespace
                )
            }
        }

        return GoogleBooksSpeechPageSplit(
            paragraphs: outputParagraphs,
            domParagraphIndices: outputDOMIndices,
            domCharacterOffsets: outputDOMOffsets,
            preparedParagraphIndex: splitIndex,
            splitOriginalParagraphIndex: splitIndex,
            insertedRemainder: hasRemainder,
            prefixUTF16Length: prefixLength,
            remainderLeadingWhitespaceUTF16Length: leadingWhitespace
        )
    }
}

/// A source-speech item may already sit behind the current page's audio, but it
/// stays gated until the exact automatic turn and exact committed source split
/// prove that the item is the first native paragraph on the new page. Pages
/// with leading placeholders still reuse the prepared audio after commit, but
/// deliberately take the non-continuous path because an already queued segment
/// cannot safely change paragraph identity while AVPlayer owns it.
enum GoogleBooksSpeechContinuousHandoffContract {
    static func canRelease(
        isAuthorizedAutomaticTurn: Bool,
        issuedTurnIdentityMatches: Bool,
        queueIsIntact: Bool,
        canContinueListening: Bool,
        candidateMatchesCommittedSplit: Bool,
        preparedVoiceID: String,
        selectedVoiceID: String,
        preparedParagraphIndex: Int,
        queuedParagraphIndex: Int
    ) -> Bool {
        isAuthorizedAutomaticTurn
            && issuedTurnIdentityMatches
            && queueIsIntact
            && canContinueListening
            && candidateMatchesCommittedSplit
            && !preparedVoiceID.isEmpty
            && preparedVoiceID == selectedVoiceID
            && preparedParagraphIndex == queuedParagraphIndex
    }
}

/// A queued prediction is stricter than a cache hit: it can become audible
/// only after the same authorized automatic turn commits and the speculative
/// suffix is still attached to the current read-owned queue.
enum GoogleBooksContinuousPageHandoffContract {
    static func canRelease(
        isAuthorizedAutomaticTurn: Bool,
        issuedTurnIdentityMatches: Bool,
        queueIsIntact: Bool,
        canContinueListening: Bool,
        sourceSignature: String,
        issuedBaselineSignature: String,
        predictedParagraphs: [String],
        visibleParagraphs: [String],
        preparedVoiceID: String,
        selectedVoiceID: String
    ) -> Bool {
        isAuthorizedAutomaticTurn
            && issuedTurnIdentityMatches
            && queueIsIntact
            && canContinueListening
            && GoogleBooksSinglePagePreloadContract.canConsume(
                sourceSignature: sourceSignature,
                previousSignature: issuedBaselineSignature,
                predictedParagraphs: predictedParagraphs,
                visibleParagraphs: visibleParagraphs,
                preparedVoiceID: preparedVoiceID,
                selectedVoiceID: selectedVoiceID
            )
    }
}

/// Page-local overlays cannot receive writes from an unconfirmed page owner.
/// Automatic turns retain the last already-painted highlight until the new
/// page commits, while this contract suppresses any later writes that could be
/// routed to a moving/replacement DOM. A confirmed no-change failure may
/// restore mapping ownership; a late Google animation remains fenced.
enum GoogleBooksPageVisualStateContract {
    static func shouldSuppress(
        pendingAutomaticTurn: Bool,
        pendingManualTurn: Bool,
        awaitingReaderRecovery: Bool,
        awaitingLateAutomaticTurn: Bool = false
    ) -> Bool {
        pendingAutomaticTurn
            || pendingManualTurn
            || awaitingReaderRecovery
            || awaitingLateAutomaticTurn
    }

    static func shouldRestoreAfterFailedTurn(
        preserveLateResult: Bool
    ) -> Bool {
        !preserveLateResult
    }
}

/// Preparing next-page work never authorizes an early visual handoff. The
/// current cross-page cue is a UTF-16 ratio and can drift by seconds from the
/// spoken word timestamps, so an active carry may own the committed page only
/// when that page proves a non-empty consumed prefix with a DOM origin.
enum GoogleBooksAudioPageBoundaryContract {
    enum Trigger: Equatable {
        /// Character-ratio/lead-time prediction while the item is audible.
        case estimatedBoundary
        /// AVPlayer attempted to advance from the completed item into a
        /// speculative successor held by the page-commit gate.
        case queuedSuccessorGate
        /// The read/explain VM received terminal playback completion.
        case documentFinished
    }

    static func canRequestPhysicalTurn(after trigger: Trigger) -> Bool {
        switch trigger {
        case .estimatedBoundary:
            return false
        case .queuedSuccessorGate, .documentFinished:
            return true
        }
    }

    static func canCommitActiveCarry(
        carryParagraphIndex: Int?,
        carryUTF16Length: Int,
        carryDOMUTF16Start: Int?
    ) -> Bool {
        carryParagraphIndex != nil
            && carryUTF16Length > 0
            && carryDOMUTF16Start != nil
    }
}

enum GoogleBooksExplainPagePrefetchContract {
    static func canConsume(
        sourceSignature: String,
        previousSignature: String,
        predictedContentFingerprint: String,
        payloadTextFingerprint: String,
        predictedParagraphs: [String],
        visibleParagraphs: [String],
        preparedVoiceID: String,
        selectedVoiceID: String,
        preparedDepth: String,
        selectedDepth: String,
        requestedLanguage: String,
        selectedLanguage: String
    ) -> Bool {
        !predictedContentFingerprint.isEmpty
            && predictedContentFingerprint == payloadTextFingerprint
            && predictedParagraphs == visibleParagraphs
            && preparedDepth == selectedDepth
            && requestedLanguage == selectedLanguage
            && GoogleBooksSinglePagePreloadContract.canConsume(
                sourceSignature: sourceSignature,
                previousSignature: previousSignature,
                predictedParagraphs: predictedParagraphs,
                visibleParagraphs: visibleParagraphs,
                preparedVoiceID: preparedVoiceID,
                selectedVoiceID: selectedVoiceID
            )
    }
}

/// 跨页断句：可见文字停在句中时，上一页会多读到自然句末；新页要把这段已读前缀裁掉。
/// 复用 WeRead 已验证的纯函数契约（`WeReadCrossPageSpeechContract`），两边同一模型。
typealias LiveWebPageSpeechBoundary = WeReadPageSpeechBoundary
typealias LiveWebPageSourceSlice = WeReadSourceTextSlice
typealias LiveWebPageConsumedCursor = WeReadConsumedTextCursor

enum GoogleBooksCrossPageContract {
    /// Map the absolute end of a fully consumed middle visual page onto the
    /// immutable carry audio segment. This prevents a three-page sentence from
    /// flipping pages 2→3 immediately when audio has only reached page 1's
    /// boundary.
    static func visualTurnTime(
        boundaryTime: Double,
        segmentDuration: Double,
        sourceBoundaryUTF16End: Int,
        visibleCarryUTF16End: Int,
        consumedUTF16End: Int
    ) -> Double {
        guard segmentDuration > boundaryTime,
              consumedUTF16End > sourceBoundaryUTF16End else {
            return max(0, min(segmentDuration, boundaryTime))
        }
        let covered = max(
            0,
            min(consumedUTF16End, visibleCarryUTF16End)
                - sourceBoundaryUTF16End
        )
        let total = consumedUTF16End - sourceBoundaryUTF16End
        let fraction = min(1, max(0, Double(covered) / Double(total)))
        return boundaryTime + (segmentDuration - boundaryTime) * fraction
    }

    /// 上一页真正读到的来源坐标：可见结束点 + 补句延长量。
    static func consumedCursor(
        boundary: LiveWebPageSpeechBoundary?,
        sourceParagraphIndex: Int?,
        sourceVisibleEnd: Int?
    ) -> LiveWebPageConsumedCursor? {
        guard let boundary, boundary.isCrossPage,
              let sourceParagraphIndex,
              let sourceVisibleEnd else { return nil }
        let extra = boundary.speechUTF16Length - boundary.visibleUTF16Offset
        guard extra > 0 else { return nil }
        return LiveWebPageConsumedCursor(
            sourceParagraphIndex: sourceParagraphIndex,
            sourceUTF16End: sourceVisibleEnd + extra
        )
    }

    /// Native may remove the prefix that the previous page already spoke.
    /// DOM highlighting and marks still target the complete source `<p>`, so
    /// every visible paragraph needs its final UTF-16 origin after that trim.
    static func domCharacterOffsets(
        in slices: [LiveWebPageSourceSlice],
        through cursor: LiveWebPageConsumedCursor?
    ) -> [Int] {
        slices.map { slice in
            let sourceStart = max(0, slice.sourceUTF16Start ?? 0)
            guard let cursor,
                  slice.sourceParagraphIndex == cursor.sourceParagraphIndex,
                  let sourceEnd = slice.sourceUTF16End,
                  sourceStart < cursor.sourceUTF16End,
                  sourceEnd > sourceStart else {
                return sourceStart
            }

            let text = slice.text as NSString
            let consumedSourceLength = max(
                0,
                min(sourceEnd, cursor.sourceUTF16End) - sourceStart
            )
            let consumedTextLength = min(consumedSourceLength, text.length)
            guard consumedTextLength < text.length else {
                return sourceStart + consumedTextLength
            }

            // `consumeAlreadySpokenPrefix` trims whitespace after clipping.
            // Account for that same leading trim so DOM Range coordinates stay
            // aligned with the exact string handed to the TTS/mark pipelines.
            let suffix = text.substring(from: consumedTextLength) as NSString
            let firstContent = suffix.rangeOfCharacter(
                from: CharacterSet.whitespacesAndNewlines.inverted
            )
            let leadingWhitespace = firstContent.location == NSNotFound
                ? suffix.length
                : firstContent.location
            return sourceStart + consumedTextLength + leadingWhitespace
        }
    }

    /// A visual page may be completely covered by the prior page's natural
    /// sentence. Keep carrying that absolute source cursor until a later page
    /// finally exposes fresh text from the same paragraph.
    static func retainedCursor(
        previous: LiveWebPageConsumedCursor?,
        carryParagraphIndex: Int?
    ) -> LiveWebPageConsumedCursor? {
        carryParagraphIndex == nil ? nil : previous
    }

    /// `speechText` starts at an absolute source-DOM coordinate, while native
    /// may have advanced the visible paragraph origin after clipping an already
    /// spoken prefix. Return the exact remaining UTF-16 suffix used by TTS.
    static func remainingSpeechText(
        _ speechText: String,
        sourceUTF16Start: Int,
        domCharacterOffset: Int,
        sourceParagraphIndex: Int? = nil,
        consumedCursor: LiveWebPageConsumedCursor? = nil
    ) -> String {
        let value = speechText as NSString
        var absoluteClipOffset = domCharacterOffset
        if let sourceParagraphIndex,
           let consumedCursor,
           consumedCursor.sourceParagraphIndex == sourceParagraphIndex {
            // A fully consumed middle page clamps its DOM origin to that
            // page's visible end, but `speechText` may still extend as far as
            // the earlier page already spoke. Clip narration by the absolute
            // cursor, not by the page-local DOM origin, or a three-page
            // sentence repeats its off-screen tail.
            absoluteClipOffset = max(
                absoluteClipOffset,
                consumedCursor.sourceUTF16End
            )
        }
        let clipped = max(
            0,
            min(value.length, absoluteClipOffset - sourceUTF16Start)
        )
        return value.substring(from: clipped)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
