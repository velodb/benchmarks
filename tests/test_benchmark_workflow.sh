#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local value="$1"
    local expected="$2"
    [[ "$value" == *"$expected"* ]] || fail "expected '$expected' in '$value'"
}

assert_not_contains() {
    local value="$1"
    local unexpected="$2"
    [[ "$value" != *"$unexpected"* ]] || fail "unexpected '$unexpected' in '$value'"
}

test_load_config_uses_ddl_path() {
    (
        source "$ROOT_DIR/benchmark.sh"
        CONFIG_FILE="$TEST_DIR/load-config.yaml"
        TEST_ROOT="$TEST_DIR"
        RESULT_DIR="$TEST_DIR/result"
        mkdir -p "$RESULT_DIR"
        cat > "$CONFIG_FILE" <<'YAML'
engine:
  connection:
    host: 127.0.0.1
parameters:
  ddl: "true"
  load: "false"
paths:
  ddl: "ddl/custom.sql"
YAML
        load_config >/dev/null
        [ "$DDL" = "ddl/custom.sql" ] || fail "DDL path was not loaded"
    )
}

test_run_ddl_skips_database_creation_for_trino() {
    (
        source "$ROOT_DIR/benchmark.sh"
        ENGINE_TYPE="trino"
        TEST_ROOT="$TEST_DIR/ddl"
        mkdir -p "$TEST_ROOT/ddl"
        printf 'SELECT 1;\n' > "$TEST_ROOT/ddl/ddl.sql"
        DDL="ddl/ddl.sql"
        local_calls=""
        engine_create_database() {
            local_calls="${local_calls}create;"
        }
        engine_run_sql_file() {
            local_calls="${local_calls}sql:$1;"
        }
        run_ddl >/dev/null
        assert_not_contains "$local_calls" "create;"
        assert_contains "$local_calls" "sql:"
    )
}

test_run_ddl_prefers_engine_specific_ddl_runner() {
    (
        source "$ROOT_DIR/benchmark.sh"
        ENGINE_TYPE="clickhouse"
        TEST_ROOT="$TEST_DIR/ddl-engine"
        mkdir -p "$TEST_ROOT/ddl"
        printf 'SELECT 1;\n' > "$TEST_ROOT/ddl/ddl.sql"
        DDL="ddl/ddl.sql"
        local_calls=""
        engine_create_database() {
            local_calls="${local_calls}create;"
        }
        engine_run_sql_file() {
            local_calls="${local_calls}generic;"
        }
        engine_run_ddl_file() {
            local_calls="${local_calls}engine;"
        }
        run_ddl >/dev/null
        assert_contains "$local_calls" "create;"
        assert_contains "$local_calls" "engine;"
        assert_not_contains "$local_calls" "generic;"
    )
}

test_run_analyze_falls_back_when_builtin_is_unsupported() {
    (
        source "$ROOT_DIR/benchmark.sh"
        local_calls=""
        run_builtin_analyze() {
            return 2
        }
        run_analyze_with_sql_file() {
            local_calls="fallback"
        }
        run_analyze >/dev/null
        [ "$local_calls" = "fallback" ] || fail "analyze fallback was not called"
    )
}

test_trino_builtin_analyze_runs_tables() {
    (
        source "$ROOT_DIR/benchmark.sh"
        ENGINE_TYPE="trino"
        db="tpch_sf1000_parquet"
        analyze_type="analyze_full"
        RESULT_DIR="$TEST_DIR/trino-analyze"
        mkdir -p "$RESULT_DIR"
        analyze_calls_file="$TEST_DIR/trino-analyze-calls"
        : > "$analyze_calls_file"
        sleep() { :; }
        engine_list_tables() {
            printf 'lineitem\norders\nregion\n'
        }
        engine_drop_stats() {
            return 0
        }
        engine_analyze_table() {
            printf '%s/%s/%s;' "$1" "$2" "$3" >> "$analyze_calls_file"
        }
        run_builtin_analyze >/dev/null
        analyze_calls="$(cat "$analyze_calls_file")"
        [ "$analyze_calls" = \
            "tpch_sf1000_parquet/lineitem/analyze_full;tpch_sf1000_parquet/orders/analyze_full;tpch_sf1000_parquet/region/analyze_full;" ] \
            || fail "unexpected Trino analyze calls: $analyze_calls"
        [ -s "$RESULT_DIR/analyze.csv" ] || fail "Trino analyze.csv missing"
    )
}

test_trino_analyze_rejects_sample() {
    (
        source "$ROOT_DIR/benchmark.sh"
        ENGINE_TYPE="trino"
        db="tpch_sf1000_parquet"
        analyze_type="analyze_sample"
        set +e
        run_builtin_analyze >/dev/null 2>&1
        local rc=$?
        set -e
        [ "$rc" -eq 2 ] || fail "expected Trino sample analyze rc=2, got $rc"
    )
}

test_trino_engine_lists_and_analyzes_tables() {
    (
        source "$ROOT_DIR/engines/trino_engine.sh"
        local fake_log="$TEST_DIR/trino-cli.log"
        : > "$fake_log"
        host="127.0.0.1"
        port="8080"
        user="trino"
        password=""
        catalog="iceberg"
        schema="tpch_sf1000_parquet"
        trino-cli() {
            printf '%s\n' "$*" >> "$fake_log"
            case "$*" in
                *"SELECT table_name"*)
                    printf 'lineitem\norders\n'
                    ;;
                *"SELECT count(*)"*)
                    printf '100\n'
                    ;;
            esac
        }

        tables="$(engine_list_tables "$schema")"
        [ "$tables" = $'lineitem\norders' ] || fail "unexpected Trino tables: $tables"
        rows="$(engine_get_table_rows "lineitem")"
        [ "$rows" = "100" ] || fail "unexpected Trino row count: $rows"
        engine_analyze_table "$schema" "lineitem" "analyze_full" >/dev/null
        grep -Fq -- "SELECT table_name FROM information_schema.tables" "$fake_log" \
            || fail "Trino table discovery query missing"
        grep -Fq -- "ANALYZE iceberg.tpch_sf1000_parquet.lineitem" "$fake_log" \
            || fail "Trino ANALYZE query missing"
        grep -Fq -- "SELECT count(*) FROM iceberg.tpch_sf1000_parquet.lineitem" "$fake_log" \
            || fail "Trino row count query missing"
        if grep -Fq -- "--no-header" "$fake_log"; then
            fail "Trino 484 does not support --no-header"
        fi
    )
}

test_clickhouse_ddl_fans_out_to_cluster_workers() {
    (
        source "$ROOT_DIR/engines/clickhouse_engine.sh"
        local fake_cli="$TEST_DIR/clickhouse"
        local fake_log="$TEST_DIR/clickhouse.log"
        cat > "$fake_cli" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_CLICKHOUSE_LOG"
case "$*" in
    *--query=*)
        printf '10.0.0.2\n10.0.0.3\n'
        ;;
esac
if [[ "$*" == *--multiquery* ]]; then
    cat >/dev/null
fi
SH
        chmod +x "$fake_cli"
        export FAKE_CLICKHOUSE_LOG="$fake_log"
        CLICKHOUSE_CMD="$fake_cli"
        clickhouse_host="10.0.0.1"
        user="default"
        password=""
        db="default"
        ddl_cluster="perf_cluster"
        printf 'SELECT 1;\n' > "$TEST_DIR/ddl.sql"
        engine_run_ddl_file "$TEST_DIR/ddl.sql" >/dev/null
        local count
        count="$(grep -c -- '--multiquery' "$fake_log")"
        [ "$count" -eq 3 ] || fail "expected 3 ClickHouse DDL targets, got $count"
        grep -q -- '--host=10.0.0.1' "$fake_log" || fail "coordinator DDL missing"
        grep -q -- '--host=10.0.0.2' "$fake_log" || fail "worker 2 DDL missing"
        grep -q -- '--host=10.0.0.3' "$fake_log" || fail "worker 3 DDL missing"

        : > "$fake_log"
        ddl_cluster=""
        engine_run_ddl_file "$TEST_DIR/ddl.sql" >/dev/null
        count="$(grep -c -- '--multiquery' "$fake_log")"
        [ "$count" -eq 1 ] || fail "expected coordinator-only DDL, got $count targets"
    )
}

test_load_config_uses_ddl_path
test_run_ddl_skips_database_creation_for_trino
test_run_ddl_prefers_engine_specific_ddl_runner
test_run_analyze_falls_back_when_builtin_is_unsupported
test_trino_builtin_analyze_runs_tables
test_trino_analyze_rejects_sample
test_trino_engine_lists_and_analyzes_tables
test_clickhouse_ddl_fans_out_to_cluster_workers

echo "All benchmark workflow tests passed."
