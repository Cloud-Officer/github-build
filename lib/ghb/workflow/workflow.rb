# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'fileutils'
require 'pathname'
require 'psych'

require_relative 'job'

module GHB
  class Workflow
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

    def read(file)
      workflow_data = Psych.safe_load(File.read(file))&.deep_symbolize_keys
      @name = workflow_data[:name]
      @run_name = workflow_data[:'run-name']
      @on = workflow_data[:on] || []
      @permissions = workflow_data[:permissions] || []
      @env = workflow_data[:env] || []
      @defaults = workflow_data[:defaults] || {}
      @concurrency = workflow_data[:concurrency] || {}
      @jobs = {}

      workflow_data[:jobs].each do |job_id, job_data|
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

          job_data[:steps].each do |step|
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
      content = header + to_h.deep_stringify_keys.to_yaml({ line_width: -1 })

      # Convert old-style ${GITHUB_*} patterns to new-style ${{github.*}}
      content.gsub!(/\$\{GITHUB_([A-Z_]+)\}/) do |_match|
        var_name = ::Regexp.last_match(1).downcase
        "${{github.#{var_name}}}"
      end

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
  end
end
