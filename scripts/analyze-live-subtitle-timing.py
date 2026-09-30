#!/usr/bin/env python3
"""Summarize caption publications; media-clock lag is not acoustic A/V latency."""
import argparse
import collections
import hashlib
import json
import math
import re
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("log", type=Path)
parser.add_argument("--start", required=True)
parser.add_argument("--end", required=True)
args = parser.parse_args()
raw = args.log.read_bytes()
lines = [line for line in raw.decode().splitlines()
         if args.start <= line[:12] <= args.end]
media, cues, playing, paused = [], [], [], []
for line in lines:
    match = re.search(r"EXPLAIN subtitle media=(\S+) cues=(\d+) timing=(\w+) width=(\d+)(.*)", line)
    if match:
        media.append(dict(wall=line[:12], media=match[1], cue_count=int(match[2]),
                          timing=match[3], width=int(match[4]), diagnostic=match[5].strip()))
    match = re.search(r"EXPLAIN subtitle cue media=(\S+) range=(\d+):(\d+) at=([\d.]+) clock=([\d.]+) exact=(true|false)", line)
    if match:
        cues.append(dict(wall=line[:12], media=match[1], range=[int(match[2]), int(match[3])],
                         start=float(match[4]), clock=float(match[5]), exact=match[6] == "true"))
    if "AUDIO state" in line and "actual=playing" in line:
        playing.append(line[:12])
    if "EXPLAIN transport applied" in line and "playing=false" in line:
        paused.append(line[:12])
lags = sorted(cue["clock"] - cue["start"] for cue in cues if cue["exact"] and cue["range"][0] > 0)
result = dict(raw_sha256=hashlib.sha256(raw).hexdigest(), window=[args.start, args.end],
              first_playing=playing[0] if playing else None,
              last_playing=playing[-1] if playing else None, user_pause=paused,
              media_timing_counts=dict(collections.Counter(item["timing"] for item in media)),
              caption_cues=len(cues), exact_word_start_cues=sum(cue["exact"] for cue in cues),
              noninitial_media_clock_lag_seconds=dict(count=len(lags), min=min(lags),
                  p95=lags[math.ceil(len(lags) * .95)-1], max=max(lags)) if lags else None,
              clock_mismatch_events=[cue for cue in cues if cue["exact"] and cue["range"][0] > 0
                                     and abs(cue["clock"] - cue["start"]) > .2],
              estimated_media=[item for item in media if item["timing"] != "words"],
              media_events=media, cue_events=cues)
print(json.dumps(result, indent=2))
