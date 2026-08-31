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
  # Single source of truth for the services whose setup options can be merged into a
  # language's Setup step. Everything per-service (default config file path, CLI flag,
  # config validation entry, YAML loading and dependency detection) is derived from this
  # list, so adding a service means adding one symbol here plus its config/options file.
  SERVICES = %i[apt mongodb mysql redis opensearch].freeze
  # Services applied to every detected language, without any dependency-file detection.
  ALWAYS_ENABLED_SERVICES = %i[apt].freeze
  # Services enabled only when a language dependency file mentions their marker string
  # (the `<service>_dependency` key in config/languages.yaml).
  DETECTABLE_SERVICES = (SERVICES - ALWAYS_ENABLED_SERVICES).freeze
  # Display names used in the `--options-<service>` help text; anything absent falls
  # back to a capitalized service name (e.g. redis -> Redis).
  SERVICE_DISPLAY_NAMES = { apt: 'APT', mongodb: 'MongoDB', mysql: 'MySQL', opensearch: 'OpenSearch' }.freeze
  DEFAULT_UBUNTU_VERSION = 'ubuntu-latest'
  DEFAULT_MACOS_VERSION = 'macos-26'
  DEFAULT_JOB_TIMEOUT_MINUTES = 30

  private_constant :CI_ACTIONS_VERSION
  private_constant :EXTERNAL_ACTIONS_CONFIG_FILE
  private_constant :DEFAULT_BUILD_FILE
  private_constant :DEFAULT_GITIGNORE_CONFIG_FILE
  private_constant :DEFAULT_LANGUAGES_CONFIG_FILE
  private_constant :DEFAULT_LINTERS_CONFIG_FILE
  private_constant :SERVICE_DISPLAY_NAMES
  private_constant :DEFAULT_UBUNTU_VERSION
  private_constant :DEFAULT_MACOS_VERSION
  public_constant :DEFAULT_JOB_TIMEOUT_MINUTES
  public_constant :SERVICES
  public_constant :ALWAYS_ENABLED_SERVICES
  public_constant :DETECTABLE_SERVICES

  # Default path of a service's options file (overridable with --options-<service>).
  def self.service_config_file(service)
    "config/options/#{service}.yaml"
  end

  # Human readable service name used in CLI help text.
  def self.service_display_name(service)
    SERVICE_DISPLAY_NAMES.fetch(service) { service.to_s.capitalize }
  end

  # Key identifying a service's options file in config validation (and its error messages).
  def self.service_config_key(service)
    :"#{service}_options"
  end

  # Key holding a service's marker string inside a language dependency entry.
  def self.service_dependency_key(service)
    :"#{service}_dependency"
  end

  # Full "owner/repo@version" ref for an external action, reading the pinned
  # version from config/actions.yaml (the single source of truth bumped by the
  # external-actions-bump cron). Raises ConfigError if the action is not listed.
  def self.external_action(name)
    actions = Psych.safe_load_file(File.expand_path("../#{EXTERNAL_ACTIONS_CONFIG_FILE}", __dir__))
    raise(ConfigError, "External action '#{name}' not found in #{EXTERNAL_ACTIONS_CONFIG_FILE}") unless actions.key?(name)

    "#{name}@#{actions[name]}"
  end
end
