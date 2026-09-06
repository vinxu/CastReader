import hashlib
import importlib.util
from pathlib import Path
import unittest
from datetime import datetime, timedelta, timezone

ROOT = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('candidate', ROOT/'remote_tts_gateway_snapshot.candidate.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class CompatibilityTests(unittest.TestCase):
    def test_historical_ambiguous_failures_and_new_disconnection_are_separate(self):
        start = datetime(2026, 9, 7, tzinfo=timezone.utc)
        rows = []
        for index in range(4):
            rows.extend([
                (start, "tts_gateway_request {\n requestId: 'fixed-old-%s',\n status: 504,\n method: 'POST',\n path: '/api/captioned_speech_partly'\n}" % index),
                (start, "tts_gateway_error {\n name: 'AbortError',\n message: 'This operation was aborted'\n}"),
            ])
        rows.extend([
            (start, "tts_gateway_request {\n requestKey: '0123456789abcdef0123',\n status: null,\n method: 'POST',\n path: '/api/captioned_speech_partly',\n abortSource: 'downstream_closed',\n abortStage: 'upstream_body',\n downstreamDisconnected: true\n}"),
            (start, "tts_gateway_error {\n code: 'TTS_DOWNSTREAM_CLOSED'\n}"),
            (start, "tts_gateway_request {\n requestKey: 'abcdef01234567890123',\n status: 504,\n abortSource: 'upstream_timeout',\n abortStage: 'upstream_headers',\n downstreamDisconnected: false\n}"),
            (start, "tts_gateway_error {\n code: 'TTS_UPSTREAM_TIMEOUT'\n}"),
        ])
        value = module.aggregate_entries(rows, start, start + timedelta(seconds=1))
        self.assertEqual(value['statusCounts'], {'504': 5, 'no_response': 1})
        self.assertEqual(value['consoleErrorClassCounts'], {'timeout_or_abort': 4, 'downstream_closed': 1, 'upstream_timeout': 1})
        self.assertEqual(value['uniqueRequestIds'], 6)
        self.assertEqual(value['downstreamConnectionStateUnknownRequests'], 4)
        self.assertEqual(value['downstreamDisconnectedRequests'], 1)
        self.assertEqual(value['malformedRequestBlocks'], 0)
        self.assertEqual(value['nonHttpRequestCount'], 1)
        self.assertEqual(value['nonHttpRequests'][0]['key'], '0123456789abcdef0123')
        self.assertEqual(value['abortSourceCounts'], {'downstream_closed': 1, 'upstream_timeout': 1})

    def test_anonymous_key_matches_legacy_hash_and_is_not_hashed_twice(self):
        now = datetime.now(timezone.utc)
        key = hashlib.sha256(b'fixed-correlation').hexdigest()[:20]
        legacy = module.request_from_block("requestId: 'fixed-correlation',\n status: 200", now)
        current = module.request_from_block("requestKey: '%s',\n status: 200" % key, now)
        self.assertEqual(legacy['key'], current['key'])
        self.assertIsNone(legacy['downstreamDisconnected'])
        self.assertFalse(legacy['downstreamDisconnectedFieldObserved'])
        connected = module.request_from_block("requestKey: '%s',\n status: 200,\n downstreamDisconnected: false" % key, now)
        self.assertIs(connected['downstreamDisconnected'], False)
        self.assertTrue(connected['downstreamDisconnectedFieldObserved'])
        self.assertEqual(module.error_from_block("code: 'TTS_UPSTREAM_ABORTED'"), 'upstream_aborted')
        self.assertIsNone(module.request_from_block("requestKey: '0123456789abcdef0123',\n status: null", now))

if __name__ == '__main__':
    unittest.main()
