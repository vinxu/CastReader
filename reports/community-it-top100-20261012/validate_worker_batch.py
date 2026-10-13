from pathlib import Path
import json,time,uuid,requests
root=Path('/tmp/community-it-top100-20261012')
headers={'X-Clone-Token':Path('/workspace/castreader-clone/.api-token').read_text().strip(),'X-TTS-Priority':'prefetch'}
base='http://127.0.0.1:8890'
report=root/'worker-validation.json'
synthesis_text='Oggi leggiamo una nuova storia. Scegli una voce piacevole e goditi l’ascolto.'
synthesis_done=0
results=json.loads(report.read_text()) if report.exists() else {}
for item in json.loads((root/'delivery/voices.json').read_text()):
    if item['id'] in results:continue
    voice='vc_'+uuid.uuid4().hex
    row={'id':item['id'],'name':item['name'],'voice_id':voice,'source_sha256':item['audio']['sha256']}
    started=time.monotonic()
    try:
        for attempt in range(4):
            with (root/'delivery'/item['audio']['path']).open('rb') as audio:
                response=requests.post(base+'/v1/voices',headers=headers,files={'reference':('reference.mp3',audio,'audio/mpeg')},data={'consent_confirmed':'true','requested_voice_id':voice,'reference_language':'it'},timeout=100)
            if response.status_code not in [429,503]:break
            time.sleep(5)
        row['status']=response.status_code
        row['result']=response.json()
        if response.status_code==200 and synthesis_done<2:
            generated=requests.post(base+'/v1/speech',headers=headers,json={'voice_id':voice,'text':synthesis_text,'language_id':'it','seed':42},timeout=90)
            row['synthesis_status']=generated.status_code
            row['synthesis_text']=synthesis_text
            if generated.status_code==200:
                (root/(item['id']+'.wav')).write_bytes(generated.content);synthesis_done+=1
    except Exception as error:row['error']=str(error)
    finally:
        try:row['cleanup_status']=requests.delete(base+'/v1/voices/'+voice,headers=headers,timeout=40).status_code
        except Exception as error:row['cleanup_error']=str(error)
        row['seconds']=round(time.monotonic()-started,3)
        results[item['id']]=row;report.write_text(json.dumps(results,ensure_ascii=False,indent=2))
        print(json.dumps({'done':len(results),'id':item['id'],'name':item['name'],'status':row.get('status'),'error':row.get('result',{}).get('detail',{}).get('code') if isinstance(row.get('result',{}).get('detail'),dict) else row.get('error'),'cleanup':row.get('cleanup_status')},ensure_ascii=False),flush=True)
