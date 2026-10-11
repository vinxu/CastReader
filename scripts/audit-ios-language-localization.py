#!/usr/bin/env python3
"""Audit actual target string catalogs; missing/draft translations fail --release."""
import argparse
import collections
import hashlib
import json
import re
from pathlib import Path

root = Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('--release', action='store_true')
p.add_argument('--output', type=Path, default=root / 'reports/ios-28-languages-20261008/localization-current.json')
a = p.parse_args()
registry = json.loads((root / 'config/ios-language-capabilities.json').read_text())
locales = [dict(zh='zh-Hans', pt='pt-BR').get(x['code'], x['code']) for x in registry['languages']]
# Positional reordering is legal; only placeholder kinds and multiplicities must match.
placeholder = re.compile(r'(?<!%)%(?!%)(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:ll|l|h|hh|z|t|j|L)?[@diuoxXfFeEgGaAcCsSpn]|\$\{[^}]+\}')
def tokens(text):
    return collections.Counter(re.sub(r'^%\d+\$', '%', token) for token in placeholder.findall(text))
def units(value, path=''):
    if isinstance(value, dict):
        if 'stringUnit' in value:
            yield path, value['stringUnit']
        for key in ('variations', 'substitutions', 'plural', 'device'):
            if key in value:
                for label, item in value[key].items():
                    yield from units(item, path + '/' + key + '/' + label)
report = {'policy': registry['version'], 'releaseQualified': False, 'catalogs': {}}
problems = 0
for path in sorted(root.glob('**/*.xcstrings')):
    if any(part in ('build', '.build', 'DerivedData') for part in path.parts): continue
    catalog = json.loads(path.read_text())
    summary = {'sha256': hashlib.sha256(path.read_bytes()).hexdigest(), 'keys': len(catalog['strings']), 'locales': {}}
    for locale in locales:
        missing=[]; review=[]; invalid=[]
        for key, entry in catalog['strings'].items():
            # Xcode extracts Text("") as the empty source key. It renders no
            # copy in any language and needs no invented visible translation.
            if key == '': continue
            localized=entry.get('localizations', {}).get(locale)
            if localized is None:
                missing.append(key);continue
            found=list(units(localized))
            if not found or any(not unit.get('value', '').strip() for _,unit in found):
                missing.append(key);continue
            if any(unit.get('state') != 'translated' for _,unit in found):review.append(key)
            source=entry.get('localizations', {}).get('en', {}).get('stringUnit', {}).get('value')
            if source is not None:
                for branch,unit in found:
                    if tokens(unit['value']) != tokens(source): invalid.append({'key':key,'branch':branch})
        summary['locales'][locale]={'missing':missing,'needsReview':review,'placeholderMismatches':invalid}
        problems += len(missing)+len(review)+len(invalid)
    report['catalogs'][str(path.relative_to(root))]=summary
report['releaseQualified']=problems == 0
report['openFindings']=problems
a.output.parent.mkdir(parents=True,exist_ok=True)
a.output.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'catalogs':len(report['catalogs']),'locales':len(locales),'openFindings':problems,'releaseQualified':report['releaseQualified']}))
if a.release and problems:raise SystemExit(1)
