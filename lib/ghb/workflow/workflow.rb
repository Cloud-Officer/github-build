# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'fileutils'
require 'psych'

require_relative 'job'

module GHB
  class Workflow
    GITHUB_ENV_VAR_REGEX = /\$\{GITHUB_([A-Z_]+)\}/
    private_constant :GITHUB_ENV_VAR_REGEX

    def initialize(name)
      @name = name
      @run_name = nil
      @on = {}
      @permissions = {}
      @env = {}
      @defaults = {}
      @concurrency = {}
      @jobs = {}
    end

    attr_accessor :name, :run_name, :on, :permissions, :env, :defaults, :concurrency, :jobs

    def do_name(name)
      @name = name
    end

    def do_run_name(name)
      @run_name = name
    end

    def do_on(event)
      @on = event unless event.nil?
    end

    def do_permissions(permissions)
      @permissions = permissions unless permissions.nil?
    end

    def do_env(env)
      @env = env unless env.nil?
    end

    def do_defaults(global_defaults)
      @defaults = global_defaults unless global_defaults.nil?
    end

    def do_concurrency(concurrency)
      @concurrency = concurrency unless concurrency.nil?
    end

    def do_job(id, &block)
      job = Job.new(id)
      job.instance_eval(&block) if block
      @jobs[id] = job
    end

    # Job names this workflow's deploy jobs must wait on (all current jobs).
    def deploy_needs
      @jobs.keys.map(&:to_s)
    end

    # The shared `if:` expression gating deploy jobs (aws / codedeploy):
    # run on a deploy trigger, only if no prior job failed. Returns the
    # ${{ }}-wrapped expression ready to pass to do_if.
    def deploy_if_statement
      base_condition = "always() && (needs.variables.outputs.DEPLOY_ON_BETA == '1' || needs.variables.outputs.DEPLOY_ON_RC == '1' || needs.variables.outputs.DEPLOY_ON_PROD == '1')"
      job_conditions = @jobs.keys.map { |job_name| "needs.#{job_name}.result != 'failure'" }

      "${{#{([base_condition] + job_conditions).join(' && ')}}}"
    end

    def read(file)
      content = File.read(file)

      # Convert github_token to github-token on load for consistency
      content.gsub!('github_token:', 'github-token:')

      begin
        parsed = Psych.safe_load(content)
      rescue Psych::SyntaxError => e
        raise(ConfigError, "Invalid YAML in #{file}: #{e.message}")
      end

      return if parsed.nil?

      raise(ConfigError, "Invalid workflow file #{file}: expected a mapping at the document root, got #{parsed.class}") unless parsed.is_a?(Hash)

      workflow_data = parsed.deep_symbolize_keys

      @name = workflow_data[:name]
      @run_name = workflow_data[:'run-name']
      @on = workflow_data[:on] || {}
      @permissions = workflow_data[:permissions] || {}
      @env = workflow_data[:env] || {}
      @defaults = workflow_data[:defaults] || {}
      @concurrency = workflow_data[:concurrency] || {}
      @jobs = {}

      workflow_data[:jobs]&.each do |job_id, job_data|
        do_job(job_id) do
          do_name(job_data[:name])
          do_permissions(job_data[:permissions])
          do_needs(job_data[:needs])
          do_if(job_data[:if])
          do_runs_on(job_data[:'runs-on'])
          do_environment(job_data[:environment])
          do_concurrency(job_data[:concurrency])
          do_outputs(job_data[:outputs])
          do_env(job_data[:env])
          do_defaults(job_data[:defaults])
          do_timeout_minutes(job_data[:'timeout-minutes'])
          do_strategy(job_data[:strategy])
          do_continue_on_error(job_data[:'continue-on-error'])
          do_container(job_data[:container])
          do_services(job_data[:services])
          do_uses(job_data[:uses])
          do_with(job_data[:with])
          do_secrets(job_data[:secrets])

          job_data[:steps]&.each do |step|
            do_step(step[:name]) do
              do_id(step[:id])
              do_if(step[:if])
              do_name(step[:name])
              do_uses(step[:uses])
              do_run(step[:run])
              do_shell(step[:shell])
              do_with(step[:with])
              do_env(step[:env])
              do_continue_on_error(step[:'continue-on-error'])
              do_timeout_minutes(step[:'timeout-minutes'])
            end
          end
        end
      end
    end

    def write(file, header: '')
      FileUtils.mkdir_p(File.dirname(file))
      data = rewrite_github_refs(to_h.deep_stringify_keys)
      content = header + data.to_yaml({ line_width: -1 })

      # Convert secrets.GITHUB_TOKEN to secrets.GH_PAT for higher rate limits
      content.gsub!('${{secrets.GITHUB_TOKEN}}', '${{secrets.GH_PAT}}') unless file.match?(/auto-(merge|approve)/)

      File.write(file, content)
    end

    def to_h
      hash = {}
      hash[:name] = @name unless @name.nil?
      hash[:'run-name'] = @run_name unless @run_name.nil?
      hash[:on] = @on.sort.to_h unless @on.empty?
      hash[:permissions] = @permissions.sort.to_h unless @permissions.empty?
      hash[:env] = @env.sort.to_h unless @env.empty?
      hash[:defaults] = @defaults.sort.to_h unless @defaults.empty?
      hash[:concurrency] = @concurrency unless @concurrency.empty?
      hash[:jobs] = @jobs.transform_values(&:to_h)
      hash
    end

    private

    # Rewrite ${GITHUB_*} -> ${{github.*}} in YAML values, but skip shell `run:`
    # bodies - there ${GITHUB_*} is the runner-exported env-var form and
    # ${{github.*}} is opaque to shellcheck (SC2193).
    def rewrite_github_refs(node)
      case node
      when Hash
        node.each_with_object({}) do |(key, value), acc|
          acc[key] = key.to_s == 'run' ? value : rewrite_github_refs(value)
        end
      when Array
        node.map { |item| rewrite_github_refs(item) }
      when String
        node.gsub(GITHUB_ENV_VAR_REGEX) { "${{github.#{::Regexp.last_match(1).downcase}}}" }
      else
        node
      end
    end
  end
end
