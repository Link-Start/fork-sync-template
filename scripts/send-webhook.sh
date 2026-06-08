#!/usr/bin/env bash

set -e

if [ -z "$WEBHOOK_URL" ]; then
  echo "⏭️  webhook_url 未配置,跳过通知"
  exit 0
fi

SUMMARY_FILE="$RUNNER_TEMP/summary.jsonl"
if [ ! -f "$SUMMARY_FILE" ] || [ ! -s "$SUMMARY_FILE" ]; then
  echo "⚠️ 没找到 summary.jsonl,跳过通知"
  exit 0
fi

SUMMARY_JSON=$(jq -s '.' "$SUMMARY_FILE")
TOTAL=$(echo "$SUMMARY_JSON" | jq 'length')
TOTAL_NEW=$(echo "$SUMMARY_JSON" | jq '[.[].new] | add // 0')
TOTAL_SYNCED=$(echo "$SUMMARY_JSON" | jq '[.[].synced] | add // 0')
TOTAL_FAILED=$(echo "$SUMMARY_JSON" | jq '[.[].failed] | add // 0')
TOTAL_SKIPPED=$(echo "$SUMMARY_JSON" | jq '[.[].skipped] | add // 0')
TOTAL_BACKUP=$(echo "$SUMMARY_JSON" | jq '[.[].local_backup] | add // 0')
REPO_NAME="${REPO:-${GITHUB_REPOSITORY#*/}}"
REPO_OWNER="${GITHUB_REPOSITORY_OWNER:-$MY_OWNER}"

PAYLOAD=$(jq -n \
  --arg total "$TOTAL" --arg new "$TOTAL_NEW" --arg synced "$TOTAL_SYNCED" \
  --arg failed "$TOTAL_FAILED" --arg skipped "$TOTAL_SKIPPED" --arg backup "$TOTAL_BACKUP" \
  --arg repo "$REPO_NAME" --arg url "https://github.com/$REPO_OWNER/$REPO_NAME/issues" \
  --arg type "$WEBHOOK_TYPE" '
  "🤖 *Fork Sync 完成* [\($repo)]\n同步: \($total) 个 fork\n🆕 新建: \($new) | ✅ 同步: \($synced) | ❌ 失败: \($failed)\n⏭️ 跳过: \($skipped) | 📦 本地备份: \($backup)\n查看 issue: \($url)" as $msg
  | if $type == "slack" then {text: $msg}
    elif $type == "dingtalk" then {msgtype: "markdown", markdown: {title: "Fork Sync", text: $msg}}
    else {message: $msg} end
')

if curl -sf -X POST -H "Content-Type: application/json" \
        -d "$PAYLOAD" "$WEBHOOK_URL" >/dev/null 2>&1; then
  echo "✅ webhook 通知已发送 ($WEBHOOK_TYPE)"
else
  echo "::warning::webhook 发送失败 ($WEBHOOK_TYPE),但不影响 workflow"
fi
