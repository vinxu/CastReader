import copy
import json
from pathlib import Path
import ssl
import unittest
import importlib.util
import tempfile
from unittest.mock import patch
from urllib.parse import parse_qs, urlparse

spec = importlib.util.spec_from_file_location('collector', Path(__file__).with_name('collect_vercel_preset_events.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

EVENT = {'source': 'tts-preset', 'event': 'attempt_failed', 'requestKey': '0123456789abcdef0123',
         'stage': 'body', 'attempt': 1, 'elapsedMs': 20000, 'attemptElapsedMs': 19999,
         'code': 'TTS_ATTEMPT_TIMEOUT', 'transportCode': 'ECONNRESET', 'region': 'global'}
DEPLOYMENT = 'dpl_fixedregression12345'
START = module.utc('2026-09-06T16:45:00Z')
END = module.utc('2026-09-06T16:55:00Z')

class PresetCollectorTests(unittest.TestCase):
    def row(self):
        return {'deploymentId': DEPLOYMENT, 'timestamp': '2026-09-06T16:48:00Z',
            'requestPath': '/api/captioned_speech_partly', 'requestId': 'private-provider-id',
            'statusCode': 504, 'requestDurationMs': 28000,
            'logs': [{'message': json.dumps(EVENT), 'messageTruncated': False}]}

    def test_only_fixed_fields_exported_and_nested_unknown_types_rejected(self):
        event = {**EVENT, 'message': 'private user input', 'requestId': 'private raw ID',
                 'audio': 'private audio', 'url': 'private endpoint', 'error': {'secret': 'private token'}}
        safe = module.safe_event(event)
        self.assertEqual(safe['requestKey'], EVENT['requestKey'])
        self.assertNotIn('source', safe)
        self.assertNotIn('private', json.dumps(safe))
        self.assertIsNone(module.safe_event({**EVENT, 'event': {'private': 'input'}}))
        self.assertIsNone(module.safe_event({**EVENT, 'attempt': True}))
        self.assertIsNone(module.safe_event({**EVENT, 'elapsedMs': float('nan')}))
        safe = module.safe_event({**EVENT, 'code': {'private': 'input'}, 'transportCode': 'private text'})
        self.assertNotIn('code', safe)
        self.assertNotIn('transportCode', safe)

    def test_deployment_path_and_exclusive_window_filtering(self):
        bad_deploy = {**self.row(), 'deploymentId': 'dpl_unrelated12345'}
        bad_path = {**self.row(), 'requestPath': '/private/path'}
        out = {**self.row(), 'timestamp': '2026-09-06T16:55:00Z'}
        rows, counts = module.sanitize_rows([self.row(), bad_deploy, bad_path, out], START, END, DEPLOYMENT)
        self.assertEqual(len(rows), 1)
        self.assertEqual(counts['deploymentMismatchRows'], 1)
        self.assertEqual(counts['unreviewedPathRows'], 1)
        self.assertEqual(counts['outOfWindowRows'], 1)
        self.assertNotIn('private-provider-id', json.dumps(rows))
        self.assertNotEqual(rows[0]['vercelRequestKey'], rows[0]['events'][0]['requestKey'])

    def test_nested_whole_json_lines_dedup_and_truncation_evidence(self):
        row = self.row()
        row['logs'][0]['message'] += '\n' + json.dumps({**EVENT, 'source': 'other', 'message': 'private'})
        row['logs'][0]['messageTruncated'] = True
        rows, counts = module.sanitize_rows([row, copy.deepcopy(row)], START, END, DEPLOYMENT)
        self.assertEqual(len(rows[0]['events']), 1)
        self.assertEqual(counts['duplicateProviderRows'], 1)
        self.assertEqual(counts['duplicateSafeEvents'], 1)
        self.assertEqual(counts['truncatedProviderLogs'], 2)
        self.assertFalse(rows[0]['hasRequestStart'])
        self.assertFalse(rows[0]['hasRequestFinished'])

    def test_api_query_pins_deployment_window_and_all_statuses(self):
        query = module.query_parameters({'projectId': 'fixed', 'orgId': 'fixed-owner'}, START, END, DEPLOYMENT, 2)
        self.assertEqual(query['deploymentId'], DEPLOYMENT)
        self.assertEqual(query['page'], 2)
        self.assertEqual(query['search'], 'tts-preset')
        self.assertNotIn('statusCode', query)
        self.assertNotIn('requestId', query)
        self.assertEqual(query['startDate'], int(START.timestamp()*1000))

    def test_tls_uses_certifi_and_preserves_hostname_and_certificate_verification(self):
        context = module.tls_context()
        self.assertTrue(context.check_hostname)
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertGreater(context.cert_store_stats()['x509_ca'], 0)
        self.assertRaises(ValueError, module.utc, '2026-09-06T16:48:00')

    def exercise_pages(self, batches):
        queries = []
        class Response:
            def __init__(self, value): self.value = value
            def __enter__(self): return self
            def __exit__(self, *_args): return False
            def read(self, _limit): return json.dumps(self.value).encode()
        class Opener:
            def open(self, request, timeout):
                queries.append(parse_qs(urlparse(request.full_url).query))
                return Response(batches[len(queries) - 1])
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            (root/'.vercel').mkdir()
            (root/'.vercel/project.json').write_text(json.dumps({'projectId': 'fixed', 'orgId': 'fixed'}))
            auth = root/'Library/Application Support/com.vercel.cli/auth.json'
            auth.parent.mkdir(parents=True)
            auth.write_text(json.dumps({'token': 'local-test-only'}))
            with patch.object(module, 'REPO', root), patch.object(module.Path, 'home', return_value=root), patch.object(module.urllib.request, 'build_opener', return_value=Opener()):
                rows, coverage = module.collect_pages(START, END, DEPLOYMENT, 20, 5000)
        return rows, coverage, queries

    def test_timestamp_cursor_overlaps_boundary_and_deduplicates(self):
        later = {**self.row(), 'timestamp': '2026-09-06T16:52:00Z'}
        earlier = {**self.row(), 'timestamp': '2026-09-06T16:46:00Z', 'requestId': 'private-earlier'}
        rows, coverage, queries = self.exercise_pages([
            {'rows': [later], 'hasMoreRows': True},
            {'rows': [later, earlier], 'hasMoreRows': False},
        ])
        self.assertEqual(coverage['issues'], [])
        self.assertEqual(queries[1]['page'], ['0'])
        self.assertEqual(int(queries[1]['endDate'][0]), int(module.utc(later['timestamp']).timestamp()*1000) + 1)
        safe, counts = module.sanitize_rows(rows, START, END, DEPLOYMENT)
        self.assertEqual(len(safe), 2)
        self.assertEqual(counts['duplicateProviderRows'], 1)

    def test_repeated_timestamp_boundary_stops_instead_of_looping(self):
        batch = {'rows': [self.row()], 'hasMoreRows': True}
        _rows, coverage, queries = self.exercise_pages([batch, batch])
        self.assertEqual(len(queries), 2)
        self.assertIn('timestamp_boundary_did_not_advance', coverage['issues'])
        self.assertIn('pagination_incomplete', coverage['issues'])

if __name__ == '__main__':
    unittest.main()
