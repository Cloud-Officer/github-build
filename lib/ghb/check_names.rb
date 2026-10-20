# frozen_string_literal: true

module GHB
  # Turns a workflow job into the check-run names GitHub reports for it.
  module CheckNames
    MATRIX_CONTROL_KEYS = %i[include exclude].freeze

    EXPRESSION = /\$\{\{.*?\}\}/m

    MATRIX_EXPRESSION = /\$\{\{\s*matrix\.([A-Za-z0-9_-]+)\s*\}\}/

    private_constant :MATRIX_CONTROL_KEYS
    private_constant :EXPRESSION
    private_constant :MATRIX_EXPRESSION

    module_function

    # @return [Array<String>, nil] the check names, or nil when they cannot be resolved statically
    def for_job(name, strategy)
      name = name.to_s
      matrix = strategy.is_a?(Hash) ? strategy[:matrix] || strategy['matrix'] : nil
      return (name.match?(EXPRESSION) ? nil : [name]) if matrix.nil?

      combinations = matrix_combinations(matrix)
      return if combinations.nil?

      names = combinations.map { |combination| name_for(name, combination) }
      names.any?(&:nil?) ? nil : names
    end

    # GitHub appends the matrix values only when the job name does not interpolate them itself.
    def name_for(name, combination)
      return "#{name} (#{combination.values.join(', ')})" unless name.match?(EXPRESSION)

      unresolved = false
      resolved =
        name.gsub(MATRIX_EXPRESSION) do
          key = Regexp.last_match(1).to_sym
          unresolved = true unless combination.key?(key)
          combination[key].to_s
        end

      unresolved || resolved.match?(EXPRESSION) ? nil : resolved
    end

    # Mirrors GitHub's matrix expansion order so generated check names match real check-run contexts.
    def matrix_combinations(matrix)
      return unless matrix.is_a?(Hash)

      matrix = symbolize_matrix_keys(matrix)
      return if matrix.nil?

      axes = matrix.except(*MATRIX_CONTROL_KEYS)
      includes = matrix_control_entries(matrix[:include])
      excludes = matrix_control_entries(matrix[:exclude])
      return if includes.nil? || excludes.nil?
      return if axes.empty? && includes.empty?
      return unless axes.all? { |_key, values| expandable_axis?(values) }

      combinations = reject_excluded(expand_axes(axes), excludes)
      apply_includes(combinations, includes, axes.keys)
    end

    def symbolize_matrix_keys(hash)
      return unless hash.keys.all? { |key| key.is_a?(Symbol) || key.is_a?(String) }

      hash.transform_keys(&:to_sym)
    end

    # @return [Array<Hash>, nil] normalized include/exclude rows, or nil when they are not statically usable
    def matrix_control_entries(entries)
      return [] if entries.nil?
      return unless entries.is_a?(Array)

      normalized = entries.map { |entry| matrix_control_entry(entry) }
      return if normalized.any?(&:nil?)

      normalized
    end

    def matrix_control_entry(entry)
      return unless entry.is_a?(Hash) && entry.any?

      normalized = symbolize_matrix_keys(entry)
      return if normalized.nil? || !normalized.each_value.all? { |value| scalar_matrix_value?(value) }

      normalized
    end

    def expandable_axis?(values)
      values.is_a?(Array) && values.any? && values.all? { |value| scalar_matrix_value?(value) }
    end

    def scalar_matrix_value?(value)
      !value.nil? && !value.is_a?(Hash) && !value.is_a?(Array)
    end

    # An include-only matrix has no base combination: every include row is its own job.
    def expand_axes(axes)
      return [] if axes.empty?

      axes.reduce([{}]) do |combinations, (key, values)|
        combinations.flat_map { |combination| values.map { |value| combination.merge(key => value) } }
      end
    end

    def reject_excluded(combinations, excludes)
      combinations.reject do |combination|
        excludes.any? { |exclusion| exclusion.all? { |key, value| combination.key?(key) && combination[key] == value } }
      end
    end

    def apply_includes(combinations, includes, axis_keys)
      added = []

      includes.each do |inclusion|
        matched = false
        combinations =
          combinations.map do |combination|
            next combination unless axis_keys.all? { |key| !inclusion.key?(key) || combination[key] == inclusion[key] }

            matched = true
            combination.merge(inclusion)
          end
        added << inclusion unless matched
      end

      combinations + added
    end
  end
end
