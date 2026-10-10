#!/usr/bin/env python3
"""Read-only language screening of draft translations; never promotes review state."""
import argparse,collections,hashlib,json,pathlib,re,subprocess,tempfile
root=pathlib.Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--fasttext',required=True,type=pathlib.Path);p.add_argument('--model',required=True,type=pathlib.Path);a=p.parse_args()
languages=set('nl ko ar ru pl sv da nb fi cs el hu fil he id ms ro tr vi'.split())
codes={'nld':'nl','kor':'ko','arb':'ar','ars':'ar','ary':'ar','aeb':'ar','apc':'ar','arz':'ar','acm':'ar','rus':'ru','pol':'pl','swe':'sv','dan':'da','nob':'nb','nno':'nn','fin':'fi','ces':'cs','ell':'el','hun':'hu','fil':'fil','tgl':'fil','heb':'he','ind':'id','zsm':'ms','msa':'ms','ron':'ro','tur':'tr','vie':'vi','eng':'en'}
rows={}
for file in root.glob('**/*.xcstrings'):
 if any(x in ('build','.build','DerivedData') for x in file.parts):continue
 for key,entry in json.loads(file.read_text())['strings'].items():
  source=entry.get('localizations',{}).get('en',{}).get('stringUnit',{}).get('value')
  if not source:continue
  for language,local in entry.get('localizations',{}).items():
   if language not in languages:continue
   unit=local.get('stringUnit',{});value=unit.get('value','')
   clean=re.sub(r'https?://\S+|\$\{[^}]+\}|%\S*[@dfsu]|[\r\n\t]+',' ',value)
   if sum(c.isalpha() for c in clean)<60:continue
   identity=(language,value)
   rows.setdefault(identity,{'language':language,'key':key,'english':source,'translation':value,'state':unit.get('state'),'clean':clean,'sourceHash':hashlib.sha256(source.encode()).hexdigest()[:20]})
values=list(rows.values())
with tempfile.TemporaryDirectory(prefix='castreader-copy-audit-') as folder:
 text=pathlib.Path(folder)/'samples.txt';text.write_text('\n'.join(r['clean'] for r in values)+'\n')
 run=subprocess.run([str(a.fasttext),'predict-prob',str(a.model),str(text),'5'],text=True,capture_output=True,check=True)
counts=collections.defaultdict(collections.Counter);findings=[]
for row,line in zip(values,run.stdout.splitlines(),strict=True):
 parts=line.split();predictions={}
 for label,prob in zip(parts[::2],parts[1::2]):
  raw=label.removeprefix('__label__');code=codes.get(raw.split('_')[0],raw)
  predictions[code]=predictions.get(code,0)+float(prob)
 best=max(predictions,key=predictions.get);target=row['language'];c=counts[target];c['screened']+=1
 if best==target:c['matchingTopLanguage']+=1
 else:
  c['reviewFindings']+=1;findings.append({k:v for k,v in row.items() if k!='clean'}|{'predictions':predictions,'top':best,'kind':'language_screening_only_not_semantic_verdict'})
report={'scope':'Draft language screening only. Includes known directly authored text; no automatic approval or semantic qualification. Short strings are not classified.','modelSHA256':hashlib.sha256(a.model.read_bytes()).hexdigest(),'minimumAlphabeticCharacters':60,'counts':counts,'findings':findings}
out=root/'reports/ios-28-languages-20261008/translation/language-screening.json';out.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'screened':len(values),'findings':len(findings),'report':str(out)}))
