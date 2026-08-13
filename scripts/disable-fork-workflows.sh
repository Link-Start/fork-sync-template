#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/github-api.sh"

EVENTS_FILE="${RUNNER_TEMP:-/tmp}/events.jsonl"
: >> "$EVENTS_FILE"

# 探测状态缓存 (Item 1/2/3):
#   - 已探测且 all_disabled 的 fork 在 TTL 内跳过重新探测 (避免每次全量列 workflows)
#   - 超过 TTL (默认 14 天) 或配置变更或新 fork 强制重新探测
#   - 状态存 workflow-state 分支的 workflow-disable-state.json
STATE_FILE="workflow-disable-state.json"
STATE_BRANCH="workflow-state"
STATE_ACCUM="$RUNNER_TEMP/wf_disable_state.jsonl"
: > "$STATE_ACCUM"
TTL_DAYS=$(printf '%s' "${WORKFLOW_DISABLE_TTL_DAYS:-14}" | tr -d '[:space:]')
if ! printf '%s' "$TTL_DAYS" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::workflow_disable_ttl_days='$TTL_DAYS' 非法,回退到 14"
  TTL_DAYS=14
fi
CONFIG_HASH=$(printf '%s|%s' \
  "${DISABLE_FORK_WORKFLOWS_REPOS:-}" \
  "${DISABLE_FORK_WORKFLOWS_KEEP_PATTERNS:-}" | cksum | awk '{print $1}')

iso_to_epoch() {
  local ts="$1"
  date -d "$ts" +%s 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
    || echo 0
}

b64_encode() {
  base64 -w 0 2>/dev/null || base64 | tr -d '\n'
}

read_old_disable_state() {
  local raw b64
  raw=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}/contents/$STATE_FILE?ref=$STATE_BRANCH" 2>/dev/null || echo "")
  if [ -n "$raw" ] && [ "$raw" != "Not Found" ]; then
    b64=$(echo "$raw" | jq -r '.content // ""')
    if [ -n "$b64" ]; then
      echo "$b64" | base64 -d 2>/dev/null || echo "{}"
    else
      echo "{}"
    fi
  else
    echo "{}"
  fi
}

OLD_STATE=$(read_old_disable_state)
OLD_STATE_SHA=""
OLD_STATE_RAW=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}/contents/$STATE_FILE?ref=$STATE_BRANCH" 2>/dev/null || echo "")
if [ -n "$OLD_STATE_RAW" ] && [ "$OLD_STATE_RAW" != "Not Found" ]; then
  OLD_STATE_SHA=$(echo "$OLD_STATE_RAW" | jq -r '.sha // ""')
fi
OLD_CONFIG_HASH=$(echo "$OLD_STATE" | jq -r '.config_hash // ""' 2>/dev/null || echo "")
OLD_FORK_LIST=$(echo "$OLD_STATE" | jq -c '.fork_list // []' 2>/dev/null || echo "[]")

# 判断该 fork 是否可跳过重新探测 (缓存命中)
# 条件: 非新 fork + 配置哈希一致 + 上次 all_disabled + 距上次探测在 TTL 内
cache_hit_for_fork() {
  local fork_owner="$1" fork_name="$2" is_new="$3" fork_full
  local entry last_probed last_epoch now_epoch ttl_epoch all_disabled

  [ "$is_new" = "true" ] && return 1
  [ "$OLD_CONFIG_HASH" != "$CONFIG_HASH" ] && return 1
  [ -z "$OLD_CONFIG_HASH" ] && return 1

  fork_full="$fork_owner/$fork_name"
  entry=$(echo "$OLD_STATE" | jq -c --arg k "$fork_name" '.forks[$k] // empty' 2>/dev/null || echo "")
  [ -z "$entry" ] && return 1

  all_disabled=$(echo "$entry" | jq -r '.all_disabled // false' 2>/dev/null || echo "false")
  [ "$all_disabled" != "true" ] && return 1

  last_probed=$(echo "$entry" | jq -r '.last_probed_at // ""' 2>/dev/null || echo "")
  [ -z "$last_probed" ] && return 1

  last_epoch=$(iso_to_epoch "$last_probed")
  now_epoch=$(date +%s)
  ttl_epoch=$((TTL_DAYS * 86400))
  [ $((now_epoch - last_epoch)) -lt "$ttl_epoch" ]
}

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

  # 缓存命中: TTL 内已全量禁用过,跳过重新探测
  local IS_NEW
  IS_NEW=$(echo "$fork_json" | jq -r '.is_new // false' 2>/dev/null || echo "false")
  if cache_hit_for_fork "$fork_owner" "$fork_name" "$IS_NEW"; then
    echo "🟦 缓存命中,跳过重新探测: $fork_full (上次 ${TTL_DAYS} 天内已全量禁用)"
    log_event "$fork_name" "disable_workflows" "skip" reason="cache_hit_within_ttl" ttl_days="$TTL_DAYS"
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
    jq -n -c \
      --arg name "$fork_name" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson all_disabled false \
      --argjson total 0 --argjson disabled 0 --argjson kept 0 --argjson already 0 \
      '{name: $name, last_probed_at: $ts, all_disabled: $all_disabled, total_workflows: $total, disabled_workflows: $disabled, kept_workflows: $kept, already_disabled_workflows: $already}' \
      >> "$STATE_ACCUM"
    return 0
  fi

  if [ -z "$workflows" ]; then
    echo "  📭 没有 workflows"
    log_event "$fork_name" "disable_workflows_complete" "ok" total_workflows="0" disabled_workflows="0"
    jq -n -c \
      --arg name "$fork_name" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson all_disabled true \
      --argjson total 0 --argjson disabled 0 --argjson kept 0 --argjson already 0 \
      '{name: $name, last_probed_at: $ts, all_disabled: $all_disabled, total_workflows: $total, disabled_workflows: $disabled, kept_workflows: $kept, already_disabled_workflows: $already}' \
      >> "$STATE_ACCUM"
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

  # 记录本次探测结果,供下次 TTL 缓存使用
  # all_disabled = 本次探测成功且没有 active workflow 残留 (failed=0 且 kept=0 或 kept 之外都处理完)
  # failed>0 时记为 false,下次重新探测
  local ALL_DISABLED=false
  if [ "$failed" -eq 0 ]; then
    ALL_DISABLED=true
  fi
  jq -n -c \
    --arg name "$fork_name" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson all_disabled "$ALL_DISABLED" \
    --argjson total "$total" \
    --argjson disabled "$disabled" \
    --argjson kept "$kept" \
    --argjson already "$already_disabled" \
    '{name: $name, last_probed_at: $ts, all_disabled: $all_disabled, total_workflows: $total, disabled_workflows: $disabled, kept_workflows: $kept, already_disabled_workflows: $already}' \
    >> "$STATE_ACCUM"
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

# 大 JSON 通过文件传递 (env 单变量限 ~128KB,455 个 fork 会 Argument list too long)
if [ -n "${FORKS_FILE:-}" ] && [ -f "$FORKS_FILE" ] && [ -z "${FORKS:-}" ]; then
  FORKS=$(cat "$FORKS_FILE")
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

# =====================================================================
# 写回探测状态 (workflow-state 分支 / workflow-disable-state.json)
# 结构: {config_hash, updated_at, fork_list, forks: {name: {...}}}
#   - config_hash 变化时全部 fork 强制重新探测 (config 驱动)
#   - 保留旧状态里本次未探测的 fork (缓存命中项), 合并本次结果
# =====================================================================
NEW_ACCUM="{}"
if [ -s "$STATE_ACCUM" ]; then
  NEW_ACCUM=$(jq -s 'map({key: .name, value: .}) | from_entries' "$STATE_ACCUM")
fi

MERGE_ARGS=(-n -c \
  --arg config_hash "$CONFIG_HASH" \
  --arg updated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)")
if [ -n "$OLD_STATE" ] && [ "$OLD_STATE" != "{}" ]; then
  MERGE_ARGS+=(--argjson old_forks "$(echo "$OLD_STATE" | jq '.forks // {}')")
else
  MERGE_ARGS+=(--argjson old_forks '{}')
fi
if [ "$NEW_ACCUM" != "{}" ]; then
  MERGE_ARGS+=(--argjson new_forks "$NEW_ACCUM")
else
  MERGE_ARGS+=(--argjson new_forks '{}')
fi

# 合并策略: 新结果覆盖旧结果;本次未处理的 fork 保留旧状态
NEW_STATE=$(jq "${MERGE_ARGS[@]}" \
  '{config_hash: $config_hash, updated_at: $updated_at, forks: ($old_forks + $new_forks)}')

echo "📦 workflow-disable 状态合并完成:"
echo "$NEW_STATE" | jq '{config_hash, updated_at, fork_count: (.forks | length), all_disabled_count: ([.forks[] | select(.all_disabled == true)] | length)}'

if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "[DRY-RUN] 写回 $STATE_BRANCH/$STATE_FILE 跳过"
else
  # 确保状态分支存在
  STATE_BRANCH_SHA=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}/git/ref/heads/$STATE_BRANCH" \
    --jq '.object.sha // ""' 2>/dev/null || echo "")
  if [ -z "$STATE_BRANCH_SHA" ]; then
    DEFAULT_BRANCH=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}" --jq '.default_branch // "main"' 2>/dev/null || echo "main")
    DEFAULT_SHA=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}/git/ref/heads/$DEFAULT_BRANCH" \
      --jq '.object.sha // ""' 2>/dev/null || echo "")
    if [ -n "$DEFAULT_SHA" ]; then
      gh_api_write -X POST "repos/$MY_OWNER/${CONFIG_REPO:-}/git/refs" \
        -f ref="refs/heads/$STATE_BRANCH" \
        -f sha="$DEFAULT_SHA" >/dev/null 2>&1 && \
        echo "🌿 已创建状态分支: $STATE_BRANCH ← $DEFAULT_BRANCH" || \
        echo "::warning::状态分支 $STATE_BRANCH 创建失败,后续写回可能失败"
    fi
  fi

  B64_CONTENT=$(echo "$NEW_STATE" | b64_encode)
  body_file="$RUNNER_TEMP/wf-disable-put.json"
  printf '{"message":"chore: update workflow disable state (run %s)","content":"%s","branch":"%s"' \
    "${GITHUB_RUN_ID:-manual}" "$B64_CONTENT" "$STATE_BRANCH" > "$body_file"
  if [ -n "$OLD_STATE_SHA" ]; then
    printf ',"sha":"%s"' "$OLD_STATE_SHA" >> "$body_file"
  fi
  printf '}' >> "$body_file"
  gh_api_with_retry -X PUT "repos/$MY_OWNER/${CONFIG_REPO:-}/contents/$STATE_FILE" --input "$body_file" >/dev/null 2>&1 && \
    echo "📝 $STATE_BRANCH/$STATE_FILE 已更新" || \
    echo "::warning::$STATE_BRANCH/$STATE_FILE 写回失败(权限或冲突)"
fi
