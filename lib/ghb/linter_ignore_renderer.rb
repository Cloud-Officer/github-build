# frozen_string_literal: true

module GHB
  # Renders the canonical excluded-directory list (the same set FileScanner uses,
  # from config/languages.yaml) into each linter config's native ignore syntax.
  #
  # Each managed config carries a sentinel-delimited block:
  #
  #   <comment> ghb:excluded-dirs:start
  #   ...generated lines...
  #   <comment> ghb:excluded-dirs:end
  #
  # so a single source of truth keeps every linter config aligned. Configs without
  # the sentinels (or that we don't manage) are returned unchanged.
  module LinterIgnoreRenderer
    SENTINEL_START = 'ghb:excluded-dirs:start'
    SENTINEL_END = 'ghb:excluded-dirs:end'
    private_constant :SENTINEL_START, :SENTINEL_END

    # Matches the managed block: captures the start-sentinel line and the
    # end-sentinel line, with the regenerated body going between them.
    SENTINEL_PATTERN = /(.*#{Regexp.escape(SENTINEL_START)}.*\n)(?:.*\n)*?(.*#{Regexp.escape(SENTINEL_END)}.*)/
    private_constant :SENTINEL_PATTERN

    # config file name (as symbol) => body renderer for its native syntax
    FORMATS = {
      '.eslintrc.json': :body_eslint,
      '.flake8': :body_flake8,
      '.bandit': :body_bandit,
      '.yamllint.yml': :body_yamllint,
      '.pmd.xml': :body_pmd
    }.freeze
    public_constant :FORMATS

    # @param config_name [String] linter config file name
    # @return [Boolean] true if this config has a managed excluded-dirs block
    def manages?(config_name)
      FORMATS.key?(config_name.to_sym)
    end

    # Replace the managed block in `content` with `dirs` rendered for `config_name`.
    # @param config_name [String] linter config file name (e.g. '.eslintrc.json')
    # @param content [String] current config file content
    # @param dirs [Array<String>] canonical excluded directory names
    # @return [String] content with the managed block regenerated (or unchanged)
    def render_excluded_dirs(config_name, content, dirs)
      renderer = FORMATS[config_name.to_sym]
      return content unless renderer
      return content unless content.include?(SENTINEL_START) && content.include?(SENTINEL_END)

      body = __send__(renderer, sorted_dirs(dirs))
      replace_between_sentinels(content, body)
    end

    private

    def sorted_dirs(dirs)
      dirs.uniq.sort_by(&:downcase)
    end

    # Replaces every line strictly between the start and end sentinel lines with
    # `body`, preserving the sentinel lines themselves (and their indentation).
    def replace_between_sentinels(content, body)
      content.sub(SENTINEL_PATTERN) { "#{Regexp.last_match(1)}#{body}\n#{Regexp.last_match(2)}" }
    end

    def body_eslint(dirs)
      patterns = dirs.map { |dir| %("**/#{dir}/**") }
      %(  "ignorePatterns": [#{patterns.join(', ')}],)
    end

    def body_flake8(dirs)
      "extend-exclude = #{dirs.join(',')}"
    end

    def body_bandit(dirs)
      "exclude: #{dirs.join(',')}"
    end

    def body_yamllint(dirs)
      lines = dirs.map { |dir| "  #{dir}/" }
      lines.join("\n")
    end

    def body_pmd(dirs)
      lines = dirs.map { |dir| "  <exclude-pattern>.*/#{dir}/.*</exclude-pattern>" }
      lines.join("\n")
    end
  end
end
