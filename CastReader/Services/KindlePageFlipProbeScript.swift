#if DEBUG
import Foundation

extension KindleWebScripts {
    static let offlineSourceNavigation = #"""
    (() => {
      let navigation = null, loading = true;
      for (const node of document.querySelectorAll('#kr-renderer,#kr-chevron-left,#kr-chevron-right,#kr-scrubber-bar')) {
        const key=Object.keys(node).find(k=>/^__react(Fiber|InternalInstance)\$/.test(k));
        let fiber=key&&node[key];
        let root=fiber; while(root?.return)root=root.return;
        if(root?.stateNode?.current&&root!==root.stateNode.current) fiber=fiber?.alternate||fiber;
        for(let depth=0;fiber&&depth<64;depth++,fiber=fiber.return) {
          const value=fiber.memoizedProps?.value;
          if(typeof value?.readerState?.isRendererLoading==='boolean') loading=value.readerState.isRendererLoading;
          if(typeof value?.moveToPosition==='function'&&typeof value?.nextPage==='function') navigation=value;
        }
      }
      if(!navigation) return null;
      const bar=document.querySelector('#kr-scrubber-bar');
      return {navigation, loading, minimum:Number(bar?.min),maximum:Number(bar?.max),
        current:navigation.state?.currentPosition,range:navigation.state?.pagePositionRange};
    })()
    """#

    static let offlineRendererProbeInstall = #"""
    (() => {
      const seen = new Set(); let service = null, navigation = null;
      for (const node of document.querySelectorAll('#kr-renderer,#kr-chevron-left,#kr-chevron-right,#kr-scrubber-bar')) {
        const key = Object.keys(node).find(k => /^__react(Fiber|InternalInstance)\$/.test(k));
        let fiber = key && node[key];
        let root=fiber; while(root?.return)root=root.return;
        if(root?.stateNode?.current&&root!==root.stateNode.current) fiber=fiber?.alternate||fiber;
        for (let depth = 0; fiber && depth < 64; depth++, fiber = fiber.return) {
          if (seen.has(fiber)) continue; seen.add(fiber);
          const props = fiber.memoizedProps;
          if (typeof props?.renderingService?.renderBookUsingToken === 'function') service = props.renderingService;
          if (typeof props?.value?.moveToPosition === 'function' && typeof props?.value?.nextPage === 'function') navigation = props.value;
        }
      }
      if (!service || !navigation) return JSON.stringify({ok:false, reason:'renderer-unavailable'});
      if (window.__crOfflineRendererProbe?.service === service) return JSON.stringify({ok:true, originalPosition:window.__crOfflineRendererProbe.originalPosition});
      function shape(value, depth = 0) {
        if (value == null) return null;
        if (typeof value === 'number' || typeof value === 'boolean') return value;
        if (typeof value === 'string') {
          if (/^-?\d+(\.\d+)?$/.test(value)) return Number(value);
          if (/^[\w/-]{1,100}\.(png|jpe?g|svg|json)$/.test(value)) return value;
          return {type:'string', length:value.length};
        }
        if (typeof value === 'function') return 'function/' + value.length;
        if (value instanceof ArrayBuffer || ArrayBuffer.isView(value)) return {type:value.constructor.name, bytes:value.byteLength};
        if (value instanceof Blob) return {type:'Blob', bytes:value.size};
        if (depth > 4) return {type:'object'};
        if (Array.isArray(value)) return {type:'array', length:value.length, first:shape(value[0],depth+1)};
        const out = {};
        for (const key of Object.keys(value).slice(0,60)) {
          if (/token|secret|auth|cookie|email|user|account/i.test(key)) continue;
          const d = Object.getOwnPropertyDescriptor(value,key);
          if (d && 'value' in d) out[key] = shape(d.value,depth+1);
        }
        return out;
      }
      function archiveShape(buffer) {
        const bytes = new Uint8Array(buffer), decoder = new TextDecoder(); let offset=0; const entries=[];
        while(offset+512<=bytes.length && entries.length<100) {
          const name=decoder.decode(bytes.slice(offset,offset+100)).replace(/\0.*$/,'');
          if(!name) break;
          const size=parseInt(decoder.decode(bytes.slice(offset+124,offset+136)).replace(/\0.*$/,'').trim(),8);
          if(!Number.isSafeInteger(size)||size<0||offset+512+size>bytes.length) break;
          const row={name,size};
          if(/\.json$/i.test(name)&&size<4000000) {
            try {
              const data=JSON.parse(decoder.decode(bytes.slice(offset+512,offset+512+size))); row.shape=shape(data);
              if(/tokens/i.test(name)&&Array.isArray(data)) row.pages=data.map(page=>{
                const starts=[],ends=[]; let nodes=0;
                function walk(v){ if(!v||typeof v!=='object'||nodes++>100000)return; if(Number.isFinite(v.startPositionId))starts.push(v.startPositionId); if(Number.isFinite(v.endPositionId))ends.push(v.endPositionId); if(Array.isArray(v))v.forEach(walk);else Object.keys(v).forEach(k=>walk(v[k])); }
                walk(page);
                return {pageIndex:page.pageIndex,minimum:starts.length?Math.min(...starts):null,maximum:ends.length?Math.max(...ends):null,top:shape({...page,children:undefined})};
              });
            } catch(_) {}
          }
          entries.push(row); offset+=512+Math.ceil(size/512)*512;
        }
        return {bytes:bytes.length,entries};
      }
      const original = service.renderBookUsingToken;
      const probe = {service, originalPosition:navigation.state.currentPosition, report:{ok:true, responses:0}};
      probe.restore = () => navigation.moveToPosition(probe.originalPosition);
      probe.begin = () => navigation.moveToPosition(0);
      service.renderBookUsingToken = async function(request, provider) {
        const response = await original.call(this,request,provider);
        probe.request = request; probe.provider = provider; probe.response = response;
        probe.report = {ok:true,responses:probe.report.responses+1,request:shape(request),response:shape(response),responseType:{constructor:response?.constructor?.name,tag:Object.prototype.toString.call(response),methods:Object.getOwnPropertyNames(Object.getPrototypeOf(response)||{}).filter(k=>typeof response[k]==='function')}};
        if(response instanceof Response) {
          const buffer=await response.clone().arrayBuffer();
          probe.buffer=buffer; probe.report.response={type:'Response',status:response.status,archive:archiveShape(buffer)};
        }
        probe.report.complete = true;
        return response;
      };
      window.__crOfflineRendererProbe = probe;
      return JSON.stringify({ok:true, originalPosition:probe.originalPosition});
    })()
    """#

    /// Read only: numeric navigation bounds and callable property names. No
    /// content, credentials, response bodies or URLs leave the reader.
    static let offlineSourceCapabilities = #"""
    (() => {
      const rows = [], seen = new Set(), imageRows = [], serviceRows = [];
      let navigationState = null, rendererMethods = {};
      function fields(value, depth = 0) {
        if (!value || typeof value !== 'object' || depth > 2) return {};
        const out = {};
        Object.keys(value).slice(0, 100).forEach(key => {
          if (!/^[a-zA-Z_][a-zA-Z0-9_]{0,60}$/.test(key) || /token|secret|auth|cookie|email|user|account|url|href|text|title|children/i.test(key)) return;
          const descriptor = Object.getOwnPropertyDescriptor(value, key);
          if (!descriptor || !('value' in descriptor)) return;
          const v = descriptor.value;
          if (typeof v === 'number' && Number.isFinite(v) || typeof v === 'boolean') out[key] = v;
          else if (typeof v === 'function') out[key] = 'function/' + v.length;
          else if (typeof v === 'string' && /^(ltr|rtl|vertical|horizontal|paginated|scroll)$/.test(v)) out[key] = v;
          else if (Array.isArray(v)) out[key] = {arrayLength:v.length};
          else if (v && typeof v === 'object' && /page|position|location|progress|render|book|state|value|context/i.test(key)) out[key] = fields(v, depth + 1);
        });
        return out;
      }
      for (const node of document.querySelectorAll('#kr-renderer,#kr-chevron-left,#kr-chevron-right,#kr-scrubber-bar,ion-range,[role="slider"],.kg-full-page-img,img[src^="blob:"]')) {
        const fiberKey = Object.keys(node).find(k => /^__react(Fiber|InternalInstance)\$/.test(k));
        let fiber = fiberKey && node[fiberKey], depth = 0;
        let root=fiber; while(root?.return)root=root.return;
        if(root?.stateNode?.current&&root!==root.stateNode.current) fiber=fiber?.alternate||fiber;
        while (fiber && depth++ < 50 && rows.length < 80) {
          if (!seen.has(fiber)) {
            seen.add(fiber);
            const context = fiber.memoizedProps?.value;
            if (typeof context?.moveToPosition === 'function' && typeof context?.nextPage === 'function') {
              navigationState = fields(context.state);
              for(const method of ['moveToPosition','moveToLocation','moveToPage']) rendererMethods['navigation.'+method]=String(context[method]).slice(0,3000);
            }
            const service = fiber.memoizedProps?.renderingService;
            if (service) {
              let prototype = service;
              for (let level = 0; prototype && level < 3; level++, prototype = Object.getPrototypeOf(prototype)) {
                for (const key of Object.getOwnPropertyNames(prototype)) {
                  if (key === 'constructor' || !/render|page|position|location|metadata/i.test(key)) continue;
                  const descriptor = Object.getOwnPropertyDescriptor(prototype, key);
                  if (typeof descriptor?.value === 'function') rendererMethods[key] = String(descriptor.value).slice(0, 2400);
                }
              }
            }
            const props = fiber.memoizedProps || {};
            if(depth<10) {
              const methods={};
              for(const key of Object.keys(props)) {
                const value=props[key];
                if(/render|image|page|raster|canvas/i.test(key)) {
                  if(typeof value==='function') methods[key]=String(value).slice(0,2200);
                  else if(value&&typeof value==='object'&&!Array.isArray(value)) {
                    let prototype=value; const names=[];
                    for(let level=0;prototype&&level<2;level++,prototype=Object.getPrototypeOf(prototype)) {
                      for(const method of Object.getOwnPropertyNames(prototype)) {
                        if(method==='constructor')continue;
                        const d=Object.getOwnPropertyDescriptor(prototype,method);
                        if(typeof d?.value==='function')names.push(method);
                      }
                    }
                    if(names.length)methods[key]=names;
                  }
                }
              }
              if(Object.keys(methods).length) serviceRows.push({depth,methods});
            }
            const values = fields(props);
            if (Object.keys(values).length) rows.push({depth, component:typeof fiber.type === 'string' ? fiber.type : 'component', fields:values});
          }
          fiber = fiber.return;
        }
      }
      let match = window.__crKindleFindPaginationActions?.();
      const controls = [...document.querySelectorAll('#kr-scrubber-bar,ion-range,[role="slider"],#kr-chevron-left,#kr-chevron-right')].slice(0, 12).map(el => {
        const value = {tag:el.tagName, id:el.id, disabled:el.disabled === true || el.getAttribute('aria-disabled') === 'true'};
        for (const key of ['min','max','value','step']) {
          const v = el[key] ?? el.getAttribute(key);
          if (v !== null && v !== '' && Number.isFinite(Number(v))) value[key] = Number(v);
        }
        return value;
      });
      return JSON.stringify({version:1, chromeLocked:document.documentElement.classList.contains('cr-kindle-page-mode-locked'),
        navigationState, rendererMethods, serviceRows,
        scripts:[...document.scripts].filter(s=>s.src).map(s=>{const u=new URL(s.src);return u.origin+u.pathname;}), pagination:fields(match?.props || window.__crKindleTurnCapability?.props), controls, rows});
    })()
    """#

    static let pageFlipProbeRingCapacity = 1_500
    static let pageFlipProbeDrainLimit = 100

    /// Installs the first-phase Kindle Page Flip probe. It observes only while a caller-owned
    /// run is active; opening, browsing, and closing Page Flip remain entirely manual. The
    /// emitted model contains structural hashes, short numeric positions, dimensions, and
    /// redacted request shapes -- never page text, response bodies, headers, or complete URLs.
    static let pageFlipProbeBootstrap = restrictedToKnownStorefronts(
        #"""
        (function() {
          'use strict';
          var VERSION = 1;
          var MAX_EVENTS = \#(pageFlipProbeRingCapacity);
          var MAX_DRAIN = \#(pageFlipProbeDrainLimit);
          var BOOTSTRAP_KEY = '__crKindlePFProbeBootstrapVersion';
          if (window.top !== window.self) return;
          if (window[BOOTSTRAP_KEY] === VERSION &&
              typeof window.__crKindlePFProbeStart === 'function' &&
              typeof window.__crKindlePFProbePoll === 'function' &&
              typeof window.__crKindlePFProbeStop === 'function') return;
          window[BOOTSTRAP_KEY] = VERSION;

          var controller = { state:null };

          function nowMs() {
            return Date.now ? Date.now() : new Date().getTime();
          }

          function finiteNumber(value, fallback) {
            value = Number(value);
            return Number.isFinite(value) ? value : fallback;
          }

          function boundedInteger(value, fallback, minimum, maximum) {
            value = Math.floor(finiteNumber(value, fallback));
            return Math.max(minimum, Math.min(maximum, value));
          }

          function hashString(value) {
            value = String(value || '');
            var hash = 2166136261;
            for (var index = 0; index < value.length; index++) {
              hash ^= value.charCodeAt(index);
              hash = Math.imul(hash, 16777619);
            }
            return (hash >>> 0).toString(16).padStart(8, '0');
          }

          function validRunID(value) {
            value = String(value || '');
            return value.length >= 8 && value.length <= 80 && /^[A-Za-z0-9._:-]+$/.test(value)
              ? value
              : '';
          }

          function safeStringify(value) {
            try { return JSON.stringify(value); }
            catch (_) {
              return '{"ok":false,"version":1,"runID":"","active":false,"seq":0,' +
                '"droppedBeforeSeq":0,"hasMore":false,"snapshot":null,"events":[],' +
                '"error":"serialization_failed"}';
            }
          }

          function rejected(runID, error) {
            return safeStringify({
              ok:false,
              version:VERSION,
              runID:String(runID || '').slice(0, 80),
              active:!!(controller.state && controller.state.active),
              seq:controller.state ? controller.state.seq : 0,
              droppedBeforeSeq:controller.state ? controller.state.droppedBeforeSeq : 0,
              hasMore:false,
              snapshot:null,
              events:[],
              error:error
            });
          }

          function emit(state, kind, payload) {
            if (!state || !state.active) return;
            state.seq += 1;
            state.events.push({ seq:state.seq, atMs:nowMs(), kind:kind, payload:payload || null });
            if (state.events.length > MAX_EVENTS) {
              var removed = state.events.splice(0, state.events.length - MAX_EVENTS);
              if (removed.length) state.droppedBeforeSeq = removed[removed.length - 1].seq;
            }
          }

          function emitError(state, stage, error) {
            var name = '';
            var length = 0;
            try {
              name = String(error && error.name || 'Error');
              length = String(error && error.message || '').length;
            } catch (_) {}
            emit(state, 'error', {
              stage:String(stage || '').slice(0, 40),
              nameHash:'e-' + hashString(name),
              messageLength:Math.min(4096, length)
            });
          }

          function rawAttribute(element, name) {
            try { return String(element && element.getAttribute && element.getAttribute(name) || '').slice(0, 256); }
            catch (_) { return ''; }
          }

          function attributeProbe(element) {
            if (!element) return '';
            return [
              rawAttribute(element, 'id'),
              rawAttribute(element, 'class'),
              rawAttribute(element, 'role'),
              rawAttribute(element, 'data-testid'),
              rawAttribute(element, 'data-test'),
              rawAttribute(element, 'data-component'),
              rawAttribute(element, 'aria-label'),
              rawAttribute(element, 'title')
            ].join(' ').toLowerCase();
          }

          function hasPageFlipWords(element) {
            return /page[\s_-]*flip|page[\s_-]*map|multi[\s_-]*page|thumbnail|thumb[\s_-]*grid|overview|navigator/.test(
              attributeProbe(element)
            );
          }

          function controlledRole(element) {
            var role = rawAttribute(element, 'role').toLowerCase();
            return /^(dialog|grid|list|listbox|region|group|presentation)$/.test(role) ? role : '';
          }

          function shortPosition(value) {
            value = String(value || '').trim();
            if (!value || value.length > 16) return null;
            return /^(?:[0-9]{1,9}|[ivxlcdm]{1,12})$/i.test(value) ? value.toUpperCase() : null;
          }

          function firstShortAttribute(element, names) {
            for (var index = 0; index < names.length; index++) {
              var value = shortPosition(rawAttribute(element, names[index]));
              if (value !== null) return value;
            }
            return null;
          }

          function firstIntegerAttribute(element, names) {
            var value = firstShortAttribute(element, names);
            if (value === null || !/^[0-9]+$/.test(value)) return null;
            var number = Number(value);
            return Number.isSafeInteger(number) && number >= 0 && number <= 100000 ? number : null;
          }

          function rectOf(element) {
            try {
              var rect = element && element.getBoundingClientRect ? element.getBoundingClientRect() : null;
              if (!rect) return null;
              return {
                left:finiteNumber(rect.left, 0),
                top:finiteNumber(rect.top, 0),
                right:finiteNumber(rect.right, 0),
                bottom:finiteNumber(rect.bottom, 0),
                width:Math.max(0, finiteNumber(rect.width, 0)),
                height:Math.max(0, finiteNumber(rect.height, 0))
              };
            } catch (_) { return null; }
          }

          function isRendered(element, rect) {
            try {
              if (!element || !element.isConnected || !rect || rect.width < 8 || rect.height < 8) return false;
              var style = getComputedStyle(element);
              if (!style || style.display === 'none' || style.visibility === 'hidden' ||
                  Number(style.opacity || 1) <= 0.01) return false;
              var viewportWidth = Math.max(1, finiteNumber(innerWidth, 1));
              var viewportHeight = Math.max(1, finiteNumber(innerHeight, 1));
              return rect.right > 0 && rect.bottom > 0 &&
                rect.left < viewportWidth && rect.top < viewportHeight;
            } catch (_) { return false; }
          }

          function nodeKey(state, node) {
            if (!node) return '';
            var key = state.nodeKeys.get(node);
            if (!key) {
              state.nodeSeq += 1;
              key = 'n-' + state.nodeSeq.toString(36);
              state.nodeKeys.set(node, key);
            }
            return key;
          }

          function collectContexts(state) {
            var documents = [];
            var roots = [];
            var seenDocuments = new Set();
            var seenRoots = new Set();
            var queue = [];
            var frame = { sameOrigin:0, crossOrigin:0, openShadowRoots:0, closedShadowSuspected:false };

            function addDocument(doc, win) {
              if (!doc || seenDocuments.has(doc) || documents.length >= 12) return;
              seenDocuments.add(doc);
              documents.push({ doc:doc, win:win });
              queue.push({ doc:doc, win:win });
            }

            function addRoot(root) {
              if (!root || seenRoots.has(root) || roots.length >= 64) return;
              seenRoots.add(root);
              roots.push(root);
            }

            addDocument(document, window);
            for (var queueIndex = 0; queueIndex < queue.length && queueIndex < 12; queueIndex++) {
              var context = queue[queueIndex];
              addRoot(context.doc);
              var frames = [];
              try { frames = Array.from(context.doc.querySelectorAll('iframe')).slice(0, 32); }
              catch (_) {}
              frames.forEach(function(frameElement) {
                try {
                  var childDocument = frameElement.contentDocument;
                  var childWindow = frameElement.contentWindow;
                  if (!childDocument || !childDocument.documentElement) throw new Error('unavailable');
                  frame.sameOrigin += 1;
                  addDocument(childDocument, childWindow);
                } catch (_) {
                  frame.crossOrigin += 1;
                  var frameRect = rectOf(frameElement);
                  if (hasPageFlipWords(frameElement) && frameRect &&
                      frameRect.width * frameRect.height > innerWidth * innerHeight * 0.20) {
                    frame.closedShadowSuspected = true;
                  }
                }
              });
            }

            documents.forEach(function(context) {
              var all = [];
              try { all = Array.from(context.doc.querySelectorAll('*')).slice(0, 6000); }
              catch (_) {}
              all.forEach(function(element) {
                try {
                  if (element.shadowRoot) {
                    frame.openShadowRoots += 1;
                    addRoot(element.shadowRoot);
                  } else if (String(element.tagName || '').indexOf('-') >= 0 && hasPageFlipWords(element)) {
                    frame.closedShadowSuspected = true;
                  }
                } catch (_) {}
              });
            });
            return { documents:documents, roots:roots, frame:frame };
          }

          function sourceForElement(element) {
            try {
              var tag = String(element.tagName || '').toLowerCase();
              if (tag === 'img') return String(element.currentSrc || element.src || '');
              var background = String(getComputedStyle(element).backgroundImage || '');
              var match = background.match(/^url\(["']?(.*?)["']?\)$/i);
              return match ? String(match[1] || '') : '';
            } catch (_) { return ''; }
          }

          function schemeForSource(source) {
            source = String(source || '').trim().toLowerCase();
            if (!source) return 'none';
            if (source.indexOf('https:') === 0) return 'https';
            if (source.indexOf('blob:') === 0) return 'blob';
            if (source.indexOf('data:') === 0) return 'data';
            return 'other';
          }

          function visualKind(element) {
            var tag = String(element && element.tagName || '').toLowerCase();
            if (tag === 'img') return 'image';
            if (tag === 'canvas') return 'canvas';
            if (tag === 'svg') return 'svg';
            return 'background';
          }

          function naturalSize(element, kind) {
            try {
              if (kind === 'image') {
                return {
                  width:Math.max(0, Math.round(finiteNumber(element.naturalWidth, 0))),
                  height:Math.max(0, Math.round(finiteNumber(element.naturalHeight, 0)))
                };
              }
              if (kind === 'canvas') {
                return {
                  width:Math.max(0, Math.round(finiteNumber(element.width, 0))),
                  height:Math.max(0, Math.round(finiteNumber(element.height, 0)))
                };
              }
              if (kind === 'svg' && element.viewBox && element.viewBox.baseVal) {
                return {
                  width:Math.max(0, Math.round(finiteNumber(element.viewBox.baseVal.width, 0))),
                  height:Math.max(0, Math.round(finiteNumber(element.viewBox.baseVal.height, 0)))
                };
              }
            } catch (_) {}
            return null;
          }

          function imageEvidence(state, element, rect) {
            var kind = visualKind(element);
            var source = sourceForElement(element);
            var scheme = schemeForSource(source);
            var blob = source ? state.blobs.get(source) : null;
            var natural = naturalSize(element, kind);
            var complete = true;
            try { if (kind === 'image') complete = !!element.complete && !!natural && natural.width > 0; }
            catch (_) { complete = false; }
            return {
              kind:kind,
              scheme:scheme,
              blobKey:blob ? blob.key : (scheme === 'blob' ? 'b-' + hashString(source) : null),
              natural:natural,
              rendered:{ width:Math.round(rect.width), height:Math.round(rect.height) },
              complete:complete,
              byteSize:blob ? blob.byteSize : null
            };
          }

          function isHighResolution(image) {
            if (!image || !image.complete || !image.natural) return false;
            var width = finiteNumber(image.natural.width, 0);
            var height = finiteNumber(image.natural.height, 0);
            return Math.min(width, height) >= 900 && Math.max(width, height) >= 1200 &&
              width * height >= 1200000;
          }

          function normalizedRect(rect) {
            var width = Math.max(1, finiteNumber(innerWidth, 1));
            var height = Math.max(1, finiteNumber(innerHeight, 1));
            return {
              x:rect.left / width,
              y:rect.top / height,
              width:rect.width / width,
              height:rect.height / height
            };
          }

          function cellForVisual(element, rect) {
            var best = element;
            var node = element;
            for (var depth = 0; depth < 4 && node && node.parentElement; depth++) {
              var parent = node.parentElement;
              var parentRect = rectOf(parent);
              if (!parentRect || parentRect.width < rect.width || parentRect.height < rect.height) break;
              if (parentRect.width > innerWidth * 0.72 || parentRect.height > innerHeight * 0.90) break;
              best = parent;
              node = parent;
            }
            return best;
          }

          function visualEntries(contexts) {
            var entries = [];
            var seen = new Set();
            contexts.roots.forEach(function(root) {
              if (entries.length >= 800) return;
              var elements = [];
              try {
                elements = Array.from(root.querySelectorAll(
                  'img,canvas,svg,[role="img"],[style*="background-image" i]'
                )).slice(0, 800);
              } catch (_) {}
              elements.forEach(function(element) {
                if (entries.length >= 800 || seen.has(element)) return;
                seen.add(element);
                var rect = rectOf(element);
                if (!isRendered(element, rect)) return;
                entries.push({ element:element, rect:rect, cell:cellForVisual(element, rect) });
              });
            });
            return entries;
          }

          function columnCount(cells) {
            var centers = cells.map(function(cell) {
              var rect = rectOf(cell);
              return rect ? rect.left + rect.width / 2 : 0;
            }).sort(function(left, right) { return left - right; });
            var columns = [];
            var tolerance = Math.max(24, innerWidth * 0.08);
            centers.forEach(function(center) {
              if (!columns.length || Math.abs(center - columns[columns.length - 1]) > tolerance) {
                columns.push(center);
              }
            });
            return columns.length;
          }

          function rootCandidate(state, entries) {
            var candidates = new Map();
            var viewportArea = Math.max(1, innerWidth * innerHeight);
            entries.forEach(function(entry) {
              var area = entry.rect.width * entry.rect.height;
              if (area > viewportArea * 0.38 || entry.rect.width > innerWidth * 0.72 ||
                  entry.rect.height > innerHeight * 0.90) return;
              var cell = entry.cell;
              for (var depth = 0, node = cell && cell.parentElement;
                   node && depth < 7 && node !== document.body && node !== document.documentElement;
                   depth++, node = node.parentElement) {
                var record = candidates.get(node);
                if (!record) {
                  record = { element:node, cells:new Map() };
                  candidates.set(node, record);
                }
                record.cells.set(nodeKey(state, cell), cell);
              }
            });

            var best = null;
            candidates.forEach(function(record) {
              var cells = Array.from(record.cells.values());
              if (cells.length < 4 || columnCount(cells) < 2) return;
              var rect = rectOf(record.element);
              if (!isRendered(record.element, rect) ||
                  rect.width * rect.height < viewportArea * 0.12) return;
              var signals = ['fourSmallPages', 'twoColumns'];
              var score = 4;
              if (hasPageFlipWords(record.element)) { score += 3; signals.push('pageFlipToken'); }
              var role = controlledRole(record.element);
              if (role === 'grid' || role === 'list' || role === 'listbox') {
                score += 1; signals.push('collectionRole');
              }
              var scrollable = record.element.scrollHeight > record.element.clientHeight + 8;
              if (scrollable) { score += 2; signals.push('verticalRange'); }
              if (cells.length >= 6) { score += 1; signals.push('sixPages'); }
              if (score < 5) return;
              var value = {
                element:record.element,
                cells:cells,
                score:score,
                confidence:Math.min(0.99, score / 10),
                signals:signals,
                role:role,
                rect:rect
              };
              if (!best || value.score > best.score ||
                  (value.score === best.score && cells.length > best.cells.length)) best = value;
            });
            return best;
          }

          function cellEvidence(state, cell, visual) {
            var rect = rectOf(cell) || visual.rect;
            var ordinal = firstIntegerAttribute(cell, [
              'aria-posinset', 'data-page-index', 'data-index', 'data-ordinal', 'data-page'
            ]);
            if (ordinal === null) {
              ordinal = firstIntegerAttribute(visual.element, [
                'aria-posinset', 'data-page-index', 'data-index', 'data-ordinal', 'data-page'
              ]);
            }
            var setSize = firstIntegerAttribute(cell, [
              'aria-setsize', 'data-page-count', 'data-total-pages', 'data-count'
            ]);
            var image = imageEvidence(state, visual.element, visual.rect);
            return {
              nodeKey:nodeKey(state, cell),
              ordinal:ordinal,
              setSize:setSize,
              location:firstShortAttribute(cell, ['data-location', 'data-loc', 'location']),
              startPosition:firstShortAttribute(cell, [
                'data-start-position', 'data-starting-position', 'data-start'
              ]),
              endPosition:firstShortAttribute(cell, ['data-end-position', 'data-end']),
              pageNumber:firstShortAttribute(cell, [
                'data-page-number', 'aria-label', 'data-label'
              ]),
              norm:normalizedRect(rect),
              image:image
            };
          }

          function identityForCell(cell) {
            if (cell.ordinal !== null) return 'o:' + cell.ordinal;
            if (cell.startPosition) return 's:' + cell.startPosition + ':' + String(cell.endPosition || '');
            if (cell.location) return 'l:' + cell.location;
            if (cell.pageNumber) return 'p:' + cell.pageNumber;
            if (cell.image && cell.image.blobKey) return 'b:' + cell.image.blobKey;
            return 'n:' + cell.nodeKey;
          }

          function declaredTotalFor(candidate, cells) {
            var total = firstIntegerAttribute(candidate.element, [
              'aria-setsize', 'data-page-count', 'data-total-pages', 'data-count'
            ]);
            cells.forEach(function(cell) {
              if (cell.setSize !== null && (total === null || cell.setSize > total)) total = cell.setSize;
            });
            return total;
          }

          function scrollEvidence(state, element) {
            var top = Math.max(0, finiteNumber(element && element.scrollTop, 0));
            var clientHeight = Math.max(0, finiteNumber(element && element.clientHeight, 0));
            var scrollHeight = Math.max(clientHeight, finiteNumber(element && element.scrollHeight, clientHeight));
            return {
              nodeKey:nodeKey(state, element),
              top:top,
              clientHeight:clientHeight,
              scrollHeight:scrollHeight,
              atStart:top <= 2,
              atEnd:top + clientHeight >= scrollHeight - 2
            };
          }

          function rootEvidence(state, candidate, cells) {
            return {
              nodeKey:nodeKey(state, candidate.element),
              tag:String(candidate.element.tagName || '').toLowerCase().slice(0, 24),
              role:candidate.role || null,
              confidence:candidate.confidence,
              signals:candidate.signals.slice(0, 12),
              scroll:scrollEvidence(state, candidate.element),
              declaredTotal:declaredTotalFor(candidate, cells)
            };
          }

          function readerEvidence(state, entries) {
            var pageKey = '';
            var navigationSeq = null;
            try {
              if (typeof window.__crKindleState === 'function') {
                var existing = window.__crKindleState();
                if (typeof existing === 'string') existing = JSON.parse(existing);
                if (existing && existing.key) pageKey = 'p-' + hashString(existing.key);
                if (existing && Number.isFinite(Number(existing.navigationSeq))) {
                  navigationSeq = Number(existing.navigationSeq);
                }
              }
            } catch (_) {}
            if (!pageKey) {
              var viewportArea = Math.max(1, innerWidth * innerHeight);
              for (var index = 0; index < entries.length; index++) {
                var entry = entries[index];
                if (entry.rect.width * entry.rect.height < viewportArea * 0.35) continue;
                var position = firstShortAttribute(entry.element, [
                  'data-location', 'data-start-position', 'data-page-number', 'data-page'
                ]);
                if (position) { pageKey = 'p-' + hashString(position); break; }
              }
            }
            var stable = null;
            if (state.initialReader.pageKey && pageKey) {
              stable = state.initialReader.pageKey === pageKey;
              if (stable && state.initialReader.navigationSeq !== null && navigationSeq !== null) {
                stable = state.initialReader.navigationSeq === navigationSeq;
              }
            } else if (state.initialReader.navigationSeq !== null && navigationSeq !== null) {
              stable = state.initialReader.navigationSeq === navigationSeq;
            }
            return {
              pageKey:pageKey || null,
              navigationSeq:navigationSeq,
              initialPageKey:state.initialReader.pageKey || null,
              initialNavigationSeq:state.initialReader.navigationSeq,
              positionStable:stable
            };
          }

          function rememberReader(state, reader) {
            var fingerprint = [reader.pageKey || '', reader.navigationSeq].join(':');
            if (state.lastReaderFingerprint && state.lastReaderFingerprint !== fingerprint) {
              emit(state, 'navigationChanged', {
                pageKey:reader.pageKey,
                navigationSeq:reader.navigationSeq,
                positionStable:reader.positionStable
              });
            }
            state.lastReaderFingerprint = fingerprint;
          }

          function rememberCells(state, root, cells) {
            var identities = [];
            cells.forEach(function(cell) {
              var identity = identityForCell(cell);
              identities.push(identity);
              state.observedCells.add(identity);
              if (cell.ordinal !== null) state.ordinals.add(cell.ordinal);
              if (cell.setSize !== null && cell.setSize > 0) {
                state.declaredTotal = Math.max(state.declaredTotal || 0, cell.setSize);
              }
              if (cell.image && cell.image.scheme !== 'none') state.directImages.add(identity);
              if (isHighResolution(cell.image)) state.directHighResolutionImages.add(identity);
              var rendererFingerprint = safeStringify(cell.image);
              if (state.rendererFingerprints.get(identity) !== rendererFingerprint) {
                state.rendererFingerprints.set(identity, rendererFingerprint);
                emit(state, 'renderer', {
                  nodeKey:cell.nodeKey,
                  role:'cell',
                  image:cell.image
                });
              }
            });
            var fingerprint = identities.sort().join('|');
            if (state.lastCellsFingerprint !== fingerprint) {
              state.lastCellsFingerprint = fingerprint;
              emit(state, 'cellsObserved', {
                rootNodeKey:root.nodeKey,
                count:cells.length,
                ordinalCount:cells.filter(function(cell) { return cell.ordinal !== null; }).length,
                declaredTotal:root.declaredTotal
              });
            }
            state.maxCellCount = Math.max(state.maxCellCount, cells.length);
            if (root.declaredTotal !== null) {
              state.declaredTotal = Math.max(state.declaredTotal || 0, root.declaredTotal);
            }
            state.sawStart = state.sawStart || root.scroll.atStart;
            state.sawEnd = state.sawEnd || root.scroll.atEnd;
            var scrollFingerprint = [
              root.scroll.nodeKey,
              Math.round(root.scroll.top),
              Math.round(root.scroll.clientHeight),
              Math.round(root.scroll.scrollHeight),
              root.scroll.atStart,
              root.scroll.atEnd
            ].join(':');
            if (state.lastScrollFingerprint !== scrollFingerprint) {
              state.lastScrollFingerprint = scrollFingerprint;
              emit(state, 'scrollObserved', root.scroll);
            }
          }

          function rememberPreview(state, candidate, entries, cellNodes) {
            var viewportArea = Math.max(1, innerWidth * innerHeight);
            entries.forEach(function(entry) {
              if (cellNodes.has(entry.cell) || !candidate.element.contains(entry.element)) return;
              if (entry.rect.width * entry.rect.height < viewportArea * 0.35) return;
              var image = imageEvidence(state, entry.element, entry.rect);
              var key = nodeKey(state, entry.element);
              var fingerprint = safeStringify(image);
              if (state.previewFingerprints.get(key) !== fingerprint) {
                state.previewFingerprints.set(key, fingerprint);
                emit(state, 'renderer', { nodeKey:key, role:'preview', image:image });
              }
              if (isHighResolution(image)) state.previewHighResolutionSeen = true;
            });
          }

          function gapCount(ordinals) {
            var values = Array.from(ordinals).sort(function(left, right) { return left - right; });
            var gaps = 0;
            for (var index = 1; index < values.length; index++) {
              if (values[index] > values[index - 1] + 1) {
                gaps += values[index] - values[index - 1] - 1;
              }
            }
            return gaps;
          }

          function summaryFor(state) {
            var ordinals = Array.from(state.ordinals).sort(function(left, right) { return left - right; });
            return {
              pageFlipCandidateSeen:state.pageFlipCandidateSeen,
              pageFlipConfirmed:state.pageFlipConfirmed,
              sawStart:state.sawStart,
              sawEnd:state.sawEnd,
              observedCellCount:state.observedCells.size,
              ordinalCount:ordinals.length,
              firstOrdinal:ordinals.length ? ordinals[0] : null,
              lastOrdinal:ordinals.length ? ordinals[ordinals.length - 1] : null,
              declaredTotal:state.declaredTotal || null,
              ordinalGapCount:gapCount(state.ordinals),
              directImageCount:state.directImages.size,
              directHighResolutionImageCount:state.directHighResolutionImages.size,
              previewHighResolutionSeen:state.previewHighResolutionSeen,
              networkImageCount:state.networkImageCount,
              blobCount:state.blobCount
            };
          }

          function snapshotFor(state, mode, contexts, reader, root, cells) {
            return {
              atMs:nowMs(),
              mode:mode,
              frame:contexts.frame,
              reader:reader,
              root:root,
              cells:cells,
              summary:summaryFor(state)
            };
          }

          function scan(state, reason) {
            if (!state || !state.active || state.scanning) return state && state.snapshot;
            state.scanning = true;
            try {
              var contexts = collectContexts(state);
              contexts.roots.forEach(function(root) {
                try {
                  if (!state.observedRoots.has(root)) {
                    state.observedRoots.add(root);
                    state.mutationObserver.observe(root, { childList:true, subtree:true, attributes:true });
                  }
                } catch (_) {}
              });
              contexts.documents.forEach(function(context) { recordPerformance(state, context.win); });
              var entries = visualEntries(contexts);
              var candidate = rootCandidate(state, entries);
              var root = null;
              var cells = [];
              var mode = 'reader';
              if (candidate) {
                state.pageFlipCandidateSeen = true;
                var candidateKey = nodeKey(state, candidate.element);
                var hits = Number(state.rootHits.get(candidateKey) || 0) + 1;
                state.rootHits.set(candidateKey, hits);
                mode = hits >= 2 ? 'pageFlipConfirmed' : 'pageFlipCandidate';
                if (mode === 'pageFlipConfirmed') state.pageFlipConfirmed = true;
                var entryByCell = new Map();
                entries.forEach(function(entry) {
                  if (candidate.cells.indexOf(entry.cell) < 0 || entryByCell.has(entry.cell)) return;
                  entryByCell.set(entry.cell, entry);
                });
                cells = Array.from(entryByCell.entries()).map(function(pair) {
                  return cellEvidence(state, pair[0], pair[1]);
                }).slice(0, 160);
                root = rootEvidence(state, candidate, cells);
                rememberCells(state, root, cells);
                rememberPreview(state, candidate, entries, new Set(candidate.cells));
              }
              var reader = readerEvidence(state, entries);
              rememberReader(state, reader);
              if (state.lastMode !== mode) {
                emit(state, 'modeChanged', { from:state.lastMode || null, to:mode });
                state.lastMode = mode;
              }
              var rootFingerprint = root ? safeStringify(root) : '';
              if (state.lastRootFingerprint !== rootFingerprint) {
                emit(state, 'rootChanged', root);
                state.lastRootFingerprint = rootFingerprint;
              }
              state.snapshot = snapshotFor(state, mode, contexts, reader, root, cells);
              return state.snapshot;
            } catch (error) {
              emitError(state, String(reason || 'scan').slice(0, 32), error);
              return state.snapshot;
            } finally {
              state.scanning = false;
            }
          }

          function scheduleScan(state, reason) {
            if (!state || !state.active || state.scanTimer) return;
            state.scanTimer = setTimeout(function() {
              state.scanTimer = 0;
              scan(state, reason);
            }, 80);
          }

          function safeMime(value) {
            value = String(value || '').split(';')[0].trim().toLowerCase();
            return /^[a-z0-9.+-]{1,40}\/[a-z0-9.+-]{1,50}$/.test(value) ? value : '';
          }

          function extensionMime(path) {
            path = String(path || '').toLowerCase();
            if (/\.(?:jpg|jpeg)$/.test(path)) return 'image/jpeg';
            if (/\.png$/.test(path)) return 'image/png';
            if (/\.webp$/.test(path)) return 'image/webp';
            if (/\.gif$/.test(path)) return 'image/gif';
            if (/\.avif$/.test(path)) return 'image/avif';
            if (/\.svg$/.test(path)) return 'image/svg+xml';
            return '';
          }

          function redactedRequest(rawURL) {
            try {
              var url = new URL(String(rawURL || ''), location.href);
              var safeSegments = new Set([
                'api', 'book', 'books', 'content', 'image', 'images', 'kindle', 'manifest',
                'metadata', 'page', 'pages', 'preview', 'reader', 'renderer', 'thumbnail', 'thumbnails'
              ]);
              var path = url.pathname.split('/').filter(Boolean).slice(0, 12).map(function(segment) {
                var decoded = '';
                try { decoded = decodeURIComponent(segment); } catch (_) { decoded = segment; }
                var lower = decoded.toLowerCase();
                var extension = (lower.match(/\.[a-z0-9]{1,6}$/) || [''])[0];
                if (safeSegments.has(lower)) return lower;
                return '~' + hashString(decoded) + ':' + Math.min(decoded.length, 999) + extension;
              });
              var queryNames = [];
              var startingPosition = null;
              url.searchParams.forEach(function(value, name) {
                name = String(name || '').slice(0, 50);
                if (/^[A-Za-z][A-Za-z0-9_.-]{0,49}$/.test(name) && queryNames.indexOf(name) < 0) {
                  queryNames.push(name);
                }
                if (/^(?:startingPosition|startPosition|start|position|location)$/i.test(name)) {
                  var safe = shortPosition(value);
                  if (safe !== null) startingPosition = safe;
                }
              });
              queryNames.sort();
              var safePath = '/' + path.join('/');
              return {
                path:safePath,
                queryNames:queryNames.slice(0, 32),
                startingPosition:startingPosition,
                inferredMime:extensionMime(url.pathname)
              };
            } catch (_) {
              return { path:'/~invalid', queryNames:[], startingPosition:null, inferredMime:'' };
            }
          }

          function recordNetwork(state, rawURL, status, mime, bytes, duration) {
            if (!state || !state.active) return;
            var redacted = redactedRequest(rawURL);
            mime = safeMime(mime) || redacted.inferredMime;
            bytes = Math.max(0, Math.round(finiteNumber(bytes, 0)));
            duration = Math.max(0, finiteNumber(duration, 0));
            var payload = {
              path:redacted.path,
              queryNames:redacted.queryNames,
              status:boundedInteger(status, 0, 0, 999),
              mime:mime || null,
              bytes:bytes,
              duration:duration,
              startingPosition:redacted.startingPosition
            };
            var fingerprint = safeStringify(payload);
            if (state.networkFingerprints.has(fingerprint)) return;
            state.networkFingerprints.add(fingerprint);
            if (mime.indexOf('image/') === 0) state.networkImageCount += 1;
            emit(state, 'network', payload);
          }

          function recordPerformance(state, targetWindow) {
            try {
              if (!targetWindow || !targetWindow.performance) return;
              var entries = targetWindow.performance.getEntriesByType('resource').slice(-500);
              entries.forEach(function(entry) {
                var bytes = Math.max(
                  finiteNumber(entry.transferSize, 0),
                  finiteNumber(entry.encodedBodySize, 0),
                  finiteNumber(entry.decodedBodySize, 0)
                );
                recordNetwork(
                  state,
                  entry.name,
                  finiteNumber(entry.responseStatus, 0),
                  '',
                  bytes,
                  finiteNumber(entry.duration, 0)
                );
              });
            } catch (error) { emitError(state, 'performance_entries', error); }
          }

          function installPerformanceObserver(state) {
            try {
              if (typeof PerformanceObserver !== 'function') return;
              state.performanceObserver = new PerformanceObserver(function(list) {
                list.getEntries().forEach(function(entry) {
                  var bytes = Math.max(
                    finiteNumber(entry.transferSize, 0),
                    finiteNumber(entry.encodedBodySize, 0),
                    finiteNumber(entry.decodedBodySize, 0)
                  );
                  recordNetwork(
                    state,
                    entry.name,
                    finiteNumber(entry.responseStatus, 0),
                    '',
                    bytes,
                    finiteNumber(entry.duration, 0)
                  );
                });
              });
              try { state.performanceObserver.observe({ type:'resource', buffered:true }); }
              catch (_) { state.performanceObserver.observe({ entryTypes:['resource'] }); }
            } catch (error) { emitError(state, 'performance_observer', error); }
          }

          function installFetchObserver(state) {
            try {
              if (typeof window.fetch !== 'function') return;
              state.originalFetch = window.fetch;
              state.fetchWrapper = function() {
                var args = arguments;
                var rawURL = '';
                try { rawURL = String(args[0] && args[0].url || args[0] || ''); } catch (_) {}
                var started = finiteNumber(performance && performance.now && performance.now(), 0);
                return state.originalFetch.apply(this, args).then(function(response) {
                  var mime = '';
                  var bytes = 0;
                  try {
                    mime = response.headers.get('content-type') || '';
                    bytes = Number(response.headers.get('content-length') || 0);
                  } catch (_) {}
                  var ended = finiteNumber(performance && performance.now && performance.now(), started);
                  recordNetwork(state, rawURL, response.status, mime, bytes, ended - started);
                  return response;
                }, function(error) {
                  var ended = finiteNumber(performance && performance.now && performance.now(), started);
                  recordNetwork(state, rawURL, 0, '', 0, ended - started);
                  throw error;
                });
              };
              window.fetch = state.fetchWrapper;
            } catch (error) { emitError(state, 'fetch_observer', error); }
          }

          function installXHRObserver(state) {
            try {
              var prototype = window.XMLHttpRequest && window.XMLHttpRequest.prototype;
              if (!prototype || typeof prototype.open !== 'function') return;
              state.xhrPrototype = prototype;
              state.originalXHROpen = prototype.open;
              state.xhrMetadata = new WeakMap();
              state.xhrOpenWrapper = function(method, rawURL) {
                var xhr = this;
                var started = 0;
                try { state.xhrMetadata.set(xhr, { url:String(rawURL || '') }); } catch (_) {}
                try {
                  xhr.addEventListener('loadstart', function() {
                    started = finiteNumber(performance && performance.now && performance.now(), 0);
                  }, { once:true });
                  xhr.addEventListener('loadend', function() {
                    var metadata = state.xhrMetadata.get(xhr) || { url:'' };
                    var mime = '';
                    var bytes = 0;
                    try {
                      mime = xhr.getResponseHeader('content-type') || '';
                      bytes = Number(xhr.getResponseHeader('content-length') || 0);
                    } catch (_) {}
                    var ended = finiteNumber(performance && performance.now && performance.now(), started);
                    recordNetwork(state, metadata.url, xhr.status, mime, bytes, ended - started);
                  }, { once:true });
                } catch (_) {}
                return state.originalXHROpen.apply(xhr, arguments);
              };
              prototype.open = state.xhrOpenWrapper;
            } catch (error) { emitError(state, 'xhr_observer', error); }
          }

          function installBlobObserver(state) {
            try {
              if (!window.URL || typeof window.URL.createObjectURL !== 'function') return;
              state.originalCreateObjectURL = window.URL.createObjectURL;
              state.createObjectURLWrapper = function(object) {
                var result = state.originalCreateObjectURL.apply(this, arguments);
                try {
                  if (state.active && object instanceof Blob) {
                    var mime = safeMime(object.type);
                    var byteSize = Math.max(0, Math.round(finiteNumber(object.size, 0)));
                    var key = 'b-' + hashString(result + ':' + byteSize + ':' + mime);
                    state.blobs.set(String(result), { key:key, byteSize:byteSize, mime:mime });
                    state.blobCount += 1;
                    emit(state, 'blobCreated', {
                      blobKey:key,
                      mime:mime || null,
                      byteSize:byteSize
                    });
                  }
                } catch (error) { emitError(state, 'blob_observer', error); }
                return result;
              };
              window.URL.createObjectURL = state.createObjectURLWrapper;
            } catch (error) { emitError(state, 'blob_install', error); }
          }

          function restoreObservers(state) {
            try { if (state.scanTimer) clearTimeout(state.scanTimer); } catch (_) {}
            state.scanTimer = 0;
            try { if (state.mutationObserver) state.mutationObserver.disconnect(); } catch (_) {}
            try { if (state.performanceObserver) state.performanceObserver.disconnect(); } catch (_) {}
            try {
              if (state.fetchWrapper && window.fetch === state.fetchWrapper) {
                window.fetch = state.originalFetch;
              }
            } catch (_) {}
            try {
              if (state.xhrPrototype && state.xhrPrototype.open === state.xhrOpenWrapper) {
                state.xhrPrototype.open = state.originalXHROpen;
              }
            } catch (_) {}
            try {
              if (state.createObjectURLWrapper &&
                  window.URL.createObjectURL === state.createObjectURLWrapper) {
                window.URL.createObjectURL = state.originalCreateObjectURL;
              }
            } catch (_) {}
          }

          function responseFor(state, afterSeq, limit) {
            afterSeq = Math.max(0, Math.floor(finiteNumber(afterSeq, 0)));
            limit = boundedInteger(limit, MAX_DRAIN, 1, MAX_DRAIN);
            var available = state.events.filter(function(event) { return event.seq > afterSeq; });
            var events = available.slice(0, limit);
            return safeStringify({
              ok:true,
              version:VERSION,
              runID:state.runID,
              active:state.active,
              seq:state.seq,
              droppedBeforeSeq:state.droppedBeforeSeq,
              hasMore:available.length > events.length,
              snapshot:state.snapshot,
              events:events,
              error:null
            });
          }

          function makeState(runID) {
            var state = {
              runID:runID,
              active:true,
              seq:0,
              droppedBeforeSeq:0,
              events:[],
              snapshot:null,
              scanning:false,
              scanTimer:0,
              nodeKeys:new WeakMap(),
              nodeSeq:0,
              observedRoots:new WeakSet(),
              rootHits:new Map(),
              blobs:new Map(),
              blobCount:0,
              networkImageCount:0,
              networkFingerprints:new Set(),
              rendererFingerprints:new Map(),
              previewFingerprints:new Map(),
              observedCells:new Set(),
              ordinals:new Set(),
              directImages:new Set(),
              directHighResolutionImages:new Set(),
              declaredTotal:0,
              maxCellCount:0,
              sawStart:false,
              sawEnd:false,
              pageFlipCandidateSeen:false,
              pageFlipConfirmed:false,
              previewHighResolutionSeen:false,
              lastMode:'',
              lastRootFingerprint:'',
              lastCellsFingerprint:'',
              lastScrollFingerprint:'',
              lastReaderFingerprint:'',
              initialReader:{ pageKey:'', navigationSeq:null },
              mutationObserver:null,
              performanceObserver:null,
              originalFetch:null,
              fetchWrapper:null,
              xhrPrototype:null,
              originalXHROpen:null,
              xhrOpenWrapper:null,
              xhrMetadata:null,
              originalCreateObjectURL:null,
              createObjectURLWrapper:null
            };
            state.mutationObserver = new MutationObserver(function() {
              scheduleScan(state, 'mutation');
            });
            return state;
          }

          window.__crKindlePFProbeStart = function(runID) {
            runID = validRunID(runID);
            if (!runID) return rejected('', 'invalid_run_id');
            if (controller.state && controller.state.active) {
              if (controller.state.runID !== runID) return rejected(runID, 'run_mismatch');
              scan(controller.state, 'restart');
              return responseFor(controller.state, controller.state.seq, MAX_DRAIN);
            }
            var state = makeState(runID);
            controller.state = state;
            try {
              var initialContexts = collectContexts(state);
              var initialEntries = visualEntries(initialContexts);
              var initialReader = readerEvidence(state, initialEntries);
              state.initialReader = {
                pageKey:initialReader.pageKey || '',
                navigationSeq:initialReader.navigationSeq
              };
              state.lastReaderFingerprint = [
                state.initialReader.pageKey,
                state.initialReader.navigationSeq
              ].join(':');
              installPerformanceObserver(state);
              installFetchObserver(state);
              installXHRObserver(state);
              installBlobObserver(state);
              scan(state, 'start');
              return responseFor(state, 0, MAX_DRAIN);
            } catch (error) {
              emitError(state, 'start', error);
              scan(state, 'start_recovery');
              return responseFor(state, 0, MAX_DRAIN);
            }
          };

          window.__crKindlePFProbePoll = function(runID, afterSeq, limit) {
            runID = validRunID(runID);
            var state = controller.state;
            if (!runID) return rejected('', 'invalid_run_id');
            if (!state || state.runID !== runID) return rejected(runID, 'run_mismatch');
            scan(state, 'poll');
            return responseFor(state, afterSeq, limit);
          };

          window.__crKindlePFProbeStop = function(runID) {
            runID = validRunID(runID);
            var state = controller.state;
            if (!runID) return rejected('', 'invalid_run_id');
            if (!state || state.runID !== runID) return rejected(runID, 'run_mismatch');
            if (state.active) scan(state, 'stop');
            state.active = false;
            restoreObservers(state);
            if (state.snapshot) {
              state.snapshot.atMs = nowMs();
              state.snapshot.summary = summaryFor(state);
            }
            return responseFor(state, 0, MAX_DRAIN);
          };
        })();
        """#
    )

}
#endif
