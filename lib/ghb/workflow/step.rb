# frozen_string_literal: true

module GHB
  # Data model for GitHub Actions step - instance variables map to YAML schema
  class Step
    def initialize(name, options = {})
      @id = options[:id]
      @if = options[:if]
      @name = name
      @uses = options[:uses]
      @run = options[:run]
      @shell = options[:shell]
      @with = options[:with] || {}
      @env = options[:env] || {}
      @continue_on_error = options[:continue_on_error]
      @timeout_minutes = options[:timeout_minutes]
    end

    attr_accessor :id, :if, :name, :uses, :run, :shell, :with, :env, :continue_on_error, :timeout_minutes

    def copy_properties(object, properties)
      return if object.nil?

      properties.each do |property|
        raise("Error: #{object.class} does not have a #{property} property!") unless object.respond_to?(property)

        public_send(:"#{property}=", object.public_send(property))
      end
    end

    def do_id(id)
      @id = id unless id.nil?
    end

    def do_if(if_statement)
      @if = if_statement unless if_statement.nil?
    end

    def do_name(name)
      @name = name unless name.nil?
    end

    def do_uses(uses)
      @uses = uses unless uses.nil?
    end

    def do_run(run)
      @run = run unless run.nil?
    end

    def do_shell(shell)
      @shell = shell unless shell.nil?
    end

    def do_with(with)
      @with = with unless with.nil?
    end

    def do_env(env)
      @env = env unless env.nil?
    end

    def do_continue_on_error(continue_on_error)
      @continue_on_error = continue_on_error unless continue_on_error.nil?
    end

    def do_timeout_minutes(timeout_minutes)
      @timeout_minutes = timeout_minutes unless timeout_minutes.nil?
    end

    def find_step(steps, step_name)
      matching_step = nil

      steps&.each do |step|
        if step.name == step_name
          matching_step = step
          break
        end
      end

      matching_step
    end

    def to_h
      hash = {}
      hash[:name] = @name unless @name.nil?
      hash[:id] = @id unless @id.nil?
      hash[:uses] = @uses unless @uses.nil?
      hash[:shell] = @shell unless @shell.nil?
      hash[:if] = @if unless @if.nil?
      hash[:run] = @run unless @run.nil?
      hash[:with] = @with unless @with.empty?
      hash[:env] = @env unless @env.empty?
      hash[:'continue-on-error'] = @continue_on_error unless @continue_on_error.nil?
      hash[:'timeout-minutes'] = @timeout_minutes unless @timeout_minutes.nil?
      hash
    end
  end
end
