#!/usr/bin/env bash

# Refresh the pinned language and service versions in config/languages.yaml and
# config/options/*.yaml from their upstream sources. Run from the repository
# root (every path below is relative to the working directory).
#
# Strict mode note: each lookup is a `<fetch> | <filter>` pipeline whose filters
# (jq, grep, sort, tail) exit 0 on empty input, so under bare `set -e` a failed
# fetch used to write an empty version into the config YAML. Under `pipefail`
# those pipelines fail instead, so every lookup ends with `|| true` — keeping
# the AWS-first paths degrading to their public fallback — and every resolved
# value is checked by `require_version` before yq touches a file.

set -euo pipefail

LANGUAGE_FILE="config/languages.yaml"

# Abort with a clear error instead of writing an empty (or JSON null) version
# into a config file.
function require_version()
{
  local name="$1" value="$2"

  if [ -z "${value}" ] || [ "${value}" == "null" ]; then
    echo "::error::could not resolve the latest ${name} version" >&2
    exit 1
  fi
}

# Go

latest=$(curl -fsS "https://go.dev/VERSION?m=text" || true)
latest_go=$(echo "${latest#go}" | awk 'NR==1 { print $1 }')
require_version "Go" "${latest_go}"
export latest_go
yq e --indent=2 '(.go.setup_options[] | select(.name == "go-version").value) = env(latest_go)' -i "${LANGUAGE_FILE}"
yq e --indent=2 '(.proto.setup_options[] | select(.name == "go-version").value) = env(latest_go)' -i "${LANGUAGE_FILE}"

# Node.js

latest=$(curl -fsS "https://nodejs.org/dist/index.json" | jq -r '.[0].version' || true)
latest_node=${latest#v}
require_version "Node.js" "${latest_node}"
export latest_node
yq e --indent=2 '(.js.setup_options[] | select(.name == "node-version").value) = env(latest_node)' -i "${LANGUAGE_FILE}"

# Java (track the latest LTS major, not a hardcoded interim release or exact patch)

latest_java=$(curl -fsS "https://api.adoptium.net/v3/info/available_releases" | jq -r '.most_recent_lts' || true)
require_version "Java" "${latest_java}"
export latest_java
yq e --indent=2 '(.kotlin.setup_options[] | select(.name == "java-version").value) = env(latest_java)' -i "${LANGUAGE_FILE}"

# PHP

releases=$(curl -fsS "https://www.php.net/releases/index.php?json=1" || true)
latest_php=$(echo "${releases}" | jq -r 'to_entries | map(.value) | map(select(.version | test("^8\\."))) | map(.version)[]' | sort -V | tail -n1 || true)
require_version "PHP" "${latest_php}"
export latest_php
yq e --indent=2 '(.php.setup_options[] | select(.name == "php-version").value) = env(latest_php)' -i "${LANGUAGE_FILE}"

# Xcode

releases=$(curl -fsS "https://xcodereleases.com/data.json" || true)
latest_xcode=$(echo "${releases}" | jq -r '[.[] | select(.version.release.release == true) | .version][0].number' || true)
require_version "Xcode" "${latest_xcode}"
export latest_xcode
yq e --indent=2 '(.proto.setup_options[] | select(.name == "xcode-version").value) = env(latest_xcode)' -i "${LANGUAGE_FILE}"

# Python

latest_python=$(pyenv install --list | grep -oE '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^[[:space:]]*//' | sort -V | tail -n1 || true)
require_version "Python" "${latest_python}"
export latest_python
yq e --indent=2 '(.python.setup_options[] | select(.name == "python-version").value) = env(latest_python)' -i "${LANGUAGE_FILE}"

# Ruby

latest_ruby=$(rbenv install -l | grep -E '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^[[:space:]]*//' | sort -V | tail -n1 || true)
require_version "Ruby" "${latest_ruby}"
export latest_ruby
yq e --indent=2 '(.ruby.setup_options[] | select(.name == "ruby-version").value) = env(latest_ruby)' -i "${LANGUAGE_FILE}"

# MongoDB (DocumentDB)

latest_mongodb=$(aws docdb describe-db-engine-versions --engine docdb --query 'DBEngineVersions[*].EngineVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -V | tail -n1 || true)

if [ -z "${latest_mongodb}" ]; then
    latest_mongodb=$(curl -fsS https://api.github.com/repos/mongodb/mongo/releases | jq -r '[.[] | select(.tag_name | test("^r[0-9]+\\.[0-9]+\\.[0-9]+$")) | .tag_name | ltrimstr("r")] | map(select(. | startswith("5.0") or startswith("4."))) | sort_by(. | split(".") | map(tonumber)) | last' || true)
fi

require_version "MongoDB" "${latest_mongodb}"
export latest_mongodb
yq e --indent=2 '(.options[] | select(.name == "mongodb-version").value) = env(latest_mongodb)' -i "config/options/mongodb.yaml"

# MySQL (Aurora)

latest_mysql=$(aws rds describe-db-engine-versions --engine aurora-mysql --query 'DBEngineVersions[*].EngineVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -V | tail -n1 | sed -E 's/^([0-9]+\.[0-9]+).*/\1/' || true)

if [ -z "${latest_mysql}" ]; then
    latest_mysql=$(curl -fsS https://dev.mysql.com/downloads/mysql/ | grep -oE 'MySQL Community Server [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)
fi

require_version "MySQL" "${latest_mysql}"
export latest_mysql
yq e --indent=2 '(.options[] | select(.name == "mysql-version").value) = env(latest_mysql)' -i "config/options/mysql.yaml"

# Valkey (ElastiCache)

latest_valkey=$(aws elasticache describe-cache-engine-versions --engine valkey --query 'CacheEngineVersions[*].EngineVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -V | tail -n1 || true)

if [ -z "${latest_valkey}" ]; then
    latest_valkey=$(curl -fsS https://api.github.com/repos/valkey-io/valkey/releases | jq -r '[.[] | select(.tag_name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | .tag_name] | first' || true)
fi

# Validate version against actions-setup-redis supported valkey versions. An
# unsupported or unresolved version degrades to the "latest" tag rather than
# failing the run.
valkey_versions=$(curl -fsS https://raw.githubusercontent.com/shogo82148/actions-setup-redis/main/src/versions/valkey.json | jq -r '[.[].version | split(".")[0:2] | join(".")] | unique | .[]' || true)
valkey_minor=$(echo "${latest_valkey}" | grep -oE '^[0-9]+\.[0-9]+' || true)

if [ -z "${latest_valkey}" ] || [ -z "${valkey_minor}" ] || ! echo "${valkey_versions}" | grep -q "^${valkey_minor}$"; then
    latest_valkey="latest"
fi

export latest_valkey
yq e --indent=2 '(.options[] | select(.name == "redis-version").value) = env(latest_valkey)' -i "config/options/redis.yaml"

# OpenSearch
#
# Track the `OpenSearch_*` line, not `Elasticsearch_*`. AWS forked OpenSearch after
# Elastic's 2021 licence change, so `list-versions` caps Elasticsearch compatibility at
# 7.10 permanently -- filtering on it pinned us to a dead lineage while our domains run
# AWS::OpenSearchService::Domain. Major.minor is what ankane/setup-opensearch expects.

latest_opensearch=$(aws opensearch list-versions --query 'Versions[*]' --output text 2>/dev/null | tr '\t' '\n' | grep -E '^OpenSearch_[0-9]+\.[0-9]+$' | sed 's/OpenSearch_//' | sort -V | tail -n1 || true)

if [ -z "${latest_opensearch}" ]; then
    latest_opensearch=$(curl -fsS https://api.github.com/repos/opensearch-project/OpenSearch/releases | jq -r '[.[] | select(.tag_name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | .tag_name | split(".")[0:2] | join(".")] | first' || true)
fi

require_version "OpenSearch" "${latest_opensearch}"
export latest_opensearch
yq e --indent=2 '(.options[] | select(.name == "opensearch-version").value) = env(latest_opensearch)' -i "config/options/opensearch.yaml"
