#!/usr/bin/env python3
"""Explicitly gated GPU acceptance for an ALREADY approved isolated candidate.

Never starts services, imports/registers/deletes voices, writes audio, or prints
credentials/text. Root must approve verified backups and capacity FIRST. Uses two
operator-owned canary voices already restored into this candidate's own root.
This probe is not an authorization mechanism or an acoustic/ASR quality verdict.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import math
import re
import subprocess
import sys
import time
from pathlib import Path

import httpx
from fastapi import HTTPException

SOURCE = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(SOURCE / "worker"), str(SOURCE / "nari-qwen3-tts/src")]
from nari_completion_client import CLONE_COMPLETION_HEADER, collect_completed_wav
from nari_qwen3_tts.completion_protocol import MEDIA_TYPE, CompletionDecoder, CompletionProtocolError, request_fingerprint


TEXTS = {
    "en": "On September 3, 2026, the report cost $24.50. Read the final sentence completely.",
    "zh": "今天是二零二六年九月三日。请把最后一句完整读完。",
    "ja": "今日は九月三日です。最後の文章まで読んでください。",
    "ko": "오늘은 구월 삼일입니다. 마지막 문장까지 모두 읽어 주세요.",
    "fr": "Le rapport est prêt. Veuillez lire entièrement la dernière phrase.",
    "de": "Der Bericht ist fertig. Bitte lesen Sie den letzten Satz vollständig.",
    "it": "Il rapporto è pronto. Leggi completamente l'ultima frase.",
    "pt": "O relatório está pronto. Leia a última frase completamente.",
    "ru": "Отчёт готов. Прочитайте последнее предложение полностью.",
    "es": "El informe está listo. Lee la última frase completamente.",
}


def validate_media(body: dict, voice: str, language: str) -> dict:
    if set(body) != {"audio", "audio_format", "timestamps", "voice_code"}:
        raise ValueError("public success body is not the four-field contract")
    if body["voice_code"] != voice or body["audio_format"] != "audio/mpeg":
        raise ValueError("voice or format mismatch")
    media = base64.b64decode(body["audio"], validate=True)
    decoded = subprocess.run(
        ["ffmpeg", "-v", "error", "-xerror", "-i", "pipe:0", "-f", "f32le", "-ar", "24000", "-ac", "1", "pipe:1"],
        input=media, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20, check=True,
    ).stdout
    if not decoded or len(decoded) % 4:
        raise ValueError("invalid decoded audio")
    duration = len(decoded) / (4 * 24000)
    timestamps = body["timestamps"]
    if not isinstance(timestamps, list) or (language in {"zh", "ja", "ko"} and timestamps):
        raise ValueError("invalid CJK segment timestamp contract")
    if language not in {"zh", "ja", "ko"} and not timestamps:
        raise ValueError("missing alphabetic word timestamps")
    previous_start = previous_end = -1.0
    for cue in timestamps:
        start, end = cue.get("start_time"), cue.get("end_time")
        if any(isinstance(v, bool) or not isinstance(v, (int, float)) or not math.isfinite(v) for v in [start, end]):
            raise ValueError("nonfinite cue")
        if start < 0 or end <= start or start < previous_start or end < previous_end or end > duration + 0.001:
            raise ValueError("cue ordering or final decoded media bound mismatch")
        previous_start, previous_end = start, end
    return {"mp3_sha256": hashlib.sha256(media).hexdigest(), "mp3_bytes": len(media),
            "decoded_duration_seconds": round(duration, 6), "cues": len(timestamps)}


def run(args):
    if not args.allow_gpu_after_backup_and_capacity_approval:
        raise SystemExit("Refusing GPU inference: verified backups and capacity approval are required first")
    if args.voice_a == args.voice_b or not all(re.fullmatch(r"vc_[A-Za-z0-9_-]{1,61}", value) for value in [args.voice_a, args.voice_b]):
        raise SystemExit("Two distinct operator-owned canary voice IDs are required")
    token = args.token_file.read_text().strip()
    if not token or any(ord(c) < 33 or ord(c) > 126 for c in token):
        raise SystemExit("Invalid candidate token file")
    worker_port, nari_port = (18990, 18095) if args.region == "us" else (28890, 28095)
    worker_url, nari_url = f"http://127.0.0.1:{worker_port}", f"http://127.0.0.1:{nari_port}"
    with httpx.Client(timeout=120, trust_env=False) as client:
        client.get(worker_url + "/health").raise_for_status()
        client.get(nari_url + "/ready").raise_for_status()
        payload = {"input": TEXTS["en"], "voice": "clone", "voice_prompt": args.voice_a,
                   "voice_clone_mode": "x_vector", "language": "english", "seed": 20260825,
                   "response_format": "pcm", "stream": True, "ignore_eos": False,
                   "non_streaming_mode": True, "defer_codec_until_terminal": False, "max_new_tokens": 1024}
        status, wav = collect_completed_wav(client, nari_url, payload, deadline_at=time.monotonic() + 60, request_timeout=60)
        if status != 200 or not wav:
            raise ValueError("real model EOS case did not complete")
        print(json.dumps({"case": "real-nari-eos", "status": "pass", "wav_bytes": len(wav)}), flush=True)
        try:
            collect_completed_wav(client, nari_url, {**payload, "max_new_tokens": 1}, deadline_at=time.monotonic() + 30, request_timeout=30)
        except HTTPException as error:
            if error.status_code != 503 or error.detail.get("reason") != "incomplete-nari-generation":
                raise
        else:
            raise ValueError("max-token truncated model output was accepted")
        print(json.dumps({"case": "real-nari-token-limit", "status": "rejected-without-audio"}), flush=True)
        decoder = CompletionDecoder(request_fingerprint(payload))
        cut = False
        with client.stream("POST", nari_url + "/internal/v1/audio/speech-complete", json=payload, headers={"Accept": MEDIA_TYPE}) as response:
            response.raise_for_status()
            for line in response.iter_lines():
                decoder.feed((line + "\n").encode())
                if json.loads(line).get("type") == "pcm":
                    cut = True
                    break
        if not cut:
            raise ValueError("could not test an in-flight disconnect")
        try:
            decoder.finish()
        except CompletionProtocolError:
            pass
        else:
            raise ValueError("disconnected prefix was accepted")
        print(json.dumps({"case": "real-transport-disconnect", "status": "prefix-rejected"}), flush=True)
        # Subsequent requests prove bounded recovery, not a direct engine-cancel trace.
        for voice_index, voice in enumerate([args.voice_a, args.voice_b]):
            for language, text in TEXTS.items():
                for speed in [1.0, 2.0]:
                    started = time.monotonic()
                    response = client.post(worker_url + "/v1/captioned-speech",
                        json={"input": text, "voice": voice, "language": language, "speed": speed,
                              "required_clone_completion": "eos-v1"},
                        headers={"Authorization": "Bearer " + token})
                    response.raise_for_status()
                    if response.headers.get(CLONE_COMPLETION_HEADER) != "eos-v1":
                        raise ValueError("missing candidate completion ACK")
                    measured = validate_media(response.json(), voice, language)
                    print(json.dumps({"case": "worker-media", "voice_index": voice_index, "language": language,
                                      "speed": speed, "seconds": round(time.monotonic() - started, 3), **measured}), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--region", required=True, choices=["us", "cn"])
    parser.add_argument("--token-file", required=True, type=Path)
    parser.add_argument("--voice-a", required=True)
    parser.add_argument("--voice-b", required=True)
    parser.add_argument("--allow-gpu-after-backup-and-capacity-approval", action="store_true")
    run(parser.parse_args())


if __name__ == "__main__":
    main()
