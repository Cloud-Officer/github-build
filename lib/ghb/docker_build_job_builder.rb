# frozen_string_literal: true

require_relative '../ghb'

module GHB
  # Builds the "Docker Build" jobs that check the image builds on each architecture without publishing it.
  class DockerBuildJobBuilder
    RUNNERS = {
      amd64: DEFAULT_UBUNTU_VERSION,
      arm64: 'ubuntu-24.04-arm'
    }.freeze
    private_constant :RUNNERS

    def initialize(context:)
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
    end

    def build
      return unless File.exist?('.dockerhub')

      puts('    Adding Docker build...')

      RUNNERS.each { |architecture, runner| build_job(architecture, runner) }
    end

    private

    def build_job(architecture, runner)
      @new_workflow.carry_job(:"docker_build_#{architecture}", from: @old_workflow) do
        do_name("Docker Build (#{architecture})")
        do_permissions({ contents: 'read' })
        do_runs_on(carried_from&.runs_on || runner)
        do_needs(%w[variables])
        do_if("${{needs.variables.outputs.SKIP_TESTS != '1'}}")

        carry_step('Docker Build') do
          do_uses("cloud-officer/ci-actions/docker@#{CI_ACTIONS_VERSION}")
          with[:push] = 'false'
          with[:platforms] = "linux/#{architecture}"
        end
      end
    end
  end
end
