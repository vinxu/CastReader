import concurrent.futures, json, re, html
from urllib.request import urlopen
from pathlib import Path
locales='en-us zh-cn zh-tw ja-jp es-es es-mx fr-fr de-de pt-br it-it hi-in nl-nl ko-kr ar-sa ru-ru pl-pl sv-se da-dk no-no fi-fi cs-cz el-gr hu-hu he-il id-id ms-my ro-ro tr-tr vi-vn'.split()
def fetch(locale):
 url=f'https://support.apple.com/{locale}/guide/iphone/iph96b214f0/ios'
 try:
  with urlopen(url,timeout=35) as response:
   final=response.url; raw=response.read().decode()
  fragment=raw[raw.find('<h1>'):]
  fragment=re.split(r'<(?:footer|nav)',fragment)[0]
  text=html.unescape(re.sub('<[^>]+>',' ',fragment))
  text=re.sub(r'\s+',' ',text).strip()
  return dict(locale=locale,url=url,resolvedURL=final,title=text[:text.find(' ',160)] if len(text)>160 else text,excerpt=text[:1800],error=None)
 except Exception as e:return dict(locale=locale,url=url,error=str(e))
with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool: results=list(pool.map(fetch,locales))
Path('reports/aso-28-languages-20261011/terminology-sources.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
for x in results: print(x['locale'],x.get('error') or x['excerpt'][:430])
