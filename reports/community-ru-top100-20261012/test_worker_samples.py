from pathlib import Path
import hashlib
import json
import time
import uuid
import requests

root=Path('/tmp/community-ru-top100-20261012')
headers={'X-Clone-Token':Path('/workspace/castreader-clone/.api-token').read_text().strip(),'X-TTS-Priority':'prefetch'}
base='http://127.0.0.1:8890'
text='Сегодня мы читаем новую историю. Выберите удобный голос и наслаждайтесь прослушиванием.'
results=[]
for rank in [1,2,100]:
    voice='vc_'+uuid.uuid4().hex
    r={'rank':rank,'voice_id':voice,'text':text}
    started=time.monotonic()
    try:
        with (root/(str(rank)+'.mp3')).open('rb') as audio:
            response=requests.post(base+'/v1/voices',headers=headers,files={'reference':('reference.mp3',audio,'audio/mpeg')},data={'consent_confirmed':'true','requested_voice_id':voice,'reference_language':'ru'},timeout=100)
        r['registration_status']=response.status_code
        if response.status_code!=200:
            r['error']=response.text[:1000]
        else:
            r['registration']=response.json()
            response=requests.post(base+'/v1/speech',headers=headers,json={'voice_id':voice,'text':text,'language_id':'ru','seed':42},timeout=90)
            r['speech_status']=response.status_code
            if response.status_code==200:
                content=response.content;(root/(str(rank)+'.wav')).write_bytes(content)
                r['bytes']=len(content);r['sha256']=hashlib.sha256(content).hexdigest()
            else:r['error']=response.text[:1000]
    except Exception as error:r['error']=str(error)
    finally:
        try:r['cleanup_status']=requests.delete(base+'/v1/voices/'+voice,headers=headers,timeout=40).status_code
        except Exception as error:r['cleanup_error']=str(error)
        r['elapsed_seconds']=round(time.monotonic()-started,3)
        results.append(r);(root/'worker-samples.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
        print(json.dumps(r,ensure_ascii=False),flush=True)
