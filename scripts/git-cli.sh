#!/usr/bin/env bash

# Shared git CLI helpers for fork-sync diagnostics.
# These helpers are intentionally small and side-effect scoped to a caller-owned
# temporary repository directory.

github_auth_header() {
  local token="${1:-${GH_TOKEN:-}}"
  [ -z "$token" ] && return 1
  printf 'AUTHORIZATION: basic %s\n' "$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
}
export -f github_auth_header

git_init_probe_repo() {
  local repo_dir="$1" fork_url="$2" upstream_url="$3"
  git -C "$repo_dir" init -q || return 1
  git -C "$repo_dir" remote add fork "$fork_url" || return 1
  git -C "$repo_dir" remote add upstream "$upstream_url" || return 1
}
export -f git_init_probe_repo

git_fetch_ref_for_signature() {
  local repo_dir="$1" remote="$2" source_ref="$3" target_ref="$4" auth_header="$5"
  git -C "$repo_dir" -c http.extraheader="$auth_header" fetch --quiet --no-tags --depth=1000 \
    "$remote" "$source_ref:$target_ref"
}
export -f git_fetch_ref_for_signature

git_local_changes_signature() {
  local repo_dir="$1" upstream_ref="$2" head_ref="$3"
  local base sig
  base=$(git -C "$repo_dir" merge-base "$upstream_ref" "$head_ref") || return 1
  sig=$(git -C "$repo_dir" diff --find-renames "$base" "$head_ref" \
        | git -C "$repo_dir" patch-id --stable \
        | awk '{print $1}' \
        | sort \
        | paste -sd, -)
  printf '%s\n' "${sig:-empty}"
}
export -f git_local_changes_signature

git_compare_local_backup_signature() {
  local repo_dir="$1" source_branch="$2" backup_branch="$3" auth_header="$4"

  git_fetch_ref_for_signature "$repo_dir" fork "refs/heads/$source_branch" refs/sync/current "$auth_header" || return 2
  git_fetch_ref_for_signature "$repo_dir" fork "refs/heads/$backup_branch" refs/sync/backup "$auth_header" || return 2
  git_fetch_ref_for_signature "$repo_dir" upstream "refs/heads/$source_branch" refs/sync/upstream "$auth_header" || return 2

  local current_sig backup_sig
  current_sig=$(git_local_changes_signature "$repo_dir" refs/sync/upstream refs/sync/current) || return 2
  backup_sig=$(git_local_changes_signature "$repo_dir" refs/sync/upstream refs/sync/backup) || return 2
  [ "$current_sig" = "$backup_sig" ]
}
export -f git_compare_local_backup_signature
