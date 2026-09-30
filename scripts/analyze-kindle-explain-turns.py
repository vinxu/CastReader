#!/usr/bin/env python3
"""Merge one ReaderRunLog with the last Kindle launch, retaining failed turns.

This reports application event intervals, not acoustic silence. Exclusions are
explicit inclusive HH:MM:SS.mmm ranges; excluded turns remain in the output.
"""
import argparse
import hashlib
import json
import math
import re
from pathlib import Path


def milliseconds(clock):
    h, m, s, fraction = map(int, re.split(r"[:.]", clock))
    return ((h * 60 + m) * 60 + s) * 1000 + fraction


def analyze(reader, probe, excluded):
    text = probe.read_text()
    launch = text.rfind("===== launch ")
    if launch >= 0:
        text = text[launch:]
    events = []
    for source, content in (("reader", reader.read_text()), ("probe", text)):
        day, previous = 0, None
        for line, entry in enumerate(content.splitlines(), 1):
            match = re.match(r"(\d\d:\d\d:\d\d\.\d{3}) (.*)", entry)
            if not match:
                continue
            clock, event = match.groups()
            at = milliseconds(clock)
            if previous is not None and at < previous - 12 * 3600000:
                day += 86400000
            previous = at
            events.append((day + at, clock, event, source, line))
    events.sort(key=lambda item: item[0])
    rows, pending, last_end = [], None, None
    phases = {"overlay staged-consume": "receipt", "read preload consumed": "source_activated",
              "native reveal confirmed": "paint", "restart after-turn begin": "restart",
              "AUDIO prepared adopted": "media_ready"}
    for at, clock, event, source, line in events:
        if "AUDIO item finished" in event:
            last_end = (at, clock)
        if "explain auto advance begin" in event:
            if pending:
                pending["outcome"] = "superseded_without_audio"
            pending = {"begin": clock, "begin_ms": at, "prior_end": last_end[1] if last_end else None,
                       "prior_end_ms": last_end[0] if last_end else None, "phase": {},
                       "staged_target": "staged-target" in event, "outcome": "awaiting_audio"}
            rows.append(pending)
        if pending is None:
            continue
        for needle, label in phases.items():
            if needle in event:
                pending["phase"].setdefault(label, clock)
        if "abandoned" in event or "auto advance error" in event:
            pending.update(outcome="failed", failure_event=event, failure_line=line,
                           failure_source=source, finished_ms=at)
            pending = None
        elif "AUDIO state" in event and "actual=playing " in event:
            pending.update(outcome="playing", playing=clock, finished_ms=at,
                           ended_to_playing_ms=at - pending["prior_end_ms"]
                           if pending["prior_end_ms"] is not None else None)
            pending = None
    for row in rows:
        start = row["prior_end_ms"] if row["prior_end_ms"] is not None else row["begin_ms"]
        end = row.get("finished_ms", row["begin_ms"])
        row["exclusions"] = [label for label, lo, hi in excluded
                             if start <= milliseconds(hi) and end >= milliseconds(lo)]
    included = [r for r in rows if r["outcome"] == "playing" and not r["exclusions"]]
    values = sorted(r["ended_to_playing_ms"] for r in included if r["ended_to_playing_ms"] is not None)
    return {"rows": rows, "ordinary_events": {"count": len(values),
            "p95_ms": values[math.ceil(len(values) * .95) - 1] if values else None,
            "max_ms": max(values) if values else None},
            "exclusion_intervals": excluded,
            "raw_sha256": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (reader, probe)},
            "measurement": "Application event clock; no acoustic silence claim. Source coverage, chapter coverage and long-duration acceptance are separate.",
            "final_acceptance": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("reader", type=Path)
    parser.add_argument("probe", type=Path)
    parser.add_argument("--candidate", type=int, required=True)
    parser.add_argument("--exclude", action="append", nargs=3, default=[], metavar=("LABEL", "START", "END"))
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = analyze(args.reader, args.probe, args.exclude)
    report["candidate"] = args.candidate
    args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"candidate": args.candidate, "total_turns": len(report["rows"]),
                     "ordinary_events": report["ordinary_events"]}, indent=2))
