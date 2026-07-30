// Real-browser fixture for the Kobo TypeScript adapter.
//
// It intentionally uses two same-origin srcdoc iframes. DOM nodes in those
// frames belong to a different JavaScript realm than the shell, which catches
// the easy-to-miss `node instanceof HTMLElement` regression. The second frame
// is populated but far off screen to prove Kobo's prefetch buffer is not
// returned as the current page.

import * as esbuild from 'esbuild'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const chrome = process.env.CASTREADER_CHROME ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const scratch = mkdtempSync(join(tmpdir(), 'castreader-kobo-fixture-'))

try {
  const build = await esbuild.build({
    entryPoints: ['src/test-entry.ts'],
    bundle: true,
    write: false,
    format: 'iife',
    globalName: 'KoboFixture',
    target: 'es2017',
    platform: 'browser',
    tsconfig: 'tsconfig.json',
    define: {
      __CASTREADER_XCTEST_FIXTURES__: 'true',
    },
  })
  const bundleBase64 = Buffer.from(build.outputFiles[0].contents)
    .toString('base64')
  const semanticModulePath = join(scratch, 'index.fixture.mjs')
  writeFileSync(semanticModulePath, `
const services = {
  'UR/engine': {
    api: {
      getCurrentReadingRange() {
        return {
          percentageOfBook: 0.25,
          pagesOfBook: 100,
          begin: { pageIndexInBook: 24 },
          end: { pageIndexInBook: 24 }
        };
      },
      goToPageByBookPercentage(percentage) {
        globalThis.__koboURProgressTurns =
          globalThis.__koboURProgressTurns || [];
        globalThis.__koboURProgressTurns.push(percentage);
        globalThis.__koboApplyProgressTurn?.(percentage);
        if (globalThis.__koboRejectURTurn) {
          return Promise.reject(new Error('fixture-ur-turn-rejected'));
        }
        return Promise.resolve();
      },
      turnRight() {
        globalThis.__koboURTurns = globalThis.__koboURTurns || [];
        globalThis.__koboURTurns.push('right');
        if (globalThis.__koboRejectURTurn) {
          return Promise.reject(new Error('fixture-ur-turn-rejected'));
        }
        return Promise.resolve();
      },
      turnLeft() {
        globalThis.__koboURTurns = globalThis.__koboURTurns || [];
        globalThis.__koboURTurns.push('left');
        return Promise.resolve();
      }
    }
  },
  messageBus: {
    publish(channel, topic, data) {
      globalThis.__koboBusEvents = globalThis.__koboBusEvents || [];
      globalThis.__koboBusEvents.push([channel, topic, data]);
      if (globalThis.__koboRejectSemanticTurn) {
        return Promise.reject(new Error('fixture-no-subscriber'));
      }
      return Promise.resolve();
    }
  },
  localConfig: {
    getLocalConfig() {
      return { MESSAGE_BUS: { CHANNEL: { READER: 'reader' } } };
    }
  }
};
export function fixtureService(name) {
  if (!services[name]) throw new Error('UNKNOWN_SERVICE: ' + name);
  return services[name];
}
`)

  const html = `<!doctype html>
<html data-cr-test-fixture="1"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<script type="module" src="./index.fixture.mjs"></script>
<style>
html,body{margin:0;width:100%;height:100%;overflow:hidden}
iframe{position:absolute;top:0;width:390px;height:650px;border:0}
#current{left:0} #future{left:1600px}
button{position:fixed;z-index:20;bottom:2px}
#chapterNext{left:2px} #pageNext{right:2px}
#footerSlider{position:fixed;left:20px;bottom:40px;width:300px;height:24px}
#footerSliderBar{position:absolute;left:0;top:10px;width:300px;height:4px}
</style></head><body>
<button id="chapterNext" aria-label="Next chapter">chapter</button>
<button id="pageNext" aria-label="Next page">page</button>
<div id="footerSlider" role="slider"
  data-test-id="reader-footerBar-slider"
  aria-valuemin="0" aria-valuemax="100" aria-valuenow="25">
  <div id="footerSliderBar"
    data-test-id="reader-footerBar-slider-bar"></div>
</div>
<span data-test-id="reader-footerBar-pageNumber">25 of 100</span>
<iframe id="current"></iframe><iframe id="future"></iframe>
<pre id="result">pending</pre>
<script>
const sentence = 'Visible Kobo sentence with emoji 😀 keeps exact UTF-16 coordinates and ends here. ';
const currentHTML = '<!doctype html><html lang="en"><head><style>'+
  'html,body{margin:0;width:390px;height:650px;overflow:hidden}'+
  'article{margin:0 20px;width:350px;height:650px;column-width:350px;column-gap:40px;column-fill:auto}'+
  'p{font:22px/32px serif;margin:0 0 18px;white-space:pre-wrap}'+
  '</style></head><body><section role="doc-chapter" id="chapter-one">'+
  '<h1 class="element-title">Visible chapter</h1><div class="text"><p id="visibleP">'+
  Array.from({length:80}, (_,i) => '<span class="koboSpan" id="kobo.1.'+i+'" data-index="'+i+'">['+i+'] '+sentence+'</span>').join('')+
  '</p></div></section></body></html>';
const futureHTML = '<!doctype html><html><body><section role="doc-chapter" id="future-chapter">'+
  '<h1 class="element-title">OFFSCREEN PREFETCH SENTINEL</h1>'+
  '<p><span class="koboSpan" id="kobo.99.1">OFFSCREEN PREFETCH SENTINEL must never be current.</span></p>'+
  '</section></body></html>';
document.getElementById('current').srcdoc = currentHTML;
document.getElementById('future').srcdoc = futureHTML;
eval(atob('${bundleBase64}'));

let clicks = 0;
document.getElementById('pageNext').addEventListener('click', () => { clicks += 1; });
const sliderClicks = [];
document.getElementById('footerSlider').addEventListener('click', event => {
  sliderClicks.push({clientX: event.clientX, clientY: event.clientY});
});

function assert(value, message) {
  if (!value) throw new Error(message);
}
async function run() {
  for (let i=0; i<60; i++) {
    const ready = document.getElementById('current').contentDocument?.querySelector('#visibleP');
    if (ready) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  const full = document.getElementById('current').contentDocument
    .querySelector('#visibleP').textContent;
  const currentFrame = document.getElementById('current');
  const frameWidthBeforeTypography = currentFrame.getBoundingClientRect().width;
  assert(
    KoboFixture.ensureKoboChapterTypography() === true,
    'chapter typography was not installed'
  );
  assert(
    currentFrame.contentDocument.getElementById('castreader-kobo-typography'),
    'chapter typography style is missing from the srcdoc'
  );
  assert(
    KoboFixture.ensureKoboChapterTypography() === false,
    'chapter typography installation must be idempotent'
  );
  assert(
    currentFrame.getBoundingClientRect().width === frameWidthBeforeTypography,
    'chapter typography must not shrink the outer page width'
  );
  const frameDocument = currentFrame.contentDocument;
  const disjoint = frameDocument.createElement('p');
  disjoint.id = 'disjoint-visible-slices';
  disjoint.style.cssText =
    'position:fixed;inset:0;margin:0;padding:0;pointer-events:none';
  disjoint.innerHTML =
    '<span style="position:fixed;left:20px;top:120px">VISIBLE FIRST.</span>' +
    '<span style="position:fixed;left:900px;top:150px">HIDDEN MIDDLE MUST NOT BE SPOKEN.</span>' +
    '<span style="position:fixed;left:20px;top:180px">VISIBLE LAST.</span>';
  frameDocument.body.appendChild(disjoint);
  const disjointText = disjoint.textContent;
  const disjointRanges = KoboFixture.visibleCharRanges(
    disjoint,
    {left:0, top:0, right:390, bottom:650}
  );
  const disjointSpoken = disjointRanges
    .map(range => disjointText.slice(range.start, range.end))
    .join(' ');
  assert(
    disjointSpoken.includes('VISIBLE FIRST.') &&
      disjointSpoken.includes('VISIBLE LAST.'),
    'disjoint visible source slices were dropped'
  );
  assert(
    !disjointSpoken.includes('HIDDEN MIDDLE'),
    'bounding source range leaked an invisible middle column'
  );
  disjoint.remove();
  const edgeSliver = frameDocument.createElement('p');
  edgeSliver.style.cssText =
    'position:fixed;top:230px;display:inline-block;white-space:nowrap;' +
    'font:20px serif;margin:0;padding:0';
  edgeSliver.textContent = 'NEIGHBOURING COLUMN EDGE';
  frameDocument.body.appendChild(edgeSliver);
  const edgeWidth = edgeSliver.getBoundingClientRect().width;
  edgeSliver.style.left = String(-(edgeWidth - 8)) + 'px';
  assert(
    KoboFixture.visibleCharRanges(
      edgeSliver,
      {left:0, top:0, right:390, bottom:650}
    ).length === 0,
    'adjacent-column glyph sliver became a speech paragraph'
  );
  edgeSliver.remove();
  const fragmentSource = frameDocument.createElement('p');
  fragmentSource.textContent =
    'A long source paragraph whose adjacent-column animation must never ' +
    'become several word-sized TTS paragraphs.';
  const fragmentBase = {
    element: fragmentSource,
    exactText: true,
    sourceParagraphIndex: 9001,
    frameIndex: 0,
  };
  const transientFragments = [
    {text:'one', sourceStart:10, sourceEnd:13, charOffset:10, paragraphOrdinal:1},
    {text:'two', sourceStart:20, sourceEnd:23, charOffset:20, paragraphOrdinal:2},
    {text:'three', sourceStart:30, sourceEnd:35, charOffset:30, paragraphOrdinal:3},
  ].map(value => ({...fragmentBase, ...value}));
  assert(
    KoboFixture.koboParagraphSnapshotQuality(transientFragments).ok === false,
    'consecutive word-sized partial slices passed the snapshot quality gate'
  );
  const legitimateShortParagraphs = ['Yes.', 'No.', 'Why?'].map(
    (text, index) => {
      const element = frameDocument.createElement('p');
      element.textContent = text;
      return {
        text,
        element,
        exactText: true,
        charOffset: 0,
        sourceParagraphIndex: 9100 + index,
        sourceStart: 0,
        sourceEnd: text.length,
        frameIndex: 0,
        paragraphOrdinal: index,
      };
    }
  );
  assert(
    KoboFixture.koboParagraphSnapshotQuality(
      legitimateShortParagraphs
    ).ok === true,
    'complete short dialogue paragraphs were rejected as column fragments'
  );
  const missingSession = document.createElement('div');
  missingSession.textContent =
    'User has no active session {"name":"MissingSession",' +
    '"tag":"service/session-service"}';
  document.body.appendChild(missingSession);
  assert(
    KoboFixture.koboReaderFailureCode() === 'missing-session',
    'Kobo MissingSession page was not detected'
  );
  missingSession.remove();
  assert(
    KoboFixture.koboReaderFailureCode() === null,
    'Kobo MissingSession detector did not recover after the error disappeared'
  );
  const paragraphs = KoboFixture.extractKoboParagraphs();
  assert(paragraphs.length > 0, 'cross-realm srcdoc content was not extracted');
  assert(
    paragraphs.every(p => p.element.ownerDocument !== document),
    'fixture must exercise child-realm elements'
  );
  const spoken = paragraphs.map(p => p.text).join('\\n');
  assert(!spoken.includes('OFFSCREEN PREFETCH SENTINEL'), 'prefetch frame leaked into current page');
  assert(spoken.length < full.length / 2, 'whole chapter was returned instead of current visible column');
  assert(paragraphs.every(p =>
    Number.isInteger(p.sourceParagraphIndex) &&
    p.sourceStart >= 0 &&
    p.sourceEnd > p.sourceStart
  ), 'stable source coordinates are missing');
  assert(
    paragraphs.every(p => !p.speechText || p.speechText === p.text),
    'current page must not speak text from a future CSS column'
  );
  assert(KoboFixture.koboSignature().startsWith('kpg-'), 'page signature missing');
  const pagePreview = KoboFixture.extractKoboNextPagePreview();
  const speechPreview = KoboFixture.extractKoboNextSpeechPreview();
  assert(
    !!pagePreview || !!speechPreview,
    'no bounded next-page / next-sentence preload was produced'
  );
  if (pagePreview) {
    assert(
      !pagePreview.paragraphs.some(p => p.text.includes('OFFSCREEN PREFETCH SENTINEL')),
      'page preload jumped across the visible chapter into the future buffer'
    );
  }
  if (speechPreview) {
    assert(
      !speechPreview.text.includes('OFFSCREEN PREFETCH SENTINEL'),
      'speech preload skipped the immediate source continuation'
    );
  }
  assert(
    await KoboFixture.prepareKoboSemanticTransport(),
    'Kobo semantic reader service was not discovered'
  );
  assert(
    KoboFixture.koboSemanticTransportReady(),
    'Kobo semantic reader service did not become ready'
  );
  assert(
    KoboFixture.koboProgressSliderReady(),
    'Kobo footer progress slider was not discovered'
  );
  const sliderInvocation = KoboFixture.invokeKoboProgressSliderTurn('next');
  assert(sliderInvocation.accepted, 'Kobo footer slider turn was rejected');
  assert(sliderClicks.length === 1, 'footer slider must receive exactly one click');
  assert(
    Math.abs(sliderClicks[0].clientX - 98) < 0.6,
    'footer slider click did not target the exact next-page percentage'
  );

  const control = KoboFixture.clickableKoboPageButton('next');
  assert(control?.id === 'pageNext', 'next chapter must not win over next page');
  assert(KoboFixture.turnKoboPage('next', 'button') === 'button', 'page button did not execute');
  assert(clicks === 1, 'one semantic request must click exactly once');
  document.getElementById('pageNext').style.display = 'none';
  assert(
    KoboFixture.clickableKoboPageButton('next')?.id === 'pageNext',
    'hidden Kobo chrome must retain its callable page transport'
  );
  document.getElementById('pageNext').remove();
  const shadowHost = document.createElement('div');
  shadowHost.id = 'shadowHost';
  const shadowRoot = shadowHost.attachShadow({mode:'open'});
  const shadowNext = document.createElement('button');
  shadowNext.id = 'shadowNext';
  shadowNext.setAttribute('aria-label', 'Next page');
  shadowNext.textContent = 'shadow page';
  shadowNext.addEventListener('click', () => { clicks += 1; });
  shadowRoot.appendChild(shadowNext);
  document.body.appendChild(shadowHost);
  assert(
    KoboFixture.clickableKoboPageButton('next')?.id === 'shadowNext',
    'open shadow-root Kobo chrome was not discovered'
  );
  let arrowRightCount = 0;
  document.addEventListener('keydown', event => {
    if (event.key === 'ArrowRight') arrowRightCount += 1;
  });

  const messages = [];
  let highlightClears = 0;
  window.__koboApplyProgressTurn = percentage => {
    currentFrame.contentDocument.getElementById('visibleP').style.transform =
      percentage > 0.25 ? 'translateY(-220px)' : '';
  };
  window.CR = {
    clearHighlight(){ highlightClears += 1; },
    clearMarks(){}
  };
  KoboFixture.installKoboReader(
    (type, payload) => messages.push({type, payload}),
    (reason, metadata = {}) => {
      messages.push({
        type: 'rendered',
        payload: {
          source: 'kobo',
          reason,
          signature: KoboFixture.koboSignature(),
          frameSessionID: 'kbf-fixture',
          paragraphs: KoboFixture.extractKoboParagraphs(),
          ...metadata,
        },
      });
    },
    'kbf-fixture'
  );
  assert(typeof window.CR.gbNextPage === 'function', 'gbNextPage compatibility API missing');
  assert(window.CastReaderKobo === window.CastReaderGoogleBooks, 'wire API aliases diverged');
  assert(
    typeof window.CastReaderKobo.__fixtureManualIntent === 'function',
    'XCTest fixture API missing from fixture bundle'
  );
  for (let attempt = 0; attempt < 30; attempt++) {
    if (messages.some(message =>
      message.type === 'rendered' &&
      message.payload.reason === 'initial'
    )) break;
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert(
    messages.some(message =>
      message.type === 'rendered' &&
      message.payload.reason === 'initial'
    ),
    'Kobo reader did not publish its initial stable page'
  );
  const orientationMessageStart = messages.length;
  window.CR.gbRelayout({
    reason: 'fixture-orientation',
    width: 500,
    height: 557,
    bottomOcclusion: 72
  });
  window.dispatchEvent(new Event('resize'));
  setTimeout(() => {
    currentFrame.style.width = '470px';
    const article = currentFrame.contentDocument.querySelector('article');
    article.style.width = '430px';
    article.style.columnWidth = '430px';
  }, 320);
  setTimeout(() => {
    currentFrame.style.width = '500px';
    const article = currentFrame.contentDocument.querySelector('article');
    article.style.width = '460px';
    article.style.columnWidth = '460px';
  }, 680);
  await new Promise(resolve => setTimeout(resolve, 2_350));
  const orientationMessages = messages.slice(orientationMessageStart);
  assert(
    !orientationMessages.some(message =>
      message.type === 'googleBooksPageChanging' &&
      message.payload.reason === 'manual'
    ),
    'viewport reflow was misclassified as a manual page turn'
  );
  const orientationRefreshes = orientationMessages.filter(message =>
    message.type === 'rendered' &&
    message.payload.reason === 'refresh'
  );
  assert(
    orientationRefreshes.length === 1,
    'orientation must publish exactly one settled refresh: ' +
      JSON.stringify(orientationMessages.map(message => ({
        type: message.type,
        reason: message.payload.reason,
        phase: message.payload.phase,
        message: message.payload.message,
      })))
  );
  const settledParagraphs = KoboFixture.extractKoboParagraphs();
  assert(
    orientationRefreshes[0].payload.signature ===
      KoboFixture.koboSignature() &&
      orientationRefreshes[0].payload.paragraphs.length ===
        settledParagraphs.length,
    'orientation committed a transient rather than final viewport snapshot'
  );
  const manualNextStarted = window.CastReaderKobo.userPage({
    direction: 'next'
  });
  assert(manualNextStarted === true, 'native next-page control was not accepted');
  await new Promise(resolve => setTimeout(resolve, 1_350));
  const manualNextIntent = messages.find(message =>
    message.type === 'googleBooksPageChanging' &&
    message.payload.reason === 'manual' &&
    message.payload.phase === 'intent' &&
    message.payload.direction === 'next'
  );
  const manualNextRendered = messages.find(message =>
    message.type === 'rendered' &&
    message.payload.reason === 'manual' &&
    message.payload.manualIntentID === manualNextIntent?.payload.manualIntentID
  );
  assert(manualNextIntent, 'native next-page control did not announce manual intent');
  assert(
    manualNextRendered,
    'native next-page control did not commit a stable manual page: ' +
      JSON.stringify({
        baseline: manualNextIntent?.payload.baselineSignature,
        current: KoboFixture.koboSignature(),
        transform: currentFrame.contentDocument
          .getElementById('visibleP').style.transform,
        progressTurns: window.__koboURProgressTurns,
        messages: messages.map(message => ({
          type: message.type,
          reason: message.payload.reason,
          phase: message.payload.phase,
          signature: message.payload.signature,
          manualIntentID: message.payload.manualIntentID,
          message: message.payload.message,
        })),
      })
  );
  assert(
    manualNextRendered.payload.baselineSignature ===
      manualNextIntent.payload.baselineSignature &&
    manualNextRendered.payload.originFrameSessionID === 'kbf-fixture',
    'native next-page identity was not preserved through commit'
  );
  assert(
    !messages.some(message => message.type === 'googleBooksTurnRequested'),
    'native page control must not enter the automatic-turn pipeline'
  );

  const manualPreviousStarted = window.CastReaderKobo.userPage({
    direction: 'prev'
  });
  assert(
    manualPreviousStarted === true,
    'native previous-page control was not accepted'
  );
  await new Promise(resolve => setTimeout(resolve, 1_350));
  const manualPreviousIntent = messages.find(message =>
    message.type === 'googleBooksPageChanging' &&
    message.payload.reason === 'manual' &&
    message.payload.phase === 'intent' &&
    message.payload.direction === 'prev'
  );
  const manualPreviousRendered = messages.find(message =>
    message.type === 'rendered' &&
    message.payload.reason === 'manual' &&
    message.payload.manualIntentID ===
      manualPreviousIntent?.payload.manualIntentID
  );
  assert(
    manualPreviousIntent && manualPreviousRendered,
    'native previous-page control did not complete its manual transaction'
  );
  window.__koboURProgressTurns = [];
  messages.length = 0;
  highlightClears = 0;

  const autoStarted = window.CastReaderKobo.nextPage({
    turnID: 'fixture-auto',
    baselineSignature: KoboFixture.koboSignature(),
    originFrameSessionID: 'kbf-fixture'
  });
  assert(autoStarted === true, 'automatic turn was not accepted');
  await new Promise(resolve => setTimeout(resolve, 30));
  assert(clicks === 1, 'semantic Kobo turn must not click the desktop page control');
  assert(arrowRightCount === 0, 'automatic Kobo turn must not dispatch an untrusted key');
  assert(
    Array.isArray(window.__koboURProgressTurns) &&
    window.__koboURProgressTurns.length === 1 &&
    Math.abs(window.__koboURProgressTurns[0] - 0.26) < 0.000001,
    'automatic Kobo turn did not invoke the exact UR progress API'
  );
  assert(
    !window.__koboURTurns || window.__koboURTurns.length === 0,
    'exact UR progress must win over the physical directional API'
  );
  assert(
    !window.__koboBusEvents || window.__koboBusEvents.length === 0,
    'UR books must not use the legacy reader message bus'
  );
  assert(messages.some(message =>
    message.type === 'googleBooksTurnRequested' &&
    message.payload.method === 'semantic'
  ), 'automatic Kobo turn did not report the semantic transport');
  assert(
    highlightClears === 0,
    'automatic request cleared final highlight before visual page departure'
  );
  assert(window.CastReaderKobo.__fixtureManualIntent('next') === true, 'fixture manual intent rejected');
  assert(highlightClears === 1, 'manual intent must clear the old page highlight immediately');
  assert(messages.some(message =>
    message.type === 'googleBooksPageChanging' &&
    message.payload.source === 'kobo' &&
    message.payload.frameSessionID === 'kbf-fixture'
  ), 'Kobo source/frame identity missing from compatibility event');
  window.__koboRejectURTurn = true;
  const rejectedStarted = window.CastReaderKobo.nextPage({
    turnID: 'fixture-rejected',
    baselineSignature: KoboFixture.koboSignature(),
    originFrameSessionID: 'kbf-fixture'
  });
  assert(rejectedStarted === true, 'async semantic turn was not accepted initially');
  await new Promise(resolve => setTimeout(resolve, 30));
  assert(messages.some(message =>
    message.type === 'googleBooksTurnFailed' &&
    message.payload.turnID === 'fixture-rejected' &&
    message.payload.lateEligible === false
  ), 'rejected UR promise did not fail the exact pending turn');

  return {
    ok: true,
    paragraphCount: paragraphs.length,
    visibleUTF16: spoken.length,
    fullUTF16: full.length,
    source: messages[0]?.payload?.source,
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
  const result = spawnSync(chrome, [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--allow-file-access-from-files',
    '--disable-web-security',
    `--user-data-dir=${join(scratch, 'chrome-profile')}`,
    '--window-size=390,700',
    '--virtual-time-budget=10000',
    '--dump-dom',
    `file://${fixturePath}`,
  ], {
    encoding: 'utf8',
    maxBuffer: 16 * 1024 * 1024,
    // Some macOS Chrome builds keep a background helper alive after
    // --dump-dom has already printed the completed DOM. Stop that helper; the
    // fixture result below remains authoritative.
    timeout: 14_000,
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
  if (!report.ok) throw new Error(report.error || 'Kobo fixture failed')
  process.stdout.write(`${JSON.stringify(report)}\n`)
} finally {
  rmSync(scratch, { recursive: true, force: true })
}
