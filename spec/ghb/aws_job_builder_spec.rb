# frozen_string_literal: true

RSpec.describe(GHB::AwsJobBuilder) do
  describe '#build' do
    let(:old_workflow) do
      workflow = GHB::Workflow.new('Old')
      workflow.do_job(:aws) do
        do_name('AWS')
        do_step('AWS Commands') do
          do_uses('cloud-officer/ci-actions/aws@v2')
        end
      end
      workflow
    end

    it 'returns early when only_dependabot is true' do
      options = instance_double(GHB::Options, only_dependabot: true)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      builder.build

      expect(new_workflow.jobs).to(be_empty)
    end

    it 'returns early when .aws file missing' do # rubocop:disable RSpec/ExampleLength
      options = instance_double(GHB::Options, only_dependabot: false)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      allow(File).to(receive(:exist?).with('.aws').and_return(false))

      builder.build

      expect(new_workflow.jobs).to(be_empty)
    end

    it 'adds aws job when .aws file exists' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = instance_double(GHB::Options, only_dependabot: false)
      new_workflow = GHB::Workflow.new('Test')

      # Add a pre-existing job so needs has something to reference
      new_workflow.do_job(:variables) do
        do_name('Prepare Variables')
      end

      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      allow(File).to(receive(:exist?).with('.aws').and_return(true))

      builder.build

      expect(new_workflow.jobs).to(have_key(:aws))
      expect(new_workflow.jobs[:aws].name).to(eq('AWS'))
      expect(new_workflow.jobs[:aws].needs).to(include('variables'))
      expect(new_workflow.jobs[:aws].steps.length).to(eq(1))
      expect(new_workflow.jobs[:aws].steps.first.name).to(eq('AWS Commands'))
    end

    it 'preserves with from old workflow when aws step has non-empty with' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      allow($stdout).to(receive(:puts))

      old_wf = GHB::Workflow.new('Old')
      old_wf.do_job(:aws) do
        do_name('AWS')
        do_step('AWS Commands') do
          do_uses('cloud-officer/ci-actions/aws@v2')
          do_with(
            {
              'ssh-key': '${{secrets.SSH_KEY}}',
              'github-token': '${{secrets.GH_PAT}}',
              'aws-access-key-id': '${{secrets.CUSTOM_AWS_KEY}}',
              'aws-secret-access-key': '${{secrets.CUSTOM_AWS_SECRET}}',
              'aws-region': 'eu-west-1',
              'shell-commands': 'echo "Custom commands"'
            }
          )
        end
      end

      options = instance_double(GHB::Options, only_dependabot: false)
      new_workflow = GHB::Workflow.new('Test')

      new_workflow.do_job(:variables) do
        do_name('Prepare Variables')
      end

      builder = described_class.new(options: options, old_workflow: old_wf, new_workflow: new_workflow)

      allow(File).to(receive(:exist?).with('.aws').and_return(true))

      builder.build

      aws_step = new_workflow.jobs[:aws].steps.first
      expect(aws_step.with[:'aws-access-key-id']).to(eq('${{secrets.CUSTOM_AWS_KEY}}'))
      expect(aws_step.with[:'aws-region']).to(eq('eu-west-1'))
      expect(aws_step.with[:'shell-commands']).to(eq('echo "Custom commands"'))
    end
  end
end
