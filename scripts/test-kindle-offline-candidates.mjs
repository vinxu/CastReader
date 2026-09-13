import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const swift=fs.readFileSync(new URL('../CastReader/Services/KindleWebScripts.swift',import.meta.url),'utf8');
const script=swift.slice(swift.indexOf('var offlineCandidateElements ='),swift.indexOf('function candidateOrderY('));
let scans=0,styleReads=0;const observers=new Set();
const first={src:'blob:first',naturalWidth:100,naturalHeight:200,isConnected:true,x:0};
const second={src:'blob:second',naturalWidth:100,naturalHeight:200,isConnected:true,x:100};
let images=[first];const unrelated=Array.from({length:200},()=>({}));
const rect=el=>({left:el.x,top:0,width:100,height:200});
const sandbox={window:null,document:{documentElement:{},querySelectorAll(selector){scans++;return selector==='img'?images:[...images,...unrelated];}},
  MutationObserver:class{constructor(fn){this.fn=fn;}observe(){observers.add(this);}disconnect(){observers.delete(this);}},
  imageElementContentRect:rect,keyForUrl:url=>url,stableImageKey:url=>url,
  visibleArea:r=>r.left===0?20000:0,readingBandArea:()=>0,
  blobUrlFromBackground(){styleReads++;return '';},liveImageFor(){throw Error('No background image expected');}};
sandbox.window=sandbox;vm.runInNewContext(script,sandbox);
assert.equal(sandbox.candidates(true)[0].key,'blob:first');const afterFirst=styleReads;
for(let i=0;i<10;i++)sandbox.candidates(true);
assert.equal(scans,2);assert.equal(styleReads,afterFirst,'Readiness samples do not scan all computed styles again');
first.x=100;first.src='blob:replacement';
assert.equal(sandbox.candidates(true)[0].key,'blob:replacement','Image identity is always fresh');
assert.equal(sandbox.candidates(true)[0].visible,0,'Geometry is never cached');
images=[second];for(const o of observers)o.fn();
assert.equal(sandbox.candidates(true)[0].key,'blob:second','Mutation re-discovers replaced nodes');
second.isConnected=false;assert.equal(sandbox.candidates(true).length,0,'Detached nodes cannot be captured');
sandbox.__crKindleOfflineResetCandidates();assert.equal(observers.size,0);
const previous=scans;sandbox.candidates();sandbox.candidates();assert.equal(scans,previous+4,'Online capture retains original discovery');
console.log('Offline candidate cache: reduced scans, fresh identity/geometry, replacement, detach and cleanup passed.');
