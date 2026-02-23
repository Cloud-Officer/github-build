# frozen_string_literal: true

module GHB
  # Manages DockerHub workflow configuration.
  class DockerhubManager
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

      @dockerhub_workflow.do_job(:push_to_registry) do
        do_name('Push Docker Image to Docker Hub')
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_permissions(
          {
            packages: 'write',
            contents: 'read',
            attestations: 'write',
            'id-token': 'write'
          }
        )

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

      @dockerhub_workflow.write('.github/workflows/docker.yml')
    end
  end
end
