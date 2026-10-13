from pathlib import Path
from html import escape
import json,zipfile,hashlib
P=Path(__file__).resolve().parent
BASE=P.parent/'october-featuring-20261011'
W=BASE/'press-site'
S=W/'samples';S.mkdir(exist_ok=True)
samples={
'en':{'lang':'en','title':'The rooftop garden','paragraphs':[
'A neighborhood library has a small rooftop garden. Maya, the librarian, wants visitors to spend more time there. She has enough money for either new chairs or a rainwater tank, but not both.',
'New chairs would make the garden more comfortable immediately. A tank would store rainwater for dry days, helping the plants survive while reducing the need to carry water upstairs. However, visitors would still have only two places to sit.',
'Maya asks volunteers to count visitors for one week and record how often the plants need watering. The notes show that most visitors stay for less than five minutes. They also show that volunteers carry water upstairs every afternoon.',
'The team chooses the tank first. A local workshop offers to repair two unused benches the following month. Maya will compare visitor numbers and watering time again after both changes. The decision balances an immediate maintenance problem with a later improvement to the visitor experience.'
]},
'zh-Hans':{'lang':'zh-Hans','title':'屋顶花园','paragraphs':[
'社区图书馆有一座小小的屋顶花园。图书管理员小林希望读者愿意在那里多待一会儿。她的预算只够添置新椅子或安装一个雨水收集箱，无法同时完成两件事。',
'新椅子能立刻让花园更舒适。雨水收集箱则能储存雨水，方便在晴天浇灌植物，减少志愿者提水上楼的次数。不过，安装水箱之后，花园里仍然只有两个座位。',
'小林请志愿者连续一周记录访客人数和浇水情况。记录显示，大多数读者停留不到五分钟，而志愿者每天下午都要提水上楼。',
'团队决定先安装水箱。附近的一家工坊愿意在下个月修好两张闲置长椅。两项改动完成后，小林会再次比较访客人数和浇水时间。这项安排先解决眼前的维护问题，再改善读者的休息体验。'
]}}
for code,item in samples.items():
 stem=f'castreader-demo-{code}'
 txt=item['title']+'\n\n'+'\n\n'.join(item['paragraphs'])+'\n'
 (S/(stem+'.txt')).write_text(txt)
 uid='urn:castreader:editorial-demo:20261011:'+code
 container='<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>'
 opf=f'''<?xml version="1.0" encoding="utf-8"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="book-id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="book-id">{uid}</dc:identifier><dc:title>{escape(item['title'])}</dc:title><dc:language>{code}</dc:language><dc:creator>CastReader editorial demo</dc:creator><meta property="dcterms:modified">2026-10-11T00:00:00Z</meta></metadata><manifest><item id="chapter" href="chapter.xhtml" media-type="application/xhtml+xml"/><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/></manifest><spine><itemref idref="chapter"/></spine></package>'''
 chapter=f'''<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xml:lang="{code}" lang="{code}"><head><title>{escape(item['title'])}</title><meta name="viewport" content="width=device-width, initial-scale=1.0"/></head><body><h1>{escape(item['title'])}</h1>{''.join('<p>'+escape(p)+'</p>' for p in item['paragraphs'])}</body></html>'''
 nav=f'''<?xml version="1.0" encoding="utf-8"?><html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" xml:lang="{code}" lang="{code}"><head><title>Contents</title></head><body><nav epub:type="toc"><h1>Contents</h1><ol><li><a href="chapter.xhtml">{escape(item['title'])}</a></li></ol></nav></body></html>'''
 with zipfile.ZipFile(S/(stem+'.epub'),'w') as z:
  z.writestr('mimetype','application/epub+zip',compress_type=zipfile.ZIP_STORED)
  for name,content in [('META-INF/container.xml',container),('EPUB/package.opf',opf),('EPUB/chapter.xhtml',chapter),('EPUB/nav.xhtml',nav)]: z.writestr(name,content,compress_type=zipfile.ZIP_DEFLATED)

guide='''CastReader — editor trial guide
Updated 11 October 2026. Current public iOS release: 1.2.48.
App Store: https://apps.apple.com/app/id6757636395
Media kit: https://press.castreader.com/
Online guide: https://press.castreader.com/review-guide.html

STORY
Follow the words. Hear the meaning. Read Aloud combines speech, word highlighting and scrolling. AI Explain speaks an explanation while marks appear on the original text. Readers bring their own material.

BEFORE YOU START
Use the public App Store release on iPhone or iPad and an internet connection. Allow roughly three minutes once installed; setup, sign-in and generation can take additional time. Follow any in-app sign-in prompts. Free daily usage is available; limits and feature availability apply. No shared account, subscription purchase or special access is supplied with this guide.

1. BRING A SHORT PASSAGE (about 30 seconds)
Use the home screen's text entry to paste the English or Chinese sample, or download its EPUB to Files and import it through the file entry. Use the TXT fallback if needed. The samples are short fictional passages written for this demo, not extracts from a supplied book catalog.

2. LISTEN AND FOLLOW (about 60 seconds)
Choose Read Aloud and start playback. Watch the spoken word move through the passage and the text scroll as needed. Pause, move to a different paragraph and resume. The material stays visible while you listen.

3. HEAR AN EXPLANATION (about 60 seconds)
Switch to AI Explain and start it. It speaks an explanation of the passage while marks appear on the original text. For this sample, look for the choice between chairs and a water tank, the evidence collected and the team's final decision. Exact wording and marks vary because the explanation is generated. Check its interpretation against the source; it is not a fixed answer key.

4. COMPARE ON IPAD (optional, about 30 seconds)
Open the same sample on iPad in landscape and compare how much source text remains in view. Current iPad screenshots are in the media kit.

ADDITIONAL ROUTES
Photo: photograph a clearly printed sample and open the recognized text. OCR runs on-device; speech and explanations still use online services.
Safari: enable the CastReader extension in Safari settings and grant it access to the page you want to read, then use it on the online sample page. Safari settings vary by OS version. Use the pasted-text route first if extension setup would interrupt the short trial.
Language: the Chinese sample supplies Chinese source text, not just translated UI. Voice and feature availability vary by language and region.

BOUNDARIES
CastReader does not supply a book catalog. It is not an offline speech engine. No clinical outcomes or unverified VoiceOver/system accessibility support are claimed. Optional Pro subscription and cloned-voice allowance details appear in the app.

MEDIA PROVENANCE
The 29.8-second approved App Store preview was recorded for an earlier release and is retained in the current listing. It is not new 1.2.48 footage. The kit's eight screenshots are current 1.2.48 store assets. Sample files are new original editorial demo material; this guide is a suggested trial, not evidence that every route has been retested on the current release.

CONTACT
support@castreader.ai
'''
(W/'review-guide.txt').write_text(guide)
css=(BASE/'site.css').read_text()+'''
.guide-hero {padding:52px 0 28px;max-width:840px;} .guide-hero h1 {font-size:clamp(38px,5.5vw,62px);} .notice {border-left:3px solid #a4410c;padding:8px 22px;background:#fff;border-radius:0 12px 12px 0;} .steps {list-style:none;padding:0;counter-reset:step;} .steps>li{counter-increment:step;display:grid;grid-template-columns:44px 1fr;gap:20px;padding:24px 0;border-bottom:1px solid #d9dcd3;} .steps>li::before{content:counter(step,decimal-leading-zero);color:#a4410c;font-weight:750;font-size:24px;} .steps h3{margin:0 0 10px;} .steps p{margin:8px 0;max-width:800px;} .sample {background:#fff;padding:24px;border-radius:16px;border:1px solid #ece9e1;max-width:850px;} .sample p {user-select:text;} .sample-links {display:flex;flex-wrap:wrap;gap:16px;} .sample-links a{display:inline-flex;align-items:center;min-height:44px;} .guide-nav {margin:30px 0;display:flex;gap:24px;flex-wrap:wrap;} .faq {max-width:900px;} @media(max-width:600px){.guide-hero{padding-top:28px;} .steps>li{gap:12px;grid-template-columns:34px 1fr;} .sample{padding:18px;}}
'''
parts=[]
for code,item in samples.items():
 parts.append(f'''<section class="section" id="sample-{code}"><p class="eyebrow">Original fictional sample · {('English' if code=='en' else '简体中文')}</p><h2 lang="{code}">{escape(item['title'])}</h2><div class="sample" lang="{code}">{''.join('<p>'+escape(p)+'</p>' for p in item['paragraphs'])}</div><div class="sample-links"><a href="samples/castreader-demo-{code}.epub" download>Download {('English' if code=='en' else 'Chinese')} EPUB</a><a href="samples/castreader-demo-{code}.txt" download>Download {('English' if code=='en' else 'Chinese')} TXT</a></div></section>''')
body='''<a class="skip-link" href="#main">Skip to content</a><nav aria-label="Main navigation"><a class="brand" href="/"><img src="assets/castreader-app-icon.png" width="42" height="42" alt=""><span>CastReader</span></a><div class="navlinks"><a href="/">Media kit</a><a href="#try">Trial steps</a><a href="#samples">Samples</a></div></nav><main id="main"><section class="guide-hero"><p class="eyebrow">For editors · iPhone + iPad · 1.2.48</p><h1>One passage.<br><span>Listen. Understand.</span></h1><p class="intro">Try Read Aloud and AI Explain with a short, original passage. Keep the same source in view as you hear the words and explore their meaning.</p><div class="buttons"><a class="button" href="https://apps.apple.com/app/id6757636395">Open in the App Store ↗</a><a class="button alt" href="castreader-editor-trial.zip" download>Download trial pack ↓</a></div><p class="small">Suggested three-minute trial after installation. Setup, sign-in and generation can take additional time.</p></section><aside class="notice"><strong>Before you start</strong><p>Use the public App Store release and an internet connection. Follow any in-app sign-in prompts. Free daily usage is available, subject to limits. Prices and optional Pro terms remain visible in the app.</p></aside><section class="section" id="try"><p class="eyebrow">Suggested trial</p><h2>Hear it. Follow it. Explain it.</h2><ol class="steps"><li><div><h3>Bring a short passage <span class="small">≈ 30 sec</span></h3><p>On the home screen, use the text entry to paste a sample below. Or save the EPUB to Files and use the file import entry. TXT is also available as a fallback.</p></div></li><li><div><h3>Listen and follow <span class="small">≈ 60 sec</span></h3><p>Start <strong>Read Aloud</strong>. Follow the spoken word as it is highlighted, with scrolling as needed. Pause, move to a different paragraph and resume.</p><p class="small">Look for: speech and your place in the text staying together.</p></div></li><li><div><h3>Hear an explanation <span class="small">≈ 60 sec</span></h3><p>Switch to <strong>AI Explain</strong>. Hear an explanation as marks appear on the original passage. In this sample, look for the two choices, the evidence collected and the final decision.</p><p class="small">The explanation and marks are generated and may vary. Check the interpretation against the original text.</p></div></li><li><div><h3>Compare on iPad <span class="small">Optional · ≈ 30 sec</span></h3><p>Open the same sample in landscape and compare how much source text stays visible. <a href="/#screenshots">See the current iPad screenshots</a>.</p></div></li></ol></section><section class="section" id="samples"><p class="eyebrow">Ready to paste or import</p><h2>Start with a small, complete story.</h2><p>A library team has one budget and two competing needs. This fictional passage makes it easy to compare listening to the source with hearing an explanation of its reasoning.</p><div class="guide-nav"><a href="#sample-en">English sample</a><a href="#sample-zh-Hans">中文样例</a><a href="review-guide.txt" download>Plain-text guide ↓</a></div></section>'''+''.join(parts)+'''<section class="section faq"><p class="eyebrow">Useful details</p><h2>Other ways to explore.</h2><details><summary>Try a photo or a Safari page</summary><p>For photo OCR, photograph a clearly printed sample and open the recognized text. Recognition runs on-device; speech and explanations still use online services.</p><p>For Safari, enable the CastReader extension in Safari settings, grant access to the page you want to read and try it on this sample page. Settings differ by OS version. Pasted text is the shortest route for the first trial.</p></details><details><summary>What is free, and what needs a connection?</summary><p>Free daily usage is available. If your daily allowance is already exhausted, resume after it resets or use an existing Pro entitlement. The public media kit can be viewed without subscribing. Speech generation and AI Explain need an internet connection. This is not an offline speech engine.</p></details><details><summary>What should the AI explanation demonstrate?</summary><p>It explains the passage rather than reading the original verbatim. In this sample, it can connect the limited budget, daily watering work and later bench repair to the final choice. Exact wording and mark placement are not fixed.</p></details><details><summary>Which materials show the current release?</summary><p>The eight screenshots in the media kit are current 1.2.48 App Store assets. The approved 29.8-second preview was recorded for an earlier release and remains in the listing. The sample passages were newly prepared for this editorial trial. Use the suggested steps above to explore the public release with your own device and settings.</p></details><details><summary>Product and accessibility scope</summary><p>CastReader is a reading tool for the reader’s own material. It does not supply a book catalog. The 1.2.48 interface and reading experience support 28 languages; voice and feature availability vary. We make no clinical claims or unverified claims of system accessibility support.</p></details></section><section class="download"><div><p class="eyebrow">Editorial materials</p><h2>Keep exploring.</h2><p class="small">Original English and Chinese TXT + EPUB samples, a trial guide and a pack README. No account credentials or private documents are included.</p></div><div class="buttons"><a class="button" href="castreader-editor-trial.zip" download>Download trial pack ↓</a><a class="button alt" href="/">Screenshots, icon &amp; preview →</a></div></section></main><footer>CastReader · Updated 11 October 2026<br><a href="mailto:support@castreader.ai">support@castreader.ai</a> · <a href="/">Editorial media kit</a></footer>'''
(W/'review-guide.html').write_text(f'''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex,nofollow"><title>CastReader — Editor Trial Guide</title><meta name="description" content="Try Read Aloud and AI Explain with original English and Chinese sample passages. Download TXT and EPUB files for iPhone and iPad."><link rel="icon" href="assets/castreader-app-icon.png"><style>{css}</style></head><body>{body}</body></html>''')
readme='''CASTREADER EDITOR TRIAL PACK — 2026-10-11

Contents: two original fictional sample passages, each in TXT and EPUB; a plain-text trial guide; this README.
The samples are newly prepared demo material, not excerpts from a third-party book or an included catalog. EPUB and TXT contain the same story in each language.
The guide is a proposed editorial trial, not a current-device QA certificate. No credentials, private customer data or software installers are included.
Current screenshots, original app icon and approved video: https://press.castreader.com/
Contact: support@castreader.ai
'''
with zipfile.ZipFile(W/'castreader-editor-trial.zip','w',zipfile.ZIP_DEFLATED) as z:
 for path in sorted(S.iterdir()): z.write(path,'samples/'+path.name)
 z.write(W/'review-guide.txt','review-guide.txt');z.writestr('README.txt',readme)
manifest={str(x.relative_to(W)):{'bytes':x.stat().st_size,'sha256':hashlib.sha256(x.read_bytes()).hexdigest()} for x in [W/'review-guide.html',W/'review-guide.txt',W/'castreader-editor-trial.zip',*sorted(S.iterdir())]}
(P/'trial-manifest.json').write_text(json.dumps(manifest,indent=2))
print('Built editor guide, 2 original samples in TXT + EPUB, and 6-file trial pack.')
