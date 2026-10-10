#!/bin/bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../engines/doris_engine.sh"
BE_HOSTS_ARR=(be-a be-b)
user=test-user
password=test-password
clear_file_cache_max_size_gb=0
calls=()
mode=ok
curl_capture_or_log() {
    local result_name="$1"
    shift 2
    local url="${!#}" payload
    calls+=("$url")
    case "$url" in
        */api/clear_cache/SegmentCache)
            [[ " $* " == *" -u test-user:test-password "* ]] || return 9
            if [[ "$mode" == http_failure ]]; then return 22; fi
            payload='ClearCacheAction cache:SegmentCache prune win, freed size 1024'
            if [[ "$mode" == unexpected_body ]]; then payload='not allowed'; fi
            ;;
        */api/file_cache\?op=clear\&sync=true)
            [[ " $* " == *" -u test-user:test-password "* ]] || return 9
            payload='{"status":"OK"}'
            ;;
        */brpc_metrics)
            payload='file_cache_cache_size 0'
            ;;
        *) return 9 ;;
    esac
    printf -v "$result_name" '%s' "$payload"
}
clear_doris_file_cache >/dev/null
[[ "${calls[*]}" == 'http://be-a:8040/api/clear_cache/SegmentCache http://be-a:8040/api/file_cache?op=clear&sync=true http://be-b:8040/api/clear_cache/SegmentCache http://be-b:8040/api/file_cache?op=clear&sync=true http://be-a:8060/brpc_metrics http://be-b:8060/brpc_metrics' ]]
for mode in http_failure unexpected_body; do
    calls=()
    if clear_doris_file_cache >/dev/null 2>&1; then
        echo "accepted failed SegmentCache clear: $mode" >&2
        exit 1
    fi
    [[ "${#calls[@]}" == 1 ]]
done
echo 'PASS: release refs before file-cache clear on every BE; authenticate; reject HTTP and invalid-response failures'
