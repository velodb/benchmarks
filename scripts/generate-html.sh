#!/bin/bash

# This script generates a standalone HTML benchmark report from result.json files.
# It reads all benchmark results and creates a single HTML file with embedded data,
# similar to ClickBench's approach. No Node.js or web server required.

set -e

# --- Configuration ---
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="$SCRIPT_DIR/.."
BENCHMARKS_DIR="$PROJECT_ROOT/benchmarks"
VERSIONS_RESULTS_DIR="$PROJECT_ROOT/versions/results"
OUTPUT_FILE="$PROJECT_ROOT/index.html"

# Default selected filters in the generated HTML.
# Empty benchmark arrays fall back to the first available benchmark on the page.
# Empty scale arrays fall back to all available scales on the page.
DEFAULT_MAIN_BENCHMARKS=(ssb ssb_flat tpcds tpch)
DEFAULT_VERSIONS_BENCHMARKS=(ssb ssb_flat tpcds tpch)
DEFAULT_MAIN_SCALES=(sf1000)
DEFAULT_VERSIONS_SCALES=(sf1000)

# --- Functions ---

js_array_from_values() {
    local first=true
    local value

    printf '['
    for value in "$@"; do
        if [ "$first" = true ]; then
            first=false
        else
            printf ', '
        fi
        jq -Rn --arg value "$value" '$value'
    done
    printf ']'
}

emit_default_selection_config() {
    local main_benchmarks_js
    local versions_benchmarks_js
    local main_scales_js
    local versions_scales_js

    main_benchmarks_js="$(js_array_from_values "${DEFAULT_MAIN_BENCHMARKS[@]}")"
    versions_benchmarks_js="$(js_array_from_values "${DEFAULT_VERSIONS_BENCHMARKS[@]}")"
    main_scales_js="$(js_array_from_values "${DEFAULT_MAIN_SCALES[@]}")"
    versions_scales_js="$(js_array_from_values "${DEFAULT_VERSIONS_SCALES[@]}")"

    cat <<EOF
// Configure default selected filters here.
const DEFAULT_SELECTED_BENCHMARKS = {
    main: $main_benchmarks_js,
    versions: $versions_benchmarks_js,
};

const DEFAULT_SELECTED_SCALES = {
    main: $main_scales_js,
    versions: $versions_scales_js,
};

EOF
}

parse_result_path() {
    local relative_path="$1"
    local -n benchmark_ref="$2"
    local -n scale_ref="$3"
    local -n database_ref="$4"
    local path_prefix
    local -a segments
    local segment_count
    local parsed_benchmark
    local parsed_scale
    local parsed_database

    if [[ "$relative_path" == */results/* ]]; then
        path_prefix="${relative_path%/results/*}"
    else
        path_prefix="${relative_path%/*}"
    fi

    IFS='/' read -r -a segments <<< "$path_prefix"
    segment_count="${#segments[@]}"

    parsed_benchmark="${segments[0]}"
    parsed_database="${segments[$((segment_count - 1))]}"

    if [ "$segment_count" -ge 3 ]; then
        parsed_scale="${segments[$((segment_count - 2))]}"
    else
        parsed_scale="default"
    fi

    benchmark_ref="$parsed_benchmark"
    scale_ref="$parsed_scale"
    database_ref="$parsed_database"
}

append_data_entries() {
    local dataset="$1"
    local base_dir="$2"
    local github_prefix="$3"
    local first_ref_name="$4"

    if [ ! -d "$base_dir" ]; then
        return
    fi

    while IFS= read -r -d '' filepath; do
        local relative_path
        local benchmark
        local scale
        local database
        local filename
        local hardware
        local id
        local github_url
        local system
        local version
        local create_time
        local machine
        local cluster_size
        local tags
        local load_times
        local data_size_bytes
        local query_times
        local jmeter_results

        relative_path="${filepath#$base_dir/}"
        parse_result_path "$relative_path" benchmark scale database

        filename=$(basename "$filepath")
        hardware="${filename%.json}"
        github_url="https://github.com/velodb/benchmarks/blob/master/$github_prefix/$relative_path"

        system=$(jq -r '.metadata.system // "Unknown"' "$filepath" | sed 's/\b\(.\)/\u\1/g')
        version=$(jq -r '.metadata.version // ""' "$filepath")
        create_time=$(jq -r '.metadata.create_time // ""' "$filepath")
        machine=$(jq -r '.metadata.machine // ""' "$filepath")
        cluster_size=$(jq -r '.metadata.cluster_size // 1' "$filepath")
        tags=$(jq -c '.metadata.tags // []' "$filepath")
        load_times=$(jq -c '.results.load.load_times // {}' "$filepath")
        data_size_bytes=$(jq -r '.results.load.data_size_bytes // null' "$filepath")
        query_times=$(jq -c '.results.query.query_times // {}' "$filepath")
        query_run_times=$(jq -c '.results.query.query_run_times // {}' "$filepath")
        jmeter_results=$(jq -c '.results.jmeter.test_results // []' "$filepath")

        if [ "$dataset" = "versions" ] && [ -n "$version" ] && [ "${hardware#"$version."}" != "$hardware" ]; then
            hardware="${hardware#"$version."}"
        fi

        id="$dataset-$benchmark-$scale-$database-${version:-unknown}-$hardware"

        if [ "${!first_ref_name}" = true ]; then
            printf -v "$first_ref_name" '%s' false
        else
            echo ","
        fi

        cat << EOF
{
    "id": "$id",
    "page": "$dataset",
    "benchmark": "$benchmark",
    "scale": "$scale",
    "database": "$database",
    "hardware": "$hardware",
    "github": "$github_url",
    "system": "$system",
    "version": "$version",
    "create_time": "$create_time",
    "machine": "$machine",
    "cluster_size": $cluster_size,
    "tags": $tags,
    "load_times": $load_times,
    "data_size_bytes": $data_size_bytes,
    "query_times": $query_times,
    "query_run_times": $query_run_times,
    "jmeter_results": $jmeter_results
}
EOF
    done < <(
        if [ "$dataset" = "main" ]; then
            find "$base_dir" -path "*/results/*.json" -print0
        else
            find "$base_dir" -name '*.json' -print0
        fi | sort -z
    )
}

# Convert result.json to JS data format
generate_data_js() {
    local first=true
    echo "const benchmarkData = ["

    append_data_entries "main" "$BENCHMARKS_DIR" "benchmarks" first
    append_data_entries "versions" "$VERSIONS_RESULTS_DIR" "versions/results" first

    echo "];"
}

# --- Main Logic ---

echo "Generating standalone HTML benchmark report..."

# Generate the HTML file
cat > "$OUTPUT_FILE" << 'HTMLHEAD'
<!DOCTYPE html>
<html data-theme="dark">
<head>
    <meta charset="UTF-8">
    <title>VeloDB Benchmarks - Database Performance Comparison</title>
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Inter&display=swap" rel="stylesheet">
    <style>
        :root {
            --color: black;
            --title-color: black;
            --background-color: white;
            --link-color: #08F;
            --link-hover-color: #F40;
            --hashed-link-lightness: 0.5;
            --selector-text-color: black;
            --selector-active-text-color: black;
            --selector-background-color: #EEE;
            --selector-active-background-color: #FFCB80;
            --selector-passive-background-color: #EEDDCC;
            --selector-hover-text-color: black;
            --selector-hover-background-color: #FDB;
            --summary-every-other-row-color: #F8F8F8;
            --highlight-color: #EEE;
            --bar-color1: oklch(calc(0.9 - 0.6) 0.1 calc(90 - 60));
            --bar-color2: oklch(calc(0.9 - 0.4) 0.1 calc(90 - 40));
            --bar-color3: oklch(calc(0.9 - 0.1) 0.1 calc(90 - 20));
            --bar-color4: oklch(0.9 0.1 90);
            --tooltip-text-color: white;
            --tooltip-background-color: black;
            --nothing-selected-color: #CCC;
            --shadow-color: grey;
            --disabled-color: #999;
            --disabled-background: #f0f0f0;
        }

        [data-theme="dark"] {
            --color: #CCC;
            --title-color: white;
            --background-color: #04293A;
            --link-color: #8CF;
            --link-hover-color: #FFF;
            --hashed-link-lightness: 0.82;
            --selector-text-color: white;
            --selector-background-color: #444;
            --selector-active-text-color: white;
            --selector-active-background-color: #088;
            --selector-passive-background-color: #566;
            --selector-hover-text-color: black;
            --selector-hover-background-color: white;
            --summary-every-other-row-color: #042e41;
            --highlight-color: #064663;
            --bar-color1: oklch(calc(0.4 + 0.6) 0.1 calc(250 - 180));
            --bar-color2: oklch(calc(0.4 + 0.4) 0.1 calc(250 - 120));
            --bar-color3: oklch(calc(0.4 + 0.2) 0.1 calc(250 - 60));
            --bar-color4: oklch(0.4 0.1 250);
            --tooltip-text-color: white;
            --tooltip-background-color: #444;
            --nothing-selected-color: #666;
            --shadow-color: black;
            --disabled-color: #666;
            --disabled-background: #333;
        }

        html, body {
            color: var(--color);
            background-color: var(--background-color);
            width: 100%;
            height: 100%;
            margin: 0;
            overflow: auto;
            box-sizing: border-box;
        }

        body {
            font-family: 'Inter', sans-serif;
            padding: 1% 3% 0 3%;
        }

        h1 {
            color: var(--title-color);
        }

        table {
            border-spacing: 1px;
        }

        .stick-left {
            position: sticky;
            left: 0px;
        }

        .selectors-container {
            padding: 2rem 0 2rem 0;
            user-select: none;
        }

        .selectors-container th {
            text-align: left;
            vertical-align: top;
            white-space: nowrap;
            padding-top: 0.5rem;
            padding-right: 1rem;
        }

        .selector {
            display: inline-block;
            margin-left: 0.1rem;
            padding: 0.2rem 0.5rem 0.2rem 0.5rem;
            background: var(--selector-background-color);
            color: var(--selector-text-color);
            border: 0.2rem solid var(--background-color);
            border-radius: 0.5rem;
            cursor: pointer;
        }

        .selector-active {
            color: var(--selector-active-text-color);
            background: var(--selector-active-background-color);
        }

        .selector-passive {
            color: var(--selector-active-text-color);
            background: var(--selector-passive-background-color);
        }

        .selector-disabled {
            color: var(--disabled-color) !important;
            background: var(--disabled-background) !important;
            cursor: not-allowed !important;
            opacity: 0.5;
        }

        a, a:visited {
            text-decoration: none;
            color: var(--link-color);
            cursor: pointer;
        }

        a:hover {
            color: var(--link-hover-color);
        }

        .selector:hover:not(.selector-disabled) {
            color: var(--selector-hover-text-color) !important;
            background: var(--selector-background-color);
        }

        .selector-active:hover:not(.selector-disabled), .selector-passive:hover:not(.selector-disabled) {
            background: var(--selector-hover-background-color);
        }

        #summary tr:nth-child(odd) {
            background: var(--summary-every-other-row-color);
        }

        #summary tr.summary-group-row:nth-child(odd) {
            background: transparent;
        }

        .summary-name {
            white-space: nowrap;
            text-align: right;
            padding-right: 1rem;
        }

        .summary-group-title {
            text-align: left;
            font-weight: bold;
            padding: 1.25rem 0 0.5rem 0;
        }

        .summary-bar-cell {
            width: 100%;
        }

        .summary-bar {
            height: 1rem;
            width: 100%;
        }

        .summary-number {
            font-family: monospace;
            text-align: right;
            padding-left: 1rem;
            white-space: nowrap;
        }

        th {
            padding-bottom: 0.5rem;
        }

        .th-entry-hilite {
            background: var(--highlight-color);
            font-weight: bold;
        }

        .summary-row:hover, .summary-row-hilite {
            background: var(--highlight-color) !important;
            font-weight: bold;
        }

        #details {
            padding-bottom: 1rem;
        }

        #details th {
            vertical-align: bottom;
            white-space: pre;
        }

        #details td {
            white-space: pre;
            font-family: monospace;
            text-align: right;
            padding: 0.1rem 0.5rem 0.1rem 0.5rem;
        }

        .shadow:hover {
            box-shadow: 0 0 1rem var(--shadow-color);
            position: relative;
        }

        #nothing-selected {
            display: none;
            font-size: 32pt;
            font-weight: bold;
            color: var(--nothing-selected-color);
        }

        .note {
            position: relative;
            display: inline-block;
        }

        .tooltip {
            position: absolute;
            bottom: calc(100% + 0.5rem);
            visibility: hidden;
            background-color: var(--tooltip-background-color);
            color: var(--tooltip-text-color);
            box-shadow: 0 0 1rem var(--shadow-color);
            padding: 0.5rem 0.75rem;
            border-radius: 0.5rem;
            z-index: 1;
            text-align: left;
            white-space: normal;
        }

        .tooltip-result {
            left: calc(50% - 0.25rem);
            width: 20rem;
            margin-left: -10rem;
        }

        .tooltip-query {
            left: 0;
            width: 40rem;
            margin-left: -3rem;
        }

        .note:hover .tooltip, .note:active .tooltip {
            visibility: visible;
        }

        .tooltip::after {
            content: " ";
            position: absolute;
            top: 100%;
            border-width: 0.5rem;
            border-style: solid;
            border-color: var(--tooltip-background-color) transparent transparent transparent;
        }

        .tooltip-result::after {
            left: 50%;
            margin-left: -1rem;
        }

        .tooltip-query::after {
            left: 3rem;
            margin-left: 0.5rem;
        }

        .nowrap {
            text-wrap: none;
        }

        #scale_hint {
            font-weight: normal;
            font-size: 80%;
            filter: contrast(10%);
        }

        .metric-separator {
            display: inline-block;
            margin: 0 0.5rem;
            color: var(--disabled-color);
        }

        .copy-notification {
            position: fixed;
            top: 20px;
            right: 20px;
            padding: 1rem 2rem;
            background: var(--selector-active-background-color);
            color: var(--selector-active-text-color);
            border-radius: 0.5rem;
            box-shadow: 0 0 1rem var(--shadow-color);
            z-index: 1000;
            display: none;
        }

        .comparison h2 {
            margin-top: 2rem;
        }
    </style>
</head>
<body>

<div id="copy-notification" class="copy-notification">Link copied to clipboard!</div>

<div class="header stick-left">
    <h1 id="page-title">VeloDB Benchmarks - Database Performance Comparison</h1>
    <a href="https://github.com/velodb/benchmarks">GitHub Repository</a> | 
    <a href="https://github.com/velodb/benchmarks#readme">Methodology</a> |
    <a id="main-benchmark-link" href="index.html">Main Benchmark</a> |
    <a id="versions-benchmark-link" href="index.html?page=versions">Versions Benchmark</a>
</div>

<table class="selectors-container stick-left">
    <tr>
        <th>Benchmark: </th>
        <td id="selectors_benchmark">
            <a id="select-all-benchmarks" class="selector selector-active">All</a>
        </td>
    </tr>
    <tr>
        <th>Scale: </th>
        <td id="selectors_scale">
            <a id="select-all-scales" class="selector selector-active">All</a>
        </td>
    </tr>
    <tr>
        <th>System: </th>
        <td id="selectors_system">
            <a id="select-all-systems" class="selector selector-active">All</a>
        </td>
    </tr>
    <tr>
        <th>Machine: </th>
        <td id="selectors_machine">
            <a id="select-all-machines" class="selector selector-active">All</a>
        </td>
    </tr>
    <tr id="version-selector-row">
        <th>Version: </th>
        <td id="selectors_version">
            <a id="select-all-versions" class="selector selector-active">All</a>
        </td>
    </tr>
    <tr>
        <th>Cluster: </th>
        <td id="selectors_cluster">
            <a id="select-all-clusters" class="selector selector-active">All</a>
        </td>
    </tr>
    <tr>
        <th>Concurrency: </th>
        <td id="selectors_thread">
        </td>
    </tr>
    <tr>
        <th>Metric: </th>
        <td id="selectors_metric">
            <a class="selector selector-active" id="selector-metric-hot">Hot Run</a>
            <a class="selector" id="selector-metric-cold">Cold Run</a>
            <a class="selector" id="selector-metric-combined">Combined</a>
            <a class="selector" id="selector-metric-load">Load Time</a>
            <a class="selector" id="selector-metric-size">Storage Size</a>
            <a class="selector" id="selector-metric-qps">QPS</a>
            <a class="selector" id="selector-metric-succ-qps">Successful QPS</a>
            <a class="selector" id="selector-metric-avg">Avg Latency</a>
            <a class="selector" id="selector-metric-p99">P99 Latency</a>
            <a class="selector" id="selector-metric-error">Error %</a>
        </td>
    </tr>
</table>

<div id="summary-title" class="stick-left comparison">
    <h2>Summary Comparison</h2>
</div>

<table id="summary-comparison" class="stick-left comparison">
    <thead>
        <tr>
            <th class="summary-name">
                System / Machine / Version
            </th>
            <th colspan="2">
                Relative <span id="time-or-size">time</span> (<span id="better-direction">lower is better</span>).<br/>
                <span id="scale_hint"></span>
            </th>
        </tr>
    </thead>
    <tbody id="summary">
    </tbody>
</table>

<div id="nothing-selected" class="stick-left">Nothing selected</div>

<div id="details-title" class="stick-left comparison">
    <h2>Detailed Comparison</h2>
</div>

<table id="details">
    <thead>
        <tr id="details_head">
        </tr>
    </thead>
    <tbody id="details_body">
    </tbody>
</table>

<script type="text/javascript">
HTMLHEAD

# Generate and embed the data
echo "Collecting benchmark data..."
generate_data_js >> "$OUTPUT_FILE"
emit_default_selection_config >> "$OUTPUT_FILE"

# Add the JavaScript logic
cat >> "$OUTPUT_FILE" << 'HTMLJS'

// Constants for calculation
const constant_time_add = 0.01;
const missing_result_penalty = 2;
const missing_result_time = 300;
const combined_load_time_share = 0.1;
const combined_data_size_share = 0.1;
const combined_cold_share = 0.2;
const combined_hot_share = 0.6;

// State management
let selectors = {
    "benchmark": {},
    "scale": {},
    "system": {},
    "machine": {},
    "version": {},
    "cluster": {},
    "thread": 1,
    "metric": "hot",
    "queries": [],
    "jmeterQueries": {},  // For JMeter mode query selection
};

// Available thread counts (extracted from JMeter data)
let availableThreads = [1];

const theme = 'dark';

function detectPageMode(pathname, search) {
    const params = new URLSearchParams(search);
    const pageParam = params.get('page');
    if (pageParam === 'versions') {
        return 'versions';
    }
    return 'main';
}

const pageMode = detectPageMode(window.location.pathname, window.location.search);

// URL parameter management
function getUrlParams() {
    const params = new URLSearchParams(window.location.search);
    return {
        benchmark: params.get('benchmark'),
        scale: params.get('scale'),
        system: params.get('system'),
        machine: params.get('machine'),
        version: params.get('version'),
        cluster: params.get('cluster'),
        thread: params.get('thread'),
        metric: params.get('metric'),
    };
}

function updateUrlParams() {
    const params = new URLSearchParams();

    if (pageMode === 'versions') {
        params.set('page', 'versions');
    }
    
    // Only add non-default values to URL
    const selectedBenchmarks = getSelectedValues(selectors.benchmark);
    const allBenchmarks = Object.keys(selectors.benchmark);
    if (selectedBenchmarks.length !== allBenchmarks.length && selectedBenchmarks.length > 0) {
        params.set('benchmark', selectedBenchmarks.join(','));
    }
    
    const selectedScales = Object.keys(selectors.scale).filter(k => selectors.scale[k]);
    const allScales = Object.keys(selectors.scale);
    if (selectedScales.length !== allScales.length && selectedScales.length > 0) {
        params.set('scale', selectedScales.join(','));
    }
    
    const selectedSystems = Object.keys(selectors.system).filter(k => selectors.system[k]);
    const allSystems = Object.keys(selectors.system);
    if (selectedSystems.length !== allSystems.length && selectedSystems.length > 0) {
        params.set('system', selectedSystems.join(','));
    }
    
    const selectedMachines = Object.keys(selectors.machine).filter(k => selectors.machine[k]);
    const allMachines = Object.keys(selectors.machine);
    if (selectedMachines.length !== allMachines.length && selectedMachines.length > 0) {
        params.set('machine', selectedMachines.join(','));
    }

    const selectedVersions = Object.keys(selectors.version).filter(k => selectors.version[k]);
    const allVersions = Object.keys(selectors.version);
    if (selectedVersions.length !== allVersions.length && selectedVersions.length > 0) {
        params.set('version', selectedVersions.join(','));
    }
    
    const selectedClusters = Object.keys(selectors.cluster).filter(k => selectors.cluster[k]);
    const allClusters = Object.keys(selectors.cluster);
    if (selectedClusters.length !== allClusters.length && selectedClusters.length > 0) {
        params.set('cluster', selectedClusters.join(','));
    }
    
    if (selectors.thread !== 1) {
        params.set('thread', selectors.thread);
    }
    
    if (selectors.metric !== 'hot') {
        params.set('metric', selectors.metric);
    }
    
    const newUrl = params.toString() 
        ? `${window.location.pathname}?${params.toString()}`
        : window.location.pathname;
    
    window.history.replaceState({}, '', newUrl);
}

function applyUrlParams(urlParams) {
    if (urlParams.benchmark) {
        setSelectionFromList(selectors.benchmark, urlParams.benchmark.split(','));
    }
    
    if (urlParams.scale) {
        const selected = urlParams.scale.split(',');
        Object.keys(selectors.scale).forEach(k => {
            selectors.scale[k] = selected.includes(k);
        });
    }
    
    if (urlParams.system) {
        const selected = urlParams.system.split(',');
        Object.keys(selectors.system).forEach(k => {
            selectors.system[k] = selected.includes(k);
        });
    }
    
    if (urlParams.machine) {
        const selected = urlParams.machine.split(',');
        Object.keys(selectors.machine).forEach(k => {
            selectors.machine[k] = selected.includes(k);
        });
    }

    if (urlParams.version) {
        const selected = urlParams.version.split(',');
        Object.keys(selectors.version).forEach(k => {
            selectors.version[k] = selected.includes(k);
        });
    }
    
    if (urlParams.cluster) {
        const selected = urlParams.cluster.split(',');
        Object.keys(selectors.cluster).forEach(k => {
            selectors.cluster[k] = selected.includes(k);
        });
    }
    
    if (urlParams.thread) {
        selectors.thread = parseInt(urlParams.thread) || 1;
    }
    
    if (urlParams.metric) {
        selectors.metric = urlParams.metric;
    }
    
}

// Helper functions
function clearElement(elem) {
    while (elem.firstChild) {
        elem.removeChild(elem.lastChild);
    }
}

function getSelectedValues(selectors_map) {
    return Object.keys(selectors_map).filter(key => selectors_map[key]);
}

function setSelectionFromList(selectors_map, selected_values) {
    const selectedSet = new Set(selected_values);
    Object.keys(selectors_map).forEach(key => {
        selectors_map[key] = selectedSet.has(key);
    });
}

function getDefaultSelectedBenchmarks(benchmarks) {
    const configured = DEFAULT_SELECTED_BENCHMARKS[pageMode] || [];
    const validConfigured = configured.filter(benchmark => benchmarks.includes(benchmark));
    if (validConfigured.length > 0) {
        return validConfigured;
    }
    return benchmarks.length > 0 ? [benchmarks[0]] : [];
}

function getDefaultSelectedScales(scales) {
    const configured = DEFAULT_SELECTED_SCALES[pageMode] || [];
    const validConfigured = configured.filter(scale => scales.includes(scale));
    if (validConfigured.length > 0) {
        return validConfigured;
    }
    return scales;
}

function getBenchmarkScaleGroups(entries) {
    const groups = new Map();

    entries.forEach(entry => {
        const key = `${entry.benchmark}::${entry.scale}`;
        if (!groups.has(key)) {
            groups.set(key, {
                key,
                benchmark: entry.benchmark,
                scale: entry.scale,
                entries: [],
            });
        }
        groups.get(key).entries.push(entry);
    });

    return [...groups.values()].sort((left, right) => {
        const benchmarkComparison = naturalSort(left.benchmark, right.benchmark);
        if (benchmarkComparison !== 0) {
            return benchmarkComparison;
        }
        return naturalSort(left.scale, right.scale);
    });
}

function getBenchmarkScaleGroupLabel(group) {
    return `${group.benchmark} / ${group.scale}`;
}

function appendSummaryGroupHeader(table, group) {
    const row = document.createElement('tr');
    row.className = 'summary-group-row';

    const cell = document.createElement('td');
    cell.colSpan = 3;
    cell.className = 'summary-group-title';
    cell.appendChild(document.createTextNode(getBenchmarkScaleGroupLabel(group)));

    row.appendChild(cell);
    table.appendChild(row);
}

function setDetailedComparisonVisible(visible) {
    document.getElementById('details-title').style.display = visible ? 'block' : 'none';
    document.getElementById('details').style.display = visible ? 'table' : 'none';
}

function updateSelectorGroupUI(containerId, selectors_map, allSelectorId) {
    [...document.getElementById(containerId).querySelectorAll('a')].forEach(elem => {
        if (allSelectorId && elem.id === allSelectorId) {
            elem.className = getSelectedValues(selectors_map).length === Object.keys(selectors_map).length
                ? 'selector selector-active'
                : 'selector';
            return;
        }

        const key = elem.textContent;
        elem.className = selectors_map[key] ? 'selector selector-active' : 'selector';
    });
}

function toggle(e, elem, selectors_map) {
    selectors_map[elem] = !selectors_map[elem];
    updateSelectorsUI();
    updateUrlParams();
    render();
}

function toggleAll(e, selectors_map) {
    const new_value = Object.keys(selectors_map).filter(k => selectors_map[k]).length * 2 < Object.keys(selectors_map).length;
    Object.keys(selectors_map).map(k => { selectors_map[k] = new_value });
    updateSelectorsUI();
    updateUrlParams();
    render();
}

// Convert query_times object to result array format (for ClickBench compatibility)
function convertQueryTimesToResult(query_times) {
    if (!query_times || Object.keys(query_times).length === 0) {
        return [];
    }
    
    // Sort query keys numerically (q1, q2, q3, ... q10, q11, ...)
    const sortedKeys = Object.keys(query_times).sort((a, b) => {
        return a.localeCompare(b, undefined, { numeric: true });
    });
    
    return sortedKeys.map(key => query_times[key]);
}

// Get total load time from load_times object
function getTotalLoadTime(load_times) {
    if (!load_times || Object.keys(load_times).length === 0) {
        return null;
    }
    return Object.values(load_times).reduce((sum, time) => sum + (time || 0), 0);
}

function naturalSort(a, b) {
    return String(a).localeCompare(String(b), undefined, { numeric: true, sensitivity: 'base' });
}

function getDisplayVersion(entry) {
    return entry.version || 'Unknown';
}

function getMachineLabel(entry) {
    return `${entry.cluster_size > 1 ? entry.cluster_size + '×' : ''}${entry.machine || 'Unknown machine'}`;
}

function getDisplayName(entry, multiline = false) {
    if (multiline) {
        return `${entry.system}\n(${getMachineLabel(entry)})\n${getDisplayVersion(entry)}`;
    }
    return `${entry.system} (${getMachineLabel(entry)}, ${getDisplayVersion(entry)})`;
}

// Prepare data for rendering
function prepareData() {
    return benchmarkData.map(entry => {
        const result = convertQueryTimesToResult(entry.query_times);
        const load_time = getTotalLoadTime(entry.load_times);
        
        return {
            ...entry,
            result: result,
            load_time: load_time,
            data_size: entry.data_size_bytes,
        };
    });
}

const processedData = prepareData();

function getActiveData() {
    return processedData.filter(entry => entry.page === pageMode);
}

function configurePage() {
    const isVersionsPage = pageMode === 'versions';
    document.getElementById('page-title').textContent = isVersionsPage
        ? 'VeloDB Versions Benchmark'
        : 'VeloDB Benchmarks - Database Performance Comparison';
    document.getElementById('version-selector-row').style.display = isVersionsPage ? '' : 'none';
    document.getElementById('main-benchmark-link').className = isVersionsPage ? '' : 'selector-active';
    document.getElementById('versions-benchmark-link').className = isVersionsPage ? 'selector-active' : '';
}

// Extract available thread counts from JMeter data
function extractAvailableThreads(entries) {
    const threads = new Set([1]); // Always include 1 for single-thread
    entries.forEach(entry => {
        if (entry.jmeter_results && entry.jmeter_results.length > 0) {
            entry.jmeter_results.forEach(r => {
                if (r.config && r.config.threads && r.config.threads > 1) {
                    threads.add(r.config.threads);
                }
            });
        }
    });
    return [...threads].sort((a, b) => a - b);
}

// Initialize selectors from data
function initSelectors() {
    configurePage();

    const benchmarkContainer = document.getElementById('selectors_benchmark');
    const scaleContainer = document.getElementById('selectors_scale');
    const systemContainer = document.getElementById('selectors_system');
    const machineContainer = document.getElementById('selectors_machine');
    const versionContainer = document.getElementById('selectors_version');
    const clusterContainer = document.getElementById('selectors_cluster');
    const threadContainer = document.getElementById('selectors_thread');
    const activeData = getActiveData();

    if (activeData.length === 0) {
        return;
    }
    
    // Get unique values
    const benchmarks = [...new Set(activeData.map(e => e.benchmark))].sort(naturalSort);
    const scales = [...new Set(activeData.map(e => e.scale))].sort(naturalSort);
    const systems = [...new Set(activeData.map(e => e.system))].sort(naturalSort);
    const machines = [...new Set(activeData.map(e => e.machine))].filter(m => m).sort(naturalSort);
    const versions = [...new Set(activeData.map(e => getDisplayVersion(e)))].sort(naturalSort);
    const clusters = [...new Set(activeData.map(e => String(e.cluster_size)))].sort((a, b) => Number(a) - Number(b));
    
    // Extract available threads
    availableThreads = extractAvailableThreads(activeData);
    
    const defaultBenchmarks = new Set(getDefaultSelectedBenchmarks(benchmarks));
    const defaultScales = new Set(getDefaultSelectedScales(scales));

    // Create benchmark selectors
    benchmarks.forEach(elem => {
        let selector = document.createElement('a');
        const isSelected = defaultBenchmarks.has(elem);
        selectors.benchmark[elem] = isSelected;
        selector.className = isSelected ? 'selector selector-active' : 'selector';
        selector.appendChild(document.createTextNode(elem));
        benchmarkContainer.appendChild(selector);
        selector.addEventListener('click', e => toggle(e, elem, selectors.benchmark));
    });
    
    // Create scale selectors
    scales.forEach(elem => {
        let selector = document.createElement('a');
        const isSelected = defaultScales.has(elem);
        selector.className = isSelected ? 'selector selector-active' : 'selector';
        selector.appendChild(document.createTextNode(elem));
        scaleContainer.appendChild(selector);
        selectors.scale[elem] = isSelected;
        selector.addEventListener('click', e => toggle(e, elem, selectors.scale));
    });
    
    // Create system selectors
    systems.forEach(elem => {
        let selector = document.createElement('a');
        selector.className = 'selector selector-active';
        selector.appendChild(document.createTextNode(elem));
        systemContainer.appendChild(selector);
        selectors.system[elem] = true;
        selector.addEventListener('click', e => toggle(e, elem, selectors.system));
    });
    
    // Create machine selectors
    machines.forEach(elem => {
        let selector = document.createElement('a');
        selector.className = 'selector selector-active';
        selector.appendChild(document.createTextNode(elem));
        machineContainer.appendChild(selector);
        selectors.machine[elem] = true;
        selector.addEventListener('click', e => toggle(e, elem, selectors.machine));
    });

    // Create version selectors
    versions.forEach(elem => {
        let selector = document.createElement('a');
        selector.className = 'selector selector-active';
        selector.appendChild(document.createTextNode(elem));
        versionContainer.appendChild(selector);
        selectors.version[elem] = true;
        selector.addEventListener('click', e => toggle(e, elem, selectors.version));
    });
    
    // Create cluster selectors
    clusters.forEach(elem => {
        let selector = document.createElement('a');
        selector.className = 'selector selector-active';
        selector.appendChild(document.createTextNode(elem));
        clusterContainer.appendChild(selector);
        selectors.cluster[elem] = true;
        selector.addEventListener('click', e => toggle(e, elem, selectors.cluster));
    });
    
    // Create thread selectors
    availableThreads.forEach(threadCount => {
        let selector = document.createElement('a');
        selector.className = threadCount === 1 ? 'selector selector-active' : 'selector';
        selector.dataset.thread = threadCount;
        selector.appendChild(document.createTextNode(threadCount));
        threadContainer.appendChild(selector);
        selector.addEventListener('click', e => {
            selectors.thread = threadCount;
            updateThreadSelector();
            updateMetricGroupsState();
            updateUrlParams();
            render();
        });
    });
    
    // Toggle all buttons
    document.getElementById('select-all-benchmarks').addEventListener('click', e => toggleAll(e, selectors.benchmark));
    document.getElementById('select-all-scales').addEventListener('click', e => toggleAll(e, selectors.scale));
    document.getElementById('select-all-systems').addEventListener('click', e => toggleAll(e, selectors.system));
    document.getElementById('select-all-machines').addEventListener('click', e => toggleAll(e, selectors.machine));
    document.getElementById('select-all-versions').addEventListener('click', e => toggleAll(e, selectors.version));
    document.getElementById('select-all-clusters').addEventListener('click', e => toggleAll(e, selectors.cluster));
    
    // Metric selectors - Single thread
    document.getElementById('selector-metric-combined').addEventListener('click', e => {
        if (selectors.thread === 1) {
            updateMetricSelector('combined');
            updateUrlParams();
            render();
        }
    });
    document.getElementById('selector-metric-cold').addEventListener('click', e => {
        if (selectors.thread === 1) {
            updateMetricSelector('cold');
            updateUrlParams();
            render();
        }
    });
    document.getElementById('selector-metric-hot').addEventListener('click', e => {
        if (selectors.thread === 1) {
            updateMetricSelector('hot');
            updateUrlParams();
            render();
        }
    });
    document.getElementById('selector-metric-load').addEventListener('click', e => {
        if (selectors.thread === 1) {
            updateMetricSelector('load');
            updateUrlParams();
            render();
        }
    });
    document.getElementById('selector-metric-size').addEventListener('click', e => {
        if (selectors.thread === 1) {
            updateMetricSelector('size');
            updateUrlParams();
            render();
        }
    });
    
    // Metric selectors - Multi thread (JMeter)
    document.getElementById('selector-metric-qps').addEventListener('click', e => {
        if (selectors.thread > 1) {
            updateMetricSelector('qps');
            updateUrlParams();
            render();
        }
    });
    document.getElementById('selector-metric-succ-qps').addEventListener('click', e => {
        if (selectors.thread > 1) {
            updateMetricSelector('succ-qps');
            updateUrlParams();
            render();
        }
    });
    document.getElementById('selector-metric-avg').addEventListener('click', e => {
        if (selectors.thread > 1) {
            updateMetricSelector('avg');
            updateUrlParams();
            render();
        }
    });
    document.getElementById('selector-metric-p99').addEventListener('click', e => {
        if (selectors.thread > 1) {
            updateMetricSelector('p99');
            updateUrlParams();
            render();
        }
    });
    document.getElementById('selector-metric-error').addEventListener('click', e => {
        if (selectors.thread > 1) {
            updateMetricSelector('error');
            updateUrlParams();
            render();
        }
    });
    
    // Apply URL parameters
    const urlParams = getUrlParams();
    applyUrlParams(urlParams);

    if (getSelectedValues(selectors.benchmark).length === 0) {
        setSelectionFromList(selectors.benchmark, getDefaultSelectedBenchmarks(benchmarks));
    }

    if (getSelectedValues(selectors.scale).length === 0) {
        setSelectionFromList(selectors.scale, getDefaultSelectedScales(scales));
    }
    
    // Update UI to reflect applied parameters
    updateSelectorsUI();
    updateThreadSelector();
    updateMetricGroupsState();
}

function updateSelectorsUI() {
    updateBenchmarkSelector();
    updateSelectorGroupUI('selectors_scale', selectors.scale, 'select-all-scales');
    updateSelectorGroupUI('selectors_system', selectors.system, 'select-all-systems');
    updateSelectorGroupUI('selectors_machine', selectors.machine, 'select-all-machines');
    updateSelectorGroupUI('selectors_version', selectors.version, 'select-all-versions');
    updateSelectorGroupUI('selectors_cluster', selectors.cluster, 'select-all-clusters');
}

function updateBenchmarkSelector() {
    updateSelectorGroupUI('selectors_benchmark', selectors.benchmark, 'select-all-benchmarks');
}

function updateThreadSelector() {
    [...document.getElementById('selectors_thread').querySelectorAll('a')].forEach(elem => {
        elem.className = parseInt(elem.dataset.thread) === selectors.thread ? 'selector selector-active' : 'selector';
    });
}

function updateMetricGroupsState() {
    if (selectors.thread === 1) {
        // Single thread mode - ensure metric is a single-thread metric
        if (['qps', 'succ-qps', 'avg', 'p99'].includes(selectors.metric)) {
            selectors.metric = 'hot';
        }
    } else {
        // Multi thread mode - ensure metric is a multi-thread metric
        if (['hot', 'cold', 'combined', 'load', 'size'].includes(selectors.metric)) {
            selectors.metric = 'qps';
        }
    }
    
    updateMetricSelectorUI();
}

function updateMetricSelector(metric) {
    selectors.metric = metric;
    updateMetricSelectorUI();
}

function updateMetricSelectorUI() {
    // Single thread metrics
    const singleMetrics = ['hot', 'cold', 'combined', 'load', 'size'];
    singleMetrics.forEach(m => {
        const elem = document.getElementById('selector-metric-' + m);
        if (elem) {
            if (selectors.thread === 1) {
                elem.className = selectors.metric === m ? 'selector selector-active' : 'selector';
            } else {
                elem.className = 'selector selector-disabled';
            }
        }
    });
    
    // Multi thread metrics
    const multiMetrics = ['qps', 'succ-qps', 'avg', 'p99', 'error'];
    multiMetrics.forEach(m => {
        const elem = document.getElementById('selector-metric-' + m);
        if (elem) {
            if (selectors.thread > 1) {
                elem.className = selectors.metric === m ? 'selector selector-active' : 'selector';
            } else {
                elem.className = 'selector selector-disabled';
            }
        }
    });
}

// Select run based on metric
function selectRun(timings, metric) {
    if (!timings || timings.length === 0) return null;
    
    const cold_timing = timings[0];
    const hot_timing = (timings.length >= 3 && timings[1] !== null && timings[2] !== null) 
        ? Math.min(timings[1], timings[2]) 
        : (timings.length >= 2 ? timings[1] : null);
    
    if (metric === 'cold') return cold_timing;
    if (metric === 'hot') return hot_timing;
    
    // Combined
    if (hot_timing !== null && cold_timing !== null) {
        return (hot_timing * combined_hot_share + cold_timing * combined_cold_share) / (combined_hot_share + combined_cold_share);
    }
    return null;
}

// Calculate relative query time
function relativeQueryTime(num_queries, baseline_data, elem, metric) {
    const fallback_timing = missing_result_penalty * Math.max(missing_result_time, 
        ...elem.result.map(timings => selectRun(timings, metric) || 0));
    
    let accumulator = 0;
    let used_queries = 0;
    const no_queries_selected = selectors.queries.filter(x => x).length === 0;
    
    for (let i = 0; i < num_queries; ++i) {
        if (no_queries_selected || selectors.queries[i]) {
            const curr_timing = selectRun(elem.result[i], metric) ?? fallback_timing;
            const baseline_timing = selectRun(baseline_data[i], metric);
            if (baseline_timing) {
                const ratio = (constant_time_add + curr_timing) / (constant_time_add + baseline_timing);
                accumulator += Math.log(ratio);
                ++used_queries;
            }
        }
    }
    
    return used_queries > 0 ? Math.exp(accumulator / used_queries) : 1;
}

function getSelectedQueryTotalTime(elem, metric, num_queries) {
    const no_queries_selected = selectors.queries.filter(x => x).length === 0;
    let totalTime = 0;

    for (let i = 0; i < num_queries; ++i) {
        if (no_queries_selected || selectors.queries[i]) {
            const timing = selectRun(elem.result[i], metric);
            if (timing !== null) {
                totalTime += timing;
            }
        }
    }

    return totalTime;
}

// Colorize cell based on ratio
function colorize(elem, ratio) {
    let [r, g, b] = [0, 0, 0];
    
    if (ratio !== null) {
        if (ratio < 1) {
            r = 232; g = 255; b = 232;
        } else if (ratio <= 1) {
            g = 255;
        } else if (ratio <= 2) {
            g = 255;
            r = (ratio - 1) * 255;
        } else if (ratio <= 10) {
            g = (10 - ratio) / 8 * 255;
            r = 255;
        } else {
            r = (1 - ((ratio - 10) / ((ratio - 10) + 1000))) * 255;
        }
    }
    
    if (theme === 'dark') {
        r /= 1.5; g /= 1.5; b /= 1.5;
    }
    
    elem.style.backgroundColor = `rgb(${r}, ${g}, ${b})`;
    elem.style.color = (ratio === null || ratio > 10) ? 'white' : 'black';
    if (ratio === 1) elem.style.fontWeight = 'bold';
}

// Name to color helper
function nameToColor(str) {
    let x = 0;
    for (let i = 0; i < str.length; i++) {
        x += str.charCodeAt(i);
        x *= 0xff51afd7;
        x ^= x >> 17;
    }
    return 60 + Math.abs(x % 240);
}

// Normalize JMeter result to handle different field naming conventions
function normalizeJmeterResult(result) {
    if (!result) return null;
    return {
        // Support both naming conventions: throughput/qps
        throughput: result.throughput ?? result.qps ?? null,
        // Support both: meanResTime (ms) / avg (s) - normalize to ms
        meanResTime: result.meanResTime ?? (result.avg ? result.avg * 1000 : null),
        // Support both: pct3ResTime (ms) / 99th (s) - normalize to ms
        pct3ResTime: result.pct3ResTime ?? (result['99th'] ? result['99th'] * 1000 : null),
        // Error percentage
        errorPct: result.errorPct ?? (result.error !== undefined && result.sample ? (result.error / result.sample * 100) : null),
        // Other fields
        minResTime: result.minResTime ?? (result.min ? result.min * 1000 : null),
        maxResTime: result.maxResTime ?? (result.max ? result.max * 1000 : null),
        sampleCount: result.sampleCount ?? result.sample ?? null,
        errorCount: result.errorCount ?? result.error ?? null,
    };
}

// Get JMeter result for a specific thread count
function getJmeterResult(entry, threadCount) {
    if (!entry.jmeter_results || entry.jmeter_results.length === 0) return null;
    
    for (const result of entry.jmeter_results) {
        if (result.config && result.config.threads === threadCount && result.total) {
            return normalizeJmeterResult(result.total);
        }
    }
    return null;
}

// Render summary for single thread mode
function renderSummarySingleThread(filtered_data, options = {}) {
    let table = options.table || document.getElementById('summary');
    if (!options.append) {
        clearElement(table);
    }
    
    if (filtered_data.length === 0) return [[], []];
    
    const num_queries = Math.max(...filtered_data.map(e => e.result.length));
    if (num_queries === 0 && selectors.metric !== 'load' && selectors.metric !== 'size') {
        return [[], []];
    }
    
    // Calculate baseline
    const baseline_data = [...Array(num_queries).keys()].map(query_num =>
        [0, 1, 2].map(run_num =>
            Math.min(...filtered_data.map(elem => 
                elem.result[query_num] && elem.result[query_num][run_num]
            ).filter(x => x != null && x > 0))));
    
    const min_load_time = Math.min(...filtered_data.map(e => e.load_time).filter(x => x && x > 5));
    const min_data_size = Math.min(...filtered_data.map(e => e.data_size).filter(x => x && x > 1e9));
    
    // Calculate summaries
    let summaries;
    if (selectors.metric === 'load') {
        summaries = filtered_data.map(e => e.load_time / min_load_time);
        document.getElementById('time-or-size').innerText = 'time';
    } else if (selectors.metric === 'size') {
        summaries = filtered_data.map(e => e.data_size / min_data_size);
        document.getElementById('time-or-size').innerText = 'size';
    } else if (selectors.metric === 'hot' || selectors.metric === 'cold') {
        const totalTimes = filtered_data.map(e => getSelectedQueryTotalTime(e, selectors.metric, num_queries));
        const minTotalTime = Math.min(...totalTimes.filter(x => x > 0));
        summaries = totalTimes.map(v => v > 0 ? v / minTotalTime : Infinity);
        document.getElementById('time-or-size').innerText = 'time';
    } else {
        const rawCombinedSummaries = filtered_data.map(e => Math.exp(
            combined_load_time_share * Math.log(e.load_time >= 5 ? (e.load_time / min_load_time) : 1) +
            combined_data_size_share * Math.log(e.data_size >= 1e9 ? (e.data_size / min_data_size) : 2) +
            combined_cold_share * Math.log(relativeQueryTime(num_queries, baseline_data, e, 'cold')) +
            combined_hot_share * Math.log(relativeQueryTime(num_queries, baseline_data, e, 'hot'))));
        const minCombinedScore = Math.min(...rawCombinedSummaries.filter(x => x > 0));
        summaries = rawCombinedSummaries.map(v => v > 0 ? v / minCombinedScore : Infinity);
        document.getElementById('time-or-size').innerText = 'time and data size';
    }
    
    const sorted_indices = [...summaries.keys()].sort((a, b) => summaries[a] - summaries[b]);
    const max_ratio = 10000;
    
    sorted_indices.forEach(idx => {
        const elem = filtered_data[idx];
        
        if (selectors.metric === 'size' && !elem.data_size) return;
        if (selectors.metric === 'load' && (!elem.load_time || elem.load_time < 5)) return;
        
        let tr = document.createElement('tr');
        tr.className = 'summary-row';
        tr.dataset.system = elem.system;
        
        let td_name = document.createElement('td');
        td_name.className = 'summary-name';
        
        let link = document.createElement('a');
        const displayName = getDisplayName(elem);
        link.appendChild(document.createTextNode(displayName));
        link.href = elem.github;
        link.style.color = `oklch(var(--hashed-link-lightness) 0.2018 ${nameToColor(elem.system.split(' ')[0])})`;
        td_name.appendChild(link);
        td_name.appendChild(document.createTextNode(': '));
        
        const ratio = summaries[idx];
        const percentage = ratio / max_ratio * 100;
        
        let td_number = document.createElement('td');
        td_number.className = 'summary-number';
        
        let text;
        if (selectors.metric === 'load') {
            text = elem.load_time ? `${Math.round(elem.load_time)}s (×${ratio.toFixed(2)})` : 'N/A';
        } else if (selectors.metric === 'size') {
            text = `${(elem.data_size / 1024 / 1024 / 1024).toFixed(2)} GiB (×${ratio.toFixed(2)})`;
        } else if (selectors.metric === 'combined') {
            // Combined is a composite score with no physical unit, only show relative ratio
            text = `×${ratio.toFixed(2)}`;
        } else {
            // Calculate total time for hot, cold metrics
            const totalTime = getSelectedQueryTotalTime(elem, selectors.metric, num_queries);
            text = `${totalTime.toFixed(2)}s (×${ratio.toFixed(2)})`;
        }
        
        td_number.appendChild(document.createTextNode(text));
        
        let td_bar = document.createElement('td');
        td_bar.className = 'summary-bar-cell';
        
        let bar = document.createElement('div');
        bar.className = 'summary-bar';
        bar.style.background = `linear-gradient(to right,
            var(--bar-color1) 0%,
            var(--bar-color1) ${Math.min(100, percentage)}%,
            var(--bar-color2) ${Math.min(100, percentage)}%,
            var(--bar-color2) ${Math.min(100, percentage * 10)}%,
            var(--bar-color3) ${Math.min(100, percentage * 10)}%,
            var(--bar-color3) ${Math.min(100, percentage * 100)}%,
            var(--bar-color4) ${Math.min(100, percentage * 100)}%,
            var(--bar-color4) ${Math.min(100, percentage * 1000)}%,
            transparent ${Math.min(100, percentage * 1000)}%,
            transparent 100%)`;
        
        td_bar.appendChild(bar);
        
        tr.appendChild(td_name);
        tr.appendChild(td_bar);
        tr.appendChild(td_number);
        table.appendChild(tr);
    });
    
    return [sorted_indices, baseline_data];
}


// Render summary for multi-thread (JMeter) mode
function renderSummaryMultiThread(filtered_data, options = {}) {
    let table = options.table || document.getElementById('summary');
    if (!options.append) {
        clearElement(table);
    }
    
    // Filter entries that have JMeter results for the selected thread count
    const jmeterData = filtered_data.filter(e => getJmeterResult(e, selectors.thread) !== null);
    
    if (jmeterData.length === 0) return [[], []];
    
    // Calculate metric values - always use original total result regardless of query selection
    const metricValues = jmeterData.map(e => {
        // Always use original total result
        const result = getJmeterResult(e, selectors.thread);
        if (!result) return null;
        
        switch (selectors.metric) {
            case 'qps':
                return result.throughput;
            case 'succ-qps':
                return result.throughput ? result.throughput * (1 - (result.errorPct ?? 0) / 100) : null;
            case 'avg':
                return result.meanResTime ? result.meanResTime / 1000 : null; // Convert to seconds
            case 'p99':
                return result.pct3ResTime ? result.pct3ResTime / 1000 : null; // Convert to seconds
            case 'error':
                return result.errorPct;
            default:
                return result.throughput;
        }
    });
    
    // For QPS, higher is better; for latency and error, lower is better
    const isHigherBetter = selectors.metric === 'qps' || selectors.metric === 'succ-qps';
    
    let summaries;
    if (isHigherBetter) {
        const maxValue = Math.max(...metricValues.filter(x => x != null && x > 0));
        summaries = metricValues.map(v => v ? maxValue / v : Infinity);
        document.getElementById('time-or-size').innerText = 'QPS';
    } else if (selectors.metric === 'error') {
        // For error rate, 0 is best, so we use a different approach
        const minValue = Math.min(...metricValues.filter(x => x != null && x >= 0));
        summaries = metricValues.map(v => v != null ? (minValue === 0 ? (v === 0 ? 1 : v + 1) : v / minValue) : Infinity);
        document.getElementById('time-or-size').innerText = 'error rate';
    } else {
        const minValue = Math.min(...metricValues.filter(x => x != null && x > 0));
        summaries = metricValues.map(v => v ? v / minValue : Infinity);
        document.getElementById('time-or-size').innerText = 'latency';
    }
    
    const sorted_indices = [...summaries.keys()].sort((a, b) => summaries[a] - summaries[b]);
    const max_ratio = 10000;
    
    sorted_indices.forEach(idx => {
        const elem = jmeterData[idx];
        const metricValue = metricValues[idx];
        
        if (metricValue === null) return;
        
        let tr = document.createElement('tr');
        tr.className = 'summary-row';
        tr.dataset.system = elem.system;
        
        let td_name = document.createElement('td');
        td_name.className = 'summary-name';
        
        let link = document.createElement('a');
        const displayName = getDisplayName(elem);
        link.appendChild(document.createTextNode(displayName));
        link.href = elem.github;
        link.style.color = `oklch(var(--hashed-link-lightness) 0.2018 ${nameToColor(elem.system.split(' ')[0])})`;
        td_name.appendChild(link);
        td_name.appendChild(document.createTextNode(': '));
        
        const ratio = summaries[idx];
        const percentage = ratio / max_ratio * 100;
        
        let td_number = document.createElement('td');
        td_number.className = 'summary-number';
        
        let text;
        if (selectors.metric === 'qps' || selectors.metric === 'succ-qps') {
            text = `${metricValue.toFixed(2)} QPS (×${ratio.toFixed(2)})`;
        } else if (selectors.metric === 'error') {
            text = `${metricValue.toFixed(2)}% (×${ratio.toFixed(2)})`;
        } else {
            text = `${metricValue.toFixed(3)}s (×${ratio.toFixed(2)})`;
        }
        
        td_number.appendChild(document.createTextNode(text));
        
        let td_bar = document.createElement('td');
        td_bar.className = 'summary-bar-cell';
        
        let bar = document.createElement('div');
        bar.className = 'summary-bar';
        bar.style.background = `linear-gradient(to right,
            var(--bar-color1) 0%,
            var(--bar-color1) ${Math.min(100, percentage)}%,
            var(--bar-color2) ${Math.min(100, percentage)}%,
            var(--bar-color2) ${Math.min(100, percentage * 10)}%,
            var(--bar-color3) ${Math.min(100, percentage * 10)}%,
            var(--bar-color3) ${Math.min(100, percentage * 100)}%,
            var(--bar-color4) ${Math.min(100, percentage * 100)}%,
            var(--bar-color4) ${Math.min(100, percentage * 1000)}%,
            transparent ${Math.min(100, percentage * 1000)}%,
            transparent 100%)`;
        
        td_bar.appendChild(bar);
        
        tr.appendChild(td_name);
        tr.appendChild(td_bar);
        tr.appendChild(td_number);
        table.appendChild(tr);
    });
    
    return [sorted_indices, []];
}

// Main render function
function render() {
    let summary = document.getElementById('summary');
    let details_head = document.getElementById('details_head');
    let details_body = document.getElementById('details_body');
    
    clearElement(summary);
    clearElement(details_head);
    clearElement(details_body);
    
    // Filter data
    let filtered_data = processedData.filter(elem =>
        elem.page === pageMode &&
        selectors.benchmark[elem.benchmark] &&
        selectors.scale[elem.scale] &&
        selectors.system[elem.system] &&
        selectors.machine[elem.machine] &&
        selectors.version[getDisplayVersion(elem)] &&
        selectors.cluster[String(elem.cluster_size)]
    );
    
    // Additional filtering by metric for single thread mode
    if (selectors.thread === 1) {
        if (selectors.metric === 'size') {
            filtered_data = filtered_data.filter(e => e.data_size);
        } else if (selectors.metric === 'load') {
            filtered_data = filtered_data.filter(e => e.load_time >= 5);
        } else {
            // For hot, cold, combined metrics, require non-empty query results
            filtered_data = filtered_data.filter(e => e.result && e.result.length > 0);
        }
    } else {
        filtered_data = filtered_data.filter(e => getJmeterResult(e, selectors.thread) !== null);
    }
    
    // Show/hide nothing selected message
    let nothing_selected = document.getElementById('nothing-selected');
    if (filtered_data.length === 0) {
        nothing_selected.style.display = 'block';
        [...document.querySelectorAll('.comparison')].map(e => e.style.display = 'none');
        setDetailedComparisonVisible(false);
        return;
    }
    nothing_selected.style.display = 'none';
    document.getElementById('summary-title').style.display = 'block';
    document.getElementById('summary-comparison').style.display = 'table';
    
    // Initialize query checkboxes for single thread mode
    if (selectors.thread === 1) {
        const maxQueries = Math.max(...filtered_data.map(e => e.result.length));
        if (selectors.queries.length !== maxQueries) {
            selectors.queries = [...Array(maxQueries)].map(() => true);
        }
    } else {
        // Initialize JMeter query checkboxes
        const queryNames = getJmeterQueryNames(filtered_data, selectors.thread);
        queryNames.forEach(q => {
            if (selectors.jmeterQueries[q] === undefined) {
                selectors.jmeterQueries[q] = true;
            }
        });
        // Remove queries that no longer exist
        Object.keys(selectors.jmeterQueries).forEach(q => {
            if (!queryNames.includes(q)) {
                delete selectors.jmeterQueries[q];
            }
        });
    }

    const benchmarkScaleGroups = getBenchmarkScaleGroups(filtered_data);
    const showDetailedComparison = benchmarkScaleGroups.length === 1;
    let detailGroupData = null;
    let sorted_indices = [];
    let baseline_data = [];
    
    // Render based on thread selection
    if (selectors.thread === 1) {
        document.getElementById('better-direction').textContent = 'lower is better';

        benchmarkScaleGroups.forEach(group => {
            appendSummaryGroupHeader(summary, group);
            [sorted_indices, baseline_data] = renderSummarySingleThread(group.entries, { table: summary, append: true });
            if (showDetailedComparison) {
                detailGroupData = group.entries;
            }
        });

        if (showDetailedComparison && detailGroupData) {
            renderDetailsSingleThread(detailGroupData, sorted_indices, baseline_data);
        }
    } else {
        if (selectors.metric === 'qps' || selectors.metric === 'succ-qps') {
            document.getElementById('better-direction').textContent = 'higher is better';
        } else {
            document.getElementById('better-direction').textContent = 'lower is better';
        }

        benchmarkScaleGroups.forEach(group => {
            appendSummaryGroupHeader(summary, group);
            [sorted_indices] = renderSummaryMultiThread(group.entries, { table: summary, append: true });
            if (showDetailedComparison) {
                detailGroupData = group.entries;
            }
        });

        if (showDetailedComparison && detailGroupData) {
            renderDetailsMultiThread(detailGroupData, sorted_indices);
        }
    }

    setDetailedComparisonVisible(showDetailedComparison);
    
    document.getElementById("scale_hint").textContent = 'Different colors represent values at different scales (1x, 10x, 100x zoom)';
}

// Render details for single thread mode
function renderDetailsSingleThread(filtered_data, sorted_indices, baseline_data) {
    let details_head = document.getElementById('details_head');
    let details_body = document.getElementById('details_body');
    
    if (sorted_indices.length === 0) return;
    
    // Generate details header
    let th_checkbox = document.createElement('th');
    let checkbox = document.createElement('input');
    checkbox.type = 'checkbox';
    checkbox.checked = true;
    checkbox.addEventListener('change', e => {
        [...document.querySelectorAll('.query-checkbox')].map(elem => { elem.checked = e.target.checked });
        selectors.queries = selectors.queries.map(() => e.target.checked);
        renderSummarySingleThread(filtered_data);
    });
    th_checkbox.appendChild(checkbox);
    details_head.appendChild(th_checkbox);
    details_head.appendChild(document.createElement('th'));
    
    sorted_indices.forEach(idx => {
        const elem = filtered_data[idx];
        let th = document.createElement('th');
        th.appendChild(document.createTextNode(getDisplayName(elem, true)));
        th.className = 'th-entry';
        th.dataset.system = elem.system;
        details_head.appendChild(th);
    });
    
    // Load times row
    {
        let tr = document.createElement('tr');
        tr.className = 'shadow';
        
        let td_title = document.createElement('td');
        td_title.colSpan = 2;
        td_title.appendChild(document.createTextNode('Load time: '));
        tr.appendChild(td_title);
        
        sorted_indices.forEach(idx => {
            const curr_timing = filtered_data[idx].load_time;
            const baseline_timing = Math.min(...filtered_data.map(e => e.load_time).filter(x => x >= 5));
            const ratio = curr_timing ? curr_timing / baseline_timing : null;
            
            let td = document.createElement('td');
            td.appendChild(document.createTextNode(curr_timing ? `${Math.round(curr_timing)}s (×${ratio.toFixed(2)})` : 'N/A'));
            colorize(td, ratio);
            tr.appendChild(td);
        });
        
        details_body.appendChild(tr);
    }
    
    // Data sizes row
    {
        let tr = document.createElement('tr');
        tr.className = 'shadow';
        
        let td_title = document.createElement('td');
        td_title.colSpan = 2;
        td_title.appendChild(document.createTextNode('Data size: '));
        tr.appendChild(td_title);
        
        sorted_indices.forEach(idx => {
            const curr_size = filtered_data[idx].data_size;
            const baseline_size = Math.min(...filtered_data.map(e => e.data_size).filter(x => x));
            const ratio = curr_size ? curr_size / baseline_size : null;
            
            let td = document.createElement('td');
            td.appendChild(document.createTextNode(curr_size ? `${(curr_size / 1024 / 1024 / 1024).toFixed(2)} GiB (×${ratio.toFixed(2)})` : 'N/A'));
            colorize(td, ratio);
            tr.appendChild(td);
        });
        
        details_body.appendChild(tr);
    }
    
    // Query runtimes
    const num_queries = Math.max(...filtered_data.map(e => e.result.length));
    
    for (let query_num = 0; query_num < num_queries; ++query_num) {
        let tr = document.createElement('tr');
        tr.className = 'shadow';
        
        let td_checkbox = document.createElement('td');
        let qcheckbox = document.createElement('input');
        qcheckbox.type = 'checkbox';
        qcheckbox.className = 'query-checkbox';
        qcheckbox.checked = selectors.queries[query_num];
        qcheckbox.addEventListener('change', e => {
            selectors.queries[query_num] = e.target.checked;
            renderSummarySingleThread(filtered_data);
        });
        td_checkbox.appendChild(qcheckbox);
        tr.appendChild(td_checkbox);
        
        let td_query_num = document.createElement('td');
        let queryKey = null;
        if (filtered_data.length > 0 && filtered_data[0].query_times) {
            const sortedKeys = Object.keys(filtered_data[0].query_times).sort((a, b) => {
                return a.localeCompare(b, undefined, { numeric: true });
            });
            queryKey = sortedKeys[query_num];
        }
        td_query_num.appendChild(document.createTextNode(queryKey ? `${queryKey}: ` : `Q${query_num + 1}. `));
        tr.appendChild(td_query_num);
        
        sorted_indices.forEach(idx => {
            const elem = filtered_data[idx];
            const curr_timing = elem.result[query_num] ? selectRun(elem.result[query_num], selectors.metric) : null;
            const baseline_timing = baseline_data[query_num] ? selectRun(baseline_data[query_num], selectors.metric) : null;
            const ratio = (curr_timing !== null && baseline_timing) 
                ? (constant_time_add + curr_timing) / (constant_time_add + baseline_timing) 
                : null;
            
            let td = document.createElement('td');
            td.appendChild(document.createTextNode(curr_timing !== null ? `${curr_timing.toFixed(3)}s (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A'));
            colorize(td, ratio);
            tr.appendChild(td);
        });
        
        details_body.appendChild(tr);
    }
}

// Get JMeter query result for a specific thread count and query
function getJmeterQueryResult(entry, threadCount, queryName) {
    if (!entry.jmeter_results || entry.jmeter_results.length === 0) return null;
    
    for (const result of entry.jmeter_results) {
        if (result.config && result.config.threads === threadCount && result.queries) {
            const queryResult = result.queries[queryName];
            return queryResult ? normalizeJmeterResult(queryResult) : null;
        }
    }
    return null;
}

// Get all query names from JMeter data for a specific thread count
function getJmeterQueryNames(filtered_data, threadCount) {
    const queryNames = new Set();
    filtered_data.forEach(entry => {
        if (!entry.jmeter_results) return;
        entry.jmeter_results.forEach(result => {
            if (result.config && result.config.threads === threadCount && result.queries) {
                Object.keys(result.queries).forEach(q => queryNames.add(q));
            }
        });
    });
    // Sort query names
    return [...queryNames].sort((a, b) => {
        const numA = parseInt(a.replace(/[^0-9]/g, '')) || 0;
        const numB = parseInt(b.replace(/[^0-9]/g, '')) || 0;
        return numA - numB;
    });
}

// Render details for multi-thread (JMeter) mode
function renderDetailsMultiThread(filtered_data, sorted_indices) {
    let details_head = document.getElementById('details_head');
    let details_body = document.getElementById('details_body');
    
    // Filter data with JMeter results for selected thread count
    const jmeterData = filtered_data.filter(e => getJmeterResult(e, selectors.thread) !== null);
    
    if (jmeterData.length === 0) return;
    
    // Sort by the current metric
    const sortedData = [...jmeterData].sort((a, b) => {
        const resultA = getJmeterResult(a, selectors.thread);
        const resultB = getJmeterResult(b, selectors.thread);
        
        if (!resultA || !resultB) return 0;
        
        switch (selectors.metric) {
            case 'qps':
                return (resultB.throughput || 0) - (resultA.throughput || 0);
            case 'succ-qps':
                return ((resultB.throughput || 0) * (1 - (resultB.errorPct || 0) / 100)) - 
                       ((resultA.throughput || 0) * (1 - (resultA.errorPct || 0) / 100));
            case 'avg':
                return (resultA.meanResTime || 0) - (resultB.meanResTime || 0);
            case 'p99':
                return (resultA.pct3ResTime || 0) - (resultB.pct3ResTime || 0);
            case 'error':
                return (resultA.errorPct || 0) - (resultB.errorPct || 0);
            default:
                return (resultB.throughput || 0) - (resultA.throughput || 0);
        }
    });
    
    // Get all query names
    const queryNames = getJmeterQueryNames(filtered_data, selectors.thread);
    
    // Generate details header (no checkbox in multi-thread mode)
    details_head.appendChild(document.createElement('th')); // Empty column for alignment
    details_head.appendChild(document.createElement('th')); // Empty for query name
    
    sortedData.forEach(elem => {
        let th = document.createElement('th');
        th.appendChild(document.createTextNode(getDisplayName(elem, true)));
        th.className = 'th-entry';
        th.dataset.system = elem.system;
        details_head.appendChild(th);
    });
    
    // Total row
    {
        let tr = document.createElement('tr');
        tr.className = 'shadow';
        
        let td_empty = document.createElement('td');
        tr.appendChild(td_empty);
        
        let td_title = document.createElement('td');
        td_title.appendChild(document.createTextNode('Total: '));
        td_title.style.fontWeight = 'bold';
        tr.appendChild(td_title);
        
        // Always use original total result - never recalculate based on query selection
        const getResultForTotal = (e) => {
            return getJmeterResult(e, selectors.thread);
        };
        
        let baselineValue;
        if (selectors.metric === 'qps') {
            baselineValue = Math.max(...sortedData.map(e => getResultForTotal(e)?.throughput || 0));
        } else if (selectors.metric === 'succ-qps') {
            baselineValue = Math.max(...sortedData.map(e => {
                const res = getResultForTotal(e);
                return res?.throughput && res?.errorPct != null ? res.throughput * (1 - res.errorPct / 100) : 0;
            }));
        } else if (selectors.metric === 'avg') {
            baselineValue = Math.min(...sortedData.map(e => getResultForTotal(e)?.meanResTime || Infinity).filter(x => x > 0));
        } else if (selectors.metric === 'p99') {
            baselineValue = Math.min(...sortedData.map(e => getResultForTotal(e)?.pct3ResTime || Infinity).filter(x => x > 0));
        } else if (selectors.metric === 'error') {
            baselineValue = Math.min(...sortedData.map(e => getResultForTotal(e)?.errorPct ?? Infinity).filter(x => x >= 0));
        }
        
        sortedData.forEach(elem => {
            const result = getResultForTotal(elem);
            let value, ratio, text;
            
            if (selectors.metric === 'qps') {
                value = result?.throughput;
                ratio = value ? baselineValue / value : null;
                text = value ? `${value.toFixed(2)} QPS (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            } else if (selectors.metric === 'succ-qps') {
                value = result?.throughput != null && result?.errorPct != null ? result.throughput * (1 - result.errorPct / 100) : null;
                ratio = value ? baselineValue / value : null;
                text = value ? `${value.toFixed(2)} QPS (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            } else if (selectors.metric === 'avg') {
                value = result?.meanResTime;
                ratio = value ? value / baselineValue : null;
                text = value ? `${(value / 1000).toFixed(3)}s (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            } else if (selectors.metric === 'p99') {
                value = result?.pct3ResTime;
                ratio = value ? value / baselineValue : null;
                text = value ? `${(value / 1000).toFixed(3)}s (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            } else if (selectors.metric === 'error') {
                value = result?.errorPct;
                ratio = (value != null && baselineValue != null) ? (baselineValue === 0 ? (value === 0 ? 1 : value + 1) : value / baselineValue) : null;
                text = value != null ? `${value.toFixed(2)}% (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            }
            
            let td = document.createElement('td');
            td.appendChild(document.createTextNode(text));
            colorize(td, ratio);
            tr.appendChild(td);
        });
        
        details_body.appendChild(tr);
    }
    
    // Per-query rows
    queryNames.forEach(queryName => {
        let tr = document.createElement('tr');
        tr.className = 'shadow';
        
        // Empty cell for alignment (no checkbox in multi-thread mode)
        let td_empty = document.createElement('td');
        tr.appendChild(td_empty);
        
        let td_query_name = document.createElement('td');
        td_query_name.appendChild(document.createTextNode(queryName));
        tr.appendChild(td_query_name);
        
        // Calculate baseline for this query
        let baselineValue;
        if (selectors.metric === 'qps') {
            baselineValue = Math.max(...sortedData.map(e => getJmeterQueryResult(e, selectors.thread, queryName)?.throughput || 0));
        } else if (selectors.metric === 'succ-qps') {
            baselineValue = Math.max(...sortedData.map(e => {
                const res = getJmeterQueryResult(e, selectors.thread, queryName);
                return res?.throughput && res?.errorPct != null ? res.throughput * (1 - res.errorPct / 100) : 0;
            }));
        } else if (selectors.metric === 'avg') {
            baselineValue = Math.min(...sortedData.map(e => getJmeterQueryResult(e, selectors.thread, queryName)?.meanResTime || Infinity).filter(x => x > 0));
        } else if (selectors.metric === 'p99') {
            baselineValue = Math.min(...sortedData.map(e => getJmeterQueryResult(e, selectors.thread, queryName)?.pct3ResTime || Infinity).filter(x => x > 0));
        } else if (selectors.metric === 'error') {
            baselineValue = Math.min(...sortedData.map(e => getJmeterQueryResult(e, selectors.thread, queryName)?.errorPct ?? Infinity).filter(x => x >= 0));
        }
        
        sortedData.forEach(elem => {
            const queryResult = getJmeterQueryResult(elem, selectors.thread, queryName);
            let value, ratio, text;
            
            if (selectors.metric === 'qps') {
                value = queryResult?.throughput;
                ratio = (value && baselineValue) ? baselineValue / value : null;
                text = value ? `${value.toFixed(2)} (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            } else if (selectors.metric === 'succ-qps') {
                value = queryResult?.throughput != null && queryResult?.errorPct != null ? queryResult.throughput * (1 - queryResult.errorPct / 100) : null;
                ratio = (value && baselineValue) ? baselineValue / value : null;
                text = value ? `${value.toFixed(2)} (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            } else if (selectors.metric === 'avg') {
                value = queryResult?.meanResTime;
                ratio = (value && baselineValue) ? value / baselineValue : null;
                text = value ? `${(value / 1000).toFixed(3)}s (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            } else if (selectors.metric === 'p99') {
                value = queryResult?.pct3ResTime;
                ratio = (value && baselineValue) ? value / baselineValue : null;
                text = value ? `${(value / 1000).toFixed(3)}s (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            } else if (selectors.metric === 'error') {
                value = queryResult?.errorPct;
                ratio = (value != null && baselineValue != null) ? (baselineValue === 0 ? (value === 0 ? 1 : value + 1) : value / baselineValue) : null;
                text = value != null ? `${value.toFixed(2)}% (×${ratio?.toFixed(2) || 'N/A'})` : 'N/A';
            }
            
            let td = document.createElement('td');
            td.appendChild(document.createTextNode(text));
            colorize(td, ratio);
            tr.appendChild(td);
        });
        
        details_body.appendChild(tr);
    });
}

// Initialize and render
initSelectors();
render();

</script>
</body>
</html>
HTMLJS

echo "HTML report generated: $OUTPUT_FILE"
echo "Open the file in a browser to view the benchmark results."
