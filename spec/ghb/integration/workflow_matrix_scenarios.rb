# frozen_string_literal: true

require 'digest'
require 'fileutils'
require 'open3'
require 'psych'
require 'rbconfig'
require 'tmpdir'

require_relative 'workflow_customizer'

module WorkflowMatrix
  ROOT = File.expand_path('../../..', __dir__)
  BIN = File.join(ROOT, 'bin/github-build.rb')
  CONFIG_DIR = File.join(ROOT, 'config')
  GOLDEN_DIR = File.join(ROOT, 'spec/fixtures/workflow_matrix')
  BUILD_FILE = '.github/workflows/build.yml'
  BASE_ARGV = %w[--organization test-org --skip_repository_settings --skip_gitignore].freeze
  PASS_LABELS = ['fresh generation', 'regeneration over a customized build.yml', 'idempotent regeneration'].freeze
  private_constant :ROOT, :BIN, :CONFIG_DIR, :GOLDEN_DIR, :BUILD_FILE, :BASE_ARGV, :PASS_LABELS

  module_function

  def scenarios
    Psych.safe_load_file(File.join(GOLDEN_DIR, 'scenarios.yml'))
  end

  def scenario_names
    scenarios.keys
  end

  def generate(name)
    scenario = scenarios[name]

    Dir.mktmpdir("ghb-matrix-#{name}") do |dir|
      write_files(dir, scenario['files'])
      passes = [run_pass(scenario, dir)]
      build_file = File.join(dir, BUILD_FILE)
      File.write(build_file, WorkflowCustomizer.customize(File.read(build_file), legacy_vercel: scenario['legacy_vercel']))
      passes << run_pass(scenario, dir)
      passes << run_pass(scenario, dir)
    end
  end

  def write_files(dir, files)
    files.each do |path, content|
      target = File.join(dir, path)
      FileUtils.mkdir_p(File.dirname(target))
      File.write(target, content)
    end
  end

  def run_pass(scenario, dir)
    env = {}
    env['BUNDLE_GEMFILE'] = File.join(ROOT, 'Gemfile')
    stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, '-rbundler/setup', BIN, *BASE_ARGV, *scenario['argv'], chdir: dir)
    build_file = File.join(dir, BUILD_FILE)
    build_yml = File.exist?(build_file) ? File.read(build_file) : ''

    { exit_code: status.exitstatus, build_yml: build_yml, output: scrub_dir(stdout + stderr, dir), tree: tree(dir) }
  end

  def scrub_dir(text, dir)
    [File.realpath(dir), dir].uniq.reduce(text) { |acc, elem| acc.gsub(elem, '<tmp>') }
  end

  def tree(dir)
    Dir.glob('**/*', File::FNM_DOTMATCH, base: dir).filter_map do |path|
      full_path = File.join(dir, path)
      next if File.directory?(full_path) && !File.symlink?(full_path)

      File.symlink?(full_path) ? "#{path} -> #{File.readlink(full_path)}" : "#{path} #{Digest::SHA256.file(full_path).hexdigest}"
    end
  end

  # Config version pins change on every update_versions run, so golden files hold a placeholder instead.
  def normalize_versions(text)
    version_pins.reduce(text) do |acc, (name, value)|
      pattern = /^(\s*)(#{Regexp.escape(name)}|#{Regexp.escape(name.upcase)}): (["']?)#{Regexp.escape(value)}\3$/
      acc.gsub(pattern, "\\1\\2: <#{name}>")
    end
  end

  def version_pins
    pins = []

    config_option_lists.each do |options|
      options.each do |option|
        next unless option.is_a?(Hash) && option['name'].to_s.include?('version') && !option['value'].nil?

        pin = [option['name'], option['value'].to_s]
        pins << pin unless pins.include?(pin)
      end
    end

    pins
  end

  def config_option_lists
    languages = Psych.safe_load_file(File.join(CONFIG_DIR, 'languages.yaml')).values.grep(Hash).map { |language| language['setup_options'] || [] }
    services = Dir.glob(File.join(CONFIG_DIR, 'options/*.yaml')).map { |path| (Psych.safe_load_file(path) || {})['options'] || [] }
    languages + services
  end

  def golden_text(passes)
    passes.each_with_index.map do |pass, index|
      tree_paths = pass[:tree].map { |entry| entry.include?(' -> ') ? entry : entry.split.first }
      "#### #{PASS_LABELS[index]}\n#{normalize_versions(pass[:build_yml])}#### files\n#{tree_paths.join("\n")}\n"
    end.join
  end

  def golden_text_for(name)
    passes = generate(name)
    failed = passes.find { |pass| pass[:exit_code] != 0 }
    raise("#{name} exited with #{failed[:exit_code]}:\n#{failed[:output]}") if failed

    golden_text(passes)
  end

  def golden(name, generated)
    path = File.join(GOLDEN_DIR, "#{name}.txt")
    File.write(path, generated) if ENV['UPDATE_SNAPSHOTS']
    raise("Missing golden file. Run with UPDATE_SNAPSHOTS=1 to create #{path}") unless File.exist?(path)

    File.read(path)
  end
end
