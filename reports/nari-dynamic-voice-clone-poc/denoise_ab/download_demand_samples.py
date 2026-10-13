#!/usr/bin/env python3
"""Download a small, deterministic DEMAND environmental-noise evaluation set.

The upstream recording is DEMAND (CC BY-SA 3.0):
https://zenodo.org/records/1227121

This downloader uses the segmented 48 kHz Hugging Face mirror so the A/B test
does not need to fetch the complete 7.4 GB corpus.  Each selected row is the
first channel/segment of one environment and remains an unmodified WAV file.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


DATASET = "philgzl/demand"
CONFIG = "default"
SPLIT = "48k"
ROWS_PER_ENVIRONMENT = 400
ENVIRONMENTS = (
    ("DKITCHEN", "indoor-kitchen"),
    ("DLIVING", "indoor-living-room"),
    ("DWASHING", "indoor-washing-machine"),
    ("NFIELD", "outdoor-field"),
    ("NPARK", "outdoor-park"),
    ("OMEETING", "indoor-meeting-room"),
    ("OOFFICE", "indoor-office"),
    ("PCAFETER", "public-cafeteria"),
    ("PSTATION", "public-station"),
    ("SPSQUARE", "outdoor-public-square"),
    ("STRAFFIC", "outdoor-traffic"),
    ("TMETRO", "transport-metro"),
)
ALL_ENVIRONMENT_ORDER = (
    "DKITCHEN",
    "DLIVING",
    "DWASHING",
    "NFIELD",
    "NPARK",
    "NRIVER",
    "OHALLWAY",
    "OMEETING",
    "OOFFICE",
    "PCAFETER",
    "PRESTO",
    "PSTATION",
    "SCAFE",
    "SPSQUARE",
    "STRAFFIC",
    "TBUS",
    "TCAR",
    "TMETRO",
)
USER_AGENT = "CastReader-Denoise-AB/1.0"


def request_bytes(url: str, attempts: int = 8) -> bytes:
    delay = 2.0
    for attempt in range(1, attempts + 1):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=90) as response:
                return response.read()
        except urllib.error.HTTPError as error:
            if error.code not in {429, 500, 502, 503, 504} or attempt == attempts:
                raise
            retry_after = error.headers.get("Retry-After")
            wait = float(retry_after) if retry_after and retry_after.isdigit() else delay
        except (TimeoutError, urllib.error.URLError):
            if attempt == attempts:
                raise
            wait = delay
        time.sleep(min(wait, 30.0))
        delay = min(delay * 2, 30.0)
    raise RuntimeError("unreachable")


def row_url(offset: int) -> str:
    query = urllib.parse.urlencode(
        {
            "dataset": DATASET,
            "config": CONFIG,
            "split": SPLIT,
            "offset": offset,
            "length": 1,
        }
    )
    return f"https://datasets-server.huggingface.co/rows?{query}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    args.output_dir.mkdir(parents=True, exist_ok=True)

    records: list[dict[str, object]] = []
    for code, slug in ENVIRONMENTS:
        environment_index = ALL_ENVIRONMENT_ORDER.index(code)
        offset = environment_index * ROWS_PER_ENVIRONMENT
        payload = json.loads(request_bytes(row_url(offset)))
        row = payload["rows"][0]["row"]
        original_name = str(row["name"])
        if not original_name.startswith(f"{code}_48k/"):
            raise RuntimeError(
                f"dataset ordering changed at row {offset}: expected {code}, got {original_name}"
            )
        asset_url = str(row["audio"][0]["src"])
        destination = args.output_dir / f"{slug}.wav"
        if args.force or not destination.is_file():
            audio = request_bytes(asset_url)
            if len(audio) < 44 or audio[:4] != b"RIFF" or audio[8:12] != b"WAVE":
                raise RuntimeError(f"unexpected audio payload for {code}")
            destination.write_bytes(audio)
        audio = destination.read_bytes()
        records.append(
            {
                "environment": code,
                "category": slug,
                "dataset_row": offset,
                "original_name": original_name,
                "file": destination.name,
                "bytes": len(audio),
                "sha256": hashlib.sha256(audio).hexdigest(),
            }
        )
        print(f"downloaded {code} row={offset} file={destination.name}", flush=True)

    manifest = {
        "dataset": "DEMAND: Diverse Environments Multichannel Acoustic Noise Database",
        "source": "https://zenodo.org/records/1227121",
        "mirror": f"https://huggingface.co/datasets/{DATASET}",
        "license": "CC BY-SA 3.0 (upstream DEMAND recording)",
        "sample_rate_hz": 48_000,
        "records": records,
    }
    (args.output_dir / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
