// Exercise the production WeRead reader script in a real DOM. The provider
// fixture paints synchronously inside turn(), as a native page callback can.
// Run: node WebReader/weread-reveal-fixture-test.mjs (no build or simulator).
import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const chrome = process.env.CASTREADER_CHROME ||
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
const swift = readFileSync(new URL('../CastReader/Services/WeReadWebScripts.swift', import.meta.url), 'utf8')
const match = swift.match(/static let readerBridge = #"""\n([\s\S]*?)\n\s*"""#/)
if (!match) throw new Error('Production WeRead readerBridge was not found')
const script = Buffer.from(match[1]).toString('base64')
const scratch = mkdtempSync(join(tmpdir(), 'castreader-weread-reveal-'))

try {
  for (const rejectedAttempts of [0, 4]) {
    const html = `<!doctype html><meta charset="utf-8"><style>
      body{margin:0}.wr_canvasContainer{position:relative;width:500px;height:400px}
      canvas{width:500px;height:400px}
      </style><div class="wr_canvasContainer"><canvas width="500" height="400"></canvas></div>
      <pre id="result">pending</pre><script>
      try {
        const check=(ok,message)=>{if(!ok)throw new Error(message)};
        let now=100000,serial=0;const jobs=new Map(),messages=[];
        Date.now=()=>now;
        window.setTimeout=(fn,ms=0)=>{const id=++serial;jobs.set(id,{fn,at:now+Math.max(1,ms)});return id};
        window.clearTimeout=id=>jobs.delete(id);
        window.requestAnimationFrame=fn=>setTimeout(fn,16);
        const tick=ms=>{const until=now+ms;let count=0;while(true){
          const next=[...jobs].filter(([,j])=>j.at<=until).sort((a,b)=>a[1].at-b[1].at)[0];
          if(!next)break;if(++count>2000)throw new Error('timer loop');
          jobs.delete(next[0]);now=next[1].at;next[1].fn();
        }now=until};
        const texts=['Original spoken source.','An intermediate source.','Later visible source.'];
        let page=0,depth=0,maxDepth=0,attempts=0,turns=0,rejections=${rejectedAttempts};
        const item=i=>{const text=texts[i],offset=i*100;return {
          text,sourceParagraphText:text,sourceParagraphIndex:offset,sourceLayoutFingerprint:'layout',
          nativeSourceIdentity:'book:chapter',sourceCharStart:0,sourceCharEnd:text.length,
          sourceAnchors:Array.from(text,(ch,n)=>({start:n,end:n+1,offset:offset+n,text:ch})),
          entries:Array.from(text,(ch,n)=>({charStart:n,charEnd:n+1,bbox:{x:20+n*6,y:20,width:6,height:20}})),
          bounds:{x:20,y:20,width:text.length*6,height:20},geometrySource:'native-glyphs'
        }};
        const paint=()=>{const ctx=document.querySelector('canvas').getContext('2d');
          ctx.clearRect(0,0,500,400);ctx.font='20px monospace';ctx.fillText(texts[page],20,40)};
        window.webkit={messageHandlers:{castreader:{postMessage:m=>messages.push(m)}}};
        window.__castReaderWeReadNative={
          snapshot(host,successor){const index=successor?Math.min(2,page+1):page;
            return {ready:true,items:[item(index)],pageIdentity:'page-'+index}},
          turn(direction){attempts++;if(rejections>0){rejections--;return false}
            depth++;maxDepth=Math.max(maxDepth,depth);turns++;
            page+=direction==='prev'?-1:1;
            check(page>=0&&page<texts.length,'source reveal left the authorized chapter');
            paint();document.dispatchEvent(new Event('castreader-wr-native'));
            depth--;return true;
          }
        };
        paint();eval(atob('${script}'));
        document.dispatchEvent(new Event('castreader-wr-native'));tick(500);
        check(messages.filter(m=>m.type==='wereadPage').length===1,'initial source must be committed once');
        // A resize exposes later source while speech/marks still own page 0.
        window.dispatchEvent(new Event('resize'));page=2;paint();tick(1500);
        const mark={id:'retained-source',paragraphIndex:0,charStart:0,charEnd:8,action:'underline'};
        for(let i=0;i<${rejectedAttempts};i++){
          CR.showMark(mark);
          check(attempts===i+1&&turns===0,'a rejected turn must release busy and preserve its retry budget');
        }
        CR.showMark(mark);
        check(maxDepth===1&&turns===1&&page===1,
          'synchronous native paint must not re-enter turn: '+JSON.stringify({maxDepth,turns,page}));
        check(document.querySelectorAll('#castreader-weread-marks-svg path').length===0,
          'an intermediate page must not receive an unrelated source mark');
        tick(2000);
        const ink=document.querySelectorAll('[data-cr-weread-mark-id="retained-source"] path').length;
        check(maxDepth===1&&turns===2&&page===0&&ink>0,
          'sequential source reveal must eventually paint the original mark: '+JSON.stringify({maxDepth,turns,page,ink}));
        check(messages.filter(m=>m.type==='wereadPage').length===1,
          'geometry recovery must retain the original speech/Explain scope');
        tick(3000);
        check(turns===2,'settled recovery must not navigate again');
        document.querySelector('#result').textContent=JSON.stringify({ok:true,rejectedAttempts:${rejectedAttempts},
          attempts,turns,maxDepth,page,ink});
      }catch(error){document.querySelector('#result').textContent=JSON.stringify({ok:false,
        rejectedAttempts:${rejectedAttempts},error:String(error.stack||error)})}
      </script>`
    const fixture = join(scratch, `reveal-${rejectedAttempts}.html`)
    writeFileSync(fixture, html)
    const result = spawnSync(chrome, ['--headless=new', '--disable-gpu', '--no-first-run',
      `--user-data-dir=${join(scratch, `profile-${rejectedAttempts}`)}`, '--window-size=867,600',
      '--dump-dom', `file://${fixture}`], {encoding:'utf8', maxBuffer:16*1024*1024, timeout:14000})
    const output = result.stdout?.match(/<pre id="result">([\s\S]*?)<\/pre>/)
    if (!output) throw new Error(result.error?.message || result.stderr || 'missing fixture result')
    const report = JSON.parse(output[1].replace(/&quot;/g,'"').replace(/&amp;/g,'&').replace(/&lt;/g,'<').replace(/&gt;/g,'>'))
    console.log(JSON.stringify(report))
    if (!report.ok) process.exitCode = 1
  }
} finally {
  rmSync(scratch,{recursive:true,force:true})
}
