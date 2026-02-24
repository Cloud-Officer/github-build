# frozen_string_literal: true

RSpec.describe(GHB::VariablesJobBuilder) do
  describe '#build' do
    it 'returns early when only_dependabot is true' do
      options = instance_double(GHB::Options, only_dependabot: true)
      workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, new_workflow: workflow)

      builder.build

      expect(workflow.jobs).to(be_empty)
    end

    it 'adds variables job to workflow' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = instance_double(GHB::Options, only_dependabot: false)
      workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, new_workflow: workflow)

      builder.build

      expect(workflow.jobs).to(have_key(:variables))
      expect(workflow.jobs[:variables].name).to(eq('Prepare Variables'))
      expect(workflow.jobs[:variables].steps.length).to(eq(1))
      expect(workflow.jobs[:variables].steps.first.name).to(eq('Prepare variables'))
      expect(workflow.jobs[:variables].outputs).not_to(be_empty)
    end
  end
end
