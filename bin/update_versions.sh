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
