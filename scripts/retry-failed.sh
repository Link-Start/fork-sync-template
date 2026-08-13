#!/usr/bin/env bash

set -e
# 阶段 3: 每天 20 点(UTC 12 点)重试多次失败列表 (retry_failed)
#   - 读注册表 retry_failed, 对每个 fork 重试一次
#   - 成功 → 从列表移除
#   - 失败 → failures+1 保留
#   - 达到告警阈值时输出, 供 webhook / 后续邮件 QQ 微信提醒扩展

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/github-api.sh"
source "$SCRIPT_DIR/git-cli.sh"
source "$SCRIPT_DIR/fork-registry.sh"

LOG_DIR=$(mktemp -d)
trap 'rm -rf "$LOG_DIR"' EXIT
: >> "$RUNNER_TEMP/events.jsonl"
: > "$RUNNER_TEMP/summary.jsonl"

REGISTRY=$(registry_read)
RETRY_LIST=$(echo "$REGISTRY" | jq -c '.retry_failed // []' 2>/dev/null || echo "[]")
RETRY_COUNT=$(echo "$RETRY_LIST" | jq length 2>/dev/null || echo 0)
if [ "$RETRY_COUNT" -eq 0 ]; then
  echo "🎉 多次失败列表为空,无需重试"
  exit 0
fi
echo "🔁 重试 $RETRY_COUNT 个多次失败的 fork"

# 参数校验
if ! printf '%s' "$MAX_PARALLEL" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::max_parallel='$MAX_PARALLEL' 非法,回退到 4"
  MAX_PARALLEL=4
fi
if ! printf '%s' "$SIZE_DROP_THRESHOLD" | grep -Eq '^(0|[0-9]+([.][0-9]+)?)$'; then
  SIZE_DROP_THRESHOLD=0.10
fi
if ! printf '%s' "$MAX_BRANCHES_PER_FORK" | grep -Eq '^(0|[1-9][0-9]*)$'; then
  MAX_BRANCHES_PER_FORK=6
fi
if ! printf '%s' "${RETRY_ALERT_THRESHOLD:-3}" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::retry_alert_threshold='${RETRY_ALERT_THRESHOLD:-}' 非法,回退到 3"
  RETRY_ALERT_THRESHOLD=3
fi

DISCARD_LOCAL_CHANGES_RAW="${DISCARD_LOCAL_CHANGES:-force}"
DISCARD_LOCAL_CHANGES=$(printf '%s' "$DISCARD_LOCAL_CHANGES_RAW" \
  | sed -E 's/[[:space:]]+#.*$//; s/^ +| +$//g' | tr '[:upper:]' '[:lower:]')
case "$DISCARD_LOCAL_CHANGES" in
  force|keep) ;;
  *) DISCARD_LOCAL_CHANGES=force ;;
esac

SKIP_LIST=$(gh_api_with_retry "repos/$MY_OWNER/$CONFIG_REPO/contents/skip.txt" \
            --jq '.content // ""' 2>/dev/null \
            | base64 -d 2>/dev/null \
            | sed 's/^ *//;s/ *$//' | grep -v '^#' | grep -v '^$' || true)
export SKIP_LIST

source "$SCRIPT_DIR/fork-worker.sh"
export -f process_fork
export MY_OWNER CONFIG_REPO SIZE_DROP_THRESHOLD SIZE_CHECK_EXEMPT LOG_DIR SYNC_MODE SKIP_LIST DISCARD_LOCAL_CHANGES
export MAX_BRANCHES_PER_FORK SKIP_BRANCH_PATTERNS FULL_BRANCH_SYNC_REPOS BRANCH_LIMIT_GROUPS BRANCH_LIMIT_OVERRIDES
export PROTECTED_SKIP_REPOS BACKUP_THEN_SYNC_REPOS LEGACY_BACKUP_REPO LEGACY_BACKUP_BRANCH_PREFIX DRY_RUN

# retry_failed 条目缺 fork 完整信息时补全 (fork_owner 等); 无法补全的跳过
BUILD="[]"
while IFS= read -r item; do
  [ -z "$item" ] && continue
  OWNER=$(echo "$item" | jq -r '.fork_owner // ""')
  if [ -z "$OWNER" ]; then
    REPO=$(echo "$item" | jq -r '.repo')
    PARENT_O=$(echo "$item" | jq -r '.parent_owner // ""')
    PARENT_N=$(echo "$item" | jq -r '.parent_name // ""')
    PARENT_D=$(echo "$item" | jq -r '.parent_default_branch // ""')
    FORK_D=$(echo "$item" | jq -r '.fork_default_branch // "main"')
    if [ -z "$PARENT_N" ]; then
      echo "  ⚠️ $REPO 缺少 upstream 信息,无法重试,跳过"
      continue
    fi
    item=$(echo "$item" | jq -c --arg o "$MY_OWNER" --arg pd "$PARENT_D" --arg fd "$FORK_D" \
      '. + {fork_owner: $o, fork_default_branch: $fd, parent_default_branch: $pd, name: (.repo | split("/")[1])}')
  fi
  BUILD=$(echo "$BUILD" | jq -c --argjson i "$item" '. + [$i]')
done < <(echo "$RETRY_LIST" | jq -c '.[]')
RETRY_FORKS="$BUILD"
ACTUAL_COUNT=$(echo "$RETRY_FORKS" | jq length)
if [ "$ACTUAL_COUNT" -eq 0 ]; then
  echo "⏭️  没有可重试的 fork"
  exit 0
fi

echo "━━━ 重试 $ACTUAL_COUNT 个 fork ━━━"
echo "$RETRY_FORKS" | jq -r '.[] | "  - \(.repo) (已失败 \(.failures) 次)"'

lines_before=$(wc -l < "$RUNNER_TEMP/summary.jsonl" | tr -d ' ')
echo "$RETRY_FORKS" | jq -r '.[] | @base64' \
  | xargs -r -P "$MAX_PARALLEL" -I {} bash -c 'process_fork "$1"' _ {} \
  || echo "⚠️ 部分 worker 非零退出 (已记录到事件日志)"

RESULTS=$(tail -n +$((lines_before + 1)) "$RUNNER_TEMP/summary.jsonl" 2>/dev/null | jq -s '.' 2>/dev/null || echo "[]")
echo "$RESULTS" | jq -r '.[] | "  📊 \(.name): \(.result)"' 2>/dev/null || true

STILL_FAIL=$(echo "$RESULTS" | jq -c '[.[] | select(.result == "fail") | .name]' 2>/dev/null || echo "[]")
STILL_FAIL_COUNT=$(echo "$STILL_FAIL" | jq length)
SUCCESS_COUNT=$((ACTUAL_COUNT - STILL_FAIL_COUNT))

# 更新注册表: 成功移除, 失败 failures+1
NEW_RETRY="[]"
if [ "$STILL_FAIL_COUNT" -gt 0 ]; then
  NEW_RETRY=$(echo "$RETRY_FORKS" | jq -c --argjson names "$STILL_FAIL" \
    '[.[] | select(.name as $n | ($names | index($n)) != null) | . + {failures: ((.failures // 1) + 1)}]')
fi

ALERT_ITEMS=$(echo "$NEW_RETRY" | jq -c --argjson t "$RETRY_ALERT_THRESHOLD" \
  '[.[] | select(.failures >= $t)]')
ALERT_COUNT=$(echo "$ALERT_ITEMS" | jq length)

NEW_REGISTRY=$(echo "$REGISTRY" | jq -c --argjson retry "$NEW_RETRY" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{updated_at: $now, last_full_check_at: .last_full_check_at, full_check_interval_days: .full_check_interval_days,
    syncable: .syncable, unsyncable: .unsyncable, new: .new, retry_failed: $retry, pending_batches: .pending_batches}')

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔁 重试结果: 成功 $SUCCESS_COUNT, 仍失败 $STILL_FAIL_COUNT"
if [ "$ALERT_COUNT" -gt 0 ]; then
  echo "🚨 达到告警阈值 (≥$RETRY_ALERT_THRESHOLD 次失败) 的 fork $ALERT_COUNT 个:"
  echo "$ALERT_ITEMS" | jq -r '.[] | "  - \(.repo): 失败 \(.failures) 次"'
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

registry_write "$NEW_REGISTRY"

# 输出告警 JSON 供后续 webhook 通知步骤读取 (可扩展邮件/QQ/微信)
if [ "$ALERT_COUNT" -gt 0 ]; then
  echo "$ALERT_ITEMS" > "$RUNNER_TEMP/retry-alert.json"
  echo "📝 告警列表已写 $RUNNER_TEMP/retry-alert.json"
fi

echo ""
echo "📋 结构化事件日志:"
if [ -f "$RUNNER_TEMP/events.jsonl" ] && [ -s "$RUNNER_TEMP/events.jsonl" ]; then
  cat "$RUNNER_TEMP/events.jsonl"
fi

if [ "$STILL_FAIL_COUNT" -gt 0 ] && [ "$ALERT_COUNT" -gt 0 ]; then
  echo "::error::$STILL_FAIL_COUNT 个 fork 重试后仍失败"
  exit 1
fi
exit 0
