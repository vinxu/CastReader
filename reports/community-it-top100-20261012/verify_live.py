import argparse,concurrent.futures,datetime,hashlib,json,pathlib,subprocess
P=pathlib.Path(__file__).resolve().parent
REPO=pathlib.Path('/Users/xuxuheng/Documents/MyProject/.worktrees/readout-web-community-ru-top100-20261012')
plan=json.loads((REPO/'docs/voice-discovery/community-it-20261012-public.json').read_text())
manifest=json.loads((REPO/'docs/voice-discovery/community-it-20261012.json').read_text())
parser=argparse.ArgumentParser();parser.add_argument('region',choices=['international','cn']);args=parser.parse_args()
host='api.castreader.ai' if args.region=='international' else 'api.castreader.cn'
def fetch(url,path):
 subprocess.run(['/usr/bin/curl','--proxy','http://127.0.0.1:17890','--compressed','-fsS','--retry','2','--max-time','120',url,'-o',str(path)],check=True)
 return path.read_bytes()
raw=fetch(f'https://{host}/api/tts/mobile-catalog?region={args.region}',P/f'catalog-after-{args.region}.json');actual=json.loads(raw)
baseline=json.loads((P/f'catalog-baseline-{args.region}.json').read_text())
added={v['id']:v for v in plan['entries']};live={v['id']:v for v in actual['voices']}
assert len(live)==len(actual['voices'])==1757
assert sum(v['id'].startswith('vl_') for v in live.values())==1474
assert sum(v.get('referenceLanguage')=='ru' for v in live.values())==84
assert sum(v.get('referenceLanguage')=='it' and v['id'].startswith('vl_') for v in live.values())==71
for old in baseline['voices']:assert live[old['id']]==old,('existing_voice_changed',old['id'])
for key,value in added.items():assert live[key]==value,('new_voice_mismatch',key)
assert set(live)==set(v['id'] for v in baseline['voices'])|set(added)
assert actual['version']==baseline['version'].replace(plan['fromVersion'],plan['toVersion'])
for field in ['languages','collections','discovery','editorialRegion','contract']:assert actual[field]==baseline[field],field
caps=json.loads(fetch(f'https://{host}/api/capabilities',P/f'capabilities-after-{args.region}.json'))
assert caps['commitSha']=='2fe536cd42c7b65dc136d236e53e0ba814d1262c'
media=P/'public-media';media.mkdir(exist_ok=True)
samples=[plan['entries'][i] for i in [0,1,35,70]]
def check(spec):
 v,kind=spec;url=v['sampleUrls']['it'] if kind=='preview' else v['avatar']['url64'];expected=url.split('revision=')[1]
 data=fetch('https://'+host+url,media/f'{args.region}-{v["id"]}-{kind}')
 sha=hashlib.sha256(data).hexdigest();assert sha==expected,(v['id'],kind,'hash_mismatch')
 return {'id':v['id'],'kind':kind,'bytes':len(data),'sha256':sha,'httpStatus':200}
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:checks=list(pool.map(check,[(v,k) for v in samples for k in ['preview','avatar']]))
result={'verifiedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'region':args.region,'host':host,'releaseId':caps['releaseId'],'commitSha':caps['commitSha'],'catalogVersion':actual['version'],'voices':len(live),'community':1474,'russian':84,'italian':71,'new':71,'existingUnchanged':1686,'metadataExact':True,'publicMedia':checks}
(P/f'live-verification-{args.region}.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps({k:v for k,v in result.items() if k!='publicMedia'},ensure_ascii=False),flush=True)
