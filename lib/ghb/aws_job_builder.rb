# frozen_string_literal: true

module GHB
  # Builds the "AWS Commands" job in the workflow.
  class AwsJobBuilder
    def initialize(context:)
      @options = context.options
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
    end

    def build
      return unless File.exist?('.aws')

      puts('    Adding aws commands...')
      needs = @new_workflow.deploy_needs
      if_statement = @new_workflow.deploy_if_statement
      old_workflow = @old_workflow

      @new_workflow.do_job(:aws) do
        copy_properties(old_workflow.jobs[id])
        do_name('AWS')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if(if_statement)

        do_step('AWS Commands') do
          copy_properties(find_step(old_workflow.jobs[:aws]&.steps, name))
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
