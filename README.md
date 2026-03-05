# VeloDB Benchmarks

[![License](https://img.shields.io/badge/license-Apache--2.0-green)](./LICENSE)

**[benchmarks.velodb.com](https://benchmarks.velodb.com)**
An open, reproducible, and community-driven database benchmark project.

---

For a long time, database benchmarking has been dominated by organizations like TPC. While their standards are respected, they often lack code-level transparency. This has created a situation of "authoritative but distant," where users can trust the final numbers but cannot easily verify or understand the entire process behind them.

Inspired by the rise of open-source databases and modern platforms like [ClickBench](https://benchmark.clickhouse.com/) and [db-benchmarks](https://db-benchmarks.com/), this project aims to embrace a new paradigm centered on openness, continuous integration, and reproducibility.

Our goal is to build `benchmarks.velodb.com` into the industry's most trusted and impartial resource for performance evaluation. Every architectural decision for the platform is measured by whether it enhances transparency, reproducibility, and fairness.

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
- yq, jq, bc
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
    Results are saved in the `results` directory under the corresponding path.

### View Results

```bash
make result
```
This generates a static html page `index.html` in the project root directory, which you can open in a browser to view the results.

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
us-east-1  
s3://bench-dataset/clickhouse

OSS  
oss-cn-beijing  
s3://bench-dataset/clickhouse

##### TPC-DS

Test set:  
S3  
us-east-1  
s3://bench-dataset/tpcds/sf1000

OSS  
oss-cn-beijing  
s3://bench-dataset/tpcds/sf1000

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
us-east-1  
s3://bench-dataset/tpch/sf1000

OSS  
oss-cn-beijing  
s3://bench-dataset/tpch/sf1000

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
us-east-1  
s3://bench-dataset/ssb/sf1000

OSS  
oss-cn-beijing  
s3://bench-dataset/ssb/sf1000

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
    "s3.secret_key" = "*XXX",
    "s3.region" = "cn-beijing",
    "s3.endpoint" = "http://oss-cn-beijing-internal.aliyuncs.com",
    "s3.access_key" = "*XXX",
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
| `query_times` | object | Each key is a query name, value is an array of execution times (seconds). E.g., `"q1": [0.067, 0.058, 0.05]`. |

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
      "version": "4.0.2-rc02-30d2df0459",
      "create_time": "2025-12-22",
      "machine": "32C(aliyun)",
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
