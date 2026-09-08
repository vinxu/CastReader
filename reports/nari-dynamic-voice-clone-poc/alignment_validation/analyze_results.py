#!/usr/bin/env python3
from __future__ import annotations

from difflib import SequenceMatcher
import json
from pathlib import Path
import statistics

from alignment_contract import AlignmentRejected, lexical_key, to_worker_timestamps


def distribution(values):
    if not values: return None
    values = sorted(values)
    return {"n":len(values),"median":statistics.median(values),
            "p95":values[min(len(values)-1, int(.95*len(values)))],"max":max(values)}


def errors(timestamps, reference):
    source=[lexical_key(t[0]) for t in timestamps]
    refs=[lexical_key(w['word']) for w in reference]
    deltas=[]
    for block in SequenceMatcher(a=source,b=refs,autojunk=False).get_matching_blocks():
        for offset in range(block.size):
            s=timestamps[block.a+offset];r=reference[block.b+offset]
            deltas.append({'word':s[0],'source_index':block.a+offset,'start':s[1],
                           'reference_start':r['start'],'start_error_ms':abs(s[1]-r['start'])*1000,
                           'end_error_ms':abs(s[2]-r['end'])*1000})
    return deltas


def main():
    root=Path('build/alignment-evidence')
    manifest=json.loads((root/'manifest.json').read_text())
    references={r['id']:r['reference'] for r in json.loads((root/'whisper-reference.json').read_text())}
    forced_file=root/'forced-mps-1.json'
    forced={r['id']:r for r in json.loads(forced_file.read_text())['rows']} if forced_file.exists() else {}
    ctc_file=root/'ctc-mps-1.json'
    ctc={r['id']:r for r in json.loads(ctc_file.read_text())['rows']} if ctc_file.exists() else {}
    records=[];old_all=[];new_all=[];old_normal=[];new_normal=[];ctc_all=[];ctc_old=[]
    for row in manifest:
        reference=[w for s in references[row['id']]['segments'] for w in s.get('words',[])]
        old=errors(row['original_timestamps'],reference)
        old_all+=old
        if row['id']!='phone-14':old_normal+=old
        item={'id':row['id'],'word_count':len(row['original_timestamps']),
              'matched_reference_words':len(old),'original_error_ms':distribution([x['start_error_ms'] for x in old]),
              'original_vs_reference':old}
        candidate=forced.get(row['id'])
        if candidate and 'words' in candidate:
            words=candidate['words']
            new=errors([(w['text'],w['start_time'],w['end_time']) for w in words],reference)
            new_all+=new
            if row['id']!='phone-14':new_normal+=new
            item.update(forced_error_ms=distribution([x['start_error_ms'] for x in new]),forced_vs_reference=new,
                        elapsed_ms=candidate['elapsed_ms'])
            try:
                item['projected_timestamps']=to_worker_timestamps(
                    [t[0] for t in row['original_timestamps']],words,duration=row['duration'])
                item['projection']='accepted'
            except AlignmentRejected as exc:
                item['projection']=str(exc)
        candidate=ctc.get(row['id'])
        if candidate and 'words' in candidate:
            words=candidate['words']
            deltas=errors([(w['text'],w['start_time'],w['end_time']) for w in words],reference)
            ctc_all+=deltas;ctc_old+=old
            item['ctc_error_ms']=distribution([x['start_error_ms'] for x in deltas])
            item['ctc_vs_reference']=deltas
            item['ctc_timestamps']=to_worker_timestamps([t[0] for t in row['original_timestamps']],words,duration=row['duration'])
        elif candidate:
            item['ctc_rejection']=candidate.get('error')
        records.append(item)
    out={'reference_limitation':'Whisper Base is independent corroboration, not human word-boundary ground truth.',
         'original_start_error_ms':distribution([e['start_error_ms'] for e in old_all]),
         'forced_start_error_ms':distribution([e['start_error_ms'] for e in new_all]),
         'original_excluding_94s':distribution([e['start_error_ms'] for e in old_normal]),
         'forced_excluding_94s':distribution([e['start_error_ms'] for e in new_normal]),
         'ctc_start_error_ms':distribution([e['start_error_ms'] for e in ctc_all]),
         'original_on_ctc_supported_samples':distribution([e['start_error_ms'] for e in ctc_old]),
         'rows':records}
    (root/'comparison.json').write_text(json.dumps(out,ensure_ascii=False,indent=2))
    print(json.dumps({k:v for k,v in out.items() if k!='rows'},indent=2))
    print('Projection:',[(r['id'],r.get('projection')) for r in records])


if __name__=='__main__':main()
