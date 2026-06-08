#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/github-api.sh"

json_lines_to_array() {
  if [ -n "$1" ]; then
    printf '%s\n' "$1" | jq -s '.'
  else
    echo "[]"
  fi
}

list_authenticated_owner_fork_candidates() {
  local lines
  if lines=$(gh_api_with_retry --paginate 'user/repos?per_page=100&type=owner&sort=updated' \
    --jq ".[] | select(.fork == true and .owner.login == \"$MY_OWNER\") | {name: .name, fork_owner: .owner.login}" 2>/dev/null); then
    json_lines_to_array "$lines"
  else
    echo "[]"
  fi
}

list_named_owner_fork_candidates() {
  local owner="$1"
  local lines

  if lines=$(gh_api_with_retry --paginate "users/$owner/repos?per_page=100&type=owner&sort=updated" \
    --jq '.[] | select(.fork == true) | {name: .name, fork_owner: .owner.login}' 2>/dev/null); then
    echo "  ✓ $owner (user/public endpoint)" >&2
    json_lines_to_array "$lines"
    return 0
  fi

  if lines=$(gh_api_with_retry --paginate "orgs/$owner/repos?per_page=100&sort=updated" \
    --jq '.[] | select(.fork == true) | {name: .name, fork_owner: .owner.login}' 2>/dev/null); then
    echo "  ✓ $owner (org endpoint)" >&2
    json_lines_to_array "$lines"
    return 0
  fi

  echo "  ⚠️ $owner: 既不是 user 也不是 org (或无权访问),跳过" >&2
  echo "[]"
  return 1
}

enrich_fork_candidates() {
  local candidates="$1"
  local candidate_count
  candidate_count=$(echo "$candidates" | jq length)
  if [ "$candidate_count" -eq 0 ]; then
    echo "[]"
    return 0
  fi

  echo "  ↳ 补齐 $candidate_count 个 fork 的 upstream 信息" >&2
  while IFS= read -r fork_json; do
    local fork_owner fork_name detail
    fork_owner=$(echo "$fork_json" | jq -r '.fork_owner')
    fork_name=$(echo "$fork_json" | jq -r '.name')

    if detail=$(gh_api_with_retry "repos/$fork_owner/$fork_name" 2>/dev/null); then
      if echo "$detail" | jq -e '.fork == true' >/dev/null 2>&1; then
        echo "$detail" | jq -c '{
          name: .name,
          fork_owner: .owner.login,
          fork_default_branch: (.default_branch // "main"),
          parent_name: (.parent.name // ""),
          parent_owner: (.parent.owner.login // ""),
          parent_default_branch: (.parent.default_branch // ""),
          upstream_unavailable_reason: (if .parent == null then "parent 信息不可用: 上游仓库可能已删除、私有化、改名或 fork 关系失效" else "" end)
        }'
      else
        echo "  ⚠️ $fork_owner/$fork_name: 不是 fork 或 fork 信息不可用,跳过" >&2
      fi
    else
      echo "  ⚠️ $fork_owner/$fork_name: 仓库详情不可访问,跳过" >&2
    fi
  done < <(echo "$candidates" | jq -c '.[]') | jq -s '.'
}

only_repo_candidates() {
  echo "$ONLY_REPOS" | jq -R '
    split(",")
    | map(gsub("^ +| +$"; ""))
    | map(select(length > 0))
    | map(
        if contains("/") then
          split("/") | {fork_owner: .[0], name: .[1]}
        else
          {fork_owner: env.MY_OWNER, name: .}
        end
      )
  '
}

FORKS="[]"
if [ -n "$ONLY_REPOS" ]; then
  echo "🎯 only_repos 快速模式: 只查询指定 fork,不扫描全量账号 → $ONLY_REPOS"
  CANDIDATES=$(only_repo_candidates)
  FORKS=$(enrich_fork_candidates "$CANDIDATES")
elif [ -z "$TARGET_OWNERS" ]; then
  echo "🌐 默认 owner: $MY_OWNER"
  AUTH_CANDIDATES=$(list_authenticated_owner_fork_candidates)
  PUBLIC_CANDIDATES=$(list_named_owner_fork_candidates "$MY_OWNER" || true)
  CANDIDATES=$(jq -s 'add | unique_by(.fork_owner + "/" + .name)' \
    <(echo "$AUTH_CANDIDATES") <(echo "$PUBLIC_CANDIDATES"))
  FORKS=$(enrich_fork_candidates "$CANDIDATES")
else
  OWNER_LIST=$(echo "$TARGET_OWNERS" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$')
  OWNER_COUNT=$(echo "$OWNER_LIST" | wc -l | tr -d ' ')
  echo "🌐 多 owner 模式: $OWNER_COUNT 个 owner → $(echo $OWNER_LIST | tr '\n' ',' | sed 's/,$//')"
  for owner in $OWNER_LIST; do
    CANDIDATES=$(list_named_owner_fork_candidates "$owner" || true)
    FORK_BATCH=$(enrich_fork_candidates "$CANDIDATES")
    FORKS=$(jq -s 'add | unique_by(.fork_owner + "/" + .name)' <(echo "$FORKS") <(echo "$FORK_BATCH"))
  done
fi

if [ -n "$FILTER" ]; then
  FORKS=$(echo "$FORKS" | jq --arg f "$FILTER" '[.[] | select(.parent_owner == $f)]')
  echo "🔍 正向过滤: 只保留 parent_owner == $FILTER"
fi

if [ -n "${EXCLUDE_PATTERN:-}" ]; then
  FORKS=$(echo "$FORKS" | jq --arg e "$EXCLUDE_PATTERN" \
    '[.[] | select((.name | ascii_downcase | contains($e | ascii_downcase)) | not)]')
  echo "🚫 反向过滤: 排除仓库名含 '$EXCLUDE_PATTERN' (大小写不敏感,只匹配 fork 仓库名)"
fi

if [ -n "$EXCLUDE_REPOS" ]; then
  EXCLUDE_JSON=$(echo "$EXCLUDE_REPOS" | jq -R 'split(",") | map(gsub("^ +| +$"; "")) | map(select(length > 0))')
  EXCLUDE_COUNT=$(echo "$EXCLUDE_JSON" | jq length)
  FORKS=$(echo "$FORKS" | jq --argjson excl "$EXCLUDE_JSON" \
    '[.[] | select(.name as $n | $excl | index($n) == null)]')
  echo "🚫 指定排除: $EXCLUDE_COUNT 个 fork → $EXCLUDE_REPOS"
fi

COUNT=$(echo "$FORKS" | jq length)
if [ -n "$ONLY_REPOS" ] && [ "$COUNT" -eq 0 ]; then
  echo "::error::only_repos 没匹配到任何 fork: $ONLY_REPOS"
  echo "  提示:填 fork 仓库名,例如 lanhu-mcp_dsphper; 多 owner 时也可填 Link-Start/lanhu-mcp_dsphper"
  exit 1
fi

echo "forks<<EOF" >> "$GITHUB_OUTPUT"
echo "$FORKS" >> "$GITHUB_OUTPUT"
echo "EOF" >> "$GITHUB_OUTPUT"

if [ "$COUNT" -eq 0 ]; then
  echo "⚠️ 没找到任何符合条件的 fork"
  exit 0
fi

echo "🔍 发现 $COUNT 个 fork 待同步"
echo "$FORKS" | jq -r '.[] | "  - \(.name) ← \(.parent_owner)/\(.parent_name)"'

if [ -n "$CRON_SCHEDULE" ]; then
  echo "🕐 手动触发,模拟 cron: $CRON_SCHEDULE"
fi
