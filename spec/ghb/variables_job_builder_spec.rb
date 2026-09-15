# frozen_string_literal: true

RSpec.describe(GHB::VariablesJobBuilder) do
  describe '#build' do
    it 'adds variables job to workflow' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = instance_double(GHB::Options)
      workflow = GHB::Workflow.new('Test')
      builder = described_class.new(context: GHB::BuildContext.new(options: options, new_workflow: workflow))

      builder.build

      expect(workflow.jobs).to(have_key(:variables))
      expect(workflow.jobs[:variables].name).to(eq('Prepare Variables'))
      expect(workflow.jobs[:variables].steps.length).to(eq(1))
      expect(workflow.jobs[:variables].steps.first.name).to(eq('Prepare variables'))
      expect(workflow.jobs[:variables].outputs).not_to(be_empty)
    end

    it 'takes the prepare-variables secrets from the shared secret bundles' do
      bundle = { 'ssh-key': '${{secrets.RENAMED_SSH_KEY}}', 'github-token': '${{secrets.RENAMED_TOKEN}}' }
      allow(GHB).to(receive(:secrets).with(:ssh, :github_token).and_return(bundle))
      workflow = GHB::Workflow.new('Test')

      described_class.new(context: GHB::BuildContext.new(options: instance_double(GHB::Options), new_workflow: workflow)).build

      expect(workflow.jobs[:variables].steps.first.with).to(eq(bundle))
    end
  end
end
