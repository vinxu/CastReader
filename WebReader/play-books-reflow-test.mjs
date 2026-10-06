import assert from 'node:assert/strict';
import {build} from 'esbuild';
const built = await build({entryPoints:['src/play-books.ts'],bundle:true,write:false,format:'esm',platform:'node',target:'es2022',define:{__CASTREADER_XCTEST_FIXTURES__:'false'}});
const {playBooksReflowSourceDirection: direction} = await import('data:text/javascript;base64,' + Buffer.from(built.outputFiles[0].text).toString('base64'));
const target = 'This uniquely identifiable speaking paragraph continues beyond the measured page fragment. ';
const earlier = 'The unique earlier neighboring paragraph establishes the original reading order without guessing pages.';
const later = 'The unique later neighboring paragraph establishes the reverse reading order without guessing pages.';
const unrelated = 'A completely unrelated currently visible page supplies no target evidence.';
function snapshot(texts, visibleIndex) {
  const pages = texts.map((text,index)=>({id:`page-0-${index}`,key:`key-${index}`,segment:0,index,element:{},blocks:[{text,raw:text,element:{},reopened:false,sliced:false}]}));
  return {layout:'verified-layout',pages,visible:[pages[visibleIndex]],ready:true,last:false,columns:1};
}
assert.equal(direction(snapshot([target,unrelated],1),target+'Audio after the measured fragment.'),'prev');
assert.equal(direction(snapshot([later,unrelated],1),target,[{text:later,side:'after'}]),'prev');
assert.equal(direction(snapshot([later,unrelated,earlier],1),target,[{text:earlier,side:'before'},{text:later,side:'after'}]),null);
assert.equal(direction(snapshot([unrelated,target,target],0),target+'Audio after the measured fragment.'),null);
assert.equal(direction(snapshot([target,unrelated],0),target+'Audio after the measured fragment.'),null);
assert.equal(direction(snapshot([unrelated,earlier],0),target,[{text:'The unique earlier neighboring paragraph establishes a DIFFERENT reading order without guessing pages.',side:'before'}]),null);
console.log(JSON.stringify({ok:true,cases:6,coverage:['reverse partial source','reverse verified neighbor','conflicting direction','repeated partial source','already visible source','changed neighbor']}));
