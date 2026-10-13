#!/usr/bin/env python3
"""Compare routing risk and coverage. Calibrate ONLY on known regression/dev.

No result here edits production policy. 'no' stays ambiguous: never silently
equate the small model's Norwegian macrolanguage with product Bokmal.
"""
import collections, csv, gzip, hashlib, json, pathlib, statistics
ROOT = pathlib.Path(__file__).resolve().parents[2]
OUT = ROOT / 'reports/ios-language-research-20261011'
SUPPORTED = set('en zh ja es fr de pt it hi nl ko ar ru pl sv da nb fi cs el hu fil he id ms ro tr vi'.split())
AMBIGUOUS = {'', 'no', 'und'}
FAMILIES = {'id','ms','nb','nn','da'}

def read(name):
    path=OUT/name
    return json.loads(path.read_text() if path.exists() else gzip.decompress(path.with_suffix(path.suffix+'.gz').read_bytes()))
def best(c): return max(c, key=c.get) if c else ''
def accepted(c, threshold):
    top = best(c)
    return top if top not in AMBIGUOUS and c[top]>=threshold else ''

reg = read('inputs-regression.json')
prod_reg = {x['key']:x for x in read('production-regression.json')['results']}
small_reg = {x['key']:x for x in read('small-regression.json')['results']}

def agree(row, prod, small, nmin, smin, letters):
    native, compact = prod['native'], small['candidates']
    n, s = best(native), best(compact)
    if (prod['count'] >= letters and n==s and n not in AMBIGUOUS|FAMILIES
            and native[n] >= nmin and compact[s] >= smin):
        return n
    return ''

# Selection is completely determined by calibration data, never new holdout.
calibration = [x for x in reg if x['split']=='dev']
grid = []
for nmin in [.95,.98,.99]:
    for smin in [.5,.7,.8,.9,.95]:
        for letters in [40,80,120]:
            counts = collections.Counter()
            for row in calibration:
                key = row['key']; truth=row['language']
                output = agree(row,prod_reg[key],small_reg[key],nmin,smin,letters)
                if output:
                    counts['accepted']+=1
                    if output in SUPPORTED and output!=truth: counts['misroute']+=1
                    if output==truth and truth in SUPPORTED: counts['correctSupported']+=1
                    if truth in SUPPORTED and output not in SUPPORTED: counts['falseUnsupported']+=1
            grid.append(dict(nativeThreshold=nmin,smallThreshold=smin,minimumLetters=letters,**counts))
eligible = [x for x in grid if x.get('misroute',0)==0 and x.get('falseUnsupported',0)==0]
selected = max(eligible,key=lambda x:(x.get('correctSupported',0), x['nativeThreshold'],x['smallThreshold'],x['minimumLetters']))
selection = dict(selected, closeFamiliesAlwaysEscalate=sorted(FAMILIES),
                 calibratedOn='Known regression/dev only; 7344 rows; no claim of independent model-training holdout',
                 considered=grid)
(OUT/'candidate-policy.json').write_text(json.dumps(selection,indent=2)+'\n')

rows = reg + read('inputs-extra.json') + read('inputs-ud-yue.json')
prod = dict(prod_reg,**{x['key']:x for x in read('production-extra.json')['results']})
small = dict(small_reg,**{x['key']:x for x in read('small-extra.json')['results']})
prod.update({x['key']:x for x in read('production-ud-yue.json')['results']})
small.update({x['key']:x for x in read('small-ud-yue.json')['results']})
predictions = {}
for row in rows:
    key = row['key']; p=prod[key]; s=small[key]
    a=agree(row,p,s,selected['nativeThreshold'],selected['smallThreshold'],selected['minimumLetters'])
    predictions[key] = {
        'apple_raw':best(p['native']), 'small_raw':best(s['candidates']),
        'glot_raw':best(p['candidates']), 'apple_95':accepted(p['native'],.95),
        'small_95':accepted(s['candidates'],.95), 'production':p['output'],
        'agreement_no_glot':a, 'cascade_with_glot':a or p['output'],
        'production_missing_glot':p['missingModelOutput'],
    }

def metrics(subset, model):
    c=collections.Counter(total=len(subset))
    mistakes=[]
    for row in subset:
        truth=row['language']; output=predictions[row['key']][model]
        supported=truth in SUPPORTED
        c['supportedInputs' if supported else 'unsupportedInputs']+=1
        if output==truth: c['exactCorrect']+=1
        if output not in AMBIGUOUS:
            c['accepted']+=1
            if supported and output==truth: c['correctSupported']+=1
            if output in SUPPORTED and output!=truth:
                c['wrongSupportedRoute']+=1
                c['wrongFromSupported' if supported else 'wrongFromUnsupported']+=1
                mistakes.append(dict(key=row['key'],truth=truth,output=output,text=row['text']))
            if supported and output not in SUPPORTED: c['falseUnsupported']+=1
            if not supported and output not in SUPPORTED: c['correctUnsupportedRejection']+=1
        else:
            c['abstain']+=1
            c['abstainSupported' if supported else 'abstainUnsupported']+=1
    c['supportedCoveragePct']=100*c['correctSupported']/max(1,c['supportedInputs'])
    c['wrongRoutePct']=100*c['wrongSupportedRoute']/max(1,len(subset))
    return dict(c), mistakes

models=list(next(iter(predictions.values())))
cohorts={
    'known_calibration_dev':[x for x in reg if x['split']=='dev'],
    'known_regression_devtest':[x for x in reg if x['split']=='devtest'],
    'new_article_holdout':[x for x in rows if x['group']=='holdout'],
    'new_article_holdout_without_disputed_yue':[x for x in rows if x['group']=='holdout' and x['language']!='yue'],
    'flores_yue_disputed_label':[x for x in rows if x['group']=='holdout' and x['language']=='yue'],
    'ud_yue_spoken_transcripts':[x for x in rows if x['group']=='ud_yue'],
}
for kind in ['prefix8','prefix20','prefix50','prefix120','noise5pct','three_sentences']:
    cohorts[kind]=[x for x in rows if x['kind']==kind]
summary={}; errors={}; per_language=[]
for name,subset in cohorts.items():
    summary[name]={};errors[name]={}
    for model in models:
        summary[name][model],errors[name][model]=metrics(subset,model)
        for language in sorted({x['language'] for x in subset}):
            m,_=metrics([x for x in subset if x['language']==language],model)
            per_language.append(dict(cohort=name,model=model,language=language,**m))

performance={}
for name in ['native','small','glot','production']:
    docs=[read(f'performance-{name}-{i}.json') for i in range(5)]
    warm=sorted(x['ms'] for d in docs for x in d['results'][1:])
    performance[name]={
        'coldFirstInferenceMilliseconds':[d['results'][0]['ms'] for d in docs],
        'coldMedianMilliseconds':statistics.median(d['results'][0]['ms'] for d in docs),
        'warmMedianMilliseconds':statistics.median(warm), 'warmP95Milliseconds':warm[int((len(warm)-1)*.95)],
        'medianResidentIncreaseFirstBytes':statistics.median(d['residentAfterFirst']-d['residentBefore'] for d in docs),
        'medianPeakResidentBytes':statistics.median(d['residentPeakSampled'] for d in docs),
        'firstInput': docs[0]['results'][0]['key'],
        'scope':'Five fresh processes, 200 identical public sentences each, English first; warm filesystem cache, simulator host CPU; RSS includes frameworks and allocator.'
    }

summary['performance']=performance
summary['candidate']=selected
summary['scope']={
    'platform':read('production-extra.json')['platform'], 'os':read('production-extra.json')['os'],
    'totalInputs':len(rows),'newIndependentArticles':100,
    'productionPolicyChanged':False,
    'meaning':'Wrong route = confidently output a supported TTS language different from input. Unsupported rejection is counted separately from abstention.',
    'limits':read('dataset.json')['limitations'] + ['iOS 17.6 and physical-device timing not measured. No network/TTS playback involved.',
        'Model scores are not calibrated probabilities. Zero observed errors is not a guarantee.',
        'FLORES-200 Yue label-quality issue found during error analysis; report full strict labels AND a separate 67-language cohort, never silently relabel. See facebookresearch/flores#61 and separate UD Cantonese-HK results.',
        'All candidate policies are offline replay experiments, not integrated application behaviour.'],
}
summary['modelFiles']={}
for name,path in [('small',pathlib.Path('/tmp/CastReaderLanguageResearch20261011/lid.176.ftz')),
                  ('glot',ROOT/'CastReader/Resources/LanguageIdentification/glotlid-v3-q300k.ftz')]:
    summary['modelFiles'][name]=dict(bytes=path.stat().st_size,sha256=hashlib.sha256(path.read_bytes()).hexdigest())
(OUT/'summary.json').write_text(json.dumps(summary,indent=2,ensure_ascii=False)+'\n')
(OUT/'errors.json').write_text(json.dumps(errors,indent=2,ensure_ascii=False)+'\n')
diagnostics=[]
for row in rows:
    if row['group']=='diagnostic':
        diagnostics.append(dict(row,outputs=predictions[row['key']], native=prod[row['key']]['native'],
                                glot=prod[row['key']]['candidates'],small=small[row['key']]['candidates']))
(OUT/'diagnostics.json').write_text(json.dumps(diagnostics,ensure_ascii=False,indent=2)+'\n')
fields=['cohort','model','language']+sorted(set().union(*(x.keys() for x in per_language))-{'cohort','model','language'})
with (OUT/'per-language.csv').open('w') as f:
    w=csv.DictWriter(f,fieldnames=fields);w.writeheader();w.writerows(per_language)
print('CANDIDATE',json.dumps(selected))
print('NEW ARTICLE HOLDOUT',json.dumps(summary['new_article_holdout'],indent=2))
print('PERFORMANCE',json.dumps(performance,indent=2))
