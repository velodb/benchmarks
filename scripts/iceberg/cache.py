"""Prepare data-I/O cold state without changing the enabled cache budgets."""
import base64
import json
import os
from pathlib import Path
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request


class Backend:
    def __init__(self, host, user='root', password='', http_port=8040, brpc_port=8060):
        self.host, self.http_port, self.brpc_port = host, http_port, brpc_port
        self.authorization = 'Basic ' + base64.b64encode(f'{user}:{password}'.encode()).decode()

    def request(self, path, data=None, port=None):
        request = urllib.request.Request(
            f'http://{self.host}:{port or self.http_port}{path}', data=data,
            headers={'Authorization': self.authorization})
        with urllib.request.urlopen(request, timeout=180) as response:
            return response.read().decode()

    def update(self, name, value):
        response = json.loads(self.request('/api/update_config?' + urllib.parse.urlencode({name: value}), b''))
        if response.get('status') != 'OK':
            raise RuntimeError(f'Cannot set backend config {name}: {response}')


def wait_empty(read, predicate, timeout=180):
    deadline = time.monotonic() + timeout
    while True:
        value = read()
        if predicate(value):
            return value
        if time.monotonic() >= deadline:
            raise RuntimeError('Backend data cache did not become empty')
        time.sleep(0.5)


def clear_doris(backend):
    # Integrated builds register POST; older cloud builds register GET.
    try:
        response = backend.request('/api/file_cache?op=clear&sync=true', b'')
        method = 'POST'
    except urllib.error.HTTPError as error:
        if error.code not in (404, 405):
            raise
        response = backend.request('/api/file_cache?op=clear&sync=true')
        method = 'GET'
    if json.loads(response).get('status') != 'OK':
        raise RuntimeError('Doris file-cache clear was rejected')

    def sizes():
        text = backend.request('/brpc_metrics', port=backend.brpc_port)
        values = [int(float(line.split()[-1])) for line in text.splitlines()
                  if 'file_cache_cache_size' in line and not line.startswith('#')]
        if not values:
            raise RuntimeError('Doris file-cache size gauge is missing')
        return values

    after = wait_empty(sizes, lambda values: all(value == 0 for value in values))
    page = backend.request('/api/clear_cache/DataPageCache')
    verify = backend.request('/api/clear_cache/DataPageCache')
    if 'prune win' not in page or 'freed size 0' not in verify:
        raise RuntimeError('Doris data-page cache did not clear')
    return {'method': method, 'file_cache_bytes': after, 'data_page_check': verify}


def clear_starrocks(backend, saved):
    """The caller reads these two values from this BE's information_schema.be_configs."""
    if set(saved) != {'datacache_mem_size', 'datacache_disk_size'}:
        raise ValueError('Both original StarRocks cache settings are required')
    before = json.loads(backend.request('/api/datacache/stat'))
    try:
        backend.update('datacache_mem_size', '0')
        backend.update('datacache_disk_size', '0')
        empty = wait_empty(
            lambda: json.loads(backend.request('/api/datacache/stat')),
            lambda value: value['page_cache_mem_used_bytes'] == 0 and value['block_cache_disk_used_bytes'] == 0)
    finally:
        # Always attempt both restores, including a failure during the first shrink.
        errors = []
        for key in ['datacache_disk_size', 'datacache_mem_size']:
            try:
                backend.update(key, saved[key])
            except Exception as error:
                errors.append(str(error))
        if errors:
            raise RuntimeError('StarRocks cache restoration failed: ' + '; '.join(errors))
    restored = json.loads(backend.request('/api/datacache/stat'))
    if restored['block_cache_disk_quota_bytes'] != before['block_cache_disk_quota_bytes']:
        raise RuntimeError('StarRocks disk cache quota changed')
    # Memory auto-adjust can change the transient quota between two queries.
    # Restore the original configuration, not that transient adaptive quota.
    if saved['datacache_mem_size'] not in ['0', '0%'] and restored['page_cache_mem_quota_bytes'] <= 0:
        raise RuntimeError('StarRocks configured memory cache was not restored')
    if restored['page_cache_mem_used_bytes'] or restored['block_cache_disk_used_bytes']:
        raise RuntimeError('StarRocks cache refilled before the cold query')
    return {'original_config': saved, 'empty': empty, 'restored': restored}


def drop_os_cache(host, ssh_user='root'):
    # A private password file is optional; no remote authorized_keys are changed.
    args = ['ssh', '-o', 'ConnectTimeout=10']
    password_file = os.environ.get('ICEBERG_SSH_PASSWORD_FILE')
    known_hosts = os.environ.get('ICEBERG_SSH_KNOWN_HOSTS_FILE')
    if known_hosts:
        args += ['-o', 'UserKnownHostsFile=' + known_hosts, '-o', 'StrictHostKeyChecking=accept-new']
    else:
        args += ['-o', 'StrictHostKeyChecking=yes']
    args += ['-o', 'NumberOfPasswordPrompts=1', f'{ssh_user}@{host}',
             'sync && sudo -n sh -c "echo 3 > /proc/sys/vm/drop_caches"']
    if password_file:
        path = Path(password_file)
        if path.stat().st_mode & 0o077:
            raise ValueError('SSH password file must have private permissions')
        with path.open('rb') as secret:
            result = subprocess.run(['sshpass', '-d', str(secret.fileno()), *args],
                                    pass_fds=(secret.fileno(),), capture_output=True, text=True, timeout=60)
    else:
        args[1:1] = ['-o', 'BatchMode=yes']
        result = subprocess.run(args, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError('OS cache clear failed: ' + result.stderr)
    return {'returncode': result.returncode, 'host': host}
