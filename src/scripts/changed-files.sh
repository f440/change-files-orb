#!/usr/bin/env bash

set -euo pipefail

declare -a CHANGED_FILES_INCLUDE_PATTERNS=()
declare -a CHANGED_FILES_EXCLUDE_PATTERNS=()
declare -a CHANGED_FILES_PATHSPECS=()

log() {
  printf '[changed-files] %s\n' "$*"
}

error() {
  printf '[changed-files] ERROR: %s\n' "$*" >&2
}

die() {
  error "$*"
  exit 1
}

is_true() {
  case "${1,,}" in
    1|true|yes|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

debug() {
  if is_true "${CHANGED_FILES_DEBUG:-false}"; then
    printf '[changed-files] DEBUG: %s\n' "$*" >&2
  fi
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' is not available in this executor."
}

read_env_var_by_name() {
  local name="$1"

  [[ -n "${name}" ]] || return 0

  if [[ ! "${name}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    die "Environment variable name '${name}' is invalid."
  fi

  printf '%s' "${!name:-}"
}

normalize_base_ref() {
  local ref="$1"
  ref="${ref#refs/heads/}"
  printf '%s' "$ref"
}

trim() {
  local value="$1"
  printf '%s' "${value}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

normalize_pattern() {
  local pattern="$1"
  pattern="${pattern#./}"
  printf '%s' "${pattern}"
}

parse_file_patterns() {
  local raw="$1"
  local line=""
  local pattern=""

  CHANGED_FILES_INCLUDE_PATTERNS=()
  CHANGED_FILES_EXCLUDE_PATTERNS=()
  CHANGED_FILES_PATHSPECS=()

  while IFS= read -r line || [[ -n "${line}" ]]; do
    pattern="$(trim "${line}")"
    [[ -n "${pattern}" ]] || continue

    if [[ "${pattern}" == '!'* ]]; then
      pattern="$(trim "${pattern#!}")"
      pattern="$(normalize_pattern "${pattern}")"
      [[ -n "${pattern}" ]] || die "Exclude patterns in 'files' must not be empty."
      CHANGED_FILES_EXCLUDE_PATTERNS+=("${pattern}")
      CHANGED_FILES_PATHSPECS+=(":(exclude,top,glob)${pattern}")
      continue
    fi

    pattern="$(normalize_pattern "${pattern}")"
    [[ -n "${pattern}" ]] || continue
    CHANGED_FILES_INCLUDE_PATTERNS+=("${pattern}")
    CHANGED_FILES_PATHSPECS+=(":(top,glob)${pattern}")
  done <<< "${raw}"

  if (( ${#CHANGED_FILES_INCLUDE_PATTERNS[@]} == 0 )); then
    die "Parameter 'files' must contain at least one include pattern."
  fi
}

fetch_base_target() {
  local ref="$1"
  local normalized_ref

  normalized_ref="$(normalize_base_ref "${ref}")"

  debug "Fetching origin/${normalized_ref}"

  if git fetch --no-tags --depth=256 origin \
    "refs/heads/${normalized_ref}:refs/remotes/origin/${normalized_ref}" >/dev/null 2>&1; then
    printf 'refs/remotes/origin/%s' "${normalized_ref}"
    return 0
  fi

  debug "Direct ref fetch failed for ${normalized_ref}; trying shorthand fetch"

  if git fetch --no-tags --depth=256 origin "${normalized_ref}" >/dev/null 2>&1; then
    if git rev-parse --verify "refs/remotes/origin/${normalized_ref}" >/dev/null 2>&1; then
      printf 'refs/remotes/origin/%s' "${normalized_ref}"
    else
      printf 'FETCH_HEAD'
    fi
    return 0
  fi

  return 1
}

resolve_compare_target() {
  local compare_base="$1"
  local deepen_attempt=0
  local max_deepen_attempts=4

  while ! git merge-base "${compare_base}" HEAD >/dev/null 2>&1; do
    if [[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" != "true" ]]; then
      return 1
    fi

    if (( deepen_attempt < max_deepen_attempts )); then
      debug "No merge base for ${compare_base}; deepening origin history by 256 commits"
      git fetch --no-tags --deepen=256 origin >/dev/null 2>&1 || return 1
    elif (( deepen_attempt == max_deepen_attempts )); then
      debug "No merge base after ${max_deepen_attempts} deepen attempts; fetching full origin history"
      git fetch --no-tags --unshallow origin >/dev/null 2>&1 || return 1
    else
      return 1
    fi

    deepen_attempt=$((deepen_attempt + 1))
  done

  printf '%s...HEAD' "${compare_base}"
}

extract_pr_parts() {
  local pr_url="$1"

  pr_url="${pr_url%%\#*}"
  pr_url="${pr_url%%\?*}"

  if [[ ! "${pr_url}" =~ ^https://([^/]+)/([^/]+)/([^/]+)/pull/([0-9]+)/?$ ]]; then
    return 1
  fi

  printf '%s\n' \
    "${BASH_REMATCH[1]}" \
    "${BASH_REMATCH[2]}" \
    "${BASH_REMATCH[3]}" \
    "${BASH_REMATCH[4]}"
}

resolve_api_url() {
  local pr_host="$1"

  if [[ -n "${GITHUB_API_URL:-}" ]]; then
    printf '%s' "${GITHUB_API_URL}"
  elif [[ "${pr_host}" == "github.com" ]]; then
    printf 'https://api.github.com'
  else
    printf 'https://%s/api/v3' "${pr_host}"
  fi
}

github_pr_metadata() {
  local owner="$1"
  local repo="$2"
  local number="$3"
  local api_url="$4"

  curl -fsSL \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_TOKEN}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${api_url}/repos/${owner}/${repo}/pulls/${number}" |
    jq -er '.base.ref, .base.sha, .head.sha'
}

collect_changed_files() {
  local compare_target="$1"

  git diff --no-renames --diff-filter=AM --name-only "${compare_target}"
}

collect_matching_files() {
  local compare_target="$1"

  git diff --no-renames --diff-filter=AM --name-only "${compare_target}" -- \
    "${CHANGED_FILES_PATHSPECS[@]}"
}

continue_without_detection() {
  log "$1"
  return 0
}

main() {
  local include_raw="${CHANGED_FILES_INCLUDE:-}"
  local base_branch="${CHANGED_FILES_BASE_BRANCH:-}"
  local github_token_env_var="${CHANGED_FILES_GITHUB_TOKEN_ENV_VAR:-GITHUB_TOKEN}"
  local github_token=""
  local pr_url="${CIRCLE_PULL_REQUEST:-}"
  local strategy=""
  local base_source=""
  local base_ref=""
  local base_sha=""
  local head_sha=""
  local compare_base=""
  local compare_target=""
  local pr_host=""
  local pr_owner=""
  local pr_repo=""
  local pr_number=""
  local api_url=""
  local local_head=""
  local tmp_dir=""
  local all_changed_file=""
  local matched_file=""

  require_command git

  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Run this command inside a git checkout."

  parse_file_patterns "${include_raw}"
  github_token="$(read_env_var_by_name "${github_token_env_var}")"

  local_head="$(git rev-parse HEAD)"

  if [[ -n "${base_branch}" ]]; then
    strategy="explicit-base-branch"
    base_ref="${base_branch}"
    base_source="explicit base-branch"
    debug "Using explicit base branch '${base_branch}'; skipping GitHub API lookup"
  elif [[ -n "${github_token}" && -n "${pr_url}" ]]; then
    strategy="pull-request-metadata"
    require_command curl
    require_command jq

    if pr_parts="$(extract_pr_parts "${pr_url}")"; then
      mapfile -t parts < <(printf '%s\n' "${pr_parts}")
      pr_host="${parts[0]}"
      pr_owner="${parts[1]}"
      pr_repo="${parts[2]}"
      pr_number="${parts[3]}"
      api_url="$(resolve_api_url "${pr_host}")"
      debug "Resolved pull request ${pr_owner}/${pr_repo}#${pr_number} from ${pr_host}"
      debug "Using GitHub API endpoint ${api_url}"
      debug "Using GitHub token environment variable '${github_token_env_var}'"

      if pr_metadata="$(GITHUB_TOKEN="${github_token}" github_pr_metadata "${pr_owner}" "${pr_repo}" "${pr_number}" "${api_url}")"; then
        mapfile -t metadata_parts < <(printf '%s\n' "${pr_metadata}")
        base_ref="${metadata_parts[0]}"
        base_sha="${metadata_parts[1]}"
        head_sha="${metadata_parts[2]}"
        base_source="GitHub pull request metadata API"
      else
        continue_without_detection \
          "GitHub API lookup failed; unable to determine changed files, so the job will continue."
        return 0
      fi
    else
      continue_without_detection \
        "CIRCLE_PULL_REQUEST is not a supported GitHub pull request URL; unable to determine changed files, so the job will continue."
      return 0
    fi
  else
    continue_without_detection \
      "Unable to determine a pull request base branch; unable to determine changed files, so the job will continue."
    return 0
  fi

  log "Strategy: ${strategy}"
  log "Base source: ${base_source}"
  log "Base branch: $(normalize_base_ref "${base_ref}")"
  if [[ -n "${base_sha}" ]]; then
    log "Base SHA: ${base_sha}"
  fi

  if [[ -n "${head_sha}" && "${head_sha}" != "${local_head}" ]]; then
    continue_without_detection \
      "GitHub API reported head SHA ${head_sha}, but local HEAD is ${local_head}; unable to trust the diff, so the job will continue."
    return 0
  fi

  compare_base="$(fetch_base_target "${base_ref}")" || {
    continue_without_detection \
      "Failed to fetch base branch '${base_ref}' from origin; unable to determine changed files, so the job will continue."
    return 0
  }

  compare_target="$(resolve_compare_target "${compare_base}")" || {
    continue_without_detection \
      "Failed to determine a merge base between '${compare_base}' and HEAD; unable to determine changed files, so the job will continue."
    return 0
  }
  log "Diff target: ${compare_target}"

  tmp_dir="$(mktemp -d)"
  trap "rm -rf '${tmp_dir}'" EXIT

  all_changed_file="${tmp_dir}/changed.txt"
  matched_file="${tmp_dir}/matched.txt"

  if ! collect_changed_files "${compare_target}" > "${all_changed_file}"; then
    continue_without_detection \
      "Failed to collect changed files from '${compare_target}'; the job will continue."
    return 0
  fi

  if ! collect_matching_files "${compare_target}" > "${matched_file}"; then
    continue_without_detection \
      "Failed to collect matching files from '${compare_target}'; the job will continue."
    return 0
  fi

  if is_true "${CHANGED_FILES_DEBUG:-false}"; then
    debug "changed files"
    if [[ -s "${all_changed_file}" ]]; then
      sed 's/^/[changed-files] DEBUG:   /' "${all_changed_file}" >&2
    else
      debug "  (none)"
    fi

    debug "include patterns"
    if (( ${#CHANGED_FILES_INCLUDE_PATTERNS[@]} == 0 )); then
      debug "  (none)"
    else
      for pattern in "${CHANGED_FILES_INCLUDE_PATTERNS[@]}"; do
        debug "  ${pattern}"
      done
    fi

    if (( ${#CHANGED_FILES_EXCLUDE_PATTERNS[@]} > 0 )); then
      debug "exclude patterns"
      for pattern in "${CHANGED_FILES_EXCLUDE_PATTERNS[@]}"; do
        debug "  ${pattern}"
      done
    fi
  fi

  if [[ -s "${matched_file}" ]]; then
    log "Matching files detected:"
    sed 's/^/[changed-files]   /' "${matched_file}"
    return 0
  fi

  log "No matching files changed; halting the rest of the job."
  circleci-agent step halt
}

main "$@"
