#!/bin/bash
# JMeter JMX Generator
#
# This module handles the generation of JMeter JMX test files for database benchmarks.
# It creates JMeter test plans with JDBC connections and query samplers.

# XML escape function (utility for JMX generation)
# Use sed for better compatibility across different environments
xml_escape() {
    local content="$1"
    echo "$content" | sed -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

# Helper function to add JDBC Sampler under Random Controller (for concurrent mode)
add_jdbc_sampler_to_random_controller() {
    local jmx_file="$1"
    local query_name="$2"
    local escaped_sql="$3"
    local datasource_name="$4"
    
    # Add JDBC Sampler under Random Controller
    cat >> "$jmx_file" << EOF
        <JDBCSampler guiclass="TestBeanGUI" testclass="JDBCSampler" testname="${query_name}" enabled="true">
          <stringProp name="dataSource">${datasource_name}</stringProp>
          <stringProp name="queryType">Select Statement</stringProp>
          <stringProp name="query">${escaped_sql}</stringProp>
        </JDBCSampler>
        <hashTree/>
EOF
}

# Helper function to add ThreadGroup and JDBC Sampler to JMX file (for query-by-query mode)
add_thread_group_and_sampler() {
    local jmx_file="$1"
    local query_name="$2"
    local escaped_sql="$3"
    local threads="$4"
    local loops="$5"
    local duration="$6"
    local datasource_name="$7"
    
    # Add ThreadGroup for this query
    cat >> "$jmx_file" << EOF
      <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="${query_name} Thread Group" enabled="true">
        <stringProp name="ThreadGroup.on_sample_error">continue</stringProp>
EOF
    
    # Add thread group configuration based on duration vs loops
    if [ "$duration" -gt 0 ]; then
        # Duration-based test
        cat >> "$jmx_file" << EOF
        <elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController" testname="Loop Controller" enabled="true">
          <boolProp name="LoopController.continue_forever">true</boolProp>
          <stringProp name="LoopController.loops">-1</stringProp>
        </elementProp>
        <stringProp name="ThreadGroup.num_threads">${threads}</stringProp>
        <stringProp name="ThreadGroup.ramp_time">0</stringProp>
        <stringProp name="ThreadGroup.duration">${duration}</stringProp>
        <stringProp name="ThreadGroup.delay"></stringProp>
        <boolProp name="ThreadGroup.scheduler">true</boolProp>
EOF
    else
        # Loop-based test
        cat >> "$jmx_file" << EOF
        <elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController" testname="Loop Controller" enabled="true">
          <boolProp name="LoopController.continue_forever">false</boolProp>
          <stringProp name="LoopController.loops">${loops}</stringProp>
        </elementProp>
        <stringProp name="ThreadGroup.num_threads">${threads}</stringProp>
        <stringProp name="ThreadGroup.ramp_time">0</stringProp>
        <stringProp name="ThreadGroup.duration"></stringProp>
        <stringProp name="ThreadGroup.delay"></stringProp>
        <boolProp name="ThreadGroup.scheduler">false</boolProp>
EOF
    fi
    
    # Add JDBC Sampler
    cat >> "$jmx_file" << EOF
      </ThreadGroup>
      <hashTree>
        <JDBCSampler guiclass="TestBeanGUI" testclass="JDBCSampler" testname="${query_name}" enabled="true">
          <stringProp name="dataSource">${datasource_name}</stringProp>
          <stringProp name="queryType">Select Statement</stringProp>
          <stringProp name="query">${escaped_sql}</stringProp>
        </JDBCSampler>
        <hashTree/>
      </hashTree>
EOF
}

# Helper function to create ThreadGroup with Random Controller for concurrent mode
add_concurrent_thread_group_with_random_controller() {
    local jmx_file="$1"
    local threads="$2"
    local loops="$3"
    local duration="$4"
    
    # Add single ThreadGroup for concurrent execution
    cat >> "$jmx_file" << EOF
      <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="Concurrent Queries Thread Group" enabled="true">
        <stringProp name="ThreadGroup.on_sample_error">continue</stringProp>
EOF
    
    # Add thread group configuration based on duration vs loops
    if [ "$duration" -gt 0 ]; then
        # Duration-based test
        cat >> "$jmx_file" << EOF
        <elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController" testname="Loop Controller" enabled="true">
          <boolProp name="LoopController.continue_forever">true</boolProp>
          <stringProp name="LoopController.loops">-1</stringProp>
        </elementProp>
        <stringProp name="ThreadGroup.num_threads">${threads}</stringProp>
        <stringProp name="ThreadGroup.ramp_time">0</stringProp>
        <stringProp name="ThreadGroup.duration">${duration}</stringProp>
        <stringProp name="ThreadGroup.delay"></stringProp>
        <boolProp name="ThreadGroup.scheduler">true</boolProp>
EOF
    else
        # Loop-based test
        cat >> "$jmx_file" << EOF
        <elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController" testname="Loop Controller" enabled="true">
          <boolProp name="LoopController.continue_forever">false</boolProp>
          <stringProp name="LoopController.loops">${loops}</stringProp>
        </elementProp>
        <stringProp name="ThreadGroup.num_threads">${threads}</stringProp>
        <stringProp name="ThreadGroup.ramp_time">0</stringProp>
        <stringProp name="ThreadGroup.duration"></stringProp>
        <stringProp name="ThreadGroup.delay"></stringProp>
        <boolProp name="ThreadGroup.scheduler">false</boolProp>
EOF
    fi
    
    # Close ThreadGroup and add Random Controller
    cat >> "$jmx_file" << EOF
      </ThreadGroup>
      <hashTree>
        <RandomController guiclass="RandomControlGui" testclass="RandomController" testname="Random Controller" enabled="true"/>
        <hashTree>
EOF
}

# Helper function to close Random Controller and ThreadGroup
close_concurrent_thread_group() {
    local jmx_file="$1"
    
    cat >> "$jmx_file" << EOF
        </hashTree>
      </hashTree>
EOF
}

# Generate JMeter JMX file
generate_jmx() {
    echo "Generating JMeter configuration..."
    
    local jmx_file="$RESULT_DIR/benchmark.jmx"
    serialize=$([ "$query_by_query" = "true" ] && echo "true" || echo "false")
    echo "Parameters: threads=$threads, loops=$loops, duration=${duration}s, query_by_query=$query_by_query"
    
    # Start JMX file with TestPlan structure
    cat > "$jmx_file" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2" properties="5.0" jmeter="5.6.3">
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="Database Benchmark" enabled="true">
      <boolProp name="TestPlan.functional_mode">false</boolProp>
      <boolProp name="TestPlan.tearDown_on_shutdown">true</boolProp>
      <boolProp name="TestPlan.serialize_threadgroups">${serialize}</boolProp>
      <elementProp name="TestPlan.arguments" elementType="Arguments" guiclass="ArgumentsPanel" testclass="Arguments" testname="User Defined Variables" enabled="true">
        <collectionProp name="Arguments.arguments"/>
      </elementProp>
      <stringProp name="TestPlan.user_define_classpath"></stringProp>
    </TestPlan>
    <hashTree>
EOF
    
    # Add JDBC DataSource configuration from engine
    if ! engine_get_jdbc_datasource >> "$jmx_file"; then
        die "Failed to get JDBC datasource configuration from engine"
    fi
    
    echo "      <hashTree/>" >> "$jmx_file"
    
    # Get datasource name for samplers
    local datasource_name
    if ! datasource_name=$(engine_get_jdbc_sampler_name); then
        die "Failed to get JDBC sampler name from engine"
    fi
    
    # Get query mode (default to 'file' for backward compatibility)
    local query_mode
    query_mode=$(yq eval '.paths.query_mode // "file"' "$CONFIG_FILE")
    echo "Query mode: $query_mode"
    
    if [ "$(yq eval '.paths.query_dirs // ""' "$CONFIG_FILE")" != "" ]; then
        die "paths.query_dirs is no longer supported; use paths.query_dir"
    fi

    # load_config exports QUERY_DIR from paths.query_dir.
    local query_dir="${QUERY_DIR:-query/}"
    
    # Collect all queries first
    local -a all_query_names=()
    local -a all_query_sqls=()
    
    # Convert relative path to absolute
    if [[ "$query_dir" != /* ]]; then
        query_dir="$TEST_ROOT/$query_dir"
    fi
    query_dir="${query_dir%/}"
    if [ -z "$query_dir" ]; then
        query_dir="/"
    fi

    if [ ! -d "$query_dir" ]; then
        echo "Query directory not found: $query_dir, skipping"
    else
        echo "Processing queries from $(basename "$query_dir")..."

        # Process all SQL files under query_dir recursively (sorted numerically)
        while IFS= read -r -d '' query_file; do
            if [ ! -f "$query_file" ]; then
                continue
            fi
            
            # Use the path relative to query_dir as the query name so nested
            # directories become part of the identifier, e.g. agg/q1.sql -> agg/q1.
            local query_name relative_path
            relative_path="${query_file#$query_dir/}"
            if [ "$relative_path" = "$query_file" ]; then
                relative_path=$(basename "$query_file")
            fi
            query_name="${relative_path%.sql}"
            
            if [ "$query_mode" = "line" ]; then
                # Line-based mode: each line is a separate query
                local query_counter=1
                while IFS= read -r line; do
                    # Skip empty lines and comments
                    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# || "$line" =~ ^[[:space:]]*-- ]]; then
                        continue
                    fi
                    
                    local full_query_name="${query_name}_q${query_counter}"
                    local escaped_sql
                    escaped_sql=$(xml_escape "$line")
                    
                    # Add to queries array: query_name and sql_content separately
                    all_query_names+=("$full_query_name")
                    all_query_sqls+=("$escaped_sql")
                    
                    ((query_counter++))
                done < "$query_file"
            else
                # File-based mode: entire file is one query (default behavior)
                local full_query_name="${query_name}"
                
                # Read and escape SQL content
                local sql_content escaped_sql
                sql_content=$(cat "$query_file")
                escaped_sql=$(xml_escape "$sql_content")
                
                # Add to queries array: query_name and sql_content separately
                all_query_names+=("$full_query_name")
                all_query_sqls+=("$escaped_sql")
            fi
            
        done < <(find "$query_dir" -name "*.sql" -type f -print0 | sort -zV)
    fi

    if [ ${#all_query_names[@]} -eq 0 ]; then
        die "No SQL queries found for JMeter generation; check paths.query_dir"
    fi
    
    # Now generate JMX based on query_by_query setting
    if [ "$query_by_query" = "true" ]; then
        # Query-by-query mode: each query gets its own ThreadGroup (current behavior)
        for ((i=0; i<${#all_query_names[@]}; i++)); do
            local query_name="${all_query_names[i]}"
            local escaped_sql="${all_query_sqls[i]}"
            add_thread_group_and_sampler "$jmx_file" "$query_name" "$escaped_sql" "$threads" "$loops" "$duration" "$datasource_name"
        done
    else
        # Concurrent mode: single ThreadGroup with Random Controller
        if [ ${#all_query_names[@]} -gt 0 ]; then
            add_concurrent_thread_group_with_random_controller "$jmx_file" "$threads" "$loops" "$duration"
            
            # Add all queries as samplers under Random Controller
            for ((i=0; i<${#all_query_names[@]}; i++)); do
                local query_name="${all_query_names[i]}"
                local escaped_sql="${all_query_sqls[i]}"
                add_jdbc_sampler_to_random_controller "$jmx_file" "$query_name" "$escaped_sql" "$datasource_name"
            done
            
            close_concurrent_thread_group "$jmx_file"
        fi
    fi
    
    # Add global result collector
    cat >> "$jmx_file" << 'EOF'
      <ResultCollector guiclass="SimpleDataWriter" testclass="ResultCollector" testname="Simple Data Writer" enabled="true">
        <boolProp name="ResultCollector.error_logging">false</boolProp>
        <objProp>
          <name>saveConfig</name>
          <value class="SampleSaveConfiguration">
            <time>true</time>
            <latency>true</latency>
            <timestamp>true</timestamp>
            <success>true</success>
            <label>true</label>
            <code>true</code>
            <message>true</message>
            <threadName>true</threadName>
            <dataType>true</dataType>
            <encoding>false</encoding>
            <assertions>true</assertions>
            <subresults>true</subresults>
            <responseData>false</responseData>
            <samplerData>false</samplerData>
            <xml>false</xml>
            <fieldNames>true</fieldNames>
            <responseHeaders>false</responseHeaders>
            <requestHeaders>false</requestHeaders>
            <responseDataOnError>false</responseDataOnError>
            <saveAssertionResultsFailureMessage>true</saveAssertionResultsFailureMessage>
            <assertionsResultsToSave>0</assertionsResultsToSave>
            <bytes>true</bytes>
            <sentBytes>true</sentBytes>
            <url>true</url>
            <threadCounts>true</threadCounts>
            <idleTime>true</idleTime>
            <connectTime>true</connectTime>
          </value>
        </objProp>
        <stringProp name="filename">results.jtl</stringProp>
      </ResultCollector>
      <hashTree/>
    </hashTree>
  </hashTree>
</jmeterTestPlan>
EOF
    
    echo "JMX generation completed"
    
    # Create JMeter configuration JSON for reference
    cat > "$RESULT_DIR/jmeter_config.json" << EOF
{
  "threads": $threads,
  "query_by_query": $query_by_query,
  "loops": $loops,
  "duration": $duration
}
EOF
}
