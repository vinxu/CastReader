from pathlib import Path
import json,zipfile,html
P=Path(__file__).resolve().parent;W=P/'press-site'
files=json.load(open(P/'asset-provenance.json'))
labels={'en-US-iphone-2.png':'Read Aloud · iPhone','en-US-iphone-3.png':'AI Explain · iPhone','en-US-iphone-5.png':'Bring your own material · iPhone','en-US-ipad-2.png':'Read Aloud · iPad','en-US-ipad-3.png':'AI Explain · iPad','ja-iphone-2.png':'Japanese UI · Read Aloud','de-DE-iphone-2.png':'German UI · Read Aloud','zh-Hans-iphone-3.png':'Simplified Chinese UI · AI Explain'}
DOWNLOAD='<svg aria-hidden="true" focusable="false" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 3v12m-5-5 5 5 5-5M5 16v5h14v-5"/></svg>'
EXTERNAL='<svg aria-hidden="true" focusable="false" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M7 17 17 7M7 7h10v10"/></svg>'
def figure(name):
 row=next(r for r in files if r['file']=='assets/'+name)
 label=labels[name]
 return f'<figure><a href="assets/{name}" aria-label="Open full-size {label} screenshot"><img loading="lazy" decoding="async" width="{row["width"]}" height="{row["height"]}" src="assets/{name}" alt="{label}: {alts[name]}"></a><figcaption><strong>{label}</strong><a href="assets/{name}" download aria-label="Download {label} PNG">Download PNG <span class="download-icon">{DOWNLOAD}</span></a></figcaption></figure>'
alts={
 'en-US-iphone-2.png':'an EPUB passage with the spoken word highlighted',
 'en-US-iphone-3.png':'an explanation playing while the source passage is underlined',
 'en-US-iphone-5.png':'import a URL, file, photo, image or pasted text',
 'en-US-ipad-2.png':'landscape reading layout with the current word highlighted',
 'en-US-ipad-3.png':'landscape explanation view with marks on the original passage',
 'ja-iphone-2.png':'Japanese interface labels with an English passage and word highlighting',
 'de-DE-iphone-2.png':'German interface labels with an English passage and word highlighting',
 'zh-Hans-iphone-3.png':'Chinese interface labels with an English passage and explanation marks',
}
phones=''.join(figure(n) for n in ['en-US-iphone-2.png','en-US-iphone-3.png','en-US-iphone-5.png'])
ipads=''.join(figure(n) for n in ['en-US-ipad-2.png','en-US-ipad-3.png'])
langs=''.join(figure(n) for n in ['ja-iphone-2.png','de-DE-iphone-2.png','zh-Hans-iphone-3.png'])
brief='''CastReader — October 2026 editorial brief
Updated 11 October 2026 · iOS 1.2.48

Follow the words. Hear the meaning.
CastReader is a text-to-speech reading tool for people's own material. Read Aloud combines speech, synchronized word highlighting and automatic scrolling. AI Explain speaks an explanation while marks appear on the original text.

What's new
Version 1.2.48 supports 28 interface and reading languages, with language-aware voice selection on iPhone and iPad. Voice and feature availability vary by language and region. The app supports iPhone and iPad layouts; its Safari extension reads web pages with highlighting and scrolling.

Why this story
Our October editorial story connects sound, visible words and explanations. This experience is designed for readers who prefer visual and audio guidance while working through their own articles, documents and ebooks. We welcome consideration for reading, learning and productivity collections.

Content and privacy
Readers can bring PDFs, EPUBs, DOCX, TXT, photos or pasted text. Photo text recognition uses on-device OCR. Speech generation and AI explanations use online services. CastReader is a reading tool, not a supplied-book subscription or an offline speech engine.

Business model
Free daily usage; optional Pro subscription. Cloned voices have a separate allowance. Current pricing and terms are shown in the app and App Store.

Media
The 29.8-second video is the exact approved preview retained in the current App Store listing. It was recorded for an earlier release and is not new 1.2.48 footage. The screenshots in this kit are exported from the current 1.2.48 App Store assets. English, Japanese, German and Simplified Chinese interface examples are included; the source passage remains in English. Storefront localization count and in-app language count are different.

Editor trial: https://press.castreader.com/review-guide.html
Original English and Chinese sample passages are available as TXT and EPUB, with a suggested three-minute Read Aloud and AI Explain walkthrough.

Brand assets: Official CastReader app icon included as a 1024-pixel PNG.
Contact: support@castreader.ai
Website: https://castreader.com/castreader-app
App Store: https://apps.apple.com/app/id6757636395
'''
(W/'editorial-brief.txt').write_text(brief)
with zipfile.ZipFile(W/'castreader-screenshots.zip','w',zipfile.ZIP_DEFLATED) as z:
 for row in files:
  if row['file'].endswith('.png'):z.write(W/row['file'],Path(row['file']).name)
 z.write(W/'assets/castreader-app-icon.png','castreader-app-icon.png')
 z.writestr('editorial-brief.txt',brief)
css=(P/'site.css').read_text()
body=f'''<a class="skip-link" href="#main">Skip to content</a><nav aria-label="Main navigation"><a class="brand" href="https://castreader.com"><img src="assets/castreader-app-icon.png" width="42" height="42" alt=""><span>CastReader</span></a><div class="navlinks"><a href="review-guide.html">Try it</a><a href="#screenshots">Screenshots</a><a href="#downloads">Downloads</a></div></nav>
<main id="main"><section class="hero"><div><p class="eyebrow">October 2026 · Editorial materials</p><h1>Follow the words.<br><span>Hear the meaning.</span></h1><p class="intro">A reading tool that keeps speech, visible words and explanations on the same page.</p><p>Bring your own article, document or ebook. Listen with synchronized highlights, then hear an explanation as notes appear on the original text.</p><div class="buttons"><a class="button" href="https://apps.apple.com/app/id6757636395">View on the App Store {EXTERNAL}</a><a class="button alt" href="review-guide.html">Editor trial guide {EXTERNAL}</a></div><p class="small">Current iOS release: 1.2.48 · Updated 11 October 2026</p></div><div class="preview"><div class="device-frame"><video controls playsinline preload="metadata" poster="assets/preview-poster.jpg" aria-label="CastReader demo: word highlighting and AI Explain" aria-describedby="preview-note"><source src="assets/castreader-web-preview.mp4" type="video/mp4">Your browser does not support embedded video. <a href="assets/castreader-approved-preview.mp4">Download the preview.</a></video></div><p><b>See Read Aloud and AI Explain</b><br><span class="small" id="preview-note">29.8-second App Store preview.<br>Recorded for an earlier release; retained in the 1.2.48 listing.</span></p></div></section>
<div class="facts"><div><strong>28</strong><span>Interface &amp; reading languages</span></div><div><strong>iPhone + iPad</strong><span>Layouts for both devices</span></div><div><strong>Your material</strong><span>Documents, webpages &amp; ebooks</span></div></div>
<section class="section"><p class="eyebrow">Try the experience</p><h2>One passage. Two ways to follow it.</h2><p>Start with an original English or Chinese sample. Listen with Read Aloud, then hear an explanation while keeping the same text in view. The guide includes TXT and EPUB downloads and a short suggested trial.</p><div class="buttons"><a class="button" href="review-guide.html">Open the editor trial guide {EXTERNAL}</a><a class="button alt" href="castreader-editor-trial.zip" download>Sample pack {DOWNLOAD}</a></div></section><section class="section" id="experience"><p class="eyebrow">The editorial angle</p><h2>Sound, text and understanding stay together.</h2><p>Our October story is about following your own material with visual and audio guidance. It brings together three moments that are usually separate: hearing the text, finding your place and understanding a difficult passage.</p><div class="cards"><article><span class="num">01 / FOLLOW</span><h3>Hear a word. See where you are.</h3><p>Read Aloud pairs speech with word-level highlighting and automatic scrolling. The text remains the center of the experience.</p></article><article><span class="num">02 / UNDERSTAND</span><h3>Keep explanations beside the source.</h3><p>AI Explain speaks an explanation while highlights, circles and numbered steps appear on the original text.</p></article><article><span class="num">03 / BRING YOUR OWN</span><h3>Start with what you need to read.</h3><p>Open PDFs, EPUBs, DOCX, TXT, photos or pasted text. Read webpages with highlighting through the Safari extension.</p></article></div>
<details><summary>Demo contents and recording version</summary><ol class="transcript"><li><strong>Read Aloud:</strong> the spoken word is highlighted within the passage.</li><li><strong>Voice selection:</strong> the reader opens the voice list.</li><li><strong>AI Explain:</strong> a spoken explanation accompanies animated marks on the original passage.</li></ol><p>This is a web-optimized copy of the approved preview retained in the current listing, originally recorded for an earlier release. The original MP4 is available in Downloads. It is not newly recorded 1.2.48 footage. The screenshots below are the current 1.2.48 store assets.</p></details></section>
<section class="section"><p class="eyebrow">What changed in 1.2.48</p><h2>The same reading experience, in more languages.</h2><p>The interface and reading experience support 28 languages. Voice lists follow the app language, and playback voice selection follows the language being read. The update also improves localized labels and the cloned-voice balance display on iPhone and iPad.</p><p class="language-list">English · Chinese · Japanese · Spanish · French · German · Brazilian Portuguese · Italian · Hindi · Dutch · Korean · Arabic · Russian · Polish · Swedish · Danish · Norwegian · Finnish · Czech · Greek · Hungarian · Filipino · Hebrew · Indonesian · Malay · Romanian · Turkish · Vietnamese</p><p class="small">Available voices, voice cloning and other features vary by language and region. Product language count differs from storefront localization count.</p></section>
<section class="section" id="screenshots"><p class="eyebrow">Current App Store assets</p><h2>iPhone: listen, explain, import.</h2><p>English screenshots from the approved 1.2.48 listing. Open each image to inspect it at full resolution.</p><div class="gallery">{phones}</div><h2>iPad: room to follow the original.</h2><div class="gallery ipad">{ipads}</div><h2>Localized interface examples.</h2><p>The Japanese, German and Chinese examples show localized controls while reading the same English source passage.</p><div class="gallery">{langs}</div></section>
<section class="section"><h2>Product facts for editors.</h2><div class="cards"><article><h3>Reading tool</h3><p>CastReader works with the reader’s own material. It is not a supplied-book subscription.</p></article><article><h3>On-device photo OCR</h3><p>Photo text recognition runs on-device. Speech generation and AI explanations use online services.</p></article><article><h3>Free daily usage + Pro</h3><p>Optional Pro subscription; cloned voices have a separate allowance. Current prices and renewal terms appear in the app and App Store.</p></article></div></section>
<section class="download" id="downloads"><div><p class="eyebrow">Ready to explore</p><h2>Download the materials.</h2><p class="small">No sign-in required. The pack includes 8 screenshots, the official app icon and an editorial brief. <a href="mailto:support@castreader.ai">Contact CastReader</a>.</p></div><div class="buttons"><a class="button" href="castreader-screenshots.zip" download>Screenshots + icon {DOWNLOAD}</a><a class="button alt" href="editorial-brief.txt" download>Editorial brief {DOWNLOAD}</a><a class="button alt" href="assets/castreader-app-icon.png" download>App icon PNG {DOWNLOAD}</a><a class="button alt" href="assets/castreader-approved-preview.mp4" download>Original preview MP4 {DOWNLOAD}</a><a class="button alt" href="https://castreader.com/castreader-app">Official website {EXTERNAL}</a></div></section></main><footer>CastReader · Editorial materials · October 2026<br><a href="mailto:support@castreader.ai">support@castreader.ai</a> · <a href="https://castreader.com/castreader-app">Product information</a></footer>'''
(W/'index.html').write_text(f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="robots" content="noindex,nofollow"><meta name="description" content="CastReader October 2026 editorial materials: synchronized reading, AI explanations, iPhone and iPad screenshots, and 28-language update."><title>CastReader — October Editorial Materials</title><link rel="icon" type="image/png" href="assets/castreader-app-icon.png"><link rel="apple-touch-icon" href="assets/castreader-app-icon.png"><meta property="og:title" content="CastReader — October Editorial Materials"><meta property="og:description" content="Read Aloud and AI Explain. Official screenshots, demo and brand assets."><meta property="og:image" content="https://press.castreader.com/assets/castreader-app-icon.png"><meta property="og:image:alt" content="CastReader app icon: seven light waveform bars on orange"><meta property="og:type" content="website"><meta property="og:url" content="https://press.castreader.com/"><style>{css}</style></head><body>{body}</body></html>')
(W/'robots.txt').write_text('User-agent: *\nDisallow: /\n')
(W/'vercel.json').write_text(json.dumps({'framework':None,'buildCommand':None,'outputDirectory':'.'},indent=2))
(W/'.vercelignore').write_text('.DS_Store\n.env*\n.git*\n.vercel\n')
print('Prepared public press site, eight current screenshots, approved preview and screenshot download pack.')
