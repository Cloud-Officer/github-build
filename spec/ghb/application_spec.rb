# frozen_string_literal: true

RSpec.describe(GHB::Application) do
  describe '#validate_config!' do
    let(:config_test_class) do
      Class.new(described_class) do
        def initialize(options) # rubocop:disable Lint/MissingSuper
          @options = options
          @submodules = []
          @file_cache = {}
        end

        public :validate_config!
      end
    end
    let(:mock_options) do
      instance_double(
        GHB::Options,
        linters_config_file: 'config/linters.yaml',
        languages_config_file: 'config/languages.yaml',
        options_config_file_apt: 'config/options/apt.yaml',
        options_config_file_mongodb: 'config/options/mongodb.yaml',
        options_config_file_mysql: 'config/options/mysql.yaml',
        options_config_file_redis: 'config/options/redis.yaml',
        options_config_file_elasticsearch: 'config/options/elasticsearch.yaml',
        gitignore_config_file: 'config/gitignore.yaml'
      )
    end

    it 'does not raise when all config files exist and are valid YAML' do
      # The real config files exist in the project
      config_app = config_test_class.new(mock_options)
      expect { config_app.validate_config! }
        .not_to(raise_error)
    end

    it 'raises ConfigError when a config file is missing' do # rubocop:disable RSpec/ExampleLength
      bad_options = instance_double(
        GHB::Options,
        linters_config_file: 'config/nonexistent.yaml',
        languages_config_file: 'config/languages.yaml',
        options_config_file_apt: 'config/options/apt.yaml',
        options_config_file_mongodb: 'config/options/mongodb.yaml',
        options_config_file_mysql: 'config/options/mysql.yaml',
        options_config_file_redis: 'config/options/redis.yaml',
        options_config_file_elasticsearch: 'config/options/elasticsearch.yaml',
        gitignore_config_file: 'config/gitignore.yaml'
      )
      config_app = config_test_class.new(bad_options)

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, /Missing required linters config file/))
    end

    it 'raises ConfigError when a config file has invalid YAML' do # rubocop:disable RSpec/ExampleLength
      config_app = config_test_class.new(mock_options)

      # Drive the real #validate_config! and exercise its real
      # Psych::SyntaxError rescue: return malformed YAML only for the
      # languages config (parsed after the valid linters config), letting
      # every other file read through to the real on-disk config.
      allow(config_app).to(
        receive(:cached_file_read).and_wrap_original do |original, path|
          path.end_with?('languages.yaml') ? 'invalid: yaml: syntax: [' : original.call(path)
        end
      )

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, %r{Invalid YAML in languages config file \(config/languages\.yaml\)}))
    end

    it 'raises ConfigError when a linter entry is missing required keys' do # rubocop:disable RSpec/ExampleLength
      linters_yaml = <<~YAML
        bad_linter:
          short_name: bad
          long_name: Bad Linter
      YAML

      allow(File).to(receive_messages(exist?: true, read: linters_yaml))

      config_app = config_test_class.new(mock_options)

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, %r{Linter 'bad_linter' in config/linters.yaml is missing required keys: uses, path, pattern}))
    end

    it 'raises ConfigError when a language entry is missing required keys' do # rubocop:disable RSpec/ExampleLength
      linters_yaml = File.read("#{__dir__}/../../config/linters.yaml")
      languages_yaml = <<~YAML
        bad_lang:
          file_extension: bad
      YAML

      allow(File).to(receive(:exist?).and_return(true))
      allow(File).to(receive(:read).with(/linters\.yaml/).and_return(linters_yaml))
      allow(File).to(receive(:read).with(/languages\.yaml/).and_return(languages_yaml))

      config_app = config_test_class.new(mock_options)

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, %r{Language 'bad_lang' in config/languages.yaml is missing required keys: short_name, long_name}))
    end

    it 'raises ConfigError when a service option entry is missing name' do # rubocop:disable RSpec/ExampleLength
      valid_yaml = "valid: yaml\n"
      options_yaml = <<~YAML
        options:
          - value: some_value
      YAML

      allow(File).to(receive_messages(exist?: true, read: valid_yaml))
      allow(File).to(receive(:read).with(%r{options/apt\.yaml}).and_return(options_yaml))

      config_app = config_test_class.new(mock_options)

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, %r{Option entry 0 in config/options/apt.yaml is missing required key: name}))
    end

    it 'outputs ignored folders as JSON when get_ignored_folders is set' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      ignored_options = instance_double(
        GHB::Options,
        get_ignored_folders: true,
        languages_config_file: 'config/languages.yaml'
      )
      app = config_test_class.new(ignored_options)

      output = +''
      allow($stdout).to(receive(:write) { |str| output << str })

      expect(app.execute).to(eq(GHB::Status::SUCCESS_EXIT_CODE))

      json = JSON.parse(output)

      expect(json).to(have_key('ignored_folders'))
      expect(json['ignored_folders']).to(be_an(Array))
      expect(json['ignored_folders']).to(include('node_modules'))
      expect(json['ignored_folders']).to(include('vendor'))
      expect(json['ignored_folders']).to(include('.git'))
    end

    it 'provides clear error message with file path' do # rubocop:disable RSpec/ExampleLength
      bad_options = instance_double(
        GHB::Options,
        linters_config_file: 'custom/path/linters.yaml',
        languages_config_file: 'config/languages.yaml',
        options_config_file_apt: 'config/options/apt.yaml',
        options_config_file_mongodb: 'config/options/mongodb.yaml',
        options_config_file_mysql: 'config/options/mysql.yaml',
        options_config_file_redis: 'config/options/redis.yaml',
        options_config_file_elasticsearch: 'config/options/elasticsearch.yaml',
        gitignore_config_file: 'config/gitignore.yaml'
      )
      config_app = config_test_class.new(bad_options)

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, 'Missing required linters config file: custom/path/linters.yaml'))
    end
  end

  describe 'private internals' do
    let(:internals_class) do
      Class.new(described_class) do
        def initialize; end # rubocop:disable Lint/MissingSuper

        public :detect_default_branch, :validate_entries
      end
    end
    let(:app) { internals_class.new }

    describe '#detect_default_branch' do
      it 'returns the branch reported by git symbolic-ref' do
        allow(app).to(receive(:`).with('git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null').and_return("refs/remotes/origin/main\n"))

        expect(app.detect_default_branch).to(eq('main'))
      end

      it "falls back to 'master' when origin/HEAD is not resolvable" do
        allow(app).to(receive(:`).with('git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null').and_return(''))

        expect(app.detect_default_branch).to(eq('master'))
      end

      it "detects 'master' when that is the default branch" do
        allow(app).to(receive(:`).with('git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null').and_return("refs/remotes/origin/master\n"))

        expect(app.detect_default_branch).to(eq('master'))
      end
    end

    describe '#validate_entries' do
      it 'is permissive: silently skips entry values that are not a Hash' do
        expect { app.validate_entries({ rubocop: 'true' }, 'config/linters.yaml', 'linter', %w[short_name]) }
          .not_to(raise_error)
      end

      it 'returns without error when the document root is not a Hash' do
        expect { app.validate_entries([], 'config/linters.yaml', 'linter', %w[short_name]) }
          .not_to(raise_error)
      end

      it 'still raises for a Hash entry missing required keys (skip is value-type only)' do
        expect { app.validate_entries({ bad: { short_name: 'x' } }, 'config/linters.yaml', 'linter', %w[short_name long_name]) }
          .to(raise_error(GHB::ConfigError, %r{Linter 'bad' in config/linters.yaml is missing required keys: long_name}))
      end
    end
  end
end
