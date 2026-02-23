# frozen_string_literal: true

module GHB
  # Builds the "Publish Statuses" (Slack) job in the workflow.
  class SlackJobBuilder
    def initialize(options:, old_workflow:, new_workflow:)
      @options = options
      @old_workflow = old_workflow
      @new_workflow = new_workflow
    end

    def build
      return if @options.only_dependabot or @options.skip_slack

      puts('    Adding slack...')
      needs = @new_workflow.jobs.keys.map(&:to_s)
      old_workflow = @old_workflow

      @new_workflow.do_job(:slack) do
        copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
        do_name('Publish Statuses')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if('always()')

        do_step('Publish Statuses') do
          copy_properties(find_step(old_workflow.jobs[:slack]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
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
