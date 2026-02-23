# frozen_string_literal: true

module GHB
  # Builds the "AWS Commands" job in the workflow.
  class AwsJobBuilder
    def initialize(options:, old_workflow:, new_workflow:)
      @options = options
      @old_workflow = old_workflow
      @new_workflow = new_workflow
    end

    def build
      return if @options.only_dependabot

      return unless File.exist?('.aws')

      puts('    Adding aws commands...')
      needs = @new_workflow.jobs.keys.map(&:to_s)
      base_condition = "always() && (needs.variables.outputs.DEPLOY_ON_BETA == '1' || needs.variables.outputs.DEPLOY_ON_RC == '1' || needs.variables.outputs.DEPLOY_ON_PROD == '1')"
      job_conditions = @new_workflow.jobs.keys.map { |job_name| "needs.#{job_name}.result != 'failure'" }
      if_statement = ([base_condition] + job_conditions).join(' && ')
      old_workflow = @old_workflow

      @new_workflow.do_job(:aws) do
        copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
        do_name('AWS')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if("${{#{if_statement}}}")

        do_step('AWS Commands') do
          copy_properties(find_step(old_workflow.jobs[:aws]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_uses("cloud-officer/ci-actions/aws@#{CI_ACTIONS_VERSION}")

          if with.empty?
            do_with(
              {
                'ssh-key': '${{secrets.SSH_KEY}}',
                'github-token': '${{secrets.GH_PAT}}',
                'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
                'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
                'aws-region': '${{secrets.AWS_DEFAULT_REGION}}',
                'shell-commands': 'echo "Add your commands here!"'
              }
            )
          end
        end
      end
    end
  end
end
