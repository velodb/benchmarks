#!/bin/bash
# Result Generator
# 
# This module handles the generation of final benchmark results.
# It processes JMeter results and load times to create standardized result.json files.

# Generate final result
generate_result() {
    echo "Generating final report..."
    
    local result_json="$RESULT_DIR/result.json"
    local load_csv="$RESULT_DIR/load.csv"
    local query_csv="$RESULT_DIR/query.csv"
    local query_detail_csv="$RESULT_DIR/query_detail.csv"
    local jmeter_config="$RESULT_DIR/jmeter_config.json"
    local statistics_json="$RESULT_DIR/html_report/statistics.json"
    local sysbench_metrics_json="$RESULT_DIR/sysbench_metrics.json"
    local vectordb_metrics_json="$RESULT_DIR/vectordb_metrics.json"
    local create_time
    create_time=$(date '+%Y-%m-%d')

    # Resolve engine metadata (best effort)
    local engine_version
    engine_version="$(resolve_engine_version)"

    local data_size_bytes
    data_size_bytes="$(resolve_data_size_bytes)"
    
    # Check required files
    # if [ ! -f "$jmeter_config" ]; then
    #     echo "JMeter config not found, creating basic report structure"
    #     generate_basic_report "$result_json" "$create_time"
    #     return 0
    # fi
    
    local analyze_csv="$RESULT_DIR/analyze.csv"
    local analyze_times_json
    if [ -f "$analyze_csv" ]; then
        analyze_times_json=$(awk -F',' 'NR > 1 {printf "\"%s\":%.3f,", $1, $NF}' "$analyze_csv")
        analyze_times_json="{${analyze_times_json%,}}"
    else
        analyze_times_json="{}"
    fi

    # Prepare load times data as a JSON object {table_name: load_time}
    local load_times_json
    if [ -f "$load_csv" ]; then
        # generate {table_name: load_time} JSON object
        # The format is table_name,method,load_time_seconds or table_name,load_time_seconds
        load_times_json=$(awk -F',' 'NR > 1 && $NF != "ERROR" {printf "\"%s\":%.3f,", $1, $NF}' "$load_csv")
        load_times_json="{${load_times_json%,}}"
    else
        load_times_json="{}"
    fi
    # Process query times data as a JSON object {query_name: [times]}
    local query_times_json
    if [ -f "$query_csv" ]; then
        # generate {query_name: [times]} JSON object
        query_times_json=$(awk -F',' 'NR > 1 {
            printf "\"%s\":[", $1;
            for(i=2; i<=NF; i++) {
                if($i == "null") {
                    printf "null";
                } else {
                    printf "%.3f", $i;
                }
                if(i < NF) {
                    printf ",";
                }
            }
            printf "],"
        }' "$query_csv")
        query_times_json="{${query_times_json%,}}"
    else
        query_times_json="{}"
    fi

    local query_run_times_json
    if [ -f "$query_detail_csv" ]; then
        query_run_times_json=$(awk -F',' '
            function append_number(list, value) {
                if (value == "null" || value == "") {
                    value = "null"
                } else {
                    value = sprintf("%.3f", value)
                }
                return list (list == "" ? "" : ",") value
            }
            NR == 1 {
                for (i = 2; i <= NF; i++) {
                    header[i] = $i
                }
                next
            }
            NR > 1 {
                cold = ""
                hot = ""
                hot_min = "null"
                for (i = 2; i <= NF; i++) {
                    if (header[i] ~ /^cold_[0-9]+$/) {
                        cold = append_number(cold, $i)
                    } else if (header[i] ~ /^hot_[0-9]+$/) {
                        hot = append_number(hot, $i)
                    } else if (header[i] == "hot_min") {
                        hot_min = ($i == "null" || $i == "") ? "null" : sprintf("%.3f", $i)
                    }
                }
                printf "\"%s\":{\"cold\":[%s],\"hot\":[%s],\"hot_min\":%s},", $1, cold, hot, hot_min
            }
        ' "$query_detail_csv")
        query_run_times_json="{${query_run_times_json%,}}"
    else
        query_run_times_json="{}"
    fi

    # Process JMeter results
    # Read JMeter configuration and statistics
    local jmeter_config_content statistics_content
    if [ -f "$jmeter_config" ]; then
      jmeter_config_content=$(cat "$jmeter_config")
    else
      jmeter_config_content="{}"
    fi
    if [ -f "$statistics_json" ]; then
        statistics_content=$(cat "$statistics_json")
    else
        statistics_content="{}"
    fi
    
    # Get sorted query keys using version sort
    local sorted_keys_json
    if [ -f "$statistics_json" ]; then
        sorted_keys_json=$(jq -r --argjson stats "$statistics_content" '$stats | to_entries | map(select(.key != "Total") | .key) | .[]' <<< 'null' | sort -V | jq -R -s -c 'split("\n") | map(select(length > 0))')
    else
        sorted_keys_json="[]"
    fi

    # Generate comprehensive result.json using jq with version-sorted keys
    jq -n \
      --arg system "$ENGINE_TYPE" \
      --arg create_time "$create_time" \
      --arg version "$engine_version" \
      --arg machine "$(hostname)" \
      --arg suite "${SUITE_NAME:-}" \
      --arg scale "${SCALE_FACTOR:-}" \
      --argjson load_times "$load_times_json" \
      --argjson analyze_times "$analyze_times_json" \
      --argjson query_times "$query_times_json" \
      --argjson query_run_times "$query_run_times_json" \
      --argjson jmeter_config "$jmeter_config_content" \
      --argjson stats "$statistics_content" \
      --argjson sorted_keys "$sorted_keys_json" \
      --argjson data_size_bytes "$data_size_bytes" \
      '
      # 1. Construct Metadata
      {
        metadata: {
          system: $system,
          version: $version,
          create_time: $create_time,
          machine: $machine,
          suite: $suite,
          scale: $scale,
          cluster_size: 1,
          tags: ["benchmark", $system]
        }
      } |
      # 2. Construct Load Results
      .results.load = {
        load_times: $load_times,
        data_size_bytes: $data_size_bytes
      } |
      # 3. Construct Analyze Results
      .results.analyze = {
        analyze_times: $analyze_times
      } |
      # 4. Construct Query Times Results
      .results.query = {
        query_times: $query_times,
        query_run_times: $query_run_times
      } |
      # 5. Construct JMeter Results
      .results.jmeter = {
        test_results: [
          {
            config: $jmeter_config,
            queries: (
              # Create a lookup map for all query data
              ($stats | to_entries | map(
                select(.key != "Total") |
                {
                  key: .key,
                  value: {
                    qps:    (.value.throughput // 0 | . / 1),
                    avg:    (.value.meanResTime // 0 | . / 1000),
                    min:    (.value.minResTime // 0 | . / 1000),
                    max:    (.value.maxResTime // 0 | . / 1000),
                    "99th": (.value.pct3ResTime // 0 | . / 1000),
                    sample: (.value.sampleCount // 0),
                    error:  (.value.errorCount // 0)
                  }
                }
              ) | from_entries) as $query_data |
              
              # Build ordered result using sorted keys
              $sorted_keys | map(select(. as $key | $query_data | has($key)) | {key: ., value: $query_data[.]}) | from_entries
            ),
            total: ($stats.Total // {})
          }
        ]
      }
      ' > "$result_json"

    if [ -f "$sysbench_metrics_json" ]; then
        local sysbench_tmp_json="$RESULT_DIR/.result_sysbench.json"
        if jq --argjson sysbench_metrics "$(cat "$sysbench_metrics_json")"             '.results.sysbench = $sysbench_metrics' "$result_json" > "$sysbench_tmp_json"; then
            mv "$sysbench_tmp_json" "$result_json"
        else
            rm -f "$sysbench_tmp_json"
            echo "ERROR: Failed to merge sysbench metrics into result.json" >&2
        fi
    fi

    if [ -f "$vectordb_metrics_json" ]; then
        local vectordb_tmp_json="$RESULT_DIR/.result_vectordb.json"
        if jq --argjson vectordb_metrics "$(cat "$vectordb_metrics_json")" \
            '.results.vectordb = $vectordb_metrics' "$result_json" > "$vectordb_tmp_json"; then
            mv "$vectordb_tmp_json" "$result_json"
        else
            rm -f "$vectordb_tmp_json"
            echo "ERROR: Failed to merge VectorDBBench metrics into result.json" >&2
        fi
    fi

    # Validate the final JSON output
    if jq '.' "$result_json" >/dev/null 2>&1; then
        echo "Report generated: $result_json"
    else
        echo "ERROR: Generated JSON is invalid, falling back to basic structure" >&2
        generate_basic_report "$result_json" "$create_time"
    fi

    # Sync to latest result for fixed-path access
    local latest_result="$(dirname "$RESULT_DIR")/result.json"
    cp "$result_json" "$latest_result"
    echo "Latest result synced to: $latest_result"
}

# Generate basic report structure when detailed processing fails
generate_basic_report() {
    local result_json="$1"
    local create_time="$2"
    local engine_version
    engine_version="$(resolve_engine_version)"
    local data_size_bytes
    data_size_bytes="$(resolve_data_size_bytes)"
    
    cat > "$result_json" << EOF
{
  "metadata": {
    "system": "$ENGINE_TYPE",
    "version": "$engine_version",
    "create_time": "$create_time",
    "machine": "$(hostname)",
    "suite": "${SUITE_NAME:-}",
    "scale": "${SCALE_FACTOR:-}",
    "cluster_size": 1,
    "tags": ["benchmark", "$ENGINE_TYPE"]
  },
  "results": {
    "load": {
      "load_times": {},
      "data_size_bytes": $data_size_bytes
    },
    "analyze": {
      "analyze_times": {}
    },
    "query": {
      "query_times": {}
    },
    "jmeter": {
      "test_results": []
    },
    "sysbench": {}
  }
}
EOF
    
    echo "Basic report generated: $result_json"
}
# Resolve engine version (engine-specific function only)
resolve_engine_version() {
    local version
    version="$(engine_get_version 2>/dev/null || true)"
    version="$(echo "$version" | head -n 1 | tr -d '\r')"
    version="$(normalize_version "$version")"
    if [ -n "$version" ]; then
        echo "$version"
        return 0
    fi
    echo ""
}

# Normalize version strings to the first numeric token (e.g., 4.0.2-rc01)
normalize_version() {
    local raw="$1"
    local v=""
    v="$(echo "$raw" | grep -Eo '[0-9]+([.][0-9]+)+([-.][0-9A-Za-z]+)*' | head -n 1)"
    if [ -z "$v" ]; then
        v="$(echo "$raw" | awk '{$1=$1; print}')"
    fi
    echo "$v"
}

# Resolve data size in bytes (engine-specific function only)
resolve_data_size_bytes() {
    local size=""
    if [ -n "${DATA_SIZE_BYTES:-}" ]; then
        size="${DATA_SIZE_BYTES}"
    elif [ -n "${data_size_bytes:-}" ]; then
        size="${data_size_bytes}"
    fi

    if [ -z "$size" ]; then
        local size_path=""
        if [ -n "${DATA_SIZE_PATH:-}" ]; then
            size_path="${DATA_SIZE_PATH}"
        elif [ -n "${data_size_path:-}" ]; then
            size_path="${data_size_path}"
        elif [ -n "${DORIS_HOME:-}" ] && [ -d "${DORIS_HOME}/be/storage" ]; then
            size_path="${DORIS_HOME}/be/storage"
        elif [ -n "${STARROCKS_HOME:-}" ] && [ -d "${STARROCKS_HOME}/be/storage" ]; then
            size_path="${STARROCKS_HOME}/be/storage"
        fi

        if [ -n "$size_path" ]; then
            local total=0
            local normalized
            normalized="$(echo "$size_path" | tr ';' ',' )"
            local -a paths=()
            IFS=',' read -ra paths <<< "$normalized"
            for path in "${paths[@]}"; do
                path="$(echo "$path" | awk '{$1=$1; print}')"
                if [ -n "$path" ] && [ -e "$path" ]; then
                    local bytes
                    bytes="$(du -bs "$path" 2>/dev/null | awk '{print $1}')"
                    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
                        total=$((total + bytes))
                    fi
                fi
            done
            if [ "$total" -gt 0 ]; then
                size="$total"
            fi
        fi
    fi

    if [ -z "$size" ]; then
        if [ -n "${RESULT_DIR:-}" ]; then
            for candidate in "${RESULT_DIR}/storage_size" "${RESULT_DIR}/data_size_bytes"; do
                if [ -f "$candidate" ]; then
                    size="$(head -n 1 "$candidate" | tr -d '\r')"
                    break
                fi
            done
        fi
        if [ -z "$size" ] && [ -n "${TEST_ROOT:-}" ] && [ -f "${TEST_ROOT}/storage_size" ]; then
            size="$(head -n 1 "${TEST_ROOT}/storage_size" | tr -d '\r')"
        fi
        if [ -z "$size" ] && [ -f "storage_size" ]; then
            size="$(head -n 1 "storage_size" | tr -d '\r')"
        fi
    fi

    if [ -z "$size" ]; then
        size="$(engine_get_data_size_bytes 2>/dev/null || true)"
    fi
    size="$(echo "$size" | head -n 1 | tr -d '\r')"

    size="$(echo "$size" | awk '{$1=$1; print}')"
    if [[ "$size" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        printf "%.0f" "$size"
    else
        echo "0"
    fi
}
