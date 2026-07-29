#!/bin/bash

to_lower() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

normalize_bool() {
    if [[ "$(to_lower "${1:-}")" == "true" ]]; then
        printf '%s' "true"
    else
        printf '%s' "false"
    fi
}
