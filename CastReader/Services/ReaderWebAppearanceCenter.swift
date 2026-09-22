import WebKit

/// Use the provider's layout controls to keep its pagination and saved
/// preferences consistent with the text displayed by its reader.
@MainActor
final class ReaderWebAppearanceCenter {
    static let shared = ReaderWebAppearanceCenter()
    private let views = NSMapTable<WKWebView, NSString>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private let readerFrames = NSMapTable<WKWebView, WKFrameInfo>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// Only called after the bridge's exact provider origin/path policy passes.
    /// Google keeps both its page and display-options toolbar cross-origin.
    func registerReaderFrame(_ frame: WKFrameInfo, in webView: WKWebView, installPanelBounds: Bool = false) {
        guard !frame.isMainFrame else { return }
        readerFrames.setObject(frame, forKey: webView)
        if installPanelBounds {
            Task { @MainActor [weak webView] in
                _ = try? await webView?.evaluateJavaScript(Self.constrainGooglePanelsScript, in: frame, contentWorld: .page)
            }
        }
    }

    func resetReaderFrame(in webView: WKWebView) {
        readerFrames.removeObject(forKey: webView)
    }

    #if DEBUG
    /// Uses the same validated cross-origin reader frame as native Aa.
    func inspectLiveAcceptance(_ script: String, in webView: WKWebView) async -> Any? {
        try? await webView.evaluateJavaScript(script, in: readerFrames.object(forKey: webView), contentWorld: .page)
    }
    #endif

    func register(_ webView: WKWebView, documentID: String) {
        views.setObject(documentID as NSString, forKey: webView)
    }

    func open(documentID: String, in window: UIWindow? = nil) async -> Bool {
        let candidates = views.keyEnumerator().allObjects.compactMap { $0 as? WKWebView }.filter {
            views.object(forKey: $0) as String? == documentID && (window == nil || $0.window === window)
        }
        // Ambiguous legacy callers never open another window's settings.
        guard candidates.count == 1, let webView = candidates.first else { return false }
        return await open(webView: webView)
    }

    func openKoboContents(documentID: String, in window: UIWindow?) async -> Bool {
        guard let window else { return false }
        let candidates = views.keyEnumerator().allObjects.compactMap { $0 as? WKWebView }.filter {
            views.object(forKey: $0) as String? == documentID && $0.window === window &&
                $0.url?.host == "readnow.kobo.com"
        }
        guard candidates.count == 1, let webView = candidates.first else { return false }
        _ = try? await webView.evaluateJavaScript(Self.constrainKoboPanelsScript)
        return (try? await webView.evaluateJavaScript(Self.openKoboContentsScript)) as? Bool ?? false
    }

    static let constrainKoboPanelsScript = #"""
    (() => {
      if (location.hostname !== 'readnow.kobo.com') return false;
      if (document.getElementById('castreader-kobo-dialog-bounds')) return true;
      const style = document.createElement('style');
      style.id = 'castreader-kobo-dialog-bounds';
      style.textContent = `
        .PopUp_container[role="dialog"] {
          max-width:calc(100vw - 24px) !important;
          max-height:calc(100dvh - 24px) !important;
          overflow:auto !important;
          overscroll-behavior:contain;
          box-sizing:border-box;
        }
        @media (max-width:500px), (max-height:480px) {
          .PopUp_container[role="dialog"] {
            top:12px !important;
            right:12px !important;
          }
        }
      `;
      document.head.append(style);
      return true;
    })()
    """#

    static let openKoboContentsScript = #"""
    (() => {
      const control = document.querySelector('[aria-label="Open table of contents"]');
      if (!control) return false;
      control.click();
      return true;
    })()
    """#

    func open(webView: WKWebView) async -> Bool {
        let frame = readerFrames.object(forKey: webView)
        _ = try? await webView.evaluateJavaScript(Self.constrainKoboPanelsScript)
        _ = try? await webView.evaluateJavaScript(Self.constrainGooglePanelsScript, in: frame, contentWorld: .page)
        #if DEBUG
        if let snapshot = try? await webView.evaluateJavaScript(Self.presentationProbe, in: frame, contentWorld: .page) {
            ReaderRunLog.write("READER appearance presentation=\(snapshot)")
        }
        #endif
        if webView.url?.host == "weread.qq.com" {
            let opened = (try? await webView.callAsyncJavaScript(
                Self.openWeReadSettingsScript,
                arguments: [
                    "settingsHint": AppLocalized("轻点 Aa，打开微信读书字体设置"),
                    "cancelTitle": AppLocalized("取消"),
                    "settingsTitle": AppLocalized("阅读设置")
                ],
                in: nil, contentWorld: .page
            )) as? Bool ?? false
            #if DEBUG
            if let snapshot = try? await webView.evaluateJavaScript(Self.appearancePanelProbe) {
                ReaderRunLog.write("READER appearance panel=\(snapshot)")
            }
            #endif
            return opened
        }
        if (try? await webView.evaluateJavaScript(Self.openSettingsScript, in: frame, contentWorld: .page)) as? Bool == true {
            #if DEBUG
            try? await Task.sleep(nanoseconds: 350_000_000)
            if let snapshot = try? await webView.evaluateJavaScript(Self.appearancePanelProbe, in: frame, contentWorld: .page) {
                ReaderRunLog.write("READER appearance panel=\(snapshot)")
            }
            #endif
            return true
        }
        // On narrow Google readers, Display options is inside the provider's
        // overflow menu. Open that menu, then delegate to its own settings row.
        guard (try? await webView.evaluateJavaScript(Self.openGoogleOverflowScript, in: frame, contentWorld: .page)) as? Bool == true else { return false }
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return false }
            if (try? await webView.evaluateJavaScript(Self.openSettingsScript, in: frame, contentWorld: .page)) as? Bool == true { return true }
        }
        return false
    }

    /// Diagnostics only: control labels and browser geometry, never cookies,
    /// storage, account fields, document text or URL query parameters.
    static let presentationProbe = #"""
    (() => JSON.stringify({
      platform:navigator.platform, ua:navigator.userAgent,
      initialOS:window.__INITIAL_STATE__?.OS, initialPlatform:window.__INITIAL_STATE__?.platform,
      host:location.hostname, path:location.pathname,
      width:innerWidth, screenWidth:screen.width, touches:navigator.maxTouchPoints,
      rootClass:document.documentElement.className, bodyClass:document.body?.className,
      mobileClass:!!document.querySelector('.wr_mobile,.isMobile'),
      controls:Array.from(document.querySelectorAll('button,[role="button"],[title],[aria-label],[class*="setting" i],[class*="font" i],[class*="footer" i]'))
        .filter(el => {const r=el.getBoundingClientRect();return r.width>2&&r.height>2;})
        .map(el => ({tag:el.tagName,cls:String(el.className).slice(0,100),label:(el.getAttribute('aria-label')||el.getAttribute('title')||el.innerText||'').trim().slice(0,80)}))
        .filter(el => el.label.length<80 && !/@|account|账号|帳戶|账户|sign.?in|log.?in/i.test(el.label)).slice(-40)
    }))()
    """#

    static let openWeReadSettingsScript = #"""
    const trigger = document.querySelector('button.readerControls_item.fontSizeButton');
    if (!trigger) return false;
    if (window.__crWeReadAppearance) return true;
    const panel = () => document.querySelector('.reader-font-control-panel-wrapper .font-panel-content');
    const isOpen = () => {
      const el = panel();
      if (!el) return false;
      const r = el.getBoundingClientRect(), s = getComputedStyle(el);
      return r.width > 20 && r.height > 20 && s.display !== 'none' && s.visibility !== 'hidden';
    };
    // WeRead's native toolbar checks event.isTrusted. Do not synthesize that
    // event or bypass its handler: expose the original button for a real tap.
    // Keep the same DOM node/listener and restore its exact position afterward.
    // Compact WeRead uses a 1.19x canvas cropped by its native container.
    // Keep the panel inside that actual visible width, recomputing on resize.
    const currentWidth = () => Math.min(440, innerWidth/1.19-32, screen.width-32);
    let width = currentWidth();
    const setStyles = (el, values) => {
      for (const [key,value] of Object.entries(values)) el.style.setProperty(key, value, 'important');
    };
    const placeholder = document.createComment('castreader-native-aa');
    trigger.before(placeholder);
    const oldTriggerStyle = trigger.getAttribute('style');
    const oldTriggerLabel = trigger.getAttribute('aria-label');
    trigger.setAttribute('aria-label', settingsTitle);
    const card = document.createElement('div');
    card.id = 'castreader-weread-aa';
    // Retain the provider's ancestor-dependent icon styles after reparenting.
    card.className = 'readerControls';
    setStyles(card, {position:'fixed',left:((innerWidth-width)/2)+'px',right:'auto',top:'16px',bottom:'auto',margin:'0',transform:'none',width:width+'px',padding:'12px','box-sizing':'border-box',display:'flex','flex-direction':'row','align-items':'center',gap:'12px','z-index':'2147483646',background:'Canvas',color:'CanvasText','border-radius':'14px','box-shadow':'0 3px 20px #0003','font-size':'16px'});
    const hint = document.createElement('span');
    hint.textContent = settingsHint;
    hint.style.flex = '1';
    const close = document.createElement('button');
    close.textContent = cancelTitle;
    setStyles(close, {'min-width':'44px','min-height':'44px','flex-shrink':'0'});
    card.append(trigger, hint, close);
    setStyles(trigger, {position:'static',transform:'none',margin:'0',width:'48px',height:'48px','flex-shrink':'0'});
    document.body.append(card);
    let opened = false, stopped = false, panelStyles;
    const restore = () => {
      if (stopped) return;
      stopped = true;
      observer.disconnect();
      clearInterval(poll);
      if (placeholder.isConnected) placeholder.replaceWith(trigger);
      if (oldTriggerStyle === null) trigger.removeAttribute('style'); else trigger.setAttribute('style', oldTriggerStyle);
      if (oldTriggerLabel === null) trigger.removeAttribute('aria-label'); else trigger.setAttribute('aria-label', oldTriggerLabel);
      if (panelStyles && panel()) {
        for (const [key,value,priority] of panelStyles) {
          if (value) panel().style.setProperty(key,value,priority); else panel().style.removeProperty(key);
        }
      }
      card.remove();
      delete window.__crWeReadAppearance;
    };
    const update = () => {
      if (stopped) return;
      if (!trigger.isConnected) { restore(); return; }
      width = currentWidth();
      if (!opened) setStyles(card, {left:((innerWidth-width)/2)+'px',width:width+'px'});
      if (isOpen()) {
        const el = panel();
        if (!opened) {
          opened = true;
          panelStyles = ['position','left','right','top','bottom','width','max-height','overflow-y','transform','z-index','box-sizing'].map(key => [key,el.style.getPropertyValue(key),el.style.getPropertyPriority(key)]);
          card.style.setProperty('display','none','important');
        }
        // Only move the provider's floating panel, never its chapter canvas.
        setStyles(el, {position:'fixed',left:((innerWidth-width)/2)+'px',right:'auto',top:'16px',bottom:'auto',width:width+'px','box-sizing':'border-box','max-height':Math.max(44,innerHeight-32)+'px','overflow-y':'auto',transform:'none','z-index':'2147483647'});
      } else if (opened) restore();
    };
    const observer = new MutationObserver(() => {
      // Avoid observing our own style writes indefinitely.
      observer.disconnect(); update();
      if (!stopped) observer.observe(document.body, {subtree:true,attributes:true,attributeFilter:['style','class']});
    });
    const poll = setInterval(update, 400);
    close.onclick = restore;
    window.__crWeReadAppearance = {close:restore};
    observer.observe(document.body, {subtree:true,attributes:true,attributeFilter:['style','class']});
    update();
    return true;
    """#

    static let appearancePanelProbe = #"""
    (() => JSON.stringify(Array.from(document.querySelectorAll('.reader-font-control-panel-wrapper,.font-panel-content,.readerControls_item.fontSizeButton,.cdk-overlay-pane,[role=dialog],[class*=settings-panel],[class*=display-options]'))
      .map(el => { const r=el.getBoundingClientRect(),s=getComputedStyle(el); return {cls:el.className,x:r.x,y:r.y,w:r.width,h:r.height,display:s.display,visibility:s.visibility,opacity:s.opacity,position:s.position}; })))()
    """#

    static let openSettingsScript = #"""
    (() => {
      const roots = [document], controls = [], visited = new Set();
      while (roots.length) {
        const root = roots.shift();
        if (!root || visited.has(root)) continue;
        visited.add(root);
        for (const el of root.querySelectorAll('*')) {
          if (el.shadowRoot) roots.push(el.shadowRoot);
          if (el.tagName === 'IFRAME') { try { if (el.contentDocument) roots.push(el.contentDocument); } catch (_) {} }
          if (!el.matches('button,[role="button"],[role="menuitem"],ion-button,[data-testid],[title],[aria-label]')) continue;
          const r = el.getBoundingClientRect(), style = getComputedStyle(el);
          if (r.width < 2 || r.height < 2 || style.display === 'none' || style.visibility === 'hidden') continue;
          const text = [el.getAttribute('aria-label'), el.getAttribute('title'), el.getAttribute('data-testid'), el.id, el.textContent].filter(Boolean).join(' ').replace(/\s+/g, ' ').trim();
          if (text.length > 200) continue;
          if (/increase|decrease|larger|smaller|font.size|字号|行高/i.test(text)) continue;
          let score = /^(aa|aа)$/i.test((el.textContent || '').trim()) ? 100 : 0;
          if (/font|typograph|reading.settings|display.settings|display.options|appearance|字体|字體|阅读设置|閱讀設定|閱讀設置|显示设置|顯示設定|显示选项|顯示選項|フォント|schrift|police|fuente|fonte|lettertype/i.test(text)) score += 50;
          if (score) controls.push({ el, score });
        }
      }
      controls.sort((a,b) => b.score-a.score);
      if (!controls.length) return false;
      controls[0].el.click();
      return true;
    })()
    """#

    /// Google's native CDK display dialog can exceed the shorter iPad viewport.
    /// Constrain only floating dialogs; preserve the provider's pagination CSS.
    static let constrainGooglePanelsScript = #"""
    (() => {
      if (location.hostname !== 'books.googleusercontent.com') return false;
      if (document.getElementById('castreader-google-dialog-bounds')) return true;
      const style = document.createElement('style');
      style.id = 'castreader-google-dialog-bounds';
      style.textContent = `
        .cdk-overlay-pane.-gb-titled-dialog {
          max-height:calc(100dvh - 80px) !important;
          max-width:calc(100vw - 32px) !important;
        }
        .cdk-overlay-pane.-gb-titled-dialog .mat-mdc-dialog-container,
        .cdk-overlay-pane.-gb-titled-dialog .mdc-dialog__container {
          max-height:inherit !important;
        }
        .cdk-overlay-pane.-gb-titled-dialog .mdc-dialog__surface {
          max-height:calc(100dvh - 80px) !important;
          overflow-y:auto !important;
          overscroll-behavior:contain;
        }
        @media (max-height:480px) {
          .cdk-overlay-pane.-gb-titled-dialog,
          .cdk-overlay-pane.-gb-titled-dialog .mdc-dialog__surface {
            max-height:calc(100dvh - 24px) !important;
          }
        }
      `;
      document.head.appendChild(style);
      return true;
    })()
    """#

    static let openGoogleOverflowScript = #"""
    (() => {
      if (location.hostname !== 'books.googleusercontent.com' && location.hostname !== 'play.google.com') return false;
      const controls = Array.from(document.querySelectorAll('button,[role="button"]'));
      const more = controls.find(el => {
        const r = el.getBoundingClientRect(), s = getComputedStyle(el);
        if (r.width < 2 || r.height < 2 || s.display === 'none' || s.visibility === 'hidden') return false;
        const label = (el.getAttribute('aria-label') || el.getAttribute('title') || el.textContent || '').trim();
        return /^(more|more options|more settings|更多|更多选项|更多選項|其他选项|其他選項|その他|weitere optionen|más opciones|mais opções|altre opzioni)$/i.test(label);
      });
      if (!more) return false;
      more.click();
      return true;
    })()
    """#
}
