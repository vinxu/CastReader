import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import {execFileSync} from 'node:child_process';
const root = path.resolve(import.meta.dirname, '..');
const swift = fs.readFileSync(path.join(root, 'CastReader/Services/KindleNativePageScript.swift'), 'utf8');
const script = swift.split('static let bootstrap = #"""')[1].split('"""#')[0];
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'kindle-native-contract-'));
let capture;
try {
  // Compile the actual Swift interpolation and escaping, not a JS facsimile.
  fs.writeFileSync(path.join(temp, 'main.swift'), `import Foundation
  struct KindleStorefront {
    var libraryURL: URL { URL(string: "https://read.amazon.com/kindle-library")! }
    let id = "us", canonicalHost = "read.amazon.com", entryEnabled = true
    static let javaScriptHostArray = "[\\"read.amazon.com\\"]"
    static let javaScriptCanonicalHostMap = "{}"
    static let readerReferenceValue = "fixture"
    static let selectable = [KindleStorefront()]
    static func entry(id: String) -> KindleStorefront? { selectable.first }
  }
  print(KindleWebScripts.pageCaptureBootstrap)`);
  execFileSync('swiftc', ['CastReader/Services/KindleNativePageScript.swift',
    'CastReader/Services/KindleWebScripts.swift', path.join(temp, 'main.swift'), '-o', path.join(temp, 'emit')], {cwd:root});
  capture = execFileSync(path.join(temp, 'emit'), {encoding:'utf8', maxBuffer:4*1024*1024});
  new vm.Script(capture);
} finally { fs.rmSync(temp, {recursive:true, force:true}); }
const flush = async () => { await Promise.resolve(); await Promise.resolve(); };
const deferred = () => { let resolve, reject; const promise = new Promise((a,b)=>{resolve=a;reject=b;}); return {promise,resolve,reject}; };
const rect = {left:0,top:0,width:390,height:700,right:390,bottom:700};
function page(name, connected=false, canvas=false) {
  const s = {tagName:canvas?'CANVAS':'IMG', isConnected:connected, complete:true,
    naturalWidth:780,naturalHeight:1400,width:780,height:1400, src:'blob:revoked-'+name,
    getBoundingClientRect(){return this.isConnected?rect:{...rect,width:0,height:0};}};
  const element = {isConnected:connected, querySelector(){return s;}};
  return {page:{startPositionId:0,endPositionId:1,pageIndex:0},renderResult:{pageElement:element},surface:s};
}
function attach(p, yes) { p.renderResult.pageElement.isConnected=yes;p.surface.isConnected=yes; }
function fixture() {
  const moves=[], rasters=[];
  const navigation = {currentIndex:10,currentView:{}, options:{rendererController:{cache:new Map(), renderingProcessId:'scope-1'}},
    move(direction){moves.push(direction);}};
  const activeRoot={stateNode:{}};activeRoot.stateNode.current=activeRoot;
  const fiber={return:activeRoot,memoizedState:{memoizedState:{current:{client:{navigationService:navigation}}}}};
  const node={'__reactFiber$fixture':fiber};
  const sandbox={window:null,Map,Set,Promise,Date,Math,Event:class{},location:{href:'https://read.amazon.com/?asin=TEST'},
    __crKindleNativeOrderEnabled:true,__crKindleNativeBook:'TEST',
    document:{querySelectorAll(){return [node];},dispatchEvent(){},createElement(tag){
      assert.equal(tag,'canvas'); const raster={getContext(){return {drawImage(source){raster.source=source;}};}};rasters.push(raster);return raster;
    }}};
  sandbox.window=sandbox;vm.runInNewContext(script,sandbox);
  const api=sandbox.__crKindleNativePages;
  const set=(index,p)=>{navigation.options.rendererController.cache.set(index,Promise.resolve(p));return p;};
  const show=(index,p)=>{navigation.currentIndex=index;navigation.currentView.renderedPage=p;attach(p,true);api.refresh(true);};
  return {navigation,api,set,show,node,sandbox,moves,rasters};
}
const f=fixture(), {api,navigation:n}=f;
const old=f.set(9,page('previous')), current=f.set(10,page('current',true)), two=f.set(12,page('two'));
const late=deferred();n.options.rendererController.cache.set(11,late.promise);
f.show(10,current);await flush();
const first=api.state().currentId;
assert.ok(first.startsWith('native:'));
assert.equal(api.adjacent(first,1,()=>rect),null,'missing +1 must never become +2');
assert.equal(api.adjacent(first,-1,()=>rect).key,api.id(9));
late.resolve(page('one'));await flush();
const next=api.adjacent(first,1,()=>rect);assert.equal(next.nativeIndex,11);
assert.equal(next.img.src,'blob:revoked-one','capture uses decoded native surface without fetch');
assert.equal(api.state().currentId,first,'preparing another page cannot mutate visible ownership');
assert.equal(f.moves.length,0,'cache inspection has no navigation side effects');
const target=api.id(11), before=n.currentIndex;
const dispatch=api.dispatch('next',first,'intent-1');assert.equal(dispatch.expectedTargetKey,target);
api.dispatch('next',first,'intent-1');assert.equal(f.moves.length,1,'same intent dispatches once');
assert.equal(api.confirmed(first,1),'','move resolution alone does not confirm');
n.currentIndex=11;assert.equal(api.confirmed(first,1),'','index advance alone does not confirm');
const p1=n.options.rendererController.cache.get(11);const resolved=await p1;
n.currentView.renderedPage=resolved;assert.equal(api.confirmed(first,1),'','detached page cannot confirm');
attach(resolved,true);assert.equal(api.confirmed(first,1),target);
assert.equal(api.dispatch('previous',first,'wrong-origin').dispatchCount,0);
assert.equal(api.dispatch('previous',target,'intent-2').targetIndex,before);
f.show(10,current);assert.equal(api.confirmed(target,-1),first,'previous is the exact -1 slot');
// An identical image/same renderer-local pageIndex never conflates two pages.
const same=f.set(11,page('current'));api.refresh(true);await flush();
assert.notEqual(api.id(11),first);assert.equal(api.adjacent(first,1,()=>rect).img.src,current.surface.src);
const stale=deferred();n.options.rendererController.cache.set(11,stale.promise);api.refresh(true);
const replacement=f.set(11,page('replacement'));api.refresh(true);await flush();const replacementID=api.id(11);
stale.resolve(page('stale'));await flush();assert.equal(api.id(11),replacementID);
assert.equal(api.adjacent(first,1,()=>rect).img,replacement.surface);
n.options.rendererController.cache.delete(11);
assert.equal(api.valid(replacementID,false),false,'evicted slot invalid even before poll');
const oldEpoch=api.state().epoch;const pending=deferred();n.options.rendererController.cache.set(11,pending.promise);api.refresh(true);
n.options.rendererController.renderingProcessId='reflow';api.refresh(true);pending.resolve(page('old-layout'));await flush();
assert.ok(api.state().epoch>oldEpoch);assert.equal(api.valid(first,false),false);
// Real reflow replaces its cache; old pending completion cannot fill new slot.
n.options.rendererController.cache=new Map([[10,Promise.resolve(current)]]);api.refresh(true);await flush();
assert.equal(api.adjacent(api.state().currentId,1,()=>rect),null);
const raster=f.set(11,page('canvas',false,true));api.refresh(true);await flush();
const canvas=api.adjacent(api.state().currentId,1,()=>rect);
assert.equal(canvas.img.complete,true);assert.equal(canvas.img.source,raster.surface);assert.equal(f.rasters.length,1);
api.adjacent(api.state().currentId,1,()=>rect);assert.equal(f.rasters.length,1,'bounded raster reused for same slot');
// Ignore stale React alternate whose controller looks structurally valid.
const active=f.node.__reactFiber$fixture, staleRoot={stateNode:active.return.stateNode};
f.node.__reactFiber$fixture={return:staleRoot,alternate:active,memoizedState:{memoizedState:{current:{client:{navigationService:{...n,currentIndex:999}}}}}};
api.refresh(true);assert.equal(api.state().index,10);
// A new controller with the same renderer/process still creates a new epoch.
const epoch=api.state().epoch;active.memoizedState.memoizedState.current.client.navigationService={...n};api.refresh(true);await flush();
assert.ok(api.state().epoch>epoch);
// A full book change invalidates all previously issued page identities.
const key=api.state().currentId;f.sandbox.__crKindleNativeBook='OTHER';api.refresh(true);await flush();assert.equal(api.valid(key,false),false);
const broken=deferred();n.options.rendererController.cache.set(11,broken.promise);api.refresh(true);broken.reject(Error('fixture'));await flush();
for(let i=0;i<100;i++)api.refresh();assert.equal(api.adjacent(api.state().currentId,1,()=>rect),null);

// Randomized slot replacements and arbitrarily reordered Promise resolution.
let seed=83719, checks=0;
const random=()=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed;};
const r=fixture(), pendingSlots=[];r.show(10,r.set(10,page('anchor',true)));await flush();
for(let i=0;i<5000;i++) {
  const index=9+random()%4, d=deferred(), p=page('random-'+i,index===10);
  r.navigation.options.rendererController.cache.set(index,d.promise);r.api.refresh(true);
  pendingSlots.push({index,d,p});
  if(random()%4===0)r.navigation.options.rendererController.cache.delete(9+random()%4);
  if(random()%31===0){r.navigation.options.rendererController.renderingProcessId='scope-'+i;r.api.refresh(true);}
  for(let j=0;j<2&&pendingSlots.length;j++) {
    const k=random()%pendingSlots.length, item=pendingSlots.splice(k,1)[0];item.d.resolve(item.p);
  }
  await flush();r.api.refresh(true);await flush();
  for(let index=9;index<=12;index++) {
    const c=r.api.candidate(index,()=>rect);if(!c)continue;
    assert.equal(c.img,(await r.navigation.options.rendererController.cache.get(index)).surface);checks++;
    assert.equal(r.api.indexFor(c.key),index);checks++;
  }
}
assert.ok(checks>10000);

// Run real integration functions against the adapter: never use held Blob order.
const c=fixture();const cp=c.set(10,page('visible',true)), np=c.set(11,page('ahead'));c.show(10,cp);await flush();
const sb=c.sandbox;
Object.assign(sb,{innerWidth:390,innerHeight:700,imageElementContentRect:s=>s.getBoundingClientRect(),
  visibleArea:()=>273000,readingBandArea:()=>273000,
  __crKindleProbe:{liveSessionId:1,liveKey:'',keyToLiveUrl:new Map()},
  crKindleImagePixelFingerprint:()=> 'identical-pixels', draw:(img,key)=>({ok:true,key,image:img.src || 'canvas'}),
  crKindleHeldCandidateForStableKey(){throw Error('Native path must not inspect held Blob order');}});
function section(start,end){return capture.slice(capture.indexOf(start),capture.indexOf(end,capture.indexOf(start)));}
vm.runInNewContext(section('function crKindleNative()','function candidateOrderY('),sb);
vm.runInNewContext(section('function currentReadingCandidate(','function refreshCandidate('),sb);
vm.runInNewContext(section('function refreshCandidate(','function lockLiveCandidate('),sb);
const nextStart=capture.indexOf('function nextCandidateAfterKey(');
const nextEnd=capture.indexOf('\n  function ',nextStart+10);
// Swift strips indentation to two spaces inside the emitted IIFE.
assert.ok(nextEnd>nextStart);vm.runInNewContext(capture.slice(nextStart,nextEnd),sb);
vm.runInNewContext(section('window.__crKindleNextPageSnapshot =','window.__crKindlePrefetchSnapshotForKey ='),sb);
vm.runInNewContext(section('window.__crKindlePrefetchSnapshotForKey =','window.__crKindleCandidateSnapshotsAfterKey ='),sb);
const manyStart=capture.indexOf('window.__crKindleCandidateSnapshotsAfterKey =');
const manyEnd=capture.indexOf('\n  window.__crKindle',manyStart+10);
assert.ok(manyEnd>manyStart);vm.runInNewContext(capture.slice(manyStart,manyEnd),sb);
const visible=sb.currentReadingCandidate();assert.equal(visible.key,c.api.state().currentId);
assert.equal(sb.refreshCandidate(visible).key,visible.key);
const adjacent=JSON.parse(sb.__crKindleNextPageSnapshot(visible.key,2048,1));assert.equal(adjacent.key,c.api.id(11));
const speculative=JSON.parse(sb.__crKindleCandidateSnapshotsAfterKey(visible.key,12,2048,1,true));
assert.equal(speculative.pages.length,1);assert.equal(speculative.pages[0].key,c.api.id(11));
assert.equal(c.api.state().currentId,visible.key);assert.equal(c.moves.length,0);
c.navigation.options.rendererController.cache.delete(11);c.set(12,page('skip'));c.api.refresh(true);await flush();
assert.equal(JSON.parse(sb.__crKindleNextPageSnapshot(visible.key,2048,1)).ok,false);
assert.equal(JSON.parse(sb.__crKindlePrefetchSnapshotForKey(adjacent.key,2048,1)).ok,false);
assert.equal(JSON.parse(sb.__crKindleCandidateSnapshotsAfterKey(visible.key,12,2048,1,true)).pages.length,0);
console.log(JSON.stringify({passed:true, randomizedMutations:5000, ownershipChecks:checks,
  coverage:['exact-adjacency','late-promise','slot-replacement','eviction','reflow','book/controller/document-scope',
    'mounted-object-confirmation','same-pixels','revoked-image','detached-canvas','active-react-branch',
    'intent-deduplication','rejected-promise','capture/prefetch-integration','compiled-JavaScript-syntax']}));
