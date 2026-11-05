"""Behavioral tests for the extracted cold-cache and retained-output workflow."""
import decimal
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import urllib.error
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts/iceberg'))
import cache
import result_codec
import runner


class BackendFixture:
    def __init__(self, fail=None):
        self.operations = []
        self.fail = fail
        self.original = {'page_cache_mem_quota_bytes': 4096, 'block_cache_disk_quota_bytes': 8192,
                         'page_cache_mem_used_bytes': 10, 'block_cache_disk_used_bytes': 20}
        self.reads = 0

    def request(self, path):
        self.reads += 1
        value = dict(self.original)
        if self.reads > 1:
            value.update(page_cache_mem_used_bytes=0, block_cache_disk_used_bytes=0)
        return json.dumps(value)

    def update(self, key, value):
        self.operations.append((key, value))
        if (key, value) == self.fail:
            raise RuntimeError('shrink failed')


class CacheTests(unittest.TestCase):
    def test_sr_restores_both_budgets_after_partial_failure(self):
        backend = BackendFixture(('datacache_disk_size', '0'))
        with self.assertRaisesRegex(RuntimeError, 'shrink failed'):
            cache.clear_starrocks(backend, {'datacache_mem_size': '20%', 'datacache_disk_size': '8192'})
        self.assertEqual(backend.operations[-2:], [('datacache_disk_size', '8192'), ('datacache_mem_size', '20%')])

    def test_sr_success_requires_empty_cache_after_restore(self):
        backend = BackendFixture()
        result = cache.clear_starrocks(backend, {'datacache_mem_size': '20%', 'datacache_disk_size': '8192'})
        self.assertEqual(result['restored']['block_cache_disk_used_bytes'], 0)
        self.assertEqual(result['restored']['page_cache_mem_quota_bytes'], 4096)

    def test_doris_get_fallback_only_for_unsupported_method(self):
        operations = []
        class Backend:
            brpc_port = 8060
            def request(self, path, data=None, port=None):
                operations.append((path, data))
                if path.startswith('/api/file_cache'):
                    if data is not None:
                        raise urllib.error.HTTPError(path, 405, 'method', {}, None)
                    return '{"status":"OK"}'
                if path == '/brpc_metrics':
                    return 'file_cache_cache_size 0\n'
                return 'ClearCacheAction cache:DataPageCache prune win, freed size 0'
        self.assertEqual(cache.clear_doris(Backend())['method'], 'GET')
        self.assertEqual(operations[0][1], b'')
        self.assertEqual(operations[1][1], None)

    def test_doris_auth_failure_is_not_retried_as_get(self):
        class Backend:
            def request(self, path, data=None):
                raise urllib.error.HTTPError(path, 403, 'forbidden', {}, None)
        with self.assertRaises(urllib.error.HTTPError):
            cache.clear_doris(Backend())

    def test_missing_cache_metric_rejects_cold_claim(self):
        class Backend:
            brpc_port = 8060
            def request(self, path, data=None, port=None):
                return '{"status":"OK"}' if path.startswith('/api/file_cache') else '# no gauge'
        with self.assertRaisesRegex(RuntimeError, 'gauge is missing'):
            cache.clear_doris(Backend())


class ResultsTests(unittest.TestCase):
    def test_duplicate_and_null_mismatches_remain_distinct(self):
        fp = lambda rows: result_codec.fingerprints(rows, 1)['multiset_sha256']
        self.assertEqual(fp([(decimal.Decimal('1.00'),), (2,)]), fp([(2,), (1,)]))
        self.assertNotEqual(fp([(None,)]), fp([(0,)]))
        self.assertNotEqual(fp([(1,), (2,)]), fp([(1,), (1,)]))

    def test_numeric_difference_not_implicitly_tolerated(self):
        a = result_codec.fingerprints([(0.1,)], 1)
        b = result_codec.fingerprints([(0.1000000001,)], 1)
        self.assertNotEqual(a['multiset_sha256'], b['multiset_sha256'])

    def test_query_timer_excludes_session_setup(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary);sql = path / 'q18.sql';sql.write_text('SELECT 1')
            fake = object.__new__(runner.Runner)
            fake.plan = {'benchmark': 'tpch', 'sf': 50};fake.engine = 'doris';fake.output = path
            class Connection:
                def close(self):pass
            fake.connect = Connection
            events = []
            fake.configure = lambda connection: events.append('configure')
            def query(connection, text):
                events.append(text)
                return (None, [('id',)]) if text.startswith('SELECT last') else ([('x', 3, None, None, None, 0, True)], [(1,)])
            fake.query = query
            with patch.object(runner.time, 'monotonic', side_effect=[10, 12]):
                result = fake.execute(sql, 1)
            self.assertEqual(events, ['configure', 'SELECT 1', 'SELECT last_query_id()'])
            self.assertEqual(result['elapsed_s'], 2)
            self.assertEqual(result['status'], 'SUCCESS')
            self.assertTrue((path / result['raw_output']).exists())

    def test_effective_session_drift_prevents_measured_query(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'session.sql';path.write_text('SET enable_spill=true;')
            fake = object.__new__(runner.Runner);fake.plan = {'session_file': str(path), 'expected_session': {'enable_spill': 1}}
            queries = [];fake.query = lambda c,s: queries.append(s)
            fake.dicts = lambda c,s: [{'enable_spill': 0}]
            with self.assertRaisesRegex(RuntimeError, 'Effective session'):
                fake.configure(None)
            self.assertEqual(queries, ['SET enable_spill=true'])


class ShellSessionTests(unittest.TestCase):
    def test_both_engines_send_session_and_query_on_same_connection(self):
        for engine in ['doris', 'starrocks']:
            with self.subTest(engine=engine), tempfile.TemporaryDirectory() as temporary:
                p = Path(temporary);(p / 'session.sql').write_text('SET enable_spill=true;\nSET query_mem_limit=8589934592;')
                script = r'''
set -euo pipefail
source "$1/engines/$2_engine.sh"
TEST_ROOT="$3"; SESSION_FILE=session.sql; RESULT_DIR="$3"; session=true
fe_host=localhost; fe_query_port=9030; user=root; password=''; db=test
mysql() { cat > "$RESULT_DIR/sent.sql"; printf 'query-id\n'; }
engine_run_sql test 'SELECT 42;' >/dev/null
'''
                subprocess.run(['bash', '-c', script, 'test', str(ROOT), engine, temporary],check=True)
                text = (p / 'sent.sql').read_text()
                self.assertLess(text.index('SET enable_spill=true'), text.index('SELECT 42'))
                self.assertLess(text.index('SET query_mem_limit'), text.index('SELECT 42'))
                self.assertIn('last_query_id()', text.lower())


if __name__ == '__main__':
    unittest.main()
