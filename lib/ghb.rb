# frozen_string_literal: true

module GHB
  DEFAULT_BUILD_FILE = '.github/workflows/build.yml'
  DEFAULT_LANGUAGES_CONFIG_FILE = 'config/languages.yaml'
  DEFAULT_LINTERS_CONFIG_FILE = 'config/linters.yaml'
  OPTIONS_APT_CONFIG_FILE = 'config/options/apt.yaml'
  OPTIONS_MONGODB_CONFIG_FILE = 'config/options/mongodb.yaml'
  OPTIONS_MYSQL_CONFIG_FILE = 'config/options/mysql.yaml'
  OPTIONS_REDIS_CONFIG_FILE = 'config/options/redis.yaml'
  DEFAULT_UBUNTU_VERSION = 'ubuntu-latest'
  DEFAULT_MACOS_VERSION = 'macos-latest'

  private_constant :DEFAULT_BUILD_FILE
  private_constant :DEFAULT_LANGUAGES_CONFIG_FILE
  private_constant :DEFAULT_LINTERS_CONFIG_FILE
  private_constant :OPTIONS_APT_CONFIG_FILE
  private_constant :OPTIONS_MONGODB_CONFIG_FILE
  private_constant :OPTIONS_MYSQL_CONFIG_FILE
  private_constant :OPTIONS_REDIS_CONFIG_FILE
  private_constant :DEFAULT_UBUNTU_VERSION
  private_constant :DEFAULT_MACOS_VERSION
end
