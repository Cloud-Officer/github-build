# frozen_string_literal: true

RSpec.describe(GHB::DockerBuildJobBuilder) do
  let(:options)      { instance_double(GHB::Options) }
  let(:old_workflow) { GHB::Workflow.new('Old')      }
  let(:new_workflow) { GHB::Workflow.new('Test')     }

  def run_build
    described_class.new(
      context: GHB::BuildContext.new(options: options, old_workflow: old_workflow, new_workflow: new_workflow)
    ).build
  end

  before do
    allow($stdout).to(receive(:puts))
    allow(File).to(receive(:exist?).and_return(false))
    new_workflow.do_job(:variables) { do_name('Prepare Variables') }
  end

  describe '#build' do
    context 'when .dockerhub is absent' do
      it 'adds no Docker build jobs' do
        run_build

        expect(new_workflow.jobs.keys).to(eq(%i[variables]))
      end

      it 'drops Docker build jobs left over from a previous build file' do
        old_workflow.do_job(:docker_build_amd64) { do_name('Docker Build (amd64)') }

        run_build

        expect(new_workflow.jobs).not_to(have_key(:docker_build_amd64))
      end
    end

    context 'when .dockerhub is present' do
      before do
        allow(File).to(receive(:exist?).with('.dockerhub').and_return(true))
      end

      it 'adds one job per architecture after the existing jobs' do
        run_build

        expect(new_workflow.jobs.keys).to(eq(%i[variables docker_build_amd64 docker_build_arm64]))
      end

      it 'names each job after its architecture' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        expect(new_workflow.jobs[:docker_build_amd64].name).to(eq('Docker Build (amd64)'))
        expect(new_workflow.jobs[:docker_build_arm64].name).to(eq('Docker Build (arm64)'))
      end

      it 'runs each architecture on a native runner' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        expect(new_workflow.jobs[:docker_build_amd64].runs_on).to(eq('ubuntu-latest'))
        expect(new_workflow.jobs[:docker_build_arm64].runs_on).to(eq('ubuntu-24.04-arm'))
      end

      it 'grants read-only contents permission' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        expect(new_workflow.jobs[:docker_build_amd64].permissions).to(eq(contents: 'read'))
        expect(new_workflow.jobs[:docker_build_arm64].permissions).to(eq(contents: 'read'))
      end

      it 'depends on variables and honours the skip-tests trigger' do # rubocop:disable RSpec/MultipleExpectations
        run_build

        job = new_workflow.jobs[:docker_build_arm64]
        expect(job.needs).to(eq(%w[variables]))
        expect(job.if).to(eq("${{needs.variables.outputs.SKIP_TESTS != '1'}}"))
      end

      it 'builds without pushing for the job architecture only' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        run_build

        amd64_steps = new_workflow.jobs[:docker_build_amd64].steps
        arm64_step = new_workflow.jobs[:docker_build_arm64].steps.first
        expect(amd64_steps.map(&:name)).to(eq(['Docker Build']))
        expect(amd64_steps.first.uses).to(eq('cloud-officer/ci-actions/docker@v3'))
        expect(amd64_steps.first.with).to(eq(push: 'false', platforms: 'linux/amd64'))
        expect(arm64_step.with).to(eq(push: 'false', platforms: 'linux/arm64'))
      end

      it 'passes no registry credentials' do
        run_build

        expect(new_workflow.jobs[:docker_build_amd64].steps.first.with.keys).not_to(include(:username, :password))
      end

      it 'enforces push and platforms over stale values while keeping other customisations' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        old_workflow.do_job(:docker_build_arm64) do
          do_timeout_minutes(45)
          do_step('Docker Build') do
            do_uses('cloud-officer/ci-actions/docker@v3')
            do_with({ push: 'true', platforms: 'linux/amd64,linux/arm64', 'build-args': 'FOO=bar' })
          end
        end

        run_build

        job = new_workflow.jobs[:docker_build_arm64]
        expect(job.timeout_minutes).to(eq(45))
        expect(job.steps.first.with).to(eq(push: 'false', platforms: 'linux/arm64', 'build-args': 'FOO=bar'))
      end

      it 'enforces name, permissions, needs and if over stale values' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
        old_workflow.do_job(:docker_build_amd64) do
          do_name('Old Docker Build')
          do_permissions({ contents: 'write', packages: 'write' })
          do_needs(%w[variables licenses])
          do_if('${{always()}}')
        end

        run_build

        job = new_workflow.jobs[:docker_build_amd64]
        expect(job.name).to(eq('Docker Build (amd64)'))
        expect(job.permissions).to(eq(contents: 'read'))
        expect(job.needs).to(eq(%w[variables]))
        expect(job.if).to(eq("${{needs.variables.outputs.SKIP_TESTS != '1'}}"))
      end

      it 'keeps a runner the user pinned on an existing job' do
        old_workflow.do_job(:docker_build_amd64) { do_runs_on('ubuntu-24.04') }

        run_build

        expect(new_workflow.jobs[:docker_build_amd64].runs_on).to(eq('ubuntu-24.04'))
      end
    end
  end
end
