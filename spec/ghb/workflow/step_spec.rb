# frozen_string_literal: true

RSpec.describe(GHB::Step) do # rubocop:disable RSpec/SpecFilePathFormat
  describe '#initialize' do
    it 'creates a step with just a name' do
      step = described_class.new('Test Step')
      expect(step.name).to(eq('Test Step'))
    end

    it 'creates a step with all options' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      step = described_class.new(
        'Test Step',
        {
          id: 'test-id',
          if: 'always()',
          uses: 'actions/checkout@v4',
          run: 'echo hello',
          shell: 'bash',
          with: { key: 'value' },
          env: { MY_VAR: 'test' },
          continue_on_error: true,
          timeout_minutes: 10
        }
      )

      expect(step.id).to(eq('test-id'))
      expect(step.if).to(eq('always()'))
      expect(step.uses).to(eq('actions/checkout@v4'))
      expect(step.run).to(eq('echo hello'))
      expect(step.shell).to(eq('bash'))
      expect(step.with).to(eq({ key: 'value' }))
      expect(step.env).to(eq({ MY_VAR: 'test' }))
      expect(step.continue_on_error).to(be(true))
      expect(step.timeout_minutes).to(eq(10))
    end

    it 'defaults with and env to empty hashes' do # rubocop:disable RSpec/MultipleExpectations
      step = described_class.new('Test Step')
      expect(step.with).to(eq({}))
      expect(step.env).to(eq({}))
    end
  end

  describe '#copy_properties' do
    it 'copies properties from another step' do # rubocop:disable RSpec/MultipleExpectations
      source = described_class.new('Source', { id: 'source-id', run: 'echo source' })
      target = described_class.new('Target')

      target.copy_properties(source, %i[id run])

      expect(target.id).to(eq('source-id'))
      expect(target.run).to(eq('echo source'))
    end

    it 'does nothing when object is nil' do
      step = described_class.new('Test')
      expect { step.copy_properties(nil, %i[id]) }
        .not_to(raise_error)
    end

    it 'raises error for unknown property' do
      source = described_class.new('Source')
      target = described_class.new('Target')

      expect { target.copy_properties(source, %i[unknown_property]) }
        .to(raise_error(RuntimeError))
    end
  end

  describe 'do_* methods' do
    let(:step) { described_class.new('Test') }

    it '#do_id sets id when not nil' do
      step.do_id('new-id')
      expect(step.id).to(eq('new-id'))
    end

    it '#do_id does not set id when nil' do
      step.do_id('original')
      step.do_id(nil)
      expect(step.id).to(eq('original'))
    end

    it '#do_if sets if condition' do
      step.do_if('success()')
      expect(step.if).to(eq('success()'))
    end

    it '#do_name sets name' do
      step.do_name('New Name')
      expect(step.name).to(eq('New Name'))
    end

    it '#do_uses sets uses' do
      step.do_uses('actions/setup-node@v4')
      expect(step.uses).to(eq('actions/setup-node@v4'))
    end

    it '#do_run sets run command' do
      step.do_run('npm install')
      expect(step.run).to(eq('npm install'))
    end

    it '#do_shell sets shell' do
      step.do_shell('pwsh')
      expect(step.shell).to(eq('pwsh'))
    end

    it '#do_with sets with hash' do
      step.do_with({ node_version: '20' })
      expect(step.with).to(eq({ node_version: '20' }))
    end

    it '#do_env sets env hash' do
      step.do_env({ CI: 'true' })
      expect(step.env).to(eq({ CI: 'true' }))
    end

    it '#do_continue_on_error sets continue_on_error' do
      step.do_continue_on_error(true)
      expect(step.continue_on_error).to(be(true))
    end

    it '#do_timeout_minutes sets timeout' do
      step.do_timeout_minutes(30)
      expect(step.timeout_minutes).to(eq(30))
    end
  end

  describe '#find_step' do
    let(:step) { described_class.new('Finder') }

    it 'finds a step by name' do # rubocop:disable RSpec/ExampleLength
      steps = [
        described_class.new('First'),
        described_class.new('Second'),
        described_class.new('Third')
      ]

      result = step.find_step(steps, 'Second')
      expect(result.name).to(eq('Second'))
    end

    it 'returns nil when step not found' do
      steps = [described_class.new('First')]
      result = step.find_step(steps, 'Missing')
      expect(result).to(be_nil)
    end

    it 'returns nil when steps is nil' do
      result = step.find_step(nil, 'Any')
      expect(result).to(be_nil)
    end
  end

  describe '#to_h' do
    it 'converts step to hash with all properties' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      step = described_class.new(
        'Test Step',
        {
          id: 'test-id',
          if: 'always()',
          uses: 'actions/checkout@v4',
          shell: 'bash',
          run: 'echo hello',
          with: { key: 'value' },
          env: { MY_VAR: 'test' },
          continue_on_error: true,
          timeout_minutes: 10
        }
      )

      hash = step.to_h

      expect(hash[:name]).to(eq('Test Step'))
      expect(hash[:id]).to(eq('test-id'))
      expect(hash[:if]).to(eq('always()'))
      expect(hash[:uses]).to(eq('actions/checkout@v4'))
      expect(hash[:shell]).to(eq('bash'))
      expect(hash[:run]).to(eq('echo hello'))
      expect(hash[:with]).to(eq({ key: 'value' }))
      expect(hash[:env]).to(eq({ MY_VAR: 'test' }))
      expect(hash[:'continue-on-error']).to(be(true))
      expect(hash[:'timeout-minutes']).to(eq(10))
    end

    it 'excludes nil and empty values' do # rubocop:disable RSpec/MultipleExpectations
      step = described_class.new('Minimal Step')
      hash = step.to_h

      expect(hash.keys).to(eq([:name]))
      expect(hash[:name]).to(eq('Minimal Step'))
    end
  end
end
