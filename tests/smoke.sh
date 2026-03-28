#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ORB_SCRIPT="${REPO_ROOT}/src/scripts/changed-files.sh"

log() {
  printf '[smoke] %s\n' "$*"
}

fail() {
  printf '[smoke] ERROR: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"

  if [[ "${haystack}" != *"${needle}"* ]]; then
    fail "Expected output to contain '${needle}', but it did not."
  fi
}

run_orb_script() {
  local workdir="$1"
  local include="$2"
  local exclude="$3"
  local base_branch="$4"
  local output_file="$5"
  shift 5

  (
    cd "${workdir}"
    export PATH="${TEST_BIN_DIR}:$PATH"
    export CHANGED_FILES_INCLUDE="${include}"
    export CHANGED_FILES_EXCLUDE="${exclude}"
    export CHANGED_FILES_BASE_BRANCH="${base_branch}"
    export CHANGED_FILES_DEBUG=true

    while [[ "$#" -gt 0 ]]; do
      export "$1"
      shift
    done

    bash "${ORB_SCRIPT}"
  ) >"${output_file}" 2>&1
}

create_origin_repo() {
  git init --bare "${TEST_ROOT}/origin.git" >/dev/null

  git clone "${TEST_ROOT}/origin.git" "${TEST_ROOT}/seed" >/dev/null 2>&1
  (
    cd "${TEST_ROOT}/seed"
    git config user.name tester
    git config user.email tester@example.com
    mkdir -p src docs/generated
    printf 'package main\n' > src/main.go
    printf 'generated\n' > docs/generated/openapi.json
    printf 'notes\n' > docs/readme.md
    git add .
    git commit -m init >/dev/null
    git branch -M main
    git push origin main >/dev/null 2>&1
  )
}

clone_feature_repo() {
  local name="$1"
  local target="${TEST_ROOT}/${name}"

  git clone "${TEST_ROOT}/origin.git" "${target}" >/dev/null 2>&1
  (
    cd "${target}"
    git config user.name tester
    git config user.email tester@example.com
    git checkout -b feature origin/main >/dev/null 2>&1
  )

  printf '%s' "${target}"
}

test_matching_change_continues() {
  local repo output

  repo="$(clone_feature_repo match-case)"
  (
    cd "${repo}"
    printf 'func main() {}\n' >> src/main.go
    git add src/main.go
    git commit -m match >/dev/null
  )

  output="${TEST_ROOT}/match.out"
  run_orb_script "${repo}" $'src/**\ngo.mod' "" "main" "${output}"

  assert_contains "$(cat "${output}")" "Matching files detected:"
  assert_contains "$(cat "${output}")" "src/main.go"
}

test_recursive_glob_matches_nested_paths() {
  local repo output content

  repo="$(clone_feature_repo recursive-glob-case)"
  (
    cd "${repo}"
    printf 'updated\n' >> docs/generated/openapi.json
    git add docs/generated/openapi.json
    git commit -m recursive >/dev/null
  )

  output="${TEST_ROOT}/recursive.out"
  run_orb_script "${repo}" 'docs/**' "" "main" "${output}"

  content="$(cat "${output}")"
  assert_contains "${content}" "Matching files detected:"
  assert_contains "${content}" "docs/generated/openapi.json"
}

test_no_match_halts() {
  local repo output content

  repo="$(clone_feature_repo halt-case)"
  (
    cd "${repo}"
    printf 'updated\n' >> docs/readme.md
    git add docs/readme.md
    git commit -m docs >/dev/null
  )

  output="${TEST_ROOT}/halt.out"
  run_orb_script "${repo}" 'internal/**' "" "main" "${output}"

  content="$(cat "${output}")"
  assert_contains "${content}" "No matching files changed"
  assert_contains "${content}" "circleci-agent step halt"
}

test_ignore_patterns_halt() {
  local repo output content

  repo="$(clone_feature_repo ignore-case)"
  (
    cd "${repo}"
    printf 'updated\n' >> docs/generated/openapi.json
    git add docs/generated/openapi.json
    git commit -m generated >/dev/null
  )

  output="${TEST_ROOT}/ignore.out"
  run_orb_script "${repo}" 'docs/**' 'docs/generated/**' "main" "${output}"

  content="$(cat "${output}")"
  assert_contains "${content}" "No matching files changed"
  assert_contains "${content}" "circleci-agent step halt"
  assert_contains "${content}" "docs/generated/openapi.json"
}

test_rename_matches_old_path() {
  local repo output content

  repo="$(clone_feature_repo rename-case)"
  (
    cd "${repo}"
    mkdir -p app
    git mv src/main.go app/main.go
    git commit -m rename >/dev/null
  )

  output="${TEST_ROOT}/rename.out"
  run_orb_script "${repo}" 'src/**' "" "main" "${output}"

  content="$(cat "${output}")"
  assert_contains "${content}" "Matching files detected:"
  assert_contains "${content}" "src/main.go"
}

test_deleted_file_matches() {
  local repo output content

  repo="$(clone_feature_repo delete-case)"
  (
    cd "${repo}"
    git rm docs/readme.md >/dev/null
    git commit -m delete >/dev/null
  )

  output="${TEST_ROOT}/delete.out"
  run_orb_script "${repo}" 'docs/**' "" "main" "${output}"

  content="$(cat "${output}")"
  assert_contains "${content}" "Matching files detected:"
  assert_contains "${content}" "docs/readme.md"
}

test_github_api_strategy_supports_enterprise_pr_urls() {
  local repo output content response_file curl_log

  repo="$(clone_feature_repo api-case)"
  (
    cd "${repo}"
    printf 'func main() {}\n' >> src/main.go
    git add src/main.go
    git commit -m api >/dev/null
  )

  response_file="${TEST_ROOT}/pull.json"
  curl_log="${TEST_ROOT}/curl.log"
  cat > "${response_file}" <<'EOF'
{"base":{"ref":"main","sha":"1234567890abcdef"}}
EOF

  output="${TEST_ROOT}/api.out"
  run_orb_script "${repo}" 'src/**' "" "" "${output}" \
    "GITHUB_TOKEN=test-token" \
    "CIRCLE_PULL_REQUEST=https://ghe.example.com/acme/widgets/pull/42" \
    "TEST_FAKE_CURL_RESPONSE_FILE=${response_file}" \
    "TEST_CURL_LOG=${curl_log}"

  content="$(cat "${output}")"
  assert_contains "${content}" "Strategy: github-api"
  assert_contains "${content}" "Base branch: main"
  assert_contains "${content}" "src/main.go"
  assert_contains "$(cat "${curl_log}")" "https://ghe.example.com/api/v3/repos/acme/widgets/pulls/42"
}

test_empty_include_fails() {
  local repo output status content

  repo="$(clone_feature_repo empty-include-case)"
  output="${TEST_ROOT}/empty.out"

  set +e
  run_orb_script "${repo}" "" "" "main" "${output}"
  status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    fail "Expected empty include case to fail, but it succeeded."
  fi

  content="$(cat "${output}")"
  assert_contains "${content}" "Parameter 'files' must contain at least one include pattern."
}

main() {
  TEST_ROOT="$(mktemp -d)"
  TEST_BIN_DIR="${TEST_ROOT}/bin"
  mkdir -p "${TEST_BIN_DIR}"
  trap 'rm -rf "${TEST_ROOT}"' EXIT
  export REAL_CURL_PATH
  REAL_CURL_PATH="$(command -v curl)"

  cat > "${TEST_BIN_DIR}/circleci-agent" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "step" && "${2:-}" == "halt" ]]; then
  echo "circleci-agent step halt"
  exit 0
fi
echo "unexpected circleci-agent invocation: $*" >&2
exit 1
EOF
  chmod +x "${TEST_BIN_DIR}/circleci-agent"

  cat > "${TEST_BIN_DIR}/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${TEST_CURL_LOG:-}" ]]; then
  printf '%s\n' "$*" > "${TEST_CURL_LOG}"
fi

if [[ -n "${TEST_FAKE_CURL_RESPONSE_FILE:-}" ]]; then
  cat "${TEST_FAKE_CURL_RESPONSE_FILE}"
  exit 0
fi

exec "${REAL_CURL_PATH}" "$@"
EOF
  chmod +x "${TEST_BIN_DIR}/curl"

  create_origin_repo

  log "Running match case"
  test_matching_change_continues
  log "Running recursive glob case"
  test_recursive_glob_matches_nested_paths
  log "Running halt case"
  test_no_match_halts
  log "Running ignore case"
  test_ignore_patterns_halt
  log "Running rename case"
  test_rename_matches_old_path
  log "Running deleted file case"
  test_deleted_file_matches
  log "Running GitHub API case"
  test_github_api_strategy_supports_enterprise_pr_urls
  log "Running empty include case"
  test_empty_include_fails
  log "Smoke tests passed"
}

main "$@"
