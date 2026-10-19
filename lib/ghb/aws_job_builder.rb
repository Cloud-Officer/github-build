# frozen_string_literal: true

require_relative '../ghb'

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

      @new_workflow.carry_job(:aws, from: @old_workflow) do |job|
        job.do_name('AWS')
        job.do_runs_on(DEFAULT_UBUNTU_VERSION)
        job.do_needs(needs)
        job.do_if(if_statement)

        job.carry_step('AWS Commands') do |step|
          step.do_uses("cloud-officer/ci-actions/aws@#{CI_ACTIONS_VERSION}")

          step.default_with(GHB.secrets(:ssh, :github_token, :aws).merge('shell-commands': 'echo "Add your commands here!"'))
        end
      end
    end
  end
end
