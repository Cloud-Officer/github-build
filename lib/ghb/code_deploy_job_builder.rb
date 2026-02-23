# frozen_string_literal: true

module GHB
  # Builds the "Code Deploy" jobs in the workflow.
  class CodeDeployJobBuilder
    def initialize(options:, old_workflow:, new_workflow:, code_deploy_pre_steps:)
      @options = options
      @old_workflow = old_workflow
      @new_workflow = new_workflow
      @code_deploy_pre_steps = code_deploy_pre_steps
    end

    def build
      return if @options.only_dependabot

      return unless File.exist?('appspec.yml')

      puts('    Adding codedeploy...')
      build_codedeploy_job
      build_environment_jobs
    end

    private

    def build_codedeploy_job
      needs = @new_workflow.jobs.keys.map(&:to_s)
      base_condition = "always() && (needs.variables.outputs.DEPLOY_ON_BETA == '1' || needs.variables.outputs.DEPLOY_ON_RC == '1' || needs.variables.outputs.DEPLOY_ON_PROD == '1')"
      job_conditions = @new_workflow.jobs.keys.map { |job_name| "needs.#{job_name}.result != 'failure'" }
      if_statement = ([base_condition] + job_conditions).join(' && ')
      code_deploy_pre_steps = @code_deploy_pre_steps
      old_workflow = @old_workflow

      @new_workflow.do_job(:codedeploy) do
        copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
        do_name('Code Deploy')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if("${{#{if_statement}}}")

        if code_deploy_pre_steps.empty?
          do_step('Checkout') do
            copy_properties(find_step(old_workflow.jobs[:codedeploy]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_uses("cloud-officer/ci-actions/codedeploy/checkout@#{CI_ACTIONS_VERSION}")
            do_with({ 'ssh-key': '${{secrets.SSH_KEY}}', 'github-token': '${{secrets.GH_PAT}}' }) if with.empty?
          end
        else
          code_deploy_pre_steps.each do |step|
            step.if = nil
          end

          self.steps = code_deploy_pre_steps.clone
        end

        do_step('Update Packages') do
          copy_properties(find_step(old_workflow.jobs[:codedeploy]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_if("${{needs.variables.outputs.UPDATE_PACKAGES == '1'}}")
          do_shell('bash')
          do_run('touch update-packages')
        end

        do_step('Zip') do
          copy_properties(find_step(old_workflow.jobs[:codedeploy]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_shell('bash')
          do_run('zip --quiet --recurse-paths "${{needs.variables.outputs.BUILD_NAME}}.zip" ./*') if run.nil?
        end

        do_step('S3Copy') do
          copy_properties(find_step(old_workflow.jobs[:codedeploy]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_uses("cloud-officer/ci-actions/codedeploy/s3copy@#{CI_ACTIONS_VERSION}")

          if with.empty?
            do_with(
              {
                'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
                'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
                'aws-region': '${{secrets.AWS_DEFAULT_REGION}}',
                source: 'deployment',
                target: 's3://${{secrets.CODEDEPLOY_BUCKET}}/${{github.repository}}'
              }
            )
          end
        end
      end
    end

    def build_environment_jobs
      old_workflow = @old_workflow
      options = @options

      %w[beta rc prod].each do |environment|
        @new_workflow.do_job(:"#{environment}_deploy") do
          copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
          do_name("#{environment.capitalize} Deploy")
          do_runs_on(DEFAULT_UBUNTU_VERSION)
          do_needs(%w[variables codedeploy])
          do_if("${{always() && needs.codedeploy.result == 'success' && needs.variables.outputs.DEPLOY_ON_#{environment.upcase} == '1'}}")

          do_step("#{environment.capitalize} Deploy") do
            copy_properties(find_step(old_workflow.jobs[:"#{environment}_deploy"]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_uses("cloud-officer/ci-actions/codedeploy/deploy@#{CI_ACTIONS_VERSION}")

            if with.empty?
              do_with(
                {
                  'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
                  'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
                  'aws-region': '${{secrets.AWS_DEFAULT_REGION}}',
                  'application-name': options.application_name,
                  'deployment-group-name': environment,
                  's3-bucket': '${{secrets.CODEDEPLOY_BUCKET}}',
                  's3-key': '${{github.repository}}/${{needs.variables.outputs.BUILD_NAME}}.zip'
                }
              )
            end
          end
        end
      end
    end
  end
end
