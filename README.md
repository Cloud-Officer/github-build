# github-build [![Build](https://github.com/Cloud-Officer/github-build/actions/workflows/build.yml/badge.svg)](https://github.com/Cloud-Officer/github-build/actions/workflows/build.yml)

## Table of Contents

* [Introduction](#introduction)
* [Installation](#installation)
* [Usage](#usage)
  * [Examples](#examples)
  * [Argument Persistence](#argument-persistence)
  * [Configuration Files](#configuration-files)
  * [Feature Triggers](#feature-triggers)
  * [Required Secrets](#required-secrets)
* [Contributing](#contributing)

## Introduction

This is a GitHub Action build file generator. It will detect and enable linters, enable license check, detect the
languages including dependencies like mongodb, mysql, redis and opensearch, enable the unit tests framework, enable CodeDeploy,
detect custom AWS and Vercel deployments and enable Slack notification.

Alongside `.github/workflows/build.yml`, it generates the companion workflows `auto-approve.yml` (approves pull
requests opened by code owners), `dependencies.yml` (weekly cron dependency updates, generated only when the
license check job is enabled and at least one dependency update command was detected — otherwise it is removed)
and, when a `.dockerhub` file is present, `docker.yml`. Any legacy `.github/dependabot.yml` or
`.github/workflows/soup.yml` is removed, as CVE alerts are handled through the repository settings instead.

It will also update the `.gitignore` file and check the repository settings.

The concept is simple. If the build file exists, it will be read and updated. If it does not exist, it will be
generated. Most of the sections are preserved (some are sorted alphabetically).

This tool leverages heavily [ci-actions](https://github.com/Cloud-Officer/ci-actions)
and [soup](https://github.com/Cloud-Officer/soup).

## Installation

Prerequisites are Ruby >= 4.0 and Bundler.

Run `bundle install` to install dependencies, then run the command.

After installation, verify by running:

```bash
./bin/github-build.rb --help
```

## Usage

Run `./bin/github-build.rb` in the root of the project.

```bash
Usage: github-build options

options
        --build_file file            Path to build file
        --excluded_folders excluded_folders
                                     Comma separated list of folders to ignore
        --gitignore_config_file file Path to gitignore config file
        --languages_config_file file Path to languages config file
        --linters_config_file file   Path to linters config file
        --options-apt file           Path to APT options file
        --options-mongodb file       Path to MongoDB options file
        --options-mysql file         Path to MySQL options file
        --options-redis file         Path to Redis options file
        --options-opensearch file    Path to OpenSearch options file
        --application_name application_name
                                     Name of the CodeDeploy application
        --organization organization  GitHub organization
        --force_codedeploy_setup     Force executing the setup step in CodeDeploy even if not technically required
        --get_ignored_folders        Output ignored folders as JSON and exit
        --ignored_linters ignored_linters
                                     Ignore linter keys in linter config file
        --no_strict_version_check    Do not auto-update when VERSION options do not match recommended defaults
        --sync_required_status_checks
                                     On branch protection check mismatch, overwrite remote check list with the expected one instead of erroring (useful when renaming jobs/matrix values)
        --skip_semgrep               Skip Semgrep
        --skip_gitignore             Skip update of gitignore file
        --skip_license_check         Skip license check
        --skip_repository_settings   Skip check of repository settings
        --skip_slack                 Skip slack
    -h, --help                       Show this message
```

Create a [Github personal access token](https://github.com/settings/tokens) and set it in the `GITHUB_TOKEN`
environment variable to enable the repository settings check.

### Examples

On this repository.

```bash
./bin/github-build.rb --skip_slack --skip_repository_settings

Generating build file...
Reading current build file .github/workflows/build.yml...
    Detecting linters...
        Enabling Actionlint...
        Enabling Markdownlint...
        Enabling Rubocop...
        Enabling Semgrep...
        Enabling ShellCheck...
        Enabling Trivy...
        Enabling Yamllint...
    Adding soup...
    Detecting languages...
        Enabling Shell Script...
        Enabling Ruby...
    Adding auto-approve workflow...
Updating .gitignore...
    Detected templates: eclipse, emacs, jetbrains, linux, macos, netbeans, nova, ruby, rubymine, sublimetext, vim, visualstudiocode, windows
    Custom patterns: Claude Code, Claude Code skill review artifacts, Cursor, GitHub Copilot, OpenAI Codex
```

Dropping `--skip_repository_settings` adds a `Configuring repository settings...` section at the end, which requires
`GITHUB_TOKEN` to be set.

### Argument Persistence

When you run `github-build` with command-line arguments, they are saved as a comment on the first line of the
generated build file:

```yaml
# github-build --skip_slack
name: CI
```

On subsequent runs, if you invoke `github-build` with **no arguments**, it automatically reads and re-applies the
saved arguments from the build file. This means you only need to specify your flags once.

To change the persisted arguments, either:

* Run `github-build` again with the new set of flags, or
* Edit the `# github-build ...` comment at the top of the build file directly

One-shot flags are never persisted: `--sync_required_status_checks` is stripped from the saved comment so it only
applies to the run where it is passed. Flags that no longer exist in the CLI but still linger in a saved header are
dropped with a warning on the next run, so old headers self-heal instead of failing.

### Configuration Files

`github-build` ships sensible defaults under `config/`. Each file below can be overridden with a CLI flag pointing at
your own copy. Required top-level keys are validated at startup — a missing key fails fast with a clear `ConfigError`.

#### Linters (`--linters_config_file`, default `config/linters.yaml`)

A map of linter id → definition. Each entry **must** define `short_name`, `long_name`, `uses`, `path`, and
`pattern`. Optional keys: `condition` (a GitHub Actions `if:` expression), `config` (a single config file name or
a list of names when a linter ships several, e.g. Trivy's `["trivy.yaml", ".trivyignore"]`), `preserve_config`
(keep the project's existing config instead of overwriting it), `content_match` / `content_match_pattern` (filter
matched files by their contents), `shebang_match` (regex matched against the first line of extensionless files, so
a widened `pattern` can be narrowed back down — used by ShellCheck for shell tools installed onto `PATH`),
`reviewdog` (the linter reports through reviewdog, so the step receives the job's `GITHUB_TOKEN` instead of the
org PAT), and `permissions` (job-level permissions override).

```yaml
actionlint:
  short_name: Actionlint
  long_name: Github Actions Linter
  uses: cloud-officer/ci-actions/linters/actionlint
  path: ".github/workflows"
  pattern: ".*\\.(yml|yaml)$"
  condition: "github.event_name == 'pull_request'" # optional
  config:                                           # optional (string or list)
```

#### Languages (`--languages_config_file`, default `config/languages.yaml`)

A map of language id → definition. Each entry **must** define `short_name` and `long_name`, and an entry that
declares `file_extension` **must** also declare `dependencies` as a list (an empty list is fine). Common optional
keys: `file_extension`, `version_files[]`, `setup_options[]` (each `{ name, value }`), `runs-on` (runner family
`ubuntu`/`macos` or an explicit image, defaults to `ubuntu`), `cache_option` and `cache_dependency_path_option`
(names of the setup options that enable dependency caching and pass the lockfile paths to hash — both are needed
together), `dependencies[]` (each with at least `dependency_file`, plus
`package_manager_name`/`package_manager_default`/`package_manager_update`, optional `package_manager_once` for a
command that installs a tool system-wide rather than a directory's dependencies, `cache_name` feeding
`cache_option`, `install_dirs[]` and `*_dependency` service markers), `unit_test_framework_name`,
`unit_test_framework_default`.

A top-level `excluded_dirs[]` is the single source of truth for directories skipped everywhere: file scanning
(combined with every dependency entry's `install_dirs`), `.gitignore` template detection, and the
`ghb:excluded-dirs:start` / `ghb:excluded-dirs:end` block regenerated inside each managed linter config
(`.eslintrc.json`, `.flake8`, `.bandit`, `.yamllint.yml`, `.pmd.xml`, `.semgrepignore`, `.cfnlintrc`,
`.swiftlint.yml`, `.markdownlint-cli2.yaml`, `trivy.yaml`). `--get_ignored_folders` prints that resolved list as
JSON.

```yaml
ruby:
  short_name: ruby
  long_name: Ruby
  file_extension: rb
  version_files:
    - .ruby-version
  dependencies:
    - dependency_file: Gemfile
      package_manager_name: Bundler
      package_manager_default: bundle install
      package_manager_update: bundle update
  unit_test_framework_name: RSpec
  unit_test_framework_default: bundle exec rspec
```

#### Service options (`--options-apt`, `--options-mongodb`, `--options-mysql`, `--options-redis`, `--options-opensearch`)

Each file has a top-level `options:` list; every entry **must** define `name` (an optional `value` becomes the
default). These map to environment variables consumed by the generated setup step.

```yaml
options:
  - name: apt-packages
    value:
```

#### Gitignore (`--gitignore_config_file`, default `config/gitignore.yaml`)

* `always_enabled:` — list of [gitignore.io](https://gitignore.io) template names always included.
* `extension_detection:` — map of template → detection rule (`extensions[]`, `files[]`, and/or
  `packages: { <file>: [<regex>...] }`); the template is added when the project matches.
* `custom_patterns:` — map of tool → `{ patterns: [...] }`, always appended under a section delimited by
  `# BEGIN AI Assistants` / `# END AI Assistants` markers.

```yaml
always_enabled:
  - linux
  - macos
custom_patterns:
  claudecode:
    patterns:
      - "# Claude Code"
      - ".claude/"
```

#### External actions (`config/actions.yaml`, no CLI override)

A map of external (non `cloud-officer/*`) action name → pinned version, used as the single source of truth for the
third-party actions emitted into generated workflows. It has no CLI flag: the weekly
`.github/workflows/external-actions-bump.yml` cron bumps these entries to the latest upstream major and opens a pull
request for review. `cloud-officer/*` actions are versioned separately.

```yaml
actions/checkout: v7
peter-evans/create-pull-request: v8
```

### Feature Triggers

Certain features are automatically activated based on the presence of specific files or directories in the
repository. No CLI flags are needed for these; they are detected on every run.

| File / Directory | Effect | How to Disable |
| ---------------- | --------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| `.aws` | Adds an AWS commands job to the workflow | Remove the `.aws` file |
| `appspec.yml` | Adds CodeDeploy and environment deployment jobs (`beta_deploy`, `rc_deploy`, `prod_deploy`) | Remove `appspec.yml` |
| `vercel.json` (or a `"vercel"`/`"next"` dependency in `package.json`) | Adds Vercel deployment jobs (`beta_deploy`, `rc_deploy`, `prod_deploy`) driving the Vercel CLI. Ignored when `appspec.yml` is present (CodeDeploy wins). Custom steps such as `vercel alias` are preserved across regenerations | Remove `vercel.json` and the `vercel`/`next` dependency |
| `.dockerhub` | Generates a separate Docker Hub workflow (`.github/workflows/docker.yml`) that pushes images on tag events | Remove the `.dockerhub` file |
| `ci_scripts/` | Adds `Xcode` to the expected branch protection status checks and, for Swift projects, drops the `Swift Unit Tests` job since Xcode Cloud runs the tests (dependency information is still collected) | Remove the `ci_scripts/` directory |
| `.github/workflows/smoke.yml` | Adds that hand-maintained workflow's job names to the expected branch protection status checks so they stay required across regenerations. The workflow itself is never generated or modified | Remove `.github/workflows/smoke.yml` |

### Required Secrets

Generated workflows reference the following GitHub Actions secrets that must be configured in target repositories.

#### Core Secrets (All Workflows)

| Secret        | Purpose                                                                                                                                                                                  |
|---------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `GH_PAT`      | GitHub Personal Access Token used for API authentication, git operations, and accessing private dependencies across all generated workflow jobs (linters, tests, licenses, deployments). |
| `SSH_KEY`     | SSH private key used for repository checkout and SSH-based git operations across all generated workflow jobs.                                                                            |
| `GH_BOT_PAT`  | Token of the bot account used by `auto-approve.yml` to approve pull requests opened by code owners. Self-approval is skipped when it resolves to the pull request author.                |

#### AWS Secrets (CodeDeploy and Custom AWS Deployments)

Required when using CodeDeploy (`--application_name`) or custom AWS deployments (`.aws` file present). The generated
Vercel deployment jobs also forward these credentials to the shared setup step, so they appear in Vercel-only
repositories as well.

| Secret                  | Purpose                                                                                            |
|-------------------------|----------------------------------------------------------------------------------------------------|
| `AWS_ACCESS_KEY_ID`     | AWS access key for authenticating S3 and CodeDeploy API calls.                                     |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key paired with `AWS_ACCESS_KEY_ID` for AWS API authentication.                         |
| `AWS_DEFAULT_REGION`    | AWS region for API calls and CodeDeploy operations (e.g., `us-east-1`).                            |
| `CODEDEPLOY_BUCKET`     | S3 bucket name for storing CodeDeploy deployment packages. Used exclusively by the CodeDeploy job. |

#### Vercel Secrets (Vercel Deployments)

Required when a `vercel.json` file (or a `vercel`/`next` dependency in `package.json`) is present and `appspec.yml`
is not.

| Secret              | Purpose                                                                  |
|---------------------|--------------------------------------------------------------------------|
| `VERCEL_TOKEN`      | Vercel access token used by the Vercel CLI to pull settings and deploy.  |
| `VERCEL_ORG_ID`     | Vercel organization (team) identifier used by the Vercel CLI.            |
| `VERCEL_PROJECT_ID` | Vercel project identifier used by the Vercel CLI.                        |

#### Slack Secret (Notifications)

Required unless `--skip_slack` is specified.

| Secret              | Purpose                                                                  |
|---------------------|--------------------------------------------------------------------------|
| `SLACK_WEBHOOK_URL` | Incoming webhook URL for posting workflow status notifications to Slack. |

#### Docker Hub Secrets (Docker Image Publishing)

Required when a `.dockerhub` file is present in the repository root.

| Secret            | Purpose                                                              |
|-------------------|----------------------------------------------------------------------|
| `DOCKER_USERNAME` | Docker Hub username for authenticating image pushes.                 |
| `DOCKER_PASSWORD` | Docker Hub password or access token for authenticating image pushes. |

## Contributing

We love your input! We want to make contributing to this project as easy and transparent as possible, whether it's:

* Reporting a bug
* Discussing the current state of the code
* Submitting a fix
* Proposing new features
* Becoming a maintainer

Pull requests are the best way to propose changes to the codebase. We actively welcome your pull requests:

1. Fork the repo and create your branch from `master`.
2. If you've added code that should be tested, add tests. Ensure the test suite passes.
3. Update the documentation.
4. Make sure your code lints.
5. Issue that pull request!

When you submit code changes, your submissions are understood to be under the same [License](LICENSE) that covers the
project. Feel free to contact the maintainers if that's a concern.
