#!/usr/bin/env python3
"""Read existing proxy diagnostics for the fixed 74 requests; never synthesize."""
import hashlib
import json
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
REMOTE = r'''
import hashlib, json, sys, types
from pathlib import Path
from datetime import datetime, timezone
p = json.load(sys.stdin)
m = types.ModuleType("sanitized_proxy_events")
exec(compile(p["safeSource"], "remote_proxy_events.py", "exec"), m.__dict__)
start, end = m.parse_utc(p["startUTC"]), m.parse_utc(p["endUTC"])
keys, flights = set(p["keys"]), set(p["flights"])
log = Path("/var/log/onstart.log")
stat = log.stat()
offset = max(0, stat.st_size - 512 * 1024 * 1024)
first = last = None
events = []
scanned = malformed = 0
with log.open("rb") as f:
    f.seek(offset)
    if offset:
        f.readline()
    while f.tell() < stat.st_size:
        raw = f.readline()
        pos = raw.find(b"{")
        if pos < 0:
            continue
        try:
            value = json.loads(raw[pos:])
        except (ValueError, UnicodeError):
            continue
        if not isinstance(value, dict) or value.get("schema") != m.EVENT_SCHEMA:
            continue
        e = m.safe_event(value)
        if e is None:
            malformed += 1
            continue
        scanned += 1
        ts = e["timeUnix"]
        first = ts if first is None else min(first, ts)
        last = ts if last is None else max(last, ts)
        if start <= ts < end and (e.get("requestKey") in keys or e.get("flightKey") in flights):
            events.append(e)
after = log.stat()
source = Path("/workspace/castreader-runtime/proxy-releases/us-tts-origin-proxy-20260907-v2/r133_stable_proxy.py")
source_hash = hashlib.sha256(source.read_bytes()).hexdigest()
print(json.dumps({
    "readOnly": True, "productionModified": False, "synthesisStarted": False,
    "rawContentExported": False, "collectedAtUTC": datetime.now(timezone.utc).isoformat(),
    "window": {"startUTC": p["startUTC"], "endUTCExclusive": p["endUTC"]},
    "source": {"path": str(source), "sha256": source_hash, "matchesPinned": source_hash == p["proxySha256"]},
    "coverage": {"path": str(log), "inode": stat.st_ino, "snapshotBytes": stat.st_size,
        "scanOffset": offset, "sameInodeAfter": stat.st_ino == after.st_ino,
        "notTruncatedDuringRead": after.st_size >= stat.st_size,
        "firstProxyEventUTC": m.utc(first) if first is not None else None,
        "lastProxyEventUTC": m.utc(last) if last is not None else None,
        "spansWindow": first is not None and first <= start and last >= end,
        "scannedProxyEvents": scanned, "malformedProxyEvents": malformed},
    "targetCount": len(keys), "events": events,
    "limitations": ["Historical window spans multiple routing/model revisions; each event retains its recorded revision.",
        "Source hash is a current readback; frozen archived identities remain the historical production evidence.",
        "These are service request observations, not proof of user intent or audio playback."]
}))
'''

joined = json.loads((HERE / "archived-proxy-joins.json").read_text())
flights = {f for rows in joined["matches"].values() for row in rows for f in row["request"]["flightKeys"]}
payload = {
    "safeSource": (ROOT / "reports/audio-playback-recovery-rollout-20260907/monitoring/remote_proxy_events.py").read_text(),
    "startUTC": "2026-09-06T18:37:52.522573Z",
    "endUTC": "2026-09-07T18:37:52.522573Z",
    "keys": sorted(joined["matches"]), "flights": sorted(flights),
    "proxySha256": "0502fc2d9b3793be6309ae6f13ea544380404721857e55162b3eae060daa7eba",
}
import shlex
result = subprocess.run(
    ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "castreader-us4090", "python3 -c " + shlex.quote(REMOTE)],
    input=json.dumps(payload), text=True, capture_output=True, timeout=55,
)
if result.returncode:
    raise SystemExit("Read-only proxy collection failed (raw SSH output withheld).")
data = json.loads(result.stdout)
data["collectorSha256"] = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
data["sanitizerSha256"] = hashlib.sha256(payload["safeSource"].encode()).hexdigest()
(HERE / "proxy-targeted-readback.json").write_text(json.dumps(data, indent=2) + "\n")
print(json.dumps({"events": len(data["events"]), "coverage": data["coverage"], "sourceMatches": data["source"]["matchesPinned"]}))
