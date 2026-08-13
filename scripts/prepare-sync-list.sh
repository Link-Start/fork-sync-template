#!/usr/bin/env bash

set -e

# 把注册表的 pending_batches 展开成 flat forks.json,供 Disable fork workflows 步骤使用
# (sync-each-fork.sh 直接读 registry 逐批处理, 不依赖本文件)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/github-api.sh"
source "$SCRIPT_DIR/fork-registry.sh"

REGISTRY=$(registry_read)

PENDING_COUNT=$(echo "$REGISTRY" | jq '[.pending_batches[]? | .[]] | length' 2>/dev/null || echo 0)
if [ "$PENDING_COUNT" -eq 0 ]; then
  echo "⏭️  没有待同步的 fork (pending_batches 为空)"
  echo "[]" > "$RUNNER_TEMP/forks.json"
  exit 0
fi

echo "📦 待同步 fork: $PENDING_COUNT 个"
echo "$REGISTRY" | jq -c '[.pending_batches[] | .[]]' > "$RUNNER_TEMP/forks.json"
echo "📝 已写入 $RUNNER_TEMP/forks.json ($PENDING_COUNT 个, 供 workflow 禁用/同步使用)"
