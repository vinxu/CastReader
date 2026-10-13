"""Opt-in bounded localhost TTS experiment using an existing synthetic test voice.

    No public gateway, account quota, voice creation, or production deployment.
    Stop if the worker has unrelated queued work. Never print the local token.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import time

import httpx
import soundfile as sf
import torch

from benchmark_pipeline import write_json
from caption_pipeline import CaptionPipeline, QwenPCMAligner, encode_gapless, prepare_pcm


SAMPLES = {
    "en": "On the nineteenth day, the little train stopped beside the river. The conductor counted thirty one tickets, then quietly closed the door.",
    "de": "Am Morgen öffnete Anna das Fenster. Draußen sangen die Vögel, und die Sonne schien über den ruhigen Garten.",
    "es": "Por la mañana, Ana abrió la ventana. Los pájaros cantaban y el sol iluminaba el jardín tranquilo.",
    "fr": "Ce matin, Marie a ouvert la fenêtre. Les oiseaux chantaient doucement dans le jardin, puis le train est arrivé.",
    "it": "Questa mattina Anna ha aperto la finestra. Gli uccelli cantavano nel giardino e il sole illuminava la casa.",
    "pt": "Naquela manhã, Ana abriu a janela. Os pássaros cantavam no jardim e o sol iluminava a casa.",
    "ru": "Утром Анна открыла окно. В саду пели птицы, а солнечный свет медленно наполнял тихую комнату.",
    "zh": "早上，小林打开窗户。花园里的小鸟正在唱歌，阳光慢慢照进安静的房间。",
    "ja": "朝、窓を開けると、庭で小鳥が歌っていました。暖かい光が静かな部屋に入りました。",
    "ko": "아침에 창문을 열었습니다. 정원에서는 작은 새들이 노래하고 따뜻한 햇빛이 방 안으로 들어왔습니다.",
}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--voice", choices=["vc_e2e_generated_test", "vc_quality_e2e_20260826"], required=True)
    parser.add_argument("--repeats", type=int, default=6)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    torch.set_num_threads(4)
    free, total = torch.cuda.mem_get_info()
    if free < 6 * 1024**3:
        raise RuntimeError("insufficient-free-vram")
    torch.cuda.set_per_process_memory_fraction(.20)
    result = {"first_segment": [], "next_segment": [], "languages": [],
              "limits": "small bounded test, not a sustained production throughput test"}
    client = httpx.Client(base_url="http://127.0.0.1:18890", timeout=65,
                          headers={"X-Clone-Token": args.token_file.read_text().strip(),
                                   "X-TTS-Priority": "prefetch"})

    def idle():
        health = client.get("/health").raise_for_status().json()
        if health["busy"] or health["queue_depth"]:
            raise RuntimeError("unrelated-worker-traffic-abort")
        free, total = torch.cuda.mem_get_info()
        if free < 3 * 1024**3:
            raise RuntimeError("gpu-headroom-abort")
        return {key: health[key] for key in ["status", "submitted", "completed", "failed", "expired"]}

    def synthesize(text, language="en"):
        started = time.perf_counter()
        response = client.post("/v1/speech", json={"text": text, "language_id": language, "voice_id": args.voice})
        response.raise_for_status()
        pcm = prepare_pcm(response.content)
        return pcm, {"tts_ms": (time.perf_counter() - started) * 1000,
                     "audio_seconds": pcm.duration,
                     "headers": {key: value for key, value in response.headers.items()
                                 if key in {"x-tts-queue-wait-ms", "x-tts-run-ms"}}}

    result["before_health"] = idle()
    aligner = QwenPCMAligner("cuda:0", str(args.model))
    pipeline = CaptionPipeline(aligner, alignment_budget_s=5)
    try:
        idle()
        warm_pcm, warm_timing = synthesize(SAMPLES["en"])
        aligner(warm_pcm, SAMPLES["en"], "en")
        result["warmup"] = warm_timing
        for repeat in range(args.repeats):
            modes = ["baseline", "serial", "overlap"]
            modes = modes[repeat % 3:] + modes[:repeat % 3]
            for mode in modes:
                idle()
                started = time.perf_counter()
                pcm, timing = synthesize(SAMPLES["en"])
                post_started = time.perf_counter()
                if mode == "baseline":
                    encode_gapless(pcm)
                    post = {"postprocess_ms": (time.perf_counter() - post_started) * 1000}
                    reason = "no-alignment"
                else:
                    caption = pipeline.caption(pcm, text=SAMPLES["en"], language="en", voice_code=args.voice,
                                               overlap=mode == "overlap")
                    post, reason = caption.timings, caption.reason
                record = {"repeat": repeat, "mode": mode, "reason": reason,
                          "total_ms": (time.perf_counter() - started) * 1000, **timing, **post}
                result["first_segment"].append(record)
                print(json.dumps({"phase": "first", **record}), flush=True)
                write_json(args.output / "results.json", result)
        with ThreadPoolExecutor(max_workers=1) as generator:
            for repeat in range(args.repeats):
                for mode in (["tts-alone", "tts-with-alignment"] if repeat % 2 == 0 else
                             ["tts-with-alignment", "tts-alone"]):
                    idle()
                    started = time.perf_counter()
                    future = generator.submit(synthesize, SAMPLES["en"])
                    post = {}
                    if mode == "tts-with-alignment":
                        caption = pipeline.caption(warm_pcm, text=SAMPLES["en"], language="en", voice_code=args.voice)
                        post = caption.timings
                    pcm, timing = future.result()
                    result["next_segment"].append({"repeat": repeat, "mode": mode, **timing,
                                                  "both_ready_ms": (time.perf_counter() - started) * 1000,
                                                  "previous_alignment": post})
                    write_json(args.output / "results.json", result)
        fixtures = []
        for language, text in SAMPLES.items():
            idle()
            pcm, timing = synthesize(text, language)
            caption = pipeline.caption(pcm, text=text, language=language, voice_code=args.voice)
            response = dict(caption.response, voice_code="vc_alignment_fixture")
            fixtures.append({"id": "live-" + language, "language": language, "text": text,
                             "duration": caption.duration, "response": response})
            sf.write(args.output / ("live-" + language + ".wav"), pcm.samples, pcm.sample_rate)
            result["languages"].append({"language": language, "text": text, "reason": caption.reason,
                                        "timestamps": caption.response["timestamps"], **timing, **caption.timings})
            print(json.dumps({"phase": "language", "language": language, "reason": caption.reason}), flush=True)
            write_json(args.output / "results.json", result)
        write_json(args.output / "client-fixtures.json", fixtures)
        result["after_health"] = idle()
        result["peak_allocated_bytes"] = torch.cuda.max_memory_allocated()
        result["peak_reserved_bytes"] = torch.cuda.max_memory_reserved()
        write_json(args.output / "results.json", result)
    finally:
        pipeline.close()
        client.close()


if __name__ == "__main__":
    main()
