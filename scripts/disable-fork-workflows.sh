#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/github-api.sh"

EVENTS_FILE="${RUNNER_TEMP:-/tmp}/events.jsonl"
: >> "$EVENTS_FILE"

trim() {
  sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
}

normalize_bool() {
  local raw
  raw=$(printf '%s' "${1:-false}" | trim | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    true|1|yes|y|on) printf '%s' "true" ;;
    *) printf '%s' "false" ;;
  esac
}

repo_selector_matches() {
  local selectors="$1" fork_owner="$2" fork_name="$3"
  local selector selector_lc owner_lc repo_lc full_lc

  owner_lc=$(printf '%s' "$fork_owner" | tr '[:upper:]' '[:lower:]')
  repo_lc=$(printf '%s' "$fork_name" | tr '[:upper:]' '[:lower:]')
  full_lc="$owner_lc/$repo_lc"

  while IFS= read -r selector; do
    selector=$(printf '%s' "$selector" | trim)
    [ -z "$selector" ] && continue
    selector_lc=$(printf '%s' "$selector" | tr '[:upper:]' '[:lower:]')
    case "$selector_lc" in
      all) return 0 ;;
      */*) [ "$selector_lc" = "$full_lc" ] && return 0 ;;
      *) [ "$selector_lc" = "$repo_lc" ] && return 0 ;;
    esac
  done < <(printf '%s\n' "$selectors" | tr ',' '\n')

  return 1
}

repo_selector_explicitly_matches() {
  local selectors="$1" fork_owner="$2" fork_name="$3"
  local selector selector_lc owner_lc repo_lc full_lc

  owner_lc=$(printf '%s' "$fork_owner" | tr '[:upper:]' '[:lower:]')
  repo_lc=$(printf '%s' "$fork_name" | tr '[:upper:]' '[:lower:]')
  full_lc="$owner_lc/$repo_lc"

  while IFS= read -r selector; do
    selector=$(printf '%s' "$selector" | trim)
    [ -z "$selector" ] && continue
    selector_lc=$(printf '%s' "$selector" | tr '[:upper:]' '[:lower:]')
    [ "$selector_lc" = "all" ] && continue
    case "$selector_lc" in
      */*) [ "$selector_lc" = "$full_lc" ] && return 0 ;;
      *) [ "$selector_lc" = "$repo_lc" ] && return 0 ;;
    esac
  done < <(printf '%s\n' "$selectors" | tr ',' '\n')

  return 1
}

is_current_config_repo() {
  local fork_owner="$1" fork_name="$2" owner_lc repo_lc config_owner_lc config_repo_lc
  [ -z "${CONFIG_REPO:-}" ] && return 1

  owner_lc=$(printf '%s' "$fork_owner" | tr '[:upper:]' '[:lower:]')
  repo_lc=$(printf '%s' "$fork_name" | tr '[:upper:]' '[:lower:]')
  config_owner_lc=$(printf '%s' "${MY_OWNER:-}" | tr '[:upper:]' '[:lower:]')
  config_repo_lc=$(printf '%s' "$CONFIG_REPO" | tr '[:upper:]' '[:lower:]')

  [ "$owner_lc" = "$config_owner_lc" ] && [ "$repo_lc" = "$config_repo_lc" ]
}

value_matches_glob_list() {
  local value="$1" patterns="$2"
  local pattern
  [ -z "$patterns" ] && return 1

  shopt -s nocasematch
  while IFS= read -r pattern; do
    pattern=$(printf '%s' "$pattern" | trim)
    [ -z "$pattern" ] && continue
    if [[ "$value" == $pattern ]]; then
      shopt -u nocasematch
      return 0
    fi
  done < <(printf '%s\n' "$patterns" | tr ',' '\n')
  shopt -u nocasematch

  return 1
}

workflow_kept_by_pattern() {
  local name="$1" path="$2" patterns="$3" basename
  basename="${path##*/}"

  value_matches_glob_list "$name" "$patterns" || \
    value_matches_glob_list "$path" "$patterns" || \
    value_matches_glob_list "$basename" "$patterns"
}

disable_workflows_for_fork() {
  local fork_json="$1" fork_owner fork_name fork_full
  local workflows workflows_err workflows_api workflow
  local total=0 disabled=0 dry_run=0 kept=0 already_disabled=0 failed=0

  fork_owner=$(echo "$fork_json" | jq -r '.fork_owner // empty')
  fork_name=$(echo "$fork_json" | jq -r '.name // empty')
  [ -z "$fork_owner" ] && return 0
  [ -z "$fork_name" ] && return 0
  fork_full="$fork_owner/$fork_name"

  if ! repo_selector_matches "$DISABLE_FORK_WORKFLOWS_REPOS" "$fork_owner" "$fork_name"; then
    return 0
  fi

  if is_current_config_repo "$fork_owner" "$fork_name" && \
     ! repo_selector_explicitly_matches "$DISABLE_FORK_WORKFLOWS_REPOS" "$fork_owner" "$fork_name"; then
    echo "🧯 跳过当前配置仓库 workflows: $fork_full (all 不默认禁用自身;如确实需要请显式列出仓库名)"
    log_event "$fork_name" "disable_workflows" "skip" reason="config_repo_self_protection"
    return 0
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🧯 禁用 fork workflows: $fork_full"

  workflows_api="repos/$fork_owner/$fork_name/actions/workflows?per_page=100"
  if ! gh_api_capture workflows workflows_err --paginate "$workflows_api" \
       --jq '.workflows[] | {id: .id, name: .name, path: .path, state: .state}'; then
    echo "  ❌ 读取 workflows 失败: $(api_error_message "$workflows_err")"
    log_event "$fork_name" "disable_workflows" "fail" \
      reason="读取 workflows 失败" api_path="$workflows_api" \
      api_status="$(api_error_field "$workflows_err" "status")" \
      api_message="$(api_error_message "$workflows_err")"
    return 0
  fi

  if [ -z "$workflows" ]; then
    echo "  📭 没有 workflows"
    log_event "$fork_name" "disable_workflows_complete" "ok" total_workflows="0" disabled_workflows="0"
    return 0
  fi

  while IFS= read -r workflow; do
    local id name path state disable_api disable_out disable_err
    [ -z "$workflow" ] && continue
    id=$(echo "$workflow" | jq -r '.id')
    name=$(echo "$workflow" | jq -r '.name // ""')
    path=$(echo "$workflow" | jq -r '.path // ""')
    state=$(echo "$workflow" | jq -r '.state // ""')
    total=$((total + 1))

    if workflow_kept_by_pattern "$name" "$path" "$DISABLE_FORK_WORKFLOWS_KEEP_PATTERNS"; then
      kept=$((kept + 1))
      echo "  🟦 保留: $name ($path, state=$state)"
      log_event "$fork_name" "disable_workflow" "skip" \
        reason="keep_pattern" workflow_id="$id" workflow_name="$name" \
        workflow_path="$path" workflow_state="$state"
      continue
    fi

    if [ "$state" != "active" ]; then
      already_disabled=$((already_disabled + 1))
      echo "  ⏭️ 已非 active,跳过: $name ($path, state=$state)"
      log_event "$fork_name" "disable_workflow" "skip" \
        reason="already_not_active" workflow_id="$id" workflow_name="$name" \
        workflow_path="$path" workflow_state="$state"
      continue
    fi

    if [ "${DRY_RUN:-false}" = "true" ]; then
      dry_run=$((dry_run + 1))
      echo "  [DRY-RUN] 会禁用: $name ($path)"
      log_event "$fork_name" "disable_workflow" "dry_run" \
        workflow_id="$id" workflow_name="$name" workflow_path="$path" workflow_state="$state"
      continue
    fi

    disable_api="repos/$fork_owner/$fork_name/actions/workflows/$id/disable"
    if gh_api_write_capture disable_out disable_err -X PUT "$disable_api" >/dev/null; then
      disabled=$((disabled + 1))
      echo "  ✅ 已禁用: $name ($path)"
      log_event "$fork_name" "disable_workflow" "ok" \
        workflow_id="$id" workflow_name="$name" workflow_path="$path" workflow_state="$state"
    else
      failed=$((failed + 1))
      echo "  ❌ 禁用失败: $name ($path) - $(api_error_message "$disable_err")"
      log_event "$fork_name" "disable_workflow" "fail" \
        workflow_id="$id" workflow_name="$name" workflow_path="$path" workflow_state="$state" \
        api_path="$disable_api" api_status="$(api_error_field "$disable_err" "status")" \
        api_message="$(api_error_message "$disable_err")"
    fi
  done <<< "$workflows"

  if [ "$failed" -gt 0 ]; then
    log_event "$fork_name" "disable_workflows_complete" "fail" \
      total_workflows="$total" disabled_workflows="$disabled" dry_run_workflows="$dry_run" \
      kept_workflows="$kept" already_disabled_workflows="$already_disabled" failed_workflows="$failed"
  else
    log_event "$fork_name" "disable_workflows_complete" "ok" \
      total_workflows="$total" disabled_workflows="$disabled" dry_run_workflows="$dry_run" \
      kept_workflows="$kept" already_disabled_workflows="$already_disabled" failed_workflows="0"
  fi

  echo "  📊 workflows: total=$total disabled=$disabled dry_run=$dry_run kept=$kept already_disabled=$already_disabled failed=$failed"
}

DISABLE_FORK_WORKFLOWS=$(normalize_bool "${DISABLE_FORK_WORKFLOWS:-false}")
DISABLE_FORK_WORKFLOWS_REPOS="${DISABLE_FORK_WORKFLOWS_REPOS:-}"
DISABLE_FORK_WORKFLOWS_KEEP_PATTERNS="${DISABLE_FORK_WORKFLOWS_KEEP_PATTERNS:-}"

if [ "$DISABLE_FORK_WORKFLOWS" = "true" ] && [ -z "$DISABLE_FORK_WORKFLOWS_REPOS" ]; then
  DISABLE_FORK_WORKFLOWS_REPOS="all"
fi

if [ -z "$DISABLE_FORK_WORKFLOWS_REPOS" ]; then
  echo "🧯 fork workflow 禁用未开启 (disable_fork_workflows_repos 为空)"
  exit 0
fi

if ! echo "${FORKS:-}" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "::error::Discover forks 输出不是 JSON array,无法禁用 fork workflows"
  exit 1
fi

FORK_COUNT=$(echo "$FORKS" | jq length)
if [ "$FORK_COUNT" -eq 0 ]; then
  echo "🧯 没有 fork 待处理,跳过 workflow 禁用"
  exit 0
fi

echo "🧯 fork workflow 禁用已开启"
echo "  targets: $DISABLE_FORK_WORKFLOWS_REPOS"
echo "  keep patterns: ${DISABLE_FORK_WORKFLOWS_KEEP_PATTERNS:-<none>}"
echo "  dry_run: ${DRY_RUN:-false}"

while IFS= read -r fork_json; do
  disable_workflows_for_fork "$fork_json"
done < <(echo "$FORKS" | jq -c '.[]')
