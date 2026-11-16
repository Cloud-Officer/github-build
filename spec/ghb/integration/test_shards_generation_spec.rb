# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

RSpec.describe('--test_shards workflow generation') do # rubocop:disable RSpec/DescribeClass
  let(:base_argv)  { %w[--organization test-org --skip_repository_settings --skip_gitignore --skip_slack] }
  let(:build_file) { '.github/workflows/build.yml'                                                        }

  around do |example|
    Dir.mktmpdir('ghb-test-shards') do |dir|
      Dir.chdir(dir) { example.run } # rubocop:disable ThreadSafety/DirChdir
    end
  end

  before do
    FileUtils.mkdir_p(%w[bin test/models test/system app/models])
    File.write('Gemfile', "source 'https://rubygems.org'\ngem 'rails'\n")
    File.write('bin/rails', "#!/usr/bin/env ruby\n")
    File.write('app/models/user.rb', "class User; end\n")
    File.write('test/models/user_test.rb', "class UserTest; end\n")
    File.write('test/system/login_test.rb', "class LoginTest; end\n")

    allow($stdout).to(receive(:puts))
    allow(Kernel).to(receive(:warn))
  end

  def generate(*argv)
    expect(GHB::Application.new(argv).execute).to(eq(GHB::Status::SUCCESS_EXIT_CODE))

    Psych.safe_load(File.read(build_file))['jobs']
  end

  it 'replaces the Ruby unit-test job with shard jobs and an aggregator' do # rubocop:disable RSpec/MultipleExpectations
    jobs = generate(*base_argv, '--test_shards', 'test=2,test:system=1')

    expect(jobs.keys).to(include('ruby_unit_tests_test_shards', 'ruby_unit_tests_test_system_shards', 'ruby_unit_tests'))
    expect(jobs['ruby_unit_tests']['strategy']).to(eq('fail-fast' => false, 'matrix' => { 'task' => %w[test test:system] })) # rubocop:disable Style/StringHashKeys
    expect(jobs['ruby_unit_tests_test_shards']['steps'].find { |step| step['name'] == 'RSpec' }['run']).to(end_with('bin/rails db:test:prepare test "${SHARD_FILES[@]}"'))
  end

  it 'regenerates the same workflow from the persisted header' do
    generate(*base_argv, '--test_shards', 'test=2,test:system=1')
    generate
    first = File.read(build_file)
    generate

    expect(File.read(build_file)).to(eq(first))
  end

  it 'restores a single unit-test job when the flag is removed' do # rubocop:disable RSpec/MultipleExpectations
    generate(*base_argv, '--test_shards', 'test=2,test:system=1')
    jobs = generate(*base_argv)

    expect(jobs.keys.grep(/shards/)).to(be_empty)
    expect(jobs['ruby_unit_tests']['steps'].find { |step| step['name'] == 'RSpec' }['run']).to(eq('bin/rails db:test:prepare ${{matrix.task}}'))
  end

  it 'rejects a key no job can use' do
    expect { GHB::Application.new(base_argv + %w[--test_shards jest=2]).execute }
      .to(raise_error(GHB::ConfigError, /--test_shards jest: no matching unit-test job/))
  end
end
