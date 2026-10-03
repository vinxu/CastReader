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

  // src/play-books-native-preparation.ts
  function installPlayBooksNativePreparation() {
    const root = window;
    if (root.__crPlayBooksNativePreparation) return;
    const attribute = "data-castreader-pb-prepared";
    const state = { view: null, generation: 0, baseline: "", busy: false };
    root.__crPlayBooksNativePreparation = state;
    let stopped = false, scheduled = false;
    const originalSet = Map.prototype.set;
    const restore = () => {
      if (Map.prototype.set === observeRegistration) Map.prototype.set = originalSet;
    };
    function observeRegistration(key, value) {
      var _a;
      const result = Reflect.apply(originalSet, this, [key, value]);
      if (Array.isArray(value) && ((_a = value[0]) == null ? void 0 : _a.localName) === "reader-horizontal-view") {
        state.view = value;
        restore();
        schedule();
      }
      return result;
    }
    Map.prototype.set = observeRegistration;
    const registrationTimeout = setTimeout(restore, 45e3);
    const descriptor = (page) => {
      if (!page || typeof page.volumeId !== "string" || !page.volumeId || !Number.isInteger(page.Uc) || page.Uc < 0 || !Number.isInteger(page.Sb) || page.Sb < 0 || typeof page.key !== "string" || typeof page.aA !== "string" || !page.key.startsWith(page.aA + ":") || !page.aA.startsWith(page.volumeId + ":") || !Number.isFinite(page.width) || page.width <= 0 || !Number.isFinite(page.height) || page.height <= 0 || typeof page.mF !== "string" || !page.mF || page.mF.length > 25e4) return null;
      return {
        id: `page-${page.Uc}-${page.Sb}`,
        key: page.key,
        engine: page.aA,
        volume: page.volumeId,
        segment: page.Uc,
        index: page.Sb,
        width: page.width,
        height: page.height,
        html: page.mF
      };
    };
    const current = () => {
      var _a, _b;
      const component = (_a = state.view) == null ? void 0 : _a.find((value) => {
        var _a2, _b2;
        return ((_b2 = (_a2 = value == null ? void 0 : value.nb) == null ? void 0 : _a2.Aa) == null ? void 0 : _b2.localName) === "reader-horizontal-view";
      });
      const host = (_b = component == null ? void 0 : component.nb) == null ? void 0 : _b.Aa;
      if (!(host == null ? void 0 : host.isConnected) || !(component.O instanceof Map)) return null;
      const visible = [...host.querySelectorAll("reader-page.shown")].filter((page) => {
        const r = page.getBoundingClientRect();
        const width = Math.max(0, Math.min(innerWidth, r.right) - Math.max(0, r.left));
        const height = Math.max(0, Math.min(innerHeight, r.bottom) - Math.max(0, r.top));
        return r.width > 0 && r.height > 0 && width * height >= r.width * r.height * 0.5;
      });
      if (!visible.length || visible.length > 2 || visible.some((page) => !page.classList.contains("-gb-loaded"))) return null;
      const cached = [...component.O.values()].map((value) => value.Wb);
      const pages = visible.map((element) => cached.filter((page) => page && element.id === `page-${page.Uc}-${page.Sb}`));
      if (pages.some((matches) => matches.length !== 1)) return null;
      const native = pages.map((matches) => matches[0]).sort((a, b) => a.Uc - b.Uc || a.Sb - b.Sb);
      const sources = native.map(descriptor);
      if (sources.some((value) => !value)) return null;
      const baseline = JSON.stringify({
        viewport: [innerWidth, innerHeight],
        pages: native.map((page) => [page.key, page.rd])
      });
      return { component, native, sources, baseline, columns: host.querySelector("li.twopage") ? 2 : 1 };
    };
    async function prepare() {
      var _a, _b, _c, _d, _e, _f, _g, _h, _i;
      scheduled = false;
      if (stopped) return;
      const selected = current();
      const baseline = (selected == null ? void 0 : selected.baseline) || "";
      if (baseline !== state.baseline) {
        state.baseline = baseline;
        state.generation++;
        state.attempted = "";
        document.documentElement.removeAttribute(attribute);
      }
      if (!selected || state.busy || state.attempted === baseline) return;
      state.attempted = baseline;
      state.busy = true;
      const generation = state.generation, nextPages = [];
      try {
        let page = selected.native.at(-1);
        const first = page;
        let required = selected.columns;
        for (let index = 0; index < required; index++) {
          const engine = (_d = (_c = (_b = (_a = selected.component.Fa) == null ? void 0 : _a.O) == null ? void 0 : _b.U) == null ? void 0 : _c.get) == null ? void 0 : _d.call(_c, page.aA);
          if (((_e = engine == null ? void 0 : engine.getKey) == null ? void 0 : _e.call(engine)) !== page.aA || ((_f = engine == null ? void 0 : engine.segment) == null ? void 0 : _f.hf) !== page.Uc || typeof engine.ha !== "function" || page.Dw !== true) break;
          const body = Function.prototype.toString.call(engine.ha);
          if (!/\.Dw/.test(body) || !/\.Sb\s*\+\s*1/.test(body) || !/\.parent\.gA\(/.test(body)) break;
          let timer;
          let next;
          try {
            next = await Promise.race([engine.ha(page), new Promise((_, reject) => {
              timer = setTimeout(() => reject(new Error("native-preparation-timeout")), 8e3);
            })]);
          } finally {
            clearTimeout(timer);
          }
          if (stopped || ((_g = current()) == null ? void 0 : _g.baseline) !== baseline || generation !== state.generation) return;
          const source = descriptor(next);
          if (!source || next.volumeId !== first.volumeId || next.width !== first.width || next.height !== first.height || JSON.stringify(next.rd) !== JSON.stringify(first.rd) || !(next.Uc === page.Uc && next.Sb === page.Sb + 1 || next.Uc === page.Uc + 1 && next.Sb === 0)) break;
          nextPages.push(source);
          page = next;
          if (nextPages.length === selected.columns) {
            const text = nextPages.map((value) => {
              const template = document.createElement("template");
              template.innerHTML = value.html;
              return template.content.textContent || "";
            }).join("").replace(/\s/g, "");
            if (text.length < 50) required = selected.columns * 2;
          }
        }
        const complete = nextPages.length >= selected.columns || nextPages.length > 0 && page.Dw === false;
        if (complete && ((_h = current()) == null ? void 0 : _h.baseline) === baseline && generation === state.generation) {
          document.documentElement.setAttribute(attribute, JSON.stringify({
            version: 1,
            viewport: [innerWidth, innerHeight],
            current: selected.sources,
            next: nextPages
          }));
          document.dispatchEvent(new Event("castreader-play-books-layout"));
        }
      } catch (e) {
      } finally {
        state.busy = false;
        if (!stopped && ((_i = current()) == null ? void 0 : _i.baseline) !== baseline) schedule();
      }
    }
    function schedule() {
      if (stopped || scheduled) return;
      scheduled = true;
      setTimeout(prepare, 25);
    }
    const observer = new MutationObserver(schedule);
    observer.observe(document, {
      subtree: true,
      childList: true,
      attributes: true,
      attributeFilter: ["class", "style", "id"]
    });
    window.addEventListener("resize", schedule);
    window.addEventListener("pagehide", () => {
      var _a;
      stopped = true;
      state.generation++;
      state.view = null;
      clearTimeout(registrationTimeout);
      restore();
      observer.disconnect();
      (_a = document.documentElement) == null ? void 0 : _a.removeAttribute(attribute);
      window.removeEventListener("resize", schedule);
    }, { once: true });
  }

  // src/play-books-native-entry.ts
  function installPlayBooksNativeLayoutBridge() {
    const root = globalThis;
    if (root.__castreaderPlayBooksLayoutBridge) return;
    root.__castreaderPlayBooksLayoutBridge = true;
    const documents = /* @__PURE__ */ new WeakSet();
    const nodes = /* @__PURE__ */ new WeakMap();
    const collections = [];
    const observers = [];
    const descriptors = [];
    let sequence = 0, scheduled = false;
    const publish = () => {
      if (scheduled) return;
      scheduled = true;
      queueMicrotask(() => {
        scheduled = false;
        while (collections.length > 8) collections.shift();
        let json = JSON.stringify(collections);
        while (json.length > 2e6 && collections.length > 1) {
          collections.shift();
          json = JSON.stringify(collections);
        }
        if (json.length > 2e6 || !document.documentElement) return;
        document.documentElement.setAttribute("data-castreader-pb-layouts", json);
        document.dispatchEvent(new Event("castreader-play-books-layout"));
      });
    };
    const observe = (doc) => {
      if (documents.has(doc) || doc === document) return;
      documents.add(doc);
      let collection;
      const observer = new MutationObserver((records) => {
        var _a;
        try {
          const changed = /* @__PURE__ */ new Set();
          for (const record of records) for (const node of [record.target, ...record.addedNodes, ...record.removedNodes]) {
            const element = node.nodeType === 1 ? node : node.parentElement;
            const segment = element == null ? void 0 : element.closest(".gb-segment[ocean_stream_index]");
            if (segment) changed.add(segment);
          }
          for (const element of changed) {
            let captured = nodes.get(element);
            if (!captured) {
              if (!element.hasAttribute("ocean-reopened-element") || !collection) {
                collection = {
                  id: ++sequence,
                  className: ((_a = doc.body) == null ? void 0 : _a.className) || "",
                  width: doc.documentElement.clientWidth,
                  height: doc.documentElement.clientHeight,
                  pages: [],
                  anchors: []
                };
                collections.push(collection);
              }
              if (collection.pages.length >= 128) continue;
              captured = { collection, page: { blocks: [], closed: false } };
              nodes.set(element, captured);
              collection.pages.push(captured.page);
            }
            const owner = captured.collection;
            owner.anchors = [.../* @__PURE__ */ new Set([
              ...owner.anchors,
              ...[...element.querySelectorAll("[id]")].map((anchor) => anchor.id).filter((id) => id.startsWith("GBS."))
            ])];
            const blocks = [...element.querySelectorAll("p,h1,h2,h3,h4,h5,h6,li,blockquote")].filter((block) => !block.querySelector("p,h1,h2,h3,h4,h5,h6,li,blockquote")).map((block) => {
              const boundaries = [];
              let offset = 0;
              const walker = doc.createTreeWalker(block, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
              for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                if (node.nodeType === Node.TEXT_NODE) offset += node.length;
                else {
                  const child = node, stream = child.getAttribute("ocean_stream_index");
                  if (stream && !child.hasAttribute("ocean-reopened-element")) boundaries.push({ stream, offset });
                }
              }
              return {
                raw: block.textContent || "",
                stream: block.getAttribute("ocean_stream_index"),
                boundaries,
                reopened: block.hasAttribute("ocean-reopened-element"),
                closed: block.hasAttribute("ocean_stream_close")
              };
            }).filter((block) => /[\p{L}\p{N}]/u.test(block.raw));
            captured.page.blocks = blocks;
            captured.page.closed = element.hasAttribute("ocean_stream_close");
          }
          publish();
        } catch (e) {
        }
      });
      observer.observe(doc, {
        childList: true,
        subtree: true,
        characterData: true,
        attributes: true,
        attributeFilter: ["ocean_stream_close", "ocean-reopened-element", "ocean_stream_index"]
      });
      observers.push(observer);
      if (observers.length > 16) observers.shift().disconnect();
    };
    for (const name of ["contentDocument", "contentWindow"]) {
      const descriptor = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, name);
      if (!(descriptor == null ? void 0 : descriptor.get) || !descriptor.configurable) continue;
      const get = function() {
        const value = Reflect.apply(descriptor.get, this, []);
        try {
          const doc = name === "contentDocument" ? value : value == null ? void 0 : value.document;
          if (doc) observe(doc);
        } catch (e) {
        }
        return value;
      };
      descriptors.push([name, descriptor, get]);
      Object.defineProperty(HTMLIFrameElement.prototype, name, __spreadProps(__spreadValues({}, descriptor), { get }));
    }
    window.addEventListener("pagehide", () => {
      var _a;
      for (const [name, descriptor, get] of descriptors) {
        if (((_a = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, name)) == null ? void 0 : _a.get) === get) {
          Object.defineProperty(HTMLIFrameElement.prototype, name, descriptor);
        }
      }
      for (const observer of observers) observer.disconnect();
    }, { once: true });
  }
  if (location.hostname === "books.googleusercontent.com" && /\/books\/reader\/frame/.test(location.pathname)) {
    installPlayBooksNativePreparation();
    installPlayBooksNativeLayoutBridge();
  }
})();
