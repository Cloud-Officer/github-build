# frozen_string_literal: true

require 'open3'

RSpec.describe('default branch detection without origin/HEAD') do # rubocop:disable RSpec/DescribeClass
  let(:argv) { %w[--organization test-org --skip_repository_settings --skip_gitignore --skip_slack] }

  def git(*args, chdir:)
    _, stderr, status = Open3.capture3('git', '-c', 'user.name=test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false', *args, chdir: chdir)
    raise("git #{args.join(' ')} failed: #{stderr}") unless status.success?
  end

  around do |example|
    Dir.mktmpdir('ghb-default-branch') do |root|
      source = File.join(root, 'source')
      project = File.join(root, 'project')
      FileUtils.mkdir_p([source, project])
      git('init', '-q', '-b', 'main', chdir: source)
      git('commit', '-q', '--allow-empty', '-m', 'init', chdir: source)
      git('clone', '-q', '--bare', source, File.join(root, 'origin.git'), chdir: root)
      git('init', '-q', '-b', 'main', chdir: project)
      git('remote', 'add', 'origin', File.join(root, 'origin.git'), chdir: project)
      Dir.chdir(project) { example.run } # rubocop:disable ThreadSafety/DirChdir
    end
  end

  before do
    File.write('app.rb', "puts 'hello'\n")
    File.write('Gemfile', "source 'https://rubygems.org'\n")
    allow($stdout).to(receive(:puts))
  end

  it 'writes the remote default branch into the build.yml push trigger' do
    GHB::Application.new(argv).execute

    build = Psych.safe_load_file('.github/workflows/build.yml')

    expect(build.dig('on', 'push', 'branches')).to(eq(['main', '[0-9]*', 'dependabot/**']))
  end
end
