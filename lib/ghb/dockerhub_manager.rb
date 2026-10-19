# frozen_string_literal: true

require_relative '../ghb'

module GHB
  # Manages DockerHub workflow configuration.
  class DockerhubManager
    VERIFY_DEFAULT_BRANCH_SCRIPT = <<~BASH
      status="$(gh api "repos/${GITHUB_REPOSITORY}/compare/${DEFAULT_BRANCH}...${GITHUB_SHA}" --jq .status)"

      case "${status}" in
        identical|behind) ;;
        *)
          echo "::error::Tag ${GITHUB_REF_NAME} points at ${GITHUB_SHA}, which is not on ${DEFAULT_BRANCH} (compare status: ${status}); refusing to publish."
          exit 1
          ;;
      esac
    BASH
    private_constant :VERIFY_DEFAULT_BRANCH_SCRIPT

    def initialize(dockerhub_workflow:)
      @dockerhub_workflow = dockerhub_workflow
    end

    def save
      return unless File.exist?('.dockerhub')

      puts('    Adding dockerhub...')
      @dockerhub_workflow.on =
        {
          push:
            {
              tags:
                %w[**]
            }
        }

      @dockerhub_workflow.permissions =
        {
          contents: 'read'
        }

      @dockerhub_workflow.do_job(:push_to_registry) do
        do_name('Push Docker Image to Docker Hub')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        # Docker Hub push authenticates via DOCKER_USERNAME/DOCKER_PASSWORD, so no packages:write (that scope is for GHCR).
        do_permissions(
          {
            contents: 'read',
            attestations: 'write',
            'id-token': 'write'
          }
        )

        # Only commits already on the default branch passed its required checks.
        do_step('Verify Tag Is On Default Branch') do
          do_env(
            {
              GH_TOKEN: '${{github.token}}',
              DEFAULT_BRANCH: '${{github.event.repository.default_branch}}'
            }
          )
          do_run(VERIFY_DEFAULT_BRANCH_SCRIPT)
        end

        do_step('Publish Docker image') do
          do_uses("cloud-officer/ci-actions/docker@#{CI_ACTIONS_VERSION}")
          do_with(
            {
              username: '${{secrets.DOCKER_USERNAME}}',
              password: '${{secrets.DOCKER_PASSWORD}}'
            }
          )
        end
      end

      @dockerhub_workflow.write('.github/workflows/docker.yml', header: GHB.generated_header('dockerhub_manager.rb'))
    end
  end
end
