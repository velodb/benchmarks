#!/usr/bin/env python3
"""Collect postflight warm-query Profiles without replacing formal measurements."""
import argparse
import fcntl
import gzip
import hashlib
import json
from pathlib import Path
import re
import time
import urllib.parse

import cache
import result_codec
from runner import Runner, save, stamp


class Collector:
    def __init__(self, plan, formal, output):
        self.plan, self.formal, self.output = plan, formal, output
        self.runner = Runner(plan, output)
        c = plan['connection']
        self.fe = cache.Backend(c['host'], c.get('user', 'root'), self.runner.password, c.get('http_port', 8030))

    def execute(self, connection, source, query, phase, folder):
        enabled = phase == 'profile'
        self.runner.query(connection, 'SET enable_profile=' + ('true' if enabled else 'false'))
        name = 'profile_level' if self.plan['engine'] == 'doris' else 'pipeline_profile_level'
        if enabled:
            self.runner.query(connection, 'SET ' + name + '=2')
        actual = self.runner.dicts(connection, 'SELECT @@enable_profile AS enabled,@@' + name + ' AS level')[0]
        if int(actual['enabled']) != int(enabled) or (enabled and int(actual['level']) != 2):
            raise RuntimeError('Effective Profile settings differ from the diagnostic plan')
        record = {'engine': self.plan['engine'], 'benchmark': self.plan['benchmark'], 'sf': self.plan['sf'],
                  'query': query, 'phase': phase, 'profile_enabled': enabled, 'profile_level': int(actual['level']),
                  'sql_sha256': hashlib.sha256(source).hexdigest(), 'started_at': stamp()}
        start = time.monotonic()
        try:
            description, rows = self.runner.query(connection, source.decode('utf-8'))
            record.update(status='SUCCESS', elapsed_s=time.monotonic() - start, finished_at=stamp())
            _, result = self.runner.query(connection, 'SELECT last_query_id()')
            record['query_id'] = str(result[0][0])
            record.update(result_codec.fingerprints(rows, len(description)))
            target = folder / (phase + '-output.json.gz')
            with gzip.open(target, 'wt', encoding='utf-8') as stream:
                json.dump({'columns': [list(d) for d in description], 'rows': rows}, stream,
                          ensure_ascii=False, default=result_codec.json_value)
            record.update(raw_output=target.name, raw_output_sha256=hashlib.sha256(target.read_bytes()).hexdigest())
        except Exception as error:
            record.update(status='ERROR', error=str(error), finished_at=stamp())
            save(folder / (phase + '-RESULT.json'), record)
            raise
        save(folder / (phase + '-RESULT.json'), record)
        return record

    def fetch(self, query_id):
        endpoint = '/api/profile/text?query_id=' if self.plan['engine'] == 'doris' else '/api/profile?query_id='
        deadline = time.monotonic() + 60
        while True:
            try:
                body = self.fe.request(endpoint + urllib.parse.quote(query_id, safe=''))
                if query_id not in body or not any(x in body for x in ['Execution', 'Fragment']):
                    raise RuntimeError('Profile is not ready or has no execution detail')
                return body
            except Exception:
                if time.monotonic() >= deadline:
                    raise RuntimeError('Complete diagnostic Profile could not be retrieved') from None
                time.sleep(1)

    def run(self):
        self.output.mkdir(parents=True, exist_ok=True)
        if (self.output / 'PROFILE_STATE.json').exists():
            raise RuntimeError('Existing diagnostics require inspection; implicit restart is disabled')
        formal = json.loads((self.formal / 'SUITE_STATE.json').read_text())
        if formal['state'] != 'suite_complete':
            raise RuntimeError('Profiles require a successfully completed formal suite')
        state = {'state': 'preflight', 'started_at': stamp(), 'completed_profiles': 0,
                 'purpose': 'Postflight diagnostics; these timings never replace formal scores'}
        save(self.output / 'PROFILE_STATE.json', state)
        connection = self.runner.connect()
        try:
            self.runner.preflight(connection)
            before = self.runner.snapshots()
            if before != json.loads((self.formal / 'SNAPSHOTS_AFTER.json').read_text()):
                raise RuntimeError('Snapshot changed since formal measurements')
            save(self.output / 'SNAPSHOTS_BEFORE.json', before)
            files = sorted(Path(self.plan['query_dir']).glob('*.sql'),
                           key=lambda p: tuple(map(int, re.findall(r'\d+', p.stem))))
            if {f.name for f in files} != set(self.plan['queries']):
                raise RuntimeError('Diagnostic query coverage differs from frozen formal inputs')
            for sql in files:
                source = sql.read_bytes()
                if hashlib.sha256(source).hexdigest() != self.plan['queries'][sql.name]:
                    raise RuntimeError('SQL changed after formal measurements')
                query = 'q' + '.'.join(str(int(x)) for x in re.findall(r'\d+', sql.stem))
                folder = self.output / query
                folder.mkdir()
                (folder / 'QUERY.sql').write_bytes(source)
                self.runner.configure(connection)
                self.runner.idle(connection)
                for kind in (['EXPLAIN', 'EXPLAIN VERBOSE'] if self.plan['engine'] == 'doris' else ['EXPLAIN', 'EXPLAIN COSTS']):
                    _, rows = self.runner.query(connection, kind + ' ' + source.decode('utf-8'))
                    (folder / (kind.replace(' ', '_') + '.txt')).write_text('\n'.join(str(x[0]) for x in rows) + '\n')
                warm = self.execute(connection, source, query, 'warmup', folder)
                profiled = self.execute(connection, source, query, 'profile', folder)
                body = self.fetch(profiled['query_id'])
                (folder / 'PROFILE.txt').write_text(body)
                save(folder / 'PROFILE_RECEIPT.json', {'query_id': profiled['query_id'],
                     'bytes': len(body.encode()), 'sha256': hashlib.sha256(body.encode()).hexdigest(),
                     'warmup_exact': warm['multiset_sha256'] == profiled['multiset_sha256']})
                state.update(state='running', current=query, completed_profiles=state['completed_profiles'] + 1)
                save(self.output / 'PROFILE_STATE.json', state)
            after = self.runner.snapshots()
            if after != before:
                raise RuntimeError('Snapshot drift during diagnostics')
            save(self.output / 'SNAPSHOTS_AFTER.json', after)
            state.update(state='profiles_complete', current=None, finished_at=stamp())
            save(self.output / 'PROFILE_STATE.json', state)
            return state
        except Exception as error:
            state.update(state='failed', error=str(error), finished_at=stamp())
            save(self.output / 'PROFILE_STATE.json', state)
            raise
        finally:
            connection.close()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for name in ['plan', 'formal-output', 'output', 'lock-file']:
        p.add_argument('--' + name, type=Path, required=True)
    args = p.parse_args()
    args.lock_file.parent.mkdir(parents=True, exist_ok=True)
    with args.lock_file.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print(json.dumps(Collector(json.loads(args.plan.read_text()), args.formal_output, args.output).run()))


if __name__ == '__main__':
    main()
