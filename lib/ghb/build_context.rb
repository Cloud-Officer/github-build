# frozen_string_literal: true

module GHB
  # Immutable bundle of the values shared across job builders, replacing the
  # recurring (options:, old_workflow:, new_workflow:, file_cache:, submodules:)
  # keyword-argument clump. Builders that need extra inputs take those as
  # additional keyword arguments alongside `context:`.
  #
  # The referenced workflow / cache / submodules objects are still mutated in
  # place by the pipeline; only the container itself is frozen.
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
