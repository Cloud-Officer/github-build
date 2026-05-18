# frozen_string_literal: true

RSpec.describe(GHB::GitignoreManager) do
  let(:mock_options) do
    instance_double(
      GHB::Options,
      skip_gitignore: false,
      gitignore_config_file: 'config/gitignore.yaml',
      languages_config_file: 'config/languages.yaml',
      excluded_folders: []
    )
  end
  let(:gitignore_rules) do
    GHB::GitignoreRules.new(context: GHB::BuildContext.new(options: mock_options, submodules: [], file_cache: {}))
  end
  let(:manager) do
    described_class.new(context: GHB::BuildContext.new(options: mock_options, submodules: [], file_cache: {}), rules: gitignore_rules)
  end

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
      skip_manager = described_class.new(context: GHB::BuildContext.new(options: skip_options, submodules: [], file_cache: {}))

      allow(File).to(receive(:exist?).with('.gitignore'))

      skip_manager.update

      expect(File).not_to(have_received(:exist?).with('.gitignore'))
    end

    it 'creates a new .gitignore when none exists' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      config_yaml = Psych.dump(minimal_gitignore_config.deep_stringify_keys)

      allow(manager).to(receive(:cached_file_read).and_return(config_yaml))

      allow(gitignore_rules).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
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

      allow(manager).to(receive(:cached_file_read).and_return(config_yaml))

      allow(gitignore_rules).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
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

      allow(manager).to(receive(:cached_file_read).and_return(config_yaml))

      allow(gitignore_rules).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
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

      allow(manager).to(receive(:cached_file_read).and_return(config_yaml))

      allow(gitignore_rules).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
      allow(File).to(receive(:exist?).with('.gitignore').and_return(false))
      allow(File).to(receive(:exist?).with(anything).and_return(false))

      api_response = double('HTTParty::Response', code: 500, message: 'Internal Server Error') # rubocop:disable RSpec/VerifiedDoubles
      allow(HTTParty).to(receive(:get).with(anything, timeout: 30).and_return(api_response))

      expect { manager.update }
        .to(raise_error(RuntimeError, /Cannot fetch gitignore templates/))
    end

    [503, 504].each do |status|
      it "raises a clear error on a #{status} response" do # rubocop:disable RSpec/ExampleLength
        config_yaml = Psych.dump(minimal_gitignore_config.deep_stringify_keys)

        allow(manager).to(receive(:cached_file_read).and_return(config_yaml))

        allow(gitignore_rules).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
        allow(File).to(receive(:exist?).with('.gitignore').and_return(false))
        allow(File).to(receive(:exist?).with(anything).and_return(false))

        api_response = double('HTTParty::Response', code: status, message: 'Service Unavailable') # rubocop:disable RSpec/VerifiedDoubles
        allow(HTTParty).to(receive(:get).with(anything, timeout: 30).and_return(api_response))

        expect { manager.update }
          .to(raise_error(RuntimeError, /Cannot fetch gitignore templates/))
      end
    end

    [Net::OpenTimeout, Net::ReadTimeout, Errno::ECONNRESET, SocketError].each do |error|
      it "wraps a transient #{error} into an actionable error instead of a raw stack trace" do # rubocop:disable RSpec/ExampleLength
        config_yaml = Psych.dump(minimal_gitignore_config.deep_stringify_keys)

        allow(manager).to(receive(:cached_file_read).and_return(config_yaml))

        allow(gitignore_rules).to(receive_messages(cached_file_read: config_yaml, find_files_matching: []))
        allow(File).to(receive(:exist?).with('.gitignore').and_return(false))
        allow(File).to(receive(:exist?).with(anything).and_return(false))
        allow(HTTParty).to(receive(:get).with(anything, timeout: 30).and_raise(error))

        expect { manager.update }
          .to(raise_error(RuntimeError, /Cannot fetch gitignore templates: #{error}/))
      end
    end
  end
end
