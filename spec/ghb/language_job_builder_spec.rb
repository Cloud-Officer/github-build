# frozen_string_literal: true

RSpec.describe(GHB::LanguageJobBuilder) do # rubocop:disable RSpec/MultipleMemoizedHelpers
  let(:file_cache)            { {}                                                       }
  let(:submodules)            { []                                                       }
  let(:dependencies_commands) { +''                                                      }
  let(:old_workflow)          { GHB::Workflow.new('CI')                                  }
  let(:new_workflow)          { GHB::Workflow.new('CI')                                  }
  let(:unit_tests_conditions) { "(needs.variables.outputs.UNIT_TESTS == '1')"            }

  let(:mock_options) do
    instance_double(
      GHB::Options,
      only_dependabot: false,
      mono_repo: false,
      excluded_folders: [],
      skip_license_check: true,
      force_codedeploy_setup: false,
      strict_version_check: true,
      languages_config_file: 'config/languages.yaml',
      options_config_file_apt: 'config/options/apt.yaml',
      options_config_file_mongodb: 'config/options/mongodb.yaml',
      options_config_file_mysql: 'config/options/mysql.yaml',
      options_config_file_redis: 'config/options/redis.yaml',
      options_config_file_elasticsearch: 'config/options/elasticsearch.yaml'
    )
  end

  let(:builder) do
    described_class.new(
      options: mock_options,
      submodules: submodules,
      old_workflow: old_workflow,
      new_workflow: new_workflow,
      unit_tests_conditions: unit_tests_conditions,
      file_cache: file_cache,
      dependencies_commands: dependencies_commands
    )
  end

  let(:go_language_config) do
    {
      go: {
        short_name: 'go',
        long_name: 'Go',
        file_extension: 'go',
        version_files: ['.go-version'],
        setup_options: [{ name: 'go-version', value: '1.26.0' }],
        dependencies: [
          {
            dependency_file: 'go.mod',
            mongodb_dependency: 'mongodb',
            mysql_dependency: 'sql',
            redis_dependency: 'redis',
            elasticsearch_dependency: 'elasticsearch',
            package_manager_name: 'Go Modules',
            package_manager_default: 'go mod vendor',
            package_manager_update: 'go mod tidy',
            dependabot_ecosystem: 'gomod'
          }
        ],
        unit_test_framework_name: 'Testing',
        unit_test_framework_default: 'go test'
      }
    }
  end

  let(:go_language_yaml) { Psych.dump(go_language_config.deep_stringify_keys) }
  let(:apt_config_yaml)           { Psych.dump({ options: [{ name: 'apt-packages', value: nil }] }.deep_stringify_keys)                     }
  let(:mongodb_config_yaml)       { Psych.dump({ options: [{ name: 'mongodb-version', value: '8.0.0' }] }.deep_stringify_keys)              }
  let(:mysql_config_yaml)         { Psych.dump({ options: [{ name: 'mysql-version', value: '8.0' }] }.deep_stringify_keys)                  }
  let(:redis_config_yaml)         { Psych.dump({ options: [{ name: 'redis-version', value: '8.2' }] }.deep_stringify_keys)                  }
  let(:elasticsearch_config_yaml) { Psych.dump({ options: [{ name: 'elasticsearch-version', value: '7.10' }] }.deep_stringify_keys)         }

  let(:swift_only_config) do
    {
      swift: {
        short_name: 'swift',
        long_name: 'Swift',
        dependencies: [{ dependency_file: 'Gemfile', dependabot_ecosystem: 'bundler' }]
      }
    }
  end

  let(:swift_language_yaml) { Psych.dump(swift_only_config.deep_stringify_keys) }

  describe '#build' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    it 'returns early when only_dependabot is true' do # rubocop:disable RSpec/ExampleLength
      dependabot_options = instance_double(GHB::Options, only_dependabot: true)
      dependabot_builder = described_class.new(
        options: dependabot_options,
        submodules: [],
        old_workflow: old_workflow,
        new_workflow: new_workflow,
        unit_tests_conditions: unit_tests_conditions,
        file_cache: {},
        dependencies_commands: +''
      )

      allow(dependabot_builder).to(receive(:cached_file_read))

      dependabot_builder.build

      expect(dependabot_builder).not_to(have_received(:cached_file_read))
    end

    it 'skips languages with nil file_extension' do
      stub_config_file_reads(swift_language_yaml)

      builder.build

      expect(new_workflow.jobs).to(be_empty)
    end

    it 'skips language when no dependency file exists' do
      stub_config_file_reads(go_language_yaml)

      allow(builder).to(receive(:find_files_matching).and_return(['./main.go']))
      allow(File).to(receive(:file?).with('go.mod').and_return(false))

      builder.build

      expect(new_workflow.jobs).to(be_empty)
    end

    it 'detects language and adds unit test job when files and dependencies exist' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      stub_config_file_reads(go_language_yaml)
      stub_go_language_detection

      builder.build

      expect(new_workflow.jobs).to(have_key(:go_unit_tests))

      job = new_workflow.jobs[:go_unit_tests]
      expect(job.name).to(eq('Go Unit Tests'))
      expect(job.needs).to(eq(%w[variables]))

      step_names = job.steps.map(&:name)
      expect(step_names).to(include('Setup'))
      expect(step_names).to(include('Go Modules'))
      expect(step_names).to(include('Testing'))
    end

    it 'sets up mongodb options when dependency file contains mongodb string' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      stub_config_file_reads(go_language_yaml)
      stub_go_language_detection
      allow(builder).to(receive(:file_contains?).with('go.mod', 'mongodb').and_return(true))

      builder.build

      expect(new_workflow.jobs).to(have_key(:go_unit_tests))
      expect(new_workflow.env).to(have_key(:'MONGODB-VERSION'))
    end

    it 'sets up mysql options when dependency file contains mysql string' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      stub_config_file_reads(go_language_yaml)
      stub_go_language_detection
      allow(builder).to(receive(:file_contains?).with('go.mod', 'sql').and_return(true))

      builder.build

      expect(new_workflow.jobs).to(have_key(:go_unit_tests))
      expect(new_workflow.env).to(have_key(:'MYSQL-VERSION'))
    end

    it 'sets up redis options when dependency file contains redis string' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      stub_config_file_reads(go_language_yaml)
      stub_go_language_detection
      allow(builder).to(receive(:file_contains?).with('go.mod', 'redis').and_return(true))

      builder.build

      expect(new_workflow.jobs).to(have_key(:go_unit_tests))
      expect(new_workflow.env).to(have_key(:'REDIS-VERSION'))
    end

    it 'sets up elasticsearch options when dependency file contains elasticsearch string' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      stub_config_file_reads(go_language_yaml)
      stub_go_language_detection
      allow(builder).to(receive(:file_contains?).with('go.mod', 'elasticsearch').and_return(true))

      builder.build

      expect(new_workflow.jobs).to(have_key(:go_unit_tests))
      expect(new_workflow.env).to(have_key(:'ELASTICSEARCH-VERSION'))
    end

    it 'uses version file when it exists instead of setup option value' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      stub_config_file_reads(go_language_yaml)

      allow(builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
      allow(File).to(receive(:file?).with('go.mod').and_return(true))
      allow(File).to(receive(:exist?).with('.go-version').and_return(true))
      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))
      allow(File).to(receive(:read).with('.go-version').and_return("1.26.0\n"))

      builder.build

      expect(new_workflow.jobs).to(have_key(:go_unit_tests))
      expect(new_workflow.env).not_to(have_key(:'GO-VERSION'))
    end

    it 'does not create any jobs when no language files are found' do
      stub_config_file_reads(go_language_yaml)

      allow(builder).to(receive(:find_files_matching).and_return([]))

      builder.build

      expect(new_workflow.jobs).to(be_empty)
    end

    it 'handles nil config YAML gracefully' do
      nil_yaml = "---\n"

      allow(builder).to(receive(:cached_file_read).and_return(nil_yaml))

      builder.build

      expect(new_workflow.jobs).to(be_empty)
    end

    it 'appends package_manager_update to dependencies_commands' do
      stub_config_file_reads(go_language_yaml)
      stub_go_language_detection

      builder.build

      expect(builder.dependencies_commands).to(include('go mod tidy'))
    end

    it 'includes additional_checks in the if condition for swift language' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      swift_full_config = {
        swift: {
          short_name: 'swift',
          long_name: 'Swift',
          file_extension: 'swift',
          version_files: nil,
          setup_options: nil,
          dependencies: [
            {
              dependency_file: 'Package.swift',
              package_manager_name: 'Swift Package Manager',
              package_manager_default: 'swift build',
              package_manager_update: nil,
              dependabot_ecosystem: 'swift'
            }
          ],
          unit_test_framework_name: 'XCTest',
          unit_test_framework_default: 'swift test'
        }
      }

      swift_full_yaml = Psych.dump(swift_full_config.deep_stringify_keys)
      stub_config_file_reads(swift_full_yaml)

      allow(builder).to(receive_messages(find_files_matching: ['./Sources/main.swift'], file_contains?: false))
      allow(File).to(receive(:file?).with('Package.swift').and_return(true))
      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))
      allow($stdout).to(receive(:puts))

      builder.build

      expect(new_workflow.jobs).to(have_key(:swift_unit_tests))

      job = new_workflow.jobs[:swift_unit_tests]
      expect(job.if).to(include('DEPLOY_ON_BETA'))
      expect(job.if).to(include('DEPLOY_ON_RC'))
      expect(job.if).to(include('DEPLOY_ON_PROD'))
      expect(job.if).to(include('DEPLOY_MACOS'))
      expect(job.if).to(include('DEPLOY_TVOS'))
    end

    it 'prints warning but does not exit when version file mismatches and strict_version_check is false' do # rubocop:disable RSpec/ExampleLength
      non_strict_options = instance_double(
        GHB::Options,
        only_dependabot: false,
        mono_repo: false,
        excluded_folders: [],
        skip_license_check: true,
        force_codedeploy_setup: false,
        strict_version_check: false,
        languages_config_file: 'config/languages.yaml',
        options_config_file_apt: 'config/options/apt.yaml',
        options_config_file_mongodb: 'config/options/mongodb.yaml',
        options_config_file_mysql: 'config/options/mysql.yaml',
        options_config_file_redis: 'config/options/redis.yaml',
        options_config_file_elasticsearch: 'config/options/elasticsearch.yaml'
      )

      non_strict_builder = described_class.new(
        options: non_strict_options,
        submodules: submodules,
        old_workflow: old_workflow,
        new_workflow: new_workflow,
        unit_tests_conditions: unit_tests_conditions,
        file_cache: {},
        dependencies_commands: +''
      )

      stub_non_strict_config_file_reads(non_strict_builder, go_language_yaml)

      allow(non_strict_builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
      allow(File).to(receive(:file?).with('go.mod').and_return(true))
      allow(File).to(receive(:exist?).with('.go-version').and_return(true))
      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))
      allow(File).to(receive(:read).with('.go-version').and_return("1.25.0\n"))
      allow($stdout).to(receive(:puts))

      non_strict_builder.build

      expect(new_workflow.jobs).to(have_key(:go_unit_tests))
    end

    it 'populates code_deploy_pre_steps when force_codedeploy_setup is true' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      codedeploy_options = instance_double(
        GHB::Options,
        only_dependabot: false,
        mono_repo: false,
        excluded_folders: [],
        skip_license_check: true,
        force_codedeploy_setup: true,
        strict_version_check: true,
        languages_config_file: 'config/languages.yaml',
        options_config_file_apt: 'config/options/apt.yaml',
        options_config_file_mongodb: 'config/options/mongodb.yaml',
        options_config_file_mysql: 'config/options/mysql.yaml',
        options_config_file_redis: 'config/options/redis.yaml',
        options_config_file_elasticsearch: 'config/options/elasticsearch.yaml'
      )

      codedeploy_builder = described_class.new(
        options: codedeploy_options,
        submodules: submodules,
        old_workflow: old_workflow,
        new_workflow: new_workflow,
        unit_tests_conditions: unit_tests_conditions,
        file_cache: {},
        dependencies_commands: +''
      )

      stub_non_strict_config_file_reads(codedeploy_builder, go_language_yaml)

      allow(codedeploy_builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
      allow(File).to(receive(:file?).with('go.mod').and_return(true))
      allow(File).to(receive(:exist?).with('.go-version').and_return(false))
      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))
      allow($stdout).to(receive(:puts))

      codedeploy_builder.build

      expect(new_workflow.jobs).to(have_key(:go_unit_tests))
      expect(codedeploy_builder.code_deploy_pre_steps).not_to(be_empty)
    end

    it 'prints warning when existing env value differs from option value' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      non_strict_options = instance_double(
        GHB::Options,
        only_dependabot: false,
        mono_repo: false,
        excluded_folders: [],
        skip_license_check: true,
        force_codedeploy_setup: false,
        strict_version_check: false,
        languages_config_file: 'config/languages.yaml',
        options_config_file_apt: 'config/options/apt.yaml',
        options_config_file_mongodb: 'config/options/mongodb.yaml',
        options_config_file_mysql: 'config/options/mysql.yaml',
        options_config_file_redis: 'config/options/redis.yaml',
        options_config_file_elasticsearch: 'config/options/elasticsearch.yaml'
      )

      env_mismatch_workflow = GHB::Workflow.new('CI')
      env_mismatch_workflow.env[:'MONGODB-VERSION'] = '7.0'

      env_mismatch_builder = described_class.new(
        options: non_strict_options,
        submodules: submodules,
        old_workflow: old_workflow,
        new_workflow: env_mismatch_workflow,
        unit_tests_conditions: unit_tests_conditions,
        file_cache: {},
        dependencies_commands: +''
      )

      stub_non_strict_config_file_reads(env_mismatch_builder, go_language_yaml)

      allow(env_mismatch_builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
      allow(env_mismatch_builder).to(receive(:file_contains?).with('go.mod', 'mongodb').and_return(true))
      allow(File).to(receive(:file?).with('go.mod').and_return(true))
      allow(File).to(receive(:exist?).with('.go-version').and_return(false))
      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))
      allow($stdout).to(receive(:puts))

      env_mismatch_builder.build

      expect(env_mismatch_workflow.jobs).to(have_key(:go_unit_tests))
      expect(env_mismatch_workflow.env[:'MONGODB-VERSION']).to(eq('7.0'))
    end

    it 'exits with error when strict_version_check is true and version file mismatches' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      stub_config_file_reads(go_language_yaml)

      allow(builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
      allow(File).to(receive(:file?).with('go.mod').and_return(true))
      allow(File).to(receive(:exist?).with('.go-version').and_return(true))
      allow(File).to(receive(:read).with('.go-version').and_return("1.25.0\n"))
      allow($stdout).to(receive(:puts))

      expect { builder.build }
        .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(GHB::Status::ERROR_EXIT_CODE)) })
    end

    it 'exits with error when strict_version_check is true and env VERSION value mismatches' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      version_mismatch_workflow = GHB::Workflow.new('CI')
      version_mismatch_workflow.env[:'MONGODB-VERSION'] = '7.0'

      version_mismatch_builder = described_class.new(
        options: mock_options,
        submodules: submodules,
        old_workflow: old_workflow,
        new_workflow: version_mismatch_workflow,
        unit_tests_conditions: unit_tests_conditions,
        file_cache: {},
        dependencies_commands: +''
      )

      stub_non_strict_config_file_reads(version_mismatch_builder, go_language_yaml)

      allow(version_mismatch_builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
      allow(version_mismatch_builder).to(receive(:file_contains?).with('go.mod', 'mongodb').and_return(true))
      allow(File).to(receive(:file?).with('go.mod').and_return(true))
      allow(File).to(receive(:exist?).with('.go-version').and_return(false))
      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))
      allow($stdout).to(receive(:puts))

      expect { version_mismatch_builder.build }
        .to(raise_error(SystemExit) { |e| expect(e.status).to(eq(GHB::Status::ERROR_EXIT_CODE)) })
    end

    it 'adds Licenses step when Podfile.lock exists and skip_license_check is false' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      license_options = instance_double(
        GHB::Options,
        only_dependabot: false,
        mono_repo: false,
        excluded_folders: [],
        skip_license_check: false,
        force_codedeploy_setup: false,
        strict_version_check: true,
        languages_config_file: 'config/languages.yaml',
        options_config_file_apt: 'config/options/apt.yaml',
        options_config_file_mongodb: 'config/options/mongodb.yaml',
        options_config_file_mysql: 'config/options/mysql.yaml',
        options_config_file_redis: 'config/options/redis.yaml',
        options_config_file_elasticsearch: 'config/options/elasticsearch.yaml'
      )

      license_builder = described_class.new(
        options: license_options,
        submodules: submodules,
        old_workflow: old_workflow,
        new_workflow: new_workflow,
        unit_tests_conditions: unit_tests_conditions,
        file_cache: {},
        dependencies_commands: +''
      )

      stub_non_strict_config_file_reads(license_builder, go_language_yaml)

      allow(license_builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
      allow(File).to(receive(:file?).with('go.mod').and_return(true))
      allow(File).to(receive(:exist?).with('.go-version').and_return(false))
      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(true))

      license_builder.build

      job = new_workflow.jobs[:go_unit_tests]
      step_names = job.steps.map(&:name)
      expect(step_names).to(include('Licenses'))

      licenses_step = job.steps.find { |s| s.name == 'Licenses' }
      expect(licenses_step.uses).to(include('soup'))
      expect(licenses_step.with).to(have_key(:'ssh-key'))
    end

    it 'detects mono_repo subdirectory dependencies and adds per-subdir steps' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      mono_options = instance_double(
        GHB::Options,
        only_dependabot: false,
        mono_repo: true,
        excluded_folders: [],
        skip_license_check: true,
        force_codedeploy_setup: false,
        strict_version_check: true,
        languages_config_file: 'config/languages.yaml',
        options_config_file_apt: 'config/options/apt.yaml',
        options_config_file_mongodb: 'config/options/mongodb.yaml',
        options_config_file_mysql: 'config/options/mysql.yaml',
        options_config_file_redis: 'config/options/redis.yaml',
        options_config_file_elasticsearch: 'config/options/elasticsearch.yaml'
      )

      mono_builder = described_class.new(
        options: mono_options,
        submodules: submodules,
        old_workflow: old_workflow,
        new_workflow: new_workflow,
        unit_tests_conditions: unit_tests_conditions,
        file_cache: {},
        dependencies_commands: +''
      )

      stub_non_strict_config_file_reads(mono_builder, go_language_yaml)

      allow(mono_builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
      allow(File).to(receive(:file?).with('go.mod').and_return(false))
      allow(File).to(receive(:exist?).with('.go-version').and_return(false))
      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))
      allow(Dir).to(receive(:glob).with('*/go.mod').and_return(['svc-a/go.mod']))

      mono_builder.build

      job = new_workflow.jobs[:go_unit_tests]
      step_names = job.steps.map(&:name)
      expect(step_names).to(include('Go Modules (svc-a)'))
      expect(step_names).to(include('Testing (svc-a)'))
    end

    it 'detects services in mono_repo subdirectory dependency files' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      mono_options = instance_double(
        GHB::Options,
        only_dependabot: false,
        mono_repo: true,
        excluded_folders: [],
        skip_license_check: true,
        force_codedeploy_setup: false,
        strict_version_check: true,
        languages_config_file: 'config/languages.yaml',
        options_config_file_apt: 'config/options/apt.yaml',
        options_config_file_mongodb: 'config/options/mongodb.yaml',
        options_config_file_mysql: 'config/options/mysql.yaml',
        options_config_file_redis: 'config/options/redis.yaml',
        options_config_file_elasticsearch: 'config/options/elasticsearch.yaml'
      )

      mono_svc_builder = described_class.new(
        options: mono_options,
        submodules: submodules,
        old_workflow: old_workflow,
        new_workflow: new_workflow,
        unit_tests_conditions: unit_tests_conditions,
        file_cache: {},
        dependencies_commands: +''
      )

      stub_non_strict_config_file_reads(mono_svc_builder, go_language_yaml)

      allow(mono_svc_builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
      allow(mono_svc_builder).to(receive(:file_contains?).with('svc-a/go.mod', 'mongodb').and_return(true))
      allow(File).to(receive(:file?).with('go.mod').and_return(false))
      allow(File).to(receive(:exist?).with('.go-version').and_return(false))
      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))
      allow(Dir).to(receive(:glob).with('*/go.mod').and_return(['svc-a/go.mod']))

      mono_svc_builder.build

      expect(new_workflow.jobs).to(have_key(:go_unit_tests))
      expect(new_workflow.env).to(have_key(:'MONGODB-VERSION'))
    end
  end

  private

  def stub_config_file_reads(languages_yaml)
    allow(builder).to(receive(:cached_file_read)) do |path|
      case path
      when /languages\.yaml/ then languages_yaml
      when /apt\.yaml/ then apt_config_yaml
      when /mongodb\.yaml/ then mongodb_config_yaml
      when /mysql\.yaml/ then mysql_config_yaml
      when /redis\.yaml/ then redis_config_yaml
      when /elasticsearch\.yaml/ then elasticsearch_config_yaml
      else raise("Unexpected config file read: #{path}")
      end
    end
  end

  def stub_go_language_detection
    allow(builder).to(receive_messages(find_files_matching: ['./main.go'], file_contains?: false))
    allow(File).to(receive(:file?).with('go.mod').and_return(true))
    allow(File).to(receive(:exist?).with('.go-version').and_return(false))
    allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))
  end

  def stub_non_strict_config_file_reads(target_builder, languages_yaml)
    allow(target_builder).to(receive(:cached_file_read)) do |path|
      case path
      when /languages\.yaml/ then languages_yaml
      when /apt\.yaml/ then apt_config_yaml
      when /mongodb\.yaml/ then mongodb_config_yaml
      when /mysql\.yaml/ then mysql_config_yaml
      when /redis\.yaml/ then redis_config_yaml
      when /elasticsearch\.yaml/ then elasticsearch_config_yaml
      else raise("Unexpected config file read: #{path}")
      end
    end
  end
end
