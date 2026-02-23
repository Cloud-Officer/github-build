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
    def find_files_matching(path, pattern, excluded_paths = [], max_depth: nil)
      matches = []
      base_depth = path.count(File::SEPARATOR)

      Find.find(path) do |file_path|
        # Check max depth
        if max_depth
          current_depth = file_path.count(File::SEPARATOR) - base_depth
          Find.prune if current_depth > max_depth
        end

        # Skip excluded paths (submodules, excluded_folders, common vendor dirs)
        should_skip = excluded_paths.any? { |excluded| file_path.include?(excluded) } ||
                      file_path.include?('/node_modules/') ||
                      file_path.include?('/vendor/') ||
                      file_path.include?('/linters/')

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
