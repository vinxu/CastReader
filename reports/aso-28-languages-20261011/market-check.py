import json, urllib.request, urllib.parse, time
from pathlib import Path
p=Path('reports/aso-28-languages-20261011')
c=json.loads(Path('docs/aso/search-localizations.json').read_text())
queries=[(k,v['market'],v['searchQueries'][0]) for k,v in c['localizations'].items()]+[('fil','ph','text to speech')]
results=[]
for locale,market,term in queries:
 url='https://itunes.apple.com/search?'+urllib.parse.urlencode(dict(term=term,country=market,entity='software',limit=50),quote_via=urllib.parse.quote)
 row=dict(locale=locale,market=market,term=term,url=url,kind='iTunes Search API sample; not measured App Store UI ranking or search volume',checkedAt=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()))
 try:
  r=json.load(urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'CastReader-ASO-Audit/1.0'}),timeout=20))
  items=r.get('results',[])
  row.update(resultCount=len(items),castreaderPosition=next((i for i,x in enumerate(items,1) if x.get('trackId')==6757636395),None),sample=[dict(id=x.get('trackId'),name=x.get('trackName'),url=x.get('trackViewUrl')) for x in items[:5]])
 except Exception as e:row['error']=str(e)
 results.append(row);(p/'market-search-samples.json').write_text(json.dumps(results,ensure_ascii=False,indent=2)+'\n')
 print(locale,row.get('resultCount'),row.get('castreaderPosition'),row.get('error',''),flush=True)
 time.sleep(3.1)
