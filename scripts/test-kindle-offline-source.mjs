import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const file = new URL('../CastReader/Services/KindleOfflineSourceScript.swift', import.meta.url);
const script = fs.readFileSync(file, 'utf8').split('static let bootstrap = #"""')[1].split('"""#')[0];
function tar(files) {
  const chunks=[];
  for(const [name,value] of Object.entries(files)) {
    const data=Buffer.from(JSON.stringify(value)), header=Buffer.alloc(512);
    header.write(name);header.write(data.length.toString(8).padStart(11,'0'),124);
    chunks.push(header,data,Buffer.alloc((512-data.length%512)%512));
  }
  return Buffer.concat([...chunks,Buffer.alloc(1024)]);
}
const pages=[{startPositionId:1,endPositionId:1,wordsInPage:0,pageIndex:0,width:432,height:714},
  {startPositionId:3,endPositionId:99,wordsInPage:20,pageIndex:1,width:432,height:714}];
const bytes=tar({'metadata.json':{firstPositionId:0,lastPositionId:100,coverPosistion:0,lang:'en'},
  'manifest.json':{asin:'B000000001',revision:'test'},'page_data_0_1.json':pages});
const calls=[];
const navigation={state:{currentPosition:3,pagePositionRange:{startPosition:3,endPosition:100}},
  readerState:{isRendererLoading:false},nextPage(){},moveToPosition(position){calls.push(position);}};
const root={stateNode:{}};root.stateNode.current=root;
const readingCalls=[];
const readingService={startReading(){},stillReading(payload){readingCalls.push(payload);return Promise.resolve();},doneReading(payload){readingCalls.push(payload);return Promise.resolve();}};
const current={return:root,memoizedProps:{value:navigation},memoizedState:{memoizedState:[readingService,[]],next:null}};
const staleRoot={stateNode:root.stateNode};
const stale={return:staleRoot,alternate:current,memoizedProps:{value:{...navigation,state:{currentPosition:1},moveToPosition(){throw new Error('stale fiber');}}}};
const node={'__reactFiber$fixture':stale};
let receivedInput, receivedOptions;
const sandbox={window:null,document:{querySelectorAll(){return [node];}},location:{href:'https://read.amazon.com/'},
  TextDecoder,Uint8Array,Map,Set,URL,URLSearchParams,Request,Response,Promise,
  fetch:async(input,options)=>{receivedInput=input;receivedOptions=options;return new Response(bytes);}};
sandbox.window=sandbox;
vm.runInNewContext(script,sandbox);
const input='https://read.amazon.com/renderer/render?width=432&height=714&startingPosition=0&asin=B000000001';
const options={headers:{'X-Test':'unchanged'}};
const response=await sandbox.fetch(input,options);
assert.equal(receivedInput,input);assert.equal(receivedOptions,options);
assert.deepEqual(Buffer.from(await response.arrayBuffer()),bytes,'consumer response remains untouched');
await new Promise(resolve=>setTimeout(resolve,10));
const result=JSON.parse(sandbox.__crOfflineSourceRead());
assert.equal(result.current,3);assert.equal(result.loading,false);
assert.equal(result.page.words,20);assert.equal(result.metadata.maximum,100);
assert.equal(result.layout.width,'432');assert.equal(result.layout.startingPosition,undefined);
assert.equal(sandbox.__crOfflineSourceMove(53),true);assert.deepEqual(calls,[53]);
assert.equal(sandbox.__crOfflineSourceMove(101),false);assert.equal(sandbox.__crOfflineSourceMove(-1),false);
assert.equal(sandbox.__crOfflineProgressGuard(true,'B000000001'),true);
await readingService.stillReading({asin:'B000000001',readingPosition:99});
assert.equal(readingCalls.length,0,'download cannot publish a furthest-read position');
await readingService.stillReading({asin:'B000000002',readingPosition:20});
assert.equal(readingCalls.length,1,'other book requests remain unchanged');
assert.equal(sandbox.__crOfflineProgressGuard(false),true);
await readingService.doneReading({asin:'B000000001',readingPosition:3});
assert.equal(readingCalls.length,2,'ordinary reading resumes after capture');
console.log('Kindle offline source: active React branch, source bounds, request isolation, and intact response passed.');
