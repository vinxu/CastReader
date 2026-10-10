// Compose genuine iOS capture pixels with the approved Android visual language.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const {chromium} = require('playwright');
const sharp = require('sharp');
const root = path.resolve(__dirname, '../../..');
const report = path.join(root, 'reports/ios-release-1.2.48');
const metadata = JSON.parse(fs.readFileSync(path.join(__dirname, 'metadata.json')));
const args = process.argv.slice(2), selected = args.filter(x => !x.startsWith('--'));
const profiles = args.includes('--ipad') ? ['ipad'] : args.includes('--iphone') ? ['iphone'] : ['iphone','ipad'];
const icon = fs.readFileSync(path.join(__dirname, 'brand-icon.png')).toString('base64');
const esc = s => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
(async () => {
 const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
 const qa = [];
 for (const profile of profiles) {
  const pad = profile==='ipad', width=pad?2732:1320, height=pad?2048:2868;
  const page=await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
  for (const [language,m] of Object.entries(metadata)) {
   if(selected.length && !selected.includes(language)) continue;
   for(let scene=1;scene<=5;scene++) {
    const raw=path.join(report,'raw',profile,`${language}-${scene}.png`);
    if(!fs.existsSync(raw)) continue;
    const sourceBytes=fs.readFileSync(raw), bytes=await sharp(sourceBytes).autoOrient().png().toBuffer(), rawMeta=await sharp(bytes).metadata();
    if(pad ? rawMeta.width<rawMeta.height : rawMeta.width>rawMeta.height) throw Error('Wrong orientation: '+raw);
    const title=(pad?m.ipadCaptions:m.phoneCaptions)[scene-1];
    const textSide=m.rtl?'right':'left', imageSide=m.rtl?'left':'right';
    const rawURL='data:image/png;base64,'+bytes.toString('base64');
    const screenW=pad?1790:990, screenH=screenW*rawMeta.height/rawMeta.width;
    const phoneTop=height-screenH-100;
    const html=`<!doctype html><html lang="${language}" dir="ltr"><meta charset="utf-8"><style>
     *{box-sizing:border-box}html,body{margin:0;width:${width}px;height:${height}px;overflow:hidden}
     body{position:relative;background:${pad?'#f6f3ed':'#fff9f3'};color:#222624;font-family:Arial,'Noto Sans','PingFang SC','Hiragino Sans',sans-serif}
     .wash{position:absolute;${imageSide}:-200px;top:320px;width:1900px;height:1600px;border-radius:50%;background:#f5ddcb}
     .brand{position:absolute;${pad?textSide+':90px':'left:0;width:100%;justify-content:center'};top:${pad?145:112}px;display:flex;align-items:center;gap:20px;font-size:${pad?50:43}px;font-weight:700;direction:ltr;letter-spacing:-1px}
     .brand img{width:${pad?76:62}px;height:${pad?76:62}px;border-radius:18px}
     .copy{direction:${m.rtl?'rtl':'ltr'};position:absolute;${pad?textSide+':90px':'left:70px'};top:${pad?595:258}px;width:${pad?645:1180}px;text-align:${pad?(m.rtl?'right':'left'):'center'}}
     h1{font-size:${pad?102:100}px;line-height:1.13;letter-spacing:-1.5px;font-weight:750;margin:0;text-wrap:balance;word-break:${language==='ko'?'keep-all':'normal'};overflow-wrap:break-word}
     .rule{width:80px;height:7px;background:#f66b23;margin-top:45px;${pad?'':'margin-left:auto;margin-right:auto'}}
     .device{position:absolute;${pad?imageSide+':88px':'left:151px'};top:${pad?370:phoneTop}px;width:${screenW+28}px;padding:12px;border:2px solid #625950;background:#242321;border-radius:${pad?42:87}px;box-shadow:0 28px 70px #52331825;direction:ltr}
     .device img{display:block;width:${screenW}px;height:${screenH}px;border-radius:${pad?28:73}px}
     .detail{position:absolute;${pad?textSide+':90px':'left:0;width:100%;text-align:center'};bottom:${pad?146:39}px;font-size:${pad?29:26}px;color:#6c6c63;direction:ltr}
     .dots{position:absolute;${textSide}:90px;bottom:100px;display:flex;gap:12px}.dots i{width:45px;height:6px;background:#ddd7cf}.dots i.active{background:#f66b23}
     </style>${pad?'<div class="wash"></div>':''}<div class="brand"><img src="data:image/png;base64,${icon}">CastReader</div><div class="copy"><h1>${esc(title)}</h1><div class="rule"></div></div><div class="device"><img src="${rawURL}"></div><div class="detail">CastReader · ${pad?'iPad':'iPhone'}</div>${pad?`<div class="dots">${[1,2,3,4,5].map(n=>`<i class="${n===scene?'active':''}"></i>`).join('')}</div>`:''}</html>`;
    await page.setContent(html);await page.evaluate(()=>document.fonts.ready);
    const layout=await page.evaluate(({pad,phoneTop,width,height})=>{
      const h=document.querySelector('h1'),copy=document.querySelector('.copy');let size=parseInt(getComputedStyle(h).fontSize);
      const maxHeight=pad?675:phoneTop-copy.getBoundingClientRect().top-95;
      while((h.getBoundingClientRect().height>maxHeight || h.scrollWidth>h.clientWidth) && size>64){size-=2;h.style.fontSize=size+'px'}
      return {fontSize:size,copyBottom:copy.getBoundingClientRect().bottom,overflow:h.scrollWidth>h.clientWidth,
       frames:[...document.querySelectorAll('.brand,.copy,.device,.detail,.dots')].map(e=>{const r=e.getBoundingClientRect();return {left:r.left,right:r.right,top:r.top,bottom:r.bottom}})};
    },{pad,phoneTop,width,height});
    if(layout.overflow||layout.frames.some(r=>r.left<0||r.right>width||r.top<0||r.bottom>height)||(!pad&&layout.copyBottom>phoneTop-25)) throw Error(JSON.stringify({profile,language,scene,layout}));
    const folder=path.join(report,'screenshots',profile,language);fs.mkdirSync(folder,{recursive:true});
    const dest=path.join(folder,`${String(scene).padStart(2,'0')}.png`);
    await sharp(await page.screenshot()).flatten({background:'#fff9f3'}).png().toFile(dest);
    const final=await sharp(dest).metadata(); if(final.hasAlpha) throw Error('Alpha: '+dest);
    qa.push({profile,language,scene,width,height,bytes:fs.statSync(dest).size,rawWidth:rawMeta.width,rawHeight:rawMeta.height,rawSha256:crypto.createHash('sha256').update(bytes).digest('hex'),sha256:crypto.createHash('sha256').update(fs.readFileSync(dest)).digest('hex'),layout,file:path.relative(root,dest)});
   }
  }
  await page.close();
 }
 const qp=path.join(report,`render-qa-${profiles.join('-')}-${selected.join('-')||'all'}.json`);fs.writeFileSync(qp,JSON.stringify(qa,null,2)+'\n');
 await browser.close();console.log('Rendered',qa.length,'verified opaque screenshots');
})().catch(e=>{console.error(e);process.exit(1)});
