from pathlib import Path
import json,subprocess,base64
p=Path(__file__).parent
row=next(x for x in json.loads((p/'pro-fixtures-private.json').read_text()) if x['status']=='active' and x['expected'])
remote=r'''
import json,urllib.request,time,pathlib

def env(path):
 out={}
 for line in pathlib.Path(path).read_text().splitlines():
  if '=' in line and not line.startswith('#'):
   k,v=line.split('=',1);out[k]=v.strip().strip('"').strip("'")
 return out
cfg=env('/etc/castreader/quickread-cn.env');extra=env('/etc/castreader/quickread-pro-realm.env')
def post(url,data,headers):
 req=urllib.request.Request(url,data=json.dumps(data).encode(),headers={'Content-Type':'application/json',**headers})
 return urllib.request.urlopen(req,timeout=210)
start=time.time()
# Read-only ledger checks prove separate authorities with their existing credentials.
checks=[]
for realm,url,key in [('global','https://castreader.com/api/pro/entitlement',extra['PRO_GLOBAL_INTERNAL_SECRET']),('cn',cfg['PRO_ENTITLEMENT_URL'],cfg['PRO_INTERNAL_SECRET'])]:
 with post(url,{'user_id':sample['user_id'],'consume':False},{'Authorization':'Bearer '+key}) as r:d=json.load(r)['data']
 checks.append({'realm':realm,'http':200,'pro':d['pro']})
assert checks[0]['pro'] is True
headers={'x-api-key':cfg['QUICKREAD_API_KEY'],'x-user-id':sample['user_id'],'x-user-email':sample['email'],'x-device-id':'qa_pro_realm_20260924','x-castreader-global-ingress':'untrusted-client-value'}
text='Photosynthesis converts sunlight into stored chemical energy. Leaves capture light using chlorophyll. Water from roots and carbon dioxide from the air supply the raw materials. Oxygen is released as a byproduct. The plant uses the resulting sugars for growth and cellular respiration. Light intensity, temperature and water availability influence the rate of photosynthesis. These processes connect plants to the wider carbon cycle and sustain most food webs.'
with post('https://quickread.castreader.cn/api/quickread/extract-plan',{'source_url':'https://example.invalid/pro-release-verification','title':'Photosynthesis release verification','lang':'en','text':text,'paragraphs':[{'text':text}]},headers) as r:
 raw=r.read().decode();status=r.status
assert 'event: block0' in raw and 'event: done' in raw and 'event: error' not in raw
blocks=[]
for line in raw.splitlines():
 if line.startswith('data: '):
  try:blocks.append(json.loads(line[6:]))
  except ValueError:pass
result=next(x for x in reversed(blocks) if x.get('job_id') and x.get('block_0'))
job=result['job_id']
for operation,body in [('resume-plan',{'job_id':job}),('extract-block',{'job_id':job,'block_idx':0}),('compose-block',{'job_id':job,'block_idx':0,'timestamps':[],'duration':8})]:
 with post('https://quickread.castreader.cn/api/quickread/'+operation,body,headers) as r:
  data=r.read();assert r.status==200;checks.append({'operation':operation,'http':r.status,'bytes':len(data)})
print(json.dumps({'checkedAt':time.time(),'ledger':checks[:2],'http':status,'block0':True,'done':True,'continuation':checks[2:],'seconds':round(time.time()-start,2),'passed':True}))
'''
code='sample='+repr(row)+'\n'+remote
r=subprocess.run(['ssh','-i','/Users/xuxuheng/.ssh/castreader_cn_deploy','-o','BatchMode=yes','ubuntu@106.54.47.163','sudo python3 -'],input=code,text=True,capture_output=True,timeout=300)
if r.returncode:print(r.stderr);raise SystemExit(r.returncode)
print(r.stdout);(p/'cn-production-smoke.json').write_text(r.stdout)
