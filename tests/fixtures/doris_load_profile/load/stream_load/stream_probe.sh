#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../../../lib/doris_stream_load_utils.sh
source "${SCRIPT_DIR}/../../../../../lib/doris_stream_load_utils.sh"

table="stream_probe"
host="${fe_host:-${FE_HOST:-127.0.0.1}}"
http_port="${fe_http_port:-${FE_HTTP_PORT:-8030}}"
db="${db:-${DB:-benchmark_load_profile_integration}}"
user_="${user:-${DB_USER:-root}}"
pass="${password:-${PASSWORD:-}}"
label="bench_${db}_${table}_${RANDOM}_$$"
url="http://${host}:${http_port}/api/${db}/${table}/_stream_load"

do_curl() {
    local this_label="$1"
    local input_file="$2"

    curl -sS --fail-with-body --location-trusted \
        -u "${user_}:${pass}" \
        -H "Expect: 100-continue" \
        -H "format:csv" \
        -H "column_separator:," \
        -H "label:${this_label}" \
        -T "$input_file" \
        "$url"
}

run_doris_stream_load "$label" "$SCRIPT_DIR/stream_probe.csv" "full file"
printf '%s\n' "$resp"
printf '%s' "$resp" | grep -Eqi '"status"[[:space:]]*:[[:space:]]*"success"'
