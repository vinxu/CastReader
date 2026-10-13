import os,json,subprocess,concurrent.futures,re,sys
from pathlib import Path
from html.parser import HTMLParser
root=Path('/Users/xuxuheng/Documents/CastReader/reports/bob-pro-ipad-audit-20260924')
target=sys.argv[1] if len(sys.argv)>1 else 'https://castreader-content-k8v44kbro-castreader.vercel.app'
env=os.environ.copy();env['VERCEL_TOKEN']=(Path.home()/'.config/castreader/vercel-token').read_text().strip()
class Page(HTMLParser):
 def __init__(self): super().__init__();self.h1s=0;self.links=[]
 def handle_starttag(self,tag,attrs):
  if tag=='h1':self.h1s+=1
  if tag=='a':self.links.append(dict(attrs).get('href',''))
paths=['/','/zh','/castreader-app','/zh/castreader-app','/read-and-explain','/pricing']
def probe(path):
 args=['vercel','curl',path,'--deployment',target,'--','--silent','--show-error','--compressed','--connect-timeout','10','--max-time','35','--retry','2','--retry-all-errors','--write-out','\n__STATUS__:%{http_code}']
 if path=='/api/pro/checkout':args+=['--request','POST','--header','Content-Type: application/json','--data-binary','{"plan":"monthly"}']
 try:
  r=subprocess.run(args,env=env,capture_output=True,text=True,timeout=130)
  if r.returncode:return {'path':path,'passed':False,'transportExit':r.returncode}
  body,status=r.stdout.rsplit('\n__STATUS__:',1);status=int(status.strip())
  if path.startswith('/api/'):
   data=json.loads(body)
   if path=='/api/pro/checkout':passed=status==200 and data.get('code')==-1 and data.get('message')=='login required' and not(data.get('data') or {}).get('url');info={'loginRequired':passed}
   else:passed=status==200 and data.get('data',{}).get('pro') is False;info={'pro':data.get('data',{}).get('pro'),'plan':data.get('data',{}).get('plan'),'billingGrace':data.get('data',{}).get('billingGrace')}
  else:
   page=Page();page.feed(body);passed=status==200 and page.h1s==1;info={'h1Count':page.h1s,'hasAppStore':any('apps.apple.com' in x for x in page.links),'hasPlayStore':any('play.google.com/store/apps/details?id=com.same.castreader' in x for x in page.links),'hasTools':any(x in ['/tools','/zh/tools'] for x in page.links)}
   if 'castreader-app' in path:passed=passed and info['hasAppStore'] and info['hasPlayStore']
   if path in ['/','/zh']:passed=passed and info['hasTools']
   (root/('candidate-page-'+(path.strip('/').replace('/','-') or 'home')+'.html')).write_text(body)
  return {'path':path.split('?')[0],'http':status,'passed':passed,**info}
 except Exception as e:return {'path':path.split('?')[0],'passed':False,'error':type(e).__name__}
with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
 results=list(pool.map(probe,paths+['/api/pro/checkout','/api/pro/status?user_id=78f67399-9d7e-489e-a367-8ccd7aef99e5']))
report={'target':target,'results':results,'passed':all(r['passed'] for r in results)}
(root/'content-candidate-verification.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2));sys.exit(0 if report['passed'] else 1)
