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
      @dependabot_package_managers = %w[github-actions]
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
          git config --global --add url."https://${{secrets.SOUP_DEPENDENCIES_UPDATE}}:x-oauth-basic@github.com/".insteadOf ssh://git@github.com:
          git config --global --add url."https://${{secrets.SOUP_DEPENDENCIES_UPDATE}}:x-oauth-basic@github.com/".insteadOf https://github.com/
          git config --global --add url."https://${{secrets.SOUP_DEPENDENCIES_UPDATE}}:x-oauth-basic@github.com/".insteadOf git@github.com:

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
          job.strategy[:matrix].each do |key, values|
            values.each do |value|
              @required_status_checks << "#{job.name} (#{key}: #{value})"
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
      check_repository_settings
      update_gitignore
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
      @new_workflow.permissions = @old_workflow.permissions || {}
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
          do_uses('cloud-officer/ci-actions/variables@master')
          do_with(
            {
              'ssh-key': '${{secrets.SSH_KEY}}'
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

        next if linter[:short_name].include?('CodeQL') and @options.skip_codeql

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
          else
            File.delete(linter[:config]) if File.symlink?(linter[:config]) or File.exist?(linter[:config])
            FileUtils.cp("#{__dir__}/../../config/linters/#{linter[:config]}", linter[:config])
            File.write(linter[:config], File.read(linter[:config]).gsub('# ', '')) if linter[:config] == '.rubocop.yml' and File.exist?('Gemfile') and File.read('Gemfile').include?('rails')
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
            do_uses(linter[:uses])

            if with.empty?
              default_with =
                {
                  linters: '${{needs.variables.outputs.LINTERS}}',
                  'ssh-key': '${{secrets.SSH_KEY}}',
                  github_token: '${{secrets.GITHUB_TOKEN}}'
                }

              default_with.merge!(linter[:options]) if linter[:options]

              do_with(default_with)
            end
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
            do_uses('cloud-officer/ci-actions/soup@master')

            if with.empty?
              do_with(
                {
                  'ssh-key': '${{secrets.SSH_KEY}}',
                  'github-token': '${{secrets.GITHUB_TOKEN}}',
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
        add_setup_options(setup_options, language[:setup_options])
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
            do_uses('cloud-officer/ci-actions/setup@master')

            if with.empty?
              do_with(
                {
                  'ssh-key': '${{secrets.SSH_KEY}}',
                  'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
                  'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
                  'aws-region': '${{secrets.AWS_DEFAULT_REGION}}'
                }.merge(setup_options)
              )
            end

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
              code_deploy_pre_steps << duplicate(self) if language[:short_name] == 'go' or language[:short_name] == 'php' or force_codedeploy_setup
              dependencies_commands += "#{dependency[:package_manager_update]}\n" if dependency[:package_manager_update]
            end
          end

          next unless dependency_detected

          do_step(language[:unit_test_framework_name]) do
            copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_shell('bash')
            do_run(language[:unit_test_framework_default]) if run.nil?
          end

          if File.exist?('Podfile.lock') and skip_license_check == false
            do_step('Licenses') do
              copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
              do_uses('cloud-officer/ci-actions/soup@master')

              if with.empty?
                do_with(
                  {
                    'ssh-key': '${{secrets.SSH_KEY}}',
                    'github-token': '${{secrets.GITHUB_TOKEN}}',
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

    def add_setup_options(setup_options, options)
      options.each do |option|
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
            do_uses('cloud-officer/ci-actions/codedeploy/checkout@master')
            do_with({ 'ssh-key': '${{secrets.SSH_KEY}}' }) if with.empty?
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
          do_uses('cloud-officer/ci-actions/codedeploy/s3copy@master')

          if with.empty?
            do_with(
              {
                'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
                'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
                'aws-region': '${{secrets.AWS_DEFAULT_REGION}}',
                source: 'deployment',
                target: 's3://${{secrets.CODEDEPLOY_BUCKET}}/${GITHUB_REPOSITORY}'
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
            do_uses('cloud-officer/ci-actions/codedeploy/deploy@master')

            if with.empty?
              do_with(
                {
                  'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
                  'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
                  'aws-region': '${{secrets.AWS_DEFAULT_REGION}}',
                  'application-name': @options.application_name,
                  'deployment-group-name': environment,
                  's3-bucket': '${{secrets.CODEDEPLOY_BUCKET}}',
                  's3-key': '${GITHUB_REPOSITORY}/${{needs.variables.outputs.BUILD_NAME}}.zip'
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
          do_uses('cloud-officer/ci-actions/aws@master')

          if with.empty?
            do_with(
              {
                'ssh-key': '${{secrets.SSH_KEY}}',
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
          do_uses('cloud-officer/ci-actions/slack@master')

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
      @new_workflow.write(@options.build_file)
    end

    def save_dependabot_config
      puts('    Adding dependabot...')
      languages = Psych.safe_load(File.read("#{__dir__}/../../#{@options.languages_config_file}"))&.deep_symbolize_keys

      languages&.each_value do |language|
        language[:dependencies].each do |dependency|
          find_command = 'find .'
          find_command += @submodules unless @submodules.empty?
          stdout_str, _stderr_str, status = Open3.capture3(find_command)

          next unless status.success?

          stdout_str.each_line do |path|
            if path.strip.end_with?(dependency[:dependency_file]) and dependency[:dependabot_ecosystem]
              @dependabot_package_managers.push(dependency[:dependabot_ecosystem])
              puts("        Enabling #{dependency[:dependabot_ecosystem]}...")
            end
          end
        end
      end

      @dependabot_package_managers.uniq!
      package_managers =
        @dependabot_package_managers.map do |package_manager|
          {
            'package-ecosystem': package_manager,
            directory: '/',
            'open-pull-requests-limit': 0,
            schedule:
              {
                interval: 'monthly'
              }
          }
        end

      File.write('.github/dependabot.yml', { version: 2, updates: package_managers }.deep_stringify_keys.to_yaml({ line_width: -1 }))

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
            do_uses('cloud-officer/ci-actions/soup@master')

            if with.empty?
              do_with(
                {
                  'ssh-key': '${{secrets.SSH_KEY}}',
                  'github-token': '${{secrets.SOUP_DEPENDENCIES_UPDATE}}',
                  parameters: '--no_prompt',
                  'skip-checkout': 'true'
                }
              )
            end

            with['github-token'] = '${{secrets.SOUP_DEPENDENCIES_UPDATE}}'
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

            with['token'] = '${{secrets.SOUP_DEPENDENCIES_UPDATE}}'
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
          do_uses('cloud-officer/ci-actions/docker@master')
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

      puts('Checking repository settings...')
      repository = Dir.pwd.split('/').last

      headers =
        {
          headers:
            {
              Authorization: "token #{ENV.fetch('GITHUB_TOKEN', '')}",
              Accept: 'application/vnd.github.v3+json'
            }
        }

      response = HTTParty.get("https://api.github.com/repos/#{@options.organization}/#{repository}/branches/master/protection", headers)

      raise(response.message) unless response.code == 200

      branch = JSON.parse(response.body)

      addition_check =
        if Dir.exist?('ci_scripts')
          1
        else
          0
        end

      @required_status_checks << 'Vercel' if File.exist?('package.json') and File.read('package.json').include?('"next"')

      unless branch['required_status_checks']['contexts'].length == (@required_status_checks.length + addition_check) and branch['required_status_checks']['checks'].length == (@required_status_checks.length + addition_check)
        @required_status_checks.each { |job| puts("Missing check #{job}!") unless branch['required_status_checks']['contexts'].include?(job) }

        puts("@required_status_checks.length : #{@required_status_checks.length}")
        puts("addition_check : #{addition_check}")
        puts("branch['required_status_checks']['checks'].length : #{branch['required_status_checks']['checks'].length}")
        puts("branch['required_status_checks']['contexts'].length : #{branch['required_status_checks']['contexts'].length}")
        puts("branch['required_status_checks']['checks'] : #{branch['required_status_checks']['checks']}")
        puts("branch['required_status_checks']['contexts'] : #{branch['required_status_checks']['contexts']}")

        raise('Error: master branch missing checks!') unless branch['required_status_checks']['contexts'].length == (@required_status_checks.length + addition_check) and branch['required_status_checks']['checks'].length == (@required_status_checks.length + addition_check)
      end

      raise('Error: master branch invalid required status checks!') unless branch['required_status_checks']['strict'] == false

      raise('Error: master branch invalid dismiss stale reviews!') unless branch['required_pull_request_reviews']['dismiss_stale_reviews']

      raise('Error: master branch invalid require code owner reviews!') unless branch['required_pull_request_reviews']['require_code_owner_reviews']

      raise('Error: master branch invalid require last push approval!') unless branch['required_pull_request_reviews']['require_last_push_approval']

      raise('Error: master branch invalid required approving review count!') unless branch['required_pull_request_reviews']['required_approving_review_count'] == 1

      raise('Error: master branch invalid dismissal restrictions!') if branch['required_pull_request_reviews']['dismissal_restrictions']['users'].empty?

      raise('Error: master branch invalid bypass pull request allowances!') if branch['required_pull_request_reviews']['bypass_pull_request_allowances']['users'].empty?

      raise('Error: master branch invalid required signatures!') unless branch['required_signatures']['enabled'] == false

      raise('Error: master branch invalid enforce admins!') unless branch['enforce_admins']['enabled'] == false

      raise('Error: master branch invalid required linear history!') unless branch['required_linear_history']['enabled'] == false

      raise('Error: master branch invalid allow force pushes!') unless branch['allow_force_pushes']['enabled'] == false

      raise('Error: master branch invalid allow deletions!') unless branch['allow_deletions']['enabled'] == false

      raise('Error: master branch invalid block creations!') unless branch['block_creations']['enabled'] == false

      raise('Error: master branch invalid required conversation resolution!') unless branch['required_conversation_resolution']['enabled']

      response = HTTParty.get("https://api.github.com/repos/#{@options.organization}/#{repository}/vulnerability-alerts", headers)

      raise('Error: vulnerability alerts disabled!') unless response.code == 204

      response = HTTParty.put("https://api.github.com/repos/#{@options.organization}/#{repository}/automated-security-fixes", headers)

      raise('Error: cannot enable automated security fixes!') unless response.code == 204

      response = HTTParty.get("https://api.github.com/repos/#{@options.organization}/#{repository}", headers)

      raise(response.message) unless response.code == 200

      response = HTTParty.patch("https://api.github.com/repos/#{@options.organization}/#{repository}", headers.merge(body: { has_wiki: false }.to_json))

      raise('Error: cannot disable wiki!') unless response.code == 200

      response = HTTParty.patch("https://api.github.com/repos/#{@options.organization}/#{repository}", headers.merge(body: { has_projects: false }.to_json))

      raise('Error: cannot disable projects!') unless response.code == 200

      response = HTTParty.patch("https://api.github.com/repos/#{@options.organization}/#{repository}", headers.merge(body: { allow_merge_commit: false }.to_json))

      raise('Error: cannot disable merge commit!') unless response.code == 200

      response = HTTParty.patch("https://api.github.com/repos/#{@options.organization}/#{repository}", headers.merge(body: { allow_squash_merge: true }.to_json))

      raise('Error: cannot enable squash merge!') unless response.code == 200

      response = HTTParty.patch("https://api.github.com/repos/#{@options.organization}/#{repository}", headers.merge(body: { allow_rebase_merge: true }.to_json))

      raise('Error: cannot enable rebase merge!') unless response.code == 200

      response = HTTParty.patch("https://api.github.com/repos/#{@options.organization}/#{repository}", headers.merge(body: { delete_branch_on_merge: true }.to_json))

      raise('Error: cannot enable delete branch after merge!') unless response.code == 200
    end

    def update_gitignore
      return if @options.skip_gitignore

      puts('Updating .gitignore...')
      git_ignore = File.read('.gitignore').strip

      return unless git_ignore.lines.first&.include?('# Created by ') or git_ignore.lines.first&.include?('# Edit at ')

      first_line = git_ignore.lines.first
      split_line = first_line&.split&.[](3)
      api_url = split_line&.gsub('?templates=', '/api/')
      response = HTTParty.get(api_url)

      raise(response.message) unless response.code == 200

      new_git_ignore = response.body.split("\n", 2).last
      found = false

      git_ignore.each_line do |line|
        if line.include?('# End of ')
          found = true
          next
        end

        new_git_ignore += line if found
      end

      new_git_ignore += "\n"

      # Uncomment specific lines if present:
      patterns = %w[*.iml modules.xml .idea/misc.xml *.ipr auto-import. .idea/artifacts .idea/compiler.xml .idea/jarRepositories.xml .idea/modules.xml .idea/*.iml .idea/modules]

      patterns.each do |pattern|
        regex = Regexp.new("^\\s*#\\s*(#{Regexp.escape(pattern)})")
        new_git_ignore.gsub!(regex, '\\1')
      end

      File.write('.gitignore', new_git_ignore.gsub(/\n{3,16}/, "\n").gsub('/bin/*', '#/bin/*').gsub('# Pods/', 'Pods/'))
    end
  end
end
