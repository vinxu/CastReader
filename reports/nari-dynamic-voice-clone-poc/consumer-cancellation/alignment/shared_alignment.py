"""Extend the existing v3 GPU gateway with an authenticated PCM-only API lane."""
import base64
import hmac
import io
import json
import os
from pathlib import Path
import threading
import time
from typing import Literal
from urllib.request import urlopen
import wave

from fastapi import Header, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from alignment_priority import AlignmentExecutor, DEVELOPER_ALIGNMENT

SERVICE_REVISION = 'shared-gpu-alignment-v1'


def runtime():
    region = os.environ.get('VOICE_COMPUTE_REGION', 'cn')
    if region == 'cn':
        return Path('/root/autodl-tmp/castreader-developer-api-mvp'), 18890
    if region == 'us':
        return Path('/workspace/castreader-voice-api'), 8890
    raise ValueError('unsupported alignment region')


class AlignRequest(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)
    pcm: str = Field(min_length=4, max_length=7680000)
    text: str = Field(min_length=1, max_length=120)
    language: Literal['en']
    format: Literal['mp3', 'wav']
    speed: float = Field(ge=.5, le=2)


def consumer_idle():
    try:
        with urlopen(f'http://127.0.0.1:{runtime()[1]}/health', timeout=.5) as response:
            value = json.load(response)
        return (value.get('nari_ready') is True and value.get('busy') is False
                and value.get('queue_depth') == 0 and value.get('active_voice_tasks') == 0)
    except (OSError, ValueError):
        return False


def install(gateway, app, developer_token, *, api_ready=consumer_idle):
    from caption_pipeline import CaptionPipeline, EncodedAudio, PIPELINE_REVISION, prepare_pcm
    import soundfile as sf

    if len(developer_token) < 16:
        raise ValueError('invalid-developer-alignment-token')
    executor = AlignmentExecutor(api_ready)
    gateway.pipeline.executor.shutdown(wait=True)
    gateway.pipeline.executor = executor
    original_generate = gateway.generate

    def generate(*args, **kwargs):
        with executor.consumer():
            return original_generate(*args, **kwargs)
    gateway.generate = generate

    def wav_encoder(pcm):
        buffer = io.BytesIO()
        sf.write(buffer, pcm.samples, pcm.sample_rate, format='WAV', subtype='PCM_16')
        return EncodedAudio(buffer.getvalue(), pcm.duration)

    pipelines = {}
    for format in ('mp3', 'wav'):
        pipeline = CaptionPipeline(gateway.pipeline.aligner, max_inflight=1, alignment_budget_s=20,
                                   **({'encoder': wav_encoder} if format == 'wav' else {}))
        pipeline.executor.shutdown(wait=True)
        pipeline.executor = executor
        pipelines[format] = pipeline
    admission = threading.BoundedSemaphore(1)
    # The original app lifespan closes gateway.pipeline, which owns the shared executor.
    for route in app.routes:
        if route.path == '/health':
            app.routes.remove(route)
            break

    @app.get('/health')
    def health():
        return {'status': 'ready', 'pipeline_revision': PIPELINE_REVISION,
                'alignment_service_revision': SERVICE_REVISION, 'device': 'cuda:0',
                'pid': os.getpid(), 'model_instances': 1}

    @app.post('/internal/v1/align-pcm')
    def align(body: AlignRequest, x_developer_token: str | None = Header(default=None)):
        if not x_developer_token or not hmac.compare_digest(x_developer_token, developer_token):
            raise HTTPException(401, 'invalid token')
        if not body.text.strip():
            raise HTTPException(422, 'empty text')
        try:
            raw = base64.b64decode(body.pcm, validate=True)
        except ValueError:
            raise HTTPException(422, 'invalid PCM')
        if not 0 < len(raw) <= 24000 * 2 * 120 or len(raw) % 2:
            raise HTTPException(422, 'invalid PCM')
        if not admission.acquire(blocking=False):
            raise HTTPException(429, 'API alignment is busy')
        context = DEVELOPER_ALIGNMENT.set(True)
        started = time.perf_counter()
        try:
            buffer = io.BytesIO()
            with wave.open(buffer, 'wb') as wav:
                wav.setnchannels(1)
                wav.setsampwidth(2)
                wav.setframerate(24000)
                wav.writeframes(raw)
            pcm = prepare_pcm(buffer.getvalue(), body.speed)
            result = pipelines[body.format].caption(pcm, text=body.text, language=body.language,
                                                   voice_code='api', return_timestamps=True)
            aligned = result.reason in {'qwen-word', 'qwen-word-groups'}
            return {'audio': result.response['audio'], 'alignment': {
                'status': 'aligned' if aligned else 'unavailable', 'alignment_revision': PIPELINE_REVISION,
                'unit': 'seconds', 'granularity': ('word' if result.reason == 'qwen-word' else 'word_group') if aligned else None,
                'duration_seconds': result.duration, 'words': result.response['timestamps'],
                'reason': None if aligned else ('alignment_timeout' if result.reason == 'deadline' else 'alignment_unavailable')},
                'metrics': {**result.timings, 'device': 'cuda:0', 'shared_model': True,
                    'cold_start': False, 'model_load_ms': 0,
                    'helper_total_ms': (time.perf_counter() - started) * 1000}}
        finally:
            DEVELOPER_ALIGNMENT.reset(context)
            admission.release()
    return app


def create_app():
    import alignment_gateway as original
    build_app = original.build_app
    # Only the newly launched service's factory is extended. Original consumer
    # validation, synthesis, coalescing and v3 alignment source stay unchanged.
    def build(gateway, token):
        app = build_app(gateway, token)
        return install(gateway, app, (runtime()[0] / 'stream-token').read_text().strip())
    original.build_app = build
    try:
        return original.create_app()
    finally:
        original.build_app = build_app
