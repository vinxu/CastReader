from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urljoin,urlparse
from xml.etree import ElementTree as ET
import json,urllib.request,zipfile,io,sys,hashlib
P=Path(__file__).resolve().parent;W=P.parent/'october-featuring-20261011/press-site'
base=sys.argv[1] if len(sys.argv)>1 else 'http://127.0.0.1:8767/'
class Page(HTMLParser):
 def __init__(self):super().__init__();self.refs=set();self.ids=[];self.stack=[]
 def handle_starttag(self,t,attrs):
  a=dict(attrs)
  if 'id' in a:self.ids.append(a['id'])
  for k in ['href','src','poster']:
   if a.get(k):self.refs.add(a[k])
  if t=='img':assert all(k in a for k in ['width','height','alt'])
  if t not in {'area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'}:self.stack.append(t)
 def handle_endtag(self,t):assert self.stack.pop()==t
p=Page();p.feed((W/'review-guide.html').read_text());assert not p.stack
assert len(p.ids)==len(set(p.ids))
assert all(r[1:] in p.ids for r in p.refs if r.startswith('#'))
resources={'review-guide.html','review-guide.txt','castreader-editor-trial.zip'}
resources.update(r for r in p.refs if not urlparse(r).scheme and not r.startswith(('#','/')))
for r in sorted(resources):
 with urllib.request.urlopen(urljoin(base,r),timeout=35) as f:b=f.read();assert f.status==200
 assert b==(W/r).read_bytes(),r
for fp in (W/'samples').glob('*.epub'):
 with zipfile.ZipFile(fp) as z:
  assert z.testzip() is None
  assert z.infolist()[0].filename=='mimetype' and z.infolist()[0].compress_type==0
  assert z.read('mimetype')==b'application/epub+zip'
  for n in z.namelist():
   if n.endswith(('.xml','.xhtml','.opf')):ET.fromstring(z.read(n))
  chapter=ET.fromstring(z.read('EPUB/chapter.xhtml'))
  ns={'x':'http://www.w3.org/1999/xhtml'}
  txt=chapter.find('.//x:h1',ns).text+'\n\n'+'\n\n'.join(x.text for x in chapter.findall('.//x:p',ns))+'\n'
  assert txt==fp.with_suffix('.txt').read_text()
with zipfile.ZipFile(W/'castreader-editor-trial.zip') as z:
 assert len(z.namelist())==6 and z.testzip() is None
 for n in z.namelist():
  if n!='README.txt':assert z.read(n)==(W/n).read_bytes()
r={'base':base,'verifiedResources':sorted(resources),'guideStructure':'passed','sampleXMLAndReferences':'passed','epubTextMatchesTXT':True,'trialZIPMembers':6,'scope':'Web assets and EPUB container/content structure; not a current iOS app runtime test.'}
(P/('trial-production-check.json' if base.startswith('https:') else 'trial-local-check.json')).write_text(json.dumps(r,indent=2))
print(json.dumps(r))
