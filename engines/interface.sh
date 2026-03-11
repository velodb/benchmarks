#!/bin/bash
# Engine Interface Definition
# 
# This file defines the contract that all database engine implementations must follow.
# Each engine must implement all four functions below to be compatible with the 
# benchmark framework.
#
# Context Variables (provided by benchmark.sh):
# - All variables defined in benchmark.yaml under 'connection' and 'parameters' 
#   are exported as environment variables and available to engine functions
# - TEST_ROOT: Absolute path to the test unit directory
# - RESULT_DIR: Directory where results should be stored

# 1. Initialize and check engine dependencies
#    This function should verify that all required command-line tools and dependencies
#    are available. If any dependencies are missing, it should print an error message
#    and exit with a non-zero status.
#    
#    Common checks include:
#    - Database CLI clients (e.g., snowsql, mysql, clickhouse-client)
#    - Required utilities (e.g., bc, jq)
#    - Environment variables
#
#    @return: 0 on success, non-zero on failure
engine_init() {
    echo "ERROR: engine_init() must be implemented by the engine" >&2
    return 1
}

# 2. Execute a SQL file
#    This function executes a single SQL file against the target database.
#    It should handle connection parameters and error reporting.
#    
#    @param $1: Absolute path to the SQL file to execute
#    @return: 0 on success, non-zero on failure
engine_run_sql_file() {
    local sql_file="$1"
    echo "ERROR: engine_run_sql_file() must be implemented by the engine" >&2
    echo "       Should execute SQL file: $sql_file" >&2
    return 1
}

# 2.1. Execute a SQL statement
#    This function executes a single SQL statement against the target database.
#    It should handle connection parameters and error reporting.
#    
#    @param $1: SQL statement to execute
#    @return: 0 on success, non-zero on failure
engine_run_sql() {
    local db="$1"
    local sql_statement="$2"
    echo "ERROR: engine_run_sql() must be implemented by the engine" >&2
    echo "       Should execute SQL statement: $sql_statement" >&2
    return 1
}

# 2.2. Get row count of a loaded table
#    This function queries the engine to verify the actual number of rows
#    loaded into the specified table. Used for benchmark load validation.
#
#    @param $1: Table name to check
#    @return: 0 on success (prints row count to stdout), non-zero on failure
engine_get_table_rows() {
    local table="$1"
    echo "0"
    return 0
}

# 3. Generate JDBC DataSource XML configuration
#    This function returns a complete <JDBCDataSource> XML configuration block
#    that will be embedded in the JMeter JMX file. The configuration should include
#    all necessary connection parameters, driver information, and connection pooling settings.
#    
#    The output should be a complete XML block starting with <JDBCDataSource> and 
#    ending with </JDBCDataSource>, properly formatted for direct inclusion in JMX.
#    
#    @return: 0 on success, prints XML to stdout
engine_get_jdbc_datasource() {
    echo "ERROR: engine_get_jdbc_datasource() must be implemented by the engine" >&2
    return 1
}

# 4. Get JDBC Sampler DataSource Name
#    This function returns the dataSource name that JMeter samplers should reference.
#    This name must match the dataSource property in the JDBC configuration returned
#    by engine_get_jdbc_datasource().
#    
#    @return: 0 on success, prints datasource name to stdout
engine_get_jdbc_sampler_name() {
    echo "ERROR: engine_get_jdbc_sampler_name() must be implemented by the engine" >&2
    return 1
}

# Optional helpers for metadata (best-effort; used by result generation)
# - engine_get_version(): prints engine version string
# - engine_get_data_size_bytes(): prints total data size in bytes
engine_get_version() {
    return 1
}

engine_get_data_size_bytes() {
    return 1
}

# Optional: Drop database/schema for cleanup
#    Implement if the engine supports explicit cleanup after benchmarks.
#    @return: 0 on success, non-zero on failure
engine_drop_database() {
    return 0
}

# Optional: Clean trash or recycle bin for storage engines that support it
#    @return: 0 on success, non-zero on failure
engine_clean_trash() {
    return 0
}
#
# Optional helpers for query diagnostics (best-effort; used by query execution)
# - engine_enable_profile(): enable query profiling if supported
engine_enable_profile() {
    echo "Profile collection not supported by this engine, skipping..." >&2
    return 1
}

# - engine_disable_profile(): disable query profiling if supported
engine_disable_profile() {
    return 1
}

# - engine_get_last_query_id(): print last query id for profile fetch
engine_get_last_query_id() {
    return 1
}

# - engine_fetch_profile(query_id): print profile content for query_id
engine_fetch_profile() {
    return 1
}

# - engine_get_plan(db, sql): print plan text for sql
engine_get_plan() {
    echo "Plan collection not supported by this engine, skipping..." >&2
    return 1
}

# Helper function to escape XML content
# This is provided as a utility for engines that need to escape XML content
# Use sed for better compatibility across different environments
xml_escape() {
    local content="$1"
    echo "$content" | sed -e 's/&/\&amp;/g' \
                          -e 's/</\&lt;/g' \
                          -e 's/>/\&gt;/g' \
                          -e 's/"/\&quot;/g' \
                          -e "s/'/\&apos;/g"
}

# Validation function to check if an engine implements all required functions
# This can be called by benchmark.sh to validate engine compatibility
validate_engine() {
    local engine_file="$1"
    local errors=0
    
    # Source the engine file
    if ! source "${engine_file}"; then
        echo "ERROR: Failed to source engine file: $engine_file" >&2
        return 1
    fi
    
    # Check if all required functions are defined
    for func in engine_init engine_run_sql_file engine_run_sql engine_get_jdbc_datasource engine_get_jdbc_sampler_name; do
        if ! declare -f "$func" >/dev/null 2>&1; then
            echo "ERROR: Function $func is not defined in $engine_file" >&2
            ((errors++))
        fi
    done
    
    return $errors
}
