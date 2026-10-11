#!/usr/bin/env python3
"""Apply reviewed-source terminology drafts without reformatting whole catalogs.

This intentionally does not fabricate coverage for untranslated strings. Read
reports/ios-28-languages-20261008/localization-current.json for remaining work.
"""
import argparse
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument('--check', action='store_true')
args = parser.parse_args()
source = json.loads((ROOT / 'config/ios-core-translations.json').read_text())
terms = source['terms']
assert len(terms) == len(set(terms))
assert all(len(values) == len(terms) for values in source['localizations'].values())
translations = {term: {locale: values[i] for locale, values in source['localizations'].items()}
                for i, term in enumerate(terms)}
decoder = json.JSONDecoder()
changed = 0
for path in sorted(ROOT.glob('**/*.xcstrings')):
    if any(part in ('build', '.build', 'DerivedData') for part in path.parts):
        continue
    raw = path.read_text()
    catalog = json.loads(raw)
    edits = []
    for key, entry in catalog.get('strings', {}).items():
        english = entry.get('localizations', {}).get('en', {}).get('stringUnit', {}).get('value')
        if english not in translations:
            continue
        entry_changed = False
        for locale, value in translations[english].items():
            localized = entry.setdefault('localizations', {})
            if locale in localized:
                continue  # Never overwrite a prior translation or human review.
            localized[locale] = {'stringUnit': {'state': 'needs_review', 'value': value}}
            entry_changed = True
        if not entry_changed:
            continue
        key_pattern = re.escape(json.dumps(key, ensure_ascii=False)) + r'\s*:\s*'
        match = re.search(key_pattern, raw)
        if not match:
            key_pattern = re.escape(json.dumps(key, ensure_ascii=True)) + r'\s*:\s*'
            match = re.search(key_pattern, raw)
        assert match, key
        start = match.end()
        _, consumed = decoder.raw_decode(raw[start:])
        original = raw[start:start + consumed]
        loc = re.search(r'"localizations"\s*:\s*', original)
        assert loc
        existing, size = decoder.raw_decode(original[loc.end():])
        end = loc.end() + size - 1
        insertion = len(original[:end].rstrip())
        whitespace = original[insertion:end]
        indent = (whitespace.rsplit('\n', 1)[-1] + '  ') if '\n' in whitespace else '  '
        additions = {k: v for k, v in entry['localizations'].items() if k not in existing}
        extra = (',\n' if existing else '\n') + ',\n'.join(indent + json.dumps(k) + ': ' + json.dumps(v, ensure_ascii=False) for k, v in additions.items())
        edits.append((start + insertion, start + insertion, extra))
    if edits:
        changed += len(edits)
        if not args.check:
            for start, end, replacement in reversed(sorted(edits)):
                raw = raw[:start] + replacement + raw[end:]
            assert json.loads(raw) == catalog
            path.write_text(raw)
print(f'{changed} catalog entries {"need updates" if args.check else "updated"}; drafts still require language/UI review')
if args.check and changed:
    raise SystemExit(1)
