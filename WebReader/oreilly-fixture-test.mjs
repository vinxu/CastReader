// Real-browser contract fixture for the O'Reilly continuous-scroll adapter.
//
// This bundles oreilly.ts directly, so it stays isolated from entry.ts until
// the native integration explicitly boots the new platform.

import * as esbuild from 'esbuild'
import { fork, spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const chrome = process.env.CASTREADER_CHROME ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const fixtureWindowSize =
  process.env.CASTREADER_OREILLY_FIXTURE_SIZE || '420,720'
const scratch = mkdtempSync(join(tmpdir(), 'castreader-oreilly-fixture-'))
let fixtureServer = null

try {
  const build = await esbuild.build({
    entryPoints: ['src/oreilly.ts'],
    bundle: true,
    write: false,
    format: 'iife',
    globalName: 'OReillyFixture',
    target: 'es2017',
    platform: 'browser',
    tsconfig: 'tsconfig.json',
  })
  const bundleBase64 = Buffer.from(build.outputFiles[0].contents)
    .toString('base64')

  const repeated = Array.from({ length: 16 }, (_, index) => `
    <p id="paragraph-${index}">
      Paragraph ${index}. This semantic O'Reilly fixture sentence has enough
      words to wrap across several complete lines in the reading column.
      Its stable source coordinates must survive viewport scrolling.
    </p>`).join('')

  const html = `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>
html,body{margin:0;width:100%;min-height:100%;font-family:Arial,sans-serif}
#siteHeader{
  position:fixed;z-index:20;left:0;right:0;top:0;height:58px;
  background:#111;color:white;display:flex;align-items:center;padding:0 16px
}
#sidebar{position:fixed;right:0;top:58px;width:28px;height:240px}
.orm-ChapterReader-readerContainer{width:100%;padding-top:82px}
[data-testid="contentViewer"]{width:100%}
#sbo-rt-content{width:340px;margin:0 auto;padding-bottom:30px}
#sbo-rt-content p{
  font:20px/30px Georgia,serif;margin:0 0 24px;white-space:normal
}
#hiddenText{display:none}
#nativeOccluded{
  position:fixed;z-index:2;left:40px;right:40px;top:600px;
  font:18px/26px Georgia,serif
}
#result{position:fixed;left:0;top:60px;z-index:100;background:white;font:10px monospace}
[data-testid="statusBar"]{margin:20px}
</style></head><body>
<header id="siteHeader">HEADER NAVIGATION SENTINEL MUST NEVER BE SPOKEN</header>
<aside id="sidebar">SIDEBAR SENTINEL MUST NEVER BE SPOKEN</aside>
<main class="orm-ChapterReader-readerContainer">
  <section data-testid="contentViewer">
    <article id="sbo-rt-content">
      <h1 id="chapter-heading">A Semantic Chapter Heading</h1>
      <p id="hiddenText">HIDDEN SENTINEL MUST NEVER BE SPOKEN</p>
      ${repeated}
      <p id="nativeOccluded">NATIVE BOTTOM OCCLUSION SENTINEL</p>
    </article>
  </section>
</main>
<nav data-testid="statusBar">
  <div data-testid="statusBarPrevious">
    <a href="/library/view/building-applications-with/9781098176495/preface01.html">Previous</a>
  </div>
  <div data-testid="statusBarNext">
    <a href="/library/view/building-applications-with/9781098176495/ch02.html">Next</a>
  </div>
</nav>
<pre id="result">pending</pre>
<script>
eval(atob('${bundleBase64}'));

function assert(value, message) {
  if (!value) throw new Error(message);
}
const delay = milliseconds =>
  new Promise(resolve => setTimeout(resolve, milliseconds));
function sourceRange(element, start, end) {
  const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
  let cursor = 0;
  let startNode = null;
  let startOffset = 0;
  let endNode = null;
  let endOffset = 0;
  let node;
  while ((node = walker.nextNode())) {
    const length = node.textContent?.length || 0;
    if (!startNode && start <= cursor + length) {
      startNode = node;
      startOffset = Math.max(0, start - cursor);
    }
    if (end <= cursor + length) {
      endNode = node;
      endOffset = Math.max(0, end - cursor);
      break;
    }
    cursor += length;
  }
  if (!startNode || !endNode) return null;
  const range = document.createRange();
  range.setStart(startNode, startOffset);
  range.setEnd(endNode, endOffset);
  return range;
}
function sourceRangesOverlap(left, right) {
  return (
    left.sourceParagraphIndex === right.sourceParagraphIndex &&
    Math.max(left.sourceStart, right.sourceStart) <
      Math.min(left.sourceEnd, right.sourceEnd)
  );
}

async function run() {
  const direct =
    'https://learning.oreilly.com/library/view/book-slug/9781098176495/ch01.html';
  const proxy =
    'https://learning-oreilly-com.ezproxy.example.edu/library/view/book-slug/9781098176495/ch01.html';
  assert(
    OReillyFixture.isTrustedOReillyReaderURL(direct),
    'direct O’Reilly reader URL was rejected'
  );
  assert(
    OReillyFixture.isTrustedOReillyReaderURL(proxy),
    'institution proxy reader URL was rejected'
  );
  assert(
    !OReillyFixture.isTrustedOReillyReaderURL(
      'https://learning-oreilly-com.evil.com/library/view/book-slug/9781098176495/ch01.html'
    ),
    'generic look-alike proxy host was accepted'
  );
  assert(
    !OReillyFixture.isTrustedOReillyReaderURL(
      'https://learning-oreilly-com.bad-.ezproxy.edu/library/view/book-slug/9781098176495/ch01.html'
    ),
    'invalid DNS label was accepted as an institution proxy'
  );
  assert(
    !OReillyFixture.isTrustedOReillyReaderURL(
      'https://www.oreilly.com/library/view/book-slug/9781098176495/ch01.html'
    ),
    'marketing host was accepted as a reader origin'
  );
  assert(
    !OReillyFixture.isTrustedOReillyReaderURL(
      'https://learning.oreilly.com/profile/'
    ),
    'profile was accepted as reader content'
  );
  assert(
    OReillyFixture.isTrustedOReillyChapterURL(
      direct,
      'https://learning.oreilly.com/library/view/book-slug/9781098176495/ch02.html'
    ),
    'same-book chapter link was rejected'
  );
  assert(
    !OReillyFixture.isTrustedOReillyChapterURL(
      direct,
      'https://learning.oreilly.com/library/view/book-slug/DIFFERENT/ch02.html'
    ),
    'different-book chapter link was trusted'
  );
  assert(
    !OReillyFixture.isTrustedOReillyChapterURL(
      direct,
      'https://learning-oreilly-com.ezproxy.example.edu/library/view/book-slug/9781098176495/ch02.html'
    ),
    'cross-origin chapter link was trusted'
  );

  OReillyFixture.setOReillyNativeBottomOcclusion(95);
  const clip = OReillyFixture.oReillyViewportClip();
  assert(clip && clip.top >= 57, 'fixed reader header was not occluded');
  assert(
    clip.bottom <= innerHeight - 94,
    'native bottom player occlusion was ignored'
  );

  const initial = OReillyFixture.extractOReillyParagraphs();
  const initialText = initial.map(value => value.text).join(' ');
  assert(
    initial.length >= 1,
    'no semantic O’Reilly page was extracted: ' +
      JSON.stringify({
        innerWidth,
        innerHeight,
        clip,
        root: (() => {
          const rect = document.getElementById('sbo-rt-content')
            .getBoundingClientRect();
          return {
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
          };
        })(),
        heading: (() => {
          const rect = document.getElementById('chapter-heading')
            .getBoundingClientRect();
          return {
            left: rect.left,
            top: rect.top,
            right: rect.right,
            bottom: rect.bottom,
          };
        })(),
      })
  );
  assert(
    initialText.includes('Semantic') ||
      initialText.includes('Paragraph 0.'),
    'visible chapter content is missing'
  );
  assert(
    !initialText.includes('HEADER NAVIGATION SENTINEL') &&
      !initialText.includes('SIDEBAR SENTINEL') &&
      !initialText.includes('HIDDEN SENTINEL'),
    'non-content chrome leaked into speech'
  );
  assert(
    !initialText.includes('NATIVE BOTTOM OCCLUSION SENTINEL'),
    'native-player-covered text leaked into speech'
  );
  initial.forEach(paragraph => {
    assert(
      paragraph.exactText === true &&
        paragraph.text === paragraph.element.textContent
          .slice(paragraph.sourceStart, paragraph.sourceEnd),
      'visible text no longer matches its exact UTF-16 source slice'
    );
    const range = sourceRange(
      paragraph.element,
      paragraph.sourceStart,
      paragraph.sourceEnd
    );
    assert(
      range && Array.from(range.getClientRects()).length > 0,
      'extracted semantic element has no rendered geometry'
    );
    Array.from(range.getClientRects()).forEach(rect => {
      if (rect.width <= 0 || rect.height <= 0) return;
      assert(
        rect.left >= clip.left - 0.75 &&
          rect.right <= clip.right + 0.75 &&
          rect.top >= clip.top - 0.75 &&
          rect.bottom <= clip.bottom + 0.75,
        'partially occluded text fragment entered the visual page'
      );
    });
  });

  const firstSignature = OReillyFixture.oReillySignature();
  const preview = OReillyFixture.extractOReillyNextPagePreview();
  assert(
    preview && preview.paragraphs.length > 0,
    'next visual viewport was not preloaded'
  );
  assert(
    preview.contentFingerprint &&
      preview.contentFingerprint !== firstSignature,
    'preview did not receive an independent content fingerprint'
  );
  const currentTail = initial[initial.length - 1];
  const previewHead = preview.paragraphs[0];
  assert(
    previewHead.sourceParagraphIndex !== currentTail.sourceParagraphIndex ||
      previewHead.sourceEnd > currentTail.sourceEnd,
    'next-page preview did not advance in source order'
  );
  assert(
    !initial.some(current =>
      preview.paragraphs.some(candidate =>
        sourceRangesOverlap(current, candidate)
      )
    ),
    'next-page preview repeats an already-visible source range'
  );
  const speechPreview = OReillyFixture.extractOReillyNextSpeechPreview();
  assert(
    speechPreview &&
      /^[0-9a-f]{8}$/.test(speechPreview.contentFingerprint),
    'bounded speech preview did not use the native 8-hex fingerprint contract'
  );

  scrollTo(0, 520);
  await delay(120);
  const scrolledSignature = OReillyFixture.oReillySignature();
  assert(
    scrolledSignature && scrolledSignature !== firstSignature,
    'visual page signature did not change after scrolling'
  );
  scrollTo(0, 0);
  await delay(120);

  const messages = [];
  const extracts = [];
  let highlightClears = 0;
  let markClears = 0;
  window.CR = {
    clearHighlight() { highlightClears += 1; },
    clearMarks() { markClears += 1; }
  };
  OReillyFixture.installOReillyReader(
    (type, payload = {}) => messages.push({type, payload}),
    (reason, metadata = {}) => extracts.push({reason, metadata}),
    'orf-fixture'
  );
  await delay(900);
  assert(
    extracts.some(value => value.reason === 'initial'),
    'adapter did not publish its stable initial visual page'
  );
  assert(
    messages.some(message =>
      message.type === 'googleBooksLocation' &&
      message.payload.source === 'oreilly' &&
      message.payload.href === location.href &&
      typeof message.payload.signature === 'string'
    ),
    'initial visual page did not publish its reader location'
  );
  assert(
    window.CastReaderOReilly === window.CastReaderGoogleBooks,
    'compatibility wire API aliases diverged'
  );
  assert(
    window.CR.gbNextPage && window.CR.gbManualPage &&
      window.CR.gbRestoreAnchor &&
      window.CR.gbRefresh && window.CR.gbRelayout,
    'shared gb* wire commands were not installed'
  );

  const beforeManual = scrollY;
  const manualAccepted = window.CastReaderOReilly.userPage({
    direction: 'next',
    manualIntentID: 'fixture-manual',
    baselineSignature: OReillyFixture.oReillySignature(),
    originFrameSessionID: 'orf-fixture'
  });
  assert(manualAccepted, 'native manual next-page request was rejected');
  await delay(1_050);
  assert(scrollY > beforeManual, 'manual next page did not scroll one viewport');
  const afterManualParagraphs = OReillyFixture.extractOReillyParagraphs();
  assert(
    !initial.some(current =>
      afterManualParagraphs.some(candidate =>
        sourceRangesOverlap(current, candidate)
      )
    ),
    'manual visual turn repeated source text from the prior page'
  );
  const manualIntent = messages.find(message =>
    message.type === 'googleBooksPageChanging' &&
    message.payload.source === 'oreilly' &&
    message.payload.reason === 'manual' &&
    message.payload.phase === 'intent' &&
    message.payload.manualIntentID === 'fixture-manual'
  );
  const manualChanged = messages.find(message =>
    message.type === 'googleBooksPageChanging' &&
    message.payload.reason === 'manual' &&
    message.payload.phase === 'changed' &&
    message.payload.manualIntentID === 'fixture-manual'
  );
  assert(
    manualIntent,
    'manual intent was not announced before scrolling: ' +
      JSON.stringify(messages.map(message => ({
        type: message.type,
        reason: message.payload.reason,
        phase: message.payload.phase,
        intent: message.payload.intent,
        manualIntentID: message.payload.manualIntentID,
        source: message.payload.source,
      })))
  );
  assert(
    manualChanged,
    'stable manual page was not committed: ' +
      JSON.stringify(messages.map(message => ({
        type: message.type,
        reason: message.payload.reason,
        phase: message.payload.phase,
        manualIntentID: message.payload.manualIntentID,
      })))
  );
  assert(
    extracts.some(value =>
      value.reason === 'manual' &&
      value.metadata.manualIntentID === 'fixture-manual'
    ),
    'manual transaction identity did not reach extraction'
  );
  assert(
    messages.some(message =>
      message.type === 'googleBooksLocation' &&
      message.payload.signature ===
        OReillyFixture.oReillySignature()
    ),
    'manual visual-page commit did not publish a location anchor'
  );
  assert(
    !messages.some(message =>
      message.type === 'googleBooksTurnRequested' &&
      message.payload.manualIntentID === 'fixture-manual'
    ),
    'manual control entered the automatic-turn pipeline'
  );

  const beforeAuto = scrollY;
  const autoBaseline = OReillyFixture.oReillySignature();
  const autoAccepted = window.CastReaderOReilly.nextPage({
    turnID: 'fixture-auto',
    baselineSignature: autoBaseline,
    originFrameSessionID: 'orf-fixture'
  });
  assert(autoAccepted, 'automatic next-page request was rejected');
  await delay(1_050);
  assert(scrollY > beforeAuto, 'automatic next page did not scroll');
  assert(
    messages.some(message =>
      message.type === 'googleBooksTurnRequested' &&
      message.payload.source === 'oreilly' &&
      message.payload.method === 'scroll' &&
      message.payload.turnID === 'fixture-auto'
    ),
    'automatic turn request was not reported'
  );
  assert(
    extracts.some(value =>
      value.reason === 'auto' &&
      value.metadata.turnID === 'fixture-auto'
    ),
    'automatic transaction identity did not reach extraction'
  );
  assert(
    highlightClears >= 3 && markClears >= 3,
    'old page highlight/marks were not cleared around visual commits'
  );

  await delay(300);
  const detectedBefore = extracts.length;
  scrollBy(0, 110);
  await delay(1_000);
  assert(
    extracts.length > detectedBefore &&
      extracts.slice(detectedBefore).some(value =>
        value.reason === 'manual' &&
        typeof value.metadata.manualIntentID === 'string'
      ),
    'unowned user-style scroll did not settle as a manual visual page'
  );

  const beforeRelayoutCount = extracts.length;
  window.CastReaderOReilly.relayout({
    bottomOcclusion: 120,
    reason: 'fixture-native-player'
  });
  await delay(900);
  assert(
    extracts.length > beforeRelayoutCount &&
      extracts[extracts.length - 1].reason === 'refresh',
    'native occlusion relayout did not refresh the stable visual page'
  );

  // A reconstructed same-chapter renderer receives the last persisted source
  // anchor after its viewport geometry may have changed. Move away from the
  // saved page, change the native occlusion, and ensure semantic source
  // coordinates (not stale pixels) restore the same paragraph/range.
  const savedLocation = messages
    .filter(message => message.type === 'googleBooksLocation')
    .slice(-1)[0]?.payload;
  assert(
    savedLocation &&
      Number.isSafeInteger(savedLocation.sourceParagraphIndex) &&
      Number.isSafeInteger(savedLocation.sourceUTF16Start),
    'location payload did not persist a semantic O’Reilly source anchor'
  );
  const savedSourceParagraphIndex = savedLocation.sourceParagraphIndex;
  const savedSourceUTF16Start = savedLocation.sourceUTF16Start;
  window.CastReaderOReilly.relayout({
    bottomOcclusion: 72,
    reason: 'fixture-restored-viewport'
  });
  await delay(900);
  scrollTo(0, 0);
  await delay(1_000);
  const restoreLocationCount = messages.filter(
    message => message.type === 'googleBooksLocation'
  ).length;
  const wrongChapterURL = new URL(location.href);
  wrongChapterURL.pathname =
    wrongChapterURL.pathname.slice(
      0,
      wrongChapterURL.pathname.lastIndexOf('/') + 1
    ) + 'different-chapter.html';
  assert(
    !window.CastReaderOReilly.restoreAnchor({
      ...savedLocation,
      expectedHref: wrongChapterURL.href
    }),
    'restore anchor accepted a different chapter pathname'
  );
  const canonicalVariantURL = new URL(location.href);
  canonicalVariantURL.searchParams.set('canonicalized', 'fixture');
  canonicalVariantURL.hash = 'reader-fragment';
  assert(
    window.CastReaderOReilly.restoreAnchor({
      ...savedLocation,
      expectedHref: canonicalVariantURL.href
    }),
    'same-chapter anchor was rejected after query/fragment canonicalization'
  );
  await delay(1_100);
  const restoredPage = OReillyFixture.extractOReillyParagraphs();
  assert(
    restoredPage.some(paragraph =>
      paragraph.sourceParagraphIndex === savedSourceParagraphIndex &&
      paragraph.sourceStart <= savedSourceUTF16Start &&
      paragraph.sourceEnd > savedSourceUTF16Start
    ),
    'viewport change did not restore the saved semantic source range: ' +
      JSON.stringify({
        savedSourceParagraphIndex,
        savedSourceUTF16Start,
        scrollY,
        clip: OReillyFixture.oReillyViewportClip(),
        restoredPage: restoredPage.map(paragraph => ({
          text: paragraph.text,
          sourceParagraphIndex: paragraph.sourceParagraphIndex,
          sourceStart: paragraph.sourceStart,
          sourceEnd: paragraph.sourceEnd,
        })),
      })
  );
  assert(
    messages
      .filter(message => message.type === 'googleBooksLocation')
      .slice(restoreLocationCount)
      .some(message =>
        message.payload.sourceParagraphIndex === savedSourceParagraphIndex
      ),
    'restored semantic source anchor was not republished to native'
  );
  // O'Reilly can apply its own saved pixel offset after our first stable
  // extraction. During the short restore-protection window the semantic
  // anchor must win; explicit user turn APIs cancel this protection.
  scrollTo(0, 0);
  await delay(420);
  const protectedPage = OReillyFixture.extractOReillyParagraphs();
  assert(
    protectedPage.some(paragraph =>
      paragraph.sourceParagraphIndex === savedSourceParagraphIndex &&
      paragraph.sourceStart <= savedSourceUTF16Start &&
      paragraph.sourceEnd > savedSourceUTF16Start
    ),
    'late site scroll overrode the protected semantic restore anchor'
  );
  await delay(420);

  // Exercise status-bar links as a real same-origin SPA. O'Reilly deployments
  // can intercept the anchor instead of performing a full document reload.
  // The transaction must still settle and preserve its stored direction.
  const root = document.getElementById('sbo-rt-content');
  const originalChapterHTML = root.innerHTML;
  OReillyFixture.positionOReillyChapterEntry('prev');
  await delay(1_000);

  const nextLink = document.querySelector(
    '[data-testid="statusBarNext"] a'
  );
  nextLink.addEventListener('click', event => {
    event.preventDefault();
    const href = event.currentTarget.href;
    history.pushState({}, '', href);
    setTimeout(() => {
      root.innerHTML =
        '<h1 id="chapter-two-heading">A Different Second Chapter</h1>' +
        Array.from({length: 12}, (_, index) =>
          '<p id="chapter-two-' + index + '">' +
          'Chapter two paragraph ' + index +
          '. This replacement content proves that a same-document route ' +
          'transition has finished before CastReader commits the page.</p>'
        ).join('');
    }, 120);
  }, { once: true });

  const spaNextAccepted = window.CastReaderOReilly.nextPage({
    turnID: 'fixture-spa-next',
    baselineSignature: OReillyFixture.oReillySignature(),
    originFrameSessionID: 'orf-fixture'
  });
  assert(spaNextAccepted, 'SPA next-chapter request was rejected');
  const storedNext = JSON.parse(
    sessionStorage.getItem('__castreaderOReillyPendingChapterTurnV1')
  );
  assert(
    storedNext && storedNext.direction === 'next',
    'stored next-chapter turn lost its direction: ' +
      JSON.stringify({
        storedNext,
        scrollY,
        rootBottom: root.getBoundingClientRect().bottom,
        clip: OReillyFixture.oReillyViewportClip(),
        recentMessages: messages.slice(-5),
      })
  );
  await delay(1_250);
  assert(
    extracts.some(value =>
      value.reason === 'auto' &&
      value.metadata.turnID === 'fixture-spa-next'
    ),
    'same-document next chapter never settled: ' +
      JSON.stringify({
        pathname: location.pathname,
        viewport: { width: innerWidth, height: innerHeight },
        scrollY,
        clip: OReillyFixture.oReillyViewportClip(),
        signature: OReillyFixture.oReillySignature(),
        currentParagraphs: OReillyFixture.extractOReillyParagraphs().map(
          value => ({
            text: value.text,
            sourceStart: value.sourceStart,
            sourceEnd: value.sourceEnd,
          })
        ),
        storedNext: JSON.parse(
          sessionStorage.getItem('__castreaderOReillyPendingChapterTurnV1')
        ),
        rootRect: (() => {
          const rect = root.getBoundingClientRect();
          return {
            top: rect.top,
            bottom: rect.bottom,
            height: rect.height,
          };
        })(),
        rootText: root.textContent.replace(/\\s+/g, ' ').trim().slice(0, 180),
        recentMessages: messages.slice(-10),
        recentExtracts: extracts.slice(-5),
      })
  );
  const nextChapterClip = OReillyFixture.oReillyViewportClip();
  const nextChapterPage = OReillyFixture.extractOReillyParagraphs();
  const nextChapterHeading = document.getElementById('chapter-two-heading');
  const nextChapterHeadingRect = nextChapterHeading.getBoundingClientRect();
  const nextChapterFirstRange = nextChapterPage[0]
    ? sourceRange(
        nextChapterHeading,
        nextChapterPage[0].sourceStart,
        nextChapterPage[0].sourceEnd
      )
    : null;
  const nextChapterFirstRects = nextChapterFirstRange
    ? Array.from(nextChapterFirstRange.getClientRects())
    : [];
  assert(
    location.pathname.endsWith('/ch02.html') &&
      nextChapterPage[0]?.element === nextChapterHeading &&
      nextChapterPage[0]?.sourceStart === 0 &&
      nextChapterFirstRects.length > 0 &&
      nextChapterFirstRects.every(rect =>
        rect.top >= nextChapterClip.top - 1 &&
        rect.bottom <= nextChapterClip.bottom + 1
      ),
    'next chapter did not commit from its first complete semantic line: ' +
      JSON.stringify({
        pathname: location.pathname,
        scrollY,
        clip: nextChapterClip,
        headingRect: {
          top: nextChapterHeadingRect.top,
          bottom: nextChapterHeadingRect.bottom,
        },
        firstParagraph: nextChapterPage[0] && {
          text: nextChapterPage[0].text,
          sourceStart: nextChapterPage[0].sourceStart,
          sourceEnd: nextChapterPage[0].sourceEnd,
        },
      })
  );
  assert(
    messages.some(message =>
      message.type === 'googleBooksLocation' &&
      message.payload.href.includes('/ch02.html')
    ),
    'SPA next chapter did not publish its new location'
  );
  assert(
    sessionStorage.getItem(
      '__castreaderOReillyPendingChapterTurnV1'
    ) === null,
    'SPA next-chapter turn left a stale reload transaction'
  );

  const previousLink = document.querySelector(
    '[data-testid="statusBarPrevious"] a'
  );
  previousLink.addEventListener('click', event => {
    event.preventDefault();
    const href = event.currentTarget.href;
    history.pushState({}, '', href);
    setTimeout(() => {
      root.innerHTML = originalChapterHTML;
    }, 120);
  }, { once: true });

  const spaPrevAccepted = window.CastReaderOReilly.prevPage({
    turnID: 'fixture-spa-prev',
    baselineSignature: OReillyFixture.oReillySignature(),
    originFrameSessionID: 'orf-fixture'
  });
  assert(spaPrevAccepted, 'SPA previous-chapter request was rejected');
  const storedPrev = JSON.parse(
    sessionStorage.getItem('__castreaderOReillyPendingChapterTurnV1')
  );
  assert(
    storedPrev && storedPrev.direction === 'prev',
    'stored previous-chapter turn lost its direction'
  );
  await delay(1_350);
  const previousClip = OReillyFixture.oReillyViewportClip();
  const previousPage = OReillyFixture.extractOReillyParagraphs();
  const previousTail = previousPage[previousPage.length - 1];
  const previousMaximum =
    document.scrollingElement.scrollHeight - innerHeight;
  assert(
    extracts.some(value =>
      value.reason === 'auto' &&
      value.metadata.turnID === 'fixture-spa-prev'
    ),
    'same-document previous chapter never settled'
  );
  assert(
    location.pathname.endsWith('/preface01.html') &&
      previousClip &&
      previousTail &&
      previousTail.element.id === 'paragraph-15' &&
      previousTail.sourceEnd ===
        previousTail.element.textContent.trimEnd().length,
    'previous chapter did not commit from its final visual viewport: ' +
      JSON.stringify({
        href: location.href,
        scrollY,
        scrollHeight: document.scrollingElement.scrollHeight,
        rootBottom: root.getBoundingClientRect().bottom,
        previousClip,
        previousMaximum,
        previousPage: previousPage.map(paragraph => ({
          id: paragraph.element.id,
          start: paragraph.sourceStart,
          end: paragraph.sourceEnd,
          text: paragraph.text,
        })),
        recentMessages: messages.slice(-6),
      })
  );
  assert(
    messages.some(message =>
      message.type === 'googleBooksLocation' &&
      message.payload.href.includes('/preface01.html')
    ),
    'SPA previous chapter did not publish its new location'
  );

  return {
    ok: true,
    initialParagraphs: initial.length,
    previewParagraphs: preview.paragraphs.length,
    manualScrollDelta: Math.round(scrollY - beforeManual),
    messages: messages.length,
    highlightClears,
  };
}

run().then(value => {
  document.getElementById('result').textContent = JSON.stringify(value);
}).catch(error => {
  document.getElementById('result').textContent =
    JSON.stringify({ok:false,error:String(error?.stack || error)});
});
</script></body></html>`

  const fixturePath = join(scratch, 'fixture.html')
  writeFileSync(fixturePath, html)
  const keyPath = join(scratch, 'fixture-key.pem')
  const certificatePath = join(scratch, 'fixture-cert.pem')
  const opensslConfigPath = join(scratch, 'openssl.cnf')
  writeFileSync(opensslConfigPath, `[req]
distinguished_name = dn
x509_extensions = extensions
prompt = no
[dn]
CN = learning.oreilly.com
[extensions]
subjectAltName = DNS:learning.oreilly.com
`)
  const certificate = spawnSync('/usr/bin/openssl', [
    'req',
    '-x509',
    '-nodes',
    '-newkey',
    'rsa:2048',
    '-keyout',
    keyPath,
    '-out',
    certificatePath,
    '-days',
    '1',
    '-config',
    opensslConfigPath,
  ], {
    encoding: 'utf8',
    timeout: 10_000,
  })
  if (certificate.status !== 0) {
    throw new Error(certificate.stderr || 'failed to create fixture TLS certificate')
  }

  const serverPath = join(scratch, 'fixture-server.mjs')
  writeFileSync(serverPath, `
import { readFileSync } from 'node:fs';
import { createServer } from 'node:https';
const [keyPath, certificatePath, fixturePath] = process.argv.slice(2);
const server = createServer({
  key: readFileSync(keyPath),
  cert: readFileSync(certificatePath),
}, (_request, response) => {
  response.writeHead(200, {
    'content-type': 'text/html; charset=utf-8',
    'cache-control': 'no-store',
  });
  response.end(readFileSync(fixturePath));
});
server.listen(0, '127.0.0.1', () => {
  process.send?.({ port: server.address().port });
});
process.on('SIGTERM', () => server.close(() => process.exit(0)));
`)
  fixtureServer = fork(
    serverPath,
    [keyPath, certificatePath, fixturePath],
    { stdio: ['ignore', 'ignore', 'pipe', 'ipc'] }
  )
  const serverPort = await new Promise((resolve, reject) => {
    const timeout = setTimeout(
      () => reject(new Error('fixture HTTPS server did not start')),
      5_000
    )
    fixtureServer.once('message', message => {
      clearTimeout(timeout)
      resolve(message.port)
    })
    fixtureServer.once('error', error => {
      clearTimeout(timeout)
      reject(error)
    })
  })
  const result = spawnSync(chrome, [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--ignore-certificate-errors',
    '--no-proxy-server',
    '--host-resolver-rules=MAP learning.oreilly.com 127.0.0.1',
    `--user-data-dir=${join(scratch, 'chrome-profile')}`,
    `--window-size=${fixtureWindowSize}`,
    '--virtual-time-budget=18000',
    '--dump-dom',
    `https://learning.oreilly.com:${serverPort}/library/view/building-applications-with/9781098176495/ch01.html`,
  ], {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    timeout: 24_000,
  })
  const match = result.stdout.match(/<pre id="result">([\s\S]*?)<\/pre>/)
  if (!match) {
    throw new Error(
      result.error?.message ||
      result.stderr ||
      `fixture result marker missing (Chrome ${result.status}, ${result.signal || 'no signal'})`
    )
  }
  const decoded = match[1]
    .replace(/&quot;/g, '"')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
  const report = JSON.parse(decoded)
  if (!report.ok) throw new Error(report.error || 'O’Reilly fixture failed')
  process.stdout.write(`${JSON.stringify(report)}\n`)
} finally {
  fixtureServer?.kill('SIGTERM')
  rmSync(scratch, { recursive: true, force: true })
}
