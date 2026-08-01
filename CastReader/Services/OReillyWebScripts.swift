//
//  OReillyWebScripts.swift
//  CastReader
//
//  O'Reilly Learning binding and History scanning. Authentication always
//  stays inside the app-owned persistent WebKit profile. Institution access
//  is intentionally allowed to traverse arbitrary HTTPS identity providers,
//  while native code accepts shelf data only from a proven O'Reilly
//  History/Profile origin.
//

import Foundation

enum OReillyWebScripts {
    private static let peninsulaLoginHost =
        "login.ezproxy.plsinfo.org"
    private static let peninsulaReaderHost =
        "learning-oreilly-com.ezproxy.plsinfo.org"

    static let directHomeURL =
        URL(string: "https://learning.oreilly.com/home/")!
    static let directHistoryURL =
        URL(string: "https://learning.oreilly.com/history/")!
    static let institutionAccessURL =
        URL(string: "https://www.oreilly.com/library-access/")!
    /// Peninsula Library System is not listed in O'Reilly's public
    /// institution picker. Its licensed access is exposed through this
    /// library-owned EZproxy route instead.
    static let peninsulaLibrarySystemAccessURL = URL(
        string:
            "https://login.ezproxy.plsinfo.org/login?" +
            "qurl=https%3A%2F%2Fwww.oreilly.com%2Flibrary%2Fview%2F" +
            "temporary-access%2F"
    )!

    /// Validates a library-provided O'Reilly entry link before presenting it
    /// inside the trusted binding UI. The visible authentication flow may
    /// subsequently traverse HTTPS IdPs, but the initial pasted link must be
    /// either O'Reilly itself or an explicitly reviewed institutional route.
    /// New direct EZproxy providers must be added here deliberately; accepting
    /// any host containing "ezproxy" would permit look-alike login pages.
    static func institutionEntryURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let url = URL(string: trimmed),
              allowsInstitutionEntryURL(url) else {
            return nil
        }
        return url
    }

    static func allowsInstitutionEntryURL(_ url: URL?) -> Bool {
        guard let components = strictHTTPSComponents(url),
              let host = components.host?.lowercased() else {
            return false
        }

        if host == "www.oreilly.com" {
            let path = normalizedPath(components.path)
            return path == "/library-access"
                || path.hasPrefix("/library/view/temporary-access")
        }

        if host == OReillyBookValidator.directReaderHost
            || host == peninsulaReaderHost {
            return true
        }

        guard host == peninsulaLoginHost else {
            return false
        }

        return (components.queryItems ?? []).contains { item in
            guard let value = item.value,
                  let target = URL(string: value),
                  let targetComponents = strictHTTPSComponents(target),
                  let targetHost =
                    targetComponents.host?.lowercased() else {
                return false
            }
            let targetPath = normalizedPath(targetComponents.path)
            return (targetHost == "www.oreilly.com"
                    || targetHost == "learning.oreilly.com")
                && targetPath.hasPrefix("/library/")
        }
    }

    static func isShelfURL(_ url: URL?) -> Bool {
        OReillyWebAccessPolicy.allowsShelfURL(url)
    }

    static func historyURL(for url: URL?) -> URL? {
        guard let host = url?.host?.lowercased(),
              OReillyWebAccessPolicy.isAllowedReaderHost(host) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/history/"
        return components.url
    }

    static func homeURL(for url: URL?) -> URL? {
        guard let host = url?.host?.lowercased(),
              OReillyWebAccessPolicy.isAllowedReaderHost(host) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/home/"
        return components.url
    }

    /// Institution access may cross the library's discovery service, EZproxy,
    /// SAML and the institution IdP. Those hosts cannot be enumerated in the
    /// app. This policy is deliberately broad for visible main-frame auth
    /// navigation only; no result from those pages is accepted as shelf data.
    static func allowsBindingNavigation(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.absoluteString == "about:blank" {
            return true
        }
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return false
        }
        return components.scheme?.lowercased() == "https"
            && components.host != nil
            && components.user == nil
            && components.password == nil
            && (components.port == nil || components.port == 443)
    }

    static func isLikelyCredentialURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        if isShelfURL(url) {
            return false
        }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return path.contains("login")
            || path.contains("signin")
            || path.contains("sign-in")
            || path.contains("authorize")
            || path.contains("saml")
            || path.contains("oauth")
            || path.contains("library-access")
            || host.contains("auth0")
            || host.contains("okta")
            || host.contains("onelogin")
            || host.contains("shibboleth")
            || (
                host.contains("ezproxy")
                    && !OReillyWebAccessPolicy.isAllowedReaderHost(host)
            )
    }

    private static func strictHTTPSComponents(
        _ url: URL?
    ) -> URLComponents? {
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

    private static func normalizedPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return "/" + trimmed.lowercased()
    }

    /// The native bottom card must not cover usernames, passwords, passkeys or
    /// MFA. URL heuristics are supplemented with this rendered-DOM check.
    static let credentialPageProbe = #"""
    (function () {
      function visible(node) {
        if (!node) return false;
        var style = window.getComputedStyle(node);
        if (style.display === 'none' ||
            style.visibility === 'hidden' ||
            Number(style.opacity || 1) === 0) return false;
        var rect = node.getBoundingClientRect();
        return rect.width > 1 && rect.height > 1;
      }
      var inputs = Array.prototype.slice.call(document.querySelectorAll([
        'input[type="password"]',
        'input[autocomplete="current-password"]',
        'input[autocomplete="username"]',
        'input[type="email"]'
      ].join(',')));
      if (inputs.some(visible)) return true;
      var forms = Array.prototype.slice.call(document.querySelectorAll('form'));
      return forms.some(function (form) {
        if (!visible(form)) return false;
        var hint = [
          form.getAttribute('action') || '',
          form.getAttribute('id') || '',
          form.getAttribute('name') || '',
          form.getAttribute('aria-label') || '',
          form.textContent || ''
        ].join(' ').toLowerCase();
        return /(sign[ -]?in|log[ -]?in|password|passkey|verification|library card)/i
          .test(hint);
      });
    })();
    """#

    /// A changed SPA URL is not enough to prove that O'Reilly has opened the
    /// book. Wait for the actual reader root before leaving the page so the
    /// site's History event has time to be recorded.
    static let readerReadyProbe = #"""
    (function () {
      if (document.readyState !== 'complete') return false;
      var root = document.querySelector('#sbo-rt-content');
      if (!root) return false;
      var text = String(root.textContent || '')
        .replace(/\s+/g, ' ')
        .trim();
      return text.length >= 2;
    })();
    """#

    static let sessionProbe = scanScript(advanceShelf: false)
    static let libraryScan = scanScript(advanceShelf: true)

    /// Remove only O'Reilly's duplicate floating audio control from the
    /// reading surface. Account, cookie and navigation controls remain owned
    /// by the site; CastReader's playback bar is native and outside this DOM.
    static let readerShellPrelude = #"""
    (function () {
      if (window.__castreaderOReillyShell) return;
      window.__castreaderOReillyShell = true;
      var style = document.createElement('style');
      style.textContent = [
        'button[aria-label^="Listen" i], [data-testid*="listen-button" i] { display:none !important; }',
        'a[href*="apps.apple.com"], a[href*="itunes.apple.com"] { display:none !important; }'
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

    private static func scanScript(advanceShelf: Bool) -> String {
        let shouldAdvance = advanceShelf ? "true" : "false"
        return #"""
        (function () {
          var shouldAdvance = \#(shouldAdvance);
          function clean(value) {
            return String(value || '')
              .replace(/\u00a0/g, ' ')
              .replace(/\s+/g, ' ')
              .trim();
          }
          function visible(node) {
            if (!node) return false;
            var style = window.getComputedStyle(node);
            if (style.display === 'none' ||
                style.visibility === 'hidden' ||
                Number(style.opacity || 1) === 0) return false;
            var rect = node.getBoundingClientRect();
            return rect.width > 1 && rect.height > 1;
          }
          function absolute(raw) {
            try {
              return new URL(String(raw || ''), location.href).href;
            } catch (_) {
              return '';
            }
          }
          function readerParts(raw) {
            try {
              var url = new URL(String(raw || ''), location.href);
              var parts = url.pathname.split('/').filter(Boolean);
              if (parts.length < 4 ||
                  String(parts[0]).toLowerCase() !== 'library' ||
                  String(parts[1]).toLowerCase() !== 'view') return null;
              var id = clean(parts[3]).toLowerCase();
              if (!/^[a-z0-9._:-]{6,64}$/.test(id)) return null;
              return { id: id, href: url.href };
            } catch (_) {
              return null;
            }
          }
          function bestText(node, selectors) {
            if (!node) return '';
            for (var i = 0; i < selectors.length; i += 1) {
              var candidate = node.querySelector(selectors[i]);
              var value = clean(
                candidate && (
                  candidate.getAttribute('aria-label') ||
                  candidate.getAttribute('title') ||
                  candidate.textContent
                )
              );
              if (value) return value;
            }
            return '';
          }
          function stripAction(value) {
            return clean(value).replace(
              /^(?:continue(?:\s+reading)?|read(?:\s+now)?|open(?:\s+book)?|resume(?:\s+reading)?|start(?:\s+reading)?)\s*[:\-–—]\s*/i,
              ''
            );
          }
          function coverFrom(card) {
            if (!card) return '';
            var images = card.querySelectorAll('img');
            for (var i = 0; i < images.length; i += 1) {
              var image = images[i];
              var raw =
                image.currentSrc ||
                image.getAttribute('src') ||
                image.getAttribute('data-src') ||
                '';
              if (!raw && image.getAttribute('srcset')) {
                raw = image.getAttribute('srcset').split(',')[0].trim().split(/\s+/)[0];
              }
              var lower = String(raw).toLowerCase();
              if (raw &&
                  lower.indexOf('data:') !== 0 &&
                  lower.indexOf('blob:') !== 0 &&
                  lower.indexOf('transparent') < 0 &&
                  lower.indexOf('spacer') < 0 &&
                  lower.indexOf('pixel') < 0) {
                return absolute(raw);
              }
            }
            return '';
          }
          function labelledText(card, expression) {
            if (!card) return '';
            var nodes = card.querySelectorAll('p,span,div,small');
            for (var i = 0; i < nodes.length; i += 1) {
              var value = clean(nodes[i].textContent);
              if (value.length <= 240 && expression.test(value)) return value;
            }
            return '';
          }
          function embeddedString(key) {
            var escaped = String(key || '').replace(
              /[.*+?^${}()|[\]\\]/g,
              '\\$&'
            );
            var expression = new RegExp(
              "[\"']" + escaped +
                "[\"']\\s*:\\s*[\"']([^\"']{1,200})[\"']",
              'i'
            );
            var scripts = document.scripts || [];
            for (var i = 0; i < scripts.length; i += 1) {
              var text = String(scripts[i].textContent || '');
              var match = text.match(expression);
              if (match) return clean(match[1]);
            }
            return '';
          }
          function safeOpaqueIdentity(value) {
            var candidate = clean(value).toLowerCase();
            return /^[a-z0-9._:-]{6,128}$/.test(candidate)
              ? candidate
              : '';
          }
          function sectionForHeading(expression) {
            var headings = document.querySelectorAll('h1,h2,h3,h4');
            for (var i = 0; i < headings.length; i += 1) {
              if (!expression.test(clean(headings[i].textContent))) continue;
              return headings[i].closest(
                'section,[data-testid*="section" i],[role="region"]'
              ) || headings[i].parentElement;
            }
            return null;
          }
          function isLoading(root) {
            if (!root) return true;
            var candidates = root.querySelectorAll([
              '[aria-busy="true"]',
              '[role="progressbar"]',
              '[data-testid*="loading" i]',
              '[class~="loading" i]',
              '[class*="spinner" i]'
            ].join(','));
            for (var i = 0; i < candidates.length; i += 1) {
              if (visible(candidates[i])) return true;
            }
            var text = clean(root.textContent);
            return /^(?:loading|loading your history|please wait)[.…]*$/i.test(text);
          }

          var host = String(location.hostname || '').toLowerCase();
          var path = String(location.pathname || '')
            .replace(/\/+$/, '')
            .toLowerCase();
          var isShelfContext =
            path === '/history' || path === '/profile';
          var historyHeading = sectionForHeading(
            /^(?:your\s+)?(?:reading\s+)?history$/i
          );
          var historyRoot = path === '/history'
            ? (
                (historyHeading && historyHeading.closest('main')) ||
                document.querySelector('main') ||
                document.body
              )
            : (
                document.querySelector('section[data-testid="History"]') ||
                historyHeading
              );
          var playlistRoot = path === '/profile'
            ? (
                document.querySelector('section[data-testid="Playlists"]') ||
                sectionForHeading(/^(?:your\s+)?playlists$/i)
              )
            : null;
          var scanRoots = [];
          if (historyRoot) scanRoots.push(historyRoot);
          if (playlistRoot && playlistRoot !== historyRoot) {
            scanRoots.push(playlistRoot);
          }

          var passwordInput = Array.prototype.slice.call(
            document.querySelectorAll(
              'input[type="password"],input[autocomplete="current-password"]'
            )
          ).some(visible);
          var signInNode = document.querySelector([
            'a[href*="/member/login" i]',
            'a[href*="/login" i]',
            'a[href*="/signin" i]',
            'button[data-testid*="sign-in" i]',
            'button[aria-label*="sign in" i]'
          ].join(','));
          var signInVisible = visible(signInNode);
          var logoutNode = document.querySelector(
            'a[href*="/logout" i],button[data-testid*="logout" i]'
          );
          var profileNode = document.querySelector([
            'a[href="/profile/"]',
            'a[href*="/profile/" i]',
            '[data-testid*="profile" i]',
            '[aria-label*="profile" i]'
          ].join(','));
          var profileHeading = path === '/profile'
            ? Array.prototype.slice.call(
                document.querySelectorAll('main h1,main h2')
              ).map(function (node) {
                return clean(node.textContent);
              }).find(function (value) {
                return value &&
                  !/^(?:profile|your history|your playlists|your highlights)$/i.test(value);
              })
            : '';
          // O'Reilly emits a stable, opaque learner UUID and primary-account
          // UUID into its rendered analytics bootstrap. They are account
          // evidence, not credentials. Hash them immediately on the native
          // side; never fall back to hostname because two personal accounts
          // share learning.oreilly.com and two library patrons can share one
          // EZproxy host.
          var learnerID = safeOpaqueIdentity(
            embeddedString('user_identifier')
          );
          var primaryAccountID = safeOpaqueIdentity(
            embeddedString('primary_account')
          );
          var organizationName = clean(
            embeddedString('organization_name')
          );
          var accountRaw = clean(
            (profileNode && (
              profileNode.getAttribute('data-email') ||
              profileNode.getAttribute('aria-label') ||
              profileNode.getAttribute('title') ||
              profileNode.textContent
            )) ||
            profileHeading ||
            ''
          );
          if (/^(?:profile|account|my account)$/i.test(accountRaw)) {
            accountRaw = '';
          }
          if (accountRaw.length > 160) accountRaw = '';

          var explicitEmpty = !!(
            historyRoot &&
            /(?:no (?:reading )?history|history is empty|no (?:history )?items|no recent activity|nothing (?:here|to show)|haven['’]?t (?:read|viewed|started))/i
              .test(clean(historyRoot.textContent))
          );
          var hasHistorySurface =
            !!historyRoot &&
            (
              !!historyHeading ||
              !!historyRoot.querySelector(
                'article[data-testid^="urn:orm:book:"],a[href*="/library/view/"]'
              ) ||
              explicitEmpty
            );
          var authRequired =
            !isShelfContext ||
            passwordInput ||
            !hasHistorySurface ||
            (signInVisible && !logoutNode);
          var hasAccountEvidence =
            isShelfContext &&
            !authRequired &&
            (
              !!logoutNode ||
              !!profileNode ||
              hasHistorySurface
            );
          var authenticated =
            hasAccountEvidence && isShelfContext && !authRequired;
          var identitySource = learnerID
            ? ('learner:' + learnerID +
              (primaryAccountID ? ':account:' + primaryAccountID : ''))
            : (profileHeading ? 'profile:' + profileHeading : '');
          var accountLabel = accountRaw || organizationName || profileHeading ||
            (authenticated ? "O'Reilly Learning" : '');

          var found = {};
          function mergeBook(next) {
            var old = found[next.contentID];
            if (!old) {
              found[next.contentID] = next;
              return;
            }
            if (next.title.length > old.title.length) old.title = next.title;
            if (!old.author && next.author) old.author = next.author;
            if (!old.coverURL && next.coverURL) old.coverURL = next.coverURL;
            if (!old.progressLabel && next.progressLabel) {
              old.progressLabel = next.progressLabel;
            }
            if (!old.resumeURL && next.resumeURL) old.resumeURL = next.resumeURL;
          }
          scanRoots.forEach(function (root) {
            var links = root.querySelectorAll('a[href*="/library/view/"]');
            for (var i = 0; i < links.length; i += 1) {
              var link = links[i];
              var parts = readerParts(link.href || link.getAttribute('href'));
              if (!parts) continue;
              var card = link.closest(
                'article,[role="listitem"],li,[data-testid^="urn:orm:book:"]'
              ) || link.parentElement;
              if (!card) continue;
              var cardTestID = clean(card.getAttribute('data-testid'));
              // History can also contain courses, videos and events. Only a
              // first-party `urn:orm:book:` card is a readable long-form book.
              // Requiring the content ID to agree with the reader URL also
              // prevents a nested cross-card link from being misattributed.
              if (cardTestID.toLowerCase().indexOf('urn:orm:book:') !== 0 ||
                  cardTestID.slice('urn:orm:book:'.length).toLowerCase() !==
                    parts.id) {
                continue;
              }
              var title = stripAction(bestText(card, [
                'h1 a[href*="/library/view/"]',
                'h2 a[href*="/library/view/"]',
                'h3 a[href*="/library/view/"]',
                'h4 a[href*="/library/view/"]',
                '[data-testid*="title" i]',
                'a[href*="/library/view/"]'
              ]));
              if (!title) {
                title = stripAction(
                  link.getAttribute('aria-label') ||
                  link.getAttribute('title') ||
                  link.textContent
                );
              }
              if (!title ||
                  /^(?:book cover|cover|read|continue|more)$/i.test(title)) {
                continue;
              }
              var author = labelledText(card, /^by\s+.+/i)
                .replace(/^by\s+/i, '');
              var progress = labelledText(
                card,
                /\b(?:100|[0-9]{1,2})%\s*progress\b/i
              );
              var resume = '';
              var candidateLinks = card.querySelectorAll(
                'a[href*="/library/view/"]'
              );
              for (var j = 0; j < candidateLinks.length; j += 1) {
                var candidate = readerParts(
                  candidateLinks[j].href ||
                  candidateLinks[j].getAttribute('href')
                );
                if (!candidate || candidate.id !== parts.id) continue;
                var hint = clean(
                  candidateLinks[j].getAttribute('aria-label') ||
                  candidateLinks[j].textContent
                );
                if (/continue|resume/i.test(hint) ||
                    /\/continue\/?$/i.test(candidate.href)) {
                  resume = candidate.href;
                  break;
                }
              }
              mergeBook({
                contentKind: 'book',
                contentID: parts.id,
                title: title,
                author: author,
                coverURL: coverFrom(card),
                readerURL: parts.href,
                resumeURL: resume,
                progressLabel: progress
              });
            }
          });

          var books = Object.keys(found).map(function (key) {
            return found[key];
          });
          var rootLoading =
            !historyRoot ||
            isLoading(historyRoot);
          var pageReady =
            document.readyState === 'complete' &&
            authenticated &&
            hasHistorySurface &&
            !rootLoading;
          var scrolling = document.scrollingElement || document.documentElement;
          var viewportBottom =
            Number(scrolling.scrollTop || window.pageYOffset || 0) +
            Number(window.innerHeight || document.documentElement.clientHeight || 0);
          var scrollHeight = Number(
            scrolling.scrollHeight || document.documentElement.scrollHeight || 0
          );
          var reachedEnd =
            scrollHeight <= 0 || viewportBottom >= scrollHeight - 32;
          if (shouldAdvance && pageReady && !reachedEnd) {
            window.scrollTo({
              top: Math.min(
                scrollHeight,
                Number(scrolling.scrollTop || window.pageYOffset || 0) +
                  Math.max(420, Number(window.innerHeight || 700) * 0.82)
              ),
              behavior: 'auto'
            });
          }

          var signature = [
            books.length,
            books.map(function (book) {
              return book.contentID + ':' + book.title;
            }).join('|'),
            scrollHeight
          ].join('::');
          if (window.__castReaderOReillyShelfSignature === signature) {
            window.__castReaderOReillyShelfStable =
              Number(window.__castReaderOReillyShelfStable || 0) + 1;
          } else {
            window.__castReaderOReillyShelfSignature = signature;
            window.__castReaderOReillyShelfStable = 1;
          }
          var localStable = Number(
            window.__castReaderOReillyShelfStable || 0
          );
          var isCompleteSnapshot =
            pageReady &&
            reachedEnd &&
            (books.length > 0 || explicitEmpty) &&
            localStable >= (books.length === 0 ? 3 : 1);

          return {
            authRequired: authRequired,
            authenticated: authenticated,
            hasAccountEvidence: hasAccountEvidence,
            isShelfContext: isShelfContext,
            isCompleteSnapshot: isCompleteSnapshot,
            account: accountLabel || null,
            accountIdentitySource: identitySource,
            books: books
          };
        })();
        """#
    }
}
