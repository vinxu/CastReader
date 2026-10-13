#!/usr/bin/python3
"""Finalize existing evidence only. Does not launch tests or alter the app."""
import csv
import datetime
import hashlib
import json
import pathlib
import re
import shutil

REPORTS = pathlib.Path(__file__).resolve().parent
ROOT = REPORTS.parents[1]
VOICE = REPORTS / 'voice134-alignment'
DOCS = ROOT / 'docs/ios-28-language-evidence'
now = datetime.datetime.now(datetime.timezone.utc).isoformat()

def read(path):
    return json.loads(path.read_text())

def write(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')

state = read(REPORTS / 'acceptance-current.json')
assert state['activeLongAcceptance'] is None, 'Driver still running'
rows = state['longSessions']
assert len(rows) == 114 and all(r['status'] == 'passed' for r in rows)
assert len({(r['language'], r['format'], r['mode']) for r in rows}) == 114
verified = []
for row in rows:
    result_path = REPORTS / row['evidence']
    result = next(r for r in read(result_path) if
                  (r['language'], r['format']) == (row['language'], row['format']))
    metric = result[row['mode']]
    seconds = metric['effectivePlayingSeconds']
    assert seconds >= 180 and metric['pauseResume'] is True, row
    assert abs(seconds - row['actualPlayingSeconds']) < .01, row
    if row['mode'] == 'read':
        assert metric['highlightChanges'] > 0, row
    else:
        assert metric['captionChanges'] > 0 and metric['maximumMarks'] > 0, row
    verified.append(dict(language=row['language'], format=row['format'], mode=row['mode'],
                         seconds=seconds, pauseResume=True, evidence=row['evidence'],
                         highlightChanges=metric['highlightChanges'], captionChanges=metric['captionChanges'],
                         maximumMarks=metric['maximumMarks'], segmentsVisited=metric['segmentsVisited'],
                         evidenceSHA256=hashlib.sha256(result_path.read_bytes()).hexdigest()))

for language in ['ms', 'nl', 'pl', 'ro', 'ru', 'sv', 'tr', 'vi']:
    folder = REPORTS / 'long-matrix-20261009-235801' / (language + '-web')
    visual = read(folder / 'visual-review.json')
    assert visual['status'] == 'passed' and len(visual['images']) == 4
    assert all((folder / p).is_file() for p in visual['images'])

manifest = read(VOICE / 'final-source-manifest.json')
assert all(hashlib.sha256((ROOT / f['path']).read_bytes()).hexdigest() == f['sha256']
           for f in manifest['files']), 'Production source changed after Release verification'
release = read(VOICE / 'release-verification.json')
assert release['status'] == 'release_build_passed_unsigned_not_installed'
assert release['debugAcceptanceMarkersAbsent'] and release['webBundleByteIdentical']
assert read(REPORTS / 'localization-final-delivery.json')['releaseQualified']

integrity = dict(checkedAt=now, verifiedRows=114, issues=[], status='passed', rows=verified)
write(REPORTS / 'matrix-evidence-integrity.json', integrity)
state.update(updatedAt=now, completedAt=now, overallStatus='client_acceptance_complete',
             deliveryReady=True, verifiedLongSessionsInCurrentMatrix=114,
             releaseBuild='voice134-alignment/release-verification.json',
             sourceManifest='voice134-alignment/final-source-manifest.json',
             finalHarnessBuild=dict(status='passed', evidence='voice134-alignment/large-type-build3.log'),
             latestBudgetRecheck='budget-incident-audit/budget-2m-limit-change.json',
             matrixEvidenceIntegrity='matrix-evidence-integrity.json')
state['webImport']['immediateManualRecovery']['ms'] = dict(
    status='playback_passed', evidence='long-matrix-20261009-235801/ms-web/results.json',
    note='Biologi fixture; earlier Bumi standalone Jawi word remains a provider input limitation.')
state['knownInputLimitations'].append(dict(
    fixture='Malay Bumi standalone Jawi word', issue='Malay provider rejects the isolated Jawi word with HTTP 502.',
    resolutionForLanguageAcceptance='Public Biologi prose passed both 180-second modes; provider limitation not claimed fixed.'))
state['finalFixes'] = dict(
    webMarks='web133-mark-geometry', visibleWebText='web135-malay-highlight',
    explainBatchContinuation='explain136-batch-continuation',
    voiceBrowseAndPlayback='voice134-alignment/verification-progress.json',
    largeAccessibilityLayout='voice134-alignment/layout-final-narrow-fixed3/visual-review.json')
write(REPORTS / 'acceptance-current.json', state)

matrix = (REPORTS / 'playback-matrix.md').read_text()
matrix = re.sub(r'当前完成 \d+ / 114；.*', '已完成 114 / 114；各项均达到 180 秒，暂停恢复及对应截图已复核。', matrix)
matrix = matrix.replace('完整证据路径在 acceptance-current.json。', '逐项证据路径和 SHA-256 见 matrix-evidence-integrity.json；原始数据保留在本地 reports。')
language_names = dict(ar='阿拉伯语', cs='捷克语', da='丹麦语', el='希腊语', fi='芬兰语', fil='菲律宾语',
                      he='希伯来语', hu='匈牙利语', id='印尼语', ko='韩语', ms='马来语', nb='挪威语',
                      nl='荷兰语', pl='波兰语', ro='罗马尼亚语', ru='俄语', sv='瑞典语', tr='土耳其语', vi='越南语')
for code, name in language_names.items():
    matrix = matrix.replace('| ' + code + ' |', '| ' + name + '（' + code + '） |')
(REPORTS / 'playback-matrix.md').write_text(matrix)
(DOCS / 'playback-matrix.md').write_text(matrix)
write(DOCS / 'matrix-evidence-integrity.json', integrity)
for name, source in [('release-verification.json', VOICE / 'release-verification.json'),
                     ('source-manifest.json', VOICE / 'final-source-manifest.json'),
                     ('historical-test-closure.json', REPORTS / 'historical-test-closure.json')]:
    shutil.copyfile(source, DOCS / name)

summary = dict(completedAt=now, status='client_acceptance_complete', version='1.2.47', build='72',
               region=state['region'], newLanguages=sorted({r['language'] for r in rows}),
               requiredSessions=114, passedSessions=114, minimumActualSeconds=min(r['seconds'] for r in verified),
               totalActualSeconds=sum(r['seconds'] for r in verified),
               productionSourceFiles=len(manifest['files']), sourceDigest=manifest['sourceDigest'],
               sourceUnchangedAfterRelease=True, release='unsigned_build_passed', appStore='not_uploaded_or_submitted',
               limitations=state['knownInputLimitations'], testScope='Real signed-in Pro simulator; no physical-device claim; no native-speaker certification.')
write(DOCS / 'acceptance-summary.json', summary)

doc = ROOT / 'docs/iOS-28-language-acceptance.md'
text = doc.read_text().replace('当前完成 **114 / 114** 次三分钟播放，尚未交付。',
                             '已完成 **114 / 114** 次三分钟播放，客户端验收完成。')
text = text.replace('../reports/ios-28-languages-20261008/playback-matrix.md', 'ios-28-language-evidence/playback-matrix.md')
text = text.replace('../reports/ios-28-languages-20261008/voice134-alignment/release-verification.json', 'ios-28-language-evidence/release-verification.json')
text = text.replace('../reports/ios-28-languages-20261008/voice134-alignment/final-source-manifest.json', 'ios-28-language-evidence/source-manifest.json')
text += '\n交付证据摘要见 [acceptance-summary.json](ios-28-language-evidence/acceptance-summary.json)；114 项原始结果的摘要校验见 [matrix-evidence-integrity.json](ios-28-language-evidence/matrix-evidence-integrity.json)。交付前仅核对现有证据和源码，未重复已通过长测。\n'
doc.write_text(text)

voice_doc = ROOT / 'docs/ios-voice-tab-alignment-2026-10-09/README.md'
text = voice_doc.read_text().replace('本轮修改尚未提交，版本', '本地交付候选版本')
text = text.replace('原任务剩余 Web 长测正在收尾，尚未交付。', '原任务 114 项三分钟长测全部完成，客户端验收交付完成。')
voice_doc.write_text(text)
csv_path = voice_doc.parent / 'acceptance.csv'
with csv_path.open(newline='') as f:
    table = list(csv.reader(f))
for row in table:
    if row[0] == 'DELIVERY-02':
        row[-3:] = ['PASS_REPORT', '../iOS-28-language-acceptance.md', '114/114 三分钟矩阵完成；逐项实际证据、失败历史与未覆盖边界保留。仅本地交付，未发布。']
with csv_path.open('w', newline='') as f:
    csv.writer(f, lineterminator='\n').writerows(table)
progress = read(VOICE / 'verification-progress.json')
progress.update(checkedAt=now, status='complete_with_documented_scope',
                longLanguageMatrix=dict(passed=114, required=114, evidence='../matrix-evidence-integrity.json'))
write(VOICE / 'verification-progress.json', progress)
print(json.dumps(summary, ensure_ascii=False, indent=2))
