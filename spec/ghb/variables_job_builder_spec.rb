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
  end
end
