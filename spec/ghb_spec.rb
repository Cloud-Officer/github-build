# frozen_string_literal: true

RSpec.describe(GHB) do
  describe 'public constants' do
    it 'defines DEFAULT_JOB_TIMEOUT_MINUTES as a positive integer' do # rubocop:disable RSpec/MultipleExpectations
      expect(described_class::DEFAULT_JOB_TIMEOUT_MINUTES).to(be_a(Integer))
      expect(described_class::DEFAULT_JOB_TIMEOUT_MINUTES).to(eq(30))
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
      expect { described_class::OPTIONS_APT_CONFIG_FILE }
        .to(raise_error(NameError))
      expect { described_class::OPTIONS_MONGODB_CONFIG_FILE }
        .to(raise_error(NameError))
      expect { described_class::OPTIONS_MYSQL_CONFIG_FILE }
        .to(raise_error(NameError))
      expect { described_class::OPTIONS_REDIS_CONFIG_FILE }
        .to(raise_error(NameError))
      expect { described_class::DEFAULT_UBUNTU_VERSION }
        .to(raise_error(NameError))
    end
  end
end
