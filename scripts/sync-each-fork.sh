#!/usr/bin/env bash

set -e
# 共享函数:gh_api_with_retry / gh_api_write / log_event
# (每个 step 是独立 bash 调用,函数不跨 step 共享,必须 source)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/github-api.sh"
source "$SCRIPT_DIR/git-cli.sh"

# 每 fork 单独 log 文件,避免并发输出错乱
LOG_DIR=$(mktemp -d)
trap 'rm -rf "$LOG_DIR"' EXIT

# 初始化事件文件。前置步骤可能已经写入 workflow 禁用事件,不要覆盖。
: >> "$RUNNER_TEMP/events.jsonl"
: > "$RUNNER_TEMP/summary.jsonl"

# 大 JSON 通过文件传递 (env 单变量限 ~128KB,455 个 fork 会 Argument list too long)
if [ -n "${FORKS_FILE:-}" ] && [ -f "$FORKS_FILE" ] && [ -z "${FORKS:-}" ]; then
  FORKS=$(cat "$FORKS_FILE")
fi

if ! echo "$FORKS" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "::error::Discover forks 输出不是 JSON array"
  exit 1
fi
FORK_COUNT=$(echo "$FORKS" | jq length)
if [ "$FORK_COUNT" -eq 0 ]; then
  echo "⏭️  没有 fork 待同步"
  exit 0
fi
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
# 每个调用重定向输出到独立 log 文件,最后按原顺序拼接
# 单 fork worker 函数放在独立脚本里,避免 workflow YAML 继续膨胀。
source "$SCRIPT_DIR/fork-worker.sh"
export -f process_fork
export MY_OWNER CONFIG_REPO SIZE_DROP_THRESHOLD SIZE_CHECK_EXEMPT LOG_DIR SYNC_MODE SKIP_LIST DISCARD_LOCAL_CHANGES
export MAX_BRANCHES_PER_FORK SKIP_BRANCH_PATTERNS FULL_BRANCH_SYNC_REPOS BRANCH_LIMIT_GROUPS BRANCH_LIMIT_OVERRIDES
export PROTECTED_SKIP_REPOS BACKUP_THEN_SYNC_REPOS LEGACY_BACKUP_REPO LEGACY_BACKUP_BRANCH_PREFIX DRY_RUN

# 配额护栏参数 (方案4: 分批同步,每批达到限流极限又不超)
#   SYNC_BATCH_SIZE           每批处理的 fork 数 (默认 15,约 150 次 API 调用/批)
#   SYNC_RATE_SAFE_THRESHOLD  剩余配额安全线,低于此值停止本次,剩余 fork 下次 run 补上
#                             避免跨窗口 sleep 等待烧掉 GitHub Actions 分钟数
if ! printf '%s' "${SYNC_BATCH_SIZE:-15}" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::sync_batch_size='${SYNC_BATCH_SIZE:-}' 非法,回退到 15"
  SYNC_BATCH_SIZE=15
fi
if ! printf '%s' "${SYNC_RATE_SAFE_THRESHOLD:-300}" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::sync_rate_safe_threshold='${SYNC_RATE_SAFE_THRESHOLD:-}' 非法,回退到 300"
  SYNC_RATE_SAFE_THRESHOLD=300
fi

# API 限流检查:剩余配额 = 0 时睡到 reset
# 一次只查一次 (在 xargs 启动前),各 fork 不再重复查
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

# 读取剩余配额 (rate_limit 端点不消耗配额)
get_remaining() {
  gh_api_with_retry "rate_limit" --jq '.resources.core.remaining // 9999' 2>/dev/null || echo 9999
}

# 分批并发处理:每批之间检查配额,低于安全线则优雅停止 (方案4)
# 已处理的 fork 幂等 (下次 run compare 结果为 identical 即跳过),无需跨 run 状态
echo "🧩 分批同步: 每批 $SYNC_BATCH_SIZE 个,安全线 $SYNC_RATE_SAFE_THRESHOLD 配额"
FORK_B64=()
while IFS= read -r line; do
  FORK_B64+=("$line")
done < <(echo "$FORKS" | jq -r '.[] | @base64')
TOTAL_FORKS=${#FORK_B64[@]}
PROCESSED=0
QUOTA_STOPPED=false

while [ "$PROCESSED" -lt "$TOTAL_FORKS" ]; do
  BATCH_END=$((PROCESSED + SYNC_BATCH_SIZE))
  [ "$BATCH_END" -gt "$TOTAL_FORKS" ] && BATCH_END=$TOTAL_FORKS
  for i in $(seq $((PROCESSED + 1)) "$BATCH_END"); do
    printf '%s\n' "${FORK_B64[$((i - 1))]}"
  done | xargs -r -P "$MAX_PARALLEL" -I {} bash -c 'process_fork "$1"' _ {} \
    || echo "⚠️ 本批次部分 fork worker 非零退出 (失败已记录到事件日志,不中断)"
  PROCESSED=$BATCH_END

  if [ "$PROCESSED" -lt "$TOTAL_FORKS" ]; then
    remaining=$(get_remaining)
    echo "📊 批次进度: $PROCESSED/$TOTAL_FORKS,剩余配额 $remaining"
    if [ "$remaining" -lt "$SYNC_RATE_SAFE_THRESHOLD" ]; then
      echo "⏸️  剩余配额 $remaining < 安全线 $SYNC_RATE_SAFE_THRESHOLD,剩余 $((TOTAL_FORKS - PROCESSED)) 个 fork 留待下次 run 同步"
      QUOTA_STOPPED=true
      break
    fi
  fi
done

# 按原始 fork 顺序输出所有 log
echo "$FORKS" | jq -r '.[].name' | while read -r name; do
  if [ -f "$LOG_DIR/$name.log" ]; then
    cat "$LOG_DIR/$name.log"
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$QUOTA_STOPPED" = "true" ]; then
  echo "⏸️  本次处理 $PROCESSED/$TOTAL_FORKS 个 fork (剩余配额不足,提前停止)"
else
  echo "✅ 全部 $TOTAL_FORKS 个 fork 处理完毕 (并发 $MAX_PARALLEL)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

# 把结构化 events 输出到主 log (Item 11),方便不下载 artifact 也能看到
# 同时生成 CSV 报告 (Item 12),用 actions/upload-artifact 上传留档
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📋 结构化事件日志 (events.jsonl)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ -f "$RUNNER_TEMP/events.jsonl" ] && [ -s "$RUNNER_TEMP/events.jsonl" ]; then
  cat "$RUNNER_TEMP/events.jsonl"
  echo ""
  EVENT_COUNT=$(wc -l < "$RUNNER_TEMP/events.jsonl" | tr -d ' ')
  echo "📊 共 $EVENT_COUNT 条事件"

  # 生成 CSV 报告 (Item 12)
  # 预定义所有 log_event 调用的 k=v 字段,缺则空
  CSV_KEYS="ts fork action result mode run_id upstream default_branch reason context hint api_status api_message api_path fork_kb upstream_kb ratio_pct threshold_pct tag sha upstream_sha branch behind ahead pr new synced failed skipped local_backup status backup_branch legacy_backup_repo legacy_backup_branch total_branches selected_branches branch_limit branch_limit_source skipped_by_pattern skipped_by_limit workflow_id workflow_name workflow_path workflow_state total_workflows disabled_workflows dry_run_workflows kept_workflows already_disabled_workflows failed_workflows"
  # header
  echo "$CSV_KEYS" | tr ' ' '\n' | jq -R '.' | jq -rs '@csv' > "$RUNNER_TEMP/events.csv"
  # body
  jq -r --arg keys "$CSV_KEYS" '
    . as $event
    | ($keys | split(" ")) as $k
    | [ $k[] | $event[.] // "" ] | @csv
  ' "$RUNNER_TEMP/events.jsonl" >> "$RUNNER_TEMP/events.csv"
  CSV_LINES=$(($(wc -l < "$RUNNER_TEMP/events.csv") - 1))
  echo "📊 CSV 报告: $CSV_LINES 条记录 → $RUNNER_TEMP/events.csv"

  # 生成 per-fork 状态文件 (Item 14)
  # 给每个 fork 聚合:最后同步时间/SHA/结果/计数/连续失败次数
  # 跨 run 历史靠 artifact 留档(30 天),方便排查
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

TOTAL_FAILED=$(jq -s '[.[].failed] | add // 0' "$RUNNER_TEMP/summary.jsonl" 2>/dev/null || echo 0)
if [ "$TOTAL_FAILED" -gt 0 ] && [ "$QUOTA_STOPPED" != "true" ]; then
  echo "::error::本次同步存在 $TOTAL_FAILED 个分支失败"
  exit 1
fi
if [ "$QUOTA_STOPPED" = "true" ]; then
  echo "ℹ️  因配额不足提前停止,剩余 fork 下次 run 自动补上,本次不算失败"
  exit 0
fi
