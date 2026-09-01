# frozen_string_literal: true

# Golden-file test for the update path; workflow_generation_spec.rb covers
# greenfield generation.
#
# Regenerate the golden file after an intentional change with:
#   UPDATE_SNAPSHOTS=1 bundle exec rspec spec/ghb/integration/workflow_update_spec.rb
RSpec.describe('workflow update (golden file)') do # rubocop:disable RSpec/DescribeClass
  let(:fixture_dir)   { "#{__dir__}/../../fixtures/workflow_generation" }
  let(:existing_path) { "#{fixture_dir}/build_existing.yml"             }
  let(:golden_path)   { "#{fixture_dir}/build_updated.yml"              }
  let(:ruby_version) do
    config = Psych.safe_load_file("#{__dir__}/../../../config/languages.yaml")
    config.dig('ruby', 'setup_options').find { |option| option['name'] == 'ruby-version' }['value']
  end
  let(:argv) do
    %w[--organization test-org --skip_repository_settings --skip_gitignore --skip_slack]
  end

  around do |example|
    Dir.mktmpdir('ghb-golden-update') do |dir|
      Dir.chdir(dir) { example.run } # rubocop:disable ThreadSafety/DirChdir
    end
  end

  before do
    File.write('app.rb', "puts 'hello'\n")
    File.write('Gemfile', "source 'https://rubygems.org'\n")
    File.write('.ruby-version', "#{ruby_version}\n")
    allow($stdout).to(receive(:puts))
  end

  def generate_over(existing_contents)
    FileUtils.mkdir_p('.github/workflows')
    File.write('.github/workflows/build.yml', existing_contents)
    exit_code = GHB::Application.new(argv).execute
    [exit_code, File.read('.github/workflows/build.yml')]
  end

  def regenerated_workflow
    _exit_code, generated = generate_over(File.read(existing_path))
    Psych.safe_load(generated)
  end

  it 'regenerates over an existing build file matching the checked-in golden file' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
    exit_code, generated = generate_over(File.read(existing_path))
    expect(exit_code).to(eq(GHB::Status::SUCCESS_EXIT_CODE))

    if ENV['UPDATE_SNAPSHOTS']
      FileUtils.mkdir_p(File.dirname(golden_path))
      File.write(golden_path, generated)
      skip("Golden file updated: #{golden_path}") # rubocop:disable RSpec/Pending
    end

    raise("Missing golden file. Run with UPDATE_SNAPSHOTS=1 to create #{golden_path}") unless File.exist?(golden_path)

    expect(generated).to(eq(File.read(golden_path)))
  end

  it 'preserves the hand-maintained top-level sections' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
    workflow = regenerated_workflow

    expect(workflow['name']).to(eq('Custom Build Name'))
    expect(workflow['run-name']).to(eq('Build ${{github.actor}} / ${{github.ref_name}}'))
    expect(workflow.dig('permissions', 'contents')).to(eq('write'))
    expect(workflow.dig('permissions', 'id-token')).to(eq('write'))
    expect(workflow.dig('concurrency', 'group')).to(eq('custom-group-${{github.head_ref}}'))
    expect(workflow.dig('concurrency', 'cancel-in-progress')).to(be(false))
    expect(workflow.dig('env', 'CUSTOM_TEAM_FLAG')).to(eq('enabled'))
    expect(workflow.dig('defaults', 'run', 'shell')).to(eq('bash'))
  end

  it 'preserves hand-edited job and step properties on a regenerated job' do # rubocop:disable RSpec/MultipleExpectations
    licenses = regenerated_workflow.dig('jobs', 'licenses')

    expect(licenses['runs-on']).to(eq('ubuntu-24.04'))
    expect(licenses['timeout-minutes']).to(eq(45))
    expect(licenses.dig('steps', 0, 'with', 'ssh-key')).to(eq('${{secrets.CUSTOM_SSH_KEY}}'))
    expect(licenses.dig('steps', 0, 'with', 'parameters')).to(eq('--no_prompt --custom-flag'))
  end

  it 'upgrades the superseded default permissions block instead of preserving it' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
    superseded = File.read(existing_path).sub(
      "permissions:\n  contents: write\n  pull-requests: write\n  id-token: write\n",
      "permissions:\n  contents: read\n  pull-requests: read\n"
    )
    # without this the sub silently no-ops and the example proves nothing
    expect(superseded).to(include("  pull-requests: read\n"))

    _exit_code, generated = generate_over(superseded)
    permissions = Psych.safe_load(generated)['permissions']

    expect(permissions['contents']).to(eq('read'))
    expect(permissions['pull-requests']).to(eq('write'))
    expect(permissions).not_to(have_key('id-token'))
  end

  it 'upgrades the ci-actions pin on the preserved step rather than keeping the old one' do # rubocop:disable RSpec/MultipleExpectations
    licenses_step = regenerated_workflow.dig('jobs', 'licenses', 'steps', 0)

    expect(licenses_step['uses']).to(end_with('/soup@v3'))
    expect(licenses_step.dig('with', 'ssh-key')).to(eq('${{secrets.CUSTOM_SSH_KEY}}'))
  end

  it 'still regenerates the on: triggers rather than preserving the narrowed ones' do # rubocop:disable RSpec/MultipleExpectations
    triggers = regenerated_workflow['on']

    expect(triggers.dig('pull_request', 'types')).to(eq(%w[opened edited reopened synchronize]))
    expect(triggers.dig('push', 'branches')).to(eq(['master', '[0-9]*', 'dependabot/**']))
  end
end
