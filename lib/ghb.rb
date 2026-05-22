# frozen_string_literal: true

require 'psych'

module GHB
  # Custom error for configuration validation failures
  class ConfigError < StandardError; end

  # Custom error for failed GitHub REST API calls (carries the response body for diagnosis)
  class GitHubAPIError < StandardError; end

  CI_ACTIONS_VERSION = 'v2'
  EXTERNAL_ACTIONS_CONFIG_FILE = 'config/actions.yaml'
  DEFAULT_BUILD_FILE = '.github/workflows/build.yml'
  DEFAULT_GITIGNORE_CONFIG_FILE = 'config/gitignore.yaml'
  DEFAULT_LANGUAGES_CONFIG_FILE = 'config/languages.yaml'
  DEFAULT_LINTERS_CONFIG_FILE = 'config/linters.yaml'
  OPTIONS_APT_CONFIG_FILE = 'config/options/apt.yaml'
  OPTIONS_MONGODB_CONFIG_FILE = 'config/options/mongodb.yaml'
  OPTIONS_MYSQL_CONFIG_FILE = 'config/options/mysql.yaml'
  OPTIONS_REDIS_CONFIG_FILE = 'config/options/redis.yaml'
  OPTIONS_ELASTICSEARCH_CONFIG_FILE = 'config/options/elasticsearch.yaml'
  DEFAULT_UBUNTU_VERSION = 'ubuntu-latest'
  DEFAULT_MACOS_VERSION = 'macos-26'
  DEFAULT_JOB_TIMEOUT_MINUTES = 30

  private_constant :CI_ACTIONS_VERSION
  private_constant :EXTERNAL_ACTIONS_CONFIG_FILE
  private_constant :DEFAULT_BUILD_FILE
  private_constant :DEFAULT_GITIGNORE_CONFIG_FILE
  private_constant :DEFAULT_LANGUAGES_CONFIG_FILE
  private_constant :DEFAULT_LINTERS_CONFIG_FILE
  private_constant :OPTIONS_APT_CONFIG_FILE
  private_constant :OPTIONS_MONGODB_CONFIG_FILE
  private_constant :OPTIONS_MYSQL_CONFIG_FILE
  private_constant :OPTIONS_REDIS_CONFIG_FILE
  private_constant :OPTIONS_ELASTICSEARCH_CONFIG_FILE
  private_constant :DEFAULT_UBUNTU_VERSION
  private_constant :DEFAULT_MACOS_VERSION
  public_constant :DEFAULT_JOB_TIMEOUT_MINUTES

  # Full "owner/repo@version" ref for an external action, reading the pinned
  # version from config/actions.yaml (the single source of truth bumped by the
  # external-actions-bump cron). Raises ConfigError if the action is not listed.
  def self.external_action(name)
    actions = Psych.safe_load_file(File.expand_path("../#{EXTERNAL_ACTIONS_CONFIG_FILE}", __dir__))
    raise(ConfigError, "External action '#{name}' not found in #{EXTERNAL_ACTIONS_CONFIG_FILE}") unless actions.key?(name)

    "#{name}@#{actions[name]}"
  end
end
