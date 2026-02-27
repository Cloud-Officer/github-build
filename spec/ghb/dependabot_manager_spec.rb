# frozen_string_literal: true

RSpec.describe(GHB::DependabotManager) do
  let(:new_workflow)          { GHB::Workflow.new('Test') }
  let(:cron_workflow)         { GHB::Workflow.new('Cron') }
  let(:dependencies_steps)    { []                        }
  let(:dependencies_commands) { ''                        }

  before do
    allow($stdout).to(receive(:puts))
  end

  describe '#save' do
    context 'when dependabot.yml exists' do
      it 'removes the dependabot config file' do # rubocop:disable RSpec/ExampleLength
        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(true))
        allow(FileUtils).to(receive(:rm_f))

        manager = described_class.new(
          new_workflow: new_workflow,
          cron_workflow: cron_workflow,
          dependencies_steps: dependencies_steps,
          dependencies_commands: dependencies_commands
        )

        manager.save

        expect(FileUtils).to(have_received(:rm_f).with('.github/dependabot.yml'))
      end
    end

    context 'when there is no licenses job' do
      it 'removes the dependencies.yml workflow' do # rubocop:disable RSpec/ExampleLength
        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(false))
        allow(FileUtils).to(receive(:rm_f))

        manager = described_class.new(
          new_workflow: new_workflow,
          cron_workflow: cron_workflow,
          dependencies_steps: dependencies_steps,
          dependencies_commands: dependencies_commands
        )

        manager.save

        expect(FileUtils).to(have_received(:rm_f).with('.github/workflows/dependencies.yml'))
      end
    end

    context 'when licenses job exists and dependency steps are present' do
      it 'saves the dependencies workflow' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        # Add a licenses job to the workflow
        new_workflow.do_job(:licenses) do
          do_name('Licenses')
          do_step('Licenses') do
            do_uses('cloud-officer/ci-actions/soup@v2')
            do_with({ 'ssh-key': '${{secrets.SSH_KEY}}', 'github-token': '${{secrets.GH_PAT}}' })
          end
        end

        step = GHB::Step.new('Setup', { with: { 'ssh-key': '${{secrets.SSH_KEY}}' } })
        deps_steps = [step]
        deps_commands = "bundle update\n"

        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(false))
        allow(FileUtils).to(receive(:rm_f))
        allow(FileUtils).to(receive(:mkdir_p))
        allow(File).to(receive(:write))

        manager = described_class.new(
          new_workflow: new_workflow,
          cron_workflow: cron_workflow,
          dependencies_steps: deps_steps,
          dependencies_commands: deps_commands
        )

        manager.save

        expect(FileUtils).to(have_received(:rm_f).with('.github/workflows/soup.yml'))
        expect(cron_workflow.jobs).to(have_key(:update_dependencies))
        expect(cron_workflow.jobs[:update_dependencies].name).to(eq('Update Dependencies'))
      end
    end

    context 'when dependencies steps have empty with' do
      it 'saves the dependencies workflow without merging with' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        new_workflow.do_job(:licenses) do
          do_name('Licenses')
          do_step('Licenses') do
            do_uses('cloud-officer/ci-actions/soup@v2')
            do_with({ 'ssh-key': '${{secrets.SSH_KEY}}', 'github-token': '${{secrets.GH_PAT}}' })
          end
        end

        step = GHB::Step.new('Setup', { with: {} })
        deps_steps = [step]
        deps_commands = "bundle update\n"

        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(false))
        allow(FileUtils).to(receive(:rm_f))
        allow(FileUtils).to(receive(:mkdir_p))
        allow(File).to(receive(:write))

        manager = described_class.new(
          new_workflow: new_workflow,
          cron_workflow: cron_workflow,
          dependencies_steps: deps_steps,
          dependencies_commands: deps_commands
        )

        manager.save

        expect(cron_workflow.jobs).to(have_key(:update_dependencies))
        expect(cron_workflow.jobs[:update_dependencies].steps.first.with).to(eq({}))
      end
    end

    context 'when dependency step has nil with' do
      it 'skips merging nil with' do # rubocop:disable RSpec/ExampleLength
        new_workflow.do_job(:licenses) do
          do_name('Licenses')
          do_step('Licenses') do
            do_uses('cloud-officer/ci-actions/soup@v2')
          end
        end

        step = GHB::Step.new('Setup')
        step.with = nil
        deps_steps = [step]
        deps_commands = "bundle update\n"

        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(false))
        allow(FileUtils).to(receive(:rm_f))
        allow(FileUtils).to(receive(:mkdir_p))
        allow(File).to(receive(:write))

        manager = described_class.new(
          new_workflow: new_workflow,
          cron_workflow: cron_workflow,
          dependencies_steps: deps_steps,
          dependencies_commands: deps_commands
        )

        manager.save

        expect(cron_workflow.jobs).to(have_key(:update_dependencies))
      end
    end

    context 'when workflow is generated' do
      it 'includes a Close Stale Dependency PRs step before Update Dependencies' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        new_workflow.do_job(:licenses) do
          do_name('Licenses')
          do_step('Licenses') do
            do_uses('cloud-officer/ci-actions/soup@v2')
            do_with({ 'ssh-key': '${{secrets.SSH_KEY}}', 'github-token': '${{secrets.GH_PAT}}' })
          end
        end

        step = GHB::Step.new('Setup', { with: { 'ssh-key': '${{secrets.SSH_KEY}}' } })
        deps_steps = [step]
        deps_commands = "bundle update\n"

        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(false))
        allow(FileUtils).to(receive(:rm_f))
        allow(FileUtils).to(receive(:mkdir_p))
        allow(File).to(receive(:write))

        manager = described_class.new(
          new_workflow: new_workflow,
          cron_workflow: cron_workflow,
          dependencies_steps: deps_steps,
          dependencies_commands: deps_commands
        )

        manager.save

        job = cron_workflow.jobs[:update_dependencies]
        step_names = job.steps.map(&:name)
        close_step = job.steps.find { |s| s.name == 'Close Stale Dependency PRs' }

        expect(close_step).not_to(be_nil)
        expect(close_step.shell).to(eq('bash'))
        expect(close_step.run).to(include('gh pr list'))
        expect(close_step.run).to(include('gh pr close'))
        expect(close_step.run).to(include('--delete-branch'))
        expect(step_names.index('Close Stale Dependency PRs')).to(be < step_names.index('Update Dependencies'))
      end
    end

    context 'when licenses step in old workflow has non-empty with' do
      it 'preserves with from old workflow licenses step' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        new_workflow.do_job(:licenses) do
          do_name('Licenses')
          do_step('Licenses') do
            do_uses('cloud-officer/ci-actions/soup@v2')
            do_with(
              {
                'ssh-key': '${{secrets.SSH_KEY}}',
                'github-token': '${{secrets.GH_PAT}}',
                parameters: '--no_prompt'
              }
            )
          end
        end

        step = GHB::Step.new('Setup', { with: { 'ssh-key': '${{secrets.SSH_KEY}}' } })
        deps_steps = [step]
        deps_commands = "bundle update\n"

        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(false))
        allow(FileUtils).to(receive(:rm_f))
        allow(FileUtils).to(receive(:mkdir_p))
        allow(File).to(receive(:write))

        manager = described_class.new(
          new_workflow: new_workflow,
          cron_workflow: cron_workflow,
          dependencies_steps: deps_steps,
          dependencies_commands: deps_commands
        )

        manager.save

        licenses_step = cron_workflow.jobs[:update_dependencies].steps.find { |s| s.name == 'Licenses' }
        expect(licenses_step).not_to(be_nil)
        expect(licenses_step.with[:'github-token']).to(eq('${{secrets.GH_PAT}}'))
        expect(licenses_step.with[:'ssh-key']).to(eq('${{secrets.SSH_KEY}}'))
      end
    end
  end
end
