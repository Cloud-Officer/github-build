#!/usr/bin/env bash

# Bump the external-action pins in config/actions.yaml (--apply edits in place; BUMP_MANIFEST overrides the path).

function is_sha()            { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
function is_floating_major() { [[ "$1" =~ ^v?[0-9]+$ ]]; }
function is_exact_semver()   { [[ "$1" =~ ^v?[0-9]+\.[0-9]+ ]]; }
function major_of()          { local v="${1#v}"; echo "${v%%.*}"; }
function esc_re()            { printf '%s' "$1" | sed 's/[.[\*^$/]/\\&/g'; }

# Upstream tag names are attacker-controlled and git permits |, the sed delimiter in apply_bump.
function is_valid_version() { [[ "$1" =~ ^v?[0-9]+(\.[0-9]+)*$ ]]; }

# True when A is strictly newer than B, ignoring a leading v.
function version_gt()
{
  local a="${1#v}" b="${2#v}"
  [ "${a}" != "${b}" ] && [ "$(printf '%s\n%s\n' "${a}" "${b}" | sort -V | tail -1)" == "${a}" ]
}

function manifest_entries()
{
  awk -F': *' '/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.\/-]+:[[:space:]]*[^[:space:]]/ { print $1, $2 }' "$1" \
    | grep -viE '^cloud-officer/' \
    | sort -u
}

function latest_version()
{
  local or="$1" tag
  tag="$(gh api "repos/${or}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  if [ -n "${tag}" ] && [ "${tag}" != "null" ] && ! is_valid_version "${tag}"; then
    echo "::warning::${or} published a release tag that is not a plain version (${tag}); ignoring it" >&2
    tag=""
  fi
  if [ -z "${tag}" ] || [ "${tag}" == "null" ]; then
    tag="$(gh api "repos/${or}/tags?per_page=100" --jq '.[].name' 2>/dev/null \
            | grep -E '^v?[0-9]+(\.[0-9]+)*$' | sort -V | tail -1 || true)"
  fi
  printf '%s' "${tag}"
}

# Single-ref lookup: tag listing is paginated and misses floating majors on repos with >100 tags.
function tag_exists()
{
  gh api "repos/$1/git/ref/tags/$2" --jq '.ref' >/dev/null 2>&1
}

function resolve_bump()
{
  local or="$1" ver="$2"
  local new="" latest latest_major cur_major prefix candidate

  is_sha "${ver}" && return 0

  latest="$(latest_version "${or}")"
  if [ -z "${latest}" ]; then
    echo "::warning::could not resolve latest version for ${or} (currently @${ver}); skipping" >&2
    return 0
  fi

  if is_floating_major "${ver}"; then
    latest_major="$(major_of "${latest}")"
    cur_major="$(major_of "${ver}")"
    [[ "${latest_major}" =~ ^[0-9]+$ ]] || return 0
    if [ "${latest_major}" -gt "${cur_major}" ]; then
      prefix=""; [[ "${ver}" == v* ]] && prefix="v"
      candidate="${prefix}${latest_major}"
      if tag_exists "${or}" "${candidate}"; then new="${candidate}"; else new="${latest}"; fi
    fi
  elif is_exact_semver "${ver}"; then
    version_gt "${latest}" "${ver}" && new="${latest}"
  else
    echo "::warning::${or}@${ver} is not a version tag (branch/unknown); skipping" >&2
  fi

  printf '%s' "${new}"
}

# Rewrite "name: <old>" -> "name: <new>" in the manifest (portable: temp + mv).
function apply_bump()
{
  local manifest="$1" name="$2" new="$3" name_re tmp
  if ! is_valid_version "${new}"; then
    echo "::error::refusing to write an invalid version for ${name}: ${new}" >&2
    return 1
  fi
  name_re="$(esc_re "${name}")"
  tmp="$(mktemp)"
  sed -E "s|^(${name_re}:[[:space:]]*).*\$|\1${new}|" "${manifest}" > "${tmp}"
  if ! cmp -s "${manifest}" "${tmp}"; then
    mv "${tmp}" "${manifest}"
    echo "updated ${manifest}: ${name} -> ${new}"
  else
    rm -f "${tmp}"
  fi
}

function main()
{
  set -euo pipefail

  local apply=false pr_body_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --apply) apply=true ;;
      --pr-body-file) pr_body_file="${2:?--pr-body-file needs a path}"; shift ;;
      *) echo "::error::unknown argument: $1" >&2; return 2 ;;
    esac
    shift
  done

  cd "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

  local manifest="${BUMP_MANIFEST:-config/actions.yaml}"
  if [ ! -f "${manifest}" ]; then
    echo "::error::manifest not found: ${manifest}" >&2
    return 1
  fi

  # Parallel arrays describing each bump.
  local bump_repo=() bump_old=() bump_new=()
  local name ver new
  while read -r name ver; do
    [ -n "${name}" ] || continue
    new="$(resolve_bump "${name}" "${ver}")"
    if [ -n "${new}" ]; then
      bump_repo+=("${name}"); bump_old+=("${ver}"); bump_new+=("${new}")
    fi
  done < <(manifest_entries "${manifest}")

  local count="${#bump_repo[@]}"
  if [ "${count}" -eq 0 ]; then
    echo "No external action bumps available."
    return 0
  fi

  local i
  for i in "${!bump_repo[@]}"; do
    printf 'BUMP\t%s\t%s -> %s\n' "${bump_repo[${i}]}" "${bump_old[${i}]}" "${bump_new[${i}]}"
  done
  echo "${count} bump(s) available."

  if [ "${apply}" == true ]; then
    for i in "${!bump_repo[@]}"; do
      apply_bump "${manifest}" "${bump_repo[${i}]}" "${bump_new[${i}]}"
    done
  fi

  # PR body: table of bumps + truncated upstream release notes.
  if [ -n "${pr_body_file}" ]; then
    local notes
    {
      echo "## Automated external action bumps"
      echo
      echo "Bumps external GitHub Action versions in \`config/actions.yaml\` to their latest"
      echo "upstream major/release. Generated by \`bump-actions/bump-actions.sh\` (issue #408)."
      echo "Review the linked release notes for breaking changes before merging."
      echo
      echo "| Action | From | To |"
      echo "| --- | --- | --- |"
      for i in "${!bump_repo[@]}"; do
        printf '| %s | %s | %s |\n' "${bump_repo[${i}]}" "${bump_old[${i}]}" "${bump_new[${i}]}"
      done
      echo
      echo "### Upstream release notes"
      for i in "${!bump_repo[@]}"; do
        name="${bump_repo[${i}]}"; new="${bump_new[${i}]}"
        echo
        echo "#### ${name} ${new}"
        echo
        notes="$(gh release view "${new}" --repo "${name}" --json body --jq '.body' 2>/dev/null || true)"
        if [ -n "${notes}" ]; then
          printf '%s\n' "${notes}" | head -n 40
        else
          echo "_Release notes not available; see https://github.com/${name}/releases_"
        fi
      done
    } > "${pr_body_file}"
    echo "Wrote PR body to ${pr_body_file}"
  fi

  return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
