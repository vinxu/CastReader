from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urljoin, urlparse
from concurrent.futures import ThreadPoolExecutor
import hashlib, json, sys, urllib.request, zipfile, io

OUT = Path(__file__).resolve().parent
SITE = OUT.parent / 'press-site'
BASE = sys.argv[1] if len(sys.argv) > 1 else 'http://127.0.0.1:8767/'

class Page(HTMLParser):
    def __init__(self):
        super().__init__(); self.refs = set(); self.ids = []; self.images = []; self.anchors = []; self.stack = []; self.errors = []
    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if 'id' in a: self.ids.append(a['id'])
        for attr in ['href', 'src', 'poster']:
            if a.get(attr): self.refs.add(a[attr])
        if tag == 'img': self.images.append(a)
        if tag == 'a': self.anchors.append(a)
        if tag not in {'area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'}: self.stack.append(tag)
    def handle_endtag(self, tag):
        if not self.stack or self.stack[-1] != tag: self.errors.append('Unbalanced '+tag)
        else: self.stack.pop()

p = Page(); text = (SITE/'index.html').read_text(); p.feed(text)
assert not p.errors and not p.stack, (p.errors,p.stack)
assert len(p.ids) == len(set(p.ids))
assert all(r[1:] in p.ids for r in p.refs if r.startswith('#'))
assert all('alt' in i and i.get('width') and i.get('height') for i in p.images)
assert '≋' not in text and 'from nine' not in text
assert 'device-frame' in text and 'Recorded for an earlier release' in text
assert '.env*' in (SITE/'.vercelignore').read_text()
local = sorted(r for r in p.refs if not urlparse(r).scheme and not r.startswith('#'))

def read_resource(relative):
    url = urljoin(BASE, relative)
    with urllib.request.urlopen(urllib.request.Request(url, method='HEAD'), timeout=45) as r:
        assert r.status == 200
        assert r.url == url, (url,r.url)
        return {'resource':relative,'status':r.status,'bytes':r.headers.get('Content-Length'),'type':r.headers.get('Content-Type')}
checks = list(ThreadPoolExecutor(max_workers=5).map(read_resource, local))
with urllib.request.urlopen(BASE, timeout=45) as r: deployed = r.read()
assert deployed == (SITE/'index.html').read_bytes()
with urllib.request.urlopen(urljoin(BASE,'assets/castreader-app-icon.png'), timeout=45) as r: icon = r.read()
assert icon == (SITE/'assets/castreader-app-icon.png').read_bytes()
with urllib.request.urlopen(urljoin(BASE,'castreader-screenshots.zip'),timeout=45) as r: packed = r.read()
assert packed == (SITE/'castreader-screenshots.zip').read_bytes()
with zipfile.ZipFile(io.BytesIO(packed)) as z:
    assert z.testzip() is None
    assert len(z.namelist()) == 10
    assert z.read('castreader-app-icon.png') == icon
    assert z.read('editorial-brief.txt') == (SITE/'editorial-brief.txt').read_bytes()
    members = z.namelist()
    for n in members:
        if n.endswith('.png'): assert z.read(n) == (SITE/'assets'/n).read_bytes()
result = {'base':BASE,'htmlStructure':'passed','anchors':'passed','imageDimensionsAndAlt':'passed','logoMatchesSource':True,'pageMatchesSource':True,'zipIntegrity':'passed','zipMembers':members,'localResources':checks,'pageSha256':hashlib.sha256(deployed).hexdigest()}
name = 'production-check.json' if BASE.startswith('https://') else 'local-check.json'
(OUT/name).write_text(json.dumps(result,indent=2))
print(json.dumps({'base':BASE,'localResources':len(checks),'zipMembers':len(members),'allChecks':'passed'},indent=2))
