const fs = require('fs');
const path = require('path');
const {pathToFileURL} = require('url');
const {chromium} = require(process.env.CASTREADER_PLAYWRIGHT || '/Users/xuxuheng/.cache/codex-runtimes/codex-primary-runtime/dependencies/node/node_modules/playwright');
const root=path.resolve(__dirname,'..');
const titles={
'en-US':['Your books. A bigger canvas.','Listen and follow every word.','Understand with marks on the page.','Find a voice you love.','Read PDFs, books and more.'],
'zh-Hans':['大屏书架，阅读更从容','边听边看，逐词跟读','听懂讲解，看懂原文','找到你喜欢的声音','PDF、电子书、文档，都能读'],
'ja':['大きな画面で、もっと快適に','聴きながら、一語ずつ追える','解説とマークで理解を深める','お気に入りの声を見つけよう','PDFも電子書籍も、音声で'],
'de-DE':['Deine Bücher. Mehr Raum.','Zuhören und Wort für Wort folgen.','Erklärungen mit Markierungen.','Finde deine Lieblingsstimme.','PDFs, Bücher und mehr vorlesen.'],
'es-ES':['Tus libros, a lo grande.','Escucha y sigue cada palabra.','Comprende con marcas en el texto.','Encuentra tu voz favorita.','Escucha PDF, libros y más.'],
'fr-FR':['Vos livres, en grand.','Écoutez et suivez chaque mot.','Comprenez grâce aux annotations.','Trouvez la voix qui vous plaît.','Écoutez vos PDF, livres et plus.'],
'it':['I tuoi libri, in grande.','Ascolta e segui ogni parola.','Comprendi con le annotazioni.','Trova la voce che ami.','Ascolta PDF, libri e altro.'],
'pt-BR':['Seus livros em uma tela maior.','Ouça e acompanhe cada palavra.','Entenda com marcações no texto.','Encontre sua voz favorita.','Ouça PDFs, livros e muito mais.'],
'hi':['बड़ी स्क्रीन पर आपकी किताबें','सुनें और हर शब्द के साथ पढ़ें','मूल पाठ पर निशानों से समझें','अपनी पसंद की आवाज़ पाएँ','PDF, किताबें और भी बहुत कुछ पढ़ें']
};
(async()=>{
 const browser=await chromium.launch({headless:true, channel:"chrome"});
 const page=await browser.newPage({viewport:{width:2048,height:2732},deviceScaleFactor:1});
 const locale=process.argv[2]||'en-US';
 const dir=path.join(root,'AppStoreAssets/1.2.43/iPad');
 const names=['01-home','02-kindle-read','03-kindle-explain','04-voices','05-import'];
 fs.mkdirSync(path.join(dir,'final',locale),{recursive:true});
 for(let i=0;i<names.length;i++){
  const source=path.join(dir,'raw',locale,names[i]+'.png');if(!fs.existsSync(source))throw Error('Missing actual screenshot '+source);
  const url=pathToFileURL(path.join(root,'scripts/app_store_ipad_screenshot.html'));
  url.searchParams.set('title',titles[locale][i]);url.searchParams.set('image',pathToFileURL(source).href);
  await page.goto(url.href);await page.locator('img').evaluate(el=>el.decode());await page.evaluate(()=>document.fonts.ready);
  await page.screenshot({path:path.join(dir,'final',locale,names[i]+'.png')});
 }
 await browser.close();console.log('Rendered '+locale+': 5 iPad screenshots, 2048×2732, complete uncropped app images.');
})().catch(e=>{console.error(e);process.exit(1)});
