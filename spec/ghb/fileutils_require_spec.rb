# frozen_string_literal: true

require 'open3'

# Regression guard for BUG-009: files that call FileUtils must require 'fileutils'
# themselves rather than relying on a transitive require from workflow.rb.
#
# Each file is loaded in a fresh Ruby process (no spec_helper, no transitive
# requires) and asserted to define the FileUtils constant. Before the fix these
# files loaded without FileUtils, so a standalone load raised NameError on first
# FileUtils call; after the fix the constant is present on load.
RSpec.describe('explicit fileutils requires (BUG-009)') do # rubocop:disable RSpec/DescribeClass
  %w[dependabot_manager linter_job_builder file_scanner].each do |file|
    it "defines FileUtils after loading #{file}.rb in isolation" do # rubocop:disable RSpec/MultipleExpectations
      path = File.expand_path("../../lib/ghb/#{file}.rb", __dir__)
      script = "require #{path.inspect}; print defined?(FileUtils).to_s"
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, '-e', script)

      expect(status).to(be_success, "load failed: #{stderr}")
      expect(stdout).to(eq('constant'))
    end
  end
end
