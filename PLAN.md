# changed-files Orb Plan

## Summary

Implement a URL orb for GitHub pull request pipelines that skips the rest of a job when no relevant files changed.

The orb must:

- Prefer an explicit `base-branch` when provided
- Avoid a `gh` CLI dependency
- Fall back to `git diff` when API-based detection is unavailable
- Fail fast when it cannot determine a safe comparison target

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
| `files` | string | yes | none | Newline-delimited include globs |
| `files-ignore` | string | no | empty | Newline-delimited exclude globs |
| `base-branch` | string | conditional | empty | Required only when API and PR metadata are unavailable |
| `debug` | boolean | no | `false` | Enables verbose logs |

### Environment inputs

- `GITHUB_TOKEN`: optional token for GitHub REST API
- `CIRCLE_PULL_REQUEST`: optional GitHub.com or GitHub Enterprise PR URL
- `GITHUB_API_URL`: optional override for the GitHub API base URL, defaults to `https://api.github.com`

## Behavior Specification

### Supported context

- Support GitHub pull request pipelines only
- Treat missing PR context as an error unless `base-branch` enables a pure `git diff` fallback

### Detection strategy

Use this priority order:

1. `git diff` using explicit `base-branch`
2. GitHub REST API with `GITHUB_TOKEN`

### Strategy 1: `git diff`

Use this path when:

- `base-branch` is provided explicitly

Implementation decisions:

- Skip GitHub API lookup entirely when `base-branch` is set
- Fetch the base branch if needed
- Deepen or unshallow the checkout if needed until a merge base exists, otherwise fail clearly
- Compare `origin/<base-branch>...HEAD`
- Treat all changed file paths from the diff as candidates for glob matching
- For rename and copy entries, include both old and new paths in matching so path moves do not hide relevant changes

### Strategy 2: GitHub REST API

Use this path when:

- `base-branch` is not provided
- `GITHUB_TOKEN` is available
- `CIRCLE_PULL_REQUEST` is available

Implementation decisions:

- Extract the host, owner, repo, and pull request number from `CIRCLE_PULL_REQUEST`
- Query GitHub REST API for pull request metadata
- Query the pull request files API and use the API-provided changed file list directly
- Resolve the PR base branch from the API response for logging and fallback
- For GitHub Enterprise URLs, default the API base URL to `https://<pull-request-host>/api/v3` unless `GITHUB_API_URL` is set
- If API calls fail, fail the step because this strategy only runs when `base-branch` is not provided

### File matching rules

- Evaluate file paths relative to the repository root
- Use newline-delimited include globs from `files`
- Use newline-delimited exclude globs from `files-ignore`
- Support `*`, `?`, and recursive `**` matching
- A match is true if any changed file matches at least one include glob and no exclude glob
- Deleted and renamed files still participate in matching
- Empty `files-ignore` means no exclusions

### Exit behavior

- Matching file exists: exit successfully and continue the job
- No matching file exists: print a skip message and run `circleci-agent step halt`
- Invalid configuration or missing comparison target: exit non-zero with a clear error

### Logging

Always print:

- Which strategy was chosen
- What comparison target was used
- Whether matching files were found

When `debug: true`, also print:

- Raw changed file candidates
- The include and exclude patterns used
- Which files matched or were excluded

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
- Equivalent information is available from `CIRCLE_PULL_REQUEST`, GitHub REST API, and git

## Test Plan

### Functional scenarios

- Explicit `base-branch` takes precedence over GitHub API inputs
- OAuth-style PR context plus `GITHUB_TOKEN` allows API-based detection
- GitHub App pipeline with `CIRCLE_PULL_REQUEST` plus `GITHUB_TOKEN` allows API-based detection
- GitHub Enterprise PR URLs resolve the correct API endpoint
- `GITHUB_TOKEN` is absent and `base-branch` allows `git diff` detection
- Recursive globs like `docs/**` match nested files
- `files-ignore` excludes a file that would otherwise match
- Deleted file matches include glob
- Renamed file matches include glob

### Failure scenarios

- No PR context and no `base-branch`
- API call fails and no fallback is available
- Empty `files`
- Invalid or unreachable base branch for `git diff`
- Shallow history with no merge base until additional fetches are performed

### Documentation checks

- README examples place `changed-files/check` in its own step
- README explains GitHub App vs OAuth behavior clearly
- README documents the runtime requirements

## Implementation Notes

### Shell/runtime assumptions

- Target a standard Linux CircleCI environment with `bash`, `git`, `curl`, and `python3`
- Do not require `jq`

### Suggested implementation split

- Orb YAML defines the command parameters and invokes the shell script
- Shell script detects context, fetches changed files, applies glob filters, and decides halt vs continue
- Example config demonstrates both token-based and explicit-base-branch usage with an executor that satisfies the documented runtime needs

### Closed decisions for v1

- Support only pull request pipelines
- Keep outputs minimal and do not expose a reusable changed-file list
- Use include and exclude globs instead of trying to mirror every option from `tj-actions/changed-files`

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
