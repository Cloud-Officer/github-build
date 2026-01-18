# Architecture Design

## Table of Contents

- [Architecture diagram](#architecture-diagram)
- [Software units](#software-units)
- [Software of Unknown Provenance](#software-of-unknown-provenance)
- [Critical algorithms](#critical-algorithms)
- [Risk controls](#risk-controls)

## Architecture diagram

```text
+-------------------+     +------------------+     +---------------------+
|   CLI Interface   |     |   Configuration  |     |   External APIs     |
|  bin/github-build |---->|      Files       |---->|    (GitHub, etc.)   |
+-------------------+     +------------------+     +---------------------+
         |                        |                         |
         v                        v                         v
+------------------------------------------------------------------------+
|                           GHB::Application                              |
|  - Workflow generation    - Linter detection    - Language detection   |
|  - Repository settings    - Gitignore updates   - Dependabot config    |
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

- `CI_ACTIONS_VERSION`: Version tag for ci-actions references
- `DEFAULT_BUILD_FILE`: Default path for workflow output
- `DEFAULT_*_CONFIG_FILE`: Paths to configuration files
- `DEFAULT_UBUNTU_VERSION`: Default runner OS
- `DEFAULT_JOB_TIMEOUT_MINUTES`: Default job timeout

### GHB::Application

**Purpose:
** Main application class that orchestrates workflow generation, linter detection, language detection, and repository configuration.

**Location:** `lib/ghb/application.rb`

**Key Components:**

- `initialize(argv)`: Parses command-line arguments and initializes workflow objects
- `execute`: Main entry point that runs all generation steps
- `workflow_job_detect_linters`: Scans codebase for linter configuration needs
- `workflow_job_detect_languages`: Detects programming languages and their dependencies
- `workflow_job_code_deploy`: Generates AWS CodeDeploy jobs if applicable
- `check_repository_settings`: Configures GitHub repository settings via API
- `update_gitignore`: Updates .gitignore based on detected project types

**Internal Dependencies:**

- `GHB::Options`
- `GHB::Status`
- `GHB::Workflow`

**External Dependencies:**

- `active_support/core_ext/hash/keys`
- `duplicate`
- `httparty`
- `psych`
- `open3`

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
- `organization`: GitHub organization name
- Various skip flags for optional features

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
- `config/options/*.yaml`: Database and service version configurations

### bin/update_versions.sh

**Purpose:** Shell script to update language and service versions in configuration files.

**Location:** `bin/update_versions.sh`

**Key Components:**

- Fetches latest versions from official sources (go.dev, nodejs.org, etc.)
- Updates `config/languages.yaml` with latest language versions
- Updates `config/options/*.yaml` with latest service versions
- Uses `yq` for YAML manipulation

## Software of Unknown Provenance

| Package                  | Version  | License    | Purpose                                          |
|--------------------------|----------|------------|--------------------------------------------------|
| activesupport            | 8.1.2    | MIT        | Hash deep symbolize/stringify methods            |
| ast                      | 2.4.3    | MIT        | Abstract Syntax Tree library (dependency)        |
| base64                   | 0.3.0    | Ruby       | Base64 encoding/decoding (dependency)            |
| bigdecimal               | 4.0.1    | Ruby       | Arbitrary-precision decimal numbers (dependency) |
| concurrent-ruby          | 1.3.6    | MIT        | Concurrency utilities (dependency)               |
| connection_pool          | 3.0.2    | MIT        | Connection pool management (dependency)          |
| csv                      | 3.3.5    | Ruby       | CSV file handling (dependency)                   |
| date                     | 3.5.1    | Ruby       | Date library (dependency)                        |
| drb                      | 2.2.3    | Ruby       | Distributed Ruby (dependency)                    |
| duplicate                | 1.1.1    | Apache-2.0 | Deep clone functionality                         |
| httparty                 | 0.24.2   | MIT        | HTTP client for GitHub API calls                 |
| i18n                     | 1.14.8   | MIT        | Internationalization (dependency)                |
| json                     | 2.18.0   | Ruby       | JSON parsing (dependency)                        |
| language_server-protocol | 3.17.0.5 | MIT        | LSP SDK (dependency)                             |
| lint_roller              | 1.1.0    | MIT        | Linter plugin specification (dependency)         |
| logger                   | 1.7.0    | Ruby       | Logging utility (dependency)                     |
| mini_mime                | 1.1.5    | MIT        | MIME type library (dependency)                   |
| minitest                 | 6.0.1    | MIT        | Testing framework (dependency)                   |
| multi_xml                | 0.8.1    | MIT        | XML parsing (dependency)                         |
| open3                    | 0.2.1    | Ruby       | Process execution with stderr capture            |
| optparse                 | 0.8.1    | Ruby       | Command-line argument parsing                    |
| parallel                 | 1.27.0   | MIT        | Parallel processing (dependency)                 |
| parser                   | 3.3.10.1 | MIT        | Ruby parser (dependency)                         |
| prism                    | 1.8.0    | MIT        | Ruby parser (dependency)                         |
| psych                    | 5.3.1    | MIT        | YAML parser and emitter                          |
| racc                     | 1.8.1    | Ruby       | LALR parser generator (dependency)               |
| rainbow                  | 3.1.1    | MIT        | Terminal text colorization (dependency)          |
| regexp_parser            | 2.11.3   | MIT        | Regular expression parser (dependency)           |
| rubocop                  | 1.82.1   | MIT        | Ruby code linter (development)                   |
| rubocop-ast              | 1.49.0   | MIT        | RuboCop AST utilities (dependency)               |
| rubocop-capybara         | 2.22.1   | MIT        | Capybara linting rules (development)             |
| rubocop-graphql          | 1.5.6    | MIT        | GraphQL linting rules (development)              |
| rubocop-minitest         | 0.38.2   | MIT        | Minitest linting rules (development)             |
| rubocop-performance      | 1.26.1   | MIT        | Performance linting rules (development)          |
| rubocop-rspec            | 3.9.0    | MIT        | RSpec linting rules (development)                |
| rubocop-thread_safety    | 0.7.3    | MIT        | Thread safety checks (development)               |
| ruby-progressbar         | 1.13.0   | MIT        | Progress bar display (dependency)                |
| securerandom             | 0.4.1    | Ruby       | Secure random number generation (dependency)     |
| stringio                 | 3.2.0    | Ruby       | String IO operations (dependency)                |
| tzinfo                   | 2.0.6    | MIT        | Timezone data (dependency)                       |
| unicode-display_width    | 3.2.0    | MIT        | Unicode display width calculation (dependency)   |
| unicode-emoji            | 4.2.0    | MIT        | Unicode emoji data (dependency)                  |
| uri                      | 1.1.1    | Ruby       | URI handling (dependency)                        |

### Critical Dependencies

| Package       | Role                                       |
|---------------|--------------------------------------------|
| activesupport | Core hash manipulation for YAML processing |
| httparty      | GitHub API communication                   |
| psych         | YAML parsing and generation                |
| optparse      | CLI argument handling                      |
| open3         | External command execution                 |

### Development Dependencies

| Package   | Role                   |
|-----------|------------------------|
| rubocop   | Code style enforcement |
| rubocop-* | Extended linting rules |

## Critical algorithms

### Linter Detection Algorithm

**Purpose:** Automatically detects which linters should be enabled based on file patterns.

**Location:** `lib/ghb/application.rb:160-253`

**Implementation:**

1. Loads linter configuration from `config/linters.yaml`
2. For each linter, constructs a find command with the linter's path and pattern
3. Excludes specified folders and submodules from search
4. Executes find command via `Open3.capture3`
5. If matching files found, enables the linter and copies/links configuration files
6. Creates workflow job with appropriate steps for each enabled linter

**Complexity:** O(n * m) where n = number of linters, m = files in repository

### Language Detection Algorithm

**Purpose:** Detects programming languages and their dependencies to configure build jobs.

**Location:** `lib/ghb/application.rb:294-455`

**Implementation:**

1. Loads language configuration from `config/languages.yaml`
2. For each language, searches for files matching the language's file extension
3. Verifies dependency files exist (e.g., `go.mod`, `package.json`)
4. Checks dependency files for database dependencies (MongoDB, MySQL, Redis)
5. Configures setup options including version files (`.ruby-version`, etc.)
6. Creates unit test workflow job with appropriate setup and test steps

**Complexity:** O(n * m) where n = number of languages, m = files in repository

### Repository Settings Configuration

**Purpose:** Configures GitHub repository settings including branch protection.

**Location:** `lib/ghb/application.rb:836-1097`

**Implementation:**

1. Retrieves current repository info and branch protection via GitHub API
2. Collects required status checks from generated workflow jobs
3. Validates existing checks match expected checks
4. Configures branch protection with required status checks, pull request reviews, signed commits, and conversation resolution
5. Enables security features (vulnerability alerts, secret scanning, CodeQL)
6. Disables GHAS features for private repos (cost avoidance)

**Security Considerations:**

- Uses GITHUB_TOKEN for API authentication
- Validates branch protection before modification
- Preserves existing dismissal restrictions and bypass allowances

### Gitignore Template Detection

**Purpose:** Detects project types to generate comprehensive .gitignore files.

**Location:** `lib/ghb/application.rb:1099-1183` and `lib/ghb/application.rb:1185-1241`

**Implementation:**

1. Loads detection rules from `config/gitignore.yaml`
2. For each template, checks file extensions present in repository, specific files that indicate the technology, and package dependencies in manifest files
3. Fetches templates from gitignore.io API
4. Applies project-specific modifications (uncomment JetBrains patterns, etc.)
5. Appends AI assistant ignore patterns

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

- `StandardError` caught at top level with backtrace output
- Exit codes indicate success (0), error (1), or failure (2)
- API errors raise exceptions with descriptive messages
- File operations checked for existence before access

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
