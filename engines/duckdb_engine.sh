#!/bin/bash
# DuckDB Database Engine Implementation
#
# This engine implements the benchmark framework interface for DuckDB.
# DuckDB must always be opened with a database file path so data is persisted
# across benchmark phases.
#
# Required environment variables:
# - db: DuckDB database file path

# Source the interface for utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/interface.sh"

# Load JDBC utilities
source "$(dirname "${BASH_SOURCE[0]}")/../lib/jdbc_utils.sh"

resolve_duckdb_dbfile() {
    local db_path="${1:-${db:-}}"

    if [ -z "$db_path" ]; then
        echo "ERROR: Missing required environment variable: db" >&2
        return 1
    fi

    if [ "$db_path" = ":memory:" ]; then
        echo "ERROR: DuckDB benchmarks require a persistent database file, not :memory:" >&2
        return 1
    fi

    if [[ "$db_path" != /* ]]; then
        if [ -n "${TEST_ROOT:-}" ]; then
            db_path="${TEST_ROOT}/${db_path}"
        else
            db_path="$(pwd)/${db_path}"
        fi
    fi

    printf '%s\n' "$db_path"
}

ensure_duckdb_parent_dir() {
    local dbfile="$1"
    local parent_dir
    parent_dir="$(dirname "$dbfile")"

    if [ ! -d "$parent_dir" ]; then
        mkdir -p "$parent_dir"
    fi
}

duckdb_exec_sql() {
    local dbfile="$1"
    local sql_statement="$2"
    shift 2

    duckdb -no-init -batch -bail "$dbfile" "$@" -c "$sql_statement"
}

duckdb_exec_file() {
    local dbfile="$1"
    local sql_file="$2"
    shift 2

    duckdb -no-init -batch -bail "$dbfile" "$@" -f "$sql_file"
}

# 1. Initialize and check DuckDB dependencies
engine_init() {
    local missing_deps=()

    if ! command -v duckdb >/dev/null 2>&1; then
        missing_deps+=("duckdb")
    fi

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "ERROR: Missing required dependencies: ${missing_deps[*]}" >&2
        return 1
    fi

    db="$(resolve_duckdb_dbfile "${db:-}")" || return 1
    export db

    if [[ "${jmeter:-}" == "true" ]] && [ -n "${JMETER_HOME:-}" ]; then
        init_duckdb_jdbc_driver
    fi

    echo "Initialized DuckDB: $db"
    return 0
}

# 2. Execute a SQL file using DuckDB CLI
engine_run_sql_file() {
    local sql_file="$1"
    local apply_session="${2:-true}"
    local dbfile
    local exec_file
    local temp_file=""

    if [ ! -f "$sql_file" ]; then
        echo "ERROR: SQL file not found: $sql_file" >&2
        return 1
    fi

    dbfile="$(resolve_duckdb_dbfile "${db:-}")" || return 1
    ensure_duckdb_parent_dir "$dbfile"

    exec_file="$(engine_prepare_sql_file_with_session "$sql_file" "$apply_session" "duckdb_sql")" || return 1
    if [ "$exec_file" != "$sql_file" ]; then
        temp_file="$exec_file"
    fi

    if duckdb_exec_file "$dbfile" "$exec_file"; then
        [ -n "$temp_file" ] && rm -f "$temp_file"
        return 0
    fi

    [ -n "$temp_file" ] && rm -f "$temp_file"
    echo "ERROR: Failed to execute SQL file: $sql_file" >&2
    return 1
}

# 2.1. Execute a SQL statement using DuckDB CLI
engine_run_sql() {
    local target_db="$1"
    local sql_statement="$2"
    local apply_session="${3:-true}"
    local dbfile
    local duckdb_sql
    local output

    if [ -z "$sql_statement" ]; then
        echo "ERROR: SQL statement cannot be empty" >&2
        return 1
    fi

    dbfile="$(resolve_duckdb_dbfile "${target_db:-${db:-}}")" || return 1
    ensure_duckdb_parent_dir "$dbfile"
    duckdb_sql="$(engine_prepend_session_sql "$sql_statement" "$apply_session")"

    if output=$(duckdb_exec_sql "$dbfile" "$duckdb_sql" 2>&1); then
        return 0
    fi

    echo "ERROR: Failed to execute SQL statement" >&2
    [ -n "$output" ] && echo "$output" >&2
    return 1
}

# 2.2. Get row count of a loaded table
engine_get_table_rows() {
    local table="$1"
    local dbfile
    local count

    dbfile="$(resolve_duckdb_dbfile "${db:-}")" || {
        echo "0"
        return 0
    }

    count="$(duckdb_exec_sql "$dbfile" "SELECT COUNT(*) FROM ${table};" -csv -noheader 2>/dev/null || true)"
    count="${count%%$'\n'*}"
    count="${count//$'\r'/}"

    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi

    return 0
}

# 3. Generate JDBC DataSource XML configuration for DuckDB
engine_get_jdbc_datasource() {
    local dbfile
    local escaped_jdbc_url

    dbfile="$(resolve_duckdb_dbfile "${db:-}")" || return 1
    escaped_jdbc_url="$(xml_escape "jdbc:duckdb:${dbfile}")"

    cat << EOF
<JDBCDataSource guiclass="TestBeanGUI" testclass="JDBCDataSource" testname="JDBC Connection Configuration" enabled="true">
  <boolProp name="autocommit">true</boolProp>
  <stringProp name="checkQuery">SELECT 1</stringProp>
  <stringProp name="connectionAge">5000</stringProp>
  <stringProp name="connectionProperties"></stringProp>
  <stringProp name="dataSource">DuckDB</stringProp>
  <stringProp name="dbUrl">${escaped_jdbc_url}</stringProp>
  <stringProp name="driver">org.duckdb.DuckDBDriver</stringProp>
  <stringProp name="keepAlive">true</stringProp>
  <stringProp name="password"></stringProp>
  <stringProp name="poolMax">0</stringProp>
  <stringProp name="timeout">10000</stringProp>
  <stringProp name="transactionIsolation">DEFAULT</stringProp>
  <stringProp name="trimInterval">60000</stringProp>
  <stringProp name="username"></stringProp>
</JDBCDataSource>
EOF
}

# 4. Get JDBC Sampler DataSource Name
engine_get_jdbc_sampler_name() {
    echo "DuckDB"
}

# Optional: Fetch engine version
engine_get_version() {
    local version
    version="$(duckdb -version 2>/dev/null || true)"
    version="${version%%$'\n'*}"
    version="${version//$'\r'/}"
    printf '%s\n' "$version"
}

# Optional: Fetch total data size in bytes
engine_get_data_size_bytes() {
    local dbfile
    local total=0
    local bytes

    dbfile="$(resolve_duckdb_dbfile "${db:-}")" || {
        echo "0"
        return 0
    }

    if [ -f "$dbfile" ]; then
        bytes="$(stat -c '%s' "$dbfile" 2>/dev/null || true)"
        if [[ "$bytes" =~ ^[0-9]+$ ]]; then
            total=$((total + bytes))
        fi
    fi

    if [ -f "$dbfile.wal" ]; then
        bytes="$(stat -c '%s' "$dbfile.wal" 2>/dev/null || true)"
        if [[ "$bytes" =~ ^[0-9]+$ ]]; then
            total=$((total + bytes))
        fi
    fi

    echo "$total"
}

# Helper function to create database file (used in DDL setup)
engine_create_database() {
    local dbfile
    local do_drop="${drop_database:-true}"

    dbfile="$(resolve_duckdb_dbfile "${db:-}")" || return 1
    ensure_duckdb_parent_dir "$dbfile"

    if [ "$do_drop" = "true" ]; then
        rm -f "$dbfile" "$dbfile.wal"
    fi

    if duckdb_exec_sql "$dbfile" "SELECT 1;" >/dev/null; then
        echo "Database file ready: $dbfile"
        return 0
    fi

    echo "ERROR: Failed to initialize DuckDB database file: $dbfile" >&2
    return 1
}

# Optional: drop database file if requested by orchestrator
engine_drop_database() {
    local dbfile

    dbfile="$(resolve_duckdb_dbfile "${db:-}")" || return 1

    rm -f "$dbfile" "$dbfile.wal"
    echo "Database file removed: $dbfile"
    return 0
}

# Optional: fetch plan text for a query
engine_get_plan() {
    local db_name="$1"
    local sql_statement="$2"
    local dbfile
    local duckdb_sql

    dbfile="$(resolve_duckdb_dbfile "${db_name:-${db:-}}")" || return 1
    duckdb_sql="$(engine_prepend_session_sql "EXPLAIN ${sql_statement}" true)"
    duckdb_exec_sql "$dbfile" "$duckdb_sql" 2>/dev/null || true
}
