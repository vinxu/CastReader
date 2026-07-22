//
//  WeReadWebScripts.swift
//  CastReader
//
//  This is intentionally a live-render bridge, not an API client.  WeRead
//  frequently paints its authenticated chapter DOM into Canvas and removes the
//  DOM afterwards.  We capture that transient layout at document-start and use
//  it only for the page currently visible in the user's signed-in WebView.
//

import Foundation

enum WeReadWebScripts {
    static let homeURL = URL(string: "https://weread.qq.com/")!
    static let shelfURL = URL(string: "https://weread.qq.com/web/shelf")!

    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36"

    static let libraryScan = #"""
    (() => {
      const absolute = (u) => { try { return new URL(u, location.href).href; } catch (_) { return ''; } };
      const clean = (v) => String(v || '').replace(/\s+/g, ' ').trim();
      const visible = (el) => {
        if (!el) return false;
        const style = getComputedStyle(el), rect = el.getBoundingClientRect();
        return style.display !== 'none' && style.visibility !== 'hidden' && rect.width > 0 && rect.height > 0;
      };
      const readerURL = (href) => /weread\.qq\.com/.test(href) && /(?:web\/)?reader/.test(href);
      const seen = new Set(); const books = [];
      for (const link of Array.from(document.querySelectorAll('a[href]'))) {
        const url = absolute(link.getAttribute('href'));
        if (!readerURL(url)) continue;
        const card = link.closest('li,article,[class*=book],[class*=shelf],[class*=Book]') || link.parentElement || link;
        // The desktop shelf is a Vue 2 component.  Its rendered DOM exposes
        // title and cover, while author remains in the component's `book`
        // prop.  Read that already-rendered client state first; this does not
        // call or persist any WeRead private API response.
        const vueNode = [link, card, ...Array.from(card.querySelectorAll('*'))]
          .find(el => el && el.__vue__ && (el.__vue__.book || el.__vue__.$props?.book));
        const bookData = vueNode ? (vueNode.__vue__.book || vueNode.__vue__.$props?.book || {}) : {};
        const image = card.querySelector('img') || link.querySelector('img');
        const texts = Array.from(card.querySelectorAll('h1,h2,h3,h4,p,span,div')).map(e => clean(e.innerText)).filter(t => t && t.length <= 140);
        const titleNode = card.querySelector(':scope > .title,.title,[class*=bookTitle],[class*=bookName]');
        const imageAlt = clean(image && image.getAttribute('alt'));
        const usableImageAlt = /^(书籍封面|图书封面|封面|book\s*cover|cover)$/i.test(imageAlt) ? '' : imageAlt;
        const title = clean(bookData.title) || clean(titleNode && (titleNode.getAttribute('title') || titleNode.innerText)) ||
          clean(link.getAttribute('title')) || usableImageAlt || texts.find(t => t.length > 1 && t.length < 80) || clean(link.innerText);
        if (!title || /^(登录|书架|微信读书|下一页|上一页|书籍封面|图书封面|封面|book\s*cover|cover)$/i.test(title)) continue;
        const match = url.match(/(?:bookId|bookId=|reader\/)([A-Za-z0-9_-]+)/i);
        const bookId = clean(bookData.bookId) || (match ? match[1] : '');
        const id = bookId || url;
        if (seen.has(id)) continue; seen.add(id);
        const authorNode = card.querySelector('[class*=author],[class*=Author]');
        const author = clean(bookData.author) || clean(authorNode && authorNode.innerText) || '';
        const rawProgress = bookData.readingProgress ?? bookData.progress ?? bookData.progressLabel;
        const progress = clean(rawProgress) || texts.find(t => /%|进度|读到|阅读/.test(t)) || '';
        const cover = clean(bookData.cover) || clean(bookData.coverURL) || clean(image && (image.currentSrc || image.getAttribute('src')));
        books.push({ id, bookId, title, author, coverURL: absolute(cover), readerURL: url, progressLabel: progress });
      }
      const accountNode = document.querySelector('[class*=avatar] img,[class*=userName],[class*=nickname]');
      const account = clean(accountNode && (accountNode.alt || accountNode.innerText));
      const loginVisible = Array.from(document.querySelectorAll('a,button,[role=button]'))
        .some(el => visible(el) && /^(登录|扫码登录|Log\s*in|Sign\s*in)$/i.test(clean(el.innerText || el.textContent)));
      // Anonymous WeRead sessions only carry wr_gid.  A signed-in desktop
      // session carries wr_vid/wr_skey (or exposes the account avatar).
      const hasSessionCookie = /(?:^|;\s*)(?:wr_vid|wr_skey)=/.test(document.cookie || '');
      const authenticated = !loginVisible && (Boolean(accountNode) || hasSessionCookie || books.length > 0);
      return { url: location.href, title: document.title, authRequired: !authenticated, authenticated, books, account: account || null };
    })()
    """#

    /// JS bridge derived from the extension's `weread-hook` contract:
    /// - observe transient `.preRenderContainer` before Canvas destroys it;
    /// - retain exact text/style/rects for the visible page;
    /// - never call chapter/private APIs or decrypt responses;
    /// - next page is a single exact `下一页` semantic click.
    private static let legacyReaderBridge = #"""
    (() => {
      if (window.__castReaderWeReadBridge) return;
      window.__castReaderWeReadBridge = true;
      const post = (type, payload = {}) => { try { window.webkit?.messageHandlers?.castreader?.postMessage({type, payload}); } catch (_) {} };
      const clean = (s) => String(s || '').replace(/\s+/g, ' ').trim();
      const layoutProps = ['font-family','font-size','font-weight','font-style','font-kerning','font-feature-settings','letter-spacing','word-spacing','line-height','text-indent','text-align','word-break','overflow-wrap','white-space','text-transform','direction','writing-mode'];
      let captured = [], lastFingerprint = '', captureTimer = 0, renderTimer = 0, turnID = 0, canvasEpoch = 0;
      const sourceSelectors = '.preRenderContainer,.wr_preRenderContainer,.renderTargetContainer,.readerChapterContent,.wr_readerContent,[class*=preRender],[class*=readerContent],[class*=ReaderContent]';
      const pageRoot = () => document.querySelector('.wr_canvasContainer,[class*=canvasContainer],[class*=readerContent]') || document.body;
      const fingerprint = (items) => {
        const first = items[0]?.text || '', last = items[items.length - 1]?.text || '';
        const progress = clean(Array.from(document.querySelectorAll('[class*=progress],[class*=Progress],[class*=readerFooter]')).map(e => e.innerText).join(' ')).slice(0, 120);
        let raw = `${first}|${last}|${progress}|${location.href}`.toLowerCase(); let h = 2166136261;
        for (let i = 0; i < raw.length; i++) { h ^= raw.charCodeAt(i); h = Math.imul(h, 16777619); }
        return { value: (h >>> 0).toString(16), progress };
      };
      const collect = (root) => {
        // The extension found that scroll mode can retain an additional
        // character-remapped pre-render container.  It is not useful text and
        // must never be sent to TTS.  Restrict the heuristic to predominantly
        // Han text so Japanese, Hindi and Latin-script books cannot be
        // mistaken for that Chinese-only anti-piracy representation.
        const safetyClone = root.cloneNode(true);
        safetyClone.querySelectorAll?.('style,script,noscript').forEach(e => e.remove());
        const safetyText = clean(safetyClone.textContent).slice(0, 500);
        const han = (safetyText.match(/[\u4e00-\u9fff]/g) || []).length;
        if (safetyText.length >= 100 && han / safetyText.length >= 0.45) {
          const common = '的一是不了人我在有他这为之大来以个中上们到说时要就出会也你对';
          let commonCount = 0; for (const ch of safetyText) if (common.includes(ch)) commonCount++;
          if (commonCount / safetyText.length < 0.03) return [];
        }
        const content = root.querySelector?.('#preRenderContent') || root;
        const container = pageRoot(), cRect = container.getBoundingClientRect();
        const blocks = Array.from(content.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li,blockquote')).filter(e => clean(e.textContent).length >= 2);
        const candidates = blocks.length ? blocks : Array.from(content.children).filter(e => clean(e.textContent).length >= 8);
        const seen = new Set();
        return candidates.map(el => {
          const text = clean(el.textContent); if (!text || seen.has(text.slice(0, 80))) return null; seen.add(text.slice(0, 80));
          const r = el.getBoundingClientRect(), cs = getComputedStyle(el);
          const style = layoutProps.map(p => `${p}:${cs.getPropertyValue(p)}`).join(';');
          return { text, top: r.top - cRect.top, left: r.left - cRect.left, width: r.width, height: r.height, style };
        }).filter(Boolean);
      };
      const rebuildLayer = (items) => {
        document.querySelectorAll('[data-castreader-weread-layer]').forEach(e => e.remove());
        const host = pageRoot(); if (!host || !items.length) return;
        const hr = host.getBoundingClientRect();
        if (getComputedStyle(host).position === 'static') host.style.position = 'relative';
        const layer = document.createElement('div'); layer.dataset.castreaderWereadLayer = '1';
        layer.style.cssText = 'position:absolute;inset:0;z-index:2147483000;pointer-events:none;overflow:hidden;'; host.appendChild(layer);
        items.forEach((p, i) => {
          const el = document.createElement('div'); el.dataset.crWereadPara = String(i); el.textContent = p.text;
          const top = Number.isFinite(p.top) ? p.top : 0, left = Number.isFinite(p.left) ? p.left : 0;
          const width = Math.max(1, p.width || hr.width), height = Math.max(1, p.height || 24);
          el.style.cssText = `position:absolute;left:${left}px;top:${top}px;width:${width}px;min-height:${height}px;box-sizing:border-box;color:transparent;background:transparent;pointer-events:none;${p.style || ''}`;
          layer.appendChild(el); p.el = el;
        });
      };
      const publish = (reason) => {
        if (captured.length < 1) return;
        rebuildLayer(captured); const fp = fingerprint(captured);
        if (fp.value === lastFingerprint && reason !== 'initial') return;
        const previous = lastFingerprint; lastFingerprint = fp.value;
        post('wereadPage', { reason, previousFingerprint: previous, fingerprint: fp.value, progressLabel: fp.progress, readerURL: location.href, title: clean(document.title), paragraphs: captured.map(p => ({text:p.text})) });
      };
      const capture = (node, reason = 'dom') => {
        if (!(node instanceof Element)) return;
        const cls = `${node.className || ''}`;
        // WeRead often appends the pre-render container first and then adds
        // each paragraph separately.  In that sequence the added `<p>` must
        // cause its already-mounted pre-render parent to be captured; waiting
        // only for another container insertion loses the page before Canvas
        // clears it.
        const source = node.matches?.(sourceSelectors) ? node : node.closest?.(sourceSelectors);
        const root = source || node;
        if (!source && !node.querySelector?.('p,h1,h2,h3,li,blockquote') && !/preRender|readerContent/i.test(cls)) return;
        const next = collect(root); if (!next.length) return;
        captured = next;
        clearTimeout(captureTimer); captureTimer = setTimeout(() => publish(reason), 80);
      };
      const observer = new MutationObserver(records => {
        for (const r of records) {
          const target = r.target.nodeType === Node.ELEMENT_NODE ? r.target : r.target.parentElement;
          const source = target?.matches?.(sourceSelectors) ? target : target?.closest?.(sourceSelectors);
          if (source) capture(source);
          for (const n of r.addedNodes) {
            if (n.nodeType === Node.ELEMENT_NODE) { capture(n); for (const e of n.querySelectorAll?.(sourceSelectors) || []) capture(e); }
          }
        }
      });
      const begin = () => {
        observer.observe(document.documentElement, {childList:true, characterData:true, subtree:true});
        const scan = (reason = 'initial') => document.querySelectorAll(sourceSelectors).forEach(e => capture(e, reason));
        scan('initial');
        // WeRead can create the reusable pre-render container after document
        // load; repeat scans mirror the extension's capture fallback without
        // issuing any network or page-navigation action.
        setTimeout(() => scan('scan'), 1000);
        setTimeout(() => scan('scan'), 2500);
        setTimeout(() => scan('scan'), 5000);
        // DOM-mode books do not use a pre-render container.
        setTimeout(() => { if (!captured.length) { const root = pageRoot(); const next = collect(root); if (next.length) { captured = next; publish('initial'); } } }, 900);
      };
      const origClear = CanvasRenderingContext2D.prototype.clearRect;
      CanvasRenderingContext2D.prototype.clearRect = function(...args) { const out = origClear.apply(this,args); canvasEpoch++; clearTimeout(renderTimer); renderTimer = setTimeout(() => { if (captured.length) publish('canvas'); }, 180); return out; };
      const charRange = (el, start, end) => { const w = document.createTreeWalker(el, NodeFilter.SHOW_TEXT); let pos=0, a=null,b=null,n; while((n=w.nextNode())) { const next=pos+n.nodeValue.length; if(!a && start>=pos && start<=next) a={n,o:start-pos}; if(end>=pos && end<=next){b={n,o:end-pos};break;} pos=next;} if(!a||!b)return null; const r=document.createRange();r.setStart(a.n,Math.max(0,a.o));r.setEnd(b.n,Math.max(0,b.o));return r; };
      const clearHighlight = () => document.querySelectorAll('[data-cr-weread-highlight]').forEach(e => e.remove());
      const paint = (range) => { clearHighlight(); for(const r of Array.from(range.getClientRects())) { if(r.width<1||r.height<1)continue; const d=document.createElement('div');d.dataset.crWereadHighlight='1';d.style.cssText=`position:fixed;left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px;border-radius:3px;background:rgba(253,95,1,.34);pointer-events:none;z-index:2147483646;`;document.body.appendChild(d);} };
      let wordPara=-1, wordCursor=0;
      window.CR = {
        init() {}, setActive(a) { if (!a.active) clearHighlight(); }, setColor() {}, clearHighlight,
        highlightRange(a) { const el=captured[a.paragraphIndex]?.el; const r=el&&charRange(el,a.charStart,a.charEnd); if(r)paint(r); else clearHighlight(); },
        highlightWord(a) { const el=captured[a.paragraphIndex]?.el; if(!el){clearHighlight();return;} if(wordPara!==a.paragraphIndex){wordPara=a.paragraphIndex;wordCursor=0;} const text=el.textContent||''; const word=(a.words||[])[a.wordIndex]||''; const at=text.indexOf(word,wordCursor); if(at>=0){wordCursor=at+word.length;const r=charRange(el,at,at+word.length);if(r)paint(r);} },
        scrollTo() {}, clearMarks() {}, showMark() {}
      };
      window.CastReaderWeRead = { nextPage() {
        const candidate = Array.from(document.querySelectorAll('button,a,[role=button],div')).find(e => clean(e.textContent) === '下一页');
        if (!candidate) { post('wereadTurnRejected',{reason:'next-page-not-found'}); return false; }
        const id = `wr-${Date.now()}-${++turnID}`; post('wereadTurnRequested',{actionID:id,fingerprint:lastFingerprint,canvasEpoch}); candidate.click(); return true;
      }, snapshot() { publish('manual'); } };
      if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', begin, {once:true}); else begin();
      post('ready',{site:'weread',bridge:'canvas-live-v1'});
    })();
    """#

    /// Must run in WKContentWorld.page at document-start.  The visible reader
    /// is Canvas pixels, so this is the authoritative geometry/page-evidence
    /// source; DOM capture below supplies text and semantic structure.
    static let canvasIntercept = #"""
    (() => {
      if (window.__castReaderWeReadCanvas) return;
      const fill = CanvasRenderingContext2D.prototype.fillText;
      const clear = CanvasRenderingContext2D.prototype.clearRect;
      const draw = CanvasRenderingContext2D.prototype.drawImage;
      const calls = [], generations = new WeakMap(), latestDraw = new Map();
      let epoch = 0, timer = 0, columnFingerprint = '';
      const host = () => document.querySelector('.wr_canvasContainer,[class*=canvasContainer]');
      const indexOf = c => { const h=host(); return h ? Array.from(h.querySelectorAll('canvas')).indexOf(c) : -1; };
      const signal = reason => { clearTimeout(timer); timer=setTimeout(()=>window.dispatchEvent(new CustomEvent('castreader-weread-canvas',{detail:{reason,epoch}})),180); };
      CanvasRenderingContext2D.prototype.clearRect = function(x,y,w,h) {
        const i=indexOf(this.canvas), area=Math.max(1,this.canvas.width*this.canvas.height),t=typeof this.getTransform==='function'?this.getTransform():null,effectiveArea=Math.abs(w*h*(t?.a||1)*(t?.d||1));
        if(i>=0 && effectiveArea>=area*.45){generations.set(this.canvas,(generations.get(this.canvas)||0)+1);epoch++;signal('clearRect');}
        return clear.call(this,x,y,w,h);
      };
      CanvasRenderingContext2D.prototype.fillText = function(text,x,y,maxWidth) {
        try {
          const value=String(text||''), i=indexOf(this.canvas);
          if(i>=0 && value.trim()){
            const t=this.getTransform(), m=String(this.font||'').match(/(\d+(?:\.\d+)?)\s*px/),metrics=this.measureText(value);
            const metric=name=>{const n=Number(metrics?.[name]);return Number.isFinite(n)?n:0;};
            calls.push({canvas:this.canvas,text:value,x:+x||0,y:+y||0,width:metrics.width||0,a:t.a||1,d:t.d||1,tx:t.e||0,ty:t.f||0,generation:generations.get(this.canvas)||0,fontSize:m?+m[1]:0,textBaseline:String(this.textBaseline||'alphabetic'),actualAscent:metric('actualBoundingBoxAscent'),actualDescent:metric('actualBoundingBoxDescent'),fontAscent:metric('fontBoundingBoxAscent'),fontDescent:metric('fontBoundingBoxDescent')});
            if(calls.length>60000)calls.splice(0,20000);signal('fillText');
          }
        } catch(_) {}
        return maxWidth===undefined?fill.call(this,text,x,y):fill.call(this,text,x,y,maxWidth);
      };
      CanvasRenderingContext2D.prototype.drawImage = function(...args) {
        try {
          const source=args[0], i=indexOf(this.canvas);
          if(i>=0 && source instanceof HTMLCanvasElement && source.width>200 && source.height>200){
            let sx=0,sy=0,sw=source.width,sh=source.height,dx=0,dy=0,dw=this.canvas.width,dh=this.canvas.height;
            if(args.length>=9){sx=+args[1]||0;sy=+args[2]||0;sw=+args[3]||source.width;sh=+args[4]||source.height;dx=+args[5]||0;dy=+args[6]||0;dw=+args[7]||this.canvas.width;dh=+args[8]||this.canvas.height;}
            else if(args.length>=5){dx=+args[1]||0;dy=+args[2]||0;dw=+args[3]||source.width;dh=+args[4]||source.height;}
            latestDraw.set(this.canvas,{canvas:this.canvas,sourceWidth:source.width,sourceHeight:source.height,sx,sy,sw,sh,dx,dy,dw,dh});
            const fp=Array.from(latestDraw.values()).filter(v=>v.canvas.isConnected).sort((a,b)=>indexOf(a.canvas)-indexOf(b.canvas)).map(v=>`${indexOf(v.canvas)}:${Math.round(v.sx)}:${Math.round(v.sy)}`).join('|');
            if(columnFingerprint && fp && fp!==columnFingerprint)epoch++;columnFingerprint=fp;signal('drawImage');
          }
        } catch(_) {}
        return draw.apply(this,args);
      };
      window.__castReaderWeReadCanvas={snapshot(){
        const live=calls.filter(c=>c.canvas?.isConnected), max=new Map();
        for(const c of live)max.set(c.canvas,Math.max(max.get(c.canvas)||0,c.generation));
        return{epoch,columnFingerprint,calls:live.filter(c=>c.generation===(max.get(c.canvas)||0)),draws:Array.from(latestDraw.values()).filter(v=>v.canvas?.isConnected)};
      }};
    })();
    """#

    /// Production WeRead bridge.  Text comes from the transient HTML layout;
    /// exact visible rectangles come from the Canvas interceptor above.
    static let readerBridge = #"""
    (() => {
      if(window.__castReaderWeReadBridgeV2)return;window.__castReaderWeReadBridgeV2=true;
      const post=(type,payload={})=>{try{window.webkit?.messageHandlers?.castreader?.postMessage({type,payload});}catch(_){}};
      const clean=s=>String(s||'').replace(/\s+/g,' ').trim();
      const hash=s=>{let h=2166136261,v=String(s||'').toLowerCase();for(let i=0;i<v.length;i++){h^=v.charCodeAt(i);h=Math.imul(h,16777619);}return(h>>>0).toString(16);};
      const cssProps=['font-family','font-size','font-weight','font-style','font-kerning','font-feature-settings','letter-spacing','word-spacing','line-height','text-indent','text-align','word-break','overflow-wrap','white-space','text-transform','direction','writing-mode'];
      const selectors='.preRenderContainer,.wr_preRenderContainer,.renderTargetContainer,.readerChapterContent,.wr_readerContent,[class*=preRender],[class*=readerContent],[class*=ReaderContent]';
      let layouts=[],visible=[],layer=null,lastFingerprint='',lastPreviewKey='',lastExtractionState='',timer=0,stableTimer=0,stableCandidate='',turnID=0,color='#FD5F01',wordState={para:-1,seg:-1,cursor:0,last:-1},currentHighlight=null,currentMarks=new Map();
      const root=()=>document.querySelector('.wr_canvasContainer,[class*=canvasContainer]')||document.querySelector('.wr_readerContent,[class*=readerContent]')||document.body;
      const points=text=>{const a=[];for(let i=0;i<text.length;){const cp=text.codePointAt(i),ch=String.fromCodePoint(cp);a.push({ch,start:i,end:i+ch.length});i+=ch.length;}return a;};
      const compact=text=>points(text).filter(v=>!(/\s/u.test(v.ch)));
      function surface(host){const hr=host.getBoundingClientRect();let left=Math.max(0,-hr.left),top=Math.max(0,-hr.top),right=Math.min(hr.width,innerWidth-hr.left),bottom=Math.min(hr.height,innerHeight-hr.top);const target=host.closest('.renderTargetContainer')||host.parentElement,tr=target?.getBoundingClientRect?.();if(tr){left=Math.max(left,tr.left-hr.left);top=Math.max(top,tr.top-hr.top);right=Math.min(right,tr.right-hr.left);bottom=Math.min(bottom,tr.bottom-hr.top);}const pager=target?.querySelector?.('.renderTarget_pager'),pr=pager?.getBoundingClientRect?.();if(pr&&pr.width>1&&pr.height>1&&pr.top>hr.top&&pr.top<hr.bottom)bottom=Math.min(bottom,pr.top-hr.top);return{left:Math.max(0,left),top:Math.max(0,top),right:Math.max(0,right),bottom:Math.max(0,bottom)};}
      function clipBox(b,s){const x=Math.max(b.x,s.left),y=Math.max(b.y,s.top),r=Math.min(b.x+b.width,s.right),d=Math.min(b.y+b.height,s.bottom),cx=b.x+b.width*.5,cy=b.y+b.height*.5;if(cx<s.left||cx>s.right||cy<s.top||cy>s.bottom||r-x<.3||d-y<.3)return null;return{x,y,width:r-x,height:d-y};}

      function measureParagraph(el,rootRect){
        const walker=document.createTreeWalker(el,NodeFilter.SHOW_TEXT,{acceptNode(node){const parent=node.parentElement;if(!node.nodeValue||parent?.closest?.('style,script,noscript,.reader_footer_note,.js_readerFooterNote,[data-wr-footernote]'))return NodeFilter.FILTER_REJECT;return NodeFilter.FILTER_ACCEPT;}}),chars=[];let text='',node;
        while((node=walker.nextNode()))for(const unit of points(node.nodeValue||'')){if(/\s/u.test(unit.ch)){if(text&&text[text.length-1]!==' ')text+=' ';continue;}const start=text.length;text+=unit.ch;try{const r=document.createRange();r.setStart(node,unit.start);r.setEnd(node,unit.end);const rect=Array.from(r.getClientRects()).find(v=>v.width>.1&&v.height>.1);if(rect)chars.push({charStart:start,charEnd:text.length,left:rect.left-rootRect.left,top:rect.top-rootRect.top,width:rect.width,height:rect.height});}catch(_){}}
        text=text.trim();return{text,chars:chars.filter(c=>c.charStart<text.length)};
      }

      function collect(node){
        if(!node||node.closest?.('[data-castreader-weread-layer]'))return null;
        const clone=node.cloneNode(true);clone.querySelectorAll?.('style,script,noscript,[data-castreader-weread-layer]').forEach(e=>e.remove());
        const sample=clean(clone.textContent).slice(0,600),han=(sample.match(/[\u4e00-\u9fff]/g)||[]).length;
        if(sample.length>=100&&han/sample.length>=.45){const common='的一是不了人我在有他这为之大来以个中上们到说时要就出会也你对';let n=0;for(const ch of sample)if(common.includes(ch))n++;if(n/sample.length<.03)return null;}
        const content=node.querySelector?.('#preRenderContent')||node,rr=content.getBoundingClientRect();
        const blocks=Array.from(content.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li,blockquote')).filter(e=>clean(e.textContent).length>=2);
        const candidates=blocks.length?blocks:Array.from(content.children||[]).filter(e=>clean(e.textContent).length>=8),seen=new Set(),paragraphs=[];
        for(const el of candidates){const measured=measureParagraph(el,rr),text=measured.text;if(!text||seen.has(text.slice(0,100)))continue;seen.add(text.slice(0,100));const r=el.getBoundingClientRect(),cs=getComputedStyle(el);paragraphs.push({text,left:r.left-rr.left,top:r.top-rr.top,width:r.width,height:r.height,chars:measured.chars,style:cssProps.map(p=>`${p}:${cs.getPropertyValue(p)}`).join(';')});}
        const layoutWidth=Math.max(rr.width,content.scrollWidth||0),layoutHeight=Math.max(rr.height,content.scrollHeight||0);
        if(!paragraphs.length||layoutWidth<20||layoutHeight<20)return null;
        return{at:Date.now(),width:layoutWidth,height:layoutHeight,paragraphs,fingerprint:hash(paragraphs.map(p=>p.text).join('|'))};
      }
      function remember(layout){if(!layout)return;const i=layouts.findIndex(v=>v.fingerprint===layout.fingerprint);if(i>=0)layouts.splice(i,1);layouts.push(layout);if(layouts.length>8)layouts.shift();schedule('dom');}
      function capture(node){if(!(node instanceof Element)||node.closest?.('[data-castreader-weread-layer]'))return;const source=node.matches?.(selectors)?node:node.closest?.(selectors);if(source)remember(collect(source));for(const e of node.querySelectorAll?.(selectors)||[])remember(collect(e));}

      function textMetricBox(c,baseline,signedScaleY,fallbackFontSize){
        const dir=signedScaleY<0?-1:1,scale=Math.abs(signedScaleY);
        const box=(ascent,descent,source)=>{const y1=baseline-ascent*scale*dir,y2=baseline+descent*scale*dir;return{y:Math.min(y1,y2),height:Math.max(1,Math.abs(y2-y1)),source};};
        const aa=Number(c?.actualAscent),ad=Number(c?.actualDescent);
        if(Number.isFinite(aa)&&Number.isFinite(ad)&&aa>=0&&ad>=0&&aa+ad>.5)return box(aa,ad,'actual');
        const fa=Number(c?.fontAscent),fd=Number(c?.fontDescent);
        if(Number.isFinite(fa)&&Number.isFinite(fd)&&fa>=0&&fd>=0&&fa+fd>.5)return box(fa,fd,'font');
        let ar=.8,dr=.2;switch(String(c?.textBaseline||'alphabetic')){case'top':ar=0;dr=1;break;case'hanging':ar=.2;dr=.8;break;case'middle':ar=.5;dr=.5;break;case'ideographic':ar=.9;dr=.1;break;case'bottom':ar=1;dr=0;break;}
        return box(ar*fallbackFontSize/Math.max(scale,.0001),dr*fallbackFontSize/Math.max(scale,.0001),'fallback');
      }
      function glyphs(snapshot,host){
        const hr=host.getBoundingClientRect(),pageSurface=surface(host),groups=new Map();
        for(const c of snapshot.calls||[]){const canvas=c.canvas;if(!canvas?.isConnected||canvas.width<1||canvas.height<1)continue;const idx=Array.from(host.querySelectorAll('canvas')).indexOf(canvas);if(idx<0)continue;const key=`${idx}:${Math.round((c.tx||0)/10)*10}`,a=groups.get(key)||[];a.push(c);groups.set(key,a);}
        const out=[],ordered=Array.from(groups.entries()).sort((a,b)=>{const x=a[0].split(':').map(Number),y=b[0].split(':').map(Number);return x[0]-y[0]||x[1]-y[1];});
        for(const [,raw]of ordered){const unique=new Map();for(const c of raw)unique.set(`${Math.round(c.x)}:${Math.round(c.y)}:${c.text}`,c);for(const c of Array.from(unique.values()).sort((a,b)=>a.y-b.y||a.x-b.x)){const canvas=c.canvas,cr=canvas.getBoundingClientRect(),chars=points(c.text).filter(v=>!(/\s/u.test(v.ch)));if(!chars.length||cr.width<1||cr.height<1)continue;const px=c.x*c.a+c.tx,py=c.y*c.d+c.ty,pw=Math.max(1,c.width*Math.abs(c.a)),left=cr.left-hr.left+px/canvas.width*cr.width,baseline=cr.top-hr.top+py/canvas.height*cr.height,width=pw/canvas.width*cr.width,signedScaleY=(c.d||1)/canvas.height*cr.height,fs=Math.max(8,(c.fontSize||18)*Math.abs(signedScaleY)),vertical=textMetricBox(c,baseline,signedScaleY,fs),each=width/chars.length;chars.forEach((v,i)=>{const bbox=clipBox({x:left+i*each,y:vertical.y,width:Math.max(1,each),height:vertical.height},pageSurface);if(bbox)out.push({ch:v.ch,bbox});});}}
        return out;
      }
      function overlap(target,text,from){let at=text.indexOf(target,from);if(at>=0)return{targetStart:0,canvasStart:at,length:target.length};let best=null,min=Math.min(10,target.length);if(min<4)return null;for(let ti=0;ti<=target.length-min;ti++){const needle=target.slice(ti,ti+min);let ci=text.indexOf(needle,Math.max(0,from-2));while(ci>=0){let l=0,r=min;while(ti-l-1>=0&&ci-l-1>=0&&target[ti-l-1]===text[ci-l-1])l++;while(ti+r<target.length&&ci+r<text.length&&target[ti+r]===text[ci+r])r++;if(!best||l+r>best.length)best={targetStart:ti-l,canvasStart:ci-l,length:l+r};ci=text.indexOf(needle,ci+1);}}return best&&best.length>=min?best:null;}
      function findUnits(haystack,needle,from=0){if(!needle.length)return Math.min(from,haystack.length);outer:for(let i=Math.max(0,from);i+needle.length<=haystack.length;i++){for(let j=0;j<needle.length;j++)if(haystack[i+j]!==needle[j])continue outer;return i;}return-1;}
      function pageOverlap(source,page){if(!source.length||!page.length)return null;const exact=findUnits(source,page);if(exact>=0)return{sourceStart:exact,canvasStart:0,length:page.length};let best=null;const offsets=Array.from(new Set([0,10,20,40,80,Math.floor(page.length*.25),Math.floor(page.length*.5),Math.floor(page.length*.75)])).filter(v=>v>=0&&v<page.length);for(const ci of offsets)for(const n of [30,20,12,8]){if(ci+n>page.length)continue;const key=page.slice(ci,ci+n);let si=findUnits(source,key);while(si>=0){let l=0,r=n;while(ci-l-1>=0&&si-l-1>=0&&page[ci-l-1]===source[si-l-1])l++;while(ci+r<page.length&&si+r<source.length&&page[ci+r]===source[si+r])r++;const hit={sourceStart:si-l,canvasStart:ci-l,length:l+r};if(!best||hit.length>best.length)best=hit;si=findUnits(source,key,si+1);}}return best&&best.length>=Math.min(8,page.length)?best:null;}
      function mapGlyphs(layout,all){
        if(!layout||!all.length)return[];const sourceUnits=[],sourceParagraphs=[];for(let pi=0;pi<layout.paragraphs.length;pi++){const p=layout.paragraphs[pi],units=compact(p.text);if(!units.length)continue;const start=sourceUnits.length;for(const u of units)sourceUnits.push({ch:u.ch,paragraphIndex:pi,start:u.start,end:u.end,global:sourceUnits.length});sourceParagraphs.push({paragraphIndex:pi,start,end:sourceUnits.length});}const hit=pageOverlap(sourceUnits.map(u=>u.ch),all.map(g=>g.ch));if(!hit)return[];const grouped=new Map();for(let i=0;i<hit.length;i++){const u=sourceUnits[hit.sourceStart+i],g=all[hit.canvasStart+i];if(!u||!g)continue;const a=grouped.get(u.paragraphIndex)||[];a.push({unit:u,glyph:g,order:hit.canvasStart+i});grouped.set(u.paragraphIndex,a);}const out=[];for(const sourceRange of sourceParagraphs){const pairs=grouped.get(sourceRange.paragraphIndex)||[];if(!pairs.length)continue;const p=layout.paragraphs[sourceRange.paragraphIndex],sliceStart=pairs[0].unit.start,sliceEnd=pairs[pairs.length-1].unit.end,raw=p.text.slice(sliceStart,sliceEnd),text=raw.trim();if(text.length<2)continue;const leading=raw.indexOf(text),origin=sliceStart+Math.max(0,leading),sourceEnd=origin+text.length,entries=pairs.map(v=>({charStart:v.unit.start-origin,charEnd:v.unit.end-origin,bbox:v.glyph.bbox})).filter(e=>e.charEnd>0&&e.charStart<text.length);if(entries.length<Math.min(4,compact(text).length))continue;const xs=entries.map(e=>e.bbox.x),ys=entries.map(e=>e.bbox.y),rs=entries.map(e=>e.bbox.x+e.bbox.width),bs=entries.map(e=>e.bbox.y+e.bbox.height);out.push({text,style:p.style,entries,bounds:{x:Math.min(...xs),y:Math.min(...ys),width:Math.max(...rs)-Math.min(...xs),height:Math.max(...bs)-Math.min(...ys)},order:pairs[0].order,sourceLayoutFingerprint:layout.fingerprint,sourceParagraphIndex:sourceRange.paragraphIndex,sourceParagraphText:p.text,sourceCharStart:origin,sourceCharEnd:sourceEnd,sourceGlobalStart:pairs[0].unit.global,sourceGlobalEnd:pairs[pairs.length-1].unit.global+1});}return out.sort((a,b)=>a.order-b.order);
      }
      function mapDraws(layout,snapshot,host){
        if(!layout||!(snapshot.draws||[]).length)return[];const hr=host.getBoundingClientRect(),pageSurface=surface(host),out=[];
        const globalBases=[];let globalCursor=0;for(const p of layout.paragraphs){globalBases.push(globalCursor);globalCursor+=compact(p.text).length;}
        for(const d of snapshot.draws){const canvas=d.canvas;if(!canvas?.isConnected||canvas.width<1||canvas.height<1)continue;const cr=canvas.getBoundingClientRect(),sx=d.sx/d.sourceWidth*layout.width,sy=d.sy/d.sourceHeight*layout.height,sw=d.sw/d.sourceWidth*layout.width,sh=d.sh/d.sourceHeight*layout.height;for(let pi=0;pi<layout.paragraphs.length;pi++){const p=layout.paragraphs[pi],selected=(p.chars||[]).filter(c=>{const cx=c.left+c.width*.5,cy=c.top+c.height*.5;return cx>=sx&&cx<sx+sw&&cy>=sy&&cy<sy+sh;});if(!selected.length)continue;const sourceStart=selected[0].charStart,sourceEnd=selected[selected.length-1].charEnd,raw=p.text.slice(sourceStart,sourceEnd),text=raw.trim();if(text.length<2)continue;const leading=raw.indexOf(text),origin=sourceStart+Math.max(0,leading),visibleSourceEnd=origin+text.length,entries=selected.map(c=>{const bbox=clipBox({x:cr.left-hr.left+(d.dx+(c.left-sx)/sw*d.dw)/canvas.width*cr.width,y:cr.top-hr.top+(d.dy+(c.top-sy)/sh*d.dh)/canvas.height*cr.height,width:c.width/sw*d.dw/canvas.width*cr.width,height:c.height/sh*d.dh/canvas.height*cr.height},pageSurface);return bbox?{charStart:c.charStart-origin,charEnd:c.charEnd-origin,bbox}:null;}).filter(e=>e&&e.charEnd>0&&e.charStart<text.length);if(!entries.length)continue;const xs=entries.map(e=>e.bbox.x),ys=entries.map(e=>e.bbox.y),rs=entries.map(e=>e.bbox.x+e.bbox.width),bs=entries.map(e=>e.bbox.y+e.bbox.height),x=Math.min(...xs),y=Math.min(...ys),compactBefore=compact(p.text.slice(0,origin)).length,compactVisible=compact(text).length;out.push({text,style:p.style,entries,bounds:{x,y,width:Math.max(...rs)-x,height:Math.max(...bs)-y},order:y*10000+x,sourceLayoutFingerprint:layout.fingerprint,sourceParagraphIndex:pi,sourceParagraphText:p.text,sourceCharStart:origin,sourceCharEnd:visibleSourceEnd,sourceGlobalStart:globalBases[pi]+compactBefore,sourceGlobalEnd:globalBases[pi]+compactBefore+compactVisible});}}
        const seen=new Set();return out.sort((a,b)=>a.order-b.order).filter(p=>{const k=p.text.slice(0,100);if(seen.has(k))return false;seen.add(k);return true;});
      }
      function fallback(layout,host){if(!layout)return[];const hr=host.getBoundingClientRect(),s=hr.width/layout.width;return layout.paragraphs.map(p=>({text:p.text,style:p.style,entries:[],bounds:{x:p.left*s,y:p.top*s,width:p.width*s,height:p.height*s},order:p.top})).filter(p=>p.bounds.y+p.bounds.height>=0&&p.bounds.y<=hr.height&&p.bounds.x+p.bounds.width>=0&&p.bounds.x<=hr.width);}
      function directFillText(snapshot,host){
        const hr=host.getBoundingClientRect(),pageSurface=surface(host),canvases=Array.from(host.querySelectorAll('canvas')),groups=new Map();
        for(const c of snapshot.calls||[]){const canvas=c.canvas,idx=canvases.indexOf(canvas);if(idx<0||!canvas?.isConnected||canvas.width<1||canvas.height<1)continue;const key=`${idx}:${Math.round((c.tx||0)/10)*10}`,a=groups.get(key)||[];a.push(c);groups.set(key,a);}
        const ordered=Array.from(groups.entries()).sort((a,b)=>{const x=a[0].split(':').map(Number),y=b[0].split(':').map(Number);return x[0]-y[0]||x[1]-y[1];}),result=[];let pageOrder=0;
        const lineJoiner=(left,right)=>{const a=String(left||'').trim().slice(-1),b=String(right||'').trim().slice(0,1),cjk=ch=>/[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]/u.test(ch);return a&&b&&!cjk(a)&&!cjk(b)&&/[\p{L}\p{N},.;:!?"'”’)]/u.test(a)&&/[\p{L}\p{N}]/u.test(b)?' ':'';};
        for(const [,raw]of ordered){
          const unique=new Map();for(const c of raw)unique.set(`${Math.round(c.x*10)}:${Math.round(c.y*10)}:${c.text}`,c);const runs=[];
          for(const c of unique.values()){const canvas=c.canvas,cr=canvas.getBoundingClientRect(),units=points(String(c.text||''));if(!units.length||cr.width<1||cr.height<1)continue;const px=c.x*c.a+c.tx,py=c.y*c.d+c.ty,pw=Math.max(1,c.width*Math.abs(c.a)),left=cr.left-hr.left+px/canvas.width*cr.width,baseline=cr.top-hr.top+py/canvas.height*cr.height,width=pw/canvas.width*cr.width,signedScaleY=(c.d||1)/canvas.height*cr.height,fs=Math.max(8,(c.fontSize||18)*Math.abs(signedScaleY)),vertical=textMetricBox(c,baseline,signedScaleY,fs),each=width/units.length;let text='',entries=[];
            for(let i=0;i<units.length;i++){const unit=units[i],bbox=clipBox({x:left+i*each,y:vertical.y,width:Math.max(1,each),height:vertical.height},pageSurface);if(!bbox)continue;const start=text.length;text+=unit.ch;if(!(/\s/u.test(unit.ch)))entries.push({charStart:start,charEnd:text.length,bbox});}
            const first=text.search(/\S/u);if(first<0||!entries.length)continue;const value=text.slice(first).replace(/\s+$/u,''),end=first+value.length;entries=entries.filter(e=>e.charEnd>first&&e.charStart<end).map(e=>({...e,charStart:Math.max(0,e.charStart-first),charEnd:Math.min(value.length,e.charEnd-first)}));if(value.length<1||!entries.length)continue;const xs=entries.map(e=>e.bbox.x),ys=entries.map(e=>e.bbox.y),rs=entries.map(e=>e.bbox.x+e.bbox.width),bs=entries.map(e=>e.bbox.y+e.bbox.height);runs.push({text:value,entries,x:Math.min(...xs),y:Math.min(...ys),right:Math.max(...rs),bottom:Math.max(...bs),baseline,height:Math.max(...bs)-Math.min(...ys)});
          }
          if(!runs.length)continue;runs.sort((a,b)=>a.baseline-b.baseline||a.x-b.x);const clustered=[];
          for(const run of runs){let line=clustered[clustered.length-1];if(!line||Math.abs(line.baseline-run.baseline)>Math.max(3,Math.min(line.height,run.height)*.35)){line={baseline:run.baseline,height:run.height,runs:[]};clustered.push(line);}line.runs.push(run);line.height=Math.max(line.height,run.height);}
          const lines=clustered.map(line=>{line.runs.sort((a,b)=>a.x-b.x);let text='',entries=[],right=-Infinity;for(const run of line.runs){const spacer=right>-Infinity&&run.x-right>Math.max(2,run.height*.18)?lineJoiner(text,run.text):'',offset=text.length+spacer.length;text+=spacer+run.text;entries.push(...run.entries.map(e=>({...e,charStart:e.charStart+offset,charEnd:e.charEnd+offset})));right=Math.max(right,run.right);}const xs=entries.map(e=>e.bbox.x),ys=entries.map(e=>e.bbox.y),rs=entries.map(e=>e.bbox.x+e.bbox.width),bs=entries.map(e=>e.bbox.y+e.bbox.height);return{text,entries,baseline:line.baseline,bounds:{x:Math.min(...xs),y:Math.min(...ys),width:Math.max(...rs)-Math.min(...xs),height:Math.max(...bs)-Math.min(...ys)}};}).filter(l=>l.text.trim().length);
          if(!lines.length)continue;const sample=lines.map(l=>l.text).join('').slice(0,500),han=(sample.match(/[\u4e00-\u9fff]/g)||[]).length;if(sample.length>=50&&han/sample.length>=.45){const common='的一是不了人我在有他这为之大来以个中上们到说时要就出会也你对';let count=0;for(const ch of sample)if(common.includes(ch))count++;if(count/sample.length<.03)continue;}
          const gaps=[];for(let i=1;i<lines.length;i++){const gap=lines[i].baseline-lines[i-1].baseline;if(gap>0)gaps.push(gap);}gaps.sort((a,b)=>a-b);const base=gaps.length?gaps[Math.max(0,Math.floor(gaps.length*.25))]:Infinity,threshold=base*1.3;let paragraphLines=[];
          const flush=()=>{if(!paragraphLines.length)return;let text='',entries=[];for(const line of paragraphLines){const join=lineJoiner(text,line.text),offset=text.length+join.length;text+=join+line.text;entries.push(...line.entries.map(e=>({...e,charStart:e.charStart+offset,charEnd:e.charEnd+offset})));}text=text.trim();if(text.length>=2&&entries.length){const xs=entries.map(e=>e.bbox.x),ys=entries.map(e=>e.bbox.y),rs=entries.map(e=>e.bbox.x+e.bbox.width),bs=entries.map(e=>e.bbox.y+e.bbox.height);result.push({text,style:'',entries,bounds:{x:Math.min(...xs),y:Math.min(...ys),width:Math.max(...rs)-Math.min(...xs),height:Math.max(...bs)-Math.min(...ys)},order:pageOrder*1000000+paragraphLines[0].baseline,geometrySource:'fillText-direct'});}paragraphLines=[];};
          for(let i=0;i<lines.length;i++){if(paragraphLines.length&&lines[i].baseline-lines[i-1].baseline>threshold)flush();paragraphLines.push(lines[i]);}flush();pageOrder++;
        }
        return result.sort((a,b)=>a.order-b.order);
      }
      // Some WeRead builds paint complete text runs directly into the visible
      // Canvas. `directFillText` can reconstruct exact on-screen geometry, but
      // it originally lost the chapter-HTML source offsets. Without those
      // offsets `predictNext` cannot slice the following page, so native
      // QuickRead only starts after the page has already turned. Re-anchor the
      // reconstructed text to the retained pre-render layout while keeping the
      // Canvas rects authoritative for highlight/mark painting.
      function attachDirectSource(layout,items){
        if(!layout||!items.length)return null;const source=[],sourceRanges=[];
        for(let pi=0;pi<layout.paragraphs.length;pi++){const p=layout.paragraphs[pi],start=source.length;for(const u of compact(p.text))source.push({...u,paragraphIndex:pi,global:source.length});sourceRanges.push({paragraphIndex:pi,start,end:source.length});}
        const page=[],pageRanges=[];for(let ii=0;ii<items.length;ii++){const start=page.length;for(const u of compact(items[ii].text))page.push({...u,itemIndex:ii,global:page.length});pageRanges.push({itemIndex:ii,start,end:page.length});}
        const hit=pageOverlap(source.map(u=>u.ch),page.map(u=>u.ch));if(!hit)return null;const mapped=items.map(p=>({...p,sourceLayoutFingerprint:layout.fingerprint})),hitPageEnd=hit.canvasStart+hit.length;
        for(const pr of pageRanges){const pageStart=Math.max(pr.start,hit.canvasStart),pageEnd=Math.min(pr.end,hitPageEnd);if(pageEnd<=pageStart)continue;const sourceStart=hit.sourceStart+(pageStart-hit.canvasStart),sourceEnd=hit.sourceStart+(pageEnd-hit.canvasStart),first=source[sourceStart],last=source[sourceEnd-1];if(!first||!last)continue;const next={...mapped[pr.itemIndex],sourceGlobalStart:sourceStart,sourceGlobalEnd:sourceEnd};const sr=sourceRanges.find(v=>sourceStart>=v.start&&sourceEnd<=v.end);if(sr){const paragraph=layout.paragraphs[sr.paragraphIndex];next.sourceParagraphIndex=sr.paragraphIndex;next.sourceParagraphText=paragraph.text;next.sourceCharStart=first.start;next.sourceCharEnd=last.end;}mapped[pr.itemIndex]=next;}
        return{items:mapped,matched:hit.length};
      }
      function enrichDirectSource(items){let best=null;for(const layout of layouts){const candidate=attachDirectSource(layout,items);if(candidate&&(!best||candidate.matched>best.matched))best=candidate;}return best?.items||items;}
      function choose(snapshot,host){let best=[];if((snapshot.draws||[]).length){for(const l of layouts){const m=mapDraws(l,snapshot,host);if(m.reduce((n,p)=>n+p.entries.length,0)>best.reduce((n,p)=>n+p.entries.length,0))best=m;}if(best.length){best.forEach(p=>p.geometrySource='drawImage');return best;}}const all=glyphs(snapshot,host);for(const l of layouts){const m=mapGlyphs(l,all);if(m.reduce((n,p)=>n+p.entries.length,0)>best.reduce((n,p)=>n+p.entries.length,0))best=m;}if(best.length){best.forEach(p=>p.geometrySource='fillText');return best;}best=directFillText(snapshot,host);if(best.length)return enrichDirectSource(best);if(host.querySelector('canvas'))return[];best=fallback(layouts[layouts.length-1],host);best.forEach(p=>p.geometrySource='dom');return best;}

      function sequentialPreview(layout,current){const starts=current.map(p=>Number(p.sourceGlobalStart)).filter(Number.isFinite),ends=current.map(p=>Number(p.sourceGlobalEnd)).filter(Number.isFinite);if(!starts.length||!ends.length)return[];const from=Math.max(...ends),count=Math.max(1,Math.max(...ends)-Math.min(...starts)),units=[];for(let pi=0;pi<layout.paragraphs.length;pi++)for(const u of compact(layout.paragraphs[pi].text))units.push({...u,paragraphIndex:pi,global:units.length});const slice=units.slice(from,from+count),grouped=new Map();for(const u of slice){const a=grouped.get(u.paragraphIndex)||[];a.push(u);grouped.set(u.paragraphIndex,a);}const out=[];for(const [pi,a]of grouped){const p=layout.paragraphs[pi],raw=p.text.slice(a[0].start,a[a.length-1].end),text=raw.trim();if(text.length>=2){const leading=raw.indexOf(text),origin=a[0].start+Math.max(0,leading);out.push({text,sourceLayoutFingerprint:layout.fingerprint,sourceParagraphIndex:pi,sourceParagraphText:p.text,sourceCharStart:origin,sourceCharEnd:origin+text.length,sourceGlobalStart:a[0].global,sourceGlobalEnd:a[a.length-1].global+1});}}return out;}
      const sentenceTerminals=new Set(['.','!','?',';','。','！','？','；','…','।','॥']),sentenceClosers=new Set(['"',"'",'»','’','”',')',']','）','】','」','』','〉','》']);
      function sentenceEndAfter(text,offset){const value=String(text||''),boundary=Math.max(0,Math.min(value.length,Number(offset)||0));let before=boundary;while(before>0){const cp=value.codePointAt(before-1),ch=String.fromCodePoint(cp);if((/\s/u.test(ch))||sentenceClosers.has(ch)){before-=ch.length;continue;}if(sentenceTerminals.has(ch))return boundary;break;}let i=boundary,seen=false;for(;i<value.length;){const cp=value.codePointAt(i),ch=String.fromCodePoint(cp),next=i+ch.length;if(seen&&!sentenceClosers.has(ch)&&!(/\s/u.test(ch)))return i;if(sentenceTerminals.has(ch))seen=true;i=next;}return seen?value.length:boundary;}
      function speechPayloads(items){return items.map((p,index)=>{const payload={text:p.text,visibleText:p.text,prefetchText:p.text};if(Number.isFinite(Number(p.sourceParagraphIndex)))payload.sourceParagraphIndex=Number(p.sourceParagraphIndex);if(Number.isFinite(Number(p.sourceCharStart)))payload.sourceCharStart=Number(p.sourceCharStart);if(Number.isFinite(Number(p.sourceCharEnd)))payload.sourceCharEnd=Number(p.sourceCharEnd);if(index!==items.length-1||!Number.isFinite(Number(p.sourceCharEnd))||!p.sourceParagraphText)return payload;const end=sentenceEndAfter(p.sourceParagraphText,p.sourceCharEnd),extension=end-Number(p.sourceCharEnd);if(extension<=0||extension>320)return payload;const suffix=p.sourceParagraphText.slice(Number(p.sourceCharEnd),end);if(!suffix.trim())return payload;payload.text=p.text+suffix;payload.prefetchText=payload.text;payload.boundaryUTF16Offset=p.text.length;payload.extendedUTF16Length=payload.text.length;payload.sourceSpeechEnd=end;return payload;});}
      function predictNext(snapshot,host,current){const layout=layouts.find(l=>l.fingerprint===current[0]?.sourceLayoutFingerprint);if(!layout)return null;const draws=(snapshot.draws||[]).filter(d=>d.canvas?.isConnected&&d.sw>0);if(draws.length){const min=Math.min(...draws.map(d=>d.sx)),max=Math.max(...draws.map(d=>d.sx+d.sw)),shift=max-min;if(shift>0){const shifted=draws.map(d=>({...d,sx:d.sx+shift})).filter(d=>d.sx<d.sourceWidth);const mapped=mapDraws(layout,{draws:shifted},host);if(mapped.length)return{confidence:'drawImage',paragraphs:mapped};}}const sequential=sequentialPreview(layout,current);return sequential.length?{confidence:'sequential',paragraphs:sequential}:null;}
      function preparePreviewPayloads(currentPayloads,paragraphs){const payloads=speechPayloads(paragraphs),tail=currentPayloads[currentPayloads.length-1],first=paragraphs[0],firstPayload=payloads[0];if(tail&&firstPayload&&Number.isFinite(Number(tail.sourceSpeechEnd))&&Number(tail.sourceParagraphIndex)===Number(first.sourceParagraphIndex)&&Number.isFinite(Number(first.sourceCharStart))){const carriedEnd=Math.min(Number(tail.sourceSpeechEnd),Number(first.sourceCharEnd)),carryLength=Math.max(0,carriedEnd-Number(first.sourceCharStart));if(carryLength>0){firstPayload.carryUTF16Length=Math.min(first.text.length,carryLength);firstPayload.prefetchText=firstPayload.text.slice(carryLength);}}return payloads;}
      function publishPreview(snapshot,host,sourceFingerprint,currentPayloads){const preview=predictNext(snapshot,host,visible);if(!preview?.paragraphs?.length){post('wereadPreviewState',{sourceFingerprint,reason:visible.some(p=>Number.isFinite(Number(p.sourceGlobalEnd)))?'chapter-end-or-no-following-text':'missing-source-anchor',geometrySource:visible[0]?.geometrySource||'unknown',layouts:layouts.length,layoutParagraphs:Math.max(0,...layouts.map(l=>l.paragraphs.length)),layoutCharacters:Math.max(0,...layouts.map(l=>l.paragraphs.reduce((n,p)=>n+compact(p.text).length,0))),pageCharacters:visible.reduce((n,p)=>n+compact(p.text).length,0)});return;}const contentFingerprint=hash(preview.paragraphs.map(p=>p.text).join('|')),key=`${sourceFingerprint}|${contentFingerprint}`;if(key===lastPreviewKey)return;lastPreviewKey=key;const payloads=preparePreviewPayloads(currentPayloads,preview.paragraphs);post('wereadPagePreview',{sourceFingerprint,contentFingerprint,confidence:preview.confidence,readerURL:location.href,paragraphs:payloads});}

      function ensureLayer(host){if(layer?.isConnected&&layer.parentElement===host)return layer;document.querySelectorAll('[data-castreader-weread-layer]').forEach(e=>e.remove());if(getComputedStyle(host).position==='static')host.style.position='relative';layer=document.createElement('div');layer.dataset.castreaderWereadLayer='1';layer.style.cssText='position:absolute;inset:0;z-index:4;pointer-events:none;overflow:hidden;';host.appendChild(layer);return layer;}
      function rebuild(items,host){const l=ensureLayer(host);l.innerHTML='';items.forEach((p,i)=>{const e=document.createElement('div'),b=p.bounds;e.dataset.crWereadPara=String(i);e.textContent=p.text;e.style.cssText=`position:absolute;left:${b.x}px;top:${b.y}px;width:${Math.max(1,b.width)}px;height:${Math.max(1,b.height)}px;color:transparent;background:transparent;pointer-events:none;overflow:hidden;box-sizing:border-box;margin:0;padding:0;${p.style||''}`;l.appendChild(e);p.el=e;});}
      function schedule(reason){clearTimeout(timer);timer=setTimeout(()=>publish(reason),240);}
      function publish(reason){
        const host=root(),snapshot=window.__castReaderWeReadCanvas?.snapshot?.()||{calls:[],draws:[],epoch:0,columnFingerprint:''};if(!host)return;const next=choose(snapshot,host);if(!next.length){const state=`${layouts.length}:${(snapshot.calls||[]).length}:${(snapshot.draws||[]).length}:${Math.round(innerWidth)}x${Math.round(innerHeight)}`;if(state!==lastExtractionState){lastExtractionState=state;post('wereadExtractionState',{reason,layouts:layouts.length,fillTextCalls:(snapshot.calls||[]).length,draws:(snapshot.draws||[]).length,innerWidth,innerHeight,devicePixelRatio});}return;}lastExtractionState='';
        const progress=clean(Array.from(document.querySelectorAll('[class*=progress],[class*=Progress],.renderTarget_pager,[class*=readerFooter]')).map(e=>e.innerText).join(' ')).slice(0,120),layoutFingerprint=hash((snapshot.calls||[]).map(c=>`${c.text}:${Math.round(c.x)}:${Math.round(c.y)}:${Math.round(c.tx)}`).join('|')),columns=snapshot.columnFingerprint||'',contentFingerprint=hash(next.map(p=>p.text).join('|')),fingerprint=hash(`${contentFingerprint}|${columns}|${location.pathname}`),geometryFingerprint=hash(next.flatMap(p=>p.entries||[]).map(e=>`${e.charStart}:${Math.round(e.bbox.x)}:${Math.round(e.bbox.y)}`).join('|')),candidate=`${fingerprint}|${layoutFingerprint}|${geometryFingerprint}|${snapshot.epoch}`;if(candidate!==stableCandidate){stableCandidate=candidate;clearTimeout(stableTimer);stableTimer=setTimeout(()=>publish(reason),120);return;}stableCandidate='';visible=next;rebuild(visible,host);const hr=host.getBoundingClientRect(),bounds=visible.map(p=>p.bounds);
        if(bounds.length&&innerWidth>0){const left=hr.left+Math.min(...bounds.map(b=>b.x)),right=hr.left+Math.max(...bounds.map(b=>b.x+b.width));post('wereadViewport',{contentLeftRatio:Math.max(0,left/innerWidth),contentRightRatio:Math.min(1,right/innerWidth)});}
        if(lastFingerprint&&fingerprint!==lastFingerprint){restoreVisualState();post('wereadPageChanging',{reason,previousFingerprint:lastFingerprint,nextFingerprint:fingerprint,canvasEpoch:snapshot.epoch});}
        if(fingerprint===lastFingerprint){restoreVisualState();post('wereadLayoutStable',{reason,fingerprint,canvasEpoch:snapshot.epoch});return;}const previousFingerprint=lastFingerprint;lastFingerprint=fingerprint;wordState={para:-1,seg:-1,cursor:0,last:-1};
        const speechParagraphs=speechPayloads(visible);post('wereadPage',{reason,previousFingerprint,fingerprint,contentFingerprint,layoutFingerprint,columnFingerprint:columns,canvasEpoch:snapshot.epoch,geometrySource:visible[0]?.geometrySource||'unknown',mappedGlyphs:visible.reduce((n,p)=>n+(p.entries?.length||0),0),progressLabel:progress,readerURL:location.href,title:clean(document.title),paragraphs:speechParagraphs});publishPreview(snapshot,host,fingerprint,speechParagraphs);post('wereadLayoutStable',{reason,fingerprint,canvasEpoch:snapshot.epoch});
      }

      function range(el,start,end){const w=document.createTreeWalker(el,NodeFilter.SHOW_TEXT);let pos=0,a=null,b=null,n;while((n=w.nextNode())){const next=pos+n.nodeValue.length;if(!a&&start>=pos&&start<=next)a={n,o:start-pos};if(end>=pos&&end<=next){b={n,o:end-pos};break;}pos=next;}if(!a||!b)return null;const r=document.createRange();r.setStart(a.n,Math.max(0,a.o));r.setEnd(b.n,Math.max(0,b.o));return r;}
      const quoteMap=new Map([['“','"'],['”','"'],['„','"'],['‟','"'],['‘',"'"],['’',"'"],['‚',"'"],['‛',"'"],['—','-'],['–','-']]);
      function normalizedUnits(text){const out=[];for(const p of points(String(text||''))){if(/\s/u.test(p.ch))continue;let value=quoteMap.get(p.ch)||p.ch;try{value=value.normalize('NFKC');}catch(_){}for(const ch of Array.from(value.toLocaleLowerCase()))if(!(/\s/u.test(ch)))out.push({ch,start:p.start,end:p.end});}return out;}
      function formattingMatch(fullText,targetText,startPos){const source=normalizedUnits(fullText),target=normalizedUnits(targetText);if(!source.length||!target.length)return null;const sourceText=source.map(v=>v.ch).join(''),targetTextNormalized=target.map(v=>v.ch).join('');let sourceFrom=source.findIndex(v=>v.end>startPos);if(sourceFrom<0)return null;let at=sourceText.indexOf(targetTextNormalized,sourceFrom),matched=targetTextNormalized.length;if(at<0){for(let n=Math.min(50,targetTextNormalized.length);n>=6;n=Math.floor(n*.6)){at=sourceText.indexOf(targetTextNormalized.slice(0,n),sourceFrom);if(at>=0){matched=n;break;}}}if(at<0)return null;return{pos:source[at].start,prefixEnd:source[Math.min(source.length-1,at+matched-1)].end};}
      function computeSourceSpan(fullText,startPos,sentenceText){let fi=startPos,si=0;const look=3;while(fi<fullText.length&&si<sentenceText.length){if(fullText[fi]===sentenceText[si]){fi++;si++;continue;}const fw=/\s/.test(fullText[fi]),sw=/\s/.test(sentenceText[si]);if(fw&&sw){while(fi<fullText.length&&/\s/.test(fullText[fi]))fi++;while(si<sentenceText.length&&/\s/.test(sentenceText[si]))si++;continue;}if(fw){fi++;continue;}if(sw){si++;continue;}let skipF=-1,skipS=-1;for(let k=1;k<=look;k++){if(skipF<0&&fi+k<fullText.length&&fullText[fi+k]===sentenceText[si])skipF=k;if(skipS<0&&si+k<sentenceText.length&&fullText[fi]===sentenceText[si+k])skipS=k;}if(skipF>=0&&(skipS<0||skipF<=skipS))fi+=skipF;else if(skipS>=0)si+=skipS;else{fi++;si++;}}while(fi<fullText.length&&/\s/.test(fullText[fi]))fi++;return Math.max(1,fi-startPos);}
      function resolveSegmentRange(p,a){const texts=Array.isArray(a.segmentTexts)?a.segmentTexts:[],seq=Number(a.segSeq);if(!p||!texts.length||!Number.isInteger(seq)||seq<0||seq>=texts.length)return null;let cursor=0;for(let i=0;i<=seq;i++){const sentence=String(texts[i]||'');if(!sentence.trim())continue;let pos=p.text.indexOf(sentence,cursor);if(pos<0)pos=p.text.toLocaleLowerCase().indexOf(sentence.toLocaleLowerCase(),cursor);if(pos<0)pos=formattingMatch(p.text,sentence,cursor)?.pos??-1;if(pos<0){if(cursor>=p.text.length)return null;pos=cursor;}const end=Math.min(p.text.length,pos+computeSourceSpan(p.text,pos,sentence));if(i===seq)return{start:pos,end};cursor=Math.max(cursor,end);}return null;}
      function rectsFor(p,start,end){const exact=(p?.entries||[]).filter(e=>e.charEnd>start&&e.charStart<end);if(exact.length)return exact.map(e=>({...e.bbox}));if(p?.geometrySource==='fillText'||p?.geometrySource==='drawImage'||root().querySelector('canvas'))return[];const r=p?.el&&range(p.el,start,end);if(!r)return[];const hr=root().getBoundingClientRect();return Array.from(r.getClientRects()).map(v=>({x:v.left-hr.left,y:v.top-hr.top,width:v.width,height:v.height}));}
      function lines(rects){const sorted=rects.filter(r=>r.width>.3&&r.height>.3).sort((a,b)=>a.y-b.y||a.x-b.x),groups=[];for(const r of sorted){let g=groups.find(v=>Math.abs(v.y-r.y)<=Math.max(3,Math.min(v.height,r.height)*.45));if(!g){groups.push({x:r.x,y:r.y,width:r.width,height:r.height});continue;}const right=Math.max(g.x+g.width,r.x+r.width),bottom=Math.max(g.y+g.height,r.y+r.height);g.x=Math.min(g.x,r.x);g.y=Math.min(g.y,r.y);g.width=right-g.x;g.height=bottom-g.y;}return groups;}
      const rgba=(hex,a)=>{const h=String(hex||'#FD5F01').replace('#','');return/^[0-9a-f]{6}$/i.test(h)?`rgba(${parseInt(h.slice(0,2),16)},${parseInt(h.slice(2,4),16)},${parseInt(h.slice(4,6),16)},${a})`:`rgba(253,95,1,${a})`;};
      function removeHighlight(){layer?.querySelectorAll('[data-cr-weread-highlight]').forEach(e=>e.remove());}
      function clearHighlight(){currentHighlight=null;removeHighlight();}
      function paint(rects){removeHighlight();const l=ensureLayer(root());for(const r of lines(rects)){const d=document.createElement('div');d.dataset.crWereadHighlight='1';d.style.cssText=`position:absolute;left:${r.x-1}px;top:${r.y}px;width:${r.width+2}px;height:${r.height}px;border-radius:4px;background:${rgba(color,.36)};pointer-events:none;`;l.appendChild(d);}}
      function applyHighlight(a){if(a?.kind==='range')paint(rectsFor(visible[a.paragraphIndex],a.charStart,a.charEnd));}
      function markSvg(){const l=ensureLayer(root());let svg=l.querySelector('#castreader-weread-marks-svg');if(!svg){svg=document.createElementNS('http://www.w3.org/2000/svg','svg');svg.id='castreader-weread-marks-svg';svg.dataset.crWereadMarkSvg='1';svg.style.cssText='position:absolute;left:0;top:0;width:100%;height:100%;overflow:visible;pointer-events:none;z-index:3;';l.appendChild(svg);}const w=Math.max(1,Math.round(l.clientWidth||l.getBoundingClientRect().width||1)),h=Math.max(1,Math.round(l.clientHeight||l.getBoundingClientRect().height||1));svg.setAttribute('viewBox',`0 0 ${w} ${h}`);svg.setAttribute('width',String(w));svg.setAttribute('height',String(h));return svg;}
      function markRng(seed){let s=(Number(seed||1)>>>0);return()=>{s=(s+0x6d2b79f5)>>>0;let t=Math.imul(s^(s>>>15),1|s);t=(t+Math.imul(t^(t>>>7),61|t))^t;return((t^(t>>>14))>>>0)/4294967296;};}
      const markJitter=(v,amp,rng)=>Number(v||0)+(rng()-.5)*Number(amp||0);
      function handLine(x0,y0,x1,y1,waviness,rng){const dx=x1-x0,dy=y1-y0,len=Math.sqrt(dx*dx+dy*dy),count=Math.max(4,Math.round(len/30));let d=`M ${markJitter(x0,3,rng).toFixed(1)} ${markJitter(y0,waviness,rng).toFixed(1)}`;for(let i=1;i<=count;i++){const t=i/count,x=x0+dx*t,y=y0+dy*t+(rng()-.5)*waviness*2,cx=x0+dx*(t-.5/count)+(rng()-.5)*8,cy=y0+dy*(t-.5/count)+(rng()-.5)*waviness*2;d+=` Q ${cx.toFixed(1)} ${cy.toFixed(1)} ${x.toFixed(1)} ${y.toFixed(1)}`;}return d;}
      function handLoop(cx,cy,rx,ry,count,rng){const pts=[],n=Math.max(8,Number(count||12)),over=Math.max(1,Math.round(n*.12));for(let i=0;i<=n+over;i++){const a=i/n*Math.PI*2;pts.push({x:cx+Math.cos(a)*rx*(1+(rng()-.5)*.15),y:cy+Math.sin(a)*ry*(1+(rng()-.5)*.15)});}let d=`M ${pts[0].x.toFixed(1)} ${pts[0].y.toFixed(1)}`;for(let i=1;i<pts.length;i++){const p=pts[i-1],q=pts[i],c1x=p.x+(q.x-p.x)*.4+(rng()-.5)*6,c1y=p.y+(q.y-p.y)*.1+(rng()-.5)*6,c2x=p.x+(q.x-p.x)*.6+(rng()-.5)*6,c2y=p.y+(q.y-p.y)*.9+(rng()-.5)*6;d+=` C ${c1x.toFixed(1)} ${c1y.toFixed(1)},${c2x.toFixed(1)} ${c2y.toFixed(1)},${q.x.toFixed(1)} ${q.y.toFixed(1)}`;}return d;}
      function handDigit(digit,cx,cy,size,rng){const j=(v,a=.7)=>markJitter(v,a,rng).toFixed(1),h=size,w=size*.58,T=cy-h/2,B=cy+h/2,L=cx-w/2,R=cx+w/2,M=cy;switch(((Number(digit||0)%10)+10)%10){case 1:return`M ${j(cx-w*.28)} ${j(T+h*.22)} Q ${j(cx-w*.06)} ${j(T+h*.05)} ${j(cx)} ${j(T)} Q ${j(cx)} ${j(M)} ${j(cx)} ${j(B)}`;case 2:return`M ${j(L+w*.08)} ${j(T+h*.24)} Q ${j(cx-w*.05)} ${j(T-h*.02)} ${j(cx+w*.2)} ${j(T)} Q ${j(R+w*.05)} ${j(T+h*.12)} ${j(cx+w*.1)} ${j(M+h*.05)} Q ${j(cx-w*.1)} ${j(M+h*.22)} ${j(L)} ${j(B)} L ${j(R)} ${j(B)}`;case 3:return`M ${j(L+w*.05)} ${j(T+h*.08)} Q ${j(cx+w*.35)} ${j(T-h*.02)} ${j(cx+w*.1)} ${j(M-h*.02)} Q ${j(R+w*.05)} ${j(M+h*.04)} ${j(cx+w*.1)} ${j(M+h*.24)} Q ${j(cx-w*.2)} ${j(B+h*.02)} ${j(L)} ${j(B-h*.1)}`;case 4:return`M ${j(cx+w*.12)} ${j(T)} Q ${j(L-w*.05)} ${j(M+h*.08)} ${j(L-w*.08)} ${j(M+h*.14)} L ${j(R+w*.05)} ${j(M+h*.14)} M ${j(cx+w*.18)} ${j(T+h*.15)} Q ${j(cx+w*.18)} ${j(M)} ${j(cx+w*.18)} ${j(B)}`;case 5:return`M ${j(R)} ${j(T+h*.02)} L ${j(L+w*.08)} ${j(T)} Q ${j(L+w*.02)} ${j(M-h*.05)} ${j(L+w*.05)} ${j(M+h*.05)} Q ${j(cx+w*.4)} ${j(M-h*.04)} ${j(cx+w*.3)} ${j(M+h*.18)} Q ${j(cx+w*.1)} ${j(B+h*.04)} ${j(L)} ${j(B-h*.08)}`;case 6:return`M ${j(cx+w*.28)} ${j(T)} Q ${j(L-w*.02)} ${j(M-h*.08)} ${j(L)} ${j(M+h*.12)} Q ${j(L-w*.02)} ${j(B)} ${j(cx)} ${j(B)} Q ${j(R+w*.02)} ${j(B)} ${j(R)} ${j(M+h*.14)} Q ${j(R-w*.05)} ${j(M)} ${j(L+w*.12)} ${j(M+h*.14)}`;case 7:return`M ${j(L)} ${j(T)} L ${j(R)} ${j(T)} Q ${j(cx+w*.05)} ${j(M)} ${j(cx-w*.12)} ${j(B)}`;case 8:return`${handLoop(cx,cy-h*.26,w*.4,h*.24,10,rng)} ${handLoop(cx,cy+h*.26,w*.48,h*.26,10,rng)}`;case 9:return`${handLoop(cx,cy-h*.2,w*.46,h*.28,10,rng)} M ${j(cx+w*.4)} ${j(M-h*.18)} Q ${j(cx+w*.28)} ${j(M+h*.2)} ${j(cx-w*.05)} ${j(B)}`;default:return handLoop(cx,cy,w*.5,h*.48,12,rng);}}
      function markDuration(action,r){const span=action==='circle'?Math.PI*(r.width+r.height)*.35:action==='number'?Math.max(40,r.height*1.4):r.width;return Math.max(450,Math.min(2200,span*3.5));}
      function markStroke(weight,base){return weight==='primary'?base*1.12:weight==='tertiary'?base*.76:base;}
      function animatedPath(parent,d,stroke,width,opacity,duration,delay,style,animate){const p=document.createElementNS('http://www.w3.org/2000/svg','path');p.setAttribute('d',d);p.setAttribute('fill','none');p.setAttribute('stroke',stroke);p.setAttribute('stroke-width',String(width));p.setAttribute('stroke-linecap','round');p.setAttribute('stroke-linejoin','round');p.setAttribute('opacity',String(opacity));p.setAttribute('vector-effect','non-scaling-stroke');p.style.cssText=style||'';parent.appendChild(p);let len=180;try{len=Math.max(1,p.getTotalLength());}catch(_){}if(animate!==false){p.style.strokeDasharray=String(len);p.style.strokeDashoffset=String(len);p.style.transition='none';try{p.getBoundingClientRect();}catch(_){}requestAnimationFrame(()=>requestAnimationFrame(()=>{p.style.transition=`stroke-dashoffset ${Math.round(duration||700)}ms cubic-bezier(0.62,0,0.22,1) ${Math.round(delay||0)}ms, opacity 180ms ease`;p.style.strokeDashoffset='0';}));}else{p.style.strokeDasharray='none';p.style.strokeDashoffset='0';p.style.transition='none';}return p;}
      function rectUnion(rs){if(!rs.length)return null;const left=Math.min(...rs.map(r=>r.x)),top=Math.min(...rs.map(r=>r.y)),right=Math.max(...rs.map(r=>r.x+r.width)),bottom=Math.max(...rs.map(r=>r.y+r.height));return{x:left,y:top,width:right-left,height:bottom-top};}
      function drawHandMark(group,rs,a,animate){const action=String(a.action||'highlight'),weight=String(a.weight||''),seed=Number(a.seed||1)>>>0,union=rectUnion(rs),stroke=rgba(color,.92),fill=rgba(color,.55);if(!union)return;if(action==='circle'){const rng=markRng(seed+17),d=handLoop(union.x+union.width/2,union.y+union.height/2,Math.max(10,union.width/2+7),Math.max(9,union.height/2+5),14,rng);animatedPath(group,d,stroke,markStroke(weight,6.5),.92,markDuration(action,union),0,'',animate);return;}if(action==='number'){const rng=markRng(seed+29),first=rs[0],lineH=Math.max(14,first.height),radius=Math.min(lineH*.6,16),cx=Math.max(4+radius,first.x-radius*1.5),cy=first.y+lineH/2,duration=markDuration(action,union);animatedPath(group,handLoop(cx,cy,radius,radius,14,rng),stroke,2.5,.9,duration*.5,0,'',animate);animatedPath(group,handDigit(Math.max(1,Number(a.n||1)),cx,cy,radius*1.12,rng),stroke,2.5,.95,duration*.5,duration*.5,'',animate);const under=rs.map(r=>handLine(r.x-2,r.y+r.height+3,r.x+r.width+4,r.y+r.height+3,1.5,rng)).join(' ');animatedPath(group,under,stroke,2.5,.9,duration*.7,0,'',animate);return;}rs.forEach((r,i)=>{const rng=markRng(seed+i*9973+101),duration=markDuration(action,r),delay=i*110;if(action==='underline'||action==='wave'){const y=r.y+r.height-Math.max(1.5,r.height*.08),d=handLine(r.x-1,y,r.x+r.width+1,y,action==='wave'?Math.max(5,r.height*.2):Math.max(3,r.height*.12),rng);animatedPath(group,d,stroke,markStroke(weight,5.2),.94,duration,delay,'',animate);}else if(action==='strike'){const y=r.y+r.height*.55,d=handLine(r.x-1,y,r.x+r.width+1,y,Math.max(3,r.height*.1),rng);animatedPath(group,d,stroke,markStroke(weight,4.8),.9,duration,delay,'',animate);}else{const y=r.y+r.height*.58,d=handLine(r.x-2,y,r.x+r.width+2,y,Math.max(4,r.height*.12),rng),width=markStroke(weight,Math.max(8,Math.min(18,r.height*.78)));animatedPath(group,d,fill,width,.42,duration,delay,'mix-blend-mode:multiply;',animate);}});}
      function removeMarks(){layer?.querySelector('#castreader-weread-marks-svg')?.remove();}
      function clearMarks(){currentMarks.clear();removeMarks();}
      function drawMark(a,animate=true){const rs=lines(rectsFor(visible[a.paragraphIndex],a.charStart,a.charEnd));if(!rs.length)return;const svg=markSvg(),id=String(a.id||'1');if(svg.querySelector(`[data-cr-weread-mark-id="${CSS.escape(id)}"]`))return;const group=document.createElementNS('http://www.w3.org/2000/svg','g');group.dataset.crWereadMarkId=id;svg.appendChild(group);drawHandMark(group,rs,a,animate);}
      function showMark(a){currentMarks.set(String(a.id||'1'),a);drawMark(a,true);}
      function restoreVisualState(){if(currentHighlight)applyHighlight(currentHighlight);for(const mark of currentMarks.values())drawMark(mark,false);}
      function scrollToParagraph(a){const p=visible[a.paragraphIndex];if(!p?.bounds)return;const host=root();if(host.querySelector('canvas'))return;const hr=host.getBoundingClientRect(),top=hr.top+p.bounds.y,bottom=top+p.bounds.height;if(top>innerHeight*.15&&bottom<innerHeight*.72)return;let s=host;while(s&&s!==document.body){const cs=getComputedStyle(s);if(/auto|scroll/.test(cs.overflowY)&&s.scrollHeight>s.clientHeight+4)break;s=s.parentElement;}const delta=top-innerHeight*(Number(a.anchor)||.3);if(s&&s!==document.body)s.scrollBy({top:delta,behavior:'smooth'});else window.scrollBy({top:delta,behavior:'smooth'});}

      function highlightWord(a){const p=visible[a.paragraphIndex];if(!p){clearHighlight();return;}if(wordState.para!==a.paragraphIndex)wordState={para:a.paragraphIndex,seg:a.segSeq,cursor:0,last:-1};const word=String((a.words||[])[a.wordIndex]||'').trim();if(!word)return;if(a.segSeq<wordState.seg||a.wordIndex<wordState.last)wordState.cursor=0;let at=p.text.toLocaleLowerCase().indexOf(word.toLocaleLowerCase(),wordState.cursor),length=word.length;if(at<0){const stripped=word.replace(/^[\s.,!?;:'“”‘’()\[\]]+|[\s.,!?;:'“”‘’()\[\]]+$/g,'');if(stripped.length>1){at=p.text.toLocaleLowerCase().indexOf(stripped.toLocaleLowerCase(),wordState.cursor);length=stripped.length;}}if(at>=0){wordState.cursor=at+length;currentHighlight={kind:'range',paragraphIndex:a.paragraphIndex,charStart:at,charEnd:at+length};applyHighlight(currentHighlight);}wordState.seg=a.segSeq;wordState.last=a.wordIndex;}
      window.CR={init(){wordState={para:-1,seg:-1,cursor:0,last:-1};currentHighlight=null;currentMarks.clear();},setActive(a){if(!a.active)clearHighlight();},setColor(a){if(a?.hex)color=a.hex;},clearHighlight,highlightRange(a){const resolved=resolveSegmentRange(visible[a.paragraphIndex],a);if(Array.isArray(a.segmentTexts)&&a.segmentTexts.length&&!resolved){clearHighlight();return;}currentHighlight={...a,kind:'range',charStart:resolved?.start??a.charStart,charEnd:resolved?.end??a.charEnd};applyHighlight(currentHighlight);},highlightWord,scrollTo:scrollToParagraph,clearMarks,showMark};
      window.CastReaderWeRead={nextPage(){const selectors=['.renderTarget_pager_button_right','.renderTarget_pager .renderTarget_pager_button:last-of-type','.readerFooter_button:last-child','.readerFooter .nextBtn'];let button=null;for(const sel of selectors){const candidate=document.querySelector(sel);if(candidate&&clean(candidate.textContent)==='下一页'){button=candidate;break;}}if(!button)button=Array.from(document.querySelectorAll('.renderTarget_pager button,button[class*=footer],button[class*=Footer]')).find(e=>clean(e.textContent)==='下一页');if(!button){post('wereadTurnRejected',{reason:'next-page-not-found'});return false;}clearHighlight();clearMarks();const id=`wr-${Date.now()}-${++turnID}`;post('wereadTurnRequested',{actionID:id,fingerprint:lastFingerprint,canvasEpoch:window.__castReaderWeReadCanvas?.snapshot?.().epoch||0});button.click();return true;},snapshot(){schedule('manual');return{fingerprint:lastFingerprint,ready:!!visible.length};},relayout(a){clearHighlight();clearMarks();stableCandidate='';lastPreviewKey='';const reason=String(a?.reason||'orientation');try{window.dispatchEvent(new Event('resize'));}catch(_){}schedule(reason);setTimeout(()=>schedule(reason+'-settled'),360);return true;},resumeAfterForeground(a){restoreVisualState();schedule(String(a?.reason||'foreground'));return true;}};
      // Measuring every character of every pre-render paragraph is expensive.
      // The old observer repeated that full pass for each mutation record,
      // blocking WeRead's own paint and making the native cover look like a
      // multi-second white screen. Coalesce mutations into one structural pass
      // and probe aggressively only until the first visible page is ready.
      let captureTimer=0,bootstrapTimer=0,bootstrapProbeIndex=0,transientFingerprints=[];
      function captureAll(){document.querySelectorAll(selectors).forEach(capture);}
      function requestCapture(){if(captureTimer)return;captureTimer=setTimeout(()=>{captureTimer=0;captureAll();},72);}
      // The complete chapter HTML exists only in `.preRenderContainer` and
      // WeRead removes that node as soon as it has painted the Canvas. A
      // debounced document scan is therefore too late: it sees only the
      // current Canvas and a small reader shell, which cannot predict the next
      // page. Capture transient pre-render nodes synchronously in the observer
      // callback (the same contract as the production Chrome extension), while
      // retaining the coalesced scan for ordinary layout mutations.
      function captureTransient(container){
        if(!(container instanceof Element))return;const text=clean(container.textContent),signature=hash(`${text.length}|${text.slice(0,160)}|${text.slice(-160)}`);if(transientFingerprints.includes(signature))return;transientFingerprints.push(signature);if(transientFingerprints.length>24)transientFingerprints.shift();remember(collect(container));
      }
      const observer=new MutationObserver(mutations=>{
        const transient=new Set();
        for(const mutation of mutations){
          const target=mutation.target instanceof Element?mutation.target:mutation.target?.parentElement,owner=target?.matches?.('.preRenderContainer')?target:target?.closest?.('.preRenderContainer');if(owner)transient.add(owner);
          for(const node of mutation.addedNodes||[]){if(!(node instanceof Element))continue;if(node.matches?.('.preRenderContainer'))transient.add(node);for(const container of node.querySelectorAll?.('.preRenderContainer')||[])transient.add(container);}
        }
        for(const container of transient)captureTransient(container);
        requestCapture();
      });
      const bootstrapProbeDelays=[80,160,280,440,680,980,1400,2100,3200,4800];
      function bootstrapProbe(){captureAll();if(visible.length)return;const delay=bootstrapProbeDelays[bootstrapProbeIndex++];if(delay==null)return;bootstrapTimer=setTimeout(bootstrapProbe,delay);}
      let lastManualIntentAt=0;
      function manualTurnIntent(event){const target=event.target instanceof Element?event.target.closest('.renderTarget_pager_button,.readerFooter_button,[class*=readerFooter],[class*=ReaderFooter]'):null,label=clean(target?.textContent);if(label!=='上一页'&&label!=='下一页')return;const now=Date.now();if(now-lastManualIntentAt<350)return;lastManualIntentAt=now;clearHighlight();clearMarks();post('wereadPageChanging',{reason:'manual-intent',direction:label==='下一页'?'next':'previous',previousFingerprint:lastFingerprint,canvasEpoch:window.__castReaderWeReadCanvas?.snapshot?.().epoch||0});}
      function begin(){observer.observe(document.documentElement,{childList:true,characterData:true,subtree:true});document.addEventListener('pointerdown',manualTurnIntent,true);document.addEventListener('touchstart',manualTurnIntent,true);bootstrapProbe();}
      window.addEventListener('castreader-weread-canvas',e=>schedule(e.detail?.reason||'canvas'));window.addEventListener('resize',()=>{removeHighlight();removeMarks();schedule('resize');});
      if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',begin,{once:true});else begin();post('ready',{site:'weread',bridge:'canvas-geometry-v2'});
    })();
    """#
}
