# frozen_string_literal: true

require 'optparse'

require_relative '../ghb'
require_relative 'status'

module GHB
  class Options
    ARGS_COMMENT_PREFIX = '# github-build'
    # Flags that are one-shot in nature and must not be persisted to the generated workflow header.
    EPHEMERAL_FLAGS = %w[--sync_required_status_checks].freeze
    # Flags removed from the CLI that may still linger in a downstream repo's persisted build.yml header.
    # They are stripped (with a warning) during persisted-args replay so old headers self-heal on the next
    # regeneration instead of aborting on OptionParser::InvalidOption.
    REMOVED_FLAGS = %w[--mono_repo].freeze
    private_constant :ARGS_COMMENT_PREFIX
    private_constant :EPHEMERAL_FLAGS
    private_constant :REMOVED_FLAGS

    def initialize(argv = [])
      @application_name = Dir.pwd.split('/').last.split('-').last
      @argv = argv.empty? ? args_from_file(DEFAULT_BUILD_FILE) : argv.dup
      @original_argv = @argv.reject { |arg| EPHEMERAL_FLAGS.include?(arg) }
      @build_file = DEFAULT_BUILD_FILE
      @excluded_folders = []
      @force_codedeploy_setup = false
      @gitignore_config_file = DEFAULT_GITIGNORE_CONFIG_FILE
      @ignored_linters = {}
      @languages_config_file = DEFAULT_LANGUAGES_CONFIG_FILE
      @linters_config_file = DEFAULT_LINTERS_CONFIG_FILE
      @options_config_files = SERVICES.to_h { |service| [service, GHB.service_config_file(service)] }
      @organization = Dir.pwd.split('/')[-2]
      @parser = OptionParser.new
      @skip_semgrep = false
      @skip_gitignore = false
      @skip_license_check = false
      @skip_repository_settings = false
      @get_ignored_folders = false
      @skip_slack = false
      @strict_version_check = true
      @sync_required_status_checks = false

      setup_parser
    end

    attr_reader :application_name, :build_file, :excluded_folders, :force_codedeploy_setup, :get_ignored_folders, :gitignore_config_file, :ignored_linters, :languages_config_file, :linters_config_file, :options_config_files, :organization, :original_argv, :skip_gitignore, :skip_license_check, :skip_repository_settings, :skip_semgrep, :skip_slack, :strict_version_check, :sync_required_status_checks

    # Path of a single service's options file, e.g. options_config_file(:mysql).
    def options_config_file(service)
      @options_config_files[service]
    end

    def parse
      @parser.parse!(@argv)

      self
    end

    def args_comment
      return '' if @original_argv.empty?

      "#{ARGS_COMMENT_PREFIX} #{@original_argv.join(' ')}\n"
    end

    private

    def args_from_file(file)
      return [] unless File.exist?(file)

      first_line = File.foreach(file).first&.strip
      return [] if first_line.nil? || !first_line.start_with?(ARGS_COMMENT_PREFIX)

      args_string = first_line.sub(ARGS_COMMENT_PREFIX, '').strip
      require('shellwords')
      strip_removed_flags(Shellwords.split(args_string), file)
    rescue ArgumentError => e
      raise(ConfigError, "Malformed github-build args in #{file}: #{e.message}")
    end

    # Drops flags that no longer exist from persisted args so replay tolerates removed options.
    # Each dropped flag is reported on stderr; because it never reaches @argv/@original_argv,
    # the regenerated build.yml header self-heals (the flag disappears on the next run).
    def strip_removed_flags(args, file)
      removed, kept = args.partition { |arg| removed_flag?(arg) }
      removed.each do |arg|
        warn("Warning: ignoring removed option '#{arg.split('=').first}' from #{file} header; it will be dropped on the next regeneration")
      end
      kept
    end

    def removed_flag?(arg)
      REMOVED_FLAGS.any? { |flag| arg == flag || arg.start_with?("#{flag}=") }
    end

    def setup_parser
      @parser.banner = 'Usage: github-build options'
      @parser.separator('')
      @parser.separator('options')

      setup_path_options
      setup_behavior_options
      setup_skip_options

      @parser.on_tail('-h', '--help', 'Show this message') do
        puts(@parser)
        exit(Status::SUCCESS_EXIT_CODE)
      end
    end

    # File / config path overrides.
    def setup_path_options
      @parser.on('', '--build_file file', 'Path to build file') do |file|
        @build_file = file
      end

      @parser.on('', '--excluded_folders excluded_folders', 'Comma separated list of folders to ignore') do |excluded_folders|
        @excluded_folders = excluded_folders.split(',').reject(&:empty?)
      end

      @parser.on('', '--gitignore_config_file file', 'Path to gitignore config file') do |file|
        @gitignore_config_file = file
      end

      @parser.on('', '--languages_config_file file', 'Path to languages config file') do |file|
        @languages_config_file = file
      end

      @parser.on('', '--linters_config_file file', 'Path to linters config file') do |file|
        @linters_config_file = file
      end

      setup_service_options
    end

    # One --options-<service> path override per SERVICES registry entry.
    def setup_service_options
      SERVICES.each do |service|
        @parser.on('', "--options-#{service} file", "Path to #{GHB.service_display_name(service)} options file") do |file|
          @options_config_files[service] = file
        end
      end
    end

    # Identity and behavior toggles.
    def setup_behavior_options
      @parser.on('', '--application_name application_name', 'Name of the CodeDeploy application') do |application_name|
        @application_name = application_name
      end

      @parser.on('', '--organization organization', 'GitHub organization') do |organization|
        @organization = organization
      end

      @parser.on('', '--force_codedeploy_setup', 'Force executing the setup step in CodeDeploy even if not technically required') do
        @force_codedeploy_setup = true
      end

      @parser.on('', '--get_ignored_folders', 'Output ignored folders as JSON and exit') do
        @get_ignored_folders = true
      end

      @parser.on('', '--ignored_linters ignored_linters', 'Ignore linter keys in linter config file') do |ignored_linters|
        ignored_linters.split(',').each do |key|
          @ignored_linters[key.to_sym] = true
        end
      end

      @parser.on('', '--no_strict_version_check', 'Do not auto-update when VERSION options do not match recommended defaults') do
        @strict_version_check = false
      end

      @parser.on('', '--sync_required_status_checks', 'On branch protection check mismatch, overwrite remote check list with the expected one instead of erroring (useful when renaming jobs/matrix values)') do
        @sync_required_status_checks = true
      end
    end

    # Skip flags.
    def setup_skip_options
      @parser.on('', '--skip_semgrep', 'Skip Semgrep') do
        @skip_semgrep = true
      end

      @parser.on('', '--skip_gitignore', 'Skip update of gitignore file') do
        @skip_gitignore = true
      end

      @parser.on('', '--skip_license_check', 'Skip license check') do
        @skip_license_check = true
      end

      @parser.on('', '--skip_repository_settings', 'Skip check of repository settings') do
        @skip_repository_settings = true
      end

      @parser.on('', '--skip_slack', 'Skip slack') do
        @skip_slack = true
      end
    end
  end
end
