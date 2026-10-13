import puppeteer from '/Users/xuxuheng/Documents/MyProject/readout-desktop/eval/node_modules/puppeteer/lib/esm/puppeteer/puppeteer.js';
import fs from 'node:fs/promises';
const root=process.cwd(),report=root+'/reports/ios-28-languages-20261008/web135-malay-highlight';
const rows=[{language:'nb',url:'https://no.wikipedia.org/wiki/Jorden?useskin=vector'}];
const bundle=await fs.readFile(root+'/CastReader/WebAssets/bundle.js','utf8');
const browser=await puppeteer.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true,args:['--disable-background-networking']});
const results=[];
try {
 const page=await browser.newPage();await page.setViewport({width:402,height:760,isMobile:true,deviceScaleFactor:1});
 await page.setUserAgent('Mozilla/5.0 (iPhone; CPU iPhone OS 26_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.5 Mobile/15E148 Safari/604.1');
 for(const row of rows){
  try{
   await page.goto(row.url,{waitUntil:'domcontentloaded',timeout:45000});
   await page.evaluate(()=>{window.crProbe=[];window.webkit={messageHandlers:{castreader:{postMessage:m=>window.crProbe.push(m)}}}});
   await page.addScriptTag({content:bundle});
   await page.waitForFunction(()=>window.crProbe.some(m=>m.type==='rendered'),{timeout:15000});
   const result=await page.evaluate(()=>{
    const rows=window.crProbe.find(m=>m.type==='rendered').payload.paragraphs;
    window.CR.init({segments:rows});
    const sample=rows.find(p=>p.text.length>100);
    const words=sample.text.split(/\s+/);const wordIndex=Math.min(4,words.length-1);
    window.CR.highlightWord({paragraphIndex:sample.paragraphIndex,segSeq:0,words,wordIndex,segmentTexts:[]});
    return {paragraphs:rows.length,characters:rows.reduce((n,p)=>n+p.text.length,0),styleLeakCount:rows.filter(p=>/\.mw-parser-output|font-family:|@media\s*\(/.test(p.text)).length,
     sample:{paragraph:sample.paragraphIndex,word:words[wordIndex],overlayRects:[...document.querySelectorAll('.cr-hl-ov')].map(e=>{let r=e.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height}})}};
   });results.push({language:row.language,url:row.url,...result});console.log(row.language,JSON.stringify(result));
  }catch(error){results.push({language:row.language,url:row.url,error:String(error)});console.log(row.language,String(error));}
  await fs.writeFile(report+'/norwegian-longer-source.json',JSON.stringify({scope:'headless browser; extraction/word geometry only, no TTS, no user authentication',results},null,2));
 }
}finally{await browser.close()}
