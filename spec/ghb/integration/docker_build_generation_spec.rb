# frozen_string_literal: true

RSpec.describe('Docker build job generation') do # rubocop:disable RSpec/DescribeClass
  let(:ruby_version) do
    config = Psych.safe_load_file("#{__dir__}/../../../config/languages.yaml")
    config.dig('ruby', 'setup_options').find { |option| option['name'] == 'ruby-version' }['value']
  end
  let(:argv) do
    %w[--organization test-org --skip_repository_settings --skip_gitignore --skip_slack]
  end
  let(:app) { GHB::Application.new(argv) }

  around do |example|
    Dir.mktmpdir('ghb-docker-build') do |dir|
      Dir.chdir(dir) { example.run } # rubocop:disable ThreadSafety/DirChdir
    end
  end

  before do
    File.write('app.rb', "puts 'hello'\n")
    File.write('Gemfile', "source 'https://rubygems.org'\n")
    File.write('.ruby-version', "#{ruby_version}\n")
    allow($stdout).to(receive(:puts))
  end

  context 'when .dockerhub is present' do
    before do
      File.write('.dockerhub', '')
      File.write('Dockerfile', "FROM ubuntu:26.04\n")
    end

    it 'requires both Docker build checks' do
      app.execute

      expect(app.instance_variable_get(:@required_status_checks)).to(include('Docker Build (amd64)', 'Docker Build (arm64)'))
    end

    it 'places the Docker build jobs after the unit tests in build.yml' do # rubocop:disable RSpec/MultipleExpectations
      app.execute

      job_ids = Psych.safe_load_file('.github/workflows/build.yml')['jobs'].keys
      expect(job_ids.last(3)).to(eq(%w[ruby_unit_tests docker_build_amd64 docker_build_arm64]))
      expect(Psych.safe_load_file('.github/workflows/build.yml', symbolize_names: true).dig(:jobs, :docker_build_arm64, :steps, 0, :with)).to(eq(push: 'false', platforms: 'linux/arm64'))
    end
  end

  context 'when .dockerhub is absent' do
    it 'requires no Docker build check' do
      app.execute

      expect(app.instance_variable_get(:@required_status_checks)).not_to(include(a_string_starting_with('Docker Build')))
    end
  end
end
