"""Bounded anonymous probes with synthetic text and the current iOS wire fields."""
import base64
import concurrent.futures
import datetime
import hashlib
import json
import pathlib
import subprocess
import time
import urllib.error
import urllib.request
import uuid

ROOT = pathlib.Path(__file__).resolve().parent
TEXTS = {
    'en': 'The final word is sunflower.',
    'zh': '今天阳光很好。',
    'ja': '今日はいい天気です。',
    'es': 'Hoy hace buen tiempo.',
    'fr': 'Il fait beau aujourd’hui.',
    'pt': 'Hoje o tempo está bom.',
    'it': 'Oggi il tempo è bello.',
    'hi': 'आज मौसम अच्छा है।',
    'de': 'Heute ist das Wetter schön.',
}

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

def probe(case):
    host, language, voice, original = case
    pending = original
    steps = []
    started = time.monotonic()
    try:
        while pending and len(steps) < 4:
            body = {'model': 'kokoro', 'input': pending, 'voice': voice,
                    'voice_code': voice, 'response_format': 'mp3',
                    'return_timestamps': language not in ['zh', 'ja', 'ko'],
                    'speed': 1.0, 'stream': False, 'language': language}
            request = urllib.request.Request(
                'https://' + host + '/api/captioned_speech_partly',
                data=json.dumps(body, ensure_ascii=False).encode(),
                headers={'Content-Type': 'application/json',
                         'X-CastReader-Platform': 'ops',
                         'X-CastReader-Version': 'ios-cost-audit',
                         'X-Request-ID': 'ios-cost-audit-' + uuid.uuid4().hex})
            with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
                raw = response.read(3 * 1024 * 1024 + 1)
                assert len(raw) <= 3 * 1024 * 1024
                headers = {k.lower(): v for k, v in response.headers.items()
                           if k.lower().startswith('x-castreader-') or
                           k.lower() in ['server', 'via', 'x-vercel-id']}
                status = response.status
            result = json.loads(raw)  # iOS expects one JSON object, not NDJSON.
            audio = base64.b64decode(result['audio'], validate=True)
            decoded = subprocess.run(
                ['ffmpeg', '-v', 'error', '-i', 'pipe:0', '-f', 's16le',
                 '-ac', '1', '-ar', '24000', 'pipe:1'], input=audio,
                capture_output=True, timeout=15, check=True).stdout
            assert decoded
            cues = result.get('timestamps') or []
            valid_cues = all(isinstance(t['word'], str) and
                             isinstance(t['start_time'], (int, float)) and
                             isinstance(t['end_time'], (int, float)) for t in cues)
            assert valid_cues
            if body['return_timestamps']:
                assert cues
            remainder = result.get('unprocessed_text') or ''
            assert isinstance(remainder, str)
            assert not remainder or (remainder != pending and pending.endswith(remainder))
            processed = result.get('processed_text') or pending
            assert isinstance(processed, str)
            steps.append({'status': status, 'responseBytes': len(raw),
                          'audioBytes': len(audio), 'decodedSamples': len(decoded) // 2,
                          'timestampCount': len(cues), 'timestampFieldsValid': valid_cues,
                          'lastTimestampWord': cues[-1]['word'] if cues else None,
                          'processedCharacters': len(processed),
                          'remainingCharacters': len(remainder), 'headers': headers})
            pending = remainder
        assert not pending
        return {'host': host, 'language': language, 'voice': voice,
                'fixture': 'multiline' if '\n' in original else 'short',
                'complete': True, 'steps': steps,
                'elapsedSeconds': round(time.monotonic() - started, 3)}
    except Exception as error:
        return {'host': host, 'language': language, 'voice': voice,
                'fixture': 'multiline' if '\n' in original else 'short',
                'complete': False, 'steps': steps, 'errorClass': type(error).__name__,
                'httpStatus': getattr(error, 'code', None)}

if __name__ == '__main__':
    catalog = json.loads((ROOT / 'catalog-global.json').read_text())
    cases = [('tts.castreader.ai', item['code'], item['defaultVoice'], TEXTS[item['code']])
             for item in catalog['languages']]
    for host in ['tts.castreader.ai', 'api.castreader.ai']:
        cases.append((host, 'en', 'af_heart',
                      'First sentence.\nThe final word is sunflower.'))
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        rows = list(pool.map(probe, cases))
    evidence = {'retrievedAtUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
                'syntheticTextOnly': True, 'credentialsSent': False,
                'audioRetained': False, 'maxConcurrency': 2,
                'scope': 'HTTP contract and MP3 decoding; no iOS player/UI or load test',
                'allPassed': all(row['complete'] for row in rows), 'cases': rows}
    (ROOT / 'contract-probes.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2))
    print(json.dumps(evidence, ensure_ascii=False, indent=2))
