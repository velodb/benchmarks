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

# Initialize yq from tools directory
init_yq() {
    _init_tools_dir
    
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

init_vectordbbench() {
    _init_tools_dir

    local wheelhouse_dir="$TOOLS_DIR/vectordb_wheelhouse"
    local requirements_file="$TOOLS_DIR/vectordb_requirements.txt"
    local venv_dir="$TOOLS_DIR/vectordbbench_venv"
    local venv_python="$venv_dir/bin/python"
    local vdb_binary="$venv_dir/bin/vectordbbench"
    local python_binary=""

    if [ -x "$vdb_binary" ]; then
        export PATH="$venv_dir/bin:$PATH"
        export VECTORDBBENCH_BIN="$vdb_binary"
        echo "Using local VectorDBBench: $vdb_binary"
        return 0
    fi

    python_binary="$(command -v python3 || true)"
    if [ -d "$wheelhouse_dir" ] && [ -n "$python_binary" ]; then
        echo "Installing VectorDBBench from local wheelhouse..."
        if [ ! -x "$venv_python" ] && ! "$python_binary" -m venv "$venv_dir"; then
            echo "WARNING: Failed to create local VectorDBBench venv: $venv_dir" >&2
        fi

        if [ -x "$venv_python" ]; then
            if ! "$venv_python" -m pip --version >/dev/null 2>&1; then
                "$venv_python" -m ensurepip --upgrade >/dev/null 2>&1 || true
            fi

            if "$venv_python" -m pip --version >/dev/null 2>&1; then
                "$venv_python" -m pip install --disable-pip-version-check \
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
                    if "$venv_python" -m pip install "${install_args[@]}" -r "$requirements_file"; then
                        export PATH="$venv_dir/bin:$PATH"
                        export VECTORDBBENCH_BIN="$vdb_binary"
                        echo "Using local VectorDBBench: $vdb_binary"
                        return 0
                    fi
                elif "$venv_python" -m pip install "${install_args[@]}" vectordb-bench doris-vector-search mysql-connector==2.2.9; then
                    export PATH="$venv_dir/bin:$PATH"
                    export VECTORDBBENCH_BIN="$vdb_binary"
                    echo "Using local VectorDBBench: $vdb_binary"
                    return 0
                fi

                echo "WARNING: Failed to install VectorDBBench from local wheelhouse, falling back to other options." >&2
            fi
        fi
    elif [ -d "$wheelhouse_dir" ]; then
        echo "WARNING: python3 not found, cannot install VectorDBBench from local wheelhouse." >&2
    fi

    if command -v vectordbbench >/dev/null 2>&1; then
        export VECTORDBBENCH_BIN="$(command -v vectordbbench)"
        echo "Using system VectorDBBench: $VECTORDBBENCH_BIN"
        return 0
    fi

    if [ -n "$python_binary" ]; then
        echo "Installing VectorDBBench via user pip..."
        if "$python_binary" -m pip install --user -U vectordb-bench doris-vector-search mysql-connector==2.2.9; then
            export PATH="$HOME/.local/bin:$PATH"
            if command -v vectordbbench >/dev/null 2>&1; then
                export VECTORDBBENCH_BIN="$(command -v vectordbbench)"
                echo "Using user-installed VectorDBBench: $VECTORDBBENCH_BIN"
                return 0
            fi
        fi
    fi

    echo "ERROR: VectorDBBench not found and installation failed" >&2
    return 1
}
