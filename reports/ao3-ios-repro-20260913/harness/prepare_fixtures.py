"""Create network-free AO3 DOM states from the three public chapter responses.

The blocked state reproduces showTOSPrompt's DOM changes. The unobstructed
state is a local comparison only: no consent, cookie or website action occurs.
"""
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from urllib.request import Request, urlopen
import json, re, hashlib

ROOT = Path(__file__).parent
PAGES = {
    '228985126': ('86539701', ROOT.parent / 'raw/228985126.html'),
    '231697481': ('86539701', ROOT.parent / 'raw/231697481.html'),
    '227434811': ('85592371', ROOT.parent / 'raw/227434811.html'),
}
CSS = [
    ('/stylesheets/skins/skin_1_default/1_site_screen_.css', 'screen'),
    ('/stylesheets/skins/skin_1_default/4_site_midsize.handheld_.css', 'only screen and (max-width: 62em), handheld'),
    ('/stylesheets/skins/skin_1_default/5_site_narrow.handheld_.css', 'only screen and (max-width: 42em), handheld'),
    ('/stylesheets/sandbox.css', 'all'),
]
def fetch_css(item):
    path, media = item
    target = ROOT / path.rsplit('/', 1)[1]
    if not target.exists():
        req = Request('https://archiveofourown.org' + path, headers={'User-Agent': 'Mozilla/5.0'})
        target.write_bytes(urlopen(req, timeout=35).read())
    text = re.sub(r'url\([^)]*\)', 'none', target.read_text())
    return '<style media="' + media + '">' + text + '</style>'
with ThreadPoolExecutor(max_workers=4) as pool:
    styles = '\n'.join(pool.map(fetch_css, CSS))
manifest = []
for chapter, (work, source) in PAGES.items():
    html = Path(source).read_text()
    raw = re.search(r'\$j\("body"\)\.prepend\(("(?:\\.|[^"\\])*")\)', html).group(1)
    prompt = json.loads(raw.replace('\\$', '$'))
    prompt = re.sub(r'<script\b[^>]*>.*?</script>', '', prompt, flags=re.S | re.I)
    prompt = prompt.replace('id="tos_prompt" class="hidden"', 'id="tos_prompt" style="display:block;opacity:1"')
    local = re.sub(r'<script\b[^>]*>.*?</script>', '', html, flags=re.S | re.I)
    local = re.sub(r'<!--.*?-->', '', local, flags=re.S)
    local = re.sub(r'<link\b[^>]*>', '', local, flags=re.I)
    local = re.sub(r'<noscript\b[^>]*>.*?</noscript>', '', local, flags=re.S | re.I)
    local = re.sub(r'<img\b[^>]*>', '', local, flags=re.I)
    local = local.replace('</head>', styles + '</head>')
    (ROOT / (chapter + '-clear.html')).write_text(local)
    blocked = re.sub(r'(<body\b[^>]*>)', r'\1' + prompt.replace('\\', '\\\\'), local, count=1)
    blocked = blocked.replace('id="outer"', 'id="outer" style="visibility:hidden" aria-hidden="true"', 1)
    blocked = blocked.replace('</head>', '<style>body{overflow:hidden}</style></head>')
    (ROOT / (chapter + '-blocked.html')).write_text(blocked)
    manifest.append({'chapter':chapter, 'url':f'https://archiveofourown.org/works/{work}/chapters/{chapter}',
                     'responseBytes':Path(source).stat().st_size,
                     'responseSHA256':hashlib.sha256(Path(source).read_bytes()).hexdigest()})
(ROOT / 'source-manifest.json').write_text(json.dumps(manifest, indent=2))
print(json.dumps(manifest, indent=2))
