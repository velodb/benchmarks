#!/bin/bash
# Trino Database Engine Implementation
#
# This script depends on the Trino CLI tool (trino-cli).
#
# How to download and install Trino CLI:
# 1. Visit https://trino.io/download.html
# 2. Download the command line client:
#      wget https://github.com/trinodb/trino/releases/download/479/trino-cli-479 -O trino-cli
#    (Replace XXX with the latest version number)
# 3. Make it executable:
#      chmod +x trino-cli
# 4. Put trino-cli in your PATH, or call it directly from this directory
#
# Required environment variables:
# - host: Trino coordinator host
# - port: Trino port (default: 8080
# - user: Trino username
# - catalog: Trino catalog name
# - schema: Trino schema name
# Optional:
# - password: Trino password (if authentication is enabled)

# Source the interface for utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/interface.sh"

# 1. Initialize and check Trino dependencies
engine_init() {
    # Check required command-line tools
    local missing_deps=()
    for cmd in trino-cli; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo "ERROR: Missing required dependencies: ${missing_deps[*]}" >&2
        echo "Please install the Trino CLI and try again." >&2
        return 1
    fi
    
    # Set default port if not provided
    port="${port:-8080}"
    
    # Check required environment variables
    local missing_vars=()
    for var in host user catalog schema; do
        if [ -z "${!var:-}" ]; then
            missing_vars+=("$var")
        fi
    done
    
    if [ ${#missing_vars[@]} -ne 0 ]; then
        echo "ERROR: Missing required environment variables: ${missing_vars[*]}" >&2
        echo "Please set these variables in your benchmark.yaml configuration." >&2
        return 1
    fi
    
    echo "Initialized Trino: $host:$port/$catalog/$schema"
    return 0
}

# 2. Execute a SQL file using trino CLI
engine_run_sql_file() {
    local sql_file="$1"
    
    if [ ! -f "$sql_file" ]; then
        echo "ERROR: SQL file not found: $sql_file" >&2
        return 1
    fi
    
    # Build trino command arguments
    local args=(
        --server "$host:$port"
        --user "$user"
        --catalog "$catalog"
        --schema "$schema"
    )
    
    # Add password if provided
    if [ -n "${password:-}" ]; then
        args+=(--password)
        export TRINO_PASSWORD="$password"
    fi
    
    # Execute the SQL file
    if trino-cli "${args[@]}" -f "$sql_file"; then
        return 0
    else
        echo "ERROR: Failed to execute SQL file: $sql_file" >&2
        return 1
    fi
}

# 2.1. Execute a SQL statement using trino CLI
engine_run_sql() {
    local db="$1"
    local sql_statement="$2"
    
    if [ -z "$sql_statement" ]; then
        echo "ERROR: SQL statement cannot be empty" >&2
        return 1
    fi
    
    local args=(
        --server "$host:$port"
        --user "$user"
        --catalog "$catalog"
    )
    
    # Use provided db as schema or default schema
    if [ -n "$db" ]; then
        args+=(--schema "$db")
    elif [ -n "$schema" ]; then
        args+=(--schema "$schema")
    fi
    
    # Add password if provided
    if [ -n "${password:-}" ]; then
        args+=(--password)
        export TRINO_PASSWORD="$password"
    fi
    
    # Execute the SQL statement
    if trino-cli "${args[@]}" --execute "$sql_statement"; then
        return 0
    else
        echo "ERROR: Failed to execute SQL statement: $sql_statement" >&2
        return 1
    fi
}

# 3. Generate JDBC DataSource XML configuration for Trino
engine_get_jdbc_datasource() {
    # Escape any special characters in the password
    local escaped_password=""
    if [ -n "${password:-}" ]; then
        escaped_password=$(xml_escape "$password")
    fi
    
    local jdbc_url="jdbc:trino://${host}:${port}/${catalog}/${schema}"
    
    cat << EOF
<JDBCDataSource guiclass="TestBeanGUI" testclass="JDBCDataSource" testname="JDBC Connection Configuration" enabled="true">
  <boolProp name="autocommit">true</boolProp>
  <stringProp name="checkQuery">SELECT 1</stringProp>
  <stringProp name="connectionAge">5000</stringProp>
  <stringProp name="connectionProperties"></stringProp>
  <stringProp name="dataSource">trino</stringProp>
  <stringProp name="dbUrl">${jdbc_url}</stringProp>
  <stringProp name="driver">io.trino.jdbc.TrinoDriver</stringProp>
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
    echo "trino"
}

# Optional: enable profile collection (no-op)

# Optional: Fetch engine version
engine_get_version() {
    local args=(
        --server "$host:$port"
        --user "$user"
        --catalog "$catalog"
        --output-format CSV
    )
    if [ -n "$schema" ]; then
        args+=(--schema "$schema")
    fi
    if [ -n "${password:-}" ]; then
        args+=(--password)
        export TRINO_PASSWORD="$password"
    fi
    local version
    version="$(trino-cli "${args[@]}" --execute "SELECT version();" 2>/dev/null || true)"
    echo "$version" | tail -n 1
}

# Optional: Fetch total data size in bytes (best effort; depends on connector support)
engine_get_data_size_bytes() {
    local args=(
        --server "$host:$port"
        --user "$user"
        --catalog "$catalog"
        --output-format CSV
    )
    if [ -n "$schema" ]; then
        args+=(--schema "$schema")
    fi
    if [ -n "${password:-}" ]; then
        args+=(--password)
        export TRINO_PASSWORD="$password"
    fi
    local size
    size="$(trino-cli "${args[@]}" --execute "SELECT COALESCE(SUM(data_size),0) FROM system.metadata.table_stats WHERE schema_name = '${schema}';" 2>/dev/null || true)"
    echo "$size" | tail -n 1
}

engine_get_table_rows() {
    local table="$1"
    local target_schema="${db:-${schema:-}}"
    local args=(
        --server "$host:$port"
        --user "$user"
        --catalog "$catalog"
        --output-format TSV
    )

    if [ -n "${password:-}" ]; then
        args+=(--password)
        export TRINO_PASSWORD="$password"
    fi

    local count
    count="$(trino-cli "${args[@]}" --execute \
        "SELECT count(*) FROM ${catalog}.${target_schema}.${table}" 2>/dev/null || true)"
    count="${count%%$'\n'*}"
    count="${count//$'\r'/}"
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi
}

engine_set_auto_analyze() {
    return 0
}

engine_list_tables() {
    local target_schema="$1"
    local args=(
        --server "$host:$port"
        --user "$user"
        --catalog "$catalog"
        --schema "$target_schema"
        --output-format TSV
    )

    if [ -n "${password:-}" ]; then
        args+=(--password)
        export TRINO_PASSWORD="$password"
    fi

    trino-cli "${args[@]}" --execute \
        "SELECT table_name FROM information_schema.tables WHERE table_schema = '${target_schema}' ORDER BY table_name" 2>&1
}

engine_drop_stats() {
    return 0
}

engine_analyze_table() {
    local target_schema="$1"
    local table="$2"
    local analyze_type="$3"
    local args=(
        --server "$host:$port"
        --user "$user"
        --catalog "$catalog"
    )

    case "$analyze_type" in
        analyze_full)
            ;;
        analyze_no)
            return 0
            ;;
        *)
            echo "Unsupported analyze type for Trino: ${analyze_type}" >&2
            return 1
            ;;
    esac

    if [ -n "${password:-}" ]; then
        args+=(--password)
        export TRINO_PASSWORD="$password"
    fi

    trino-cli "${args[@]}" --execute \
        "ANALYZE ${catalog}.${target_schema}.${table}" 2>&1
}

# Helper function to create schema (used in DDL setup)
engine_create_database() {
    # Build trino command arguments
    local args=(
        --server "$host:$port"
        --user "$user"
        --catalog "$catalog"
    )
    
    # Add password if provided
    if [ -n "${password:-}" ]; then
        args+=(--password)
        export TRINO_PASSWORD="$password"
    fi
    
    local do_drop="${drop_database:-true}"

    if [ "$do_drop" = "true" ]; then
        if trino-cli "${args[@]}" --execute "DROP SCHEMA IF EXISTS ${schema}; CREATE SCHEMA ${schema};"; then
            return 0
        else
            echo "ERROR: Failed to create schema: $catalog/$schema" >&2
            return 1
        fi
    fi

    if trino-cli "${args[@]}" --execute "CREATE SCHEMA IF NOT EXISTS ${schema};"; then
        return 0
    else
        echo "ERROR: Failed to create schema: $catalog/$schema" >&2
        return 1
    fi
}

# Optional: drop schema if requested by orchestrator
engine_drop_database() {
    local args=(
        --server "$host:$port"
        --user "$user"
        --catalog "$catalog"
    )

    if [ -n "${password:-}" ]; then
        args+=(--password)
        export TRINO_PASSWORD="$password"
    fi

    if trino-cli "${args[@]}" --execute "DROP SCHEMA IF EXISTS ${schema} CASCADE;"; then
        return 0
    else
        echo "ERROR: Failed to drop schema: $catalog/$schema" >&2
        return 1
    fi
}
