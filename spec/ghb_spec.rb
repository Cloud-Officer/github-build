# frozen_string_literal: true

RSpec.describe(GHB) do
  describe 'public constants' do
    it 'defines DEFAULT_JOB_TIMEOUT_MINUTES as a positive integer' do # rubocop:disable RSpec/MultipleExpectations
      expect(described_class::DEFAULT_JOB_TIMEOUT_MINUTES).to(be_a(Integer))
      expect(described_class::DEFAULT_JOB_TIMEOUT_MINUTES).to(eq(30))
    end

    it 'exposes the service registry', :aggregate_failures do
      expect(described_class::SERVICES).to(eq(%i[apt mongodb mysql redis opensearch]))
      expect(described_class::SERVICES).to(be_frozen)
    end

    it 'splits the registry into always enabled and detectable services', :aggregate_failures do
      expect(described_class::ALWAYS_ENABLED_SERVICES).to(eq(%i[apt]))
      expect(described_class::DETECTABLE_SERVICES).to(eq(%i[mongodb mysql redis opensearch]))
      expect(described_class::ALWAYS_ENABLED_SERVICES + described_class::DETECTABLE_SERVICES).to(match_array(described_class::SERVICES))
    end

    it 'ships an options file for every registered service' do
      described_class::SERVICES.each do |service|
        expect(File).to(exist(File.expand_path("../#{described_class.service_config_file(service)}", __dir__)))
      end
    end
  end

  describe 'service helpers' do
    it 'derives the default options file path from the service name' do
      expect(described_class.service_config_file(:postgres)).to(eq('config/options/postgres.yaml'))
    end

    it 'uses the display name table when present', :aggregate_failures do
      expect(described_class.service_display_name(:apt)).to(eq('APT'))
      expect(described_class.service_display_name(:mongodb)).to(eq('MongoDB'))
      expect(described_class.service_display_name(:mysql)).to(eq('MySQL'))
      expect(described_class.service_display_name(:opensearch)).to(eq('OpenSearch'))
    end

    it 'falls back to a capitalized name for services absent from the table', :aggregate_failures do
      expect(described_class.service_display_name(:redis)).to(eq('Redis'))
      expect(described_class.service_display_name(:postgres)).to(eq('Postgres'))
    end

    it 'derives the config validation key' do
      expect(described_class.service_config_key(:mysql)).to(eq(:mysql_options))
    end

    it 'derives the language dependency key' do
      expect(described_class.service_dependency_key(:mysql)).to(eq(:mysql_dependency))
    end
  end

  describe '.external_action' do
    let(:manifest) { Psych.safe_load_file(File.expand_path('../config/actions.yaml', __dir__)) }

    it 'returns owner/repo@version using the version pinned in config/actions.yaml' do
      manifest.each do |name, version|
        expect(described_class.external_action(name)).to(eq("#{name}@#{version}"))
      end
    end

    it 'raises ConfigError for an action absent from the manifest' do
      expect { described_class.external_action('nonexistent/action') }
        .to(raise_error(GHB::ConfigError, %r{not found in config/actions\.yaml}))
    end

    it 'raises ConfigError when the manifest is missing' do
      allow(File).to(receive(:exist?).and_call_original)
      allow(File).to(receive(:exist?).with(%r{config/actions\.yaml\z}).and_return(false))

      expect { described_class.external_action('actions/checkout') }
        .to(raise_error(GHB::ConfigError, 'Missing required external actions file: config/actions.yaml'))
    end

    it 'raises ConfigError when the manifest is empty or comment-only' do
      allow(Psych).to(receive(:safe_load_file).and_return(nil))

      expect { described_class.external_action('actions/checkout') }
        .to(raise_error(GHB::ConfigError, %r{config/actions\.yaml must be a non-empty map}))
    end

    it 'raises ConfigError when the manifest is not valid YAML' do
      allow(Psych).to(receive(:safe_load_file).and_raise(Psych::SyntaxError.new('config/actions.yaml', 1, 1, 0, 'bad', 'context')))

      expect { described_class.external_action('actions/checkout') }
        .to(raise_error(GHB::ConfigError, %r{Invalid YAML in external actions file \(config/actions\.yaml\)}))
    end
  end

  describe '.validate_external_actions!' do
    it 'accepts a non-empty map of action name to version string' do
      expect { described_class.validate_external_actions!({ 'actions/checkout': 'v7' }.transform_keys(&:to_s)) }
        .not_to(raise_error)
    end

    [
      ['nil', nil],
      ['an empty map', {}],
      ['a list', ['actions/checkout']],
      ['a map with a non-string version', { 'actions/checkout': 7 }.transform_keys(&:to_s)],
      ['a map with a non-string action name', { checkout: 'v7' }]
    ].each do |description, actions|
      it "raises ConfigError for #{description}" do
        expect { described_class.validate_external_actions!(actions) }
          .to(raise_error(GHB::ConfigError, 'config/actions.yaml must be a non-empty map of action name to version string'))
      end
    end
  end

  describe 'hand-maintained workflows' do
    let(:github_root) { File.expand_path('../.github', __dir__) }
    let(:ci_actions_references) do
      Dir.glob("#{github_root}/**/*.{yml,yaml}").flat_map do |path|
        File.foreach(path).with_index(1).filter_map do |line, number|
          match = line.match(%r{cloud-officer/ci-actions[^@\s]*@(\S+)})
          match && { location: "#{path.delete_prefix("#{github_root}/")}:#{number}", version: match[1] }
        end
      end
    end

    it 'references cloud-officer/ci-actions under .github' do
      expect(ci_actions_references).not_to(be_empty)
    end

    it 'pins every cloud-officer/ci-actions reference under .github to CI_ACTIONS_VERSION' do
      drifted = ci_actions_references.reject { |reference| reference[:version] == described_class.const_get(:CI_ACTIONS_VERSION) }

      expect(drifted).to(eq([]))
    end
  end

  describe 'private constants' do
    it 'keeps configuration constants private' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      # These constants exist but are private - accessing them should raise NameError
      expect { described_class::CI_ACTIONS_VERSION }
        .to(raise_error(NameError))
      expect { described_class::EXTERNAL_ACTIONS_CONFIG_FILE }
        .to(raise_error(NameError))
      expect { described_class::DEFAULT_BUILD_FILE }
        .to(raise_error(NameError))
      expect { described_class::DEFAULT_LINTERS_CONFIG_FILE }
        .to(raise_error(NameError))
      expect { described_class::DEFAULT_LANGUAGES_CONFIG_FILE }
        .to(raise_error(NameError))
      expect { described_class::DEFAULT_GITIGNORE_CONFIG_FILE }
        .to(raise_error(NameError))
      expect { described_class::SERVICE_DISPLAY_NAMES }
        .to(raise_error(NameError))
      expect { described_class::DEFAULT_UBUNTU_VERSION }
        .to(raise_error(NameError))
    end
  end
end
