#!/usr/bin/env python3
"""Build reviewable iOS copy from the frozen Android reference and authored deltas."""
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
read = lambda p: json.loads(p.read_text())
reference = read(HERE / 'android-reference-metadata.json')
tablet = read(HERE / 'android-reference-tablet-metadata.json')
copy = read(HERE / 'ios-copy.json')
baseline = read(HERE / 'baseline-public-metadata.json')
old_info = baseline['appInfo']
old_version = baseline['version']
mapping = [
 ('en','en-IN','en-US'), ('zh-Hans','zh-CN','zh-Hans'), ('ja','ja-JP','ja'),
 ('de','de-DE','de-DE'), ('fr','fr-FR','fr-FR'), ('es','es-ES','es-ES'),
 ('pt-BR','pt-BR','pt-BR'), ('it','it-IT','it'), ('hi','hi-IN','hi'),
 ('nl','nl-NL','nl-NL'), ('ko','ko-KR','ko'), ('ar','ar','ar-SA'),
 ('ru','ru-RU','ru'), ('pl','pl-PL','pl'), ('sv','sv-SE','sv'),
 ('da','da-DK','da'), ('nb','no-NO','no'), ('fi','fi-FI','fi'),
 ('cs','cs-CZ','cs'), ('el','el-GR','el'), ('hu','hu-HU','hu'),
 ('fil','fil',None), ('he','iw-IL','he'), ('id','id','id'),
 ('ms','ms-MY','ms'), ('ro','ro','ro'), ('tr','tr-TR','tr'), ('vi','vi','vi')]
result = {}
for language, android, asc in mapping:
    source = reference[android]
    paragraphs = source['full'].split('\n\n')
    assert len(paragraphs) in (11,17), (language, len(paragraphs))
    # Keep the reviewed reading, explanation, inputs, language and commercial
    # paragraphs. Replace Android OCR/platform prose, not just its brand name.
    body = '\n\n'.join(paragraphs[:-3]).replace('Google Play', 'App Store')
    description = '\n\n'.join([copy[language]['platform'], body, copy[language]['availability'],
                               copy[language]['privacy'],
                               'EULA: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'])
    if len(description) > 4000 and len(paragraphs) == 17:
        body = '\n\n'.join(paragraphs[:8] + paragraphs[10:-3]).replace('Google Play', 'App Store')
        description = '\n\n'.join([copy[language]['platform'],body,copy[language]['availability'],copy[language]['privacy'],
                                   'EULA: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/'])
    previous = old_version.get(asc, old_version['en-US'])
    info = old_info.get(asc, {})
    title = info.get('name', source['title'])
    assert len(title) <= 30, (language, 'title',len(title))
    assert len(description) <= 4000, (language, 'description',len(description))
    assert copy[language]['availability'] in description
    assert 'Android' not in description and 'Google Play' not in description
    result[language] = {
        'appLanguage': language, 'androidReferenceLocale': android, 'ascLocale': asc,
        'title': title, 'subtitle': info.get('subtitle') or 'PDF · EPUB · TTS',
        'description': description, 'whatsNew': copy[language]['whatsNew'],
        'keywords': previous['keywords'] if asc in old_version else 'Kindle,PDF,EPUB,TTS,OCR',
        'promotionalText': previous.get('promotionalText'),
        'supportUrl': previous['supportUrl'], 'marketingUrl': previous.get('marketingUrl'),
        'privacyPolicyUrl': info.get('privacyPolicyUrl',old_info['en-US'].get('privacyPolicyUrl')),
        'phoneCaptions': source['captions'],
        'ipadCaptions': tablet[android]['captions'][:2] + source['captions'][2:],
        'rtl': language in ('ar','he'),
        'submissionPolicy': 'upload' if asc else 'deliver-files; Apple has no Filipino metadata locale'
    }
assert len(result)==28
(HERE/'metadata.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
(HERE/'whats-new.json').write_text(json.dumps({v['ascLocale']:v['whatsNew'] for v in result.values() if v['ascLocale']},ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'languageCount':28,'uploadLocales':27,'filesOnly':['fil'],
                  'descriptionLengths':{k:len(v['description']) for k,v in result.items()}},ensure_ascii=False,indent=2))

# Retain the two existing regional variants in addition to the 27 new-scope
# store locales. Their titles remain the baseline titles.
extras = read(HERE / 'additional-store-locales.json')
extras['es-MX']['description'] = result['es']['description']
extras['es-MX']['whatsNew'] = result['es']['whatsNew']
zh_hant_availability = '音色和功能的可用範圍依地區而異。'
if zh_hant_availability not in extras['zh-Hant']['description']:
    extras['zh-Hant']['description'] = extras['zh-Hant']['description'].replace('\n\nEULA:', '\n\n' + zh_hant_availability + '\n\nEULA:')
(HERE/'additional-store-locales.json').write_text(json.dumps(extras,ensure_ascii=False,indent=2)+'\n')
all_metadata = {v['ascLocale']:v for v in result.values() if v['ascLocale']}
all_metadata.update(extras)
(HERE/'asc-metadata.json').write_text(json.dumps(all_metadata,ensure_ascii=False,indent=2)+'\n')
legacy = 'en-US zh-Hans ja es-ES fr-FR pt-BR it hi de-DE zh-Hant es-MX'.split()
for stem, locales in [('metadata', list(all_metadata)),('preflight-11',legacy)]:
    lines = ['# CastReader 1.2.48 App Store metadata','']
    for locale in locales:
        v = all_metadata[locale]
        lines += ['## '+locale+' — `'+locale+'`','']
        for label,key in [('Name','title'),('Subtitle','subtitle'),('Promotional text','promotionalText'),('Keywords','keywords'),('Description','description'),('What’s New','whatsNew')]:
            lines += ['### '+label,'','```text',v.get(key) or '', '```','']
    (HERE/(stem+'.md')).write_text('\n'.join(lines))
(HERE/'preflight-11-whats-new.json').write_text(json.dumps({k:all_metadata[k]['whatsNew'] for k in legacy},ensure_ascii=False,indent=2)+'\n')
