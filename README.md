# changed-files Orb

CircleCI Orb for skipping expensive steps when a pull request does not touch the files you care about.

This orb is implemented as a URL orb under `orb.yml`.

## Goal

On GitHub pull request pipelines, detect whether target files changed.
If no matching files changed, the orb marks the step as successful and stops the rest of the job with `circleci-agent step halt`.

The current implementation:

- Uses `GITHUB_TOKEN` when available to query GitHub pull request metadata via the REST API
- Avoids requiring `gh` CLI
- Falls back to `git diff` when API-based metadata is unavailable
- Requires the caller to provide a base branch when neither API access nor PR metadata is available

## Files

- `orb.yml`: packed URL orb file to reference from CircleCI config
- `src/`: source files for the orb
- `examples/config.yml`: sample usage
- `PLAN.md`: implementation notes and test cases

## Usage

```yaml
version: 2.1

orbs:
  changed-files: https://raw.githubusercontent.com/<org>/<repo>/refs/heads/main/orb.yml

jobs:
  test:
    docker:
      - image: cimg/base:stable
    steps:
      - checkout
      - changed-files/check:
          files: |
            src/**
            go.mod
            go.sum
      - run:
          name: Run tests
          command: go test ./...

workflows:
  test:
    jobs:
      - test
```

### Explicit base branch fallback

Use this when `GITHUB_TOKEN` is not available or when you want deterministic `git diff` behavior.

```yaml
version: 2.1

orbs:
  changed-files: https://raw.githubusercontent.com/<org>/<repo>/refs/heads/main/orb.yml

jobs:
  test:
    docker:
      - image: cimg/base:stable
    steps:
      - checkout
      - changed-files/check:
          base-branch: main
          files: |
            cmd/**
            internal/**
            go.mod
      - run:
          name: Run tests
          command: go test ./...
```

## Parameters

| Parameter | Required | Type | Description |
| --- | --- | --- | --- |
| `files` | yes | string | Newline-delimited include globs, evaluated from the repository root |
| `files-ignore` | no | string | Newline-delimited exclude globs |
| `base-branch` | conditional | string | Required when the orb cannot determine a PR base ref and `GITHUB_TOKEN` is not available |
| `debug` | no | boolean | Print the detection path, comparison target, and matched files |

## How detection works

The orb uses the following resolution order:

1. If both `GITHUB_TOKEN` and `CIRCLE_PULL_REQUEST` are available, fetch the PR metadata from GitHub and resolve the base branch from the API.
2. Otherwise, use the explicit `base-branch` parameter.
3. Fetch the base branch from `origin` and compare it to `HEAD` with `git diff`.
4. If no changed file matches `files` after applying `files-ignore`, call `circleci-agent step halt`.

The implementation intentionally does not reference `pipeline.event.*`.
Those values are compile-time features and are not reliably available across GitHub App and GitHub OAuth project setups.
Using `CIRCLE_PULL_REQUEST` plus `GITHUB_TOKEN` keeps the runtime path compatible across both setups.

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

The executor image must provide:

- `bash`
- `git`
- `curl`
- `python3`

The orb uses `python3` to parse GitHub API JSON and apply glob matching consistently.

## Why not use `gh`

The implementation intentionally avoids depending on GitHub CLI.

- It adds an extra runtime dependency to every executor image
- The needed data can be obtained from `CIRCLE_PULL_REQUEST`, GitHub REST API, and `git diff`
- `curl` plus the existing Git toolchain is enough for the current behavior

## Scope and Non-goals

Current scope:

- GitHub pull request pipelines only
- File matching based on include and exclude globs
- Skip the rest of the current job when no relevant files changed

Current non-goals:

- Push event support
- GitLab or Bitbucket support
- Full compatibility with `tj-actions/changed-files`
- Returning a full changed-file list as reusable outputs

Reference inspiration:

- https://github.com/tj-actions/changed-files

## Operational Caveat

`circleci-agent step halt` stops the rest of the job after the current step finishes.
Because of that, `changed-files/check` should be used in its own dedicated step before expensive test or build steps.

Reference:

- https://circleci.com/docs/guides/test/rerun-failed-tests/
