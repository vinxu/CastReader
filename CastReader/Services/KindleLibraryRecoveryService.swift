import Foundation
import WebKit

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
        guard !isRecovering else { return .notFound }
        isRecovering = true
        defer { isRecovering = false }

        do {
            onProgress(String(localized: "正在打开 Kindle 书架…"))
            webView.load(URLRequest(url: KindleWebScripts.libraryURL, cachePolicy: .reloadIgnoringLocalCacheData))
            for _ in 0..<40 {
                try Task.checkCancellation()
                if !webView.isLoading,
                   webView.url?.absoluteString.contains("kindle-library") == true {
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }

            var recoveredBooks: [KindleBook] = []
            var authRequired = false
            var initialPayload: RecoveryPayload?
            onProgress(String(localized: "正在等待 Kindle 书架加载…"))
            for readinessAttempt in 0..<24 {
                let payload = try await scrape(webView)
                let rowCount = payload.books?.count ?? 0
                KindleRunLog.write("KINDLE library auto-recovery readiness=\(readinessAttempt) rows=\(rowCount) signals=\(payload.hasReaderSignals == true ? "Y" : "N") auth=\(payload.authRequired == true ? "Y" : "N") ua=\(Self.logKey(payload.userAgent ?? ""))")
                if rowCount > 0 || payload.authRequired == true {
                    initialPayload = payload
                    break
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }

            var idlePasses = 0
            onProgress(String(localized: "正在同步 Kindle 书架…"))
            for pass in 0..<12 {
                let before = Set(recoveredBooks.map(\.id)).count
                let payload: RecoveryPayload
                if pass == 0, let initialPayload {
                    payload = initialPayload
                } else {
                    payload = try await scrape(webView)
                }
                authRequired = authRequired || payload.authRequired == true
                recoveredBooks.append(contentsOf: (payload.books ?? []).compactMap(\.book))
                let uniqueCount = Set(recoveredBooks.map(\.id)).count
                idlePasses = uniqueCount == before ? idlePasses + 1 : 0
                let matched = matchingBook(book, in: recoveredBooks) != nil
                KindleRunLog.write("KINDLE library auto-recovery pass=\(pass) rows=\(payload.books?.count ?? 0) unique=\(uniqueCount) matched=\(matched ? "Y" : "N") auth=\(authRequired ? "Y" : "N")")
                // Recovery is deliberately two-phase: finish syncing the shelf first,
                // then resolve and open the target book from that completed snapshot.
                if uniqueCount > 0 && pass >= 2 && idlePasses >= 2 { break }
                try await scrollLibraryForward(in: webView)
                try? await Task.sleep(nanoseconds: 650_000_000)
            }

            guard !authRequired else { return .signInRequired }
            let unique = Dictionary(grouping: recoveredBooks, by: \.id).compactMap(\.value.first)
            if !unique.isEmpty { KindleLibraryStore.shared.mergeScrapedBooks(unique) }
            guard let latest = matchingBook(book, in: unique) else { return .notFound }
            // A Kindle reader runtime that has already entered the stale-book
            // error cannot recover in-place, even after a real shelf click. The
            // caller must recreate the reader WKWebView after this shelf sync,
            // matching the proven manual flow: sync shelf -> exit -> reopen book.
            onProgress(String(localized: "正在重新打开书籍…"))
            KindleRunLog.write("KINDLE library auto-recovery synchronized book=\(Self.logKey(latest.id)) fresh-reader=required")
            return .recovered(latest)
        } catch {
            KindleRunLog.write("KINDLE library auto-recovery failed error=\(error.localizedDescription)")
            return .notFound
        }
    }

    private func scrape(_ webView: WKWebView) async throws -> RecoveryPayload {
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
                NSLocalizedDescriptionKey: String(localized: "Kindle 书架响应异常。")
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
                progressLabel: Self.string(row["progressLabel"] ?? row["progress_label"])
            )
        }
        return RecoveryPayload(
            books: books,
            authRequired: object["authRequired"] as? Bool,
            hasReaderSignals: object["hasReaderSignals"] as? Bool,
            userAgent: Self.string(object["userAgent"])
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
          var delta = Math.max(520, Math.floor((window.innerHeight || 700) * 0.82));
          for (var i=0; i<Math.min(8, all.length); i++) {
            try { all[i].scrollTop = (all[i].scrollTop || 0) + delta; } catch(e) {}
          }
          try { window.scrollBy(0, delta); } catch(e) {}
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
      var body = norm(document.body && document.body.innerText);
      var stale = body.indexOf('please try to open this book from the library again') >= 0 ||
        (body.indexOf('something went wrong') >= 0 && body.indexOf('back to library') >= 0);
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
        String(value.prefix(24))
    }

    private func matchingBook(_ target: KindleBook, in books: [KindleBook]) -> KindleBook? {
        let targetASIN = KindleBookValidator.asinValue(in: target.asin)
            ?? KindleBookValidator.asinValue(in: target.id)
            ?? KindleBookValidator.asinValue(in: target.readerURL)
        return books.first { candidate in
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
    let userAgent: String?
}

private struct RecoveryScrapedBook {
    let id: String?
    let asin: String?
    let title: String?
    let author: String?
    let coverURL: String?
    let readerURL: String?
    let progressLabel: String?

    var book: KindleBook? {
        let resolvedID = id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedURL = readerURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !resolvedID.isEmpty, !resolvedTitle.isEmpty, !resolvedURL.isEmpty else { return nil }
        return KindleBook(
            id: resolvedID, asin: asin, title: resolvedTitle, author: author ?? "", coverURL: coverURL,
            readerURL: resolvedURL, progressLabel: progressLabel ?? "", lastOpenedAt: nil,
            lastSyncedAt: Date(), lastReadPageKey: nil, lastReadURL: nil
        )
    }
}
