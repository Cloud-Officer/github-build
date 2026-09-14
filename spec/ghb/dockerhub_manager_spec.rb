# frozen_string_literal: true

RSpec.describe(GHB::DockerhubManager) do
  describe '#save' do
    it 'returns early when .dockerhub file missing' do
      workflow = GHB::Workflow.new('DockerHub')
      manager = described_class.new(dockerhub_workflow: workflow)

      allow(File).to(receive(:exist?).with('.dockerhub').and_return(false))

      manager.save

      expect(workflow.jobs).to(be_empty)
    end

    it 'configures and writes dockerhub workflow when .dockerhub exists' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow = GHB::Workflow.new('DockerHub')
      manager = described_class.new(dockerhub_workflow: workflow)

      allow(File).to(receive(:exist?).with('.dockerhub').and_return(true))
      allow(FileUtils).to(receive(:mkdir_p))
      allow(File).to(receive(:write))

      manager.save

      expect(workflow.on).to(eq({ push: { tags: %w[**] } }))
      # Workflow-level least-privilege default so any future job must opt into
      # write scopes rather than inheriting the repo's default GITHUB_TOKEN scope.
      expect(workflow.permissions).to(eq(contents: 'read'))
      expect(workflow.jobs).to(have_key(:push_to_registry))
      expect(workflow.jobs[:push_to_registry].name).to(eq('Push Docker Image to Docker Hub'))
      # Regression test for CI-01 (soup#docs/code-review.md): packages:write is for
      # GHCR; cloud-officer/ci-actions/docker@v3 pushes to Docker Hub via
      # DOCKER_USERNAME/DOCKER_PASSWORD and never touches GHCR, so the scope must
      # NOT be requested. attestations:write and id-token:write are required by
      # actions/attest-build-provenance, so they stay.
      expect(workflow.jobs[:push_to_registry].permissions).to(eq(contents: 'read', attestations: 'write', 'id-token': 'write'))
      expect(workflow.jobs[:push_to_registry].permissions).not_to(include(packages: 'write'))
      expect(workflow.jobs[:push_to_registry].steps.map(&:name)).to(eq(['Verify Tag Is On Default Branch', 'Publish Docker image']))
    end

    it 'refuses to publish a tag whose commit is not on the default branch' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      workflow = GHB::Workflow.new('DockerHub')
      manager = described_class.new(dockerhub_workflow: workflow)

      allow(File).to(receive(:exist?).with('.dockerhub').and_return(true))
      allow(FileUtils).to(receive(:mkdir_p))
      allow(File).to(receive(:write))

      manager.save

      verify = workflow.jobs[:push_to_registry].steps.first
      expect(verify.uses).to(be_nil)
      expect(verify.env).to(eq(GH_TOKEN: '${{github.token}}', DEFAULT_BRANCH: '${{github.event.repository.default_branch}}'))
      expect(verify.run).to(include('compare/${DEFAULT_BRANCH}...${GITHUB_SHA}'))
      expect(verify.run).to(include('identical|behind) ;;'))
      expect(verify.run).to(include('exit 1'))
    end
  end
end
