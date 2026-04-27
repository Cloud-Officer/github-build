# frozen_string_literal: true

RSpec.describe(GHB::AutoMergeManager) do
  let(:auto_merge_workflow) { GHB::Workflow.new('Auto-merge for code owners') }

  before do
    allow($stdout).to(receive(:puts))
    allow(FileUtils).to(receive(:mkdir_p))
    allow(File).to(receive(:write))
  end

  describe '#save' do
    it 'generates the auto-merge workflow file' do
      manager = described_class.new(auto_merge_workflow: auto_merge_workflow)
      manager.save

      expect(File).to(have_received(:write).with('.github/workflows/auto-merge.yml', anything))
    end

    it 'sets the correct trigger' do # rubocop:disable RSpec/ExampleLength
      manager = described_class.new(auto_merge_workflow: auto_merge_workflow)
      manager.save

      expect(auto_merge_workflow.on).to(
        eq(
          {
            pull_request_target:
              {
                types: %w[opened reopened ready_for_review synchronize]
              }
          }
        )
      )
    end

    it 'sets the correct permissions' do # rubocop:disable RSpec/ExampleLength
      manager = described_class.new(auto_merge_workflow: auto_merge_workflow)
      manager.save

      expect(auto_merge_workflow.permissions).to(
        eq(
          {
            contents: 'write',
            'pull-requests': 'write',
            issues: 'write'
          }
        )
      )
    end

    it 'creates the enable_automerge job' do # rubocop:disable RSpec/MultipleExpectations
      manager = described_class.new(auto_merge_workflow: auto_merge_workflow)
      manager.save

      expect(auto_merge_workflow.jobs).to(have_key(:enable_automerge))
      expect(auto_merge_workflow.jobs[:enable_automerge].name).to(eq('Enable Auto-merge'))
    end

    it 'skips draft pull requests' do
      manager = described_class.new(auto_merge_workflow: auto_merge_workflow)
      manager.save

      expect(auto_merge_workflow.jobs[:enable_automerge].if).to(eq('github.event.pull_request.draft == false'))
    end

    it 'includes a checkout step with base sha' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      manager = described_class.new(auto_merge_workflow: auto_merge_workflow)
      manager.save

      checkout_step = auto_merge_workflow.jobs[:enable_automerge].steps.find { |s| s.name == 'Checkout' }
      expect(checkout_step).not_to(be_nil)
      expect(checkout_step.uses).to(eq('actions/checkout@v4'))
      expect(checkout_step.with[:ref]).to(eq('${{github.event.pull_request.base.sha}}'))
    end

    it 'includes a code owner check step' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      manager = described_class.new(auto_merge_workflow: auto_merge_workflow)
      manager.save

      check_step = auto_merge_workflow.jobs[:enable_automerge].steps.find { |s| s.name == 'Check if PR author is a code owner' }
      expect(check_step).not_to(be_nil)
      expect(check_step.id).to(eq('check'))
      expect(check_step.run).to(include('CODEOWNERS'))
      expect(check_step.run).to(include('is_owner'))
      expect(check_step.env[:GH_TOKEN]).to(eq('${{secrets.GH_PAT}}'))
    end

    it 'includes an approve PR step' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      manager = described_class.new(auto_merge_workflow: auto_merge_workflow)
      manager.save

      approve_step = auto_merge_workflow.jobs[:enable_automerge].steps.find { |s| s.name == 'Approve PR' }
      expect(approve_step).not_to(be_nil)
      expect(approve_step.if).to(eq("steps.check.outputs.is_owner == 'true'"))
      expect(approve_step.run).to(eq('gh pr review --approve "$PR"'))
    end

    it 'includes an enable auto-merge step' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      manager = described_class.new(auto_merge_workflow: auto_merge_workflow)
      manager.save

      merge_step = auto_merge_workflow.jobs[:enable_automerge].steps.find { |s| s.name == 'Enable auto-merge' }
      expect(merge_step).not_to(be_nil)
      expect(merge_step.if).to(eq("steps.check.outputs.is_owner == 'true'"))
      expect(merge_step.run).to(eq('gh pr merge --auto --squash "$PR"'))
      expect(merge_step.env[:GH_TOKEN]).to(eq('${{secrets.GITHUB_TOKEN}}'))
    end
  end
end
