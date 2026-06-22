#!/bin/bash
# Central Benchmark Orchestrator (V6)
#
# This script serves as the central coordinator for database benchmark tests.
# It follows the V6 framework design that separates orchestration from
# database-specific implementations.
#
# Usage: ./benchmark.sh --config path/to/benchmark.yaml

set -euo pipefail

# Global variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/lib"
CONFIG_FILE=""
TEST_ROOT=""
ENGINE_TYPE=""
RESULT_DIR=""
TIMESTAMP=""
LAST_TEMP_FILE=""
STACK_TRACE_MONITOR_PID=""
STACK_TRACE_MONITOR_DIR=""
STACK_TRACE_MONITOR_ARCHIVE=""
STACK_TRACE_MONITOR_STARTED="false"
STACK_TRACE_MONITOR_FINALIZED="false"

create_temp_sql_file() {
    local prefix="$1"
    local safe_prefix
    local tmp_file
    safe_prefix="${prefix//[^a-zA-Z0-9_.-]/_}"
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/bench_${safe_prefix}.XXXXXX.sql")" || die "Failed to create temporary file"
    LAST_TEMP_FILE="$tmp_file"
}

# Load modular components
source "$SCRIPT_DIR/lib/tools_utils.sh"
source "$SCRIPT_DIR/lib/jmx_generator.sh"
source "$SCRIPT_DIR/lib/result.sh"

# Print usage information
usage() {
    cat << EOF
Usage: $0 --config <path-to-benchmark.yaml>
       $0 -c <path-to-benchmark.yaml>

Central benchmark orchestrator for database performance testing.

Options:
  -c, --config FILE    Path to benchmark.yaml configuration file
  --help               Show this help message

Example:
  $0 --config benchmarks/ssb/sf100/snowflake/benchmark.yaml

EOF
}

# Die with error message
die() {
    echo "ERROR: $1" >&2
    exit 1
}

is_sysbench_enabled() {
    [[ "$(yq eval '.sysbench.enabled // "false"' "$CONFIG_FILE")" == "true" ]]
}

# Check dependencies
# TODO(zgx): move this function to lib dir and install all dependencies
check_dependencies() {
    echo "Checking dependencies..."
    local cmds=("jq" "bc" "yq" "envsubst" "mktemp")
    local missing_deps=()
    for cmd in "${cmds[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        die "Missing required dependencies: ${missing_deps[*]}. Please install them and try again."
    fi
    
    # Initialize JMeter tools if JMeter is enabled
    if [[ "${jmeter:-}" == "true" ]]; then
        init_java_env
        init_jmeter_tools
    fi

    if [[ "${vectordbbench,,}" == "true" ]] && ! init_vectordbbench; then
        die "Failed to initialize VectorDBBench"
    fi

    if is_sysbench_enabled; then
        init_sysbench
    fi
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -c|--config)
                CONFIG_FILE="$2"
                shift 2
            ;;
            --help)
                usage
                exit 0
            ;;
            *)
                echo "ERROR: Unknown option: $1" >&2
                usage
                exit 1
            ;;
        esac
    done
    
    if [ -z "$CONFIG_FILE" ]; then
        echo "ERROR: Missing required --config argument" >&2
        usage
        exit 1
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        die "Configuration file not found: $CONFIG_FILE"
    fi
    
    # Convert to absolute path
    CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
    echo "Configuration: $CONFIG_FILE"
}

# Initialize test environment
initialize_test() {
    # Extract test root directory and engine type from config path
    TEST_ROOT="$(dirname "$CONFIG_FILE")"
    ENGINE_TYPE="$(yq eval '.engine.type' "$CONFIG_FILE")"
    echo "Engine: $ENGINE_TYPE"
    
    # Extract benchmark name and scale factor from directory structure
    # Expected path:
    #   - benchmarks/<benchmark>/<scale>/<database>/benchmark.yaml
    #   - benchmarks/<benchmark>/<database>/benchmark.yaml (no scale)
    local benchmark_name=""
    local scale_factor=""
    local database_name=""
    database_name="$(basename "$TEST_ROOT")"
    local benchmarks_dir="$SCRIPT_DIR/benchmarks"
    if [[ "$TEST_ROOT" == "$benchmarks_dir/"* ]]; then
        local relative="${TEST_ROOT#$benchmarks_dir/}"
        IFS='/' read -r -a parts <<< "$relative"
        if [ "${#parts[@]}" -ge 3 ]; then
            benchmark_name="${parts[0]}"
            scale_factor="${parts[1]}"
            database_name="${parts[2]}"
        elif [ "${#parts[@]}" -ge 2 ]; then
            benchmark_name="${parts[0]}"
            scale_factor="default"
            database_name="${parts[1]}"
        fi
    fi
    if [ -z "$benchmark_name" ]; then
        scale_factor="$(basename "$(dirname "$TEST_ROOT")")"
        benchmark_name="$(basename "$(dirname "$(dirname "$TEST_ROOT")")")"
    fi
    scale_factor="${scale_factor:-default}"
    # Expose suite/scale for result.json metadata
    SUITE_NAME="$benchmark_name"
    SCALE_FACTOR="$scale_factor"
    export SUITE_NAME SCALE_FACTOR
    echo "Benchmark: $benchmark_name (scale: $scale_factor, database: $database_name)"
    
    # Create timestamped results directory.
    # Prefer the config directory name so paths like
    # benchmarks/tpcds/sf1000/doris_hive/benchmark.yaml map to
    # results/tpcds_sf1000_doris_hive_<timestamp>.
    TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    export TIMESTAMP
    RESULT_DIR="$SCRIPT_DIR/results/${benchmark_name}_${scale_factor}_${database_name}_${TIMESTAMP}"
    mkdir -p "$RESULT_DIR"
    
    echo "Results: $RESULT_DIR"
    
    # Copy configuration to results for reference
    cp "$CONFIG_FILE" "$RESULT_DIR/benchmark.yaml"
}

# Load and validate YAML configuration
load_config() {
    echo "Loading configuration..."

    # Validate YAML syntax
    if ! yq eval '.' "$CONFIG_FILE" >/dev/null 2>&1; then
        die "Invalid YAML syntax in configuration file: $CONFIG_FILE"
    fi

    # Export connection and parameters
    for section in "engine.connection" "parameters"; do
        while IFS='=' read -r key value; do
            [ -n "$key" ] && [ -n "$value" ] && export "$key=$(eval echo "$value")"
        done < <(yq eval ".$section // {} | to_entries | .[] | .key + \"=\" + .value" "$CONFIG_FILE")
    done

    # Export paths (scalar values only)
    for key in ddl load_dir query_mode session_file analyze_file query_dir; do
        value=$(yq eval ".paths.$key // \"\"" "$CONFIG_FILE")
        if [ -n "$value" ] && [ "$value" != "null" ]; then
            # Convert key to uppercase for env var name
            env_var=$(echo "$key" | tr '[:lower:]' '[:upper:]')
            export "$env_var=$(eval echo "$value")"
        fi
    done

    # Set TEST_ROOT for engine access
    export TEST_ROOT
    export RESULT_DIR
}

# Load storage configuration from benchmark.yaml
# Each benchmark.yaml contains its own storage config (endpoint, region, bucket).
# All fields support environment variable overrides via ${VAR:-default} syntax.
load_storage_config() {
    echo "Loading storage configuration..."

    # 1. Check if storage config exists in benchmark.yaml
    local has_storage
    has_storage=$(yq eval '.storage // ""' "$CONFIG_FILE")
    if [ -z "$has_storage" ] || [ "$has_storage" = "null" ]; then
        echo "No storage configuration found in benchmark.yaml, skipping."
        return 0
    fi

    # 2. Read each field from benchmark.yaml and expand env vars via eval echo
    local raw_endpoint raw_region raw_bucket raw_access_key raw_secret_key
    raw_endpoint=$(yq eval '.storage.endpoint // ""' "$CONFIG_FILE")
    raw_region=$(yq eval '.storage.region // ""' "$CONFIG_FILE")
    raw_bucket=$(yq eval '.storage.bucket // ""' "$CONFIG_FILE")
    raw_access_key=$(yq eval '.storage.access_key // ""' "$CONFIG_FILE")
    raw_secret_key=$(yq eval '.storage.secret_key // ""' "$CONFIG_FILE")

    # Expand environment variables (e.g., ${STORAGE_ENDPOINT:-https://...})
    export STORAGE_ENDPOINT=$(eval echo "$raw_endpoint")
    export STORAGE_REGION=$(eval echo "$raw_region")
    export STORAGE_BUCKET=$(eval echo "$raw_bucket")
    export STORAGE_ACCESS_KEY=$(eval echo "$raw_access_key")
    export STORAGE_SECRET_KEY=$(eval echo "$raw_secret_key")

    echo "Storage: endpoint=$STORAGE_ENDPOINT bucket=$STORAGE_BUCKET"
}

sanitize_stack_trace_path_component() {
    local value="$1"
    value="${value//[^a-zA-Z0-9_.-]/_}"
    if [ -z "$value" ]; then
        value="unknown"
    fi
    printf '%s' "$value"
}

list_stack_trace_be_hosts() {
    local raw="${be_hosts:-}"
    local host
    local -a stack_trace_hosts=()
    [ -z "$raw" ] && return 0

    IFS=',' read -r -a stack_trace_hosts <<< "$raw"
    for host in "${stack_trace_hosts[@]}"; do
        host="$(echo "$host" | xargs)"
        [ -n "$host" ] && printf '%s\n' "$host"
    done
}

ensure_stack_trace_be_hosts() {
    if [ -n "${be_hosts:-}" ]; then
        return 0
    fi

    if type -t discover_be_hosts_from_fe >/dev/null 2>&1; then
        echo "be_hosts is empty; discovering BE hosts for stack trace monitor..."
        if ! discover_be_hosts_from_fe; then
            echo "WARNING: failed to discover BE hosts; stack trace monitor will be skipped." >&2
            return 1
        fi
    fi

    [ -n "${be_hosts:-}" ]
}

collect_stack_trace_once() {
    local trace_dir="${STACK_TRACE_MONITOR_DIR:-${RESULT_DIR}/stack_trace}"
    local timestamp
    local host
    local port="${be_http_port:-8040}"
    local timeout="${stack_trace_curl_timeout_seconds:-${STACK_TRACE_CURL_TIMEOUT_SECONDS:-30}}"
    local auth_user="${user:-root}"
    local auth_password="${password:-}"

    if [ -z "${RESULT_DIR:-}" ]; then
        echo "WARNING: RESULT_DIR is empty; skipping stack trace collection." >&2
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "WARNING: curl not found; skipping stack trace collection." >&2
        return 0
    fi

    STACK_TRACE_MONITOR_DIR="$trace_dir"
    mkdir -p "$trace_dir"
    timestamp="$(date '+%Y%m%d_%H%M%S')"

    while IFS= read -r host; do
        local safe_host node_dir output_file error_file url status
        safe_host="$(sanitize_stack_trace_path_component "$host")"
        node_dir="$trace_dir/$safe_host"
        output_file="$node_dir/${timestamp}.txt"
        error_file="$(mktemp "${TMPDIR:-/tmp}/stack_trace_curl.XXXXXX")" || {
            echo "WARNING: failed to create stack trace curl stderr file." >&2
            return 0
        }
        url="http://${host}:${port}/api/stack_trace"

        mkdir -p "$node_dir"
        {
            printf 'timestamp=%s\n' "$timestamp"
            printf 'be_host=%s\n' "$host"
            printf 'url=%s\n\n' "$url"
        } > "$output_file"

        status=0
        if curl -fsS --max-time "$timeout" -u "${auth_user}:${auth_password}" "$url" >> "$output_file" 2>"$error_file"; then
            :
        else
            status=$?
            {
                printf '\nERROR: stack trace fetch failed for %s\n' "$host"
                printf 'curl_exit_code=%s\n' "$status"
                if [ -s "$error_file" ]; then
                    printf '\n--- curl stderr ---\n'
                    sed -e 's/[[:cntrl:]]//g' "$error_file"
                fi
            } >> "$output_file"
        fi
        rm -f "$error_file"
    done < <(list_stack_trace_be_hosts)

    return 0
}

start_stack_trace_monitor() {
    local interval="${stack_trace_interval_seconds:-${STACK_TRACE_INTERVAL_SECONDS:-120}}"
    local host_count=0

    if [[ "${stack_trace_monitor:-true}" != "true" ]]; then
        echo "Stack trace monitor disabled, skipping"
        return 0
    fi

    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
        echo "WARNING: invalid stack_trace_interval_seconds=${interval}; using 120." >&2
        interval=120
    fi
    stack_trace_interval_seconds="$interval"

    if ! ensure_stack_trace_be_hosts; then
        return 0
    fi

    host_count=$(list_stack_trace_be_hosts | wc -l | xargs)
    if [ "$host_count" -eq 0 ]; then
        echo "WARNING: no BE hosts configured; stack trace monitor will be skipped." >&2
        return 0
    fi

    STACK_TRACE_MONITOR_DIR="${RESULT_DIR}/stack_trace"
    mkdir -p "$STACK_TRACE_MONITOR_DIR"

    echo "Starting BE stack trace monitor: ${host_count} hosts, interval=${interval}s, port=${be_http_port:-8040}"
    (
        while :; do
            collect_stack_trace_once || true
            sleep "$interval" || break
        done
    ) &
    STACK_TRACE_MONITOR_PID="$!"
    STACK_TRACE_MONITOR_STARTED="true"
}

stop_stack_trace_monitor() {
    if [[ "${STACK_TRACE_MONITOR_STARTED:-false}" != "true" || -z "${STACK_TRACE_MONITOR_PID:-}" ]]; then
        return 0
    fi

    if kill -0 "$STACK_TRACE_MONITOR_PID" >/dev/null 2>&1; then
        echo "Stopping BE stack trace monitor..."
        kill "$STACK_TRACE_MONITOR_PID" >/dev/null 2>&1 || true
        wait "$STACK_TRACE_MONITOR_PID" 2>/dev/null || true
    fi

    STACK_TRACE_MONITOR_PID=""
    STACK_TRACE_MONITOR_STARTED="false"
    return 0
}

generate_stack_trace_upload_uid() {
    if [ -n "${STACK_TRACE_UPLOAD_UID:-}" ]; then
        printf '%s' "$STACK_TRACE_UPLOAD_UID"
        return 0
    fi

    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import uuid; print(uuid.uuid4())'
    else
        printf '%s-%s\n' "$(date '+%Y%m%d%H%M%S')" "$$"
    fi
}

upload_stack_trace_archive() {
    local archive_path="$1"
    local upload_enabled="${stack_trace_upload:-${STACK_TRACE_UPLOAD:-true}}"
    local upload_enabled_lower
    local endpoint="${file_server_endpoint:-${FILE_SERVER_ENDPOINT:-http://justtmp.oss-cn-beijing.aliyuncs.com}}"
    local path_prefix="${stack_trace_file_server_prefix:-${STACK_TRACE_FILE_SERVER_PREFIX:-rqg-abtest/case_result}}"
    local content_type="${stack_trace_upload_content_type:-${STACK_TRACE_UPLOAD_CONTENT_TYPE:-application/gzip}}"
    local timeout="${stack_trace_upload_timeout_seconds:-${STACK_TRACE_UPLOAD_TIMEOUT_SECONDS:-30}}"
    local uid filename upload_url public_url

    upload_enabled_lower="$(printf '%s' "$upload_enabled" | tr '[:upper:]' '[:lower:]')"
    if [[ "$upload_enabled_lower" != "true" ]]; then
        echo "Stack trace archive upload disabled, keeping local archive: $archive_path"
        return 0
    fi

    if ! command -v curl >/dev/null 2>&1; then
        echo "WARNING: curl not found; stack trace archive kept local: $archive_path" >&2
        return 0
    fi

    if ! [[ "$timeout" =~ ^[0-9]+$ ]] || [ "$timeout" -le 0 ]; then
        echo "WARNING: invalid stack_trace_upload_timeout_seconds=${timeout}; using 30." >&2
        timeout=30
    fi

    endpoint="${endpoint%/}"
    path_prefix="${path_prefix#/}"
    path_prefix="${path_prefix%/}"
    uid="$(generate_stack_trace_upload_uid)"
    filename="$(basename "$archive_path")"
    upload_url="${endpoint}/${path_prefix}/${uid}/${filename}"
    public_url="${upload_url//-internal/}"

    echo "Uploading stack trace archive to file server..."
    if curl -fsS --max-time "$timeout" \
        -H "Content-Disposition: inline" \
        -H "Content-Type: ${content_type}" \
        -T "$archive_path" \
        "$upload_url"; then
        echo
        echo "Stack trace archive URL: $public_url"
    else
        echo "WARNING: stack trace archive upload failed; local archive: $archive_path" >&2
    fi

    return 0
}

archive_and_upload_stack_traces() {
    local trace_dir="${STACK_TRACE_MONITOR_DIR:-${RESULT_DIR}/stack_trace}"
    local timestamp_part="${TIMESTAMP:-$(date '+%Y%m%d_%H%M%S')}"
    local archive_path="${RESULT_DIR}/stack_trace_${timestamp_part}.tar.gz"

    if [ -z "${RESULT_DIR:-}" ] || [ ! -d "$trace_dir" ]; then
        return 0
    fi

    if ! find "$trace_dir" -type f -print -quit | grep -q .; then
        echo "No stack trace files collected, skipping archive upload"
        return 0
    fi

    if ! command -v tar >/dev/null 2>&1; then
        echo "WARNING: tar not found; cannot archive stack trace files." >&2
        return 0
    fi

    echo "Archiving BE stack traces: $archive_path"
    if ! tar -czf "$archive_path" -C "$RESULT_DIR" "$(basename "$trace_dir")"; then
        echo "WARNING: failed to archive stack trace files." >&2
        return 0
    fi

    STACK_TRACE_MONITOR_ARCHIVE="$archive_path"
    upload_stack_trace_archive "$archive_path"
    return 0
}

finalize_stack_trace_monitor() {
    local status="${1:-0}"

    if [[ "${STACK_TRACE_MONITOR_FINALIZED:-false}" == "true" ]]; then
        return "$status"
    fi
    STACK_TRACE_MONITOR_FINALIZED="true"

    set +e
    stop_stack_trace_monitor
    archive_and_upload_stack_traces
    set -e

    return "$status"
}

# Load database engine
load_engine() {
    local engine_file_prefix="$ENGINE_TYPE"
    if [ "$ENGINE_TYPE" = "velodb" ]; then
        engine_file_prefix="doris"
    fi
    
    local engine_file="$SCRIPT_DIR/engines/${engine_file_prefix}_engine.sh"
    
    if [ ! -f "$engine_file" ]; then
        die "Engine file not found: $engine_file"
    fi

    # Source the engine
    if ! source "$engine_file"; then
        die "Failed to load engine: $engine_file"
    fi
    
    # Validate engine interface
    for func in engine_init engine_run_sql_file engine_run_sql engine_get_jdbc_datasource engine_get_jdbc_sampler_name; do
        if ! declare -f "$func" >/dev/null 2>&1; then
            die "Engine $ENGINE_TYPE does not implement required function: $func"
        fi
    done
}

# Initialize engine
init_engine() {
    if ! engine_init; then
        die "Engine initialization failed"
    fi
}

# Run DDL setup
run_ddl() {
    if ! engine_create_database; then
        die "Database creation failed"
    fi

    local ddl_file="${DDL:-ddl/ddl.sql}"

    # Convert relative path to absolute
    if [[ "$ddl_file" != /* ]]; then
        ddl_file="$TEST_ROOT/$ddl_file"
    fi

    if [ ! -f "$ddl_file" ]; then
        echo "DDL file not found, skipping setup"
        return 0
    fi

    echo "Running DDL."

    # Keep DDL behavior consistent with load phase so ${STORAGE_*} works in DDL SQL.
    local tmp_sql
    create_temp_sql_file "ddl"
    tmp_sql="$LAST_TEMP_FILE"
    envsubst < "$ddl_file" > "$tmp_sql"
    if ! engine_run_sql_file "$tmp_sql" false; then
        rm -f "$tmp_sql"
        die "DDL setup failed"
    fi
    rm -f "$tmp_sql"
}

run_session() {
    local session_file="${SESSION_FILE:-session/session.sql}"

    # Convert relative path to absolute
    if [[ "$session_file" != /* ]]; then
        session_file="$TEST_ROOT/$session_file"
    fi

    if [ ! -f "$session_file" ]; then
        echo "Session file not found, skipping session setup"
        return 0
    fi
    echo "Running set session."
    local session_content
    session_content=$(envsubst < "$session_file")
    if ! engine_run_sql "" "$session_content" false; then
        die "Setup session failed"
    fi
}

detect_load_method() {
    local load_dir="$1"
    local dirname
    dirname=$(basename "$load_dir")

    if [[ "$dirname" == *stream* ]]; then
        echo "stream_load"
    elif [[ "$dirname" == *s3* ]]; then
        echo "s3_load"
    elif [[ "$dirname" == *insert* ]]; then
        echo "insert_into"
    else
        echo "insert_into"
    fi
}

run_load_directory() {
    local load_dir="$1"
    local detected_method="$2"
    local load_csv="$3"
    local loaded_count=0
    local load_output=""

    LAST_LOAD_COUNT=0

    # Convert relative path to absolute
    if [[ "$load_dir" != /* ]]; then
        load_dir="$TEST_ROOT/$load_dir"
    fi

    if [ ! -d "$load_dir" ]; then
        echo "Load directory not found, skipping: $load_dir"
        return 0
    fi

    echo "Loading data from $(basename "$load_dir") (method: $detected_method)..."

    for load_file in "$load_dir"/*.sql "$load_dir"/*.sh; do
        if [ ! -f "$load_file" ]; then
            continue
        fi

        local filename
        filename=$(basename "$load_file")
        local table_name="${filename%.*}"

        echo "  Loading $table_name..."

        local start_time
        start_time=$(date +%s%3N)

        if type -t engine_load_data > /dev/null; then
            if ! engine_load_data "$detected_method" "$load_file" "$table_name"; then
                die "Engine failed to load data for $table_name using $detected_method"
            fi
        else
            # Default fallback for engines that don't implement engine_load_data
            if [[ "$detected_method" == "stream_load" ]]; then
                if load_output=$(bash "$load_file" 2>&1); then
                    echo "$load_output"
                else
                    echo "$load_output" >&2
                    die "Failed to execute load script: $load_file"
                fi
            else
                local tmp_sql
                create_temp_sql_file "load_${table_name}"
                tmp_sql="$LAST_TEMP_FILE"
                envsubst < "$load_file" > "$tmp_sql"

                if ! engine_run_sql_file "$tmp_sql"; then
                    rm -f "$tmp_sql"
                    die "Failed to execute load SQL file: $load_file"
                fi
                rm -f "$tmp_sql"
            fi
        fi

        local end_time
        end_time=$(date +%s%3N)
        local duration
        duration=$(echo "scale=3; ($end_time - $start_time) / 1000" | bc)

        echo "$table_name,$detected_method,$duration" >> "$load_csv"
        echo "    ${duration}s"
        loaded_count=$((loaded_count + 1))
    done

    LAST_LOAD_COUNT=$loaded_count
}

# Load data
run_load() {
    local load_dir="${LOAD_DIR:-}"
    local load_steps_count=0

    load_steps_count=$(yq eval '.paths.load_steps // [] | length' "$CONFIG_FILE")

    if [ "$load_steps_count" -eq 0 ] && [ -z "$load_dir" ]; then
        echo "No load directory configured, skipping data loading"
        return 0
    fi

    # Initialize load results CSV
    local load_csv="$RESULT_DIR/load.csv"
    echo "table_name,method,load_time_seconds" > "$load_csv"

    local loaded_count=0

    if [ "$load_steps_count" -gt 0 ]; then
        local i
        for ((i = 0; i < load_steps_count; i++)); do
            local step_dir
            local step_method

            step_dir=$(yq eval ".paths.load_steps[$i].dir // \"\"" "$CONFIG_FILE")
            step_method=$(yq eval ".paths.load_steps[$i].method // \"\"" "$CONFIG_FILE")

            step_dir=$(eval echo "$step_dir")
            step_method=$(eval echo "$step_method")

            if [ -z "$step_dir" ]; then
                echo "Skipping load step $i: missing dir"
                continue
            fi

            if [ -z "$step_method" ]; then
                step_method=$(detect_load_method "$step_dir")
            fi

            run_load_directory "$step_dir" "$step_method" "$load_csv"
            loaded_count=$((loaded_count + LAST_LOAD_COUNT))
        done
    else
        if [ -z "$load_dir" ]; then
            echo "No load directory configured, skipping data loading"
            return 0
        fi

        local detected_method
        detected_method=$(detect_load_method "$load_dir")
        run_load_directory "$load_dir" "$detected_method" "$load_csv"
        loaded_count=$LAST_LOAD_COUNT
    fi

    echo "Data loading completed: $loaded_count tables"
}

run_check_rows() {
    echo "Checking loaded rows..."
    local check_start
    check_start=$(date +%s%3N)

    # Read expected row counts from tables config in benchmark.yaml
    local has_tables
    has_tables=$(yq eval '.tables // ""' "$CONFIG_FILE")
    if [ -z "$has_tables" ] || [ "$has_tables" = "null" ]; then
        echo "No tables config found in benchmark.yaml, skipping check rows"
        return 0
    fi

    local rows_csv="$RESULT_DIR/check_rows.csv"
    echo "table_name,rows" > "$rows_csv"

    # Validate actual row counts against expected values from config
    local has_mismatch=false
    local mismatch_details=""
    while IFS='=' read -r table_name expected_rows; do
        [ -z "$table_name" ] && continue
        local actual_rows
        actual_rows=$(engine_get_table_rows "$table_name")
        echo "$table_name,$actual_rows" >> "$rows_csv"
        if [ "$actual_rows" -ne "$expected_rows" ]; then
            echo "    MISMATCH $table_name: expected=$expected_rows actual=$actual_rows"
            has_mismatch=true
            mismatch_details+="  $table_name: expected=$expected_rows actual=$actual_rows\n"
        else
            echo "    OK $table_name: $actual_rows rows"
        fi
    done < <(yq eval '.tables | to_entries | .[] | .key + "=" + (.value | tostring)' "$CONFIG_FILE")

    if [ "$has_mismatch" = true ]; then
        die "Row count validation failed:\n$mismatch_details"
    fi

    local check_end
    check_end=$(date +%s%3N)
    echo "scale=3; ($check_end - $check_start) / 1000" | bc > "$RESULT_DIR/check_rows_time.txt"
}

run_timed_query() {
    local query_name="$1"
    local safe_query_name="$2"
    local run_label="$3"
    local sql_content="$4"

    RUN_QUERY_DURATION="9999"
    echo "Query run ${query_name} on ${run_label}"

    local start_time
    start_time=$(date +%s%3N)
    if engine_run_sql "${db}" "$sql_content"; then
        local end_time
        end_time=$(date +%s%3N)
        RUN_QUERY_DURATION=$(echo "scale=3; ($end_time - $start_time) / 1000" | bc)
        if [[ "$profile_supported" == "true" && "$profile_enabled" == "true" ]]; then
            local query_id
            query_id=$(engine_get_last_query_id 2>/dev/null || true)
            if [ -n "$query_id" ]; then
                profile_query_names+=("${safe_query_name}")
                profile_query_runs+=("${run_label}")
                profile_query_ids+=("${query_id}")
            else
                echo "Failed to get query id for ${query_name} ${run_label}" >&2
            fi
        fi
    else
        echo "Query execution failed ${query_name} on ${run_label}" >&2
    fi
}

min_query_duration() {
    local min="$1"
    shift || true
    local value
    for value in "$@"; do
        if awk -v a="$value" -v b="$min" 'BEGIN{exit !(a < b)}'; then
            min="$value"
        fi
    done
    printf '%s' "$min"
}

# Run benchmark queries
run_query() {
    local query_dir="${QUERY_DIR:-query/}"

    # Collect all queries first
    local -a all_query_names=()
    local -a all_query_sqls=()

    # Convert relative path to absolute
    if [[ "$query_dir" != /* ]]; then
        query_dir="$TEST_ROOT/$query_dir"
    fi
    query_dir="${query_dir%/}"
    if [ -z "$query_dir" ]; then
        query_dir="/"
    fi

    if [ ! -d "$query_dir" ]; then
        echo "Query directory not found: $query_dir, skipping"
        return 0
    fi

    echo "Processing queries from $(basename "$query_dir")..."
    # Process all SQL files under query_dir recursively (sorted numerically)
    while IFS= read -r -d '' query_file; do
        if [ ! -f "$query_file" ]; then
            continue
        fi

        # Use the path relative to query_dir as the query name so nested
        # directories become part of the identifier, e.g. agg/q1.sql -> agg/q1.
        local query_name relative_path
        relative_path="${query_file#$query_dir/}"
        if [ "$relative_path" = "$query_file" ]; then
            relative_path=$(basename "$query_file")
        fi
        query_name="${relative_path%.sql}"

        if [ "$QUERY_MODE" = "line" ]; then
            # Line-based mode: each line is a separate query
            local query_counter=1
            while IFS= read -r line || [ -n "$line" ]; do
                # Skip empty lines and comments
                if [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*-- ]]; then
                    continue
                fi

                local full_query_name="${query_name}_q${query_counter}"
                # Add to queries array: query_name and sql_content separately
                all_query_names+=("$full_query_name")
                all_query_sqls+=("$(printf '%s' "$line" | envsubst)")

                ((query_counter++))
            done < "$query_file"
        else
            # File-based mode: entire file is one query (default behavior)
            local full_query_name="${query_name}"

            # Read and escape SQL content
            local sql_content
            sql_content=$(envsubst < "$query_file")

            # Add to queries array: query_name and sql_content separately
            all_query_names+=("$full_query_name")
            all_query_sqls+=("$sql_content")
        fi
    done < <(find "$query_dir" -name "*.sql" -type f -print0 | sort -zV)
    
    

    local profile_supported="false"
    local profile_enabled="false"
    if [[ "$profile" == "true" ]]; then
        profile_supported="true"
        if engine_enable_profile; then
            profile_enabled="true"
        else
            profile_supported="false"
        fi
    fi

    echo "Running queries..."
    # Initialize query results CSV
    local query_csv="$RESULT_DIR/query.csv"
    local query_detail_csv="$RESULT_DIR/query_detail.csv"
    local plan_dir=""
    local profile_dir=""
    if [[ "$plan" == "true" ]]; then
        plan_dir="$RESULT_DIR/plan"
        mkdir -p "$plan_dir"
    fi
    if [[ "$profile_supported" == "true" ]]; then
        profile_dir="$RESULT_DIR/profile"
        mkdir -p "$profile_dir"
    fi
    
    # Store query metadata for batch profile fetching
    local profile_query_names=()
    local profile_query_runs=()
    local profile_query_ids=()
    
    local use_custom_query_counts="false"
    if (( cold_query_count > 0 || hot_query_count > 0 )); then
        use_custom_query_counts="true"
    fi

    # Write header to query.csv. In custom cold/hot mode query.csv keeps a
    # UI-compatible summary; query_detail.csv keeps every measured run.
    header="query_name,cold_1"
    if [[ "$use_custom_query_counts" == "true" ]]; then
        if (( hot_query_count > 0 )); then
            header+=",hot_min"
        fi
        echo "$header" > "$query_csv"

        local detail_header="query_name"
        for ((i=1; i<=cold_query_count; i++)); do
            detail_header+=",cold_$i"
        done
        for ((i=1; i<=hot_query_count; i++)); do
            detail_header+=",hot_$i"
        done
        if (( hot_query_count > 0 )); then
            detail_header+=",hot_min"
        fi
        echo "$detail_header" > "$query_detail_csv"
    else
        for ((i=1; i<=query_times-1; i++)); do
            header+=",hot_$i"
        done
        echo "$header" > "$query_csv"
    fi
    for((i=0; i<${#all_query_names[@]}; i++)); do
        local query_name="${all_query_names[i]}"
        local sql_content="${all_query_sqls[i]}"
        local times_result="${query_name}"
        local safe_query_name="${query_name//\//_}"
        safe_query_name="${safe_query_name// /_}"

        if [[ "$plan" == "true" ]]; then
            local plan_content
            local plan_sql
            plan_sql=$(printf '%s' "$sql_content" | sed -e '/^[[:space:]]*--/d' -e '/^[[:space:]]*#/d')
            plan_content=$(engine_get_plan "${db}" "$plan_sql" 2>/dev/null || true)
            if [ -n "$plan_content" ]; then
                printf "%s\n" "$plan_content" > "$plan_dir/${safe_query_name}_plan.txt"
            else
                echo "Plan collection returned empty for ${query_name}" >&2
            fi
        fi

        if [[ "$use_custom_query_counts" != "true" ]] && type -t should_clear_cache_before_query >/dev/null && should_clear_cache_before_query "$query_name"; then
            if ! run_clear_cache_actions "$query_name"; then
                die "Failed to clear cache before query ${query_name}"
            fi
        fi

        if [[ "$use_custom_query_counts" == "true" ]]; then
            local cold_values=()
            local hot_values=()
            local detail_result="${query_name}"

            for ((t=1; t<=cold_query_count; t++)); do
                if type -t should_clear_cache_for_cold_query_run >/dev/null && should_clear_cache_for_cold_query_run "$query_name" "$t"; then
                    if ! run_clear_cache_actions "$query_name" "cold_$t"; then
                        die "Failed to clear cache before query ${query_name} cold run ${t}"
                    fi
                fi
                run_timed_query "$query_name" "$safe_query_name" "cold_$t" "$sql_content"
                cold_values+=("$RUN_QUERY_DURATION")
                detail_result+=",$RUN_QUERY_DURATION"
            done

            for ((t=1; t<=hot_query_count; t++)); do
                run_timed_query "$query_name" "$safe_query_name" "hot_$t" "$sql_content"
                hot_values+=("$RUN_QUERY_DURATION")
                detail_result+=",$RUN_QUERY_DURATION"
            done

            local hot_min="null"
            if (( hot_query_count > 0 )); then
                hot_min=$(min_query_duration "${hot_values[@]}")
                detail_result+=",$hot_min"
            fi

            if (( cold_query_count > 0 )); then
                times_result+=",${cold_values[0]}"
            else
                times_result+=",null"
            fi
            if (( hot_query_count > 0 )); then
                times_result+=",$hot_min"
            fi

            echo "$times_result" >> "$query_csv"
            echo "$detail_result" >> "$query_detail_csv"
        else
            for ((t=1; t<=query_times; t++)); do
                if type -t should_clear_cache_for_run >/dev/null && should_clear_cache_for_run "$t"; then
                    if ! run_clear_cache_actions "$query_name" "$t"; then
                        die "Failed to clear cache before query ${query_name} run ${t}"
                    fi
                fi
                run_timed_query "$query_name" "$safe_query_name" "$t" "$sql_content"
                times_result+=",$RUN_QUERY_DURATION"
            done
            echo "$times_result" >> "$query_csv"
        fi
    done
    
    # Process batch profile fetching
    if [[ "$profile_supported" == "true" && "$profile_enabled" == "true" ]] && [ ${#profile_query_ids[@]} -gt 0 ]; then
        local profile_wait_seconds="${PROFILE_WAIT_SECONDS:-10}"
        echo "Waiting ${profile_wait_seconds}s for asynchronous profile generation before fetching..."
        sleep "${profile_wait_seconds}"
        
        for p_idx in "${!profile_query_ids[@]}"; do
            local p_name="${profile_query_names[$p_idx]}"
            local p_run="${profile_query_runs[$p_idx]}"
            local p_id="${profile_query_ids[$p_idx]}"
            
            echo "Fetching profile for ${p_name} run ${p_run} (Query ID: ${p_id})..."
            local profile_content
            profile_content=$(engine_fetch_profile "$p_id" 2>/dev/null || true)

            if [ -n "$profile_content" ]; then
                printf "%s\n" "$profile_content" > "$profile_dir/${p_name}_run${p_run}_profile.txt"
            else
                echo "Profile fetch returned empty for ${p_name} run ${p_run}" >&2
            fi
        done
    fi

    if [[ "$profile_supported" == "true" && "$profile_enabled" == "true" ]]; then
        if ! engine_disable_profile; then
            echo "Failed to disable profile after queries" >&2
        fi
    fi
}


run_analyze() {
    if run_builtin_analyze; then
        return 0
    fi

    local builtin_rc=$?
    if [ "$builtin_rc" -eq 2 ]; then
        echo "Built-in analyze is unavailable for this engine, fallback to analyze SQL file."
        if run_analyze_with_sql_file; then
            return 0
        fi
        die "Analysis failed: built-in analyze unavailable and SQL-file fallback failed"
    fi

    die "Built-in analysis failed"
}


run_analyze_with_sql_file() {
    echo "Running analysis with SQL file..."
    local analyze_sql="${ANALYZE_FILE:-analyze/analyze.sql}"

    if [ -z "$analyze_sql" ] || [ "$analyze_sql" = "null" ]; then
        echo "No analysis SQL file configured"
        return 2
    fi

    if [[ "$analyze_sql" == *'${'* ]]; then
        echo "Unresolved variable in analyze path: $analyze_sql" >&2
        return 1
    fi

    if [[ "$analyze_sql" != /* ]]; then
        analyze_sql="$TEST_ROOT/$analyze_sql"
    fi

    if [ ! -f "$analyze_sql" ]; then
        echo "Analysis SQL file not found: $analyze_sql" >&2
        return 2
    fi

    local tmp_sql
    create_temp_sql_file "analyze"
    tmp_sql="$LAST_TEMP_FILE"
    envsubst < "$analyze_sql" > "$tmp_sql"

    local start_time
    start_time=$(date +%s%3N)

    if engine_run_sql_file "$tmp_sql"; then
        local end_time
        end_time=$(date +%s%3N)
        local duration
        duration=$(echo "scale=3; ($end_time - $start_time) / 1000" | bc)

        echo "step,duration_seconds" > "$RESULT_DIR/analyze.csv"
        echo "analyze,$duration" >> "$RESULT_DIR/analyze.csv"

        rm -f "$tmp_sql"
        echo "Analysis completed in ${duration}s"
        return 0
    fi

    rm -f "$tmp_sql"
    echo "Analysis SQL execution failed" >&2
    return 1
}

run_builtin_analyze() {
    local target_db="${db:-}"
    if [ -z "$target_db" ]; then
        echo "Database is empty, cannot run built-in analyze" >&2
        return 1
    fi

    local engine_type_lower
    engine_type_lower="$(echo "${ENGINE_TYPE:-}" | tr '[:upper:]' '[:lower:]')"
    if [[ "$engine_type_lower" != "doris" && "$engine_type_lower" != "starrocks" ]]; then
        echo "Built-in analyze is supported only for doris/starrocks, current engine: ${ENGINE_TYPE}" >&2
        return 2
    fi

    local tables_output
    if ! tables_output=$(engine_list_tables "$target_db" 2>&1); then
        if [[ "$tables_output" == *"not supported"* ]]; then
            return 2
        fi
        echo "$tables_output" >&2
        return 1
    fi

    mapfile -t tables < <(printf '%s\n' "$tables_output" | awk 'NF > 0')

    # Normalize analyze_type to lowercase for robust matching
    analyze_type="$(echo "${analyze_type:-${ANALYZE_TYPE:-analyze_full}}" | tr '[:upper:]' '[:lower:]')"
    local analyze_csv="$RESULT_DIR/analyze.csv"

    echo "Running built-in analysis (type: ${analyze_type})..."
    echo "step,duration_seconds" > "$analyze_csv"

    case "$analyze_type" in
        analyze_default)
            local auto_output
            if ! auto_output=$(engine_set_auto_analyze "true" 2>&1); then
                if [[ "$auto_output" == *"not supported"* ]]; then
                    return 2
                fi
                echo "$auto_output" >&2
                return 1
            fi

            echo "default analyze wait 10 min"
            sleep 600
        ;;
        analyze_full|analyze_sample)
            local disable_output
            if ! disable_output=$(engine_set_auto_analyze "false" 2>&1); then
                if [[ "$disable_output" == *"not supported"* ]]; then
                    return 2
                fi
                echo "$disable_output" >&2
                return 1
            fi

            sleep 60

            local table
            for table in "${tables[@]}"; do
                local drop_output
                if ! drop_output=$(engine_drop_stats "$target_db" "$table" 2>&1); then
                    if [[ "$drop_output" != *"not supported"* ]]; then
                        echo "$drop_output" >&2
                        return 1
                    fi
                fi

                local start_time end_time duration
                start_time=$(date +%s%3N)

                local analyze_output
                if ! analyze_output=$(engine_analyze_table "$target_db" "$table" "$analyze_type" 2>&1); then
                    if [[ "$analyze_output" == *"Analyze view is not allowed"* ]]; then
                        echo "Skip analyze view entry: ${table}"
                        continue
                    fi
                    echo "$analyze_output" >&2
                    return 1
                fi

                end_time=$(date +%s%3N)
                duration=$(echo "scale=3; ($end_time - $start_time) / 1000" | bc)
                echo "${table},${duration}" >> "$analyze_csv"
                echo "Analyze table ${table} completed in ${duration}s"
            done
        ;;
        analyze_no)
            local disable_output
            if ! disable_output=$(engine_set_auto_analyze "false" 2>&1); then
                if [[ "$disable_output" == *"not supported"* ]]; then
                    return 2
                fi
                echo "$disable_output" >&2
                return 1
            fi

            local table
            for table in "${tables[@]}"; do
                local drop_output
                if ! drop_output=$(engine_drop_stats "$target_db" "$table" 2>&1); then
                    if [[ "$drop_output" != *"not supported"* ]]; then
                        echo "$drop_output" >&2
                        return 1
                    fi
                fi
            done
        ;;
        *)
            echo "analyze type [${analyze_type}] error format" >&2
        ;;
    esac

    if [ "$engine_type_lower" = "doris" ]; then
        local table
        for table in "${tables[@]}"; do
            local stats_output
            if ! stats_output=$(engine_show_column_stats "$target_db" "$table" 2>&1); then
                echo "Column stats unavailable for ${table}: ${stats_output}" >&2
            fi
        done
    fi

    return 0
}


# Run JMeter tests
run_jmeter() {
    echo "Running JMeter tests..."
    
    local jmx_file="$RESULT_DIR/benchmark.jmx"
    local jtl_file="$RESULT_DIR/results.jtl"
    local html_report="$RESULT_DIR/html_report"
    local jmeter_log="$RESULT_DIR/jmeter.log"
    
    if [ ! -f "$jmx_file" ]; then
        die "JMX file not found: $jmx_file"
    fi
    
    # Clean up any previous results
    rm -rf "$jtl_file" "$html_report"
    
    # Determine which jmeter command to use
    local jmeter_cmd
    if [ -n "${JMETER_HOME:-}" ] && [ -x "$JMETER_HOME/bin/jmeter" ]; then
        jmeter_cmd="$JMETER_HOME/bin/jmeter"
        echo "Using local JMeter: $jmeter_cmd"
    elif command -v jmeter >/dev/null 2>&1; then
        jmeter_cmd="jmeter"
        echo "Using system JMeter"
    else
        die "JMeter not found. Please provide JMeter archive in tools directory or install it system-wide."
    fi
    
    # Execute JMeter in non-GUI mode
    if "$jmeter_cmd" \
    -n \
    -t "$jmx_file" \
    -l "$jtl_file" \
    -e \
    -o "$html_report" \
    -j "$jmeter_log"; then
        echo "JMeter execution completed"
    else
        echo "ERROR: JMeter execution failed, check log: $jmeter_log" >&2
        return 1
    fi
}

run_vectordbbench() {
    local runner_file="$LIB_DIR/vectordb_runner.sh"
    if [ ! -f "$runner_file" ]; then
        die "VectorDBBench runner not found: $runner_file"
    fi

    # Source the runner and execute
    # shellcheck source=lib/vectordb_runner.sh
    source "$runner_file"
    execute_vectordbbench_task
}

run_sysbench() {
    local runner_file="$LIB_DIR/sysbench_runner.sh"
    if [ ! -f "$runner_file" ]; then
        die "Sysbench runner not found: $runner_file"
    fi

    # Source the runner and execute
    # shellcheck source=lib/sysbench_runner.sh
    source "$runner_file"
    execute_sysbench_task
}

# Main execution function
main() {
    # Initialize tools early (especially yq which is needed for config parsing)
    if ! init_basic_tools; then
        die "Failed to initialize tools"
    fi
    # Parse command line arguments
    parse_args "$@"
    
    # Initialize test environment
    initialize_test
    
    # Load configuration (to get jmeter flag early)
    load_config
    load_storage_config
    jmeter="${jmeter:-false}"
    vectordbbench="${vectordbbench:-false}"
    
    # Check framework dependencies (now that jmeter flag is known)
    check_dependencies
    
    # Load other parameters
    session="${session:-true}"
    load="${load:-false}"
    analyze="${analyze:-false}"
    analyze_type="${analyze_type:-${ANALYZE_TYPE:-analyze_full}}"
    query="${query:-false}"
    query_times="${query_times:-1}"
    cold_query_count="${cold_query_count:-${COLD_QUERY_COUNT:-0}}"
    hot_query_count="${hot_query_count:-${HOT_QUERY_COUNT:-0}}"
    db="${db:-}"
    drop_database="${drop_database:-${DROP_DATABASE:-false}}"
    clean_trash="${clean_trash:-${CLEAN_TRASH:-false}}"
    profile="${profile:-${PROFILE:-false}}"
    plan="${plan:-${PLAN:-false}}"
    stack_trace_monitor="${stack_trace_monitor:-${STACK_TRACE_MONITOR:-true}}"
    stack_trace_upload="${stack_trace_upload:-${STACK_TRACE_UPLOAD:-true}}"
    stack_trace_interval_seconds="${stack_trace_interval_seconds:-${STACK_TRACE_INTERVAL_SECONDS:-120}}"
    stack_trace_curl_timeout_seconds="${stack_trace_curl_timeout_seconds:-${STACK_TRACE_CURL_TIMEOUT_SECONDS:-30}}"
    stack_trace_upload_timeout_seconds="${stack_trace_upload_timeout_seconds:-${STACK_TRACE_UPLOAD_TIMEOUT_SECONDS:-30}}"
    stack_trace_file_server_prefix="${stack_trace_file_server_prefix:-${STACK_TRACE_FILE_SERVER_PREFIX:-rqg-abtest/case_result}}"
    stack_trace_upload_content_type="${stack_trace_upload_content_type:-${STACK_TRACE_UPLOAD_CONTENT_TYPE:-application/gzip}}"
    file_server_endpoint="${file_server_endpoint:-${FILE_SERVER_ENDPOINT:-http://justtmp.oss-cn-beijing.aliyuncs.com}}"
    clear_file_cache="${clear_file_cache:-${CLEAR_FILE_CACHE:-false}}"
    disable_doris_page_cache="${disable_doris_page_cache:-${DISABLE_DORIS_PAGE_CACHE:-}}"
    clear_sys_page_cache="${clear_sys_page_cache:-${CLEAR_SYS_PAGE_CACHE:-false}}"
    clear_cache_scope="${clear_cache_scope:-${CLEAR_CACHE_SCOPE:-cold}}"
    be_hosts="${be_hosts:-${BE_HOSTS:-}}"
    be_http_port="${be_http_port:-${BE_HTTP_PORT:-8040}}"
    be_brpc_port="${be_brpc_port:-${BE_BRPC_PORT:-8060}}"
    clear_file_cache_max_size_gb="${clear_file_cache_max_size_gb:-${CLEAR_FILE_CACHE_MAX_SIZE_GB:-0}}"
    clear_file_cache_timeout_min="${clear_file_cache_timeout_min:-${CLEAR_FILE_CACHE_TIMEOUT_MIN:-60}}"
    clear_sys_page_cache_method="${clear_sys_page_cache_method:-${CLEAR_SYS_PAGE_CACHE_METHOD:-ssh}}"
    clear_sys_page_cache_http_port="${clear_sys_page_cache_http_port:-${CLEAR_SYS_PAGE_CACHE_HTTP_PORT:-8050}}"
    clear_sys_page_cache_http_path="${clear_sys_page_cache_http_path:-${CLEAR_SYS_PAGE_CACHE_HTTP_PATH:-/drop_sys_cache}}"
    clear_cache_ssh_user="${clear_cache_ssh_user:-${CLEAR_CACHE_SSH_USER:-root}}"

    if [[ "${drop_database,,}" != "true" ]]; then
        drop_database="false"
    fi
    if [[ "${clean_trash,,}" != "true" ]]; then
        clean_trash="false"
    fi
    if [[ "${profile,,}" != "true" ]]; then
        profile="false"
    fi
    if [[ "${plan,,}" != "true" ]]; then
        plan="false"
    fi
    local stack_trace_monitor_lower
    local stack_trace_upload_lower
    stack_trace_monitor_lower="$(printf '%s' "$stack_trace_monitor" | tr '[:upper:]' '[:lower:]')"
    stack_trace_upload_lower="$(printf '%s' "$stack_trace_upload" | tr '[:upper:]' '[:lower:]')"
    if [[ "$stack_trace_monitor_lower" == "true" ]]; then
        stack_trace_monitor="true"
    else
        stack_trace_monitor="false"
    fi
    if [[ "$stack_trace_upload_lower" == "true" ]]; then
        stack_trace_upload="true"
    else
        stack_trace_upload="false"
    fi
    if ! [[ "$stack_trace_curl_timeout_seconds" =~ ^[0-9]+$ ]] || [ "$stack_trace_curl_timeout_seconds" -le 0 ]; then
        echo "WARNING: invalid stack_trace_curl_timeout_seconds=${stack_trace_curl_timeout_seconds}; using 30." >&2
        stack_trace_curl_timeout_seconds="30"
    fi
    if ! [[ "$cold_query_count" =~ ^[0-9]+$ ]]; then
        die "Invalid cold_query_count: ${cold_query_count}"
    fi
    if ! [[ "$hot_query_count" =~ ^[0-9]+$ ]]; then
        die "Invalid hot_query_count: ${hot_query_count}"
    fi

    clear_cache_scope="${clear_cache_scope,,}"
    clear_sys_page_cache_method="${clear_sys_page_cache_method,,}"
    if [[ "${clear_file_cache,,}" == "true" ]]; then
        clear_file_cache="true"
    else
        clear_file_cache="false"
    fi
    case "${disable_doris_page_cache,,}" in
        true)
            disable_doris_page_cache="true"
            ;;
        false)
            disable_doris_page_cache="false"
            ;;
        "")
            disable_doris_page_cache=""
            ;;
        *)
            die "Invalid disable_doris_page_cache: ${disable_doris_page_cache} (allowed: true, false)"
            ;;
    esac
    if [[ "${clear_sys_page_cache,,}" == "true" ]]; then
        clear_sys_page_cache="true"
    else
        clear_sys_page_cache="false"
    fi

    if ! [[ "$be_http_port" =~ ^[0-9]+$ ]]; then
        die "Invalid be_http_port: ${be_http_port}"
    fi

    if [[ "${clear_file_cache:-false}" == "true" \
        || "${clear_sys_page_cache:-false}" == "true" ]]; then
        case "$clear_cache_scope" in
            before_query_phase|query_phase|once)
                clear_cache_scope="before_query"
                ;;
            before_query|per_query|cold|every_run)
                ;;
            *)
                die "Invalid clear_cache_scope: ${clear_cache_scope} (allowed: before_query, per_query, cold, every_run)"
                ;;
        esac
        # Some engines can discover BE hosts from the FE when BE_HOSTS is empty.
        # Engine initialization is responsible for failing if discovery is not
        # supported or returns no hosts.
        if ! [[ "$be_brpc_port" =~ ^[0-9]+$ ]]; then
            die "Invalid be_brpc_port: ${be_brpc_port}"
        fi
        if [[ "${clear_sys_page_cache:-false}" == "true" ]]; then
            if [[ "$clear_sys_page_cache_method" != "ssh" && "$clear_sys_page_cache_method" != "http" ]]; then
                die "Invalid clear_sys_page_cache_method: ${clear_sys_page_cache_method} (allowed: ssh, http)"
            fi
            if [[ "$clear_sys_page_cache_method" == "http" ]] && ! [[ "$clear_sys_page_cache_http_port" =~ ^[0-9]+$ ]]; then
                die "Invalid clear_sys_page_cache_http_port: ${clear_sys_page_cache_http_port}"
            fi
        fi
        if ! [[ "$clear_file_cache_max_size_gb" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            die "Invalid clear_file_cache_max_size_gb: ${clear_file_cache_max_size_gb}"
        fi
        if ! [[ "$clear_file_cache_timeout_min" =~ ^[0-9]+$ ]]; then
            die "Invalid clear_file_cache_timeout_min: ${clear_file_cache_timeout_min}"
        fi
    fi
    
    # Load and initialize engine
    load_engine
    init_engine

    if [[ "${clear_file_cache:-false}" == "true" \
        || "${clear_sys_page_cache:-false}" == "true" ]]; then
        if ! type -t should_clear_cache_before_query_phase >/dev/null \
            || ! type -t should_clear_cache_before_query >/dev/null \
            || ! type -t should_clear_cache_for_run >/dev/null \
            || ! type -t should_clear_cache_for_cold_query_run >/dev/null \
            || ! type -t run_clear_cache_actions >/dev/null; then
            die "Cache clearing is not supported by engine: ${ENGINE_TYPE}"
        fi
    fi
    
    # Run benchmark workflow
    echo "Starting benchmark: $ENGINE_TYPE"
    start_stack_trace_monitor
    if [[ "${STACK_TRACE_MONITOR_STARTED:-false}" == "true" ]]; then
        trap 'stack_trace_status=$?; finalize_stack_trace_monitor "$stack_trace_status"; exit "$stack_trace_status"' EXIT
    fi

    # 1. Run DDL first so the database and tables exist
    if [[ "$load" == "true" ]]; then
        run_ddl
    fi

    # 2. Run Session setup next so variables are set for Load and Query phases
    if [[ "$session" != "true" ]]; then
        echo "Session setup disabled, skipping"
    else
        run_session
    fi

    # 3. Finally run Load and other phases
    if [[ "$load" == "true" ]]; then
        run_load
        run_check_rows
    fi
    
    if [[ "$analyze" != "true" ]]; then
        echo "Analysis disabled, skipping"
    else
        run_analyze
    fi
    if [[ "$query" != "true" ]]; then
        echo "Query execution disabled, skipping"
    else
        if type -t should_clear_cache_before_query_phase >/dev/null && should_clear_cache_before_query_phase; then
            if ! run_clear_cache_actions "query phase"; then
                die "Failed to clear cache before query phase"
            fi
        fi
        run_query
    fi
    if [[ "$jmeter" != "true" ]]; then
        echo "JMeter execution disabled, skipping"
    else
        generate_jmx
        run_jmeter
    fi

    if is_sysbench_enabled; then
        run_sysbench
    fi

    if [[ "$vectordbbench" == "true" ]]; then
        run_vectordbbench
    fi

    finalize_stack_trace_monitor 0
    trap - EXIT
    
    # Generation Result
    generate_result

    # Optional: cleanup databases after benchmark
    if [[ "$drop_database" == "true" ]]; then
        if ! engine_drop_database; then
            echo "Drop database failed" >&2
        fi
    fi

    # Optional: clean trash independently of drop_database
    if [[ "$clean_trash" == "true" ]]; then
        local clean_trash_delay="${CLEAN_TRASH_DELAY:-30}"
        sleep "$clean_trash_delay"
        if ! engine_clean_trash; then
            echo "Clean trash failed" >&2
        fi
    fi
    
    echo "Benchmark completed!"
    echo "Results: $RESULT_DIR"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
