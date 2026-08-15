//
//  WeReadModels.swift
//  CastReader
//
//  Local-only metadata and pure contracts for the user's WeRead shelf.  The
//  reader itself remains the authenticated weread.qq.com WebView: never store
//  credentials or chapter bodies outside that session.
//

import CryptoKit
import Combine
import CoreGraphics
import Foundation

/// WeRead is currently exposed to every CastReader user. Keep the decision in
/// one contract so a future product rollout policy cannot accidentally diverge
/// between Home and Settings; the present contract deliberately has no locale,
/// language, time-zone, account, or storefront restriction.
enum WeReadAvailability {
    static func isAvailable(
        appLanguage: AppLanguage,
        systemLanguageCode: String?,
        timeZoneIdentifier: String
    ) -> Bool {
        // Parameters remain in the API so existing call sites do not grow
        // independent visibility rules. They intentionally do not gate access.
        _ = appLanguage
        _ = systemLanguageCode
        _ = timeZoneIdentifier
        return true
    }

    static var current: Bool { true }
}

struct WeReadBook: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var author: String
    var coverURL: String?
    var readerURL: String
    var progressLabel: String
    var bookID: String?
    var lastOpenedAt: Date?
    var lastSyncedAt: Date
    var lastPageFingerprint: String?
    var lastReaderURL: String?

    var displayAuthor: String {
        author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppLocalized("未知作者") : author
    }

    var displayProgress: String {
        progressLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? AppLocalized("尚未开始") : progressLabel
    }

    var effectiveReaderURL: String { lastReaderURL ?? readerURL }
}

struct WeReadReadingAnchor: Codable, Equatable {
    let bookID: String
    var readerURL: String
    var pageFingerprint: String
    var progressLabel: String?
    var updatedAt: Date
}

/// Stable, metadata-only table-of-contents entry captured from the signed-in
/// WeRead page. `index` is CastReader's display order; `chapterIndex` and
/// `chapterUID` remain the server-authored navigation identity.
struct WeReadTOCEntry: Identifiable, Codable, Equatable {
    let index: Int
    let chapterIndex: Int
    let chapterUID: String
    let title: String
    let level: Int
    var active: Bool

    var id: String {
        chapterUID.isEmpty ? "index:\(chapterIndex)" : "uid:\(chapterUID)"
    }

    /// Presentation-only DOM rows are not navigation targets. A chapter can
    /// only be selected after WeRead has supplied its server-authored UID.
    var isActionable: Bool { !chapterUID.isEmpty }

    init(
        index: Int,
        chapterIndex: Int,
        chapterUID: String,
        title: String,
        level: Int = 0,
        active: Bool = false
    ) {
        self.index = max(0, index)
        self.chapterIndex = chapterIndex
        self.chapterUID = chapterUID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.level = max(0, level)
        self.active = active
    }
}

/// Native TOC presentation state. Chapter bodies and WeRead credentials never
/// leave WKWebView; only title/UID/index metadata is cached so the panel opens
/// immediately on a later visit and refreshes against the live session.
@MainActor
final class WeReadTOCController: ObservableObject {
    @Published private(set) var entries: [WeReadTOCEntry] = []
    @Published private(set) var isLoading = false
    @Published private(set) var isJumping = false
    @Published private(set) var errorText: String?
    @Published var isPresented = false

    var onLoad: (() -> Void)?
    var onSelect: ((WeReadTOCEntry) -> Void)?

    private var bookID = ""
    private var didLoadCache = false

    init(bookID: String = "") {
        if !bookID.isEmpty { configure(bookID: bookID) }
    }

    func configure(bookID: String) {
        guard self.bookID != bookID || !didLoadCache else { return }
        self.bookID = bookID
        didLoadCache = true
        entries = []
        isLoading = false
        isJumping = false
        errorText = nil
        isPresented = false
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode([WeReadTOCEntry].self, from: data) else { return }
        // Older builds persisted title/index-only DOM rows. Keeping them made
        // the native sheet look actionable even though no deterministic
        // chapter route could be constructed.
        entries = Self.normalized(cached).filter(\.isActionable)
    }

    func present() {
        isPresented = true
        isLoading = true
        errorText = nil
        onLoad?()
    }

    func dismiss() {
        guard !isJumping else { return }
        isPresented = false
    }

    func select(_ entry: WeReadTOCEntry) {
        // A cached catalog is immediately actionable while the live catalog
        // refreshes in the background. Only block when there is no stable
        // entry to select yet, or a prior chapter jump is still in flight.
        guard !isJumping, entry.isActionable, !entries.isEmpty else {
            errorText = AppLocalized("正在同步微信读书目录，请稍后重试。")
            return
        }
        if entry.active {
            isPresented = false
            return
        }
        isPresented = false
        isJumping = true
        errorText = nil
        onSelect?(entry)
    }

    func receive(
        _ next: [WeReadTOCEntry],
        currentChapterUID: String?,
        currentChapterIndex: Int?
    ) {
        let normalized = Self.normalized(next)
        let stable = normalized.filter(\.isActionable)
        if !stable.isEmpty {
            entries = Self.markingCurrent(
                stable,
                chapterUID: currentChapterUID,
                chapterIndex: currentChapterIndex
            )
            persist()
        }
        isLoading = false
        errorText = entries.isEmpty ? AppLocalized("正在同步微信读书目录，请稍后重试。") : nil
    }

    func failLoading(_ message: String? = nil) {
        isLoading = false
        errorText = message ?? AppLocalized("暂未找到这本书的目录。")
    }

    func finishJump(to entry: WeReadTOCEntry) {
        entries = Self.markingCurrent(
            entries,
            chapterUID: entry.chapterUID,
            chapterIndex: entry.chapterIndex
        )
        isJumping = false
        errorText = nil
        persist()
    }

    func failJump(_ message: String? = nil) {
        isJumping = false
        isPresented = true
        errorText = message ?? AppLocalized("跳转失败，请重试。")
    }

    static func normalized(_ source: [WeReadTOCEntry]) -> [WeReadTOCEntry] {
        var seen = Set<String>()
        return source
            .sorted { lhs, rhs in
                lhs.index == rhs.index ? lhs.chapterIndex < rhs.chapterIndex : lhs.index < rhs.index
            }
            .filter { entry in
                guard !entry.title.isEmpty else { return false }
                let key = entry.chapterUID.isEmpty ? "index:\(entry.chapterIndex)" : "uid:\(entry.chapterUID)"
                return seen.insert(key).inserted
            }
            .enumerated()
            .map { offset, entry in
                WeReadTOCEntry(
                    index: offset,
                    chapterIndex: entry.chapterIndex,
                    chapterUID: entry.chapterUID,
                    title: entry.title,
                    level: entry.level,
                    active: entry.active
                )
            }
    }

    static func markingCurrent(
        _ source: [WeReadTOCEntry],
        chapterUID: String?,
        chapterIndex: Int?
    ) -> [WeReadTOCEntry] {
        let uid = chapterUID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasUIDMatch = !uid.isEmpty && source.contains { $0.chapterUID == uid }
        return source.map { entry in
            var value = entry
            value.active = hasUIDMatch
                ? entry.chapterUID == uid
                : chapterIndex.map { entry.chapterIndex == $0 } ?? entry.active
            return value
        }
    }

    private var cacheKey: String {
        let digest = SHA256.hash(data: Data(bookID.utf8))
        return "castreader.weread.toc." + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private func persist() {
        guard !bookID.isEmpty,
              let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }
}

struct WeReadAccountInfo: Codable, Equatable {
    var label: String?
}

enum WeReadLibrarySort: String, CaseIterable, Identifiable {
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

enum WeReadBookValidator {
    static func usableReaderURL(_ raw: String?) -> String? {
        guard let raw, let components = URLComponents(string: raw),
              let host = components.host?.lowercased(), host.hasSuffix("weread.qq.com") else { return nil }
        let path = components.path.lowercased()
        guard path.contains("web/reader") || path.contains("reader") else { return nil }
        return components.url?.absoluteString
    }

    static func isLikelyLibraryBook(_ book: WeReadBook) -> Bool {
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 1, usableReaderURL(book.readerURL) != nil else { return false }
        let discarded = ["微信读书", "登录", "扫码", "书架", "推荐", "搜索", "书籍封面", "图书封面", "封面", "book cover", "cover"]
        return !discarded.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame })
    }

    static func stableID(bookID: String?, readerURL: String, title: String) -> String {
        if let bookID, !bookID.isEmpty { return "weread:\(bookID)" }
        let payload = "\(readerURL)|\(title)"
        let digest = SHA256.hash(data: Data(payload.utf8))
        return "weread:" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// Only the authenticated desktop shelf may author the local WeRead library.
/// Marketing/home/reader pages also contain valid-looking `/reader/` links,
/// so accepting a loose `contains("shelf")` check can persist recommendations
/// as if they belonged to the signed-in user's shelf.
enum WeReadShelfPageContract {
    static func isExactShelfURL(_ raw: String?) -> Bool {
        guard let raw,
              let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "weread.qq.com",
              components.user == nil,
              components.password == nil,
              components.port == nil || components.port == 443 else { return false }
        return components.path == "/web/shelf" || components.path == "/web/shelf/"
    }

    static func isExactShelfURL(_ url: URL?) -> Bool {
        isExactShelfURL(url?.absoluteString)
    }
}

enum WeReadBookEntryRecoveryContract {
    /// A fresh shelf URL is server-authored and therefore supersedes a local
    /// resume URL only when the canonical entry itself changed. Unchanged shelf
    /// scans must not rewind a healthy reader session.
    static func shouldDiscardResumeURL(
        oldCanonicalURL: String,
        newCanonicalURL: String,
        resumeURL: String?
    ) -> Bool {
        guard resumeURL != nil else { return false }
        return oldCanonicalURL != newCanonicalURL
    }

    /// First recovery is intentionally cheap: if the failed URL was the local
    /// resume URL and a different canonical shelf entry is available, retry it
    /// once before opening/scanning the shelf.
    static func localFallbackURL(
        failedURL: String?,
        canonicalURL: String,
        resumeURL: String?
    ) -> String? {
        guard let failedURL,
              let resumeURL,
              failedURL == resumeURL,
              canonicalURL != resumeURL,
              WeReadBookValidator.usableReaderURL(canonicalURL) != nil else { return nil }
        return canonicalURL
    }
}

struct WeReadScanResult {
    var pageURL: String?
    var isShelfPage: Bool
    var documentReady: Bool
    var reachedShelfEnd: Bool
    var loading: Bool
    var emptyShelfEvidence: Bool
    var rawBookCount: Int
    var authRequired: Bool
    var authenticated: Bool
    var account: String?
    var books: [WeReadBook]

    init(_ raw: [String: Any]) {
        pageURL = raw["url"] as? String
        isShelfPage = (raw["isShelfPage"] as? Bool ?? false)
            && WeReadShelfPageContract.isExactShelfURL(pageURL)
        documentReady = raw["documentReady"] as? Bool ?? false
        reachedShelfEnd = raw["reachedShelfEnd"] as? Bool ?? false
        loading = raw["loading"] as? Bool ?? true
        emptyShelfEvidence = raw["emptyShelfEvidence"] as? Bool ?? false
        rawBookCount = max(0, raw["rawBookCount"] as? Int ?? 0)
        authRequired = raw["authRequired"] as? Bool ?? true
        authenticated = raw["authenticated"] as? Bool ?? false
        account = raw["account"] as? String
        // Defense in depth: even if page JavaScript accidentally returns
        // reader cards for a home/recommendation page, native code discards
        // them unless the reported URL is the exact trusted shelf URL.
        let rawBooks = isShelfPage ? (raw["books"] as? [[String: Any]] ?? []) : []
        books = rawBooks.compactMap { item in
            let reader = item["readerURL"] as? String ?? ""
            let title = item["title"] as? String ?? ""
            guard let url = WeReadBookValidator.usableReaderURL(reader), !title.isEmpty else { return nil }
            let bookID = item["bookId"] as? String
            let id = WeReadBookValidator.stableID(bookID: bookID, readerURL: url, title: title)
            return WeReadBook(
                id: id,
                title: title,
                author: item["author"] as? String ?? "",
                coverURL: item["coverURL"] as? String,
                readerURL: url,
                progressLabel: item["progressLabel"] as? String ?? "",
                bookID: bookID,
                lastOpenedAt: nil,
                lastSyncedAt: Date(),
                lastPageFingerprint: nil,
                lastReaderURL: nil
            )
        }
    }
}

/// A page turn has exactly one semantic action.  A new page is accepted only
/// after its visible-surface fingerprint changes; retries/keyboard fallbacks
/// are intentionally forbidden because they can skip a WeRead page.
enum WeReadPageTurnContract {
    static let manualRestartDelayNanoseconds: UInt64 = 600_000_000

    static func canCommit(previous: String?, next: String?, actionID: String) -> Bool {
        guard !actionID.isEmpty, let previous, let next else { return false }
        return !previous.isEmpty && !next.isEmpty && previous != next
    }

    static func semanticNextLabels() -> Set<String> { ["下一页"] }
}

/// QuickRead owns its own page lifecycle. A Canvas repaint caused by marks,
/// status UI, foreground recovery, or an incidental layout pass is not a page
/// turn. Only an explicit pointer intent, a semantic auto-turn, or an active
/// navigation refresh may replace the page underneath an explanation session.
enum WeReadExplainPageEventContract {
    static func shouldHandleVisualChange(
        isReadMode: Bool,
        reason: String,
        hasPendingSemanticTurn: Bool,
        hasPendingManualTurn: Bool,
        refreshActive: Bool
    ) -> Bool {
        if isReadMode || hasPendingSemanticTurn || hasPendingManualTurn || refreshActive {
            return true
        }
        return reason == "manual-intent"
    }

    /// Match the extension: a manual page turn closes the current page-only
    /// explanation. Only QuickRead's own automatic next-page request continues
    /// by generating the newly confirmed page.
    static func shouldResumeExplanation(
        isAutomaticTurn: Bool,
        resumeAlreadyArmed: Bool = false,
        wasLiveExplaining: Bool = false
    ) -> Bool {
        isAutomaticTurn || resumeAlreadyArmed || wasLiveExplaining
    }
}

struct WeReadSpeculativeTextMatch: Equatable {
    let isCompatible: Bool
    let matchedCharacters: Int
    let predictedCoverage: Double
    let visibleCoverage: Double
}

/// WeRead lays out the same chapter into visual pages with slightly different
/// character capacities (paragraph spacing, footnotes and the pager all affect
/// the final edge). A sequential preview can therefore be the correct next page
/// while having a different whole-page fingerprint. Validate the ordered text
/// itself: the prepared prefix must cover most of the prediction and a
/// substantial part of the confirmed visible page. Small leading offsets are
/// allowed for a sentence already carried across the previous page.
enum WeReadSpeculativeTextContract {
    private static func normalizedScalars(_ paragraphs: [String]) -> [Unicode.Scalar] {
        let raw = paragraphs.joined()
            .precomposedStringWithCompatibilityMapping
            .lowercased()
        return raw.unicodeScalars.compactMap { scalar in
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { return nil }
            switch scalar.value {
            case 0x2018, 0x2019, 0x201A, 0x201B: return Unicode.Scalar(0x27)
            case 0x201C, 0x201D, 0x201E, 0x201F: return Unicode.Scalar(0x22)
            case 0x2013, 0x2014: return Unicode.Scalar(0x2D)
            default: return scalar
            }
        }
    }

    static func evaluate(predicted: [String], visible: [String]) -> WeReadSpeculativeTextMatch {
        let lhs = normalizedScalars(predicted)
        let rhs = normalizedScalars(visible)
        guard !lhs.isEmpty, !rhs.isEmpty else {
            return WeReadSpeculativeTextMatch(
                isCompatible: false,
                matchedCharacters: 0,
                predictedCoverage: 0,
                visibleCoverage: 0
            )
        }

        let maxPredictedSkip = min(120, lhs.count - 1)
        let maxVisibleSkip = min(48, rhs.count - 1)
        var best = 0
        for predictedStart in 0...maxPredictedSkip {
            for visibleStart in 0...maxVisibleSkip where lhs[predictedStart] == rhs[visibleStart] {
                var length = 0
                while predictedStart + length < lhs.count,
                      visibleStart + length < rhs.count,
                      lhs[predictedStart + length] == rhs[visibleStart + length] {
                    length += 1
                }
                best = max(best, length)
            }
        }
        let predictedCoverage = Double(best) / Double(lhs.count)
        let visibleCoverage = Double(best) / Double(rhs.count)
        let minimumRun = min(32, max(12, min(lhs.count, rhs.count) / 4))
        return WeReadSpeculativeTextMatch(
            isCompatible: best >= minimumRun && predictedCoverage >= 0.70 && visibleCoverage >= 0.42,
            matchedCharacters: best,
            predictedCoverage: predictedCoverage,
            visibleCoverage: visibleCoverage
        )
    }
}

/// A speculative next-page explanation is only a cache. It may replace the
/// normal QuickRead startup after the real Canvas has confirmed that it is the
/// predicted sequential page and the user has not changed voice/depth.
enum WeReadExplainPagePrefetchContract {
    static func canConsume(
        sourceFingerprint: String,
        previousFingerprint: String,
        predictedContentFingerprint: String,
        visibleContentFingerprint: String,
        predictedText: [String],
        visibleText: [String],
        payloadTextFingerprint: String,
        preparedVoiceID: String,
        selectedVoiceID: String,
        preparedDepth: String,
        selectedDepth: String
    ) -> Bool {
        !sourceFingerprint.isEmpty &&
            sourceFingerprint == previousFingerprint &&
            !predictedContentFingerprint.isEmpty &&
            (predictedContentFingerprint == visibleContentFingerprint ||
                WeReadSpeculativeTextContract.evaluate(
                    predicted: predictedText,
                    visible: visibleText
                ).isCompatible) &&
            payloadTextFingerprint == predictedContentFingerprint &&
            !preparedVoiceID.isEmpty && preparedVoiceID == selectedVoiceID &&
            preparedDepth == selectedDepth
    }
}

/// Evidence collected from the visible WeRead surface.  `contentFingerprint`
/// represents the text the user can actually see; `layoutFingerprint` comes
/// from Canvas fillText generations; `columnFingerprint` is the drawImage
/// source-column signature used by paginated/spread mode.
struct WeReadPageEvidence: Equatable {
    var contentFingerprint: String
    var layoutFingerprint: String
    var columnFingerprint: String
    var canvasEpoch: Int
}

extension WeReadPageTurnContract {
    /// A semantic action is necessary but never sufficient.  A turn is
    /// committed only after at least one visible-surface signal changes.
    static func canCommit(
        previous: WeReadPageEvidence?,
        next: WeReadPageEvidence?,
        actionID: String
    ) -> Bool {
        guard !actionID.isEmpty, let previous, let next else { return false }
        let contentChanged = !previous.contentFingerprint.isEmpty &&
            !next.contentFingerprint.isEmpty &&
            previous.contentFingerprint != next.contentFingerprint
        let layoutChanged = !previous.layoutFingerprint.isEmpty &&
            !next.layoutFingerprint.isEmpty &&
            previous.layoutFingerprint != next.layoutFingerprint
        let columnsChanged = !previous.columnFingerprint.isEmpty &&
            !next.columnFingerprint.isEmpty &&
            previous.columnFingerprint != next.columnFingerprint
        return contentChanged || layoutChanged || columnsChanged
    }
}

/// Scheduling and identity checks for a gapless WeRead page boundary.  A
/// speculative page is useful only as a cache: visible Canvas evidence remains
/// authoritative, and the prepared audio is released only after an exact text
/// fingerprint match.
enum WeReadContinuousPageHandoffContract {
    /// WeRead's Canvas bridge debounces at 240 ms and confirms stability at
    /// 120 ms.  The default adds native/WebKit handoff margin without moving
    /// the visual page a full second before the spoken boundary.
    static let visualTurnLeadSeconds: Double = 0.65

    static func shouldArm(
        sourceFingerprint: String,
        currentFingerprint: String,
        hasPreparedAudio: Bool,
        isLastReadableParagraph: Bool,
        currentTTSComplete: Bool,
        audioIsPlaying: Bool
    ) -> Bool {
        !sourceFingerprint.isEmpty && sourceFingerprint == currentFingerprint &&
            hasPreparedAudio && isLastReadableParagraph && currentTTSComplete && audioIsPlaying
    }

    static func shouldBeginVisualTurn(
        currentSegmentID: String?,
        predecessorSegmentID: String,
        remainingAudioSeconds: Double,
        playbackRate: Float,
        leadSeconds: Double = visualTurnLeadSeconds
    ) -> Bool {
        guard currentSegmentID == predecessorSegmentID,
              remainingAudioSeconds >= 0 else { return false }
        return remainingAudioSeconds / max(0.25, Double(playbackRate)) <= max(0.2, leadSeconds)
    }

    static func canReleasePreparedAudio(
        sourceFingerprint: String,
        previousFingerprint: String,
        predictedContentFingerprint: String,
        visibleContentFingerprint: String,
        preparedText: String,
        visiblePreparedText: String,
        preparedVoiceID: String,
        selectedVoiceID: String
    ) -> Bool {
        !sourceFingerprint.isEmpty && sourceFingerprint == previousFingerprint &&
            !predictedContentFingerprint.isEmpty &&
            predictedContentFingerprint == visibleContentFingerprint &&
            !preparedText.isEmpty && preparedText == visiblePreparedText &&
            !preparedVoiceID.isEmpty && preparedVoiceID == selectedVoiceID
    }
}

/// The live Canvas may cut a natural sentence at the visual page edge.  The
/// speech paragraph keeps that sentence whole; this boundary records where the
/// currently visible glyphs end inside the extended paragraph.
struct WeReadPageSpeechBoundary: Equatable {
    let paragraphIndex: Int
    let visibleUTF16Offset: Int
    let speechUTF16Length: Int
    let sourceLayoutFingerprint: String?
    let sourceParagraphIndex: Int?
    let sourceSpeechEnd: Int?

    init(
        paragraphIndex: Int,
        visibleUTF16Offset: Int,
        speechUTF16Length: Int,
        sourceLayoutFingerprint: String? = nil,
        sourceParagraphIndex: Int? = nil,
        sourceSpeechEnd: Int? = nil
    ) {
        self.paragraphIndex = paragraphIndex
        self.visibleUTF16Offset = visibleUTF16Offset
        self.speechUTF16Length = speechUTF16Length
        self.sourceLayoutFingerprint = sourceLayoutFingerprint
        self.sourceParagraphIndex = sourceParagraphIndex
        self.sourceSpeechEnd = sourceSpeechEnd
    }

    var isCrossPage: Bool {
        paragraphIndex >= 0 && visibleUTF16Offset > 0 && speechUTF16Length > visibleUTF16Offset
    }
}

struct WeReadBoundaryAudioCue: Equatable {
    let segmentID: String
    let segmentSequence: Int
    let boundaryTime: Double
    let segmentDuration: Double
    let consumedCursor: WeReadConsumedTextCursor?

    init(
        segmentID: String,
        segmentSequence: Int,
        boundaryTime: Double,
        segmentDuration: Double,
        consumedCursor: WeReadConsumedTextCursor? = nil
    ) {
        self.segmentID = segmentID
        self.segmentSequence = segmentSequence
        self.boundaryTime = boundaryTime
        self.segmentDuration = segmentDuration
        self.consumedCursor = consumedCursor
    }
}

/// Stable source-DOM cursor carried across a visual WeRead page turn. The old
/// page may synthesize one complete natural sentence past the visible edge;
/// every new-page path must therefore skip source text before this cursor,
/// regardless of whether speculative audio was ready.
struct WeReadConsumedTextCursor: Equatable {
    let sourceLayoutFingerprint: String?
    let sourceParagraphIndex: Int
    let sourceUTF16End: Int

    init(
        sourceLayoutFingerprint: String? = nil,
        sourceParagraphIndex: Int,
        sourceUTF16End: Int
    ) {
        self.sourceLayoutFingerprint = sourceLayoutFingerprint
        self.sourceParagraphIndex = sourceParagraphIndex
        self.sourceUTF16End = sourceUTF16End
    }
}

struct WeReadSourceTextSlice: Equatable {
    let visibleParagraphIndex: Int
    let sourceLayoutFingerprint: String?
    let sourceParagraphIndex: Int?
    let sourceUTF16Start: Int?
    let sourceUTF16End: Int?
    let text: String

    init(
        visibleParagraphIndex: Int,
        sourceLayoutFingerprint: String? = nil,
        sourceParagraphIndex: Int?,
        sourceUTF16Start: Int?,
        sourceUTF16End: Int?,
        text: String
    ) {
        self.visibleParagraphIndex = visibleParagraphIndex
        self.sourceLayoutFingerprint = sourceLayoutFingerprint
        self.sourceParagraphIndex = sourceParagraphIndex
        self.sourceUTF16Start = sourceUTF16Start
        self.sourceUTF16End = sourceUTF16End
        self.text = text
    }
}

struct WeReadPageConsumption: Equatable {
    let texts: [String]
    let carryParagraphIndex: Int?
    let carryUTF16Length: Int
}

/// Pure mapping from the page's source-text boundary to the single TTS API
/// segment that owns it. Segment-timed languages generate one natural sentence
/// per request, so a cross-page sentence remains one audio item rather than two
/// clipped requests with an audible restart.
enum WeReadCrossPageSpeechContract {
    static func shouldApplyConsumedCursor(
        pendingSemanticTurn: Bool,
        continuationSuppressed: Bool
    ) -> Bool {
        pendingSemanticTurn && !continuationSuppressed
    }

    static func shouldClearContinuationSuppressionWhenReturningToRead(
        pendingSemanticTurn: Bool
    ) -> Bool {
        !pendingSemanticTurn
    }

    static func consumeAlreadySpokenPrefix(
        in slices: [WeReadSourceTextSlice],
        through cursor: WeReadConsumedTextCursor?,
        requireSourceLayoutIdentity: Bool = false
    ) -> WeReadPageConsumption {
        guard let cursor else {
            return WeReadPageConsumption(
                texts: slices.map(\.text),
                carryParagraphIndex: nil,
                carryUTF16Length: 0
            )
        }

        var carryParagraphIndex: Int?
        var carryUTF16Length = 0
        let texts = slices.map { slice -> String in
            let sourceIdentityMatches: Bool
            if let identity = cursor.sourceLayoutFingerprint, !identity.isEmpty {
                sourceIdentityMatches = slice.sourceLayoutFingerprint == identity
            } else {
                sourceIdentityMatches = !requireSourceLayoutIdentity
            }
            guard sourceIdentityMatches,
                  slice.sourceParagraphIndex == cursor.sourceParagraphIndex,
                  let sourceStart = slice.sourceUTF16Start,
                  let sourceEnd = slice.sourceUTF16End,
                  sourceStart < cursor.sourceUTF16End,
                  sourceEnd > sourceStart else { return slice.text }

            let consumed = max(0, min(sourceEnd, cursor.sourceUTF16End) - sourceStart)
            let value = slice.text as NSString
            let clipped = min(consumed, value.length)
            guard clipped > 0 else { return slice.text }
            if carryParagraphIndex == nil {
                carryParagraphIndex = slice.visibleParagraphIndex
                carryUTF16Length = clipped
            }
            return value.substring(from: clipped)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return WeReadPageConsumption(
            texts: texts,
            carryParagraphIndex: carryParagraphIndex,
            carryUTF16Length: carryUTF16Length
        )
    }

    static func boundarySegment(
        segmentTexts: [String],
        boundaryUTF16Offset: Int
    ) -> (sequence: Int, fraction: Double)? {
        guard boundaryUTF16Offset > 0, !segmentTexts.isEmpty else { return nil }
        var cursor = 0
        for (sequence, text) in segmentTexts.enumerated() {
            let length = (text as NSString).length
            guard length > 0 else { continue }
            let end = cursor + length
            if boundaryUTF16Offset <= end {
                let local = max(0, min(length, boundaryUTF16Offset - cursor))
                return (sequence, min(1, max(0, Double(local) / Double(length))))
            }
            cursor = end
        }
        return nil
    }

    static func shouldRequestTurn(
        currentSegmentID: String?,
        cue: WeReadBoundaryAudioCue,
        currentTime: Double,
        playbackRate: Float,
        leadSeconds: Double
    ) -> Bool {
        guard currentSegmentID == cue.segmentID else { return false }
        let remaining = max(0, cue.boundaryTime - currentTime)
        return remaining / max(0.25, Double(playbackRate)) <= max(0.2, leadSeconds)
    }
}

/// Sentence-level playback checkpoint used only when the WeRead WebKit context
/// really has to be rebuilt (content-process eviction, theme reload, or a
/// viewport reflow that changes the visible page). A healthy foreground return
/// never consumes this checkpoint because it never reloads the page.
struct WeReadPlaybackResumeAnchor: Equatable {
    let segmentText: String
    let sourceParagraphText: String
    let segmentProgress: Double
    let wasPlaying: Bool
}

enum WeReadPlaybackResumeContract {
    static func paragraphIndex(
        in paragraphs: [ReadingParagraph],
        anchor: WeReadPlaybackResumeAnchor
    ) -> Int? {
        let segment = normalized(anchor.segmentText)
        if segment.count >= 2,
           let match = paragraphs.firstIndex(where: { normalized($0.text).contains(segment) }) {
            return match
        }

        // A viewport change can clip the source paragraph differently. Compare
        // a stable sentence-sized prefix instead of requiring the old full
        // visual paragraph to remain byte-identical.
        let source = normalized(anchor.sourceParagraphText)
        guard source.count >= 8 else { return nil }
        let prefix = String(source.prefix(min(32, source.count)))
        return paragraphs.firstIndex { paragraph in
            let candidate = normalized(paragraph.text)
            return candidate.contains(prefix) || prefix.contains(String(candidate.prefix(min(24, candidate.count))))
        }
    }

    static func segmentMatches(_ candidate: String, anchor: WeReadPlaybackResumeAnchor) -> Bool {
        let lhs = normalized(candidate)
        let rhs = normalized(anchor.segmentText)
        guard lhs.count >= 2, rhs.count >= 2 else { return false }
        if lhs == rhs { return true }
        let shorter = min(lhs.count, rhs.count)
        let longer = max(lhs.count, rhs.count)
        return Double(shorter) / Double(longer) >= 0.78 && (lhs.contains(rhs) || rhs.contains(lhs))
    }

    private static func normalized(_ value: String) -> String {
        let compatible = value.precomposedStringWithCompatibilityMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        let ignored = CharacterSet.whitespacesAndNewlines
            .union(.punctuationCharacters)
            .union(.symbols)
        return String(compatible.unicodeScalars.filter { !ignored.contains($0) })
    }
}

/// A suspended WKWebView can reject JavaScript briefly while iOS is bringing
/// its web-content process back to the foreground. A failed health probe is
/// therefore never evidence that the page should be reloaded. Reloading is
/// reserved for WebKit's explicit process-termination callback; this preserves
/// the exact WeRead page and lets native background audio/page handoff continue.
enum WeReadBackgroundLifecycleContract {
    static let foregroundProbeDelays: [TimeInterval] = [0.28, 0.55, 0.9]
    static let foregroundProbeTimeout: TimeInterval = 0.8

    static func shouldReload(
        probeSucceeded: Bool,
        webContentProcessTerminationObserved: Bool
    ) -> Bool {
        _ = probeSucceeded
        return webContentProcessTerminationObserved
    }

    static func shouldScheduleRefreshFallback(applicationIsActive: Bool) -> Bool {
        applicationIsActive
    }
}

/// WeRead's production reader is responsive even when the desktop user agent is
/// used. Its own CSS switches `.readerChapterContent` to the compact layout at
/// 700 CSS px and below. On phones we create one slightly wider, centre-cropped
/// viewport before navigation so its large desktop-derived gutters do not make
/// the page look miniature. No runtime calibration is allowed to resize it.
struct WeReadViewportCrop: Equatable {
    var widthScale: CGFloat
    var offsetX: CGFloat

    static let compactReaderBreakpoint: CGFloat = 700
    static let compactPageHorizontalPadding: CGFloat = 50
    /// WeRead keeps roughly 70pt of combined reader chrome/gutter on each side
    /// of a 430pt compact viewport.  A 1.19x, centre-cropped opening surface
    /// brings the visible gutter back to about 29pt while the site remains in
    /// its <=700px responsive reader branch.  This is native geometry, not a
    /// post-load CSS transform, so Canvas text and overlay coordinates stay in
    /// the same coordinate system.
    static let compactOpeningWidthScale: CGFloat = 1.19
    /// The exact WKWebView frame to install before the first navigation. The
    /// website must never observe a zero/provisional viewport and then resize.
    func webViewFrame(for surface: CGSize) -> CGRect {
        CGRect(
            x: offsetX,
            y: 0,
            width: surface.width * widthScale,
            height: surface.height
        )
    }

    static func predicted(for surface: CGSize) -> WeReadViewportCrop {
        guard surface.width > 80, surface.height > 80 else {
            return WeReadViewportCrop(widthScale: 1, offsetX: 0)
        }
        guard surface.width <= compactReaderBreakpoint else {
            return WeReadViewportCrop(widthScale: 1, offsetX: 0)
        }
        let scale = compactOpeningWidthScale
        return WeReadViewportCrop(
            widthScale: scale,
            offsetX: -surface.width * (scale - 1) / 2
        )
    }

    /// Centre the visible reader content without changing the WebView's layout
    /// width. Ratios are in the existing WebView viewport coordinate space.
    /// Only `offsetX` may change after navigation; preserving `widthScale`
    /// prevents a second WeRead pagination pass and its visible flash.
    static func calibrated(
        for surface: CGSize,
        layoutWidthScale: CGFloat? = nil,
        contentLeftRatio: CGFloat,
        contentRightRatio: CGFloat
    ) -> WeReadViewportCrop? {
        guard surface.width > 80,
              contentLeftRatio.isFinite,
              contentRightRatio.isFinite,
              contentLeftRatio >= 0,
              contentRightRatio <= 1,
              contentRightRatio > contentLeftRatio else { return nil }
        let coverage = contentRightRatio - contentLeftRatio
        guard coverage >= 0.28 else { return nil }
        _ = layoutWidthScale
        // Runtime text bounds are diagnostics/readiness evidence only. They are
        // never allowed to mutate native geometry after the first navigation.
        return predicted(for: surface)
    }
}

enum WeReadInitialPlaybackContract {
    /// The WebView is shown as soon as navigation completes, but autoplay is
    /// armed only after the first visible-surface commit remains unchanged.
    /// This is intentionally longer than the JS Canvas stability debounce and
    /// prevents provisional hydration/layout output from speaking twice.
    static let stabilityDelayNanoseconds: UInt64 = 1_800_000_000
}

enum WeReadPageFingerprint {
    static func make(first: String, last: String, progress: String, route: String) -> String {
        let normalized = [first, last, progress, route]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}
