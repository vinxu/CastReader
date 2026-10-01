"""PCM alignment and encoding with bounded, explicitly qualified timestamps."""
from __future__ import annotations

import base64
from concurrent.futures import Future, ThreadPoolExecutor, TimeoutError as FutureTimeout
from dataclasses import dataclass
import io
import math
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unicodedata

import numpy as np
import soundfile as sf

from alignment_contract import AlignmentRejected, lexical_key


MODEL_ID = "Qwen/Qwen3-ForcedAligner-0.6B"
MODEL_REVISION = "c7cbfc2048c462b0d63a45797104fc9db3ad62b7"
PIPELINE_REVISION = "qwen-pcm-measured-groups-v4-zh-candidate"
WORD_LANGUAGES = {
    "en": "English", "de": "German", "es": "Spanish", "fr": "French",
    "it": "Italian", "pt": "Portuguese", "ru": "Russian",
    "zh": "Chinese",
}
SEGMENT_LANGUAGES = {"ja", "ko"}


class AlignmentBusy(RuntimeError):
    pass


class PipelineCancelled(RuntimeError):
    pass


@dataclass(frozen=True)
class PCM:
    samples: np.ndarray
    sample_rate: int

    def __post_init__(self):
        if not isinstance(self.sample_rate, int) or self.sample_rate <= 0:
            raise ValueError("invalid-sample-rate")
        if self.samples.ndim != 1 or not 0 < len(self.samples) <= self.sample_rate * 120:
            raise ValueError("invalid-pcm-length")
        if not np.all(np.isfinite(self.samples)):
            raise ValueError("invalid-pcm-samples")

    @property
    def duration(self):
        return len(self.samples) / self.sample_rate


@dataclass(frozen=True)
class EncodedAudio:
    data: bytes
    duration: float


@dataclass(frozen=True)
class CaptionResult:
    response: dict
    duration: float
    reason: str
    timings: dict


def prepare_pcm(wav: bytes, speed=1.0):
    if not math.isfinite(speed) or not .5 <= speed <= 2.0:
        raise ValueError("unsupported-speed")
    if speed != 1.0:
        wav = subprocess.run(
            ["ffmpeg", "-v", "error", "-i", "pipe:0", "-filter:a", f"atempo={speed:.4f}",
             "-ac", "1", "-ar", "24000", "-f", "wav", "pipe:1"],
            input=wav, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            check=True, timeout=20,
        ).stdout
    samples, sample_rate = sf.read(io.BytesIO(wav), dtype="float32")
    if samples.ndim != 1:
        raise ValueError("invalid-pcm-channels")
    frame_samples = 1152 if sample_rate >= 32000 else 576
    padding = -len(samples) % frame_samples
    if padding:
        samples = np.pad(samples, (0, padding))
    return PCM(samples, sample_rate)


def encode_gapless(pcm: PCM):
    with tempfile.TemporaryDirectory(prefix="clone-align-encode-") as directory:
        path = Path(directory) / "audio.mp3"
        subprocess.run(
            ["ffmpeg", "-v", "error", "-f", "f32le", "-ar", str(pcm.sample_rate),
             "-ac", "1", "-i", "pipe:0", "-codec:a", "libmp3lame", "-b:a", "64k",
             "-write_xing", "1", str(path)],
            input=pcm.samples.astype("<f4").tobytes(), stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, check=True, timeout=20,
        )
        data = path.read_bytes()
        decoded, sample_rate = sf.read(io.BytesIO(data), dtype="float32")
    if sample_rate != pcm.sample_rate or len(decoded) != len(pcm.samples):
        raise ValueError("encoded-pcm-clock-mismatch")
    return EncodedAudio(data, len(decoded) / sample_rate)


def project_words(text, words, duration):
    """Restore source spans, never split a measured word into invented timings."""
    if not words or not math.isfinite(duration) or duration <= 0:
        raise AlignmentRejected("empty-alignment-or-clock")
    characters = []
    positions = []
    index = 0
    while index < len(text):
        stop = index + 1
        while stop < len(text) and unicodedata.combining(text[stop]):
            stop += 1
        for normalized in unicodedata.normalize("NFKC", text[index:stop]).casefold():
            if unicodedata.category(normalized)[0] in {"L", "N"}:
                characters.append(normalized)
                positions.append((index, stop))
        index = stop
    source_key = "".join(characters)
    keys = [lexical_key(word["text"]) for word in words]
    if not all(keys) or "".join(keys) != source_key:
        raise AlignmentRejected("text-coverage-mismatch")
    timestamps = []
    offset = 0
    previous_end = 0.0
    for word, key in zip(words, keys):
        start, end = float(word["start_time"]), float(word["end_time"])
        if not (math.isfinite(start) and math.isfinite(end) and 0 <= start < end <= duration):
            raise AlignmentRejected("invalid-word-interval")
        if start < previous_end:
            raise AlignmentRejected("overlapping-word-interval")
        source_start = positions[offset][0]
        source_end = positions[offset + len(key) - 1][1]
        if offset and source_start == positions[offset - 1][0]:
            raise AlignmentRejected("normalization-boundary-split")
        timestamps.append({"word": text[source_start:source_end], "start_time": start, "end_time": end})
        offset += len(key)
        previous_end = end
    return timestamps


def alignment_input_text(text):
    source = unicodedata.normalize("NFKC", text)
    characters = []
    for index, character in enumerate(source):
        category = unicodedata.category(character)
        previous = source[index - 1] if index else ""
        following = source[index + 1] if index + 1 < len(source) else ""
        apostrophe = character in {"'", "’"} and previous.isalpha() and following.isalpha()
        numeric_separator = character in {".", ","} and previous.isdigit() and following.isdigit()
        characters.append(character if category[0] in {"L", "N", "M"} or apostrophe or numeric_separator else " ")
    return " ".join("".join(characters).split())


class QwenPCMAligner:
    def __init__(self, device="mps", model_path=MODEL_ID, attention="eager"):
        import torch
        from qwen_asr import Qwen3ForcedAligner

        self.model = Qwen3ForcedAligner.from_pretrained(
            model_path, revision=MODEL_REVISION, local_files_only=True,
            dtype=torch.float32 if device == "cpu" else torch.float16,
            device_map=device, attn_implementation=attention,
        )

    def __call__(self, pcm, text, language):
        result = self.model.align(
            audio=(pcm.samples, pcm.sample_rate), text=alignment_input_text(text),
            language=WORD_LANGUAGES[language],
        )[0]
        return [{"text": word.text, "start_time": word.start_time, "end_time": word.end_time}
                for word in result.items]


def measured_word_groups(words, duration):
    if not words:
        raise AlignmentRejected("empty-alignment-or-clock")
    unresolved = []
    previous_end = 0.0
    for index, word in enumerate(words):
        start, end = float(word["start_time"]), float(word["end_time"])
        if not lexical_key(word["text"]) or not (
            math.isfinite(start) and math.isfinite(end) and 0 <= start <= end <= duration
        ):
            raise AlignmentRejected("invalid-word-interval")
        if start < previous_end:
            raise AlignmentRejected("overlapping-word-interval")
        if start == end:
            first, last = index, min(len(words) - 1, index + 1)
            if last == index or float(words[last]["start_time"]) - end > .081:
                first, last = max(0, index - 1), index
                if start - float(words[first]["end_time"]) > .081:
                    first = index
            if first == last:
                raise AlignmentRejected("unresolved-word-near-pause")
            if unresolved and first <= unresolved[-1][1]:
                unresolved[-1] = (unresolved[-1][0], last)
            else:
                unresolved.append((first, last))
        previous_end = end
    grouped = []
    index = 0
    ranges = dict(unresolved)
    while index < len(words):
        last = ranges.get(index, index)
        group = words[index:last + 1]
        start, end = float(group[0]["start_time"]), float(group[-1]["end_time"])
        if start >= end or (last > index and (len(group) > 7 or end - start > 2.0)):
            raise AlignmentRejected("unresolved-word-group-too-large")
        grouped.append({"text": " ".join(word["text"] for word in group),
                        "start_time": start, "end_time": end})
        index = last + 1
    return grouped


def reject_uncovered_zero_word_gaps(pcm, words):
    gaps = []
    for index, word in enumerate(words):
        start, end = float(word["start_time"]), float(word["end_time"])
        if start != end:
            continue
        left = float(words[index - 1]["end_time"]) + .08 if index else 0.0
        right = float(words[index + 1]["start_time"]) - .08 if index + 1 < len(words) else pcm.duration
        gaps.extend((lower, upper) for lower, upper in [(left, start - .08), (end + .08, right)]
                    if upper - lower >= .16)
    if not gaps:
        return
    frame_size = max(1, round(pcm.sample_rate * .02))
    frame_count = len(pcm.samples) // frame_size
    if not frame_count:
        return
    frames = pcm.samples[:frame_count * frame_size].reshape(-1, frame_size)
    levels = np.sqrt(np.mean(np.square(frames), axis=1))
    threshold = max(.005, float(np.percentile(levels, 90)) * .15)
    for lower, upper in gaps:
        first_frame, last_frame = math.ceil(lower / .02), math.floor(upper / .02)
        active_frames = 0
        for level in levels[first_frame:last_frame]:
            active_frames = active_frames + 1 if level > threshold else 0
            if active_frames >= 8:
                raise AlignmentRejected("uncovered-audio-near-unresolved-word")


class CaptionPipeline:
    """Single-flight aligner with bounded admission, overlapping caller-side encoding.

    A running model call cannot be forcibly cancelled. Its admission slot stays
    occupied until actual completion; late metadata never changes a response.
    This runner requires its own measured resource budget, not an uncoordinated
    thread added to the production GPU. Audio generation/settlement stay outside.
    """

    def __init__(self, aligner, *, encoder=encode_gapless, max_inflight=3, alignment_budget_s=2.0):
        if max_inflight < 1 or not math.isfinite(alignment_budget_s) or alignment_budget_s <= 0:
            raise ValueError("invalid-pipeline-capacity")
        self.aligner = aligner
        self.encoder = encoder
        self.budget = alignment_budget_s
        self.slots = threading.BoundedSemaphore(max_inflight)
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="clone-align")
        self.closed = False
        self.lock = threading.Lock()

    def close(self):
        with self.lock:
            self.closed = True
        self.executor.shutdown(wait=True, cancel_futures=True)

    def _submit(self, pcm, text, language, cancel):
        with self.lock:
            if self.closed or not self.slots.acquire(blocking=False):
                raise AlignmentBusy("alignment-not-admitted")
            submitted = time.perf_counter()

            def run():
                started = time.perf_counter()
                if cancel.is_set() or started - submitted >= self.budget:
                    raise PipelineCancelled("alignment-expired-before-start")
                words = self.aligner(pcm, text, language)
                return words, {"queue_ms": (started - submitted) * 1000,
                               "alignment_ms": (time.perf_counter() - started) * 1000}

            try:
                future = self.executor.submit(run)
            except BaseException:
                self.slots.release()
                raise
            future.add_done_callback(lambda completed: self.slots.release())
            return future, submitted

    def caption(self, pcm, *, text, language, voice_code, return_timestamps=True,
                overlap=True, cancel=None):
        cancel = cancel if cancel is not None else threading.Event()
        if cancel.is_set():
            raise PipelineCancelled("request-cancelled")
        with self.lock:
            if self.closed:
                raise RuntimeError("pipeline-closed")
        started = time.perf_counter()
        language = language.strip().lower().replace("_", "-").split("-", 1)[0]
        reason = "disabled" if not return_timestamps else "segment-language"
        eligible = return_timestamps and language in WORD_LANGUAGES
        if return_timestamps and language not in WORD_LANGUAGES and language not in SEGMENT_LANGUAGES:
            reason = "unsupported-language"
        future: Future | None = None
        submitted = started
        timings = {}
        timestamps = []

        def submit():
            try:
                return self._submit(pcm, text, language, cancel), "pending"
            except AlignmentBusy:
                return (None, time.perf_counter()), "overloaded"

        if eligible and overlap:
            (future, submitted), reason = submit()
        encoding_started = time.perf_counter()
        try:
            encoded = self.encoder(pcm)
        except BaseException:
            if future is not None:
                future.cancel()
            raise
        timings["encoding_ms"] = (time.perf_counter() - encoding_started) * 1000
        if not math.isfinite(encoded.duration) or abs(encoded.duration - pcm.duration) > 1 / pcm.sample_rate:
            if future is not None:
                future.cancel()
            raise ValueError("encoded-pcm-clock-mismatch")
        if cancel.is_set():
            if future is not None:
                future.cancel()
            raise PipelineCancelled("request-cancelled")
        if eligible and not overlap:
            (future, submitted), reason = submit()
        if future is not None:
            try:
                while True:
                    if cancel.is_set():
                        raise PipelineCancelled("request-cancelled")
                    remaining = self.budget - (time.perf_counter() - submitted)
                    if remaining <= 0 and not future.done():
                        reason = "deadline"
                        future.cancel()
                        break
                    try:
                        words, alignment_timings = future.result(timeout=max(0, min(.02, remaining)))
                        timings.update(alignment_timings)
                        if alignment_timings["queue_ms"] + alignment_timings["alignment_ms"] > self.budget * 1000:
                            reason = "deadline"
                            break
                        grouped = measured_word_groups(words, encoded.duration)
                        candidate = project_words(text, grouped, encoded.duration)
                        validation_started = time.perf_counter()
                        reject_uncovered_zero_word_gaps(pcm, words)
                        timings["validation_ms"] = (time.perf_counter() - validation_started) * 1000
                        timestamps = candidate
                        reason = "qwen-word" if len(grouped) == len(words) else "qwen-word-groups"
                        break
                    except FutureTimeout:
                        if future.done():
                            raise
            except PipelineCancelled:
                future.cancel()
                if cancel.is_set():
                    raise
                reason = "deadline"
            except AlignmentRejected as error:
                reason = str(error)
            except Exception:
                reason = "alignment-failed"
        if cancel.is_set():
            raise PipelineCancelled("request-cancelled")
        timings["postprocess_ms"] = (time.perf_counter() - started) * 1000
        return CaptionResult(
            response={"audio": base64.b64encode(encoded.data).decode("ascii"),
                      "audio_format": "audio/mpeg", "timestamps": timestamps, "voice_code": voice_code},
            duration=encoded.duration, reason=reason, timings=timings,
        )
