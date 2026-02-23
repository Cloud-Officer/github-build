# frozen_string_literal: true

module GHB
  # Builds the "Licenses Check" job in the workflow.
  class LicensesJobBuilder
    attr_reader :unit_tests_conditions

    def initialize(options:, old_workflow:, new_workflow:)
      @options = options
      @old_workflow = old_workflow
      @new_workflow = new_workflow
      @unit_tests_conditions = nil
    end

    def build
      return if @options.only_dependabot

      if File.exist?('Podfile.lock')
        @unit_tests_conditions = "needs.variables.outputs.SKIP_LICENSES != '1' || needs.variables.outputs.SKIP_TESTS != '1'"
      else
        @unit_tests_conditions = "needs.variables.outputs.SKIP_TESTS != '1'"

        return if @options.skip_license_check

        puts('    Adding soup...')
        old_workflow = @old_workflow

        @new_workflow.do_job(:licenses) do
          copy_properties(old_workflow.jobs[id], %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets])
          do_name('Licenses Check')
          do_runs_on(old_workflow.jobs[:licenses]&.runs_on || DEFAULT_UBUNTU_VERSION)
          do_needs(%w[variables])
          do_if("${{needs.variables.outputs.SKIP_LICENSES != '1'}}")

          do_step('Licenses') do
            copy_properties(find_step(old_workflow.jobs[:licenses]&.steps, name), %i[id if uses run shell with env continue_on_error timeout_minutes])
            do_uses("cloud-officer/ci-actions/soup@#{CI_ACTIONS_VERSION}")

            if with.empty?
              do_with(
                {
                  'ssh-key': '${{secrets.SSH_KEY}}',
                  'github-token': '${{secrets.GH_PAT}}',
                  parameters: '--no_prompt'
                }
              )
            end
          end
        end
      end
    end
  end
end
