// Build a local browser regression page from the production iOS adapters.
// Serve the output directory and inspect its visible result. This is a DOM
// contract test, not an iPhone / audio / logged-in-provider acceptance result.
import { build } from 'esbuild'
import { mkdirSync, writeFileSync } from 'node:fs'
import { resolve, join } from 'node:path'

const output = resolve(process.argv[2] || '/tmp/castreader-pagination-fixture')
mkdirSync(output, { recursive: true })
const result = await build({ stdin: { resolveDir: process.cwd(), loader: 'ts', contents: `
import { installPlayBooksNativeLayoutBridge } from './src/play-books-native-entry';
import { readPlayBooksSnapshot } from './src/play-books-native-pages';
window.fixture = { installPlayBooksNativeLayoutBridge, readPlayBooksSnapshot };
` }, bundle: true, write: false, format: 'iife', platform: 'browser', target: 'es2022' })
writeFileSync(join(output, 'fixture.js'), result.outputFiles[0].contents)
writeFileSync(join(output, 'index.html'), `<!doctype html><meta charset="utf-8">
<title>iOS pagination adapter regression</title>
<style>reader-horizontal-view,reader-rendered-page{display:block}reader-page{display:none;width:350px;height:560px}reader-page.shown{display:block}ol{padding:0}li{list-style:none}p{font:20px/28px sans-serif}</style>
<pre id="result">RUNNING</pre><main id="reader"></main><script src="fixture.js"></script>
<script>
(async()=>{
  const results=[];
  const check=(condition,name)=>{if(!condition)throw new Error(name);results.push(name)};
  const tick=()=>new Promise(resolve=>setTimeout(resolve,0));
  const f=window.fixture;
  const originals=['contentDocument','contentWindow'].map(k=>Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype,k).get);
  f.installPlayBooksNativeLayoutBridge();f.installPlayBooksNativeLayoutBridge();
  const frame=document.createElement('iframe');frame.style.cssText='position:absolute;left:-9999px;width:350px;height:560px;border:0';document.body.append(frame);
  const doc=frame.contentDocument;check(doc===frame.contentWindow.document,'native iframe getter identity preserved');
  doc.body.className='layout';
  const growing=doc.createElement('div');growing.className='gb-segment';growing.setAttribute('ocean_stream_index','0');
  growing.innerHTML='<p ocean_stream_index="1">Initially partial</p>';doc.body.append(growing);await tick();
  growing.firstChild.firstChild.data+=' source.';
  growing.firstChild.setAttribute('ocean_stream_close','3');growing.setAttribute('ocean_stream_close','4');
  const anchor=doc.createElement('a');anchor.id='GBS.PT1';anchor.setAttribute('ocean_stream_index','2');growing.firstChild.append(anchor);await tick();
  const capture=()=>JSON.parse(document.documentElement.getAttribute('data-castreader-pb-layouts'));
  let groups=capture(), block=groups[0].pages[0].blocks[0];
  check(groups.length===1&&groups[0].pages.length===1,'in-place mutation keeps one native page identity');
  check(block.raw==='Initially partial source.','later character data retained');
  check(groups[0].pages[0].closed&&block.closed,'late stream closure retained');
  check(groups[0].anchors.includes('GBS.PT1'),'late chapter anchor retained');
  check(block.boundaries[0].offset===block.raw.length&&block.boundaries[0].stream==='2','native inline source offset retained');
  growing.remove();await tick();doc.body.append(growing);growing.remove();await tick();
  check(capture()[0].pages.length===1,'recycled measuring node is not duplicated');
  document.querySelector('#reader').innerHTML='<reader-horizontal-view><ol><li class="onepage"><reader-page id="page-0-0" class="shown -gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><a id="GBS.PT1"></a><p ocean_stream_index="1" ocean-sliced-element>Hello </p></div></reader-rendered-page></reader-page></li></ol></reader-horizontal-view><button><mat-icon>chevron_right</mat-icon></button>';
  const group={id:1,className:'layout',width:350,height:560,anchors:['GBS.PT1'],pages:[
    {blocks:[{raw:'Hello world.',stream:'1',boundaries:[{stream:'2',offset:6}],reopened:false,closed:false}],closed:false},
    {blocks:[{raw:'world. Next.',stream:'1',boundaries:[{stream:'2',offset:0}],reopened:true,closed:true}],closed:true}]};
  const measure=()=>{document.documentElement.setAttribute('data-castreader-pb-layouts',JSON.stringify([group]));return f.readPlayBooksSnapshot()};
  let snapshot=measure();
  check(snapshot?.ready&&snapshot.pages.length===2,'extended next measurement accepted with exact native source offset');
  check(snapshot.pages[0].blocks[0].text==='Hello'&&snapshot.pages[1].blocks[0].text==='world. Next.','trimmed source coverage preserves page order');
  check(snapshot.pages[1].lastInSegment,'confirmed closed tail retained before it is visible');
  group.pages.forEach(p=>p.blocks[0].boundaries=[]);snapshot=measure();
  check(snapshot.pages.length===2,'matching layout plus chapter anchor allows native visible slice witness');
  group.anchors=[];snapshot=measure();
  check(snapshot.pages.length===1,'matching prose without source anchor cannot guess unseen page');
  group.anchors=['GBS.PT1'];group.pages[0].blocks[0].boundaries=[{stream:'2',offset:6}];group.pages[1].blocks[0].boundaries=[{stream:'2',offset:1}];snapshot=measure();
  check(snapshot.pages.length===1,'conflicting native displacement rejected despite visible text match');
  group.pages[1].blocks[0].boundaries=[{stream:'2',offset:0}];group.pages[1].blocks[0].raw='wrong. Next.';snapshot=measure();
  check(snapshot.pages.length===1,'changed overlapping source rejected');
  window.dispatchEvent(new Event('pagehide'));
  check(['contentDocument','contentWindow'].every((k,i)=>Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype,k).get===originals[i]),'native getters restored after exit');
  const saved=document.documentElement.getAttribute('data-castreader-pb-layouts');doc.body.append(growing);growing.firstChild.firstChild.data='After cleanup.';await tick();
  check(saved===document.documentElement.getAttribute('data-castreader-pb-layouts'),'observers stop publishing after exit');
  document.querySelector('#result').textContent=JSON.stringify({passed:true,checks:results.length,results},null,2);
})().catch(error=>{document.querySelector('#result').textContent=JSON.stringify({passed:false,error:String(error),stack:error.stack},null,2)});
</script>`)
console.log(output)
