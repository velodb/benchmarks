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

# 1. Initialize and check Doris dependencies
engine_init() {
    echo "Initializing Doris engine..."
    
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
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "ERROR: Missing required dependencies: ${missing_deps[*]}" >&2
        echo "Please install the missing tools and try again." >&2
        return 1
    fi
    
    # Set default ports if not provided
    fe_http_port="${fe_http_port:-8030}"
    fe_query_port="${fe_query_port:-9030}"
    
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
    
    echo "Initialized ${ENGINE_TYPE:-Doris}: $fe_host:$fe_query_port/$db"
    return 0
}

# 2. Execute a SQL file using mysql client
engine_run_sql_file() {
    local sql_file="$1"
    
    if [ ! -f "$sql_file" ]; then
        echo "ERROR: SQL file not found: $sql_file" >&2
        return 1
    fi
    
    # Set password environment variable for mysql
    export MYSQL_PWD="${password:-}"
    
    # Execute the SQL file
    if mysql \
    -h"$fe_host" \
    -P"$fe_query_port" \
    -u"$user" \
    -D"$db" \
    < "$sql_file"; then
        return 0
    else
        echo "ERROR: Failed to execute SQL file: $sql_file" >&2
        return 1
    fi
}

# 2.1. Execute a SQL statement using mysql client
engine_run_sql() {
    local db="$1"
    local sql_statement="$2"
    
    if [ -z "$sql_statement" ]; then
        echo "ERROR: SQL statement cannot be empty" >&2
        return 1
    fi
    
    # Set password environment variable for mysql
    export MYSQL_PWD="${password:-}"
    
    # Build mysql command arguments
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")
    [ -n "${catalog:-}" ] && db="${catalog}.${db}"
    [ -n "$db" ] && args+=(-D"$db")
    
    # Execute the SQL statement and select last_query_id() sequentially.
    # Use --batch --skip-column-names to get clean output without headers,
    # and keep stderr separate to avoid contaminating the query ID.
    local last_query_id_file="${RESULT_DIR:-/tmp}/.last_query_id"
    if output=$(mysql "${args[@]}" --batch --skip-column-names \
        -e "$sql_statement; select last_query_id();" 2>/dev/null); then
        # The last non-empty line of stdout is the query ID
        echo "$output" | tail -n 1 > "$last_query_id_file"
        return 0
    else
        echo "ERROR: Failed to execute SQL statement: $sql_statement" >&2
        return 1
    fi
}

engine_get_table_rows() {
    local table="$1"
    local host="${fe_host:-127.0.0.1}"
    local port="${fe_query_port:-9030}"
    local sys_user="${user:-root}"

    # Do not use `export MYSQL_PWD` to avoid environment pollution
    MYSQL_PWD="${password:-}" mysql -h"${host}" -P"${port}" -u"${sys_user}" "${db}" \
        -N -s -e "SELECT COUNT(*) FROM ${table};" 2>/dev/null || echo "0"

    return 0
}

# Check S3 load status
engine_check_load_status() {
    local label="$1"
    local host="${fe_host:-127.0.0.1}"
    local port="${fe_query_port:-9030}"
    local sys_user="${user:-root}"

    MYSQL_PWD="${password:-}" mysql -h"${host}" -P"${port}" -u"${sys_user}" "${db}" \
        -e "SHOW LOAD WHERE Label = '${label}'\\G" 2>/dev/null
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
    curl -s -u "${user}:${password:-}" "http://${fe_host}:${fe_http_port}/rest/v2/manager/query/profile/text/${query_id}" 2>/dev/null
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
    local detected_method="$1"
    local load_file="$2"
    local table_name="$3"
    local load_output=""

    if [[ "$detected_method" == "stream_load" ]]; then
        if load_output=$(bash "$load_file" 2>&1); then
            echo "$load_output"
        else
            echo "$load_output" >&2
            echo "ERROR: Failed to execute load script: $load_file" >&2
            return 1
        fi
    elif [[ "$detected_method" == "s3_load" ]]; then
        # S3 Broker Load is async — submit then poll SHOW LOAD
        local tmp_sql
        create_temp_sql_file "load_${table_name}"
        tmp_sql="$LAST_TEMP_FILE"
        envsubst < "$load_file" > "$tmp_sql"

        if ! engine_run_sql_file "$tmp_sql"; then
            rm -f "$tmp_sql"
            echo "ERROR: Failed to submit S3 load: $load_file" >&2
            return 1
        fi
        rm -f "$tmp_sql"

        local load_label="${table_name}_${TIMESTAMP}"
        echo "    Waiting for S3 load to complete (label: $load_label)..."
        # Poll load status every 10 seconds
        local max_wait=36000
        local waited=0
        while [ $waited -lt $max_wait ]; do
            sleep 10
            waited=$((waited + 10))

            local status_output
            status_output=$(engine_check_load_status "$load_label")

            if echo "$status_output" | grep -q "FINISHED"; then
                echo "    S3 load completed successfully"
                break
            elif echo "$status_output" | grep -q "CANCELLED"; then
                echo "$status_output"
                echo "ERROR: S3 load cancelled" >&2
                return 1
            fi

            # Print progress every minute
            if [ $((waited % 60)) -eq 0 ]; then
                local progress
                progress=$(echo "$status_output" | grep -oP 'Progress: \K[^|]+' || echo "unknown")
                echo "    [$waited s] Progress: $progress"
            fi
        done

        if [ $waited -ge $max_wait ]; then
            echo "ERROR: S3 load timeout after ${max_wait}s" >&2
            return 1
        fi
    elif [[ "$detected_method" == "insert_into" ]]; then
        local tmp_sql
        create_temp_sql_file "load_${table_name}"
        tmp_sql="$LAST_TEMP_FILE"
        envsubst < "$load_file" > "$tmp_sql"

        if ! engine_run_sql_file "$tmp_sql"; then
            rm -f "$tmp_sql"
            echo "ERROR: Failed to execute load SQL file: $load_file" >&2
            return 1
        fi
        rm -f "$tmp_sql"
    else
        echo "ERROR: Unknown load method: $detected_method" >&2
        return 1
    fi
}

engine_check_load_status() {
    local label="$1"
    export MYSQL_PWD="${password:-}"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")
    [ -n "${db:-}" ] && args+=(-D"$db")
    mysql "${args[@]}" -e "SHOW LOAD WHERE Label = '$label' \G" 2>/dev/null || true
}
