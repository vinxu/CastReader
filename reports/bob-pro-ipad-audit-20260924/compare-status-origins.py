import concurrent.futures, datetime, json, pathlib, subprocess
user_id='78f67399-9d7e-489e-a367-8ccd7aef99e5'
hosts=['castreader.com','castreader.ai','api.castreader.ai']
def get(host):
    started=datetime.datetime.now(datetime.timezone.utc).isoformat()
    url=f'https://{host}/api/pro/status?user_id={user_id}&fresh=1'
    p=subprocess.run(['curl','-sS','--max-time','20','-D','-','-H','Cache-Control: no-cache','-w','\n%{http_code} %{time_total}',url],capture_output=True,text=True)
    result={'host':host,'startedAt':started,'exit':p.returncode}
    try:
        # Proxy CONNECT may add an initial header block.
        payload=p.stdout.rsplit('\n',1)
        parts=payload[0].replace('\r\n','\n').split('\n\n')
        body=json.loads(parts[-1]); d=body.get('data') or {}
        headers={}
        for block in parts[:-1]:
            for line in block.splitlines():
                if ':' in line:
                    k,v=line.split(':',1)
                    if k.lower() in ['server','x-vercel-id','x-vercel-cache','cache-control','age','location','x-request-id']:headers[k.lower()]=v.strip()
        result.update({'httpAndSeconds':payload[-1],'headers':headers,'code':body.get('code'),'data':{k:d.get(k) for k in ['pro','plan','resolvedUserId','status','subscriptionStatus','freeRemaining','listenRemaining','listenLimit','contract','degraded']}})
    except Exception as e:
        result.update({'errorType':type(e).__name__,'transportError':p.stderr[:150]})
    return result
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool: result=list(pool.map(get,hosts))
out={'checkedAt':datetime.datetime.now(datetime.timezone.utc).isoformat(),'results':result}
stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%H%M%S')
path=pathlib.Path(__file__).with_name(f'origin-status-comparison-{stamp}.json')
path.write_text(json.dumps(out,indent=2)+'\n');path.chmod(0o600)
print(json.dumps(out,indent=2))
