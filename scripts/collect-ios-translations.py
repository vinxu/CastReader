#!/usr/bin/env python3
"""Salvage verified entries without repeating billable requests; keep drafts reviewable."""
import collections,hashlib,json,pathlib,re
ROOT=pathlib.Path(__file__).resolve().parents[1]
OUT=ROOT/'reports/ios-28-languages-20261008/translation'
source=json.loads((OUT/'source.json').read_text()); ledger=json.loads((OUT/'ledger.json').read_text())
pattern=re.compile(r'(?<!%)%(?!%)(?:(\d+)\$)?([-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:ll|l|h|hh|z|t|j|L)?[@diuoxXfFeEgGaAcCsSpn])|\$\{[^}]+\}')
def arguments(text):
 tokens=list(pattern.finditer(text)); found={}; positional=any(m[1] for m in tokens)
 if positional and any(not m[1] for m in tokens if m[2]):raise ValueError('mixed argument positions')
 for i,m in enumerate(tokens):
  key=m[1]or str(i+1); kind=m[2]or m[0]
  found.setdefault(key,[]).append(kind)
 return {k:sorted(v) for k,v in found.items()}
def valid(en,value):
 if not isinstance(value,str)or not value.strip():return False
 if re.search(r'[\u202a-\u202e\u2066-\u2069]',value):return False
 try:return arguments(en)==arguments(value)
 except ValueError:return False
candidates={};missing=[]
for job in ledger['jobs']:
 lang=job['language'];offset=int(job['id'].rsplit('-',1)[1]);entries=[(k,v)for k,v in source.items()if lang in v['targets']][offset:offset+45]
 raw=OUT/(job['id']+'.raw.txt'); values={}
 if raw.exists():
  try:values=json.loads(raw.read_text())
  except ValueError:pass
 for i,(key,entry) in enumerate(entries):
  value=values.get(key,values.get('s'+str(i)))
  if valid(entry['english'],value):candidates.setdefault(lang,{})[key]=value
  else:missing.append({'language':lang,'key':key,'english':entry['english'],'originalJob':job['id'],'originalStatus':job['status']})
(OUT/'candidates.json').write_text(json.dumps(candidates,ensure_ascii=False,indent=2)+'\n')
(OUT/'repair-queue.json').write_text(json.dumps(missing,ensure_ascii=False,indent=2)+'\n')
# Original source lookup remains immutable; only fill absent entries and retain
# needs_review until the semantic review and runtime resource audits complete.
catalogs={}
for lang,entries in candidates.items():
 for key,value in entries.items():
  for context in source[key]['contexts']:
   file=context['file']
   if file not in catalogs:catalogs[file]=json.loads((ROOT/file).read_text())
   catalog=catalogs[file]
   localizations=catalog['strings'][context['key']].setdefault('localizations',{})
   if lang not in localizations:localizations[lang]={'stringUnit':{'state':'needs_review','value':value}}
for file,catalog in catalogs.items():(ROOT/file).write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'validDrafts':sum(map(len,candidates.values())),'repairEntries':len(missing),'byLocale':dict(collections.Counter(x['language']for x in missing))}))
