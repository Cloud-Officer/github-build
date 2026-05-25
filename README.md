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
languages including dependencies like mongodb, mysql, redis and elasticsearch, enable the unit tests framework, enable CodeDeploy,
detect custom AWS deployment, enable Slack notification and enable Dependabot Jira integration.

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
        --application_name application_name
                                     Name of the CodeDeploy application
        --build_file file            Path to build file
        --excluded_folders excluded_folders
                                     Comma separated list of folders to ignore
        --force_codedeploy_setup     Force executing the setup step in CodeDeploy even if not technically required
        --get_ignored_folders        Output ignored folders as JSON and exit
        --gitignore_config_file file Path to gitignore config file
        --ignored_linters ignored_linters
                                     Ignore linter keys in linter config file
        --languages_config_file file Path to languages config file
        --linters_config_file file   Path to linters config file
        --mono_repo                  Scan one level deep for language dependency files
        --options-apt file           Path to APT options file
        --options-mongodb file       Path to MongoDB options file
        --options-mysql file         Path to MySQL options file
        --options-redis file         Path to Redis options file
        --options-elasticsearch file Path to Elasticsearch options file
        --organization organization  GitHub organization
        --skip_semgrep               Skip Semgrep
        --skip_gitignore             Skip update of gitignore file
        --skip_license_check         Skip license check
        --skip_repository_settings   Skip check of repository settings
        --skip_slack                 Skip slack
        --no_strict_version_check    Do not auto-update when VERSION options do not match recommended defaults
        --sync_required_status_checks
                                     On branch protection check mismatch, overwrite remote check list with the expected one instead of erroring (useful when renaming jobs/matrix values)
    -h, --help                       Show this message
```

Create a [Github personal access token](https://github.com/settings/tokens) and set it in the `GITHUB_TOKEN`
environment variable to enable the repository settings check.

### Examples

On this repository.

```bash
./bin/github-build.rb --skip_slack

Generating build file...
Reading current build file .github/workflows/build.yml...
    Detecting linters...
        Enabling Actionlint...
        Enabling Markdownlint...
        Enabling Rubocop...
        Enabling Yamllint...
    Adding soup...
    Detecting languages...
        Enabling Ruby...
Checking repository settings...
Updating .gitignore...
```

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

### Configuration Files

`github-build` ships sensible defaults under `config/`. Each file can be overridden with a CLI flag pointing at your
own copy. Required top-level keys are validated at startup — a missing key fails fast with a clear `ConfigError`.

#### Linters (`--linters_config_file`, default `config/linters.yaml`)

A map of linter id → definition. Each entry **must** define `short_name`, `long_name`, `uses`, `path`, and
`pattern`. Optional keys: `condition` (a GitHub Actions `if:` expression), `config` (linter config file to copy).

```yaml
actionlint:
  short_name: Actionlint
  long_name: Github Actions Linter
  uses: cloud-officer/ci-actions/linters/actionlint
  path: ".github/workflows"
  pattern: ".*\\.(yml|yaml)$"
  condition: "github.event_name == 'pull_request'" # optional
  config:                                           # optional
```

#### Languages (`--languages_config_file`, default `config/languages.yaml`)

A map of language id → definition. Each entry **must** define `short_name` and `long_name`. Common optional keys:
`file_extension`, `version_files[]`, `setup_options[]` (each `{ name, value }`), `dependencies[]` (each with at
least `dependency_file`, plus `package_manager_name`/`package_manager_default`/`package_manager_update`,
optional `install_dirs[]` and `*_dependency` service markers), `unit_test_framework_name`,
`unit_test_framework_default`. A top-level `excluded_dirs[]` lists directories to skip during file scanning.

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

#### Service options (`--options-apt`, `--options-mongodb`, `--options-mysql`, `--options-redis`, `--options-elasticsearch`)

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
* `custom_patterns:` — map of tool → `{ patterns: [...] }`, always appended under an AI-Assistants section.

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

### Feature Triggers

Certain features are automatically activated based on the presence of specific files or directories in the repository
root. No CLI flags are needed for these; they are detected on every run.

| File / Directory | Effect | How to Disable |
| ---------------- | --------------------------------------------------------------------------------------------------------- | ----------------------------------- |
| `.aws` | Adds an AWS commands job to the workflow | Remove the `.aws` file |
| `appspec.yml` | Adds CodeDeploy and environment deployment jobs (`beta_deploy`, `rc_deploy`, `prod_deploy`) | Remove `appspec.yml` |
| `vercel.json` (or a `"vercel"`/`"next"` dependency in `package.json`) | Adds Vercel deployment jobs (`beta_deploy`, `rc_deploy`, `prod_deploy`) driving the Vercel CLI. Ignored when `appspec.yml` is present (CodeDeploy wins). Custom steps such as `vercel alias` are preserved across regenerations | Remove `vercel.json` and the `vercel`/`next` dependency |
| `.dockerhub` | Generates a separate Docker Hub workflow (`.github/workflows/docker.yml`) that pushes images on tag events | Remove the `.dockerhub` file |
| `ci_scripts/` | Adds `Xcode` to the expected branch protection status checks | Remove the `ci_scripts/` directory |

### Required Secrets

Generated workflows reference the following GitHub Actions secrets that must be configured in target repositories.

#### Core Secrets (All Workflows)

| Secret    | Purpose                                                                                                                                                                                  |
|-----------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `GH_PAT`  | GitHub Personal Access Token used for API authentication, git operations, and accessing private dependencies across all generated workflow jobs (linters, tests, licenses, deployments). |
| `SSH_KEY` | SSH private key used for repository checkout and SSH-based git operations across all generated workflow jobs.                                                                            |

#### AWS Secrets (CodeDeploy and Custom AWS Deployments)

Required when using CodeDeploy (`--application_name`) or custom AWS deployments (`.aws` file present).

| Secret                  | Purpose                                                                                            |
|-------------------------|----------------------------------------------------------------------------------------------------|
| `AWS_ACCESS_KEY_ID`     | AWS access key for authenticating S3 and CodeDeploy API calls.                                     |
| `AWS_SECRET_ACCESS_KEY` | AWS secret key paired with `AWS_ACCESS_KEY_ID` for AWS API authentication.                         |
| `AWS_DEFAULT_REGION`    | AWS region for API calls and CodeDeploy operations (e.g., `us-east-1`).                            |
| `CODEDEPLOY_BUCKET`     | S3 bucket name for storing CodeDeploy deployment packages. Used exclusively by the CodeDeploy job. |

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
