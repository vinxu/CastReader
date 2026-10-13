import puppeteer from '/Users/xuxuheng/Documents/MyProject/readout-desktop/eval/node_modules/puppeteer/lib/esm/puppeteer/puppeteer.js';
import fs from 'node:fs/promises';
const root=process.cwd(), report=root+'/reports/ios-28-languages-20261008/web135-malay-highlight';
const browser=await puppeteer.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--disable-background-networking']});
try {
 const page=await browser.newPage();await page.setViewport({width:402,height:760,isMobile:true,deviceScaleFactor:1});
 await page.setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Mobile/15E148 Safari/604.1');
 await page.goto('https://ms.wikipedia.org/wiki/Bumi?useskin=vector',{waitUntil:'domcontentloaded',timeout:60000});
 await page.evaluate(()=>{window.crProbe=[];window.webkit={messageHandlers:{castreader:{postMessage:m=>window.crProbe.push(m)}}}});
 await page.addScriptTag({content:await fs.readFile(root+'/CastReader/WebAssets/bundle.js','utf8')});
 await page.waitForFunction(()=>window.crProbe.some(m=>m.type==='rendered'),{timeout:20000});
 const data=await page.evaluate(()=>{
  const rows=window.crProbe.find(m=>m.type==='rendered').payload.paragraphs;
  return rows.slice(0,10).map(p=>{const el=document.querySelector(`[data-cr-para="${p.paragraphIndex}"]`);const r=el?.getBoundingClientRect();return {...p,element:el?.tagName,rect:r?{x:r.x,y:r.y,width:r.width,height:r.height}:null}});
 });
 await fs.writeFile(report+'/extracted-first-paragraphs.json',JSON.stringify(data,null,2));
 const observations=[];
 for(const p of data.slice(0,4)){
  const audit=await page.evaluate(p=>{window.CR.init({segments:window.crProbe.find(m=>m.type==='rendered').payload.paragraphs});let words=p.text.split(/\s+/);window.CR.highlightWord({paragraphIndex:p.paragraphIndex,segSeq:0,words,wordIndex:Math.min(words.length-1,10),segmentTexts:[]});const overlay=[...document.querySelectorAll('.cr-hl-ov')].map(e=>{let r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}});return {paragraph:p.paragraphIndex,word:words[10],overlay,logs:window.crProbe.filter(m=>m.type==='log').slice(-3)}},p);observations.push(audit);
 }
 await fs.writeFile(report+'/browser-observations.json',JSON.stringify(observations,null,2));
 console.log(JSON.stringify({paragraphs:data.map(p=>({index:p.paragraphIndex,chars:p.text.length,prefix:p.text.slice(0,80),element:p.element,rect:p.rect})),observations}));
} finally {await browser.close()}
