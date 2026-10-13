#!/usr/bin/env python3
"""Deterministic, article-disjoint research additions from the official FLORES archive.

Download https://tinyurl.com/flores200dataset to the path below first.
Known regression/dev is calibration; no threshold tuning on new holdout articles.
Derived prefixes/noise/mixes are stress tests, not independent labelled sentences.
"""
import collections, csv, hashlib, io, json, pathlib, random, tarfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'reports/ios-language-research-20261011'
ARCHIVE = pathlib.Path('/tmp/CastReaderLanguageResearch20261011/flores200.tar.gz')
mapping = dict(pair.split(':') for pair in '''am:amh_Ethi ar:arb_Arab as:asm_Beng az:azj_Latn bg:bul_Cyrl bn:ben_Beng cs:ces_Latn da:dan_Latn de:deu_Latn el:ell_Grek en:eng_Latn es:spa_Latn et:est_Latn fa:pes_Arab fi:fin_Latn fil:tgl_Latn fr:fra_Latn gu:guj_Gujr he:heb_Hebr hi:hin_Deva hu:hun_Latn id:ind_Latn it:ita_Latn ja:jpn_Jpan kn:kan_Knda ko:kor_Hang ml:mal_Mlym mr:mar_Deva ms:zsm_Latn nb:nob_Latn ne:npi_Deva nl:nld_Latn nn:nno_Latn pa:pan_Guru pl:pol_Latn pt:por_Latn ro:ron_Latn ru:rus_Cyrl sk:slk_Latn sv:swe_Latn sw:swh_Latn ta:tam_Taml ti:tir_Ethi tr:tur_Latn uk:ukr_Cyrl ur:urd_Arab vi:vie_Latn zh:zho_Hans yue:yue_Hant af:afr_Latn ca:cat_Latn hr:hrv_Latn sr:srp_Cyrl sl:slv_Latn th:tha_Thai te:tel_Telu lo:lao_Laoo bo:bod_Tibt my:mya_Mymr km:khm_Khmr is:isl_Latn eo:epo_Latn cy:cym_Latn gl:glg_Latn be:bel_Cyrl yi:ydd_Hebr jv:jav_Latn min:min_Latn'''.split())
regression = json.loads((ROOT / 'CastReaderTests/Fixtures/language-audit-regression.json').read_text())
for row in regression:
    row.update(key=f"regression:{row['language']}:{row['split']}:{row['id']}", group='regression',kind='sentence')
random.Random(20261011).shuffle(regression)
(OUT/'inputs-regression.json').write_text(json.dumps(regression,ensure_ascii=False))
known_sources = {x['source'] for x in regression}
data = []

def add(text, lang, key, kind, group, **extra):
    data.append(dict(text=text, language=lang, key=key, kind=kind, group=group,
                     sha256=hashlib.sha256(text.encode()).hexdigest(), **extra))

with tarfile.open(ARCHIVE) as tar:
    def read(name):
        return tar.extractfile('./flores200_dataset/' + name).read().decode('utf-8')
    metadata = list(csv.DictReader(io.StringIO(read('metadata_devtest.tsv')), delimiter='\t'))
    # One sentence from each of 100 previously unused articles, identical ids
    # across translations. Keep articles out of calibration in every language.
    source_ids = {}
    for i, row in enumerate(metadata):
        if row['URL'] not in known_sources:
            source_ids.setdefault(row['URL'], []).append(i)
    selected_sources = sorted(source_ids)
    random.Random(20261011).shuffle(selected_sources)
    ids = [source_ids[s][0] for s in selected_sources[:100]]
    assert len(ids) == 100
    by_language = {}
    for lang, code in mapping.items():
        lines = read('devtest/' + code + '.devtest').splitlines()
        by_language[lang] = lines
        for i in ids:
            text = lines[i]
            key = f'holdout:{lang}:{i+1}'
            add(text, lang, key, 'sentence', 'holdout', source=metadata[i]['URL'], split='devtest', id=i+1)
        for i in ids[:24]:
            text = lines[i]
            for length in [8, 20, 50, 120]:
                add(text[:length], lang, f'prefix{length}:{lang}:{i+1}', f'prefix{length}', 'stress', parent=f'holdout:{lang}:{i+1}')
            # Deterministic deletion/Latin lookalike noise, approximately 5% of
            # alphabetic code points. An engineering stressor, not real OCR.
            rng = random.Random('noise:' + lang + ':' + str(i))
            noise = ''.join(('' if rng.random() < 0.5 else {'o':'0','O':'0','l':'1','i':'1','e':'c'}.get(c, c))
                            if c.isalpha() and rng.random() < .05 else c for c in text)
            add(noise, lang, f'noise:{lang}:{i+1}', 'noise5pct', 'stress', parent=f'holdout:{lang}:{i+1}')
        for start in range(0, 30, 3):
            # Same-language concatenation deliberately draws different articles;
            # this tests length, not authentic document context.
            text = ' '.join(lines[i] for i in ids[start:start+3])
            add(text, lang, f'long:{lang}:{start}', 'three_sentences', 'stress')
    # Mixed-language text does not have a single gold label. Report behaviour
    # and instability separately; never count its output as simple accuracy.
    for a, b in [('zh','en'),('en','es'),('en','fr'),('id','ms'),('nb','nn'),('hi','ne'),('ar','ur'),('ja','zh')]:
        for i in ids[:10]:
            for ratio in [0.5, 0.8]:
                left, right = by_language[a][i], by_language[b][i]
                size = min(len(left), len(right))
                text = left[:int(size*ratio)] + ' ' + right[:int(size*(1-ratio))]
                add(text, '', f'mix:{a}:{b}:{ratio}:{i}', 'mixed', 'diagnostic', components=[a,b], firstFraction=ratio)

diagnostics = [
    '', '1234567890 2026/10/11', 'III', 'Chapter 1', 'Fig. 1', 'Hello', 'OK', 'Introduction',
    'www.example.com', 'https://example.com/chapter/123', 'John Smith 2026',
    'qzxw plmk hjgrt vbnm', 'XQZPLMNRST VJWKFBCD GHXYKLMNPQRST', '😀📚🎧✨',
    'Copyright © 2026 All rights reserved.',
    '人工智能领域中的 machine learning 方法正在改变我们的生活。',
    '这是今天的学习内容，我们将继续阅读下一段文字。',
    '私は今日図書館に行き、新しい本を借りました。',
    'The library is open today. Please bring your book and read the next chapter.',
    'ïðàâèëà, ðàçâèòü õîðîøèé ëèòåðàòóðíûé',
]
for i, text in enumerate(diagnostics):
    add(text, '', f'diagnostic:{i}', 'boundary', 'diagnostic',
        note='Authored diagnostic; no general-accuracy claim')
random.Random(61011).shuffle(data)
(OUT / 'inputs-extra.json').write_text(json.dumps(data, ensure_ascii=False))
manifest = {
    'archiveURL':'https://tinyurl.com/flores200dataset',
    'archiveSHA256': hashlib.sha256(ARCHIVE.read_bytes()).hexdigest(),
    'regressionSamples': len(regression), 'regressionLanguages':48,
    'holdoutLanguages':len(mapping), 'holdoutSentencesPerLanguage':100,
    'knownArticles':len(known_sources), 'newArticles':len(selected_sources[:100]),
    'articleOverlap':len(set(selected_sources[:100]) & known_sources),
    'groups':dict(collections.Counter(x['group'] for x in data)),
    'kinds':dict(collections.Counter(x['kind'] for x in data)),
    'limitations':['Same public FLORES domain as regression, not private user traffic.',
                   'Unknown overlap with pretrained models; article-disjoint only from app regression/calibration.',
                   'Translations share semantic ids, variants share parents: samples are not all statistically independent.',
                   'Prefix/noise/mixed text is synthetic; short fragments can lack a uniquely identifiable language.'],
    'languages':mapping,
}
(OUT / 'dataset.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2)+'\n')
print(json.dumps({k:v for k,v in manifest.items() if k not in ['languages','limitations']},indent=2))
