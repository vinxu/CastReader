//
//  KoboWebScripts.swift
//  CastReader
//
//  Kobo binding/shelf metadata scan. Credentials remain exclusively in the
//  shared persistent WKWebsiteDataStore; CastReader stores only book metadata.
//

import Foundation

enum KoboWebScripts {
    static let shelfURL =
        URL(string: "https://www.kobo.com/sg/en/library/books")!
    static let homeURL = shelfURL

    /// Kobo renders the sign-in affordance dynamically and may select Google,
    /// Rakuten or email login. Prefer its current same-session destination.
    static let currentPageSignInURL = #"""
    (function () {
      var selectors = [
        'a[data-testid*="sign-in" i]',
        'a[href*="/signin" i]',
        'a[href*="/login" i]',
        'a[href*="authorize" i]',
        'button[data-testid*="sign-in" i]'
      ];
      for (var i = 0; i < selectors.length; i += 1) {
        var node = document.querySelector(selectors[i]);
        if (!node) continue;
        var href = node.href || node.getAttribute('data-href') || '';
        if (!href) continue;
        try {
          var target = new URL(href, location.href);
          if (target.protocol === 'https:') return target.href;
        } catch (e) {}
      }
      return null;
    })();
    """#

    static func isShelfURL(_ url: URL?) -> Bool {
        guard let url,
              let host = url.host?.lowercased(),
              host == "www.kobo.com" || host == "kobo.com" else {
            return false
        }
        return url.path.lowercased().contains("/library/books")
    }

    /// Binding is allowed to traverse only official Kobo/Rakuten identity
    /// origins plus identity providers Kobo visibly delegates to. The reader
    /// itself has a much narrower readnow.kobo.com policy.
    static func allowsBindingNavigation(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host?.lowercased() else {
            return false
        }
        let suffixes = [
            "kobo.com",
            "kobobooks.com",
            "rakuten.com",
            "rakuten.co.jp",
        ]
        if suffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        return host == "accounts.google.com" || host == "appleid.apple.com"
    }

    static let libraryScan = #"""
    (function () {
      var probeOnly = window.__castreaderKoboProbeOnly === true;
      try { delete window.__castreaderKoboProbeOnly; }
      catch (e) { window.__castreaderKoboProbeOnly = false; }

      function clean(value) {
        return String(value || '').replace(/\s+/g, ' ').trim();
      }
      function absolute(href) {
        try { return new URL(href, location.href).href; }
        catch (e) { return ''; }
      }
      function uuidFrom(value) {
        var match = /(?:readnow\.kobo\.com\/|\/ReadNow\/)([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})(?:[/?#]|$)/i.exec(value || '');
        if (!match) {
          match = /\b([0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\b/i.exec(value || '');
        }
        return match ? match[1].toLowerCase() : '';
      }
      function stripActionTitle(value) {
        var title = clean(value);
        for (var pass = 0; pass < 2; pass += 1) {
          title = clean(title.replace(
            /^(?:read\s*now|continue(?:\s*reading)?|open(?:\s*book)?|start\s*reading|resume(?:\s*reading)?)\s*[:\-–—]\s*/i,
            ''
          ));
        }
        return title;
      }
      function placeholderTitle(value) {
        var lower = clean(value).toLowerCase();
        return !lower || [
          'book', 'book cover', 'cover', 'read now', 'continue reading',
          'unknown title', 'untitled', 'kobo', 'rakuten kobo'
        ].indexOf(lower) >= 0;
      }
      function realImageURL(value) {
        var raw = clean(value);
        if (!raw) return '';
        if (raw.indexOf(',') >= 0) {
          var srcset = raw.split(',');
          for (var i = srcset.length - 1; i >= 0; i -= 1) {
            var token = clean(srcset[i]).split(/\s+/)[0];
            var parsed = realImageURL(token);
            if (parsed) return parsed;
          }
          return '';
        }
        if (/\s+\d+(?:\.\d+)?[wx]\s*$/i.test(raw)) {
          raw = raw.split(/\s+/)[0];
        }
        if (/^(?:data|blob|about):/i.test(raw) ||
            /(?:transparent|spacer|blank|pixel)(?:[._-]|\b)/i.test(raw)) {
          return '';
        }
        var resolved = absolute(raw);
        return /^https:\/\//i.test(resolved) ? resolved : '';
      }
      function imageSource(image) {
        if (!image) return '';
        var picture = image.closest && image.closest('picture');
        var sources = picture ? picture.querySelectorAll('source') : [];
        for (var i = sources.length - 1; i >= 0; i -= 1) {
          var sourceURL = realImageURL(
            sources[i].getAttribute('srcset') ||
            sources[i].getAttribute('data-srcset') ||
            ''
          );
          if (sourceURL) return sourceURL;
        }
        var values = [
          image.getAttribute('data-src'),
          image.getAttribute('data-lazy-src'),
          image.getAttribute('data-original'),
          image.getAttribute('data-srcset'),
          image.getAttribute('srcset'),
          image.currentSrc,
          image.getAttribute('src')
        ];
        for (var n = 0; n < values.length; n += 1) {
          var url = realImageURL(values[n]);
          if (url) return url;
        }
        return '';
      }
      function cardCover(card) {
        if (!card) return '';
        var images = card.querySelectorAll('img');
        for (var i = 0; i < images.length; i += 1) {
          var imageURL = imageSource(images[i]);
          if (imageURL) return imageURL;
        }
        var styled = card.querySelectorAll(
          '[style*="background-image" i], [data-testid*="cover" i], [class*="cover" i]'
        );
        for (var n = 0; n < styled.length; n += 1) {
          var css = '';
          try { css = getComputedStyle(styled[n]).backgroundImage || ''; }
          catch (e) {}
          var match = /url\((['"]?)(.*?)\1\)/i.exec(css);
          var backgroundURL = realImageURL(match && match[2]);
          if (backgroundURL) return backgroundURL;
        }
        return '';
      }
      function firstMeaningful(card, selectors, transform) {
        if (!card) return '';
        for (var i = 0; i < selectors.length; i += 1) {
          var nodes = card.querySelectorAll(selectors[i]);
          for (var n = 0; n < nodes.length; n += 1) {
            var value = transform(nodes[n]);
            if (value) return value;
          }
        }
        return '';
      }
      function cardTitle(card, actionNode) {
        var title = firstMeaningful(card, [
          '[data-testid*="title" i]',
          '[data-qa*="title" i]',
          '[itemprop="name"]',
          '[class*="title" i]',
          'h1', 'h2', 'h3', 'h4'
        ], function (node) {
          var value = stripActionTitle(
            node.getAttribute('aria-label') ||
            node.getAttribute('title') ||
            node.textContent
          );
          return placeholderTitle(value) ? '' : value;
        });
        if (title) return title;
        var images = card ? card.querySelectorAll('img') : [];
        for (var i = 0; i < images.length; i += 1) {
          title = stripActionTitle(images[i].getAttribute('alt'));
          if (!placeholderTitle(title)) return title;
        }
        title = stripActionTitle(
          actionNode && (
            actionNode.getAttribute('aria-label') ||
            actionNode.getAttribute('title') ||
            actionNode.textContent
          )
        );
        return placeholderTitle(title) ? '' : title;
      }
      function cardAuthor(card, title) {
        return firstMeaningful(card, [
          '[data-testid*="author" i]',
          '[data-qa*="author" i]',
          '[itemprop="author"]',
          '[class*="author" i]',
          '[class*="contributor" i]',
          '.subtitle'
        ], function (node) {
          var value = clean(
            node.getAttribute('aria-label') ||
            node.getAttribute('title') ||
            node.textContent
          ).replace(/^(?:by|author)\s*[:\-]?\s*/i, '');
          var lower = clean(value).toLowerCase();
          if (!lower ||
              lower === clean(title).toLowerCase() ||
              lower === 'unknown author' ||
              lower === 'author') return '';
          return clean(value);
        });
      }
      function cardUUIDs(card) {
        var ids = {};
        if (!card) return ids;
        var nodes = card.querySelectorAll([
          'a[href*="readnow.kobo.com/"]',
          'a[href*="/ReadNow/"]',
          '[data-content-id]',
          '[data-book-id]'
        ].join(','));
        for (var i = 0; i < nodes.length; i += 1) {
          var id = uuidFrom(
            nodes[i].href ||
            nodes[i].getAttribute('data-href') ||
            nodes[i].getAttribute('data-content-id') ||
            nodes[i].getAttribute('data-book-id') ||
            ''
          );
          if (id) ids[id] = true;
        }
        return ids;
      }
      function bestCard(node, uuid) {
        if (!node) return null;
        var interactive = /^(?:A|BUTTON)$/i.test(node.tagName || '');
        var ancestor = interactive ? node.parentElement : node;
        var best = null;
        var bestScore = -100000;
        var depth = 0;
        while (ancestor && ancestor !== document.body && depth++ < 12) {
          var ids = cardUUIDs(ancestor);
          var idList = Object.keys(ids);
          var title = cardTitle(ancestor, node);
          var author = cardAuthor(ancestor, title);
          var cover = cardCover(ancestor);
          var score =
            (title ? 140 : 0) +
            (author ? 50 : 0) +
            (cover ? 50 : 0) +
            (ancestor.matches(
              '[role="listitem"],article,li,[data-testid*="book" i],[data-qa*="book" i]'
            ) ? 90 : 0) -
            (idList.length > 1 ? 1000 : 0) -
            depth;
          if (ids[uuid]) score += 120;
          if (score > bestScore) {
            bestScore = score;
            best = ancestor;
          }
          ancestor = ancestor.parentElement;
        }
        return best || node.parentElement;
      }
      function titleScore(value) {
        var title = stripActionTitle(value);
        return placeholderTitle(title) ? 0 : 1000 + Math.min(title.length, 200);
      }
      function authorScore(value) {
        var author = clean(value).toLowerCase();
        if (!author || author === 'unknown author' || author === 'author') return 0;
        return 100 + Math.min(author.length, 120);
      }
      function mergeFound(oldValue, newValue) {
        newValue.title = stripActionTitle(newValue.title);
        if (!oldValue) return newValue;
        var result = oldValue;
        result.title = stripActionTitle(result.title);
        if (titleScore(newValue.title) > titleScore(result.title)) {
          result.title = newValue.title;
        }
        if (authorScore(newValue.author) > authorScore(result.author)) {
          result.author = newValue.author;
        }
        if (!result.coverURL && newValue.coverURL) {
          result.coverURL = newValue.coverURL;
        }
        if (!result.progressLabel && newValue.progressLabel) {
          result.progressLabel = newValue.progressLabel;
        }
        return result;
      }

      var host = String(location.hostname || '').toLowerCase();
      var path = String(location.pathname || '').toLowerCase();
      var isShelfContext =
        (host === 'www.kobo.com' || host === 'kobo.com') &&
        path.indexOf('/library/books') >= 0;
      var accountNode = document.querySelector([
        'a[href*="/signout" i]',
        'a[href*="/logout" i]',
        '[data-testid*="account-menu" i]',
        '[data-testid*="user-menu" i]',
        '[aria-label*="account" i][href*="/account" i]'
      ].join(','));
      var signInNode = document.querySelector([
        'a[data-testid*="sign-in" i]',
        'a[href*="/signin" i]',
        'a[href*="/login" i]',
        'button[data-testid*="sign-in" i]'
      ].join(','));
      var hasAccountEvidence = !!accountNode;
      var authRequired = !hasAccountEvidence && (!!signInNode || !isShelfContext);
      var authenticated = hasAccountEvidence && isShelfContext;
      var rawAccount = accountNode
        ? clean(
            accountNode.getAttribute('data-email') ||
            accountNode.getAttribute('aria-label') ||
            accountNode.getAttribute('title') ||
            accountNode.textContent
          )
        : '';
      var accountIdentitySource = rawAccount.toLowerCase();
      var account = rawAccount ? 'Kobo · ' + rawAccount.replace(/^.*?([@•])/,'') : null;

      var found = {};
      var bookNodes = [];
      function push(candidate, node) {
        var href = absolute(candidate || '');
        var uuid = uuidFrom(href) || uuidFrom(
          node && (
            node.getAttribute('data-content-id') ||
            node.getAttribute('data-book-id') ||
            node.getAttribute('data-testid') ||
            node.id
          )
        );
        if (!uuid) return;
        var card = bestCard(node, uuid);
        if (card) bookNodes.push(card);
        var title = cardTitle(card, node);
        var author = cardAuthor(card, title);
        var coverURL = cardCover(card);
        var progressNode = card && card.querySelector(
          '[role="progressbar"], [data-testid*="progress" i], .progress'
        );
        var progressLabel = progressNode
          ? clean(
              progressNode.getAttribute('aria-label') ||
              progressNode.textContent ||
              progressNode.getAttribute('aria-valuenow')
            )
          : '';
        if (!title) return;
        found[uuid] = mergeFound(found[uuid], {
          id: uuid,
          readerURL:
            'https://readnow.kobo.com/' + uuid +
            '?backref_url=' + encodeURIComponent(location.href) +
            '&locale=' + encodeURIComponent(
              (document.documentElement.lang || 'en-US').replace('_','-')
            ),
          title: title,
          author: author,
          coverURL: coverURL,
          progressLabel: progressLabel
        });
      }

      var links = document.querySelectorAll([
        'a[href*="readnow.kobo.com/"]',
        'a[href*="/ReadNow/"]',
        'a[data-testid*="read-now" i]',
        '[data-content-id]',
        '[data-book-id]'
      ].join(','));
      for (var i = 0; i < links.length; i += 1) {
        push(links[i].href || links[i].getAttribute('data-href') || '', links[i]);
      }

      var books = [];
      Object.keys(found).forEach(function (key) { books.push(found[key]); });

      var scrollRoot = document.scrollingElement || document.documentElement;
      var bestRange = scrollRoot
        ? Math.max(0, Number(scrollRoot.scrollHeight || 0) - Number(scrollRoot.clientHeight || 0))
        : 0;
      for (var n = 0; n < bookNodes.length; n += 1) {
        var ancestor = bookNodes[n];
        var depth = 0;
        while (ancestor && ancestor !== document.body && depth++ < 12) {
          var range = Math.max(
            0,
            Number(ancestor.scrollHeight || 0) - Number(ancestor.clientHeight || 0)
          );
          var style = window.getComputedStyle(ancestor);
          if (range > bestRange + 8 &&
              (style.overflowY === 'auto' || style.overflowY === 'scroll')) {
            scrollRoot = ancestor;
            bestRange = range;
          }
          ancestor = ancestor.parentElement;
        }
      }

      var atScrollEnd = true;
      if (scrollRoot) {
        var viewport = Number(scrollRoot.clientHeight || window.innerHeight || 0);
        bestRange = Math.max(
          0,
          Number(scrollRoot.scrollHeight || 0) - viewport
        );
        var scrollTop = Number(scrollRoot.scrollTop || 0);
        atScrollEnd = bestRange <= 8 || scrollTop >= bestRange - 8;
        if (probeOnly && authenticated) {
          scrollRoot.scrollTop = 0;
          atScrollEnd = bestRange <= 8;
        } else if (!probeOnly && !atScrollEnd) {
          scrollRoot.scrollTop = Math.min(
            bestRange,
            scrollTop + Math.max(viewport * 0.82, 520)
          );
        }
      }
      var hasPendingWork = !!document.querySelector([
        '[aria-busy="true"]',
        '[data-loading="true"]',
        '[data-testid*="skeleton" i]',
        '[data-testid*="loading" i]'
      ].join(','));
      return {
        authRequired: authRequired,
        authenticated: authenticated,
        hasAccountEvidence: hasAccountEvidence,
        isShelfContext: isShelfContext,
        isCompleteSnapshot:
          authenticated &&
          document.readyState !== 'loading' &&
          atScrollEnd &&
          !hasPendingWork,
        account: account,
        accountIdentitySource: accountIdentitySource,
        books: books
      };
    })();
    """#

    static var sessionProbe: String {
        "window.__castreaderKoboProbeOnly = true;\n" + libraryScan
    }

    /// Hide install-app chrome that can cover the bottom of the reader. The
    /// CastReader control bar remains native and outside this viewport.
    static let readerShellPrelude = #"""
    (function () {
      if (window.__castreaderKoboShell) return;
      window.__castreaderKoboShell = true;
      var style = document.createElement('style');
      style.textContent = [
        'a[href*="apps.apple.com"], a[href*="itunes.apple.com"] { display:none !important; }',
        '[data-testid*="app-banner" i], .smartbanner, #smartbanner { display:none !important; }'
      ].join('\n');
      function attach() {
        (document.head || document.documentElement).appendChild(style);
      }
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', attach, { once:true });
      } else {
        attach();
      }
    })();
    """#
}
