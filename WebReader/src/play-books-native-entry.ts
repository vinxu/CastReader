// Observe only native measuring DOM in the Google reader frame.
// No provider requests or speculative navigation; bounded and detached on pagehide.
export function installPlayBooksNativeLayoutBridge() {
    const root = globalThis as any;
    if (root.__castreaderPlayBooksLayoutBridge) return;
    root.__castreaderPlayBooksLayoutBridge = true;
    const documents = new WeakSet<Document>();
    const nodes = new WeakMap<Element, { collection: any; page: any }>();
    const collections: any[] = [];
    const observers: MutationObserver[] = [];
    const descriptors: [string, PropertyDescriptor, () => any][] = [];
    let sequence = 0, scheduled = false;
    const publish = () => {
      if (scheduled) return;
      scheduled = true;
      queueMicrotask(() => {
        scheduled = false;
        while (collections.length > 8) collections.shift();
        let json = JSON.stringify(collections);
        while (json.length > 2000000 && collections.length > 1) {
          collections.shift(); json = JSON.stringify(collections);
        }
        if (json.length > 2000000 || !document.documentElement) return;
        document.documentElement.setAttribute('data-castreader-pb-layouts', json);
        document.dispatchEvent(new Event('castreader-play-books-layout'));
      });
    };
    const observe = (doc: Document) => {
      if (documents.has(doc) || doc === document) return;
      documents.add(doc);
      let collection: any;
      const observer = new MutationObserver(records => {
        try {
          const changed = new Set<HTMLElement>();
          for (const record of records) for (const node of [record.target, ...record.addedNodes, ...record.removedNodes]) {
            const element = node.nodeType === 1 ? node as HTMLElement : node.parentElement;
            const segment = element?.closest<HTMLElement>('.gb-segment[ocean_stream_index]');
            if (segment) changed.add(segment);
          }
          for (const element of changed) {
            let captured = nodes.get(element);
            if (!captured) {
              if (!element.hasAttribute('ocean-reopened-element') || !collection) {
                collection = { id: ++sequence, className: doc.body?.className || '',
                  width: doc.documentElement.clientWidth, height: doc.documentElement.clientHeight, pages: [], anchors: [] };
                collections.push(collection);
              }
              if (collection.pages.length >= 128) continue;
              captured = { collection, page: { blocks: [], closed: false } };
              nodes.set(element, captured);
              collection.pages.push(captured.page);
            }
            // The native renderer may append source or close its stream after
            // the first insertion. Update that page; don't freeze an early copy.
            const owner = captured.collection;
            owner.anchors = [...new Set([...owner.anchors,
              ...[...element.querySelectorAll<HTMLElement>('[id]')].map(anchor => anchor.id).filter(id => id.startsWith('GBS.'))])];
            const blocks = [...element.querySelectorAll<HTMLElement>('p,h1,h2,h3,h4,h5,h6,li,blockquote')]
              .filter(block => !block.querySelector('p,h1,h2,h3,h4,h5,h6,li,blockquote'))
              .map(block => {
                const boundaries: { stream: string; offset: number }[] = [];
                let offset = 0;
                const walker = doc.createTreeWalker(block, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT);
                for (let node = walker.nextNode(); node; node = walker.nextNode()) {
                  if (node.nodeType === Node.TEXT_NODE) offset += (node as Text).length;
                  else {
                    const child = node as Element, stream = child.getAttribute('ocean_stream_index');
                    if (stream && !child.hasAttribute('ocean-reopened-element')) boundaries.push({ stream, offset });
                  }
                }
                return { raw: block.textContent || '', stream: block.getAttribute('ocean_stream_index'), boundaries,
                  reopened: block.hasAttribute('ocean-reopened-element'),
                  closed: block.hasAttribute('ocean_stream_close') };
              })
              .filter(block => /[\p{L}\p{N}]/u.test(block.raw));
            captured.page.blocks = blocks;
            captured.page.closed = element.hasAttribute('ocean_stream_close');
          }
          publish();
        } catch { /* Layout observation cannot interfere with Google's renderer. */ }
      });
      observer.observe(doc, { childList: true, subtree: true, characterData: true, attributes: true,
        attributeFilter: ['ocean_stream_close', 'ocean-reopened-element', 'ocean_stream_index'] });
      observers.push(observer);
      if (observers.length > 16) observers.shift()!.disconnect();
    };
    // The measuring iframe is created and emptied in the same rendering task.
    // Observe its document before native code uses it, preserving getter results.
    for (const name of ['contentDocument', 'contentWindow']) {
      const descriptor = Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, name);
      if (!descriptor?.get || !descriptor.configurable) continue;
      const get = function(this: HTMLIFrameElement) {
        const value = Reflect.apply(descriptor.get!, this, []);
        try { const doc = name === 'contentDocument' ? value : value?.document; if (doc) observe(doc); } catch { /* cross-origin iframe */ }
        return value;
      };
      descriptors.push([name, descriptor, get]);
      Object.defineProperty(HTMLIFrameElement.prototype, name, { ...descriptor, get });
    }
    window.addEventListener('pagehide', () => {
      for (const [name, descriptor, get] of descriptors) {
        if (Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype, name)?.get === get) {
          Object.defineProperty(HTMLIFrameElement.prototype, name, descriptor);
        }
      }
      for (const observer of observers) observer.disconnect();
    }, { once: true });
}

if (location.hostname === 'books.googleusercontent.com' && /\/books\/reader\/frame/.test(location.pathname)) {
  installPlayBooksNativeLayoutBridge();
}
