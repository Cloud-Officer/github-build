# frozen_string_literal: true

require 'open3'

# Expression evaluated in the child process => the output it must print once the
# library is required by the file under test.
LIBRARY_PROBES = {
  active_support: ['({}.respond_to?(:deep_symbolize_keys) && {}.respond_to?(:deep_stringify_keys)).to_s', 'true'],
  fileutils: ['defined?(FileUtils).to_s', 'constant'],
  psych: ['defined?(Psych).to_s', 'constant']
}.freeze

# Every lib file that calls FileUtils, Psych or the ActiveSupport hash core
# extensions, mapped to the libraries it must require itself.
GUARDED_FILES = {
  dependabot_manager: %i[fileutils],
  file_scanner: %i[active_support fileutils psych],
  gitignore_manager: %i[active_support psych],
  language_job_builder: %i[active_support psych],
  linter_job_builder: %i[active_support fileutils psych],
  repository_configurator: %i[psych],
  'workflow/workflow': %i[active_support psych]
}.freeze

# Regression guard for BUG-009 (FileUtils) and CON-004 (Psych / ActiveSupport):
# files that use a library must require it themselves rather than relying on a
# transitive require from application.rb or workflow.rb.
#
# Each file is loaded in a fresh Ruby process (no spec_helper, no transitive
# requires) and asserted to provide every library it calls. Without the explicit
# require a standalone load raises NameError on the first FileUtils/Psych call
# and NoMethodError on the first deep_symbolize_keys call; with it the library is
# present as soon as the file is loaded.
RSpec.describe('explicit library requires (BUG-009, CON-004)') do # rubocop:disable RSpec/DescribeClass
  # Runs `preamble` then prints one probe result per library, comma separated.
  def capture_probes(libraries, preamble = '')
    expressions = libraries.map { |library| LIBRARY_PROBES[library].first }
    script = "#{preamble}print [#{expressions.join(', ')}].join(',')"
    Open3.capture3(RbConfig.ruby, '-e', script)
  end

  def expected_probes(libraries)
    outputs = libraries.map { |library| LIBRARY_PROBES[library].last }
    outputs.join(',')
  end

  GUARDED_FILES.each do |file, libraries|
    it "provides #{libraries.join(', ')} after loading #{file}.rb in isolation" do # rubocop:disable RSpec/MultipleExpectations
      path = File.expand_path("../../lib/ghb/#{file}.rb", __dir__)
      stdout, stderr, status = capture_probes(libraries, "require #{path.inspect}; ")

      expect(status).to(be_success, "load failed: #{stderr}")
      expect(stdout).to(eq(expected_probes(libraries)))
    end
  end

  # Control: proves the probes above actually detect a missing require, i.e. the
  # child process does not get these libraries for free from Ruby or Bundler.
  it 'reports every library as missing when nothing is required' do # rubocop:disable RSpec/MultipleExpectations
    stdout, stderr, status = capture_probes(LIBRARY_PROBES.keys)

    expect(status).to(be_success, "probe failed: #{stderr}")
    expect(stdout).to(eq('false,,'))
  end
end
