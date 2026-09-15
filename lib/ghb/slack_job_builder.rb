# frozen_string_literal: true

module GHB
  # Builds the "Publish Statuses" (Slack) job in the workflow.
  class SlackJobBuilder
    def initialize(context:)
      @options = context.options
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
    end

    def build
      return if @options.skip_slack

      puts('    Adding slack...')
      needs = @new_workflow.jobs.keys.map(&:to_s)

      @new_workflow.do_job(:slack) do |job|
        job.copy_properties(@old_workflow.jobs[job.id])
        job.do_name('Publish Statuses')
        job.do_runs_on(DEFAULT_UBUNTU_VERSION)
        job.do_needs(needs)
        job.do_if('always()')

        job.do_step('Publish Statuses') do |step|
          step.copy_properties(step.find_step(@old_workflow.jobs[:slack]&.steps, step.name))
          step.do_uses("cloud-officer/ci-actions/slack@#{CI_ACTIONS_VERSION}")

          step.default_with('webhook-url': '${{secrets.SLACK_WEBHOOK_URL}}', jobs: '${{toJSON(needs)}}')
        end
      end
    end
  end
end
