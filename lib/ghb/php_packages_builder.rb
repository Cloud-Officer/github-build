# frozen_string_literal: true

require_relative '../ghb'

module GHB
  # Switches the PHP jobs from setup-php to Ubuntu apt packages when the repository lists them in php-packages.txt.
  class PhpPackagesBuilder
    PHP_PACKAGES_FILE = 'php-packages.txt'
    ENV_KEY = :'PHP-PACKAGES'
    SETUP_ACTION = 'cloud-officer/ci-actions/setup'
    LINTER_ACTIONS = %w[cloud-officer/ci-actions/linters/phpcs cloud-officer/ci-actions/linters/phpstan].freeze
    public_constant :PHP_PACKAGES_FILE
    private_constant :ENV_KEY, :SETUP_ACTION, :LINTER_ACTIONS

    def self.parse(content)
      content.each_line.flat_map { |line| line.sub(/#.*/, '').split }
    end

    def initialize(context:)
      @new_workflow = context.new_workflow
    end

    def build
      return unless File.exist?(PHP_PACKAGES_FILE)

      packages = PhpPackagesBuilder.parse(File.read(PHP_PACKAGES_FILE))
      raise(ConfigError, "#{PHP_PACKAGES_FILE} lists no package") if packages.empty?

      puts("    Installing PHP from apt (#{PHP_PACKAGES_FILE})...")
      @new_workflow.env[ENV_KEY] = packages.join(' ')

      @new_workflow.jobs.each_value do |job|
        adopt(job) unless job.nil?
      end
    end

    private

    def adopt(job)
      steps = job.steps.select { |step| php_step?(step) }
      return if steps.empty?

      steps.each do |step|
        step.with[:'php-packages'] = "${{env.#{ENV_KEY}}}"
        step.with.merge!(GHB.secrets(:aws)) if step.with.keys.none? { |key| key.to_s.start_with?('aws-') }
      end
    end

    def php_step?(step)
      action = step.uses.to_s.split('@').first
      return true if LINTER_ACTIONS.include?(action)

      action == SETUP_ACTION && step.with.keys.any? { |key| key.to_s.start_with?('php-') }
    end
  end
end
