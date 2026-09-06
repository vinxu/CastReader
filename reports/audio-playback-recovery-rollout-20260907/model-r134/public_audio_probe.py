"""Fixed public compatibility probes, run from the existing US control host."""
import base64
from datetime import datetime, timezone
import hashlib
import http.client
import json
import ssl
import subprocess
import time


def probe(host, mode, kind):
    pending = '。' if kind == 'silent' else 'First sentence.\n。\nThe final word is sunflower.'
    steps, timestamps, started = [], [], time.monotonic()
    while pending and len(steps) < 6:
        rid = 'ops-r134-public-' + host.split('.')[0] + '-' + str(mode).lower() + '-' + kind + '-' + str(len(steps))
        body = {'model':'kokoro','input':pending,'voice':'am_adam','voice_code':'am_adam',
                'language':'en','lang_code':'a','response_format':'mp3','return_timestamps':True,'speed':1}
        if mode is not None:
            body['stream'] = mode
        connection = http.client.HTTPSConnection(host,timeout=40,context=ssl.create_default_context())
        try:
            connection.request('POST','/api/captioned_speech_partly',body=json.dumps(body).encode(),headers={
                'Content-Type':'application/json','X-Request-Id':rid,
                'X-CastReader-Platform':'ops','X-CastReader-Version':'release-r134-validation'})
            response = connection.getresponse()
            raw = response.read(3*1024**2+1)
            if response.status != 200 or len(raw)>3*1024**2:
                raise RuntimeError('public_audio_http_or_size_failed')
            routing = {k.lower():v for k,v in response.getheaders() if k.lower().startswith('x-castreader-')}
        finally:
            connection.close()
        try:
            records = [json.loads(raw)]
        except json.JSONDecodeError:
            records = [json.loads(line) for line in raw.splitlines() if line.strip()]
        if not records or any(not isinstance(row,dict) for row in records):
            raise RuntimeError('public_audio_response_shape_failed')
        audio = b''.join(base64.b64decode(row['audio'],validate=True) for row in records)
        decoded = subprocess.run(['ffmpeg','-v','error','-i','pipe:0','-f','s16le','-ac','1','-ar','24000','pipe:1'],
                                 input=audio,capture_output=True,timeout=20)
        if decoded.returncode or not decoded.stdout:
            raise RuntimeError('public_audio_complete_decode_failed')
        current_timestamps = [cue for row in records for cue in (row.get('timestamps') or [])]
        timestamps.extend(current_timestamps)
        # Gateways omit this optional field for these fully consumed fixtures.
        # iOS finishes on nil; Android can infer continuation from text/timestamps.
        # The fixed mixed fixture must still reach its final word below.
        remainder = records[-1].get('unprocessed_text')
        if remainder is None:
            remainder = ''
        if not isinstance(remainder,str) or (remainder and (remainder==pending or not pending.endswith(remainder))):
            raise RuntimeError('public_audio_remainder_contract_failed')
        samples = len(decoded.stdout)//2
        if kind=='silent' and (current_timestamps or samples>6000 or remainder or any(decoded.stdout)):
            raise RuntimeError('public_silent_segment_contract_failed')
        steps.append({'requestKey':hashlib.sha256(rid.encode()).hexdigest()[:20],
                      'status':200,'audioBytes':len(audio),'decodedSamples':samples,
                      'durationSeconds':samples/24000,'timestamps':len(current_timestamps),
                      'remainingCharacters':len(remainder),'routingHeaders':routing})
        pending = remainder
    if pending:
        raise RuntimeError('public_audio_continuation_did_not_finish')
    if kind=='mixed' and (not timestamps or timestamps[-1].get('word','').rstrip('.!?').lower()!='sunflower'):
        raise RuntimeError('public_audio_final_source_word_missing')
    return {'host':host,'stream':mode,'kind':kind,'steps':steps,
            'elapsedSeconds':round(time.monotonic()-started,3),'complete':True}


def main():
    rows=[]
    for host in ('api.castreader.ai','tts.castreader.ai'):
        for mode in (None,True,False):
            for kind in ('silent','mixed'):
                try:
                    rows.append(probe(host,mode,kind))
                except Exception as error:
                    rows.append({'host':host,'stream':mode,'kind':kind,'complete':False,
                                 'errorClass':type(error).__name__,
                                 'reason':str(error) if type(error) is RuntimeError and str(error) in {
                                     'public_audio_http_or_size_failed','public_audio_response_shape_failed',
                                     'public_audio_complete_decode_failed','public_audio_remainder_contract_failed',
                                     'public_silent_segment_contract_failed','public_audio_continuation_did_not_finish',
                                     'public_audio_final_source_word_missing'} else 'fixed_probe_failed'})
    passed=all(row['complete'] for row in rows)
    print(json.dumps({'schema':'castreader.r134-public-audio-validation.v1','verified':passed,
                      'verifiedAtUTC':datetime.now(timezone.utc).isoformat(),
                      'probeOrigin':'existing US control host','fixedNonUserText':True,
                      'audioOrInputRetained':False,'cases':rows},sort_keys=True))
    return 0 if passed else 1


if __name__=='__main__':
    raise SystemExit(main())
