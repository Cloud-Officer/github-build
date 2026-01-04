# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'duplicate'
require 'find'
require 'httparty'
require 'json'
require 'open3'
require 'psych'
require 'rbconfig'

require_relative 'options'
require_relative 'status'
require_relative 'workflow/workflow'

module GHB
  # Represents an instance of an application. This is the entry point for all invocations from the command line.
  class Application
    def initialize(argv)
      @code_deploy_pre_steps = []
      @exit_code = Status::SUCCESS_EXIT_CODE
      @dependencies_steps = []
      @cron_workflow = Workflow.new('Cron Dependencies')
      @dockerhub_workflow = Workflow.new('Publish Docker image')
      @new_workflow = Workflow.new('Build')
      @old_workflow = Workflow.new('Build')
      @options = configure_options(argv)
      @required_status_checks = []
      @submodules = ''
      @unit_tests_conditions = nil
      @dependencies_commands =
        <<~BASH
          git config --global --add url."https://${{secrets.GH_PAT}}:x-oauth-basic@github.com/".insteadOf ssh://git@github.com:
          git config --global --add url."https://${{secrets.GH_PAT}}:x-oauth-basic@github.com/".insteadOf https://github.com/
          git config --global --add url."https://${{secrets.GH_PAT}}:x-oauth-basic@github.com/".insteadOf git@github.com:

        BASH
    end

    def execute
      puts('Generating build file...')
      workflow_read
      workflow_set_defaults
      workflow_job_prepare_variables
      workflow_job_detect_linters
      workflow_job_licenses_check
      workflow_job_detect_languages

      @new_workflow.jobs.each_value do |job|
        if job&.strategy&.[](:matrix)
          job.strategy[:matrix].each_value do |values|
            values.each do |value|
              @required_status_checks << "#{job.name} (#{value})"
            end
          end
        else
          @required_status_checks << job.name
        end
      end

      workflow_job_code_deploy
      workflow_job_aws_commands
      workflow_job_publish_status
      workflow_write
      save_dependabot_config
      save_dockerhub_config
      update_gitignore
      check_repository_settings
      @exit_code
    end

    private

    def configure_options(argv)
      Options.new(argv).parse
    rescue OptionParser::InvalidOption => e
      puts("Error: #{e}")
      exit(Status::ERROR_EXIT_CODE)
    end

    def workflow_read
      return unless File.exist?(@options.build_file)

      puts("Reading current build file #{@options.build_file}...")
      @old_workflow.read(@options.build_file)
    end

    def workflow_set_defaults
      @new_workflow.name =
        if @old_workflow.name.nil?
          'Build'
        else
          @old_workflow.name
        end

      @new_workflow.on =
        {
          pull_request:
            {
              types: %w[opened edited reopened synchronize]
            },
          push:
            {
              branches: %w[master [0-9]* dependabot/**],
              tags: %w[**]
            }
        }

      @new_workflow.run_name = @old_workflow.run_name unless @old_workflow.run_name.nil?
      @new_workflow.permissions =
        if @old_workflow.permissions.is_a?(Hash) && @old_workflow.permissions.any?
          @old_workflow.permissions
        else
          { contents: 'read', 'pull-requests': 'read' }
        end
      @new_workflow.env = @old_workflow.env.is_a?(Hash) ? @old_workflow.env : {}
      @new_workflow.defaults = @old_workflow.defaults || {}
      @new_workflow.concurrency = @old_workflow.concurrency || {}
    end

    def workflow_job_prepare_variables
      return if @options.only_dependabot

      @new_workflow.do_job(:variables) do
        do_name('Prepare Variables')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_outputs(
          {
            BUILD_NAME: '${{steps.variables.outputs.BUILD_NAME}}',
            BUILD_VERSION: '${{steps.variables.outputs.BUILD_VERSION}}',
            COMMIT_MESSAGE: '${{steps.variables.outputs.COMMIT_MESSAGE}}',
            MODIFIED_GITHUB_RUN_NUMBER: '${{steps.variables.outputs.MODIFIED_GITHUB_RUN_NUMBER}}',
            DEPLOY_ON_BETA: '${{steps.variables.outputs.DEPLOY_ON_BETA}}',
            DEPLOY_ON_RC: '${{steps.variables.outputs.DEPLOY_ON_RC}}',
            DEPLOY_ON_PROD: '${{steps.variables.outputs.DEPLOY_ON_PROD}}',
            DEPLOY_MACOS: '${{steps.variables.outputs.DEPLOY_MACOS}}',
            DEPLOY_TVOS: '${{steps.variables.outputs.DEPLOY_TVOS}}',
            DEPLOY_OPTIONS: '${{steps.variables.outputs.DEPLOY_OPTIONS}}',
            SKIP_LICENSES: '${{steps.variables.outputs.SKIP_LICENSES}}',
            SKIP_LINTERS: '${{steps.variables.outputs.SKIP_LINTERS}}',
            SKIP_TESTS: '${{steps.variables.outputs.SKIP_TESTS}}',
            UPDATE_PACKAGES: '${{steps.variables.outputs.UPDATE_PACKAGES}}',
            LINTERS: '${{steps.variables.outputs.LINTERS}}'
          }
        )

        do_step('Prepare variables') do
          do_id('variables')
          do_uses("cloud-officer/ci-actions/variables@#{CI_ACTIONS_VERSION}")
          do_with(
            {
              'ssh-key': '${{secrets.SSH_KEY}}',
              'github-token': '${{secrets.GH_PAT}}'
            }
          )
        end
      end
    end

    def workflow_job_detect_linters
      return if @options.only_dependabot

      puts('    Detecting linters...')
      linters = Psych.safe_load(File.read("#{__dir__}/../../#{@options.linters_config_file}"))&.deep_symbolize_keys
      excluded_folders = ''

      @options.excluded_folders.each do |folder|
        excluded_folders += " -not -path '*#{folder}*'"
      end

      script_path = nil

      if File.exist?('.gitmodules')
        File.read('.gitmodules').each_line do |line|
          if line.include?('path = ')
            @submodules += " -not -path '*#{line.split('=').last&.strip}*'"
            script_path = line.split('=').last&.strip if line.include?('scripts')
          end
        end
      end

      linters&.each do |short_name, linter|
        next if @options.ignored_linters[short_name]

        next if linter[:short_name].include?('Semgrep') and @options.skip_semgrep

        find_command = "find #{linter[:path]}"
        find_command += excluded_folders unless excluded_folders.empty?
        find_command += @submodules unless @submodules.empty?
        find_command += " | grep -v /node_modules/ | grep -v linters | grep -v vendor | grep -E '#{linter[:pattern]}'"
        stdout_str, _stderr_str, status = Open3.capture3(find_command)

        next unless status.success?

        result = stdout_str.strip

        next if result.empty?

        puts("        Enabling #{linter[:short_name]}...")
        puts('            Found:')

        result.each_line.map(&:strip).first(5).each do |line|
          puts("              #{line}")
        end

        old_workflow = @old_workflow

        if linter[:config]
          if File.exist?("#{script_path}/linters/#{linter[:config]}") && linter[:config] != '.editorconfig'
            FileUtils.ln_s("#{script_path}/linters/#{linter[:config]}", linter[:config], force: true)
          elsif linter[:preserve_config] && File.exist?(linter[:config]) && !File.symlink?(linter[:config])
            puts("            Preserving existing #{linter[:config]} (project-specific config)")
          else
            File.delete(linter[:config]) if File.symlink?(linter[:config]) or File.exist?(linter[:config])
            FileUtils.cp("#{__dir__}/../../config/linters/#{linter[:config]}", linter[:config])
            File.write(linter[:config], File.read(linter[:config]).gsub(/^(\s*)# /, '\1')) if linter[:config] == '.rubocop.yml' and File.exist?('Gemfile') and File.read('Gemfile').include?('rails')
          end
        end

        @new_workflow.do_job(short_name) do
          copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
          do_name(linter[:long_name])
          do_runs_on(old_workflow.jobs[short_name]&.runs_on || DEFAULT_UBUNTU_VERSION)
          do_needs(%w[variables])
          do_permissions(linter[:permissions]) if permissions.empty? and linter[:permissions]

          if linter[:condition]
            do_if("${{needs.variables.outputs.SKIP_LINTERS != '1' && #{linter[:condition]}}}")
          else
            do_if("${{needs.variables.outputs.SKIP_LINTERS != '1'}}")
          end

          do_step(linter[:short_name]) do
            copy_properties(find_step(old_workflow.jobs[short_name]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_uses("#{linter[:uses]}@#{CI_ACTIONS_VERSION}")

            if with.empty?
              default_with =
                {
                  linters: '${{needs.variables.outputs.LINTERS}}',
                  'ssh-key': '${{secrets.SSH_KEY}}',
                  'github-token': '${{secrets.GH_PAT}}'
                }

              default_with.merge!(linter[:options]) if linter[:options]

              do_with(default_with)
            end

            with[:'github-token'] = '${{secrets.GH_PAT}}'
          end
        end
      end
    end

    def workflow_job_licenses_check
      return if @options.only_dependabot

      if File.exist?('Podfile.lock')
        @unit_tests_conditions = "needs.variables.outputs.SKIP_LICENSES != '1' || needs.variables.outputs.SKIP_TESTS != '1'"
      else
        @unit_tests_conditions = "needs.variables.outputs.SKIP_TESTS != '1'"

        return if @options.skip_license_check

        puts('    Adding soup...')
        old_workflow = @old_workflow

        @new_workflow.do_job(:licenses) do
          copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
          do_name('Licenses Check')
          do_runs_on(old_workflow.jobs[:licenses]&.runs_on || DEFAULT_UBUNTU_VERSION)
          do_needs(%w[variables])
          do_if("${{needs.variables.outputs.SKIP_LICENSES != '1'}}")

          do_step('Licenses') do
            copy_properties(find_step(old_workflow.jobs[:licenses]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
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
      end
    end

    def workflow_job_detect_languages
      return if @options.only_dependabot

      puts('    Detecting languages...')
      languages = Psych.safe_load(File.read("#{__dir__}/../../#{@options.languages_config_file}"))&.deep_symbolize_keys
      options_apt = Psych.safe_load(File.read("#{__dir__}/../../#{@options.options_config_file_apt}"))&.deep_symbolize_keys&.[](:options)
      options_mongodb = Psych.safe_load(File.read("#{__dir__}/../../#{@options.options_config_file_mongodb}"))&.deep_symbolize_keys&.[](:options)
      options_mysql = Psych.safe_load(File.read("#{__dir__}/../../#{@options.options_config_file_mysql}"))&.deep_symbolize_keys&.[](:options)
      options_redis = Psych.safe_load(File.read("#{__dir__}/../../#{@options.options_config_file_redis}"))&.deep_symbolize_keys&.[](:options)

      old_workflow = @old_workflow
      unit_tests_conditions = @unit_tests_conditions
      code_deploy_pre_steps = @code_deploy_pre_steps
      dependencies_steps = @dependencies_steps
      dependencies_commands = @dependencies_commands
      excluded_folders = ''

      @options.excluded_folders.each do |folder|
        excluded_folders += " -not -path '*#{folder}*'"
      end

      languages&.each_value do |language|
        next if language[:file_extension].nil?

        language_detected = false
        mongodb = false
        mysql = false
        redis = false
        setup_options = {}

        case RbConfig::CONFIG['host_os']
        when /linux/
          _stdout_str, _stderr_str, status = Open3.capture3("find . #{excluded_folders} -regextype posix-extended -regex '.*\\.(#{language[:file_extension]})' #{@submodules} | grep -qE '.*'")
        else
          _stdout_str, _stderr_str, status = Open3.capture3("find -E . #{excluded_folders} -regex '.*\\.(#{language[:file_extension]})' #{@submodules} | grep -qE '.*'")
        end

        if status.success?
          dependency_detected = false

          language[:dependencies].each do |dependency|
            dependency_detected = true if File.file?(dependency[:dependency_file])
          end

          next unless dependency_detected

          language_detected = true

          language[:dependencies].each do |dependency|
            _stdout_str, _stderr_str, status = Open3.capture3("grep -q #{dependency[:mongodb_dependency]} #{dependency[:dependency_file]}")
            mongodb = true if status.success?
            _stdout_str, _stderr_str, status = Open3.capture3("grep -q #{dependency[:mysql_dependency]} #{dependency[:dependency_file]}")
            mysql = true if status.success?
            _stdout_str, _stderr_str, status = Open3.capture3("grep -q #{dependency[:redis_dependency]} #{dependency[:dependency_file]}")
            redis = true if status.success?
          end
        end

        next unless language_detected

        puts("        Enabling #{language[:long_name]}...")
        version_file = language[:version_files]&.find { |f| File.exist?(f) }
        add_setup_options(setup_options, language[:setup_options], version_file)
        add_setup_options(setup_options, options_apt)
        add_setup_options(setup_options, options_mongodb) if mongodb
        add_setup_options(setup_options, options_mysql) if mysql
        add_setup_options(setup_options, options_redis) if redis

        additional_checks =
          if language[:short_name] == 'swift'
            " || (needs.variables.outputs.DEPLOY_ON_BETA == '1') || (needs.variables.outputs.DEPLOY_ON_RC == '1') || (needs.variables.outputs.DEPLOY_ON_PROD == '1') || (needs.variables.outputs.DEPLOY_MACOS == '1') || (needs.variables.outputs.DEPLOY_TVOS == '1')"
          else
            ''
          end

        skip_license_check = @options.skip_license_check
        force_codedeploy_setup = @options.force_codedeploy_setup

        @new_workflow.do_job(:"#{language[:short_name]}_unit_tests") do
          copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
          do_name("#{language[:long_name]} Unit Tests")
          do_runs_on(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.runs_on || language[:'runs-on'] || DEFAULT_UBUNTU_VERSION)
          do_needs(%w[variables])
          do_if("${{#{unit_tests_conditions}#{additional_checks}}}")

          do_step('Setup') do
            copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
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

            code_deploy_pre_steps << duplicate(self) if language[:short_name] == 'go' or language[:short_name] == 'php' or force_codedeploy_setup
            dependencies_steps << duplicate(self)
          end

          dependency_detected = false

          language[:dependencies].each do |dependency|
            next unless File.file?(dependency[:dependency_file])

            dependency_detected = true

            do_step(dependency[:package_manager_name]) do
              copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
              do_shell('bash')
              do_run(dependency[:package_manager_default]) if run.nil?
              env['GITHUB_TOKEN'] = '${{secrets.GH_PAT}}'
              code_deploy_pre_steps << duplicate(self) if language[:short_name] == 'go' or language[:short_name] == 'php' or force_codedeploy_setup
              dependencies_commands += "#{dependency[:package_manager_update]}\n" if dependency[:package_manager_update]
            end
          end

          next unless dependency_detected

          do_step(language[:unit_test_framework_name]) do
            copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_shell('bash')
            do_run(language[:unit_test_framework_default]) if run.nil?
            env['GITHUB_TOKEN'] = '${{secrets.GH_PAT}}'
          end

          if File.exist?('Podfile.lock') and skip_license_check == false
            do_step('Licenses') do
              copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
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
        end
      end

      @code_deploy_pre_steps = code_deploy_pre_steps
      @dependencies_steps = dependencies_steps
      @dependencies_commands = dependencies_commands
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

              if @options.strict_version_check
                puts("ERROR: Value mismatch for #{option[:name].upcase}")
                puts("Version file (#{version_file}): #{file_version}")
                puts("Recommended value: #{option_value}")
                puts('Strict version check is enabled. Exiting with error.')
                puts("#{'*' * 80}\n\e[0m")
                exit(Status::ERROR_EXIT_CODE)
              else
                puts("WARNING: Value mismatch for #{option[:name].upcase}")
                puts("Version file (#{version_file}): #{file_version}")
                puts("Recommended value: #{option_value}")
                puts('Using version file.')
                puts("#{'*' * 80}\n\e[0m")
              end
            end
          end

          @new_workflow.env.delete(option[:name].upcase.to_sym)
          next
        end

        # Original logic preserved exactly for all other options
        existing_value = @new_workflow.env[option[:name].upcase.to_sym]
        option_value = option[:value]
        value = existing_value || option_value

        next unless value

        if existing_value && option_value && existing_value.to_s != option_value.to_s
          puts("\e[31m\n#{'*' * 80}")

          if @options.strict_version_check && option[:name].upcase.include?('VERSION')
            puts("ERROR: Value mismatch for #{option[:name].upcase}")
            puts("Existing value: #{existing_value}")
            puts("Recommended value: #{option_value}")
            puts('Strict version check is enabled. Exiting with error.')
            puts("#{'*' * 80}\n\e[0m")
            exit(Status::ERROR_EXIT_CODE)
          else
            puts("\e[31m\n#{'*' * 80}")
            puts("WARNING: Value mismatch for #{option[:name].upcase}")
            puts("Existing value: #{existing_value}")
            puts("Recommended value: #{option_value}")
            puts('Using existing value.')
            puts("#{'*' * 80}\n\e[0m")
          end
        end

        @new_workflow.env[option[:name].upcase.to_sym] = value unless @new_workflow.env[option[:name].upcase.to_sym]
        setup_options[option[:name]] = "${{env.#{option[:name].upcase}}}"
      end
    end

    def workflow_job_code_deploy
      return if @options.only_dependabot

      return unless File.exist?('appspec.yml')

      puts('    Adding codedeploy...')
      needs = @new_workflow.jobs.keys.map(&:to_s)
      if_statement = "always() && (needs.variables.outputs.DEPLOY_ON_BETA == '1' || needs.variables.outputs.DEPLOY_ON_RC == '1' || needs.variables.outputs.DEPLOY_ON_PROD == '1')"
      code_deploy_pre_steps = @code_deploy_pre_steps
      old_workflow = @old_workflow

      @new_workflow.jobs.each_key do |job_name|
        if_statement += " && needs.#{job_name}.result != 'failure'"
      end

      @new_workflow.do_job(:codedeploy) do
        copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
        do_name('Code Deploy')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if("${{#{if_statement}}}")

        if code_deploy_pre_steps.empty?
          do_step('Checkout') do
            copy_properties(find_step(old_workflow.jobs[:codedeploy]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_uses("cloud-officer/ci-actions/codedeploy/checkout@#{CI_ACTIONS_VERSION}")
            do_with({ 'ssh-key': '${{secrets.SSH_KEY}}', 'github-token': '${{secrets.GH_PAT}}' }) if with.empty?
          end
        else
          code_deploy_pre_steps.each do |step|
            step.if = nil
          end

          self.steps = code_deploy_pre_steps.clone
        end

        do_step('Update Packages') do
          copy_properties(find_step(old_workflow.jobs[:codedeploy]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_if("${{needs.variables.outputs.UPDATE_PACKAGES == '1'}}")
          do_shell('bash')
          do_run('touch update-packages')
        end

        do_step('Zip') do
          copy_properties(find_step(old_workflow.jobs[:codedeploy]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_shell('bash')
          do_run('zip --quiet --recurse-paths "${{needs.variables.outputs.BUILD_NAME}}.zip" ./*') if run.nil?
        end

        do_step('S3Copy') do
          copy_properties(find_step(old_workflow.jobs[:codedeploy]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_uses("cloud-officer/ci-actions/codedeploy/s3copy@#{CI_ACTIONS_VERSION}")

          if with.empty?
            do_with(
              {
                'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
                'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
                'aws-region': '${{secrets.AWS_DEFAULT_REGION}}',
                source: 'deployment',
                target: 's3://${{secrets.CODEDEPLOY_BUCKET}}/${{github.repository}}'
              }
            )
          end
        end
      end

      %w[beta rc prod].each do |environment|
        @new_workflow.do_job(:"#{environment}_deploy") do
          copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
          do_name("#{environment.capitalize} Deploy")
          do_runs_on(DEFAULT_UBUNTU_VERSION)
          do_needs(%w[variables codedeploy])
          do_if("${{always() && needs.codedeploy.result == 'success' && needs.variables.outputs.DEPLOY_ON_#{environment.upcase} == '1'}}")

          do_step("#{environment.capitalize} Deploy") do
            copy_properties(find_step(old_workflow.jobs[:"#{environment}_deploy"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_uses("cloud-officer/ci-actions/codedeploy/deploy@#{CI_ACTIONS_VERSION}")

            if with.empty?
              do_with(
                {
                  'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
                  'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
                  'aws-region': '${{secrets.AWS_DEFAULT_REGION}}',
                  'application-name': @options.application_name,
                  'deployment-group-name': environment,
                  's3-bucket': '${{secrets.CODEDEPLOY_BUCKET}}',
                  's3-key': '${{github.repository}}/${{needs.variables.outputs.BUILD_NAME}}.zip'
                }
              )
            end
          end
        end
      end
    end

    def workflow_job_aws_commands
      return if @options.only_dependabot

      return unless File.exist?('.aws')

      puts('    Adding aws commands...')
      needs = @new_workflow.jobs.keys.map(&:to_s)
      if_statement = "always() && (needs.variables.outputs.DEPLOY_ON_BETA == '1' || needs.variables.outputs.DEPLOY_ON_RC == '1' || needs.variables.outputs.DEPLOY_ON_PROD == '1')"
      old_workflow = @old_workflow

      @new_workflow.jobs.each_key do |job_name|
        if_statement += " && needs.#{job_name}.result != 'failure'"
      end

      @new_workflow.do_job(:aws) do
        copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
        do_name('AWS')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if("${{#{if_statement}}}")

        do_step('AWS Commands') do
          copy_properties(find_step(old_workflow.jobs[:aws]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_uses("cloud-officer/ci-actions/aws@#{CI_ACTIONS_VERSION}")

          if with.empty?
            do_with(
              {
                'ssh-key': '${{secrets.SSH_KEY}}',
                'github-token': '${{secrets.GH_PAT}}',
                'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
                'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
                'aws-region': '${{secrets.AWS_DEFAULT_REGION}}',
                'shell-commands': 'echo "Add your commands here!"'
              }
            )
          end
        end
      end
    end

    def workflow_job_publish_status
      return if @options.only_dependabot or @options.skip_slack

      puts('    Adding slack...')
      needs = @new_workflow.jobs.keys.map(&:to_s)
      old_workflow = @old_workflow

      @new_workflow.do_job(:slack) do
        copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
        do_name('Publish Statuses')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if('always()')

        do_step('Publish Statuses') do
          copy_properties(find_step(old_workflow.jobs[:slack]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_uses("cloud-officer/ci-actions/slack@#{CI_ACTIONS_VERSION}")

          if with.empty?
            do_with(
              {
                'webhook-url': '${{secrets.SLACK_WEBHOOK_URL}}',
                jobs: '${{toJSON(needs)}}'
              }
            )
          end
        end
      end
    end

    def workflow_write
      @new_workflow.write(@options.build_file, header: @options.args_comment)
    end

    def save_dependabot_config
      dependabot_file = '.github/dependabot.yml'

      if File.exist?(dependabot_file)
        puts('    Removing dependabot config (CVE alerts are handled by repository settings)...')
        FileUtils.rm_f(dependabot_file)
      end

      if @new_workflow.jobs[:licenses] and !@dependencies_steps.empty?
        new_workflow = @new_workflow
        dependencies_steps = @dependencies_steps
        dependencies_commands = @dependencies_commands
        FileUtils.rm_f('.github/workflows/soup.yml')

        @cron_workflow.on =
          {
            schedule:
              [
                {
                  cron: '0 9 * * 1'
                }
              ]
          }

        @cron_workflow.env = @new_workflow.env

        @cron_workflow.do_job(:update_dependencies) do
          do_name('Update Dependencies')
          do_runs_on(DEFAULT_UBUNTU_VERSION)
          do_permissions(
            {
              actions: 'write',
              checks: 'write',
              contents: 'write',
              'pull-requests': 'write'
            }
          )

          merged_with = {}

          dependencies_steps.each do |step|
            merged_with.merge!(step.with) if step.with
          end

          dependencies_steps&.first&.if = nil
          dependencies_steps&.first&.with = merged_with

          self.steps = [dependencies_steps&.first]

          do_step('Update Dependencies') do
            do_shell('bash')
            do_run(dependencies_commands)
          end

          do_step('Licenses') do
            copy_properties(new_workflow.jobs[:licenses]&.steps&.first, %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_uses("cloud-officer/ci-actions/soup@#{CI_ACTIONS_VERSION}")

            if with.empty?
              do_with(
                {
                  'ssh-key': '${{secrets.SSH_KEY}}',
                  'github-token': '${{secrets.GH_PAT}}',
                  parameters: '--no_prompt',
                  'skip-checkout': 'true'
                }
              )
            end

            with[:'github-token'] = '${{secrets.GH_PAT}}'
            with['skip-checkout'] = 'true'
          end

          do_step('Create Pull Request') do
            do_uses('peter-evans/create-pull-request@v7')
            do_with(
              {
                'commit-message': 'Update dependencies and soup files',
                branch: 'update-dependencies-${{github.run_id}}',
                title: 'Update Dependencies',
                body: 'This PR updates the dependencies.'
              }
            )

            with['token'] = '${{secrets.GH_PAT}}'
          end
        end

        @cron_workflow.write('.github/workflows/dependencies.yml')
      else
        FileUtils.rm_f('.github/workflows/dependencies.yml')
      end
    end

    def save_dockerhub_config
      return unless File.exist?('.dockerhub')

      puts('    Adding dockerhub...')
      @dockerhub_workflow.on =
        {
          push:
            {
              tags:
                %w[**]
            }
        }

      @dockerhub_workflow.do_job(:push_to_registry) do
        do_name('Push Docker Image to Docker Hub')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_permissions(
          {
            packages: 'write',
            contents: 'read',
            attestations: 'write',
            'id-token': 'write'
          }
        )

        do_step('Publish Docker image') do
          do_uses("cloud-officer/ci-actions/docker@#{CI_ACTIONS_VERSION}")
          do_with(
            {
              username: '${{secrets.DOCKER_USERNAME}}',
              password: '${{secrets.DOCKER_PASSWORD}}'
            }
          )
        end
      end

      @dockerhub_workflow.write('.github/workflows/docker.yml')
    end

    def check_repository_settings
      return if @options.skip_repository_settings

      puts('Configuring repository settings...')
      repository = Dir.pwd.split('/').last
      repo_url = "https://api.github.com/repos/#{@options.organization}/#{repository}"

      headers =
        {
          headers:
            {
              Authorization: "token #{ENV.fetch('GITHUB_TOKEN', '')}",
              Accept: 'application/vnd.github.v3+json'
            }
        }

      # Get repository info to check visibility
      response = HTTParty.get(repo_url, headers)
      raise(response.message) unless response.code == 200

      repo_info = JSON.parse(response.body)
      is_private = repo_info['private'] == true

      # Get current branch protection to preserve settings
      response = HTTParty.get("#{repo_url}/branches/master/protection", headers)

      raise(response.message) unless response.code == 200

      current_protection = JSON.parse(response.body)

      # Add Vercel check if Next.js project
      @required_status_checks << 'Vercel' if File.exist?('package.json') && File.read('package.json').include?('"next"')

      # Get code scanning analyses (CodeQL, Semgrep, etc.)
      code_scanning_checks = []

      # Check for CodeQL default setup
      codeql_response = HTTParty.get("#{repo_url}/code-scanning/default-setup", headers)

      if codeql_response.code == 200
        codeql_setup = JSON.parse(codeql_response.body)

        if codeql_setup['state'] == 'configured' && codeql_setup['languages'].is_a?(Array)
          # Filter out redundant languages from API response
          # The API returns 'javascript', 'javascript-typescript', and 'typescript' but
          # only 'javascript' check actually runs (it covers both JS and TS)
          redundant_languages = %w[javascript-typescript typescript]
          languages = codeql_setup['languages'].reject { |lang| redundant_languages.include?(lang) }

          languages.each do |lang|
            code_scanning_checks << "Analyze (#{lang})"
          end
          puts("    CodeQL languages detected: #{languages.join(', ')} (#{languages.length})")
        end
      end

      # Build complete list of expected checks
      # Note: CodeQL checks are NOT included because they use "smart mode" which only runs
      # when relevant files change. CodeQL still blocks PRs through code scanning alerts.
      expected_checks = @required_status_checks.dup
      expected_checks << 'Xcode' if Dir.exist?('ci_scripts')

      # Get actual checks from branch protection
      actual_checks = current_protection['required_status_checks']['contexts']

      puts('    Checking required status checks...')

      # Compare expected vs actual
      missing_checks = expected_checks - actual_checks
      extra_checks = actual_checks - expected_checks

      if missing_checks.any? || extra_checks.any?
        if missing_checks.any?
          puts('        MISSING (expected but not in branch protection):')
          missing_checks.each { |check| puts("          ✗ #{check}") }
        end

        if extra_checks.any?
          puts('        EXTRA (in branch protection but not expected):')
          extra_checks.each { |check| puts("          + #{check}") }
        end

        raise('Error: branch protection checks mismatch!')
      end

      # Preserve existing dismissal restrictions or use empty defaults
      dismissal_users = current_protection.dig('required_pull_request_reviews', 'dismissal_restrictions', 'users')&.map { |u| u['login'] } || []
      dismissal_teams = current_protection.dig('required_pull_request_reviews', 'dismissal_restrictions', 'teams')&.map { |t| t['slug'] } || []

      # Preserve existing bypass allowances or use empty defaults
      bypass_users = current_protection.dig('required_pull_request_reviews', 'bypass_pull_request_allowances', 'users')&.map { |u| u['login'] } || []
      bypass_teams = current_protection.dig('required_pull_request_reviews', 'bypass_pull_request_allowances', 'teams')&.map { |t| t['slug'] } || []

      # Preserve existing status checks
      existing_checks = current_protection.dig('required_status_checks', 'checks') || []

      # Set branch protection
      puts('    Setting branch protection...')
      branch_protection = {
        required_status_checks: {
          strict: false,
          checks: existing_checks
        },
        enforce_admins: false,
        required_pull_request_reviews: {
          dismiss_stale_reviews: true,
          require_code_owner_reviews: true,
          require_last_push_approval: true,
          required_approving_review_count: 1,
          dismissal_restrictions: {
            users: dismissal_users,
            teams: dismissal_teams
          },
          bypass_pull_request_allowances: {
            users: bypass_users,
            teams: bypass_teams
          }
        },
        restrictions: nil,
        required_linear_history: false,
        allow_force_pushes: false,
        allow_deletions: false,
        block_creations: false,
        required_conversation_resolution: true
      }

      response = HTTParty.put(
        "#{repo_url}/branches/master/protection",
        headers.merge(body: branch_protection.to_json)
      )
      raise("Error: cannot set branch protection! #{response.message}") unless response.code == 200

      # Enable required signatures (separate endpoint)
      puts('    Enabling required signatures...')
      response = HTTParty.post(
        "#{repo_url}/branches/master/protection/required_signatures",
        headers.merge(headers: headers[:headers].merge(Accept: 'application/vnd.github.zzzax-preview+json'))
      )
      raise("Error: cannot enable required signatures! #{response.message}") unless [200, 204].include?(response.code)

      # Enable vulnerability alerts
      puts('    Enabling vulnerability alerts...')
      response = HTTParty.put("#{repo_url}/vulnerability-alerts", headers)
      raise("Error: cannot enable vulnerability alerts! #{response.message}") unless [200, 204].include?(response.code)

      # Enable automated security fixes
      puts('    Enabling automated security fixes...')
      response = HTTParty.put("#{repo_url}/automated-security-fixes", headers)
      raise("Error: cannot enable automated security fixes! #{response.message}") unless [200, 204].include?(response.code)

      # Configure repository settings
      puts('    Configuring repository options...')
      repo_settings = {
        has_wiki: false,
        has_projects: false,
        allow_merge_commit: false,
        allow_squash_merge: true,
        allow_rebase_merge: true,
        delete_branch_on_merge: true
      }

      response = HTTParty.patch(repo_url, headers.merge(body: repo_settings.to_json))
      raise("Error: cannot configure repository settings! #{response.message}") unless response.code == 200

      # Advanced Security features - disable for private repos (GHAS incurs charges)
      if is_private
        puts('    Disabling Advanced Security features (private repository - GHAS incurs charges)...')
        security_settings = {
          security_and_analysis: {
            secret_scanning: { status: 'disabled' },
            secret_scanning_push_protection: { status: 'disabled' },
            secret_scanning_validity_checks: { status: 'disabled' },
            secret_scanning_non_provider_patterns: { status: 'disabled' },
            secret_scanning_ai_detection: { status: 'disabled' }
          }
        }

        response = HTTParty.patch(repo_url, headers.merge(body: security_settings.to_json))

        if response.code == 200
          puts('        Secret scanning disabled')
          puts('        Secret scanning push protection disabled')
          puts('        Secret scanning validity checks disabled')
          puts('        Secret scanning non-provider patterns disabled')
          puts('        Secret scanning AI detection disabled')
        end
      else
        puts('    Enabling Advanced Security features...')
        security_settings = {
          security_and_analysis: {
            secret_scanning: { status: 'enabled' },
            secret_scanning_push_protection: { status: 'enabled' },
            secret_scanning_validity_checks: { status: 'enabled' },
            secret_scanning_non_provider_patterns: { status: 'enabled' },
            secret_scanning_ai_detection: { status: 'enabled' }
          }
        }

        response = HTTParty.patch(repo_url, headers.merge(body: security_settings.to_json))

        if response.code == 200
          puts('        Secret scanning enabled')
          puts('        Secret scanning push protection enabled')
          puts('        Secret scanning validity checks enabled')
          puts('        Secret scanning non-provider patterns enabled')
          puts('        Secret scanning AI detection (generic passwords) enabled')
        end
      end

      # CodeQL - disable for private repos (GHAS incurs charges)
      if is_private
        puts('    Disabling CodeQL default setup (private repository - GHAS incurs charges)...')
        code_scanning_config = {
          state: 'not-configured'
        }

        response = HTTParty.patch(
          "#{repo_url}/code-scanning/default-setup",
          headers.merge(body: code_scanning_config.to_json)
        )

        puts('        CodeQL default setup disabled') if [200, 202].include?(response.code)
      else
        puts('    Enabling CodeQL default setup...')

        # First check current status
        response = HTTParty.get("#{repo_url}/code-scanning/default-setup", headers)

        if response.code == 200
          current_setup = JSON.parse(response.body)

          if current_setup['state'] == 'configured'
            puts('        CodeQL default setup already configured')
          else
            code_scanning_config = {
              state: 'configured',
              query_suite: 'default'
            }

            response = HTTParty.patch(
              "#{repo_url}/code-scanning/default-setup",
              headers.merge(body: code_scanning_config.to_json)
            )

            puts('        CodeQL default setup enabled') if [200, 202].include?(response.code)
          end
        end
      end

      puts('    Repository settings configured successfully!')
    end

    def update_gitignore
      return if @options.skip_gitignore
      return unless File.exist?('.gitignore')

      puts('Updating .gitignore...')
      git_ignore = File.read('.gitignore').strip

      # Load gitignore templates config
      config_path = "#{__dir__}/../../#{@options.gitignore_config_file}"
      gitignore_config = Psych.safe_load(File.read(config_path))&.deep_symbolize_keys

      # Detect templates based on project files
      detected_templates = detect_gitignore_templates(gitignore_config)

      # Build API URL with detected templates
      templates_param = detected_templates.join(',')
      api_url = "https://www.toptal.com/developers/gitignore/api/#{templates_param}"

      puts("    Detected templates: #{detected_templates.join(', ')}")
      response = HTTParty.get(api_url)

      raise(response.message) unless response.code == 200

      new_git_ignore = response.body.split("\n", 2).last

      # Uncomment specific lines if present (for JetBrains IDE compatibility):
      patterns = %w[*.iml modules.xml .idea/misc.xml *.ipr auto-import. .idea/artifacts .idea/compiler.xml .idea/jarRepositories.xml .idea/modules.xml .idea/*.iml .idea/modules]

      patterns.each do |pattern|
        regex = Regexp.new("^\\s*#\\s*(#{Regexp.escape(pattern)})")
        new_git_ignore.gsub!(regex, '\\1')
      end

      # Add AI Assistants section right after gitignore.io content
      custom_patterns = detect_custom_patterns(gitignore_config)

      unless custom_patterns.empty?
        new_git_ignore += "\n# BEGIN AI Assistants\n\n"
        # Group patterns into pairs (comment + pattern) and join with blank lines between sections
        grouped_patterns = custom_patterns.each_slice(2).map { |group| group.join("\n") }
        new_git_ignore += grouped_patterns.join("\n\n")
        new_git_ignore += "\n\n# END AI Assistants\n"
        tool_names = custom_patterns.filter_map { |p| p.sub('# ', '') if p.start_with?('#') }
        puts("    Custom patterns: #{tool_names.join(', ')}")
      end

      # Preserve custom entries after "# End of" section from original gitignore
      # but skip the AI Assistants section (it was regenerated above)
      found = false
      in_ai_section = false

      git_ignore.each_line do |line|
        if line.include?('# End of ')
          found = true
          next
        end

        if line.include?('# BEGIN AI Assistants') || line.include?('# AI Assistants')
          in_ai_section = true
          next
        end

        if line.include?('# END AI Assistants')
          in_ai_section = false
          next
        end

        # Skip individual AI tool patterns when in old-style AI section (no END marker)
        next if in_ai_section && custom_patterns.any? { |pattern| line.start_with?(pattern) }

        new_git_ignore += line if found && !in_ai_section
      end

      content = new_git_ignore.gsub(/\n{3,16}/, "\n\n").gsub('/bin/*', '#/bin/*').gsub('# Pods/', 'Pods/')
      File.write('.gitignore', "#{content.chomp}\n")
    end

    def detect_gitignore_templates(config)
      templates = Set.new

      # Add always-enabled templates
      config[:always_enabled]&.each do |template|
        templates.add(template)
      end

      # Exclude common dependency/build folders from search
      dependency_excludes = %w[node_modules vendor .git .hg .svn venv .venv env __pycache__ .pytest_cache .bundle target build dist out Pods Carthage .build DerivedData packages .nuget .npm .yarn .pnpm bower_components jspm_packages]
                            .map { |d| "-not -path './#{d}/*'" }
                            .join(' ')

      # Detect templates based on file extensions, specific files, and packages
      config[:extension_detection]&.each do |template_name, detection_config|
        detected = false

        # Check for file extensions
        detection_config[:extensions]&.each do |ext|
          break if detected

          # Use find to check for files with this extension, excluding dependency folders
          case RbConfig::CONFIG['host_os']
          when /linux/
            _stdout_str, _stderr_str, status = Open3.capture3("find . #{dependency_excludes} -maxdepth 5 -type f -name '*.#{ext}' #{@submodules} 2>/dev/null | head -1 | grep -qE '.*'")
          else
            _stdout_str, _stderr_str, status = Open3.capture3("find -E . #{dependency_excludes} -maxdepth 5 -type f -name '*.#{ext}' #{@submodules} 2>/dev/null | head -1 | grep -qE '.*'")
          end

          detected = status.success?
        end

        # Check for specific files
        detection_config[:files]&.each do |file|
          break if detected

          detected = File.exist?(file)
        end

        # Check for packages in package manager files (regex grep)
        detection_config[:packages]&.each do |pm_file, packages|
          break if detected
          next unless File.exist?(pm_file.to_s)

          packages.each do |pkg|
            break if detected

            _stdout_str, _stderr_str, status = Open3.capture3('grep', '-qE', pkg, pm_file.to_s)
            detected = status.success?
          end
        end

        templates.add(template_name.to_s) if detected
      end

      templates.to_a.sort
    end

    def detect_custom_patterns(config)
      patterns = []

      # Always include all custom patterns to prevent accidental commits
      # even if the tool isn't detected (developer may start using it later)
      config[:custom_patterns]&.each_value do |tool_config|
        tool_config[:patterns]&.each do |pattern|
          patterns << pattern
        end
      end

      patterns
    end
  end
end
