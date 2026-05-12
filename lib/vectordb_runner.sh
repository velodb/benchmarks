#!/bin/bash

# VectorDBBench Runner for Benchmark Framework
# This script handles the execution of zilliztech/VectorDBBench

extract_vectordbbench_metrics_json() {
    local result_file="$1"
    local metrics_file="$2"

    if ! jq -e '
        def metrics:
          if ((.results? | type) == "array"
              and (.results | length) > 0
              and ((.results[0].metrics? | type) == "object")) then
            .results[0].metrics
          elif ((.metrics? | type) == "object") then
            .metrics
          else
            .
          end;

        metrics as $m
        | {
            qps: $m.qps,
            serial_latency_p99: $m.serial_latency_p99,
            recall: $m.recall,
            insert_duration: ($m.insert_duration // $m.insert_dur),
            optimize_duration: ($m.optimize_duration // $m.optimize_dur),
            load_duration: ($m.load_duration // $m.load_dur)
          } as $result
        | ([ $result | to_entries[] | select(.value == null) | .key ]) as $missing
        | if ($missing | length) > 0 then
            error("missing metric fields: " + ($missing | join(", ")))
          elif (($result.qps <= 0) and ($result.load_duration <= 0)) then
            error("metrics are empty (Zero QPS/Load Duration)")
          else
            $result
          end
    ' "$result_file" > "$metrics_file"; then
        rm -f "$metrics_file"
        echo "Error extracting VectorDBBench metrics from $result_file" >&2
        return 1
    fi

    jq -r 'to_entries[] | "\(.key): \(.value)"' "$metrics_file"
}

execute_vectordbbench_task() {
    echo "==== Starting VectorDBBench Phase ===="
    
    # Discover project root (one level up from lib/)
    local base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    
    # 1. Environment and Dependency Check
    if ! init_vectordbbench; then
        echo "ERROR: Failed to initialize VectorDBBench." >&2
        return 1
    fi

    local vdb_cmd="${VECTORDBBENCH_BIN:-$(command -v vectordbbench)}"
    if [ -z "$vdb_cmd" ] || [ ! -x "$vdb_cmd" ]; then
        echo "ERROR: VectorDBBench binary not found after initialization." >&2
        return 1
    fi

    # 2. Extract and expand configurations from YAML using yq
    local case_type=$(eval echo $(yq eval '.vectordbbench.case.type' "$CONFIG_FILE"))
    local task_label=$(eval echo $(yq eval '.vectordbbench.case.task_label' "$CONFIG_FILE"))
    local db_label=$(eval echo $(yq eval '.vectordbbench.case.db_label' "$CONFIG_FILE"))
    local concurrency=$(eval echo $(yq eval '.vectordbbench.test.concurrency' "$CONFIG_FILE"))
    local num_per_batch=$(eval echo $(yq eval '.vectordbbench.test.num_per_batch' "$CONFIG_FILE"))
    local batch_size=$(eval echo $(yq eval '.vectordbbench.test.stream_load_rows_per_batch // .vectordbbench.test.rows_per_batch // "100000"' "$CONFIG_FILE"))
    local index_prop=$(eval echo $(yq eval '.vectordbbench.index.properties' "$CONFIG_FILE"))
    local session_var=$(eval echo $(yq eval '.vectordbbench.index.session_vars' "$CONFIG_FILE"))
    
    local dataset_source=$(eval echo $(yq eval '.vectordbbench.storage.dataset_source' "$CONFIG_FILE"))
    local dataset_dir=$(eval echo $(yq eval '.vectordbbench.storage.dataset_local_dir' "$CONFIG_FILE"))
    local result_dir=$(eval echo $(yq eval '.vectordbbench.storage.results_local_dir' "$CONFIG_FILE"))

    # Normalize relative paths to absolute (anchored to base_dir)
    [[ "$dataset_dir" != /* ]] && dataset_dir="$base_dir/$dataset_dir"
    [[ "$result_dir" != /* ]] && result_dir="$base_dir/$result_dir"

    # 3. Setup Environment Variables for VectorDBBench
    export DATASET_SOURCE="$dataset_source"
    export DATASET_LOCAL_DIR="$dataset_dir"
    export RESULTS_LOCAL_DIR="$result_dir"
    export NUM_PER_BATCH="$num_per_batch"

    mkdir -p "$dataset_dir"
    mkdir -p "$result_dir"

    # 4. Ensure Database Exists (Doris requires explicit creation)
    echo "  Ensuring database $db exists..."
    export MYSQL_PWD="${password:-}"
    mysql -h"$fe_host" -P"$fe_query_port" -u"$user" -e "CREATE DATABASE IF NOT EXISTS $db" || echo "Warning: Failed to ensure database exists, attempting to proceed..."

    echo "  Case Type: $case_type"
    echo "  Concurrency: $concurrency"
    echo "  Results: $result_dir"

    # 6. Assemble and Execute Command
    local cmd="$vdb_cmd doris \
        --case-type=$case_type \
        --task-label=$task_label \
        --db-label=standard \
        --host=$fe_host \
        --port=$fe_query_port \
        --http-port=$fe_http_port \
        --username=$user \
        --password=$password \
        --db-name=$db \
        --num-concurrency=$concurrency \
        --stream-load-rows-per-batch=$batch_size \
        --index-prop=$index_prop \
        --session-var=$session_var"

    echo "  Executing: $cmd"
    if eval "$cmd"; then
        echo "  VectorDBBench command finished. Validating results..."
        
        # Find the latest JSON result for this task in the specified results directory
        local result_file
        result_file=$(ls -t "$result_dir"/Doris/result_*_"${task_label}"_*.json 2>/dev/null | head -n 1)
        
        if [ -n "$result_file" ] && [ -f "$result_file" ]; then
            local compact_metrics
            local vectordb_metrics_file="${RESULT_DIR:-$result_dir}/vectordb_metrics.json"
            mkdir -p "$(dirname "$vectordb_metrics_file")"
            if compact_metrics=$(extract_vectordbbench_metrics_json "$result_file" "$vectordb_metrics_file"); then
                echo "  Result validation successful: $result_file"
                echo "  VectorDBBench metrics written: $vectordb_metrics_file"
                echo ""
                echo "=========================================================="
                echo "            VectorDBBench Performance Results             "
                echo "=========================================================="
                printf "%s\n" "$compact_metrics"
                echo "=========================================================="
                echo "==== VectorDBBench Phase Completed Successfully ===="
                return 0
            else
                echo "  ERROR: VectorDBBench finished but result metrics are invalid. Check logs for process crashes." >&2
                return 1
            fi
        else
            echo "  ERROR: VectorDBBench finished but no result file found." >&2
            return 1
        fi
    else
        echo "  ERROR: VectorDBBench command failed with exit code $?" >&2
        return 1
    fi
}
