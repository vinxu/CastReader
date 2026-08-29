from __future__ import annotations

import threading
import time
import unittest

from inference_scheduler import (
    PRIORITY_BACKGROUND,
    PRIORITY_INTERACTIVE,
    InferenceScheduler,
    SchedulerOverloaded,
)


class InferenceSchedulerTests(unittest.TestCase):
    def test_concurrent_callers_never_overlap_gpu_execution(self) -> None:
        scheduler = InferenceScheduler(max_queue_size=16, aging_seconds=1)
        active = 0
        max_active = 0
        lock = threading.Lock()
        results: list[int] = []

        def work(value: int) -> int:
            nonlocal active, max_active
            with lock:
                active += 1
                max_active = max(max_active, active)
            time.sleep(0.015)
            with lock:
                active -= 1
            return value

        def caller(value: int) -> None:
            result = scheduler.submit(
                lambda: work(value), kind="test", timeout_s=2
            )
            results.append(result.value)

        threads = [threading.Thread(target=caller, args=(index,)) for index in range(8)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        scheduler.close()

        self.assertEqual(max_active, 1)
        self.assertEqual(sorted(results), list(range(8)))
        self.assertEqual(scheduler.snapshot()["failed"], 0)

    def test_interactive_request_overtakes_waiting_background_request(self) -> None:
        scheduler = InferenceScheduler(max_queue_size=8, aging_seconds=30)
        release_active = threading.Event()
        execution_order: list[str] = []

        active = threading.Thread(
            target=lambda: scheduler.submit(
                lambda: release_active.wait(1), kind="active", timeout_s=2
            )
        )
        active.start()
        deadline = time.monotonic() + 1
        while scheduler.snapshot()["busy"] is not True and time.monotonic() < deadline:
            time.sleep(0.005)

        background = threading.Thread(
            target=lambda: scheduler.submit(
                lambda: execution_order.append("background"),
                kind="background",
                priority=PRIORITY_BACKGROUND,
                timeout_s=2,
            )
        )
        interactive = threading.Thread(
            target=lambda: scheduler.submit(
                lambda: execution_order.append("interactive"),
                kind="interactive",
                priority=PRIORITY_INTERACTIVE,
                timeout_s=2,
            )
        )
        background.start()
        time.sleep(0.01)
        interactive.start()
        time.sleep(0.01)
        release_active.set()

        active.join()
        interactive.join()
        background.join()
        scheduler.close()
        self.assertEqual(execution_order, ["interactive", "background"])

    def test_bounded_queue_rejects_only_after_capacity_is_exhausted(self) -> None:
        scheduler = InferenceScheduler(max_queue_size=1, aging_seconds=1)
        release_active = threading.Event()
        active = threading.Thread(
            target=lambda: scheduler.submit(
                lambda: release_active.wait(1), kind="active", timeout_s=2
            )
        )
        active.start()
        deadline = time.monotonic() + 1
        while scheduler.snapshot()["busy"] is not True and time.monotonic() < deadline:
            time.sleep(0.005)

        queued = threading.Thread(
            target=lambda: scheduler.submit(lambda: None, kind="queued", timeout_s=2)
        )
        queued.start()
        deadline = time.monotonic() + 1
        while scheduler.snapshot()["queue_depth"] != 1 and time.monotonic() < deadline:
            time.sleep(0.005)

        with self.assertRaises(SchedulerOverloaded):
            scheduler.submit(lambda: None, kind="overflow", timeout_s=1)

        release_active.set()
        active.join()
        queued.join()
        scheduler.close()


if __name__ == "__main__":
    unittest.main()
