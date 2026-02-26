# frozen_string_literal: true

RSpec.describe(GHB::LinterJobBuilder) do
  let(:old_workflow) { GHB::Workflow.new('Old')    }
  let(:new_workflow) { GHB::Workflow.new('Test')   }
  let(:submodules)   { []                          }
  let(:file_cache)   { {}                          }

  before do
    allow($stdout).to(receive(:puts))
  end

  describe '#build' do
    context 'when only_dependabot is true' do
      let(:options) do
        instance_double(GHB::Options, only_dependabot: true)
      end

      it 'returns early without adding jobs' do # rubocop:disable RSpec/ExampleLength
        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        builder.build

        expect(new_workflow.jobs).to(be_empty)
      end
    end

    context 'when detecting linters' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'detects linters and adds jobs to workflow' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        # Allow File.exist? to work normally for config file reads
        allow(File).to(receive(:exist?).and_call_original)
        # Mock .gitmodules as not present
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # Mock find_files_matching: return matches for rubocop pattern, empty for others
        allow(builder).to(receive(:find_files_matching)) do |_path, pattern, _excluded|
          if pattern.source.include?('Fastfile')
            ['app.rb']
          else
            []
          end
        end

        # Allow copy_linter_config internals
        allow(File).to(receive(:exist?).with('/linters/.rubocop.yml').and_return(false))
        allow(File).to(receive(:exist?).with('.rubocop.yml').and_return(false))
        allow(File).to(receive(:symlink?).and_return(false))
        allow(File).to(receive(:read).and_call_original)
        allow(File).to(receive(:write))
        allow(FileUtils).to(receive(:mv))

        builder.build

        expect(new_workflow.jobs).to(have_key(:rubocop))
        expect(new_workflow.jobs[:rubocop].name).to(eq('Ruby Linter'))
      end
    end

    context 'when a linter is in ignored_linters' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: { rubocop: true, eslint: true },
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'skips ignored linters' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # Return matches for everything to prove ignored linters are skipped
        allow(builder).to(receive(:find_files_matching).and_return(['match.txt']))
        allow(builder).to(receive(:copy_linter_config))

        builder.build

        expect(new_workflow.jobs).not_to(have_key(:rubocop))
        expect(new_workflow.jobs).not_to(have_key(:eslint))
      end
    end

    context 'when skip_semgrep is true' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: true,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'skips the semgrep linter' do # rubocop:disable RSpec/ExampleLength
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # Return matches for everything to prove semgrep is skipped
        allow(builder).to(receive(:find_files_matching).and_return(['match.txt']))
        allow(builder).to(receive(:copy_linter_config))

        builder.build

        expect(new_workflow.jobs).not_to(have_key(:semgrep))
      end
    end

    context 'when .gitmodules is present' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'populates submodules from .gitmodules file' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(true))
        allow(File).to(receive(:read).and_call_original)

        gitmodules_content = <<~GITMODULES
          [submodule "scripts"]
          \tpath = scripts-repo
          \turl = git@github.com:org/scripts.git
          [submodule "shared"]
          \tpath = shared-lib
          \turl = git@github.com:org/shared.git
        GITMODULES
        allow(File).to(receive(:read).with('.gitmodules').and_return(gitmodules_content))

        local_submodules = []

        builder = described_class.new(
          options: options,
          submodules: local_submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        allow(builder).to(receive(:find_files_matching).and_return([]))

        builder.build

        expect(local_submodules).to(include('scripts-repo'))
        expect(local_submodules).to(include('shared-lib'))
      end
    end

    context 'when a linter has a condition' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'includes the condition in the job if statement' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # Only match eslint pattern (js files)
        allow(builder).to(receive(:find_files_matching)) do |_path, pattern, _excluded|
          if pattern.source.include?('js')
            ['app.js']
          else
            []
          end
        end

        allow(builder).to(receive(:copy_linter_config))

        builder.build

        expect(new_workflow.jobs).to(have_key(:eslint))

        job = new_workflow.jobs[:eslint]
        expect(job.if).to(include("needs.variables.outputs.SKIP_LINTERS != '1'"))
        expect(job.if).to(include("github.event_name == 'pull_request'"))
      end
    end

    context 'when a linter has preserve_config and config already exists' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'preserves the existing config file' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))
        allow(File).to(receive(:symlink?).and_return(false))
        allow(File).to(receive(:write))
        allow(File).to(receive(:delete))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # Only match semgrep pattern
        allow(builder).to(receive(:find_files_matching)) do |_path, pattern, _excluded|
          if pattern.source.include?('swift') && pattern.source.include?('py')
            ['app.py']
          else
            []
          end
        end

        # Semgrep config is .semgrepignore with preserve_config: true
        # No script_path (no .gitmodules), so script_path is nil
        # File.exist?("#{nil}/linters/.semgrepignore") should be false
        allow(File).to(receive(:exist?).with('/linters/.semgrepignore').and_return(false))
        # The config file exists and is NOT a symlink -> preserve
        allow(File).to(receive(:exist?).with('.semgrepignore').and_return(true))
        allow(File).to(receive(:symlink?).with('.semgrepignore').and_return(false))

        builder.build

        expect(new_workflow.jobs).to(have_key(:semgrep))
        # Config should be preserved - no write or mv should happen for the config
        expect(File).not_to(have_received(:write))
      end
    end

    context 'when a linter has options' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'merges linter options into the default_with hash' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        # Create a custom linters config with options field
        custom_linters_config = {
          custom_linter: {
            short_name: 'CustomLinter',
            long_name: 'Custom Test Linter',
            uses: 'cloud-officer/ci-actions/linters/custom',
            config: nil,
            path: '.',
            pattern: '.*\\.(custom)$',
            options: { 'extra-flag': 'true', 'custom-param': 'value' }
          }
        }
        custom_linters_yaml = Psych.dump(custom_linters_config.deep_stringify_keys)

        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: {}
        )

        # Override cached_file_read to return our custom config
        allow(builder).to(receive(:cached_file_read).and_return(custom_linters_yaml))

        allow(builder).to(receive(:find_files_matching)) do |_path, pattern, _excluded|
          if pattern.source.include?('custom')
            ['test.custom']
          else
            []
          end
        end

        builder.build

        expect(new_workflow.jobs).to(have_key(:custom_linter))

        job = new_workflow.jobs[:custom_linter]
        step = job.steps.first
        expect(step.with).to(have_key(:'extra-flag'))
        expect(step.with[:'extra-flag']).to(eq('true'))
        expect(step.with).to(have_key(:'custom-param'))
        expect(step.with[:'custom-param']).to(eq('value'))
      end
    end

    context 'when rubocop config is copied for a Rails project' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'uncomments Rails-specific rules in .rubocop.yml' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # Only match rubocop pattern (Fastfile)
        allow(builder).to(receive(:find_files_matching)) do |_path, pattern, _excluded|
          if pattern.source.include?('Fastfile')
            ['Fastfile']
          else
            []
          end
        end

        # No script_path, no preserve_config -> falls through to atomic_copy_config
        allow(File).to(receive(:exist?).with('/linters/.rubocop.yml').and_return(false))
        allow(File).to(receive(:exist?).with('.rubocop.yml').and_return(false))

        # Rails project detection
        allow(File).to(receive(:exist?).with('Gemfile').and_return(true))
        allow(File).to(receive(:read).and_call_original)
        allow(File).to(receive(:read).with('Gemfile').and_return("gem 'rails'\n"))

        # atomic_copy_config internals
        rubocop_content = "# AllCops:\n#   TargetRailsVersion: 7.0\n"
        allow(File).to(receive(:read).with(%r{config/linters/\.rubocop\.yml}).and_return(rubocop_content))
        allow(File).to(receive(:write))
        allow(FileUtils).to(receive(:mv))

        builder.build

        expect(new_workflow.jobs).to(have_key(:rubocop))
        # The transformation block should have uncommented the Rails rules
        expect(File).to(have_received(:write).with(anything, "AllCops:\n  TargetRailsVersion: 7.0\n"))
      end
    end

    context 'when linter is not enabled (no matches) and has a config file' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'deletes the stale config file' do # rubocop:disable RSpec/ExampleLength
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))
        allow(File).to(receive(:symlink?).and_return(false))
        allow(File).to(receive(:delete))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # No files match any linter
        allow(builder).to(receive(:find_files_matching).and_return([]))

        # Stale config exists on disk
        allow(File).to(receive(:exist?).with('.eslintrc.json').and_return(true))

        builder.build

        expect(File).to(have_received(:delete).with('.eslintrc.json'))
      end
    end

    context 'when linter is ignored and has a config file' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: { eslint: true },
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'deletes the config file for the ignored linter' do # rubocop:disable RSpec/ExampleLength
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))
        allow(File).to(receive(:symlink?).and_return(false))
        allow(File).to(receive(:delete))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # Return matches for non-ignored linters so they proceed normally
        allow(builder).to(receive(:find_files_matching).and_return([]))

        # Stale config for eslint exists on disk
        allow(File).to(receive(:exist?).with('.eslintrc.json').and_return(true))

        builder.build

        expect(File).to(have_received(:delete).with('.eslintrc.json'))
      end
    end

    context 'when linter has preserve_config and config is user-owned' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'does not delete the config file' do # rubocop:disable RSpec/ExampleLength
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(false))
        allow(File).to(receive(:symlink?).and_return(false))
        allow(File).to(receive(:delete))

        builder = described_class.new(
          options: options,
          submodules: submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # No files match any linter pattern
        allow(builder).to(receive(:find_files_matching).and_return([]))

        # Semgrep has preserve_config: true; its config exists and is NOT a symlink
        allow(File).to(receive(:exist?).with('.semgrepignore').and_return(true))

        builder.build

        expect(File).not_to(have_received(:delete).with('.semgrepignore'))
      end
    end

    context 'when script_path has the linter config file' do
      let(:options) do
        instance_double(
          GHB::Options,
          only_dependabot: false,
          skip_semgrep: false,
          ignored_linters: {},
          excluded_folders: [],
          linters_config_file: 'config/linters.yaml'
        )
      end

      it 'creates a symlink from script_path instead of copying' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        allow(File).to(receive(:exist?).and_call_original)
        allow(File).to(receive(:exist?).with('.gitmodules').and_return(true))
        allow(File).to(receive(:read).and_call_original)

        gitmodules_content = <<~GITMODULES
          [submodule "scripts"]
          \tpath = scripts-repo
          \turl = git@github.com:org/scripts.git
        GITMODULES
        allow(File).to(receive(:read).with('.gitmodules').and_return(gitmodules_content))

        local_submodules = []

        builder = described_class.new(
          options: options,
          submodules: local_submodules,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          file_cache: file_cache
        )

        # Only match golangci pattern (go files)
        allow(builder).to(receive(:find_files_matching)) do |_path, pattern, _excluded|
          if pattern.source.include?('go')
            ['main.go']
          else
            []
          end
        end

        # script_path will be 'scripts-repo' (contains 'scripts')
        # Config file is .golangci.yml
        allow(File).to(receive(:exist?).with('scripts-repo/linters/.golangci.yml').and_return(true))
        allow(FileUtils).to(receive(:ln_s))

        builder.build

        expect(new_workflow.jobs).to(have_key(:golangci))
        expect(FileUtils).to(have_received(:ln_s).with('scripts-repo/linters/.golangci.yml', '.golangci.yml', force: true))
      end
    end
  end
end
