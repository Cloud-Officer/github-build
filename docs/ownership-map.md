# Ownership Map & Bus Factor — github-build

**Date:** 2026-09-07   **Window:** full history (2023-05-20 → 2026-09-07, 652 commits), weighted to the last 12 months
**Thresholds:** 50% (bus factor), 75% (knowledge silo), 9 months (stale), 5 shared commits (co-change cluster)
**Method:** `git blame -w -M` line ownership on tracked files + commit recency, cross-checked against `.github/CODEOWNERS`,
GitHub team membership, and PR approval records. Blame is not understanding — see [Caveats & method](#caveats--method).

This report describes **organizational risk, not individual performance**. A bus factor of 1 is a property of how the
team is staffed and how review is wired, not a judgement about the person holding the knowledge.

## Headline risks

- **Repo bus factor: 1.** One person, Yves Desgagné, owns **19,125 of 19,170 current lines (99.8%)**. Every one of the
  116 non-empty tracked files has bus factor 1, and 109 of them have a single owner at 100%.
- **Sensitive files with bus factor 1: 34 of 34** — every CI/CD workflow, every job builder, the GitHub API client, the
  branch-protection configurator, the security-scanner suppression files, and both supply-chain bump scripts.
- **CODEOWNERS drift: 0 file-level mismatches, 1 structural finding.** `@Cloud-Officer/Maintainers` resolves to two
  accounts, of which **one is a bot** (`cloudofficer-admin`, display name `cloud-officer-bot`). The catch-all `*` rule
  therefore delivers exactly one human code owner.
- **Segregation of duties: not currently achieved.** All 14 most recent merged PRs were authored by `ydesgagn` and
  approved by the bot account. The `required_approving_review_count: 1` control is satisfied by automation, not by a
  second person. See [Segregation of duties](#segregation-of-duties-iso-a53).
- **Stale sensitive code: 4 files** — linter configs shipped to downstream repositories, untouched since 2023-06-07.

## Risk matrix

Change frequency uses commits in the last 12 months: `high` >= 20, `medium` 5-19, `low` < 5.

| File / module | Change freq | Top owner (%) | Bus factor | Sensitive? | Risk |
| --- | --- | --- | --- | --- | --- |
| `lib/ghb/` (25 files, 3,783 lines) | high (112) | Yves Desgagné (100) | 1 | yes | critical |
| `.github/workflows/` (4 files, 453 lines) | high (39) | Yves Desgagné (100) | 1 | yes | critical |
| `config/` (26 files, 2,369 lines) | high (121) | Yves Desgagné (99.6) | 1 | yes | high |
| `config/linters/` (17 files, 842 lines) | high (26) | Yves Desgagné (98.8) | 1 | yes | high |
| `lib/ghb/workflow/` (4 files, 453 lines) | high (20) | Yves Desgagné (100) | 1 | yes | high |
| `bin/` (2 files, 166 lines) | medium (11) | Yves Desgagné (100) | 1 | yes | high |
| `bump-actions/` (1 file, 228 lines) | low (4) | Yves Desgagné (100) | 1 | yes | medium |
| `config/options/` (5 files, 118 lines) | medium (15) | Yves Desgagné (100) | 1 | no | medium |
| `spec/` (34 files, 8,561 lines) | high (86) | Yves Desgagné (100) | 1 | no | medium |
| `tests/` (2 files, 523 lines) | medium (5) | Yves Desgagné (100) | 1 | no | low |
| `docs/` (2 files, 943 lines) | high (120) | Yves Desgagné (99.8) | 1 | no | low |

The concentration dimension is uniform here: there is no module, and no individual file, where a second contributor
holds enough of the current code to continue without the top owner.

## Single points of failure (bus factor 1 on sensitive code)

All 34 sensitive files have bus factor 1 and the same owner. The highest-consequence ones:

| File | Owner | Owner active? | Last changed | Why it matters |
| --- | --- | --- | --- | --- |
| `lib/ghb/application.rb` | Yves Desgagné (100%) | yes | 2026-09-01 | Orchestrates the whole generator; 126 commits, 46 in the last 12 months |
| `lib/ghb/repository_configurator.rb` | Yves Desgagné (100%) | yes | 2026-09-01 | Writes branch protection, required checks, required signatures, secret-scanning push protection for every repo it runs against |
| `lib/ghb/auto_approve_manager.rb` | Yves Desgagné (100%) | yes | 2026-09-01 | Generates the approval control itself; the one person who can change the review gate is the one it approves |
| `lib/ghb/github_api_client.rb` | Yves Desgagné (100%) | yes | 2026-09-01 | Sole handler of `GITHUB_TOKEN`; the credential boundary for all repo mutations |
| `.github/workflows/build.yml` | Yves Desgagné (100%) | yes | 2026-09-07 | This repo's own CI; 49 commits, 23 in the last 12 months |
| `.github/workflows/auto-approve.yml` | Yves Desgagné (100%) | yes | 2026-09-07 | Runs on `pull_request_target` with `GH_PAT` / `GH_BOT_PAT`; a privileged, single-owner workflow |
| `lib/ghb/linter_job_builder.rb` + `config/linters.yaml` | Yves Desgagné (100%) | yes | 2026-09-02 | Decides which security scanners (Semgrep, Trivy, Bandit, CodeQL) run in downstream repos |
| `lib/ghb/dependabot_manager.rb` | Yves Desgagné (100%) | yes | 2026-08-31 | Removes legacy Dependabot config; governs supply-chain alerting posture |
| `bin/update_versions.sh`, `bump-actions/bump-actions.sh` | Yves Desgagné (100%) | yes | 2026-09-01 / 2026-08-31 | Pin and bump external GitHub Actions — the supply-chain trust anchor |
| `config/languages.yaml` | Yves Desgagné (100%) | yes | 2026-09-07 | Highest-churn file in the repo (121 commits, 79 in 12 months); drives detection for every generated workflow |
| `.trivyignore`, `.semgrepignore`, `config/linters/.bandit` | Yves Desgagné (94-100%) | yes | 2026-08-29 / 2026-06-03 / 2026-06-01 | Vulnerability suppression: a single owner decides what findings are ignored, here and downstream |

Blast radius is wider than this repository. `github-build` generates the CI, branch protection, and scanner
configuration for the rest of the fleet, so bus factor 1 here is bus factor 1 on the security posture of every repo it
provisions.

The owner is highly active (261 commits in the last 12 months, most recent today), so this is a **continuity** risk
rather than an **orphaning** risk — the knowledge is present but undistributed.

## CODEOWNERS drift

No file has an actual owner different from its declared owner: `.github/CODEOWNERS` assigns everything to
`@Cloud-Officer/Maintainers`, and Yves Desgagné is in that team and does own every file. The finding is structural.

| File | Declared owner | Actual owner | Note |
| --- | --- | --- | --- |
| `*` (all 121 tracked files) | `@Cloud-Officer/Maintainers` | Yves Desgagné (99.8% of lines) | Team has 2 members: `ydesgagn` and `cloudofficer-admin` (a bot). One human code owner. |
| `.github/`, `bin/`, `lib/`, `*.sh`, linter configs | `@Cloud-Officer/Maintainers` | Yves Desgagné (100%) | The explicit build/deploy rules restate the catch-all; they add specificity but no additional owner. |
| — | — | `tlacroix` (admin collaborator) | Repo admin, **not** in the Maintainers team, holds 11 lines. Can merge, is not a code owner — the reverse of the usual drift. |

### Segregation of duties (ISO A.5.3)

The generated `auto-approve.yml` approves any PR whose author is in the catch-all CODEOWNERS entry, using
`secrets.GH_BOT_PAT`. It correctly refuses to self-approve when approver and author are the same account, and the
branch protection it writes sets `dismiss_stale_reviews`, `require_code_owner_reviews`, `require_last_push_approval`
and `required_approving_review_count: 1` — all sound controls. The gap is who satisfies them:

- Maintainers team = 1 human + 1 bot.
- The bot is the approver on 14/14 of the most recently merged PRs, all authored by the sole human maintainer.
- `enforce_admins: false`, and the human maintainer is a repo admin.

The result is that author, code owner, approver-of-record, and the person who can change the approval workflow are
effectively the same individual. No control here is misconfigured; there is simply no second human in the loop.

## Stale sensitive code

| File | Owner | Last changed | Owner active? |
| --- | --- | --- | --- |
| `config/linters/.golangci.yml` | Yves Desgagné (100%) | 2023-06-07 | yes |
| `config/linters/.hadolint.yaml` | Yves Desgagné (100%) | 2023-06-07 | yes |
| `config/linters/.protolint.yaml` | Yves Desgagné (100%) | 2023-06-07 | yes |
| `config/linters/.shellcheckrc` | Yves Desgagné (100%) | 2023-06-07 | yes |

These are the Go, Docker, protobuf, and shell linter configurations distributed to downstream repositories. They have
not been revised in over three years while `config/linters.yaml` around them changed 24 times in the last 12 months —
worth confirming they still reflect current rule sets rather than 2023 defaults. `config/linters/.shellcheckrc` and the
root `.shellcheckrc` are both empty files (0 blame lines), so no owner can be computed for them at all.

## Co-change clusters (pairs co-occurring in >= 5 commits in the window)

Every cluster below has the same owner on both sides, so none reveals a cross-owner responsibility gap. What they do
reveal is coupling that a second contributor would have to learn as a unit.

| Cluster (files) | Owners | Note |
| --- | --- | --- |
| `config/languages.yaml` + `docs/soup.md` (28) + `docs/architecture.md` (25) + `README.md` (12) | Yves Desgagné | Language detection changes fan out into three separate documents; documentation is coupled to config by hand |
| `.github/workflows/build.yml` + `.github/workflows/dependencies.yml` (14) | Yves Desgagné | The two generated workflows are regenerated together; changing one in isolation is not the normal path |
| `.github/workflows/build.yml` + `config/languages.yaml` (14) | Yves Desgagné | This repo dogfoods its own generator — config edits regenerate its own CI |
| `lib/ghb/application.rb` + `lib/ghb/options.rb` (11) | Yves Desgagné | Orchestrator and CLI options move together; the option surface is not decoupled from the flow |
| `lib/ghb/*.rb` + matching `spec/ghb/*_spec.rb` (9-12 each) | Yves Desgagné | Healthy signal: implementation and tests change together for `repository_configurator`, `language_job_builder`, `options`, `linter_job_builder`, `gitignore_manager`, `application`, `workflow` |
| `config/languages.yaml` + `config/linters.yaml` (9) | Yves Desgagné | Language and linter catalogues are effectively one dataset split across two files |

## Recommended actions (cultural, not just tooling)

Ordered by how much risk each removes per unit of effort.

1. **Add a second human to `@Cloud-Officer/Maintainers`.** This is the single highest-value change: it converts the
   approval control from automation-satisfied to peer-reviewed and gives the ISO A.5.3 evidence something to point at.
   `tlacroix` is already an admin collaborator and has contributed, so this may be a team-membership change rather than
   a hiring one.
2. **Scope the auto-approve workflow away from the highest-risk paths.** Let it keep unblocking routine dependency and
   docs PRs, but require a human approval for `lib/ghb/repository_configurator.rb`, `lib/ghb/auto_approve_manager.rb`,
   `lib/ghb/github_api_client.rb`, `.github/workflows/`, and the ignore/suppression files. That preserves the velocity
   benefit while restoring four-eyes on the security-relevant surface.
3. **Pair or walk through the four credential- and control-bearing files** (`application.rb`,
   `repository_configurator.rb`, `github_api_client.rb`, `auto_approve_manager.rb`). A recorded walkthrough or a design
   note in `docs/architecture.md` costs hours and is the difference between a second person being able to take over in
   days versus weeks.
4. **Document the coupling the co-change data exposes** — specifically that `config/languages.yaml` changes require
   corresponding edits to `docs/soup.md`, `docs/architecture.md`, and `README.md`. Right now that sequence lives in one
   person's habits. Consider generating what can be generated.
5. **Review the four 2023-era linter configs** and either refresh them or record that they are deliberately frozen, so
   the staleness stops reading as neglect.
6. **Keep the test suite as the knowledge backstop.** 8,561 lines of spec against 3,783 lines of `lib` is a genuinely
   strong ratio and is currently the most effective transfer mechanism in the repo — the co-change data shows specs
   move with implementation consistently. Preserve that discipline.

Note that raising the bus factor is not the same as duplicating a role. The goal is enough overlap that a second person
can safely review, debug, and release — not that two people do the same work.

## Caveats & method

- **Blame shows who last touched a line, not who understands it best.** Knowledge spreads through review, pairing,
  and documentation in ways git cannot see. These numbers are a conversation starter and a diagnostic, not a verdict.
- **Thresholds are defaults**, not truth: 50% for bus factor, 75% for silo, 9 months for staleness, 5 shared commits
  for a co-change cluster, and 20/5 commits-per-year for high/medium change frequency.
- **Identity folding:** `Yves Desgagne` (39 commits) and `Yves Desgagné` (558 commits) share the email
  `yves@cloudofficer.ca` and are counted as one person. No `.mailmap` exists; adding one would make this automatic.
- **`cloudofficer-admin` is treated as a service account, not a second owner.** It is a bot (`cloud-officer-bot`,
  created 2024-12-30) whose 28 commits are automated dependency and SOUP updates, last committing 2025-12-27. Its 14
  blame lines are not counted as human knowledge coverage. Counting it as a person would report a bus factor of 1 with
  a "team" of two and hide the actual finding.
- **Whole-repo scope:** all 121 tracked files were analyzed at file level; the risk matrix aggregates them by module
  for readability. No time window was applied to ownership; recency is reported separately.
- **Excluded from blame:** `Gemfile.lock` (generated) and `.idea/` (4 tracked IDE files, not authored code). Nothing
  else was excluded — this repository vendors no dependencies.
- **Skipped untracked paths:** `docs/threat-model.md` is untracked and has no git history, so no ownership can be
  computed for it. It matched no sensitive-category pattern. It is the only untracked, non-ignored file in the tree.
- **Uncommitted work:** 19 lines currently blame to `Not Committed Yet` (17 in `README.md`, 2 in
  `docs/architecture.md`) from unstaged working-tree edits. They are excluded from owner percentages.
- **Full clone verified** before analysis (`git rev-parse --is-shallow-repository` → `false`, no grafts, 652 commits
  back to the initial commit). A shallow clone would have fabricated these numbers.
- **Other contributors, for completeness:** Tommy Lacroix (4 commits, 11 current lines, last 2026-08-29),
  Franck Clément (1 commit, 1 line, last 2026-02-05), Lionel Nicolas (2 commits, 0 surviving lines, last 2025-08-18),
  and `dependabot[bot]` (20 commits, 0 surviving lines). Their contributions are real but too small to change any
  file's bus factor.
- **Read-only:** no code, configuration, or git history was modified in producing this report.

## ISO 27001:2022 mapping

| Control | Evidence in this report |
| --- | --- |
| **A.5.3 Segregation of duties** | Author, code owner, approver-of-record, and owner of the approval workflow are the same individual; the second team member is a bot. Documented above with PR-level evidence. |
| **Clause 7.2 Competence** | Knowledge concentration is quantified per module and per sensitive file; the mitigation plan is in [Recommended actions](#recommended-actions-cultural-not-just-tooling). |
| **A.8.25 / A.8.27 Secure development** | Bus factor 1 on the code that generates branch protection, required checks, and scanner configuration for the whole fleet is a documented operational risk with a stated mitigation. |
| **A.8.28 Secure coding** | Single-owner control over `.trivyignore`, `.semgrepignore`, and `config/linters/.bandit` means vulnerability suppression decisions have no second reviewer. |

Cross-reference `docs/threat-model.md` when it lands: any trust-boundary component that also has bus factor 1 is a
compounded risk — critical and fragile at the same time.
