"""Consumer cancellation shared by HTTP, coalescing and the existing GPU queue.

No model/queue is created here. An already-running CUDA kernel is not preempted;
its existing executor keeps ownership until it returns. Closing a legacy PCM stream is not an engine-stop acknowledgment. Consumer
synthesis uses retiring_pcm and retains ownership until its exact engine ACK.
"""
from __future__ import annotations

import asyncio
from contextlib import contextmanager
from contextvars import ContextVar
import threading
import time
import uuid
from typing import Callable


class ConsumerCancelled(RuntimeError):
    pass


class NeverCancelled:
    def is_set(self):
        return False


_CURRENT = ContextVar('consumer_speech_cancellation', default=NeverCancelled())


def current_cancellation():
    return _CURRENT.get()


def check_cancelled(cancel=None):
    if (cancel if cancel is not None else current_cancellation()).is_set():
        raise ConsumerCancelled('consumer request cancelled')


@contextmanager
def bind_cancellation(cancel):
    context = _CURRENT.set(cancel)
    try:
        yield
    finally:
        _CURRENT.reset(context)


class SharedCancellation:
    """One producer may have multiple HTTP consumers; all must leave to stop it.

    Cancellation latches so a new request cannot resurrect an already-retiring
    operation. The caller can retry its stable billing ID after terminal state.
    """
    def __init__(self):
        self._lock = threading.Lock()
        self._consumers = []
        self._cancelled = False

    def add(self, consumer):
        with self._lock:
            if self._cancelled or (self._consumers and all(c.is_set() for c in self._consumers)):
                self._cancelled = True
                raise ConsumerCancelled('original consumer operation is cancelling')
            self._consumers.append(consumer)

    def is_set(self):
        with self._lock:
            if self._consumers and all(c.is_set() for c in self._consumers):
                self._cancelled = True
            return self._cancelled


async def run_on_disconnect(request, operation: Callable[[], object]):
    """ASGI owns connection lifetime; synchronous inference remains off-loop."""
    from fastapi import HTTPException
    cancel = threading.Event()

    def run():
        with bind_cancellation(cancel):
            check_cancelled()
            return operation()

    async def disconnected():
        while True:
            if (await request.receive())['type'] == 'http.disconnect':
                return

    task = asyncio.create_task(asyncio.to_thread(run))
    watcher = asyncio.create_task(disconnected())
    try:
        done, _ = await asyncio.wait({task, watcher}, return_when=asyncio.FIRST_COMPLETED)
        if watcher in done:
            cancel.set()
            raise ConsumerCancelled('consumer disconnected')
        return await task
    except ConsumerCancelled as error:
        raise HTTPException(499, detail={'code': 'GENERATION_CANCELLED', 'message': str(error)},
                            headers={'X-Voice-Retryable': 'false'}) from error
    finally:
        cancel.set()
        watcher.cancel()
        # Cancelling this await does not falsely release the GPU queue's active
        # slot. The worker callback and HTTP cleanup own that terminal state.
        task.cancel()
        await asyncio.gather(watcher, task, return_exceptions=True)


async def _until_cancelled(operation, cancel):
    check_cancelled(cancel)
    task = asyncio.create_task(operation())

    async def watcher():
        while not cancel.is_set():
            await asyncio.sleep(.02)

    watch = asyncio.create_task(watcher())
    try:
        done, _ = await asyncio.wait({task, watch}, return_when=asyncio.FIRST_COMPLETED)
        if watch in done:
            raise ConsumerCancelled('upstream request cancelled')
        result = await task
        check_cancelled(cancel)
        return result
    finally:
        task.cancel()
        watch.cancel()
        # Wait for AsyncClient/stream finally before releasing this local task.
        await asyncio.gather(task, watch, return_exceptions=True)


def cancellable_post(url, *, headers=None, json=None, timeout=60):
    """Complete response body, with a private connection closed on cancellation."""
    import httpx
    cancel = current_cancellation()
    async def post():
        async with httpx.AsyncClient(trust_env=False, follow_redirects=False, timeout=timeout) as client:
            return await client.post(url, headers=headers, json=json)
    return asyncio.run(_until_cancelled(post, cancel))


def cancellable_pcm(url, *, json, timeout, deadline_at):
    """Read the existing PCM protocol; cancel closes even a silent socket."""
    import httpx
    cancel = current_cancellation()
    async def stream():
        async with httpx.AsyncClient(trust_env=False, follow_redirects=False, timeout=timeout) as client:
            async with client.stream('POST', url, json=json) as response:
                if response.status_code != 200:
                    return response.status_code, b''
                data = bytearray()
                async for chunk in response.aiter_bytes():
                    check_cancelled(cancel)
                    data.extend(chunk)
                return 200, bytes(data)
    async def bounded():
        async with asyncio.timeout(max(.001, deadline_at - time.monotonic())):
            return await _until_cancelled(stream, cancel)
    return asyncio.run(bounded())


def retiring_pcm(origin, *, json, timeout, deadline_at, token):
    """Retain the caller's single-GPU slot until exact Nari retirement.

    If ACK delivery fails, this existing scheduler callback remains occupied.
    Its public caller may time out, but unknown is never converted into idle.
    No replacement model, queue, or automatic synthesis retry is created.
    """
    import httpx
    import json as audit_json
    from consumer_nari_ack import PROTOCOL, ENGINE_SHA256
    cancel = current_cancellation()
    attempt = 'ctts_' + uuid.uuid4().hex
    headers = {'X-Consumer-Nari-Token': token}
    async def run():
        check_cancelled(cancel)
        async with httpx.AsyncClient(trust_env=False, follow_redirects=False, timeout=timeout) as client:
            capability = await client.get(origin + '/v1/consumer/capabilities', headers=headers)
            capability.raise_for_status()
            meta = capability.json()
            if (meta.get('protocol') != PROTOCOL or meta.get('engine_source_sha256') != ENGINE_SHA256
                    or not isinstance(meta.get('instance_id'), str) or len(meta['instance_id']) != 32):
                raise RuntimeError('consumer exact-retirement capability unavailable')
            headers.update({'X-Consumer-Nari-Instance': meta['instance_id'], 'X-Request-ID': attempt})
            check_cancelled(cancel)
            # This control operation never submits to the engine. Without its
            # returned lease, no audio POST can be admitted, even if this reply
            # is lost. Unused leases expire; terminal ACKs never expire unseen.
            prepared = await client.post(origin + f'/v1/consumer/requests/{attempt}/prepare',
                                         headers=headers, timeout=2)
            value = prepared.json()
            if prepared.status_code != 200:
                proof = value.get('detail', {}) if isinstance(value, dict) else {}
                if (proof.get('protocol') == PROTOCOL and proof.get('request_id') == attempt
                        and proof.get('instance_id') == meta['instance_id']
                        and proof.get('engine_source_sha256') == ENGINE_SHA256
                        and proof.get('engine_stopped') is True
                        and proof.get('proof') == 'admission-lease-not-issued-v1'):
                    return prepared.status_code, b''
                prepared.raise_for_status()
                raise RuntimeError('invalid consumer admission response')
            if (value.get('protocol') != PROTOCOL or value.get('request_id') != attempt
                    or value.get('instance_id') != meta['instance_id']
                    or not isinstance(value.get('lease'), str) or len(value['lease']) != 32):
                raise RuntimeError('invalid consumer admission lease')
            headers['X-Consumer-Nari-Lease'] = value['lease']
            print('CASTREADER_CONSUMER_ENGINE ' + audit_json.dumps({'event': 'admitted', 'attempt': attempt, 'instance_id': meta['instance_id']}), flush=True)
            complete = False
            async def stream():
                nonlocal complete
                async with client.stream('POST', origin + '/v1/consumer/audio/speech',
                                         headers=headers, json=json) as response:
                    if response.status_code != 200:
                        return response.status_code, b''
                    data = bytearray()
                    async for chunk in response.aiter_bytes():
                        check_cancelled(cancel)
                        data.extend(chunk)
                    complete = True
                    return 200, bytes(data)
            try:
                async with asyncio.timeout(max(.001, deadline_at - time.monotonic())):
                    return await _until_cancelled(stream, cancel)
            finally:
                # Runs outside the body deadline/cancel scope. PCM end, socket
                # close, 404, process restart and arbitrary IDs are not ACKs.
                while True:
                    try:
                        if not complete:
                            await client.post(origin + f'/v1/consumer/requests/{attempt}/cancel',
                                              headers=headers, timeout=2)
                        response = await client.get(origin + f'/v1/consumer/requests/{attempt}/state',
                                                    headers=headers, timeout=2)
                        value = response.json() if response.status_code == 200 else {}
                        if (value.get('protocol') == PROTOCOL and value.get('request_id') == attempt
                                and value.get('instance_id') == meta['instance_id']
                                and value.get('lease') == headers['X-Consumer-Nari-Lease']
                                and value.get('engine_source_sha256') == ENGINE_SHA256
                                and value.get('engine_stopped') is True
                                and value.get('state') in {'done', 'cancelled'}
                                and value.get('proof') in {'engine-retired-v1', 'engine-not-submitted-v1'}):
                            # The exact retirement proof already permits
                            # slot release. Cleanup failure must not turn a
                            # stopped engine into a permanently occupied slot.
                            # An undelivered ACK remains retained server-side
                            # and contributes bounded admission backpressure.
                            print('CASTREADER_CONSUMER_ENGINE ' + audit_json.dumps({'event': 'terminal', 'attempt': attempt, 'instance_id': meta['instance_id'], 'state': value['state'], 'engine_stopped': True, 'engine_source_sha256': ENGINE_SHA256, 'proof': value['proof']}), flush=True)
                            try:
                                await client.post(origin + f'/v1/consumer/requests/{attempt}/ack',
                                                  headers=headers, timeout=2)
                            except (httpx.HTTPError, ValueError):
                                pass
                            break
                    except (httpx.HTTPError, ValueError):
                        pass
                    await asyncio.sleep(.1)
    return asyncio.run(run())
