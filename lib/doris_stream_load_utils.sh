#!/bin/bash
# Doris Stream Load Utilities

redact_doris_stream_load_response() {
    local content="$1"
    local variable_name secret

    for variable_name in password PASSWORD STORAGE_ACCESS_KEY STORAGE_SECRET_KEY; do
        secret="${!variable_name:-}"
        [ -z "$secret" ] && continue
        content=$(printf '%s' "$content" | REDACT_NEEDLE="$secret" awk '
            BEGIN { needle = ENVIRON["REDACT_NEEDLE"]; replacement = "[REDACTED]" }
            {
                line = $0
                while (needle != "" && (position = index(line, needle)) > 0) {
                    line = substr(line, 1, position - 1) replacement substr(line, position + length(needle))
                }
                print line
            }
        ')
    done

    printf '%s\n' "$content"
}

persist_doris_stream_load_response() {
    local this_label="$1"
    local response="$2"
    local profile_dir="${LOAD_PROFILE_DIR:-}"
    local profile_index="${LOAD_PROFILE_INDEX:-}"
    local artifact_prefix="${LOAD_PROFILE_ARTIFACT_PREFIX:-stream_load}"

    [ -z "$profile_dir" ] && return 0
    mkdir -p "$profile_dir" || return 1

    local safe_label response_file profile_id=""
    safe_label="${this_label//[^a-zA-Z0-9_.-]/_}"
    response_file="$profile_dir/${artifact_prefix}_${safe_label}_stream_load_response.json"
    response=$(redact_doris_stream_load_response "$response")

    if command -v jq >/dev/null 2>&1 && printf '%s' "$response" | jq -e . >/dev/null 2>&1; then
        printf '%s' "$response" | jq . > "$response_file" || return 1
        profile_id=$(printf '%s' "$response" | jq -r '.TxnId // .txnId // empty' 2>/dev/null || true)
    else
        response_file="${response_file%.json}.txt"
        printf '%s\n' "$response" > "$response_file" || return 1
    fi

    if [ -n "$profile_index" ]; then
        local relative_file="$response_file"
        if [ -n "${RESULT_DIR:-}" ]; then
            relative_file="${response_file#$RESULT_DIR/}"
        fi
        printf '"%s","stream_load","%s","stream_load_response","%s"\n' \
            "$this_label" "$profile_id" "$relative_file" >> "$profile_index" || return 1
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

    if ! persist_doris_stream_load_response "$this_label" "$resp"; then
        echo "[WARN] Failed to persist Stream Load diagnostics for label: ${this_label}" >&2
    fi

    if [ "$errexit_was_set" = "true" ]; then
        set -e
    fi

    if [ "$curl_status" -ne 0 ]; then
        [ -n "$resp" ] && echo "$resp"
        echo "[ERROR] Stream load request failed for ${db}.${table} (${load_scope}, label: ${this_label}, curl exit=${curl_status})" >&2
        exit "$curl_status"
    fi
}
