# frozen_string_literal: true

module GHB
  # Builds the "Licenses Check" job in the workflow.
  class LicensesJobBuilder
    attr_reader :unit_tests_conditions

    def initialize(context:)
      @options = context.options
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
      @unit_tests_conditions = nil
    end

    def build
      if File.exist?('Podfile.lock')
        @unit_tests_conditions = "needs.variables.outputs.SKIP_LICENSES != '1' || needs.variables.outputs.SKIP_TESTS != '1'"
      else
        @unit_tests_conditions = "needs.variables.outputs.SKIP_TESTS != '1'"

        return if @options.skip_license_check

        puts('    Adding soup...')
        old_workflow = @old_workflow

        @new_workflow.do_job(:licenses) do
          copy_properties(old_workflow.jobs[id])
          do_name('Licenses Check')
          do_runs_on(old_workflow.jobs[:licenses]&.runs_on || DEFAULT_UBUNTU_VERSION)
          do_needs(%w[variables])
          do_if("${{needs.variables.outputs.SKIP_LICENSES != '1'}}")

          do_step('Licenses') do
            copy_properties(find_step(old_workflow.jobs[:licenses]&.steps, name))
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
