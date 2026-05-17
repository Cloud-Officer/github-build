# frozen_string_literal: true

# Golden-file (snapshot) test for the end-to-end workflow generation.
#
# Feeds a minimal Ruby project tree to Application#execute inside an isolated
# tmpdir and diffs the generated .github/workflows/build.yml against a
# checked-in expected file. This catches structural drift (wrong needs: graph,
# missing permissions:, mis-ordered jobs/steps) that substring assertions miss.
#
# Regenerate the golden file after an intentional change with:
#   UPDATE_SNAPSHOTS=1 bundle exec rspec spec/ghb/integration/workflow_generation_spec.rb
RSpec.describe('workflow generation (golden file)') do # rubocop:disable RSpec/DescribeClass
  let(:golden_path) { "#{__dir__}/../../fixtures/workflow_generation/build.yml" }
  let(:argv) do
    %w[--organization test-org --skip_repository_settings --skip_gitignore --skip_slack]
  end

  around do |example|
    Dir.mktmpdir('ghb-golden') do |dir|
      Dir.chdir(dir) { example.run } # rubocop:disable ThreadSafety/DirChdir
    end
  end

  before do
    # Minimal Ruby project so the Ruby language + linters are detected.
    # .ruby-version matches config/languages.yaml ruby-version so the
    # version-file reconciliation neither warns nor rewrites mid-test.
    File.write('app.rb', "puts 'hello'\n")
    File.write('Gemfile', "source 'https://rubygems.org'\n")
    File.write('.ruby-version', "4.0.4\n")
    allow($stdout).to(receive(:puts))
  end

  it 'generates build.yml matching the checked-in golden file' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
    exit_code = GHB::Application.new(argv).execute
    expect(exit_code).to(eq(GHB::Status::SUCCESS_EXIT_CODE))

    generated = File.read('.github/workflows/build.yml')

    if ENV['UPDATE_SNAPSHOTS']
      FileUtils.mkdir_p(File.dirname(golden_path))
      File.write(golden_path, generated)
      skip("Golden file updated: #{golden_path}") # rubocop:disable RSpec/Pending
    end

    raise("Missing golden file. Run with UPDATE_SNAPSHOTS=1 to create #{golden_path}") unless File.exist?(golden_path)

    expect(generated).to(eq(File.read(golden_path)))
  end
end
