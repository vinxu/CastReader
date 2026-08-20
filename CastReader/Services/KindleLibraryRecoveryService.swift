import Foundation
import CryptoKit
import WebKit

/// Shared deny-by-default gate for transient shelf WebViews used outside the
/// visible connection screen. Keeping these recovery surfaces behind the same
/// action + response checks prevents an alias or cross-market redirect from
/// bypassing the canonical-only policy in the background.
@MainActor
final class KindleCanonicalShelfNavigationGate: NSObject, WKNavigationDelegate {
    private let storefront: KindleStorefront
    private(set) var hasBlockedNavigation = false

    init(storefront: KindleStorefront) {
        self.storefront = storefront
        super.init()
    }

    private func allows(_ url: URL?) -> Bool {
        KindleStorefrontNavigationPolicy.allowsMainFrame(
            url,
            expectedStorefrontID: storefront.id,
            expectedAuthenticationReturnPath: storefront.libraryURL.path
        )
    }

    private func block(_ webView: WKWebView, destination: URL?) {
        hasBlockedNavigation = true
        webView.stopLoading()
        let domain = KindleStorefront.registrableDomain(for: destination?.host)
            ?? "invalid_destination"
        KindleRunLog.write(
            "KINDLE transient shelf navigation blocked expected=\(storefront.id) domain=\(domain)"
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true,
              !allows(navigationAction.request.url) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        block(webView, destination: navigationAction.request.url)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard navigationResponse.isForMainFrame,
              !allows(navigationResponse.response.url) else {
            decisionHandler(.allow)
            return
        }
        decisionHandler(.cancel)
        block(webView, destination: navigationResponse.response.url)
    }
}

@MainActor
final class KindleLibraryRecoveryService {
    static let shared = KindleLibraryRecoveryService()

    enum Result {
        case recovered(KindleBook)
        case signInRequired
        case notFound
        case reopenFailed
    }

    private var isRecovering = false

    func recover(
        book: KindleBook,
        in webView: WKWebView,
        onProgress: (String) -> Void
    ) async -> Result {
        guard !Task.isCancelled,
              let accountBoundaryToken = AccountContentIsolation.captureBoundaryToken(),
              !isRecovering else { return .notFound }
        isRecovering = true
        defer { isRecovering = false }

        do {
            let storefront = KindleStorefront.entry(id: book.storefrontID)
                ?? KindleStorefront.entry(rawURL: book.lastReadURL)
                ?? KindleStorefront.entry(rawURL: book.readerURL)
                ?? KindleLibraryStore.shared.boundStorefront
            let navigationGate = KindleCanonicalShelfNavigationGate(
                storefront: storefront
            )
            let previousNavigationDelegate = webView.navigationDelegate
            webView.navigationDelegate = navigationGate
            defer {
                webView.navigationDelegate = previousNavigationDelegate
            }
            onProgress(AppLocalized("正在打开 Kindle 书架…"))
            KindleRunLog.write("KINDLE library auto-recovery storefront=\(storefront.id)")
            webView.load(URLRequest(
                url: KindleWebScripts.libraryURL(for: storefront),
                cachePolicy: .reloadIgnoringLocalCacheData
            ))
            for _ in 0..<40 {
                try Task.checkCancellation()
                guard AccountContentIsolation.isCurrent(accountBoundaryToken) else {
                    return .notFound
                }
                if navigationGate.hasBlockedNavigation { return .notFound }
                if !webView.isLoading {
                    switch Self.landingKind(webView.url, expectedStorefront: storefront) {
                    case .library:
                        break
                    case .auth:
                        KindleRunLog.write(
                            "KINDLE library auto-recovery landing=auth storefront=\(storefront.id)"
                        )
                        return .signInRequired
                    case .otherStorefront:
                        KindleRunLog.write(
                            "KINDLE library auto-recovery landing=other-storefront expected=\(storefront.id)"
                        )
                        return .notFound
                    case .reader, .other, .empty:
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        continue
                    }
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            var recoveredBooks: [KindleBook] = []
            var authRequired = false
            var initialPayload: RecoveryPayload?
            onProgress(AppLocalized("正在等待 Kindle 书架加载…"))
            for readinessAttempt in 0..<24 {
                guard !Task.isCancelled,
                      AccountContentIsolation.isCurrent(accountBoundaryToken) else {
                    return .notFound
                }
                if navigationGate.hasBlockedNavigation { return .notFound }
                let payload = try await scrape(webView, expectedStorefront: storefront)
                let rowCount = payload.books?.count ?? 0
                KindleRunLog.write(
                    "KINDLE library auto-recovery readiness=\(readinessAttempt) " +
                    "landing=\(payload.landing.rawValue) storefront=\(payload.storefrontID ?? "-") " +
                    "rows=\(rowCount) signals=\(payload.hasReaderSignals == true ? "Y" : "N") " +
                    "auth=\(payload.authRequired == true ? "Y" : "N") ua=\(Self.logKey(payload.userAgent ?? ""))"
                )
                if payload.landing == .auth || payload.authRequired == true {
                    return .signInRequired
                }
                if payload.landing == .otherStorefront {
                    return .notFound
                }
                if rowCount > 0 {
                    initialPayload = payload
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            var idlePasses = 0
            var lastNewBookAt = Date()
            var lastReachedEndAt = Date()
            var wasAtScrollEnd = false
            var observedRestock: TimeInterval = 0
            onProgress(AppLocalized("正在同步 Kindle 书架…"))
            for pass in 0..<KindleShelfScanPolicy.maxPasses {
                guard !Task.isCancelled,
                      AccountContentIsolation.isCurrent(accountBoundaryToken) else {
                    return .notFound
                }
                if navigationGate.hasBlockedNavigation { return .notFound }
                let before = Set(recoveredBooks.map(\.id)).count
                let payload: RecoveryPayload
                if pass == 0, let initialPayload {
                    payload = initialPayload
                } else {
                    payload = try await scrape(webView, expectedStorefront: storefront)
                }
                authRequired = authRequired
                    || payload.authRequired == true
                    || payload.landing == .auth
                if payload.landing == .otherStorefront {
                    KindleRunLog.write(
                        "KINDLE library auto-recovery scan-abort landing=other-storefront expected=\(storefront.id)"
                    )
                    return .notFound
                }
                let ingressStorefrontID = payload.storefrontID ?? storefront.id
                recoveredBooks.append(contentsOf: (payload.books ?? []).compactMap {
                    $0.book(storefrontID: ingressStorefrontID)
                })
                let uniqueCount = Set(recoveredBooks.map(\.id)).count
                if uniqueCount == before {
                    idlePasses += 1
                } else {
                    if wasAtScrollEnd {
                        let restock = Date().timeIntervalSince(lastReachedEndAt)
                        if restock > 0 { observedRestock = max(observedRestock, restock) }
                    }
                    idlePasses = 0
                    lastNewBookAt = Date()
                }
                let matched = matchingBook(book, in: recoveredBooks) != nil
                KindleRunLog.write("KINDLE library auto-recovery pass=\(pass) rows=\(payload.books?.count ?? 0) unique=\(uniqueCount) matched=\(matched ? "Y" : "N") auth=\(authRequired ? "Y" : "N")")
                // Recovery is deliberately two-phase: finish syncing the shelf first,
                // then resolve and open the target book from that completed snapshot.
                // 这里提前收工的后果是把「还没同步到的书」报成「书已失效」，
                // 所以判据必须和手动同步完全一致。
                if payload.atScrollEnd == true, !wasAtScrollEnd {
                    lastReachedEndAt = Date()
                }
                wasAtScrollEnd = payload.atScrollEnd == true
                let decision = KindleShelfScanPolicy.decide(
                    KindleShelfScanPolicy.Input(
                        pass: pass,
                        bookCount: uniqueCount,
                        idlePasses: idlePasses,
                        // 恢复扫描的 payload 不解 snapshotKey；idlePasses 是更严的
                        // 近似（收工另外要求 idlePasses >= 3，已蕴含这一条）。
                        stableSnapshotPasses: idlePasses,
                        secondsSinceLastNewBook: Date().timeIntervalSince(lastNewBookAt),
                        secondsSinceReachedEnd: Date().timeIntervalSince(lastReachedEndAt),
                        observedRestock: observedRestock,
                        atScrollEnd: payload.atScrollEnd == true,
                        shelfLoading: payload.shelfLoading == true,
                        pageReady: payload.pageReady == true,
                        isExactBoundLibrary: payload.landing == .library
                    )
                )
                if case .keepScrolling(let waitSeconds) = decision {
                    try await scrollLibraryForward(in: webView)
                    try? await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                } else {
                    break
                }
            }

            guard !authRequired else { return .signInRequired }
            guard AccountContentIsolation.isCurrent(accountBoundaryToken) else {
                return .notFound
            }
            let unique = Dictionary(grouping: recoveredBooks, by: \.id).compactMap(\.value.first)
            if !unique.isEmpty { KindleLibraryStore.shared.mergeScrapedBooks(unique) }
            guard let latest = matchingBook(book, in: unique) else { return .notFound }
            // A Kindle reader runtime that has already entered the stale-book
            // error cannot recover in-place, even after a real shelf click. The
            // caller must recreate the reader WKWebView after this shelf sync,
            // matching the proven manual flow: sync shelf -> exit -> reopen book.
            onProgress(AppLocalized("正在重新打开书籍…"))
            KindleRunLog.write("KINDLE library auto-recovery synchronized book=\(Self.logKey(latest.id)) fresh-reader=required")
            return .recovered(latest)
        } catch {
            KindleRunLog.write("KINDLE library auto-recovery failed error=\(error.localizedDescription)")
            return .notFound
        }
    }

    private func scrape(
        _ webView: WKWebView,
        expectedStorefront: KindleStorefront
    ) async throws -> RecoveryPayload {
        // `scrapeLibrary` already returns a JSON string. Keep this identical to the
        // proven manual sync path; serializing that string again creates double JSON.
        let value = try await evaluate(KindleWebScripts.scrapeLibrary, in: webView)
        let data: Data
        if let json = value as? String, let encoded = json.data(using: .utf8) {
            data = encoded
        } else if JSONSerialization.isValidJSONObject(value) {
            data = try JSONSerialization.data(withJSONObject: value)
        } else {
            throw NSError(domain: "KindleLibraryRecovery", code: -2, userInfo: [
                NSLocalizedDescriptionKey: AppLocalized("Kindle 书架响应异常。")
            ])
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "KindleLibraryRecovery", code: -3)
        }
        let rows = object["books"] as? [[String: Any]] ?? []
        let books = rows.map { row in
            RecoveryScrapedBook(
                id: Self.string(row["id"]),
                asin: Self.string(row["asin"]),
                title: Self.string(row["title"]),
                author: Self.string(row["author"]),
                coverURL: Self.string(row["coverURL"] ?? row["cover_url"]),
                readerURL: Self.string(row["readerURL"] ?? row["reader_url"]),
                progressLabel: Self.string(row["progressLabel"] ?? row["progress_label"]),
                language: Self.string(row["language"]),
                languageSource: Self.string(row["languageSource"] ?? row["language_source"])
            )
        }
        let payloadURL = Self.string(object["url"])
        let actualURL = payloadURL.flatMap(URL.init(string:)) ?? webView.url
        let landing = Self.landingKind(actualURL, expectedStorefront: expectedStorefront)
        let actualStorefrontID = KindleStorefront.storefront(url: actualURL)?.id
        return RecoveryPayload(
            books: books,
            authRequired: object["authRequired"] as? Bool,
            hasReaderSignals: object["hasReaderSignals"] as? Bool,
            atScrollEnd: object["atScrollEnd"] as? Bool,
            shelfLoading: object["shelfLoading"] as? Bool,
            pageReady: object["pageReady"] as? Bool,
            userAgent: Self.string(object["userAgent"]),
            storefrontID: actualStorefrontID == expectedStorefront.id ? actualStorefrontID : nil,
            landing: landing
        )
    }

    private func evaluate(_ script: String, in webView: WKWebView) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let value { continuation.resume(returning: value) }
                else { continuation.resume(returning: NSNull()) }
            }
        }
    }

    private func scrollLibraryForward(in webView: WKWebView) async throws {
        _ = try await evaluate("""
        (function() {
          var all = Array.from(document.querySelectorAll('*')).concat([document.scrollingElement, document.body, document.documentElement]).filter(Boolean);
          all.sort(function(a,b){ return ((b.scrollHeight||0)-(b.clientHeight||0))-((a.scrollHeight||0)-(a.clientHeight||0)); });
          for (var i=0; i<Math.min(8, all.length); i++) {
            try {
              all[i].scrollTop = Math.max(0, (all[i].scrollHeight || 0) - (all[i].clientHeight || 0));
            } catch(e) {}
          }
          try { window.scrollTo(0, Math.max(0, (document.body.scrollHeight || 0))); } catch(e) {}
          return true;
        })();
        """, in: webView)
    }

    private func openBookFromLibrary(_ book: KindleBook, in webView: WKWebView) async throws -> Bool {
        let asin = KindleBookValidator.asinValue(in: book.asin)
            ?? KindleBookValidator.asinValue(in: book.id)
            ?? KindleBookValidator.asinValue(in: book.readerURL)
            ?? ""
        guard !asin.isEmpty else { return false }

        _ = try? await evaluate("""
        (function() {
          var all = Array.from(document.querySelectorAll('*')).concat([document.scrollingElement, document.body, document.documentElement]).filter(Boolean);
          all.forEach(function(el) { try { el.scrollTop = 0; } catch (_) {} });
          try { window.scrollTo(0, 0); } catch (_) {}
          return true;
        })();
        """, in: webView)
        try? await Task.sleep(nanoseconds: 500_000_000)

        for pass in 0..<12 {
            try Task.checkCancellation()
            let raw = try await evaluate(
                Self.libraryClickScript(asin: asin, title: book.title),
                in: webView
            )
            let click = Self.jsonObject(raw)
            let found = click?["found"] as? Bool == true
            let clicked = click?["clicked"] as? Bool == true
            KindleRunLog.write(
                "KINDLE library auto-recovery click pass=\(pass) found=\(found ? "Y" : "N") " +
                "clicked=\(clicked ? "Y" : "N") method=\(Self.logKey(click?["method"] as? String ?? "")) " +
                "picked=\(Self.logKey(click?["pickedTag"] as? String ?? "")) " +
                "tag=\(Self.logKey(click?["tag"] as? String ?? "")) score=\(click?["score"] ?? 0) " +
                "candidates=\(click?["candidates"] ?? 0) href=\(Self.logKey(click?["href"] as? String ?? ""))"
            )
            if clicked {
                return await waitForRecoveredReader(in: webView)
            }
            try await scrollLibraryForward(in: webView)
            try? await Task.sleep(nanoseconds: 650_000_000)
        }
        return false
    }

    private func waitForRecoveredReader(in webView: WKWebView) async -> Bool {
        for attempt in 0..<56 {
            guard !Task.isCancelled else { return false }
            let raw = try? await evaluate(Self.readerReadinessProbe, in: webView)
            let probe = Self.jsonObject(raw)
            let stale = probe?["stale"] as? Bool == true
            let ready = probe?["ready"] as? Bool == true
            if attempt == 0 || attempt % 8 == 0 || stale || ready {
                KindleRunLog.write(
                    "KINDLE library auto-recovery reopen probe=\(attempt) ready=\(ready ? "Y" : "N") " +
                    "stale=\(stale ? "Y" : "N") blobs=\(probe?["blobs"] ?? 0) " +
                    "controls=\(probe?["controls"] ?? 0) url=\(Self.logKey(probe?["url"] as? String ?? ""))"
                )
            }
            if stale { return false }
            if ready { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private static func libraryClickScript(asin: String, title: String) -> String {
        let target = jsLiteral(asin.uppercased())
        let targetTitle = jsLiteral(title)
        return """
        (function() {
          var target = \(target);
          var targetTitle = \(targetTitle);
          function attr(el, name) { try { return el ? (el.getAttribute(name) || '') : ''; } catch (_) { return ''; } }
          function norm(value) { return String(value || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
          function asinFrom(raw) {
            raw = String(raw || '');
            var patterns = [/^([A-Z0-9]{10})$/i, /\\b(B[0-9A-Z]{9})\\b/i, /[?&]asin=([A-Z0-9]{10})/i, /\\/([A-Z0-9]{10})(?:[/?#]|$)/i, /asin[:=\\s_-]+([A-Z0-9]{10})/i];
            for (var i = 0; i < patterns.length; i++) { var m = raw.match(patterns[i]); if (m) return m[1].toUpperCase(); }
            return '';
          }
          function ownSignature(el) {
            var chunks = [el && el.id || '', el && el.className || '', attr(el, 'data-asin'), attr(el, 'data-id'), attr(el, 'data-key'), attr(el, 'aria-label'), attr(el, 'href')];
            try { Array.from(el.attributes || []).slice(0, 36).forEach(function(a) { chunks.push(a.name || '', a.value || ''); }); } catch (_) {}
            return chunks.join(' ');
          }
          function hasTarget(raw) {
            raw = String(raw || '').toUpperCase();
            return asinFrom(raw) === target || raw.indexOf(target) >= 0;
          }
          function visible(el) {
            try {
              var style = getComputedStyle(el);
              var rect = el.getBoundingClientRect();
              return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 4 && rect.height > 4;
            } catch (_) { return false; }
          }
          function candidateScore(el) {
            var score = 0;
            var href = attr(el, 'href');
            if (String(attr(el, 'data-asin')).toUpperCase() === target) score += 1200;
            if (asinFrom(href) === target) score += 1100;
            if (hasTarget(el.id)) score += 900;
            if (hasTarget(attr(el, 'data-id')) || hasTarget(attr(el, 'data-key'))) score += 850;
            if (hasTarget(attr(el, 'aria-label'))) score += 700;
            if (hasTarget(ownSignature(el))) score += 600;
            var html = '';
            try { html = String(el.outerHTML || '').slice(0, 12000); } catch (_) {}
            if (hasTarget(html)) score += Math.max(120, 500 - Math.min(380, Math.floor(html.length / 30)));
            if (visible(el)) score += 80;
            if (/^(A|BUTTON|IMG|ION-ITEM)$/.test(String(el.tagName || '').toUpperCase())) score += 60;
            return score;
          }
          function bestClickable(node) {
            var selectors = 'a[href],button,[role="button"],ion-item,img,[tabindex]';
            var tag = String(node && node.tagName || '').toUpperCase();
            if (/^(A|BUTTON|IMG)$/.test(tag)) return node;
            try {
              var children = Array.from(node.querySelectorAll(selectors));
              children.sort(function(a, b) {
                var aTarget = hasTarget(ownSignature(a)) || hasTarget(String(a.outerHTML || '').slice(0, 4000));
                var bTarget = hasTarget(ownSignature(b)) || hasTarget(String(b.outerHTML || '').slice(0, 4000));
                if (aTarget !== bTarget) return bTarget ? 1 : -1;
                var aCover = String(a.tagName || '').toUpperCase() === 'IMG';
                var bCover = String(b.tagName || '').toUpperCase() === 'IMG';
                if (aCover !== bCover) return bCover ? 1 : -1;
                return candidateScore(b) - candidateScore(a);
              });
              var child = children[0];
              if (child) return child;
            } catch (_) {}
            try { if (node.matches(selectors)) return node; } catch (_) {}
            try {
              var parent = node.closest(selectors);
              if (parent) return parent;
            } catch (_) {}
            return node;
          }
          function dispatchClick(el) {
            if (!el) return false;
            var rect = null;
            try { rect = el.getBoundingClientRect(); } catch (_) {}
            var options = rect ? {
              clientX:rect.left + rect.width / 2,
              clientY:rect.top + rect.height / 2,
              bubbles:true,
              cancelable:true,
              view:window
            } : { bubbles:true, cancelable:true, view:window };
            try { el.focus({ preventScroll:true }); } catch (_) {}
            try { el.dispatchEvent(new PointerEvent('pointerdown', Object.assign({ pointerId:1, pointerType:'mouse', isPrimary:true }, options))); } catch (_) {}
            try { el.dispatchEvent(new MouseEvent('mousedown', options)); } catch (_) {}
            try { el.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerId:1, pointerType:'mouse', isPrimary:true }, options))); } catch (_) {}
            try { el.dispatchEvent(new MouseEvent('mouseup', options)); } catch (_) {}
            try { el.click(); return true; } catch (_) {}
            try { return el.dispatchEvent(new MouseEvent('click', options)); } catch (_) { return false; }
          }
          var selectors = [
            '[data-asin]', 'a[href*="asin="]', 'a[href*="/reader/"]',
            '[id^="library-item-option-"]', '[id^="coverContainer-"]',
            'img[id^="cover-"]', '[aria-labelledby*="cover-"]', 'img'
          ].join(',');
          var nodes = Array.from(document.querySelectorAll(selectors));
          var candidates = nodes.map(function(node) { return { node:node, score:candidateScore(node) }; })
            .filter(function(item) { return item.score >= 600; })
            .sort(function(a, b) { return b.score - a.score; });
          if (!candidates.length && norm(targetTitle).length > 2) {
            candidates = nodes.map(function(node) {
              var label = norm(attr(node, 'aria-label') + ' ' + attr(node, 'alt') + ' ' + (node.innerText || ''));
              return { node:node, score:label.indexOf(norm(targetTitle)) >= 0 ? 400 : 0 };
            }).filter(function(item) { return item.score > 0; });
          }
          if (candidates.length) {
            var picked = candidates[0];
            var clickable = bestClickable(picked.node);
            try { clickable.scrollIntoView({ block:'center', inline:'center' }); } catch (_) {}
            var clicked = dispatchClick(clickable);
            return JSON.stringify({
              found:true,
              clicked:clicked,
              method:picked.score >= 600 ? 'asin-dom' : 'title-dom',
              pickedTag:String(picked.node.tagName || ''),
              tag:String(clickable.tagName || ''),
              href:attr(clickable, 'href'),
              score:picked.score,
              candidates:candidates.length
            });
          }
          return JSON.stringify({ found:false, clicked:false, method:'none', count:nodes.length, candidates:0 });
        })();
        """
    }

    private static let readerReadinessProbe = """
    (function() {
      function norm(v) { return String(v || '').replace(/\\s+/g, ' ').trim().toLowerCase(); }
      function visible(el) {
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            rect.width > 4 && rect.height > 4;
        } catch (_) { return false; }
      }
      function structure(el) {
        try {
          return norm([
            el.id || '',
            typeof el.className === 'string' ? el.className : '',
            el.getAttribute && (el.getAttribute('data-testid') || ''),
            el.getAttribute && (el.getAttribute('data-test') || ''),
            el.getAttribute && (el.getAttribute('data-action') || ''),
            el.getAttribute && (el.getAttribute('href') || '')
          ].join(' '));
        } catch (_) { return ''; }
      }
      function errorText(value) {
        return /something went wrong|please try to open this book|algo (?:salió mal|ha salido mal)|abre este libro desde la biblioteca|algo deu errado|abra este livro (?:na|pela) biblioteca|問題が発生しました|ライブラリから.*(?:開|開き)|etwas ist schiefgelaufen|buch.*bibliothek.*öffnen|(?:une erreur s'est produite|un problème est survenu)|livre.*bibliothèque.*ouvrir|qualcosa è andato storto|libro.*libreria.*apri|कुछ गलत हो गया|किताब.*लाइब्रेरी.*खोल/i.test(value);
      }
      function libraryActionText(value) {
        return /back to library|return to library|volver a la biblioteca|voltar (?:para|à) (?:a )?biblioteca|ライブラリに戻|zurück zur bibliothek|retour à la bibliothèque|torna alla libreria|लाइब्रेरी (?:पर|में) वापस/i.test(value);
      }
      var body = norm(document.body && document.body.innerText);
      var errorNodes = Array.from(document.querySelectorAll(
        '[role="dialog"],[aria-modal="true"],[data-testid*="error" i],[class*="error" i],button,a'
      )).filter(visible);
      var libraryAction = errorNodes.some(function(el) {
        var text = norm((el.innerText || '') + ' ' + (el.getAttribute && el.getAttribute('aria-label') || ''));
        var token = structure(el);
        return libraryActionText(text) ||
          /kindle-library|back.*library|library.*back|return.*library/.test(token);
      });
      var errorSurface = errorNodes.some(function(el) {
        var token = structure(el);
        if (!/(?:^|[-_\\s])(error|failure|failed|oops)(?:$|[-_\\s])/.test(token) &&
            !(el.matches && el.matches('[role="dialog"],[aria-modal="true"]'))) {
          return false;
        }
        return errorText(norm(el.innerText || el.textContent || '')) ||
          /(?:^|[-_\\s])(error|failure|failed|oops)(?:$|[-_\\s])/.test(token);
      });
      var stale = errorText(body) || (errorSurface && libraryAction);
      var blobs = Array.from(document.images || []).filter(function(img) {
        return String(img.currentSrc || img.src || '').indexOf('blob:') === 0 && Number(img.naturalWidth || 0) > 80;
      }).length;
      var pageControls = document.querySelectorAll('[aria-label*="next" i], [aria-label*="previous" i], [class*="page" i]').length;
      return JSON.stringify({
        ready:!stale && blobs > 0,
        stale:stale,
        blobs:blobs,
        controls:pageControls,
        url:location.href
      });
    })();
    """

    private static func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let array = String(data: data, encoding: .utf8),
              array.count >= 2 else { return "\"\"" }
        return String(array.dropFirst().dropLast())
    }

    private static func jsonObject(_ value: Any?) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        guard let string = value as? String,
              let data = string.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func logKey(_ value: String) -> String {
        guard !value.isEmpty else { return "" }
        let hash = SHA256.hash(data: Data(value.utf8))
        return hash.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate enum LandingKind: String {
        case library
        case auth
        case reader
        case otherStorefront = "other-storefront"
        case other
        case empty
    }

    private static func landingKind(
        _ url: URL?,
        expectedStorefront: KindleStorefront
    ) -> LandingKind {
        guard let url else { return .empty }
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443 else {
            return .other
        }

        let host = url.host?.lowercased() ?? ""
        let path = normalizedPath(url.path)
        if isAmazonAuthLanding(host: host, path: path, url: url) {
            return .auth
        }

        guard let actualStorefront = KindleStorefront.storefront(url: url) else {
            return .other
        }
        guard actualStorefront.id == expectedStorefront.id else {
            return .otherStorefront
        }
        guard expectedStorefront.ownsCanonicalURL(url) else {
            // Known aliases remain valid ownership evidence for migration, but
            // a recovery WebView must never accept one as a fresh shelf/reader
            // destination because localized aliases can drop /kindle-library.
            return .otherStorefront
        }
        if path == normalizedPath(expectedStorefront.libraryURL.path) {
            return .library
        }
        if hasReaderASINQuery(url, normalizedPath: path)
            || KindleBookValidator.isKindleReaderPath(url.absoluteString) {
            return .reader
        }
        return .other
    }

    private static func hasReaderASINQuery(
        _ url: URL,
        normalizedPath: String
    ) -> Bool {
        guard normalizedPath == "/",
              let components = URLComponents(
                url: url,
                resolvingAgainstBaseURL: false
              ),
              let asin = components.queryItems?.first(where: {
                  $0.name.caseInsensitiveCompare("asin") == .orderedSame
              })?.value else {
            return false
        }
        return KindleBookValidator.asinValue(in: asin) != nil
    }

    private static func isAmazonAuthLanding(
        host: String,
        path: String,
        url: URL
    ) -> Bool {
        guard KindleStorefront.isAmazonWebsiteDataDomain(host) else { return false }
        if path == "/ap/signin" || path.hasPrefix("/ap/signin/")
            || path == "/ap/cvf" || path.hasPrefix("/ap/cvf/") {
            return true
        }
        if host.split(separator: ".").contains(where: {
            String($0).caseInsensitiveCompare("authportal") == .orderedSame
        }) {
            return true
        }
        guard path.hasPrefix("/ap/"),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.queryItems?.contains(where: {
            $0.name.lowercased().hasPrefix("openid.")
        }) == true
    }

    private static func normalizedPath(_ raw: String) -> String {
        var path = raw.lowercased()
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? "/" : path
    }

    private func matchingBook(_ target: KindleBook, in books: [KindleBook]) -> KindleBook? {
        let targetStorefrontID = KindleStorefront.storefront(id: target.storefrontID)?.id
            ?? KindleStorefront.storefront(rawURL: target.lastReadURL)?.id
            ?? KindleStorefront.storefront(rawURL: target.readerURL)?.id
        let targetASIN = KindleBookValidator.asinValue(in: target.asin)
            ?? KindleBookValidator.asinValue(in: target.id)
            ?? KindleBookValidator.asinValue(in: target.readerURL)
        return books.first { candidate in
            let candidateStorefrontID = KindleStorefront.storefront(id: candidate.storefrontID)?.id
                ?? KindleStorefront.storefront(rawURL: candidate.lastReadURL)?.id
                ?? KindleStorefront.storefront(rawURL: candidate.readerURL)?.id
            if let targetStorefrontID, let candidateStorefrontID,
               targetStorefrontID != candidateStorefrontID {
                return false
            }
            if candidate.id == target.id { return true }
            guard let targetASIN else { return false }
            let candidateASIN = KindleBookValidator.asinValue(in: candidate.asin)
                ?? KindleBookValidator.asinValue(in: candidate.id)
                ?? KindleBookValidator.asinValue(in: candidate.readerURL)
            return candidateASIN == targetASIN
        }
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }
}

private struct RecoveryPayload {
    let books: [RecoveryScrapedBook]?
    let authRequired: Bool?
    let hasReaderSignals: Bool?
    let atScrollEnd: Bool?
    let shelfLoading: Bool?
    let pageReady: Bool?
    let userAgent: String?
    let storefrontID: String?
    let landing: KindleLibraryRecoveryService.LandingKind
}

private struct RecoveryScrapedBook {
    let id: String?
    let asin: String?
    let title: String?
    let author: String?
    let coverURL: String?
    let readerURL: String?
    let progressLabel: String?
    let language: String?
    let languageSource: String?

    func book(storefrontID: String) -> KindleBook? {
        let resolvedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedURL = readerURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolvedID.isEmpty, !resolvedTitle.isEmpty, !resolvedURL.isEmpty else { return nil }
        return KindleBook(
            id: resolvedID, asin: asin, title: resolvedTitle, author: author ?? "", coverURL: coverURL,
            readerURL: resolvedURL, progressLabel: progressLabel ?? "",
            storefrontID: KindleStorefront.storefront(rawURL: resolvedURL)?.id ?? storefrontID,
            language: language, languageSource: languageSource, lastOpenedAt: nil,
            lastSyncedAt: Date(), lastReadPageKey: nil, lastReadURL: nil
        )
    }
}
