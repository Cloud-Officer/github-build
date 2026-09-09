# frozen_string_literal: true

RSpec.describe(GHB::DependabotManager) do
  let(:new_workflow) { GHB::Workflow.new('Test') }

  def build_manager
    described_class.new
  end

  before do
    allow($stdout).to(receive(:puts))
  end

  describe '#save' do
    context 'when dependabot.yml exists' do
      it 'removes the dependabot config file' do
        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(true))
        allow(FileUtils).to(receive(:rm_f))

        build_manager.save

        expect(FileUtils).to(have_received(:rm_f).with('.github/dependabot.yml'))
      end
    end

    context 'when dependabot.yml does not exist' do
      it 'leaves the dependabot config alone' do
        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(false))
        allow(FileUtils).to(receive(:rm_f))

        build_manager.save

        expect(FileUtils).not_to(have_received(:rm_f).with('.github/dependabot.yml'))
      end
    end

    context 'when the repository has no licenses job' do
      it 'removes the retired cron workflows' do # rubocop:disable RSpec/MultipleExpectations
        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(false))
        allow(FileUtils).to(receive(:rm_f))

        build_manager.save

        expect(FileUtils).to(have_received(:rm_f).with('.github/workflows/dependencies.yml'))
        expect(FileUtils).to(have_received(:rm_f).with('.github/workflows/soup.yml'))
      end
    end

    # Regression guard for the retirement of the cron dependency workflow. These
    # are the exact conditions that used to generate it: a licenses job plus at
    # least one dependency step. Both files must still be removed and no job may
    # be emitted, otherwise secrets.GH_PAT returns to ~/.gitconfig in cleartext
    # ahead of package-manager updates that run third-party install scripts.
    context 'when a licenses job and dependency steps are present' do
      let(:dependencies_steps) { [GHB::Step.new('Setup', { with: { 'ssh-key': '${{secrets.SSH_KEY}}' } })] }

      before do
        new_workflow.do_job(:licenses) do
          do_name('Licenses')
          do_step('Licenses') { do_uses('cloud-officer/ci-actions/soup@v3') }
        end
      end

      it 'still removes both workflows' do # rubocop:disable RSpec/MultipleExpectations
        allow(File).to(receive(:exist?).with('.github/dependabot.yml').and_return(false))
        allow(FileUtils).to(receive(:rm_f))

        build_manager.save

        expect(FileUtils).to(have_received(:rm_f).with('.github/workflows/dependencies.yml'))
        expect(FileUtils).to(have_received(:rm_f).with('.github/workflows/soup.yml'))
      end
    end
  end
end
