//
//  KindleWebScripts.swift
//  CastReader
//
//  JavaScript helpers for every supported Kindle storefront. Keep selectors broad because Amazon
//  changes Cloud Reader markup often.
//

import Foundation

enum KindleWebScripts {
    static func libraryURL(for storefront: KindleStorefront) -> URL {
        storefront.libraryURL
    }

    /// WKUserScript has no host allow-list. Guard document-start hooks in page
    /// world so Amazon auth pages and unrelated redirect targets are untouched.
    static func restrictedToKnownStorefronts(_ source: String) -> String {
        """
        (function() {
          var __crAllowedKindleHosts = \(KindleStorefront.javaScriptHostArray);
          var __crHost = String(location.hostname || '').toLowerCase();
          if (__crHost.endsWith('.')) __crHost = __crHost.slice(0, -1);
          if (!__crHost || __crHost.endsWith('.') ||
              location.protocol !== 'https:' ||
              (location.port && location.port !== '443') ||
              location.username || location.password ||
              __crAllowedKindleHosts.indexOf(__crHost) < 0) return;
          \(source)
        })();
        """
    }
    static let mobileChromeUserAgent = "Mozilla/5.0 (Linux; Android 14; Mobile) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
    static let desktopChromeUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    /// Kindle localizes visible labels per marketplace. These helpers deliberately
    /// score stable DOM semantics first (`data-*`, id/class, role, geometry).
    /// Text in CastReader's eight non-Chinese app languages is only a fallback.
    private static let uiSemanticHelpers = """
      function crKindleUINorm(value) {
        try {
          value = String(value || '').normalize('NFKC');
        } catch (_) {
          value = String(value || '');
        }
        return value.replace(/\\s+/g, ' ').trim().toLowerCase();
      }
      function crKindleUIStructure(el) {
        if (!el) return '';
        try {
          return crKindleUINorm([
            String(el.tagName || ''),
            el.id || '',
            typeof el.className === 'string' ? el.className : '',
            el.getAttribute && (el.getAttribute('role') || ''),
            el.getAttribute && (el.getAttribute('part') || ''),
            el.getAttribute && (el.getAttribute('name') || ''),
            el.getAttribute && (el.getAttribute('data-testid') || ''),
            el.getAttribute && (el.getAttribute('data-test') || ''),
            el.getAttribute && (el.getAttribute('data-action') || ''),
            el.getAttribute && (el.getAttribute('data-command') || ''),
            el.getAttribute && (el.getAttribute('data-ref') || ''),
            el.getAttribute && (el.getAttribute('data-location') || ''),
            el.getAttribute && (el.getAttribute('data-position') || '')
          ].join(' '));
        } catch (_) { return ''; }
      }
      function crKindleUIText(el) {
        if (!el) return '';
        try {
          return crKindleUINorm([
            el.getAttribute && (el.getAttribute('aria-label') || ''),
            el.getAttribute && (el.getAttribute('title') || ''),
            el.innerText || el.textContent || ''
          ].join(' '));
        } catch (_) { return ''; }
      }
      function crKindleUITextMatches(kind, raw) {
        var text = crKindleUINorm(raw);
        if (!text) return false;
        switch (kind) {
        case 'next':
          return /(?:^|\\s)(?:next(?: page)?|forward|siguiente|página siguiente|próxima página|pagina seguinte|seguinte|次のページ|次へ|nächste seite|weiter|page suivante|suivant|pagina successiva|avanti|अगला पृष्ठ|अगला)(?:$|\\s)/i.test(text);
        case 'previous':
          return /(?:^|\\s)(?:previous(?: page)?|prev|back|anterior|página anterior|pagina anterior|前のページ|前へ|vorherige seite|zurück|page précédente|précédent|pagina precedente|indietro|पिछला पृष्ठ|पिछला)(?:$|\\s)/i.test(text);
        case 'settings':
          return /(?:font|display|appearance|reading settings?|text settings?|fuente|visualización|apariencia|configuración de lectura|fonte|aparência|configurações de leitura|フォント|表示|読書設定|schrift|anzeige|leseeinstellungen|police|affichage|paramètres de lecture|carattere|visualizzazione|impostazioni di lettura|फ़ॉन्ट|प्रदर्शन|पठन सेटिंग)/i.test(text);
        case 'font-size':
          return /(?:font size|preferred font size|tamaño de fuente|tamanho da fonte|フォントサイズ|schriftgröße|taille de police|dimensione carattere|फ़ॉन्ट आकार)/i.test(text);
        case 'single-column':
          return /(?:single column|one column|una columna|columna única|uma coluna|coluna única|1列|一列|単一列|eine spalte|einzelne spalte|une colonne|colonna singola|एक कॉलम)/i.test(text);
        case 'narrow':
          return /(?:^|\\s)(?:narrow|estrecho|estreita|狭い|schmal|étroit|stretto|संकीर्ण)(?:$|\\s)/i.test(text);
        case 'toc':
          return /(?:table of contents|contents|go to|chapter|índice|contenido|capítulo|ir a|sumário|capítulo|ir para|目次|章|移動|inhaltsverzeichnis|kapitel|gehe zu|table des matières|sommaire|chapitre|indice|sommario|capitolo|विषय सूची|अध्याय)/i.test(text);
        case 'close':
          return /^(?:close|done|dismiss|cerrar|listo|hecho|fechar|concluído|閉じる|完了|schließen|fertig|fermer|terminé|chiudi|fatto|बंद|पूर्ण)$/i.test(text);
        case 'yes':
          return /^(?:yes|ok|go|continue|sí|aceptar|continuar|ir|sim|continuar|ir|はい|移動|続行|ja|ok|weiter|los|oui|continuer|aller|sì|continua|vai|हाँ|ठीक|जारी रखें|जाएं)$/i.test(text);
        case 'no':
          return /^(?:no|cancel|stay|cancelar|quedarse|não|cancelar|ficar|いいえ|キャンセル|このまま|nein|abbrechen|bleiben|non|annuler|rester|no|annulla|resta|नहीं|रद्द|यहीं रहें)$/i.test(text);
        case 'location':
          return /(?:location|page|position|ubicación|posición|página|localização|posição|página|位置|ページ|position|seite|emplacement|page|posizione|pagina|स्थान|पृष्ठ)/i.test(text);
        case 'sync-dialog':
          return /(?:most recent (?:page|location) read|furthest (?:page|location) read|ubicación (?:leída )?más reciente|posición (?:leída )?más reciente|página (?:leída )?más reciente|última (?:página|posición) leída|localização (?:lida )?mais recente|posição (?:lida )?mais recente|página lida mais recentemente|última página lida|最後に読んだ(?:ページ|位置)|最も遠い(?:ページ|位置)|前回読んだ(?:ページ|位置)|最新の(?:ページ|位置)|zuletzt gelesene (?:seite|position)|letzte leseposition|am weitesten gelesene (?:seite|position)|page (?:lue )?la plus récente|emplacement (?:lu )?le plus récent|dernière (?:page|position) (?:de lecture|lue)|pagina (?:letta )?più recente|posizione (?:letta )?più recente|ultima (?:pagina|posizione) letta|सबसे हाल में पढ़ा (?:गया )?(?:पृष्ठ|स्थान)|हाल ही में पढ़ा (?:गया )?(?:पृष्ठ|स्थान)|अंतिम पठन स्थान|सबसे आगे पढ़ा (?:गया )?(?:पृष्ठ|स्थान))/i.test(text);
        default:
          return false;
        }
      }
      function crKindleUIStructureScore(el, kind) {
        if (!el) return 0;
        var token = crKindleUIStructure(el);
        var role = crKindleUINorm(el.getAttribute && (el.getAttribute('role') || ''));
        var score = 0;
        if (kind === 'next' && /(?:^|[-_\\s])(next|forward|chevron[-_\\s]?right|page[-_\\s]?right)(?:$|[-_\\s])/.test(token)) score += 180;
        if (kind === 'previous' && /(?:^|[-_\\s])(previous|prev|back|chevron[-_\\s]?left|page[-_\\s]?left)(?:$|[-_\\s])/.test(token)) score += 180;
        if (kind === 'settings' && /setting|preference|appearance|display|font|typograph|reader[-_\\s]?option/.test(token)) score += 170;
        if (kind === 'font-size' && /font[-_\\s]*size|text[-_\\s]*size|typograph.*size/.test(token)) score += 180;
        if (kind === 'single-column' && /single.*column|one.*column|column.*single|layout.*one/.test(token)) score += 180;
        if (kind === 'narrow' && /narrow|compact.*margin|margin.*compact|small.*margin|width.*narrow/.test(token)) score += 180;
        if (kind === 'toc' && /(?:^|[-_\\s])toc(?:$|[-_\\s])|table.*content|content.*list|chapter.*list|navigation.*list|go[-_\\s]?to/.test(token)) score += 180;
        if (kind === 'close' && /close|dismiss|dialog.*cancel|modal.*cancel|done/.test(token)) score += 180;
        if (kind === 'yes' && /confirm|accept|positive|continue|go[-_\\s]?to|sync.*yes|primary/.test(token)) score += 160;
        if (kind === 'no' && /reject|decline|negative|cancel|stay|sync.*no|secondary/.test(token)) score += 160;
        if (kind === 'location' && /location|position|progress|page[-_\\s]?(?:number|index)/.test(token)) score += 170;
        if (kind === 'sync-dialog' && /whisper|sync.*dialog|position.*dialog|location.*dialog|furthest.*read|recent.*read/.test(token)) score += 190;
        if ((kind === 'next' || kind === 'previous' || kind === 'settings' || kind === 'close' || kind === 'yes' || kind === 'no') &&
            /button|menuitem|option/.test(role + ' ' + token)) score += 12;
        if (kind === 'toc' && /navigation|tree|menu/.test(role)) score += 28;
        if (kind === 'sync-dialog' && role === 'dialog') score += 35;
        if ((kind === 'next' || kind === 'previous') && score < 100) {
          try {
            var rect = el.getBoundingClientRect();
            var parentToken = crKindleUIStructure(el.parentElement) + ' ' + crKindleUIStructure(el.parentElement && el.parentElement.parentElement);
            var edgeControl = /pagination|page[-_\\s]?control|reader[-_\\s]?(?:control|nav)|chevron/.test(parentToken + ' ' + token);
            var viewportWidth = innerWidth || document.documentElement.clientWidth || 0;
            if (edgeControl && rect.width >= 18 && rect.height >= 18) {
              if (kind === 'previous' && rect.left <= Math.max(96, viewportWidth * 0.18)) score += 120;
              if (kind === 'next' && rect.right >= viewportWidth - Math.max(96, viewportWidth * 0.18)) score += 120;
            }
          } catch (_) {}
        }
        return score;
      }
      function crKindleUISemanticScore(el, kind) {
        var structural = crKindleUIStructureScore(el, kind);
        var text = crKindleUIText(el);
        if (crKindleUITextMatches(kind, text)) structural += 45;
        return structural;
      }
      function crKindleUIIsVisible(el) {
        if (!el || !el.getBoundingClientRect) return false;
        try {
          var rect = el.getBoundingClientRect();
          var style = getComputedStyle(el);
          return style.display !== 'none' && style.visibility !== 'hidden' &&
            Number(style.opacity || 1) > 0 && rect.width > 2 && rect.height > 2;
        } catch (_) { return false; }
      }
      function crKindleUIFind(kind, root, selector) {
        root = root || document;
        selector = selector || 'button,[role="button"],[role="option"],[role="radio"],[role="menuitem"],ion-button,ion-item,[data-testid],[data-action],[aria-label],[title]';
        var nodes = [];
        try { nodes = Array.from(root.querySelectorAll(selector)); } catch (_) {}
        return nodes.map(function(el) {
          return { el:el, score:crKindleUISemanticScore(el, kind) };
        }).filter(function(item) {
          return item.score >= 45 && crKindleUIIsVisible(item.el);
        }).sort(function(a, b) {
          return b.score - a.score;
        })[0] || null;
      }
      function crKindleUINormalizeDigits(value) {
        var sets = ['０１２３４５６７８９','०१२३४५६७८९','٠١٢٣٤٥٦٧٨٩','۰۱۲۳۴۵۶۷۸۹'];
        return String(value || '').replace(/[０-９०-९٠-٩۰-۹]/g, function(ch) {
          for (var i = 0; i < sets.length; i++) {
            var index = sets[i].indexOf(ch);
            if (index >= 0) return String(index);
          }
          return ch;
        });
      }
    """

    static let readerLayoutProbe = """
    (function() {
      \(uiSemanticHelpers)
      function count(sel) {
        try { return document.querySelectorAll(sel).length; } catch (_) { return -1; }
      }
      function textOf(el) {
        try {
          return [
            el.getAttribute && (el.getAttribute('aria-label') || ''),
            el.getAttribute && (el.getAttribute('title') || ''),
            el.getAttribute && (el.getAttribute('data-testid') || ''),
            el.id || '',
            el.className || '',
            (el.innerText || '').slice(0, 80)
          ].join(' ').trim();
        } catch (_) {
          return '';
        }
      }
      var controls = [];
      try {
        Array.from(document.querySelectorAll('button,[role="button"],[aria-label],[title]')).slice(0, 240).forEach(function(el) {
          var label = textOf(el);
          var nextScore = crKindleUISemanticScore(el, 'next');
          var previousScore = crKindleUISemanticScore(el, 'previous');
          if (Math.max(nextScore, previousScore) >= 45) {
            var r = el.getBoundingClientRect ? el.getBoundingClientRect() : null;
            controls.push({
              label:label.slice(0, 140),
              semantic:nextScore > previousScore ? 'next' : 'previous',
              structuralScore:Math.max(
                crKindleUIStructureScore(el, 'next'),
                crKindleUIStructureScore(el, 'previous')
              ),
              left:r ? Math.round(r.left) : 0,
              top:r ? Math.round(r.top) : 0,
              width:r ? Math.round(r.width) : 0,
              height:r ? Math.round(r.height) : 0
            });
          }
        });
      } catch (_) {}
      return JSON.stringify({
        ok:true,
        ua:navigator.userAgent || '',
        viewport:{ width:Math.round(innerWidth || 0), height:Math.round(innerHeight || 0) },
        blobImages:count('img[src^="blob:"]'),
        fullPageImages:count('.kg-full-page-img, .kg-full-page-img img'),
        scrollRunways:count('[class*="kg-scroll-runway"], .kg-scroll-runway'),
        columns:count('#column_0,#column_1,[id^="column_"]'),
        pageControls:controls.slice(0, 12),
        url:location.href,
        title:document.title || ''
      });
    })();
    """

    static let applyReaderPreferences = """
    (function() {
      \(uiSemanticHelpers)
      window.__crKindlePrefs = window.__crKindlePrefs || { applied:false, attempts:0 };
      window.__crKindlePrefs.attempts += 1;

      function isVisible(el) {
        if (!el) return false;
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 2 && rect.height > 2;
        } catch (_) {
          return false;
        }
      }
      function labelOf(el) {
        try {
          return [
            el.getAttribute && (el.getAttribute('aria-label') || ''),
            el.getAttribute && (el.getAttribute('title') || ''),
            el.getAttribute && (el.getAttribute('data-testid') || ''),
            (el.innerText || el.textContent || '')
          ].join(' ').replace(/\\s+/g, ' ').trim();
        } catch (_) {
          return '';
        }
      }
      function clickElement(el) {
        if (!el) return false;
        try {
          var target = el.closest && el.closest('button,[role="button"],ion-button,span,div') || el;
          var rect = target.getBoundingClientRect ? target.getBoundingClientRect() : null;
          var opts = rect ? {
            clientX: rect.left + rect.width / 2,
            clientY: rect.top + rect.height / 2,
            bubbles: true,
            cancelable: true
          } : { bubbles:true, cancelable:true };
          try { target.dispatchEvent(new PointerEvent('pointerdown', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mousedown', opts)); } catch (_) {}
          try { target.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mouseup', opts)); } catch (_) {}
          try { target.click(); } catch (_) { target.dispatchEvent(new MouseEvent('click', opts)); }
          return true;
        } catch (_) {
          return false;
        }
      }
      function findExactAria(value) {
        var wanted = String(value || '').toLowerCase();
        var nodes = Array.from(document.querySelectorAll('[aria-label],button,[role="button"],span,div'));
        for (var i = 0; i < nodes.length; i++) {
          var el = nodes[i];
          if (!isVisible(el)) continue;
          var aria = String((el.getAttribute && el.getAttribute('aria-label')) || '').trim().toLowerCase();
          var text = String((el.innerText || el.textContent || '')).replace(/\\s+/g, ' ').trim().toLowerCase();
          if (aria === wanted || text === wanted) return el;
        }
        return null;
      }
      function findSettingsButton() {
        var exact = Array.from(document.querySelectorAll('button,[role="button"],ion-button,span,div')).filter(isVisible);
        for (var i = 0; i < exact.length; i++) {
          var glyph = String(exact[i].innerText || exact[i].textContent || '').replace(/\\s+/g, '').trim();
          if (/^aa$/i.test(glyph) && glyph.length === 2) return exact[i];
        }
        var semantic = crKindleUIFind(
          'settings',
          document,
          'button,[role="button"],ion-button,[data-testid],[data-action],[aria-label],[title]'
        );
        if (semantic && crKindleUISemanticScore(semantic.el, 'font-size') < semantic.score) {
          return semantic.el;
        }
        return null;
      }
      function findFontSizeRange() {
        var nodes = Array.from(document.querySelectorAll('ion-range,[role="slider"],input[type="range"]')).filter(isVisible);
        var ranked = nodes.map(function(el) {
          return { el:el, score:crKindleUISemanticScore(el, 'font-size') };
        }).sort(function(a, b) { return b.score - a.score; });
        if (ranked.length && ranked[0].score >= 45) return ranked[0].el;
        // A single visible range inside the already-open settings surface is a
        // stable structural fallback even when Amazon strips every label.
        return nodes.length === 1 ? nodes[0] : null;
      }
      function findReaderOption(kind) {
        var selector = 'button,[role="button"],[role="radio"],[role="option"],ion-button,ion-item,[aria-checked],[aria-selected],[data-testid],[data-action]';
        var match = crKindleUIFind(kind, document, selector);
        return match ? match.el : null;
      }
      function setRangeValue(range, desiredRatio) {
        if (!range) return { ok:false, reason:'range-not-found' };
        try {
          var minRaw = range.getAttribute('min');
          var maxRaw = range.getAttribute('max');
          var min = minRaw == null || minRaw === '' ? 0 : Number(minRaw);
          var max = maxRaw == null || maxRaw === '' ? 10 : Number(maxRaw);
          if (!Number.isFinite(min)) min = 0;
          if (!Number.isFinite(max) || max <= min) max = 10;
          var target = min + (max - min) * desiredRatio;
          var stepRaw = range.getAttribute('step');
          var step = stepRaw == null || stepRaw === '' ? 1 : Number(stepRaw);
          if (Number.isFinite(step) && step > 0) {
            target = Math.round(target / step) * step;
          }
          target = Math.max(min, Math.min(max, target));
          var oldValue = range.value;
          try { range.value = target; } catch (_) {}
          try { range.setAttribute('value', String(target)); } catch (_) {}
          var detail = { value: target };
          try { range.dispatchEvent(new CustomEvent('ionInput', { bubbles:true, cancelable:true, detail:detail })); } catch (_) {}
          try { range.dispatchEvent(new CustomEvent('ionChange', { bubbles:true, cancelable:true, detail:detail })); } catch (_) {}
          try { range.dispatchEvent(new Event('input', { bubbles:true, cancelable:true })); } catch (_) {}
          try { range.dispatchEvent(new Event('change', { bubbles:true, cancelable:true })); } catch (_) {}
          return { ok:true, oldValue:oldValue, value:target, min:min, max:max };
        } catch (e) {
          return { ok:false, reason:String(e && e.message || e) };
        }
      }
      function bumpFontSize(times) {
        var button = findExactAria('Increase font size');
        var clicks = 0;
        for (var i = 0; i < times; i++) {
          if (clickElement(button)) clicks += 1;
        }
        return { ok:clicks > 0, clicks:clicks };
      }
      function settingsMenuOpen() {
        var menus = Array.from(document.querySelectorAll('ion-menu,[aria-label="menu"],[role="menu"],[role="dialog"],.popover-content,.modal-wrapper'));
        for (var i = 0; i < menus.length; i++) {
          if (!isVisible(menus[i])) continue;
          var semanticScore = crKindleUIStructureScore(menus[i], 'settings');
          var controls = menus[i].querySelectorAll('ion-range,[role="slider"],input[type="range"],[role="radio"],[aria-checked],ion-segment-button').length;
          if (semanticScore >= 100 || controls >= 2 ||
              (controls >= 1 && crKindleUITextMatches('settings', crKindleUIText(menus[i])))) {
            return true;
          }
        }
        var settingsButton = findSettingsButton();
        return !!(settingsButton &&
          String(settingsButton.getAttribute && settingsButton.getAttribute('aria-expanded') || '').toLowerCase() === 'true');
      }
      function closeSettingsMenu() {
        var closeMatch = crKindleUIFind(
          'close',
          document,
          'button,[role="button"],ion-button,[data-testid],[data-action],[part],[aria-label],[title]'
        );
        var close = closeMatch && closeMatch.el;
        if (clickElement(close)) return 'close-button';
        try {
          document.dispatchEvent(new KeyboardEvent('keydown', { key:'Escape', code:'Escape', keyCode:27, which:27, bubbles:true, cancelable:true }));
        } catch (_) {}
        var aa = findSettingsButton();
        if (clickElement(aa)) return 'aa-toggle';
        return '';
      }

      var hasNext = !!crKindleUIFind('next', document);
      var hasPrev = !!crKindleUIFind('previous', document);
      var menuWasOpen = settingsMenuOpen();
      if (!menuWasOpen) {
        var aaButton = findSettingsButton();
        var opened = clickElement(aaButton);
        return JSON.stringify({
          ok:false,
          stage:opened ? 'opening-settings' : 'settings-button-not-found',
          opened:opened,
          hasNext:hasNext,
          hasPrev:hasPrev,
          attempts:window.__crKindlePrefs.attempts,
          ua:navigator.userAgent || '',
          url:location.href
        });
      }

      var single = findReaderOption('single-column');
      var narrow = findReaderOption('narrow');
      var singleClicked = clickElement(single);
      var narrowClicked = clickElement(narrow);
      var fontSize = { ok:false, reason:'not-forced' };
      var fontBump = { ok:false, clicks:0, reason:'not-forced' };
      window.__crKindlePrefs.applied = singleClicked || narrowClicked || window.__crKindlePrefs.applied;
      var closeMode = closeSettingsMenu();
      return JSON.stringify({
        ok:!!window.__crKindlePrefs.applied,
        stage:'applied-reader-preferences',
        singleClicked:singleClicked,
        narrowClicked:narrowClicked,
        fontSize:fontSize,
        fontBump:fontBump,
        closeMode:closeMode,
        hasNext:hasNext,
        hasPrev:hasPrev,
        attempts:window.__crKindlePrefs.attempts,
        ua:navigator.userAgent || '',
        url:location.href
      });
    })();
    """

    /// Mirrors the extension's renderer-metadata authority in Kindle's page world.
    /// Only the small normalized profile is retained; renderer text/TAR data never crosses the bridge.
    static let metadataBootstrap = """
    (function() {
      if (window.__crKindleMetadataInstalled === 3) return;
      window.__crKindleMetadataInstalled = 3;
      var PROFILE_ATTR = 'data-castreader-kindle-profile';
      var LANGUAGE_KEYS = /^(?:lang|language|languageCode|bookLanguage|bookLocale|contentLanguage|contentLocale|locale)$/i;
      var WRITING_KEYS = /^(?:writingMode|writingOrientation|textOrientation)$/i;
      var READING_KEYS = /^(?:pageProgressionDirection|readingDirection|pageTurnDirection|direction)$/i;
      var PROGRESSION_KEYS = /^(?:pageProgressionDirection|pageTurnDirection)$/i;

      function normalizedKey(key) { return String(key || '').replace(/[-_]/g, ''); }
      function findMetadataString(value, pattern, depth, seen) {
        if (!value || typeof value !== 'object' || depth > 5) return null;
        seen = seen || [];
        if (seen.indexOf(value) >= 0) return null;
        seen.push(value);
        var keys;
        try { keys = Object.keys(value); } catch (e) { return null; }
        for (var i = 0; i < keys.length; i++) {
          var child;
          try { child = value[keys[i]]; } catch (e) { continue; }
          if (pattern.test(normalizedKey(keys[i])) && typeof child === 'string' && child.trim()) return child;
        }
        for (var j = 0; j < keys.length; j++) {
          var nested;
          try { nested = value[keys[j]]; } catch (e) { continue; }
          var found = findMetadataString(nested, pattern, depth + 1, seen);
          if (found) return found;
        }
        return null;
      }
      function normalizeLanguage(value) {
        var primary = String(value || '').trim().toLowerCase().replace(/_/g, '-').split('-')[0];
        var aliases = { eng:'en', zho:'zh', chi:'zh', jpn:'ja', spa:'es', fra:'fr', fre:'fr', deu:'de', ger:'de', por:'pt', ita:'it', hin:'hi' };
        primary = aliases[primary] || primary;
        return /^(?:en|zh|ja|es|fr|de|pt|it|hi)$/.test(primary) ? primary : null;
      }
      function direction(value) {
        if (/rtl|right[-_ ]?to[-_ ]?left|horizontal-rl|vertical-rl/i.test(value || '')) return 'rtl';
        if (/ltr|left[-_ ]?to[-_ ]?right|horizontal-lr|vertical-lr/i.test(value || '')) return 'ltr';
        return null;
      }
      function publish(metadata) {
        var language = normalizeLanguage(findMetadataString(metadata, LANGUAGE_KEYS, 0, []));
        if (!language) return null;
        var writingRaw = findMetadataString(metadata, WRITING_KEYS, 0, []);
        var readingRaw = findMetadataString(metadata, READING_KEYS, 0, []);
        var progressionRaw = findMetadataString(metadata, PROGRESSION_KEYS, 0, []);
        var profile = {
          language: language,
          writingMode: /vertical|tb-rl|tb-lr/i.test(writingRaw || '') ? 'vertical' : 'horizontal',
          readingDirection: direction(readingRaw) || (language === 'ja' ? 'rtl' : 'ltr'),
          pageProgressionDirection: direction(progressionRaw) || (language === 'ja' ? 'rtl' : 'ltr'),
          source: 'renderer-metadata'
        };
        window.__crKindleMetadataProfile = profile;
        try {
          if (document.documentElement) document.documentElement.setAttribute(PROFILE_ATTR, JSON.stringify(profile));
        } catch (e) {}
        return profile;
      }
      function parseTar(buffer) {
        var view = new Uint8Array(buffer), offset = 0, files = [];
        while (offset + 512 <= view.length) {
          var nameEnd = offset;
          while (nameEnd < offset + 100 && view[nameEnd] !== 0) nameEnd++;
          var filename = new TextDecoder().decode(view.slice(offset, nameEnd));
          if (!filename) break;
          var sizeStr = '';
          for (var i = offset + 124; i < offset + 136; i++) {
            var ch = view[i];
            if (ch === 0 || ch === 32) break;
            sizeStr += String.fromCharCode(ch);
          }
          var size = parseInt(sizeStr, 8) || 0;
          var start = offset + 512, end = start + size;
          if (size > 0 && end <= view.length && /\\.json$/i.test(filename)) {
            try {
              files.push({ name:filename, value:JSON.parse(new TextDecoder().decode(view.slice(start, end))) });
            } catch (e) {}
          }
          offset = start + Math.ceil(size / 512) * 512;
        }
        return files;
      }
      function median(values) {
        values = values.filter(Number.isFinite).sort(function(a,b){ return a-b; });
        if (!values.length) return 0;
        var middle = Math.floor(values.length / 2);
        return values.length % 2 ? values[middle] : (values[middle - 1] + values[middle]) / 2;
      }
      function overlapRatio(aStart, aSize, bStart, bSize) {
        var smaller = Math.min(aSize, bSize);
        if (!(smaller > 0)) return 0;
        return Math.max(0, Math.min(aStart + aSize, bStart + bSize) - Math.max(aStart, bStart)) / smaller;
      }
      function inferTokenWritingMode(blocks) {
        var horizontal = 0, vertical = 0;
        (blocks || []).forEach(function(block) {
          var width = Number(block && block.width), height = Number(block && block.height);
          if (!(width > 0) || !(height > 0)) return;
          var ratio = width / height;
          if (ratio >= 2.5) horizontal++;
          else if (ratio <= 0.4) vertical++;
        });
        if (!horizontal && !vertical) return null;
        if (horizontal >= Math.max(1, vertical * 2)) return 'horizontal';
        if (vertical >= Math.max(1, horizontal * 2)) return 'vertical';
        return null;
      }
      function groupVerticalTokenWords(entries) {
        if (!entries.length) return [];
        var typical = Math.max(1, median(entries.map(function(entry){ return entry.width; })));
        var groups = [];
        entries.forEach(function(entry) {
          var center = entry.x + entry.width / 2, best = null, bestDelta = Infinity;
          groups.forEach(function(group) {
            var centers = group.map(function(item){ return item.x + item.width / 2; });
            var sizes = group.map(function(item){ return item.width; });
            var groupCenter = median(centers), size = Math.max(1, median(sizes));
            var delta = Math.abs(center - groupCenter);
            var close = delta <= typical * 0.65;
            var overlaps = overlapRatio(entry.x, entry.width, groupCenter - size / 2, size) >= 0.5 && delta <= typical;
            if ((close || overlaps) && delta < bestDelta) { best = group; bestDelta = delta; }
          });
          if (best) best.push(entry); else groups.push([entry]);
        });
        groups.forEach(function(group){ group.sort(function(a,b){ return a.y-b.y; }); });
        return groups;
      }
      function buildVerticalTokenHints(page) {
        var blocks = page && page.children || [];
        if (!blocks.length) return [];
        var maxRight = Math.max.apply(null, blocks.map(function(block){ return Number(block.x) + Number(block.width); }));
        var minX = Math.min.apply(null, blocks.map(function(block){ return Number(block.x); }));
        var maxBottom = Math.max.apply(null, blocks.map(function(block){ return Number(block.y) + Number(block.height); }));
        var minY = Math.min.apply(null, blocks.map(function(block){ return Number(block.y); }));
        var pageWidth = maxRight + minX, pageHeight = maxBottom + minY;
        if (!(pageWidth > 0) || !(pageHeight > 0)) return [];
        var entries = [];
        blocks.forEach(function(block) {
          (block.words || []).forEach(function(word) {
            var x = Number(word.x), y = Number(word.y), width = Number(word.width), height = Number(word.height);
            if (!Number.isFinite(x) || !Number.isFinite(y) || !(width > 0) || !(height > 0)) return;
            entries.push({
              x:x, y:y, width:width, height:height,
              startPositionId:Number(word.startPositionId), endPositionId:Number(word.endPositionId)
            });
          });
        });
        return groupVerticalTokenWords(entries).map(function(column) {
          var left = Math.max(0, Math.min.apply(null, column.map(function(item){ return item.x; })));
          var right = Math.min(pageWidth, Math.max.apply(null, column.map(function(item){ return item.x + item.width; })));
          var top = Math.max(0, Math.min.apply(null, column.map(function(item){ return item.y; })));
          var bottom = Math.min(pageHeight, Math.max.apply(null, column.map(function(item){ return item.y + item.height; })));
          var spans = column.map(function(item){
            return { start:item.startPositionId, end:Math.max(item.startPositionId, item.endPositionId) };
          }).filter(function(span){ return Number.isFinite(span.start) && Number.isFinite(span.end); })
            .sort(function(a,b){ return a.start-b.start; });
          var merged = [];
          spans.forEach(function(span) {
            var previous = merged[merged.length - 1];
            if (previous && span.start <= previous.end + 1) previous.end = Math.max(previous.end, span.end);
            else merged.push({ start:span.start, end:span.end });
          });
          return {
            leftRatio:left/pageWidth, rightRatio:right/pageWidth,
            topRatio:top/pageHeight, bottomRatio:bottom/pageHeight,
            expectedCharacters:merged.reduce(function(sum, span){ return sum + Math.max(1, span.end-span.start+1); }, 0),
            startPositionId:merged.length ? merged[0].start : null,
            endPositionId:merged.length ? merged[merged.length - 1].end : null
          };
        }).filter(function(hint){ return hint.rightRatio-hint.leftRatio > 0.001; })
          .sort(function(a,b){
            var ap = Number.isFinite(a.startPositionId) ? a.startPositionId : Number.MAX_SAFE_INTEGER;
            var bp = Number.isFinite(b.startPositionId) ? b.startPositionId : Number.MAX_SAFE_INTEGER;
            return ap-bp || b.leftRatio-a.leftRatio;
          });
      }
      function startingPosition(url, options) {
        try {
          var parsed = new URL(url, location.href);
          var value = parsed.searchParams.get('startingPosition');
          if (value && Number.isFinite(Number(value))) return Number(value);
        } catch (e) {}
        try {
          var body = options && options.body;
          if (typeof body === 'string') {
            var match = body.match(/(?:startingPosition|starting_position)[^0-9-]*(-?[0-9]+)/i);
            if (match) return Number(match[1]);
          }
        } catch (e) {}
        return null;
      }
      function publishRendererFiles(files, url, options) {
        var profile = publish({ files:files.map(function(file){ return file.value; }) });
        var tokenFile = files.find(function(file){ return /(?:^|\\/)tokens[^/]*\\.json$/i.test(file.name); });
        var pages = tokenFile && Array.isArray(tokenFile.value) ? tokenFile.value : [];
        if (!profile || !pages.length) return profile;
        var start = startingPosition(url, options);
        var page = pages.find(function(candidate) {
          var children = candidate && candidate.children || [];
          if (!children.length || !Number.isFinite(start)) return false;
          var min = Math.min.apply(null, children.map(function(block){ return Number(block.startPositionId); }));
          var max = Math.max.apply(null, children.map(function(block){ return Number(block.endPositionId); }));
          return start >= min && start <= max;
        }) || pages[0];
        var geometryMode = inferTokenWritingMode(page && page.children || []);
        if (geometryMode) {
          profile.writingMode = geometryMode;
          profile.writingModeSource = 'token-geometry';
        }
        profile.verticalColumnHints = geometryMode === 'vertical' ? buildVerticalTokenHints(page) : [];
        profile.tokenPageIndex = Number(page && page.pageIndex);
        window.__crKindleMetadataProfile = profile;
        try {
          if (document.documentElement) document.documentElement.setAttribute(PROFILE_ATTR, JSON.stringify(profile));
        } catch (e) {}
        return profile;
      }
      window.__crKindleExtractMetadataProfile = publish;
      window.__crKindleExtractRendererFiles = publishRendererFiles;
      window.__crKindleReadMetadataProfile = function() {
        if (window.__crKindleMetadataProfile) return window.__crKindleMetadataProfile;
        try {
          var raw = document.documentElement && document.documentElement.getAttribute(PROFILE_ATTR);
          return raw ? JSON.parse(raw) : null;
        } catch (e) { return null; }
      };
      var originalFetch = window.fetch;
      if (typeof originalFetch === 'function') {
        window.fetch = async function() {
          var args = Array.prototype.slice.call(arguments);
          var response = await originalFetch.apply(this, args);
          try {
            var url = args[0] instanceof Request ? args[0].url : String(args[0] || '');
            if (url.indexOf('/renderer/render') >= 0) {
              response.clone().arrayBuffer().then(function(buffer) {
                var files = parseTar(buffer);
                publishRendererFiles(files, url, args[1]);
              }).catch(function() {});
            }
          } catch (e) {}
          return response;
        };
      }
    })();
    """

    static let readMetadataProfile = """
    (function() {
      try {
        var profile = typeof window.__crKindleReadMetadataProfile === 'function'
          ? window.__crKindleReadMetadataProfile() : null;
        return profile ? JSON.stringify(profile) : '';
      } catch (e) { return ''; }
    })();
    """

    static let scrapeLibrary = """
    (function() {
      var kindleHosts = \(KindleStorefront.javaScriptHostArray);
      var canonicalHostByAlias = \(KindleStorefront.javaScriptCanonicalHostMap);
      function normalizedKindleHost(host) {
        host = String(host || '').toLowerCase();
        if (host.endsWith('.')) host = host.slice(0, -1);
        if (!host || host.endsWith('.')) return '';
        return host;
      }
      function isKindleHost(host) {
        host = normalizedKindleHost(host);
        return kindleHosts.indexOf(host) >= 0;
      }
      function secureKindleURL(raw) {
        try {
          var url = new URL(raw, location.href);
          if (url.protocol !== 'https:' || url.username || url.password) return null;
          if (url.port && url.port !== '443') return null;
          return isKindleHost(url.hostname) ? url : null;
        } catch (_) {
          return null;
        }
      }
      function text(el) { return (el && (el.innerText || el.textContent) || '').replace(/\\s+/g, ' ').trim(); }
      function attr(el, name) { try { return el ? (el.getAttribute(name) || '') : ''; } catch (e) { return ''; } }
      function normalizedDigits(value) {
        var sets = ['０１２３４５６７８９','०१२३४५६७८९','٠١٢٣٤٥٦٧٨٩','۰۱۲۳۴۵۶۷۸۹'];
        return String(value || '').replace(/[０-９०-९٠-٩۰-۹]/g, function(ch) {
          for (var i = 0; i < sets.length; i++) {
            var index = sets[i].indexOf(ch);
            if (index >= 0) return String(index);
          }
          return ch;
        });
      }
      function abs(url) {
        if (!url) return '';
        try { return new URL(url, location.href).href; } catch (e) { return url || ''; }
      }
      function readerURLForASIN(asin) {
        var currentHost = normalizedKindleHost(location.hostname);
        var canonicalHost = canonicalHostByAlias[currentHost] || '';
        var normalizedASIN = String(asin || '').trim().toUpperCase();
        if (!canonicalHost || !/^[A-Z0-9]{10}$/.test(normalizedASIN)) return '';
        var url = new URL('https://' + canonicalHost + '/');
        url.searchParams.set('asin', normalizedASIN);
        url.searchParams.set('ref_', '\(KindleStorefront.readerReferenceValue)');
        return url.href;
      }
      function bareKindleRoot(href) {
        href = abs(href);
        if (!href) return false;
        try {
          var u = secureKindleURL(href);
          if (!u) return false;
          var path = String(u.pathname || '').replace(/^\\/+|\\/+$/g, '');
          return !path && !u.search && !u.hash;
        } catch (e) {
          return false;
        }
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
      function hasExplicitEmptyShelfSignal() {
        try {
          var activeSearch = Array.from(document.querySelectorAll('input[type="search"], input[role="searchbox"]'))
            .some(function(input) { return visible(input) && String(input.value || '').trim().length > 0; });
          if (activeSearch) return false;
        } catch (_) {}
        // An empty result is destructive evidence: it may clear a previously
        // cached shelf. Accept only normalized, complete empty-state copy.
        // Substring matching is deliberately forbidden because help text such
        // as "If your library is empty, ..." is not shelf state.
        var emptyCopies = [
          'your library is empty',
          'no books in your library',
          'you do not have any books',
          "you don't have any books",
          'tu biblioteca está vacía',
          'no hay libros en tu biblioteca',
          'no tienes libros',
          'sua biblioteca está vazia',
          'não há livros na sua biblioteca',
          'nenhum livro na sua biblioteca',
          'ライブラリに本がありません',
          'ライブラリは空',
          '本はありません',
          'deine bibliothek ist leer',
          'ihre bibliothek ist leer',
          'keine bücher in deiner bibliothek',
          'keine bücher in ihrer bibliothek',
          'votre bibliothèque est vide',
          'aucun livre dans votre bibliothèque',
          "vous n'avez aucun livre",
          'la tua libreria è vuota',
          'la tua biblioteca è vuota',
          'nessun libro nella tua libreria',
          'non hai libri',
          'आपकी लाइब्रेरी खाली है',
          'आपकी लाइब्रेरी में कोई किताब नहीं',
          'आपकी लाइब्रेरी में कोई पुस्तक नहीं',
          'कोई पुस्तक नहीं'
        ];
        function normalizedEmptyCopy(value) {
          value = String(value || '');
          try { value = value.normalize('NFKC'); } catch (_) {}
          return value
            .replace(/[’‘]/g, "'")
            .replace(/\\s+/g, ' ')
            .trim()
            .toLowerCase()
            .replace(/[\\s.!?。！？…।]+$/g, '')
            .trim();
        }
        var selectors = [
          '[data-testid*="empty" i]', '[data-test*="empty" i]',
          '[data-automation-id*="empty" i]', '[class*="empty-state" i]',
          '[class*="emptyState"]', '[id*="empty" i]',
          '[role="status"]', '[role="alert"]',
          'main h1', 'main h2', 'main h3', 'main p'
        ];
        var nodes = [];
        selectors.forEach(function(selector) {
          try { nodes = nodes.concat(Array.from(document.querySelectorAll(selector))); } catch (_) {}
        });
        return nodes.some(function(node) {
          if (!visible(node)) return false;
          var value = normalizedEmptyCopy(text(node));
          return value.length > 0 && value.length < 300 &&
            emptyCopies.indexOf(value) >= 0;
        });
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
          var u = secureKindleURL(href);
          if (!u) return false;
          var path = (u.pathname || '').toLowerCase();
          if (/kindle-library|landing|help|support|settings|notebook|privacy|terms|download|appstore|app-store/.test(path)) return false;
          return !!u.search.match(/[?&]asin=[A-Z0-9]{10}/i) || /\\/reader\\//i.test(path);
        } catch (e) {
          return false;
        }
      }
      function badTitle(raw) {
        var v = String(raw || '').toLowerCase();
        return /download|app store|kindle app|learn more|read on any device|help|support|settings|notebook|privacy|terms|descargar|tienda de aplicaciones|más información|ayuda|configuración|privacidad|términos|baixar|loja de aplicativos|saiba mais|ajuda|configurações|privacidade|termos|ダウンロード|アプリストア|詳細|ヘルプ|設定|プライバシー|規約|herunterladen|app-store|mehr erfahren|hilfe|einstellungen|datenschutz|bedingungen|télécharger|en savoir plus|aide|paramètres|confidentialité|conditions|scarica|ulteriori informazioni|aiuto|impostazioni|privacy|termini|डाउनलोड|ऐप स्टोर|और जानें|सहायता|सेटिंग|गोपनीयता|शर्तें|下载|应用商店|了解更多|任何设备|帮助|支持|设置|笔记/.test(v);
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
        if (labelled) return labelled.trim();
        var raw = text(card).split(/\\n|\\u2022|\\|/)[0] || text(a);
        return raw.slice(0, 160).trim();
      }
      function authorFrom(card, title) {
        var selectors = ['[class*=author]', '[class*=Author]', '[data-testid*=author]'];
        for (var i = 0; i < selectors.length; i++) {
          try {
            var v = text(card.querySelector(selectors[i]));
            if (v && v !== title && v.length < 120) {
              return v.replace(/^(?:by|por|de|par|von|di|著者|作者|लेखक|द्वारा)\\s*[:：]?\\s*/i, '').trim();
            }
          } catch (e) {}
        }
        var lines = text(card).split(/\\n|\\u2022|\\|/).map(function(s) { return s.trim(); }).filter(Boolean);
        for (var j = 0; j < lines.length; j++) {
          var line = lines[j];
          if (line === title) continue;
          if (/^(?:by|por|de|par|von|di|著者|作者|लेखक|द्वारा)\\s*[:：]?\\s*/i.test(line)) {
            return line.replace(/^(?:by|por|de|par|von|di|著者|作者|लेखक|द्वारा)\\s*[:：]?\\s*/i, '').trim();
          }
        }
        return '';
            }
            function progressFrom(card) {
              var structural = card && card.querySelector && card.querySelector('[data-progress],[data-percentage],[data-location],[data-position],[aria-valuenow],[role="progressbar"]');
              if (structural) {
                var direct = attr(structural, 'data-progress') || attr(structural, 'data-percentage') ||
                  attr(structural, 'data-location') || attr(structural, 'data-position') ||
                  attr(structural, 'aria-valuetext') || attr(structural, 'aria-valuenow') || text(structural);
                if (direct) return String(direct).replace(/\\s+/g, ' ').trim();
              }
              var raw = normalizedDigits(text(card));
              var m = raw.match(/(\\d{1,3}\\s*%|(?:Page|Location|Last\\s+read|Página|Ubicación|Posición|Última\\s+lectura|Localização|Posição|Última\\s+leitura|ページ|位置|最終閲覧|Seite|Position|Zuletzt\\s+gelesen|Page|Emplacement|Dernière\\s+lecture|Pagina|Posizione|Ultima\\s+lettura|पृष्ठ|स्थान|अंतिम\\s+पठन)\\s*[:#-]?\\s*\\d+[^\\n,;]*)/i);
              return m ? m[1].replace(/\\s+/g, ' ').trim() : '';
            }
            function languageFrom(card) {
              var nodes = [card].concat(Array.from((card && card.querySelectorAll) ? card.querySelectorAll('[lang],[data-language],[data-language-code],[data-book-language],[data-locale]') : []));
              var aliases = { eng:'en', zho:'zh', chi:'zh', jpn:'ja', spa:'es', fra:'fr', fre:'fr', deu:'de', ger:'de', por:'pt', ita:'it', hin:'hi' };
              for (var i = 0; i < nodes.length; i++) {
                var raw = attr(nodes[i], 'data-book-language') || attr(nodes[i], 'data-language-code') || attr(nodes[i], 'data-language') || attr(nodes[i], 'data-locale') || attr(nodes[i], 'lang');
                var primary = String(raw || '').trim().toLowerCase().replace(/_/g, '-').split('-')[0];
                primary = aliases[primary] || primary;
                if (/^(?:en|zh|ja|es|fr|de|pt|it|hi)$/.test(primary)) return primary;
              }
              return '';
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
                '[data-testid*=account i]',
                '[data-test*=account i]',
                '[data-nav-role=signin]',
                '#nav-link-accountList-nav-line-1',
                '#nav-link-accountList .nav-line-1',
                '[aria-label*=Account]',
                '[aria-label*=account]',
                '[href*=account] span',
                '[href*=your-account] span'
              ];
              for (var i = 0; i < selectors.length && !label; i++) {
                try {
                  var el = document.querySelector(selectors[i]);
                  var v = text(el).replace(/^(?:Hello|Hi|Hola|Olá|こんにちは|Hallo|Bonjour|Ciao|नमस्ते),?\\s*/i, '').trim();
                  if (v && !/sign\\s*in|account|lists?|returns?|orders?|iniciar sesión|cuenta|entrar|conta|anmelden|konto|connexion|compte|accedi|account|ログイン|アカウント|साइन इन|खाता/i.test(v) && v.length < 80) label = v;
                } catch (e) {}
              }
              return { label: label, email: email };
            }
            function candidateLinks() {
              var links = Array.from(document.querySelectorAll('a[href*="asin="], a[href*="/reader/"]'));
        var hits = links.filter(function(a) {
          var href = attr(a, 'href');
          return isReaderHref(href) || !!attr(a, 'data-asin');
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
        if (asin && !isReaderHref(href)) href = readerURLForASIN(asin);
        var title = titleFrom(card, a, img);
        if (!title || title.length < 2) return;
        if (badTitle(title) || badTitle(text(a))) return;
        if (!asinFrom(asin) && !isReaderHref(href)) return;
        if (!isReaderHref(href)) return;
        var id = asin || href || title;
        if (!id || seen[id]) return;
        seen[id] = true;
        var cover = attr(img, 'src') || attr(img, 'data-src') || attr(img, 'srcset').split(' ')[0] || bgURL(card);
        var language = languageFrom(card);
        books.push({
          id: id,
          asin: asin,
          title: title,
          author: authorFrom(card, title),
          coverURL: cover ? abs(cover) : '',
          readerURL: href,
          progressLabel: progressFrom(card),
          language: language,
          languageSource: language ? 'library-hint' : ''
        });
      });
      var signin = Array.from(document.querySelectorAll('input[type=email], input[name=email], input[type=password], #ap_email, #ap_password')).some(visible);
      var hasReaderSignals = books.length > 0 || candidateLinks().length > 0;
            var readerPage = /[?&]asin=[A-Z0-9]{10}/i.test(location.search) || /\\/reader\\//i.test(location.pathname);
            var pageReady = document.readyState === 'complete';
            var hasEmptyShelfSignal = pageReady && !signin && !readerPage &&
              !hasReaderSignals && hasExplicitEmptyShelfSignal();
            return JSON.stringify({
              ok: true,
              loggedIn: books.length > 0,
              authRequired: signin,
              hasReaderSignals: hasReaderSignals,
              hasEmptyShelfSignal: hasEmptyShelfSignal,
              pageReady: pageReady,
              isReaderPage: readerPage,
              account: accountInfo(),
              url: location.href,
              userAgent: navigator.userAgent || '',
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

    static let tocProbe = """
    (function() {
      \(uiSemanticHelpers)
      window.__crKindleTocProbe = window.__crKindleTocProbe || { nodes: [], entries: [], openedAt: 0 };
      var probe = window.__crKindleTocProbe;
      function now() { return Date.now ? Date.now() : new Date().getTime(); }
      function norm(value) {
        return String(value || '').replace(/\\s+/g, ' ').trim();
      }
      function visible(el) {
        if (!el) return false;
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            rect.width > 3 &&
            rect.height > 3 &&
            rect.bottom > 0 &&
            rect.right > 0 &&
            rect.top < (innerHeight || document.documentElement.clientHeight || 0) &&
            rect.left < (innerWidth || document.documentElement.clientWidth || 0);
        } catch (_) {
          return false;
        }
      }
      function labelOf(el) {
        try {
          return norm([
            el.getAttribute && (el.getAttribute('aria-label') || ''),
            el.getAttribute && (el.getAttribute('title') || ''),
            el.getAttribute && (el.getAttribute('data-testid') || ''),
            el.getAttribute && (el.getAttribute('role') || ''),
            el.id || '',
            el.className || '',
            el.innerText || el.textContent || ''
          ].join(' '));
        } catch (_) {
          return '';
        }
      }
      function textOf(el) {
        try { return norm(el && (el.innerText || el.textContent) || ''); } catch (_) { return ''; }
      }
      function rectOf(el) {
        try {
          var r = el.getBoundingClientRect();
          return {
            left: Math.round(r.left),
            top: Math.round(r.top),
            width: Math.round(r.width),
            height: Math.round(r.height),
            right: Math.round(r.right),
            bottom: Math.round(r.bottom)
          };
        } catch (_) {
          return { left:0, top:0, width:0, height:0, right:0, bottom:0 };
        }
      }
      function clickElement(el) {
        if (!el) return false;
        try {
          var target = el.closest && el.closest('button,[role="button"],ion-button,ion-item,a,li,div,span') || el;
          var rect = target.getBoundingClientRect ? target.getBoundingClientRect() : null;
          var opts = rect ? {
            clientX: rect.left + rect.width / 2,
            clientY: rect.top + rect.height / 2,
            bubbles: true,
            cancelable: true
          } : { bubbles:true, cancelable:true };
          try { target.dispatchEvent(new PointerEvent('pointerdown', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mousedown', opts)); } catch (_) {}
          try { target.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mouseup', opts)); } catch (_) {}
          try { target.click(); } catch (_) { target.dispatchEvent(new MouseEvent('click', opts)); }
          return true;
        } catch (_) {
          return false;
        }
      }
      function dispatchPointClick(x, y) {
        try {
          var target = document.elementFromPoint(x, y) || document.body || document.documentElement;
          var opts = { clientX:x, clientY:y, bubbles:true, cancelable:true };
          try { target.dispatchEvent(new PointerEvent('pointerdown', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mousedown', opts)); } catch (_) {}
          try { target.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mouseup', opts)); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('click', opts)); } catch (_) {}
          return true;
        } catch (_) {
          return false;
        }
      }
      function revealReaderChrome() {
        try {
          var viewportW = innerWidth || document.documentElement.clientWidth || 0;
          var viewportH = innerHeight || document.documentElement.clientHeight || 0;
          var points = [
            [Math.round(viewportW * 0.50), Math.round(Math.max(36, viewportH * 0.12))],
            [Math.round(viewportW * 0.50), Math.round(viewportH * 0.50)],
            [Math.round(viewportW * 0.12), Math.round(viewportH * 0.50)]
          ];
          var clicked = false;
          points.forEach(function(point) {
            if (dispatchPointClick(point[0], point[1])) clicked = true;
          });
          return clicked;
        } catch (_) {
          return false;
        }
      }
      function postNative(type, payload) {
        try {
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.castReaderKindle;
          if (handler && handler.postMessage) {
            handler.postMessage(Object.assign({ type:type }, payload || {}));
          }
        } catch (_) {}
      }
      function badEntryText(text) {
        var v = String(text || '').toLowerCase();
        if (!v || v.length < 2 || v.length > 180) return true;
        if (/^(kindle library|search|aa|bookmark|more|previous page|next page|page \\d+|read aloud|explain|close|done|font|layout|margin|page color|side panel close)$/i.test(text) ||
            /preferred font|single column|two columns|narrow|medium|wide|time left|page in book|reading progress/i.test(text)) {
          return true;
        }
        return crKindleUITextMatches('next', text) ||
          crKindleUITextMatches('previous', text) ||
          crKindleUITextMatches('close', text) ||
          crKindleUITextMatches('settings', text) ||
          crKindleUITextMatches('single-column', text) ||
          crKindleUITextMatches('narrow', text);
      }
      function nodePath(el) {
        try {
          var parts = [];
          for (var node = el; node && node.nodeType === 1 && node !== document.documentElement; node = node.parentElement) {
            var tag = String(node.tagName || '').toLowerCase();
            var parent = node.parentElement;
            if (!parent) break;
            var siblings = Array.from(parent.children).filter(function(child) { return child.tagName === node.tagName; });
            var index = Math.max(1, siblings.indexOf(node) + 1);
            parts.unshift(tag + ':nth-of-type(' + index + ')');
            if (parts.length >= 8) break;
          }
          return parts.join('>');
        } catch (_) {
          return '';
        }
      }
      function clickableEntryNode(el) {
        try {
          return el && el.closest && el.closest('a[href],button,[role="button"],[role="menuitem"],ion-button,ion-item,li') || el;
        } catch (_) {
          return el;
        }
      }
      function activeState(el) {
        try {
          var node = clickableEntryNode(el);
          var state = norm([
            node && node.getAttribute && (node.getAttribute('aria-current') || ''),
            node && node.getAttribute && (node.getAttribute('aria-selected') || ''),
            node && node.getAttribute && (node.getAttribute('selected') || ''),
            node && node.getAttribute && (node.getAttribute('data-selected') || ''),
            node && node.className || '',
            el && el.className || ''
          ].join(' ')).toLowerCase();
          return /\\b(current|selected|active|checked|highlight|is-active|is-selected)\\b/.test(state) ||
            state.indexOf('page') === 0 ||
            state === 'true';
        } catch (_) {
          return false;
        }
      }
      function closeTocOverlay(reason) {
        try {
          var explicit = [];
          [
            '[aria-label="Side Panel Close"]',
            '[aria-label*="Side Panel Close"]',
            '[title="Side Panel Close"]',
            '[aria-label="Close"]',
            '[title="Close"]'
          ].forEach(function(sel) {
            try { Array.from(document.querySelectorAll(sel)).forEach(function(el) { explicit.push(el); }); } catch (_) {}
          });
          var nodes = explicit.concat(Array.from(document.querySelectorAll('button,[role="button"],ion-button,[aria-label],[title]')).filter(visible));
          var seen = new Set();
          var close = nodes.filter(function(el) {
            if (seen.has(el)) return false;
            seen.add(el);
            return true;
          }).map(function(el) {
            return {
              el:el,
              label:labelOf(el),
              rect:rectOf(el),
              score:crKindleUISemanticScore(el, 'close')
            };
          }).filter(function(item) {
            return item.score >= 45 && !/kindle library/.test(item.label.toLowerCase());
          }).sort(function(a, b) {
            return b.score - a.score || a.rect.top - b.rect.top || b.rect.left - a.rect.left;
          })[0];
          var clicked = close ? clickElement(close.el) : false;
          if (!clicked) {
            try { document.dispatchEvent(new KeyboardEvent('keydown', { key:'Escape', code:'Escape', bubbles:true, cancelable:true })); } catch (_) {}
          }
          postNative('toc-close', {
            reason:reason || '',
            clicked:clicked,
            closeLabel:close ? close.label.slice(0, 160) : '',
            url:location.href
          });
          return clicked;
        } catch (e) {
          postNative('toc-close-error', { reason:String(e && e.message || e), url:location.href });
          return false;
        }
      }
      function entryScore(el, text, rect) {
        var node = clickableEntryNode(el);
        var tag = String((node && node.tagName) || '').toLowerCase();
        var role = String((node && node.getAttribute && node.getAttribute('role')) || '').toLowerCase();
        var score = 0;
        if (tag === 'a' || tag === 'button' || tag === 'ion-button') score += 30;
        if (tag === 'ion-item' || tag === 'li') score += 24;
        if (role === 'button' || role === 'menuitem' || role === 'listitem') score += 18;
        if (node && node.getAttribute && node.getAttribute('href')) score += 16;
        if (node && node.getAttribute && (
            node.getAttribute('data-location') ||
            node.getAttribute('data-position') ||
            node.getAttribute('data-cfi') ||
            node.getAttribute('data-section') ||
            node.getAttribute('data-chapter'))) score += 24;
        if (activeState(el)) score += 10;
        score += Math.min(20, Math.max(0, rect.width / 30));
        score += Math.min(10, Math.max(0, rect.height / 10));
        if (crKindleUITextMatches('toc', text)) score += 8;
        return score;
      }
      function installTocMonitor() {
        if (probe.monitorInstalled) return;
        probe.monitorInstalled = true;
        probe.events = probe.events || [];
        document.addEventListener('click', function(event) {
          try {
            var node = clickableEntryNode(event.target);
            var label = labelOf(node).slice(0, 180);
            var lowerLabel = label.toLowerCase();
            if (crKindleUISemanticScore(node, 'close') >= 45 &&
                !/kindle library/.test(lowerLabel)) {
              setTimeout(function() {
                postNative('toc-close', {
                  reason:'native-close-click',
                  clicked:true,
                  closeLabel:label,
                  url:location.href
                });
              }, 120);
              return;
            }
            var text = textOf(node);
            if (badEntryText(text)) return;
            var rect = rectOf(node);
            if (rect.width < 20 || rect.height < 16) return;
            var path = nodePath(node);
            var entry = {
              at: now(),
              text: text.slice(0, 180),
              active: activeState(node),
              path: path,
              rect: rect,
              label: label,
              url: location.href
            };
            probe.events.push(entry);
            if (probe.events.length > 24) probe.events.splice(0, probe.events.length - 24);
            postNative('toc-click', entry);
            setTimeout(function() {
              var collected = collectEntries();
              var activeEntries = collected.entries.filter(function(item) { return item.active; }).slice(0, 8);
              postNative('toc-after-click', {
                text: text.slice(0, 180),
                activeEntries: activeEntries.map(function(item) { return item.text; }).join(' | '),
                rawCount: collected.rawEntries.length,
                count: collected.entries.length,
                url: location.href
              });
            }, 220);
          } catch (_) {}
        }, true);
      }
      function findOverlayContainers() {
        var selectors = [
          'ion-menu',
          'ion-modal',
          'ion-popover',
          '[role="dialog"]',
          '[role="menu"]',
          '[role="navigation"]',
          '[aria-modal="true"]',
          '.popover-content',
          '.modal-wrapper',
          '[class*="toc"]',
          '[class*="contents"]',
          '[class*="chapter"]',
          '[class*="navigation"]',
          'ion-content',
          'ion-list'
        ].join(',');
        var containers = [];
        Array.from(document.querySelectorAll(selectors)).forEach(function(el) {
          if (!visible(el)) return;
          var label = labelOf(el).toLowerCase();
          var txt = textOf(el).toLowerCase();
          var r = rectOf(el);
          var semanticScore = crKindleUISemanticScore(el, 'toc');
          var structuralEntries = el.querySelectorAll(
            'a[href],[role="treeitem"],[role="listitem"],[role="menuitem"],ion-item,li,[data-location],[data-cfi],[data-section],[data-chapter]'
          ).length;
          var looksLikeOverlay = semanticScore >= 45 ||
            /dialog|menu|navigation|toc|contents|chapter|go to|location|cover|beginning|section/.test(label + ' ' + txt);
          var largePanel = r.width > Math.min(260, (innerWidth || 0) * 0.35) && r.height > Math.min(260, (innerHeight || 0) * 0.35);
          if (looksLikeOverlay || (largePanel && structuralEntries >= 2)) containers.push(el);
        });
        return containers;
      }
      function collectEntries() {
        installTocMonitor();
        var containers = findOverlayContainers();
        var nodes = [];
        var seenNode = new Set();
        containers.forEach(function(container) {
          Array.from(container.querySelectorAll('a[href],button,[role="button"],[role="menuitem"],[role="listitem"],ion-item,li')).forEach(function(el) {
            if (seenNode.has(el) || !visible(el)) return;
            seenNode.add(el);
            nodes.push(el);
          });
        });
        var rawEntries = [];
        nodes.forEach(function(el) {
          var text = textOf(el);
          if (badEntryText(text)) return;
          var label = labelOf(el).toLowerCase();
          var node = clickableEntryNode(el);
          var r = rectOf(el);
          if (r.width < 20 || r.height < 16) return;
          var level = 0;
          var ariaLevel = (el.getAttribute && el.getAttribute('aria-level')) || (node && node.getAttribute && node.getAttribute('aria-level'));
          if (ariaLevel && !isNaN(Number(ariaLevel))) level = Number(ariaLevel);
          var clickableRect = rectOf(node);
          rawEntries.push({
            rawIndex: rawEntries.length,
            text: text,
            level: level,
            role: String((node && node.getAttribute && node.getAttribute('role')) || (el.getAttribute && el.getAttribute('role')) || ''),
            aria: String((node && node.getAttribute && node.getAttribute('aria-label')) || (el.getAttribute && el.getAttribute('aria-label')) || ''),
            path: nodePath(node),
            sourcePath: nodePath(el),
            rect: clickableRect.width > 0 ? clickableRect : r,
            sourceRect: r,
            active: activeState(el),
            score: entryScore(el, text, clickableRect.width > 0 ? clickableRect : r),
            label: label.slice(0, 180)
          });
        });
        var byText = {};
        rawEntries.forEach(function(entry) {
          var key = entry.text.toLowerCase();
          var current = byText[key];
          if (!current || entry.score > current.score ||
              (entry.score === current.score && entry.rect.width * entry.rect.height > current.rect.width * current.rect.height)) {
            byText[key] = entry;
          }
        });
        var entries = Object.keys(byText).map(function(key) { return byText[key]; }).sort(function(a, b) {
          return a.rect.top - b.rect.top || a.rect.left - b.rect.left || a.text.localeCompare(b.text);
        }).map(function(entry, index) {
          entry.index = index;
          return entry;
        });
        probe.nodes = entries.map(function(entry) {
          return document.querySelector(entry.path);
        });
        probe.entries = entries;
        probe.rawEntries = rawEntries;
        return { containers: containers, entries: entries, rawEntries: rawEntries };
      }
      function findTocOpeners() {
        var nodes = Array.from(document.querySelectorAll('button,[role="button"],ion-button,[aria-label],[title],span,div'));
        var explicit = [];
        [
          '[aria-label="Table of Contents"]',
          '[aria-label*="Table of Contents"]',
          '[aria-label*="Contents"]',
          '[aria-label*="Go to"]',
          '[aria-label*="Navigation"]',
          '[title*="Table of Contents"]',
          '[title*="Contents"]',
          '[data-testid*="toc" i]',
          '[class*="toc" i]',
          '[class*="contents" i]',
          '[class*="navigation" i]'
        ].forEach(function(sel) {
          try {
            Array.from(document.querySelectorAll(sel)).forEach(function(el) {
              if (nodes.indexOf(el) < 0) nodes.push(el);
              explicit.push(el);
            });
          } catch (_) {}
        });
        var scored = nodes.map(function(el) {
          var label = labelOf(el);
          var lower = label.toLowerCase();
          var r = rectOf(el);
          var score = crKindleUISemanticScore(el, 'toc');
          var isExplicit = explicit.indexOf(el) >= 0;
          if (isExplicit) score += 160;
          if (/table of contents|contents|toc|go to|goto|chapter|navigation|menu/.test(lower)) score += 120;
          if (/list|outline|目录|章节|内容/.test(lower)) score += 80;
          if (/list|outline|navigation|tree/.test(crKindleUIStructure(el))) score += 80;
          if (String(el.getAttribute && (el.getAttribute('aria-label') || '')).toLowerCase() === 'table of contents') score += 220;
          if (visible(el)) score += 20;
          else if (score > 0) score -= 18;
          if (r.top < 150 && r.width >= 24 && r.width <= 90 && r.height >= 24 && r.height <= 90) score += 18;
          if (/kindle library|search|aa|bookmark|previous page|next page|page \\d+|read aloud|explain/.test(lower)) score -= 160;
          if (crKindleUISemanticScore(el, 'next') >= 45 ||
              crKindleUISemanticScore(el, 'previous') >= 45) score -= 220;
          return { el: el, score: score, label: label, rect: r };
        }).filter(function(item) { return item.score > 0; }).sort(function(a, b) {
          return b.score - a.score || a.rect.left - b.rect.left;
        });
        if (scored.length > 0) return scored;

        var topButtons = nodes.map(function(el) {
          return { el: el, label: labelOf(el), rect: rectOf(el) };
        }).filter(function(item) {
          return item.rect.top < 130 &&
            item.rect.width >= 28 &&
            item.rect.width <= 90 &&
            item.rect.height >= 28 &&
            item.rect.height <= 90 &&
            !/kindle library|search|aa|bookmark|previous page|next page/.test(item.label.toLowerCase()) &&
            crKindleUISemanticScore(item.el, 'next') < 45 &&
            crKindleUISemanticScore(item.el, 'previous') < 45;
        }).sort(function(a, b) { return a.rect.left - b.rect.left; });
        return topButtons.map(function(item) {
          return { el: item.el, score: 10, label: item.label, rect: item.rect };
        });
      }
      function armNativeTOCListMode(opener) {
        try {
          document.documentElement.setAttribute('data-cr-native-toc-list-mode', '1');
          var id = '__cr_castreader_native_toc_list_mode';
          var style = document.getElementById(id);
          if (!style) {
            style = document.createElement('style');
            style.id = id;
            document.documentElement.appendChild(style);
          }
          style.textContent = [
            '[data-cr-native-toc-chrome="1"]{',
            'display:none!important;height:0!important;min-height:0!important;max-height:0!important;',
            'padding:0!important;margin:0!important;overflow:hidden!important;',
            'border:0!important;box-shadow:none!important;',
            '}'
          ].join('');

          function save(el) {
            if (!el || !el.dataset) return;
            if (el.dataset.crPrevNativeTocChromeStyle == null) {
              el.dataset.crPrevNativeTocChromeStyle = el.getAttribute('style') || '';
            }
          }
          function mark(el) {
            if (!el) return false;
            save(el);
            el.setAttribute('data-cr-native-toc-chrome', '1');
            return true;
          }
          function rowCandidateFrom(el) {
            var viewportW = innerWidth || document.documentElement.clientWidth || 0;
            var best = null;
            var node = el;
            var hops = 0;
            while (node && node.nodeType === 1 && node !== document.documentElement && hops < 8) {
              var r = rectOf(node);
              if (r.top >= -8 &&
                  r.top < 180 &&
                  r.height >= 34 &&
                  r.height <= 130 &&
                  r.width >= Math.max(260, viewportW * 0.62)) {
                var score = r.width + Math.max(0, 140 - r.height) - Math.abs(r.top);
                if (!best || score > best.score) best = { el:node, score:score, rect:r };
              }
              node = node.parentElement;
              hops += 1;
            }
            return best && best.el ? best.el : null;
          }
          var row = rowCandidateFrom(opener);
          var ok = mark(row || opener);
          return {
            ok:ok,
            tag:String((row || opener || {}).tagName || ''),
            rect:rectOf(row || opener),
            label:labelOf(row || opener).slice(0, 160)
          };
        } catch (e) {
          return { ok:false, reason:String(e && e.message || e) };
        }
      }
      window.__crKindleTOCJump = function(index) {
        try {
          var i = Number(index || 0);
          var node = probe.nodes && probe.nodes[i];
          if (!node && probe.entries && probe.entries[i] && probe.entries[i].path) {
            node = document.querySelector(probe.entries[i].path);
          }
          if (!node || !visible(node)) return JSON.stringify({ ok:false, reason:'entry-not-visible', index:i, count:(probe.entries || []).length, url:location.href });
          window.__crKindleProbe = window.__crKindleProbe || {};
          window.__crKindleProbe.navigationSeq = Number(window.__crKindleProbe.navigationSeq || 0) + 1;
          window.__crKindleProbe.navigationAt = now();
          window.__crKindleProbe.navigationReason = 'toc-probe-jump-' + i;
          var entryText = textOf(node).slice(0, 160);
          var clicked = clickElement(node);
          return JSON.stringify({ ok:clicked, stage:'toc-jump', index:i, text:entryText, url:location.href });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e && e.message || e), index:index, url:location.href });
        }
      };

      var collected = collectEntries();
      if (collected.entries.length > 0) {
        return JSON.stringify({
          ok:true,
          stage:'toc-visible',
          rawCount:collected.rawEntries.length,
          count:collected.entries.length,
          entries:collected.entries.slice(0, 80),
          rawEntries:collected.rawEntries.slice(0, 80),
          activeEntries:collected.entries.filter(function(entry) { return entry.active; }).slice(0, 12),
          events:(probe.events || []).slice(-12),
          containers:collected.containers.map(function(el) { return { label:labelOf(el).slice(0, 160), rect:rectOf(el), text:textOf(el).slice(0, 220) }; }).slice(0, 8),
          url:location.href,
          title:document.title || ''
        });
      }

      var openers = findTocOpeners();
      var opener = openers.length ? openers[0].el : null;
      var clicked = clickElement(opener);
      var listMode = { ok:false, reason:'native-visible-mode' };
      if (clicked) {
        probe.openedAt = now();
      }
      if (!clicked && openers.length === 0) {
        var revealed = revealReaderChrome();
        return JSON.stringify({
          ok:false,
          stage:revealed ? 'revealing-reader-chrome' : 'toc-opener-not-found',
          opener:null,
          openerCandidates:[],
          rawCount:collected.rawEntries.length,
          count:0,
          entries:[],
          rawEntries:collected.rawEntries.slice(0, 80),
          activeEntries:[],
          events:(probe.events || []).slice(-12),
          containers:collected.containers.map(function(el) { return { label:labelOf(el).slice(0, 160), rect:rectOf(el), text:textOf(el).slice(0, 220) }; }).slice(0, 8),
          url:location.href,
          title:document.title || ''
        });
      }
      return JSON.stringify({
        ok:false,
        stage:clicked ? 'opening-toc' : 'toc-opener-not-found',
        listMode:listMode,
        opener:opener ? { label:labelOf(opener).slice(0, 160), rect:rectOf(opener) } : null,
        openerCandidates:openers.slice(0, 8).map(function(item) { return { score:item.score, label:item.label.slice(0, 160), rect:item.rect }; }),
        rawCount:collected.rawEntries.length,
        count:0,
        entries:[],
        rawEntries:collected.rawEntries.slice(0, 80),
        activeEntries:[],
        events:(probe.events || []).slice(-12),
        containers:collected.containers.map(function(el) { return { label:labelOf(el).slice(0, 160), rect:rectOf(el), text:textOf(el).slice(0, 220) }; }).slice(0, 8),
        url:location.href,
        title:document.title || ''
      });
    })();
    """

    static let closeTOCOverlay = """
    (function() {
      \(uiSemanticHelpers)
      function norm(value) { return String(value || '').replace(/\\s+/g, ' ').trim(); }
      function visible(el) {
        if (!el) return false;
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            rect.width > 3 &&
            rect.height > 3 &&
            rect.bottom > 0 &&
            rect.right > 0 &&
            rect.top < (innerHeight || document.documentElement.clientHeight || 0) &&
            rect.left < (innerWidth || document.documentElement.clientWidth || 0);
        } catch (_) { return false; }
      }
      function labelOf(el) {
        try {
          return norm([
            el.getAttribute && (el.getAttribute('aria-label') || ''),
            el.getAttribute && (el.getAttribute('title') || ''),
            el.getAttribute && (el.getAttribute('data-testid') || ''),
            el.getAttribute && (el.getAttribute('role') || ''),
            el.id || '',
            el.className || '',
            el.innerText || el.textContent || ''
          ].join(' '));
        } catch (_) { return ''; }
      }
      function textOf(el) {
        try { return norm(el && (el.innerText || el.textContent) || ''); } catch (_) { return ''; }
      }
      function rectOf(el) {
        try {
          var r = el.getBoundingClientRect();
          return { left:Math.round(r.left), top:Math.round(r.top), width:Math.round(r.width), height:Math.round(r.height), right:Math.round(r.right), bottom:Math.round(r.bottom) };
        } catch (_) {
          return { left:0, top:0, width:0, height:0, right:0, bottom:0 };
        }
      }
      function clickElement(el) {
        if (!el) return false;
        try {
          var target = el.closest && el.closest('button,[role="button"],ion-button,ion-item,a,li,div,span') || el;
          var rect = target.getBoundingClientRect ? target.getBoundingClientRect() : null;
          var opts = rect ? { clientX:rect.left + rect.width / 2, clientY:rect.top + rect.height / 2, bubbles:true, cancelable:true } : { bubbles:true, cancelable:true };
          try { target.dispatchEvent(new PointerEvent('pointerdown', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mousedown', opts)); } catch (_) {}
          try { target.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mouseup', opts)); } catch (_) {}
          try { target.click(); } catch (_) { try { target.dispatchEvent(new MouseEvent('click', opts)); } catch (_) {} }
          return true;
        } catch (_) {
          return false;
        }
      }
      function visibleTocContainers() {
        var selectors = [
          'ion-menu',
          'ion-modal',
          'ion-popover',
          '[role="dialog"]',
          '[role="menu"]',
          '[role="navigation"]',
          '[aria-modal="true"]',
          '.popover-content',
          '.modal-wrapper',
          '[class*="toc"]',
          '[class*="contents"]',
          '[class*="chapter"]',
          '[class*="navigation"]',
          'ion-content',
          'ion-list'
        ].join(',');
        var containers = [];
        try {
          Array.from(document.querySelectorAll(selectors)).forEach(function(el) {
            if (!visible(el)) return;
            var text = textOf(el);
            var label = labelOf(el);
            var r = rectOf(el);
            var entryCount = el.querySelectorAll(
              'a[href],[role="treeitem"],[role="listitem"],[role="menuitem"],ion-item,li,[data-location],[data-cfi],[data-section],[data-chapter]'
            ).length;
            var largePanel = r.width > Math.min(260, (innerWidth || 0) * 0.35) &&
              r.height > Math.min(260, (innerHeight || 0) * 0.35);
            if (crKindleUISemanticScore(el, 'toc') >= 45 ||
                /chapter\\s+\\d+|table of contents|contents|go to|location|cover|beginning|section/i.test(text + ' ' + label) ||
                (largePanel && entryCount >= 2)) {
              containers.push({ label:label.slice(0, 160), text:text.slice(0, 220), rect:rectOf(el) });
            }
          });
        } catch (_) {}
        return containers;
      }

      var containers = visibleTocContainers();
      var explicit = [];
      [
        '[aria-label="Side Panel Close"]',
        '[aria-label*="Side Panel Close"]',
        '[title="Side Panel Close"]',
        '[aria-label="Close"]',
        '[title="Close"]'
      ].forEach(function(sel) {
        try { Array.from(document.querySelectorAll(sel)).forEach(function(el) { explicit.push(el); }); } catch (_) {}
      });
      var nodes = explicit.concat(Array.from(document.querySelectorAll('button,[role="button"],ion-button,[aria-label],[title]')).filter(visible));
      var seen = new Set();
      var close = nodes.filter(function(el) {
        if (seen.has(el)) return false;
        seen.add(el);
        return true;
      }).map(function(el) {
        return {
          el:el,
          label:labelOf(el),
          rect:rectOf(el),
          explicit:explicit.indexOf(el) >= 0,
          score:crKindleUISemanticScore(el, 'close')
        };
      }).filter(function(item) {
        return item.score >= 45 && !/kindle library/.test(item.label.toLowerCase());
      }).sort(function(a, b) {
        if (a.explicit !== b.explicit) return a.explicit ? -1 : 1;
        return b.score - a.score || a.rect.top - b.rect.top || b.rect.left - a.rect.left;
      })[0];
      var clicked = close ? clickElement(close.el) : false;
      var escaped = false;
      if (!clicked && containers.length > 0) {
        try {
          document.dispatchEvent(new KeyboardEvent('keydown', { key:'Escape', code:'Escape', keyCode:27, which:27, bubbles:true, cancelable:true }));
          escaped = true;
        } catch (_) {}
      }
      return JSON.stringify({
        ok:clicked || escaped,
        clicked:clicked,
        escaped:escaped,
        visibleBefore:containers.length > 0,
        closeLabel:close ? close.label.slice(0, 160) : '',
        containers:containers.slice(0, 8),
        url:location.href
      });
    })();
    """

    static let styleNativeTOCSheet = """
    (function() {
      \(uiSemanticHelpers)
      try {
        Array.from(document.querySelectorAll(
          'button,[role="button"],ion-button,[data-testid],[data-action],[aria-label],[title]'
        )).forEach(function(el) {
          if (crKindleUISemanticScore(el, 'next') >= 45 ||
              crKindleUISemanticScore(el, 'previous') >= 45) {
            el.setAttribute('data-cr-native-toc-page-control', '1');
          }
        });
        var id = '__cr_castreader_native_toc_sheet';
        var style = document.getElementById(id);
        if (!style) {
          style = document.createElement('style');
          style.id = id;
          document.documentElement.appendChild(style);
        }
        document.documentElement.setAttribute('data-cr-native-toc-open', '1');
        style.textContent = [
          'html[data-cr-native-toc-open="1"] ion-menu::part(backdrop),',
          'html[data-cr-native-toc-open="1"] ion-backdrop,',
          'html[data-cr-native-toc-open="1"] .menu-backdrop,',
          'html[data-cr-native-toc-open="1"] [part="backdrop"],',
          'html[data-cr-native-toc-open="1"] [class*="scrim" i],',
          'html[data-cr-native-toc-open="1"] [class*="backdrop" i]{',
          'opacity:0!important;background:transparent!important;pointer-events:none!important;',
          '--backdrop-opacity:0!important;--background:transparent!important;',
          '}',
          'html[data-cr-native-toc-open="1"] button[aria-label="Previous page"],',
          'html[data-cr-native-toc-open="1"] button[aria-label="Next page"],',
          'html[data-cr-native-toc-open="1"] [title="Previous page"],',
          'html[data-cr-native-toc-open="1"] [title="Next page"],',
          'html[data-cr-native-toc-open="1"] [data-cr-native-toc-page-control="1"]{',
          'visibility:hidden!important;pointer-events:none!important;',
          '}',
          '[data-cr-toc-sheet="root"]{',
          'opacity:1!important;visibility:visible!important;background:#fff!important;color:#111!important;',
          'filter:none!important;',
          '-webkit-backdrop-filter:none!important;backdrop-filter:none!important;',
          '}',
          '[data-cr-toc-sheet="panel"]{',
          'opacity:1!important;visibility:visible!important;background:#fff!important;color:#111!important;',
          'filter:none!important;',
          '-webkit-backdrop-filter:none!important;backdrop-filter:none!important;',
          '}',
          '[data-cr-toc-sheet="scroll"]{',
          '-webkit-overflow-scrolling:touch!important;overscroll-behavior:contain!important;',
          'overflow-y:auto!important;overflow-x:hidden!important;background:#fff!important;color:#111!important;',
          'padding-bottom:calc(env(safe-area-inset-bottom,0px) + 24px)!important;',
          '}',
          '[data-cr-toc-sheet="root"] *,',
          '[data-cr-toc-sheet="panel"] *,',
          '[data-cr-toc-sheet="scroll"] *{',
          'color:#111!important;text-shadow:none!important;',
          '}'
        ].join('');

        function norm(value) {
          return String(value || '').replace(/\\s+/g, ' ').trim();
        }
        function rectOf(el) {
          try {
            var r = el.getBoundingClientRect();
            return {
              left: Math.round(r.left),
              top: Math.round(r.top),
              width: Math.round(r.width),
              height: Math.round(r.height),
              right: Math.round(r.right),
              bottom: Math.round(r.bottom)
            };
          } catch (_) {
            return { left:0, top:0, width:0, height:0, right:0, bottom:0 };
          }
        }
        function visible(el) {
          if (!el) return false;
          try {
            var s = getComputedStyle(el);
            var r = el.getBoundingClientRect();
            return s.display !== 'none' &&
              s.visibility !== 'hidden' &&
              r.width > 4 &&
              r.height > 4 &&
              r.bottom > 0 &&
              r.right > 0 &&
              r.top < (innerHeight || document.documentElement.clientHeight || 0) &&
              r.left < (innerWidth || document.documentElement.clientWidth || 0);
          } catch (_) {
            return false;
          }
        }
        function labelOf(el) {
          try {
            return norm([
              el.getAttribute && (el.getAttribute('aria-label') || ''),
              el.getAttribute && (el.getAttribute('title') || ''),
              el.getAttribute && (el.getAttribute('data-testid') || ''),
              el.getAttribute && (el.getAttribute('role') || ''),
              el.id || '',
              el.className || '',
              el.innerText || el.textContent || ''
            ].join(' '));
          } catch (_) {
            return '';
          }
        }
        function textOf(el) {
          try { return norm(el && (el.innerText || el.textContent) || ''); } catch (_) { return ''; }
        }
        function badEntryText(text) {
          var v = String(text || '').toLowerCase();
          if (!v || v.length < 2 || v.length > 180) return true;
          if (/^(kindle library|search|aa|bookmark|more|previous page|next page|page \\d+|read aloud|explain|close|done|font|layout|margin|page color|side panel close)$/i.test(text) ||
              /preferred font|single column|two columns|narrow|medium|wide|time left|page in book|reading progress/i.test(text)) {
            return true;
          }
          return crKindleUITextMatches('next', text) ||
            crKindleUITextMatches('previous', text) ||
            crKindleUITextMatches('close', text) ||
            crKindleUITextMatches('settings', text) ||
            crKindleUITextMatches('single-column', text) ||
            crKindleUITextMatches('narrow', text);
        }
        function looksLikeEntry(el) {
          if (!visible(el)) return false;
          var t = textOf(el);
          if (badEntryText(t)) return false;
          var r = rectOf(el);
          if (r.width < 24 || r.height < 16) return false;
          var label = labelOf(el).toLowerCase();
          if (el.matches && el.matches(
              '[data-location],[data-position],[data-cfi],[data-section],[data-chapter],[role="treeitem"],[role="listitem"],[role="menuitem"]'
          )) return true;
          if (crKindleUIStructureScore(el, 'toc') >= 45) return true;
          if (/chapter|contents|section|author|note|part|prologue|epilogue|toc-item|toc|目录|章节/.test(label + ' ' + t.toLowerCase())) return true;
          return false;
        }
        function saveStyle(el) {
          if (!el || !el.dataset) return;
          if (el.dataset.crPrevStyle == null) el.dataset.crPrevStyle = el.getAttribute('style') || '';
        }
        function mark(el, role) {
          if (!el) return;
          saveStyle(el);
          el.setAttribute('data-cr-toc-sheet', role);
        }
        function restoreOldSheetMarks() {
          Array.from(document.querySelectorAll('[data-cr-toc-sheet]')).forEach(function(el) {
            try {
              var prev = el.dataset ? el.dataset.crPrevStyle : null;
              if (prev != null) {
                if (prev) el.setAttribute('style', prev);
                else el.removeAttribute('style');
                delete el.dataset.crPrevStyle;
              }
              el.removeAttribute('data-cr-toc-sheet');
            } catch (_) {}
          });
        }
        function ancestorScore(el, entries) {
          if (!el || el === document.documentElement || el === document.body) return -1;
          var r = rectOf(el);
          if (r.width < 160 || r.height < 120) return -1;
          var count = 0;
          entries.forEach(function(entry) {
            try { if (el.contains(entry)) count += 1; } catch (_) {}
          });
          if (count < Math.min(3, entries.length)) return -1;
          var label = labelOf(el).toLowerCase();
          var tag = String(el.tagName || '').toLowerCase();
          var score = count * 100;
          if (/ion-menu|ion-modal|ion-popover/.test(tag)) score += 800;
          if (/dialog|menu|navigation|toc|contents|chapter|side-menu|side panel/.test(label)) score += 520;
          if (r.height > (innerHeight || 0) * 0.35) score += 80;
          if (r.width > (innerWidth || 0) * 0.5) score += 60;
          if (tag === 'html' || tag === 'body') score -= 10000;
          return score;
        }
        function findRoot(entries) {
          var candidates = [];
          entries.forEach(function(entry) {
            var el = entry;
            var hops = 0;
            while (el && el.nodeType === 1 && hops < 12) {
              var score = ancestorScore(el, entries);
              if (score > 0) candidates.push({ el:el, score:score, rect:rectOf(el), label:labelOf(el).slice(0, 140) });
              el = el.parentElement;
              hops += 1;
            }
          });
          candidates.sort(function(a, b) {
            return b.score - a.score || b.rect.height - a.rect.height || b.rect.width - a.rect.width;
          });
          return candidates.length ? candidates[0] : null;
        }
        function shadowQueryAll(root, selector) {
          var out = [];
          try {
            if (root && root.shadowRoot) {
              out = out.concat(Array.from(root.shadowRoot.querySelectorAll(selector)));
            }
          } catch (_) {}
          return out;
        }
        function findScrollTarget(root, entries) {
          var nodes = [];
          try { nodes = nodes.concat(Array.from(root.querySelectorAll('ion-content,ion-list,.inner-scroll,.scroll-y,[part="scroll"],[class*="scroll" i],[class*="content" i]'))); } catch (_) {}
          nodes = nodes.concat(shadowQueryAll(root, '.inner-scroll,.scroll-y,[part="scroll"],[part="container"],main,section,div'));
          try {
            Array.from(root.querySelectorAll('*')).forEach(function(el) {
              if (nodes.indexOf(el) < 0 && el.scrollHeight > el.clientHeight + 20) nodes.push(el);
            });
          } catch (_) {}
          var best = null;
          nodes.forEach(function(el) {
            var r = rectOf(el);
            if (r.width < 120 || r.height < 80) return;
            var count = 0;
            entries.forEach(function(entry) {
              try { if (el.contains(entry)) count += 1; } catch (_) {}
            });
            var score = count * 100 + Math.min(400, el.scrollHeight || 0) + r.height;
            if (!best || score > best.score) best = { el:el, score:score, rect:r };
          });
          return best && best.el ? best.el : root;
        }

        restoreOldSheetMarks();
        var nodes = Array.from(document.querySelectorAll('a[href],button,[role="button"],[role="menuitem"],[role="listitem"],ion-item,li,span,div'));
        var entries = nodes.filter(looksLikeEntry);
        var seen = new Set();
        entries = entries.filter(function(el) {
          var t = textOf(el).toLowerCase();
          if (seen.has(t)) return false;
          seen.add(t);
          return true;
        }).slice(0, 80);
        if (entries.length < 3) {
          return JSON.stringify({ ok:false, styled:false, reason:'toc-entries-not-found', entryCount:entries.length, url:location.href });
        }
        var rootHit = findRoot(entries);
        if (!rootHit || !rootHit.el) {
          return JSON.stringify({ ok:false, styled:false, reason:'toc-root-not-found', entryCount:entries.length, url:location.href });
        }
        var root = rootHit.el;
        var scrollTarget = findScrollTarget(root, entries);
        mark(root, 'root');
        if (root.shadowRoot) {
          shadowQueryAll(root, '[part="container"],.menu-inner,.inner-scroll,.scroll-y,main,section,div').slice(0, 8).forEach(function(el, index) {
            mark(el, index === 0 ? 'panel' : 'scroll');
          });
        }
        var firstChild = null;
        try { firstChild = root.firstElementChild; } catch (_) {}
        if (firstChild) mark(firstChild, 'panel');
        mark(scrollTarget, 'scroll');
        try { scrollTarget.scrollTop = scrollTarget.scrollTop || 0; } catch (_) {}

        return JSON.stringify({
          ok:true,
          styled:true,
          entryCount:entries.length,
          first:textOf(entries[0]).slice(0, 120),
          rootTag:String(root.tagName || ''),
          rootLabel:labelOf(root).slice(0, 160),
          rootRect:rectOf(root),
          scrollTag:String(scrollTarget && scrollTarget.tagName || ''),
          scrollRect:rectOf(scrollTarget),
          url:location.href
        });
      } catch (e) {
        return JSON.stringify({ ok:false, reason:String(e && e.message || e), url:location.href });
      }
    })();
    """

    static let clearNativeTOCSheetStyle = """
    (function() {
      try {
        Array.from(document.querySelectorAll('[data-cr-toc-sheet]')).forEach(function(el) {
          try {
            var prev = el.dataset ? el.dataset.crPrevStyle : null;
            if (prev != null) {
              if (prev) el.setAttribute('style', prev);
              else el.removeAttribute('style');
              delete el.dataset.crPrevStyle;
            }
            el.removeAttribute('data-cr-toc-sheet');
          } catch (_) {}
        });
        var style = document.getElementById('__cr_castreader_native_toc_sheet');
        if (style && style.parentNode) style.parentNode.removeChild(style);
        document.documentElement.removeAttribute('data-cr-native-toc-open');
        Array.from(document.querySelectorAll('[data-cr-toc-pad]')).forEach(function(el) {
          try {
            if (el.getAttribute('data-cr-toc-pad') === 'spacer') {
              if (el.parentNode) el.parentNode.removeChild(el);
              return;
            }
            var prev = el.dataset ? el.dataset.crPrevTocPadStyle : null;
            if (prev != null) {
              if (prev) el.setAttribute('style', prev);
              else el.removeAttribute('style');
              delete el.dataset.crPrevTocPadStyle;
            }
            el.removeAttribute('data-cr-toc-pad');
          } catch (_) {}
        });
        var padStyle = document.getElementById('__cr_castreader_native_toc_padding');
        if (padStyle && padStyle.parentNode) padStyle.parentNode.removeChild(padStyle);
        document.documentElement.removeAttribute('data-cr-native-toc-content-only');
        var contentStyle = document.getElementById('__cr_castreader_native_toc_content_only');
        if (contentStyle && contentStyle.parentNode) contentStyle.parentNode.removeChild(contentStyle);
        document.documentElement.removeAttribute('data-cr-native-toc-list-mode');
        Array.from(document.querySelectorAll('[data-cr-native-toc-chrome]')).forEach(function(el) {
          try {
            var prev = el.dataset ? el.dataset.crPrevNativeTocChromeStyle : null;
            if (prev != null) {
              if (prev) el.setAttribute('style', prev);
              else el.removeAttribute('style');
              delete el.dataset.crPrevNativeTocChromeStyle;
            }
            el.removeAttribute('data-cr-native-toc-chrome');
          } catch (_) {}
        });
        var listModeStyle = document.getElementById('__cr_castreader_native_toc_list_mode');
        if (listModeStyle && listModeStyle.parentNode) listModeStyle.parentNode.removeChild(listModeStyle);
        return JSON.stringify({ ok:true, styled:false, url:location.href });
      } catch (e) {
        return JSON.stringify({ ok:false, reason:String(e && e.message || e), url:location.href });
      }
    })();
    """

    static let padNativeTOCScrollArea = """
    (function() {
      \(uiSemanticHelpers)
      try {
        var id = '__cr_castreader_native_toc_padding';
        var style = document.getElementById(id);
        if (!style) {
          style = document.createElement('style');
          style.id = id;
          document.documentElement.appendChild(style);
        }
        style.textContent = [
          '[data-cr-toc-pad="root"]{',
          'top:0!important;bottom:0!important;height:100vh!important;max-height:100vh!important;',
          '}',
          '[data-cr-toc-pad="scroll"]{',
          'padding-bottom:260px!important;scroll-padding-bottom:260px!important;',
          '}'
        ].join('');

        function norm(value) { return String(value || '').replace(/\\s+/g, ' ').trim(); }
        function visible(el) {
          if (!el) return false;
          try {
            var s = getComputedStyle(el);
            var r = el.getBoundingClientRect();
            return s.display !== 'none' &&
              s.visibility !== 'hidden' &&
              r.width > 4 &&
              r.height > 4 &&
              r.bottom > 0 &&
              r.right > 0 &&
              r.top < (innerHeight || document.documentElement.clientHeight || 0) &&
              r.left < (innerWidth || document.documentElement.clientWidth || 0);
          } catch (_) { return false; }
        }
        function textOf(el) {
          try { return norm(el && (el.innerText || el.textContent) || ''); } catch (_) { return ''; }
        }
        function labelOf(el) {
          try {
            return norm([
              el.getAttribute && (el.getAttribute('aria-label') || ''),
              el.getAttribute && (el.getAttribute('title') || ''),
              el.getAttribute && (el.getAttribute('role') || ''),
              el.id || '',
              el.className || '',
              el.innerText || el.textContent || ''
            ].join(' '));
          } catch (_) { return ''; }
        }
        function rectOf(el) {
          try {
            var r = el.getBoundingClientRect();
            return {
              left: Math.round(r.left),
              top: Math.round(r.top),
              width: Math.round(r.width),
              height: Math.round(r.height),
              right: Math.round(r.right),
              bottom: Math.round(r.bottom)
            };
          } catch (_) {
            return { left:0, top:0, width:0, height:0, right:0, bottom:0 };
          }
        }
        function save(el) {
          if (!el || !el.dataset) return;
          if (el.dataset.crPrevTocPadStyle == null) el.dataset.crPrevTocPadStyle = el.getAttribute('style') || '';
        }
        function mark(el, role) {
          if (!el) return;
          save(el);
          el.setAttribute('data-cr-toc-pad', role);
        }
        function cleanup() {
          Array.from(document.querySelectorAll('[data-cr-toc-pad]')).forEach(function(el) {
            try {
              if (el.getAttribute('data-cr-toc-pad') === 'spacer') {
                if (el.parentNode) el.parentNode.removeChild(el);
                return;
              }
              var prev = el.dataset ? el.dataset.crPrevTocPadStyle : null;
              if (prev != null) {
                if (prev) el.setAttribute('style', prev);
                else el.removeAttribute('style');
                delete el.dataset.crPrevTocPadStyle;
              }
              el.removeAttribute('data-cr-toc-pad');
            } catch (_) {}
          });
        }
        function looksLikeTOCEntry(el) {
          if (!visible(el)) return false;
          var t = textOf(el);
          if (!t || t.length < 2 || t.length > 180) return false;
          var hay = (labelOf(el) + ' ' + t).toLowerCase();
          if (/^(kindle library|search|aa|bookmark|more|previous page|next page|read aloud|explain|close|font|layout|margin)$/i.test(t)) return false;
          if (crKindleUITextMatches('next', t) ||
              crKindleUITextMatches('previous', t) ||
              crKindleUITextMatches('close', t) ||
              crKindleUITextMatches('settings', t)) return false;
          if (el.matches && el.matches(
              '[data-location],[data-position],[data-cfi],[data-section],[data-chapter],[role="treeitem"],[role="listitem"],[role="menuitem"]'
          )) return true;
          if (crKindleUIStructureScore(el, 'toc') >= 45) return true;
          if (crKindleUITextMatches('toc', t)) return true;
          return /chapter|contents|author|note|part|prologue|epilogue|目录|章节/.test(hay);
        }
        function shadowQueryAll(root, selector) {
          var out = [];
          try {
            if (root && root.shadowRoot) {
              out = out.concat(Array.from(root.shadowRoot.querySelectorAll(selector)));
            }
          } catch (_) {}
          return out;
        }
        function findCommonRoot(entries) {
          var best = null;
          entries.forEach(function(entry) {
            var el = entry;
            var hops = 0;
            while (el && el.nodeType === 1 && hops < 12) {
              var count = 0;
              entries.forEach(function(other) {
                try { if (el.contains(other)) count += 1; } catch (_) {}
              });
              var r = rectOf(el);
              if (count >= Math.min(3, entries.length) && r.width > 120 && r.height > 120) {
                var tag = String(el.tagName || '').toLowerCase();
                var label = labelOf(el).toLowerCase();
                var area = Math.max(1, r.width * r.height);
                var score = count * 10000 - area / 200;
                if (/ion-menu|ion-modal|ion-popover/.test(tag)) score += 800;
                if (/dialog|menu|toc|contents|chapter|navigation/.test(label)) score += 400;
                if (/^(html|body|ion-app)$/.test(tag)) score -= 2000;
                if (r.top <= -8 && r.bottom >= (innerHeight || document.documentElement.clientHeight || 0) + 8) score -= 500;
                if (!best || score > best.score) best = { el: el, score: score };
              }
              el = el.parentElement;
              hops += 1;
            }
          });
          return best && best.el ? best.el : null;
        }
        function findScrollTarget(root, entries) {
          var nodes = [];
          try { nodes = nodes.concat(Array.from(root.querySelectorAll('ion-content,ion-list,.inner-scroll,.scroll-y,[part="scroll"],[class*="scroll" i],[class*="content" i]'))); } catch (_) {}
          nodes = nodes.concat(shadowQueryAll(root, '.inner-scroll,.scroll-y,[part="scroll"],[part="container"],main,section,div'));
          try {
            Array.from(root.querySelectorAll('*')).forEach(function(el) {
              if (nodes.indexOf(el) < 0 && el.scrollHeight > el.clientHeight + 20) nodes.push(el);
            });
          } catch (_) {}
          var best = null;
          nodes.forEach(function(el) {
            var r = rectOf(el);
            if (r.width < 120 || r.height < 80) return;
            var count = 0;
            entries.forEach(function(entry) {
              try { if (el.contains(entry)) count += 1; } catch (_) {}
            });
            var score = count * 100 + Math.max(0, (el.scrollHeight || 0) - (el.clientHeight || 0)) + r.height;
            if (!best || score > best.score) best = { el: el, score: score };
          });
          return best && best.el ? best.el : root;
        }
        function findTopFillers(root, entries) {
          var out = [];
          if (!root || !entries.length) return out;
          var minTop = Infinity;
          entries.forEach(function(entry) {
            var r = rectOf(entry);
            if (r.top > 0 && r.top < minTop) minTop = r.top;
          });
          if (!Number.isFinite(minTop) || minTop < 40) return out;
          var nodes = [];
          try { nodes = nodes.concat(Array.from(root.children || [])); } catch (_) {}
          try { nodes = nodes.concat(Array.from(root.querySelectorAll('ion-header,ion-toolbar,header,[role="toolbar"],[class*="toolbar" i],[class*="header" i]'))); } catch (_) {}
          nodes.forEach(function(el) {
            var r = rectOf(el);
            if (r.height < 20) return;
            if (r.bottom <= minTop + 4 && r.top >= -4) {
              var hasEntry = false;
              entries.forEach(function(entry) {
                try { if (el.contains(entry)) hasEntry = true; } catch (_) {}
              });
              if (!hasEntry && out.indexOf(el) < 0) out.push(el);
            }
          });
          return out.slice(0, 6);
        }
        function findChromeAbove(entries) {
          var out = [];
          if (!entries.length) return out;
          var minTop = Infinity;
          entries.forEach(function(entry) {
            var r = rectOf(entry);
            if (r.top > 0 && r.top < minTop) minTop = r.top;
          });
          if (!Number.isFinite(minTop)) return out;
          var selectors = [
            'ion-header',
            'ion-toolbar',
            'header',
            '[role="toolbar"]',
            '[class*="toolbar" i]',
            '[class*="header" i]',
            'button',
            '[role="button"]',
            'ion-button'
          ].join(',');
          var nodes = [];
          try { nodes = Array.from(document.querySelectorAll(selectors)); } catch (_) {}
          nodes.forEach(function(el) {
            if (!visible(el)) return;
            var r = rectOf(el);
            if (r.height < 18 || r.bottom > minTop + 4) return;
            var label = labelOf(el).toLowerCase();
            var text = textOf(el).toLowerCase();
            var hay = label + ' ' + text;
            if (!/kindle library|search|aa|bookmark|more|menu|toc|contents|table of contents|font|layout|margin/.test(hay) &&
                !/toolbar|header/.test(String(el.className || '').toLowerCase())) {
              return;
            }
            var hasEntry = false;
            entries.forEach(function(entry) {
              try { if (el.contains(entry)) hasEntry = true; } catch (_) {}
            });
            if (!hasEntry && out.indexOf(el) < 0) out.push(el);
          });
          return out.slice(0, 12);
        }
        function pullScrollContentUp(root, scrollTarget, entries) {
          if (!scrollTarget || !entries.length) return { gap:0, rootTop:0, firstTop:0 };
          var rootRect = rectOf(root || scrollTarget);
          var scrollRect = rectOf(scrollTarget);
          var firstTop = Infinity;
          entries.forEach(function(entry) {
            var r = rectOf(entry);
            if (r.top > 0 && r.top < firstTop) firstTop = r.top;
          });
          if (!Number.isFinite(firstTop)) return { gap:0, rootTop:rootRect.top, firstTop:0 };
          var contentTop = Math.max(0, Math.min(
            scrollRect.top > 0 ? scrollRect.top : rootRect.top,
            rootRect.top > 0 ? rootRect.top : scrollRect.top
          ));
          if (!Number.isFinite(contentTop) || contentTop < 0) contentTop = 0;
          var gap = Math.round(firstTop - contentTop - 12);
          if (gap <= 24) return { gap:0, rootTop:rootRect.top, scrollTop:scrollRect.top, firstTop:firstTop };
          gap = Math.min(gap, 180);
          save(scrollTarget);
          try {
            scrollTarget.style.setProperty('transform', 'translateY(-' + gap + 'px)', 'important');
            scrollTarget.style.setProperty('height', 'calc(100% + ' + gap + 'px)', 'important');
            scrollTarget.style.setProperty('max-height', 'calc(100% + ' + gap + 'px)', 'important');
            scrollTarget.style.setProperty('padding-top', '0px', 'important');
            scrollTarget.style.setProperty('margin-top', '0px', 'important');
            scrollTarget.dataset.crTocTopGap = String(gap);
          } catch (_) {}
          return { gap:gap, rootTop:rootRect.top, scrollTop:scrollRect.top, firstTop:firstTop };
        }

        cleanup();
        var candidates = Array.from(document.querySelectorAll('a[href],button,[role="button"],[role="menuitem"],[role="listitem"],ion-item,li,span,div'));
        var entries = candidates.filter(looksLikeTOCEntry);
        var seen = new Set();
        entries = entries.filter(function(el) {
          var key = textOf(el).toLowerCase();
          if (seen.has(key)) return false;
          seen.add(key);
          return true;
        });
        if (entries.length < 3) {
          return JSON.stringify({ ok:false, reason:'entries-not-found', count:entries.length, url:location.href });
        }
        var root = findCommonRoot(entries) || document.body;
        var scrollTarget = findScrollTarget(root, entries);
        mark(root, 'root');
        mark(scrollTarget, 'scroll');
        var topFillers = [];
        var chrome = [];
        var pull = { gap:0 };
        return JSON.stringify({
          ok:true,
          count:entries.length,
          first:textOf(entries[0]).slice(0, 80),
          last:textOf(entries[entries.length - 1]).slice(0, 80),
          rootTag:String(root.tagName || ''),
          rootRect:rectOf(root),
          topFillers:topFillers.map(function(el) { return { tag:String(el.tagName || ''), rect:rectOf(el), label:labelOf(el).slice(0, 80) }; }),
          chrome:chrome.map(function(el) { return { tag:String(el.tagName || ''), rect:rectOf(el), label:labelOf(el).slice(0, 80) }; }),
          pull:pull,
          scrollTag:String(scrollTarget && scrollTarget.tagName || ''),
          scrollRect:rectOf(scrollTarget),
          url:location.href
        });
      } catch (e) {
        return JSON.stringify({ ok:false, reason:String(e && e.message || e), url:location.href });
      }
    })();
    """

    static let hideNativeTOCOverlay = """
    (function() {
      try {
        var id = '__cr_castreader_hide_native_toc';
        var style = document.getElementById(id);
        if (!style) {
          style = document.createElement('style');
          style.id = id;
          document.documentElement.appendChild(style);
        }
        document.documentElement.setAttribute('data-cr-native-toc-hidden', '1');
        Array.from(document.querySelectorAll('[data-cr-toc-bridge-root="1"]')).forEach(function(el) {
          try { el.removeAttribute('data-cr-toc-bridge-root'); } catch (_) {}
        });
        Array.from(document.querySelectorAll('ion-menu,ion-modal,ion-popover,[role="dialog"],[role="menu"],[role="navigation"],[aria-modal="true"],.popover-content,.modal-wrapper,[class*="toc" i],[class*="contents" i],[class*="navigation" i]')).forEach(function(el) {
          try {
            var r = el.getBoundingClientRect();
            var label = String((el.getAttribute && (el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('role') || el.className)) || '').toLowerCase();
            var text = String((el.innerText || el.textContent || '')).toLowerCase();
            var looksLikeTOC = /toc|contents|chapter|navigation|go to|location|cover|beginning|section/.test(label + ' ' + text);
            var largePanel = r.width > Math.min(260, (window.innerWidth || 0) * 0.35) && r.height > Math.min(220, (window.innerHeight || 0) * 0.28);
            if (looksLikeTOC && largePanel) el.setAttribute('data-cr-toc-bridge-root', '1');
          } catch (_) {}
        });
        style.textContent = [
          'html[data-cr-native-toc-hidden="1"] ion-menu,',
          'html[data-cr-native-toc-hidden="1"] ion-modal,',
          'html[data-cr-native-toc-hidden="1"] ion-popover,',
          'html[data-cr-native-toc-hidden="1"] [role="dialog"],',
          'html[data-cr-native-toc-hidden="1"] [role="menu"],',
          'html[data-cr-native-toc-hidden="1"] [role="navigation"],',
          'html[data-cr-native-toc-hidden="1"] [aria-modal="true"],',
          'html[data-cr-native-toc-hidden="1"] .popover-content,',
          'html[data-cr-native-toc-hidden="1"] .modal-wrapper,',
          'html[data-cr-native-toc-hidden="1"] [data-cr-toc-bridge-root="1"]{',
          'position:fixed!important;',
          'top:0!important;right:0!important;bottom:auto!important;left:auto!important;',
          'width:min(420px,46vw)!important;',
          'min-width:min(420px,46vw)!important;',
          'max-width:min(420px,46vw)!important;',
          'height:100vh!important;',
          'max-height:100vh!important;',
          'margin:0!important;',
          'overflow:auto!important;',
          'opacity:0!important;',
          'pointer-events:none!important;',
          'visibility:visible!important;',
          'transform:none!important;',
          'contain:layout style paint!important;',
          'z-index:-1!important;',
          'box-shadow:none!important;',
          '}',
          'html[data-cr-native-toc-hidden="1"] [class*="chapter" i]{',
          'opacity:0!important;pointer-events:none!important;',
          '}',
          'html[data-cr-native-toc-hidden="1"] ion-menu ion-content,',
          'html[data-cr-native-toc-hidden="1"] ion-modal ion-content,',
          'html[data-cr-native-toc-hidden="1"] ion-popover ion-content,',
          'html[data-cr-native-toc-hidden="1"] [role="dialog"] ion-content,',
          'html[data-cr-native-toc-hidden="1"] [role="navigation"] ion-content,',
          'html[data-cr-native-toc-hidden="1"] .popover-content ion-content,',
          'html[data-cr-native-toc-hidden="1"] .modal-wrapper ion-content{',
          'height:100%!important;',
          'max-height:100%!important;',
          'overflow:auto!important;',
          '-webkit-overflow-scrolling:touch!important;',
          '}'
        ].join('');
        return JSON.stringify({ ok:true, hidden:true, url:location.href });
      } catch (e) {
        return JSON.stringify({ ok:false, reason:String(e && e.message || e), url:location.href });
      }
    })();
    """

    static let showNativeTOCOverlay = """
    (function() {
      try {
        document.documentElement.removeAttribute('data-cr-native-toc-hidden');
        Array.from(document.querySelectorAll('[data-cr-toc-bridge-root="1"]')).forEach(function(el) {
          try { el.removeAttribute('data-cr-toc-bridge-root'); } catch (_) {}
        });
        var style = document.getElementById('__cr_castreader_hide_native_toc');
        if (style && style.parentNode) style.parentNode.removeChild(style);
        return JSON.stringify({ ok:true, hidden:false, url:location.href });
      } catch (e) {
        return JSON.stringify({ ok:false, reason:String(e && e.message || e), url:location.href });
      }
    })();
    """

    static let nativeTOCScanStep = """
    (function(reset) {
      \(uiSemanticHelpers)
      window.__crKindleNativeTOCScan = window.__crKindleNativeTOCScan || {
        entries: [],
        byKey: {},
        activeByKey: {},
        stable: 0,
        lastScrollTop: -1,
        lastCount: 0,
        started: false
      };
      var scan = window.__crKindleNativeTOCScan;
      if (reset) {
        scan.entries = [];
        scan.byKey = {};
        scan.activeByKey = {};
        scan.stable = 0;
        scan.lastScrollTop = -1;
        scan.lastCount = 0;
        scan.started = false;
      }
      function norm(value) { return String(value || '').replace(/\\s+/g, ' ').trim(); }
      function visible(el) {
        if (!el) return false;
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            rect.width > 3 &&
            rect.height > 3 &&
            rect.bottom > 0 &&
            rect.right > 0 &&
            rect.top < (innerHeight || document.documentElement.clientHeight || 0) &&
            rect.left < (innerWidth || document.documentElement.clientWidth || 0);
        } catch (_) { return false; }
      }
      function textOf(el) {
        try { return norm(el && (el.innerText || el.textContent) || ''); } catch (_) { return ''; }
      }
      function labelOf(el) {
        try {
          return norm([
            el.getAttribute && (el.getAttribute('aria-label') || ''),
            el.getAttribute && (el.getAttribute('title') || ''),
            el.getAttribute && (el.getAttribute('data-testid') || ''),
            el.getAttribute && (el.getAttribute('role') || ''),
            el.id || '',
            el.className || '',
            el.innerText || el.textContent || ''
          ].join(' '));
        } catch (_) { return ''; }
      }
      function scrollNodeFor(el) {
        if (!el) return null;
        function rangeOf(node) {
          try {
            return Math.max(0, Number(node.scrollHeight || 0) - Number(node.clientHeight || 0));
          } catch (_) {
            return 0;
          }
        }
        function isScrollable(node) {
          var range = rangeOf(node);
          if (range <= 8) return false;
          try {
            var style = getComputedStyle(node);
            var overflow = String((style && (style.overflowY || style.overflow)) || '').toLowerCase();
            return range > 8 || /auto|scroll|overlay/.test(overflow);
          } catch (_) {
            return true;
          }
        }
        var best = null;
        var bestRange = 0;
        function consider(node) {
          if (!node || node.nodeType !== 1) return;
          var range = rangeOf(node);
          if (range > bestRange && isScrollable(node)) {
            best = node;
            bestRange = range;
          }
        }
        function visit(node, depth) {
          if (!node || node.nodeType !== 1 || depth > 7) return;
          consider(node);
          try {
            if (node.shadowRoot) {
              var preferred = node.shadowRoot.querySelector('[part="scroll"],.inner-scroll,.scroll-y,.scroll-content');
              if (preferred) consider(preferred);
              Array.from(node.shadowRoot.querySelectorAll('[part="scroll"],.inner-scroll,.scroll-y,.scroll-content,ion-content,ion-list,div,main,section'))
                .slice(0, 120)
                .forEach(function(child) { visit(child, depth + 1); });
            }
          } catch (_) {}
          try {
            Array.from(node.children || [])
              .slice(0, 120)
              .forEach(function(child) { visit(child, depth + 1); });
          } catch (_) {}
        }
        visit(el, 0);
        try {
          for (var node = el; node && node.nodeType === 1; node = node.parentElement) {
            consider(node);
          }
        } catch (_) {}
        return best || el;
      }
      function rectOf(el) {
        try {
          var r = el.getBoundingClientRect();
          return { left:Math.round(r.left), top:Math.round(r.top), width:Math.round(r.width), height:Math.round(r.height), right:Math.round(r.right), bottom:Math.round(r.bottom) };
        } catch (_) {
          return { left:0, top:0, width:0, height:0, right:0, bottom:0 };
        }
      }
      function badEntryText(text) {
        var v = String(text || '').toLowerCase();
        if (!v || v.length < 2 || v.length > 180) return true;
        if (/^(kindle library|search|aa|bookmark|more|previous page|next page|page \\d+|read aloud|explain|close|done|font|layout|margin|page color|side panel close)$/i.test(text) ||
            /preferred font|single column|two columns|narrow|medium|wide|time left|page in book|reading progress/i.test(text)) {
          return true;
        }
        return crKindleUITextMatches('next', text) ||
          crKindleUITextMatches('previous', text) ||
          crKindleUITextMatches('close', text) ||
          crKindleUITextMatches('settings', text) ||
          crKindleUITextMatches('single-column', text) ||
          crKindleUITextMatches('narrow', text);
      }
      function clickableEntryNode(el) {
        try { return el && el.closest && el.closest('a[href],button,[role="button"],[role="menuitem"],ion-button,ion-item,li') || el; } catch (_) { return el; }
      }
      function activeState(el) {
        try {
          var node = clickableEntryNode(el);
          var state = norm([
            node && node.id || '',
            el && el.id || '',
            node && node.getAttribute && (node.getAttribute('aria-current') || ''),
            node && node.getAttribute && (node.getAttribute('aria-selected') || ''),
            node && node.getAttribute && (node.getAttribute('selected') || ''),
            node && node.getAttribute && (node.getAttribute('data-selected') || ''),
            node && node.getAttribute && (node.getAttribute('data-active') || ''),
            node && node.getAttribute && (node.getAttribute('data-current') || ''),
            node && node.className || '',
            el && el.className || ''
          ].join(' ')).toLowerCase();
          return /\\b(current|selected|active|checked|highlight|is-active|is-selected)\\b/.test(state) ||
            state.indexOf('page') === 0 ||
            state === 'true';
        } catch (_) { return false; }
      }
      function nodePath(el) {
        try {
          var parts = [];
          for (var node = el; node && node.nodeType === 1 && node !== document.documentElement; node = node.parentElement) {
            var tag = String(node.tagName || '').toLowerCase();
            var parent = node.parentElement;
            if (!parent) break;
            var siblings = Array.from(parent.children).filter(function(child) { return child.tagName === node.tagName; });
            var index = Math.max(1, siblings.indexOf(node) + 1);
            parts.unshift(tag + ':nth-of-type(' + index + ')');
            if (parts.length >= 8) break;
          }
          return parts.join('>');
        } catch (_) { return ''; }
      }
      function attrOf(el, name) {
        try { return el && el.getAttribute ? String(el.getAttribute(name) || '') : ''; } catch (_) { return ''; }
      }
      function hrefOf(el) {
        try {
          if (!el) return '';
          var raw = attrOf(el, 'href') || attrOf(el, 'data-href') || attrOf(el, 'data-url') || '';
          if (!raw && el.href) raw = String(el.href || '');
          if (!raw) return '';
          try { return new URL(raw, location.href).href; } catch (_) { return raw; }
        } catch (_) { return ''; }
      }
      function compactAttrs(el) {
        try {
          if (!el || !el.attributes) return '';
          var names = [
            'id','class','role','href','title','aria-label','aria-current','aria-selected','aria-level',
            'data-testid','data-id','data-key','data-ref','data-href','data-url','data-location','data-cfi',
            'data-chapter','data-section','data-index','data-page','data-target','data-action'
          ];
          var parts = [];
          names.forEach(function(name) {
            var value = attrOf(el, name);
            if (value) parts.push(name + '=' + value.replace(/\\s+/g, ' ').slice(0, 120));
          });
          try {
            Array.from(el.attributes).forEach(function(attr) {
              if (!attr || !attr.name || names.indexOf(attr.name) >= 0) return;
              if (!/^data-/i.test(attr.name)) return;
              parts.push(attr.name + '=' + String(attr.value || '').replace(/\\s+/g, ' ').slice(0, 120));
            });
          } catch (_) {}
          return parts.slice(0, 18).join(' | ');
        } catch (_) { return ''; }
      }
      function actionInfo(el, node) {
        var candidates = [];
        var seen = new Set();
        function add(item, reason) {
          try {
            if (!item || item.nodeType !== 1 || seen.has(item)) return;
            seen.add(item);
            var tag = String(item.tagName || '').toLowerCase();
            var role = attrOf(item, 'role').toLowerCase();
            var href = hrefOf(item);
            var label = labelOf(item);
            var score = 0;
            if (href) score += 1000;
            if (tag === 'a') score += 280;
            if (tag === 'button' || tag === 'ion-button') score += 220;
            if (tag === 'ion-item') score += 170;
            if (/button|menuitem|listitem|link/.test(role)) score += 120;
            if (attrOf(item, 'data-location') || attrOf(item, 'data-position') ||
                attrOf(item, 'data-cfi') || attrOf(item, 'data-section') ||
                attrOf(item, 'data-chapter')) score += 180;
            if (crKindleUITextMatches('toc', label)) score += 40;
            candidates.push({ el:item, score:score, href:href, role:role, tag:tag, reason:reason, label:label.slice(0, 120) });
          } catch (_) {}
        }
        add(node, 'node');
        add(el, 'source');
        try { Array.from((node || el).querySelectorAll('a[href],button,[role="button"],[role="menuitem"],[role="listitem"],ion-button,ion-item,[href],[data-href],[data-url],[data-location],[data-cfi]')).slice(0, 24).forEach(function(child) { add(child, 'child'); }); } catch (_) {}
        try {
          var parent = node || el;
          for (var i = 0; parent && parent.nodeType === 1 && i < 6; i++, parent = parent.parentElement) {
            add(parent, 'ancestor' + i);
          }
        } catch (_) {}
        candidates.sort(function(a, b) { return b.score - a.score; });
        var best = candidates[0] || { el:node || el, href:'', role:'', tag:'', reason:'none', label:'' };
        var bestEl = best.el || node || el;
        return {
          href: best.href || '',
          role: best.role || '',
          aria: attrOf(bestEl, 'aria-label'),
          path: nodePath(bestEl),
          actionSummary: [
            'tag=' + (best.tag || ''),
            'reason=' + (best.reason || ''),
            'score=' + Math.round(best.score || 0),
            'attrs=' + compactAttrs(bestEl),
            'label=' + (best.label || '')
          ].join(' || ').slice(0, 800)
        };
      }
      function entryLikeCount(root) {
        var count = 0;
        try {
          Array.from(root.querySelectorAll('a[href],button,[role="button"],[role="menuitem"],[role="listitem"],ion-item,li')).forEach(function(el) {
            if (count >= 80 || !visible(el)) return;
            var node = clickableEntryNode(el);
            var text = textOf(node);
            if (badEntryText(text)) return;
            var structural = crKindleUIStructureScore(el, 'toc') >= 45 ||
              !!(el.matches && el.matches(
                '[data-location],[data-position],[data-cfi],[data-section],[data-chapter],[role="treeitem"],[role="listitem"],[role="menuitem"]'
              ));
            if (structural || crKindleUITextMatches('toc', text) ||
                /cover|author|prologue|epilogue|note|appendix|part\\s+\\d+|section\\s+\\d+/i.test(text)) {
              count += 1;
            }
          });
        } catch (_) {}
        return count;
      }
      function findContainers() {
        var selectors = [
          'ion-menu','ion-modal','ion-popover','[role="dialog"]','[role="menu"]','[role="navigation"]','[aria-modal="true"]',
          '.popover-content','.modal-wrapper','[class*="toc" i]','[class*="contents" i]','[class*="chapter" i]','[class*="navigation" i]',
          'ion-content','ion-list'
        ].join(',');
        var containers = [];
        Array.from(document.querySelectorAll(selectors)).forEach(function(el) {
          if (!visible(el)) return;
          var scroll = scrollNodeFor(el);
          var txt = textOf(el).toLowerCase();
          var label = labelOf(el).toLowerCase();
          var r = rectOf(el);
          var semanticScore = crKindleUISemanticScore(el, 'toc');
          var looksLikeTOC = semanticScore >= 45 ||
            /chapter\\s+\\d+|table of contents|contents|go to|location|cover|beginning|section/.test(txt + ' ' + label);
          var scrollable = scroll && ((scroll.scrollHeight || 0) - (scroll.clientHeight || 0)) > 8;
          var large = r.height > Math.min(220, (innerHeight || 0) * 0.30) && r.width > Math.min(220, (innerWidth || 0) * 0.30);
          var entryCount = entryLikeCount(el);
          if (looksLikeTOC || entryCount >= 3 || (scrollable && large)) {
            var scrollRange = scroll ? Math.max(0, (scroll.scrollHeight || 0) - (scroll.clientHeight || 0)) : 0;
            var score = entryCount * 10000 + (looksLikeTOC ? 5000 : 0) +
              semanticScore * 10 + (scrollable ? 1200 : 0) +
              (large ? 300 : 0) + Math.min(999, scrollRange);
            containers.push({ host:el, scroll:scroll || el, label:label, rect:r, score:score, entryCount:entryCount });
          }
        });
        containers.sort(function(a, b) {
          if (b.score !== a.score) return b.score - a.score;
          var as = Math.max(0, (a.scroll.scrollHeight || 0) - (a.scroll.clientHeight || 0));
          var bs = Math.max(0, (b.scroll.scrollHeight || 0) - (b.scroll.clientHeight || 0));
          if (bs !== as) return bs - as;
          var at = textOf(a.host).length;
          var bt = textOf(b.host).length;
          if (bt !== at) return bt - at;
          return bs - as;
        });
        return containers;
      }
      function rememberVisibleActive(container) {
        var activeTexts = [];
        try {
          Array.from(container.querySelectorAll('a[href],button,[role="button"],[role="menuitem"],[role="listitem"],ion-item,li')).forEach(function(el) {
            if (!visible(el)) return;
            var node = clickableEntryNode(el);
            var text = textOf(node);
            if (badEntryText(text)) return;
            var key = text.toLowerCase();
            if (!key) return;
            if (activeState(node) || activeState(el)) {
              scan.activeByKey[key] = true;
              activeTexts.push(text);
            }
          });
        } catch (_) {}
        return activeTexts;
      }
      function collect(container) {
        var nodes = [];
        var seen = new Set();
        Array.from(container.querySelectorAll('a[href],button,[role="button"],[role="menuitem"],[role="listitem"],ion-item,li')).forEach(function(el) {
          if (!visible(el)) return;
          var node = clickableEntryNode(el);
          if (seen.has(node)) return;
          seen.add(node);
          var text = textOf(node);
          if (badEntryText(text)) return;
          var r = rectOf(node);
          if (r.width < 20 || r.height < 14) return;
          var key = text.toLowerCase();
          if (activeState(node) || activeState(el)) scan.activeByKey[key] = true;
          if (scan.byKey[key]) return;
          var ariaLevel = (node.getAttribute && node.getAttribute('aria-level')) || (el.getAttribute && el.getAttribute('aria-level'));
          var level = ariaLevel && !isNaN(Number(ariaLevel)) ? Number(ariaLevel) : 0;
          var action = actionInfo(el, node);
          var entry = {
            index: scan.entries.length,
            text: text,
            level: level,
            active: activeState(node) || activeState(el) || !!scan.activeByKey[key],
            path: nodePath(node),
            sourcePath: nodePath(el),
            href: action.href || '',
            role: action.role || '',
            aria: action.aria || '',
            actionPath: action.path || '',
            actionSummary: action.actionSummary || '',
            rect: r
          };
          scan.byKey[key] = true;
          scan.entries.push(entry);
          nodes.push(entry);
        });
        return nodes;
      }
      function setScrollTop(scrollEl, y) {
        var target = Math.max(0, Math.round(Number(y || 0)));
        try { scrollEl.scrollTop = target; } catch (_) {}
        try { if (scrollEl.scrollTo) scrollEl.scrollTo(0, target); } catch (_) {}
        try { scrollEl.dispatchEvent(new Event('scroll', { bubbles:true, cancelable:false })); } catch (_) {}
      }
      var containers = findContainers();
      var item = containers[0] || null;
      if (!item) {
        return JSON.stringify({ ok:false, stage:'toc-container-not-found', done:false, entries:scan.entries, count:scan.entries.length, url:location.href });
      }
      var scrollEl = item.scroll || item.host;
      var scrollTop = Number(scrollEl.scrollTop || 0);
      var clientHeight = Number(scrollEl.clientHeight || 0);
      var scrollHeight = Number(scrollEl.scrollHeight || 0);
      var maxScroll = Math.max(0, scrollHeight - clientHeight);
      if (!scan.started) {
        var initialActive = rememberVisibleActive(item.host);
        setScrollTop(scrollEl, 0);
        scan.started = true;
        scan.lastScrollTop = -1;
        scan.lastCount = 0;
        return JSON.stringify({
          ok:true,
          stage:'toc-scan-reset-top',
          done:false,
          count:scan.entries.length,
          added:0,
          visibleCount:0,
          scrollTop:Math.round(scrollTop),
          clientHeight:Math.round(clientHeight),
          scrollHeight:Math.round(scrollHeight),
          maxScroll:Math.round(maxScroll),
          containerTag:String((item.host && item.host.tagName) || ''),
          scrollTag:String((scrollEl && scrollEl.tagName) || ''),
          containerLabel:String(item.label || '').slice(0, 140),
          containerScore:Math.round(item.score || 0),
          entryHint:Math.round(item.entryCount || 0),
          activeHint:initialActive.join(' | ').slice(0, 240),
          stable:scan.stable,
          entries:scan.entries,
          url:location.href
        });
      }
      var before = scan.entries.length;
      var visibleEntries = collect(item.host);
      scrollTop = Number(scrollEl.scrollTop || 0);
      clientHeight = Number(scrollEl.clientHeight || 0);
      scrollHeight = Number(scrollEl.scrollHeight || 0);
      maxScroll = Math.max(0, scrollHeight - clientHeight);
      var atBottom = scrollTop >= maxScroll - 4;
      var noMove = Math.abs(scrollTop - Number(scan.lastScrollTop || -1)) < 2;
      var noGrowth = scan.entries.length === scan.lastCount;
      if (atBottom || (noMove && noGrowth && scan.stable >= 2)) {
        scan.stable += 1;
      } else {
        scan.stable = noGrowth ? scan.stable + 1 : 0;
      }
      var done = atBottom && scan.stable >= 2;
      if (!done) {
        var step = Math.max(80, Math.floor(clientHeight * 0.82));
        setScrollTop(scrollEl, Math.min(maxScroll, scrollTop + step));
      }
      scan.lastScrollTop = scrollTop;
      scan.lastCount = scan.entries.length;
      return JSON.stringify({
        ok:true,
        stage:done ? 'toc-scan-done' : 'toc-scan-step',
        done:done,
        count:scan.entries.length,
        added:scan.entries.length - before,
        visibleCount:visibleEntries.length,
        scrollTop:Math.round(scrollTop),
        clientHeight:Math.round(clientHeight),
        scrollHeight:Math.round(scrollHeight),
        maxScroll:Math.round(maxScroll),
        containerTag:String((item.host && item.host.tagName) || ''),
        scrollTag:String((scrollEl && scrollEl.tagName) || ''),
        containerLabel:String(item.label || '').slice(0, 140),
        containerScore:Math.round(item.score || 0),
        entryHint:Math.round(item.entryCount || 0),
        activeHint:Object.keys(scan.activeByKey || {}).slice(0, 8).join(' | ').slice(0, 240),
        stable:scan.stable,
        entries:scan.entries,
        url:location.href
      });
    })(arguments[0]);
    """

    static let nativeTOCJumpStep = """
    (function(targetIndex, targetText, targetPath, targetHref, reset, cachedEntries) {
      \(uiSemanticHelpers)
      window.__crKindleNativeTOCJump = window.__crKindleNativeTOCJump || {
        stable: 0,
        lastScrollTop: -1,
        clickedTargetText: '',
        clickedTargetIndex: -1,
        targetClicks: 0,
        childClicks: 0
      };
      var state = window.__crKindleNativeTOCJump;
      if (reset) {
        state.stable = 0;
        state.lastScrollTop = -1;
        state.clickedTargetText = '';
        state.clickedTargetIndex = -1;
        state.targetClicks = 0;
        state.childClicks = 0;
        state.clickStrategy = 0;
        state.lastFramework = {};
        state.visibleTargetText = '';
        state.visibleTargetScrollTop = -1;
        state.visibleTargetStable = 0;
      }
      function norm(value) { return String(value || '').replace(/\\s+/g, ' ').trim(); }
      function attrOf(el, name) {
        try { return el && el.getAttribute ? String(el.getAttribute(name) || '') : ''; } catch (_) { return ''; }
      }
      function hrefOf(el) {
        try {
          if (!el) return '';
          var raw = attrOf(el, 'href') || attrOf(el, 'data-href') || attrOf(el, 'data-url') || String((el && el.href) || '');
          if (!raw) return '';
          try { return new URL(raw, location.href).href; } catch (_) { return raw; }
        } catch (_) { return ''; }
      }
      function usableHref(href) {
        try {
          if (!href) return '';
          var u = new URL(href, location.href);
          if (!/^https?:$/i.test(u.protocol)) return '';
          if (u.host !== location.host) return '';
          if (u.href === location.href) return '';
          return u.href;
        } catch (_) {
          return '';
        }
      }
      function nodePath(el) {
        try {
          var parts = [];
          for (var node = el; node && node.nodeType === 1 && node !== document.documentElement; node = node.parentElement) {
            var tag = String(node.tagName || '').toLowerCase();
            var parent = node.parentElement;
            if (!parent) break;
            var siblings = Array.from(parent.children).filter(function(child) { return child.tagName === node.tagName; });
            var index = Math.max(1, siblings.indexOf(node) + 1);
            parts.unshift(tag + ':nth-of-type(' + index + ')');
            if (parts.length >= 8) break;
          }
          return parts.join('>');
        } catch (_) { return ''; }
      }
      function compactAttrs(el) {
        try {
          if (!el || !el.attributes) return '';
          var names = ['id','class','role','href','title','aria-label','aria-current','aria-selected','aria-level','data-testid','data-id','data-key','data-ref','data-href','data-url','data-location','data-cfi','data-chapter','data-section','data-index','data-page','data-target','data-action'];
          var parts = [];
          names.forEach(function(name) {
            var value = attrOf(el, name);
            if (value) parts.push(name + '=' + value.replace(/\\s+/g, ' ').slice(0, 120));
          });
          try {
            Array.from(el.attributes).forEach(function(attr) {
              if (!attr || !attr.name || names.indexOf(attr.name) >= 0) return;
              if (!/^data-/i.test(attr.name)) return;
              parts.push(attr.name + '=' + String(attr.value || '').replace(/\\s+/g, ' ').slice(0, 120));
            });
          } catch (_) {}
          return parts.slice(0, 18).join(' | ');
        } catch (_) { return ''; }
      }
      function visible(el) {
        if (!el) return false;
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            rect.width > 3 &&
            rect.height > 3 &&
            rect.bottom > 0 &&
            rect.right > 0 &&
            rect.top < (innerHeight || document.documentElement.clientHeight || 0) &&
            rect.left < (innerWidth || document.documentElement.clientWidth || 0);
        } catch (_) { return false; }
      }
      function textOf(el) {
        try { return norm(el && (el.innerText || el.textContent) || ''); } catch (_) { return ''; }
      }
      function labelOf(el) {
        try { return norm([el.getAttribute && (el.getAttribute('aria-label') || ''), el.id || '', el.className || '', el.innerText || el.textContent || ''].join(' ')); } catch (_) { return ''; }
      }
      function scrollNodeFor(el) {
        if (!el) return null;
        function rangeOf(node) {
          try {
            return Math.max(0, Number(node.scrollHeight || 0) - Number(node.clientHeight || 0));
          } catch (_) {
            return 0;
          }
        }
        function isScrollable(node) {
          var range = rangeOf(node);
          if (range <= 8) return false;
          try {
            var style = getComputedStyle(node);
            var overflow = String((style && (style.overflowY || style.overflow)) || '').toLowerCase();
            return range > 8 || /auto|scroll|overlay/.test(overflow);
          } catch (_) {
            return true;
          }
        }
        var best = null;
        var bestRange = 0;
        function consider(node) {
          if (!node || node.nodeType !== 1) return;
          var range = rangeOf(node);
          if (range > bestRange && isScrollable(node)) {
            best = node;
            bestRange = range;
          }
        }
        function visit(node, depth) {
          if (!node || node.nodeType !== 1 || depth > 7) return;
          consider(node);
          try {
            if (node.shadowRoot) {
              var preferred = node.shadowRoot.querySelector('[part="scroll"],.inner-scroll,.scroll-y,.scroll-content');
              if (preferred) consider(preferred);
              Array.from(node.shadowRoot.querySelectorAll('[part="scroll"],.inner-scroll,.scroll-y,.scroll-content,ion-content,ion-list,div,main,section'))
                .slice(0, 120)
                .forEach(function(child) { visit(child, depth + 1); });
            }
          } catch (_) {}
          try {
            Array.from(node.children || [])
              .slice(0, 120)
              .forEach(function(child) { visit(child, depth + 1); });
          } catch (_) {}
        }
        visit(el, 0);
        try {
          for (var node = el; node && node.nodeType === 1; node = node.parentElement) {
            consider(node);
          }
        } catch (_) {}
        return best || el;
      }
      function clickableEntryNode(el) {
        try { return el && el.closest && el.closest('a[href],button,[role="button"],[role="menuitem"],ion-button,ion-item,li') || el; } catch (_) { return el; }
      }
      function shadowActionNodes(el) {
        var out = [];
        try {
          if (!el || !el.shadowRoot) return out;
          Array.from(el.shadowRoot.querySelectorAll('a[href],button,[part="native"],.item-native,[role="button"],[href]'))
            .slice(0, 12)
            .forEach(function(child) { out.push(child); });
        } catch (_) {}
        return out;
      }
      function actionInfo(el) {
        var candidates = [];
        var seen = new Set();
        function add(item, reason) {
          try {
            if (!item || item.nodeType !== 1 || seen.has(item)) return;
            seen.add(item);
            var tag = String(item.tagName || '').toLowerCase();
            var role = attrOf(item, 'role').toLowerCase();
            var href = hrefOf(item);
            var label = labelOf(item);
            var score = 0;
            if (href) score += 1000;
            if (tag === 'a') score += 280;
            if (tag === 'button' || tag === 'ion-button') score += 220;
            if (attrOf(item, 'part') === 'native' || /item-native/.test(attrOf(item, 'class'))) score += 240;
            if (tag === 'ion-item') score += 170;
            if (/button|menuitem|listitem|link/.test(role)) score += 120;
            if (attrOf(item, 'data-location') || attrOf(item, 'data-position') ||
                attrOf(item, 'data-cfi') || attrOf(item, 'data-section') ||
                attrOf(item, 'data-chapter')) score += 180;
            if (crKindleUITextMatches('toc', label)) score += 40;
            candidates.push({ el:item, score:score, href:href, role:role, tag:tag, reason:reason, label:label.slice(0, 120) });
          } catch (_) {}
        }
        add(clickableEntryNode(el), 'clickable');
        add(el, 'source');
        try { Array.from(el.querySelectorAll('a[href],button,[role="button"],[role="menuitem"],[role="listitem"],ion-button,ion-item,[href],[data-href],[data-url],[data-location],[data-cfi]')).slice(0, 24).forEach(function(child) { add(child, 'child'); }); } catch (_) {}
        try { shadowActionNodes(clickableEntryNode(el)).forEach(function(child) { add(child, 'shadow'); }); } catch (_) {}
        try { shadowActionNodes(el).forEach(function(child) { add(child, 'source-shadow'); }); } catch (_) {}
        try {
          var parent = el;
          for (var i = 0; parent && parent.nodeType === 1 && i < 6; i++, parent = parent.parentElement) {
            add(parent, 'ancestor' + i);
            shadowActionNodes(parent).forEach(function(child) { add(child, 'ancestor-shadow' + i); });
          }
        } catch (_) {}
        candidates.sort(function(a, b) { return b.score - a.score; });
        var best = candidates[0] || { el:clickableEntryNode(el), score:0, href:'', role:'', tag:'', reason:'none', label:'' };
        var bestEl = best.el || clickableEntryNode(el) || el;
        return {
          el: bestEl,
          href: best.href || '',
          role: best.role || '',
          tag: best.tag || '',
          path: nodePath(bestEl),
          summary: [
            'tag=' + (best.tag || ''),
            'reason=' + (best.reason || ''),
            'score=' + Math.round(best.score || 0),
            'attrs=' + compactAttrs(bestEl),
            'label=' + (best.label || '')
          ].join(' || ').slice(0, 800)
        };
      }
      function fakeInteractionEvent(target) {
        return {
          type:'click',
          target:target,
          currentTarget:target,
          detail:{ source:'castreader' },
          nativeEvent:{ type:'click', target:target, isTrusted:true },
          bubbles:true,
          cancelable:true,
          defaultPrevented:false,
          isDefaultPrevented:function() { return false; },
          isPropagationStopped:function() { return false; },
          preventDefault:function() { this.defaultPrevented = true; },
          stopPropagation:function() {},
          persist:function() {}
        };
      }
      function frameworkHandlerInfo(el) {
        var names = [];
        try {
          var nodes = [];
          var seen = new Set();
          function add(node) {
            if (!node || node.nodeType !== 1 || seen.has(node)) return;
            seen.add(node);
            nodes.push(node);
          }
          add(el);
          add(clickableEntryNode(el));
          try { Array.from((clickableEntryNode(el) || el).querySelectorAll('*')).slice(0, 24).forEach(add); } catch (_) {}
          try { shadowActionNodes(clickableEntryNode(el)).forEach(add); } catch (_) {}
          try {
            for (var parent = el; parent && parent.nodeType === 1 && nodes.length < 60; parent = parent.parentElement) add(parent);
          } catch (_) {}
          nodes.forEach(function(node) {
            try {
              Object.keys(node).forEach(function(key) {
                if (/^__reactProps\\$|^__reactEventHandlers\\$|^__reactFiber\\$|^__reactInternalInstance\\$|^_listeners$|^__zone_symbol__/.test(key)) {
                  names.push(String(node.tagName || '').toLowerCase() + ':' + key);
                }
              });
            } catch (_) {}
          });
        } catch (_) {}
        return names.slice(0, 16).join(',');
      }
      function invokeFrameworkHandlers(el, skipCount) {
        var invoked = 0;
        var names = [];
        var errors = [];
        var available = [];
        var candidates = [];
        var seenNode = new Set();
        var seenHandler = new Set();
        var handlerNames = [
          'onClick',
          'onTap',
          'onClickCapture',
          'onPointerDown',
          'onPointerUp',
          'onMouseDown',
          'onMouseUp',
          'onTouchStart',
          'onTouchEnd',
          'onIonSelect',
          'onIonActivate',
          'onclick'
        ];
        function addHandler(fn, node, name, priority) {
          if (typeof fn !== 'function' || seenHandler.has(fn)) return;
          seenHandler.add(fn);
          candidates.push({ fn:fn, node:node, name:name, priority:priority });
          available.push(name);
        }
        function callFirstHandler() {
          candidates.sort(function(a, b) { return a.priority - b.priority; });
          var item = candidates[Math.max(0, Number(skipCount || 0))] || null;
          if (!item) return;
          try {
            item.fn.call(item.node, fakeInteractionEvent(item.node));
            invoked += 1;
            names.push(item.name);
          } catch (e) {
            errors.push(item.name + ':' + String(e && e.message || e).slice(0, 80));
          }
        }
        function inspectProps(props, node, source, priority) {
          if (!props || typeof props !== 'object') return;
          handlerNames.forEach(function(name, index) {
            addHandler(props[name], node, source + '.' + name, priority + index);
          });
          try {
            if (props.children && typeof props.children === 'object') {
              handlerNames.forEach(function(name, index) {
                addHandler(props.children[name], node, source + '.children.' + name, priority + 100 + index);
              });
            }
          } catch (_) {}
        }
        function inspectFiber(fiber, node, source) {
          var cur = fiber;
          for (var depth = 0; cur && depth < 8; depth++, cur = cur.return) {
            inspectProps(cur.memoizedProps, node, source + '.fiber' + depth, 40 + depth * 20);
            inspectProps(cur.pendingProps, node, source + '.pending' + depth, 160 + depth * 20);
          }
        }
        function inspectNode(node) {
          if (!node || node.nodeType !== 1 || seenNode.has(node)) return;
          seenNode.add(node);
          try {
            Object.keys(node).forEach(function(key) {
              if (/^__reactProps\\$|^__reactEventHandlers\\$/.test(key)) inspectProps(node[key], node, key, 20);
              if (/^__reactFiber\\$|^__reactInternalInstance\\$/.test(key)) inspectFiber(node[key], node, key);
              if (key === '_listeners' && node[key]) inspectProps(node[key], node, key, 700);
            });
          } catch (_) {}
          try { addHandler(node.onclick, node, 'dom.onclick', 900); } catch (_) {}
        }
        try {
          inspectNode(el);
          inspectNode(clickableEntryNode(el));
          try { Array.from((clickableEntryNode(el) || el).querySelectorAll('*')).slice(0, 36).forEach(inspectNode); } catch (_) {}
          try { shadowActionNodes(clickableEntryNode(el)).forEach(inspectNode); } catch (_) {}
          try { shadowActionNodes(el).forEach(inspectNode); } catch (_) {}
          try {
            for (var parent = el; parent && parent.nodeType === 1 && seenNode.size < 80; parent = parent.parentElement) inspectNode(parent);
          } catch (_) {}
        } catch (e) {
          errors.push(String(e && e.message || e).slice(0, 120));
        }
        callFirstHandler();
        return { invoked:invoked, names:names.slice(0, 12).join(','), available:available.slice(0, 12).join(','), skip:Math.max(0, Number(skipCount || 0)), errors:errors.slice(0, 5).join('|'), keys:frameworkHandlerInfo(el) };
      }
      function clickElement(el) {
        if (!el) return false;
        try {
          var info = actionInfo(el);
          var row = clickableEntryNode(el);
          var target = info.el || row || el;
          var strategy = Math.max(0, Number(state.clickStrategy || 0));
          state.clickStrategy = strategy + 1;
          var framework = { invoked:0, names:'', available:'', errors:'', keys:frameworkHandlerInfo(row || target || el), strategy:strategy };
          if (strategy <= 3) {
            framework = invokeFrameworkHandlers(row || target || el, strategy);
            framework.strategy = strategy;
            state.lastFramework = framework;
            if (Number(framework.invoked || 0) > 0) return true;
          }
          state.lastFramework = framework;
          var rowRect = row && row.getBoundingClientRect ? row.getBoundingClientRect() : null;
          var targetRect = target.getBoundingClientRect ? target.getBoundingClientRect() : null;
          var rect = rowRect || targetRect;
          var pointTarget = null;
          var pointX = rect ? Math.max(rect.left + 12, rect.right - Math.min(34, Math.max(18, rect.width * 0.10))) : 0;
          var pointY = rect ? (rect.top + rect.height / 2) : 0;
          if (strategy >= 2) {
            try { if (rect) pointTarget = document.elementFromPoint(pointX, pointY); } catch (_) {}
            if (pointTarget && pointTarget.nodeType === 1) target = pointTarget;
          } else {
            target = row || target || el;
          }
          var opts = rect ? { clientX:pointX, clientY:pointY, bubbles:true, cancelable:true, composed:true, view:window } : { bubbles:true,cancelable:true, composed:true, view:window };
          try { target.focus && target.focus({ preventScroll:true }); } catch (_) {}
          try { target.dispatchEvent(new PointerEvent('pointerover', Object.assign({ pointerId:1, pointerType:'touch', isPrimary:true }, opts))); } catch (_) {}
          try { target.dispatchEvent(new PointerEvent('pointerenter', Object.assign({ pointerId:1, pointerType:'touch', isPrimary:true }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mouseover', opts)); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mouseenter', opts)); } catch (_) {}
          try { target.dispatchEvent(new PointerEvent('pointerdown', Object.assign({ pointerId:1, pointerType:'touch', isPrimary:true, button:0, buttons:1 }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mousedown', opts)); } catch (_) {}
          try {
            if (typeof Touch === 'function' && typeof TouchEvent === 'function' && rect) {
              var touch = new Touch({ identifier:1, target:target, clientX:opts.clientX, clientY:opts.clientY, screenX:opts.clientX, screenY:opts.clientY, pageX:opts.clientX, pageY:opts.clientY });
              target.dispatchEvent(new TouchEvent('touchstart', { touches:[touch], targetTouches:[touch], changedTouches:[touch], bubbles:true, cancelable:true, composed:true }));
              target.dispatchEvent(new TouchEvent('touchend', { touches:[], targetTouches:[], changedTouches:[touch], bubbles:true, cancelable:true, composed:true }));
            }
          } catch (_) {}
          try { target.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerId:1, pointerType:'touch', isPrimary:true, button:0, buttons:0 }, opts))); } catch (_) {}
          try { target.dispatchEvent(new MouseEvent('mouseup', opts)); } catch (_) {}
          try { target.dispatchEvent(new CustomEvent('tap', { bubbles:true, cancelable:true, composed:true, detail:{ source:'castreader' } })); } catch (_) {}
          try { target.click(); } catch (_) { try { target.dispatchEvent(new MouseEvent('click', opts)); } catch (_) {} }
          try { target.dispatchEvent(new KeyboardEvent('keydown', { key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true, cancelable:true, composed:true })); } catch (_) {}
          try { target.dispatchEvent(new KeyboardEvent('keyup', { key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true, cancelable:true, composed:true })); } catch (_) {}
          try { target.__crFrameworkClickResult = framework; } catch (_) {}
          return true;
        } catch (_) { return false; }
      }
      function setScrollTop(scrollEl, y) {
        var target = Math.max(0, Math.round(Number(y || 0)));
        try { scrollEl.scrollTop = target; } catch (_) {}
        try { if (scrollEl.scrollTo) scrollEl.scrollTo(0, target); } catch (_) {}
        try { scrollEl.dispatchEvent(new Event('scroll', { bubbles:true, cancelable:false })); } catch (_) {}
      }
      function badEntryText(text) {
        var v = String(text || '').toLowerCase();
        if (!v || v.length < 2 || v.length > 180) return true;
        if (/^(kindle library|search|aa|bookmark|more|previous page|next page|page \\d+|read aloud|explain|close|done|font|layout|margin|page color|side panel close)$/i.test(text) ||
            /preferred font|single column|two columns|narrow|medium|wide|time left|page in book|reading progress/i.test(text)) {
          return true;
        }
        return crKindleUITextMatches('next', text) ||
          crKindleUITextMatches('previous', text) ||
          crKindleUITextMatches('close', text) ||
          crKindleUITextMatches('settings', text) ||
          crKindleUITextMatches('single-column', text) ||
          crKindleUITextMatches('narrow', text);
      }
      function findContainers() {
        var selectors = [
          'ion-menu','ion-modal','ion-popover','[role="dialog"]','[role="menu"]','[role="navigation"]','[aria-modal="true"]',
          '.popover-content','.modal-wrapper','[class*="toc" i]','[class*="contents" i]','[class*="chapter" i]','[class*="navigation" i]',
          'ion-content','ion-list'
        ].join(',');
        var containers = [];
        Array.from(document.querySelectorAll(selectors)).forEach(function(el) {
          if (!visible(el)) return;
          var scroll = scrollNodeFor(el);
          var txt = textOf(el).toLowerCase();
          var label = labelOf(el).toLowerCase();
          var structuralEntries = el.querySelectorAll(
            '[data-location],[data-position],[data-cfi],[data-section],[data-chapter],[role="treeitem"],[role="listitem"],[role="menuitem"],a[href],ion-item,li'
          ).length;
          var looksLikeTOC = crKindleUISemanticScore(el, 'toc') >= 45 ||
            /chapter\\s+\\d+|table of contents|contents|go to|location|cover|beginning|section/.test(txt + ' ' + label);
          var scrollable = scroll && ((scroll.scrollHeight || 0) - (scroll.clientHeight || 0)) > 8;
          if (looksLikeTOC || (scrollable && structuralEntries >= 2)) {
            containers.push({ host:el, scroll:scroll || el, label:label, entryCount:structuralEntries });
          }
        });
        containers.sort(function(a, b) {
          if (Number(b.entryCount || 0) !== Number(a.entryCount || 0)) {
            return Number(b.entryCount || 0) - Number(a.entryCount || 0);
          }
          var as = Math.max(0, (a.scroll.scrollHeight || 0) - (a.scroll.clientHeight || 0));
          var bs = Math.max(0, (b.scroll.scrollHeight || 0) - (b.scroll.clientHeight || 0));
          if (bs !== as) return bs - as;
          var at = textOf(a.host).length;
          var bt = textOf(b.host).length;
          if (bt !== at) return bt - at;
          return bs - as;
        });
        return containers;
      }
      function knownIndexForText(text) {
        try {
          var scan = window.__crKindleNativeTOCScan;
          if (scan && scan.entries) {
            var key = norm(text).toLowerCase();
            for (var i = 0; i < scan.entries.length; i++) {
              if (norm(scan.entries[i].text).toLowerCase() === key) return i;
            }
          }
        } catch (_) {}
        try {
          var rows = Array.isArray(cachedEntries) ? cachedEntries : [];
          var cachedKey = norm(text).toLowerCase();
          for (var j = 0; j < rows.length; j++) {
            var row = rows[j] || {};
            if (norm(row.text).toLowerCase() === cachedKey) {
              var idx = Number(row.index);
              return isNaN(idx) ? j : idx;
            }
          }
        } catch (_) {}
        return null;
      }
      var targetHrefValue = usableHref(String(targetHref || ''));
      if (targetHrefValue) {
        try {
          location.assign(targetHrefValue);
          return JSON.stringify({ ok:true, stage:'toc-jump-param-href', clicked:false, href:targetHrefValue, text:String(targetText || ''), index:targetIndex, url:location.href });
        } catch (_) {}
      }
      var target = norm(targetText).toLowerCase();
      var containers = findContainers();
      var item = containers[0] || null;
      if (!item) return JSON.stringify({ ok:false, stage:'toc-jump-no-container', clicked:false, url:location.href });
      var container = item.host;
      var scrollEl = item.scroll || item.host;
      var nodes = Array.from(container.querySelectorAll('a[href],button,[role="button"],[role="menuitem"],[role="listitem"],ion-item,li')).filter(visible);
      var visibleIndexes = [];
      if (state.clickedTargetText === target && Number(state.targetClicks || 0) > 0 && Number(state.childClicks || 0) < 3) {
        var afterTarget = false;
        var nextKnownIndex = null;
        var targetNumForChild = Number(targetIndex || 0);
        for (var ci = 0; ci < nodes.length; ci++) {
          var childNode = clickableEntryNode(nodes[ci]);
          var childText = textOf(childNode);
          if (badEntryText(childText)) continue;
          var childKey = norm(childText).toLowerCase();
          var childKnown = knownIndexForText(childText);
          if (!afterTarget) {
            if (childKey === target) afterTarget = true;
            continue;
          }
          if (childKnown !== null && childKnown > targetNumForChild) {
            nextKnownIndex = childKnown;
            break;
          }
          if (childKey === target || (childKnown !== null && childKnown <= targetNumForChild)) continue;
          var childInfo = actionInfo(childNode);
          var childHref = usableHref(childInfo.href);
          if (childHref) {
            location.assign(childHref);
            return JSON.stringify({ ok:true, stage:'toc-jump-expanded-child-href', clicked:false, href:childHref, text:childText, index:targetIndex, childClicks:Number(state.childClicks || 0), nextKnownIndex:nextKnownIndex, action:childInfo.summary, actionPath:childInfo.path, url:location.href });
          }
          state.childClicks = Number(state.childClicks || 0) + 1;
          var childClicked = clickElement(childNode);
          return JSON.stringify({ ok:childClicked, stage:'toc-jump-expanded-child-clicked', clicked:childClicked, text:childText, index:targetIndex, childClicks:state.childClicks, nextKnownIndex:nextKnownIndex, framework:state.lastFramework || {}, action:childInfo.summary, actionPath:childInfo.path, url:location.href });
        }
      }
      for (var i = 0; i < nodes.length; i++) {
        var node = clickableEntryNode(nodes[i]);
        var text = textOf(node);
        if (badEntryText(text)) continue;
        var key = norm(text).toLowerCase();
        var known = knownIndexForText(text);
        if (known !== null) visibleIndexes.push(known);
        if (key === target) {
          var info = actionInfo(node);
          var href = usableHref(info.href);
          if (href) {
            location.assign(href);
            return JSON.stringify({ ok:true, stage:'toc-jump-text-href', clicked:false, href:href, text:text, index:targetIndex, action:info.summary, actionPath:info.path, url:location.href });
          }
          state.visibleTargetText = target;
          state.visibleTargetScrollTop = Math.round(Number(scrollEl.scrollTop || 0));
          state.visibleTargetStable = Number(state.visibleTargetStable || 0) + 1;
          if (state.clickedTargetText === target && Number(state.targetClicks || 0) >= 3) {
            return JSON.stringify({ ok:false, stage:'toc-jump-clicked-no-navigation', clicked:false, text:text, index:targetIndex, targetClicks:Number(state.targetClicks || 0), framework:state.lastFramework || {}, action:info.summary, actionPath:info.path, url:location.href });
          }
          state.clickedTargetText = target;
          state.clickedTargetIndex = Number(targetIndex || 0);
          state.targetClicks = Number(state.targetClicks || 0) + 1;
          var clicked = clickElement(node);
          return JSON.stringify({ ok:clicked, stage:'toc-jump-clicked', clicked:clicked, text:text, index:targetIndex, targetClicks:state.targetClicks, framework:state.lastFramework || {}, href:info.href, action:info.summary, actionPath:info.path, url:location.href });
        }
      }
      if (targetPath) {
        try {
          var direct = document.querySelector(targetPath);
          var directText = textOf(direct);
          if (direct && visible(direct) && norm(directText).toLowerCase() === target) {
            var directInfo = actionInfo(direct);
            var directHref = usableHref(directInfo.href);
            if (directHref) {
              location.assign(directHref);
              return JSON.stringify({ ok:true, stage:'toc-jump-path-href', clicked:false, href:directHref, text:directText, index:targetIndex, action:directInfo.summary, actionPath:directInfo.path, url:location.href });
            }
            var directClicked = clickElement(direct);
            return JSON.stringify({ ok:directClicked, stage:'toc-jump-path-clicked', clicked:directClicked, text:directText, index:targetIndex, framework:state.lastFramework || {}, href:directInfo.href, action:directInfo.summary, actionPath:directInfo.path, url:location.href });
          }
        } catch (_) {}
      }
      var scrollTop = Number(scrollEl.scrollTop || 0);
      var clientHeight = Number(scrollEl.clientHeight || 0);
      var scrollHeight = Number(scrollEl.scrollHeight || 0);
      var maxScroll = Math.max(0, scrollHeight - clientHeight);
      var minVisible = visibleIndexes.length ? Math.min.apply(Math, visibleIndexes) : null;
      var maxVisible = visibleIndexes.length ? Math.max.apply(Math, visibleIndexes) : null;
      var targetNum = Number(targetIndex || 0);
      var direction = (minVisible !== null && targetNum < minVisible) ? -1 : 1;
      var step = Math.max(80, Math.floor(clientHeight * 0.80));
      var next = Math.max(0, Math.min(maxScroll, scrollTop + direction * step));
      if (Math.abs(next - scrollTop) < 2) {
        state.stable += 1;
      } else {
        state.stable = 0;
        setScrollTop(scrollEl, next);
      }
      return JSON.stringify({
        ok:false,
        stage:'toc-jump-scroll',
        clicked:false,
        index:targetIndex,
        minVisible:minVisible,
        maxVisible:maxVisible,
        direction:direction,
        scrollTop:Math.round(scrollTop),
        next:Math.round(next),
        maxScroll:Math.round(maxScroll),
        containerTag:String((container && container.tagName) || ''),
        scrollTag:String((scrollEl && scrollEl.tagName) || ''),
        stable:state.stable,
        url:location.href
      });
    })(arguments[0], arguments[1], arguments[2], arguments[3], arguments[4], arguments[5]);
    """

    static let pageModeLockBootstrap = """
    (function() {
      \(uiSemanticHelpers)
      var crKindlePageModeLockVersion = 7;
      window.__crKindleProbe = window.__crKindleProbe || {};
      window.__crKindleProbe.pageModeLocked = !!window.__crKindleProbe.pageModeLocked;
      window.__crKindleProbe.programmaticScrollUntil = Number(window.__crKindleProbe.programmaticScrollUntil || 0);
      window.__crKindleProbe.navigationSeq = Number(window.__crKindleProbe.navigationSeq || 0);
      window.__crKindleProbe.navigationAt = Number(window.__crKindleProbe.navigationAt || 0);
      window.__crKindleProbe.navigationReason = String(window.__crKindleProbe.navigationReason || '');

      function crKindleNow() { return Date.now ? Date.now() : new Date().getTime(); }
      function crKindleIsProgrammaticScroll() {
        try { return crKindleNow() < Number(window.__crKindleProbe.programmaticScrollUntil || 0); } catch (_) { return false; }
      }
      function crKindleInstallSelectionBlocker() {
        try {
          if (window.__crKindleSelectionBlockerVersion === 1) return;
          window.__crKindleSelectionBlockerVersion = 1;
          function locked() {
            try {
              return !!(window.__crKindleProbe && window.__crKindleProbe.pageModeLocked) ||
                document.documentElement.classList.contains('cr-kindle-page-mode-locked');
            } catch (_) {
              return false;
            }
          }
          function editable(target) {
            try {
              var el = target && (target.nodeType === 1 ? target : target.parentElement);
              while (el && el !== document.body && el !== document.documentElement) {
                var tag = String(el.tagName || '').toLowerCase();
                if (tag === 'input' || tag === 'textarea' || tag === 'select') return true;
                if (el.isContentEditable) return true;
                el = el.parentElement;
              }
            } catch (_) {}
            return false;
          }
          function clearSelection() {
            try {
              var selection = window.getSelection && window.getSelection();
              if (selection && selection.rangeCount) selection.removeAllRanges();
            } catch (_) {}
          }
          function block(e) {
            if (!locked() || editable(e && e.target)) return;
            try { e.preventDefault(); } catch (_) {}
            try { e.stopImmediatePropagation(); } catch (_) {}
            try { e.stopPropagation(); } catch (_) {}
            clearSelection();
            return false;
          }
          document.addEventListener('contextmenu', block, true);
          document.addEventListener('selectstart', block, true);
          document.addEventListener('selectionchange', function() {
            if (!locked()) return;
            setTimeout(clearSelection, 0);
          }, true);
        } catch (_) {}
      }
      function crKindleHideCastReaderChrome(locked) {
        try {
          var root = document.documentElement;
          var hiddenClass = 'cr-kindle-castreader-hidden-chrome';
          if (!locked) {
            root.classList.remove('cr-kindle-castreader-chrome-hidden');
            Array.from(document.querySelectorAll('.' + hiddenClass)).forEach(function(el) {
              try { el.classList.remove(hiddenClass); } catch (_) {}
            });
            return;
          }
          root.classList.add('cr-kindle-castreader-chrome-hidden');
          function textOf(el) {
            try {
              return [
                el.getAttribute && (el.getAttribute('aria-label') || ''),
                el.getAttribute && (el.getAttribute('title') || ''),
                el.getAttribute && (el.getAttribute('data-testid') || ''),
                el.id || '',
                el.className || '',
                (el.innerText || el.textContent || '')
              ].join(' ').replace(/\\s+/g, ' ').trim();
            } catch (_) {
              return '';
            }
          }
          function visible(el) {
            try {
              var r = el.getBoundingClientRect();
              var s = getComputedStyle(el);
              return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 1 && r.height > 1;
            } catch (_) {
              return false;
            }
          }
          function hasReaderContent(el) {
            try {
              return !!(el && el.querySelector && el.querySelector('#kr-renderer, img[src^="blob:"], .kg-full-page-img, [class*="kindle-reader"], [class*="reader-content"]'));
            } catch (_) {
              return false;
            }
          }
          function chromeTarget(el) {
            var best = el;
            try {
              var label = textOf(el).toLowerCase();
              for (var node = el, depth = 0; node && depth < 7 && node !== document.body && node !== document.documentElement; depth++, node = node.parentElement) {
                if (hasReaderContent(node)) continue;
                var r = node.getBoundingClientRect && node.getBoundingClientRect();
                if (!r || r.width <= 0 || r.height <= 0) continue;
                var nodeLabel = textOf(node).toLowerCase();
                var nearEdge = r.top < 150 || r.bottom > (innerHeight || 0) - 150;
                var toolbarLike = /toolbar|header|footer|scrubber|progress|control|pagination|reader-menu|reader-header|reader-footer/.test(nodeLabel);
                var compactBand = r.height <= Math.min(150, Math.max(80, (innerHeight || 0) * 0.22)) && r.width >= (innerWidth || 0) * 0.35;
                if ((nearEdge && compactBand) || toolbarLike) best = node;
                if (crKindleUISemanticScore(el, 'previous') >= 45 ||
                    crKindleUISemanticScore(el, 'next') >= 45) best = el;
              }
            } catch (_) {}
            return best || el;
          }
          function hide(el) {
            try {
              if (!el) return;
              chromeTarget(el).classList.add(hiddenClass);
            } catch (_) {}
          }
          function hidePageTurnControl(el) {
            try {
              if (!el) return;
              el.setAttribute('data-cr-kindle-page-turn-control', '1');
              var target = chromeTarget(el);
              target.classList.remove(hiddenClass);
              target.style.opacity = '0';
              target.style.pointerEvents = 'none';
              target.style.visibility = 'visible';
            } catch (_) {}
          }
          [
            '#kr-scrubber-bar',
            'ion-range.scrubber-bar'
          ].forEach(function(sel) {
            try { Array.from(document.querySelectorAll(sel)).forEach(hide); } catch (_) {}
          });
          [
            '#kr-chevron-left',
            '#kr-chevron-right',
            'button[aria-label="Previous page"]',
            'button[aria-label="Next page"]',
            'button[title="Previous page"]',
            'button[title="Next page"]'
          ].forEach(function(sel) {
            try { Array.from(document.querySelectorAll(sel)).forEach(hidePageTurnControl); } catch (_) {}
          });
          Array.from(document.querySelectorAll('button,[role="button"],ion-button,ion-range,[aria-label],[title]')).forEach(function(el) {
            if (!visible(el)) return;
            var label = textOf(el).toLowerCase();
            if (crKindleUISemanticScore(el, 'previous') >= 45 ||
                crKindleUISemanticScore(el, 'next') >= 45) {
              hidePageTurnControl(el);
            } else if (/^(kindle library|search|aa|bookmark)$/.test(label)
              || /kindle library|page \\d+|time left|reading progress|bookmark|search/.test(label)) {
              hide(el);
            }
          });
          Array.from(document.querySelectorAll('ion-header,ion-footer,header,footer,[role="toolbar"],[class*="toolbar"],[class*="reader-header"],[class*="reader-footer"],[class*="scrubber"],[class*="progress"]')).forEach(function(el) {
            if (!visible(el) || hasReaderContent(el)) return;
            var r = el.getBoundingClientRect();
            if (r.height <= 170 && (r.top < 170 || r.bottom > (innerHeight || 0) - 170)) hide(el);
          });
        } catch (_) {}
      }
      function crKindleApplyPageModeLockStyles(locked) {
        try {
          var wasLocked = document.documentElement.classList.contains('cr-kindle-page-mode-locked');
          var id = 'cr-kindle-page-mode-lock-style';
          var style = document.getElementById(id);
          if (!style) {
            style = document.createElement('style');
            style.id = id;
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = [
            'html.cr-kindle-page-mode-locked, html.cr-kindle-page-mode-locked body, html.cr-kindle-page-mode-locked body * {',
            '  -webkit-touch-callout: none !important;',
            '  -webkit-user-select: none !important;',
            '  user-select: none !important;',
            '}',
            'html.cr-kindle-page-mode-locked ::selection { background: transparent !important; }',
            'html.cr-kindle-page-mode-locked, html.cr-kindle-page-mode-locked body { overscroll-behavior: none !important; }',
            'html.cr-kindle-page-mode-locked img { -webkit-user-drag: none !important; }',
            'html.cr-kindle-page-mode-locked #kr-renderer,',
            'html.cr-kindle-page-mode-locked .kr-renderer-container-fullpage,',
            'html.cr-kindle-page-mode-locked .kr-interaction-layer-fullpage,',
            'html.cr-kindle-page-mode-locked .kg-view,',
            'html.cr-kindle-page-mode-locked .kg-full-page-img,',
            'html.cr-kindle-page-mode-locked .kg-full-page-img img,',
            'html.cr-kindle-page-mode-locked img[src^="blob:"] {',
            '  touch-action: none !important;',
            '  overscroll-behavior: contain !important;',
            '  -webkit-user-select: none !important;',
            '  user-select: none !important;',
            '}',
            'html.cr-kindle-page-mode-locked .cr-kindle-castreader-hidden-chrome,',
            'html.cr-kindle-page-mode-locked #kr-scrubber-bar,',
            'html.cr-kindle-page-mode-locked ion-range.scrubber-bar {',
            '  display: none !important;',
            '  visibility: hidden !important;',
            '  pointer-events: none !important;',
            '}',
            'html.cr-kindle-page-mode-locked #kr-chevron-left,',
            'html.cr-kindle-page-mode-locked #kr-chevron-right,',
            'html.cr-kindle-page-mode-locked button[aria-label="Previous page"],',
            'html.cr-kindle-page-mode-locked button[aria-label="Next page"],',
            'html.cr-kindle-page-mode-locked button[title="Previous page"],',
            'html.cr-kindle-page-mode-locked button[title="Next page"],',
            'html.cr-kindle-page-mode-locked [data-cr-kindle-page-turn-control="1"] {',
            '  opacity: 0 !important;',
            '  visibility: visible !important;',
            '  pointer-events: none !important;',
            '}'
          ].join('\\n');
          if (locked) document.documentElement.classList.add('cr-kindle-page-mode-locked');
          else document.documentElement.classList.remove('cr-kindle-page-mode-locked');
          crKindleInstallSelectionBlocker();
          crKindleHideCastReaderChrome(locked);
          if (locked) {
            setTimeout(function() { crKindleHideCastReaderChrome(true); }, 120);
            setTimeout(function() { crKindleHideCastReaderChrome(true); }, 420);
            setTimeout(function() { crKindleHideCastReaderChrome(true); }, 1000);
            if (!wasLocked) {
              try { window.dispatchEvent(new Event('resize')); } catch (_) {}
            }
          }
        } catch (_) {}
      }
      function crKindleShouldAllowManualScrollTarget(target) {
        try {
          var el = target && (target.nodeType === 1 ? target : target.parentElement);
          while (el && el !== document.body && el !== document.documentElement) {
            var role = String(el.getAttribute && (el.getAttribute('role') || '') || '').toLowerCase();
            var ariaModal = String(el.getAttribute && (el.getAttribute('aria-modal') || '') || '').toLowerCase();
            var label = [
              el.id || '',
              el.className || '',
              el.getAttribute && (el.getAttribute('aria-label') || ''),
              el.getAttribute && (el.getAttribute('data-testid') || ''),
              el.getAttribute && (el.getAttribute('title') || '')
            ].join(' ').toLowerCase();
            var explicitTOC = /(\\btoc\\b|table[-_\\s]*of[-_\\s]*contents|kg[-_\\s]*toc|toc[-_]|[-_]toc\\b|contents|chapter|section|location|go to|goto|navigation|nav-|menu|listitem|ion-content|ion-list|ion-item)/.test(label);
            var overlayRole = /dialog|menu|menuitem|listbox|tree|grid|tablist|navigation/.test(role) || ariaModal === 'true';
            var overlayName = /modal|popover|dropdown|sheet|drawer|side[-_\\s]*panel|side\\.panel|\\bmenu\\b|toolbar|header|footer|search|scrubber|range|slider/.test(label);
            if (explicitTOC || overlayRole || overlayName) return true;
            el = el.parentElement;
          }
        } catch (_) {}
        return false;
      }
      function crKindlePreventManualScroll(e) {
        try {
          if (!window.__crKindleProbe || !window.__crKindleProbe.pageModeLocked) return;
          if (crKindleIsProgrammaticScroll()) return;
          if (crKindleShouldAllowManualScrollTarget(e && e.target)) {
            window.__crKindleProbe.allowedManualScrolls = Number(window.__crKindleProbe.allowedManualScrolls || 0) + 1;
            return;
          }
          window.__crKindleProbe.blockedManualScrolls = Number(window.__crKindleProbe.blockedManualScrolls || 0) + 1;
          e.preventDefault && e.preventDefault();
          e.stopPropagation && e.stopPropagation();
          e.stopImmediatePropagation && e.stopImmediatePropagation();
          return false;
        } catch (_) {}
      }
      function crKindleLooksLikeNavigationTarget(target) {
        try {
          var el = target && (target.nodeType === 1 ? target : target.parentElement);
          for (var depth = 0; el && depth < 8 && el !== document.body && el !== document.documentElement; depth++, el = el.parentElement) {
            var label = [
              el.id || '',
              el.className || '',
              el.getAttribute && (el.getAttribute('role') || ''),
              el.getAttribute && (el.getAttribute('aria-label') || ''),
              el.getAttribute && (el.getAttribute('data-testid') || ''),
              el.getAttribute && (el.getAttribute('title') || ''),
              (el.innerText || '').slice(0, 120)
            ].join(' ').toLowerCase();
            if (crKindleUISemanticScore(el, 'toc') >= 45) return true;
            if (/toc|table.of.contents|contents|chapter|section|location|go to|goto|navigation|nav-|menu|listitem|kg-bookmark|kindle library/.test(label)) return true;
          }
        } catch (_) {}
        return false;
      }
      function crKindleNavigationClick(e) {
        try {
          if (!window.__crKindleProbe || !window.__crKindleProbe.pageModeLocked) return;
          if (!crKindleLooksLikeNavigationTarget(e && e.target)) return;
          var now = crKindleNow();
          if (now - Number(window.__crKindleProbe.navigationAt || 0) < 220) return;
          window.__crKindleProbe.navigationSeq = Number(window.__crKindleProbe.navigationSeq || 0) + 1;
          window.__crKindleProbe.navigationAt = now;
          window.__crKindleProbe.navigationReason = 'kindle-navigation-ui';
        } catch (_) {}
      }
      function crKindleReaderForNativePageTurn() {
        try {
          return document.querySelector('#kr-renderer')
            || document.querySelector('[id*="kr-content"]')
            || document.querySelector('[class*="kg-scroll-runway"]')
            || document.querySelector('[class*="kindle-reader"]')
            || document.body;
        } catch (_) {
          return document.body;
        }
      }
      function crKindleDispatchNativePointerTurn(dir) {
        var reader = crKindleReaderForNativePageTurn();
        if (!reader || !reader.getBoundingClientRect) return false;
        var rect = reader.getBoundingClientRect();
        if (!rect || rect.width <= 0 || rect.height <= 0) return false;
        var x = dir === 'left' ? rect.left + Math.min(48, rect.width * 0.12) : rect.right - Math.min(48, rect.width * 0.12);
        var y = rect.top + rect.height * 0.5;
        var target = document.elementFromPoint(x, y) || reader;
        var opts = { clientX:x, clientY:y, bubbles:true, cancelable:true };
        try {
          target.dispatchEvent(new PointerEvent('pointerdown', Object.assign({ pointerId:1, pointerType:'mouse' }, opts)));
          target.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerId:1, pointerType:'mouse' }, opts)));
        } catch (_) {}
        try { target.dispatchEvent(new MouseEvent('mousedown', opts)); } catch (_) {}
        try { target.dispatchEvent(new MouseEvent('mouseup', opts)); } catch (_) {}
        try { target.dispatchEvent(new MouseEvent('click', opts)); } catch (_) {}
        return true;
      }
      function crKindleNativeControlVisible(el) {
        if (!el || !el.getBoundingClientRect) return false;
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            rect.width > 2 &&
            rect.height > 2;
        } catch (_) {
          return false;
        }
      }
      window.__crKindleTurnNativePage = function(direction) {
        try {
          var raw = String(direction || '').toLowerCase();
          var dir = (raw === 'previous' || raw === 'prev' || raw === 'back' || raw === 'left') ? 'left' : 'right';
          var step = dir === 'left' ? -1 : 1;
          var tried = [];
          window.__crKindleProbe = window.__crKindleProbe || {};
          window.__crKindleProbe.programmaticScrollUntil = crKindleNow() + 2400;
          window.__crKindleProbe.navigationSeq = Number(window.__crKindleProbe.navigationSeq || 0) + 1;
          window.__crKindleProbe.navigationAt = crKindleNow();
          window.__crKindleProbe.navigationReason = 'manual-native-page-' + (dir === 'left' ? 'previous' : 'next');

          var chevron = document.querySelector(dir === 'left' ? '#kr-chevron-left' : '#kr-chevron-right')
            || document.querySelector(dir === 'left' ? 'button[aria-label="Previous page"],button[title="Previous page"]' : 'button[aria-label="Next page"],button[title="Next page"]');
          if (!chevron) {
            var semanticControl = crKindleUIFind(
              dir === 'left' ? 'previous' : 'next',
              document,
              'button,[role="button"],ion-button,[data-testid],[data-action],[aria-label],[title]'
            );
            chevron = semanticControl && semanticControl.el;
          }
          var chevronEnabled = !!chevron && !chevron.disabled && String(chevron.getAttribute && chevron.getAttribute('aria-disabled') || '').toLowerCase() !== 'true';
          var chevronVisible = crKindleNativeControlVisible(chevron);
          if (chevronEnabled) {
            try { chevron.click(); } catch (_) {
              try { chevron.dispatchEvent(new MouseEvent('click', { bubbles:true, cancelable:true })); } catch (_) {}
            }
            return JSON.stringify({ ok:true, direction:dir, strategy:'native-chevron', controlVisible:crKindleNativeControlVisible(chevron), tried:tried.concat(['native-chevron']).join('|'), url:location.href });
          }
          tried.push(chevron ? 'disabled-chevron' : 'no-chevron');

          if (crKindleDispatchNativePointerTurn(dir)) {
            return JSON.stringify({ ok:true, direction:dir, strategy:'native-tap-zone', tried:tried.concat(['native-tap-zone']).join('|'), url:location.href });
          }
          tried.push('no-tap-zone');

          try {
            var key = dir === 'left' ? 'ArrowLeft' : 'ArrowRight';
            var code = dir === 'left' ? 37 : 39;
            var ae = document.activeElement;
            if (ae && ae !== document.body && ae !== document.documentElement && ae.blur) ae.blur();
            var opts = { key:key, code:key, keyCode:code, which:code, bubbles:true, cancelable:true };
            var target = document.activeElement || document.body || document;
            target.dispatchEvent(new KeyboardEvent('keydown', opts));
            target.dispatchEvent(new KeyboardEvent('keyup', opts));
            return JSON.stringify({ ok:true, direction:dir, strategy:'native-keyboard', tried:tried.concat(['native-keyboard']).join('|'), url:location.href });
          } catch (_) {
            tried.push('keyboard-failed');
          }

          var scrubber = document.querySelector('#kr-scrubber-bar') || document.querySelector('ion-range.scrubber-bar');
          if (crKindleNativeControlVisible(scrubber) && typeof scrubber.value === 'number') {
            var oldValue = Number(scrubber.value || 0);
            var newValue = oldValue + step;
            scrubber.value = newValue;
            try { scrubber.dispatchEvent(new CustomEvent('ionInput', { detail: { value:newValue }, bubbles:true })); } catch (_) {}
            try { scrubber.dispatchEvent(new CustomEvent('ionChange', { detail: { value:newValue }, bubbles:true })); } catch (_) {}
            return JSON.stringify({ ok:true, direction:dir, strategy:'native-scrubber', tried:tried.concat(['native-scrubber']).join('|'), oldValue:oldValue, newValue:newValue, url:location.href });
          }
          tried.push(scrubber ? 'hidden-scrubber' : 'no-scrubber');

          return JSON.stringify({ ok:false, direction:dir, reason:'no-native-page-control', tried:tried.join('|'), url:location.href });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e && e.message || e), direction:String(direction || ''), url:location.href });
        }
      };
      if (window.__crKindlePageModeLightInstalledVersion !== crKindlePageModeLockVersion) {
        window.__crKindlePageModeLightInstalledVersion = crKindlePageModeLockVersion;
        try { document.addEventListener('touchmove', crKindlePreventManualScroll, { capture:true, passive:false }); } catch (_) {}
        try { document.addEventListener('pointermove', crKindlePreventManualScroll, { capture:true, passive:false }); } catch (_) {}
        try { document.addEventListener('wheel', crKindlePreventManualScroll, { capture:true, passive:false }); } catch (_) {}
        try { document.addEventListener('gesturestart', crKindlePreventManualScroll, { capture:true, passive:false }); } catch (_) {}
        try { document.addEventListener('click', crKindleNavigationClick, true); } catch (_) {}
      }
      window.__crKindleSetPageModeLocked = function(locked) {
        window.__crKindleProbe = window.__crKindleProbe || {};
        window.__crKindleProbe.pageModeLocked = !!locked;
        crKindleApplyPageModeLockStyles(!!locked);
        return JSON.stringify({
          ok:true,
          locked:window.__crKindleProbe.pageModeLocked,
          light:true,
          blocked:Number(window.__crKindleProbe.blockedManualScrolls || 0),
          allowed:Number(window.__crKindleProbe.allowedManualScrolls || 0),
          url:location.href
        });
      };
      window.__crKindlePageModeDiagnostics = function() {
        function scrollOf(el) {
          try { return el ? { top:Number(el.scrollTop || 0), left:Number(el.scrollLeft || 0), h:Number(el.scrollHeight || 0), ch:Number(el.clientHeight || 0) } : null; } catch (_) { return null; }
        }
        return JSON.stringify({
          ok:true,
          locked:!!(window.__crKindleProbe && window.__crKindleProbe.pageModeLocked),
          blocked:Number(window.__crKindleProbe && window.__crKindleProbe.blockedManualScrolls || 0),
          allowed:Number(window.__crKindleProbe && window.__crKindleProbe.allowedManualScrolls || 0),
          html:scrollOf(document.documentElement),
          body:scrollOf(document.body),
          scrollingElement:scrollOf(document.scrollingElement),
          url:location.href
        });
      };
      return JSON.stringify({ ok:true, installed:true, locked:!!window.__crKindleProbe.pageModeLocked, url:location.href });
    })();
    """

    /// This intentionally stays small because it must run before Amazon's
    /// renderer creates and revokes its pre-rendered page blobs. The full
    /// capture/bootstrap payload is installed lazily after navigation, but by
    /// then these one-shot createObjectURL calls have already happened.
    static let earlyPageBlobCaptureBootstrap = """
    (function() {
      var crKindleEarlyCaptureVersion = 1;
      if (window.__crKindleEarlyCaptureVersion === crKindleEarlyCaptureVersion) return;
      window.__crKindleEarlyCaptureVersion = crKindleEarlyCaptureVersion;

      var probe = window.__crKindleProbe = window.__crKindleProbe || {};
      probe.urlToKey = probe.urlToKey || new Map();
      probe.keyToLiveUrl = probe.keyToLiveUrl || new Map();
      probe.heldPageKeys = probe.heldPageKeys || [];
      probe.earlyCapturedBlobCount = Number(probe.earlyCapturedBlobCount || 0);

      function rememberHeldKey(key) {
        try {
          var stable = 'content-' + String(key || '');
          var order = probe.heldPageKeys || [];
          probe.heldPageKeys = order;
          if (order.indexOf(stable) < 0) order.push(stable);
          if (order.length > 400) probe.heldPageKeys = order.slice(order.length - 400);
        } catch (_) {}
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
        } catch (_) {
          return String(Date.now()) + '-' + Math.floor(Math.random() * 100000);
        }
      }

      if (!URL.__crKindleOriginalCreateObjectURL) {
        URL.__crKindleOriginalCreateObjectURL = URL.createObjectURL.bind(URL);
      }
      var originalCreate = URL.__crKindleOriginalCreateObjectURL;
      URL.createObjectURL = function(obj) {
        var url = originalCreate(obj);
        try {
          if (obj instanceof Blob && obj.type && obj.type.indexOf('image/') === 0) {
            contentKey(obj).then(function(key) {
              probe.urlToKey.set(url, key);
              if (!probe.keyToLiveUrl.has(key)) {
                probe.keyToLiveUrl.set(key, originalCreate(obj));
              }
              rememberHeldKey(key);
              probe.earlyCapturedBlobCount = Number(probe.earlyCapturedBlobCount || 0) + 1;
            }).catch(function(){});
          }
        } catch (_) {}
        return url;
      };
      window.__crKindleEarlyBlobCaptureReady = true;
    })();
    """

    static let pageCaptureBootstrap = """
    (function() {
      \(uiSemanticHelpers)
      var crKindleInstallVersion = 40;
      // OCR keeps the source glyphs lossless. Kindle pages are mostly flat-color
      // text surfaces, so PNG is often no larger than JPEG and avoids destroying
      // CJK punctuation / Devanagari combining marks. 2048px is only a safety cap;
      // normal Kindle surfaces keep their native pixels.
      var crKindleOcrMaxWidth = 2048;
      var crKindleOcrJpegQuality = 1;
      if (window.__crKindleInstalledVersion === crKindleInstallVersion) {
        return;
      }
      window.__crKindleInstalledVersion = crKindleInstallVersion;
      window.__crKindleInstalled = true;
      window.__crKindleProbe = window.__crKindleProbe || {
        idx: 0,
        candidateSeq: 0,
        urlToKey: new Map(),
        keyToLiveUrl: new Map(),
        keyToLiveImg: new Map(),
        liveSessionId: 0,
        visualSeq: 0,
        liveCandidate: null,
        liveState: null,
        liveImagePixelSize: null,
        restoreAnchors: new Map(),
        playbackAnchors: new Map(),
        observedPageKeys: [],
        heldPageKeys: [],
        pageModeLocked: false,
        programmaticScrollUntil: 0,
        manualScrollRestoreRaf: 0,
        navigationSeq: 0,
        navigationAt: 0,
        navigationReason: ''
      };
      window.__crKindleProbe.idx = Number(window.__crKindleProbe.idx || 0);
      window.__crKindleProbe.candidateSeq = Number(window.__crKindleProbe.candidateSeq || 0);
      window.__crKindleProbe.urlToKey = window.__crKindleProbe.urlToKey || new Map();
      window.__crKindleProbe.keyToLiveUrl = window.__crKindleProbe.keyToLiveUrl || new Map();
      window.__crKindleProbe.keyToLiveImg = window.__crKindleProbe.keyToLiveImg || new Map();
      window.__crKindleProbe.liveSessionId = Number(window.__crKindleProbe.liveSessionId || 0);
      window.__crKindleProbe.visualSeq = Number(window.__crKindleProbe.visualSeq || 0);
      window.__crKindleProbe.liveCandidate = window.__crKindleProbe.liveCandidate || null;
      window.__crKindleProbe.liveState = window.__crKindleProbe.liveState || null;
      window.__crKindleProbe.liveImagePixelSize = window.__crKindleProbe.liveImagePixelSize || null;
      window.__crKindleProbe.restoreAnchors = window.__crKindleProbe.restoreAnchors || new Map();
      window.__crKindleProbe.playbackAnchors = window.__crKindleProbe.playbackAnchors || new Map();
      window.__crKindleProbe.observedPageKeys = window.__crKindleProbe.observedPageKeys || [];
      window.__crKindleProbe.heldPageKeys = window.__crKindleProbe.heldPageKeys || [];
      window.__crKindleProbe.pageModeLocked = !!window.__crKindleProbe.pageModeLocked;
      window.__crKindleProbe.programmaticScrollUntil = Number(window.__crKindleProbe.programmaticScrollUntil || 0);
      window.__crKindleProbe.manualScrollRestoreRaf = Number(window.__crKindleProbe.manualScrollRestoreRaf || 0);
      window.__crKindleProbe.navigationSeq = Number(window.__crKindleProbe.navigationSeq || 0);
      window.__crKindleProbe.navigationAt = Number(window.__crKindleProbe.navigationAt || 0);
      window.__crKindleProbe.navigationReason = String(window.__crKindleProbe.navigationReason || '');
      window.__crKindleProbe.syncDialogVisible = !!window.__crKindleProbe.syncDialogVisible;
      window.__crKindleProbe.syncDialogSignature = String(window.__crKindleProbe.syncDialogSignature || '');
      function crKindleNow() { return Date.now ? Date.now() : new Date().getTime(); }
      function crKindlePostNative(type, payload) {
        try {
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.castReaderKindle;
          if (handler && handler.postMessage) {
            handler.postMessage(Object.assign({ type:type }, payload || {}));
          }
        } catch (_) {}
      }
      function crKindleSyncDialogText(el) {
        try {
          var text = String((el && (el.innerText || el.textContent)) || '');
          if (el && el.shadowRoot) text += ' ' + String(el.shadowRoot.textContent || '');
          return text.replace(/\\s+/g, ' ').trim();
        } catch (_) { return ''; }
      }
      function crKindleVisibleElement(el) {
        if (!el || !el.getBoundingClientRect) return false;
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 20 && rect.height > 20;
        } catch (_) { return false; }
      }
      function crKindleSyncDialogCandidate() {
        try {
          var nodes = Array.from(document.querySelectorAll('ion-alert,ion-modal,[role="dialog"],[aria-modal="true"],.alert-wrapper,.modal-wrapper'));
          for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            if (!crKindleVisibleElement(el)) continue;
            var text = crKindleSyncDialogText(el);
            var structuralLocations = el.querySelectorAll(
              '[data-location],[data-position],[data-page],[data-page-number],[data-progress-location],[aria-valuenow]'
            ).length;
            var actionCount = el.querySelectorAll(
              'button,[role="button"],ion-button,[data-action],[data-testid]'
            ).length;
            var structuralScore = crKindleUIStructureScore(el, 'sync-dialog');
            var role = crKindleUINorm(el.getAttribute && (el.getAttribute('role') || ''));
            if (structuralScore >= 190 ||
                ((role === 'dialog' || String(el.getAttribute && el.getAttribute('aria-modal') || '') === 'true') &&
                  structuralLocations >= 2 && actionCount >= 2) ||
                crKindleUITextMatches('sync-dialog', text)) {
              return { element:el, text:text };
            }
          }
        } catch (_) {}
        return null;
      }
      function crKindleInstallSyncDialogButtonObservers(candidate, localLocation, cloudLocation) {
        try {
          var roots = [candidate.element];
          if (candidate.element.shadowRoot) roots.push(candidate.element.shadowRoot);
          roots.forEach(function(root) {
            Array.from(root.querySelectorAll('button,[role="button"],ion-button')).forEach(function(button) {
              if (button.__crKindleSyncObserved) return;
              var yesScore = crKindleUISemanticScore(button, 'yes');
              var noScore = crKindleUISemanticScore(button, 'no');
              var choice = '';
              if (yesScore >= 45 && yesScore >= noScore + 20) choice = 'yes';
              if (noScore >= 45 && noScore >= yesScore + 20) choice = 'no';
              if (!choice) return;
              button.__crKindleSyncObserved = true;
              button.addEventListener('click', function() {
                crKindlePostNative('kindle-sync-dialog-choice', {
                  visible:true,
                  choice:choice,
                  localLocation:localLocation,
                  cloudLocation:cloudLocation
                });
              }, true);
            });
          });
        } catch (_) {}
      }
      function crKindleSyncDialogLocations(candidate) {
        var locations = [];
        var roots = [candidate.element];
        try { if (candidate.element.shadowRoot) roots.push(candidate.element.shadowRoot); } catch (_) {}
        roots.forEach(function(root) {
          try {
            Array.from(root.querySelectorAll(
              '[data-location],[data-position],[data-page],[data-page-number],[data-progress-location],[aria-valuenow]'
            )).forEach(function(el) {
              if (locations.length >= 4) return;
              var raw = [
                el.getAttribute('data-location') || '',
                el.getAttribute('data-position') || '',
                el.getAttribute('data-page') || '',
                el.getAttribute('data-page-number') || '',
                el.getAttribute('data-progress-location') || '',
                el.getAttribute('aria-valuenow') || ''
              ].join(' ');
              var normalized = crKindleUINormalizeDigits(raw);
              var match = normalized.match(/\\d+/);
              if (match) locations.push(Number(match[0] || 0));
            });
          } catch (_) {}
        });
        if (locations.length < 2) {
          var normalizedText = crKindleUINormalizeDigits(candidate.text);
          var regex = /(?:location|position|page|ubicación|posición|página|localização|posição|página|位置|ページ|seite|emplacement|posizione|pagina|स्थान|पृष्ठ)\\s*(?:n[º°.]?\\s*)?[:#-]?\\s*(\\d+)/ig;
          var match;
          while ((match = regex.exec(normalizedText)) !== null && locations.length < 4) {
            locations.push(Number(match[1] || 0));
          }
        }
        return locations;
      }
      function crKindleCheckSyncDialog() {
        try {
          var candidate = crKindleSyncDialogCandidate();
          if (!candidate) {
            if (window.__crKindleProbe.syncDialogVisible) {
              window.__crKindleProbe.syncDialogVisible = false;
              window.__crKindleProbe.syncDialogSignature = '';
              crKindlePostNative('kindle-sync-dialog', { visible:false });
            }
            return;
          }
          var locations = crKindleSyncDialogLocations(candidate);
          var localLocation = locations.length > 0 ? locations[0] : 0;
          var cloudLocation = locations.length > 1 ? locations[1] : 0;
          var signature = String(localLocation) + '|' + String(cloudLocation);
          crKindleInstallSyncDialogButtonObservers(candidate, localLocation, cloudLocation);
          if (!window.__crKindleProbe.syncDialogVisible || window.__crKindleProbe.syncDialogSignature !== signature) {
            window.__crKindleProbe.syncDialogVisible = true;
            window.__crKindleProbe.syncDialogSignature = signature;
            crKindlePostNative('kindle-sync-dialog', {
              visible:true,
              localLocation:localLocation || null,
              cloudLocation:cloudLocation || null
            });
          }
        } catch (_) {}
      }
      try {
        if (window.__crKindleSyncDialogTimer) clearInterval(window.__crKindleSyncDialogTimer);
        window.__crKindleSyncDialogTimer = setInterval(crKindleCheckSyncDialog, 250);
        setTimeout(crKindleCheckSyncDialog, 0);
      } catch (_) {}
      function crKindleAllowProgrammaticScroll(ms) {
        try {
          window.__crKindleProbe.programmaticScrollUntil = Math.max(
            Number(window.__crKindleProbe.programmaticScrollUntil || 0),
            crKindleNow() + Number(ms || 900)
          );
        } catch (_) {}
      }
      function crKindleIsProgrammaticScroll() {
        try { return crKindleNow() < Number(window.__crKindleProbe.programmaticScrollUntil || 0); } catch (_) { return false; }
      }
      function crKindleInstallSelectionBlocker() {
        try {
          if (window.__crKindleSelectionBlockerVersion === 1) return;
          window.__crKindleSelectionBlockerVersion = 1;
          function locked() {
            try {
              return !!(window.__crKindleProbe && window.__crKindleProbe.pageModeLocked) ||
                document.documentElement.classList.contains('cr-kindle-page-mode-locked');
            } catch (_) {
              return false;
            }
          }
          function editable(target) {
            try {
              var el = target && (target.nodeType === 1 ? target : target.parentElement);
              while (el && el !== document.body && el !== document.documentElement) {
                var tag = String(el.tagName || '').toLowerCase();
                if (tag === 'input' || tag === 'textarea' || tag === 'select') return true;
                if (el.isContentEditable) return true;
                el = el.parentElement;
              }
            } catch (_) {}
            return false;
          }
          function clearSelection() {
            try {
              var selection = window.getSelection && window.getSelection();
              if (selection && selection.rangeCount) selection.removeAllRanges();
            } catch (_) {}
          }
          function block(e) {
            if (!locked() || editable(e && e.target)) return;
            try { e.preventDefault(); } catch (_) {}
            try { e.stopImmediatePropagation(); } catch (_) {}
            try { e.stopPropagation(); } catch (_) {}
            clearSelection();
            return false;
          }
          document.addEventListener('contextmenu', block, true);
          document.addEventListener('selectstart', block, true);
          document.addEventListener('selectionchange', function() {
            if (!locked()) return;
            setTimeout(clearSelection, 0);
          }, true);
        } catch (_) {}
      }
      function crKindleHideCastReaderChrome(locked) {
        try {
          var root = document.documentElement;
          var hiddenClass = 'cr-kindle-castreader-hidden-chrome';
          if (!locked) {
            root.classList.remove('cr-kindle-castreader-chrome-hidden');
            Array.from(document.querySelectorAll('.' + hiddenClass)).forEach(function(el) {
              try { el.classList.remove(hiddenClass); } catch (_) {}
            });
            return;
          }
          root.classList.add('cr-kindle-castreader-chrome-hidden');
          function textOf(el) {
            try {
              return [
                el.getAttribute && (el.getAttribute('aria-label') || ''),
                el.getAttribute && (el.getAttribute('title') || ''),
                el.getAttribute && (el.getAttribute('data-testid') || ''),
                el.id || '',
                el.className || '',
                (el.innerText || el.textContent || '')
              ].join(' ').replace(/\\s+/g, ' ').trim();
            } catch (_) {
              return '';
            }
          }
          function visible(el) {
            try {
              var r = el.getBoundingClientRect();
              var s = getComputedStyle(el);
              return s.display !== 'none' && s.visibility !== 'hidden' && r.width > 1 && r.height > 1;
            } catch (_) {
              return false;
            }
          }
          function hasReaderContent(el) {
            try {
              return !!(el && el.querySelector && el.querySelector('#kr-renderer, img[src^="blob:"], .kg-full-page-img, [class*="kindle-reader"], [class*="reader-content"]'));
            } catch (_) {
              return false;
            }
          }
          function chromeTarget(el) {
            var best = el;
            try {
              var label = textOf(el).toLowerCase();
              for (var node = el, depth = 0; node && depth < 7 && node !== document.body && node !== document.documentElement; depth++, node = node.parentElement) {
                if (hasReaderContent(node)) continue;
                var r = node.getBoundingClientRect && node.getBoundingClientRect();
                if (!r || r.width <= 0 || r.height <= 0) continue;
                var nodeLabel = textOf(node).toLowerCase();
                var nearEdge = r.top < 150 || r.bottom > (innerHeight || 0) - 150;
                var toolbarLike = /toolbar|header|footer|scrubber|progress|control|pagination|reader-menu|reader-header|reader-footer/.test(nodeLabel);
                var compactBand = r.height <= Math.min(150, Math.max(80, (innerHeight || 0) * 0.22)) && r.width >= (innerWidth || 0) * 0.35;
                if ((nearEdge && compactBand) || toolbarLike) best = node;
                if (crKindleUISemanticScore(el, 'previous') >= 45 ||
                    crKindleUISemanticScore(el, 'next') >= 45) best = el;
              }
            } catch (_) {}
            return best || el;
          }
          function hide(el) {
            try {
              if (!el) return;
              chromeTarget(el).classList.add(hiddenClass);
            } catch (_) {}
          }
          function hidePageTurnControl(el) {
            try {
              if (!el) return;
              el.setAttribute('data-cr-kindle-page-turn-control', '1');
              var target = chromeTarget(el);
              target.classList.remove(hiddenClass);
              target.style.opacity = '0';
              target.style.pointerEvents = 'none';
              target.style.visibility = 'visible';
            } catch (_) {}
          }
          [
            '#kr-scrubber-bar',
            'ion-range.scrubber-bar'
          ].forEach(function(sel) {
            try { Array.from(document.querySelectorAll(sel)).forEach(hide); } catch (_) {}
          });
          [
            '#kr-chevron-left',
            '#kr-chevron-right',
            'button[aria-label="Previous page"]',
            'button[aria-label="Next page"]',
            'button[title="Previous page"]',
            'button[title="Next page"]'
          ].forEach(function(sel) {
            try { Array.from(document.querySelectorAll(sel)).forEach(hidePageTurnControl); } catch (_) {}
          });
          Array.from(document.querySelectorAll('button,[role="button"],ion-button,ion-range,[aria-label],[title]')).forEach(function(el) {
            if (!visible(el)) return;
            var label = textOf(el).toLowerCase();
            if (crKindleUISemanticScore(el, 'previous') >= 45 ||
                crKindleUISemanticScore(el, 'next') >= 45) {
              hidePageTurnControl(el);
            } else if (/^(kindle library|search|aa|bookmark)$/.test(label)
              || /kindle library|page \\d+|time left|reading progress|bookmark|search/.test(label)) {
              hide(el);
            }
          });
          Array.from(document.querySelectorAll('ion-header,ion-footer,header,footer,[role="toolbar"],[class*="toolbar"],[class*="reader-header"],[class*="reader-footer"],[class*="scrubber"],[class*="progress"]')).forEach(function(el) {
            if (!visible(el) || hasReaderContent(el)) return;
            var r = el.getBoundingClientRect();
            if (r.height <= 170 && (r.top < 170 || r.bottom > (innerHeight || 0) - 170)) hide(el);
          });
        } catch (_) {}
      }
      function crKindleApplyPageModeLockStyles(locked) {
        try {
          var wasLocked = document.documentElement.classList.contains('cr-kindle-page-mode-locked');
          var id = 'cr-kindle-page-mode-lock-style';
          var style = document.getElementById(id);
          if (!style) {
            style = document.createElement('style');
            style.id = id;
            (document.head || document.documentElement).appendChild(style);
          }
          style.textContent = [
            'html.cr-kindle-page-mode-locked, html.cr-kindle-page-mode-locked body, html.cr-kindle-page-mode-locked body * {',
            '  -webkit-touch-callout: none !important;',
            '  -webkit-user-select: none !important;',
            '  user-select: none !important;',
            '}',
            'html.cr-kindle-page-mode-locked ::selection { background: transparent !important; }',
            'html.cr-kindle-page-mode-locked, html.cr-kindle-page-mode-locked body { overscroll-behavior: none !important; }',
            'html.cr-kindle-page-mode-locked img { -webkit-user-drag: none !important; }',
            'html.cr-kindle-page-mode-locked #kr-renderer,',
            'html.cr-kindle-page-mode-locked [id*="kr-content"],',
            'html.cr-kindle-page-mode-locked [class*="kg-scroll-runway"],',
            'html.cr-kindle-page-mode-locked [class*="kg-page"],',
            'html.cr-kindle-page-mode-locked [class*="kindle-reader"],',
            'html.cr-kindle-page-mode-locked [class*="reader-content"] {',
            '  touch-action: none !important;',
            '  overscroll-behavior: none !important;',
            '  -webkit-user-select: none !important;',
            '  user-select: none !important;',
            '}',
            'html.cr-kindle-page-mode-locked .cr-kindle-castreader-hidden-chrome,',
            'html.cr-kindle-page-mode-locked #kr-scrubber-bar,',
            'html.cr-kindle-page-mode-locked ion-range.scrubber-bar {',
            '  display: none !important;',
            '  visibility: hidden !important;',
            '  pointer-events: none !important;',
            '}',
            'html.cr-kindle-page-mode-locked #kr-chevron-left,',
            'html.cr-kindle-page-mode-locked #kr-chevron-right,',
            'html.cr-kindle-page-mode-locked button[aria-label="Previous page"],',
            'html.cr-kindle-page-mode-locked button[aria-label="Next page"],',
            'html.cr-kindle-page-mode-locked button[title="Previous page"],',
            'html.cr-kindle-page-mode-locked button[title="Next page"],',
            'html.cr-kindle-page-mode-locked [data-cr-kindle-page-turn-control="1"] {',
            '  opacity: 0 !important;',
            '  visibility: visible !important;',
            '  pointer-events: none !important;',
            '}'
          ].join('\\n');
          var root = document.documentElement;
          if (locked) root.classList.add('cr-kindle-page-mode-locked');
          else root.classList.remove('cr-kindle-page-mode-locked');
          crKindleInstallSelectionBlocker();
          crKindleHideCastReaderChrome(locked);
          if (locked) {
            setTimeout(function() { crKindleHideCastReaderChrome(true); }, 120);
            setTimeout(function() { crKindleHideCastReaderChrome(true); }, 420);
            setTimeout(function() { crKindleHideCastReaderChrome(true); }, 1000);
            if (!wasLocked) {
              try { window.dispatchEvent(new Event('resize')); } catch (_) {}
            }
          }
        } catch (_) {}
      }
      function crKindleEnsureBottomSafeSpacer() {
        try {
          var spacer = document.getElementById('cr-kindle-bottom-safe-spacer');
          if (spacer && spacer.parentNode) spacer.parentNode.removeChild(spacer);
        } catch (_) {}
      }
      function crKindleShouldAllowManualScrollTarget(target) {
        try {
          var el = target && (target.nodeType === 1 ? target : target.parentElement);
          while (el && el !== document.body && el !== document.documentElement) {
            var role = String(el.getAttribute && (el.getAttribute('role') || '') || '').toLowerCase();
            var ariaModal = String(el.getAttribute && (el.getAttribute('aria-modal') || '') || '').toLowerCase();
            var label = [
              el.id || '',
              el.className || '',
              el.getAttribute && (el.getAttribute('aria-label') || ''),
              el.getAttribute && (el.getAttribute('data-testid') || ''),
              el.getAttribute && (el.getAttribute('title') || '')
            ].join(' ').toLowerCase();
            var explicitTOC = /(\\btoc\\b|table[-_\\s]*of[-_\\s]*contents|kg[-_\\s]*toc|toc[-_]|[-_]toc\\b)/.test(label);
            var overlayRole = /dialog|menu|listbox|tree|grid|tablist/.test(role) || ariaModal === 'true';
            var overlayName = /modal|popover|dropdown|sheet|drawer|side[-_\\s]*panel|side\\.panel|\\bmenu\\b/.test(label);
            if (explicitTOC || overlayRole || overlayName) return true;
            el = el.parentElement;
          }
        } catch (_) {}
        return false;
      }
      function crKindleLooksLikeNavigationTarget(target) {
        try {
          var el = target && (target.nodeType === 1 ? target : target.parentElement);
          for (var depth = 0; el && depth < 8 && el !== document.body && el !== document.documentElement; depth++, el = el.parentElement) {
            var label = [
              el.id || '',
              el.className || '',
              el.getAttribute && (el.getAttribute('role') || ''),
              el.getAttribute && (el.getAttribute('aria-label') || ''),
              el.getAttribute && (el.getAttribute('data-testid') || ''),
              el.getAttribute && (el.getAttribute('title') || ''),
              (el.innerText || '').slice(0, 120)
            ].join(' ').toLowerCase();
            if (crKindleUISemanticScore(el, 'toc') >= 45) return true;
            if (/toc|table.of.contents|contents|chapter|section|location|go to|goto|navigation|nav-|menu|listitem|kg-bookmark|kindle library/.test(label)) return true;
          }
        } catch (_) {}
        return false;
      }
      function crKindleMarkNavigationIntent(reason) {
        try {
          var now = crKindleNow();
          if (now - Number(window.__crKindleProbe.navigationAt || 0) < 220) return;
          window.__crKindleProbe.navigationSeq = Number(window.__crKindleProbe.navigationSeq || 0) + 1;
          window.__crKindleProbe.navigationAt = now;
          window.__crKindleProbe.navigationReason = String(reason || 'navigation');
        } catch (_) {}
      }
      function crKindleNavigationClick(e) {
        try {
          if (!window.__crKindleProbe || !window.__crKindleProbe.pageModeLocked) return;
          if (crKindleLooksLikeNavigationTarget(e && e.target)) {
            crKindleMarkNavigationIntent('kindle-navigation-ui');
          }
        } catch (_) {}
      }
      function crKindlePreventManualScroll(e) {
        try {
          if (window.__crKindleProbe && window.__crKindleProbe.pageModeLocked && !crKindleShouldAllowManualScrollTarget(e.target)) {
            e.preventDefault();
            e.stopPropagation && e.stopPropagation();
            e.stopImmediatePropagation && e.stopImmediatePropagation();
            crKindleScheduleManualScrollRestore('gesture');
            return false;
          }
        } catch (_) {}
      }
      function crKindleScheduleManualScrollRestore(reason) {
        try {
          if (!window.__crKindleProbe || !window.__crKindleProbe.pageModeLocked) return;
          if (crKindleIsProgrammaticScroll()) return;
          var key = String(window.__crKindleProbe.liveKey || '');
          if (!key) return;
          if (window.__crKindleProbe.manualScrollRestoreRaf) return;
          window.__crKindleProbe.manualScrollRestoreRaf = requestAnimationFrame(function() {
            window.__crKindleProbe.manualScrollRestoreRaf = 0;
            try {
              crKindleAllowProgrammaticScroll(700);
              if (window.__crKindleRestoreAnchor) window.__crKindleRestoreAnchor(key);
              crKindleUpdateLiveOverlay();
            } catch (_) {}
          });
        } catch (_) {}
      }
      function crKindleHandleScrollEvent(e) {
        try {
          if (!window.__crKindleProbe || !window.__crKindleProbe.pageModeLocked) return;
          if (crKindleIsProgrammaticScroll()) return;
          if (crKindleShouldAllowManualScrollTarget(e && e.target)) return;
          crKindleScheduleManualScrollRestore('scroll');
        } catch (_) {}
      }
      function crKindleReaderForPageTurn() {
        try {
          return document.querySelector('#kr-renderer')
            || document.querySelector('[id*="kr-content"]')
            || document.querySelector('[class*="kg-scroll-runway"]')
            || document.querySelector('[class*="kindle-reader"]')
            || document.body;
        } catch (_) {
          return document.body;
        }
      }
      function crKindleDispatchPointerTurn(dir) {
        var reader = crKindleReaderForPageTurn();
        if (!reader || !reader.getBoundingClientRect) return false;
        var rect = reader.getBoundingClientRect();
        if (!rect || rect.width <= 0 || rect.height <= 0) return false;
        var x = dir === 'left' ? rect.left + 40 : rect.right - 40;
        var y = rect.top + rect.height * 0.5;
        var target = document.elementFromPoint(x, y) || reader;
        var opts = { clientX:x, clientY:y, screenX:x, screenY:y, pageX:x + window.scrollX, pageY:y + window.scrollY, bubbles:true, cancelable:true };
        try { target.dispatchEvent(new PointerEvent('pointerdown', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
        try { target.dispatchEvent(new PointerEvent('pointerup', Object.assign({ pointerId:1, pointerType:'mouse' }, opts))); } catch (_) {}
        try { target.dispatchEvent(new MouseEvent('click', opts)); } catch (_) {}
        return true;
      }
      function crKindlePageControlVisible(el) {
        if (!el || !el.getBoundingClientRect) return false;
        try {
          var style = getComputedStyle(el);
          var rect = el.getBoundingClientRect();
          return style.display !== 'none' &&
            style.visibility !== 'hidden' &&
            style.pointerEvents !== 'none' &&
            rect.width > 2 &&
            rect.height > 2;
        } catch (_) {
          return false;
        }
      }
      window.__crKindleTurnPage = function(direction) {
        try {
          var raw = String(direction || '').toLowerCase();
          var dir = (raw === 'previous' || raw === 'prev' || raw === 'back' || raw === 'left') ? 'left' : 'right';
          var step = dir === 'left' ? -1 : 1;
          var tried = [];
          var restorePageLock = false;
          function releasePageLockForNativeTurn() {
            try {
              window.__crKindleProbe = window.__crKindleProbe || {};
              restorePageLock = !!window.__crKindleProbe.pageModeLocked ||
                document.documentElement.classList.contains('cr-kindle-page-mode-locked');
              if (!restorePageLock) return;
              window.__crKindleProbe.pageModeLocked = false;
              crKindleApplyPageModeLockStyles(false);
              tried.push('release-page-lock');
            } catch (_) {}
          }
          function schedulePageLockRestore() {
            try {
              if (!restorePageLock) return;
              setTimeout(function() {
                try {
                  window.__crKindleProbe = window.__crKindleProbe || {};
                  window.__crKindleProbe.pageModeLocked = true;
                  crKindleApplyPageModeLockStyles(true);
                } catch (_) {}
              }, 480);
            } catch (_) {}
          }
          function finish(payload) {
            payload = payload || {};
            try {
              payload.lockReleased = !!restorePageLock;
              payload.tried = payload.tried || tried.join('|');
            } catch (_) {}
            schedulePageLockRestore();
            return JSON.stringify(payload);
          }
          crKindleAllowProgrammaticScroll(2400);
          crKindleMarkNavigationIntent('manual-page-' + (dir === 'left' ? 'previous' : 'next'));
          var current = currentReadingCandidate() || bestCandidate();
          var currentKey = String((current && current.key) || window.__crKindleProbe.liveKey || '');
          releasePageLockForNativeTurn();

          var scrubber = null;
          try {
            scrubber = document.querySelector('#kr-scrubber-bar') || document.querySelector('ion-range.scrubber-bar');
            tried.push(scrubber ? 'scrubber-available' : 'no-scrubber');
          } catch (e) {
            tried.push('scrubber-error:' + String(e));
          }

          // Match the extension's proven main-world transport: the Kindle
          // scrubber is the most reliable page action. Dispatch it once, then
          // let Swift poll the real visible page before any fallback is tried.
          try {
            if (scrubber && typeof scrubber.value === 'number') {
              var scrubberOldValue = Number(scrubber.value || 0);
              var scrubberNewValue = scrubberOldValue + step;
              scrubber.value = scrubberNewValue;
              scrubber.dispatchEvent(new CustomEvent('ionInput', { detail: { value:scrubberNewValue }, bubbles:true }));
              scrubber.dispatchEvent(new CustomEvent('ionChange', { detail: { value:scrubberNewValue }, bubbles:true }));
              return finish({
                ok:true,
                direction:dir,
                strategy:'native-scrubber',
                dispatchCount:1,
                tried:tried.concat(['native-scrubber']).join('|'),
                oldKey:currentKey,
                oldValue:scrubberOldValue,
                newValue:scrubberNewValue,
                url:location.href
              });
            }
          } catch (e) {
            tried.push('scrubber-dispatch-error:' + String(e));
          }

          // Kindle often keeps the real chevron mounted but visually hidden.
          // The extension intentionally clicks that control before falling back
          // to an edge tap; Swift still verifies the real visible page changed.
          var chevron = document.querySelector(dir === 'left' ? '#kr-chevron-left' : '#kr-chevron-right')
            || document.querySelector(dir === 'left' ? 'button[aria-label="Previous page"],button[title="Previous page"]' : 'button[aria-label="Next page"],button[title="Next page"]');
          if (!chevron) {
            var semanticControl = crKindleUIFind(
              dir === 'left' ? 'previous' : 'next',
              document,
              'button,[role="button"],ion-button,[data-testid],[data-action],[aria-label],[title]'
            );
            chevron = semanticControl && semanticControl.el;
          }
          var chevronEnabled = !!chevron && !chevron.disabled && String(chevron.getAttribute && chevron.getAttribute('aria-disabled') || '').toLowerCase() !== 'true';
          var chevronVisible = crKindlePageControlVisible(chevron);
          if (chevronEnabled) {
            try { chevron.click(); } catch (_) {
              try { chevron.dispatchEvent(new MouseEvent('click', { bubbles:true, cancelable:true })); } catch (_) {}
            }
            return finish({
              ok:true,
              direction:dir,
              strategy:'native-chevron',
              controlVisible:chevronVisible,
              dispatchCount:1,
              tried:tried.concat(['native-chevron']).join('|'),
              oldKey:currentKey,
              url:location.href
            });
          }
          tried.push(chevron ? 'disabled-chevron' : 'no-chevron');

          if (crKindleDispatchPointerTurn(dir)) {
            return finish({
              ok:true,
              direction:dir,
              strategy:'native-tap-zone',
              tried:tried.concat(['native-tap-zone']).join('|'),
              oldKey:currentKey,
              url:location.href
            });
          }
          tried.push('no-tap-zone');

          try {
            var key = dir === 'left' ? 'ArrowLeft' : 'ArrowRight';
            var code = dir === 'left' ? 37 : 39;
            var ae = document.activeElement;
            if (ae && ae !== document.body && ae !== document.documentElement && ae.blur) ae.blur();
            var opts = { key:key, code:key, keyCode:code, which:code, bubbles:true, cancelable:true };
            var target = document.activeElement || document.body || document;
            target.dispatchEvent(new KeyboardEvent('keydown', opts));
            target.dispatchEvent(new KeyboardEvent('keyup', opts));
            return finish({
              ok:true,
              direction:dir,
              strategy:'native-keyboard',
              tried:tried.concat(['native-keyboard']).join('|'),
              oldKey:currentKey,
              url:location.href
            });
          } catch (_) {
            tried.push('keyboard-failed');
          }

          return finish({
            ok:false,
            direction:dir,
            reason:'no-native-page-control',
            tried:tried.join('|'),
            oldKey:currentKey,
            url:location.href
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), direction:String(direction || ''), url:location.href });
        }
      };
      window.__crKindleTurnNativePage = window.__crKindleTurnPage;
      function crKindlePaginationProps(value) {
        return !!value && typeof value === 'object' &&
          typeof value.leftAction === 'function' && typeof value.rightAction === 'function';
      }
      function crKindleFiberName(fiber) {
        try {
          var t = fiber && (fiber.elementType || fiber.type);
          return typeof t === 'string' ? t : String((t && (t.displayName || t.name)) || 'anonymous');
        } catch (_) { return 'anonymous'; }
      }
      function crKindlePaginationFromFiber(start) {
        var fiber = start, visited = [], depth = 0;
        while (fiber && depth < 64) {
          if (visited.indexOf(fiber) >= 0) return null;
          visited.push(fiber);
          var candidates = [
            { value:fiber.memoizedProps, source:'memoizedProps' },
            { value:fiber.pendingProps, source:'pendingProps' }
          ];
          for (var i = 0; i < candidates.length; i++) {
            if (crKindlePaginationProps(candidates[i].value)) {
              return { props:candidates[i].value, propsSource:candidates[i].source,
                component:crKindleFiberName(fiber), fiberDepth:depth };
            }
          }
          fiber = fiber.return;
          depth += 1;
        }
        return null;
      }
      function crKindleReactFiberForNode(node) {
        if (!node) return null;
        try {
          var keys = Object.keys(node);
          for (var i = 0; i < keys.length; i++) {
            if (keys[i].indexOf('__reactFiber$') === 0 || keys[i].indexOf('__reactInternalInstance$') === 0) {
              return node[keys[i]];
            }
          }
        } catch (_) {}
        return null;
      }
      function crKindleFindPaginationActions() {
        var selectors = [
          '#kr-chevron-left', '#kr-chevron-right',
          '[aria-label="Previous page"]', '[aria-label="Next page"]',
          '[title="Previous page"]', '[title="Next page"]'
        ];
        var nodes = [], seen = [];
        function add(node) {
          if (!node || seen.indexOf(node) >= 0) return;
          seen.push(node); nodes.push(node);
        }
        selectors.forEach(function(selector) {
          Array.from(document.querySelectorAll(selector)).forEach(function(node) {
            add(node); Array.from(node.querySelectorAll('*')).forEach(add);
            add(node.closest && node.closest('button,[role="button"],ion-button'));
            add(node.parentElement); add(node.previousElementSibling); add(node.nextElementSibling);
          });
        });
        ['previous', 'next'].forEach(function(kind) {
          var match = crKindleUIFind(
            kind,
            document,
            'button,[role="button"],ion-button,[data-testid],[data-action],[data-command],[aria-label],[title]'
          );
          if (!match) return;
          var node = match.el;
          add(node);
          Array.from(node.querySelectorAll('*')).forEach(add);
          add(node.closest && node.closest('button,[role="button"],ion-button'));
          add(node.parentElement);
          add(node.previousElementSibling);
          add(node.nextElementSibling);
        });
        for (var i = 0; i < nodes.length; i++) {
          var match = crKindlePaginationFromFiber(crKindleReactFiberForNode(nodes[i]));
          if (match) return match;
        }
        return null;
      }
      window.__crKindleFindPaginationActions = crKindleFindPaginationActions;
      window.__crKindleSemanticPageTurn = function(direction, fallbackProgression) {
        try {
          var match = crKindleFindPaginationActions();
          if (!match) return JSON.stringify({ ok:false, reason:'pagination-component-unavailable', dispatchCount:0 });
          var progression = String(match.props.pageProgressionDirection || '').toLowerCase();
          var progressionSource = 'react-component';
          if (progression !== 'rtl' && progression !== 'ltr') {
            progression = String(fallbackProgression || '').toLowerCase() === 'rtl' ? 'rtl' : 'ltr';
            progressionSource = 'language-fallback';
          }
          var next = String(direction || 'next').toLowerCase() !== 'previous';
          var useLeft = next ? progression === 'rtl' : progression !== 'rtl';
          var action = useLeft ? match.props.leftAction : match.props.rightAction;
          var fingerprint = crKindleVisiblePixelFingerprint(currentReadingCandidate());
          action.call(match.props);
          return JSON.stringify({ ok:true, strategy:'react-paired-action', semanticAction:useLeft ? 'leftAction' : 'rightAction',
            progressionDirection:progression, progressionSource:progressionSource, component:match.component, fiberDepth:match.fiberDepth,
            propsSource:match.propsSource, dispatchCount:1, beforeFingerprint:fingerprint });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:'semantic-action-error:' + String(e && e.message || e), dispatchCount:0 });
        }
      };
      window.__crKindleTurnPage = window.__crKindleSemanticPageTurn;
      window.__crKindleTurnNativePage = window.__crKindleSemanticPageTurn;
      window.__crKindleDirectPage = function(direction, anchorKey) {
        try {
          var raw = String(direction || '').toLowerCase();
          var dir = (raw === 'previous' || raw === 'prev' || raw === 'back' || raw === 'left' || raw === '-1') ? 'left' : 'right';
          var step = dir === 'left' ? -1 : 1;
          var tried = [];
          crKindleAllowProgrammaticScroll(2400);
          crKindleMarkNavigationIntent('manual-direct-page-' + (dir === 'left' ? 'previous' : 'next'));
          var current = currentReadingCandidate() || bestCandidate();
          var beforeKey = String(anchorKey || (current && current.key) || window.__crKindleProbe.liveKey || '');
          function finish(payload) {
            payload = payload || {};
            payload.oldKey = beforeKey;
            payload.tried = tried.join('|');
            payload.url = location.href;
            return JSON.stringify(payload);
          }

          var scrubber = document.querySelector('#kr-scrubber-bar') || document.querySelector('ion-range.scrubber-bar');
          if (crKindlePageControlVisible(scrubber) && typeof scrubber.value !== 'undefined') {
            var oldValue = Number(scrubber.value || 0);
            var newValue = oldValue + step;
            scrubber.value = newValue;
            try { scrubber.dispatchEvent(new CustomEvent('ionInput', { detail: { value:newValue }, bubbles:true })); } catch (_) {}
            try { scrubber.dispatchEvent(new CustomEvent('ionChange', { detail: { value:newValue }, bubbles:true })); } catch (_) {}
            tried.push('scrubber:' + newValue);
            return finish({
              ok:true,
              direction:dir,
              strategy:'direct-scrubber',
              oldValue:oldValue,
              newValue:newValue
            });
          }
          tried.push(scrubber ? 'hidden-scrubber' : 'no-scrubber');

          // The primary transport already tried Kindle's chevron. The next
          // extension-aligned fallback is one edge tap, not another keyboard.
          if (crKindleDispatchPointerTurn(dir)) {
            tried.push('tap-zone');
            return finish({ ok:true, direction:dir, strategy:'direct-tap-zone', dispatchCount:1 });
          }
          tried.push('no-tap-zone');

          try {
            var target = null;
            if (step > 0) {
              target = nextCandidateAfterKey(beforeKey);
            } else {
              var list = orderedCandidates();
              var index = -1;
              for (var i = 0; i < list.length; i++) {
                if (String((list[i] && list[i].key) || '') === beforeKey) { index = i; break; }
              }
              if (index > 0) target = list[index - 1];
            }
            if (target && target.key && target.key !== beforeKey && target.el) {
              var align = scrollCandidateIntoView(target, 'start');
              tried.push('candidate-align:' + String(target.key || '').slice(0, 24));
              if (align && (align.ok || align.moved || align.animated || align.fallback)) {
                return finish({
                  ok:true,
                  direction:dir,
                  strategy:step > 0 ? 'direct-candidate-next' : 'direct-candidate-previous',
                  targetKey:String(target.key || ''),
                  align:align
                });
              }
            } else {
              tried.push('candidate-none');
            }
          } catch (e) {
            tried.push('candidate-error:' + String(e && e.message || e));
          }

          try {
            var key = dir === 'left' ? 'ArrowLeft' : 'ArrowRight';
            var code = dir === 'left' ? 37 : 39;
            var opts = { key:key, code:key, keyCode:code, which:code, bubbles:true, cancelable:true };
            var targetNode = document.activeElement || document.body || document;
            targetNode.dispatchEvent(new KeyboardEvent('keydown', opts));
            targetNode.dispatchEvent(new KeyboardEvent('keyup', opts));
            tried.push('keyboard');
            return finish({ ok:true, direction:dir, strategy:'direct-keyboard' });
          } catch (e) {
            tried.push('keyboard-error:' + String(e && e.message || e));
          }

          return finish({ ok:false, direction:dir, reason:'direct-page-control-unavailable' });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e && e.message || e), direction:String(direction || ''), anchorKey:String(anchorKey || ''), url:location.href });
        }
      };
      window.__crKindleForceAdjacentPage = function(direction, anchorKey) {
        try {
          var raw = String(direction || '').toLowerCase();
          var dir = (raw === 'previous' || raw === 'prev' || raw === 'back' || raw === 'left' || raw === '-1') ? 'left' : 'right';
          var step = dir === 'left' ? -1 : 1;
          var current = currentReadingCandidate() || bestCandidate();
          var beforeKey = String(anchorKey || (current && current.key) || window.__crKindleProbe.liveKey || '');
          var target = null;
          if (step > 0) {
            target = nextCandidateAfterKey(beforeKey);
          } else {
            var list = orderedCandidates();
            var index = -1;
            for (var i = 0; i < list.length; i++) {
              if (String((list[i] && list[i].key) || '') === beforeKey) { index = i; break; }
            }
            if (index > 0) target = list[index - 1];
          }
          if (!target || !target.key || String(target.key || '') === beforeKey || !target.el) {
            return JSON.stringify({
              ok:false,
              direction:dir,
              strategy:'force-adjacent-blob',
              reason:'adjacent-candidate-not-found',
              oldKey:beforeKey,
              candidateKey:target && target.key ? String(target.key || '') : '',
              orderedCount:(orderedCandidates() || []).length,
              url:location.href
            });
          }
          crKindleAllowProgrammaticScroll(2400);
          crKindleMarkNavigationIntent('manual-force-adjacent-' + (dir === 'left' ? 'previous' : 'next'));
          var align = scrollCandidateIntoView(target, 'start');
          var moved = !!(align && (align.ok || align.moved || align.animated || align.fallback));
          return JSON.stringify({
            ok:moved,
            direction:dir,
            strategy:'force-adjacent-blob',
            oldKey:beforeKey,
            targetKey:String(target.key || ''),
            align:align || null,
            reason:moved ? '' : 'adjacent-align-failed',
            url:location.href
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e && e.message || e), direction:String(direction || ''), anchorKey:String(anchorKey || ''), url:location.href });
        }
      };
      // Compatibility names must never revive the retired scrubber/tap/
      // keyboard/candidate fallbacks. Every page-turn entry point converges on
      // one paired React semantic action.
      function crKindleCompatibilitySemanticTurn(direction) {
        var raw = String(direction || '').toLowerCase();
        var semanticDirection = (raw === 'previous' || raw === 'prev' || raw === 'back' || raw === 'left' || raw === '-1')
          ? 'previous'
          : 'next';
        return window.__crKindleSemanticPageTurn(semanticDirection);
      }
      window.__crKindleTurnPage = crKindleCompatibilitySemanticTurn;
      window.__crKindleTurnNativePage = crKindleCompatibilitySemanticTurn;
      window.__crKindleDirectPage = crKindleCompatibilitySemanticTurn;
      window.__crKindleForceAdjacentPage = crKindleCompatibilitySemanticTurn;
      if (window.__crKindlePageModeLockInstalledVersion !== crKindleInstallVersion) {
        window.__crKindlePageModeLockInstalledVersion = crKindleInstallVersion;
        window.__crKindlePageModeLockInstalled = true;
          try { document.addEventListener('touchmove', crKindlePreventManualScroll, { capture:true, passive:false }); } catch (_) {}
          try { document.addEventListener('pointermove', crKindlePreventManualScroll, { capture:true, passive:false }); } catch (_) {}
          try { document.addEventListener('wheel', crKindlePreventManualScroll, { capture:true, passive:false }); } catch (_) {}
          try { document.addEventListener('gesturestart', crKindlePreventManualScroll, { capture:true, passive:false }); } catch (_) {}
          try { document.addEventListener('scroll', crKindleHandleScrollEvent, true); } catch (_) {}
        try { document.addEventListener('click', crKindleNavigationClick, true); } catch (_) {}
        try { window.addEventListener('scroll', crKindleHandleScrollEvent, true); } catch (_) {}
      }
      window.__crKindleSetPageModeLocked = function(locked) {
        window.__crKindleProbe.pageModeLocked = !!locked;
        crKindleApplyPageModeLockStyles(!!locked);
        return JSON.stringify({ ok:true, locked:window.__crKindleProbe.pageModeLocked });
      };
      var originalCreate = null;
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
      function crKindleRememberHeldKey(contentKey) {
        try {
          if (!contentKey) return;
          var stable = 'content-' + String(contentKey || '');
          var order = window.__crKindleProbe.heldPageKeys || [];
          window.__crKindleProbe.heldPageKeys = order;
          if (order.indexOf(stable) < 0) order.push(stable);
          if (order.length > 400) window.__crKindleProbe.heldPageKeys = order.slice(order.length - 400);
        } catch (_) {}
      }
      function ensureReaderPatchStyle() {
        return null;
      }
      function ensureBottomSafeSpacer() {
        try {
          var spacer = document.getElementById('cr-kindle-bottom-safe-spacer');
          if (spacer && spacer.parentNode) spacer.parentNode.removeChild(spacer);
        } catch (_) {}
      }
      function setImportant(el, name, value) {
        try { if (el && el.style) el.style.setProperty(name, value, 'important'); } catch (_) {}
      }
      function isKindleUiTarget(target) {
        try {
          var node = target;
          for (var depth = 0; node && depth < 12; depth++, node = node.parentElement) {
            if (!node || node === document.documentElement || node === document.body) break;
            var tag = String(node.tagName || '').toLowerCase();
            var role = String(node.getAttribute && (node.getAttribute('role') || '') || '').toLowerCase();
            var id = String(node.id || '').toLowerCase();
            var cls = String(node.className || '').toLowerCase();
            var label = String(node.getAttribute && (node.getAttribute('aria-label') || '') || '').toLowerCase();
            var text = [role, id, cls, label].join(' ');
            if (/button|a|input|select|textarea/.test(tag)) return true;
            if (/button|menu|menuitem|dialog|listbox|option|search|slider|tab|toolbar|navigation/.test(role)) return true;
            if (/toc|table-of-contents|tableofcontents|contents|目录|chapter-list|chapterlist|navigation-list|popover|modal|dialog|drawer|sheet|panel|side-panel|sidepanel|menu|toolbar|header|footer|search|scrubber|range|slider|chevron|bookmark|annotation|notebook|font|settings|kindle-library|library|ion-popover|ion-modal|ion-content|ion-list|ion-item/.test(text)) return true;
          }
        } catch (_) {}
        return false;
      }
      function isKindleReaderTarget(target) {
        try {
          var node = target;
          for (var depth = 0; node && depth < 10; depth++, node = node.parentElement) {
            var tag = String(node.tagName || '').toLowerCase();
            if (tag === 'img' && String(node.src || '').indexOf('blob:') === 0) return true;
            var id = String(node.id || '').toLowerCase();
            var cls = String(node.className || '').toLowerCase();
            if (/kr-renderer|renderer-container|kg-full-page-img|kindleReader_content|kindle-reader-content/.test(id + ' ' + cls)) return true;
            if (/kr-interaction-layer-fullpage|kg-view/.test(id + ' ' + cls)) return true;
          }
        } catch (_) {}
        return false;
      }
      function shouldBlockReaderScrollEvent(e) {
        try {
          var target = e && e.target ? e.target : document.elementFromPoint(
            (e && e.touches && e.touches[0] ? e.touches[0].clientX : innerWidth * 0.5),
            (e && e.touches && e.touches[0] ? e.touches[0].clientY : innerHeight * 0.5)
          );
          if (!target || isKindleUiTarget(target)) return false;
          if (isKindleReaderTarget(target)) return true;
          var c = currentReadingCandidate && currentReadingCandidate();
          if (!c || !c.rect) return false;
          var point = e && e.touches && e.touches[0] ? e.touches[0] : e;
          var x = Number(point && point.clientX || innerWidth * 0.5);
          var y = Number(point && point.clientY || innerHeight * 0.5);
          return x >= c.rect.left && x <= c.rect.right && y >= c.rect.top && y <= c.rect.bottom;
        } catch (_) {
          return false;
        }
      }
      function crKindleInstallUserPageGestureObserver() {
        if (window.__crKindleUserPageGestureObserverInstalled) return;
        window.__crKindleUserPageGestureObserverInstalled = true;
        var start = null;
        function begin(e) {
          try {
            var touch = e && e.touches && e.touches.length === 1 ? e.touches[0] : null;
            if (!touch || !window.__crKindleProbe || !window.__crKindleProbe.pageModeLocked) {
              start = null;
              return;
            }
            var target = e.target || document.elementFromPoint(touch.clientX, touch.clientY);
            if (!isKindleReaderTarget(target) && !shouldBlockReaderScrollEvent(e)) {
              start = null;
              return;
            }
            start = { x:Number(touch.clientX || 0), y:Number(touch.clientY || 0), at:crKindleNow() };
          } catch (_) { start = null; }
        }
        function finish(e) {
          try {
            var first = start;
            start = null;
            var touch = e && e.changedTouches && e.changedTouches.length === 1 ? e.changedTouches[0] : null;
            if (!first || !touch) return;
            var dx = Number(touch.clientX || 0) - first.x;
            var dy = Number(touch.clientY || 0) - first.y;
            var elapsed = crKindleNow() - first.at;
            if (elapsed > 1400 || Math.abs(dx) < 44 || Math.abs(dx) < Math.abs(dy) * 1.25) return;
            crKindlePostNative('kindle-user-page-gesture', {
              direction:dx < 0 ? 'left' : 'right',
              dx:Math.round(dx),
              dy:Math.round(dy),
              elapsed:elapsed
            });
          } catch (_) { start = null; }
        }
        try { document.addEventListener('touchstart', begin, { capture:true, passive:true }); } catch (_) {}
        try { document.addEventListener('touchend', finish, { capture:true, passive:true }); } catch (_) {}
        try { document.addEventListener('touchcancel', function() { start = null; }, { capture:true, passive:true }); } catch (_) {}
      }
      crKindleInstallUserPageGestureObserver();
      function documentScrollNodes() {
        var out = [];
        [document.scrollingElement, document.documentElement, document.body].forEach(function(el) {
          if (el && out.indexOf(el) < 0) out.push(el);
        });
        return out;
      }
      function captureDocumentScroll() {
        return documentScrollNodes().map(function(el) {
          return { el:el, top:Number(el.scrollTop || 0), left:Number(el.scrollLeft || 0) };
        });
      }
      function restoreDocumentScroll(saved) {
        try {
          (saved || []).forEach(function(item) {
            if (!item || !item.el) return;
            item.el.scrollTop = item.top;
            item.el.scrollLeft = item.left;
          });
          if (saved && saved[0]) {
            try { window.scrollTo(Number(saved[0].left || 0), Number(saved[0].top || 0)); } catch (_) {}
          }
        } catch (_) {}
      }
      function installReaderScrollGuard() {
        if (window.__crKindleReaderScrollGuardInstalled) return;
        window.__crKindleReaderScrollGuardInstalled = true;
        var readerTouchActive = false;
        var lockedScroll = null;
        var begin = function(e) {
          readerTouchActive = shouldBlockReaderScrollEvent(e);
          lockedScroll = readerTouchActive ? captureDocumentScroll() : null;
        };
        var end = function() {
          readerTouchActive = false;
          lockedScroll = null;
        };
        var guard = function(e) {
          var shouldBlock = readerTouchActive || shouldBlockReaderScrollEvent(e);
          if (shouldBlock) {
            try { e.preventDefault(); } catch (_) {}
            try { e.stopPropagation(); } catch (_) {}
            try { e.stopImmediatePropagation(); } catch (_) {}
            restoreDocumentScroll(lockedScroll || captureDocumentScroll());
          }
        };
        try { document.addEventListener('touchstart', begin, { capture:true, passive:true }); } catch (_) {}
        try { document.addEventListener('touchmove', guard, { capture:true, passive:false }); } catch (_) {}
        try { document.addEventListener('touchend', end, { capture:true, passive:true }); } catch (_) {}
        try { document.addEventListener('touchcancel', end, { capture:true, passive:true }); } catch (_) {}
        try { document.addEventListener('wheel', guard, { capture:true, passive:false }); } catch (_) {}
      }
      function patchReaderVisibility() {
        var rendererCount = 0;
        var imageCount = 0;
        try {
          ensureBottomSafeSpacer();
          Array.from(document.querySelectorAll('.kg-full-page-img, .kg-full-page-img img, img[src^="blob:"]')).forEach(function(el) {
            imageCount++;
          });
        } catch (_) {}
        return { rendererCount: rendererCount, imageCount: imageCount };
      }
      window.__crKindlePatchReaderVisibility = function() {
        try {
          var result = patchReaderVisibility();
          return JSON.stringify({ ok:true, rendererCount:result.rendererCount, imageCount:result.imageCount, url:location.href });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), url:location.href });
        }
      };
      try { ensureBottomSafeSpacer(); } catch (e) {}
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
      if (!URL.__crKindleOriginalCreateObjectURL) {
        URL.__crKindleOriginalCreateObjectURL = URL.createObjectURL.bind(URL);
      }
      originalCreate = URL.__crKindleOriginalCreateObjectURL;
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
              crKindleRememberHeldKey(key);
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
      function crKindleRememberCandidateOrder(list) {
        try {
          var order = window.__crKindleProbe.observedPageKeys || [];
          window.__crKindleProbe.observedPageKeys = order;
          list = (list || []).filter(function(c) { return c && c.key; });
          for (var i = 0; i < list.length; i++) {
            var key = String(list[i].key || '');
            if (!key || order.indexOf(key) >= 0) continue;
            var insertAt = -1;
            for (var p = i - 1; p >= 0; p--) {
              var prevIdx = order.indexOf(String((list[p] && list[p].key) || ''));
              if (prevIdx >= 0) { insertAt = prevIdx + 1; break; }
            }
            if (insertAt < 0) {
              for (var n = i + 1; n < list.length; n++) {
                var nextIdx = order.indexOf(String((list[n] && list[n].key) || ''));
                if (nextIdx >= 0) { insertAt = nextIdx; break; }
              }
            }
            if (insertAt < 0 || insertAt > order.length) insertAt = order.length;
            order.splice(insertAt, 0, key);
          }
          if (order.length > 400) {
            window.__crKindleProbe.observedPageKeys = order.slice(order.length - 400);
            order = window.__crKindleProbe.observedPageKeys;
          }
          list.forEach(function(c) {
            try {
              if (!c || !c.el || !c.key) return;
              var idx = order.indexOf(String(c.key || ''));
              if (idx >= 0) {
                c.el.setAttribute('data-cr-kindle-observed-index', String(idx));
                c.el.setAttribute('data-cr-kindle-key', String(c.key || ''));
              }
            } catch (_) {}
          });
        } catch (_) {}
      }
      function crKindleObservedIndex(key) {
        try {
          var order = window.__crKindleProbe.observedPageKeys || [];
          return order.indexOf(String(key || ''));
        } catch (_) {
          return -1;
        }
      }
      function crKindleContentKeyFromStableKey(key) {
        key = String(key || '');
        if (key.indexOf('content-') === 0) return key.substring('content-'.length);
        return '';
      }
      function crKindleTinyImageFingerprint(img) {
        if (!img || !img.complete || !(img.naturalWidth > 0)) return '';
        try {
          if (img.__crKindleTinyFingerprint) return img.__crKindleTinyFingerprint;
          var canvas = document.createElement('canvas');
          canvas.width = 18;
          canvas.height = 28;
          var ctx = canvas.getContext('2d');
          ctx.drawImage(img, 0, 0, canvas.width, canvas.height);
          var fp = canvas.toDataURL('image/png');
          img.__crKindleTinyFingerprint = fp;
          return fp;
        } catch (_) {
          return '';
        }
      }
      function crKindleVisiblePixelFingerprint(candidate) {
        candidate = refreshCandidate(candidate || currentReadingCandidate());
        var img = candidate && candidate.img;
        if (!img || !img.complete || !(img.naturalWidth > 0)) return '';
        try {
          var size = 48;
          var canvas = document.createElement('canvas');
          canvas.width = size; canvas.height = size;
          var ctx = canvas.getContext('2d', { willReadFrequently:true });
          if (!ctx) return '';
          ctx.drawImage(img, 0, 0, size, size);
          var data = ctx.getImageData(0, 0, size, size).data;
          var hashA = 0x811c9dc5, hashB = 0x9e3779b9;
          for (var i = 0; i < data.length; i += 4) {
            var lum = ((data[i] * 77 + data[i + 1] * 150 + data[i + 2] * 29) >>> 8) ^ data[i + 3];
            hashA = Math.imul(hashA ^ lum, 0x01000193) >>> 0;
            hashB = Math.imul(hashB ^ (lum + (i >>> 2)), 0x85ebca6b) >>> 0;
          }
          return 'px:' + Number(candidate.nw || img.naturalWidth || 0) + 'x' + Number(candidate.nh || img.naturalHeight || 0) + ':' + hashA.toString(16) + ':' + hashB.toString(16);
        } catch (_) { return ''; }
      }
      function crKindleHeldKeyByImageFingerprint(key) {
        key = String(key || '');
        if (!key) return '';
        var target = null;
        try {
          var live = window.__crKindleProbe.liveCandidate;
          if (live && String(live.key || '') === key) target = live;
        } catch (_) {}
        if (!target) {
          try {
            var list = candidates();
            for (var i = 0; i < list.length; i++) {
              if (String((list[i] && list[i].key) || '') === key) { target = list[i]; break; }
            }
          } catch (_) {}
        }
        var targetFp = crKindleTinyImageFingerprint(target && target.img);
        if (!targetFp) return '';
        try {
          var order = window.__crKindleProbe.heldPageKeys || [];
          for (var j = 0; j < order.length; j++) {
            var held = crKindleHeldCandidateForStableKey(order[j]);
            if (!held || !held.img) continue;
            if (crKindleTinyImageFingerprint(held.img) === targetFp) return order[j];
          }
        } catch (_) {}
        return '';
      }
      function crKindleHeldKeyForStableKey(key) {
        key = String(key || '');
        if (!key) return '';
        var content = crKindleContentKeyFromStableKey(key);
        if (content) return 'content-' + content;
        try {
          var live = window.__crKindleProbe.liveCandidate;
          if (live && String(live.key || '') === key && live.contentKey) {
            return 'content-' + live.contentKey;
          }
        } catch (_) {}
        try {
          var list = candidates();
          for (var i = 0; i < list.length; i++) {
            var c = list[i];
            if (c && String(c.key || '') === key && c.contentKey) {
              return 'content-' + c.contentKey;
            }
          }
        } catch (_) {}
        return crKindleHeldKeyByImageFingerprint(key) || key;
      }
      function crKindleHeldIndex(key) {
        try {
          var order = window.__crKindleProbe.heldPageKeys || [];
          return order.indexOf(crKindleHeldKeyForStableKey(key));
        } catch (_) {
          return -1;
        }
      }
      function crKindleFallbackPageRect() {
        var ref = null;
        try { ref = currentReadingCandidate() || bestCandidate(); } catch (_) {}
        if (ref && ref.rect && ref.rect.width > 40 && ref.rect.height > 40) return ref.rect;
        var w = Math.max(1, Number(innerWidth || document.documentElement.clientWidth || 1));
        var h = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
        return { left:0, top:0, right:w, bottom:h, width:w, height:h };
      }
      function crKindleHeldCandidateForStableKey(stableKey) {
        stableKey = String(stableKey || '');
        var content = crKindleContentKeyFromStableKey(stableKey);
        if (!content) return null;
        var live = window.__crKindleProbe.keyToLiveUrl.get(content) || '';
        if (!live) return null;
        var img = liveImageFor(content, live);
        if (!img) return null;
        return {
          kind:'held-live',
          el:null,
          img:img,
          src:live,
          key:stableKey,
          contentKey:content,
          rect:crKindleFallbackPageRect(),
          visible:0,
          bandVisible:0,
          nw:img.naturalWidth || img.width || 0,
          nh:img.naturalHeight || img.height || 0
        };
      }
      function crKindleHeldCandidateAfterKey(key) {
        key = String(key || '');
        var order = window.__crKindleProbe.heldPageKeys || [];
        if (!order.length) {
          try {
            window.__crKindleProbe.keyToLiveUrl.forEach(function(_, content) {
              crKindleRememberHeldKey(content);
            });
            order = window.__crKindleProbe.heldPageKeys || [];
          } catch (_) {}
        }
        var heldKey = crKindleHeldKeyForStableKey(key);
        var idx = order.indexOf(heldKey);
        if (idx >= 0 && idx + 1 < order.length) return crKindleHeldCandidateForStableKey(order[idx + 1]);
        return null;
      }
      function crKindleFirstVisibleAfterObservedKey(key, list) {
        var anchorIdx = crKindleObservedIndex(key);
        if (anchorIdx < 0) return null;
        var targetIdx = anchorIdx + 1;
        list = list || orderedCandidates();
        for (var i = 0; i < list.length; i++) {
          var idx = crKindleObservedIndex(list[i] && list[i].key);
          if (idx === targetIdx) return list[i];
        }
        return null;
      }
      function orderedCandidates() {
        var list = candidates()
          .filter(function(c) { return c && c.key && c.rect && c.rect.height > 40 && c.rect.width > 40; })
          .sort(function(a, b) {
            var dy = candidateOrderY(a) - candidateOrderY(b);
            if (Math.abs(dy) > 2) return dy;
            return Number((a.rect && a.rect.left) || 0) - Number((b.rect && b.rect.left) || 0);
          });
        crKindleRememberCandidateOrder(list);
        return list;
      }
      function nextCandidateAfterKey(key) {
        key = String(key || '');
        var list = orderedCandidates();
        if (!list.length) return crKindleHeldCandidateAfterKey(key);
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
        return crKindleFirstVisibleAfterObservedKey(key, list) || crKindleHeldCandidateAfterKey(key);
      }
      function scrollCandidateIntoView(candidate, block) {
        if (!candidate || !candidate.el || !candidate.rect) return { ok:false, reason:'missing-candidate' };
        block = block || 'nearest';
        var viewportH = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
        var targetTop = block === 'start' ? 8 : Math.max(18, viewportH * 0.10);
        var result = crKindleDirectAlignCandidate(candidate, targetTop, block === 'start' ? 'candidate-playback-align' : 'candidate-delta-align');
        if (!result || !result.ok) {
          try {
            crKindleAllowProgrammaticScroll(1200);
            candidate.el.scrollIntoView({ block:block === 'start' ? 'start' : block, inline:'nearest', behavior:'auto' });
            result = result || {};
            result.fallback = 'element-scroll-into-view-auto';
            result.moved = true;
            result.animated = false;
          } catch (e) {
            result = result || {};
            result.fallbackError = String(e);
          }
        }
        return result || { ok:false, reason:'scroll-failed' };
      }
      function crKindleScrollNode(el, delta) {
        delta = Number(delta || 0);
        if (!el || !isFinite(delta) || Math.abs(delta) < 1) {
          return { moved:false, before:0, after:0, delta:0, animated:false };
        }
        var isRoot = el === document.scrollingElement || el === document.documentElement || el === document.body;
        function readTop() {
          if (isRoot) {
            return Number(window.pageYOffset || document.documentElement.scrollTop || document.body.scrollTop || el.scrollTop || 0);
          }
          return Number(el.scrollTop || 0);
        }
        function writeTop(value) {
          value = Number(value || 0);
          if (isRoot) {
            var scrolling = document.scrollingElement || document.documentElement || document.body;
            try { if (scrolling) scrolling.scrollTop = value; } catch (_) {}
            try { if (document.documentElement) document.documentElement.scrollTop = value; } catch (_) {}
            try { if (document.body) document.body.scrollTop = value; } catch (_) {}
            try { window.scrollTo(0, value); } catch (_) {}
          } else {
            el.scrollTop = value;
          }
        }
        function maxTopForNode() {
          if (isRoot) {
            var doc = document.documentElement || el;
            var body = document.body || el;
            return Math.max(0, Math.max(Number(doc.scrollHeight || 0), Number(body.scrollHeight || 0)) - Math.max(1, Number(innerHeight || doc.clientHeight || 1)));
          }
          return Math.max(0, Number(el.scrollHeight || 0) - Number(el.clientHeight || 0));
        }
        var before = readTop();
        var maxTop = maxTopForNode();
        var target = Math.max(0, Math.min(maxTop, before + delta));
        var actual = target - before;
        if (Math.abs(actual) < 1) {
          return { moved:false, before:Math.round(before), after:Math.round(before), delta:0, animated:false };
        }
        crKindleAllowProgrammaticScroll(1400);
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
            writeTop(start + actual * ease(p));
            crKindleUpdateLiveOverlay();
            if (p < 1) {
              el[slot].raf = requestAnimationFrame(tick);
            } else {
              writeTop(target);
              crKindleUpdateLiveOverlay();
              el[slot] = null;
            }
          } catch (e) {
            try { writeTop(target); } catch (_) {}
            try { crKindleUpdateLiveOverlay(); } catch (_) {}
            try { el[slot] = null; } catch (_) {}
          }
        }
        try {
          el[slot] = { raf: requestAnimationFrame(tick), target: target };
          return { moved:true, before:Math.round(before), after:Math.round(target), delta:Math.round(actual), animated:true };
        } catch (e) {
          try { writeTop(target); } catch (_) {}
          return { moved:true, before:Math.round(before), after:Math.round(target), delta:Math.round(actual), animated:false };
        }
      }
      function crKindleScrollableNodesFor(candidate) {
        var all = [];
        var node = candidate && candidate.el ? candidate.el : null;
        for (var depth = 0; node && depth < 12; depth++, node = node.parentElement) {
          try {
            var st = getComputedStyle(node);
            var canY = /(auto|scroll|overlay)/.test(st.overflowY || '') || (node.scrollHeight || 0) > (node.clientHeight || 0) + 4;
            if (canY && (node.scrollHeight || 0) > (node.clientHeight || 0) + 4 && all.indexOf(node) < 0) all.push(node);
          } catch (e) {}
        }
        [document.scrollingElement, document.body, document.documentElement].forEach(function(el) {
          if (el && all.indexOf(el) < 0) all.push(el);
        });
        return all;
      }
      function crKindleIsDocumentScroller(el) {
        return el === document.scrollingElement || el === document.documentElement || el === document.body;
      }
      function crKindleScrollTopOf(el) {
        if (!el) return 0;
        if (crKindleIsDocumentScroller(el)) {
          return Number(window.pageYOffset || document.documentElement.scrollTop || document.body.scrollTop || el.scrollTop || 0);
        }
        return Number(el.scrollTop || 0);
      }
      function crKindleMaxScrollTopOf(el) {
        if (!el) return 0;
        if (crKindleIsDocumentScroller(el)) {
          var doc = document.documentElement || el;
          var body = document.body || el;
          return Math.max(0, Math.max(Number(doc.scrollHeight || 0), Number(body.scrollHeight || 0)) - Math.max(1, Number(innerHeight || doc.clientHeight || 1)));
        }
        return Math.max(0, Number(el.scrollHeight || 0) - Math.max(1, Number(el.clientHeight || 1)));
      }
      function crKindleSetScrollTopImmediate(el, value) {
        if (!el) return { moved:false, before:0, after:0, target:0, max:0 };
        var before = crKindleScrollTopOf(el);
        var max = crKindleMaxScrollTopOf(el);
        var target = Math.max(0, Math.min(max, Number(value || 0)));
        crKindleAllowProgrammaticScroll(1200);
        try {
          if (crKindleIsDocumentScroller(el)) {
            var scrolling = document.scrollingElement || document.documentElement || document.body;
            if (scrolling) scrolling.scrollTop = target;
            if (document.documentElement) document.documentElement.scrollTop = target;
            if (document.body) document.body.scrollTop = target;
            try { window.scrollTo(0, target); } catch (e) {}
          } else {
            el.scrollTop = target;
          }
        } catch (e) {}
        try { crKindleUpdateLiveOverlay(); } catch (e) {}
        var after = crKindleScrollTopOf(el);
        return { moved:Math.abs(after - before) >= 1, before:before, after:after, target:target, max:max };
      }
      function crKindleSetScrollTopAnimated(el, value) {
        if (!el) return { moved:false, before:0, after:0, target:0, max:0, animated:false };
        var before = crKindleScrollTopOf(el);
        var max = crKindleMaxScrollTopOf(el);
        var target = Math.max(0, Math.min(max, Number(value || 0)));
        var result = crKindleScrollNode(el, target - before);
        result.target = target;
        result.max = max;
        result.after = target;
        return result;
      }
      function crKindleScrollContainerForCandidate(candidate) {
        var node = candidate && candidate.el ? candidate.el : null;
        for (var depth = 0; node && depth < 16; depth++, node = node.parentElement) {
          try {
            var st = getComputedStyle(node);
            var scrollable = /(auto|scroll|overlay)/.test(st.overflowY || '') || (node.scrollHeight || 0) > (node.clientHeight || 0) + 4;
            if (scrollable && crKindleMaxScrollTopOf(node) > 0) return node;
          } catch (e) {}
        }
        return document.scrollingElement || document.documentElement || document.body;
      }
      function crKindleDirectAlignCandidate(candidate, topInset, mode) {
        if (!candidate || !candidate.el || !candidate.rect) return { ok:false, reason:'missing-candidate' };
        var scroller = crKindleScrollContainerForCandidate(candidate);
        var scrollerTop = crKindleIsDocumentScroller(scroller) ? 0 : Number((absRect(scroller) || {}).top || 0);
        var before = crKindleScrollTopOf(scroller);
        var targetTop = Math.max(0, Number(topInset || 0));
        var target = before + Number(candidate.rect.top || 0) - scrollerTop - targetTop;
        var result = crKindleSetScrollTopAnimated(scroller, target);
        var pending = !!(result && result.moved && result.animated);
        var refreshed = pending ? candidate : crKindleCandidateForKey(candidate.key || '');
        var refreshedTop = refreshed && refreshed.rect ? Number(refreshed.rect.top || 0) : NaN;
        var aligned = isFinite(refreshedTop) && Math.abs(refreshedTop - targetTop) <= 10;
        return {
          ok: pending || aligned,
          pending: pending,
          moved: result.moved,
          animated: !!result.animated,
          mode: mode || 'direct-candidate-align',
          key: candidate.key || '',
          before: Math.round(result.before),
          after: Math.round(result.after),
          targetScrollTop: Math.round(result.target),
          maxScrollTop: Math.round(result.max),
          beforeTop: Math.round(Number(candidate.rect.top || 0)),
          afterTop: isFinite(refreshedTop) ? Math.round(refreshedTop) : null,
          targetTop: Math.round(targetTop),
          scrollerTag: scroller && scroller.tagName ? scroller.tagName : 'DOCUMENT'
        };
      }
      function crKindleRememberPlaybackAnchorForKey(key, topInset) {
        key = String(key || '');
        if (!key) return { ok:false, reason:'missing-key' };
        var candidate = crKindleCandidateForKey(key);
        if (!candidate || !candidate.el || !candidate.rect) return { ok:false, reason:'key-not-visible', key:key };
        var scroller = crKindleScrollContainerForCandidate(candidate);
        var scrollerTop = crKindleIsDocumentScroller(scroller) ? 0 : Number((absRect(scroller) || {}).top || 0);
        var targetTop = Math.max(0, Number(topInset || 0));
        var target = crKindleScrollTopOf(scroller) + Number(candidate.rect.top || 0) - scrollerTop - targetTop;
        try {
          window.__crKindleProbe.playbackAnchors.set(key, {
            node: scroller,
            scrollTop: Math.max(0, Math.min(crKindleMaxScrollTopOf(scroller), target)),
            targetTop: targetTop,
            storedAt: Date.now(),
            tag: scroller && scroller.tagName ? scroller.tagName : 'DOCUMENT'
          });
        } catch (e) {}
        return { ok:true, key:key, scrollTop:Math.round(target), targetTop:Math.round(targetTop) };
      }
      function crKindleRestorePlaybackAnchorForKey(key) {
        key = String(key || '');
        var anchor = null;
        try { anchor = window.__crKindleProbe.playbackAnchors && window.__crKindleProbe.playbackAnchors.get(key); } catch (e) {}
        if (!anchor || !anchor.node) return { ok:false, reason:'no-stored-anchor', key:key };
        var node = anchor.node;
        if (!crKindleIsDocumentScroller(node) && !node.isConnected) return { ok:false, reason:'anchor-node-detached', key:key };
        var result = crKindleSetScrollTopAnimated(node, Number(anchor.scrollTop || 0));
        var pending = !!(result && result.moved && result.animated);
        var candidate = pending ? null : crKindleCandidateForKey(key);
        var afterTop = candidate && candidate.rect ? Number(candidate.rect.top || 0) : NaN;
        var targetTop = Number(anchor.targetTop || 0);
        var aligned = isFinite(afterTop) && Math.abs(afterTop - targetTop) <= 14;
        return {
          ok: pending || aligned,
          verified: aligned,
          pending: pending,
          moved: result.moved,
          animated: !!result.animated,
          mode: 'stored-playback-anchor',
          key: key,
          before: Math.round(result.before),
          after: Math.round(result.after),
          targetScrollTop: Math.round(result.target),
          targetTop: Math.round(targetTop),
          afterTop: isFinite(afterTop) ? Math.round(afterTop) : null,
          scrollerTag: anchor.tag || ''
        };
      }
      window.__crKindleCancelScrollAnimations = function() {
        var cancelled = 0;
        var slot = '__crKindleScrollAnim';
        try {
          var nodes = crKindleScrollableNodesFor(bestCandidate());
          for (var i = 0; i < nodes.length; i++) {
            var el = nodes[i];
            if (el && el[slot] && el[slot].raf) {
              cancelAnimationFrame(el[slot].raf);
              el[slot] = null;
              cancelled += 1;
            }
          }
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), cancelled:cancelled });
        }
        return JSON.stringify({ ok:true, cancelled:cancelled });
      };
      function crKindleScrollAnchorNode(candidate) {
        var all = crKindleScrollableNodesFor(candidate);
        return all[0] || document.scrollingElement || document.body || document.documentElement;
      }
      function crKindleRememberRestoreAnchor(candidate, key, rect) {
        key = String(key || '');
        if (!key || !candidate || !candidate.el || !rect) return null;
        var el = crKindleScrollAnchorNode(candidate);
        if (!el) return null;
        var isRoot = el === document.scrollingElement || el === document.body || el === document.documentElement;
        var parentRect = isRoot ? { left:0, top:0 } : absRect(el);
        var currentTop = isRoot ? Number(window.pageYOffset || el.scrollTop || 0) : Number(el.scrollTop || 0);
        var currentLeft = isRoot ? Number(window.pageXOffset || el.scrollLeft || 0) : Number(el.scrollLeft || 0);
        var targetTop = currentTop + Number(rect.top || 0) - Number(parentRect.top || 0);
        var targetLeft = currentLeft + Number(rect.left || 0) - Number(parentRect.left || 0);
        var maxTop = Math.max(0, Number(el.scrollHeight || 0) - Number(el.clientHeight || 0));
        var maxLeft = Math.max(0, Number(el.scrollWidth || 0) - Number(el.clientWidth || 0));
        targetTop = Math.max(0, Math.min(maxTop, targetTop));
        targetLeft = Math.max(0, Math.min(maxLeft, targetLeft));
        var anchor = {
          el: el,
          key: key,
          kind: String(candidate.kind || ''),
          targetTop: targetTop,
          targetLeft: targetLeft,
          capturedTop: currentTop,
          capturedLeft: currentLeft,
          pageViewportTop: Number(rect.top || 0),
          pageViewportHeight: Number(rect.height || 0),
          scrollHeight: Number(el.scrollHeight || 0),
          clientHeight: Number(el.clientHeight || 0),
          createdAt: Date.now()
        };
        try { window.__crKindleProbe.restoreAnchors.set(key, anchor); } catch (e) {}
        return anchor;
      }
      window.__crKindleRestoreAnchor = function(key) {
        try {
          key = String(key || '');
          var anchor = key ? window.__crKindleProbe.restoreAnchors.get(key) : null;
          if (!anchor || !anchor.el) {
            return JSON.stringify({ ok:false, reason:'anchor-missing', key:key, anchors:window.__crKindleProbe.restoreAnchors.size || 0, url:location.href });
          }
          var el = anchor.el;
          var isRoot = el === document.scrollingElement || el === document.body || el === document.documentElement;
          if (!isRoot && !el.isConnected) {
            return JSON.stringify({ ok:false, reason:'anchor-scroll-node-detached', key:key, anchors:window.__crKindleProbe.restoreAnchors.size || 0, url:location.href });
          }
          var maxTop = crKindleMaxScrollTopOf(el);
          var targetTop = Math.max(0, Math.min(maxTop, Number(anchor.targetTop || 0)));
          var result = crKindleSetScrollTopAnimated(el, targetTop);
          try { if (!isRoot) el.scrollLeft = Number(anchor.targetLeft || 0); } catch (_) {}
          return JSON.stringify({
            ok:true,
            key:key,
            before:Math.round(Number(result.before || 0)),
            after:Math.round(Number(result.after || targetTop)),
            target:Math.round(targetTop),
            delta:Math.round(Number(result.delta || 0)),
            animated:!!result.animated,
            pending:!!(result.moved && result.animated),
            ageMs:Date.now() - Number(anchor.createdAt || Date.now()),
            scrollHeight:Math.round(Number(el.scrollHeight || 0)),
            clientHeight:Math.round(Number(el.clientHeight || 0)),
            capturedScrollHeight:Math.round(Number(anchor.scrollHeight || 0)),
            capturedClientHeight:Math.round(Number(anchor.clientHeight || 0)),
            url:location.href
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), key:String(key || ''), url:location.href });
        }
      };
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
        var locked = window.__crKindleProbe.liveCandidate;
        if (locked && locked.key) {
          for (var i = 0; i < list.length; i++) {
            if (list[i].key === locked.key) {
              var lc = list[i], lr = lc && lc.rect;
              var lvis = Math.max(lc.bandVisible || 0, lc.visible || 0);
              var containsAnchor = !!(lr && anchorX >= lr.left && anchorX <= lr.right && anchorY >= lr.top && anchorY <= lr.bottom);
              if (lvis > 24 || containsAnchor) return lc;
              break;
            }
          }
        }
        var best = null, score = -Infinity;
        for (var j = 0; j < list.length; j++) {
          var c = list[j], r = c && c.rect;
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
      function draw(img, key, maxWidth, quality, rect, candidate) {
        var nw = img.naturalWidth || img.width || 1;
        var nh = img.naturalHeight || img.height || 1;
        maxWidth = Number(maxWidth || crKindleOcrMaxWidth);
        quality = Number(quality || crKindleOcrJpegQuality);
        if (!isFinite(maxWidth) || maxWidth <= 0) maxWidth = crKindleOcrMaxWidth;
        if (!isFinite(quality) || quality <= 0 || quality > 1) quality = crKindleOcrJpegQuality;
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
        var anchor = crKindleRememberRestoreAnchor(candidate || null, key || '', rect);
        return {
          ok: true,
          key: key || '',
          pixelFingerprint: crKindleVisiblePixelFingerprint(candidate || currentReadingCandidate()),
          source: 'visible',
          image: canvas.toDataURL('image/png'),
          natural: nw + 'x' + nh,
          rendered: canvas.width + 'x' + canvas.height,
          ocrMaxWidth: maxWidth,
          ocrEncoding: 'png',
          pageRect: { left:rect.left||0, top:rect.top||0, width:rect.width||0, height:rect.height||0 },
          visibleTopNorm: topNorm,
          visibleBottomNorm: bottomNorm,
          title: document.title || 'Kindle',
          url: location.href,
          progress: (document.body && (document.body.innerText || '').match(/Page\\s+\\d+\\s+of\\s+\\d+|\\d{1,3}\\s*%/i) || [''])[0],
          restoreAnchor: anchor ? {
            target: Math.round(Number(anchor.targetTop || 0)),
            captured: Math.round(Number(anchor.capturedTop || 0)),
            scrollHeight: Math.round(Number(anchor.scrollHeight || 0)),
            clientHeight: Math.round(Number(anchor.clientHeight || 0))
          } : null
        };
      }
      window.__crKindleCurrentPageSnapshot = function(maxWidth, quality) {
        try {
          var c = currentReadingCandidate();
          if (!c || !c.img || !c.img.complete || !(c.img.naturalWidth > 0)) {
            return JSON.stringify({ ok:false, reason:'no-visible-kindle-image', heldKeys: window.__crKindleProbe.keyToLiveUrl.size, url: location.href });
          }
          c = lockLiveCandidate(c) || c;
          var shot = draw(c.img, c.key || '', maxWidth || crKindleOcrMaxWidth, quality || crKindleOcrJpegQuality, c.rect, c);
          shot.source = 'current';
          shot.kind = c.kind || '';
          shot.visibleArea = c.visible || 0;
          shot.bandVisibleArea = c.bandVisible || 0;
          shot.sessionId = window.__crKindleProbe.liveSessionId || 0;
          return JSON.stringify(shot);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), url: location.href });
        }
      };
      window.__crKindleLockCurrentPageForPlayback = function(expectedKey) {
        try {
          expectedKey = String(expectedKey || '');
          var c = currentReadingCandidate();
          if (!c || !c.key) {
            return JSON.stringify({ ok:false, reason:'no-current-candidate', expectedKey:expectedKey, url:location.href });
          }
          if (expectedKey && String(c.key || '') !== expectedKey) {
            return JSON.stringify({ ok:false, reason:'visible-key-mismatch', expectedKey:expectedKey, key:String(c.key || ''), url:location.href });
          }
          c = lockLiveCandidate(c) || c;
          return JSON.stringify({
            ok:true,
            key:String(c.key || ''),
            sessionId:Number(window.__crKindleProbe.liveSessionId || 0),
            url:location.href
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), expectedKey:String(expectedKey || ''), url:location.href });
        }
      };
      function orderedIndexForCandidate(list, candidate) {
        if (!list || !list.length || !candidate) return -1;
        var key = String(candidate.key || '');
        if (key) {
          for (var i = 0; i < list.length; i++) {
            if (String(list[i].key || '') === key) return i;
          }
        }
        var rect = candidate.rect || null;
        if (!rect) return -1;
        var best = -1, bestDistance = Infinity;
        for (var j = 0; j < list.length; j++) {
          var r = list[j].rect || {};
          var d = Math.abs(Number(r.top || 0) - Number(rect.top || 0)) + Math.abs(Number(r.left || 0) - Number(rect.left || 0));
          if (d < bestDistance) { best = j; bestDistance = d; }
        }
        return best;
      }
      function orderedBrief(list) {
        return (list || []).map(function(x) {
          var top = x && x.rect ? Math.round(Number(x.rect.top || 0)) : 0;
          var bottom = x && x.rect ? Math.round(Number(x.rect.bottom || 0)) : 0;
          var width = x && x.rect ? Math.round(Number(x.rect.width || 0)) : 0;
          var height = x && x.rect ? Math.round(Number(x.rect.height || 0)) : 0;
          return String((x && x.key) || '').slice(0, 24) + ':' + top + '..' + bottom + ':' + width + 'x' + height;
        }).slice(0, 14).join('|');
      }
      window.__crKindleCandidateSnapshotNearCurrent = function(offset, maxWidth, quality) {
        try {
          offset = Number(offset || 0);
          var list = orderedCandidates();
          if (!list.length) {
            return JSON.stringify({ ok:false, reason:'no-candidates', offset:offset, heldKeys: window.__crKindleProbe.keyToLiveUrl.size, url: location.href });
          }
          var current = currentReadingCandidate();
          var currentIndex = orderedIndexForCandidate(list, current);
          if (currentIndex < 0) currentIndex = 0;
          var targetIndex = Math.max(0, Math.min(list.length - 1, currentIndex + offset));
          var c = list[targetIndex];
          if (!c || !c.img || !c.img.complete || !(c.img.naturalWidth > 0)) {
            return JSON.stringify({
              ok:false,
              reason:'candidate-not-ready',
              offset:offset,
              currentIndex:currentIndex,
              targetIndex:targetIndex,
              ordered:orderedBrief(list),
              url:location.href
            });
          }
          var shot = draw(c.img, c.key || '', maxWidth || crKindleOcrMaxWidth, quality || crKindleOcrJpegQuality, c.rect, c);
          shot.source = 'nearby';
          shot.kind = c.kind || '';
          shot.visibleArea = c.visible || 0;
          shot.bandVisibleArea = c.bandVisible || 0;
          shot.sessionId = window.__crKindleProbe.liveSessionId || 0;
          shot.offset = offset;
          shot.currentIndex = currentIndex;
          shot.targetIndex = targetIndex;
          shot.ordered = orderedBrief(list);
          return JSON.stringify(shot);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), offset:Number(offset || 0), url: location.href });
        }
      };
      window.__crKindlePageSnapshotForKey = function(key, maxWidth, quality) {
        try {
          key = String(key || '');
          if (!key) return JSON.stringify({ ok:false, reason:'empty-key', url:location.href });
          var c = crKindleCandidateForKey(key) || crKindleHeldCandidateForStableKey(key);
          if (!c || !c.img || !c.img.complete || !(c.img.naturalWidth > 0)) {
            var list = orderedCandidates();
            return JSON.stringify({
              ok:false,
              reason:'key-not-visible',
              key:key,
              observedIndex:crKindleObservedIndex(key),
              observedCount:(window.__crKindleProbe.observedPageKeys || []).length,
              heldIndex:crKindleHeldIndex(key),
              heldCount:(window.__crKindleProbe.heldPageKeys || []).length,
              ordered:list.map(function(x){ return String(x.key || '').slice(0,24) + ':' + Math.round((x.rect && x.rect.top) || 0); }).slice(0,8).join('|'),
              heldKeys:(window.__crKindleProbe.heldPageKeys || []).slice(-12),
              url: location.href
            });
          }
          c = lockLiveCandidate(c) || c;
          var shot = draw(c.img, c.key || key, maxWidth || crKindleOcrMaxWidth, quality || crKindleOcrJpegQuality, c.rect, c);
          shot.source = 'key';
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
              afterObservedIndex:crKindleObservedIndex(afterKey),
              observedCount:(window.__crKindleProbe.observedPageKeys || []).length,
              afterHeldIndex:crKindleHeldIndex(afterKey),
              heldCount:(window.__crKindleProbe.heldPageKeys || []).length,
              heldKeys:(window.__crKindleProbe.heldPageKeys || []).slice(-12),
              ordered:orderedBrief(),
              url:location.href
            });
          }
          var afterIdx = crKindleObservedIndex(afterKey);
          var nextIdx = crKindleObservedIndex(next.key || '');
          var afterHeldIdx = crKindleHeldIndex(afterKey);
          var nextHeldIdx = crKindleHeldIndex(next.key || '');
          var afterOrderIdx = afterIdx >= 0 ? afterIdx : afterHeldIdx;
          var nextOrderIdx = nextIdx >= 0 ? nextIdx : nextHeldIdx;
          if (afterOrderIdx >= 0 && nextOrderIdx >= 0 && nextOrderIdx !== afterOrderIdx + 1) {
            var badDelta = nextOrderIdx - afterOrderIdx;
            return JSON.stringify({
              ok:false,
              reason:badDelta <= 0 ? 'next-backtrack' : 'next-skip',
              orderStatus:badDelta <= 0 ? 'backtrack' : 'skip',
              afterKey:afterKey,
              candidateKey:next.key || '',
              afterObservedIndex:afterIdx,
              candidateObservedIndex:nextIdx,
              afterHeldIndex:afterHeldIdx,
              candidateHeldIndex:nextHeldIdx,
              orderDelta:badDelta,
              observedCount:(window.__crKindleProbe.observedPageKeys || []).length,
              heldCount:(window.__crKindleProbe.heldPageKeys || []).length,
              ordered:orderedBrief(),
              url:location.href
            });
          }
          // Important: preloading must not call lockLiveCandidate(). It should not mutate
          // liveKey/liveSessionId/liveCandidate; otherwise the current page highlight state
          // can be polluted before playback actually advances.
          var shot = draw(next.img, next.key || '', maxWidth || crKindleOcrMaxWidth, quality || crKindleOcrJpegQuality, next.rect, next);
          shot.source = 'next';
          shot.kind = next.kind || '';
          shot.visibleArea = next.visible || 0;
          shot.bandVisibleArea = next.bandVisible || 0;
          shot.sessionId = window.__crKindleProbe.liveSessionId || 0;
          shot.afterKey = afterKey;
          shot.prefetch = true;
          shot.ordered = orderedBrief();
          shot.afterObservedIndex = afterIdx;
          shot.candidateObservedIndex = nextIdx;
          shot.afterHeldIndex = afterHeldIdx;
          shot.candidateHeldIndex = nextHeldIdx;
          shot.orderDelta = (afterOrderIdx >= 0 && nextOrderIdx >= 0) ? (nextOrderIdx - afterOrderIdx) : null;
          shot.orderStatus = (afterOrderIdx >= 0 && nextOrderIdx >= 0)
            ? ((nextOrderIdx - afterOrderIdx) === 1 ? 'ok' : ((nextOrderIdx - afterOrderIdx) <= 0 ? 'backtrack' : 'skip'))
            : 'unknown';
          return JSON.stringify(shot);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), afterKey:String(afterKey || ''), url:location.href });
        }
      };
      window.__crKindleCandidateSnapshotsAfterKey = function(afterKey, limit, maxWidth, quality) {
        try {
          afterKey = String(afterKey || window.__crKindleProbe.liveKey || '');
          limit = Math.max(1, Math.min(12, Number(limit || 12)));
          if (!afterKey) return JSON.stringify({ ok:false, reason:'empty-after-key', pages:[], url:location.href });

          var seen = {};
          var pages = [];
          function pushCandidate(c, source, orderIndex) {
            if (pages.length >= limit || !c || !c.key || seen[c.key]) return;
            if (!c.img || !c.img.complete || !(c.img.naturalWidth > 0)) return;
            seen[c.key] = true;
            var shot = draw(c.img, c.key || '', maxWidth || crKindleOcrMaxWidth, quality || crKindleOcrJpegQuality, c.rect, c);
            shot.kind = c.kind || '';
            shot.visibleArea = c.visible || 0;
            shot.bandVisibleArea = c.bandVisible || 0;
            shot.sessionId = window.__crKindleProbe.liveSessionId || 0;
            shot.afterKey = afterKey;
            shot.prefetch = true;
            shot.source = source || 'candidate';
            shot.orderIndex = orderIndex;
            pages.push(shot);
          }

          var order = window.__crKindleProbe.heldPageKeys || [];
          if (!order.length) {
            try {
              window.__crKindleProbe.keyToLiveUrl.forEach(function(_, content) {
                crKindleRememberHeldKey(content);
              });
              order = window.__crKindleProbe.heldPageKeys || [];
            } catch (_) {}
          }
          var heldAfterKey = crKindleHeldKeyForStableKey(afterKey);
          var idx = order.indexOf(heldAfterKey);
          // An adjacent entry from the same renderer batch is the best cheap
          // speculation, but never treat it as authoritative. Kindle retains
          // previous and future batches together, so mirror the extension and
          // fill a broad recent window. Native code reconciles this cache with
          // the page key confirmed by the actual React page turn.
          if (idx >= 0) {
            pushCandidate(crKindleHeldCandidateForStableKey(order[idx + 1]), 'held-adjacent-speculation', 1);
          }
          for (var i = order.length - 1; i >= 0 && pages.length < limit; i--) {
            if (order[i] === heldAfterKey) continue;
            pushCandidate(crKindleHeldCandidateForStableKey(order[i]), 'held-recent-window', i - idx);
          }
          // A DOM neighbor can cover a just-mounted page whose Blob hash has not
          // completed yet. Keep it as the final fallback, not the first guess.
          if (pages.length < limit) {
            pushCandidate(nextCandidateAfterKey(afterKey), 'visual-neighbor-fallback', pages.length + 1);
          }
          // When the current key is from an older renderer batch, recent-first
          // may leave unused room even though older held pages still exist.
          for (var j = 0; j < order.length && pages.length < limit; j++) {
            if (order[j] === heldAfterKey) continue;
            pushCandidate(crKindleHeldCandidateForStableKey(order[j]), 'held-window-fill', j - idx);
          }

          var recentStart = Math.max(0, order.length - limit - 1);
          var diagnosticKeys = order.slice(recentStart);
          if (idx >= 0 && diagnosticKeys.indexOf(heldAfterKey) < 0) {
            diagnosticKeys.unshift(heldAfterKey);
            if (idx + 1 < order.length) diagnosticKeys.splice(1, 0, order[idx + 1]);
          }

          return JSON.stringify({
            ok: pages.length > 0,
            reason: pages.length > 0 ? '' : 'no-candidate-pages',
            afterKey: afterKey,
            pages: pages,
            heldCount: order.length,
            afterHeldIndex: idx,
            orderedKeys: diagnosticKeys,
            url: location.href
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), afterKey:String(afterKey || ''), pages:[], url:location.href });
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
        crKindleAllowProgrammaticScroll(1400);
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
              var alignResult = scrollCandidateIntoView(c, block);
              try { crKindleUpdateLiveOverlay(); } catch (_) {}
              var current = currentReadingCandidate();
              var refreshed = crKindleCandidateForKey(key) || c;
              var r = refreshed && refreshed.rect ? refreshed.rect : {};
              return JSON.stringify({
                ok:true,
                key:key,
                currentKey:current && current.key ? current.key : '',
                block:block,
                align:alignResult,
                rect:r ? { left:Math.round(Number(r.left || 0)), top:Math.round(Number(r.top || 0)), width:Math.round(Number(r.width || 0)), height:Math.round(Number(r.height || 0)) } : null,
                visibleArea:refreshed ? (refreshed.visible || 0) : 0,
                bandVisibleArea:refreshed ? (refreshed.bandVisible || 0) : 0,
                url:location.href
              });
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
      function crKindleParagraphFragmentRects(para, mapper) {
        var fragments = (para && para.visualFragments) || [];
        return fragments.map(function(fragment) {
          return mapper(fragment && fragment.bboxNorm);
        }).filter(Boolean);
      }
      function crKindleLiveViewport() {
        var h = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
        return {
          top:0,
          bottom:h,
          height:h,
          topGuard:Math.max(48, h * 0.10),
          lower:Math.max(240, h * 0.72),
          hardLower:Math.max(280, h * 0.86),
          target:Math.max(120, h * 0.44)
        };
      }
      function crKindleLiveLineKey(word) {
        var n = word && word.bboxNorm ? word.bboxNorm : {};
        return Math.round(Number(n.y || 0) * 1000);
      }
      function crKindleLiveLineRectForWord(para, wordIndex) {
        if (!para || !para.words) return null;
        var word = para.words[Number(wordIndex)];
        if (!word || !word.bboxNorm) return null;
        var targetRect = crKindleNormRectInViewport(word.bboxNorm);
        if (!targetRect) return null;
        var targetMid = Number(targetRect.top || 0) + Number(targetRect.height || 0) / 2;
        var rects = [];
        for (var i = 0; i < para.words.length; i++) {
          var candidateWord = para.words[i];
          if (!candidateWord || !candidateWord.bboxNorm) continue;
          var r = crKindleNormRectInViewport(candidateWord.bboxNorm);
          if (!r) continue;
          var mid = Number(r.top || 0) + Number(r.height || 0) / 2;
          var tol = Math.max(5, Math.min(Number(targetRect.height || 0), Number(r.height || 0)) * 0.78);
          if (Math.abs(mid - targetMid) <= tol) rects.push(r);
        }
        var line = crKindleUnion(rects);
        if (!line) return null;
        line.right = Number(line.left || 0) + Number(line.width || 0);
        line.bottom = Number(line.top || 0) + Number(line.height || 0);
        line.lineIndex = crKindleLiveLineKey(word);
        return line;
      }
      function crKindleLiveScrollRectToAnchor(rect, expectedKey, reason, force) {
        expectedKey = String(expectedKey || '');
        if (!rect) return { ok:false, reason:'missing-rect', key:expectedKey };
        var vp = crKindleLiveViewport();
        var top = Number(rect.top || 0);
        var bottom = Number(rect.bottom || (top + Number(rect.height || 0)));
        var anchorSlackTop = Math.max(36, vp.height * 0.055);
        var anchorSlackBottom = Math.max(54, vp.height * 0.075);
        var inAnchor = top >= (vp.target - anchorSlackTop) &&
          top <= (vp.target + anchorSlackBottom) &&
          bottom > vp.topGuard &&
          bottom <= vp.hardLower;
        var inComfort = top >= vp.topGuard && bottom <= vp.lower;
        if (inAnchor || (!force && inComfort)) {
          return {
            ok:true,
            key:expectedKey,
            moved:false,
            needed:false,
            reason:inAnchor ? 'in-anchor' : 'in-comfort',
            inAnchor:inAnchor,
            inComfort:inComfort,
            top:Math.round(top),
            bottom:Math.round(bottom),
            target:Math.round(vp.target),
            lower:Math.round(vp.lower),
            hardLower:Math.round(vp.hardLower),
            viewportH:Math.round(vp.height)
          };
        }
        var delta = top - vp.target;
        if (Math.abs(delta) < 32) {
          return {
            ok:true,
            key:expectedKey,
            moved:false,
            needed:false,
            reason:'small-delta',
            inComfort:inComfort,
            delta:Math.round(delta),
            top:Math.round(top),
            bottom:Math.round(bottom),
            target:Math.round(vp.target),
            lower:Math.round(vp.lower),
            hardLower:Math.round(vp.hardLower),
            viewportH:Math.round(vp.height)
          };
        }
        delta = Math.max(-vp.height * 0.82, Math.min(vp.height * 0.82, delta));
        var result = crKindleSoftScroll(delta, expectedKey);
        result.needed = true;
        result.scrollReason = reason || 'scroll-rect-to-anchor';
        result.top = Math.round(top);
        result.bottom = Math.round(bottom);
        result.target = Math.round(vp.target);
        result.lower = Math.round(vp.lower);
        result.hardLower = Math.round(vp.hardLower);
        result.viewportH = Math.round(vp.height);
        result.inComfort = inComfort;
        return result;
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
      function crKindleLiveComfortScrollRect(rect, expectedKey, reason, maxDelta) {
        expectedKey = String(expectedKey || '');
        if (!rect) return { ok:false, reason:'no-scroll-rect' };
        var viewportH = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
        var upper = Math.max(28, viewportH * 0.12);
        var lower = Math.max(upper + 140, viewportH * 0.72);
        var target = Math.max(upper + 24, viewportH * 0.34);
        var top = Number(rect.top || 0);
        var bottom = top + Number(rect.height || 0);
        var needed = top < upper || bottom > lower;
        var delta = 0;
        if (needed) delta = top - target;
        if (Math.abs(delta) < 18) { needed = false; delta = 0; }
        if (!needed) {
          return {
            ok:true,
            reason:reason || 'in-comfort',
            key:expectedKey,
            needed:false,
            top:Math.round(top),
            bottom:Math.round(bottom),
            upper:Math.round(upper),
            lower:Math.round(lower),
            target:Math.round(target),
            viewportH:Math.round(viewportH)
          };
        }
        var limit = Math.max(72, Number(maxDelta || 220));
        delta = Math.max(-limit, Math.min(limit, delta));
        var result = crKindleSoftScroll(delta, expectedKey);
        result.needed = true;
        result.scrollReason = reason || '';
        result.top = Math.round(top);
        result.bottom = Math.round(bottom);
        result.target = Math.round(target);
        result.upper = Math.round(upper);
        result.lower = Math.round(lower);
        result.viewportH = Math.round(viewportH);
        return result;
      }
      window.__crKindleLiveScrollAfterHighlight = function(payload) {
        try {
          var data = typeof payload === 'string' ? JSON.parse(payload) : (payload || {});
          var expectedKey = String(window.__crKindleProbe.liveKey || '');
          var viewportH = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
          var top = Number(data.viewportTop);
          var bottom = Number(data.viewportBottom);
          var height = Number(data.viewportHeight || (bottom - top));
          if (!isFinite(top) || !isFinite(bottom)) {
            return JSON.stringify({ ok:false, reason:'bad-highlight-rect', key:expectedKey });
          }

          var readUpper = Math.max(72, viewportH * 0.16);
          var lineLower = Math.max(readUpper + 160, viewportH * 0.70);
          var pageLower = Math.max(lineLower + 48, viewportH * 0.84);
          var safeHeight = Math.max(24, height || 24);
          var mode = 'none';
          var delta = 0;

          if (bottom >= pageLower) {
            mode = 'page-bottom';
            delta = Math.max(viewportH * 0.50, Math.min(viewportH * 0.74, viewportH - readUpper - safeHeight));
          } else if (bottom >= lineLower) {
            mode = 'line-bottom';
            delta = Math.max(72, Math.min(viewportH * 0.28, bottom - lineLower + viewportH * 0.16));
          }

          if (!(delta > 24)) {
            return JSON.stringify({
              ok:true,
              key:expectedKey,
              needed:false,
              reason:'highlight-in-comfort',
              top:Math.round(top),
              bottom:Math.round(bottom),
              lineLower:Math.round(lineLower),
              pageLower:Math.round(pageLower),
              viewportH:Math.round(viewportH),
              lineKey:String(data.lineKey || '')
            });
          }

          var result = crKindleSoftScroll(delta, expectedKey);
          result.needed = true;
          result.scrollReason = mode;
          result.top = Math.round(top);
          result.bottom = Math.round(bottom);
          result.lineLower = Math.round(lineLower);
          result.pageLower = Math.round(pageLower);
          result.viewportH = Math.round(viewportH);
          result.lineKey = String(data.lineKey || '');
          return JSON.stringify(result);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleLiveScrollLineIfNeeded = function(payload) {
        try {
          var data;
          if (arguments.length === 1 && typeof payload === 'object') {
            data = payload || {};
          } else if (arguments.length === 1 && typeof payload === 'string' && payload.trim().charAt(0) === '{') {
            data = JSON.parse(payload);
          } else {
            data = {
              paragraphIndex:arguments[0],
              wordIndex:arguments[1],
              expectedKey:arguments[2],
              mode:arguments[3]
            };
          }
          var paragraphIndex = Number(data.paragraphIndex);
          var wordIndex = Number(data.wordIndex);
          var expectedKey = String(data.expectedKey || window.__crKindleProbe.liveKey || '');
          var mode = String(data.mode || 'line');
          var candidate = crKindleCandidateForKey(expectedKey);
          var para = crKindleFindLiveParagraph(paragraphIndex);
          if (!para || !para.words || wordIndex < 0 || wordIndex >= para.words.length) {
            return JSON.stringify({ ok:false, reason:'word-not-found', key:expectedKey, paragraphIndex:paragraphIndex, wordIndex:wordIndex });
          }
          if (candidate && candidate.rect) crKindleEnsureLiveOverlay(candidate);
          var state = crKindleUpdateLiveOverlay(candidate);
          if (!state || state.stale) return JSON.stringify({ ok:false, reason:'captured-page-not-visible', key:expectedKey });
          if (expectedKey && state.key && state.key !== expectedKey) {
            return JSON.stringify({ ok:false, reason:'key-mismatch', key:state.key, expectedKey:expectedKey });
          }
          var word = para.words[wordIndex];
          var wordRect = crKindleNormRectInViewport(word && word.bboxNorm);
          var line = crKindleLiveLineRectForWord(para, wordIndex) || wordRect;
          if (!line) return JSON.stringify({ ok:false, reason:'missing-line-rect', key:expectedKey });
          var vp = crKindleLiveViewport();
          var lineTop = Number(line.top || 0);
          var lineBottom = Number(line.bottom || (lineTop + Number(line.height || 0)));
          var shouldMove = mode === 'paragraph' || lineBottom > vp.lower || lineTop < vp.topGuard;
          var lineKey = String(data.lineKey || (String(paragraphIndex) + ':' + (line.lineIndex || crKindleLiveLineKey(word))));
          if (!shouldMove) {
            return JSON.stringify({
              ok:true,
              key:expectedKey,
              moved:false,
              needed:false,
              reason:'line-stable',
              mode:mode,
              lineKey:lineKey,
              lineTop:Math.round(lineTop),
              lineBottom:Math.round(lineBottom),
              topGuard:Math.round(vp.topGuard),
              lower:Math.round(vp.lower),
              hardLower:Math.round(vp.hardLower),
              target:Math.round(vp.target),
              viewportH:Math.round(vp.height)
            });
          }
          var result = crKindleLiveScrollRectToAnchor(
            line,
            expectedKey,
            mode === 'paragraph' ? 'paragraph-anchor' : 'line-near-bottom',
            true
          );
          result.mode = mode;
          result.lineKey = lineKey;
          result.lineTop = Math.round(lineTop);
          result.lineBottom = Math.round(lineBottom);
          result.topGuard = Math.round(vp.topGuard);
          result.lower = Math.round(vp.lower);
          result.hardLower = Math.round(vp.hardLower);
          result.target = Math.round(vp.target);
          return JSON.stringify(result);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
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
        var marksSvg = document.getElementById('castreader-kindle-live-marks-svg');
        if (marksSvg) marksSvg.remove();
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
      window.__crKindleLiveHighlightWord = function(paragraphIndex, wordIndex, sequence) {
        try {
          var seq = Number(sequence || 0);
          if (seq > 0) {
            var currentSeq = Number(window.__crKindleProbe.visualSeq || 0);
            if (seq < currentSeq) {
              return JSON.stringify({ ok:false, stale:true, reason:'stale-visual-seq', sequence:seq, currentSequence:currentSeq });
            }
            window.__crKindleProbe.visualSeq = seq;
          }
          var expectedKey = String(window.__crKindleProbe.liveKey || '');
          var candidate = crKindleCandidateForKey(expectedKey);
          var para = crKindleFindLiveParagraph(paragraphIndex);
          if (!para || !para.words || wordIndex < 0 || wordIndex >= para.words.length) return JSON.stringify({ ok:false, reason:'word-not-found' });
          if (candidate && candidate.rect) crKindleEnsureLiveOverlay(candidate);
          var state = crKindleUpdateLiveOverlay(candidate);
          if (!state || state.stale) return JSON.stringify({ ok:false, reason:'captured-page-not-visible', key:expectedKey });
          var word = para.words[wordIndex];
          var viewportRect = crKindleNormRectInViewport(word.bboxNorm);
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
          div.textContent = '';
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
          var vp = crKindleLiveViewport();
          var viewportH = vp.height;
          var viewportTop = viewportRect ? Number(viewportRect.top || 0) : Number(divRect.top || 0);
          var viewportHeight = viewportRect ? Number(viewportRect.height || 0) : Number(divRect.height || 0);
          var viewportBottom = viewportTop + viewportHeight;
          var lineRect = crKindleLiveLineRectForWord(para, wordIndex);
          var lineTop = lineRect ? Number(lineRect.top || viewportTop) : viewportTop;
          var lineBottom = lineRect ? Number(lineRect.bottom || viewportBottom) : viewportBottom;
          var lineKey = String(paragraphIndex) + ':' + (lineRect && isFinite(Number(lineRect.lineIndex)) ? Number(lineRect.lineIndex) : crKindleLiveLineKey(word));
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
            sequence:seq,
            currentSequence:Number(window.__crKindleProbe.visualSeq || 0),
            bboxNorm:[Number(word.bboxNorm && word.bboxNorm.x || 0).toFixed(4), Number(word.bboxNorm && word.bboxNorm.y || 0).toFixed(4), Number(word.bboxNorm && word.bboxNorm.width || 0).toFixed(4), Number(word.bboxNorm && word.bboxNorm.height || 0).toFixed(4)].join(','),
            pct:[pct.left.toFixed(2), pct.top.toFixed(2), pct.width.toFixed(2), pct.height.toFixed(2)].join(','),
            viewportTop:Math.round(viewportTop),
            viewportBottom:Math.round(viewportBottom),
            viewportHeight:Math.round(viewportHeight),
            viewportH:Math.round(viewportH),
            lineKey:lineKey,
            lineTop:Math.round(lineTop),
            lineBottom:Math.round(lineBottom),
            lower:Math.round(vp.lower),
            hardLower:Math.round(vp.hardLower),
            target:Math.round(vp.target),
            nearLineBottom:lineBottom >= vp.lower,
            nearPageBottom:lineBottom >= vp.hardLower,
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
      window.__crKindleLiveHighlightWords = function(paragraphIndex, startWordIndex, endWordIndex, sequence) {
        try {
          var seq = Number(sequence || 0);
          var currentSeq = Number(window.__crKindleProbe.visualSeq || 0);
          if (seq > 0 && seq < currentSeq) return JSON.stringify({ ok:false, stale:true, reason:'stale-visual-seq' });
          if (seq > 0) window.__crKindleProbe.visualSeq = seq;
          var expectedKey = String(window.__crKindleProbe.liveKey || '');
          var candidate = crKindleCandidateForKey(expectedKey);
          var para = crKindleFindLiveParagraph(paragraphIndex);
          var start = Math.max(0, Number(startWordIndex || 0));
          var end = Math.min(para && para.words ? para.words.length : 0, Number(endWordIndex || 0));
          if (!para || !para.words || end <= start) return JSON.stringify({ ok:false, reason:'word-range-not-found' });
          if (candidate && candidate.rect) crKindleEnsureLiveOverlay(candidate);
          var state = crKindleUpdateLiveOverlay(candidate);
          if (!state || state.stale) return JSON.stringify({ ok:false, reason:'captured-page-not-visible', key:expectedKey });
          var rects = crKindleLineUnions(para.words.slice(start, end).map(function(word) {
            return crKindleNormRectInOverlay(word && word.bboxNorm);
          }).filter(Boolean));
          if (!rects.length) return JSON.stringify({ ok:false, reason:'word-range-no-rects' });
          var ov = window.__crKindleProbe.liveOverlay;
          if (!ov) return JSON.stringify({ ok:false, reason:'no-overlay' });
          var container = ov.querySelector('#castreader-kindle-live-word');
          if (!container) {
            container = document.createElement('div');
            container.id = 'castreader-kindle-live-word';
            container.className = 'cr-kindle-live-word-range';
            container.setAttribute('data-castreader-overlay', 'kindle-segment-local');
            ov.appendChild(container);
          }
          container.textContent = '';
          container.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;pointer-events:none;z-index:20;';
          rects.forEach(function(rect) {
            var div = document.createElement('div');
            div.style.cssText = 'position:absolute;pointer-events:none;background:rgba(242,101,34,0.28);border-radius:3px;box-sizing:border-box;';
            div.style.left = (rect.left - 2) + 'px';
            div.style.top = (rect.top - 1) + 'px';
            div.style.width = (rect.width + 4) + 'px';
            div.style.height = (rect.height + 2) + 'px';
            container.appendChild(div);
          });
          return JSON.stringify({ ok:true, key:expectedKey, paragraphIndex:paragraphIndex,
            startWordIndex:start, endWordIndex:end, rects:rects.length, sequence:seq });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleLiveClearWord = function() {
        try {
          var word = document.getElementById('castreader-kindle-live-word');
          if (word) word.remove();
          return JSON.stringify({ ok:true });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      function crKindleMarkSvg(layer) {
        if (!layer) return null;
        var svg = layer.querySelector('#castreader-kindle-live-marks-svg');
        if (!svg) {
          svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg');
          svg.id = 'castreader-kindle-live-marks-svg';
          svg.classList.add('cr-kindle-live-mark-svg');
          svg.setAttribute('data-castreader-overlay', 'kindle-marks-local');
          svg.style.cssText = 'position:absolute;left:0;top:0;width:100%;height:100%;overflow:visible;pointer-events:none;z-index:12;';
          layer.appendChild(svg);
        }
        var w = Math.max(1, Math.round(layer.clientWidth || layer.getBoundingClientRect().width || 1));
        var h = Math.max(1, Math.round(layer.clientHeight || layer.getBoundingClientRect().height || 1));
        svg.setAttribute('viewBox', '0 0 ' + w + ' ' + h);
        svg.setAttribute('width', String(w));
        svg.setAttribute('height', String(h));
        return svg;
      }
      function crKindleMulberry32(seed) {
        var s = (Number(seed || 1) >>> 0);
        return function() {
          s = (s + 0x6d2b79f5) >>> 0;
          var t = Math.imul(s ^ (s >>> 15), 1 | s);
          t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
          return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
        };
      }
      function crKindleJitter(v, amp, rng) {
        return Number(v || 0) + (rng() - 0.5) * Number(amp || 0);
      }
      function crKindleHandDrawnLine(x0, y0, x1, y1, waviness, rng) {
        var dx = x1 - x0, dy = y1 - y0;
        var len = Math.sqrt(dx * dx + dy * dy);
        var segments = Math.max(4, Math.round(len / 30));
        var d = 'M ' + crKindleJitter(x0, 3, rng).toFixed(1) + ' ' + crKindleJitter(y0, waviness, rng).toFixed(1);
        for (var i = 1; i <= segments; i++) {
          var t = i / segments;
          var x = x0 + dx * t;
          var y = y0 + dy * t + (rng() - 0.5) * waviness * 2;
          var cpx = x0 + dx * (t - 0.5 / segments) + (rng() - 0.5) * 8;
          var cpy = y0 + dy * (t - 0.5 / segments) + (rng() - 0.5) * waviness * 2;
          d += ' Q ' + cpx.toFixed(1) + ' ' + cpy.toFixed(1) + ' ' + x.toFixed(1) + ' ' + y.toFixed(1);
        }
        return d;
      }
      function crKindleHandDrawnLoop(cx, cy, rx, ry, n, rng) {
        var pts = [];
        var count = Math.max(8, Number(n || 12));
        var over = Math.max(1, Math.round(count * 0.12));
        for (var i = 0; i <= count + over; i++) {
          var a = (i / count) * Math.PI * 2;
          var rjx = rx * (1 + (rng() - 0.5) * 0.15);
          var rjy = ry * (1 + (rng() - 0.5) * 0.15);
          pts.push({ x: cx + Math.cos(a) * rjx, y: cy + Math.sin(a) * rjy });
        }
        var d = 'M ' + pts[0].x.toFixed(1) + ' ' + pts[0].y.toFixed(1);
        for (var j = 1; j < pts.length; j++) {
          var prev = pts[j - 1], cur = pts[j];
          var cpx1 = prev.x + (cur.x - prev.x) * 0.4 + (rng() - 0.5) * 6;
          var cpy1 = prev.y + (cur.y - prev.y) * 0.1 + (rng() - 0.5) * 6;
          var cpx2 = prev.x + (cur.x - prev.x) * 0.6 + (rng() - 0.5) * 6;
          var cpy2 = prev.y + (cur.y - prev.y) * 0.9 + (rng() - 0.5) * 6;
          d += ' C ' + cpx1.toFixed(1) + ' ' + cpy1.toFixed(1) + ',' + cpx2.toFixed(1) + ' ' + cpy2.toFixed(1) + ',' + cur.x.toFixed(1) + ' ' + cur.y.toFixed(1);
        }
        return d;
      }
      function crKindleHandDrawnDigit(digit, cx, cy, size, rng) {
        function j(v, amp) { return crKindleJitter(v, amp == null ? 0.7 : amp, rng).toFixed(1); }
        var h = size, w = size * 0.58;
        var T = cy - h / 2, B = cy + h / 2, L = cx - w / 2, R = cx + w / 2, My = cy;
        switch ((((Number(digit || 0) % 10) + 10) % 10)) {
          case 1: return 'M ' + j(cx-w*0.28) + ' ' + j(T+h*0.22) + ' Q ' + j(cx-w*0.06) + ' ' + j(T+h*0.05) + ' ' + j(cx) + ' ' + j(T) + ' Q ' + j(cx) + ' ' + j(My) + ' ' + j(cx) + ' ' + j(B);
          case 2: return 'M ' + j(L+w*0.08) + ' ' + j(T+h*0.24) + ' Q ' + j(cx-w*0.05) + ' ' + j(T-h*0.02) + ' ' + j(cx+w*0.2) + ' ' + j(T) + ' Q ' + j(R+w*0.05) + ' ' + j(T+h*0.12) + ' ' + j(cx+w*0.1) + ' ' + j(My+h*0.05) + ' Q ' + j(cx-w*0.1) + ' ' + j(My+h*0.22) + ' ' + j(L) + ' ' + j(B) + ' L ' + j(R) + ' ' + j(B);
          case 3: return 'M ' + j(L+w*0.05) + ' ' + j(T+h*0.08) + ' Q ' + j(cx+w*0.35) + ' ' + j(T-h*0.02) + ' ' + j(cx+w*0.1) + ' ' + j(My-h*0.02) + ' Q ' + j(R+w*0.05) + ' ' + j(My+h*0.04) + ' ' + j(cx+w*0.1) + ' ' + j(My+h*0.24) + ' Q ' + j(cx-w*0.2) + ' ' + j(B+h*0.02) + ' ' + j(L) + ' ' + j(B-h*0.1);
          case 4: return 'M ' + j(cx+w*0.12) + ' ' + j(T) + ' Q ' + j(L-w*0.05) + ' ' + j(My+h*0.08) + ' ' + j(L-w*0.08) + ' ' + j(My+h*0.14) + ' L ' + j(R+w*0.05) + ' ' + j(My+h*0.14) + ' M ' + j(cx+w*0.18) + ' ' + j(T+h*0.15) + ' Q ' + j(cx+w*0.18) + ' ' + j(My) + ' ' + j(cx+w*0.18) + ' ' + j(B);
          case 5: return 'M ' + j(R) + ' ' + j(T+h*0.02) + ' L ' + j(L+w*0.08) + ' ' + j(T) + ' Q ' + j(L+w*0.02) + ' ' + j(My-h*0.05) + ' ' + j(L+w*0.05) + ' ' + j(My+h*0.05) + ' Q ' + j(cx+w*0.4) + ' ' + j(My-h*0.04) + ' ' + j(cx+w*0.3) + ' ' + j(My+h*0.18) + ' Q ' + j(cx+w*0.1) + ' ' + j(B+h*0.04) + ' ' + j(L) + ' ' + j(B-h*0.08);
          case 6: return 'M ' + j(cx+w*0.28) + ' ' + j(T) + ' Q ' + j(L-w*0.02) + ' ' + j(My-h*0.08) + ' ' + j(L) + ' ' + j(My+h*0.12) + ' Q ' + j(L-w*0.02) + ' ' + j(B) + ' ' + j(cx) + ' ' + j(B) + ' Q ' + j(R+w*0.02) + ' ' + j(B) + ' ' + j(R) + ' ' + j(My+h*0.14) + ' Q ' + j(R-w*0.05) + ' ' + j(My) + ' ' + j(L+w*0.12) + ' ' + j(My+h*0.14);
          case 7: return 'M ' + j(L) + ' ' + j(T) + ' L ' + j(R) + ' ' + j(T) + ' Q ' + j(cx+w*0.05) + ' ' + j(My) + ' ' + j(cx-w*0.12) + ' ' + j(B);
          case 8: return crKindleHandDrawnLoop(cx, cy - h * 0.26, w * 0.4, h * 0.24, 10, rng) + ' ' + crKindleHandDrawnLoop(cx, cy + h * 0.26, w * 0.48, h * 0.26, 10, rng);
          case 9: return crKindleHandDrawnLoop(cx, cy - h * 0.2, w * 0.46, h * 0.28, 10, rng) + ' M ' + j(cx+w*0.4) + ' ' + j(My-h*0.18) + ' Q ' + j(cx+w*0.28) + ' ' + j(My+h*0.2) + ' ' + j(cx-w*0.05) + ' ' + j(B);
          case 0: return crKindleHandDrawnLoop(cx, cy, w * 0.5, h * 0.48, 12, rng);
          default: return crKindleHandDrawnLoop(cx, cy, w * 0.5, h * 0.48, 12, rng);
        }
      }
      function crKindleMarkDuration(action, rect) {
        var span = action === 'circle'
          ? Math.PI * (Number(rect.width || 0) + Number(rect.height || 0)) * 0.35
          : action === 'number'
            ? Math.max(40, Number(rect.height || 0) * 1.4)
            : Number(rect.width || 0);
        return Math.max(450, Math.min(2200, span * 3.5));
      }
      function crKindleMarkStroke(weight, fallback) {
        var base = Number(fallback || 6);
        if (weight === 'primary') return base * 1.12;
        if (weight === 'tertiary') return base * 0.76;
        return base;
      }
      function crKindleDrawAnimatedPath(parent, d, stroke, strokeWidth, opacity, duration, delay, fill, extraStyle, animate) {
        var shouldAnimate = animate !== false;
        var path = document.createElementNS('http://www.w3.org/2000/svg', 'path');
        path.setAttribute('d', d);
        path.setAttribute('fill', fill || 'none');
        path.setAttribute('stroke', stroke || 'rgba(253,95,1,0.9)');
        path.setAttribute('stroke-width', String(strokeWidth || 5));
        path.setAttribute('stroke-linecap', 'round');
        path.setAttribute('stroke-linejoin', 'round');
        path.setAttribute('opacity', String(opacity == null ? 1 : opacity));
        path.setAttribute('vector-effect', 'non-scaling-stroke');
        path.style.cssText = (extraStyle || '');
        parent.appendChild(path);
        var len = 180;
        try { len = Math.max(1, path.getTotalLength()); } catch (e) {}
        if (shouldAnimate) {
          path.style.strokeDasharray = String(len);
          path.style.strokeDashoffset = String(len);
          path.style.transition = 'none';
          try { path.getBoundingClientRect(); } catch (e) {}
          requestAnimationFrame(function() {
            requestAnimationFrame(function() {
              path.style.transition = 'stroke-dashoffset ' + Math.round(duration || 700) + 'ms cubic-bezier(0.62,0,0.22,1) ' + Math.round(delay || 0) + 'ms, opacity 180ms ease';
              path.style.strokeDashoffset = '0';
            });
          });
        } else {
          path.style.strokeDasharray = 'none';
          path.style.strokeDashoffset = '0';
          path.style.transition = 'none';
        }
        return path;
      }
      function crKindleDrawHandMark(svg, group, rects, data) {
        var action = String(data.action || 'highlight');
        var weight = String(data.weight || '');
        var seed = Number(data.seed || Date.now()) >>> 0;
        var animate = data.animate !== false;
        var union = crKindleUnion(rects);
        if (!union) return;
        var stroke = 'rgba(253,95,1,0.92)';
        var fillStroke = 'rgba(253,95,1,0.55)';
        if (action === 'circle') {
          var rngCircle = crKindleMulberry32(seed + 17);
          var cx = union.left + union.width / 2;
          var cy = union.top + union.height / 2;
          var dCircle = crKindleHandDrawnLoop(cx, cy, Math.max(10, union.width / 2 + 7), Math.max(9, union.height / 2 + 5), 14, rngCircle);
          crKindleDrawAnimatedPath(group, dCircle, stroke, crKindleMarkStroke(weight, 6.5), 0.92, crKindleMarkDuration(action, union), 0, 'none', '', animate);
          return;
        }
        if (action === 'number') {
          var rngNumber = crKindleMulberry32(seed + 29);
          var first = rects[0] || union;
          var lineH = Math.max(14, Number(first.height || union.height || 14));
          var r = Math.min(lineH * 0.6, 16);
          var cxn = Number(first.left || union.left || 0) - r * 1.5;
          if (cxn - r < 4) cxn = Number(first.left || union.left || 0) + r * 0.35;
          var cyn = Number(first.top || union.top || 0) + lineH / 2;
          var kk = 0.5523;
          function jr(v) { return crKindleJitter(v, 0.9, rngNumber).toFixed(1); }
          var x0 = cxn - r, x1 = cxn + r, y0 = cyn - r, y1 = cyn + r;
          var dNumCircle =
            'M ' + jr(cxn) + ' ' + jr(y0) + ' C ' + jr(cxn + r * kk) + ' ' + jr(y0) + ' ' + jr(x1) + ' ' + jr(cyn - r * kk) + ' ' + jr(x1) + ' ' + jr(cyn) +
            ' C ' + jr(x1) + ' ' + jr(cyn + r * kk) + ' ' + jr(cxn + r * kk) + ' ' + jr(y1) + ' ' + jr(cxn) + ' ' + jr(y1) +
            ' C ' + jr(cxn - r * kk) + ' ' + jr(y1) + ' ' + jr(x0) + ' ' + jr(cyn + r * kk) + ' ' + jr(x0) + ' ' + jr(cyn) +
            ' C ' + jr(x0) + ' ' + jr(cyn - r * kk) + ' ' + jr(cxn - r * kk) + ' ' + jr(y0) + ' ' + jr(cxn + r * 0.5) + ' ' + jr(y0 + r * 0.15);
          var draw = crKindleMarkDuration(action, union);
          crKindleDrawAnimatedPath(group, dNumCircle, stroke, 2.5, 0.9, Math.round(draw * 0.5), 0, 'none', '', animate);
          var dDigit = crKindleHandDrawnDigit(Number(data.n || 1) >= 1 ? Number(data.n || 1) : 1, cxn, cyn, r * 1.12, rngNumber);
          crKindleDrawAnimatedPath(group, dDigit, stroke, 2.5, 0.95, Math.round(draw * 0.5), Math.round(draw * 0.5), 'none', '', animate);
          var dUnderline = '';
          rects.forEach(function(rect) {
            var uy = rect.top + rect.height + 3;
            dUnderline += crKindleHandDrawnLine(rect.left - 2, uy, rect.left + rect.width + 4, uy, 1.5, rngNumber) + ' ';
          });
          if (dUnderline.trim()) {
            crKindleDrawAnimatedPath(group, dUnderline.trim(), stroke, 2.5, 0.9, Math.round(draw * 0.7), 0, 'none', '', animate);
          }
          return;
        }
        rects.forEach(function(rect, i) {
          var rng = crKindleMulberry32(seed + i * 9973 + 101);
          var duration = crKindleMarkDuration(action, rect);
          var delay = i * 110;
          if (action === 'underline') {
            var uy = rect.top + rect.height - Math.max(1.5, rect.height * 0.08);
            var ud = crKindleHandDrawnLine(rect.left - 1, uy, rect.left + rect.width + 1, uy, Math.max(3, rect.height * 0.12), rng);
            crKindleDrawAnimatedPath(group, ud, stroke, crKindleMarkStroke(weight, 5.2), 0.94, duration, delay, 'none', '', animate);
          } else {
            var hy = rect.top + rect.height * 0.58;
            var hd = crKindleHandDrawnLine(rect.left - 2, hy, rect.left + rect.width + 2, hy, Math.max(4, rect.height * 0.12), rng);
            var sw = crKindleMarkStroke(weight, Math.max(8, Math.min(18, rect.height * 0.78)));
            crKindleDrawAnimatedPath(group, hd, fillStroke, sw, 0.42, duration, delay, 'none', 'mix-blend-mode:multiply;', animate);
          }
        });
      }
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
            rects = crKindleParagraphFragmentRects(para, crKindleNormRectInOverlay);
            if (!rects.length) {
              var fallback = crKindleNormRectInOverlay(crKindleParagraphNormRect(para));
              if (fallback) rects = [fallback];
            }
          }
          var svg = crKindleMarkSvg(layer);
          if (!svg) return JSON.stringify({ ok:false, reason:'no-mark-svg', key:expectedKey });
          var group = document.createElementNS('http://www.w3.org/2000/svg', 'g');
          group.classList.add('cr-kindle-live-mark-group');
          if (data.id) group.setAttribute('data-cr-mark-id', data.id);
          svg.appendChild(group);
          crKindleDrawHandMark(svg, group, rects, data);
          return JSON.stringify({ ok:true, rects:rects.length });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleLiveScrollToRange = function(payload) {
        try {
          var data = typeof payload === 'string' ? JSON.parse(payload) : payload;
          var expectedKey = String(window.__crKindleProbe.liveKey || '');
          var page = crKindleLivePageRect();
          if (!page) return JSON.stringify({ ok:false, reason:'captured-page-not-visible', key:expectedKey });
          var para = crKindleFindLiveParagraph(data.paragraphIndex);
          if (!para) return JSON.stringify({ ok:false, reason:'para-not-found' });
          var words = crKindleWordsForRange(para, Number(data.charStart || 0), Number(data.charEnd || 0));
          if (!words.length && para.words) words = para.words;
          var rects = crKindleLineUnions(words.map(function(word) { return crKindleNormRectInViewport(word.bboxNorm); }).filter(Boolean));
          if (!rects.length) rects = crKindleParagraphFragmentRects(para, crKindleNormRectInViewport);
          var rect = crKindleUnion(rects);
          if (!rect) rect = crKindleNormRectInViewport(crKindleParagraphNormRect(para));
          var result = crKindleLiveComfortScrollRect(rect, expectedKey, 'mark', 220);
          result.rects = rects.length;
          result.paragraphIndex = Number(data.paragraphIndex || 0);
          return JSON.stringify(result);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleLiveClearMarks = function() {
        try {
          var layer = window.__crKindleProbe.liveOverlay;
          if (layer) {
            Array.from(layer.querySelectorAll('.cr-kindle-live-mark-group,.cr-kindle-live-mark,#castreader-kindle-live-marks-svg')).forEach(function(el) { el.remove(); });
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
          var rect = crKindleNormRectInViewport(norm);
          var result = crKindleLiveComfortScrollRect(rect, expectedKey, 'paragraph', 220);
          result.paragraphIndex = Number(paragraphIndex || 0);
          return JSON.stringify(result);
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e) });
        }
      };
      window.__crKindleKeyVisibility = function(key) {
        try {
          key = String(key || '');
          var c = crKindleCandidateForKey(key);
          var viewportH = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
          if (!c || !c.el || !c.rect) {
            var best = bestCandidate();
            return JSON.stringify({
              ok:false,
              visible:false,
              aligned:false,
              reason:'key-not-visible',
              key:key,
              visibleKey:best && best.key ? best.key : '',
              observedIndex:crKindleObservedIndex(key),
              observedCount:(window.__crKindleProbe.observedPageKeys || []).length,
              heldIndex:crKindleHeldIndex(key),
              heldCount:(window.__crKindleProbe.heldPageKeys || []).length,
              url:location.href
            });
          }
          var top = Number(c.rect.top || 0);
          var bottom = Number(c.rect.bottom || 0);
          var visible = bottom > 0 && top < viewportH;
          var aligned = Math.abs(top - 8) <= 18;
          return JSON.stringify({
            ok:visible && aligned,
            visible:visible,
            aligned:aligned,
            key:key,
            visibleKey:c && c.key ? c.key : '',
            top:Math.round(top),
            bottom:Math.round(bottom),
            width:Math.round(Number(c.rect.width || 0)),
            height:Math.round(Number(c.rect.height || 0)),
            viewportH:Math.round(viewportH),
            observedIndex:crKindleObservedIndex(key),
            observedCount:(window.__crKindleProbe.observedPageKeys || []).length,
            heldIndex:crKindleHeldIndex(key),
            heldCount:(window.__crKindleProbe.heldPageKeys || []).length,
            url:location.href
          });
        } catch (e) {
          return JSON.stringify({ ok:false, visible:false, aligned:false, reason:String(e), key:String(key || ''), url:location.href });
        }
      };
      window.__crKindlePositionKeyForPlayback = function(key) {
        try {
          key = String(key || '');
          var c = crKindleCandidateForKey(key);
          if (!c || !c.el || !c.rect) {
            var restored = crKindleRestorePlaybackAnchorForKey(key);
            if (restored.ok) {
              restored.url = location.href;
              return JSON.stringify(restored);
            }
            var current = bestCandidate();
            return JSON.stringify({
              ok:false,
              reason:restored.reason || 'key-not-visible',
              key:key,
              currentKey:current && current.key ? current.key : '',
              targetIndex:crKindleObservedIndex(key),
              currentIndex:crKindleObservedIndex(current && current.key ? current.key : ''),
              targetHeldIndex:crKindleHeldIndex(key),
              currentHeldIndex:crKindleHeldIndex(current && current.key ? current.key : ''),
              observedCount:(window.__crKindleProbe.observedPageKeys || []).length,
              heldCount:(window.__crKindleProbe.heldPageKeys || []).length,
              url:location.href
            });
          }
          var result = crKindleDirectAlignCandidate(c, 8, 'playback-key-direct-align');
          var fallback = null;
          if (!result || !result.ok) {
            fallback = scrollCandidateIntoView(c, 'start');
          }
          crKindleRememberPlaybackAnchorForKey(key, 8);
          c = crKindleCandidateForKey(key);
          var top = c && c.rect ? Number(c.rect.top || 0) : 999999;
          var bottom = c && c.rect ? Number(c.rect.bottom || 0) : -999999;
          var viewportH = Math.max(1, Number(innerHeight || document.documentElement.clientHeight || 1));
          var pending = !!(result && result.pending);
          var aligned = pending || !!(c && c.rect && Math.abs(top - 8) <= 18);
          return JSON.stringify({
            ok:aligned,
            pending:pending,
            key:key,
            top:Math.round(top),
            bottom:Math.round(bottom),
            inView:!!(c && c.rect && bottom > 0 && top < viewportH),
            viewportH:Math.round(viewportH),
            observedIndex:crKindleObservedIndex(key),
            observedCount:(window.__crKindleProbe.observedPageKeys || []).length,
            heldIndex:crKindleHeldIndex(key),
            heldCount:(window.__crKindleProbe.heldPageKeys || []).length,
            align:result,
            fallback:fallback,
            url:location.href
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), key:String(key || ''), url:location.href });
        }
      };
      function crKindlePreciseRect(rect) {
        if (!rect) return null;
        return {
          left:Number(rect.left || 0),
          top:Number(rect.top || 0),
          right:Number(rect.right || 0),
          bottom:Number(rect.bottom || 0),
          width:Number(rect.width || 0),
          height:Number(rect.height || 0)
        };
      }
      function crKindleAncestorMetrics(el) {
        var out = [];
        try {
          for (var node = el, depth = 0; node && depth < 8 && node !== document.documentElement; depth++, node = node.parentElement) {
            var r = node.getBoundingClientRect ? node.getBoundingClientRect() : null;
            var st = node.nodeType === 1 ? getComputedStyle(node) : null;
            out.push({
              tag:String(node.tagName || ''),
              id:String(node.id || ''),
              className:String(node.className || '').slice(0, 160),
              rect:r ? crKindlePreciseRect(r) : null,
              overflowX:st ? String(st.overflowX || '') : '',
              overflowY:st ? String(st.overflowY || '') : '',
              transform:st ? String(st.transform || '') : ''
            });
          }
        } catch (_) {}
        return out;
      }
      function crKindleCurrentGeometryCandidate() {
        return currentReadingCandidate() || bestCandidate();
      }
      window.__crKindleGeometry = function() {
        try {
          var c = crKindleCurrentGeometryCandidate();
          var viewportW = Number(innerWidth || document.documentElement.clientWidth || 0);
          var viewportH = Number(innerHeight || document.documentElement.clientHeight || 0);
          var docRect = document.documentElement && document.documentElement.getBoundingClientRect
            ? document.documentElement.getBoundingClientRect()
            : null;
          var vv = window.visualViewport || null;
          var candidate = null;
          if (c && c.rect) {
            var nw = Number(c.nw || (c.img && c.img.naturalWidth) || 0);
            var nh = Number(c.nh || (c.img && c.img.naturalHeight) || 0);
            var scaleX = nw > 0 ? Number(c.rect.width || 0) / nw : 0;
            var scaleY = nh > 0 ? Number(c.rect.height || 0) / nh : 0;
            var topNorm = c.rect.height > 0 ? (0 - c.rect.top) / c.rect.height : 0;
            var bottomNorm = c.rect.height > 0 ? (viewportH - c.rect.top) / c.rect.height : 1;
            topNorm = Math.max(0, Math.min(1, topNorm));
            bottomNorm = Math.max(topNorm, Math.min(1, bottomNorm));
            var displayedAspect = c.rect.width > 0 ? c.rect.height / c.rect.width : 0;
            var naturalAspect = nw > 0 ? nh / nw : 0;
            var aspectError = naturalAspect > 0 ? (displayedAspect - naturalAspect) / naturalAspect : 0;
            candidate = {
              key:String(c.key || ''),
              contentKey:String(c.contentKey || ''),
              kind:String(c.kind || ''),
              rect:crKindlePreciseRect(c.rect),
              natural:{ width:nw, height:nh },
              displayScale:{ x:scaleX, y:scaleY },
              aspect:{ displayed:displayedAspect, natural:naturalAspect },
              aspectError:aspectError,
              visibleArea:Number(c.visible || 0),
              bandVisibleArea:Number(c.bandVisible || 0),
              visibleNorm:{ top:topNorm, bottom:bottomNorm },
              ancestors:crKindleAncestorMetrics(c.el)
            };
          }
          return JSON.stringify({
            ok:!!candidate,
            viewport:{ width:viewportW, height:viewportH, devicePixelRatio:Number(devicePixelRatio || 1) },
            visualViewport:vv ? {
              width:Number(vv.width || 0),
              height:Number(vv.height || 0),
              scale:Number(vv.scale || 1),
              offsetLeft:Number(vv.offsetLeft || 0),
              offsetTop:Number(vv.offsetTop || 0),
              pageLeft:Number(vv.pageLeft || 0),
              pageTop:Number(vv.pageTop || 0)
            } : null,
            documentElement:{
              clientWidth:Number(document.documentElement && document.documentElement.clientWidth || 0),
              clientHeight:Number(document.documentElement && document.documentElement.clientHeight || 0),
              scrollWidth:Number(document.documentElement && document.documentElement.scrollWidth || 0),
              scrollHeight:Number(document.documentElement && document.documentElement.scrollHeight || 0),
              rect:docRect ? crKindlePreciseRect(docRect) : null
            },
            scrollingElement:document.scrollingElement ? {
              scrollTop:Number(document.scrollingElement.scrollTop || 0),
              scrollLeft:Number(document.scrollingElement.scrollLeft || 0),
              clientWidth:Number(document.scrollingElement.clientWidth || 0),
              clientHeight:Number(document.scrollingElement.clientHeight || 0),
              scrollWidth:Number(document.scrollingElement.scrollWidth || 0),
              scrollHeight:Number(document.scrollingElement.scrollHeight || 0)
            } : null,
            candidate:candidate,
            ordered:orderedBrief(orderedCandidates()),
            orderedCount:orderedCandidates().length,
            hiddenChromeCount:document.querySelectorAll('.cr-kindle-castreader-hidden-chrome').length,
            url:location.href,
            title:document.title || ''
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e && e.message || e), url:location.href });
        }
      };
      window.__crKindleState = function() {
        var c = currentReadingCandidate();
        var list = orderedCandidates();
        var key = c && c.key ? String(c.key || '') : '';
        return JSON.stringify({
          ok: true,
          key: key,
          kind: c && c.kind ? c.kind : '',
          rect: c && c.rect ? { left:Math.round(c.rect.left), top:Math.round(c.rect.top), width:Math.round(c.rect.width), height:Math.round(c.rect.height) } : null,
          preciseRect: c && c.rect ? crKindlePreciseRect(c.rect) : null,
          naturalSize: c ? { width:Number(c.nw || 0), height:Number(c.nh || 0) } : null,
          displayScale: c && c.nw > 0 && c.nh > 0 ? { x:Number(c.rect.width || 0) / Number(c.nw || 1), y:Number(c.rect.height || 0) / Number(c.nh || 1) } : null,
          viewportWidth: Math.round(Number(innerWidth || document.documentElement.clientWidth || 0)),
          viewportHeight: Math.round(Number(innerHeight || document.documentElement.clientHeight || 0)),
          ordered: orderedBrief(list),
          orderedCount: list.length,
          observedIndex: crKindleObservedIndex(key),
          observedCount: (window.__crKindleProbe.observedPageKeys || []).length,
          heldIndex: crKindleHeldIndex(key),
          heldCount: (window.__crKindleProbe.heldPageKeys || []).length,
          liveKey: String(window.__crKindleProbe.liveKey || ''),
          pixelFingerprint: crKindleVisiblePixelFingerprint(c),
          progress: (document.body && (document.body.innerText || '').match(/(?:Page|Location|Emplacement|Position|P[aá]gina|Posici[oó]n|Ubicaci[oó]n|Localiza[cç][aã]o|Posizione|页码|頁碼|位置|ページ|पृष्ठ|स्थान)\\s*[:#-]?\\s*[0-9０-９०-९٠-٩۰-۹]+/i) || [''])[0],
          navigationSeq: Number(window.__crKindleProbe.navigationSeq || 0),
          navigationAt: Number(window.__crKindleProbe.navigationAt || 0),
          navigationReason: String(window.__crKindleProbe.navigationReason || ''),
          visibleArea: c ? (c.visible || 0) : 0,
          bandVisibleArea: c ? (c.bandVisible || 0) : 0,
          heldKeys: window.__crKindleProbe.keyToLiveUrl.size,
          url: location.href,
          title: document.title || ''
        });
      };
      window.__crKindleLiveKeys = function() {
        try {
          var visible = orderedCandidates().map(function(c) { return String((c && c.key) || ''); }).filter(Boolean);
          var observed = (window.__crKindleProbe.observedPageKeys || []).map(function(k) { return String(k || ''); }).filter(Boolean);
          var held = (window.__crKindleProbe.heldPageKeys || []).map(function(k) { return String(k || ''); }).filter(Boolean);
          var keys = [];
          var seen = {};
          function add(k) {
            k = String(k || '');
            if (!k || seen[k]) return;
            seen[k] = true;
            keys.push(k);
          }
          held.forEach(add);
          observed.forEach(add);
          visible.forEach(add);
          var current = currentReadingCandidate() || bestCandidate();
          return JSON.stringify({
            ok:true,
            keys:keys,
            visibleKeys:visible,
            observedKeys:observed.slice(-48),
            heldKeys:held.slice(-48),
            current:current && current.key ? String(current.key || '') : '',
            bestKey:bestCandidate() && bestCandidate().key ? String(bestCandidate().key || '') : '',
            observedCount:observed.length,
            heldCount:held.length,
            url:location.href
          });
        } catch (e) {
          return JSON.stringify({ ok:false, reason:String(e), url:location.href });
        }
      };
    })();
    """
}
