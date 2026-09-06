#!/usr/bin/env python3
"""Migrate only the four existing Global TTS environment fields after proxy proof."""

from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parent
PROJECT = "prj_wYf9gRnrKR28vEUtOP9hY7ITa7tK"
TEAM = "team_T12jAJWADzok4cQ5gWZPVjw2"
CWD = "/Users/xuxuheng/Documents/MyProject/readout-web"


def api(path):
    result = subprocess.run(
        ["vercel", "api", path, "--raw"], cwd=CWD, capture_output=True, text=True, timeout=40
    )
    if result.returncode:
        raise RuntimeError("vercel_selected_configuration_read_failed")
    return json.loads(result.stdout)


def main():
    # Input is a reviewed, non-secret target document derived from the real
    # stable-proxy source and nine-language validation receipt.
    target_path = Path(sys.argv[1])
    desired = json.loads(target_path.read_text())
    values = desired["environment"]
    before = json.loads((ROOT / "tts-production-env-before.json").read_text())
    assert set(values) == {row["key"] for row in before["fields"]}
    assert values["TTS_UPSTREAM_URL"] == "http://71.175.237.103:41209/dev/captioned_speech"
    assert values["TTS_UPSTREAM_NODE_ID"] == "castreader-us4090"
    receipt = Path(desired["proxyReceiptPath"])
    assert hashlib.sha256(receipt.read_bytes()).hexdigest() == values["TTS_UPSTREAM_RECEIPT_SHA256"]
    assert set(desired["verifiedLanguages"]) == {"en", "zh", "de", "fr", "ja", "pt", "es", "it", "hi"}
    output = ROOT / "tts-production-env-update.json"
    assert not output.exists(), "Inspect existing update receipt instead of reapplying"
    conn = http.client.HTTPConnection("71.175.237.103", 41209, timeout=10)
    try:
        conn.request("GET", "/health")
        response = conn.getresponse()
        health = json.loads(response.read(8192))
        assert response.status == 200 and health["ok"] is True
        assert health["proxyReleaseId"] == values["TTS_UPSTREAM_RELEASE_ID"]
    finally:
        conn.close()
    rows = []
    # Read every expected field before beginning the four-field migration.
    for row in before["fields"]:
        current = api(f'/v1/projects/{PROJECT}/env/{row["id"]}?teamId={TEAM}')
        assert all(current.get(key) == row[key] for key in ("key", "value", "target", "type", "updatedAt")), "TTS configuration baseline changed"
        rows.append(row)
    record = {"startedAtUtc": datetime.now(timezone.utc).isoformat(), "projectId": PROJECT,
              "fields": [], "complete": False, "otherProductionFieldsModified": False}
    for row in rows:
        value = values[row["key"]]
        if value != row["value"]:
            changed = subprocess.run(
                ["vercel", "env", "update", row["key"], "production", "--project", PROJECT, "--yes"],
                input=value, cwd=CWD, capture_output=True, text=True, timeout=45,
            )
            if changed.returncode:
                output.write_text(json.dumps(record, indent=2) + "\n")
                raise RuntimeError("TTS configuration update failed; inspect partial receipt")
        current = api(f'/v1/projects/{PROJECT}/env/{row["id"]}?teamId={TEAM}')
        assert current.get("value") == value and current.get("target") == row["target"] and current.get("type") == row["type"]
        record["fields"].append({"key": row["key"], "before": row["value"], "after": value,
                                "readbackVerified": True, "updatedAt": current.get("updatedAt")})
        output.write_text(json.dumps(record, indent=2) + "\n")
    record.update(complete=True, completedAtUtc=datetime.now(timezone.utc).isoformat())
    output.write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"complete": True, "updatedFields": len(rows), "receipt": str(output)}))


if __name__ == "__main__":
    main()
