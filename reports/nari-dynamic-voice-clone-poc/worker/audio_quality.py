#!/usr/bin/env python3
"""CPU-only acoustic quality gate for CastReader voice cloning.

Speaker-only prompts accept arbitrary natural speech in any recording language.
This module therefore checks only audio properties that materially affect the
speaker embedding: usable speech duration, level, clipping, noise, reverb, and
single-speaker consistency. Suggested UI text is never part of this contract.
"""

from __future__ import annotations

import math
import os
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

import numpy as np
from scipy import signal


TARGET_SAMPLE_RATE = 24_000
VAD_SAMPLE_RATE = 16_000
QUALITY_PROFILE = "castreader-reference-v4"
EPSILON = 1e-9


class ReferenceQualityError(ValueError):
    """A user-correctable reference recording failure."""

    def __init__(
        self,
        code: str,
        message: str,
        metrics: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.metrics = metrics or {}


@dataclass(frozen=True)
class ReferenceQualityConfig:
    min_speech_seconds: float = 3.0
    min_speech_ratio: float = 0.35
    min_active_rms_dbfs: float = -42.0
    reject_snr_db: float = 9.0
    denoise_below_snr_db: float = 18.0
    min_noise_evidence_seconds: float = 0.15
    reject_broadband_flatness: float = 0.70
    max_clipping_ratio: float = 0.004
    max_clipped_run_ms: float = 8.0
    target_active_rms_dbfs: float = -20.0
    max_gain_db: float = 9.0
    min_gain_db: float = -9.0
    peak_ceiling_dbfs: float = -1.0
    trim_lead_seconds: float = 0.15
    trim_tail_seconds: float = 0.20
    # A single sentence ending is not enough evidence for a hard reverb
    # rejection: the last phoneme is often quiet, which made ordinary iPhone
    # recordings look like a loud decay tail.  Only repeated, near-direct-level
    # tails are severe enough to block creation.
    severe_reverb_tail_db: float = -4.0
    severe_reverb_min_tail_count: int = 2
    warn_reverb_tail_db: float = -14.0
    reject_speaker_similarity: float = 0.45
    warn_speaker_similarity: float = 0.62


@dataclass
class ReferenceAudioResult:
    audio: np.ndarray
    sample_rate: int
    duration_seconds: float
    metrics: dict[str, Any]
    warnings: list[str]


@dataclass(frozen=True)
class NoiseStatistics:
    """Noise-floor evidence without treating quiet speech as room noise.

    Overlapping analysis frames mean the evidence duration is measured by the
    frame hop, not by summing each complete frame. When there is too little
    genuine non-speech, the SNR is intentionally unknown. Broadband spectral
    flatness remains available as a conservative backstop for continuous
    wide-band noise that VAD can otherwise mistake for speech.
    """

    noise_rms: float | None
    stationarity_db: float | None
    noise_frames: np.ndarray
    evidence_seconds: float
    reliable: bool
    broadband_flatness: float


_SILERO_LOCK = threading.Lock()
_SILERO_MODEL: Any | None = None
_SILERO_UNAVAILABLE = False


def _dbfs(value: float) -> float:
    return 20.0 * math.log10(max(float(value), EPSILON))


def _rms(audio: np.ndarray) -> float:
    if audio.size == 0:
        return 0.0
    return float(np.sqrt(np.mean(np.square(audio, dtype=np.float64))))


def _resample(audio: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if source_rate == target_rate:
        return np.asarray(audio, dtype=np.float32)
    divisor = math.gcd(source_rate, target_rate)
    return signal.resample_poly(
        audio,
        target_rate // divisor,
        source_rate // divisor,
    ).astype(np.float32, copy=False)


def _frame_audio(
    audio: np.ndarray,
    sample_rate: int,
    frame_ms: float = 30.0,
    hop_ms: float = 10.0,
) -> tuple[np.ndarray, int, int]:
    frame_length = max(1, round(sample_rate * frame_ms / 1000.0))
    hop_length = max(1, round(sample_rate * hop_ms / 1000.0))
    if audio.size < frame_length:
        padded = np.pad(audio, (0, frame_length - audio.size))
        return padded.reshape(1, -1), frame_length, hop_length
    frames = np.lib.stride_tricks.sliding_window_view(audio, frame_length)[::hop_length]
    return np.asarray(frames), frame_length, hop_length


def _regions_from_mask(
    mask: np.ndarray,
    hop_length: int,
    frame_length: int,
    sample_rate: int,
) -> list[tuple[int, int]]:
    regions: list[tuple[int, int]] = []
    start: int | None = None
    for index, value in enumerate(mask.tolist() + [False]):
        if value and start is None:
            start = index
        elif not value and start is not None:
            begin = start * hop_length
            end = min(
                (index - 1) * hop_length + frame_length,
                round((len(mask) * hop_length + frame_length)),
            )
            regions.append((begin, end))
            start = None
    return [
        (round(begin * TARGET_SAMPLE_RATE / sample_rate), round(end * TARGET_SAMPLE_RATE / sample_rate))
        for begin, end in regions
    ]


def _fill_short_gaps(mask: np.ndarray, maximum_frames: int) -> np.ndarray:
    output = mask.copy()
    index = 0
    while index < len(output):
        if output[index]:
            index += 1
            continue
        end = index
        while end < len(output) and not output[end]:
            end += 1
        if index > 0 and end < len(output) and end - index <= maximum_frames:
            output[index:end] = True
        index = end
    return output


def _drop_short_runs(mask: np.ndarray, minimum_frames: int) -> np.ndarray:
    output = mask.copy()
    index = 0
    while index < len(output):
        if not output[index]:
            index += 1
            continue
        end = index
        while end < len(output) and output[end]:
            end += 1
        if end - index < minimum_frames:
            output[index:end] = False
        index = end
    return output


def _energy_vad(audio_16k: np.ndarray) -> list[tuple[int, int]]:
    frames, frame_length, hop_length = _frame_audio(audio_16k, VAD_SAMPLE_RATE)
    window = np.hanning(frame_length).astype(np.float32)
    frame_rms = np.sqrt(np.mean(np.square(frames, dtype=np.float64), axis=1) + EPSILON)
    frame_db = 20 * np.log10(frame_rms + EPSILON)
    spectrum = np.abs(np.fft.rfft(frames * window, axis=1)) + EPSILON
    flatness = np.exp(np.mean(np.log(spectrum), axis=1)) / np.mean(spectrum, axis=1)
    noise_floor = float(np.percentile(frame_db, 20))
    threshold = min(-24.0, max(-46.0, noise_floor + 10.0))
    voiced = (frame_db >= threshold) & ((flatness < 0.82) | (frame_db >= threshold + 7.0))
    voiced = _fill_short_gaps(voiced, maximum_frames=25)
    voiced = _drop_short_runs(voiced, minimum_frames=16)
    return _merge_regions(
        _regions_from_mask(voiced, hop_length, frame_length, VAD_SAMPLE_RATE),
        maximum_gap_samples=round(0.30 * TARGET_SAMPLE_RATE),
    )


def _load_silero_model() -> Any | None:
    global _SILERO_MODEL, _SILERO_UNAVAILABLE
    if _SILERO_MODEL is not None:
        return _SILERO_MODEL
    if _SILERO_UNAVAILABLE:
        return None
    with _SILERO_LOCK:
        if _SILERO_MODEL is not None:
            return _SILERO_MODEL
        try:
            from silero_vad import load_silero_vad

            _SILERO_MODEL = load_silero_vad(onnx=True)
        except Exception:
            _SILERO_UNAVAILABLE = True
            return None
    return _SILERO_MODEL


def _silero_vad(audio_16k: np.ndarray) -> list[tuple[int, int]] | None:
    model = _load_silero_model()
    if model is None:
        return None
    try:
        import torch
        from silero_vad import get_speech_timestamps

        timestamps = get_speech_timestamps(
            torch.from_numpy(audio_16k),
            model,
            sampling_rate=VAD_SAMPLE_RATE,
            threshold=0.50,
            min_speech_duration_ms=180,
            min_silence_duration_ms=250,
            speech_pad_ms=80,
            return_seconds=False,
        )
    except Exception:
        return None
    regions = [
        (
            round(int(item["start"]) * TARGET_SAMPLE_RATE / VAD_SAMPLE_RATE),
            round(int(item["end"]) * TARGET_SAMPLE_RATE / VAD_SAMPLE_RATE),
        )
        for item in timestamps
    ]
    return _merge_regions(
        regions,
        maximum_gap_samples=round(0.30 * TARGET_SAMPLE_RATE),
    )


def _merge_regions(
    regions: Iterable[tuple[int, int]],
    maximum_gap_samples: int,
) -> list[tuple[int, int]]:
    merged: list[list[int]] = []
    for begin, end in sorted(regions):
        if end <= begin:
            continue
        if merged and begin - merged[-1][1] <= maximum_gap_samples:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([begin, end])
    return [(begin, end) for begin, end in merged]


def _mask_from_regions(length: int, regions: Iterable[tuple[int, int]]) -> np.ndarray:
    mask = np.zeros(length, dtype=bool)
    for begin, end in regions:
        mask[max(0, begin) : min(length, end)] = True
    return mask


def _longest_true_run_ms(mask: np.ndarray, sample_rate: int) -> float:
    if not mask.any():
        return 0.0
    padded = np.pad(mask.astype(np.int8), (1, 1))
    transitions = np.diff(padded)
    starts = np.flatnonzero(transitions == 1)
    ends = np.flatnonzero(transitions == -1)
    return float(np.max(ends - starts) * 1000.0 / sample_rate)


def _noise_statistics(
    audio: np.ndarray,
    speech_mask: np.ndarray,
    sample_rate: int,
    minimum_evidence_seconds: float,
) -> NoiseStatistics:
    frames, frame_length, hop_length = _frame_audio(audio, sample_rate)
    frame_rms = np.sqrt(np.mean(np.square(frames, dtype=np.float64), axis=1) + EPSILON)
    non_speech_ratio = []
    for index in range(len(frames)):
        begin = index * hop_length
        end = min(len(speech_mask), begin + frame_length)
        non_speech_ratio.append(1.0 - float(np.mean(speech_mask[begin:end])))
    non_speech_ratio_array = np.asarray(non_speech_ratio)
    noise_frames = frame_rms[non_speech_ratio_array >= 0.80]
    evidence_seconds = float(noise_frames.size * hop_length / sample_rate)
    reliable = evidence_seconds >= minimum_evidence_seconds

    window = np.hanning(frame_length).astype(np.float32)
    spectrum = np.abs(np.fft.rfft(frames * window, axis=1)) + EPSILON
    flatness = np.exp(np.mean(np.log(spectrum), axis=1)) / np.mean(spectrum, axis=1)
    # Device fades and codec tails can be spectrally flat even when the spoken
    # recording is clean, so exclude the quietest frames from this backstop.
    active_frames = frame_rms >= np.percentile(frame_rms, 35)
    broadband_flatness = float(
        np.median(flatness[active_frames])
        if np.any(active_frames)
        else np.median(flatness)
    )

    if not reliable:
        return NoiseStatistics(
            noise_rms=None,
            stationarity_db=None,
            noise_frames=noise_frames,
            evidence_seconds=evidence_seconds,
            reliable=False,
            broadband_flatness=broadband_flatness,
        )

    noise_rms = float(np.median(noise_frames))
    noise_db = 20 * np.log10(noise_frames + EPSILON)
    stationarity_db = float(np.std(noise_db)) if noise_db.size > 1 else 99.0
    return NoiseStatistics(
        noise_rms=noise_rms,
        stationarity_db=stationarity_db,
        noise_frames=noise_frames,
        evidence_seconds=evidence_seconds,
        reliable=True,
        broadband_flatness=broadband_flatness,
    )


def _reverb_tail_db(
    audio: np.ndarray,
    regions: list[tuple[int, int]],
    sample_rate: int,
) -> tuple[float | None, int]:
    values: list[float] = []
    for index, (begin, end) in enumerate(regions):
        next_begin = regions[index + 1][0] if index + 1 < len(regions) else len(audio)
        tail_begin = end + round(0.05 * sample_rate)
        tail_end = min(end + round(0.30 * sample_rate), next_begin, len(audio))
        # Compare the tail with a robust level from the voiced region, not only
        # the final phoneme. Sentence-final phonemes naturally decay and made
        # the previous denominator too small, causing false positives.
        direct_audio = audio[begin:end]
        if tail_end - tail_begin < round(0.08 * sample_rate):
            continue
        direct_frames, _, _ = _frame_audio(
            direct_audio,
            sample_rate,
            frame_ms=40.0,
            hop_ms=20.0,
        )
        direct_frame_rms = np.sqrt(
            np.mean(np.square(direct_frames, dtype=np.float64), axis=1) + EPSILON
        )
        direct_rms = float(np.percentile(direct_frame_rms, 65))
        tail_rms = _rms(audio[tail_begin:tail_end])
        if direct_rms > EPSILON:
            values.append(20 * math.log10(max(tail_rms, EPSILON) / direct_rms))
    if not values:
        return None, 0
    return float(np.median(values)), len(values)


def _is_severe_reverb(
    tail_db: float | None,
    tail_count: int,
    config: ReferenceQualityConfig,
) -> bool:
    return (
        tail_db is not None
        and tail_count >= config.severe_reverb_min_tail_count
        and tail_db > config.severe_reverb_tail_db
    )


def _spectral_denoise(
    audio: np.ndarray,
    speech_mask: np.ndarray,
    sample_rate: int,
    max_attenuation_db: float = 4.5,
) -> np.ndarray:
    frame_length = round(0.025 * sample_rate)
    overlap = round(0.015 * sample_rate)
    frequencies, times, spectrum = signal.stft(
        audio,
        fs=sample_rate,
        window="hann",
        nperseg=frame_length,
        noverlap=overlap,
        boundary="zeros",
        padded=True,
    )
    del frequencies
    centers = np.clip((times * sample_rate).astype(int), 0, len(speech_mask) - 1)
    noise_columns = ~speech_mask[centers]
    if np.count_nonzero(noise_columns) < 3:
        return audio
    power = np.square(np.abs(spectrum))
    noise_power = np.median(power[:, noise_columns], axis=1, keepdims=True)
    minimum_gain = 10 ** (-max_attenuation_db / 20.0)
    gain = np.clip(1.0 - 0.85 * noise_power / (power + EPSILON), minimum_gain, 1.0)
    gain = signal.medfilt2d(gain, kernel_size=(3, 3))
    # medfilt2d zero-pads at the borders, so clamp again to keep this pass
    # within the promised conservative attenuation ceiling.
    gain = np.clip(gain, minimum_gain, 1.0)
    _, enhanced = signal.istft(
        spectrum * gain,
        fs=sample_rate,
        window="hann",
        nperseg=frame_length,
        noverlap=overlap,
        input_onesided=True,
    )
    if enhanced.size < audio.size:
        enhanced = np.pad(enhanced, (0, audio.size - enhanced.size))
    return enhanced[: audio.size].astype(np.float32, copy=False)


class SpeakerConsistencyInspector:
    """Optional CPU ONNX speaker-embedding consistency check.

    Production enables this with CLONE_SPEAKER_MODEL.  If either the model or
    sherpa-onnx is unavailable, the gate reports unavailable rather than making
    an unreliable hard decision from pitch alone.
    """

    def __init__(self, model_path: str | None = None) -> None:
        self.model_path = Path(
            model_path or os.environ.get("CLONE_SPEAKER_MODEL", "")
        )
        self._extractor: Any | None = None

    def _load(self) -> Any | None:
        if self._extractor is not None:
            return self._extractor
        if not str(self.model_path) or not self.model_path.is_file():
            return None
        try:
            import sherpa_onnx

            config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
                model=str(self.model_path),
                num_threads=2,
                debug=False,
                provider="cpu",
            )
            extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
            self._extractor = extractor
            return extractor
        except Exception:
            return None

    def _embedding(self, audio_16k: np.ndarray) -> np.ndarray | None:
        extractor = self._load()
        if extractor is None:
            return None
        try:
            stream = extractor.create_stream()
            stream.accept_waveform(sample_rate=VAD_SAMPLE_RATE, waveform=audio_16k)
            stream.input_finished()
            if not extractor.is_ready(stream):
                return None
            embedding = np.asarray(extractor.compute(stream), dtype=np.float32)
        except Exception:
            return None
        norm = float(np.linalg.norm(embedding))
        return embedding / norm if norm > EPSILON else None

    def inspect(
        self,
        audio: np.ndarray,
        speech_mask: np.ndarray,
        sample_rate: int,
    ) -> tuple[float | None, int, str]:
        if self._load() is None:
            return None, 0, "unavailable"
        audio_16k = _resample(audio, sample_rate, VAD_SAMPLE_RATE)
        mask_16k = signal.resample_poly(
            speech_mask.astype(np.float32), VAD_SAMPLE_RATE, sample_rate
        ) >= 0.5
        window = round(2.4 * VAD_SAMPLE_RATE)
        hop = round(1.2 * VAD_SAMPLE_RATE)
        embeddings: list[np.ndarray] = []
        for begin in range(0, max(1, len(audio_16k) - window + 1), hop):
            end = min(len(audio_16k), begin + window)
            if end - begin < round(1.8 * VAD_SAMPLE_RATE):
                continue
            if float(np.mean(mask_16k[begin:end])) < 0.72:
                continue
            embedding = self._embedding(audio_16k[begin:end])
            if embedding is not None:
                embeddings.append(embedding)
        if len(embeddings) < 2:
            return None, len(embeddings), "sherpa-onnx"
        similarities = [
            float(np.dot(embeddings[left], embeddings[right]))
            for left in range(len(embeddings))
            for right in range(left + 1, len(embeddings))
        ]
        return min(similarities), len(embeddings), "sherpa-onnx"


_SPEAKER_INSPECTOR = SpeakerConsistencyInspector()


def process_reference_audio(
    audio: np.ndarray,
    sample_rate: int,
    *,
    config: ReferenceQualityConfig | None = None,
    vad_backend: str = "auto",
    speaker_inspector: SpeakerConsistencyInspector | None = None,
) -> ReferenceAudioResult:
    config = config or ReferenceQualityConfig()
    if sample_rate < 8_000 or sample_rate > 192_000:
        raise ReferenceQualityError(
            "VOICE_REFERENCE_SAMPLE_RATE_UNSUPPORTED",
            "The recording sample rate is unsupported.",
        )
    samples = np.asarray(audio, dtype=np.float32)
    if samples.ndim == 2:
        samples = np.mean(samples, axis=1)
    if samples.ndim != 1 or samples.size == 0 or not np.isfinite(samples).all():
        raise ReferenceQualityError(
            "VOICE_REFERENCE_INVALID",
            "The recording contains invalid audio samples.",
        )
    samples = _resample(samples, sample_rate, TARGET_SAMPLE_RATE)
    raw_duration = samples.size / TARGET_SAMPLE_RATE
    if raw_duration < 3.0 or raw_duration > 30.0:
        raise ReferenceQualityError(
            "VOICE_REFERENCE_DURATION_INVALID",
            "Record between 3 and 30 seconds.",
            {"raw_duration_s": round(raw_duration, 3)},
        )

    dc_offset = float(np.mean(samples))
    samples = samples - dc_offset
    vad_audio = _resample(samples, TARGET_SAMPLE_RATE, VAD_SAMPLE_RATE)
    regions: list[tuple[int, int]] | None = None
    resolved_vad_backend = "energy"
    if vad_backend in {"auto", "silero"}:
        regions = _silero_vad(vad_audio)
        if regions is not None:
            resolved_vad_backend = "silero"
    if regions is None:
        regions = _energy_vad(vad_audio)
    regions = [
        (max(0, begin), min(len(samples), end))
        for begin, end in regions
        if end > begin
    ]
    if not regions:
        raise ReferenceQualityError(
            "VOICE_REFERENCE_NO_SPEECH",
            "No clear speech was detected. Record again in a quiet place.",
            {"raw_duration_s": round(raw_duration, 3), "vad_backend": resolved_vad_backend},
        )

    speech_mask = _mask_from_regions(len(samples), regions)
    speech_seconds = float(np.count_nonzero(speech_mask) / TARGET_SAMPLE_RATE)
    speech_ratio = speech_seconds / raw_duration
    metrics: dict[str, Any] = {
        "profile": QUALITY_PROFILE,
        "vad_backend": resolved_vad_backend,
        "raw_duration_s": round(raw_duration, 3),
        "speech_duration_s": round(speech_seconds, 3),
        "speech_ratio": round(speech_ratio, 4),
        "dc_offset": round(dc_offset, 7),
    }
    if speech_seconds < config.min_speech_seconds:
        raise ReferenceQualityError(
            "VOICE_REFERENCE_SPEECH_TOO_SHORT",
            "Speak for a little longer and read the complete sentence.",
            metrics,
        )
    if speech_ratio < config.min_speech_ratio:
        raise ReferenceQualityError(
            "VOICE_REFERENCE_TOO_MUCH_SILENCE",
            "Too much silence was detected. Start speaking soon after pressing record.",
            metrics,
        )

    speech_samples = samples[speech_mask]
    active_rms = _rms(speech_samples)
    active_rms_dbfs = _dbfs(active_rms)
    noise = _noise_statistics(
        samples,
        speech_mask,
        TARGET_SAMPLE_RATE,
        config.min_noise_evidence_seconds,
    )
    snr_db = (
        None
        if noise.noise_rms is None
        else 20
        * math.log10(max(active_rms, EPSILON) / max(noise.noise_rms, EPSILON))
    )
    clipping_mask = np.abs(samples) >= 0.985
    clipping_ratio = float(np.mean(clipping_mask))
    clipped_run_ms = _longest_true_run_ms(clipping_mask, TARGET_SAMPLE_RATE)
    internal_silence = max(
        [
            max(0.0, (regions[index + 1][0] - regions[index][1]) / TARGET_SAMPLE_RATE)
            for index in range(len(regions) - 1)
        ]
        or [0.0]
    )
    reverb_tail_db, reverb_tail_count = _reverb_tail_db(
        samples, regions, TARGET_SAMPLE_RATE
    )
    inspector = speaker_inspector or _SPEAKER_INSPECTOR
    min_speaker_similarity, speaker_window_count, speaker_backend = inspector.inspect(
        samples, speech_mask, TARGET_SAMPLE_RATE
    )
    metrics.update(
        {
            "active_rms_dbfs": round(active_rms_dbfs, 2),
            "noise_rms_dbfs": (
                None if noise.noise_rms is None else round(_dbfs(noise.noise_rms), 2)
            ),
            "snr_db": None if snr_db is None else round(snr_db, 2),
            "noise_stationarity_db": (
                None
                if noise.stationarity_db is None
                else round(noise.stationarity_db, 2)
            ),
            "noise_evidence_seconds": round(noise.evidence_seconds, 3),
            "noise_estimate_reliable": noise.reliable,
            "broadband_flatness": round(noise.broadband_flatness, 4),
            "peak_dbfs": round(_dbfs(float(np.max(np.abs(samples)))), 2),
            "clipping_ratio": round(clipping_ratio, 6),
            "max_clipped_run_ms": round(clipped_run_ms, 2),
            "longest_internal_silence_s": round(internal_silence, 3),
            "reverb_tail_db": None if reverb_tail_db is None else round(reverb_tail_db, 2),
            "reverb_tail_count": reverb_tail_count,
            "speaker_backend": speaker_backend,
            "speaker_window_count": speaker_window_count,
            "min_speaker_similarity": (
                None
                if min_speaker_similarity is None
                else round(min_speaker_similarity, 4)
            ),
        }
    )

    if active_rms_dbfs < config.min_active_rms_dbfs:
        raise ReferenceQualityError(
            "VOICE_REFERENCE_TOO_QUIET",
            "The voice is too quiet. Move closer to the phone and record again.",
            metrics,
        )
    if (
        clipping_ratio > config.max_clipping_ratio
        or clipped_run_ms > config.max_clipped_run_ms
    ):
        raise ReferenceQualityError(
            "VOICE_REFERENCE_CLIPPING",
            "The recording is distorted because it is too loud. Move slightly farther away.",
            metrics,
        )
    if (
        (snr_db is not None and snr_db < config.reject_snr_db)
        or (
            snr_db is None
            and noise.broadband_flatness >= config.reject_broadband_flatness
        )
    ):
        raise ReferenceQualityError(
            "VOICE_REFERENCE_TOO_NOISY",
            "Background noise is too strong. Find a quieter place and record again.",
            metrics,
        )
    if _is_severe_reverb(reverb_tail_db, reverb_tail_count, config):
        raise ReferenceQualityError(
            "VOICE_REFERENCE_TOO_REVERBERANT",
            "The room echo is too strong. Record closer to the phone in a smaller, softer room.",
            metrics,
        )
    if (
        min_speaker_similarity is not None
        and speaker_window_count >= 2
        and (
            (snr_db is not None and snr_db >= config.denoise_below_snr_db)
            or (
                snr_db is None
                and noise.broadband_flatness < config.reject_broadband_flatness
            )
        )
        and min_speaker_similarity < config.reject_speaker_similarity
    ):
        raise ReferenceQualityError(
            "VOICE_REFERENCE_MULTIPLE_SPEAKERS",
            "More than one voice may be present. Record again with only one person speaking.",
            metrics,
        )

    warnings: list[str] = []
    processed = samples
    denoised = False
    if (
        snr_db is not None
        and snr_db < config.denoise_below_snr_db
        and noise.stationarity_db is not None
        and noise.stationarity_db <= 5.0
        and np.count_nonzero(~speech_mask) >= round(0.25 * TARGET_SAMPLE_RATE)
    ):
        processed = _spectral_denoise(processed, speech_mask, TARGET_SAMPLE_RATE)
        denoised = True
        warnings.append("light_stationary_noise_reduction")
    elif snr_db is not None and snr_db < config.denoise_below_snr_db:
        warnings.append("background_noise_detected")

    if (
        reverb_tail_db is not None
        and reverb_tail_count >= 1
        and reverb_tail_db > config.warn_reverb_tail_db
    ):
        warnings.append("room_echo_detected")
    if (
        min_speaker_similarity is not None
        and (
            (snr_db is not None and snr_db >= config.denoise_below_snr_db)
            or (
                snr_db is None
                and noise.broadband_flatness < config.reject_broadband_flatness
            )
        )
        and min_speaker_similarity < config.warn_speaker_similarity
        and (reverb_tail_db is None or reverb_tail_db <= config.warn_reverb_tail_db)
    ):
        warnings.append("speaker_change_suspected")
    if speaker_backend == "unavailable":
        warnings.append("speaker_consistency_check_unavailable")
    if internal_silence > 1.2:
        warnings.append("long_internal_pause")

    trim_begin = max(0, regions[0][0] - round(config.trim_lead_seconds * TARGET_SAMPLE_RATE))
    desired_trim_end = regions[-1][1] + round(
        config.trim_tail_seconds * TARGET_SAMPLE_RATE
    )
    # Push-to-record users commonly release on the final phoneme. Previously
    # `min(len(processed), desired_trim_end)` silently removed the intended
    # acoustic settling tail in exactly that case. Pad only the missing part
    # after all VAD/noise/reverb decisions, so the synthetic silence cannot
    # improve the sample's quality score or change which speech is retained.
    synthetic_tail_samples = max(0, desired_trim_end - len(processed))
    if synthetic_tail_samples:
        processed = np.pad(processed, (0, synthetic_tail_samples))
        speech_mask = np.pad(
            speech_mask,
            (0, synthetic_tail_samples),
            constant_values=False,
        )
    trim_end = desired_trim_end
    trimmed = processed[trim_begin:trim_end].copy()
    trimmed_speech_mask = speech_mask[trim_begin:trim_end]
    normalized_active_rms = _rms(trimmed[trimmed_speech_mask])
    desired_gain_db = config.target_active_rms_dbfs - _dbfs(normalized_active_rms)
    applied_gain_db = min(config.max_gain_db, max(config.min_gain_db, desired_gain_db))
    trimmed *= 10 ** (applied_gain_db / 20.0)
    peak_ceiling = 10 ** (config.peak_ceiling_dbfs / 20.0)
    peak = float(np.max(np.abs(trimmed))) if trimmed.size else 0.0
    limiter_reduction_db = 0.0
    if peak > peak_ceiling:
        limiter_gain = peak_ceiling / peak
        trimmed *= limiter_gain
        limiter_reduction_db = -20 * math.log10(limiter_gain)
    fade_samples = min(round(0.01 * TARGET_SAMPLE_RATE), len(trimmed) // 2)
    if fade_samples > 1:
        fade = np.linspace(0.0, 1.0, fade_samples, dtype=np.float32)
        trimmed[:fade_samples] *= fade
        trimmed[-fade_samples:] *= fade[::-1]
    trimmed = np.clip(trimmed, -peak_ceiling, peak_ceiling).astype(np.float32, copy=False)

    metrics.update(
        {
            "trim_start_s": round(trim_begin / TARGET_SAMPLE_RATE, 3),
            "trim_end_s": round(trim_end / TARGET_SAMPLE_RATE, 3),
            "last_speech_end_s": round(regions[-1][1] / TARGET_SAMPLE_RATE, 3),
            "synthetic_tail_padding_ms": round(
                synthetic_tail_samples * 1000 / TARGET_SAMPLE_RATE,
                1,
            ),
            "processed_duration_s": round(len(trimmed) / TARGET_SAMPLE_RATE, 3),
            "denoised": denoised,
            "normalization_gain_db": round(applied_gain_db, 2),
            "limiter_reduction_db": round(limiter_reduction_db, 2),
            "processed_peak_dbfs": round(
                _dbfs(float(np.max(np.abs(trimmed))) if trimmed.size else 0.0), 2
            ),
        }
    )
    return ReferenceAudioResult(
        audio=trimmed,
        sample_rate=TARGET_SAMPLE_RATE,
        duration_seconds=len(trimmed) / TARGET_SAMPLE_RATE,
        metrics=metrics,
        warnings=warnings,
    )
