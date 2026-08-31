#!/usr/bin/env bats

# Tests for bin/update_versions.sh. Fake `curl`, `aws`, `pyenv` and `rbenv`
# binaries on PATH resolve fixed upstream payloads (no network, no AWS
# credentials), and the script runs against a throwaway copy of `config/` so the
# real files are never touched. Real `jq`/`yq` are used so the actual filters and
# yq expressions are exercised.
#
# Fake behaviour is driven by env knobs: FAKE_CURL_FAIL (substring of the URL to
# fail on), FAKE_AWS_OK (AWS answers instead of failing), FAKE_JAVA_NULL,
# FAKE_PYENV_EMPTY and FAKE_VALKEY_UNSUPPORTED.

setup() {
  command -v jq >/dev/null || skip "jq is not installed"
  command -v yq >/dev/null || skip "yq is not installed"

  SCRIPT="${BATS_TEST_DIRNAME}/../bin/update_versions.sh"
  BIN="$(mktemp -d)"
  WORK="$(mktemp -d)"
  export PATH="${BIN}:${PATH}"
  make_fakes
  cp -R "${BATS_TEST_DIRNAME}/../config" "${WORK}/config"
  cd "${WORK}" || exit 1
}

teardown() {
  cd "${BATS_TEST_DIRNAME}" || exit 1
  rm -rf "${BIN}" "${WORK}"
}

make_fakes() {
  cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for arg in "$@"; do
  case "${arg}" in http*) url="${arg}" ;; esac
done

if [ -n "${FAKE_CURL_FAIL:-}" ] && [[ "${url}" == *"${FAKE_CURL_FAIL}"* ]]; then
  echo "curl: (22) simulated upstream failure for ${url}" >&2
  exit 22
fi

case "${url}" in
  *go.dev/VERSION*)
    printf 'go1.25.3\ntime 2026-01-01T00:00:00Z\n' ;;
  *nodejs.org/dist/index.json*)
    printf '[{"version":"v24.4.1"},{"version":"v24.4.0"}]\n' ;;
  *api.adoptium.net*)
    if [ -n "${FAKE_JAVA_NULL:-}" ]; then printf '{}\n'; else printf '{"most_recent_lts":21}\n'; fi ;;
  *php.net/releases*)
    printf '{"8.5":{"version":"8.5.1"},"8.4":{"version":"8.4.3"},"7.4":{"version":"7.4.33"}}\n' ;;
  *xcodereleases.com*)
    printf '[{"version":{"number":"26.2","release":{"beta":1}}},{"version":{"number":"26.1","release":{"release":true}}}]\n' ;;
  *mongodb/mongo/releases*)
    printf '[{"tag_name":"r8.0.4"},{"tag_name":"r5.0.31"},{"tag_name":"r4.4.29"}]\n' ;;
  *dev.mysql.com*)
    printf '<p>MySQL Community Server 9.2.0 (GA)</p>\n' ;;
  *valkey-io/valkey/releases*)
    if [ -n "${FAKE_VALKEY_UNSUPPORTED:-}" ]; then
      printf '[{"tag_name":"9.9.9"}]\n'
    else
      printf '[{"tag_name":"8.1.1"},{"tag_name":"8.0.2"}]\n'
    fi ;;
  *actions-setup-redis*)
    printf '[{"version":"8.1.0"},{"version":"7.2.5"}]\n' ;;
  *opensearch-project/OpenSearch/releases*)
    printf '[{"tag_name":"3.8.0"},{"tag_name":"3.7.0"}]\n' ;;
  *)
    echo "unexpected url: ${url}" >&2; exit 1 ;;
esac
EOF

  cat > "${BIN}/aws" <<'EOF'
#!/usr/bin/env bash
if [ -z "${FAKE_AWS_OK:-}" ]; then
  echo "Unable to locate credentials." >&2
  exit 255
fi

case "$1" in
  docdb)       printf '5.0.0\t4.0.0\n' ;;
  rds)         printf '8.0.mysql_aurora.3.05.2\t5.7.mysql_aurora.2.11.4\n' ;;
  elasticache) printf '8.1.0\t7.2.6\n' ;;
  # Elasticsearch_ entries are deliberate: 8.1 sorts above every OpenSearch_ entry,
  # so this fixture fails if the filter ever tracks that lineage again.
  opensearch)  printf 'Elasticsearch_7.10\tOpenSearch_2.13\tElasticsearch_8.1\tOpenSearch_3.5\n' ;;
  *)           echo "unexpected aws command: $1" >&2; exit 1 ;;
esac
EOF

  cat > "${BIN}/pyenv" <<'EOF'
#!/usr/bin/env bash
[ -n "${FAKE_PYENV_EMPTY:-}" ] && exit 0
printf '  3.13.1\n  3.14.0\n  3.14.0rc1\n  anaconda3-2024.02\n'
EOF

  cat > "${BIN}/rbenv" <<'EOF'
#!/usr/bin/env bash
printf '  3.4.2\n  3.5.0\n  jruby-9.4.5.0\n'
EOF

  chmod +x "${BIN}/curl" "${BIN}/aws" "${BIN}/pyenv" "${BIN}/rbenv"
}

# Read an option value back out of a config file.
value_of() {
  yq e "(.${2}[] | select(.name == \"${3}\").value)" "${1}"
}

# ===========================================================================
# Conventions (the finding this script was changed for)
# ===========================================================================

@test "the script runs under strict mode" {
  grep -q '^set -euo pipefail$' "${BATS_TEST_DIRNAME}/../bin/update_versions.sh"
  ! grep -qE '^set -e$' "${BATS_TEST_DIRNAME}/../bin/update_versions.sh"
}

@test "every yq invocation uses the same flag order" {
  script="${BATS_TEST_DIRNAME}/../bin/update_versions.sh"
  total="$(grep -cE '^yq ' "${script}")"
  ordered="$(grep -cE '^yq e --indent=2 ' "${script}")"
  [ "${total}" -gt 0 ]
  [ "${total}" -eq "${ordered}" ]
  ! grep -qE '^yq --indent' "${script}"
}

# ===========================================================================
# Success path
# ===========================================================================

@test "resolves and writes every language and service version" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(value_of config/languages.yaml go.setup_options go-version)" = "1.25.3" ]
  [ "$(value_of config/languages.yaml proto.setup_options go-version)" = "1.25.3" ]
  [ "$(value_of config/languages.yaml js.setup_options node-version)" = "24.4.1" ]
  [ "$(value_of config/languages.yaml kotlin.setup_options java-version)" = "21" ]
  [ "$(value_of config/languages.yaml php.setup_options php-version)" = "8.5.1" ]
  [ "$(value_of config/languages.yaml proto.setup_options xcode-version)" = "26.1" ]
  [ "$(value_of config/languages.yaml python.setup_options python-version)" = "3.14.0" ]
  [ "$(value_of config/languages.yaml ruby.setup_options ruby-version)" = "3.5.0" ]
  [ "$(value_of config/options/mongodb.yaml options mongodb-version)" = "5.0.31" ]
  [ "$(value_of config/options/mysql.yaml options mysql-version)" = "9.2" ]
  [ "$(value_of config/options/redis.yaml options redis-version)" = "8.1.1" ]
  [ "$(value_of config/options/opensearch.yaml options opensearch-version)" = "3.8" ]
}

@test "the rewritten config files stay valid two-space YAML" {
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  yq e '.' config/languages.yaml >/dev/null
  grep -q '^  - name: mongodb-version$' config/options/mongodb.yaml
}

@test "AWS-sourced versions win over the public fallbacks when AWS answers" {
  FAKE_AWS_OK=1 run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(value_of config/options/mongodb.yaml options mongodb-version)" = "5.0.0" ]
  [ "$(value_of config/options/mysql.yaml options mysql-version)" = "8.0" ]
  [ "$(value_of config/options/redis.yaml options redis-version)" = "8.1.0" ]
  [ "$(value_of config/options/opensearch.yaml options opensearch-version)" = "3.5" ]
}

@test "a failing aws CLI falls back to the public sources instead of aborting" {
  # Regression: under pipefail a non-zero `aws` would kill the whole pipeline
  # before the `-z` fallback could run.
  run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(value_of config/options/mongodb.yaml options mongodb-version)" = "5.0.31" ]
  [ "$(value_of config/options/opensearch.yaml options opensearch-version)" = "3.8" ]
}

# ===========================================================================
# Valkey / redis degradation
# ===========================================================================

@test "a valkey version unsupported by actions-setup-redis degrades to latest" {
  FAKE_VALKEY_UNSUPPORTED=1 run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(value_of config/options/redis.yaml options redis-version)" = "latest" ]
}

@test "an unresolved valkey version degrades to latest instead of failing" {
  FAKE_CURL_FAIL="valkey-io" run "${SCRIPT}"
  [ "${status}" -eq 0 ]
  [ "$(value_of config/options/redis.yaml options redis-version)" = "latest" ]
}

# ===========================================================================
# Failure paths — never write an empty version
# ===========================================================================

@test "a failed upstream fetch exits non-zero and writes nothing" {
  before="$(cat config/languages.yaml)"
  FAKE_CURL_FAIL="go.dev" run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not resolve the latest Go version"* ]]
  [ "$(cat config/languages.yaml)" = "${before}" ]
}

@test "a lookup whose filters yield nothing exits non-zero" {
  # pyenv succeeds but grep/sort/tail produce no version.
  FAKE_PYENV_EMPTY=1 run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not resolve the latest Python version"* ]]
  [ "$(value_of config/languages.yaml python.setup_options python-version)" != "" ]
  [ "$(value_of config/languages.yaml python.setup_options python-version)" != "null" ]
}

@test "a JSON null answer is rejected like an empty one" {
  FAKE_JAVA_NULL=1 run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not resolve the latest Java version"* ]]
  [ "$(value_of config/languages.yaml kotlin.setup_options java-version)" != "null" ]
}

@test "a service whose AWS and public lookups both fail exits non-zero" {
  FAKE_CURL_FAIL="mongodb/mongo" run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not resolve the latest MongoDB version"* ]]
  [ "$(value_of config/options/mongodb.yaml options mongodb-version)" != "" ]
}

@test "every remaining lookup guards its own version" {
  while read -r fail expected; do
    FAKE_CURL_FAIL="${fail}" run "${SCRIPT}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *"could not resolve the latest ${expected} version"* ]]
  done <<'EOF'
nodejs.org Node.js
api.adoptium.net Java
php.net PHP
xcodereleases.com Xcode
dev.mysql.com MySQL
opensearch-project/OpenSearch OpenSearch
EOF
}

@test "an unavailable lookup tool exits non-zero rather than blanking the version" {
  printf '#!/usr/bin/env bash\necho "rbenv: command not found" >&2\nexit 127\n' > "${BIN}/rbenv"
  chmod +x "${BIN}/rbenv"
  run "${SCRIPT}"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"could not resolve the latest Ruby version"* ]]
}
