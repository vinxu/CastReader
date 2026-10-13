#!/usr/bin/env python3
"""Generate a frozen baseline and the current shelf script/fixture for WK QA."""

import argparse
import hashlib
import json
from pathlib import Path
import re


report = Path(__file__).resolve().parent
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=report.parents[1] / "CastReader/Services/GoogleBooksWebScripts.swift")
parser.add_argument("--output", type=Path, default=report / "generated")
args = parser.parse_args()
source = args.source.read_text()


def swift_raw_literal(name: str) -> str:
    match = re.search(r"static let " + re.escape(name) + r' = #"""(.*?)"""#', source, re.S)
    if not match:
        raise SystemExit(f"Cannot locate the raw Swift string for {name}")
    return match.group(1)


artifacts = {
    "baseline-library-scan.js": (report / "baseline-library-scan.js").read_text(),
    "fixed-library-scan.js": swift_raw_literal("libraryScan"),
    "hundred-books.html": swift_raw_literal("debugHundredBookShelfFixture"),
}
args.output.mkdir(parents=True, exist_ok=True)
for name, content in artifacts.items():
    (args.output / name).write_text(content)
manifest = {
    "baseline_origin": "Verbatim libraryScan captured before this task changed it; no live account state.",
    "fixed_origin": "Current GoogleBooksWebScripts.swift raw libraryScan string.",
    "fixture_origin": "Current DEBUG debugHundredBookShelfFixture: observed Google custom-element/card structure, synthetic metadata only.",
    "sha256": {name: hashlib.sha256(content.encode()).hexdigest() for name, content in artifacts.items()},
}
(args.output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print(f"Prepared {len(artifacts)} synthetic reproduction artifacts")
