// Native pagination contract adapted from readout-desktop 9694b2c (2026-09-29).
type ParagraphWithElement = { text: string; element: HTMLElement; canHighlight: boolean; fragments?: unknown[] };

export interface PlayBooksBlock {
  text: string;
  raw: string;
  element: HTMLElement;
  reopened: boolean;
  sliced: boolean;
}
export interface PlayBooksPage {
  id: string;
  segment: number;
  index: number;
  key: string;
  element: HTMLElement;
  blocks: PlayBooksBlock[];
  lastInSegment?: boolean;
}
export interface PlayBooksSnapshot {
  layout: string;
  pages: PlayBooksPage[];
  visible: PlayBooksPage[];
  ready: boolean;
  last: boolean;
  columns: number;
}
export interface PlayBooksFragment {
  page: PlayBooksPage;
  block: number;
  start: number;
  end: number;
}
export interface PlayBooksUnit {
  text: string;
  fragments: PlayBooksFragment[];
  sliced: boolean;
}

// Only structural metadata: no source text, account or provider response.
// Retained for the one-per-visible-page preview diagnostic.
let snapshotDiagnostic = '';
export function playBooksSnapshotDiagnostic(): string { return snapshotDiagnostic; }

function normalizedText(raw: string) {
  let text = '';
  const starts: number[] = [], ends: number[] = [];
  for (let i = 0; i < raw.length; i++) {
    if (/[\u00ad\u200b\ufeff]/u.test(raw[i])) continue;
    if (/\s/u.test(raw[i])) {
      if (!text || text.endsWith(' ')) continue;
      text += ' ';
    } else text += raw[i];
    starts.push(i); ends.push(i + 1);
  }
  if (text.endsWith(' ')) { text = text.slice(0, -1); starts.pop(); ends.pop(); }
  return { text, starts, ends };
}

function hash(text: string): string {
  let value = 2166136261;
  for (let i = 0; i < text.length; i++) value = Math.imul(value ^ text.charCodeAt(i), 16777619);
  return (value >>> 0).toString(36);
}

function pageKey(id: string, blocks: PlayBooksBlock[]): string {
  return `${id}:${hash(JSON.stringify(blocks.map(block => [block.text, block.reopened, block.sliced])))}`;
}

function sourceBlocks(segment: Element): PlayBooksBlock[] {
  return [...segment.querySelectorAll<HTMLElement>('p,h1,h2,h3,h4,h5,h6,li,blockquote')]
    .filter(block => !block.querySelector('p,h1,h2,h3,h4,h5,h6,li,blockquote'))
    .map(element => {
      const raw = element.textContent || '';
      return { element, raw, text: normalizedText(raw).text,
        reopened: element.hasAttribute('ocean-reopened-element'),
        sliced: element.hasAttribute('ocean-sliced-element') };
    }).filter(block => /[\p{L}\p{N}]/u.test(block.text));
}

/** A prepared native spread is usable only while every visible source page
 * still exactly matches its request baseline. Detached HTML is inert and is
 * never used for highlight geometry; rendering must confirm the same source. */
function addVerifiedPreparedPages(pages: PlayBooksPage[], visible: PlayBooksPage[], rendered: HTMLElement) {
  let witness: any;
  const raw = document.documentElement.getAttribute('data-castreader-pb-prepared');
  if (!raw || raw.length > 1600000) return;
  try { witness = JSON.parse(raw); } catch { return; }
  if (witness.version !== 1 || !Array.isArray(witness.current) || !Array.isArray(witness.next) ||
      witness.current.length !== visible.length || !witness.next.length || witness.next.length > 4 ||
      JSON.stringify(witness.viewport) !== JSON.stringify([innerWidth, innerHeight])) return;
  const decode = (source: any): PlayBooksPage | null => {
    if (!source || !Number.isInteger(source.segment) || source.segment < 0 ||
        !Number.isInteger(source.index) || source.index < 0 || source.id !== `page-${source.segment}-${source.index}` ||
        typeof source.volume !== 'string' || !source.volume || typeof source.engine !== 'string' ||
        !source.engine.startsWith(source.volume + ':') || typeof source.key !== 'string' ||
        !source.key.startsWith(source.engine + ':') || typeof source.html !== 'string' || source.html.length > 250000 ||
        source.width !== parseFloat(rendered.style.width) || source.height !== parseFloat(rendered.style.height)) return null;
    const template = document.createElement('template');
    template.innerHTML = source.html;
    const segments = template.content.querySelectorAll('.gb-segment');
    if (segments.length !== 1) return null;
    const blocks = sourceBlocks(segments[0]);
    if (!blocks.length) return null;
    return { id: source.id, segment: source.segment, index: source.index, blocks,
      key: pageKey(source.id, blocks), element: document.createElement('div') };
  };
  const volume = witness.current[0]?.volume;
  const current = witness.current.map(decode), next = witness.next.map(decode);
  if (current.some((page: PlayBooksPage | null) => !page) || next.some((page: PlayBooksPage | null) => !page) ||
      [...witness.current, ...witness.next].some(source => source.volume !== volume) ||
      current.some((page: PlayBooksPage) => visible.filter(live => live.id === page.id && live.key === page.key).length !== 1)) return;
  let previous = visible.at(-1)!;
  for (const page of next as PlayBooksPage[]) {
    if (page.segment === previous.segment && page.index === previous.index + 1) { /* adjacent native page */ }
    else if (page.segment === previous.segment + 1 && page.index === 0) { /* adjacent native chapter */ }
    else return;
    const existing = pages.find(candidate => candidate.id === page.id);
    if (existing && existing.key !== page.key) return;
    previous = page;
  }
  previous = visible.at(-1)!;
  for (const page of next as PlayBooksPage[]) {
    if (page.segment !== previous.segment) previous.lastInSegment = true;
    let existing = pages.find(candidate => candidate.id === page.id);
    if (!existing) { pages.push(page); existing = page; }
    previous = existing;
  }
  snapshotDiagnostic += `;native-prepared=${next.length}`;
}

function measuredSourceCut(previous: any, next: any, visiblePrefix?: string): number | null {
  const full = normalizedText(previous.raw), suffix = normalizedText(next.raw).text;
  if (full.text.endsWith(suffix)) {
    const length = full.text.length - suffix.length;
    return length ? full.starts[length] : 0;
  }
  // An unclosed measurement may be shorter than the next measurement. Only
  // native source offsets (or the strongly bound visible slice) prove its cut;
  // repeated prose or a longest matching substring cannot choose a page.
  if (previous.closed || !Array.isArray(previous.boundaries) || !Array.isArray(next.boundaries)) return null;
  const cuts = new Set<number>();
  if (visiblePrefix !== undefined) {
    const cut = visiblePrefix.length;
    if (!previous.raw.startsWith(visiblePrefix) || cut <= 0 || cut >= previous.raw.length ||
        previous.raw.slice(cut) !== next.raw.slice(0, previous.raw.length - cut)) return null;
    cuts.add(cut);
  }
  for (const marker of previous.boundaries) {
    const matches = next.boundaries.filter((other: any) => other.stream === marker.stream);
    if (!matches.length) continue;
    if (matches.length !== 1 || !Number.isInteger(marker.offset) || !Number.isInteger(matches[0].offset)) return null;
    const cut = marker.offset - matches[0].offset;
    if (cut < 0 || cut >= previous.raw.length ||
        previous.raw.slice(cut) !== next.raw.slice(0, previous.raw.length - cut)) return null;
    cuts.add(cut);
  }
  return cuts.size === 1 ? [...cuts][0] : null;
}

/** Measurement DOM intentionally extends past the page break. The following
 * native slice supplies the exact cut: same stream block + remaining suffix.
 * Never treat all text that happened to enter the measuring iframe as a page. */
function measuredPages(group: any, visible: PlayBooksPage[] = []): PlayBooksBlock[][] | null {
  if (!Array.isArray(group.pages) || group.pages.length > 128) return null;
  const result: PlayBooksBlock[][] = [];
  // Once native navigation shows a later page, unresolved cuts in pages
  // behind it cannot veto that page's exact source witness. Keep the native
  // indices; never publish these placeholders or jump a future unknown cut.
  const start = visible.length ? Math.min(...visible.map(page => page.index)) : 0;
  for (let index = 0; index < group.pages.length; index++) {
    if (index < start) { result.push([]); continue; }
    const source = group.pages[index];
    if (!Array.isArray(source.blocks)) break;
    let blocks = source.blocks.map((block: any) => ({ ...block, sliced: false }));
    const next = group.pages[index + 1]?.blocks?.[0];
    if (next) {
      const cut = blocks.findIndex((block: any) => block.stream === next.stream);
      if (cut >= 0) {
        if (next.reopened) {
          const live = visible.find(page => page.index === index)?.blocks[cut];
          const position = measuredSourceCut(blocks[cut], next, live?.sliced ? live.raw : undefined);
          // Retain only the already proven prefix. An unresolved later
          // measurement must neither erase the immediate successor nor grant
          // permission to skip this cut into a more distant page.
          if (position === null) break;
          if (position > 0) {
            blocks[cut].raw = blocks[cut].raw.slice(0, position);
            blocks[cut].sliced = true;
            blocks = blocks.slice(0, cut + 1);
          } else blocks = blocks.slice(0, cut);
        } else blocks = blocks.slice(0, cut);
      } else if (!blocks.at(-1)?.closed) break;
    } else if (!source.closed) break; // Still waiting for the next measured cut.
    result.push(blocks.map((block: any) => {
      const element = document.createElement('p');
      element.textContent = block.raw;
      return { raw: block.raw, text: normalizedText(block.raw).text, element,
        reopened: !!block.reopened, sliced: !!block.sliced };
    }).filter((block: PlayBooksBlock) => /[\p{L}\p{N}]/u.test(block.text)));
  }
  return result;
}

function addVerifiedMeasuredPages(pages: PlayBooksPage[], visible: PlayBooksPage[], rendered: HTMLElement) {
  let groups: any[];
  try { groups = JSON.parse(document.documentElement.getAttribute('data-castreader-pb-layouts') || '[]'); }
  catch { snapshotDiagnostic += ';measurements=invalid-json'; return; }
  if (!Array.isArray(groups) || groups.length > 8) {
    snapshotDiagnostic += ';measurements=invalid-schema'; return;
  }
  const outcomes: string[] = [];
  const anchors = visible.flatMap(page => [
    ...[...page.element.querySelectorAll<HTMLElement>('.gb-segment [id]')].map(anchor => anchor.id),
    page.element.querySelector('.gb-segment')?.getAttribute('ocean-position')?.split('+')[0] || '',
  ]).filter(id => id.startsWith('GBS.'));
  for (const group of [...groups].reverse()) {
    const tag = `${group.id}:${Array.isArray(group.pages) ? group.pages.length : -1}`;
    if (group.height !== parseFloat(rendered.style.height) || !group.className ||
        !String(group.className).split(/\s+/).every(name => rendered.classList.contains(name))) {
      outcomes.push(`${tag}:layout`); continue;
    }
    if (anchors.some(anchor => !group.anchors?.includes(anchor))) {
      outcomes.push(`${tag}:anchor`); continue;
    }
    const prepared = measuredPages(group, anchors.length ? visible : []);
    if (!prepared) { outcomes.push(`${tag}:source-cut`); continue; }
    if (visible.some(page => page.segment !== visible[0].segment ||
        !prepared[page.index] || pageKey(page.id, prepared[page.index]) !== page.key)) {
      outcomes.push(`${tag}:visible-mismatch:${prepared.length}`); continue;
    }
    // Agreement with every live column binds this speculative measurement to
    // the current native segment and layout, independently of arrival order.
    prepared.forEach((blocks, index) => {
      if (!blocks.length) return;
      const id = `page-${visible[0].segment}-${index}`;
      const existing = pages.find(page => page.id === id);
      if (existing) {
        if (index === group.pages.length - 1 && group.pages[index]?.closed) existing.lastInSegment = true;
      } else pages.push({ id, segment: visible[0].segment, index, key: pageKey(id, blocks),
        blocks, element: document.createElement('div'),
        lastInSegment: index === group.pages.length - 1 && group.pages[index]?.closed });
    });
    outcomes.push(`${tag}:accepted:${prepared.length}`);
    break;
  }
  snapshotDiagnostic += `;anchors=${anchors.length};measurements=${outcomes.join(',') || 'none'}`;
}

/** The icon is locale-independent and belongs to the native pager. Never
 * infer navigation from a translated English aria-label alone. */
export function findPlayBooksTurnButton(direction: 'next' | 'previous'): HTMLButtonElement | null {
  const icon = direction === 'next' ? 'chevron_right' : 'chevron_left';
  return [...document.querySelectorAll<HTMLButtonElement>('button')].find(button =>
    button.querySelector('mat-icon')?.textContent?.trim() === icon
  ) || null;
}

export function readPlayBooksSnapshot(): PlayBooksSnapshot | null {
  snapshotDiagnostic = 'native=false';
  const view = document.querySelector<HTMLElement>('reader-horizontal-view');
  if (!view || getComputedStyle(view).direction === 'rtl') return null;
  const pages: PlayBooksPage[] = [];
  const current = view.querySelector<HTMLElement>('reader-page.shown reader-rendered-page.-gb-text');
  if (!current) return null;
  const pageLayout = (page: HTMLElement) =>
    `${innerWidth}:${innerHeight}:${page.className}:${page.style.width}:${page.style.height}`;
  const layout = pageLayout(current);
  for (const element of view.querySelectorAll<HTMLElement>('reader-page[id]')) {
    const match = /^page-(\d+)-(\d+)$/.exec(element.id);
    const rendered = element.querySelector<HTMLElement>('reader-rendered-page.-gb-text');
    const segment = rendered?.querySelector<HTMLElement>('.gb-segment');
    if (!match || !rendered || !segment) continue;
    const blocks = sourceBlocks(segment);
    // Google keeps multiple size candidates with duplicate native page IDs.
    // Only the typography of the actually shown page owns this session.
    if (pageLayout(rendered) !== layout) continue;
    pages.push({ id: element.id, segment: Number(match[1]), index: Number(match[2]), element,
      key: pageKey(element.id, blocks), blocks });
  }
  pages.sort((a, b) => a.segment - b.segment || a.index - b.index);
  const visible = pages.filter(page => {
    if (!page.element.classList.contains('shown')) return false;
    const rect = page.element.getBoundingClientRect();
    const width = Math.max(0, Math.min(innerWidth, rect.right) - Math.max(0, rect.left));
    const height = Math.max(0, Math.min(innerHeight, rect.bottom) - Math.max(0, rect.top));
    return rect.width > 0 && rect.height > 0 && width * height >= rect.width * rect.height * 0.5;
  });
  if (!visible.length) return null;
  snapshotDiagnostic = `native=true;visible=${visible.map(page => page.id).join(',')};rendered=${pages.map(page => page.id).join(',')}`;
  addVerifiedMeasuredPages(pages, visible, current);
  addVerifiedPreparedPages(pages, visible, current);
  pages.sort((a, b) => a.segment - b.segment || a.index - b.index);
  return { layout, pages, visible,
    ready: visible.every(page => page.element.classList.contains('-gb-loaded') && page.blocks.length > 0),
    last: findPlayBooksTurnButton('next')?.disabled === true,
    columns: view.querySelector('li.twopage') ? 2 : 1 };
}

/** A gap in the cache is not permission to skip a page. Across native content
 * segments, only the next segment's first page is a possible successor. */
export function nextPlayBooksPage(snapshot: PlayBooksSnapshot, page: PlayBooksPage): PlayBooksPage | null {
  return snapshot.pages.find(next => next.segment === page.segment && next.index === page.index + 1)
    || (page.lastInSegment ? snapshot.pages.find(next => next.segment === page.segment + 1 && next.index === 0) : null)
    || null;
}

export function appendPlayBooksPage(units: PlayBooksUnit[], page: PlayBooksPage): void {
  page.blocks.forEach((block, index) => {
    const last = units.at(-1);
    if (index === 0 && block.reopened && last?.sliced) {
      const previous = last.fragments.at(-1)!;
      const raw = previous.page.blocks[previous.block].raw;
      const separator = /\s$/u.test(raw) || /^\s/u.test(block.raw) ? ' ' : '';
      const start = last.text.length + separator.length;
      last.text += separator + block.text;
      last.fragments.push({ page, block: index, start, end: last.text.length });
      last.sliced = block.sliced;
    } else {
      if (index === 0 && last?.sliced) throw new Error('play_books_unconfirmed_paragraph_continuation');
      units.push({ text: block.text, sliced: block.sliced,
        fragments: [{ page, block: index, start: 0, end: block.text.length }] });
    }
  });
}

export function currentPlayBooksUnits(snapshot: PlayBooksSnapshot): PlayBooksUnit[] {
  const units: PlayBooksUnit[] = [];
  for (const page of snapshot.visible) appendPlayBooksPage(units, page);
  return units;
}

export function extractPlayBooksParagraphs(): ParagraphWithElement[] {
  const snapshot = readPlayBooksSnapshot();
  if (!snapshot?.ready) return [];
  return currentPlayBooksUnits(snapshot).map(unit => ({ text: unit.text,
    element: unit.fragments[0].page.blocks[unit.fragments[0].block].element,
    canHighlight: true,
    fragments: unit.fragments.length < 2 ? undefined : unit.fragments.map(fragment => ({
      text: unit.text.slice(fragment.start, fragment.end),
      element: fragment.page.blocks[fragment.block].element,
      start: fragment.start, end: fragment.end,
    })),
  }));
}

/** Rebuild a Range from the currently displayed DOM, rather than retaining
 * text nodes belonging to a recycled/hidden layout candidate. */
export function playBooksTextRange(element: HTMLElement, from: number, to: number): Range | null {
  const nodes: Text[] = [];
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) nodes.push(node as Text);
  const raw = nodes.map(node => node.data).join('');
  const map = normalizedText(raw);
  const start = map.starts[from], end = map.ends[to - 1];
  if (start == null || end == null || end <= start) return null;
  const range = document.createRange();
  let offset = 0, started = false;
  for (const node of nodes) {
    if (!started && start < offset + node.length) {
      range.setStart(node, start - offset); started = true;
    }
    if (started && end <= offset + node.length) {
      range.setEnd(node, end - offset); return range;
    }
    offset += node.length;
  }
  return null;
}
