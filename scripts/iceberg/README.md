# Retained-output Iceberg measurements

`runner.py` runs one Doris/StarRocks Iceberg case on a dedicated single-BE engine.
It keeps the existing shell entrypoint unchanged. Install `requirements.txt`, then:

```sh
python3 scripts/iceberg/runner.py --plan /path/to/frozen-plan.json \
  --output /path/to/new-run/doris/tpch/sf50 --lock-file /path/to/shared-measurement.lock
```

The plan supplies `engine`, `benchmark`, `sf`, `connection` (host, port, user,
HTTP port and password environment-variable name), `backend` (host, HTTP/brpc
ports, SSH user), catalog/namespace, REST URI/warehouse, query/session paths,
per-file SHA256 hashes (`queries`), and per-table `row_count`/`snapshot_id`.
It also supplies `expected_session`, `expected_backend_config`, `cpu_cores`,
`version_contains`, `fe_heap_bytes`, and `cache_bytes`. The caller freezes these
from its dataset and deployment; this public tool contains no private suites,
service addresses, credentials, or platform-specific workflow definitions.

Each case checks the running version, CPU, FE heap, BE/cache configuration and
session values; verifies source snapshots; runs synchronous Full Analyze and
checks every column's statistics; then runs each query three times serially.
Before the first run it clears local file/data-page and OS page caches and
verifies empty engine caches. Cache capacities are enabled and restored before
measurement. Two hot repeats immediately follow without clearing. Planner,
metadata/JVM and remote object-store caches are not reset. This is **data-I/O
cold**, not a process-cold or remote-storage-cold measurement.

Doris integrated builds use POST `/api/file_cache`; unsupported-method responses
fall back to GET for older cloud builds. StarRocks uses the mutable memory/disk
cache quotas to evict cached data, restores both original settings in `finally`,
and checks quota and empty-state readback. OS clearing uses existing SSH access
and noninteractive `sudo`; use only dedicated benchmark hosts. A clearing or
restoration failure prevents a cold timing from being published.

Time is monotonic execute + fetchall, excluding connection/session setup,
cache preparation, output serialization and last-query-ID retrieval. Each
successful query keeps its typed rows, column metadata, strict ordered/multiset
hashes and raw-file SHA256. Decimal values, NULL and duplicate multiplicity are
preserved. A query error is retained and stops the suite so an orphan cannot
contaminate later measurements. Existing output directories are not restarted.

`ANALYZE_STATE.json`, `RUNTIME_PRECHECK.json`, per-query cold preparation files,
`RESULTS.jsonl`, `SNAPSHOTS_BEFORE/AFTER.json`, and `SUITE_STATE.json` are suitable
for downstream auditing. A separate private workload may layer a *frozen*
numeric compatibility contract over the strict hashes; this tool does not
silently introduce numeric tolerances or declare successful execution to be
result equivalence. Keep a genuine workflow/execution ID and its real timestamps
when a platform consumes these results; do not invent IDs for standalone imports.

Tests (no live database or cache mutation):

```sh
python3 -m unittest discover -s tests -p 'test_iceberg_runner.py' -v
```
