#!/usr/bin/env python3
"""Small in-memory idempotency/coalescing layer for synchronous worker calls."""

from __future__ import annotations

import collections
import dataclasses
import threading
import time
from collections.abc import Callable
from typing import Generic, TypeVar


T = TypeVar("T")


class IdempotencyConflict(RuntimeError):
    pass


class IdempotencyWaitTimeout(TimeoutError):
    pass


@dataclasses.dataclass(frozen=True)
class CoalescedResult(Generic[T]):
    value: T
    source: str


@dataclasses.dataclass
class _Entry(Generic[T]):
    fingerprint: str
    event: threading.Event = dataclasses.field(default_factory=threading.Event)
    value: T | None = None
    error: BaseException | None = None


@dataclasses.dataclass(frozen=True)
class _Cached(Generic[T]):
    fingerprint: str
    value: T
    expires_at: float


class RequestCoalescer:
    """Executes one owner per request ID and briefly caches its result.

    Vercel/iOS may retry an ambiguous request after a transient transport
    failure. Callers that reuse the same request ID receive the first result
    instead of consuming a second GPU slot. Reusing an ID for different input
    is rejected rather than returning the wrong audio.
    """

    def __init__(self, *, max_entries: int = 64, ttl_s: float = 90.0) -> None:
        if max_entries < 1 or ttl_s <= 0:
            raise ValueError("invalid coalescer bounds")
        self.max_entries = max_entries
        self.ttl_s = ttl_s
        self._lock = threading.Lock()
        self._inflight: dict[str, _Entry[object]] = {}
        self._cache: collections.OrderedDict[str, _Cached[object]] = (
            collections.OrderedDict()
        )

    def execute(
        self,
        key: str,
        fingerprint: str,
        execute: Callable[[], T],
        *,
        wait_timeout_s: float,
    ) -> CoalescedResult[T]:
        if not key or not fingerprint or wait_timeout_s <= 0:
            raise ValueError("invalid idempotency request")
        owner = False
        with self._lock:
            self._purge_locked(time.monotonic())
            cached = self._cache.get(key)
            if cached is not None:
                if cached.fingerprint != fingerprint:
                    raise IdempotencyConflict("request ID payload mismatch")
                self._cache.move_to_end(key)
                return CoalescedResult(cached.value, "cache")  # type: ignore[arg-type]
            entry = self._inflight.get(key)
            if entry is not None:
                if entry.fingerprint != fingerprint:
                    raise IdempotencyConflict("request ID payload mismatch")
            else:
                entry = _Entry(fingerprint=fingerprint)
                self._inflight[key] = entry  # type: ignore[assignment]
                owner = True

        if not owner:
            if not entry.event.wait(wait_timeout_s):
                raise IdempotencyWaitTimeout("timed out waiting for original request")
            if entry.error is not None:
                raise entry.error
            return CoalescedResult(entry.value, "coalesced")  # type: ignore[arg-type]

        try:
            value = execute()
        except BaseException as error:
            with self._lock:
                entry.error = error
                self._inflight.pop(key, None)
                entry.event.set()
            raise
        with self._lock:
            entry.value = value
            self._inflight.pop(key, None)
            self._cache[key] = _Cached(
                fingerprint=fingerprint,
                value=value,
                expires_at=time.monotonic() + self.ttl_s,
            )
            self._cache.move_to_end(key)
            while len(self._cache) > self.max_entries:
                self._cache.popitem(last=False)
            entry.event.set()
        return CoalescedResult(value, "owner")

    def _purge_locked(self, now: float) -> None:
        expired = [key for key, value in self._cache.items() if value.expires_at <= now]
        for key in expired:
            self._cache.pop(key, None)
