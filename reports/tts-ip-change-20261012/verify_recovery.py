"""Public recovery verification; no credentials or user text are used."""
import base64
import datetime
import json
import pathlib
import subprocess
import time
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent
EXPECTED_SHA = "227b932f3d402a15924e00b566bf69206f708296"
with urllib.request.urlopen("https://api.castreader.ai/api/capabilities", timeout=15) as response:
    capabilities = json.load(response)
assert capabilities["commitSha"] == EXPECTED_SHA, "recovery release is not serving yet"

probes = [
    ("en", "af_heart", "CastReader service recovery check."),
    ("zh", "zf_001", "语音服务恢复检查。"),
    ("ja", "jf_alpha", "音声サービスの復旧を確認します。"),
    ("es", "ef_dora", "El servicio de voz funciona correctamente."),
    ("fr", "ff_siwis", "Le service vocal fonctionne correctement."),
    ("de", "df_mls_19", "Der Sprachdienst funktioniert wieder."),
    ("pt", "pf_dora", "O serviço de voz funciona corretamente."),
    ("it", "if_sara", "Il servizio vocale funziona correttamente."),
    ("hi", "hf_alpha", "आवाज सेवा फिर से काम कर रही है।"),
]
results = []
for host, selected in [
    ("api.castreader.ai", probes),
    ("tts.castreader.ai", probes[:2]),
    ("api.castreader.cn", probes[:2]),
]:
    for language, voice, sentence in selected:
        result = {"host": host, "language": language}
        started = time.monotonic()
        try:
            payload = dict(input=sentence, model="kokoro", response_format="mp3",
                           return_timestamps=True, speed=1, stream=False,
                           language=language, voice_code=voice)
            request = urllib.request.Request(
                f"https://{host}/api/captioned_speech_partly",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json", "User-Agent": "CastReader-IncidentRecovery/20261012"},
            )
            with urllib.request.urlopen(request, timeout=35) as response:
                body = json.load(response)
                result["http"] = response.status
                result["routingHeaders"] = {
                    key: value for key, value in response.headers.items()
                    if key.lower().startswith("x-tts")
                }
            result["seconds"] = round(time.monotonic() - started, 3)
            audio = base64.b64decode(body["audio"], validate=True)
            assert len(audio) > 1000 and len(body["timestamps"]) > 0
            path = ROOT / f"recovered-{host}-{language}.mp3"
            path.write_bytes(audio)
            subprocess.run(["ffmpeg", "-nostdin", "-v", "error", "-i", str(path), "-f", "null", "-"],
                           check=True, capture_output=True, timeout=20)
            duration = float(subprocess.check_output([
                "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)
            ], text=True, timeout=20))
            result.update(passed=True, audioBytes=len(audio), timestamps=len(body["timestamps"]), duration=duration)
        except Exception as error:
            result.update(passed=False, error=type(error).__name__, seconds=round(time.monotonic()-started, 3))
            if isinstance(error, urllib.error.HTTPError):
                result["http"] = error.code
        results.append(result)
        print(json.dumps(result, ensure_ascii=False), flush=True)

report = {
    "checkedAtUtc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "releaseSha": capabilities["commitSha"],
    "releaseId": capabilities["releaseId"],
    "results": results,
    "passed": all(item["passed"] for item in results),
}
(ROOT / "recovery-public-verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit(0 if report["passed"] else 1)
