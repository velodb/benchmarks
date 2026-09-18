#!/bin/bash
# Apache Spark SQL engine implementation.
#
# SQL is sent to a long-running Spark Thrift Server through Beeline. Spark
# does not expose a JMeter data source in this benchmark runner; use the
# runner's query mode for Spark benchmarks.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/interface.sh"

spark_session_file=""
spark_jdbc_url=""

spark_resolve_path() {
    local path="$1"
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        printf '%s/%s\n' "${TEST_ROOT:-.}" "$path"
    fi
}

spark_beeline() {
    local sql="$1"
    local beeline_cmd="${BEELINE_CMD:-beeline}"
    local args=(
        -u "$spark_jdbc_url"
        --silent=true
        --showHeader=true
        --outputformat=tsv2
        -f /dev/stdin
    )

    if [[ -n "${user:-}" ]]; then
        args=(-n "$user" "${args[@]}")
    fi
    if [[ -n "${password:-}" ]]; then
        args=(-p "$password" "${args[@]}")
    fi

    printf '%s\n' "$sql" | "$beeline_cmd" "${args[@]}"
}

spark_sql_with_session() {
    local sql="$1"
    local apply_session="${2:-true}"
    local session_sql=""

    if [[ "$apply_session" != "false" && "${session:-true}" == "true" \
        && -n "$spark_session_file" && -f "$spark_session_file" ]]; then
        session_sql="$(<"$spark_session_file")"
    fi

    # run_session() already sends the session file as a statement. Avoid
    # sending it twice when the runner invokes engine_run_sql for that phase.
    if [[ -n "$session_sql" && "$sql" != "$session_sql" ]]; then
        printf '%s\n%s\n' "$session_sql" "$sql"
    else
        printf '%s\n' "$sql"
    fi
}

engine_init() {
    local missing_deps=()
    local beeline_cmd="${BEELINE_CMD:-beeline}"

    if [[ "$beeline_cmd" == */* ]]; then
        [[ -x "$beeline_cmd" ]] || missing_deps+=("$beeline_cmd")
    elif ! command -v "$beeline_cmd" >/dev/null 2>&1; then
        missing_deps+=("$beeline_cmd")
    fi

    if [[ "${jmeter:-false}" == "true" ]]; then
        echo "ERROR: Spark engine does not support JMeter; use query=true with query_by_query=true" >&2
        return 1
    fi

    spark_thrift_host="${spark_thrift_host:-127.0.0.1}"
    spark_thrift_port="${spark_thrift_port:-10000}"
    spark_thrift_database="${db:-default}"
    spark_jdbc_url="${jdbc_url:-jdbc:hive2://${spark_thrift_host}:${spark_thrift_port}/${spark_thrift_database}}"

    local missing_vars=()
    for var in spark_thrift_host spark_thrift_port db; do
        if [[ -z "${!var:-}" ]]; then
            missing_vars+=("$var")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo "ERROR: Missing required dependency: ${missing_deps[*]}" >&2
        return 1
    fi
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        echo "ERROR: Missing required environment variables: ${missing_vars[*]}" >&2
        return 1
    fi

    # The current runner exports paths.session_file; older configurations used
    # paths.session. Keep both names working when CONFIG_FILE is available.
    local configured_session="${SESSION_FILE:-}"
    if [[ -z "$configured_session" && -n "${CONFIG_FILE:-}" ]] \
        && command -v yq >/dev/null 2>&1; then
        configured_session="$(yq eval '.paths.session_file // .paths.session // "session/session.sql"' \
            "$CONFIG_FILE" 2>/dev/null || true)"
    fi
    if [[ -z "$configured_session" || "$configured_session" == "null" ]]; then
        configured_session="session/session.sql"
    fi
    spark_session_file="$(spark_resolve_path "$configured_session")"

    if ! spark_beeline "SELECT 1" >/dev/null 2>&1; then
        echo "ERROR: Cannot connect to Spark Thrift Server at ${spark_thrift_host}:${spark_thrift_port}/${spark_thrift_database}" >&2
        return 1
    fi

    echo "Initialized Spark Thrift Server: ${spark_thrift_host}:${spark_thrift_port}/${spark_thrift_database}"
    return 0
}

engine_run_sql_file() {
    local sql_file="$1"
    local apply_session="${2:-true}"

    if [[ ! -f "$sql_file" ]]; then
        echo "ERROR: SQL file not found: $sql_file" >&2
        return 1
    fi

    local sql_content
    sql_content="$(<"$sql_file")"
    spark_beeline "$(spark_sql_with_session "$sql_content" "$apply_session")"
}

engine_run_sql() {
    local _db="$1"
    local sql_statement="$2"
    local apply_session="${3:-true}"

    if [[ -z "$sql_statement" ]]; then
        echo "ERROR: SQL statement cannot be empty" >&2
        return 1
    fi

    spark_beeline "$(spark_sql_with_session "$sql_statement" "$apply_session")"
}

# JMeter is intentionally unsupported, but these functions satisfy the common
# engine interface and fail clearly if called by a future integration.
engine_get_jdbc_datasource() {
    echo "ERROR: Spark engine does not provide a JMeter JDBC data source" >&2
    return 1
}

engine_get_jdbc_sampler_name() {
    printf 'spark\n'
}

engine_get_version() {
    spark_beeline "$(spark_sql_with_session 'SELECT version()')" 2>/dev/null | tail -n 1
}

engine_get_data_size_bytes() {
    printf '0\n'
}

engine_get_plan() {
    local _db="$1"
    local sql_statement="$2"
    spark_beeline "$(spark_sql_with_session "EXPLAIN FORMATTED $sql_statement")"
}

engine_enable_profile() {
    echo "Spark profile collection is managed by Spark UI/Event Log; benchmark profile API is unsupported" >&2
    return 1
}

engine_disable_profile() {
    return 0
}

engine_drop_database() {
    return 0
}

engine_clean_trash() {
    return 0
}

engine_create_database() {
    return 0
}
