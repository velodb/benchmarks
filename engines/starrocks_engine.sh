#!/bin/bash
# Starrocks Database Engine Implementation
# 
# This engine implements the benchmark framework interface for Starrocks databases.
# Starrocks uses MySQL protocol for connections.
# 
# Required environment variables:
# - fe_host: Starrocks Frontend host address
# - fe_http_port: HTTP port for Starrocks Frontend (default: 8030)
# - fe_query_port: Query port for Starrocks Frontend (default: 9030)  
# - user: Starrocks username
# - password: Starrocks password
# - db: Starrocks database name

# Source the interface for utility functions
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/interface.sh"

starrocks_qualified_db() {
    local db_name="$1"

    if [ -n "${catalog:-}" ] && [ -n "$db_name" ] && [[ "$db_name" != *.* ]]; then
        printf '%s.%s\n' "$catalog" "$db_name"
    else
        printf '%s\n' "$db_name"
    fi
}

starrocks_qualified_table() {
    local table_name="$1"
    local db_name

    db_name="$(starrocks_qualified_db "${db:-}")"
    if [[ "$table_name" != *.* ]] && [ -n "$db_name" ]; then
        printf '%s.%s\n' "$db_name" "$table_name"
    else
        printf '%s\n' "$table_name"
    fi
}

# 1. Initialize and check StarRocks dependencies
engine_init() {
    echo "Initializing StarRocks engine..."

    # Initialize MySQL JDBC driver for JMeter if needed
    if [[ "${jmeter:-}" == "true" ]] && [ -n "${JMETER_HOME:-}" ]; then
        init_mysql_jdbc_driver
    fi

    # Check required command-line tools
    local missing_deps=()
    for cmd in mysql; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_deps+=("$cmd")
        fi
    done


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

    echo "Initialized Starrocks: $fe_host:$fe_query_port/$db"
    return 0
}

# Initialize MySQL JDBC driver for JMeter
init_mysql_jdbc_driver() {
    local tools_dir
    tools_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tools"
    
    local mysql_connector_archive="$tools_dir/mysql-connector-j-8.0.33.tar.gz"
    if [ -f "$mysql_connector_archive" ]; then
        local mysql_connector_dir="$tools_dir/mysql-connector-j-8.0.33"
        
        # Extract if not already extracted
        if [ ! -d "$mysql_connector_dir" ]; then
            echo "Extracting MySQL Connector..."
            tar -xzf "$mysql_connector_archive" -C "$tools_dir"
        fi
        
        # Copy MySQL JDBC driver to JMeter lib directory
        if [ -d "$JMETER_HOME/lib" ]; then
            local jar_file="$mysql_connector_dir/mysql-connector-j-8.0.33.jar"
            if [ -f "$jar_file" ]; then
                cp "$jar_file" "$JMETER_HOME/lib/ext/" 2>/dev/null || true
                echo "MySQL Connector copied to JMeter"
            fi
        fi
    else
        echo "WARNING: MySQL Connector archive not found at $mysql_connector_archive" >&2
    fi
}

# 2. Execute a SQL file using mysql client
engine_run_sql_file() {
    local sql_file="$1"
    local apply_session="${2:-true}"
    local db_name
    
    if [ ! -f "$sql_file" ]; then
        echo "ERROR: SQL file not found: $sql_file" >&2
        return 1
    fi
    
    # Set password environment variable for mysql
    export MYSQL_PWD="${password:-}"
    db_name="${db:-}"
    # DDL setup passes apply_session=false and may create/drop the catalog itself,
    # so do not select catalog.db before the catalog exists.
    if [ "$apply_session" != "false" ]; then
        db_name="$(starrocks_qualified_db "$db_name")"
    fi
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")
    [ -n "$db_name" ] && args+=(-D"$db_name")
    
    # Execute the SQL file
    if mysql "${args[@]}" < "$sql_file"; then
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
    local error_file=""
    local sql_file=""
    local status=0
    
    if [ -z "$sql_statement" ]; then
        echo "ERROR: SQL statement cannot be empty" >&2
        return 1
    fi
    
    # Set password environment variable for mysql
    export MYSQL_PWD="${password:-}"

    # Build mysql command arguments
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")
    db="$(starrocks_qualified_db "$db")"
    [ -n "$db" ] && args+=(-D"$db")

    local last_query_id_file="${RESULT_DIR:-/tmp}/.last_query_id"

    # Execute the SQL statement
    error_file="$(mktemp "${TMPDIR:-/tmp}/starrocks_mysql_stderr.XXXXXX")" || {
        echo "ERROR: Failed to create temporary stderr file" >&2
        return 1
    }
    sql_file="$(mktemp "${TMPDIR:-/tmp}/starrocks_mysql_sql.XXXXXX")" || {
        echo "ERROR: Failed to create temporary SQL file" >&2
        rm -f "$error_file"
        return 1
    }
    if [[ "${profile:-}" == "true" ]]; then
        printf 'SET enable_profile = true;\n' > "$sql_file"
    else
        : > "$sql_file"
    fi
    printf '%s\n' "$sql_statement" >> "$sql_file"
    local sql_tail="$sql_statement"
    while :; do
        case "$sql_tail" in
            *[[:space:]]) sql_tail="${sql_tail%?}" ;;
            *) break ;;
        esac
    done
    case "$sql_tail" in
        *";") printf 'SELECT last_query_id();\n' >> "$sql_file" ;;
        *) printf ';\nSELECT last_query_id();\n' >> "$sql_file" ;;
    esac
    if output=$(mysql "${args[@]}" --batch --skip-column-names < "$sql_file" 2>"$error_file"); then
        rm -f "$sql_file" "$error_file"
        echo "$output" | sed '/^[[:space:]]*$/d' | tail -n 1 > "$last_query_id_file"
        return 0
    else
        status=$?
        echo "ERROR: Failed to execute SQL statement: $sql_statement" >&2
        if [ -s "$error_file" ]; then
            cat "$error_file" >&2
        fi
        rm -f "$error_file" "$sql_file"
        return "$status"
    fi
}

# 2.2. Get row count of a loaded table
engine_get_table_rows() {
    local table="$1"
    local host="${fe_host:-127.0.0.1}"
    local port="${fe_query_port:-9030}"
    local sys_user="${user:-root}"
    local current_db="${db:-}"
    local qualified_table

    current_db="$(starrocks_qualified_db "$current_db")"
    qualified_table="$(starrocks_qualified_table "$table")"

    local count
    count="$(MYSQL_PWD="${password:-}" mysql -h"${host}" -P"${port}" -u"${sys_user}" -D"${current_db}" \
        -N -s -e "SELECT COUNT(*) FROM ${qualified_table};" 2>/dev/null || true)"
    count="${count%%$'\n'*}"
    count="${count//$'\r'/}"

    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi

    return 0
}

# Optional: Custom generic load implementation for StarRocks
engine_load_data() {
    mysql_engine_load_data "$@"
}

engine_set_auto_analyze() {
    local enabled="$1"
    local collect="false"
    local full_collect="false"
    local output=""

    if [ "$enabled" = "true" ]; then
        collect="true"
        full_collect="true"
    fi

    export MYSQL_PWD="${password:-}"
    if ! output=$(mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -e "ADMIN SET FRONTEND CONFIG ('enable_statistic_collect'='${collect}');" 2>&1); then
        if [[ "$output" != *"EMR"* ]]; then
            echo "$output" >&2
            return 1
        fi
    fi

    if ! output=$(mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -e "ADMIN SET FRONTEND CONFIG ('enable_collect_full_statistic'='${full_collect}');" 2>&1); then
        if [[ "$output" != *"EMR"* ]]; then
            echo "$output" >&2
            return 1
        fi
    fi

    return 0
}

engine_list_tables() {
    local db_name="$1"
    db_name="$(starrocks_qualified_db "$db_name")"

    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -D"$db_name" -N -s -e "SHOW TABLES;" 2>/dev/null
}

engine_drop_stats() {
    local db_name="$1"
    local table="$2"
    db_name="$(starrocks_qualified_db "$db_name")"

    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -D"$db_name" -e "DROP STATS ${table};" >/dev/null 2>&1
}

engine_analyze_table() {
    local db_name="$1"
    local table="$2"
    local analyze_type="$3"
    local sql=""

    db_name="$(starrocks_qualified_db "$db_name")"

    case "${analyze_type}" in
        analyze_full)
            sql="analyze full table ${table} with sync mode"
        ;;
        analyze_sample)
            sql="ANALYZE sample table ${table} with sync mode PROPERTIES('statistic_sample_collect_rows'='4000000')"
        ;;
        analyze_no|analyze_default)
            return 0
        ;;
        *)
            echo "Unsupported analyze type for StarRocks: ${analyze_type}" >&2
            return 1
        ;;
    esac

    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -D"$db_name" -e "${sql};" 2>&1
}

engine_show_column_stats() {
    return 0
}

# Optional: enable query profile collection for StarRocks.
#
# benchmark.sh opens a new mysql connection for each query, so the query runner
# also enables the session variable immediately before the measured statement.
# This function is a capability check that keeps the shared profile hook active.
engine_enable_profile() {
    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -e "SET enable_profile = true;" >/dev/null 2>&1
}

# Optional: disable query profile collection.
engine_disable_profile() {
    return 0
}

# Optional: get last query id (best effort)
engine_get_last_query_id() {
    local last_query_id_file="${RESULT_DIR:-/tmp}/.last_query_id"
    if [ -f "$last_query_id_file" ]; then
        cat "$last_query_id_file"
    else
        export MYSQL_PWD="${password:-}"
        mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -N -s -e "SELECT last_query_id();" 2>/dev/null
    fi
}

# Optional: fetch profile content by query id
engine_fetch_profile() {
    local query_id="$1"
    if [[ ! "$query_id" =~ ^[0-9A-Za-z_-]+$ ]]; then
        return 1
    fi

    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -N -s --raw \
        -e "SELECT get_query_profile('${query_id}');" 2>/dev/null
}

# Optional: fetch plan text for a query
engine_get_plan() {
    local db_name="$1"
    local sql_statement="$2"
    export MYSQL_PWD="${password:-}"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user" -N -s)
    db_name="$(starrocks_qualified_db "$db_name")"
    [ -n "$db_name" ] && args+=(-D"$db_name")
    mysql "${args[@]}" -e "EXPLAIN VERBOSE ${sql_statement}" 2>/dev/null || true
}

# 3. Generate JDBC DataSource XML configuration for Starrocks
engine_get_jdbc_datasource() {
    # Escape any special characters in the password
    local escaped_password
    local jdbc_db
    escaped_password=$(xml_escape "${password:-}")
    jdbc_db="$(starrocks_qualified_db "${db:-}")"
    
    cat << EOF
<JDBCDataSource guiclass="TestBeanGUI" testclass="JDBCDataSource" testname="JDBC Connection Configuration" enabled="true">
  <boolProp name="autocommit">true</boolProp>
  <stringProp name="checkQuery">SELECT 1</stringProp>
  <stringProp name="connectionAge">5000</stringProp>
  <stringProp name="connectionProperties"></stringProp>
  <stringProp name="dataSource">Starrocks</stringProp>
  <stringProp name="dbUrl">jdbc:mysql://${fe_host}:${fe_query_port}/${jdbc_db}</stringProp>
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
    echo "Starrocks"
}

# Optional: Fetch engine version
engine_get_version() {
    export MYSQL_PWD="${password:-}"
    local args=(-h"$fe_host" -P"$fe_query_port" -u"$user")
    local db_name
    db_name="$(starrocks_qualified_db "${db:-}")"
    [ -n "$db_name" ] && args+=(-D"$db_name")

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
