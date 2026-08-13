#!/usr/bin/env bash

# fork 注册表读写工具 (source 进各阶段脚本)
# 状态存 workflow-state 分支的 fork-registry.json
# 结构:
# {
#   "updated_at": "...",
#   "last_full_check_at": "...",           # 14 天全量重检时间
#   "full_check_interval_days": 14,
#   "syncable":  [{"repo","fork_default_branch","parent","parent_default_branch"}],
#   "unsyncable":[{"repo","reason"}],
#   "new":       [{"repo","fork_default_branch","parent","parent_default_branch"}],
#   "retry_failed":[{"repo","failures","last_error"}],
#   "pending_batches": [["owner/repo", ...], ...],   # 每天 8 点检测出的待同步批次
#   "pending_generated_at": "..."
# }

REGISTRY_FILE="fork-registry.json"
REGISTRY_BRANCH="workflow-state"

b64_encode() {
  base64 -w 0 2>/dev/null || base64 | tr -d '\n'
}

# 读注册表,输出 JSON(不存在则 "{}")
registry_read() {
  local raw b64
  raw=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}/contents/$REGISTRY_FILE?ref=$REGISTRY_BRANCH" 2>/dev/null || echo "")
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

# 写回注册表(条件更新,带 sha;分支不存在则创建)
registry_write() {
  local new_state="$1" old_sha branch_sha default_branch default_sha b64
  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[DRY-RUN] 写回 $REGISTRY_BRANCH/$REGISTRY_FILE 跳过"
    return 0
  fi
  old_sha=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}/contents/$REGISTRY_FILE?ref=$REGISTRY_BRANCH" \
            --jq '.sha // ""' 2>/dev/null || echo "")

  branch_sha=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}/git/ref/heads/$REGISTRY_BRANCH" \
               --jq '.object.sha // ""' 2>/dev/null || echo "")
  if [ -z "$branch_sha" ]; then
    default_branch=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}" --jq '.default_branch // "main"' 2>/dev/null || echo "main")
    default_sha=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}/git/ref/heads/$default_branch" \
                  --jq '.object.sha // ""' 2>/dev/null || echo "")
    if [ -n "$default_sha" ]; then
      gh_api_with_retry -X POST "repos/$MY_OWNER/${CONFIG_REPO:-}/git/refs" \
        -f ref="refs/heads/$REGISTRY_BRANCH" -f sha="$default_sha" >/dev/null 2>&1 && \
        echo "🌿 已创建状态分支: $REGISTRY_BRANCH" || \
        echo "::warning::状态分支 $REGISTRY_BRANCH 创建失败"
    fi
  fi

  b64=$(printf '%s' "$new_state" | b64_encode)
  local -a PUT_ARGS
  PUT_ARGS=(-X PUT "repos/$MY_OWNER/${CONFIG_REPO:-}/contents/$REGISTRY_FILE" \
    -f message="chore: update fork registry (run ${GITHUB_RUN_ID:-manual})" \
    -f content="$b64" \
    -f branch="$REGISTRY_BRANCH")
  if [ -n "$old_sha" ]; then
    PUT_ARGS+=(-f sha="$old_sha")
  fi
  if gh_api_with_retry "${PUT_ARGS[@]}" >/dev/null 2>&1; then
    echo "📝 $REGISTRY_BRANCH/$REGISTRY_FILE 已更新"
  else
    echo "::warning::$REGISTRY_BRANCH/$REGISTRY_FILE 写回失败(权限或冲突)"
  fi
}
