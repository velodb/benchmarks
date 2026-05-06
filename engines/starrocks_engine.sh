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
    [ -n "$db" ] && args+=(-D"$db")

    # Execute the SQL statement
    if output=$(mysql "${args[@]}" -e "$sql_statement" 2>&1); then
        return 0
    else
        echo "ERROR: Failed to execute SQL statement: $sql_statement" >&2
        return 1
    fi
}

# 2.2. Get row count of a loaded table
engine_get_table_rows() {
    local table="$1"
    local host="${fe_host:-127.0.0.1}"
    local port="${fe_query_port:-9030}"
    local sys_user="${user:-root}"
    local current_db="${db:-}"

    local count
    count="$(MYSQL_PWD="${password:-}" mysql -h"${host}" -P"${port}" -u"${sys_user}" -D"${current_db}" \
        -N -s -e "SELECT COUNT(*) FROM ${table};" 2>/dev/null || true)"
    count="${count%%$'\n'*}"
    count="${count//$'\r'/}"

    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo "0"
    fi

    return 0
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
    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -D"$db_name" -N -s -e "SHOW TABLES;" 2>/dev/null
}

engine_drop_stats() {
    local db_name="$1"
    local table="$2"
    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -D"$db_name" -e "DROP STATS ${table};" >/dev/null 2>&1
}

engine_analyze_table() {
    local db_name="$1"
    local table="$2"
    local analyze_type="$3"
    local sql=""

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

# 3. Generate JDBC DataSource XML configuration for Starrocks
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
  <stringProp name="dataSource">Starrocks</stringProp>
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
    echo "Starrocks"
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
