# frozen_string_literal: true

RSpec.describe(GHB::VercelJobBuilder) do
  let(:options)      { instance_double(GHB::Options) }
  let(:old_workflow) { GHB::Workflow.new('Old')      }
  let(:new_workflow) { GHB::Workflow.new('Test')     }

  # The build/test/lint jobs a real workflow has by the time deploy jobs are
  # built; deploy needs/conditions are derived from these.
  def populate_base_jobs
    %i[variables actionlint markdownlint semgrep trivy yamllint licenses js_unit_tests].each do |id|
      new_workflow.do_job(id) { do_name(id.to_s) }
    end
  end

  def run_build(old: old_workflow)
    described_class.new(
      context: GHB::BuildContext.new(options: options, old_workflow: old, new_workflow: new_workflow)
    ).build
  end

  before do
    allow($stdout).to(receive(:puts))
    # Nothing on disk unless a test opts in.
    allow(File).to(receive(:exist?).and_return(false))
  end

  describe '#build' do
    context 'when the repo is not a Vercel project' do
      it 'returns early without adding jobs' do
        populate_base_jobs

        run_build

        expect(new_workflow.jobs.keys).to(eq(%i[variables actionlint markdownlint semgrep trivy yamllint licenses js_unit_tests]))
      end
    end

    context 'when appspec.yml exists' do
      it 'leaves the *_deploy jobs to CodeDeploy and adds nothing' do
        allow(File).to(receive(:exist?).with('appspec.yml').and_return(true))
        allow(File).to(receive(:exist?).with('vercel.json').and_return(true))
        populate_base_jobs

        run_build

        expect(new_workflow.jobs).not_to(include(:beta_deploy, :rc_deploy, :prod_deploy))
      end
    end

    context 'when a vercel.json marker is present' do
      before do
        allow(File).to(receive(:exist?).with('vercel.json').and_return(true))
        populate_base_jobs
      end

      it 'adds beta_deploy, rc_deploy and prod_deploy jobs' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        expect(new_workflow.jobs).to(have_key(:beta_deploy))
        expect(new_workflow.jobs).to(have_key(:rc_deploy))
        expect(new_workflow.jobs).to(have_key(:prod_deploy))
      end

      it 'names rc "RC Deploy" (matching the Vercel template, not CodeDeploy "Rc Deploy")' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        expect(new_workflow.jobs[:beta_deploy].name).to(eq('Beta Deploy'))
        expect(new_workflow.jobs[:rc_deploy].name).to(eq('RC Deploy'))
        expect(new_workflow.jobs[:prod_deploy].name).to(eq('Prod Deploy'))
      end

      it 'makes deploy jobs depend on the build/test/lint jobs, not on each other' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        expect(new_workflow.jobs[:rc_deploy].needs).to(eq(%w[variables actionlint markdownlint semgrep trivy yamllint licenses js_unit_tests]))
        expect(new_workflow.jobs[:rc_deploy].needs).not_to(include('beta_deploy', 'prod_deploy'))
      end

      it 'gates each job on its own DEPLOY_ON_* flag and every prior job result' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        run_build

        prod_if = new_workflow.jobs[:prod_deploy].if
        expect(prod_if).to(include("needs.variables.outputs.DEPLOY_ON_PROD == '1'"))
        expect(prod_if).to(include("needs.js_unit_tests.result != 'failure'"))
        expect(prod_if).not_to(include('DEPLOY_ON_BETA'))
        expect(prod_if).not_to(include('beta_deploy'))
      end

      it 'sets a 60-minute timeout and the Vercel org/project env' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        prod = new_workflow.jobs[:prod_deploy]
        expect(prod.timeout_minutes).to(eq(60))
        expect(prod.env[:VERCEL_ORG_ID]).to(eq('${{secrets.VERCEL_ORG_ID}}'))
        expect(prod.env[:VERCEL_PROJECT_ID]).to(eq('${{secrets.VERCEL_PROJECT_ID}}'))
      end

      it 'generates the four Vercel CLI steps' do
        run_build

        expect(new_workflow.jobs[:prod_deploy].steps.map(&:name))
          .to(eq(['Setup', 'Install Vercel CLI', 'Pull Vercel Environment Information', 'Deploy Project to Vercel']))
      end

      it 'deploys production with --prod and no output id' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        deploy = new_workflow.jobs[:prod_deploy].steps.last
        expect(deploy.run).to(eq('vercel deploy --prod --token=${{ secrets.VERCEL_TOKEN }}'))
        expect(deploy.id).to(be_nil)
        expect(new_workflow.jobs[:prod_deploy].steps[2].run).to(include('--environment=production'))
      end

      it 'deploys preview environments capturing the URL into the deploy step output' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        deploy = new_workflow.jobs[:rc_deploy].steps.last
        expect(deploy.id).to(eq('deploy'))
        expect(deploy.run).to(eq('echo "url=$(vercel deploy --token=${{ secrets.VERCEL_TOKEN }})" >> "${GITHUB_OUTPUT}"'))
        expect(new_workflow.jobs[:rc_deploy].steps[2].run).to(include('--environment=preview'))
      end

      it 'drops a carried-over node-version from Setup when a version file pins it' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        allow(File).to(receive(:exist?).with('.nvmrc').and_return(true))
        old_workflow.do_job(:prod_deploy) do
          do_step('Setup') do
            do_uses('cloud-officer/ci-actions/setup@v2')
            do_with({ 'ssh-key': '${{secrets.SSH_KEY}}', 'node-version': '${{env.NODE-VERSION}}' })
          end
        end

        run_build

        setup = new_workflow.jobs[:prod_deploy].steps.first
        expect(setup.with).not_to(have_key(:'node-version'))
        expect(setup.with[:'github-token']).to(eq('${{secrets.GH_PAT}}'))
      end
    end

    context 'when package.json declares a Vercel/Next dependency' do
      before { populate_base_jobs }

      it 'detects "next"' do
        allow(File).to(receive(:exist?).with('package.json').and_return(true))
        allow(File).to(receive(:read).with('package.json').and_return('{ "dependencies": { "next": "^16.2.3" } }'))

        run_build

        expect(new_workflow.jobs).to(have_key(:prod_deploy))
      end

      it 'detects "vercel"' do
        allow(File).to(receive(:exist?).with('package.json').and_return(true))
        allow(File).to(receive(:read).with('package.json').and_return('{ "devDependencies": { "vercel": "^39" } }'))

        run_build

        expect(new_workflow.jobs).to(have_key(:prod_deploy))
      end

      it 'ignores look-alike packages such as "next-auth"' do
        allow(File).to(receive(:exist?).with('package.json').and_return(true))
        allow(File).to(receive(:read).with('package.json').and_return('{ "dependencies": { "next-auth": "^5" } }'))

        run_build

        expect(new_workflow.jobs).not_to(have_key(:prod_deploy))
      end
    end

    context 'when an existing deploy job carries custom alias steps' do
      before do
        allow(File).to(receive(:exist?).with('vercel.json').and_return(true))
        populate_base_jobs

        old_workflow.do_job(:rc_deploy) do
          do_name('RC Deploy')
          do_step('Setup') { do_uses('cloud-officer/ci-actions/setup@v2') }
          do_step('Pull Vercel Environment Information') do
            do_run('vercel pull --yes --environment=preview --token=${{ secrets.VERCEL_TOKEN }} --custom')
          end
          do_step('Deploy Project to Vercel') do
            do_id('deploy')
            do_run('echo "url=$(vercel deploy --token=${{ secrets.VERCEL_TOKEN }})" >> "${GITHUB_OUTPUT}"')
          end
          do_step('Alias to rc.applaydu.app') do
            do_run('vercel alias ${{ steps.deploy.outputs.url }} rc.applaydu.app --scope "ugroup-media" --token=${{ secrets.VERCEL_TOKEN }}')
          end
        end
      end

      it 'preserves the custom alias step, appended after the generated steps' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        names = new_workflow.jobs[:rc_deploy].steps.map(&:name)
        expect(names).to(eq(['Setup', 'Install Vercel CLI', 'Pull Vercel Environment Information', 'Deploy Project to Vercel', 'Alias to rc.applaydu.app']))
        expect(new_workflow.jobs[:rc_deploy].steps.last.run).to(include('rc.applaydu.app'))
      end

      it 'keeps a customized run command on a regenerated step (copy_properties)' do
        run_build

        pull = new_workflow.jobs[:rc_deploy].steps[2]
        expect(pull.run).to(eq('vercel pull --yes --environment=preview --token=${{ secrets.VERCEL_TOKEN }} --custom'))
      end
    end
  end
end
