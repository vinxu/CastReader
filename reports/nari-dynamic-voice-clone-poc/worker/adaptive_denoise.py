#!/usr/bin/env python3
"""Production-safe adaptive DeepFilterNet selection for clone references.

The module deliberately keeps policy and CPU-only signal processing separate
from the worker's GPU orchestration.  It never owns a production voice path:
callers supply a private build directory and publish only the selected prompt.
"""

from __future__ import annotations

import hashlib
import math
import os
import signal as process_signal
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import numpy as np
import soundfile as sf
from scipy import signal


SELECTOR_VERSION = "adaptive-deepfilter-24-100-v1"
PROBE_VERSION = "clone-denoise-probe-v1"
DEEPFILTER_VERSION = "0.5.6"
DEEPFILTER_SAMPLE_RATE = 48_000
PROBE_SEEDS = (20260902, 20260903, 20260904)
SUPPORTED_MODES = frozenset({"off", "shadow", "canary", "on"})
DEFAULT_DEEPFILTER_SHA256 = (
    "70775e251eee44c0f2451a1e833326cf8bcbbe304d3e7cd12851e6fce72ef7da"
)
DEFAULT_DIARIZATION_SHA256 = (
    "220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079"
)
DEFAULT_SPEAKER_SHA256 = (
    "f682b514c05d947ee3fa91cd6ec6c5c7543479a128373fa29b1faedccd21fd11"
)
MINIMUM_LOW_ENERGY_FRAMES = 30
MATERIAL_DELTA = 0.030
MAXIMUM_SINGLE_SEED_REGRESSION = 0.020
QWEN_PROMPT_COSINE_FLOOR = 0.90
RELATIVE_SPEAKER_FLOOR = 0.05
MECHANICAL_FLATNESS_CEILING = 0.060
CLEAN_SPECTRAL_FLATNESS_CEILING = 0.075

PROBE_TEXT_ZH = (
    "今天我们继续测试声音克隆。请保持自然、清晰和稳定的语气，"
    "让每一个字都容易听懂。"
)
PROBE_TEXT_EN = (
    "Today we are testing voice cloning with a clear, natural, and steady "
    "speaking style for every sentence."
)


class AdaptiveDenoiseError(RuntimeError):
    """A recoverable enhancement or selector failure.

    Production creation reports a retryable failure without publishing a raw
    prompt. Legacy selector helpers remain available for offline experiments.
    This exception must never be used for raw reference quality failures.
    """


class DiarizationUnavailable(RuntimeError):
    """The raw, pre-enhancement multi-speaker safety gate could not run."""


@dataclass(frozen=True, slots=True)
class DenoiseDecision:
    selected: str
    reason: str
    material_100_wins: int
    material_100_regressions: int
    material_raw_wins: int
    valid_seed_count: int


@dataclass(frozen=True, slots=True)
class DiarizationEvidence:
    speaker_count: int
    segments: tuple[dict[str, float | int], ...]
    speaker_durations_s: tuple[float, ...]
    overlap_duration_s: float
    second_speaker_duration_s: float
    elapsed_s: float
    backend: str = "sherpa-onnx-pyannote-segmentation-3.0"

    @property
    def competing_speech(self) -> bool:
        # A brief cluster split can be a phonetic change from the same speaker.
        # Require meaningful secondary speech, or explicit overlapping speech.
        return self.speaker_count >= 2 and (
            self.second_speaker_duration_s >= 0.80
            or (
                self.second_speaker_duration_s >= 0.35
                and self.overlap_duration_s >= 0.20
            )
        )

    def as_metrics(self) -> dict[str, Any]:
        return {
            "backend": self.backend,
            "speaker_count": self.speaker_count,
            "speaker_durations_s": list(self.speaker_durations_s),
            "overlap_duration_s": round(self.overlap_duration_s, 3),
            "second_speaker_duration_s": round(self.second_speaker_duration_s, 3),
            "competing_speech": self.competing_speech,
            "elapsed_s": round(self.elapsed_s, 3),
            "segments": [dict(item) for item in self.segments],
        }


def sha256_file(path: Path) -> str | None:
    try:
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for chunk in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(chunk)
        return digest.hexdigest()
    except OSError:
        return None


def configured_mode(value: str | None) -> str:
    normalized = (value or "off").strip().lower()
    return normalized if normalized in SUPPORTED_MODES else "off"


def runtime_mode(configured: str, override_path: Path) -> tuple[str, str]:
    """Resolve the hot mode switch on every creation request.

    Writing ``off`` to the override is an immediate, restart-free rollback.
    An invalid or unreadable override fails closed to the original pipeline.
    """

    if not override_path.exists():
        return configured_mode(configured), "environment"
    try:
        raw = override_path.read_text(encoding="utf-8").strip().lower()
    except OSError:
        return "off", "override-unreadable"
    if raw not in SUPPORTED_MODES:
        return "off", "override-invalid"
    return raw, "override-file"


def canary_selected(voice_id: str, percent: int) -> bool:
    bounded = min(100, max(0, int(percent)))
    bucket = int.from_bytes(
        hashlib.sha256(voice_id.encode("utf-8")).digest()[:4], "big"
    ) % 10_000
    return bucket < bounded * 100


def should_apply(mode: str, voice_id: str, canary_percent: int) -> bool:
    if mode == "on" or mode == "shadow":
        return True
    if mode == "canary":
        return canary_selected(voice_id, canary_percent)
    return False


def probe_text(language_code: str) -> tuple[str, str]:
    return (
        (PROBE_TEXT_ZH, "zh")
        if language_code.strip().lower().split("-", 1)[0] == "zh"
        else (PROBE_TEXT_EN, "en")
    )


def raw_bypass_reason(metrics: dict[str, Any], warnings: Iterable[str]) -> str | None:
    """Return why DeepFilter must not run for this already valid reference."""

    snr = metrics.get("snr_db")
    reliable = metrics.get("noise_estimate_reliable") is True
    flatness = metrics.get("broadband_flatness")
    warning_set = set(warnings)
    if isinstance(snr, (float, int)) and not isinstance(snr, bool):
        if float(snr) >= 18.0 and "background_noise_detected" not in warning_set:
            return "clean-reliable-snr"
        if (
            reliable
            and float(snr) < 18.0
            and isinstance(flatness, (float, int))
            and not isinstance(flatness, bool)
            and float(flatness) <= MECHANICAL_FLATNESS_CEILING
        ):
            # 03 washing-machine was the only subjective regression even though
            # its electrical proxy improved. Keep periodic/narrow-band noise on
            # the original path until a dedicated mechanical-noise branch is
            # independently validated.
            return "periodic-mechanical-noise-conservative-bypass"
    if (
        not reliable
        and snr is None
        and isinstance(flatness, (float, int))
        and not isinstance(flatness, bool)
        and float(flatness) <= CLEAN_SPECTRAL_FLATNESS_CEILING
    ):
        # Continuous speech may leave no VAD-labelled noise frames. Low
        # broadband flatness is the existing quality profile's clean-speech
        # backstop; it separates the clean control from every noisy fixture in
        # the frozen 12-sample matrix without relying on generated audio.
        return "clean-spectral-backstop"
    # A continuous appliance, traffic, or crowd bed can make the energy VAD
    # label every frame as speech. That produces no SNR estimate even though
    # the recording is exactly the kind that benefits from this selector. Do
    # not bypass it here: incomplete probes and identity checks still fall
    # back to the validated original prompt.
    return None


def cosine(left: np.ndarray, right: np.ndarray) -> float:
    left64 = np.asarray(left, dtype=np.float64).reshape(-1)
    right64 = np.asarray(right, dtype=np.float64).reshape(-1)
    denominator = math.sqrt(float(np.dot(left64, left64)) * float(np.dot(right64, right64)))
    if denominator <= 1e-12:
        return 0.0
    return float(np.dot(left64, right64) / denominator)


def low_energy_artifact_metrics(
    audio: np.ndarray,
    sample_rate: int,
) -> dict[str, float | int | None]:
    """Measure the electrical-noise proxy frozen by the blind experiment."""

    samples = np.asarray(audio, dtype=np.float32).reshape(-1)
    frame_length = round(0.080 * sample_rate)
    hop = round(0.020 * sample_rate)
    window = np.hanning(frame_length)
    frequencies = np.fft.rfftfreq(frame_length, 1 / sample_rate)
    speech_band = (frequencies >= 80) & (
        frequencies <= min(11_500, sample_rate / 2)
    )
    high_band = frequencies >= min(6_500, sample_rate / 2)
    flat_band = (frequencies >= 100) & (
        frequencies <= min(10_000, sample_rate / 2)
    )
    rows: list[tuple[float, float, float]] = []
    offsets = range(0, max(1, samples.size - frame_length + 1), hop)
    for offset in offsets:
        frame = samples[offset : offset + frame_length]
        if frame.size < frame_length:
            frame = np.pad(frame, (0, frame_length - frame.size))
        rms = float(np.sqrt(np.mean(np.square(frame, dtype=np.float64))))
        rms_dbfs = 20 * math.log10(max(rms, 1e-12))
        power = np.abs(np.fft.rfft(frame * window)) ** 2
        total_power = float(np.sum(power[speech_band])) + 1e-18
        high_ratio = float(np.sum(power[high_band])) / total_power
        selected = power[flat_band] + 1e-18
        flatness = float(np.exp(np.mean(np.log(selected))) / np.mean(selected))
        rows.append((rms_dbfs, flatness, high_ratio))
    values = np.asarray(rows, dtype=np.float64)
    low_energy = (values[:, 0] > -60) & (values[:, 0] < -30)
    suspicious = low_energy & (values[:, 1] > 0.10) & (values[:, 2] > 0.04)
    low_count = int(np.sum(low_energy))
    return {
        "frame_count": int(values.shape[0]),
        "low_energy_frame_count": low_count,
        "low_energy_median_flatness": (
            round(float(np.median(values[low_energy, 1])), 6)
            if low_count
            else None
        ),
        "low_energy_median_high_frequency_ratio": (
            round(float(np.median(values[low_energy, 2])), 6)
            if low_count
            else None
        ),
        "suspicious_fraction_all_frames": round(float(np.mean(suspicious)), 6),
        "suspicious_fraction_low_energy_frames": round(
            float(np.sum(suspicious)) / max(low_count, 1), 6
        ),
    }


def select_branch(
    per_seed: Iterable[dict[str, Any]],
    *,
    atten24_eligible: bool,
    atten100_eligible: bool,
) -> DenoiseDecision:
    """Apply the frozen 2-of-3 repeatability rule without a clean oracle."""

    valid = [
        item
        for item in per_seed
        if all(
            isinstance(item.get(key), (float, int))
            and not isinstance(item.get(key), bool)
            for key in ("online_e", "atten24_e", "atten100_e")
        )
        and min(
            int(item.get("online_low_frames", 0)),
            int(item.get("atten24_low_frames", 0)),
            int(item.get("atten100_low_frames", 0)),
        )
        >= MINIMUM_LOW_ENERGY_FRAMES
    ]
    if not atten24_eligible:
        return DenoiseDecision(
            selected="online",
            reason="atten24-identity-or-quality-guard-failed",
            material_100_wins=0,
            material_100_regressions=0,
            material_raw_wins=0,
            valid_seed_count=len(valid),
        )
    if len(valid) < 3:
        return DenoiseDecision(
            selected="atten24",
            reason="paired-probe-evidence-incomplete-conservative-default",
            material_100_wins=0,
            material_100_regressions=0,
            material_raw_wins=0,
            valid_seed_count=len(valid),
        )
    wins_100 = sum(
        float(item["atten24_e"]) - float(item["atten100_e"]) >= MATERIAL_DELTA
        for item in valid
    )
    regressions_100 = sum(
        float(item["atten100_e"]) - float(item["atten24_e"])
        > MAXIMUM_SINGLE_SEED_REGRESSION
        for item in valid
    )
    promote_100 = (
        atten100_eligible
        and wins_100 >= 2
        and regressions_100 == 0
    )
    provisional = "atten100" if promote_100 else "atten24"
    raw_wins = sum(
        float(item[f"{provisional}_e"]) - float(item["online_e"])
        >= MATERIAL_DELTA
        for item in valid
    )
    if raw_wins >= 2:
        selected = "online"
        reason = f"{provisional}-electrical-regression-repeatable"
    elif promote_100:
        selected = "atten100"
        reason = "atten100-electrical-improvement-repeatable"
    else:
        selected = "atten24"
        reason = "atten24-conservative-default"
    return DenoiseDecision(
        selected=selected,
        reason=reason,
        material_100_wins=wins_100,
        material_100_regressions=regressions_100,
        material_raw_wins=raw_wins,
        valid_seed_count=len(valid),
    )


def _resample(audio: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    samples = np.asarray(audio, dtype=np.float32)
    if samples.ndim == 2:
        samples = np.mean(samples, axis=1, dtype=np.float32)
    if source_rate == target_rate:
        return samples.astype(np.float32, copy=False)
    divisor = math.gcd(source_rate, target_rate)
    return signal.resample_poly(
        samples,
        target_rate // divisor,
        source_rate // divisor,
    ).astype(np.float32, copy=False)


class DeepFilterRunner:
    def __init__(self, binary: Path, expected_sha256: str) -> None:
        self.binary = binary
        self.expected_sha256 = expected_sha256.strip().lower()
        self._status_lock = threading.Lock()
        self._status_key: tuple[int, int] | None = None
        self._verified = False

    def status(self) -> dict[str, Any]:
        try:
            stat = self.binary.stat()
            key = (stat.st_mtime_ns, stat.st_size)
        except OSError:
            return {
                "ready": False,
                "version": DEEPFILTER_VERSION,
                "binary": str(self.binary),
                "sha256": None,
                "reason": "binary-missing",
            }
        with self._status_lock:
            if key != self._status_key:
                actual = sha256_file(self.binary)
                self._verified = bool(
                    actual
                    and len(self.expected_sha256) == 64
                    and actual == self.expected_sha256
                    and os.access(self.binary, os.X_OK)
                )
                self._status_key = key
            else:
                actual = self.expected_sha256 if self._verified else sha256_file(self.binary)
        return {
            "ready": self._verified,
            "version": DEEPFILTER_VERSION,
            "binary": str(self.binary),
            "sha256": actual,
            "reason": None if self._verified else "binary-hash-or-mode-mismatch",
        }

    def enhance(
        self,
        audio: np.ndarray,
        sample_rate: int,
        *,
        attenuation_db: int,
        work_dir: Path,
        deadline_at: float,
        cancelled: threading.Event,
    ) -> tuple[np.ndarray, int, float]:
        if attenuation_db not in {24, 100}:
            raise ValueError("attenuation_db must be 24 or 100")
        if not self.status()["ready"]:
            raise AdaptiveDenoiseError("DeepFilter binary is unavailable or untrusted")
        branch_dir = work_dir / f"atten-{attenuation_db}"
        output_dir = branch_dir / "output"
        branch_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
        output_dir.mkdir(mode=0o700)
        source = branch_dir / "reference.wav"
        samples_48k = _resample(audio, sample_rate, DEEPFILTER_SAMPLE_RATE)
        sf.write(source, samples_48k, DEEPFILTER_SAMPLE_RATE, subtype="PCM_16")
        started = time.perf_counter()
        process = subprocess.Popen(
            [
                str(self.binary),
                "-a",
                str(attenuation_db),
                "-D",
                "-o",
                str(output_dir),
                str(source),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
            env={**os.environ, "RUST_LOG": "warn"},
        )
        try:
            while process.poll() is None:
                if cancelled.is_set() or time.monotonic() >= deadline_at:
                    try:
                        os.killpg(process.pid, process_signal.SIGTERM)
                    except ProcessLookupError:
                        pass
                    try:
                        process.wait(timeout=1.0)
                    except subprocess.TimeoutExpired:
                        try:
                            os.killpg(process.pid, process_signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    raise AdaptiveDenoiseError("DeepFilter was cancelled or timed out")
                time.sleep(0.025)
            stdout, stderr = process.communicate(timeout=1.0)
        except BaseException:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, process_signal.SIGKILL)
                except ProcessLookupError:
                    pass
            raise
        if process.returncode != 0:
            detail = (stderr or stdout or "unknown error").strip().splitlines()[-1:]
            raise AdaptiveDenoiseError(
                f"DeepFilter failed ({process.returncode}): {' '.join(detail)[:160]}"
            )
        generated = output_dir / source.name
        if not generated.is_file():
            raise AdaptiveDenoiseError("DeepFilter did not produce the expected WAV")
        try:
            enhanced, enhanced_rate = sf.read(
                generated,
                dtype="float32",
                always_2d=True,
            )
        except (RuntimeError, ValueError) as error:
            raise AdaptiveDenoiseError("DeepFilter produced an invalid WAV") from error
        mono = np.mean(enhanced, axis=1, dtype=np.float32)
        if mono.size == 0 or not np.isfinite(mono).all():
            raise AdaptiveDenoiseError("DeepFilter produced invalid samples")
        return mono, int(enhanced_rate), time.perf_counter() - started


class SpeakerDiarizer:
    def __init__(
        self,
        segmentation_model: Path,
        embedding_model: Path,
        *,
        cluster_threshold: float = 0.30,
        expected_segmentation_sha256: str = DEFAULT_DIARIZATION_SHA256,
        expected_embedding_sha256: str = DEFAULT_SPEAKER_SHA256,
    ) -> None:
        self.segmentation_model = segmentation_model
        self.embedding_model = embedding_model
        self.cluster_threshold = cluster_threshold
        self.expected_segmentation_sha256 = expected_segmentation_sha256.strip().lower()
        self.expected_embedding_sha256 = expected_embedding_sha256.strip().lower()
        self._lock = threading.Lock()
        self._status_lock = threading.Lock()
        self._instance: Any | None = None
        self._load_error: str | None = None
        self._status_key: tuple[tuple[int, int], tuple[int, int]] | None = None
        self._status_cache: dict[str, Any] | None = None

    def model_status(self) -> dict[str, Any]:
        try:
            segmentation_stat = self.segmentation_model.stat()
            embedding_stat = self.embedding_model.stat()
            key = (
                (segmentation_stat.st_mtime_ns, segmentation_stat.st_size),
                (embedding_stat.st_mtime_ns, embedding_stat.st_size),
            )
        except OSError:
            key = None
        with self._status_lock:
            if key is not None and key == self._status_key and self._status_cache:
                return dict(self._status_cache)
            segmentation_hash = sha256_file(self.segmentation_model)
            embedding_hash = sha256_file(self.embedding_model)
            ready = bool(
                segmentation_hash == self.expected_segmentation_sha256
                and embedding_hash == self.expected_embedding_sha256
            )
            status = {
                "ready": ready,
                "backend": "sherpa-onnx-pyannote-segmentation-3.0",
                "segmentation_model": str(self.segmentation_model),
                "segmentation_sha256": segmentation_hash,
                "embedding_model": str(self.embedding_model),
                "embedding_sha256": embedding_hash,
                "cluster_threshold": self.cluster_threshold,
                "loaded": self._instance is not None,
                "load_error": self._load_error,
                "reason": None if ready else "model-missing-or-hash-mismatch",
            }
            self._status_key = key
            self._status_cache = status
            return dict(status)

    def warmup(self) -> None:
        self._load()

    def _load(self) -> Any:
        if self._instance is not None:
            return self._instance
        with self._lock:
            if self._instance is not None:
                return self._instance
            if not self.model_status()["ready"]:
                self._load_error = "model-missing"
                raise DiarizationUnavailable(
                    "speaker diarization model is missing or failed integrity verification"
                )
            try:
                import sherpa_onnx

                config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
                    segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
                        pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                            model=str(self.segmentation_model),
                            window_shift_ratio=0.1,
                        ),
                    ),
                    embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(
                        model=str(self.embedding_model),
                        num_threads=2,
                        debug=False,
                        provider="cpu",
                    ),
                    clustering=sherpa_onnx.FastClusteringConfig(
                        num_clusters=-1,
                        threshold=self.cluster_threshold,
                    ),
                    min_duration_on=0.3,
                    min_duration_off=0.5,
                )
                if not config.validate():
                    raise RuntimeError("invalid sherpa-onnx diarization config")
                self._instance = sherpa_onnx.OfflineSpeakerDiarization(config)
                self._load_error = None
                with self._status_lock:
                    self._status_key = None
                    self._status_cache = None
            except Exception as error:
                self._load_error = type(error).__name__
                with self._status_lock:
                    self._status_key = None
                    self._status_cache = None
                raise DiarizationUnavailable(
                    "speaker diarization backend could not be loaded"
                ) from error
        return self._instance

    def inspect(self, audio: np.ndarray, sample_rate: int) -> DiarizationEvidence:
        diarizer = self._load()
        samples = _resample(audio, sample_rate, int(diarizer.sample_rate))
        started = time.perf_counter()
        try:
            result = diarizer.process(samples).sort_by_start_time()
        except Exception as error:
            raise DiarizationUnavailable("speaker diarization inference failed") from error
        segments = tuple(
            {
                "start": round(float(item.start), 3),
                "end": round(float(item.end), 3),
                "speaker": int(item.speaker),
            }
            for item in result
            if float(item.end) > float(item.start)
        )
        speakers = sorted({int(item["speaker"]) for item in segments})
        durations = []
        for speaker in speakers:
            intervals = [
                (float(item["start"]), float(item["end"]))
                for item in segments
                if int(item["speaker"]) == speaker
            ]
            durations.append(_union_duration(intervals))
        durations.sort(reverse=True)
        overlap = _overlap_duration(segments)
        return DiarizationEvidence(
            speaker_count=len(speakers),
            segments=segments,
            speaker_durations_s=tuple(round(value, 3) for value in durations),
            overlap_duration_s=overlap,
            second_speaker_duration_s=durations[1] if len(durations) > 1 else 0.0,
            elapsed_s=time.perf_counter() - started,
        )


def _union_duration(intervals: Iterable[tuple[float, float]]) -> float:
    merged: list[list[float]] = []
    for begin, end in sorted(intervals):
        if end <= begin:
            continue
        if merged and begin <= merged[-1][1]:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([begin, end])
    return sum(end - begin for begin, end in merged)


def _overlap_duration(segments: Iterable[dict[str, float | int]]) -> float:
    events: list[tuple[float, int, int]] = []
    for item in segments:
        begin = float(item["start"])
        end = float(item["end"])
        speaker = int(item["speaker"])
        events.append((begin, 1, speaker))
        events.append((end, -1, speaker))
    # End events sort before start events at the same timestamp.
    events.sort(key=lambda item: (item[0], item[1]))
    active: dict[int, int] = {}
    previous: float | None = None
    overlap = 0.0
    for timestamp, delta, speaker in events:
        if previous is not None and timestamp > previous and len(active) >= 2:
            overlap += timestamp - previous
        count = active.get(speaker, 0) + delta
        if count > 0:
            active[speaker] = count
        else:
            active.pop(speaker, None)
        previous = timestamp
    return round(overlap, 3)


__all__ = [
    "AdaptiveDenoiseError",
    "DEFAULT_DEEPFILTER_SHA256",
    "DEFAULT_DIARIZATION_SHA256",
    "DEFAULT_SPEAKER_SHA256",
    "DEEPFILTER_VERSION",
    "DenoiseDecision",
    "DiarizationEvidence",
    "DiarizationUnavailable",
    "DeepFilterRunner",
    "PROBE_SEEDS",
    "PROBE_VERSION",
    "QWEN_PROMPT_COSINE_FLOOR",
    "RELATIVE_SPEAKER_FLOOR",
    "SELECTOR_VERSION",
    "SpeakerDiarizer",
    "canary_selected",
    "configured_mode",
    "cosine",
    "low_energy_artifact_metrics",
    "probe_text",
    "raw_bypass_reason",
    "runtime_mode",
    "select_branch",
    "sha256_file",
    "should_apply",
]
