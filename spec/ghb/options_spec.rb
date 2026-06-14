# frozen_string_literal: true

RSpec.describe(GHB::Options) do
  # Access private constants for testing
  let(:default_build_file)       { '.github/workflows/build.yml' }
  let(:default_linters_config)   { 'config/linters.yaml'         }
  let(:default_languages_config) { 'config/languages.yaml'       }
  let(:default_gitignore_config) { 'config/gitignore.yaml'       }

  describe '#initialize' do
    before do
      allow(File).to(receive(:exist?).and_return(false))
    end

    it 'sets default values' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = described_class.new([])

      expect(options.build_file).to(eq(default_build_file))
      expect(options.linters_config_file).to(eq(default_linters_config))
      expect(options.languages_config_file).to(eq(default_languages_config))
      expect(options.gitignore_config_file).to(eq(default_gitignore_config))
      expect(options.excluded_folders).to(eq([]))
      expect(options.ignored_linters).to(eq({}))
      expect(options.skip_semgrep).to(be(false))
      expect(options.skip_gitignore).to(be(false))
      expect(options.skip_license_check).to(be(false))
      expect(options.skip_repository_settings).to(be(false))
      expect(options.skip_slack).to(be(false))
      expect(options.force_codedeploy_setup).to(be(false))
      expect(options.get_ignored_folders).to(be(false))
      expect(options.strict_version_check).to(be(true))
    end

    it 'derives application_name from current directory' do
      allow(Dir).to(receive(:pwd).and_return('/path/to/my-awesome-app'))
      options = described_class.new([])

      expect(options.application_name).to(eq('app'))
    end

    it 'derives organization from parent directory' do
      allow(Dir).to(receive(:pwd).and_return('/path/to/my-org/my-repo'))
      options = described_class.new([])

      expect(options.organization).to(eq('my-org'))
    end

    it 'reads args from existing build file when no argv provided' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      allow(File).to(receive(:exist?).with(default_build_file).and_return(true))
      allow(File).to(receive(:foreach).with(default_build_file).and_return(["# github-build --organization TestOrg --skip_slack\n", "name: CI\n"].each))

      options = described_class.new([])
      options.parse

      expect(options.organization).to(eq('TestOrg'))
      expect(options.skip_slack).to(be(true))
    end
  end

  describe '#parse' do
    before do
      allow(File).to(receive(:exist?).and_return(false))
    end

    it 'parses --organization' do
      options = described_class.new(['--organization', 'MyOrg'])
      options.parse

      expect(options.organization).to(eq('MyOrg'))
    end

    it 'parses --application_name' do
      options = described_class.new(['--application_name', 'myapp'])
      options.parse

      expect(options.application_name).to(eq('myapp'))
    end

    it 'parses --build_file' do
      options = described_class.new(['--build_file', 'custom/build.yml'])
      options.parse

      expect(options.build_file).to(eq('custom/build.yml'))
    end

    it 'parses --excluded_folders as comma-separated list' do
      options = described_class.new(['--excluded_folders', 'vendor,tmp,log'])
      options.parse

      expect(options.excluded_folders).to(eq(%w[vendor tmp log]))
    end

    it 'parses --ignored_linters as comma-separated list' do
      options = described_class.new(['--ignored_linters', 'rubocop,eslint'])
      options.parse

      expect(options.ignored_linters).to(eq({ rubocop: true, eslint: true }))
    end

    it 'parses --skip_semgrep' do
      options = described_class.new(['--skip_semgrep'])
      options.parse

      expect(options.skip_semgrep).to(be(true))
    end

    it 'parses --skip_gitignore' do
      options = described_class.new(['--skip_gitignore'])
      options.parse

      expect(options.skip_gitignore).to(be(true))
    end

    it 'parses --skip_license_check' do
      options = described_class.new(['--skip_license_check'])
      options.parse

      expect(options.skip_license_check).to(be(true))
    end

    it 'parses --skip_repository_settings' do
      options = described_class.new(['--skip_repository_settings'])
      options.parse

      expect(options.skip_repository_settings).to(be(true))
    end

    it 'parses --skip_slack' do
      options = described_class.new(['--skip_slack'])
      options.parse

      expect(options.skip_slack).to(be(true))
    end

    it 'parses --force_codedeploy_setup' do
      options = described_class.new(['--force_codedeploy_setup'])
      options.parse

      expect(options.force_codedeploy_setup).to(be(true))
    end

    it 'parses --get_ignored_folders' do
      options = described_class.new(['--get_ignored_folders'])
      options.parse

      expect(options.get_ignored_folders).to(be(true))
    end

    it 'parses --no_strict_version_check' do
      options = described_class.new(['--no_strict_version_check'])
      options.parse

      expect(options.strict_version_check).to(be(false))
    end

    it 'parses --linters_config_file' do
      options = described_class.new(['--linters_config_file', 'custom/linters.yaml'])
      options.parse

      expect(options.linters_config_file).to(eq('custom/linters.yaml'))
    end

    it 'parses --languages_config_file' do
      options = described_class.new(['--languages_config_file', 'custom/languages.yaml'])
      options.parse

      expect(options.languages_config_file).to(eq('custom/languages.yaml'))
    end

    it 'parses --gitignore_config_file' do
      options = described_class.new(['--gitignore_config_file', 'custom/gitignore.yaml'])
      options.parse

      expect(options.gitignore_config_file).to(eq('custom/gitignore.yaml'))
    end

    it 'parses --options-mongodb' do
      options = described_class.new(['--options-mongodb', 'custom/mongodb.yaml'])
      options.parse

      expect(options.options_config_file_mongodb).to(eq('custom/mongodb.yaml'))
    end

    it 'parses --options-mysql' do
      options = described_class.new(['--options-mysql', 'custom/mysql.yaml'])
      options.parse

      expect(options.options_config_file_mysql).to(eq('custom/mysql.yaml'))
    end

    it 'parses --options-redis' do
      options = described_class.new(['--options-redis', 'custom/redis.yaml'])
      options.parse

      expect(options.options_config_file_redis).to(eq('custom/redis.yaml'))
    end

    it 'parses --options-apt' do
      options = described_class.new(['--options-apt', 'custom/apt.yaml'])
      options.parse

      expect(options.options_config_file_apt).to(eq('custom/apt.yaml'))
    end

    it 'parses multiple options together' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = described_class.new(
        [
          '--organization',
          'TestOrg',
          '--skip_slack',
          '--excluded_folders',
          'vendor,tmp'
        ]
      )
      options.parse

      expect(options.organization).to(eq('TestOrg'))
      expect(options.skip_slack).to(be(true))
      expect(options.excluded_folders).to(eq(%w[vendor tmp]))
    end

    it 'returns self for chaining' do
      options = described_class.new([])
      result = options.parse

      expect(result).to(eq(options))
    end
  end

  describe '#parse (invalid input)' do
    before do
      allow(File).to(receive(:exist?).and_return(false))
    end

    it 'raises InvalidOption on an unknown flag' do
      expect { described_class.new(['--bogus']).parse }
        .to(raise_error(OptionParser::InvalidOption))
    end

    it 'raises MissingArgument when a value-taking flag has no value' do
      expect { described_class.new(['--organization']).parse }
        .to(raise_error(OptionParser::MissingArgument))
    end

    it 'normalizes an empty --excluded_folders value to []' do
      options = described_class.new(['--excluded_folders', '']).parse

      expect(options.excluded_folders).to(eq([]))
    end

    it 'drops blank entries from a partially-empty --excluded_folders value' do
      options = described_class.new(['--excluded_folders', 'vendor,,tmp,']).parse

      expect(options.excluded_folders).to(eq(%w[vendor tmp]))
    end
  end

  describe '#args_comment' do
    before do
      allow(File).to(receive(:exist?).and_return(false))
    end

    it 'returns empty string when no arguments' do
      options = described_class.new([])
      expect(options.args_comment).to(eq(''))
    end

    it 'returns comment with original arguments' do
      options = described_class.new(['--organization', 'TestOrg', '--skip_slack'])
      comment = options.args_comment

      expect(comment).to(eq("# github-build --organization TestOrg --skip_slack\n"))
    end

    it 'omits ephemeral flags from the persisted comment' do
      options = described_class.new(['--organization', 'TestOrg', '--sync_required_status_checks', '--skip_slack']).parse

      expect(options.args_comment).to(eq("# github-build --organization TestOrg --skip_slack\n"))
    end

    it 'still parses ephemeral flags into option state' do
      options = described_class.new(['--sync_required_status_checks']).parse

      expect(options.sync_required_status_checks).to(be(true))
    end
  end

  describe 'args from build file' do
    it 'returns empty array when file does not exist' do
      allow(File).to(receive(:exist?).and_return(false))
      options = described_class.new([])

      expect(options.original_argv).to(eq([]))
    end

    it 'returns empty array when first line does not start with prefix' do
      allow(File).to(receive_messages(exist?: true, foreach: ["name: CI\n", "on: push\n"].each))

      options = described_class.new([])
      expect(options.original_argv).to(eq([]))
    end

    it 'handles empty file gracefully' do
      allow(File).to(receive_messages(exist?: true, foreach: [].each))

      options = described_class.new([])
      expect(options.original_argv).to(eq([]))
    end

    it 'parses arguments with shellwords' do
      allow(File).to(receive_messages(exist?: true, foreach: ["# github-build --organization 'My Org' --skip_slack\n"].each))

      options = described_class.new([])
      expect(options.original_argv).to(eq(['--organization', 'My Org', '--skip_slack']))
    end

    it 'raises a clear ConfigError on malformed quoting instead of a raw Shellwords stack trace' do
      allow(File).to(receive_messages(exist?: true, foreach: ["# github-build --organization 'unterminated\n"].each))

      expect { described_class.new([]) }
        .to(raise_error(GHB::ConfigError, /Malformed github-build args/))
    end
  end

  describe 'removed flags in persisted header' do
    it 'strips a removed flag from replayed args instead of aborting (BC-001)' do
      allow(File).to(receive_messages(exist?: true, foreach: ["# github-build --organization TestOrg --mono_repo --skip_slack\n"].each))
      allow($stderr).to(receive(:write))

      options = described_class.new([])

      expect(options.original_argv).to(eq(['--organization', 'TestOrg', '--skip_slack']))
    end

    it 'parses cleanly after the removed flag is stripped' do # rubocop:disable RSpec/MultipleExpectations
      allow(File).to(receive_messages(exist?: true, foreach: ["# github-build --organization TestOrg --mono_repo --skip_slack\n"].each))
      allow($stderr).to(receive(:write))

      options = described_class.new([]).parse

      expect(options.organization).to(eq('TestOrg'))
      expect(options.skip_slack).to(be(true))
    end

    it 'self-heals the persisted header by dropping the removed flag from args_comment' do
      allow(File).to(receive_messages(exist?: true, foreach: ["# github-build --organization TestOrg --mono_repo --skip_slack\n"].each))
      allow($stderr).to(receive(:write))

      options = described_class.new([])

      expect(options.args_comment).to(eq("# github-build --organization TestOrg --skip_slack\n"))
    end

    it 'warns on stderr when a removed flag is stripped' do
      allow(File).to(receive_messages(exist?: true, foreach: ["# github-build --mono_repo\n"].each))

      expect { described_class.new([]) }
        .to(output(/ignoring removed option '--mono_repo'/).to_stderr)
    end

    it 'strips a removed flag written in --flag=value form' do
      allow(File).to(receive_messages(exist?: true, foreach: ["# github-build --mono_repo=true --skip_slack\n"].each))
      allow($stderr).to(receive(:write))

      options = described_class.new([])

      expect(options.original_argv).to(eq(['--skip_slack']))
    end

    it 'still aborts when a removed flag is passed explicitly on the command line' do
      allow(File).to(receive(:exist?).and_return(false))

      expect { described_class.new(['--mono_repo']).parse }
        .to(raise_error(OptionParser::InvalidOption))
    end
  end
end
