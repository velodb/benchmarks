#!/bin/bash
# Doris Database Engine Implementation
#
# This engine implements the benchmark framework interface for Doris databases.
# Doris uses MySQL protocol for connections.
#
# Required environment variables:
# - fe_host: Doris Frontend host address
# - fe_http_port: HTTP port for Doris Frontend (default: 8030)
# - fe_query_port: Query port for Doris Frontend (default: 9030)
# - user: Doris username
# - password: Doris password
# - db: Doris database name

# Source the interface for utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/interface.sh"

# Load JDBC utilities
source "$(dirname "${BASH_SOURCE[0]}")/../lib/jdbc_utils.sh"

BE_HOSTS_ARR=()

any_clear_cache_enabled() {
    [[ "${clear_file_cache:-false}" == "true" \
    || "${clear_page_cache:-false}" == "true" \
    || "${clear_sys_page_cache:-false}" == "true" ]]
}

parse_be_hosts() {
    BE_HOSTS_ARR=()
    local raw="${be_hosts:-}"
    [ -z "$raw" ] && return 0
    IFS=',' read -r -a BE_HOSTS_ARR <<< "$raw"
    local i
    for i in "${!BE_HOSTS_ARR[@]}"; do
        BE_HOSTS_ARR[$i]="$(echo "${BE_HOSTS_ARR[$i]}" | xargs)"
    done
}

should_clear_cache_for_run() {
    local run_index="$1"
    any_clear_cache_enabled || return 1
    [[ "${clear_cache_scope:-cold}" == "every_run" ]] && return 0
    [[ "$run_index" -eq 1 ]]
}

# 1. Initialize and check Doris dependencies
engine_init() {
    echo "Initializing Doris engine..."

    if declare -f init_mysql_client >/dev/null 2>&1; then
        init_mysql_client || return 1
    fi
    
    # Initialize MySQL JDBC driver for JMeter if needed
    if [[ "${jmeter:-}" == "true" ]] && [ -n "${JMETER_HOME:-}" ]; then
        init_mysql_jdbc_driver
    fi
    
    # Validate required connection parameters
    if [ -z "${fe_host:-}" ]; then
        echo "ERROR: Missing required parameter: fe_host" >&2
        return 1
    fi
    
    # Check required command-line tools
    local missing_deps=()
    for cmd in mysql; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ "${profile:-}" == "true" ]]; then
        for cmd in curl; do
            if ! command -v "$cmd" >/dev/null 2>&1; then
                missing_deps+=("$cmd")
            fi
        done
    fi
    
    if [[ "${clear_file_cache:-false}" == "true" || "${clear_page_cache:-false}" == "true" ]]; then
        if ! command -v curl >/dev/null 2>&1; then
            missing_deps+=("curl")
        fi
    fi
    if [[ "${clear_sys_page_cache:-false}" == "true" ]]; then
        if ! command -v ssh >/dev/null 2>&1; then
            missing_deps+=("ssh")
        fi
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "ERROR: Missing required dependencies: ${missing_deps[*]}" >&2
        echo "Please install the missing tools and try again." >&2
        return 1
    fi
    
    # Set default ports if not provided
    fe_http_port="${fe_http_port:-8030}"
    fe_query_port="${fe_query_port:-9030}"
    be_http_port="${be_http_port:-8040}"
    be_brpc_port="${be_brpc_port:-8060}"
    
    # Check required environment variables
    local missing_vars=()
    for var in fe_host user db; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        echo "ERROR: Missing required environment variables: ${missing_vars[*]}" >&2
        echo "Please set these variables in your benchmark.yaml configuration." >&2
        return 1
    fi
    
    if any_clear_cache_enabled; then
        parse_be_hosts
        if [ "${#BE_HOSTS_ARR[@]}" -eq 0 ]; then
            echo "ERROR: be_hosts parsed to empty list: ${be_hosts}" >&2
            return 1
        fi
        echo "cache-clear BEs: ${BE_HOSTS_ARR[*]}"
    fi

    echo "Initialized ${ENGINE_TYPE:-Doris}: $fe_host:$fe_query_port/$db"
    return 0
}

# 2. Execute a SQL file using mysql client
engine_run_sql_file() {
    local sql_file="$1"
    local error_file=""
    local status=0
    
    if [ ! -f "$sql_file" ]; then
        echo "ERROR: SQL file not found: $sql_file" >&2
        return 1
    fi
    
    # Set password environment variable for mysql
    export MYSQL_PWD="${password:-}"

    error_file="$(mktemp "${TMPDIR:-/tmp}/doris_mysql_stderr.XXXXXX")" || {
        echo "ERROR: Failed to create temporary stderr file" >&2
        return 1
    }
    
    # Execute the SQL file
    if mysql \
    -h"$fe_host" \
    -P"$fe_query_port" \
    -u"$user" \
    -D"$db" \
    2>"$error_file" \
    < "$sql_file"; then
        rm -f "$error_file"
        return 0
    else
        status=$?
        echo "ERROR: Failed to execute SQL file: $sql_file" >&2
        if [ -s "$error_file" ]; then
            cat "$error_file" >&2
        fi
        rm -f "$error_file"
        return "$status"
    fi
}

# 2.1. Execute a SQL statement using mysql client
engine_run_sql() {
    local db="$1"
    local sql_statement="$2"
    local capture_last_query_id="${3:-true}"
    local error_file=""
    local status=0
    
    if [ -z "$sql_statement" ]; then
        echo "ERROR: SQL statement cannot be empty" >&2
        return 1
    fi
    
    # Set password environment variable for mysql
    export MYSQL_PWD="${password:-}"
    
    # Build mysql command arguments
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")
    [ -n "${catalog:-}" ] && [ -n "$db" ] && db="${catalog}.${db}"
    [ -n "$db" ] && args+=(-D"$db")
    
    local mysql_sql="$sql_statement"
    if [ "$capture_last_query_id" = "true" ]; then
        local normalized_sql
        normalized_sql=$(printf '%s' "$sql_statement" | sed -e ':trim' -e 's/[[:space:]]*$//' \
            -e '/;$/ { s/;*$//; b trim; }')
        mysql_sql="${normalized_sql}; select last_query_id();"
    fi

    local last_query_id_file="${RESULT_DIR:-/tmp}/.last_query_id"
    error_file="$(mktemp "${TMPDIR:-/tmp}/doris_mysql_stderr.XXXXXX")" || {
        echo "ERROR: Failed to create temporary stderr file" >&2
        return 1
    }
    if output=$(mysql "${args[@]}" --batch --skip-column-names \
        -e "$mysql_sql" 2>"$error_file"); then
        rm -f "$error_file"
        if [ "$capture_last_query_id" = "true" ]; then
            # The last non-empty line of stdout is the query ID.
            echo "$output" | tail -n 1 > "$last_query_id_file"
        fi
        return 0
    else
        status=$?
        echo "ERROR: Failed to execute SQL statement: $sql_statement" >&2
        if [ -s "$error_file" ]; then
            cat "$error_file" >&2
        fi
        rm -f "$error_file"
        return "$status"
    fi
}

engine_set_auto_analyze() {
    local enabled="$1"
    local value="false"
    if [ "$enabled" = "true" ]; then
        value="true"
    fi

    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -e "set global enable_auto_analyze=${value};" >/dev/null 2>&1
}

engine_list_tables() {
    local db_name="$1"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user" -N -s)

    if [ -n "${catalog:-}" ]; then
        db_name="${catalog}.${db_name}"
    fi
    [ -n "$db_name" ] && args+=(-D"$db_name")

    export MYSQL_PWD="${password:-}"
    mysql "${args[@]}" -e "SHOW TABLES;" 2>/dev/null
}

engine_drop_stats() {
    local db_name="$1"
    local table="$2"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")

    if [ -n "${catalog:-}" ]; then
        db_name="${catalog}.${db_name}"
    fi
    [ -n "$db_name" ] && args+=(-D"$db_name")

    export MYSQL_PWD="${password:-}"
    mysql "${args[@]}" -e "DROP STATS ${table};" >/dev/null 2>&1
}

engine_analyze_table() {
    local db_name="$1"
    local table="$2"
    local analyze_type="$3"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")
    local sql=""

    if [ -n "${catalog:-}" ]; then
        db_name="${catalog}.${db_name}"
    fi
    [ -n "$db_name" ] && args+=(-D"$db_name")

    case "${analyze_type}" in
        analyze_full)
            sql="analyze table ${table} with sync"
        ;;
        analyze_sample)
            sql="analyze table ${table} WITH SAMPLE ROWS 4000000 with sync"
        ;;
        analyze_no|analyze_default)
            return 0
        ;;
        *)
            echo "Unsupported analyze type for Doris: ${analyze_type}" >&2
            return 1
        ;;
    esac

    export MYSQL_PWD="${password:-}"
    mysql "${args[@]}" -e "${sql};" 2>&1
}

engine_show_column_stats() {
    local db_name="$1"
    local table="$2"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")

    if [ -n "${catalog:-}" ]; then
        db_name="${catalog}.${db_name}"
    fi
    [ -n "$db_name" ] && args+=(-D"$db_name")

    export MYSQL_PWD="${password:-}"
    mysql "${args[@]}" -e "show column stats ${table};" >/dev/null 2>&1
}

engine_get_table_rows() {
    local table="$1"
    local host="${fe_host:-127.0.0.1}"
    local port="${fe_query_port:-9030}"
    local sys_user="${user:-root}"
    local current_db="${db:-}"
    local qualified_table="$table"

    if [ -n "${catalog:-}" ] && [ -n "$current_db" ]; then
        current_db="${catalog}.${current_db}"
    fi

    # Support bare table names in benchmark.yaml tables config when a catalog
    # is configured, while still allowing callers to pass db.table or
    # catalog.db.table explicitly.
    if [[ "$qualified_table" != *.* ]] && [ -n "${catalog:-}" ] && [ -n "${db:-}" ]; then
        qualified_table="${catalog}.${db}.${qualified_table}"
    fi

    # Do not use `export MYSQL_PWD` to avoid environment pollution
    MYSQL_PWD="${password:-}" mysql -h"${host}" -P"${port}" -u"${sys_user}" "${current_db}" \
        -N -s -e "SELECT COUNT(*) FROM ${qualified_table};" 2>/dev/null || echo "0"

    return 0
}

# Check S3 load status
engine_check_load_status() {
    mysql_engine_check_load_status "$@"
}

# Port of selectdb-qa ClearSystemPageCache:
#   ssh root@<be> "echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null"
clear_system_page_cache() {
    local ssh_user="${clear_cache_ssh_user:-root}"
    local be
    for be in "${BE_HOSTS_ARR[@]}"; do
        echo "[${be}] ssh drop_caches"
        if ! ssh -o StrictHostKeyChecking=no -o BatchMode=yes \
                "${ssh_user}@${be}" \
                "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null"; then
            echo "drop_caches failed on ${be}" >&2
            return 1
        fi
    done
    sleep 3
    return 0
}

# Port of selectdb-qa ClearDorisPageCache:
#   POST api/update_config?cache_periodic_prune_stale_sweep_sec=5
#   POST api/update_config?disable_storage_page_cache=true   (wait 10s)
#   POST api/update_config?disable_storage_page_cache=false  (wait 10s)
clear_doris_page_cache() {
    local port="${be_http_port:-8040}"
    local be
    for be in "${BE_HOSTS_ARR[@]}"; do
        echo "[${be}] POST cache_periodic_prune_stale_sweep_sec=5"
        if ! curl -fsS -X POST "http://${be}:${port}/api/update_config?cache_periodic_prune_stale_sweep_sec=5"; then
            echo "update_config prune_sweep_sec failed on ${be}" >&2
            return 1
        fi
        echo
        echo "[${be}] POST disable_storage_page_cache=true"
        if ! curl -fsS -X POST "http://${be}:${port}/api/update_config?disable_storage_page_cache=true"; then
            echo "update_config disable=true failed on ${be}" >&2
            return 1
        fi
        echo
    done
    echo "wait 10s"
    sleep 10
    for be in "${BE_HOSTS_ARR[@]}"; do
        echo "[${be}] POST disable_storage_page_cache=false"
        if ! curl -fsS -X POST "http://${be}:${port}/api/update_config?disable_storage_page_cache=false"; then
            echo "update_config disable=false failed on ${be}" >&2
            return 1
        fi
        echo
    done
    echo "wait 10s"
    sleep 10
    return 0
}

# Extract file_cache_cache_size values from brpc_metrics output (one per disk)
_parse_file_cache_sizes() {
    awk '/file_cache_cache_size/ && !/gauge/ && !/HELP/ {print $NF}'
}

# Port of selectdb-qa ClearDorisFileCache:
#   GET api/file_cache?op=clear&sync=false on each BE
#   sleep 60, then every 30s poll brpc_metrics until every disk on every BE
#   has file_cache_cache_size < max_size_gb * 1GB; re-trigger clear on BEs
#   still above threshold. Timeout after timeout_min minutes.
clear_doris_file_cache() {
    local http_port="${be_http_port:-8040}"
    local brpc_port="${be_brpc_port:-8060}"
    local max_gb="${clear_file_cache_max_size_gb:-2}"
    local timeout_min="${clear_file_cache_timeout_min:-60}"
    local max_bytes
    max_bytes=$(awk -v g="$max_gb" 'BEGIN{printf "%.0f", g*1024*1024*1024}')
    local be
    for be in "${BE_HOSTS_ARR[@]}"; do
        echo "[${be}] GET api/file_cache?op=clear&sync=false"
        if ! curl -fsS "http://${be}:${http_port}/api/file_cache?op=clear&sync=false"; then
            echo "clear file_cache failed on ${be}" >&2
            return 1
        fi
        echo
    done
    echo "wait 60s for async clear"
    sleep 60

    local deadline
    deadline=$(( $(date +%s) + timeout_min * 60 ))
    while :; do
        local all_below="true"
        local need_reclear=()
        for be in "${BE_HOSTS_ARR[@]}"; do
            local metrics
            if ! metrics=$(curl -fsS "http://${be}:${brpc_port}/brpc_metrics" 2>/dev/null); then
                echo "[${be}] failed to fetch brpc_metrics" >&2
                all_below="false"
                continue
            fi
            local sizes
            sizes=$(echo "$metrics" | _parse_file_cache_sizes)
            if [ -z "$sizes" ]; then
                echo "[${be}] file_cache_cache_size metric not found" >&2
                all_below="false"
                continue
            fi
            local node_below="true"
            local idx=0
            local size
            while IFS= read -r size; do
                idx=$((idx+1))
                local gb
                gb=$(awk -v s="$size" 'BEGIN{printf "%.2f", s/1024/1024/1024}')
                echo "[${be}] disk ${idx} cache size: ${gb} GB"
                if awk -v s="$size" -v m="$max_bytes" 'BEGIN{exit !(s>=m)}'; then
                    node_below="false"
                fi
            done <<< "$sizes"
            if [[ "$node_below" != "true" ]]; then
                all_below="false"
                need_reclear+=("$be")
            fi
        done

        if [[ "$all_below" == "true" ]]; then
            echo "all disks on all BEs below ${max_gb}GB"
            return 0
        fi

        if [ "${#need_reclear[@]}" -gt 0 ]; then
            echo "re-clearing BEs still above threshold: ${need_reclear[*]}"
            for be in "${need_reclear[@]}"; do
                echo "[${be}] GET api/file_cache?op=clear&sync=false (re-clear)"
                curl -fsS "http://${be}:${http_port}/api/file_cache?op=clear&sync=false" || \
                    echo "re-clear failed on ${be}" >&2
                echo
            done
        fi

        if [ "$(date +%s)" -ge "$deadline" ]; then
            echo "timeout waiting for file cache to drop below ${max_gb}GB" >&2
            return 1
        fi
        sleep 30
    done
}

run_clear_cache_actions() {
    local query_name="$1"
    local run_index="$2"
    echo "Clearing cache before query ${query_name} run ${run_index}..."

    if [[ "${clear_file_cache:-false}" == "true" ]]; then
        clear_doris_file_cache || return 1
    fi
    if [[ "${clear_page_cache:-false}" == "true" ]]; then
        clear_doris_page_cache || return 1
    fi
    if [[ "${clear_sys_page_cache:-false}" == "true" ]]; then
        clear_system_page_cache || return 1
    fi
    return 0
}

# 3. Generate JDBC DataSource XML configuration for Doris
engine_get_jdbc_datasource() {
    # Escape any special characters in the password
    local escaped_password
    escaped_password=$(xml_escape "${password:-}")
    
    cat << EOF
<JDBCDataSource guiclass="TestBeanGUI" testclass="JDBCDataSource" testname="JDBC Connection Configuration" enabled="true">
  <boolProp name="autocommit">true</boolProp>
  <stringProp name="checkQuery">SELECT 1</stringProp>
  <stringProp name="connectionAge">5000</stringProp>
  <stringProp name="connectionProperties"></stringProp>
  <stringProp name="dataSource">${ENGINE_TYPE:-Doris}</stringProp>
  <stringProp name="dbUrl">jdbc:mysql://${fe_host}:${fe_query_port}/${db}</stringProp>
  <stringProp name="driver">com.mysql.cj.jdbc.Driver</stringProp>
  <stringProp name="keepAlive">true</stringProp>
  <stringProp name="password">${escaped_password}</stringProp>
  <stringProp name="poolMax">0</stringProp>
  <stringProp name="timeout">10000</stringProp>
  <stringProp name="transactionIsolation">DEFAULT</stringProp>
  <stringProp name="trimInterval">60000</stringProp>
  <stringProp name="username">${user}</stringProp>
</JDBCDataSource>
EOF
}

# 4. Get JDBC Sampler DataSource Name
engine_get_jdbc_sampler_name() {
    echo "${ENGINE_TYPE:-Doris}"
}

# Optional: enable query profile collection
engine_enable_profile() {
    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -e "set global enable_profile=true;" >/dev/null 2>&1
}

# Optional: disable query profile collection
engine_disable_profile() {
    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -e "set global enable_profile=false;" >/dev/null 2>&1
}

# Optional: get last query id (best effort)
engine_get_last_query_id() {
    local last_query_id_file="${RESULT_DIR:-/tmp}/.last_query_id"
    if [ -f "$last_query_id_file" ]; then
        cat "$last_query_id_file"
    else
        # Fallback
        export MYSQL_PWD="${password:-}"
        mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -N -e "show query profile '/' limit 1;" 2>/dev/null | awk '{print $1}'
    fi
}

# Optional: fetch profile content by query id
engine_fetch_profile() {
    local query_id="$1"
    if [ -z "$query_id" ]; then
        return 1
    fi
    echo -e "$(curl -s -u "${user}:${password:-}" "http://${fe_host}:${fe_http_port}/rest/v2/manager/query/profile/text/${query_id}" 2>/dev/null)"
}

# Optional: fetch plan text for a query
engine_get_plan() {
    local db_name="$1"
    local sql_statement="$2"
    export MYSQL_PWD="${password:-}"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user" -N -s)
    [ -n "${catalog:-}" ] && db_name="${catalog}.${db_name}"
    [ -n "$db_name" ] && args+=(-D"$db_name")
    mysql "${args[@]}" -e "explain memo plan ${sql_statement}" 2>/dev/null || true
}

# Optional: Fetch engine version
engine_get_version() {
    export MYSQL_PWD="${password:-}"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")
    [ -n "${db:-}" ] && args+=(-D"$db")

    local version
    version=$(mysql "${args[@]}" -N -s -e "SHOW VARIABLES LIKE 'version_comment';" 2>/dev/null | cut -f2- || true)
    if [ -z "$version" ]; then
        version=$(mysql "${args[@]}" -N -s -e "SELECT VERSION();" 2>/dev/null | head -n 1 || true)
    fi
    echo "$version"
}

# Optional: Fetch total data size in bytes
engine_get_data_size_bytes() {
    export MYSQL_PWD="${password:-}"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")
    mysql "${args[@]}" -N -s -e "SELECT IFNULL(SUM(DATA_LENGTH + INDEX_LENGTH),0) FROM information_schema.tables WHERE table_schema='${db}';" 2>/dev/null || true
}

# Helper function to create database (used in DDL setup)
engine_create_database() {
    export MYSQL_PWD="${password:-}"
    local args=(
        -h"$fe_host"
        -P"$fe_query_port"
        -u"$user"
    )

    local do_drop="${drop_database:-true}"

    if [ "$do_drop" = "true" ]; then
        if mysql "${args[@]}" -e "DROP DATABASE IF EXISTS ${db}" && mysql "${args[@]}" -e "CREATE DATABASE IF NOT EXISTS ${db}" ; then
            return 0
        else
            echo "ERROR: Failed to create database: $db" >&2
            return 1
        fi
    fi

    if mysql "${args[@]}" -e "CREATE DATABASE IF NOT EXISTS ${db}" ; then
        return 0
    else
        echo "ERROR: Failed to create database: $db" >&2
        return 1
    fi
}
# Optional: drop database if requested by orchestrator
engine_drop_database() {
    export MYSQL_PWD="${password:-}"
    local args=(
        -h"$fe_host"
        -P"$fe_query_port"
        -u"$user"
    )

    if mysql "${args[@]}" -e "DROP DATABASE IF EXISTS ${db}"; then
        return 0
    else
        echo "ERROR: Failed to drop database: $db" >&2
        return 1
    fi
}
# Optional: clean trash if supported
engine_clean_trash() {
    export MYSQL_PWD="${password:-}"
    local args=(
        -h"$fe_host"
        -P"$fe_query_port"
        -u"$user"
    )

    if mysql "${args[@]}" -e "ADMIN CLEAN TRASH"; then
        return 0
    else
        echo "ERROR: Failed to clean trash" >&2
        return 1
    fi
}

# Optional: Custom generic load implementation for Doris
engine_load_data() {
    mysql_engine_load_data "$@"
}
