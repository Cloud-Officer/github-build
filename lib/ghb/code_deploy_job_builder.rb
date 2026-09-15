# frozen_string_literal: true

module GHB
  # Builds the "Code Deploy" jobs in the workflow.
  class CodeDeployJobBuilder
    def initialize(context:, code_deploy_pre_steps:)
      @options = context.options
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
      @code_deploy_pre_steps = code_deploy_pre_steps
    end

    def build
      return unless File.exist?('appspec.yml')

      puts('    Adding codedeploy...')
      build_codedeploy_job
      build_environment_jobs
    end

    private

    def build_codedeploy_job
      needs = @new_workflow.deploy_needs
      if_statement = @new_workflow.deploy_if_statement

      @new_workflow.do_job(:codedeploy) do |job|
        job.copy_properties(@old_workflow.jobs[job.id])
        job.do_name('Code Deploy')
        job.do_runs_on(DEFAULT_UBUNTU_VERSION)
        job.do_needs(needs)
        job.do_if(if_statement)

        if @code_deploy_pre_steps.empty?
          job.do_step('Checkout') do |step|
            step.copy_properties(step.find_step(@old_workflow.jobs[:codedeploy]&.steps, step.name))
            step.do_uses("cloud-officer/ci-actions/codedeploy/checkout@#{CI_ACTIONS_VERSION}")
            step.default_with(GHB.secrets(:ssh, :github_token))
          end
        else
          @code_deploy_pre_steps.each do |step|
            step.if = nil
          end

          job.steps = @code_deploy_pre_steps.clone
        end

        job.do_step('Update Packages') do |step|
          step.copy_properties(step.find_step(@old_workflow.jobs[:codedeploy]&.steps, step.name))
          step.do_if("${{needs.variables.outputs.UPDATE_PACKAGES == '1'}}")
          step.do_shell('bash')
          step.do_run('touch update-packages')
        end

        job.do_step('Zip') do |step|
          step.copy_properties(step.find_step(@old_workflow.jobs[:codedeploy]&.steps, step.name))
          step.do_shell('bash')
          step.do_run('zip --quiet --recurse-paths "${{needs.variables.outputs.BUILD_NAME}}.zip" ./*') if step.run.nil?
        end

        job.do_step('S3Copy') do |step|
          step.copy_properties(step.find_step(@old_workflow.jobs[:codedeploy]&.steps, step.name))
          step.do_uses("cloud-officer/ci-actions/codedeploy/s3copy@#{CI_ACTIONS_VERSION}")

          step.default_with(GHB.secrets(:aws).merge(source: 'deployment', target: 's3://${{secrets.CODEDEPLOY_BUCKET}}/${{github.repository}}'))
        end
      end
    end

    def build_environment_jobs
      %w[beta rc prod].each do |environment|
        @new_workflow.do_job(:"#{environment}_deploy") do |job|
          job.copy_properties(@old_workflow.jobs[job.id])
          job.do_name("#{environment.capitalize} Deploy")
          job.do_runs_on(DEFAULT_UBUNTU_VERSION)
          job.do_needs(%w[variables codedeploy])
          job.do_if("${{always() && needs.codedeploy.result == 'success' && needs.variables.outputs.DEPLOY_ON_#{environment.upcase} == '1'}}")

          job.do_step("#{environment.capitalize} Deploy") do |step|
            step.copy_properties(step.find_step(@old_workflow.jobs[:"#{environment}_deploy"]&.steps, step.name))
            step.do_uses("cloud-officer/ci-actions/codedeploy/deploy@#{CI_ACTIONS_VERSION}")

            step.default_with(
              GHB.secrets(:aws).merge(
                'application-name': @options.application_name,
                'deployment-group-name': environment,
                's3-bucket': '${{secrets.CODEDEPLOY_BUCKET}}',
                's3-key': '${{github.repository}}/${{needs.variables.outputs.BUILD_NAME}}.zip'
              )
            )
          end
        end
      end
    end
  end
end
