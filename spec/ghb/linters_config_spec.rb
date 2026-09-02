# frozen_string_literal: true

# Guards the per-linter `condition` in config/linters.yaml against catalog drift
# (the root cause of CI-010): a linter job should carry the
# `github.event_name == 'pull_request'` guard ONLY when it needs a pull request
# to be meaningful, i.e. it reports through reviewdog's github-pr-review reporter.
# Linters that fail the job by exit code work on pushes too and must run
# unconditionally so regressions on master/tags/dependabot are still caught.
RSpec.describe('config/linters.yaml conditions') do # rubocop:disable RSpec/DescribeClass
  let(:linters) do
    Psych.safe_load(File.read("#{__dir__}/../../config/linters.yaml")).transform_keys(&:to_sym)
  end

  # reviewdog/github-pr-review reporters -> require a PR.
  let(:pr_only) { %i[actionlint eslint flake8 golangci hadolint ktlint markdownlint pmd protolint rubocop shellcheck yamllint] }

  # Exit-code linters -> meaningful on every event, no PR guard.
  let(:run_always) { %i[bandit cfnlint phpcs phpstan semgrep swiftlint trivy] }

  it 'lists exactly the known linters (a new linter must be classified explicitly)' do
    expect(linters.keys.sort).to(eq((pr_only + run_always).sort))
  end

  it 'guards every reviewdog linter with the pull_request condition' do
    conditions = pr_only.map { |name| linters[name]['condition'] }
    expect(conditions).to(all(eq("github.event_name == 'pull_request'")))
  end

  it 'runs every exit-code linter on all events (no condition)' do
    conditions = run_always.map { |name| linters[name]['condition'] }
    expect(conditions).to(all(be_nil))
  end

  # ShellCheck is the one linter whose files are routinely extensionless: shell
  # tools install onto PATH without a suffix, so an extension-only pattern left
  # it disabled for repositories made entirely of them (and deleted their
  # .shellcheckrc on every run).
  describe 'shellcheck extensionless detection' do
    let(:entry) { linters[:shellcheck] }

    def matches_path?(path)
      path.match?(Regexp.new(entry['pattern']))
    end

    def matches_shebang?(line)
      line.match?(Regexp.new(entry['shebang_match']))
    end

    it 'declares a shebang_match so the widened pattern is narrowed by content' do
      expect(entry['shebang_match']).not_to(be_nil)
    end

    it 'matches extensionless paths as well as *.sh', :aggregate_failures do
      expect(matches_path?('./linters')).to(be(true))
      expect(matches_path?('./bin/deploy')).to(be(true))
      expect(matches_path?('./scripts/build.sh')).to(be(true))
    end

    it 'does not match paths carrying an unrelated extension', :aggregate_failures do
      expect(matches_path?('./deploy.rb')).to(be(false))
      expect(matches_path?('./tests/x.bats')).to(be(false))
    end

    it 'accepts every shell dialect ShellCheck supports', :aggregate_failures do
      expect(matches_shebang?('#!/bin/sh')).to(be(true))
      expect(matches_shebang?('#!/usr/bin/env bash')).to(be(true))
      expect(matches_shebang?('#!/bin/dash')).to(be(true))
      expect(matches_shebang?('#!/bin/ksh')).to(be(true))
      expect(matches_shebang?('#!/bin/bash -e')).to(be(true))
    end

    it 'rejects shebangs ShellCheck would fail on with SC1071', :aggregate_failures do
      expect(matches_shebang?('#!/usr/bin/env ruby')).to(be(false))
      expect(matches_shebang?('#!/usr/bin/env python3')).to(be(false))
      expect(matches_shebang?('#!/usr/bin/env bats')).to(be(false))
    end
  end

  describe 'managed excluded-dirs coverage' do
    let(:templates) { Dir["#{__dir__}/../../config/linters/*"].map { |path| File.basename(path) } }

    let(:helper) do
      Class.new do
        include GHB::FileScanner
        include GHB::LinterIgnoreRenderer

        def initialize
          @file_cache = {}
          @options = Struct.new(:languages_config_file).new('config/languages.yaml')
        end

        public :excluded_dirs_from_config, :render_excluded_dirs
      end.new
    end

    it 'renders every managed config back to its own template unchanged' do
      dirs = helper.excluded_dirs_from_config

      GHB::LinterIgnoreRenderer::FORMATS.each_key do |name|
        content = File.read("#{__dir__}/../../config/linters/#{name}")
        expect(helper.render_excluded_dirs(name.to_s, content, dirs)).to(eq(content))
      end
    end

    it 'gives every managed config a sentinel block in its template' do
      GHB::LinterIgnoreRenderer::FORMATS.each_key do |name|
        expect(File.read("#{__dir__}/../../config/linters/#{name}")).to(include('ghb:excluded-dirs:start'))
      end
    end
  end
end
