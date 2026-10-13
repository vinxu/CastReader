//
//  GoogleBooksWebScripts.swift
//  CastReader
//
//  Google Play 图书绑定所需的注入脚本与地址常量。
//
//  只做两件事：在**用户已登录**的 WKWebView 里扫书架元数据、在阅读器壳里驱动翻页。
//  正文提取/高亮全部由 WebAssets/bundle.js（play-books 适配）在跨源阅读帧里完成。
//  这里不读取、不保存、不上报任何 Google 凭据。
//

import Foundation
import WebKit

/// Persistent browser profile shared by the commercial readers of the *active
/// CastReader account only*.
///
/// The earlier implementation used one device-global profile. That made an
/// Amazon/WeRead/Google/Kobo/O'Reilly login created by account A immediately
/// available after CastReader switched to account B (or from the global route
/// to the CN route). The profile identifier is now derived from the already
/// opaque `route x canonical-account` storage scope. A different CastReader
/// identity therefore receives a different WebKit cookie/local-storage jar,
/// while the same identity can still resume its own browser session after an
/// app relaunch.
@MainActor
enum CommercialWebSession {
    /// The device-global profile used by previous builds. New production code
    /// never selects it; it remains named so we can erase its unowned data once
    /// without ever attaching it to a newly signed-in account.
    private static let legacyWebsiteDataStoreIdentifier =
        UUID(uuidString: "739ED7D6-8C70-4D85-971C-5DDAE87C6C6F")!
    private static let signedOutWebsiteDataStoreIdentifier =
        UUID(uuidString: "5B6649F4-E15B-43E1-A90B-44B411A84A42")!

    private static var activeIdentifier = signedOutWebsiteDataStoreIdentifier
    private static var didScheduleLegacyPurge = false

    static var websiteDataStoreIdentifier: UUID { activeIdentifier }

    static var websiteDataStore: WKWebsiteDataStore {
        WKWebsiteDataStore(forIdentifier: activeIdentifier)
    }

    static func activateAccountScope(_ scope: AccountContentScope) {
        activeIdentifier = scopedIdentifier(storageID: scope.storageID)
        purgeLegacyUnownedWebsiteDataOnce()
    }

    static func deactivateAccountScope() {
        activeIdentifier = signedOutWebsiteDataStoreIdentifier
    }

    #if DEBUG
    /// UI fixtures that intentionally exercise pre-account browser behavior
    /// can opt into the historical profile. Production has no such path.
    static func activateLegacyTestingScope() {
        activeIdentifier = legacyWebsiteDataStoreIdentifier
    }
    #endif

    private static func scopedIdentifier(storageID: String) -> UUID {
        var bytes = stride(from: 0, to: min(storageID.count, 32), by: 2).compactMap { offset -> UInt8? in
            let start = storageID.index(storageID.startIndex, offsetBy: offset)
            let end = storageID.index(start, offsetBy: 2, limitedBy: storageID.endIndex)
                ?? storageID.endIndex
            return UInt8(storageID[start..<end], radix: 16)
        }
        guard bytes.count == 16 else { return signedOutWebsiteDataStoreIdentifier }
        // RFC 4122 variant + deterministic v5 marker. The input is already a
        // SHA-256 digest, so no raw account identifier enters WebKit's path.
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Both historical jars were device-global and have no trustworthy owner.
    /// New account-scoped readers never use either jar, so this asynchronous
    /// cleanup cannot race with a newly opened shelf or reader.
    private static func purgeLegacyUnownedWebsiteDataOnce() {
        guard !didScheduleLegacyPurge else { return }
        didScheduleLegacyPurge = true
        let legacyCommercial = WKWebsiteDataStore(
            forIdentifier: legacyWebsiteDataStoreIdentifier
        )
        let legacyDefault = WKWebsiteDataStore.default()
        Task {
            await removeAllWebsiteData(from: legacyCommercial)
            await removeAllWebsiteData(from: legacyDefault)
        }
    }

    private static func removeAllWebsiteData(
        from dataStore: WKWebsiteDataStore
    ) async {
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await withCheckedContinuation { continuation in
            dataStore.removeData(
                ofTypes: types,
                modifiedSince: Date(timeIntervalSince1970: 0)
            ) {
                continuation.resume()
            }
        }
    }
}

/// Source compatibility for the already-shipped Google Books integration.
@MainActor
enum GoogleWebSession {
    static var websiteDataStoreIdentifier: UUID {
        CommercialWebSession.websiteDataStoreIdentifier
    }
    static var websiteDataStore: WKWebsiteDataStore {
        CommercialWebSession.websiteDataStore
    }
}

enum GoogleBooksWebScripts {
    static let homeURL = URL(string: "https://play.google.com/books")!
    /// 「我的图书」书架。Play 图书网页版有多个入口，扫描脚本对三种都写宽。
    static let shelfURL = URL(string: "https://play.google.com/books")!
    static let signInURL: URL = {
        var components = URLComponents(
            string: "https://accounts.google.com/ServiceLogin"
        )!
        components.queryItems = [
            URLQueryItem(name: "service", value: "print"),
            URLQueryItem(name: "continue", value: shelfURL.absoluteString),
        ]
        return components.url!
    }()

    /// Reads the exact sign-in destination generated by Google for the current
    /// Play Books page/session. The native button loads this URL in the main
    /// WKWebView instead of synthesizing a click (which can lose user-gesture
    /// privileges). `signInURL` remains the fallback while the page hydrates.
    static let currentPageSignInURL = #"""
    (function () {
      var selectors = [
        'a[href*="accounts.google.com/ServiceLogin"]',
        'a[href*="accounts.google.com/signin"]',
        'a[href*="accounts.google.com/InteractiveLogin"]'
      ];
      for (var i = 0; i < selectors.length; i += 1) {
        var node = document.querySelector(selectors[i]);
        if (!node) continue;
        try {
          var target = new URL(node.href, location.href);
          if (target.protocol === 'https:' &&
              target.hostname.toLowerCase() === 'accounts.google.com') {
            return target.href;
          }
        } catch (e) {}
      }
      return null;
    })();
    """#

    /// 必须是**完整的 Mobile Safari UA**：WKWebView 默认 UA 缺 `Version/… Safari/…`，
    /// Google 会据此判定「不安全的浏览器」而拒绝登录。同时移动 UA 让 Play 图书
    /// 直接给手机端排版，省掉缩放适配。
    static let mobileSafariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_6 like Mac OS X) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.6 Mobile/15E148 Safari/604.1"

    /// 部分地区/账号在移动版会被引导去装 App，桌面 UA 是唯一兜底。
    static let desktopSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " +
        "(KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    static func readerURL(volumeID: String) -> URL? {
        URL(string: GoogleBooksBookValidator.canonicalReaderURL(volumeID: volumeID))
    }

    static func isReaderURL(_ url: URL?) -> Bool {
        GoogleBooksWebAccessPolicy.allowsMainFrameNavigation(url)
    }

    static func isShelfURL(_ url: URL?) -> Bool {
        guard let url, let host = url.host?.lowercased() else { return false }
        guard host == "play.google.com" else { return false }
        let path = url.path
        return path == "/books" || path.hasPrefix("/books/") && !path.hasPrefix("/books/reader")
    }

    /// 书架扫描：抓「我的图书」里所有指向 /books/reader?id= 的卡片。
    /// Google 频繁改 markup（DOM 里既有 `<a href>` 也有 data-* 承载的 volume id），
    /// 所以选择器写宽 + 多路兜底，任意一路命中即可。
    static let libraryScan = #"""
    (function () {
      var probeOnly = window.__castreaderGoogleBooksProbeOnly === true;
      try { delete window.__castreaderGoogleBooksProbeOnly; }
      catch (e) { window.__castreaderGoogleBooksProbeOnly = false; }

      function text(node) {
        return node ? String(node.textContent || '').replace(/\s+/g, ' ').trim() : '';
      }
      function abs(href) {
        if (!href) return '';
        try { return new URL(href, location.href).href; } catch (e) { return ''; }
      }
      function volumeFrom(href) {
        if (!href) return '';
        try {
          var url = new URL(href, location.href);
          if (url.protocol !== 'https:' || url.hostname.toLowerCase() !== 'play.google.com' ||
              url.username || url.password || (url.port && url.port !== '443') ||
              !/^\/books\/reader\/?$/.test(url.pathname)) return '';
          var ids = url.searchParams.getAll('id');
          return ids.length === 1 && /^[A-Za-z0-9_-]{6,64}$/.test(ids[0]) ? ids[0] : '';
        } catch (e) { return ''; }
      }
      function visible(node) {
        if (!node || !node.isConnected) return false;
        for (var parent = node; parent && parent.nodeType === 1; parent = parent.parentElement) {
          var style = getComputedStyle(parent);
          if (parent.hidden || parent.getAttribute('aria-hidden') === 'true' || parent.hasAttribute('inert') ||
              style.display === 'none' || style.visibility === 'hidden' || style.visibility === 'collapse' ||
              Number(style.opacity) === 0) return false;
        }
        return node.getClientRects().length > 0;
      }
      function firstVisible(selector) {
        return Array.from(document.querySelectorAll(selector)).find(visible) || null;
      }
      function recommendation(node) {
        return !!node.closest('aside,[aria-label*="recommend" i],[data-testid*="recommend" i]');
      }
      function shelfBusy() {
        return Array.from(document.querySelectorAll([
          '[aria-busy="true"]', '[data-loading="true"]',
          '[data-testid*="loading" i]', '[data-testid*="skeleton" i]',
          '[role="progressbar"]:not([aria-valuenow])'
        ].join(','))).some(function (node) { return visible(node) && !recommendation(node); });
      }

      var authRequired = false;
      var authenticated = false;
      var hasAccountEvidence = false;
      var isShelfContext = false;
      var account = null;
      var accountIdentitySource = '';
      var hasCredentialForm = !!firstVisible([
        'input[type="password"]', 'input[autocomplete~="username"]',
        'input[autocomplete~="current-password"]', 'input[autocomplete~="one-time-code"]',
        'form[action*="signin" i] input', 'form[action*="ServiceLogin" i] input'
      ].join(','));
      var shelfSurfaceSelector = 'gpb-library-home gpb-shelf-page,main,[role="main"],[role="list"],[role="grid"]';
      var shelfSurfaces = Array.from(document.querySelectorAll(shelfSurfaceSelector))
        .filter(function (node) { return visible(node) && node.clientHeight > 0 && !recommendation(node); });
      var hasShelfSurface = shelfSurfaces.length > 0;
      var isDocumentReady = document.readyState === 'interactive' || document.readyState === 'complete';
      try {
        var host = String(location.hostname || '').toLowerCase();
        var path = String(location.pathname || '').toLowerCase().replace(/\/+$/, '') || '/';
        var pageURL = new URL(location.href);
        isShelfContext = location.protocol === 'https:' && !pageURL.username && !pageURL.password &&
          (!location.port || location.port === '443') && host === 'play.google.com' &&
          (path === '/books' || (path.indexOf('/books/') === 0 && path.indexOf('/books/reader') !== 0));
        if (host === 'accounts.google.com') authRequired = true;

        // Prefer URL/data attributes over localized visible text. aria-label
        // remains a fallback because Google currently puts the signed-in
        // email there in most locales.
        var accountNodes = Array.from(document.querySelectorAll(
          '[data-email], a[href*="SignOutOptions"], a[href*="/ManageAccount"], header a[aria-label*="@"], header button[aria-label*="@"], [role="banner"] [aria-label*="@"], img.gb_P'
        ));
        var signInNode = firstVisible(
          'a[href*="ServiceLogin"], a[href*="accounts.google.com/signin"]'
        );
        hasAccountEvidence = accountNodes.length > 0 && !hasCredentialForm && !signInNode;
        // The first match can be generic avatar artwork. Inspect every known
        // account node and isolate the email from localized labels such as
        // "Google Account: Name (reader@example.com)" without punctuation.
        var emailPattern = /[a-z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+/i;
        for (var accountIndex = 0; accountIndex < accountNodes.length && !accountIdentitySource; accountIndex++) {
          var accountNode = accountNodes[accountIndex];
          var attributes = ['data-email', 'aria-label', 'alt', 'title'];
          for (var attributeIndex = 0; attributeIndex < attributes.length; attributeIndex++) {
            var emailMatch = emailPattern.exec(accountNode.getAttribute(attributes[attributeIndex]) || '');
            if (emailMatch) {
              accountIdentitySource = String(emailMatch[0]).toLowerCase();
              // 只保留域名部分作展示，不带邮箱本体。
              account = 'Google · ' + accountIdentitySource.split('@')[1];
              break;
            }
          }
        }
        if (hasCredentialForm || signInNode) authRequired = true;
        authenticated = hasAccountEvidence && isShelfContext && !authRequired;
        if (!hasAccountEvidence && signInNode) authRequired = true;
      } catch (e) { /* */ }

      var found = {};
      var observedBookNodes = [];
      var bookCandidates = [];
      var recognizedCandidates = [];
      function candidateRoot(node) {
        return node.closest('.card,[role="listitem"],li,[data-item-id],[data-docid],[data-volume-id],gpb-volume-card') || node;
      }
      function registerCandidate(node) {
        if (!node || !visible(node) || recommendation(node)) return null;
        var root = candidateRoot(node);
        if (bookCandidates.indexOf(root) === -1) bookCandidates.push(root);
        return root;
      }
      function push(href, node) {
        if (node && (!visible(node) || recommendation(node))) return;
        var candidate = registerCandidate(node);
        var url = abs(href);
        var volume = volumeFrom(url);
        if (!volume) return;
        if (node) observedBookNodes.push(node);
        if (found[volume]) {
          if (candidate) recognizedCandidates.push(candidate);
          return;
        }
        // Real Google cards nest the title inside .metadata/.bottompanel.
        // A generic nearest div stops there and misses the sibling cover.
        var card = node ? (node.closest('.card,[role="listitem"],li,[data-item-id],[data-docid],[data-volume-id],gpb-volume-card') || node.closest('div') || node) : null;
        var title = '';
        var author = '';
        var cover = '';
        var progress = '';
        if (node) {
          title = node.getAttribute('aria-label') || node.getAttribute('title') || '';
        }
        if (card) {
          if (!title) {
            var t = card.querySelector('[role="heading"], .title, h2, h3, [data-title]');
            title = t ? (t.getAttribute('data-title') || text(t)) : '';
          }
          var a = card.querySelector('.subtitle, .author, [data-author]');
          author = a ? (a.getAttribute('data-author') || text(a)) : '';
          var img = card.querySelector('img');
          if (img) cover = img.getAttribute('src') || img.getAttribute('data-src') || '';
          var p = card.querySelector('[role="progressbar"], .progress, [aria-valuenow]');
          if (p) {
            var now = p.getAttribute('aria-valuenow');
            progress = now ? (Math.round(Number(now)) + '%') : text(p);
          }
        }
        if (!title && node) title = text(node);
        title = String(title || '').replace(/\s+/g, ' ').trim();
        // aria-label 常见形如 "书名 by 作者"。
        if (!author) {
          var byMatch = /^(.*?)\s+(?:by|作者[:：]?)\s+(.+)$/i.exec(title);
          if (byMatch) { title = byMatch[1].trim(); author = byMatch[2].trim(); }
        }
        if (!title) return;
        if (candidate) recognizedCandidates.push(candidate);
        found[volume] = {
          readerURL: 'https://play.google.com/books/reader?id=' + volume,
          title: title,
          author: author,
          coverURL: cover,
          progressLabel: progress
        };
      }

      try {
        var anchors = document.querySelectorAll('a[href*="/books/reader"], a[href*="books/reader?id="]');
        for (var i = 0; i < anchors.length; i++) push(anchors[i].getAttribute('href'), anchors[i]);
      } catch (e) { /* */ }

      // 兜底一：卡片把 volume id 放在 data-* 上，点击才拼 URL。
      try {
        var carriers = document.querySelectorAll('[data-item-id], [data-docid], [data-volume-id]');
        for (var j = 0; j < carriers.length; j++) {
          var node = carriers[j];
          registerCandidate(node);
          var raw = node.getAttribute('data-volume-id') || node.getAttribute('data-docid') || node.getAttribute('data-item-id') || '';
          var id = /^book-(.+)$/.exec(raw);
          var volume = id ? id[1] : raw;
          if (/^[A-Za-z0-9_-]{6,64}$/.test(volume)) {
            push('https://play.google.com/books/reader?id=' + volume, node);
          }
        }
      } catch (e) { /* */ }

      var books = [];
      for (var key in found) { if (Object.prototype.hasOwnProperty.call(found, key)) books.push(found[key]); }

      // A visible cover/card that this adapter cannot decode is not an empty
      // shelf. Keep the diagnostic count separate from successfully parsed
      // books so native validation can prevent a partial replacement.
      Array.from(document.querySelectorAll('gpb-volume-card,[role="listitem"],li,.card,[role="button"]')).forEach(function (node) {
        if (!visible(node) || recommendation(node) ||
            !shelfSurfaces.some(function (surface) { return surface.contains(node); })) return;
        if (node.matches('gpb-volume-card')) { registerCandidate(node); return; }
        if (!node.querySelector('img')) return;
        if (text(node) || node.getAttribute('aria-label') || node.getAttribute('title') ||
            node.querySelector('img[alt],a,button,[role="heading"]')) registerCandidate(node);
      });
      var unrecognizedCandidates = bookCandidates.filter(function (candidate) {
        return !recognizedCandidates.some(function (recognized) {
          return candidate === recognized || candidate.contains(recognized) || recognized.contains(candidate);
        });
      });
      var unrecognizedBookCandidateCount = unrecognizedCandidates.filter(function (candidate) {
        return !unrecognizedCandidates.some(function (nested) {
          return nested !== candidate && candidate.contains(nested);
        });
      }).length;

      // Choose the nearest scrolling ancestor of the cards, not whichever
      // outer layout happens to have the largest scroll range.
      var scrollRoot = document.scrollingElement || document.documentElement;
      var owners = [];
      observedBookNodes.forEach(function (node) {
        for (var ancestor = node.parentElement; ancestor && ancestor !== document.body; ancestor = ancestor.parentElement) {
          var style = getComputedStyle(ancestor);
          if (ancestor.clientHeight > 0 && /^(?:auto|scroll)$/.test(style.overflowY)) {
            var existing = owners.find(function (item) { return item.node === ancestor; });
            if (existing) existing.votes += 1;
            else owners.push({ node: ancestor, votes: 1 });
            break;
          }
        }
      });
      if (owners.length) {
        owners.sort(function (a, b) { return b.votes - a.votes; });
        scrollRoot = owners[0].node;
      } else {
        var emptyOwner = Array.from(document.querySelectorAll(shelfSurfaceSelector)).find(function (node) {
          return visible(node) && node.clientHeight > 0 && /^(?:auto|scroll)$/.test(getComputedStyle(node).overflowY);
        });
        if (emptyOwner) scrollRoot = emptyOwner;
      }

      var scrollTop = scrollRoot ? Number(scrollRoot.scrollTop || 0) : 0;
      var viewport = scrollRoot ? Number(scrollRoot.clientHeight || window.innerHeight || 0) : 0;
      var bestRange = scrollRoot ? Math.max(0, Number(scrollRoot.scrollHeight || 0) - viewport) : 0;
      var atScrollEnd = bestRange <= 4 || scrollTop >= bestRange - 4;
      var fingerprint = Object.keys(found).sort().join('|');
      var hasPendingShelfWork = !isDocumentReady || shelfBusy();
      var unsupportedPagination = Array.from(document.querySelectorAll([
        'nav[aria-label*="pagination" i]', '[aria-label*="page navigation" i]',
        '[class~="pagination"]', '[class~="pager"]', '[data-testid*="pagination" i]'
      ].join(','))).some(function (node) {
        return visible(node) && !recommendation(node) &&
          !node.closest('[class*="page-size" i],[class*="pagesize" i],.pagination-filter-container,.filter-chip') &&
          !!node.querySelector('a,button,[role="button"]');
      });
      var hasActiveShelfFilter = false;
      if (isShelfContext && !hasCredentialForm) {
        // Observed Google progress dropdown: the placeholder carries the
        // mat-mdc-select-empty class. A selected progress value is a subset
        // of the account library and must not replace its complete catalog.
        hasActiveShelfFilter = Array.from(document.querySelectorAll('gpb-shelf-page .progress-filter mat-select'))
          .some(function (node) {
            return !node.classList.contains('mat-mdc-select-empty') || !!text(node.querySelector('.mat-mdc-select-value-text'));
          });
        if (!hasActiveShelfFilter) {
          hasActiveShelfFilter = Array.from(document.querySelectorAll('input[type="search"],input[role="searchbox"]'))
            .some(function (node) {
              // Only explicit shelf-search fields are read, never credentials
              // or generic text inputs. Only the Boolean leaves the page.
              return visible(node) && !recommendation(node) &&
                shelfSurfaces.some(function (surface) { return surface.contains(node); }) &&
                String(node.value || '').trim().length > 0;
            });
        }
      }

      var cardRects = observedBookNodes.map(function (node) {
        var card = node.closest('.card,[role="listitem"],li,[data-item-id],gpb-volume-card') || node;
        return card.getBoundingClientRect();
      }).filter(function (rect) { return rect.height > 0; });
      var firstCardTop = cardRects.length ? Math.min.apply(null, cardRects.map(function (rect) { return rect.top; })) : 0;
      var lastCardBottom = cardRects.length ? Math.max.apply(null, cardRects.map(function (rect) { return rect.bottom; })) : 0;
      var rootTop = scrollRoot === document.scrollingElement || scrollRoot === document.documentElement
        ? 0 : scrollRoot.getBoundingClientRect().top + Number(scrollRoot.clientTop || 0);
      var coversViewport = cardRects.length > 0 && firstCardTop <= rootTop + 8 && lastCardBottom >= rootTop + viewport - 8;
      var looksVirtual = cardRects.length > 0 && lastCardBottom - firstCardTop + viewport * 2 < bestRange;
      var movement = window.__castreaderGoogleBooksShelfMovement;
      if (movement && movement.root !== scrollRoot) {
        movement = null;
        window.__castreaderGoogleBooksShelfMovement = null;
      }
      if (movement) {
        // A virtual list can update scrollTop before replacing the old cards.
        // Hold position until its new metadata or covered viewport proves the
        // render caught up. Static lists already expose all their cards.
        var rendered = fingerprint !== movement.fingerprint || coversViewport || !movement.virtual;
        if (!hasPendingShelfWork && rendered) {
          window.__castreaderGoogleBooksShelfMovement = null;
          movement = null;
        } else {
          hasPendingShelfWork = true;
        }
      }
      try {
        if (probeOnly && authenticated && scrollRoot) {
          scrollRoot.scrollTop = 0;
          scrollTop = 0;
          atScrollEnd = bestRange <= 4;
          window.__castreaderGoogleBooksShelfMovement = null;
        } else if (!probeOnly && authenticated && scrollRoot && !hasPendingShelfWork &&
                   unrecognizedBookCandidateCount === 0 && !atScrollEnd && !unsupportedPagination && !hasActiveShelfFilter) {
          // Overlap viewports. A minimum 520px step skipped books whenever a
          // nested virtual list was shorter than 520px (common on phones).
          var targetTop = Math.min(bestRange, scrollTop + Math.max(1, viewport * 0.82));
          window.__castreaderGoogleBooksShelfMovement = {
            root: scrollRoot, fingerprint: fingerprint, virtual: looksVirtual, targetTop: targetTop
          };
          scrollRoot.scrollTop = targetTop;
        }
      } catch (e) { atScrollEnd = false; hasPendingShelfWork = true; }
      // Generic main/list markup and repeated zero results do not prove an
      // empty account. Require a visible, explicit empty-state message, and
      // reject it if any book-like card (including an undecodable one) exists.
      var emptyStateVisible = Array.from(document.querySelectorAll([
        '[data-testid="empty-library"]', '[data-testid="empty-shelf"]',
        '[data-empty-library="true"]', '[data-empty-shelf="true"]',
        '.empty-library', '.empty-shelf', '.empty-state', '[role="status"]'
      ].join(','))).some(function (node) {
        if (!visible(node) || recommendation(node) ||
            !shelfSurfaces.some(function (surface) { return surface.contains(node); })) return false;
        var message = text(node).toLowerCase().replace(/[.!。！]+$/, '').trim();
        return /^(?:no books(?: yet)?|your (?:library|shelf) is empty|you (?:don't|do not) have any books(?: yet)?|没有图书|暂无图书|书架为空|尚无图书|還沒有圖書|沒有圖書|書架為空)$/.test(message);
      });
      var hasExplicitEmptyShelf = authenticated && isDocumentReady && hasShelfSurface &&
        !hasPendingShelfWork && !hasActiveShelfFilter && books.length === 0 && bookCandidates.length === 0 && emptyStateVisible;
      var isCompleteSnapshot = authenticated && isDocumentReady && hasShelfSurface &&
        atScrollEnd && !hasPendingShelfWork && !unsupportedPagination && !hasActiveShelfFilter &&
        unrecognizedBookCandidateCount === 0 && (books.length > 0 || hasExplicitEmptyShelf);

      return {
        authRequired: authRequired,
        authenticated: authenticated,
        hasAccountEvidence: hasAccountEvidence,
        isShelfContext: isShelfContext,
        isCompleteSnapshot: isCompleteSnapshot,
        hasCredentialForm: hasCredentialForm,
        isDocumentReady: isDocumentReady,
        hasShelfSurface: hasShelfSurface,
        hasExplicitEmptyShelf: hasExplicitEmptyShelf,
        unrecognizedBookCandidateCount: unrecognizedBookCandidateCount,
        atScrollEnd: atScrollEnd,
        hasPendingWork: hasPendingShelfWork,
        pageFingerprint: fingerprint,
        scrollPosition: scrollTop,
        scrollExtent: bestRange,
        viewportHeight: viewport,
        hasUnsupportedPagination: unsupportedPagination,
        hasActiveShelfFilter: hasActiveShelfFilter,
        account: account,
        accountIdentitySource: accountIdentitySource,
        books: books
      };
    })();
    """#

    /// Lightweight authentication/shelf-state probe. It deliberately reuses
    /// the production selectors, but does not advance the virtualized shelf.
    /// Using `libraryScan` directly for login polling used to consume and then
    /// discard the first viewport before the real sync began.
    static var sessionProbe: String {
        "window.__castreaderGoogleBooksProbeOnly = true;\n" + libraryScan
    }

#if DEBUG
    /// Synthetic metadata-only library using the observed Google custom
    /// elements and nested cover/metadata card shape. No account DOM or book
    /// content is copied. Its asynchronous four-card viewport deliberately
    /// needs more than 24 scan passes to reach all 100 books.
    static let debugHundredBookShelfFixture = #"""
    <!doctype html><html lang="zh-CN"><head>
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <style>
        * { box-sizing: border-box; }
        body { margin: 0; font: 14px -apple-system,sans-serif; color: #25272c; background: #f5f6f8; }
        header { margin: 12px; padding: 13px; background: #eaf2ff; border-radius: 12px; }
        header h1 { margin: 0 0 7px; font-size: 19px; }
        header p { margin: 4px 0; color: #536887; line-height: 1.45; }
        header button { border: 0; background: none; padding: 3px 0; color: #536887; }
        #shelf { box-sizing: content-box; height: 180px; margin: 12px; overflow-y: auto; overscroll-behavior: contain; border: 1px solid #d6deea; border-radius: 8px; background: white; }
        gpb-library-home,gpb-shelf-page,gpb-volume-card { display: block; }
        gpb-volume-card { height: 60px; border-bottom: 1px solid #edf0f4; padding: 9px 12px; }
        .card { display: flex; gap: 10px; height: 42px; }
        .cover { width: 28px; flex: 0 0 28px; }
        .cover-image-container { height: 40px; position: relative; }
        .refresh-cover-image { width: 28px; height: 40px; }
        .cover-link { position: absolute; inset: 0; }
        .title { display: block; color: #244c82; font-weight: 600; text-decoration: none; line-height: 21px; }
        .card-link { display: none; }
        .author { color: #858d98; font-size: 12px; }
        #fixture-state { margin: 12px; color: #526477; line-height: 1.5; }
      </style>
    </head><body>
      <header><h1>Google Play 图书 · 100 本同步测试</h1>
        <p>100 本合成书目，窄列表异步加载。不含真实书籍正文。</p>
        <button data-email="synthetic-googlebooks@example.invalid">Synthetic Google account</button>
      </header>
      <gpb-library-home><div class="main-content"><div class="content">
        <gpb-shelf-page id="shelf">
          <div id="before"></div><div id="rows" class="-gb-book-card-grid"></div><div id="after"></div>
        </gpb-shelf-page>
      </div></div></gpb-library-home>
      <p id="fixture-state"></p>
      <script>
        var shelf = document.getElementById('shelf');
        var fixture = window.__castreaderGoogleBooksHundredFixture = {
          totalBooks: 100, rowHeight: 60, windowSize: 4, renderDelayMS: 40,
          pending: false, stallRendering: false, renderCount: 0,
          renderedStart: 0, requestedStart: 0, seenVolumeIDs: []
        };
        var renderTimer = null;
        var seen = {};
        function volumeID(number) { return 'GBFIX' + String(number).padStart(4, '0'); }
        function render() {
          var start = Math.min(99, Math.max(0, Math.floor(shelf.scrollTop / fixture.rowHeight)));
          var count = Math.min(fixture.windowSize, fixture.totalBooks - start);
          document.getElementById('before').style.height = (start * fixture.rowHeight) + 'px';
          var cards = [];
          for (var index = start; index < start + count; index++) {
            var number = index + 1;
            var id = volumeID(number);
            seen[id] = true;
            var title = 'Google 合成测试书 ' + String(number).padStart(3, '0');
            var href = '/books/reader?id=' + id;
            var cover = 'data:image/svg+xml,%3Csvg xmlns="http://www.w3.org/2000/svg" width="28" height="40"%3E%3Crect width="28" height="40" fill="%234d6794"/%3E%3C/svg%3E';
            cards.push('<gpb-volume-card draggable="true"><div class="card ebook">' +
              '<div style="display:none" id="title-' + id + '">对应“' + title + '”</div>' +
              '<a aria-hidden="true" tabindex="-1" class="card-link" title="' + title + '" href="' + href + '"></a>' +
              '<div class="cover"><div class="cover-image-container">' +
              '<img alt="" aria-hidden="true" class="refresh-cover-image" src=\'' + cover + '\'>' +
              '<a class="cover-link" title="' + title + '" aria-label="' + title + '" href="' + href + '"></a></div></div>' +
              '<div class="below-cover"><div class="bottompanel"><div class="metadata">' +
              '<a class="title" title="' + title + '" href="' + href + '">' + title + '</a>' +
              '<a class="author" title="Synthetic Google Author">Synthetic Google Author</a>' +
              '</div></div></div></div></gpb-volume-card>');
          }
          document.getElementById('rows').innerHTML = cards.join('');
          document.getElementById('after').style.height = ((fixture.totalBooks - start - count) * fixture.rowHeight) + 'px';
          fixture.pending = false;
          fixture.renderedStart = start;
          fixture.renderCount += 1;
          fixture.seenVolumeIDs = Object.keys(seen).sort();
          shelf.removeAttribute('aria-busy');
          document.getElementById('fixture-state').textContent = '当前显示 ' + (start + 1) + '–' + (start + count) +
            ' / 100 · 已呈现 ' + fixture.seenVolumeIDs.length + ' 本';
        }
        function scheduleRender() {
          fixture.pending = true;
          fixture.requestedStart = Math.floor(shelf.scrollTop / fixture.rowHeight);
          shelf.setAttribute('aria-busy', 'true');
          if (renderTimer !== null) clearTimeout(renderTimer);
          if (!fixture.stallRendering) {
            renderTimer = setTimeout(function () { renderTimer = null; render(); }, fixture.renderDelayMS);
          }
        }
        fixture.finishPendingRender = function () {
          if (renderTimer !== null) clearTimeout(renderTimer);
          renderTimer = null;
          render();
        };
        shelf.addEventListener('scroll', scheduleRender);
        document.addEventListener('click', function (event) {
          if (event.target.closest('a')) event.preventDefault();
        });
        render();
      </script>
    </body></html>
    """#
#endif

    /// 阅读器壳里的最小辅助脚本（documentStart，主帧）：
    /// 关掉 Play 图书自己的「打开 App」引导，避免把 WebView 顶走。
    static let readerShellPrelude = #"""
    (function () {
      if (window.__castreaderGBShell) return;
      window.__castreaderGBShell = true;
      var css = document.createElement('style');
      css.textContent = [
        // 底部/顶部的 App 安装横幅会盖住阅读区，且点到会跳出 WebView。
        'a[href*="itunes.apple.com"], a[href*="apps.apple.com"] { display: none !important; }',
        '.smartbanner, #smartbanner { display: none !important; }'
      ].join('\n');
      var attach = function () {
        if (document.head) document.head.appendChild(css);
        else if (document.documentElement) document.documentElement.appendChild(css);
      };
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', attach);
      } else {
        attach();
      }
    })();
    """#
}
