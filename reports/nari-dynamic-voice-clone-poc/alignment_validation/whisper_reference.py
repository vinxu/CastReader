#!/usr/bin/env python3
"""Independent offline reference, not manual ground truth or runtime dependency."""
import hashlib
import json
from pathlib import Path
import time

import mlx_whisper


root = Path("build/alignment-evidence")
model = "/Users/xuxuheng/.cache/huggingface/hub/models--mlx-community--whisper-base-mlx/snapshots/1e3e249fb8d01c655324bd6841b1deadffd6d04c"
prior = Path("/Users/xuxuheng/Documents/.worktrees/CastReader-Android-kindle-ios-parity-20260908/build/huawei-ios-parity-20260908")
prior_files = {
    "phone-00": ("clone-timing-sample.audio", "clone-timing-local-asr.json"),
    "phone-14": ("clone-collapsed-timing.audio", "clone-collapsed-timing-local-asr.json"),
}
results = []
for row in json.loads((root / "manifest.json").read_text()):
    cached = prior_files.get(row["id"])
    started = time.perf_counter()
    if cached:
        assert hashlib.sha256((prior/cached[0]).read_bytes()).hexdigest() == row["audio_sha256"]
        result = json.loads((prior/cached[1]).read_text())
        # Historical runner wraps its transcript under 'result'.
        result = result.get("result", result)
    else:
        result = mlx_whisper.transcribe(
            str(root / row["audio"]), path_or_hf_repo=model,
            language="en", word_timestamps=True, condition_on_previous_text=False,
        )
    results.append({"id":row["id"], "reference":result, "reused_verified_audio":bool(cached),
                    "elapsed_ms":(time.perf_counter()-started)*1000})
    (root/"whisper-reference.json").write_text(json.dumps(results,ensure_ascii=False,indent=2))
    print(row["id"], "reference saved", flush=True)
