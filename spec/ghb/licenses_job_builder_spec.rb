# frozen_string_literal: true

RSpec.describe(GHB::LicensesJobBuilder) do
  describe '#build' do
    let(:old_workflow) do
      workflow = GHB::Workflow.new('Old')
      workflow.do_job(:licenses) do
        do_name('Licenses Check')
        do_step('Licenses') do
          do_uses('cloud-officer/ci-actions/soup@v2')
        end
      end
      workflow
    end

    it 'returns early when only_dependabot is true' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = instance_double(GHB::Options, only_dependabot: true)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      builder.build

      expect(new_workflow.jobs).to(be_empty)
      expect(builder.unit_tests_conditions).to(be_nil)
    end

    it 'sets unit_tests_conditions with Podfile.lock present' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = instance_double(GHB::Options, only_dependabot: false)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(true))

      builder.build

      expect(builder.unit_tests_conditions).to(eq("needs.variables.outputs.SKIP_LICENSES != '1' || needs.variables.outputs.SKIP_TESTS != '1'"))
      expect(new_workflow.jobs).to(be_empty)
    end

    it 'sets unit_tests_conditions without Podfile.lock' do # rubocop:disable RSpec/ExampleLength
      options = instance_double(GHB::Options, only_dependabot: false, skip_license_check: false)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))

      builder.build

      expect(builder.unit_tests_conditions).to(eq("needs.variables.outputs.SKIP_TESTS != '1'"))
    end

    it 'adds licenses job when skip_license_check is false and no Podfile.lock' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = instance_double(GHB::Options, only_dependabot: false, skip_license_check: false)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))

      builder.build

      expect(new_workflow.jobs).to(have_key(:licenses))
      expect(new_workflow.jobs[:licenses].name).to(eq('Licenses Check'))
      expect(new_workflow.jobs[:licenses].needs).to(eq(%w[variables]))
      expect(new_workflow.jobs[:licenses].steps.length).to(eq(1))
      expect(new_workflow.jobs[:licenses].steps.first.name).to(eq('Licenses'))
    end

    it 'skips licenses job when skip_license_check is true' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      options = instance_double(GHB::Options, only_dependabot: false, skip_license_check: true)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)

      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))

      builder.build

      expect(new_workflow.jobs).to(be_empty)
      expect(builder.unit_tests_conditions).to(eq("needs.variables.outputs.SKIP_TESTS != '1'"))
    end

    it 'preserves with from old workflow when licenses step has non-empty with' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      allow($stdout).to(receive(:puts))

      old_wf = GHB::Workflow.new('Old')
      old_wf.do_job(:licenses) do
        do_name('Licenses Check')
        do_step('Licenses') do
          do_uses('cloud-officer/ci-actions/soup@v2')
          do_with(
            {
              'ssh-key': '${{secrets.SSH_KEY}}',
              'github-token': '${{secrets.GH_PAT}}',
              parameters: '--custom-flag'
            }
          )
        end
      end

      options = instance_double(GHB::Options, only_dependabot: false, skip_license_check: false)
      new_workflow = GHB::Workflow.new('Test')
      builder = described_class.new(options: options, old_workflow: old_wf, new_workflow: new_workflow)

      allow(File).to(receive(:exist?).with('Podfile.lock').and_return(false))

      builder.build

      licenses_step = new_workflow.jobs[:licenses].steps.first
      expect(licenses_step.with[:'ssh-key']).to(eq('${{secrets.SSH_KEY}}'))
      expect(licenses_step.with[:parameters]).to(eq('--custom-flag'))
    end
  end
end
