// Compose genuine Mac window captures using the released iOS campaign style.
// The app pixels are never replaced with translated mockups or invented state.
const fs = require('fs'), path = require('path'), crypto = require('crypto');
const { chromium } = require('playwright');
const sharp = require('sharp');
const root = path.resolve(__dirname, '../../..');
const report = path.join(root, 'reports/mac-28-languages-20261011');
const metadata = JSON.parse(fs.readFileSync(path.join(__dirname, 'metadata.json')));
const selected = process.argv.slice(2).filter(x => !x.startsWith('--'));
const requireComplete = process.argv.includes('--require-complete');
const icon = fs.readFileSync(path.join(__dirname, '../1.2.48/brand-icon.png')).toString('base64');
const esc = s => s.replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
(async () => {
  const browser = await chromium.launch({executablePath:'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',headless:true});
  const width = 2560, height = 1600;
  const page = await browser.newPage({viewport:{width,height},deviceScaleFactor:1});
  const qa = [];
  for (const [language, m] of Object.entries(metadata)) {
    if (selected.length && !selected.includes(language)) continue;
    for (let scene = 1; scene <= 5; scene++) {
      const raw = path.join(report, 'raw', `${language}-${scene}.png`);
      if (!fs.existsSync(raw)) {
        if (requireComplete) throw Error('Missing genuine capture: ' + raw);
        continue;
      }
      const original = fs.readFileSync(raw), rm = await sharp(original).metadata();
      if (rm.width < 1200 || rm.height < 700 || rm.width <= rm.height) throw Error('Insufficient Mac capture: '+raw);
      const screenW = Math.min(1740, 1280 * rm.width / rm.height), screenH = screenW * rm.height / rm.width;
      const side = m.rtl ? 'right' : 'left', imageSide = m.rtl ? 'left' : 'right';
      const imageTop = (height - screenH) / 2;
      await page.setContent(`<!doctype html><html lang="${language}" dir="ltr"><meta charset="utf-8"><style>
        *{box-sizing:border-box}html,body{margin:0;width:${width}px;height:${height}px;overflow:hidden}
        body{position:relative;background:#f6f3ed;color:#222624;font-family:Arial,'Noto Sans','PingFang SC','Hiragino Sans',sans-serif}
        .wash{position:absolute;${imageSide}:-180px;top:200px;width:1850px;height:1400px;border-radius:50%;background:#f5ddcb}
        .brand{position:absolute;${side}:80px;top:125px;display:flex;align-items:center;gap:18px;font-size:46px;font-weight:700;direction:ltr;letter-spacing:-1px}
        .brand img{width:72px;height:72px;border-radius:17px}
        .copy{direction:${m.rtl?'rtl':'ltr'};position:absolute;${side}:80px;top:500px;width:595px;text-align:${m.rtl?'right':'left'}}
        h1{font-size:100px;line-height:1.15;letter-spacing:-1.5px;font-weight:750;margin:0;text-wrap:balance;word-break:${language==='ko'?'keep-all':'normal'};overflow-wrap:break-word}
        .rule{width:80px;height:7px;background:#f66b23;margin-top:40px}
        .window{position:absolute;${imageSide}:75px;top:${imageTop}px;width:${screenW+4}px;padding:1px;border:1px solid #aaa39b;background:#f5f3ef;border-radius:18px;box-shadow:0 25px 65px #52331825;direction:ltr;overflow:hidden}
        .window img{display:block;width:${screenW}px;height:${screenH}px;border-radius:16px}
        .detail{position:absolute;${side}:80px;bottom:150px;font-size:29px;color:#6c6c63;direction:ltr}
        .dots{position:absolute;${side}:80px;bottom:105px;display:flex;gap:12px}.dots i{width:45px;height:6px;background:#ddd7cf}.dots i.active{background:#f66b23}
      </style><div class="wash"></div><div class="brand"><img src="data:image/png;base64,${icon}">CastReader</div><div class="copy"><h1>${esc(m.macCaptions[scene-1])}</h1><div class="rule"></div></div><div class="window"><img src="data:image/png;base64,${original.toString('base64')}"></div><div class="detail">CastReader · Mac</div><div class="dots">${[1,2,3,4,5].map(n=>`<i class="${n===scene?'active':''}"></i>`).join('')}</div></html>`);
      await page.evaluate(()=>document.fonts.ready);
      const layout = await page.evaluate(() => {
        const h = document.querySelector('h1');let size=100;
        while ((h.getBoundingClientRect().height>650 || h.scrollWidth>h.clientWidth) && size>64) {size-=2;h.style.fontSize=size+'px';}
        return {fontSize:size,overflow:h.scrollWidth>h.clientWidth,frames:[...document.querySelectorAll('.brand,.copy,.window,.detail,.dots')].map(e=>{const r=e.getBoundingClientRect();return {kind:e.className,left:r.left,right:r.right,top:r.top,bottom:r.bottom};})};
      });
      if (layout.overflow || layout.frames.some(r=>r.left<0||r.right>width||r.top<0||r.bottom>height)) throw Error(JSON.stringify({language,scene,layout}));
      const copy=layout.frames.find(x=>x.kind==='copy'), window=layout.frames.find(x=>x.kind==='window');
      if (copy.bottom > 1400 || !(copy.right < window.left || copy.left > window.right)) throw Error('Overlapping copy: '+language);
      const folder=path.join(report,'screenshots',language);fs.mkdirSync(folder,{recursive:true});
      const file=path.join(folder,`${String(scene).padStart(2,'0')}.png`);
      await sharp(await page.screenshot()).flatten({background:'#f6f3ed'}).png().toFile(file);
      const final=await sharp(file).metadata();
      if(final.hasAlpha || final.width!==width || final.height!==height)throw Error('Wrong final image format');
      qa.push({language,scene,width,height,rawWidth:rm.width,rawHeight:rm.height,rawSha256:digest(original),sha256:digest(fs.readFileSync(file)),layout,file:path.relative(root,file)});
    }
  }
  fs.writeFileSync(path.join(report,`render-qa-${selected.join('-')||'all'}.json`),JSON.stringify(qa,null,2)+'\n');
  await browser.close();
  console.log('Rendered',qa.length,'verified opaque Mac screenshots');
})().catch(e=>{console.error(e);process.exit(1);});
