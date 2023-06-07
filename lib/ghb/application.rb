# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'duplicate'
require 'open3'
require 'psych'

require_relative 'options'
require_relative 'status'
require_relative 'workflow/workflow'

module GHB
  # Represents an instance of an application. This is the entry point for all invocations from the command line.
  class Application
    def initialize(argv)
      @code_deploy_pre_steps = []
      @exit_code = Status::SUCCESS_EXIT_CODE
      @new_workflow = Workflow.new('Build')
      @old_workflow = Workflow.new('Build')
      @options = configure_options(argv)
      @submodules = ''
      @unit_tests_conditions = nil
    end

    def execute
      puts('Generating build file...')
      read
      set_defaults
      prepare_variables
      detect_linters
      licenses_check
      detect_languages
      code_deploy
      aws_commands
      publish_status
      dependabot
      write
      @exit_code
    end

    private

    def configure_options(argv)
      Options.new(argv).parse
    rescue OptionParser::InvalidOption => e
      puts("Error: #{e}")
      exit(Status::ERROR_EXIT_CODE)
    end

    def read
      return unless File.exist?(@options.build_file)

      puts("Reading current build file #{@options.build_file}...")
      @old_workflow.read(@options.build_file)
    end

    def set_defaults
      @new_workflow.name =
        if @old_workflow.name.nil?
          'Build'
        else
          @old_workflow.name
        end

      @new_workflow.on =
        if @old_workflow.on.empty?
          {
            pull_request:
              {
                types: %w[opened edited reopened synchronize]
              },
            push: nil,
            release:
              {
                types: %w[created]
              }
          }
        else
          @old_workflow.on
        end

      @new_workflow.run_name = @old_workflow.run_name unless @old_workflow.run_name.nil?
      @new_workflow.permissions = @old_workflow.permissions || {}
      @new_workflow.env = @old_workflow.env || {}
      @new_workflow.defaults = @old_workflow.defaults || {}
      @new_workflow.concurrency = @old_workflow.concurrency || {}
    end

    def prepare_variables
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

    def detect_linters
      return if @options.only_dependabot

      puts('    Detecting linters...')
      linters = Psych.safe_load(File.read("#{__dir__}/../../#{@options.linters_config_file}"))&.deep_symbolize_keys
      excluded_folders = ''

      @options.excluded_folders&.split(',')&.each do |folder|
        excluded_folders += "| grep -v #{folder} "
      end

      script_path = nil

      if File.exist?('.gitmodules')
        File.read('.gitmodules').each_line do |line|
          if line.include?('path = ')
            @submodules += "| grep -v #{line.split('=').last&.strip} "
            script_path = line.split('=').last&.strip if line.include?('scripts')
          end
        end
      end

      linters&.each do |short_name, linter|
        next if @options.ignored_linters[short_name]

        _stdout_str, _stderr_str, status = Open3.capture3("find -E #{linter[:path]} -regex '#{linter[:pattern]}' #{excluded_folders} #{@submodules} | grep -v linters | grep -E '.*' &> /dev/null")

        next unless status.success? or (linter[:directory] and Dir.exist?(linter[:directory])) # rubocop:disable Style/UnlessLogicalOperators

        puts("        Enabling #{linter[:short_name]}...")
        old_workflow = @old_workflow

        if linter[:config] and !File.exist?(linter[:config])
          if File.exist?("#{script_path}/linters/#{linter[:config]}")
            FileUtils.ln_s("#{script_path}/linters/#{linter[:config]}", linter[:config], force: true)
          else
            FileUtils.cp("#{__dir__}/../../config/linters/#{linter[:config]}", linter[:config])
          end
        end

        @new_workflow.do_job(short_name) do
          copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
          do_name(linter[:long_name])
          do_runs_on(DEFAULT_UBUNTU_VERSION)
          do_needs(%w[variables])

          if linter[:condition]
            do_if("${{needs.variables.outputs.SKIP_LINTERS != '1' && #{linter[:condition]}}}")
          else
            do_if("${{needs.variables.outputs.SKIP_LINTERS != '1'}}")
          end

          do_step(linter[:short_name]) do
            copy_properties(find_step(old_workflow.jobs[short_name]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_uses(linter[:uses])

            if with.empty?
              do_with(
                {
                  linters: '${{needs.variables.outputs.LINTERS}}',
                  'ssh-key': '${{secrets.SSH_KEY}}',
                  github_token: '${{secrets.GITHUB_TOKEN}}'
                }
              )
            end
          end
        end
      end
    end

    def licenses_check
      return if @options.only_dependabot

      if File.exist?('Podfile.lock')
        @unit_tests_conditions = "needs.variables.outputs.SKIP_LICENSES != '1' || needs.variables.outputs.SKIP_TESTS != '1'"
      else
        puts('    Adding soup...')
        @unit_tests_conditions = "needs.variables.outputs.SKIP_TESTS != '1'"

        old_workflow = @old_workflow

        @new_workflow.do_job(:licenses) do
          copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
          do_name('Licenses Check')
          do_runs_on(DEFAULT_UBUNTU_VERSION)
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

    def detect_languages
      return if @options.only_dependabot

      puts('    Detecting languages...')
      languages = Psych.safe_load(File.read("#{__dir__}/../../#{@options.languages_config_file}"))&.deep_symbolize_keys
      options_apt = Psych.safe_load(File.read("#{__dir__}/../../#{@options.options_config_file[:apt]}"))&.deep_symbolize_keys&.[](:options)
      options_mongodb = Psych.safe_load(File.read("#{__dir__}/../../#{@options.options_config_file[:mongodb]}"))&.deep_symbolize_keys&.[](:options)
      options_mysql = Psych.safe_load(File.read("#{__dir__}/../../#{@options.options_config_file[:mysql]}"))&.deep_symbolize_keys&.[](:options)
      options_redis = Psych.safe_load(File.read("#{__dir__}/../../#{@options.options_config_file[:redis]}"))&.deep_symbolize_keys&.[](:options)

      old_workflow = @old_workflow
      unit_tests_conditions = @unit_tests_conditions
      code_deploy_pre_steps = @code_deploy_pre_steps

      languages&.each do |_, language|
        language_detected = false
        mongodb = false
        mysql = false
        redis = false
        setup_options = {}

        # grep -v linters | grep -v tests | grep -v sdk | grep -v Libraries |
        _stdout_str, _stderr_str, status = Open3.capture3("find -E . -regex '.*\\.(#{language[:file_extension]})' #{@submodules} | grep -E '.*' &> /dev/null")

        if status.success?
          dependency_detected = false

          language[:dependencies].each do |dependency|
            dependency_detected = true if File.file?(dependency[:dependency_file])
          end

          next unless dependency_detected

          language_detected = true

          language[:dependencies].each do |dependency|
            _stdout_str, _stderr_str, status = Open3.capture3("grep #{dependency[:mongodb_dependency]} #{dependency[:dependency_file]} &> /dev/null")
            mongodb = true if status.success?
            _stdout_str, _stderr_str, status = Open3.capture3("grep #{dependency[:mysql_dependency]} #{dependency[:dependency_file]} &> /dev/null")
            mysql = true if status.success?
            _stdout_str, _stderr_str, status = Open3.capture3("grep #{dependency[:redis_dependency]} #{dependency[:dependency_file]} &> /dev/null")
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

        @new_workflow.do_job(:"#{language[:short_name]}_unit_tests") do
          copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
          do_name("#{language[:long_name]} Unit Tests")
          do_runs_on(old_workflow.jobs["#{language[:short_name]}_unit_tests".to_sym]&.runs_on || language[:'runs-on'] || DEFAULT_UBUNTU_VERSION)
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
                }
              )
            end

            code_deploy_pre_steps << duplicate(self) if language[:short_name] == 'go' or language[:short_name] == 'php'
          end

          dependency_detected = false

          language[:dependencies].each do |dependency|
            next unless File.file?(dependency[:dependency_file])

            dependency_detected = true

            do_step(dependency[:package_manager_name]) do
              copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
              do_shell('bash')
              do_run(dependency[:package_manager_default]) if run.nil?
              code_deploy_pre_steps << duplicate(self) if language[:short_name] == 'go' or language[:short_name] == 'php'
            end
          end

          next unless dependency_detected

          do_step(language[:unit_test_framework_name]) do
            copy_properties(find_step(old_workflow.jobs[:"#{language[:short_name]}_unit_tests"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_shell('bash')
            do_run(language[:unit_test_framework_default]) if run.nil?
          end

          if File.exist?('Podfile.lock')
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
    end

    def add_setup_options(setup_options, options)
      options.each do |option|
        value = @new_workflow.env[option[:name].upcase.to_sym] || option[:value]

        next unless value

        @new_workflow.env[option[:name].upcase.to_sym] = value unless @new_workflow.env[option[:name].upcase.to_sym]
        setup_options[option[:name]] = "${{env.#{option[:name].upcase}}}"
      end
    end

    def code_deploy
      return if @options.only_dependabot

      return unless File.exist?('appspec.yml')

      puts('    Adding CodeDeploy...')
      needs = @new_workflow.jobs.keys.map(&:to_s)
      if_statement = "(needs.variables.outputs.DEPLOY_ON_BETA == '1' || needs.variables.outputs.DEPLOY_ON_RC == '1' || needs.variables.outputs.DEPLOY_ON_PROD == '1')"
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
        do_if(if_statement)

        if code_deploy_pre_steps.empty?
          do_step('Checkout') do
            copy_properties(find_step(old_workflow.jobs[:codedeploy]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_uses('cloud-officer/ci-actions/codedeploy/checkout@master')
            do_with({ 'ssh-key': '${{secrets.SSH_KEY}}' }) if with.empty?
          end
        else
          code_deploy_pre_steps.each do |step|
            next unless step.name == 'Setup'

            step.with.reject! { |key, _value| key.to_s.include?('apt') or key.to_s.include?('mongodb') or key.to_s.include?('mysql') or key.to_s.include?('redis') }
          end

          self.steps = code_deploy_pre_steps
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
          do_if("${{always() && needs.code_deploy.result == 'success' && needs.variables.outputs.DEPLOY_ON_#{environment.upcase} == '1'}}")

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

    def aws_commands
      return if @options.only_dependabot

      return unless File.exist?('.aws')

      puts('    Adding AWS Commands...')
      needs = @new_workflow.jobs.keys.map(&:to_s)
      if_statement = "(needs.variables.outputs.DEPLOY_ON_BETA == '1' || needs.variables.outputs.DEPLOY_ON_RC == '1' || needs.variables.outputs.DEPLOY_ON_PROD == '1')"
      old_workflow = @old_workflow

      @new_workflow.jobs.each_key do |job_name|
        if_statement += " && needs.#{job_name}.result != 'failure'"
      end

      @new_workflow.do_job(:aws) do
        copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
        do_name('AWS Commands')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if(if_statement)

        do_step('AWS Commands') do
          copy_properties(find_step(old_workflow.jobs[:aws]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_name("#{environment.capitalize} Deploy")
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

    def publish_status
      return if @options.only_dependabot

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

    def dependabot
      puts('    Adding dependabot...')
      old_workflow = @old_workflow

      @new_workflow.do_job(:dependabot) do
        copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
        do_name('Dependabot')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_if("${{(github.event_name == 'pull_request' || github.event_name == 'pull_request_target') && github.event.pull_request.user.login == 'dependabot[bot]'}}")

        do_step('Dependabot') do
          copy_properties(find_step(old_workflow.jobs[:dependencies]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_uses('cloud-officer/ci-actions/jira@master')

          if with.empty?
            do_with(
              {
                'base-url': '${{secrets.JIRA_BASE_URL}}',
                'user-email': '${{secrets.JIRA_USER_EMAIL}}',
                'api-token': '${{secrets.JIRA_API_TOKEN}}',
                project: '${{secrets.JIRA_PROJECT}}',
                'issue-type': '${{secrets.JIRA_ISSUE_TYPE}}'
              }
            )
          end
        end
      end
    end

    def write
      @new_workflow.write(@options.build_file)
    end
  end
end
