# frozen_string_literal: true

RSpec.describe(GHB) do
  describe 'public constants' do
    it 'defines DEFAULT_JOB_TIMEOUT_MINUTES as a positive integer' do # rubocop:disable RSpec/MultipleExpectations
      expect(described_class::DEFAULT_JOB_TIMEOUT_MINUTES).to(be_a(Integer))
      expect(described_class::DEFAULT_JOB_TIMEOUT_MINUTES).to(eq(30))
    end
  end

  describe 'private constants' do
    it 'keeps configuration constants private' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      # These constants exist but are private - accessing them should raise NameError
      expect { described_class::CI_ACTIONS_VERSION }
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
