# frozen_string_literal: true

module GHB
  # Manages auto-merge workflow for code owners.
  class AutoMergeManager
    def initialize(auto_merge_workflow:)
      @auto_merge_workflow = auto_merge_workflow
    end

    def save
      puts('    Adding auto-merge workflow...')

      @auto_merge_workflow.on =
        {
          pull_request_target:
            {
              types: %w[opened reopened ready_for_review synchronize]
            }
        }

      @auto_merge_workflow.permissions =
        {
          contents: 'write',
          'pull-requests': 'write',
          issues: 'write'
        }

      @auto_merge_workflow.do_job(:enable_automerge) do
        do_name('Enable Auto-merge')
        do_if('github.event.pull_request.draft == false')
        do_runs_on(DEFAULT_UBUNTU_VERSION)

        do_step('Checkout') do
          do_uses('actions/checkout@v4')
          do_with(
            {
              ref: '${{github.event.pull_request.base.sha}}'
            }
          )
        end

        do_step('Check if PR author is a code owner') do
          do_id('check')
          do_shell('bash')
          do_env(
            {
              GH_TOKEN: '${{secrets.GH_PAT}}',
              AUTHOR: '${{github.event.pull_request.user.login}}',
              ORG: '${{github.repository_owner}}'
            }
          )
          do_run(
            <<~BASH
              set -euo pipefail

              # Find the CODEOWNERS file (GitHub checks these three locations)
              for path in .github/CODEOWNERS CODEOWNERS docs/CODEOWNERS; do
                if [ -f "$path" ]; then CODEOWNERS="$path"; break; fi
              done
              if [ -z "${CODEOWNERS:-}" ]; then
                echo "No CODEOWNERS file found"
                echo "is_owner=false" >> "$GITHUB_OUTPUT"
                exit 0
              fi

              # Collect @handles only from the catch-all (*) line — the repo-wide code owners
              handles=$(grep -E '^\\*\\s' "$CODEOWNERS" \\
                | grep -oE '@[A-Za-z0-9_.\\-]+(/[A-Za-z0-9_.\\-]+)?' \\
                | sort -u)

              is_owner=false
              for h in $handles; do
                entry="${h#@}"
                if [[ "$entry" == */* ]]; then
                  # Team handle: org/team-slug
                  team_org="${entry%/*}"
                  team_slug="${entry#*/}"
                  if gh api "orgs/${team_org}/teams/${team_slug}/memberships/${AUTHOR}" \\
                       --jq '.state' 2>/dev/null | grep -q active; then
                    is_owner=true
                    break
                  fi
                else
                  # Individual user handle
                  if [ "$entry" = "$AUTHOR" ]; then
                    is_owner=true
                    break
                  fi
                fi
              done

              echo "is_owner=${is_owner}" >> "$GITHUB_OUTPUT"
              echo "PR author ${AUTHOR} is_owner=${is_owner}"
            BASH
          )
        end

        do_step('Approve PR') do
          do_if("steps.check.outputs.is_owner == 'true'")
          do_shell('bash')
          do_env(
            {
              GH_TOKEN: '${{secrets.GITHUB_TOKEN}}',
              PR: '${{github.event.pull_request.number}}'
            }
          )
          do_run('gh pr review --approve "$PR"')
        end

        do_step('Enable auto-merge') do
          do_if("steps.check.outputs.is_owner == 'true'")
          do_shell('bash')
          do_env(
            {
              GH_TOKEN: '${{secrets.GITHUB_TOKEN}}',
              PR: '${{github.event.pull_request.number}}'
            }
          )
          do_run('gh pr merge --auto --squash "$PR"')
        end
      end

      @auto_merge_workflow.write('.github/workflows/auto-merge.yml')
    end
  end
end
