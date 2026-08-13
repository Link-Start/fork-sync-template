#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/github-api.sh"

DRIFT_FILE=".drift-state.json"
STATE_BRANCH="workflow-state"
DRIFT_THRESHOLD=3

SYNC_STATE="$RUNNER_TEMP/sync-state.json"
if [ ! -f "$SYNC_STATE" ] || [ ! -s "$SYNC_STATE" ]; then
  echo "⏭️  无 sync-state.json,跳过 drift 检测"
  exit 0
fi

OLD_DRIFT_JSON=$(gh_api_with_retry "repos/$MY_OWNER/$REPO/contents/$DRIFT_FILE?ref=$STATE_BRANCH" 2>/dev/null || echo "")
if [ -n "$OLD_DRIFT_JSON" ] && [ "$OLD_DRIFT_JSON" != "Not Found" ]; then
  OLD_B64=$(echo "$OLD_DRIFT_JSON" | jq -r '.content // ""')
  OLD_SHA=$(echo "$OLD_DRIFT_JSON" | jq -r '.sha // ""')
  if [ -n "$OLD_B64" ]; then
    OLD_STATE=$(echo "$OLD_B64" | base64 -d 2>/dev/null || echo "{}")
  else
    OLD_STATE="{}"
  fi
else
  OLD_STATE="{}"
  OLD_SHA=""
  echo "📄 .drift-state.json 不存在,从空开始"
fi

NEW_STATE=$(jq -s --argjson old "$OLD_STATE" '
  {
    forks: (
      ($old.forks // {}) as $old_forks
      | .[0] as $current
      | $current | keys | map(
          . as $fork
          | $current[$fork].last_result as $result
          | ($old_forks[$fork].consecutive_failures // 0) as $old_cf
          | {
              ($fork): {
                last_result: $result,
                last_ts: $current[$fork].last_ts,
                consecutive_failures: (
                  if $result == "fail" then $old_cf + 1
                  else 0
                  end
                ),
                last_alert_ts: (if $old_forks[$fork].last_alert_ts == null then null else $old_forks[$fork].last_alert_ts end)
              }
            }
        ) | add // {}
    ),
    updated_at: (now | todate)
  }
' "$SYNC_STATE")

echo "📊 drift state 更新后:"
echo "$NEW_STATE" | jq '.forks'

ALERT_FORKS=$(echo "$NEW_STATE" | jq -r --argjson th "$DRIFT_THRESHOLD" \
  '.forks | to_entries | map(select(.value.consecutive_failures >= $th)) | .[].key')
if [ -n "$ALERT_FORKS" ]; then
  ALERT_COUNT=$(printf '%s\n' "$ALERT_FORKS" | grep -c .)
else
  ALERT_COUNT=0
fi

if [ "$ALERT_COUNT" -gt 0 ]; then
  echo "🚨 检测到 $ALERT_COUNT 个 fork 连续失败 ≥ $DRIFT_THRESHOLD 次: $ALERT_FORKS"
  DETAIL=$(echo "$NEW_STATE" | jq -r --argjson th "$DRIFT_THRESHOLD" \
    '.forks | to_entries[] | select(.value.consecutive_failures >= $th) | "- **\(.key)**: 连续失败 \(.value.consecutive_failures) 次 (最后: \(.value.last_ts))"')
  ISSUE_TITLE="🚨 Fork Drift Alert: 连续失败"
  printf -v ISSUE_BODY "以下 fork 连续失败 ≥ %s 次,可能 fork 或 upstream 出问题,请排查:\n\n%s\n\n- 排查方式:查看 Actions log 和 [Artifact](https://github.com/%s/%s/actions/runs/%s)\n- 解决后下次 run 成功会自动清除告警状态" \
    "$DRIFT_THRESHOLD" "$DETAIL" "$MY_OWNER" "$REPO" "$GITHUB_RUN_ID"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[DRY-RUN] 会开 issue: $ISSUE_TITLE"
  else
    NEW_ISSUE=$(gh_api_with_retry -X POST "repos/$MY_OWNER/$REPO/issues" \
      -f title="$ISSUE_TITLE" \
      -f body="$ISSUE_BODY" \
      -f label="drift-alert" 2>/dev/null)
    NEW_NUM=$(echo "$NEW_ISSUE" | jq -r '.number // empty' 2>/dev/null)
    if [ -n "$NEW_NUM" ]; then
      echo "📝 开漂移告警 issue #$NEW_NUM"
      NEW_STATE=$(echo "$NEW_STATE" | jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '.forks |= with_entries(
          if .value.consecutive_failures >= '"$DRIFT_THRESHOLD"' then .value.last_alert_ts = $ts else . end
        )')
    fi
  fi
else
  echo "✅ 无 drift 告警"
fi

if [ "${DRY_RUN:-false}" = "true" ]; then
  echo "[DRY-RUN] 写回 $STATE_BRANCH/$DRIFT_FILE 跳过"
else
  STATE_BRANCH_SHA=$(gh_api_with_retry "repos/$MY_OWNER/$REPO/git/ref/heads/$STATE_BRANCH" \
    --jq '.object.sha // ""' 2>/dev/null || echo "")
  if [ -z "$STATE_BRANCH_SHA" ]; then
    DEFAULT_BRANCH=$(gh_api_with_retry "repos/$MY_OWNER/$REPO" --jq '.default_branch // "main"' 2>/dev/null || echo "main")
    DEFAULT_SHA=$(gh_api_with_retry "repos/$MY_OWNER/$REPO/git/ref/heads/$DEFAULT_BRANCH" \
      --jq '.object.sha // ""' 2>/dev/null || echo "")
    if [ -n "$DEFAULT_SHA" ]; then
      gh_api_write -X POST "repos/$MY_OWNER/$REPO/git/refs" \
        -f ref="refs/heads/$STATE_BRANCH" \
        -f sha="$DEFAULT_SHA" >/dev/null 2>&1 && \
        echo "🌿 已创建状态分支: $STATE_BRANCH ← $DEFAULT_BRANCH" || \
        echo "::warning::状态分支 $STATE_BRANCH 创建失败,后续写回可能失败"
    fi
  fi

  B64_CONTENT=$(echo "$NEW_STATE" | base64 -w 0)
  local body_file="$RUNNER_TEMP/drift-put.json"
  printf '{"message":"chore: update drift state (run %s)","content":"%s","branch":"%s"' \
    "$GITHUB_RUN_ID" "$B64_CONTENT" "$STATE_BRANCH" > "$body_file"
  if [ -n "$OLD_SHA" ]; then
    printf ',"sha":"%s"' "$OLD_SHA" >> "$body_file"
  fi
  printf '}' >> "$body_file"
  local put_out
  put_out=$(gh_api_with_retry -X PUT "repos/$MY_OWNER/$REPO/contents/$DRIFT_FILE" --input "$body_file" 2>&1) && \
    echo "📝 $STATE_BRANCH/$DRIFT_FILE 已更新" || \
    echo "::warning::$STATE_BRANCH/$DRIFT_FILE 写回失败(权限或冲突): $(printf '%s' "$put_out" | head -1)"
fi
