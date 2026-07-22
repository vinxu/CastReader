#!/usr/bin/env node

import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(
  path.join(root, 'CastReader/Services/WeReadWebScripts.swift'),
  'utf8',
);
const webReaderSource = fs.readFileSync(
  path.join(root, 'CastReader/Views/Reader/WebReaderView.swift'),
  'utf8',
);
const nativeBridgeSource = fs.readFileSync(
  path.join(root, 'CastReader/Services/WebReaderBridge.swift'),
  'utf8',
);
const librarySource = fs.readFileSync(
  path.join(root, 'CastReader/Services/WeReadLibraryStore.swift'),
  'utf8',
);
const libraryViewsSource = fs.readFileSync(
  path.join(root, 'CastReader/Views/WeRead/WeReadLibraryViews.swift'),
  'utf8',
);
const readAloudSource = fs.readFileSync(
  path.join(root, 'CastReader/ViewModels/ReadAloudViewModel.swift'),
  'utf8',
);
const appSource = fs.readFileSync(
  path.join(root, 'CastReader/CastReaderApp.swift'),
  'utf8',
);
const readerHostSource = fs.readFileSync(
  path.join(root, 'CastReader/Views/Reader/ReaderHostView.swift'),
  'utf8',
);
const playerCoordinatorSource = fs.readFileSync(
  path.join(root, 'CastReader/ViewModels/PlayerCoordinator.swift'),
  'utf8',
);
const kindleReaderSource = fs.readFileSync(
  path.join(root, 'CastReader/Views/Kindle/KindleBookView.swift'),
  'utf8',
);

function rawSwiftString(name, useLast = false) {
  const expression = new RegExp(
    `static let ${name} = #\"\"\"\\n([\\s\\S]*?)\\n    \"\"\"#`,
    'g',
  );
  const matches = [...source.matchAll(expression)];
  assert.ok(matches.length > 0, `missing Swift raw string: ${name}`);
  return matches[useLast ? matches.length - 1 : 0][1];
}

const canvas = rawSwiftString('canvasIntercept');
const bridge = rawSwiftString('readerBridge', true);

// Syntax is verified independently from Swift compilation because WKUserScript
// only reports malformed JavaScript at runtime.
new vm.Script(canvas, { filename: 'WeRead.canvasIntercept.js' });
new vm.Script(bridge, { filename: 'WeRead.readerBridge.js' });

assert.match(canvas, /CanvasRenderingContext2D\.prototype\.fillText/);
assert.match(canvas, /CanvasRenderingContext2D\.prototype\.clearRect/);
assert.match(canvas, /effectiveArea>=area\*\.45/);
assert.match(canvas, /source instanceof HTMLCanvasElement/);
assert.match(canvas, /columnFingerprint/);
assert.match(canvas, /actualBoundingBoxAscent/);
assert.match(canvas, /actualBoundingBoxDescent/);
assert.match(canvas, /fontBoundingBoxAscent/);
assert.match(canvas, /fontBoundingBoxDescent/);
assert.match(canvas, /textBaseline:String\(this\.textBaseline/);

assert.match(webReaderSource, /\.name: "wr_theme"/);
assert.match(webReaderSource, /\.value: isDark \? "dark" : "white"/);
assert.match(webReaderSource, /URLQueryItem\(name: "wtheme", value: "white"\)/);
assert.match(webReaderSource, /httpCookieStore\.setCookie\(cookie\)/);
assert.match(libraryViewsSource, /updateTheme\(isDark:/);
assert.match(libraryViewsSource, /WeReadNativeTheme\.prepare/);
assert.match(webReaderSource, /preferredContentMode = \.mobile/);
assert.doesNotMatch(webReaderSource, /preferredContentMode = \.desktop/);
assert.doesNotMatch(source, /wr_whiteTheme|wr_darkTheme|dataset\.theme/);

// Backgrounding may transiently republish SwiftUI's color scheme. Lifecycle
// state must be delivered first and WeRead theme reloads must be active-only,
// otherwise `prepareWeReadReload` stops native TTS while WebKit is suspended.
const updateUIViewStart = webReaderSource.indexOf('func updateUIView(');
const updateUIViewEnd = webReaderSource.indexOf('/// 读取 app bundle', updateUIViewStart);
assert.ok(updateUIViewStart >= 0 && updateUIViewEnd > updateUIViewStart, 'updateUIView lifecycle block missing');
const updateUIView = webReaderSource.slice(updateUIViewStart, updateUIViewEnd);
assert.match(updateUIView, /let isApplicationActive = scenePhase == \.active/);
assert.match(updateUIView, /applicationActivityChanged\(isActive: isApplicationActive\)/);
assert.match(updateUIView, /if isApplicationActive \{[\s\S]*syncWeReadSystemTheme/);
assert.ok(
  updateUIView.indexOf('applicationActivityChanged') < updateUIView.indexOf('syncWeReadSystemTheme'),
  'WeRead lifecycle state must be updated before theme synchronization',
);

assert.match(bridge, /preRenderContainer/);
assert.match(bridge, /renderTargetContainer/);
assert.match(bridge, /contentFingerprint=hash\(next\.map/);
assert.doesNotMatch(bridge, /\$\{columns\}\|\$\{progress\}/);
assert.match(bridge, /function surface\(host\)/);
assert.match(bridge, /function clipBox\(b,s\)/);
assert.match(bridge, /function textMetricBox\(c,baseline,signedScaleY,fallbackFontSize\)/);
assert.doesNotMatch(bridge, /baseline-fs\*\.88/);
assert.match(bridge, /stableCandidate/);
assert.match(bridge, /stableTimer=setTimeout\(\(\)=>publish\(reason\),120\)/);
assert.match(bridge, /restoreVisualState\(\)/);
assert.match(
  bridge,
  /if\(lastFingerprint&&fingerprint!==lastFingerprint\)\{restoreVisualState\(\);post\('wereadPageChanging'/,
);
assert.doesNotMatch(
  bridge,
  /if\(lastFingerprint&&fingerprint!==lastFingerprint\)\{currentHighlight=null;currentMarks\.clear\(\)/,
);
assert.match(bridge, /post\('wereadLayoutStable'/);
assert.match(bridge, /relayout\(a\)/);
assert.match(bridge, /resumeAfterForeground\(a\)/);
assert.match(bridge, /geometrySource='fillText'/);
assert.match(bridge, /geometrySource='drawImage'/);
assert.match(bridge, /function directFillText\(snapshot,host\)/);
assert.match(bridge, /geometrySource:'fillText-direct'/);
// WeRead deletes its complete pre-render chapter DOM immediately after Canvas
// paint. It must be captured inside the MutationObserver callback; a delayed
// `captureAll` scan can only see the reader shell/current page and can never
// provide next-page source offsets.
assert.match(bridge, /function captureTransient\(container\)/);
assert.match(bridge, /for\(const container of transient\)captureTransient\(container\);/);
assert.ok(
  bridge.indexOf('captureTransient(container)') < bridge.indexOf('requestCapture();', bridge.indexOf('const observer=new MutationObserver')),
  'transient pre-render DOM must be captured before the coalesced scan is scheduled',
);
assert.match(bridge, /if\(\(snapshot\.draws\|\|\[\]\)\.length\)/);
assert.match(bridge, /selected=\(p\.chars\|\|\[\]\)\.filter/);
assert.match(bridge, /mappedGlyphs/);
assert.match(bridge, /post\('wereadPagePreview'/);
assert.match(bridge, /confidence:'drawImage'/);
assert.match(bridge, /sourceFingerprint,contentFingerprint/);
assert.match(bridge, /sourceCharStart/);
assert.match(bridge, /sourceCharEnd/);
assert.match(bridge, /sourceSpeechEnd/);
assert.match(bridge, /resolveSegmentRange/);
assert.match(bridge, /computeSourceSpan/);
assert.match(bridge, /formattingMatch/);
assert.match(bridge, /manualTurnIntent/);
assert.match(bridge, /document\.addEventListener\('pointerdown',manualTurnIntent,true\)/);
assert.match(bridge, /\.renderTarget_pager_button_right/);
assert.match(bridge, /\.readerFooter_button:last-child/);
assert.match(bridge, /clean\(candidate\.textContent\)==='下一页'/);
assert.match(bridge, /clearHighlight\(\);clearMarks\(\);const id=/);
assert.match(bridge, /z-index:4;pointer-events:none;overflow:hidden/);
// Explain marks must use the same deterministic hand-drawn SVG contract as
// Kindle. CSS boxes/system-font numbers look static and replay on every Canvas
// stabilization, so restored marks are intentionally non-animated.
assert.match(bridge, /castreader-weread-marks-svg/);
assert.match(bridge, /function markRng\(seed\)/);
assert.match(bridge, /function handLine\(/);
assert.match(bridge, /function handLoop\(/);
assert.match(bridge, /function handDigit\(/);
assert.match(bridge, /strokeDashoffset/);
assert.match(bridge, /cubic-bezier\(0\.62,0,0\.22,1\)/);
assert.match(bridge, /drawMark\(mark,false\)/);
assert.doesNotMatch(bridge, /d\.textContent=String\(a\.n/);
assert.match(bridge, /if\(p\?\.geometrySource==='fillText'\|\|p\?\.geometrySource==='drawImage'\|\|root\(\)\.querySelector\('canvas'\)\)return\[\]/);
assert.match(bridge, /if\(host\.querySelector\('canvas'\)\)return/);
assert.doesNotMatch(bridge, /if\(!host\|\|!layouts\.length\)return/);
assert.match(bridge, /post\('wereadExtractionState'/);
assert.match(bridge, /a\.segmentTexts\.length&&!resolved\)\{clearHighlight\(\);return;/);
assert.equal((bridge.match(/button\.click\(\)/g) || []).length, 1);
assert.doesNotMatch(bridge, /KeyboardEvent|ArrowRight|dispatchEvent\(new MouseEvent/);
assert.doesNotMatch(bridge, /chapterInfos|decodeChapterResponse/);
assert.match(webReaderSource, /webView\.navigationDelegate = context\.coordinator/);
assert.match(webReaderSource, /showWeReadLoadingCover\(\)/);
assert.doesNotMatch(webReaderSource, /WeReadSurfaceTransitionContract|crop\.visualScale/);
assert.match(nativeBridgeSource, /consumeAlreadySpokenPrefix/);
assert.match(nativeBridgeSource, /commitLiveWebPageDuringActiveCarry/);
assert.match(nativeBridgeSource, /requestWeReadNextPage\(\)/);
assert.match(readAloudSource, /isAwaitingLiveWebCarryCompletion/);
assert.match(nativeBridgeSource, /scheduleWeReadForegroundProbe/);
assert.doesNotMatch(nativeBridgeSource, /reason: "orientation"|weReadSurfaceDidChange|weReadSurfaceRelayoutTask/);
assert.match(nativeBridgeSource, /foreground probe inconclusive preserve-live-webview/);
assert.match(nativeBridgeSource, /startWeReadEntryRecovery/);
assert.match(nativeBridgeSource, /localRecoveryURL/);
assert.match(nativeBridgeSource, /scanWeReadShelfForRecovery/);
assert.match(nativeBridgeSource, /didAttemptWeReadShelfRecovery/);
assert.match(librarySource, /installRecoveredEntry/);
assert.match(librarySource, /anchors\.removeValue\(forKey: bookID\)/);
assert.doesNotMatch(nativeBridgeSource, /recoverWeReadWebContent\(reason: "foreground-health-check"\)/);
assert.match(nativeBridgeSource, /WeReadExplainPageEventContract\.shouldHandleVisualChange/);
assert.match(nativeBridgeSource, /WeReadExplainPageEventContract\.shouldResumeExplanation/);
assert.match(nativeBridgeSource, /isAutomaticTurn: pendingWeReadTurn/);
assert.match(nativeBridgeSource, /explain confirmed-page restart=/);
assert.match(nativeBridgeSource, /maybeStartWeReadExplainPrefetch/);
assert.match(nativeBridgeSource, /WeReadExplainPagePrefetchContract\.canConsume/);
assert.match(nativeBridgeSource, /prefetched: prefetched/);
assert.match(nativeBridgeSource, /preservePrediction: true/);
const explainVMSource = fs.readFileSync(
  path.join(root, 'CastReader/ViewModels/ExplainViewModel.swift'),
  'utf8',
);
assert.match(explainVMSource, /private var contentGeneration: UInt64 = 0/);
assert.match(explainVMSource, /contentGeneration &\+= 1/);
assert.match(explainVMSource, /guard generation == contentGeneration else \{ throw CancellationError\(\) \}/);
assert.match(explainVMSource, /prepared\.removeAll\(\)[\s\S]*loadWebParagraphs\(p, language: language\)/);
assert.match(explainVMSource, /if let prefetched \{[\s\S]*startFromPrefetched\(prefetched\)/);
assert.match(readerHostSource, /portraitPlaybackBarHeight: CGFloat = 124/);
assert.match(readerHostSource, /\.frame\(height: Self\.portraitPlaybackBarHeight\)/);
assert.match(appSource, /supportedInterfaceOrientationsFor/);
assert.match(appSource, /requestGeometryUpdate/);
assert.match(appSource, /static func lockCurrent/);
assert.match(playerCoordinatorSource, /document\.sourceKind == \.weread[\s\S]*AppOrientationLock\.lockPortrait/);
assert.match(playerCoordinatorSource, /func minimize\(\)[\s\S]*AppOrientationLock\.lockCurrent/);
assert.match(playerCoordinatorSource, /func expand\(\)[\s\S]*updateOrientationForExpandedReader/);
assert.match(kindleReaderSource, /func minimize\(\)[\s\S]*AppOrientationLock\.lockCurrent/);
assert.match(kindleReaderSource, /func expand\(\)[\s\S]*AppOrientationLock\.unlock/);
assert.match(readerHostSource, /onChange\(of: verticalSizeClass\)[\s\S]*guard coordinator\.isReaderPresented/);
assert.match(kindleReaderSource, /onChange\(of: verticalSizeClass\)[\s\S]*guard playbackCenter\.isPresented/);

// Canvas fillText y is a baseline, not a glyph top.  Modern WKWebView exposes
// the exact ascent/descent used for that draw call; those metrics must win over
// any font-size ratio so the overlay stays on the painted glyphs at every zoom.
const metricStart = bridge.indexOf('function textMetricBox');
const metricEnd = bridge.indexOf('function glyphs', metricStart);
assert.ok(metricStart >= 0 && metricEnd > metricStart, 'text metric mapper missing');
const metricContext = vm.createContext({});
new vm.Script(`
  ${bridge.slice(metricStart, metricEnd)}
  globalThis.textMetricBoxForTest=textMetricBox;
`).runInContext(metricContext);
const actualMetric = metricContext.textMetricBoxForTest(
  { actualAscent: 12, actualDescent: 4, textBaseline: 'alphabetic' },
  100,
  2,
  36,
);
assert.equal(actualMetric.y, 76);
assert.equal(actualMetric.height, 32);
assert.equal(actualMetric.source, 'actual');
const fallbackMetric = metricContext.textMetricBoxForTest(
  { textBaseline: 'middle' },
  100,
  1,
  20,
);
assert.equal(fallbackMetric.y, 90);
assert.equal(fallbackMetric.height, 20);
assert.equal(fallbackMetric.source, 'fallback');

// Execute the exact alignment functions embedded in the WKUserScript.  TTS
// frequently normalizes CJK curly quotes/full-width punctuation; replaying all
// previous segments must still resolve the current sentence in source offsets.
const alignmentStart = bridge.indexOf('const quoteMap=');
const alignmentEnd = bridge.indexOf('function rectsFor', alignmentStart);
assert.ok(alignmentStart >= 0 && alignmentEnd > alignmentStart, 'alignment helpers missing');
const alignmentContext = vm.createContext({});
new vm.Script(`
  const points=text=>{const a=[];for(let i=0;i<text.length;){const cp=text.codePointAt(i),ch=String.fromCodePoint(cp);a.push({ch,start:i,end:i+ch.length});i+=ch.length;}return a;};
  ${bridge.slice(alignmentStart, alignmentEnd)}
  globalThis.resolveSegmentRangeForTest=resolveSegmentRange;
`).runInContext(alignmentContext);
const paragraph = '前句。“社会话题性”在她的作品里并不是目的，而是场景中的一个因素；后句。';
const segmentTexts = [
  '前句。',
  '"社会话题性"在她的作品里并不是目的,而是场景中的一个因素;',
  '后句。',
];
const resolved = alignmentContext.resolveSegmentRangeForTest(
  { text: paragraph },
  { segmentTexts, segSeq: 1 },
);
assert.equal(resolved.start, paragraph.indexOf('“'));
assert.equal(paragraph.slice(resolved.start, resolved.end), '“社会话题性”在她的作品里并不是目的，而是场景中的一个因素；');

// The transient pre-render DOM can contain a complete long paragraph while
// the phone only shows its middle slice.  The native document must receive
// exactly that contiguous Canvas slice, otherwise TTS continues below the
// pager and automatic page advance cannot happen at the visual boundary.
const glyphStart = bridge.indexOf('function findUnits');
const glyphEnd = bridge.indexOf('function mapDraws', glyphStart);
assert.ok(glyphStart >= 0 && glyphEnd > glyphStart, 'fillText page mapper missing');
const glyphContext = vm.createContext({});
new vm.Script(`
  const points=text=>{const a=[];for(let i=0;i<text.length;){const cp=text.codePointAt(i),ch=String.fromCodePoint(cp);a.push({ch,start:i,end:i+ch.length});i+=ch.length;}return a;};
  const compact=text=>points(text).filter(v=>!(/\\s/u.test(v.ch)));
  ${bridge.slice(glyphStart, glyphEnd)}
  globalThis.mapGlyphsForTest=mapGlyphs;
`).runInContext(glyphContext);
const longParagraph = '不可见的上一页文字。当前页从这里开始，逐句朗读并高亮，直到当前页真正结束。下一页的文字绝不能提前进入。';
const visibleSlice = '当前页从这里开始，逐句朗读并高亮，直到当前页真正结束。';
const visibleGlyphs = [...visibleSlice].map((ch, index) => ({
  ch,
  bbox: { x: 8 + (index % 12) * 7, y: 10 + Math.floor(index / 12) * 18, width: 7, height: 16 },
}));
const fillTextPage = glyphContext.mapGlyphsForTest(
  { paragraphs: [{ text: longParagraph, style: '' }] },
  visibleGlyphs,
);
assert.equal(fillTextPage.length, 1);
assert.equal(fillTextPage[0].text, visibleSlice);
assert.equal(fillTextPage[0].entries.length, [...visibleSlice].length);
assert.doesNotMatch(fillTextPage[0].text, /上一页|下一页/);

const supplementaryParagraph = '前頁の文字𠮷野家。現在の頁😀から朗読する。次頁の文字。';
const supplementarySlice = '現在の頁😀から朗読する。';
const supplementaryPage = glyphContext.mapGlyphsForTest(
  { paragraphs: [{ text: supplementaryParagraph, style: '' }] },
  [...supplementarySlice].map((ch, index) => ({
    ch,
    bbox: { x: 8 + index * 7, y: 10, width: 7, height: 16 },
  })),
);
assert.equal(supplementaryPage.length, 1);
assert.equal(supplementaryPage[0].text, supplementarySlice);
assert.equal(supplementaryPage[0].entries.length, [...supplementarySlice].length);

// The reader pager is an independent z-index 10 surface inside the render
// target.  Canvas glyphs at or below its top edge are not book content.
const geometryStart = bridge.indexOf('function surface');
const geometryEnd = bridge.indexOf('function measureParagraph', geometryStart);
assert.ok(geometryStart >= 0 && geometryEnd > geometryStart, 'visible surface helpers missing');
const geometryContext = vm.createContext({ innerWidth: 100, innerHeight: 100 });
new vm.Script(`
  ${bridge.slice(geometryStart, geometryEnd)}
  globalThis.surfaceForTest=surface;
  globalThis.clipBoxForTest=clipBox;
`).runInContext(geometryContext);
const pager = { getBoundingClientRect: () => ({ left: 0, top: 80, right: 100, bottom: 100, width: 100, height: 20 }) };
const renderTarget = {
  getBoundingClientRect: () => ({ left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 }),
  querySelector: selector => selector === '.renderTarget_pager' ? pager : null,
};
const surfaceHost = {
  parentElement: renderTarget,
  closest: selector => selector === '.renderTargetContainer' ? renderTarget : null,
  getBoundingClientRect: () => ({ left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 }),
};
const visibleSurface = geometryContext.surfaceForTest(surfaceHost);
assert.equal(visibleSurface.bottom, 80);
assert.equal(geometryContext.clipBoxForTest({ x: 10, y: 82, width: 20, height: 10 }, visibleSurface), null);
assert.deepEqual(
  { ...geometryContext.clipBoxForTest({ x: 10, y: 70, width: 20, height: 12 }, visibleSurface) },
  { x: 10, y: 70, width: 20, height: 10 },
);

// The Canvas is itself authoritative visible text. If WeRead removes its
// transient pre-render DOM before MutationObserver measures it, playback must
// still receive a page instead of leaving native with zero readable paragraphs.
const directStart = bridge.indexOf('function directFillText');
const directEnd = bridge.indexOf('function choose', directStart);
assert.ok(directStart >= 0 && directEnd > directStart, 'direct fillText fallback missing');
const directContext = vm.createContext({ innerWidth: 100, innerHeight: 100 });
new vm.Script(`
  const points=text=>{const a=[];for(let i=0;i<text.length;){const cp=text.codePointAt(i),ch=String.fromCodePoint(cp);a.push({ch,start:i,end:i+ch.length});i+=ch.length;}return a;};
  ${bridge.slice(geometryStart, geometryEnd)}
  ${bridge.slice(metricStart, metricEnd)}
  ${bridge.slice(directStart, directEnd)}
  globalThis.directFillTextForTest=directFillText;
`).runInContext(directContext);
const directCanvas = {
  isConnected: true,
  width: 100,
  height: 100,
  getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 100 }; },
};
const directHost = {
  parentElement: null,
  closest() { return null; },
  querySelectorAll(selector) { return selector === 'canvas' ? [directCanvas] : []; },
  getBoundingClientRect() { return { left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 }; },
};
const directPage = directContext.directFillTextForTest({ calls: [
  { canvas: directCanvas, text: '第一页。', x: 10, y: 20, width: 32, a: 1, d: 1, tx: 0, ty: 0, fontSize: 12, actualAscent: 10, actualDescent: 2 },
  { canvas: directCanvas, text: '第二行。', x: 10, y: 40, width: 32, a: 1, d: 1, tx: 0, ty: 0, fontSize: 12, actualAscent: 10, actualDescent: 2 },
] }, directHost);
assert.equal(directPage.length, 1);
assert.equal(directPage[0].text, '第一页。第二行。');
assert.equal(directPage[0].geometrySource, 'fillText-direct');
assert.ok(directPage[0].entries.length >= 8);

// drawImage pagination must hand native TTS only the characters inside the
// currently copied source column.  Returning the whole long paragraph makes
// playback continue into the next page and paints below the footer.
const drawStart = bridge.indexOf('function mapDraws');
const drawEnd = bridge.indexOf('function fallback', drawStart);
assert.ok(drawStart >= 0 && drawEnd > drawStart, 'drawImage mapper missing');
const drawContext = vm.createContext({});
new vm.Script(`
  const innerWidth=100,innerHeight=100;
  const points=text=>{const a=[];for(let i=0;i<text.length;){const cp=text.codePointAt(i),ch=String.fromCodePoint(cp);a.push({ch,start:i,end:i+ch.length});i+=ch.length;}return a;};
  const compact=text=>points(text).filter(v=>!(/\\s/u.test(v.ch)));
  ${bridge.slice(geometryStart, geometryEnd)}
  ${bridge.slice(drawStart, drawEnd)}
  globalThis.mapDrawsForTest=mapDraws;
`).runInContext(drawContext);
const sourceText = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ1234';
const fakeCanvas = {
  isConnected: true,
  width: 100,
  height: 100,
  getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 100 }; },
};
const cropped = drawContext.mapDrawsForTest(
  {
    width: 300,
    height: 100,
    paragraphs: [{
      text: sourceText,
      style: '',
      chars: [...sourceText].map((_, index) => ({
        charStart: index,
        charEnd: index + 1,
        left: index * 10,
        top: 10,
        width: 9,
        height: 20,
      })),
    }],
  },
  {
    draws: [{
      canvas: fakeCanvas,
      sourceWidth: 300,
      sourceHeight: 100,
      sx: 100,
      sy: 0,
      sw: 100,
      sh: 100,
      dx: 0,
      dy: 0,
      dw: 100,
      dh: 100,
    }],
  },
  {
    parentElement: null,
    closest() { return null; },
    getBoundingClientRect() { return { left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 }; },
  },
);
assert.equal(cropped.length, 1);
assert.equal(cropped[0].text, sourceText.slice(10, 20));
assert.equal(cropped[0].entries.length, 10);

// Page preloading may inspect the next source column but must not mutate or
// advance the live Canvas. The exact predicted text fingerprint is only a
// cache key; native still waits for the real next surface before releasing it.
const previewStart = bridge.indexOf('function sequentialPreview');
const previewEnd = bridge.indexOf('function ensureLayer', previewStart);
assert.ok(previewStart >= 0 && previewEnd > previewStart, 'next-page preview helpers missing');
const previewLayout = {
  fingerprint: 'layout-1',
  width: 300,
  height: 100,
  paragraphs: [{
    text: sourceText,
    style: '',
    chars: [...sourceText].map((_, index) => ({
      charStart: index,
      charEnd: index + 1,
      left: index * 10,
      top: 10,
      width: 9,
      height: 20,
    })),
  }],
};
const previewContext = vm.createContext({ layoutForPreview: previewLayout });
new vm.Script(`
  const innerWidth=100,innerHeight=100;
  const layouts=[globalThis.layoutForPreview];
  const points=text=>{const a=[];for(let i=0;i<text.length;){const cp=text.codePointAt(i),ch=String.fromCodePoint(cp);a.push({ch,start:i,end:i+ch.length});i+=ch.length;}return a;};
  const compact=text=>points(text).filter(v=>!(/\\s/u.test(v.ch)));
  const hash=s=>String(s);
  const post=()=>{};
  let lastPreviewKey='',visible=[];
  ${bridge.slice(geometryStart, geometryEnd)}
  ${bridge.slice(drawStart, drawEnd)}
  ${bridge.slice(previewStart, previewEnd)}
  globalThis.predictNextForTest=predictNext;
`).runInContext(previewContext);
const previewCanvas = {
  isConnected: true,
  width: 100,
  height: 100,
  getBoundingClientRect() { return { left: 0, top: 0, width: 100, height: 100 }; },
};
const liveDraw = {
  canvas: previewCanvas,
  sourceWidth: 300,
  sourceHeight: 100,
  sx: 100,
  sy: 0,
  sw: 100,
  sh: 100,
  dx: 0,
  dy: 0,
  dw: 100,
  dh: 100,
};
const previewHost = {
  parentElement: null,
  closest() { return null; },
  getBoundingClientRect() { return { left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 }; },
};
const predicted = previewContext.predictNextForTest(
  { draws: [liveDraw] },
  previewHost,
  [{ text: sourceText.slice(10, 20), sourceLayoutFingerprint: 'layout-1' }],
);
assert.equal(predicted.confidence, 'drawImage');
assert.equal(predicted.paragraphs[0].text, sourceText.slice(20, 30));
assert.equal(liveDraw.sx, 100, 'preview must not mutate the live source crop');

// Newer WeRead builds can bypass the transient DOM/cropped-canvas mapping and
// paint the visible page with fillText directly. The direct geometry still has
// to recover chapter-source offsets; otherwise the page renders correctly but
// no next-page preview (and therefore no Explain prefetch) is ever emitted.
const overlapStart = bridge.indexOf('function findUnits');
const overlapEnd = bridge.indexOf('function mapGlyphs', overlapStart);
const directAnchorStart = bridge.indexOf('function attachDirectSource');
const directAnchorEnd = bridge.indexOf('function choose', directAnchorStart);
assert.ok(overlapStart >= 0 && overlapEnd > overlapStart, 'page overlap helper missing');
assert.ok(directAnchorStart >= 0 && directAnchorEnd > directAnchorStart, 'direct source anchoring helper missing');
const directAnchorContext = vm.createContext({ layoutForPreview: previewLayout });
new vm.Script(`
  const layouts=[globalThis.layoutForPreview];
  const points=text=>{const a=[];for(let i=0;i<text.length;){const cp=text.codePointAt(i),ch=String.fromCodePoint(cp);a.push({ch,start:i,end:i+ch.length});i+=ch.length;}return a;};
  const compact=text=>points(text).filter(v=>!(/\\s/u.test(v.ch)));
  ${bridge.slice(overlapStart, overlapEnd)}
  ${bridge.slice(directAnchorStart, directAnchorEnd)}
  ${bridge.slice(previewStart, previewEnd)}
  globalThis.attachDirectSourceForTest=attachDirectSource;
  globalThis.predictNextForTest=predictNext;
`).runInContext(directAnchorContext);
const directVisible = [{
  text: sourceText.slice(10, 20),
  entries: [],
  geometrySource: 'fillText-direct',
}];
const anchored = directAnchorContext.attachDirectSourceForTest(previewLayout, directVisible);
assert.ok(anchored, 'direct fillText page must map back to retained chapter HTML');
assert.equal(anchored.items[0].sourceGlobalStart, 10);
assert.equal(anchored.items[0].sourceGlobalEnd, 20);
assert.equal(anchored.items[0].sourceLayoutFingerprint, 'layout-1');
const directPredicted = directAnchorContext.predictNextForTest(
  { draws: [] },
  previewHost,
  anchored.items,
);
assert.equal(directPredicted.confidence, 'sequential');
assert.equal(directPredicted.paragraphs[0].text, sourceText.slice(20, 30));

// A visual page edge is not a sentence boundary. Extend only the final visible
// slice through the source sentence terminator, then remove that carried prefix
// from the next page's prefetch input so it is spoken exactly once.
const speechStart = bridge.indexOf('const sentenceTerminals=');
const speechEnd = bridge.indexOf('function publishPreview', speechStart);
assert.ok(speechStart >= 0 && speechEnd > speechStart, 'cross-page speech helpers missing');
const speechContext = vm.createContext({});
new vm.Script(`
  ${bridge.slice(speechStart, speechEnd)}
  globalThis.speechPayloadsForTest=speechPayloads;
  globalThis.preparePreviewPayloadsForTest=preparePreviewPayloads;
`).runInContext(speechContext);
const logicalSentence = '第一页开头，这句话跨到下一页才结束。第二句。';
const currentVisible = '第一页开头，这句话跨';
const nextVisible = '到下一页才结束。第二句。';
const currentSpeech = speechContext.speechPayloadsForTest([{
  text: currentVisible,
  sourceParagraphIndex: 0,
  sourceParagraphText: logicalSentence,
  sourceCharStart: 0,
  sourceCharEnd: currentVisible.length,
}]);
assert.equal(currentSpeech[0].text, '第一页开头，这句话跨到下一页才结束。');
assert.equal(currentSpeech[0].boundaryUTF16Offset, currentVisible.length);
const previewSpeech = speechContext.preparePreviewPayloadsForTest(currentSpeech, [{
  text: nextVisible,
  sourceParagraphIndex: 0,
  sourceParagraphText: logicalSentence,
  sourceCharStart: currentVisible.length,
  sourceCharEnd: logicalSentence.length,
}]);
assert.equal(previewSpeech[0].carryUTF16Length, '到下一页才结束。'.length);
assert.equal(previewSpeech[0].prefetchText, '第二句。');

const alreadyComplete = speechContext.speechPayloadsForTest([{
  text: '已经完整结束。',
  sourceParagraphIndex: 0,
  sourceParagraphText: '已经完整结束。下一句。',
  sourceCharStart: 0,
  sourceCharEnd: '已经完整结束。'.length,
}]);
assert.equal(alreadyComplete[0].text, '已经完整结束。', 'must not pull in the next complete sentence');

console.log('WeRead iOS JavaScript contracts passed');
