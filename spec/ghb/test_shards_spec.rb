# frozen_string_literal: true

RSpec.describe(GHB::TestShards) do # rubocop:disable RSpec/MultipleMemoizedHelpers
  let(:old_workflow) { GHB::Workflow.new('Build')                                                                  }
  let(:new_workflow) { GHB::Workflow.new('Build')                                                                  }
  let(:shards)       { {}                                                                                          }
  let(:test_shards)  { described_class.new(old_workflow: old_workflow, new_workflow: new_workflow, shards: shards) }

  let(:ruby_language) { { short_name: 'ruby', unit_test_framework_name: 'RSpec', unit_test_framework_default: 'bundle exec rspec --format documentation' } }
  let(:js_language)   { { short_name: 'js', unit_test_framework_name: 'Jest', unit_test_framework_default: 'npx jest' } }

  def add_job(workflow, id, name:, run:, step_name: 'RSpec', strategy: nil)
    workflow.do_job(id) do |job|
      job.do_name(name)
      job.do_runs_on('ubuntu-latest-8-cores')
      job.do_needs(%w[variables])
      job.do_if("${{needs.variables.outputs.SKIP_TESTS != '1'}}")
      job.do_strategy(strategy)
      job.do_services({ postgres: { image: 'postgres' } })
      job.do_step('Setup') { |step| step.do_uses('cloud-officer/ci-actions/setup@v3') }
      job.do_step(step_name) do |step|
        step.do_shell('bash')
        step.do_run(run)
        step.env[:RAILS_ENV] = 'test'
      end
      job.do_step('Upload Failure Artifacts') { |step| step.with[:name] = 'failure-artifacts-${{strategy.job-index}}' }
    end
  end

  def ruby_job(run: 'bin/rails db:test:prepare ${{matrix.task}}')
    add_job(new_workflow, :ruby_unit_tests, name: 'Ruby Unit Tests', run: run, strategy: { 'fail-fast': false, matrix: { task: %w[test test:system] } })
  end

  def step_run(job_id, step_name = 'RSpec')
    new_workflow.jobs[job_id].steps.find { |step| step.name == step_name }
                             .run
  end

  def apply_ruby
    test_shards.apply(new_workflow.jobs[:ruby_unit_tests], :ruby_unit_tests, ruby_language)
  end

  def apply_js
    test_shards.apply(new_workflow.jobs[:js_unit_tests], :js_unit_tests, js_language)
  end

  describe '.parse' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    it 'maps each key to its shard count' do
      expect(described_class.parse('test=4,test:system=2,jest=3')).to(eq(test: 4, 'test:system': 2, jest: 3))
    end

    it 'ignores empty entries' do
      expect(described_class.parse('test=4,,')).to(eq(test: 4))
    end

    it 'accepts the 1 to 32 bounds' do
      expect(described_class.parse('test=1,jest=32')).to(eq(test: 1, jest: 32))
    end

    it 'rejects an unknown key' do
      expect { described_class.parse('rspec=2') }
        .to(raise_error(GHB::ConfigError, /'rspec=2': expected one of test, test:system, jest/))
    end

    %w[test=0 test=33 test=two test= test].each do |entry|
      it "rejects the shard count in '#{entry}'" do
        expect { described_class.parse(entry) }
          .to(raise_error(GHB::ConfigError, /whole number from 1 to 32/))
      end
    end
  end

  describe '.shard_job?' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    it 'recognises the generated shard job ids' do
      expect(%i[ruby_unit_tests_test_shards ruby_unit_tests_test_system_shards js_unit_tests_shards].map { |id| described_class.shard_job?(id) }).to(all(be(true)))
    end

    it 'does not match unit-test or other jobs' do
      expect(%i[ruby_unit_tests js_unit_tests shards variables].map { |id| described_class.shard_job?(id) }).to(all(be(false)))
    end
  end

  describe '#apply for Rails' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    let(:shards) { { test: 4, 'test:system': 2 } }

    around do |example|
      Dir.mktmpdir('ghb-shards') do |dir|
        Dir.chdir(dir) do # rubocop:disable ThreadSafety/DirChdir
          FileUtils.mkdir_p(%w[bin test])
          File.write('bin/rails', '')
          example.run
        end
      end
    end

    before do
      new_workflow.do_job(:variables) { |job| job.do_name('Prepare Variables') }
      ruby_job
      new_workflow.do_job(:licenses) { |job| job.do_name('Licenses Check') }
      apply_ruby
    end

    it 'puts the shard jobs right before the aggregator, keeping other jobs in place' do
      expect(new_workflow.jobs.keys).to(eq(%i[variables ruby_unit_tests_test_shards ruby_unit_tests_test_system_shards ruby_unit_tests licenses]))
    end

    it 'names and sizes each shard job matrix' do # rubocop:disable RSpec/MultipleExpectations
      unit = new_workflow.jobs[:ruby_unit_tests_test_shards]
      system = new_workflow.jobs[:ruby_unit_tests_test_system_shards]

      expect([unit.name, unit.strategy]).to(eq(['Ruby Unit Tests (test ${{matrix.shard}}/4)', { 'fail-fast': false, matrix: { shard: [1, 2, 3, 4] } }]))
      expect([system.name, system.strategy]).to(eq(['Ruby Unit Tests (test:system ${{matrix.shard}}/2)', { 'fail-fast': false, matrix: { shard: [1, 2] } }]))
    end

    it 'keeps the runner, needs, condition and services of the original job' do
      shard = new_workflow.jobs[:ruby_unit_tests_test_shards]

      expect([shard.runs_on, shard.needs, shard.if, shard.services]).to(eq(['ubuntu-latest-8-cores', %w[variables], "${{needs.variables.outputs.SKIP_TESTS != '1'}}", { postgres: { image: 'postgres' } }]))
    end

    it 'gives each shard job its own copy of the job properties' do
      new_workflow.jobs[:ruby_unit_tests_test_shards].services[:postgres][:image] = 'changed'

      expect(new_workflow.jobs[:ruby_unit_tests_test_system_shards].services[:postgres][:image]).to(eq('postgres'))
    end

    it 'runs the unit-test files of its shard, keeping the original command prefix' do # rubocop:disable RSpec/ExampleLength
      expect(step_run(:ruby_unit_tests_test_shards)).to(eq(<<~RUN.chomp))
        SHARD_ALL=$(find test -name '*_test.rb' -not -path 'test/system/*' | sort)
        [ -n "${SHARD_ALL}" ] || { echo 'No test files found'; exit 1; }
        mapfile -t SHARD_FILES < <(printf '%s\\n' "${SHARD_ALL}" | awk -v shard='${{matrix.shard}}' 'NR % 4 == shard % 4')
        if [ "${#SHARD_FILES[@]}" -eq 0 ]; then echo 'No test files in this shard'; exit 0; fi
        bin/rails db:test:prepare && bin/rails test "${SHARD_FILES[@]}"
      RUN
    end

    it 'runs only system-test files in the system shards' do
      expect(step_run(:ruby_unit_tests_test_system_shards)).to(start_with("SHARD_ALL=$(find test/system -name '*_test.rb' | sort)"))
    end

    it 'keeps the step env' do
      expect(
        new_workflow.jobs[:ruby_unit_tests_test_shards].steps.find { |step| step.name == 'RSpec' }
        .env
      ).to(eq(RAILS_ENV: 'test'))
    end

    it 'names failure artifacts per shard job so uploads do not collide' do
      expect(new_workflow.jobs[:ruby_unit_tests_test_shards].steps.last.with[:name]).to(eq('failure-artifacts-${{github.job}}-${{strategy.job-index}}'))
    end

    it 'replaces the original job with an aggregator keeping its id, name and task matrix' do # rubocop:disable RSpec/MultipleExpectations
      aggregator = new_workflow.jobs[:ruby_unit_tests]

      expect([aggregator.name, aggregator.runs_on, aggregator.strategy]).to(eq(['Ruby Unit Tests', 'ubuntu-latest', { 'fail-fast': false, matrix: { task: %w[test test:system] } }]))
      expect([aggregator.needs, aggregator.if]).to(eq([%w[variables ruby_unit_tests_test_shards ruby_unit_tests_test_system_shards], "${{always() && (needs.variables.outputs.SKIP_TESTS != '1')}}"]))
    end

    it 'passes each aggregator leg only when its own task shards succeeded' do # rubocop:disable RSpec/MultipleExpectations
      step = new_workflow.jobs[:ruby_unit_tests].steps.first

      expect(step.env[:RESULT]).to(eq("${{matrix.task == 'test:system' && needs.ruby_unit_tests_test_system_shards.result || needs.ruby_unit_tests_test_shards.result}}"))
      expect(step.run).to(include('[ "${RESULT}" = success ]'))
    end

    it 'consumes the Rails keys' do
      expect(test_shards.unused_keys).to(eq([]))
    end
  end

  describe '#apply for Rails command variants' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    let(:shards) { { test: 2 } }

    around do |example|
      Dir.mktmpdir('ghb-shards') do |dir|
        Dir.chdir(dir) do # rubocop:disable ThreadSafety/DirChdir
          FileUtils.mkdir_p(%w[bin test])
          File.write('bin/rails', '')
          example.run
        end
      end
    end

    it 'keeps setup lines and flags after the task' do
      ruby_job(run: "bin/setup-ci\nbin/rails test -v\n")
      apply_ruby

      expect(step_run(:ruby_unit_tests_test_shards).lines(chomp: true).last(2)).to(eq(['bin/setup-ci', 'bin/rails test "${SHARD_FILES[@]}" -v']))
    end

    it 'keeps a trailing newline on the run' do
      ruby_job(run: "bin/rails test\n")
      apply_ruby

      expect(step_run(:ruby_unit_tests_test_shards)).to(end_with("bin/rails test \"${SHARD_FILES[@]}\"\n"))
    end

    it 'replaces the generated rspec default with the Rails test command' do
      ruby_job(run: 'bundle exec rspec --format documentation')
      apply_ruby

      expect(step_run(:ruby_unit_tests_test_shards).lines.last).to(eq('bin/rails db:test:prepare && bin/rails test "${SHARD_FILES[@]}"'))
    end

    it 'repeats an env prefix on the separate test call and puts it back when unsharded' do # rubocop:disable RSpec/MultipleExpectations
      ruby_job(run: 'RAILS_ENV=test bin/rails db:test:prepare ${{matrix.task}} -v')
      apply_ruby
      sharded = step_run(:ruby_unit_tests_test_shards).lines.last

      expect(sharded).to(eq('RAILS_ENV=test bin/rails db:test:prepare && RAILS_ENV=test bin/rails test "${SHARD_FILES[@]}" -v'))
      expect(sharded.sub(described_class.const_get(:RAILS_SPLIT_TEST), ' ${{matrix.task}}')).to(eq('RAILS_ENV=test bin/rails db:test:prepare ${{matrix.task}} -v'))
    end

    it 'gives a single-task aggregator a one-value matrix and a direct result' do # rubocop:disable RSpec/MultipleExpectations
      ruby_job
      apply_ruby
      aggregator = new_workflow.jobs[:ruby_unit_tests]

      expect(aggregator.strategy).to(eq({ 'fail-fast': false, matrix: { task: %w[test] } }))
      expect(aggregator.steps.first.env[:RESULT]).to(eq('${{needs.ruby_unit_tests_test_shards.result}}'))
    end

    it 'runs the aggregator unconditionally when the job had no condition' do
      ruby_job
      new_workflow.jobs[:ruby_unit_tests].if = nil
      apply_ruby

      expect(new_workflow.jobs[:ruby_unit_tests].if).to(eq('${{always() && (true)}}'))
    end

    it 'fails when the test step has no bin/rails test command' do
      ruby_job(run: 'bundle exec rake spec')

      expect { apply_ruby }
        .to(raise_error(GHB::ConfigError, %r{no `bin/rails ... test` command found in the RSpec step of ruby_unit_tests}))
    end

    it 'fails outside a Rails app' do
      ruby_job
      File.delete('bin/rails')

      expect { apply_ruby }
        .to(raise_error(GHB::ConfigError, /needs a Rails app/))
    end
  end

  describe '#apply for Jest' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    let(:shards) { { jest: 3 } }

    def js_job(run)
      add_job(new_workflow, :js_unit_tests, name: 'JavaScript Unit Tests', run: run, step_name: 'Jest')
    end

    it 'appends the shard flag and keeps the other flags' do
      js_job('npx jest --ci')
      apply_js

      expect(step_run(:js_unit_tests_shards, 'Jest')).to(eq('npx jest --ci --shard=${{matrix.shard}}/3'))
    end

    it 'replaces a shard flag already on the command' do
      js_job("npm run build\nyarn jest --shard 1/2 --ci")
      apply_js

      expect(step_run(:js_unit_tests_shards, 'Jest')).to(eq("npm run build\nyarn jest --ci --shard=${{matrix.shard}}/3"))
    end

    it 'shards the per-directory Jest steps too' do
      js_job('npx jest')
      new_workflow.jobs[:js_unit_tests].do_step('Jest (web)') { |step| step.do_run('cd web && node_modules/.bin/jest') }
      apply_js

      expect(step_run(:js_unit_tests_shards, 'Jest (web)')).to(eq('cd web && node_modules/.bin/jest --shard=${{matrix.shard}}/3'))
    end

    it 'adds a shard job and an aggregator without a matrix' do # rubocop:disable RSpec/MultipleExpectations
      js_job('npx jest')
      apply_js

      expect(new_workflow.jobs[:js_unit_tests_shards].name).to(eq('JavaScript Unit Tests (${{matrix.shard}}/3)'))
      expect([new_workflow.jobs[:js_unit_tests].strategy, new_workflow.jobs[:js_unit_tests].steps.first.env[:RESULT]]).to(eq([{}, '${{needs.js_unit_tests_shards.result}}']))
    end

    it 'fails when the Jest step does not call jest' do
      js_job('npm test')

      expect { apply_js }
        .to(raise_error(GHB::ConfigError, /no jest command found in the Jest step of js_unit_tests/))
    end
  end

  describe '#apply without a matching key' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    let(:shards) { { jest: 2 } }

    it 'leaves a Ruby job alone and reports the key unused' do # rubocop:disable RSpec/MultipleExpectations
      ruby_job
      apply_ruby

      expect(new_workflow.jobs.keys).to(eq(%i[ruby_unit_tests]))
      expect(test_shards.unused_keys).to(eq(%i[jest]))
    end

    it 'leaves a job whose framework is not Jest alone' do
      add_job(new_workflow, :go_unit_tests, name: 'Go Unit Tests', run: 'go test', step_name: 'Testing')
      test_shards.apply(new_workflow.jobs[:go_unit_tests], :go_unit_tests, { short_name: 'go', unit_test_framework_name: 'Testing' })

      expect(new_workflow.jobs.keys).to(eq(%i[go_unit_tests]))
    end
  end

  describe '#carry_source' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    it 'is the job itself when it was not sharded' do
      add_job(old_workflow, :ruby_unit_tests, name: 'Ruby Unit Tests', run: 'bin/rails test')

      expect(test_shards.carry_source(:ruby_unit_tests)).to(eq(:ruby_unit_tests))
    end

    it 'is the first old shard job of that job when it was sharded' do
      add_job(old_workflow, :js_unit_tests_shards, name: 'JavaScript Unit Tests (${{matrix.shard}}/2)', run: 'npx jest')
      add_job(old_workflow, :ruby_unit_tests_test_shards, name: 'Ruby Unit Tests (test)', run: 'bin/rails test')
      add_job(old_workflow, :ruby_unit_tests_test_system_shards, name: 'Ruby Unit Tests (test:system)', run: 'bin/rails test')

      expect(test_shards.carry_source(:ruby_unit_tests)).to(eq(:ruby_unit_tests_test_shards))
    end
  end

  describe '#normalize' do # rubocop:disable RSpec/MultipleMemoizedHelpers
    let(:shards) { { test: 4, 'test:system': 2, jest: 3 } }

    around do |example|
      Dir.mktmpdir('ghb-shards') do |dir|
        Dir.chdir(dir) do # rubocop:disable ThreadSafety/DirChdir
          FileUtils.mkdir_p(%w[bin test])
          File.write('bin/rails', '')
          example.run
        end
      end
    end

    def unshard(job_id, base_id, language)
      sharded = new_workflow
      old = described_class.new(old_workflow: GHB::Workflow.new('Build'), new_workflow: GHB::Workflow.new('Build'), shards: {})
      old.instance_variable_set(:@old_workflow, sharded)
      job = GHB::Job.new(base_id)
      job.carry_over(sharded.jobs[job_id])
      job.steps = sharded.jobs[job_id].steps.map(&:dup)
      old.normalize(job, base_id, language)
      job
    end

    it 'turns a Rails shard job back into the original task-matrix job' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      ruby_job
      apply_ruby
      job = unshard(:ruby_unit_tests_test_shards, :ruby_unit_tests, ruby_language)

      expect(
        job.steps.find { |step| step.name == 'RSpec' }
        .run
      ).to(eq('bin/rails db:test:prepare ${{matrix.task}}'))
      expect([job.strategy, job.steps.last.with[:name]]).to(eq([{ 'fail-fast': false, matrix: { task: %w[test test:system] } }, 'failure-artifacts-${{strategy.job-index}}']))
    end

    it 'drops the Jest shard flag and has no matrix without an old aggregator' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      add_job(new_workflow, :js_unit_tests, name: 'JavaScript Unit Tests', run: "npx jest --ci\n", step_name: 'Jest')
      apply_js
      new_workflow.jobs.delete(:js_unit_tests)
      job = unshard(:js_unit_tests_shards, :js_unit_tests, js_language)

      expect(
        job.steps.find { |step| step.name == 'Jest' }
        .run
      ).to(eq("npx jest --ci\n"))
      expect(job.strategy).to(eq({}))
    end
  end
end
