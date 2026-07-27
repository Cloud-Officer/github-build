# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'duplicate'
require 'find'
require 'httparty'
require 'json'
require 'psych'

require_relative '../ghb'
require_relative 'auto_merge_manager'
require_relative 'aws_job_builder'
require_relative 'build_context'
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
require_relative 'vercel_job_builder'
require_relative 'workflow/workflow'

module GHB
  # Represents an instance of an application. This is the entry point for all invocations from the command line.
  class Application
    include FileScanner

    # Matrix keys that shape the expansion instead of declaring an axis.
    MATRIX_CONTROL_KEYS = %i[include exclude].freeze
    private_constant :MATRIX_CONTROL_KEYS

    # Validation keys of the service options files, derived from the SERVICES registry.
    SERVICE_CONFIG_KEYS =
      SERVICES
      .map { |service| GHB.service_config_key(service) }
      .freeze
    private_constant :SERVICE_CONFIG_KEYS

    def initialize(argv)
      @code_deploy_pre_steps = []
      @default_branch = detect_default_branch
      @exit_code = Status::SUCCESS_EXIT_CODE
      @dependencies_steps = []
      @file_cache = {}
      @auto_merge_workflow = Workflow.new('Auto-approve for code owners')
      @cron_workflow = Workflow.new('Cron Dependencies')
      @dockerhub_workflow = Workflow.new('Publish Docker image')
      @new_workflow = Workflow.new('Build')
      @old_workflow = Workflow.new('Build')
      @options = configure_options(argv)
      @required_status_checks = []
      @submodules = []
      @unit_tests_conditions = nil
      # Scope the PAT insteadOf rewrites to the owning org only. A bare
      # github.com/ rewrite would attach GH_PAT to ANY github.com URL fetched
      # later in the run (transitive git-source gems on bundle update, etc.);
      # narrowing to ${{github.repository_owner}}/ limits the token to this
      # org's own repos and shrinks the exfiltration surface. See CI-004 (#410).
      @dependencies_commands =
        <<~BASH
          git config --global --add url."https://${GH_PAT}:x-oauth-basic@github.com/${{github.repository_owner}}/".insteadOf ssh://git@github.com:${{github.repository_owner}}/
          git config --global --add url."https://${GH_PAT}:x-oauth-basic@github.com/${{github.repository_owner}}/".insteadOf https://github.com/${{github.repository_owner}}/
          git config --global --add url."https://${GH_PAT}:x-oauth-basic@github.com/${{github.repository_owner}}/".insteadOf git@github.com:${{github.repository_owner}}/

        BASH
    end

    def execute
      if @options.get_ignored_folders
        puts(JSON.pretty_generate({ ignored_folders: excluded_dirs_from_config }))
        return Status::SUCCESS_EXIT_CODE
      end

      validate_config!
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
        unit_tests_conditions: @unit_tests_conditions,
        dependencies_commands: @dependencies_commands
      )
      language_builder.build
      @code_deploy_pre_steps = language_builder.code_deploy_pre_steps
      @dependencies_steps = language_builder.dependencies_steps
      @dependencies_commands = language_builder.dependencies_commands

      collect_required_status_checks

      CodeDeployJobBuilder.new(context: context, code_deploy_pre_steps: @code_deploy_pre_steps).build

      VercelJobBuilder.new(context: context).build

      AwsJobBuilder.new(context: context).build
      SlackJobBuilder.new(context: context).build

      workflow_write

      DependabotManager.new(
        new_workflow: @new_workflow,
        cron_workflow: @cron_workflow,
        dependencies_steps: @dependencies_steps,
        dependencies_commands: @dependencies_commands
      ).save

      AutoMergeManager.new(auto_merge_workflow: @auto_merge_workflow).save
      DockerhubManager.new(dockerhub_workflow: @dockerhub_workflow).save
      GitignoreManager.new(context: context).update
      RepositoryConfigurator.new(options: @options, required_status_checks: @required_status_checks, default_branch: @default_branch).configure

      @exit_code
    end

    private

    def detect_default_branch
      branch = `git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null`.strip.sub(%r{^refs/remotes/origin/}, '')
      branch.empty? ? 'master' : branch
    end

    def configure_options(argv)
      Options.new(argv).parse
    rescue OptionParser::ParseError => e
      warn("Error: #{e}")
      exit(Status::ERROR_EXIT_CODE)
    end

    # Validates that all required config files exist, have valid YAML syntax,
    # and contain required keys (CFG-001, CFG-005)
    # @raise [ConfigError] if any config file is missing, malformed, or missing required keys
    def validate_config!
      service_config_files = SERVICES.to_h { |service| [GHB.service_config_key(service), @options.options_config_files[service]] }
      config_files = {
        linters_config: @options.linters_config_file,
        languages_config: @options.languages_config_file,
        **service_config_files,
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
      return validate_option_entries(data, relative_path) if SERVICE_CONFIG_KEYS.include?(name)

      case name
      when :linters_config
        validate_entries(data, relative_path, 'linter', %w[short_name long_name uses path pattern])
      when :languages_config
        validate_entries(data, relative_path, 'language', %w[short_name long_name])
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
              branches: [@default_branch, '[0-9]*', 'dependabot/**'],
              tags: %w[**]
            }
        }

      @new_workflow.run_name = @old_workflow.run_name unless @old_workflow.run_name.nil?
      @new_workflow.permissions =
        if @old_workflow.permissions.any?
          @old_workflow.permissions
        else
          { contents: 'read', 'pull-requests': 'read' }
        end
      @new_workflow.env = @old_workflow.env
      @new_workflow.defaults = @old_workflow.defaults || {}
      @new_workflow.concurrency =
        if @old_workflow.concurrency.any?
          @old_workflow.concurrency
        else
          # Cancel superseded full builds when a PR branch is pushed again.
          { group: 'build-${{github.ref}}', 'cancel-in-progress': true }
        end
    end

    def collect_required_status_checks
      @new_workflow.jobs.each_value do |job|
        next if job.nil?

        matrix = job.strategy.is_a?(Hash) ? job.strategy[:matrix] || job.strategy['matrix'] : nil

        if matrix.nil?
          @required_status_checks << job.name
          next
        end

        combinations = matrix_combinations(matrix)

        if combinations.nil?
          warn("Warning: cannot expand the matrix of job '#{job.name}' into check names (dynamic or non-scalar matrix values); skipping it in the required status checks.")
          next
        end

        combinations.each { |combination| @required_status_checks << "#{job.name} (#{combination.values.join(', ')})" }
      end
    end

    # Expands a job matrix into the combinations GitHub actually creates, in the
    # same order, so the generated check names match the real check-run contexts
    # (`Job (ubuntu-latest, 3.3)` rather than one name per axis value). `exclude:`
    # combinations are dropped first, then `include:` rows are merged, mirroring
    # GitHub's documented expansion (BUG-001, #474).
    # @return [Array<Hash>, nil] the combinations, or nil when the matrix cannot be expanded statically
    def matrix_combinations(matrix)
      return unless matrix.is_a?(Hash)

      matrix = symbolize_matrix_keys(matrix)
      return if matrix.nil?

      axes = matrix.except(*MATRIX_CONTROL_KEYS)
      includes = matrix_control_entries(matrix[:include])
      excludes = matrix_control_entries(matrix[:exclude])
      return if includes.nil? || excludes.nil?
      return if axes.empty? && includes.empty?
      return unless axes.all? { |_key, values| expandable_axis?(values) }

      combinations = reject_excluded(expand_axes(axes), excludes)
      apply_includes(combinations, includes, axes.keys)
    end

    def symbolize_matrix_keys(hash)
      return unless hash.keys.all? { |key| key.is_a?(Symbol) || key.is_a?(String) }

      hash.transform_keys(&:to_sym)
    end

    # @return [Array<Hash>, nil] normalized include/exclude rows, or nil when they are not statically usable
    def matrix_control_entries(entries)
      return [] if entries.nil?
      return unless entries.is_a?(Array)

      normalized = entries.map { |entry| matrix_control_entry(entry) }
      return if normalized.any?(&:nil?)

      normalized
    end

    def matrix_control_entry(entry)
      return unless entry.is_a?(Hash) && entry.any?

      normalized = symbolize_matrix_keys(entry)
      return if normalized.nil? || !normalized.each_value.all? { |value| scalar_matrix_value?(value) }

      normalized
    end

    def expandable_axis?(values)
      values.is_a?(Array) && values.any? && values.all? { |value| scalar_matrix_value?(value) }
    end

    def scalar_matrix_value?(value)
      !value.nil? && !value.is_a?(Hash) && !value.is_a?(Array)
    end

    # Cartesian product with the first axis varying slowest, matching GitHub's job order.
    # An include-only matrix has no base combination: every include row is its own job.
    def expand_axes(axes)
      return [] if axes.empty?

      axes.reduce([{}]) do |combinations, (key, values)|
        combinations.flat_map { |combination| values.map { |value| combination.merge(key => value) } }
      end
    end

    def reject_excluded(combinations, excludes)
      combinations.reject do |combination|
        excludes.any? { |exclusion| exclusion.all? { |key, value| combination.key?(key) && combination[key] == value } }
      end
    end

    # An include row is merged into every combination it does not contradict on an
    # axis key; rows that match nothing become their own combination.
    def apply_includes(combinations, includes, axis_keys)
      added = []

      includes.each do |inclusion|
        matched = false
        combinations =
          combinations.map do |combination|
            next combination unless axis_keys.all? { |key| !inclusion.key?(key) || combination[key] == inclusion[key] }

            matched = true
            combination.merge(inclusion)
          end
        added << inclusion unless matched
      end

      combinations + added
    end

    def workflow_write
      @new_workflow.write(@options.build_file, header: @options.args_comment)
    end
  end
end
