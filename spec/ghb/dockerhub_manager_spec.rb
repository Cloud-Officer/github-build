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
      expect(workflow.jobs[:push_to_registry].permissions).to(include(packages: 'write'))
      expect(workflow.jobs[:push_to_registry].steps.length).to(eq(1))
      expect(workflow.jobs[:push_to_registry].steps.first.name).to(eq('Publish Docker image'))
    end
  end
end
