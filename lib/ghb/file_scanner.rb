# frozen_string_literal: true

require 'find'

module GHB
  # Shared utility methods for file scanning and content searching.
  # Provides pure Ruby file operations to avoid shell command injection (SEC-001, SEC-002).
  module FileScanner
    private

    def cached_file_read(path)
      @file_cache[path] ||= File.read(path)
    end

    # Pure Ruby file finder - avoids shell command injection (SEC-001, SEC-002)
    # @param path [String] starting directory path
    # @param pattern [Regexp] file pattern to match
    # @param excluded_paths [Array<String>] paths to exclude (partial matches)
    # @param max_depth [Integer, nil] maximum directory depth (nil for unlimited)
    # @return [Array<String>] list of matching file paths
    # Builds the list of excluded directory patterns from languages.yaml.
    # Combines install_dirs from all dependency entries with the top-level excluded_dirs.
    # @return [Array<String>] directory names to exclude (e.g., ['node_modules', 'vendor', '.git'])
    def excluded_dirs_from_config
      @excluded_dirs_from_config ||=
        begin
          config_path = "#{__dir__}/../../#{@options.languages_config_file}"
          config = Psych.safe_load(cached_file_read(config_path))&.deep_symbolize_keys || {}

          dirs = Set.new
          config.each_value do |language|
            next unless language.is_a?(Hash) && language[:dependencies]

            language[:dependencies].each do |dep|
              dep[:install_dirs]&.each { |dir| dirs.add(dir) }
            end
          end

          config[:excluded_dirs]&.each { |dir| dirs.add(dir) }

          dirs.to_a
        end
    end

    def find_files_matching(path, pattern, excluded_paths = [], max_depth: nil)
      matches = []
      base_depth = path.count(File::SEPARATOR)
      config_excluded = excluded_dirs_from_config

      Find.find(path) do |file_path|
        # Check max depth
        if max_depth
          current_depth = file_path.count(File::SEPARATOR) - base_depth
          Find.prune if current_depth > max_depth
        end

        # Skip excluded paths (submodules, excluded_folders, dirs from languages.yaml)
        should_skip = excluded_paths.any? { |excluded| file_path.include?(excluded) } ||
                      config_excluded.any? { |dir| file_path.include?("/#{dir}/") }

        if should_skip
          Find.prune
          next
        end

        # Match files against pattern
        matches << file_path if File.file?(file_path) && file_path.match?(pattern)
      end

      matches
    rescue Errno::ENOENT, Errno::EACCES
      # Path doesn't exist or permission denied - return empty
      []
    end

    # Pure Ruby file content search
    # @param file [String] file path to search
    # @param pattern [String] pattern to search for (literal string match)
    # @return [Boolean] true if pattern found in file
    def file_contains?(file, pattern)
      return false unless File.exist?(file) && File.file?(file)

      File.foreach(file) do |line|
        return true if line.include?(pattern)
      end

      false
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    # Atomic file copy with optional transformation
    # Copies source to a temp file, applies optional transformation, then renames atomically
    # @param source [String] source file path
    # @param target [String] target file path
    # @yield [content] optional block to transform content before writing
    # @yieldparam content [String] the file content
    # @yieldreturn [String] the transformed content
    def atomic_copy_config(source, target)
      content = File.read(source)
      content = yield(content) if block_given?

      temp_file = "#{target}.tmp.#{Process.pid}"

      begin
        File.write(temp_file, content)
        File.delete(target) if File.symlink?(target)
        FileUtils.mv(temp_file, target)
      rescue StandardError
        FileUtils.rm_f(temp_file)
        raise
      end
    end
  end
end
