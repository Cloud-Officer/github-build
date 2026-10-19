# frozen_string_literal: true

module GHB
  # Renders the excluded-dirs list into the sentinel-delimited block of each linter config.
  module LinterIgnoreRenderer
    SENTINEL_START = 'ghb:excluded-dirs:start'
    SENTINEL_END = 'ghb:excluded-dirs:end'
    private_constant :SENTINEL_START, :SENTINEL_END

    SENTINEL_PATTERN = /(.*#{Regexp.escape(SENTINEL_START)}.*\n)(?:.*\n)*?(.*#{Regexp.escape(SENTINEL_END)}.*)/
    private_constant :SENTINEL_PATTERN

    # Workflow DSL scripts mix a top-level export and return, which no ESLint parser mode accepts.
    ESLINT_EXTRA_IGNORES = ['**/*.workflow.js'].freeze
    private_constant :ESLINT_EXTRA_IGNORES

    # config file name (as symbol) => body renderer for its native syntax
    FORMATS = {
      '.eslintrc.json': :body_eslint,
      '.flake8': :body_flake8,
      '.bandit': :body_bandit,
      '.yamllint.yml': :body_yamllint,
      '.pmd.xml': :body_pmd,
      '.semgrepignore': :body_semgrepignore,
      '.cfnlintrc': :body_cfnlint,
      '.swiftlint.yml': :body_swiftlint,
      '.markdownlint-cli2.yaml': :body_markdownlint,
      'trivy.yaml': :body_trivy
    }.freeze
    public_constant :FORMATS

    MERGE_EXISTING_CONFIGS = %i[trivy.yaml].freeze
    public_constant :MERGE_EXISTING_CONFIGS

    def manages?(config_name)
      FORMATS.key?(config_name.to_sym)
    end

    def merges_existing?(config_name)
      MERGE_EXISTING_CONFIGS.include?(config_name.to_sym)
    end

    def managed_block?(content)
      content.include?(SENTINEL_START) && content.include?(SENTINEL_END)
    end

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

    def replace_between_sentinels(content, body)
      content.sub(SENTINEL_PATTERN) { "#{Regexp.last_match(1)}#{body}\n#{Regexp.last_match(2)}" }
    end

    def body_eslint(dirs)
      patterns = dirs.map { |dir| %("**/#{dir}/**") }
      patterns.concat(ESLINT_EXTRA_IGNORES.map { |glob| %("#{glob}") })
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

    # Semgrep reads .semgrepignore as gitignore-style patterns, one per line.
    def body_semgrepignore(dirs)
      lines = dirs.map { |dir| "#{dir}/" }
      lines.join("\n")
    end

    def body_cfnlint(dirs)
      lines = dirs.map { |dir| "  - #{dir}/**" }
      lines.join("\n")
    end

    def body_swiftlint(dirs)
      # Quoted because a leading `*` would make the scalar a YAML alias.
      lines = dirs.map { |dir| %(  - "**/#{dir}") }
      lines.join("\n")
    end

    # Quoted because a leading `!` would open a YAML tag.
    def body_markdownlint(dirs)
      lines = dirs.map { |dir| %(  - "!**/#{dir}/**") }
      lines.join("\n")
    end

    # Quoted because a leading `*` would make the scalar a YAML alias.
    def body_trivy(dirs)
      lines = dirs.map { |dir| %(    - "**/#{dir}") }
      lines.join("\n")
    end
  end
end
