"""Immutable monitor-only installation with CAS, backup, test and protected PID checks."""
import sys,json,pathlib,hashlib,base64,subprocess,os,shutil,time,fcntl
from datetime import datetime,timezone
P=json.load(sys.stdin);region=P['region'];assert region in {'cn','us'}
root=pathlib.Path('/opt/castreader-core-audio-monitor');link=root/'current';old=pathlib.Path(P['expectedTarget']);new=root/'releases'/P['releaseName'];timer=f'castreader-core-audio-monitor@{region}.timer';service=f'castreader-core-audio-monitor@{region}.service'
def hashes(path):return {str(f.relative_to(path)):hashlib.sha256(f.read_bytes()).hexdigest() for f in path.rglob('*') if f.is_file() and not f.is_symlink()}
def show(unit):
 s=subprocess.check_output(['systemctl','show',unit,'--property=MainPID,ActiveState,SubState,ExecMainStatus'],text=True);return dict(l.split('=',1)for l in s.splitlines()if '='in l)
def protect():return {u:show(u)['MainPID']for u in P['protectedUnits']}
def swap(target):
 temporary=link.with_name('current.next-'+str(os.getpid()));temporary.symlink_to(target);os.replace(temporary,link)
lock=open('/var/lock/castreader-core-audio-monitor-release.lock','w');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
assert link.resolve()==old and hashes(old)==P['expectedFiles'],'monitor baseline changed'
assert not new.exists(),'release already exists'
before=protect();backup=root/'backups'/P['releaseName'];backup.parent.mkdir(exist_ok=True);shutil.copytree(old,backup,symlinks=True);assert hashes(backup)==P['expectedFiles']
new.mkdir()
for name,item in P['files'].items():
 rel=pathlib.PurePosixPath(name);assert not rel.is_absolute() and '..'not in rel.parts
 data=base64.b64decode(item['data']);assert hashlib.sha256(data).hexdigest()==item['sha256'];dest=new/name;dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(data)
assert hashes(new)=={name:item['sha256']for name,item in P['files'].items()}
tests=subprocess.run(['node','--test',str(new/'probe-core.test.mjs'),str(new/'state-store.test.mjs')],capture_output=True,text=True,timeout=30);assert tests.returncode==0,'candidate monitor tests failed'
receipt={'region':region,'from':str(old),'to':str(new),'backup':str(backup),'backupVerified':True,'testsPassed':True,'sourceFiles':hashes(new),'beforeProtectedPIDs':before,'startedUTC':datetime.now(timezone.utc).isoformat(),'switched':False}
stopped=False
try:
 subprocess.run(['systemctl','stop',timer],check=True,timeout=15);stopped=True
 deadline=time.monotonic()+150
 while show(service)['ActiveState']in {'active','activating','deactivating'}:
  assert time.monotonic()<deadline,'existing monitor did not finish';time.sleep(.5)
 assert link.resolve()==old and hashes(old)==P['expectedFiles'] and protect()==before,'baseline changed before switch'
 swap(new);receipt['switched']=True
 r=subprocess.run(['systemctl','start',service],capture_output=True,text=True,timeout=150)
 latest=json.loads(pathlib.Path(f'/var/lib/castreader-core-audio-monitor/{region}/latest.json').read_text())
 assert 'attemptRecords'in latest and latest['attemptRecords'],'new monitor did not persist attempt records'
 assert latest['observedAt']>=receipt['startedUTC'].replace('+00:00','Z'),'latest monitor receipt is stale'
 assert protect()==before,'business PID changed during monitor install'
 receipt['probe']={k:latest.get(k)for k in ['observedAt','status','supplyOk','failureCode','segmentCount','elapsedMs','attemptRecords']};receipt['manualProbeExit']=r.returncode
 receipt['status']='installed'
except Exception as error:
 receipt['errorType']=type(error).__name__
 if receipt['switched']:swap(old)
 receipt['status']='rolled_back' if receipt['switched'] else 'aborted'
finally:
 if stopped:subprocess.run(['systemctl','start',timer],check=True,timeout=15)
 receipt['timerAfter']=show(timer);receipt['afterProtectedPIDs']=protect();receipt['currentAfter']=str(link.resolve());receipt['finishedUTC']=datetime.now(timezone.utc).isoformat()
(root/'release-evidence').mkdir(exist_ok=True);(root/'release-evidence'/(P['releaseName']+'.json')).write_text(json.dumps(receipt,indent=2));print('SAFE='+json.dumps(receipt));sys.exit(0 if receipt['status']=='installed'else 1)
