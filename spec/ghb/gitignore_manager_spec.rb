# frozen_string_literal: true

RSpec.describe(GHB::GitignoreManager) do
  let(:file_cache) { {} }
  let(:submodules) { [] }
  let(:mock_options) do
    instance_double(
      GHB::Options,
      skip_gitignore: false,
      gitignore_config_file: 'config/gitignore.yaml'
    )
  end
  let(:manager) { described_class.new(options: mock_options, submodules: submodules, file_cache: file_cache) }

  let(:minimal_gitignore_config) do
    {
      always_enabled: %w[linux macos windows],
      extension_detection: {},
      custom_patterns: {
        claudecode: {
          patterns: ['# Claude Code', '.claude/']
        },
        cursor: {
          patterns: ['# Cursor', '.cursor/']
        }
      }
    }
  end

  describe '#update' do
    it 'returns early when skip_gitignore is true' do
      skip_options = instance_double(GHB::Options, skip_gitignore: true)
      skip_manager = described_class.new(options: skip_options, submodules: [], file_cache: {})

      allow(File).to(receive(:exist?).with('.gitignore'))

      skip_manager.update

      expect(File).not_to(have_received(:exist?).with('.gitignore'))
    end

    it 'creates a new .gitignore when none exists' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      config_yaml = Psych.dump(minimal_gitignore_config.deep_stringify_keys)

      allow(manager).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
      allow(File).to(receive(:exist?).with('.gitignore').and_return(false))
      allow(File).to(receive(:exist?).with(anything).and_return(false))

      api_response = instance_double(HTTParty::Response, code: 200, body: "# Created by gitignore.io\n# Edit at gitignore.io\n\n### Linux ###\n*~\n")
      allow(HTTParty).to(receive(:get).with(anything, timeout: 30).and_return(api_response))

      written_content = nil
      allow(File).to(receive(:write).with('.gitignore', anything)) do |_path, content|
        written_content = content
      end

      manager.update

      expect(written_content).not_to(be_nil)
      expect(written_content).to(include('Linux'))
    end

    it 'updates an existing .gitignore and preserves custom entries' do # rubocop:disable RSpec/ExampleLength
      existing_gitignore = +"# Created by gitignore.io\n# End of gitignore.io\n\n# My custom pattern\nmy-custom-dir/\n"
      config_yaml = Psych.dump(minimal_gitignore_config.deep_stringify_keys)

      allow(manager).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
      allow(File).to(receive(:exist?).and_return(false))
      allow(File).to(receive(:exist?).with('.gitignore').and_return(true))
      allow(File).to(receive(:read).with('.gitignore').and_return(existing_gitignore))

      api_response = instance_double(HTTParty::Response, code: 200, body: "# Created by gitignore.io\n# Edit at gitignore.io\n\n### Linux ###\n*~\n# End of gitignore.io\n")
      allow(HTTParty).to(receive(:get).with(anything, timeout: 30).and_return(api_response))

      written_content = nil
      allow(File).to(receive(:write).with('.gitignore', anything)) do |_path, content|
        written_content = content
      end

      manager.update

      expect(written_content).to(include('my-custom-dir/'))
    end

    it 'does not add AI section when custom_patterns returns empty array' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      config_without_custom = {
        always_enabled: %w[linux macos windows],
        extension_detection: {},
        custom_patterns: {}
      }
      config_yaml = Psych.dump(config_without_custom.deep_stringify_keys)

      allow(manager).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
      allow(File).to(receive(:exist?).with('.gitignore').and_return(false))
      allow(File).to(receive(:exist?).with(anything).and_return(false))

      api_response = instance_double(HTTParty::Response, code: 200, body: "# Created by gitignore.io\n# Edit at gitignore.io\n\n### Linux ###\n*~\n")
      allow(HTTParty).to(receive(:get).with(anything, timeout: 30).and_return(api_response))

      written_content = nil
      allow(File).to(receive(:write).with('.gitignore', anything)) do |_path, content|
        written_content = content
      end

      manager.update

      expect(written_content).not_to(be_nil)
      expect(written_content).not_to(include('AI Assistants'))
    end

    it 'raises an error when the API returns a non-200 response' do # rubocop:disable RSpec/ExampleLength
      config_yaml = Psych.dump(minimal_gitignore_config.deep_stringify_keys)

      allow(manager).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
      allow(File).to(receive(:exist?).with('.gitignore').and_return(false))
      allow(File).to(receive(:exist?).with(anything).and_return(false))

      api_response = double('HTTParty::Response', code: 500, message: 'Internal Server Error') # rubocop:disable RSpec/VerifiedDoubles
      allow(HTTParty).to(receive(:get).with(anything, timeout: 30).and_return(api_response))

      expect { manager.update }
        .to(raise_error(RuntimeError, /Cannot fetch gitignore templates/))
    end
  end

  describe '#detect_gitignore_templates (private)' do
    before do
      allow(manager).to(receive(:find_files_matching).and_return([]))
      allow(File).to(receive(:exist?).and_return(false))
    end

    it 'returns always_enabled templates' do
      config = { always_enabled: %w[linux macos windows], extension_detection: {} }

      result = manager.__send__(:detect_gitignore_templates, config)

      expect(result).to(eq(%w[linux macos windows]))
    end

    it 'returns sorted templates' do
      config = { always_enabled: %w[windows linux macos], extension_detection: {} }

      result = manager.__send__(:detect_gitignore_templates, config)

      expect(result).to(eq(%w[linux macos windows]))
    end

    it 'includes extension-detected templates when files match' do
      allow(manager).to(receive(:find_files_matching).and_return(['./app.rb']))

      config = { always_enabled: %w[linux], extension_detection: { ruby: { extensions: ['rb'] } } }

      result = manager.__send__(:detect_gitignore_templates, config)

      expect(result).to(include('ruby'))
    end

    it 'includes file-detected templates when specific files exist' do
      allow(File).to(receive(:exist?).with('Gemfile').and_return(true))

      config = { always_enabled: %w[linux], extension_detection: { ruby: { files: ['Gemfile'] } } }

      result = manager.__send__(:detect_gitignore_templates, config)

      expect(result).to(include('ruby'))
    end

    it 'handles nil always_enabled gracefully' do
      config = { always_enabled: nil, extension_detection: {} }

      result = manager.__send__(:detect_gitignore_templates, config)

      expect(result).to(eq([]))
    end

    it 'includes package-detected templates when package patterns match' do # rubocop:disable RSpec/ExampleLength
      allow(File).to(receive(:exist?).with('Gemfile').and_return(true))
      allow(File).to(receive(:read).with('Gemfile').and_return("gem 'rails'\ngem 'rspec'"))

      config = {
        always_enabled: %w[linux],
        extension_detection: {
          ruby: {
            packages: { Gemfile: ['rails'] }
          }
        }
      }

      result = manager.__send__(:detect_gitignore_templates, config)

      expect(result).to(include('ruby'))
    end
  end

  describe '#uncomment_jetbrains_patterns (private)' do
    it 'uncomments matching JetBrains patterns' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      content = +"# *.iml\n# modules.xml\n# .idea/misc.xml\nsomething else\n"

      manager.__send__(:uncomment_jetbrains_patterns, content)

      expect(content).to(include("*.iml\n"))
      expect(content).to(include("modules.xml\n"))
      expect(content).to(include(".idea/misc.xml\n"))
      expect(content).to(include("something else\n"))
    end

    it 'does not modify non-matching lines' do
      content = +"# some-other-pattern\n*.log\n"

      manager.__send__(:uncomment_jetbrains_patterns, content)

      expect(content).to(eq("# some-other-pattern\n*.log\n"))
    end

    it 'handles patterns with leading whitespace' do
      content = +"  # *.iml\n"

      manager.__send__(:uncomment_jetbrains_patterns, content)

      expect(content).to(eq("*.iml\n"))
    end
  end

  describe '#comment_conflicting_patterns (private)' do
    it 'comments out bin/, lib/, and var/' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      content = +"bin/\nlib/\nvar/\nother/\n"

      manager.__send__(:comment_conflicting_patterns, content)

      expect(content).to(include("# bin/\n"))
      expect(content).to(include("# lib/\n"))
      expect(content).to(include("# var/\n"))
      expect(content).to(include("other/\n"))
    end

    it 'does not comment patterns that are substrings of longer paths' do
      content = +"mybin/\nlibrary/\n"

      manager.__send__(:comment_conflicting_patterns, content)

      expect(content).to(eq("mybin/\nlibrary/\n"))
    end

    it 'does not double-comment already commented patterns' do
      content = +"# bin/\n"

      manager.__send__(:comment_conflicting_patterns, content)

      expect(content).to(eq("# bin/\n"))
    end
  end

  describe '#preserve_custom_entries (private)' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    let(:custom_patterns) { ['# Claude Code', '.claude/', '# Cursor', '.cursor/'] }

    it 'extracts lines after "# End of" marker' do
      git_ignore = "# some content\n# End of https://www.toptal.com/developers/gitignore\n\n# My custom entry\nmy-dir/\n"

      result = manager.__send__(:preserve_custom_entries, git_ignore, [])

      expect(result).to(eq(["\n", "# My custom entry\n", "my-dir/\n"]))
    end

    it 'returns empty array when no "# End of" marker is found' do
      git_ignore = "# some content\n*.log\n"

      result = manager.__send__(:preserve_custom_entries, git_ignore, [])

      expect(result).to(eq([]))
    end

    it 'skips AI Assistants section with BEGIN/END markers' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      git_ignore = "# End of gitignore.io\n\n# BEGIN AI Assistants\n\n# Claude Code\n.claude/\n\n# END AI Assistants\n\n# My custom\nmy-dir/\n"

      result = manager.__send__(:preserve_custom_entries, git_ignore, custom_patterns)

      expect(result).to(include("# My custom\n"))
      expect(result).to(include("my-dir/\n"))
      expect(result).not_to(include("# Claude Code\n"))
      expect(result).not_to(include(".claude/\n"))
    end

    it 'skips old-style AI Assistants section without END marker' do # rubocop:disable RSpec/MultipleExpectations
      git_ignore = "# End of gitignore.io\n\n# AI Assistants\n# Claude Code\n.claude/\n# Cursor\n.cursor/\n\n# My custom\nmy-dir/\n"

      result = manager.__send__(:preserve_custom_entries, git_ignore, custom_patterns)

      expect(result).not_to(include("# Claude Code\n"))
      expect(result).not_to(include(".claude/\n"))
    end
  end

  describe '#detect_custom_patterns (private)' do
    it 'returns patterns from config custom_patterns' do # rubocop:disable RSpec/ExampleLength
      config = {
        custom_patterns: {
          claudecode: { patterns: ['# Claude Code', '.claude/'] },
          cursor: { patterns: ['# Cursor', '.cursor/'] }
        }
      }

      result = manager.__send__(:detect_custom_patterns, config)

      expect(result).to(eq(['# Claude Code', '.claude/', '# Cursor', '.cursor/']))
    end

    it 'returns empty array when no custom_patterns configured' do
      result = manager.__send__(:detect_custom_patterns, { custom_patterns: nil })

      expect(result).to(eq([]))
    end

    it 'returns empty array when custom_patterns is empty' do
      result = manager.__send__(:detect_custom_patterns, { custom_patterns: {} })

      expect(result).to(eq([]))
    end
  end
end
