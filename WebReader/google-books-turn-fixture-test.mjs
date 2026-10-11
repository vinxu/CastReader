// Exercise the production page observer and relay in a real DOM, with a
// controlled clock so a resize is still settling when the audio requests Next.
// Run from WebReader: node google-books-turn-fixture-test.mjs
import * as esbuild from 'esbuild'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const chrome = process.env.CASTREADER_CHROME ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const scratch = mkdtempSync(join(tmpdir(), 'castreader-google-turn-fixture-'))

try {
  const build = await esbuild.build({
    entryPoints: ['src/play-books.ts'], bundle: true, write: false,
    format: 'iife', globalName: 'PlayBooks', target: 'es2017', platform: 'browser',
    define: { __CASTREADER_XCTEST_FIXTURES__: 'false' },
  })
  const bundle = Buffer.from(build.outputFiles[0].contents).toString('base64')
  for (const native of [false, true]) {
    const pages = ['Current source sentence.', 'Exact next source sentence.', 'A later source sentence.']
      .map((text, i) => `<reader-page id="page-0-${i}" class="${i === 0 ? 'shown ' : ''}-gb-loaded">
        <reader-rendered-page class="-gb-text layout" style="width:350px;height:500px">
          <div class="gb-segment"><p>${text}</p></div>
        </reader-rendered-page></reader-page>`).join('')
    const html = `<!doctype html><meta charset="utf-8"><style>
      html,body{margin:0;width:100%;height:100%}
      reader-horizontal-view,reader-rendered-page{display:block}
      reader-page{display:none;width:350px;height:500px}reader-page.shown{display:block}
      p{margin:0;font:20px/28px serif}button{position:fixed;bottom:5px;right:5px}
      </style>${native ? '<reader-horizontal-view>' : '<main>'}${pages}
      ${native ? '</reader-horizontal-view>' : '</main>'}
      <button><mat-icon>chevron_right</mat-icon></button><pre id="result">pending</pre>
      <script>
      eval(atob('${bundle}'));
      try {
        const check=(ok,message)=>{if(!ok)throw new Error(message)};
        let now=0,serial=0,clicks=0;const jobs=new Map(),messages=[],extracts=[];
        Date.now=()=>100000+now;
        window.setTimeout=(fn,delay=0)=>{const id=++serial;jobs.set(id,{fn,at:now+Math.max(1,delay),period:0});return id};
        window.setInterval=(fn,delay=0)=>{const id=++serial;jobs.set(id,{fn,at:now+Math.max(1,delay),period:Math.max(1,delay)});return id};
        window.clearTimeout=window.clearInterval=id=>jobs.delete(id);
        window.requestAnimationFrame=fn=>setTimeout(()=>fn(now),16);
        window.cancelAnimationFrame=clearTimeout;
        const tick=ms=>{const until=now+ms;let count=0;while(true){
          const next=[...jobs].filter(([,j])=>j.at<=until).sort((a,b)=>a[1].at-b[1].at||a[0]-b[0])[0];
          if(!next)break;if(++count>10000)throw new Error('timer loop');
          const [id,job]=next;now=job.at;if(job.period)job.at+=job.period;else jobs.delete(id);job.fn();
        }now=until};
        const frameID='active-reader-frame';
        document.querySelector('button').addEventListener('click',()=>{
          clicks++;const shown=document.querySelector('reader-page.shown');
          const next=shown.nextElementSibling;if(next){shown.classList.remove('shown');next.classList.add('shown')}
        });
        PlayBooks.installPlayBooksReader((type,payload)=>messages.push({type,payload}),
          (reason,metadata)=>extracts.push({reason,metadata,signature:PlayBooks.playBooksSignature(),
            text:PlayBooks.extractPlayBooksParagraphs().map(p=>p.text).join('|')}),frameID);
        PlayBooks.installPlayBooksRelayReceiver(frameID);
        const send=(fn,arg)=>window.dispatchEvent(new MessageEvent('message',{
          origin:'https://play.google.com',data:{__castreaderGB:1,fn,arg}}));
        tick(260);check(extracts.length===1&&extracts[0].reason==='initial','initial readable surface');
        const baseline=PlayBooks.playBooksSignature();
        document.querySelectorAll('reader-rendered-page').forEach(p=>p.style.width='330px');
        tick(250); // The 500ms observer started refresh; its first settle sample is still pending.
        check(extracts.length===1,'resize must not have settled before the turn');
        const metadata={turnID:'audio-edge-1',baselineSignature:baseline,originFrameSessionID:frameID,
          __gbFrameSessionID:frameID,sourcePresentation:{id:'paint-hold-1',sourceParagraphIndex:1,sourceStart:0,sourceEnd:5,text:'Exact'}};
        send('gbNextPage',{...metadata,__gbFrameSessionID:'retired-reader-frame'});
        check(clicks===0,'a retired frame target must not turn this reader');
        send('gbNextPage',metadata);
        send('gbNextPage',metadata);
        check(clicks===1,'duplicate pending request must perform exactly one physical turn');
        tick(20);
        send('gbRefresh',{}); // A concurrent geometry probe must not steal the automatic settle timer.
        tick(1400);
        const committed=extracts.filter(e=>e.reason!=='initial');
        check(committed.length===1&&committed[0].reason==='auto',
          'resize must yield to one automatic commit: '+JSON.stringify(committed));
        check(committed[0].metadata.turnID===metadata.turnID&&
          committed[0].metadata.baselineSignature===baseline&&
          committed[0].metadata.originFrameSessionID===frameID&&
          committed[0].metadata.sourcePresentation.id==='paint-hold-1','automatic identity and paint witness must survive resize');
        check(committed[0].text==='Exact next source sentence.','the committed DOM must be the actual next page');
        check(messages.filter(m=>m.type==='googleBooksPageChanging'&&m.payload.phase==='changed').length===1,
          'only one visual departure may be committed');
        check(messages.filter(m=>m.type==='googleBooksTurnRequested').length===1,'only one turn request');
        send('gbNextPage',{...metadata,__gbFrameSessionID:'retired-reader-frame'});
        tick(6000);
        check(clicks===1&&extracts.length===2,'old frame and expired timers cannot repeat a committed turn');
        check(!messages.some(m=>m.type==='googleBooksTurnFailed'),'the confirmed turn cannot later time out');
        // A later resize with no semantic turn must retain ordinary refresh behavior.
        document.querySelectorAll('reader-rendered-page').forEach(p=>p.style.width='320px');
        tick(1200);
        check(extracts.length===3&&extracts[2].reason==='refresh'&&!extracts[2].metadata.turnID,
          'standalone resize must not inherit an old automatic identity');
        document.getElementById('result').textContent=JSON.stringify({ok:true,native:${native},clicks,
          presentation:committed[0].metadata.presentation});
      }catch(error){document.getElementById('result').textContent=JSON.stringify({ok:false,error:String(error.stack||error)})}
      </script>`
    const fixture = join(scratch, `turn-${native}.html`)
    writeFileSync(fixture, html)
    const result = spawnSync(chrome, ['--headless=new', '--disable-gpu', '--no-first-run',
      `--user-data-dir=${join(scratch, `profile-${native}`)}`, '--window-size=390,700',
      '--dump-dom', `file://${fixture}`], {encoding:'utf8', maxBuffer:16*1024*1024, timeout:14000})
    const match = result.stdout?.match(/<pre id="result">([\s\S]*?)<\/pre>/)
    if (!match) throw new Error(result.error?.message || result.stderr || 'missing fixture result')
    const report = JSON.parse(match[1].replace(/&quot;/g,'"').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>'))
    if (!report.ok) throw new Error(report.error || 'Google Books turn fixture failed')
    console.log(JSON.stringify(report))
  }
} finally {
  rmSync(scratch,{recursive:true,force:true})
}
