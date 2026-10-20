# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'find'
require 'httparty'
require 'json'
require 'psych'

require_relative '../ghb'
require_relative 'auto_approve_manager'
require_relative 'aws_job_builder'
require_relative 'build_context'
require_relative 'check_names'
require_relative 'code_deploy_job_builder'
require_relative 'dependabot_manager'
require_relative 'docker_build_job_builder'
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
require_relative 'vercel_job_builder'
require_relative 'workflow/workflow'

module GHB
  # Represents an instance of an application. This is the entry point for all invocations from the command line.
  class Application
    include FileScanner

    # Validation keys of the service options files, derived from the SERVICES registry.
    SERVICE_CONFIG_KEYS =
      SERVICES
      .map { |service| GHB.service_config_key(service) }
      .freeze
    private_constant :SERVICE_CONFIG_KEYS

    def initialize(argv)
      @code_deploy_pre_steps = []
      @file_cache = {}
      @auto_approve_workflow = Workflow.new('Auto-approve for code owners')
      @dockerhub_workflow = Workflow.new('Publish Docker image')
      @new_workflow = Workflow.new('Build')
      @old_workflow = Workflow.new('Build')
      @options = configure_options(argv)
      @required_status_checks = []
      @submodules = []
      @unit_tests_conditions = nil
    end

    def execute
      validate_config!

      if @options.get_ignored_folders
        puts(JSON.pretty_generate({ ignored_folders: excluded_dirs_from_config }))
        return Status::SUCCESS_EXIT_CODE
      end

      @default_branch = detect_default_branch
      puts('Generating build file...')
      workflow_read
      workflow_set_defaults

      context = BuildContext.new(
        options: @options,
        old_workflow: @old_workflow,
        new_workflow: @new_workflow,
        file_cache: @file_cache,
        submodules: @submodules
      )

      VariablesJobBuilder.new(context: context).build

      LinterJobBuilder.new(context: context).build

      licenses_builder = LicensesJobBuilder.new(context: context)
      licenses_builder.build
      @unit_tests_conditions = licenses_builder.unit_tests_conditions

      language_builder = LanguageJobBuilder.new(
        context: context,
        unit_tests_conditions: @unit_tests_conditions
      )
      language_builder.build
      @code_deploy_pre_steps = language_builder.code_deploy_pre_steps

      DockerBuildJobBuilder.new(context: context).build

      collect_required_status_checks

      CodeDeployJobBuilder.new(context: context, code_deploy_pre_steps: @code_deploy_pre_steps).build

      VercelJobBuilder.new(context: context).build

      AwsJobBuilder.new(context: context).build
      SlackJobBuilder.new(context: context).build

      @new_workflow.adopt_aws_role
      workflow_write

      DependabotManager.new.save

      AutoApproveManager.new(auto_approve_workflow: @auto_approve_workflow).save
      DockerhubManager.new(dockerhub_workflow: @dockerhub_workflow).save
      GitignoreManager.new(context: context).update
      RepositoryConfigurator.new(options: @options, required_status_checks: @required_status_checks, default_branch: @default_branch).configure

      Status::SUCCESS_EXIT_CODE
    end

    private

    def detect_default_branch
      branch = `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null`.strip.sub(%r{^refs/remotes/origin/}, '')
      return branch unless branch.empty?

      branch = remote_default_branch || api_default_branch
      return branch if branch

      warn("WARNING: could not detect the default branch from origin/HEAD, the origin remote or the GitHub API, falling back to 'master'")
      'master'
    end

    def remote_default_branch
      `GIT_TERMINAL_PROMPT=0 git ls-remote --symref origin HEAD 2>/dev/null`[%r{^ref: refs/heads/(\S+)\tHEAD$}, 1]
    end

    def api_default_branch
      github_token = ENV.fetch('GITHUB_TOKEN', nil)
      return if github_token.nil? || github_token.empty? || `git remote get-url origin 2>/dev/null`.strip.empty?

      repo_url = "https://api.github.com/repos/#{@options.organization}/#{Dir.pwd.split('/').last}"
      branch = JSON.parse(GitHubAPIClient.new(github_token).get(repo_url).body)['default_branch']
      branch unless branch.to_s.empty?
    rescue StandardError
      nil
    end

    def configure_options(argv)
      Options.new(argv).parse
    rescue OptionParser::ParseError => e
      raise(ConfigError, e.message)
    end

    def validate_config!
      service_config_files = SERVICES.to_h { |service| [GHB.service_config_key(service), @options.options_config_files[service]] }
      config_files = {
        linters_config: @options.linters_config_file,
        languages_config: @options.languages_config_file,
        **service_config_files,
        gitignore_config: @options.gitignore_config_file,
        external_actions: EXTERNAL_ACTIONS_CONFIG_FILE
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
      return validate_option_entries(data, relative_path) if SERVICE_CONFIG_KEYS.include?(name)

      case name
      when :linters_config
        validate_entries(data, relative_path, 'linter', %w[short_name long_name uses path pattern])
      when :languages_config
        validate_entries(data, relative_path, 'language', %w[short_name long_name])
        validate_language_dependencies(data, relative_path)
        validate_language_failure_artifacts(data, relative_path)
      when :external_actions
        GHB.validate_external_actions!(data)
      end
    end

    # LanguageJobBuilder iterates dependencies unguarded once file_extension matches.
    def validate_language_dependencies(data, relative_path)
      return unless data.is_a?(Hash)

      data.each do |entry_name, entry|
        next unless entry.is_a?(Hash)
        next unless entry.key?('file_extension') || entry.key?(:file_extension)

        dependencies = entry['dependencies'] || entry[:dependencies]
        next if dependencies.is_a?(Array)

        raise(ConfigError, "Language '#{entry_name}' in #{relative_path} declares file_extension so it must also declare dependencies as a list")
      end
    end

    def validate_language_failure_artifacts(data, relative_path)
      return unless data.is_a?(Hash)

      data.each do |entry_name, entry|
        next unless entry.is_a?(Hash)

        artifacts = entry['failure_artifacts'] || entry[:failure_artifacts]
        next if artifacts.nil? || (artifacts.is_a?(Array) && artifacts.all? { |artifact| valid_failure_artifact?(artifact) })

        raise(ConfigError, "Language '#{entry_name}' in #{relative_path} must declare failure_artifacts as a list of entries with a marker string and a non-empty list of path strings")
      end
    end

    def valid_failure_artifact?(artifact)
      return false unless artifact.is_a?(Hash)

      marker = artifact['marker'] || artifact[:marker]
      paths = artifact['paths'] || artifact[:paths]
      marker.is_a?(String) && !marker.empty? && paths.is_a?(Array) && paths.any? && paths.all? { |path| path.is_a?(String) && !path.empty? }
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
              branches: [@default_branch, '[0-9]*', 'dependabot/**'],
              tags: %w[**]
            }
        }

      @new_workflow.run_name = @old_workflow.run_name unless @old_workflow.run_name.nil?
      # pull-requests: write is granted per job to the reviewdog linters only (LinterJobBuilder).
      previous_defaults = [
        { contents: 'read', 'pull-requests': 'read' },
        { contents: 'read', 'pull-requests': 'write' }
      ]
      @new_workflow.permissions =
        if !@old_workflow.permissions.empty? and !previous_defaults.include?(@old_workflow.permissions)
          @old_workflow.permissions
        else
          { contents: 'read' }
        end
      @new_workflow.env = @old_workflow.env
      @new_workflow.defaults = @old_workflow.defaults || {}
      @new_workflow.concurrency =
        if @old_workflow.concurrency.empty?
          # Cancel superseded full builds when a PR branch is pushed again.
          { group: 'build-${{github.ref}}', 'cancel-in-progress': true }
        else
          @old_workflow.concurrency
        end
    end

    def collect_required_status_checks
      @new_workflow.jobs.each_value do |job|
        next if job.nil?

        names = CheckNames.for_job(job.name, job.strategy)

        if names.nil?
          warn("Warning: cannot resolve the check names of job '#{job.name}' (dynamic matrix values or unresolved expressions); skipping it in the required status checks.")
          next
        end

        @required_status_checks.concat(names)
      end
    end

    def workflow_write
      @new_workflow.write(@options.build_file, header: @options.args_comment)
    end
  end
end
