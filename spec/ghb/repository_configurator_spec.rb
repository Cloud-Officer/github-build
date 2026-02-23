# frozen_string_literal: true

RSpec.describe(GHB::RepositoryConfigurator) do
  describe '#configure' do
    it 'raises ConfigError when GITHUB_TOKEN is not set' do
      mock_options = instance_double(GHB::Options, skip_repository_settings: false)
      configurator = described_class.new(options: mock_options, required_status_checks: [])

      # Ensure GITHUB_TOKEN is not set
      allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', nil).and_return(nil))

      expect { configurator.configure }
        .to(raise_error(GHB::ConfigError, 'GITHUB_TOKEN environment variable is required for repository settings'))
    end

    it 'raises ConfigError when GITHUB_TOKEN is empty' do
      mock_options = instance_double(GHB::Options, skip_repository_settings: false)
      configurator = described_class.new(options: mock_options, required_status_checks: [])

      # Set GITHUB_TOKEN to empty string
      allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', nil).and_return(''))

      expect { configurator.configure }
        .to(raise_error(GHB::ConfigError, 'GITHUB_TOKEN environment variable is required for repository settings'))
    end

    it 'skips validation when skip_repository_settings is true' do
      mock_options = instance_double(GHB::Options, skip_repository_settings: true)
      configurator = described_class.new(options: mock_options, required_status_checks: [])

      # Should return early without checking token
      expect { configurator.configure }
        .not_to(raise_error)
    end
  end
end
