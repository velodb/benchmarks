#!/usr/bin/env python3
"""Run one frozen Iceberg case: Full Analyze, verified data-cold1, hot2, typed outputs.

Plans contain connection/HTTP addresses, not embedded credentials. Database passwords
are read from the named environment variable. QA orchestration lives outside this tool.
"""
import argparse
import collections
import datetime
import fcntl
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import time
import urllib.parse
import urllib.request

import cache
import result_codec


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def save(path, value):
    temp = path.with_suffix(path.suffix + '.tmp')
    temp.write_text(json.dumps(value, ensure_ascii=False, indent=2, default=result_codec.json_value) + '\n')
    temp.replace(path)


def identifier(value):
    if not re.fullmatch(r'[A-Za-z_][A-Za-z_0-9]*', value):
        raise ValueError('Unsupported SQL identifier: ' + value)
    return '`' + value + '`'


class Runner:
    def __init__(self, plan, output):
        self.plan, self.output = plan, output
        self.engine = plan['engine']
        if self.engine not in ['doris', 'starrocks']:
            raise ValueError('Only Doris and StarRocks are supported')
        self.password = os.environ.get(plan['connection'].get('password_env', 'DB_PASSWORD'), '')
        self.backend = cache.Backend(
            plan['backend']['host'], plan['connection'].get('user', 'root'), self.password,
            plan['backend'].get('http_port', 8040), plan['backend'].get('brpc_port', 8060))

    def connect(self):
        import pymysql
        c = self.plan['connection']
        return pymysql.connect(host=c['host'], port=c.get('port', 9030), user=c.get('user', 'root'),
                               password=self.password, charset='utf8mb4', autocommit=True,
                               connect_timeout=15, read_timeout=1850, write_timeout=30)

    @staticmethod
    def query(connection, sql):
        with connection.cursor() as cursor:
            cursor.execute(sql)
            return cursor.description, cursor.fetchall()

    def dicts(self, connection, sql):
        columns, rows = self.query(connection, sql)
        return [dict(zip([c[0] for c in columns], row)) for row in rows]

    def configure(self, connection):
        content = re.sub(r'--[^\n]*', '', Path(self.plan['session_file']).read_text())
        for command in content.split(';'):
            if not command.strip():
                continue
            if not command.strip().upper().startswith('SET '):
                raise ValueError('Session files may contain only SET statements')
            self.query(connection, command)
        expected = self.plan['expected_session']
        for name in expected:
            identifier(name)
        actual = self.dicts(connection, 'SELECT ' + ','.join('@@' + k + ' AS ' + k for k in expected))[0]
        if any(int(actual[k]) != int(v) for k, v in expected.items()):
            raise RuntimeError('Effective session settings differ from the frozen plan')
        self.query(connection, 'USE ' + identifier(self.plan['catalog']) + '.' + identifier(self.plan['namespace']))
        return actual

    def snapshots(self):
        rest = self.plan['rest']
        uri = rest['uri'].rstrip('/') + '/v1'
        with urllib.request.urlopen(uri + '/config?' + urllib.parse.urlencode({'warehouse': rest['warehouse']}), timeout=30) as response:
            config = json.load(response)
        options = {**config.get('defaults', {}), **config.get('overrides', {})}
        prefix = options.get('prefix', '')
        root = uri + ('/' + urllib.parse.quote(prefix.strip('/'), safe='/') if prefix else '')
        found = {}
        namespace = urllib.parse.quote(self.plan['namespace'], safe='')
        for table, expected in self.plan['tables'].items():
            with urllib.request.urlopen(root + '/namespaces/' + namespace + '/tables/' + urllib.parse.quote(table, safe=''), timeout=30) as response:
                metadata = json.load(response)['metadata']
            found[table] = metadata['current-snapshot-id']
            if found[table] != expected['snapshot_id']:
                raise RuntimeError('Iceberg source snapshot changed: ' + table)
        return found

    def idle(self, connection):
        active = [row for row in self.dicts(connection, 'SHOW FULL PROCESSLIST')
                  if str(row.get('Command', '')).lower() == 'query'
                  and str(row.get('Info', '')).strip().upper() != 'SHOW FULL PROCESSLIST']
        if active:
            raise RuntimeError('Other queries are active on the dedicated benchmark engine')

    def preflight(self, connection):
        session = self.configure(connection)
        self.idle(connection)
        rows = self.dicts(connection, 'SHOW BACKENDS')
        if len(rows) != 1 or str(rows[0]['Alive']).lower() not in ['true', '1']:
            raise RuntimeError('This plan requires one live backend')
        backend = rows[0]
        if int(backend['CpuCores']) != self.plan['cpu_cores'] or self.plan['version_contains'] not in backend['Version']:
            raise RuntimeError('Backend CPU/version drift')
        names = self.plan['expected_backend_config']
        if self.engine == 'doris':
            all_configs = {row[0]: row[2] for row in json.loads(self.backend.request('/api/show_config'))}
            configs = {name: all_configs.get(name) for name in names}
            if sum(int(p['total_size']) for p in json.loads(all_configs['file_cache_path'])) != self.plan['cache_bytes']:
                raise RuntimeError('Doris file-cache capacity drift')
        else:
            quoted = ','.join("'" + identifier(name).strip('`') + "'" for name in names)
            configs = {row['NAME']: row['VALUE'] for row in self.dicts(connection, 'SELECT NAME,VALUE FROM default_catalog.information_schema.be_configs WHERE NAME IN (' + quoted + ')')}
        if any(str(configs.get(k)) != str(v) for k, v in names.items()):
            raise RuntimeError('Backend configuration drift')
        fe = cache.Backend(self.plan['connection']['host'], self.plan['connection'].get('user', 'root'),
                           self.password, self.plan['connection'].get('http_port', 8030))
        metrics = fe.request('/metrics')
        heap = re.search(r'^jvm_heap_size_bytes\{type="max"\}\s+([0-9.eE+]+)', metrics, re.M)
        if not heap or int(float(heap[1])) != self.plan['fe_heap_bytes']:
            raise RuntimeError('FE heap budget drift')
        # Keep only the expected fields; no catalog credential dumps.
        save(self.output / 'RUNTIME_PRECHECK.json', {'at': stamp(), 'session': session,
             'backend': {k: backend[k] for k in ['BackendId', 'Alive', 'Version', 'CpuCores']}, 'config': configs})

    def analyze(self, connection):
        ledger = {'started_at': stamp(), 'state': 'analyzing', 'tables': {}}
        self.query(connection, 'SET query_timeout=1800')
        for table, expected in self.plan['tables'].items():
            full = identifier(self.plan['catalog']) + '.' + identifier(self.plan['namespace']) + '.' + identifier(table)
            sql = ('ANALYZE TABLE ' + full + ' WITH SYNC' if self.engine == 'doris'
                   else 'ANALYZE FULL TABLE ' + full + ' WITH SYNC MODE')
            started = stamp()
            start = time.monotonic()
            _, response = self.query(connection, sql)
            elapsed = time.monotonic() - start
            columns = {row['Field'] for row in self.dicts(connection, 'DESC ' + full)}
            if self.engine == 'doris':
                stats = self.dicts(connection, 'SHOW COLUMN STATS ' + full)
                valid = {r['column_name'] for r in stats} == columns and all(
                    r['method'] == 'FULL' and int(float(r['count'])) == expected['row_count']
                    and float(r['ndv']) >= 0 and 0 <= float(r['num_null']) <= expected['row_count'] for r in stats)
            else:
                # Identifiers are validated before interpolation into this metadata predicate.
                catalog = identifier(self.plan['catalog']).strip('`')
                namespace = identifier(self.plan['namespace']).strip('`')
                name = identifier(table).strip('`')
                stats = self.dicts(connection, "SELECT column_name,SUM(row_count) AS stat_rows,MAX(hll_cardinality(ndv)) AS ndv,SUM(null_count) AS num_null,COUNT(*) AS partition_rows FROM _statistics_.external_column_statistics "
                                   f"WHERE catalog_name='{catalog}' AND db_name='{namespace}' AND table_name='{name}' GROUP BY column_name")
                valid = {r['column_name'] for r in stats} == columns and all(
                    int(r['partition_rows']) == 1 and int(r['stat_rows']) == expected['row_count']
                    and float(r['ndv']) >= 0 and 0 <= int(r['num_null']) <= expected['row_count'] for r in stats)
            if not valid:
                raise RuntimeError('Full Analyze statistics validation failed: ' + table)
            ledger['tables'][table] = {'started_at': started, 'elapsed_s': elapsed, 'snapshot_id': expected['snapshot_id'], 'columns': len(columns)}
            save(self.output / 'ANALYZE_STATE.json', ledger)
        ledger.update(state='statistics_verified', finished_at=stamp())
        save(self.output / 'ANALYZE_STATE.json', ledger)
        self.configure(connection)
        return ledger

    def cold(self, connection, query_name):
        self.idle(connection)
        started = stamp()
        start = time.monotonic()
        if self.engine == 'doris':
            cleared = cache.clear_doris(self.backend)
        else:
            saved = {row['NAME']: row['VALUE'] for row in self.dicts(connection, "SELECT NAME,VALUE FROM default_catalog.information_schema.be_configs WHERE NAME IN ('datacache_mem_size','datacache_disk_size')")}
            cleared = cache.clear_starrocks(self.backend, saved)
        os_clear = cache.drop_os_cache(self.plan['backend']['host'], self.plan['backend'].get('ssh_user', 'root'))
        save(self.output / (query_name + '-COLD_PREPARATION.json'), {'state': 'data_cold_ready', 'started_at': started,
             'finished_at': stamp(), 'preparation_elapsed_s': time.monotonic() - start, 'engine_cache': cleared, 'os': os_clear})

    def execute(self, sql_file, round_number):
        # Session setup and query-ID retrieval are deliberately outside the SQL timer.
        connection = self.connect()
        rows = None
        record = {'engine': self.engine, 'benchmark': self.plan['benchmark'], 'sf': self.plan['sf'],
                  'query': 'q' + '.'.join(str(int(x)) for x in re.findall(r'\d+', sql_file.stem)),
                  'round': round_number, 'round_label': ['strict_data_cold', 'repeat_1', 'repeat_2'][round_number - 1],
                  'sql_sha256': hashlib.sha256(sql_file.read_bytes()).hexdigest(), 'elapsed_s': None}
        try:
            self.configure(connection)
            record['started_at'] = stamp()
            start = time.monotonic()
            try:
                description, rows = self.query(connection, sql_file.read_bytes().decode('utf-8'))
                record.update(status='SUCCESS', elapsed_s=time.monotonic() - start,
                              **result_codec.fingerprints(rows, len(description)))
            except Exception as error:
                status = 'TIMEOUT' if re.search(r'timeout|timed out|time out', str(error), re.I) else 'ERROR'
                record.update(status=status, observed_wall_s=time.monotonic() - start, error=str(error))
            record['finished_at'] = stamp()
            try:
                _, query_id = self.query(connection, 'SELECT last_query_id()')
                record['query_id'] = str(query_id[0][0])
            except Exception:
                record['query_id'] = None
        finally:
            connection.close()
        if rows is not None:
            path = self.output / f"{record['query']}-r{round_number}.json.gz"
            with gzip.open(path, 'wt', encoding='utf-8', compresslevel=1) as stream:
                json.dump({'columns': [list(d) for d in description], 'rows': rows}, stream,
                          ensure_ascii=False, default=result_codec.json_value)
            record.update(raw_output=path.name, raw_output_sha256=hashlib.sha256(path.read_bytes()).hexdigest())
        return record

    def run(self):
        self.output.mkdir(parents=True, exist_ok=True)
        state_file = self.output / 'SUITE_STATE.json'
        if state_file.exists():
            raise RuntimeError('Existing run requires inspection; implicit restart is disabled')
        state = {'state': 'preflight', 'suite_started_at': stamp(), 'completed_executions': 0}
        save(state_file, state)
        records = []
        connection = self.connect()
        try:
            self.preflight(connection)
            source = self.snapshots()
            save(self.output / 'SNAPSHOTS_BEFORE.json', source)
            files = sorted(Path(self.plan['query_dir']).glob('*.sql'), key=lambda p: tuple(map(int, re.findall(r'\d+', p.stem))))
            expected = self.plan['queries']
            if set(expected) != {f.name for f in files}:
                raise RuntimeError('Query coverage differs from frozen plan')
            for path in files:
                normalized = re.sub(r'--[^\n]*|/\*.*?\*/', ' ', path.read_text(), flags=re.S).strip()
                if not re.match(r'^(SELECT|WITH)\b', normalized, re.I) or re.search(r'\bINTO\s+OUTFILE\b|\bSET_VAR\b', normalized, re.I):
                    raise ValueError('Measured query must be a SELECT without session hints')
                if hashlib.sha256(path.read_bytes()).hexdigest() != expected[path.name]:
                    raise RuntimeError('Frozen SQL changed: ' + path.name)
            self.analyze(connection)
            for path in files:
                self.cold(connection, path.stem)
                for number in [1, 2, 3]:
                    state.update(state='running', current={'query': path.name, 'round': number})
                    save(state_file, state)
                    row = self.execute(path, number)
                    with (self.output / 'RESULTS.jsonl').open('a') as stream:
                        stream.write(json.dumps(row, ensure_ascii=False) + '\n')
                    records.append(row)
                    state['completed_executions'] = len(records)
                    state['counts'] = dict(collections.Counter(r['status'] for r in records))
                    save(state_file, state)
                    if row['status'] != 'SUCCESS':
                        # Do not let an orphan query contaminate subsequent measurements.
                        raise RuntimeError('Query failed; retained evidence requires inspection before continuing')
            after = self.snapshots()
            if after != source:
                raise RuntimeError('Snapshot drift during suite')
            save(self.output / 'SNAPSHOTS_AFTER.json', after)
            state.update(state='suite_complete', current=None, finished_at=stamp(), counts=dict(collections.Counter(r['status'] for r in records)))
            save(state_file, state)
            return state
        except Exception as error:
            state.update(state='failed', error=str(error), finished_at=stamp())
            save(state_file, state)
            raise
        finally:
            connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--lock-file', type=Path, required=True, help='Shared by all measured engines and suites')
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    args.lock_file.parent.mkdir(parents=True, exist_ok=True)
    with args.lock_file.open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        print(json.dumps(Runner(plan, args.output).run(), ensure_ascii=False))


if __name__ == '__main__':
    main()
