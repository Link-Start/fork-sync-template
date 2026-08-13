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

# 读注册表,输出 JSON(不存在则规范化默认结构)
registry_read() {
  local raw b64 content
  raw=$(gh_api_with_retry "repos/$MY_OWNER/${CONFIG_REPO:-}/contents/$REGISTRY_FILE?ref=$REGISTRY_BRANCH" 2>/dev/null || echo "")
  if [ -n "$raw" ] && [ "$raw" != "Not Found" ]; then
    b64=$(echo "$raw" | jq -r '.content // ""')
    if [ -n "$b64" ]; then
      content=$(echo "$b64" | base64 -d 2>/dev/null || echo "{}")
    else
      content="{}"
    fi
  else
    content="{}"
  fi
  echo "$content" | jq -c '{
    updated_at: (.updated_at // ""),
    last_full_check_at: (.last_full_check_at // ""),
    full_check_interval_days: (.full_check_interval_days // 0),
    syncable: (.syncable // []),
    unsyncable: (.unsyncable // []),
    new: (.new // []),
    retry_failed: (.retry_failed // []),
    pending_batches: (.pending_batches // []),
    pending_generated_at: (.pending_generated_at // "")
  }'
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
  # 用文件传 body: content 可能 >128KB,经命令行参数传会报 Argument list too long
  local body_file="$RUNNER_TEMP/fork-registry-put.json"
  printf '{"message":"chore: update fork registry (run %s)","content":"%s","branch":"%s"' \
    "${GITHUB_RUN_ID:-manual}" "$b64" "$REGISTRY_BRANCH" > "$body_file"
  if [ -n "$old_sha" ]; then
    printf ',"sha":"%s"' "$old_sha" >> "$body_file"
  fi
  printf '}' >> "$body_file"
  local put_out
  put_out=$(gh_api_with_retry -X PUT "repos/$MY_OWNER/${CONFIG_REPO:-}/contents/$REGISTRY_FILE" --input "$body_file" 2>&1) && {
    echo "📝 $REGISTRY_BRANCH/$REGISTRY_FILE 已更新"
    return 0
  }
  echo "::warning::$REGISTRY_BRANCH/$REGISTRY_FILE 写回失败(权限或冲突): $(printf '%s' "$put_out" | head -1)"
}
