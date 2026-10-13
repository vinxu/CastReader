from pathlib import Path
import json, urllib.request, hashlib, shutil, concurrent.futures
P=Path(__file__).resolve().parent
src=P.parent/'custom-product-pages-20261011'
base=json.load(open(src/'baseline-screenshots.json'))
locs={v['attributes']['locale']:v for v in json.load(open(src/'live-localizations.json'))['data']}
jobs=[('en-US','iphone',2),('en-US','iphone',3),('en-US','iphone',5),('en-US','ipad',2),('en-US','ipad',3),('ja','iphone',2),('de-DE','iphone',2),('zh-Hans','iphone',3)]
def get(job):
 locale,device,index=job
 sets=[base[x['id']] for x in locs[locale]['relationships']['appScreenshotSets']['data']]
 group=next(s for s in sets if ('IPHONE' if device=='iphone' else 'IPAD') in s['set']['attributes']['screenshotDisplayType'])
 shot=group['screenshots'][index-1];attr=shot['attributes'];im=attr['imageAsset']
 url=im['templateUrl'].replace('{w}',str(im['width'])).replace('{h}',str(im['height'])).replace('{f}','png')
 name=f'{locale}-{device}-{index}.png';out=P/'press-site/assets'/name
 if not out.exists():
  with urllib.request.urlopen(url,timeout=45) as r:out.write_bytes(r.read())
 return {'file':f'assets/{name}','locale':locale,'device':device,'scene':index,'ascScreenshotId':shot['id'],'approvedListingVersion':'1.2.48','sourceUrl':url,'sourceFileName':attr['fileName'],'sourceChecksum':attr['sourceFileChecksum'],'downloadSha256':hashlib.sha256(out.read_bytes()).hexdigest(),'bytes':out.stat().st_size,'width':im['width'],'height':im['height']}
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:rows=list(ex.map(get,jobs))
v=Path('/Users/xuxuheng/Documents/CastReader/AppStoreAssets/6.9-inch/final-1.2.14/app-preview-public-domain.mp4')
assert hashlib.md5(v.read_bytes()).hexdigest()=='2d5d57d6709ddb5332cfc35bef71f4c6'
shutil.copyfile(v,P/'press-site/assets/castreader-approved-preview.mp4')
rows.append({'file':'assets/castreader-approved-preview.mp4','bytes':v.stat().st_size,'md5':'2d5d57d6709ddb5332cfc35bef71f4c6','duration':29.8,'note':'Exact preview asset retained in the current approved 1.2.48 listing. Originally recorded for an earlier release, not newly recorded 1.2.48 footage.'})
(P/'asset-provenance.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
print(json.dumps([{'file':r['file'],'bytes':r['bytes']} for r in rows],indent=2))
