# frozen_string_literal: true

require 'httparty'

require_relative 'file_scanner'

module GHB
  # Manages .gitignore file generation and updates.
  class GitignoreManager
    include FileScanner

    def initialize(options:, submodules:, file_cache:)
      @options = options
      @submodules = submodules
      @file_cache = file_cache
    end

    def update
      return if @options.skip_gitignore

      if File.exist?('.gitignore')
        puts('Updating .gitignore...')
        git_ignore = File.read('.gitignore').strip
      else
        puts('Creating .gitignore...')
        git_ignore = ''
      end

      # Load gitignore templates config
      config_path = "#{__dir__}/../../#{@options.gitignore_config_file}"
      gitignore_config = Psych.safe_load(cached_file_read(config_path))&.deep_symbolize_keys

      # Detect templates based on project files
      detected_templates = detect_gitignore_templates(gitignore_config)

      # Build API URL with detected templates
      templates_param = detected_templates.join(',')
      api_url = "https://www.toptal.com/developers/gitignore/api/#{templates_param}"

      puts("    Detected templates: #{detected_templates.join(', ')}")
      response = HTTParty.get(api_url, timeout: 30)

      raise("Cannot fetch gitignore templates: #{response.message}") unless response.code == 200

      # Skip the first line (gitignore.io header comment), default to empty string if response is empty
      new_git_ignore = response.body.to_s.split("\n", 2).last || ''

      uncomment_jetbrains_patterns(new_git_ignore)
      comment_conflicting_patterns(new_git_ignore)

      # Add AI Assistants section right after gitignore.io content
      custom_patterns = detect_custom_patterns(gitignore_config)

      unless custom_patterns.empty?
        # Group patterns into pairs (comment + pattern) and join with blank lines between sections
        grouped_patterns = custom_patterns.each_slice(2).map { |group| group.join("\n") }
        ai_section = "\n# BEGIN AI Assistants\n\n#{grouped_patterns.join("\n\n")}\n\n# END AI Assistants\n"
        new_git_ignore = "#{new_git_ignore}#{ai_section}"
        tool_names = custom_patterns.filter_map { |p| p.sub('# ', '') if p.start_with?('#') }
        puts("    Custom patterns: #{tool_names.join(', ')}")
      end

      # Preserve custom entries after "# End of" section from original gitignore
      # but skip the AI Assistants section (it was regenerated above)
      custom_lines = preserve_custom_entries(git_ignore, custom_patterns)

      content = (new_git_ignore + custom_lines.join).gsub(/\n{3,16}/, "\n\n").gsub('/bin/*', '#/bin/*').gsub('# Pods/', 'Pods/')
      File.write('.gitignore', "#{content.chomp}\n")
    end

    private

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

    def detect_gitignore_templates(config)
      templates = Set.new

      config[:always_enabled]&.each { |template| templates.add(template) }

      excluded_paths = build_gitignore_excluded_paths

      config[:extension_detection]&.each do |template_name, detection_config|
        templates.add(template_name.to_s) if template_detected?(detection_config, excluded_paths)
      end

      templates.to_a.sort
    end

    # Exclude common dependency/build folders from search - pure Ruby approach (SEC-002)
    def build_gitignore_excluded_paths
      dependency_excludes = %w[node_modules vendor .git .hg .svn venv .venv env __pycache__ .pytest_cache .bundle target build dist out Pods Carthage .build DerivedData packages .nuget .npm .yarn .pnpm bower_components jspm_packages]
      dependency_excludes + @submodules
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
  end
end
