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
        try { return new URL(href, location.origin).href; } catch (e) { return ''; }
      }
      function volumeFrom(href) {
        if (!href) return '';
        var m = /[?&#]id=([A-Za-z0-9_-]{6,64})/.exec(href);
        return m ? m[1] : '';
      }

      var authRequired = false;
      var authenticated = false;
      var hasAccountEvidence = false;
      var isShelfContext = false;
      var account = null;
      var accountIdentitySource = '';
      try {
        var host = String(location.hostname || '').toLowerCase();
        var path = String(location.pathname || '').toLowerCase().replace(/\/+$/, '') || '/';
        isShelfContext = host === 'play.google.com' &&
          (path === '/books' || (path.indexOf('/books/') === 0 && path.indexOf('/books/reader') !== 0));
        if (host === 'accounts.google.com') authRequired = true;

        // Prefer URL/data attributes over localized visible text. aria-label
        // remains a fallback because Google currently puts the signed-in
        // email there in most locales.
        var accountNode = document.querySelector(
          '[data-email], a[href*="SignOutOptions"], a[href*="/ManageAccount"], a[href*="accounts.google.com/SignOutOptions"], header a[aria-label*="@"], img.gb_P'
        );
        var signInNode = document.querySelector(
          'a[href*="ServiceLogin"], a[href*="accounts.google.com/signin"]'
        );
        hasAccountEvidence = !!accountNode;
        if (accountNode) {
          var rawEvidence =
            accountNode.getAttribute('data-email') ||
            accountNode.getAttribute('aria-label') ||
            accountNode.getAttribute('alt') ||
            accountNode.getAttribute('title') || '';
          var emailMatch = /([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+)/.exec(rawEvidence);
          if (emailMatch) {
            accountIdentitySource = String(emailMatch[1]).toLowerCase();
            // 只保留域名部分作展示，不带邮箱本体。
            account = 'Google · ' + accountIdentitySource.split('@')[1];
          } else {
            accountIdentitySource = String(rawEvidence || '')
              .replace(/\s+/g, ' ')
              .trim()
              .toLowerCase();
          }
        }
        authenticated = hasAccountEvidence && isShelfContext && !authRequired;
        if (!hasAccountEvidence && signInNode) authRequired = true;
      } catch (e) { /* */ }

      var found = {};
      var observedBookNodes = [];
      function push(href, node) {
        var url = abs(href);
        var volume = volumeFrom(url);
        if (!volume) return;
        if (node) observedBookNodes.push(node);
        if (found[volume]) return;
        var card = node ? (node.closest('[role="listitem"], li, .card, [data-item-id], div') || node) : null;
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

      // Find the real vertical scroll owner from book-card ancestors. Google
      // alternates between document scrolling and a virtualized nested list.
      // Move it one viewport per scan pass; the native loop unions the cards
      // observed across passes.
      var scrollRoot = document.scrollingElement || document.documentElement;
      var bestRange = scrollRoot
        ? Math.max(0, Number(scrollRoot.scrollHeight || 0) - Number(scrollRoot.clientHeight || 0))
        : 0;
      try {
        var nestedRoot = null;
        var nestedRange = 0;
        for (var n = 0; n < observedBookNodes.length; n++) {
          var ancestor = observedBookNodes[n];
          var depth = 0;
          while (ancestor && ancestor !== document.body && depth < 12) {
            var range = Math.max(
              0,
              Number(ancestor.scrollHeight || 0) - Number(ancestor.clientHeight || 0)
            );
            if (range > nestedRange + 8) {
              var style = window.getComputedStyle(ancestor);
              var overflowY = style ? String(style.overflowY || '') : '';
              if (overflowY === 'auto' || overflowY === 'scroll') {
                nestedRoot = ancestor;
                nestedRange = range;
              }
            }
            ancestor = ancestor.parentElement;
            depth++;
          }
        }
        if (nestedRoot) {
          scrollRoot = nestedRoot;
          bestRange = nestedRange;
        }
      } catch (e) { /* */ }

      var scrollTop = 0;
      var viewport = 0;
      var atScrollEnd = true;
      try {
        if (scrollRoot) {
          scrollTop = Number(scrollRoot.scrollTop || 0);
          viewport = Number(scrollRoot.clientHeight || window.innerHeight || 0);
          bestRange = Math.max(
            0,
            Number(scrollRoot.scrollHeight || 0) - viewport
          );
          atScrollEnd = bestRange <= 8 || scrollTop >= bestRange - 8;
          // Authentication/session probes must be side-effect free with one
          // exception: once the real signed-in shelf is reached, rewind it to
          // the first viewport so the following full scan cannot silently
          // skip cards that the probe itself observed.
          if (probeOnly && authenticated) {
            scrollRoot.scrollTop = 0;
            scrollTop = 0;
            atScrollEnd = bestRange <= 8;
          } else if (!probeOnly && !atScrollEnd) {
            scrollRoot.scrollTop = Math.min(
              bestRange,
              scrollTop + Math.max(viewport * 0.82, 520)
            );
          }
        }
      } catch (e) { atScrollEnd = false; }
      var hasPendingShelfWork = !!document.querySelector(
        'main[aria-busy="true"], [role="main"][aria-busy="true"], [data-loading="true"]'
      );
      var isCompleteSnapshot = authenticated &&
        document.readyState === 'complete' &&
        atScrollEnd &&
        !hasPendingShelfWork;

      return {
        authRequired: authRequired,
        authenticated: authenticated,
        hasAccountEvidence: hasAccountEvidence,
        isShelfContext: isShelfContext,
        isCompleteSnapshot: isCompleteSnapshot,
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
