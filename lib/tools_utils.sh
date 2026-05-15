#!/bin/bash
# Tools Utilities
#
# This module handles initialization and management of local tools
# located in the tools directory.

# Global variable for tools directory
TOOLS_DIR=""

# Initialize tools directory path
_init_tools_dir() {
    if [ -z "$TOOLS_DIR" ]; then
        # Get the directory where this script is located
        local lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        TOOLS_DIR="$(dirname "$lib_dir")/tools"
    fi
}

init_common_tools() {
    _init_tools_dir

    if [ -d "$TOOLS_DIR/bin" ]; then
        export PATH="$TOOLS_DIR/bin:$PATH"
    fi

    if [ -d "$TOOLS_DIR/lib" ]; then
        export LD_LIBRARY_PATH="$TOOLS_DIR/lib:${LD_LIBRARY_PATH:-}"
    fi
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

init_mysql_client() {
    _init_tools_dir
    init_common_tools

    local mysql_dir="$TOOLS_DIR/mysql_client_dir"
    local mysql_binary="$mysql_dir/bin/mysql"
    local mysql_archive="$TOOLS_DIR/mysql_client_dir.tar.gz"

    if [ ! -x "$mysql_binary" ] && [ -f "$mysql_archive" ]; then
        echo "Extracting mysql client..."
        rm -rf "$mysql_dir"
        tar -xzf "$mysql_archive" -C "$TOOLS_DIR"
    fi

    if [ -x "$mysql_binary" ]; then
        export PATH="$mysql_dir/bin:$PATH"
        if [ -d "$mysql_dir/lib" ]; then
            export LD_LIBRARY_PATH="$mysql_dir/lib:${LD_LIBRARY_PATH:-}"
        fi
        echo "Using local mysql client: $mysql_binary"
        return 0
    fi

    if [ -x "$TOOLS_DIR/bin/mysql" ]; then
        echo "Using local mysql client: $TOOLS_DIR/bin/mysql"
        return 0
    fi

    if command -v mysql >/dev/null 2>&1; then
        echo "Using system mysql client"
        return 0
    fi

    echo "ERROR: mysql client not found in tools directory or system PATH" >&2
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
