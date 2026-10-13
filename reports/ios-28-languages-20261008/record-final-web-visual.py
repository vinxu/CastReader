#!/usr/bin/python3
"""Record a completed, manually inspected pair. Never invoke before viewing it."""
import datetime, json, pathlib, re, sys

reports = pathlib.Path(__file__).resolve().parent
root = reports.parents[1]
language = sys.argv[1]
folder = reports / 'long-matrix-20261009-235801' / (language + '-web')
result = json.loads((folder / 'results.json').read_text())[0]
assert result['status'] == 'passed'
assert all(result[m]['effectivePlayingSeconds'] >= 180 for m in ['read', 'explain'])
record = {
    'reviewedAt': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    'reviewer': 'Codex visual inspection', 'status': 'passed',
    'language': language, 'format': 'web', 'modes': ['read', 'explain'],
    'images': ['screenshots/' + language + '-web-' + m + '-' + s + '.png'
               for m in ['read', 'explain'] for s in ['halfway', 'three-minutes']],
    'observations': sys.argv[2:],
    'actualPlayingSeconds': {m: result[m]['effectivePlayingSeconds'] for m in ['read', 'explain']},
}
assert record['observations']
assert all((folder / f).exists() for f in record['images'])
(folder / 'visual-review.json').write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n')
state = json.loads((reports / 'acceptance-current.json').read_text())
count = state['verifiedLongSessionsInCurrentMatrix']
lookup = {(r['language'], r['format'], r['mode']): r for r in state['longSessions']}
lines = ['# 三分钟播放验收矩阵', '', '计时只计实际音频播放；每格为朗读 / 解读秒数。完整证据路径在 acceptance-current.json。', '',
         '| 语言 | Web | PDF | EPUB |', '|---|---:|---:|---:|']
for lang in sorted({r['language'] for r in state['longSessions']}):
    cells = []
    for fmt in ['web', 'pdf', 'epub']:
        cells.append(' / '.join(f"{lookup[(lang, fmt, m)]['actualPlayingSeconds']:.2f}"
                     if lookup[(lang, fmt, m)]['status'] == 'passed' else '待通过' for m in ['read', 'explain']))
    lines.append('| ' + lang + ' | ' + ' | '.join(cells) + ' |')
lines += ['', f'当前完成 {count} / 114；数值通过后另核对截图，不把加载、暂停或重复循环计入三分钟。']
(reports / 'playback-matrix.md').write_text('\n'.join(lines) + '\n')
doc = root / 'docs/iOS-28-language-acceptance.md'
doc.write_text(re.sub(r'当前完成 \*\*\d+ / 114\*\*', f'当前完成 **{count} / 114**', doc.read_text()))
print(language, 'reviewed;', count, '/114')
