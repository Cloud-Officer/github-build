# frozen_string_literal: true

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

      # Workflow-level least-privilege default. The single job below opts into the
      # write scopes it needs; declaring contents: read here forces any job added
      # later to request write scopes deliberately rather than inheriting the
      # repository's (often broader) default GITHUB_TOKEN permissions.
      @dockerhub_workflow.permissions =
        {
          contents: 'read'
        }

      @dockerhub_workflow.do_job(:push_to_registry) do
        do_name('Push Docker Image to Docker Hub')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        # Permission scopes are the minimum required by cloud-officer/ci-actions/docker@v3:
        # - contents:read     for actions/checkout
        # - id-token:write    for actions/attest-build-provenance OIDC signing via Sigstore
        # - attestations:write for publishing the build provenance attestation to GitHub
        # Docker Hub push itself authenticates via DOCKER_USERNAME / DOCKER_PASSWORD,
        # so packages:write (which is for GHCR) is intentionally NOT requested here.
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
