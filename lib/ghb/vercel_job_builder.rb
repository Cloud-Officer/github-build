# frozen_string_literal: true

require_relative '../ghb'

module GHB
  # CodeDeployJobBuilder owns the *_deploy jobs when appspec.yml exists, so these are skipped then.
  class VercelJobBuilder
    # "RC" is upper-cased to match the hand-written Vercel template.
    DEPLOYS = {
      beta: { name: 'Beta Deploy', target: 'preview' },
      rc: { name: 'RC Deploy', target: 'preview' },
      prod: { name: 'Prod Deploy', target: 'production' }
    }.freeze
    private_constant :DEPLOYS

    GENERATED_STEP_NAMES = ['Setup', 'Install Vercel CLI', 'Pull Vercel Environment Information', 'Deploy Project to Vercel'].freeze
    private_constant :GENERATED_STEP_NAMES

    # When one is present the ci-actions setup reads the Node version from it.
    NODE_VERSION_FILES = %w[.node-version .nvmrc].freeze
    private_constant :NODE_VERSION_FILES

    DEPLOY_JOB_TIMEOUT_MINUTES = 60
    private_constant :DEPLOY_JOB_TIMEOUT_MINUTES

    # The Vercel CLI reads its token from the environment, keeping it out of argv.
    VERCEL_TOKEN_ENV = '${{secrets.VERCEL_TOKEN}}'
    LEGACY_TOKEN_FLAG = ' --token=${{ secrets.VERCEL_TOKEN }}'
    private_constant :VERCEL_TOKEN_ENV, :LEGACY_TOKEN_FLAG

    def initialize(context:)
      @options = context.options
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
    end

    def build
      return if File.exist?('appspec.yml') # CodeDeploy owns the *_deploy jobs
      return unless GHB.vercel?

      puts('    Adding Vercel deploys...')

      # Captured before any deploy job is added so deploy jobs never depend on each other.
      needs = @new_workflow.deploy_needs

      DEPLOYS.each do |environment, config|
        build_deploy_job(environment, config, needs)
      end
    end

    private

    def build_deploy_job(environment, config, needs)
      job_id = :"#{environment}_deploy"
      job_name = config[:name]
      target = config[:target]
      if_statement = build_if_statement(environment, needs)

      @new_workflow.carry_job(job_id, from: @old_workflow) do |job|
        job.do_name(job_name)
        job.do_runs_on(DEFAULT_UBUNTU_VERSION)
        job.do_needs(needs)
        job.do_if(if_statement)
        job.do_timeout_minutes(DEPLOY_JOB_TIMEOUT_MINUTES) if job.timeout_minutes.nil?

        if job.env.empty?
          job.do_env(
            {
              VERCEL_ORG_ID: '${{secrets.VERCEL_ORG_ID}}',
              VERCEL_PROJECT_ID: '${{secrets.VERCEL_PROJECT_ID}}'
            }
          )
        end

        job.do_env(job.env.merge(VERCEL_TOKEN: VERCEL_TOKEN_ENV)) unless job.env.key?(:VERCEL_TOKEN)

        build_setup_step(job)
        build_install_step(job)
        build_pull_step(job, target)
        build_deploy_step(job, target)
        append_custom_steps(job)
      end
    end

    def build_if_statement(environment, needs)
      base_condition = "always() && needs.variables.outputs.DEPLOY_ON_#{environment.to_s.upcase} == '1'"
      job_conditions = needs.map { |job| "needs.#{job}.result != 'failure'" }

      "${{#{([base_condition] + job_conditions).join(' && ')}}}"
    end

    def build_setup_step(job)
      # A version file pins the Node version, so drop a carried-over node-version.
      drop_node_version = NODE_VERSION_FILES.any? { |file| File.exist?(file) }

      job.carry_step('Setup') do
        do_uses("cloud-officer/ci-actions/setup@#{CI_ACTIONS_VERSION}")

        with.delete(:'node-version') if drop_node_version

        default_with(GHB.secrets(:ssh, :github_token, :aws))

        with[:'github-token'] = '${{github.token}}'
      end
    end

    def build_install_step(job)
      job.carry_step('Install Vercel CLI') do
        do_run('npm install --global vercel@latest') if run.nil?
      end
    end

    def build_pull_step(job, target)
      command = "vercel pull --yes --environment=#{target}"
      legacy_command = "#{command}#{LEGACY_TOKEN_FLAG}"

      job.carry_step('Pull Vercel Environment Information') do
        do_run(command) if run.nil? || run == legacy_command
      end
    end

    def build_deploy_step(job, target)
      preview = target != 'production'
      command = preview ? 'echo "url=$(vercel deploy)" >> "${GITHUB_OUTPUT}"' : 'vercel deploy --prod'
      legacy_command = preview ? %(echo "url=$(vercel deploy#{LEGACY_TOKEN_FLAG})" >> "${GITHUB_OUTPUT}") : "vercel deploy --prod#{LEGACY_TOKEN_FLAG}"

      job.carry_step('Deploy Project to Vercel') do
        do_id('deploy') if preview
        do_run(command) if run.nil? || run == legacy_command
      end
    end

    def append_custom_steps(job)
      return if job.carried_from.nil?

      job.carried_from.steps.each do |step|
        job.steps << step unless GENERATED_STEP_NAMES.include?(step.name)
      end
    end
  end
end
