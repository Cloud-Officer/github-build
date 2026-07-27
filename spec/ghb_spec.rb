# frozen_string_literal: true

RSpec.describe(GHB) do
  describe 'public constants' do
    it 'defines DEFAULT_JOB_TIMEOUT_MINUTES as a positive integer' do # rubocop:disable RSpec/MultipleExpectations
      expect(described_class::DEFAULT_JOB_TIMEOUT_MINUTES).to(be_a(Integer))
      expect(described_class::DEFAULT_JOB_TIMEOUT_MINUTES).to(eq(30))
    end

    it 'exposes the service registry', :aggregate_failures do
      expect(described_class::SERVICES).to(eq(%i[apt mongodb mysql redis elasticsearch]))
      expect(described_class::SERVICES).to(be_frozen)
    end

    it 'splits the registry into always enabled and detectable services', :aggregate_failures do
      expect(described_class::ALWAYS_ENABLED_SERVICES).to(eq(%i[apt]))
      expect(described_class::DETECTABLE_SERVICES).to(eq(%i[mongodb mysql redis elasticsearch]))
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
      expect(described_class.service_display_name(:elasticsearch)).to(eq('Elasticsearch'))
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
