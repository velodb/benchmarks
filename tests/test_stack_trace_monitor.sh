#!/usr/bin/env bash
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/.." && pwd)"

source "$REPO_ROOT/benchmark.sh"

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

assert_file_contains() {
    local file="$1"
    local pattern="$2"
    if ! grep -Fq -- "$pattern" "$file"; then
        echo "File did not contain expected pattern: $file" >&2
        echo "Expected: $pattern" >&2
        echo "--- file content ---" >&2
        sed -n '1,120p' "$file" >&2
        fail "missing pattern"
    fi
}

test_collect_stack_trace_once_uses_be_http_port_and_keeps_failures_nonfatal() {
    local tmp_dir mock_bin be1_file be2_file output
    tmp_dir="$(mktemp -d)"
    mock_bin="$tmp_dir/bin"
    mkdir -p "$mock_bin" "$tmp_dir/results"

    cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
url="${!#}"
if [[ "$url" == *"be2"* ]]; then
    echo "simulated failure" >&2
    exit 7
fi
printf 'stack trace for %s\n' "$url"
MOCK
    chmod +x "$mock_bin/curl"

    output="$(PATH="$mock_bin:$PATH" \
    CURL_LOG="$tmp_dir/curl.log" \
    RESULT_DIR="$tmp_dir/results" \
    be_hosts="be1,be2" \
    be_http_port="18040" \
    user="bench" \
    password="" \
    STACK_TRACE_MONITOR_DIR="" \
        collect_stack_trace_once)"

    be1_file="$(find "$tmp_dir/results/stack_trace/be1" -type f -name '*.txt' | head -n 1)"
    be2_file="$(find "$tmp_dir/results/stack_trace/be2" -type f -name '*.txt' | head -n 1)"
    [ -n "$be1_file" ] || fail "missing be1 stack trace file"
    [ -n "$be2_file" ] || fail "missing be2 stack trace file"

    assert_file_contains "$tmp_dir/curl.log" "http://be1:18040/api/stack_trace"
    assert_file_contains "$tmp_dir/curl.log" "http://be2:18040/api/stack_trace"
    assert_file_contains "$be1_file" "stack trace for http://be1:18040/api/stack_trace"
    assert_file_contains "$be2_file" "ERROR: stack trace fetch failed for be2"
    printf '%s\n' "$output" > "$tmp_dir/output.log"
    assert_file_contains "$tmp_dir/output.log" "Stack trace saved: $be1_file"
    assert_file_contains "$tmp_dir/output.log" "Stack trace saved: $be2_file"
}

test_archive_and_upload_stack_traces_uses_file_server_and_logs_public_url() {
    local tmp_dir mock_bin archive_path
    tmp_dir="$(mktemp -d)"
    mock_bin="$tmp_dir/bin"
    mkdir -p "$mock_bin" "$tmp_dir/results/stack_trace/be1"
    printf 'sample stack trace\n' > "$tmp_dir/results/stack_trace/be1/20260101_000000.txt"

    cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
url="${!#}"
[[ "$url" == http://justtmp.oss-cn-beijing-internal.aliyuncs.com/rqg-abtest/case_result/00000000-0000-0000-0000-000000000001/stack_trace_20260101_000000.tar.gz ]] || exit 4
for ((i=1; i<=$#; i++)); do
    if [[ "${!i}" == "-T" ]]; then
        next=$((i + 1))
        [ -f "${!next}" ] || exit 3
    fi
done
MOCK
    chmod +x "$mock_bin/curl"

    output="$(PATH="$mock_bin:$PATH" \
    CURL_LOG="$tmp_dir/curl.log" \
    RESULT_DIR="$tmp_dir/results" \
    STACK_TRACE_MONITOR_DIR="$tmp_dir/results/stack_trace" \
    TIMESTAMP="20260101_000000" \
    FILE_SERVER_ENDPOINT="http://justtmp.oss-cn-beijing-internal.aliyuncs.com" \
    STACK_TRACE_UPLOAD_UID="00000000-0000-0000-0000-000000000001" \
        archive_and_upload_stack_traces)"

    archive_path="$tmp_dir/results/stack_trace_20260101_000000.tar.gz"
    [ -f "$archive_path" ] || fail "missing stack trace archive"
    assert_file_contains "$tmp_dir/curl.log" "-H Content-Disposition: inline"
    assert_file_contains "$tmp_dir/curl.log" "-T $archive_path"
    printf '%s\n' "$output" > "$tmp_dir/output.log"
    assert_file_contains "$tmp_dir/output.log" "Stack trace archive URL: http://justtmp.oss-cn-beijing.aliyuncs.com/rqg-abtest/case_result/00000000-0000-0000-0000-000000000001/stack_trace_20260101_000000.tar.gz"
}

test_archive_upload_failure_is_nonfatal() {
    local tmp_dir mock_bin archive_path
    tmp_dir="$(mktemp -d)"
    mock_bin="$tmp_dir/bin"
    mkdir -p "$mock_bin" "$tmp_dir/results/stack_trace/be1"
    printf 'sample stack trace\n' > "$tmp_dir/results/stack_trace/be1/20260101_000000.txt"

    cat > "$mock_bin/curl" <<'MOCK'
#!/usr/bin/env bash
exit 9
MOCK
    chmod +x "$mock_bin/curl"

    PATH="$mock_bin:$PATH" \
    RESULT_DIR="$tmp_dir/results" \
    STACK_TRACE_MONITOR_DIR="$tmp_dir/results/stack_trace" \
    TIMESTAMP="20260101_000000" \
    STACK_TRACE_UPLOAD_UID="00000000-0000-0000-0000-000000000002" \
        archive_and_upload_stack_traces

    archive_path="$tmp_dir/results/stack_trace_20260101_000000.tar.gz"
    [ -f "$archive_path" ] || fail "missing archive after failed upload"
}

test_collect_stack_trace_once_uses_be_http_port_and_keeps_failures_nonfatal
test_archive_and_upload_stack_traces_uses_file_server_and_logs_public_url
test_archive_upload_failure_is_nonfatal
echo "stack trace monitor tests passed"
