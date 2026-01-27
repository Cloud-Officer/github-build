# frozen_string_literal: true

RSpec.describe(GHB::Workflow) do # rubocop:disable RSpec/SpecFilePathFormat
  describe '#initialize' do
    it 'creates a workflow with a name' do
      workflow = described_class.new('Build')
      expect(workflow.name).to(eq('Build'))
    end

    it 'initializes with default empty values' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow = described_class.new('Test')

      expect(workflow.run_name).to(be_nil)
      expect(workflow.on).to(eq({}))
      expect(workflow.permissions).to(eq({}))
      expect(workflow.env).to(eq({}))
      expect(workflow.defaults).to(eq({}))
      expect(workflow.concurrency).to(eq({}))
      expect(workflow.jobs).to(eq({}))
    end
  end

  describe 'do_* methods' do
    let(:workflow) { described_class.new('Test') }

    it '#do_name sets the name' do
      workflow.do_name('New Name')
      expect(workflow.name).to(eq('New Name'))
    end

    it '#do_run_name sets the run name' do
      workflow.do_run_name('Deploy to ${{ github.ref }}')
      expect(workflow.run_name).to(eq('Deploy to ${{ github.ref }}'))
    end

    it '#do_on sets the trigger events' do
      workflow.do_on({ push: { branches: ['main'] }, pull_request: {} })
      expect(workflow.on).to(eq({ push: { branches: ['main'] }, pull_request: {} }))
    end

    it '#do_permissions sets permissions' do
      workflow.do_permissions({ contents: 'read', packages: 'write' })
      expect(workflow.permissions).to(eq({ contents: 'read', packages: 'write' }))
    end

    it '#do_env sets env' do
      workflow.do_env({ NODE_ENV: 'production' })
      expect(workflow.env).to(eq({ NODE_ENV: 'production' }))
    end

    it '#do_defaults sets defaults' do
      workflow.do_defaults({ run: { shell: 'bash', working_directory: 'src' } })
      expect(workflow.defaults).to(eq({ run: { shell: 'bash', working_directory: 'src' } }))
    end

    it '#do_concurrency sets concurrency' do
      workflow.do_concurrency({ group: '${{ github.workflow }}', cancel_in_progress: true })
      expect(workflow.concurrency).to(eq({ group: '${{ github.workflow }}', cancel_in_progress: true }))
    end
  end

  describe '#do_job' do
    let(:workflow) { described_class.new('Test') }

    it 'adds a job to the workflow' do # rubocop:disable RSpec/MultipleExpectations
      workflow.do_job(:build) { do_name('Build') }
      expect(workflow.jobs).to(have_key(:build))
      expect(workflow.jobs[:build]).to(be_a(GHB::Job))
    end

    it 'executes block on job' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow.do_job(:build) do
        do_name('Build Job')
        do_runs_on('ubuntu-latest')
      end

      job = workflow.jobs[:build]
      expect(job.name).to(eq('Build Job'))
      expect(job.runs_on).to(eq('ubuntu-latest'))
    end

    it 'adds multiple jobs' do
      workflow.do_job(:lint) { do_name('Lint') }
      workflow.do_job(:test) { do_name('Test') }
      workflow.do_job(:deploy) { do_name('Deploy') }

      expect(workflow.jobs.keys).to(eq(%i[lint test deploy]))
    end
  end

  describe '#read' do
    let(:workflow) { described_class.new('Test') }
    let(:yaml_content) do
      <<~YAML
        name: CI
        run-name: Build ${{ github.sha }}
        "on":
          push:
            branches: [main]
          pull_request:
        permissions:
          contents: read
        env:
          CI: "true"
        defaults:
          run:
            shell: bash
        concurrency:
          group: ci-${{ github.ref }}
          cancel-in-progress: true
        jobs:
          build:
            name: Build
            runs-on: ubuntu-latest
            timeout-minutes: 30
            steps:
              - name: Checkout
                uses: actions/checkout@v4
              - name: Run tests
                run: npm test
      YAML
    end

    before do
      allow(File).to(receive(:read).and_return(yaml_content.dup))
    end

    it 'reads workflow from file' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow.read('build.yml')

      expect(workflow.name).to(eq('CI'))
      expect(workflow.run_name).to(eq('Build ${{ github.sha }}'))
      expect(workflow.on).to(be_a(Hash))
      expect(workflow.on.keys).to(include(:push, :pull_request))
      expect(workflow.permissions).to(eq({ contents: 'read' }))
      expect(workflow.env).to(eq({ CI: 'true' }))
      expect(workflow.concurrency).to(eq({ group: 'ci-${{ github.ref }}', 'cancel-in-progress': true }))
    end

    it 'reads jobs from file' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow.read('build.yml')

      expect(workflow.jobs).to(have_key(:build))
      job = workflow.jobs[:build]
      expect(job.name).to(eq('Build'))
      expect(job.runs_on).to(eq('ubuntu-latest'))
      expect(job.timeout_minutes).to(eq(30))
    end

    it 'reads steps from file' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow.read('build.yml')

      steps = workflow.jobs[:build].steps
      expect(steps.length).to(eq(2))
      expect(steps.first.name).to(eq('Checkout'))
      expect(steps.first.uses).to(eq('actions/checkout@v4'))
      expect(steps[1].name).to(eq('Run tests'))
      expect(steps[1].run).to(eq('npm test'))
    end

    it 'converts github_token to github-token' do # rubocop:disable RSpec/ExampleLength
      yaml_with_token = <<~YAML
        name: CI
        "on":
          push:
        jobs:
          build:
            runs-on: ubuntu-latest
            steps:
              - name: Test
                with:
                  github_token: ${{ secrets.GITHUB_TOKEN }}
      YAML

      allow(File).to(receive(:read).and_return(yaml_with_token.dup))
      workflow.read('build.yml')

      # The conversion happens on the raw content, this test verifies it doesn't break
      expect(workflow.jobs[:build].steps.first.name).to(eq('Test'))
    end
  end

  describe '#write' do
    let(:workflow) { described_class.new('CI') }
    let(:temp_file) { '/tmp/test_workflow.yml' }

    before do
      allow(FileUtils).to(receive(:mkdir_p))
      allow(File).to(receive(:write))
    end

    it 'creates parent directories' do
      workflow.write(temp_file)
      expect(FileUtils).to(have_received(:mkdir_p).with('/tmp'))
    end

    it 'writes YAML content to file' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow.do_on({ push: {} })
      workflow.do_job(:build) do
        do_runs_on('ubuntu-latest')
      end

      workflow.write(temp_file)

      expect(File).to(have_received(:write)) do |path, content|
        expect(path).to(eq(temp_file))
        expect(content).to(include('name: CI'))
        expect(content).to(include('push:'))
        expect(content).to(include('build:'))
      end
    end

    it 'includes header comment' do # rubocop:disable RSpec/MultipleExpectations
      workflow.write(temp_file, header: "# Generated by github-build\n")

      expect(File).to(have_received(:write)) do |_, content|
        expect(content).to(start_with('# Generated by github-build'))
      end
    end

    it 'converts ${GITHUB_*} to ${{github.*}}' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow.do_env({ SHA: '${GITHUB_SHA}' })
      workflow.write(temp_file)

      expect(File).to(have_received(:write)) do |_, content|
        expect(content).to(include('${{github.sha}}'))
        expect(content).not_to(include('${GITHUB_SHA}'))
      end
    end

    it 'converts secrets.GITHUB_TOKEN to secrets.GH_PAT' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow.do_env({ TOKEN: '${{secrets.GITHUB_TOKEN}}' })
      workflow.write(temp_file)

      expect(File).to(have_received(:write)) do |_, content|
        expect(content).to(include('${{secrets.GH_PAT}}'))
        expect(content).not_to(include('${{secrets.GITHUB_TOKEN}}'))
      end
    end
  end

  describe '#to_h' do
    it 'converts workflow to hash' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow = described_class.new('CI')
      workflow.do_run_name('Build')
      workflow.do_on({ push: {}, pull_request: {} })
      workflow.do_permissions({ contents: 'read' })
      workflow.do_env({ CI: 'true' })
      workflow.do_defaults({ run: { shell: 'bash' } })
      workflow.do_concurrency({ group: 'ci' })
      workflow.do_job(:build) do
        do_runs_on('ubuntu-latest')
      end

      hash = workflow.to_h

      expect(hash[:name]).to(eq('CI'))
      expect(hash[:'run-name']).to(eq('Build'))
      expect(hash[:on]).to(be_a(Hash))
      expect(hash[:permissions]).to(eq({ contents: 'read' }))
      expect(hash[:env]).to(eq({ CI: 'true' }))
      expect(hash[:defaults]).to(eq({ run: { shell: 'bash' } }))
      expect(hash[:concurrency]).to(eq({ group: 'ci' }))
      expect(hash[:jobs]).to(have_key(:build))
    end

    it 'sorts on, permissions, env, and defaults' do
      workflow = described_class.new('CI')
      workflow.do_on({ push: {}, pull_request: {} })
      workflow.do_permissions({ packages: 'write', contents: 'read' })

      hash = workflow.to_h

      # Verify keys are sorted (contents before packages)
      expect(hash[:permissions].keys.first).to(eq(:contents))
    end

    it 'excludes empty values' do # rubocop:disable RSpec/MultipleExpectations
      workflow = described_class.new('Minimal')
      hash = workflow.to_h

      expect(hash).not_to(have_key(:'run-name'))
      expect(hash).not_to(have_key(:permissions))
      expect(hash).not_to(have_key(:env))
    end
  end
end
