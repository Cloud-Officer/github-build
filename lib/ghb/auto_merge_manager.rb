# frozen_string_literal: true

require 'fileutils'

module GHB
  # Manages the auto-approve workflow for code owners. The workflow only
  # approves code-owner PRs; it never merges, so it is named "Auto-approve".
  class AutoMergeManager
    OLD_WORKFLOW_FILE = '.github/workflows/auto-merge.yml'
    WORKFLOW_FILE = '.github/workflows/auto-approve.yml'

    # Bash run by the "Check if PR author is a code owner" step. Resolves the
    # CODEOWNERS file, collects @handles from the catch-all (*) line, and sets
    # step output is_owner=true when the PR author matches a user or team.
    CODEOWNERS_CHECK_SCRIPT = <<~BASH
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

      # Collect @handles only from the catch-all (*) line — the repo-wide code owners.
      # `|| true` keeps the pipeline from aborting under `set -euo pipefail` when there
      # is no `*` line (grep exits 1); empty handles then degrade to is_owner=false below.
      handles=$(grep -E '^\\*\\s' "$CODEOWNERS" \\
        | grep -oE '@[A-Za-z0-9_.\\-]+(/[A-Za-z0-9_.\\-]+)?' \\
        | sort -u || true)

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

    # Bash run by the "Approve PR" step. GitHub rejects approving your own PR, so
    # when GH_BOT_PAT resolves to the same account that opened the PR (e.g. the
    # dependency-update bot approving its own PRs) we skip instead of failing the
    # job. Human code-owner PRs (author != bot) are still approved as before.
    APPROVE_SCRIPT = <<~BASH
      set -euo pipefail

      APPROVER=$(gh api user --jq .login)
      if [ "$APPROVER" = "$AUTHOR" ]; then
        echo "Approver $APPROVER is the PR author; skipping self-approval."
        exit 0
      fi

      gh pr review --approve "$PR"
    BASH

    private_constant :OLD_WORKFLOW_FILE, :WORKFLOW_FILE, :CODEOWNERS_CHECK_SCRIPT, :APPROVE_SCRIPT

    def initialize(auto_merge_workflow:)
      @auto_merge_workflow = auto_merge_workflow
    end

    def save
      puts('    Adding auto-approve workflow...')

      @auto_merge_workflow.on =
        {
          pull_request_target:
            {
              types: %w[opened reopened ready_for_review synchronize]
            }
        }

      # Least privilege: the only GITHUB_TOKEN consumer is actions/checkout (base SHA),
      # which needs contents: read. Both gh steps authenticate via GH_PAT / GH_BOT_PAT,
      # so the workflow token needs no write scopes.
      @auto_merge_workflow.permissions =
        {
          contents: 'read'
        }

      # Cancel superseded runs on rapid pushes to the same PR.
      @auto_merge_workflow.concurrency =
        {
          group: 'auto-approve-${{github.event.pull_request.number}}',
          'cancel-in-progress': true
        }

      @auto_merge_workflow.do_job(:auto_approve) do
        do_name('Auto-approve')
        # Skip drafts, and never run the privileged pull_request_target token
        # against code checked out from a fork.
        do_if('github.event.pull_request.draft == false && github.event.pull_request.head.repo.full_name == github.repository')
        do_runs_on(DEFAULT_UBUNTU_VERSION)

        do_step('Checkout') do
          do_uses(GHB.external_action('actions/checkout'))
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
          do_run(CODEOWNERS_CHECK_SCRIPT)
        end

        do_step('Approve PR') do
          do_if("steps.check.outputs.is_owner == 'true'")
          do_shell('bash')
          do_env(
            {
              GH_TOKEN: '${{secrets.GH_BOT_PAT}}',
              AUTHOR: '${{github.event.pull_request.user.login}}',
              PR: '${{github.event.pull_request.number}}'
            }
          )
          do_run(APPROVE_SCRIPT)
        end
      end

      # Remove the legacy auto-merge.yml so regenerated repos do not end up
      # running both the old and the renamed workflow.
      FileUtils.rm_f(OLD_WORKFLOW_FILE)

      @auto_merge_workflow.write(
        WORKFLOW_FILE,
        header: "# AUTO-GENERATED by github-build (auto_merge_manager.rb). Do not edit directly; changes will be overwritten.\n"
      )
    end
  end
end
