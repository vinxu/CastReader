"""Read local source literals, exporting only matches to a known remote prefix hash."""
import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
import warnings

warnings.simplefilter('ignore', SyntaxWarning)
ROOTS = [
    Path('/Users/xuxuheng/Documents/CastReader'),
    Path('/Users/xuxuheng/Documents/MyProject/readout-web'),
    Path('/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-feedback-20260905'),
]
TARGET = '3ba4f07afc0f07b8d66970d7d1702e45f710409c26bc652a5922345900db6627'
PATTERN = re.compile(r'''(['"`])((?:\\.|(?!\1)[^\n\\]){50,500})\1''')
matches, counts = [], {}
for root in ROOTS:
    args = ['rg', '--files', '--hidden', '--no-ignore']
    for omit in ['.git', 'node_modules', 'build', 'dist', '.next', '.venv', 'venv', '.vercel', 'Pods', '.build', '.gradle', '.cache', 'vendor']:
        args.extend(['-g', f'!**/{omit}/**'])
    files = subprocess.run(args, cwd=root, capture_output=True, text=True, check=True).stdout.splitlines()
    count = 0
    for rel in files:
        path = root / rel
        if path.suffix not in {'.ts', '.tsx', '.js', '.mjs', '.py', '.swift', '.kt', '.json', '.md', '.sh'}:
            continue
        try:
            if path.stat().st_size > 2_000_000:
                continue
            source = path.read_text(errors='replace')
        except OSError:
            continue
        count += 1
        for match in PATTERN.finditer(source):
            candidates = [match.group(2)]
            if match.group(1) != '`':
                try:
                    value = ast.literal_eval(match.group(0))
                    if isinstance(value, str):
                        candidates.append(value)
                except (SyntaxError, ValueError):
                    pass
            for value in candidates:
                try:
                    digest = hashlib.sha256((value[:50] + '...').encode()).hexdigest()
                except UnicodeError:
                    continue
                if digest == TARGET:
                    matches.append({'root': root.name, 'path': rel, 'line': source.count('\n', 0, match.start()) + 1, 'literalLength': len(value)})
                    break
    counts[root.name] = count
output = {
    'readOnly': True,
    'method': 'Bounded local quoted literal prefix hash search including reports and scripts, max 2MB/file, excluding common dependency/build directories. No literal text exported; no match cannot exclude dynamic text or external callers.',
    'hash': TARGET,
    'scannedFiles': counts,
    'matches': matches,
}
Path(__file__).with_name('local-fixture-prefix-match.json').write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(output, ensure_ascii=False))
