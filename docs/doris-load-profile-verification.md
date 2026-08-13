# Doris Load Profile Collection Verification

This document records the reproducible validation of load-profile collection
for the benchmark runner. It is intended to accompany the pull request that
adds Doris load diagnostics.

## Test environment

- Date: 2026-08-13 (Asia/Shanghai)
- Test host: isolated development host; the test was executed locally on that
  host
- Doris MySQL endpoint: `127.0.0.1:9535`
- Doris HTTP endpoint: `127.0.0.1:8535`
- Doris version: `doris-0.0.0-7a9447f368`
- Source file: public S3 object
  `s3://bench-dataset/ssb/sf100/date/date.tbl.gz`

No production database or table was used. The integration test created a
unique database and configured the benchmark to drop it after the assertions.

## Reproduction command

Run the checked-in end-to-end test from the repository root:

```bash
FE_HOST=127.0.0.1 \
FE_QUERY_PORT=9535 \
FE_HTTP_PORT=8535 \
KEEP_TEST_ARTIFACTS=true \
make integration-test-doris-profile
```

The test fixture is under `tests/fixtures/doris_load_profile/`. Override the
connection variables for another Doris deployment. Set
`KEEP_TEST_ARTIFACTS=false` or omit it to remove generated results after all
assertions pass.

## Assertions performed

The integration test fails unless all of the following are true:

1. `INSERT INTO ... SELECT` writes 100,000 rows and produces a non-empty Doris
   Load Profile containing write-side counters.
2. S3/Broker Load reaches `FINISHED`, writes 2,556 rows, and produces both the
   final `SHOW LOAD` diagnostics and a Load Profile containing
   `FileReadTime` and `RowsRead`.
3. Stream Load returns `Success`, writes two rows, and persists a JSON response
   containing `LoadTimeMs`, `WriteDataTimeMs`, and
   `CommitAndPublishTimeMs`.
4. A regular `SELECT COUNT(*)` produces a non-empty Query Profile, verifying
   that the existing query-profile path still works.
5. `load.csv` and `load_profile.csv` map all methods to their artifacts.
6. No missing-profile warning is emitted.
7. The global `enable_profile` value is unchanged by the benchmark.
8. The temporary database is removed.

## Passing main-branch run

The following output is copied from the successful integration-test run:

```text
DORIS_LOAD_PROFILE_INTEGRATION_TEST=PASS
DORIS_VERSION=doris version doris-0.0.0-7a9447f368
INSERT_PROFILE_ID=e26c9f5709e1446f-99edea72d4857b9f
S3_LOAD_PROFILE_ID=1786568594874
QUERY_PROFILE_ID=5a304b1592794a9f-a2e92aa134e7fcf7
STREAM_LOAD_METRICS={"TxnId":798757,"LoadTimeMs":22,"WriteDataTimeMs":3,"CommitAndPublishTimeMs":15}
GLOBAL_ENABLE_PROFILE_BEFORE=1
GLOBAL_ENABLE_PROFILE_AFTER=1
TEMPORARY_DATABASE_DROPPED=true
```

### Recorded load durations

```csv
table_name,method,load_time_seconds
insert_probe,insert_into,.137
dates_probe,s3_load,9.799
stream_probe,stream_load,.097
```

### Recorded profile index

```csv
load_name,method,profile_id,artifact_type
insert_probe,insert_into,e26c9f5709e1446f-99edea72d4857b9f,profile
dates_probe,s3_load,,diagnostics
dates_probe,s3_load,1786568594874,profile
bench_<generated>_stream_probe,stream_load,798757,stream_load_response
stream_probe,stream_load,,diagnostics
```

### Profile evidence

INSERT Load Profile:

```text
Profile ID: e26c9f5709e1446f-99edea72d4857b9f
Task Type: LOAD
Total: 105ms
RowsRead: 100.0K (100000)
SendDataTime: 13.354ms
CloseWaitTime: 68.282ms
```

S3/Broker Load Profile:

```text
Profile ID: 1786568594874
Task Type: LOAD
Total: 8sec386ms
ScanBytes: 34.36 KB
ScanRows: 2.556K (2556)
FileReadTime: 3sec24ms
RowsRead: 2.556K (2556)
CloseWaitTime: 6.268ms
```

Stream Load response:

```json
{
  "Status": "Success",
  "NumberLoadedRows": 2,
  "TxnId": 798757,
  "LoadTimeMs": 22,
  "WriteDataTimeMs": 3,
  "CommitAndPublishTimeMs": 15
}
```

Generated artifact sizes demonstrate that the files contain detailed profiles,
not only identifiers:

```text
INSERT Load Profile:     41,832 bytes
S3/Broker Load Profile:  14,229 bytes
Stream Load response:       505 bytes
Query Profile:            80,213 bytes
```

## Reliability observation

An initial strict integration run used the benchmark's original 10-second
Broker Load polling interval. On this busy master cluster, the completed Load
Profile was evicted before the next collection attempt, and the integration
test correctly failed on the missing artifact.

The runner now supports `LOAD_STATUS_POLL_INTERVAL_SECONDS`. The integration
test uses one-second polling so it can fetch a completed asynchronous profile
promptly. The passing run above completed without missing-profile warnings.
The production default remains 10 seconds and can be overridden for busy
clusters.

After rebasing the change onto the latest upstream `main`, the test was
repeated with the default cleanup mode and passed again:

```text
DORIS_LOAD_PROFILE_INTEGRATION_TEST=PASS
INSERT_PROFILE_ID=eae7854080a24f61-a3f1044738764596
S3_LOAD_PROFILE_ID=1786568616392
QUERY_PROFILE_ID=bda43bd789404304-87710d33d11894db
STREAM_LOAD_METRICS={"TxnId":799482,"LoadTimeMs":24,"WriteDataTimeMs":3,"CommitAndPublishTimeMs":17}
GLOBAL_ENABLE_PROFILE_BEFORE=1
GLOBAL_ENABLE_PROFILE_AFTER=1
TEMPORARY_DATABASE_DROPPED=true
RESULT_DIR=<removed after assertions>
```

## Additional checks

The non-cluster helper test is available through:

```bash
make test
```

It validates profile indexing, Broker Load label extraction, Stream Load
response persistence, and credential redaction without requiring Doris.

At the time of this record, the configured Doris 2.1 and 3.0 FE ports were not
listening, so this report does not claim end-to-end coverage for those two
deployments. Runtime detection of `enable_profile` and the older
`is_report_success` variable remains in place for version compatibility.
