# frozen_string_literal: true

module GHB
  # Builds the "Prepare Variables" job in the workflow.
  class VariablesJobBuilder
    def initialize(options:, new_workflow:)
      @options = options
      @new_workflow = new_workflow
    end

    def build
      return if @options.only_dependabot

      @new_workflow.do_job(:variables) do
        do_name('Prepare Variables')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_outputs(
          {
            BUILD_NAME: '${{steps.variables.outputs.BUILD_NAME}}',
            BUILD_VERSION: '${{steps.variables.outputs.BUILD_VERSION}}',
            COMMIT_MESSAGE: '${{steps.variables.outputs.COMMIT_MESSAGE}}',
            MODIFIED_GITHUB_RUN_NUMBER: '${{steps.variables.outputs.MODIFIED_GITHUB_RUN_NUMBER}}',
            DEPLOY_ON_BETA: '${{steps.variables.outputs.DEPLOY_ON_BETA}}',
            DEPLOY_ON_RC: '${{steps.variables.outputs.DEPLOY_ON_RC}}',
            DEPLOY_ON_PROD: '${{steps.variables.outputs.DEPLOY_ON_PROD}}',
            DEPLOY_MACOS: '${{steps.variables.outputs.DEPLOY_MACOS}}',
            DEPLOY_TVOS: '${{steps.variables.outputs.DEPLOY_TVOS}}',
            DEPLOY_OPTIONS: '${{steps.variables.outputs.DEPLOY_OPTIONS}}',
            SKIP_LICENSES: '${{steps.variables.outputs.SKIP_LICENSES}}',
            SKIP_LINTERS: '${{steps.variables.outputs.SKIP_LINTERS}}',
            SKIP_TESTS: '${{steps.variables.outputs.SKIP_TESTS}}',
            UPDATE_PACKAGES: '${{steps.variables.outputs.UPDATE_PACKAGES}}',
            LINTERS: '${{steps.variables.outputs.LINTERS}}'
          }
        )

        do_step('Prepare variables') do
          do_id('variables')
          do_uses("cloud-officer/ci-actions/variables@#{CI_ACTIONS_VERSION}")
          do_with(
            {
              'ssh-key': '${{secrets.SSH_KEY}}',
              'github-token': '${{secrets.GH_PAT}}'
            }
          )
        end
      end
    end
  end
end
