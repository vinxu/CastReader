from __future__ import annotations

import argparse
import base64
from concurrent.futures import ThreadPoolExecutor
import hashlib
import io
import json
from pathlib import Path
import time
import uuid

import httpx
import soundfile as sf

from alignment_contract import lexical_key
from benchmark_tts_overlap import SAMPLES
from caption_pipeline import PIPELINE_REVISION


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--token-file", type=Path, required=True)
    parser.add_argument("--endpoint", default="http://127.0.0.1:18891")
    args = parser.parse_args()
    output = args.root / "gateway-grouped-smoke"
    output.mkdir(exist_ok=True)
    token = args.token_file.read_text().strip()
    headers = {"X-Clone-Token": token, "X-TTS-Priority": "prefetch"}
    endpoint = args.endpoint
    client = httpx.Client(base_url=endpoint, headers=headers, timeout=65, trust_env=False)
    results = []
    fixtures = []

    def invoke(identity, text, language="en", speed=1.0):
        started = time.perf_counter()
        response = client.post("/v1/captioned-speech", headers={"X-Request-ID": identity}, json={
            "input": text, "voice": "vc_e2e_generated_test", "language": language,
            "speed": speed, "return_timestamps": True, "response_format": "mp3", "stream": False,
        })
        response.raise_for_status()
        body = response.json()
        assert set(body) == {"audio", "audio_format", "timestamps", "voice_code"}
        assert body["voice_code"] == "vc_e2e_generated_test"
        assert body["audio_format"] == "audio/mpeg"
        assert response.headers["x-voice-alignment-revision"] == PIPELINE_REVISION
        encoded = base64.b64decode(body["audio"], validate=True)
        samples, sample_rate = sf.read(io.BytesIO(encoded), dtype="float32")
        duration = len(samples) / sample_rate
        assert samples.ndim == 1 and duration > 0
        assert 0 <= int(response.headers["x-voice-audio-duration-ms"]) - duration * 1000 < 1.001
        previous_end = 0.0
        for stamp in body["timestamps"]:
            assert previous_end <= stamp["start_time"] < stamp["end_time"] <= duration
            previous_end = stamp["end_time"]
        if body["timestamps"]:
            assert "".join(lexical_key(stamp["word"]) for stamp in body["timestamps"]) == lexical_key(text)
        elif language not in {"zh", "ja", "ko"}:
            raise AssertionError("Unexpected word-alignment degradation: " + response.headers["x-voice-alignment-mode"])
        result = {"id": identity, "language": language, "speed": speed,
                  "mode": response.headers["x-voice-alignment-mode"], "timestamps": len(body["timestamps"]),
                  "duration": duration, "elapsed_ms": (time.perf_counter() - started) * 1000,
                  "audio_sha256": hashlib.sha256(encoded).hexdigest(),
                  "cache": response.headers.get("x-tts-idempotency")}
        (output / (identity + ".mp3")).write_bytes(encoded)
        fixtures.append({"id": identity, "text": text, "language": language,
                         "duration": duration, "response": body})
        return result

    try:
        health = client.get("/health").raise_for_status().json()
        assert health["pipeline_revision"] == PIPELINE_REVISION
        unauthenticated = httpx.post(endpoint + "/v1/captioned-speech", timeout=5,
                                    json={"input": "Hello", "voice": "vc_e2e_generated_test"})
        assert unauthenticated.status_code == 401
        for language, text in SAMPLES.items():
            identity = f"grouped-{language}-" + uuid.uuid4().hex[:8]
            result = invoke(identity, text, language)
            results.append(result)
            print(json.dumps(result), flush=True)
            (output / "results.json").write_text(json.dumps(results, indent=2))
        for speed in [.5, 2.0]:
            result = invoke(f"speed-{speed}-" + uuid.uuid4().hex[:8],
                            "I could not tell the time without a watch. It was impossible for us to understand.", speed=speed)
            results.append(result)
            print(json.dumps(result), flush=True)
        for index, text in enumerate(['"Nedat."("Below.")',
                                      '"Hans was right," he exclaimed enthusiastically;"that is the dull roaring of a torrent."']):
            result = invoke(f"punctuation-{index}-" + uuid.uuid4().hex[:8], text)
            results.append(result)
            print(json.dumps(result), flush=True)
        identity = "coalesced-" + uuid.uuid4().hex[:8]
        with ThreadPoolExecutor(max_workers=4) as executor:
            repeated = list(executor.map(lambda _: invoke(identity, "Chapter 31. The sea monster was near the ship."), range(4)))
        assert len({row["audio_sha256"] for row in repeated}) == 1
        assert sum(row["cache"] == "owner" for row in repeated) == 1
        results.extend(repeated)
        (output / "client-fixtures.json").write_text(json.dumps(fixtures, ensure_ascii=False))
        (output / "results.json").write_text(json.dumps(results, indent=2))
        print(json.dumps({"passed": len(results), "unauthorized_rejected": True,
                          "revision": PIPELINE_REVISION}), flush=True)
    finally:
        client.close()


if __name__ == "__main__":
    main()
