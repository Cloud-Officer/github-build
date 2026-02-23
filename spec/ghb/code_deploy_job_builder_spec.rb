# frozen_string_literal: true

RSpec.describe(GHB::CodeDeployJobBuilder) do
  let(:old_workflow)          { GHB::Workflow.new('Old')  }
  let(:new_workflow)          { GHB::Workflow.new('Test') }
  let(:code_deploy_pre_steps) { []                        }

  before do
    allow($stdout).to(receive(:puts))
  end

  describe '#build' do
    context 'when only_dependabot is true' do
      let(:options) do
        instance_double(GHB::Options, only_dependabot: true)
      end

      it 'returns early without adding jobs' do # rubocop:disable RSpec/ExampleLength
        builder = described_class.new(
          options: options,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          code_deploy_pre_steps: code_deploy_pre_steps
        )

        builder.build

        expect(new_workflow.jobs).to(be_empty)
      end
    end

    context 'when appspec.yml is missing' do
      let(:options) do
        instance_double(GHB::Options, only_dependabot: false)
      end

      it 'returns early without adding jobs' do # rubocop:disable RSpec/ExampleLength
        allow(File).to(receive(:exist?).with('appspec.yml').and_return(false))

        builder = described_class.new(
          options: options,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          code_deploy_pre_steps: code_deploy_pre_steps
        )

        builder.build

        expect(new_workflow.jobs).to(be_empty)
      end
    end

    context 'when appspec.yml exists' do
      let(:options) do
        instance_double(GHB::Options, only_dependabot: false, application_name: 'myapp')
      end

      before do
        allow(File).to(receive(:exist?).with('appspec.yml').and_return(true))

        # Pre-populate the workflow with a variables job so needs/conditions work
        new_workflow.do_job(:variables) do
          do_name('Variables')
        end
      end

      it 'adds codedeploy and environment jobs' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        builder = described_class.new(
          options: options,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          code_deploy_pre_steps: code_deploy_pre_steps
        )

        builder.build

        expect(new_workflow.jobs).to(have_key(:codedeploy))
        expect(new_workflow.jobs).to(have_key(:beta_deploy))
        expect(new_workflow.jobs).to(have_key(:rc_deploy))
        expect(new_workflow.jobs).to(have_key(:prod_deploy))
      end

      it 'creates the codedeploy job with correct name and needs' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        builder = described_class.new(
          options: options,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          code_deploy_pre_steps: code_deploy_pre_steps
        )

        builder.build

        codedeploy_job = new_workflow.jobs[:codedeploy]
        expect(codedeploy_job.name).to(eq('Code Deploy'))
        expect(codedeploy_job.needs).to(include('variables'))
      end

      it 'creates beta_deploy, rc_deploy, and prod_deploy environment jobs' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        builder = described_class.new(
          options: options,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          code_deploy_pre_steps: code_deploy_pre_steps
        )

        builder.build

        beta_job = new_workflow.jobs[:beta_deploy]
        expect(beta_job.name).to(eq('Beta Deploy'))
        expect(beta_job.needs).to(eq(%w[variables codedeploy]))

        rc_job = new_workflow.jobs[:rc_deploy]
        expect(rc_job.name).to(eq('Rc Deploy'))
        expect(rc_job.needs).to(eq(%w[variables codedeploy]))

        prod_job = new_workflow.jobs[:prod_deploy]
        expect(prod_job.name).to(eq('Prod Deploy'))
        expect(prod_job.needs).to(eq(%w[variables codedeploy]))
      end

      it 'preserves steps from old workflow via copy_properties' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        old_wf = GHB::Workflow.new('Old')
        old_wf.do_job(:codedeploy) do
          do_name('Code Deploy')
          do_step('Checkout') do
            do_uses('cloud-officer/ci-actions/codedeploy/checkout@v2')
            do_with({ 'ssh-key': 'existing-key' })
          end
          do_step('Update Packages') do
            do_if("${{needs.variables.outputs.UPDATE_PACKAGES == '1'}}")
            do_shell('bash')
            do_run('echo existing-update')
          end
          do_step('Zip') do
            do_shell('bash')
            do_run('custom zip command')
          end
          do_step('S3Copy') do
            do_uses('cloud-officer/ci-actions/codedeploy/s3copy@v2')
            do_with({ source: 'custom-source' })
          end
        end

        builder = described_class.new(
          options: options,
          old_workflow: old_wf,
          new_workflow: new_workflow,
          code_deploy_pre_steps: code_deploy_pre_steps
        )

        builder.build

        codedeploy_job = new_workflow.jobs[:codedeploy]

        zip_step = codedeploy_job.steps.find { |s| s.name == 'Zip' }
        expect(zip_step.run).to(eq('custom zip command'))

        s3_step = codedeploy_job.steps.find { |s| s.name == 'S3Copy' }
        expect(s3_step.with[:source]).to(eq('custom-source'))
      end

      it 'uses code_deploy_pre_steps instead of Checkout when pre_steps are not empty' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        pre_step = GHB::Step.new('Setup', { with: { 'ssh-key': '${{secrets.SSH_KEY}}' } })
        pre_steps = [pre_step]

        builder = described_class.new(
          options: options,
          old_workflow: old_workflow,
          new_workflow: new_workflow,
          code_deploy_pre_steps: pre_steps
        )

        builder.build

        codedeploy_job = new_workflow.jobs[:codedeploy]
        step_names = codedeploy_job.steps.map(&:name)
        expect(step_names).not_to(include('Checkout'))
        expect(step_names).to(include('Setup'))
      end

      it 'preserves environment deploy with from old workflow when with is not empty' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        old_wf = GHB::Workflow.new('Old')
        old_wf.do_job(:beta_deploy) do
          do_name('Beta Deploy')
          do_step('Beta Deploy') do
            do_uses('cloud-officer/ci-actions/codedeploy/deploy@v2')
            do_with(
              {
                'aws-access-key-id': '${{secrets.CUSTOM_KEY}}',
                'aws-secret-access-key': '${{secrets.CUSTOM_SECRET}}',
                'aws-region': 'us-west-2',
                'application-name': 'custom-app',
                'deployment-group-name': 'beta',
                's3-bucket': '${{secrets.CUSTOM_BUCKET}}',
                's3-key': 'custom-key'
              }
            )
          end
        end

        builder = described_class.new(
          options: options,
          old_workflow: old_wf,
          new_workflow: new_workflow,
          code_deploy_pre_steps: code_deploy_pre_steps
        )

        builder.build

        beta_step = new_workflow.jobs[:beta_deploy].steps.first
        expect(beta_step.with[:'aws-access-key-id']).to(eq('${{secrets.CUSTOM_KEY}}'))
        expect(beta_step.with[:'aws-region']).to(eq('us-west-2'))
      end
    end
  end
end
