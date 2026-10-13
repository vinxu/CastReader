from pathlib import Path
import urllib.request,urllib.error,concurrent.futures,json,hashlib
P=Path(__file__).resolve().parent
base='https://press.castreader.com'
paths=['/','/editorial-brief.txt','/castreader-screenshots.zip','/assets/castreader-approved-preview.mp4','/assets/castreader-web-preview.mp4','/assets/preview-poster.jpg']+[r['file'].join(['/','']) for r in json.load(open(P/'asset-provenance.json')) if r['file'].endswith('.png')]+['/.env.local','/.vercel/project.json']
def check(path):
 try:
  with urllib.request.urlopen(urllib.request.Request(base+path,method='HEAD'),timeout=30) as r:
   return {'path':path,'status':r.status,'finalUrl':r.url,'contentType':r.headers.get('Content-Type'),'bytes':r.headers.get('Content-Length')}
 except urllib.error.HTTPError as e:return {'path':path,'status':e.code,'finalUrl':e.url}
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as ex:rows=list(ex.map(check,paths))
for row in rows:
 path=row['path']
 if path.startswith('/.'):assert row['status']==404,row
 else:
  assert row['status']==200 and row['finalUrl'].startswith(base),row
  expected='text/html' if path=='/' else ('video/mp4' if path.endswith('.mp4') else ('image/png' if path.endswith('.png') else ('image/jpeg' if path.endswith('.jpg') else ('text/plain' if path.endswith('.txt') else 'application/zip'))))
  assert expected in row.get('contentType',''),row
with urllib.request.urlopen(base,timeout=30) as r: html=r.read()
assert html==(P/'press-site/index.html').read_bytes()
with urllib.request.urlopen(urllib.request.Request(base+'/assets/castreader-approved-preview.mp4',headers={'Range':'bytes=0-1023'}),timeout=30) as r:
 first=r.read(1024);assert b'ftyp' in first[:64];video={'status':r.status,'contentRange':r.headers.get('Content-Range'),'signature':'ftyp present'}
result={'baseUrl':base,'pageSha256':hashlib.sha256(html).hexdigest(),'pageMatchesLocal':True,'videoRange':video,'checks':rows}
(P/'public-verification.json').write_text(json.dumps(result,indent=2))
print(json.dumps({'baseUrl':base,'pageMatchesLocal':True,'checkedResources':len(rows),'videoRange':video,'privateFilePaths':'404'},indent=2))
