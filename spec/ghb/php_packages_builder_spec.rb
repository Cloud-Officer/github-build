# frozen_string_literal: true

RSpec.describe(GHB::PhpPackagesBuilder) do
  let(:new_workflow) do
    workflow = GHB::Workflow.new('Build')
    workflow.do_job(:php_unit_tests) do
      do_runs_on('ubuntu-latest')
      do_step('Setup') do
        do_uses('cloud-officer/ci-actions/setup@v3')
        do_with({ 'php-tools': '${{env.PHP-TOOLS}}', 'ssh-key': '${{secrets.SSH_KEY}}' })
      end
    end
    workflow.do_job(:phpstan) do
      do_runs_on('ubuntu-latest-16-cores')
      do_step('PHPStan') { do_uses('cloud-officer/ci-actions/linters/phpstan@v3') }
    end
    workflow.do_job(:phpcs) do
      do_step('PHPCS') do
        do_uses('cloud-officer/ci-actions/linters/phpcs@v3')
        do_with({ 'aws-region': 'eu-west-1' })
      end
    end
    workflow.do_job(:js_unit_tests) do
      do_runs_on('ubuntu-latest')
      do_step('Setup') do
        do_uses('cloud-officer/ci-actions/setup@v3')
        do_with({ 'node-version': '24' })
      end
    end
    workflow
  end
  let(:builder) { described_class.new(context: GHB::BuildContext.new(options: nil, new_workflow: new_workflow)) }

  around do |example|
    Dir.mktmpdir('ghb-php-packages') do |dir|
      Dir.chdir(dir) { example.run } # rubocop:disable ThreadSafety/DirChdir
    end
  end

  before do
    allow($stdout).to(receive(:puts))
    allow(builder).to(receive(:warn))
  end

  describe '.parse' do
    it 'reads one package per word and drops comments and blank lines' do
      content = "# PHP extensions\nphp8.5-amqp\n\nphp8.5-grpc # from our repo\nphp8.5-intl php8.5-zip\n"

      expect(described_class.parse(content)).to(eq(%w[php8.5-amqp php8.5-grpc php8.5-intl php8.5-zip]))
    end
  end

  describe '#build' do
    it 'leaves the workflow unchanged without php-packages.txt' do
      before_build = new_workflow.to_h.deep_dup

      builder.build

      expect(new_workflow.to_h).to(eq(before_build))
    end

    it 'raises when php-packages.txt lists no package' do
      File.write('php-packages.txt', "# nothing yet\n")

      expect { builder.build }
        .to(raise_error(GHB::ConfigError, /lists no package/))
    end

    context 'with php-packages.txt' do
      before do
        File.write('php-packages.txt', "# extensions\nphp8.5-amqp\nphp8.5-grpc\n")
        builder.build
      end

      it 'stores the package list in the workflow env' do
        expect(new_workflow.env[:'PHP-PACKAGES']).to(eq('php8.5-amqp php8.5-grpc'))
      end

      it 'passes the packages to the PHP setup and linter steps' do # rubocop:disable RSpec/MultipleExpectations
        %i[php_unit_tests phpstan phpcs].each do |job|
          expect(new_workflow.jobs[job].steps.first.with[:'php-packages']).to(eq('${{env.PHP-PACKAGES}}'))
        end
        expect(new_workflow.jobs[:js_unit_tests].steps.first.with).not_to(have_key(:'php-packages'))
      end

      it 'adds the AWS credentials unless the step already sets some' do # rubocop:disable RSpec/MultipleExpectations
        expect(new_workflow.jobs[:php_unit_tests].steps.first.with[:'aws-role-to-assume']).to(eq('${{vars.AWS_ROLE_TO_ASSUME}}'))
        expect(new_workflow.jobs[:phpstan].steps.first.with[:'aws-region']).to(eq('${{secrets.AWS_DEFAULT_REGION}}'))
        expect(new_workflow.jobs[:phpcs].steps.first.with).to(eq({ 'aws-region': 'eu-west-1', 'php-packages': '${{env.PHP-PACKAGES}}' }))
      end

      it 'moves standard runners to ubuntu-26.04 and keeps larger runners' do # rubocop:disable RSpec/MultipleExpectations
        expect(new_workflow.jobs[:php_unit_tests].runs_on).to(eq('ubuntu-26.04'))
        expect(new_workflow.jobs[:phpcs].runs_on).to(eq('ubuntu-26.04'))
        expect(new_workflow.jobs[:phpstan].runs_on).to(eq('ubuntu-latest-16-cores'))
        expect(new_workflow.jobs[:js_unit_tests].runs_on).to(eq('ubuntu-latest'))
        expect(builder).to(have_received(:warn).with(/job 'phpstan' keeps runner "ubuntu-latest-16-cores"/))
      end

      it 'grants id-token: write once the AWS role is adopted' do # rubocop:disable RSpec/MultipleExpectations
        new_workflow.adopt_aws_role

        expect(new_workflow.jobs[:php_unit_tests].permissions).to(include('id-token': 'write'))
        expect(new_workflow.jobs[:js_unit_tests].permissions).to(be_empty)
      end
    end

    it 'keeps the arm flavour of a standard runner' do
      new_workflow.jobs[:php_unit_tests].runs_on = 'ubuntu-24.04-arm'
      File.write('php-packages.txt', "php8.5-intl\n")

      builder.build

      expect(new_workflow.jobs[:php_unit_tests].runs_on).to(eq('ubuntu-26.04-arm'))
    end
  end
end
