# changed-files Orb

CircleCI Orb for skipping expensive steps when a pull request does not touch the files you care about.

This orb is implemented as a URL orb under `orb.yml`.

## Goal

On GitHub pull request pipelines, detect whether relevant files changed.
If no matching files changed, the orb marks the step as successful and stops the rest of the job with `circleci-agent step halt`.

The current implementation:

- Prefers `base-branch` when it is explicitly set
- Uses `GITHUB_TOKEN` to query GitHub pull request metadata only when `base-branch` is not set
- Uses local `git diff` for the actual file detection in every successful path
- Uses `!pattern` inside `files` for exclusions
- Falls back to continuing the job when it cannot determine a trustworthy diff

## Files

- `orb.yml`: packed URL orb file to reference from CircleCI config
- `src/`: source files for the orb
- `examples/config.yml`: sample usage
- `tests/smoke.sh`: local smoke tests for the shell script behavior
- `.circleci/config.yml`: CI checks for packing, linting, and smoke tests
- `PLAN.md`: implementation notes and accepted behavior

## Usage

```yaml
version: 2.1

orbs:
  changed-files: https://raw.githubusercontent.com/<org>/<repo>/refs/heads/main/orb.yml

jobs:
  test:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - changed-files/check:
          files: |
            src/**
            tests/**
            !tests/fixtures/**
      - run:
          name: Run tests
          command: make test

workflows:
  test:
    jobs:
      - test
```

### Explicit base branch fallback

Use this when `GITHUB_TOKEN` is not available, or when you want to force base branch lookup from local git state.

```yaml
version: 2.1

orbs:
  changed-files: https://raw.githubusercontent.com/<org>/<repo>/refs/heads/main/orb.yml

jobs:
  test:
    docker:
      - image: cimg/base:current
    steps:
      - checkout
      - changed-files/check:
          base-branch: main
          files: |
            src/**
            tests/**
      - run:
          name: Run tests
          command: make test
```

## Parameters

| Parameter | Required | Type | Description |
| --- | --- | --- | --- |
| `files` | yes | string | Newline-delimited globs evaluated from the repository root. Prefix a pattern with `!` to exclude it. |
| `base-branch` | no | string | Explicit base branch to diff against. When set, GitHub API lookup is skipped. |
| `debug` | no | boolean | Print the detection path, comparison target, raw changed files, and parsed patterns. |

Supported glob syntax follows Git pathspec `glob` behavior.

Examples:

- `src/**` matches `src/main.go` and `src/pkg/util/file.go`
- `docs/**/*.md` matches Markdown files at any depth under `docs/`
- `!docs/generated/**` excludes generated content from an otherwise broader include

## How detection works

The orb uses the following resolution order:

1. If `base-branch` is explicitly set, skip GitHub API lookup and use local `git diff`.
2. Otherwise, if both `GITHUB_TOKEN` and `CIRCLE_PULL_REQUEST` are available, fetch pull request metadata from GitHub or GitHub Enterprise.
3. Fetch and deepen the base branch as needed, then compare it to `HEAD` with `git diff --no-renames --diff-filter=AM`.
4. Apply the include and exclude patterns directly through Git pathspecs.
5. If no matching file remains, call `circleci-agent step halt`.

Important behavior:

- Added and modified files participate in matching.
- Deleted files are ignored.
- Renames are treated as delete + add because the diff uses `--no-renames`.
- If the orb cannot determine a trustworthy diff, it logs why and continues the job instead of halting it.

The implementation intentionally does not reference `pipeline.event.*`.
Those values are compile-time features and are not reliably available across GitHub App and GitHub OAuth project setups.
Using `CIRCLE_PULL_REQUEST` plus `GITHUB_TOKEN` keeps the runtime path compatible across both setups.

For GitHub Enterprise pull request URLs, the orb derives the default API endpoint as `https://<pull-request-host>/api/v3`.
Set `GITHUB_API_URL` explicitly if your Enterprise instance uses a different API base URL.

## Compatibility Notes

The tricky part is not GitHub itself, but how the CircleCI project is installed and configured.

### GitHub App pipeline

GitHub App projects may expose pull request pipeline values like `pipeline.event.github.pull_request.base.ref`.
This orb does not rely on them, because directly referencing those values can break on projects that are not truly running as GitHub App pipelines.

### GitHub OAuth pipeline

On GitHub OAuth pipelines, expect to rely on:

- `CIRCLE_PULL_REQUEST` for the PR URL
- `GITHUB_TOKEN` for GitHub REST API access
- `base-branch` as an explicit fallback

Installing the CircleCI GitHub App is not enough by itself. The project must actually be configured and running as a GitHub App pipeline for the GitHub App-specific pipeline values to be present.

Useful references:

- https://discuss.circleci.com/t/documentation-on-github-app-events-not-working/53407
- https://circleci.com/docs/guides/integration/using-the-circleci-github-app-in-an-oauth-org/
- https://circleci.com/docs/reference/variables/

## Runtime Requirements

The executor image must always provide:

- `bash`
- `git`

The executor image must also provide:

- `curl`
- `jq`

only when the orb needs GitHub API pull request metadata lookup.

The examples use `cimg/base:current`, which already includes `curl` and `jq`.

Environment inputs used by the runtime:

- `GITHUB_TOKEN`: optional, enables GitHub API pull request lookup
- `CIRCLE_PULL_REQUEST`: optional pull request URL for GitHub.com or GitHub Enterprise
- `GITHUB_API_URL`: optional API base URL override, mainly for GitHub Enterprise

If `base-branch` is set, these API-related variables and tool requirements are ignored for diff target resolution.

## Development

`src/` is the source of truth. Do not edit `orb.yml` by hand.

After changing any orb source file under `src/`, regenerate `orb.yml`:

```bash
circleci orb pack --skip-update-check src > orb.yml
```

Then run the local smoke tests:

```bash
bash tests/smoke.sh
```

Recommended local workflow:

1. Edit files under `src/`
2. Run `circleci orb pack --skip-update-check src > orb.yml`
3. Run `bash tests/smoke.sh`
4. Commit both the source changes and the updated `orb.yml`

The CI job in `.circleci/config.yml` verifies:

- `orb.yml` is up to date with `src/`
- `src/scripts/changed-files.sh` and `tests/smoke.sh` pass `shellcheck`
- Orb and CI YAML files pass `yamllint`
- The smoke tests cover include and exclude matching, rename behavior, deleted files, API metadata lookup, shallow history, fail-open cases, and validation failures

## Why not use `gh`

The implementation intentionally avoids depending on GitHub CLI.

- It adds an extra runtime dependency to every executor image
- The needed data can be obtained from `CIRCLE_PULL_REQUEST`, GitHub REST API metadata, and `git diff`
- `curl`, `jq`, and the existing Git toolchain are enough for the current behavior

## Scope and Non-goals

Current scope:

- GitHub pull request pipelines only
- File matching based on newline-delimited globs in `files`
- Exclusions via `!pattern`
- Skip the rest of the current job when no relevant added or modified files changed

Current non-goals:

- Push event support
- GitLab or Bitbucket support
- Full compatibility with `tj-actions/changed-files`
- Returning a reusable changed-file list as outputs

Reference inspiration:

- https://github.com/tj-actions/changed-files

## Operational Caveat

`circleci-agent step halt` stops the rest of the job after the current step finishes.
Because of that, `changed-files/check` should be used in its own dedicated step before expensive test or build steps.

Reference:

- https://circleci.com/docs/guides/test/rerun-failed-tests/
