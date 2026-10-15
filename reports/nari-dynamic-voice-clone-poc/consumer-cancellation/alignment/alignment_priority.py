"""One alignment executor, consumer work first; never duplicate model weights."""
from concurrent.futures import Future
from contextlib import contextmanager
from contextvars import ContextVar
import heapq
import itertools
import threading

DEVELOPER_ALIGNMENT = ContextVar('developer_alignment', default=False)


class AlignmentExecutor:
    def __init__(self, api_ready=lambda: True):
        self.api_ready = api_ready
        self.condition = threading.Condition()
        self.pending = []
        self.sequence = itertools.count()
        self.consumers = 0
        self.closed = False
        self.thread = threading.Thread(target=self._run, name='shared-gpu-align', daemon=True)
        self.thread.start()

    @contextmanager
    def consumer(self):
        with self.condition:
            self.consumers += 1
        try:
            yield
        finally:
            with self.condition:
                self.consumers -= 1
                self.condition.notify_all()

    def submit(self, fn, *args, **kwargs):
        future = Future()
        with self.condition:
            if self.closed:
                raise RuntimeError('alignment-executor-closed')
            heapq.heappush(self.pending, (10 if DEVELOPER_ALIGNMENT.get() else 0,
                          next(self.sequence), future, fn, args, kwargs))
            self.condition.notify_all()
        return future

    def _run(self):
        while True:
            with self.condition:
                while self.pending and self.pending[0][2].cancelled():
                    heapq.heappop(self.pending)
                if not self.pending:
                    if self.closed:
                        return
                    self.condition.wait(.1)
                    continue
                if self.pending[0][0] and self.consumers:
                    self.condition.wait(.05)
                    continue
                api = bool(self.pending[0][0])
            # Never hold the queue lock during the consumer health probe.
            try:
                ready = not api or self.api_ready()
            except Exception:
                ready = False
            with self.condition:
                if not self.pending:
                    continue
                if self.pending[0][0] and (self.consumers or not ready):
                    self.condition.wait(.05)
                    continue
                _, _, future, fn, args, kwargs = heapq.heappop(self.pending)
            if not future.set_running_or_notify_cancel():
                continue
            try:
                future.set_result(fn(*args, **kwargs))
            except BaseException as error:
                future.set_exception(error)
            finally:
                # Retain neither prior request audio nor its result while idle.
                future = fn = args = kwargs = None

    def shutdown(self, wait=True, *, cancel_futures=False):
        with self.condition:
            self.closed = True
            if cancel_futures:
                for item in self.pending:
                    item[2].cancel()
            self.condition.notify_all()
        if wait:
            self.thread.join()
