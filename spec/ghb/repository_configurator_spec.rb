# frozen_string_literal: true

RSpec.describe(GHB::RepositoryConfigurator) do # rubocop:disable RSpec/MultipleMemoizedHelpers
  let(:organization)           { 'test-org'                                                   }
  let(:repository)             { 'my-repo'                                                    }
  let(:default_branch)         { 'master'                                                     }
  let(:repo_url)               { "https://api.github.com/repos/#{organization}/#{repository}" }
  let(:github_token)           { 'test-token-abc123'                                          }
  let(:required_status_checks) { %w[Build Lint]                                               }

  let(:mock_options) do
    instance_double(GHB::Options, skip_repository_settings: false, organization: organization)
  end

  let(:github_client) do
    instance_double(GHB::GitHubAPIClient)
  end

  let(:configurator) do
    described_class.new(options: mock_options, required_status_checks: required_status_checks.dup, default_branch: default_branch)
  end

  before do
    allow($stdout).to(receive(:puts))
    allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', nil).and_return(github_token))
    allow(Dir).to(receive(:pwd).and_return("/home/user/#{repository}"))
    allow(GHB::GitHubAPIClient).to(receive(:new).with(github_token).and_return(github_client))
    allow(File).to(receive(:exist?).with('package.json').and_return(false))
    allow(Dir).to(receive(:exist?).with('ci_scripts').and_return(false))
  end

  describe '#configure' do # rubocop:disable RSpec/MultipleMemoizedHelpers
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

    context 'when configuring a public repository with no existing branch protection' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured', languages: [] }.to_json)
      end

      let(:codeql_setup_not_configured_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        # GET repo info
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        # GET branch protection (404 = not found)
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        # GET CodeQL default setup (for branch protection)
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        # PUT branch protection
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        # POST required signatures
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        # PUT vulnerability alerts
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        # PUT automated security fixes
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        # PATCH repo settings
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        # GET CodeQL default setup (for configure_codeql)
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_setup_not_configured_response))
        # PATCH CodeQL default setup (enable)
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'completes the full configure flow for a public repository' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        configurator.configure

        # Verify repo info was fetched
        expect(github_client).to(have_received(:get).with(repo_url))
        # Verify branch protection was checked
        expect(github_client).to(have_received(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]))
        # Verify branch protection was set (with expected checks built from required_status_checks since no existing protection)
        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_status_checks: hash_including(
                strict: false,
                checks: [{ context: 'Build', app_id: nil }, { context: 'Lint', app_id: nil }]
              ),
              enforce_admins: false,
              required_pull_request_reviews: hash_including(
                dismiss_stale_reviews: true,
                require_code_owner_reviews: true,
                require_last_push_approval: true,
                required_approving_review_count: 1
              ),
              restrictions: nil,
              required_linear_history: false,
              allow_force_pushes: false,
              allow_deletions: false,
              block_creations: false,
              required_conversation_resolution: true
            )
          )
        )
        # Verify required signatures were enabled
        expect(github_client).to(have_received(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]))
        # Verify vulnerability alerts and automated security fixes
        expect(github_client).to(have_received(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]))
        expect(github_client).to(have_received(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]))
        # Verify repo options were configured
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
        # Verify security features were enabled (public repo)
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
        # Verify CodeQL was configured (public repo, not yet configured)
        expect(github_client).to(have_received(:get).with("#{repo_url}/code-scanning/default-setup"))
        expect(github_client).to(have_received(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'configured', query_suite: 'default' }, expected_codes: [200, 202]))
      end

      it 'builds expected checks from required_status_checks when no existing protection' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_status_checks: hash_including(
                checks: [{ context: 'Build', app_id: nil }, { context: 'Lint', app_id: nil }]
              )
            )
          )
        )
      end
    end

    context 'when configuring a private repository' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: true }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured', languages: [] }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:security_patch_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:codeql_disable_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        # For repo options PATCH
        allow(github_client).to(receive(:patch).with(repo_url, body: hash_including(has_wiki: false)).and_return(ok_response))
        # For security settings PATCH (private: disable)
        allow(github_client).to(receive(:patch).with(repo_url, body: hash_including(security_and_analysis: anything), expected_codes: nil).and_return(security_patch_response))
        # For CodeQL disable PATCH (private)
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil).and_return(codeql_disable_response))
      end

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
    end

    context 'when branch protection exists with matching checks' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:existing_checks) do
        JSON.parse([{ context: 'Build', app_id: 12_345 }, { context: 'Lint', app_id: 12_345 }].to_json)
      end

      let(:current_protection) do
        {
          required_status_checks: {
            contexts: %w[Build Lint],
            checks: existing_checks
          },
          required_pull_request_reviews: {
            dismissal_restrictions: {
              users: [{ login: 'admin-user' }],
              teams: [{ slug: 'core-team' }]
            },
            bypass_pull_request_allowances: {
              users: [{ login: 'bot-user' }],
              teams: [{ slug: 'release-team' }]
            }
          }
        }
      end

      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 200, body: current_protection.to_json)
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'configured', languages: %w[ruby javascript javascript-typescript typescript] }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
      end

      it 'preserves existing checks and dismissal/bypass settings' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_status_checks: hash_including(
                strict: false,
                checks: existing_checks
              ),
              required_pull_request_reviews: hash_including(
                dismissal_restrictions: {
                  users: ['admin-user'],
                  teams: ['core-team']
                },
                bypass_pull_request_allowances: {
                  users: ['bot-user'],
                  teams: ['release-team']
                }
              )
            )
          )
        )
      end

      it 'reports CodeQL as already configured' do
        configurator.configure

        # Should not attempt to PATCH CodeQL since it is already configured
        expect(github_client).not_to(have_received(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]))
      end

      it 'filters redundant CodeQL languages' do
        configurator.configure

        # Verify that 'javascript-typescript' and 'typescript' are filtered out.
        # The detection happens via puts, so just verify it completes without error.
        expect(github_client).to(have_received(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil))
      end
    end

    context 'when branch protection exists with mismatching checks' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:current_protection) do
        {
          required_status_checks: {
            contexts: %w[Build Lint ExtraCheck],
            checks: []
          },
          required_pull_request_reviews: {}
        }
      end

      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 200, body: current_protection.to_json)
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
      end

      it 'raises an error when checks do not match' do
        expect { configurator.configure }
          .to(raise_error(RuntimeError, 'Error: branch protection checks mismatch!'))
      end
    end

    context 'when branch protection exists with missing checks' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:current_protection) do
        {
          required_status_checks: {
            contexts: ['Build'],
            checks: []
          },
          required_pull_request_reviews: {}
        }
      end

      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 200, body: current_protection.to_json)
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
      end

      it 'raises an error when expected checks are missing from branch protection' do
        expect { configurator.configure }
          .to(raise_error(RuntimeError, 'Error: branch protection checks mismatch!'))
      end
    end

    context 'when package.json contains "next" (Vercel detection)' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        allow(File).to(receive(:exist?).with('package.json').and_return(true))
        allow(File).to(receive(:read).with('package.json').and_return('{"dependencies": {"next": "^14.0.0"}}'))

        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'adds Vercel to the expected checks' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_status_checks: hash_including(
                checks: [{ context: 'Build', app_id: nil }, { context: 'Lint', app_id: nil }, { context: 'Vercel', app_id: nil }]
              )
            )
          )
        )
      end
    end

    context 'when package.json exists but does not contain "next"' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        allow(File).to(receive(:exist?).with('package.json').and_return(true))
        allow(File).to(receive(:read).with('package.json').and_return('{"dependencies": {"react": "^18.0.0"}}'))

        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'does not add Vercel to the expected checks' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_status_checks: hash_including(
                checks: [{ context: 'Build', app_id: nil }, { context: 'Lint', app_id: nil }]
              )
            )
          )
        )
      end
    end

    context 'when ci_scripts directory exists with no existing protection' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      let(:xcode_status_response) do
        instance_double(
          HTTParty::Response,
          code: 200,
          body: {
            statuses: [
              { context: 'MyApp | UnitTests', target_url: 'https://appstoreconnect.apple.com/teams/123/apps/456/ci/builds/789' }
            ]
          }.to_json
        )
      end

      before do
        allow(Dir).to(receive(:exist?).with('ci_scripts').and_return(true))

        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/commits/#{default_branch}/status", expected_codes: [200]).and_return(xcode_status_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'discovers Xcode Cloud checks from commit statuses' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_status_checks: hash_including(
                checks: [{ context: 'Build', app_id: nil }, { context: 'Lint', app_id: nil }, { context: 'MyApp | UnitTests', app_id: nil }]
              )
            )
          )
        )
      end
    end

    context 'when ci_scripts directory exists with existing protection' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:current_protection) do
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

      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 200, body: current_protection.to_json)
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        allow(Dir).to(receive(:exist?).with('ci_scripts').and_return(true))

        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'extracts Xcode Cloud checks from existing branch protection' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_status_checks: hash_including(
                checks: current_protection[:required_status_checks][:checks].map { |c| JSON.parse(c.to_json) }
              )
            )
          )
        )
      end
    end

    context 'when CodeQL default setup returns non-200 during branch protection' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 403, body: '{"message":"Forbidden"}')
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'completes without error, skipping CodeQL language detection' do
        expect { configurator.configure }
          .not_to(raise_error)
      end
    end

    context 'when private repo security features patch returns error' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: true }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:security_error_response) do
        instance_double(HTTParty::Response, code: 422, body: '{"message":"Validation Failed"}')
      end

      let(:codeql_disable_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: hash_including(has_wiki: false)).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: hash_including(security_and_analysis: anything), expected_codes: nil).and_return(security_error_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil).and_return(codeql_disable_response))
      end

      it 'does not print disabled confirmation messages when response is not 200' do
        configurator.configure

        # The security patch was called with expected_codes: nil (so it does not raise)
        expect(github_client).to(have_received(:patch).with(repo_url, body: hash_including(security_and_analysis: anything), expected_codes: nil))
      end
    end

    context 'when private repo CodeQL disable returns 202' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: true }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:security_patch_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:codeql_disable_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: hash_including(has_wiki: false)).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: hash_including(security_and_analysis: anything), expected_codes: nil).and_return(security_patch_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil).and_return(codeql_disable_response))
      end

      it 'prints CodeQL disabled confirmation for 202 response' do
        configurator.configure

        expect(github_client).to(have_received(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil))
      end
    end

    context 'when private repo CodeQL disable returns non-200/202' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: true }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:security_patch_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:codeql_disable_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: hash_including(has_wiki: false)).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: hash_including(security_and_analysis: anything), expected_codes: nil).and_return(security_patch_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil).and_return(codeql_disable_response))
      end

      it 'does not print CodeQL disabled confirmation for non-200/202 response' do
        configurator.configure

        expect(github_client).to(have_received(:patch).with("#{repo_url}/code-scanning/default-setup", body: { state: 'not-configured' }, expected_codes: nil))
      end
    end

    context 'when CodeQL configured state with languages is detected in branch protection' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'configured', languages: %w[ruby python] }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
      end

      it 'detects and logs CodeQL languages without redundant ones' do
        expect { configurator.configure }
          .not_to(raise_error)
      end
    end

    context 'when using a custom default branch' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:custom_branch) { 'main' }

      let(:configurator_custom_branch) do
        described_class.new(options: mock_options, required_status_checks: required_status_checks.dup, default_branch: custom_branch)
      end

      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{custom_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{custom_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{custom_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'uses the custom branch name in protection URLs' do # rubocop:disable RSpec/MultipleExpectations
        configurator_custom_branch.configure

        expect(github_client).to(have_received(:get).with("#{repo_url}/branches/#{custom_branch}/protection", expected_codes: [200, 404]))
        expect(github_client).to(have_received(:put).with("#{repo_url}/branches/#{custom_branch}/protection", body: anything))
        expect(github_client).to(have_received(:post).with("#{repo_url}/branches/#{custom_branch}/protection/required_signatures", expected_codes: [200, 204]))
      end
    end

    context 'when protection exists with empty dismissal_restrictions and bypass_allowances' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:current_protection) do
        {
          required_status_checks: {
            contexts: %w[Build Lint],
            checks: [{ context: 'Build', app_id: nil }, { context: 'Lint', app_id: nil }]
          },
          required_pull_request_reviews: {
            dismissal_restrictions: {
              users: [],
              teams: []
            },
            bypass_pull_request_allowances: {
              users: [],
              teams: []
            }
          }
        }
      end

      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 200, body: current_protection.to_json)
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'uses empty arrays for dismissal and bypass settings' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_pull_request_reviews: hash_including(
                dismissal_restrictions: { users: [], teams: [] },
                bypass_pull_request_allowances: { users: [], teams: [] }
              )
            )
          )
        )
      end
    end

    context 'when protection exists without dismissal_restrictions or bypass keys' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:current_protection) do
        {
          required_status_checks: {
            contexts: %w[Build Lint],
            checks: [{ context: 'Build', app_id: nil }, { context: 'Lint', app_id: nil }]
          },
          required_pull_request_reviews: {}
        }
      end

      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 200, body: current_protection.to_json)
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'defaults to empty arrays when dismissal_restrictions and bypass keys are absent' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_pull_request_reviews: hash_including(
                dismissal_restrictions: { users: [], teams: [] },
                bypass_pull_request_allowances: { users: [], teams: [] }
              )
            )
          )
        )
      end
    end

    context 'when CodeQL default setup has configured state but languages is not an array' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 404, body: '{"message":"Not Found"}')
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'configured', languages: 'not-an-array' }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
      end

      it 'skips language logging when languages is not an array' do
        expect { configurator.configure }
          .not_to(raise_error)
      end
    end

    context 'when protection exists without required_status_checks.checks key' do # rubocop:disable RSpec/MultipleMemoizedHelpers
      let(:current_protection) do
        {
          required_status_checks: {
            contexts: %w[Build Lint]
          },
          required_pull_request_reviews: {}
        }
      end

      let(:repo_info_response) do
        instance_double(HTTParty::Response, code: 200, body: { private: false }.to_json)
      end

      let(:protection_response) do
        instance_double(HTTParty::Response, code: 200, body: current_protection.to_json)
      end

      let(:codeql_default_setup_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:codeql_get_response) do
        instance_double(HTTParty::Response, code: 200, body: { state: 'not-configured' }.to_json)
      end

      let(:ok_response) do
        instance_double(HTTParty::Response, code: 200, body: '{}')
      end

      let(:accepted_response) do
        instance_double(HTTParty::Response, code: 202, body: '{}')
      end

      before do
        allow(github_client).to(receive(:get).with(repo_url).and_return(repo_info_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/branches/#{default_branch}/protection", expected_codes: [200, 404]).and_return(protection_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup", expected_codes: nil).and_return(codeql_default_setup_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/branches/#{default_branch}/protection", body: anything).and_return(ok_response))
        allow(github_client).to(receive(:post).with("#{repo_url}/branches/#{default_branch}/protection/required_signatures", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/vulnerability-alerts", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:put).with("#{repo_url}/automated-security-fixes", expected_codes: [200, 204]).and_return(ok_response))
        allow(github_client).to(receive(:patch).with(repo_url, body: anything).and_return(ok_response))
        allow(github_client).to(receive(:get).with("#{repo_url}/code-scanning/default-setup").and_return(codeql_get_response))
        allow(github_client).to(receive(:patch).with("#{repo_url}/code-scanning/default-setup", body: anything, expected_codes: [200, 202]).and_return(accepted_response))
      end

      it 'defaults to empty array for checks when key is missing' do # rubocop:disable RSpec/ExampleLength
        configurator.configure

        expect(github_client).to(
          have_received(:put).with(
            "#{repo_url}/branches/#{default_branch}/protection",
            body: hash_including(
              required_status_checks: hash_including(checks: [])
            )
          )
        )
      end
    end
  end
end
