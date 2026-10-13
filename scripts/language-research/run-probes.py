#!/usr/bin/env python3
"""Run separate simulator processes sequentially to avoid timing interference."""
import json, os, pathlib, subprocess
ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'reports/ios-language-research-20261011'
TEMP = pathlib.Path('/tmp/CastReaderLanguageResearch20261011')
SIM = os.environ.get('CASTREADER_LID_SIMULATOR','63D71088-9ECB-40B2-9444-E86B45C8EF47')
PROBE = TEMP / 'LanguageResearch.app/LanguageResearch'

def run(mode, data, output, model='unused'):
    subprocess.run(['xcrun', 'simctl', 'spawn', SIM, str(PROBE), mode,
                    str(data), str(output), str(model)], check=True)

for corpus in ['regression', 'extra']:
    data = OUT / ('inputs-' + corpus + '.json')
    for mode, name, model in [('production', 'production', 'bundled'),
                               ('fasttext', 'small', TEMP / 'lid.176.ftz')]:
        output = OUT / (name + '-' + corpus + '.json')
        if not output.exists():
            run(mode, data, output, model)

data = json.loads((OUT / 'inputs-extra.json').read_text())
performance = [next(x for x in data if x['group']=='holdout' and x['language']=='en')]
performance += [x for x in data if x['group']=='holdout' and x['key']!=performance[0]['key']][:199]
(TEMP / 'performance-input.json').write_text(json.dumps(performance,ensure_ascii=False))
for mode, name, model in [('native','native','unused'),
                         ('fasttext','small',TEMP/'lid.176.ftz'),
                         ('fasttext','glot',ROOT/'CastReader/Resources/LanguageIdentification/glotlid-v3-q300k.ftz'),
                         ('production','production','bundled')]:
    for repeat in range(5):
        run(mode, TEMP/'performance-input.json',OUT/f'performance-{name}-{repeat}.json',model)
