# github build [![Build](https://github.com/Cloud-Officer/github-build/actions/workflows/build.yml/badge.svg)](https://github.com/Cloud-Officer/github-build/actions/workflows/build.yml)

This is a GitHub Action build file generator. It will detect and enable linters, enable license check, detect the
languages including dependencies like mongodb, mysql and redis, enable the unit tests framework, enable CodeDeploy,
detect custom AWS deployment, enable Slack notification and enable Dependabot Jira integration.

It will also update the `.gitignore` file and check the repository settings.

The concept is simple. If the build file exists, it will be read and updated. If it does not exist, it will be
generated. Most of the sections are preserved (some are sorted alphabetically).

This tool leverages heavily [ci-actions](https://github.com/Cloud-Officer/ci-actions)
and [soup](https://github.com/Cloud-Officer/soup).

## Installation

You can run `bundle install` and then run the command `github-build` or you can install the latest via homebrew
with `brew install cloud-officer/ci/githubbuild`.

## Usage

Run `github-build` in the root of the project.

```bash
Usage: github-build options

options
        --application_name application_name
                                     Name of the CodeDeploy application
        --build_file file            Path to build file
        --excluded_folders excluded_folders
                                     Comma separated list of folders to ignore
        --ignored_linters ignored_linters
                                     Ignore linter keys in linter config file
        --languages_config_file file Path to languages config file
        --linters_config_file file   Path to linters config file
        --only_dependabot            Just do Dependabot and nothing else
        --options-apt file           Path to APT options file
        --options-mongodb file       Path to MongoDB options file
        --options-mysql file         Path to MySQL options file
        --options-redis file         Path to Redis options file
        --organization organization  GitHub organization
        --skip_dependabot            Skip dependabot
        --skip_gitignore             Skip update of gitignore file
        --skip_license_check         Skip license check
        --skip_repository_settings   Skip check of repository settings
        --skip_slack                 Skip slack
    -h, --help                       Show this message
```

Create a [Github personal access token](https://github.com/settings/tokens) and set it in the `GITHUB_TOKEN`
environment variable to enable the repository settings check.

To force a custom AWS deployment, create an empty file `.aws` in the root of the project.

## Examples

On this repository.

```bash
github-build --skip_dependabot  --skip_slack

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
