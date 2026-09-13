# frozen_string_literal: true

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
      old_job = @old_workflow.jobs[:"docker_build_#{architecture}"]

      @new_workflow.do_job(:"docker_build_#{architecture}") do
        copy_properties(old_job)
        do_name("Docker Build (#{architecture})")
        do_permissions({ contents: 'read' })
        do_runs_on(old_job&.runs_on || runner)
        do_needs(%w[variables])
        do_if("${{needs.variables.outputs.SKIP_TESTS != '1'}}")

        do_step('Docker Build') do
          copy_properties(find_step(old_job&.steps, name))
          do_uses("cloud-officer/ci-actions/docker@#{CI_ACTIONS_VERSION}")
          with[:push] = 'false'
          with[:platforms] = "linux/#{architecture}"
        end
      end
    end
  end
end
