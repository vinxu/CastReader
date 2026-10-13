import subprocess,json,pathlib
remote=r'''
import pathlib,json,subprocess,os,urllib.parse
pid=subprocess.check_output(['systemctl','show','castreader','--property=MainPID','--value'],text=True).strip()
e=dict(x.decode().split('=',1) for x in pathlib.Path('/proc/'+pid+'/environ').read_bytes().split(b'\0') if b'=' in x)
u=urllib.parse.urlparse(e['DATABASE_URL']);env=dict(os.environ,PGHOST=u.hostname,PGPORT=str(u.port or 5432),PGDATABASE=u.path.lstrip('/'),PGUSER=urllib.parse.unquote(u.username or ''),PGPASSWORD=urllib.parse.unquote(u.password or ''),PGCONNECT_TIMEOUT='10',PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=15000')
if 'sslmode' in urllib.parse.parse_qs(u.query):env['PGSSLMODE']=urllib.parse.parse_qs(u.query)['sslmode'][0]
query="""BEGIN READ ONLY;
SELECT json_build_object('checkedAt',now(),'region','cn','subscriptions',coalesce((SELECT json_agg(t) FROM (SELECT s.id,s.user_id,u.email,u.blocked_at,s.payment_provider,s.status,s.interval,s.amount,s.currency,s.plan_name,s.current_period_start,s.current_period_end,s.created_at,s.updated_at FROM subscription s LEFT JOIN public.\"user\" u ON u.id=s.user_id WHERE s.product_id='castreader-pro' ORDER BY s.user_id) t),'[]'::json),'paidOrders',coalesce((SELECT json_agg(t) FROM (SELECT user_id,payment_provider,status,amount,payment_amount,currency,paid_at FROM public.\"order\" WHERE product_id='castreader-pro' AND status='paid') t),'[]'::json));
ROLLBACK;"""
r=subprocess.run(['psql','-X','-q','-t','-A','-v','ON_ERROR_STOP=1'],input=query,env=env,text=True,capture_output=True,timeout=45)
if r.returncode: print(json.dumps({'error':'CN_READ_QUERY_FAILED','detail':r.stderr.splitlines()[-1:]}));raise SystemExit(1)
print(r.stdout.strip())
'''
r=subprocess.run(['ssh','-i','/Users/xuxuheng/.ssh/castreader_cn_deploy','-o','BatchMode=yes','ubuntu@106.54.47.163','sudo python3 -'],input=remote,text=True,capture_output=True,timeout=60)
if r.returncode: print(r.stdout or 'CN inventory unavailable');raise SystemExit(1)
s=json.loads(r.stdout);p=pathlib.Path(__file__).parent/'cn-inventory.private.json';p.write_text(json.dumps(s,indent=2)+'\n');p.chmod(0o600)
from collections import Counter
print(json.dumps({'checkedAt':s['checkedAt'],'region':'cn','records':len(s['subscriptions']),'users':len(set(x['user_id'] for x in s['subscriptions'])),'states':dict(Counter(x['payment_provider']+'/'+x['status'] for x in s['subscriptions'])),'paidOrders':len(s['paidOrders'])}))
