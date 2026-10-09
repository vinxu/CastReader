#!/usr/bin/env python3
"""Bounded public-text, free-voice probe. No credentials and no automatic retry."""
import base64
import argparse
import concurrent.futures
import datetime
import hashlib
import json
import pathlib
import subprocess
import tempfile
import uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
OUT = ROOT / 'reports/ios-28-languages-20261008'
parser = argparse.ArgumentParser()
parser.add_argument('--catalog', type=pathlib.Path, default=OUT / 'catalog-global.json')
parser.add_argument('--output', type=pathlib.Path, default=OUT)
args = parser.parse_args()
CATALOG = json.loads(args.catalog.read_text())
OUT = args.output
OUT.mkdir(parents=True, exist_ok=True)
ROWS = json.loads((ROOT / 'CastReaderTests/Fixtures/language-audit-regression.json').read_text())
VOICES = [v for v in CATALOG['voices'] if v['engine'] == 'google' and v['tier'] == 'free' and v['enabled'] and v['selectable']]
VOICES = list({v['language']: v for v in reversed(VOICES)}.values())

def probe(voice):
    row = next(r for r in ROWS if r['language'] == voice['language'] and 80 <= len(r['text']) <= 220)
    request_id = str(uuid.uuid4())
    result = {'language': voice['language'], 'voice': voice['id'], 'requestID': request_id,
              'source': row['source'], 'sha256': row['sha256'], 'truth': row['language'],
              'region': 'global', 'catalogVersion': CATALOG['version'],
              'at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    body = dict(input=row['text'], voice=voice['id'], language=voice['language'],
                model='google-wavenet', response_format='mp3', return_timestamps=True, speed=1, stream=False)
    with tempfile.TemporaryDirectory(prefix='ios-google-probe-') as temporary:
        temporary = pathlib.Path(temporary)
        payload = temporary / 'request.json'; payload.write_text(json.dumps(body, ensure_ascii=False))
        response = temporary / 'response.json'
        completed = subprocess.run(['curl', '--silent', '--show-error', '--max-time', '60',
            '--request', 'POST', '--header', 'Content-Type: application/json', '--header', 'X-Request-ID: ' + request_id,
            '--data-binary', '@' + str(payload), '--output', str(response), '--write-out', '%{http_code}',
            'https://api.castreader.ai/api/captioned_speech_partly'], capture_output=True, text=True)
        result['httpStatus'] = completed.stdout
        try:
            data = json.loads(response.read_text())
            if completed.stdout != '200':
                result.update(status='fail', response=data)
            else:
                audio = base64.b64decode(data.pop('audio'), validate=True)
                result['audioSHA256'] = hashlib.sha256(audio).hexdigest()
                mp3 = temporary / 'audio.mp3'; mp3.write_bytes(audio)
                metadata = subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=codec_name',
                    '-of', 'json', str(mp3)], capture_output=True, text=True, check=True)
                info = json.loads(metadata.stdout)
                result['decodedAudio'] = info
                duration = float(info['format']['duration'])
                result['response'] = data
                marks = data.get('timestamps', [])
                expected = [w for w in data.get('processed_text', '').split() if any(c.isalnum() for c in w)]
                valid = (data.get('model') == 'google-wavenet' and data.get('voice_code') == voice['id']
                         and data.get('timestamp_source') == 'google-ssml-marks-v1'
                         and [m['word'] for m in marks] == expected and bool(expected)
                         and data.get('processed_text', '') + data.get('unprocessed_text', '') == row['text'])
                previous = -1
                for m in marks:
                    valid &= 0 <= m['start_time'] < m['end_time'] <= duration + .05 and m['start_time'] > previous
                    previous = m['start_time']
                result['status'] = 'pass' if valid else 'fail'
                result['scope'] = 'gateway/audio/marks contract only; not iOS playback, Pro, or native-speaker quality'
        except Exception as error:
            result.update(status='fail', error=type(error).__name__)
    (OUT / ('google-free-' + voice['language'] + '.json')).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(voice['language'], result['status'], result['httpStatus'], flush=True)
    return result

if __name__ == '__main__':
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results = list(pool.map(probe, VOICES))
    (OUT / 'google-free-summary.json').write_text(json.dumps([
        {k: r[k] for k in ('language', 'voice', 'status', 'httpStatus', 'requestID')} for r in results], indent=2) + '\n')
