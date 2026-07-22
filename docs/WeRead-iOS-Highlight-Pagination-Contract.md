# WeRead iOS highlight and pagination contract

## Scope

This document defines the iOS WeRead contract for page extraction, TTS input,
sentence highlighting, automatic pagination, and manual pagination.  It is
derived from the production WeRead renderer and the current CastReader browser
extension.  The iOS implementation must preserve these invariants rather than
approximate them with a transparent reflowed copy of the chapter.

## Production WeRead renderer

The current desktop reader has three distinct surfaces:

1. `.preRenderContainer > #preRenderContent` is a transient, transparent HTML
   layout.  WeRead measures it and then rasterizes it.  It can contain a full
   chapter or several future columns, so it is a semantic/source-coordinate
   surface, not proof that text is visible now.
2. `.renderTargetContainer .wr_canvasContainer` is the visible raster surface.
   The reader paints at most the current left/right render pages into Canvas.
   A page can be painted directly with `fillText`, or copied from a larger source
   Canvas with `drawImage(sx, sy, sw, sh, ...)`.
3. `.renderTarget_pager` is a sibling UI surface positioned over the bottom of
   the render target (`bottom: 24px`, `height: 32px`, `z-index: 10`).  Its
   `.renderTarget_pager_button` controls and text are never book content.

The live renderer uses `leftRenderPageIdx` / `rightRenderPageIdx`, prepares
Canvas data from the transient DOM, and repaints the current page(s).  Therefore
DOM presence, Canvas generation, and visible page identity are related but are
not interchangeable signals.

## Extension reference behavior

### Capture

- Capture `.preRenderContainer` synchronously before the first `await`; WeRead
  may clear it immediately after rasterization.
- Remove style/script and footnote UI from the semantic text.
- Save paragraph text, paragraph/character source coordinates, layout size,
  URL, and content fingerprint.
- Reject encrypted/character-remapped pre-render copies.
- Hook `fillText`, `clearRect`, and Canvas-to-Canvas `drawImage` at document
  start.  Keep only the latest generation for each visible content Canvas.
- Treat `content-ready` as cache/layout telemetry only.  It is not a page-change
  command and must not restart playback.

### Current-page extraction

The only valid TTS source is the intersection of the semantic source and the
current visible Canvas page:

1. Build the current page text from the latest visible `fillText` page(s), or
   derive the source crop from the latest Canvas-to-Canvas `drawImage` call.
2. Locate that page text in the chapter/source text using normalized,
   order-constrained matching.  Repeated phrases must not move matching back to
   an earlier source occurrence.
3. Compute the exact source range `[pageStart, pageEnd)`.
4. Intersect every semantic paragraph range with that page range.
5. A paragraph crossing a page boundary is sliced.  Page 1 receives only its
   prefix and page 2 receives only its suffix.
6. Attach only bbox entries whose pixels lie inside the visible Canvas content
   surface.  Pixels outside Canvas, below the content surface, or underneath the
   pager are invalid evidence.
7. If exact Canvas geometry is unavailable, fail closed for highlight/page
   commit.  Never reflow the full paragraph in a transparent DOM element and
   use that layout as a Canvas highlight fallback.

This page slice is the single source of truth for all three consumers:

- native TTS input;
- sentence/word highlight mapping;
- page content fingerprint and turn confirmation.

### Sentence alignment

- TTS-normalized punctuation and whitespace are mapped back to source offsets
  with NFKC/quote normalization plus bounded insertion/deletion/substitution
  lookahead.
- The current sentence offset is deterministic: replay all immutable earlier
  audio segments in the same paragraph from offset zero.  A mutable cursor must
  not own sentence alignment because seek, replay, cancellation, and one missed
  match otherwise poison every later sentence.
- Canvas sentence highlighting is bbox-only.  Partially overlapping bbox runs
  are clipped to the sentence range and grouped into visual lines.
- Missing bbox evidence means no highlight for that sentence; it does not permit
  a DOM Range fallback.

### Automatic page turn

1. Finish every TTS paragraph in the current page slice.
2. Perform exactly one semantic click on the exact current next control
   (`.renderTarget_pager_button_right`, text `下一页`).
3. Never add keyboard, coordinate tap, duplicate click, or timeout retry paths.
4. Observe a stable new visible-surface fingerprint.
5. Invalidate the old generation/queue/highlight.
6. Extract the new page slice and start a fresh TTS generation.

A timeout records failure and leaves the reader where it is; it never performs
a second turn action.

### Manual page turn

1. A pointer/touch intent on the exact previous/next pager immediately stops
   audio and invalidates the old TTS generation.
2. Each stable page candidate replaces the prior pending candidate.
3. Commit and restart only after the final candidate has remained unchanged for
   600 ms.  Rapid A -> B -> C turns produce no B-page audio and exactly one
   restart on C.
4. Preserve whether Read Aloud or Explain was active and restart only that mode.
5. A Canvas change not preceded by an intercepted pointer is still an
   authoritative stop boundary.

## iOS gaps found by the audit (addressed in this implementation)

1. `glyphs()` maps all latest-generation `fillText` calls, including calls whose
   transformed pixels are outside the visible Canvas/page content rectangle.
2. `mapGlyphs()` independently matches whole semantic paragraphs and can accept
   invisible continuation text instead of first locating one contiguous current
   page range.
3. `rectsFor()` falls back to DOM Range rectangles on the transparent overlay
   when exact Canvas bboxes are absent.  This produced the orange blocks below
   the WeRead pager in the device reproduction.
4. The injected highlight layer used `overflow: visible` and a z-index above the
   pager, so invalid geometry is visibly painted over reader controls.
5. A `wereadPage` payload is committed immediately.  iOS lacks the extension's
   600 ms final-page debounce for manual A -> B -> C turns.
6. Manual intent and automatic next selectors still primarily target the old
   `readerFooter` DOM.  The production reader now uses `renderTarget_pager`.
7. A single 240 ms publish debounce is not a stability contract; a transient
   source/Canvas pairing can be committed before the next render mutation.

## Required iOS implementation

- Add an explicit visible Canvas surface calculation and filter/clip every
  fillText/drawImage bbox against it and the pager top boundary.
- Replace per-paragraph fillText matching with one order-constrained current-page
  range match, then intersect/slice source paragraphs.
- Make Canvas highlight and Explain marks exact-bbox-only.
- Clip the overlay to the Canvas content surface and keep it below pager UI.
- Disable generic webpage auto-scroll for the Canvas reader.  A highlight or
  refocus command must never scroll WeRead's own paginated surface.
- Require the same candidate fingerprint on two settled snapshots before JS
  publishes a page.
- Add a native manual-turn candidate debounce of 600 ms; automatic confirmed
  turns remain immediate.
- Use exact current pager selectors and one click only.
- Keep the existing native generation epoch, request cancellation, audio queue
  clearing, and evidence-confirmed restart as the cancellation boundary.

## Verification matrix

- One long paragraph crossing two pages: page 1 speaks/highlights only the
  prefix; page 2 only the suffix.
- Captured glyphs below Canvas or under `.renderTarget_pager` are excluded from
  TTS, fingerprint, and highlight.
- No exact bbox: no Canvas highlight and no page commit.
- Curly/straight quotes, full-width punctuation, whitespace normalization, and
  repeated Chinese phrases remain sentence-aligned.
- Automatic completion: one next click, one confirmed page, one restart.
- Manual A -> B -> C: old audio stops immediately; no B restart; exactly one C
  restart after 600 ms.
- Stale DOM layout paired with a new Canvas generation is rejected.
- Both direct fillText pages and drawImage source-crop pages pass the same page
  slice contract.
