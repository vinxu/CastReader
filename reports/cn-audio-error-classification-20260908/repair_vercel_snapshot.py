"""Retry only failed read-only Vercel queries; preserve initial partial snapshots."""
from pathlib import Path
import argparse,json
import observe as o
parser=argparse.ArgumentParser();parser.add_argument('snapshot');args=parser.parse_args()
folder=Path(args.snapshot).resolve();folder.relative_to(o.HERE/'observations')
v=json.loads((folder/'vercel.json').read_text());summary=json.loads((folder/'summary.json').read_text());start=o.utc(summary['window']['startUTC']);end=o.utc(summary['window']['endUTCExclusive'])
failed=[(q['statusQuery'],q['search'])for q in v['queries']if q['issues']]
if not failed:raise SystemExit('no failed Vercel queries')
retry=o.vercel(start,end,query_specs=failed);o.write(folder/'vercel-retry.json',retry)
if len(retry['queries'])!=len(failed) or {(q['statusQuery'],q['search'])for q in retry['queries']}!=set(failed):raise SystemExit('missing retry receipts; checkpoint unchanged')
if not retry['completeReturnedPages']:raise SystemExit('retry incomplete; checkpoint unchanged')
for name in ['vercel','summary']:
 target=folder/(name+'-initial-partial.json')
 if not target.exists():target.write_bytes((folder/(name+'.json')).read_bytes())
v['queries']=[q for q in v['queries']if not q['issues']]+retry['queries'];v['coreRecords']=list({row['requestKey']:row for row in v['coreRecords']+retry['coreRecords']}.values());v['completeReturnedPages']=True;v['repairedWith']='vercel-retry.json';o.write(folder/'vercel.json',v)
summary['sources']['vercel']={k:v.get(k)for k in ['collectionFailed','completeReturnedPages','coreRecords','queries']}
# Only advance if every other saved source is complete under the existing collector contract.
complete=True
for region in ['cn','us']:
 r=json.loads((folder/(region+'.json')).read_text())
 complete=complete and not r.get('collectionFailed')and r['monitor']['coverage']['completeRead']and r['quickread']['coverage']['parseErrors']==0
d=json.loads((folder/'direct.json').read_text());complete=complete and not d.get('collectionFailed')and d.get('coverage',{}).get('complete',False)
summary['collectionCompleteWithinAvailableSources']=complete;o.write(folder/'summary.json',summary)
state=json.loads((o.HERE/'observation-state.json').read_text())
if complete and o.utc(state['lastCompleteEndUTC'])==start:
 state.update({'lastCompleteEndUTC':o.iso(end),'latestCollectionComplete':True});o.write(o.HERE/'observation-state.json',state)
print(json.dumps({'queriesRetried':failed,'complete':complete,'checkpoint':state['lastCompleteEndUTC'],'coreErrorRecords':len(v['coreRecords'])}))
