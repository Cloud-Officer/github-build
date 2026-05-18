# frozen_string_literal: true

require 'open3'
require 'tmpdir'

# Integration coverage for the bin/github-build.rb rescue chain. Runs the real
# entry script as a subprocess so the GHB::ConfigError rescue (clean message on
# STDERR, exit 1, no backtrace) is exercised end-to-end. Guards against a
# regression where ConfigError becomes a RuntimeError (would still exit 1 but
# dump a noisy backtrace).
RSpec.describe('bin/github-build.rb') do # rubocop:disable RSpec/DescribeClass
  let(:script) { File.expand_path('../../bin/github-build.rb', __dir__) }

  def run_in_tmpdir(*, env: {})
    Dir.mktmpdir('ghb-bin') do |dir|
      return Open3.capture3(env, RbConfig.ruby, script, *, chdir: dir)
    end
  end

  it 'exits 1 with a clean STDERR message and no backtrace on ConfigError' do # rubocop:disable RSpec/MultipleExpectations
    stdout, stderr, status = run_in_tmpdir('--linters_config_file', 'does-not-exist.yaml', '--skip_repository_settings')

    expect(status.exitstatus).to(eq(1))
    expect(stderr).to(match(/Error: Missing required .* file: does-not-exist\.yaml/))
    expect(stdout).to(be_empty)
    expect(stderr).not_to(match(%r{lib/ghb/.*\.rb:\d+:in}))
  end

  it 'writes the error to STDERR, not STDOUT' do # rubocop:disable RSpec/MultipleExpectations
    stdout, stderr, = run_in_tmpdir('--linters_config_file', 'does-not-exist.yaml', '--skip_repository_settings')

    expect(stdout).not_to(include('Error:'))
    expect(stderr).to(include('Error:'))
  end
end
