# frozen_string_literal: true

RSpec.describe('php-packages.txt workflow generation') do # rubocop:disable RSpec/DescribeClass
  let(:argv)     { %w[--organization test-org --skip_repository_settings --skip_gitignore --skip_slack --skip_license_check] }
  let(:php_jobs) { %i[php_unit_tests phpstan phpcs codedeploy]                                                               }
  let(:dir)      { Dir.mktmpdir('ghb-php-packages')                                                                          }

  def generate(path, php_packages: nil)
    Dir.chdir(path) do # rubocop:disable ThreadSafety/DirChdir
      File.write('index.php', "<?php echo 'hello';\n")
      File.write('composer.json', "{}\n")
      File.write('appspec.yml', "version: 0.0\n")
      File.write('php-packages.txt', php_packages) if php_packages
      GHB::Application.new(argv).execute
      Psych.safe_load_file('.github/workflows/build.yml', symbolize_names: true)
    end
  end

  before do
    allow($stdout).to(receive(:puts))
    allow($stderr).to(receive(:write))
  end

  after { FileUtils.rm_rf(dir) }

  it 'keeps setup-php without php-packages.txt' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
    workflow = generate(dir)

    expect(workflow[:env]).not_to(have_key(:'PHP-PACKAGES'))
    php_jobs.each do |job|
      expect(workflow.dig(:jobs, job, :'runs-on')).to(eq('ubuntu-latest'))
      expect(workflow.dig(:jobs, job, :steps).map { |step| step[:with] || {} }).to(all(satisfy { |with| !with.key?(:'php-packages') }))
    end
    expect(workflow.dig(:jobs, :phpstan, :permissions)).to(eq({ contents: 'read' }))
  end

  it 'moves the PHP jobs to apt packages on ubuntu-26.04 with php-packages.txt' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
    workflow = generate(dir, php_packages: "# extensions\nphp8.5-intl\nphp8.5-grpc\n")

    expect(workflow.dig(:env, :'PHP-PACKAGES')).to(eq('php8.5-intl php8.5-grpc'))
    php_jobs.each do |job|
      setup = workflow.dig(:jobs, job, :steps).find { |step| step[:uses].to_s.match?(%r{ci-actions/(setup|linters/php)}) }

      expect(workflow.dig(:jobs, job, :'runs-on')).to(eq('ubuntu-26.04'))
      expect(workflow.dig(:jobs, job, :permissions, :'id-token')).to(eq('write'))
      expect(setup[:with]).to(include('php-packages': '${{env.PHP-PACKAGES}}', 'aws-role-to-assume': '${{vars.AWS_ROLE_TO_ASSUME}}'))
    end
    expect(workflow.dig(:jobs, :variables, :'runs-on')).to(eq('ubuntu-latest'))
  end

  it 'is stable when regenerated' do
    generate(dir, php_packages: "php8.5-intl\n")
    second = generate(dir)

    expect(generate(dir)).to(eq(second))
  end
end
