# frozen_string_literal: true

require 'optparse'

require_relative '../ghb'
require_relative 'status'

module GHB
  class Options
    def initialize(argv = [])
      @application_name =
        if Dir.pwd.include?('service')
          Dir.pwd.split('/').last.split('-')[2]
        else
          Dir.pwd.split('/').last.split('-').last.gsub('flattening', 'worker')
        end
      @argv = argv
      @build_file = DEFAULT_BUILD_FILE
      @excluded_folders = ''
      @ignored_linters = {}
      @languages_config_file = DEFAULT_LANGUAGES_CONFIG_FILE
      @linters_config_file = DEFAULT_LINTERS_CONFIG_FILE
      @only_dependabot = false
      @options_config_file =
        {
          apt: OPTIONS_APT_CONFIG_FILE,
          mongodb: OPTIONS_MONGODB_CONFIG_FILE,
          mysql: OPTIONS_MYSQL_CONFIG_FILE,
          redis: OPTIONS_REDIS_CONFIG_FILE
        }
      @parser = OptionParser.new

      setup_parser
    end

    attr_reader :application_name, :build_file, :excluded_folders, :ignored_linters, :languages_config_file, :linters_config_file, :only_dependabot, :options_config_file

    def parse
      @parser.parse!(@argv)

      self
    end

    private

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

      @parser.on('', '--excluded_folders excluded_folders', 'Path to linters config file') do |excluded_folders|
        @excluded_folders = excluded_folders
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
        @options_config_file[:apt] = file
      end

      @parser.on('', '--options-mongodb file', 'Path to MongoDB options file') do |file|
        @options_config_file[:mongodb] = file
      end

      @parser.on('', '--options-mysql file', 'Path to MySQL options file') do |file|
        @options_config_file[:mysql] = file
      end

      @parser.on('', '--options-redis file', 'Path to Redis options file') do |file|
        @options_config_file[:redis] = file
      end

      @parser.on_tail('-h', '--help', 'Show this message') do
        puts(@parser)
        exit(Status::SUCCESS_EXIT_CODE)
      end
    end
  end
end
