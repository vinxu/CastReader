#!/usr/bin/env python3
"""English-only CTC comparison. Isolated experiment, not a production fallback.

Align a known transcript using acoustic label probabilities and the complete
CTC state path (including repeated-label blanks). Do not infer word timing from
text length. Long audio uses context-overlapped windows with absolute frame
clocks. Unsupported text is rejected, never silently normalized to new speech.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import numpy as np
import torch
from transformers import Wav2Vec2ForCTC, Wav2Vec2Processor

from replay_estimator import decode


def ctc_path(log_probs, token_ids, blank_id=0):
    labels=np.full(2*len(token_ids)+1,blank_id,dtype=np.int32)
    labels[1::2]=token_ids
    skip=np.zeros(len(labels),dtype=bool)
    skip[2:]=(labels[2:]!=blank_id)&(labels[2:]!=labels[:-2])
    previous=np.full(len(labels),-np.inf,dtype=np.float32)
    previous[0]=0
    trace=np.zeros((len(log_probs),len(labels)),dtype=np.int8)
    for t,emission in enumerate(log_probs):
        step=np.r_[-np.inf,previous[:-1]]
        leap=np.r_[-np.inf,-np.inf,previous[:-2]]
        leap[~skip]=-np.inf
        options=np.stack([previous,step,leap])
        selected=options.argmax(axis=0)
        trace[t]=selected
        previous=options[selected,np.arange(len(labels))]+emission[labels]
    state=len(labels)-1 if previous[-1]>=previous[-2] else len(labels)-2
    if not np.isfinite(previous[state]): raise ValueError('No complete CTC alignment')
    states=np.empty(len(log_probs),dtype=np.int32)
    for t in range(len(log_probs)-1,-1,-1):
        states[t]=state
        state-=int(trace[t,state])
    if state!=0:raise ValueError('Incomplete CTC backtrace')
    return states


@torch.inference_mode()
def emissions(audio, model, processor, device):
    sr=16000; center=20*sr; context=2*sr
    all_probs=[];all_times=[]
    for pos in range(0,len(audio),center):
        left=max(0,pos-context);right=min(len(audio),pos+center+context)
        inputs=processor(audio[left:right],sampling_rate=sr,return_tensors='pt').input_values.to(device)
        logits=model(inputs).logits[0]
        probs=logits.float().log_softmax(-1).cpu().numpy()
        # Wav2Vec2 convolution has a 400-sample receptive field and 320-sample stride.
        times=(left+200+320*np.arange(len(probs)))/sr
        keep=(times>=pos/sr)&(times<min(len(audio),pos+center)/sr)
        all_probs.append(probs[keep]);all_times.append(times[keep])
    return np.concatenate(all_probs),np.concatenate(all_times)


def align_words(log_probs,times,words,vocab):
    tokens=[];ranges=[]
    for word in words:
        spelling=word.replace('’',"'").upper()
        if not spelling or any(c not in vocab or c in '<>|' for c in spelling):
            raise ValueError('Unsupported English CTC spelling: '+word)
        if tokens:tokens.append(vocab['|'])
        first=len(tokens)
        tokens.extend(vocab[c] for c in spelling)
        ranges.append((first,len(tokens)))
    states=ctc_path(log_probs,tokens,vocab['<pad>'])
    result=[]
    for word,(first,last) in zip(words,ranges):
        frame_indexes=np.flatnonzero((states>=first*2+1)&(states<last*2)&(states%2==1))
        if not len(frame_indexes):raise ValueError('Unaligned word')
        scores=[log_probs[t,tokens[(states[t]-1)//2]] for t in frame_indexes]
        result.append({'text':word,'start_time':round(max(0,times[frame_indexes[0]]-.01),6),
                       'end_time':round(times[frame_indexes[-1]]+.01,6),
                       'mean_character_posterior':float(np.exp(np.mean(scores)))})
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--repeats',type=int,default=1)
    parser.add_argument('--ids',nargs='*');args=parser.parse_args()
    torch.set_num_threads(4);device='mps'
    model_id='facebook/wav2vec2-base-960h';revision='22aad52d435eb6dbaf354bdad9b0da84ce7d6156'
    start=time.perf_counter()
    processor=Wav2Vec2Processor.from_pretrained(model_id,revision=revision)
    model=Wav2Vec2ForCTC.from_pretrained(model_id,revision=revision,attn_implementation='eager').to(device).eval()
    torch.mps.synchronize()
    root=Path('build/alignment-evidence')
    result={'model':model_id,'revision':revision,'device':device,'language':'English only',
            'load_ms_including_download':(time.perf_counter()-start)*1000,'rows':[]}
    print(json.dumps({k:v for k,v in result.items() if k!='rows'}),flush=True)
    rows=json.loads((root/'manifest.json').read_text())
    if args.ids:rows=[r for r in rows if r['id'] in args.ids]
    for row in sorted(rows,key=lambda r:r['duration']):
        audio,_=decode(root/row['audio'],16000)
        for repeat in range(args.repeats):
            started=time.perf_counter()
            try:
                probs,times=emissions(audio,model,processor,device)
                words=align_words(probs,times,[t[0] for t in row['original_timestamps']],processor.tokenizer.get_vocab())
                torch.mps.synchronize()
                item={'id':row['id'],'repeat':repeat,'elapsed_ms':(time.perf_counter()-started)*1000,'words':words,
                      'zero_or_negative':int(sum(w['start_time']>=w['end_time'] for w in words)),
                      'mps_driver_allocated_bytes':torch.mps.driver_allocated_memory()}
            except Exception as error:
                item={'id':row['id'],'repeat':repeat,'error':str(error)}
            result['rows'].append(item)
            (root/f'ctc-mps-{args.repeats}.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
            print(json.dumps({k:v for k,v in item.items() if k!='words'}),flush=True)


if __name__=='__main__':main()
