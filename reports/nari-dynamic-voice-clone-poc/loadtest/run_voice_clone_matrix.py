#!/usr/bin/env python3
"""Sequential end-to-end robustness matrix for the clone worker.

The suite yields to interactive traffic, exercises the full prompt lifecycle,
and removes every synthetic test voice in a finally block.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import tempfile
import time
import uuid
import wave
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx


ZH_REFERENCE = "今天我们继续测试声音克隆。请保持自然、清晰和稳定的语气，让每一个字都容易听懂。"
EN_REFERENCE = "Today we are testing voice cloning with a clear, natural, and steady speaking style for every sentence."
REFERENCE_TEXTS = {
    "de": "Heute testen wir das Klonen einer Stimme mit einer klaren, natürlichen und ruhigen Sprechweise für jeden Satz.",
    "es": "Hoy probamos la clonación de voz con una forma de hablar clara, natural y estable en cada frase.",
    "fr": "Aujourd’hui, nous testons le clonage vocal avec une voix claire, naturelle et régulière dans chaque phrase.",
    "it": "Oggi proviamo la clonazione vocale con un modo di parlare chiaro, naturale e stabile in ogni frase.",
    "ja": "今日は音声クローニングをテストします。すべての文を自然で明瞭かつ安定した話し方で読みます。",
    "ko": "오늘은 음성 복제를 테스트합니다. 모든 문장을 자연스럽고 명확하며 안정된 말투로 읽습니다.",
    "pt": "Hoje testamos a clonagem de voz com uma maneira de falar clara, natural e estável em cada frase.",
    "ru": "Сегодня мы тестируем клонирование голоса с ясной, естественной и ровной манерой речи в каждом предложении.",
}

PREVIEW_TEXTS = {
    "de": "Hallo, das ist meine Stimme.",
    "en": "Hello, this is my voice.",
    "es": "Hola, esta es mi voz.",
    "fr": "Bonjour, voici ma voix.",
    "it": "Ciao, questa è la mia voce.",
    "ja": "こんにちは、私の声です。",
    "ko": "안녕하세요. 제 목소리입니다.",
    "pt": "Olá, esta é a minha voz.",
    "ru": "Здравствуйте, это мой голос.",
    "zh": "你好，这是我的声音。",
}

PARAGRAPHS = {
    "de": "Dieser Absatz bestätigt, dass die geklonte Stimme vom ersten Wort an klar und stabil bleibt.",
    "en": "This paragraph verifies that the cloned voice remains clear, natural, and stable from the very first word.",
    "es": "Este párrafo confirma que la voz clonada permanece clara y estable desde la primera palabra.",
    "fr": "Ce paragraphe confirme que la voix clonée reste claire et stable dès le premier mot.",
    "it": "Questo paragrafo conferma che la voce clonata rimane chiara e stabile fin dalla prima parola.",
    "ja": "この段落では、クローン音声が最初の言葉から明瞭で安定していることを確認します。",
    "ko": "이 문단은 복제된 음성이 첫 단어부터 명확하고 안정적인지 확인합니다.",
    "pt": "Este parágrafo confirma que a voz clonada permanece clara e estável desde a primeira palavra.",
    "ru": "Этот абзац подтверждает, что клонированный голос звучит ясно и стабильно с первого слова.",
    "zh": "今天的测试会确认声音在每一个段落中都保持清晰、自然和稳定。",
}


@dataclass(frozen=True)
class Fixture:
    name: str
    language: str
    transcript: str
    should_pass: bool
    accepted_rejections: tuple[str, ...] = ()


FIXTURES = (
    Fixture("zh_tingting_clean.wav", "zh", ZH_REFERENCE, True),
    Fixture("zh_eddy_clean.wav", "zh", ZH_REFERENCE, True),
    Fixture("zh_grandma_clean.wav", "zh", ZH_REFERENCE, True),
    Fixture("en_samantha_clean.wav", "en", EN_REFERENCE, True),
    Fixture("en_daniel_clean.wav", "en", EN_REFERENCE, True),
    Fixture("en_karen_clean.wav", "en", EN_REFERENCE, True),
    Fixture("de_anna_clean.wav", "de", REFERENCE_TEXTS["de"], True),
    Fixture("es_monica_clean.wav", "es", REFERENCE_TEXTS["es"], True),
    Fixture("fr_thomas_clean.wav", "fr", REFERENCE_TEXTS["fr"], True),
    Fixture("it_alice_clean.wav", "it", REFERENCE_TEXTS["it"], True),
    Fixture("ja_kyoko_clean.wav", "ja", REFERENCE_TEXTS["ja"], True),
    Fixture("ko_yuna_clean.wav", "ko", REFERENCE_TEXTS["ko"], True),
    Fixture("pt_luciana_clean.wav", "pt", REFERENCE_TEXTS["pt"], True),
    Fixture("ru_milena_clean.wav", "ru", REFERENCE_TEXTS["ru"], True),
    Fixture("en_daniel_quiet_ok.wav", "en", EN_REFERENCE, True),
    Fixture("zh_tingting_light_noise.wav", "zh", ZH_REFERENCE, True),
    Fixture("en_samantha_light_reverb.wav", "en", EN_REFERENCE, True),
    Fixture("en_samantha_48k_stereo.wav", "en", EN_REFERENCE, True),
    Fixture("zh_tingting_44100_stereo.wav", "zh", ZH_REFERENCE, True),
    Fixture("de_anna_16k_mono.wav", "de", REFERENCE_TEXTS["de"], True),
    Fixture("en_karen_clean.flac", "en", EN_REFERENCE, True),
    Fixture("fr_thomas_dc_offset.wav", "fr", REFERENCE_TEXTS["fr"], True),
    Fixture("it_alice_outer_silence.wav", "it", REFERENCE_TEXTS["it"], True),
    Fixture("reject_too_short.wav", "en", EN_REFERENCE, False, ("VOICE_REFERENCE_DURATION_INVALID", "VOICE_REFERENCE_SPEECH_TOO_SHORT")),
    Fixture("reject_too_quiet.wav", "en", EN_REFERENCE, False, ("VOICE_REFERENCE_TOO_QUIET", "VOICE_REFERENCE_NO_SPEECH")),
    Fixture("reject_clipped.wav", "en", EN_REFERENCE, False, ("VOICE_REFERENCE_CLIPPING",)),
    Fixture("reject_heavy_noise.wav", "zh", ZH_REFERENCE, False, ("VOICE_REFERENCE_TOO_NOISY", "VOICE_REFERENCE_NO_SPEECH")),
    Fixture("reject_silence.wav", "en", EN_REFERENCE, False, ("VOICE_REFERENCE_NO_SPEECH",)),
    Fixture("reject_two_speakers.wav", "en", EN_REFERENCE, False, ("VOICE_REFERENCE_MULTIPLE_SPEAKERS",)),
)


def error_code(response: httpx.Response) -> str:
    try:
        detail = response.json().get("detail")
        if isinstance(detail, dict):
            return str(detail.get("code") or "")
        return str(detail or "")
    except (ValueError, AttributeError):
        return ""


def wav_duration(data: bytes) -> float:
    with tempfile.NamedTemporaryFile(suffix=".wav") as audio_file:
        audio_file.write(data)
        audio_file.flush()
        with wave.open(audio_file.name, "rb") as reader:
            assert reader.getnchannels() == 1
            assert reader.getframerate() == 24_000
            assert reader.getsampwidth() == 2
            return reader.getnframes() / reader.getframerate()


def mp3_duration(data: bytes) -> float:
    with tempfile.NamedTemporaryFile(suffix=".mp3") as audio_file:
        audio_file.write(data)
        audio_file.flush()
        result = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=noprint_wrappers=1:nokey=1", audio_file.name],
            check=True,
            capture_output=True,
            text=True,
            timeout=10,
        )
        return float(result.stdout.strip())


def wait_until_idle(client: httpx.Client, base_url: str, token: str) -> dict[str, Any]:
    for _ in range(60):
        health = client.get(f"{base_url}/health", headers={"X-Clone-Token": token})
        health.raise_for_status()
        body = health.json()
        if not body.get("busy") and int(body.get("queue_depth", 0)) == 0:
            return body
        time.sleep(1)
    raise RuntimeError("worker did not become idle without interactive traffic")


def protected_health_probe(client: httpx.Client, url: str | None) -> bool:
    if not url:
        return True
    try:
        return client.get(url, timeout=2.0).status_code == 200
    except httpx.HTTPError:
        return False


def validate_captioned(body: dict[str, Any], voice_id: str, language: str) -> tuple[float, int]:
    assert set(body) == {"audio", "audio_format", "timestamps", "voice_code"}
    assert body["audio_format"] == "audio/mpeg"
    assert body["voice_code"] == voice_id
    audio = base64.b64decode(body["audio"], validate=True)
    duration = mp3_duration(audio)
    assert duration > 0.2
    timestamps = body["timestamps"]
    if language not in {"zh", "ja", "ko"}:
        assert isinstance(timestamps, list) and timestamps
        cursor = 0.0
        for item in timestamps:
            assert item["word"]
            assert float(item["start_time"]) >= cursor - 0.001
            assert float(item["end_time"]) >= float(item["start_time"])
            cursor = float(item["end_time"])
        assert cursor <= duration + 0.05
    else:
        assert timestamps == []
    return duration, len(audio)


def run_fixture(client: httpx.Client, args: argparse.Namespace, fixture: Fixture, run_id: str) -> dict[str, Any]:
    path = args.fixture_dir / fixture.name
    voice_id = f"vc_matrix_{run_id}_{Path(fixture.name).stem.replace('-', '_')}"
    voice_id = voice_id[:64]
    headers = {"X-Clone-Token": args.token, "X-Request-ID": f"matrix-create-{uuid.uuid4().hex}"}
    started = time.perf_counter()
    created = False
    try:
        wait_until_idle(client, args.base_url, args.token)
        with path.open("rb") as source:
            response = client.post(
                f"{args.base_url}/v1/voices",
                headers=headers,
                data={
                    "consent_confirmed": "true",
                    "requested_voice_id": voice_id,
                    "reference_text": fixture.transcript,
                    "reference_language": fixture.language,
                },
                files={
                    "reference": (
                        fixture.name,
                        source,
                        "audio/flac" if path.suffix.lower() == ".flac" else "audio/wav",
                    )
                },
            )
        code = error_code(response)
        if not fixture.should_pass:
            matched = response.status_code == 422 and code in fixture.accepted_rejections
            if response.is_success:
                created = True
            return {
                "fixture": fixture.name,
                "expected": "reject",
                "status": response.status_code,
                "code": code,
                "passed": matched,
                "elapsed_s": round(time.perf_counter() - started, 3),
            }

        if response.status_code != 200:
            return {
                "fixture": fixture.name,
                "expected": "pass",
                "stage": "create",
                "status": response.status_code,
                "code": code,
                "passed": False,
                "elapsed_s": round(time.perf_counter() - started, 3),
            }
        created = True
        metadata = response.json()
        assert metadata["voice_id"] == voice_id
        assert float(metadata["reference_duration_s"]) >= 3.0
        assert isinstance(metadata["reference_quality"], dict)

        prompt = client.get(
            f"{args.base_url}/v1/voices/{voice_id}/prompt",
            headers={"X-Clone-Token": args.token},
        )
        prompt.raise_for_status()
        assert len(prompt.content) > 1_000

        preview_text = PREVIEW_TEXTS[fixture.language]
        preview_durations = []
        for _ in range(3):
            preview = client.post(
                f"{args.base_url}/v1/speech",
                headers={
                    "X-Clone-Token": args.token,
                    "X-TTS-Priority": "background",
                    "X-Request-ID": f"matrix-preview-{uuid.uuid4().hex}",
                },
                json={
                    "voice_id": voice_id,
                    "text": preview_text,
                    "language_id": fixture.language,
                    "seed": int(uuid.uuid4().hex[:8], 16) % 2_147_483_647,
                },
            )
            preview.raise_for_status()
            preview_duration = wav_duration(preview.content)
            assert 0.2 < preview_duration < 12.0
            preview_durations.append(round(preview_duration, 3))

        deleted = client.delete(
            f"{args.base_url}/v1/voices/{voice_id}",
            headers={"X-Clone-Token": args.token},
        )
        deleted.raise_for_status()
        created = False
        imported = client.put(
            f"{args.base_url}/v1/voices/{voice_id}/prompt",
            headers={"X-Clone-Token": args.token},
            files={"prompt": ("prompt.pt", prompt.content, "application/octet-stream")},
        )
        imported.raise_for_status()
        created = True

        paragraph = PARAGRAPHS[fixture.language]
        captioned = client.post(
            f"{args.base_url}/v1/captioned-speech",
            headers={
                "X-Clone-Token": args.token,
                "X-TTS-Priority": "background",
                "X-Request-ID": f"matrix-captioned-{uuid.uuid4().hex}",
            },
            json={
                "input": paragraph,
                "voice": voice_id,
                "language": fixture.language,
                "speed": 1.0,
                "response_format": "mp3",
                "return_timestamps": True,
                "stream": False,
            },
        )
        captioned.raise_for_status()
        paragraph_duration, audio_bytes = validate_captioned(captioned.json(), voice_id, fixture.language)

        cross_language = "en" if fixture.language in {"zh", "ja", "ko"} else "zh"
        cross_paragraph = (
            "The same cloned voice should also read this English sentence clearly and consistently."
            if cross_language == "en"
            else "同一个克隆音色也应该能够清晰、稳定地朗读这句中文。"
        )
        cross_captioned = client.post(
            f"{args.base_url}/v1/captioned-speech",
            headers={
                "X-Clone-Token": args.token,
                "X-TTS-Priority": "background",
                "X-Request-ID": f"matrix-cross-{uuid.uuid4().hex}",
            },
            json={
                "input": cross_paragraph,
                "voice": voice_id,
                "language": cross_language,
                "speed": 1.0,
                "response_format": "mp3",
                "return_timestamps": True,
                "stream": False,
            },
        )
        cross_captioned.raise_for_status()
        cross_duration, cross_audio_bytes = validate_captioned(
            cross_captioned.json(), voice_id, cross_language
        )
        return {
            "fixture": fixture.name,
            "expected": "pass",
            "status": 200,
            "passed": True,
            "reference_duration_s": metadata["reference_duration_s"],
            "preview_duration_s": preview_durations,
            "paragraph_duration_s": round(paragraph_duration, 3),
            "paragraph_audio_bytes": audio_bytes,
            "cross_language": cross_language,
            "cross_duration_s": round(cross_duration, 3),
            "cross_audio_bytes": cross_audio_bytes,
            "warnings": metadata.get("reference_quality_warnings", []),
            "elapsed_s": round(time.perf_counter() - started, 3),
        }
    except Exception as error:
        return {
            "fixture": fixture.name,
            "expected": "pass" if fixture.should_pass else "reject",
            "stage": "lifecycle",
            "passed": False,
            "error": f"{type(error).__name__}: {error}"[:240],
            "elapsed_s": round(time.perf_counter() - started, 3),
        }
    finally:
        if created:
            try:
                client.delete(
                    f"{args.base_url}/v1/voices/{voice_id}",
                    headers={"X-Clone-Token": args.token},
                )
            except Exception:
                pass
        time.sleep(args.pause_seconds)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("fixture_dir", type=Path)
    parser.add_argument("--base-url", default="http://127.0.0.1:18890")
    parser.add_argument("--token", default=os.environ.get("CLONE_TOKEN", ""))
    parser.add_argument("--pause-seconds", type=float, default=1.5)
    parser.add_argument("--protected-health-url")
    parser.add_argument("--result", type=Path)
    args = parser.parse_args()
    if not args.token:
        raise SystemExit("CLONE_TOKEN or --token is required")
    missing = [fixture.name for fixture in FIXTURES if not (args.fixture_dir / fixture.name).is_file()]
    if missing:
        raise SystemExit(f"missing fixtures: {', '.join(missing)}")

    run_id = uuid.uuid4().hex[:8]
    with httpx.Client(timeout=150.0) as client:
        before = wait_until_idle(client, args.base_url, args.token)
        results = []
        protected_probe_total = 0
        protected_probe_non_200 = 0
        for index, fixture in enumerate(FIXTURES, start=1):
            if args.protected_health_url:
                protected_probe_total += 1
                if not protected_health_probe(client, args.protected_health_url):
                    protected_probe_non_200 += 1
            result = run_fixture(client, args, fixture, run_id)
            results.append(result)
            if args.protected_health_url:
                protected_probe_total += 1
                if not protected_health_probe(client, args.protected_health_url):
                    protected_probe_non_200 += 1
            print(
                f"matrix_progress {index}/{len(FIXTURES)} "
                f"fixture={fixture.name} passed={result['passed']}",
                flush=True,
            )
        after = wait_until_idle(client, args.base_url, args.token)
    report = {
        "run_id": run_id,
        "fixtures": len(results),
        "passed": sum(bool(result["passed"]) for result in results),
        "failed": sum(not bool(result["passed"]) for result in results),
        "worker_before": {key: before.get(key) for key in ("submitted", "completed", "failed", "expired")},
        "worker_after": {key: after.get(key) for key in ("submitted", "completed", "failed", "expired")},
        "protected_health_probes": protected_probe_total,
        "protected_health_non_200": protected_probe_non_200,
        "results": results,
    }
    serialized = json.dumps(report, ensure_ascii=False, indent=2)
    if args.result:
        args.result.parent.mkdir(parents=True, exist_ok=True)
        args.result.write_text(serialized + "\n", encoding="utf-8")
    print(serialized)
    return 0 if report["failed"] == 0 and protected_probe_non_200 == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
