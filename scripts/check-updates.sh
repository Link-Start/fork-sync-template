#!/usr/bin/env bash

set -e

# 阶段 1: 每日 8 点(UTC 0 点)检测任务
#   - 每 FULL_CHECK_INTERVAL_DAYS 天(默认 14)全量重检: 重建可同步/不可同步列表
#   - 每次运行: 轻量识别新 fork, 只对新 fork 做 enrich
#   - 对可同步 + 新 fork 用 compare 检测"有更新"的库, 按批次写入 registry.pending_batches
#   - 有更新的才进待同步, 无更新的直接跳过(省同步配额)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/github-api.sh"
source "$SCRIPT_DIR/fork-registry.sh"

iso_to_epoch() {
  local ts="$1"
  date -d "$ts" +%s 2>/dev/null \
    || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null \
    || echo 0
}

urlencode_ref() {
  printf '%s' "$1" | sed 's|/|%2F|g; s|%|%25|g'
}

FULL_CHECK_INTERVAL_DAYS=$(printf '%s' "${FULL_CHECK_INTERVAL_DAYS:-14}" | tr -d '[:space:]')
if ! printf '%s' "$FULL_CHECK_INTERVAL_DAYS" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::full_check_interval_days='$FULL_CHECK_INTERVAL_DAYS' 非法,回退到 14"
  FULL_CHECK_INTERVAL_DAYS=14
fi
if ! printf '%s' "${SYNC_BATCH_SIZE:-15}" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::sync_batch_size='${SYNC_BATCH_SIZE:-}' 非法,回退到 15"
  SYNC_BATCH_SIZE=15
fi
if ! printf '%s' "${SYNC_RATE_SAFE_THRESHOLD:-300}" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::sync_rate_safe_threshold='${SYNC_RATE_SAFE_THRESHOLD:-}' 非法,回退到 300"
  SYNC_RATE_SAFE_THRESHOLD=300
fi
COMPARE_BATCH_SIZE=$(printf '%s' "${COMPARE_BATCH_SIZE:-100}" | tr -d '[:space:]')
if ! printf '%s' "$COMPARE_BATCH_SIZE" | grep -Eq '^[1-9][0-9]*$'; then
  echo "::warning::compare_batch_size='$COMPARE_BATCH_SIZE' 非法,回退到 100"
  COMPARE_BATCH_SIZE=100
fi

NOW_ISO=$(date -u +%Y-%m-%dT%H:%M:%SZ)
NOW_EPOCH=$(date +%s)

REGISTRY=$(registry_read)
echo "📋 已加载注册表: $(echo "$REGISTRY" | jq -r '((.syncable|length) // 0) as $s | ((.unsyncable|length) // 0) as $u | ((.new|length) // 0) as $n | "\($s) 个可同步, \($u) 个不可同步, \($n) 个新 fork"')"

# =====================================================================
# 判断是否需要 14 天全量重检
# TARGET_OWNERS 指定其他 owner 时强制全量 (light_check 只扫 MY_OWNER, 注册表不含这些 fork)
# ONLY_REPOS 走 targeted_enrich, 不触发全量重建 (避免把注册表砍到只剩测试的仓库)
# =====================================================================
needs_full_check() {
  local last elapsed
  [ -n "$TARGET_OWNERS" ] && return 0
  if [ -n "$ONLY_REPOS" ]; then
    echo "  ↳ only_repos 快速模式: 跳过全量重建 (targeted enrich 补齐指定 fork)"
    return 1
  fi
  last=$(echo "$REGISTRY" | jq -r '.last_full_check_at // ""' 2>/dev/null || echo "")
  [ -z "$last" ] && return 0
  elapsed=$((NOW_EPOCH - $(iso_to_epoch "$last")))
  [ "$elapsed" -ge $((FULL_CHECK_INTERVAL_DAYS * 86400)) ]
}

# =====================================================================
# 全量重检: 跑 discover-forks.sh(全量 enrich + 过滤) → 分类 syncable/unsyncable
# 失败时降级保留旧注册表, 不阻塞后续轻量检测
# =====================================================================
full_check() {
  echo "🔍 全量重检 (间隔 ${FULL_CHECK_INTERVAL_DAYS} 天): 重建可同步/不可同步列表"
  local discover_out="$RUNNER_TEMP/discover_output.txt"
  : > "$discover_out"

  if ! GITHUB_OUTPUT="$discover_out" bash "$SCRIPT_DIR/discover-forks.sh"; then
    echo "::warning::全量重检 discover 失败(配额或网络),保留旧注册表,降级为轻量检测"
    return 1
  fi
  if [ ! -f "$RUNNER_TEMP/forks.json" ]; then
    echo "::warning::discover 未生成 forks.json,保留旧注册表"
    return 1
  fi

  local forks syncable_json unsyncable_json
  forks=$(cat "$RUNNER_TEMP/forks.json")
  if ! echo "$forks" | jq -e 'type == "array"' >/dev/null 2>&1; then
    echo "::warning::forks.json 不是 JSON array,保留旧注册表"
    return 1
  fi

  syncable_json=$(echo "$forks" | jq -c '[.[] | select((.upstream_unavailable_reason // "") == "") | {
      repo: ((.fork_owner // $owner) + "/" + .name),
      name: .name,
      fork_owner: (.fork_owner // $owner),
      fork_default_branch: (.fork_default_branch // "main"),
      parent_owner: (.parent_owner // ""),
      parent_name: (.parent_name // ""),
      parent_default_branch: (.parent_default_branch // ""),
      is_new: false
    }]' --arg owner "$MY_OWNER")

  unsyncable_json=$(echo "$forks" | jq -c '[.[] | select((.upstream_unavailable_reason // "") != "") | {
      repo: ((.fork_owner // $owner) + "/" + .name),
      reason: .upstream_unavailable_reason
    }]' --arg owner "$MY_OWNER")

  local syncable_count unsyncable_count
  syncable_count=$(echo "$syncable_json" | jq length)
  unsyncable_count=$(echo "$unsyncable_json" | jq length)
  echo "  ✅ 可同步: $syncable_count, 不可同步: $unsyncable_count"
  if [ "$unsyncable_count" -gt 0 ]; then
    echo "$unsyncable_json" | jq -r '.[] | "    ⚠️ \(.repo): \(.reason)"'
  fi

  REGISTRY=$(echo "$REGISTRY" | jq -c --argjson s "$syncable_json" --argjson u "$unsyncable_json" --arg now "$NOW_ISO" --argjson days "$FULL_CHECK_INTERVAL_DAYS" \
    '{updated_at: $now, last_full_check_at: $now, full_check_interval_days: $days,
      syncable: $s, unsyncable: $u, new: [], retry_failed: (.retry_failed // []), pending_batches: []}')
  echo "  📝 注册表已重建"
}

# =====================================================================
# 轻量识别新 fork: 列当前 fork(分页,便宜), 与注册表已知集合 diff
#   - 新增 → 逐个 enrich → 可同步进 syncable / 不可同步进 unsyncable
#   - 消失 → 从注册表移除
# =====================================================================
light_check() {
  if [ -n "$ONLY_REPOS" ]; then
    echo "🔍 轻量检测: only_repos 模式跳过全量扫描(只检测 $ONLY_REPOS)"
    return 0
  fi
  echo "🔍 轻量检测: 对比当前 fork 列表与注册表"
  local current_lines
  current_lines=$(gh_api_with_retry --paginate "user/repos?per_page=100&type=owner&sort=updated" \
    --jq ".[] | select(.fork == true and .owner.login == \"$MY_OWNER\") | {repo: ((.owner.login // \"$MY_OWNER\") + \"/\" + .name), name: .name}" 2>/dev/null || echo "")
  local current
  current=$(printf '%s\n' "$current_lines" | jq -s '.' 2>/dev/null || echo "[]")

  local known
  known=$(echo "$REGISTRY" | jq -c '[(.syncable // [])[].repo, ((.new // [])[].repo // empty), (.unsyncable // [])[].repo]' 2>/dev/null || echo "[]")

  local added removed
  added=$(echo "$current" | jq -c --argjson known "$known" '[.[] | select(.repo as $r | ($known | index($r)) == null)]')
  removed=$(echo "$known" | jq -c --argjson cur "$current" '[.[] | select(. as $r | ($cur | map(.repo) | index($r)) == null)]')

  local added_count removed_count
  added_count=$(echo "$added" | jq length 2>/dev/null || echo 0)
  removed_count=$(echo "$removed" | jq length 2>/dev/null || echo 0)
  if [ "$added_count" -gt 0 ]; then
    echo "  🆕 新增 $added_count 个 fork:"
    while IFS= read -r repo_json; do
      local repo_full
      repo_full=$(echo "$repo_json" | jq -r '.repo')
      echo "    - $repo_full"
      enrich_new_fork "$repo_full"
    done < <(echo "$added" | jq -c '.[]')
  else
    echo "  ✅ 无新增 fork"
  fi
  if [ "$removed_count" -gt 0 ]; then
    echo "  🗑️ 消失 $removed_count 个 fork(上游或 fork 已删除/改名),从注册表移除:"
    echo "$removed" | jq -r '.[] | "    - \(.)"'
    REGISTRY=$(echo "$REGISTRY" | jq -c --argjson gone "$removed" \
      '{updated_at: .updated_at, last_full_check_at: .last_full_check_at, full_check_interval_days: .full_check_interval_days,
        syncable: [.syncable[] | select(.repo as $r | ($gone | index($r)) == null)],
        unsyncable: [.unsyncable[] | select(.repo as $r | ($gone | index($r)) == null)],
        new: [.new[] | select(.repo as $r | ($gone | index($r)) == null)],
        retry_failed: .retry_failed, pending_batches: .pending_batches}')
  fi
}

# enrich 单个新 fork: 调 repos/owner/name 拿 parent 信息, 决定进 syncable 还是 unsyncable
# 参数支持 "repo" 或 "owner/repo" 两种格式
enrich_new_fork() {
  local repo_full="$1" owner name detail
  if [[ "$repo_full" == */* ]]; then
    owner="${repo_full%%/*}"
    name="${repo_full#*/}"
  else
    owner="$MY_OWNER"
    name="$repo_full"
  fi
  if detail=$(gh_api_with_retry "repos/$owner/$name" 2>/dev/null); then
    local entry
    entry=$(echo "$detail" | jq -c --arg owner "$owner" --arg name "$name" '{
      repo: ($owner + "/" + .name),
      name: .name,
      fork_owner: .owner.login,
      fork_default_branch: (.default_branch // "main"),
      parent_owner: (.parent.owner.login // ""),
      parent_name: (.parent.name // ""),
      parent_default_branch: (.parent.default_branch // ""),
      is_new: true
    }')
    if echo "$entry" | jq -e '.parent_owner != ""' >/dev/null 2>&1; then
      echo "    ✓ 可同步 → new (待首次同步成功后移入 syncable)"
      REGISTRY=$(echo "$REGISTRY" | jq -c --argjson e "$entry" \
        '{updated_at: .updated_at, last_full_check_at: .last_full_check_at, full_check_interval_days: .full_check_interval_days,
          syncable: .syncable, unsyncable: .unsyncable, new: (.new + [$e]), retry_failed: .retry_failed, pending_batches: .pending_batches}')
    else
      local reason
      reason=$(echo "$detail" | jq -r 'if .parent == null then "parent 信息不可用: 上游仓库可能已删除、私有化、改名或 fork 关系失效" else "" end')
      echo "    ⚠️ 不可同步 → unsyncable ($reason)"
      REGISTRY=$(echo "$REGISTRY" | jq -c --arg repo "$repo_full" --arg reason "$reason" \
        '{updated_at: .updated_at, last_full_check_at: .last_full_check_at, full_check_interval_days: .full_check_interval_days,
          syncable: .syncable, unsyncable: (.unsyncable + [{repo: $repo, reason: $reason}]), new: .new, retry_failed: .retry_failed, pending_batches: .pending_batches}')
    fi
  else
    echo "    ⚠️ $repo_full 详情不可访问,跳过"
  fi
}

# =====================================================================
# 检测更新: 对 syncable + new 里的 fork 逐个 compare(每 fork 1 次调用)
#   - behind / diverged → 有更新, 加入待同步
#   - identical / ahead → 无更新, 跳过
#   - compare 失败(无共同祖先等) → 交给同步阶段处理, 加入待同步
# 分批进行, 批间查配额, 低于安全线提前结束(剩余明天再查)
# =====================================================================
detect_updates() {
  local candidates
  candidates=$(echo "$REGISTRY" | jq -c '[(.syncable // [])[], ((.new // [])[] // empty)]')
  if [ -n "$ONLY_REPOS" ]; then
    # only_repos 快速模式: 只检测指定 fork (注册表里可能有也可能没有,没有就 enrich 补上)
    local want_json want
    want_json=$(echo "$ONLY_REPOS" | jq -R 'split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0))')
    want=$(echo "$candidates" | jq -c --argjson w "$want_json" \
      '[.[] | select((.repo // "") as $r | (($w | map(ascii_downcase) | index($r | ascii_downcase)) != null
        or (($r | split("/")[-1]) as $n | ($w | map(ascii_downcase) | index($n)) != null)))]')
    local want_count
    want_count=$(echo "$want" | jq length)
    if [ "$want_count" -eq 0 ]; then
      echo "🎯 only_repos 指定的 fork 不在注册表,尝试单独补齐..."
      local selector
      while IFS= read -r selector; do
        [ -z "$selector" ] && continue
        enrich_new_fork "$selector"
      done < <(echo "$want_json" | jq -r '.[]')
      candidates=$(echo "$REGISTRY" | jq -c '[(.syncable // [])[], ((.new // [])[] // empty)]')
      want=$(echo "$candidates" | jq -c --argjson w "$want_json" \
        '[.[] | select((.repo // "") as $r | (($w | map(ascii_downcase) | index($r | ascii_downcase)) != null
          or (($r | split("/")[-1]) as $n | ($w | map(ascii_downcase) | index($n)) != null)))]')
      want_count=$(echo "$want" | jq length)
    fi
    if [ "$want_count" -eq 0 ]; then
      echo "::warning::only_repos 没有匹配到注册表里的 fork: $ONLY_REPOS"
      return 0
    fi
    candidates="$want"
    echo "🎯 only_repos 模式: 只检测这 $want_count 个 fork"
  fi
  local total
  total=$(echo "$candidates" | jq length)
  if [ "$total" -eq 0 ]; then
    echo "⏭️  没有可同步的 fork,无需检测"
    return 0
  fi
  echo "🔍 检测 $total 个 fork 是否有更新 (compare, 每批 $COMPARE_BATCH_SIZE 个)"

  local pending_json="[]" processed=0
  local i end remaining
  while [ "$processed" -lt "$total" ]; do
    i=$((processed + 1))
    end=$((processed + COMPARE_BATCH_SIZE))
    [ "$end" -gt "$total" ] && end=$total
    echo "  ── 批次 $i..$end / $total"

    local idx fork_json compare_url cmp status behind
    local batch_pending="[]"
    for idx in $(seq $i $end); do
      fork_json=$(echo "$candidates" | jq -c ".[$((idx - 1))]")
      local repo_full compare_out
      repo_full=$(echo "$fork_json" | jq -r '.repo')
      compare_url="repos/$(echo "$fork_json" | jq -r '.fork_owner')/$(echo "$fork_json" | jq -r '.name')/compare/$(urlencode_ref "$(echo "$fork_json" | jq -r '.parent_owner')"):$(urlencode_ref "$(echo "$fork_json" | jq -r '.parent_default_branch')")...$(urlencode_ref "$(echo "$fork_json" | jq -r '.fork_owner')"):$(urlencode_ref "$(echo "$fork_json" | jq -r '.fork_default_branch')")"
      if compare_out=$(gh_api_with_retry "$compare_url" --jq '{status: (.status // "error"), behind_by: (.behind_by // 0)}' 2>/dev/null); then
        status=$(echo "$compare_out" | jq -r '.status')
        behind=$(echo "$compare_out" | jq -r '.behind_by')
        if [ "$behind" -gt 0 ] 2>/dev/null; then
          batch_pending=$(echo "$batch_pending" | jq -c --argjson f "$fork_json" '. + [$f]')
          echo "    ⏳ $repo_full: $status (落后 $behind 个提交)"
        else
          echo "    ✅ $repo_full: $status, 无更新"
        fi
      else
        # compare 失败(无共同祖先/分支不存在等) → 交给同步阶段处理
        batch_pending=$(echo "$batch_pending" | jq -c --argjson f "$fork_json" '. + [$f]')
        echo "    ⚠️ $repo_full: compare 失败,加入待同步由同步阶段处理"
      fi
    done

    pending_json=$(echo "$pending_json" | jq -c --argjson sub "$batch_pending" '. + $sub')

    processed=$end
    if [ "$processed" -lt "$total" ]; then
      remaining=$(gh_api_with_retry "rate_limit" --jq '.resources.core.remaining // 9999' 2>/dev/null || echo 9999)
      echo "  📊 已检测 $processed/$total,剩余配额 $remaining"
      if [ "$remaining" -lt "$SYNC_RATE_SAFE_THRESHOLD" ]; then
        echo "⏸️  剩余配额 $remaining < 安全线 $SYNC_RATE_SAFE_THRESHOLD,未检测的 $((total - processed)) 个明天再查"
        break
      fi
    fi
  done

  local pending_count
  pending_count=$(echo "$pending_json" | jq length)
  echo "  🎯 有更新待同步: $pending_count 个"

  if [ "$pending_count" -eq 0 ]; then
    REGISTRY=$(echo "$REGISTRY" | jq -c --arg now "$NOW_ISO" \
      '{updated_at: $now, last_full_check_at: .last_full_check_at, full_check_interval_days: .full_check_interval_days,
        syncable: .syncable, unsyncable: .unsyncable, new: .new, retry_failed: .retry_failed, pending_batches: []}')
    echo "✅ 没有需要同步的 fork"
    return 0
  fi

  # 按 SYNC_BATCH_SIZE 分组
  local batches
  batches=$(echo "$pending_json" | jq -c --argjson size "$SYNC_BATCH_SIZE" \
    '[range(0; length; $size) as $i | .[$i:$i+$size]]')
  local batch_count
  batch_count=$(echo "$batches" | jq length)
  echo "  📦 已分 $batch_count 批 (每批 $SYNC_BATCH_SIZE 个):"
  echo "$batches" | jq -r 'to_entries[] | "    批次 \(.key+1): \([.value[].name] | join(", "))"'

  REGISTRY=$(echo "$REGISTRY" | jq -c --argjson b "$batches" --arg now "$NOW_ISO" \
    '{updated_at: $now, last_full_check_at: .last_full_check_at, full_check_interval_days: .full_check_interval_days,
      syncable: .syncable, unsyncable: .unsyncable, new: .new, retry_failed: .retry_failed, pending_batches: $b, pending_generated_at: $now}')
}

# =====================================================================
# 主流程
# =====================================================================
if needs_full_check; then
  full_check || echo "  ↳ 继续轻量检测(使用旧注册表)"
fi
light_check
detect_updates
registry_write "$REGISTRY"
echo "✅ 8 点检测完成"
