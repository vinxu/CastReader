#!/usr/bin/env python3
"""Run fixed non-user regression probes from the existing US control host."""

import base64
from datetime import datetime, timezone
import hashlib
import http.client
import json
import ssl
import subprocess
import time


def main():
    text = "The repeated value is 00, and complete playback ends with sunflower."
    rows = []
    for host in ("api.castreader.ai", "tts.castreader.ai"):
        request_id = "ops-final-r133-" + ("global" if host.startswith("api.") else "direct") + "-20260906"
        body = json.dumps({
            "model": "kokoro", "input": text, "voice": "am_adam", "voice_code": "am_adam",
            "language": "en", "lang_code": "a", "response_format": "mp3",
            "return_timestamps": True, "speed": 1,
        }).encode()
        connection = http.client.HTTPSConnection(host, timeout=40, context=ssl.create_default_context())
        started = time.monotonic()
        try:
            connection.request("POST", "/api/captioned_speech_partly", body=body, headers={
                "Content-Type": "application/json", "X-Request-Id": request_id,
                "X-CastReader-Platform": "ops", "X-CastReader-Version": "release-r133-final",
            })
            response = connection.getresponse()
            raw = response.read(3 * 1024 * 1024 + 1)
            assert response.status == 200 and len(raw) <= 3 * 1024 * 1024, "Public audio response failed"
            headers = {k.lower(): v for k, v in response.getheaders() if k.lower().startswith("x-castreader-")}
        finally:
            connection.close()
        result = json.loads(raw)
        audio = base64.b64decode(result["audio"], validate=True)
        decoded = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", "pipe:0", "-f", "s16le", "-ac", "1", "-ar", "24000", "pipe:1"],
            input=audio, capture_output=True, timeout=20,
        )
        assert decoded.returncode == 0 and len(decoded.stdout) > 0, "Public audio failed complete decode"
        assert result.get("unprocessed_text") in (None, ""), "Public audio left a remainder"
        cues = result.get("timestamps") or []
        assert any(cue.get("word") == "00" for cue in cues), "Repeated-digit source cue missing"
        assert cues[-1].get("word", "").rstrip(".!?").lower() == "sunflower", "Source tail missing"
        rows.append({
            "host": host, "requestId": request_id, "status": 200,
            "elapsedSeconds": round(time.monotonic() - started, 3),
            "inputSha256": hashlib.sha256(text.encode()).hexdigest(),
            "audioBytes": len(audio), "audioSha256": hashlib.sha256(audio).hexdigest(),
            "decodedSamples": len(decoded.stdout) // 2,
            "decodedDurationSeconds": len(decoded.stdout) / 48000,
            "remainingCharacters": 0, "repeatedDigitsAndFinalWordVerified": True,
            "routingHeaders": headers,
        })
    print(json.dumps({
        "schema": "castreader.final-public-r133-audio-probes.v1",
        "verifiedAtUtc": datetime.now(timezone.utc).isoformat(),
        "probeOrigin": "existing US control host 140.82.14.49",
        "fixedNonUserText": True, "audioOrInputRetained": False, "cases": rows,
    }, sort_keys=True))


if __name__ == "__main__":
    main()
