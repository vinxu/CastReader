#!/usr/bin/env python3
import pathlib,json,hashlib
root=pathlib.Path(__file__).resolve().parents[1]
c=json.loads((root/'CastReader/Localizable.xcstrings').read_text())
fields='title badge subtitle dateRange progressTitle progressRule todayComplete upcomingStatus activeStatus completedStatus endedStatus stepImportTitle stepImportDetail stepListenTitle stepListenDetail stepExplainTitle stepExplainDetail startCTA previewCTA continueCTA close'.split()
keys=['studyBoost.'+field for field in fields]
assert len(keys)==21
languages=json.loads((root/'config/ios-studyboost-translations.json').read_text());result={}
for lang,values in languages.items():
 assert len(values)==21,(lang,len(values))
 result[lang]={hashlib.sha256(c['strings'][key]['localizations']['en']['stringUnit']['value'].encode()).hexdigest()[:20]:value for key,value in zip(keys,values,strict=True)}
(root/'config/ios-direct-translations/studyboost.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
print('Campaign locales authored:',len(languages))
