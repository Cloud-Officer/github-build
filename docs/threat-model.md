# Threat Model — github-build

**Date:** 2026-09-07   **Scope:** the entire `github-build` repository — the Ruby CLI (`bin/`, `lib/ghb/`), its
bundled configuration (`config/`), the maintenance shell scripts (`bin/update_versions.sh`,
`bump-actions/bump-actions.sh`), and the CI workflows this tool **emits** into consumer repositories
(`build.yml`, `auto-approve.yml`, `dependencies.yml`, `docker.yml`). Nothing was sampled or skipped.
**Method:** STRIDE, weighted toward supply-chain and CI-authorization threats.
**Status:** DRAFT — requires human security sign-off.

## Method selection

STRIDE alone was applied. LINDDUN was deliberately **not** layered in: the system processes no personal,
health, or payment data — its inputs are source trees and YAML config, and its outputs are workflow files
and GitHub repository settings. PASTA and attack trees were not used either; the system is a single-process
CLI with one external API dependency, so the enumeration cost would exceed the value.

The threat classes that dominate here are the ones current to CI/CD tooling in 2026: mutable action tags,
credentials reachable by third-party code executing inside a build step, `pull_request_target` privilege
escalation, and automated merge paths that bypass human review. Those are what the model probes hardest.

## System overview

`github-build` is a **generator with write access to production controls**. Run from the root of a target
repository, it:

1. Scans the working tree in pure Ruby (`lib/ghb/file_scanner.rb`) to detect languages, dependency
   lockfiles, and applicable linters.
2. Reads any existing `.github/workflows/build.yml`, preserving hand-edited sections
   (`lib/ghb/workflow/workflow.rb:76`).
3. Emits `build.yml` plus the companion `auto-approve.yml`, `dependencies.yml`, and `docker.yml`
   workflows, each wiring `${{secrets.*}}` references into steps.
4. Copies or symlinks linter configs into the target repo and rewrites its `.gitignore` from a remote
   template service.
5. Calls the GitHub REST and GraphQL APIs with a `GITHUB_TOKEN` from the environment to set branch
   protection, required status checks, merge policy, and Advanced Security state
   (`lib/ghb/repository_configurator.rb`).

Two properties drive the risk profile. First, step 5 means a bug or a manipulated input can **weaken a
repository's security posture**, not merely produce a bad file. Second, the generated workflows are
replicated across every Cloud-Officer repository, so a weakness in a template is an **org-wide** weakness,
not a single-repo one.

## Assets

| Asset | Sensitivity | Where it lives |
| --- | --- | --- |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | Critical | GitHub secrets; injected by `GHB.secrets(:aws)` (`lib/ghb.rb:55`) into CodeDeploy, AWS, and Vercel jobs |
| `DOCKER_USERNAME` / `DOCKER_PASSWORD` | High | GitHub secrets; `lib/ghb/dockerhub_manager.rb:53` |
| `GH_BOT_PAT` (bot account PAT used to approve PRs) | Critical | GitHub secrets; `lib/ghb/auto_approve_manager.rb:141` |
| `GH_PAT` (long-lived, organization-scoped PAT) | Critical | GitHub secrets; referenced by every generated Setup/linter/deploy step |
| `GITHUB_TOKEN` (operator token used by the CLI) | High | Operator environment / CI env; read at `lib/ghb/repository_configurator.rb:85` |
| `SSH_KEY` (deploy key for private sibling repositories) | Critical | GitHub secrets; `GHB.secrets(:ssh)` (`lib/ghb.rb:53`) |
| `VERCEL_TOKEN` / `VERCEL_ORG_ID` / `VERCEL_PROJECT_ID` | High | GitHub secrets; `lib/ghb/vercel_job_builder.rb:150` |
| Branch-protection and Advanced Security configuration of every consumer repo | Critical | GitHub; written by `lib/ghb/repository_configurator.rb` |
| Generated workflow files (`.github/workflows/*.yml`) across all consumer repos | High | Each consumer repository; the effective CI supply chain |
| Source trees of consumer repositories (read during detection) | Medium | Local working tree at run time |

## Trust boundaries & entry points

| # | Boundary / entry point | File / route | Actors reaching it |
| --- | --- | --- | --- |
| 1 | CLI arguments (`ARGV`) | `bin/github-build.rb:6` → `lib/ghb/options.rb:51` | Operator (maintainer, or CI running the tool) |
| 2 | Consumer repository `.gitmodules` (drives config symlink targets) | `lib/ghb/linter_job_builder.rb:29` | Anyone who can land a commit in the target repo |
| 3 | Consumer repository working tree (language/linter/dependency detection) | `lib/ghb/file_scanner.rb:57` | Anyone who can land a commit in the target repo |
| 4 | Existing `build.yml` — parsed, and its header line replayed as CLI args | `lib/ghb/options.rb:68`, `lib/ghb/workflow/workflow.rb:76` | Anyone who can land a commit in the target repo |
| 5 | Generated CI runner ↔ GitHub secrets store (secrets materialized into steps) | `lib/ghb.rb:52` | Any code executing in a generated job: linters, tests, package managers, third-party actions |
| 6 | GitHub REST / GraphQL API (settings written with an operator token) | `lib/ghb/github_api_client.rb:38` | Operator token; GitHub as a trusted third party |
| 7 | Third-party GitHub Actions resolved at run time by mutable tag | `lib/ghb.rb:15`, `config/actions.yaml` | Upstream action maintainers; anyone who compromises them |
| 8 | `toptal.com` gitignore template service (response written to disk) | `lib/ghb/gitignore_manager.rb:42` | Toptal; a network attacker able to break TLS |
| 9 | Upstream release/tag metadata consumed by the bump cron | `bump-actions/bump-actions.sh:63` | Upstream action maintainers |
| 10 | Upstream version endpoints consumed by `update_versions.sh` (go.dev, nodejs.org, php.net, …) | `bin/update_versions.sh:32` | Those services; a network attacker able to break TLS |

## Threats (prioritized)

Rating rubric: **Impact** ∈ {Critical, High, Medium, Low} (credential loss, RCE, auth bypass, org-wide
blast radius push it up). **Likelihood** ∈ {High, Medium, Low} (exposure, attacker skill required, whether
an existing control already blocks it). **Risk** is derived from the Impact × Likelihood matrix in the
skill rubric — Critical impact with any likelihood is at least High; Low impact stays Low.

### T-01 — External and first-party actions are pinned to mutable tags · Risk: Critical

- **STRIDE category:** Tampering, Elevation of privilege
- **Abuse path:** `lib/ghb.rb:15` pins every first-party composite action to the floating
  `CI_ACTIONS_VERSION = 'v3'`, and `config/actions.yaml` pins `actions/checkout: v7` and
  `peter-evans/create-pull-request: v8` — all mutable Git tags, not commit SHAs.
  `bump-actions/bump-actions.sh:29` treats a 40-character SHA as a value to *skip*, so tag pinning is the
  deliberate policy. Every generated `build.yml` hands `cloud-officer/ci-actions/setup@v3` both
  `${{secrets.SSH_KEY}}` and `${{secrets.GH_PAT}}` (`lib/ghb/language_job_builder.rb:295`). An attacker who
  gains write access to `cloud-officer/ci-actions` — or to `actions/checkout` — and repoints the tag
  executes their code, with those secrets in scope, in every Cloud-Officer repository on the next build,
  with no PR, no review, and no diff anywhere in the consumer repos.
- **Likelihood × Impact:** Medium × Critical
- **Existing control:** Partial. `config/actions.yaml` centralizes external versions, and the weekly bump
  cron opens a PR for human review (`.github/workflows/external-actions-bump.yml`). Neither prevents a tag
  from being silently repointed under an already-approved version.
- **Recommended mitigation:** Pin external actions to full commit SHAs with a version comment
  (`actions/checkout@<sha> # v7`) and teach `bump-actions.sh` to resolve tag → SHA instead of skipping
  SHAs. For `cloud-officer/*`, either SHA-pin as well or enforce protected, immutable release tags on
  `ci-actions` with required reviews on the tag-moving path.
- **Residual risk / decision:** SHA pinning trades a real reduction in blast radius for more bump churn.
  Accept-vs-mitigate is a human call; if accepted, the compensating control should be immutable tags plus
  branch protection on `ci-actions`.

### T-02 — Weekly dependency cron executes untrusted upstream code with `GH_PAT` in the environment · Risk: Critical

- **STRIDE category:** Elevation of privilege, Information disclosure
- **Abuse path:** `lib/ghb/dependabot_manager.rb:96` emits an "Update Dependencies" step whose env is
  `GH_PAT: ${{secrets.GH_PAT}}` and whose body runs the package manager's update command (`bundle update`,
  `npm update`, `composer update`, …). Those commands execute arbitrary maintainer-controlled code —
  Bundler extension builds, npm lifecycle scripts — inside the step. The org-scoped PAT is a plain
  environment variable readable by any child process, and the `git config --global … insteadOf` rewrites
  written at `lib/ghb/application.rb:60` persist it into `~/.gitconfig` on the runner. One malicious
  version of any transitive dependency exfiltrates a long-lived credential with write access to every
  repository in the organization.
- **Likelihood × Impact:** Medium × Critical
- **Existing control:** Partial, and deliberately so. The `insteadOf` rewrites were narrowed from a bare
  `github.com/` to `github.com/${{github.repository_owner}}/` (comment at `lib/ghb/application.rb:52`,
  issue CI-004/#410) so the PAT is no longer attached to arbitrary github.com fetches. That limits *where
  git will send* the token; it does not stop a process from reading `$GH_PAT` directly.
- **Recommended mitigation:** Replace `GH_PAT` in this step with a short-lived GitHub App installation
  token minted per run and scoped to the repositories actually needed, or split the job so the update
  command runs with no credential and a separate, code-free step performs the authenticated push. Failing
  that, run the update under a network egress allowlist.
- **Residual risk / decision:** For human sign-off. Any package-manager update inherently runs upstream
  code; the decision is whether the credential in scope stays long-lived and org-wide.

### T-03 — Auto-approval satisfies the required-review control without a human · Risk: High

- **STRIDE category:** Elevation of privilege, Repudiation
- **Abuse path:** `lib/ghb/auto_approve_manager.rb:136` approves any non-draft PR whose author matches the
  catch-all line of `CODEOWNERS`, using `${{secrets.GH_BOT_PAT}}`, and re-fires on `synchronize` — so a new
  push is re-approved immediately, defeating both `dismiss_stale_reviews` and `require_last_push_approval`
  set at `lib/ghb/repository_configurator.rb:329`. With `allow_auto_merge: true`
  (`lib/ghb/repository_configurator.rb:398`) and `required_approving_review_count: 1`, a single code-owner
  account — compromised, or an insider acting alone — can merge to the default branch with zero human eyes
  on the diff. Chained with T-02, a poisoned upstream package flows from cron → PR → bot approval → merge
  with no human in the path at any point.
- **Likelihood × Impact:** Medium × High
- **Existing control:** Good against the classic `pull_request_target` "pwn request": the job is gated on
  `github.event.pull_request.head.repo.full_name == github.repository`
  (`lib/ghb/auto_approve_manager.rb:112`), and the checkout uses `github.event.pull_request.base.sha`
  (`lib/ghb/auto_approve_manager.rb:119`), so fork code never runs and `CODEOWNERS` is read from the base
  branch rather than the PR. Those controls address code execution, not authorization — nothing here
  restores four-eyes review.
- **Recommended mitigation:** Restrict auto-approval to PRs whose diff touches only an allowlisted set of
  paths (lockfiles, `.soup.json`, `config/actions.yaml`), and require a genuine second reviewer for
  anything touching `lib/`, `bin/`, `.github/`, or `*.sh`. Alternatively require two approvals so the bot's
  approval can never be the only one.
- **Residual risk / decision:** This is an intentional throughput trade-off. It should be *documented as
  accepted* with its scope stated, not left implicit — an ISO 27001 auditor will read
  `required_approving_review_count: 1` plus a bot approver as an ineffective segregation-of-duties control.

### T-04 — Long-lived organization PAT is handed to third-party linter actions running over PR content · Risk: High

- **STRIDE category:** Information disclosure, Elevation of privilege
- **Abuse path:** `lib/ghb/linter_job_builder.rb:213` sets `github-token: ${{secrets.GH_PAT}}` on every
  generated linter step. Those steps run RuboCop, ESLint, Semgrep, Trivy, PMD, SwiftLint and friends —
  each pulling its own plugin/rule dependencies — over the contents of the pull request being linted. A
  malicious plugin, or a linter configuration in the PR that loads one, executes with the org-scoped PAT in
  the environment.
- **Likelihood × Impact:** Medium × High
- **Existing control:** Partial. The rationale is recorded inline (the linter action's internal
  `actions/checkout` needs the PAT for private cross-repo submodules), and `reviewdog-token` was
  deliberately downgraded to the job's ephemeral `${{secrets.GITHUB_TOKEN}}`
  (`lib/ghb/linter_job_builder.rb:214`). Fork PRs receive no secrets from GitHub at all, so the reachable
  actor is someone who can push a branch to the repository.
- **Recommended mitigation:** Split checkout from linting: perform the submodule-bearing checkout in a
  dedicated step holding the PAT, then run the linter in a step with no credential. Where the PAT must
  stay, replace it with a GitHub App token scoped to the submodule repositories only.
- **Residual risk / decision:** Mitigate.

### T-05 — Repository administrators bypass every branch-protection control, and the review-bypass allowlist is preserved rather than cleared · Risk: High

- **STRIDE category:** Elevation of privilege
- **Abuse path:** `lib/ghb/repository_configurator.rb:326` writes `enforce_admins: false` on every
  configured repository, so any admin can push directly to the default branch and bypass required reviews
  and required status checks entirely. Separately,
  `lib/ghb/repository_configurator.rb:302` reads the existing `bypass_pull_request_allowances` users and
  teams out of the current protection and writes them straight back — so an actor previously granted
  review-bypass keeps it across every regeneration, silently. This is inconsistent with how the same class
  of allowlist is treated a few lines away: `enforce_force_push_allowlist`
  (`lib/ghb/repository_configurator.rb:152`) actively detects the force-push allowlist, warns, clears it
  over GraphQL, and **fails the run** if it survives.
- **Likelihood × Impact:** Medium × High
- **Existing control:** Missing for both. The force-push allowlist is the only bypass path currently
  enforced.
- **Recommended mitigation:** Either set `enforce_admins: true`, or make it an explicit,
  documented per-repo exception. Report `bypass_pull_request_allowances` entries the way the force-push
  allowlist is reported — enumerate the actors, warn, and clear them unless an explicit flag preserves
  them.
- **Residual risk / decision:** For human sign-off; `enforce_admins: true` blocks legitimate break-glass
  fixes, so the accepted answer may be "leave false, but surface it in the run output."

### T-06 — Private repositories run with secret scanning, push protection, and CodeQL disabled · Risk: High

- **STRIDE category:** Information disclosure
- **Abuse path:** `lib/ghb/repository_configurator.rb:409` turns *off* secret scanning, push protection,
  validity checks, non-provider patterns, and AI detection for every private repository, and
  `lib/ghb/repository_configurator.rb:427` sets CodeQL default setup to `not-configured` — explicitly to
  avoid GitHub Advanced Security charges. A developer who commits an AWS key or a PAT into a private repo
  therefore receives no push-protection block and no alert; the credential sits in history until someone
  notices. Private repositories are exactly where this organization's own deploy credentials and
  infrastructure code live.
- **Likelihood × Impact:** High × High
- **Existing control:** Missing by design. `vulnerability-alerts` and `automated-security-fixes` remain
  enabled for all repositories (`lib/ghb/repository_configurator.rb:387`), which covers known-CVE
  dependencies but not committed secrets or code-level findings.
- **Recommended mitigation:** Compensate with a free, tool-side control that does not depend on GHAS
  licensing: enable a pre-commit secret scanner (gitleaks, `trufflehog`) in the generated `build.yml` for
  private repos, or a `pre-push` hook installed alongside the linter configs. Trivy is already generated as
  a linter job and its secret-scanning mode can cover much of this gap at no cost.
- **Residual risk / decision:** The cost decision is legitimate and should be recorded as an accepted risk
  with the compensating control named — not left as an unexplained "security features: disabled."

### T-07 — Every generated job inherits `pull-requests: write` on the workflow `GITHUB_TOKEN` · Risk: Medium

- **STRIDE category:** Elevation of privilege
- **Abuse path:** `lib/ghb/application.rb:271` sets the workflow-level default to
  `{contents: read, pull-requests: write}` because reviewdog needs it to post review comments. No linter in
  `config/linters.yaml` declares a job-level `permissions:` block, and `LanguageJobBuilder` never calls
  `do_permissions`, so unit-test jobs — which run `bundle exec rspec`, `npm test`, and other
  fully-attacker-controlled code from the PR branch — inherit `pull-requests: write` too. That token can
  post, edit, and dismiss review comments and manipulate PR metadata.
- **Likelihood × Impact:** Medium × Medium
- **Existing control:** Missing at the job level. The workflow-level scope is at least explicit and narrow
  (two permissions, not `write-all`), and job-level overrides are supported for linters
  (`lib/ghb/linter_job_builder.rb:193`) but unused.
- **Recommended mitigation:** Set the workflow default to `{contents: read}` and grant
  `pull-requests: write` only on the linter jobs whose config carries `reviewdog: true`, using the existing
  `do_permissions` path.
- **Residual risk / decision:** Mitigate — this is a low-cost change with an existing mechanism.

### T-08 — `.gitignore` is fetched over the network and written verbatim · Risk: Medium

- **STRIDE category:** Tampering
- **Abuse path:** `lib/ghb/gitignore_manager.rb:42` builds
  `https://www.toptal.com/developers/gitignore/api/<templates>` and
  `lib/ghb/gitignore_manager.rb:79` writes the response body into the repository's `.gitignore` after only
  cosmetic rewrites. There is no checksum, no pinning, and no schema check. A compromised or hostile
  response can (a) inject a negation such as `!.env` that un-ignores a secrets file so it becomes
  committable, or (b) add broad ignore rules that hide paths from `git ls-files`, which
  `lib/ghb/file_scanner.rb:116` consults — so ignored files are then skipped by language, dependency, and
  linter detection, silently removing code from CI coverage.
- **Likelihood × Impact:** Low × High
- **Existing control:** Partial: HTTPS with a 30-second timeout and a non-200 hard failure. No integrity or
  content validation.
- **Recommended mitigation:** Reject any fetched line beginning with `!`, and validate that the response
  looks like a gitignore body before writing. Better: vendor the templates into `config/` and refresh them
  through the same reviewed-PR cron that bumps actions, removing the run-time network dependency entirely.
- **Residual risk / decision:** Mitigate — the `!`-rejection alone is a few lines.

### T-09 — `.gitmodules` in the target repo controls symlink targets created in the repo root · Risk: Medium

- **STRIDE category:** Tampering, Information disclosure
- **Abuse path:** `lib/ghb/linter_job_builder.rb:33` derives `script_path` from the `path = …` value of the
  target repository's `.gitmodules`, with no normalization or containment check; a `..`-bearing value is
  taken as-is. `lib/ghb/linter_job_builder.rb:142` then calls
  `FileUtils.ln_s("#{script_path}/linters/#{config_name}", config_name, force: true)`, creating a symlink
  at the repo root that points wherever `script_path` leads (subject only to `File.exist?` on the target).
  The linter subsequently reads its config through that link, so a crafted `.gitmodules` can pull a file
  from outside the repository into a linter's input and, from there, into CI logs.
- **Likelihood × Impact:** Low × Medium
- **Existing control:** Missing. `force: true` also means an existing file at that name is replaced without
  a prompt.
- **Recommended mitigation:** Expand `script_path` and require that it resolves inside the repository root
  before using it; skip the submodule with a warning otherwise.
- **Residual risk / decision:** Mitigate.

### T-10 — The target repo's `build.yml` header is replayed as CLI arguments · Risk: Medium

- **STRIDE category:** Tampering, Elevation of privilege
- **Abuse path:** `lib/ghb/options.rb:68` reads the first line of `.github/workflows/build.yml` and, when
  it starts with `# github-build`, `Shellwords.split`s it into `ARGV` (`lib/ghb/options.rb:24`). That file
  lives in the target repository and is modifiable by anyone who can land a commit there. A crafted header
  can therefore set `--build_file /any/path`, which `Workflow#write`
  (`lib/ghb/workflow/workflow.rb:147`) happily `mkdir_p`s and writes to — an arbitrary file write outside
  the repository, under the operator's identity; or point `--languages_config_file` at a traversal path
  (`lib/ghb/application.rb:157` joins it onto `#{__dir__}/../../` with no containment check) to have an
  arbitrary file parsed as YAML; or set `--skip_repository_settings` / `--ignored_linters semgrep` so a
  maintainer's regeneration silently stops enforcing branch protection or drops a security linter.
- **Likelihood × Impact:** Low × High
- **Existing control:** Partial. `Psych.safe_load` prevents object instantiation from a hostile YAML file,
  `Shellwords.escape` is used when writing the header back (`lib/ghb/options.rb:59`), and unknown flags
  raise. Nothing constrains the *values*, and the run is not sandboxed.
- **Recommended mitigation:** Treat replayed args as untrusted: restrict `--build_file` and every
  `--*_config_file` to paths that resolve inside the repository root (or the generator's own `config/`),
  and ignore skip-flags coming from the persisted header, requiring them on the real command line.
- **Residual risk / decision:** Mitigate. Exploitation requires a maintainer to run the tool against a repo
  carrying an attacker's commit — plausible during review of an external contribution.

### T-11 — `--sync_required_status_checks` rewrites remote branch protection from a repo-controlled file · Risk: Medium

- **STRIDE category:** Tampering, Elevation of privilege
- **Abuse path:** Without the flag, a mismatch between expected and actual required checks raises
  (`lib/ghb/repository_configurator.rb:290`) — a good fail-closed default. With it, the remote required-check
  list is overwritten by the list computed from the *local* workflow
  (`lib/ghb/repository_configurator.rb:311`). Since that workflow is a file in the target repository, a PR
  that removes or renames jobs, plus an operator running with `--sync_required_status_checks` (the
  documented remedy for exactly that mismatch), demotes those checks from required to absent.
- **Likelihood × Impact:** Low × Medium
- **Existing control:** Good default. The mismatch is printed in full — `MISSING` and `EXTRA` lists at
  `lib/ghb/repository_configurator.rb:281` — before the overwrite, so an attentive operator sees it. The
  flag is also excluded from the persisted header via `EPHEMERAL_FLAGS`
  (`lib/ghb/options.rb:13`), so it cannot be smuggled in through T-10.
- **Recommended mitigation:** Require an interactive confirmation, or refuse to *drop* a check that exists
  remotely unless a second explicit flag is passed; adding checks is the safe direction, removing them is
  not.
- **Residual risk / decision:** Accept with the operator warning, or mitigate with the asymmetric rule
  above. Human call.

### T-12 — Required status checks are not strict, so stale branches can merge · Risk: Medium

- **STRIDE category:** Tampering
- **Abuse path:** `lib/ghb/repository_configurator.rb:323` sets `strict: false`, so a branch may merge with
  green checks that ran against an out-of-date base. A security fix landing on the default branch — a
  linter rule tightened, a vulnerable dependency pinned — does not have to be re-validated against an
  in-flight PR, so a change that would fail against current `master` can still merge.
- **Likelihood × Impact:** Medium × Medium
- **Existing control:** Missing. `required_conversation_resolution: true` and
  `dismiss_stale_reviews: true` are set, which covers review staleness but not check staleness.
- **Recommended mitigation:** Set `strict: true` for repositories where the merge queue volume makes it
  practical, or adopt GitHub merge queues, which achieve the same guarantee without the rebase churn that
  motivated `strict: false`.
- **Residual risk / decision:** Likely accept for velocity; record the reasoning.

### T-13 — GitHub API error bodies are echoed into logs · Risk: Low

- **STRIDE category:** Information disclosure
- **Abuse path:** `lib/ghb/github_api_client.rb:94` appends up to 1000 characters of the response body to
  the raised error message, which `bin/github-build.rb:9` prints to stderr. When the tool runs inside CI,
  private repository metadata from a GitHub error response lands in a build log that may have a wider
  audience than the repository itself.
- **Likelihood × Impact:** Low × Low
- **Existing control:** Partial and deliberate — the body is truncated to 1000 characters, and the token is
  never included (it lives only in request headers). `e.backtrace` is printed only under `DEBUG`.
- **Recommended mitigation:** None required. If tightened, log the body only under `DEBUG` and keep the
  status line unconditional.
- **Residual risk / decision:** Accept.

### T-14 — Config-supplied regexes and an unbounded tree walk allow local denial of service · Risk: Low

- **STRIDE category:** Denial of service
- **Abuse path:** `lib/ghb/language_job_builder.rb:103` builds `Regexp.new(".*\\.(#{...})$")` from
  `config/languages.yaml`, and `lib/ghb/linter_job_builder.rb:68` builds `Regexp.new(linter[:pattern])`
  from `config/linters.yaml`; both are then matched against every path from an unbounded `Find.find`
  (`lib/ghb/file_scanner.rb:62`). A catastrophically-backtracking pattern — reachable if a config path is
  redirected via T-10 — or simply a very large working tree stalls the run.
- **Likelihood × Impact:** Low × Low
- **Existing control:** Partial. The configs are repository-bundled and validated for required keys
  (`lib/ghb/application.rb:186`); `max_depth` bounds the sub-project scan; exclusion patterns prune
  `node_modules`, `vendor`, and git-ignored trees before matching.
- **Recommended mitigation:** None required for a developer-run CLI. If the tool is ever run
  unattended against untrusted repositories, add a wall-clock timeout around detection.
- **Residual risk / decision:** Accept.

## Controls verified as present and effective

Recorded because they are load-bearing, and because a future refactor that removes one silently
reintroduces a threat:

- **No shell interpolation of repository-controlled data.** File discovery and content matching are pure
  Ruby (`lib/ghb/file_scanner.rb:57`, `:129`). The only backticks in the codebase —
  `lib/ghb/application.rb:139` and `lib/ghb/file_scanner.rb:116` — are fixed `git` command strings with no
  interpolated values. Command injection is not reachable.
- **YAML is always parsed with `Psych.safe_load`** (`lib/ghb/application.rb:161`,
  `lib/ghb/workflow/workflow.rb:83`, `lib/ghb/repository_configurator.rb:231`), with `Symbol` the only
  permitted extra class. Deserialization to arbitrary objects is not reachable.
- **`pull_request_target` is used correctly** in the generated auto-approve workflow: fork heads are
  excluded and the checkout is pinned to `base.sha` (`lib/ghb/auto_approve_manager.rb:112`, `:119`).
- **No blanket PAT rewrite at workflow-write time**, and regeneration actively strips a previously injected
  PAT from unit-test step environments (`LanguageJobBuilder.drop_injected_pat`,
  `lib/ghb/language_job_builder.rb:49`).
- **Dependency-install steps get the ephemeral repo-scoped `GITHUB_TOKEN`, not the PAT**
  (`lib/ghb/language_job_builder.rb:36`); unit-test steps get no token at all.
- **The force-push allowlist is detected, cleared, verified, and fails the run if it survives**
  (`lib/ghb/repository_configurator.rb:152`) — the one bypass path that is genuinely enforced rather than
  preserved.
- **API calls are bounded and retried safely:** open/read timeouts, capped rate-limit back-off, and a
  bounded retry count (`lib/ghb/github_api_client.rb:19`–`:21`).
- **The bump script validates upstream tag names before use** (`is_valid_version`,
  `bump-actions/bump-actions.sh:37`), with the injection risk called out in the comment above it — upstream
  tag names are attacker-controlled and reach a `sed` expression at
  `bump-actions/bump-actions.sh:126`.

## ISO 27001:2022 mapping

| Control | Coverage | Gaps surfaced |
| --- | --- | --- |
| **A.5.7** Threat intelligence | Model is organized around the threat classes current to CI/CD in 2026: mutable action tags (T-01), credentials reachable by build-step code (T-02, T-04), `pull_request_target` abuse (T-03), automated merge paths (T-03) | No documented process for tracking new action-supply-chain advisories; the bump cron tracks versions, not advisories |
| **A.8.25** Secure development lifecycle | This exercise is the design-phase threat model, repeatable and version-controlled alongside the code | Should be re-run on change to `repository_configurator.rb`, `auto_approve_manager.rb`, or any generated-workflow template — not left to drift |
| **A.8.27** Secure architecture & engineering principles | Ten trust boundaries identified and mapped to code; least-privilege applied to tokens is documented and partly implemented | T-01 (mutable pins) and T-07 (broad default job permissions) are architecture-level gaps |
| **A.8.28** Secure coding | Code-level sinks enumerated: symlink target (T-09), argument replay and path traversal (T-10), network content written to disk (T-08), regex construction (T-14). Injection and unsafe deserialization are confirmed *not* reachable | T-09 and T-10 are unmitigated input-validation gaps |
| **A.8.29** Security testing | Each abuse path above is directly usable as a security test case or pentest scope item; `spec/` already covers `repository_configurator` and `auto_approve_manager` behavior | No negative-path tests exist for T-09 (traversal in `.gitmodules`) or T-10 (hostile `build.yml` header); both are cheap RSpec cases |
| **A.5.3 / A.8.2** Segregation of duties, privileged access | — | T-03 (bot approval satisfies the review requirement) and T-05 (`enforce_admins: false`, preserved review-bypass allowlist) mean the four-eyes control is not effective as written. This is the finding most likely to be challenged in an audit |
| **A.8.12** Data leakage prevention | Vulnerability alerts and automated security fixes enabled on all repos | T-06: secret scanning and push protection are off for every private repository |

## Assumptions & out of scope

- **Assumed:** `GH_PAT`, `GH_BOT_PAT`, `SSH_KEY`, and the AWS/Vercel/Docker secrets are stored as GitHub
  Actions secrets with organization- or repository-level access controls. Their provisioning, rotation
  cadence, and actual scopes were not inspected — the repository only references them by name, which is
  correct. **Verifying that `GH_PAT` is scoped as narrowly as its usage requires is a follow-up item, and
  bounds the real impact of T-01, T-02, and T-04.**
- **Out of scope:** the internals of `cloud-officer/ci-actions` and `cloud-officer/soup`. They are the
  largest single dependency in the generated workflows and receive the most sensitive secrets; they warrant
  their own threat model. T-01 addresses only how they are *referenced* from here.
- **Out of scope:** GitHub's own platform security, the security of the runner images, and the third-party
  linters themselves beyond the credentials handed to them.
- **Not modeled:** `bin/update_versions.sh` beyond boundary #10. It is a maintainer-run script whose
  outputs land in a reviewed PR; a hostile upstream version string would have to survive `require_version`
  and human review of the diff.
- **Not applicable:** privacy threat modeling (LINDDUN). The system handles no personal data; the only
  personal identifiers touched are GitHub logins and team slugs read from `CODEOWNERS` and the GitHub API
  for the authorization check at `lib/ghb/auto_approve_manager.rb:42`.

## Sign-off

- Modeled by: AI (draft) · Reviewed & accepted by: __________ (human)
- Method: LLM-assisted generation with human review. Every threat above is anchored to a specific file and
  line, rated, and mapped to an existing or missing control — but the accept-versus-mitigate decision, and
  the formal acceptance of residual risk, belong to a person. This document is not an authoritative final
  artifact until that signature is present.
- Decisions specifically requiring a human: T-01 (SHA pinning vs. bump churn), T-03 (auto-approval scope),
  T-05 (`enforce_admins`), T-06 (GHAS cost vs. secret-scanning coverage on private repos), T-12
  (`strict: false`).
