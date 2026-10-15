"""Consumer-only exact engine retirement; reuses the existing Nari instance.

HTTP completion and a queued cancel command are never terminal evidence.
"""
from __future__ import annotations
import asyncio
import hashlib
import hmac
import inspect
import json
from pathlib import Path
import re
import threading
import time
import uuid

import anyio
from fastapi import HTTPException, Request
from fastapi.responses import StreamingResponse

PROTOCOL = 'consumer-stop-v2'
ENGINE_SHA256 = 'e65cb446c76f5023d3ab0aa66308c5eecae10c867f0ffde1ad287acf7df987a5'
PINNED = {
    'engine/engine.py': ENGINE_SHA256,
    'engine/state.py': '2b81fbd447d0b043242678227b95544189a9ec1b4e276b50e5db747c33d1a1a1',
    'engine/pipeline.py': '699a7319b6860a61945dc0c9158ba6264de28b7acd0449325afd4c17bec37f5c',
    'engine/output.py': 'b8775aa9b164797af750a1f5a132a553323928485cce1d65a7e469201cd9c663',
}
REQUEST_ID = re.compile(r'^ctts_[a-f0-9]{32}$')

def engine_attempt(request_id, lease):
    return request_id + '__' + lease

def split_attempt(request_id, lease=None):
    if '__' in request_id:
        return tuple(request_id.split('__', 1))
    return request_id, lease


class ConsumerRetirements:
    def __init__(self, capacity=4096, reservation_seconds=120):
        self.lock = threading.RLock()
        self.records = {}
        self.instance_id = uuid.uuid4().hex
        self.capacity = capacity
        self.reservation_seconds = reservation_seconds

    def begin(self, request_id):
        with self.lock:
            now = time.monotonic()
            # Only unused admission leases expire. Unconsumed terminal ACKs
            # and executing/preparing attempts are never evicted by age/capacity.
            for key in list(self.records):
                record = self.records[key]
                if record['phase'] == 'reserved' and record['expires'] < now:
                    del self.records[key]
            if request_id in self.records:
                raise HTTPException(409, 'consumer attempt already registered')
            if len(self.records) >= self.capacity:
                raise HTTPException(429, self.no_lease(request_id))
            lease = uuid.uuid4().hex
            self.records[request_id] = dict(phase='reserved', state='submitted',
                engine_stopped=False, cancel_requested=False, lease=lease,
                expires=now + self.reservation_seconds)
            return {**self.state(request_id), 'lease': lease}

    def no_lease(self, request_id):
        return dict(protocol=PROTOCOL, request_id=request_id, instance_id=self.instance_id,
            engine_source_sha256=ENGINE_SHA256, state='cancelled', engine_stopped=True,
            proof='admission-lease-not-issued-v1')

    def claim(self, request_id, lease):
        with self.lock:
            record = self.records.get(request_id)
            if record is None or not hmac.compare_digest(record['lease'], lease):
                raise HTTPException(409, 'consumer admission lease unavailable')
            if record['phase'] != 'reserved' or record['cancel_requested']:
                raise HTTPException(409, 'consumer attempt already used or cancelled')
            record['phase'] = 'preparing'
            if record['expires'] < time.monotonic():
                self.not_submitted(request_id, lease=lease)
                raise HTTPException(409, 'consumer admission lease expired')

    def owns(self, request_id, lease):
        record = self.records.get(request_id)
        return record is not None and hmac.compare_digest(record['lease'], lease)

    def before_submit(self, request_id, lease):
        with self.lock:
            record = self.records.get(request_id)
            if record is None or not self.owns(request_id, lease):
                return False
            if record['cancel_requested'] or record['engine_stopped']:
                self.not_submitted(request_id, lease=lease)
                return False
            record['phase'] = 'submitting'
            return True

    def not_submitted(self, request_id, *, command_proof=False, lease=None):
        request_id, lease = split_attempt(request_id, lease)
        with self.lock:
            record = self.records.get(request_id)
            if record is None or not self.owns(request_id, lease or '') or (record['phase'] not in {'reserved', 'preparing'} and not command_proof):
                return
            record.update(state='cancelled', engine_stopped=True,
                          proof='engine-not-submitted-v1', phase='terminal')

    def cancel(self, request_id, lease):
        with self.lock:
            if not self.owns(request_id, lease):
                raise HTTPException(409, 'consumer admission lease unavailable')
            record = self.records[request_id]
            record['cancel_requested'] = True
            if record['phase'] in {'reserved', 'preparing'}:
                self.not_submitted(request_id, lease=lease)
            return not record['engine_stopped']

    def retired(self, request_id, completed):
        request_id, lease = split_attempt(request_id)
        with self.lock:
            record = self.records.get(request_id)
            if record is not None and self.owns(request_id, lease or ''):
                record.update(state='done' if completed else 'cancelled',
                    engine_stopped=True, proof='engine-retired-v1', phase='terminal')

    def acknowledge(self, request_id, lease):
        with self.lock:
            record = self.records.get(request_id)
            if record is None:
                return  # Idempotent cleanup; this is NOT engine-stop evidence.
            if not self.owns(request_id, lease) or not record['engine_stopped']:
                raise HTTPException(409, 'terminal consumer ACK required')
            del self.records[request_id]
            # Late old speech requests cannot begin: they need an existing lease.
            # A later reservation reusing this ID receives a different lease.

    def state(self, request_id):
        request_id, supplied_lease = split_attempt(request_id)
        with self.lock:
            record = self.records.get(request_id)
            if record is not None and supplied_lease and not self.owns(request_id, supplied_lease):
                record = None
            return dict(protocol=PROTOCOL, request_id=request_id,
                        instance_id=self.instance_id, engine_source_sha256=ENGINE_SHA256,
                        state=record['state'] if record else 'unknown',
                        engine_stopped=bool(record and record['engine_stopped']),
                        proof=record.get('proof') if record else None,
                        lease=record['lease'] if record else None)


def observed_submit(engine, tracker, request_id, domain, command_factory, *, timeout_s=5):
    """The pinned Engine.submit dispatch, with precise pre-command proof.

    Same original command queue and _wait_future timeout/orphan cancellation.
    A timeout after command execution starts remains unknown until _retire.
    """
    from concurrent.futures import Future
    try:
        engine._require_ready()
    except BaseException:
        tracker.not_submitted(request_id, command_proof=True)
        raise
    future = Future()
    command = command_factory(request_id, domain, False, (), (), True, future)
    try:
        engine._put(command, timeout_s=timeout_s)
    except BaseException as error:
        # Only Queue.full proves failure before enqueue. Unknown interruptions
        # may race Queue.put and must retain admission until engine retirement.
        import queue
        if isinstance(error.__cause__, queue.Full) or isinstance(error, queue.Full):
            tracker.not_submitted(request_id, command_proof=True)
        raise
    try:
        return engine._wait_future(future, timeout_s=timeout_s, request_id=request_id)
    except BaseException:
        if future.cancelled():
            # _execute_command's set_running_or_notify_cancel must reject this.
            tracker.not_submitted(request_id, command_proof=True)
        raise


def observe_admission_rejections(engine, tracker):
    """Observe original _handle_submit before GPU admission without changing it."""
    local = threading.local()
    handle = engine._handle_submit
    admit = engine._admit_record
    def admitting(record, **kwargs):
        if getattr(local, 'request_id', None) == record.request_id:
            local.entered_admission = True
        return admit(record, **kwargs)
    def submitting(command):
        local.request_id = command.request_id
        local.entered_admission = False
        try:
            return handle(command)
        finally:
            # Capacity/type/duplicate validation errors and cancelled commands
            # before _admit_record have not invoked the GPU admission path.
            if not local.entered_admission:
                with engine._condition:
                    absent = command.request_id not in engine._records
                if absent:
                    tracker.not_submitted(command.request_id, command_proof=True)
            local.request_id = None
    engine._admit_record = admitting
    engine._handle_submit = submitting


def install_consumer_stop_ack(app, engine, *, parse_request, token,
                              verify_source=True, deadline_seconds=60, tracker_capacity=4096, command_factory=None):
    if not token or len(token) > 4096 or any(ord(c) < 33 for c in token):
        raise ValueError('separate authenticated Nari control token required')
    if not .1 <= deadline_seconds <= 120:
        raise ValueError('invalid consumer deadline')
    if verify_source:
        root = Path(inspect.getfile(type(engine))).parent.parent
        if any(hashlib.sha256((root / path).read_bytes()).hexdigest() != sha
               for path, sha in PINNED.items()):
            raise ValueError('Nari engine source differs from audited source')
    elif not getattr(engine, 'consumer_test_double', False):
        raise ValueError('only explicit model-free test doubles may skip source verification')
    if getattr(app.state, 'consumer_stop_ack_installed', False):
        raise ValueError('consumer stop ACK already installed')
    tracker = ConsumerRetirements(capacity=tracker_capacity)
    if verify_source:
        if command_factory is not None:
            raise ValueError('production command factory cannot be overridden')
        from nari_qwen3_tts.contract.command import SubmitRequest
        command_factory = SubmitRequest
    elif command_factory is None:
        command_factory = engine.consumer_test_command
    observe_admission_rejections(engine, tracker)
    original_retire = engine._retire
    def retired(record, *, completed):
        original_retire(record, completed=completed)
        with engine._condition:
            stopped = record.retired and record.request_id not in engine._records
        if stopped:
            tracker.retired(record.request_id, completed)
    engine._retire = retired  # Chains after the existing developer observer.

    def authorize(request, request_id=None):
        if not hmac.compare_digest(request.headers.get('x-consumer-nari-token', ''), token):
            raise HTTPException(401, 'invalid consumer Nari token')
        if request_id is not None:
            if not REQUEST_ID.fullmatch(request_id):
                raise HTTPException(422, 'invalid consumer attempt ID')
            if request.headers.get('x-consumer-nari-instance') != tracker.instance_id:
                raise HTTPException(409, 'consumer engine instance changed')

    async def cancel_engine(request_id, lease):
        if tracker.cancel(request_id, lease):
            try:
                await asyncio.to_thread(engine.cancel, engine_attempt(request_id, lease), timeout_s=2)
            except Exception:
                pass  # Unknown remains unknown; callers retain their slot.
        return tracker.state(request_id)

    async def cleanup_cancel(request_id, lease):
        try:
            await cancel_engine(request_id, lease)
        except HTTPException as error:
            if error.status_code != 409:
                raise
            # Its acknowledged lease was already reclaimed. Do not mask the
            # original cancellation or touch a newer lease using this ID.

    @app.get('/v1/consumer/capabilities')
    async def capabilities(request: Request):
        authorize(request)
        return dict(protocol=PROTOCOL, instance_id=tracker.instance_id,
                    engine_source_sha256=ENGINE_SHA256)

    @app.post('/v1/consumer/requests/{request_id}/prepare')
    async def prepare(request_id: str, request: Request):
        authorize(request, request_id)
        return tracker.begin(request_id)

    @app.post('/v1/consumer/requests/{request_id}/ack')
    async def acknowledge(request_id: str, request: Request):
        authorize(request, request_id)
        tracker.acknowledge(request_id, request.headers.get('x-consumer-nari-lease', ''))
        return {'acknowledged': True}

    @app.get('/v1/consumer/requests/{request_id}/state')
    async def state(request_id: str, request: Request):
        authorize(request, request_id)
        return tracker.state(request_id)

    @app.post('/v1/consumer/requests/{request_id}/cancel')
    async def cancel(request_id: str, request: Request):
        authorize(request, request_id)
        return await cancel_engine(request_id, request.headers.get('x-consumer-nari-lease', ''))

    @app.post('/v1/consumer/audio/speech')
    async def speech(request: Request):
        request_id = request.headers.get('x-request-id', '')
        authorize(request, request_id)
        lease = request.headers.get('x-consumer-nari-lease', '')
        tracker.claim(request_id, lease)
        try:
            raw = bytearray()
            async with asyncio.timeout(5):
                async for chunk in request.stream():
                    raw.extend(chunk)
                    if len(raw) > 65536:
                        raise HTTPException(413, 'consumer request too large')
            body = json.loads(raw)
            if (not isinstance(body, dict) or body.get('response_format') != 'pcm'
                    or body.get('stream') is not True):
                raise ValueError('consumer route requires original PCM contract')
            domain = parse_request(body)  # Original schema/voice/language/token limits.
        except BaseException as error:
            tracker.not_submitted(request_id, lease=lease)
            if isinstance(error, (ValueError, TypeError)):
                raise HTTPException(422, 'invalid consumer PCM request') from None
            raise

        def submit():
            if not tracker.before_submit(request_id, lease):
                raise HTTPException(499, 'consumer cancelled before submission')
            try:
                return observed_submit(engine, tracker, engine_attempt(request_id, lease), domain, command_factory, timeout_s=5)
            finally:
                # Cancellation may race command admission or submit timeout.
                # A command return is never itself an engine-stop proof.
                with tracker.lock:
                    cancelled = tracker.owns(request_id, lease) and tracker.records[request_id]['cancel_requested']
                if cancelled:
                    try:
                        engine.cancel(engine_attempt(request_id, lease), timeout_s=2)
                    except Exception:
                        pass
        task = asyncio.create_task(asyncio.to_thread(submit))
        try:
            stream = await asyncio.shield(task)
        except BaseException as error:
            # The submit thread remains owned and cannot be resurrected. Its
            # finally checks cancellation even if the HTTP task has ended.
            with anyio.CancelScope(shield=True):
                await cleanup_cancel(request_id, lease)
            if isinstance(error, Exception) and not isinstance(error, HTTPException):
                raise HTTPException(503, 'consumer engine submission failed') from None
            raise
        deadline_at = time.monotonic() + deadline_seconds
        async def pcm():
            completed = False
            try:
                while time.monotonic() < deadline_at:
                    try:
                        chunk = await asyncio.to_thread(stream.read, timeout_s=.1)
                    except TimeoutError:
                        continue
                    if chunk is None:
                        completed = True
                        return
                    yield chunk
                raise TimeoutError('consumer PCM deadline')
            finally:
                if not completed:
                    with anyio.CancelScope(shield=True):
                        await cleanup_cancel(request_id, lease)
        return StreamingResponse(pcm(), media_type='audio/pcm',
                                 headers={'X-Nari-Request-ID': request_id, 'Cache-Control': 'no-store'})
    app.state.consumer_stop_ack_installed = True
    return tracker
