# frozen_string_literal: true

require_relative 'file_scanner'

module GHB
  # Pure rule logic for .gitignore generation: template detection, excluded-path
  # building, and content transforms. Extracted from GitignoreManager so the
  # logic has a public, directly-testable API while GitignoreManager retains the
  # I/O orchestration (HTTP fetch + file writes).
  class GitignoreRules
    include FileScanner

    def initialize(context:)
      @options = context.options
      @submodules = context.submodules
      @file_cache = context.file_cache
    end

    def detect_gitignore_templates(config)
      templates = Set.new

      config[:always_enabled]&.each { |template| templates.add(template) }

      excluded_paths = build_gitignore_excluded_paths

      config[:extension_detection]&.each do |template_name, detection_config|
        templates.add(template_name.to_s) if template_detected?(detection_config, excluded_paths)
      end

      templates.to_a.sort
    end

    # Build excluded paths from languages.yaml config + submodules + --excluded_folders (SEC-002)
    def build_gitignore_excluded_paths
      excluded_dirs_from_config + @submodules + @options.excluded_folders
    end

    # Uncomment specific lines if present (for JetBrains IDE compatibility)
    def uncomment_jetbrains_patterns(content)
      patterns = %w[*.iml modules.xml .idea/misc.xml *.ipr auto-import. .idea/artifacts .idea/compiler.xml .idea/jarRepositories.xml .idea/modules.xml .idea/*.iml .idea/modules]

      patterns.each do |pattern|
        regex = Regexp.new("^\\s*#\\s*(#{Regexp.escape(pattern)})")
        content.gsub!(regex, '\\1')
      end
    end

    # Comment out specific directory patterns that conflict with common project directories
    def comment_conflicting_patterns(content)
      %w[bin/ lib/ var/].each do |dir_pattern|
        content.gsub!(/^#{Regexp.escape(dir_pattern)}$/, "# #{dir_pattern}")
      end
    end

    def preserve_custom_entries(git_ignore, custom_patterns)
      found = false
      in_ai_section = false
      custom_lines = []

      git_ignore.each_line do |line|
        if line.include?('# End of ')
          found = true
          next
        end

        if line.include?('# BEGIN AI Assistants') || line.include?('# AI Assistants')
          in_ai_section = true
          next
        end

        if line.include?('# END AI Assistants')
          in_ai_section = false
          next
        end

        # Skip individual AI tool patterns when in old-style AI section (no END marker)
        next if in_ai_section && custom_patterns.any? { |pattern| line.start_with?(pattern) }

        custom_lines << line if found && !in_ai_section
      end

      custom_lines
    end

    def detect_custom_patterns(config)
      patterns = []

      # Always include all custom patterns to prevent accidental commits
      # even if the tool isn't detected (developer may start using it later)
      config[:custom_patterns]&.each_value do |tool_config|
        tool_config[:patterns]&.each do |pattern|
          patterns << pattern
        end
      end

      patterns
    end

    private

    def template_detected?(detection_config, excluded_paths)
      extension_detected?(detection_config[:extensions], excluded_paths) ||
        file_detected?(detection_config[:files]) ||
        package_detected?(detection_config[:packages])
    end

    # Check for file extensions - pure Ruby (SEC-002)
    def extension_detected?(extensions, excluded_paths)
      return false if extensions.nil?

      extensions.any? do |ext|
        pattern = Regexp.new("\\.#{Regexp.escape(ext)}$")
        find_files_matching('.', pattern, excluded_paths, max_depth: 5).any?
      end
    end

    def file_detected?(files)
      return false if files.nil?

      files.any? { |file| File.exist?(file) }
    end

    # Check for packages in package manager files - pure Ruby regex (SEC-002)
    def package_detected?(packages)
      return false if packages.nil?

      packages.any? do |pm_file, pkg_patterns|
        next false unless File.exist?(pm_file.to_s)

        file_content = File.read(pm_file.to_s)
        pkg_patterns.any? { |pkg| file_content.match?(Regexp.new(pkg)) }
      end
    end
  end
end
