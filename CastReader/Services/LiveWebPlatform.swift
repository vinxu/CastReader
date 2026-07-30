//
//  LiveWebPlatform.swift
//  CastReader
//
//  Small platform profile for paginated commercial web readers.  The mature
//  Google Play Books pagination engine is shared; a platform adapter supplies
//  only URL/message security, browser presentation and local shelf callbacks.
//

import Foundation
import WebKit

enum LiveWebPlatformID: String, Equatable {
    case googleBooks = "google-books"
    case kobo

    init?(sourceKind: ReadingSourceKind) {
        switch sourceKind {
        case .googleBooks: self = .googleBooks
        case .kobo: self = .kobo
        default: return nil
        }
    }

    var logPrefix: String {
        switch self {
        case .googleBooks: return "GBOOKS"
        case .kobo: return "KOBO"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .googleBooks: return "googleBooksReaderWebView"
        case .kobo: return "koboReaderWebView"
        }
    }

    var userAgent: String {
        switch self {
        case .googleBooks:
            return GoogleBooksWebScripts.mobileSafariUserAgent
        case .kobo:
            // Kobo's proven web reader exposes its semantic page controls in
            // the desktop shell. preferredContentMode remains `.mobile`, so
            // the CSS viewport is still the iPhone's real width.
            return GoogleBooksWebScripts.desktopSafariUserAgent
        }
    }

    /// Never scale the whole WKWebView. `pageZoom < 1` shrinks the page's
    /// painted width without asking Kobo to repaginate, leaving the exact
    /// blank strip seen on device. Kobo typography is normalized inside each
    /// same-origin chapter iframe instead.
    var pageZoom: CGFloat { 1 }

    /// All bound commercial readers share this app-owned persistent browser
    /// profile. Cookies are still scoped by the web origin.
    var websiteDataStore: WKWebsiteDataStore {
        CommercialWebSession.websiteDataStore
    }

    func allowsMainFrameNavigation(_ url: URL?) -> Bool {
        switch self {
        case .googleBooks:
            return GoogleBooksWebAccessPolicy.allowsMainFrameNavigation(url)
        case .kobo:
            return KoboBookValidator.usableReaderURL(url?.absoluteString) != nil
        }
    }

    func allowsScriptMessage(
        type: String?,
        frame: GoogleBooksScriptMessageFrame
    ) -> Bool {
        switch self {
        case .googleBooks:
            return GoogleBooksWebAccessPolicy.allowsScriptMessage(
                type: type,
                from: frame
            )
        case .kobo:
            guard let type,
                  Self.pagedReaderMessageTypes.contains(type),
                  frame.isMainFrame,
                  frame.securityScheme
                    .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                    .lowercased() == "https",
                  frame.securityPort == 0 || frame.securityPort == 443,
                  frame.securityHost.lowercased() == "readnow.kobo.com",
                  let raw = frame.requestURL,
                  allowsMainFrameNavigation(URL(string: raw)) else {
                return false
            }
            return true
        }
    }

    @MainActor
    func clearReaderError() {
        switch self {
        case .googleBooks: GoogleBooksLibraryStore.shared.clearError()
        case .kobo: KoboLibraryStore.shared.clearError()
        }
    }

    @MainActor
    func reportReaderError(_ message: String) {
        switch self {
        case .googleBooks: GoogleBooksLibraryStore.shared.reportError(message)
        case .kobo: KoboLibraryStore.shared.reportError(message)
        }
    }

    @MainActor
    func localRecoveryURL(bookID: String, failedURL: String?) -> String? {
        switch self {
        case .googleBooks:
            return GoogleBooksLibraryStore.shared.localRecoveryURL(
                bookID: bookID,
                failedURL: failedURL
            )
        case .kobo:
            return KoboLibraryStore.shared.localRecoveryURL(
                bookID: bookID,
                failedURL: failedURL
            )
        }
    }

    @MainActor
    func canonicalReaderURL(bookID: String) -> String? {
        switch self {
        case .googleBooks:
            return GoogleBooksLibraryStore.shared.book(for: bookID)?.readerURL
        case .kobo:
            return KoboLibraryStore.shared.canonicalReaderURL(for: bookID)
        }
    }

    @MainActor
    func updateProgress(
        bookID: String,
        readerURL: String,
        fingerprint: String,
        progressLabel: String?
    ) {
        switch self {
        case .googleBooks:
            GoogleBooksLibraryStore.shared.updateProgress(
                bookID: bookID,
                readerURL: readerURL,
                fingerprint: fingerprint,
                progressLabel: progressLabel
            )
        case .kobo:
            KoboLibraryStore.shared.updateProgress(
                bookID: bookID,
                readerURL: readerURL,
                fingerprint: fingerprint,
                progressLabel: progressLabel
            )
        }
    }

    /// Kobo intentionally speaks the already-proven Google wire names for the
    /// first migration. This private compatibility layer keeps the 6k-line
    /// coordinator single-sourced while the public platform profile is generic.
    private static let pagedReaderMessageTypes: Set<String> = [
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
        "googleBooksLocation",
    ]
}
