#!/usr/bin/env bash

set -e
# 共享函数:gh_api_with_retry / gh_api_write / log_event
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/github-api.sh"
source "$SCRIPT_DIR/git-cli.sh"
source "$SCRIPT_DIR/fork-registry.sh"

# 每 fork 单独 log 文件,避免并发输出错乱
LOG_DIR=$(mktemp -d)
trap 'rm -rf "$LOG_DIR"' EXIT

# 初始化事件文件。前置步骤可能已经写入 workflow 禁用事件,不要覆盖。
: >> "$RUNNER_TEMP/events.jsonl"
: > "$RUNNER_TEMP/summary.jsonl"

# =====================================================================
# 数据来源: 注册表的 pending_batches(每天 8 点 check-updates.sh 生成)
# =====================================================================
REGISTRY=$(registry_read)
PENDING=$(echo "$REGISTRY" | jq -c '.pending_batches // []' 2>/dev/null || echo "[]")
BATCH_COUNT=$(echo "$PENDING" | jq length 2>/dev/null || echo 0)
if [ "$BATCH_COUNT" -eq 0 ]; then
  echo "⏭️  没有待同步的 fork (pending_batches 为空,8 点检测可能没有发现更新)"
  exit 0
fi
TOTAL_PENDING=$(echo "$PENDING" | jq '[.[] | .[]] | length' 2>/dev/null || echo 0)

# 参数校验
if ! printf '%s' "$MAX_PARALLEL" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::max_parallel='$MAX_PARALLEL' 非法,回退到 4"
  MAX_PARALLEL=4
fi
if ! printf '%s' "$SIZE_DROP_THRESHOLD" | grep -Eq '^(0|[0-9]+([.][0-9]+)?)$'; then
  echo "::warning::size_drop_threshold='$SIZE_DROP_THRESHOLD' 非法,回退到 0.10"
  SIZE_DROP_THRESHOLD=0.10
fi
if ! printf '%s' "$MAX_BRANCHES_PER_FORK" | grep -Eq '^(0|[1-9][0-9]*)$'; then
  echo "::warning::max_branches_per_fork='$MAX_BRANCHES_PER_FORK' 非法,回退到 6"
  MAX_BRANCHES_PER_FORK=6
fi
if ! printf '%s' "${SYNC_BATCH_SIZE:-15}" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::sync_batch_size='${SYNC_BATCH_SIZE:-}' 非法,回退到 15"
  SYNC_BATCH_SIZE=15
fi
if ! printf '%s' "${SYNC_RATE_SAFE_THRESHOLD:-300}" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::sync_rate_safe_threshold='${SYNC_RATE_SAFE_THRESHOLD:-}' 非法,回退到 300"
  SYNC_RATE_SAFE_THRESHOLD=300
fi

DISCARD_LOCAL_CHANGES_RAW="${DISCARD_LOCAL_CHANGES:-force}"
DISCARD_LOCAL_CHANGES=$(printf '%s' "$DISCARD_LOCAL_CHANGES_RAW" \
  | sed -E 's/[[:space:]]+#.*$//; s/^ +| +$//g' \
  | tr '[:upper:]' '[:lower:]')
case "$DISCARD_LOCAL_CHANGES" in
  force|keep) ;;
  *)
    echo "::warning::discard_local_changes='$DISCARD_LOCAL_CHANGES_RAW' 非法,回退到 force"
    DISCARD_LOCAL_CHANGES=force
    ;;
esac

echo "🧩 待同步 $TOTAL_PENDING 个 fork, $BATCH_COUNT 批"
echo "🧭 本地分歧处理模式: $DISCARD_LOCAL_CHANGES"
echo "🌿 默认分支同步上限: $MAX_BRANCHES_PER_FORK (0 = 不限制)"

SKIP_LIST=$(gh_api_with_retry "repos/$MY_OWNER/$CONFIG_REPO/contents/skip.txt" \
            --jq '.content // ""' 2>/dev/null \
            | base64 -d 2>/dev/null \
            | sed 's/^ *//;s/ *$//' \
            | grep -v '^#' \
            | grep -v '^$' || true)
export SKIP_LIST

# 单 fork 处理函数 (被 xargs -P 并发调用)
source "$SCRIPT_DIR/fork-worker.sh"
export -f process_fork
export MY_OWNER CONFIG_REPO SIZE_DROP_THRESHOLD SIZE_CHECK_EXEMPT LOG_DIR SYNC_MODE SKIP_LIST DISCARD_LOCAL_CHANGES
export MAX_BRANCHES_PER_FORK SKIP_BRANCH_PATTERNS FULL_BRANCH_SYNC_REPOS BRANCH_LIMIT_GROUPS BRANCH_LIMIT_OVERRIDES
export PROTECTED_SKIP_REPOS BACKUP_THEN_SYNC_REPOS LEGACY_BACKUP_REPO LEGACY_BACKUP_BRANCH_PREFIX DRY_RUN

check_rate_limit() {
  local info
  info=$(gh_api_with_retry "rate_limit" \
    --jq '{remaining: .resources.core.remaining, reset: .resources.core.reset, limit: .resources.core.limit}' 2>/dev/null || echo '{}')
  local remaining reset limit now wait
  remaining=$(echo "$info" | jq -r '.remaining // 9999')
  reset=$(echo "$info" | jq -r '.reset // 0')
  limit=$(echo "$info" | jq -r '.limit // 5000')
  echo "📊 rate limit: $remaining/$limit"
  if [ "$remaining" -le 0 ] 2>/dev/null; then
    now=$(date +%s)
    wait=$((reset - now + 10))
    if [ $wait -gt 0 ] && [ $wait -lt 3700 ]; then
      local reset_human
      reset_human=$(date -d "@$reset" '+%H:%M:%S' 2>/dev/null || date -r "$reset" '+%H:%M:%S')
      echo "  ⏸️  限流,等待 ${wait}s (到 $reset_human UTC)"
      sleep "$wait"
      echo "  ✅ 等待完毕,继续"
    fi
  fi
}
check_rate_limit

get_remaining() {
  gh_api_with_retry "rate_limit" --jq '.resources.core.remaining // 9999' 2>/dev/null || echo 9999
}

# 执行一批 fork 的并发同步,输出该批结果 JSON (从 summary.jsonl 新增行提取)
run_batch() {
  local batch_json="$1" label="$2"
  local batch_count lines_before lines_after results
  batch_count=$(echo "$batch_json" | jq length)
  if [ "$batch_count" -eq 0 ]; then
    echo "[]"
    return 0
  fi
  echo "━━━ $label: $batch_count 个 fork ━━━" >&2
  echo "$batch_json" | jq -r '.[] | "  - \(.repo)"' >&2

  lines_before=$(wc -l < "$RUNNER_TEMP/summary.jsonl" | tr -d ' ')
  echo "$batch_json" | jq -r '.[] | @base64' \
    | xargs -r -P "$MAX_PARALLEL" -I {} bash -c 'process_fork "$1"' _ {} \
    || echo "⚠️ 本批次部分 fork worker 非零退出 (失败已记录到事件日志,不中断)" >&2
  lines_after=$(wc -l < "$RUNNER_TEMP/summary.jsonl" | tr -d ' ')

  if [ "$lines_after" -gt "$lines_before" ]; then
    tail -n +$((lines_before + 1)) "$RUNNER_TEMP/summary.jsonl" | jq -s '.'
  else
    echo "[]"
  fi
}

# =====================================================================
# 主循环: 逐批同步
# =====================================================================
ALL_FAILED_NAMES="[]"     # 短名 (summary.jsonl 的 .name)
PROCESSED_BATCHES=0
QUOTA_STOPPED=false

while [ "$PROCESSED_BATCHES" -lt "$BATCH_COUNT" ]; do
  BATCH_IDX=$((PROCESSED_BATCHES + 1))
  BATCH_JSON=$(echo "$PENDING" | jq -c ".[$((BATCH_IDX - 1))]")
  RESULTS=$(run_batch "$BATCH_JSON" "批次 $BATCH_IDX/$BATCH_COUNT")
  BATCH_FAIL=$(echo "$RESULTS" | jq -c '[.[] | select(.result == "fail") | .name]' 2>/dev/null || echo "[]")
  ALL_FAILED_NAMES=$(echo "$ALL_FAILED_NAMES" | jq -c --argjson f "$BATCH_FAIL" '. + $f | unique')
  PROCESSED_BATCHES=$BATCH_IDX

  # 每批后检查配额 (剩一批以上时)
  if [ "$PROCESSED_BATCHES" -lt "$BATCH_COUNT" ]; then
    remaining=$(get_remaining)
    echo "📊 批次进度: $PROCESSED_BATCHES/$BATCH_COUNT, 剩余配额 $remaining"
    if [ "$remaining" -lt "$SYNC_RATE_SAFE_THRESHOLD" ]; then
      echo "⏸️  剩余配额 $remaining < 安全线 $SYNC_RATE_SAFE_THRESHOLD, 剩余批次留待下次 run"
      QUOTA_STOPPED=true
      break
    fi
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$QUOTA_STOPPED" = "true" ]; then
  echo "⏸️  处理了 $PROCESSED_BATCHES/$BATCH_COUNT 批 (剩余配额不足,提前停止)"
else
  echo "✅ 全部 $BATCH_COUNT 批处理完毕 (并发 $MAX_PARALLEL)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 按原始 fork 顺序输出所有 log
echo "$PENDING" | jq -r '.[][] | .name' | while read -r name; do
  if [ -f "$LOG_DIR/$name.log" ]; then
    cat "$LOG_DIR/$name.log"
  fi
done

# =====================================================================
# 主 run 末尾: 重试失败的 fork 一次 (配额允许时)
# =====================================================================
FAIL_COUNT=$(echo "$ALL_FAILED_NAMES" | jq length)
RETRY_FAIL_FORKS="[]"
if [ "$FAIL_COUNT" -gt 0 ]; then
  ALL_FAILED_FORKS=$(echo "$PENDING" | jq -c --argjson names "$ALL_FAILED_NAMES" \
    '[.[] | .[] | select(.name as $n | ($names | index($n)) != null)] | unique_by(.repo)')
  RETRY_RESULTS=$(run_batch "$ALL_FAILED_FORKS" "主 run 末尾重试")
  RETRY_FAIL_NAMES=$(echo "$RETRY_RESULTS" | jq -c '[.[] | select(.result == "fail") | .name]' 2>/dev/null || echo "[]")
  RETRY_FAIL_FORKS=$(echo "$ALL_FAILED_FORKS" | jq -c --argjson names "$RETRY_FAIL_NAMES" \
    '[.[] | select(.name as $n | ($names | index($n)) != null)]')
  echo "  🔁 重试后仍失败: $(echo "$RETRY_FAIL_FORKS" | jq length) 个"
else
  echo "🎉 本 run 无失败 fork,无需重试"
fi

# =====================================================================
# 写回注册表
# =====================================================================
REMAINING_BATCHES=$(echo "$PENDING" | jq -c --argjson n "$PROCESSED_BATCHES" '.[$n:]')
REMAINING_COUNT=$(echo "$REMAINING_BATCHES" | jq length 2>/dev/null || echo 0)
OLD_RETRY=$(echo "$REGISTRY" | jq -c '.retry_failed // []' 2>/dev/null || echo "[]")

# 本次重试仍失败的 fork → retry_failed 累加 failures
RETRY_ACCUM="$OLD_RETRY"
if [ "$(echo "$RETRY_FAIL_FORKS" | jq length)" -gt 0 ]; then
  while IFS= read -r f; do
    REPO=$(echo "$f" | jq -r '.repo')
    EXIST=$(echo "$RETRY_ACCUM" | jq -c --arg r "$REPO" '[.[] | select(.repo == $r)] | length' 2>/dev/null || echo 0)
    if [ "$EXIST" -gt 0 ]; then
      RETRY_ACCUM=$(echo "$RETRY_ACCUM" | jq -c --arg r "$REPO" \
        'map(if .repo == $r then .failures += 1 else . end)')
    else
      RETRY_ACCUM=$(echo "$RETRY_ACCUM" | jq -c --argjson f "$f" \
        '. + [{repo: $f.repo, name: $f.name, fork_owner: $f.fork_owner,
               fork_default_branch: $f.fork_default_branch, parent_owner: $f.parent_owner,
               parent_name: $f.parent_name, parent_default_branch: $f.parent_default_branch,
               failures: 1, last_error: "主 run 末尾重试后仍失败"}]')
    fi
  done < <(echo "$RETRY_FAIL_FORKS" | jq -c '.[]')
fi

# new → syncable 迁移: 本次成功(is_new 且非 fail)的 fork
SYNCABLE=$(echo "$REGISTRY" | jq -c '.syncable // []')
NEW_LIST=$(echo "$REGISTRY" | jq -c '.new // []')
MIGRATE=$(echo "$PENDING" | jq -c --argjson n "$PROCESSED_BATCHES" --argjson failed "$ALL_FAILED_NAMES" \
  '[.[0:$n][] | .[] | select(.is_new == true) | select(.name as $n2 | ($failed | index($n2)) == null)]' 2>/dev/null || echo "[]")
if [ "$MIGRATE" != "[]" ] && [ -n "$MIGRATE" ]; then
  MIGRATE_COUNT=$(echo "$MIGRATE" | jq length)
  echo "🆕 新 fork 同步成功 $MIGRATE_COUNT 个,移入可同步列表"
  SYNCABLE=$(echo "$SYNCABLE" | jq -c --argjson m "$MIGRATE" '. + $m')
  NEW_LIST=$(echo "$NEW_LIST" | jq -c --argjson m "$MIGRATE" \
    '[.[] | select(.name as $n | ($m | map(.name) | index($n)) == null)]')
fi

NEW_REGISTRY=$(echo "$REGISTRY" | jq -c \
  --argjson remaining "$REMAINING_BATCHES" \
  --argjson retry "$RETRY_ACCUM" \
  --argjson syncable "$SYNCABLE" \
  --argjson new "$NEW_LIST" \
  --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{updated_at: $now, last_full_check_at: .last_full_check_at,
    full_check_interval_days: .full_check_interval_days,
    syncable: $syncable, unsyncable: .unsyncable, new: $new,
    retry_failed: $retry, pending_batches: $remaining}')

echo ""
echo "📦 注册表更新:"
echo "  待同步批次: 剩余 $REMAINING_COUNT 批 (已处理 $PROCESSED_BATCHES/$BATCH_COUNT)"
echo "  多次失败列表: $(echo "$RETRY_ACCUM" | jq length) 个"
registry_write "$NEW_REGISTRY"

# =====================================================================
# 事件/CSV 输出 (保留原逻辑)
# =====================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 结构化事件日志 (events.jsonl)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -f "$RUNNER_TEMP/events.jsonl" ] && [ -s "$RUNNER_TEMP/events.jsonl" ]; then
  cat "$RUNNER_TEMP/events.jsonl"
  echo ""
  EVENT_COUNT=$(wc -l < "$RUNNER_TEMP/events.jsonl" | tr -d ' ')
  echo "📊 共 $EVENT_COUNT 条事件"

  CSV_KEYS="ts fork action result mode run_id upstream default_branch reason context hint api_status api_message api_path fork_kb upstream_kb ratio_pct threshold_pct tag sha upstream_sha branch behind ahead pr new synced failed skipped local_backup status backup_branch legacy_backup_repo legacy_backup_branch total_branches selected_branches branch_limit branch_limit_source skipped_by_pattern skipped_by_limit workflow_id workflow_name workflow_path workflow_state total_workflows disabled_workflows dry_run_workflows kept_workflows already_disabled_workflows failed_workflows"
  echo "$CSV_KEYS" | tr ' ' '\n' | jq -R '.' | jq -rs '@csv' > "$RUNNER_TEMP/events.csv"
  jq -r --arg keys "$CSV_KEYS" '
    . as $event
    | ($keys | split(" ")) as $k
    | [ $k[] | $event[.] // "" ] | @csv
  ' "$RUNNER_TEMP/events.jsonl" >> "$RUNNER_TEMP/events.csv"
  CSV_LINES=$(($(wc -l < "$RUNNER_TEMP/events.csv") - 1))
  echo "📊 CSV 报告: $CSV_LINES 条记录 → $RUNNER_TEMP/events.csv"

  jq -s '
    group_by(.fork) | map({
      (.[0].fork): {
        last_ts: (map(.ts) | max),
        last_run_id: (.[0].run_id),
        last_result: (
          (map(select(.action == "fork_complete")) | last | .result) as $complete_result
          | if $complete_result == "fail" then "fail"
            elif $complete_result == "skip" then "skip"
            elif (any(.result == "fail" or .result == "error")) then "fail"
            elif $complete_result == "ok" then "complete"
            elif $complete_result != null then $complete_result
            else "partial"
            end
        ),
        last_action: (map(.action) | unique | join(",")),
        events: length
      }
    }) | add // {}
  ' "$RUNNER_TEMP/events.jsonl" > "$RUNNER_TEMP/sync-state.json"
  FORK_COUNT=$(jq 'keys | length' "$RUNNER_TEMP/sync-state.json")
  echo "📊 状态文件: $FORK_COUNT 个 fork → $RUNNER_TEMP/sync-state.json"
else
  echo "(无事件,跳过 CSV 生成)"
fi

# =====================================================================
# 退出码: 重试仍失败 → 非 0 让 run 变红; 配额停止不算失败
# =====================================================================
RETRY_FAIL_COUNT=$(echo "$RETRY_FAIL_FORKS" | jq length)
if [ "$RETRY_FAIL_COUNT" -gt 0 ] && [ "$QUOTA_STOPPED" != "true" ]; then
  echo "::error::$RETRY_FAIL_COUNT 个 fork 重试后仍失败 (已记录到多次失败列表)"
  echo "$RETRY_FAIL_FORKS" | jq -r '.[] | "  - \(.repo)"'
  exit 1
fi
echo "ℹ️  同步完成: 处理 $PROCESSED_BATCHES 批, 多次失败 $(echo "$RETRY_ACCUM" | jq length) 个"
exit 0
