# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'duplicate'
require 'find'
require 'httparty'
require 'json'
require 'psych'

require_relative 'aws_job_builder'
require_relative 'code_deploy_job_builder'
require_relative 'dependabot_manager'
require_relative 'dockerhub_manager'
require_relative 'file_scanner'
require_relative 'github_api_client'
require_relative 'gitignore_manager'
require_relative 'language_job_builder'
require_relative 'licenses_job_builder'
require_relative 'linter_job_builder'
require_relative 'options'
require_relative 'repository_configurator'
require_relative 'slack_job_builder'
require_relative 'status'
require_relative 'variables_job_builder'
require_relative 'workflow/workflow'

module GHB
  # Represents an instance of an application. This is the entry point for all invocations from the command line.
  class Application
    include FileScanner

    def initialize(argv)
      @code_deploy_pre_steps = []
      @exit_code = Status::SUCCESS_EXIT_CODE
      @dependencies_steps = []
      @file_cache = {}
      @cron_workflow = Workflow.new('Cron Dependencies')
      @dockerhub_workflow = Workflow.new('Publish Docker image')
      @new_workflow = Workflow.new('Build')
      @old_workflow = Workflow.new('Build')
      @options = configure_options(argv)
      @required_status_checks = []
      @submodules = []
      @unit_tests_conditions = nil
      @dependencies_commands =
        <<~BASH
          git config --global --add url."https://${{secrets.GH_PAT}}:x-oauth-basic@github.com/".insteadOf ssh://git@github.com:
          git config --global --add url."https://${{secrets.GH_PAT}}:x-oauth-basic@github.com/".insteadOf https://github.com/
          git config --global --add url."https://${{secrets.GH_PAT}}:x-oauth-basic@github.com/".insteadOf git@github.com:

        BASH
    end

    def execute
      validate_config!
      puts('Generating build file...')
      workflow_read
      workflow_set_defaults

      VariablesJobBuilder.new(options: @options, new_workflow: @new_workflow).build

      LinterJobBuilder.new(
        options: @options,
        submodules: @submodules,
        old_workflow: @old_workflow,
        new_workflow: @new_workflow,
        file_cache: @file_cache
      ).build

      licenses_builder = LicensesJobBuilder.new(options: @options, old_workflow: @old_workflow, new_workflow: @new_workflow)
      licenses_builder.build
      @unit_tests_conditions = licenses_builder.unit_tests_conditions

      language_builder = LanguageJobBuilder.new(
        options: @options,
        submodules: @submodules,
        old_workflow: @old_workflow,
        new_workflow: @new_workflow,
        unit_tests_conditions: @unit_tests_conditions,
        file_cache: @file_cache,
        dependencies_commands: @dependencies_commands
      )
      language_builder.build
      @code_deploy_pre_steps = language_builder.code_deploy_pre_steps
      @dependencies_steps = language_builder.dependencies_steps
      @dependencies_commands = language_builder.dependencies_commands

      collect_required_status_checks

      CodeDeployJobBuilder.new(
        options: @options,
        old_workflow: @old_workflow,
        new_workflow: @new_workflow,
        code_deploy_pre_steps: @code_deploy_pre_steps
      ).build

      AwsJobBuilder.new(options: @options, old_workflow: @old_workflow, new_workflow: @new_workflow).build
      SlackJobBuilder.new(options: @options, old_workflow: @old_workflow, new_workflow: @new_workflow).build

      workflow_write

      DependabotManager.new(
        new_workflow: @new_workflow,
        cron_workflow: @cron_workflow,
        dependencies_steps: @dependencies_steps,
        dependencies_commands: @dependencies_commands
      ).save

      DockerhubManager.new(dockerhub_workflow: @dockerhub_workflow).save
      GitignoreManager.new(options: @options, submodules: @submodules, file_cache: @file_cache).update
      RepositoryConfigurator.new(options: @options, required_status_checks: @required_status_checks).configure

      @exit_code
    end

    private

    def configure_options(argv)
      Options.new(argv).parse
    rescue OptionParser::InvalidOption => e
      puts("Error: #{e}")
      exit(Status::ERROR_EXIT_CODE)
    end

    # Validates that all required config files exist, have valid YAML syntax,
    # and contain required keys (CFG-001, CFG-005)
    # @raise [ConfigError] if any config file is missing, malformed, or missing required keys
    def validate_config!
      config_files = {
        linters_config: @options.linters_config_file,
        languages_config: @options.languages_config_file,
        apt_options: @options.options_config_file_apt,
        mongodb_options: @options.options_config_file_mongodb,
        mysql_options: @options.options_config_file_mysql,
        redis_options: @options.options_config_file_redis,
        elasticsearch_options: @options.options_config_file_elasticsearch,
        gitignore_config: @options.gitignore_config_file
      }

      config_files.each do |name, relative_path|
        full_path = "#{__dir__}/../../#{relative_path}"
        display_name = name.to_s.tr('_', ' ')

        raise(ConfigError, "Missing required #{display_name} file: #{relative_path}") unless File.exist?(full_path)

        begin
          data = Psych.safe_load(cached_file_read(full_path), permitted_classes: [Symbol])
        rescue Psych::SyntaxError => e
          raise(ConfigError, "Invalid YAML in #{display_name} file (#{relative_path}): #{e.message}")
        end

        validate_config_schema(name, relative_path, data)
      end
    end

    def validate_config_schema(name, relative_path, data)
      case name
      when :linters_config
        validate_entries(data, relative_path, 'linter', %w[short_name long_name uses path pattern])
      when :languages_config
        validate_entries(data, relative_path, 'language', %w[short_name long_name])
      when :apt_options, :mongodb_options, :mysql_options, :redis_options, :elasticsearch_options
        validate_option_entries(data, relative_path)
      end
    end

    def validate_entries(data, relative_path, entry_type, required_keys)
      return unless data.is_a?(Hash)

      data.each do |entry_name, entry|
        next unless entry.is_a?(Hash)

        missing_keys = required_keys.reject { |key| entry.key?(key) || entry.key?(key.to_sym) }
        next if missing_keys.empty?

        raise(ConfigError, "#{entry_type.capitalize} '#{entry_name}' in #{relative_path} is missing required keys: #{missing_keys.join(', ')}")
      end
    end

    def validate_option_entries(data, relative_path)
      return unless data.is_a?(Hash)

      options = data['options'] || data[:options]
      return unless options.is_a?(Array)

      options.each_with_index do |option, index|
        next if option.is_a?(Hash) && (option.key?('name') || option.key?(:name))

        raise(ConfigError, "Option entry #{index} in #{relative_path} is missing required key: name")
      end
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

    def collect_required_status_checks
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
    end

    def workflow_write
      @new_workflow.write(@options.build_file, header: @options.args_comment)
    end
  end
end
