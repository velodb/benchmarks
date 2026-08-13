#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"
CONFIG_FILE="$TEST_DIR/fixtures/doris_load_profile/benchmark.yaml"

fe_host="${FE_HOST:-127.0.0.1}"
fe_query_port="${FE_QUERY_PORT:-9030}"
fe_http_port="${FE_HTTP_PORT:-8030}"
db_user="${DB_USER:-root}"
db_password="${PASSWORD:-}"
integration_db="benchmark_load_profile_it_$(date '+%Y%m%d_%H%M%S')_$$"
keep_artifacts="${KEEP_TEST_ARTIFACTS:-false}"
result_marker=$(mktemp "${TMPDIR:-/tmp}/doris_profile_result.XXXXXX")
run_log=$(mktemp "${TMPDIR:-/tmp}/doris_profile_run.XXXXXX")
result_dir=""

mysql_args=(-h"$fe_host" -P"$fe_query_port" -u"$db_user" --batch --skip-column-names)

run_mysql() {
    MYSQL_PWD="$db_password" mysql "${mysql_args[@]}" "$@"
}

cleanup() {
    run_mysql -e "DROP DATABASE IF EXISTS ${integration_db};" >/dev/null 2>&1 || true

    if [[ "$keep_artifacts" != "true" && -n "$result_dir" && -d "$result_dir" ]]; then
        case "$result_dir" in
            "$REPO_DIR"/results/*)
                find "$result_dir" -depth -delete
                ;;
            *)
                echo "Refusing to remove unexpected result directory: $result_dir" >&2
                ;;
        esac
    fi

    rm -f "$result_marker" "$run_log"
}
trap cleanup EXIT

fail() {
    echo "ASSERTION FAILED: $1" >&2
    exit 1
}

require_file() {
    local file="$1"
    [ -s "$file" ] || fail "missing or empty file: $file"
}

for command_name in mysql curl jq find grep awk sed; do
    command -v "$command_name" >/dev/null 2>&1 \
        || fail "required command not found: $command_name"
done

run_mysql -e "SELECT 1;" >/dev/null \
    || fail "cannot connect to Doris at ${fe_host}:${fe_query_port}"

profile_before=$(run_mysql -e "SELECT @@global.enable_profile;" | tail -n 1)
doris_version=$(run_mysql -e "SELECT @@version_comment;" | tail -n 1)

echo "Running Doris Load Profile integration test"
echo "  Doris: ${doris_version:-unknown}"
echo "  MySQL endpoint: ${fe_host}:${fe_query_port}"
echo "  HTTP endpoint: ${fe_host}:${fe_http_port}"
echo "  Temporary database: ${integration_db}"

set +e
FE_HOST="$fe_host" \
FE_QUERY_PORT="$fe_query_port" \
FE_HTTP_PORT="$fe_http_port" \
DB_USER="$db_user" \
PASSWORD="$db_password" \
DB="$integration_db" \
RESULT_DIR_FILE="$result_marker" \
PROFILE_WAIT_SECONDS="${PROFILE_WAIT_SECONDS:-0}" \
LOAD_PROFILE_WAIT_SECONDS="${LOAD_PROFILE_WAIT_SECONDS:-5}" \
LOAD_STATUS_POLL_INTERVAL_SECONDS="${LOAD_STATUS_POLL_INTERVAL_SECONDS:-1}" \
bash "$REPO_DIR/benchmark.sh" --config "$CONFIG_FILE" 2>&1 | tee "$run_log"
benchmark_status=${PIPESTATUS[0]}
set -e

[ "$benchmark_status" -eq 0 ] || fail "benchmark exited with status ${benchmark_status}"
[ -s "$result_marker" ] || fail "benchmark did not write RESULT_DIR_FILE"
result_dir=$(head -n 1 "$result_marker")
case "$result_dir" in
    "$REPO_DIR"/results/*) ;;
    *) fail "unexpected result directory: $result_dir" ;;
esac

load_csv="$result_dir/load.csv"
profile_index="$result_dir/load_profile.csv"
require_file "$load_csv"
require_file "$profile_index"

grep -q '^insert_probe,insert_into,' "$load_csv" \
    || fail "load.csv is missing the INSERT load result"
grep -q '^dates_probe,s3_load,' "$load_csv" \
    || fail "load.csv is missing the S3/Broker load result"
grep -q '^stream_probe,stream_load,' "$load_csv" \
    || fail "load.csv is missing the Stream Load result"

insert_profile=$(find "$result_dir/profile/load" -name '*insert_into*profile.txt' -type f -print -quit)
s3_profile=$(find "$result_dir/profile/load" -name '*s3_load*profile.txt' -type f -print -quit)
s3_diagnostics=$(find "$result_dir/profile/load" -name '*s3_load_diagnostics.txt' -type f -print -quit)
stream_response=$(find "$result_dir/profile/load" -name '*stream_load_response.json' -type f -print -quit)
query_profile=$(find "$result_dir/profile" -maxdepth 1 -name '*profile.txt' -type f -print -quit)

for artifact in "$insert_profile" "$s3_profile" "$s3_diagnostics" "$stream_response" "$query_profile"; do
    require_file "$artifact"
done

grep -q 'Task Type: LOAD' "$insert_profile" \
    || fail "INSERT artifact is not a Doris Load Profile"
grep -Eq 'PhysicalOlapTableSink|CloseWaitTime' "$insert_profile" \
    || fail "INSERT profile is missing write-side counters"
grep -Eq 'Rows(Read|Produced):.*\(100000\)' "$insert_profile" \
    || fail "INSERT profile does not contain the expected 100000 rows"

grep -q 'Task Type: LOAD' "$s3_profile" \
    || fail "S3 artifact is not a Doris Load Profile"
grep -q 'FileReadTime:' "$s3_profile" \
    || fail "S3 profile is missing FileReadTime"
grep -Eq 'Rows(Read|Produced|ScanRows):.*\(2556\)' "$s3_profile" \
    || fail "S3 profile does not contain the expected 2556 rows"
grep -q 'State: FINISHED' "$s3_diagnostics" \
    || fail "S3 SHOW LOAD diagnostics are not FINISHED"

jq -e '
    .Status == "Success"
    and .NumberLoadedRows == 2
    and (.LoadTimeMs >= 0)
    and (.WriteDataTimeMs >= 0)
    and (.CommitAndPublishTimeMs >= 0)
' "$stream_response" >/dev/null \
    || fail "Stream Load response is missing success/timing fields"

grep -q 'Task Type: QUERY' "$query_profile" \
    || fail "query artifact is not a Doris Query Profile"
grep -Fq 'SELECT COUNT(*) FROM insert_probe' "$query_profile" \
    || fail "query profile does not match the integration query"

grep -q '"insert_probe","insert_into".*"profile"' "$profile_index" \
    || fail "load_profile.csv is missing the INSERT profile"
grep -q '"dates_probe","s3_load".*"profile"' "$profile_index" \
    || fail "load_profile.csv is missing the S3 profile"
grep -q '"stream_load".*"stream_load_response"' "$profile_index" \
    || fail "load_profile.csv is missing the Stream Load response"

if grep -Eq 'WARN: (No load profile ID|Load profile fetch returned empty)' "$run_log"; then
    fail "benchmark reported a missing load profile"
fi

profile_after=$(run_mysql -e "SELECT @@global.enable_profile;" | tail -n 1)
[ "$profile_before" = "$profile_after" ] \
    || fail "global enable_profile changed from ${profile_before} to ${profile_after}"

database_count=$(run_mysql -e \
    "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = '${integration_db}';")
[ "$database_count" = "0" ] || fail "temporary database was not dropped"

insert_profile_id=$(awk -F ': ' '/Profile ID:/ {print $2; exit}' "$insert_profile")
s3_profile_id=$(awk -F ': ' '/Profile ID:/ {print $2; exit}' "$s3_profile")
query_profile_id=$(awk -F ': ' '/Profile ID:/ {print $2; exit}' "$query_profile")

echo "DORIS_LOAD_PROFILE_INTEGRATION_TEST=PASS"
echo "DORIS_VERSION=${doris_version:-unknown}"
echo "INSERT_PROFILE_ID=${insert_profile_id}"
echo "S3_LOAD_PROFILE_ID=${s3_profile_id}"
echo "QUERY_PROFILE_ID=${query_profile_id}"
echo "STREAM_LOAD_METRICS=$(jq -c \
    '{TxnId,LoadTimeMs,WriteDataTimeMs,CommitAndPublishTimeMs}' "$stream_response")"
echo "GLOBAL_ENABLE_PROFILE_BEFORE=${profile_before}"
echo "GLOBAL_ENABLE_PROFILE_AFTER=${profile_after}"
echo "TEMPORARY_DATABASE_DROPPED=true"

if [[ "$keep_artifacts" == "true" ]]; then
    echo "RESULT_DIR=${result_dir}"
else
    echo "RESULT_DIR=<removed after assertions>"
fi
