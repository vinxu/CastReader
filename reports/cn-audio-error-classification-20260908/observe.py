"""Read-only bounded post-release observation. Does not synthesize, restart or deploy."""
from pathlib import Path
from datetime import datetime,timezone,timedelta
from concurrent.futures import ThreadPoolExecutor,as_completed
from collections import Counter
import ssl,argparse,ast,json,subprocess,shlex,sys,hashlib,urllib.request,urllib.parse,urllib.error
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1];LIB=ROOT/'reports/backend-audio-iteration-20260906/monitoring'
sys.path.insert(0,str(LIB));sys.path.insert(0,str(ROOT/'reports/audio-playback-recovery-rollout-20260907/monitoring'))
import collect_vercel_preset_events as v
import collect_acceptance as c

def iso(t):return t.astimezone(timezone.utc).isoformat().replace('+00:00','Z')
def utc(s):return datetime.fromisoformat(s.replace('Z','+00:00')).astimezone(timezone.utc)
def write(path,data):
 tmp=path.with_suffix('.tmp');tmp.write_text(json.dumps(data,indent=2,ensure_ascii=False)+'\n');tmp.replace(path)
def ast_constant(path,name):
 for node in ast.parse(path.read_text()).body:
  if isinstance(node,ast.Assign)and any(isinstance(t,ast.Name)and t.id==name for t in node.targets):return ast.literal_eval(node.value)
 raise ValueError('constant_not_found')
def remote(region,code,payload,timeout=100):
 args=['ssh','-C','-T','-o','BatchMode=yes','-o','ConnectTimeout=10']
 if region=='cn':args+=['-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'ubuntu@106.54.47.163','sudo -n python3 -B -c '+shlex.quote(code)]
 else:args+=['root@140.82.14.49','python3 -B -c '+shlex.quote(code)]
 result=subprocess.run(args,input=json.dumps(payload),capture_output=True,text=True,timeout=timeout)
 if result.returncode:raise RuntimeError('remote_read_failed_raw_output_withheld')
 return json.loads(result.stdout)
def regional(region,start,end):
 result=remote(region,(HERE/'remote_observe.py').read_text(),{'region':region,'start':iso(start),'end':iso(end),'monitorSource':(LIB/'remote_monitor_snapshot.py').read_text()})
 receipt=json.loads((HERE/f'{region}-monitor-release.json').read_text())
 observed=result['monitor']['sourceHashes']
 result['monitorReleaseMatches']=observed==receipt['sourceFiles']
 if region=='cn':
  expected=json.loads((HERE/'cn-activate-receipt.json').read_text())
  result['quickreadReleaseMatches']=result['quickread']['source']['current']==expected['to'] and result['quickread']['source']['providerSha256']==expected['afterSource']['tools/llm-provider.mjs']['sha256']
 return result

def direct(start,end):
 code=ast_constant(ROOT/'reports/backend-service-review-20260908T121827Z/collect_direct_streaming.py','REMOTE')
 return remote('us',code,{'source':(LIB/'remote_tts_gateway_snapshot.py').read_text(),'start':iso(start),'end':iso(end)},150)

def vercel(start,end):
 project=json.loads((v.REPO/'.vercel/project.json').read_text());token=json.loads((Path.home()/'Library/Application Support/com.vercel.cli/auth.json').read_text())['token']
 opener=urllib.request.build_opener(urllib.request.HTTPSHandler(context=ssl.create_default_context()),v.NoRedirect())
 records={};queries=[]
 # Targeted error queries avoid unrelated 4xx traffic exhausting the page budget.
 for mask,search in [('5xx','')]+[('4xx',x)for x in ['captioned_speech','quickread','voice-clone','markdown-tts','/api/tts/']]:
  cursor=end;pages=0;issues=[];more=True
  try:
   while pages<8 and more:
    q={'projectId':project['projectId'],'ownerId':project['orgId'],'page':0,'environment':'production','statusCode':mask,'startDate':int(start.timestamp()*1000),'endDate':int(cursor.timestamp()*1000)}
    if search:q['search']=search
    req=urllib.request.Request('https://vercel.com/api/logs/request-logs?'+urllib.parse.urlencode(q),headers={'Authorization':'Bearer '+token,'Accept':'application/json'})
    with opener.open(req,timeout=25)as response:raw=response.read(v.MAX_HTTP_BYTES+1)
    if len(raw)>v.MAX_HTTP_BYTES:raise ValueError('response_limit')
    data=json.loads(raw);batch=data['rows'];more=data.get('hasMoreRows')is True;pages+=1;times=[]
    for row in batch:
     t=v.utc(row['timestamp'])
     if not start<=t<end:continue
     times.append(t);path,group=c.normalize_vercel_path(row.get('requestPath'))
     if group=='other':continue
     key=v.anonymous(row.get('requestId'))
     if not key:continue
     safe=c.sanitize_vercel({**row,'id':row['requestId'],'timestamp':t.timestamp()*1000,'responseStatusCode':row.get('statusCode')},start,end)
     safe['durationMs']=row.get('requestDurationMs')if v.number(row.get('requestDurationMs'))else None
     safe['method']=row.get('requestMethod')if row.get('requestMethod')in {'GET','POST','HEAD','OPTIONS','DELETE'}else 'other'
     records[key]=safe
    if more:
     new=min(times)+timedelta(milliseconds=1)if times else cursor
     if new>=cursor:issues.append('nonadvancing_cursor');break
     cursor=new
   if more:issues.append('pagination_incomplete')
  except Exception as e:issues.append(type(e).__name__+('_'+str(e.code)if isinstance(e,urllib.error.HTTPError)else ''))
  queries.append({'statusQuery':mask,'search':search,'pages':pages,'issues':issues})
 return {'readOnly':True,'rawContentExported':False,'window':{'startUTC':iso(start),'endUTCExclusive':iso(end)},'queries':queries,'completeReturnedPages':all(not q['issues']for q in queries),'coreRecords':list(records.values()),'limitations':['Returned 5xx and targeted 4xx request logs only; not a complete all-status denominator.','Backend 200 and healthy fixed probes do not prove client playback.']}

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--start');parser.add_argument('--end');args=parser.parse_args()
 release=utc(json.loads((HERE/'cn-activate-receipt.json').read_text())['finishedUTC']);deadline=release+timedelta(hours=24)
 prior=json.loads((HERE/'observation-state.json').read_text())if (HERE/'observation-state.json').exists()else {}
 start=utc(args.start)if args.start else utc(prior.get('lastCompleteEndUTC',iso(release)))
 end=min(utc(args.end)if args.end else datetime.now(timezone.utc),deadline)
 if not release<=start<end<=deadline:raise SystemExit('window_outside_fixed_observation_period_or_already_complete')
 dest=HERE/'observations'/end.strftime('%Y%m%dT%H%M%SZ');dest.mkdir(parents=True,exist_ok=False)
 results={}
 tasks={'cn':lambda:regional('cn',start,end),'us':lambda:regional('us',start,end),'direct':lambda:direct(start,end),'vercel':lambda:vercel(start,end)}
 with ThreadPoolExecutor(max_workers=3)as pool:
  futures={pool.submit(fn):name for name,fn in tasks.items()}
  for future in as_completed(futures):
   name=futures[future]
   try:result=future.result()
   except Exception as e:result={'collectionFailed':True,'errorClass':type(e).__name__,'rawErrorWithheld':True}
   write(dest/(name+'.json'),result);results[name]=result
 summary={'window':{'startUTC':iso(start),'endUTCExclusive':iso(end),'fixedObservationEndUTC':iso(deadline)},'readOnly':True,'sources':{},'notes':[]}
 complete=True
 for region in ['cn','us']:
  r=results[region]
  if r.get('collectionFailed'):summary['sources'][region]=r;complete=False;continue
  m=r['monitor'];q=r['quickread']
  summary['sources'][region]={'monitorCycles':m['aggregate']['cycles'],'monitorStatusCounts':m['aggregate']['statusCounts'],'monitorFailureCodes':m['aggregate']['failureCodeCounts'],'attemptOutcomeCounts':m['attemptOutcomeCounts'],'attemptFailureCodes':m['attemptCodeCounts'],'attemptsRecoveredInHealthyCycle':m['attemptsRecoveredInHealthyCycle'],'cyclesWithMissingAttempts':m['cyclesWithMissingAttempts'],'timerActive':m['systemd']['timer']['ActiveState'],'monitorReleaseMatches':r['monitorReleaseMatches'],'quickreadHealth':q['health'],'quickreadProviderEvents':q['providerEventCounts'],'quickreadProviderFailureCodes':q['providerFailureCodes'],'quickreadProviderRecoveredRequests':q['providerRecoveredRequests'],'quickreadErrorLines':q['fixedErrorLines'],'quickreadUndatedErrorLines':q['coverage'].get('undatedErrorLines',0)}
  if region=='cn':summary['sources'][region].update({'quickreadReleaseMatches':r['quickreadReleaseMatches'],'cloneHealth':r['cloneHealth'],'ingressCounts':r['ingress']['counts'],'ingressNon200':r['ingress']['non200']})
  complete=complete and m['coverage']['completeRead'] and q['coverage']['parseErrors']==0
 d=results['direct'];summary['sources']['direct']={k:d.get(k)for k in ['collectionFailed','statusCounts','errorClassCounts','coverage','non200Records']};complete=complete and not d.get('collectionFailed')and d.get('coverage',{}).get('complete',False)
 vv=results['vercel'];summary['sources']['vercel']={k:vv.get(k)for k in ['collectionFailed','completeReturnedPages','coreRecords','queries']};complete=complete and vv.get('completeReturnedPages',False)
 summary['collectionCompleteWithinAvailableSources']=complete
 summary['notes']=['CN HTTP log does not cover dedicated QuickRead ingress.','Direct early admission responses are a known logging blind spot.','Historical disconnects and Vercel platform errors are not claimed fixed by this release.','No observation command submits audio, modifies production or reads client telemetry.']
 write(dest/'summary.json',summary)
 state={**prior,'fixedObservationStartUTC':iso(release),'fixedObservationEndUTC':iso(deadline),'latestDirectory':str(dest),'latestCaptureEndUTC':iso(end),'latestCollectionComplete':complete}
 if complete:state['lastCompleteEndUTC']=iso(end)
 write(HERE/'observation-state.json',state)
 print(json.dumps({'directory':str(dest),'summary':summary},ensure_ascii=False))
if __name__=='__main__':main()
