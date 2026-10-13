#!/bin/sh
set -eu
report_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
python3 "$report_dir/prepare_reproduction.py"
xcrun swift "$report_dir/run_wk_probe.swift" "$report_dir/generated/baseline-library-scan.js" "$report_dir/generated/hundred-books.html" baseline "$report_dir/generated/baseline-result.json"
xcrun swift "$report_dir/run_wk_probe.swift" "$report_dir/generated/fixed-library-scan.js" "$report_dir/generated/hundred-books.html" fixed "$report_dir/generated/fixed-result.json"
python3 - "$report_dir" <<'PY'
import json
from pathlib import Path
import sys

folder = Path(sys.argv[1]) / "generated"
baseline = json.loads((folder / "baseline-result.json").read_text())
fixed = json.loads((folder / "fixed-result.json").read_text())
assert baseline["reported_complete"] and baseline["unique_books_collected"] < 100, "Baseline did not reproduce false completion"
assert fixed["reported_complete"] and fixed["unique_books_collected"] == 100, "Fixed scan did not collect all 100 books"
print("Verified baseline false completion and fixed 100-book collection")
PY
