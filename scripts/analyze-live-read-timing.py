#!/usr/bin/env python3
"""Keep all live Read presentation holds and natural media handoffs for audit.

Measures application events. It does not establish acoustic silence, source
coverage, every-frame geometry, or chapter completion.
"""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path


def clock(value):
    h, m, s = value.split(":")
    return (int(h) * 3600 + int(m) * 60) * 1000 + round(float(s) * 1000)


def field(event, name):
    match = re.search(r"(?:^| )" + re.escape(name) + r"=([^ ]+)", event)
    return match.group(1) if match else None


def stats(values):
    values = sorted(values)
    return {"count": len(values), "p95_ms": values[math.ceil(len(values) * .95) - 1],
            "max_ms": values[-1]} if values else {"count": 0}


def analyze(path, since, until):
    raw = path.read_bytes()
    holds, handoffs, commits, failures = [], [], [], []
    pending_hold, last_end, current_segment = None, None, None
    current_stage = 0
    for line_number, line in enumerate(raw.decode(errors="replace").splitlines(), 1):
        match = re.match(r"(\d\d:\d\d:\d\d\.\d{3}) (.*)", line)
        if not match:
            continue
        stamp, event = match.groups()
        at = clock(stamp)
        if not since <= at <= until:
            continue
        if event.startswith("AUDIO stage "):
            current_segment = field(event, "segment")
            current_stage += 1
        if event.startswith("AUDIO item finished "):
            last_end = {"at": at, "stamp": stamp, "segment": field(event, "segment"),
                        "stage": current_stage}
        if "PAGINATION visual_hold " in event:
            if pending_hold and pending_hold["outcome"] == "awaiting_presentation":
                pending_hold["outcome"] = "superseded_without_resume"
            pending_hold = {"hold": field(event, "id"), "hold_at": stamp, "hold_ms": at,
                            "line": line_number, "segment": current_segment,
                            "cue": field(event, "cue"), "outcome": "awaiting_presentation"}
            holds.append(pending_hold)
        if re.match(r"(?:WEREAD|GBOOKS|KOBO) page commit ", event):
            commit = {"at": stamp, "line": line_number, "event": event}
            commits.append(commit)
            if pending_hold and "commit_ms" not in pending_hold:
                pending_hold.update(commit_at=stamp, commit_ms=at,
                                    hold_to_commit_ms=at-pending_hold["hold_ms"])
        if "PAGINATION visual_release " in event and pending_hold:
            if field(event, "id") == pending_hold["hold"]:
                pending_hold.update(release_at=stamp, release_ms=at,
                                    hold_to_release_ms=at-pending_hold["hold_ms"],
                                    release_intent=field(event, "intent"))
                pending_hold["outcome"] = "released_waiting_for_media"
        if event.startswith("AUDIO state ") and "actual=playing " in event:
            segment = field(event, "segment")
            if pending_hold and ("release_ms" in pending_hold or "commit_ms" in pending_hold):
                pending_hold.update(playing_at=stamp, playing_ms=at,
                                    hold_to_playing_ms=at-pending_hold["hold_ms"],
                                    resumed_segment=segment,
                                    outcome="playing" if "release_ms" in pending_hold
                                            else "playing_without_explicit_visual_release")
                if "release_ms" in pending_hold:
                    pending_hold["release_to_playing_ms"] = at-pending_hold["release_ms"]
                if "commit_ms" in pending_hold:
                    pending_hold["commit_to_playing_ms"] = at-pending_hold["commit_ms"]
                pending_hold = None
            # Page-local segment IDs can repeat after a confirmed page commit.
            # A new staged item, rather than its paragraph ID, proves handoff.
            if last_end and current_stage != last_end["stage"]:
                handoffs.append({"ended_at": last_end["stamp"], "playing_at": stamp,
                                 "from_segment": last_end["segment"], "to_segment": segment,
                                 "ended_to_playing_ms": at-last_end["at"], "line": line_number})
                last_end = None
        if any(term in event for term in ("cue_rejected", "anchor_ack_timeout", "anchor_ack_rejected",
                                          "content blocked", "failed", "AUDIO interruption")):
            failures.append({"at": stamp, "line": line_number, "event": event})
    return {"raw_sha256": hashlib.sha256(raw).hexdigest(), "interval": [since, until],
            "measurement": __doc__.strip(), "final_acceptance": False,
            "holds": holds, "natural_media_handoffs": handoffs, "page_commits": commits,
            "failure_or_interruption_events": failures,
            "timing": {name: stats([row[name] for row in holds if name in row])
                       for name in ("hold_to_commit_ms", "hold_to_release_ms", "hold_to_playing_ms",
                                    "commit_to_playing_ms", "release_to_playing_ms")},
            "natural_media_handoff_timing": stats([r["ended_to_playing_ms"] for r in handoffs])}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("log", type=Path)
    parser.add_argument("--since", required=True)
    parser.add_argument("--until", default="23:59:59.999")
    parser.add_argument("--candidate", type=int, required=True)
    parser.add_argument("--platform", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = analyze(args.log, clock(args.since), clock(args.until))
    report.update(candidate=args.candidate, platform=args.platform,
                  raw_log=str(args.log.resolve()), interval_clock=[args.since, args.until])
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
    print(json.dumps({"holds": len(report["holds"]), "commits": len(report["page_commits"]),
                      "timing": report["timing"],
                      "natural_media_handoff_timing": report["natural_media_handoff_timing"],
                      "failures": report["failure_or_interruption_events"]}, indent=2))
