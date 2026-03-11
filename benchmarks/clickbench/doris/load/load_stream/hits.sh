#!/bin/bash
set -euo pipefail

table="hits"

# Doris connection (inherited from benchmark.yaml via benchmark.sh)
host="${fe_host:-${FE_HOST:-127.0.0.1}}"
http_port="${fe_http_port:-${FE_HTTP_PORT:-8030}}"
db="${db:-clickbench}"
user_="${user:-root}"
pass="${password:-${PASSWORD:-}}"

# Stream load knobs (override if needed)
timeout_s="${DORIS_STREAM_LOAD_TIMEOUT_S:-86400}"
max_filter_ratio="${DORIS_MAX_FILTER_RATIO:-0.1}"

url="http://${host}:${http_port}/api/${db}/${table}/_stream_load"
label="bench_${db}_${table}_${RANDOM}_$$"

echo "[INFO] Stream load ${db}.${table} from: ${BENCH_DATA_DIR:-/mnt/disk1/wangchengfeng/benchmarks_velodb/benchmarks/clickbench/postgresql/load/hits.tsv}"

sep_value=$'\t'

headers=(
  # Doris Stream Load requires/benefits from Expect: 100-continue.
  -H "Expect: 100-continue"
  -H "format:csv"
  -H "column_separator:${sep_value}"
  -H "columns:WatchID,JavaEnable,Title,GoodEvent,EventTime,EventDate,CounterID,ClientIP,RegionID,UserID,CounterClass,OS,UserAgent,URL,Referer,IsRefresh,RefererCategoryID,RefererRegionID,URLCategoryID,URLRegionID,ResolutionWidth,ResolutionHeight,ResolutionDepth,FlashMajor,FlashMinor,FlashMinor2,NetMajor,NetMinor,UserAgentMajor,UserAgentMinor,CookieEnable,JavascriptEnable,IsMobile,MobilePhone,MobilePhoneModel,Params,IPNetworkID,TraficSourceID,SearchEngineID,SearchPhrase,AdvEngineID,IsArtifical,WindowClientWidth,WindowClientHeight,ClientTimeZone,ClientEventTime,SilverlightVersion1,SilverlightVersion2,SilverlightVersion3,SilverlightVersion4,PageCharset,CodeVersion,IsLink,IsDownload,IsNotBounce,FUniqID,OriginalURL,HID,IsOldCounter,IsEvent,IsParameter,DontCountHits,WithHash,HitColor,LocalEventTime,Age,Sex,Income,Interests,Robotness,RemoteIP,WindowName,OpenerName,HistoryLength,BrowserLanguage,BrowserCountry,SocialNetwork,SocialAction,HTTPError,SendTiming,DNSTiming,ConnectTiming,ResponseStartTiming,ResponseEndTiming,FetchTiming,SocialSourceNetworkID,SocialSourcePage,ParamPrice,ParamOrderID,ParamCurrency,ParamCurrencyID,OpenstatServiceName,OpenstatCampaignID,OpenstatAdID,OpenstatSourceID,UTMSource,UTMMedium,UTMCampaign,UTMContent,UTMTerm,FromTag,HasGCLID,RefererHash,URLHash,CLID"
  -H "timeout:${timeout_s}"
  -H "max_filter_ratio:${max_filter_ratio}"
)

DATA_FILE="${BENCH_DATA_DIR:-/mnt/disk1/wangchengfeng/benchmarks_velodb/benchmarks/clickbench/postgresql/load/hits.tsv}"

if [[ ! -f "$DATA_FILE" ]]; then
  echo "[ERROR] Source file not found: $DATA_FILE" >&2
  exit 1
fi

# Doris BE defaults to ~10GB max Stream Load body; load big files in chunks.
max_body_mb="${DORIS_STREAM_LOAD_BODY_MAX_MB:-10240}"
chunk_mb="${DORIS_STREAM_LOAD_CHUNK_MB:-8192}"

file_size_bytes="$(stat -c%s "$DATA_FILE")"
max_body_bytes="$((max_body_mb * 1024 * 1024))"

if (( file_size_bytes == 0 )); then
  echo "[ERROR] Source file is empty: $DATA_FILE" >&2
  exit 1
fi

do_curl() {
  local this_label="$1"
  local input_file="$2"

  if [[ "false" == "true" ]]; then
    sed 's/|$//' "$input_file" | \
      curl -sS --fail-with-body --location-trusted -u "${user_}:${pass}" -H "label:${this_label}" "${headers[@]}" -T - "$url"
  else
    curl -sS --fail-with-body --location-trusted -u "${user_}:${pass}" -H "label:${this_label}" "${headers[@]}" -T "$input_file" "$url"
  fi
}

if (( file_size_bytes > max_body_bytes )); then
  chunk_dir="${DORIS_STREAM_LOAD_CHUNK_DIR:-/tmp/doris_stream_load_chunks}/${db}/${table}_${label}"
  mkdir -p "$chunk_dir"
  cleanup() { rm -rf "$chunk_dir"; }
  trap cleanup EXIT
  # Split by line boundaries to avoid corrupting records.
  split -C "${chunk_mb}m" -d -a 4 "$DATA_FILE" "$chunk_dir/part_"

  # Load each chunk.
  for part in "$chunk_dir"/part_*; do
    part_suffix="$(basename "$part")"
    part_label="${label}_${part_suffix}"
    resp="$(do_curl "$part_label" "$part")"
    echo "$resp"
    echo "$resp" | grep -Eqi '"status"[[:space:]]*:[[:space:]]*"success"' || {
      echo "[ERROR] Stream load failed for ${db}.${table} (chunk: $part_suffix)" >&2
      exit 1
    }
  done
  exit 0
fi

resp="$(do_curl "$label" "$DATA_FILE")"

echo "$resp"
echo "$resp" | grep -Eqi '"status"[[:space:]]*:[[:space:]]*"success"' || {
  echo "[ERROR] Stream load failed for ${db}.${table}" >&2
  exit 1
}
