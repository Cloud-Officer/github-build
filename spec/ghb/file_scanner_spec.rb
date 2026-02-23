# frozen_string_literal: true

RSpec.describe(GHB::FileScanner) do
  let(:test_class) do
    Class.new do
      include GHB::FileScanner

      def initialize
        @file_cache = {}
      end

      public :find_files_matching, :file_contains?, :atomic_copy_config
    end
  end

  let(:scanner) { test_class.new }

  describe '#find_files_matching' do
    let(:temp_dir) { Dir.mktmpdir('ghb-test') }

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it 'finds files matching a pattern' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.touch("#{temp_dir}/test.rb")
      FileUtils.touch("#{temp_dir}/test.js")
      FileUtils.mkdir_p("#{temp_dir}/lib")
      FileUtils.touch("#{temp_dir}/lib/app.rb")

      pattern = /\.rb$/
      matches = scanner.find_files_matching(temp_dir, pattern, [])

      expect(matches).to(include("#{temp_dir}/test.rb"))
      expect(matches).to(include("#{temp_dir}/lib/app.rb"))
      expect(matches).not_to(include("#{temp_dir}/test.js"))
    end

    it 'excludes specified paths' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.mkdir_p("#{temp_dir}/vendor")
      FileUtils.touch("#{temp_dir}/app.rb")
      FileUtils.touch("#{temp_dir}/vendor/gem.rb")

      pattern = /\.rb$/
      matches = scanner.find_files_matching(temp_dir, pattern, ['vendor'])

      expect(matches).to(include("#{temp_dir}/app.rb"))
      expect(matches).not_to(include("#{temp_dir}/vendor/gem.rb"))
    end

    it 'excludes node_modules by default' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.mkdir_p("#{temp_dir}/node_modules")
      FileUtils.touch("#{temp_dir}/app.js")
      FileUtils.touch("#{temp_dir}/node_modules/lib.js")

      pattern = /\.js$/
      matches = scanner.find_files_matching(temp_dir, pattern, [])

      expect(matches).to(include("#{temp_dir}/app.js"))
      expect(matches).not_to(include("#{temp_dir}/node_modules/lib.js"))
    end

    it 'excludes vendor by default' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.mkdir_p("#{temp_dir}/vendor")
      FileUtils.touch("#{temp_dir}/app.rb")
      FileUtils.touch("#{temp_dir}/vendor/bundle.rb")

      pattern = /\.rb$/
      matches = scanner.find_files_matching(temp_dir, pattern, [])

      expect(matches).to(include("#{temp_dir}/app.rb"))
      expect(matches).not_to(include("#{temp_dir}/vendor/bundle.rb"))
    end

    it 'respects max_depth option' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.mkdir_p("#{temp_dir}/a/b/c/d/e/f")
      FileUtils.touch("#{temp_dir}/level0.rb")
      FileUtils.touch("#{temp_dir}/a/level1.rb")
      FileUtils.touch("#{temp_dir}/a/b/c/d/e/f/level6.rb")

      pattern = /\.rb$/

      # max_depth limits how deep we traverse from the starting path
      shallow_matches = scanner.find_files_matching(temp_dir, pattern, [], max_depth: 1)
      deep_matches = scanner.find_files_matching(temp_dir, pattern, [], max_depth: 10)

      # Shallow search should find files near the root but not deeply nested ones
      expect(shallow_matches).to(include("#{temp_dir}/level0.rb"))
      expect(shallow_matches).not_to(include("#{temp_dir}/a/b/c/d/e/f/level6.rb"))

      # Deep search should find all files
      expect(deep_matches).to(include("#{temp_dir}/level0.rb"))
      expect(deep_matches).to(include("#{temp_dir}/a/level1.rb"))
      expect(deep_matches).to(include("#{temp_dir}/a/b/c/d/e/f/level6.rb"))
    end

    it 'returns empty array for non-existent path' do
      matches = scanner.find_files_matching('/nonexistent/path/that/does/not/exist', /\.rb$/, [])
      expect(matches).to(eq([]))
    end

    it 'handles permission denied gracefully' do # rubocop:disable RSpec/ExampleLength
      skip 'Cannot test permission denied as root' if Process.uid.zero? # rubocop:disable RSpec/Pending

      restricted_dir = "#{temp_dir}/restricted"
      FileUtils.mkdir_p(restricted_dir)
      FileUtils.chmod(0o000, restricted_dir)

      expect { scanner.find_files_matching(restricted_dir, /.*/, []) }
        .not_to(raise_error)

      FileUtils.chmod(0o755, restricted_dir)
    end
  end

  describe '#file_contains?' do
    let(:temp_file) { Tempfile.new(['test', '.txt']) }

    after do
      temp_file.close
      temp_file.unlink
    end

    it 'returns true when file contains pattern' do
      temp_file.write("gem 'rails'\ngem 'pg'\ngem 'redis'\n")
      temp_file.flush

      expect(scanner.file_contains?(temp_file.path, 'redis')).to(be(true))
    end

    it 'returns false when file does not contain pattern' do
      temp_file.write("gem 'rails'\ngem 'pg'\n")
      temp_file.flush

      expect(scanner.file_contains?(temp_file.path, 'redis')).to(be(false))
    end

    it 'returns false for non-existent file' do
      expect(scanner.file_contains?('/nonexistent/file.txt', 'pattern')).to(be(false))
    end

    it 'handles partial matches' do
      temp_file.write("mongodb-driver\n")
      temp_file.flush

      expect(scanner.file_contains?(temp_file.path, 'mongo')).to(be(true))
    end
  end

  describe 'command injection prevention' do
    let(:temp_dir) { Dir.mktmpdir('ghb-security-test') }

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it 'does not execute shell commands in patterns' do
      malicious_pattern = '$(touch /tmp/pwned)'
      pwned_file = '/tmp/pwned'
      FileUtils.rm_f(pwned_file)

      # This should not create the file
      scanner.find_files_matching(temp_dir, Regexp.new(Regexp.escape(malicious_pattern)), [])

      expect(File.exist?(pwned_file)).to(be(false))
    end

    it 'handles regex special characters safely' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      FileUtils.touch("#{temp_dir}/file.rb")
      FileUtils.touch("#{temp_dir}/file[1].rb")

      pattern = /\[1\]\.rb$/
      matches = scanner.find_files_matching(temp_dir, pattern, [])

      expect(matches).to(include("#{temp_dir}/file[1].rb"))
      expect(matches).not_to(include("#{temp_dir}/file.rb"))
    end
  end

  describe '#atomic_copy_config' do
    let(:temp_dir) { Dir.mktmpdir('ghb-atomic-test') }

    after do
      FileUtils.rm_rf(temp_dir)
    end

    it 'copies file to target location' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/target.txt"
      File.write(source, "original content\n")

      scanner.atomic_copy_config(source, target)

      expect(File.exist?(target)).to(be(true))
      expect(File.read(target)).to(eq("original content\n"))
    end

    it 'applies transformation block to content' do
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/target.txt"
      File.write(source, "hello world\n")

      scanner.atomic_copy_config(source, target, &:upcase)

      expect(File.read(target)).to(eq("HELLO WORLD\n"))
    end

    it 'replaces existing regular file' do # rubocop:disable RSpec/ExampleLength
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/target.txt"
      File.write(source, "new content\n")
      File.write(target, "old content\n")

      scanner.atomic_copy_config(source, target)

      expect(File.read(target)).to(eq("new content\n"))
    end

    it 'replaces existing symlink' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/target.txt"
      other = "#{temp_dir}/other.txt"
      File.write(source, "new content\n")
      File.write(other, "other content\n")
      FileUtils.ln_s(other, target)

      scanner.atomic_copy_config(source, target)

      expect(File.symlink?(target)).to(be(false))
      expect(File.read(target)).to(eq("new content\n"))
    end

    it 'cleans up temp file on failure' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      source = "#{temp_dir}/source.txt"
      target = "#{temp_dir}/subdir/target.txt"
      File.write(source, "content\n")
      # Don't create subdir - this will cause mv to fail

      expect { scanner.atomic_copy_config(source, target) }
        .to(raise_error(Errno::ENOENT))

      # Verify no temp files left behind
      temp_files = Dir.glob("#{temp_dir}/*.tmp.*")
      expect(temp_files).to(be_empty)
    end

    it 'preserves original file if copy fails' do # rubocop:disable RSpec/ExampleLength,RSpec/MultipleExpectations
      source = "#{temp_dir}/nonexistent.txt"
      target = "#{temp_dir}/target.txt"
      File.write(target, "original content\n")

      expect { scanner.atomic_copy_config(source, target) }
        .to(raise_error(Errno::ENOENT))

      # Original file should still exist with original content
      expect(File.read(target)).to(eq("original content\n"))
    end
  end
end
