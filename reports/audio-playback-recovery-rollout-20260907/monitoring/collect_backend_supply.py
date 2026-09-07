#!/usr/bin/env python3
"""Collect existing QuickRead/clone/CN TTS evidence without production mutations."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import subprocess

from remote_backend_supply import timestamp

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--start-utc', required=True)
    parser.add_argument('--end-utc', required=True)
    parser.add_argument('--incremental-start-utc', required=True)
    parser.add_argument('--output-dir', required=True, type=Path)
    args = parser.parse_args()
    start, incremental, end = map(timestamp, (args.start_utc, args.incremental_start_utc, args.end_utc))
    if not all((start, incremental, end)) or not start <= incremental < end:
        parser.error('invalid fixed observation window')
    targets = (
        ('us', 'root@140.82.14.49', 'python3 -B -', []),
        ('cn', 'ubuntu@106.54.47.163', 'sudo -n python3 -B -',
            ['-i', str(Path.home() / '.ssh/castreader_cn_deploy')]),
        ('us-gpu', 'castreader-us4090', '/venv/main/bin/python -B -', []),
    )
    args.output_dir.mkdir(parents=True, exist_ok=True)
    for role, *_ in targets:
        if (args.output_dir / f'{role}-backend-supply.json').exists():
            parser.error('refusing to overwrite observation; select a new directory')
    source = Path(__file__).with_name('remote_backend_supply.py').read_text()

    def run(target):
        role, host, interpreter, ssh_args = target
        config = {'role': role, 'startUTC': args.start_utc, 'endUTC': args.end_utc,
            'incrementalStartUTC': args.incremental_start_utc}
        code = source + '\ntry:\n print("SAFE_BACKEND=" + json.dumps(collect(' + repr(config) + ')))\n'
        code += 'except Exception as error:\n print("SAFE_BACKEND=" + json.dumps({"collectionFailed":True,"errorClass":type(error).__name__}))\n'
        try:
            result = subprocess.run(['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10',
                *ssh_args, host, interpreter], input=code, text=True, capture_output=True, timeout=90)
            lines = [line[len('SAFE_BACKEND='):] for line in result.stdout.splitlines() if line.startswith('SAFE_BACKEND=')]
            if result.returncode or len(lines) != 1:
                raise RuntimeError('no_sanitized_result')
            value = json.loads(lines[0])
            if not value.get('collectionFailed') and value.get('schema') != 'castreader.backend-supply-observation.v1':
                raise ValueError('unexpected_schema')
        except Exception as error:
            value = {'collectionFailed': True, 'errorClass': type(error).__name__}
        value['collectorSourceSha256'] = hashlib.sha256(source.encode()).hexdigest()
        path = args.output_dir / f'{role}-backend-supply.json'
        with path.open('x') as stream:
            json.dump(value, stream, indent=2)
            stream.write('\n')
        return {'role': role, 'output': str(path), 'collectionFailed': value.get('collectionFailed', False)}

    with ThreadPoolExecutor(max_workers=3) as pool:
        futures = [pool.submit(run, target) for target in targets]
        results = [future.result() for future in as_completed(futures)]
    print(json.dumps(results))
    return 1 if any(result['collectionFailed'] for result in results) else 0

if __name__ == '__main__':
    raise SystemExit(main())
