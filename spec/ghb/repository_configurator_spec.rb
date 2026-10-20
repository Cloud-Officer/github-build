# frozen_string_literal: true

RSpec.describe(GHB::RepositoryConfigurator) do
  let(:mock_options) do
    instance_double(GHB::Options, skip_repository_settings: false, organization: organization, sync_required_status_checks: false)
  end
  let(:github_client) do
    instance_double(GHB::GitHubAPIClient)
  end
  let(:configurator) do
    described_class.new(options: mock_options, required_status_checks: required_status_checks.dup, default_branch: default_branch)
  end
  let(:api_responses) do
    {
      repo_info: http_response(200, { private: false }.to_json),
      protection: http_response(404, '{"message":"Not Found"}'),
      rulesets: http_response(200, '[]'),
      codeql_default_setup: http_response(200, { state: 'not-configured' }.to_json),
      codeql_get: http_response(200, { state: 'not-configured' }.to_json),
      ok: http_response(200, '{}'),
      no_content: http_response(204, ''),
      accepted: http_response(202, '{}')
    }
  end

  def organization = 'test-org'

  def repository = 'my-repo'

  def default_branch = 'master'

  def repo_url = "https://api.github.com/repos/#{organization}/#{repository}"

  def rulesets_url = "#{repo_url}/rulesets"

  def github_token = 'test-token-abc123'

  def required_status_checks = %w[Build Lint]

  def existing_ruleset_id = 77

  def http_response(code, body) = instance_double(HTTParty::Response, code: code, body: body)

  def applied_ruleset_response(code, body)
    http_response(code, { id: existing_ruleset_id, enforcement: body[:enforcement], rules: body[:rules] }.to_json)
  end

  def written_rulesets = (@written_rulesets ||= [])

  def written_ruleset = written_rulesets.last

  def written_rule(type) = written_ruleset[:rules].find { |rule| rule[:type] == type }

  def written_checks = written_rule('required_status_checks')[:parameters][:required_status_checks]

  def classic_protection_url(branch = default_branch) = "#{repo_url}/branches/#{branch}/protection"

  def stub_branch_protection(branch)
    allow(github_client).to(receive(:get).with(classic_protection_url(branch), expected_codes: [200, 404]).and_return(api_responses[:protection]))
    allow(github_client).to(receive(:delete).with(classic_protection_url(branch), expected_codes: nil).and_return(api_responses[:no_content]))
  end

  def stub_rulesets
    allow(github_client).to(receive(:get).with("#{rulesets_url}?includes_parents=false&targets=branch").and_return(api_responses[:rulesets]))
    allow(github_client).to(receive(:post).with(rulesets_url, body: anything, expected_codes: [201])) do |_url, body:, **|
      written_rulesets << body
      applied_ruleset_response(201, body)
    end
    allow(github_client).to(receive(:put).with("#{rulesets_url}/#{existing_ruleset_id}", body: anything)) do |_url, body:, **|
      written_rulesets << body
      applied_ruleset_response(200, body)
    end
  end

  def stub_existing_ruleset(ruleset)
    summary = { id: existing_ruleset_id, name: 'github-build', source_type: 'Repository' }
    allow(github_client).to(receive(:get).with("#{rulesets_url}?includes_parents=false&targets=branch").and_return(http_response(200, [summary].to_json)))
    allow(github_client).to(receive(:get).with("#{rulesets_url}/#{existing_ruleset_id}").and_return(http_response(200, ruleset.merge(id: existing_ruleset_id).to_json)))
  end

  def stub_repository_default_branch(branch)
    allow(github_client).to(receive(:get).with(repo_url).and_return(http_response(200, JSON.parse(api_responses[:repo_info].body, symbolize_names: true).merge(default_branch: branch).to_json)))
    stub_branch_protection(branch)
  end

  def stub_security_patch(code, body)
    allow(github_client).to(receive(:patch).with(repo_url, body: hash_including(security_and_analysis: anything), expected_codes: nil).and_return(http_response(code, body)))
  end

  def stub_codeql_disable(code, body)
    allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil).and_return(http_response(code, body)))
  end

  def stub_codeql_read(code, body)
    allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(http_response(code, body)))
  end

  def answer_sync_prompt(answer)
    allow($stdin).to(receive_messages(tty?: true, gets: "#{answer}\n"))
    allow($stderr).to(receive(:print))
  end

  shared_context 'with a stubbed repository API' do
    before do
      allow(github_client).to(receive(:get).with(repo_url).and_return(api_responses[:repo_info]))
      allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(api_responses[:codeql_default_setup]))
      allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(api_responses[:codeql_get]))
      allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(api_responses[:ok]))
      allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(api_responses[:ok]))
      allow(github_client).to(receive(:put).with("#{repo_url}/actions/permissions/workflow", body: anything, expected_codes: [204]).and_return(api_responses[:ok]))
      allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(api_responses[:ok]))
      allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(api_responses[:accepted]))
      stub_rulesets
      stub_branch_protection(default_branch)
    end
  end

  shared_context 'with a private repository' do
    let(:api_responses) { super().merge(repo_info: http_response(200, { private: true }.to_json)) }

    before do
      stub_security_patch(200, '{}')
      stub_codeql_disable(200, '{}')
    end
  end

  shared_context 'with classic branch protection' do
    let(:api_responses) { super().merge(protection: http_response(200, current_protection.to_json)) }
  end

  before do
    allow($stdin).to(receive(:tty?).and_return(false))
    allow($stdout).to(receive(:puts))
    allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', nil).and_return(github_token))
    allow(Dir).to(receive(:pwd).and_return("/home/user/#{repository}"))
    allow(GHB::GitHubAPIClient).to(receive(:new).with(github_token).and_return(github_client))
    allow(File).to(receive(:exist?).with('vercel.json').and_return(false))
    allow(File).to(receive(:exist?).with('package.json').and_return(false))
    allow(File).to(receive(:exist?).with('.github/workflows/smoke.yml').and_return(false))
    allow(Dir).to(receive(:exist?).with('ci_scripts').and_return(false))
  end

  include_context 'with a stubbed repository API'

  describe '#configure' do
    it 'skips validation when skip_repository_settings is true' do
      skip_options = instance_double(GHB::Options, skip_repository_settings: true)
      skip_configurator = described_class.new(options: skip_options, required_status_checks: [])

      expect { skip_configurator.configure }
        .not_to(raise_error)
    end

    it 'raises ConfigError when GITHUB_TOKEN is not set' do
      allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', nil).and_return(nil))

      expect { configurator.configure }
        .to(raise_error(GHB::ConfigError, 'GITHUB_TOKEN environment variable is required for repository settings'))
    end

    it 'raises ConfigError when GITHUB_TOKEN is empty' do
      allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', nil).and_return(''))

      expect { configurator.configure }
        .to(raise_error(GHB::ConfigError, 'GITHUB_TOKEN environment variable is required for repository settings'))
    end
  end

  describe '#configure branch protection' do
    context 'when the repository has neither a ruleset nor classic protection' do
      before { configurator.configure }

      it 'creates the github-build ruleset on the default branch' do
        expect(written_ruleset).to(include(name: 'github-build', target: 'branch', enforcement: 'active', conditions: { ref_name: { include: ['~DEFAULT_BRANCH'], exclude: [] } }))
      end

      it 'lets nobody bypass the ruleset' do
        expect(written_ruleset[:bypass_actors]).to(eq([]))
      end

      it 'blocks deletion and force pushes and requires signed commits' do
        expect(written_ruleset[:rules].map { |rule| rule[:type] }).to(include('deletion', 'non_fast_forward', 'required_signatures'))
      end

      def expected_pull_request_parameters
        {
          allowed_merge_methods: %w[squash rebase],
          dismiss_stale_reviews_on_push: true,
          require_code_owner_review: true,
          require_last_push_approval: true,
          required_approving_review_count: 1,
          required_review_thread_resolution: true
        }
      end

      it 'requires one code-owner approval of the last push with resolved conversations' do
        expect(written_rule('pull_request')[:parameters]).to(eq(expected_pull_request_parameters))
      end

      it 'requires the generated checks without the strict up-to-date policy' do
        expect(written_rule('required_status_checks')[:parameters]).to(eq(strict_required_status_checks_policy: false, required_status_checks: [{ context: 'Build' }, { context: 'Lint' }]))
      end

      it 'does not try to delete a classic rule that does not exist' do
        expect(github_client).not_to(have_received(:delete))
      end

      it 'no longer calls the classic protection endpoints' do
        expect(github_client).not_to(have_received(:put).with(classic_protection_url, anything))
      end
    end

    context 'when configuring a public repository' do
      it 'completes the repository options and security flow' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        configurator.configure

        expect(github_client).to(have_received(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]))
        expect(github_client).to(have_received(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]))
        expect(github_client).to(have_received(:put).with("#{repo_url}/actions/permissions/workflow", body: { default_workflow_permissions: 'read', can_approve_pull_request_reviews: false }, expected_codes: [204]))
        expect(github_client).to(
          have_received(:patch).with(
            repo_url,
            body: {
              has_wiki: false,
              has_projects: false,
              allow_auto_merge: true,
              allow_merge_commit: false,
              allow_squash_merge: true,
              allow_rebase_merge: true,
              delete_branch_on_merge: true
            }
          )
        )
        expect(github_client).to(
          have_received(:patch).with(
            repo_url,
            body: hash_including(
              security_and_analysis: hash_including(
                secret_scanning: { status: 'enabled' },
                secret_scanning_push_protection: { status: 'enabled' },
                secret_scanning_validity_checks: { status: 'enabled' },
                secret_scanning_non_provider_patterns: { status: 'enabled' },
                secret_scanning_ai_detection: { status: 'enabled' }
              )
            )
          )
        )
        expect(github_client).to(have_received(:get).with("#{repo_url}/code-scanning/default-setup"))
        expect(github_client).to(have_received(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'configured', query_suite: 'default' }, expected_codes: [200, 202]))
      end
    end

    context 'when migrating from classic protection with matching checks' do
      let(:api_responses) do
        super().merge(
          protection: http_response(200, current_protection.to_json),
          codeql_default_setup: http_response(200, { state: 'configured', languages: %w[ruby javascript javascript-typescript typescript] }.to_json),
          codeql_get: http_response(200, { state: 'configured' }.to_json)
        )
      end

      def current_protection
        {
          required_status_checks: {
            contexts: %w[Build Lint],
            checks: [{ context: 'Build', app_id: 12_345 }, { context: 'Lint', app_id: 12_345 }]
          },
          required_pull_request_reviews: {
            dismissal_restrictions: {
              users: [{ login: 'admin-user', id: 11 }],
              teams: [{ slug: 'core-team', id: 22 }]
            },
            bypass_pull_request_allowances: {
              users: [{ login: 'bot-user', id: 33 }],
              teams: [{ slug: 'release-team', id: 44 }],
              apps: [{ slug: 'renovate', id: 55 }]
            }
          }
        }
      end

      it 'carries the classic checks over with their integration ids' do
        configurator.configure
        expect(written_checks).to(eq([{ context: 'Build', integration_id: 12_345 }, { context: 'Lint', integration_id: 12_345 }]))
      end

      def expected_bypass_actors
        [
          { actor_id: 33, actor_type: 'User', bypass_mode: 'pull_request' },
          { actor_id: 44, actor_type: 'Team', bypass_mode: 'pull_request' },
          { actor_id: 55, actor_type: 'Integration', bypass_mode: 'pull_request' }
        ]
      end

      it 'carries the pull request bypass allowances over as pull-request-only bypass actors' do
        configurator.configure
        expect(written_ruleset[:bypass_actors]).to(eq(expected_bypass_actors))
      end

      it 'carries the review dismissal restriction over' do
        configurator.configure
        expect(written_rule('pull_request')[:parameters][:dismissal_restriction]).to(eq(enabled: true, allowed_actors: [{ id: 11, type: 'User' }, { id: 22, type: 'Team' }]))
      end

      it 'deletes the classic rule once the ruleset is applied' do
        configurator.configure
        expect(github_client).to(have_received(:delete).with(classic_protection_url, expected_codes: nil))
      end

      def rulesets_written_before_delete
        written_at_delete = []
        allow(github_client).to(receive(:delete)) { written_at_delete << written_rulesets.size and api_responses[:no_content] }
        configurator.configure
        written_at_delete
      end

      it 'creates the ruleset before deleting the classic rule' do
        expect(rulesets_written_before_delete).to(eq([1]))
      end

      it 'raises when the ruleset comes back without enforcement' do
        allow(github_client).to(receive(:post).with(rulesets_url, body: anything, expected_codes: [201]).and_return(http_response(201, { id: 1, enforcement: 'disabled', rules: [] }.to_json)))
        expect { configurator.configure }
          .to(raise_error(GHB::RepositorySettingsError, /github-build ruleset was not applied as expected \(enforcement: "disabled"/))
      end

      it 'keeps the classic rule when the ruleset comes back without enforcement' do
        allow(github_client).to(receive(:post).with(rulesets_url, body: anything, expected_codes: [201]).and_return(http_response(201, { id: 1, enforcement: 'disabled', rules: [] }.to_json)))
        configurator.configure
      rescue GHB::RepositorySettingsError
        expect(github_client).not_to(have_received(:delete))
      end

      it 'keeps the classic rule when the ruleset is missing a rule' do
        allow(github_client).to(receive(:post).with(rulesets_url, body: anything, expected_codes: [201]).and_return(http_response(201, { id: 1, enforcement: 'active', rules: [{ type: 'deletion' }] }.to_json)))
        expect { configurator.configure }
          .to(raise_error(GHB::RepositorySettingsError, /missing rules: non_fast_forward, required_signatures, pull_request, required_status_checks/))
      end

      it 'warns but keeps the run going when the classic rule cannot be deleted' do
        allow(github_client).to(receive(:delete).and_return(http_response(403, '{"message":"Forbidden"}')))
        expect { configurator.configure }
          .to(output(/WARNING: could not delete the classic branch protection rule: HTTP 403/).to_stderr)
      end

      it 'reports CodeQL as already configured' do
        configurator.configure

        expect(github_client).not_to(have_received(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]))
      end

      it 'filters redundant CodeQL languages' do
        configurator.configure

        expect(github_client).to(have_received(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil))
      end

      it "reads classic protection from the repository API default branch when git detected 'master' but the API reports 'main'" do
        stub_repository_default_branch('main')
        allow(configurator).to(receive(:warn))
        configurator.configure
        expect(github_client).to(have_received(:get).with(classic_protection_url('main'), expected_codes: [200, 404]))
      end

      it "deletes classic protection on the repository API default branch when git detected 'master' but the API reports 'main'" do
        stub_repository_default_branch('main')
        allow(configurator).to(receive(:warn))
        configurator.configure
        expect(github_client).to(have_received(:delete).with(classic_protection_url('main'), expected_codes: nil))
      end

      it 'warns naming both branches when the repository API default branch differs from the detected one' do
        stub_repository_default_branch('main')
        expect { configurator.configure }
          .to(output(/detected default branch 'master' differs from the repository default branch 'main'/).to_stderr)
      end

      it 'emits no default-branch warning when the repository API reports the detected branch' do
        stub_repository_default_branch('master')
        expect { configurator.configure }
          .not_to(output(/differs from the repository default branch/).to_stderr)
      end
    end

    context 'when classic allowances contain entries without an id' do
      include_context 'with classic branch protection'

      def current_protection
        {
          required_status_checks: { contexts: %w[Build Lint], checks: [] },
          required_pull_request_reviews: {
            dismissal_restrictions: { users: [{}], teams: [{}] },
            bypass_pull_request_allowances: { users: [{ login: 'bot-user', id: 33 }, {}], teams: [] }
          }
        }
      end

      before { configurator.configure }

      it 'drops actors without an id from the bypass list' do
        expect(written_ruleset[:bypass_actors]).to(eq([{ actor_id: 33, actor_type: 'User', bypass_mode: 'pull_request' }]))
      end

      it 'leaves review dismissal unrestricted when no dismissal actor has an id' do
        expect(written_rule('pull_request')[:parameters]).not_to(have_key(:dismissal_restriction))
      end
    end

    context 'when classic protection has no allowances and no checks key' do
      include_context 'with classic branch protection'

      def current_protection
        { required_status_checks: { contexts: %w[Build Lint] }, required_pull_request_reviews: {} }
      end

      before { configurator.configure }

      it 'falls back to the classic contexts' do
        expect(written_checks).to(eq([{ context: 'Build' }, { context: 'Lint' }]))
      end

      it 'lets nobody bypass the ruleset' do
        expect(written_ruleset[:bypass_actors]).to(eq([]))
      end
    end

    context 'when the github-build ruleset already exists' do
      def existing_ruleset
        {
          name: 'github-build',
          enforcement: 'active',
          bypass_actors: [{ actor_id: 5, actor_type: 'Team', bypass_mode: 'pull_request' }],
          rules: [
            { type: 'pull_request', parameters: { dismissal_restriction: { enabled: true, allowed_actors: [{ id: 9, type: 'User' }] } } },
            { type: 'required_status_checks', parameters: { required_status_checks: [{ context: 'Build', integration_id: 15_368 }, { context: 'Lint', integration_id: 15_368 }] } }
          ]
        }
      end

      before do
        stub_existing_ruleset(existing_ruleset)
      end

      it 'updates the ruleset in place instead of creating a second one' do
        configurator.configure
        expect(github_client).not_to(have_received(:post).with(rulesets_url, anything))
      end

      it 'keeps the existing checks and their integration ids' do
        configurator.configure
        expect(written_checks).to(eq([{ context: 'Build', integration_id: 15_368 }, { context: 'Lint', integration_id: 15_368 }]))
      end

      it 'keeps the existing bypass actors' do
        configurator.configure
        expect(written_ruleset[:bypass_actors]).to(eq(JSON.parse(existing_ruleset[:bypass_actors].to_json)))
      end

      it 'keeps the existing review dismissal restriction' do
        configurator.configure
        expect(written_rule('pull_request')[:parameters][:dismissal_restriction]).to(eq(JSON.parse(existing_ruleset[:rules][0][:parameters][:dismissal_restriction].to_json)))
      end

      it 'deletes a leftover classic rule' do
        allow(github_client).to(receive(:get).with(classic_protection_url, expected_codes: [200, 404]).and_return(http_response(200, { required_status_checks: { contexts: ['Stale'] } }.to_json)))
        configurator.configure
        expect(github_client).to(have_received(:delete).with(classic_protection_url, expected_codes: nil))
      end

      it 'compares checks against the ruleset rather than a leftover classic rule' do
        allow(github_client).to(receive(:get).with(classic_protection_url, expected_codes: [200, 404]).and_return(http_response(200, { required_status_checks: { contexts: ['Stale'] } }.to_json)))
        expect { configurator.configure }
          .not_to(raise_error)
      end

      it 'raises when the ruleset checks do not match' do
        stub_existing_ruleset(existing_ruleset.merge(rules: [{ type: 'required_status_checks', parameters: { required_status_checks: [{ context: 'Build' }] } }]))
        expect { configurator.configure }
          .to(raise_error(GHB::RepositorySettingsError, 'branch protection checks mismatch!'))
      end
    end

    context 'when an organization ruleset shares the github-build name' do
      before do
        summary = { id: 999, name: 'github-build', source_type: 'Organization' }
        allow(github_client).to(receive(:get).with("#{rulesets_url}?includes_parents=false&targets=branch").and_return(http_response(200, [summary].to_json)))
        configurator.configure
      end

      it 'creates a repository ruleset instead of updating the organization one' do
        expect(github_client).to(have_received(:post).with(rulesets_url, body: anything, expected_codes: [201]))
      end
    end

    context 'when branch protection exists with mismatching checks' do
      include_context 'with classic branch protection'

      def current_protection
        {
          required_status_checks: {
            contexts: %w[Build Lint ExtraCheck],
            checks: []
          },
          required_pull_request_reviews: {}
        }
      end

      it 'raises an error when checks do not match' do
        expect { configurator.configure }
          .to(raise_error(GHB::RepositorySettingsError, 'branch protection checks mismatch!'))
      end

      it 'leaves the classic rule in place when the checks do not match' do
        configurator.configure
      rescue GHB::RepositorySettingsError
        expect(github_client).not_to(have_received(:delete))
      end
    end

    context 'when branch protection exists with missing checks' do
      include_context 'with classic branch protection'

      def current_protection
        {
          required_status_checks: {
            contexts: ['Build'],
            checks: [{ context: 'Build', app_id: nil }]
          },
          required_pull_request_reviews: {}
        }
      end

      it 'raises an error when expected checks are missing from branch protection' do
        expect { configurator.configure }
          .to(raise_error(GHB::RepositorySettingsError, 'branch protection checks mismatch!'))
      end

      it 'does not prompt when stdin is not a terminal' do
        allow($stdin).to(receive(:gets).and_raise('prompted without a terminal'))
        expect { configurator.configure }
          .to(raise_error(GHB::RepositorySettingsError, 'branch protection checks mismatch!'))
      end

      it 'asks on stderr before syncing' do
        answer_sync_prompt('y')
        configurator.configure
        expect($stderr).to(have_received(:print).with('        Sync required status checks on master? [y/N] '))
      end

      it 'syncs the expected checks when the prompt is accepted' do
        answer_sync_prompt('y')
        configurator.configure
        expect(written_checks).to(eq([{ context: 'Build' }, { context: 'Lint' }]))
      end

      it 'accepts yes in any case' do
        answer_sync_prompt('YES')
        expect { configurator.configure }
          .not_to(raise_error)
      end

      it 'raises when the prompt is declined' do
        answer_sync_prompt('n')
        expect { configurator.configure }
          .to(raise_error(GHB::RepositorySettingsError, 'branch protection checks mismatch!'))
      end

      it 'raises when the prompt is left empty' do
        answer_sync_prompt('')
        expect { configurator.configure }
          .to(raise_error(GHB::RepositorySettingsError, 'branch protection checks mismatch!'))
      end
    end

    context 'when branch protection has mismatching checks and sync_required_status_checks is true' do
      include_context 'with classic branch protection'

      let(:mock_options) do
        instance_double(GHB::Options, skip_repository_settings: false, organization: organization, sync_required_status_checks: true)
      end

      def current_protection
        {
          required_status_checks: {
            contexts: %w[Build StaleCheck],
            checks: [{ context: 'Build', app_id: 42 }, { context: 'StaleCheck', app_id: nil }]
          },
          required_pull_request_reviews: {}
        }
      end

      it 'rewrites the checks with the expected ones while preserving integration ids' do
        configurator.configure
        expect(written_checks).to(eq([{ context: 'Build', integration_id: 42 }, { context: 'Lint' }]))
      end
    end
  end

  describe '#configure security features' do
    context 'when configuring a private repository' do
      include_context 'with a private repository'

      it 'disables security features for private repository' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:patch).with(
            repo_url,
            body: {
              security_and_analysis: {
                secret_scanning: { status: 'disabled' },
                secret_scanning_push_protection: { status: 'disabled' },
                secret_scanning_validity_checks: { status: 'disabled' },
                secret_scanning_non_provider_patterns: { status: 'disabled' },
                secret_scanning_ai_detection: { status: 'disabled' }
              }
            },
            expected_codes: nil
          )
        )
      end

      it 'disables CodeQL for private repository' do
        configurator.configure

        expect(github_client).to(have_received(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil))
      end

      it 'restricts the default workflow token to read-only for private repository' do
        configurator.configure

        expect(github_client).to(have_received(:put).with("#{repo_url}/actions/permissions/workflow", body: { default_workflow_permissions: 'read', can_approve_pull_request_reviews: false }, expected_codes: [204]))
      end

      it 'emits no warnings when every disable call succeeds' do
        expect { configurator.configure }
          .not_to(output(/WARNING/).to_stderr)
      end

      it 'reports success when every disable call succeeds' do
        expect { configurator.configure }
          .to(output(/Repository settings configured successfully!/).to_stdout)
      end

      it 'warns with the status code and body when disabling the security features is rejected' do
        stub_security_patch(403, '{"message":"Resource not accessible by integration"}')
        expect { configurator.configure }
          .to(output(/WARNING: could not disable Advanced Security features: HTTP 403 \{"message":"Resource not accessible by integration"\}/).to_stderr)
      end

      it 'summarizes the warning count when disabling the security features is rejected' do
        stub_security_patch(403, '{"message":"Resource not accessible by integration"}')
        expect { configurator.configure }
          .to(output(/Repository settings configured with 1 warning\(s\)/).to_stderr)
      end

      it 'does not report success when disabling the security features is rejected' do
        stub_security_patch(403, '{"message":"Resource not accessible by integration"}')
        expect { configurator.configure }
          .not_to(output(/configured successfully/).to_stdout)
      end

      it 'warns with the status code and body when disabling CodeQL default setup is rejected' do
        stub_codeql_disable(422, '{"message":"Validation Failed"}')
        expect { configurator.configure }
          .to(output(/WARNING: could not disable CodeQL default setup: HTTP 422 \{"message":"Validation Failed"\}/).to_stderr)
      end

      it 'warns with the status code and body when reading CodeQL default setup fails' do
        stub_codeql_read(404, '{"message":"Not Found"}')
        expect { configurator.configure }
          .to(output(/WARNING: could not read CodeQL default setup: HTTP 404 \{"message":"Not Found"\}/).to_stderr)
      end

      it 'omits an empty body from the warning' do
        stub_security_patch(403, '')
        stub_codeql_disable(403, '')
        expect { configurator.configure }
          .to(output(/WARNING: could not disable CodeQL default setup: HTTP 403$/).to_stderr)
      end

      it 'counts every warning in the final summary' do
        stub_security_patch(403, '')
        stub_codeql_disable(403, '')
        expect { configurator.configure }
          .to(output(/Repository settings configured with 2 warning\(s\)/).to_stderr)
      end
    end

    context 'when private repo security features patch returns error' do
      include_context 'with a private repository'

      before do
        stub_security_patch(422, '{"message":"Validation Failed"}')
      end

      it 'does not print disabled confirmation messages when response is not 200' do
        configurator.configure

        expect(github_client).to(have_received(:patch).with(repo_url, body: hash_including(security_and_analysis: anything), expected_codes: nil))
      end
    end
  end

  describe '#configure CodeQL' do
    context 'when CodeQL default setup returns non-200 during branch protection' do
      let(:api_responses) { super().merge(codeql_default_setup: http_response(403, '{"message":"Forbidden"}')) }

      it 'completes without error, skipping CodeQL language detection' do
        expect { configurator.configure }
          .not_to(raise_error)
      end
    end

    context 'when private repo CodeQL disable returns 202' do
      include_context 'with a private repository'

      before do
        stub_codeql_disable(202, '{}')
      end

      it 'patches CodeQL default setup to not-configured for 202 response' do
        configurator.configure

        expect(github_client).to(have_received(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil))
      end
    end

    context 'when private repo CodeQL disable returns non-200/202' do
      include_context 'with a private repository'

      before do
        stub_codeql_disable(404, '{"message":"Not Found"}')
      end

      it 'still patches CodeQL default setup for non-200/202 response' do
        configurator.configure

        expect(github_client).to(have_received(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil))
      end
    end

    context 'when CodeQL configured state with languages is detected in branch protection' do
      let(:api_responses) do
        super().merge(
          codeql_default_setup: http_response(200, { state: 'configured', languages: %w[ruby python] }.to_json),
          codeql_get: http_response(200, { state: 'configured' }.to_json)
        )
      end

      it 'detects and logs CodeQL languages without redundant ones' do
        expect { configurator.configure }
          .not_to(raise_error)
      end
    end

    context 'when CodeQL default setup has configured state but languages is not an array' do
      let(:api_responses) do
        super().merge(
          codeql_default_setup: http_response(200, { state: 'configured', languages: 'not-an-array' }.to_json),
          codeql_get: http_response(200, { state: 'configured' }.to_json)
        )
      end

      it 'skips language logging when languages is not an array' do
        expect { configurator.configure }
          .not_to(raise_error)
      end
    end
  end

  describe '#configure repository detection' do
    context 'when package.json contains "next" (Vercel detection)' do
      before do
        allow(File).to(receive(:exist?).with('package.json').and_return(true))
        allow(File).to(receive(:read).with('package.json').and_return('{"dependencies": {"next": "^14.0.0"}}'))
      end

      it 'adds Vercel to the expected checks' do
        configurator.configure
        expect(written_checks).to(eq([{ context: 'Build' }, { context: 'Lint' }, { context: 'Vercel' }]))
      end
    end

    context 'when package.json exists but does not contain "next"' do
      before do
        allow(File).to(receive(:exist?).with('package.json').and_return(true))
        allow(File).to(receive(:read).with('package.json').and_return('{"dependencies": {"react": "^18.0.0"}}'))
      end

      it 'does not add Vercel to the expected checks' do
        configurator.configure
        expect(written_checks).to(eq([{ context: 'Build' }, { context: 'Lint' }]))
      end

      it 'adds Vercel to the expected checks when vercel.json exists' do
        allow(File).to(receive(:exist?).with('vercel.json').and_return(true))
        configurator.configure
        expect(written_checks).to(include({ context: 'Vercel' }))
      end
    end

    context 'when .github/workflows/smoke.yml exists (smoke-test detection)' do
      before do
        allow(File).to(receive(:exist?).with('.github/workflows/smoke.yml').and_return(true))
        allow(File).to(receive(:read).with('.github/workflows/smoke.yml').and_return(smoke_yaml))
      end

      def smoke_yaml
        <<~YAML
          ---
          name: Smoke
          'on': [push]
          jobs:
            action-contracts:
              name: Action contracts (all 28)
            linters-smoke:
              name: Linter actions (disabled path)
            variables-smoke:
        YAML
      end

      it 'adds each smoke job (by name, falling back to job id) to the expected checks' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(written_checks).to(
          eq(
            [
              { context: 'Build' },
              { context: 'Lint' },
              { context: 'Action contracts (all 28)' },
              { context: 'Linter actions (disabled path)' },
              { context: 'variables-smoke' }
            ]
          )
        )
      end
    end

    context 'when ci_scripts directory exists with no existing protection' do
      before do
        allow(Dir).to(receive(:exist?).with('ci_scripts').and_return(true))
        allow(github_client).to(receive(:get).with("#{repo_url}/commits/#{default_branch}/status", expected_codes: [200]).and_return(xcode_status_response))
      end

      def xcode_status_response
        http_response(
          200,
          {
            statuses: [
              { context: 'MyApp | UnitTests', target_url: 'https://appstoreconnect.apple.com/teams/123/apps/456/ci/builds/789' }
            ]
          }.to_json
        )
      end

      it 'discovers Xcode Cloud checks from commit statuses' do
        configurator.configure
        expect(written_checks).to(eq([{ context: 'Build' }, { context: 'Lint' }, { context: 'MyApp | UnitTests' }]))
      end
    end

    context 'when ci_scripts directory exists with existing classic protection' do
      include_context 'with classic branch protection'

      def current_protection
        {
          required_status_checks: {
            contexts: ['Build', 'Lint', 'MyApp | Build + Unit Test'],
            checks: [
              { context: 'Build', app_id: 15_368 },
              { context: 'Lint', app_id: 15_368 },
              { context: 'MyApp | Build + Unit Test', app_id: nil }
            ]
          },
          required_pull_request_reviews: {}
        }
      end

      before do
        allow(Dir).to(receive(:exist?).with('ci_scripts').and_return(true))
      end

      it 'extracts Xcode Cloud checks from the classic protection' do
        configurator.configure
        expect(written_checks).to(eq([{ context: 'Build', integration_id: 15_368 }, { context: 'Lint', integration_id: 15_368 }, { context: 'MyApp | Build + Unit Test' }]))
      end
    end

    context 'when ci_scripts directory exists with an existing ruleset' do
      before do
        allow(Dir).to(receive(:exist?).with('ci_scripts').and_return(true))
        stub_existing_ruleset(
          name: 'github-build',
          bypass_actors: [],
          rules: [{ type: 'required_status_checks', parameters: { required_status_checks: [{ context: 'Build' }, { context: 'Lint' }, { context: 'MyApp | Build + Unit Test' }] } }]
        )
      end

      it 'extracts Xcode Cloud checks from the ruleset' do
        expect { configurator.configure }
          .to(output(/Xcode Cloud checks detected: MyApp \| Build \+ Unit Test/).to_stdout)
      end
    end

    context 'when using a custom default branch' do
      let(:configurator_custom_branch) do
        described_class.new(options: mock_options, required_status_checks: required_status_checks.dup, default_branch: custom_branch)
      end

      def custom_branch = 'main'

      before do
        stub_branch_protection(custom_branch)
      end

      it 'reads the classic protection of the custom branch' do
        configurator_custom_branch.configure
        expect(github_client).to(have_received(:get).with(classic_protection_url(custom_branch), expected_codes: [200, 404]))
      end
    end
  end
end
