# frozen_string_literal: true

require 'json'
require 'uri'

require_relative 'github_api_client'

module GHB
  # Configures GitHub repository settings including branch protection, security features, and CodeQL.
  class RepositoryConfigurator
    def initialize(options:, required_status_checks:, default_branch: 'master')
      @options = options
      @required_status_checks = required_status_checks
      @default_branch = default_branch
    end

    def configure
      return if @options.skip_repository_settings

      # Validate GITHUB_TOKEN is present (SEC-003)
      github_token = ENV.fetch('GITHUB_TOKEN', nil)
      raise(ConfigError, 'GITHUB_TOKEN environment variable is required for repository settings') if github_token.nil? || github_token.empty?

      puts('Configuring repository settings...')
      repository = Dir.pwd.split('/').last
      repo_url = "https://api.github.com/repos/#{@options.organization}/#{repository}"
      github_client = GitHubAPIClient.new(github_token)

      # Get repository info to check visibility
      response = github_client.get(repo_url)
      repo_info = JSON.parse(response.body)
      is_private = repo_info['private'] == true

      # Get current branch protection to preserve settings (404 means no protection configured yet)
      response = github_client.get("#{repo_url}/branches/#{@default_branch}/protection", expected_codes: [200, 404])
      protection_exists = response.code == 200
      current_protection = protection_exists ? JSON.parse(response.body) : {}

      configure_branch_protection(github_client, repo_url, current_protection, protection_exists)
      configure_repository_options(github_client, repo_url)
      configure_security_features(github_client, repo_url, is_private)
      configure_codeql(github_client, repo_url, is_private)

      puts('    Repository settings configured successfully!')
    end

    private

    def configure_branch_protection(github_client, repo_url, current_protection, protection_exists)
      # Add Vercel check if Next.js project
      @required_status_checks << 'Vercel' if File.exist?('package.json') && File.read('package.json').include?('"next"')

      # Check for CodeQL default setup
      codeql_response = github_client.get("#{repo_url}/code-scanning/default-setup", expected_codes: nil)

      if codeql_response.code == 200
        codeql_setup = JSON.parse(codeql_response.body)

        if codeql_setup['state'] == 'configured' && codeql_setup['languages'].is_a?(Array)
          # Filter out redundant languages from API response
          # The API returns 'javascript', 'javascript-typescript', and 'typescript' but
          # only 'javascript' check actually runs (it covers both JS and TS)
          redundant_languages = %w[javascript-typescript typescript]
          languages = codeql_setup['languages'].reject { |lang| redundant_languages.include?(lang) }
          puts("    CodeQL languages detected: #{languages.join(', ')} (#{languages.length})")
        end
      end

      # Build complete list of expected checks
      # Note: CodeQL checks are NOT included because they use "smart mode" which only runs
      # when relevant files change. CodeQL still blocks PRs through code scanning alerts.
      expected_checks = @required_status_checks.dup

      # Get actual checks from branch protection
      actual_checks = current_protection.dig('required_status_checks', 'contexts') || []

      # Discover Xcode Cloud checks when ci_scripts directory exists
      if Dir.exist?('ci_scripts')
        xcode_checks =
          if protection_exists
            # Extract Xcode Cloud checks from existing protection (checks not from GitHub Actions workflows)
            discover_xcode_cloud_checks_from_protection(actual_checks, expected_checks)
          else
            # For new repos, try to discover from commit statuses on the default branch
            discover_xcode_cloud_checks_from_statuses(github_client, repo_url)
          end

        expected_checks.concat(xcode_checks)
      end

      puts('    Checking required status checks...')

      # Only validate mismatch if protection already exists (skip for new repos)
      if protection_exists
        # Compare expected vs actual
        missing_checks = expected_checks - actual_checks
        extra_checks = actual_checks - expected_checks

        if missing_checks.any? || extra_checks.any?
          if missing_checks.any?
            puts('        MISSING (expected but not in branch protection):')
            missing_checks.each { |check| puts("          ✗ #{check}") }
          end

          if extra_checks.any?
            puts('        EXTRA (in branch protection but not expected):')
            extra_checks.each { |check| puts("          + #{check}") }
          end

          raise('Error: branch protection checks mismatch!')
        end
      else
        puts('        No existing branch protection, will create with expected checks')
      end

      # Preserve existing dismissal restrictions or use empty defaults
      dismissal_users = current_protection.dig('required_pull_request_reviews', 'dismissal_restrictions', 'users')&.map { |u| u['login'] } || []
      dismissal_teams = current_protection.dig('required_pull_request_reviews', 'dismissal_restrictions', 'teams')&.map { |t| t['slug'] } || []

      # Preserve existing bypass allowances or use empty defaults
      bypass_users = current_protection.dig('required_pull_request_reviews', 'bypass_pull_request_allowances', 'users')&.map { |u| u['login'] } || []
      bypass_teams = current_protection.dig('required_pull_request_reviews', 'bypass_pull_request_allowances', 'teams')&.map { |t| t['slug'] } || []

      # Use existing checks if protection exists, otherwise build from expected checks
      status_checks =
        if protection_exists
          current_protection.dig('required_status_checks', 'checks') || []
        else
          expected_checks.map { |check| { context: check, app_id: nil } }
        end

      # Set branch protection
      puts('    Setting branch protection...')
      branch_protection = {
        required_status_checks: {
          strict: false,
          checks: status_checks
        },
        enforce_admins: false,
        required_pull_request_reviews: {
          dismiss_stale_reviews: true,
          require_code_owner_reviews: true,
          require_last_push_approval: true,
          required_approving_review_count: 1,
          dismissal_restrictions: {
            users: dismissal_users,
            teams: dismissal_teams
          },
          bypass_pull_request_allowances: {
            users: bypass_users,
            teams: bypass_teams
          }
        },
        restrictions: nil,
        required_linear_history: false,
        allow_force_pushes: false,
        allow_deletions: false,
        block_creations: false,
        required_conversation_resolution: true
      }

      github_client.put("#{repo_url}/branches/#{@default_branch}/protection", body: branch_protection)

      # Enable required signatures (separate endpoint)
      puts('    Enabling required signatures...')
      github_client.post(
        "#{repo_url}/branches/#{@default_branch}/protection/required_signatures",
        expected_codes: [200, 204]
      )
    end

    def discover_xcode_cloud_checks_from_protection(actual_checks, expected_checks)
      xcode_checks = actual_checks - expected_checks

      if xcode_checks.empty?
        puts('        WARNING: ci_scripts directory exists but no Xcode Cloud checks found in branch protection')
      else
        puts("        Xcode Cloud checks detected: #{xcode_checks.join(', ')}")
      end

      xcode_checks
    end

    def discover_xcode_cloud_checks_from_statuses(github_client, repo_url)
      response = github_client.get("#{repo_url}/commits/#{@default_branch}/status", expected_codes: [200])
      statuses = JSON.parse(response.body)['statuses'] || []
      xcode_checks = statuses.filter_map do |s|
        url = s['target_url']
        next unless url

        host = URI.parse(url).host
        s['context'] if host == 'appstoreconnect.apple.com'
      rescue URI::InvalidURIError
        nil
      end.uniq

      if xcode_checks.empty?
        puts('        WARNING: ci_scripts directory exists but no Xcode Cloud checks found on default branch')
      else
        puts("        Xcode Cloud checks detected: #{xcode_checks.join(', ')}")
      end

      xcode_checks
    end

    def configure_repository_options(github_client, repo_url)
      # Enable vulnerability alerts
      puts('    Enabling vulnerability alerts...')
      github_client.put("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204])

      # Enable automated security fixes
      puts('    Enabling automated security fixes...')
      github_client.put("#{repo_url}/automated-security-fixes", expected_codes: [200, 204])

      # Configure repository settings
      puts('    Configuring repository options...')
      repo_settings = {
        has_wiki: false,
        has_projects: false,
        allow_auto_merge: true,
        allow_merge_commit: false,
        allow_squash_merge: true,
        allow_rebase_merge: true,
        delete_branch_on_merge: true
      }

      github_client.patch(repo_url, body: repo_settings)
    end

    def configure_security_features(github_client, repo_url, is_private)
      if is_private
        puts('    Disabling Advanced Security features (private repository - GHAS incurs charges)...')
        security_settings = {
          security_and_analysis: {
            secret_scanning: { status: 'disabled' },
            secret_scanning_push_protection: { status: 'disabled' },
            secret_scanning_validity_checks: { status: 'disabled' },
            secret_scanning_non_provider_patterns: { status: 'disabled' },
            secret_scanning_ai_detection: { status: 'disabled' }
          }
        }

        response = github_client.patch(repo_url, body: security_settings, expected_codes: nil)

        if response.code == 200
          puts('        Secret scanning disabled')
          puts('        Secret scanning push protection disabled')
          puts('        Secret scanning validity checks disabled')
          puts('        Secret scanning non-provider patterns disabled')
          puts('        Secret scanning AI detection disabled')
        end
      else
        puts('    Enabling Advanced Security features...')
        security_settings = {
          security_and_analysis: {
            secret_scanning: { status: 'enabled' },
            secret_scanning_push_protection: { status: 'enabled' },
            secret_scanning_validity_checks: { status: 'enabled' },
            secret_scanning_non_provider_patterns: { status: 'enabled' },
            secret_scanning_ai_detection: { status: 'enabled' }
          }
        }

        github_client.patch(repo_url, body: security_settings)

        puts('        Secret scanning enabled')
        puts('        Secret scanning push protection enabled')
        puts('        Secret scanning validity checks enabled')
        puts('        Secret scanning non-provider patterns enabled')
        puts('        Secret scanning AI detection (generic passwords) enabled')
      end
    end

    def configure_codeql(github_client, repo_url, is_private)
      if is_private
        puts('    Disabling CodeQL default setup (private repository - GHAS incurs charges)...')
        code_scanning_config = {
          state: 'not-configured'
        }

        response = github_client.patch(
          "#{repo_url}/code-scanning/default-setup",
          body: code_scanning_config,
          expected_codes: nil
        )

        puts('        CodeQL default setup disabled') if [200, 202].include?(response.code)
      else
        puts('    Enabling CodeQL default setup...')

        # First check current status
        response = github_client.get("#{repo_url}/code-scanning/default-setup")
        current_setup = JSON.parse(response.body)

        if current_setup['state'] == 'configured'
          puts('        CodeQL default setup already configured')
        else
          code_scanning_config = {
            state: 'configured',
            query_suite: 'default'
          }

          github_client.patch(
            "#{repo_url}/code-scanning/default-setup",
            body: code_scanning_config,
            expected_codes: [200, 202]
          )

          puts('        CodeQL default setup enabled')
        end
      end
    end
  end
end
