# frozen_string_literal: true

require 'fileutils'

require_relative '../ghb'

module GHB
  class AutoApproveManager
    OLD_WORKFLOW_FILE = '.github/workflows/auto-merge.yml'
    WORKFLOW_FILE = '.github/workflows/auto-approve.yml'

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

    # GitHub rejects self-approval and GH_BOT_PAT lacks contents read, hence the skip and the run-token commit lookup.
    APPROVE_SCRIPT = <<~BASH
      set -euo pipefail

      SUBJECT=$(GH_TOKEN="$GITHUB_TOKEN" gh api "repos/${REPO}/commits/${HEAD_SHA}" --jq .commit.message)
      SUBJECT="${SUBJECT%%$'\\n'*}"
      for trigger in '#skip-all' '#skip-licenses' '#skip-linters' '#skip-tests'; do
        if grep -iqF -- "$trigger" <<< "$SUBJECT"; then
          echo "Head commit uses ${trigger}, so required checks may be skipped; human review is required."
          exit 0
        fi
      done

      APPROVER=$(gh api user --jq .login)
      if [ "$APPROVER" = "$AUTHOR" ]; then
        echo "Approver $APPROVER is the PR author; skipping self-approval."
        exit 0
      fi

      gh pr review --approve "$PR"
    BASH

    private_constant :OLD_WORKFLOW_FILE, :WORKFLOW_FILE, :CODEOWNERS_CHECK_SCRIPT, :APPROVE_SCRIPT

    def initialize(auto_approve_workflow:)
      @auto_approve_workflow = auto_approve_workflow
    end

    def save
      puts('    Adding auto-approve workflow...')

      @auto_approve_workflow.on =
        {
          pull_request_target:
            {
              types: %w[opened reopened ready_for_review synchronize]
            }
        }

      # Membership checks and the approval authenticate via GH_BOT_PAT, so the run token needs only contents: read.
      @auto_approve_workflow.permissions =
        {
          contents: 'read'
        }

      # Cancel superseded runs on rapid pushes to the same PR.
      @auto_approve_workflow.concurrency =
        {
          group: 'auto-approve-${{github.event.pull_request.number}}',
          'cancel-in-progress': true
        }

      @auto_approve_workflow.do_job(:auto_approve) do
        do_name('Auto-approve')
        # Never run the privileged pull_request_target token against code checked out from a fork.
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
              GH_TOKEN: '${{secrets.GH_BOT_PAT}}',
              AUTHOR: '${{github.event.pull_request.user.login}}'
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
              GITHUB_TOKEN: '${{github.token}}',
              AUTHOR: '${{github.event.pull_request.user.login}}',
              PR: '${{github.event.pull_request.number}}',
              REPO: '${{github.repository}}',
              HEAD_SHA: '${{github.event.pull_request.head.sha}}'
            }
          )
          do_run(APPROVE_SCRIPT)
        end
      end

      FileUtils.rm_f(OLD_WORKFLOW_FILE)

      @auto_approve_workflow.write(
        WORKFLOW_FILE,
        header: GHB.generated_header('auto_approve_manager.rb')
      )
    end
  end
end
