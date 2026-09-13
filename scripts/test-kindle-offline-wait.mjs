import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const swift=fs.readFileSync(new URL('../CastReader/Services/KindleOfflineSourceScript.swift',import.meta.url),'utf8');
const script=swift.split('static let bootstrap = #"""')[1].split('"""#')[0];
function fixture() {
  let now=0,seq=0,identity='new-image';
  const timers=new Map(),observers=new Set(),loads=new Set();
  let source={asin:'fixture',revision:'1',layout:{width:432},metadata:{minimum:0,maximum:100,cover:0},
    start:3,end:19,current:3,page:{start:3,end:19},loading:false};
  const sandbox={window:null,performance:{now:()=>now},fetch(){throw Error('No network needed');},
    document:{documentElement:{},addEventListener:(_,fn)=>loads.add(fn),removeEventListener:(_,fn)=>loads.delete(fn)},
    setTimeout(fn,delay){const id=++seq;timers.set(id,{at:now+delay,fn});return id;},
    clearTimeout(id){timers.delete(id);},
    MutationObserver:class {constructor(fn){this.fn=fn;} observe(){observers.add(this);} disconnect(){observers.delete(this);}}
  };
  sandbox.window=sandbox;vm.runInNewContext(script,sandbox);
  sandbox.__crOfflineSourceRead=()=>JSON.stringify(source);
  sandbox.__crKindleOfflineImageIdentity=()=>identity;
  let recoveries=0;sandbox.__crOfflineSourceRecover=()=>{recoveries++;return false;};
  const tick=ms=>{
    const target=now+ms;let count=0;
    while(true){const next=[...timers].sort((a,b)=>a[1].at-b[1].at)[0];if(!next||next[1].at>target)break;
      assert.ok(++count<10000);now=next[1].at;timers.delete(next[0]);next[1].fn();}
    now=target;
  };
  return {sandbox,tick,source,observers,loads,timers,setIdentity:value=>{identity=value;},
    mutate(){for(const o of observers)o.fn();tick(0);},get recoveries(){return recoveries;}};
}
{
  const f=fixture();const p=f.sandbox.__crOfflineWaitForImage(4,'old-image','ready');
  f.tick(49);assert.equal(f.observers.size,1);f.tick(1);
  const result=JSON.parse(await p);assert.equal(result.status,'ready');assert.equal(result.source.start,3);
  assert.equal(result.source.imageIdentity,'new-image');assert.equal(f.observers.size,0);assert.equal(f.loads.size,0);assert.equal(f.timers.size,0);
}
{
  const f=fixture();f.setIdentity('old-image');const p=f.sandbox.__crOfflineWaitForImage(4,'old-image','stale-pixels');
  f.tick(100);assert.equal(f.observers.size,1,'Position change alone cannot confirm old pixels');
  f.setIdentity('new-image');f.mutate();f.tick(49);assert.equal(f.observers.size,1);f.tick(1);
  assert.equal(JSON.parse(await p).status,'ready');
}
{
  const f=fixture();const p=f.sandbox.__crOfflineWaitForImage(4,'old-image','reorder');
  f.tick(25);f.source.start=20;f.source.end=39;f.source.current=20;f.source.page={start:20,end:39};f.mutate();
  f.tick(100);assert.equal(f.observers.size,1,'A future page is not the requested page');
  f.source.start=3;f.source.end=19;f.source.current=3;f.source.page={start:3,end:19};f.mutate();
  f.tick(49);assert.equal(f.observers.size,1,'Returning to target requires fresh confirmation');f.tick(1);
  assert.equal(JSON.parse(await p).status,'ready');
}
{
  const f=fixture();f.source.loading=true;const p=f.sandbox.__crOfflineWaitForImage(4,'old-image','loading');
  f.tick(100);assert.equal(f.observers.size,1);f.source.loading=false;f.mutate();f.tick(50);
  assert.equal(JSON.parse(await p).status,'ready','Never remove the loading guard');
}
{
  const f=fixture();f.source.page={start:3,end:18};const p=f.sandbox.__crOfflineWaitForImage(4,'old-image','wrong-source');
  f.tick(100);assert.equal(f.observers.size,1);f.sandbox.__crOfflineCancelWait('wrong-source');
  assert.equal(JSON.parse(await p).status,'cancelled');f.tick(30000);assert.equal(f.recoveries,0);
}
{
  const f=fixture();f.sandbox.__crOfflineCancelWait('early');
  assert.equal(JSON.parse(await f.sandbox.__crOfflineWaitForImage(4,'old-image','early')).status,'cancelled');
  const p=f.sandbox.__crOfflineWaitForImage(4,'old-image','active');
  assert.equal(JSON.parse(await f.sandbox.__crOfflineWaitForImage(4,'old-image','second')).status,'busy');
  f.sandbox.__crOfflineCancelWait('early');f.tick(50);assert.equal(JSON.parse(await p).status,'ready');
}
{
  const f=fixture();f.setIdentity('old-image');const p=f.sandbox.__crOfflineWaitForImage(4,'old-image','blank');
  f.tick(599);assert.equal(f.observers.size,1);f.tick(1);
  assert.equal(JSON.parse(await p).status,'same-image','Equal images retain the conservative native check');
}
{
  const f=fixture();f.source.loading=true;const p=f.sandbox.__crOfflineWaitForImage(4,'old-image','timeout');
  f.tick(25000);assert.equal(JSON.parse(await p).status,'timeout');assert.equal(f.recoveries,1);assert.equal(f.timers.size,0);
}
{
  const f=fixture();f.sandbox.__crKindleOfflineImageIdentity=()=>{throw Error('detached surface');};
  assert.equal(JSON.parse(await f.sandbox.__crOfflineWaitForImage(4,'old-image','error')).status,'invalid-source');
  assert.equal(f.observers.size,0);assert.equal(f.timers.size,0);
}
console.log('Offline event wait: stale images, wrong order/source, loading, cancellation, duplicate requests, identical pages and timeout passed.');
