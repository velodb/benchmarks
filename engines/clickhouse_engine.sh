#!/bin/bash
# ClickHouse Database Engine Implementation
#
# This engine implements the benchmark framework interface for ClickHouse databases.
#
# Required environment variables:
# - clickhouse_host: ClickHouse server host address
# - user: ClickHouse username (default: 'default')
# - password: ClickHouse password
# - db: ClickHouse database name
# - secure: Whether to use secure connection (default: true)

# Source the interface for utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/interface.sh"

# Load JDBC utilities
source "$(dirname "${BASH_SOURCE[0]}")/../lib/jdbc_utils.sh"

# Load client utilities
source "$(dirname "${BASH_SOURCE[0]}")/../lib/client_utils.sh"

# ClickHouse command path (will be set in engine_init)
CLICKHOUSE_CMD=""

# 1. Initialize and check ClickHouse dependencies
engine_init() {
    echo "Initializing ClickHouse engine..."

    # Initialize ClickHouse JDBC driver for JMeter if needed
    if [[ "${jmeter:-}" == "true" ]] && [ -n "${JMETER_HOME:-}" ]; then
        init_clickhouse_jdbc_driver
    fi

    # Check for clickhouse: use system version if available, otherwise use tools directory
    if command -v clickhouse-client >/dev/null 2>&1; then
        CLICKHOUSE_CMD="clickhouse-client"
        elif command -v clickhouse >/dev/null 2>&1; then
        CLICKHOUSE_CMD="clickhouse client"
        elif [ -x "${SCRIPT_DIR}/../tools/clickhouse" ]; then
        CLICKHOUSE_CMD="${SCRIPT_DIR}/../tools/clickhouse client"
        echo "Using clickhouse from tools directory: ${SCRIPT_DIR}/../tools/clickhouse"
    else
        echo "ERROR: clickhouse not found in system PATH or tools directory" >&2
        echo "Please install clickhouse or place it in the tools directory." >&2
        return 1
    fi

    # Set defaults
    user="${user:-default}"
    # Check required environment variables
    local missing_vars=()
    for var in clickhouse_host db; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -ne 0 ]; then
        echo "ERROR: Missing required environment variables: ${missing_vars[*]}" >&2
        echo "Please set these variables in your benchmark.yaml configuration." >&2
        return 1
    fi

    echo "Initialized ClickHouse: $clickhouse_host/$db"
    return 0
}

# 2. Execute a SQL file using clickhouse client
engine_run_sql_file() {
    local sql_file="$1"
    local apply_session="${2:-true}"
    local exec_file
    local temp_file=""

    if [ ! -f "$sql_file" ]; then
        echo "ERROR: SQL file not found: $sql_file" >&2
        return 1
    fi

    # Build clickhouse client command
    local args=(
        "--host=$clickhouse_host"
        "--user=$user"
        "--database=$db"
    )

    # Add password if provided
    if [ -n "${password:-}" ]; then
        args+=("--secure")
        args+=("--password=$password")
    fi

    exec_file="$(engine_prepare_sql_file_with_session "$sql_file" "$apply_session" "clickhouse_sql")" || return 1
    if [ "$exec_file" != "$sql_file" ]; then
        temp_file="$exec_file"
    fi

    # Execute the SQL file
    if $CLICKHOUSE_CMD "${args[@]}" --multiquery < "$exec_file"; then
        [ -n "$temp_file" ] && rm -f "$temp_file"
        return 0
    else
        [ -n "$temp_file" ] && rm -f "$temp_file"
        echo "ERROR: Failed to execute SQL file: $sql_file" >&2
        return 1
    fi
}

# 2.1. Execute a SQL statement using clickhouse client
engine_run_sql() {
    local db="$1"
    local sql_statement="$2"
    local apply_session="${3:-true}"
    local clickhouse_sql

    if [ -z "$sql_statement" ]; then
        echo "ERROR: SQL statement cannot be empty" >&2
        return 1
    fi

    # Build clickhouse client command
    local args=(
        "--host=$clickhouse_host"
        "--user=$user"
    )

    # Add password if provided
    if [ -n "${password:-}" ]; then
        args+=("--secure")
        args+=("--password=$password")
    fi
    [ -n "$db" ] && args+=("--database=$db")
    clickhouse_sql="$(engine_prepend_session_sql "$sql_statement" "$apply_session")"

    # Execute the SQL statement
    if $CLICKHOUSE_CMD "${args[@]}" --multiquery --query="$clickhouse_sql"; then
        return 0
    else
        echo "ERROR: Failed to execute SQL statement: $sql_statement" >&2
        return 1
    fi
}

# 2.2. Get row count of a loaded table
engine_get_table_rows() {
    local table="$1"
    local args=(
        "--host=$clickhouse_host"
        "--user=$user"
        "--database=$db"
    )

    if [ -n "${password:-}" ]; then
        args+=("--secure" "--password=$password")
    fi

    local count
    count="$($CLICKHOUSE_CMD "${args[@]}" --query="SELECT count() FROM ${table};" 2>/dev/null || true)"
    count="${count%%$'\n'*}"
    count="${count//$'\r'/}"

    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi

    return 0
}

# 3. Generate JDBC DataSource XML configuration for ClickHouse
engine_get_jdbc_datasource() {
    # Escape any special characters in the password
    local escaped_password
    escaped_password=$(xml_escape "${password:-}")
    local max_execution_time=$((duration))
    # Build JDBC URL
    local jdbc_url="jdbc:clickhouse://${clickhouse_host}:8443/${db}?ssl=true&connection_timeout=10000&socket_timeout=600000&max_execution_time=${max_execution_time}"
    local jdbc_safe_url=$(echo "$jdbc_url" | sed 's/&/\&amp;/g')
    cat << EOF
<JDBCDataSource guiclass="TestBeanGUI" testclass="JDBCDataSource" testname="JDBC Connection Configuration" enabled="true">
  <boolProp name="autocommit">true</boolProp>
  <stringProp name="checkQuery">SELECT 1</stringProp>
  <stringProp name="connectionAge">5000</stringProp>
  <stringProp name="connectionProperties"></stringProp>
  <stringProp name="dataSource">clickhouse</stringProp>
  <stringProp name="dbUrl">${jdbc_safe_url}</stringProp>
  <stringProp name="driver">com.clickhouse.jdbc.ClickHouseDriver</stringProp>
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
    echo "clickhouse"
}

# Optional: enable profile collection (no-op)

# Optional: Fetch engine version
engine_get_version() {
    local args=(
        "--host=$clickhouse_host"
        "--user=$user"
    )
    if [ -n "${password:-}" ]; then
        args+=("--secure" "--password=$password")
    fi
    local version
    version="$($CLICKHOUSE_CMD "${args[@]}" --query "SELECT version()" 2>/dev/null || true)"
    echo "$version" | head -n 1
}

# Optional: Fetch total data size in bytes
engine_get_data_size_bytes() {
    local args=(
        "--host=$clickhouse_host"
        "--user=$user"
    )
    if [ -n "${password:-}" ]; then
        args+=("--secure" "--password=$password")
    fi
    local size
    size="$($CLICKHOUSE_CMD "${args[@]}" --query "SELECT ifNull(sum(total_bytes),0) FROM system.tables WHERE database = '${db}'" 2>/dev/null || true)"
    echo "$size" | head -n 1
}

# Helper function to create database (used in DDL setup)
engine_create_database() {
    # Build clickhouse client command
    local args=(
        "--host=$clickhouse_host"
        "--user=$user"
    )

    local do_drop="${drop_database:-true}"

    # Add password if provided
    if [ -n "${password:-}" ]; then
        args+=("--secure")
        args+=("--password=$password")
    fi

    if [ "$do_drop" = "true" ]; then
        if $CLICKHOUSE_CMD "${args[@]}" --query="DROP DATABASE IF EXISTS ${db}" && $CLICKHOUSE_CMD "${args[@]}" --query="CREATE DATABASE IF NOT EXISTS ${db}" ; then
            return 0
        else
            echo "ERROR: Failed to create database: $db" >&2
            return 1
        fi
    fi

    if $CLICKHOUSE_CMD "${args[@]}" --query="CREATE DATABASE IF NOT EXISTS ${db}" ; then
        return 0
    else
        echo "ERROR: Failed to create database: $db" >&2
        return 1
    fi
}

# Optional: drop database if requested by orchestrator
engine_drop_database() {
    local args=(
        "--host=$clickhouse_host"
        "--user=$user"
    )

    if [ -n "${password:-}" ]; then
        args+=("--secure")
        args+=("--password=$password")
    fi

    if $CLICKHOUSE_CMD "${args[@]}" --query="DROP DATABASE IF EXISTS ${db}"; then
        return 0
    else
        echo "ERROR: Failed to drop database: $db" >&2
        return 1
    fi
}
