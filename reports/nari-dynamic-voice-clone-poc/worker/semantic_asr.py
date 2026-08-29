#!/usr/bin/env python3
"""Final-audio semantic validation and measured word timing for clone TTS.

The clone model is probabilistic.  A structurally valid prompt and a plausible
duration are useful admission checks, but neither proves that the returned PCM
contains only the requested text.  This module treats a local, pinned Whisper
checkpoint as the final authority: generated audio is transcribed before it can
leave the worker, and letter-language word timestamps come from that same final
waveform rather than from text-length interpolation.
"""

from __future__ import annotations

import difflib
import hashlib
import io
import math
import re
import threading
import time
import unicodedata
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import soundfile as sf
from opencc import OpenCC
from scipy.signal import resample_poly


LEXICAL_PATTERN = re.compile(
    r"\d+(?:[.,]\d+)?|[^\W\d_]+(?:['’\-][^\W\d_]+)?",
    re.UNICODE,
)
REQUIRED_MODEL_FILES = (
    "config.json",
    "generation_config.json",
    "model.safetensors",
    "preprocessor_config.json",
    "tokenizer.json",
)
WHISPER_SAMPLE_RATE = 16_000
TRADITIONAL_TO_SIMPLIFIED = OpenCC("t2s")


class SemanticASRError(RuntimeError):
    """Base class for a fail-safe final-audio validation failure."""


class SemanticASRUnavailable(SemanticASRError):
    """The pinned local ASR checkpoint cannot be loaded or executed."""


class SemanticAudioMismatch(SemanticASRError):
    """The final waveform does not faithfully contain the requested text."""

    def __init__(self, reason: str, metrics: dict[str, object]):
        super().__init__(reason)
        self.reason = reason
        self.metrics = metrics


@dataclass(frozen=True, slots=True)
class ASRWord:
    text: str
    start: float
    end: float


@dataclass(frozen=True, slots=True)
class SemanticASREvidence:
    transcript: str
    words: tuple[ASRWord, ...]
    requested_words: tuple[str, ...]
    similarity: float
    inference_seconds: float


def _canonical_token(value: str) -> str:
    decomposed = unicodedata.normalize(
        "NFKD",
        TRADITIONAL_TO_SIMPLIFIED.convert(value.casefold()),
    )
    return "".join(
        character
        for character in decomposed
        if unicodedata.category(character) != "Mn" and character.isalnum()
    )


_SMALL_NUMBERS = (
    "zero", "one", "two", "three", "four", "five", "six", "seven", "eight",
    "nine", "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen",
    "sixteen", "seventeen", "eighteen", "nineteen",
)
_TENS = ("", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety")


def _english_integer(value: int) -> str | None:
    if not 0 <= value <= 9_999:
        return None
    if value < 20:
        return _SMALL_NUMBERS[value]
    if value < 100:
        return _TENS[value // 10] + (_SMALL_NUMBERS[value % 10] if value % 10 else "")
    if value < 1_000:
        remainder = value % 100
        return (
            _SMALL_NUMBERS[value // 100]
            + "hundred"
            + (_english_integer(remainder) or "")
        )
    remainder = value % 1_000
    return (
        _SMALL_NUMBERS[value // 1_000]
        + "thousand"
        + (_english_integer(remainder) or "")
    )


def lexical_tokens(value: str, *, language: str = "") -> list[str]:
    result: list[str] = []
    for match in LEXICAL_PATTERN.finditer(value):
        raw = match.group(0)
        token = _canonical_token(raw)
        if language == "en" and raw.isdigit():
            spoken = _english_integer(int(token))
            if spoken is not None:
                token = spoken
        if token:
            result.append(token)
    return result


def canonical_text(value: str) -> str:
    return " ".join(lexical_tokens(value))


def _longest_reference_block(
    reference_tokens: list[str],
    observed_tokens: list[str],
) -> int:
    if not reference_tokens or not observed_tokens:
        return 0
    return max(
        (
            block.size
            for block in difflib.SequenceMatcher(
                None,
                reference_tokens,
                observed_tokens,
                autojunk=False,
            ).get_matching_blocks()
        ),
        default=0,
    )


def _similarity(expected: list[str], observed: list[str]) -> float:
    return difflib.SequenceMatcher(
        None,
        " ".join(expected),
        " ".join(observed),
        autojunk=False,
    ).ratio()


def validate_transcript(
    requested_text: str,
    transcript: str,
    *,
    reference_text: str = "",
    language: str = "",
) -> dict[str, object]:
    """Reject missing, additional, or reference-leaked speech.

    Whisper is used as evidence rather than an exact string oracle, so ordinary
    homophone/spelling substitutions are allowed within a conservative edit
    threshold.  Extra spoken words are bounded separately; this prevents a long
    reference prefix from passing merely because the requested suffix is also
    present.
    """

    expected = lexical_tokens(requested_text, language=language)
    observed = lexical_tokens(transcript, language=language)
    reference = lexical_tokens(reference_text, language=language)
    if not expected or not observed:
        raise SemanticAudioMismatch(
            "empty-asr-transcript",
            {
                "expected_word_count": len(expected),
                "observed_word_count": len(observed),
            },
        )
    similarity = _similarity(expected, observed)
    allowed_extra = max(1, min(3, round(len(expected) * 0.18)))
    extra_words = max(0, len(observed) - len(expected))
    reference_block = _longest_reference_block(reference, observed)
    metrics: dict[str, object] = {
        "expected_word_count": len(expected),
        "observed_word_count": len(observed),
        "extra_word_count": extra_words,
        "similarity": round(similarity, 4),
        "reference_block_words": reference_block,
    }

    # A reference match is only incriminating when the waveform also contains
    # additional words.  This avoids rejecting a legitimate target that happens
    # to reuse a few words from the recording script.
    leak_threshold = min(4, max(3, len(reference) // 4)) if reference else 99
    if extra_words > 0 and reference_block >= leak_threshold:
        raise SemanticAudioMismatch("reference-prefix-leak", metrics)
    if extra_words > allowed_extra:
        raise SemanticAudioMismatch("unexpected-extra-speech", metrics)

    minimum_similarity = 0.70 if len(expected) <= 2 else 0.78
    if similarity < minimum_similarity:
        raise SemanticAudioMismatch("requested-text-mismatch", metrics)
    return metrics


def measured_word_timestamps(
    requested_text: str,
    evidence: SemanticASREvidence,
    *,
    language: str,
    speed: float,
    duration: float,
) -> list[dict[str, object]]:
    """Map complete Whisper word boundaries back to the requested word labels.

    No interpolation is performed.  If Whisper did not produce exactly one
    measured boundary for every requested lexical word, the timing contract is
    not provable and the request fails closed.
    """

    request_matches = list(LEXICAL_PATTERN.finditer(requested_text))
    requested: list[tuple[str, str]] = []
    for match in request_matches:
        tokens = lexical_tokens(match.group(0), language=language)
        if tokens:
            requested.append((match.group(0), tokens[0]))
    observed: list[tuple[ASRWord, str]] = []
    for word in evidence.words:
        tokens = lexical_tokens(word.text, language=language)
        if tokens:
            observed.append((word, tokens[0]))
    if len(observed) < len(requested):
        raise SemanticAudioMismatch(
            "word-alignment-incomplete",
            {
                "expected_word_count": len(requested),
                "observed_word_count": len(observed),
                "similarity": round(evidence.similarity, 4),
            },
        )
    if speed <= 0 or duration <= 0:
        raise SemanticAudioMismatch("invalid-audio-timing", {})

    # Partition one or more measured Whisper words onto each request token.
    # This handles spoken-number expansion ("26" -> "twenty" + "six") without
    # inventing any boundary.  We never split one ASR word into several request
    # words because that would require interpolation.
    count_expected = len(requested)
    count_observed = len(observed)
    costs: dict[tuple[int, int], tuple[float, tuple[int, ...]]] = {(0, 0): (0.0, ())}
    for expected_index in range(count_expected):
        for observed_start in range(count_observed + 1):
            state = costs.get((expected_index, observed_start))
            if state is None:
                continue
            remaining_expected = count_expected - expected_index - 1
            maximum_end = count_observed - remaining_expected
            for observed_end in range(observed_start + 1, maximum_end + 1):
                combined = "".join(item[1] for item in observed[observed_start:observed_end])
                token_similarity = difflib.SequenceMatcher(
                    None,
                    requested[expected_index][1],
                    combined,
                    autojunk=False,
                ).ratio()
                candidate = (state[0] + (1.0 - token_similarity), state[1] + (observed_end,))
                key = (expected_index + 1, observed_end)
                if key not in costs or candidate[0] < costs[key][0]:
                    costs[key] = candidate
    final = costs.get((count_expected, count_observed))
    if final is None:
        raise SemanticAudioMismatch("word-alignment-incomplete", {})

    timestamps: list[dict[str, object]] = []
    previous_end = 0.0
    observed_start = 0
    for (label, expected), observed_end in zip(requested, final[1]):
        group = observed[observed_start:observed_end]
        actual = "".join(item[1] for item in group)
        token_similarity = difflib.SequenceMatcher(
            None, expected, actual, autojunk=False
        ).ratio()
        # One-to-one homophone substitutions are acceptable when the complete
        # sentence already passed its stronger transcript gate.  A fully
        # unrelated token is not a trustworthy word boundary.
        if token_similarity < 0.35 and evidence.similarity < 0.90:
            raise SemanticAudioMismatch(
                "word-alignment-low-confidence",
                {
                    "token_similarity": round(token_similarity, 4),
                    "similarity": round(evidence.similarity, 4),
                },
            )
        start = min(duration, max(previous_end, group[0][0].start / speed))
        end = min(duration, max(start, group[-1][0].end / speed))
        if end <= start:
            raise SemanticAudioMismatch("word-alignment-empty-boundary", {})
        timestamps.append(
            {
                "word": label,
                "start_time": round(start, 6),
                "end_time": round(end, 6),
            }
        )
        previous_end = end
        observed_start = observed_end
    return timestamps


class SemanticASRValidator:
    """Thread-safe lazy wrapper around a pinned local Whisper checkpoint."""

    def __init__(self, model_directory: str | Path) -> None:
        self.model_directory = Path(model_directory).expanduser().resolve()
        missing = [
            name for name in REQUIRED_MODEL_FILES
            if not (self.model_directory / name).is_file()
        ]
        if missing:
            raise SemanticASRUnavailable(
                "local ASR checkpoint is incomplete: " + ", ".join(missing)
            )
        self._lock = threading.Lock()
        self._inference_lock = threading.Lock()
        self._pipeline = None

    @property
    def loaded(self) -> bool:
        return self._pipeline is not None

    def warmup(self) -> None:
        self._get_pipeline()

    def _get_pipeline(self):
        if self._pipeline is not None:
            return self._pipeline
        with self._lock:
            if self._pipeline is None:
                try:
                    import torch
                    from transformers import (
                        AutoModelForSpeechSeq2Seq,
                        AutoProcessor,
                        pipeline,
                    )

                    processor = AutoProcessor.from_pretrained(
                        self.model_directory,
                        local_files_only=True,
                    )
                    model = AutoModelForSpeechSeq2Seq.from_pretrained(
                        self.model_directory,
                        local_files_only=True,
                        dtype=torch.float32,
                    )
                    model.eval()
                    self._pipeline = pipeline(
                        "automatic-speech-recognition",
                        model=model,
                        tokenizer=processor.tokenizer,
                        feature_extractor=processor.feature_extractor,
                        device=-1,
                        dtype=torch.float32,
                    )
                except Exception as error:
                    raise SemanticASRUnavailable(
                        "could not load the pinned local ASR checkpoint"
                    ) from error
        return self._pipeline

    def validate(
        self,
        wav_bytes: bytes,
        requested_text: str,
        *,
        language: str,
        reference_text: str = "",
    ) -> SemanticASREvidence:
        try:
            audio, sample_rate = sf.read(
                io.BytesIO(wav_bytes),
                dtype="float32",
                always_2d=True,
            )
        except (RuntimeError, ValueError) as error:
            raise SemanticAudioMismatch("invalid-final-audio", {}) from error
        if audio.size == 0 or sample_rate <= 0:
            raise SemanticAudioMismatch("empty-final-audio", {})
        mono = audio.mean(axis=1, dtype=np.float32)
        if sample_rate != WHISPER_SAMPLE_RATE:
            divisor = math.gcd(sample_rate, WHISPER_SAMPLE_RATE)
            mono = resample_poly(
                mono,
                WHISPER_SAMPLE_RATE // divisor,
                sample_rate // divisor,
            ).astype(np.float32, copy=False)
            sample_rate = WHISPER_SAMPLE_RATE
        recognizer = self._get_pipeline()
        started = time.perf_counter()
        try:
            with self._inference_lock:
                generate_kwargs = {"task": "transcribe"}
                if language:
                    generate_kwargs["language"] = language
                result = recognizer(
                    {"array": mono, "sampling_rate": sample_rate},
                    generate_kwargs=generate_kwargs,
                    return_timestamps="word",
                )
        except Exception as error:
            raise SemanticASRUnavailable("final-audio ASR failed") from error
        inference_seconds = time.perf_counter() - started
        transcript = result.get("text") if isinstance(result, dict) else None
        chunks = result.get("chunks") if isinstance(result, dict) else None
        if not isinstance(transcript, str) or not isinstance(chunks, list):
            raise SemanticASRUnavailable("final-audio ASR returned an invalid result")
        try:
            metrics = validate_transcript(
                requested_text,
                transcript,
                reference_text=reference_text,
                language=language,
            )
        except SemanticAudioMismatch as error:
            error.metrics["transcript_sha256"] = hashlib.sha256(
                transcript.encode("utf-8")
            ).hexdigest()
            raise
        words: list[ASRWord] = []
        for chunk in chunks:
            if not isinstance(chunk, dict):
                continue
            text = chunk.get("text")
            timestamps = chunk.get("timestamp")
            if (
                not isinstance(text, str)
                or not isinstance(timestamps, (tuple, list))
                or len(timestamps) != 2
                or not isinstance(timestamps[0], (float, int))
                or not isinstance(timestamps[1], (float, int))
            ):
                continue
            start, end = float(timestamps[0]), float(timestamps[1])
            if start < 0 or end <= start:
                continue
            words.append(ASRWord(text=text, start=start, end=end))
        return SemanticASREvidence(
            transcript=transcript,
            words=tuple(words),
            requested_words=tuple(lexical_tokens(requested_text, language=language)),
            similarity=float(metrics["similarity"]),
            inference_seconds=inference_seconds,
        )
