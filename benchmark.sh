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
CONFIG_FILE=""
TEST_ROOT=""
ENGINE_TYPE=""
RESULT_DIR=""
TIMESTAMP=""
TEMP_FILES=()
LAST_TEMP_FILE=""

# Track and clean temporary files created by this script.
register_temp_file() {
    TEMP_FILES+=("$1")
}

cleanup_temp_files() {
    local tmp
    for tmp in "${TEMP_FILES[@]:-}"; do
        [ -n "$tmp" ] && rm -f -- "$tmp"
    done
}

create_temp_sql_file() {
    local prefix="$1"
    local safe_prefix
    local tmp_file
    safe_prefix="${prefix//[^a-zA-Z0-9_.-]/_}"
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/bench_${safe_prefix}.XXXXXX.sql")" || die "Failed to create temporary file"
    register_temp_file "$tmp_file"
    LAST_TEMP_FILE="$tmp_file"
}

trap cleanup_temp_files EXIT

# Load modular components
source "$SCRIPT_DIR/lib/tools_utils.sh"
source "$SCRIPT_DIR/lib/jmx_generator.sh"
source "$SCRIPT_DIR/lib/result.sh"

# Print usage information
usage() {
    cat << EOF
Usage: $0 --config <path-to-benchmark.yaml>

Central benchmark orchestrator for database performance testing.

Options:
  --config FILE    Path to benchmark.yaml configuration file
  --help          Show this help message

Example:
  $0 --config benchmarks/ssb/sf100/snowflake/benchmark.yaml

EOF
}

# Die with error message
die() {
    echo "ERROR: $1" >&2
    exit 1
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
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)
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
    
    # Create timestamped results directory
    TIMESTAMP="$(date '+%Y%m%d_%H%M%S')"
    RESULT_DIR="$SCRIPT_DIR/results/${benchmark_name}_${scale_factor}_${ENGINE_TYPE}_${TIMESTAMP}"
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
    
    # Export connection parameters as environment variables
    while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            # Expand environment variables in the value
            expanded_value=$(eval echo "$value")
            export "$key=$expanded_value"
        fi
    done < <(yq eval '.engine.connection // {} | to_entries | .[] | .key + "=" + .value' "$CONFIG_FILE")
    
    # Export test parameters as environment variables
    while IFS='=' read -r key value; do
        if [ -n "$key" ] && [ -n "$value" ]; then
            # Expand environment variables in the value
            expanded_value=$(eval echo "$value")
            export "$key=$expanded_value"
        fi
    done < <(yq eval '.parameters // {} | to_entries | .[] | .key + "=" + .value' "$CONFIG_FILE")
    
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
    local raw_endpoint raw_region raw_bucket
    raw_endpoint=$(yq eval '.storage.endpoint // ""' "$CONFIG_FILE")
    raw_region=$(yq eval '.storage.region // ""' "$CONFIG_FILE")
    raw_bucket=$(yq eval '.storage.bucket // ""' "$CONFIG_FILE")

    # Expand environment variables (e.g., ${STORAGE_ENDPOINT:-https://...})
    export STORAGE_ENDPOINT=$(eval echo "$raw_endpoint")
    export STORAGE_REGION=$(eval echo "$raw_region")
    export STORAGE_BUCKET=$(eval echo "$raw_bucket")

    echo "Storage: endpoint=$STORAGE_ENDPOINT bucket=$STORAGE_BUCKET"
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
    
    local ddl_path
    ddl_path=$(yq eval '.paths.ddl // "ddl.sql"' "$CONFIG_FILE")
    
    # Convert relative path to absolute
    if [[ "$ddl_path" != /* ]]; then
        ddl_path="$TEST_ROOT/$ddl_path"
    fi
    
    if [ ! -f "$ddl_path" ]; then
        echo "DDL file not found, skipping setup"
        return 0
    fi
    
    echo "Running DDL."
    
    # Keep DDL behavior consistent with load phase so ${STORAGE_*} works in DDL SQL.
    local tmp_sql
    create_temp_sql_file "ddl"
    tmp_sql="$LAST_TEMP_FILE"
    envsubst < "$ddl_path" > "$tmp_sql"
    if ! engine_run_sql_file "$tmp_sql"; then
        rm -f "$tmp_sql"
        die "DDL setup failed"
    fi
    rm -f "$tmp_sql"
}

run_session() {
    local session_path
    session_path=$(yq eval '.paths.session // "session/session.sql"' "$CONFIG_FILE")
    # Convert relative path to absolute
    if [[ "$session_path" != /* ]]; then
        session_path="$TEST_ROOT/$session_path"
    fi
    
    if [ ! -f "$session_path" ]; then
        echo "Session file not found, skipping session setup"
        return 0
    fi
    echo "Running set session."
    local session_content
    session_content=$(envsubst < "$session_path")
    if ! engine_run_sql "" "$session_content"; then
        die "Setup session failed"
    fi
}

# Load data
run_load() {
    local load_dir
    load_dir=$(yq eval '.paths.load_dir // "load/"' "$CONFIG_FILE")
    
    # Convert relative path to absolute
    if [[ "$load_dir" != /* ]]; then
        load_dir="$TEST_ROOT/$load_dir"
    fi
    
    if [ ! -d "$load_dir" ]; then
        echo "Load directory not found, skipping data loading"
        return 0
    fi
    
    echo "Loading data..."
    
    # Initialize load results CSV
    local load_csv="$RESULT_DIR/load.csv"
    echo "table_name,load_time_seconds" > "$load_csv"
    
    # Process all SQL and shell script files in load directory
    local loaded_count=0
    for load_file in "$load_dir"/*.sql "$load_dir"/*.sh; do
        if [ ! -f "$load_file" ]; then
            continue
        fi
        
        local table_name
        table_name=$(basename "$load_file" .sql)
        table_name=$(basename "$table_name" .sh)
        
        echo "Loading $table_name..."
        
        local start_time
        start_time=$(date +%s%3N)
        
        if [[ "$load_file" == *.sh ]]; then
            # Execute shell script for loading
            if ! bash "$load_file"; then
                die "Failed to execute load script: $load_file"
            fi
        elif [[ "$load_file" == *.sql ]]; then
            # Pre-process SQL using envsubst to inject STORAGE_* configs
            local tmp_sql
            create_temp_sql_file "load_${table_name}"
            tmp_sql="$LAST_TEMP_FILE"
            envsubst < "$load_file" > "$tmp_sql"
            
            if ! engine_run_sql_file "$tmp_sql"; then
                rm -f "$tmp_sql"
                die "Failed to execute load SQL file: $load_file"
            fi
            
            # Clean up the temporary injected SQL file after execution
            rm -f "$tmp_sql"
        else
            echo "Skipping unknown file type: $load_file"
        fi
        
        local end_time
        end_time=$(date +%s%3N)
        
        local duration
        duration=$(echo "scale=3; ($end_time - $start_time) / 1000" | bc)
        
        echo "$table_name,$duration" >> "$load_csv"
        echo "    ${duration}s"
        loaded_count=$((loaded_count + 1))
    done
    
    echo "Data loading completed: $loaded_count tables"
}

# Run benchmark queries
run_query() {
    local query_dirs
    while IFS= read -r line; do
        query_dirs+=("$line")
    done < <(yq eval '.paths.query_dirs[]?' "$CONFIG_FILE")
    query_mode=$(yq eval '.paths.query_mode // "file"' "$CONFIG_FILE")
    
    if [ ${#query_dirs[@]} -eq 0 ]; then
        echo "No query directories specified, skipping query execution"
        return 0
    fi
    
    # Collect all queries first
    local -a all_query_names=()
    local -a all_query_sqls=()
    for query_dir in "${query_dirs[@]}"; do
        # Convert relative path to absolute
        if [[ "$query_dir" != /* ]]; then
            query_dir="$TEST_ROOT/$query_dir"
        fi
        
        if [ ! -d "$query_dir" ]; then
            echo "Query directory not found: $query_dir, skipping"
            continue
        fi
        
        echo "Processing queries from $(basename "$query_dir")..."
        # Process all SQL files in directory (sorted numerically)
        while IFS= read -r -d '' query_file; do
            if [ ! -f "$query_file" ]; then
                continue
            fi
            
            local query_name prefix
            query_name=$(basename "$query_file" .sql)
            
            # Add prefix based on directory name for organization
            local dir_name
            dir_name=$(basename "$query_dir")
            if [ "$dir_name" != "query" ] && [ "$dir_name" != "." ]; then
                prefix="${dir_name}_"
            else
                prefix=""
            fi
            
            if [ "$query_mode" = "line" ]; then
                # Line-based mode: each line is a separate query
                local query_counter=1
                while IFS= read -r line || [ -n "$line" ]; do
                    # Skip empty lines and comments
                    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*-- ]]; then
                        continue
                    fi
                    
                    local full_query_name="${prefix}q${query_counter}"
                    # Add to queries array: query_name and sql_content separately
                    all_query_names+=("$full_query_name")
                    all_query_sqls+=("$(printf '%s' "$line" | envsubst)")
                    
                    ((query_counter++))
                done < "$query_file"
            else
                # File-based mode: entire file is one query (default behavior)
                local full_query_name="${prefix}${query_name}"
                
                # Read and escape SQL content
                local sql_content
                sql_content=$(envsubst < "$query_file")
                
                # Add to queries array: query_name and sql_content separately
                all_query_names+=("$full_query_name")
                all_query_sqls+=("$sql_content")
            fi
        done < <(find "$query_dir" -maxdepth 1 -name "*.sql" -type f -print0 | sort -zV)
    done
    
    

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
    
    # Write header to query.csv
    header="query_name,cold_1"
    for ((i=1; i<=query_times-1; i++)); do
        header+=",hot_$i"
    done
    echo "$header" > "$query_csv"
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

        for ((t=1; t<=query_times; t++)); do
            echo "Query run ${query_name} on run $t"
            local start_time
            start_time=$(date +%s%3N)
            if engine_run_sql "${db}" "$sql_content"; then
                local end_time
                end_time=$(date +%s%3N)
                local duration
                duration=$(echo "scale=3; ($end_time - $start_time) / 1000" | bc)
                times_result+=",$duration"
                if [[ "$profile_supported" == "true" && "$profile_enabled" == "true" ]]; then
                    local query_id
                    query_id=$(engine_get_last_query_id 2>/dev/null || true)
                    if [ -n "$query_id" ]; then
                        profile_query_names+=("${safe_query_name}")
                        profile_query_runs+=("${t}")
                        profile_query_ids+=("${query_id}")
                    else
                        echo "Failed to get query id for ${query_name} run $t" >&2
                    fi
                fi
            else
                times_result+=",null"
                echo "Query execution failed ${query_name} on run $t" >&2
            fi
        done
        echo "$times_result" >> "$query_csv"
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
    echo "Running analysis..."
    local raw_analyze_sql
    raw_analyze_sql=$(yq eval '.paths.analyze // "analyze/analyze.sql"' "$CONFIG_FILE")
    local analyze_sql
    analyze_sql="$(eval echo "$raw_analyze_sql")"
    
    if [[ "$analyze_sql" != /* ]]; then
        analyze_sql="$TEST_ROOT/$analyze_sql"
    fi
    
    if [ -z "$analyze_sql" ] || [ "$analyze_sql" = "null" ]; then
        echo "No analysis SQL provided, skipping"
        return 0
    fi
    
    
    local tmp_sql
    create_temp_sql_file "analyze"
    tmp_sql="$LAST_TEMP_FILE"
    envsubst < "$analyze_sql" > "$tmp_sql"

    if engine_run_sql_file "$tmp_sql"; then
        rm -f "$tmp_sql"
        echo "Analysis completed"
    else
        rm -f "$tmp_sql"
        die "Analysis failed"
    fi
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
    
    # Check framework dependencies (now that jmeter flag is known)
    check_dependencies
    
    # Load other parameters
    session="${session:-false}"
    load="${load:-false}"
    analyze="${analyze:-false}"
    query="${query:-false}"
    query_times="${query_times:-1}"
    db="${db:-}"
    drop_database="${drop_database:-${DROP_DATABASE:-true}}"
    clean_trash="${clean_trash:-${CLEAN_TRASH:-false}}"
    profile="${profile:-${PROFILE:-false}}"
    plan="${plan:-${PLAN:-false}}"

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
    
    # Load and initialize engine
    load_engine
    init_engine
    
    # Run benchmark workflow
    echo "Starting benchmark: $ENGINE_TYPE"
    # TODO(zgx): add prepare set session ..
    if [[ "$session" != "true" ]]; then
        echo "Session setup disabled, skipping"
    else
        run_session
    fi
    if [[ "$load" != "true" ]]; then
        echo "Data loading disabled, skipping"
    else
        run_ddl
        run_load
    fi
    
    if [[ "$analyze" != "true" ]]; then
        echo "Analysis disabled, skipping"
    else
        run_analyze
    fi
    if [[ "$query" != "true" ]]; then
        echo "Query execution disabled, skipping"
    else
        run_query
    fi
    if [[ "$jmeter" != "true" ]]; then
        echo "JMeter execution disabled, skipping"
    else
        generate_jmx
        run_jmeter
    fi
    
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
