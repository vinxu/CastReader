#!/usr/bin/env python3
"""Extra corpus-quality check and actual missing/corrupt-model process probes."""
import hashlib,json,os,pathlib,re,subprocess
ROOT=pathlib.Path(__file__).resolve().parents[2]
OUT=ROOT/'reports/ios-language-research-20261011'
TEMP=pathlib.Path('/tmp/CastReaderLanguageResearch20261011')
SIM=os.environ.get('CASTREADER_LID_SIMULATOR','63D71088-9ECB-40B2-9444-E86B45C8EF47')
APP=TEMP/'LanguageResearch.app'

def run(mode,source,destination,model='unused'):
    subprocess.run(['xcrun','simctl','spawn',SIM,str(APP/'LanguageResearch'),mode,
                    str(source),str(destination),str(model)],check=True)

source=TEMP/'yue_hk-ud-test.conllu'
rows=[]
for block in source.read_text().split('\n\n'):
    text=re.search(r'^# text = (.*)$',block,re.M)
    identifier=re.search(r'^# sent_id = (.*)$',block,re.M)
    if text and identifier:
        value=text.group(1)
        rows.append(dict(key='ud:yue:'+identifier.group(1),text=value,language='yue',
                         group='ud_yue',kind='sentence',sha256=hashlib.sha256(value.encode()).hexdigest()))
(OUT/'inputs-ud-yue.json').write_text(json.dumps(rows,ensure_ascii=False))
(OUT/'ud-yue-source.json').write_text(json.dumps({
    'url':'https://raw.githubusercontent.com/UniversalDependencies/UD_Cantonese-HK/master/yue_hk-ud-test.conllu',
    'dataset':'UD Cantonese HK test split, all sentences', 'license':'CC BY-SA 4.0',
    'authors':'Kim Gerdes, John Lee, Herman Leung, Tak-sum Wong; City University of Hong Kong',
    'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'sentences':len(rows),
    'purpose':'Separate spoken-transcript domain; investigate known FLORES-200 Yue label-quality issue, not threshold calibration.',
    'issue':'https://github.com/facebookresearch/flores/issues/61',
    'limitations':'Many very short utterances are not uniquely identifiable; all rows retained without filtering.'
},indent=2)+'\n')
run('production',OUT/'inputs-ud-yue.json',OUT/'production-ud-yue.json','bundled')
run('fasttext',OUT/'inputs-ud-yue.json',OUT/'small-ud-yue.json',TEMP/'lid.176.ftz')

rows=[x for x in json.loads((OUT/'inputs-extra.json').read_text()) if x['group']=='holdout' and x['language']=='en'][:3]
(TEMP/'availability-input.json').write_text(json.dumps(rows))
link=APP/'LanguageIdentification/glotlid-v3-q300k.ftz'
original=link.readlink()
corrupt=TEMP/'corrupt-model.ftz';corrupt.write_bytes(b'not a fastText model\n')
try:
    link.unlink()
    run('production',TEMP/'availability-input.json',OUT/'availability-missing.json')
    link.symlink_to(corrupt)
    run('production',TEMP/'availability-input.json',OUT/'availability-corrupt.json')
finally:
    if link.is_symlink(): link.unlink()
    link.symlink_to(original)
run('production',TEMP/'availability-input.json',OUT/'availability-restored.json')
for scenario in ['missing','corrupt','restored']:
    results=json.loads((OUT/f'availability-{scenario}.json').read_text())['results']
    assert all(x['output']==('en' if scenario=='restored' else '') for x in results)
    assert all(x['native'].get('en',0)>.95 for x in results)
print('PASS: actual absent and corrupt Glot both cause English uncertainty; restoration recovers.')
