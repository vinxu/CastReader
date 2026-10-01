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
import { installPlayBooksNativePreparation } from './src/play-books-native-preparation';
import { readPlayBooksSnapshot } from './src/play-books-native-pages';
import { extractPlayBooksParagraphs, extractPlayBooksNextPagePreview, installPlayBooksReader } from './src/play-books';
import { extractKoboNextSpeechPreview, extractKoboNextPagePreview } from './src/kobo';
window.fixture = { installPlayBooksNativePreparation, installPlayBooksNativeLayoutBridge, readPlayBooksSnapshot, extractPlayBooksParagraphs, extractPlayBooksNextPagePreview, installPlayBooksReader, extractKoboNextSpeechPreview, extractKoboNextPagePreview };
` }, bundle: true, write: false, format: 'iife', platform: 'browser', target: 'es2022',
  define: { __CASTREADER_XCTEST_FIXTURES__: 'false' } })
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
  // A later unresolved native cut cannot revoke an earlier verified next page.
  document.querySelector('reader-page.shown p').textContent='A.';
  document.querySelector('reader-page.shown p').removeAttribute('ocean-sliced-element');
  group.pages=[
    {blocks:[{raw:'A.',stream:'1',boundaries:[],reopened:false,closed:true}],closed:true},
    {blocks:[{raw:'B.',stream:'2',boundaries:[],reopened:false,closed:true}],closed:true},
    {blocks:[{raw:'C prefix',stream:'3',boundaries:[],reopened:false,closed:false}],closed:false},
    {blocks:[{raw:'prefix expanded.',stream:'3',boundaries:[],reopened:true,closed:true}],closed:true}];
  snapshot=measure();
  check(snapshot.pages.length===2&&snapshot.pages[1].blocks[0].text==='B.','verified immediate successor survives an unresolved later cut');
  check(!snapshot.pages[1].lastInSegment,'truncated measurement prefix cannot pretend to end the chapter');
  document.querySelector('reader-page.shown').id='page-0-1';
  document.querySelector('.gb-segment').innerHTML='<a id="GBS.PT1"></a><p ocean-reopened-element>old expanded.</p><p>Current exact source.</p>';
  group.pages=[
    {blocks:[{raw:'An unresolved old',stream:'1',boundaries:[],reopened:false,closed:false}],closed:false},
    {blocks:[{raw:'old expanded.',stream:'1',boundaries:[],reopened:true,closed:true},{raw:'Current exact source.',stream:'2',boundaries:[],reopened:false,closed:true}],closed:true},
    {blocks:[{raw:'The confirmed immediate successor.',stream:'3',boundaries:[],reopened:false,closed:true}],closed:true}];
  snapshot=measure();
  check(snapshot.pages.map(p=>p.id).join(',')==='page-0-1,page-0-2','exact current native source reanchors after an unresolved earlier cut');
  check(f.extractPlayBooksNextPagePreview()?.paragraphs[0].text==='The confirmed immediate successor.','reanchored preview retains immediate native ordering');
  document.querySelector('.gb-segment p').textContent='Different current source.';
  snapshot=measure();
  check(snapshot.pages.length===1,'a mismatching current source cannot reanchor a measurement');
  document.documentElement.removeAttribute('data-castreader-pb-layouts');
  const page=(index,text,sliced=false)=>'<reader-page id="page-0-'+index+'" class="'+(index===0?'shown ':'')+'-gb-loaded"><reader-rendered-page class="-gb-text layout" style="width:350px;height:560px"><div class="gb-segment"><p'+(sliced?' ocean-sliced-element':'')+'>'+text+'</p></div></reader-rendered-page></reader-page>';
  document.querySelector('#reader').innerHTML='<reader-horizontal-view><ol><li class="onepage">'+page(0,'Current page.')+page(1,'Verified next page.')+page(2,'Unfinished later paragraph',true)+page(3,'Unconfirmed later continuation.')+'</li></ol></reader-horizontal-view><button><mat-icon>chevron_right</mat-icon></button>';
  check(f.extractPlayBooksParagraphs().map(p=>p.text).join('|')==='Current page.','unrelated future continuation cannot revoke the visible page');
  check(f.extractPlayBooksNextPagePreview()?.paragraphs.map(p=>p.text).join('|')==='Verified next page.','unrelated future continuation cannot revoke the verified successor');
  document.querySelector('reader-page.shown').classList.remove('shown');
  document.querySelector('#page-0-2').classList.add('shown');
  let rejected=false;try{f.extractPlayBooksNextPagePreview()}catch(error){rejected=error.message==='play_books_unconfirmed_paragraph_continuation'}
  check(rejected,'the requested successor still requires exact continuation evidence');
  document.querySelector('#reader').innerHTML='<reader-horizontal-view><ol><li class="onepage">'+page(0,'Current page.')+'</li></ol></reader-horizontal-view><button><mat-icon>chevron_right</mat-icon></button>';
  const preparedSource=(segment,index,text)=>({id:'page-'+segment+'-'+index,segment,index,volume:'fixture-book',
    engine:'fixture-book:'+segment+':350x560',key:'fixture-book:'+segment+':350x560:'+index,width:350,height:560,
    html:'<div class="gb-segment"><p>'+text+'</p></div>'});
  const prepared={version:1,viewport:[innerWidth,innerHeight],current:[preparedSource(0,0,'Current page.')],next:[preparedSource(1,0,'Next chapter exact first page.')]};
  const publishPrepared=()=>document.documentElement.setAttribute('data-castreader-pb-prepared',JSON.stringify(prepared));
  publishPrepared();
  check(f.extractPlayBooksNextPagePreview()?.paragraphs[0].text==='Next chapter exact first page.','native next-chapter descriptor supplies only its exact first page');
  prepared.current[0].html='<div class="gb-segment"><p>Stale source.</p></div>';publishPrepared();
  check(!f.extractPlayBooksNextPagePreview(),'prepared native source rejected after current text changes');
  prepared.current[0]=preparedSource(0,0,'Current page.');prepared.viewport[0]++;publishPrepared();
  check(!f.extractPlayBooksNextPagePreview(),'prepared native source rejected after viewport changes');
  prepared.viewport=[innerWidth,innerHeight];prepared.next[0]=preparedSource(2,0,'Skipped chapter.');publishPrepared();
  check(!f.extractPlayBooksNextPagePreview(),'native preparation cannot skip a chapter');
  prepared.next[0]=preparedSource(1,0,'Next chapter exact first page.');prepared.next[0].volume='different-book';publishPrepared();
  check(!f.extractPlayBooksNextPagePreview(),'native preparation cannot cross book identity');
  document.documentElement.removeAttribute('data-castreader-pb-prepared');
  const oldMapSet=Map.prototype.set;
  f.installPlayBooksNativePreparation();
  const nativeDescriptor=(segment,index,text)=>({volumeId:'fixture-book',Uc:segment,Sb:index,
    aA:'fixture-book:'+segment+':350x560',key:'fixture-book:'+segment+':350x560:'+index,
    width:350,height:560,rd:{width:350,height:560},Dw:true,mF:preparedSource(segment,index,text).html});
  const currentNative=nativeDescriptor(0,0,'Current page.'), nextNative=nativeDescriptor(1,0,'Next chapter exact first page.');
  let prepareCalls=0;
  const engine={getKey:()=>currentNative.aA,segment:{hf:0},parent:{gA:()=>{prepareCalls++;return nextNative}},
    async ha(a){const following=a.Sb+1;return a.Dw?this.parent.gA(a):null;}};
  const host=document.querySelector('reader-horizontal-view');
  const component={nb:{Aa:host},O:new Map([['current',{Wb:currentNative}]]),Fa:{O:{U:new Map([[currentNative.aA,engine]])}}};
  new Map().set(1,[host,component]);
  for(let i=0;i<50&&!document.documentElement.hasAttribute('data-castreader-pb-prepared');i++)await new Promise(r=>setTimeout(r,20));
  check(prepareCalls===1&&f.extractPlayBooksNextPagePreview()?.paragraphs[0].text==='Next chapter exact first page.','bounded native preparation produces one exact successor');
  check(document.querySelector('reader-page.shown').id==='page-0-0','native preparation preserves visible page');
  check(Map.prototype.set===oldMapSet,'native registration observation restores Map immediately');
  host.style.color='rgb(30,30,30)';await new Promise(r=>setTimeout(r,80));
  check(prepareCalls===1,'mark-only DOM changes do not repeat native preparation');
  let resolveLate;
  engine.parent.gA=()=>{prepareCalls++;return new Promise(resolve=>{resolveLate=resolve})};
  const shown=document.querySelector('reader-page.shown');
  const nativeAway=nativeDescriptor(0,1,'Away page.');
  component.O.set('current',{Wb:nativeAway});shown.id='page-0-1';shown.querySelector('p').textContent='Away page.';
  await new Promise(r=>setTimeout(r,80));
  check(typeof resolveLate==='function','changed native page begins its own preparation');
  component.O.set('current',{Wb:currentNative});shown.id='page-0-0';shown.querySelector('p').textContent='Current page.';
  await new Promise(r=>setTimeout(r,80));
  engine.parent.gA=()=>{prepareCalls++;return nextNative};resolveLate(nativeDescriptor(0,2,'Stale late page.'));
  await new Promise(r=>setTimeout(r,100));
  check(f.extractPlayBooksNextPagePreview()?.paragraphs[0].text==='Next chapter exact first page.','late result cannot overwrite a revisited page preparation');
  check(!JSON.parse(document.documentElement.getAttribute('data-castreader-pb-prepared')).next.some(p=>p.html.includes('Stale late')),'stale native result never published');

  const tailNative=nativeDescriptor(0,4,'it.'), bodyNative=nativeDescriptor(0,5,'The following chapter contains enough source for a complete explanation and narration.');
  engine.parent.gA=a=>{prepareCalls++;return a.Sb===3?tailNative:bodyNative};
  component.O.set('current',{Wb:nativeDescriptor(0,3,'Before tiny tail.')});
  shown.id='page-0-3';shown.querySelector('p').textContent='Before tiny tail.';
  await new Promise(r=>setTimeout(r,120));
  const tinyPreview=f.extractPlayBooksNextPagePreview();
  check(tinyPreview?.paragraphs[0].text==='it.','tiny tail remains the immediate visual successor');
  check(tinyPreview?.following?.paragraphs[0].text.startsWith('The following chapter'),'tiny tail prepares one subsequent explanation spread');
  check(JSON.parse(document.documentElement.getAttribute('data-castreader-pb-prepared')).next.length===2,'tiny tail preparation stays bounded to two spreads');
  check(shown.id==='page-0-3','preparing beyond a tiny tail never navigates the visible page');

  window.dispatchEvent(new Event('pagehide'));
  check(['contentDocument','contentWindow'].every((k,i)=>Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype,k).get===originals[i]),'native getters restored after exit');
  const saved=document.documentElement.getAttribute('data-castreader-pb-layouts');doc.body.append(growing);growing.firstChild.firstChild.data='After cleanup.';await tick();
  check(saved===document.documentElement.getAttribute('data-castreader-pb-layouts'),'observers stop publishing after exit');
  document.querySelector('#reader').innerHTML='<reader-horizontal-view><ol><li class="onepage">'+page(0,'Hello ',true)+page(1,'world.')+'</li></ol></reader-horizontal-view><button><mat-icon>chevron_right</mat-icon></button>';
  window.CR={};const posts=[];f.installPlayBooksReader((type,payload)=>posts.push({type,payload}),()=>{},'browser-regression');
  await new Promise(resolve=>setTimeout(resolve,850));
  check(!posts.some(p=>p.type==='googleBooksPagePreview'),'unconfirmed successor is never published');
  document.querySelector('#page-0-1 p').setAttribute('ocean-reopened-element','');
  await new Promise(resolve=>setTimeout(resolve,1800));
  check(posts.some(p=>p.type==='googleBooksPagePreview'&&p.payload.paragraphs[0].text==='world.'),'preview observation recovers after a delayed native continuation marker');
  check(document.querySelector('reader-page.shown').id==='page-0-0','recovering preview never physically turns the visible page');
  document.querySelector('#reader').innerHTML='<reader-horizontal-view><ol><li class="onepage">'+page(0,'Before tiny tail.')+page(1,'it.')+'</li></ol></reader-horizontal-view><button><mat-icon>chevron_right</mat-icon></button>';
  await new Promise(resolve=>setTimeout(resolve,1600));
  const beforePrepared=posts.filter(p=>p.type==='googleBooksPagePreview');
  check(beforePrepared.at(-1)?.payload.paragraphs[0].text==='it.'&&!beforePrepared.at(-1)?.payload.following,'first tiny-tail preview publishes before native lookahead finishes');
  prepared.current=[preparedSource(0,0,'Before tiny tail.')];
  prepared.next=[preparedSource(0,1,'it.'),preparedSource(0,2,'The late following chapter has enough source for a complete explanation.')];
  publishPrepared();document.dispatchEvent(new Event('castreader-play-books-layout'));
  await new Promise(resolve=>setTimeout(resolve,250));
  check(posts.filter(p=>p.type==='googleBooksPagePreview').length===beforePrepared.length+1&&posts.filter(p=>p.type==='googleBooksPagePreview').at(-1)?.payload.following?.paragraphs[0].text.startsWith('The late following chapter'),'late native preparation republishes following source after a successful initial preview');
  document.dispatchEvent(new Event('castreader-play-books-layout'));
  await new Promise(resolve=>setTimeout(resolve,250));
  check(posts.filter(p=>p.type==='googleBooksPagePreview').length===beforePrepared.length+1,'repeated native preparation events do not duplicate preview');
  check(document.querySelector('reader-page.shown').id==='page-0-0','late lookahead publication preserves visible page');
  document.documentElement.removeAttribute('data-castreader-pb-prepared');
  document.querySelector('#reader').innerHTML='<div id="BookView" style="position:absolute;left:20px;top:20px;width:240px;height:280px;overflow:hidden"><div class="ReadingOrderView"><div class="ReadingItem"><iframe data-chapterurl="chapter-1.xhtml" style="width:720px;height:280px;border:0"></iframe></div></div></div>';
  const koboFrame=document.querySelector('#BookView iframe');
  await new Promise(resolve=>{koboFrame.onload=resolve;koboFrame.srcdoc='<style>html,body{margin:0;height:280px;column-width:240px;column-gap:0;column-fill:auto}p{margin:0;height:280px;font:24px/32px Georgia}</style><p>Current source sentence.</p><p>Next exact source sentence.</p><p>Later source sentence.</p>'});
  const speech=f.extractKoboNextSpeechPreview();
  check(speech?.text==='Next exact source sentence.','Kobo preview is exactly the immediate offscreen source sentence');
  check(/^[0-9a-f]{8}$/.test(speech.contentFingerprint),'Kobo speech fingerprint satisfies the shared native preparation contract');
  koboFrame.contentDocument.body.innerHTML='<p>Current chapter ends here.</p>';
  const nextChapter=document.createElement('iframe');
  nextChapter.setAttribute('data-chapterurl','chapter-2.xhtml');
  nextChapter.style.cssText='position:absolute;left:5000px;width:720px;height:280px;border:0';
  const item=document.createElement('div');item.className='ReadingItem';item.append(nextChapter);document.querySelector('.ReadingOrderView').append(item);
  await new Promise(resolve=>{nextChapter.onload=resolve;nextChapter.srcdoc='<style>html,body{margin:0;height:280px;column-width:240px;column-gap:0;column-fill:auto}p{margin:0;height:280px;font:24px/32px Georgia}</style><p>Verified next chapter opening.</p><p>This belongs to its second page.</p>'});
  const chapterPreview=f.extractKoboNextPagePreview();
  check(chapterPreview?.paragraphs.map(p=>p.text).join('|')==='Verified next chapter opening.','laid-out immediate next chapter previews its first page only');
  check(nextChapter.style.left==='5000px'&&koboFrame.contentDocument.body.textContent==='Current chapter ends here.','chapter preview never moves the provider or changes the visible source');
  nextChapter.contentDocument.body.style.columnWidth='200px';
  check(!f.extractKoboNextPagePreview(),'a different next-chapter layout cannot borrow the current page geometry');
  document.querySelector('#result').textContent=JSON.stringify({passed:true,checks:results.length,results},null,2);
})().catch(error=>{document.querySelector('#result').textContent=JSON.stringify({passed:false,error:String(error),stack:error.stack},null,2)});
</script>`)
console.log(output)
