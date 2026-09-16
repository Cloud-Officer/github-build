# frozen_string_literal: true

require 'psych'

module WorkflowCustomizer
  VERCEL_TARGETS = { beta_deploy: 'preview', rc_deploy: 'preview', prod_deploy: 'production' }.freeze
  LEGACY_TOKEN_FLAG = ' --token=${{ secrets.VERCEL_TOKEN }}'
  CUSTOM_STEP = { name: 'Custom Step', run: 'echo custom' }.freeze
  private_constant :VERCEL_TARGETS, :LEGACY_TOKEN_FLAG, :CUSTOM_STEP

  module_function

  def customize(yaml, legacy_vercel: false)
    workflow = Psych.safe_load(yaml)
    workflow['env'] = with_kept_entry(workflow['env'], 'CUSTOM_WORKFLOW_ENV')

    workflow['jobs'].each do |job_id, job|
      job['timeout-minutes'] = 42
      job['runs-on'] = 'custom-runner'
      job['env'] = with_kept_entry(job['env'], 'CUSTOM_JOB_ENV')
      job['env'].delete('VERCEL_TOKEN') if legacy_vercel
      steps = job['steps'] || []
      steps.each { |step| customize_step(step, job_id, legacy_vercel) }
      steps << CUSTOM_STEP.transform_keys(&:to_s)
    end

    Psych.dump(workflow)
  end

  def with_kept_entry(hash, key)
    (hash || {}).merge(key => 'kept')
  end

  def customize_step(step, job_id, legacy_vercel)
    step['with']['custom-input'] = 'kept' if step['with']
    step['env'] = with_kept_entry(step['env'], 'CUSTOM_STEP_ENV')
    target = VERCEL_TARGETS[job_id.to_sym]

    if legacy_vercel && target && step['name'] == 'Pull Vercel Environment Information'
      step['run'] = "vercel pull --yes --environment=#{target}#{LEGACY_TOKEN_FLAG}"
    elsif legacy_vercel && target && step['name'] == 'Deploy Project to Vercel'
      step['run'] = target == 'production' ? "vercel deploy --prod#{LEGACY_TOKEN_FLAG}" : %(echo "url=$(vercel deploy#{LEGACY_TOKEN_FLAG})" >> "${GITHUB_OUTPUT}")
    elsif step['run']
      step['run'] = "#{step['run']} --customized"
    end
  end
end
