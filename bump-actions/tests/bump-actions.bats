#!/usr/bin/env bats

# Tests for bump-actions/bump-actions.sh. A fake `gh` on PATH resolves a fixed
# version/tag map (no network), and BUMP_MANIFEST points the resolver at a
# throwaway fixture manifest. The script is also sourced so its helpers can be
# unit-tested directly (its body is guarded by
# `[[ "${BASH_SOURCE[0]}" == "${0}" ]]`). The fake `gh` mirrors the one in
# cloud-officer/ci-actions so the shared helpers stay behaviour-compatible.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../bump-actions.sh"
  BIN="$(mktemp -d)"
  MANIFEST="$(mktemp)"
  export BUMP_MANIFEST="${MANIFEST}"
  export PATH="${BIN}:${PATH}"
  make_fake_gh
  make_manifest
  # shellcheck source=/dev/null
  source "${SCRIPT}"
}

teardown() {
  rm -rf "${BIN}"
  rm -f "${MANIFEST}"
}

# Fake gh: latest versions per repo, single-ref tag existence, and notes.
make_fake_gh() {
  cat > "${BIN}/gh" <<'EOF'
#!/usr/bin/env bash
args="$*"
case "$args" in
  *"repos/actions/checkout/releases/latest"*)         echo "v7.0.0" ;;
  *"repos/webfactory/ssh-agent/releases/latest"*)     echo "v0.10.0" ;;
  *"repos/some-org/already-current/releases/latest"*) echo "v2.3.4" ;;
  *"repos/branchy/action/releases/latest"*)           echo "v3.0.0" ;;
  *"repos/ahead/action/releases/latest"*)             echo "v7.0.0" ;;
  *"repos/tagonly/action/releases/latest"*)           echo "" ;;
  *"repos/tagonly/action/tags"*)                      printf 'v3.1.0\nv3.0.0\nv2.0.0\n' ;;
  *"repos/actions/checkout/git/ref/tags/v7"*)         echo "refs/tags/v7" ;;
  *"git/ref/tags/"*)                                  exit 1 ;;
  "release view"*)                                    echo "fake release notes" ;;
  *)                                                  echo "" ;;
esac
EOF
  chmod +x "${BIN}/gh"
}

# Manifest fixture covering: floating major to bump, exact semver to bump, an
# already-current major, a cloud-officer entry (skipped), a SHA pin, a branch
# pin, an exact pin ahead of latest, and a tag-only repo.
make_manifest() {
  cat > "${MANIFEST}" <<'EOF'
---
# External action version manifest (test fixture).
actions/checkout: v6
webfactory/ssh-agent: v0.9.1
some-org/already-current: v2
cloud-officer/internal-action: v2
pinned/by-sha: 0123456789abcdef0123456789abcdef01234567
branchy/action: main
ahead/action: v8.0.0
tagonly/action: v2
EOF
}

# ===========================================================================
# Helper unit tests (sourced) — shared with cloud-officer/ci-actions
# ===========================================================================

@test "is_sha matches only 40-char hex" {
  is_sha 0123456789abcdef0123456789abcdef01234567
  ! is_sha v6
  ! is_sha 0123456789abcdef0123456789abcdef0123456g
}

@test "is_floating_major / is_exact_semver classification" {
  is_floating_major v6
  is_floating_major 1
  ! is_floating_major v0.9.1
  ! is_floating_major main
  is_exact_semver v0.9.1
  is_exact_semver 0.35.0
  ! is_exact_semver v6
  ! is_exact_semver main
}

@test "major_of strips the v and takes the leading number" {
  [ "$(major_of v6)" = 6 ]
  [ "$(major_of v7.2.0)" = 7 ]
  [ "$(major_of 0.35.0)" = 0 ]
}

@test "version_gt is newer-aware and v-prefix insensitive" {
  version_gt v0.10.0 v0.9.1
  version_gt v0.36.0 0.35.0
  ! version_gt v0.35.0 0.35.0
  ! version_gt v7.0.0 v8.0.0
}

@test "esc_re escapes regex metacharacters" {
  [ "$(esc_re 'a.b/c')" = 'a\.b\/c' ]
}

@test "manifest_entries skips comments, the doc marker and cloud-officer entries" {
  run manifest_entries "${MANIFEST}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"actions/checkout v6"* ]]
  [[ "${output}" == *"tagonly/action v2"* ]]
  [[ "${output}" != *"cloud-officer/internal-action"* ]]
  [[ "${output}" != *"#"* ]]
}

# ===========================================================================
# Dry-run resolution
# ===========================================================================

@test "dry run lists floating-major and exact-semver bumps" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"actions/checkout"*"v6 -> v7"* ]]
  [[ "${output}" == *"webfactory/ssh-agent"*"v0.9.1 -> v0.10.0"* ]]
}

@test "floating major stays floating (not pinned to exact)" {
  run "${SCRIPT}"
  [[ "${output}" == *"v6 -> v7"* ]]
  [[ "${output}" != *"v6 -> v7.0.0"* ]]
}

@test "action already on the latest major is not bumped" {
  run "${SCRIPT}"
  [[ "${output}" != *"some-org/already-current"* ]]
}

@test "cloud-officer entries are skipped" {
  run "${SCRIPT}"
  [[ "${output}" != *"cloud-officer/internal-action"* ]]
}

@test "SHA-pinned entries are skipped" {
  run "${SCRIPT}"
  [[ "${output}" != *"pinned/by-sha"* ]]
}

@test "branch pins (e.g. main) are skipped with a warning, not converted to a tag" {
  run "${SCRIPT}"
  ! grep -qE '^BUMP[[:space:]]+branchy/action' <<< "${output}"
  [[ "${output}" == *"branchy/action@main is not a version tag"* ]]
}

@test "exact pins ahead of the latest release are not downgraded" {
  run "${SCRIPT}"
  [[ "${output}" != *"ahead/action"* ]]
}

@test "tag-only repos resolve via the tags fallback" {
  run "${SCRIPT}"
  # releases/latest empty -> highest semver tag v3.1.0; no floating v3 tag -> exact
  [[ "${output}" == *"tagonly/action"*"v2 -> v3.1.0"* ]]
}

# ===========================================================================
# Apply
# ===========================================================================

@test "--apply rewrites the bumped entries and leaves the rest untouched" {
  run "${SCRIPT}" --apply
  [ "${status}" -eq 0 ]
  grep -q '^actions/checkout: v7$'             "${MANIFEST}"
  grep -q '^webfactory/ssh-agent: v0.10.0$'    "${MANIFEST}"
  grep -q '^tagonly/action: v3.1.0$'           "${MANIFEST}"
  # current-major, cloud-officer, branch and ahead pins are untouched
  grep -q '^some-org/already-current: v2$'      "${MANIFEST}"
  grep -q '^cloud-officer/internal-action: v2$' "${MANIFEST}"
  grep -q '^branchy/action: main$'              "${MANIFEST}"
  grep -q '^ahead/action: v8.0.0$'              "${MANIFEST}"
  # comment header preserved
  grep -q '^# External action version manifest' "${MANIFEST}"
}

# ===========================================================================
# PR body, empty result and missing manifest
# ===========================================================================

@test "--pr-body-file writes a table and release notes" {
  body="$(mktemp)"
  run "${SCRIPT}" --apply --pr-body-file "${body}"
  [ "${status}" -eq 0 ]
  grep -q '| Action | From | To |' "${body}"
  grep -q '| actions/checkout | v6 | v7 |' "${body}"
  grep -q 'fake release notes' "${body}"
  rm -f "${body}"
}

@test "no bumps available exits 0 with a clear message" {
  empty="$(mktemp)"
  printf -- '---\nsome-org/already-current: v2\n' > "${empty}"
  BUMP_MANIFEST="${empty}" run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [[ "${output}" == *"No external action bumps available."* ]]
  rm -f "${empty}"
}

@test "a missing manifest exits non-zero with a clear error" {
  BUMP_MANIFEST="/nonexistent/manifest.yaml" run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"manifest not found"* ]]
}
