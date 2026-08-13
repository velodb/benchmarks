#!/bin/bash

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$TEST_DIR/.." && pwd)"

# shellcheck source=../benchmark.sh
source "$REPO_DIR/benchmark.sh"
# shellcheck source=../engines/interface.sh
source "$REPO_DIR/engines/interface.sh"

test_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/load_profile_test.XXXXXX")
cleanup() {
    find "$test_tmp_dir" -depth -delete
}
trap cleanup EXIT

profile="true"
RESULT_DIR="$test_tmp_dir/result"
LOAD_PROFILE_DIR="$RESULT_DIR/profile/load"
LOAD_PROFILE_INDEX="$RESULT_DIR/load_profile.csv"
mkdir -p "$LOAD_PROFILE_DIR"
echo 'load_name,method,profile_id,artifact_type,file' > "$LOAD_PROFILE_INDEX"

password="secret-password"
PASSWORD="$password"
STORAGE_ACCESS_KEY="access-key"
STORAGE_SECRET_KEY="storage-secret"
LAST_LOAD_PROFILE_ID="abc-123"
LAST_LOAD_PROFILE_LABEL="load_label_1"
LAST_LOAD_DIAGNOSTICS="JobId: 42"

engine_supports_load_profile() { return 0; }
engine_fetch_load_profile() {
    printf '%s\n' "SQL password=secret-password access-key storage-secret"
}

collect_load_profile_artifacts "001_orders" "orders" "insert_into"
profile_file=$(find "$LOAD_PROFILE_DIR" -name '*_profile.txt' -type f)
grep -q '\[REDACTED\]' "$profile_file"
if grep -Eq 'secret-password|access-key|storage-secret' "$profile_file"; then
    echo "sensitive profile values were not redacted" >&2
    exit 1
fi
grep -q 'insert_into' "$LOAD_PROFILE_INDEX"

label_sql="$test_tmp_dir/load.sql"
printf '%s\n' \
    'LOAD LABEL db.orders_20260813' \
    '(DATA INFILE("s3://bucket/a") INTO TABLE orders)' > "$label_sql"
if [ "$(mysql_engine_extract_load_label "$label_sql")" != "orders_20260813" ]; then
    echo "failed to extract a database-qualified Broker Load label" >&2
    exit 1
fi

# shellcheck source=../lib/doris_stream_load_utils.sh
source "$REPO_DIR/lib/doris_stream_load_utils.sh"
LOAD_PROFILE_ARTIFACT_PREFIX="002_hits"
export RESULT_DIR LOAD_PROFILE_DIR LOAD_PROFILE_INDEX LOAD_PROFILE_ARTIFACT_PREFIX
do_curl() {
    printf '%s' '{"TxnId":99,"Label":"stream_label","Status":"Success","Message":"secret-password","LoadTimeMs":12}'
}
run_doris_stream_load "stream_label" "/dev/null"
stream_response=$(find "$LOAD_PROFILE_DIR" -name '*_stream_load_response.*' -type f)
grep -q 'TxnId' "$stream_response"
grep -q '\[REDACTED\]' "$stream_response"
if grep -q 'secret-password' "$stream_response"; then
    echo "sensitive Stream Load response values were not redacted" >&2
    exit 1
fi
grep -q 'stream_load_response' "$LOAD_PROFILE_INDEX"

echo "load profile helper tests passed"
