# frozen_string_literal: true

require 'httparty'

require_relative 'file_scanner'
require_relative 'gitignore_rules'

module GHB
  # Manages .gitignore file generation and updates. Owns the I/O orchestration
  # (HTTP fetch + file writes); the rule logic lives in GitignoreRules.
  class GitignoreManager
    include FileScanner

    def initialize(context:, rules: GitignoreRules.new(context: context))
      @options = context.options
      @file_cache = context.file_cache
      @rules = rules
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
      detected_templates = @rules.detect_gitignore_templates(gitignore_config)

      # Build API URL with detected templates
      templates_param = detected_templates.join(',')
      api_url = "https://www.toptal.com/developers/gitignore/api/#{templates_param}"

      puts("    Detected templates: #{detected_templates.join(', ')}")

      response =
        begin
          HTTParty.get(api_url, timeout: 30)
        rescue Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, Errno::ECONNREFUSED, SocketError => e
          raise("Cannot fetch gitignore templates: #{e.class}: #{e.message}")
        end

      raise("Cannot fetch gitignore templates: #{response.message}") unless response.code == 200

      # Skip the first line (gitignore.io header comment), default to empty string if response is empty
      new_git_ignore = response.body.to_s.split("\n", 2).last || ''

      @rules.uncomment_jetbrains_patterns(new_git_ignore)
      @rules.comment_conflicting_patterns(new_git_ignore)

      # Add AI Assistants section right after gitignore.io content
      custom_patterns = @rules.detect_custom_patterns(gitignore_config)

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
      custom_lines = @rules.preserve_custom_entries(git_ignore, custom_patterns)

      content = (new_git_ignore + custom_lines.join).gsub(/\n{3,16}/, "\n\n").gsub('/bin/*', '#/bin/*').gsub('# Pods/', 'Pods/')
      File.write('.gitignore', "#{content.chomp}\n")
    end
  end
end
