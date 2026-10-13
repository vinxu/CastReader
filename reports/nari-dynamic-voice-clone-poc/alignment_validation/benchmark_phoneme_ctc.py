from __future__ import annotations

import argparse
import json
from pathlib import Path
import time

import numpy as np
import torch
from transformers import Wav2Vec2FeatureExtractor, Wav2Vec2ForCTC

from alignment_contract import lexical_key
from benchmark_ctc import ctc_path, emissions
from caption_pipeline import project_words
from replay_estimator import decode


MODEL_REVISION = "2c733782da5604684829819a5eb744c193fe9398"


def make_lexicon(root, output):
    from phonemizer.backend import EspeakBackend
    from phonemizer.separator import Separator

    manifest = json.loads((root / "evidence/manifest.json").read_text())
    live = json.loads((root / "live-tts/client-fixtures.json").read_text())
    cases = [dict(identity=row["id"], path="evidence/" + row["audio"],
                  text=row["text"], language="en") for row in manifest]
    cases.extend(dict(identity=row["id"], path=f'live-tts/{row["id"]}.wav',
                      text=row["text"], language=row["language"])
                 for row in live if row["language"] not in {"zh", "ja", "ko"})
    backends = {}
    for case in cases:
        language = case["language"]
        if language not in backends:
            backends[language] = EspeakBackend(
                {"en": "en-us", "pt": "pt-br", "fr": "fr-fr"}.get(language, language),
                language_switch="remove-flags", with_stress=False,
            )
        words = [word for word in case["text"].split() if lexical_key(word)]
        separator = Separator(phone=" ", word=" | ", syllable="")
        isolated = backends[language].phonemize(words, separator=separator, strip=True)
        counts = [len([group for group in phones.split("|") if group.strip()]) for phones in isolated]
        contextual = backends[language].phonemize([" ".join(words)], separator=separator, strip=True)[0]
        groups = [group.split() for group in contextual.split("|") if group.strip()]
        if len(groups) != sum(counts):
            raise ValueError(f'pronunciation-boundary-mismatch:{case["identity"]}')
        case["tokens"] = []
        offset = 0
        for word, count in zip(words, counts):
            case["tokens"].append(dict(text=word, phonemes=[phone for group in groups[offset:offset + count] for phone in group]))
            offset += count
    output.write_text(json.dumps(cases, ensure_ascii=False, indent=2))


def align_phonemes(probs, times, tokens, vocabulary):
    labels = []
    spans = []
    for token in tokens:
        start = len(labels)
        for phoneme in token["phonemes"]:
            if phoneme not in vocabulary or vocabulary[phoneme] == vocabulary["<unk>"]:
                raise ValueError("unsupported-phoneme:" + phoneme)
            labels.append(vocabulary[phoneme])
        if start == len(labels):
            raise ValueError("empty-pronunciation")
        spans.append((start, len(labels)))
    states = ctc_path(probs, labels, vocabulary["<pad>"])
    words = []
    for token, (start, end) in zip(tokens, spans):
        frames = np.flatnonzero((states >= start * 2 + 1) & (states < end * 2) & (states % 2 == 1))
        scores = [probs[index, labels[(states[index] - 1) // 2]] for index in frames]
        words.append(dict(text=token["text"], start_time=round(max(0.0, times[frames[0]] - .01), 6),
                          end_time=round(times[frames[-1]] + .01, 6),
                          mean_phone_posterior=float(np.exp(np.mean(scores)))))
    return words


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--lexicon", type=Path, required=True)
    parser.add_argument("--make-lexicon", action="store_true")
    parser.add_argument("--model", type=Path)
    parser.add_argument("--device", default="cuda:0")
    args = parser.parse_args()
    if args.make_lexicon:
        make_lexicon(args.root, args.lexicon)
        return
    torch.set_num_threads(4)
    if args.device.startswith("cuda"):
        if torch.cuda.mem_get_info()[0] < 6 * 1024**3:
            raise RuntimeError("insufficient-gpu-headroom")
        torch.cuda.set_per_process_memory_fraction(.20)
    model = Wav2Vec2ForCTC.from_pretrained(args.model, local_files_only=True,
                                          attn_implementation="eager").to(args.device).eval()
    processor = Wav2Vec2FeatureExtractor.from_pretrained(args.model, local_files_only=True)
    vocabulary = json.loads((args.model / "vocab.json").read_text())
    results = []
    for case in json.loads(args.lexicon.read_text()):
        started = time.perf_counter()
        audio, _ = decode(args.root / case["path"], 16000)
        try:
            probs, times = emissions(audio, model, processor, args.device)
            words = align_phonemes(probs, times, case["tokens"], vocabulary)
            projected = project_words(case["text"], words, len(audio) / 16000)
            result = dict(id=case["identity"], words=words, timestamps=projected, reason="accepted",
                          minimum_posterior=min(word["mean_phone_posterior"] for word in words))
        except Exception as error:
            result = dict(id=case["identity"], reason=str(error))
        result["elapsed_ms"] = (time.perf_counter() - started) * 1000
        results.append(result)
        filename = "phoneme-ctc-" + args.device.replace(":", "-") + ".json"
        (args.root / filename).write_text(json.dumps(results, ensure_ascii=False, indent=2))
        print(json.dumps({key: value for key, value in result.items()
                          if key not in {"words", "timestamps"}}), flush=True)


if __name__ == "__main__":
    main()
