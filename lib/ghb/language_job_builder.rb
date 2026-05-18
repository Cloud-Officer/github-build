# frozen_string_literal: true

require_relative 'file_scanner'

module GHB
  # Detects programming languages based on file extensions and adds unit test jobs to the workflow.
  class LanguageJobBuilder
    include FileScanner

    # Deploy flags that extend the Swift unit-test `if:` so the job also runs on deploy triggers.
    SWIFT_DEPLOY_CHECK_FLAGS = %w[DEPLOY_ON_BETA DEPLOY_ON_RC DEPLOY_ON_PROD DEPLOY_MACOS DEPLOY_TVOS].freeze
    # Languages whose dependency steps must also be staged as CodeDeploy pre-steps.
    CODEDEPLOY_SETUP_LANGUAGES = %w[go php].freeze
    private_constant :SWIFT_DEPLOY_CHECK_FLAGS, :CODEDEPLOY_SETUP_LANGUAGES

    attr_reader :code_deploy_pre_steps, :dependencies_steps, :dependencies_commands

    def initialize(context:, unit_tests_conditions:, dependencies_commands:)
      @options = context.options
      @submodules = context.submodules
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
      @unit_tests_conditions = unit_tests_conditions
      @file_cache = context.file_cache
      @code_deploy_pre_steps = []
      @dependencies_steps = []
      @dependencies_commands = dependencies_commands
      @dependencies_commands_additions = []
    end

    def build
      return if @options.only_dependabot

      puts('    Detecting languages...')
      languages = Psych.safe_load(cached_file_read("#{__dir__}/../../#{@options.languages_config_file}"))&.deep_symbolize_keys
      options_apt = Psych.safe_load(cached_file_read("#{__dir__}/../../#{@options.options_config_file_apt}"))&.deep_symbolize_keys&.[](:options)
      options_mongodb = Psych.safe_load(cached_file_read("#{__dir__}/../../#{@options.options_config_file_mongodb}"))&.deep_symbolize_keys&.[](:options)
      options_mysql = Psych.safe_load(cached_file_read("#{__dir__}/../../#{@options.options_config_file_mysql}"))&.deep_symbolize_keys&.[](:options)
      options_redis = Psych.safe_load(cached_file_read("#{__dir__}/../../#{@options.options_config_file_redis}"))&.deep_symbolize_keys&.[](:options)
      options_elasticsearch = Psych.safe_load(cached_file_read("#{__dir__}/../../#{@options.options_config_file_elasticsearch}"))&.deep_symbolize_keys&.[](:options)

      service_options = {
        apt: options_apt,
        mongodb: options_mongodb,
        mysql: options_mysql,
        redis: options_redis,
        elasticsearch: options_elasticsearch
      }

      languages&.each_value do |language|
        next unless language.is_a?(Hash)

        detect_language(language, service_options)
      end

      @dependencies_commands += @dependencies_commands_additions
                                .map { |cmd| "#{cmd}\n" }
                                .join
    end

    private

    def detect_language(language, service_options)
      return if language[:file_extension].nil?

      language_detected = false
      mongodb = false
      mysql = false
      redis = false
      elasticsearch = false
      setup_options = {}

      # Pure Ruby file finding - avoids shell injection (SEC-002)
      excluded_paths = @options.excluded_folders + @submodules
      pattern = Regexp.new(".*\\.(#{language[:file_extension]})$")
      matches = find_files_matching('.', pattern, excluded_paths)

      if matches.any?
        dependency_detected = false
        mono_dependency_locations = []

        language[:dependencies].each do |dependency|
          dependency_detected = true if File.file?(dependency[:dependency_file])

          next unless @options.mono_repo

          Dir.glob("*/#{dependency[:dependency_file]}").each do |found|
            mono_dependency_locations << { dependency: dependency, subdir: File.dirname(found), path: found }
          end
        end

        dependency_detected = true if mono_dependency_locations.any?

        return unless dependency_detected

        language_detected = true

        # Pure Ruby dependency checking - avoids shell injection (SEC-002)
        language[:dependencies].each do |dependency|
          dep_file = dependency[:dependency_file]
          mongodb = true if dependency[:mongodb_dependency] && file_contains?(dep_file, dependency[:mongodb_dependency])
          mysql = true if dependency[:mysql_dependency] && file_contains?(dep_file, dependency[:mysql_dependency])
          redis = true if dependency[:redis_dependency] && file_contains?(dep_file, dependency[:redis_dependency])
          elasticsearch = true if dependency[:elasticsearch_dependency] && file_contains?(dep_file, dependency[:elasticsearch_dependency])
        end

        # Also check subdirectory dependency files for service detection
        mono_dependency_locations.each do |loc|
          dep = loc[:dependency]
          path = loc[:path]
          mongodb = true if dep[:mongodb_dependency] && file_contains?(path, dep[:mongodb_dependency])
          mysql = true if dep[:mysql_dependency] && file_contains?(path, dep[:mysql_dependency])
          redis = true if dep[:redis_dependency] && file_contains?(path, dep[:redis_dependency])
          elasticsearch = true if dep[:elasticsearch_dependency] && file_contains?(path, dep[:elasticsearch_dependency])
        end
      end

      return unless language_detected

      puts("        Enabling #{language[:long_name]}...")
      version_file = language[:version_files]&.find { |f| File.exist?(f) }
      add_setup_options(setup_options, language[:setup_options], version_file)
      add_setup_options(setup_options, service_options[:apt])
      add_setup_options(setup_options, service_options[:mongodb]) if mongodb
      add_setup_options(setup_options, service_options[:mysql]) if mysql
      add_setup_options(setup_options, service_options[:redis]) if redis
      add_setup_options(setup_options, service_options[:elasticsearch]) if elasticsearch

      add_language_job(language, setup_options, version_file, mono_dependency_locations)
    end

    # True for languages that get the extended Swift deploy `if:` checks.
    def extra_deploy_checks?(language)
      language[:short_name] == 'swift'
    end

    # Swift + Xcode Cloud: collect dependency info but drop the unit-test job.
    def xcode_cloud_unit_tests?(language)
      language[:short_name] == 'swift' && Dir.exist?('ci_scripts')
    end

    # Whether this language's dependency steps must also be staged as CodeDeploy pre-steps.
    def needs_codedeploy_setup?(language)
      CODEDEPLOY_SETUP_LANGUAGES.include?(language[:short_name]) || @options.force_codedeploy_setup
    end

    # The extra `|| (...)` deploy checks appended to the Swift unit-test `if:`.
    def additional_unit_test_checks(language)
      return '' unless extra_deploy_checks?(language)

      checks = SWIFT_DEPLOY_CHECK_FLAGS.map { |flag| "(needs.variables.outputs.#{flag} == '1')" }

      " || #{checks.join(' || ')}"
    end

    def add_language_job(language, setup_options, version_file, mono_dependency_locations)
      additional_checks = additional_unit_test_checks(language)
      skip_license_check = @options.skip_license_check
      needs_codedeploy_setup = needs_codedeploy_setup?(language)
      old_workflow = @old_workflow
      unit_tests_conditions = @unit_tests_conditions
      # Swift with Xcode Cloud (ci_scripts): build the job to collect dependency info, then delete it below.
      skip_unit_test_job = xcode_cloud_unit_tests?(language)
      builder = self

      @new_workflow.do_job(:"#{language[:short_name]}_unit_tests") do
        copy_properties(old_workflow.jobs[id])
        do_name("#{language[:long_name]} Unit Tests")
        do_runs_on(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.runs_on || language[:'runs-on'] || DEFAULT_UBUNTU_VERSION)
        do_needs(%w[variables])
        do_if("${{#{unit_tests_conditions}#{additional_checks}}}")

        builder.__send__(:build_setup_step, self, language, version_file, setup_options, needs_codedeploy_setup)
        dependency_detected = builder.__send__(:build_dependency_steps, self, language, needs_codedeploy_setup)
        builder.__send__(:build_mono_dependency_steps, self, language, mono_dependency_locations)

        next unless dependency_detected || mono_dependency_locations.any?

        builder.__send__(:build_licenses_step, self, language) if File.exist?('Podfile.lock') && skip_license_check == false
      end

      # Remove the unit test job from the workflow when Xcode Cloud handles tests,
      # but dependency info (dependencies_steps, dependencies_commands) was still collected above
      return unless skip_unit_test_job

      @new_workflow.jobs.delete(:"#{language[:short_name]}_unit_tests")
      puts("        Skipping #{language[:long_name]} Unit Tests job (Xcode Cloud handles tests via ci_scripts)")
    end

    def build_setup_step(job, language, version_file, setup_options, needs_codedeploy_setup)
      old_workflow = @old_workflow
      code_deploy_pre_steps = @code_deploy_pre_steps
      dependencies_steps = @dependencies_steps

      job.do_step('Setup') do
        copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name))
        do_uses("cloud-officer/ci-actions/setup@#{CI_ACTIONS_VERSION}")

        # Remove version parameter from with if version file exists (version file takes precedence)
        if version_file
          version_option_key = (version_file == '.nvmrc' ? 'node-version' : version_file.delete_prefix('.')).to_sym
          with.delete(version_option_key)
        end

        if with.empty?
          do_with(
            {
              'ssh-key': '${{secrets.SSH_KEY}}',
              'github-token': '${{secrets.GH_PAT}}',
              'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
              'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
              'aws-region': '${{secrets.AWS_DEFAULT_REGION}}'
            }.merge(setup_options)
          )
        end

        with[:'github-token'] = '${{secrets.GH_PAT}}'

        code_deploy_pre_steps << duplicate(self) if needs_codedeploy_setup
        dependencies_steps << duplicate(self)
      end
    end

    def build_dependency_steps(job, language, needs_codedeploy_setup)
      old_workflow = @old_workflow
      code_deploy_pre_steps = @code_deploy_pre_steps
      dependencies_commands_additions = @dependencies_commands_additions
      dependency_detected = false

      language[:dependencies].each do |dependency|
        next unless File.file?(dependency[:dependency_file])

        dependency_detected = true

        job.do_step(dependency[:package_manager_name]) do
          copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name))
          do_shell('bash')
          do_run(dependency[:package_manager_default]) if run.nil?
          env['GITHUB_TOKEN'] = '${{secrets.GH_PAT}}'
          code_deploy_pre_steps << duplicate(self) if needs_codedeploy_setup
          dependencies_commands_additions << dependency[:package_manager_update] if dependency[:package_manager_update]
        end
      end

      if dependency_detected
        job.do_step(language[:unit_test_framework_name]) do
          copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name))
          do_shell('bash')
          do_run(language[:unit_test_framework_default]) if run.nil?
          env['GITHUB_TOKEN'] = '${{secrets.GH_PAT}}'
        end
      end

      dependency_detected
    end

    def build_mono_dependency_steps(job, language, mono_dependency_locations)
      old_workflow = @old_workflow
      dependencies_commands_additions = @dependencies_commands_additions

      mono_dependency_locations.each do |loc|
        dep = loc[:dependency]
        subdir = loc[:subdir]

        job.do_step("#{dep[:package_manager_name]} (#{subdir})") do
          copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name))
          do_shell('bash')
          do_run("cd #{subdir} && #{dep[:package_manager_default]}") if run.nil?
          env['GITHUB_TOKEN'] = '${{secrets.GH_PAT}}'
          dependencies_commands_additions << dep[:package_manager_update] if dep[:package_manager_update]
        end

        job.do_step("#{language[:unit_test_framework_name]} (#{subdir})") do
          copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name))
          do_shell('bash')
          do_run("cd #{subdir} && #{language[:unit_test_framework_default]}") if run.nil?
          env['GITHUB_TOKEN'] = '${{secrets.GH_PAT}}'
        end
      end
    end

    def build_licenses_step(job, language)
      old_workflow = @old_workflow

      job.do_step('Licenses') do
        copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name))
        do_uses("cloud-officer/ci-actions/soup@#{CI_ACTIONS_VERSION}")

        if with.empty?
          do_with(
            {
              'ssh-key': '${{secrets.SSH_KEY}}',
              'github-token': '${{secrets.GH_PAT}}',
              parameters: '--no_prompt'
            }
          )
        end
      end
    end

    def add_setup_options(setup_options, options, version_file = nil)
      # Derive the version option name from the version file (e.g., .ruby-version -> ruby-version)
      # Special case for .nvmrc -> node-version
      version_option_name = nil

      if version_file
        version_option_name = version_file == '.nvmrc' ? 'node-version' : version_file.delete_prefix('.')
      end

      options&.each do |option|
        # If a version file exists and this option matches the version file,
        # skip setting it so the ci-actions setup will use the version file instead
        if version_option_name && option[:name] == version_option_name
          option_value = option[:value]

          if option_value
            file_version = File.read(version_file).strip

            if file_version != option_value.to_s
              puts("\e[31m\n#{'*' * 80}")
              puts("WARNING: Value mismatch for #{option[:name].upcase}")
              puts("Version file (#{version_file}): #{file_version}")
              puts("Recommended value: #{option_value}")

              if @options.strict_version_check
                puts("Updating #{version_file} to #{option_value}.")
                puts("#{'*' * 80}\n\e[0m")
                File.write(version_file, "#{option_value}\n")
              else
                puts('Using version file.')
                puts("#{'*' * 80}\n\e[0m")
              end
            end
          end

          @new_workflow.env.delete(option[:name].upcase.to_sym)
          next
        end

        existing_value = @new_workflow.env[option[:name].upcase.to_sym]
        option_value = option[:value]
        value = existing_value || option_value

        next unless value

        if existing_value && option_value && existing_value.to_s != option_value.to_s
          puts("\e[31m\n#{'*' * 80}")
          puts("WARNING: Value mismatch for #{option[:name].upcase}")
          puts("Existing value: #{existing_value}")
          puts("Recommended value: #{option_value}")

          if @options.strict_version_check && option[:name].upcase.include?('VERSION')
            puts("Updating #{option[:name].upcase} to #{option_value}.")
            @new_workflow.env[option[:name].upcase.to_sym] = option_value
          else
            puts('Using existing value.')
          end

          puts("#{'*' * 80}\n\e[0m")
        end

        @new_workflow.env[option[:name].upcase.to_sym] = value unless @new_workflow.env[option[:name].upcase.to_sym]
        setup_options[option[:name]] = "${{env.#{option[:name].upcase}}}"
      end
    end
  end
end
