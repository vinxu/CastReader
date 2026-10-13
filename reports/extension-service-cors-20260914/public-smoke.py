"""TLS/public-ingress checks. Fixed non-user text; no account credentials."""
from pathlib import Path
from datetime import datetime, timezone
import base64, hashlib, json, subprocess, urllib.request, urllib.error

ROOT = Path(__file__).resolve().parent
URL = 'https://tts.castreader.ai/api/captioned_speech_partly'
CHROME = 'chrome-extension://foammmkhpbeladledijkdljlechlclpb'
EDGE = 'chrome-extension://niidajfbelfcgnkmnpcmdlioclhljaaj'
records = []

def call(name, method='OPTIONS', origin=CHROME, body=None, extra=None):
    headers = {} if origin is None else {'Origin': origin}
    if method == 'OPTIONS':
        headers.update({'Access-Control-Request-Method': 'POST',
          'Access-Control-Request-Headers': 'content-type,x-request-id,x-castreader-tts-policy,x-castreader-platform,x-castreader-version'})
    if body is not None:
        headers.update({'Content-Type': 'application/json', 'X-CastReader-TTS-Policy': 'extension-v1',
                        'X-CastReader-Platform': 'extension', 'X-CastReader-Version': '1.2.42'})
    headers.update(extra or {})
    request = urllib.request.Request(URL, data=None if body is None else json.dumps(body).encode(),
                                     headers=headers, method=method)
    try: response = urllib.request.urlopen(request, timeout=40)
    except urllib.error.HTTPError as error: response = error
    data = response.read()
    safe = {key.lower(): ', '.join(response.headers.get_all(key)) for key in response.headers.keys()
            if key.lower().startswith(('access-control-', 'x-castreader-', 'x-tts-', 'x-voice-'))
            or key.lower() in ['content-type', 'vary', 'retry-after']}
    records.append({'name': name, 'status': response.status, 'headers': safe, 'bodyBytes': len(data)})
    return response.status, safe, data

for name, origin in [('chrome', CHROME), ('edge', EDGE)]:
    status, headers, data = call(name+'-preflight', origin=origin)
    assert status == 204 and not data and headers['access-control-allow-origin'] == origin
    assert 'access-control-allow-credentials' not in headers
    assert {'origin', 'access-control-request-method', 'access-control-request-headers'} <= set(x.strip().lower() for x in headers['vary'].split(','))

status, headers, _ = call('untrusted-web-origin', origin='https://example.com')
assert status == 404 and 'access-control-allow-origin' not in headers
status, headers, _ = call('invalid-input', 'POST', body={'input': ''})
assert status == 400 and headers['access-control-allow-origin'] == CHROME
for name, origin in [('native-no-origin', None), ('chrome-noop', CHROME), ('edge-noop', EDGE)]:
    status, headers, body = call(name, 'POST', origin=origin, body={'input': '[5]', 'voice': 'bf_emma', 'language': 'en'})
    assert status == 200 and headers['x-castreader-tts-attempts'] == '0'
    assert headers['x-castreader-tts-contract'] == 'preset-gateway-v1'
    assert ('access-control-allow-origin' not in headers) if origin is None else headers['access-control-allow-origin'] == origin

status, headers, body = call('real-emma-audio', 'POST', body={
    'input': 'The reading test continues with synchronized word highlights.',
    'voice': 'bf_emma', 'language': 'en', 'model': 'kokoro',
    'response_format': 'mp3', 'return_timestamps': True})
assert status == 200 and headers['access-control-allow-origin'] == CHROME
payload = json.loads(body)
audio = base64.b64decode(payload['audio'], validate=True)
assert payload['timestamps'] and not payload.get('unprocessed_text')
path = ROOT/'emma-fixed-smoke.mp3'
path.write_bytes(audio)
probe = json.loads(subprocess.check_output(['/opt/homebrew/bin/ffprobe', '-v', 'error', '-show_entries',
                    'format=duration:stream=codec_name,sample_rate', '-of', 'json', str(path)]))
subprocess.run(['/opt/homebrew/bin/ffmpeg', '-v', 'error', '-xerror', '-i', str(path), '-f', 'null', '-'], check=True, capture_output=True)
report = {'passed': True, 'at': datetime.now(timezone.utc).isoformat(), 'checks': records,
          'audioSha256': hashlib.sha256(audio).hexdigest(), 'audioBytes': len(audio),
          'timestamps': len(payload['timestamps']), 'probe': probe, 'fullMp3Decode': True,
          'boundary': 'Public protocol and fixed MP3 verification; real Brave UI acceptance recorded separately.'}
(ROOT/'public-smoke.json').write_text(json.dumps(report, indent=2)+'\n')
print(json.dumps({'passed': True, 'checks': len(records), 'audioBytes': len(audio), 'timestamps': len(payload['timestamps']), 'fullMp3Decode': True}))
