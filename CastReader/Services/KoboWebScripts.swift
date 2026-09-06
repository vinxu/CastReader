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
        KoboWebAccessPolicy.allowsLibraryURL(url)
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
        if host == "gds.google.com" {
            return url.path.lowercased() == "/web/landing"
                || url.path.lowercased() == "/web/landing/"
        }
        return host == "accounts.google.com" || host == "appleid.apple.com"
    }

    /// Shared page-shape checks. No input value, account text, cookie or token
    /// is returned by the login probe or used to activate the official entry.
    private static let bindingDOMHelpers = #"""
      function bindingClean(value) {
        return String(value || '').replace(/\s+/g, ' ').trim();
      }
      function bindingVisible(node) {
        if (!node || !node.isConnected) return false;
        for (var parent = node; parent && parent.nodeType === 1; parent = parent.parentElement) {
          var style = getComputedStyle(parent);
          if (parent.hidden || parent.getAttribute('aria-hidden') === 'true' ||
              parent.hasAttribute('inert') || style.display === 'none' ||
              style.visibility === 'hidden' || style.visibility === 'collapse' ||
              Number(style.opacity) === 0) return false;
        }
        return node.getClientRects().length > 0;
      }
      function bindingFirstVisible(selector) {
        return Array.from(document.querySelectorAll(selector)).find(bindingVisible) || null;
      }
      function bindingCredentialForm() {
        if (bindingFirstVisible([
          'input[type="password"]', 'input[autocomplete~="current-password"]',
          'input[autocomplete~="new-password"]', 'input[autocomplete~="one-time-code"]',
          'input[autocomplete~="username"]'
        ].join(','))) return true;
        return Array.from(document.querySelectorAll('form,[role="dialog"]')).some(function (form) {
          if (!bindingVisible(form)) return false;
          var label = [form.getAttribute('aria-label'), form.getAttribute('data-testid'),
            form.getAttribute('id'), form.getAttribute('class')].join(' ');
          var action = form.getAttribute('action') || '';
          var authForm = /sign.?in|log.?in|authenticat|authorize|verification|passkey|one.?time/i.test(label) ||
            /(?:^|\/)(?:signin|sign-in|login|authorize|authenticate)(?:[/?#]|$)/i.test(action);
          if (!authForm) return false;
          return Array.from(form.querySelectorAll('input,button,select')).some(bindingVisible);
        });
      }
      function bindingAccountNode() {
        var selector = [
          'a[href*="/signout" i]', 'a[href*="/logout" i]',
          '[data-testid*="account-menu" i]', '[data-testid*="user-menu" i]',
          '[aria-label*="account" i][href*="/account" i]'
        ].join(',');
        // Kobo's mobile header keeps these links inside a collapsed menu.
        // Its explicit server login state, plus the actual library container,
        // allows that DOM evidence without requiring the user to open a menu.
        if (bindingServerLoginState() === true && bindingShelfRoot()) {
          return document.querySelector(selector);
        }
        return bindingFirstVisible(selector);
      }
      function bindingServerLoginState() {
        var user = window.DynamicConfiguration && window.DynamicConfiguration.user;
        return user && typeof user.isLoggedIn === 'boolean' ? user.isLoggedIn : null;
      }
      function bindingShelfRoot() {
        return bindingShelfContext() && bindingFirstVisible(
          'body.Store-Library #library-grid .library-items'
        );
      }
      function bindingHasAccountEvidence() {
        if (bindingCredentialForm() || bindingServerLoginState() === false) return false;
        if (bindingServerLoginState() === true) return !!bindingShelfRoot();
        return !bindingSignInControl() && !!bindingAccountNode();
      }
      function bindingAccountIdentity(node) {
        if (!node) return '';
        var candidates = [node.getAttribute('data-email'), node.getAttribute('aria-label'),
          node.getAttribute('title'), node.textContent];
        for (var i = 0; i < candidates.length; i++) {
          var email = bindingClean(candidates[i]).match(/[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+/);
          if (email) return email[0].toLowerCase();
        }
        // "Sign out" and "My Account" are shared labels, never user IDs.
        return '';
      }
      function bindingSignInControl() {
        return Array.from(document.querySelectorAll('a,button,[role="button"]')).find(function (node) {
          if (!bindingVisible(node) || node.closest('[disabled],[aria-disabled="true"]')) return false;
          // Submit controls belong to the site's credential flow, never the
          // native "open login" action (including forms with omitted type).
          if (node.tagName === 'BUTTON' && node.type === 'submit' && node.closest('form')) return false;
          var label = bindingClean([node.getAttribute('aria-label'), node.getAttribute('data-testid'),
            node.getAttribute('data-test-id'), node.getAttribute('title'), node.textContent].join(' '));
          var href = node.getAttribute('href') || node.getAttribute('data-href') || '';
          var route = '';
          if (href) {
            try {
              var target = new URL(href, location.href);
              if (target.protocol !== 'https:' || target.username || target.password ||
                  (target.port && target.port !== '443')) return false;
              var host = target.hostname.toLowerCase();
              var official = /(^|\.)(?:kobo\.com|kobobooks\.com|rakuten\.com|rakuten\.co\.jp)$/.test(host) ||
                host === 'accounts.google.com' || host === 'appleid.apple.com';
              if (!official) return false;
              route = target.pathname;
            } catch (error) { return false; }
          }
          return /(?:^|\/)(?:signin|sign-in|login|authorize)(?:[/?#]|$)/i.test(route) ||
            /(?:^|\b)(?:sign[ -]?in|log[ -]?in)(?:\b|$)|登录|登入|ログイン|connexion|anmelden|iniciar sesi[oó]n/i.test(label);
        }) || null;
      }
      function bindingShelfContext() {
        if (location.protocol !== 'https:' || (location.port && location.port !== '443')) return false;
        var host = String(location.hostname || '').toLowerCase();
        if (host !== 'www.kobo.com' && host !== 'kobo.com') return false;
        return /^\/(?:[a-z0-9-]{2,16}\/[a-z0-9-]{2,16}\/)?library\/books\/?$/i.test(location.pathname);
      }
      function bindingLoading() {
        return document.readyState === 'loading' || !!bindingFirstVisible([
          '[aria-busy="true"]', '[data-loading="true"]',
          '[data-testid*="skeleton" i]', '[data-testid*="loading" i]'
        ].join(','));
      }
    """#

    static let bindingPageProbe = "(function () {\n" + bindingDOMHelpers + #"""
      var hasCredentialForm = bindingCredentialForm();
      var hasSignInControl = !!bindingSignInControl();
      var hasAccountEvidence = bindingHasAccountEvidence();
      var isShelfContext = bindingShelfContext();
      var hasShelfBooks = isShelfContext && Array.from(document.querySelectorAll(
        'a[href*="readnow.kobo.com/" i], [data-content-id], [data-book-id]'
      )).some(function (node) {
        return bindingVisible(node) && !node.closest('aside,[aria-label*="recommend" i],[data-testid*="recommend" i]') &&
          (bindingServerLoginState() !== true || !!node.closest('#library-grid .library-items'));
      });
      var bodyTextLength = document.body ? bindingClean(document.body.innerText).length : 0;
      var hasVisibleSurface = !!bindingFirstVisible('input,button,a,img,iframe,canvas,video,[role="dialog"]');
      return {
        hasCredentialForm: hasCredentialForm,
        hasSignInControl: hasSignInControl,
        hasAccountEvidence: hasAccountEvidence,
        isShelfContext: isShelfContext,
        isBlank: bodyTextLength === 0 && !hasVisibleSurface,
        isLoading: bindingLoading(),
        hasShelfBooks: hasShelfBooks,
        bodyTextLength: bodyTextLength
      };
    })();
    """#

    static let activateSignIn = "(function () {\n" + bindingDOMHelpers + #"""
      if (bindingCredentialForm()) return 'form';
      var control = bindingSignInControl();
      if (!control) return 'unavailable';
      control.click();
      return 'clicked';
    })();
    """#

    /// Called with WKWebView.callAsyncJavaScript only after the shelf proves
    /// login. This GET reads the existing profile email, never login/password
    /// fields. Only a hash and non-identifying domain label leave WebKit.
    static let accountSettingsIdentity = bindingDOMHelpers + #"""
      if (!bindingHasAccountEvidence() || !bindingShelfRoot()) return null;
      var link = Array.from(document.querySelectorAll('a[href]')).find(function (node) {
        try {
          var url = new URL(node.href, location.href);
          return url.origin === location.origin && /\/account\/settings\/?$/i.test(url.pathname);
        } catch (e) { return false; }
      });
      if (!link) return null;
      var target = new URL(link.href, location.href);
      var controller = new AbortController();
      var timer = setTimeout(function () { controller.abort(); }, 10000);
      try {
        var response = await fetch(target.href, { credentials: 'same-origin', cache: 'no-store', signal: controller.signal });
        var finalURL = new URL(response.url);
        if (!response.ok || finalURL.origin !== target.origin || finalURL.pathname !== target.pathname) return null;
        var doc = new DOMParser().parseFromString(await response.text(), 'text/html');
        var emailNode = doc.querySelector('body.Account-AccountSettings #save-email-form input#email[type="email"][name="Email"]');
        var email = emailNode ? bindingClean(emailNode.getAttribute('value')).toLowerCase() : '';
        if (!/^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$/.test(email)) return null;
        var digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(email.normalize('NFC')));
        var hash = Array.from(new Uint8Array(digest)).map(function (b) { return b.toString(16).padStart(2, '0'); }).join('');
        return { identity: 'sha256:' + hash, label: 'Kobo · ' + email.split('@')[1] };
      } finally { clearTimeout(timer); }
    """#

    static let libraryScan = "(function () {\n" + bindingDOMHelpers + #"""
      var probeOnly = window.__castreaderKoboProbeOnly === true;
      var snapshotOnly = window.__castreaderKoboSnapshotOnly === true;
      try { delete window.__castreaderKoboProbeOnly; }
      catch (e) { window.__castreaderKoboProbeOnly = false; }
      try { delete window.__castreaderKoboSnapshotOnly; }
      catch (e) { window.__castreaderKoboSnapshotOnly = false; }

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
        var providedTitle = stripActionTitle(actionNode && actionNode.getAttribute('data-book-title'));
        if (!placeholderTitle(providedTitle)) return providedTitle;
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
          '[data-contributors]',
          '[data-testid*="author" i]',
          '[data-qa*="author" i]',
          '[itemprop="author"]',
          '[class*="author" i]',
          '[class*="contributor" i]',
          '.subtitle'
        ], function (node) {
          var value = clean(
            node.getAttribute('data-contributors') ||
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

      var isShelfContext = bindingShelfContext();
      var hasCredentialForm = bindingCredentialForm();
      var accountNode = hasCredentialForm ? null : bindingAccountNode();
      var signInNode = bindingSignInControl();
      var hasAccountEvidence = bindingHasAccountEvidence();
      var authRequired = hasCredentialForm || bindingServerLoginState() === false || (!hasAccountEvidence && (!!signInNode || !isShelfContext));
      var authenticated = !hasCredentialForm && hasAccountEvidence && isShelfContext;
      var rawAccount = accountNode
        ? clean(
            accountNode.getAttribute('data-email') ||
            accountNode.getAttribute('aria-label') ||
            accountNode.getAttribute('title') ||
            accountNode.textContent
          )
        : '';
      var accountIdentitySource = bindingAccountIdentity(accountNode);
      var account = accountIdentitySource || null;

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
        if (links[i].closest('aside,[aria-label*="recommend" i],[data-testid*="recommend" i]') ||
            (bindingServerLoginState() === true && !links[i].closest('#library-grid .library-items'))) continue;
        push(links[i].href || links[i].getAttribute('data-href') || '', links[i]);
      }

      var books = [];
      Object.keys(found).forEach(function (key) { books.push(found[key]); });

      // A shelf can have both lazy scrolling and numbered pages. Keep page
      // observation separate from the one explicit navigation action owned by
      // native code, so a slow transition cannot click past an unseen page.
      function visible(node) {
        for (var parent = node; parent && parent.nodeType === 1; parent = parent.parentElement) {
          var style = getComputedStyle(parent);
          if (parent.hidden || style.display === 'none' || style.visibility === 'hidden') return false;
        }
        return true;
      }
      function disabled(node) {
        return !!node.closest('[disabled], [aria-disabled="true"], .disabled, .is-disabled');
      }
      function shelfLink(node) {
        var raw = node.getAttribute('href');
        if (!raw) return node.tagName === 'BUTTON' || node.getAttribute('role') === 'button';
        try {
          var url = new URL(raw, location.href);
          if (url.protocol !== 'https:' || url.username || url.password ||
              url.origin !== location.origin || url.pathname !== location.pathname) return false;
          function scopeOf(value) {
            var scope = [];
            value.searchParams.forEach(function (value, key) {
              if (!/^(?:page|pagenumber|pageno|page-number|cursor)$/i.test(key)) scope.push(key + '=' + value);
            });
            return scope.sort().join('&');
          }
          return scopeOf(url) === scopeOf(new URL(location.href));
        } catch (e) { return false; }
      }
      function positiveNumber(value) {
        return /^\d+$/.test(clean(value)) && Number(value) > 0 ? Number(value) : null;
      }
      function pageFromURL(value) {
        try {
          var url = new URL(value, location.href);
          var page = null;
          url.searchParams.forEach(function (value, key) {
            if (/^(?:page|pagenumber|pageno|page-number)$/i.test(key)) page = positiveNumber(value);
          });
          return page;
        } catch (e) { return null; }
      }
      function paginationInfo() {
        var roots = Array.from(document.querySelectorAll([
          '[class*="pagination" i]', '[class~="pager"]', '[class*="paging" i]',
          '[aria-label*="pagination" i]', '[aria-label*="page navigation" i]',
          '[data-testid*="pagination" i]', '[data-test-id*="pagination" i]'
        ].join(','))).filter(function (node) {
          return visible(node) && !node.closest([
            'aside', '[aria-label*="recommend" i]', '[data-testid*="recommend" i]',
            // Kobo calls its "Show: 24 / 36 / 48 / 60" page-size filter
            // pagination-controls too. Those numbers are never page numbers.
            '.pagination-filter-container', '.pagination-controls.filter-chip', '#pagination-option'
          ].join(','));
        });
        var nodes = [];
        function append(node) { if (visible(node) && nodes.indexOf(node) < 0) nodes.push(node); }
        roots.forEach(function (root) {
          if (root.matches('a,button,[role="button"]')) append(root);
          root.querySelectorAll('a,button,[role="button"]').forEach(append);
        });
        // Some layouts expose only rel=next/prev without a wrapper. Do not
        // mistake a recommendation carousel's generic Next for shelf paging.
        document.querySelectorAll('a[rel="next"],a[rel="prev"]').forEach(function (node) {
          if (shelfLink(node) && !node.closest('aside,[aria-label*="recommend" i],[data-testid*="recommend" i]')) append(node);
        });
        var hasPagination = roots.length > 0 || nodes.length > 0;
        var current = null;
        var total = null;
        var numeric = [];
        var hasEllipsis = false;
        roots.forEach(function (root) {
          var label = clean(root.getAttribute('aria-label')) + ' ' + clean(root.textContent);
          var count = /(?:page\s*)?(\d+)\s*(?:of|\/)\s*(\d+)/i.exec(label);
          if (count) { current = positiveNumber(count[1]); total = positiveNumber(count[2]); }
          if (/…|\.{3}/.test(label)) hasEllipsis = true;
          root.querySelectorAll('[aria-current="page"],.active,.current,.selected').forEach(function (node) {
            var number = positiveNumber(node.textContent) || pageFromURL(node.getAttribute('href'));
            if (number) current = number;
          });
        });
        current = current || pageFromURL(location.href);
        var next = null;
        var previous = null;
        var first = null;
        var hasNextControl = false;
        var hasPreviousControl = false;
        var disabledNext = false;
        var disabledPrevious = false;
        nodes.forEach(function (node) {
          var text = clean(node.textContent);
          var label = clean([
            node.getAttribute('rel'), node.getAttribute('aria-label'), node.getAttribute('title'),
            node.getAttribute('data-testid'), node.getAttribute('data-test-id'), node.className, text
          ].join(' '));
          var isNext = /\bnext\b|\bsuivant|\bsiguiente|\bpróxim|\bweiter\b|\bavanti\b|\bvolgende\b|下一页|下一頁|次のページ|^[›»→>]$/i.test(label) || /^[›»→>]$/.test(text);
          var isPrevious = /\bprev(?:ious)?\b|\bprécéd|\banterior\b|\bzurück\b|\bindietro\b|上一页|上一頁|前のページ/i.test(label) || /^[‹«←<]$/.test(text);
          var isFirst = /\bfirst\b|\bpremière\b|\bprimera\b|首页|首頁/i.test(label);
          var number = positiveNumber(text) || pageFromURL(node.getAttribute('href'));
          if (number) numeric.push({ number: number, node: node });
          if (isNext) {
            hasNextControl = true;
            if (disabled(node)) disabledNext = true;
            else if (shelfLink(node)) next = next || node;
          }
          if (isPrevious) {
            hasPreviousControl = true;
            if (disabled(node)) disabledPrevious = true;
            else if (shelfLink(node)) previous = previous || node;
          }
          if ((isFirst || number === 1) && !disabled(node) && shelfLink(node)) first = first || node;
        });
        // Numeric links are a fallback only when there is no explicit Next.
        // An explicitly disabled/broken Next before the last page is loading
        // or unsupported markup, never evidence that the shelf is finished.
        if (!next && !hasNextControl && current) {
          numeric.forEach(function (item) {
            if (item.number === current + 1 && !disabled(item.node) && shelfLink(item.node)) next = item.node;
          });
        }
        if (!total && !hasEllipsis && numeric.length) {
          total = Math.max.apply(null, numeric.map(function (item) { return item.number; }).concat(current || 1));
        }
        var knownFuture = !!(current && total && current < total);
        var isFirst = !hasPagination || current === 1 || (disabledPrevious && !previous);
        var isLast = !hasPagination || !!(!next && !knownFuture &&
          (disabledNext || (current && !hasNextControl && !hasEllipsis && total === current)));
        var blocked = hasPagination && !next && !isLast;
        var cursor = new URL(location.href).searchParams.get('cursor');
        var key = current ? 'page:' + current : hasPagination ?
          (cursor ? 'cursor:' + cursor : 'url:' + location.href) : 'single';
        return {
          publicState: {
            hasPagination: hasPagination, currentPage: current, totalPages: total,
            isFirstPage: isFirst, isLastPage: isLast, hasNextPage: !!next,
            canGoToFirstPage: !!first, blocked: blocked, pageKey: key
          },
          next: next, first: first
        };
      }
      var pageInfo = paginationInfo();
      window.__castreaderKoboShelfPageAction = function (action) {
        if (!authenticated || !isShelfContext) return false;
        var latest = paginationInfo();
        if (latest.publicState.pageKey !== pageInfo.publicState.pageKey) return false;
        if (action === 'first' && latest.publicState.isFirstPage) return false;
        if (document.readyState === 'loading' || Array.from(document.querySelectorAll(
          '[aria-busy="true"], [data-loading="true"]'
        )).some(visible)) return false;
        var target = action === 'first' ? latest.first : action === 'next' ? latest.next : null;
        if (!target || disabled(target) || !visible(target) || !shelfLink(target)) return false;
        window.__castreaderKoboShelfPageAction = null;
        target.click();
        return true;
      };

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
        if (snapshotOnly) {
          // Commit revalidation must not scroll or turn the shelf.
        } else if (probeOnly && authenticated) {
          scrollRoot.scrollTop = 0;
          atScrollEnd = bestRange <= 8;
        } else if (!probeOnly && !atScrollEnd) {
          scrollRoot.scrollTop = Math.min(
            bestRange,
            scrollTop + Math.max(viewport * 0.82, 520)
          );
        }
      }
      var hasPendingWork = document.readyState === 'loading' || Array.from(document.querySelectorAll([
        '[aria-busy="true"]',
        '[data-loading="true"]',
        '[data-testid*="skeleton" i]',
        '[data-testid*="loading" i]'
      ].join(','))).some(visible);
      return {
        authRequired: authRequired,
        authenticated: authenticated,
        hasCredentialForm: hasCredentialForm,
        hasAccountEvidence: hasAccountEvidence,
        isShelfContext: isShelfContext,
        isCompleteSnapshot:
          authenticated &&
          document.readyState !== 'loading' &&
          atScrollEnd &&
          !hasPendingWork &&
          pageInfo.publicState.isLastPage &&
          !pageInfo.publicState.blocked,
        atScrollEnd: atScrollEnd,
        hasPendingWork: hasPendingWork,
        pageFingerprint: Object.keys(found).sort().join('|'),
        pagination: pageInfo.publicState,
        account: account,
        accountIdentitySource: accountIdentitySource,
        books: books
      };
    })();
    """#

    static var sessionProbe: String {
        "window.__castreaderKoboProbeOnly = true;\n" + libraryScan
    }

    static var shelfSnapshot: String {
        "window.__castreaderKoboSnapshotOnly = true;\n" + libraryScan
    }

    static let advanceShelfPage = #"""
    (function () {
      return typeof window.__castreaderKoboShelfPageAction === 'function' &&
        window.__castreaderKoboShelfPageAction('next');
    })();
    """#

    static let resetShelfToFirstPage = #"""
    (function () {
      return typeof window.__castreaderKoboShelfPageAction === 'function' &&
        window.__castreaderKoboShelfPageAction('first');
    })();
    """#

#if DEBUG
    /// Synthetic shelf for repeatable simulator verification. No network,
    /// credentials or real book content. The native fixture uses an isolated
    /// store and a nonpersistent website profile.
    static let debugShelfFixture = #"""
    <!doctype html><html lang="en"><head>
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <style>
        body { font: 15px -apple-system, sans-serif; margin: 16px; color: #20252b; background: #f6f5f2; }
        header { background: #fff0d8; border-radius: 12px; padding: 12px; }
        header a { color: #684a17; }
        h1 { font-size: 21px; margin: 0 0 8px; }
        #shelf { display: grid; grid-template-columns: 1fr 1fr; gap: 8px; margin: 12px 0; }
        article { padding: 10px; min-height: 60px; border-radius: 10px; background: white; }
        h3 { font-size: 14px; margin: 0 0 4px; } article a { font-size: 12px; color: #666; }
        .book-author { font-size: 11px; color: #888; }
        nav { padding-bottom: 260px; display: flex; gap: 10px; flex-wrap: wrap; }
        nav a, nav button { padding: 10px; border: 1px solid #ccc; border-radius: 6px; }
        [aria-current="page"] { background: #ffce82; }
        #loading { background: #fff0d8; padding: 8px; }
      </style>
    </head><body>
      <header><h1>Kobo shelf · test fixture</h1>
        <div>4 pages · 20 cards per page · 77 unique books</div>
        <a href="/logout" data-email="synthetic-kobo@example.invalid">Synthetic account</a>
      </header>
      <p id="summary"></p><div id="loading" hidden>Loading next page (1.2 seconds)…</div>
      <main><section id="shelf"></section><nav aria-label="Pagination"></nav></main>
      <script>
        var fixturePage = 1;
        function render(page) {
          fixturePage = page;
          var cards = [];
          var start = 1 + (page - 1) * 19;
          for (var number = start; number < start + 20; number++) {
            var uuid = 'a0000000-0000-4000-8000-' + String(number).padStart(12, '0');
            cards.push('<article role="listitem"><h3 class="book-title">Synthetic Book ' + number +
              '</h3><div class="book-author">Test Author</div>' +
              '<a href="https://readnow.kobo.com/' + uuid + '">Read Now</a></article>');
          }
          document.querySelector('#shelf').innerHTML = cards.join('');
          document.querySelector('#summary').textContent = 'Page ' + page + ' of 4 · Books ' + start + '–' + (start + 19);
          var links = [];
          for (var p = 1; p <= 4; p++) links.push('<a href="?page=' + p + '"' +
            (p === page ? ' aria-current="page"' : '') + '>' + p + '</a>');
          links.push(page < 4 ? '<a rel="next" href="?page=' + (page + 1) + '">Next</a>' :
            '<button rel="next" disabled>Next</button>');
          document.querySelector('nav').innerHTML = links.join('');
          document.querySelector('main').removeAttribute('aria-busy');
          document.querySelector('#loading').hidden = true;
          window.scrollTo(0, 0);
        }
        document.addEventListener('click', function (event) {
          var link = event.target.closest('a');
          if (!link) return;
          event.preventDefault();
          if (!link.closest('nav') || document.querySelector('main').getAttribute('aria-busy') === 'true') return;
          var target = Number(new URL(link.href, document.baseURI).searchParams.get('page'));
          if (!(target >= 1 && target <= 4) || target === fixturePage) return;
          document.querySelector('main').setAttribute('aria-busy', 'true');
          document.querySelector('#loading').hidden = false;
          setTimeout(function () { render(target); }, 1200);
        });
        render(1);
      </script>
    </body></html>
    """#

    /// A second, independent fixture keeps the original 77-book regression
    /// intact while exercising Kobo's observed mobile library DOM at 100 books.
    /// All UUIDs, titles, authors, covers and the account email are synthetic;
    /// no readable book text or network resource is provided.
    static let debugHundredBookShelfFixture = #"""
    <!doctype html><html lang="zh-CN"><head>
      <meta name="viewport" content="width=device-width,initial-scale=1">
      <style>
        * { box-sizing: border-box; }
        body { margin: 0; background: #f6f5f2; color: #25272b; font: 14px -apple-system, sans-serif; }
        .fixture-banner { margin: 12px; padding: 14px; border: 1px solid #e9d9b7; border-radius: 12px; background: #fff6e4; }
        .fixture-banner h1 { font-size: 19px; margin: 0 0 7px; }
        .fixture-banner p { margin: 4px 0; color: #756347; line-height: 1.45; }
        .fixture-count { font-variant-numeric: tabular-nums; font-weight: 600; }
        main { padding: 0 12px 30px; }
        #library-grid > h2 { margin: 16px 0 10px; font-size: 22px; }
        .pagination-filter-container { display: flex; justify-content: flex-end; margin: 10px 0; }
        .pagination-controls.filter-chip { position: relative; display: flex; align-items: center; gap: 7px; }
        .filter-btn { border: 1px solid #c6c8cc; border-radius: 7px; background: white; padding: 8px 13px; }
        .filter-list { position: absolute; right: 0; top: 25px; z-index: 2; min-width: 105px; list-style: none; padding: 5px; background: white; border: 1px solid #ddd; border-radius: 7px; box-shadow: 0 3px 15px #0002; }
        .filter-item { display: block; padding: 8px; color: #5f6268; text-decoration: none; }
        .filter-item[aria-current="true"] { color: #b42f28; font-weight: 600; }
        .library-items { margin: 0; padding: 0; list-style: none; display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 11px; }
        .item-wrapper.book { min-width: 0; padding: 12px; border: 1px solid #e5e4df; background: white; border-radius: 10px; }
        .cover { width: 64px; height: 88px; display: block; margin-bottom: 9px; border-radius: 3px; box-shadow: 0 2px 5px #0002; }
        .title { font-size: 14px; line-height: 1.4; min-height: 40px; margin: 0 0 5px; overflow-wrap: anywhere; }
        .contributor { color: #777; font-size: 12px; line-height: 1.4; }
        .library-action { display: inline-block; margin-top: 9px; color: #b42f28; text-decoration: none; font-size: 12px; }
        nav.pagination { display: flex; gap: 7px; justify-content: center; flex-wrap: wrap; margin: 20px 0; }
        nav.pagination a, nav.pagination button { border: 1px solid #ccc; border-radius: 6px; padding: 10px 12px; background: white; color: #35383d; text-decoration: none; }
        nav.pagination [aria-current="page"] { border-color: #b42f28; color: white; background: #b42f28; }
        nav.pagination [disabled] { color: #aaa; background: #eee; }
        #fixture-loading { margin: 12px 0; padding: 10px; border-radius: 7px; background: #fff0cf; color: #795623; }
      </style>
    </head><body class="Store-Library">
      <header>
        <div class="nav-user-account collapsed" style="display:none">
          <a href="/sg/en/SignOut" data-email="hundred-kobo-fixture@example.invalid">Sign out</a>
          <a href="/sg/en/account">My Account</a>
        </div>
        <div class="fixture-banner">
          <h1>Kobo · 100 本跨页同步测试</h1>
          <p>4 页，每页 25 本。书目和封面均为合成测试数据，不含书籍正文。</p>
          <p id="fixture-summary" class="fixture-count"></p>
        </div>
      </header>
      <main>
        <div id="fixture-loading" hidden>正在加载下一页…</div>
        <section id="library-grid">
          <h2>My Books</h2>
          <div class="pagination-filter-container">
            <div class="pagination-controls filter-chip">Show:
              <button type="button" class="filter-btn" aria-expanded="false">25</button>
              <ul id="pagination-option" class="filter-list" hidden>
                <li><a class="filter-item" href="?pageSize=24" aria-label="Show: 24">24</a></li>
                <li><a class="filter-item" href="?pageSize=25" aria-label="Show: 25" aria-current="true">25</a></li>
                <li><a class="filter-item" href="?pageSize=36" aria-label="Show: 36">36</a></li>
                <li><a class="filter-item" href="?pageSize=48" aria-label="Show: 48">48</a></li>
                <li><a class="filter-item" href="?pageSize=60" aria-label="Show: 60">60</a></li>
              </ul>
            </div>
          </div>
          <section class="library-content book-list grid"><ul class="library-items"></ul></section>
        </section>
        <nav class="pagination" aria-label="Pagination"></nav>
      </main>
      <script>
        window.DynamicConfiguration = { user: {
          isLoggedIn: true, hasPreviouslyAuthenticated: true, inHomeStoreFront: true,
          homeStorefront: 'sg', currentStorefront: 'sg'
        } };
        var fixture = window.__castreaderKoboHundredFixture = {
          totalBooks: 100, pageSize: 25, totalPages: 4, currentPage: 1,
          requestedPage: null, pending: false, pageChangeCount: 0, renderedPages: [],
          transitionDelayMS: 1200, stallOnPage: null, includeBoundaryDuplicates: false
        };
        var transitionTimer = null;
        function bookUUID(number) {
          return 'b1000000-0000-4000-8000-' + String(number).padStart(12, '0');
        }
        function syntheticCover(number) {
          var dark = number % 2 === 0 ? '#285958' : '#644067';
          var pale = number % 2 === 0 ? '#c8e1d7' : '#f2d6b3';
          var svg = '<svg xmlns="http://www.w3.org/2000/svg" width="128" height="176" viewBox="0 0 128 176">' +
            '<rect width="128" height="176" fill="' + dark + '"/>' +
            '<rect x="13" y="15" width="102" height="146" fill="none" stroke="' + pale + '"/>' +
            '<circle cx="91" cy="126" r="36" fill="' + pale + '" opacity=".28"/>' +
            '<text x="25" y="48" fill="' + pale + '" font-family="sans-serif" font-size="12">TEST SHELF</text>' +
            '<text x="23" y="103" fill="white" font-family="sans-serif" font-size="38">' + String(number).padStart(3, '0') + '</text>' +
            '<text x="25" y="144" fill="' + pale + '" font-family="sans-serif" font-size="9">SYNTHETIC COVER</text></svg>';
          return 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(svg);
        }
        function renderPagination(page) {
          var links = [];
          links.push(page > 1 ? '<a rel="prev" href="?page=' + (page - 1) + '">Previous</a>' :
            '<button rel="prev" disabled>Previous</button>');
          for (var number = 1; number <= fixture.totalPages; number++) {
            links.push('<a href="?page=' + number + '" aria-label="Page ' + number + '"' +
              (number === page ? ' aria-current="page"' : '') + '>' + number + '</a>');
          }
          links.push(page < fixture.totalPages ? '<a rel="next" href="?page=' + (page + 1) + '">Next</a>' :
            '<button rel="next" disabled aria-disabled="true">Next</button>');
          document.querySelector('nav.pagination').innerHTML = links.join('');
        }
        function render(page) {
          if (transitionTimer !== null) clearTimeout(transitionTimer);
          transitionTimer = null;
          var first = (page - 1) * fixture.pageSize + 1;
          var last = page * fixture.pageSize;
          var numbers = [];
          // Optional overlap mode adds the preceding boundary card; the page
          // still contributes 25 new books and the full union remains 100.
          if (fixture.includeBoundaryDuplicates && page > 1) numbers.push(first - 1);
          for (var number = first; number <= last; number++) numbers.push(number);
          document.querySelector('.library-items').innerHTML = numbers.map(function (number) {
            var title = '合成测试书 ' + String(number).padStart(3, '0');
            var author = number % 2 === 0 ? 'Synthetic Author B' : 'Synthetic Author A';
            return '<li class="item-wrapper book">' +
              '<img class="cover" alt="' + title + '" src="' + syntheticCover(number) + '">' +
              '<h3 class="title">' + title + '</h3><div class="contributor">' + author + '</div>' +
              '<a class="library-action" data-web-reader-entrypoint="true" data-book-title="' + title +
              '" data-contributors="' + author + '" href="https://readnow.kobo.com/' + bookUUID(number) + '">Read now</a></li>';
          }).join('');
          fixture.currentPage = page;
          fixture.requestedPage = null;
          fixture.pending = false;
          fixture.renderedPages.push(page);
          fixture.renderedBookUUIDs = numbers.map(bookUUID);
          renderPagination(page);
          document.querySelector('#fixture-summary').textContent = '第 ' + page + ' / 4 页 · 书目 ' + first + '–' + last +
            (fixture.includeBoundaryDuplicates && page > 1 ? ' · 含 1 张重复边界卡片' : '') + ' · 总计 100 本';
          document.querySelector('main').removeAttribute('aria-busy');
          document.querySelector('#fixture-loading').hidden = true;
          window.scrollTo(0, 0);
        }
        function requestPage(page) {
          if (fixture.pending || !(page >= 1 && page <= fixture.totalPages) || page === fixture.currentPage) return false;
          fixture.pending = true;
          fixture.requestedPage = page;
          fixture.pageChangeCount += 1;
          document.querySelector('main').setAttribute('aria-busy', 'true');
          document.querySelector('#fixture-loading').hidden = false;
          // Model the observed transition race: the page control changes
          // before the old cards are replaced. aria-busy owns that interval.
          renderPagination(page);
          if (fixture.stallOnPage !== page) {
            transitionTimer = setTimeout(function () { render(page); }, Math.max(0, fixture.transitionDelayMS));
          }
          return true;
        }
        fixture.finishPendingPage = function () {
          if (fixture.pending) render(fixture.requestedPage);
        };
        fixture.requestPage = requestPage;
        document.addEventListener('click', function (event) {
          var node = event.target.closest('a,button');
          if (!node) return;
          // Synthetic books are metadata fixtures, never reader destinations.
          event.preventDefault();
          if (node.closest('.pagination-filter-container')) {
            var menu = document.querySelector('#pagination-option');
            menu.hidden = node.classList.contains('filter-btn') ? !menu.hidden : true;
            document.querySelector('.filter-btn').setAttribute('aria-expanded', String(!menu.hidden));
            return;
          }
          if (!node.closest('nav.pagination') || node.disabled) return;
          var page = Number(new URL(node.href, document.baseURI).searchParams.get('page'));
          requestPage(page);
        });
        render(1);
      </script>
    </body></html>
    """#
#endif

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
