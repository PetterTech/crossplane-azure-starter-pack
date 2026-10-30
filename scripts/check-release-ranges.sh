#!/usr/bin/env bash
# Checks the Configuration dependency ranges of a project against the versions being released.
#
# usage: scripts/check-release-ranges.sh [--registry] <project> <version>
#        scripts/check-release-ranges.sh --help
#
#   <project>   foundation | services | landingzone
#   <version>   the version being released, vX.Y.Z (no pre-release suffix)
#   --registry  only count versions that exist in ghcr.io (docker buildx imagetools inspect).
#               Without it, git tags <dependency>/vX.Y.Z are the list of released versions.
#
# Overrides for tests: PUBLISHED_<DEP>="v0.1.0 v0.1.1" (DEP upper-case) replaces the version list.
#
# Checks:
#   1. <version> is plain vX.Y.Z.
#   2. Every Configuration dependency range in projects/<project>/crossplane-project.yaml is
#      "stable-shaped": >=A.B.C <next-breaking, where next-breaking is 0.(B+1).0 for 0.x and
#      (A+1).0.0 otherwise.
#   3. Bottom-up: each range is satisfied by at least one released dependency version.
#      A missing dependency release fails with the tag to create first.
#   4. Dependents (info): if other projects have a range on <project>, warn when <version> falls
#      outside it, because they must be re-released with a new range.
#
# Exit codes: 0 all checks pass, 1 a check failed, 2 usage error.
set -euo pipefail

cd "$(dirname "$0")/.."

usage() { sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; }

registry=0
args=()
for a in "$@"; do
  case "$a" in
    -h|--help) usage; exit 0 ;;
    --registry) registry=1 ;;
    *) args+=("$a") ;;
  esac
done
[ ${#args[@]} -eq 2 ] || { usage >&2; exit 2; }
project=${args[0]} version=${args[1]}

case "$project" in foundation|services|landingzone) ;; *) echo "unknown project: $project" >&2; exit 2 ;; esac
manifest_of() { echo "projects/$1/crossplane-project.yaml"; }
[ -f "$(manifest_of "$project")" ] || { echo "missing $(manifest_of "$project")" >&2; exit 2; }

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

plain() { [[ $1 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

# a >= b for plain versions (without leading v)
cmp() { # v1 op v2
  local a=$1 op=$2 b=$3 low
  low=$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)
  case "$op" in
    '>=') [ "$low" = "$b" ] ;;
    '>')  [ "$a" != "$b" ] && [ "$low" = "$b" ] ;;
    '<=') [ "$low" = "$a" ] ;;
    '<')  [ "$a" != "$b" ] && [ "$low" = "$a" ] ;;
    '='|'==') [ "$a" = "$b" ] ;;
    *) return 2 ;;
  esac
}

# satisfies <version> "<range>": every space separated comparator must hold
satisfies() {
  local v=${1#v} range=$2 c op ver
  for c in $range; do
    [[ $c =~ ^(>=|<=|==|=|>|<)v?([0-9]+\.[0-9]+\.[0-9]+)$ ]] || { echo "unparsable comparator '$c'" >&2; return 2; }
    op=${BASH_REMATCH[1]} ver=${BASH_REMATCH[2]}
    cmp "$v" "$op" "$ver" || return 1
  done
}

# Prints "<dep-name> <range>" for each Configuration dependency of a project.
config_deps() {
  awk '
    /^[[:space:]]*kind:/ { kind=$2 }
    /^[[:space:]]*package:/ { pkg=$2 }
    /^[[:space:]]*version:/ {
      v=$0; sub(/^[[:space:]]*version:[[:space:]]*/, "", v); gsub(/"/, "", v)
      if (kind == "Configuration") { n=pkg; sub(/.*\//, "", n); print n, v }
    }' "$(manifest_of "$1")"
}

released_versions() { # dep
  local dep=$1 var v list
  var="PUBLISHED_$(echo "$dep" | tr '[:lower:]' '[:upper:]')"
  if [ -n "${!var+x}" ]; then list=${!var}
  else list=$(git tag --list "$dep/v*" | sed "s#^$dep/##"); fi
  for v in $list; do
    plain "$v" || continue
    if [ "$registry" = 1 ] && [ -z "${!var+x}" ]; then
      docker buildx imagetools inspect "ghcr.io/pettertech/crossplane-azure-starter-pack/$dep:$v" >/dev/null 2>&1 || continue
    fi
    echo "$v"
  done
}

shape_ok() { # range
  local range=$1 lo hi a b
  [[ $range =~ ^\>=v?([0-9]+)\.([0-9]+)\.([0-9]+)\ \<v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || return 1
  a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
  if [ "$a" = 0 ]; then
    [ "${BASH_REMATCH[4]}.${BASH_REMATCH[5]}.${BASH_REMATCH[6]}" = "0.$((b + 1)).0" ]
  else
    [ "${BASH_REMATCH[4]}.${BASH_REMATCH[5]}.${BASH_REMATCH[6]}" = "$((a + 1)).0.0" ]
  fi
}

plain "$version" || err "version '$version' is not plain vX.Y.Z"

n=0
while read -r dep range; do
  [ -n "${dep:-}" ] || continue
  n=$((n + 1))
  if ! shape_ok "$range"; then
    err "$project: range on $dep is '$range'; use '>=vA.B.C <vNEXT' (0.x: <v0.(B+1).0, otherwise <v(A+1).0.0)"
    continue
  fi
  have=$(released_versions "$dep" </dev/null | tr '\n' ' ')
  ok=""
  for v in $have; do
    if satisfies "$v" "$range"; then ok=$v; fi
  done
  if [ -z "$ok" ]; then
    err "$project requires $dep '$range' but no matching $dep release exists$([ "$registry" = 1 ] && echo " in ghcr.io"). Release $dep first (git tag $dep/<vX.Y.Z> within that range), then $project."
  else
    echo "ok: $project -> $dep '$range' satisfied (released: ${have% })"
  fi
done < <(config_deps "$project")
[ "$n" -gt 0 ] || echo "ok: $project has no Configuration dependencies"

for other in foundation services landingzone; do
  [ "$other" != "$project" ] || continue
  while read -r dep range; do
    [ "$dep" = "$project" ] || continue
    if plain "$version" && ! satisfies "$version" "$range"; then
      echo "WARN: $other depends on $project '$range'; $version is outside it, so $other must raise its range and be re-released." >&2
    fi
  done < <(config_deps "$other")
done

[ $fail = 0 ] && echo "release ranges ok for $project $version"
exit $fail
