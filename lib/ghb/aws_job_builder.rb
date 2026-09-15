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

      @new_workflow.do_job(:aws) do |job|
        job.copy_properties(@old_workflow.jobs[job.id])
        job.do_name('AWS')
        job.do_runs_on(DEFAULT_UBUNTU_VERSION)
        job.do_needs(needs)
        job.do_if(if_statement)

        job.do_step('AWS Commands') do |step|
          step.copy_properties(step.find_step(@old_workflow.jobs[:aws]&.steps, step.name))
          step.do_uses("cloud-officer/ci-actions/aws@#{CI_ACTIONS_VERSION}")

          step.default_with(GHB.secrets(:ssh, :github_token, :aws).merge('shell-commands': 'echo "Add your commands here!"'))
        end
      end
    end
  end
end
