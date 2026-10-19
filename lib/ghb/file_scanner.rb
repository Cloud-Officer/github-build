# frozen_string_literal: true

require 'active_support/core_ext/hash/keys'
require 'fileutils'
require 'find'
require 'psych'

module GHB
  module FileScanner
    private

    def cached_file_read(path)
      @file_cache[path] ||= File.read(path)
    end

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

    # Entries match literally and only as whole path segments ("app" never matches "application").
    def excluded_paths_pattern(excluded_paths)
      segments =
        (excluded_paths + excluded_dirs_from_config).filter_map do |entry|
          segment = entry.to_s.strip.delete_prefix('./').chomp('/')
          Regexp.escape(segment) unless segment.empty?
        end

      segments.empty? ? Regexp.union : Regexp.new("(?:\\A|/)(?:#{segments.uniq.join('|')})(?:/|\\z)")
    end

    def find_files_matching(path, pattern, excluded_paths = [], max_depth: nil)
      matches = []
      base_depth = path.count(File::SEPARATOR)
      excluded_pattern = excluded_paths_pattern(excluded_paths)

      Find.find(path) do |file_path|
        # Check max depth
        if max_depth
          current_depth = file_path.count(File::SEPARATOR) - base_depth
          Find.prune if current_depth > max_depth
        end

        if file_path.match?(excluded_pattern) || git_ignored?(file_path)
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

    def git_ignored?(file_path)
      ignored = gitignored_paths
      return false if ignored.empty?

      relative = file_path.delete_prefix('./')

      ignored.any? do |entry|
        if entry.end_with?('/')
          directory = entry.chomp('/')
          relative == directory || relative.start_with?("#{directory}/")
        else
          relative == entry
        end
      end
    end

    def gitignored_paths
      return @gitignored_paths if defined?(@gitignored_paths)

      output = `git ls-files --others --ignored --exclude-standard --directory 2>/dev/null`
      entries = output.split("\n")
      entries.map!(&:strip)
      entries.reject!(&:empty?)
      @gitignored_paths = entries
    rescue StandardError
      @gitignored_paths = []
    end

    def file_contains?(file, pattern)
      return false unless File.exist?(file) && File.file?(file)

      File.foreach(file) do |line|
        return true if line.include?(pattern)
      end

      false
    rescue Errno::ENOENT, Errno::EACCES
      false
    end

    def file_shebang_matches?(file, pattern)
      return false unless File.exist?(file) && File.file?(file)

      first_line = File.open(file, 'r', &:gets)
      return false if first_line.nil?

      first_line.match?(pattern)
    rescue Errno::ENOENT, Errno::EACCES, ArgumentError
      # ArgumentError covers a binary first line that is not valid UTF-8.
      false
    end

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
