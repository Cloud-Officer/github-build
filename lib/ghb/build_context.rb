# frozen_string_literal: true

module GHB
  # Only the container is frozen; the referenced workflow, cache and submodules are still mutated in place.
  class BuildContext
    attr_reader :options, :old_workflow, :new_workflow, :file_cache, :submodules

    def initialize(options:, new_workflow: nil, old_workflow: nil, file_cache: {}, submodules: [])
      @options = options
      @old_workflow = old_workflow
      @new_workflow = new_workflow
      @file_cache = file_cache
      @submodules = submodules
      freeze
    end
  end
end
