#!/usr/bin/env bash
# Decides which projects CI has to check from the files changed since a base commit.
# usage: scripts/ci-changes.sh <base-sha>   (empty or all-zero base = everything changed)
# Prints "projects=<json array>" and "build=<json array>" (GITHUB_OUTPUT format).
#
# Dependencies:
#   - .github/, scripts/ and setup/ feed every project (setup/functions.yaml is used by all render tests).
#   - foundation/apis/_shared holds the resolver template that services compositions must match,
#     and landingzone renders against foundation and services APIs.
# Not built with `crossplane project build`: landingzone, which depends on foundation and services
# packages that are not published yet (PR 18).
set -euo pipefail

cd "$(dirname "$0")/.."
base=${1:-}

if [ -z "$base" ] || [ -z "${base//0/}" ] || ! git cat-file -e "$base^{commit}" 2>/dev/null; then
  files=$'.github/\n'
else
  files=$(git diff --name-only "$base" HEAD)
fi

any() { printf '%s\n' "$files" | grep -Eq "$1"; }

all=0 foundation=0 services=0 landingzone=0
any '^(\.github/|scripts/|setup/)' && all=1
if [ $all = 1 ]; then foundation=1 services=1 landingzone=1; fi
any '^projects/foundation/' && foundation=1
any '^projects/services/' && services=1
any '^projects/landingzone/' && landingzone=1
any '^projects/foundation/apis/_shared/' && services=1
[ $foundation = 1 ] || [ $services = 1 ] && landingzone=1

json() { # names...
  local out="" n
  for n in "$@"; do out+="${out:+,}\"$n\""; done
  echo "[$out]"
}

projects=()
build=()
[ $foundation = 1 ] && projects+=(foundation) && build+=(foundation)
[ $services = 1 ] && projects+=(services) && build+=(services)
[ $landingzone = 1 ] && projects+=(landingzone)

echo "projects=$(json ${projects[@]+"${projects[@]}"})"
echo "build=$(json ${build[@]+"${build[@]}"})"
