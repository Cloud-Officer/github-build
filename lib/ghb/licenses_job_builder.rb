# frozen_string_literal: true

require_relative '../ghb'

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

        @new_workflow.carry_job(:licenses, from: @old_workflow) do |job|
          job.do_name('Licenses Check')
          job.do_runs_on(job.carried_from&.runs_on || DEFAULT_UBUNTU_VERSION)
          job.do_needs(%w[variables])
          job.do_if("${{needs.variables.outputs.SKIP_LICENSES != '1'}}")

          job.carry_step('Licenses') do |step|
            step.do_uses("cloud-officer/ci-actions/soup@#{CI_ACTIONS_VERSION}")

            step.default_with(GHB.secrets(:ssh, :github_token).merge(parameters: '--no_prompt'))
          end
        end
      end
    end
  end
end
