#!/usr/bin/env bash

# Shared GitHub API helpers for fork-sync workflows and local diagnostics.
# Workflow steps source this file after checking out the configuration repo.

wait_for_core_rate_limit() {
  local info remaining reset limit now wait reset_human
  info=$(gh api rate_limit \
    --jq '{remaining: .resources.core.remaining, reset: .resources.core.reset, limit: .resources.core.limit}' \
    2>/dev/null || echo '{}')
  remaining=$(echo "$info" | jq -r '.remaining // 9999')
  reset=$(echo "$info" | jq -r '.reset // 0')
  limit=$(echo "$info" | jq -r '.limit // 5000')
  if [ "$remaining" -le 0 ] 2>/dev/null; then
    now=$(date +%s)
    wait=$((reset - now + 10))
    if [ "$wait" -gt 0 ] && [ "$wait" -lt 3700 ]; then
      reset_human=$(date -d "@$reset" '+%H:%M:%S' 2>/dev/null || date -r "$reset" '+%H:%M:%S')
      echo "  rate limit exhausted ($remaining/$limit), waiting ${wait}s until $reset_human UTC" >&2
      sleep "$wait"
      return 0
    fi
  fi
  return 1
}
export -f wait_for_core_rate_limit

gh_api_with_retry() {
  local max_attempts=3
  local attempt=1
  local delay=1
  local output rc
  while [ "$attempt" -le "$max_attempts" ]; do
    output=$(gh api "$@" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "$output"
      return 0
    fi
    if printf '%s' "$output" | grep -Eiq 'rate limit|API rate limit exceeded'; then
      wait_for_core_rate_limit && continue
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      echo "  gh api failed ($attempt/$max_attempts), retrying in ${delay}s: $(printf '%s' "$output" | head -1)" >&2
      sleep "$delay"
      delay=$((delay * 2))
    fi
    attempt=$((attempt + 1))
  done
  if [ -n "${GH_API_ERROR_FILE:-}" ]; then
    printf '%s\n' "$output" > "$GH_API_ERROR_FILE" 2>/dev/null || true
  fi
  echo "  gh api failed after $max_attempts attempts: $(printf '%s' "$output" | head -1)" >&2
  return 1
}
export -f gh_api_with_retry

gh_api_capture() {
  local __out_var="$1" __err_var="$2"
  shift 2
  local output rc error_file stderr_file error_output
  error_file=$(mktemp)
  stderr_file=$(mktemp)
  output=$(GH_API_ERROR_FILE="$error_file" gh_api_with_retry "$@" 2>"$stderr_file")
  rc=$?
  printf -v "$__out_var" '%s' "$output"
  if [ "$rc" -ne 0 ]; then
    if [ -s "$error_file" ]; then
      error_output=$(cat "$error_file")
    else
      error_output=$(cat "$stderr_file")
    fi
    printf -v "$__err_var" '%s' "$error_output"
  else
    printf -v "$__err_var" '%s' ""
  fi
  rm -f "$error_file" "$stderr_file"
  return "$rc"
}
export -f gh_api_capture

gh_api_write() {
  if [ "${DRY_RUN:-false}" = "true" ]; then
    echo "[DRY-RUN] gh api $*"
    return 0
  fi
  gh_api_with_retry "$@"
}
export -f gh_api_write

gh_api_write_capture() {
  local __out_var="$1" __err_var="$2"
  shift 2
  if [ "${DRY_RUN:-false}" = "true" ]; then
    printf -v "$__out_var" '[DRY-RUN] gh api %s' "$*"
    printf -v "$__err_var" '%s' ""
    return 0
  fi
  gh_api_capture "$__out_var" "$__err_var" "$@"
}
export -f gh_api_write_capture

with_gh_token() {
  local token="$1"
  shift
  local old_token="${GH_TOKEN:-}"
  local had_token="${GH_TOKEN+x}"
  if [ -n "$token" ]; then
    GH_TOKEN="$token"
    export GH_TOKEN
  fi
  "$@"
  local rc=$?
  if [ -n "$had_token" ]; then
    GH_TOKEN="$old_token"
    export GH_TOKEN
  else
    unset GH_TOKEN
  fi
  return "$rc"
}
export -f with_gh_token

api_error_field() {
  local raw="$1" field="$2" json
  json=$(awk 'match($0, /^\{.*\}/) {print substr($0, RSTART, RLENGTH); exit}' <<<"$raw")
  if [ -n "$json" ]; then
    jq -r --arg field "$field" '.[$field] // empty' <<<"$json" 2>/dev/null | head -1
  fi
}
export -f api_error_field

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
export -f api_error_message

api_error_hint() {
  local context="$1" status="$2" message="$3"
  case "$context:$status:$message" in
    upstream_repo:404:*)
      printf '%s' "upstream repository is not reachable; common causes: deleted source repo, private repo without token access, stale fork metadata after rename, hidden owner account, or token scope mismatch"
      ;;
    upstream_repo:403:*)
      printf '%s' "upstream repository access was denied; common causes: token scope, private repo access, organization SSO/policy, or API limit"
      ;;
    branches:404:*)
      printf '%s' "upstream branch list is not reachable; common causes: deleted/private/renamed upstream, empty repository, or token scope mismatch"
      ;;
    branches:403:*)
      printf '%s' "upstream branch list access was denied; common causes: token scope, private repo access, organization SSO/policy, or API limit"
      ;;
    upstream_sha:404:*)
      printf '%s' "upstream branch ref is not readable; branch may be deleted/renamed or changed between list and ref lookup"
      ;;
    compare:404:*No\ common\ ancestor*)
      printf '%s' "fork and upstream branches have no common ancestor"
      ;;
    compare:404:*)
      printf '%s' "GitHub compare could not find comparable refs; repo/branch may be missing, inaccessible, or unrelated"
      ;;
    *:404:*)
      printf '%s' "GitHub returned 404; repo/branch may be missing, deleted, private, renamed, or inaccessible to the token"
      ;;
    *:403:*)
      printf '%s' "GitHub returned 403; token permissions, branch protection, organization policy, or API limit may block access"
      ;;
    *)
      printf '%s' "GitHub API call failed; inspect status, message, and context"
      ;;
  esac
}
export -f api_error_hint

probe_upstream_repository() {
  local owner="$1" repo="$2" repo_out repo_err status message hint
  if gh_api_capture repo_out repo_err "repos/$owner/$repo" \
    --jq '{full_name, private, default_branch, size, archived, disabled, html_url}'; then
    printf '%s\n' "$repo_out"
    return 0
  fi

  status=$(api_error_field "$repo_err" "status")
  message=$(api_error_message "$repo_err")
  hint=$(api_error_hint "upstream_repo" "$status" "$message")
  jq -n -c \
    --arg owner "$owner" \
    --arg repo "$repo" \
    --arg status "$status" \
    --arg message "$message" \
    --arg hint "$hint" \
    '{owner: $owner, repo: $repo, reachable: false, status: $status, message: $message, hint: $hint}' >&2
  return 1
}
export -f probe_upstream_repository

probe_upstream_branches() {
  local owner="$1" repo="$2" branches_out branches_err status message hint
  if gh_api_capture branches_out branches_err --paginate "repos/$owner/$repo/branches?per_page=100" --jq '.[] | .name'; then
    printf '%s\n' "$branches_out"
    return 0
  fi

  status=$(api_error_field "$branches_err" "status")
  message=$(api_error_message "$branches_err")
  hint=$(api_error_hint "branches" "$status" "$message")
  jq -n -c \
    --arg owner "$owner" \
    --arg repo "$repo" \
    --arg status "$status" \
    --arg message "$message" \
    --arg hint "$hint" \
    '{owner: $owner, repo: $repo, reachable: false, status: $status, message: $message, hint: $hint}' >&2
  return 1
}
export -f probe_upstream_branches
