# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

# CI-005. `shell_script` is the only ecosystem whose package_manager command
# installs a tool system-wide (the bats runner) rather than the dependencies of
# the directory it was detected in -- `.bats` is a zero-byte marker, not a
# manifest. Without `package_manager_once` the generic sub-project detection
# emits one install per detected directory, repeating `apt-get update` on the
# same runner and multiplying the chance of a transient apt failure.
RSpec.describe('shell_script package_manager_once') do # rubocop:disable RSpec/DescribeClass
  let(:argv) do
    %w[--organization test-org --skip_repository_settings --skip_gitignore --skip_slack]
  end

  around do |example|
    Dir.mktmpdir('ghb-bats') do |dir|
      Dir.chdir(dir) { example.run } # rubocop:disable ThreadSafety/DirChdir
    end
  end

  before do
    %w[bump-actions codedeploy variables].each do |dir|
      FileUtils.mkdir_p("#{dir}/tests")
      File.write("#{dir}/.bats", '')
      File.write("#{dir}/thing.sh", "#!/usr/bin/env bash\necho hi\n")
      File.write("#{dir}/tests/x.bats", "@test \"t\" { true; }\n")
    end

    allow($stdout).to(receive(:puts))
  end

  it 'installs bats once but runs the suite per sub-project' do # rubocop:disable RSpec/MultipleExpectations
    expect(GHB::Application.new(argv).execute).to(eq(GHB::Status::SUCCESS_EXIT_CODE))

    workflow = File.read('.github/workflows/build.yml')

    # One un-scoped install, no `(subdir)` suffix and no `cd` into a sub-project:
    # the tool is installed for the whole job.
    expect(workflow.scan(/- name: Bats Install[^\n]*/)).to(eq(['- name: Bats Install']))

    # The suites still run once per detected directory.
    expect(workflow.scan(/- name: Bats \(([^)]+)\)/).flatten).to(eq(%w[bump-actions codedeploy variables]))
  end
end
