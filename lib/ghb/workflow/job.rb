# frozen_string_literal: true

require_relative '../../ghb'
require_relative 'copyable_properties'
require_relative 'step'

module GHB
  # Instance variables map to the YAML schema; new copyable ivars go in COPYABLE_PROPERTIES.
  class Job
    include CopyableProperties

    # Properties carried over from a previously-generated job by copy_properties.
    COPYABLE_PROPERTIES = %i[name permissions needs if runs_on environment concurrency outputs env defaults timeout_minutes strategy continue_on_error container services uses with secrets].freeze
    public_constant :COPYABLE_PROPERTIES

    def self.evaluate(target, block)
      if block&.arity == 1
        block.call(target)
      elsif block
        target.instance_eval(&block)
      end
    end

    def initialize(id)
      @id = id
      @name = nil
      @permissions = {}
      @needs = []
      @if = nil
      @runs_on = nil
      @environment = {}
      @concurrency = {}
      @outputs = {}
      @env = {}
      @defaults = {}
      @steps = []
      @timeout_minutes = nil
      @strategy = {}
      @continue_on_error = nil
      @container = {}
      @services = {}
      @uses = nil
      @with = {}
      @secrets = {}
      @carried_from = nil
    end

    attr_accessor :id, :name, :permissions, :needs, :if, :runs_on, :environment, :concurrency, :outputs, :env, :defaults, :steps, :timeout_minutes, :strategy, :continue_on_error, :container, :services, :uses, :with, :secrets
    attr_reader :carried_from

    def carry_over(old_job)
      copy_properties(old_job)
      @carried_from = old_job
    end

    def do_name(name)
      @name = name
    end

    def do_permissions(permissions)
      @permissions = permissions unless permissions.nil?
    end

    def do_needs(needs)
      return if needs.nil?

      if needs.is_a?(Array)
        @needs = needs
      else
        @needs << needs unless needs.nil?
      end
    end

    def do_if(if_statement)
      @if = if_statement unless if_statement.nil?
    end

    def do_runs_on(runs_on)
      @runs_on = runs_on unless runs_on.nil?
    end

    def do_environment(environment)
      @environment = environment unless environment.nil?
    end

    def do_concurrency(concurrency)
      @concurrency = concurrency unless concurrency.nil?
    end

    def do_outputs(outputs)
      @outputs = outputs unless outputs.nil?
    end

    def do_env(env)
      @env = env unless env.nil?
    end

    def do_defaults(global_defaults)
      @defaults = global_defaults unless global_defaults.nil?
    end

    def do_step(name, options = {}, &block)
      step = Step.new(name, options)
      Job.evaluate(step, block)
      @steps << step
      step
    end

    def carry_step(name, from: carried_from, &block)
      do_step(name) do |step|
        step.copy_properties(step.find_step(from&.steps, name))
        Job.evaluate(step, block)
      end
    end

    def do_timeout_minutes(timeout_minutes)
      @timeout_minutes = timeout_minutes
    end

    def do_strategy(strategy)
      @strategy = strategy unless strategy.nil?
    end

    def do_continue_on_error(continue_on_error)
      @continue_on_error = continue_on_error
    end

    def do_container(container)
      @container = container unless container.nil?
    end

    def do_services(services)
      @services = services unless services.nil?
    end

    def do_uses(uses)
      @uses = uses
    end

    def do_with(with)
      @with = with unless with.nil?
    end

    def do_secrets(secrets)
      @secrets = secrets unless secrets.nil?
    end

    def to_h
      hash = {}
      hash[:name] = @name unless @name.nil?
      hash[:permissions] = @permissions unless @permissions.empty?
      hash[:'runs-on'] = @runs_on unless @runs_on.nil?
      hash[:needs] = @needs unless @needs.empty?
      hash[:if] = @if unless @if.nil?
      hash[:environment] = @environment unless @environment.empty?
      hash[:concurrency] = @concurrency unless @concurrency.empty?
      hash[:outputs] = @outputs unless @outputs.empty?
      hash[:env] = @env unless @env.empty?
      hash[:defaults] = @defaults unless @defaults.empty?
      hash[:'timeout-minutes'] = @timeout_minutes || DEFAULT_JOB_TIMEOUT_MINUTES
      hash[:strategy] = @strategy unless @strategy.empty?
      hash[:'continue-on-error'] = @continue_on_error unless @continue_on_error.nil?
      hash[:container] = @container unless @container.empty?
      hash[:services] = @services unless @services.empty?
      hash[:uses] = @uses unless @uses.nil?
      hash[:with] = @with unless @with.empty?
      hash[:secrets] = @secrets unless @secrets.empty?
      hash[:steps] = @steps.map(&:to_h) unless @steps.empty?
      hash
    end
  end
end
