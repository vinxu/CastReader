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
    installPlayBooksNativeLayoutBridge();
  }
})();
