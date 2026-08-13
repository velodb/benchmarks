#!/bin/bash
# Doris Stream Load Utilities

persist_doris_stream_load_response() {
    local this_label="$1"
    local response="$2"

    [ -n "${LOAD_PROFILE_DIR:-}" ] || return 0
    local safe_label="${this_label//[^a-zA-Z0-9_.-]/_}"
    local response_file="${LOAD_PROFILE_DIR}/${LOAD_PROFILE_ARTIFACT_PREFIX}_${safe_label}_stream_load_response.json"
    local variable_name secret

    for variable_name in password PASSWORD STORAGE_ACCESS_KEY STORAGE_SECRET_KEY; do
        secret="${!variable_name:-}"
        [ -z "$secret" ] && continue
        response="${response//"$secret"/[REDACTED]}"
    done

    if command -v jq >/dev/null 2>&1 && printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$response" | jq . > "$response_file"
    else
        printf '%s\n' "$response" > "${response_file%.json}.txt"
    fi
}

run_doris_stream_load() {
    local this_label="$1"
    local input_file="$2"
    local load_scope="${3:-full file}"
    local curl_status
    local errexit_was_set="false"

    case "$-" in
        *e*)
            errexit_was_set="true"
            set +e
            ;;
    esac

    resp="$(do_curl "$this_label" "$input_file")"
    curl_status=$?

    persist_doris_stream_load_response "$this_label" "$resp" || \
        echo "[WARN] Failed to save Stream Load response for label: ${this_label}" >&2

    if [ "$errexit_was_set" = "true" ]; then
        set -e
    fi

    if [ "$curl_status" -ne 0 ]; then
        [ -n "$resp" ] && echo "$resp"
        echo "[ERROR] Stream load request failed for ${db}.${table} (${load_scope}, label: ${this_label}, curl exit=${curl_status})" >&2
        exit "$curl_status"
    fi
}
