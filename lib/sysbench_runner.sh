#!/bin/bash

if ! declare -f to_lower >/dev/null 2>&1; then
    source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common_utils.sh"
fi

get_sysbench_config() {
    local key="$1"
    local default_value="$2"
    local raw_value
    local value

    local env_var
    env_var="SYSBENCH_$(printf '%s' "$key" | tr '[:lower:]' '[:upper:]')"
    if [ "$key" = "enabled" ]; then
        env_var="SYSBENCH"
    fi

    raw_value=$(yq eval ".sysbench.${key} // \"\" | tostring" "$CONFIG_FILE")
    if [ -n "$raw_value" ]; then
        value="$raw_value"
    else
        value="${!env_var:-$default_value}"
    fi
    eval "printf '%s' \"$value\""
}

resolve_sysbench_test() {
    local configured_test="$1"
    local candidate

    if [[ "$configured_test" == /* ]]; then
        printf '%s\n' "$configured_test"
        return 0
    fi

    for candidate in         "$TEST_ROOT/$configured_test"         "$TEST_ROOT/$configured_test.lua"         "${SYSBENCH_SHARE_DIR:-}/$configured_test"         "${SYSBENCH_SHARE_DIR:-}/$configured_test.lua"; do
        if [ -n "$candidate" ] && [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    printf '%s\n' "$configured_test"
}

ensure_sysbench_database() {
    echo "  Ensuring database $db exists..."

    if ! command -v mysql >/dev/null 2>&1; then
        echo "Warning: mysql client not found, skipping explicit database creation."
        return 0
    fi

    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -e "CREATE DATABASE IF NOT EXISTS \`$db\`"         || echo "Warning: Failed to ensure database exists, attempting to proceed..."
}

extract_sysbench_metrics() {
    local log_file="$1"
    local output_file="$RESULT_DIR/sysbench_metrics.json"
    local test_name="$2"
    local tables="$3"
    local table_size="$4"
    local threads="$5"
    local time_s="$6"
    local report_interval="$7"
    local tps=0
    local qps=0
    local total_time_s=0
    local total_events=0
    local latency_min_ms=0
    local latency_avg_ms=0
    local latency_max_ms=0
    local latency_p95_ms=0

    echo "  Extracting metrics from $log_file..."

    eval "$(awk '
        /transactions:/ {
            value=$3
            gsub(/[()]/, "", value)
            print "tps=" value
        }
        /queries:/ {
            value=$3
            gsub(/[()]/, "", value)
            print "qps=" value
        }
        /total time:/ {
            value=$3
            sub(/s$/, "", value)
            print "total_time_s=" value
        }
        /total number of events:/ {
            print "total_events=" $5
        }
        /^[[:space:]]*min:/ {
            print "latency_min_ms=" $2
        }
        /^[[:space:]]*avg:/ {
            print "latency_avg_ms=" $2
        }
        /^[[:space:]]*max:/ {
            print "latency_max_ms=" $2
        }
        /95th percentile:/ {
            print "latency_p95_ms=" $3
        }
    ' "$log_file")"

    jq -n         --arg test_name "$test_name"         --argjson tables "$tables"         --argjson table_size "$table_size"         --argjson threads "$threads"         --argjson time_s "$time_s"         --argjson report_interval_s "$report_interval"         --argjson tps "$tps"         --argjson qps "$qps"         --argjson total_time_s "$total_time_s"         --argjson total_events "$total_events"         --argjson latency_min_ms "$latency_min_ms"         --argjson latency_avg_ms "$latency_avg_ms"         --argjson latency_max_ms "$latency_max_ms"         --argjson latency_p95_ms "$latency_p95_ms"         '{
          config: {
            test_name: $test_name,
            tables: $tables,
            table_size: $table_size,
            threads: $threads,
            time_s: $time_s,
            report_interval_s: $report_interval_s
          },
          performance: {
            tps: $tps,
            qps: $qps,
            total_time_s: $total_time_s,
            total_events: $total_events,
            latency_ms: {
              min: $latency_min_ms,
              avg: $latency_avg_ms,
              max: $latency_max_ms,
              p95: $latency_p95_ms
            }
          }
        }' > "$output_file"
}

execute_sysbench_task() {
    echo "==== Starting Sysbench Phase ===="

    local enabled
    enabled="$(get_sysbench_config enabled false)"
    if [[ "$(to_lower "$enabled")" != "true" ]]; then
        echo "Sysbench not enabled, skipping."
        return 0
    fi

    local sysbench_cmd="${SYSBENCH_CMD:-sysbench}"
    if [ ! -x "$sysbench_cmd" ] && ! command -v "$sysbench_cmd" >/dev/null 2>&1; then
        echo "ERROR: sysbench executable not available. Run init_sysbench first." >&2
        return 1
    fi

    local test_name
    local tables
    local table_size
    local threads
    local time_s
    local report_interval
    local run_prepare
    local run_benchmark
    local run_cleanup
    local query_enabled

    test_name="$(resolve_sysbench_test "$(get_sysbench_config test_name oltp_read_only)")"
    tables="$(get_sysbench_config tables 8)"
    table_size="$(get_sysbench_config table_size 30000000)"
    threads="$(get_sysbench_config threads 32)"
    time_s="$(get_sysbench_config time 20)"
    report_interval="$(get_sysbench_config report_interval 1)"
    run_prepare="$(get_sysbench_config prepare false)"
    run_benchmark="$(get_sysbench_config run true)"
    run_cleanup="$(get_sysbench_config cleanup false)"
    query_enabled="${query:-false}"

    echo "  Running test: $test_name"
    ensure_sysbench_database

    if [[ "$(to_lower "$query_enabled")" != "true" ]]; then
        echo "  Sysbench query phase disabled, skipping run."
        run_benchmark="false"
    fi

    local -a common_args=(
        "--db-driver=mysql"
        "--mysql-host=${fe_host}"
        "--mysql-port=${fe_query_port}"
        "--mysql-user=${user}"
        "--mysql-db=${db}"
        "--tables=${tables}"
        "--table-size=${table_size}"
        "--threads=${threads}"
        "--db-ps-mode=disable"
        "--skip-trx=on"
    )
    if [ -n "${password:-}" ]; then
        common_args+=("--mysql-password=$password")
    fi

    if [[ "$(to_lower "$run_prepare")" == "true" ]]; then
        echo "  [Sysbench] prepare phase..."
        "$sysbench_cmd" "$test_name" "${common_args[@]}" prepare
    fi

    if [[ "$(to_lower "$run_benchmark")" == "true" ]]; then
        local log_file="$RESULT_DIR/sysbench.log"
        echo "  [Sysbench] run phase..."
        if ! "$sysbench_cmd" "$test_name" "${common_args[@]}"             "--time=${time_s}"             "--report-interval=${report_interval}"             run 2>&1 | tee "$log_file"; then
            echo "ERROR: Sysbench run failed." >&2
            return 1
        fi

        extract_sysbench_metrics "$log_file" "$test_name" "$tables" "$table_size" "$threads" "$time_s" "$report_interval"

        if declare -f engine_get_data_size_bytes >/dev/null 2>&1; then
            sleep 5
            engine_get_data_size_bytes 2>/dev/null > "$RESULT_DIR/data_size_bytes" || echo "0" > "$RESULT_DIR/data_size_bytes"
        fi
    fi

    if [[ "$(to_lower "$run_cleanup")" == "true" ]]; then
        echo "  [Sysbench] cleanup phase..."
        "$sysbench_cmd" "$test_name" "${common_args[@]}" cleanup
    fi

    echo "==== Sysbench Phase Completed ===="
}
