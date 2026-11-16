# frozen_string_literal: true

require 'active_support/core_ext/object/deep_dup'

require_relative '../ghb'
require_relative 'workflow/job'

module GHB
  # Splits a unit-test job into parallel shard jobs behind an aggregator job that keeps the original check names.
  class TestShards
    RAILS_TASKS = %i[test test:system].freeze
    JEST_KEY = :jest
    KEYS = (RAILS_TASKS + [JEST_KEY]).freeze
    MAX_SHARDS = 32
    SHARD_JOB_ID = /_unit_tests(?:_[a-z_]+)?_shards\z/
    SHARD_FILES = '"${SHARD_FILES[@]}"'
    RAILS_TASK_TOKEN = /(?<=\s)(?:\$\{\{\s*matrix\.task\s*\}\}|test:system|test(?: "\$\{SHARD_FILES\[@\]\}")?)(?=\s|\z)/
    RAILS_PREFIX_LINES = [/\ASHARD_ALL=\$\(/, /\A\[ -n "\$\{SHARD_ALL\}" \]/, /\Amapfile -t SHARD_FILES /, /\ASHARD_FILES=\(\); while /, /\Aif \[ "\$\{#SHARD_FILES\[@\]\}" /].freeze
    RAILS_SPLIT_TEST = %r{ && .*?\bbin/rails test "\$\{SHARD_FILES\[@\]\}"}
    RAILS_COMMAND = %r{\A.*?\bbin/rails\b}
    RAILS_DEFAULT_COMMAND = 'bin/rails db:test:prepare ${{matrix.task}}'
    RAILS_FILES = {
      test: "find test -name '*_test.rb' -not -path 'test/system/*'",
      'test:system': "find test/system -name '*_test.rb'"
    }.freeze
    JEST_LINE = %r{(?:\A|[\s/])jest(?:\s|\z)}
    JEST_SHARD_FLAG = /\s+--shard(?:=|\s+)\S+/
    DEFAULT_ARTIFACT_NAME = 'failure-artifacts-${{strategy.job-index}}'
    SHARD_ARTIFACT_NAME = 'failure-artifacts-${{github.job}}-${{strategy.job-index}}'
    AGGREGATOR_TIMEOUT_MINUTES = 5
    private_constant :RAILS_TASKS, :JEST_KEY, :MAX_SHARDS, :SHARD_JOB_ID, :SHARD_FILES, :RAILS_TASK_TOKEN, :RAILS_PREFIX_LINES, :RAILS_SPLIT_TEST, :RAILS_COMMAND, :RAILS_DEFAULT_COMMAND, :RAILS_FILES, :JEST_LINE, :JEST_SHARD_FLAG, :DEFAULT_ARTIFACT_NAME, :SHARD_ARTIFACT_NAME, :AGGREGATOR_TIMEOUT_MINUTES
    public_constant :KEYS

    def self.shard_job?(job_id)
      job_id.to_s.match?(SHARD_JOB_ID)
    end

    def self.parse(value)
      value.split(',').reject(&:empty?).to_h do |entry|
        key, count = entry.split('=', 2)
        raise(ConfigError, "Invalid --test_shards entry '#{entry}': expected one of #{KEYS.join(', ')}") unless KEYS.include?(key&.to_sym)
        raise(ConfigError, "Invalid --test_shards entry '#{entry}': the shard count must be a whole number from 1 to #{MAX_SHARDS}") unless count&.match?(/\A\d+\z/) && Integer(count, 10).between?(1, MAX_SHARDS)

        [key.to_sym, Integer(count, 10)]
      end
    end

    def initialize(old_workflow:, new_workflow:, shards:)
      @old_workflow = old_workflow
      @new_workflow = new_workflow
      @shards = shards
      @consumed = []
    end

    # A sharded job's test steps live in its shard jobs, so regeneration carries from the first one.
    def carry_source(base_id)
      old_shard_ids(base_id).first || base_id
    end

    # Undoes the shard rewrites on a job carried from an old shard job, giving back the plain unit-test job.
    def normalize(job, base_id, language)
      job.strategy = @old_workflow.jobs[base_id]&.strategy&.deep_dup || {}
      job.steps.each { |step| step.with[:name] = DEFAULT_ARTIFACT_NAME if step.with[:name] == SHARD_ARTIFACT_NAME }

      test_steps(job, language).each do |step|
        lines = step.run.lines(chomp: true).reject { |line| RAILS_PREFIX_LINES.any? { |prefix| line.match?(prefix) } }
        lines.map! { |line| line.include?(SHARD_FILES) ? line.sub(RAILS_SPLIT_TEST, ' ${{matrix.task}}').sub(RAILS_TASK_TOKEN, '${{matrix.task}}') : line }
        lines.map! { |line| line.match?(JEST_LINE) ? line.gsub(JEST_SHARD_FLAG, '') : line }
        step.run = join_lines(lines, step.run)
      end
    end

    def apply(job, base_id, language)
      if language[:short_name] == 'ruby'
        tasks = RAILS_TASKS.select { |task| @shards.key?(task) }
        split_rails(job, base_id, language, tasks) if tasks.any?
      elsif language[:unit_test_framework_name] == 'Jest' && @shards.key?(JEST_KEY)
        split_jest(job, base_id, language)
      end
    end

    def unused_keys
      @shards.keys - @consumed
    end

    private

    def old_shard_ids(base_id)
      @old_workflow.jobs.keys.select { |id| TestShards.shard_job?(id) && id.to_s.start_with?("#{base_id}_") }
    end

    def test_steps(job, language)
      name = language[:unit_test_framework_name]
      job.steps.select { |step| step.run && (step.name == name || step.name.start_with?("#{name} (")) }
    end

    def join_lines(lines, original)
      lines.join("\n") + (original.end_with?("\n") ? "\n" : '')
    end

    def split_rails(job, base_id, language, tasks)
      raise(ConfigError, "--test_shards #{tasks.join(', ')}: needs a Rails app (bin/rails and a test directory)") unless File.exist?('bin/rails') && Dir.exist?('test')

      steps = test_steps(job, language)
      steps.each { |step| step.run = RAILS_DEFAULT_COMMAND if step.run.strip == language[:unit_test_framework_default] }
      rails_steps = steps.select { |step| rails_line_index(step.run.lines(chomp: true)) }
      raise(ConfigError, "--test_shards #{tasks.join(', ')}: no `bin/rails ... test` command found in the #{language[:unit_test_framework_name]} step of #{base_id}") if rails_steps.empty?

      shard_jobs =
        tasks.map do |task|
          count = @shards[task]
          shard_job(job, :"#{base_id}_#{task.to_s.tr(':', '_')}_shards", "#{job.name} (#{task} ${{matrix.shard}}/#{count})", count) do |shard|
            test_steps(shard, language).each { |step| step.run = rails_shard_run(step.run, task, count) }
          end
        end

      result = shard_result_expression(tasks, shard_jobs)
      replace_with_aggregator(job, base_id, shard_jobs, result, { 'fail-fast': false, matrix: { task: tasks.map(&:to_s) } })
      @consumed.concat(tasks)
    end

    def rails_line_index(lines)
      lines.rindex { |line| line.match?(%r{\bbin/rails\b}) && line.match?(RAILS_TASK_TOKEN) }
    end

    def rails_shard_run(run, task, count)
      lines = run.lines(chomp: true)
      index = rails_line_index(lines)
      return run if index.nil?

      line = lines[index]
      last_token = line.to_enum(:scan, RAILS_TASK_TOKEN).map { Regexp.last_match }
                       .last
      head = line[0...last_token.begin(0)].rstrip
      tail = line[last_token.end(0)..]
      rails = head[RAILS_COMMAND]
      # Rails reads arguments after another task (db:test:prepare) as more commands, so test files need their own call.
      lines[index] = head == rails ? "#{rails} test #{SHARD_FILES}#{tail}" : "#{head} && #{rails.lstrip} test #{SHARD_FILES}#{tail}"

      prefix = [
        "SHARD_ALL=$(#{RAILS_FILES[task]} | sort)",
        "[ -n \"${SHARD_ALL}\" ] || { echo 'No test files found'; exit 1; }",
        "SHARD_FILES=(); while IFS= read -r file; do SHARD_FILES+=(\"${file}\"); done < <(printf '%s\\n' \"${SHARD_ALL}\" | awk -v shard='${{matrix.shard}}' 'NR % #{count} == shard % #{count}')",
        "if [ \"${#SHARD_FILES[@]}\" -eq 0 ]; then echo 'No test files in this shard'; exit 0; fi"
      ]

      join_lines(prefix + lines, run)
    end

    def split_jest(job, base_id, language)
      count = @shards[JEST_KEY]
      steps = test_steps(job, language)
      raise(ConfigError, "--test_shards jest: no jest command found in the #{language[:unit_test_framework_name]} step of #{base_id}") unless steps.any? { |step| step.run.lines.any? { |line| line.match?(JEST_LINE) } }

      shard_jobs = [
        shard_job(job, :"#{base_id}_shards", "#{job.name} (${{matrix.shard}}/#{count})", count) do |shard|
          test_steps(shard, language).each do |step|
            lines = step.run.lines(chomp: true).map { |line| line.match?(JEST_LINE) ? "#{line.gsub(JEST_SHARD_FLAG, '')} --shard=${{matrix.shard}}/#{count}" : line }
            step.run = join_lines(lines, step.run)
          end
        end
      ]

      replace_with_aggregator(job, base_id, shard_jobs, "${{needs.#{shard_jobs.first.id}.result}}", {})
      @consumed << JEST_KEY
    end

    def shard_job(job, id, name, count)
      Job.new(id).tap do |shard|
        shard.copy_properties(job)
        Job::COPYABLE_PROPERTIES.each { |property| shard.public_send(:"#{property}=", shard.public_send(property).deep_dup) }
        shard.steps = job.steps.map(&:dup)
        shard.name = name
        shard.strategy = { 'fail-fast': false, matrix: { shard: (1..count).to_a } }
        shard.steps.each { |step| step.with[:name] = SHARD_ARTIFACT_NAME if step.with[:name] == DEFAULT_ARTIFACT_NAME }
        yield(shard)
      end
    end

    def shard_result_expression(tasks, shard_jobs)
      return "${{needs.#{shard_jobs.first.id}.result}}" if tasks.one?

      "${{matrix.task == '#{tasks.last}' && needs.#{shard_jobs.last.id}.result || needs.#{shard_jobs.first.id}.result}}"
    end

    # Keeps the job id, name and matrix, so required checks and downstream `needs` stay unchanged.
    def replace_with_aggregator(job, base_id, shard_jobs, result, strategy)
      condition = job.if.to_s.delete_prefix('${{').delete_suffix('}}')

      aggregator =
        Job.new(base_id).tap do |agg|
          agg.do_name(job.name)
          agg.do_runs_on(DEFAULT_UBUNTU_VERSION)
          agg.do_needs(job.needs + shard_jobs.map { |shard| shard.id.to_s })
          agg.do_if("${{always() && (#{condition.empty? ? 'true' : condition})}}")
          agg.do_timeout_minutes(AGGREGATOR_TIMEOUT_MINUTES)
          agg.do_strategy(strategy) unless strategy.empty?
          agg.do_step('Check Shards') do |step|
            step.do_shell('bash')
            step.env[:RESULT] = result
            step.do_run("echo \"Shard jobs: ${RESULT}\"\n[ \"${RESULT}\" = success ]\n")
          end
        end

      jobs =
        @new_workflow.jobs.each_with_object({}) do |(id, existing), ordered|
          if id == base_id
            shard_jobs.each { |shard| ordered[shard.id] = shard }
            ordered[id] = aggregator
          else
            ordered[id] = existing
          end
        end

      @new_workflow.jobs = jobs
    end
  end
end
