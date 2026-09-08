"""Candidate-only adapter. Deliberately not wired into the production worker.

Preserve the worker's lexical tokens and wire fields. Reject unsupported or
invalid alignments instead of inventing durations, spreading zeros or silently
reverting to estimated timing. Admission/scheduling/HTTP policy needs separate
production integration and latency validation.
"""
from __future__ import annotations

import math
import unicodedata


class AlignmentRejected(ValueError):
    pass


def lexical_key(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).casefold()
    return "".join(c for c in normalized if unicodedata.category(c)[0] in {"L", "N"})


def to_worker_timestamps(source_tokens, aligned_words, *, duration, synthesis_speed=1.0):
    """Aligner clocks are before server speed conversion; device playback rate is unrelated."""
    if not math.isfinite(duration) or duration <= 0 or not math.isfinite(synthesis_speed) or synthesis_speed <= 0:
        raise AlignmentRejected("invalid-audio-clock")
    if len(source_tokens) != len(aligned_words):
        raise AlignmentRejected("token-count-mismatch")
    timestamps = []
    previous_start = previous_end = 0.0
    for token, aligned in zip(source_tokens, aligned_words):
        if not lexical_key(token) or lexical_key(token) != lexical_key(aligned["text"]):
            raise AlignmentRejected("token-identity-mismatch")
        start, end = aligned["start_time"]/synthesis_speed, aligned["end_time"]/synthesis_speed
        if not (math.isfinite(start) and math.isfinite(end) and 0 <= start < end <= duration + .050):
            raise AlignmentRejected("invalid-word-interval")
        if start + .001 < previous_start or end + .001 < previous_end:
            raise AlignmentRejected("non-monotonic-interval")
        timestamps.append({"word":token, "start_time":round(start,6), "end_time":round(end,6)})
        previous_start, previous_end = start, end
    return timestamps
