#!/usr/bin/env python3
from __future__ import annotations

import argparse
import base64
from difflib import SequenceMatcher
import html
import json
from pathlib import Path
import re
import statistics

import whisper


def normalize(word: str) -> str:
    return re.sub(r"[^a-z0-9']", "", word.lower().replace("’", "'"))


def percentile(values: list[float], fraction: float) -> float:
    values = sorted(values)
    position = max(0, min(len(values) - 1, round((len(values) - 1) * fraction)))
    return values[position]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--audio", type=Path, required=True)
    parser.add_argument("--timestamps", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--whisper-model", default="small.en")
    args = parser.parse_args()
    predicted = json.loads(args.timestamps.read_text())
    evaluator = whisper.load_model(args.whisper_model)
    result = evaluator.transcribe(str(args.audio), language="en", word_timestamps=True)
    reference = [
        {"word": word["word"].strip(), "start": float(word["start"]), "end": float(word["end"])}
        for segment in result["segments"] for word in segment.get("words", [])
    ]
    predicted_words = [normalize(item["word"]) for item in predicted["words"]]
    reference_words = [normalize(item["word"]) for item in reference]
    matcher = SequenceMatcher(a=predicted_words, b=reference_words, autojunk=False)
    pairs: list[tuple[int, int]] = []
    for block in matcher.get_matching_blocks():
        for offset in range(block.size):
            pairs.append((block.a + offset, block.b + offset))
    start_errors = [
        abs(float(predicted["words"][left]["start"]) - reference[right]["start"])
        for left, right in pairs
    ]
    end_errors = [
        abs(float(predicted["words"][left]["end"]) - reference[right]["end"])
        for left, right in pairs
    ]
    metrics = {
        "predicted_words": len(predicted_words),
        "reference_words": len(reference_words),
        "matched_words": len(pairs),
        "coverage": len(pairs) / len(predicted_words),
        "start_error_median_ms": statistics.median(start_errors) * 1000,
        "start_error_p95_ms": percentile(start_errors, 0.95) * 1000,
        "end_error_median_ms": statistics.median(end_errors) * 1000,
        "end_error_p95_ms": percentile(end_errors, 0.95) * 1000,
        "whisper_text": result["text"].strip(),
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "evaluation.json").write_text(
        json.dumps({"metrics": metrics, "reference": reference}, indent=2), encoding="utf-8"
    )
    audio_mime = "audio/mpeg" if args.audio.suffix.lower() == ".mp3" else "audio/wav"
    audio_uri = f"data:{audio_mime};base64," + base64.b64encode(args.audio.read_bytes()).decode()
    words_json = json.dumps(predicted["words"], separators=(",", ":"))
    metrics_json = html.escape(json.dumps(metrics, indent=2))
    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
<title>Qwen native timestamp head POC</title>
<style>
body{{font:17px/1.75 system-ui,sans-serif;max-width:920px;margin:40px auto;padding:0 22px;color:#18212f}}
h1{{font-size:25px}} audio{{width:100%;margin:12px 0 24px}} #words{{font-size:22px;line-height:2.05}}
.word{{padding:3px 4px;border-radius:6px;transition:.08s;background:#f3f5f8}}
.active{{background:#ffd65a;color:#111;box-shadow:0 0 0 2px #efb900}}
.past{{color:#657083;background:#eef1f5}} pre{{background:#111827;color:#dbeafe;padding:16px;border-radius:10px;overflow:auto}}
</style></head><body>
<h1>Qwen3-TTS 0.6B · native timestamp-head POC</h1>
<p>Press play and watch whether the yellow word follows the voice. Resolution: 80 ms per acoustic frame.</p>
<audio id="audio" controls src="{audio_uri}"></audio><div id="words"></div>
<h2>Offline evaluator metrics</h2><pre>{metrics_json}</pre>
<script>
const words={words_json}, box=document.querySelector('#words'), audio=document.querySelector('#audio');
words.forEach((w,i)=>{{const s=document.createElement('span');s.className='word';s.textContent=w.word;s.dataset.i=i;box.append(s,' ');}});
const spans=[...document.querySelectorAll('.word')]; let active=-1;
function paint(){{const t=audio.currentTime;let next=words.findIndex(w=>t>=w.start&&t<w.end);if(next<0){{next=words.findLastIndex(w=>t>=w.start)}}if(next===active)return;active=next;spans.forEach((s,i)=>s.className='word '+(i===active?'active':i<active?'past':'  '));if(active>=0)spans[active].scrollIntoView({{block:'nearest'}})}}
audio.addEventListener('timeupdate',paint);audio.addEventListener('seeked',paint);requestAnimationFrame(paint);
</script></body></html>"""
    (args.output / "demo.html").write_text(page, encoding="utf-8")
    print(json.dumps(metrics), flush=True)


if __name__ == "__main__":
    main()
