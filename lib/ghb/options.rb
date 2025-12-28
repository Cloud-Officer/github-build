# frozen_string_literal: true

require 'optparse'

require_relative '../ghb'
require_relative 'status'

module GHB
  class Options
    ARGS_COMMENT_PREFIX = '# github-build'
    private_constant :ARGS_COMMENT_PREFIX

    def initialize(argv = [])
      @application_name = Dir.pwd.split('/').last.split('-').last
      @argv = argv.empty? ? args_from_file(DEFAULT_BUILD_FILE) : argv.dup
      @original_argv = @argv.dup
      @build_file = DEFAULT_BUILD_FILE
      @excluded_folders = []
      @force_codedeploy_setup = false
      @gitignore_config_file = DEFAULT_GITIGNORE_CONFIG_FILE
      @ignored_linters = {}
      @languages_config_file = DEFAULT_LANGUAGES_CONFIG_FILE
      @linters_config_file = DEFAULT_LINTERS_CONFIG_FILE
      @only_dependabot = false
      @options_config_file_apt = OPTIONS_APT_CONFIG_FILE
      @options_config_file_mongodb = OPTIONS_MONGODB_CONFIG_FILE
      @options_config_file_mysql = OPTIONS_MYSQL_CONFIG_FILE
      @options_config_file_redis = OPTIONS_REDIS_CONFIG_FILE
      @organization = Dir.pwd.split('/')[-2]
      @parser = OptionParser.new
      @skip_dependabot = false
      @skip_semgrep = false
      @skip_gitignore = false
      @skip_license_check = false
      @skip_repository_settings = false
      @skip_slack = false
      @strict_version_check = true

      setup_parser
    end

    attr_reader :application_name, :build_file, :excluded_folders, :force_codedeploy_setup, :gitignore_config_file, :ignored_linters, :languages_config_file, :linters_config_file, :only_dependabot, :options_config_file_apt, :options_config_file_mongodb, :options_config_file_mysql, :options_config_file_redis, :organization, :original_argv, :skip_dependabot, :skip_gitignore, :skip_license_check, :skip_repository_settings, :skip_semgrep, :skip_slack, :strict_version_check

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

      first_line = File.open(file, &:readline).strip
      return [] unless first_line.start_with?(ARGS_COMMENT_PREFIX)

      args_string = first_line.sub(ARGS_COMMENT_PREFIX, '').strip
      require('shellwords')
      Shellwords.split(args_string)
    rescue EOFError
      []
    end

    def setup_parser
      @parser.banner = 'Usage: github-build options'
      @parser.separator('')
      @parser.separator('options')

      @parser.on('', '--application_name application_name', 'Name of the CodeDeploy application') do |application_name|
        @application_name = application_name
      end

      @parser.on('', '--build_file file', 'Path to build file') do |file|
        @build_file = file
      end

      @parser.on('', '--excluded_folders excluded_folders', 'Comma separated list of folders to ignore') do |excluded_folders|
        @excluded_folders = excluded_folders.split(',')
      end

      @parser.on('', '--force_codedeploy_setup', 'Force executing the setup step in CodeDeploy even if not technically required') do
        @force_codedeploy_setup = true
      end

      @parser.on('', '--gitignore_config_file file', 'Path to gitignore config file') do |file|
        @gitignore_config_file = file
      end

      @parser.on('', '--ignored_linters ignored_linters', 'Ignore linter keys in linter config file') do |ignored_linters|
        ignored_linters.split(',').each do |key|
          @ignored_linters[key.to_sym] = true
        end
      end

      @parser.on('', '--languages_config_file file', 'Path to languages config file') do |file|
        @languages_config_file = file
      end

      @parser.on('', '--linters_config_file file', 'Path to linters config file') do |file|
        @linters_config_file = file
      end

      @parser.on('', '--only_dependabot', 'Just do Dependabot and nothing else') do
        @only_dependabot = true
      end

      @parser.on('', '--options-apt file', 'Path to APT options file') do |file|
        @options_config_file_apt = file
      end

      @parser.on('', '--options-mongodb file', 'Path to MongoDB options file') do |file|
        @options_config_file_mongodb = file
      end

      @parser.on('', '--options-mysql file', 'Path to MySQL options file') do |file|
        @options_config_file_mysql = file
      end

      @parser.on('', '--options-redis file', 'Path to Redis options file') do |file|
        @options_config_file_redis = file
      end

      @parser.on('', '--organization organization', 'GitHub organization') do |organization|
        @organization = organization
      end

      @parser.on('', '--skip_semgrep', 'Skip Semgrep') do
        @skip_semgrep = true
      end

      @parser.on('', '--skip_dependabot', 'Skip dependabot') do
        @skip_dependabot = true
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

      @parser.on('', '--no_strict_version_check', 'Do not exit with error when VERSION options do not match recommended defaults') do
        @strict_version_check = false
      end

      @parser.on_tail('-h', '--help', 'Show this message') do
        puts(@parser)
        exit(Status::SUCCESS_EXIT_CODE)
      end
    end
  end
end
