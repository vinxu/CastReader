/** Google owns pagination and access checks. This adapter asks its existing
 * paginator for one following spread (two only for a tiny tail), without dispatching navigation,
 * changing the bookmark or mounting hidden reader pages. Unknown engine shapes
 * fail closed to the existing measured-DOM path. */
export function installPlayBooksNativePreparation() {
  const root = window as any;
  if (root.__crPlayBooksNativePreparation) return;
  const attribute = 'data-castreader-pb-prepared';
  const state: any = { view: null, generation: 0, baseline: '', busy: false };
  root.__crPlayBooksNativePreparation = state;
  let stopped = false, scheduled = false;
  const originalSet = Map.prototype.set;
  const restore = () => { if (Map.prototype.set === observeRegistration) Map.prototype.set = originalSet; };
  function observeRegistration(this: Map<any, any>, key: any, value: any) {
    const result = Reflect.apply(originalSet, this, [key, value]);
    if (Array.isArray(value) && value[0]?.localName === 'reader-horizontal-view') {
      state.view = value;
      restore();
      schedule();
    }
    return result;
  }
  Map.prototype.set = observeRegistration;
  const registrationTimeout = setTimeout(restore, 45000);

  const descriptor = (page: any) => {
    if (!page || typeof page.volumeId !== 'string' || !page.volumeId ||
        !Number.isInteger(page.Uc) || page.Uc < 0 || !Number.isInteger(page.Sb) || page.Sb < 0 ||
        typeof page.key !== 'string' || typeof page.aA !== 'string' ||
        !page.key.startsWith(page.aA + ':') || !page.aA.startsWith(page.volumeId + ':') ||
        !Number.isFinite(page.width) || page.width <= 0 || !Number.isFinite(page.height) || page.height <= 0 ||
        typeof page.mF !== 'string' || !page.mF || page.mF.length > 250000) return null;
    return { id: `page-${page.Uc}-${page.Sb}`, key: page.key, engine: page.aA,
      volume: page.volumeId, segment: page.Uc, index: page.Sb,
      width: page.width, height: page.height, html: page.mF };
  };
  const current = () => {
    const component = state.view?.find((value: any) => value?.nb?.Aa?.localName === 'reader-horizontal-view');
    const host = component?.nb?.Aa as HTMLElement | undefined;
    if (!host?.isConnected || !(component.O instanceof Map)) return null;
    const visible = [...host.querySelectorAll<HTMLElement>('reader-page.shown')].filter(page => {
      const r = page.getBoundingClientRect();
      const width = Math.max(0, Math.min(innerWidth, r.right) - Math.max(0, r.left));
      const height = Math.max(0, Math.min(innerHeight, r.bottom) - Math.max(0, r.top));
      return r.width > 0 && r.height > 0 && width * height >= r.width * r.height * .5;
    });
    if (!visible.length || visible.length > 2 || visible.some(page => !page.classList.contains('-gb-loaded'))) return null;
    const cached = [...component.O.values()].map((value: any) => value.Wb);
    const pages = visible.map(element => cached.filter((page: any) =>
      page && element.id === `page-${page.Uc}-${page.Sb}`));
    if (pages.some(matches => matches.length !== 1)) return null;
    const native = pages.map(matches => matches[0]).sort((a, b) => a.Uc - b.Uc || a.Sb - b.Sb);
    const sources = native.map(descriptor);
    if (sources.some(value => !value)) return null;
    const baseline = JSON.stringify({ viewport: [innerWidth, innerHeight],
      pages: native.map(page => [page.key, page.rd]) });
    return { component, native, sources, baseline, columns: host.querySelector('li.twopage') ? 2 : 1 };
  };
  async function prepare() {
    scheduled = false;
    if (stopped) return;
    const selected = current();
    const baseline = selected?.baseline || '';
    if (baseline !== state.baseline) {
      state.baseline = baseline; state.generation++;
      state.attempted = '';
      document.documentElement.removeAttribute(attribute);
    }
    if (!selected || state.busy || state.attempted === baseline) return;
    state.attempted = baseline;
    state.busy = true;
    const generation = state.generation, nextPages: any[] = [];
    try {
      let page = selected.native.at(-1);
      const first = page;
      let required = selected.columns;
      for (let index = 0; index < required; index++) {
        const engine = selected.component.Fa?.O?.U?.get?.(page.aA);
        if (engine?.getKey?.() !== page.aA || engine?.segment?.hf !== page.Uc ||
            typeof engine.ha !== 'function' || page.Dw !== true) break;
        // Both observed Google paginators implement this exact forward-only
        // contract. A changed provider implementation is not called blindly.
        const body = Function.prototype.toString.call(engine.ha);
        if (!/\.Dw/.test(body) || !/\.Sb\s*\+\s*1/.test(body) || !/\.parent\.gA\(/.test(body)) break;
        let timer: ReturnType<typeof setTimeout> | undefined;
        let next: any;
        try {
          next = await Promise.race([engine.ha(page), new Promise((_, reject) => {
            timer = setTimeout(() => reject(new Error('native-preparation-timeout')), 8000);
          })]);
        } finally { clearTimeout(timer); }
        if (stopped || current()?.baseline !== baseline || generation !== state.generation) return;
        const source = descriptor(next);
        if (!source || next.volumeId !== first.volumeId || next.width !== first.width || next.height !== first.height ||
            JSON.stringify(next.rd) !== JSON.stringify(first.rd) ||
            !((next.Uc === page.Uc && next.Sb === page.Sb + 1) || (next.Uc === page.Uc + 1 && next.Sb === 0))) break;
        nextPages.push(source);
        page = next;
        if (nextPages.length === selected.columns) {
          const text = nextPages.map(value => {
            const template = document.createElement('template');
            template.innerHTML = value.html;
            return template.content.textContent || '';
          }).join('').replace(/\s/g, '');
          // A tiny chapter tail is skipped by Explain and provides no audio
          // preparation time. Permit exactly one extra adjacent spread.
          if (text.length < 50) required = selected.columns * 2;
        }
      }
      const complete = nextPages.length >= selected.columns || (nextPages.length > 0 && page.Dw === false);
      if (complete && current()?.baseline === baseline && generation === state.generation) {
        document.documentElement.setAttribute(attribute, JSON.stringify({ version: 1,
          viewport: [innerWidth, innerHeight], current: selected.sources, next: nextPages }));
        document.dispatchEvent(new Event('castreader-play-books-layout'));
      }
    } catch { /* Optional preparation must never break native reading. */ }
    finally {
      state.busy = false;
      if (!stopped && current()?.baseline !== baseline) schedule();
    }
  }
  function schedule() {
    if (stopped || scheduled) return;
    scheduled = true;
    setTimeout(prepare, 25);
  }
  const observer = new MutationObserver(schedule);
  observer.observe(document, { subtree: true, childList: true, attributes: true,
    attributeFilter: ['class', 'style', 'id'] });
  window.addEventListener('resize', schedule);
  window.addEventListener('pagehide', () => {
    stopped = true; state.generation++; state.view = null;
    clearTimeout(registrationTimeout); restore(); observer.disconnect();
    document.documentElement?.removeAttribute(attribute);
    window.removeEventListener('resize', schedule);
  }, { once: true });
}
