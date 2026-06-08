#!/usr/bin/env bash

set -e

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/github-api.sh"

SUMMARY_FILE="$RUNNER_TEMP/summary.jsonl"

if [ ! -f "$SUMMARY_FILE" ] || [ ! -s "$SUMMARY_FILE" ]; then
  echo "⚠️ 没找到 summary.jsonl ($SUMMARY_FILE),跳过 issue 通知"
  exit 0
fi

SUMMARY_JSON=$(jq -s '.' "$SUMMARY_FILE")
TOTAL=$(echo "$SUMMARY_JSON" | jq 'length')
TOTAL_NEW=$(echo "$SUMMARY_JSON" | jq '[.[].new] | add // 0')
TOTAL_SYNCED=$(echo "$SUMMARY_JSON" | jq '[.[].synced] | add // 0')
TOTAL_FAILED=$(echo "$SUMMARY_JSON" | jq '[.[].failed] | add // 0')
TOTAL_SKIPPED=$(echo "$SUMMARY_JSON" | jq '[.[].skipped] | add // 0')
TOTAL_BACKUP=$(echo "$SUMMARY_JSON" | jq '[.[].local_backup] | add // 0')
RUN_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

ISSUE_TITLE="🤖 Fork Sync Report"
DETAIL_ROWS=$(echo "$SUMMARY_JSON" | jq -r '.[] | "| \(.name) | \(.result // "ok") | \(.reason // "") | \(.new) | \(.synced) | \(.failed) | \(.skipped) | \(.local_backup) |"')
FAILURE_ROWS=$(echo "$SUMMARY_JSON" | jq -r '
  def clean:
    tostring
    | gsub("[\r\n|]"; " ")
    | if length > 240 then .[0:237] + "..." else . end;
  [ .[] as $fork
    | ($fork.failure_details // [])[]?
    | "| \($fork.name | clean) | \(.branch | clean) | \(.reason | clean) | \(.hint | clean) | HTTP \((.api_status // "") | clean): \((.api_message // "") | clean) | \(.api_path | clean) |"
  ] | if length == 0 then "| - | - | - | - | - | - |" else .[] end
')
printf -v ISSUE_BODY "## 同步汇总\n\n- **运行时间**: %s (UTC)\n- **同步 fork 数**: %s\n- 🆕 新建分支: **%s**\n- ✅ 已同步: **%s**\n- ❌ 失败: **%s**\n- ⏭️ 跳过: **%s**\n- 📦 本地修改备份: **%s**\n\n### 详情\n\n| Fork | Result | Reason | 🆕 | ✅ | ❌ | ⏭️ | 📦 |\n|---|---|---|---|---|---|---|---|\n%s\n\n### 失败详情\n\n| Fork | Branch | Reason | Meaning | GitHub | API |\n|---|---|---|---|---|---|\n%s" \
  "$RUN_TS" "$TOTAL" "$TOTAL_NEW" "$TOTAL_SYNCED" "$TOTAL_FAILED" "$TOTAL_SKIPPED" "$TOTAL_BACKUP" "$DETAIL_ROWS" "$FAILURE_ROWS"

EXISTING=$(gh_api_with_retry "repos/$MY_OWNER/$REPO/issues?state=all&labels=&per_page=100" \
           --jq ".[] | select(.title == \"$ISSUE_TITLE\") | .number" 2>/dev/null | head -1 || echo "")

if [ -n "$EXISTING" ]; then
  gh_api_write -X PATCH "repos/$MY_OWNER/$REPO/issues/$EXISTING" \
    -f title="$ISSUE_TITLE" \
    -f body="$ISSUE_BODY" >/dev/null
  echo "📝 更新 issue #$EXISTING"
else
  NEW_ISSUE=$(gh_api_write -X POST "repos/$MY_OWNER/$REPO/issues" \
              -f title="$ISSUE_TITLE" \
              -f body="$ISSUE_BODY" 2>/dev/null)
  NEW_NUM=$(echo "$NEW_ISSUE" | jq -r '.number // empty')
  echo "📝 新建 issue #$NEW_NUM"
fi
