# frozen_string_literal: true

require 'simplecov'
SimpleCov.start do
  add_filter '/spec/'
  enable_coverage :branch
  minimum_coverage line: 80, branch: 80
end

require 'bundler/setup'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require 'webmock/rspec'

# Load the application
require_relative '../lib/ghb'
require_relative '../lib/ghb/application'
require_relative '../lib/ghb/aws_job_builder'
require_relative '../lib/ghb/code_deploy_job_builder'
require_relative '../lib/ghb/dependabot_manager'
require_relative '../lib/ghb/dockerhub_manager'
require_relative '../lib/ghb/file_scanner'
require_relative '../lib/ghb/github_api_client'
require_relative '../lib/ghb/gitignore_manager'
require_relative '../lib/ghb/language_job_builder'
require_relative '../lib/ghb/licenses_job_builder'
require_relative '../lib/ghb/linter_job_builder'
require_relative '../lib/ghb/options'
require_relative '../lib/ghb/repository_configurator'
require_relative '../lib/ghb/slack_job_builder'
require_relative '../lib/ghb/status'
require_relative '../lib/ghb/variables_job_builder'
require_relative '../lib/ghb/workflow/job'
require_relative '../lib/ghb/workflow/step'
require_relative '../lib/ghb/workflow/workflow'

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = '.rspec_status'

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  # Run specs in random order to surface order dependencies
  config.order = :random
  Kernel.srand(config.seed)

  config.expect_with(:rspec) do |c|
    c.syntax = :expect
  end

  # Disable external HTTP requests by default
  WebMock.disable_net_connect!(allow_localhost: true)
end
