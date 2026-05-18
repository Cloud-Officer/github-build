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

    it 'skips old-style AI Assistants section without END marker' do # rubocop:disable RSpec/MultipleExpectations
      git_ignore = "# End of gitignore.io\n\n# AI Assistants\n# Claude Code\n.claude/\n# Cursor\n.cursor/\n\n# My custom\nmy-dir/\n"

      result = rules.preserve_custom_entries(git_ignore, custom_patterns)

      expect(result).not_to(include("# Claude Code\n"))
      expect(result).not_to(include(".claude/\n"))
    end
  end

  describe '#detect_custom_patterns' do
    it 'returns patterns from config custom_patterns' do # rubocop:disable RSpec/ExampleLength
      config = {
        custom_patterns: {
          claudecode: { patterns: ['# Claude Code', '.claude/'] },
          cursor: { patterns: ['# Cursor', '.cursor/'] }
        }
      }

      expect(rules.detect_custom_patterns(config)).to(eq(['# Claude Code', '.claude/', '# Cursor', '.cursor/']))
    end

    it 'returns empty array when no custom_patterns configured' do
      expect(rules.detect_custom_patterns({ custom_patterns: nil })).to(eq([]))
    end

    it 'returns empty array when custom_patterns is empty' do
      expect(rules.detect_custom_patterns({ custom_patterns: {} })).to(eq([]))
    end
  end
end
