from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
import sys, json
ROOT = Path('/Users/xuxuheng/Documents/CastReader')
HERE = Path(__file__).resolve().parent
LIB = ROOT / 'reports/backend-audio-iteration-20260906/monitoring'
sys.path.insert(0, str(LIB))
import collect_acceptance as c
def run(region):
    host = ['root@140.82.14.49'] if region == 'us' else ['-i', str(Path.home()/'.ssh/castreader_cn_deploy'), 'ubuntu@106.54.47.163', 'sudo']
    value = c.source_with_error('monitor_'+region, lambda:c.run_remote_script(host, LIB/'remote_monitor_snapshot.py', [region,'2026-09-08T02:24:22Z','2026-09-09T02:24:22Z'],55))
    with (HERE/('monitor-'+region+'.json')).open('x') as f:json.dump(value,f,indent=2)
    return {'region':region, 'saved':True, 'keys':list(value)}
with ThreadPoolExecutor(max_workers=2) as p: print(json.dumps(list(p.map(run,['us']))))
