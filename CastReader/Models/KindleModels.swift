//
//  KindleModels.swift
//  CastReader
//
//  Native Kindle shelf metadata. Kindle content still comes from the user's
//  authenticated read.amazon.com WebView session; CastReader persists only
//  book metadata and local reading position.
//

import CryptoKit
import Foundation
import SwiftUI

struct KindleBook: Identifiable, Codable, Equatable {
    enum CodingKeys: String, CodingKey {
        case id, asin, title, author, coverURL, readerURL, progressLabel, storefrontID, language, languageSource
        case kindleWritingMode, kindleReadingDirection, kindlePageProgressionDirection
        case lastOpenedAt, lastSyncedAt, lastReadPageKey, lastReadURL
    }

    let id: String
    var asin: String?
    var title: String
    var author: String
    var coverURL: String?
    var readerURL: String
    var progressLabel: String
    /// Amazon marketplace that owns this book. Legacy records are migrated from
    /// their reader URL host by KindleLibraryStore.
    var storefrontID: String? = nil
    var language: String? = nil
    /// `nil` means a legacy/unverified value and must not become the OCR authority.
    var languageSource: String? = nil
    var kindleWritingMode: String? = nil
    var kindleReadingDirection: String? = nil
    var kindlePageProgressionDirection: String? = nil
    var lastOpenedAt: Date?
    var lastSyncedAt: Date
    var lastReadPageKey: String?
    var lastReadURL: String?

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

    var effectiveReaderURL: String {
        KindleBookValidator.repairedReaderURL(for: self, preferLastRead: true) ?? readerURL
    }

    var isLikelyLibraryBook: Bool {
        KindleBookValidator.isLikelyLibraryBook(self)
    }
}

enum KindleReadingDirection: String, Equatable { case ltr, rtl }
enum KindleWritingMode: String, Equatable { case horizontal, vertical }
enum KindleOCREngine: String, Equatable { case vision, tesseract }

struct KindleOCRRoute: Equatable {
    let primary: KindleOCREngine
    let fallback: KindleOCREngine?

    var engines: [KindleOCREngine] {
        fallback.map { [primary, $0] } ?? [primary]
    }
}

struct KindleLanguageProfile: Equatable {
    let language: String
    let visionLocale: String
    let tesseractModel: String
    let readingDirection: KindleReadingDirection
    let pageProgressionFallback: KindleReadingDirection
    let writingMode: KindleWritingMode

    /// Production Kindle playback currently supports horizontal text only.
    /// The bundled vertical-Japanese recognizer remains an isolated experiment;
    /// it must not enter OCR/TTS until its geometry contract is fully verified.
    var isSupported: Bool { writingMode == .horizontal }
}

/// Cross-engine parity is defined by text order + geometry + quality, not by
/// forcing every language through the same binary. Vision is the iOS authority
/// where it has a native model; Hindi and vertical Japanese keep dedicated
/// Tesseract paths.
enum KindleOCRRoutingContract {
    static func route(for profile: KindleLanguageProfile) -> KindleOCRRoute {
        if profile.language == "ja", profile.writingMode == .vertical {
            return KindleOCRRoute(primary: .tesseract, fallback: nil)
        }
        if profile.language == "hi" {
            return KindleOCRRoute(primary: .tesseract, fallback: nil)
        }
        return KindleOCRRoute(primary: .vision, fallback: .tesseract)
    }
}

struct KindleVerticalColumnHint: Equatable {
    let leftRatio: Double
    let rightRatio: Double
    let topRatio: Double
    let bottomRatio: Double
    let expectedCharacters: Int
    let startPositionID: Int?
    let endPositionID: Int?

    var javaScriptValue: [String: Any] {
        var value: [String: Any] = [
            "leftRatio": leftRatio,
            "rightRatio": rightRatio,
            "topRatio": topRatio,
            "bottomRatio": bottomRatio,
            "expectedCharacters": expectedCharacters
        ]
        if let startPositionID { value["startPositionId"] = startPositionID }
        if let endPositionID { value["endPositionId"] = endPositionID }
        return value
    }
}

enum KindleLanguageContract {
    static let trustedLanguageSources: Set<String> = [
        "renderer-metadata", "renderer-token-geometry", "renderer-metadata+geometry", "ocr-consensus-v2"
    ]
    private static let aliases: [String: String] = [
        "eng": "en", "zho": "zh", "chi": "zh", "jpn": "ja",
        "spa": "es", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de", "por": "pt",
        "ita": "it", "hin": "hi"
    ]
    private static let locales: [String: String] = [
        "en": "en-US", "zh": "zh-Hans", "ja": "ja-JP", "es": "es-ES",
        "fr": "fr-FR", "de": "de-DE", "pt": "pt-BR", "it": "it-IT", "hi": "hi-IN"
    ]
    private static let tesseractModels: [String: String] = [
        "en": "eng", "zh": "chi_sim", "ja": "jpn", "es": "spa",
        "fr": "fra", "de": "deu", "pt": "por", "it": "ita", "hi": "hin"
    ]

    static func normalize(_ value: String?) -> String? {
        guard let value else { return nil }
        let primary = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").first.map(String.init) ?? ""
        let language = aliases[primary] ?? primary
        return locales[language] == nil ? nil : language
    }

    static func profile(
        language: String?,
        writingMode: KindleWritingMode = .horizontal,
        readingDirection: KindleReadingDirection? = nil,
        pageProgressionDirection: KindleReadingDirection? = nil
    ) -> KindleLanguageProfile? {
        guard let language = normalize(language),
              let locale = locales[language],
              var tesseractModel = tesseractModels[language] else { return nil }
        if language == "ja", writingMode == .vertical { tesseractModel = "jpn_vert" }
        return KindleLanguageProfile(
            language: language,
            visionLocale: locale,
            tesseractModel: tesseractModel,
            readingDirection: readingDirection ?? (language == "ja" ? .rtl : .ltr),
            pageProgressionFallback: pageProgressionDirection ?? (language == "ja" ? .rtl : .ltr),
            writingMode: writingMode
        )
    }

    static func isVerified(language: String?, source: String?) -> Bool {
        normalize(language) != nil && source.map(trustedLanguageSources.contains) == true
    }

    static func endsWithHardTerminal(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"[.!?。！？…।॥][\s\"'»”’\)\]\）\】\」\』]*$"#, options: .regularExpression) != nil
    }

    /// Script-neutral list boundary used by the OCR paragraph contract.
    /// `\p{Nd}` includes both ASCII and Devanagari digits.
    static func startsWithListMarker(_ value: String) -> Bool {
        value.range(
            of: #"^\s*(?:[•◦▪‣⁃∙·●○■□◆◇►▸]|\p{Nd}{1,3}[\)\]\.．、）:]|[A-Za-z][\)\.])\s*\S"#,
            options: .regularExpression
        ) != nil
    }

    static func endsWithHeadingDelimiter(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"[:：][\s\"'»”’\)\]\）]*$"#, options: .regularExpression) != nil
    }

    static func alignmentText(_ value: String) -> String {
        value.decomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
            .filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) || CharacterSet.nonBaseCharacters.contains($0) }
            .map(String.init).joined()
    }

    static func join(_ parts: [String], language: String) -> String {
        let values = parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return values.joined(separator: normalize(language).map { $0 == "zh" || $0 == "ja" } == true ? "" : " ")
    }

    static func shouldPreferRawParagraphs(language: String, raw: Int, visualLines: Int, rebuilt: Int) -> Bool {
        guard let language = normalize(language), ["zh", "ja", "hi"].contains(language) else { return false }
        return raw > 1 && raw > rebuilt && raw <= visualLines
    }
}

/// What a Kindle page is recognized as when the user has told us what language
/// this book is.
///
/// The three ordinary sources - renderer metadata, a previously verified book
/// profile, and single-locale OCR consensus - are all inference. Metadata can be
/// wrong or missing, and consensus sees one page. Recognizing a page under the
/// wrong locale does not merely mispronounce it: Vision returns the nearest
/// words of the language it was asked for, so an Italian page read as English
/// comes back subtly wrong, and the reader has no other way to say otherwise.
/// A correction therefore outranks all three - the same order as
/// `ReadingLanguagePolicy`, where a user correction outranks any detection.
enum KindleReadingLanguageCorrection {

    /// The profile to recognize with, or nil when there is nothing to correct.
    ///
    /// A correction restates the language, not the page geometry, so the writing
    /// mode observed on the page carries over while reading direction and page
    /// progression fall back to the corrected language's own defaults. Those
    /// defaults are a function of the language - Japanese alone defaults to
    /// right-to-left - so carrying a Japanese default into an Italian book would
    /// reverse its column order.
    static func profile(
        correcting resolved: KindleLanguageProfile?,
        with override: String?
    ) -> KindleLanguageProfile? {
        guard let corrected = KindleLanguageContract.normalize(override),
              corrected != resolved?.language else { return nil }
        return KindleLanguageContract.profile(
            language: corrected,
            writingMode: resolved?.writingMode ?? .horizontal
        )
    }
}

enum KindleWritingModeContract {
    /// Kindle renderer metadata sometimes calls a portrait page/image `vertical`.
    /// Strongly elongated paragraph rectangles are the actual glyph-flow authority.
    static func infer(from paragraphSizes: [CGSize]) -> KindleWritingMode? {
        var horizontalVotes = 0
        var verticalVotes = 0
        for size in paragraphSizes where size.width > 0 && size.height > 0 {
            let ratio = size.width / size.height
            if ratio >= 2.5 { horizontalVotes += 1 }
            else if ratio <= 0.4 { verticalVotes += 1 }
        }
        if horizontalVotes == 0 && verticalVotes == 0 { return nil }
        if horizontalVotes >= max(1, verticalVotes * 2) { return .horizontal }
        if verticalVotes >= max(1, horizontalVotes * 2) { return .vertical }
        return nil
    }
}

enum KindleColumnLayoutContract {
    static func isDualColumn(aspect: CGFloat, pixelsReadable: Bool, centerGutter: Bool) -> Bool {
        if pixelsReadable { return centerGutter }
        return aspect > 1.35
    }

    static func cacheSignature(contentKey: String, pixelFingerprint: String?, pixelSize: CGSize) -> String? {
        guard let pixelFingerprint, !pixelFingerprint.isEmpty else { return nil }
        return "\(contentKey)|\(pixelFingerprint)|\(Int(pixelSize.width))x\(Int(pixelSize.height))"
    }
}

/// Kindle playback lifecycle deliberately separates presentation from session
/// ownership. Mini player and background audio keep the reader surface attached;
/// only a foreground, expanded reader requires every visual update immediately.
enum KindlePlaybackLifecycleContract {
    static func shouldKeepPlayback(surfaceAttached: Bool, explicitlyClosed: Bool) -> Bool {
        surfaceAttached && !explicitlyClosed
    }

    static func requiresImmediateVisualSync(readerPresented: Bool, applicationActive: Bool) -> Bool {
        readerPresented && applicationActive
    }
}

/// Pure scheduling contract for a gapless Kindle page boundary. OCR and the
/// next page's first utterance must both be complete before audio is appended.
/// Kindle may stage its WebView during the old tail, but the held old-page frame
/// is not released until both the spoken boundary and new surface are ready.
enum KindleContinuousPageHandoffContract {
    static func shouldArm(
        isReadMode: Bool,
        isLastReadableParagraph: Bool,
        currentTTSComplete: Bool,
        hasPreparedPage: Bool,
        hasPreparedAudio: Bool,
        audioIsPlaying: Bool
    ) -> Bool {
        isReadMode && isLastReadableParagraph && currentTTSComplete &&
            hasPreparedPage && hasPreparedAudio && audioIsPlaying
    }

    static func shouldBeginVisualTurn(
        currentSegmentID: String?,
        predecessorSegmentID: String,
        remainingAudioSeconds: Double,
        playbackRate: Float,
        wallClockLeadSeconds: Double = 1.4
    ) -> Bool {
        guard currentSegmentID == predecessorSegmentID,
              remainingAudioSeconds >= 0 else { return false }
        let rate = max(0.25, Double(playbackRate))
        return remainingAudioSeconds / rate <= wallClockLeadSeconds
    }

    static func shouldReleaseAudioGate(
        hasConfirmedVisibleSurface: Bool,
        textFingerprintMatches: Bool,
        firstHighlightHandshakeFinished: Bool
    ) -> Bool {
        hasConfirmedVisibleSurface && textFingerprintMatches && firstHighlightHandshakeFinished
    }

    static func shouldReleaseVisualHold(
        audioBoundaryReached: Bool,
        hasConfirmedVisibleSurface: Bool
    ) -> Bool {
        audioBoundaryReached && hasConfirmedVisibleSurface
    }

    /// A continuous handoff may reuse the shared audio queue, but it must never
    /// reuse the previous page's ReadAloudViewModel. Kindle OCR paragraph IDs are
    /// page-local (normally starting at zero), so an ID-only check cannot prove
    /// that the playback owner belongs to the newly visible page.
    static func canAdoptPreparedAudio(
        previousOwnerDocumentID: String?,
        activeOwnerDocumentID: String?,
        targetDocumentID: String
    ) -> Bool {
        guard !targetDocumentID.isEmpty,
              let activeOwnerDocumentID,
              activeOwnerDocumentID == targetDocumentID else { return false }
        guard let previousOwnerDocumentID else { return true }
        return activeOwnerDocumentID != previousOwnerDocumentID
    }

    /// A speculative next-page cache miss is recoverable with fresh audio. If
    /// the player already reached the held queue item before visual confirmation
    /// completed, no second gate callback will arrive by itself; commit the
    /// confirmed surface immediately. When old-page audio is still playing, the
    /// normal queue boundary remains responsible for starting the commit.
    static func shouldCommitConfirmedFallbackAtBoundary(
        hasConfirmedVisibleSurface: Bool,
        textFingerprintMatches: Bool,
        isQueuedSegmentGated: Bool
    ) -> Bool {
        hasConfirmedVisibleSurface && !textFingerprintMatches && isQueuedSegmentGated
    }
}

enum KindleVisualHighlightCompletion: Equatable {
    /// A newer paint task owns the slot. The older completion must not clear it.
    case stale
    /// The active task completed or was cancelled with nothing left to paint.
    case clearOnly
    /// The active task completed and the latest coalesced timestamp should run.
    case drainPending
}

enum KindleVisualHighlightQueueContract {
    static func completion(
        activeSequence: UInt64?,
        completedSequence: UInt64,
        taskCancelled: Bool,
        hasPending: Bool
    ) -> KindleVisualHighlightCompletion {
        guard activeSequence == completedSequence else { return .stale }
        guard !taskCancelled, hasPending else { return .clearOnly }
        return .drainPending
    }
}

/// A Kindle page-turn action is non-idempotent: retrying the action after an
/// observation/cache mismatch skips a page. This contract keeps action dispatch
/// separate from the retryable work of identifying and staging the new surface.
enum KindleContinuousVisualTurnContract {
    static func shouldDispatchSemanticAction(
        expectedKey: String,
        visibleKey: String,
        semanticActionAttempted: Bool,
        confirmedTargetKey: String?
    ) -> Bool {
        let expected = expectedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = visibleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmed = confirmedTargetKey?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !expected.isEmpty && visible != expected &&
            !semanticActionAttempted && confirmed.isEmpty
    }

    /// Prefer the surface returned by the semantic action. If confirmation
    /// failed after dispatch, a visibly changed surface is still recoverable,
    /// but the action itself must never be sent again.
    static func stagingTargetKey(
        oldKey: String,
        expectedKey: String,
        visibleKey: String,
        semanticActionAttempted: Bool,
        confirmedTargetKey: String?
    ) -> String? {
        let old = oldKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = expectedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = visibleKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let confirmed = confirmedTargetKey?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !confirmed.isEmpty { return confirmed }
        if !expected.isEmpty, visible == expected { return expected }
        if semanticActionAttempted, !visible.isEmpty, visible != old { return visible }
        return nil
    }
}

struct KindleReadPageSession: Equatable {
    let generation: UInt64
    let documentID: String
}

/// Page completion is an ownership event, not merely an `isFinished` state.
/// Only the currently installed ReadAloudViewModel may consume the active page
/// session, and each generation is consumable exactly once.
enum KindleReadPageCompletionContract {
    enum Decision: Equatable {
        case accept
        case wrongMode
        case missingPageKey
        case staleOwner
        case staleSession
        case duplicate
    }

    static func decision(
        isReadMode: Bool,
        ownerMatches: Bool,
        activeSession: KindleReadPageSession?,
        eventSession: KindleReadPageSession,
        consumedGeneration: UInt64?,
        currentPageKey: String
    ) -> Decision {
        guard isReadMode else { return .wrongMode }
        guard !currentPageKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .missingPageKey
        }
        guard ownerMatches else { return .staleOwner }
        guard activeSession == eventSession else { return .staleSession }
        guard consumedGeneration != eventSession.generation else { return .duplicate }
        return .accept
    }
}

enum KindleForwardProgress: Equatable { case forward, backward, unchanged, unverifiable }

enum KindleTurnContract {
    private static func asciiDigitNormalized(_ label: String) -> String {
        label.precomposedStringWithCompatibilityMapping.unicodeScalars.map { scalar -> String in
            let value = Int(scalar.value)
            let zero: Int?
            switch value {
            case 0xFF10...0xFF19: zero = 0xFF10
            case 0x0966...0x096F: zero = 0x0966
            case 0x0660...0x0669: zero = 0x0660
            case 0x06F0...0x06F9: zero = 0x06F0
            default: zero = nil
            }
            return zero.map { String(value - $0) } ?? String(scalar)
        }.joined()
    }

    static func progressNumber(_ label: String?) -> Int? {
        guard let label else { return nil }
        let scalars = asciiDigitNormalized(label)
        guard let range = scalars.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(scalars[range])
    }

    /// A failed forward action is a successful reading completion only when
    /// Kindle itself exposes explicit terminal progress. A repeated pixel or a
    /// no-op semantic action alone is not enough evidence: those also occur on
    /// transient renderer failures and must remain navigation failures.
    static func isTerminalProgress(_ label: String?) -> Bool {
        guard let label else { return false }
        let normalized = asciiDigitNormalized(label)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }

        if normalized.contains("%"), let percent = progressNumber(normalized) {
            return percent >= 100
        }

        let expression = try? NSRegularExpression(
            pattern: #"(\d+)\s*(?:of|/)\s*(\d+)"#,
            options: [.caseInsensitive]
        )
        let whole = NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
        guard let match = expression?.firstMatch(in: normalized, range: whole),
              match.numberOfRanges >= 3,
              let currentRange = Range(match.range(at: 1), in: normalized),
              let totalRange = Range(match.range(at: 2), in: normalized),
              let current = Int(normalized[currentRange]),
              let total = Int(normalized[totalRange]),
              total > 0 else { return false }
        return current >= total
    }

    /// Prefer the progress captured from the visible page. Persisted shelf
    /// progress is only a fallback when that live surface did not expose one,
    /// avoiding a stale historical "100%" from misclassifying a real failure.
    static func isTerminalPage(liveProgress: String?, storedProgress: String?) -> Bool {
        if let liveProgress,
           !liveProgress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return isTerminalProgress(liveProgress)
        }
        return isTerminalProgress(storedProgress)
    }

    static func progress(beforeLocation: Int?, afterLocation: Int?, beforeRenderer: Int?, afterRenderer: Int?) -> KindleForwardProgress {
        func compare(_ before: Int?, _ after: Int?) -> KindleForwardProgress? {
            guard let before, let after else { return nil }
            if after > before { return .forward }
            if after < before { return .backward }
            return .unchanged
        }
        if let location = compare(beforeLocation, afterLocation), location != .unchanged { return location }
        if let renderer = compare(beforeRenderer, afterRenderer), renderer != .unchanged { return renderer }
        return compare(beforeLocation, afterLocation) ?? compare(beforeRenderer, afterRenderer) ?? .unverifiable
    }

    static func confirms(progress: KindleForwardProgress, beforeFingerprint: String?, afterFingerprint: String?, semanticActionDispatched: Bool, stableVisualSamples: Int) -> Bool {
        guard let beforeFingerprint, let afterFingerprint, beforeFingerprint != afterFingerprint, progress != .backward else { return false }
        return progress == .forward || (semanticActionDispatched && stableVisualSamples >= 2)
    }
}

/// External Kindle navigation is user intent, not a visual-layout heuristic.
/// OCR preloading and React surface reconciliation can temporarily change the
/// candidate reported by `__crKindleState`; that visual drift must never stop
/// or restart audio unless the Kindle page itself emitted a semantic
/// navigation sequence.
enum KindleExternalNavigationContract {
    static func shouldBeginResume(
        semanticSequenceAdvanced: Bool,
        hasActivePlayback: Bool,
        isReaderStable: Bool,
        isInternalTurnInFlight: Bool
    ) -> Bool {
        semanticSequenceAdvanced &&
            hasActivePlayback &&
            isReaderStable &&
            !isInternalTurnInFlight
    }
}

/// Cross-platform semantic contract for resuming Kindle audio from a sentence-level anchor.
/// `charOffset` is a UTF-16 offset so Swift, Kotlin, and JavaScript can exchange it safely.
struct KindleListeningAnchor: Codable, Equatable {
    static let currentSchemaVersion = 1
    static let currentReaderImplementationVersion = 1

    let bookId: String
    let pageKey: String
    let pageTextHash: String
    let paragraphIndex: Int
    let wordIndex: Int?
    let charOffset: Int
    let anchorPhrase: String
    let anchorWordOffset: Int
    let voice: String
    let speed: Double
    let updatedAt: Date
    let schemaVersion: Int
    let readerImplementationVersion: Int
}

extension KindleListeningAnchor {
    private enum CodingKeys: String, CodingKey {
        case bookId, pageKey, pageTextHash, paragraphIndex, wordIndex, charOffset
        case anchorPhrase, anchorWordOffset, voice, speed, updatedAt
        case schemaVersion, readerImplementationVersion
        case legacyTextHash = "textHash"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        bookId = try values.decode(String.self, forKey: .bookId)
        pageKey = try values.decode(String.self, forKey: .pageKey)
        pageTextHash = try values.decodeIfPresent(String.self, forKey: .pageTextHash)
            ?? values.decode(String.self, forKey: .legacyTextHash)
        paragraphIndex = try values.decode(Int.self, forKey: .paragraphIndex)
        wordIndex = try values.decodeIfPresent(Int.self, forKey: .wordIndex)
        charOffset = try values.decode(Int.self, forKey: .charOffset)
        anchorPhrase = try values.decode(String.self, forKey: .anchorPhrase)
        anchorWordOffset = try values.decode(Int.self, forKey: .anchorWordOffset)
        voice = try values.decode(String.self, forKey: .voice)
        speed = try values.decode(Double.self, forKey: .speed)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        readerImplementationVersion = try values.decode(Int.self, forKey: .readerImplementationVersion)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(bookId, forKey: .bookId)
        try values.encode(pageKey, forKey: .pageKey)
        try values.encode(pageTextHash, forKey: .pageTextHash)
        try values.encode(paragraphIndex, forKey: .paragraphIndex)
        try values.encodeIfPresent(wordIndex, forKey: .wordIndex)
        try values.encode(charOffset, forKey: .charOffset)
        try values.encode(anchorPhrase, forKey: .anchorPhrase)
        try values.encode(anchorWordOffset, forKey: .anchorWordOffset)
        try values.encode(voice, forKey: .voice)
        try values.encode(speed, forKey: .speed)
        try values.encode(updatedAt, forKey: .updatedAt)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encode(readerImplementationVersion, forKey: .readerImplementationVersion)
    }
}

enum KindleListeningAnchorMatch: String, Codable, Equatable {
    case exact
    case relocated
    case fallback
}

struct KindleListeningAnchorResolution: Equatable {
    let match: KindleListeningAnchorMatch
    let paragraphIndex: Int
    let wordIndex: Int?
    let charOffset: Int
    let reason: String
}

struct KindleAnchorPhrase: Equatable {
    let phrase: String
    let anchorWordOffset: Int
}

enum KindleListeningAnchorResolver {
    static func pageTextHash(paragraphs: [ReadingParagraph]) -> String {
        pageTextHash(paragraphTexts: paragraphs.map(\.text))
    }

    static func pageTextHash(paragraphTexts: [String]) -> String {
        let canonical = paragraphTexts
            .map { searchTokens(in: $0).map(\.value).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func charOffset(in paragraph: ReadingParagraph, wordIndex: Int?) -> Int {
        guard let wordIndex, paragraph.words.indices.contains(wordIndex) else { return 0 }
        let ranges = wordRanges(in: paragraph)
        return ranges.first(where: { $0.wordIndex == wordIndex })?.range.location ?? 0
    }

    static func anchorPhrase(in text: String, charOffset: Int) -> KindleAnchorPhrase {
        let tokens = searchTokens(in: text)
        guard !tokens.isEmpty else { return KindleAnchorPhrase(phrase: "", anchorWordOffset: 0) }
        let target = min(max(0, charOffset), (text as NSString).length)
        let targetIndex = tokens.firstIndex(where: { NSLocationInRange(target, $0.range) })
            ?? tokens.firstIndex(where: { $0.range.location >= target })
            ?? (tokens.count - 1)
        let start = max(0, targetIndex - 5)
        let end = min(tokens.count, targetIndex + 6)
        return KindleAnchorPhrase(
            phrase: tokens[start..<end].map(\.value).joined(separator: " "),
            anchorWordOffset: targetIndex - start
        )
    }

    static func resolve(
        _ anchor: KindleListeningAnchor,
        bookId: String,
        pageKey: String,
        paragraphs: [ReadingParagraph],
        currentTextHash: String? = nil
    ) -> KindleListeningAnchorResolution {
        let fallback = fallbackResolution(paragraphs: paragraphs, reason: "unavailable")
        guard anchor.schemaVersion == KindleListeningAnchor.currentSchemaVersion else {
            return fallbackResolution(paragraphs: paragraphs, reason: "schema-mismatch")
        }
        guard anchor.readerImplementationVersion == KindleListeningAnchor.currentReaderImplementationVersion else {
            return fallbackResolution(paragraphs: paragraphs, reason: "reader-version-mismatch")
        }
        guard anchor.bookId == bookId else {
            return fallbackResolution(paragraphs: paragraphs, reason: "book-mismatch")
        }
        let expectedKey = anchor.pageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let actualKey = pageKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expectedKey.isEmpty, expectedKey == actualKey else {
            return fallbackResolution(paragraphs: paragraphs, reason: "page-key-mismatch")
        }
        guard fallback.paragraphIndex >= 0 else { return fallback }

        let currentHash = currentTextHash ?? pageTextHash(paragraphs: paragraphs)
        if currentHash == anchor.pageTextHash,
           let paragraph = paragraphs.first(where: { $0.id == anchor.paragraphIndex }) {
            let nsLength = (paragraph.text as NSString).length
            let offset = min(max(0, anchor.charOffset), nsLength)
            let word = validatedWordIndex(anchor.wordIndex, paragraph: paragraph)
                ?? nearestWordIndex(in: paragraph, charOffset: offset)
            return KindleListeningAnchorResolution(
                match: .exact,
                paragraphIndex: paragraph.id,
                wordIndex: word,
                charOffset: offset,
                reason: "page-key-and-hash"
            )
        }

        let phraseTokens = searchTokens(in: anchor.anchorPhrase).map(\.value)
        guard !phraseTokens.isEmpty else {
            return fallbackResolution(paragraphs: paragraphs, reason: "text-hash-mismatch-no-phrase")
        }
        let candidates = locateCandidates(
            phraseTokens: phraseTokens,
            anchorWordOffset: anchor.anchorWordOffset,
            in: paragraphs
        )
        guard let best = candidates.first, best.score >= 0.84 else {
            return fallbackResolution(paragraphs: paragraphs, reason: "anchor-score-low")
        }
        if candidates.count > 1, best.score - candidates[1].score < 0.12 {
            return fallbackResolution(paragraphs: paragraphs, reason: "anchor-ambiguous")
        }
        if best.score >= 0.84 {
            return KindleListeningAnchorResolution(
                match: .relocated,
                paragraphIndex: best.paragraph.id,
                wordIndex: nearestWordIndex(in: best.paragraph, charOffset: best.charOffset),
                charOffset: best.charOffset,
                reason: "anchor-fuzzy"
            )
        }
        return fallbackResolution(paragraphs: paragraphs, reason: "anchor-score-low")
    }

    private struct LocatedPhrase {
        let paragraph: ReadingParagraph
        let charOffset: Int
        let score: Double
    }

    private struct WordRange {
        let wordIndex: Int
        let range: NSRange
    }

    private struct SearchToken {
        let value: String
        let range: NSRange
    }

    private static func locateCandidates(
        phraseTokens: [String],
        anchorWordOffset: Int,
        in paragraphs: [ReadingParagraph]
    ) -> [LocatedPhrase] {
        guard !phraseTokens.isEmpty else { return [] }
        let anchorOffset = min(max(0, anchorWordOffset), phraseTokens.count - 1)
        var matches: [LocatedPhrase] = []
        for paragraph in paragraphs where paragraph.type.isReadable {
            let tokens = searchTokens(in: paragraph.text)
            guard !tokens.isEmpty else { continue }
            for center in tokens.indices {
                let start = center - anchorOffset
                guard start >= 0, start < tokens.count else { continue }
                let end = min(tokens.count, start + phraseTokens.count)
                let candidate = Array(tokens[start..<end].map(\.value))
                let score = tokenSimilarity(phraseTokens, candidate)
                let resolvedCenter = min(tokens.count - 1, start + anchorOffset)
                matches.append(LocatedPhrase(
                    paragraph: paragraph,
                    charOffset: tokens[resolvedCenter].range.location,
                    score: score
                ))
            }
        }
        return matches.sorted {
            if $0.score == $1.score {
                if $0.paragraph.id == $1.paragraph.id { return $0.charOffset < $1.charOffset }
                return $0.paragraph.id < $1.paragraph.id
            }
            return $0.score > $1.score
        }
    }

    private static func fallbackResolution(paragraphs: [ReadingParagraph], reason: String) -> KindleListeningAnchorResolution {
        guard let paragraph = paragraphs.first(where: {
            $0.type.isReadable && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            return KindleListeningAnchorResolution(
                match: .fallback,
                paragraphIndex: -1,
                wordIndex: nil,
                charOffset: 0,
                reason: reason
            )
        }
        return KindleListeningAnchorResolution(
            match: .fallback,
            paragraphIndex: paragraph.id,
            wordIndex: paragraph.words.isEmpty ? nil : 0,
            charOffset: 0,
            reason: reason
        )
    }

    private static func validatedWordIndex(_ wordIndex: Int?, paragraph: ReadingParagraph) -> Int? {
        guard let wordIndex, paragraph.words.indices.contains(wordIndex) else { return nil }
        return wordIndex
    }

    private static func nearestWordIndex(in paragraph: ReadingParagraph, charOffset: Int) -> Int? {
        let ranges = wordRanges(in: paragraph)
        guard !ranges.isEmpty else { return nil }
        if let containing = ranges.first(where: { NSLocationInRange(charOffset, $0.range) }) {
            return containing.wordIndex
        }
        if let following = ranges.first(where: { $0.range.location >= charOffset }) {
            return following.wordIndex
        }
        return ranges.last?.wordIndex
    }

    private static func wordRanges(in paragraph: ReadingParagraph) -> [WordRange] {
        let text = paragraph.text as NSString
        var cursor = 0
        var result: [WordRange] = []
        let punctuation = CharacterSet.punctuationCharacters
            .union(.symbols)
            .union(.whitespacesAndNewlines)
        for (index, word) in paragraph.words.enumerated() {
            let raw = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty, cursor <= text.length else { continue }
            let tail = NSRange(location: cursor, length: max(0, text.length - cursor))
            var range = text.range(of: raw, options: [.caseInsensitive, .diacriticInsensitive], range: tail)
            if range.location == NSNotFound {
                let stripped = raw.trimmingCharacters(in: punctuation)
                if !stripped.isEmpty {
                    range = text.range(of: stripped, options: [.caseInsensitive, .diacriticInsensitive], range: tail)
                }
            }
            guard range.location != NSNotFound else { continue }
            result.append(WordRange(wordIndex: index, range: range))
            cursor = NSMaxRange(range)
        }
        return result
    }

    private static func searchTokens(in text: String) -> [SearchToken] {
        guard let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{N}]+"#) else { return [] }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: fullRange).map { match in
            let raw = (text as NSString).substring(with: match.range)
            return SearchToken(
                value: raw
                    .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
                    .lowercased(with: Locale(identifier: "en_US_POSIX")),
                range: match.range
            )
        }
    }

    private static func tokenSimilarity(_ lhs: [String], _ rhs: [String]) -> Double {
        let denominator = max(lhs.count, rhs.count)
        guard denominator > 0 else { return 1 }
        var previous = Array(0...rhs.count)
        for (leftIndex, left) in lhs.enumerated() {
            var current = Array(repeating: 0, count: rhs.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, right) in rhs.enumerated() {
                let substitution = previous[rightIndex] + (left == right ? 0 : 1)
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    substitution
                )
            }
            previous = current
        }
        return max(0, 1 - Double(previous[rhs.count]) / Double(denominator))
    }
}

/// Consumes each explicit Continue Listening request once, even if WebKit emits
/// multiple readiness/navigation callbacks for the same request.
final class KindleAutoplayRequestGate {
    private var latestRequestByBook: [String: Int] = [:]
    private var consumedRequestByBook: [String: Int] = [:]

    func hasPendingRequest(for bookId: String) -> Bool {
        latestRequestByBook[bookId, default: 0] > consumedRequestByBook[bookId, default: 0]
    }

    @discardableResult
    func request(for bookId: String) -> Int {
        let next = latestRequestByBook[bookId, default: 0] + 1
        latestRequestByBook[bookId] = next
        return next
    }

    func consume(for bookId: String) -> Int? {
        guard hasPendingRequest(for: bookId) else { return nil }
        let request = latestRequestByBook[bookId, default: 0]
        consumedRequestByBook[bookId] = request
        return request
    }
}

enum KindleSyncDialogChoice: String, Equatable {
    case yes
    case no
    case unknown
}

struct KindleSyncDialogEvent: Equatable {
    let isVisible: Bool
    let localLocation: Int?
    let cloudLocation: Int?
    let choice: KindleSyncDialogChoice?

    init?(payload: [String: Any]) {
        let type = payload["type"] as? String
        guard type == "kindle-sync-dialog" || type == "kindle-sync-dialog-choice" else { return nil }
        isVisible = Self.boolValue(payload["visible"]) ?? (type == "kindle-sync-dialog-choice")
        localLocation = Self.intValue(payload["localLocation"])
        cloudLocation = Self.intValue(payload["cloudLocation"])
        if type == "kindle-sync-dialog-choice" {
            choice = KindleSyncDialogChoice(rawValue: (payload["choice"] as? String ?? "").lowercased()) ?? .unknown
        } else {
            choice = nil
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

enum KindleBookValidator {
    private static let blockedTitlePhrases = [
        "download", "app store", "kindle app", "learn more", "read on any device",
        "help", "support", "settings", "notebook", "privacy", "terms",
        "descargar", "tienda de aplicaciones", "aplicación kindle", "más información",
        "leer en cualquier dispositivo", "ayuda", "soporte", "configuración", "cuaderno",
        "privacidad", "términos",
        "baixar", "loja de aplicativos", "aplicativo kindle", "saiba mais",
        "leia em qualquer dispositivo", "ajuda", "suporte", "configurações", "caderno",
        "privacidade", "termos",
        "ダウンロード", "アプリストア", "kindleアプリ", "詳細", "どの端末でも読む",
        "ヘルプ", "サポート", "設定", "ノートブック", "プライバシー", "規約",
        "herunterladen", "app-store", "kindle-app", "mehr erfahren",
        "auf jedem gerät lesen", "hilfe", "einstellungen", "notizbuch",
        "datenschutz", "bedingungen",
        "télécharger", "application kindle", "en savoir plus",
        "lire sur n’importe quel appareil", "aide", "assistance", "paramètres",
        "carnet", "confidentialité", "conditions",
        "scarica", "app kindle", "ulteriori informazioni",
        "leggi su qualsiasi dispositivo", "aiuto", "impostazioni", "taccuino",
        "termini",
        "downloaden", "kindle-app", "meer informatie", "lezen op elk apparaat",
        "ondersteuning", "instellingen", "notitieboek", "voorwaarden",
        "डाउनलोड", "ऐप स्टोर", "किंडल ऐप", "और जानें", "किसी भी डिवाइस पर पढ़ें",
        "सहायता", "समर्थन", "सेटिंग", "नोटबुक", "गोपनीयता", "शर्तें",
        "下载", "应用商店", "了解更多", "任何设备", "帮助", "支持", "设置", "笔记"
    ]

    private static let blockedURLPhrases = [
        "kindle-library", "landing", "help", "support", "settings", "notebook",
        "appstore", "app-store", "download", "privacy", "terms"
    ]

    static func isLikelyLibraryBook(_ book: KindleBook) -> Bool {
        let title = book.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title.count >= 2 else { return false }

        let lowerTitle = title.lowercased()
        if blockedTitlePhrases.contains(where: { lowerTitle.contains($0) }) {
            return false
        }

        // A valid ASIN is not proof that the surrounding URL came from Kindle.
        // Preserve legacy ASIN-only records, but reject any absolute URL whose
        // host is outside the exact storefront contract before repair can turn
        // it into a trusted canonical URL.
        let originalReaderURL = book.readerURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let originalURL = URL(string: originalReaderURL),
           originalURL.host != nil,
           KindleStorefront.entry(url: originalURL) == nil {
            return false
        }

        let rawURL = repairedReaderURL(for: book, preferLastRead: false) ?? book.readerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else { return false }

        guard KindleStorefront.entry(url: URL(string: rawURL)) != nil else {
            return false
        }

        let lowerURL = rawURL.lowercased()
        let hasASIN = containsASIN(book.asin) || containsASIN(book.id) || containsASIN(rawURL)
        let isReaderPath = isKindleReaderPath(rawURL)

        guard hasASIN || isReaderPath else { return false }

        if !hasASIN && blockedURLPhrases.contains(where: { lowerURL.contains($0) }) {
            return false
        }
        return true
    }

    static func containsASIN(_ raw: String?) -> Bool {
        asinValue(in: raw) != nil
    }

    static func asinValue(in raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let patterns = [
            #"(?i)[?&]asin=([A-Z0-9]{10})(?=$|[&#])"#,
            #"(?i)(^|[?&=/:\s-])([A-Z0-9]{10})(?=$|[&#/\s-])"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, range: range) else { continue }
            let group = match.numberOfRanges > 2 ? 2 : 1
            guard let swiftRange = Range(match.range(at: group), in: raw) else { continue }
            return String(raw[swiftRange]).uppercased()
        }
        return nil
    }

    static func isKindleReaderPath(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        guard KindleStorefront.matches(url: url) else { return false }
        return url.path.lowercased().contains("/reader/")
    }

    static func repairedReaderURL(for book: KindleBook, preferLastRead: Bool) -> String? {
        let explicitStorefront = KindleStorefront.entry(id: book.storefrontID)
        let fallbackStorefront = explicitStorefront ?? .us
        let candidates = preferLastRead ? [book.lastReadURL, Optional(book.readerURL)] : [Optional(book.readerURL), book.lastReadURL]
        for candidate in candidates {
            if let usable = usableReaderURL(
                candidate,
                fallbackASIN: book.asin ?? book.id,
                storefront: explicitStorefront
            ) {
                return usable
            }
        }
        if let asin = asinValue(in: book.asin) ?? asinValue(in: book.id) {
            return canonicalReaderURL(asin: asin, storefront: fallbackStorefront)
        }
        return nil
    }

    static func usableReaderURL(
        _ raw: String?,
        fallbackASIN: String? = nil,
        storefront explicitStorefront: KindleStorefront? = nil
    ) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Only the historical "ASIN-only" representation is eligible for
        // hostless migration. A relative path or malformed absolute URL that
        // merely contains an ASIN has no trustworthy marketplace ownership and
        // must not be upgraded into a navigable Kindle URL.
        if let asin = pureASINValue(trimmed) {
            return canonicalReaderURL(
                asin: asin,
                storefront: explicitStorefront ?? .us
            )
        }

        guard let url = URL(string: trimmed),
              let urlStorefront = KindleStorefront.entry(url: url) else {
            return nil
        }
        let targetStorefront = explicitStorefront ?? urlStorefront

        if isBareKindleRoot(trimmed), let asin = asinValue(in: fallbackASIN) {
            return canonicalReaderURL(asin: asin, storefront: targetStorefront)
        }

        if let asin = asinValue(in: trimmed) {
            return canonicalReaderURL(asin: asin, storefront: targetStorefront)
        }

        if isKindleReaderPath(trimmed) {
            guard var components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
            ) else {
                return nil
            }
            components.scheme = "https"
            components.host = targetStorefront.canonicalHost
            components.user = nil
            components.password = nil
            components.port = nil
            return components.url?.absoluteString
        }

        return nil
    }

    private static func pureASINValue(_ raw: String) -> String? {
        let candidate = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard candidate.count == 10,
              candidate.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57)
                      || (scalar.value >= 65 && scalar.value <= 90)
              }) else {
            return nil
        }
        return candidate
    }

    static func canonicalReaderURL(
        asin: String,
        storefront: KindleStorefront = .us
    ) -> String {
        storefront.readerURL(asin: asin).absoluteString
    }

    private static func isBareKindleRoot(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else { return false }
        guard KindleStorefront.matches(url: url) else { return false }
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path.isEmpty && (url.query?.isEmpty ?? true)
    }
}

enum KindleLibrarySort: String, CaseIterable, Identifiable {
    case recent
    case title
    case author

    var id: String { rawValue }

    var label: LocalizedStringKey {
        switch self {
        case .recent: return "最近"
        case .title: return "书名"
        case .author: return "作者"
        }
    }
}
