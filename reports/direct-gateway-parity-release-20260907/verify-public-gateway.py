"""Strict-TLS, sequential positive-fixture release gate. Default: local plan.

Only fixed German/English text is synthesized. No fault injection, load tests,
redirect following, credential, cookie, insecure TLS, or IP override is used.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import http.client
import json
import math
from pathlib import Path
import shutil
import ssl
import subprocess
import sys
import re
import time
import uuid

ROOT=Path(__file__).resolve().parent
HOST='tts.castreader.ai'
EXPECTED_PEER='140.82.14.49'
PATH='/api/captioned_speech_partly'
ORIGIN='chrome-extension://foammmkhpbeladledijkdljlechlclpb'
FIXTURES=[
    {'name':'german-abbreviation-decimal','input':'Dr. Müller zahlt 3.14 Euro.',
     'language':'de','voice':'df_mls_19','words':['Dr.','Müller','zahlt','3.14','Euro']},
    {'name':'english-terminal-citation','input':'A careful reader follows the text.[5]',
     'language':'en','voice':'af_heart','words':['A','careful','reader','follows','the','text']},
]


def sha(raw):return hashlib.sha256(raw).hexdigest()


def require(condition,message):
    if not condition:raise RuntimeError(message)


def validate_audio_contract(body,fixture):
    require(isinstance(body,dict),'audio body is not an object')
    require(isinstance(body.get('audio'),str) and bool(body['audio']),'audio string missing')
    audio=base64.b64decode(body['audio'],validate=True)
    require(bool(audio),'decoded audio empty')
    require(body.get('voice_code')==fixture['voice'],'preset voice changed')
    require(body.get('unprocessed_text') in (None,''),'single fixed sentence has a remainder')
    processed=body.get('processed_text')
    accepted={None,fixture['input']}
    if fixture['language']=='en':accepted.add(fixture['input'].replace('[5]',''))
    require(processed in accepted,'fixed sentence was split or rewritten')
    stamps=body.get('timestamps')
    require(isinstance(stamps,list) and bool(stamps),'word timestamps missing')
    words=[]
    previous_start=previous_end=0
    for index,item in enumerate(stamps):
        require(isinstance(item,dict) and isinstance(item.get('word'),str),'invalid timestamp word')
        require('start' not in item and 'end' not in item,'conflicting legacy timestamp aliases remain')
        start,end=item.get('start_time'),item.get('end_time')
        require(type(start) in (int,float) and type(end) in (int,float)
                and math.isfinite(start) and math.isfinite(end),'timestamp clock invalid')
        require(0<=start<end and start+.001>=previous_start and end+.001>=previous_end,
                'timestamp clock moved backward')
        word=item['word'].strip()
        if index==len(stamps)-1:word=word.rstrip('.!?')
        words.append(word)
        previous_start,previous_end=start,end
    # Internal abbreviation/decimal punctuation and spaces remain significant.
    require(words==fixture['words'],'fixed timestamp word sequence differs')
    return audio,{'processedText':processed,'unprocessedText':body.get('unprocessed_text'),
        'timestampWords':words,'timestampCount':len(stamps),'lastTimestampEnd':previous_end,
        'payloadKeys':sorted(body),'voiceCode':body.get('voice_code')}


def exchange(method,policy,payload=None):
    context=ssl.create_default_context()
    require(context.check_hostname and context.verify_mode==ssl.CERT_REQUIRED,'strict TLS context required')
    connection=http.client.HTTPSConnection(HOST,443,timeout=40 if policy=='extension-v1' else 130,context=context)
    request_id='public-parity-'+str(uuid.uuid4())
    headers={'Accept':'application/json','Connection':'close','X-Request-ID':request_id,
        'X-CastReader-Platform':'ops','X-CastReader-Version':'1.2.37'}
    if policy=='extension-v1':headers.update({'X-CastReader-TTS-Policy':'extension-v1','Origin':ORIGIN})
    encoded=json.dumps(payload,ensure_ascii=False).encode() if payload is not None else None
    if encoded is not None:headers['Content-Type']='application/json'
    started=time.monotonic()
    try:
        connection.connect()
        tls={'hostnameVerified':True,'certificateChainVerified':True,'protocol':connection.sock.version(),
            'cipher':connection.sock.cipher()[0],'peerCertificateSha256':sha(connection.sock.getpeercert(binary_form=True)),
            'peerAddress':connection.sock.getpeername()[0]}
        require(tls['peerAddress']==EXPECTED_PEER,'public peer is not the reviewed direct VPS')
        connection.request(method,PATH,body=encoded,headers=headers)
        response=connection.getresponse()
        values={key.lower():value for key,value in response.getheaders()}
        raw=response.read(20*1024*1024+1)
        require(len(raw)<=20*1024*1024,'public response exceeds fixed gate limit')
        if method=='HEAD':
            require(response.status==404 and not raw,'existing POST-only Caddy routing contract changed')
            require(not values.get('x-castreader-gateway') and not values.get('x-castreader-tts-attempts'),
                    'public HEAD unexpectedly reached synthesis gateway')
            return raw,{'method':method,'policy':policy,'status':response.status,'url':'https://'+HOST+PATH,
                'redirectsFollowed':0,'strictTLS':tls,'elapsedSeconds':round(time.monotonic()-started,3),
                'existingRouteContract':'Caddy forwards POST only; HEAD returns static 404','upstreamSynthesisDispatched':False}
        require(response.status==200,'public request did not return HTTP 200')
        require(values.get('x-castreader-gateway')=='direct-us','public request did not reach direct gateway')
        require(values.get('x-castreader-tts-contract')=='preset-gateway-v1','public capability contract missing')
        require(values.get('x-castreader-tts-policy')==policy,'public policy differs')
        require(values.get('x-request-id')==request_id,'request correlation changed')
        require(values.get('cache-control')=='no-store','cache contract changed')
        attempts=values.get('x-castreader-tts-attempts','')
        require(attempts.isdigit(),'attempt header invalid')
        if payload and payload.get('input')=='[5]':
            require(attempts=='0' and values.get('x-castreader-tts-noop')=='punctuation-only',
                    'canonical citation-only capability probe contacted upstream')
        else:
            require(1<=int(attempts)<=3,'audio attempt count outside reviewed recovery bound')
            require(values.get('x-castreader-tts-timing')=='word','fixed fixture lost word timing')
        require('application/json' in values.get('content-type',''),'audio response is not JSON')
        if 'content-length' in values:require(int(values['content-length'])==len(raw),'JSON transfer incomplete')
        selected=['x-castreader-gateway','x-castreader-tts-contract','x-castreader-tts-policy',
            'x-castreader-tts-attempts','x-castreader-tts-timing','x-castreader-tts-noop','x-request-id','cache-control',
            'content-type','content-length','access-control-allow-origin','access-control-expose-headers']
        return raw,{'method':method,'policy':policy,'status':response.status,'url':'https://'+HOST+PATH,
            'redirectsFollowed':0,'strictTLS':tls,'elapsedSeconds':round(time.monotonic()-started,3),
            'headers':{key:values[key] for key in selected if key in values},'responseSha256':sha(raw)}
    finally:connection.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action',choices=['plan','run'],default='plan',nargs='?')
    action=parser.parse_args().action
    plan=json.loads((ROOT/'release-plan.json').read_text())
    if action=='plan':
        print(json.dumps({'networkAccessed':False,'host':HOST,'strictTLS':True,'fixedNonUserText':True,
            'headRequestsExpected404':2,'noGpuCitationCapabilityPosts':2,'audioRequests':4,'sequential':True,'fixtures':FIXTURES,
            'policies':['legacy','extension-v1'],'requiresVerifiedProductionAndPostBackup':True},ensure_ascii=False,indent=2))
        return
    require(shutil.which('ffmpeg') is not None,'ffmpeg is required')
    require(ssl.create_default_context().cert_store_stats()['x509_ca']>0,
        'Python has no CA trust store; use the reviewed /opt/homebrew/bin/python3')
    candidate=(Path(plan['candidateWorktree'])/'ops/tts-direct-gateway/gateway.mjs').read_bytes()
    require(sha(candidate)==plan['candidateSha256'],'candidate source changed')
    encoded_silence=re.search(r"const PUNCTUATION_ONLY_SILENCE_MP3 = '([^']+)';",candidate.decode()).group(1)
    silence_sha=sha(base64.b64decode(encoded_silence,validate=True))
    status=json.loads((ROOT/'status-receipt.json').read_text())
    production=status.get('production.json',{})
    require(production.get('sourceSha256')==plan['candidateSha256'] and production.get('sourceCommit')==plan['candidateCommit'],
        'verified production receipt is missing or differs')
    require(status.get('cleanup.json',{}).get('shadowStopped') is True,'production cleanup incomplete')
    backup=json.loads((ROOT/'offhost-production-combined-receipt.json').read_text())
    require(backup.get('verified') is True,'new production private full readback is incomplete')
    stamp=datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    artifacts=ROOT/('public-validation-'+stamp)
    artifacts.mkdir(mode=0o700)
    receipt={'schema':'castreader.direct-public-positive-gate.v1','observedAt':datetime.now(timezone.utc).isoformat(),
        'candidateCommit':plan['candidateCommit'],'candidateSha256':plan['candidateSha256'],
        'productionReceiptSha256':sha((ROOT/'status-receipt.json').read_bytes()),
        'postBackupReceiptSha256':sha((ROOT/'offhost-production-combined-receipt.json').read_bytes()),
        'strictTLS':True,'pythonExecutable':sys.executable,'pythonVersion':sys.version.split()[0],
        'certificateAuthorities':ssl.create_default_context().cert_store_stats()['x509_ca'],
        'expectedPeer':EXPECTED_PEER,'fixedNonUserText':True,'sequential':True,'synthesisRequestsPlanned':4,
        'noGpuCitationCapabilityPosts':2,'publicHeadExpected404':True,
        'faultInjection':False,'loadTest':False,'passed':False,'observations':[]}
    try:
        for policy in ['legacy','extension-v1']:
            raw,entry=exchange('HEAD',policy)
            receipt['observations'].append(entry)
            noop_payload={'input':'[5]','language':'en','voice':'af_heart','voice_code':'af_heart',
                'model':'kokoro','response_format':'mp3','return_timestamps':True,'speed':1}
            raw,entry=exchange('POST',policy,noop_payload)
            body=json.loads(raw)
            require(isinstance(body,dict) and body.get('timestamps')==[],'canonical silence timing differs')
            require(body.get('voice_code')=='af_heart' and body.get('unprocessed_text') in (None,''),
                    'canonical silence voice or continuation differs')
            audio=base64.b64decode(body.get('audio',''),validate=True)
            require(sha(audio)==silence_sha,'citation-only audio differs from the pinned static canonical silence')
            decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-err_detect','explode','-f','mp3','-i','pipe:0',
                '-f','s16le','-ac','1','-ar','24000','pipe:1'],input=audio,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
            require(decoded.returncode==0 and len(decoded.stdout)>0,'canonical silence MP3 decode failed')
            entry.update({'fixture':'citation-only-capability','upstreamAttempts':0,'audioSha256':sha(audio),
                'matchesPinnedCanonicalSilence':True,'ffmpegCompleteDecode':True,'decodedDurationSeconds':len(decoded.stdout)/2/24000})
            receipt['observations'].append(entry)
            for fixture in FIXTURES:
                # Legacy stream:true still requests one complete MP3 via this
                # gateway. extension-v1 matches the extension's omitted stream.
                payload={'input':fixture['input'],'language':fixture['language'],'voice':fixture['voice'],
                    'voice_code':fixture['voice'],'model':'kokoro','response_format':'mp3','return_timestamps':True,'speed':1}
                if policy=='legacy':payload['stream']=True
                raw,entry=exchange('POST',policy,payload)
                audio,contract=validate_audio_contract(json.loads(raw),fixture)
                decoded=subprocess.run(['ffmpeg','-v','error','-xerror','-err_detect','explode','-f','mp3','-i','pipe:0',
                    '-f','s16le','-ac','1','-ar','24000','pipe:1'],input=audio,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
                require(decoded.returncode==0 and len(decoded.stdout)>0 and len(decoded.stdout)%2==0,
                        'complete strict MP3 decode failed')
                duration=len(decoded.stdout)/2/24000
                require(contract['lastTimestampEnd']<=duration+.25,'word timestamps exceed decoded audio')
                stem=policy+'-'+fixture['name']
                (artifacts/(stem+'.mp3')).write_bytes(audio)
                entry.update({'fixture':fixture['name'],'input':fixture['input'],'contract':contract,
                    'audioBytes':len(audio),'audioSha256':sha(audio),'pcmSamples':len(decoded.stdout)//2,
                    'decodedDurationSeconds':duration,'ffmpegCompleteDecode':True,'audioArtifact':str(artifacts/(stem+'.mp3'))})
                receipt['observations'].append(entry)
        receipt['passed']=True
    except Exception as error:
        receipt['failure']={'type':type(error).__name__,'detail':str(error) if type(error) is RuntimeError else 'strict public verification failed'}
        if isinstance(error,ssl.SSLCertVerificationError):
            receipt['failure'].update(verifyCode=error.verify_code,verifyMessage=error.verify_message)
    finally:
        target=artifacts/'receipt.json'
        target.write_text(json.dumps(receipt,ensure_ascii=False,indent=2)+'\n')
        print(json.dumps({'passed':receipt['passed'],'receipt':str(target),'observations':len(receipt['observations'])}))
    if not receipt['passed']:raise SystemExit(1)


if __name__=='__main__':main()
