// Vendored from readout-desktop native page bridge (2026-09-29); iOS owns this copy.
/** A column is owned by the renderer's chapter UID and source offsets, never
 * by the URL at which a speculative preRender DOM happened to appear. */
export const WEREAD_NATIVE_ATTR = 'data-castreader-wr-native';
export const WEREAD_NATIVE_EVENT = 'castreader-wr-native';
export const WEREAD_TURN_EVENT = 'castreader-wr-native-turn';
export const WEREAD_TURN_ATTR = 'data-castreader-wr-native-turn';
export const WEREAD_TURN_RESULT = 'data-castreader-wr-native-turn-result';
export const WEREAD_NAVIGATION_EVENT = 'castreader-wr-native-navigation';
export interface WeReadGlyph {
  text: string; offset: number; x: number; y: number; width: number; height: number;
}
export interface WeReadColumn {
  id: string; index: number; chapter: number; width: number; height: number;
  glyphs: WeReadGlyph[];
}
export interface WeReadNativeState {
  book: string; layout: string; current: string[]; columns: WeReadColumn[];
  count: number; last: boolean; ready: boolean; revision: number;
}
export function readWeReadNativeState(): WeReadNativeState | null {
  try {
    const value = JSON.parse(document.documentElement.getAttribute(WEREAD_NATIVE_ATTR) || 'null');
    return value?.book && Array.isArray(value.columns) && value.columns.length <= 12 &&
      Array.isArray(value.current) && value.current.length <= 2 ? value : null;
  } catch { return null; }
}

/** Installed in MAIN. Captures the actual reader once, then immediately
 * restores Function.apply. No chapter requests, decryption or speculative
 * navigation. Its public render methods supply the already-rendered text. */
export function installWeReadNativeBridge(existingReader?: any) {
  let reader: any;
  let scheduled = false;
  let revision = 0;
  let lastSignature = '';
  let pendingTarget: string | null = null;
  let pendingRestore: { chapter: number; index: number; expires: number } | null = null;
  let state: WeReadNativeState | null = null;
  let painted = new WeakMap<HTMLCanvasElement, string>();
  const hash = (s: string) => {
    let h = 2166136261;
    for (let i = 0; i < s.length; i++) h = Math.imul(h ^ s.charCodeAt(i), 16777619);
    return (h >>> 0).toString(36);
  };
  function nativeColumns(): { book: string; layout: string; columns: WeReadColumn[] } | null {
    if (!reader || reader._isDestroyed || !reader.$el?.isConnected) return null;
    const book = String(reader.bookInfo?.bookId || '');
    const width = Number(reader.pageWidth), height = Number(reader.pageHeight);
    if (!book || width <= 0 || height <= 0) return null;
    const layout = `${width}:${height}:${reader.fontSizeLevel}:${reader.fontFamily}:${reader.displayColumnCount}`;
    const infos = reader.extraRenderPagesInfo;
    const getPages = reader.$options?.methods?.getCurrentChapterPages;
    if (!Array.isArray(infos) || typeof getPages !== 'function') return null;
    const left = reader.leftRenderPageIdx;
    const nearby = infos.filter((p: any) => p.pageIdx >= left - 2 && p.pageIdx < left + 8);
    const chapters = [...new Set(nearby.map((p: any) => p.chapterUid))];
    const columns: WeReadColumn[] = [];
    for (const uid of chapters) {
      // This read-only native getter filters its private page array by
      // currentChapterUid. Calling with a receiver does not mutate the reader.
      const pages = getPages.call({ currentChapterUid: uid });
      if (!Array.isArray(pages) || pages.some((p: any) => p.chapterUid !== uid)) return null;
      for (const page of pages) {
        if (page.pageIdx < left - 2 || page.pageIdx >= left + 8) continue;
        const glyphs: WeReadGlyph[] = page.contents.filter((o: any) => o.type === 1 && o.text)
          .map((o: any) => ({ text: String(o.text), offset: Number(o._offset), x: o.canvasX,
            y: o.rect.y, width: o.rect.w, height: o.rect.h }));
        if (glyphs.some(g => ![g.offset, g.x, g.y, g.width, g.height].every(Number.isFinite))) return null;
        const id = `${book}:${uid}:${hash(layout + JSON.stringify(glyphs))}`;
        const value = { id, index: page.pageIdx, chapter: Number(uid), width, height, glyphs };
        columns.push(value);
      }
    }
    return { book, layout, columns: columns.sort((a, b) => a.index - b.index) };
  }
  function publish(): void {
    scheduled = false;
    try {
      const data = nativeColumns();
      if (!data) {
        if (state) {
          state = null; lastSignature = '';
          document.documentElement.removeAttribute(WEREAD_NATIVE_ATTR);
          document.dispatchEvent(new Event(WEREAD_NATIVE_EVENT));
        }
        return;
      }
      const count = reader.isSinglePage ? 1 : 2;
      const visible = data.columns.filter(p => p.index >= reader.leftRenderPageIdx &&
        p.index < reader.leftRenderPageIdx + count);
      const canvases = [...document.querySelectorAll<HTMLCanvasElement>('.wr_canvasContainer canvas')];
      const ready = (visible.length === count || (!!reader.isLastPage && visible.length > 0)) &&
        (!pendingTarget || visible[0]?.id === pendingTarget) &&
        visible.every((p, i) => painted.get(canvases[i]) === p.id);
      if (ready) pendingTarget = null;
      const signature = `${data.layout}|${visible.map(p => p.id)}|${data.columns.map(p => p.id)}|${ready}|${reader.isLastPage}`;
      if (signature === lastSignature) return;
      lastSignature = signature;
      state = { ...data, current: visible.map(p => p.id), count, last: !!reader.isLastPage,
        ready, revision: ++revision };
      document.documentElement.setAttribute(WEREAD_NATIVE_ATTR, JSON.stringify(state));
      document.dispatchEvent(new Event(WEREAD_NATIVE_EVENT));
      finishSinglePageRestore();
    } catch { /* A renderer contract change must leave the native reader intact. */ }
  }
  function traceRestore(stage: string, detail: Record<string, unknown>) {
    try { (window as any).webkit?.messageHandlers?.castreader?.postMessage({ type: 'log',
      payload: { message: `WEREAD native resume ${stage} ${JSON.stringify(detail)}` } }); } catch {}
  }
  function finishSinglePageRestore(): void {
    const target = pendingRestore;
    if (!target || !state?.ready) return;
    const first = state.columns.find(p => p.id === state!.current[0]);
    // The provider's scrollTo/changePage rounds an odd target down to its
    // two-page spread even in single-page mode. Correct only that exact case,
    // after the earlier page has actually painted, with one native Next.
    pendingRestore = null;
    traceRestore('painted', { target: target.index, current: first?.index, single: reader.isSinglePage });
    if (!reader.isSinglePage || Date.now() > target.expires || !first ||
        first.chapter !== target.chapter || first.index !== target.index - 1 || target.index % 2 !== 1) return;
    const next = state.columns.find(p => p.chapter === target.chapter && p.index === target.index);
    const button = document.querySelector<HTMLButtonElement>('.renderTarget_pager_button_right');
    if (!next || !button || button.disabled) return;
    pendingTarget = next.id;
    publish();
    button.click();
  }
  function schedule(): void {
    if (scheduled) return;
    scheduled = true; requestAnimationFrame(publish);
  }
  function attach(candidate: any): boolean {
    if (reader || candidate?.$options?.name !== 'HorizontalReader' ||
        typeof candidate.paintPageFinish !== 'function' ||
        typeof candidate.$options?.methods?.getCurrentChapterPages !== 'function') return false;
    reader = candidate;
    const finish = reader.paintPageFinish;
    reader.paintPageFinish = function(ctx: CanvasRenderingContext2D) {
      const result = Reflect.apply(finish, this, arguments);
      try {
        const data = nativeColumns();
        const canvases = [...document.querySelectorAll<HTMLCanvasElement>('.wr_canvasContainer canvas')];
        const slot = canvases.indexOf(ctx.canvas);
        const column = data?.columns.find(p => p.index === reader.leftRenderPageIdx + slot);
        if (slot >= 0 && column) painted.set(ctx.canvas, column.id);
        publish();
      } catch { /* diagnostic bridge cannot break paint */ }
      return result;
    };
    // Preloading another chapter changes the native resource window without
    // repainting the visible page. Observe that native commit too.
    const preload = reader.setPreloadChapterRenderContents;
    if (typeof preload === 'function') reader.setPreloadChapterRenderContents = function(...args: any[]) {
      const result = Reflect.apply(preload, this, args); publish(); return result;
    };
    schedule();
    return true;
  }
  if (existingReader) attach(existingReader);
  else {
    const original = Function.prototype.apply;
    let timer: ReturnType<typeof setTimeout>;
    const restore = () => {
      if (Function.prototype.apply === capture) Function.prototype.apply = original;
      clearTimeout(timer);
    };
    const capture: typeof original = function(this: Function, context: any, args: any) {
      try { if (context?._isVue && attach(context)) restore(); } catch { restore(); }
      return Reflect.apply(original, this, [context, args]);
    };
    Function.prototype.apply = capture;
    timer = setTimeout(restore, 15000);
    window.addEventListener('pagehide', restore, { once: true });
  }
  document.addEventListener(WEREAD_NAVIGATION_EVENT, () => {
    // A catalog jump supersedes an automatic turn, including one stopped at
    // the provider's trial wall. Its old target must not poison all later
    // chapters. Require a fresh native paint before publishing any new source.
    pendingTarget = null;
    pendingRestore = null;
    painted = new WeakMap();
    publish();
  });
  document.addEventListener('pointerdown', () => { pendingRestore = null; }, true);
  document.addEventListener('keydown', () => { pendingRestore = null; }, true);
  document.addEventListener(WEREAD_TURN_EVENT, () => {
    pendingRestore = null;
    let request: any;
    try {
      request = JSON.parse(document.documentElement.getAttribute(WEREAD_TURN_ATTR) || 'null');
      const fresh = nativeColumns();
      const from = fresh?.columns.find(p => p.index === reader.leftRenderPageIdx);
      const target = fresh?.columns.find(p => p.id === request?.to);
      const count = reader.isSinglePage ? 1 : 2;
      const accepted = !!(state?.ready && from && from.id === request?.from && target &&
        Math.abs(target.index - from.index) === count);
      document.documentElement.setAttribute(WEREAD_TURN_RESULT,
        JSON.stringify({ requestId: request?.requestId, accepted }));
      if (!accepted || !target || !from) return;
      const selector = target.index > from.index ? '.renderTarget_pager_button_right'
        : '.renderTarget_pager_button:not(.renderTarget_pager_button_right)';
      const button = document.querySelector<HTMLButtonElement>(selector);
      if (!button || button.disabled) throw new Error('no_native_turn_control');
      pendingTarget = target.id;
      publish(); // Withdraw old-page readiness before the native side effect.
      button.click(); // Exactly one semantic native turn, including chapter preloading.
      publish();
    } catch {
      document.documentElement.setAttribute(WEREAD_TURN_RESULT,
        JSON.stringify({ requestId: request?.requestId, accepted: false }));
    }
  });
  return {
    readerPosition() {
      const first = state?.ready && state.columns.find(p => p.id === state!.current[0]);
      const chapterOffset = first && first.glyphs[0]?.offset;
      if (!first || !Number.isSafeInteger(chapterOffset) || chapterOffset! < 0) return null;
      return { chapterUID: String(first.chapter), chapterOffset };
    },
    restorePosition(target: { chapterUID?: string; chapterOffset?: number }) {
      const first = state?.ready && state.columns.find(p => p.id === state!.current[0]);
      const offset = target?.chapterOffset;
      if (!first || String(first.chapter) !== String(target?.chapterUID) ||
          !Number.isSafeInteger(offset) || offset! < 0 ||
          typeof reader?.scrollTo !== 'function' || reader._isDestroyed || !reader.$el?.isConnected) return false;
      // Only an offset within the currently rendered chapter is authorized.
      // A saved chapter URL performs cross-chapter navigation separately.
      // Preserve the provider's UID type: its getter compares with strict
      // equality while the bridge serializes chapter numbers for identity.
      const raw = reader.extraRenderPagesInfo?.find((p: any) => Number(p.pageIdx) === first.index &&
        String(p.chapterUid) === String(first.chapter));
      const pages = raw ? reader.$options.methods.getCurrentChapterPages.call({ currentChapterUid: raw.chapterUid }) : [];
      const matches = Array.isArray(pages) ? pages.filter((p: any) => String(p.chapterUid) === String(first.chapter) &&
        p.contents?.some((g: any) => g.type === 1 && Number(g._offset) === offset)) : [];
      const targetPage = matches.length === 1 && Number.isSafeInteger(Number(matches[0].pageIdx)) ? matches[0] : null;
      traceRestore('requested', { offset, chapter: first.chapter, current: first.index,
        rawUIDType: typeof raw?.chapterUid, pages: pages.length, matches: matches.map((p: any) => p.pageIdx) });
      pendingRestore = targetPage ? { chapter: first.chapter, index: Number(targetPage.pageIdx), expires: Date.now() + 5000 } : null;
      pendingTarget = null;
      painted = new WeakMap();
      publish();
      reader.scrollTo({ chapterOffset: offset });
      return true;
    },
  };
}
