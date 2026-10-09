#!/bin/bash
# Tools Utilities
#
# This module handles initialization and management of local tools
# located in the tools directory.

# Global variable for tools directory
TOOLS_DIR=""
TOOLS_WRAPPER_DIR=""
TOOLS_COMMON_TOOLS_READY=""
TOOLS_CURL_TOOL_READY=""
TOOLS_UTILS_LOADED=1

# Initialize tools directory path
_init_tools_dir() {
    if [ -z "$TOOLS_DIR" ]; then
        # Get the directory where this script is located
        local lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        TOOLS_DIR="$(dirname "$lib_dir")/tools"
    fi
}

_init_tools_wrapper_dir() {
    if [ -n "$TOOLS_WRAPPER_DIR" ] && [ -d "$TOOLS_WRAPPER_DIR" ]; then
        case ":$PATH:" in
            *":$TOOLS_WRAPPER_DIR:"*) ;;
            *) export PATH="$TOOLS_WRAPPER_DIR:$PATH" ;;
        esac
        return 0
    fi

    TOOLS_WRAPPER_DIR="$(mktemp -d "${TMPDIR:-/tmp}/benchmarks-tools.XXXXXX")" || return 1
    export PATH="$TOOLS_WRAPPER_DIR:$PATH"
}

_write_command_wrapper() {
    local wrapper_path="$1"
    local target_binary="$2"
    local target_ld_path="${3:-}"

    mkdir -p "$(dirname "$wrapper_path")"

    if [ -n "$target_ld_path" ]; then
        cat >"$wrapper_path" <<EOF
#!/bin/sh
exec env LD_LIBRARY_PATH="$target_ld_path\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}" "$target_binary" "\$@"
EOF
    else
        cat >"$wrapper_path" <<EOF
#!/bin/sh
exec "$target_binary" "\$@"
EOF
    fi

    chmod +x "$wrapper_path"
}

_find_fallback_command() {
    local cmd_name="$1"
    local path_entry
    local candidate
    local -a path_entries

    IFS=':' read -r -a path_entries <<< "${PATH:-}"
    for path_entry in "${path_entries[@]}"; do
        [ -n "$path_entry" ] || path_entry="."
        if [ -n "$TOOLS_WRAPPER_DIR" ] && [ "$path_entry" = "$TOOLS_WRAPPER_DIR" ]; then
            continue
        fi
        if [ -n "$TOOLS_DIR" ] && [ "$path_entry" = "$TOOLS_DIR/bin" ]; then
            continue
        fi

        candidate="$path_entry/$cmd_name"
        if [ -x "$candidate" ] && [ ! -d "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    command -p -v "$cmd_name" 2>/dev/null || true
}

_init_command_with_fallback() {
    local cmd_name="$1"
    local local_binary="$2"
    local local_ld_path="${3:-}"
    local wrapper_path="$TOOLS_WRAPPER_DIR/$cmd_name"
    local system_binary=""

    if [ -x "$local_binary" ]; then
        if [ -n "$local_ld_path" ]; then
            if env LD_LIBRARY_PATH="$local_ld_path" "$local_binary" --version >/dev/null 2>&1; then
                _write_command_wrapper "$wrapper_path" "$local_binary" "$local_ld_path"
                echo "Using local $cmd_name: $local_binary"
                return 0
            fi
        elif "$local_binary" --version >/dev/null 2>&1; then
            _write_command_wrapper "$wrapper_path" "$local_binary"
            echo "Using local $cmd_name: $local_binary"
            return 0
        fi

        echo "WARNING: local $cmd_name is not runnable on this host, falling back to system $cmd_name." >&2
    fi

    system_binary="$(_find_fallback_command "$cmd_name")"
    if [ -n "$system_binary" ]; then
        _write_command_wrapper "$wrapper_path" "$system_binary"
        echo "Using system $cmd_name: $system_binary"
        return 0
    fi

    echo "ERROR: $cmd_name not found in tools directory or system PATH" >&2
    return 1
}

init_common_tools() {
    _init_tools_dir
    _init_tools_wrapper_dir || return 1

    if [ -n "$TOOLS_COMMON_TOOLS_READY" ]; then
        return 0
    fi

    local missing_tools=()

    _init_command_with_fallback jq "$TOOLS_DIR/bin/jq" "$TOOLS_DIR/lib" || missing_tools+=("jq")
    _init_command_with_fallback bc "$TOOLS_DIR/bin/bc" "$TOOLS_DIR/lib" || missing_tools+=("bc")
    _init_command_with_fallback envsubst "$TOOLS_DIR/bin/envsubst" "$TOOLS_DIR/lib" || missing_tools+=("envsubst")
    if [ ${#missing_tools[@]} -ne 0 ]; then
        echo "ERROR: missing required common tools: ${missing_tools[*]}" >&2
        return 1
    fi

    TOOLS_COMMON_TOOLS_READY=1
}

init_curl_tool() {
    _init_tools_dir
    _init_tools_wrapper_dir || return 1

    if [ -n "$TOOLS_CURL_TOOL_READY" ]; then
        return 0
    fi

    _init_command_with_fallback curl "$TOOLS_DIR/bin/curl" "$TOOLS_DIR/lib" || return 1
    TOOLS_CURL_TOOL_READY=1
}

# Initialize yq from tools directory
init_yq() {
    _init_tools_dir
    init_common_tools
    
    local yq_dir="$TOOLS_DIR/yq_dir"
    local yq_binary="$yq_dir/yq"
    local yq_archive="$TOOLS_DIR/yq_linux_amd64.tar.gz"
    
    # Extract yq if archive exists and binary doesn't
    if [ ! -f "$yq_binary" ] && [ -f "$yq_archive" ]; then
        echo "Extracting yq..."
        mkdir -p "$yq_dir"
        tar -xzf "$yq_archive" -C "$yq_dir"
        # The archive extracts to ./yq_linux_amd64, rename it to yq
        if [ -f "$yq_dir/yq_linux_amd64" ]; then
            mv "$yq_dir/yq_linux_amd64" "$yq_binary"
        fi
    fi
    
    if [ -f "$yq_binary" ]; then
        # Make it executable if needed
        if [ ! -x "$yq_binary" ]; then
            chmod +x "$yq_binary"
        fi
        
        # Add yq directory to PATH
        export PATH="$yq_dir:$PATH"
        echo "Using local yq: $yq_binary"
        return 0
    fi
    
    # Fall back to system yq
    if command -v yq >/dev/null 2>&1; then
        echo "Using system yq"
        return 0
    fi
    
    echo "ERROR: yq not found in tools directory or system PATH" >&2
    return 1
}
init_java_env() {
    _init_tools_dir
    local java_dir="$TOOLS_DIR/java_dir"
    local java_binary="$java_dir/bin/java"
    local java_archive="$TOOLS_DIR/OpenJDK17U-jdk_x64_linux_hotspot_17.0.17_10.tar.gz"
    if [ ! -f "$java_binary" ] && [ -f "$java_archive" ]; then
        echo "Extracting Java..."
        mkdir -p "$java_dir"
        tar -xzf "$java_archive" -C "$java_dir" --strip-components=1
    fi
    if [ -f "$java_binary" ]; then
        export JAVA_HOME="$java_dir"
        export PATH="$java_dir/bin:$PATH"
        echo "Using local Java: $java_binary"
        return 0
    fi
    if command -v java >/dev/null 2>&1; then
        echo "Using system Java"
        return 0
    fi
    echo "ERROR: Java not found in tools directory or system PATH" >&2
    return 1
}

# Initialize JMeter from tools directory
init_jmeter() {
    _init_tools_dir
    
    local jmeter_archive="$TOOLS_DIR/apache-jmeter-5.6.3.tgz"
    local jmeter_dir="$TOOLS_DIR/apache-jmeter-5.6.3"
    
    if [ -f "$jmeter_archive" ]; then
        # Extract if not already extracted
        if [ ! -d "$jmeter_dir" ]; then
            echo "Extracting JMeter..."
            tar -xzf "$jmeter_archive" -C "$TOOLS_DIR"
        fi
        
        export JMETER_HOME="$jmeter_dir"
        export PATH="$jmeter_dir/bin:$PATH"
        echo "Using local JMeter: $jmeter_dir"
        return 0
    fi
    
    # Fall back to system JMeter
    if command -v jmeter >/dev/null 2>&1; then
        echo "Using system JMeter"
        return 0
    fi
    
    echo "WARNING: JMeter not found in tools directory or system PATH" >&2
    return 1
}

# Initialize all tools
init_basic_tools() {
    echo "Initializing tools..."
    init_common_tools
    
    # Always initialize yq (required)
    if ! init_yq; then
        return 1
    fi
    
    return 0
}

# Initialize tools that are only needed for JMeter mode
init_jmeter_tools() {
    if ! init_jmeter; then
        return 1
    fi
    return 0
}

init_sysbench() {
    _init_tools_dir

    local sysbench_dir="$TOOLS_DIR/sysbench_dir"
    local sysbench_binary="$sysbench_dir/bin/sysbench"
    local sysbench_archive="$TOOLS_DIR/sysbench_dir.tar.gz"

    if [ ! -f "$sysbench_binary" ] && [ -f "$sysbench_archive" ]; then
        echo "Extracting sysbench..."
        mkdir -p "$TOOLS_DIR"
        tar -xzf "$sysbench_archive" -C "$TOOLS_DIR"
    fi

    if [ -f "$sysbench_binary" ]; then
        export LD_LIBRARY_PATH="$sysbench_dir/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
        export PATH="$sysbench_dir/bin:$PATH"
        export LUA_PATH="$sysbench_dir/share/sysbench/?.lua;;"
        export SYSBENCH_SHARE_DIR="$sysbench_dir/share/sysbench"
        echo "Using local sysbench: $sysbench_binary"
        return 0
    fi

    if command -v sysbench >/dev/null 2>&1; then
        echo "Using system sysbench"
        return 0
    fi

    echo "ERROR: sysbench not found in tools directory or system PATH" >&2
    return 1
}

init_python_runtime() {
    _init_tools_dir
    init_common_tools

    local python_dir="$TOOLS_DIR/python_dir"
    local python_archive="$TOOLS_DIR/python_dir.tar.gz"
    local python_binary="$python_dir/bin/python3"

    if [ ! -x "$python_binary" ] && [ -f "$python_archive" ]; then
        echo "Extracting Python..."
        rm -rf "$python_dir"
        mkdir -p "$python_dir"
        tar -xzf "$python_archive" -C "$python_dir" --strip-components=1
    fi

    if [ -x "$python_binary" ]; then
        export PATH="$python_dir/bin:$PATH"
        export LD_LIBRARY_PATH="$python_dir/lib:${LD_LIBRARY_PATH:-}"
        export PYTHONNOUSERSITE=1
        if ! "$python_binary" -m pip --version >/dev/null 2>&1; then
            "$python_binary" -m ensurepip --upgrade >/dev/null 2>&1 || true
        fi
        echo "Using local Python: $python_binary"
        return 0
    fi

    return 1
}

init_vectordbbench() {
    _init_tools_dir

    local wheelhouse_dir="$TOOLS_DIR/vectordb_wheelhouse"
    local requirements_file="$TOOLS_DIR/vectordb_requirements.txt"
    local python_binary=""
    local vdb_binary="$TOOLS_DIR/python_dir/bin/vectordbbench"
    local use_local_python=false

    init_common_tools

    if [ -x "$vdb_binary" ]; then
        export VECTORDBBENCH_BIN="$vdb_binary"
        echo "Using local VectorDBBench: $VECTORDBBENCH_BIN"
        return 0
    fi

    if init_python_runtime; then
        python_binary="$TOOLS_DIR/python_dir/bin/python3"
        use_local_python=true
    else
        python_binary="$(command -v python3 || true)"
    fi

    if command -v vectordbbench >/dev/null 2>&1; then
        export VECTORDBBENCH_BIN="$(command -v vectordbbench)"
        echo "Using existing VectorDBBench: $VECTORDBBENCH_BIN"
        return 0
    fi

    if ! init_mysql_client; then
        return 1
    fi

    if [ "$use_local_python" = true ] && [ -d "$wheelhouse_dir" ]; then
        echo "Installing VectorDBBench from local wheelhouse..."
        if "$python_binary" -m pip --version >/dev/null 2>&1; then
            "$python_binary" -m pip install --disable-pip-version-check \
                --no-index \
                --find-links "$wheelhouse_dir" \
                setuptools >/dev/null 2>&1 || true

            local install_args=(
                --disable-pip-version-check
                --no-index
                --find-links "$wheelhouse_dir"
                --no-build-isolation
            )

            if [ -f "$requirements_file" ]; then
                if "$python_binary" -m pip install "${install_args[@]}" -r "$requirements_file"; then
                    if [ -x "$vdb_binary" ]; then
                        export VECTORDBBENCH_BIN="$vdb_binary"
                        echo "Using local VectorDBBench: $VECTORDBBENCH_BIN"
                        return 0
                    fi
                fi
            elif "$python_binary" -m pip install "${install_args[@]}" vectordb-bench doris-vector-search mysql-connector==2.2.9; then
                if [ -x "$vdb_binary" ]; then
                    export VECTORDBBENCH_BIN="$vdb_binary"
                    echo "Using local VectorDBBench: $VECTORDBBENCH_BIN"
                    return 0
                fi
            fi

            echo "WARNING: Failed to install VectorDBBench from local wheelhouse, falling back to other options." >&2
        fi
    elif [ -d "$wheelhouse_dir" ]; then
        echo "WARNING: local Python runtime not found, skip VectorDBBench local wheelhouse." >&2
    fi

    if command -v vectordbbench >/dev/null 2>&1; then
        export VECTORDBBENCH_BIN="$(command -v vectordbbench)"
        echo "Using system VectorDBBench: $VECTORDBBENCH_BIN"
        return 0
    fi

    echo "ERROR: VectorDBBench not found in third-party tools or system PATH" >&2
    return 1
}
