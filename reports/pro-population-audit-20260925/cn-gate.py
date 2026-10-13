import pathlib,json,subprocess
p=pathlib.Path(__file__).parent
cn=json.loads((p/'cn-inventory.private.json').read_text())
ids=sorted(set(s['user_id'] for s in cn['subscriptions']))
remote=r'''
import pathlib,json,urllib.request,urllib.error,time,datetime
cfg={}
for line in pathlib.Path('/etc/castreader/quickread-cn.env').read_text().splitlines():
 if '=' in line and not line.startswith('#'):
  k,v=line.split('=',1);cfg[k]=v.strip().strip('"').strip("'")
rows=[]
for uid in ids:
 try:
  req=urllib.request.Request(cfg['PRO_ENTITLEMENT_URL'],data=json.dumps({'user_id':uid,'consume':False}).encode(),headers={'Content-Type':'application/json','Authorization':'Bearer '+cfg['PRO_INTERNAL_SECRET']})
  with urllib.request.urlopen(req,timeout=15) as r:
   d=json.load(r).get('data',{});rows.append({'userId':uid,'http':r.status,'pro':d.get('pro'),'allowed':d.get('allowed'),'consume':False,'checkedAt':datetime.datetime.now(datetime.timezone.utc).isoformat()})
 except Exception as ex:
  rows.append({'userId':uid,'error':type(ex).__name__})
 time.sleep(1)
print(json.dumps(rows))
'''
r=subprocess.run(['ssh','-i','/Users/xuxuheng/.ssh/castreader_cn_deploy','-o','BatchMode=yes','ubuntu@106.54.47.163','sudo python3 -'],input='ids='+repr(ids)+'\n'+remote,text=True,capture_output=True,timeout=150)
if r.returncode:print('CN gate read unavailable');raise SystemExit(1)
data=json.loads(r.stdout);f=p/'cn-gate.private.json';f.write_text(json.dumps(data,indent=2)+'\n');f.chmod(0o600)
print(json.dumps({'checks':len(data),'responses':[{'http':x.get('http'),'pro':x.get('pro'),'error':x.get('error')}for x in data]}))
