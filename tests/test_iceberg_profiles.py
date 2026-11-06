import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts/iceberg'))
import cache
import profiles
import runner


class ProfileTests(unittest.TestCase):
    def test_profile_is_enabled_after_the_original_profile_off_setup(self):
        with tempfile.TemporaryDirectory() as tmp:
            collector = object.__new__(profiles.Collector)
            collector.plan = {'engine': 'doris', 'benchmark': 'ssb', 'sf': 10}
            commands = []
            class FakeRunner:
                def query(self, connection, sql):
                    commands.append(sql)
                    if sql.startswith('SELECT last_query_id'):
                        return None, [('own-query-id',)]
                    return [('value', 3, None, None, None, None, True)], [(7,)]
                def dicts(self, connection, sql):
                    return [{'enabled': 1, 'level': 2}]
            collector.runner = FakeRunner()
            source = b'SELECT 7;\r\n'
            result = collector.execute(object(), source, 'q1', 'profile', Path(tmp))
            self.assertEqual(commands[:2], ['SET enable_profile=true', 'SET profile_level=2'])
            self.assertIn(source.decode(), commands)
            self.assertEqual(result['query_id'], 'own-query-id')
            self.assertEqual(result['row_count'], 1)
            self.assertTrue((Path(tmp) / 'profile-output.json.gz').exists())

    def test_pending_profile_is_retried_until_matching_execution_detail_exists(self):
        c = object.__new__(profiles.Collector);c.plan = {'engine': 'starrocks'}
        class FE:
            calls = 0
            def request(self, path):
                self.calls += 1
                return 'pending' if self.calls == 1 else 'Query ID: own-id\nFragment 0: execution detail'
        c.fe = FE()
        with patch.object(profiles.time, 'sleep'):
            self.assertIn('Fragment', c.fetch('own-id'))
        self.assertEqual(c.fe.calls, 2)

    def test_wrong_query_profile_is_not_accepted(self):
        c = object.__new__(profiles.Collector);c.plan = {'engine': 'doris'}
        class FE:
            def request(self, path):return 'Other query\nExecution Profile'
        c.fe = FE()
        with patch.object(profiles.time, 'monotonic', side_effect=[0, 61]):
            with self.assertRaisesRegex(RuntimeError, 'could not be retrieved'):
                c.fetch('own-id')

    def test_formal_execute_preserves_crlf_query_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp);source = p/'q1.sql';source.write_bytes(b'SELECT 1;\r\n')
            calls = []
            class Connection:
                def close(self):pass
            class Tool(runner.Runner):
                def connect(self):return Connection()
                def configure(self,c):pass
                @staticmethod
                def query(c, sql):
                    calls.append(sql)
                    if sql.startswith('SELECT last_query_id'):return None,[('id',)]
                    return [('x',3,None,None,None,None,True)],[(1,)]
            tool=object.__new__(Tool);tool.plan={'benchmark':'ssb','sf':10};tool.engine='doris';tool.output=p
            self.assertEqual(tool.execute(source,1)['status'],'SUCCESS')
            self.assertEqual(calls[0],'SELECT 1;\r\n')

    def test_rest_prefix_is_not_double_encoded(self):
        import io
        for prefix in ['main%7Cwarehouse', 'main|warehouse']:
            tool=object.__new__(runner.Runner)
            tool.plan={'rest':{'uri':'http://rest/iceberg','warehouse':'warehouse'},'namespace':'dataset',
                       'tables':{'table':{'snapshot_id':123}}}
            requests=[]
            def request(url,**kwargs):
                requests.append(url)
                if '/config?' in url:return io.BytesIO(json.dumps({'overrides':{'prefix':prefix}}).encode())
                self.assertEqual(url,'http://rest/iceberg/v1/main%7Cwarehouse/namespaces/dataset/tables/table')
                return io.BytesIO(b'{"metadata":{"current-snapshot-id":123}}')
            with patch.object(runner.urllib.request,'urlopen',side_effect=request):self.assertEqual(tool.snapshots(),{'table':123})
            self.assertEqual(len(requests),2)

    def test_private_ssh_secret_is_passed_by_file_descriptor(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'password';p.write_text('test-only-password\n');p.chmod(0o600)
            seen={}
            def call(args,**kwargs):
                seen['args']=args;seen['fds']=kwargs['pass_fds']
                self.assertNotIn('test-only-password',' '.join(args))
                self.assertEqual(os.read(kwargs['pass_fds'][0],100),b'test-only-password\n')
                return subprocess.CompletedProcess(args,0,'','')
            with patch.dict(os.environ,{'ICEBERG_SSH_PASSWORD_FILE':str(p)},clear=True),patch.object(cache.subprocess,'run',side_effect=call):
                self.assertEqual(cache.drop_os_cache('dedicated-node')['returncode'],0)
            self.assertEqual(seen['args'][0],'sshpass')

    def test_world_readable_ssh_secret_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'password';p.write_text('test-only');p.chmod(0o644)
            with patch.dict(os.environ,{'ICEBERG_SSH_PASSWORD_FILE':str(p)},clear=True),patch.object(cache.subprocess,'run') as call:
                with self.assertRaisesRegex(ValueError,'private permissions'):cache.drop_os_cache('node')
                call.assert_not_called()


if __name__=='__main__':unittest.main()
