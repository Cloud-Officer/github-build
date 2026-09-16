# frozen_string_literal: true

require_relative 'workflow_matrix_scenarios'

# Regenerate after an intentional change: UPDATE_SNAPSHOTS=1 bundle exec rspec spec/ghb/integration/workflow_matrix_spec.rb
RSpec.describe(WorkflowMatrix) do
  described_class.scenario_names.each do |name|
    it "reproduces the #{name} golden file across generation, customized regeneration and rerun" do
      generated = described_class.golden_text_for(name)

      expect(generated).to(eq(described_class.golden(name, generated)))
    end
  end
end
