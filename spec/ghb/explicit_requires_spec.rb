# frozen_string_literal: true

require 'open3'

# library => [expression evaluated in the child process, output it must print]
LIBRARY_PROBES = {
  active_support: ['({}.respond_to?(:deep_symbolize_keys) && {}.respond_to?(:deep_stringify_keys)).to_s', 'true'],
  deep_dup: ['Object.new.respond_to?(:deep_dup).to_s', 'true'],
  fileutils: ['defined?(FileUtils).to_s', 'constant'],
  ghb_root: ['defined?(GHB.secrets).to_s', 'method'],
  psych: ['defined?(Psych).to_s', 'constant']
}.freeze

GUARDED_FILES = {
  application: %i[ghb_root psych],
  auto_approve_manager: %i[fileutils ghb_root],
  aws_job_builder: %i[ghb_root],
  code_deploy_job_builder: %i[ghb_root],
  dependabot_manager: %i[fileutils],
  docker_build_job_builder: %i[ghb_root],
  dockerhub_manager: %i[ghb_root],
  file_scanner: %i[active_support fileutils psych],
  gitignore_manager: %i[active_support psych],
  language_job_builder: %i[active_support deep_dup ghb_root psych],
  licenses_job_builder: %i[ghb_root],
  linter_job_builder: %i[active_support fileutils ghb_root psych],
  options: %i[ghb_root],
  repository_configurator: %i[ghb_root psych],
  slack_job_builder: %i[ghb_root],
  variables_job_builder: %i[ghb_root],
  vercel_job_builder: %i[ghb_root],
  'workflow/step': %i[deep_dup],
  'workflow/workflow': %i[active_support fileutils ghb_root psych]
}.freeze

# Source markers that mean a file uses each guarded library.
LIBRARY_USAGE = {
  active_support: /deep_symbolize_keys|deep_stringify_keys|deep_merge/,
  deep_dup: /deep_dup/,
  fileutils: /FileUtils\./,
  ghb_root: /DEFAULT_UBUNTU_VERSION|CI_ACTIONS_VERSION|GHB\./,
  psych: /Psych\./
}.freeze

RSpec.describe('explicit library requires') do # rubocop:disable RSpec/DescribeClass
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

  it 'lists every lib file that uses a guarded library' do # rubocop:disable RSpec/ExampleLength
    lib_root = File.expand_path('../../lib/ghb', __dir__)
    actual =
      Dir.glob("#{lib_root}/**/*.rb").to_h do |path|
        source = File.read(path)
        key = path.delete_prefix("#{lib_root}/").delete_suffix('.rb')
        [
          key,
          LIBRARY_USAGE.select { |_library, marker| source.match?(marker) }
                       .keys.sort
        ]
      end
    actual.reject! { |_key, libraries| libraries.empty? }
    expected = GUARDED_FILES.to_h { |file, libraries| [file.to_s, libraries.sort] }

    expect(actual).to(eq(expected))
  end

  it 'reports every library as missing when nothing is required' do # rubocop:disable RSpec/MultipleExpectations
    stdout, stderr, status = capture_probes(LIBRARY_PROBES.keys)

    expect(status).to(be_success, "probe failed: #{stderr}")
    expect(stdout).to(eq('false,false,,,'))
  end
end
