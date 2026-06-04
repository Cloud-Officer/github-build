# frozen_string_literal: true

require_relative 'file_scanner'
require_relative 'linter_ignore_renderer'

module GHB
  # Detects linters based on file patterns and adds linter jobs to the workflow.
  class LinterJobBuilder
    include FileScanner
    include LinterIgnoreRenderer

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

          submodule_path = line.split('=').last&.strip
          @submodules << submodule_path if submodule_path
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

    private

    def detect_linter(short_name, linter, script_path)
      if @options.ignored_linters[short_name]
        delete_linter_config(linter)
        return
      end

      if linter[:short_name].include?('Semgrep') and @options.skip_semgrep
        delete_linter_config(linter)
        return
      end

      # Pure Ruby file finding - avoids shell injection (SEC-001)
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

      if matches.empty?
        delete_linter_config(linter)
        return
      end

      result = matches.join("\n")

      puts("        Enabling #{linter[:short_name]}...")
      puts('            Found:')

      result.each_line.map(&:strip).first(5).each do |line|
        puts("              #{line}")
      end

      copy_linter_config(linter, script_path)
      add_linter_job(short_name, linter)
    end

    # A linter's `config` may be a single file name or a list of them (e.g. Trivy
    # ships both trivy.yaml and .trivyignore). Normalise to an array, dropping a
    # nil/empty config (linters like Actionlint have none).
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
      elsif File.exist?("#{script_path}/linters/#{config_name}") && config_name != '.editorconfig'
        FileUtils.ln_s("#{script_path}/linters/#{config_name}", config_name, force: true)
      elsif File.exist?("linters/#{config_name}") && config_name != '.editorconfig'
        FileUtils.ln_s("linters/#{config_name}", config_name, force: true)
      else
        # Use atomic file operation to prevent data loss if copy fails. For
        # merge-managed configs (e.g. trivy.yaml) render into the project's own
        # file so its out-of-block additions survive; otherwise copy the template.
        atomic_copy_config(config_source(config_name), config_name) do |content|
          # Keep each linter's ignore list aligned with the single source of truth
          # (excluded_dirs + install_dirs from languages.yaml).
          content = render_excluded_dirs(config_name, content, excluded_dirs_from_config) if manages?(config_name)

          # Uncomment Rails-specific rules if this is a Rails project. Only
          # un-comment commented-out YAML config (list items and mapping keys)
          # so prose comments (e.g. the MultilineMethodSignature note) survive.
          content = content.gsub(/^(\s*)# (?=\s*(?:-\s|[^\s:#]+:(?:\s|$)))/, '\1') if config_name == '.rubocop.yml' && File.exist?('Gemfile') && File.read('Gemfile').include?('rails')

          content
        end
      end
    end

    # Resolves the content source for a config: the project's existing file when
    # it is a merge-managed config already carrying our sentinel block (so custom
    # lines outside the block are preserved), otherwise the bundled template.
    def config_source(config_name)
      bundled = "#{__dir__}/../../config/linters/#{config_name}"
      return bundled unless merges_existing?(config_name)
      return bundled unless File.exist?(config_name) && !File.symlink?(config_name)
      return bundled unless managed_block?(File.read(config_name))

      config_name
    end

    def add_linter_job(short_name, linter)
      old_workflow = @old_workflow

      @new_workflow.do_job(short_name) do
        copy_properties(old_workflow.jobs[id])
        do_name(linter[:long_name])
        do_runs_on(old_workflow.jobs[short_name]&.runs_on || DEFAULT_UBUNTU_VERSION)
        do_needs(%w[variables])
        do_permissions(linter[:permissions]) if permissions.empty? and linter[:permissions]

        if linter[:condition]
          do_if("${{needs.variables.outputs.SKIP_LINTERS != '1' && #{linter[:condition]}}}")
        else
          do_if("${{needs.variables.outputs.SKIP_LINTERS != '1'}}")
        end

        do_step(linter[:short_name]) do
          copy_properties(find_step(old_workflow.jobs[short_name]&.steps, name))
          do_uses("#{linter[:uses]}@#{CI_ACTIONS_VERSION}")

          if with.empty?
            default_with =
              {
                linters: '${{needs.variables.outputs.LINTERS}}',
                'ssh-key': '${{secrets.SSH_KEY}}',
                'github-token': '${{secrets.GH_PAT}}'
              }

            default_with.merge!(linter[:options]) if linter[:options]

            do_with(default_with)
          end

          with[:'github-token'] = '${{secrets.GH_PAT}}'
        end
      end
    end
  end
end
