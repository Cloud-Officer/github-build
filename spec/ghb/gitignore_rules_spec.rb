# frozen_string_literal: true

RSpec.describe(GHB::GitignoreRules) do
  let(:file_cache) { {} }
  let(:submodules) { [] }
  let(:mock_options) do
    instance_double(
      GHB::Options,
      languages_config_file: 'config/languages.yaml',
      excluded_folders: []
    )
  end
  let(:rules) { described_class.new(context: GHB::BuildContext.new(options: mock_options, submodules: submodules, file_cache: file_cache)) }

  describe '#detect_gitignore_templates' do
    before do
      allow(rules).to(receive(:find_files_matching).and_return([]))
      allow(File).to(receive(:exist?).and_return(false))
    end

    it 'returns always_enabled templates' do
      config = { always_enabled: %w[linux macos windows], extension_detection: {} }

      expect(rules.detect_gitignore_templates(config)).to(eq(%w[linux macos windows]))
    end

    it 'returns sorted templates' do
      config = { always_enabled: %w[windows linux macos], extension_detection: {} }

      expect(rules.detect_gitignore_templates(config)).to(eq(%w[linux macos windows]))
    end

    it 'includes extension-detected templates when files match' do
      allow(rules).to(receive(:find_files_matching).and_return(['./app.rb']))

      config = { always_enabled: %w[linux], extension_detection: { ruby: { extensions: ['rb'] } } }

      expect(rules.detect_gitignore_templates(config)).to(include('ruby'))
    end

    it 'includes file-detected templates when specific files exist' do
      allow(File).to(receive(:exist?).with('Gemfile').and_return(true))

      config = { always_enabled: %w[linux], extension_detection: { ruby: { files: ['Gemfile'] } } }

      expect(rules.detect_gitignore_templates(config)).to(include('ruby'))
    end

    it 'handles nil always_enabled gracefully' do
      config = { always_enabled: nil, extension_detection: {} }

      expect(rules.detect_gitignore_templates(config)).to(eq([]))
    end

    it 'includes package-detected templates when package patterns match' do # rubocop:disable RSpec/ExampleLength
      allow(File).to(receive(:exist?).with('Gemfile').and_return(true))
      allow(File).to(receive(:read).and_call_original)
      allow(File).to(receive(:read).with('Gemfile').and_return("gem 'rails'\ngem 'rspec'"))

      config = {
        always_enabled: %w[linux],
        extension_detection: {
          ruby: {
            packages: { Gemfile: ['rails'] }
          }
        }
      }

      expect(rules.detect_gitignore_templates(config)).to(include('ruby'))
    end
  end

  describe '#build_gitignore_excluded_paths' do
    it 'includes excluded_folders from --excluded_folders option' do # rubocop:disable RSpec/ExampleLength
      options = instance_double(
        GHB::Options,
        languages_config_file: 'config/languages.yaml',
        excluded_folders: %w[var tmp]
      )
      rules = described_class.new(context: GHB::BuildContext.new(options: options, submodules: ['pnp-scripts'], file_cache: {}))
      allow(rules).to(receive(:excluded_dirs_from_config).and_return(['.git']))

      expect(rules.build_gitignore_excluded_paths).to(eq(%w[.git pnp-scripts var tmp]))
    end
  end

  describe '#uncomment_jetbrains_patterns' do
    it 'uncomments matching JetBrains patterns' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      content = +"# *.iml\n# modules.xml\n# .idea/misc.xml\nsomething else\n"

      rules.uncomment_jetbrains_patterns(content)

      expect(content).to(include("*.iml\n"))
      expect(content).to(include("modules.xml\n"))
      expect(content).to(include(".idea/misc.xml\n"))
      expect(content).to(include("something else\n"))
    end

    it 'does not modify non-matching lines' do
      content = +"# some-other-pattern\n*.log\n"

      rules.uncomment_jetbrains_patterns(content)

      expect(content).to(eq("# some-other-pattern\n*.log\n"))
    end

    it 'handles patterns with leading whitespace' do
      content = +"  # *.iml\n"

      rules.uncomment_jetbrains_patterns(content)

      expect(content).to(eq("*.iml\n"))
    end
  end

  describe '#comment_conflicting_patterns' do
    it 'comments out bin/, lib/, and var/' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      content = +"bin/\nlib/\nvar/\nother/\n"

      rules.comment_conflicting_patterns(content)

      expect(content).to(include("# bin/\n"))
      expect(content).to(include("# lib/\n"))
      expect(content).to(include("# var/\n"))
      expect(content).to(include("other/\n"))
    end

    it 'does not comment patterns that are substrings of longer paths' do
      content = +"mybin/\nlibrary/\n"

      rules.comment_conflicting_patterns(content)

      expect(content).to(eq("mybin/\nlibrary/\n"))
    end

    it 'does not double-comment already commented patterns' do
      content = +"# bin/\n"

      rules.comment_conflicting_patterns(content)

      expect(content).to(eq("# bin/\n"))
    end
  end

  describe '#preserve_custom_entries' do
    let(:custom_patterns) { ['# Claude Code', '.claude/', '# Cursor', '.cursor/'] }

    it 'extracts lines after "# End of" marker' do
      git_ignore = "# some content\n# End of https://www.toptal.com/developers/gitignore\n\n# My custom entry\nmy-dir/\n"

      result = rules.preserve_custom_entries(git_ignore, [])

      expect(result).to(eq(["\n", "# My custom entry\n", "my-dir/\n"]))
    end

    it 'returns empty array when no "# End of" marker is found' do
      git_ignore = "# some content\n*.log\n"

      result = rules.preserve_custom_entries(git_ignore, [])

      expect(result).to(eq([]))
    end

    it 'skips AI Assistants section with BEGIN/END markers' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      git_ignore = "# End of gitignore.io\n\n# BEGIN AI Assistants\n\n# Claude Code\n.claude/\n\n# END AI Assistants\n\n# My custom\nmy-dir/\n"

      result = rules.preserve_custom_entries(git_ignore, custom_patterns)

      expect(result).to(include("# My custom\n"))
      expect(result).to(include("my-dir/\n"))
      expect(result).not_to(include("# Claude Code\n"))
      expect(result).not_to(include(".claude/\n"))
    end

    it 'skips the Managed patterns section with BEGIN/END markers' do
      git_ignore = "# End of gitignore.io\n\n# BEGIN Managed patterns\n\n# Claude Code\n.claude/\n\n# END Managed patterns\n\n# My custom\nmy-dir/\n"

      expect(rules.preserve_custom_entries(git_ignore, custom_patterns)).to(eq(["\n", "\n", "# My custom\n", "my-dir/\n"]))
    end

    it 'skips old-style AI Assistants section without END marker' do # rubocop:disable RSpec/MultipleExpectations
      git_ignore = "# End of gitignore.io\n\n# AI Assistants\n# Claude Code\n.claude/\n# Cursor\n.cursor/\n\n# My custom\nmy-dir/\n"

      result = rules.preserve_custom_entries(git_ignore, custom_patterns)

      expect(result).not_to(include("# Claude Code\n"))
      expect(result).not_to(include(".claude/\n"))
    end

    it 'drops a hand-added copy of a managed pattern sitting outside the section' do # rubocop:disable RSpec/MultipleExpectations
      git_ignore = "# End of gitignore.io\n\n# BEGIN AI Assistants\n\n# Claude Code\n.claude/\n\n# END AI Assistants\n\n.claude/\n# My custom\nmy-dir/\n"

      result = rules.preserve_custom_entries(git_ignore, custom_patterns)

      expect(result).not_to(include(".claude/\n"))
      expect(result).to(include("my-dir/\n"))
    end

    it 'keeps an out-of-section entry that only prefix-matches a managed pattern' do
      git_ignore = "# End of gitignore.io\n\ndocs/migration/keep.md\n"

      result = rules.preserve_custom_entries(git_ignore, ['docs/migration/'])

      expect(result).to(include("docs/migration/keep.md\n"))
    end
  end

  describe '#detect_custom_pattern_groups' do
    it 'keeps each tool\'s patterns together as one group' do # rubocop:disable RSpec/ExampleLength
      config = {
        custom_patterns: {
          claudecode: { patterns: ['# Claude Code', '.claude/'] },
          claudecodeskills: { patterns: ['# Claude Code skill review artifacts', 'docs/code-review.md', 'docs/seo-audit.md'] }
        }
      }

      expect(rules.detect_custom_pattern_groups(config)).to(eq([['# Claude Code', '.claude/'], ['# Claude Code skill review artifacts', 'docs/code-review.md', 'docs/seo-audit.md']]))
    end

    it 'skips tools with no patterns' do
      config = { custom_patterns: { claudecode: { patterns: ['# Claude Code', '.claude/'] }, empty: { patterns: [] }, missing: {} } }

      expect(rules.detect_custom_pattern_groups(config)).to(eq([['# Claude Code', '.claude/']]))
    end

    it 'returns empty array when no custom_patterns configured' do
      expect(rules.detect_custom_pattern_groups({ custom_patterns: nil })).to(eq([]))
    end
  end

  describe '#validate_template!' do
    def sample
      File.binread(File.expand_path('../fixtures/gitignore_io_sample.txt', __dir__))
    end

    def header
      "# Created by https://www.toptal.com/developers/gitignore/api/ruby\n"
    end

    def footer
      "\n# End of https://www.toptal.com/developers/gitignore/api/ruby\n"
    end

    def framed(*lines)
      "#{header}#{lines.join("\n")}\n#{footer}"
    end

    def rejection(body)
      rules.validate_template!(body)
      nil
    rescue GHB::ConfigError => e
      e.message
    end

    def git_ignores?(content, path)
      Dir.mktmpdir do |dir|
        system('git', 'init', '-q', dir, exception: true)
        File.binwrite(File.join(dir, '.gitignore'), content)
        system('git', '-C', dir, 'check-ignore', '-q', '--no-index', path)
      end
    end

    it 'accepts the real gitignore.io output for this repository templates' do
      expect(rejection(sample)).to(be_nil)
    end

    it 'keeps app/main.rb tracked under the accepted sample, per git check-ignore' do
      expect(git_ignores?(sample, 'app/main.rb')).to(be(false))
    end

    it 'accepts a negated catch-all' do
      expect(rejection(framed('!*'))).to(be_nil)
    end

    it 'accepts an escaped trailing backslash' do
      expect(rejection(framed('foo\\\\'))).to(be_nil)
    end

    it 'rejects a body larger than 1 MB' do
      expect(rejection(framed(*Array.new(1100, 'x' * 1000)))).to(include('over the 1048576-byte limit'))
    end

    it 'rejects a body that is not valid UTF-8' do
      expect(rejection(framed("caf\xC3".b))).to(include('not valid UTF-8'))
    end

    ["foo\0bar", "foo\ebar"].each do |line|
      it "rejects a control character in #{line.inspect}" do
        expect(rejection(framed(line))).to(include('NUL or control characters'))
      end
    end

    ["  <div>Maintenance</div>\n", "Error\n<!DOCTYPE html>\n", "x\n<HTML lang=\"en\">\n"].each do |body|
      it "rejects an HTML body #{body.inspect}" do
        expect(rejection(body)).to(include('looks like HTML'))
      end
    end

    it 'rejects a body without the gitignore.io header line' do
      expect(rejection("*.log\n#{footer}")).to(include("missing '# Created by https://www.toptal.com/developers/gitignore/api/' header line"))
    end

    it 'rejects a body without the gitignore.io footer line' do
      expect(rejection("#{header}*.log\n")).to(include("missing '# End of https://www.toptal.com/developers/gitignore/api/' footer line"))
    end

    it 'rejects content appended after the footer line' do
      expect(rejection("#{framed('*.log')}*.rb\n")).to(include('footer line'))
    end

    it 'rejects a bare negation' do
      expect(rejection(framed('*.log', '!'))).to(include("line 3 is a bare '!'"))
    end

    it 'rejects a line longer than 1024 characters' do
      expect(rejection(framed('a' * 1025))).to(include('line 2 exceeds 1024 characters'))
    end

    it 'rejects a trailing unescaped backslash' do
      expect(rejection(framed('foo\\'))).to(include('line 2 ends with an unescaped backslash'))
    end

    %w[* ** *.* /* /** **/* */].each do |pattern|
      it "rejects the catch-all #{pattern}" do
        expect(rejection(framed(pattern))).to(include("line 2 '#{pattern}' would ignore the entire repository"))
      end

      it "confirms git ignores app/main.rb under #{pattern}" do
        expect(git_ignores?("#{pattern}\n", 'app/main.rb')).to(be(true))
      end
    end
  end

  describe 'credentials patterns shipped in config/gitignore.yaml' do
    let(:credentials_patterns) do
      config = Psych.safe_load_file(File.expand_path('../../config/gitignore.yaml', __dir__), symbolize_names: true)
      rules.detect_custom_pattern_groups(config).find { |group| group.first == '# Credentials' }
    end

    def ignored?(patterns, path)
      Dir.mktmpdir do |dir|
        system('git', 'init', '-q', dir, exception: true)
        File.write(File.join(dir, '.gitignore'), "#{patterns.join("\n")}\n")
        system('git', '-C', dir, 'check-ignore', '-q', '--no-index', path)
      end
    end

    %w[
      .env
      .env.local
      .env.production
      backend/.env
      fastlane/.env
      .envrc
      .npmrc
      .netrc
      .pypirc
      .vault_pass
      credentials
      play-service-account.json
      id_rsa
      id_ed25519
      config/master.key
      server.pem
      AuthKey_ABC123.p8
      cert.p12
      cert.pfx
      release.jks
      debug.keystore
      vault.kdbx
      putty.ppk
      App.mobileprovision
    ].each do |path|
      it "ignores #{path}" do
        expect(ignored?(credentials_patterns, path)).to(be(true))
      end
    end

    %w[
      .env.example
      .env.sample
      .env.template
      .env.dist
      .env.test
      fastlane/.env.beta
      ios/fastlane/.env.prod
      id_rsa.pub
      data/rds-combined-ca-bundle.pem
      data/aws-global-bundle.pem
      app/services/credentials.rb
      google-services.json
    ].each do |path|
      it "keeps #{path} committable" do
        expect(ignored?(credentials_patterns, path)).to(be(false))
      end
    end
  end

  describe '#detect_custom_pattern_groups flattened' do
    it 'returns patterns from config custom_patterns' do # rubocop:disable RSpec/ExampleLength
      config = {
        custom_patterns: {
          claudecode: { patterns: ['# Claude Code', '.claude/'] },
          cursor: { patterns: ['# Cursor', '.cursor/'] }
        }
      }

      expect(rules.detect_custom_pattern_groups(config).flatten).to(eq(['# Claude Code', '.claude/', '# Cursor', '.cursor/']))
    end

    it 'flattens a multi-pattern tool into the pattern list' do # rubocop:disable RSpec/ExampleLength
      config = {
        custom_patterns: {
          claudecode: { patterns: ['# Claude Code', '.claude/'] },
          claudecodeskills: { patterns: ['# Claude Code skill review artifacts', 'docs/code-review.md', 'docs/seo-audit.md'] }
        }
      }

      expect(rules.detect_custom_pattern_groups(config).flatten).to(eq(['# Claude Code', '.claude/', '# Claude Code skill review artifacts', 'docs/code-review.md', 'docs/seo-audit.md']))
    end

    it 'returns empty array when no custom_patterns configured' do
      expect(rules.detect_custom_pattern_groups({ custom_patterns: nil }).flatten).to(eq([]))
    end

    it 'returns empty array when custom_patterns is empty' do
      expect(rules.detect_custom_pattern_groups({ custom_patterns: {} }).flatten).to(eq([]))
    end
  end
end
