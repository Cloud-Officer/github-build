# frozen_string_literal: true

RSpec.describe(GHB::Job) do # rubocop:disable RSpec/SpecFilePathFormat
  describe '#initialize' do
    it 'creates a job with an id' do
      job = described_class.new(:build)
      expect(job.id).to(eq(:build))
    end

    it 'initializes with default empty values' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      job = described_class.new(:test)

      expect(job.name).to(be_nil)
      expect(job.permissions).to(eq({}))
      expect(job.needs).to(eq([]))
      expect(job.if).to(be_nil)
      expect(job.runs_on).to(be_nil)
      expect(job.environment).to(eq({}))
      expect(job.concurrency).to(eq({}))
      expect(job.outputs).to(eq({}))
      expect(job.env).to(eq({}))
      expect(job.defaults).to(eq({}))
      expect(job.steps).to(eq([]))
      expect(job.timeout_minutes).to(be_nil)
      expect(job.strategy).to(eq({}))
      expect(job.continue_on_error).to(be_nil)
      expect(job.container).to(eq({}))
      expect(job.services).to(eq({}))
      expect(job.uses).to(be_nil)
      expect(job.with).to(eq({}))
      expect(job.secrets).to(eq({}))
    end
  end

  describe '#copy_properties' do
    it 'copies properties from another job' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      source = described_class.new(:source)
      source.name = 'Source Job'
      source.runs_on = 'ubuntu-latest'

      target = described_class.new(:target)
      target.copy_properties(source, %i[name runs_on])

      expect(target.name).to(eq('Source Job'))
      expect(target.runs_on).to(eq('ubuntu-latest'))
    end

    it 'does nothing when object is nil' do
      job = described_class.new(:test)
      expect { job.copy_properties(nil, %i[name]) }
        .not_to(raise_error)
    end

    it 'raises error for unknown property' do
      source = described_class.new(:source)
      target = described_class.new(:target)

      expect { target.copy_properties(source, %i[unknown_property]) }
        .to(raise_error(RuntimeError))
    end
  end

  describe 'do_* methods' do
    let(:job) { described_class.new(:test) }

    it '#do_name sets the name' do
      job.do_name('My Job')
      expect(job.name).to(eq('My Job'))
    end

    it '#do_permissions sets permissions' do
      job.do_permissions({ contents: 'read' })
      expect(job.permissions).to(eq({ contents: 'read' }))
    end

    it '#do_needs adds to needs array' do
      job.do_needs(:build)
      expect(job.needs).to(eq([:build]))
    end

    it '#do_needs accepts array' do
      job.do_needs(%i[build lint])
      expect(job.needs).to(eq(%i[build lint]))
    end

    it '#do_if sets the if condition' do
      job.do_if("github.event_name == 'push'")
      expect(job.if).to(eq("github.event_name == 'push'"))
    end

    it '#do_runs_on sets the runner' do
      job.do_runs_on('ubuntu-latest')
      expect(job.runs_on).to(eq('ubuntu-latest'))
    end

    it '#do_environment sets environment' do
      job.do_environment({ name: 'production' })
      expect(job.environment).to(eq({ name: 'production' }))
    end

    it '#do_concurrency sets concurrency' do
      job.do_concurrency({ group: 'deploy', cancel_in_progress: true })
      expect(job.concurrency).to(eq({ group: 'deploy', cancel_in_progress: true }))
    end

    it '#do_outputs sets outputs' do
      job.do_outputs({ version: '${{ steps.version.outputs.value }}' })
      expect(job.outputs).to(eq({ version: '${{ steps.version.outputs.value }}' }))
    end

    it '#do_env sets env' do
      job.do_env({ CI: 'true' })
      expect(job.env).to(eq({ CI: 'true' }))
    end

    it '#do_defaults sets defaults' do
      job.do_defaults({ run: { shell: 'bash' } })
      expect(job.defaults).to(eq({ run: { shell: 'bash' } }))
    end

    it '#do_timeout_minutes sets timeout' do
      job.do_timeout_minutes(60)
      expect(job.timeout_minutes).to(eq(60))
    end

    it '#do_strategy sets strategy' do
      job.do_strategy({ matrix: { os: %w[ubuntu macos] } })
      expect(job.strategy).to(eq({ matrix: { os: %w[ubuntu macos] } }))
    end

    it '#do_continue_on_error sets continue_on_error' do
      job.do_continue_on_error(true)
      expect(job.continue_on_error).to(be(true))
    end

    it '#do_container sets container' do
      job.do_container({ image: 'ruby:3.2' })
      expect(job.container).to(eq({ image: 'ruby:3.2' }))
    end

    it '#do_services sets services' do
      job.do_services({ redis: { image: 'redis:7' } })
      expect(job.services).to(eq({ redis: { image: 'redis:7' } }))
    end

    it '#do_uses sets uses' do
      job.do_uses('./.github/workflows/reusable.yml')
      expect(job.uses).to(eq('./.github/workflows/reusable.yml'))
    end

    it '#do_with sets with' do
      job.do_with({ config: 'production' })
      expect(job.with).to(eq({ config: 'production' }))
    end

    it '#do_secrets sets secrets' do
      job.do_secrets({ token: '${{ secrets.DEPLOY_TOKEN }}' })
      expect(job.secrets).to(eq({ token: '${{ secrets.DEPLOY_TOKEN }}' }))
    end
  end

  describe '#do_step' do
    let(:job) { described_class.new(:test) }

    it 'adds a step to the job' do # rubocop:disable RSpec/MultipleExpectations
      job.do_step('Checkout')
      expect(job.steps.length).to(eq(1))
      expect(job.steps.first.name).to(eq('Checkout'))
    end

    it 'adds a step with options' do
      job.do_step('Checkout', { uses: 'actions/checkout@v4' })
      expect(job.steps.first.uses).to(eq('actions/checkout@v4'))
    end

    it 'executes block on step' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      job.do_step('Setup') do
        do_uses('actions/setup-node@v4')
        do_with({ node_version: '20' })
      end

      step = job.steps.first
      expect(step.uses).to(eq('actions/setup-node@v4'))
      expect(step.with).to(eq({ node_version: '20' }))
    end
  end

  describe '#to_h' do
    it 'converts job to hash with all properties' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      job = described_class.new(:build)
      job.do_name('Build Job')
      job.do_runs_on('ubuntu-latest')
      job.do_permissions({ contents: 'read' })
      job.do_needs(:lint)
      job.do_if('success()')
      job.do_env({ CI: 'true' })
      job.do_timeout_minutes(30)
      job.do_step('Checkout', { uses: 'actions/checkout@v4' })

      hash = job.to_h

      expect(hash[:name]).to(eq('Build Job'))
      expect(hash[:'runs-on']).to(eq('ubuntu-latest'))
      expect(hash[:permissions]).to(eq({ contents: 'read' }))
      expect(hash[:needs]).to(eq([:lint]))
      expect(hash[:if]).to(eq('success()'))
      expect(hash[:env]).to(eq({ CI: 'true' }))
      expect(hash[:'timeout-minutes']).to(eq(30))
      expect(hash[:steps]).to(be_an(Array))
      expect(hash[:steps].first[:uses]).to(eq('actions/checkout@v4'))
    end

    it 'uses default timeout when not specified' do
      job = described_class.new(:test)
      hash = job.to_h

      expect(hash[:'timeout-minutes']).to(eq(GHB::DEFAULT_JOB_TIMEOUT_MINUTES))
    end

    it 'excludes empty collections' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      job = described_class.new(:minimal)
      hash = job.to_h

      expect(hash).not_to(have_key(:permissions))
      expect(hash).not_to(have_key(:needs))
      expect(hash).not_to(have_key(:env))
      expect(hash).not_to(have_key(:steps))
    end
  end
end
