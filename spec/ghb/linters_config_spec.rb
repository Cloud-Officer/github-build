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
end
