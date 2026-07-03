//
//  KindleWebScripts.swift
//  CastReader
//
//  JavaScript helpers for read.amazon.com. Keep selectors broad because Amazon
//  changes Cloud Reader markup often.
//

import Foundation

enum KindleWebScripts {
    static let libraryURL = URL(string: "https://read.amazon.com/kindle-library")!

    static let scrapeLibrary = """
    (function() {
      function text(el) { return (el && (el.innerText || el.textContent) || '').replace(/\\s+/g, ' ').trim(); }
      function attr(el, name) { try { return el ? (el.getAttribute(name) || '') : ''; } catch (e) { return ''; } }
      function abs(url) {
        if (!url) return '';
        try { return new URL(url, location.href).href; } catch (e) { return url || ''; }
      }
      function bgURL(el) {
        try {
          var bg = getComputedStyle(el).backgroundImage || '';
          var m = bg.match(/url\\(["']?([^"')]+)["']?\\)/);
          return m ? abs(m[1]) : '';
        } catch (e) { return ''; }
      }
      function visible(el) {
        if (!el) return false;
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 4 && rect.height > 4;
        } catch (e) {
          return false;
        }
      }
      function asinFrom(raw) {
        raw = String(raw || '');
        var patterns = [
          /^([A-Z0-9]{10})$/i,
          /\\b(B[0-9A-Z]{9})\\b/i,
          /[?&]asin=([A-Z0-9]{10})/i,
          /\\/([A-Z0-9]{10})(?:[/?#]|$)/i,
          /asin[:=\\s-]+([A-Z0-9]{10})/i
        ];
        for (var i = 0; i < patterns.length; i++) {
          var m = raw.match(patterns[i]);
          if (m) return m[1].toUpperCase();
        }
        return '';
      }
      function nodeSignature(node) {
        var chunks = [];
        var cur = node;
        for (var depth = 0; cur && depth < 5; depth++, cur = cur.parentElement) {
          try {
            chunks.push(cur.id || '', cur.className || '', cur.getAttribute('data-asin') || '', cur.getAttribute('data-id') || '', cur.getAttribute('data-key') || '', cur.getAttribute('aria-label') || '');
            Array.from(cur.attributes || []).slice(0, 24).forEach(function(attr) {
              chunks.push(attr.name || '', attr.value || '');
            });
          } catch (e) {}
        }
        try { chunks.push(String((node && node.outerHTML) || '').slice(0, 6000)); } catch (e) {}
        return chunks.join(' ');
      }
      function isReaderHref(href) {
        href = abs(href);
        if (!href) return false;
        try {
          var u = new URL(href, location.href);
          var path = (u.pathname || '').toLowerCase();
          if (!/read\\.amazon\\./i.test(u.host || '')) return false;
          if (/kindle-library|landing|help|support|settings|notebook|privacy|terms|download|appstore|app-store/.test(path)) return false;
          return !!u.search.match(/[?&]asin=[A-Z0-9]{10}/i) || /\\/reader\\//i.test(path);
        } catch (e) {
          return /[?&]asin=[A-Z0-9]{10}/i.test(href) || /\\/reader\\//i.test(href);
        }
      }
      function badTitle(raw) {
        var v = String(raw || '').toLowerCase();
        return /download|app store|kindle app|learn more|read on any device|help|support|settings|notebook|privacy|terms|下载|应用商店|了解更多|任何设备|帮助|支持|设置|笔记/.test(v);
      }
      function nearestCard(a) {
        var node = a;
        for (var depth = 0; node && depth < 8; depth++, node = node.parentElement) {
          var label = [node.getAttribute('role'), node.getAttribute('class'), node.getAttribute('data-asin'), node.getAttribute('aria-label')]
            .filter(Boolean).join(' ').toLowerCase();
          var t = text(node);
          if (node.getAttribute('data-asin')) return node;
          if (/listitem|book|library|cover|asin|title|item|card/.test(label) && t.length > 2 && node.querySelector('img')) return node;
          if (node.tagName === 'LI' && t.length > 2) return node;
          if (node.querySelector && node.querySelector('img') && t.length > 8 && depth >= 2) return node;
        }
        return a.parentElement || a;
      }
      function titleFrom(card, a, img) {
        var labelled = attr(card, 'aria-label') || attr(a, 'aria-label') || attr(img, 'alt') || '';
        var selectors = [
          '[data-testid*=title]', '[class*=title]', '[class*=Title]', '[id*=title]',
          'h1', 'h2', 'h3', 'h4', '[role=heading]'
        ];
        for (var i = 0; i < selectors.length; i++) {
          try {
            var el = card.querySelector(selectors[i]);
            var v = text(el);
            if (v && v.length < 180) return v;
          } catch (e) {}
        }
        if (labelled) return labelled.replace(/Kindle Edition|ebook|book/ig, '').trim();
        var raw = text(card).split(/\\n|\\u2022|\\|/)[0] || text(a);
        return raw.slice(0, 160).trim();
      }
      function authorFrom(card, title) {
        var selectors = ['[class*=author]', '[class*=Author]', '[data-testid*=author]'];
        for (var i = 0; i < selectors.length; i++) {
          try {
            var v = text(card.querySelector(selectors[i]));
            if (v && v !== title && v.length < 120) return v.replace(/^by\\s+/i, '').trim();
          } catch (e) {}
        }
        var lines = text(card).split(/\\n|\\u2022|\\|/).map(function(s) { return s.trim(); }).filter(Boolean);
        for (var j = 0; j < lines.length; j++) {
          var line = lines[j];
          if (line === title) continue;
          if (/^by\\s+/i.test(line)) return line.replace(/^by\\s+/i, '').trim();
        }
        return '';
            }
            function progressFrom(card) {
              var raw = text(card);
              var m = raw.match(/(\\d{1,3}\\s*%|Page\\s+\\d+[^\\n,;]*|Location\\s+\\d+[^\\n,;]*|Last\\s+read[^\\n,;]*)/i);
              return m ? m[1].replace(/\\s+/g, ' ').trim() : '';
            }
            function accountInfo() {
              var email = '';
              var label = '';
              try {
                var body = text(document.body || document.documentElement);
                var emailMatch = body.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}/i);
                if (emailMatch) email = emailMatch[0];
              } catch (e) {}
              var selectors = [
                '#nav-link-accountList-nav-line-1',
                '#nav-link-accountList .nav-line-1',
                '[data-nav-role=signin] .nav-line-1',
                '[aria-label*=Account]',
                '[aria-label*=account]',
                '[href*=account] span',
                '[href*=your-account] span'
              ];
              for (var i = 0; i < selectors.length && !label; i++) {
                try {
                  var el = document.querySelector(selectors[i]);
                  var v = text(el).replace(/^Hello,?\\s*/i, '').replace(/^Hi,?\\s*/i, '').trim();
                  if (v && !/sign\\s*in|account|lists?|returns?|orders?/i.test(v) && v.length < 80) label = v;
                } catch (e) {}
              }
              return { label: label, email: email };
            }
            function candidateLinks() {
              var links = Array.from(document.querySelectorAll('a[href*="asin="], a[href*="/reader/"]'));
        var hits = links.filter(function(a) {
          var href = attr(a, 'href');
          return isReaderHref(href) || !!asinFrom(href) || !!attr(a, 'data-asin');
        });
        Array.from(document.querySelectorAll('[data-asin]')).forEach(function(card) {
          var label = (attr(card, 'data-asin') + ' ' + attr(card, 'aria-label') + ' ' + attr(card, 'class')).toLowerCase();
          if (!asinFrom(label) && !attr(card, 'data-asin')) return;
          var link = card.querySelector('a[href]');
          hits.push(link || card);
        });
        Array.from(document.querySelectorAll('img')).forEach(function(img) {
          if (!visible(img)) return;
          var rect = img.getBoundingClientRect();
          if (rect.width < 42 || rect.height < 58) return;
          var card = nearestCard(img);
          var link = card.querySelector && card.querySelector('a[href*="asin="], a[href*="/reader/"]');
          var signature = nodeSignature(card) + ' ' + attr(img, 'src') + ' ' + attr(img, 'alt');
          if (!asinFrom(signature) && !(link && isReaderHref(attr(link, 'href')))) return;
          hits.push(link || card);
        });
        return hits;
      }
      var seen = {};
      var books = [];
      candidateLinks().forEach(function(a) {
        var href = abs(attr(a, 'href'));
        var card = nearestCard(a);
        var img = card.querySelector('img') || a.querySelector('img');
        var asin = attr(card, 'data-asin') || attr(a, 'data-asin') || asinFrom(href) || asinFrom(nodeSignature(card)) || asinFrom(text(card));
        if (!href && asin) href = 'https://read.amazon.com/?asin=' + encodeURIComponent(asin);
        var title = titleFrom(card, a, img);
        if (!title || title.length < 2) return;
        if (badTitle(title) || badTitle(text(a))) return;
        if (!asinFrom(asin) && !asinFrom(href) && !isReaderHref(href)) return;
        if (href && !isReaderHref(href) && !asinFrom(href)) return;
        var id = asin || href || title;
        if (!id || seen[id]) return;
        seen[id] = true;
        var cover = attr(img, 'src') || attr(img, 'data-src') || attr(img, 'srcset').split(' ')[0] || bgURL(card);
        books.push({
          id: id,
          asin: asin,
          title: title,
          author: authorFrom(card, title),
          coverURL: cover ? abs(cover) : '',
          readerURL: href,
          progressLabel: progressFrom(card)
        });
      });
      var signin = Array.from(document.querySelectorAll('input[type=email], input[name=email], input[type=password], #ap_email, #ap_password')).some(visible);
      var hasReaderSignals = books.length > 0 || candidateLinks().length > 0;
            var readerPage = /[?&]asin=[A-Z0-9]{10}/i.test(location.search) || /\\/reader\\//i.test(location.pathname);
            return JSON.stringify({
              ok: true,
              loggedIn: books.length > 0,
              authRequired: signin,
              hasReaderSignals: hasReaderSignals,
              isReaderPage: readerPage,
              account: accountInfo(),
              url: location.href,
              title: document.title || '',
              count: books.length,
        books: books.slice(0, 120)
      });
    })();
    """

    static let currentPageState = """
    (function() {
      function text(el) { return (el && (el.innerText || el.textContent) || '').replace(/\\s+/g, ' ').trim(); }
      function asinFrom(raw) {
        raw = String(raw || '');
        var patterns = [
          /^([A-Z0-9]{10})$/i,
          /\\b(B[0-9A-Z]{9})\\b/i,
          /[?&]asin=([A-Z0-9]{10})/i,
          /\\/([A-Z0-9]{10})(?:[/?#]|$)/i
        ];
        for (var i = 0; i < patterns.length; i++) {
          var m = raw.match(patterns[i]);
          if (m) return m[1].toUpperCase();
        }
        return '';
      }
      var asin = asinFrom(location.href);
      var isReaderPage = /[?&]asin=[A-Z0-9]{10}/i.test(location.search) || /\\/reader\\//i.test(location.pathname);
      var title = text(document.querySelector('[data-testid*=title], [class*=Title], [class*=title], h1, h2, [role=heading]')) || document.title || 'Kindle';
      title = title.replace(/Kindle Cloud Reader|Amazon Kindle/ig, '').replace(/\\s+/g, ' ').trim() || 'Kindle';
      return JSON.stringify({
        ok: true,
        url: location.href,
        title: title,
        asin: asin,
        isReaderPage: isReaderPage
      });
    })();
    """

    static let pageCaptureBootstrap = """
    (function() {
      if (window.__crKindleInstalled) return;
      window.__crKindleInstalled = true;
      window.__crKindleProbe = window.__crKindleProbe || {
        idx: 0,
        candidateSeq: 0,
        urlToKey: new Map(),
        keyToLiveUrl: new Map(),
        keyToLiveImg: new Map(),
        liveSessionId: 0,
        liveCandidate: null,
        liveState: null,
        liveImagePixelSize: null
      };
      var originalCreate = URL.createObjectURL.bind(URL);
      function liveImageFor(key, url) {
        if (!key || !url) return null;
        var img = window.__crKindleProbe.keyToLiveImg.get(key);
        if (!img || img.src !== url) {
          img = new Image();
          try { img.decoding = 'async'; } catch (e) {}
          img.src = url;
          window.__crKindleProbe.keyToLiveImg.set(key, img);
        }
        return img;
      }
      async function contentKey(blob) {
        try {
          var size = blob.size || 0;
          var head = await blob.slice(0, 256).arrayBuffer();
          var buf = new ArrayBuffer(8 + head.byteLength);
          var view = new DataView(buf);
          view.setUint32(0, Math.floor(size / 0x100000000), false);
          view.setUint32(4, size >>> 0, false);
          new Uint8Array(buf, 8).set(new Uint8Array(head));
          var digest = await crypto.subtle.digest('SHA-256', buf);
          var bytes = new Uint8Array(digest);
          var hex = '';
          for (var i = 0; i < 8; i++) hex += bytes[i].toString(16).padStart(2, '0');
          return hex;
        } catch (e) {
          return String(Date.now()) + '-' + Math.floor(Math.random() * 100000);
        }
      }
      URL.createObjectURL = function(obj) {
        var url = originalCreate(obj);
        try {
          if (obj instanceof Blob && obj.type && obj.type.indexOf('image/') === 0) {
            contentKey(obj).then(function(key) {
              window.__crKindleProbe.urlToKey.set(url, key);
              if (!window.__crKindleProbe.keyToLiveUrl.has(key)) {
                var liveUrl = originalCreate(obj);
                window.__crKindleProbe.keyToLiveUrl.set(key, liveUrl);
                liveImageFor(key, liveUrl);
              }
            }).catch(function(){});
          }
        } catch (e) {}
        return url;
      };
      function absRect(el) {
        try {
          var r = el.getBoundingClientRect();
          return { left:r.left||0, top:r.top||0, right:r.right||0, bottom:r.bottom||0, width:r.width||0, height:r.height||0 };
        } catch (e) {
          return { left:0, top:0, right:0, bottom:0, width:0, height:0 };
        }
      }
      function rectFromLeftTopWidthHeight(left, top, width, height) {
        left = Number(left || 0); top = Number(top || 0);
        width = Math.max(0, Number(width || 0)); height = Math.max(0, Number(height || 0));
        return { left:left, top:top, right:left + width, bottom:top + height, width:width, height:height };
      }
      function parseLengthToken(token, total, natural, fallback) {
        token = String(token || '').trim();
        if (!token || token === 'auto') return fallback;
        if (token.endsWith('%')) {
          var pct = parseFloat(token);
          return isFinite(pct) ? total * pct / 100 : fallback;
        }
        var px = parseFloat(token);
        return isFinite(px) ? px : fallback;
      }
      function parsePositionToken(token, outer, inner, fallback) {
        token = String(token || '').trim().toLowerCase();
        if (!token) return fallback;
        if (token === 'left' || token === 'top') return 0;
        if (token === 'center') return (outer - inner) / 2;
        if (token === 'right' || token === 'bottom') return outer - inner;
        if (token.endsWith('%')) {
          var pct = parseFloat(token);
          return isFinite(pct) ? (outer - inner) * pct / 100 : fallback;
        }
        var px = parseFloat(token);
        return isFinite(px) ? px : fallback;
      }
      function backgroundImageRect(el, img) {
        var r = absRect(el);
        var nw = img && img.naturalWidth ? img.naturalWidth : 0;
        var nh = img && img.naturalHeight ? img.naturalHeight : 0;
        if (!(nw > 0 && nh > 0 && r.width > 0 && r.height > 0)) return r;
        var w = r.width, h = r.height;
        try {
          var st = getComputedStyle(el);
          var size = String(st.backgroundSize || '').trim();
          var parts = size.split(/\\s+/).filter(Boolean);
          if (size.indexOf('contain') >= 0) {
            var scale = Math.min(r.width / nw, r.height / nh);
            w = nw * scale; h = nh * scale;
          } else if (size.indexOf('cover') >= 0) {
            var coverScale = Math.max(r.width / nw, r.height / nh);
            w = nw * coverScale; h = nh * coverScale;
          } else if (parts.length > 0 && size !== 'auto') {
            var first = parseLengthToken(parts[0], r.width, nw, NaN);
            var second = parseLengthToken(parts[1] || 'auto', r.height, nh, NaN);
            if (isFinite(first) && isFinite(second)) {
              w = first; h = second;
            } else if (isFinite(first)) {
              w = first; h = nh * (first / nw);
            } else if (isFinite(second)) {
              h = second; w = nw * (second / nh);
            }
          }
          var pos = String(st.backgroundPosition || '50% 50%').trim().split(/\\s+/).filter(Boolean);
          var leftOffset = parsePositionToken(pos[0] || '50%', r.width, w, (r.width - w) / 2);
          var topOffset = parsePositionToken(pos[1] || '50%', r.height, h, (r.height - h) / 2);
          return rectFromLeftTopWidthHeight(r.left + leftOffset, r.top + topOffset, w, h);
        } catch (e) {
          return rectFromLeftTopWidthHeight(r.left + (r.width - w) / 2, r.top + (r.height - h) / 2, w, h);
        }
      }
      function objectPositionOffset(raw, outerW, outerH, innerW, innerH) {
        var parts = String(raw || '50% 50%').trim().split(/\\s+/).filter(Boolean);
        var x = parsePositionToken(parts[0] || '50%', outerW, innerW, (outerW - innerW) / 2);
        var y = parsePositionToken(parts[1] || '50%', outerH, innerH, (outerH - innerH) / 2);
        return { x:x, y:y };
      }
      function imageElementContentRect(img) {
        var r = absRect(img);
        var nw = img && img.naturalWidth ? img.naturalWidth : 0;
        var nh = img && img.naturalHeight ? img.naturalHeight : 0;
        if (!(nw > 0 && nh > 0 && r.width > 0 && r.height > 0)) return r;
        try {
          var st = getComputedStyle(img);
          var fit = String(st.objectFit || 'fill').toLowerCase();
          var w = r.width, h = r.height;
          if (fit === 'contain' || fit === 'scale-down') {
            var containScale = Math.min(r.width / nw, r.height / nh);
            if (fit === 'scale-down') containScale = Math.min(1, containScale);
            w = nw * containScale; h = nh * containScale;
          } else if (fit === 'cover') {
            var coverScale = Math.max(r.width / nw, r.height / nh);
            w = nw * coverScale; h = nh * coverScale;
          } else if (fit === 'none') {
            w = nw; h = nh;
          } else {
            // Kindle pages should not distort the page bitmap. If the element
            // box aspect visibly disagrees with the blob aspect, use the
            // rendered width as the source of truth and recover height from
            // the image aspect to avoid cumulative Y-axis drift.
            var boxAspect = r.height / Math.max(1, r.width);
            var imgAspect = nh / Math.max(1, nw);
            if (Math.abs(boxAspect - imgAspect) / Math.max(0.001, imgAspect) > 0.025) {
              h = r.width * imgAspect;
            }
          }
          var pos = objectPositionOffset(st.objectPosition || '50% 50%', r.width, r.height, w, h);
          return rectFromLeftTopWidthHeight(r.left + pos.x, r.top + pos.y, w, h);
        } catch (e) {
          var aspect = nh / Math.max(1, nw);
          return rectFromLeftTopWidthHeight(r.left, r.top, r.width, r.width * aspect);
        }
      }
      function visibleArea(rect) {
        var w = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
        var h = Math.max(0, Math.min(rect.bottom, innerHeight) - Math.max(rect.top, 0));
        return w * h;
      }
      function readingBandArea(rect) {
        var topBand = innerHeight * 0.08;
        var bottomBand = innerHeight * 0.82;
        var w = Math.max(0, Math.min(rect.right, innerWidth) - Math.max(rect.left, 0));
        var h = Math.max(0, Math.min(rect.bottom, bottomBand) - Math.max(rect.top, topBand));
        return w * h;
      }
      function keyForUrl(url) {
        try { return window.__crKindleProbe.urlToKey.get(url) || ''; } catch (e) { return ''; }
      }
      function hashString(value) {
        value = String(value || '');
        var hash = 5381;
        for (var i = 0; i < value.length; i++) {
          hash = ((hash << 5) + hash) ^ value.charCodeAt(i);
        }
        return (hash >>> 0).toString(36);
      }
      function stableImageKey(url, element) {
        var content = keyForUrl(url) || '';
        if (content) return 'content-' + content;
        if (url && url.indexOf('blob:') === 0) return 'src-' + hashString(url);
        return elementKey(element);
      }
      function elementKey(el) {
        if (!el) return '';
        try {
          var key = el.getAttribute('data-cr-kindle-candidate-id') || '';
          if (!key) {
            window.__crKindleProbe.candidateSeq = (window.__crKindleProbe.candidateSeq || 0) + 1;
            key = 'el-' + Date.now().toString(36) + '-' + window.__crKindleProbe.candidateSeq;
            el.setAttribute('data-cr-kindle-candidate-id', key);
          }
          return key;
        } catch (e) {
          return '';
        }
      }
      function blobUrlFromBackground(el) {
        try {
          var bg = getComputedStyle(el).backgroundImage || '';
          var m = bg.match(/url\\(["']?(blob:[^"')]+)["']?\\)/);
          return m ? m[1] : '';
        } catch (e) { return ''; }
      }
      function candidates() {
        var out = [];
        Array.from(document.querySelectorAll('img')).forEach(function(img) {
          if (!img.src || img.src.indexOf('blob:') !== 0) return;
          var rect = imageElementContentRect(img);
          var content = keyForUrl(img.src) || '';
          var key = stableImageKey(img.src, img);
          out.push({ kind:'dom-img', el:img, img:img, src:img.src, key:key, contentKey:content, rect:rect, visible:visibleArea(rect), bandVisible:readingBandArea(rect), nw:img.naturalWidth||0, nh:img.naturalHeight||0 });
        });
        Array.from(document.querySelectorAll('*')).forEach(function(el) {
          var url = blobUrlFromBackground(el);
          if (!url) return;
          var content = keyForUrl(url);
          var key = stableImageKey(url, el);
          var live = content ? (window.__crKindleProbe.keyToLiveUrl.get(content) || url) : url;
          var img = (content ? liveImageFor(content, live) : null) || liveImageFor(key, live);
          if (!img || !img.complete || !(img.naturalWidth > 0)) return;
          var rect = backgroundImageRect(el, img);
          out.push({ kind:'bg-blob', el:el, img:img, src:url, key:key, contentKey:content || '', rect:rect, visible:visibleArea(rect), bandVisible:readingBandArea(rect), nw:img.naturalWidth||0, nh:img.naturalHeight||0 });
        });
        return out;
      }
      function candidateOrderY(c) {
        if (!c || !c.rect) return 0;
        return Number(c.rect.top || 0);
      }
      function orderedCandidates() {
        return candidates()
          .filter(function(c) { return c && c.key && c.rect && c.rect.height > 40 && c.rect.width > 40; })
          .sort(function(a, b) {
            var dy = candidateOrderY(a) - candidateOrderY(b);
            if (Math.abs(dy) > 2) return dy;
            return Number((a.rect && a.rect.left) || 0) - Number((b.rect && b.rect.left) || 0);
          });
      }
      function nextCandidateAfterKey(key) {
        key = String(key || '');
        var list = orderedCandidates();
        if (!list.length) return null;
        var idx = -1;
        for (var i = 0; i < list.length; i++) {
          if (String(list[i].key || '') === key) { idx = i; break; }
        }
        if (idx >= 0 && idx + 1 < list.length) return list[idx + 1];
        var anchor = key ? (lockedLiveCandidateForKey(key) || crKindleCandidateForKey(key)) : null;
        if (anchor && anchor.rect) {
          var anchorMid = Number(anchor.rect.top || 0) + Number(anchor.rect.height || 0) * 0.5;
          for (var j = 0; j < list.length; j++) {
            if (String(list[j].key || '') !== key && candidateOrderY(list[j]) > anchorMid) return list[j];
          }
        }
        return null;
      }
      function scrollCandidateIntoView(candidate, block) {
        if (!candidate || !candidate.el) return false;
        try {
          candidate.el.scrollIntoView({ block:block || 'start', inline:'nearest', behavior:'smooth' });
          return true;
        } catch (e) {
          try {
            candidate.el.scrollIntoView();
            return true;
          } catch (_) {
            return false;
          }
        }
      }
      function crKindleScrollNode(el, delta) {
        delta = Number(delta || 0);
        if (!el || !isFinite(delta) || Math.abs(delta) < 1) {
          return { moved:false, before:0, after:0, delta:0, animated:false };
        }
        var before = Number(el.scrollTop || 0);
        var maxTop = Math.max(0, Number(el.scrollHeight || 0) - Number(el.clientHeight || 0));
        var target = Math.max(0, Math.min(maxTop, before + delta));
        var actual = target - before;
        if (Math.abs(actual) < 1) {
          return { moved:false, before:Math.round(before), after:Math.round(before), delta:0, animated:false };
        }
        var slot = '__crKindleScrollAnim';
        try {
          if (el[slot] && el[slot].raf) cancelAnimationFrame(el[slot].raf);
        } catch (e) {}
        var start = before;
        var duration = Math.max(150, Math.min(380, Math.abs(actual) * 4.2));
        var startedAt = (window.performance && performance.now) ? performance.now() : Date.now();
        function ease(t) { return 1 - Math.pow(1 - t, 3); }
        function tick(now) {
          try {
            var elapsed = now - startedAt;
            var p = Math.max(0, Math.min(1, elapsed / duration));
            el.scrollTop = start + actual * ease(p);
            crKindleUpdateLiveOverlay();
            if (p < 1) {
              el[slot].raf = requestAnimationFrame(tick);
            } else {
              el.scrollTop = target;
              crKindleUpdateLiveOverlay();
              el[slot] = null;
            }
          } catch (e) {
            try { el.scrollTop = target; } catch (_) {}
            try { crKindleUpdateLiveOverlay(); } catch (_) {}
            try { el[slot] = null; } catch (_) {}
          }
        }
        try {
          el[slot] = { raf: requestAnimationFrame(tick), target: target };
          return { moved:true, before:Math.round(before), after:Math.round(target), delta:Math.round(actual), animated:true };
        } catch (e) {
          try { el.scrollTop = target; } catch (_) {}
          return { moved:true, before:Math.round(before), after:Math.round(target), delta:Math.round(actual), animated:false };
        }
      }
      function findReplacementCandidate(candidate, key) {
        var list = candidates();
        var wantedKey = String(key || (candidate && candidate.key) || '');
        var wantedSrc = String((candidate && candidate.src) || '');
        var wantedContent = String((candidate && candidate.contentKey) || '');
        var best = null, score = -1;
        for (var i = 0; i < list.length; i++) {
          var c = list[i];
          var same =
            (wantedKey && c.key === wantedKey) ||
            (wantedContent && c.contentKey === wantedContent) ||
            (wantedSrc && c.src === wantedSrc);
          if (!same) continue;
          var visibleScore = Math.max(c.bandVisible || 0, c.visible || 0);
          var s = visibleScore > 0 ? visibleScore + 100000000 : (c.nw || 0) * (c.nh || 0);
          if (s > score) { best = c; score = s; }
        }
        return best;
      }
      function bestCandidate() {
        var list = candidates();
        var best = null, score = -1;
        for (var i = 0; i < list.length; i++) {
          var c = list[i];
          var visibleScore = Math.max(c.bandVisible || 0, c.visible || 0);
          var s = visibleScore > 0 ? visibleScore + 100000000 : (c.nw || 0) * (c.nh || 0);
          if (s > score) { best = c; score = s; }
        }
        return best;
      }
      function currentReadingCandidate() {
        var list = candidates();
        if (!list.length) return null;
        var anchorX = Math.max(1, Number(innerWidth || document.documentElement.clientWidth || 1)) * 0.5;
        var anchorY = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1)) * 0.36;
        var best = null, score = -Infinity;
        for (var i = 0; i < list.length; i++) {
          var c = list[i], r = c && c.rect;
          if (!r || r.width <= 1 || r.height <= 1) continue;
          var contains = anchorX >= r.left && anchorX <= r.right && anchorY >= r.top && anchorY <= r.bottom;
          var vis = Math.max(c.bandVisible || 0, c.visible || 0);
          var midY = r.top + r.height * 0.5;
          var distance = Math.abs(midY - anchorY);
          var s = (contains ? 1000000000 : 0) + vis - distance * 12;
          if (s > score) { best = c; score = s; }
        }
        return best || bestCandidate();
      }
      function refreshCandidate(candidate) {
        if (!candidate || !candidate.el) return null;
        try {
          if (!candidate.el.isConnected) {
            candidate = findReplacementCandidate(candidate, candidate.key);
            if (!candidate || !candidate.el) return null;
          }
        } catch (e) {
          return null;
        }
        var img = candidate.img || (candidate.el && candidate.el.tagName === 'IMG' ? candidate.el : null);
        if (!img || !img.complete || !(img.naturalWidth > 0)) return null;
        var rect = candidate.kind === 'bg-blob' ? backgroundImageRect(candidate.el, img) : imageElementContentRect(candidate.el);
        if (!rect || rect.width <= 1 || rect.height <= 1) return null;
        return {
          kind: candidate.kind || 'dom-img',
          el: candidate.el,
          img: img,
          src: candidate.src || (candidate.el && candidate.el.tagName === 'IMG' ? candidate.el.src : blobUrlFromBackground(candidate.el)),
          key: candidate.key || stableImageKey(candidate.src || '', candidate.el) || '',
          contentKey: candidate.contentKey || '',
          rect: rect,
          visible: visibleArea(rect),
          bandVisible: readingBandArea(rect),
          nw: img.naturalWidth || 0,
          nh: img.naturalHeight || 0
        };
      }
      function lockLiveCandidate(candidate) {
        candidate = refreshCandidate(candidate) || candidate;
        if (!candidate || !candidate.rect || !candidate.el) return null;
        window.__crKindleProbe.liveSessionId = Number(window.__crKindleProbe.liveSessionId || 0) + 1;
        window.__crKindleProbe.liveCandidate = candidate;
        window.__crKindleProbe.liveKey = String(candidate.key || '');
        window.__crKindleProbe.liveParagraphs = [];
        try { candidate.el.setAttribute('data-cr-kindle-live-session', String(window.__crKindleProbe.liveSessionId)); } catch (e) {}
        crKindleEnsureLiveOverlay(candidate);
        var ov = window.__crKindleProbe.liveOverlay;
        if (ov) ov.textContent = '';
        crKindleUpdateLiveOverlay(candidate);
        return candidate;
      }
      function lockedLiveCandidateForKey(key) {
        var live = window.__crKindleProbe.liveCandidate;
        if (!live) return null;
        var refreshed = refreshCandidate(live);
        key = String(key || '');
        if (!refreshed) refreshed = findReplacementCandidate(live, key);
        if (!refreshed) return null;
        if (key && refreshed.key !== key) return null;
        try { refreshed.el.setAttribute('data-cr-kindle-live-session', String(window.__crKindleProbe.liveSessionId || 0)); } catch (e) {}
        window.__crKindleProbe.liveCandidate = refreshed;
        return refreshed;
      }
      function draw(img, key, maxWidth, quality, rect) {
        var nw = img.naturalWidth || img.width || 1;
        var nh = img.naturalHeight || img.height || 1;
        var scale = nw > maxWidth ? maxWidth / nw : 1;
        var canvas = document.createElement('canvas');
        canvas.width = Math.max(1, Math.round(nw * scale));
        canvas.height = Math.max(1, Math.round(nh * scale));
        var ctx = canvas.getContext('2d');
        ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
        rect = rect || { left:0, top:0, width:innerWidth||1, height:innerHeight||1 };
        var topNorm = rect.height > 0 ? (0 - rect.top) / rect.height : 0;
        var bottomNorm = rect.height > 0 ? ((innerHeight || 0) - rect.top) / rect.height : 1;
        topNorm = Math.max(0, Math.min(1, topNorm));
        bottomNorm = Math.max(topNorm, Math.min(1, bottomNorm));
        return {
          ok: true,
          key: key || '',
          source: 'visible',
          image: canvas.toDataURL('image/jpeg', quality || 0.9),
          natural: nw + 'x' + nh,
          rendered: canvas.width + 'x' + canvas.height,
          pageRect: { left:rect.left||0, top:rect.top||0, width:rect.width||0, height:rect.height||0 },
          visibleTopNorm: topNorm,
          visibleBottomNorm: bottomNorm,
          title: document.title || 'Kindle',
          url: location.href,
          progress: (document.body && (document.body.innerText || '').match(/Page\\s+\\d+\\s+of\\s+\\d+|\\d{1,3}\\s*%/i) || [''])[0]
        };
      }
      window.__crKindleCurrentPageSnapshot = function(maxWidth, quality) {
        try {
          var c = currentReadingCandidate();
          if (!c || !c.img || !c.img.complete || !(c.img.naturalWidth > 0)) {
            return JSON.stringify({ ok:false, reason:'no-visible-kindle-image', heldKeys: window.__crKindleProbe.keyToLiveUrl.size, url: location.href });
          }
          c = lockLiveCandidate(c) || c;
          var shot = draw(c.img, c.key || '', maxWidth || 1200, quality || 0.9, c.rect);
          shot.kind = c.kind || '';
          shot.visibleArea = c.visible || 0;
          shot.bandVisibleArea = c.bandVisible || 0;
          shot.sessionId = window.__crKindleProbe.liveSessionId || 0;
          return JSON.stringify(shot);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), url: location.href });
        }
      };
      window.__crKindlePageSnapshotForKey = function(key, maxWidth, quality) {
        try {
          key = String(key || '');
          if (!key) return JSON.stringify({ ok:false, reason:'empty-key', url:location.href });
          var c = crKindleCandidateForKey(key);
          if (!c || !c.img || !c.img.complete || !(c.img.naturalWidth > 0)) {
            var list = orderedCandidates();
            return JSON.stringify({
              ok:false,
              reason:'key-not-visible',
              key:key,
              ordered:list.map(function(x){ return String(x.key || '').slice(0,24) + ':' + Math.round((x.rect && x.rect.top) || 0); }).slice(0,8).join('|'),
              heldKeys: window.__crKindleProbe.keyToLiveUrl.size,
              url: location.href
            });
          }
          c = lockLiveCandidate(c) || c;
          var shot = draw(c.img, c.key || key, maxWidth || 1200, quality || 0.9, c.rect);
          shot.kind = c.kind || '';
          shot.visibleArea = c.visible || 0;
          shot.bandVisibleArea = c.bandVisible || 0;
          shot.sessionId = window.__crKindleProbe.liveSessionId || 0;
          shot.requestedKey = key;
          return JSON.stringify(shot);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), key:String(key || ''), url:location.href });
        }
      };
      window.__crKindleNextPageSnapshot = function(afterKey, maxWidth, quality) {
        try {
          afterKey = String(afterKey || window.__crKindleProbe.liveKey || '');
          if (!afterKey) return JSON.stringify({ ok:false, reason:'empty-after-key', url:location.href });
          var next = nextCandidateAfterKey(afterKey);
          var ordered = orderedCandidates();
          function orderedBrief() {
            return ordered.map(function(x) {
              var top = x && x.rect ? Math.round(Number(x.rect.top || 0)) : 0;
              var bottom = x && x.rect ? Math.round(Number(x.rect.bottom || 0)) : 0;
              return String((x && x.key) || '').slice(0, 24) + ':' + top + '..' + bottom;
            }).slice(0, 12).join('|');
          }
          if (!next || !next.key || !next.img || !next.img.complete || !(next.img.naturalWidth > 0)) {
            return JSON.stringify({
              ok:false,
              reason:'no-next-candidate',
              afterKey:afterKey,
              liveKey:String(window.__crKindleProbe.liveKey || ''),
              heldKeys:window.__crKindleProbe.keyToLiveUrl.size,
              ordered:orderedBrief(),
              url:location.href
            });
          }
          // Important: preloading must not call lockLiveCandidate(). It should not mutate
          // liveKey/liveSessionId/liveCandidate; otherwise the current page highlight state
          // can be polluted before playback actually advances.
          var shot = draw(next.img, next.key || '', maxWidth || 1200, quality || 0.9, next.rect);
          shot.kind = next.kind || '';
          shot.visibleArea = next.visible || 0;
          shot.bandVisibleArea = next.bandVisible || 0;
          shot.sessionId = window.__crKindleProbe.liveSessionId || 0;
          shot.afterKey = afterKey;
          shot.prefetch = true;
          shot.ordered = orderedBrief();
          return JSON.stringify(shot);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), afterKey:String(afterKey || ''), url:location.href });
        }
      };
      window.__crKindleAlignBestPageToTop = function() {
        try {
          var c = currentReadingCandidate();
          if (!c || !c.key || !c.el) {
            return JSON.stringify({ ok:false, reason:'no-visible-kindle-image', url:location.href });
          }
          var before = c.rect ? [Math.round(c.rect.left), Math.round(c.rect.top), Math.round(c.rect.width), Math.round(c.rect.height)].join(',') : '';
          scrollCandidateIntoView(c, 'start');
          var refreshed = crKindleCandidateForKey(c.key) || c;
          var after = refreshed && refreshed.rect ? [Math.round(refreshed.rect.left), Math.round(refreshed.rect.top), Math.round(refreshed.rect.width), Math.round(refreshed.rect.height)].join(',') : '';
          return JSON.stringify({ ok:true, key:String(c.key || ''), mode:'current-reading-page-top', before:before, after:after });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), url:location.href });
        }
      };
      window.__crKindleScroll = function(delta) {
        var tried = [];
        var c = bestCandidate();
        var all = [];
        var node = c && c.el ? c.el : null;
        for (var depth = 0; node && depth < 12; depth++, node = node.parentElement) {
          try {
            var st = getComputedStyle(node);
            var canY = /(auto|scroll|overlay)/.test(st.overflowY || '') || (node.scrollHeight || 0) > (node.clientHeight || 0) + 4;
            if (canY && (node.scrollHeight || 0) > (node.clientHeight || 0) + 4) all.push(node);
          } catch (e) {}
        }
        [document.scrollingElement, document.body, document.documentElement].forEach(function(el) {
          if (el && all.indexOf(el) < 0) all.push(el);
        });
        var moved = false;
        for (var i = 0; i < Math.min(all.length, 4); i++) {
          var el = all[i];
          try {
            var movedResult = crKindleScrollNode(el, delta);
            tried.push(movedResult.before + '>' + movedResult.after + (movedResult.animated ? '~' : ''));
            if (movedResult.moved) {
              moved = true;
              break;
            }
          } catch (e) {}
        }
        if (!moved) {
          try { window.scrollBy(0, delta); tried.push('window'); } catch (e) {}
          try {
            var key = delta >= 0 ? 'PageDown' : 'PageUp';
            document.dispatchEvent(new KeyboardEvent('keydown', { key:key, code:key, bubbles:true }));
            document.dispatchEvent(new KeyboardEvent('keyup', { key:key, code:key, bubbles:true }));
            tried.push(key);
          } catch (e) {}
        }
        return JSON.stringify({ ok:true, tried:tried.slice(0,4).join('|'), moved:moved, url:location.href });
      };
      window.__crKindleScrollToKey = function(key, block) {
        try {
          block = String(block || 'nearest');
          var list = candidates();
          for (var i = 0; i < list.length; i++) {
            var c = list[i];
            if (c.key === key && c.el) {
              try { c.el.scrollIntoView({ block:block, inline:'nearest', behavior:'smooth' }); } catch (e) { c.el.scrollIntoView(); }
              return JSON.stringify({ ok:true, key:key, block:block, url:location.href });
            }
          }
          return JSON.stringify({ ok:false, reason:'key-not-visible', key:key, heldKeys:window.__crKindleProbe.keyToLiveUrl.size, url:location.href });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), key:key, url:location.href });
        }
      };
      function crKindleRemoveLiveOverlay() {
        try {
          if (window.__crKindleProbe.liveResizeObserver) {
            window.__crKindleProbe.liveResizeObserver.disconnect();
            window.__crKindleProbe.liveResizeObserver = null;
          }
          if (window.__crKindleProbe.liveOverlay) {
            window.__crKindleProbe.liveOverlay.remove();
            window.__crKindleProbe.liveOverlay = null;
          }
          window.__crKindleProbe.liveState = null;
        } catch (e) {}
      }
      function crKindleNormRect(n, w, h) {
        n = n || {};
        var x = Number(n.x || 0), y = Number(n.y || 0), rw = Number(n.width || 0), rh = Number(n.height || 0);
        return { left: x * w, top: (1 - y - rh) * h, width: rw * w, height: rh * h };
      }
      function crKindleUnion(rects) {
        if (!rects || !rects.length) return null;
        var l = rects[0].left, t = rects[0].top, r = rects[0].left + rects[0].width, b = rects[0].top + rects[0].height;
        for (var i = 1; i < rects.length; i++) {
          l = Math.min(l, rects[i].left); t = Math.min(t, rects[i].top);
          r = Math.max(r, rects[i].left + rects[i].width); b = Math.max(b, rects[i].top + rects[i].height);
        }
        return { left:l, top:t, width:r-l, height:b-t };
      }
      function crKindleWordsForRange(para, start, end) {
        var text = String((para && para.text) || '');
        var words = (para && para.words) || [];
        var cursor = 0, out = [];
        for (var i = 0; i < words.length; i++) {
          var raw = String(words[i].text || '');
          if (!raw) continue;
          var found = text.indexOf(raw, cursor);
          if (found < 0) {
            var stripped = raw.replace(/^[^\\w\\u4e00-\\u9fff]+|[^\\w\\u4e00-\\u9fff]+$/g, '');
            found = stripped ? text.toLowerCase().indexOf(stripped.toLowerCase(), cursor) : -1;
            if (found >= 0) raw = stripped;
          }
          if (found < 0) continue;
          var wr = { start: found, end: found + raw.length };
          if (wr.end > start && wr.start < end) out.push(words[i]);
          cursor = found + raw.length;
        }
        return out;
      }
      function crKindleLineUnions(rects) {
        if (!rects || !rects.length) return [];
        var sorted = rects.slice().sort(function(a, b) { return a.top - b.top; });
        var lines = [], cur = [sorted[0]], mid = sorted[0].top + sorted[0].height / 2;
        for (var i = 1; i < sorted.length; i++) {
          var r = sorted[i], m = r.top + r.height / 2;
          var tol = Math.max(5, Math.min(r.height, sorted[0].height) * 0.75);
          if (Math.abs(m - mid) <= tol) {
            cur.push(r);
          } else {
            lines.push(crKindleUnion(cur));
            cur = [r]; mid = m;
          }
        }
        lines.push(crKindleUnion(cur));
        return lines.filter(Boolean);
      }
      function crKindlePaintRect(className, rect, style) {
        var ov = window.__crKindleProbe.liveOverlay;
        if (!ov || !rect) return null;
        var d = document.createElement('div');
        d.className = className;
        d.style.cssText =
          'position:absolute;left:' + (rect.left - 2) + 'px;top:' + (rect.top - 1) + 'px;' +
          'width:' + (rect.width + 4) + 'px;height:' + (rect.height + 2) + 'px;' +
          'pointer-events:none;border-radius:3px;' + (style || '');
        ov.appendChild(d);
        return d;
      }
      function crKindleCandidateForKey(key) {
        key = String(key || '');
        var locked = lockedLiveCandidateForKey(key);
        if (locked) return locked;
        if (!key) return bestCandidate();
        var list = candidates();
        var best = null, score = -1;
        for (var i = 0; i < list.length; i++) {
          var c = list[i];
          if (!c || c.key !== key) continue;
          var visibleScore = Math.max(c.bandVisible || 0, c.visible || 0);
          var s = visibleScore > 0 ? visibleScore + 100000000 : (c.nw || 0) * (c.nh || 0);
          if (s > score) { best = c; score = s; }
        }
        return best;
      }
      function crKindleOverlayParent(candidate) {
        if (!candidate || !candidate.el) return document.body || document.documentElement;
        if (candidate.kind === 'dom-img' && candidate.el.parentElement) return candidate.el.parentElement;
        if (candidate.kind === 'bg-blob') return candidate.el;
        return candidate.el.parentElement || candidate.el || document.body || document.documentElement;
      }
      function crKindleEnsureLiveOverlay(candidate) {
        candidate = candidate || crKindleLiveCandidate();
        if (!candidate || !candidate.rect || !candidate.el) return null;
        var key = String(candidate.key || '');
        var parent = crKindleOverlayParent(candidate);
        if (!parent) return null;
        var ov = window.__crKindleProbe.liveOverlay;
        if (!ov || ov.getAttribute('data-cr-page-key') !== key || ov.parentElement !== parent) {
          crKindleRemoveLiveOverlay();
          ov = document.createElement('div');
          ov.className = 'cr-kindle-live-overlay';
          ov.setAttribute('data-castreader-overlay', 'kindle-live-local');
          ov.setAttribute('data-cr-page-key', key);
          ov.style.cssText = 'position:absolute;left:0;top:0;width:1px;height:1px;pointer-events:none;z-index:2147483647;overflow:visible;opacity:1;display:block;background:transparent;transform:translateZ(0);will-change:left,top,width,height;';
          try {
            var ps = getComputedStyle(parent).position || '';
            if (parent !== document.body && parent !== document.documentElement && (!ps || ps === 'static')) {
              parent.style.position = 'relative';
            }
          } catch (e) {}
          parent.appendChild(ov);
          window.__crKindleProbe.liveOverlay = ov;
          try {
            window.__crKindleProbe.liveResizeObserver = new ResizeObserver(function() {
              crKindleUpdateLiveOverlay();
            });
            window.__crKindleProbe.liveResizeObserver.observe(parent);
            if (candidate.el !== parent) window.__crKindleProbe.liveResizeObserver.observe(candidate.el);
          } catch (e) {}
        }
        crKindleUpdateLiveOverlay(candidate);
        return ov;
      }
      function crKindleLocalOverlayRect(candidate, parent) {
        if (!candidate || !parent) return null;
        var r = candidate.rect;
        if (parent === document.body || parent === document.documentElement) {
          return {
            left: Number(r.left || 0),
            top: Number(r.top || 0),
            width: Math.max(1, r.width || 0),
            height: Math.max(1, r.height || 0),
            mode: 'viewport'
          };
        }
        function localFromViewportRect(viewRect, mode) {
          var parentRect = absRect(parent);
          var scrollLeft = Number(parent.scrollLeft || 0);
          var scrollTop = Number(parent.scrollTop || 0);
          var borderLeft = 0, borderTop = 0;
          try {
            var ps = getComputedStyle(parent);
            borderLeft = parseFloat(ps.borderLeftWidth || '0') || 0;
            borderTop = parseFloat(ps.borderTopWidth || '0') || 0;
          } catch (e) {}
          var layoutW = Number(parent.offsetWidth || parent.clientWidth || parentRect.width || 0);
          var layoutH = Number(parent.offsetHeight || parent.clientHeight || parentRect.height || 0);
          var scaleX = layoutW > 0 && parentRect.width > 0 ? parentRect.width / layoutW : 1;
          var scaleY = layoutH > 0 && parentRect.height > 0 ? parentRect.height / layoutH : 1;
          if (!isFinite(scaleX) || Math.abs(scaleX) < 0.001) scaleX = 1;
          if (!isFinite(scaleY) || Math.abs(scaleY) < 0.001) scaleY = 1;
          var localWidth = Math.max(1, Number(viewRect.width || 0) / scaleX);
          var localHeight = Math.max(1, Number(viewRect.height || 0) / scaleY);
          var calibrated = false;
          try {
            var px = window.__crKindleProbe.liveImagePixelSize || null;
            var iw = Number(px && px.width || 0);
            var ih = Number(px && px.height || 0);
            if (iw > 1 && ih > 1 && localWidth > 1) {
              var aspectHeight = localWidth * (ih / iw);
              if (isFinite(aspectHeight) && aspectHeight > 1) {
                var drift = Math.abs(aspectHeight - localHeight) / Math.max(1, aspectHeight);
                if (drift > 0.006) {
                  localHeight = aspectHeight;
                  calibrated = true;
                }
              }
            }
          } catch (e) {}
          return {
            left: (Number(viewRect.left || 0) - Number(parentRect.left || 0)) / scaleX + scrollLeft - borderLeft,
            top: (Number(viewRect.top || 0) - Number(parentRect.top || 0)) / scaleY + scrollTop - borderTop,
            width: localWidth,
            height: localHeight,
            mode: mode + ':scale=' + scaleX.toFixed(3) + ',' + scaleY.toFixed(3) + (calibrated ? ':ocr-aspect' : '')
          };
        }
        if (candidate.kind === 'dom-img' && candidate.el && candidate.el.parentElement === parent) {
          var imgRect = imageElementContentRect(candidate.el);
          return localFromViewportRect(imgRect, 'bcr-parent');
        }
        if (candidate.kind === 'bg-blob' && candidate.el === parent) {
          var bgRect = candidate.rect || absRect(parent);
          return localFromViewportRect(bgRect, 'bg-bcr-parent');
        }
        return localFromViewportRect(r, 'bcr');
      }
      function crKindleUpdateLiveOverlay(candidate) {
        var ov = window.__crKindleProbe.liveOverlay;
        if (!ov) return null;
        candidate = candidate || crKindleLiveCandidate();
        if (!candidate || !candidate.rect) {
          return null;
        }
        var parent = ov.parentElement || crKindleOverlayParent(candidate);
        if (!parent) return null;
        var r = candidate.rect;
        var local = crKindleLocalOverlayRect(candidate, parent);
        if (!local) return null;
        var positionMode = (parent === document.body || parent === document.documentElement) ? 'fixed' : 'absolute';
        Object.assign(ov.style, {
          position: positionMode,
          left: local.left + 'px',
          top: local.top + 'px',
          width: local.width + 'px',
          height: local.height + 'px'
        });
        ov.setAttribute('data-cr-page-key', String(candidate.key || ''));
        ov.setAttribute('data-cr-page-kind', String(candidate.kind || ''));
        ov.setAttribute('data-cr-page-rect', [Math.round(r.left), Math.round(r.top), Math.round(r.width), Math.round(r.height)].join(','));
        ov.setAttribute('data-cr-local-rect', [Math.round(local.left), Math.round(local.top), Math.round(local.width), Math.round(local.height), local.mode].join(','));
        ov.setAttribute('data-cr-overlay-position', positionMode);
        try { if (ov.parentElement) ov.parentElement.appendChild(ov); } catch (e) {}
        var state = { overlay:ov, rect:r, localRect:local, width:local.width, height:local.height };
        window.__crKindleProbe.liveState = {
          sessionId: Number(window.__crKindleProbe.liveSessionId || 0),
          key: String(candidate.key || ''),
          kind: String(candidate.kind || ''),
          rect: r,
          localRect: local,
          width: local.width,
          height: local.height
        };
        return state;
      }
      function crKindleLiveCandidate() {
        var key = String(window.__crKindleProbe.liveKey || '');
        return crKindleCandidateForKey(key);
      }
      function crKindleLivePageRect() {
        var state = crKindleUpdateLiveOverlay();
        if (state && state.rect) return state.rect;
        var c = crKindleLiveCandidate();
        return c && c.rect ? c.rect : null;
      }
      function crKindleNormRectInViewport(norm) {
        var page = crKindleLivePageRect();
        if (!page || !norm) return null;
        var x = Number(norm.x || 0), y = Number(norm.y || 0), rw = Number(norm.width || 0), rh = Number(norm.height || 0);
        return {
          left: page.left + x * page.width,
          top: page.top + (1 - y - rh) * page.height,
          width: Math.max(1, rw * page.width),
          height: Math.max(1, rh * page.height)
        };
      }
      function crKindleNormRectInOverlay(norm) {
        var state = crKindleUpdateLiveOverlay();
        if (!state || !norm) return null;
        var x = Number(norm.x || 0), y = Number(norm.y || 0), rw = Number(norm.width || 0), rh = Number(norm.height || 0);
        return {
          left: x * state.width,
          top: (1 - y - rh) * state.height,
          width: Math.max(1, rw * state.width),
          height: Math.max(1, rh * state.height)
        };
      }
      function crKindleNormRectPercent(norm) {
        if (!norm) return null;
        var x = Number(norm.x || 0), y = Number(norm.y || 0), rw = Number(norm.width || 0), rh = Number(norm.height || 0);
        return {
          left:x * 100,
          top:(1 - y - rh) * 100,
          width:Math.max(0.05, rw * 100),
          height:Math.max(0.05, rh * 100)
        };
      }
      function crKindleNormUnion(words) {
        if (!words || !words.length) return null;
        var minX = 1, minY = 1, maxX = 0, maxY = 0, hit = false;
        words.forEach(function(word) {
          var n = word && word.bboxNorm;
          if (!n) return;
          var x = Number(n.x || 0), y = Number(n.y || 0), w = Number(n.width || 0), h = Number(n.height || 0);
          if (w <= 0 || h <= 0) return;
          minX = Math.min(minX, x); minY = Math.min(minY, y);
          maxX = Math.max(maxX, x + w); maxY = Math.max(maxY, y + h);
          hit = true;
        });
        if (!hit) return null;
        return { x:minX, y:minY, width:Math.max(0.001, maxX - minX), height:Math.max(0.001, maxY - minY) };
      }
      function crKindleFindLiveParagraph(paragraphIndex) {
        var paras = window.__crKindleProbe.liveParagraphs || [];
        for (var i = 0; i < paras.length; i++) {
          if (Number(paras[i].id) === Number(paragraphIndex)) return paras[i];
        }
        return null;
      }
      function crKindleParagraphNormRect(para) {
        if (!para) return null;
        return para.bboxNorm || crKindleNormUnion(para.words || []);
      }
      function crKindleSoftScroll(delta, expectedKey) {
        expectedKey = String(expectedKey || '');
        var before = crKindleCandidateForKey(expectedKey);
        var beforeKey = before && before.key ? before.key : '';
        var beforeBest = bestCandidate();
        var beforeBestKey = beforeBest && beforeBest.key ? beforeBest.key : '';
        if (expectedKey && beforeKey && beforeKey !== expectedKey) {
          return { ok:false, reason:'before-mismatch', expectedKey:expectedKey, beforeKey:beforeKey, beforeBestKey:beforeBestKey, afterKey:beforeKey, delta:0 };
        }
        var all = [];
        var node = before && before.el ? before.el : null;
        for (var depth = 0; node && depth < 12; depth++, node = node.parentElement) {
          try {
            var st = getComputedStyle(node);
            var canY = /(auto|scroll|overlay)/.test(st.overflowY || '') || (node.scrollHeight || 0) > (node.clientHeight || 0) + 4;
            if (canY && (node.scrollHeight || 0) > (node.clientHeight || 0) + 4) all.push(node);
          } catch (e) {}
        }
        [document.scrollingElement, document.body, document.documentElement].forEach(function(el) {
          if (el && all.indexOf(el) < 0) all.push(el);
        });
        var tried = [];
        var moved = false;
        for (var i = 0; i < Math.min(all.length, 4); i++) {
          var el = all[i];
          try {
            var movedResult = crKindleScrollNode(el, delta);
            tried.push(movedResult.before + '>' + movedResult.after + (movedResult.animated ? '~' : ''));
            if (movedResult.moved) {
              moved = true;
              break;
            }
          } catch (e) {}
        }
        if (!moved) {
          try {
            var rootResult = crKindleScrollNode(document.scrollingElement || document.documentElement || document.body, delta);
            tried.push('root:' + rootResult.before + '>' + rootResult.after + (rootResult.animated ? '~' : ''));
            moved = rootResult.moved;
          } catch (e) {}
          try {
            var x = Math.floor(innerWidth * 0.5), y = Math.floor(innerHeight * 0.62);
            var target = document.elementFromPoint(x, y) || document.body;
            target.dispatchEvent(new WheelEvent('wheel', { deltaY: delta, bubbles: true, cancelable: true }));
          } catch (e) {}
        }
        var after = bestCandidate();
        var afterKey = after && after.key ? after.key : '';
        var afterExpected = expectedKey ? crKindleCandidateForKey(expectedKey) : null;
        var afterExpectedVisible = afterExpected ? Math.max(afterExpected.bandVisible || 0, afterExpected.visible || 0) : 0;
        if (expectedKey && (!afterExpected || afterExpectedVisible <= 4)) {
          crKindleUpdateLiveOverlay();
          return { ok:false, reason:'expected-page-left-view', expectedKey:expectedKey, beforeKey:beforeKey, beforeBestKey:beforeBestKey, afterKey:afterKey, afterExpectedVisible:Math.round(afterExpectedVisible), delta:delta, reverted:false, tried:tried.slice(0,4).join('|') };
        }
        crKindleUpdateLiveOverlay();
        return { ok:true, expectedKey:expectedKey, beforeKey:beforeKey, beforeBestKey:beforeBestKey, afterKey:afterKey, afterExpectedKey:afterExpected && afterExpected.key ? afterExpected.key : '', afterExpectedVisible:Math.round(afterExpectedVisible), delta:delta, tried:tried.slice(0,4).join('|') };
      }
      function crKindleLiveFollowRect(rect, expectedKey) {
        expectedKey = String(expectedKey || '');
        if (!rect) return { needed:false, reason:'no-rect' };
        var viewportH = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
        var lower = Math.max(220, viewportH * 0.78);
        var hardLower = Math.max(lower + 24, viewportH * 0.92);
        var target = Math.max(140, viewportH * 0.58);
        var top = Number(rect.top || 0);
        var bottom = top + Number(rect.height || 0);
        var now = Date.now();
        var pageStartedAt = Number(window.__crKindleProbe.livePageStartedAt || 0);
        var pageAge = pageStartedAt > 0 ? now - pageStartedAt : 999999;
        var delta = 0;
        var needed = false;
        if (pageAge < 1400 && bottom < hardLower) {
          return {
            needed:false,
            reason:'initial-visible-hold',
            top:Math.round(top),
            bottom:Math.round(bottom),
            lower:Math.round(lower),
            hardLower:Math.round(hardLower),
            target:Math.round(target),
            pageAge:Math.round(pageAge),
            viewportH:Math.round(viewportH)
          };
        }
        if (bottom > lower) {
          delta = top - target;
          needed = true;
        }
        if (!needed || delta < 28) {
          return {
            needed:false,
            top:Math.round(top),
            bottom:Math.round(bottom),
            lower:Math.round(lower),
            hardLower:Math.round(hardLower),
            target:Math.round(target),
            pageAge:Math.round(pageAge),
            viewportH:Math.round(viewportH)
          };
        }
        var lastAt = Number(window.__crKindleProbe.lastFollowScrollAt || 0);
        if (now - lastAt < 900) {
          return {
            needed:true,
            throttled:true,
            delta:Math.round(delta),
            top:Math.round(top),
            bottom:Math.round(bottom),
            lower:Math.round(lower),
            hardLower:Math.round(hardLower),
            target:Math.round(target),
            pageAge:Math.round(pageAge),
            viewportH:Math.round(viewportH)
          };
        }
        delta = Math.max(44, Math.min(180, delta));
        var result = crKindleSoftScroll(delta, expectedKey);
        result.followNeeded = true;
        result.followTop = Math.round(top);
        result.followBottom = Math.round(bottom);
        result.followLower = Math.round(lower);
        result.followHardLower = Math.round(hardLower);
        result.followTarget = Math.round(target);
        result.followPageAge = Math.round(pageAge);
        result.viewportH = Math.round(viewportH);
        if (result.ok) window.__crKindleProbe.lastFollowScrollAt = now;
        return result;
      }
      window.__crKindleLiveAdvanceScroll = function(visibleBottomNorm, expectedKey) {
        try {
          expectedKey = String(expectedKey || '');
          var page = crKindleLivePageRect();
          var viewportH = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
          var ordered = orderedCandidates();
          function orderedBrief() {
            return ordered.map(function(x) {
              var top = x && x.rect ? Math.round(Number(x.rect.top || 0)) : 0;
              var bottom = x && x.rect ? Math.round(Number(x.rect.bottom || 0)) : 0;
              return String((x && x.key) || '').slice(0, 24) + ':' + top + '..' + bottom;
            }).slice(0, 10).join('|');
          }
          if (!page || !(page.height > 0)) {
            var fallbackDelta = Math.max(420, Math.floor(viewportH * 0.62));
            var fallback = crKindleSoftScroll(fallbackDelta, '');
            fallback.reason = fallback.reason || 'fallback-no-page';
            fallback.targetKey = fallback.afterKey || '';
            fallback.ordered = orderedBrief();
            return JSON.stringify(fallback);
          }
          var currentTopNorm = Math.max(0, Math.min(1, (0 - Number(page.top || 0)) / Number(page.height || 1)));
          var bottom = Number(visibleBottomNorm);
          var samePage = expectedKey && isFinite(bottom) && bottom < 0.94;
          if (samePage) {
            var remainingNorm = Math.max(0, 1 - bottom);
            var delta = (remainingNorm + 0.04) * Number(page.height || 1);
            if (!(delta > 36)) delta = 64;
            delta = Math.max(44, Math.min(delta, Math.max(96, viewportH * 0.22)));
            var sameResult = crKindleSoftScroll(delta, expectedKey);
            sameResult.mode = 'same-page';
            sameResult.targetKey = expectedKey;
            sameResult.currentTopNorm = Number(currentTopNorm.toFixed(4));
            sameResult.visibleBottomNorm = isFinite(bottom) ? Number(bottom.toFixed(4)) : null;
            sameResult.viewportH = Math.round(viewportH);
            sameResult.pageTop = Math.round(page.top || 0);
            sameResult.pageHeight = Math.round(page.height || 0);
            sameResult.ordered = orderedBrief();
            return JSON.stringify(sameResult);
          }

          var beforeBest = bestCandidate();
          var next = expectedKey ? nextCandidateAfterKey(expectedKey) : null;
          if (next && next.key) {
            scrollCandidateIntoView(next, 'start');
            crKindleUpdateLiveOverlay();
            return JSON.stringify({
              ok:true,
              mode:'next-page',
              expectedKey:expectedKey,
              beforeKey:expectedKey,
              beforeBestKey:(beforeBest && beforeBest.key) || '',
              afterKey:String(next.key || ''),
              targetKey:String(next.key || ''),
              delta:0,
              currentTopNorm:Number(currentTopNorm.toFixed(4)),
              visibleBottomNorm:isFinite(bottom) ? Number(bottom.toFixed(4)) : null,
              viewportH:Math.round(viewportH),
              pageTop:Math.round(page.top || 0),
              pageHeight:Math.round(page.height || 0),
              ordered:orderedBrief()
            });
          }

          var delta = Math.max(120, Math.min(Math.max(180, page.height * 0.22), viewportH * 0.32));
          var result = crKindleSoftScroll(delta, '');
          result.mode = 'next-page';
          result.targetKey = (result.afterKey && result.afterKey !== expectedKey) ? result.afterKey : '';
          result.currentTopNorm = Number(currentTopNorm.toFixed(4));
          result.visibleBottomNorm = isFinite(bottom) ? Number(bottom.toFixed(4)) : null;
          result.viewportH = Math.round(viewportH);
          result.pageTop = Math.round(page.top || 0);
          result.pageHeight = Math.round(page.height || 0);
          result.ordered = orderedBrief();
          return JSON.stringify(result);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), expectedKey:String(expectedKey || '') });
        }
      };
      window.__crKindleLiveClear = function() {
        crKindleRemoveLiveOverlay();
        window.__crKindleProbe.liveParagraphs = [];
        window.__crKindleProbe.liveKey = '';
        window.__crKindleProbe.liveCandidate = null;
        var word = document.getElementById('castreader-kindle-live-word');
        if (word) word.remove();
        var marks = document.getElementById('castreader-kindle-live-marks');
        if (marks) marks.remove();
        return JSON.stringify({ ok:true });
      };
      window.__crKindleLiveRefresh = function() {
        try {
          var expectedKey = String(window.__crKindleProbe.liveKey || '');
          var candidate = crKindleCandidateForKey(expectedKey);
          if (candidate && candidate.rect) crKindleEnsureLiveOverlay(candidate);
          var state = crKindleUpdateLiveOverlay(candidate);
          if (!state || !state.overlay) {
            return JSON.stringify({ ok:false, reason:'captured-page-not-visible', key:expectedKey });
          }
          var ov = state.overlay;
          var ovRect = ov.getBoundingClientRect();
          var imgRect = candidate && candidate.el ? absRect(candidate.el) : null;
          var parentRect = ov.parentElement ? absRect(ov.parentElement) : null;
          var imgOffset = '';
          try {
            if (candidate && candidate.el) {
              imgOffset = [
                Math.round(Number(candidate.el.offsetLeft || 0)),
                Math.round(Number(candidate.el.offsetTop || 0)),
                Math.round(Number(candidate.el.offsetWidth || 0)),
                Math.round(Number(candidate.el.offsetHeight || 0))
              ].join(',');
            }
          } catch (e) {}
          return JSON.stringify({
            ok:true,
            key:expectedKey,
            overlayLeft:Math.round(ovRect.left),
            overlayTop:Math.round(ovRect.top),
            overlayWidth:Math.round(ovRect.width),
            overlayHeight:Math.round(ovRect.height),
            imgRect:imgRect ? [Math.round(imgRect.left), Math.round(imgRect.top), Math.round(imgRect.width), Math.round(imgRect.height)].join(',') : '',
            imgOffset:imgOffset,
            parentRect:parentRect ? [Math.round(parentRect.left), Math.round(parentRect.top), Math.round(parentRect.width), Math.round(parentRect.height)].join(',') : '',
            local:ov.getAttribute('data-cr-local-rect') || '',
            position:ov.getAttribute('data-cr-overlay-position') || ''
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleLiveSetPage = function(payload) {
        try {
          var data = typeof payload === 'string' ? JSON.parse(payload) : payload;
          var key = String((data && data.key) || '');
          var sessionId = Number((data && data.sessionId) || 0);
          var currentSessionId = Number(window.__crKindleProbe.liveSessionId || 0);
          if (sessionId > 0 && currentSessionId > 0 && sessionId !== currentSessionId) {
            return JSON.stringify({ ok:false, reason:'stale-session', key:key, sessionId:sessionId, currentSessionId:currentSessionId });
          }
          var candidate = lockedLiveCandidateForKey(key) || crKindleCandidateForKey(key);
          var fallback = false;
          if ((!candidate || !candidate.rect) && !key) {
            candidate = bestCandidate();
            fallback = true;
          }
          if (!candidate || !candidate.rect) {
            var list = candidates();
            return JSON.stringify({
              ok:false,
              reason:'live-candidate-not-visible',
              key:key,
              candidates:list.map(function(c){ return String(c.key || '').slice(0,24) + ':' + Math.round((c.rect && c.rect.top) || 0) + '/' + Math.round((c.rect && c.rect.height) || 0); }).slice(0,5).join('|')
            });
          }
          var actualKey = String(candidate.key || key || '');
          window.__crKindleProbe.liveKey = actualKey;
          window.__crKindleProbe.liveCandidate = candidate;
          window.__crKindleProbe.liveParagraphs = (data && data.paragraphs) || [];
          window.__crKindleProbe.livePageStartedAt = Date.now();
          window.__crKindleProbe.lastFollowScrollAt = Date.now();
          var imagePixelWidth = Number((data && data.imagePixelWidth) || 0);
          var imagePixelHeight = Number((data && data.imagePixelHeight) || 0);
          window.__crKindleProbe.liveImagePixelSize = (imagePixelWidth > 1 && imagePixelHeight > 1)
            ? { width:imagePixelWidth, height:imagePixelHeight }
            : null;
          crKindleEnsureLiveOverlay(candidate);
          var ov = window.__crKindleProbe.liveOverlay;
          if (ov) {
            ov.textContent = '';
            (window.__crKindleProbe.liveParagraphs || []).forEach(function(para) {
              var norm = crKindleParagraphNormRect(para);
              var pct = crKindleNormRectPercent(norm);
              if (!pct) return;
              var anchor = document.createElement('div');
              anchor.className = 'cr-kindle-live-para-anchor';
              anchor.setAttribute('data-castreader-overlay', 'kindle-para-local');
              anchor.setAttribute('data-cr-paragraph-id', String(para.id));
              anchor.style.cssText =
                'position:absolute;left:' + pct.left + '%;top:' + pct.top + '%;' +
                'width:' + pct.width + '%;height:' + pct.height + '%;' +
                'pointer-events:none;background:transparent;z-index:1;';
              ov.appendChild(anchor);
            });
          }
          var parentTag = '';
          try {
            var p = ov && ov.parentElement;
            parentTag = p ? ((p.tagName || '') + '#' + (p.id || '') + '.' + (p.className || '')) : '';
          } catch (e) {}
          return JSON.stringify({
            ok:true,
            paragraphs:window.__crKindleProbe.liveParagraphs.length,
            key:actualKey,
            requestedKey:key,
            sessionId:currentSessionId,
            fallback:fallback,
            kind:candidate.kind || '',
            rect:candidate.rect,
            imagePixel:window.__crKindleProbe.liveImagePixelSize,
            local:ov ? (ov.getAttribute('data-cr-local-rect') || '') : '',
            position:ov ? (ov.getAttribute('data-cr-overlay-position') || '') : '',
            parent:parentTag
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleLiveHighlightWord = function(paragraphIndex, wordIndex) {
        try {
          var expectedKey = String(window.__crKindleProbe.liveKey || '');
          var candidate = crKindleCandidateForKey(expectedKey);
          var para = crKindleFindLiveParagraph(paragraphIndex);
          if (!para || !para.words || wordIndex < 0 || wordIndex >= para.words.length) return JSON.stringify({ ok:false, reason:'word-not-found' });
          if (candidate && candidate.rect) crKindleEnsureLiveOverlay(candidate);
          var state = crKindleUpdateLiveOverlay(candidate);
          if (!state || state.stale) return JSON.stringify({ ok:false, reason:'captured-page-not-visible', key:expectedKey });
          var word = para.words[wordIndex];
          var viewportRect = crKindleNormRectInViewport(word.bboxNorm);
          var follow = viewportRect ? crKindleLiveFollowRect(viewportRect, expectedKey) : { needed:false, reason:'no-viewport-rect' };
          if (follow && follow.ok) {
            candidate = crKindleCandidateForKey(expectedKey);
            state = crKindleUpdateLiveOverlay(candidate);
          }
          var rect = crKindleNormRectInOverlay(word.bboxNorm);
          var pct = crKindleNormRectPercent(word.bboxNorm);
          if (!rect) return JSON.stringify({ ok:false, reason:'no-page-rect', key:expectedKey });
          if (!pct) return JSON.stringify({ ok:false, reason:'no-page-percent', key:expectedKey });
          var ov = window.__crKindleProbe.liveOverlay;
          if (!ov) return JSON.stringify({ ok:false, reason:'no-overlay', key:expectedKey });
          var div = ov.querySelector('#castreader-kindle-live-word');
          if (!div) {
            div = document.createElement('div');
            div.id = 'castreader-kindle-live-word';
            div.className = 'cr-kindle-live-word';
            div.setAttribute('data-castreader-overlay', 'kindle-word-local');
            ov.appendChild(div);
          }
          div.style.position = 'absolute';
          div.style.left = (rect.left - 2) + 'px';
          div.style.top = (rect.top - 1) + 'px';
          div.style.width = (rect.width + 4) + 'px';
          div.style.height = (rect.height + 2) + 'px';
          div.style.backgroundColor = 'rgba(242,101,34,0.52)';
          div.style.borderRadius = '3px';
          div.style.mixBlendMode = 'normal';
          div.style.transition = 'none';
          div.style.zIndex = '20';
          div.style.opacity = '1';
          div.style.boxShadow = '0 0 0 1px rgba(242,101,34,0.30)';
          div.style.display = 'block';
          div.style.pointerEvents = 'none';
          div.style.transform = 'translateZ(0)';
          div.style.boxSizing = 'border-box';
          try { if (ov.parentElement) ov.parentElement.appendChild(ov); } catch (e) {}
          var ovRect = ov.getBoundingClientRect();
          var divRect = div.getBoundingClientRect();
          var imgRect = candidate && candidate.el ? absRect(candidate.el) : null;
          var parentRect = ov.parentElement ? absRect(ov.parentElement) : null;
          var imgOffset = '';
          try {
            if (candidate && candidate.el) {
              imgOffset = [
                Math.round(Number(candidate.el.offsetLeft || 0)),
                Math.round(Number(candidate.el.offsetTop || 0)),
                Math.round(Number(candidate.el.offsetWidth || 0)),
                Math.round(Number(candidate.el.offsetHeight || 0))
              ].join(',');
            }
          } catch (e) {}
          var pointTag = '';
          var parentTag = '';
          try {
            var cx = ovRect.left + rect.left + rect.width / 2;
            var cy = ovRect.top + rect.top + rect.height / 2;
            var pointEl = document.elementFromPoint(cx, cy);
            pointTag = pointEl ? ((pointEl.tagName || '') + '#' + (pointEl.id || '') + '.' + (pointEl.className || '')) : '';
          } catch (e) {}
          try {
            var p = ov.parentElement;
            parentTag = p ? ((p.tagName || '') + '#' + (p.id || '') + '.' + (p.className || '')) : '';
          } catch (e) {}
          return JSON.stringify({
            ok:true,
            key:expectedKey,
            paragraphIndex:paragraphIndex,
            wordIndex:wordIndex,
            left:Math.round(rect.left),
            top:Math.round(rect.top),
            width:Math.round(rect.width),
            height:Math.round(rect.height),
            screen:[Math.round(divRect.left), Math.round(divRect.top), Math.round(divRect.width), Math.round(divRect.height)].join(','),
            overlayLeft:Math.round(ovRect.left),
            overlayTop:Math.round(ovRect.top),
            overlayWidth:Math.round(ovRect.width),
            overlayHeight:Math.round(ovRect.height),
            imgRect:imgRect ? [Math.round(imgRect.left), Math.round(imgRect.top), Math.round(imgRect.width), Math.round(imgRect.height)].join(',') : '',
            imgOffset:imgOffset,
            parentRect:parentRect ? [Math.round(parentRect.left), Math.round(parentRect.top), Math.round(parentRect.width), Math.round(parentRect.height)].join(',') : '',
            wordText:String(word.text || ''),
            bboxNorm:[Number(word.bboxNorm && word.bboxNorm.x || 0).toFixed(4), Number(word.bboxNorm && word.bboxNorm.y || 0).toFixed(4), Number(word.bboxNorm && word.bboxNorm.width || 0).toFixed(4), Number(word.bboxNorm && word.bboxNorm.height || 0).toFixed(4)].join(','),
            pct:[pct.left.toFixed(2), pct.top.toFixed(2), pct.width.toFixed(2), pct.height.toFixed(2)].join(','),
            follow:follow,
            stale:!!state.stale,
            local:ov.getAttribute('data-cr-local-rect') || '',
            position:ov.getAttribute('data-cr-overlay-position') || '',
            point:pointTag,
            parent:parentTag
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleLiveShowMark = function(payload) {
        try {
          var data = typeof payload === 'string' ? JSON.parse(payload) : payload;
          var expectedKey = String(window.__crKindleProbe.liveKey || '');
          var candidate = crKindleCandidateForKey(expectedKey);
          var para = crKindleFindLiveParagraph(data.paragraphIndex);
          if (!para) return JSON.stringify({ ok:false, reason:'para-not-found' });
          if (candidate && candidate.rect) crKindleEnsureLiveOverlay(candidate);
          var state = crKindleUpdateLiveOverlay(candidate);
          if (!state || state.stale) return JSON.stringify({ ok:false, reason:'captured-page-not-visible', key:expectedKey });
          var layer = window.__crKindleProbe.liveOverlay;
          if (!layer) return JSON.stringify({ ok:false, reason:'no-overlay', key:expectedKey });
          if (data.id && layer.querySelector('[data-cr-mark-id="' + data.id + '"]')) return JSON.stringify({ ok:true, duplicate:true });
          var words = crKindleWordsForRange(para, Number(data.charStart || 0), Number(data.charEnd || 0));
          if (!words.length && para.words) words = para.words;
          var rects = crKindleLineUnions(words.map(function(word) { return crKindleNormRectInOverlay(word.bboxNorm); }).filter(Boolean));
          if (!rects.length) {
            var fallback = crKindleNormRectInOverlay(crKindleParagraphNormRect(para));
            if (fallback) rects = [fallback];
          }
          var group = document.createElement('div');
          group.className = 'cr-kindle-live-mark-group';
          if (data.id) group.setAttribute('data-cr-mark-id', data.id);
          group.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none;';
          layer.appendChild(group);
          rects.forEach(function(rect, i) {
            var d = document.createElement('div');
            var action = String(data.action || 'highlight');
            var css = 'position:absolute;pointer-events:none;';
            if (action === 'underline') {
              css += 'left:' + rect.left + 'px;top:' + (rect.top + rect.height - 3) + 'px;width:' + rect.width + 'px;height:3px;background:rgba(253,95,1,0.88);border-radius:4px;';
            } else if (action === 'circle') {
              css += 'left:' + (rect.left - 5) + 'px;top:' + (rect.top - 4) + 'px;width:' + (rect.width + 10) + 'px;height:' + (rect.height + 8) + 'px;border:3px solid rgba(253,95,1,0.88);border-radius:50%;';
            } else {
              css += 'left:' + (rect.left - 2) + 'px;top:' + (rect.top + rect.height * 0.18) + 'px;width:' + (rect.width + 4) + 'px;height:' + (rect.height * 0.72) + 'px;background:rgba(253,95,1,0.30);border-radius:5px;mix-blend-mode:multiply;';
            }
            d.className = 'cr-kindle-live-mark';
            d.style.cssText = css;
            group.appendChild(d);
          });
          return JSON.stringify({ ok:true, rects:rects.length });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleLiveClearMarks = function() {
        try {
          var layer = window.__crKindleProbe.liveOverlay;
          if (layer) {
            Array.from(layer.querySelectorAll('.cr-kindle-live-mark-group,.cr-kindle-live-mark')).forEach(function(el) { el.remove(); });
          }
          return JSON.stringify({ ok:true });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleLiveScrollToParagraph = function(paragraphIndex) {
        try {
          var expectedKey = String(window.__crKindleProbe.liveKey || '');
          var page = crKindleLivePageRect();
          if (!page) return JSON.stringify({ ok:false, reason:'captured-page-not-visible', key:expectedKey });
          var para = crKindleFindLiveParagraph(paragraphIndex);
          if (!para) return JSON.stringify({ ok:false, reason:'para-not-found' });
          var norm = crKindleParagraphNormRect(para);
          if (!norm) return JSON.stringify({ ok:false, reason:'no-para-rect' });
          var top = page.top + (1 - Number(norm.y || 0) - Number(norm.height || 0)) * page.height;
          var bottom = top + Number(norm.height || 0) * page.height;
          var viewportH = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
          var upper = Math.max(18, viewportH * 0.035);
          var lower = Math.max(upper + 120, viewportH - 36);
          var target = Math.max(upper + 24, viewportH * 0.40);
          var needed = top < upper || bottom > lower;
          var delta = 0;
          if (needed) {
            if (bottom > lower) delta = bottom - lower + 8;
            else if (top < upper) delta = top - target;
          }
          if (Math.abs(delta) < 16) { needed = false; delta = 0; }
          if (!needed) {
            return JSON.stringify({ ok:true, reason:'in-comfort', key:expectedKey, needed:false, top:Math.round(top), bottom:Math.round(bottom), upper:Math.round(upper), lower:Math.round(lower), viewportH:Math.round(viewportH) });
          }
          delta = Math.max(-72, Math.min(72, delta));
          var result = crKindleSoftScroll(delta, expectedKey);
          result.needed = true;
          result.top = Math.round(top);
          result.bottom = Math.round(bottom);
          result.target = Math.round(target);
          result.upper = Math.round(upper);
          result.lower = Math.round(lower);
          result.viewportH = Math.round(viewportH);
          return JSON.stringify(result);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleState = function() {
        var c = currentReadingCandidate();
        return JSON.stringify({
          ok: true,
          key: c && c.key ? c.key : '',
          kind: c && c.kind ? c.kind : '',
          rect: c && c.rect ? { left:Math.round(c.rect.left), top:Math.round(c.rect.top), width:Math.round(c.rect.width), height:Math.round(c.rect.height) } : null,
          visibleArea: c ? (c.visible || 0) : 0,
          bandVisibleArea: c ? (c.bandVisible || 0) : 0,
          heldKeys: window.__crKindleProbe.keyToLiveUrl.size,
          url: location.href,
          title: document.title || ''
        });
      };
    })();
    """
}
