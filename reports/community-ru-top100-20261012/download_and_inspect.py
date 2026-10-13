import array
import concurrent.futures
import hashlib
import json
import math
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent
rows = json.loads((ROOT / 'discovery-top100.json').read_text())['voices']
hash_bytes = lambda data: hashlib.sha256(data).hexdigest()

def process(row):
    result = dict(row)
    try:
        for kind in ['audio', 'avatar']:
            folder = ROOT / 'raw' / kind
            folder.mkdir(parents=True, exist_ok=True)
            destination = folder / (row['sourceId'] + ('.mp3' if kind == 'audio' else '.webp'))
            if not destination.exists():
                temporary = destination.with_suffix(destination.suffix + '.part')
                subprocess.run(['curl', '-fLsS', '--retry', '2', '--connect-timeout', '10', '--max-time', '60', row[kind + 'Url'], '-o', str(temporary)], check=True, capture_output=True, timeout=190)
                temporary.replace(destination)
            data = destination.read_bytes()
            result[kind + 'Path'] = str(destination)
            result[kind + 'Sha256'] = hash_bytes(data)
            result[kind + 'Bytes'] = len(data)
        pcm = subprocess.run(['ffmpeg', '-v', 'error', '-xerror', '-i', result['audioPath'], '-vn', '-ac', '1', '-ar', '16000', '-f', 's16le', '-'], capture_output=True, check=True, timeout=30).stdout
        samples = array.array('h', pcm)
        rms = math.sqrt(sum(float(v) ** 2 for v in samples) / max(1, len(samples))) / 32768
        result['audioCheck'] = {'valid': len(samples) >= 48000 and rms > 0.00001, 'pcmSha256': hash_bytes(pcm), 'decodedSeconds': len(samples) / 16000, 'rmsDb': round(20 * math.log10(max(rms, 1e-12)), 2)}
        result['catalogId'] = 'v_' + hash_bytes(pcm)[:20]
        result['error'] = None
    except Exception as error:
        result['error'] = str(error)
    (ROOT / 'raw' / (row['sourceId'] + '.json')).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    return result

results = []
with concurrent.futures.ThreadPoolExecutor(max_workers=5) as pool:
    for result in pool.map(process, rows):
        results.append(result)
        print(json.dumps({'rank': result['index'], 'name': result['name'], 'duration': result.get('audioCheck', {}).get('decodedSeconds'), 'error': result['error']}, ensure_ascii=False), flush=True)
results.sort(key=lambda row: row['index'])
(ROOT / 'download-audit.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
existing = {row['id'] for row in json.loads(Path('/Users/xuxuheng/Documents/MyProject/readout-web/voice-library-clean/delivery/voices.json').read_text())}
print(json.dumps({'complete': len(results), 'failures': sum(bool(r['error']) for r in results), 'alreadyInCatalog': [r['index'] for r in results if r.get('catalogId') in existing], 'uniquePCM': len({r.get('catalogId') for r in results})}), flush=True)
