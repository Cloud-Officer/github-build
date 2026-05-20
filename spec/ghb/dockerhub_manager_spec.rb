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
      expect(workflow.jobs).to(have_key(:push_to_registry))
      expect(workflow.jobs[:push_to_registry].name).to(eq('Push Docker Image to Docker Hub'))
      # Regression test for CI-01 (soup#docs/code-review.md): packages:write is for
      # GHCR; cloud-officer/ci-actions/docker@v2 pushes to Docker Hub via
      # DOCKER_USERNAME/DOCKER_PASSWORD and never touches GHCR, so the scope must
      # NOT be requested. attestations:write and id-token:write are required by
      # actions/attest-build-provenance, so they stay.
      expect(workflow.jobs[:push_to_registry].permissions).to(eq(contents: 'read', attestations: 'write', 'id-token': 'write'))
      expect(workflow.jobs[:push_to_registry].permissions).not_to(include(packages: 'write'))
      expect(workflow.jobs[:push_to_registry].steps.length).to(eq(1))
      expect(workflow.jobs[:push_to_registry].steps.first.name).to(eq('Publish Docker image'))
    end
  end
end
