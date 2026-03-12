#!/bin/bash

# VectorDBBench Runner for Benchmark Framework
# This script handles the execution of zilliztech/VectorDBBench

execute_vectordbbench_task() {
    echo "==== Starting VectorDBBench Phase ===="
    
    # 1. Environment and Dependency Check
    export PATH="$PATH:$HOME/.local/bin"
    local vdb_cmd="vectordbbench"

    if ! command -v "$vdb_cmd" > /dev/null 2>&1; then
        echo "  VectorDBBench not found. Attempting to install..."
        if ! pip3 install --user -U vectordb-bench doris-vector-search mysql-connector-python; then
            echo "ERROR: Failed to install VectorDBBench dependencies via pip3."
            return 1
        fi
        
        # Verify again after install
        if [ -f "$HOME/.local/bin/vectordbbench" ]; then
            vdb_cmd="$HOME/.local/bin/vectordbbench"
        else
            echo "ERROR: vectordbbench installed but not found in $HOME/.local/bin."
            return 1
        fi
        echo "  VectorDBBench installed successfully."
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
            if grep -q '"qps": [0-9.]*[1-9]' "$result_file" || grep -q '"load_dur": [0-9.]*[1-9]' "$result_file"; then
                echo "  Result validation successful: $result_file"
                echo ""
                echo "=========================================================="
                echo "            VectorDBBench Performance Results             "
                echo "=========================================================="
                python3 -c "
import json, sys
try:
    with open('$result_file', 'r') as f:
        data = json.load(f)
        results = data.get('results', [])
        if results:
            m = results[0].get('metrics', {})
            fields = ['qps', 'serial_latency_p99', 'recall', 'insert_duration', 'optimize_duration', 'load_duration']
            print('\n'.join([f'{field}: {m.get(field, \"N/A\")}' for field in fields]))
except Exception as e:
    print(f'Error parsing result JSON: {e}')
"
                echo "=========================================================="
                echo "==== VectorDBBench Phase Completed Successfully ===="
                return 0
            else
                echo "  ERROR: VectorDBBench finished but metrics are empty (Zero QPS/Load Duration). Check logs for process crashes." >&2
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
