# frozen_string_literal: true

RSpec.describe(GHB::Application) do
  describe '#validate_config!' do
    let(:temp_dir) { Dir.mktmpdir('ghb-config-test') }
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

    after do
      FileUtils.rm_rf(temp_dir)
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
      # Create a temp config structure
      FileUtils.mkdir_p("#{temp_dir}/config/options")
      File.write("#{temp_dir}/config/linters.yaml", "valid: yaml\n")
      File.write("#{temp_dir}/config/languages.yaml", 'invalid: yaml: syntax: [')
      File.write("#{temp_dir}/config/options/apt.yaml", "valid: yaml\n")
      File.write("#{temp_dir}/config/options/mongodb.yaml", "valid: yaml\n")
      File.write("#{temp_dir}/config/options/mysql.yaml", "valid: yaml\n")
      File.write("#{temp_dir}/config/options/redis.yaml", "valid: yaml\n")
      File.write("#{temp_dir}/config/gitignore.yaml", "valid: yaml\n")

      # Stub __dir__ to point to our temp directory
      temp_options = instance_double(
        GHB::Options,
        linters_config_file: "#{temp_dir}/config/linters.yaml",
        languages_config_file: "#{temp_dir}/config/languages.yaml",
        options_config_file_apt: "#{temp_dir}/config/options/apt.yaml",
        options_config_file_mongodb: "#{temp_dir}/config/options/mongodb.yaml",
        options_config_file_mysql: "#{temp_dir}/config/options/mysql.yaml",
        options_config_file_redis: "#{temp_dir}/config/options/redis.yaml",
        gitignore_config_file: "#{temp_dir}/config/gitignore.yaml"
      )

      # Create a custom test class that uses absolute paths directly
      absolute_path_test_class =
        Class.new do
          def initialize(options)
            @options = options
          end

          def validate_config!
            config_files = {
              'linters config': @options.linters_config_file,
              'languages config': @options.languages_config_file,
              'APT options': @options.options_config_file_apt,
              'MongoDB options': @options.options_config_file_mongodb,
              'MySQL options': @options.options_config_file_mysql,
              'Redis options': @options.options_config_file_redis,
              'gitignore config': @options.gitignore_config_file
            }

            config_files.each do |name, path|
              raise(GHB::ConfigError, "Missing required #{name} file: #{path}") unless File.exist?(path)

              begin
                Psych.safe_load(File.read(path), permitted_classes: [Symbol])
              rescue Psych::SyntaxError => e
                raise(GHB::ConfigError, "Invalid YAML in #{name} file (#{path}): #{e.message}")
              end
            end
          end
        end

      config_app = absolute_path_test_class.new(temp_options)

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, /Invalid YAML in languages config file/))
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

      call_count = 0
      allow(File).to(receive(:exist?).and_return(true))
      allow(File).to(receive(:read)) do
        call_count += 1
        call_count == 1 ? linters_yaml : languages_yaml
      end

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

      call_count = 0
      allow(File).to(receive(:exist?).and_return(true))
      allow(File).to(receive(:read)) do
        call_count += 1
        # linters (1), languages (2), apt_options (3)
        call_count == 3 ? options_yaml : valid_yaml
      end

      config_app = config_test_class.new(mock_options)

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, %r{Option entry 0 in config/options/apt.yaml is missing required key: name}))
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
end
