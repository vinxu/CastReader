#!/usr/bin/env python3
"""Fault-injection checks for the independent offline-book verifier."""
import base64
import copy
import hashlib
import importlib.util
import json
import tempfile
from pathlib import Path

spec = importlib.util.spec_from_file_location("book_verifier", Path(__file__).with_name("verify-kindle-offline-book.py"))
verifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verifier)

def digest(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()

with tempfile.TemporaryDirectory(prefix="kindle-manifest-faults-") as folder:
    root = Path(folder)
    book_id = digest("fixture")
    generation = "00000000-0000-0000-0000-000000000001"
    resources = root / book_id / generation / book_id
    resources.mkdir(parents=True)
    image = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")
    snapshot = json.dumps({"version": 1, "paragraphs": [{"text": ""}]}).encode()
    image_hash, snapshot_hash = digest(image), digest(snapshot)
    (resources / (image_hash + ".image")).write_bytes(image)
    (resources / (snapshot_hash + ".page")).write_bytes(snapshot)
    pages = []
    for ordinal, (start, end) in enumerate([(0, 2), (3, 10), (10, 20)]):
        key = digest(f"{generation}:{ordinal}:{start}:{end}")
        resource = {"id": digest(f"{key}:{image_hash}:{snapshot_hash}"), "pageKeyHash": key,
                    "imageHash": image_hash, "snapshotHash": snapshot_hash, "byteCount": len(image) + len(snapshot)}
        pages.append({"ordinal": ordinal, "position": {"start": start, "end": end, "minimum": 0,
                       "maximum": 20, "layoutID": "same-layout"}, "resource": resource})
    (resources / "index.json").write_text(json.dumps({"pages": [p["resource"] for p in pages]}))
    book = {"version": 1, "id": book_id, "generation": generation, "pages": pages,
            "status": "complete", "originalPositionRestored": True, "readingPosition": {"page": 0}}
    manifest = root / (book_id + ".book")
    manifest.write_text(json.dumps(book))
    result = verifier.verify(manifest)
    assert result["pages"] == 3 and result["uniqueImages"] == 1, "Equal images must retain separate page occurrences"
    cases = {}
    bad = copy.deepcopy(book); del bad["pages"][1]; cases["missing middle"] = bad
    bad = copy.deepcopy(book); del bad["pages"][-1]; cases["missing end"] = bad
    bad = copy.deepcopy(book); bad["pages"][2]["position"]["start"] = 5; cases["interior overlap"] = bad
    bad = copy.deepcopy(book); bad["pages"][2]["position"] = bad["pages"][1]["position"]; cases["duplicate page"] = bad
    bad = copy.deepcopy(book); bad["pages"][1], bad["pages"][2] = bad["pages"][2], bad["pages"][1]; cases["wrong order"] = bad
    bad = copy.deepcopy(book); bad["pages"][1]["resource"], bad["pages"][2]["resource"] = bad["pages"][2]["resource"], bad["pages"][1]["resource"]; cases["swapped image references"] = bad
    for label, bad in cases.items():
        manifest.write_text(json.dumps(bad))
        try:
            verifier.verify(manifest)
        except AssertionError:
            print(label + ": rejected")
        else:
            raise AssertionError(label + " was accepted")
    print("Independent manifest verifier: 6 injected faults rejected; identical-image page occurrences retained.")
