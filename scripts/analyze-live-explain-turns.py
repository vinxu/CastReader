#!/usr/bin/env python3
"""Audit Google/Kobo/WeRead Explain logs, retaining every automatic page commit.

These are application-clock observations, not acoustic silence measurements.
Read/carry and Kindle have different events and are deliberately excluded.
"""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path


def analyze(path, platform="gbooks", since="00:00:00.000", until="23:59:59.999"):
    raw = path.read_bytes()
    rows, pending, request, last_end = [], None, None, None
    day, previous_clock = 0, None
    for number, line in enumerate(raw.decode(errors="replace").splitlines(), 1):
        match = re.match(r"(\d\d):(\d\d):(\d\d)\.(\d{3}) (.*)", line)
        if not match:
            continue
        h, m, s, ms = map(int, match.groups()[:4])
        clock = ((h * 60 + m) * 60 + s) * 1000 + ms
        if previous_clock is not None and clock < previous_clock - 12 * 3600000:
            day += 86400000
        previous_clock = clock
        at, event = day + clock, match.group(5)
        stamp = f"{h:02}:{m:02}:{s:02}.{ms:03}"
        if not since <= stamp <= until:
            continue
        if event.startswith("AUDIO item finished"):
            last_end = at
        if event.startswith("GBOOKS next page requested") or (platform == "weread" and
                event.startswith("WEREAD page turn action=semantic-next ")):
            request = at
        if event.startswith("GBOOKS page commit") or (platform == "weread" and
                event.startswith("WEREAD page commit ")):
            if pending is not None and pending["outcome"] == "awaiting_audio":
                pending["outcome"] = "superseded_without_audio"
            pending = None
            automatic = request is not None if platform == "weread" else "reason=auto " in event
            if not automatic:
                request = None
                continue
            def field(name):
                value = re.search(r"(?:^| )" + re.escape(name) + r"=([^ ]+)", event)
                return value.group(1) if value else None
            pending = {"commit_line": number, "commit_ms": at, "request_ms": request,
                       "prior_audio_end_ms": last_end, "source": field("next" if platform == "weread" else "sig"),
                       "voice": field("tts.voice"), "prefetch_hit": False,
                       "pending_producer_adopted": False, "decoded_media_adopted": False,
                       "outcome": "awaiting_audio"}
            if request is not None:
                pending["request_to_commit_ms"] = at - request
            request = None
            rows.append(pending)
        if pending is None:
            continue
        if "explain preload consume" in event:
            pending["prefetch_hit"] = "hit=Y" in event
        if platform == "weread" and "WEREAD explain confirmed-page " in event:
            pending["prefetch_hit"] = "prefetched=Y" in event
        if "explain preload adopted" in event:
            pending["pending_producer_adopted"] = True
        if "AUDIO prepared adopted" in event:
            pending["decoded_media_adopted"] = "decoded=true" in event
        if "LIVE explain short-page continue" in event:
            pending["outcome"] = "short_page_without_audio"
            pending["short_page_line"] = number
        if "AUDIO state" in event and "actual=playing " in event:
            pending["outcome"] = "playing"
            pending["playing_line"] = number
            pending["playing_ms"] = at
            pending["commit_to_playing_ms"] = at - pending["commit_ms"]
            if pending["prior_audio_end_ms"] is not None:
                pending["ended_to_playing_ms"] = at - pending["prior_audio_end_ms"]
            pending = None
    if pending is not None and pending["outcome"] == "awaiting_audio":
        pending["outcome"] = "log_ended_before_audio"

    def summarize(subset):
        result = {"count": len(subset)}
        for key in ("request_to_commit_ms", "commit_to_playing_ms", "ended_to_playing_ms"):
            values = sorted(row[key] for row in subset if key in row)
            result[key] = {"samples": len(values), "p95": values[math.ceil(len(values) * .95) - 1],
                           "max": values[-1]} if values else None
        return result
    summary = {}
    for kind in ("preset", "clone", "voice_not_recorded"):
        selected = [row for row in rows if
                    ("voice_not_recorded" if not row["voice"] else
                     "clone" if row["voice"].startswith("vc_") else "preset") == kind]
        played = [row for row in selected if row["outcome"] == "playing"]
        warm = [row for row in played if row["prefetch_hit"] and row["decoded_media_adopted"]]
        summary[kind] = {"all_commits": len(selected), "all_audible_paths": summarize(played),
                         "ready_and_decoded_hits_only": summarize(warm),
                         "other_or_cold_audible_paths": summarize([row for row in played if row not in warm]),
                         "without_audio": [{"line": row["commit_line"], "outcome": row["outcome"]}
                                           for row in selected if row["outcome"] != "playing"]}
    return {"raw_log": str(path.resolve()), "raw_sha256": hashlib.sha256(raw).hexdigest(),
            "measurement": "Application event clock; includes native turn time separately; no acoustic claim",
            "summary": summary, "rows": rows, "final_acceptance": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--candidate", type=int, required=True)
    parser.add_argument("--platform", choices=("gbooks", "weread"), default="gbooks")
    parser.add_argument("--since", default="00:00:00.000")
    parser.add_argument("--until", default="23:59:59.999")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = analyze(args.log, args.platform, args.since, args.until)
    report["candidate"] = args.candidate
    report["platform"] = args.platform
    report["interval_clock"] = [args.since, args.until]
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report["summary"], ensure_ascii=False, indent=2))
