# frozen_string_literal: true

require 'json'
require 'psych'
require 'uri'

require_relative 'check_names'
require_relative 'github_api_client'

module GHB
  # Configures GitHub repository settings including branch protection, security features, and CodeQL.
  class RepositoryConfigurator
    RULESET_NAME = 'github-build'

    CLASSIC_BYPASS_ACTOR_TYPES = { users: 'User', teams: 'Team', apps: 'Integration' }.freeze

    CLASSIC_DISMISSAL_ACTOR_TYPES = { users: 'User', teams: 'Team' }.freeze

    SECRET_SCANNING_SETTINGS = %i[
      secret_scanning
      secret_scanning_push_protection
      secret_scanning_validity_checks
      secret_scanning_non_provider_patterns
      secret_scanning_ai_detection
    ].freeze

    WORKFLOW_TOKEN_PERMISSIONS = {
      default_workflow_permissions: 'read',
      can_approve_pull_request_reviews: false
    }.freeze

    private_constant :SECRET_SCANNING_SETTINGS
    private_constant :WORKFLOW_TOKEN_PERMISSIONS
    private_constant :RULESET_NAME
    private_constant :CLASSIC_BYPASS_ACTOR_TYPES
    private_constant :CLASSIC_DISMISSAL_ACTOR_TYPES

    def initialize(options:, required_status_checks:, default_branch: 'master')
      @options = options
      @required_status_checks = required_status_checks
      @default_branch = default_branch
    end

    def configure
      return if @options.skip_repository_settings

      github_token = ENV.fetch('GITHUB_TOKEN', nil)
      raise(ConfigError, 'GITHUB_TOKEN environment variable is required for repository settings') if github_token.nil? || github_token.empty?

      puts('Configuring repository settings...')
      @warning_count = 0
      repository = Dir.pwd.split('/').last
      repo_url = "https://api.github.com/repos/#{@options.organization}/#{repository}"
      github_client = GitHubAPIClient.new(github_token)

      # Get repository info to check visibility
      response = github_client.get(repo_url)
      repo_info = JSON.parse(response.body)
      is_private = repo_info['private'] == true
      adopt_repository_default_branch(repo_info['default_branch'])

      configure_branch_protection(github_client, repo_url)
      configure_repository_options(github_client, repo_url)
      if is_private
        disable_security_features(github_client, repo_url)
        disable_codeql_default_setup(github_client, repo_url)
      else
        enable_security_features(github_client, repo_url)
        enable_codeql_default_setup(github_client, repo_url)
      end

      if @warning_count.zero?
        puts('    Repository settings configured successfully!')
      else
        warn("    Repository settings configured with #{@warning_count} warning(s)")
      end
    end

    private

    def adopt_repository_default_branch(repository_default_branch)
      return if repository_default_branch.nil? || repository_default_branch.empty? || repository_default_branch == @default_branch

      warn("    WARNING: detected default branch '#{@default_branch}' differs from the repository default branch '#{repository_default_branch}', using '#{repository_default_branch}'")
      @default_branch = repository_default_branch
    end

    def configure_branch_protection(github_client, repo_url)
      augment_required_status_checks
      log_codeql_languages(github_client, repo_url)

      ruleset = fetch_ruleset(github_client, repo_url)
      classic_protection = fetch_classic_protection(github_client, repo_url)
      current = ruleset ? ruleset_state(ruleset) : classic_state(classic_protection)
      protection_exists = !current.nil?

      # CodeQL is excluded: its "smart mode" runs only when relevant files change.
      expected_checks = @required_status_checks.dup
      actual_checks = protection_exists ? current[:checks].map { |check| check[:context] } : []
      xcode_checks = discover_xcode_cloud_checks(github_client, repo_url, actual_checks, expected_checks, protection_exists)
      expected_checks.concat(xcode_checks)

      sync = sync_required_checks?(expected_checks, actual_checks, protection_exists)
      payload = build_ruleset_payload(current, expected_checks, sync)

      apply_ruleset(github_client, repo_url, ruleset, payload)
      delete_classic_protection(github_client, repo_url) if classic_protection
    end

    def fetch_ruleset(github_client, repo_url)
      response = github_client.get("#{repo_url}/rulesets?includes_parents=false&targets=branch")
      summary = JSON.parse(response.body).find { |ruleset| ruleset['name'] == RULESET_NAME && ruleset['source_type'] == 'Repository' }
      return if summary.nil?

      JSON.parse(github_client.get("#{repo_url}/rulesets/#{summary['id']}").body)
    end

    def fetch_classic_protection(github_client, repo_url)
      response = github_client.get("#{repo_url}/branches/#{@default_branch}/protection", expected_codes: [200, 404])
      response.code == 200 ? JSON.parse(response.body) : nil
    end

    def ruleset_state(ruleset)
      rules = ruleset['rules'] || []
      checks = rules.find { |rule| rule['type'] == 'required_status_checks' }
                    &.dig('parameters', 'required_status_checks') || []
      pull_request = rules.find { |rule| rule['type'] == 'pull_request' }
                          &.dig('parameters') || {}

      {
        checks: checks.map { |check| status_check(check['context'], check['integration_id']) },
        bypass_actors: ruleset['bypass_actors'] || [],
        dismissal_restriction: pull_request['dismissal_restriction']
      }
    end

    def classic_state(protection)
      return if protection.nil?

      status_checks = protection['required_status_checks'] || {}
      app_ids = (status_checks['checks'] || []).to_h { |check| [check['context'], check['app_id']] }
      contexts = status_checks['contexts'] || app_ids.keys
      reviews = protection['required_pull_request_reviews'] || {}
      bypass = classic_actors(reviews['bypass_pull_request_allowances'], CLASSIC_BYPASS_ACTOR_TYPES)
      dismissal = classic_actors(reviews['dismissal_restrictions'], CLASSIC_DISMISSAL_ACTOR_TYPES)

      {
        checks: contexts.map { |context| status_check(context, app_ids[context]) },
        bypass_actors: bypass.map { |actor| { actor_id: actor[:id], actor_type: actor[:type], bypass_mode: 'pull_request' } },
        dismissal_restriction: dismissal.any? ? { enabled: true, allowed_actors: dismissal } : nil
      }
    end

    # filter_map drops entries without an id: GitHub rejects an actor whose id is null with 422.
    def classic_actors(allowances, actor_types)
      return [] if allowances.nil?

      actor_types.flat_map do |key, type|
        (allowances[key.to_s] || []).filter_map { |actor| { id: actor['id'], type: type } if actor['id'] }
      end
    end

    def status_check(context, integration_id)
      { context: context, integration_id: integration_id }.compact
    end

    def apply_ruleset(github_client, repo_url, ruleset, payload)
      response =
        if ruleset
          puts("    Updating #{RULESET_NAME} ruleset...")
          github_client.put("#{repo_url}/rulesets/#{ruleset['id']}", body: payload)
        else
          puts("    Creating #{RULESET_NAME} ruleset...")
          github_client.post("#{repo_url}/rulesets", body: payload, expected_codes: [201])
        end

      verify_ruleset(JSON.parse(response.body), payload)
    end

    # The classic rule is only deleted after this passes, so the branch is never left unprotected.
    def verify_ruleset(applied, payload)
      expected_types = payload[:rules].map { |rule| rule[:type] }
      applied_types = (applied['rules'] || []).map { |rule| rule['type'] }
      missing_types = expected_types - applied_types
      return if applied['enforcement'] == 'active' && missing_types.empty?

      raise(RepositorySettingsError, "#{RULESET_NAME} ruleset was not applied as expected (enforcement: #{applied['enforcement'].inspect}, missing rules: #{missing_types.join(', ')})")
    end

    def delete_classic_protection(github_client, repo_url)
      puts("    Removing classic branch protection rule on #{@default_branch}...")
      response = github_client.delete("#{repo_url}/branches/#{@default_branch}/protection", expected_codes: nil)
      warn_unless_successful(response, 'delete the classic branch protection rule')
    end

    def augment_required_status_checks
      @required_status_checks << 'Vercel' if GHB.vercel?

      # smoke.yml is hand-maintained, not generated, so its jobs must be discovered here.
      smoke_workflow = '.github/workflows/smoke.yml'
      return unless File.exist?(smoke_workflow)

      smoke_jobs = (Psych.safe_load(File.read(smoke_workflow)) || {})['jobs'] || {}
      smoke_jobs.each do |job_id, job|
        job ||= {}
        name = job['name'] || job_id.to_s
        names = CheckNames.for_job(name, job['strategy'])
        next record_warning("    WARNING: cannot resolve the check names of smoke job '#{name}'; skipping it in the required status checks") if names.nil?

        @required_status_checks.concat(names)
      end
    end

    def log_codeql_languages(github_client, repo_url)
      codeql_response = github_client.get("#{repo_url}/code-scanning/default-setup", expected_codes: nil)
      warn_unless_successful(codeql_response, 'read CodeQL default setup')
      return unless codeql_response.code == 200

      codeql_setup = JSON.parse(codeql_response.body)
      return unless codeql_setup['state'] == 'configured' && codeql_setup['languages'].is_a?(Array)

      # The API lists javascript-typescript and typescript, but only the javascript check runs.
      redundant_languages = %w[javascript-typescript typescript]
      languages = codeql_setup['languages'].reject { |lang| redundant_languages.include?(lang) }
      puts("    CodeQL languages detected: #{languages.join(', ')} (#{languages.length})")
    end

    def discover_xcode_cloud_checks(github_client, repo_url, actual_checks, expected_checks, protection_exists)
      return [] unless Dir.exist?('ci_scripts')

      if protection_exists
        # Extract Xcode Cloud checks from existing protection (checks not from GitHub Actions workflows)
        discover_xcode_cloud_checks_from_protection(actual_checks, expected_checks)
      else
        # For new repos, try to discover from commit statuses on the default branch
        discover_xcode_cloud_checks_from_statuses(github_client, repo_url)
      end
    end

    # Prints the check status and returns whether to overwrite the remote check list; raises on a declined mismatch.
    def sync_required_checks?(expected_checks, actual_checks, protection_exists)
      puts('    Checking required status checks...')

      unless protection_exists
        puts('        No existing branch protection, will create with expected checks')
        return false
      end

      missing_checks = expected_checks - actual_checks
      extra_checks = actual_checks - expected_checks
      return false if missing_checks.none? && extra_checks.none?

      if missing_checks.any?
        warn('        MISSING (expected but not in branch protection):')
        missing_checks.each { |check| warn("          ✗ #{check}") }
      end

      if extra_checks.any?
        warn('        EXTRA (in branch protection but not expected):')
        extra_checks.each { |check| warn("          + #{check}") }
      end

      raise(RepositorySettingsError, 'branch protection checks mismatch!') unless sync_confirmed?

      puts('        Overwriting remote check list with expected')
      true
    end

    def sync_confirmed?
      return true if @options.sync_required_status_checks
      return false unless $stdin.tty?

      $stderr.print("        Sync required status checks on #{@default_branch}? [y/N] ")
      %w[y yes].include?($stdin.gets.to_s.strip.downcase)
    end

    def build_ruleset_payload(current, expected_checks, sync_required_status_checks)
      {
        name: RULESET_NAME,
        target: 'branch',
        enforcement: 'active',
        conditions: { ref_name: { include: ['~DEFAULT_BRANCH'], exclude: [] } },
        bypass_actors: current ? current[:bypass_actors] : [],
        rules: [
          { type: 'deletion' },
          { type: 'non_fast_forward' },
          { type: 'required_signatures' },
          { type: 'pull_request', parameters: pull_request_parameters(current) },
          {
            type: 'required_status_checks',
            parameters: {
              strict_required_status_checks_policy: false,
              required_status_checks: ruleset_status_checks(current, expected_checks, sync_required_status_checks)
            }
          }
        ]
      }
    end

    def pull_request_parameters(current)
      parameters = {
        allowed_merge_methods: %w[squash rebase],
        dismiss_stale_reviews_on_push: true,
        require_code_owner_review: true,
        require_last_push_approval: true,
        required_approving_review_count: 1,
        required_review_thread_resolution: true
      }
      dismissal_restriction = current && current[:dismissal_restriction]
      parameters[:dismissal_restriction] = dismissal_restriction if dismissal_restriction
      parameters
    end

    # Preserve integration_id from existing entries so integration checks (e.g. Xcode Cloud) are not clobbered.
    def ruleset_status_checks(current, expected_checks, sync_required_status_checks)
      return expected_checks.map { |check| status_check(check, nil) } if current.nil?
      return current[:checks] unless sync_required_status_checks

      integration_ids = current[:checks].to_h { |check| [check[:context], check[:integration_id]] }
      expected_checks.map { |check| status_check(check, integration_ids[check]) }
    end

    def discover_xcode_cloud_checks_from_protection(actual_checks, expected_checks)
      xcode_checks = actual_checks - expected_checks

      report_xcode_cloud_checks(xcode_checks, 'in branch protection')
    end

    def report_xcode_cloud_checks(xcode_checks, source)
      if xcode_checks.empty?
        puts("        WARNING: ci_scripts directory exists but no Xcode Cloud checks found #{source}")
      else
        puts("        Xcode Cloud checks detected: #{xcode_checks.join(', ')}")
      end

      xcode_checks
    end

    def discover_xcode_cloud_checks_from_statuses(github_client, repo_url)
      response = github_client.get("#{repo_url}/commits/#{@default_branch}/status", expected_codes: [200])
      statuses = JSON.parse(response.body)['statuses'] || []
      xcode_checks =
        statuses.filter_map do |s|
          url = s['target_url']
          next unless url

          host = URI.parse(url).host
          s['context'] if host == 'appstoreconnect.apple.com'
        rescue URI::InvalidURIError
          nil
        end
      xcode_checks.uniq!

      report_xcode_cloud_checks(xcode_checks, 'on default branch')
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

      puts('    Restricting default workflow token permissions...')
      github_client.put("#{repo_url}/actions/permissions/workflow", body: WORKFLOW_TOKEN_PERMISSIONS, expected_codes: [204])
    end

    def disable_security_features(github_client, repo_url)
      puts('    Disabling Advanced Security features (private repository - GHAS incurs charges)...')
      response = set_security_features(github_client, repo_url, 'disabled', expected_codes: nil)
      warn_unless_successful(response, 'disable Advanced Security features')
    end

    def enable_security_features(github_client, repo_url)
      puts('    Enabling Advanced Security features...')
      set_security_features(github_client, repo_url, 'enabled')
    end

    def set_security_features(github_client, repo_url, state, **)
      security_settings = {
        security_and_analysis: SECRET_SCANNING_SETTINGS.to_h { |setting| [setting, { status: state }] }
      }

      github_client.patch(repo_url, body: security_settings, **)
    end

    def disable_codeql_default_setup(github_client, repo_url)
      puts('    Disabling CodeQL default setup (private repository - GHAS incurs charges)...')
      code_scanning_config = {
        state: 'not-configured'
      }

      response = github_client.patch(
        "#{repo_url}/code-scanning/default-setup",
        body: code_scanning_config,
        expected_codes: nil
      )
      warn_unless_successful(response, 'disable CodeQL default setup')
    end

    def warn_unless_successful(response, action)
      return if response.code.between?(200, 299)

      body = response.body.to_s.strip[0, 500]
      record_warning("    WARNING: could not #{action}: HTTP #{response.code}#{" #{body}" unless body.empty?}")
    end

    def record_warning(message)
      @warning_count += 1
      warn(message)
    end

    def enable_codeql_default_setup(github_client, repo_url)
      puts('    Enabling CodeQL default setup...')

      # First check current status; skip the patch if it is already configured.
      response = github_client.get("#{repo_url}/code-scanning/default-setup")
      current_setup = JSON.parse(response.body)

      return if current_setup['state'] == 'configured'

      code_scanning_config = {
        state: 'configured',
        query_suite: 'default'
      }

      github_client.patch(
        "#{repo_url}/code-scanning/default-setup",
        body: code_scanning_config,
        expected_codes: [200, 202]
      )
    end
  end
end
