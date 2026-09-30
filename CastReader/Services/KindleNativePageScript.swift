import Foundation

/// Observes Kindle's existing renderer cache. No inferred Blob order, renderer
/// fetch, or scroll is permitted in this adapter. Kept separate so the exact
/// shipped JavaScript can be exercised with adversarial asynchronous fixtures.
enum KindleNativePageScript {
    static let bootstrap = #"""
    (function() {
      if (window.__crKindleNativePages) return;
      var navigation = null, renderer = null, process = null, book = '';
      var epoch = 0, revision = 0, entries = new Map(), engaged = false;
      var documentID = Date.now().toString(36) + '-' + Math.random().toString(36).slice(2);
      var lastDiscovery = 0, turn = null, requests = new Map();
      function find(start) {
        var root = start, roots = new Set();
        while (root && root.return && !roots.has(root)) { roots.add(root); root = root.return; }
        if (root?.stateNode?.current && root !== root.stateNode.current) {
          if (!start?.alternate) return null;
          start = start.alternate;
        }
        var fibers = new Set();
        for (var f = start, depth = 0; f && depth < 64 && !fibers.has(f); f = f.return, depth++) {
          fibers.add(f);
          var hooks = new Set();
          for (var h = f.memoizedState, i = 0; h && i < 80 && !hooks.has(h); h = h.next, i++) {
            hooks.add(h);
            var n = h.memoizedState && h.memoizedState.current && h.memoizedState.current.client && h.memoizedState.current.client.navigationService;
            var r = n && n.options && n.options.rendererController;
            if (Number.isInteger(n && n.currentIndex) && r && r.cache instanceof Map && r.renderingProcessId != null && typeof n.move === 'function') return n;
          }
        }
        return null;
      }
      function discover() {
        var nodes = document.querySelectorAll('#kr-chevron-right, #kr-chevron-left, #kr-renderer');
        for (var node of nodes) for (var key of Object.getOwnPropertyNames(node)) {
          if (key.indexOf('__reactFiber$') !== 0 && key.indexOf('__reactInternalInstance$') !== 0) continue;
          var found = find(node[key]);
          if (found) return found;
        }
        return null;
      }
      function changed() {
        try { document.dispatchEvent(new Event('castreader-native-pages-changed')); } catch (_) {}
      }
      function reset(n, b) {
        navigation = n;
        renderer = n && n.options.rendererController;
        process = renderer && renderer.renderingProcessId;
        book = b; epoch++; entries.clear();
      }
      function owns(index, entry, ownerEpoch) {
        return ownerEpoch === epoch && navigation && navigation.options.rendererController === renderer &&
          renderer.renderingProcessId === process && renderer.cache.get(index) === entry.promise && entries.get(index) === entry;
      }
      function refresh(force) {
        if (!window.__crKindleNativeOrderEnabled) return;
        var b = String(window.__crKindleNativeBook || location.href);
        if (b !== book) { reset(null, b); engaged = false; turn = null; lastDiscovery = 0; }
        if (force || !navigation || Date.now() - lastDiscovery >= 250) {
          lastDiscovery = Date.now();
          var found = discover();
          // Kindle removes its chrome. Retain only the controller whose real
          // current page is still attached; never substitute another DOM image.
          if (found) navigation = found;
        }
        var r = navigation && navigation.options && navigation.options.rendererController;
        if (!r || !(r.cache instanceof Map)) return;
        engaged = true;
        if (renderer !== r || process !== r.renderingProcessId || (entries.navigation && entries.navigation !== navigation)) reset(navigation, b);
        entries.navigation = navigation;
        var current = navigation.currentIndex;
        for (var pair of entries) {
          if (pair[0] < current - 1 || pair[0] > current + 2 || r.cache.get(pair[0]) !== pair[1].promise) entries.delete(pair[0]);
        }
        for (var index = current - 1; index <= current + 2; index++) {
          var promise = r.cache.get(index);
          if (!promise || typeof promise.then !== 'function' || entries.get(index)?.promise === promise) continue;
          observe(index, promise);
        }
      }
      function observe(index, promise) {
        var entry = {promise:promise, revision:++revision, page:null, raster:null};
        var ownerEpoch = epoch;
        entries.set(index, entry);
        promise.then(function(page) {
          if (!owns(index, entry, ownerEpoch)) return;
          if (!page || !page.page || !page.renderResult || !page.renderResult.pageElement) return;
          entry.page = page; changed();
        }, function() {
          // Keep the failed slot until Kindle replaces its Promise, avoiding
          // an unbounded retry / microtask loop on a rejected cached Promise.
          if (owns(index, entry, ownerEpoch)) entry.failed = true;
        });
      }
      function get(index) {
        var entry = entries.get(index);
        return entry && owns(index, entry, epoch) && entry.page ? entry : null;
      }
      function id(index) {
        var entry = get(index);
        return entry ? 'native:' + documentID + ':' + book + ':' + epoch + ':' + index + ':' + entry.revision : '';
      }
      function indexFor(key) {
        for (var index of entries.keys()) if (id(index) === key) return index;
        return null;
      }
      function surface(entry) {
        var el = entry && entry.page.renderResult.pageElement;
        if (!el) return null;
        var s = /^(IMG|CANVAS)$/.test(el.tagName || '') ? el : el.querySelector('img, canvas');
        if (!s) return null;
        var canvas = s.tagName === 'CANVAS';
        var w = canvas ? s.width : s.naturalWidth, h = canvas ? s.height : s.naturalHeight;
        return w > 0 && h > 0 && (canvas || s.complete) ? s : null;
      }
      function currentIndex() {
        if (!navigation) return null;
        var i = navigation.currentIndex, e = get(i), s = surface(e);
        return e && e.page === navigation.currentView?.renderedPage &&
          e.page.renderResult.pageElement.isConnected && s && s.isConnected ? i : null;
      }
      function sourceRange(index) {
        var p = get(index)?.page?.page;
        var start = p?.startPositionId, end = p?.endPositionId;
        return Number.isFinite(start) && Number.isFinite(end) && start >= 0 && end > start ? [start,end] : null;
      }
      function sameSource(a, b) {
        var left = sourceRange(a), right = sourceRange(b);
        return !!left && !!right && left[0] === right[0] && left[1] === right[1];
      }
      function candidate(index, geometry) {
        var entry = get(index), s = surface(entry);
        if (!entry || !s) return null;
        var active = currentIndex();
        if (active != null && index !== active && sameSource(active, index)) return null;
        var img = s;
        if (s.tagName === 'CANVAS') {
          // Adapt a decoded native canvas to the existing image/OCR interface.
          // Owned pixels survive detached/revoked original surfaces; no URL fetch.
          if (!entry.raster || entry.rasterSource !== s || entry.raster.width !== s.width || entry.raster.height !== s.height) {
            if (s.width * s.height > 24000000) return null;
            var copy = document.createElement('canvas'); copy.width = s.width; copy.height = s.height;
            copy.getContext('2d').drawImage(s, 0, 0);
            copy.complete = true; copy.naturalWidth = s.width; copy.naturalHeight = s.height;
            entry.raster = copy; entry.rasterSource = s;
          }
          img = entry.raster;
        }
        var rect = geometry(s);
        if (!rect || rect.width <= 1 || rect.height <= 1) {
          var ci = currentIndex(), cs = ci == null ? null : surface(get(ci));
          rect = cs ? geometry(cs) : null;
        }
        if (!rect || rect.width <= 1 || rect.height <= 1) return null;
        return {key:id(index), kind:'native-page', nativeIndex:index, nativeEpoch:epoch,
          el:s, img:img, src:s.currentSrc || s.src || '', contentKey:'', rect:rect,
          nw:img.naturalWidth, nh:img.naturalHeight,
          visible:0, bandVisible:0};
      }
      function state() {
        refresh();
        var ci = currentIndex();
        return {active:engaged, epoch:epoch, book:book, index:navigation?.currentIndex ?? null,
          currentId:ci == null ? '' : id(ci), previousId:ci == null ? '' : id(ci - 1),
          nextId:ci == null ? '' : id(ci + 1),
          sourceRange:ci == null ? null : sourceRange(ci),
          nextSourceRepeated:ci != null && sameSource(ci, ci + 1)};
      }
      function dispatch(direction, expectedFrom, requestID) {
        if (requestID && requests.has(requestID)) return requests.get(requestID);
        refresh(true);
        var s = state(), step = direction === 'previous' ? -1 : 1;
        if (!s.currentId || (expectedFrom && expectedFrom !== s.currentId)) return {ok:false, dispatchCount:0, reason:'native-origin-not-current'};
        // Kindle can cache the final source interval under more relative
        // indices. A new cache identity alone is not a new source page.
        if (sameSource(s.index, s.index + step)) return {ok:false, dispatchCount:0, reason:'native-source-unchanged'};
        turn = {from:s.currentId, epoch:epoch, index:s.index, targetIndex:s.index + step,
          targetId:id(s.index + step), sourceRange:sourceRange(s.index), step:step};
        var result = {ok:true, strategy:'native-cache-navigation', dispatchCount:1,
          nativeEpoch:epoch, fromKey:s.currentId, fromIndex:s.index, targetIndex:turn.targetIndex,
          expectedTargetKey:turn.targetId, semanticAction:step === 1 ? 'NextPage' : 'PreviousPage'};
        if (requestID) {
          requests.set(requestID, result);
          if (requests.size > 64) requests.delete(requests.keys().next().value);
        }
        try {
          var pending = navigation.move(result.semanticAction);
          if (pending && typeof pending.catch === 'function') pending.catch(function() {});
        } catch (_) { result.ok = false; result.reason = 'native-action-threw'; result.dispatchUncertain = true; }
        return result;
      }
      function confirmed(from, step) {
        var s = state();
        if (!turn || turn.from !== from || turn.step !== step || turn.epoch !== epoch) return '';
        var range = sourceRange(s.index);
        if (range && turn.sourceRange && range[0] === turn.sourceRange[0] && range[1] === turn.sourceRange[1]) return '';
        // A changed process is a new pagination scope. Caller must rebuild;
        // no acceptance based on a different image or a later cache index.
        return s.index === turn.targetIndex && s.currentId &&
          (!turn.targetId || s.currentId === turn.targetId) ? s.currentId : '';
      }
      window.__crKindleNativePages = {
        refresh:refresh, state:state, engaged:function(){ return engaged; },
        currentIndex:currentIndex, id:id, indexFor:indexFor, candidate:candidate,
        adjacent:function(key, step, geometry) { var i = indexFor(key); return i == null ? null : candidate(i + step, geometry); },
        dispatch:dispatch, confirmed:confirmed,
        valid:function(key, displayed) { refresh(); var i = indexFor(key); return i != null && (!displayed || currentIndex() === i); }
      };
    })();
    """#
}
