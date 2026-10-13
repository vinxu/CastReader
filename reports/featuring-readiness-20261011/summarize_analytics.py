from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
from collections import defaultdict,Counter
import json,urllib.request,gzip,io,csv,hashlib,datetime
P=Path(__file__).resolve().parent;D=P/'analytics-private'
def fetch(fp):
 doc=json.loads(fp.read_text());rows=[];files=[]
 for i,seg in enumerate(doc['data']):
  a=seg['attributes'];dst=fp.with_suffix('.'+str(i)+'.tsv')
  if dst.exists(): b=dst.read_bytes()
  else:
   raw=urllib.request.urlopen(a['url'],timeout=45).read()
   assert len(raw)==a['sizeInBytes'],fp.name
   assert hashlib.md5(raw).hexdigest()==a['checksum'],fp.name
   b=gzip.decompress(raw) if raw[:2]==b'\x1f\x8b' else raw
   dst.write_bytes(b);dst.chmod(0o600)
  rows.extend(csv.DictReader(io.StringIO(b.decode()),delimiter='\t'))
 key,processing=fp.stem.split('-',1)
 return key,processing,rows
batches=list(ThreadPoolExecutor(max_workers=6).map(fetch,sorted(D.glob('*.json'))))
latest={k:{} for k in ['r3','r14']}
for key,processing,rows in sorted(batches,key=lambda r:r[1]):
 bydate=defaultdict(list)
 for r in rows:bydate[r['Date']].append(r)
 for date,dated in bydate.items():latest[key][date]={'processingDate':processing,'rows':dated}
# Use a common 28-day window ending 3 days before latest processing day.
start='2026-09-10';end='2026-10-07'
result={'appId':'6757636395','windowStart':start,'windowEnd':end,'days':28,'latestProcessingDate':max(x[1] for x in batches),'method':'Standard daily reports, newest processingDate replaces the entire record set for each Date; iPhone+iPad only; Counts (events, not unique people); 28-day window ends 2026-10-07 to leave 3 processing days. No CVR inferred across incompatible denominators. Privacy noise may apply.','sources':{},'firstDownloadsByTerritory':{},'weekly':{},'coverage':{}}
downloads=[];engagement=[]
for key,target in [('r3',downloads),('r14',engagement)]:
 selected={d:v for d,v in latest[key].items() if start<=d<=end}
 result['coverage'][key]={'dates':len(selected),'start':min(selected),'end':max(selected)}
 assert len(selected)==28,(key,len(selected))
 for batch in selected.values():target.extend(r for r in batch['rows'] if r['Device'] in ['iPhone','iPad'] and r['App Apple Identifier']=='6757636395')
territory=Counter();sources=defaultdict(Counter);weekly=defaultdict(Counter)
for r in downloads:
 metric={'First-time download':'firstDownloads','Redownload':'redownloads'}.get(r['Download Type'])
 if not metric:continue
 n=int(r['Counts']);sources[r['Source Type']][metric]+=n
 if metric=='firstDownloads':territory[r['Territory']]+=n
 week=((datetime.date.fromisoformat(r['Date'])-datetime.date.fromisoformat(start)).days//7)+1
 weekly['week'+str(week)][metric]+=n
for r in engagement:
 metric='impressions' if r['Event']=='Impression' else 'productPageViews' if r['Event']=='Page view' and r['Page Type']=='Product page' else None
 if metric:sources[r['Source Type']][metric]+=int(r['Counts'])
result['sources']={s:dict(c) for s,c in sources.items()};result['firstDownloadsByTerritory']=dict(territory.most_common());result['weekly']={s:dict(c) for s,c in sorted(weekly.items())}
result['totals']=dict(sum(sources.values(),Counter()))
(P/'analytics-baseline.json').write_text(json.dumps(result,indent=2))
with (P/'traffic-baseline.csv').open('w') as f:
 writer=csv.DictWriter(f,fieldnames=['source','impressions','productPageViews','firstDownloads','redownloads']);writer.writeheader()
 for k,v in result['sources'].items():writer.writerow({'source':k,**v})
print(json.dumps(result,indent=2))
