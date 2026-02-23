# frozen_string_literal: true

require_relative 'file_scanner'

module GHB
  # Detects linters based on file patterns and adds linter jobs to the workflow.
  class LinterJobBuilder
    include FileScanner

    def initialize(options:, submodules:, old_workflow:, new_workflow:, file_cache:)
      @options = options
      @submodules = submodules
      @old_workflow = old_workflow
      @new_workflow = new_workflow
      @file_cache = file_cache
    end

    def build
      return if @options.only_dependabot

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

    private

    def detect_linter(short_name, linter, script_path)
      return if @options.ignored_linters[short_name]

      return if linter[:short_name].include?('Semgrep') and @options.skip_semgrep

      # Pure Ruby file finding - avoids shell injection (SEC-001)
      excluded_paths = @options.excluded_folders + @submodules
      pattern = Regexp.new(linter[:pattern])
      matches = find_files_matching(linter[:path], pattern, excluded_paths)

      return if matches.empty?

      result = matches.join("\n")

      puts("        Enabling #{linter[:short_name]}...")
      puts('            Found:')

      result.each_line.map(&:strip).first(5).each do |line|
        puts("              #{line}")
      end

      copy_linter_config(linter, script_path)
      add_linter_job(short_name, linter)
    end

    def copy_linter_config(linter, script_path)
      return unless linter[:config]

      if File.exist?("#{script_path}/linters/#{linter[:config]}") && linter[:config] != '.editorconfig'
        FileUtils.ln_s("#{script_path}/linters/#{linter[:config]}", linter[:config], force: true)
      elsif linter[:preserve_config] && File.exist?(linter[:config]) && !File.symlink?(linter[:config])
        puts("            Preserving existing #{linter[:config]} (project-specific config)")
      else
        # Use atomic file operation to prevent data loss if copy fails
        atomic_copy_config("#{__dir__}/../../config/linters/#{linter[:config]}", linter[:config]) do |content|
          # Uncomment Rails-specific rules if this is a Rails project
          if linter[:config] == '.rubocop.yml' && File.exist?('Gemfile') && File.read('Gemfile').include?('rails')
            content.gsub(/^(\s*)# /, '\1')
          else
            content
          end
        end
      end
    end

    def add_linter_job(short_name, linter)
      old_workflow = @old_workflow

      @new_workflow.do_job(short_name) do
        copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
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
          copy_properties(find_step(old_workflow.jobs[short_name]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
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
