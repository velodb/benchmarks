#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${repo_root}/lib/jmx_generator.sh"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

engine_get_jdbc_datasource() {
  echo '<JDBCDataSource testname="JDBC Connection Configuration"/>'
}

engine_get_jdbc_sampler_name() {
  echo "test_ds"
}

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

TEST_ROOT="${tmp_dir}/suite"
CONFIG_FILE="${TEST_ROOT}/benchmark.yaml"
RESULT_DIR="${tmp_dir}/result"
QUERY_DIR="${TEST_ROOT}/custom_queries"
mkdir -p "${QUERY_DIR}" "${RESULT_DIR}"

printf '%s\n' \
  "paths:" \
  "  query_dir: custom_queries/" \
  "  query_mode: file" \
  > "${CONFIG_FILE}"
printf 'SELECT 1;\n' > "${QUERY_DIR}/q1.sql"

threads=4
loops=1
duration=1
query_by_query=true

generate_jmx

grep -q '<ThreadGroup ' "${RESULT_DIR}/benchmark.jmx"
grep -q '<JDBCSampler ' "${RESULT_DIR}/benchmark.jmx"
grep -q 'SELECT 1;' "${RESULT_DIR}/benchmark.jmx"

QUERY_DIR="${TEST_ROOT}/missing_queries"
if (generate_jmx) >/dev/null 2>&1; then
  echo "expected empty query directory to fail" >&2
  exit 1
fi

printf '%s\n' \
  "paths:" \
  "  query_dirs:" \
  "    - custom_queries/" \
  "  query_mode: file" \
  > "${CONFIG_FILE}"
QUERY_DIR="${TEST_ROOT}/custom_queries"
if (generate_jmx) 2>"${tmp_dir}/legacy-query-dirs.err"; then
  echo "expected paths.query_dirs to be rejected" >&2
  exit 1
fi
grep -q 'paths.query_dirs is no longer supported' "${tmp_dir}/legacy-query-dirs.err"

echo "PASS: JMeter generator uses query_dir, rejects query_dirs and zero queries"
