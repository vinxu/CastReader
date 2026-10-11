#!/usr/bin/env python3
"""Score exported publisher-raster OCR evidence without deleting case/punctuation."""
import argparse, collections, json, pathlib, unicodedata
import regex


def distance(pattern, text):
    # Myers' bit-vector Levenshtein; arbitrary-size Python integers retain every
    # grapheme/word position. Memory stays bounded for full-page comparisons.
    if len(pattern) > len(text):
        pattern, text = text, pattern
    if not pattern:
        return len(text)
    masks = {}
    for i, token in enumerate(pattern):
        masks[token] = masks.get(token, 0) | (1 << i)
    positive, negative, score = ~0, 0, len(pattern)
    high = 1 << (len(pattern) - 1)
    for token in text:
        equal = masks.get(token, 0)
        vertical = equal | negative
        horizontal = (((equal & positive) + positive) ^ positive) | equal
        up = negative | ~(horizontal | positive)
        down = positive & horizontal
        score += bool(up & high) - bool(down & high)
        up = (up << 1) | 1
        down <<= 1
        positive = down | ~(vertical | up)
        negative = up & vertical
    return score


def metrics(expected, actual):
    expected = unicodedata.normalize('NFC', expected.replace('\r\n', '\n'))
    actual = unicodedata.normalize('NFC', actual.replace('\r\n', '\n'))
    a, b = regex.findall(r'\X', expected), regex.findall(r'\X', actual)
    strict = distance(a, b) / max(1, len(a))
    a, b = [c for c in a if not c.isspace()], [c for c in b if not c.isspace()]
    return {'graphemeCER': distance(a, b) / max(1, len(a)),
            'whitespaceInclusiveCER': strict,
            'WER': distance(expected.split(), actual.split()) / max(1, len(expected.split())),
            'expectedNonWhitespaceGraphemes': len(a)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('attachments', type=pathlib.Path)
    parser.add_argument('--output', required=True, type=pathlib.Path)
    args = parser.parse_args()
    assert distance('kitten', 'sitting') == 3
    assert distance('ab', 'ba') == 2
    assert distance([], ['a']) == 1
    assert metrics('é!', 'e\u0301!')['graphemeCER'] == 0
    assert metrics('A!', 'a')['graphemeCER'] == 1
    manifest = json.loads((args.attachments / 'manifest.json').read_text())
    candidates = [a['exportedFileName'] for entry in manifest for a in entry.get('attachments', [])
                  if a.get('suggestedHumanReadableName', '').startswith('original-publication-ocr')]
    if len(candidates) != 1:
        raise ValueError(f'Expected one original-publication-ocr attachment; found {len(candidates)}')
    source = json.loads((args.attachments / candidates[0]).read_text())
    languages = collections.defaultdict(list)
    for row in source['results']:
        if 'error' not in row:
            row.update(metrics(row['expected'], row['recognized']))
        # Keep original text only in the exported source attachment. The summary
        # links the source PDF/image hashes and never embeds a whole publication.
        languages[row['language']].append({k: v for k, v in row.items() if k not in ('expected', 'recognized')})
    summaries = {}
    for language, rows in languages.items():
        valid = [r for r in rows if 'graphemeCER' in r]
        mean = sum(r['graphemeCER'] for r in valid) / max(1, len(valid))
        worst = max((r['graphemeCER'] for r in valid), default=1)
        summaries[language] = {'pages': len(rows), 'errors': len(rows) - len(valid),
                              'meanGraphemeCER': mean, 'worstGraphemeCER': worst,
                              'characterQualityPassed': None,
                              'textLayerDiagnosticThresholdPassed': len(valid) == len(rows) and mean <= .02 and worst <= .05,
                              'rows': rows}
    report = {'os': source['os'], 'scope': source['scope'], 'languages': summaries,
              'metrics': 'NFC graphemes; primary CER ignores whitespace only. Strict CER retains whitespace; WER splits on whitespace. Case, accents, punctuation and hyphens are preserved.',
              'releaseQualified': False,
              'groundTruthStatus': 'Unverified PDF text layers, not human-verified transcription of rendered pages',
              'limitations': ['PDF text layers can differ from visible glyphs: inspected Polish pages omit j and use ligature encodings; Norwegian small caps differ in case. These scores are diagnostic discrepancies, not validated OCR error rates.', 'Forward source-text geometry matching can select repeated words incorrectly; low matching coverage is not by itself a bounding-box defect.', 'Publisher rasters are not camera photos.', 'One source per language; font/source/current/minimum-device matrix incomplete.', 'Geometry matching is reported only for source-matched words, with unmatched words retained in the denominator.']}
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({language: {k: v for k, v in summary.items() if k != 'rows'}
                      for language, summary in summaries.items()}, indent=2))


if __name__ == '__main__':
    main()
