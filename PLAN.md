# changed-files Orb Plan

## Summary

Implement a URL orb for GitHub pull request pipelines that skips the rest of a job when no relevant files changed.

The accepted design is:

- Prefer an explicit `base-branch` when provided
- Avoid a `gh` CLI dependency
- Use GitHub API only for pull request metadata
- Use local `git diff` for the actual file detection
- Fail open when the diff cannot be trusted

## Public Interface

### Orb type

- URL orb

### Source layout

- `orb.yml`: packed URL orb file
- `src/@orb.yml`: orb metadata
- `src/commands/check.yml`: command definition
- `src/scripts/changed-files.sh`: runtime detection logic
- `examples/config.yml`: sample CircleCI config using the orb

### Command

- `changed-files/check`

### Parameters

| Parameter | Type | Required | Default | Notes |
| --- | --- | --- | --- | --- |
| `files` | string | yes | none | Newline-delimited globs. Prefix a pattern with `!` to exclude it. |
| `base-branch` | string | no | empty | Explicit base branch override |
| `debug` | boolean | no | `false` | Enables verbose logs |

### Environment inputs

- `GITHUB_TOKEN`: optional token for GitHub REST API
- `CIRCLE_PULL_REQUEST`: optional GitHub.com or GitHub Enterprise PR URL
- `GITHUB_API_URL`: optional override for the GitHub API base URL

## Behavior Specification

### Supported context

- Support GitHub pull request pipelines only
- Treat missing or unusable PR context as a fail-open condition unless the `files` input itself is invalid

### Detection strategy

Use this priority order:

1. `git diff` using explicit `base-branch`
2. GitHub REST API metadata plus local `git diff`

### Strategy 1: `git diff`

Use this path when:

- `base-branch` is provided explicitly

Implementation decisions:

- Skip GitHub API lookup entirely when `base-branch` is set
- Fetch the base branch if needed
- Deepen or unshallow the checkout if needed until a merge base exists
- Compare `origin/<base-branch>...HEAD`
- Detect only added and modified files
- Disable rename detection and treat renames as delete + add

### Strategy 2: GitHub REST API metadata

Use this path when:

- `base-branch` is not provided
- `GITHUB_TOKEN` is available
- `CIRCLE_PULL_REQUEST` is available

Implementation decisions:

- Extract the host, owner, repo, and pull request number from `CIRCLE_PULL_REQUEST`
- Query GitHub REST API for pull request metadata only
- Read `base.ref`, `base.sha`, and `head.sha`
- Use `base.ref` for fetch/deepen and `HEAD` as the local comparison tip
- Continue the job when `head.sha` does not match local `HEAD`
- For GitHub Enterprise URLs, default the API base URL to `https://<pull-request-host>/api/v3` unless `GITHUB_API_URL` is set

### File matching rules

- Evaluate file paths relative to the repository root
- Parse newline-delimited patterns from `files`
- Treat `!pattern` as an exclude
- Support Git pathspec `glob` semantics
- Require at least one positive include pattern
- Deleted files do not participate in matching
- A match is true if any changed file survives the include/exclude pathspec filtering

### Exit behavior

- Matching file exists: exit successfully and continue the job
- No matching file exists: print a skip message and run `circleci-agent step halt`
- Invalid `files` configuration: exit non-zero with a clear error
- Missing PR context, failed API call, failed fetch, merge-base failure, or head SHA mismatch: log the reason and continue the job

### Logging

Always print:

- Which strategy was chosen
- What base source was used
- What comparison target was used when available
- Whether matching files were found

When `debug: true`, also print:

- Raw changed files from the diff
- Parsed include patterns
- Parsed exclude patterns

## Compatibility Notes

### GitHub App vs GitHub OAuth

The implementation must explicitly document that `pipeline.event.*` values are only expected on projects actually running as GitHub App pipelines.

Do not assume those values exist just because the CircleCI GitHub App is installed somewhere in the organization.

README and error messages must explain that OAuth-based projects may need:

- `GITHUB_TOKEN`
- `CIRCLE_PULL_REQUEST`
- `base-branch`

Implementation decisions:

- Do not reference `pipeline.event.*` inside the orb source
- Rely on runtime environment variables instead so the orb works across both App and OAuth projects without compile-time failures

### No `gh` dependency

Do not require GitHub CLI in the orb executor environment.

Rationale:

- Avoid executor image assumptions
- Keep runtime dependencies minimal
- Equivalent information is available from `CIRCLE_PULL_REQUEST`, GitHub REST API metadata, and git

## Test Plan

### Functional scenarios

- Explicit `base-branch` takes precedence over GitHub API inputs
- GitHub Enterprise PR URLs resolve the correct API endpoint
- Recursive globs like `docs/**` match nested files
- `!pattern` excludes a file that would otherwise match
- Added and modified files match
- Deleted files do not match
- Rename old-path matches no longer trigger
- Rename new-path matches trigger as added files

### Fail-open scenarios

- No PR context and no `base-branch`
- API call fails and no fallback is available
- API `head.sha` does not match local `HEAD`
- Invalid or unreachable base branch
- Shallow history needs additional fetches before a merge base can be found

### Validation failures

- Empty `files`
- `files` contains only exclude patterns

### Documentation checks

- README examples place `changed-files/check` in its own step
- README explains fail-open behavior clearly
- README documents the runtime requirements

## Implementation Notes

### Shell/runtime assumptions

- Target a standard Linux CircleCI environment with `bash` and `git`
- Require `curl` and `jq` only for the GitHub API metadata path
- Do not require `python3`

### Closed decisions for v1

- Support only pull request pipelines
- Keep outputs minimal and do not expose a reusable changed-file list
- Keep excludes inside `files` via `!pattern`
- Do not carry forward `files-ignore`

## References

- CircleCI URL orbs:
  https://circleci.com/docs/orbs/author/create-test-and-use-url-orbs/
- CircleCI orb overview:
  https://circleci.com/docs/orbs/use/orb-intro/
- CircleCI variables:
  https://circleci.com/docs/reference/variables/
- CircleCI GitHub App in OAuth orgs:
  https://circleci.com/docs/guides/integration/using-the-circleci-github-app-in-an-oauth-org/
- CircleCI Discuss thread on missing GitHub App event values:
  https://discuss.circleci.com/t/documentation-on-github-app-events-not-working/53407
- `circleci-agent step halt` usage:
  https://circleci.com/docs/guides/test/rerun-failed-tests/
- Reference inspiration:
  https://github.com/tj-actions/changed-files
