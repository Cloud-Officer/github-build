# frozen_string_literal: true

require 'bundler/setup'
require 'fileutils'
require 'tempfile'
require 'tmpdir'
require 'webmock/rspec'

# Load the application
require_relative '../lib/ghb'
require_relative '../lib/ghb/application'
require_relative '../lib/ghb/options'
require_relative '../lib/ghb/status'
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
