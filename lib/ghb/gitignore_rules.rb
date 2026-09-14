# frozen_string_literal: true

require_relative 'file_scanner'

module GHB
  # Pure rule logic for .gitignore generation: template detection, excluded-path
  # building, and content transforms. Extracted from GitignoreManager so the
  # logic has a public, directly-testable API while GitignoreManager retains the
  # I/O orchestration (HTTP fetch + file writes).
  class GitignoreRules
    include FileScanner

    MANAGED_SECTION_BEGIN = '# BEGIN Managed patterns'
    MANAGED_SECTION_END = '# END Managed patterns'
    LEGACY_SECTION_BEGIN_MARKERS = ['# BEGIN AI Assistants', '# AI Assistants'].freeze
    LEGACY_SECTION_END = '# END AI Assistants'
    TEMPLATE_MAX_BYTES = 1_048_576
    TEMPLATE_MAX_LINE_LENGTH = 1024
    TEMPLATE_HEADER_PREFIX = '# Created by https://www.toptal.com/developers/gitignore/api/'
    TEMPLATE_FOOTER_PREFIX = '# End of https://www.toptal.com/developers/gitignore/api/'
    TEMPLATE_CONTROL_CHARACTERS = /[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/
    TEMPLATE_HTML = /\A\s*<|<html|<!doctype/i
    CATCH_ALL_PATTERNS = %w[* ** *.* **/*].freeze
    public_constant :MANAGED_SECTION_BEGIN, :MANAGED_SECTION_END
    private_constant :LEGACY_SECTION_BEGIN_MARKERS, :LEGACY_SECTION_END
    private_constant :TEMPLATE_MAX_BYTES, :TEMPLATE_MAX_LINE_LENGTH, :TEMPLATE_HEADER_PREFIX, :TEMPLATE_FOOTER_PREFIX
    private_constant :TEMPLATE_CONTROL_CHARACTERS, :TEMPLATE_HTML, :CATCH_ALL_PATTERNS

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
      in_managed_section = false
      custom_lines = []

      git_ignore.each_line do |line|
        if line.include?('# End of ')
          found = true
          next
        end

        if line.include?(MANAGED_SECTION_BEGIN) || LEGACY_SECTION_BEGIN_MARKERS.any? { |marker| line.include?(marker) }
          in_managed_section = true
          next
        end

        if line.include?(MANAGED_SECTION_END) || line.include?(LEGACY_SECTION_END)
          in_managed_section = false
          next
        end

        # Skip managed patterns inside an old-style section that has no END marker
        next if in_managed_section && custom_patterns.any? { |pattern| line.start_with?(pattern) }

        # Drop a hand-added copy of a now-managed pattern sitting outside the section:
        # the regenerated block is the single source of truth, so preserving the stray
        # line would emit it twice. Exact match only, so docs/migration/keep.md survives
        # even though docs/migration/ is managed.
        next if found && !in_managed_section && custom_patterns.include?(line.strip)

        custom_lines << line if found && !in_managed_section
      end

      custom_lines
    end

    # Patterns kept grouped per tool, so a tool contributing several ignore rules
    # renders as one commented block instead of being split into arbitrary pairs.
    def detect_custom_pattern_groups(config)
      groups = []

      # Always include all custom patterns to prevent accidental commits
      # even if the tool isn't detected (developer may start using it later)
      config[:custom_patterns]&.each_value do |tool_config|
        patterns = tool_config[:patterns]

        groups << patterns unless patterns.nil? || patterns.empty?
      end

      groups
    end

    def validate_template!(body)
      text = body.to_s.dup.force_encoding(Encoding::UTF_8)
      error = template_body_error(text) || template_framing_error(text.lines(chomp: true)) || template_lines_error(text.lines(chomp: true))

      raise(ConfigError, "Refusing gitignore.io response, .gitignore left unchanged: #{error}") if error
    end

    private

    def template_body_error(text)
      return "body is #{text.bytesize} bytes, over the #{TEMPLATE_MAX_BYTES}-byte limit" if text.bytesize > TEMPLATE_MAX_BYTES
      return 'body is not valid UTF-8' unless text.valid_encoding?
      return 'body contains NUL or control characters' if text.match?(TEMPLATE_CONTROL_CHARACTERS)

      'body looks like HTML, not a gitignore template' if text.match?(TEMPLATE_HTML)
    end

    def template_framing_error(lines)
      return "missing '#{TEMPLATE_HEADER_PREFIX}' header line" unless lines.first.to_s.start_with?(TEMPLATE_HEADER_PREFIX)

      content_lines = lines.reject { |line| line.strip.empty? }

      "missing '#{TEMPLATE_FOOTER_PREFIX}' footer line" unless content_lines.last.to_s.start_with?(TEMPLATE_FOOTER_PREFIX)
    end

    def template_lines_error(lines)
      index = lines.index { |line| template_line_error(line) }

      "line #{index + 1} #{template_line_error(lines[index])}" if index
    end

    def template_line_error(line)
      return if line.strip.empty? || line.start_with?('#')
      return "is a bare '!'" if line.rstrip == '!'
      return "exceeds #{TEMPLATE_MAX_LINE_LENGTH} characters" if line.length > TEMPLATE_MAX_LINE_LENGTH
      return 'ends with an unescaped backslash' if line[/\\+\z/].to_s.length.odd?

      "'#{line.strip}' would ignore the entire repository" if catch_all_pattern?(line)
    end

    def catch_all_pattern?(line)
      !line.start_with?('!') && CATCH_ALL_PATTERNS.include?(line.rstrip.gsub(%r{\A/+|/+\z}, ''))
    end

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
