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
  local mode="${7:-}" detail="${8:-}"
  jq -n -c \
    --arg name "$name" \
    --arg result "$result" \
    --arg reason "$reason" \
    --arg legacy_repo "$legacy_repo" \
    --arg legacy_branch "$legacy_branch" \
    --arg sha "$sha" \
    --arg mode "$mode" \
    --arg detail "$detail" \
    '{name: $name, result: $result, reason: $reason, legacy_backup_repo: $legacy_repo, legacy_backup_branch: $legacy_branch, sha: $sha, mode: $mode, detail: $detail}' \
    >> "${RUNNER_TEMP:-/tmp}/legacy-backup-summary.jsonl"
}

git_error_detail() {
  local path="$1"
  [ -s "$path" ] || return 0
  sed -E \
    -e 's#x-access-token:[^@[:space:]]+#x-access-token:***#g' \
    -e 's#https://[^@[:space:]]+@github.com/#https://***@github.com/#g' \
    "$path" \
    | tail -20 \
    | tr '\r\n' ' ' \
    | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | cut -c 1-500
}

snapshot_batch_limit_bytes() {
  local value="${LEGACY_BACKUP_SNAPSHOT_BATCH_BYTES:-10485760}"
  if ! printf '%s' "$value" | grep -Eq '^[1-9][0-9]*$'; then
    value=10485760
  fi
  printf '%s' "$value"
}

snapshot_direct_size_threshold_kb() {
  local value="${LEGACY_BACKUP_SNAPSHOT_DIRECT_SIZE_KB:-1048576}"
  if ! printf '%s' "$value" | grep -Eq '^[0-9]+$'; then
    value=1048576
  fi
  printf '%s' "$value"
}

git_transport_config() {
  printf '%s\n' \
    -c credential.helper= \
    -c http.version=HTTP/1.1 \
    -c http.postBuffer=157286400
}

commit_snapshot_batch() {
  local repo_dir="$1" target_branch="$2" auth_header="$3" batch_no="$4" source_label="$5"
  if git -C "$repo_dir" diff --cached --quiet; then
    return 0
  fi

  git -C "$repo_dir" commit -q \
    -m "Snapshot backup for $source_label" \
    -m "Batch: $batch_no" \
    -m "This branch is a source-tree fallback because GitHub rejected the original history push."
  git -C "$repo_dir" \
    $(git_transport_config) \
    -c http.extraheader="$auth_header" \
    push --quiet legacy "HEAD:refs/heads/$target_branch"
}

create_snapshot_backup() {
  local source_repo_dir="$1" source_ref="$2" legacy_full="$3" requested_branch="$4"
  local fork_owner="$5" fork_name="$6" fork_default="$7" fork_sha="$8" auth_header="$9" original_detail="${10:-}"
  local update_existing="${11:-false}"
  local legacy_owner legacy_repo snapshot_dir snapshot_branch timestamp source_tree backup_tree verify_ref
  local batch_limit batch_bytes batch_files batch_no path rel size push_err detail source_label
  local existing_sha existing_err
  local target_exists=false

  legacy_owner=${legacy_full%%/*}
  legacy_repo=${legacy_full#*/}
  snapshot_branch="$requested_branch"

  # Do not overwrite an existing unrelated backup branch with fallback history.
  if with_gh_token "${BACKUP_GH_TOKEN:-}" gh_api_capture existing_sha existing_err "repos/$legacy_owner/$legacy_repo/git/ref/heads/$snapshot_branch" --jq '.object.sha' >/dev/null; then
    if [ "$update_existing" = "true" ]; then
      target_exists=true
      echo "    fallback target exists; updating source-tree snapshot branch: $snapshot_branch"
    else
      timestamp=$(date +%Y%m%d-%H%M%S)
      snapshot_branch="${requested_branch}-${timestamp}-snapshot-${fork_sha:0:7}"
      echo "    fallback target already exists; using snapshot branch: $snapshot_branch"
    fi
  fi

  snapshot_dir="$source_repo_dir/snapshot-worktree"
  mkdir -p "$snapshot_dir"
  git -C "$snapshot_dir" init -q
  git -C "$snapshot_dir" config user.name "fork-sync backup"
  git -C "$snapshot_dir" config user.email "fork-sync-backup@users.noreply.github.com"
  git -C "$snapshot_dir" config core.autocrlf false
  git -C "$snapshot_dir" remote add legacy "https://github.com/$legacy_owner/$legacy_repo.git"

  if [ "$target_exists" = "true" ]; then
    if git -C "$snapshot_dir" $(git_transport_config) -c http.extraheader="$auth_header" fetch --quiet --no-tags legacy "refs/heads/$snapshot_branch:refs/remotes/legacy/snapshot-base" && \
       git -C "$snapshot_dir" checkout -q -B snapshot refs/remotes/legacy/snapshot-base; then
      find "$snapshot_dir" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
    else
      timestamp=$(date +%Y%m%d-%H%M%S)
      snapshot_branch="${requested_branch}-${timestamp}-snapshot-${fork_sha:0:7}"
      target_exists=false
      echo "    existing snapshot branch cannot be fetched; using snapshot branch: $snapshot_branch"
      git -C "$snapshot_dir" checkout -q -b snapshot
    fi
  else
    git -C "$snapshot_dir" checkout -q -b snapshot
  fi

  if ! git -C "$source_repo_dir" archive --format=tar "$source_ref" | LC_ALL=C tar -xf - -C "$snapshot_dir"; then
    echo "    ! snapshot fallback failed: source tree export failed"
    return 1
  fi

  batch_limit=$(snapshot_batch_limit_bytes)
  batch_bytes=0
  batch_files=0
  batch_no=1
  source_label="$fork_owner/$fork_name:$fork_default@$fork_sha"
  push_err="$source_repo_dir/snapshot-push.err"
  : > "$push_err"

  echo "    full-history push failed; writing source-tree snapshot in batches: $legacy_full:$snapshot_branch"
  echo "    snapshot batch limit: $batch_limit bytes"

  while IFS= read -r -d '' path; do
    rel=${path#./}
    [ -n "$rel" ] || continue
    if [ -L "$snapshot_dir/$rel" ]; then
      size=0
    else
      size=$(wc -c < "$snapshot_dir/$rel" | tr -d ' ')
    fi
    if [ "$batch_files" -gt 0 ] && [ $((batch_bytes + size)) -gt "$batch_limit" ]; then
      echo "      snapshot batch $batch_no: $batch_files file(s), $batch_bytes byte(s)"
      if ! commit_snapshot_batch "$snapshot_dir" "$snapshot_branch" "$auth_header" "$batch_no" "$source_label" 2>"$push_err"; then
        detail=$(git_error_detail "$push_err")
        echo "    ! snapshot fallback push failed: ${detail:-unknown git error}"
        return 1
      fi
      batch_no=$((batch_no + 1))
      batch_bytes=0
      batch_files=0
    fi

    git -C "$snapshot_dir" add -f -- "$rel"
    batch_bytes=$((batch_bytes + size))
    batch_files=$((batch_files + 1))
    if [ "$batch_bytes" -ge "$batch_limit" ]; then
      echo "      snapshot batch $batch_no: $batch_files file(s), $batch_bytes byte(s)"
      if ! commit_snapshot_batch "$snapshot_dir" "$snapshot_branch" "$auth_header" "$batch_no" "$source_label" 2>"$push_err"; then
        detail=$(git_error_detail "$push_err")
        echo "    ! snapshot fallback push failed: ${detail:-unknown git error}"
        return 1
      fi
      batch_no=$((batch_no + 1))
      batch_bytes=0
      batch_files=0
    fi
  done < <(cd "$snapshot_dir" && find . -path ./.git -prune -o \( -type f -o -type l \) -print0)

  git -C "$snapshot_dir" add -A
  if ! git -C "$snapshot_dir" diff --cached --quiet; then
    echo "      snapshot batch $batch_no: $batch_files file(s), $batch_bytes byte(s)"
    if ! commit_snapshot_batch "$snapshot_dir" "$snapshot_branch" "$auth_header" "$batch_no" "$source_label" 2>"$push_err"; then
      detail=$(git_error_detail "$push_err")
      echo "    ! snapshot fallback push failed: ${detail:-unknown git error}"
      return 1
    fi
  fi

  source_tree=$(git -C "$source_repo_dir" rev-parse "$source_ref^{tree}")
  verify_ref="refs/sync/verify-snapshot-${fork_sha:0:7}"
  if ! git -C "$source_repo_dir" $(git_transport_config) -c http.extraheader="$auth_header" fetch --quiet --no-tags legacy "refs/heads/$snapshot_branch:$verify_ref" || \
     ! backup_tree=$(git -C "$source_repo_dir" rev-parse "$verify_ref^{tree}") || \
     [ "$source_tree" != "$backup_tree" ]; then
    echo "    ! snapshot fallback verification failed: tree hash mismatch"
    return 1
  fi

  echo "    snapshot fallback complete: $legacy_full:$snapshot_branch -> source tree ${fork_sha:0:7}"
  json_log "$fork_name" "legacy_backup" "ok" \
    branch="$fork_default" \
    legacy_backup_repo="$legacy_full" \
    legacy_backup_branch="$snapshot_branch" \
    sha="${fork_sha:0:7}" \
    mode="source_tree_snapshot" \
    reason="full-history push failed; source-tree snapshot fallback used" \
    detail="$original_detail"
  write_summary "$fork_name" "ok" "full-history push failed; source-tree snapshot fallback used" "$legacy_full" "$snapshot_branch" "$fork_sha" "source_tree_snapshot" "$original_detail"
  return 0
}

process_legacy_backup_fork() {
  local fork_b64="$1" legacy_full="$2"
  local fork_json fork_name fork_owner fork_default fork_size fork_sha fork_sha_err fork_sha_api
  local branch_prefix safe_name primary_branch target_branch tmp source_auth_header backup_auth_header
  local existing_sha existing_err timestamp push_err push_detail verify_ref legacy_owner legacy_repo
  local current_tree legacy_tree direct_snapshot_threshold direct_snapshot_fetch fetch_args

  fork_json=$(printf '%s' "$fork_b64" | base64 -d 2>/dev/null || echo "")
  if [ -z "$fork_json" ] || ! echo "$fork_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::warning::invalid fork payload, skipped"
    return 0
  fi

  fork_name=$(echo "$fork_json" | jq -r '.name')
  fork_owner=$(echo "$fork_json" | jq -r '.fork_owner // env.MY_OWNER')
  fork_default=$(echo "$fork_json" | jq -r '.fork_default_branch // "main"')
  fork_size=$(echo "$fork_json" | jq -r '.fork_size // 0')
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
  direct_snapshot_threshold=$(snapshot_direct_size_threshold_kb)
  direct_snapshot_fetch=false
  fetch_args=(--quiet --no-tags)
  if [ "$direct_snapshot_threshold" -gt 0 ] && [ "$fork_size" -ge "$direct_snapshot_threshold" ] 2>/dev/null; then
    direct_snapshot_fetch=true
    fetch_args=(--quiet --no-tags --depth=1)
  fi

  if ! git -C "$tmp" init -q || \
     ! git -C "$tmp" remote add fork "https://github.com/$fork_owner/$fork_name.git" || \
     ! git -C "$tmp" remote add legacy "https://github.com/$legacy_owner/$legacy_repo.git" || \
     ! git -C "$tmp" -c credential.helper= -c http.extraheader="$source_auth_header" fetch "${fetch_args[@]}" fork "refs/heads/$fork_default:refs/sync/current"; then
    rm -rf "$tmp"
    echo "    ! fetch failed: $fork_owner/$fork_name:$fork_default"
    json_log "$fork_name" "legacy_backup" "fail" reason="fetch failed" branch="$fork_default" legacy_backup_repo="$legacy_full"
    write_summary "$fork_name" "fail" "fetch failed" "$legacy_full" "$target_branch" "$fork_sha"
    return 0
  fi

  if with_gh_token "${BACKUP_GH_TOKEN:-}" gh_api_capture existing_sha existing_err "repos/$legacy_owner/$legacy_repo/git/ref/heads/$primary_branch" --jq '.object.sha'; then
      if git -C "$tmp" $(git_transport_config) -c http.extraheader="$backup_auth_header" fetch --quiet --no-tags legacy "refs/heads/$primary_branch:refs/sync/legacy"; then
      current_tree=$(git -C "$tmp" rev-parse refs/sync/current^{tree})
      legacy_tree=$(git -C "$tmp" rev-parse refs/sync/legacy^{tree})
      if [ "$current_tree" = "$legacy_tree" ]; then
        echo "    centralized backup already contains current source tree: $legacy_full:$primary_branch -> ${fork_sha:0:7}"
        json_log "$fork_name" "legacy_backup" "skip" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$primary_branch" sha="${fork_sha:0:7}" reason="existing centralized backup contains current source tree" mode="source_tree_match"
        write_summary "$fork_name" "skip" "existing centralized backup contains current source tree" "$legacy_full" "$primary_branch" "$fork_sha" "source_tree_match" ""
        rm -rf "$tmp"
        return 0
      fi
      if [ "$direct_snapshot_fetch" = "true" ]; then
        echo "    fork size ${fork_size}KB exceeds direct snapshot threshold ${direct_snapshot_threshold}KB; updating source-tree snapshot"
        if create_snapshot_backup "$tmp" "refs/sync/current" "$legacy_full" "$primary_branch" "$fork_owner" "$fork_name" "$fork_default" "$fork_sha" "$backup_auth_header" "fork size ${fork_size}KB exceeds direct snapshot threshold" true; then
          rm -rf "$tmp"
          return 0
        fi
        json_log "$fork_name" "legacy_backup" "fail" reason="snapshot fallback failed" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$primary_branch" detail="fork size ${fork_size}KB exceeds direct snapshot threshold"
        write_summary "$fork_name" "fail" "snapshot fallback failed" "$legacy_full" "$primary_branch" "$fork_sha" "source_tree_snapshot" "fork size ${fork_size}KB exceeds direct snapshot threshold"
        rm -rf "$tmp"
        return 0
      fi
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

  if [ "$direct_snapshot_fetch" = "true" ]; then
    echo "    fork size ${fork_size}KB exceeds direct snapshot threshold ${direct_snapshot_threshold}KB; writing source-tree snapshot"
    if create_snapshot_backup "$tmp" "refs/sync/current" "$legacy_full" "$primary_branch" "$fork_owner" "$fork_name" "$fork_default" "$fork_sha" "$backup_auth_header" "fork size ${fork_size}KB exceeds direct snapshot threshold" true; then
      rm -rf "$tmp"
      return 0
    fi
    json_log "$fork_name" "legacy_backup" "fail" reason="snapshot fallback failed" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$primary_branch" detail="fork size ${fork_size}KB exceeds direct snapshot threshold"
    write_summary "$fork_name" "fail" "snapshot fallback failed" "$legacy_full" "$primary_branch" "$fork_sha" "source_tree_snapshot" "fork size ${fork_size}KB exceeds direct snapshot threshold"
    rm -rf "$tmp"
    return 0
  fi

  if ! git -C "$tmp" $(git_transport_config) -c http.extraheader="$backup_auth_header" push --quiet legacy "refs/sync/current:refs/heads/$target_branch" 2>"$push_err"; then
    push_detail=$(git_error_detail "$push_err")
    echo "    ! push failed: $legacy_full:$target_branch"
    [ -z "$push_detail" ] || echo "      $push_detail"
    if create_snapshot_backup "$tmp" "refs/sync/current" "$legacy_full" "$target_branch" "$fork_owner" "$fork_name" "$fork_default" "$fork_sha" "$backup_auth_header" "$push_detail"; then
      rm -rf "$tmp"
      return 0
    fi
    json_log "$fork_name" "legacy_backup" "fail" reason="push failed" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$target_branch" detail="$push_detail"
    write_summary "$fork_name" "fail" "push failed" "$legacy_full" "$target_branch" "$fork_sha" "full_history" "$push_detail"
    rm -rf "$tmp"
    return 0
  fi

  verify_ref="refs/sync/verify-${fork_sha:0:7}"
  if ! git -C "$tmp" $(git_transport_config) -c http.extraheader="$backup_auth_header" fetch --quiet --no-tags legacy "refs/heads/$target_branch:$verify_ref" || \
     ! git -C "$tmp" merge-base --is-ancestor refs/sync/current "$verify_ref"; then
    echo "    ! verification failed: $legacy_full:$target_branch does not contain current HEAD"
    json_log "$fork_name" "legacy_backup" "fail" reason="verification failed" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$target_branch"
    write_summary "$fork_name" "fail" "verification failed" "$legacy_full" "$target_branch" "$fork_sha"
    rm -rf "$tmp"
    return 0
  fi

  echo "    centralized backup complete: $legacy_full:$target_branch -> ${fork_sha:0:7}"
  json_log "$fork_name" "legacy_backup" "ok" branch="$fork_default" legacy_backup_repo="$legacy_full" legacy_backup_branch="$target_branch" sha="${fork_sha:0:7}"
  write_summary "$fork_name" "ok" "" "$legacy_full" "$target_branch" "$fork_sha" "full_history" ""
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
