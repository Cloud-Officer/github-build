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
         |  delegates to
         v
+------------------------------------------------------------------------+
|                         Job Builders & Managers                         |
|  VariablesJobBuilder  |  LinterJobBuilder    |  LicensesJobBuilder    |
|  LanguageJobBuilder   |  CodeDeployJobBuilder|  AwsJobBuilder         |
|  SlackJobBuilder      |  DependabotManager   |  DockerhubManager      |
|  AutoMergeManager     |  GitignoreManager    |  RepositoryConfigurator|
+------------------------------------------------------------------------+
         |  uses                       |  uses
         v                             v
+-------------------+     +---------------------+     +-----------------+
|  GHB::Workflow    |     |  GHB::FileScanner   |     | GitHubAPIClient |
|  - Read/Write     |     |  - find_files_match  |     | - get/put/post  |
|  - YAML handling  |     |  - file_contains?    |     | - retry logic   |
+-------------------+     |  - atomic_copy_config|     +-----------------+
   |            |          +---------------------+
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
| .gitignore        |
| Linter configs    |
+-------------------+
```

### System Overview

github-build is a Ruby CLI tool that automatically generates and updates GitHub Actions workflow files. It analyzes a repository to detect programming languages, linters, and dependencies, then generates appropriate CI/CD configuration files. The architecture follows a builder pattern where `Application` orchestrates specialized builder and manager classes.

### Component Interactions

1. The CLI entry point (`bin/github-build.rb`) instantiates `GHB::Application`
2. `Application` parses command-line options via `GHB::Options` and validates configuration
3. `Application` delegates workflow generation to specialized builders: `VariablesJobBuilder`, `LinterJobBuilder`, `LicensesJobBuilder`, `LanguageJobBuilder`, `CodeDeployJobBuilder`, `AwsJobBuilder`, and `SlackJobBuilder`
4. Post-generation managers handle output: `DependabotManager`, `AutoMergeManager`, `DockerhubManager`, `GitignoreManager`, and `RepositoryConfigurator`
5. `FileScanner` mixin provides shared pure-Ruby file operations to builders that need file pattern matching
6. `GitHubAPIClient` centralizes GitHub REST API calls with retry logic for `RepositoryConfigurator`
7. `Workflow`, `Job`, and `Step` classes model the GitHub Actions YAML structure

## Software units

### GHB Module

**Purpose:** Root module providing constants and namespace for the application.

**Location:** `lib/ghb.rb`

**Key Components:**

- `ConfigError`: Custom exception class for configuration validation failures
- `CI_ACTIONS_VERSION`: Version tag for ci-actions references
- `DEFAULT_BUILD_FILE`: Default path for workflow output
- `DEFAULT_GITIGNORE_CONFIG_FILE`: Path to gitignore configuration
- `DEFAULT_LANGUAGES_CONFIG_FILE`: Path to languages configuration
- `DEFAULT_LINTERS_CONFIG_FILE`: Path to linters configuration
- `OPTIONS_APT_CONFIG_FILE`: Path to APT options configuration
- `OPTIONS_MONGODB_CONFIG_FILE`: Path to MongoDB options configuration
- `OPTIONS_MYSQL_CONFIG_FILE`: Path to MySQL options configuration
- `OPTIONS_REDIS_CONFIG_FILE`: Path to Redis options configuration
- `OPTIONS_ELASTICSEARCH_CONFIG_FILE`: Path to Elasticsearch options configuration
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
- `collect_required_status_checks`: Collects status checks from generated jobs for branch protection
- `workflow_write`: Writes the generated workflow to YAML file

**Includes:**

- `GHB::FileScanner` (mixin for file operations)

**Internal Dependencies:**

- `GHB::Options`
- `GHB::Status`
- `GHB::Workflow`
- `GHB::VariablesJobBuilder`
- `GHB::LinterJobBuilder`
- `GHB::LicensesJobBuilder`
- `GHB::LanguageJobBuilder`
- `GHB::CodeDeployJobBuilder`
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
- `args_from_file(file)`: Reads arguments from existing build file

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
- `mono_repo`: Scan one level deep for language dependency files
- `only_dependabot`: Only generate dependabot workflow
- `options_config_file_apt`: Path to APT options config
- `options_config_file_mongodb`: Path to MongoDB options config
- `options_config_file_mysql`: Path to MySQL options config
- `options_config_file_redis`: Path to Redis options config
- `options_config_file_elasticsearch`: Path to Elasticsearch options config
- `organization`: GitHub organization name
- `original_argv`: Original command-line arguments for reproducibility
- `skip_dependabot`: Skip dependabot workflow generation
- `skip_gitignore`: Skip gitignore updates
- `skip_license_check`: Skip license checking job
- `skip_repository_settings`: Skip GitHub repository settings configuration
- `skip_semgrep`: Skip semgrep linter
- `skip_slack`: Skip Slack notification job
- `strict_version_check`: Auto-update version files and env vars to recommended values on mismatch (default: true)

### GHB::Status

**Purpose:** Exit code constants for application status.

**Location:** `lib/ghb/status.rb`

**Key Components:**

- `SUCCESS_EXIT_CODE`: 0
- `ERROR_EXIT_CODE`: 1
- `FAILURE_EXIT_CODE`: 2

### GHB::FileScanner (Module)

**Purpose:** Shared utility module providing pure-Ruby file operations to avoid shell command injection. Included as a mixin by Application, LinterJobBuilder, LanguageJobBuilder, and GitignoreManager. Provides config-driven directory exclusions sourced from `languages.yaml`.

**Location:** `lib/ghb/file_scanner.rb`

**Key Components:**

- `cached_file_read(path)`: Caches and returns file contents to avoid redundant reads across builders
- `excluded_dirs_from_config`: Builds the list of excluded directory patterns from `languages.yaml` by combining `install_dirs` from all dependency entries with the top-level `excluded_dirs`, memoized per instance
- `find_files_matching(path, pattern, excluded_paths, max_depth:)`: Recursively searches for files matching a regex pattern using `Find.find`, with optional depth limit, path exclusions, and config-driven directory exclusions via `excluded_dirs_from_config`
- `file_contains?(file, pattern)`: Checks if a file contains a literal string match using `File.foreach`
- `atomic_copy_config(source, target)`: Atomically copies a config file using a temp file and rename, with optional transformation via block

**External Dependencies:**

- `find` (Ruby stdlib)

### GHB::GitHubAPIClient

**Purpose:** Centralized GitHub REST API client with shared headers, retry logic with linear backoff, and error handling.

**Location:** `lib/ghb/github_api_client.rb`

**Key Components:**

- `initialize(token)`: Creates client with GitHub personal access token
- `get(url, expected_codes:)`: HTTP GET with response validation
- `put(url, body:, expected_codes:)`: HTTP PUT with response validation
- `post(url, body:, headers:, expected_codes:)`: HTTP POST with response validation
- `patch(url, body:, expected_codes:)`: HTTP PATCH with response validation

**External Dependencies:**

- `httparty`
- `json`

### GHB::VariablesJobBuilder

**Purpose:** Builds the "Prepare Variables" job that sets up shared environment outputs for downstream jobs.

**Location:** `lib/ghb/variables_job_builder.rb`

**Key Components:**

- `initialize(options:, new_workflow:)`: Accepts options and new workflow
- `build`: Creates the variables preparation job with outputs

### GHB::LinterJobBuilder

**Purpose:** Detects which linters should be enabled based on file patterns in the repository and creates corresponding linting workflow jobs.

**Location:** `lib/ghb/linter_job_builder.rb`

**Includes:** `GHB::FileScanner`

**Key Components:**

- `initialize(options:, submodules:, old_workflow:, new_workflow:, file_cache:)`: Accepts configuration and workflow objects
- `build`: Loads linter config, parses `.gitmodules`, scans for matching files, and creates linter jobs with config file copying

### GHB::LicensesJobBuilder

**Purpose:** Builds the "Licenses Check" job in the workflow and determines unit test preconditions.

**Location:** `lib/ghb/licenses_job_builder.rb`

**Key Components:**

- `initialize(options:, old_workflow:, new_workflow:)`: Accepts options and workflow objects
- `build`: Creates the licenses check job if not skipped

**Attributes:**

- `unit_tests_conditions`: Conditions string for unit test jobs (read-only)

### GHB::LanguageJobBuilder

**Purpose:** Detects programming languages based on file extensions and dependency files, then creates unit test workflow jobs with appropriate setup, package manager, and test framework steps. Supports mono-repo mode with per-subdirectory steps.

**Location:** `lib/ghb/language_job_builder.rb`

**Includes:** `GHB::FileScanner`

**Key Components:**

- `initialize(options:, submodules:, old_workflow:, new_workflow:, unit_tests_conditions:, file_cache:, dependencies_commands:)`: Accepts comprehensive configuration
- `build`: Detects languages, checks for database dependencies (MongoDB, MySQL, Redis, Elasticsearch), validates versions, and creates test jobs. For Swift projects with Xcode Cloud (`ci_scripts` directory), removes the unit test job from the workflow while still collecting dependency info

**Attributes:**

- `code_deploy_pre_steps`: Pre-deployment steps collected during language detection (read-only)
- `dependencies_steps`: Dependency management steps collected during detection (read-only)
- `dependencies_commands`: Accumulated dependency update commands (read-only)

### GHB::CodeDeployJobBuilder

**Purpose:** Builds AWS CodeDeploy jobs for deploying applications via S3 and CodeDeploy, including environment-specific deployment jobs.

**Location:** `lib/ghb/code_deploy_job_builder.rb`

**Key Components:**

- `initialize(options:, old_workflow:, new_workflow:, code_deploy_pre_steps:)`: Accepts options, workflows, and pre-deployment steps
- `build`: Creates CodeDeploy packaging and per-environment deployment jobs

### GHB::AwsJobBuilder

**Purpose:** Builds the "AWS" job for custom AWS deployment scripts.

**Location:** `lib/ghb/aws_job_builder.rb`

**Key Components:**

- `initialize(options:, old_workflow:, new_workflow:)`: Accepts options and workflow objects
- `build`: Creates the AWS job if `.aws` file exists

### GHB::SlackJobBuilder

**Purpose:** Builds the "Publish Statuses" job for Slack build notifications.

**Location:** `lib/ghb/slack_job_builder.rb`

**Key Components:**

- `initialize(options:, old_workflow:, new_workflow:)`: Accepts options and workflow objects
- `build`: Creates the Slack notification job if not skipped

### GHB::AutoMergeManager

**Purpose:** Manages auto-merge workflow generation for code owners, enabling automatic squash-merge of pull requests authored by CODEOWNERS.

**Location:** `lib/ghb/auto_merge_manager.rb`

**Key Components:**

- `initialize(auto_merge_workflow:)`: Accepts auto-merge workflow object
- `save`: Configures the auto-merge workflow with CODEOWNERS detection, auto-approval, and writes `.github/workflows/auto-merge.yml`

### GHB::DependabotManager

**Purpose:** Manages the cron-based dependency update workflow and removes legacy dependabot configuration files.

**Location:** `lib/ghb/dependabot_manager.rb`

**Key Components:**

- `initialize(new_workflow:, cron_workflow:, dependencies_steps:, dependencies_commands:)`: Accepts workflow objects and dependency configuration
- `save`: Removes `.github/dependabot.yml` if present and writes the dependencies workflow

### GHB::DockerhubManager

**Purpose:** Manages Docker Hub image publishing workflow generation.

**Location:** `lib/ghb/dockerhub_manager.rb`

**Key Components:**

- `initialize(dockerhub_workflow:)`: Accepts DockerHub workflow object
- `save`: Configures and writes the DockerHub workflow if `.dockerhub` file exists

### GHB::GitignoreManager

**Purpose:** Manages `.gitignore` file generation by detecting project types, fetching templates from gitignore.io, and applying project-specific modifications.

**Location:** `lib/ghb/gitignore_manager.rb`

**Includes:** `GHB::FileScanner`

**Key Components:**

- `initialize(options:, submodules:, file_cache:)`: Accepts options, submodules list, and file cache
- `update`: Detects templates, fetches from API, applies modifications, and writes `.gitignore`

**External Dependencies:**

- `httparty`

### GHB::RepositoryConfigurator

**Purpose:** Configures GitHub repository settings including branch protection rules, security features (vulnerability alerts, secret scanning, CodeQL), and repository options via the GitHub REST API.

**Location:** `lib/ghb/repository_configurator.rb`

**Key Components:**

- `initialize(options:, required_status_checks:, default_branch:)`: Accepts options, collected status checks, and default branch
- `configure`: Validates GITHUB_TOKEN, retrieves repo info, and configures branch protection, security features, and repository options
- `discover_xcode_cloud_checks_from_protection(actual_checks, expected_checks)`: Extracts Xcode Cloud checks from existing branch protection by finding checks not in the expected set
- `discover_xcode_cloud_checks_from_statuses(github_client, repo_url)`: Discovers Xcode Cloud checks from commit statuses on the default branch for new repos without existing protection

**Internal Dependencies:**

- `GHB::GitHubAPIClient`

**External Dependencies:**

- `json`

### GHB::Workflow

**Purpose:** Models a GitHub Actions workflow with serialization to/from YAML.

**Location:** `lib/ghb/workflow/workflow.rb`

**Key Components:**

- `initialize(name)`: Creates workflow with name
- `read(file)`: Parses existing workflow YAML file
- `write(file, header:)`: Writes workflow to YAML file
- `do_job(id, &block)`: DSL method to define jobs
- `to_h`: Converts workflow to hash for YAML serialization

**Attributes:**

- `name`, `run_name`, `on`, `permissions`, `env`, `defaults`, `concurrency`, `jobs`

### GHB::Job

**Purpose:** Models a GitHub Actions job with steps and configuration.

**Location:** `lib/ghb/workflow/job.rb`

**Key Components:**

- `initialize(id)`: Creates job with identifier
- `copy_properties(object, properties)`: Copies properties from another job
- `do_step(name, options, &block)`: DSL method to define steps
- `to_h`: Converts job to hash for YAML serialization

**Attributes:**

- `id`, `name`, `permissions`, `needs`, `if`, `runs_on`, `environment`
- `concurrency`, `outputs`, `env`, `defaults`, `steps`, `timeout_minutes`, `strategy`
- `continue_on_error`, `container`, `services`, `uses`, `with`, `secrets`

### GHB::Step

**Purpose:** Models a single step within a GitHub Actions job.

**Location:** `lib/ghb/workflow/step.rb`

**Key Components:**

- `initialize(name, options)`: Creates step with name and optional configuration
- `copy_properties(object, properties)`: Copies properties from another step
- `find_step(steps, step_name)`: Finds a step by name in a list
- `to_h`: Converts step to hash for YAML serialization

**Attributes:**

- `id`, `if`, `name`, `uses`, `run`, `shell`, `with`, `env`
- `continue_on_error`, `timeout_minutes`

### Configuration Files

**Purpose:** YAML configuration files defining linters, languages, and options.

**Locations:**

- `config/linters.yaml`: Linter definitions with patterns and configurations
- `config/languages.yaml`: Language definitions with setup options, dependencies (including `install_dirs` for exclusion), and top-level `excluded_dirs` for non-package-manager directories
- `config/gitignore.yaml`: Gitignore template detection rules
- `config/options/apt.yaml`: APT package configuration
- `config/options/mongodb.yaml`: MongoDB service version and settings
- `config/options/mysql.yaml`: MySQL service version and settings
- `config/options/redis.yaml`: Redis service version and settings
- `config/options/elasticsearch.yaml`: Elasticsearch service version and settings

### bin/update_versions.sh

**Purpose:** Shell script to update language and service versions in configuration files.

**Location:** `bin/update_versions.sh`

**Key Components:**

- Fetches latest versions from official sources (go.dev, nodejs.org, etc.)
- Updates `config/languages.yaml` with latest language versions
- Updates `config/options/*.yaml` with latest service versions
- Uses `yq` for YAML manipulation

## Software of Unknown Provenance

See [soup.md](soup.md) for the complete list of third-party dependencies.

This project uses Ruby gems for:

- **Core functionality:** activesupport (hash manipulation), httparty (HTTP client), psych (YAML parsing), optparse (CLI arguments), duplicate (deep cloning)
- **Development:** rubocop and extensions (code linting), rspec (testing), webmock (HTTP stubbing)

All dependencies are managed via Bundler with versions locked in `Gemfile.lock`. The soup.md file documents risk levels, requirements justification, and verification reasoning for each package.

## Critical algorithms

### Linter Detection Algorithm

**Purpose:** Automatically detects which linters should be enabled based on file patterns.

**Location:** `lib/ghb/linter_job_builder.rb` in `GHB::LinterJobBuilder#build`

**Implementation:**

1. Loads linter configuration from `config/linters.yaml`
2. Parses `.gitmodules` for submodule paths to exclude
3. For each linter, uses pure Ruby `find_files_matching` with regex pattern matching to search for files
4. Excludes specified folders and submodules from search
5. If a `content_match` string is configured, further filters matched files by checking file contents via `file_contains?`. When `content_match_pattern` is also set, only files whose path matches that sub-pattern require the content check; other files pass through unconditionally
6. If matching files remain, enables the linter and resolves configuration files via a priority chain: cleans up deprecated config files that were renamed (tracked via `RENAMED_CONFIGS` constant, e.g., `.markdownlint.yml` → `.markdownlint-cli2.yaml`), preserves existing project-specific configs (when `preserve_config` is set and a non-symlink file exists), creates symlinks to a scripts submodule `linters/` directory, creates symlinks to a local `linters/` directory, or falls back to `atomic_copy_config` to safely copy bundled configs with optional transformation (e.g., uncommenting Rails rules in `.rubocop.yml`)
7. Creates workflow job with appropriate steps for each enabled linter

**Complexity:** O(n * m) where n = number of linters, m = files in repository

### Language Detection Algorithm

**Purpose:** Detects programming languages and their dependencies to configure build jobs.

**Location:** `lib/ghb/language_job_builder.rb` in `GHB::LanguageJobBuilder#build`

**Implementation:**

1. Loads language and options configurations from YAML files
2. For each language entry (skipping non-Hash values like `excluded_dirs`), uses pure Ruby `find_files_matching` to search for files matching the language's file extension
3. Verifies dependency files exist (e.g., `go.mod`, `package.json`)
4. In mono-repo mode, scans one level deep for subdirectory dependency files and generates per-subdirectory package manager and test steps
5. Checks dependency files (including subdirectory files in mono-repo mode) for database dependencies (MongoDB, MySQL, Redis, Elasticsearch) using `file_contains?`
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
4. Detects Vercel integration (Next.js) and CodeQL languages, filtering redundant entries
5. Discovers Xcode Cloud checks dynamically when `ci_scripts` directory exists: extracts from existing branch protection or from commit statuses on the default branch for new repos
6. Collects required status checks from generated workflow jobs
7. Validates existing checks match expected checks (only for existing protection)
8. Preserves existing dismissal restrictions and bypass allowances
9. Configures branch protection with required status checks, pull request reviews, signed commits, and conversation resolution
10. Configures repository options: enables vulnerability alerts and automated security fixes, disables wiki and projects, configures merge strategies, and enables delete branch on merge
11. Enables secret scanning features (push protection, validity checks, non-provider patterns, AI detection) for public repos; disables them for private repos (GHAS cost avoidance)
12. Enables CodeQL default setup for public repos; disables it for private repos (GHAS cost avoidance)

**Security Considerations:**

- Uses GITHUB_TOKEN for API authentication via `GitHubAPIClient`
- Validates branch protection before modification
- Preserves existing dismissal restrictions and bypass allowances
- Handles new repositories without existing branch protection gracefully

### Gitignore Template Detection

**Purpose:** Detects project types to generate comprehensive .gitignore files.

**Location:** `lib/ghb/gitignore_manager.rb` in `GHB::GitignoreManager#update`, `GHB::GitignoreManager#detect_gitignore_templates`, and `GHB::GitignoreManager#detect_custom_patterns`

**Implementation:**

1. Loads detection rules from `config/gitignore.yaml`
2. Adds always-enabled templates (OS, IDEs)
3. For each extension detection entry, checks file extensions using `find_files_matching` (with config-driven excluded paths from `languages.yaml` plus submodules), specific files that indicate the technology, and package dependencies in manifest files using pure Ruby regex
4. Fetches templates from gitignore.io API via HTTParty
5. Applies project-specific modifications (uncomment JetBrains patterns, comment out conflicting directory patterns like `bin/`, `lib/`, `var/`)
6. Always appends AI assistant ignore patterns (Claude Code, Cursor, Copilot, OpenAI Codex) via `detect_custom_patterns` to prevent accidental commits even if the tool isn't actively used
7. Preserves custom entries from existing .gitignore

## Risk controls

### Security Measures

**Authentication:**

- GitHub API calls use personal access tokens (GH_PAT secret)
- SSH keys used for repository checkout (SSH_KEY secret)
- AWS credentials for CodeDeploy operations

**Authorization:**

- Repository settings only modifiable with appropriate token permissions
- Branch protection enforces code review requirements
- Required status checks prevent merging broken code

**Input Validation:**

- Command-line arguments validated via optparse
- YAML configuration parsed with safe_load (no arbitrary code execution)
- File paths validated before operations

**Secrets Management:**

- Secrets referenced via GitHub Actions secret syntax
- No secrets stored in generated files
- Token permissions scoped appropriately in workflow files

### Error Handling

- `GHB::ConfigError` raised for configuration validation failures (missing or malformed YAML)
- `StandardError` caught at top level with backtrace output (DEBUG-only via `ENV['DEBUG']`)
- Exit codes via `GHB::Status` indicate success (0), error (1), or failure (2)
- API errors raise exceptions with descriptive messages
- File operations rescue `Errno::ENOENT` and `Errno::EACCES` for graceful degradation

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
| Network timeout             | API calls fail              | HTTParty handles timeouts, user can retry          |
| Version mismatch detected   | Warning or error            | Configurable strict mode for version checking      |
