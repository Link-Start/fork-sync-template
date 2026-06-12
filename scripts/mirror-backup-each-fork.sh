#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$SCRIPT_DIR/github-api.sh"

LOG_DIR=$(mktemp -d)
trap 'rm -rf "$LOG_DIR"' EXIT

: > "${RUNNER_TEMP:-/tmp}/mirror-backup-events.jsonl"
: > "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl"

csv_lines() {
  printf '%s' "$1" | tr ',' '\n' | sed 's/^ *//;s/ *$//' | grep -v '^$' || true
}

repo_in_csv() {
  local list="$1" fork_owner="$2" fork_name="$3"
  [ -z "$list" ] && return 0
  csv_lines "$list" | grep -Fxq "*" && return 0
  csv_lines "$list" | grep -Fxq "$fork_name" && return 0
  csv_lines "$list" | grep -Fxq "$fork_owner/$fork_name"
}

sanitize_ref_component() {
  local value="$1"
  value=$(printf '%s' "$value" | sed -E 's#^refs/heads/##; s#^refs/tags/##; s#[^A-Za-z0-9._/-]+#-#g; s#(^|/)[.]+#\1dot-#g; s#/[.]lock$#/dot-lock#g; s#[.]lock$#-lock#g; s#//+#/#g; s#^/+##; s#/+$##')
  printf '%s' "${value:-ref}"
}

sanitize_repo_name() {
  local value="$1"
  value=$(printf '%s' "$value" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  printf '%s' "${value:-fork-backup}"
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
  echo "$json" >> "${RUNNER_TEMP:-/tmp}/mirror-backup-events.jsonl"
}

ensure_backup_repo() {
  local repo_name="$1" description="$2"
  local repo_full="$MIRROR_BACKUP_OWNER/$repo_name"
  local repo_out repo_err backup_login login_err

  if with_gh_token "$BACKUP_GH_TOKEN" gh_api_capture repo_out repo_err "repos/$repo_full" --jq '.full_name' >/dev/null; then
    printf '%s\n' "$repo_full"
    return 0
  fi

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "    [DRY-RUN] would create private backup repo $repo_full" >&2
    printf '%s\n' "$repo_full"
    return 0
  fi

  if ! with_gh_token "$BACKUP_GH_TOKEN" gh_api_capture backup_login login_err "user" --jq '.login' >/dev/null || \
     [ "$backup_login" != "$MIRROR_BACKUP_OWNER" ]; then
    echo "    ! cannot auto-create $repo_full: BACKUP_GH_TOKEN authenticates as '${backup_login:-unknown}', expected '$MIRROR_BACKUP_OWNER'" >&2
    echo "      create the repo manually or use a token from $MIRROR_BACKUP_OWNER" >&2
    return 1
  fi

  echo "    + create private backup repo: $repo_full" >&2
  if ! with_gh_token "$BACKUP_GH_TOKEN" gh_api_capture repo_out repo_err "user/repos" \
      -X POST \
      -f name="$repo_name" \
      -f private=true \
      -f has_issues=false \
      -f has_wiki=false \
      -f auto_init=false \
      -f description="$description" \
      --jq '.full_name' >/dev/null; then
    echo "    ! create failed: $(api_error_message "$repo_err")" >&2
    return 1
  fi
  if [ "$repo_out" != "$repo_full" ]; then
    echo "    ! create returned unexpected repo: ${repo_out:-unknown}" >&2
    return 1
  fi
  printf '%s\n' "$repo_full"
}

write_push_script() {
  local path="$1" auth_header="$2"
  cat > "$path" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

repo_dir=$1
dest_remote=$2
snapshot_prefix=$3
current_prefix=$4
tag_prefix=$5
push_current=$6
auth_header=$7
summary_file=$8

: > "$summary_file"

while IFS= read -r refline; do
  src_ref=${refline#refs/heads/}
  dst_ref=$(printf '%s' "$src_ref" | sed -E 's#[^A-Za-z0-9._/-]+#-#g; s#(^|/)[.]+#\1dot-#g; s#/[.]lock$#/dot-lock#g; s#[.]lock$#-lock#g; s#//+#/#g; s#^/+##; s#/+$##')
  [ -z "$dst_ref" ] && dst_ref=branch
  git -C "$repo_dir" -c credential.helper= -c http.extraheader="$auth_header" push --quiet "$dest_remote" "$refline:refs/heads/$snapshot_prefix/$dst_ref"
  echo "branch snapshot $src_ref refs/heads/$snapshot_prefix/$dst_ref" >> "$summary_file"
  if [ "$push_current" = "true" ]; then
    git -C "$repo_dir" -c credential.helper= -c http.extraheader="$auth_header" push --quiet --force-with-lease "$dest_remote" "$refline:refs/heads/$current_prefix/$dst_ref"
    echo "branch current $src_ref refs/heads/$current_prefix/$dst_ref" >> "$summary_file"
  fi
done < <(git -C "$repo_dir" for-each-ref --format='%(refname)' refs/heads)

while IFS= read -r refline; do
  src_ref=${refline#refs/tags/}
  dst_ref=$(printf '%s' "$src_ref" | sed -E 's#[^A-Za-z0-9._/-]+#-#g; s#(^|/)[.]+#\1dot-#g; s#/[.]lock$#/dot-lock#g; s#[.]lock$#-lock#g; s#//+#/#g; s#^/+##; s#/+$##')
  [ -z "$dst_ref" ] && dst_ref=tag
  git -C "$repo_dir" -c credential.helper= -c http.extraheader="$auth_header" push --quiet "$dest_remote" "$refline:refs/tags/$tag_prefix/$dst_ref"
  echo "tag snapshot $src_ref refs/tags/$tag_prefix/$dst_ref" >> "$summary_file"
done < <(git -C "$repo_dir" for-each-ref --format='%(refname)' refs/tags)
SCRIPT
  chmod +x "$path"
}

process_backup_fork() {
  local fork_b64="$1"
  local fork_json fork_name fork_owner backup_repo_name backup_repo_full repo_url dest_url
  local tmp source_auth_header backup_auth_header snapshot_id snapshot_prefix current_prefix tag_prefix summary_file script_path
  local branch_count tag_count description push_current

  fork_json=$(printf '%s' "$fork_b64" | base64 -d 2>/dev/null || echo "")
  if [ -z "$fork_json" ] || ! echo "$fork_json" | jq -e 'type == "object"' >/dev/null 2>&1; then
    echo "::warning::invalid fork payload, skipped"
    return 0
  fi

  fork_name=$(echo "$fork_json" | jq -r '.name')
  fork_owner=$(echo "$fork_json" | jq -r '.fork_owner // env.MY_OWNER')
  exec > "$LOG_DIR/$fork_name.log" 2>&1

  if ! repo_in_csv "${MIRROR_BACKUP_REPOS:-}" "$fork_owner" "$fork_name"; then
    echo "Skipping full-ref backup for $fork_owner/$fork_name: not in MIRROR_BACKUP_REPOS"
    json_log "$fork_name" "mirror_backup" "skip" reason="not in MIRROR_BACKUP_REPOS"
    echo "{\"name\":\"$fork_name\",\"result\":\"skip\",\"reason\":\"not in MIRROR_BACKUP_REPOS\"}" >> "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl"
    return 0
  fi

  backup_repo_name="$(sanitize_repo_name "${MIRROR_BACKUP_REPO_PREFIX:-}${fork_name}${MIRROR_BACKUP_REPO_SUFFIX:-}")"
  description="Full ref backup for $fork_owner/$fork_name, managed by fork-sync-template"
  snapshot_id="$(date -u +%Y%m%d-%H%M%S)-${GITHUB_RUN_ID:-local}"
  snapshot_prefix="${MIRROR_BACKUP_SNAPSHOT_PREFIX:-snapshots}/$snapshot_id"
  current_prefix="${MIRROR_BACKUP_CURRENT_PREFIX:-current}"
  tag_prefix="${MIRROR_BACKUP_TAG_PREFIX:-backup}/$snapshot_id"
  push_current="${MIRROR_BACKUP_UPDATE_CURRENT:-true}"

  echo "------------------------------------------"
  echo "Full-ref backup: $fork_owner/$fork_name"
  echo "------------------------------------------"

  if [ -z "${BACKUP_GH_TOKEN:-}" ] && [ "${DRY_RUN:-false}" != "true" ]; then
    echo "    ! BACKUP_GH_TOKEN is required"
    json_log "$fork_name" "mirror_backup" "fail" reason="BACKUP_GH_TOKEN is required"
    echo "{\"name\":\"$fork_name\",\"result\":\"fail\",\"reason\":\"BACKUP_GH_TOKEN is required\"}" >> "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl"
    return 0
  fi

  if [ -z "${MIRROR_BACKUP_OWNER:-}" ]; then
    echo "    ! MIRROR_BACKUP_OWNER is required"
    json_log "$fork_name" "mirror_backup" "fail" reason="MIRROR_BACKUP_OWNER is required"
    echo "{\"name\":\"$fork_name\",\"result\":\"fail\",\"reason\":\"MIRROR_BACKUP_OWNER is required\"}" >> "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl"
    return 0
  fi

  if [ "${DRY_RUN:-false}" = "true" ]; then
    backup_repo_full="$MIRROR_BACKUP_OWNER/$backup_repo_name"
  elif ! backup_repo_full=$(ensure_backup_repo "$backup_repo_name" "$description"); then
    json_log "$fork_name" "mirror_backup" "fail" reason="create or access backup repo failed" backup_repo="$MIRROR_BACKUP_OWNER/$backup_repo_name"
    echo "{\"name\":\"$fork_name\",\"result\":\"fail\",\"reason\":\"create or access backup repo failed\"}" >> "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl"
    return 0
  fi

  repo_url="https://github.com/$fork_owner/$fork_name.git"
  dest_url="https://github.com/$backup_repo_full.git"
  tmp=$(mktemp -d)
  source_auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${GH_TOKEN:-dry-run}" | base64 | tr -d '\n')"
  backup_auth_header="AUTHORIZATION: basic $(printf 'x-access-token:%s' "${BACKUP_GH_TOKEN:-dry-run}" | base64 | tr -d '\n')"
  summary_file="$tmp/push-summary.txt"
  script_path="$tmp/push-refs.sh"

  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "    [DRY-RUN] would push snapshot refs to $backup_repo_full:$snapshot_prefix"
    json_log "$fork_name" "mirror_backup" "dry_run" backup_repo="$backup_repo_full" snapshot_prefix="$snapshot_prefix"
    echo "{\"name\":\"$fork_name\",\"result\":\"dry_run\",\"backup_repo\":\"$backup_repo_full\"}" >> "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl"
    rm -rf "$tmp"
    return 0
  fi

  if ! git -c credential.helper= -c http.extraheader="$source_auth_header" clone --mirror --quiet "$repo_url" "$tmp/source.git"; then
    echo "    ! clone failed: $repo_url"
    json_log "$fork_name" "mirror_backup" "fail" reason="clone failed" backup_repo="$backup_repo_full"
    echo "{\"name\":\"$fork_name\",\"result\":\"fail\",\"reason\":\"clone failed\"}" >> "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl"
    rm -rf "$tmp"
    return 0
  fi

  branch_count=$(git -C "$tmp/source.git" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')
  tag_count=$(git -C "$tmp/source.git" for-each-ref --format='%(refname)' refs/tags | wc -l | tr -d ' ')
  echo "    refs: $branch_count branches, $tag_count tags"
  echo "    backup repo: $backup_repo_full"
  echo "    snapshot prefix: refs/heads/$snapshot_prefix/*"

  write_push_script "$script_path" "$backup_auth_header"
  if ! "$script_path" "$tmp/source.git" "$dest_url" "$snapshot_prefix" "$current_prefix" "$tag_prefix" "$push_current" "$backup_auth_header" "$summary_file"; then
    echo "    ! push failed"
    json_log "$fork_name" "mirror_backup" "fail" reason="push failed" backup_repo="$backup_repo_full" branches="$branch_count" tags="$tag_count"
    echo "{\"name\":\"$fork_name\",\"result\":\"fail\",\"reason\":\"push failed\"}" >> "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl"
    rm -rf "$tmp"
    return 0
  fi

  echo "    pushed refs: $(wc -l < "$summary_file" | tr -d ' ')"
  json_log "$fork_name" "mirror_backup" "ok" backup_repo="$backup_repo_full" snapshot_prefix="$snapshot_prefix" tag_prefix="$tag_prefix" branches="$branch_count" tags="$tag_count"
  jq -n -c \
    --arg name "$fork_name" \
    --arg result "ok" \
    --arg backup_repo "$backup_repo_full" \
    --arg snapshot_prefix "$snapshot_prefix" \
    --argjson branches "$branch_count" \
    --argjson tags "$tag_count" \
    '{name: $name, result: $result, backup_repo: $backup_repo, snapshot_prefix: $snapshot_prefix, branches: $branches, tags: $tags}' \
    >> "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl"
  rm -rf "$tmp"
}

if ! echo "${FORKS:-}" | jq -e 'type == "array"' >/dev/null 2>&1; then
  echo "::error::FORKS must be a JSON array"
  exit 1
fi

fork_count=$(echo "$FORKS" | jq length)
if [ "$fork_count" -eq 0 ]; then
  echo "No forks to back up"
  exit 0
fi

if ! printf '%s' "${MIRROR_BACKUP_MAX_PARALLEL:-1}" | grep -Eq '^[1-9][0-9]*$'; then
  MIRROR_BACKUP_MAX_PARALLEL=1
fi
if [ "${MIRROR_BACKUP_MAX_PARALLEL:-1}" != "1" ]; then
  echo "::warning::full-ref backup runs serially for safer disaster snapshots; ignoring MIRROR_BACKUP_MAX_PARALLEL=${MIRROR_BACKUP_MAX_PARALLEL}"
  MIRROR_BACKUP_MAX_PARALLEL=1
fi

echo "Full-ref backup targets: $fork_count fork(s), parallel=${MIRROR_BACKUP_MAX_PARALLEL:-1}"
while IFS= read -r fork_b64; do
  [ -z "$fork_b64" ] && continue
  ( process_backup_fork "$fork_b64" )
done < <(echo "$FORKS" | jq -r '.[] | @base64')

echo "$FORKS" | jq -r '.[].name' | while read -r name; do
  if [ -f "$LOG_DIR/$name.log" ]; then
    cat "$LOG_DIR/$name.log"
  fi
done

echo ""
echo "------------------------------------------"
echo "Full-ref backup events"
echo "------------------------------------------"
if [ -s "${RUNNER_TEMP:-/tmp}/mirror-backup-events.jsonl" ]; then
  cat "${RUNNER_TEMP:-/tmp}/mirror-backup-events.jsonl"
fi

failed=$(jq -s '[.[] | select(.result == "fail")] | length' "${RUNNER_TEMP:-/tmp}/mirror-backup-summary.jsonl" 2>/dev/null || echo 0)
if [ "$failed" -gt 0 ]; then
  echo "::error::full-ref backup failed for $failed fork(s)"
  exit 1
fi
