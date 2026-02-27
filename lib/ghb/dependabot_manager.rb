# frozen_string_literal: true

module GHB
  # Manages dependabot configuration and cron dependency update workflow.
  class DependabotManager
    def initialize(new_workflow:, cron_workflow:, dependencies_steps:, dependencies_commands:)
      @new_workflow = new_workflow
      @cron_workflow = cron_workflow
      @dependencies_steps = dependencies_steps
      @dependencies_commands = dependencies_commands
    end

    def save
      dependabot_file = '.github/dependabot.yml'

      if File.exist?(dependabot_file)
        puts('    Removing dependabot config (CVE alerts are handled by repository settings)...')
        FileUtils.rm_f(dependabot_file)
      end

      if @new_workflow.jobs[:licenses] and !@dependencies_steps.empty?
        save_dependencies_workflow
      else
        FileUtils.rm_f('.github/workflows/dependencies.yml')
      end
    end

    private

    def save_dependencies_workflow
      new_workflow = @new_workflow
      dependencies_steps = @dependencies_steps
      dependencies_commands = @dependencies_commands
      FileUtils.rm_f('.github/workflows/soup.yml')

      @cron_workflow.on =
        {
          schedule:
            [
              {
                cron: '0 9 * * 1'
              }
            ]
        }

      @cron_workflow.env = @new_workflow.env

      @cron_workflow.do_job(:update_dependencies) do
        do_name('Update Dependencies')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_permissions(
          {
            actions: 'write',
            checks: 'write',
            contents: 'write',
            'pull-requests': 'write'
          }
        )

        merged_with = {}

        dependencies_steps.each do |step|
          merged_with.merge!(step.with) if step.with
        end

        dependencies_steps&.first&.if = nil
        dependencies_steps&.first&.with = merged_with

        self.steps = [dependencies_steps&.first]

        do_step('Close Stale Dependency PRs') do
          do_shell('bash')
          do_env({ GH_TOKEN: '${{secrets.GH_PAT}}' })
          do_run(
            <<~BASH
              prs=$(gh pr list --repo "${{github.repository}}" --search "Update Dependencies in:title" --state open --json number,headRefName --jq '.[] | "\\(.number) \\(.headRefName)"')

              if [ -n "$prs" ]; then
                while IFS=' ' read -r pr_number branch_name; do
                  echo "Closing PR #${pr_number} and deleting branch ${branch_name}"
                  gh pr close "${pr_number}" --repo "${{github.repository}}" --delete-branch --comment "Superseded by a newer dependency update."
                done <<< "$prs"
              else
                echo "No stale dependency update PRs found."
              fi
            BASH
          )
        end

        do_step('Update Dependencies') do
          do_shell('bash')
          do_env({ GH_PAT: '${{secrets.GH_PAT}}' })
          do_run(dependencies_commands)
        end

        do_step('Licenses') do
          copy_properties(new_workflow.jobs[:licenses]&.steps&.first, %i[id if uses run shell with env continue_on_error timeout_minutes])
          do_uses("cloud-officer/ci-actions/soup@#{CI_ACTIONS_VERSION}")

          if with.empty?
            do_with(
              {
                'ssh-key': '${{secrets.SSH_KEY}}',
                'github-token': '${{secrets.GH_PAT}}',
                parameters: '--no_prompt',
                'skip-checkout': 'true'
              }
            )
          end

          with[:'github-token'] = '${{secrets.GH_PAT}}'
          with['skip-checkout'] = 'true'
        end

        do_step('Create Pull Request') do
          do_uses('peter-evans/create-pull-request@v7')
          do_with(
            {
              'commit-message': 'Update dependencies and soup files',
              branch: 'update-dependencies-${{github.run_id}}',
              title: 'Update Dependencies',
              body: 'This PR updates the dependencies.'
            }
          )

          with['token'] = '${{secrets.GH_PAT}}'
        end
      end

      @cron_workflow.write('.github/workflows/dependencies.yml')
    end
  end
end
