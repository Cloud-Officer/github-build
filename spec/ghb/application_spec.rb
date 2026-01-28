# frozen_string_literal: true

RSpec.describe(GHB::Application) do
  # Create a test subclass to access private methods
  let(:test_class) do
    Class.new(described_class) do
      def initialize # rubocop:disable Lint/MissingSuper
        @submodules = []
        @file_cache = {}
      end

      public :find_files_matching, :file_contains?, :atomic_copy_config
    end
  end

  let(:app) { test_class.new }

  describe '#find_files_matching' do
    let(:temp_dir) { Dir.mktmpdir('ghb-test') }

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it 'finds files matching a pattern' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.touch("#{temp_dir}/test.rb")
      FileUtils.touch("#{temp_dir}/test.js")
      FileUtils.mkdir_p("#{temp_dir}/lib")
      FileUtils.touch("#{temp_dir}/lib/app.rb")

      pattern = /\.rb$/
      matches = app.find_files_matching(temp_dir, pattern, [])

      expect(matches).to(include("#{temp_dir}/test.rb"))
      expect(matches).to(include("#{temp_dir}/lib/app.rb"))
      expect(matches).not_to(include("#{temp_dir}/test.js"))
    end

    it 'excludes specified paths' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.mkdir_p("#{temp_dir}/vendor")
      FileUtils.touch("#{temp_dir}/app.rb")
      FileUtils.touch("#{temp_dir}/vendor/gem.rb")

      pattern = /\.rb$/
      matches = app.find_files_matching(temp_dir, pattern, ['vendor'])

      expect(matches).to(include("#{temp_dir}/app.rb"))
      expect(matches).not_to(include("#{temp_dir}/vendor/gem.rb"))
    end

    it 'excludes node_modules by default' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.mkdir_p("#{temp_dir}/node_modules")
      FileUtils.touch("#{temp_dir}/app.js")
      FileUtils.touch("#{temp_dir}/node_modules/lib.js")

      pattern = /\.js$/
      matches = app.find_files_matching(temp_dir, pattern, [])

      expect(matches).to(include("#{temp_dir}/app.js"))
      expect(matches).not_to(include("#{temp_dir}/node_modules/lib.js"))
    end

    it 'excludes vendor by default' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.mkdir_p("#{temp_dir}/vendor")
      FileUtils.touch("#{temp_dir}/app.rb")
      FileUtils.touch("#{temp_dir}/vendor/bundle.rb")

      pattern = /\.rb$/
      matches = app.find_files_matching(temp_dir, pattern, [])

      expect(matches).to(include("#{temp_dir}/app.rb"))
      expect(matches).not_to(include("#{temp_dir}/vendor/bundle.rb"))
    end

    it 'respects max_depth option' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.mkdir_p("#{temp_dir}/a/b/c/d/e/f")
      FileUtils.touch("#{temp_dir}/level0.rb")
      FileUtils.touch("#{temp_dir}/a/level1.rb")
      FileUtils.touch("#{temp_dir}/a/b/c/d/e/f/level6.rb")

      pattern = /\.rb$/

      # max_depth limits how deep we traverse from the starting path
      shallow_matches = app.find_files_matching(temp_dir, pattern, [], max_depth: 1)
      deep_matches = app.find_files_matching(temp_dir, pattern, [], max_depth: 10)

      # Shallow search should find files near the root but not deeply nested ones
      expect(shallow_matches).to(include("#{temp_dir}/level0.rb"))
      expect(shallow_matches).not_to(include("#{temp_dir}/a/b/c/d/e/f/level6.rb"))

      # Deep search should find all files
      expect(deep_matches).to(include("#{temp_dir}/level0.rb"))
      expect(deep_matches).to(include("#{temp_dir}/a/level1.rb"))
      expect(deep_matches).to(include("#{temp_dir}/a/b/c/d/e/f/level6.rb"))
    end

    it 'returns empty array for non-existent path' do
      matches = app.find_files_matching('/nonexistent/path/that/does/not/exist', /\.rb$/, [])
      expect(matches).to(eq([]))
    end

    it 'handles permission denied gracefully' do # rubocop:disable RSpec/ExampleLength
      skip 'Cannot test permission denied as root' if Process.uid.zero? # rubocop:disable RSpec/Pending

      restricted_dir = "#{temp_dir}/restricted"
      FileUtils.mkdir_p(restricted_dir)
      FileUtils.chmod(0o000, restricted_dir)

      expect { app.find_files_matching(restricted_dir, /.*/, []) }
        .not_to(raise_error)

      FileUtils.chmod(0o755, restricted_dir)
    end
  end

  describe '#file_contains?' do
    let(:temp_file) { Tempfile.new(['test', '.txt']) }

    after do
      temp_file.close
      temp_file.unlink
    end

    it 'returns true when file contains pattern' do
      temp_file.write("gem 'rails'\ngem 'pg'\ngem 'redis'\n")
      temp_file.flush

      expect(app.file_contains?(temp_file.path, 'redis')).to(be(true))
    end

    it 'returns false when file does not contain pattern' do
      temp_file.write("gem 'rails'\ngem 'pg'\n")
      temp_file.flush

      expect(app.file_contains?(temp_file.path, 'redis')).to(be(false))
    end

    it 'returns false for non-existent file' do
      expect(app.file_contains?('/nonexistent/file.txt', 'pattern')).to(be(false))
    end

    it 'handles partial matches' do
      temp_file.write("mongodb-driver\n")
      temp_file.flush

      expect(app.file_contains?(temp_file.path, 'mongo')).to(be(true))
    end
  end

  describe 'command injection prevention' do
    let(:temp_dir) { Dir.mktmpdir('ghb-security-test') }

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it 'does not execute shell commands in patterns' do
      malicious_pattern = '$(touch /tmp/pwned)'
      pwned_file = '/tmp/pwned'
      FileUtils.rm_f(pwned_file)

      # This should not create the file
      app.find_files_matching(temp_dir, Regexp.new(Regexp.escape(malicious_pattern)), [])

      expect(File.exist?(pwned_file)).to(be(false))
    end

    it 'handles regex special characters safely' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.touch("#{temp_dir}/file.rb")
      FileUtils.touch("#{temp_dir}/file[1].rb")

      pattern = /\[1\]\.rb$/
      matches = app.find_files_matching(temp_dir, pattern, [])

      expect(matches).to(include("#{temp_dir}/file[1].rb"))
      expect(matches).not_to(include("#{temp_dir}/file.rb"))
    end
  end

  describe '#atomic_copy_config' do
    let(:temp_dir) { Dir.mktmpdir('ghb-atomic-test') }

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it 'copies file to target location' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/target.txt"
      File.write(source, "original content\n")

      app.atomic_copy_config(source, target)

      expect(File.exist?(target)).to(be(true))
      expect(File.read(target)).to(eq("original content\n"))
    end

    it 'applies transformation block to content' do
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/target.txt"
      File.write(source, "hello world\n")

      app.atomic_copy_config(source, target, &:upcase)

      expect(File.read(target)).to(eq("HELLO WORLD\n"))
    end

    it 'replaces existing regular file' do # rubocop:disable RSpec/ExampleLength
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/target.txt"
      File.write(source, "new content\n")
      File.write(target, "old content\n")

      app.atomic_copy_config(source, target)

      expect(File.read(target)).to(eq("new content\n"))
    end

    it 'replaces existing symlink' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/target.txt"
      other = "#{temp_dir}/other.txt"
      File.write(source, "new content\n")
      File.write(other, "other content\n")
      FileUtils.ln_s(other, target)

      app.atomic_copy_config(source, target)

      expect(File.symlink?(target)).to(be(false))
      expect(File.read(target)).to(eq("new content\n"))
    end

    it 'cleans up temp file on failure' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/subdir/target.txt"
      File.write(source, "content\n")
      # Don't create subdir - this will cause mv to fail

      expect { app.atomic_copy_config(source, target) }
        .to(raise_error(Errno::ENOENT))

      # Verify no temp files left behind
      temp_files = Dir.glob("#{temp_dir}/*.tmp.*")
      expect(temp_files).to(be_empty)
    end

    it 'preserves original file if copy fails' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      source = "#{temp_dir}/nonexistent.txt"
      target = "#{temp_dir}/target.txt"
      File.write(target, "original content\n")

      expect { app.atomic_copy_config(source, target) }
        .to(raise_error(Errno::ENOENT))

      # Original file should still exist with original content
      expect(File.read(target)).to(eq("original content\n"))
    end
  end

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

  describe '#check_repository_settings' do
    let(:repo_settings_test_class) do
      Class.new(described_class) do
        def initialize(options) # rubocop:disable Lint/MissingSuper
          @options = options
          @submodules = []
          @required_status_checks = []
        end

        public :check_repository_settings
      end
    end

    it 'raises ConfigError when GITHUB_TOKEN is not set' do
      mock_options = instance_double(GHB::Options, skip_repository_settings: false)
      app = repo_settings_test_class.new(mock_options)

      # Ensure GITHUB_TOKEN is not set
      allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', nil).and_return(nil))

      expect { app.check_repository_settings }
        .to(raise_error(GHB::ConfigError, 'GITHUB_TOKEN environment variable is required for repository settings'))
    end

    it 'raises ConfigError when GITHUB_TOKEN is empty' do
      mock_options = instance_double(GHB::Options, skip_repository_settings: false)
      app = repo_settings_test_class.new(mock_options)

      # Set GITHUB_TOKEN to empty string
      allow(ENV).to(receive(:fetch).with('GITHUB_TOKEN', nil).and_return(''))

      expect { app.check_repository_settings }
        .to(raise_error(GHB::ConfigError, 'GITHUB_TOKEN environment variable is required for repository settings'))
    end

    it 'skips validation when skip_repository_settings is true' do
      mock_options = instance_double(GHB::Options, skip_repository_settings: true)
      app = repo_settings_test_class.new(mock_options)

      # Should return early without checking token
      expect { app.check_repository_settings }
        .not_to(raise_error)
    end
  end
end
