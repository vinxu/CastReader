from __future__ import annotations

import concurrent.futures
import threading
import time
import unittest

from request_coalescer import IdempotencyConflict, RequestCoalescer


class RequestCoalescerTests(unittest.TestCase):
    def test_concurrent_duplicates_execute_once(self) -> None:
        coalescer = RequestCoalescer()
        calls = 0
        lock = threading.Lock()

        def work() -> str:
            nonlocal calls
            with lock:
                calls += 1
            time.sleep(0.05)
            return "audio"

        def invoke():
            return coalescer.execute("request-1", "same", work, wait_timeout_s=1)

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
            results = list(executor.map(lambda _: invoke(), range(4)))
        self.assertEqual(calls, 1)
        self.assertEqual([result.value for result in results], ["audio"] * 4)
        self.assertEqual(
            sorted(result.source for result in results),
            ["coalesced", "coalesced", "coalesced", "owner"],
        )

    def test_completed_result_is_cached(self) -> None:
        coalescer = RequestCoalescer()
        first = coalescer.execute("request-2", "same", lambda: 7, wait_timeout_s=1)
        second = coalescer.execute(
            "request-2",
            "same",
            lambda: self.fail("cached request executed twice"),
            wait_timeout_s=1,
        )
        self.assertEqual(first.source, "owner")
        self.assertEqual(second.source, "cache")
        self.assertEqual(second.value, 7)

    def test_same_id_with_different_payload_is_rejected(self) -> None:
        coalescer = RequestCoalescer()
        coalescer.execute("request-3", "first", lambda: 1, wait_timeout_s=1)
        with self.assertRaises(IdempotencyConflict):
            coalescer.execute("request-3", "second", lambda: 2, wait_timeout_s=1)

    def test_failed_owner_is_retryable(self) -> None:
        coalescer = RequestCoalescer()
        with self.assertRaisesRegex(RuntimeError, "failed"):
            coalescer.execute(
                "request-4",
                "same",
                lambda: (_ for _ in ()).throw(RuntimeError("failed")),
                wait_timeout_s=1,
            )
        result = coalescer.execute(
            "request-4", "same", lambda: "recovered", wait_timeout_s=1
        )
        self.assertEqual(result.value, "recovered")


if __name__ == "__main__":
    unittest.main()
