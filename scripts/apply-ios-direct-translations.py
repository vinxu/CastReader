#!/usr/bin/env python3
"""Apply translations authored/reviewed directly in this task, with format checks."""
import hashlib,json,pathlib,re,collections
ROOT=pathlib.Path(__file__).resolve().parents[1]
TOKEN=re.compile(r'(?<!%)%(?!%)(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:ll|l|h|hh|z|t|j|L)?[@diuoxXfFeEgGaAcCsSpn]|\$\{[^}]+\}')
def args(text):
 out={}
 for index,t in enumerate(TOKEN.findall(text),1):
  position=re.match(r'%(\d+)\$',t)
  key=position[1]if position else str(index)
  out.setdefault(key,[]).append(re.sub(r'^%\d+\$','%',t))
 return {k:sorted(v)for k,v in out.items()}
values={}
for file in sorted((ROOT/'config/ios-direct-translations').glob('*.json')):
 for language,translations in json.loads(file.read_text()).items():
  for key,value in translations.items():
   assert isinstance(value,str) and value.strip(),(file,key)
   assert not re.search(r'[\u202a-\u202e\u2066-\u2069]',value),(file,key)
   values.setdefault(language,{})[key]=value
count=0;found=set()
for file in sorted(ROOT.glob('**/*.xcstrings')):
 if any(p in ['build','.build','DerivedData']for p in file.parts):continue
 catalog=json.loads(file.read_text());changed=False
 for entry in catalog['strings'].values():
  english=entry.get('localizations',{}).get('en',{}).get('stringUnit',{}).get('value')
  if not english:continue
  key=hashlib.sha256(english.encode()).hexdigest()[:20]
  for language,translations in values.items():
   if key not in translations:continue
   value=translations[key]; assert args(english)==args(value),(language,english,value)
   entry['localizations'][language]={'stringUnit':{'state':'translated','value':value}}
   found.add((language,key));count+=1;changed=True
 if changed:file.write_text(json.dumps(catalog,ensure_ascii=False,indent=2)+'\n')
missing={(lang,key)for lang,t in values.items()for key in t}-found
assert not missing,missing
print(json.dumps({'appliedCatalogEntries':count,'uniqueTranslations':len(found)}))
