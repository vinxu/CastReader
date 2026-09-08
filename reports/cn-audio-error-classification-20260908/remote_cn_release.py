"""CN-only immutable module rollout. Credentials never leave the regional host."""
import sys,json,pathlib,hashlib,base64,subprocess,os,shutil,time,fcntl,urllib.request
from datetime import datetime,timezone
P=json.load(sys.stdin);root=pathlib.Path('/opt/castreader-quickread-cn');link=root/'current';old=pathlib.Path(P['expectedTarget']);new=root/'releases'/P['releaseName'];service='castreader-quickread-cn.service';evidence=root/'release-evidence'/(P['releaseName']+'.json');excluded={'.git','node_modules','output','bench-out','test-results'}
def stamp():return datetime.now(timezone.utc).isoformat()
def inventory(tree):
 rows={}
 for f in tree.rglob('*'):
  rel=f.relative_to(tree)
  if any(x in excluded or x=='.env' or x.startswith('.env.') for x in rel.parts) or not f.is_file() or f.is_symlink():continue
  raw=f.read_bytes();rows[str(rel)]={'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw)}
 return rows
expected={f['path']:{'sha256':f['sha256'],'bytes':f['bytes']}for f in P['expectedFiles']}
def digest(rows):return hashlib.sha256(json.dumps(rows,sort_keys=True,separators=(',',':')).encode()).hexdigest()
def check_current():
 assert link.resolve()==old,'production target changed'
 assert inventory(old)==expected,'complete production source baseline changed'
def show(unit):
 r=subprocess.check_output(['systemctl','show',unit,'--property=MainPID,ActiveState,SubState,NRestarts'],text=True);return dict(l.split('=',1)for l in r.splitlines()if '='in l)
def protected():return {u:show(u)['MainPID']for u in ['castreader.service','castreader-cn-kokoro-tunnel.service','castreader-cn-clone-tunnel.service','nginx.service']}
def health():
 with urllib.request.urlopen('http://127.0.0.1:7777/health',timeout=3)as r:v=json.loads(r.read(10000))
 assert v.get('ok')is True
 return {k:v.get(k)for k in ['ok','queue','active','concurrency']}
def idle():
 v=health();return v['queue']==0 and v['active']in {0,False}
def swap(target):
 temp=link.with_name('current.next-'+str(os.getpid()));temp.symlink_to(target);os.replace(temp,link)
def provider_probe(target):
 env={}
 for line in pathlib.Path('/etc/castreader/quickread-cn.env').read_text().splitlines():
  if '='in line and not line.lstrip().startswith('#'):
   k,v=line.split('=',1);v=v.strip();env[k.strip()]=v[1:-1]if len(v)>=2 and v[0]==v[-1]and v[0]in '\"\''else v
 assert env.get('QUICKREAD_REGION')=='cn'
 js="""import {deepSeekMessage,resolveLLMRuntime} from './tools/llm-provider.mjs';import {createHash} from 'node:crypto';
const runtime=resolveLLMRuntime();if(runtime.region!=='cn'||runtime.provider!=='deepseek')throw Error('region mismatch');
const events=[];const result=await deepSeekMessage('Return only this JSON object: {"ok":true}',{maxTokens:64,timeoutMs:15000,logEvent:e=>events.push(e)});
if(JSON.parse(result.text).ok!==true)throw Error('fixture contract failed');
console.log('PROBE='+JSON.stringify({ok:true,region:runtime.region,provider:runtime.provider,model:runtime.primaryModel,textSha256:createHash('sha256').update(result.text).digest('hex'),events,userData:false,ttsRequested:false}));"""
 r=subprocess.run(['/usr/bin/node','--input-type=module','-e',js],cwd=target,env={**os.environ,**env},capture_output=True,text=True,timeout=25)
 lines=[s[6:]for s in r.stdout.splitlines()if s.startswith('PROBE=')];assert r.returncode==0 and len(lines)==1,'regional provider probe failed';return json.loads(lines[0])
lock=open('/var/lock/castreader-quickread-release.lock','w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
check_current()
if P['mode']=='stage':
 assert not new.exists(),'candidate already exists'
 backup=root/'backups'/P['releaseName'];backup.parent.mkdir(exist_ok=True);assert not backup.exists()
 def ignore(path,names):return [n for n in names if n in {'.git','output','bench-out','test-results'}or n=='.env'or n.startswith('.env.')]
 shutil.copytree(old,backup,symlinks=True,ignore=ignore);assert inventory(backup)==expected,'regional backup readback mismatch'
 shutil.copytree(old,new,symlinks=True,ignore=ignore)
 after=dict(expected)
 for name,item in P['patches'].items():
  assert name in {'tools/llm-provider.mjs','tools/llm-provider.test.mjs','tools/llm-deadline.test.mjs'}
  raw=base64.b64decode(item['data']);assert hashlib.sha256(raw).hexdigest()==item['sha256'];(new/name).write_bytes(raw);after[name]={'sha256':item['sha256'],'bytes':len(raw)}
 assert inventory(new)==after and (new/'node_modules').is_dir()and not(new/'node_modules').is_symlink()
 r=subprocess.run(['/usr/bin/node','--test','tools/llm-provider.test.mjs','tools/llm-deadline.test.mjs'],cwd=new,capture_output=True,text=True,timeout=40);assert r.returncode==0,'regional runtime tests failed'
 probe=provider_probe(new)
 receipt={'mode':'staged','startedUTC':stamp(),'from':str(old),'to':str(new),'backup':str(backup),'backupVerified':True,'beforeSource':expected,'afterSource':after,'beforeDigest':digest(expected),'afterDigest':digest(after),'changedSourceFiles':sorted(P['patches']),'candidateTestsPassed':True,'candidateProviderProbe':probe,'productionUnit':show(service),'productionHealth':health()}
 evidence.parent.mkdir(exist_ok=True);evidence.write_text(json.dumps(receipt,indent=2));print('SAFE='+json.dumps(receipt))
elif P['mode']=='activate':
 receipt=json.loads(evidence.read_text());assert receipt['mode']=='staged';assert inventory(new)==receipt['afterSource'] and inventory(pathlib.Path(receipt['backup']))==expected
 before=protected();pid=show(service)['MainPID'];assert pathlib.Path('/proc/'+pid+'/cwd').resolve()==old
 receipt['activationStartedUTC']=stamp();receipt['protectedPIDsBefore']=before;receipt['idleChecks']=[]
 for i in range(3):
  assert idle(),'production has active work; activation deferred'
  receipt['idleChecks'].append(stamp());time.sleep(1)
 check_current();assert idle()and show(service)['MainPID']==pid
 switched=False
 try:
  swap(new);switched=True
  # Existing server SIGTERM handler stops admission and drains accepted work.
  subprocess.run(['systemctl','restart',service],check=True,capture_output=True,timeout=190)
  for i in range(40):
   try:current_health=health();break
   except Exception:time.sleep(.25)
  else:raise RuntimeError('new regional service not ready')
  newpid=show(service)['MainPID'];assert newpid!=pid and pathlib.Path('/proc/'+newpid+'/cwd').resolve()==new
  env=pathlib.Path('/proc/'+newpid+'/environ').read_bytes().split(b'\0');assert b'QUICKREAD_REGION=cn'in env
  assert protected()==before and inventory(new)==receipt['afterSource']
  receipt['productionProviderProbe']=provider_probe(new);receipt['mode']='activated';receipt['oldPID']=pid;receipt['newPID']=newpid;receipt['healthAfter']=current_health
 except Exception as error:
  receipt['errorType']=type(error).__name__
  if switched:swap(old);subprocess.run(['systemctl','restart',service],check=True,timeout=190)
  receipt['mode']='rolled_back';receipt['healthAfter']=health()
 receipt['protectedPIDsAfter']=protected();receipt['currentAfter']=str(link.resolve());receipt['finishedUTC']=stamp();evidence.write_text(json.dumps(receipt,indent=2));print('SAFE='+json.dumps(receipt));sys.exit(0 if receipt['mode']=='activated'else 1)
else:raise ValueError('unknown mode')
