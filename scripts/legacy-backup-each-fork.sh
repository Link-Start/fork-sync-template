#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/github-api.sh"

LOG_DIR=$(mktemp -d)
trap 'rm -rf "$LOG_DIR"' EXIT

: > "${RUNNER_TEMP:-/tmp}/legacy-backup-events.jsonl"
: > "${RUNNER_TEMP:-/tmp}/legacy-backup-summary.jsonl"

csv_lines() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || true
}

repo_in_csv() {
  local list="$1" fork_owner="$2" fork_name="$3"
  [ -z "$list" ] && return 1
  csv_lines "$list" | grep -Fxq "*" && return 0
  csv_lines "$list" | grep -Fxq "$fork_name" && return 0
  csv_lines "$list" | grep -Fxq "$fork_owner/$fork_name"
}

safe_branch_component() {
  local value="$1"
  value=$(printf '%s' "$value" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  printf '%s' "${value:-fork}"
}

parse_repo_full_name() {
  local input="$1" default_owner="$2"
  case "$input" in
    */*) printf '%s\n' "$input" ;;
    *) printf '%s/%s\n' "$default_owner" "$input" ;;
  esac
}

json_log() {
  local fork="$1" action="$2" result="$3"
  shift 3
  local json ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  json=$(jq -n -c \
    --arg ts "$ts" \
    --arg fork "$fork" \
    --arg action "$action" \
    --arg result "$result" \
    --arg run_id "${GITHUB_RUN_ID:-local}" \
    '{ts: $ts, fork: $fork, action: $action, result: $result, run_id: $run_id}')
  for kv in "$@"; do
    local key="${kv%%=*}"
    local value="${kv#*=}"
    json=$(echo "$json" | jq -c --arg key "$key" --arg value "$value" '. + {($key): $value}')
  done
  echo "$json" >> "${RUNNER_TEMP:-/tmp}/legacy-backup-events.jsonl"
}

ensure_legacy_repo() {
  local repo_full="$1"
  local legacy_owner="${repo_full%%/*}"
  local legacy_repo="${repo_full#*/}"
  local repo_out repo_err backup_login login_err

  if with_gh_token "${BACKUP_GH_TOKEN:-}" gh_api_capture repo_out repo_err "repos/$repo_full" --jq '.full_name' >/dev/null; then
    printf '%s\n' "$repo_full"
    return 0
  fi

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[DRY-RUN] centralized backup repo is not accessible; actual run would create private repo: $repo_full" >&2
    printf '%s\n' "$repo_full"
    return 0
  fi

  if ! with_gh_token "${BACKUP_GH_TOKEN:-}" gh_api_capture backup_login login_err "user" --jq '.login' >/dev/null || \
     [ "$backup_login" != "$legacy_owner" ]; then
    echo "::error::cannot access or create centralized backup repo $repo_full; BACKUP_GH_TOKEN authenticates as '${backup_login:-unknown}'" >&2
    return 1
  fi

  echo "+ create private centralized backup repo: $repo_full" >&2
  if ! with_gh_token "$BACKUP_GH_TOKEN" gh_api_capture repo_out repo_err "user/repos" \
      -X POST \
      -f name="$legacy_repo" \
      -f private=true \
      -f has_issues=false \
      -f has_wiki=false \
      -f auto_init=false \
      -f description="Centralized default-branch fork backups" \
      --jq '.full_name' >/dev/null; then
    echo "::error::create failed for $repo_full: $(api_error_message "$repo_err")" >&2
    return 1
  fi
  if [ "$repo_out" != "$repo_full" ]; then
    echo "::error::create returned unexpected repo: ${repo_out:-unknown}" >&2
    return 1
  fi
  printf '%s\n' "$repo_full"
}

write_summary() {
  local name="$1" result="$2" reason="$3" legacy_repo="$4" legacy_branch="$5" sha="$6"
  jq -n -c \
    --arg name "$name" \
    --arg result "$result" \
    --arg reason "$reason" \
    --arg legacy_repo "$legacy_repo" \
    --arg legacy_branch "$legacy_branch" \
    --arg sha "$sha" \
    '{name: $name, result: $result, reason: $reason, legacy_backup_repo: $legacy_repo, legacy_backup_branch: $legacy_branch, sha: $sha}' \
    >> "${RUNNER_TEMP:-/tmp}/legacy-backup-summary.jsonl"
}

process_legacy_backup_fork() {
  local fork_b64="$1" legacy_full="$2"
  local fork_json fork_name fork_owner fork_default fork_sha fork_sha_err fork_sha_api
  local branch_prefix safe_name primary_branch target_branch tmp source_auth_header backup_auth_header
  local existing_sha existing_err timestamp push_err verify_ref legacy_owner legacy_repo

  fork_json=$(printf '%s' "$fork_b64" | base64 -d 2>/dev/null || echo "")
  if [ -z "$fork_json" ] || ! echo "$fork_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::warning::invalid fork payload, skipped"
    return 0
  fi

  fork_name=$(echo "$fork_json" | jq -r '.name')
  fork_owner=$(echo "$fork_json" | jq -r '.fork_owner // env.MY_OWNER')
  fork_default=$(echo "$fork_json" | jq -r '.fork_default_branch // "main"')
  exec > "$LOG_DIR/$fork_name.log" 2>&1

  if ! repo_in_csv "${LEGACY_BACKUP_REPOS:-}" "$fork_owner" "$fork_name"; then
    echo "Skipping centralized backup for $fork_owner/$fork_name: not in LEGACY_BACKUP_REPOS"
    json_log "$fork_name" "legacy_backup" "skip" reason="not in LEGACY_BACKUP_REPOS"
    write_summary "$fork_name" "skip" "not in LEGACY_BACKUP_REPOS" "$legacy_full" "" ""
    return 0
  fi

  echo "------------------------------------------"
  echo "Centralized default-branch backup: $fork_owner/$fork_name:$fork_default"
  echo "------------------------------------------"

  fork_sha_api="repos/$fork_owner/$fork_name/git/ref/heads/$fork_default"
  if ! gh_api_capture fork_sha fork_sha_err "$fork_sha_api" --jq '.object.sha'; then
    fork_sha=""
  fi
  if [ -z "$fork_sha" ]; then
    echo "    ! fork default branch is not readable: $fork_default"
    json_log "$fork_name" "legacy_backup" "fail" reason="fork default branch is not readable" branch="$fork_default" legacy_backup_repo="$legacy_full"
    write_summary "$fork_name" "fail" "fork default branch is not readable" "$legacy_full" "" ""
    return 0
  fi

  branch_prefix=$(printf '%s' "${LEGACY_BACKUP_BRANCH_PREFIX:-legacy}" | sed -E 's#^/+##; s#/+$##')
  branch_prefix=${branch_prefix:-legacy}
  safe_name=$(safe_branch_component "$fork_name")
  primary_branch="$branch_prefix/$safe_name"
  target_branch="$primary_branch"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "    [DRY-RUN] would back up $fork_owner/$fork_name:$fork_default -> $legacy_full:$primary_branch (${fork_sha:0:7})"
    json_log "$fork_name" "legacy_backup" "dry_run" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$primary_branch" sha="${fork_sha:0:7}"
    write_summary "$fork_name" "dry_run" "" "$legacy_full" "$primary_branch" "$fork_sha"
    return 0
  fi

  legacy_owner=${legacy_full%%/*}
  legacy_repo=${legacy_full#*/}
  tmp=$(mktemp -d) || return 1
  push_err="$tmp/push.err"
  source_auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64 | tr -d '\n')"
  backup_auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${BACKUP_GH_TOKEN:-$GH_TOKEN}" | base64 | tr -d '\n')"

  if ! git -C "$tmp" init -q || \
     ! git -C "$tmp" remote add fork "https://github.com/$fork_owner/$fork_name.git" || \
     ! git -C "$tmp" remote add legacy "https://github.com/$legacy_owner/$legacy_repo.git" || \
     ! git -C "$tmp" -c credential.helper= -c http.extraheader="$source_auth_header" fetch --quiet --no-tags fork "refs/heads/$fork_default:refs/sync/current"; then
    rm -rf "$tmp"
    echo "    ! fetch failed: $fork_owner/$fork_name:$fork_default"
    json_log "$fork_name" "legacy_backup" "fail" reason="fetch failed" branch="$fork_default" legacy_backup_repo="$legacy_full"
    write_summary "$fork_name" "fail" "fetch failed" "$legacy_full" "$target_branch" "$fork_sha"
    return 0
  fi

  if with_gh_token "${BACKUP_GH_TOKEN:-}" gh_api_capture existing_sha existing_err "repos/$legacy_owner/$legacy_repo/git/ref/heads/$primary_branch" --jq '.object.sha'; then
    if git -C "$tmp" -c credential.helper= -c http.extraheader="$backup_auth_header" fetch --quiet --no-tags legacy "refs/heads/$primary_branch:refs/sync/legacy"; then
      if git -C "$tmp" merge-base --is-ancestor refs/sync/current refs/sync/legacy; then
        echo "    centralized backup already contains current HEAD: $legacy_full:$primary_branch -> ${fork_sha:0:7}"
        json_log "$fork_name" "legacy_backup" "skip" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$primary_branch" sha="${fork_sha:0:7}" reason="existing centralized backup contains current HEAD"
        write_summary "$fork_name" "skip" "existing centralized backup contains current HEAD" "$legacy_full" "$primary_branch" "$fork_sha"
        rm -rf "$tmp"
        return 0
      fi
      if ! git -C "$tmp" merge-base --is-ancestor refs/sync/legacy refs/sync/current; then
        timestamp=$(date +%Y%m%d-%H%M%S)
        target_branch="$branch_prefix/${safe_name}-${timestamp}-${fork_sha:0:7}"
        echo "    primary backup branch cannot fast-forward; using timestamp branch: $target_branch"
      fi
    else
      timestamp=$(date +%Y%m%d-%H%M%S)
      target_branch="$branch_prefix/${safe_name}-${timestamp}-${fork_sha:0:7}"
      echo "    existing primary branch cannot be fetched; using timestamp branch: $target_branch"
    fi
  fi

  if ! git -C "$tmp" -c credential.helper= -c http.extraheader="$backup_auth_header" push --quiet legacy "refs/sync/current:refs/heads/$target_branch" 2>"$push_err"; then
    echo "    ! push failed: $legacy_full:$target_branch"
    json_log "$fork_name" "legacy_backup" "fail" reason="push failed" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$target_branch"
    write_summary "$fork_name" "fail" "push failed" "$legacy_full" "$target_branch" "$fork_sha"
    rm -rf "$tmp"
    return 0
  fi

  verify_ref="refs/sync/verify-${fork_sha:0:7}"
  if ! git -C "$tmp" -c credential.helper= -c http.extraheader="$backup_auth_header" fetch --quiet --no-tags legacy "refs/heads/$target_branch:$verify_ref" || \
     ! git -C "$tmp" merge-base --is-ancestor refs/sync/current "$verify_ref"; then
    echo "    ! verification failed: $legacy_full:$target_branch does not contain current HEAD"
    json_log "$fork_name" "legacy_backup" "fail" reason="verification failed" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$target_branch"
    write_summary "$fork_name" "fail" "verification failed" "$legacy_full" "$target_branch" "$fork_sha"
    rm -rf "$tmp"
    return 0
  fi

  echo "    centralized backup complete: $legacy_full:$target_branch -> ${fork_sha:0:7}"
  json_log "$fork_name" "legacy_backup" "ok" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$target_branch" sha="${fork_sha:0:7}"
  write_summary "$fork_name" "ok" "" "$legacy_full" "$target_branch" "$fork_sha"
  rm -rf "$tmp"
}

if ! echo "${FORKS:-}" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "::error::FORKS must be a JSON array"
  exit 1
fi

if [ -z "${LEGACY_BACKUP_REPOS:-}" ]; then
  echo "No centralized backup targets configured"
  exit 0
fi

if [ -z "${LEGACY_BACKUP_REPO:-}" ]; then
  echo "::error::LEGACY_BACKUP_REPO is required when LEGACY_BACKUP_REPOS is set"
  exit 1
fi

fork_count=$(echo "$FORKS" | jq length)
if [ "$fork_count" -eq 0 ]; then
  echo "No forks to back up"
  exit 0
fi

legacy_full=$(parse_repo_full_name "$LEGACY_BACKUP_REPO" "$MY_OWNER")
if ! legacy_full=$(ensure_legacy_repo "$legacy_full"); then
  exit 1
fi

echo "Centralized default-branch backup targets: $fork_count fork(s)"
while IFS= read -r fork_b64; do
  [ -z "$fork_b64" ] && continue
  ( process_legacy_backup_fork "$fork_b64" "$legacy_full" )
done < <(echo "$FORKS" | jq -r '.[] | @base64')

echo "$FORKS" | jq -r '.[].name' | while read -r name; do
  if [ -f "$LOG_DIR/$name.log" ]; then
    cat "$LOG_DIR/$name.log"
  fi
done

echo ""
echo "------------------------------------------"
echo "Centralized backup events"
echo "------------------------------------------"
if [ -s "${RUNNER_TEMP:-/tmp}/legacy-backup-events.jsonl" ]; then
  cat "${RUNNER_TEMP:-/tmp}/legacy-backup-events.jsonl"
fi

failed=$(jq -s '[.[] | select(.result == "fail")] | length' "${RUNNER_TEMP:-/tmp}/legacy-backup-summary.jsonl" 2>/dev/null || echo 0)
if [ "$failed" -gt 0 ]; then
  echo "::error::centralized backup failed for $failed fork(s)"
  exit 1
fi
