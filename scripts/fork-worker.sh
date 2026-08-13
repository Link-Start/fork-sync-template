#!/usr/bin/env bash

process_fork() {
  local fork_b64="$1"
  local fork_json
  local FORK_REPO UPSTREAM_OWNER UPSTREAM_REPO UPSTREAM_DEFAULT FORK_DEFAULT UPSTREAM_UNAVAILABLE_REASON
  local FORK_NAME
  fork_json=$(printf '%s' "$fork_b64" | base64 -d 2>/dev/null || echo "")
  if [ -z "$fork_json" ] || ! echo "$fork_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::warning::收到非法 fork 参数,跳过"
    return 0
  fi
  FORK_NAME=$(echo "$fork_json" | jq -r '.name')
  local log_file="$LOG_DIR/${FORK_NAME}.log"
  exec > "$log_file" 2>&1

  FORK_REPO=$(echo "$fork_json" | jq -r '.name')
  # fork_owner 是 Item 17 多 owner 引入的字段;老数据没有就 fallback 到 MY_OWNER
  FORK_OWNER=$(echo "$fork_json" | jq -r '.fork_owner // empty')
  FORK_OWNER="${FORK_OWNER:-$MY_OWNER}"
  UPSTREAM_OWNER=$(echo "$fork_json" | jq -r '.parent_owner')
  UPSTREAM_REPO=$(echo "$fork_json" | jq -r '.parent_name')
  UPSTREAM_DEFAULT=$(echo "$fork_json" | jq -r '.parent_default_branch')
  FORK_DEFAULT=$(echo "$fork_json" | jq -r '.fork_default_branch // "main"')
  UPSTREAM_UNAVAILABLE_REASON=$(echo "$fork_json" | jq -r '.upstream_unavailable_reason // empty')
  local SYNCED=() FAILED=() NEW=() SKIPPED=() LOCAL_BACKED_UP=() FAILURE_DETAILS=()
  local BACKUP_THEN_SYNC_ACTIVE=false LEGACY_BACKUP_READY=false

  csv_lines() {
    printf '%s' "$1" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || true
  }

  # verify_fork_ref_sha: PATCH force update 后校验 fork ref 是否到达目标 SHA。
  # PATCH 成功但立即 GET 可能命中 GitHub 最终一致性延迟(读到旧 SHA),
  # 因此做带退避的重试,避免把"已成功的同步"误判为失败。
  # 返回 0 表示确认一致;返回 1 表示确认不一致(此时变量里是最新的实测 SHA 与错误)。
  verify_fork_ref_sha() {
    local branch="$1" expect_sha="$2"
    local out_var="${3:-VERIFY_SHA}" err_var="${4:-VERIFY_ERR}"
    local api="repos/$FORK_OWNER/$FORK_REPO/git/ref/heads/$branch"
    local attempt=1 max_attempts=3 delay=2 got="" err=""
    while [ "$attempt" -le "$max_attempts" ]; do
      if gh_api_capture got err "$api" --jq '.object.sha' && [ -n "$got" ]; then
        if [ "$got" = "$expect_sha" ]; then
          printf -v "$out_var" '%s' "$got"
          printf -v "$err_var" '%s' ""
          return 0
        fi
        # 成功读到但 SHA 不一致 → 可能是最终一致性延迟,短暂等待后重读
        if [ "$attempt" -lt "$max_attempts" ]; then
          echo "  ⏳ 校验 SHA 不一致(fork=${got:0:7} != upstream=${expect_sha:0:7}),等待 ${delay}s 重试 (${attempt}/${max_attempts})" >&2
          sleep "$delay"
          delay=$((delay * 2))
        fi
      else
        # API 调用失败 → 重试
        if [ "$attempt" -lt "$max_attempts" ]; then
          echo "  ⏳ 校验 API 失败,${delay}s 后重试 (${attempt}/${max_attempts})" >&2
          sleep "$delay"
          delay=$((delay * 2))
        fi
      fi
      attempt=$((attempt + 1))
    done
    printf -v "$out_var" '%s' "${got:-}"
    printf -v "$err_var" '%s' "$err"
    return 1
  }

  repo_in_csv() {
    local list="$1"
    [ -z "$list" ] && return 1
    csv_lines "$list" | grep -Fxq "*" && return 0
    csv_lines "$list" | grep -Fxq "$FORK_REPO" && return 0
    csv_lines "$list" | grep -Fxq "$FORK_OWNER/$FORK_REPO"
  }

  branch_matches_pattern() {
    local branch="$1" patterns="$2" pattern
    [ -z "$patterns" ] && return 1
    while IFS= read -r pattern; do
      [ -z "$pattern" ] && continue
      case "$branch" in
        $pattern) return 0 ;;
      esac
    done < <(csv_lines "$patterns")
    return 1
  }

  branch_limit_override_for_repo() {
    local overrides="$1" item key val repo_full="$FORK_OWNER/$FORK_REPO"
    [ -z "$overrides" ] && return 1
    while IFS= read -r item; do
      [ -z "$item" ] && continue
      case "$item" in
        *=*) ;;
        *) continue ;;
      esac
      key=${item%%=*}
      val=${item#*=}
      key=$(printf '%s' "$key" | sed 's/^ *//;s/ *$//')
      val=$(printf '%s' "$val" | sed 's/^ *//;s/ *$//')
      if { [ "$key" = "$FORK_REPO" ] || [ "$key" = "$repo_full" ]; } && \
         printf '%s' "$val" | grep -Eq '^(0|[1-9][0-9]*)$'; then
        printf '%s\n' "$val"
        return 0
      fi
    done < <(csv_lines "$overrides")
    return 1
  }

  branch_limit_group_for_repo() {
    local groups="$1" group limit repos repo_full="$FORK_OWNER/$FORK_REPO"
    [ -z "$groups" ] && return 1
    while IFS= read -r group; do
      group=$(printf '%s' "$group" | sed 's/^ *//;s/ *$//')
      [ -z "$group" ] && continue
      case "$group" in
        *:*) ;;
        *) continue ;;
      esac
      limit=${group%%:*}
      repos=${group#*:}
      limit=$(printf '%s' "$limit" | sed 's/^ *//;s/ *$//')
      if ! printf '%s' "$limit" | grep -Eq '^(0|[1-9][0-9]*)$'; then
        continue
      fi
      if csv_lines "$repos" | grep -Fxq "$FORK_REPO" || \
         csv_lines "$repos" | grep -Fxq "$repo_full"; then
        printf '%s\n' "$limit"
        return 0
      fi
    done < <(printf '%s\n' "$groups" | tr ';' '\n')
    return 1
  }

  first_json_line() {
    awk 'match($0, /^\{.*\}/) {print substr($0, RSTART, RLENGTH); exit}' <<<"$1"
  }

  api_error_field() {
    local raw="$1" field="$2" json
    json=$(first_json_line "$raw")
    if [ -n "$json" ]; then
      jq -r --arg field "$field" '.[$field] // empty' <<<"$json" 2>/dev/null | head -1
    fi
  }

  api_error_message() {
    local raw="$1" message
    message=$(api_error_field "$raw" "message")
    if [ -z "$message" ]; then
      message=$(sed -n 's/^gh: //p' <<<"$raw" | head -1)
    fi
    if [ -z "$message" ]; then
      message=$(head -1 <<<"$raw")
    fi
    printf '%s' "$message" | tr '\r\n' ' ' | cut -c 1-500
  }

  api_error_hint() {
    local context="$1" status="$2" message="$3"
    case "$context:$status:$message" in
      upstream_repo:404:*)
        printf '%s' "上游仓库本体不可访问; 常见原因: 源仓库被删除、改私有且 token 无权限、仓库改名但 fork 元数据残留、owner 账号不可见或 token 无权限"
        ;;
      upstream_repo:403:*)
        printf '%s' "上游仓库本体被拒绝访问; 常见原因: token 权限不足、私有仓库无权限、组织 SSO/策略限制或 API 限制"
        ;;
      branches:404:*)
        printf '%s' "上游仓库分支列表不可访问; 常见原因: 上游仓库被删除、私有化、改名、空仓库或 token 无权限"
        ;;
      branches:403:*)
        printf '%s' "上游仓库分支列表被拒绝访问; 常见原因: token 权限不足、私有仓库无权限、组织 SSO/策略限制或 API 限制"
        ;;
      upstream_sha:404:*)
        printf '%s' "上游分支当前不可读取; 常见原因: 分支已删除/重命名、分支名包含特殊路径导致 ref 查询失败、或 API 列表与 ref 查询之间发生变化"
        ;;
      fork_sha:404:*)
        printf '%s' "fork 上没有这个分支; 如果后续创建失败,通常是分支名/SHA/权限问题"
        ;;
      compare:404:*No\ common\ ancestor*)
        printf '%s' "fork 分支和 upstream 分支没有共同祖先; 常见原因: fork 分支是独立历史、被强制改写过、或不是从该 upstream 分支派生"
        ;;
      compare:404:*)
        printf '%s' "GitHub compare 找不到可比较对象; 常见原因: 上游/fork 分支不存在、仓库不可访问、fork 关系异常或没有共同历史"
        ;;
      compare:409:*)
        printf '%s' "GitHub compare 冲突/无法生成比较结果; 需要人工确认该分支历史"
        ;;
      create_ref:422:*Reference\ already\ exists*)
        printf '%s' "目标分支已存在; 可能是并发运行或上一次运行刚创建"
        ;;
      create_ref:422:*)
        printf '%s' "GitHub 拒绝创建分支; 常见原因: 分支名非法、SHA 不存在、仓库规则限制或参数校验失败"
        ;;
      create_ref:403:*)
        printf '%s' "没有创建分支权限,或仓库规则禁止创建该 ref"
        ;;
      update_ref:403:*|discard:403:*|merge_keep:403:*|merge_upstream:403:*)
        printf '%s' "没有更新分支权限,或分支保护/仓库规则阻止写入"
        ;;
      update_ref:422:*|discard:422:*)
        printf '%s' "GitHub 拒绝强制更新 ref; 常见原因: 参数校验失败、分支保护、SHA 无效或仓库规则限制"
        ;;
      merge_upstream:409:*|merge_keep:409:*)
        printf '%s' "merge-upstream 发生冲突,不能自动合并"
        ;;
      *:404:*)
        printf '%s' "GitHub 返回 404; 通常是仓库/分支不存在、已删除/私有化、改名或 token 无权限"
        ;;
      *:403:*)
        printf '%s' "GitHub 返回 403; 通常是 token 权限不足、分支保护、仓库规则或 API 限制"
        ;;
      *:422:*)
        printf '%s' "GitHub 返回 422; 通常是请求参数无效、ref/SHA 不合法、分支已存在或仓库规则校验失败"
        ;;
      *)
        printf '%s' "GitHub API 调用失败; 需要结合原始 message 判断"
        ;;
    esac
  }

  record_failure() {
    local branch="$1" reason="$2" context="${3:-}" api_path="${4:-}" api_error="${5:-}" event_mode="${6:-}"
    local api_status api_message api_doc hint detail_json
    api_status=$(api_error_field "$api_error" "status")
    api_doc=$(api_error_field "$api_error" "documentation_url")
    api_message=$(api_error_message "$api_error")
    hint=$(api_error_hint "$context" "$api_status" "$api_message")

    FAILED+=("$branch")
    detail_json=$(jq -n -c \
      --arg branch "$branch" \
      --arg reason "$reason" \
      --arg context "$context" \
      --arg api_path "$api_path" \
      --arg api_status "$api_status" \
      --arg api_message "$api_message" \
      --arg api_doc "$api_doc" \
      --arg hint "$hint" \
      --arg mode "$event_mode" \
      '{branch: $branch, reason: $reason, context: $context, api_path: $api_path, api_status: $api_status, api_message: $api_message, api_doc: $api_doc, hint: $hint, mode: $mode}')
    FAILURE_DETAILS+=("$detail_json")

    echo "    详情: $hint"
    if [ -n "$api_status" ] || [ -n "$api_message" ]; then
      echo "    GitHub: HTTP ${api_status:-unknown} - ${api_message:-unknown}"
    fi
    log_event "$FORK_REPO" "sync_branch" "fail" \
      branch="$branch" reason="$reason" context="$context" api_path="$api_path" \
      api_status="$api_status" api_message="$api_message" hint="$hint" mode="$event_mode"
  }

  write_fork_summary() {
    local result="$1"
    local reason="${2:-}"
    local failure_details_json="[]" failure_summary=""
    if [ "${#FAILED[@]}" -gt 0 ]; then
      result="fail"
    fi
    if [ "${#FAILURE_DETAILS[@]}" -gt 0 ]; then
      failure_details_json=$(printf '%s\n' "${FAILURE_DETAILS[@]}" | jq -s '.')
      failure_summary=$(printf '%s\n' "${FAILURE_DETAILS[0]}" | jq -r '
        .reason
        + (if .api_status != "" then " (HTTP " + .api_status + ")" else "" end)
        + (if .hint != "" then ": " + .hint else "" end)
      ' | cut -c 1-300)
    fi
    if [ -z "$reason" ] && [ -n "$failure_summary" ]; then
      reason="$failure_summary"
    fi

    echo ""
    echo "  📊 $FORK_REPO: result=$result 🆕${#NEW[@]} ✅${#SYNCED[@]} ❌${#FAILED[@]} ⏭️${#SKIPPED[@]} 📦${#LOCAL_BACKED_UP[@]}"

    log_event "$FORK_REPO" "fork_complete" "$result" \
      new="${#NEW[@]}" synced="${#SYNCED[@]}" failed="${#FAILED[@]}" \
      skipped="${#SKIPPED[@]}" local_backup="${#LOCAL_BACKED_UP[@]}" reason="$reason"

    jq -n -c \
      --arg name "$FORK_REPO" \
      --arg result "$result" \
      --arg reason "$reason" \
      --argjson new "${#NEW[@]}" \
      --argjson synced "${#SYNCED[@]}" \
      --argjson failed "${#FAILED[@]}" \
      --argjson skipped "${#SKIPPED[@]}" \
      --argjson local_backup "${#LOCAL_BACKED_UP[@]}" \
      --argjson failure_details "$failure_details_json" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{name: $name, result: $result, reason: $reason, new: $new, synced: $synced, failed: $failed, skipped: $skipped, local_backup: $local_backup, failure_details: $failure_details, ts: $ts}' \
      >> "$RUNNER_TEMP/summary.jsonl"
  }

  local_backup_branches() {
    local source_branch="$1"
    local prefix="local-backup/${source_branch}-"
    gh_api_with_retry "repos/$FORK_OWNER/$FORK_REPO/git/matching-refs/heads/$prefix" \
      --jq '.[].ref' 2>/dev/null \
      | sed 's|^refs/heads/||' \
      | awk -v prefix="$prefix" 'index($0, prefix) == 1 {
          rest = substr($0, length(prefix) + 1)
          if (rest ~ /^[0-9]{8}-[0-9]{6}-[0-9a-f]{7}$/) print
        }' \
      | sort -r \
      || true
  }

  latest_local_backup_branch() {
    local source_branch="$1"
    local_backup_branches "$source_branch" | head -1 || true
  }

  local_backup_contains_sha() {
    local backup_branch="$1" fork_sha="$2"
    local backup_sha compare_status compare_err compare_api

    backup_sha=$(gh_api_with_retry "repos/$FORK_OWNER/$FORK_REPO/git/ref/heads/$backup_branch" \
                 --jq '.object.sha' 2>/dev/null || echo "")
    [ -z "$backup_sha" ] && return 1
    [ "$backup_sha" = "$fork_sha" ] && return 0

    compare_api="repos/$FORK_OWNER/$FORK_REPO/compare/$fork_sha...$backup_sha"
    if ! gh_api_capture compare_status compare_err "$compare_api" --jq '.status'; then
      return 1
    fi
    case "$compare_status" in
      identical|ahead) return 0 ;;
      *) return 1 ;;
    esac
  }

  protective_backup_for_current_head() {
    local source_branch="$1" fork_sha="$2" backup_branch
    while IFS= read -r backup_branch; do
      [ -z "$backup_branch" ] && continue
      if local_backup_contains_sha "$backup_branch" "$fork_sha"; then
        printf '%s\n' "$backup_branch"
        return 0
      fi
    done < <(local_backup_branches "$source_branch")
    return 1
  }

  safe_legacy_branch_name() {
    local name="$1"
    name=$(printf '%s' "$name" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
    printf '%s' "${name:-fork}"
  }

  parse_repo_full_name() {
    local input="$1" default_owner="$2"
    case "$input" in
      */*) printf '%s\n' "$input" ;;
      *) printf '%s/%s\n' "$default_owner" "$input" ;;
    esac
  }

  ensure_legacy_backup_contains_current_head() {
    local backup_repo_config="${LEGACY_BACKUP_REPO:-}"
    local branch_prefix="${LEGACY_BACKUP_BRANCH_PREFIX:-legacy}"
    local fork_sha fork_sha_err fork_sha_api legacy_full legacy_owner legacy_repo
    local safe_name primary_branch target_branch existing_sha existing_err repo_err legacy_repo_out
    local tmp source_auth_header backup_auth_header timestamp push_err verify_ref

    fork_sha_api="repos/$FORK_OWNER/$FORK_REPO/git/ref/heads/$FORK_DEFAULT"
    if ! gh_api_capture fork_sha fork_sha_err "$fork_sha_api" --jq '.object.sha'; then
      fork_sha=""
    fi
    if [ -z "$fork_sha" ]; then
      echo "    ❌ 集中备份失败: fork 默认分支不可读取 ($FORK_DEFAULT)"
      record_failure "$FORK_DEFAULT" "集中备份失败: fork 默认分支不可读取" "fork_sha" "$fork_sha_api" "$fork_sha_err" "legacy_backup"
      return 1
    fi

    if [ -z "$backup_repo_config" ]; then
      echo "    ❌ backup_then_sync_repos 已命中,但 legacy_backup_repo 未配置"
      record_failure "$FORK_DEFAULT" "集中备份失败: legacy_backup_repo 未配置" "legacy_backup" "" "" "legacy_backup"
      return 1
    fi

    legacy_full=$(parse_repo_full_name "$backup_repo_config" "$MY_OWNER")
    legacy_owner=${legacy_full%%/*}
    legacy_repo=${legacy_full#*/}
    if ! with_gh_token "${BACKUP_GH_TOKEN:-}" gh_api_capture legacy_repo_out repo_err "repos/$legacy_owner/$legacy_repo" --jq '.full_name' >/dev/null; then
      if [ "${DRY_RUN:-false}" = "true" ]; then
        echo "    [DRY-RUN] 集中备份仓库不可访问,实际运行时会尝试创建私有仓库: $legacy_full"
      else
        local backup_login login_err create_out create_err
        if ! with_gh_token "${BACKUP_GH_TOKEN:-}" gh_api_capture backup_login login_err "user" --jq '.login' >/dev/null || \
           [ "$backup_login" != "$legacy_owner" ]; then
          echo "    ❌ 集中备份仓库不可访问: $legacy_full"
          echo "    详情: BACKUP_GH_TOKEN 当前账号为 '${backup_login:-unknown}',不能自动创建 $legacy_owner/$legacy_repo"
          record_failure "$FORK_DEFAULT" "集中备份仓库不可访问: $legacy_full" "legacy_backup_repo" "repos/$legacy_owner/$legacy_repo" "$repo_err" "legacy_backup"
          return 1
        fi
        echo "    📦 集中备份仓库不存在,创建私有仓库: $legacy_full"
        if ! with_gh_token "${BACKUP_GH_TOKEN:-}" gh_api_capture create_out create_err "user/repos" \
            -X POST \
            -f name="$legacy_repo" \
            -f private=true \
            -f has_issues=false \
            -f has_wiki=false \
            -f auto_init=false \
            -f description="Centralized default-branch fork backups" \
            --jq '.full_name' >/dev/null || [ "$create_out" != "$legacy_full" ]; then
          echo "    ❌ 集中备份仓库创建失败: $legacy_full"
          record_failure "$FORK_DEFAULT" "集中备份仓库创建失败: $legacy_full" "legacy_backup_repo" "repos/$legacy_owner/$legacy_repo" "$create_err" "legacy_backup"
          return 1
        fi
      fi
    fi

    safe_name=$(safe_legacy_branch_name "$FORK_REPO")
    branch_prefix=$(printf '%s' "$branch_prefix" | sed -E 's#^/+##; s#/+$##')
    branch_prefix=${branch_prefix:-legacy}
    primary_branch="$branch_prefix/$safe_name"
    target_branch="$primary_branch"

    if [ "${DRY_RUN:-false}" = "true" ]; then
      echo "    [DRY-RUN] 会集中备份 $FORK_OWNER/$FORK_REPO:$FORK_DEFAULT → $legacy_full:$primary_branch (${fork_sha:0:7})"
      log_event "$FORK_REPO" "legacy_backup" "dry_run" \
        branch="$FORK_DEFAULT" legacy_backup_repo="$legacy_full" \
        legacy_backup_branch="$primary_branch" sha="${fork_sha:0:7}"
      return 0
    fi

    tmp=$(mktemp -d) || return 1
    source_auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
    backup_auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${BACKUP_GH_TOKEN:-$GH_TOKEN}" | base64 | tr -d '\n')"
    push_err="$tmp/push.err"

    if ! git -C "$tmp" init -q || \
       ! git -C "$tmp" remote add fork "https://github.com/$FORK_OWNER/$FORK_REPO.git" || \
       ! git -C "$tmp" remote add legacy "https://github.com/$legacy_owner/$legacy_repo.git" || \
       ! git -C "$tmp" -c credential.helper= -c http.extraheader="$source_auth_header" fetch --quiet --no-tags fork "refs/heads/$FORK_DEFAULT:refs/sync/current"; then
      rm -rf "$tmp"
      echo "    ❌ 集中备份失败: 无法读取 fork 默认分支"
      record_failure "$FORK_DEFAULT" "集中备份失败: 无法读取 fork 默认分支" "legacy_backup" "$fork_sha_api" "" "legacy_backup"
      return 1
    fi

    if with_gh_token "${BACKUP_GH_TOKEN:-}" gh_api_capture existing_sha existing_err "repos/$legacy_owner/$legacy_repo/git/ref/heads/$primary_branch" --jq '.object.sha'; then
      if git -C "$tmp" -c credential.helper= -c http.extraheader="$backup_auth_header" fetch --quiet --no-tags legacy "refs/heads/$primary_branch:refs/sync/legacy"; then
        if git -C "$tmp" merge-base --is-ancestor refs/sync/current refs/sync/legacy; then
          echo "    📦 集中备份已包含当前 HEAD: $legacy_full:$primary_branch → ${fork_sha:0:7}"
          log_event "$FORK_REPO" "legacy_backup" "skip" \
            branch="$FORK_DEFAULT" legacy_backup_repo="$legacy_full" \
            legacy_backup_branch="$primary_branch" sha="${fork_sha:0:7}" \
            reason="已有集中备份包含当前 fork HEAD"
          rm -rf "$tmp"
          return 0
        fi
        if ! git -C "$tmp" merge-base --is-ancestor refs/sync/legacy refs/sync/current; then
          timestamp=$(date +%Y%m%d-%H%M%S)
          target_branch="$branch_prefix/${safe_name}-${timestamp}-${fork_sha:0:7}"
          echo "    📦 集中备份分支不能 fast-forward,改用时间戳分支: $target_branch"
        fi
      else
        timestamp=$(date +%Y%m%d-%H%M%S)
        target_branch="$branch_prefix/${safe_name}-${timestamp}-${fork_sha:0:7}"
        echo "    ⚠️ 集中备份已有分支不可 fetch,改用时间戳分支: $target_branch"
      fi
    fi

    if ! git -C "$tmp" -c credential.helper= -c http.extraheader="$backup_auth_header" push --quiet legacy "refs/sync/current:refs/heads/$target_branch" 2>"$push_err"; then
      echo "    ❌ 集中备份 push 失败: $legacy_full:$target_branch"
      record_failure "$FORK_DEFAULT" "集中备份 push 失败: $legacy_full:$target_branch" "legacy_backup" "repos/$legacy_owner/$legacy_repo/git/refs/heads/$target_branch" "$(cat "$push_err")" "legacy_backup"
      rm -rf "$tmp"
      return 1
    fi

    verify_ref="refs/sync/verify-${fork_sha:0:7}"
    if ! git -C "$tmp" -c credential.helper= -c http.extraheader="$backup_auth_header" fetch --quiet --no-tags legacy "refs/heads/$target_branch:$verify_ref" || \
       ! git -C "$tmp" merge-base --is-ancestor refs/sync/current "$verify_ref"; then
      echo "    ❌ 集中备份校验失败: $legacy_full:$target_branch 不包含当前 HEAD"
      record_failure "$FORK_DEFAULT" "集中备份校验失败: 备份分支不包含当前 fork HEAD" "legacy_backup" "repos/$legacy_owner/$legacy_repo/git/refs/heads/$target_branch" "" "legacy_backup"
      rm -rf "$tmp"
      return 1
    fi

    echo "    📦 集中备份完成: $legacy_full:$target_branch → ${fork_sha:0:7}"
    log_event "$FORK_REPO" "legacy_backup" "ok" \
      branch="$FORK_DEFAULT" legacy_backup_repo="$legacy_full" \
      legacy_backup_branch="$target_branch" sha="${fork_sha:0:7}"
    rm -rf "$tmp"
    return 0
  }

  ensure_protective_local_backup() {
    local source_branch="$1" reason="$2"
    local fork_sha fork_sha_err fork_sha_api backup_branch existing_backup
    local backup_out backup_err backup_api
    fork_sha_api="repos/$FORK_OWNER/$FORK_REPO/git/ref/heads/$source_branch"
    if ! gh_api_capture fork_sha fork_sha_err "$fork_sha_api" --jq '.object.sha'; then
      fork_sha=""
    fi
    if [ -z "$fork_sha" ]; then
      echo "    ❌ 保护备份失败: fork 分支不存在或不可读取 ($source_branch)"
      record_failure "$source_branch" "保护备份失败: fork 分支不存在或不可读取" "fork_sha" "$fork_sha_api" "$fork_sha_err" "protective_backup"
      return 1
    fi

    existing_backup=$(protective_backup_for_current_head "$source_branch" "$fork_sha" || true)
    if [ -n "$existing_backup" ]; then
      echo "    📦 已有包含当前 HEAD 的保护备份: $existing_backup → ${fork_sha:0:7}"
      LOCAL_BACKED_UP+=("$source_branch:$existing_backup")
      log_event "$FORK_REPO" "local_backup" "skip" branch="$source_branch" backup_branch="$existing_backup" reason="已有保护备份包含当前 fork HEAD" sha="${fork_sha:0:7}"
      return 0
    fi

    backup_branch="local-backup/${source_branch}-$(date +%Y%m%d-%H%M%S)-${fork_sha:0:7}"
    backup_api="repos/$FORK_OWNER/$FORK_REPO/git/refs"
    if [ "${DRY_RUN:-false}" = "true" ]; then
      echo "    [DRY-RUN] 会保护备份: $backup_branch → ${fork_sha:0:7}"
      LOCAL_BACKED_UP+=("$source_branch:$backup_branch")
      log_event "$FORK_REPO" "local_backup" "dry_run" branch="$source_branch" backup_branch="$backup_branch" reason="$reason" sha="${fork_sha:0:7}"
      return 0
    fi
    if gh_api_write_capture backup_out backup_err -X POST "$backup_api" \
         -f ref="refs/heads/$backup_branch" \
         -f sha="$fork_sha" >/dev/null 2>&1; then
      echo "    📦 保护备份: $backup_branch → ${fork_sha:0:7}"
      LOCAL_BACKED_UP+=("$source_branch:$backup_branch")
      log_event "$FORK_REPO" "local_backup" "ok" branch="$source_branch" backup_branch="$backup_branch" reason="$reason" sha="${fork_sha:0:7}"
      return 0
    fi

    echo "    ❌ 保护备份分支创建失败: $backup_branch"
    log_event "$FORK_REPO" "local_backup" "fail" branch="$source_branch" backup_branch="$backup_branch" reason="$reason" api_status="$(api_error_field "$backup_err" "status")" api_message="$(api_error_message "$backup_err")"
    record_failure "$source_branch" "保护备份分支创建失败" "protective_backup" "$backup_api" "$backup_err" "protective_backup"
    return 1
  }

  protect_and_skip_fork() {
    local reason="$1" detail="$2"
    echo "  🛡️  $reason"
    [ -n "$detail" ] && echo "  $detail"
    ensure_protective_local_backup "$FORK_DEFAULT" "$reason" || true
    log_event "$FORK_REPO" "protective_skip" "skip" reason="$reason" default_branch="$FORK_DEFAULT"
    SKIPPED+=("$FORK_REPO")
    write_fork_summary "skip" "$reason"
    return 0
  }

  probe_upstream_repository() {
    local repo_out repo_err repo_api status message hint
    repo_api="repos/$UPSTREAM_OWNER/$UPSTREAM_REPO"
    if gh_api_capture repo_out repo_err "$repo_api" --jq '{full_name, private, default_branch, size, archived, disabled}'; then
      printf '%s\n' "$repo_out"
      return 0
    fi

    status=$(api_error_field "$repo_err" "status")
    message=$(api_error_message "$repo_err")
    hint=$(api_error_hint "upstream_repo" "$status" "$message")
    UPSTREAM_UNAVAILABLE_REASON="上游仓库本体不可访问 (HTTP ${status:-unknown}: ${message:-unknown}); $hint"
    echo "::warning::$UPSTREAM_UNAVAILABLE_REASON" >&2
    log_event "$FORK_REPO" "upstream_check" "fail" \
      upstream="$UPSTREAM_OWNER/$UPSTREAM_REPO" reason="$UPSTREAM_UNAVAILABLE_REASON" \
      context="upstream_repo" api_path="$repo_api" api_status="$status" api_message="$message" hint="$hint"
    return 1
  }

  fetch_ref_for_signature() {
    local repo_dir="$1"
    local remote="$2"
    local source_ref="$3"
    local target_ref="$4"
    local auth_header="$5"

    git -C "$repo_dir" -c http.extraheader="$auth_header" fetch --quiet --no-tags --depth=1000 \
      "$remote" "$source_ref:$target_ref"
  }

  local_changes_signature() {
    local repo_dir="$1"
    local upstream_ref="$2"
    local head_ref="$3"
    local base sig
    base=$(git -C "$repo_dir" merge-base "$upstream_ref" "$head_ref") || return 1
    sig=$(git -C "$repo_dir" diff --find-renames "$base" "$head_ref" \
          | git -C "$repo_dir" patch-id --stable \
          | awk '{print $1}' \
          | sort \
          | paste -sd, -)
    printf '%s\n' "${sig:-empty}"
  }

  local_backup_matches_current_changes() {
    local source_branch="$1"
    local backup_branch="$2"
    local tmp auth_header current_sig backup_sig
    tmp=$(mktemp -d) || return 2
    auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"

    git -C "$tmp" init -q || { rm -rf "$tmp"; return 2; }
    git -C "$tmp" remote add fork "https://github.com/$FORK_OWNER/$FORK_REPO.git"
    git -C "$tmp" remote add upstream "https://github.com/$UPSTREAM_OWNER/$UPSTREAM_REPO.git"

    if ! fetch_ref_for_signature "$tmp" fork "refs/heads/$source_branch" refs/sync/current "$auth_header" || \
       ! fetch_ref_for_signature "$tmp" fork "refs/heads/$backup_branch" refs/sync/backup "$auth_header"; then
      rm -rf "$tmp"
      return 2
    fi
    if ! fetch_ref_for_signature "$tmp" upstream "refs/heads/$source_branch" refs/sync/upstream "$auth_header"; then
      rm -rf "$tmp"
      return 2
    fi

    current_sig=$(local_changes_signature "$tmp" refs/sync/upstream refs/sync/current) || {
      rm -rf "$tmp"
      return 2
    }
    backup_sig=$(local_changes_signature "$tmp" refs/sync/upstream refs/sync/backup) || {
      rm -rf "$tmp"
      return 2
    }
    rm -rf "$tmp"

    [ "$current_sig" = "$backup_sig" ]
  }

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "🔄 $FORK_OWNER/$FORK_REPO ← $UPSTREAM_OWNER/$UPSTREAM_REPO"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # ----- 阶段 0: 列表策略与跳过检查 -----
  local IN_PROTECTED_SKIP=false IN_BACKUP_THEN_SYNC=false IN_LEGACY_BACKUP=false
  if repo_in_csv "${PROTECTED_SKIP_REPOS:-}"; then
    IN_PROTECTED_SKIP=true
  fi
  if repo_in_csv "${LEGACY_BACKUP_REPOS:-}"; then
    IN_LEGACY_BACKUP=true
  fi
  if repo_in_csv "${BACKUP_THEN_SYNC_REPOS:-}"; then
    IN_BACKUP_THEN_SYNC=true
  fi
  if { [ "$IN_PROTECTED_SKIP" = "true" ] && { [ "$IN_LEGACY_BACKUP" = "true" ] || [ "$IN_BACKUP_THEN_SYNC" = "true" ]; }; } || \
     { [ "$IN_LEGACY_BACKUP" = "true" ] && [ "$IN_BACKUP_THEN_SYNC" = "true" ]; }; then
    echo "    ❌ 配置冲突: 同时命中 protected_skip_repos / legacy_backup_repos / backup_then_sync_repos 中多个列表"
    record_failure "$FORK_DEFAULT" "配置冲突: 同时命中多个备份/同步策略列表" "config" "" "" "config"
    write_fork_summary "fail"
    return 0
  fi
  if [ "$IN_PROTECTED_SKIP" = "true" ]; then
    log_event "$FORK_REPO" "policy" "protected_skip" reason="protected_skip_repos"
    protect_and_skip_fork "protected_skip_repos 命中,已保护备份并跳过同步" "该列表只做 local-backup 保护备份,不会进入集中备份库,也不会执行 Discard commits"
    return 0
  fi
  if [ "$IN_LEGACY_BACKUP" = "true" ]; then
    echo "🧭 legacy_backup_repos 命中: 只集中备份默认分支,然后跳过同步/Discard"
    log_event "$FORK_REPO" "policy" "legacy_backup" reason="legacy_backup_repos"
    if ensure_legacy_backup_contains_current_head; then
      LOCAL_BACKED_UP+=("$FORK_DEFAULT:legacy")
      SKIPPED+=("$FORK_REPO")
      write_fork_summary "skip" "legacy_backup_repos 命中,已集中备份默认分支并跳过同步"
    else
      echo "    🛑 集中备份未完成,跳过该 fork 同步以避免丢失旧代码"
      write_fork_summary "fail"
    fi
    return 0
  fi
  if [ "$IN_BACKUP_THEN_SYNC" = "true" ]; then
    BACKUP_THEN_SYNC_ACTIVE=true
    echo "🧭 backup_then_sync_repos 命中: 将先集中备份,再允许原 fork 对齐当前指向库"
    log_event "$FORK_REPO" "policy" "backup_then_sync" reason="backup_then_sync_repos"
  fi

  # ----- 阶段 0.1: 传统跳过检查 -----
  local NO_SYNC_JSON SKIP_REASON
  NO_SYNC_JSON=$(gh_api_with_retry "repos/$FORK_OWNER/$FORK_REPO/contents/.github/.no-sync" 2>/dev/null || true)
  if [ -n "$NO_SYNC_JSON" ]; then
    SKIP_REASON=$(echo "$NO_SYNC_JSON" | jq -r '.content // ""' 2>/dev/null | base64 -d 2>/dev/null | head -c 200 || true)
    SKIP_REASON="${SKIP_REASON:-no-sync marker}"
    echo "⏭️  跳过 $FORK_REPO (fork 自带 .github/.no-sync: $SKIP_REASON)"
    SKIPPED+=("$FORK_REPO")
    log_event "$FORK_REPO" "skip_check" "skip" reason=".github/.no-sync"
    write_fork_summary "skip" ".github/.no-sync: $SKIP_REASON"
    return 0
  fi

  if [ -n "$SKIP_LIST" ] && printf '%s\n' "$SKIP_LIST" | grep -qxF "$FORK_REPO"; then
    echo "⏭️  跳过 $FORK_REPO (在 config 仓库 skip.txt 中)"
    SKIPPED+=("$FORK_REPO")
    log_event "$FORK_REPO" "skip_check" "skip" reason="skip.txt"
    write_fork_summary "skip" "skip.txt"
    return 0
  fi

  # ----- 阶段 1: 上游存活检查 -----
  if [ -z "$UPSTREAM_DEFAULT" ]; then
    echo "::warning::上游不可访问 (删除/私有化/改名/fork 关系失效),只备份 fork 后跳过"
    log_event "$FORK_REPO" "upstream_check" "fail" reason="${UPSTREAM_UNAVAILABLE_REASON:-上游不可访问}"
    protect_and_skip_fork "上游不可访问,已保护备份并跳过同步" "${UPSTREAM_UNAVAILABLE_REASON:-疑似源仓库已删除、私有化、改名或 token 无权限}"
    return 0
  fi

  local UPSTREAM_REPO_PROBE UPSTREAM_PROBED_DEFAULT UPSTREAM_PROBED_SIZE
  if ! UPSTREAM_REPO_PROBE=$(probe_upstream_repository); then
    protect_and_skip_fork "上游仓库不可访问,已保护备份并跳过同步" "$UPSTREAM_UNAVAILABLE_REASON"
    return 0
  fi
  UPSTREAM_PROBED_DEFAULT=$(echo "$UPSTREAM_REPO_PROBE" | jq -r '.default_branch // empty' 2>/dev/null || echo "")
  UPSTREAM_PROBED_SIZE=$(echo "$UPSTREAM_REPO_PROBE" | jq -r '.size // 0' 2>/dev/null || echo 0)
  if [ -z "$UPSTREAM_PROBED_DEFAULT" ]; then
    UPSTREAM_UNAVAILABLE_REASON="上游仓库 default_branch 为空; 可能是空仓库、源码不可用或 token 无权限读取默认分支"
    log_event "$FORK_REPO" "upstream_check" "fail" upstream="$UPSTREAM_OWNER/$UPSTREAM_REPO" reason="$UPSTREAM_UNAVAILABLE_REASON"
    protect_and_skip_fork "上游默认分支不可用,已保护备份并跳过同步" "$UPSTREAM_UNAVAILABLE_REASON"
    return 0
  fi
  UPSTREAM_DEFAULT="$UPSTREAM_PROBED_DEFAULT"

  log_event "$FORK_REPO" "upstream_check" "ok" upstream="$UPSTREAM_OWNER/$UPSTREAM_REPO" default_branch="$UPSTREAM_DEFAULT"
  echo "🔍 上游默认分支: $UPSTREAM_DEFAULT"

  # ----- 阶段 1.5: 危险检测 - 上游体积暴减 -----
  # 场景: 上游把源码删了只留 README/说明文件,同步会把 fork 源码也删光
  # 启发: GitHub repo .size 字段 (KB),当 fork 已有实质内容 (>= 50KB)
  #       且 upstream 为空或 upstream 体积/fork 体积 < SIZE_DROP_THRESHOLD 时,跳过整个 fork
  # SIZE_DROP_THRESHOLD 默认 0.10 (=10%,敏感);0.30 宽松;0 关闭
  # SIZE_CHECK_EXEMPT: 逗号分隔的 fork 名白名单,这些 fork 跳过 size 检查
  #                    适用于极小项目 (1KB CLI 工具) 被误杀的情况
  local FORK_SIZE UPSTREAM_SIZE THRESHOLD_PCT SKIP_SIZE_CHECK=false
  # 检查豁免名单 (精确匹配,逗号分隔)
  if [ -n "$SIZE_CHECK_EXEMPT" ] && \
     printf '%s' "$SIZE_CHECK_EXEMPT" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -Fxq "$FORK_REPO"; then
    echo "⏭️  豁免 size 检查: $FORK_REPO 在 SIZE_CHECK_EXEMPT 白名单里"
    SKIP_SIZE_CHECK=true
    log_event "$FORK_REPO" "size_check" "exempt" reason="在白名单里"
  fi
  FORK_SIZE=$(gh_api_with_retry "repos/$FORK_OWNER/$FORK_REPO" --jq '.size // 0' 2>/dev/null || echo 0)
  UPSTREAM_SIZE="${UPSTREAM_PROBED_SIZE:-0}"
  THRESHOLD_PCT=$(awk "BEGIN {printf \"%.0f\", $SIZE_DROP_THRESHOLD * 100}")
  if [ "$SKIP_SIZE_CHECK" != "true" ] && [ "${FORK_SIZE:-0}" -ge 50 ] && \
     [ "$(awk "BEGIN {print ($SIZE_DROP_THRESHOLD > 0 && $UPSTREAM_SIZE <= 0) ? 1 : 0}")" = "1" ]; then
    echo "::error::🛑 危险: 上游仓库为空或源码不可用 (fork=${FORK_SIZE}KB → upstream=${UPSTREAM_SIZE}KB,阈值 ${THRESHOLD_PCT}%)"
    log_event "$FORK_REPO" "size_check" "skip" reason="上游仓库为空或源码不可用" fork_kb="$FORK_SIZE" upstream_kb="$UPSTREAM_SIZE" ratio_pct="0.0" threshold_pct="$THRESHOLD_PCT"
    protect_and_skip_fork "上游仓库为空或源码不可用,已保护备份并跳过同步" "疑似上游删库/清空源码/只保留空历史"
    return 0
  fi
  if [ "$SKIP_SIZE_CHECK" != "true" ] && [ "${FORK_SIZE:-0}" -ge 50 ] && [ "${UPSTREAM_SIZE:-0}" -gt 0 ] && \
     [ "$(awk "BEGIN {print ($UPSTREAM_SIZE < $FORK_SIZE * $SIZE_DROP_THRESHOLD) ? 1 : 0}")" = "1" ]; then
    local RATIO
    RATIO=$(awk "BEGIN {printf \"%.1f\", $UPSTREAM_SIZE * 100 / $FORK_SIZE}")
    echo "::error::🛑 危险: 上游体积暴减 (fork=${FORK_SIZE}KB → upstream=${UPSTREAM_SIZE}KB, 上游只剩 fork 的 ${RATIO}%,阈值 ${THRESHOLD_PCT}%)"
    log_event "$FORK_REPO" "size_check" "skip" reason="上游体积暴减" fork_kb="$FORK_SIZE" upstream_kb="$UPSTREAM_SIZE" ratio_pct="$RATIO" threshold_pct="$THRESHOLD_PCT"
    protect_and_skip_fork "上游体积暴减,已保护备份并跳过同步" "疑似上游删除了源码,只留下 README/说明文件"
    return 0
  fi
  if [ "$SKIP_SIZE_CHECK" = "true" ]; then
    echo "📏 体积检查跳过 (豁免): fork=${FORK_SIZE}KB, upstream=${UPSTREAM_SIZE}KB"
  else
    echo "📏 体积检查通过: fork=${FORK_SIZE}KB, upstream=${UPSTREAM_SIZE}KB (阈值 ${THRESHOLD_PCT}%)"
    log_event "$FORK_REPO" "size_check" "pass" fork_kb="$FORK_SIZE" upstream_kb="$UPSTREAM_SIZE" threshold_pct="$THRESHOLD_PCT"
  fi

  if [ "$BACKUP_THEN_SYNC_ACTIVE" = "true" ]; then
    echo "📦 backup_then_sync_repos: 开始集中备份当前 fork 默认分支"
    if ensure_legacy_backup_contains_current_head; then
      LEGACY_BACKUP_READY=true
      echo "📦 backup_then_sync_repos: 集中备份校验通过,允许后续 Discard commits/同步"
    else
      echo "    🛑 集中备份未完成,跳过该 fork 同步以避免丢失旧代码"
      write_fork_summary "fail"
      return 0
    fi
  fi

  # ----- 阶段 2: 备份当前 fork 默认分支 -----
  local FORK_DEFAULT_SHA
  FORK_DEFAULT_SHA=$(gh_api_with_retry "repos/$FORK_OWNER/$FORK_REPO/git/ref/heads/$UPSTREAM_DEFAULT" \
                     --jq '.object.sha' 2>/dev/null || echo "")
  if [ -n "$FORK_DEFAULT_SHA" ]; then
    local BACKUP_TAG
    BACKUP_TAG="backup/$(date +%Y%m%d-%H%M%S)-${FORK_DEFAULT_SHA:0:7}"
    if gh_api_write -X POST "repos/$FORK_OWNER/$FORK_REPO/git/refs" \
         -f ref="refs/tags/$BACKUP_TAG" \
         -f sha="$FORK_DEFAULT_SHA" >/dev/null 2>&1; then
      echo "💾 备份: $BACKUP_TAG → ${FORK_DEFAULT_SHA:0:7}"
      log_event "$FORK_REPO" "backup_tag" "ok" tag="$BACKUP_TAG" sha="${FORK_DEFAULT_SHA:0:7}"
    fi
  fi

  # ----- 阶段 3: 遍历 upstream 分支,逐个同步 -----
  local UPSTREAM_BRANCH_LIST UPSTREAM_BRANCH_ERR UPSTREAM_BRANCH_API
  UPSTREAM_BRANCH_API="repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/branches?per_page=100"
  if ! gh_api_capture UPSTREAM_BRANCH_LIST UPSTREAM_BRANCH_ERR --paginate "$UPSTREAM_BRANCH_API" \
       --jq '.[] | .name'; then
    UPSTREAM_BRANCH_LIST=""
  fi
  if [ -z "$UPSTREAM_BRANCH_LIST" ]; then
    echo "    ❌ 拿不到 upstream 分支列表"
    record_failure "__branches__" "拿不到 upstream 分支列表" "branches" "$UPSTREAM_BRANCH_API" "$UPSTREAM_BRANCH_ERR" "auto"
    write_fork_summary "fail"
    return 0
  fi

  # GitHub branches API is paginated. Process the default branch first so
  # a large upstream cannot starve main behind later pages.
  SORTED_BRANCH_LIST=$(printf '%s\n' "$UPSTREAM_BRANCH_LIST" | awk -v default_branch="$UPSTREAM_DEFAULT" '
    $0 == "" { next }
    $0 == default_branch { has_default = 1; next }
    !seen[$0]++ { branches[++n] = $0 }
    END {
      if (default_branch != "" && has_default) print default_branch
      for (i = 1; i <= n; i++) print branches[i]
    }
  ') || {
    echo "    ❌ upstream 分支排序失败"
    record_failure "__branches__" "upstream 分支排序失败" "branches" "$UPSTREAM_BRANCH_API" "" "auto"
    write_fork_summary "fail"
    return 0
  }
  UPSTREAM_BRANCH_LIST="$SORTED_BRANCH_LIST"
  if [ -z "$UPSTREAM_BRANCH_LIST" ]; then
    echo "    ❌ upstream 分支排序后为空"
    record_failure "__branches__" "upstream 分支排序后为空" "branches" "$UPSTREAM_BRANCH_API" "" "auto"
    write_fork_summary "fail"
    return 0
  fi

  local TOTAL_BRANCH_COUNT EFFECTIVE_BRANCH_LIMIT BRANCH_LIMIT_SOURCE FULL_BRANCH_SYNC
  local OVERRIDE_LIMIT SELECTED_BRANCH_LIST SELECTED_COUNT SKIPPED_BY_PATTERN SKIPPED_BY_LIMIT
  TOTAL_BRANCH_COUNT=$(printf '%s\n' "$UPSTREAM_BRANCH_LIST" | grep -c . || true)
  EFFECTIVE_BRANCH_LIMIT="$MAX_BRANCHES_PER_FORK"
  BRANCH_LIMIT_SOURCE="default"
  FULL_BRANCH_SYNC=false

  if repo_in_csv "$FULL_BRANCH_SYNC_REPOS"; then
    FULL_BRANCH_SYNC=true
    EFFECTIVE_BRANCH_LIMIT=0
    BRANCH_LIMIT_SOURCE="full_branch_sync_repos"
  else
    OVERRIDE_LIMIT=$(branch_limit_override_for_repo "$BRANCH_LIMIT_OVERRIDES" || true)
    if [ -n "$OVERRIDE_LIMIT" ]; then
      EFFECTIVE_BRANCH_LIMIT="$OVERRIDE_LIMIT"
      BRANCH_LIMIT_SOURCE="branch_limit_overrides"
    else
      OVERRIDE_LIMIT=$(branch_limit_group_for_repo "$BRANCH_LIMIT_GROUPS" || true)
      if [ -n "$OVERRIDE_LIMIT" ]; then
        EFFECTIVE_BRANCH_LIMIT="$OVERRIDE_LIMIT"
        BRANCH_LIMIT_SOURCE="branch_limit_groups"
      fi
    fi
  fi

  SELECTED_BRANCH_LIST=""
  SELECTED_COUNT=0
  SKIPPED_BY_PATTERN=0
  SKIPPED_BY_LIMIT=0
  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    if [ "$FULL_BRANCH_SYNC" != "true" ] && [ "$branch" != "$UPSTREAM_DEFAULT" ] && \
       branch_matches_pattern "$branch" "$SKIP_BRANCH_PATTERNS"; then
      SKIPPED_BY_PATTERN=$((SKIPPED_BY_PATTERN + 1))
      continue
    fi
    if [ "$FULL_BRANCH_SYNC" != "true" ] && [ "$EFFECTIVE_BRANCH_LIMIT" -gt 0 ] && \
       [ "$SELECTED_COUNT" -ge "$EFFECTIVE_BRANCH_LIMIT" ]; then
      SKIPPED_BY_LIMIT=$((SKIPPED_BY_LIMIT + 1))
      continue
    fi
    SELECTED_BRANCH_LIST="${SELECTED_BRANCH_LIST}${branch}"$'\n'
    SELECTED_COUNT=$((SELECTED_COUNT + 1))
  done <<< "$UPSTREAM_BRANCH_LIST"

  UPSTREAM_BRANCH_LIST=$(printf '%s' "$SELECTED_BRANCH_LIST")
  if [ -z "$UPSTREAM_BRANCH_LIST" ]; then
    echo "    ❌ upstream 分支筛选后为空"
    record_failure "__branches__" "upstream 分支筛选后为空" "branches" "$UPSTREAM_BRANCH_API" "" "auto"
    write_fork_summary "fail"
    return 0
  fi

  echo "🌿 分支计划: upstream=$TOTAL_BRANCH_COUNT, selected=$SELECTED_COUNT, limit=$EFFECTIVE_BRANCH_LIMIT, source=$BRANCH_LIMIT_SOURCE, pattern_skip=$SKIPPED_BY_PATTERN, limit_skip=$SKIPPED_BY_LIMIT"
  if [ "$SKIPPED_BY_LIMIT" -gt 0 ]; then
    echo "  ⏭️  $SKIPPED_BY_LIMIT 个 upstream 分支因超过上限暂不处理"
  fi
  if [ "$SKIPPED_BY_PATTERN" -gt 0 ]; then
    echo "  ⏭️  $SKIPPED_BY_PATTERN 个 upstream 分支匹配 skip_branch_patterns 暂不处理"
  fi
  log_event "$FORK_REPO" "branch_plan" "ok" \
    total_branches="$TOTAL_BRANCH_COUNT" selected_branches="$SELECTED_COUNT" \
    branch_limit="$EFFECTIVE_BRANCH_LIMIT" branch_limit_source="$BRANCH_LIMIT_SOURCE" \
    skipped_by_pattern="$SKIPPED_BY_PATTERN" skipped_by_limit="$SKIPPED_BY_LIMIT"

  while IFS= read -r branch; do
    [ -z "$branch" ] && continue
    echo "  ━━━ $branch ━━━"

    local UPSTREAM_SHA FORK_SHA UPSTREAM_SHA_ERR UPSTREAM_SHA_API
    UPSTREAM_SHA_API="repos/$UPSTREAM_OWNER/$UPSTREAM_REPO/git/ref/heads/$branch"
    if ! gh_api_capture UPSTREAM_SHA UPSTREAM_SHA_ERR "$UPSTREAM_SHA_API" \
         --jq '.object.sha'; then
      UPSTREAM_SHA=""
    fi
    if [ -z "$UPSTREAM_SHA" ]; then
      echo "    ❌ 拿不到 upstream SHA"
      record_failure "$branch" "拿不到 upstream SHA" "upstream_sha" "$UPSTREAM_SHA_API" "$UPSTREAM_SHA_ERR" "auto"
      continue
    fi

    local FORK_SHA_ERR FORK_SHA_API
    FORK_SHA_API="repos/$FORK_OWNER/$FORK_REPO/git/ref/heads/$branch"
    if ! gh_api_capture FORK_SHA FORK_SHA_ERR "$FORK_SHA_API" \
         --jq '.object.sha'; then
      FORK_SHA=""
    fi

    if [ -z "$FORK_SHA" ]; then
      local CREATE_REF_OUT CREATE_REF_ERR CREATE_REF_API
      CREATE_REF_API="repos/$FORK_OWNER/$FORK_REPO/git/refs"
      if gh_api_write_capture CREATE_REF_OUT CREATE_REF_ERR -X POST "$CREATE_REF_API" \
           -f ref="refs/heads/$branch" \
           -f sha="$UPSTREAM_SHA" >/dev/null 2>&1; then
        echo "    🆕 新建 → ${UPSTREAM_SHA:0:7}"
        NEW+=("$branch")
        SYNCED+=("$branch")
        log_event "$FORK_REPO" "sync_branch" "new" branch="$branch" upstream_sha="${UPSTREAM_SHA:0:7}"
      else
        echo "    ❌ 新建失败"
        record_failure "$branch" "新建失败" "create_ref" "$CREATE_REF_API" "$CREATE_REF_ERR" "auto"
      fi
      continue
    fi

    local COMPARE_JSON STATUS AHEAD BEHIND COMPARE_ERR COMPARE_API
    COMPARE_API="repos/$FORK_OWNER/$FORK_REPO/compare/${UPSTREAM_OWNER}:${UPSTREAM_REPO}:${branch}...${branch}"
    if ! gh_api_capture COMPARE_JSON COMPARE_ERR "$COMPARE_API" \
         --jq '{status: .status, ahead: .ahead_by, behind: .behind_by}'; then
      COMPARE_JSON='{"status":"error"}'
    fi
    STATUS=$(echo "$COMPARE_JSON" | jq -r '.status // "error"')
    AHEAD=$(echo "$COMPARE_JSON" | jq -r '.ahead // 0')
    BEHIND=$(echo "$COMPARE_JSON" | jq -r '.behind // 0')

    # upstream 没有新增时,纯 ahead 是 fork 本地独有提交,无需备份/同步。
    if { [ "$STATUS" = "ahead" ] || [ "$STATUS" = "diverged" ]; } && \
       [ "$AHEAD" -gt 0 ] && [ "${BEHIND:-0}" -eq 0 ] && \
       { [ "$BACKUP_THEN_SYNC_ACTIVE" != "true" ] || [ "$branch" != "$FORK_DEFAULT" ]; }; then
      echo "    ⏭️ 本地超前 $AHEAD commit,上游无新增,无需备份/同步"
      SKIPPED+=("$branch")
      log_event "$FORK_REPO" "sync_branch" "skip" branch="$branch" ahead="$AHEAD" behind="$BEHIND" reason="上游无新增"
      continue
    fi

    if [ "$BACKUP_THEN_SYNC_ACTIVE" = "true" ] && [ "$branch" = "$FORK_DEFAULT" ] && [ "$LEGACY_BACKUP_READY" != "true" ]; then
      record_failure "$branch" "backup_then_sync_repos 集中备份未完成" "legacy_backup" "" "" "legacy_backup"
      continue
    fi

    # 3.4.0 本地修改自动备份
    # 只在 upstream 有新增且 fork 有本地 commit 时备份;已有相同本地 patch 备份则跳过。
    if { [ "$STATUS" = "ahead" ] || [ "$STATUS" = "diverged" ]; } && \
       [ "$AHEAD" -gt 0 ] && [ "${BEHIND:-0}" -gt 0 ] && [ -n "$FORK_SHA" ]; then
      local BACKUP_BRANCH LATEST_BACKUP SHOULD_CREATE_BACKUP BACKUP_READY BACKUP_COMPARE_RC
      SHOULD_CREATE_BACKUP=true
      BACKUP_READY=false
      LATEST_BACKUP=$(latest_local_backup_branch "$branch")

      if [ -n "$LATEST_BACKUP" ]; then
        if local_backup_matches_current_changes "$branch" "$LATEST_BACKUP"; then
          echo "    📦 已有相同本地修改备份: $LATEST_BACKUP,跳过新备份"
          log_event "$FORK_REPO" "local_backup" "skip" branch="$branch" backup_branch="$LATEST_BACKUP" ahead="$AHEAD" behind="$BEHIND" reason="已有相同本地改动备份"
          SHOULD_CREATE_BACKUP=false
          BACKUP_READY=true
        else
          BACKUP_COMPARE_RC=$?
          if [ "$BACKUP_COMPARE_RC" -eq 1 ]; then
            echo "    📦 本地修改不同于最近备份: $LATEST_BACKUP,创建新备份"
          else
            echo "    ⚠️ 无法比较最近备份: $LATEST_BACKUP,保守创建新备份"
            log_event "$FORK_REPO" "local_backup" "warn" branch="$branch" backup_branch="$LATEST_BACKUP" ahead="$AHEAD" behind="$BEHIND" reason="备份比较失败"
          fi
        fi
      fi

      if [ "$SHOULD_CREATE_BACKUP" = "true" ]; then
        local BACKUP_REF_OUT BACKUP_REF_ERR BACKUP_REF_API
        BACKUP_BRANCH="local-backup/${branch}-$(date +%Y%m%d-%H%M%S)-${FORK_SHA:0:7}"
        BACKUP_REF_API="repos/$FORK_OWNER/$FORK_REPO/git/refs"
        if gh_api_write_capture BACKUP_REF_OUT BACKUP_REF_ERR -X POST "$BACKUP_REF_API" \
             -f ref="refs/heads/$BACKUP_BRANCH" \
             -f sha="$FORK_SHA" >/dev/null 2>&1; then
          echo "    📦 本地修改备份: $BACKUP_BRANCH (含 $AHEAD 个 commit)"
          LOCAL_BACKED_UP+=("$branch:$BACKUP_BRANCH")
          BACKUP_READY=true
          log_event "$FORK_REPO" "local_backup" "ok" branch="$branch" backup_branch="$BACKUP_BRANCH" ahead="$AHEAD" behind="$BEHIND"
        else
          echo "    🛑 备份分支创建失败,跳过该分支同步以避免丢失本地修改"
          log_event "$FORK_REPO" "local_backup" "fail" branch="$branch" backup_branch="$BACKUP_BRANCH" ahead="$AHEAD" behind="$BEHIND" reason="备份分支创建失败" api_message="$(api_error_message "$BACKUP_REF_ERR")" api_status="$(api_error_field "$BACKUP_REF_ERR" "status")"
        fi
      fi

      if [ "$BACKUP_READY" != "true" ]; then
        record_failure "$branch" "本地修改备份未完成" "backup_ref" "${BACKUP_REF_API:-}" "${BACKUP_REF_ERR:-}" "auto"
        continue
      fi
    fi

    case "$STATUS" in
      identical)
        echo "    = 已同步 (${UPSTREAM_SHA:0:7})"
        log_event "$FORK_REPO" "sync_branch" "identical" branch="$branch" upstream_sha="${UPSTREAM_SHA:0:7}"
        ;;
      behind)
        if [ "$SYNC_MODE" = "pr" ]; then
          # PR 模式: 建 sync 分支 + 开 PR,让用户审
          local PR_BRANCH PR_NUM PR_REF_OUT PR_REF_ERR PR_REF_API
          PR_BRANCH="sync-upstream/${branch}-$(date +%Y%m%d-%H%M%S)"
          PR_REF_API="repos/$FORK_OWNER/$FORK_REPO/git/refs"
          if gh_api_write_capture PR_REF_OUT PR_REF_ERR -X POST "$PR_REF_API" \
               -f ref="refs/heads/$PR_BRANCH" \
               -f sha="$UPSTREAM_SHA" >/dev/null 2>&1; then
            local PR_JSON
            PR_JSON=$(gh_api_write -X POST "repos/$FORK_OWNER/$FORK_REPO/pulls" \
                      -f title="[Sync] $branch ← upstream (落后 $BEHIND)" \
                      -f head="$PR_BRANCH" \
                      -f base="$branch" \
                      -f body="自动从 upstream 同步,$BEHIND 个 commit 待 review" 2>/dev/null)
            PR_NUM=$(echo "$PR_JSON" | jq -r '.number // empty' 2>/dev/null)
            echo "    🔀 落后 $BEHIND → 开 PR #$PR_NUM ($PR_BRANCH → $branch)"
            NEW+=("$branch:$PR_BRANCH")
            SYNCED+=("$branch")
            log_event "$FORK_REPO" "sync_branch" "ok" branch="$branch" mode="pr" behind="$BEHIND" pr="$PR_NUM"
          else
            echo "    ❌ PR 模式: sync 分支创建失败"
            record_failure "$branch" "sync 分支创建失败" "create_ref" "$PR_REF_API" "$PR_REF_ERR" "pr"
          fi
        else
          # auto 模式: 直接 merge-upstream,失败兜底 PATCH
          local MERGE_OUT MERGE_ERR MERGE_API PATCH_OUT PATCH_ERR PATCH_API
          MERGE_API="repos/$FORK_OWNER/$FORK_REPO/merge-upstream"
          if gh_api_write_capture MERGE_OUT MERGE_ERR -X POST "$MERGE_API" \
               -f branch="$branch" >/dev/null 2>&1; then
            echo "    ⏪ 落后 $BEHIND → merge-upstream 快进"
            SYNCED+=("$branch")
            log_event "$FORK_REPO" "sync_branch" "ok" branch="$branch" mode="merge" behind="$BEHIND"
          else
            PATCH_API="repos/$FORK_OWNER/$FORK_REPO/git/refs/heads/$branch"
            if gh_api_write_capture PATCH_OUT PATCH_ERR -X PATCH "$PATCH_API" \
                 -f sha="$UPSTREAM_SHA" -F force=true >/dev/null 2>&1; then
              echo "    ⏪ 落后 $BEHIND → PATCH 兜底"
              SYNCED+=("$branch")
              log_event "$FORK_REPO" "sync_branch" "ok" branch="$branch" mode="patch" behind="$BEHIND"
            else
              echo "    ❌ merge + PATCH 都失败"
              record_failure "$branch" "merge-upstream 和 PATCH 兜底都失败" "update_ref" "$PATCH_API" "$PATCH_ERR" "auto"
              log_event "$FORK_REPO" "sync_branch" "fail" branch="$branch" mode="auto" reason="merge-upstream 原始错误" context="merge_upstream" api_path="$MERGE_API" api_status="$(api_error_field "$MERGE_ERR" "status")" api_message="$(api_error_message "$MERGE_ERR")" hint="$(api_error_hint "merge_upstream" "$(api_error_field "$MERGE_ERR" "status")" "$(api_error_message "$MERGE_ERR")")"
            fi
          fi
        fi
        ;;
      ahead|diverged)
        if [ "$DISCARD_LOCAL_CHANGES" = "force" ] || { [ "$BACKUP_THEN_SYNC_ACTIVE" = "true" ] && [ "$branch" = "$FORK_DEFAULT" ]; }; then
          # 等价于 GitHub 网页 Sync fork 里的 Discard commits: ref 必须指向 upstream SHA。
          local VERIFY_SHA DISCARD_OUT DISCARD_ERR DISCARD_API VERIFY_ERR VERIFY_API
          DISCARD_API="repos/$FORK_OWNER/$FORK_REPO/git/refs/heads/$branch"
          if gh_api_write_capture DISCARD_OUT DISCARD_ERR -X PATCH "$DISCARD_API" \
               -f sha="$UPSTREAM_SHA" -F force=true >/dev/null; then
            if [ "${DRY_RUN:-false}" = "true" ]; then
              echo "    [DRY-RUN] 会 Discard commits: 丢弃 $AHEAD + 同步 $BEHIND → ${UPSTREAM_SHA:0:7}"
              SYNCED+=("$branch")
              log_event "$FORK_REPO" "sync_branch" "dry_run" branch="$branch" mode="discard_commits" ahead="$AHEAD" behind="$BEHIND" upstream_sha="${UPSTREAM_SHA:0:7}"
              continue
            fi
            VERIFY_API="repos/$FORK_OWNER/$FORK_REPO/git/ref/heads/$branch"
            if verify_fork_ref_sha "$branch" "$UPSTREAM_SHA" VERIFY_SHA VERIFY_ERR; then
              echo "    ⏩ Discard commits: 丢弃 $AHEAD + 同步 $BEHIND → ${UPSTREAM_SHA:0:7}"
              SYNCED+=("$branch")
              log_event "$FORK_REPO" "sync_branch" "ok" branch="$branch" mode="discard_commits" ahead="$AHEAD" behind="$BEHIND" upstream_sha="${UPSTREAM_SHA:0:7}"
            else
              echo "    ❌ Discard commits 校验失败: fork=${VERIFY_SHA:0:7}, upstream=${UPSTREAM_SHA:0:7}"
              if [ -n "$VERIFY_ERR" ]; then
                record_failure "$branch" "Discard commits 后校验失败" "verify_ref" "$VERIFY_API" "$VERIFY_ERR" "discard_commits"
              else
                record_failure "$branch" "同步后 SHA 不一致: fork=${VERIFY_SHA:0:7}, upstream=${UPSTREAM_SHA:0:7}" "verify_ref" "$VERIFY_API" "" "discard_commits"
              fi
            fi
          else
            echo "    ❌ Discard commits 失败"
            record_failure "$branch" "PATCH force update 失败" "discard" "$DISCARD_API" "$DISCARD_ERR" "discard_commits"
          fi
        else
          # keep 模式: 去重备份 + 用 merge-upstream 合并上游更新，保留本地改动
          local KEEP_MERGE_OUT KEEP_MERGE_ERR KEEP_MERGE_API
          KEEP_MERGE_API="repos/$FORK_OWNER/$FORK_REPO/merge-upstream"
          if gh_api_write_capture KEEP_MERGE_OUT KEEP_MERGE_ERR -X POST "$KEEP_MERGE_API" \
               -f branch="$branch" >/dev/null 2>&1; then
            echo "    🔀 保留本地 $AHEAD commit，merge upstream $BEHIND commit → ${UPSTREAM_SHA:0:7}"
            SYNCED+=("$branch")
            log_event "$FORK_REPO" "sync_branch" "ok" branch="$branch" mode="keep" ahead="$AHEAD" behind="$BEHIND"
          else
            echo "    ❌ merge-upstream 失败"
            record_failure "$branch" "merge-upstream 失败" "merge_keep" "$KEEP_MERGE_API" "$KEEP_MERGE_ERR" "keep"
          fi
        fi
        ;;
      *)
        echo "    ⚠️ compare 异常 (status=$STATUS)"
        if { [ "$DISCARD_LOCAL_CHANGES" = "force" ] || { [ "$BACKUP_THEN_SYNC_ACTIVE" = "true" ] && [ "$branch" = "$FORK_DEFAULT" ]; }; } && \
           [ "$(api_error_field "$COMPARE_ERR" "status")" = "404" ] && \
           printf '%s' "$(api_error_message "$COMPARE_ERR")" | grep -Fq 'No common ancestor'; then
          local NO_COMMON_ANCESTOR_REASON NO_COMMON_ANCESTOR_STATUS NO_COMMON_ANCESTOR_MESSAGE NO_COMMON_ANCESTOR_HINT
          NO_COMMON_ANCESTOR_REASON="fork 分支和 upstream 分支没有共同祖先"
          NO_COMMON_ANCESTOR_STATUS=$(api_error_field "$COMPARE_ERR" "status")
          NO_COMMON_ANCESTOR_MESSAGE=$(api_error_message "$COMPARE_ERR")
          NO_COMMON_ANCESTOR_HINT=$(api_error_hint "compare" "$NO_COMMON_ANCESTOR_STATUS" "$NO_COMMON_ANCESTOR_MESSAGE")
          echo "    ⚠️ 分支无共同祖先,按 Discard commits 处理"
          log_event "$FORK_REPO" "compare" "no_common_ancestor" \
            branch="$branch" reason="$NO_COMMON_ANCESTOR_REASON" context="compare" \
            api_path="$COMPARE_API" api_status="$NO_COMMON_ANCESTOR_STATUS" \
            api_message="$NO_COMMON_ANCESTOR_MESSAGE" hint="$NO_COMMON_ANCESTOR_HINT"
          local ORPHAN_BACKUP_BRANCH ORPHAN_BACKUP_OUT ORPHAN_BACKUP_ERR ORPHAN_BACKUP_API
          local ORPHAN_DISCARD_OUT ORPHAN_DISCARD_ERR ORPHAN_DISCARD_API ORPHAN_VERIFY_SHA ORPHAN_VERIFY_ERR ORPHAN_VERIFY_API
          ORPHAN_BACKUP_BRANCH="local-backup/${branch}-$(date +%Y%m%d-%H%M%S)-${FORK_SHA:0:7}"
          ORPHAN_BACKUP_API="repos/$FORK_OWNER/$FORK_REPO/git/refs"
          if gh_api_write_capture ORPHAN_BACKUP_OUT ORPHAN_BACKUP_ERR -X POST "$ORPHAN_BACKUP_API" \
               -f ref="refs/heads/$ORPHAN_BACKUP_BRANCH" \
               -f sha="$FORK_SHA" >/dev/null 2>&1; then
            echo "    📦 无共同祖先备份: $ORPHAN_BACKUP_BRANCH"
            LOCAL_BACKED_UP+=("$branch:$ORPHAN_BACKUP_BRANCH")
            log_event "$FORK_REPO" "local_backup" "ok" branch="$branch" backup_branch="$ORPHAN_BACKUP_BRANCH" reason="无共同祖先备份"

            ORPHAN_DISCARD_API="repos/$FORK_OWNER/$FORK_REPO/git/refs/heads/$branch"
            if gh_api_write_capture ORPHAN_DISCARD_OUT ORPHAN_DISCARD_ERR -X PATCH "$ORPHAN_DISCARD_API" \
                 -f sha="$UPSTREAM_SHA" -F force=true >/dev/null; then
              if [ "${DRY_RUN:-false}" = "true" ]; then
                echo "    [DRY-RUN] 会 Discard commits: 无共同祖先 → ${UPSTREAM_SHA:0:7}"
                SYNCED+=("$branch")
                log_event "$FORK_REPO" "sync_branch" "dry_run" branch="$branch" mode="discard_no_common_ancestor" upstream_sha="${UPSTREAM_SHA:0:7}" backup_branch="$ORPHAN_BACKUP_BRANCH" reason="$NO_COMMON_ANCESTOR_REASON"
                continue
              fi
              ORPHAN_VERIFY_API="repos/$FORK_OWNER/$FORK_REPO/git/ref/heads/$branch"
              if verify_fork_ref_sha "$branch" "$UPSTREAM_SHA" ORPHAN_VERIFY_SHA ORPHAN_VERIFY_ERR; then
                echo "    ⏩ Discard commits: 无共同祖先 → ${UPSTREAM_SHA:0:7}"
                SYNCED+=("$branch")
                log_event "$FORK_REPO" "sync_branch" "ok" branch="$branch" mode="discard_no_common_ancestor" upstream_sha="${UPSTREAM_SHA:0:7}" backup_branch="$ORPHAN_BACKUP_BRANCH"
              else
                echo "    ❌ Discard commits 校验失败: fork=${ORPHAN_VERIFY_SHA:0:7}, upstream=${UPSTREAM_SHA:0:7}"
                if [ -n "$ORPHAN_VERIFY_ERR" ]; then
                  record_failure "$branch" "$NO_COMMON_ANCESTOR_REASON; Discard commits 后校验失败" "verify_ref" "$ORPHAN_VERIFY_API" "$ORPHAN_VERIFY_ERR" "discard_no_common_ancestor"
                else
                  record_failure "$branch" "$NO_COMMON_ANCESTOR_REASON; 同步后 SHA 不一致: fork=${ORPHAN_VERIFY_SHA:0:7}, upstream=${UPSTREAM_SHA:0:7}" "compare" "$COMPARE_API" "$COMPARE_ERR" "discard_no_common_ancestor"
                fi
              fi
            else
              echo "    ❌ 无共同祖先 Discard commits 失败"
              record_failure "$branch" "$NO_COMMON_ANCESTOR_REASON; PATCH force update 失败" "discard" "$ORPHAN_DISCARD_API" "$ORPHAN_DISCARD_ERR" "discard_no_common_ancestor"
            fi
          else
            echo "    🛑 无共同祖先备份分支创建失败,跳过该分支同步"
            log_event "$FORK_REPO" "local_backup" "fail" branch="$branch" backup_branch="$ORPHAN_BACKUP_BRANCH" reason="无共同祖先备份分支创建失败" api_message="$(api_error_message "$ORPHAN_BACKUP_ERR")" api_status="$(api_error_field "$ORPHAN_BACKUP_ERR" "status")"
            record_failure "$branch" "$NO_COMMON_ANCESTOR_REASON; 备份未完成" "backup_ref" "$ORPHAN_BACKUP_API" "$ORPHAN_BACKUP_ERR" "discard_no_common_ancestor"
          fi
        else
          record_failure "$branch" "compare 异常" "compare" "$COMPARE_API" "$COMPARE_ERR" "auto"
        fi
        ;;
    esac
  done <<< "$UPSTREAM_BRANCH_LIST"

  # ----- 阶段 4: 清理旧 backup tag -----
  local KEPT=20
  local TAGS
  TAGS=$(gh_api_with_retry "repos/$FORK_OWNER/$FORK_REPO/git/refs/tags" \
         --jq '.[] | .ref' 2>/dev/null \
         | sed 's|refs/tags/||' \
         | grep '^backup/' || true)
  local TAG_COUNT
  if [ -n "$TAGS" ]; then
    TAG_COUNT=$(printf '%s\n' "$TAGS" | grep -c .)
  else
    TAG_COUNT=0
  fi
  if [ "$TAG_COUNT" -gt "$KEPT" ]; then
    echo "  🗑️ 清理旧 backup tag ($TAG_COUNT → 保留 $KEPT)"
    echo "$TAGS" | tail -n +$((KEPT+1)) | while read -r tag; do
      [ -z "$tag" ] && continue
      gh_api_write -X DELETE "repos/$FORK_OWNER/$FORK_REPO/git/refs/tags/$tag" \
        >/dev/null 2>&1 && echo "    - $tag"
    done
  fi

  # ----- 阶段 5: 单 fork 汇总 -----
  write_fork_summary "ok"
}
