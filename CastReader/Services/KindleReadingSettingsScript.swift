import Foundation

/// Only user-requested changes reach Amazon's native range. Its live value is
/// authoritative; localStorage can lag behind React's persisted preferences.
enum KindleReadingSettingsScript {
    /// Kindle's resize handler can persist an older font pair from its mount
    /// closure. Preserve only that pair, only across an observed resize write;
    /// native font choices and every unrelated preference retain ownership.
    static let resizePreferenceCompatibilityBootstrap: String = {
        guard let data = try? JSONEncoder().encode(KindleStorefront.selectable.map(\.canonicalHost)),
              let hosts = String(data: data, encoding: .utf8) else { return "false" }
        return #"""
        (() => {
          const allowedHosts = \#(hosts);
          if(location.protocol !== 'https:' || (location.port && location.port !== '443') ||
             location.username || location.password || !allowedHosts.includes(location.hostname.toLowerCase())) return false;
          const existing = window.__crKindleResizePreferenceCompatibility;
          if(existing) return existing.version === 1 && existing.document === document;
          const key = 'KWR_Display_Settings', ownerDocument = document;
          let storage, originalSetItem, originalGetItem, descriptor;
          try {
            storage = window.localStorage;
            descriptor = Object.getOwnPropertyDescriptor(Storage.prototype, 'setItem');
            originalSetItem = descriptor && descriptor.value;
            originalGetItem = Storage.prototype.getItem;
            if(typeof originalSetItem !== 'function' || typeof originalGetItem !== 'function') return false;
          } catch(_) { return false; }
          const state = {version:1, document:ownerDocument, epoch:0, pending:null, correcting:false};
          const cancel = () => {
            state.epoch += 1;
            if(state.pending) clearTimeout(state.pending.timer);
            state.pending = null;
          };
          const read = () => {
            try {
              const raw = originalGetItem.call(storage, key), value = JSON.parse(raw);
              if(!value || typeof value !== 'object' || Array.isArray(value)) return null;
              const index = value.fontSizeIndex, size = value.fontSize;
              if(typeof index !== 'number' || !Number.isInteger(index) || index < 0 || index > 128 ||
                 typeof size !== 'number' || !Number.isFinite(size) || size <= 0 || size > 512) return null;
              return {raw,value,index,size};
            } catch(_) { return null; }
          };
          const owns = pending => state.pending === pending && state.epoch === pending.epoch &&
            document === ownerDocument && location.href === pending.url;
          const reconcile = pending => {
            if(!owns(pending)) {
              if(state.pending === pending) cancel();
              return;
            }
            state.pending = null;
            if(pending.lastResizeRaw === null) return;
            const current = read();
            if(!current || current.raw !== pending.lastResizeRaw ||
               (current.index === pending.index && current.size === pending.size)) return;
            const corrected = {...current.value, fontSizeIndex:pending.index, fontSize:pending.size};
            try {
              state.correcting = true;
              originalSetItem.call(storage, key, JSON.stringify(corrected));
              // This is Kindle's observed local-storage hook protocol. Its
              // value is the object, not the serialized storage string.
              window.dispatchEvent(new CustomEvent('onLocalStorageChange', {detail:{key,value:corrected}}));
            } catch(_) {
              // Storage failures do not initiate retries or page operations.
            } finally { state.correcting = false; }
          };
          const observeSetItem = function() {
            let result;
            try { result = originalSetItem.apply(this, arguments); }
            catch(error) {
              if(this === storage && arguments[0] === key) cancel();
              throw error;
            }
            // Preserve native coercion/exception semantics. Only the exact
            // string key on localStorage is observed after a successful write.
            if(this !== storage || arguments[0] !== key || state.correcting || !state.pending) return result;
            const pending = state.pending;
            try {
              const event = window.event;
              if(owns(pending) && event && event.type === 'resize' && event.eventPhase !== 0 &&
                 event.currentTarget === window && pending.resizeEvents.has(event)) {
                pending.lastResizeRaw = originalGetItem.call(storage, key);
              } else cancel();
            } catch(_) { cancel(); }
            return result;
          };
          try { Object.defineProperty(Storage.prototype, 'setItem', {...descriptor,value:observeSetItem}); }
          catch(_) { return false; }
          window.__crKindleResizePreferenceCompatibility = state;
          window.__crKindleCancelPendingFontPreferenceCorrection = cancel;
          window.addEventListener('resize', event => {
            if(state.correcting || document !== ownerDocument) return;
            if(state.pending && !owns(state.pending)) cancel();
            if(!state.pending) {
              const snapshot = read();
              if(!snapshot) return;
              const pending = {epoch:state.epoch, url:location.href, index:snapshot.index,
                size:snapshot.size, lastResizeRaw:null, resizeEvents:new WeakSet(), timer:null};
              state.pending = pending;
              pending.timer = setTimeout(() => reconcile(pending), 0);
            }
            // Nested or same-task resize events keep the first pair, while
            // each active event may supply the final observed native write.
            state.pending.resizeEvents.add(event);
          }, true);
          window.addEventListener('onLocalStorageChange', event => {
            if(state.correcting || !state.pending || !event.detail || event.detail.key !== key) return;
            try {
              if(state.pending.lastResizeRaw !== null &&
                 JSON.stringify(event.detail.value) === state.pending.lastResizeRaw) return;
            } catch(_) {}
            cancel();
          }, true);
          window.addEventListener('storage', event => {
            if(event.storageArea === storage && event.key === key) cancel();
          }, true);
          const fontIntent = event => {
            if(!state.pending) return;
            const path = typeof event.composedPath === 'function' ? event.composedPath() : [event.target];
            const fontLabel = /font[-_\s]*size|(?:increase|decrease)[-_\s]*font|字号|字體|フォント|文字サイズ|schriftgröße|taille.*police|tamañ.*fuente|tamanho.*fonte|dimension.*caratter|फ़ॉन्ट/i;
            if(path.slice(0,16).some(node => node && node.nodeType === 1 &&
               ['id','aria-label','title','data-testid','data-action'].some(name => fontLabel.test(node.getAttribute(name) || '')))) cancel();
          };
          ['click','input','change','ionInput','ionChange'].forEach(name => window.addEventListener(name, fontIntent, true));
          window.addEventListener('pagehide', cancel, true);
          return true;
        })()
        """#
    }()

    static let read = script(operation: "read")
    static func close(attempt: UInt64) -> String {
        """
        (() => {
          if(window.__crKindleFontCloseAttempt !== '\(attempt)') {
            window.__crKindleFontCloseAttempt = '\(attempt)';
            window.__crKindleFontOpenedByNative = true;
          }
          return \(close);
        })()
        """
    }
    static let close = """
    (() => {
      \(KindleWebScripts.uiSemanticHelpers)
      const button = window.__crKindleFontSettingsButton;
      const visible = el => {
        if(!el || !el.isConnected) return false;
        const r=el.getBoundingClientRect(), s=getComputedStyle(el);
        return r.width>2 && r.height>2 && s.display!=='none' && s.visibility!=='hidden';
      };
      \(nativePanelOwnershipHelpers)
      const ownership=crFontAdoptOpenedPanel();
      if(ownership==='ambiguous'||ownership==='unresolved')return JSON.stringify({ok:false,reason:'settings-panel-'+ownership});
      const panel = window.__crKindleFontSettingsPanel;
      const visibleFontRange = () => Array.from(document.querySelectorAll('input[type="range"],ion-range,[role="slider"]')).some(el => {
        const r=el.getBoundingClientRect(), s=getComputedStyle(el);
        return r.width>2 && r.height>2 && s.display!=='none' && s.visibility!=='hidden' && crKindleUISemanticScore(el,'font-size')>=45;
      });
      const nativeMenu = panel && panel.tagName.toLowerCase()==='ion-menu';
      const nativePanel = panel && (panel.matches('ion-menu,ion-popover,[role="dialog"],[role="menu"]'));
      const menuOpen = () => nativeMenu && panel.isConnected && panel.classList.contains('show-menu');
      const menuAnimating = () => {
        if(!panel||!panel.isConnected)return false;
        const elements=[panel,...panel.querySelectorAll('*')];
        if(panel.shadowRoot)elements.push(...panel.shadowRoot.querySelectorAll('*'));
        return elements.some(el=>typeof el.getAnimations==='function' && el.getAnimations().some(animation=>animation.pending||animation.playState==='running'));
      };
      const visuallyClosed=()=>!visibleFontRange()&&!visible(panel)&&!menuOpen()&&!menuAnimating()&&!(button&&button.getAttribute('aria-expanded')==='true');
      const observation=window.__crKindleFontOpenObservation;
      const closeAttempt=window.__crKindleFontCloseAttempt;
      const ownsPublicClose=state=>window.__crKindleFontPublicClose===state&&state.document===document&&
        state.panel===window.__crKindleFontSettingsPanel&&state.observation===window.__crKindleFontOpenObservation;
      const checkPublicOpen=state=>{
        if(!ownsPublicClose(state)||state.checkPending)return;
        state.checkPending=true;
        try {
          Promise.resolve(state.panel.isOpen()).then(open=>{
            if(!ownsPublicClose(state))return;
            state.checkPending=false;state.open=typeof open==='boolean'?open:null;state.checkFailed=state.open===null;
          },()=>{if(ownsPublicClose(state)){state.checkPending=false;state.checkFailed=true;}});
        } catch(_){state.checkPending=false;state.checkFailed=true;}
      };
      const pendingClose=window.__crKindleFontPublicClose;
      if(pendingClose&&ownsPublicClose(pendingClose)&&(pendingClose.pending||pendingClose.checkPending))pendingClose.attempt=closeAttempt;
      if(menuAnimating())return JSON.stringify({ok:false,reason:'settings-menu-animating'});
      if(pendingClose&&pendingClose.panel===panel&&pendingClose.observation===observation&&ownsPublicClose(pendingClose)){
        // A second Done while the native Promise is pending only observes it.
        // A settled failure may be retried by a new explicit close attempt.
        const retry=pendingClose.attempt!==closeAttempt&&!pendingClose.pending&&!pendingClose.checkPending&&
          (pendingClose.failed||pendingClose.checkFailed||pendingClose.open===true);
        if(!retry){
          if(pendingClose.pending||pendingClose.checkPending)return JSON.stringify({ok:false,reason:'closing-native-menu'});
          if(pendingClose.failed||pendingClose.checkFailed)return JSON.stringify({ok:false,reason:'native-menu-close-failed'});
          if(pendingClose.open!==false){checkPublicOpen(pendingClose);return JSON.stringify({ok:false,reason:'closing-native-menu'});}
          const closed=visuallyClosed();
          if(closed)window.__crKindleFontOpenedByNative=false;
          return JSON.stringify({ok:closed});
        }
      }
      if (window.__crKindleFontOpenedByNative && (visibleFontRange() || visible(panel) || menuOpen() || (button && button.getAttribute('aria-expanded')==='true'))) {
        const names=['close','side panel close','schließen','fermer','cerrar','fechar','chiudi','閉じる','关闭','關閉','बंद करें'];
        const normalize=raw=>String(raw || '').replace(/\\s+/g,' ').trim().toLowerCase();
        const labelledControls=panel ? Array.from(panel.querySelectorAll('button,[role="button"],ion-button,[aria-label]')).filter(el=>
          ['aria-label','title','data-testid','data-action'].map(k=>normalize(el.getAttribute(k))).concat([normalize(el.textContent)]).some(label=>names.includes(label))) : [];
        const controls=labelledControls.filter(el=>visible(el)&&!el.disabled&&!el.hasAttribute('disabled')&&el.getAttribute('aria-disabled')!=='true');
        if (controls.length > 1) return JSON.stringify({ok:false,reason:'ambiguous-close-button'});
        let current=controls[0];
        if(!current&&labelledControls.length===0&&nativeMenu&&ownership==='owned'&&panel.isConnected&&
            typeof panel.close==='function'&&typeof panel.isOpen==='function'){
          const state={panel,document,observation,attempt:closeAttempt,pending:true,failed:false,checkPending:false,checkFailed:false,open:null};
          window.__crKindleFontPublicClose=state;
          window.__crKindleFontOpenedByNative=false;
          try {
            // Keep evaluateJavaScript's result synchronous. Ionic owns the
            // animation, focus cleanup and ionDidClose notification.
            Promise.resolve(panel.close()).then(()=>{
              if(!ownsPublicClose(state))return;
              state.pending=false;checkPublicOpen(state);
            },()=>{if(ownsPublicClose(state)){state.pending=false;state.failed=true;}});
          } catch(_){state.pending=false;state.failed=true;}
          return JSON.stringify({ok:false,reason:state.failed?'native-menu-close-failed':'closing-native-menu'});
        }
        if (!current && nativePanel) return JSON.stringify({ok:false,reason:'close-control-pending'});
        if (!current) current=button && button.isConnected ? button :
          (crKindleUIFind('settings',document,'button,[role="button"],ion-button,[aria-label],[title]') || {}).el;
        if (current) {
          // Use the native panel's close control when present. Toggling Aa can
          // re-enter Kindle's settings initialization and stale preference code.
          window.__crKindleFontOpenedByNative=false;
          current.click();
        }
      }
      const closed=visuallyClosed();
      if (closed) window.__crKindleFontOpenedByNative=false;
      return JSON.stringify({ok:closed});
    })()
    """

    static func change(by delta: Int) -> String {
        script(operation: delta < 0 ? "decrease" : "increase")
    }

    private static let nativePanelOwnershipHelpers = """
    const crFontMenuOpen=menu=>menu.isConnected&&menu.classList.contains('show-menu');
    const crFontRememberOpening=button=>{
      const toggle=button.closest('ion-menu-toggle');
      window.__crKindleFontOpenObservation={button,document,
        before:Array.from(document.querySelectorAll('ion-menu')).map(menu=>({menu,open:crFontMenuOpen(menu)})),
        controls:String(button.getAttribute('aria-controls')||'').trim().split(/\\s+/).filter(Boolean),
        target:toggle ? String(toggle.getAttribute('menu')||toggle.menu||'').trim() : ''};
      window.__crKindleFontSettingsPanel=null;
      window.__crKindleFontPublicClose=null;
    };
    const crFontAdoptOpenedPanel=()=>{
      const owned=window.__crKindleFontSettingsPanel;
      if(owned&&owned.isConnected)return 'owned';
      const observation=window.__crKindleFontOpenObservation;
      if(!observation||observation.document!==document||observation.button!==window.__crKindleFontSettingsButton)return 'none';
      const menus=Array.from(document.querySelectorAll('ion-menu'));
      const opened=menus.filter(menu=>crFontMenuOpen(menu)&&!observation.before.some(before=>before.menu===menu&&before.open));
      const explicit=observation.controls.length>0||observation.target!=='';
      const candidates=explicit ? opened.filter(menu=>
        observation.controls.some(id=>document.getElementById(id)===menu)||
        (observation.target!==''&&[menu.id,menu.getAttribute('menu-id'),menu.menuId,menu.getAttribute('side'),menu.side].includes(observation.target))) : opened;
      if(candidates.length===1){window.__crKindleFontSettingsPanel=candidates[0];return 'owned';}
      if(candidates.length>1)return 'ambiguous';
      // A known target that did not open cannot confer ownership on another
      // menu. Pre-existing open menus are never acquired by this transaction.
      return explicit&&opened.length>0 ? 'unresolved' : 'none';
    };
    """

    private static let settingsSelectionHelpers = """
    const settingsNames=['reader settings','reading settings','leseeinstellungen','paramètres de lecture','paramètres du lecteur','configuración de lectura','configurações de leitura','impostazioni di lettura','読書設定','閱讀設定','阅读设置','पढ़ने की सेटिंग'];
    const settingsNorm=raw=>String(raw||'').replace(/\\s+/g,' ').trim().toLowerCase();
    const settingsKind=el=>{
      const labels=['aria-label','title','data-testid','data-action'].map(key=>settingsNorm(el.getAttribute(key))).concat([settingsNorm(el.textContent)]);
      return labels.some(label=>settingsNames.includes(label)) ? 'settings' : (labels.includes('aa') ? 'aa' : null);
    };
    const settingsRect=el=>{
      if(!el||!el.isConnected)return null;
      const r=el.getBoundingClientRect();
      return {x:r.left,y:r.top,w:r.width,h:r.height};
    };
    const settingsNativeDisabled=el=>el.disabled===true||el.hasAttribute('disabled')||el.getAttribute('aria-disabled')==='true'||el.matches(':disabled');
    const settingsRejectionReason=el=>{
      if(!el||!el.isConnected)return 'disconnected';
      if(settingsNativeDisabled(el))return 'disabled';
      const shadowButtons=el.shadowRoot ? el.shadowRoot.querySelectorAll('button') : [];
      if(shadowButtons.length===1 && settingsNativeDisabled(shadowButtons[0]))return 'disabled-shadow-button';
      const openMenu=el.closest('ion-menu.show-menu');
      for(let node=el;node;node=node.parentElement){
        const style=getComputedStyle(node);
        if(node.hidden)return 'hidden-ancestor';
        if(node.hasAttribute('inert'))return 'inert-ancestor';
        // Ionic's split-pane disabled attribute disables the split layout, not
        // its content. Native :disabled above owns fieldset/legend semantics.
        if(node.getAttribute('aria-disabled')==='true')return 'disabled-ancestor';
        if(style.display==='none')return 'display-none-ancestor';
        if(style.visibility==='hidden'||style.visibility==='collapse')return 'visibility-hidden-ancestor';
        if(Number(style.opacity||1)<=0)return 'transparent-ancestor';
        // Ionic marks the content ancestor aria-hidden even when an open menu
        // is nested inside it. Exempt only ancestors outside that proven menu.
        if(node.getAttribute('aria-hidden')==='true' && !(openMenu && node!==openMenu && node.contains(openMenu)))return 'aria-hidden-ancestor';
      }
      const r=el.getBoundingClientRect();
      if(Math.min(r.right,innerWidth)-Math.max(r.left,0)<=2 || Math.min(r.bottom,innerHeight)-Math.max(r.top,0)<=2)return 'outside-viewport-or-empty';
      return null;
    };
    const settingsTranslatedHeader=el=>{
      if(settingsRejectionReason(el)!=='outside-viewport-or-empty'||el.tagName!=='ION-BUTTON'||!el.closest('ion-header'))return false;
      const rect=el.getBoundingClientRect();
      // Kindle translates its native toolbar above the page during playback.
      // Only one exact global Aa candidate can use this bounded exception.
      return rect.width>2&&rect.height>2&&settingsCandidates().length===1;
    };
    const settingsEligible=el=>settingsRejectionReason(el)===null||settingsTranslatedHeader(el);
    const settingsCandidates=()=>Array.from(document.querySelectorAll('button,[role="button"],ion-button')).filter(el=>settingsKind(el)!==null);
    const nativePanelSelector='ion-menu,ion-popover,[role="dialog"],[role="menu"]';
    const fallbackPanelSelector='.popover-content,.modal-wrapper,section';
    const settingsPanelFor=el=>el && (el.closest(nativePanelSelector)||el.closest(fallbackPanelSelector));
    const settingsAncestors=el=>{
      const result=[];
      for(let node=el;node && result.length<16;node=node.parentElement){
        const style=getComputedStyle(node);
        result.push({tag:node.tagName,classes:Array.from(node.classList).filter(token=>/^[a-zA-Z_][a-zA-Z0-9_-]{0,63}$/.test(token)).slice(0,8),
          display:style.display,visibility:style.visibility,opacity:Number(style.opacity||1),hidden:node.hidden===true,inert:node.hasAttribute('inert'),ariaHidden:node.getAttribute('aria-hidden')==='true',disabled:node.disabled===true,disabledAttribute:node.hasAttribute('disabled'),disabledValue:['','true','false'].includes(node.getAttribute('disabled'))?node.getAttribute('disabled'):null,ariaDisabled:node.getAttribute('aria-disabled')==='true'});
      }
      return result;
    };
    const settingsMenuSnapshot=menu=>{
      const elements=[menu,...menu.querySelectorAll('*')],roots=elements.filter(el=>el.shadowRoot).map(el=>el.shadowRoot);
      const queue=[{el:menu,depth:0,shadow:false}],tree=[];
      while(queue.length&&tree.length<30){
        const item=queue.shift();tree.push({tag:item.el.tagName,depth:item.depth,shadow:item.shadow});
        if(item.depth>=3)continue;
        for(const child of item.el.children)queue.push({el:child,depth:item.depth+1,shadow:false});
        if(item.el.shadowRoot)for(const child of item.el.shadowRoot.children)queue.push({el:child,depth:item.depth+1,shadow:true});
      }
      return {open:menu.classList.contains('show-menu'),visible:visible(menu),
        controls:menu.querySelectorAll('input[type="range"],ion-range,[role="slider"]').length,
        iframeCount:menu.querySelectorAll('iframe').length,shadowRootCount:roots.length,
        shadowControls:roots.reduce((count,root)=>count+root.querySelectorAll('input[type="range"],ion-range,[role="slider"]').length,0),tree};
    };
    const settingsProbe=selected=>{
      const candidates=settingsCandidates(), eligible=candidates.filter(settingsEligible);
      const allRanges=Array.from(document.querySelectorAll('input[type="range"],ion-range,[role="slider"]'));
      const panel=window.__crKindleFontSettingsPanel;
      const ownedButton=selected||window.__crKindleFontSettingsButton;
      const button=ownedButton||(candidates.length===1?candidates[0]:null);
      const inspectionOnly=!!button&&!ownedButton;
      return {
        tocHidden:document.documentElement.getAttribute('data-cr-native-toc-hidden')==='1',
        tocOpen:document.documentElement.getAttribute('data-cr-native-toc-open')==='1',
        locked:!!(window.__crKindleProbe&&window.__crKindleProbe.pageModeLocked),lockClass:document.documentElement.classList.contains('cr-kindle-page-mode-locked'),
        openedByNative:!!window.__crKindleFontOpenedByNative,documentHidden:document.hidden,visibilityState:document.visibilityState,
        viewport:{w:innerWidth,h:innerHeight},candidateCount:candidates.length,eligibleCount:eligible.length,
        candidates:candidates.slice(0,3).map(el=>({tag:el.tagName,connected:el.isConnected,rejectionReason:settingsRejectionReason(el),translatedHeaderFallback:settingsTranslatedHeader(el),rect:settingsRect(el)})),
        button:button ? {tag:button.tagName,kind:settingsKind(button),connected:button.isConnected,eligible:settingsEligible(button),inspectionOnly,rejectionReason:settingsRejectionReason(button),ancestors:settingsAncestors(button),rect:settingsRect(button),disabled:button.disabled===true||button.hasAttribute('disabled')||button.getAttribute('aria-disabled')==='true',
          ariaExpanded:['true','false'].includes(button.getAttribute('aria-expanded'))?button.getAttribute('aria-expanded'):null,
          hasShadowRoot:!!button.shadowRoot,shadowButtonCount:button.shadowRoot ? button.shadowRoot.querySelectorAll('button').length : 0,
          shadowButtons:button.shadowRoot ? Array.from(button.shadowRoot.querySelectorAll('button')).slice(0,3).map(el=>({rect:settingsRect(el),disabled:el.disabled===true})) : [],
          slots:button.shadowRoot ? Array.from(button.shadowRoot.querySelectorAll('slot')).slice(0,4).map(slot=>{
            const nodes=slot.assignedNodes({flatten:true});
            return {elements:nodes.filter(node=>node.nodeType===1).map(node=>node.tagName).slice(0,6),textNodes:nodes.filter(node=>node.nodeType===3).length,hasAa:nodes.some(node=>settingsNorm(node.textContent)==='aa')};
          }) : []} : null,
        panelTag:panel ? panel.tagName : null,panelConnected:!!(panel&&panel.isConnected),panelMenuOpen:!!(panel&&panel.classList.contains('show-menu')),
        rangeCount:allRanges.length,ranges:allRanges.slice(0,6).map(el=>({tag:el.tagName,score:crKindleUISemanticScore(el,'font-size'),rect:settingsRect(el),ancestors:settingsAncestors(el)})),
        menus:Array.from(document.querySelectorAll('ion-menu')).slice(0,4).map(settingsMenuSnapshot)
      };
    };
    """

    private static func script(operation: String) -> String {
        """
        (() => {
          \(KindleWebScripts.uiSemanticHelpers)
          const visible = el => {
            const r = el.getBoundingClientRect(), s = getComputedStyle(el);
            return r.width > 2 && r.height > 2 && s.display !== 'none' && s.visibility !== 'hidden';
          };
          \(settingsSelectionHelpers)
          \(nativePanelOwnershipHelpers)
          crFontAdoptOpenedPanel();
          const ranges = Array.from(document.querySelectorAll('input[type="range"],ion-range,[role="slider"]')).filter(visible);
          const ranked = ranges.map(el => ({el, score:crKindleUISemanticScore(el,'font-size')})).sort((a,b)=>b.score-a.score);
          const range = ranked.length && ranked[0].score >= 45 ? ranked[0].el : null;
          const containingPanel = settingsPanelFor(range);
          if (containingPanel) window.__crKindleFontSettingsPanel = containingPanel;
          if (!range) {
            if ('\(operation)' !== 'read') return JSON.stringify({ok:false,reason:'range-not-found'});
            const candidates=settingsCandidates().filter(settingsEligible);
            if(candidates.length!==1) return JSON.stringify({ok:false,reason:candidates.length>1?'ambiguous-settings-button':'settings-unavailable',probe:settingsProbe(null)});
            const button=candidates[0];
            if (!window.__crKindleFontOpenedByNative) {
              window.__crKindleFontSettingsButton = button;
              crFontRememberOpening(button);
              window.__crKindleFontOpenedByNative = true;
              button.click();
              crFontAdoptOpenedPanel();
            }
            return JSON.stringify({ok:false,reason:'opening-settings',probe:settingsProbe(button)});
          }
          const numeric = (attribute, fallback) => {
            const raw = range.getAttribute(attribute) ?? range[attribute];
            return raw !== null && raw !== '' && Number.isFinite(Number(raw)) ? Number(raw) : fallback;
          };
          const nativeInput = range instanceof HTMLInputElement;
          const min = numeric('min', nativeInput ? 0 : NaN), max = numeric('max', nativeInput ? 100 : NaN), step = numeric('step',1);
          const value = Number(range.value ?? range.getAttribute('aria-valuenow'));
          // Diagnostics only: Amazon's storage may lag its live UI. Never use
          // this value to overwrite the reader or as a second settings store.
          let persistedValue = null;
          try {
            const stored = JSON.parse(localStorage.getItem('KWR_Display_Settings') || '{}').fontSizeIndex;
            if (typeof stored === 'number' && Number.isFinite(stored)) persistedValue = stored;
          } catch (_) {}
          if (!Number.isFinite(value) || !Number.isFinite(min) || !Number.isFinite(max) || max <= min || step <= 0 || value < min || value > max) return JSON.stringify({ok:false,reason:'invalid-range'});
          if ('\(operation)' === 'read') return JSON.stringify({ok:true,value,min,max,step,persistedValue,probe:settingsProbe(null)});
          const target = Math.max(min,Math.min(max,min + Math.round((value-min)/step + ('\(operation)' === 'increase' ? 1 : -1))*step));
          if (target === value) return JSON.stringify({ok:true,value,min,max,step,changed:false});
          const labels = {
            increase: ['increase font size','schriftgröße erhöhen','augmenter la taille de la police','aumentar tamaño de fuente','aumentar el tamaño de fuente','aumentar tamanho da fonte','aumenta dimensione carattere','フォントサイズを大きくする','文字サイズを大きくする','增大字号','放大字體','फ़ॉन्ट का आकार बढ़ाएं','फ़ॉन्ट आकार बढ़ाएँ'],
            decrease: ['decrease font size','schriftgröße verringern','réduire la taille de la police','diminuer la taille de la police','disminuir tamaño de fuente','reducir el tamaño de fuente','diminuir tamanho da fonte','diminuisci dimensione carattere','フォントサイズを小さくする','文字サイズを小さくする','减小字号','縮小字體','फ़ॉन्ट का आकार घटाएं','फ़ॉन्ट आकार घटाएँ']
          };
          const normalize = raw => String(raw || '').replace(/\\s+/g,' ').trim().toLowerCase();
          const direction = '\(operation)' === 'increase' ? 'increase' : 'decrease';
          const buttons = Array.from(range.querySelectorAll('button,[role="button"],ion-button,span,[aria-label]')).filter(el =>
            visible(el) && ['aria-label','title','data-testid','data-action'].map(key=>normalize(el.getAttribute(key)))
              .concat([normalize(el.textContent)]).some(label=>labels[direction].includes(label)));
          // Ionic's font step buttons own Kindle's preference commit. Setting
          // ion-range.value and fabricating ionChange can update only the DOM.
          if (buttons.length > 1) return JSON.stringify({ok:false,reason:'ambiguous-font-button'});
          if (buttons.length === 1) {
            const button = buttons[0];
            if (button.disabled === true || button.hasAttribute('disabled') || button.getAttribute('aria-disabled') === 'true')
              return JSON.stringify({ok:false,reason:'font-button-disabled'});
            if(typeof window.__crKindleCancelPendingFontPreferenceCorrection === 'function')
              window.__crKindleCancelPendingFontPreferenceCorrection();
            button.click();
          } else if (range instanceof HTMLInputElement) {
            if(typeof window.__crKindleCancelPendingFontPreferenceCorrection === 'function')
              window.__crKindleCancelPendingFontPreferenceCorrection();
            Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set.call(range,String(target));
            range.dispatchEvent(new Event('input',{bubbles:true}));
            range.dispatchEvent(new Event('change',{bubbles:true}));
          } else return JSON.stringify({ok:false,reason:'font-button-unavailable'});
          return JSON.stringify({ok:true,value:target,min,max,step,changed:true});
        })()
        """
    }
}
