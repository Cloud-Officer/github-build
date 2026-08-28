# Architecture Design

## Table of Contents

- [Architecture diagram](#architecture-diagram)
- [Software units](#software-units)
- [Software of Unknown Provenance](#software-of-unknown-provenance)
- [Critical algorithms](#critical-algorithms)
- [Risk controls](#risk-controls)

## Architecture diagram

```text
+----------------------+     +------------------+     +---------------------+
|    CLI Interface     |     |   Configuration  |     |   External APIs     |
|  bin/github-build.rb |---->|      Files       |     |  (GitHub, gitignore |
+----------------------+     +------------------+     |   .io)              |
         |                        |                    +---------------------+
         v                        v                         ^
+------------------------------------------------------------------------+
|                      GHB::Application (Orchestrator)                    |
|  - Config validation   - Workflow read/write   - Default detection     |
+------------------------------------------------------------------------+
         |  builds GHB::BuildContext, delegates to
         v
+------------------------------------------------------------------------+
|                         Job Builders & Managers                         |
|  VariablesJobBuilder  |  LinterJobBuilder    |  LicensesJobBuilder    |
|  LanguageJobBuilder   |  CodeDeployJobBuilder|  VercelJobBuilder      |
|  AwsJobBuilder        |  SlackJobBuilder     |  DependabotManager     |
|  DockerhubManager     |  AutoMergeManager    |  GitignoreManager      |
|  RepositoryConfigurator|                     |                        |
+------------------------------------------------------------------------+
         |  uses                       |  uses
         v                             v
+-------------------+     +----------------------+     +-----------------+
|  GHB::Workflow    |     |  GHB::FileScanner    |     | GitHubAPIClient |
|  - Read/Write     |     |  - find_files_match  |     | - get/put/post  |
|  - YAML handling  |     |  - file_contains?    |     | - retry/backoff |
+-------------------+     |  - atomic_copy_config|     +-----------------+
   |            |         +----------------------+
   |            |         +----------------------+
   |            |         | GitignoreRules       |
   |            |         | LinterIgnoreRenderer |
   |            |         +----------------------+
   v            v
+----------+ +----------+
| GHB::Job | |GHB::Step |
+----------+ +----------+
         |
         v
+-------------------+
|   Output Files    |
| .github/workflows |
|   build.yml       |
|   dependencies.yml|
|   docker.yml      |
|   auto-approve.yml|
| .gitignore        |
| Linter configs    |
+-------------------+
```

### System Overview

github-build is a Ruby CLI tool that automatically generates and updates GitHub Actions workflow files. It analyzes a repository to detect programming languages, linters, and dependencies, then generates appropriate CI/CD configuration files. The architecture follows a builder pattern where `Application` orchestrates specialized builder and manager classes.

### Component Interactions

1. The CLI entry point (`bin/github-build.rb`) instantiates `GHB::Application`
2. `Application` parses command-line options via `GHB::Options` and validates configuration
3. `Application` bundles the shared inputs (options, old/new workflow, file cache, submodules) into an immutable `GHB::BuildContext` that is passed to every builder
4. `Application` delegates workflow generation to specialized builders: `VariablesJobBuilder`, `LinterJobBuilder`, `LicensesJobBuilder`, `LanguageJobBuilder`, `CodeDeployJobBuilder`, `VercelJobBuilder`, `AwsJobBuilder`, and `SlackJobBuilder`
5. Post-generation managers handle output: `DependabotManager`, `AutoMergeManager`, `DockerhubManager`, `GitignoreManager`, and `RepositoryConfigurator`
6. `GitignoreManager` delegates pure rule logic (template detection, content transforms) to `GHB::GitignoreRules`
7. `FileScanner` mixin provides shared pure-Ruby file operations to builders that need file pattern matching
8. `GitHubAPIClient` centralizes GitHub REST API calls with retry logic for `RepositoryConfigurator`
9. `Workflow`, `Job`, and `Step` classes model the GitHub Actions YAML structure

## Software units

### bin/github-build.rb

**Purpose:** CLI entry point. Instantiates `GHB::Application` with `ARGV`, exits with its return code, and maps uncaught exceptions to a non-zero exit.

**Location:** `bin/github-build.rb`

**Key Components:**

- Rescues `GHB::ConfigError` and prints `Error: <message>` to stderr, exiting 1
- Rescues `StandardError` (including `GHB::GitHubAPIError`), printing the backtrace only when `ENV['DEBUG']` is set, exiting 1

**Internal Dependencies:**

- `GHB::Application`

### GHB Module

**Purpose:** Root module providing constants and namespace for the application.

**Location:** `lib/ghb.rb`

**Key Components:**

- `ConfigError`: Custom exception class for configuration validation failures
- `GitHubAPIError`: Custom exception class for failed GitHub REST API calls (carries the response body for diagnosis)
- `CI_ACTIONS_VERSION`: Version tag for `cloud-officer/ci-actions` references
- `EXTERNAL_ACTIONS_CONFIG_FILE`: Path to the external (third-party) GitHub Actions version manifest (`config/actions.yaml`)
- `external_action(name)`: Class method that resolves an external action to its full `owner/repo@version` ref by reading the pinned version from `config/actions.yaml` (single source of truth bumped by the external-actions cron); raises `ConfigError` if the action is not listed
- `DEFAULT_BUILD_FILE`: Default path for workflow output
- `DEFAULT_GITIGNORE_CONFIG_FILE`: Path to gitignore configuration
- `DEFAULT_LANGUAGES_CONFIG_FILE`: Path to languages configuration
- `DEFAULT_LINTERS_CONFIG_FILE`: Path to linters configuration
- `SERVICES`: Registry of supported services (`apt`, `mongodb`, `mysql`, `redis`, `elasticsearch`); config file paths, CLI flags, config validation entries and dependency detection are all derived from it, so adding a service means adding one symbol plus a `config/options/<service>.yaml` file
- `ALWAYS_ENABLED_SERVICES`: Services applied to every detected language without dependency detection (`apt`)
- `DETECTABLE_SERVICES`: Services enabled only when a language dependency file contains their marker string
- `service_config_file(service)`: Default options file path for a service (`config/options/<service>.yaml`)
- `service_display_name(service)`: Human readable service name used in CLI help text
- `service_config_key(service)`: Config validation key for a service's options file (`<service>_options`)
- `service_dependency_key(service)`: Key holding a service's marker string in a language dependency entry (`<service>_dependency`)
- `DEFAULT_UBUNTU_VERSION`: Default Ubuntu runner OS
- `DEFAULT_MACOS_VERSION`: Default macOS runner OS
- `DEFAULT_JOB_TIMEOUT_MINUTES`: Default job timeout

### GHB::Application

**Purpose:** Main orchestrator that delegates workflow generation to specialized builder and manager classes.

**Location:** `lib/ghb/application.rb`

**Key Components:**

- `initialize(argv)`: Parses command-line arguments and initializes workflow objects
- `execute`: Main entry point that outputs ignored folders (if requested) or delegates to builders and managers in sequence

**Private Methods:**

- `detect_default_branch`: Detects repository default branch via git
- `configure_options(argv)`: Creates and parses `Options` from command-line arguments
- `validate_config!`: Validates all YAML configuration files exist and have valid syntax
- `validate_config_schema(name, relative_path, data)`: Validates YAML schema structure
- `validate_entries(data, relative_path, entry_type, required_keys)`: Validates config entries have required keys
- `validate_option_entries(data, relative_path)`: Validates option config entries
- `workflow_read`: Reads existing workflow YAML file
- `workflow_set_defaults`: Sets workflow defaults from existing or new values
- `collect_required_status_checks`: Collects status checks from generated jobs for branch protection, expanding matrix jobs into the per-combination check names GitHub actually creates (`Job (ubuntu-latest, 3.3)`); a job whose matrix cannot be expanded statically is warned about and skipped. Called from `execute` immediately after `LanguageJobBuilder` and *before* `CodeDeployJobBuilder`, `VercelJobBuilder`, `AwsJobBuilder` and `SlackJobBuilder` run, so only the variables, linter, licenses and unit-test jobs become required checks — deploy and notification jobs are gated by `deploy_if_statement` and must not block a merge
- `matrix_combinations(matrix)` and its helpers (`symbolize_matrix_keys`, `matrix_control_entries`, `matrix_control_entry`, `expandable_axis?`, `scalar_matrix_value?`, `expand_axes`, `reject_excluded`, `apply_includes`): Expand a job matrix in GitHub's documented order — `exclude:` rows dropped first, then `include:` rows merged — returning `nil` when the matrix carries dynamic or non-scalar values
- `workflow_write`: Writes the generated workflow to YAML file

**Includes:**

- `GHB::FileScanner` (mixin for file operations)

**Internal Dependencies:**

- `GHB::Options`
- `GHB::Status`
- `GHB::BuildContext`
- `GHB::Workflow`
- `GHB::VariablesJobBuilder`
- `GHB::LinterJobBuilder`
- `GHB::LicensesJobBuilder`
- `GHB::LanguageJobBuilder`
- `GHB::CodeDeployJobBuilder`
- `GHB::VercelJobBuilder`
- `GHB::AwsJobBuilder`
- `GHB::SlackJobBuilder`
- `GHB::DependabotManager`
- `GHB::DockerhubManager`
- `GHB::GitignoreManager`
- `GHB::AutoMergeManager`
- `GHB::RepositoryConfigurator`

**External Dependencies:**

- `active_support/core_ext/hash/keys`
- `duplicate`
- `find`
- `httparty`
- `json`
- `psych`

### GHB::Options

**Purpose:** Command-line argument parsing and configuration management.

**Location:** `lib/ghb/options.rb`

**Key Components:**

- `initialize(argv)`: Sets up option parser with defaults
- `parse`: Parses command-line arguments
- `args_comment`: Generates comment header for persisting arguments

**Private Methods:**

- `args_from_file(file)`: Reads arguments from existing build file, stripping any flags that no longer exist before replay
- `strip_removed_flags(args, file)`: Drops `REMOVED_FLAGS` from persisted args (warning on stderr) so an old `build.yml` header self-heals on the next regeneration instead of aborting on `OptionParser::InvalidOption`
- `removed_flag?(arg)`: Returns whether an argument matches a removed flag (bare or `flag=value` form)

**Attributes:**

- `application_name`: CodeDeploy application name
- `build_file`: Path to output workflow file
- `excluded_folders`: Folders to ignore during detection
- `force_codedeploy_setup`: Force CodeDeploy setup regardless of detection
- `get_ignored_folders`: Output ignored folders as JSON and exit
- `gitignore_config_file`: Path to gitignore config file
- `ignored_linters`: Hash of linters to skip
- `languages_config_file`: Path to languages config file
- `linters_config_file`: Path to linters config file
- `options_config_files`: Hash of service symbol (`GHB::SERVICES`) to its options config path, one `--options-<service>` flag per entry (`options_config_file(service)` reads a single entry)
- `organization`: GitHub organization name
- `original_argv`: Original command-line arguments for reproducibility
- `skip_gitignore`: Skip gitignore updates
- `skip_license_check`: Skip license checking job
- `skip_repository_settings`: Skip GitHub repository settings configuration
- `skip_semgrep`: Skip semgrep linter
- `skip_slack`: Skip Slack notification job
- `strict_version_check`: Auto-update version files and env vars to recommended values on mismatch (default: true)
- `sync_required_status_checks`: On branch protection check mismatch, overwrite the remote check list with the expected one instead of erroring (useful when renaming jobs or matrix values)

**Constants:**

- `EPHEMERAL_FLAGS`: One-shot flags (e.g. `--sync_required_status_checks`) that are stripped from `original_argv` so they are not persisted to the generated workflow header
- `REMOVED_FLAGS`: Flags removed from the CLI (e.g. `--mono_repo`) that may still linger in a downstream repo's persisted `build.yml` header; stripped with a warning during replay so old headers self-heal

### GHB::Status

**Purpose:** Exit code constants for application status.

**Location:** `lib/ghb/status.rb`

**Key Components:**

- `SUCCESS_EXIT_CODE`: 0
- `ERROR_EXIT_CODE`: 1
- `FAILURE_EXIT_CODE`: 2

### GHB::BuildContext

**Purpose:** Immutable bundle of the values shared across job builders (`options`, `old_workflow`, `new_workflow`, `file_cache`, `submodules`), replacing the recurring keyword-argument clump. The container itself is frozen, though the referenced workflow/cache/submodules objects are still mutated in place by the pipeline.

**Location:** `lib/ghb/build_context.rb`

**Key Components:**

- `initialize(options:, new_workflow:, old_workflow:, file_cache:, submodules:)`: Stores shared inputs and freezes the instance

**Attributes:**

- `options`, `old_workflow`, `new_workflow`, `file_cache`, `submodules` (all read-only)

### GHB::FileScanner (Module)

**Purpose:** Shared utility module providing pure-Ruby file operations to avoid shell command injection. Included as a mixin by Application, LinterJobBuilder, LanguageJobBuilder, GitignoreManager, and GitignoreRules. Provides config-driven directory exclusions sourced from `languages.yaml` and excludes anything the repo's `.gitignore` ignores so ignored files never count toward language/dependency/linter detection.

**Location:** `lib/ghb/file_scanner.rb`

**Key Components:**

- `cached_file_read(path)`: Caches and returns file contents to avoid redundant reads across builders
- `excluded_dirs_from_config`: Builds the list of excluded directory patterns from `languages.yaml` by combining `install_dirs` from all dependency entries with the top-level `excluded_dirs`, memoized per instance
- `excluded_paths_pattern(excluded_paths)`: Builds a single `Regexp.union` of the caller-supplied exclusion fragments and the `/<dir>/` forms of `excluded_dirs_from_config`, so each scanned path is tested once instead of once per fragment. Fragments are escaped, mirroring the literal `String#include?` semantics they replaced
- `find_files_matching(path, pattern, excluded_paths, max_depth:)`: Recursively searches for files matching a regex pattern using `Find.find`, with optional depth limit, a single-pass exclusion test via `excluded_paths_pattern`, and gitignored-path exclusions via `git_ignored?`
- `git_ignored?(file_path)`: Returns whether a path is ignored by the repo's `.gitignore` (and global/exclude rules), matched relative to the repo root
- `gitignored_paths`: Computes the git-ignored files and directories once via `git ls-files --others --ignored --exclude-standard --directory` (so real `.gitignore` semantics apply); returns `[]` when git is unavailable or the cwd is not a repository, leaving scanning unfiltered
- `file_contains?(file, pattern)`: Checks if a file contains a literal string match using `File.foreach`
- `atomic_copy_config(source, target)`: Atomically copies a config file using a temp file and rename, with optional transformation via block

**External Dependencies:**

- `active_support/core_ext/hash/keys`
- `fileutils` (Ruby stdlib, for `atomic_copy_config`)
- `find` (Ruby stdlib)
- `psych`
- `git` CLI (via `git ls-files` for gitignore-aware exclusion)

### GHB::LinterIgnoreRenderer (Module)

**Purpose:** Renders the canonical excluded-directory list (the same set `FileScanner` derives from `languages.yaml`) into each linter config's native ignore syntax, keeping every linter's ignore list aligned with a single source of truth. Each managed config carries a sentinel-delimited block (`ghb:excluded-dirs:start` / `ghb:excluded-dirs:end`) whose body is regenerated; configs without the sentinels are returned unchanged. Included as a mixin by `LinterJobBuilder`.

**Location:** `lib/ghb/linter_ignore_renderer.rb`

**Key Components:**

- `FORMATS`: Maps each managed config file name (`.eslintrc.json`, `.flake8`, `.bandit`, `.yamllint.yml`, `.pmd.xml`, `.semgrepignore`, `.cfnlintrc`, `.swiftlint.yml`, `trivy.yaml`) to its native-syntax body renderer
- `MERGE_EXISTING_CONFIGS`: Managed configs (`trivy.yaml`) whose project-added lines outside the sentinel block must survive a rebuild. These are rendered against the project's own existing file rather than the bundled template; the other managed configs are fully curated by us and refreshed from the bundled template each build
- `ESLINT_EXTRA_IGNORES`: ESLint-only static globs (`**/*.workflow.js`) layered on top of the canonical excluded dirs. Workflow DSL scripts combine a top-level `export const meta` with a top-level `return` that no single ESLint parser mode can parse; they are validated by the Workflow runtime, not ESLint, so they are always ignored
- `manages?(config_name)`: Returns whether a given linter config has a managed excluded-dirs block
- `merges_existing?(config_name)`: Returns whether a config must be merged into the project's existing file (preserving content outside the managed block) rather than copied fresh from the bundled template
- `managed_block?(content)`: Returns whether `content` carries a complete sentinel-delimited managed block
- `render_excluded_dirs(config_name, content, dirs)`: Replaces the sentinel-delimited block in `content` with `dirs` rendered for the target config's native syntax (ESLint `ignorePatterns` — including the `ESLINT_EXTRA_IGNORES` globs, flake8 `extend-exclude`, Bandit `exclude`, yamllint ignore lines, PMD `exclude-pattern` entries, gitignore-style lines for `.semgrepignore`, cfn-lint `ignore_templates` globs, SwiftLint `excluded` quoted `**/<dir>` globs matched at any depth, Trivy `scan.skip-dirs` quoted `**/<dir>` globs), or returns `content` unchanged when unmanaged or missing sentinels

### GHB::GitHubAPIClient

**Purpose:** Centralized GitHub REST and GraphQL API client with shared headers, bounded timeouts, rate-limit-aware retries, and error handling. Raises `GHB::GitHubAPIError` (carrying a truncated response body) when a response code falls outside the caller's `expected_codes`.

**Location:** `lib/ghb/github_api_client.rb`

**Key Components:**

- `initialize(token)`: Creates client with GitHub personal access token
- `get(url, expected_codes:)`: HTTP GET with response validation
- `put(url, body:, expected_codes:)`: HTTP PUT with response validation
- `post(url, body:, headers:, expected_codes:)`: HTTP POST with response validation
- `patch(url, body:, expected_codes:)`: HTTP PATCH with response validation
- `graphql(query, variables:)`: Runs a GraphQL query or mutation against `https://api.github.com/graphql` (bearer auth) and returns its `data` hash. GraphQL reports failures inside a 200 response's `errors` array rather than through the status code, so those — and a body that is not valid JSON — are raised as `GHB::GitHubAPIError` just like a failed REST call. Used for the settings the classic REST API cannot represent, notably branch-protection actor allowlists

**Private Methods:**

- `execute(method, url, body:, headers:, expected_codes:)`: Applies shared headers and the `OPEN_TIMEOUT` / `READ_TIMEOUT` bounds, dispatches through `with_retries`, and validates the response code
- `with_retries`: Retries up to `MAX_RETRIES` on retryable responses and on transient network errors (`RETRYABLE_ERRORS`: `Net::OpenTimeout`, `Net::ReadTimeout`, `Errno::ECONNRESET`, `Errno::ECONNREFUSED`, `SocketError`, `OpenSSL::SSL::SSLError`)
- `retryable_response?(response)`: Returns whether a response is a 5xx or rate-limited
- `rate_limited?(response)`: Detects rate limiting via HTTP 429, or HTTP 403 with `X-RateLimit-Remaining: 0` (primary and secondary/abuse limits)
- `retry_wait(response, retries)` / `rate_limit_wait(response)`: Honors `Retry-After` and `X-RateLimit-Reset` for rate-limited responses (capped at `MAX_RETRY_WAIT`), otherwise falls back to linear backoff (1s, 2s, 3s)

**Constants:**

- `MAX_RETRIES`: Retry attempts per request (3)
- `MAX_RETRY_WAIT`: Cap on a single rate-limit backoff so a far-future `X-RateLimit-Reset` cannot hang CI (60s)
- `OPEN_TIMEOUT` / `READ_TIMEOUT`: Connection and read bounds (10s / 30s) so a stalled connection cannot hang the CLI and the timeout retry path can fire

**External Dependencies:**

- `httparty`
- `json`

### GHB::VariablesJobBuilder

**Purpose:** Builds the "Prepare Variables" job that sets up shared environment outputs for downstream jobs.

**Location:** `lib/ghb/variables_job_builder.rb`

**Key Components:**

- `initialize(context:)`: Accepts a `GHB::BuildContext`
- `build`: Creates the variables preparation job with outputs

### GHB::LinterJobBuilder

**Purpose:** Detects which linters should be enabled based on file patterns in the repository and creates corresponding linting workflow jobs.

**Location:** `lib/ghb/linter_job_builder.rb`

**Includes:** `GHB::FileScanner`, `GHB::LinterIgnoreRenderer`

**Key Components:**

- `initialize(context:)`: Accepts a `GHB::BuildContext`
- `build`: Loads linter config, parses `.gitmodules`, scans for matching files, and creates linter jobs with config file copying. When copying a bundled linter config that `GHB::LinterIgnoreRenderer` manages, regenerates its excluded-dirs block from `excluded_dirs_from_config` so every linter's ignore list stays aligned with `languages.yaml`

**Internal Dependencies:**

- `GHB::LinterIgnoreRenderer`

### GHB::LicensesJobBuilder

**Purpose:** Builds the "Licenses Check" job in the workflow and determines unit test preconditions.

**Location:** `lib/ghb/licenses_job_builder.rb`

**Key Components:**

- `initialize(context:)`: Accepts a `GHB::BuildContext`
- `build`: Creates the licenses check job if not skipped

**Attributes:**

- `unit_tests_conditions`: Conditions string for unit test jobs (read-only)

### GHB::LanguageJobBuilder

**Purpose:** Detects programming languages based on file extensions and dependency files, then creates unit test workflow jobs with appropriate setup, package manager, and test framework steps. Sub-projects whose dependency files sit up to two directory levels below the repo root are detected by default and generate per-subdirectory steps.

**Location:** `lib/ghb/language_job_builder.rb`

**Includes:** `GHB::FileScanner`

**Key Components:**

- `initialize(context:, unit_tests_conditions:, dependencies_commands:)`: Accepts a `GHB::BuildContext` plus the unit-test conditions and accumulated dependency commands
- `build`: Detects languages, checks for database dependencies (MongoDB, MySQL, Redis, Elasticsearch), validates versions, and creates test jobs. For Swift projects with Xcode Cloud (`ci_scripts` directory), removes the unit test job from the workflow while still collecting dependency info
- `self.drop_injected_pat(env)`: Deletes a step's `GITHUB_TOKEN` entry only when its value is exactly the PAT reference this tool used to inject, so workflows generated before the fix self-heal on regeneration while a token the user set deliberately is left alone
- `cache_setup_options(language, detected_dependencies)`: For a language that opted in via `cache_option`/`cache_dependency_path_option` in `config/languages.yaml`, derives the dependency-cache pair from the lockfiles actually found — the cache value from the detected package manager's `cache_name` (npm/yarn/pnpm), the dependency path from every lockfile path, root and sub-project alike. The two are always emitted together: a bare `cache:` makes the setup action look only at the repo root and fail with "Dependencies lock file is not found" in a repo whose lockfile sits in a sub-project. Caching is left off when no package manager is cacheable or when two are detected, since the setup actions accept only one. Unlike the other setup options, the cache pair is applied to the Setup step even when its `with:` was inherited non-empty from a previously generated workflow — otherwise the cache would stay dead in every existing repo

**Constants:**

- `DEPENDENCY_STEP_TOKEN`: Token exposed to dependency-install steps — the ephemeral, repo-scoped `${{secrets.GITHUB_TOKEN}}` rather than the org-scoped `secrets.GH_PAT`, because install steps execute arbitrary third-party code (postinstall hooks, plugins). It is kept rather than dropped because Tuist's SwiftPM resolution reads it, and it raises the API rate limit to a per-repository budget instead of a shared org-wide one. The other package managers authenticate by other means (Composer github-oauth, Bundler `BUNDLE_GITHUB__COM`, npm/yarn/pnpm `NODE_AUTH_TOKEN`, Carthage `GITHUB_ACCESS_TOKEN`, private sibling repos over SSH)
- `INJECTED_PAT`: The `${{secrets.GH_PAT}}` reference formerly injected, retained so `drop_injected_pat` can recognise and strip it
- `SUBDIR_DEPENDENCY_SCAN_DEPTH`: How many directory levels below the repo root a sub-project dependency file may sit and still be detected (2)
- `SWIFT_DEPLOY_CHECK_FLAGS`: Deploy flags (`DEPLOY_ON_BETA`, `DEPLOY_ON_RC`, `DEPLOY_ON_PROD`, `DEPLOY_MACOS`, `DEPLOY_TVOS`) that extend the Swift unit-test `if:` so the job also runs on deploy triggers
- `CODEDEPLOY_SETUP_LANGUAGES`: Languages (`go`, `php`) whose dependency steps are also staged as CodeDeploy pre-steps for `CodeDeployJobBuilder`

**Attributes:**

- `code_deploy_pre_steps`: Pre-deployment steps collected during language detection (read-only)
- `dependencies_steps`: Dependency management steps collected during detection (read-only)
- `dependencies_commands`: Accumulated dependency update commands (read-only)

### GHB::CodeDeployJobBuilder

**Purpose:** Builds AWS CodeDeploy jobs for deploying applications via S3 and CodeDeploy, including environment-specific deployment jobs.

**Location:** `lib/ghb/code_deploy_job_builder.rb`

**Key Components:**

- `initialize(context:, code_deploy_pre_steps:)`: Accepts a `GHB::BuildContext` and the collected pre-deployment steps
- `build`: Creates CodeDeploy packaging and per-environment deployment jobs

### GHB::VercelJobBuilder

**Purpose:** Builds the Vercel `beta_deploy` / `rc_deploy` / `prod_deploy` jobs — the Vercel counterpart to `CodeDeployJobBuilder`. Triggered when a `vercel.json` marker is present or `package.json` declares a `"vercel"` / `"next"` dependency. CodeDeploy takes precedence: when `appspec.yml` exists these jobs are left to `CodeDeployJobBuilder` so the `*_deploy` job names do not collide.

**Location:** `lib/ghb/vercel_job_builder.rb`

**Key Components:**

- `initialize(context:)`: Accepts a `GHB::BuildContext`
- `build`: Creates the three per-environment Vercel CLI deploy jobs (`prod` publishes with `--prod`; `beta`/`rc` deploy a preview build and capture the URL). Generated steps are Setup, Install Vercel CLI, Pull Vercel Environment Information, and Deploy Project to Vercel; any other step on an existing `*_deploy` job (e.g. project-specific `vercel alias` steps) is preserved across regenerations.

**Constants:**

- `DEPLOYS`: The generated deploy jobs, mapping each environment key to its display name and Vercel CLI target (`beta` → "Beta Deploy"/`preview`, `rc` → "RC Deploy"/`preview`, `prod` → "Prod Deploy"/`production`)
- `GENERATED_STEP_NAMES`: The step names this builder owns; every other step found on an existing `*_deploy` job is treated as a custom step to preserve
- `NODE_VERSION_FILES`: Version files (`.node-version`, `.nvmrc`) that make the ci-actions setup read the Node version from the repository, so a `node-version` carried over from a previous Setup step is dropped (mirrors `LanguageJobBuilder#build_setup_step`)
- `DEPLOY_JOB_TIMEOUT_MINUTES`: Timeout for the deploy jobs (60), double the `GHB::DEFAULT_JOB_TIMEOUT_MINUTES` used elsewhere, because a Vercel build runs inside the deploy step

### GHB::AwsJobBuilder

**Purpose:** Builds the "AWS" job for custom AWS deployment scripts.

**Location:** `lib/ghb/aws_job_builder.rb`

**Key Components:**

- `initialize(context:)`: Accepts a `GHB::BuildContext`
- `build`: Creates the AWS job if `.aws` file exists

### GHB::SlackJobBuilder

**Purpose:** Builds the "Publish Statuses" job for Slack build notifications.

**Location:** `lib/ghb/slack_job_builder.rb`

**Key Components:**

- `initialize(context:)`: Accepts a `GHB::BuildContext`
- `build`: Creates the Slack notification job if not skipped

### GHB::AutoMergeManager

**Purpose:** Manages auto-merge workflow generation for code owners, providing automatic approval of pull requests authored by CODEOWNERS.

**Location:** `lib/ghb/auto_merge_manager.rb`

**Key Components:**

- `initialize(auto_merge_workflow:)`: Accepts auto-merge workflow object
- `save`: Configures the auto-approve workflow with CODEOWNERS detection and auto-approval, and writes `.github/workflows/auto-approve.yml` (removing the legacy `auto-merge.yml` if present). The CODEOWNERS membership check uses `GH_PAT`, while the approval step uses `GH_BOT_PAT` so the bot identity satisfies the `require_code_owner_reviews` branch-protection rule

### GHB::DependabotManager

**Purpose:** Manages the cron-based dependency update workflow and removes legacy dependabot configuration files.

**Location:** `lib/ghb/dependabot_manager.rb`

**Key Components:**

- `initialize(new_workflow:, cron_workflow:, dependencies_steps:, dependencies_commands:)`: Accepts workflow objects and dependency configuration
- `save`: Removes `.github/dependabot.yml` if present (CVE alerts are handled by repository settings), then writes `.github/workflows/dependencies.yml` when the licenses job exists and dependency steps were collected; otherwise removes that workflow so a repo that no longer has dependencies does not keep a stale cron

**Private Methods:**

- `save_dependencies_workflow`: Builds the weekly cron workflow (`0 9 * * 1`) from the collected dependency steps and commands, and removes the legacy `.github/workflows/soup.yml`

**External Dependencies:**

- `fileutils`

### GHB::DockerhubManager

**Purpose:** Manages Docker Hub image publishing workflow generation.

**Location:** `lib/ghb/dockerhub_manager.rb`

**Key Components:**

- `initialize(dockerhub_workflow:)`: Accepts DockerHub workflow object
- `save`: Configures and writes `.github/workflows/docker.yml` if a `.dockerhub` file exists. The workflow declares a `contents: read` least-privilege default and the single publish job opts into the scopes `cloud-officer/ci-actions/docker` needs (`attestations: write`, `id-token: write` for build-provenance signing); Docker Hub itself authenticates via `DOCKER_USERNAME` / `DOCKER_PASSWORD`, so `packages: write` is deliberately not requested

### GHB::GitignoreManager

**Purpose:** Manages `.gitignore` file generation by detecting project types, fetching templates from gitignore.io, and applying project-specific modifications.

**Location:** `lib/ghb/gitignore_manager.rb`

**Includes:** `GHB::FileScanner`

**Key Components:**

- `initialize(context:, rules:)`: Accepts a `GHB::BuildContext` and an optional `GHB::GitignoreRules` (defaults to one built from the context)
- `update`: Detects templates, fetches from API, applies modifications, appends a single AI Assistants section — one `# BEGIN AI Assistants` / `# END AI Assistants` block whose body holds one blank-line-separated group per tool, built from `GHB::GitignoreRules#detect_custom_pattern_groups` — and writes `.gitignore`

**Internal Dependencies:**

- `GHB::GitignoreRules`

**External Dependencies:**

- `active_support/core_ext/hash/keys`
- `httparty`
- `psych`

### GHB::GitignoreRules

**Purpose:** Pure rule logic for `.gitignore` generation — template detection, excluded-path building, and content transforms. Extracted from `GitignoreManager` so the logic has a public, directly-testable API while `GitignoreManager` retains the I/O orchestration (HTTP fetch and file writes).

**Location:** `lib/ghb/gitignore_rules.rb`

**Includes:** `GHB::FileScanner`

**Key Components:**

- `initialize(context:)`: Accepts a `GHB::BuildContext`
- `detect_gitignore_templates(config)`: Returns the sorted list of detected gitignore templates
- `build_gitignore_excluded_paths`: Builds excluded paths from `languages.yaml` config, submodules, and `--excluded_folders`
- `uncomment_jetbrains_patterns(content)`: Uncomments JetBrains IDE patterns
- `comment_conflicting_patterns(content)`: Comments out directory patterns (`bin/`, `lib/`, `var/`) that conflict with common project directories
- `preserve_custom_entries(git_ignore, custom_patterns)`: Preserves custom entries from an existing `.gitignore`, dropping a hand-added copy of a now-managed pattern that sits outside the AI Assistants section (exact line match only, so `docs/migration/keep.md` survives even though `docs/migration/` is managed) — the regenerated block is the single source of truth, and keeping the stray line would emit it twice
- `detect_custom_pattern_groups(config)`: Returns the always-appended custom patterns grouped per tool (comment line plus that tool's ignore rules), regardless of whether the corresponding tool is detected, so they cannot be accidentally committed. Grouping keeps a tool contributing several rules (e.g. the Claude Code skill review artifacts) rendered as one commented block instead of being split into arbitrary pairs
- `detect_custom_patterns(config)`: Flattened view of `detect_custom_pattern_groups` used for the "skip already-managed lines" comparison in `preserve_custom_entries`

### GHB::RepositoryConfigurator

**Purpose:** Configures GitHub repository settings including branch protection rules, security features (vulnerability alerts, secret scanning, CodeQL), and repository options via the GitHub REST API, falling back to GraphQL for the one setting REST cannot express (the force-push actor allowlist).

**Location:** `lib/ghb/repository_configurator.rb`

**Key Components:**

- `initialize(options:, required_status_checks:, default_branch:)`: Accepts options, collected status checks, and default branch
- `configure`: Validates GITHUB_TOKEN, retrieves repo info, and configures branch protection, security features, and repository options

**Private Methods:**

- `configure_branch_protection(github_client, repo_url, current_protection, protection_exists, repository)`: Assembles the expected check list (generated jobs, augmented checks, Xcode Cloud checks), validates it, applies the branch protection payload, enables required signatures, and enforces the force-push allowlist
- `augment_required_status_checks`: Adds integration-derived checks to the collected list — a `Vercel` check when `package.json` declares `"next"`, plus the job names of a hand-maintained `.github/workflows/smoke.yml` (read dynamically, since that workflow is intentionally not generated). CodeQL checks are deliberately excluded: default setup runs in "smart mode" and only on relevant file changes, so it blocks PRs through code scanning alerts rather than a required check
- `log_codeql_languages(github_client, repo_url)`: Reports the languages CodeQL default setup covers (filtering the redundant `javascript-typescript` / `typescript` entries the API returns alongside `javascript`); informational only — it contributes no required checks
- `discover_xcode_cloud_checks(github_client, repo_url, actual_checks, expected_checks, protection_exists)`: Returns Xcode Cloud checks when a `ci_scripts` directory exists, dispatching to the protection-based or commit-status-based discovery below
- `required_checks_differ?(expected_checks, actual_checks)`: Returns whether the two check lists differ in either direction
- `validate_required_checks!(expected_checks, actual_checks, protection_exists)`: Prints the missing/extra checks and raises on a mismatch unless `--sync_required_status_checks` is set
- `build_branch_protection_payload(current_protection, expected_checks, protection_exists, sync_required_status_checks)`: Builds the PUT body — reusing the remote check list unless syncing, preserving `app_id` values when syncing, and `filter_map`-ing dismissal/bypass users and teams so the payload never carries a `[null]` array (which GitHub rejects with 422)
- `enforce_force_push_allowlist(github_client, repository)`: Reads the default branch's force-push actor allowlist over GraphQL after the PUT and clears it when non-empty. The `allow_force_pushes: false` sent in the PUT is silently a no-op while that allowlist exists — the PUT still returns 200, but the branch stays force-pushable and REST reports the same `allow_force_pushes` boolean for "nobody may force push" and "only these actors may". Names every actor found and raises if the list survives clearing, so the run never reports success over a rewritable branch history
- `fetch_branch_protection_rule(github_client, repository)`: Fetches the classic branch protection rule (id plus `bypassForcePushAllowances`) for `refs/heads/<default_branch>`. Returns `nil` when no rule exists, and warns without failing when GraphQL is unreachable — an unreadable allowlist is undetected drift, not proven drift
- `clear_force_push_allowlist(github_client, rule_id)`: Runs `updateBranchProtectionRule(bypassForcePushActorIds: [])` and returns the actors GitHub still reports as allowed, re-verifying the mutation in the same round trip
- `force_push_actors(rule)`: Flattens `bypassForcePushAllowances` nodes into `User <login>` / `Team <slug>` / `App <slug>` labels for the warnings and error message
- `discover_xcode_cloud_checks_from_protection(actual_checks, expected_checks)`: Extracts Xcode Cloud checks from existing branch protection by finding checks not in the expected set
- `discover_xcode_cloud_checks_from_statuses(github_client, repo_url)`: Discovers Xcode Cloud checks from commit statuses on the default branch for new repos without existing protection
- `configure_repository_options(github_client, repo_url)`: Applies merge strategy, wiki/projects, and delete-branch-on-merge settings
- `enable_security_features` / `disable_security_features`: Toggles secret scanning features by repository visibility
- `enable_codeql_default_setup` / `disable_codeql_default_setup`: Toggles CodeQL default setup by repository visibility

**Internal Dependencies:**

- `GHB::GitHubAPIClient`

**External Dependencies:**

- `json`
- `psych`
- `uri`

### GHB::Workflow

**Purpose:** Models a GitHub Actions workflow with serialization to/from YAML.

**Location:** `lib/ghb/workflow/workflow.rb`

**Key Components:**

- `initialize(name)`: Creates workflow with name
- `read(file)`: Parses existing workflow YAML file
- `write(file, header:)`: Writes workflow to YAML file, rewriting `${GITHUB_*}` references to `${{github.*}}` in YAML values via `rewrite_github_refs` while preserving them in shell `run:` bodies (where they are runner-exported env vars). `${{secrets.GITHUB_TOKEN}}` is deliberately **not** rewritten to `${{secrets.GH_PAT}}`: the former blanket rewrite put a long-lived org-scoped PAT into every step's environment and silently overrode a `GITHUB_TOKEN` a user had set on purpose in a preserved job. Steps needing cross-repo or PR-creation rights request `secrets.GH_PAT` explicitly instead
- `do_job(id, &block)`: DSL method to define jobs
- `do_name`, `do_run_name`, `do_on`, `do_permissions`, `do_env`, `do_defaults`, `do_concurrency`: DSL setters for the top-level workflow keys
- `deploy_needs`: Returns the job ids a deploy job must wait on (linters, licenses, unit tests)
- `deploy_if_statement`: Returns the shared `if:` guard applied to deploy jobs
- `to_h`: Converts workflow to hash for YAML serialization

**Attributes:**

- `name`, `run_name`, `on`, `permissions`, `env`, `defaults`, `concurrency`, `jobs`

### GHB::Job

**Purpose:** Models a GitHub Actions job with steps and configuration.

**Location:** `lib/ghb/workflow/job.rb`

**Key Components:**

- `initialize(id)`: Creates job with identifier
- `copy_properties(object, properties)`: Copies properties from another job, defaulting to `COPYABLE_PROPERTIES`
- `do_step(name, options, &block)`: DSL method to define steps
- `do_name`, `do_permissions`, `do_needs`, `do_if`, `do_runs_on`, `do_environment`, `do_concurrency`, `do_outputs`, `do_env`, `do_defaults`, `do_timeout_minutes`, `do_strategy`, `do_continue_on_error`, `do_container`, `do_services`, `do_uses`, `do_with`, `do_secrets`: DSL setters for the job keys
- `to_h`: Converts job to hash for YAML serialization

**Constants:**

- `COPYABLE_PROPERTIES`: Job keys carried over from a previously generated workflow so hand-made edits survive regeneration (every attribute except `id` and `steps`)

**Attributes:**

- `id`, `name`, `permissions`, `needs`, `if`, `runs_on`, `environment`
- `concurrency`, `outputs`, `env`, `defaults`, `steps`, `timeout_minutes`, `strategy`
- `continue_on_error`, `container`, `services`, `uses`, `with`, `secrets`

### GHB::Step

**Purpose:** Models a single step within a GitHub Actions job.

**Location:** `lib/ghb/workflow/step.rb`

**Key Components:**

- `initialize(name, options)`: Creates step with name and optional configuration
- `copy_properties(object, properties)`: Copies properties from another step, defaulting to `COPYABLE_PROPERTIES`
- `do_id`, `do_if`, `do_name`, `do_uses`, `do_run`, `do_shell`, `do_with`, `do_env`, `do_continue_on_error`, `do_timeout_minutes`: DSL setters for the step keys
- `find_step(steps, step_name)`: Finds a step by name in a list
- `to_h`: Converts step to hash for YAML serialization

**Constants:**

- `COPYABLE_PROPERTIES`: Step keys carried over from a previously generated workflow (every attribute except `name`, which is the lookup key)

**Attributes:**

- `id`, `if`, `name`, `uses`, `run`, `shell`, `with`, `env`
- `continue_on_error`, `timeout_minutes`

### Configuration Files

**Purpose:** YAML configuration files defining linters, languages, and options.

**Locations:**

- `config/linters.yaml`: Linter definitions with patterns and configurations
- `config/languages.yaml`: Language definitions with setup options, dependencies (including `install_dirs` for exclusion), and top-level `excluded_dirs` for non-package-manager directories
- `config/gitignore.yaml`: Gitignore template detection rules
- `config/actions.yaml`: Pinned versions for external (third-party) GitHub Actions emitted into generated workflows; single source of truth read via `GHB.external_action` and bumped by the external-actions cron
- `config/options/apt.yaml`: APT package configuration
- `config/options/mongodb.yaml`: MongoDB service version and settings
- `config/options/mysql.yaml`: MySQL service version and settings
- `config/options/redis.yaml`: Redis service version and settings
- `config/options/elasticsearch.yaml`: Elasticsearch service version and settings
- `config/linters/`: Bundled linter config templates copied or symlinked into target repositories by `GHB::LinterJobBuilder` (`.rubocop.yml`, `.eslintrc.json`, `.flake8`, `.bandit`, `.yamllint.yml`, `.pmd.xml`, `.semgrepignore`, `.cfnlintrc`, `.swiftlint.yml`, `trivy.yaml`, `.trivyignore`, `.golangci.yml`, `.hadolint.yaml`, `.protolint.yaml`, `.markdownlint-cli2.yaml`, `.shellcheckrc`, `.editorconfig`). The subset listed in `GHB::LinterIgnoreRenderer::FORMATS` has its excluded-dirs block regenerated on copy
- `config/linters/.trivyignore`: Shared baseline of Trivy IDs (CVE, secret and misconfiguration check IDs are all accepted) suppressed in every repository, each annotated with the reason it is wrong or unfixable everywhere. Unlike `trivy.yaml` it is not merge-managed: it is symlinked from the scripts submodule's or a local `linters/` directory when present, otherwise copied fresh from the bundled template on each run, so repo-local additions to it do not survive a rebuild. Repo-specific exclusions belong in that repo's `trivy.yaml`, outside the managed `ghb:excluded-dirs` block

### bin/update_versions.sh

**Purpose:** Shell script to update language and service versions in configuration files.

**Location:** `bin/update_versions.sh`

**Key Components:**

- Fetches latest versions from official sources (go.dev, nodejs.org, etc.)
- Updates `config/languages.yaml` with latest language versions
- Updates `config/options/*.yaml` with latest service versions
- Uses `yq` for YAML manipulation (always invoked as `yq e --indent=2 ... -i <file>`)
- `require_version(name, value)`: Aborts with `::error::could not resolve the latest <name> version` when a lookup resolves to an empty or `null` value, so a failed upstream fetch can never write an empty version into a config file

**Behavior:** Runs under `set -euo pipefail`; because the filter stages (`jq`, `grep`, `sort`, `tail`) exit 0 on empty input, each lookup pipeline ends with `|| true` and is validated by `require_version`. The AWS-first service lookups (DocumentDB, Aurora MySQL, ElastiCache Valkey, OpenSearch) still degrade to their public fallback when the AWS CLI is unavailable, and an unresolved or unsupported Valkey version degrades to the `latest` tag. Covered by `tests/update_versions.bats`, which stubs `curl`/`aws`/`pyenv`/`rbenv` and runs against a throwaway copy of `config/`.

### bump-actions/bump-actions.sh

**Purpose:** Resolves each external GitHub Action in `config/actions.yaml` to its latest upstream version and (with `--apply`) rewrites the pinned versions in place. Powers the weekly `external-actions-bump.yml` cron, which opens a review PR with the bumps. Because the Ruby builders read the same manifest via `GHB.external_action`, bumping it propagates the new version to every generated workflow.

**Location:** `bump-actions/bump-actions.sh`

**Key Components:**

- `main`: Parses `--apply` / `--pr-body-file`, reads the manifest, resolves bumps, and optionally rewrites the manifest and emits a PR body with a bumps table and truncated upstream release notes
- `resolve_bump(org/repo, version)`: Determines the new version for a ref — floating major tags (`vN`) bump only when the upstream major increases; exact semver pins bump to the latest strictly-newer release; SHA pins and branch pins are skipped
- `manifest_entries`, `latest_version`, `tag_exists`, `version_gt`, `apply_bump`: Pure, individually-testable helpers (covered by `tests/bump-actions.bats`)

**Behavior:** Skips `cloud-officer/*` actions (versioned separately via `CI_ACTIONS_VERSION`); honors `BUMP_MANIFEST` to override the manifest path for testing; requires an authenticated `gh` on `PATH`.

## Software of Unknown Provenance

See [soup.md](soup.md) for the complete list of third-party dependencies.

This project uses Ruby gems for:

- **Core functionality:** activesupport (hash manipulation), httparty (HTTP client), psych (YAML parsing), optparse (CLI arguments), duplicate (deep cloning)
- **Development:** rubocop and extensions (code linting), rspec (testing), webmock (HTTP stubbing), simplecov (coverage reporting)

All dependencies are managed via Bundler with versions locked in `Gemfile.lock`. The soup.md file documents risk levels, requirements justification, and verification reasoning for each package.

## Critical algorithms

### Linter Detection Algorithm

**Purpose:** Automatically detects which linters should be enabled based on file patterns.

**Location:** `lib/ghb/linter_job_builder.rb` in `GHB::LinterJobBuilder#build`

**Implementation:**

1. Loads linter configuration from `config/linters.yaml`
2. Parses `.gitmodules` for submodule paths to exclude
3. For each linter, uses pure Ruby `find_files_matching` with regex pattern matching to search for files
4. Excludes specified folders, submodules, config-driven directories, and gitignored paths from search
5. If a `content_match` string is configured, further filters matched files by checking file contents via `file_contains?`. When `content_match_pattern` is also set, only files whose path matches that sub-pattern require the content check; other files pass through unconditionally
6. If matching files remain, enables the linter and resolves each of its configuration files via a priority chain. A linter's `config` may be a single file name or a list (e.g., Trivy ships `["trivy.yaml", ".trivyignore"]`); `configs_for` normalizes it and each entry is resolved independently: cleans up deprecated config files that were renamed (tracked via `RENAMED_CONFIGS` constant, e.g., `.markdownlint.yml` → `.markdownlint-cli2.yaml`), preserves existing project-specific configs (when `preserve_config` is set and a non-symlink file exists, e.g., KTLint's `.editorconfig`), creates symlinks to a scripts submodule `linters/` directory, creates symlinks to a local `linters/` directory (both skipped for a *project-owned* config — see `project_owned_config?`: a merge-managed config the project has deliberately turned from a symlink into a real file carrying the sentinel block, which re-symlinking would silently discard), or falls back to `atomic_copy_config` to safely copy bundled configs with optional transformation (e.g., regenerating the excluded-dirs block via `GHB::LinterIgnoreRenderer` for managed configs, or uncommenting Rails rules in `.rubocop.yml`). For merge-managed configs (`trivy.yaml`), `config_source` points `atomic_copy_config` at the project's own existing file when it already carries the sentinel block, so the managed `scan.skip-dirs` block is regenerated while project-added entries outside it (extra skip-dirs, or a repo-local `scan.skip-files`) are preserved. This is what lets a repo whose shared configs come from a scripts submodule carry an exclusion that must not leak into the other repos sharing that submodule
7. Creates workflow job with appropriate steps for each enabled linter

**Complexity:** O(n * m) where n = number of linters, m = files in repository

### Language Detection Algorithm

**Purpose:** Detects programming languages and their dependencies to configure build jobs.

**Location:** `lib/ghb/language_job_builder.rb` in `GHB::LanguageJobBuilder#build`

**Implementation:**

1. Loads language and options configurations from YAML files
2. For each language entry (skipping non-Hash values like `excluded_dirs`), uses pure Ruby `find_files_matching` to search for files matching the language's file extension
3. Verifies dependency files exist (e.g., `go.mod`, `package.json`)
4. Scans up to two directory levels below the repo root for sub-project dependency files (excluding vendored/ignored directories) and generates per-subdirectory package manager and test steps
5. Checks dependency files (including sub-project files) for database dependencies (MongoDB, MySQL, Redis, Elasticsearch) using `file_contains?`
6. Detects version files (`.ruby-version`, `.nvmrc`, etc.) and validates against recommended versions
7. Merges setup options with version validation (strict mode auto-updates version files and env vars to recommended values, non-strict warns)
8. Creates unit test workflow job with appropriate setup, package manager, and test steps
9. For Swift projects with Xcode Cloud (`ci_scripts` directory), removes the unit test job from the workflow while retaining collected dependency info for the cron workflow

**Complexity:** O(n * m) where n = number of languages, m = files in repository

### Repository Settings Configuration

**Purpose:** Configures GitHub repository settings including branch protection.

**Location:** `lib/ghb/repository_configurator.rb` in `GHB::RepositoryConfigurator#configure`

**Implementation:**

1. Validates `GITHUB_TOKEN` environment variable is present
2. Retrieves current repository info to check visibility (public/private) via `GitHubAPIClient`
3. Gets current branch protection via GitHub API (handles 404 for new repos without protection)
4. Augments the checks collected from generated workflow jobs (the variables, linter, licenses and unit-test jobs only — deploy and notification jobs are built after collection and are deliberately not required; matrix jobs already expanded into their per-combination check names by `GHB::Application#collect_required_status_checks`) with a `Vercel` check (when `package.json` declares `"next"`) and the job names of a hand-maintained `.github/workflows/smoke.yml`. CodeQL languages are logged for visibility only — CodeQL default setup runs in "smart mode" and is intentionally not made a required check
5. Discovers Xcode Cloud checks dynamically when `ci_scripts` directory exists: extracts from existing branch protection or from commit statuses on the default branch for new repos
6. Validates existing checks match expected checks (only for existing protection); on mismatch, raises an error unless `--sync_required_status_checks` is set, in which case the remote check list is rebuilt from `expected_checks` while preserving `app_id` values for existing entries (so integration-specific configurations such as Xcode Cloud checks are not clobbered)
7. Builds the protection payload, preserving existing dismissal restrictions and bypass allowances while dropping entries GitHub returns without a `login`/`slug` so the request body never contains a `[null]` users/teams array
8. Configures branch protection with required status checks, code-owner review enforcement (`require_code_owner_reviews: true`), pull request reviews, and conversation resolution, then enables required signatures via the separate `required_signatures` endpoint
9. Reads the default branch's force-push actor allowlist over GraphQL and clears it when non-empty, because `allow_force_pushes: false` in the REST payload is silently ignored while that allowlist exists; the actors are named in the output and an allowlist that survives clearing fails the run
10. Configures repository options: enables vulnerability alerts and automated security fixes, disables wiki and projects, configures merge strategies, and enables delete branch on merge
11. Enables secret scanning features (push protection, validity checks, non-provider patterns, AI detection) for public repos; disables them for private repos (GHAS cost avoidance)
12. Enables CodeQL default setup for public repos; disables it for private repos (GHAS cost avoidance)

**Security Considerations:**

- Uses GITHUB_TOKEN for API authentication via `GitHubAPIClient`
- Validates branch protection before modification
- Preserves existing dismissal restrictions and bypass allowances
- Verifies over GraphQL that the default branch is actually not force-pushable, since the REST `allow_force_pushes` boolean cannot distinguish "nobody may force push" from "these actors may"
- Handles new repositories without existing branch protection gracefully

### Gitignore Template Detection

**Purpose:** Detects project types to generate comprehensive .gitignore files.

**Location:** `lib/ghb/gitignore_manager.rb` in `GHB::GitignoreManager#update`; rule logic in `lib/ghb/gitignore_rules.rb` in `GHB::GitignoreRules#detect_gitignore_templates` and `GHB::GitignoreRules#detect_custom_pattern_groups`

**Implementation:**

1. Loads detection rules from `config/gitignore.yaml`
2. Adds always-enabled templates (OS, IDEs)
3. For each extension detection entry, checks file extensions using `find_files_matching` (with excluded paths combining config-driven directories from `languages.yaml`, submodules, the `--excluded_folders` option, and gitignored paths), specific files that indicate the technology, and package dependencies in manifest files using pure Ruby regex
4. Fetches templates from gitignore.io API via HTTParty
5. Applies project-specific modifications (uncomment JetBrains patterns, comment out conflicting directory patterns like `bin/`, `lib/`, `var/`)
6. Always appends AI assistant ignore patterns (Claude Code, Claude Code skill review artifacts, Cursor, Copilot, OpenAI Codex) via `detect_custom_pattern_groups` to prevent accidental commits even if the tool isn't actively used, writing them into one sentinel-delimited section (`# BEGIN AI Assistants` / `# END AI Assistants`) whose body carries one blank-line-separated group per tool, so a tool with several ignore rules stays a single commented block
7. Preserves custom entries from existing .gitignore, dropping stray hand-added copies of the now-managed patterns so they are not emitted twice

## Risk controls

### Security Measures

**Authentication:**

- GitHub API calls use personal access tokens where cross-repository or PR-creation rights are genuinely required (`GH_PAT`; `GH_BOT_PAT` for auto-merge approvals so the bot identity satisfies the code-owner review rule). Each such step requests the secret explicitly — there is no blanket token rewrite at workflow-write time
- Dependency-install steps receive the ephemeral, repo-scoped `secrets.GITHUB_TOKEN` (`GHB::LanguageJobBuilder::DEPENDENCY_STEP_TOKEN`) rather than the org-scoped PAT, since those steps run arbitrary third-party code; unit-test steps receive no token at all
- Repository configuration uses `GITHUB_TOKEN` from the runtime environment
- SSH keys used for repository checkout (`SSH_KEY` secret)
- AWS credentials for CodeDeploy operations

**Authorization:**

- Repository settings only modifiable with appropriate token permissions
- Branch protection enforces code review requirements, including code-owner reviews
- Required status checks prevent merging broken code

**Input Validation:**

- Command-line arguments validated via optparse
- YAML configuration parsed with safe_load (no arbitrary code execution)
- File paths validated before operations

**Secrets Management:**

- Secrets referenced via GitHub Actions secret syntax
- No secrets stored in generated files
- Token permissions scoped appropriately in workflow files
- The generated dependency-update `git config ... insteadOf` rewrites (built in `GHB::Application#initialize`) are scoped to `${{github.repository_owner}}/` rather than bare `github.com/`, so `GH_PAT` is not attached to arbitrary GitHub URLs fetched later in the run (e.g. transitive git-source dependencies), limiting the exfiltration surface to the owning organization's own repositories
- `GHB::Options::EPHEMERAL_FLAGS` keeps one-shot flags out of the argument comment persisted in the generated workflow header
- Regeneration strips the previously injected `${{secrets.GH_PAT}}` from unit-test step environments via `GHB::LanguageJobBuilder.drop_injected_pat`, so repos whose `build.yml` predates the fix stop carrying the PAT once rebuilt

### Error Handling

- `GHB::ConfigError` raised for configuration validation failures (missing or malformed YAML, or an external action absent from `config/actions.yaml`)
- `GHB::GitHubAPIError` raised by `GHB::GitHubAPIClient` for unexpected REST response codes, carrying the method, URL, status, and a truncated response body for diagnosis
- Both are rescued in `bin/github-build.rb`; `StandardError` is caught at top level with backtrace output (DEBUG-only via `ENV['DEBUG']`)
- Exit codes via `GHB::Status` indicate success (0), error (1), or failure (2)
- Transient API failures (5xx, rate limiting, connection timeouts/resets) are retried by `GHB::GitHubAPIClient` before surfacing
- File operations in `GHB::FileScanner` rescue `Errno::ENOENT` and `Errno::EACCES` for graceful degradation
- `GHB::FileScanner#gitignored_paths` returns `[]` when git is unavailable or the cwd is not a repository, leaving scanning unfiltered rather than failing

### Logging and Monitoring

- Progress output to stdout during execution
- Warnings for version mismatches highlighted with color
- Errors include context for debugging
- Generated workflow files include argument comment for reproducibility

### Failure Modes

| Failure Mode                | Impact                      | Mitigation                                         |
|-----------------------------|-----------------------------|----------------------------------------------------|
| GitHub API unavailable      | Cannot configure repository | Exit with error, manual configuration possible     |
| Invalid configuration YAML  | Application crash           | Validate YAML structure, use safe_load             |
| Missing linter config files | Linter step may fail        | Copy default configs, symlink to scripts submodule |
| File permission errors      | Cannot write output         | Check permissions, exit with error                 |
| Network timeout             | API calls fail              | Bounded open/read timeouts, up to 3 retries        |
| GitHub API rate limiting    | API calls rejected          | Retry honoring Retry-After / X-RateLimit-Reset     |
| Version mismatch detected   | Warning or error            | Configurable strict mode for version checking      |
| Status check list mismatch  | Protection update fails     | Error unless `--sync_required_status_checks`       |
| git unavailable in cwd      | Ignored files scanned       | Scanning proceeds unfiltered instead of failing    |
