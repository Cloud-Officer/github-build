# frozen_string_literal: true

module GHB
  # Builds the Vercel deploy jobs (beta_deploy / rc_deploy / prod_deploy).
  #
  # This is the Vercel counterpart to CodeDeployJobBuilder: where an appspec.yml
  # repo gets AWS CodeDeploy *_deploy jobs, a Vercel repo gets *_deploy jobs that
  # drive the Vercel CLI. A repo is treated as Vercel when a vercel.json marker
  # file is present, or its package.json declares a "vercel" or "next"
  # dependency.
  #
  # CodeDeploy takes precedence: when appspec.yml exists these jobs are left to
  # CodeDeployJobBuilder so the *_deploy job names do not collide.
  #
  # Each job emits four generated steps (Setup, Install Vercel CLI, Pull Vercel
  # Environment Information, Deploy Project to Vercel). Any other step found on an
  # existing *_deploy job - typically project-specific `vercel alias ...` steps,
  # whose domains the generator cannot know - is preserved and appended, so
  # regeneration stops stripping them (the bug the pnp-web-next hotfix worked
  # around).
  class VercelJobBuilder
    # Generated deploy jobs: environment key => display name + Vercel CLI target.
    # prod publishes with `--prod`; beta and rc deploy a preview build and
    # capture the resulting URL so preserved alias steps can reference it via
    # steps.deploy.outputs.url. "RC" is upper-cased to match the hand-written
    # Vercel template (CodeDeploy's equivalent reads "Rc Deploy").
    DEPLOYS = {
      beta: { name: 'Beta Deploy', target: 'preview' },
      rc: { name: 'RC Deploy', target: 'preview' },
      prod: { name: 'Prod Deploy', target: 'production' }
    }.freeze
    private_constant :DEPLOYS

    # Names of the steps this builder generates; every other step on an existing
    # *_deploy job is treated as a custom step to preserve.
    GENERATED_STEP_NAMES = ['Setup', 'Install Vercel CLI', 'Pull Vercel Environment Information', 'Deploy Project to Vercel'].freeze
    private_constant :GENERATED_STEP_NAMES

    # JavaScript version files; when one is present the ci-actions setup reads the
    # Node version from it, so a node-version carried over from a previous Setup
    # step is dropped (mirrors LanguageJobBuilder#build_setup_step).
    NODE_VERSION_FILES = %w[.node-version .nvmrc].freeze
    private_constant :NODE_VERSION_FILES

    DEPLOY_JOB_TIMEOUT_MINUTES = 60
    private_constant :DEPLOY_JOB_TIMEOUT_MINUTES

    def initialize(context:)
      @options = context.options
      @old_workflow = context.old_workflow
      @new_workflow = context.new_workflow
    end

    def build
      return if File.exist?('appspec.yml') # CodeDeploy owns the *_deploy jobs
      return unless vercel?

      puts('    Adding Vercel deploys...')

      # Capture needs once, before any deploy job is added, so every deploy job
      # depends on the build/test/lint jobs only - not on each other.
      needs = @new_workflow.deploy_needs

      DEPLOYS.each do |environment, config|
        build_deploy_job(environment, config, needs)
      end
    end

    private

    # A repo deploys to Vercel when a vercel.json marker exists, or package.json
    # declares a "vercel" or "next" dependency. Mirrors the Next.js detection
    # RepositoryConfigurator uses to require the "Vercel" status check.
    def vercel?
      return true if File.exist?('vercel.json')

      File.exist?('package.json') && File.read('package.json').match?(/"(?:vercel|next)"/)
    end

    def build_deploy_job(environment, config, needs)
      job_id = :"#{environment}_deploy"
      job_name = config[:name]
      target = config[:target]
      if_statement = build_if_statement(environment, needs)
      old_job = @old_workflow.jobs[job_id]
      builder = self

      @new_workflow.do_job(job_id) do
        copy_properties(old_job)
        do_name(job_name)
        do_runs_on(DEFAULT_UBUNTU_VERSION)
        do_needs(needs)
        do_if(if_statement)
        do_timeout_minutes(DEPLOY_JOB_TIMEOUT_MINUTES) if timeout_minutes.nil?

        if env.empty?
          do_env(
            {
              VERCEL_ORG_ID: '${{secrets.VERCEL_ORG_ID}}',
              VERCEL_PROJECT_ID: '${{secrets.VERCEL_PROJECT_ID}}'
            }
          )
        end

        builder.__send__(:build_setup_step, self, old_job)
        builder.__send__(:build_install_step, self, old_job)
        builder.__send__(:build_pull_step, self, old_job, target)
        builder.__send__(:build_deploy_step, self, old_job, target)
        builder.__send__(:append_custom_steps, self, old_job)
      end
    end

    # The per-environment `if:` gating a single deploy job: run on its deploy
    # trigger only if none of the build/test/lint jobs failed. Built from the
    # captured needs list (not live @jobs.keys) so the three jobs never reference
    # one another.
    def build_if_statement(environment, needs)
      base_condition = "always() && needs.variables.outputs.DEPLOY_ON_#{environment.to_s.upcase} == '1'"
      job_conditions = needs.map { |job| "needs.#{job}.result != 'failure'" }

      "${{#{([base_condition] + job_conditions).join(' && ')}}}"
    end

    def build_setup_step(job, old_job)
      # A version file pins the Node version, so drop a carried-over node-version.
      drop_node_version = NODE_VERSION_FILES.any? { |file| File.exist?(file) }

      job.do_step('Setup') do
        copy_properties(find_step(old_job&.steps, name))
        do_uses("cloud-officer/ci-actions/setup@#{CI_ACTIONS_VERSION}")

        with.delete(:'node-version') if drop_node_version

        if with.empty?
          do_with(
            {
              'ssh-key': '${{secrets.SSH_KEY}}',
              'github-token': '${{secrets.GH_PAT}}',
              'aws-access-key-id': '${{secrets.AWS_ACCESS_KEY_ID}}',
              'aws-secret-access-key': '${{secrets.AWS_SECRET_ACCESS_KEY}}',
              'aws-region': '${{secrets.AWS_DEFAULT_REGION}}'
            }
          )
        end

        with[:'github-token'] = '${{secrets.GH_PAT}}'
      end
    end

    def build_install_step(job, old_job)
      job.do_step('Install Vercel CLI') do
        copy_properties(find_step(old_job&.steps, name))
        do_run('npm install --global vercel@latest') if run.nil?
      end
    end

    def build_pull_step(job, old_job, target)
      job.do_step('Pull Vercel Environment Information') do
        copy_properties(find_step(old_job&.steps, name))
        do_run("vercel pull --yes --environment=#{target} --token=${{ secrets.VERCEL_TOKEN }}") if run.nil?
      end
    end

    def build_deploy_step(job, old_job, target)
      preview = target != 'production'

      job.do_step('Deploy Project to Vercel') do
        copy_properties(find_step(old_job&.steps, name))
        do_id('deploy') if preview
        next unless run.nil?

        do_run(
          if preview
            'echo "url=$(vercel deploy --token=${{ secrets.VERCEL_TOKEN }})" >> "${GITHUB_OUTPUT}"'
          else
            'vercel deploy --prod --token=${{ secrets.VERCEL_TOKEN }}'
          end
        )
      end
    end

    # Re-append any non-generated steps (e.g. project-specific `vercel alias`
    # steps) from the existing job so regeneration preserves them.
    def append_custom_steps(job, old_job)
      return if old_job.nil?

      old_job.steps.each do |step|
        job.steps << step unless GENERATED_STEP_NAMES.include?(step.name)
      end
    end
  end
end
