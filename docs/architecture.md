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
|  bin/github-build.rb |---->|      Files       |---->|  (GitHub, gitignore |
+----------------------+     +------------------+     |   .io, etc.)        |
         |                        |                    +---------------------+
         v                        v                         |
+------------------------------------------------------------------------+
|                           GHB::Application                              |
|  - Workflow generation    - Linter detection    - Language detection   |
|  - Repository settings    - Gitignore updates   - Dependabot config    |
|  - Licenses check         - AWS commands        - Slack notification   |
|  - DockerHub workflow     - Cron workflow        - Config validation    |
+------------------------------------------------------------------------+
         |                        |                         |
         v                        v                         v
+-------------------+     +------------------+     +---------------------+
|  GHB::Workflow    |     |    GHB::Job      |     |    GHB::Step        |
|  - Read/Write     |     |  - Properties    |     |  - Properties       |
|  - YAML handling  |     |  - Steps mgmt    |     |  - Serialization    |
+-------------------+     +------------------+     +---------------------+
         |
         v
+-------------------+
|   Output Files    |
| .github/workflows |
|   build.yml       |
|   cron.yml        |
|   dockerhub.yml   |
| .gitignore        |
| Linter configs    |
+-------------------+
```

### System Overview

github-build is a Ruby CLI tool that automatically generates and updates GitHub Actions workflow files. It analyzes a repository to detect programming languages, linters, and dependencies, then generates appropriate CI/CD configuration files.

### Component Interactions

1. The CLI entry point (`bin/github-build.rb`) instantiates `GHB::Application`
2. `Application` parses command-line options via `GHB::Options`
3. `Application` orchestrates workflow generation by reading existing workflow files, detecting linters based on file patterns, detecting languages based on file extensions and dependency files, generating workflow jobs and steps, and writing output files
4. `Workflow`, `Job`, and `Step` classes model GitHub Actions structure
5. External API calls configure repository settings via GitHub REST API

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
- `DEFAULT_UBUNTU_VERSION`: Default Ubuntu runner OS
- `DEFAULT_MACOS_VERSION`: Default macOS runner OS
- `DEFAULT_JOB_TIMEOUT_MINUTES`: Default job timeout

### GHB::Application

**Purpose:** Main application class that orchestrates workflow generation, linter detection, language detection, and repository configuration.

**Location:** `lib/ghb/application.rb`

**Key Components:**

- `initialize(argv)`: Parses command-line arguments and initializes workflow objects
- `execute`: Main entry point that runs all generation steps
- `validate_config!`: Validates all YAML configuration files exist and have valid syntax
- `workflow_job_detect_linters`: Scans codebase for linter configuration needs
- `workflow_job_detect_languages`: Detects programming languages and their dependencies
- `workflow_job_licenses_check`: Adds license checking job to workflow
- `workflow_job_code_deploy`: Generates AWS CodeDeploy jobs if applicable
- `workflow_job_aws_commands`: Creates AWS commands job
- `workflow_job_publish_status`: Creates Slack notification job for build status
- `save_dependabot_config`: Creates cron dependencies workflow
- `save_dockerhub_config`: Creates Docker Hub publish workflow
- `check_repository_settings`: Configures GitHub repository settings via API
- `update_gitignore`: Updates .gitignore based on detected project types
- `detect_gitignore_templates(config)`: Detects gitignore templates by file extensions, files, and packages
- `detect_custom_patterns(config)`: Detects and appends AI assistant ignore patterns
- `find_files_matching(path, pattern, excluded_paths, max_depth)`: Pure Ruby file finder avoiding shell injection
- `atomic_copy_config(source, target)`: Atomic file copy with temp file and rename
- `file_contains?(file, pattern)`: Pure Ruby content search using `File.foreach`

**Internal Dependencies:**

- `GHB::Options`
- `GHB::Status`
- `GHB::Workflow`

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
- `gitignore_config_file`: Path to gitignore config file
- `ignored_linters`: Hash of linters to skip
- `languages_config_file`: Path to languages config file
- `linters_config_file`: Path to linters config file
- `only_dependabot`: Only generate dependabot workflow
- `options_config_file_apt`: Path to APT options config
- `options_config_file_mongodb`: Path to MongoDB options config
- `options_config_file_mysql`: Path to MySQL options config
- `options_config_file_redis`: Path to Redis options config
- `organization`: GitHub organization name
- `original_argv`: Original command-line arguments for reproducibility
- `skip_dependabot`: Skip dependabot workflow generation
- `skip_gitignore`: Skip gitignore updates
- `skip_license_check`: Skip license checking job
- `skip_repository_settings`: Skip GitHub repository settings configuration
- `skip_semgrep`: Skip semgrep linter
- `skip_slack`: Skip Slack notification job
- `strict_version_check`: Exit with error on version mismatch (default: true)

### GHB::Status

**Purpose:** Exit code constants for application status.

**Location:** `lib/ghb/status.rb`

**Key Components:**

- `SUCCESS_EXIT_CODE`: 0
- `ERROR_EXIT_CODE`: 1
- `FAILURE_EXIT_CODE`: 2

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
- `outputs`, `env`, `steps`, `timeout_minutes`, `strategy`, `container`, `services`

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
- `config/languages.yaml`: Language definitions with setup options and dependencies
- `config/gitignore.yaml`: Gitignore template detection rules
- `config/options/apt.yaml`: APT package configuration
- `config/options/mongodb.yaml`: MongoDB service version and settings
- `config/options/mysql.yaml`: MySQL service version and settings
- `config/options/redis.yaml`: Redis service version and settings

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

**Location:** `lib/ghb/application.rb` in `GHB::Application#workflow_job_detect_linters`

**Implementation:**

1. Loads linter configuration from `config/linters.yaml`
2. Parses `.gitmodules` for submodule paths to exclude
3. For each linter, uses pure Ruby `find_files_matching` with regex pattern matching to search for files
4. Excludes specified folders and submodules from search
5. If matching files found, enables the linter and uses `atomic_copy_config` to safely copy/transform configuration files (e.g., uncommenting Rails rules in `.rubocop.yml`)
6. Creates workflow job with appropriate steps for each enabled linter

**Complexity:** O(n * m) where n = number of linters, m = files in repository

### Language Detection Algorithm

**Purpose:** Detects programming languages and their dependencies to configure build jobs.

**Location:** `lib/ghb/application.rb` in `GHB::Application#workflow_job_detect_languages`

**Implementation:**

1. Loads language and options configurations from YAML files
2. For each language, uses pure Ruby `find_files_matching` to search for files matching the language's file extension
3. Verifies dependency files exist (e.g., `go.mod`, `package.json`)
4. Checks dependency files for database dependencies (MongoDB, MySQL, Redis, Elasticsearch) using `file_contains?`
5. Detects version files (`.ruby-version`, `.nvmrc`, etc.) and validates against recommended versions
6. Merges setup options with version validation (strict mode exits on mismatch, non-strict warns)
7. Creates unit test workflow job with appropriate setup, package manager, and test steps

**Complexity:** O(n * m) where n = number of languages, m = files in repository

### Repository Settings Configuration

**Purpose:** Configures GitHub repository settings including branch protection.

**Location:** `lib/ghb/application.rb` in `GHB::Application#check_repository_settings`

**Implementation:**

1. Validates `GITHUB_TOKEN` environment variable is present
2. Retrieves current repository info to check visibility (public/private)
3. Gets current branch protection via GitHub API (handles 404 for new repos without protection)
4. Detects CodeQL languages and filters redundant entries
5. Collects required status checks from generated workflow jobs
6. Validates existing checks match expected checks (only for existing protection)
7. Preserves existing dismissal restrictions and bypass allowances
8. Configures branch protection with required status checks, pull request reviews, signed commits, and conversation resolution
9. Configures repository options (delete branch on merge, etc.) and checks for Vercel integration
10. Enables security features (vulnerability alerts, secret scanning, CodeQL default setup)
11. Disables GHAS features for private repos (cost avoidance)

**Security Considerations:**

- Uses GITHUB_TOKEN for API authentication
- Validates branch protection before modification
- Preserves existing dismissal restrictions and bypass allowances
- Handles new repositories without existing branch protection gracefully

### Gitignore Template Detection

**Purpose:** Detects project types to generate comprehensive .gitignore files.

**Location:** `lib/ghb/application.rb` in `GHB::Application#update_gitignore`, `GHB::Application#detect_gitignore_templates`, and `GHB::Application#detect_custom_patterns`

**Implementation:**

1. Loads detection rules from `config/gitignore.yaml`
2. Adds always-enabled templates (OS, IDEs)
3. For each extension detection entry, checks file extensions using `find_files_matching`, specific files that indicate the technology, and package dependencies in manifest files using pure Ruby regex
4. Fetches templates from gitignore.io API
5. Applies project-specific modifications (uncomment JetBrains patterns, comment out conflicting directory patterns like `bin/`, `lib/`, `var/`)
6. Detects and appends AI assistant ignore patterns (Claude Code, Cursor, Copilot, OpenAI Codex) via `detect_custom_patterns`
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
