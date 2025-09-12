#!/usr/bin/env bash
set -e

LANGUAGE_FILE="config/languages.yaml"

# Go

latest=$(curl -s https://go.dev/VERSION?m=text)
latest_go=$(echo "${latest#go}" | awk '{ print $1 }')
export latest_go
yq --indent=2 e '(.go.setup_options[] | select(.name == "go-version").value) = env(latest_go)' -i "${LANGUAGE_FILE}"
yq --indent=2 e '(.proto.setup_options[] | select(.name == "go-version").value) = env(latest_go)' -i "${LANGUAGE_FILE}"

# Node.js

latest=$(curl -s https://nodejs.org/dist/index.json | jq -r '.[0].version')
latest_node=${latest#v}
export latest_node
yq e --indent=2 '(.js.setup_options[] | select(.name == "node-version").value) = env(latest_node)' -i "${LANGUAGE_FILE}"

# Java

latest_java=$(curl -s "https://api.adoptium.net/v3/assets/latest/24/hotspot" | jq -r '.[0].version.openjdk_version' | cut -d+ -f1)
export latest_java
yq e --indent=2 '(.kotlin.setup_options[] | select(.name == "java-version").value) = env(latest_java)' -i  "${LANGUAGE_FILE}"

# PHP

releases=$(curl -s "https://www.php.net/releases/index.php?json=1")
latest_php=$(echo "${releases}" | jq -r 'to_entries | map(.value) | map(select(.version | test("^8\\."))) | map(.version)[]' | sort -V | tail -n1)
export latest_php
yq e --indent=2 '(.php.setup_options[] | select(.name == "php-version").value) = env(latest_php)' -i "${LANGUAGE_FILE}"

# Xcode

releases=$(curl -s "https://xcodereleases.com/data.json")
latest_xcode=$(echo "${releases}" |  jq -r '[.[] | select(.version.release.release == true) | .version][0].number')
export latest_xcode
yq e --indent=2 '(.proto.setup_options[] | select(.name == "xcode-version").value) = env(latest_xcode)' -i "${LANGUAGE_FILE}"

# Python

latest_python=$(pyenv install --list | grep -oE '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^[[:space:]]*//' | sort -V | tail -n1)
export latest_python
yq --indent=2 e '(.python.setup_options[] | select(.name == "python-version").value) = env(latest_python)' -i "${LANGUAGE_FILE}"

# Ruby

latest_ruby=$(rbenv install -l | grep -E '^[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+$' | sed 's/^[[:space:]]*//' | sort -V | tail -n1)
export latest_ruby
yq --indent=2 e '(.ruby.setup_options[] | select(.name == "ruby-version").value) = env(latest_ruby)' -i "${LANGUAGE_FILE}"

# MongoDB (DocumentDB)

latest_mongodb=$(aws docdb describe-db-engine-versions --engine docdb --query 'DBEngineVersions[*].EngineVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -V | tail -n1)

if [ -z "${latest_mongodb}" ]; then
    latest_mongodb=$(curl -s https://api.github.com/repos/mongodb/mongo/releases | jq -r '[.[] | select(.tag_name | test("^r[0-9]+\\.[0-9]+\\.[0-9]+$")) | .tag_name | ltrimstr("r")] | map(select(. | startswith("5.0") or startswith("4."))) | sort_by(. | split(".") | map(tonumber)) | last')
fi

export latest_mongodb
yq --indent=2 e '(.options[] | select(.name == "mongodb-version").value) = env(latest_mongodb)' -i "config/options/mongodb.yaml"

# MySQL (Aurora)

latest_mysql=$(aws rds describe-db-engine-versions --engine aurora-mysql --query 'DBEngineVersions[*].EngineVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -V | tail -n1 | sed -E 's/^([0-9]+\.[0-9]+).*/\1/')

if [ -z "${latest_mysql}" ]; then
    latest_mysql=$(curl -s https://dev.mysql.com/downloads/mysql/ | grep -oE 'MySQL Community Server [0-9]+\.[0-9]+\.[0-9]+' | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1)
fi

export latest_mysql
yq --indent=2 e '(.options[] | select(.name == "mysql-version").value) = env(latest_mysql)' -i "config/options/mysql.yaml"

# Redis (ElastiCache/Valkey)

latest_redis=$(aws elasticache describe-cache-engine-versions --engine redis --query 'CacheEngineVersions[*].EngineVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -V | tail -n1)
latest_valkey=$(aws elasticache describe-cache-engine-versions --engine valkey --query 'CacheEngineVersions[*].EngineVersion' --output text 2>/dev/null | tr '\t' '\n' | sort -V | tail -n1)

# Compare and use the highest version
if [ -n "${latest_valkey}" ] && [ -n "${latest_redis}" ]; then
    if [ "$(printf '%s\n' "${latest_valkey}" "${latest_redis}" | sort -V | tail -n1)" == "${latest_valkey}" ]; then
        latest_redis="${latest_valkey}"
    fi
elif [ -n "${latest_valkey}" ]; then
    latest_redis="${latest_valkey}"
fi

if [ -z "${latest_redis}" ]; then
    latest_redis=$(curl -s https://api.github.com/repos/valkey-io/valkey/releases | jq -r '[.[] | select(.tag_name | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")) | .tag_name] | first')

    if [ -z "${latest_redis}" ]; then
        latest_redis=$(curl -s https://raw.githubusercontent.com/redis/redis/unstable/src/version.h | grep REDIS_VERSION | cut -d'"' -f2)
    fi
fi

export latest_redis
yq --indent=2 e '(.options[] | select(.name == "redis-version").value) = env(latest_redis)' -i "config/options/redis.yaml"
