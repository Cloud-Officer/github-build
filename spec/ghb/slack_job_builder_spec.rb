# frozen_string_literal: true

RSpec.describe(GHB::SlackJobBuilder) do
  describe '#build' do
    let(:old_workflow) do
      workflow = GHB::Workflow.new('Old')
      workflow.do_job(:slack) do
        do_name('Publish Statuses')
        do_step('Publish Statuses') do
          do_uses('cloud-officer/ci-actions/slack@v2')
        end
      end
      workflow
    end

    it 'returns early when only_dependabot is true' do
      options = instance_double(GHB::Options, only_dependabot: true, skip_slack: false)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      builder.build

      expect(new_workflow.jobs).to(be_empty)
    end

    it 'returns early when skip_slack is true' do
      options = instance_double(GHB::Options, only_dependabot: false, skip_slack: true)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      builder.build

      expect(new_workflow.jobs).to(be_empty)
    end

    it 'adds slack job to workflow' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = instance_double(GHB::Options, only_dependabot: false, skip_slack: false)
      new_workflow = GHB::Workflow.new('Test')

      # Add a pre-existing job so needs has something to reference
      new_workflow.do_job(:variables) do
        do_name('Prepare Variables')
      end

      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      builder.build

      expect(new_workflow.jobs).to(have_key(:slack))
      expect(new_workflow.jobs[:slack].name).to(eq('Publish Statuses'))
      expect(new_workflow.jobs[:slack].needs).to(include('variables'))
      expect(new_workflow.jobs[:slack].steps.length).to(eq(1))
      expect(new_workflow.jobs[:slack].steps.first.name).to(eq('Publish Statuses'))
    end

    it 'preserves with from old workflow when slack step has non-empty with' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      allow($stdout).to(receive(:puts))

      old_wf = GHB::Workflow.new('Old')
      old_wf.do_job(:slack) do
        do_name('Publish Statuses')
        do_step('Publish Statuses') do
          do_uses('cloud-officer/ci-actions/slack@v2')
          do_with(
            {
              'webhook-url': '${{secrets.CUSTOM_SLACK_URL}}',
              jobs: '${{toJSON(needs)}}'
            }
          )
        end
      end

      options = instance_double(GHB::Options, only_dependabot: false, skip_slack: false)
      new_workflow = GHB::Workflow.new('Test')

      new_workflow.do_job(:variables) do
        do_name('Prepare Variables')
      end

      builder = described_class.new(options: options, old_workflow: old_wf, new_workflow: new_workflow)

      builder.build

      slack_step = new_workflow.jobs[:slack].steps.first
      expect(slack_step.with[:'webhook-url']).to(eq('${{secrets.CUSTOM_SLACK_URL}}'))
      expect(slack_step.with[:jobs]).to(eq('${{toJSON(needs)}}'))
    end
  end
end
