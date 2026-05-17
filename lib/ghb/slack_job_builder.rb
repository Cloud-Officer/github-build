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
      return if @options.only_dependabot or @options.skip_slack

      puts('    Adding slack...')
      needs = @new_workflow.jobs.keys.map(&:to_s)
      old_workflow = @old_workflow

      @new_workflow.do_job(:slack) do
        copy_properties(old_workflow.jobs[id])
        do_name('Publish Statuses')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if('always()')

        do_step('Publish Statuses') do
          copy_properties(find_step(old_workflow.jobs[:slack]&.steps, name))
          do_uses("cloud-officer/ci-actions/slack@#{CI_ACTIONS_VERSION}")

          if with.empty?
            do_with(
              {
                'webhook-url': '${{secrets.SLACK_WEBHOOK_URL}}',
                jobs: '${{toJSON(needs)}}'
              }
            )
          end
        end
      end
    end
  end
end
