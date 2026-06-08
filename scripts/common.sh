#!/usr/bin/env bash

log_event() {
  local fork="$1" action="$2" result="$3"
  shift 3
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  local json
  json=$(jq -n -c     --arg ts "$ts"     --arg fork "$fork"     --arg action "$action"     --arg result "$result"     --arg mode "${SYNC_MODE:-auto}"     --arg run_id "${GITHUB_RUN_ID:-local}"     '{ts: $ts, fork: $fork, action: $action, result: $result, mode: $mode, run_id: $run_id}')
  for kv in "$@"; do
    local k="${kv%%=*}"
    local v="${kv#*=}"
    json=$(echo "$json" | jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}')
  done
  echo "$json" >> "${RUNNER_TEMP:-/tmp}/events.jsonl"
}
export -f log_event
