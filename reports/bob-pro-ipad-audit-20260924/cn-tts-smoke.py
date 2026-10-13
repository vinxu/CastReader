from pathlib import Path
import json,subprocess,base64
p=Path(__file__).parent
code=r'''
import urllib.request,json,base64,hashlib,time
body={'input':'Membership checks must preserve continuous reading.','model':'kokoro','response_format':'mp3','return_timestamps':True,'speed':1,'stream':False,'language':'en','voice_code':'af_heart'}
t=time.time();req=urllib.request.Request('https://api.castreader.cn/api/captioned_speech_partly',data=json.dumps(body).encode(),headers={'Content-Type':'application/json'})
with urllib.request.urlopen(req,timeout=90) as r:data=json.load(r);http=r.status
print(json.dumps({'http':http,'seconds':round(time.time()-t,2),'data':data}))
'''
r=subprocess.run(['ssh','-i','/Users/xuxuheng/.ssh/castreader_cn_deploy','-o','BatchMode=yes','ubuntu@106.54.47.163','python3 -'],input=code,capture_output=True,text=True,timeout=100)
if r.returncode:print(r.stderr);raise SystemExit(r.returncode)
x=json.loads(r.stdout);data=x.pop('data');a=data.get('audio_b64') or data.get('audio') or data.get('audio_base64');assert a
path=p/'cn-postrelease-tts.mp3';path.write_bytes(base64.b64decode(a));timestamps=data.get('timestamps') or [];assert isinstance(timestamps,list) and timestamps
f=subprocess.run(['ffprobe','-v','error','-show_entries','format=duration','-of','json',str(path)],capture_output=True,text=True,check=True);duration=float(json.loads(f.stdout)['format']['duration']);assert duration>1
x.update(audioBytes=path.stat().st_size,duration=duration,timestampCount=len(timestamps),passed=True);(p/'cn-postrelease-tts.json').write_text(json.dumps(x,indent=2));print(json.dumps(x))
