(() => {
  var __defProp = Object.defineProperty;
  var __defProps = Object.defineProperties;
  var __getOwnPropDescs = Object.getOwnPropertyDescriptors;
  var __getOwnPropSymbols = Object.getOwnPropertySymbols;
  var __hasOwnProp = Object.prototype.hasOwnProperty;
  var __propIsEnum = Object.prototype.propertyIsEnumerable;
  var __defNormalProp = (obj, key, value) => key in obj ? __defProp(obj, key, { enumerable: true, configurable: true, writable: true, value }) : obj[key] = value;
  var __spreadValues = (a, b) => {
    for (var prop in b || (b = {}))
      if (__hasOwnProp.call(b, prop))
        __defNormalProp(a, prop, b[prop]);
    if (__getOwnPropSymbols)
      for (var prop of __getOwnPropSymbols(b)) {
        if (__propIsEnum.call(b, prop))
          __defNormalProp(a, prop, b[prop]);
      }
    return a;
  };
  var __spreadProps = (a, b) => __defProps(a, __getOwnPropDescs(b));

  // src/weread-native.ts
  var WEREAD_NATIVE_ATTR = "data-castreader-wr-native";
  var WEREAD_NATIVE_EVENT = "castreader-wr-native";
  var WEREAD_TURN_EVENT = "castreader-wr-native-turn";
  var WEREAD_TURN_ATTR = "data-castreader-wr-native-turn";
  var WEREAD_TURN_RESULT = "data-castreader-wr-native-turn-result";
  var WEREAD_NAVIGATION_EVENT = "castreader-wr-native-navigation";
  function readWeReadNativeState() {
    try {
      const value = JSON.parse(document.documentElement.getAttribute(WEREAD_NATIVE_ATTR) || "null");
      return (value == null ? void 0 : value.book) && Array.isArray(value.columns) && value.columns.length <= 12 && Array.isArray(value.current) && value.current.length <= 2 ? value : null;
    } catch (e) {
      return null;
    }
  }
  function installWeReadNativeBridge(existingReader) {
    let reader;
    let scheduled = false;
    let revision = 0;
    let lastSignature = "";
    let pendingTarget = null;
    let pendingRestore = null;
    let state = null;
    let painted = /* @__PURE__ */ new WeakMap();
    const hash = (s) => {
      let h = 2166136261;
      for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
      return (h >>> 0).toString(36);
    };
    function nativeColumns() {
      var _a, _b, _c, _d;
      if (!reader || reader._isDestroyed || !((_a = reader.$el) == null ? void 0 : _a.isConnected)) return null;
      const book = String(((_b = reader.bookInfo) == null ? void 0 : _b.bookId) || "");
      const width = Number(reader.pageWidth), height = Number(reader.pageHeight);
      if (!book || width <= 0 || height <= 0) return null;
      const layout = `${width}:${height}:${reader.fontSizeLevel}:${reader.fontFamily}:${reader.displayColumnCount}`;
      const infos = reader.extraRenderPagesInfo;
      const getPages = (_d = (_c = reader.$options) == null ? void 0 : _c.methods) == null ? void 0 : _d.getCurrentChapterPages;
      if (!Array.isArray(infos) || typeof getPages !== "function") return null;
      const left = reader.leftRenderPageIdx;
      const nearby = infos.filter((p) => p.pageIdx >= left - 2 && p.pageIdx < left + 8);
      const chapters = [...new Set(nearby.map((p) => p.chapterUid))];
      const columns = [];
      for (const uid of chapters) {
        const pages = getPages.call({ currentChapterUid: uid });
        if (!Array.isArray(pages) || pages.some((p) => p.chapterUid !== uid)) return null;
        for (const page of pages) {
          if (page.pageIdx < left - 2 || page.pageIdx >= left + 8) continue;
          const glyphs = page.contents.filter((o) => o.type === 1 && o.text).map((o) => ({
            text: String(o.text),
            offset: Number(o._offset),
            x: o.canvasX,
            y: o.rect.y,
            width: o.rect.w,
            height: o.rect.h
          }));
          if (glyphs.some((g) => ![g.offset, g.x, g.y, g.width, g.height].every(Number.isFinite))) return null;
          const id = `${book}:${uid}:${hash(layout + JSON.stringify(glyphs))}`;
          const value = { id, index: page.pageIdx, chapter: Number(uid), width, height, glyphs };
          columns.push(value);
        }
      }
      return { book, layout, columns: columns.sort((a, b) => a.index - b.index) };
    }
    function publish() {
      var _a;
      scheduled = false;
      try {
        const data = nativeColumns();
        if (!data) {
          if (state) {
            state = null;
            lastSignature = "";
            document.documentElement.removeAttribute(WEREAD_NATIVE_ATTR);
            document.dispatchEvent(new Event(WEREAD_NATIVE_EVENT));
          }
          return;
        }
        const count = reader.isSinglePage ? 1 : 2;
        const visible = data.columns.filter((p) => p.index >= reader.leftRenderPageIdx && p.index < reader.leftRenderPageIdx + count);
        const canvases = [...document.querySelectorAll(".wr_canvasContainer canvas")];
        const ready = (visible.length === count || !!reader.isLastPage && visible.length > 0) && (!pendingTarget || ((_a = visible[0]) == null ? void 0 : _a.id) === pendingTarget) && visible.every((p, i) => painted.get(canvases[i]) === p.id);
        if (ready) pendingTarget = null;
        const signature = `${data.layout}|${visible.map((p) => p.id)}|${data.columns.map((p) => p.id)}|${ready}|${reader.isLastPage}`;
        if (signature === lastSignature) return;
        lastSignature = signature;
        state = __spreadProps(__spreadValues({}, data), {
          current: visible.map((p) => p.id),
          count,
          last: !!reader.isLastPage,
          ready,
          revision: ++revision
        });
        document.documentElement.setAttribute(WEREAD_NATIVE_ATTR, JSON.stringify(state));
        document.dispatchEvent(new Event(WEREAD_NATIVE_EVENT));
        finishSinglePageRestore();
      } catch (e) {
      }
    }
    function traceRestore(stage, detail) {
      var _a, _b, _c;
      try {
        (_c = (_b = (_a = window.webkit) == null ? void 0 : _a.messageHandlers) == null ? void 0 : _b.castreader) == null ? void 0 : _c.postMessage({
          type: "log",
          payload: { message: `WEREAD native resume ${stage} ${JSON.stringify(detail)}` }
        });
      } catch (e) {
      }
    }
    function finishSinglePageRestore() {
      const target = pendingRestore;
      if (!target || !(state == null ? void 0 : state.ready)) return;
      const first = state.columns.find((p) => p.id === state.current[0]);
      pendingRestore = null;
      traceRestore("painted", { target: target.index, current: first == null ? void 0 : first.index, single: reader.isSinglePage });
      if (!reader.isSinglePage || Date.now() > target.expires || !first || first.chapter !== target.chapter || first.index !== target.index - 1 || target.index % 2 !== 1) return;
      const next = state.columns.find((p) => p.chapter === target.chapter && p.index === target.index);
      const button = document.querySelector(".renderTarget_pager_button_right");
      if (!next || !button || button.disabled) return;
      pendingTarget = next.id;
      publish();
      button.click();
    }
    function schedule() {
      if (scheduled) return;
      scheduled = true;
      requestAnimationFrame(publish);
    }
    function attach(candidate) {
      var _a, _b, _c;
      if (reader || ((_a = candidate == null ? void 0 : candidate.$options) == null ? void 0 : _a.name) !== "HorizontalReader" || typeof candidate.paintPageFinish !== "function" || typeof ((_c = (_b = candidate.$options) == null ? void 0 : _b.methods) == null ? void 0 : _c.getCurrentChapterPages) !== "function") return false;
      reader = candidate;
      const finish = reader.paintPageFinish;
      reader.paintPageFinish = function(ctx) {
        const result = Reflect.apply(finish, this, arguments);
        try {
          const data = nativeColumns();
          const canvases = [...document.querySelectorAll(".wr_canvasContainer canvas")];
          const slot = canvases.indexOf(ctx.canvas);
          const column = data == null ? void 0 : data.columns.find((p) => p.index === reader.leftRenderPageIdx + slot);
          if (slot >= 0 && column) painted.set(ctx.canvas, column.id);
          publish();
        } catch (e) {
        }
        return result;
      };
      const preload = reader.setPreloadChapterRenderContents;
      if (typeof preload === "function") reader.setPreloadChapterRenderContents = function(...args) {
        const result = Reflect.apply(preload, this, args);
        publish();
        return result;
      };
      schedule();
      return true;
    }
    if (existingReader) attach(existingReader);
    else {
      const original = Function.prototype.apply;
      let timer;
      const restore = () => {
        if (Function.prototype.apply === capture) Function.prototype.apply = original;
        clearTimeout(timer);
      };
      const capture = function(context, args) {
        try {
          if ((context == null ? void 0 : context._isVue) && attach(context)) restore();
        } catch (e) {
          restore();
        }
        return Reflect.apply(original, this, [context, args]);
      };
      Function.prototype.apply = capture;
      timer = setTimeout(restore, 15e3);
      window.addEventListener("pagehide", restore, { once: true });
    }
    document.addEventListener(WEREAD_NAVIGATION_EVENT, () => {
      pendingTarget = null;
      pendingRestore = null;
      painted = /* @__PURE__ */ new WeakMap();
      publish();
    });
    document.addEventListener("pointerdown", () => {
      pendingRestore = null;
    }, true);
    document.addEventListener("keydown", () => {
      pendingRestore = null;
    }, true);
    document.addEventListener(WEREAD_TURN_EVENT, () => {
      pendingRestore = null;
      let request;
      try {
        request = JSON.parse(document.documentElement.getAttribute(WEREAD_TURN_ATTR) || "null");
        const fresh = nativeColumns();
        const from = fresh == null ? void 0 : fresh.columns.find((p) => p.index === reader.leftRenderPageIdx);
        const target = fresh == null ? void 0 : fresh.columns.find((p) => p.id === (request == null ? void 0 : request.to));
        const count = reader.isSinglePage ? 1 : 2;
        const accepted = !!((state == null ? void 0 : state.ready) && from && from.id === (request == null ? void 0 : request.from) && target && Math.abs(target.index - from.index) === count);
        document.documentElement.setAttribute(
          WEREAD_TURN_RESULT,
          JSON.stringify({ requestId: request == null ? void 0 : request.requestId, accepted })
        );
        if (!accepted || !target || !from) return;
        const selector = target.index > from.index ? ".renderTarget_pager_button_right" : ".renderTarget_pager_button:not(.renderTarget_pager_button_right)";
        const button = document.querySelector(selector);
        if (!button || button.disabled) throw new Error("no_native_turn_control");
        pendingTarget = target.id;
        publish();
        button.click();
        publish();
      } catch (e) {
        document.documentElement.setAttribute(
          WEREAD_TURN_RESULT,
          JSON.stringify({ requestId: request == null ? void 0 : request.requestId, accepted: false })
        );
      }
    });
    return {
      readerPosition() {
        var _a;
        const first = (state == null ? void 0 : state.ready) && state.columns.find((p) => p.id === state.current[0]);
        const chapterOffset = first && ((_a = first.glyphs[0]) == null ? void 0 : _a.offset);
        if (!first || !Number.isSafeInteger(chapterOffset) || chapterOffset < 0) return null;
        return { chapterUID: String(first.chapter), chapterOffset };
      },
      restorePosition(target) {
        var _a, _b;
        const first = (state == null ? void 0 : state.ready) && state.columns.find((p) => p.id === state.current[0]);
        const offset = target == null ? void 0 : target.chapterOffset;
        if (!first || String(first.chapter) !== String(target == null ? void 0 : target.chapterUID) || !Number.isSafeInteger(offset) || offset < 0 || typeof (reader == null ? void 0 : reader.scrollTo) !== "function" || reader._isDestroyed || !((_a = reader.$el) == null ? void 0 : _a.isConnected)) return false;
        const raw = (_b = reader.extraRenderPagesInfo) == null ? void 0 : _b.find((p) => Number(p.pageIdx) === first.index && String(p.chapterUid) === String(first.chapter));
        const pages = raw ? reader.$options.methods.getCurrentChapterPages.call({ currentChapterUid: raw.chapterUid }) : [];
        const matches = Array.isArray(pages) ? pages.filter((p) => {
          var _a2;
          return String(p.chapterUid) === String(first.chapter) && ((_a2 = p.contents) == null ? void 0 : _a2.some((g) => g.type === 1 && Number(g._offset) === offset));
        }) : [];
        const targetPage = matches.length === 1 && Number.isSafeInteger(Number(matches[0].pageIdx)) ? matches[0] : null;
        traceRestore("requested", {
          offset,
          chapter: first.chapter,
          current: first.index,
          rawUIDType: typeof (raw == null ? void 0 : raw.chapterUid),
          pages: pages.length,
          matches: matches.map((p) => p.pageIdx)
        });
        pendingRestore = targetPage ? { chapter: first.chapter, index: Number(targetPage.pageIdx), expires: Date.now() + 5e3 } : null;
        pendingTarget = null;
        painted = /* @__PURE__ */ new WeakMap();
        publish();
        reader.scrollTo({ chapterOffset: offset });
        return true;
      }
    };
  }

  // src/weread-native-entry.ts
  var terminal = (text) => /[。！？.!?][”’"'」』）)]*\s*$/u.test(text.replace(/[\u200b-\u200d\ufeff]/g, ""));
  function units(columns) {
    const result = [];
    let unit;
    let previousHeight = 0;
    let previousIndex;
    for (const column of columns) {
      if (previousIndex !== void 0 && column.index !== previousIndex + 1) unit = void 0;
      for (const glyph of column.glyphs) {
        if (!unit || unit.chapter !== column.chapter || terminal(unit.text) && !/^[”’"'」』）)]/.test(glyph.text) || previousHeight > 0 && Math.abs(previousHeight - glyph.height) > 6) {
          unit = { text: "", chapter: column.chapter, offset: glyph.offset, words: [] };
          result.push(unit);
        }
        const start = unit.text.length;
        unit.text += glyph.text;
        unit.words.push({ text: glyph.text, start, end: unit.text.length, column, glyph });
        previousHeight = glyph.height;
      }
      previousIndex = column.index;
    }
    return result;
  }
  var observedNativeState = false;
  function snapshot(host, successor = false) {
    const state = readWeReadNativeState();
    if (!state) return observedNativeState ? { ready: false, items: [] } : null;
    observedNativeState = true;
    if (!state.ready || !state.current.length || !(host == null ? void 0 : host.isConnected)) return { ready: false, items: [] };
    const first = state.columns.find((p) => p.id === state.current[0]);
    if (!first) return { ready: false, items: [] };
    const start = first.index + (successor ? state.count : 0);
    const selected = successor ? state.columns.filter((p) => p.index >= start && p.index < start + state.count) : state.current.map((id) => state.columns.find((p) => p.id === id)).filter(Boolean);
    if (!selected.length || selected[0].index !== start || selected.some((p, i) => p.index !== start + i)) return { ready: false, items: [] };
    const ids = selected.map((p) => p.id);
    const hr = host.getBoundingClientRect();
    const canvases = [...document.querySelectorAll(".wr_canvasContainer canvas")];
    const all = units(state.columns);
    const items = all.flatMap((unit) => {
      const visible = unit.words.filter((w) => ids.includes(w.column.id));
      if (!visible.length) return [];
      const from = visible[0].start, to = visible[visible.length - 1].end;
      const text = unit.text.slice(from, to);
      if (!text.trim()) return [];
      const entries = successor ? [] : visible.flatMap((word) => {
        const slot = ids.indexOf(word.column.id), canvas = canvases[slot];
        if (!(canvas == null ? void 0 : canvas.isConnected)) return [];
        const r = canvas.getBoundingClientRect(), g = word.glyph;
        if (r.width <= 0 || r.height <= 0) return [];
        const x = r.left + g.x * r.width / word.column.width;
        const y = r.top + g.y * r.height / word.column.height;
        const right = x + g.width * r.width / word.column.width;
        const bottom = y + g.height * r.height / word.column.height;
        const leftClip = Math.max(x, r.left, hr.left, 0), topClip = Math.max(y, r.top, hr.top, 0);
        const rightClip = Math.min(right, r.right, hr.right, innerWidth);
        const bottomClip = Math.min(bottom, r.bottom, hr.bottom, innerHeight);
        if (rightClip <= leftClip || bottomClip <= topClip) return [];
        return [{
          charStart: word.start - from,
          charEnd: word.end - from,
          bbox: { x: leftClip - hr.left, y: topClip - hr.top, width: rightClip - leftClip, height: bottomClip - topClip }
        }];
      });
      if (!successor && !entries.length) return [];
      const left = Math.min(...entries.map((e) => e.bbox.x)), top = Math.min(...entries.map((e) => e.bbox.y));
      return [{
        text,
        style: "",
        entries,
        bounds: successor ? { x: 0, y: 0, width: 0, height: 0 } : {
          x: left,
          y: top,
          width: Math.max(...entries.map((e) => e.bbox.x + e.bbox.width)) - left,
          height: Math.max(...entries.map((e) => e.bbox.y + e.bbox.height)) - top
        },
        sourceLayoutFingerprint: `${state.book}:${unit.chapter}:${state.layout}`,
        sourceParagraphIndex: unit.offset,
        sourceParagraphText: unit.text,
        // Chapter offsets are stable across font/column changes; sentence units
        // can begin earlier/later when the provider replaces its cached columns.
        nativeSourceIdentity: `${state.book}:${unit.chapter}`,
        sourceAnchors: unit.words.map((w) => ({
          start: w.start - from,
          end: w.end - from,
          offset: w.glyph.offset,
          text: w.text
        })),
        sourceCharStart: from,
        sourceCharEnd: to,
        sourcePageEnds: unit.words.filter((w, i, a) => i === a.length - 1 || a[i + 1].column.id !== w.column.id).map((w) => w.end),
        geometrySource: "native-glyphs",
        nativePages: ids
      }];
    });
    return {
      ready: true,
      items,
      pageIdentity: `${state.layout}|${ids.join("|")}`,
      layout: state.layout,
      revision: state.revision,
      last: state.last,
      count: state.count
    };
  }
  function turn(direction) {
    const state = readWeReadNativeState();
    if (!(state == null ? void 0 : state.ready)) return false;
    const from = state.columns.find((p) => p.id === state.current[0]);
    const to = from && state.columns.find((p) => p.index === from.index + (direction === "next" ? state.count : -state.count));
    if (!from || !to) return false;
    const requestId = `ios-${state.revision}-${from.index}-${to.index}`;
    document.documentElement.setAttribute(WEREAD_TURN_ATTR, JSON.stringify({ requestId, from: from.id, to: to.id }));
    document.dispatchEvent(new Event(WEREAD_TURN_EVENT));
    try {
      const result = JSON.parse(document.documentElement.getAttribute(WEREAD_TURN_RESULT) || "null");
      return (result == null ? void 0 : result.requestId) === requestId && result.accepted === true;
    } catch (e) {
      return false;
    }
  }
  var prepareNavigation = () => document.dispatchEvent(new Event(WEREAD_NAVIGATION_EVENT));
  var root = window;
  if (!root.__castReaderWeReadNative && location.hostname === "weread.qq.com") {
    root.__castReaderWeReadNative = __spreadProps(__spreadValues({
      snapshot,
      turn,
      prepareNavigation
    }, installWeReadNativeBridge()), {
      version: "ios-native-pages-20260930-5"
    });
  }
})();
