# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'fileutils'
require 'json'
require 'psych'

require_relative '../ghb'
require_relative 'file_scanner'
require_relative 'linter_ignore_renderer'

module GHB
  # Detects linters based on file patterns and adds linter jobs to the workflow.
  class LinterJobBuilder
    include FileScanner
    include LinterIgnoreRenderer

    REVIEWDOG_PERMISSIONS = { contents: 'read', 'pull-requests': 'write' }.freeze
    READ_ONLY_PERMISSIONS = { contents: 'read' }.freeze
    private_constant :REVIEWDOG_PERMISSIONS, :READ_ONLY_PERMISSIONS

    # reviewdog needs pull-requests: write to post review comments.
    def self.default_permissions(linter)
      (linter[:reviewdog] ? REVIEWDOG_PERMISSIONS : READ_ONLY_PERMISSIONS).dup
    end

    def initialize(context:)
      @options = context.options
      @submodules = context.submodules
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
      @file_cache = context.file_cache
    end

    def build
      puts('    Detecting linters...')
      linters = Psych.safe_load(cached_file_read("#{__dir__}/../../#{@options.linters_config_file}"))&.deep_symbolize_keys
      script_path = nil

      if File.exist?('.gitmodules')
        File.read('.gitmodules').each_line do |line|
          next unless line.include?('path = ')

          submodule_path = line.split('=', 2).last.to_s.strip
          next if submodule_path.empty?
          next unless relative_in_repo?(submodule_path)

          @submodules << submodule_path
          script_path = submodule_path if line.include?('scripts')
        end
      end

      linters&.each do |short_name, linter|
        detect_linter(short_name, linter, script_path)
      end
    end

    # Mapping of renamed config files: old name => new name
    RENAMED_CONFIGS = { '.markdownlint.yml': '.markdownlint-cli2.yaml' }.freeze
    private_constant :RENAMED_CONFIGS

    EXTENSION_RE = %r{[^/]\.[^/]*$}
    private_constant :EXTENSION_RE

    private

    def detect_linter(short_name, linter, script_path)
      if @options.ignored_linters[short_name]
        delete_linter_config(linter)
        return
      end

      if short_name == :semgrep and @options.skip_semgrep
        delete_linter_config(linter)
        return
      end

      excluded_paths = @options.excluded_folders + @submodules + [@options.linters_config_file]
      pattern = Regexp.new(linter[:pattern])
      matches = find_files_matching(linter[:path], pattern, excluded_paths)

      if linter[:content_match] && !matches.empty?
        if linter[:content_match_pattern]
          content_pattern = Regexp.new(linter[:content_match_pattern])
          matches =
            matches.select do |file|
              !file.match?(content_pattern) || file_contains?(file, linter[:content_match])
            end
        else
          matches = matches.select { |file| file_contains?(file, linter[:content_match]) }
        end
      end

      # Extensionless files pass the loose pattern; their shebang decides the language.
      if linter[:shebang_match] && !matches.empty?
        shebang_pattern = Regexp.new(linter[:shebang_match])
        matches = matches.select { |file| file.match?(EXTENSION_RE) || file_shebang_matches?(file, shebang_pattern) }
      end

      if matches.empty?
        delete_linter_config(linter)
        return
      end

      puts("        Enabling #{linter[:short_name]}...")

      copy_linter_config(linter, script_path)
      add_linter_job(short_name, linter)
    end

    def configs_for(linter)
      Array(linter[:config]).compact
    end

    # Clean up deprecated config files that were renamed
    def cleanup_renamed_configs(config_name)
      RENAMED_CONFIGS.each do |old_name, new_name|
        next if config_name != new_name.to_s
        next unless File.exist?(old_name.to_s) || File.symlink?(old_name.to_s)

        File.delete(old_name.to_s)
      end
    end

    def delete_linter_config(linter)
      configs_for(linter).each { |config_name| delete_single_config(linter, config_name) }
    end

    def delete_single_config(linter, config_name)
      return if linter[:preserve_config] && File.exist?(config_name) && !File.symlink?(config_name)

      File.delete(config_name) if File.exist?(config_name) || File.symlink?(config_name)

      cleanup_renamed_configs(config_name)
    end

    def copy_linter_config(linter, script_path)
      configs_for(linter).each { |config_name| copy_single_config(linter, config_name, script_path) }
    end

    def copy_single_config(linter, config_name, script_path)
      cleanup_renamed_configs(config_name)

      if linter[:preserve_config] && File.exist?(config_name) && !File.symlink?(config_name)
        puts("            Preserving existing #{config_name} (project-specific config)")
      elsif script_path && File.exist?("#{script_path}/linters/#{config_name}") && inside_repo?("#{script_path}/linters/#{config_name}") && config_name != '.editorconfig' && !project_owned_config?(config_name)
        FileUtils.ln_s("#{script_path}/linters/#{config_name}", config_name, force: true)
      elsif File.exist?("linters/#{config_name}") && config_name != '.editorconfig' && !project_owned_config?(config_name)
        FileUtils.ln_s("linters/#{config_name}", config_name, force: true)
      else
        atomic_copy_config(config_source(config_name), config_name) do |content|
          content = render_excluded_dirs(config_name, content, excluded_dirs_from_config) if manages?(config_name)
          content = content.sub('"sourceType": "commonjs"', '"sourceType": "module"') if config_name == '.eslintrc.json' && esm_package?

          # Uncomments only YAML list items and mapping keys so prose comments survive.
          content = content.gsub(/^(\s*)# (?=\s*(?:-\s|[^\s:#]+:(?:\s|$)))/, '\1') if config_name == '.rubocop.yml' && File.exist?('Gemfile') && File.read('Gemfile').include?('rails')

          content
        end
      end
    end

    # Node treats .js as ES modules only when package.json sets "type": "module".
    def esm_package?
      return false unless File.exist?('package.json')

      manifest = JSON.parse(File.read('package.json'))
      manifest.is_a?(Hash) && manifest['type'] == 'module'
    rescue JSON::ParserError
      false
    end

    def relative_in_repo?(path)
      !path.start_with?('/') && !path.split(%r{[/\\]}).include?('..')
    end

    def inside_repo?(path)
      root = File.expand_path(Dir.pwd)
      File.absolute_path(path, root).start_with?("#{root}/")
    end

    def project_owned_config?(config_name)
      merges_existing?(config_name) && File.exist?(config_name) && !File.symlink?(config_name) && managed_block?(File.read(config_name))
    end

    def config_source(config_name)
      bundled = "#{__dir__}/../../config/linters/#{config_name}"
      return bundled unless merges_existing?(config_name)
      return bundled unless File.exist?(config_name) && !File.symlink?(config_name)
      return bundled unless managed_block?(File.read(config_name))

      config_name
    end

    def add_linter_job(short_name, linter)
      @new_workflow.carry_job(short_name, from: @old_workflow) do |job|
        job.do_name(linter[:long_name])
        job.do_runs_on(job.carried_from&.runs_on || DEFAULT_UBUNTU_VERSION)
        job.do_needs(%w[variables])
        job.do_permissions(linter[:permissions] || LinterJobBuilder.default_permissions(linter)) if job.permissions.empty?

        if linter[:condition]
          job.do_if("${{needs.variables.outputs.SKIP_LINTERS != '1' && #{linter[:condition]}}}")
        else
          job.do_if("${{needs.variables.outputs.SKIP_LINTERS != '1'}}")
        end

        job.carry_step(linter[:short_name]) do |step|
          step.do_uses("#{linter[:uses]}@#{CI_ACTIONS_VERSION}")

          defaults = { linters: '${{needs.variables.outputs.LINTERS}}' }.merge(GHB.secrets(:ssh, :github_token))
          defaults.merge!(linter[:options]) if linter[:options]
          step.default_with(defaults)

          # Assigned, not defaulted, so older workflows carrying the PAT are upgraded on regeneration.
          step.with[:'github-token'] = '${{github.token}}'
          step.with[:'reviewdog-token'] = '${{github.token}}' if linter[:reviewdog]
        end
      end
    end
  end
end
