#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/github-api.sh"

CONFIG_REPO="${CONFIG_REPO:-}"
if [ -z "$CONFIG_REPO" ]; then
  echo "::error::CONFIG_REPO is required"
  exit 1
fi

CONFIG_YAML=$(gh_api_with_retry "repos/$MY_OWNER/$CONFIG_REPO/contents/.github/sync-config.yml" \
              --jq '.content // ""' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -z "$CONFIG_YAML" ]; then
  echo "📄 未找到 .github/sync-config.yml,用默认配置"
  exit 0
fi

echo "📄 找到 .github/sync-config.yml,加载覆盖:"
for KEY in exclude_pattern exclude_repos size_drop_threshold size_check_exempt \
           max_parallel max_branches_per_fork skip_branch_patterns full_branch_sync_repos \
           branch_limit_groups branch_limit_overrides sync_mode webhook_type \
           discard_local_changes protected_skip_repos backup_then_sync_repos \
           legacy_backup_repo legacy_backup_branch_prefix; do
  VAL=$(echo "$CONFIG_YAML" | grep -E "^${KEY}:" | head -1 \
        | sed -E "s/^${KEY}:[[:space:]]*//" \
        | sed 's/^["'"'"']//;s/["'"'"']$//' || echo "")
  if [ -n "$VAL" ]; then
    ENV_KEY=$(printf '%s' "$KEY" | tr '[:lower:]' '[:upper:]')
    echo "  ✓ $KEY = $VAL"
    echo "CONFIG_${ENV_KEY}=${VAL}" >> "$GITHUB_ENV"
  fi
done
