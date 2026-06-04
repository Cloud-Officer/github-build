# frozen_string_literal: true

RSpec.describe(GHB::LinterIgnoreRenderer) do
  let(:renderer) do
    Class.new do
      include GHB::LinterIgnoreRenderer

      public :render_excluded_dirs, :sorted_dirs
    end.new
  end

  # Deliberately unsorted, duplicated, mixed-case input to prove normalisation.
  let(:dirs) { %w[vendor node_modules Build node_modules coverage .git] }

  describe '#render_excluded_dirs' do
    it 'renders the eslint ignorePatterns as sorted glob patterns, then the eslint-only file globs' do
      content = "{\n  // ghb:excluded-dirs:start\n  \"ignorePatterns\": [\"**/old/**\"],\n  // ghb:excluded-dirs:end\n}\n"

      result = renderer.render_excluded_dirs('.eslintrc.json', content, dirs)

      expect(result).to(include('"ignorePatterns": ["**/.git/**", "**/Build/**", "**/coverage/**", "**/node_modules/**", "**/vendor/**", "**/*.workflow.js"],'))
    end

    it 'renders the flake8 extend-exclude as a sorted comma list' do
      content = "[flake8]\n# ghb:excluded-dirs:start\nextend-exclude = old\n# ghb:excluded-dirs:end\n"

      result = renderer.render_excluded_dirs('.flake8', content, dirs)

      expect(result).to(include('extend-exclude = .git,Build,coverage,node_modules,vendor'))
    end

    it 'renders the bandit exclude as a sorted comma list' do
      content = "[bandit]\n# ghb:excluded-dirs:start\nexclude: old\n# ghb:excluded-dirs:end\n"

      result = renderer.render_excluded_dirs('.bandit', content, dirs)

      expect(result).to(include('exclude: .git,Build,coverage,node_modules,vendor'))
    end

    it 'renders the yamllint ignore block as indented, slash-suffixed lines' do
      content = "ignore: |\n  # ghb:excluded-dirs:start\n  old/\n  # ghb:excluded-dirs:end\n"

      result = renderer.render_excluded_dirs('.yamllint.yml', content, dirs)

      expect(result).to(include("  .git/\n  Build/\n  coverage/\n  node_modules/\n  vendor/"))
    end

    it 'renders the pmd exclude-pattern block as path regexes' do
      content = "<ruleset>\n  <!-- ghb:excluded-dirs:start -->\n  <exclude-pattern>.*/old/.*</exclude-pattern>\n  <!-- ghb:excluded-dirs:end -->\n</ruleset>\n"

      result = renderer.render_excluded_dirs('.pmd.xml', content, dirs)

      expect(result).to(include("  <exclude-pattern>.*/.git/.*</exclude-pattern>\n  <exclude-pattern>.*/Build/.*</exclude-pattern>"))
    end

    it 'renders the semgrepignore block as gitignore-style, slash-suffixed lines' do
      content = "# deps\n# ghb:excluded-dirs:start\nold/\n# ghb:excluded-dirs:end\n"

      result = renderer.render_excluded_dirs('.semgrepignore', content, dirs)

      expect(result).to(include(".git/\nBuild/\ncoverage/\nnode_modules/\nvendor/"))
    end

    it 'renders the cfn-lint ignore_templates block as indented glob list items' do
      content = "ignore_templates:\n  # ghb:excluded-dirs:start\n  - old/**\n  # ghb:excluded-dirs:end\n"

      result = renderer.render_excluded_dirs('.cfnlintrc', content, dirs)

      expect(result).to(include("  - .git/**\n  - Build/**\n  - coverage/**\n  - node_modules/**\n  - vendor/**"))
    end

    it 'renders the swiftlint excluded block as indented list items, preserving Swift-specific extras' do
      content = "excluded:\n  - SourcePackages\n  # ghb:excluded-dirs:start\n  - old\n  # ghb:excluded-dirs:end\n"

      result = renderer.render_excluded_dirs('.swiftlint.yml', content, dirs)

      expect(result).to(include("  - SourcePackages\n  # ghb:excluded-dirs:start\n  - .git\n  - Build\n  - coverage\n  - node_modules\n  - vendor"))
    end

    it 'renders the trivy skip-dirs block as quoted, indented anywhere-globs, preserving project entries' do # rubocop:disable RSpec/MultipleExpectations
      content = %(scan:\n  skip-dirs:\n    # ghb:excluded-dirs:start\n    - "**/old"\n    # ghb:excluded-dirs:end\n    - "**/keep-me"\n)

      result = renderer.render_excluded_dirs('trivy.yaml', content, dirs)

      expect(result).to(include(%(    - "**/.git"\n    - "**/Build"\n    - "**/coverage"\n    - "**/node_modules"\n    - "**/vendor")))
      expect(result).to(include(%(    - "**/keep-me"))) # project addition outside the block survives
    end

    it 'is idempotent' do
      content = "[flake8]\n# ghb:excluded-dirs:start\nextend-exclude = old\n# ghb:excluded-dirs:end\n"

      once = renderer.render_excluded_dirs('.flake8', content, dirs)

      expect(renderer.render_excluded_dirs('.flake8', once, dirs)).to(eq(once))
    end

    it 'preserves content outside the managed block' do
      content = "[flake8]\nignore = E501\n# ghb:excluded-dirs:start\nextend-exclude = old\n# ghb:excluded-dirs:end\nmax-line-length = 120\n"
      expected = "[flake8]\nignore = E501\n# ghb:excluded-dirs:start\nextend-exclude = .git,Build,coverage,node_modules,vendor\n# ghb:excluded-dirs:end\nmax-line-length = 120\n"

      expect(renderer.render_excluded_dirs('.flake8', content, dirs)).to(eq(expected))
    end

    it 'returns content unchanged for configs it does not manage' do
      content = "AllCops:\n  NewCops: enable\n"

      expect(renderer.render_excluded_dirs('.rubocop.yml', content, dirs)).to(eq(content))
    end

    it 'returns content unchanged when the sentinels are absent' do
      content = "[flake8]\nextend-exclude = old\n"

      expect(renderer.render_excluded_dirs('.flake8', content, dirs)).to(eq(content))
    end
  end

  # Drift guard: the shipped templates must already match what copy time produces
  # for the current languages.yaml. If this fails, re-run the renderer over the
  # templates (or someone hand-edited a managed block).
  describe 'shipped linter templates' do
    let(:canonical_dirs) do
      config = Psych.safe_load(File.read('config/languages.yaml'))
      dirs = []
      config.each_value do |language|
        next unless language.is_a?(Hash) && language['dependencies']

        language['dependencies'].each { |dep| dirs.concat(Array(dep['install_dirs'])) }
      end
      dirs.concat(Array(config['excluded_dirs']))
      dirs
    end

    GHB::LinterIgnoreRenderer::FORMATS.each_key do |config_name|
      it "#{config_name} is already aligned with config/languages.yaml" do
        path = "config/linters/#{config_name}"
        content = File.read(path)

        expect(renderer.render_excluded_dirs(config_name.to_s, content, canonical_dirs)).to(eq(content))
      end
    end
  end
end
