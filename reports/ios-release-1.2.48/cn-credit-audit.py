from pathlib import Path
import json,plistlib,subprocess,shlex,sys
r=Path(__file__).parent;a=json.loads(plistlib.loads((r/'device-preferences-private.plist').read_bytes())['auth_account_v1.cn']);owner=a['backendUserId'];assert a['maskedPhone']=='139****1416'
remote=r'''
import os,json,pathlib,subprocess,urllib.parse,re,sys
owner=sys.argv[1];assert re.fullmatch(r'[A-Za-z0-9_-]{1,120}',owner)
pid=subprocess.check_output(['systemctl','show','--property','MainPID','--value','castreader'],text=True).strip();e=dict(x.split('=',1) for x in pathlib.Path('/proc/'+pid+'/environ').read_text().split('\0') if '=' in x);assert e.get('CASTREADER_SERVICE_ROUTE')=='cn'
u=urllib.parse.urlparse(e['DATABASE_URL']);pg={**os.environ,'PGHOST':u.hostname,'PGPORT':str(u.port or 5432),'PGUSER':urllib.parse.unquote(u.username or ''),'PGPASSWORD':urllib.parse.unquote(u.password or ''),'PGDATABASE':u.path.lstrip('/'),'PGCONNECT_TIMEOUT':'10','PGOPTIONS':'-c default_transaction_read_only=on'}
sql=f"""BEGIN READ ONLY; SET LOCAL TIME ZONE 'UTC'; SET LOCAL statement_timeout='15s';
SELECT json_build_object('at',now(),'buckets',(SELECT coalesce(json_agg(json_build_object('period',period_key,'usedMs',used_ms,'reservedMs',reserved_ms,'resetAt',reset_at)),'[]') FROM voice_clone_quota_bucket WHERE user_id='{owner}' AND reset_at>now()),'purchases',(SELECT coalesce(json_agg(json_build_object('environment',environment,'grantedMs',granted_ms,'consumedMs',consumed_ms,'reservedMs',reserved_ms,'refunded',refunded)),'[]') FROM voice_clone_credit_purchase WHERE user_id='{owner}'),'requests',(SELECT coalesce(json_agg(t),'[]') FROM (SELECT r.request_id,r.environment,r.state,r.base_reserved_ms,r.base_charged_ms,r.actual_ms,coalesce(sum(a.reserved_ms),0) purchased_reserved_ms,coalesce(sum(a.charged_ms),0) purchased_charged_ms,r.created_at,r.updated_at FROM voice_clone_credit_request r LEFT JOIN voice_clone_credit_allocation a ON a.request_id=r.id WHERE r.user_id='{owner}' AND r.created_at>='2026-10-10T11:29:00Z' GROUP BY r.id ORDER BY r.created_at) t)); ROLLBACK;"""
p=subprocess.run(['psql','-X','-tAq','-v','ON_ERROR_STOP=1'],input=sql,env=pg,text=True,capture_output=True);assert p.returncode==0,p.stderr;print(p.stdout.strip())
'''
p=subprocess.run(['ssh','-i',str(Path.home()/'.ssh/castreader_cn_deploy'),'-o','BatchMode=yes','ubuntu@106.54.47.163','sudo python3 -c '+shlex.quote(remote)+' '+shlex.quote(owner)],capture_output=True,text=True,timeout=30);assert p.returncode==0,p.stderr
v=json.loads(p.stdout);f=r/('cn-credit-'+sys.argv[1]+'.json');f.write_text(json.dumps(v,indent=2)+'\n');f.chmod(0o600)
print(json.dumps({'phase':sys.argv[1],'at':v['at'],'buckets':v['buckets'],'requestCount':len(v['requests']),'chargedMs':sum(x['base_charged_ms']+x['purchased_charged_ms'] for x in v['requests'])}))
