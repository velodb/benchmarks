# VeloDB Benchmarks

[![License](https://img.shields.io/badge/license-Apache--2.0-green)](./LICENSE)

**[velodb.github.io/benchmarks](https://velodb.github.io/benchmarks)**
An open, reproducible, and community-driven database benchmark project.

---

For a long time, database benchmarking has been dominated by organizations like TPC. While their standards are respected, they often lack code-level transparency. This has created a situation of "authoritative but distant," where users can trust the final numbers but cannot easily verify or understand the entire process behind them.

Inspired by the rise of open-source databases and modern platforms like [ClickBench](https://benchmark.clickhouse.com/) and [db-benchmarks](https://db-benchmarks.com/), this project aims to embrace a new paradigm centered on openness, continuous integration, and reproducibility.

Our goal is to build `velodb.github.io/benchmarks` into the industry's most trusted and impartial resource for performance evaluation. Every architectural decision for the platform is measured by whether it enhances transparency, reproducibility, and fairness.

## Core Principles

- **Benchmark-as-Code**: All test scripts, queries, environment configurations, and data loading logic are stored in this public Git repository, allowing anyone to review, fork, and run them.
- **Extreme Transparency**: We automatically record and publish the full metadata for every test run, including specific software versions, complete configuration files, detailed execution logs, raw performance data, and key system monitoring metrics.
- **Community-Driven**: We encourage community members to submit new database systems or optimize existing test scripts, fostering a virtuous ecosystem.

## Composite Benchmark Support

*   **Multi-Scenario Coverage**: Supports various industry-standard test sets like ClickBench, SSB, and TPC-H, covering different business scenarios.
*   **Easy to Extend**: Users can easily add new databases or custom test sets.
*   **Result Visualization**: Provides a web interface to intuitively display and compare test results.
*   **Automated Workflow**: Simple scripts to complete data preparation, test execution, and report generation.

## Quick Start

### Dependencies
- yq, jq, bc, envsubst, maketemp
- [Jmeter](https://jmeter.apache.org) (optional, only needed for running JMeter tests)

### Benchmark Workflow

1. **Clone the repository**
    ```bash
    git clone https://github.com/velodb/benchmarks.git
    cd benchmarks
    ```

2. **Choose a test scenario**
    Enter the corresponding database directory, such as `benchmarks/clickbench/doris`.

    > ⚠️ To run single-threaded tests, you need to install the corresponding database client (e.g., mysql-client); to run multi-threaded JMeter tests, you need to prepare the corresponding JDBC driver for the database (e.g., clickhouse-jdbc, snowflake-jdbc, mysql-connector).

3. **Configure benchmark.yaml**
    Edit the `benchmark.yaml` file in the database directory and fill in the connection information and parameters.

4. **Prepare third-party tools**
    ```bash
    make thirdpaty
    ```

5. **Run the test**
    ```bash
    bash benchmark.sh --config benchmarks/clickbench/doris/benchmark.yaml
    ```
    You can adjust parameters with environment variables:
    ```bash
    LOAD=false JMETER_THREADS=100 bash benchmark.sh --config ...
    ```
   For cloud scenarios on VeloDB / Doris, configure BE-side page cache behavior
   and optionally enable cache clearing.
   `BE_HOSTS` can be provided explicitly; when omitted, Doris tries to discover
   BE / Compute hosts from the FE via `SHOW BACKENDS` and `SHOW COMPUTE NODES`.
   Each flag is independent and can be combined:
   ```bash
   BE_HOSTS=10.0.0.11,10.0.0.12 \
   DORIS_PAGE_CACHE_ACTION=configure \
   DISABLE_DORIS_PAGE_CACHE=true \
   CLEAR_FILE_CACHE=true \
   CLEAR_SYS_PAGE_CACHE=true \
   CLEAR_CACHE_SCOPE=before_query \
   bash benchmark.sh --config benchmarks/clickbench_update/percent_100/velodb-cloud/benchmark.yaml
   ```
   - `DORIS_PAGE_CACHE_ACTION` — controls whether Doris BE `disable_storage_page_cache`
     is configured. Use `unchanged` or unset it to leave the BE config untouched,
     and `configure` to apply the value from `DISABLE_DORIS_PAGE_CACHE`.
     When `DORIS_PAGE_CACHE_ACTION=configure` and `DISABLE_DORIS_PAGE_CACHE` is unset,
     the target value defaults to `false`, matching the engine's original default.
     For compatibility, `DISABLE_DORIS_PAGE_CACHE=true` is still accepted as
     `DORIS_PAGE_CACHE_ACTION=configure` with value `true`; `DISABLE_DORIS_PAGE_CACHE=false` is treated as no-op because
     workflow UIs often emit unchecked booleans as `false`. Before changing anything, the engine reads
     `GET /api/show_config` on each BE and only calls `/api/update_config` when
     the current value differs from the requested value.
   - `CLEAR_FILE_CACHE` — authenticated
     `GET /api/file_cache?op=clear&sync=true` on each BE using the benchmark
     `DB_USER` / `PASSWORD`, then poll `brpc_metrics` until every disk's
     `file_cache_cache_size` drops to `CLEAR_FILE_CACHE_MAX_SIZE_GB` or less
     (default 0 GB), timeout `CLEAR_FILE_CACHE_TIMEOUT_MIN` minutes (default 60).
   - `CLEAR_SYS_PAGE_CACHE` — defaults to `CLEAR_SYS_PAGE_CACHE_METHOD=ssh`, which
     runs `sync; echo 3 | sudo tee /proc/sys/vm/drop_caches` as
     `CLEAR_CACHE_SSH_USER` (default `root`). For Yaochi clusters that expose cache
     clearing over HTTP, set `CLEAR_SYS_PAGE_CACHE_METHOD=http`; this calls
     `GET http://<be>:${CLEAR_SYS_PAGE_CACHE_HTTP_PORT:-8050}${CLEAR_SYS_PAGE_CACHE_HTTP_PATH:-/drop_sys_cache}`.
   - `CLEAR_CACHE_SCOPE` controls timing:
     `before_query` clears once after load/analyze and before the query phase;
     `per_query` clears once before each query; `cold` clears before run 1 of
     each query; `every_run` clears before every query run.
   - `COLD_QUERY_COUNT` / `HOT_QUERY_COUNT` enable selectdb-qa style
     cold/hot query execution. Each cold run clears enabled caches first; hot
     runs do not clear cache, and the hot summary uses the minimum hot time.
    Results are saved in the `results` directory under the corresponding path.

### View Results

```bash
make result
```
This generates a static html page `index.html` in the project root directory, which you can open in a browser to view the results.

The generated report supports two views:
- Main benchmark: `index.html`
- Versions benchmark: `index.html?page=versions`

#### HTML Metrics Explanation

The main benchmark page and the versions benchmark page use the same metric definitions.

- `Cold Run`: uses the first recorded execution time of each selected query. The displayed value is the sum of selected query times. Sorting follows this displayed total time, so lower is better.
- `Hot Run`: uses the faster value of the second and third execution time of each selected query, i.e. `min(run2, run3)`. The displayed value is the sum of selected query times. Sorting follows this displayed total time, so lower is better.
- `Load Time`: uses the total load time, i.e. the sum of all values in `results.load.load_times`. Lower is better.
- `Storage Size`: uses `results.load.data_size_bytes`. Lower is better.
- `Combined`: uses a weighted geometric mean of four relative factors: load time, storage size, cold-query score, and hot-query score. The formula is:

```text
combined_raw =
exp(
  0.1 * log(load_time / best_load_time) +
  0.1 * log(data_size / best_data_size) +
  0.2 * log(cold_query_score) +
  0.6 * log(hot_query_score)
)

combined = combined_raw / min(combined_raw among filtered entries)
```

Where:
- `cold_query_score` is the geometric mean of per-query relative cold-run ratios.
- `hot_query_score` is the geometric mean of per-query relative hot-run ratios.
- The weights are `load=0.1`, `size=0.1`, `cold=0.2`, `hot=0.6`.
- After normalization, the best filtered entry is always shown as `×1.00`.

- `QPS`: uses JMeter total throughput, i.e. `throughput`. Higher is better.
- `Successful QPS`: uses `throughput * (1 - errorPct / 100)`. Higher is better.
- `Avg Latency`: uses JMeter `meanResTime`, converted from milliseconds to seconds. Lower is better.
- `P99 Latency`: uses JMeter `pct3ResTime`, converted from milliseconds to seconds. Lower is better.
- `Error %`: uses JMeter `errorPct`. Lower is better.

For all summary rows that display a relative multiplier such as `×1.23`, the multiplier is normalized against the best currently filtered entry for the selected metric.

### Submit Test Results

1. After completing the test, rename the generated `result.json` (e.g., `aws.32C.json`).
2. Place it in the `results` directory of the corresponding test scenario and submit a Pull Request.

### Directory Structure

```
.
├── benchmarks/         # Test scenarios
│   ├── clickbench/     # ClickBench
│   ├── ssb/            # SSB
│   └── tpch/           # TPC-H
├── engines/            # Database test logic
├── lib/                # Common libraries and scripts
├── results/            # Test results (actually under each benchmark directory)
├── scripts/            # Helper scripts
├── Makefile             # Build commands for generating reports
└── benchmark.sh        # Entry for performance testing
```

## Testing Guide

This document details how to conduct performance testing for different databases or query engines, including environment preparation, test set preparation, test execution, result upload, and result presentation.

### Notes

1. Prepare the performance execution environment and the system under test. Try to ensure they are in the same region and VPC; at worst, they should be in the same region to ensure controllable and stable network latency. For single-threaded performance tests, the benchmark machine does not need to be high-spec (2C4G is sufficient). For multi-threaded tests, ensure that the benchmark machine's resource bottleneck does not affect the test results.
2. The benchmark machine needs to have necessary command-line tools installed, such as `yq`, `jq`, `bc`. Install other tools as needed based on the system under test, such as `mysql-client`, `psql`, `clickhouse-client`, etc.
3. Disable all result-cache features on the system under test during testing to ensure the validity of performance data.
4. Ensure that the same test set uses consistent SQL logic and table data across different systems under test for fair comparison.
5. You can directly use the provided test sets. Lakehouse data may not be publicly readable, so you need to prepare test data in advance. There will be a dedicated section later on how to prepare Iceberg datasets.
6. For VeloDB / Doris cloud runs you can explicitly configure Doris page cache through
   `DORIS_PAGE_CACHE_ACTION=configure` plus `DISABLE_DORIS_PAGE_CACHE=true|false`
   and clear BE caches through two independent
   switches: `CLEAR_FILE_CACHE`, `CLEAR_SYS_PAGE_CACHE`.
   `BE_HOSTS` can be provided explicitly as a comma-separated list; when it is
   empty, Doris tries to discover BE / Compute hosts from the FE. `CLEAR_CACHE_SCOPE` controls timing
   (`before_query` = once before the query phase, matching selectdb-qa's default
   clear behavior; `per_query` = once before each query, matching selectdb-qa's
   `clearPerQuery`; `cold` = only before run 1 of each query; `every_run` =
   before every run).
   You can also set `COLD_QUERY_COUNT` and `HOT_QUERY_COUNT` to run the
   selectdb-qa cold/hot model: every cold run clears enabled caches first, hot
   runs do not clear cache, and the hot summary is the minimum hot run.
   `CLEAR_FILE_CACHE` talks to each BE's HTTP API on `BE_HTTP_PORT` (default 8040)
   using the benchmark `DB_USER` / `PASSWORD`, and polls `BE_BRPC_PORT` (default 8060)
   until `file_cache_cache_size` falls to `CLEAR_FILE_CACHE_MAX_SIZE_GB` or less
   (default 0) or `CLEAR_FILE_CACHE_TIMEOUT_MIN` (default 60) elapses.
   `CLEAR_SYS_PAGE_CACHE_METHOD=ssh` by default and SSHes to each BE as
   `CLEAR_CACHE_SSH_USER` (default `root`) to run `drop_caches`. Set
   `CLEAR_SYS_PAGE_CACHE_METHOD=http` for Yaochi-style clusters; it sends
   `GET http://<be>:${CLEAR_SYS_PAGE_CACHE_HTTP_PORT:-8050}${CLEAR_SYS_PAGE_CACHE_HTTP_PATH:-/drop_sys_cache}`.

### Testing Steps

#### Environment Preparation

| System            | Description |
|-------------------|-------------|
| Apache Doris      | Deploy Doris cluster, refer to [official documentation](https://doris.apache.org/docs/4.x/gettingStarted/quick-start); install client tool `mysql-client` |
| Redshift          | Create Redshift cluster, configure node type and count; configure network and security group; install client tool `psql` |
| Snowflake         | Create Snowflake account and warehouse; configure network and security settings; install client tool `snowsql` |
| ClickHouse Cloud  | Create ClickHouse Cloud cluster; configure network and security settings; install client tool `clickhouse-client` |
| BigQuery          | Create Google Cloud project and enable BigQuery API; configure service account and permissions; install client tool `bq` |
| Trino             | Install Trino cluster, refer to [official documentation](https://trino.io/docs/current/installation.html); configure connections to data sources; install client tool `trino-cli`, a [deployment script](docs/iceberg/prepare-env/trino/deploy.sh) is provided |

#### Test Set Preparation

##### ClickBench

Refer to [ClickBench](https://github.com/ClickHouse/ClickBench)

Test set locations:  
S3  
endpoint: https://s3.us-east-1.amazonaws.com  
region: us-east-1  
bucket: bench-dataset  
location: s3://bench-dataset/clickhouse

OSS  
endpoint: https://oss-cn-beijing.aliyuncs.com  
region: oss-cn-beijing  
bucket: bench-dataset  
location: s3://bench-dataset/clickhouse

##### TPC-DS

Test set:  
S3  
endpoint: https://s3.us-east-1.amazonaws.com  
region: us-east-1  
bucket: bench-dataset  
location: s3://bench-dataset/tpcds/sf1000

OSS  
endpoint: https://oss-cn-beijing.aliyuncs.com  
region: oss-cn-beijing  
bucket: bench-dataset  
location: s3://bench-dataset/tpcds/sf1000

Test SQL

| System    | Description |
|-----------|-------------|
| Redshift  | Adjusted based on [aws-samples](https://github.com/aws-samples/redshift-benchmarks/tree/main/load-tpc-ds) |
| Snowflake | Copy Redshift test set and make necessary adjustments |
| ClickHouse| Copy Snowflake test set and make necessary adjustments |
| Trino     | Copy Snowflake test set and make necessary adjustments |

##### TPC-H

Test set:  
S3  
endpoint: https://s3.us-east-1.amazonaws.com  
region: us-east-1  
bucket: bench-dataset  
location: s3://bench-dataset/tpch/sf1000

OSS  
endpoint: https://oss-cn-beijing.aliyuncs.com  
region: oss-cn-beijing  
bucket: bench-dataset  
location: s3://bench-dataset/tpch/sf1000

Test SQL

| System    | Description |
|-----------|-------------|
| Redshift  | Refer to [amazon-redshift-utils](https://github.com/awslabs/amazon-redshift-utils/tree/master/src/CloudDataWarehouseBenchmark/Cloud-DWB-Derived-from-TPCH) |
| Snowflake | Use the same test set and SQL as Redshift |
| ClickHouse| Refer to [ClickHouse TPC-H documentation](https://clickhouse.com/docs/getting-started/example-datasets/tpch) |
| Trino     | Use the same test set and SQL as Snowflake, with necessary adjustments |

##### SSB

Test set:  
S3  
endpoint: https://s3.us-east-1.amazonaws.com  
region: us-east-1  
bucket: bench-dataset  
location: s3://bench-dataset/ssb/sf1000

OSS  
endpoint: https://oss-cn-beijing.aliyuncs.com  
region: oss-cn-beijing  
bucket: bench-dataset  
location: s3://bench-dataset/ssb/sf1000

Test SQL

| System    | Description |
|-----------|-------------|
| Redshift  | Refer to Doris test set and SQL |
| Snowflake | Refer to Doris test set and SQL |
| Trino     | Refer to Doris test set and SQL |
| ClickHouse| Refer to [ClickHouse SSB documentation](https://clickhouse.com/docs/getting-started/example-datasets/star-schema) |

##### Iceberg Parquet/ORC

Use Nessie catalog + Aliyun OSS (S3 compatible).  
Nessie deployment: [docker-compose.yaml](./iceberg/prepare-env/nessie/docker-compose.yaml)

With this combination, Trino will report errors when creating tables and writing data:
```
Caused by: software.amazon.awssdk.services.s3.model.S3Exception: A header you provided implies functionality that is not implemented. (Service: S3, Status Code: 400, Request ID: 693EEB94153DBB3432C97FC5) (SDK Attempt Count: 1)
```
Therefore, export the standard dataset from Doris catalog internal tables to OSS, then both Trino and Doris use this data for performance comparison.

Doris Create catalog statement:
```sql
DROP CATALOG IF EXISTS iceberg_nessie;

CREATE CATALOG `iceberg_nessie` PROPERTIES (
    "warehouse" = "warehouse",
    "uri" = "http://172.20.48.9:19120/iceberg",
    "type" = "iceberg",
    "s3.secret_key" = "${STORAGE_SECRET_KEY}",
    "s3.region" = "cn-beijing",
    "s3.endpoint" = "http://oss-cn-beijing-internal.aliyuncs.com",
    "s3.access_key" = "${STORAGE_ACCESS_KEY}",
    "iceberg.catalog.type" = "rest"
);
```

Doris CTAS:
```sql
-- ckbench
USE clickbench;
CREATE TABLE iceberg_nessie.clickbench_orc.hits PROPERTIES ('write-format'='orc') AS SELECT * FROM hits;
```

#### Test Execution

##### Single-threaded

> **Note**: ClickHouse needs to configure a timeout to avoid queries getting stuck.


##### Multi-threaded

TODO

#### Result Upload

After completing the performance test, upload the generated `result.json` file to the performance dashboard for visualization and analysis.

#### Result Presentation

Once the PR is merged, the results will be automatically displayed on the performance dashboard, making it easy to view and compare the performance of different database systems.


## Result Format

This document describes the structure and content of the `result.json` file, which is used to store benchmark results.

### Naming

It is recommended to name the file by machine type or name, such as `aws.32C.json`.

### Root Object

The root object contains two main keys: `metadata` and `results`.

- `metadata`: Benchmark metadata, such as test environment, system, etc.
- `results`: Actual performance metrics, such as load time, query time, and JMeter test results.

---

### `metadata` Object

| Key            | Type      | Description                                              | Example Value                        |
|----------------|-----------|---------------------------------------------------------|--------------------------------------|
| `system`       | string    | Name of the system under test (e.g., "Doris", "ClickHouse"). | `"Doris"`                            |
| `suite`        | string    | Benchmark suite name (e.g., "ssb", "tpch").              | `"ssb"`                              |
| `scale`        | string    | Scale factor from directory structure (e.g., "sf100").   | `"sf100"`                            |
| `version`      | string    | Version of the system under test.                       | `"3.0"`                              |
| `create_time`  | string    | Test run date, formatted as `YYYY-MM-DD`.               | `"2025-07-21"`                       |
| `machine`      | string    | Machine or cluster specification of the system under test. | `"32C(aws)"`                     |
| `cluster_size` | number    | Number of cluster nodes.                                | `3`                                  |
| `tags`         | string[]  | List of classification tags (e.g., "olap", "mpp", "open-source"). | `["olap", "mpp", "open-source"]`     |

---

### `results` Object

#### `load` Object

| Key               | Type   | Description                                              |
|-------------------|--------|---------------------------------------------------------|
| `load_times`      | object | Each key is a table or file name, value is load time (seconds). E.g., `{ "hits": 366.774 }`. |
| `data_size_bytes` | number | Total loaded data size (bytes). (Optional)              |

#### `query` Object

| Key           | Type   | Description                                              |
|---------------|--------|---------------------------------------------------------|
| `query_times` | object | Each key is a query name, value is a UI-compatible summary array. In custom cold/hot mode this is `[cold_1, hot_min]`; otherwise it contains all legacy `query_times` runs. |
| `query_run_times` | object | Detailed custom cold/hot runs. Each key has `cold`, `hot`, and `hot_min` fields. Empty when custom cold/hot mode is not used. |

#### `jmeter` Object

| Key            | Type  | Description                                             |
|----------------|-------|--------------------------------------------------------|
| `test_results` | array | Contains test results under different configurations, each element represents a complete JMeter test. Can be an empty object. |

##### Test Result Object Structure

Each test result object contains the following fields:

| Key        | Type  | Description                                 |
|------------|-------|---------------------------------------------|
| `config`   | object| Test configuration, including concurrency, execution mode, etc. |
| `queries`  | object| Performance metrics for each query, key is query name, value is metrics object |
| `total`    | object| Overall performance metrics for this test   |

##### Config Object Fields

| Key           | Type    | Description                                         |
|---------------|---------|-----------------------------------------------------|
| `threads`     | number  | Number of concurrent threads                        |
| `consecutive` | boolean | Whether to execute queries sequentially (true=sequential, false=concurrent) |
| `loops`       | number  | Number of loops per query                           |
| `duration`    | number  | Test duration (seconds), 0 means by loop count      |

##### Query Performance Metrics Fields

| Key      | Type   | Description                                | Unit   |
|----------|--------|--------------------------------------------|--------|
| `qps`    | number | Queries Per Second                         | ops/s  |
| `max`    | number | Maximum response time                      | s      |
| `min`    | number | Minimum response time                      | s      |
| `avg`    | number | Average response time                      | s      |
| `99th`   | number | 99th percentile response time              | s      |
| `sample` | number | Number of samples                          | count  |
| `error`  | number | Number of errors                           | count  |

##### Total Performance Metrics Fields

| Key                    | Type   | Description                |
|------------------------|--------|----------------------------|
| `transaction`          | string | Transaction name           |
| `sampleCount`          | number | Number of samples          |
| `errorCount`           | number | Number of errors           |
| `errorPct`             | number | Error rate                 |
| `meanResTime`          | number | Mean response time         |
| `medianResTime`        | number | Median response time       |
| `minResTime`           | number | Minimum response time      |
| `maxResTime`           | number | Maximum response time      |
| `pct1ResTime`          | number | 90th percentile response time |
| `pct2ResTime`          | number | 95th percentile response time |
| `pct3ResTime`          | number | 99th percentile response time |
| `throughput`           | number | Throughput                 |
| `receivedKBytesPerSec` | number | Received KB per second     |
| `sentKBytesPerSec`     | number | Sent KB per second         |

---

### Complete Example

```json
{
   "metadata": {
      "system": "Apache Doris",
      "version": "4.0.2",
      "create_time": "2025-12-22",
      "machine": "32C(Alibaba Cloud)",
      "cluster_size": 3,
      "tags": [
         "benchmark",
         "doris"
      ]
    },
   "results": {
      "load": {
         "load_times": {
            "hits": 864.489
         },
         "data_size_bytes": 0
      },
      "query": {
         "query_times": {
            "q1": [0.067, 0.058, 0.05],
            "q2": [0.064, 0.043, 0.062]
         },
         "query_run_times": {
            "q1": { "cold": [0.067], "hot": [0.058, 0.05], "hot_min": 0.05 }
         }
      },
      "jmeter": {
         "test_results": [
            {
               "config": {
                  "threads": 1,
                  "consecutive": true,
                  "loops": 1,
                  "duration": 0
               },
               "queries": {
                  "q1": {
                     "qps": 1.6286644951140066,
                     "avg": 0.614,
                     "min": 0.614,
                     "max": 0.614,
                     "99th": 0.614,
                     "sample": 1,
                     "error": 0
                  }
               },
               "total": {
                  "transaction": "Total",
                  "sampleCount": 43,
                  "errorCount": 0,
                  "errorPct": 0,
                  "meanResTime": 1855.4651162790692,
                  "medianResTime": 503,
                  "minResTime": 115,
                  "maxResTime": 35387,
                  "pct1ResTime": 2769,
                  "pct2ResTime": 8086.399999999982,
                  "pct3ResTime": 35387,
                  "throughput": 0.5383681185912284,
                  "receivedKBytesPerSec": 0.4025045072679696,
                  "sentKBytesPerSec": 0
               }
            }
         ]
      }
   }
}
```




## Contributing

We welcome contributions of all forms, including but not limited to:

*   Submitting new test results
*   Adding support for new databases
*   Improving and optimizing test scripts
*   Enhancing the report display interface

If you have any questions or suggestions, please feel free to communicate with us via Issues.
