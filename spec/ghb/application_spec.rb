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
        options_config_files: { apt: 'config/options/apt.yaml', mongodb: 'config/options/mongodb.yaml', mysql: 'config/options/mysql.yaml', redis: 'config/options/redis.yaml', opensearch: 'config/options/opensearch.yaml' },
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
        options_config_files: { apt: 'config/options/apt.yaml', mongodb: 'config/options/mongodb.yaml', mysql: 'config/options/mysql.yaml', redis: 'config/options/redis.yaml', opensearch: 'config/options/opensearch.yaml' },
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

    it 'raises ConfigError when a language declares file_extension without dependencies' do # rubocop:disable RSpec/ExampleLength
      linters_yaml = File.read("#{__dir__}/../../config/linters.yaml")
      languages_yaml = <<~YAML
        lonely_lang:
          short_name: lonely
          long_name: Lonely Language
          file_extension: lon
      YAML

      allow(File).to(receive(:exist?).and_return(true))
      allow(File).to(receive(:read).with(/linters\.yaml/).and_return(linters_yaml))
      allow(File).to(receive(:read).with(/languages\.yaml/).and_return(languages_yaml))

      config_app = config_test_class.new(mock_options)

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, %r{Language 'lonely_lang' in config/languages.yaml declares file_extension so it must also declare dependencies as a list}))
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

    # Validation entries are derived from the SERVICES registry, so each service's
    # options file must be checked for existence and schema.
    GHB::SERVICES.each do |service|
      it "validates the #{service} options file" do # rubocop:disable RSpec/ExampleLength
        missing_options = instance_double(
          GHB::Options,
          linters_config_file: 'config/linters.yaml',
          languages_config_file: 'config/languages.yaml',
          options_config_files: GHB::SERVICES.to_h { |name| [name, name == service ? "config/options/missing-#{name}.yaml" : "config/options/#{name}.yaml"] },
          gitignore_config_file: 'config/gitignore.yaml'
        )
        config_app = config_test_class.new(missing_options)

        expect { config_app.validate_config! }
          .to(raise_error(GHB::ConfigError, "Missing required #{service} options file: config/options/missing-#{service}.yaml"))
      end
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
        options_config_files: { apt: 'config/options/apt.yaml', mongodb: 'config/options/mongodb.yaml', mysql: 'config/options/mysql.yaml', redis: 'config/options/redis.yaml', opensearch: 'config/options/opensearch.yaml' },
        gitignore_config_file: 'config/gitignore.yaml'
      )
      config_app = config_test_class.new(bad_options)

      expect { config_app.validate_config! }
        .to(raise_error(GHB::ConfigError, 'Missing required linters config file: custom/path/linters.yaml'))
    end
  end

  describe 'dependencies git-config rewrite (CI-004)' do
    subject(:dependencies_commands) { described_class.new([]).instance_variable_get(:@dependencies_commands) }

    it 'scopes every GH_PAT insteadOf rewrite to the repository owner' do # rubocop:disable RSpec/MultipleExpectations
      expect(dependencies_commands).to(include('.insteadOf https://github.com/${{github.repository_owner}}/'))
      expect(dependencies_commands).to(include('.insteadOf git@github.com:${{github.repository_owner}}/'))
      expect(dependencies_commands).to(include('.insteadOf ssh://git@github.com:${{github.repository_owner}}/'))
    end

    it 'does not attach the PAT to unscoped github.com URLs' do
      expect(dependencies_commands).not_to(include(".insteadOf https://github.com/\n"))
    end
  end

  describe 'private internals' do
    let(:internals_class) do
      Class.new(described_class) do
        def initialize; end # rubocop:disable Lint/MissingSuper

        public :detect_default_branch, :validate_entries, :collect_required_status_checks
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

    describe '#collect_required_status_checks' do
      def checks_for
        workflow = GHB::Workflow.new('Build')
        yield(workflow)
        app.instance_variable_set(:@new_workflow, workflow)
        app.instance_variable_set(:@required_status_checks, [])
        app.collect_required_status_checks
        app.instance_variable_get(:@required_status_checks)
      end

      it 'adds the bare job name for a non-matrix job' do
        expect(checks_for { |w| w.do_job(:lint) { do_name('Ruby Linter') } })
          .to(eq(['Ruby Linter']))
      end

      it 'expands a matrix job into one check per matrix value' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: { os: %w[ubuntu-latest macos-26] } })
            end
          end

        expect(result).to(eq(['Ruby Unit Tests (ubuntu-latest)', 'Ruby Unit Tests (macos-26)']))
      end

      it 'joins every dimension of a multi-key matrix into a single check name' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: { os: %w[ubuntu-latest], ruby: %w[3.3 3.4] } })
            end
          end

        expect(result).to(eq(['Ruby Unit Tests (ubuntu-latest, 3.3)', 'Ruby Unit Tests (ubuntu-latest, 3.4)']))
      end

      it 'expands the cartesian product with the first axis varying slowest' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: { os: %w[ubuntu-latest macos-26], ruby: %w[3.3 3.4] } })
            end
          end

        expect(result).to(
          eq(
            [
              'Ruby Unit Tests (ubuntu-latest, 3.3)',
              'Ruby Unit Tests (ubuntu-latest, 3.4)',
              'Ruby Unit Tests (macos-26, 3.3)',
              'Ruby Unit Tests (macos-26, 3.4)'
            ]
          )
        )
      end

      it 'stringifies non-string matrix values the way GitHub does' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: { version: [20, 3.4], experimental: [true] } })
            end
          end

        expect(result).to(eq(['Ruby Unit Tests (20, true)', 'Ruby Unit Tests (3.4, true)']))
      end

      it 'accepts a matrix written with string keys' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ 'matrix' => { 'os' => %w[ubuntu-latest], 'ruby' => %w[3.3] } }) # rubocop:disable Style/StringHashKeys
            end
          end

        expect(result).to(eq(['Ruby Unit Tests (ubuntu-latest, 3.3)']))
      end

      it 'drops the combinations listed under exclude' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: { os: %w[ubuntu-latest macos-26], ruby: %w[3.3 3.4], exclude: [{ os: 'macos-26', ruby: '3.3' }] } })
            end
          end

        expect(result).to(
          eq(['Ruby Unit Tests (ubuntu-latest, 3.3)', 'Ruby Unit Tests (ubuntu-latest, 3.4)', 'Ruby Unit Tests (macos-26, 3.4)'])
        )
      end

      it 'merges an include row into every combination it matches' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: { os: %w[ubuntu-latest macos-26], include: [{ os: 'macos-26', arch: 'arm64' }] } })
            end
          end

        expect(result).to(eq(['Ruby Unit Tests (ubuntu-latest)', 'Ruby Unit Tests (macos-26, arm64)']))
      end

      it 'adds an include row that matches nothing as its own combination' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: { os: %w[ubuntu-latest], include: [{ os: 'windows-latest' }] } })
            end
          end

        expect(result).to(eq(['Ruby Unit Tests (ubuntu-latest)', 'Ruby Unit Tests (windows-latest)']))
      end

      it 'treats each row of an include-only matrix as its own combination' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: { include: [{ site: 'production', datacenter: 'site-a' }, { site: 'staging', datacenter: 'site-b' }] } })
            end
          end

        expect(result).to(eq(['Ruby Unit Tests (production, site-a)', 'Ruby Unit Tests (staging, site-b)']))
      end

      it "reproduces GitHub's documented include expansion" do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Build')
              do_strategy(
                {
                  matrix:
                    {
                      fruit: %w[apple pear],
                      animal: %w[cat dog],
                      include: [{ color: 'green' }, { color: 'pink', animal: 'cat' }, { fruit: 'apple', shape: 'circle' }, { fruit: 'banana' }, { fruit: 'banana', animal: 'cat' }]
                    }
                }
              )
            end
          end

        expect(result).to(
          eq(
            [
              'Build (apple, cat, pink, circle)',
              'Build (apple, dog, green, circle)',
              'Build (pear, cat, pink)',
              'Build (pear, dog, green)',
              'Build (banana)',
              'Build (banana, cat)'
            ]
          )
        )
      end

      it 'mixes bare and expanded names across jobs and preserves job order' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:variables) { do_name('Prepare Variables') }
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: { os: %w[ubuntu-latest macos-26] } })
            end
            w.do_job(:licenses) { do_name('Licenses Check') }
          end

        expect(result).to(eq(['Prepare Variables', 'Ruby Unit Tests (ubuntu-latest)', 'Ruby Unit Tests (macos-26)', 'Licenses Check']))
      end

      it 'returns an empty list when the workflow has no jobs' do
        expect(checks_for { |_w| nil }).to(eq([]))
      end

      it "treats a job whose strategy is the default empty hash as non-matrix (no '(value)' suffix)" do # rubocop:disable RSpec/MultipleExpectations
        result = checks_for { |w| w.do_job(:lint) { do_name('Ruby Linter') } }

        expect(result.first).to(eq('Ruby Linter'))
        expect(result.first).not_to(include('('))
      end

      it 'treats a job whose strategy is not a mapping as non-matrix' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:lint) { do_name('Ruby Linter') }
            w.jobs[:lint].strategy = 'fail-fast'
          end

        expect(result).to(eq(['Ruby Linter']))
      end

      it 'skips a nil job entry' do # rubocop:disable RSpec/ExampleLength
        result =
          checks_for do |w|
            w.do_job(:lint) { do_name('Ruby Linter') }
            w.jobs[:broken] = nil
          end

        expect(result).to(eq(['Ruby Linter']))
      end

      describe 'matrices that cannot be expanded statically' do # rubocop:disable RSpec/NestedGroups
        before { allow(app).to(receive(:warn)) }

        def checks_for_matrix(matrix)
          checks_for do |w|
            w.do_job(:tests) do
              do_name('Ruby Unit Tests')
              do_strategy({ matrix: matrix })
            end
          end
        end

        it 'warns and emits no check name for a matrix built from an expression' do # rubocop:disable RSpec/MultipleExpectations
          expect(checks_for_matrix('${{fromJson(needs.variables.outputs.matrix)}}')).to(eq([]))
          expect(app).to(have_received(:warn).with(/cannot expand the matrix of job 'Ruby Unit Tests'/))
        end

        it 'warns and emits no check name for an axis whose values come from an expression' do # rubocop:disable RSpec/MultipleExpectations
          expect(checks_for_matrix({ os: '${{fromJson(needs.variables.outputs.os)}}' })).to(eq([]))
          expect(app).to(have_received(:warn).with(/skipping it in the required status checks/))
        end

        it 'emits no check name for an axis with no values' do
          expect(checks_for_matrix({ os: [] })).to(eq([]))
        end

        it 'emits no check name for an axis holding non-scalar values' do
          expect(checks_for_matrix({ config: [{ os: 'ubuntu-latest' }] })).to(eq([]))
        end

        it 'emits no check name for an axis holding a nil value' do
          expect(checks_for_matrix({ os: [nil] })).to(eq([]))
        end

        it 'emits no check name for an empty matrix' do
          expect(checks_for_matrix({})).to(eq([]))
        end

        it 'emits no check name when the matrix keys are not names' do
          expect(checks_for_matrix({ 1 => %w[a b] })).to(eq([]))
        end

        it 'emits no check name when include is not a list' do
          expect(checks_for_matrix({ os: %w[ubuntu-latest], include: { os: 'macos-26' } })).to(eq([]))
        end

        it 'emits no check name when an include row is not a mapping' do
          expect(checks_for_matrix({ os: %w[ubuntu-latest], include: ['macos-26'] })).to(eq([]))
        end

        it 'emits no check name when an include row is empty' do
          expect(checks_for_matrix({ os: %w[ubuntu-latest], include: [{}] })).to(eq([]))
        end

        it 'emits no check name when an include row holds a non-scalar value' do
          expect(checks_for_matrix({ os: %w[ubuntu-latest], include: [{ os: 'ubuntu-latest', env: { 'DEBUG' => '1' } }] })).to(eq([])) # rubocop:disable Style/StringHashKeys
        end

        it 'emits no check name when an include row key is not a name' do
          expect(checks_for_matrix({ os: %w[ubuntu-latest], include: [{ 1 => 'macos-26' }] })).to(eq([]))
        end

        it 'emits no check name when exclude is not a list' do
          expect(checks_for_matrix({ os: %w[ubuntu-latest], exclude: 'macos-26' })).to(eq([]))
        end
      end
    end
  end
end
