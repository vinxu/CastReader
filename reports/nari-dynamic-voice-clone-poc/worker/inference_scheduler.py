#!/usr/bin/env python3
"""Bounded, observable single-GPU scheduler for interactive TTS work.

Nari is intentionally configured for one active request on an RTX 4090.  The
old adapter exposed that constraint as an immediate HTTP 429.  This scheduler
keeps the GPU single-flight while allowing callers to wait in a bounded queue.
Interactive playback is preferred over prefetch, and prefetch is preferred
over work explicitly submitted as background. The public voice-build route is
currently an interactive request because a user is synchronously waiting for
creation; caller-supplied priority is authoritative.
"""

from __future__ import annotations

import collections
import dataclasses
import math
import threading
import time
import uuid
from collections.abc import Callable
from typing import Generic, TypeVar


T = TypeVar("T")

PRIORITY_INTERACTIVE = 0
PRIORITY_PREFETCH = 1
PRIORITY_BACKGROUND = 2
VALID_PRIORITIES = (PRIORITY_INTERACTIVE, PRIORITY_PREFETCH, PRIORITY_BACKGROUND)


class SchedulerClosed(RuntimeError):
    pass


class SchedulerOverloaded(RuntimeError):
    pass


class SchedulerDeadlineExceeded(TimeoutError):
    pass


@dataclasses.dataclass(frozen=True)
class ScheduledResult(Generic[T]):
    value: T
    request_id: str
    queue_wait_s: float
    run_s: float


@dataclasses.dataclass
class _Job(Generic[T]):
    request_id: str
    kind: str
    priority: int
    submitted_at: float
    deadline_at: float
    execute: Callable[[], T]
    event: threading.Event = dataclasses.field(default_factory=threading.Event)
    started_at: float | None = None
    finished_at: float | None = None
    value: T | None = None
    error: BaseException | None = None
    cancelled: bool = False


class InferenceScheduler:
    """One execution thread with bounded priority queues and aging.

    The scheduler normally drains interactive work first.  Aging promotes an
    older request by one priority level for every ``aging_seconds`` it waits,
    preventing background voice creation from starving indefinitely.
    """

    def __init__(
        self,
        *,
        max_queue_size: int = 64,
        aging_seconds: float = 8.0,
        recent_window: int = 512,
        name: str = "castreader-gpu-scheduler",
    ) -> None:
        if max_queue_size < 1:
            raise ValueError("max_queue_size must be positive")
        if aging_seconds <= 0:
            raise ValueError("aging_seconds must be positive")
        self.max_queue_size = max_queue_size
        self.aging_seconds = aging_seconds
        self._condition = threading.Condition()
        self._queues: dict[int, collections.deque[_Job[object]]] = {
            priority: collections.deque() for priority in VALID_PRIORITIES
        }
        self._accepting = True
        self._active: _Job[object] | None = None
        self._submitted = 0
        self._completed = 0
        self._failed = 0
        self._expired = 0
        self._queue_waits: collections.deque[float] = collections.deque(
            maxlen=recent_window
        )
        self._run_times: collections.deque[float] = collections.deque(
            maxlen=recent_window
        )
        self._thread = threading.Thread(target=self._run, name=name, daemon=True)
        self._thread.start()

    def submit(
        self,
        execute: Callable[[], T],
        *,
        kind: str,
        priority: int = PRIORITY_INTERACTIVE,
        timeout_s: float = 45.0,
        request_id: str | None = None,
    ) -> ScheduledResult[T]:
        if priority not in VALID_PRIORITIES:
            raise ValueError("invalid scheduler priority")
        if timeout_s <= 0:
            raise ValueError("timeout_s must be positive")
        now = time.monotonic()
        job: _Job[T] = _Job(
            request_id=request_id or uuid.uuid4().hex,
            kind=kind,
            priority=priority,
            submitted_at=now,
            deadline_at=now + timeout_s,
            execute=execute,
        )
        with self._condition:
            if not self._accepting:
                raise SchedulerClosed("scheduler is shutting down")
            if self._queue_depth_locked() >= self.max_queue_size:
                raise SchedulerOverloaded("GPU request queue is full")
            self._queues[priority].append(job)  # type: ignore[arg-type]
            self._submitted += 1
            self._condition.notify()

        # A small grace interval lets the execution thread publish a terminal
        # result when the request finishes exactly at its declared deadline.
        if not job.event.wait(timeout_s + 0.25):
            with self._condition:
                job.cancelled = True
                self._condition.notify()
            raise SchedulerDeadlineExceeded("GPU request deadline exceeded")
        if job.error is not None:
            raise job.error
        if job.started_at is None or job.finished_at is None:
            raise RuntimeError("scheduler completed a job without timings")
        return ScheduledResult(
            value=job.value,  # type: ignore[arg-type]
            request_id=job.request_id,
            queue_wait_s=job.started_at - job.submitted_at,
            run_s=job.finished_at - job.started_at,
        )

    def snapshot(self) -> dict[str, object]:
        with self._condition:
            waits = tuple(self._queue_waits)
            runs = tuple(self._run_times)
            return {
                "accepting": self._accepting,
                "busy": self._active is not None,
                "active_request_id": self._active.request_id
                if self._active is not None
                else None,
                "active_kind": self._active.kind if self._active is not None else None,
                "queue_depth": self._queue_depth_locked(),
                "queue_by_priority": {
                    "interactive": len(self._queues[PRIORITY_INTERACTIVE]),
                    "prefetch": len(self._queues[PRIORITY_PREFETCH]),
                    "background": len(self._queues[PRIORITY_BACKGROUND]),
                },
                "max_queue_size": self.max_queue_size,
                "submitted": self._submitted,
                "completed": self._completed,
                "failed": self._failed,
                "expired": self._expired,
                "queue_wait_p50_ms": round(self._percentile(waits, 0.50) * 1000, 2),
                "queue_wait_p95_ms": round(self._percentile(waits, 0.95) * 1000, 2),
                "run_p50_ms": round(self._percentile(runs, 0.50) * 1000, 2),
                "run_p95_ms": round(self._percentile(runs, 0.95) * 1000, 2),
            }

    def close(self, *, wait: bool = True) -> None:
        with self._condition:
            self._accepting = False
            for queue in self._queues.values():
                while queue:
                    job = queue.popleft()
                    job.error = SchedulerClosed("scheduler stopped before execution")
                    job.finished_at = time.monotonic()
                    job.event.set()
            self._condition.notify_all()
        if wait:
            self._thread.join(timeout=5.0)

    def _queue_depth_locked(self) -> int:
        return sum(len(queue) for queue in self._queues.values())

    def _next_job_locked(self, now: float) -> _Job[object] | None:
        candidates: list[tuple[int, float, int]] = []
        for priority, queue in self._queues.items():
            while queue and (queue[0].cancelled or queue[0].deadline_at <= now):
                expired = queue.popleft()
                expired.error = SchedulerDeadlineExceeded(
                    "GPU request expired before execution"
                )
                expired.finished_at = now
                expired.event.set()
                self._expired += 1
            if not queue:
                continue
            oldest = queue[0]
            age_promotions = int((now - oldest.submitted_at) / self.aging_seconds)
            effective_priority = max(
                PRIORITY_INTERACTIVE, priority - age_promotions
            )
            candidates.append((effective_priority, oldest.submitted_at, priority))
        if not candidates:
            return None
        _, _, source_priority = min(candidates)
        return self._queues[source_priority].popleft()

    def _run(self) -> None:
        while True:
            with self._condition:
                job = self._next_job_locked(time.monotonic())
                while job is None:
                    if not self._accepting:
                        return
                    self._condition.wait(timeout=0.25)
                    job = self._next_job_locked(time.monotonic())
                if job.cancelled:
                    continue
                job.started_at = time.monotonic()
                self._active = job
            try:
                job.value = job.execute()
            except BaseException as error:  # propagate the original API error
                job.error = error
            finally:
                finished = time.monotonic()
                with self._condition:
                    job.finished_at = finished
                    self._queue_waits.append(job.started_at - job.submitted_at)
                    self._run_times.append(finished - job.started_at)
                    if job.error is None:
                        self._completed += 1
                    else:
                        self._failed += 1
                    self._active = None
                    job.event.set()
                    self._condition.notify_all()

    @staticmethod
    def _percentile(values: tuple[float, ...], fraction: float) -> float:
        if not values:
            return 0.0
        ordered = sorted(values)
        index = max(0, math.ceil(fraction * len(ordered)) - 1)
        return ordered[index]
